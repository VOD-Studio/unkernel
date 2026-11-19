#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// unkernel CLI: boot the kernel under Node with the console on stdio.
// Usage below (`unkernel --help`); exit codes: 0 power off, 1 halt (or boot
// failure), 2 restart, 124 --timeout, 253 panic, 254 wasm trap, 255 fatal.

import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { availableParallelism } from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { BlockDevice } from "./core/block.ts";
import type { DiskSpec, NetSpec } from "./core/devices.ts";
import { frameToPpm, type DisplayMode } from "./core/display.ts";
import { BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, domCodeToLinux, type InputState } from "./core/input.ts";
import { KernelInstance, createKernelOn, type KernelHandle } from "./core/instance.ts";
import { decodeSnapshot, encodeSnapshot, type KernelSnapshot } from "./core/snapshot.ts";
import { bundledBoot, moduleIsMemory64, type ExitResult } from "./core/kernel.ts";
import { smpKernelFromBundle } from "./core/kpatch.ts";
import type { MountsOption } from "./core/mounts.ts";
import { NetStack } from "./core/net.ts";
import type { JitStats, KwemuStats } from "./core/jit.ts";
import { createImageFromKwsparse, openDisk } from "./node/disk.ts";
import { directBackend, wispBackend } from "./node/net.ts";
import { nodeFs } from "./node/nodefs.ts";
import { nodePlatform } from "./node/platform.ts";
import { cliSound } from "./node/sound.ts";

// Next to this file, like the Node entry's (this module is an entry too, so
// the URL stays relative to dist/cli.mjs; in a source checkout js/ has a
// symlink to vendor/build/bundle/unkernel-alpine.wasm).
const bundledKernelUrl = new URL("./unkernel-alpine.wasm", import.meta.url);

