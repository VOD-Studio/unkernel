#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Headless-Chromium test of the persistent data disk (web/src/data.ts), via
// the DevTools protocol (no npm dependencies; see lib.mjs).
//
//   bun web/test/data.mjs [--dev] [--chrome path] [--mb 4] [--verbose]
//
// Runs against the built output (web/.output, `bun run build:web` first), or
// with --dev against the Vite dev server. One fresh browser profile, page
// loads of the default page (the bundle, which carries the data disk
// template):
//   1. first boot: the data disk is created from the template; mount it by
//      label (mount LABEL=kwdata), write a marker and an N MiB file, sync.
//      Also the guest's own /data mount and the overlay root (its changes
//      live on /data), and that KW.sync() (IRQ 4) alone saves a file
//      written with the guest's writeback slowed down.
//   2. reload: the files are still there, the disk opened lazily (no block
//      data in memory at boot), and a file written under /etc survives
//      another reload. Safe mode (?root=initramfs) boots the plain root
//      with /data mounted, and the reload after it the overlay again.
//   2b. a broken root: /etc/profile ends in `exit`, so the console shell
//      keeps exiting; the guest says so, the reload after it boots safe
//      mode by itself (the plain image, changes kept; the page explains),
//      and `kw-overlay restore` after a repair brings the overlay root back.
//   3. a second tab while the first is open: it gets an in-memory snapshot
//      (and says so), with the saved files; its writes are not saved.
//   4. export (KW.exportData, a download) and reset (KW.resetData): the
//      marker is gone; import the exported file (KW.importData): it is back.
//   5. ?data=0: no data disk.
// The other steps mount the disk at /mnt/kwdata and run sync themselves.
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { readKwsparse } from "../../js/core/kwsparse.ts";
import { PROMPT, opt, openPage, sleep, startServer } from "./lib.mjs";

const mb = Number(opt("mb", "4"));
const TEMPLATE_BLOCKS = 554; // non-zero blocks of the empty kwdata file system (kernel/build.sh datadisk)

const results = [];
const check = (name, ok, detail = "") => {
	results.push(ok);
	console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
};

const MOUNT = "mkdir -p /mnt/kwdata; mountpoint -q /mnt/kwdata || mount LABEL=kwdata /mnt/kwdata";
const ROOT = "awk '$2 == \"/\" { t = $3 } END { print t }' /proc/mounts";
const diskInfo = (p) => p.evaluate(`JSON.stringify(KW.dataDisk && { persistent: KW.dataDisk.persistent, seeded: !!KW.dataDisk.seeded,
	stored: KW.dataDisk.stored.size, mem: KW.dataDisk.mem.size, memBytes: KW.dataDisk.memBytes, notice: KW.dataDisk.notice ?? null,
	stats: KW.dataDisk.stats, size: KW.dataDisk.size })`).then((s) => (s ? JSON.parse(s) : null));
const panelText = (p) => p.evaluate("document.getElementById('data-status').textContent");

