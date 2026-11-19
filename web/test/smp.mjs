#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Headless-Chromium tests of the page's several-CPUs option (?smp=N;
// web/src/config.ts, boot.ts, js/web/cpu.ts), via the DevTools protocol
// (no npm dependencies; see lib.mjs).
//
//   bun web/test/smp.mjs [--dev] [--chrome /path/to/chrome]
//        [--only up,smp2,smp4,lan,fallback,session,hidden] [--lan-ip A.B.C.D] [--verbose]
//
// Runs against the built output (web/.output; needs a kernel with an SMP
// patch, e.g. KW_KERNEL=../vendor/build/bundle/unkernel-alpine.wasm bun run
// build:web), or with --dev against the Vite dev server (after
// kernel/build.sh smp).
//
// Scenarios:
//   up        default load on 127.0.0.1: fetches only the UP bundle, runs on
//             1 CPU, and enables the CPUs radio choices in Options.
//   smp2      ?smp=2: fetches only the SMP bundle, boots in Web Workers on 2
//             CPUs without Suspend, checks console ring order, JIT compilation
//             on every CPU, 2-CPU parallel scaling, a vsock terminal window,
//             and glimmer's display, evdev and sound through worker mode.
//   smp4      ?smp=4 (when hardwareConcurrency >= 4): fetches only the SMP
//             bundle, boots on 4 CPUs, JIT on every CPU, parallel scaling.
//   lan       ?smp=2 on the LAN IP over plain http (not cross-origin isolated):
//             disables CPUs > 1, never fetches the SMP bundle, boots on 1 CPU.
//   fallback  ?smp=2 with the SMP bundle answered 404: reloads once on 1 CPU
//             (bootUpOnce) and records why.
//   session   a UP suspended session offered before ?smp=2 downloads: "Resume
//             on 1 CPU" resumes it on UP, "Boot on 2 CPUs" boots SMP and
//             discards the session (when a data disk is attached).
//   hidden    ?smp=2 while another foreground tab hides the page: multi-CPU
//             work finishes cleanly without stalling or throwing.
import { availableParallelism, networkInterfaces } from "node:os";
import { PROMPT, findChrome, opt, openPage, sleep, startServer } from "./lib.mjs";

const only = opt("only", "up,smp2,smp4,lan,fallback,session,hidden").split(",");
const DESKTOP = { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false };
const SMP_WASM_RE = /unkernel-alpine-smp[^/]*\.wasm/;
const UP_WASM_RE = /unkernel-alpine(?!-smp)[^/]*\.wasm/;

function lanIp() {
	const explicit = opt("lan-ip");
	if (explicit) return explicit;
	for (const list of Object.values(networkInterfaces()))
		for (const a of list ?? []) if (a.family === "IPv4" && !a.internal) return a.address;
	return null;
}

const port = 24000 + Math.floor(Math.random() * 1000);
const server = await startServer({ port });
const chromePath = findChrome();
const lan = lanIp();

async function trackRequests(page) {
	const urls = [];
	await page.send("Network.enable");
	page.on((m) => {
		if (m.method === "Network.requestWillBeSent") urls.push(m.params.request.url);
	});
	return urls;
}

const wasmUrls = (urls) => urls.filter((u) => /\.wasm(\?|$)/.test(u));

/** Time an awk sqrt loop with `n` parallel workers in the guest (ms, from /proc/uptime). */
async function timeAwk(page, n, iters = 150000) {
	const body = `awk 'BEGIN{s=0; for(i=1;i<=${iters};i++) s+=sqrt(i); printf "%.2f\\n", s}'`;
	const cmd = n === 1
		? body
		: `pids=""; for k in $(seq 1 ${n}); do (${body} > /tmp/awk-$k) & pids="$pids $!"; done; for p in $pids; do wait $p; done; cat /tmp/awk-* | sort -u; rm -f /tmp/awk-*`;
	const r = await page.run(`read t0 _ < /proc/uptime; ${cmd}; read t1 _ < /proc/uptime; awk -v a="$t0" -v b="$t1" 'BEGIN{printf "MS=%.0f\\n", (b-a)*1000}'`, 180000);
	if (r.rc !== 0) throw new Error(`awk x${n} failed (rc=${r.rc}): ${r.out}`);
	const ms = Number(r.out.match(/MS=(\d+)/)?.[1]);
	const sum = r.out.split("\n").map((l) => l.trim()).find((l) => /^\d+\.\d{2}$/.test(l));
	if (!Number.isFinite(ms) || !sum) throw new Error(`unexpected awk x${n} output: ${r.out}`);
	return { ms, sum };
}