const USAGE = `Usage: unkernel [kernel.wasm | --kernel kernel.wasm] [--initrd alpine|none|NAME|file.cpio[.gz]]
       [--mem MiB] [--append "cmdline"] [--timeout seconds] [--input "text"] [--input-delay seconds]
       [--size COLSxROWS] [--stats] [--disk image.ext4|URL]... [--snapshot]
       [--data FILE [--data-template FILE.kwsparse.gz]]
       [--no-net | --net-wisp URL] [--net-mtu N] [--no-jit] [--display[=WxH[@DPI]]]
       [--sound | --sound-wav FILE] [--no-vsock] [--shm] [--worker[=shared|messages]] [--smp N]
       [--mount HOSTDIR:GUESTPATH[:ro]]... [--forward HOSTPORT:GUESTPORT]...
       [--restore FILE]

With no arguments it boots Alpine from the bundled kernel (unkernel-alpine.wasm:
vmlinux32.wasm with the root fs and command line in custom sections), interactive
on this terminal; Ctrl-] quits. In a source checkout, any other --initrd (a NAME
from vendor/build/initramfs/, or a path) loads vendor/build/kernel/vmlinux32.wasm
plus that file. The kwtest smoke test is in a local build's Alpine (not in
releases): --append "console=hvc0 rdinit=/usr/bin/kwtest" (exit 0, or 1 on a
failure); with a release bundle add --initrd alpine-test.

--kernel (or a positional path) replaces the kernel: either build, or a bundle;
the memory type is detected from the module. A kernel with a bundled root fs
boots it unless --initrd is given. The wasm64 reference build is
--kernel vendor/build/kernel/vmlinux.

--disk attaches a kwblk disk (/dev/wda, then wdb, ...; repeatable): a disk image
file (read and written in place), or an http(s) URL served with Range support.
With a disk and no --initrd/--append, it boots "root=/dev/wda rw" without an
initramfs. --snapshot keeps writes to file images in memory (discarded at exit).

--data FILE attaches the persistent data disk (the ext4 file system labelled
kwdata that the page keeps in IndexedDB; Alpine mounts it at /data) after the
--disk disks: wda without --disk. If FILE does not exist it is created (sparse,
4 GiB) from the data disk template: --data-template, else the kernel's bundled
one (custom section unkernel.datadisk), else vendor/build/disk/kwdata.kwsparse.gz
(kernel/build.sh datadisk). An existing FILE is used in place, like --disk
(--snapshot applies too).

Networking (a user-mode NAT over host sockets) is on by default: --no-net
disables it, --net-mtu N sets the MTU handed out by DHCP. The guest is
10.0.2.15, gateway 10.0.2.2 (= host 127.0.0.1), DNS 10.0.2.3. --net-wisp URL
sends the guest's TCP through a Wisp server instead (handshake with
Origin: http://localhost, which wss://wisp.pi0.io:6680/ requires).

kwemu's JIT tier (hot riscv64 code compiled to WebAssembly) is on by default;
--no-jit runs the interpreter only. --stats prints its counters at exit, and
kwemu's own (exits, compiled share) from a kernel built by kernel/build.sh stats.

--worker runs the kernel in a worker thread (createKernel({ worker: true })),
with the disks and the network built there from specs; the display, the input
tokens and the sound work with it too. Console and evdev input and frames go
through shared memory (read by the worker while the kernel runs);
--worker=messages sends them as messages instead (handled when the kernel
yields, up to 20 ms while the guest is busy), --worker=shared insists on
shared memory. PCM and everything else are messages either way.

--smp N gives an SMP kernel (one built with CONFIG_SMP: kw_smp.config)
N CPUs, each another instance of the kernel in its own thread on a shared
memory, each with its own JIT; it implies --worker, and --stats prints the
JIT counters per CPU. A UP kernel runs on one CPU (a log line says so). Keep N
at or below the host's free CPU threads (it warns above os.availableParallelism()).
An SMP kernel has every device (their host side and their I/O stay with CPU 0),
but no snapshots.

--display gives the guest a display: /dev/fb0 (kwfb, 32 bpp XRGB8888), whose
memory exists while a program has it open; 640x480, or --display=WxH (the
kernel caps it at 1M pixels by dividing both sides by an integer; a program
may set its own size). --display=WxH@DPI also tells the guest the pixel
density, which it sees as the picture's physical size. Without it there is no
/dev/fb0. {fb=FILE} in --input saves the current frame. It also gives the guest
a keyboard, a mouse and an absolute pointer (a tablet; evdev: /dev/input/event0,
event1, event2), fed by these --input tokens, which reach the guest only while a
program has the device open:
{key=K} = press and release key K, {key=K:1} = press, {key=K:0} = release
(K: a Linux key code, or a DOM KeyboardEvent.code such as KeyA or ArrowUp),
{rel=DX,DY} = mouse motion, {btn=B:1} / {btn=B:0} = press / release button B
(left, right, middle, or a code), {wheel=N} = wheel clicks (positive = up);
for the tablet {abs=X,Y} = move to pixel X,Y of the current mode (or X%,Y% of
the picture), {abtn=B:1|0} and {awheel=N} as above.

--sound-wav FILE gives the guest a sound card (kwsnd: ALSA hw:0,0, i.e.
/dev/snd/pcmC0D0p, and OSS /dev/dsp; playback only) and writes what it plays
to FILE as a WAV, in the format of the first stream (later ones are
converted; gaps are not recorded). --sound gives the card and drops the
output. Without either there is no sound card. Try glimmer --test (with
--display: a 3 s test signal) or the game, glimmer, in the guest.

The guest has a vsock device (kwvsock: AF_VSOCK, guest CID 3, host CID 2)
with nothing listening on the host, so guest connections to CID 2 are
refused; the SDK's vm.vsock listens and connects. --no-vsock leaves it out:
the guest has no vsock transport (connect() fails with ENODEV).

--mount HOSTDIR:GUESTPATH mounts a host directory in the guest (repeatable):
the SDK serves it over 9p on vsock and the guest's kw9p mounts it once kwtty
answers (it needs vsock). :ro makes it read-only. Each guest write(2) reaches
the host as it happens; host changes show in the guest within 1 s. Files show
as root's; symlinks stay symlinks and are never followed on the host.

--forward HOSTPORT:GUESTPORT listens on the host's 127.0.0.1:HOSTPORT and
connects each connection to the guest's 127.0.0.1:GUESTPORT (repeatable), e.g.
--forward 8000:80 for a web server in the guest: through kwtty over vsock (the
SDK's vm.connect()), not the network, so it works with --no-net too, and it
needs vsock. Half-closes pass through; a refused guest port resets the host
connection.

--shm gives the guest kwshm (/dev/kwshm: guest programs export shmem files to
the host, which reads and writes their pages in place; the SDK's vm.shm). The
CLI itself opens nothing; it is there for kwtest's checks. Without it there is
no /dev/kwshm.

Interactive when stdin is a TTY (raw mode; Ctrl-] quits). With --input, the text
is typed into the console after boot (\\n = Enter, ^C = Ctrl-C, {N} = pause N
seconds, {sync} = ask the guest to sync, as the page does before the tab goes
away: it writes back all file systems and flushes its disks, and the time to
the next block flush is logged; {fb=FILE} = write the display's frame to FILE
as a PPM, with --display); handy for tests. Otherwise a piped stdin is
the console input.

Snapshots: {save=FILE} in --input saves the running machine to FILE and lets
it run on, {suspend=FILE} saves it and stops it (exit 0, no clean shutdown),
and --restore FILE resumes one instead of booting, with the same kernel (the
snapshot carries the memory size; --mem, --initrd and --append do not apply)
and the same devices (--no-net, --no-vsock, --display, --sound and --shm as
when it was saved), with or without --worker. --mount directories survive
(without --worker), with the guest's open files on them: pass the same
--mount options again (a file deleted meanwhile gives "Stale file handle").
Other vsock sessions (--forward connections) and the guest's TCP connections
do not survive a restore: the guest's ends are reset. Disks are not copied: pass the
same --disk and --data images, unchanged. A restore refuses a disk
that was written after the snapshot (by the guest running on after {save}, a
later boot, or another program), and the first write after a restore makes the
snapshot unrestorable. A writable image FILE gets a FILE.kwsnap with its write
generation when a snapshot first includes it.

The guest console (hvc0) gets the window size of stdout when it is a TTY, and
follows its resizes; --size COLSxROWS sets a fixed size instead.

Exit codes: 0 power off, 1 halt (kwtest on failure) or boot failure, 2 restart,
124 --timeout, 253 kernel panic, 254 wasm trap, 255 host runtime error.`;

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
	process.stdout.write(`${USAGE}\n`);
	process.exit(0);
}
const opt = (name: string, def?: string): string | undefined => {
	const i = args.indexOf(`--${name}`);
	return i >= 0 ? args[i + 1] : def;
};
const flag = (name: string) => args.includes(`--${name}`);