const port = 23000 + Math.floor(Math.random() * 1000);
const base = `http://127.0.0.1:${port}/`;
const downloads = mkdtempSync(path.join(tmpdir(), "kw-data-dl-"));
const server = await startServer({ port, host: "127.0.0.1" });
console.log(`server: ${server.kind}, ${base}`);
let a;
try {
	a = await openPage("data");
	await a.send("Page.setDownloadBehavior", { behavior: "allow", downloadPath: downloads });
	const shell = (p) => p.waitScreen(PROMPT, "shell prompt", 180000);
	const load = async (p, url) => {
		await p.goto(url);
		await sleep(500);
		await shell(p);
		// bootwatch confirms the idle prompt (two samples 0.25 s apart) and
		// clears the boot attempt count; two boots in a row reloaded before
		// that count as failed and the next one is safe mode.
		await sleep(1000);
	};

	console.log("== 1. first boot: the data disk is created from the template");
	await load(a, base);
	let info = await diskInfo(a);
	check("data disk attached persistently, created from the template", info?.persistent && info.seeded && info.size === 4 * 1024 ** 3,
		JSON.stringify(info && { stored: info.stored, size: info.size }));
	const panel = await panelText(a);
	check("panel shows the data disk", /Saved in this browser/.test(panel), panel);
	let r = await a.run(`dmesg -n 1; findfs LABEL=kwdata; ${MOUNT} && grep ' /mnt/kwdata ' /proc/mounts`);
	check("the guest finds and mounts LABEL=kwdata", r.rc === 0 && /ext4/.test(r.out), r.out.replace(/\n/g, " | "));
	const marker = `marker-${Date.now()}`;
	r = await a.run(`echo ${marker} > /mnt/kwdata/marker.txt; dd if=/dev/urandom of=/mnt/kwdata/big bs=1M count=${mb} 2>/dev/null; ` +
		"md5sum /mnt/kwdata/big | cut -d' ' -f1; sync", 300000);
	const md5 = r.out.split("\n").map((l) => l.trim()).find((l) => /^[0-9a-f]{32}$/.test(l));
	check(`write a marker and ${mb} MiB, sync`, r.rc === 0 && !!md5, md5);
	info = await diskInfo(a);
	check("saved: blocks in IndexedDB, little kept in memory", info.stored > TEMPLATE_BLOCKS + mb * 256 && info.memBytes < 1048576,
		`${info.stored} stored blocks, ${info.mem} blocks in memory, ${info.stats.saves} saves`);
	r = await a.run("grep -E ' /data | / ' /proc/mounts | cut -d' ' -f2,3 | tr '\\n' ' '; echo");
	check("the guest mounts /data itself, / is the overlay", /\/data ext4/.test(r.out) && /\/ overlay/.test(r.out), r.out);
	// With the guest's writeback and journal commits slowed down, only the
	// sync request (IRQ 4) gets this file onto the disk before the reload.
	r = await a.run("echo 360000 > /proc/sys/vm/dirty_expire_centisecs; echo 360000 > /proc/sys/vm/dirty_writeback_centisecs; " +
		`mount -o remount,commit=600 /data && echo ${marker} > /root/unsynced.txt`);
	const synced = await a.evaluate("KW.sync({ timeout: 5000 })");
	check("KW.sync() (the SDK's sync()) is confirmed by the kernel", r.rc === 0 && synced === true, String(synced));

	console.log("== 2. reload: the files persist, the disk opens lazily");
	await load(a, base);
	info = await diskInfo(a);
	check("reattached without seeding, nothing loaded at boot", info.persistent && !info.seeded && info.stored > TEMPLATE_BLOCKS + mb * 256,
		`${info.stored} stored, ${info.mem} in memory, ${info.stats.storeBlocksRead} blocks read so far`);
	r = await a.run(`${MOUNT} && cat /mnt/kwdata/marker.txt && md5sum /mnt/kwdata/big | cut -d' ' -f1`);
	check("marker and file survive the reload", r.out.includes(marker) && r.out.includes(md5), r.out.replace(/\n/g, " | "));
	r = await a.run("cat /root/unsynced.txt");
	check("a file written without a guest sync survives (KW.sync)", r.out.includes(marker), r.out);
	r = await a.run(`${ROOT}; echo ${marker} > /etc/kw-overlay-test; sync`);
	check("overlay: / is the overlay, write /etc/kw-overlay-test", r.rc === 0 && /^overlay$/m.test(r.out), r.out.replace(/\n/g, " | "));
	await a.evaluate("KW.sync({ timeout: 2000 })");
	await load(a, base);
	r = await a.run(`${ROOT}; cat /etc/kw-overlay-test`);
	check("overlay: /etc/kw-overlay-test survives a reload", /^overlay$/m.test(r.out) && r.out.includes(marker), r.out.replace(/\n/g, " | "));

	await load(a, `${base}?root=initramfs`);
	r = await a.run(`${ROOT}; grep ' /data ' /proc/mounts | cut -d' ' -f3; cat /etc/kw-overlay-test 2>&1 | head -1`);
	const safeBtn = await a.evaluate("document.getElementById('data-safe').textContent");
	check("safe mode (?root=initramfs): the plain root, /data mounted", /^(rootfs|tmpfs|ramfs)$/m.test(r.out) && /^ext4$/m.test(r.out) &&
		!r.out.includes(marker) && safeBtn === "Leave safe mode", `${r.out.replace(/\n/g, " | ")}; button "${safeBtn}"`);
	await load(a, base);
	r = await a.run(`${ROOT}`);
	check("after safe mode: the overlay root again", /^overlay$/m.test(r.out), r.out.replace(/\n/g, " | "));

	console.log("== 2b. a broken root recovers through safe mode");
	r = await a.run("echo exit >> /etc/profile; sync");
	await a.evaluate("KW.sync({ timeout: 2000 })");
	await a.goto(base);
	await sleep(500);
	await a.waitScreen(/console shell keeps exiting/, "the respawn-loop report", 90000);
	check("broken /etc/profile: the guest reports the respawn loop", true);
	await sleep(1500); // /data/overlay/safe reaches IndexedDB (sync -f)
	await load(a, base);
	const scr = await a.screen();
	check("the reload boots safe mode, with the reason", /SAFE MODE/.test(scr) && /kept exiting before its prompt/.test(scr),
		scr.split("\n").filter((l) => /kw-overlay|SAFE/.test(l)).join(" | "));
	const note = await a.evaluate("(() => { const n = document.getElementById('data-safe-note'); return n.hidden ? '' : n.textContent; })()");
	check("the page explains safe mode and kw-overlay restore", /kept exiting/.test(note) && /kw-overlay restore/.test(note), note);
	r = await a.run(`${ROOT}; cat /data/overlay/upper/etc/kw-overlay-test; rm /data/overlay/upper/etc/profile; kw-overlay restore`);
	check("safe mode: plain root, changes kept, kw-overlay restore", /^(rootfs|tmpfs|ramfs)$/m.test(r.out) && r.out.includes(marker) && /uses your changes/.test(r.out),
		r.out.replace(/\n/g, " | "));
	await a.evaluate("KW.sync({ timeout: 2000 })");
	await load(a, base);
	r = await a.run(`${MOUNT}; ${ROOT}; cat /etc/kw-overlay-test`); // step 3 uses the mount
	check("after the repair: the overlay root again, with the changes", /^overlay$/m.test(r.out) && r.out.includes(marker), r.out.replace(/\n/g, " | "));

	console.log("== 3. a second tab gets an unsaved snapshot");
	const b = await a.newTab("data-tab2");
	try {
		await load(b, base);
		info = await diskInfo(b);
		check("second tab: not persistent, with a notice", info && !info.persistent && /another tab/.test(await b.screen()), info?.notice);
		const chk = await panelText(b);
		check("second tab: the panel says so", /In memory only: open in another tab/.test(chk), chk);
		r = await b.run(`${MOUNT} && cat /mnt/kwdata/marker.txt && echo tab2 > /mnt/kwdata/tab2.txt && sync`);
		check("second tab: sees the saved files (a copy)", r.out.includes(marker), r.out.replace(/\n/g, " | "));
		r = await b.run("cat /etc/kw-overlay-test");
		check("second tab: overlay root with the saved changes", r.out.includes(marker), r.out);
	} finally {
		await b.close();
	}
	r = await a.run("ls /mnt/kwdata");
	check("first tab is unaffected", !r.out.includes("tab2.txt") && r.out.includes("marker.txt"), r.out.replace(/\n/g, " "));

	console.log("== 4. export, reset, import");
	const before = new Set(readdirSync(downloads));
	const exp = await a.evaluate("KW.exportData().then((r) => JSON.stringify(r))").then(JSON.parse);
	let file;
	for (let i = 0; i < 40 && !file; i++) {
		await sleep(250);
		file = readdirSync(downloads).find((f) => !before.has(f) && f.endsWith(".kwsparse.gz"));
	}
	let img = null;
	if (file) img = await readKwsparse(readFileSync(path.join(downloads, file)));
	check("export downloads a kwsparse.gz of the disk", !!img && img.size === 4 * 1024 ** 3 && img.indices.length === exp.blocks && exp.blocks > mb * 256,
		file ? `${file}: ${exp.blocks} blocks, ${exp.bytes} bytes` : "no file downloaded");
	await a.evaluate("KW.resetData()").catch(() => {}); // reloads the page
	await sleep(500);
	await shell(a);
	info = await diskInfo(a);
	r = await a.run(`${MOUNT} && ls /mnt/kwdata`);
	check("reset: a fresh disk from the template", info.seeded && !r.out.includes("marker.txt"), r.out.replace(/\n/g, " "));
	if (file) {
		const b64 = readFileSync(path.join(downloads, file)).toString("base64");
		await a.evaluate(`KW.importData(Uint8Array.from(atob(${JSON.stringify(b64)}), (c) => c.charCodeAt(0)))`).catch(() => {});
		await sleep(500);
		await shell(a);
		r = await a.run(`${MOUNT} && cat /mnt/kwdata/marker.txt && md5sum /mnt/kwdata/big | cut -d' ' -f1`);
		check("import restores the exported disk", r.out.includes(marker) && r.out.includes(md5), r.out.replace(/\n/g, " | "));
	}

	console.log("== 5. ?data=0");
	await load(a, `${base}?data=0`);
	info = await diskInfo(a);
	r = await a.run("findfs LABEL=kwdata || echo none");
	check("?data=0: no data disk", info === null && /none/.test(r.out), r.out);
} catch (e) {
	check("exception", false, e.stack ?? e.message);
} finally {
	await a?.close();
	await server.kill();
	try { rmSync(downloads, { recursive: true, force: true }); } catch {}
}

const ok = results.length > 0 && results.every(Boolean);
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
