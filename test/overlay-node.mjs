#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// The overlay root under Node: persistence, the kw.root=initramfs escape
// hatch, and recovery from broken changes (safe mode, kernel/guest/overlay/).
// Each boot is a CLI process (bun js/cli.ts --data IMG) with the console on
// a pipe, on a data disk image in a temp dir; killing the process stands in
// for a reload or a closed tab.
//
//   bun test/overlay-node.mjs [--verbose] [--keep] [--only NAME[,NAME...]]
//        [--kernel BUNDLE] [--apk] [--image2 BUNDLE2]
//
// Disk hygiene: the images are sparse (created from the template, copied
// with cp --sparse=always, one copy at a time, about 30 MiB each on disk),
// every child is killed on any exit, and the temp dir is removed at the end
// (--keep keeps it).
//
// Cases (each on a copy of one prepared disk that has /root/keep.txt):
//   persist     a file survives, kw.root=initramfs boots the plain image with /data
//   reload      a boot killed before its prompt once does not trip safe mode
//   inittab     /etc/inittab garbage        -> safe mode at the next boot (check)
//   nosh        /bin/sh deleted             -> safe mode at the next boot (check)
//   libc        /lib/ld-musl-* truncated    -> safe mode at the next boot (check)
//   profile     /etc/profile ends in exit   -> bootwatch sees the respawn loop,
//                                             the boot after is safe mode
//   hang        /etc/profile.d hangs (sleep) -> two boots without a prompt, then safe mode
//   spin        /etc/profile.d spins (busy loop) -> the same
//   panic       /sbin/init is a broken file -> kernel panic twice, then safe mode
//   apk         (with --apk; needs the network) apk add python3 cut off ->
//               the next boot removes its leftovers, apk add works again
//   update      (with --image2; needs the network) on the first image install
//               htop and tree, upgrade zlib, remove musl-utils; then boot
//               BUNDLE2, an image with a different package set: apk's
//               database is rebased (kernel/guest/overlay/rebase.sh), and
//               apk info, apk audit, apk add/del and the packages agree
// Every case then repairs the changes from safe mode (or kw-overlay
// restore/discard) and checks that the next boot is the overlay again with
// /root/keep.txt still there.
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (n, d) => (args.includes(`--${n}`) ? args[args.indexOf(`--${n}`) + 1] : d);
const verbose = args.includes("--verbose");
const only = opt("only", "")?.split(",").filter(Boolean);
const kernel = opt("kernel");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const dir = mkdtempSync(path.join(tmpdir(), "kw-overlay-test-"));
const results = [];
const check = (name, ok, detail = "") => {
	results.push(ok);
	console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail && (!ok || verbose) ? `: ${detail}` : ""}`);
	return ok;
};
// Every CLI child, killed on any exit: an orphan would keep a 4 GiB
// (sparse) image open.
const children = new Set();
const killAll = () => { for (const p of children) try { p.kill("SIGKILL"); } catch {} };
process.on("exit", killAll);
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { killAll(); rmSync(dir, { recursive: true, force: true }); process.exit(130); });
const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[78]/g;
const PROMPT = /⇒ $/;

/** One boot: the CLI on IMG with the console on a pipe. */
function boot(img, { append, net = false, kernel: k = kernel } = {}) {
	// A bounded lifetime, in case this script is killed without a chance to
	// kill its children.
	const argv = [path.join(here, "../js/cli.ts"), "--data", img, "--timeout", net ? "600" : "120"];
	if (!net) argv.push("--no-net");
	if (k) argv.push("--kernel", k);
	if (append) argv.push("--append", `console=hvc0 rdinit=/init ${append}`);
	const p = spawn(process.execPath, argv, { stdio: ["pipe", "pipe", "pipe"] });
	children.add(p);
	let out = "", n = 0;
	const t0 = performance.now();
	const onData = (d) => {
		const s = d.toString();
		out += s.replace(ANSI, "").replace(/\r/g, "");
		if (verbose) process.stderr.write(s);
	};
	p.stdout.on("data", onData);
	p.stderr.on("data", onData);
	const exited = new Promise((r) => p.on("exit", (code) => { children.delete(p); r(code); }));
	const b = {
		get out() { return out; },
		exited,
		code: null,
		async wait(re, ms = 60000) {
			const end = performance.now() + ms;
			while (performance.now() < end) {
				const m = re.exec(out);
				if (m) return m;
				if (b.code !== null) break;
				await sleep(50);
			}
			throw new Error(`timeout waiting for ${re} (${((performance.now() - t0) / 1000).toFixed(1)} s); output:\n${out.slice(-3000)}`);
		},
		/** Run a shell command; resolves {out, rc}. */
		async run(cmd, ms = 60000) {
			const tag = `KW${++n}x`;
			p.stdin.write(`echo ${tag}-BEGIN; ${cmd}; echo ${tag}-END-$?\n`);
			const m = await b.wait(new RegExp(`${tag}-END-(\\d+)`), ms);
			const start = out.lastIndexOf(`${tag}-BEGIN\n`, m.index);
			return { out: out.slice(start + tag.length + 7, m.index).trim(), rc: Number(m[1]) };
		},
		prompt: (ms) => b.wait(PROMPT, ms),
		send: (s) => p.stdin.write(s),
		kill() { p.kill("SIGKILL"); return exited; },
		async poweroff() {
			p.stdin.write("poweroff\n");
			const code = await Promise.race([exited, sleep(30000).then(() => "timeout")]);
			if (code === "timeout") { p.kill("SIGKILL"); return exited; }
			return code;
		},
	};
	exited.then((c) => { b.code = c; });
	return b;
}

const rootType = "awk '$2 == \"/\" { t = $3 } END { print t }' /proc/mounts";
/** Boot, expect the overlay root with /root/keep.txt, power off. */
async function expectOverlay(img, what, opts) {
	const b = boot(img, opts);
	await b.prompt();
	await sleep(1000); // bootwatch confirms the idle prompt
	const r = await b.run(`${rootType}; cat /root/keep.txt; ls /data/overlay/attempts 2>&1 | grep -c 'No such'; test -e /data/overlay/safe && echo SAFE`);
	check(`${what}: back on the overlay root, /root/keep.txt intact`, /^overlay$/m.test(r.out) && /keep-\d+/.test(r.out) && /^1$/m.test(r.out) && !/SAFE/.test(r.out), r.out);
	await b.poweroff();
}
/** Boot, expect safe mode with REASON on the console; returns the boot (at its prompt). */
async function expectSafe(img, what, reason) {
	const b = boot(img);
	await b.prompt(90000);
	const r = await b.run(`${rootType}; ls /data/overlay/upper/root/keep.txt; kw-overlay status`);
	check(`${what}: safe mode (plain root, changes kept)`, /SAFE MODE/.test(b.out) && /^rootfs$/m.test(r.out) && /keep\.txt/.test(r.out) && reason.test(b.out),
		b.out.split("\n").filter((l) => /kw-overlay|SAFE|rootfs|keep/.test(l)).join(" | "));
	return b;
}

const base = path.join(dir, "base.img");
let id = 0;
// A sparse copy (fs.copyFileSync would write all 4 GiB); one at a time.
let current = null;
const fresh = () => {
	if (current) rmSync(current, { force: true });
	current = path.join(dir, `c${++id}.img`);
	execFileSync("cp", ["--sparse=always", base, current]);
	return current;
};
const marker = `keep-${Date.now()}`;
let auditBase = "";
const cases = {
	async persist() {
		const img = fresh();
		await expectOverlay(img, "persist");
		const b = boot(img, { append: "kw.root=initramfs" });
		await b.prompt();
		const r = await b.run(`${rootType}; mountpoint /data; cat /root/keep.txt 2>&1; cat /data/overlay/upper/root/keep.txt`);
		check("kw.root=initramfs: plain root, /data mounted, changes unmounted", /^rootfs$/m.test(r.out) && /is a mountpoint/.test(r.out) && /No such file/.test(r.out) && r.out.includes(marker) && /kw\.root=initramfs: the plain image/.test(b.out), r.out);
		await b.poweroff();
		await expectOverlay(img, "after kw.root=initramfs");
	},
	async reload() {
		const img = fresh();
		const b = boot(img);
		await b.wait(/Run \/init as init process/);
		await sleep(150); // inside the overlay switch or just after it
		await b.kill();
		await expectOverlay(img, "one boot killed before its prompt");
	},
	async inittab() {
		const img = fresh();
		let b = boot(img); await b.prompt();
		await b.run("echo 'this is not an inittab' > /etc/inittab; sync");
		await b.poweroff();
		b = await expectSafe(img, "inittab", /inittab starts no console shell/);
		await b.run("rm /data/overlay/upper/etc/inittab");
		await b.poweroff();
		await expectOverlay(img, "inittab repaired");
	},
	async nosh() {
		const img = fresh();
		let b = boot(img); await b.prompt();
		await b.run("rm /bin/sh; sync");
		await b.poweroff();
		b = await expectSafe(img, "nosh", /\/bin\/sh is missing/);
		await b.run("rm /data/overlay/upper/bin/sh"); // the whiteout
		await b.poweroff();
		await expectOverlay(img, "nosh repaired");
	},
	async libc() {
		const img = fresh();
		let b = boot(img); await b.prompt();
		// mv runs before the swap; nothing dynamic runs after it.
		await b.run("head -c 4096 /lib/ld-musl-riscv64.so.1 > /lib/ld.broken; sync");
		b.send("mv /lib/ld.broken /lib/ld-musl-riscv64.so.1\n");
		await sleep(4000); // the journal commit (commit=1)
		await b.kill();
		b = await expectSafe(img, "libc", /\/bin\/sh does not run/);
		await b.run("rm /data/overlay/upper/lib/ld-musl-riscv64.so.1");
		await b.poweroff();
		await expectOverlay(img, "libc repaired");
	},
	async profile() {
		const img = fresh();
		let b = boot(img); await b.prompt();
		await b.run("echo exit >> /etc/profile; sync");
		await b.poweroff();
		b = boot(img);
		await b.wait(/console shell keeps exiting/, 60000);
		check("profile: bootwatch reports the respawn loop", true);
		await sleep(2000);
		await b.kill();
		b = await expectSafe(img, "profile", /no console shell stayed up/);
		const r = await b.run("rm /data/overlay/upper/etc/profile; kw-overlay restore");
		check("profile: kw-overlay restore", /uses your changes/.test(r.out), r.out);
		await b.poweroff();
		await expectOverlay(img, "profile repaired");
	},
	async hang() { await hangCase("hang", "sleep 100000"); },
	async spin() { await hangCase("spin", "while :; do :; done"); },
	async panic() {
		const img = fresh();
		let b = boot(img); await b.prompt();
		// /sbin/init is a symlink to busybox: replace the link, not busybox.
		await b.run("rm /sbin/init && printf '\\177ELF broken' > /sbin/init && chmod 755 /sbin/init; sync");
		await b.poweroff();
		for (const n of [1, 2]) {
			b = boot(img);
			const code = await b.exited;
			check(`panic: boot ${n} ends in a kernel panic (exit 253)`, code === 253 && /Kernel panic/.test(b.out), `exit ${code}`);
		}
		b = await expectSafe(img, "panic", /the last 2 boots with your root changes did not reach a shell prompt/);
		await b.run("rm /data/overlay/upper/sbin/init; kw-overlay restore");
		await b.poweroff();
		await expectOverlay(img, "panic repaired");
	},
	async apk() {
		const img = fresh();
		let b = boot(img, { net: true });
		await b.prompt();
		await b.run("apk update -q", 120000);
		b.send("apk add --no-progress python3\n");
		await b.wait(/Installing python3 /, 180000);
		await sleep(1500);
		await b.kill();
		b = boot(img, { net: true });
		await b.prompt(120000);
		const t = /an apk run was cut off: removed (\d+) files \((\d+) KiB\)/.exec(b.out);
		check("apk: the next boot removes the cut-off run's files", !!t && Number(t[1]) > 50, t?.[0] ?? b.out.slice(-1500));
		let r = await b.run("find /data/overlay/upper -name '.apk.*' | wc -l; ls /usr/lib/libpython3* 2>&1 | head -1; test -e /lib/apk/db/kw-commit && echo MARK");
		check("apk: no .apk.* left, no unregistered libpython, no marker", /^0$/m.test(r.out) && /No such file/.test(r.out) && !/MARK/.test(r.out), r.out);
		r = await b.run("apk add -q --no-progress python3 && python3 -c 'print(6*7)'", 300000);
		check("apk: apk add python3 works afterwards", /^42$/m.test(r.out), r.out);
		r = await b.run("apk audit | grep -v ' etc/resolv.conf$' | sort"); // resolv.conf: DHCP
		const diff = (a, b) => a.split("\n").filter((l) => !b.split("\n").includes(l));
		check("apk: apk audit as on a fresh root", r.out === auditBase, `new: ${diff(r.out, auditBase).join(", ")}; gone: ${diff(auditBase, r.out).join(", ")}`);
		await b.poweroff();
	},
	async update() {
		const image2 = opt("image2");
		const pkgs = "apk --no-network info -v 2>/dev/null | sort | tr '\\n' ' '";
		const audit = "apk audit | grep -v ' etc/resolv.conf$' | sort";
		// Baselines: the second image on a disk without changes.
		const img0 = fresh();
		let b = boot(img0, { kernel: image2 });
		await b.prompt();
		const pk2 = (await b.run(pkgs)).out.split(" ").filter(Boolean);
		const audit2 = (await b.run(audit)).out;
		await b.poweroff();
		const img = fresh();
		b = boot(img, { net: true });
		await b.prompt();
		let r = await b.run("apk update -q && apk add -q --no-progress htop tree && apk upgrade -q --no-progress zlib && apk del -q musl-utils; " +
			`${pkgs}; sync`, 300000);
		const pk1 = r.out.replace(/^.*\]/s, "").split(/\s+/).filter((x) => /-r\d+$/.test(x));
		console.log(`   image 1 + changes: ${pk1.join(" ")}`);
		console.log(`   image 2:           ${pk2.join(" ")}`);
		await b.poweroff();
		b = boot(img, { kernel: image2, net: true });
		await b.prompt(120000);
		const msg = b.out.slice(b.out.indexOf("kw-overlay: the root image changed"), b.out.search(/⇒/));
		console.log(msg.replace(/^/gm, "   | "));
		check("update: the boot rebases apk's database", /kept: .*\bhtop\b/.test(msg) && /kept: .*\btree\b/.test(msg) && /still removed.*musl-utils/.test(msg), msg);
		r = await b.run(pkgs);
		const now = r.out.split(" ").filter(Boolean);
		// htop pulls in lsof; scanelf went with musl-utils.
		const want = [...pk2.filter((p) => !/^(musl-utils|scanelf)-/.test(p)), ...pk1.filter((p) => /^(htop|lsof|tree)-/.test(p))].sort();
		check("update: apk info -v = image 2's packages - musl-utils, scanelf + htop, lsof, tree", now.join(" ") === want.join(" "), `got ${now.join(" ")}; want ${want.join(" ")}`);
		r = await b.run(audit);
		check("update: apk audit as on image 2 without changes", r.out === audit2, r.out);
		r = await b.run("htop --version | head -1; tree --version | head -1; nano --version | head -1; ls /usr/bin/musl-ldd 2>&1; ldd /usr/bin/htop | grep -c ncursesw");
		check("update: htop, tree (yours) and nano (image 2's) run; musl-utils stays removed", /htop 3/.test(r.out) && /tree v2/.test(r.out) && /nano, version/.test(r.out) && /No such file/.test(r.out), r.out);
		r = await b.run("apk del -q tree && apk add -q --no-progress lua5.4 && lua5.4 -v; apk info -e tree; apk fix --simulate 2>&1 | head; apk upgrade --simulate | head -3", 300000);
		check("update: apk del tree, apk add lua5.4 work; apk fix has nothing to do", /Lua 5\.4/.test(r.out) && !/^tree$/m.test(r.out) && !/ERROR|WARNING/.test(r.out), r.out);
		r = await b.run("cat /etc/apk/world | tr '\\n' ' '; ls /data/overlay | tr '\\n' ' '");
		check("update: world = image 2's - musl-utils + htop + lua5.4", /htop/.test(r.out) && /lua5\.4/.test(r.out) && /nano/.test(r.out) && !/musl-utils/.test(r.out) && !/\btree\b/.test(r.out), r.out);
		await b.poweroff();
		await expectOverlay(img, "update", { kernel: image2 });
		// The same without the zlib upgrade: the copy of the database in the
		// changes says zlib 1.3.2, image 2 has 1.4.
		const imgB = fresh();
		b = boot(imgB, { net: true });
		await b.prompt();
		await b.run("apk update -q && apk add -q --no-progress htop; sync", 300000);
		await b.poweroff();
		b = boot(imgB, { kernel: image2 });
		await b.prompt(120000);
		check("update (zlib not upgraded): the image's zlib replaces the old entry", /now the image's version: zlib 1\.3\.2-r1 -> 1\.4-r0/.test(b.out), b.out.slice(b.out.indexOf("kw-overlay: the root image")));
		r = await b.run(`${pkgs}; ${audit} | wc -l; echo; htop --version | head -1`);
		check("update (zlib not upgraded): apk info, audit and htop agree", /zlib-1\.4-r0/.test(r.out) && !/zlib-1\.3/.test(r.out) && /nano-9/.test(r.out) && /htop-3/.test(r.out) && /htop 3/.test(r.out) && r.out.includes(`${audit2.split("\n").length}\n`), r.out);
		await b.poweroff();
	},
};
async function hangCase(name, code) {
	const img = fresh();
	let b = boot(img); await b.prompt();
	await b.run(`echo '${code}' > /etc/profile.d/zz-${name}.sh; sync`);
	await b.poweroff();
	for (const n of [1, 2]) {
		b = boot(img);
		await b.wait(/Welcome to /); // init runs (the hang is in the login shell's profile)
		if (n === 1) {
			await b.wait(/no shell prompt after 20 s/, 40000);
			check(`${name}: bootwatch hints after 20 s`, true);
		} else await sleep(4000);
		check(`${name}: boot ${n} shows no prompt`, !PROMPT.test(b.out));
		await b.kill();
	}
	b = await expectSafe(img, name, /the last 2 boots with your root changes did not reach a shell prompt/);
	await b.run(`rm /data/overlay/upper/etc/profile.d/zz-${name}.sh; kw-overlay restore`);
	await b.poweroff();
	await expectOverlay(img, `${name} repaired`);
}

try {
	// The prepared disk: created from the template, with /root/keep.txt.
	const b = boot(base);
	await b.prompt();
	const t0 = /^(\d+\.\d+)/m.exec((await b.run("cut -d' ' -f1 /proc/uptime")).out);
	auditBase = (await b.run("apk audit | sort")).out; // the image's own changes to /etc
	await b.run(`echo ${marker} > /root/keep.txt; sync`);
	check("prepared disk: overlay root by default", /^overlay$/m.test((await b.run(rootType)).out), t0 ? `prompt at ${t0[1]} s` : "");
	await b.poweroff();
	const names = Object.keys(cases).filter((n) => (only?.length ? only.includes(n) : n === "apk" ? args.includes("--apk") : n === "update" ? !!opt("image2") : true));
	for (const n of names) {
		console.log(`== ${n}`);
		try { await cases[n](); } catch (e) { check(`${n}: exception`, false, e.stack ?? e.message); }
		killAll(); // a failed case may leave its boot running
		await sleep(200);
	}
} catch (e) {
	check("exception", false, e.stack ?? e.message);
} finally {
	killAll();
	await sleep(200);
	if (!args.includes("--keep")) rmSync(dir, { recursive: true, force: true });
	else console.log(`kept ${dir}`);
}
const ok = results.length > 0 && results.every(Boolean);
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