const positional = args[0] && !args[0].startsWith("--") ? args[0] : undefined;
const diskSpecs = args.flatMap((a, i) => (a === "--disk" ? [args[i + 1]!] : []));
const initrdOpt = opt("initrd", diskSpecs.length ? "none" : "alpine")!;
const kernelOpt = positional ?? opt("kernel");
// The default Alpine comes bundled in the kernel; anything else is vmlinux32.wasm + a cpio.
const kernelPath = kernelOpt ?? (initrdOpt === "alpine" ? fileURLToPath(bundledKernelUrl) : path.join(root, "vendor/build/kernel/vmlinux32.wasm"));
const memoryMiB = Number(opt("mem", "512"));
const timeout = Number(opt("timeout", "0"));
const scripted = opt("input");
const rel = (p: string) => path.relative(process.cwd(), p) || p;
const workerArg = args.find((a) => a === "--worker" || a.startsWith("--worker="));
const smpCpus = Number(opt("smp", "1"));
if (!Number.isInteger(smpCpus) || smpCpus < 1 || smpCpus > 32) {
	process.stderr.write("[host] --smp N: 1 to 32 CPUs\n");
	process.exit(1);
}
const hostCpus = availableParallelism();
if (smpCpus > hostCpus) {
	process.stderr.write(`[host] warning: --smp ${smpCpus} exceeds this host's ${hostCpus} CPU thread${hostCpus === 1 ? "" : "s"}; oversubscription can stall cross-CPU waits and TLB shootdowns\n`);
}
// SMP: every CPU in a worker, CPU 0 in the kernel worker.
const worker = !!workerArg || smpCpus > 1;
const workerTransport = workerArg?.slice(9);
if (workerTransport && workerTransport !== "shared" && workerTransport !== "messages") {
	process.stderr.write("[host] --worker=shared|messages\n");
	process.exit(1);
}

const t0 = performance.now();
let module: WebAssembly.Module;
try {
	let bytes: Uint8Array = readFileSync(kernelPath);
	// --smp N with a bundle that carries an SMP patch (kernel/tools/bundle.mjs --smp): boot the SMP kernel it makes.
	if (smpCpus > 1) {
		const tp = performance.now();
		const smp = await smpKernelFromBundle(bytes);
		if (smp) {
			bytes = smp;
			process.stderr.write(`[host] SMP kernel from the bundle's patch (${(performance.now() - tp).toFixed(0)} ms)\n`);
		}
	}
	module = await WebAssembly.compile(bytes as Uint8Array<ArrayBuffer>);
} catch (e) {
	const err = e as NodeJS.ErrnoException;
	const hint = err.code === "ENOENT" && !kernelOpt
		? (initrdOpt === "alpine" ? " (build it with kernel/build.sh bundle)" : " (build it with kernel/build.sh kernel)") : "";
	process.stderr.write(`[host] cannot load the kernel ${rel(kernelPath)}: ${err.message}${hint}\n`);
	process.exit(1);
}
const tCompile = performance.now() - t0;
const bundled = bundledBoot(module);
const useBundle = !!bundled.initrd && (opt("initrd") === undefined || (!kernelOpt && initrdOpt === "alpine"));
// A bare name (no "/" or ".") is an image from vendor/build/initramfs/.
const initrdPath = useBundle ? "bundled" : initrdOpt === "none" || /[/.]/.test(initrdOpt) ? initrdOpt
	: path.join(root, "vendor/build/initramfs", `${initrdOpt}.cpio`);