const scenarios = {
	async up(page) {
		await page.emulate(DESKTOP);
		const reqs = await trackRequests(page);
		await page.goto(`http://127.0.0.1:${port}/?wisp=0&data=0`);
		await page.waitScreen(PROMPT, "shell prompt");
		const info = await page.evaluate(`({
			cpus: KW.config.cpus,
			statsCpus: KW.vm.stats().cpus,
			smpUrl: KW.config.kernelSmpUrl,
			smpBlocked: KW.config.smpBlocked,
			suspend: typeof KW.suspend,
		})`);
		if (!info.smpUrl) {
			throw new Error("this page has no SMP bundle (build with KW_KERNEL=../vendor/build/bundle/unkernel-alpine.wasm bun run build:web, or pass --dev after kernel/build.sh smp)");
		}
		const wasms = wasmUrls(reqs);
		if (!wasms.some((u) => UP_WASM_RE.test(u)) || wasms.some((u) => SMP_WASM_RE.test(u)))
			throw new Error(`expected only the UP bundle, fetched: ${wasms.join(", ")}`);
		if (info.cpus !== 1 || info.statsCpus !== 1 || info.smpBlocked !== null || info.suspend !== "function")
			throw new Error(`unexpected UP state: ${JSON.stringify(info)}`);
		const r = await page.run("nproc");
		if (r.rc !== 0 || r.out.trim() !== "1") throw new Error(`expected nproc=1, got ${JSON.stringify(r)}`);
		await page.click("#status");
		await page.waitFor("document.getElementById('panel').classList.contains('open')", "panel open");
		const optCheck = await page.evaluate(`(async () => {
			const r2 = document.getElementById("opt-cpus-2");
			if (!r2 || r2.disabled) return { ok: false, disabled: r2?.disabled ?? null };
			r2.checked = true;
			r2.dispatchEvent(new Event("change"));
			await new Promise((r) => setTimeout(r, 50));
			return { ok: true, url: KW.ui.rebootUrl() };
		})()`);
		if (!optCheck.ok || !/[?&]smp=2(&|$)/.test(optCheck.url))
			throw new Error(`CPUs radio did not map to ?smp=2: ${JSON.stringify(optCheck)}`);
		console.log(`  UP bundle only, nproc=1, opt-cpus-2 enabled -> ${optCheck.url}`);
	},

	async smp2(page) {
		await page.emulate(DESKTOP);
		const reqs = await trackRequests(page);
		await page.goto(`http://127.0.0.1:${port}/?smp=2&wisp=0&data=0`);
		await page.waitScreen(PROMPT, "shell prompt", 180000);
		const wasms = wasmUrls(reqs);
		if (!wasms.some((u) => SMP_WASM_RE.test(u)) || wasms.some((u) => UP_WASM_RE.test(u)))
			throw new Error(`expected only the SMP bundle, fetched: ${wasms.join(", ")}`);
		const state = await page.evaluate(`({
			cpus: KW.config.cpus,
			statsCpus: KW.vm.stats().cpus,
			transport: KW.vm.transport,
			suspend: typeof KW.suspend,
			barSuspend: !!document.getElementById("bar-suspend"),
			panelSuspend: !!document.getElementById("suspend"),
			screen: KW.screenText(),
		})`);
		if (state.cpus !== 2 || state.statsCpus !== 2 || state.transport !== "shared")
			throw new Error(`unexpected SMP state: ${JSON.stringify({ ...state, screen: undefined })}`);
		if (state.suspend !== "undefined" || state.barSuspend || state.panelSuspend)
			throw new Error(`Suspend must be hidden on SMP: ${JSON.stringify({ ...state, screen: undefined })}`);
		if (!/on 2 CPUs, in Web Workers/.test(state.screen))
			throw new Error("boot summary does not mention 'on 2 CPUs, in Web Workers'");

		let r = await page.run("nproc; uname -v");
		const lines = r.out.split("\n").map((l) => l.trim()).filter(Boolean);
		if (r.rc !== 0 || lines[0] !== "2" || !/\bSMP\b/.test(lines[1] ?? ""))
			throw new Error(`unexpected nproc/uname: ${JSON.stringify(r)}`);

		// Console ring: lines printed in turn by four processes stay in order, and output arrives while another process spins.
		r = await page.run("cd /tmp && mkfifo t0 t1 t2 t3 && for c in 0 1 2 3; do (exec 3<>t$c; i=$c; while [ $i -lt 80 ]; do read x <&3; echo ord-$i; i=$((i+4)); [ $((i-3)) -lt 80 ] && echo > t$(((c+1)%4)); done) & done; echo > t0; wait; rm t0 t1 t2 t3; cd");
		const gotOrd = r.out.split("\n").map((l) => l.trim()).filter((l) => /^ord-\d+$/.test(l));
		const wantOrd = Array.from({ length: 80 }, (_, i) => `ord-${i}`);
		if (r.rc !== 0 || gotOrd.join(",") !== wantOrd.join(","))
			throw new Error(`console ring reordered or dropped lines: got ${gotOrd.length}: ${gotOrd.slice(0, 10).join(",")}...`);
		r = await page.run("(i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done) & p=$!; echo output-while-spinning; wait $p");
		if (r.rc !== 0 || !r.out.includes("output-while-spinning"))
			throw new Error(`console output failed while a peer spun: ${JSON.stringify(r)}`);
		console.log("  console ring order (80 turn-taking lines across 4 procs) + spinning peer ok");

		// Parallel scaling and per-CPU JIT compilation.
		const t1 = await timeAwk(page, 1);
		const t2 = await timeAwk(page, 2);
		const ratio = t2.ms / Math.max(t1.ms, 1);
		if (t1.sum !== t2.sum) throw new Error(`awk digests differ: ${t1.sum} vs ${t2.sum}`);
		const jitCpus = await page.evaluate("KW.vm.stats().jitCpus");
		console.log(`  awk scaling: 1x=${t1.ms} ms, 2x=${t2.ms} ms (${ratio.toFixed(2)}x); jitCpus=${JSON.stringify(jitCpus?.map((j) => ({ c: j.compiled, f: j.failed })))}`);
		if (!Array.isArray(jitCpus) || jitCpus.length !== 2 || jitCpus.some((j) => !(j.compiled > 0) || j.failed))
			throw new Error(`JIT did not compile cleanly on both CPUs: ${JSON.stringify(jitCpus)}`);
		if (ratio > 1.85) throw new Error(`2 parallel awk loops did not scale (${t2.ms} ms vs ${t1.ms} ms, ${ratio.toFixed(2)}x)`);

		// Terminal window over vsock.
		const win = await page.evaluate(`(async () => {
			const w = await KW.windows.open({ name: "smp-win" });
			await new Promise((r) => setTimeout(r, 400));
			KW.windows.send(w.n, "echo win-$((6*7))-$(nproc)\\r");
			const end = performance.now() + 30000;
			let txt = "";
			while (performance.now() < end) {
				txt = KW.windows.text(w.n);
				if (/^win-42-2\\s*$/m.test(txt)) break;
				await new Promise((r) => setTimeout(r, 150));
			}
			await KW.windows.close(w.n);
			return { n: w.n, ok: /^win-42-2\\s*$/m.test(txt), tail: txt.slice(-300) };
		})()`);
		if (!win.ok) throw new Error(`vsock terminal window failed: ${JSON.stringify(win)}`);
		console.log(`  vsock terminal window #${win.n} ok`);

		// Display, evdev keyboard and sound through worker mode.
		await page.type("glimmer --test 2\r");
		await page.waitScreen(/glimmer: test ready/, "glimmer test ready", 60000);
		const gl = await page.evaluate(`(async () => {
			const f = await KW.vm.readFrame();
			if (!f) return { ok: false, why: "no frame" };
			const px = (x, y) => [...f.data.subarray((y * f.width + x) * 4, (y * f.width + x) * 4 + 4)];
			const corners = [px(0, 0), px(4, 4), px(f.width - 5, 4), px(4, f.height - 5)];
			const k1 = KW.vm.evdev.key(30, true), k0 = KW.vm.evdev.key(30, false);
			return { ok: true, w: f.width, h: f.height, corners, k1, k0 };
		})()`);
		if (!gl.ok) throw new Error(`glimmer frame failed: ${JSON.stringify(gl)}`);
		const wantCorners = [[255, 255, 255, 255], [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]];
		if (JSON.stringify(gl.corners) !== JSON.stringify(wantCorners) || !gl.k1 || !gl.k0)
			throw new Error(`glimmer check mismatch: ${JSON.stringify(gl)}`);
		const s = await page.waitScreen(/glimmer: test sound done/, "glimmer sound done", 60000);
		if (!/glimmer: event event\d+ EV_KEY 30 1[\s\S]*EV_KEY 30 0/.test(s))
			throw new Error("glimmer did not report EV_KEY 30 press and release");
		await page.waitScreen(PROMPT, "prompt after glimmer", 30000);
		console.log(`  glimmer display (${gl.w}x${gl.h}), evdev key and sound ok`);
	},

	async smp4(page) {
		await page.emulate(DESKTOP);
		const hc = await page.evaluate("navigator.hardwareConcurrency || 1");
		if (hc < 4 || availableParallelism() < 4) {
			console.log(`  SKIP smp4 (only ${hc} browser / ${availableParallelism()} host threads)`);
			return;
		}
		const reqs = await trackRequests(page);
		await page.goto(`http://127.0.0.1:${port}/?smp=4&wisp=0&data=0`);
		await page.waitScreen(PROMPT, "shell prompt", 180000);
		const wasms = wasmUrls(reqs);
		if (!wasms.some((u) => SMP_WASM_RE.test(u)) || wasms.some((u) => UP_WASM_RE.test(u)))
			throw new Error(`expected only the SMP bundle, fetched: ${wasms.join(", ")}`);
		const r = await page.run("nproc");
		if (r.rc !== 0 || r.out.trim() !== "4") throw new Error(`expected nproc=4, got ${JSON.stringify(r)}`);
		const t1 = await timeAwk(page, 1);
		const t4 = await timeAwk(page, 4);
		const ratio = t4.ms / Math.max(t1.ms, 1);
		if (t1.sum !== t4.sum) throw new Error(`awk digests differ: ${t1.sum} vs ${t4.sum}`);
		const jitCpus = await page.evaluate("KW.vm.stats().jitCpus");
		console.log(`  awk scaling: 1x=${t1.ms} ms, 4x=${t4.ms} ms (${ratio.toFixed(2)}x); jitCpus=${JSON.stringify(jitCpus?.map((j) => ({ c: j.compiled, f: j.failed })))}`);
		if (!Array.isArray(jitCpus) || jitCpus.length !== 4 || jitCpus.some((j) => !(j.compiled > 0) || j.failed))
			throw new Error(`JIT did not compile cleanly on all 4 CPUs: ${JSON.stringify(jitCpus)}`);
		if (ratio > 2.6) throw new Error(`4 parallel awk loops did not scale (${t4.ms} ms vs ${t1.ms} ms, ${ratio.toFixed(2)}x)`);
	},

	async lan(page) {
		await page.emulate(DESKTOP);
		const host = lan ?? "unkernel.test";
		const reqs = await trackRequests(page);
		await page.goto(`http://${host}:${port}/?smp=2&wisp=0&data=0`);
		await page.waitScreen(PROMPT, "shell prompt", 180000);
		const wasms = wasmUrls(reqs);
		if (wasms.some((u) => SMP_WASM_RE.test(u)))
			throw new Error(`plain-http non-secure page should not fetch SMP bundle: ${wasms.join(", ")}`);
		const info = await page.evaluate(`({
			secure: isSecureContext,
			isolated: crossOriginIsolated,
			cpus: KW.config.cpus,
			statsCpus: KW.vm.stats().cpus,
			blocked: KW.config.smpBlocked,
			why: KW.config.smpWhy,
		})`);
		if (info.secure || info.isolated || info.cpus !== 1 || info.statsCpus !== 1 || !info.blocked)
			throw new Error(`expected plain-http page to block SMP: ${JSON.stringify(info)}`);
		await page.click("#status");
		await page.waitFor("document.getElementById('panel').classList.contains('open')", "panel open");
		const ui = await page.evaluate(`({
			r2Disabled: document.getElementById("opt-cpus-2")?.disabled,
			note: document.getElementById("opt-cpus-note")?.textContent,
		})`);
		if (!ui.r2Disabled || !ui.note) throw new Error(`CPUs option should be disabled on plain http: ${JSON.stringify(ui)}`);
		const r = await page.run("nproc");
		if (r.rc !== 0 || r.out.trim() !== "1") throw new Error(`expected nproc=1 on plain http, got ${JSON.stringify(r)}`);
		console.log(`  plain http://${host}: SMP disabled (${info.blocked}), nproc=1`);
	},

	async fallback(page) {
		await page.emulate(DESKTOP);
		await page.send("Fetch.enable", { patterns: [{ urlPattern: "*unkernel-alpine-smp*.wasm*" }] });
		let blocked = 0;
		page.on((m) => {
			if (m.method === "Fetch.requestPaused") {
				blocked++;
				page.send("Fetch.fulfillRequest", {
					requestId: m.params.requestId,
					responseCode: 404,
					body: Buffer.from("not found\n").toString("base64"),
				});
			}
		});
		await page.goto(`http://127.0.0.1:${port}/?smp=2&wisp=0&data=0`);
		// First load hits 404 on the SMP bundle, records kw-up-once and reloads onto 1 CPU.
		await page.waitFor("globalThis.KW?.config?.cpus === 1 && !!globalThis.KW?.config?.smpWhy", "reload onto 1 CPU", 60000);
		await page.waitScreen(PROMPT, "shell prompt after UP fallback", 180000);
		const info = await page.evaluate(`({
			search: location.search,
			cpus: KW.config.cpus,
			statsCpus: KW.vm.stats().cpus,
			smpWhy: KW.config.smpWhy,
		})`);
		if (blocked < 1 || info.cpus !== 1 || info.statsCpus !== 1 || !/smp=2/.test(info.search) || !/404|SMP kernel did not load/.test(info.smpWhy ?? ""))
			throw new Error(`unexpected fallback state (blocked=${blocked}): ${JSON.stringify(info)}`);
		const r = await page.run("nproc");
		if (r.rc !== 0 || r.out.trim() !== "1") throw new Error(`expected nproc=1 after fallback, got ${JSON.stringify(r)}`);
		console.log(`  blocked SMP 404 (${blocked}x) -> reloaded UP (${info.smpWhy})`);
	},

	async session(page) {
		await page.emulate(DESKTOP);
		const base = `http://127.0.0.1:${port}/?wisp=0`;
		// 1. Boot UP (with the default data disk), write a marker and suspend.
		await page.goto(base);
		await page.waitScreen(PROMPT, "initial UP shell prompt", 180000);
		await sleep(1000); // let bootwatch confirm the prompt
		const marker = `smp-snap-${Date.now()}`;
		let r = await page.run(`echo ${marker} > /tmp/snap.txt; sync`);
		if (r.rc !== 0) throw new Error(`failed to write marker: ${JSON.stringify(r)}`);
		const snap1 = await page.evaluate("KW.suspend()");
		await page.waitFor("!!document.getElementById('resume-card')", "resume card after suspend", 30000);
		console.log(`  suspended UP (${(snap1.bytes / 1048576).toFixed(1)} MiB in ${snap1.ms.toFixed(0)} ms)`);

		// 2. Navigate to ?smp=2: dialog offers "Resume on 1 CPU" vs "Boot on 2 CPUs"; pick Resume.
		await page.goto(`${base}&smp=2`);
		await page.waitFor("document.getElementById('confirm')?.open === true", "resume dialog on ?smp=2", 30000);
		const labels = await page.evaluate(`({
			ok: document.getElementById("confirm-ok")?.textContent,
			cancel: document.getElementById("confirm-cancel")?.textContent,
		})`);
		if (labels.ok !== "Resume on 1 CPU" || labels.cancel !== "Boot on 2 CPUs")
			throw new Error(`unexpected resume dialog buttons: ${JSON.stringify(labels)}`);
		await page.click("#confirm-ok");
		await page.waitFor("globalThis.KW?.config?.cpus === 1 && document.getElementById('app')?.dataset.state === 'running' && /Suspended session:\\s+resumed/i.test(globalThis.KW?.ui?.diagText?.() ?? '')", "resumed on 1 CPU", 40000);
		await sleep(500);
		r = await page.run("cat /tmp/snap.txt; nproc");
		if (r.rc !== 0 || !r.out.includes(marker) || !/^1$/m.test(r.out))
			throw new Error(`resumed session missing marker or wrong nproc: ${JSON.stringify(r)}`);
		console.log("  'Resume on 1 CPU' resumed the UP session with state intact");

		// 3. Suspend again, navigate to ?smp=2, and pick "Boot on 2 CPUs" (must boot SMP and discard the session).
		await page.evaluate("KW.suspend()");
		await page.waitFor("!!document.getElementById('resume-card')", "second resume card", 30000);
		await page.goto(`${base}&smp=2`);
		await page.waitFor("document.getElementById('confirm')?.open === true", "second resume dialog", 30000);
		await page.click("#confirm-cancel");
		await page.waitFor("globalThis.KW?.config?.cpus === 2", "booting on 2 CPUs", 60000);
		await page.waitScreen(PROMPT, "SMP prompt after discarding session", 180000);
		await sleep(1000);
		r = await page.run("nproc");
		if (r.rc !== 0 || r.out.trim() !== "2") throw new Error(`expected nproc=2 after Boot on 2 CPUs, got ${JSON.stringify(r)}`);

		// Verify the saved session was removed (reloading UP boots fresh with no confirm dialog).
		await page.goto(base);
		await page.waitScreen(PROMPT, "fresh UP prompt without resume prompt", 180000);
		const reopened = await page.evaluate("document.getElementById('confirm')?.open === true");
		if (reopened) throw new Error("suspended session was not deleted after Boot on 2 CPUs");
		console.log("  'Boot on 2 CPUs' booted SMP (nproc=2) and discarded the UP session");
	},

	async hidden(page) {
		await page.emulate(DESKTOP);
		await page.goto(`http://127.0.0.1:${port}/?smp=2&wisp=0&data=0`);
		await page.waitScreen(PROMPT, "shell prompt", 180000);
		const win = await page.send("Browser.getWindowForTarget", { targetId: page.targetId });
		const windowId = win.result?.windowId;
		if (!windowId) throw new Error(`Browser.getWindowForTarget returned no windowId: ${JSON.stringify(win)}`);
		try {
			await page.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "minimized" } });
			await page.waitFor("document.visibilityState === 'hidden'", "visibilityState === hidden", 5000);
			// Run parallel work across both CPUs while the page is hidden (worker throttling).
			const cmd = "(awk 'BEGIN{s=0; for(i=1;i<=120000;i++) s+=sqrt(i); printf \"a=%.2f\\n\", s}' > /tmp/bg0) & p0=$!; " +
				"(awk 'BEGIN{s=0; for(i=1;i<=120000;i++) s+=sqrt(i); printf \"b=%.2f\\n\", s}' > /tmp/bg1) & p1=$!; " +
				"wait $p0 $p1; cat /tmp/bg0 /tmp/bg1; rm -f /tmp/bg0 /tmp/bg1";
			const r = await page.run(cmd, 180000);
			const visEnd = await page.evaluate("document.visibilityState");
			if (visEnd !== "hidden") throw new Error(`expected visibilityState to stay hidden, got ${visEnd}`);
			if (r.rc !== 0 || !/^a=\d+\.\d{2}$/m.test(r.out) || !/^b=\d+\.\d{2}$/m.test(r.out))
				throw new Error(`hidden-tab SMP work failed: ${JSON.stringify(r)}`);
			const a = r.out.match(/^a=(\d+\.\d{2})$/m)[1], b = r.out.match(/^b=(\d+\.\d{2})$/m)[1];
			if (a !== b) throw new Error(`hidden-tab SMP digests differ: ${a} vs ${b}`);
			const jitCpus = await page.evaluate("KW.vm.stats().jitCpus");
			console.log(`  hidden tab (visibilityState=hidden): parallel 2-CPU work completed in ${r.secs.toFixed(1)} s (${a}); jitCpus=${JSON.stringify(jitCpus?.map((j) => j.compiled))}`);
		} finally {
			await page.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "normal" } }).catch(() => {});
		}
	},
};

let failed = 0;
try {
	console.log(`chrome: ${chromePath}\nserver: ${server.kind}, http://127.0.0.1:${port}/ (LAN ${lan ?? "none found; lan scenario maps unkernel.test"})`);
	for (const name of only) {
		if (!scenarios[name]) { console.log(`unknown scenario ${name}`); failed++; continue; }
		console.log(`\n[${name}]`);
		const chromeArgs = name === "lan" && !lan ? ["--host-resolver-rules=MAP unkernel.test 127.0.0.1"] : [];
		const page = await openPage(`smp-${name}`, { chromeArgs });
		try {
			await scenarios[name](page);
			if (page.exceptions.length) throw new Error(`uncaught page exceptions: ${page.exceptions.join(" | ")}`);
			console.log(`  PASS ${name}`);
		} catch (e) {
			failed++;
			console.log(`  FAIL ${name}: ${e.message}`);
		} finally {
			await page.close();
		}
	}
} finally {
	await server.kill();
}
console.log(failed ? `\nFAIL (${failed})` : "\nPASS");
process.exit(failed ? 1 : 0);