const cmdline = opt("append", useBundle && bundled.cmdline ? bundled.cmdline
	: diskSpecs.length && initrdPath === "none" ? "console=hvc0 root=/dev/wda rw" : "console=hvc0 rdinit=/init")!;
let initrd: Uint8Array | null | undefined;
try {
	initrd = useBundle ? undefined : initrdPath === "none" ? null : new Uint8Array(readFileSync(initrdPath));
} catch (e) {
	process.stderr.write(`[host] cannot load the initrd ${rel(initrdPath)}: ${(e as Error).message}\n`);
	process.exit(1);
}
process.stderr.write(`[host] kernel ${rel(kernelPath)}, initrd ${useBundle ? "bundled" : initrdPath === "none" ? "none" : rel(initrdPath)}\n`);
// Inline the disks are opened here; with --worker they cross as specs and the worker opens them.
const disks: BlockDevice[] = [];
const diskSpecsOut: DiskSpec[] = [];
const addDisk = async (spec: string) => {
	if (!worker) disks.push(await openDisk(spec, { snapshot: flag("snapshot") }));
	else diskSpecsOut.push(/^https?:\/\//.test(spec) ? { kind: "http", url: spec } : { kind: "file", path: spec, snapshot: flag("snapshot") });
};
const diskCount = () => disks.length + diskSpecsOut.length;
for (const spec of diskSpecs) await addDisk(spec);
const dataPath = opt("data");
if (dataPath) {
	if (!existsSync(dataPath)) {
		const tplPath = opt("data-template") ?? (bundled.datadisk ? undefined : path.join(root, "vendor/build/disk/kwdata.kwsparse.gz"));
		if (tplPath && !existsSync(tplPath)) {
			process.stderr.write(`[host] --data: no ${dataPath} and no template ${rel(tplPath)} (kernel/build.sh datadisk)\n`);
			process.exit(1);
		}
		const r = await createImageFromKwsparse(dataPath, tplPath ? readFileSync(tplPath) : bundled.datadisk!);
		process.stderr.write(`[host] data disk: created ${dataPath} (${r.size / 1048576} MiB) from ${tplPath ? rel(tplPath) : "the bundled template"}\n`);
	}
	await addDisk(dataPath);
	process.stderr.write(`[host] data disk: ${dataPath} is /dev/wd${String.fromCharCode(96 + diskCount())}\n`);
}

const log = (m: string) => process.stderr.write(m + "\n");
const wisp = opt("net-wisp");
const mtu = opt("net-mtu");
const useNet = !flag("no-net");
// With --worker the network crosses as a spec (Wisp from a spec sends NODE_WISP_HEADERS too).
const netSpec: NetSpec | undefined = useNet && worker
	? { kind: "net", backend: wisp ? { kind: "wisp", servers: wisp } : { kind: "direct" }, hostLoopback: !wisp, mtu: mtu ? Number(mtu) : undefined }
	: undefined;
const net = !useNet || worker ? undefined : new NetStack({
	backend: wisp ? wispBackend(wisp, { log }) : directBackend(),
	hostLoopback: !wisp, mtu: mtu ? Number(mtu) : undefined, log,
});

const restorePath = opt("restore");
let restore: KernelSnapshot | undefined;
if (restorePath) {
	try {
		restore = decodeSnapshot(new Uint8Array(readFileSync(restorePath)));
	} catch (e) {
		process.stderr.write(`[host] cannot load the snapshot ${rel(restorePath)}: ${(e as Error).message}\n`);
		process.exit(1);
	}
	process.stderr.write(`[host] restoring ${rel(restorePath)} (${restore.memory.byteLength / 1048576} MiB)\n`);
}

const sizeOpt = opt("size")?.match(/^(\d+)x(\d+)$/);
const consoleSize = sizeOpt ? { cols: Number(sizeOpt[1]), rows: Number(sizeOpt[2]) }
	: process.stdout.isTTY ? { cols: process.stdout.columns, rows: process.stdout.rows } : undefined;

// --display or --display=WxH.
const displayArg = args.find((a) => a.startsWith("--display="))?.slice(10).match(/^(\d+)x(\d+)(?:@(\d+))?$/);
if (args.some((a) => a.startsWith("--display=")) && !displayArg) {
	process.stderr.write("[host] --display=WxH[@DPI]: expected a size such as 1280x720 or 1280x720@96\n");
	process.exit(1);
}
const displaySize = displayArg
	? { width: Number(displayArg[1]), height: Number(displayArg[2]), dpi: displayArg[3] ? Number(displayArg[3]) : undefined }
	: undefined;
// --sound, --sound-wav FILE (node/sound.ts).
const sound = cliSound(opt("sound-wav"), flag("sound"), log);

// --mount HOSTDIR:GUESTPATH[:ro] (repeatable): host directories through nodeFs().
const mounts: MountsOption = {};
for (const [i, a] of args.entries()) {
	if (a !== "--mount") continue;
	const m = /^(.+?):(\/[^:]*)(?::(ro|rw))?$/.exec(args[i + 1] ?? "");
	if (!m) {
		process.stderr.write(`[host] --mount HOSTDIR:GUESTPATH[:ro], not ${JSON.stringify(args[i + 1] ?? "")}\n`);
		process.exit(1);
	}
	const dir = path.resolve(m[1]!);
	if (!existsSync(dir) || !statSync(dir).isDirectory()) {
		process.stderr.write(`[host] --mount: ${rel(dir)} is not a directory\n`);
		process.exit(1);
	}
	mounts[m[2]!] = { fs: nodeFs(dir), readOnly: m[3] === "ro" };
}
if (Object.keys(mounts).length && flag("no-vsock")) {
	process.stderr.write("[host] --mount needs vsock (the 9p server and kwtty run over it); drop --no-vsock\n");
	process.exit(1);
}

// --forward HOSTPORT:GUESTPORT (repeatable): host 127.0.0.1:HOSTPORT to the guest's 127.0.0.1:GUESTPORT.
const forwards: Array<{ host: number; guest: number }> = [];
for (const [i, a] of args.entries()) {
	if (a !== "--forward") continue;
	const m = /^(\d+):(\d+)$/.exec(args[i + 1] ?? "");
	const host = Number(m?.[1]), guest = Number(m?.[2]);
	if (!m || host < 1 || host > 65535 || guest < 1 || guest > 65535) {
		process.stderr.write(`[host] --forward HOSTPORT:GUESTPORT (ports 1 to 65535), not ${JSON.stringify(args[i + 1] ?? "")}\n`);
		process.exit(1);
	}
	forwards.push({ host, guest });
}
if (forwards.length && flag("no-vsock")) {
	process.stderr.write("[host] --forward needs vsock (kwtty connects in the guest); drop --no-vsock\n");
	process.exit(1);
}

const interactive = process.stdin.isTTY && !scripted;
let vm: KernelHandle;
let vmReady!: (vm: KernelHandle) => void;
const booted = new Promise<KernelHandle>((r) => (vmReady = r));
// Listen before booting, so a taken port fails at once; connections wait for the kernel.
const servers: Server[] = [];
for (const f of forwards) {
	const server = createServer({ allowHalfOpen: true, pauseOnConnect: true }, (sock) => void forward(sock, f.guest));
	try {
		await new Promise<void>((resolve, reject) => {
			server.once("error", reject);
			server.listen(f.host, "127.0.0.1", () => resolve());
		});
	} catch (e) {
		process.stderr.write(`[host] --forward ${f.host}:${f.guest}: ${(e as Error).message}\n`);
		process.exit(1);
	}
	server.on("error", (e) => log(`[host] forward ${f.host}: ${e.message}`));
	server.unref(); // the kernel keeps the process alive, not the listener
	servers.push(server);
	log(`[host] forwarding 127.0.0.1:${f.host} to the guest's 127.0.0.1:${f.guest}`);
}

// One forwarded connection: vm.connect(), then bytes both ways, with
// half-closes passed on (the guest's kwtty does the same on its side).
async function forward(sock: Socket, guestPort: number): Promise<void> {
	sock.on("error", () => {}); // reported as 'close'; the guest side is reset below
	let gs;
	try {
		gs = await (await booted).connect(guestPort);
	} catch (e) {
		log(`[host] forward to guest port ${guestPort}: ${(e as Error).message}`);
		sock.resetAndDestroy();
		return;
	}
	const writer = gs.writable.getWriter();
	const reader = gs.readable.getReader();
	sock.on("close", (hadError) => {
		if (hadError) writer.abort().catch(() => {});
		else void gs.close().catch(() => {});
	});
	// Host to guest; EOF is a half-close.
	sock.on("data", (chunk: Buffer) => {
		sock.pause();
		writer.write(new Uint8Array(chunk)).then(() => sock.resume(), () => sock.destroy());
	});
	sock.on("end", () => void writer.close().catch(() => {}));
	sock.resume();
	// Guest to host.
	try {
		for (;;) {
			const r = await reader.read();
			if (r.done) break;
			if (!sock.write(r.value)) await new Promise((resolve) => sock.once("drain", resolve).once("close", resolve));
		}
		sock.end();
	} catch {
		sock.resetAndDestroy(); // the guest side was reset
	}
}
try {
	const common = {
		kernel: module, initrd, cmdline, memoryMiB, consoleSize, log, jit: !flag("no-jit"), cpus: smpCpus, onOutput: (bytes: Uint8Array) => process.stdout.write(bytes),
		display: displaySize ?? flag("display"),
		onDisplay: (m: DisplayMode | null) => log(m ? `[host] display: ${m.width}x${m.height}, stride ${m.stride}` : "[host] display: closed"),
		onInput: (s: InputState) => log(`[host] evdev: keyboard ${s.keyboard ? "open" : "closed"}, mouse ${s.mouse ? "open" : "closed"}, tablet ${s.tablet ? "open" : "closed"}`),
		sound: sound.option,
		vsock: !flag("no-vsock"),
		shm: flag("shm"),
		mounts,
		restore,
	};
	vm = worker ? await createKernelOn(nodePlatform(bundledKernelUrl), {
		...common, worker: true, disks: diskSpecsOut, net: netSpec,
		shared: workerTransport === "messages" ? false : workerTransport === "shared" ? true : undefined,
		transferRestore: true,
	})
		: await createKernelOn(nodePlatform(bundledKernelUrl), { ...common, disks, net });
	if (worker) log(`[host] kernel worker: input and frames by ${vm.transport === "shared" ? "shared memory" : "messages"}`);
	vmReady(vm);
} catch (e) {
	process.stderr.write(`[host] boot failed: ${(e as Error).stack ?? e}\n`);
	process.exit(1);
}
// Inline the frame is read in place; with --worker it is a round trip (readFrame()).
const local = vm instanceof KernelInstance ? vm : undefined;

if (!sizeOpt && process.stdout.isTTY) process.stdout.on("resize", () => vm.resize(process.stdout.columns, process.stdout.rows));

if (interactive) {
	process.stdin.setRawMode(true);
	process.stdin.on("data", (d: Buffer) => {
		if (d.includes(0x1d)) {
			process.stderr.write("\n[host] Ctrl-] pressed, exiting\n");
			finish({ code: 0, reason: "user quit", kind: "stopped" });
		}
		vm.write(new Uint8Array(d));
	});
} else if (scripted) {
	// "\n" = Enter, "^C" = Ctrl-C, "{N}" = wait N seconds before the rest,
	// "{sync}" = request a sync, "{fb=FILE}" = save the display's frame,
	// "{save=FILE}", "{suspend=FILE}" = save a snapshot (and stop),
	// {key=..}, {rel=..}, {btn=..}, {wheel=..}, {abs=..}, {abtn=..}, {awheel=..} = evdev input.
	const parts = scripted.replace(/\\n/g, "\n").replace(/\^C/g, "\x03").split(/\{([\d.]+|sync|(?:fb|save|suspend|key|rel|btn|wheel|abs|abtn|awheel)=[^}]+)\}/);
	let at = Number(opt("input-delay", "0")) * 1000;
	parts.forEach((p, i) => {
		if (i % 2 && p === "sync") setTimeout(requestSync, at);
		else if (i % 2 && p.startsWith("fb=")) setTimeout(() => void dumpFrame(p.slice(3)), at);
		else if (i % 2 && p.startsWith("save=")) setTimeout(() => void saveSnapshot(p.slice(5), false), at);
		else if (i % 2 && p.startsWith("suspend=")) setTimeout(() => void saveSnapshot(p.slice(8), true), at);
		else if (i % 2 && /^(key|rel|btn|wheel|abs|abtn|awheel)=/.test(p)) setTimeout(() => injectInput(p), at);
		else if (i % 2) at += Number(p) * 1000;
		else if (p) setTimeout(() => vm.write(p), at);
	});
} else if (!process.stdin.isTTY) {
	process.stdin.on("data", (d: Buffer) => vm.write(new Uint8Array(d)));
}

// {save=FILE}, {suspend=FILE}: snapshot the running machine into FILE
// (encodeSnapshot), and with stop, stop it. The exit waits for the file.
let snapshotWrite: Promise<void> | null = null;
function saveSnapshot(file: string, stop: boolean): Promise<void> {
	const p = (snapshotWrite ?? Promise.resolve()).then(() => writeSnapshot(file, stop));
	snapshotWrite = p;
	return p;
}
async function writeSnapshot(file: string, stop: boolean): Promise<void> {
	const t = performance.now();
	try {
		const snap = await vm.snapshot({ stop });
		const tSnap = performance.now() - t;
		const bytes = encodeSnapshot(snap);
		writeFileSync(file, bytes);
		process.stderr.write(`\n[host] snapshot: ${file}, ${(bytes.length / 1048576).toFixed(1)} MiB of ${snap.memory.byteLength / 1048576} MiB ` +
			`(${((snap.freeBytes ?? 0) / 1048576).toFixed(0)} MiB free left out, ` +
			`parked and copied in ${tSnap.toFixed(0)} ms, written in ${(performance.now() - t - tSnap).toFixed(0)} ms)\n`);
	} catch (e) {
		process.stderr.write(`\n[host] snapshot failed: ${(e as Error).message}\n`);
	}
}

// vm.sync() (the sync IRQ, as the page raises it) and log when every
// persistent disk has completed a flush issued after the request.
function requestSync(): void {
	const t = performance.now();
	process.stderr.write("\n[host] sync requested\n");
	void vm.sync({ timeout: 10000 }).then((ok) => process.stderr.write(ok
		? `[host] sync: block flush after ${(performance.now() - t).toFixed(0)} ms\n`
		: "[host] sync: no block flush within 10 s\n"));
}

// An evdev token from --input: key=K[:1|0], rel=DX,DY, btn=B:1|0, wheel=N,
// abs=X,Y (pixels of the mode, or X%,Y%), abtn=B:1|0, awheel=N.
function injectInput(token: string): void {
	const ev = vm.evdev;
	const [what, arg = ""] = token.split("=", 2) as [string, string];
	const note = (msg: string, ok: boolean): void => void process.stderr.write(`[host] evdev: ${msg}${ok ? "" : " (dropped: not open)"}\n`);
	if (!ev) return note(`${token} without --display`, false);
	const [a, state] = arg.split(":");
	if (what === "key") {
		const code = /^\d+$/.test(a!) ? Number(a) : domCodeToLinux(a!);
		if (code === undefined) return void process.stderr.write(`[host] evdev: unknown key ${a}\n`);
		const downs = state === undefined ? [true, false] : [state === "1"];
		for (const d of downs) note(`key ${code} ${d ? "down" : "up"}`, ev.key(code, d));
	} else if (what === "btn" || what === "abtn") {
		const code = a === "left" ? BTN_LEFT : a === "right" ? BTN_RIGHT : a === "middle" ? BTN_MIDDLE : Number(a);
		const downs = state === undefined ? [true, false] : [state === "1"];
		const tablet = what === "abtn";
		for (const d of downs) note(`${tablet ? "tablet " : ""}button ${code} ${d ? "down" : "up"}`, tablet ? ev.tabletButton(code, d) : ev.button(code, d));
	} else if (what === "abs") {
		// Pixels of the current mode (the centre of that pixel; without one, of
		// the size --display offers), or percentages.
		const m = vm.display?.mode ?? displaySize ?? { width: 640, height: 480 };
		const [x, y] = arg.split(",").map((v, i) => v.endsWith("%") ? Number(v.slice(0, -1)) / 100
			: (Number(v) + 0.5) / ((i ? m?.height : m?.width) ?? 1)) as [number, number];
		note(`tablet to ${arg} (${x.toFixed(5)}, ${y.toFixed(5)})`, ev.moveTo(x, y));
	} else if (what === "awheel") {
		note(`tablet wheel ${Number(arg)}`, ev.tabletWheel(Number(arg)));
	} else if (what === "rel") {
		const [dx = 0, dy = 0] = arg.split(",").map(Number);
		note(`motion ${dx},${dy}`, ev.move(dx, dy));
	} else if (what === "wheel") {
		note(`wheel ${Number(arg)}`, ev.wheel(Number(arg)));
	}
}

// Write the display's current frame as a PPM.
async function dumpFrame(file: string): Promise<void> {
	const f = local ? local.frame() : await vm.readFrame();
	if (!f) {
		process.stderr.write(`\n[host] fb: no frame for ${file} (${vm.display ? "no program has /dev/fb0 open" : "no --display"})\n`);
		return;
	}
	writeFileSync(file, frameToPpm(f));
	process.stderr.write(`\n[host] fb: wrote ${file} (${f.width}x${f.height})\n`);
}

// A -Dkwemu-stats kernel (kernel/build.sh stats): the lines the kwemu harness
// prints with --stats, from the layout in src/emu/kwemu.zig (Stats) and the
// exit counter indices in src/emu/jit.zig (Jx).
function printKwemuStats(k: KwemuStats): void {
	const nk = 192, base = k.words.length - 64, ic = Math.max(k.icount, 1);
	const w = (i: number): number => k.words[i] ?? 0, jx = (i: number): number => w(base + i);
	process.stderr.write(`[kwemu] instret=${k.icount} compiled insns=${(w(11 + nk) * 100 / ic).toFixed(2)}% handbacks=${w(12 + nk)}\n`);
	process.stderr.write(`[kwemu-exits] entries=${jx(0)} handbacks=${jx(1)} side=${jx(2)} (region ${jx(25)}) direct=${jx(3)} jalr=${jx(4)} stop=${jx(24)}\n`);
	process.stderr.write(`[kwemu-jx] ${k.words.slice(base).join(" ")}\n`);
	process.stderr.write(`[kwemu-stats] lookups_slow=${w(0)} revalidated=${w(1)} decoded=${w(2)} resets=${w(3)} blocks=${w(4)} ` +
		`insns/block=${(w(5) / Math.max(w(4), 1)).toFixed(2)} single_steps=${w(6)} walks r/w/x=${w(7)}/${w(8)}/${w(9)} generic=${w(10)}\n`);
}

function finish(res: ExitResult): never {
	if (interactive) process.stdin.setRawMode(false);
	sound.close(flag("stats") ? vm.stats().sound : undefined);
	if (flag("stats")) {
		const s = vm.stats();
		process.stderr.write(`[host] ${path.basename(kernelPath)} (${moduleIsMemory64(module) ? "memory64" : "32-bit memory"}), compile ${tCompile.toFixed(0)} ms, ran ${(s.uptimeMs / 1000).toFixed(2)} s, ` +
			`switches ${s.switches}, idles ${s.idles}, yields ${s.yields}\n`);
		if (s.display) process.stderr.write(`[host] display: ${s.display.attaches} attaches (opens and mode changes), ${s.display.detaches} closes\n`);
		if (s.evdev) process.stderr.write(`[host] evdev: ${s.evdev.delivered} events delivered, ${s.evdev.dropped} dropped\n`);
		const jitLine = (who: string, j: JitStats) => process.stderr.write(!j.requested ? `[host] ${who}: not in this kernel\n` : !j.enabled ? `[host] ${who}: off\n`
			: `[host] ${who}: ${j.compiled} compiled, ${j.live} live (max ${j.maxLive}), ${j.freed} freed, ${j.failed} failed, ` +
				`${j.compileMs.toFixed(0)} ms compiling ${(j.bytes / 1024).toFixed(0)} KiB (longest ${j.maxCompileMs.toFixed(2)} ms); ` +
				(j.collected < 0 ? "collection not tracked\n"
					: `${j.collected} collected, ${j.retained} freed but uncollected (max ${j.maxRetained}), ${j.gcNudges} GC nudges, ${j.refused} refused\n`));
		jitLine("jit", s.jit);
		s.jitCpus?.forEach((j, i) => jitLine(`jit cpu${i}`, j));
		if (s.kwemuCpus) {
			s.kwemuCpus.forEach((k, i) => {
				if (!k) return;
				process.stderr.write(`[kwemu] cpu${i}:\n`);
				printKwemuStats(k);
			});
		} else if (s.kwemu) printKwemuStats(s.kwemu);
		if (diskCount()) {
			const b = s.block;
			process.stderr.write(`[host] block: ${b.reads} reads (${(b.bytesRead / 1048576).toFixed(1)} MiB), ` +
				`${b.writes} writes (${(b.bytesWritten / 1048576).toFixed(1)} MiB), ${b.flushes} flushes, ` +
				`${b.discards} discards, ${b.async} async\n`);
		}
	}
	process.stderr.write(`[host] kernel exited: ${res.reason} (code ${res.code})\n`);
	process.exit(res.code);
}

if (timeout > 0) {
	setTimeout(() => finish({ code: 124, reason: `timeout after ${timeout}s`, kind: "stopped" }), timeout * 1000);
}
vm.exited.then(async (res) => {
	await snapshotWrite; // {suspend=FILE} stops the kernel before its file is written
	finish(res);
});
