// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// The public createKernel() API on the bundled Alpine kernel, inline and
// (where marked) also with `worker: true`, whose input and frames go through
// shared memory on Node unless `shared: false` (marked "worker, messages").
//
//   node --test test/api.test.ts                       # from source (js/node.ts)
//   UNKERNEL_DIST=1 node --test test/api.test.ts       # the built package ("unkernel" -> dist/)
//   UNKERNEL_TEST_WISP=1 ...                           # also the default Wisp server (internet)
//   UNKERNEL_TEST_KERNEL=path ...                      # another bundle instead of the bundled kernel
//   UNKERNEL_TEST_CPUS=n ...                           # CPUs for an SMP kernel under test (snapshot tests skipped)
//   UNKERNEL_TEST_CONCURRENCY=n ...                    # tests at once (default: the number of cores; 1 = in order)
//
// The tests run concurrently, each kernel stopped by its own test's cleanup. A
// suite marked "one kernel" boots once and runs its tests in order on it.
import test, { after, before, describe } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { availableParallelism, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const spec = process.env.UNKERNEL_DIST ? "unkernel" : "../js/node.ts";
const sdk: typeof import("../js/node.ts") = await import(spec);
const { createKernel, ConsoleRouter, NetStack, directBackend, wispBackend, DEFAULT_WISP_SERVERS, FileDisk, bundledBoot, bundledKernelUrl, createImageFromKwsparse, MemoryFs, nodeFs } = sdk;
type Instance = Awaited<ReturnType<typeof createKernel>>;
/** The kernel under test: UNKERNEL_TEST_KERNEL (a bundle, e.g. from a build of your own), else the bundled one. */
const testKernel = process.env.UNKERNEL_TEST_KERNEL ? path.resolve(process.env.UNKERNEL_TEST_KERNEL) : undefined;
const kernelFile = testKernel ?? fileURLToPath(bundledKernelUrl);
/** UNKERNEL_TEST_CPUS: CPUs to offer an SMP kernel under test; it has no snapshots. */
const testCpus = Number(process.env.UNKERNEL_TEST_CPUS) || undefined;
const noSnapshots = (testCpus ?? 1) > 1 && "SMP: no snapshots";

const PROMPT = /⇒/; // Alpine's shell prompt (kernel/guest/alpine.sh)
const CONCURRENCY = Number(process.env.UNKERNEL_TEST_CONCURRENCY) || Math.max(1, Math.floor(availableParallelism() / (testCpus ?? 1)));

/** Does the kernel under test have kwvsock (net/vmw_vsock/kwvsock.c) and kwshm (drivers/misc/kwshm.c)? */
const kernelBytes = readFileSync(kernelFile);
const kernelModule = await WebAssembly.compile(kernelBytes);
const kernelImports = WebAssembly.Module.imports(kernelModule);
/** 9p adds no import; its client's version string is in the kernel only with NET_9P (kw_defconfig). */
const kernelHas9p = kernelBytes.includes("9P2000.L");
const kernelHasVsock = kernelImports.some((i) => i.name === "wasm_driver_vsock_init");
const kernelHasShm = kernelImports.some((i) => i.name === "wasm_driver_shm_init");
const kernelIsSmp = kernelImports.some((i) => i.name === "wasm_cpu_start");
const kernelHasSmp = kernelIsSmp || WebAssembly.Module.customSections(kernelModule, "unkernel.kernel.smp.kwpatch").length > 0;

type BootOptions = NonNullable<Parameters<typeof createKernel>[0]>;
// A failed assertion must not leave a kernel running (it would keep the test process alive).
// Each test stops its own kernels: a shared afterEach would stop the kernels of tests still running.
const boot = async (t: { after(fn: () => unknown): void }, opts: BootOptions) => {
	const vm = await createKernel({ kernel: testKernel, cpus: testCpus, ...opts });
	t.after(() => vm.stop({ reason: "test cleanup" }));
	return vm;
};
/** One kernel for the tests of the calling suite, which then run in order on it; stopped when the suite ends. */
function sharedKernel(opts: () => BootOptions) {
	const k = {} as { vm: Instance } & ReturnType<typeof screen>;
	before(async () => {
		k.vm = await createKernel({ kernel: testKernel, cpus: testCpus, ...opts() });
		Object.assign(k, screen(k.vm));
	});
	after(async () => { await k.vm?.stop({ reason: "test cleanup" }); });
	return k;
}
const MODES = [{ worker: false, name: "inline" }, { worker: true, name: "worker" }] as const;
/** Also worker mode with messages for console and evdev input and frames (the transport of a browser page that is not cross-origin isolated). */
const TRANSPORTS = [
	{ worker: false, shared: undefined, name: "inline", transport: "inline" },
	{ worker: true, shared: undefined, name: "worker", transport: "shared" },
	{ worker: true, shared: false, name: "worker, messages", transport: "messages" },
] as const;

/** Collects console text and lets a test wait for a pattern. */
function screen(vm: Instance) {
	const dec = new TextDecoder();
	const s = { text: "" };
	let exit: string | undefined;
	void vm.exited.then((r) => { exit = r.reason; });
	const reader = vm.output.getReader();
	void (async () => {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			s.text += dec.decode(value, { stream: true });
		}
	})();
	const waitFor = async (re: RegExp, from = 0, ms = 60000) => {
		const end = Date.now() + ms;
		while (!re.test(s.text.slice(from))) {
			if (Date.now() > end) throw new Error(`timeout waiting for ${re}; screen tail:\n${s.text.slice(-1500)}`);
			if (exit !== undefined) throw new Error(`kernel exited (${exit}) waiting for ${re}`);
			await new Promise((r) => setTimeout(r, 50));
		}
	};
	return { s, waitFor };
}

describe("api", { concurrency: CONCURRENCY }, () => {
	// Powering off with exit code 0 is checked by the display, data disk, jit and device tests.
	for (const { worker, shared, name, transport } of TRANSPORTS) describe(`createKernel() with no devices, one kernel (${spec}, ${name})`, { concurrency: 1 }, () => {
		const stages: string[] = [], kernelLines: string[] = [];
		let user = "", userspace = "";
		const router = new ConsoleRouter({
			onKernelLine: (line) => kernelLines.push(line),
			onUserOutput: (t) => { user += t; },
			onUserspace: (why) => { userspace = why; },
		});
		const k = sharedKernel(() => ({
			worker, shared, log: () => {}, onProgress: (p) => stages.push(p.stage),
			onOutput: (b) => router.write(b), consoleSize: { cols: 100, rows: 30 },
		}));

		test("boots the bundled Alpine without a network and runs a command", async () => {
			const { vm, s, waitFor } = k;
			assert.equal(vm.transport, transport);
			assert.equal("kernel" in vm, !worker, "the low-level kernel only inline");
			assert.equal(vm instanceof sdk.WorkerKernel, worker);
			assert.equal(vm.memoryMiB, 512);
			assert.equal(vm.memory64, false);
			assert.ok(stages.includes("compiled") && stages.includes("memory") && stages.at(-1) === "start", stages.join(","));
			assert.match(vm.cmdline, /rdinit=/);
			await waitFor(PROMPT);
			assert.match(s.text, /Linux version/, "the stream starts at the first byte");
			const at = s.text.length;
			vm.write("uname -m; nproc; ls /sys/class/net | cat\n");
			await waitFor(/riscv64[\s\S]*⇒/, at);
			const out = s.text.slice(at);
			// stats().cpus: the CPUs the kernel got, which the guest sees (UNKERNEL_TEST_CPUS on an SMP kernel).
			const cpus = vm.stats().cpus;
			assert.equal(cpus, testCpus ?? 1);
			assert.match(out, new RegExp(`riscv64\\r?\\n${cpus}\\r?\\n`), "the guest's nproc is stats().cpus");
			assert.match(out, /\blo\b/);
			assert.doesNotMatch(out, /\beth0\b/, "no network device unless one is passed");
			assert.ok(vm.vsock, "a vsock device by default");
			assert.equal(vm.shm, undefined, "no shm device unless asked for");
		});

		test("ConsoleRouter splits kernel lines from user output; consoleSize, resize(), input stream", async () => {
			const { vm, s, waitFor } = k;
			let at = s.text.length;
			vm.write("stty size; echo marker-$((6*7))\n");
			await waitFor(/marker-42/, at);
			at = s.text.length;
			vm.resize(120, 40);
			const w = vm.input.getWriter();
			await w.write("stty size; echo resized-$((6*7))\n");
			w.releaseLock();
			await waitFor(/40 120[\s\S]*resized-42/, at);
			assert.ok(kernelLines.some((l) => /Linux version/.test(l)), "kernel log routed as kernel lines");
			assert.ok(!/Linux version/.test(user), "no kernel log in the user output");
			assert.match(user, /30 100/, "console size from consoleSize");
			assert.match(user, /marker-42/);
			assert.ok(userspace, "onUserspace fired");
		});

		// Four processes (spread over the CPUs of an SMP kernel at fork) print
		// 200 lines in turn, passing a token through FIFOs (each held open
		// read-write by its reader, so a token is never lost to a writer that
		// has not closed yet): the host must see them in that order (the
		// console ring, console-ring.ts).
		test("lines printed in turn by several processes arrive in order", async () => {
			const { vm, s, waitFor } = k;
			const at = s.text.length;
			vm.write("cd /tmp && mkfifo t0 t1 t2 t3 && for c in 0 1 2 3; do (exec 3<>t$c; i=$c; while [ $i -lt 200 ]; do read x <&3; echo ord-$i; i=$((i+4)); " +
				"[ $((i-3)) -lt 200 ] && echo > t$(((c+1)%4)); done) & done; echo > t0; wait; rm t0 t1 t2 t3; cd; echo ord-end-$((6*7))\n");
			await waitFor(/ord-end-42/, at);
			const got = [...s.text.slice(at).matchAll(/^ord-(\d+)\r?$/gm)].map((m) => Number(m[1]));
			assert.deepEqual(got, Array.from({ length: 200 }, (_, i) => i));
		});

		// The device not offered: the guest has no /dev/kwshm.
		if (!worker && kernelHasShm) test("shm: no /dev/kwshm without the option", async () => {
			const { vm, s, waitFor } = k;
			const at = s.text.length;
			vm.write("kwshm memfd 4096 < /dev/null; echo rc=$?\n");
			await waitFor(/rc=\d/, at);
			assert.match(s.text.slice(at), /kwshm: open \/dev\/kwshm: No such device[\s\S]*rc=1/);
		});

		test("stop() ends a running kernel", async () => {
			const { vm } = k;
			const res = await vm.stop({ reason: "test over" });
			assert.equal(res.kind, "stopped");
			assert.equal(res.reason, "test over");
			const st = vm.stats();
			assert.ok(st.switches > 0 && st.uptimeMs > 0 && st.compileMs > 0, JSON.stringify(st));
			assert.ok(st.jit.enabled, "JIT on by default");
			assert.equal(await vm.sync(), true, "sync() after the exit: nothing to flush");
		});
	});

	test("worker mode: exit codes (restart, panic), an AbortSignal stops it", async (t) => {
		await Promise.all([
			(async () => {
				const vm = await boot(t, { worker: true, log: () => {} });
				await screen(vm).waitFor(PROMPT);
				vm.write("reboot\n");
				assert.deepEqual(await vm.exited.then((r) => [r.code, r.kind]), [2, "halt"]);
			})(),
			// init exits at once: the kernel panics (253).
			(async () => {
				const vm = await boot(t, { worker: true, log: () => {}, cmdline: "console=hvc0 rdinit=/bin/true" });
				assert.equal(vm.cmdline, "console=hvc0 rdinit=/bin/true");
				assert.deepEqual(await vm.exited.then((r) => [r.code, r.kind]), [253, "panic"]);
			})(),
			(async () => {
				const ac = new AbortController();
				const vm = await boot(t, { worker: true, log: () => {}, signal: ac.signal });
				await screen(vm).waitFor(PROMPT);
				ac.abort();
				assert.deepEqual(await vm.exited.then((r) => [r.code, r.reason]), [130, "aborted"]);
			})(),
		]);
	});

	test("worker mode: the kernel from a relative path, bytes or a Module; an initrd from bytes", async (t) => {
		const file = kernelFile;
		const bytes = new Uint8Array(readFileSync(file));
		const module = await WebAssembly.compile(bytes);
		const panics = { cmdline: "console=hvc0 rdinit=/bin/true", log: () => {} };
		await Promise.all([
			...[path.relative(process.cwd(), file), bytes, module].map(async (kernel) => {
				const vm = await boot(t, { worker: true, kernel, ...panics });
				assert.equal((await vm.exited).code, 253, `kernel from ${kernel.constructor.name}`);
			}),
			// compileInWorker: the worker loads and compiles it (its progress is forwarded).
			...[path.relative(process.cwd(), file), bytes].map(async (kernel) => {
				const stages: string[] = [];
				const vm = await boot(t, { worker: true, compileInWorker: true, kernel, ...panics, onProgress: (p) => stages.push(p.stage) });
				assert.equal((await vm.exited).code, 253, `compileInWorker, kernel from ${kernel.constructor.name}`);
				assert.ok(stages.indexOf("worker") < stages.indexOf("compiled") && vm.stats().compileMs > 0, stages.join(","));
			}),
			// The bundled root fs as an explicit initrd: same boot.
			(async () => {
				const initrd = bundledBoot(module).initrd!;
				const vm = await boot(t, { worker: true, kernel: module, initrd, cmdline: "console=hvc0 rdinit=/init", log: () => {} });
				await screen(vm).waitFor(PROMPT);
				vm.write("poweroff\n");
				assert.equal((await vm.exited).code, 0);
			})(),
			assert.rejects(createKernel({ worker: true, kernel: "/nonexistent/kernel.wasm", log: () => {} }),
				(e: Error) => e.name === "BootError" && (e as InstanceType<typeof sdk.BootError>).stage === "download" && /nonexistent/.test(e.message)),
		]);
		assert.equal(bytes.byteLength, readFileSync(file).byteLength, "the caller's bytes are not detached");
	});

	test("worker mode rejects device objects (naming the spec instead)", async (t) => {
		const disk = { size: 1 << 20, read: () => {} } as unknown as import("../js/node.ts").BlockDevice;
		await assert.rejects(createKernel({ worker: true, disks: [{ kind: "file", path: "/nonexistent" }, disk] }), (e: Error) =>
			e.name === "BootError" && /disks\[1\] is a BlockDevice object, which cannot cross to the worker; pass a spec instead: \{ kind: "file", path \}/.test(e.message));
		await assert.rejects(createKernel({ worker: true, net: directBackend() }), (e: Error) =>
			e.name === "BootError" && /net is a NetDevice or NetBackend object.*\{ kind: "net", backend: \{ kind: "direct" \} \}/.test(e.message));
		// A spec of a kind nobody registered, and a spec that cannot be built.
		await assert.rejects(createKernel({ worker: true, disks: [{ kind: "nope" } as never], log: () => {} }), (e: Error) =>
			e.name === "BootError" && /disk kind "nope" is not available on this platform/.test(e.message));
		await assert.rejects(createKernel({ worker: true, disks: [{ kind: "file", path: "/nonexistent/disk.img" }], log: () => {} }), (e: Error) =>
			e.name === "BootError" && /disk 0 \(file\): .*ENOENT/.test(e.message));
		// Empty or off is fine (and the boot is real).
		const vm = await boot(t, { worker: true, disks: [], display: false, sound: false, cmdline: "console=hvc0 rdinit=/bin/true", log: () => {} });
		assert.equal((await vm.exited).code, 253);
	});

	for (const { worker, shared, name } of TRANSPORTS) test(`display, evdev and sound: glimmer --test draws a frame of the size offered, reads a key, plays PCM; mode changes reported (${name})`, async (t) => {
		type Mode = { width: number; height: number; stride: number } | null;
		const modes: Mode[] = [], inputs: string[] = [], events: string[] = [];
		const chunks: Array<{ rate: number; channels: number; format: number; frames: number }> = [];
		let size = { width: 320, height: 240 };
		const vm = await boot(t, {
			worker, shared, log: () => {},
			display: () => size,
			onDisplay: (m) => modes.push(m && { width: m.width, height: m.height, stride: m.stride }),
			onInput: (st) => inputs.push(`${+st.keyboard}${+st.mouse}${+st.tablet}`),
			sound: {
				rate: 48000,
				onState: (_st, ev) => events.push(ev),
				onChunk: (c) => { chunks.push({ rate: c.format.rate, channels: c.format.channels, format: c.format.format, frames: c.frames }); return 0; },
			},
		});
		const { s, waitFor } = screen(vm);
		await waitFor(PROMPT);
		// Nothing is open before a program opens a device: an in-kernel input handler that opens the
		// keyboard (sysrq did, before it became a passive observer) would send every key to evdev.
		assert.deepEqual(vm.evdev!.state, { keyboard: false, mouse: false, tablet: false }, inputs.join(","));
		assert.equal(inputs.length, 0, `no open reported at boot: ${inputs.join(",")}`);
		let at = s.text.length;
		vm.write("glimmer --test 2\n");
		await waitFor(/glimmer: test ready/, at);
		assert.deepEqual(modes, [{ width: 320, height: 240, stride: 1280 }]);
		assert.deepEqual(vm.display?.mode && { w: vm.display.mode.width, h: vm.display.mode.height }, { w: 320, h: 240 });
		const f = await vm.readFrame();
		assert.ok(f, "a frame while glimmer holds the picture");
		assert.deepEqual([f.width, f.height, f.data.length], [320, 240, 320 * 240 * 4]);
		const px = (x: number, y: number) => [...f.data.subarray((y * 320 + x) * 4, (y * 320 + x) * 4 + 4)];
		assert.deepEqual([px(0, 0), px(4, 4), px(315, 4), px(4, 235)], [[255, 255, 255, 255], [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]], "glimmer's test pattern, as RGBA");
		assert.deepEqual(vm.frame()?.data, f.data, "frame() has the same picture");
		// The keyboard is open once glimmer listed the devices: a key press and release reach it.
		const ev = vm.evdev!;
		assert.ok(ev.keyboardOpen && ev.tabletOpen && inputs.at(-1)?.startsWith("1"), inputs.join(","));
		assert.equal(ev.key(30, true), true);
		assert.equal(ev.key(30, false), true);
		assert.equal(ev.key(31, false), false, "a release of a key the guest never saw");
		await waitFor(/glimmer: event event\d+ EV_KEY 30 1[\s\S]*EV_KEY 30 0/, at);
		await waitFor(/glimmer: test sound done/, at, 30000);
		await waitFor(PROMPT, s.text.length - 200);
		await new Promise((r) => setTimeout(r, 300));
		assert.equal(modes.at(-1), null, "the close is reported");
		assert.deepEqual(ev.state, { keyboard: false, mouse: false, tablet: false }, inputs.join(","));
		assert.equal(ev.moveTo(0.5, 0.5), false, "no motion while nothing reads the tablet");
		assert.equal(ev.key(30, true), false, "no presses while nothing reads the keyboard");
		assert.deepEqual([...new Set(chunks.map((c) => `${c.rate}/${c.channels}/${c.format}`))], ["22050/2/2"], "the test signal: 22050 Hz, stereo, S16_LE");
		assert.equal(chunks.reduce((n, c) => n + c.frames, 0), 66150, "3 s of it");
		assert.deepEqual([events[0], events.at(-1)], ["open", "close"], events.join(","));
		assert.ok(events.includes("prepare") && events.includes("start"), events.join(","));
		assert.equal(vm.sound?.state.open, false);
		// Another size offered: the next program gets it (worker mode: sent ahead, the kernel cannot ask this thread).
		size = { width: 400, height: 300 };
		if (vm instanceof sdk.WorkerKernel) vm.updateDisplaySize();
		at = s.text.length;
		vm.write("glimmer --test 1 --no-sound\n");
		await waitFor(/glimmer: test done/, at);
		await waitFor(PROMPT, s.text.length - 200);
		await new Promise((r) => setTimeout(r, 300));
		assert.deepEqual(modes.slice(-2), [{ width: 400, height: 300, stride: 1600 }, null]);
		vm.write("poweroff\n");
		const res = await vm.exited;
		assert.deepEqual({ code: res.code, kind: res.kind }, { code: 0, kind: "halt" });
		const st = vm.stats();
		assert.ok(st.display && st.display.attaches === 2 && st.display.detaches === 2, JSON.stringify(st.display));
		assert.ok(st.evdev && st.evdev.delivered >= 4, JSON.stringify(st.evdev));
		assert.ok(st.sound && st.sound.frames === 66150, JSON.stringify(st.sound));
	});

	for (const shared of [true, false]) test(`worker mode with a busy guest (${shared ? "shared memory" : "messages"}): 150 KB of console input arrives whole and in order; readFrame() and keys while it runs`, async (t) => {
		const vm = await boot(t, { worker: true, shared, log: () => {}, display: { width: 320, height: 240 } });
		assert.equal(vm.transport, shared ? "shared" : "messages");
		const { s, waitFor } = screen(vm);
		await waitFor(PROMPT);
		vm.write("(while :; do :; done) & stty -echo; cat > /tmp/paste; stty echo; echo got-$((6*7))\n");
		await new Promise((r) => setTimeout(r, 300));
		// More than the 64 KiB ring: the rest waits on this side and follows in order.
		let text = "";
		for (let i = 0; i < 1500; i++) text += `${String(i).padStart(5, "0")} ${"abcdefghijklmnopqrstuvwxyz0123456789".repeat(3)}${i % 7 ? "" : " ünïcödé"}\n`;
		const bytes = new TextEncoder().encode(text);
		assert.ok(bytes.length > 150000, String(bytes.length));
		for (let i = 0; i < bytes.length; i += 4000) vm.write(bytes.subarray(i, i + 4000));
		vm.write("\x04");
		await waitFor(/got-42/, 0, 120000);
		const { createHash } = await import("node:crypto");
		const at = s.text.length;
		vm.write("wc -c < /tmp/paste; md5sum /tmp/paste\n");
		await waitFor(/[0-9a-f]{32}/, at);
		assert.match(s.text.slice(at), new RegExp(`\\b${bytes.length}\\b`));
		assert.match(s.text.slice(at), new RegExp(createHash("md5").update(bytes).digest("hex")));
		// glimmer while the loop runs: a fresh frame and a key press.
		vm.write("glimmer --test 3 --no-sound\n");
		await waitFor(/glimmer: test ready/, at);
		const f = await vm.readFrame();
		assert.deepEqual(f && [f.width, f.height, [...f.data.subarray(0, 4)]], [320, 240, [255, 255, 255, 255]]);
		const k0 = s.text.length;
		assert.equal(vm.evdev!.key(30, true), true);
		assert.equal(vm.evdev!.key(30, false), true);
		await waitFor(/EV_KEY 30 1[\s\S]*EV_KEY 30 0/, k0);
		await waitFor(/glimmer: test done/, at);
		await vm.stop();
	});

	test("WorkerKernel: sync() is a round trip, and a request the worker never answered resolves false with a persistent disk", async () => {
		// A stand-in worker: records what is posted, and lets the test answer.
		type Msg = { t: string; id?: number };
		const make = () => {
			const posted: Msg[] = [];
			let h!: { message(m: unknown): void; error(e: unknown): void; exit(): void };
			const endpoint = { post: (m: Msg) => posted.push(m), listen: (x: typeof h) => { h = x; }, terminate: () => {} };
			const vm = new sdk.WorkerKernel(endpoint as never, { onProgress: () => {}, log: () => {} });
			return { vm, posted, h: () => h };
		};
		const stats = { switches: 0, idles: 0, yields: 0, uptimeMs: 1, compileMs: 0, block: {}, jit: {} };
		const disk = (persistent: boolean) => ({ index: 0, kind: "file", size: 512, readOnly: false, persistent, flushSeq: 0, saving: false });
		for (const persistent of [true, false]) {
			const { vm, posted, h } = make();
			h().message({ t: "started", cmdline: "", memoryMiB: 1, memory64: false, stats, disks: [disk(persistent)], skipped: [] });
			await vm.started;
			const answered = vm.sync({ timeout: 50 });
			const sync = posted.find((m) => m.t === "sync")!;
			assert.equal((sync as { timeout?: number }).timeout, 50);
			h().message({ t: "synced", id: sync.id, ok: false });
			assert.equal(await answered, false, "the worker's answer is the result");
			const open = vm.sync();
			h().exit(); // the worker died with the request open
			assert.equal(await open, !persistent);
			assert.equal((await vm.exited).kind, "fatal");
			assert.equal(await vm.sync(), true, "after the exit: nothing can become dirty");
		}
	});

	for (const { worker, name } of MODES) test(`data disk from the bundled template: sync() saves what the guest has not written back (${name}${worker ? ", a file disk spec" : ""})`, async (t) => {
		const dir = mkdtempSync(path.join(tmpdir(), "unkernel-api-"));
		try {
			const module = await WebAssembly.compile(readFileSync(kernelFile));
			const tpl = bundledBoot(module).datadisk;
			assert.ok(tpl, "the bundle carries the data disk template (kernel/build.sh datadisk)");
			const file = path.join(dir, "data.img");
			await createImageFromKwsparse(file, tpl);
			// Inline: a FileDisk object (the caller closes it); worker: a spec, built and closed in the worker.
			let disk: InstanceType<typeof FileDisk> | undefined;
			const disks = () => (worker ? [{ kind: "file" as const, path: file }] : [disk = new FileDisk(file)]);
			let vm = await boot(t, { worker, kernel: module, disks: disks(), log: () => {} });
			let { s, waitFor } = screen(vm);
			await waitFor(PROMPT);
			let at = s.text.length;
			// Slow the guest's writeback and journal commits down: only the sync request gets the file out.
			vm.write("echo 360000 > /proc/sys/vm/dirty_expire_centisecs; echo 360000 > /proc/sys/vm/dirty_writeback_centisecs; " +
				"mount -o remount,commit=600 /data && echo kept-$((6*7)) > /data/kept.txt && echo written\n");
			await waitFor(/^written/m, at);
			assert.equal(await vm.sync({ timeout: 10000 }), true, "the kernel confirms the sync with a flush");
			if (vm instanceof sdk.WorkerKernel) {
				const d = vm.disks[0]!;
				assert.deepEqual({ index: d.index, kind: d.kind, persistent: d.persistent, readOnly: d.readOnly, size: d.size }, { index: 0, kind: "file", persistent: true, readOnly: false, size: 4 * 2 ** 30 });
			}
			assert.equal((await vm.stop({ reason: "no clean shutdown" })).kind, "stopped");
			disk?.close();

			vm = await boot(t, { worker, kernel: module, disks: disks(), log: () => {} });
			({ s, waitFor } = screen(vm));
			await waitFor(PROMPT);
			at = s.text.length;
			vm.write("cat /data/kept.txt\n");
			await waitFor(/kept-42/, at);
			vm.write("poweroff\n");
			assert.equal((await vm.exited).code, 0);
			disk?.close();
			if (vm instanceof sdk.WorkerKernel) assert.ok(vm.disks[0]!.flushSeq > 0 && vm.stats().block.flushes > 0, "the final snapshot has the flushes");
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});

	test("jit option: kwemu's JIT tier compiles hot guest code when on (the default) and nothing when off", async (t) => {
		// sha256 over busybox (~1 MiB) runs well past the 2^17-instruction threshold.
		const run = async (jit: boolean | undefined) => {
			const logs: string[] = [];
			const vm = await boot(t, { log: (m) => logs.push(m), ...(jit === undefined ? {} : { jit }) });
			const { s, waitFor } = screen(vm);
			await waitFor(PROMPT);
			const at = s.text.length;
			vm.write("sha256sum /bin/busybox; echo jit-$((6*7))\n");
			await waitFor(/jit-42/, at);
			const sum = s.text.slice(at).match(/\b[0-9a-f]{64}\b/)?.[0];
			vm.write("poweroff\n");
			assert.equal((await vm.exited).code, 0);
			return { sum, st: vm.stats().jit, logs };
		};
		const [on, off] = await Promise.all([run(undefined), run(false)]);
		assert.ok(on.st.enabled && on.st.requested, JSON.stringify(on.st));
		assert.ok(on.st.compiled > 0 && on.st.compileMs > 0 && on.st.bytes > 0, JSON.stringify(on.st));
		assert.equal(on.st.failed, 0, on.logs.join("\n"));
		assert.equal(on.st.live, on.st.compiled - on.st.freed);
		assert.ok(on.st.maxLive >= on.st.live && on.st.maxLive <= 1024);
		assert.equal(on.st.refused, 0);
		assert.ok(on.st.collected >= 0 && on.st.retained === on.st.freed - on.st.collected, JSON.stringify(on.st));
		assert.deepEqual({ ...off.st, compileMs: 0 }, {
			enabled: false, requested: true, compiled: 0, live: 0, maxLive: 0, freed: 0, failed: 0, compileMs: 0, maxCompileMs: 0, bytes: 0,
			collected: 0, retained: 0, maxRetained: 0, gcNudges: 0, refused: 0,
		});
		assert.ok(on.sum && on.sum === off.sum, `same sha256 with and without the JIT: ${on.sum} vs ${off.sum}`);
	});

	test("JitHost: prompts a collection once freed modules pile up uncollected, refuses compiles at the limit", async () => {
		// A stand-in for the kernel: a memory holding one module in kwemu's shape
		// (imports env.memory, exports f: (i64, i64, i64, i64) -> i64) and a table of stubs.
		const T = [0x60, 4, 0x7e, 0x7e, 0x7e, 0x7e, 1, 0x7e];
		const mod = [0, 97, 115, 109, 1, 0, 0, 0, 1, 1 + T.length, 1, ...T, 2, 15, 1, 3, 101, 110, 118, 6, 109, 101, 109, 111, 114, 121, 2, 0, 0,
			3, 2, 1, 0, 7, 5, 1, 1, 102, 0, 0, 10, 6, 1, 4, 0, 0x20, 0, 0x0b];
		const memory = new WebAssembly.Memory({ initial: 1 });
		new Uint8Array(memory.buffer).set(mod, 64);
		const stub = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(mod)), { env: { memory } }).exports.f;
		const table = new WebAssembly.Table({ element: "anyfunc", initial: 8 });
		for (let i = 1; i < 8; i++) table.set(i, stub);
		const logs: string[] = [];
		const host = new sdk.JitHost({ memory: () => memory, memory64: () => false, log: (m) => logs.push(m), retainedNudge: 2, retainedLimit: 4 });
		host.attach({ __indirect_function_table: table });
		assert.equal(host.caps(), 3);
		// Finalizers never run inside one synchronous loop, so nothing is collected here.
		const results: number[] = [];
		for (let i = 0; i < 6; i++) {
			const r = host.compile(64, mod.length, 1 + (i % 7));
			results.push(r);
			if (r === 0) host.free(1 + (i % 7));
		}
		assert.deepEqual(results, [0, 0, 0, 0, -1, -1]);
		const st = host.stats;
		assert.deepEqual({ compiled: st.compiled, freed: st.freed, live: st.live, failed: st.failed, refused: st.refused, collected: st.collected, retained: st.retained, maxRetained: st.maxRetained },
			{ compiled: 4, freed: 4, live: 0, failed: 0, refused: 2, collected: 0, retained: 4, maxRetained: 4 });
		// Nudged on every compile (not on a free) with 2 or more uncollected: compiles 3-6.
		assert.equal(st.gcNudges, 4);
		assert.equal(table.get(1), stub);
		assert.equal(logs.length, 1, logs.join("\n"));
		// With a GC the modules are collected and compiling resumes.
		const gc = (globalThis as { gc?: () => void }).gc;
		if (gc) {
			for (let i = 0; i < 50 && host.stats.collected < 4; i++) {
				gc();
				await new Promise((r) => setTimeout(r, 20));
			}
			assert.equal(host.stats.collected, 4);
			assert.equal(host.stats.retained, 0);
			assert.equal(host.compile(64, mod.length, 1), 0);
			host.free(1);
		}
	});

	test("worker mode: Wisp from a net spec reaches a local Wisp server", async (t) => {
		const { withWisp } = await import("./net-helpers.ts");
		await withWisp(async (_b, seen, url) => {
			const vm = await boot(t, { worker: true, log: () => {}, net: { kind: "net", backend: { kind: "wisp", servers: [url] } } });
			const { s, waitFor } = screen(vm);
			await waitFor(PROMPT);
			const at = s.text.length;
			vm.write("wget -q -T 3 -O /dev/null http://echo.test/; echo wisp-tried\n");
			await waitFor(/^wisp-tried/m, at);
			assert.ok(seen.hosts.includes("echo.test:80"), JSON.stringify(seen));
			vm.write("poweroff\n");
			assert.equal((await vm.exited).code, 0);
		});
	});

	for (const { worker, name } of MODES) test(`Wisp networking through the default server (${name})`, { skip: !process.env.UNKERNEL_TEST_WISP && "set UNKERNEL_TEST_WISP=1 (needs internet)" }, async (t) => {
		const logs: string[] = [];
		const vm = await boot(t, { worker, log: (m) => logs.push(m), net: worker ? { kind: "net", backend: { kind: "wisp", servers: [...DEFAULT_WISP_SERVERS] } }
			: wispBackend(DEFAULT_WISP_SERVERS, { log: (m) => logs.push(m) }) });
		const { s, waitFor } = screen(vm);
		await waitFor(PROMPT);
		const at = s.text.length;
		vm.write("wget -q -O - http://example.com/ | grep -o '<title>.*</title>'; echo wisp-done\n");
		await waitFor(/wisp-done/, at, 90000);
		assert.match(s.text.slice(at), /<title>Example Domain<\/title>/, logs.join("\n"));
		vm.write("poweroff\n");
		assert.equal((await vm.exited).code, 0);
	});

	// Linux sends at most its own buffer (256 KiB) ahead of the host's credit and never asks for more,
	// so a host that waited for half of a larger buffer to fill before granting credit stalled it for good.
	test("vsock: a host buffer larger than the guest's window does not stall the guest's sends (inline)",
		{ skip: !kernelHasVsock && "the kernel under test has no kwvsock" }, async (t) => {
		const SIZE = 2 << 20;
		const vm = await boot(t, { log: () => {}, vsock: { bufferSize: 1 << 20 } });
		const { s, waitFor } = screen(vm);
		await waitFor(PROMPT);
		const l = vm.vsock!.listen(5000);
		const got = (async () => {
			const c = (await l.accept())!;
			let n = 0;
			for await (const chunk of c.readable) n += chunk.length;
			await c.writable.close();
			return n;
		})();
		const at = s.text.length;
		vm.write(`dd if=/dev/zero bs=65536 count=${SIZE / 65536} 2>/dev/null | kwvsock connect 5000; echo rc=$?\n`);
		await waitFor(/rc=0/, at, 30000);
		assert.equal(await got, SIZE);
		l.close();
		vm.write("poweroff\n");
		assert.equal((await vm.exited).code, 0);
	});

	// With kwshm, the device not offered is checked in the inline createKernel() suite.
	test("shm: the option on a kernel without kwshm", { skip: kernelHasShm && "the kernel under test has kwshm" }, async (t) => {
		// Requests fail at once with ENODEV.
		const vm = await boot(t, { log: () => {}, shm: true });
		assert.ok(vm.shm);
		await assert.rejects(vm.shm!.open("x"), (e: Error & { code?: string }) => e.code === "ENODEV");
		await assert.rejects(vm.shm!.openId(1), (e: Error & { code?: string }) => e.code === "ENOENT");
		await vm.stop();
	});

	/** FNV-1a 32, as kernel/guest/kwshm.c prints it. */
	const fnv32 = (b: Uint8Array) => {
		let h = 2166136261;
		for (let i = 0; i < b.length; i++) h = Math.imul(h ^ b[i]!, 16777619);
		return (h >>> 0).toString(16).padStart(8, "0");
	};
	/** kwshm.c's memfd pattern. */
	const shmPattern = (n: number, seed: number) => {
		const b = new Uint8Array(n);
		for (let i = 0, x = seed; i < n; i++) b[i] = (x = (Math.imul(x, 1103515245) + 12345) >>> 0) >>> 24;
		return b;
	};

	for (const { worker, name } of MODES) describe(`direct networking, vsock and shm, one kernel (${name})`, { concurrency: 1 }, () => {
		const net = worker ? { kind: "net" as const, backend: { kind: "direct" as const }, hostLoopback: true } : new NetStack({ backend: directBackend(), hostLoopback: true });
		const k = sharedKernel(() => ({
			worker, log: () => {}, net,
			// vsock: a small window (16 times smaller than the transfers) so the credit runs out over and over.
			...(kernelHasVsock && { vsock: { bufferSize: 64 * 1024 } }),
			...(kernelHasShm && { shm: true }),
		}));
		/** Shm handles the poweroff test checks. */
		const held: Array<import("../js/node.ts").ShmFile> = [];

		test(`direct networking: the guest fetches from a host HTTP server through the gateway${worker ? " (a net spec)" : ""}`, async () => {
			const http = createServer((_req, res) => res.end("hello from the host\n"));
			await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
			const port = (http.address() as AddressInfo).port;
			try {
				const { vm, s, waitFor } = k;
				await waitFor(PROMPT);
				const at = s.text.length;
				vm.write(`wget -q -O - http://10.0.2.2:${port}/ && echo fetch-ok\n`);
				await waitFor(/hello from the host[\s\S]*fetch-ok/, at);
				if (net instanceof NetStack) assert.ok(net.stats.tcpOpened >= 1);
				else {
					await new Promise((r) => setTimeout(r, 700)); // the next stats snapshot
					assert.ok(vm.stats().net!.tcpOpened >= 1, JSON.stringify(vm.stats().net));
				}
			} finally {
				http.close();
			}
		});

		test("vsock: guest to a host listener and host to a guest listener, 4 MiB each way by checksum under credit flow control, half-close, refused and reset",
			{ skip: !kernelHasVsock && "the kernel under test has no kwvsock" }, async (t) => {
			const { createHash } = await import("node:crypto");
			const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
			const SIZE = 4 << 20;
			const { vm, s, waitFor } = k;
			const v = vm.vsock!;
			assert.ok(v, "vm.vsock with the vsock option");
			// Inline: the host refuses some of the guest's packets for now; the kernel must send them again, in order.
			const dev = vm instanceof sdk.KernelInstance ? vm.kernel.vsock : undefined;
			if (dev) {
				dev.refuse = () => Math.random() < 0.05;
				t.after(() => { dev.refuse = undefined; });
			}
			await waitFor(PROMPT);
			assert.equal(v.guestCid, 3);

			// 1. The guest connects to a host listener that echoes everything back; both directions at once.
			const echo = v.listen(5000);
			assert.throws(() => v.listen(5000), (e: Error & { code?: string }) => e.code === "EADDRINUSE");
			const echoed = (async () => {
				const c = await echo.accept();
				assert.ok(c && c.localPort === 5000 && c.remotePort > 0);
				const hash = createHash("sha256");
				let n = 0;
				await c.readable.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
					transform(chunk, ctl) { hash.update(chunk); n += chunk.length; ctl.enqueue(chunk); },
				})).pipeTo(c.writable); // ends with a half-close once the guest's EOF arrives
				return { n, sum: hash.digest("hex"), closed: await c.closed };
			})();
			let at = s.text.length;
			vm.write(`head -c ${SIZE} /dev/urandom > /tmp/blob; kwvsock connect 5000 < /tmp/blob > /tmp/back; echo rc=$?; sha256sum /tmp/blob /tmp/back\n`);
			await waitFor(/rc=\d+[\s\S]*\/tmp\/back/, at, 120000);
			const out1 = s.text.slice(at);
			assert.match(out1, /rc=0/, out1);
			const blob = out1.match(/([0-9a-f]{64})\s+\/tmp\/blob/)?.[1], back = out1.match(/([0-9a-f]{64})\s+\/tmp\/back/)?.[1];
			const e = await echoed;
			assert.equal(e.n, SIZE);
			assert.equal(e.sum, blob, "what the host received is what the guest sent");
			assert.equal(back, blob, "what the guest received back is what it sent");
			assert.equal(e.closed, "closed", "an orderly close");
			echo.close();

			// 2. The host connects to a guest listener and sends 4 MiB; the guest has already
			// sent its reply and shut down its side (a half-close), so the host reads it, then EOF.
			at = s.text.length;
			vm.write("echo reply-$((6*7)) > /tmp/reply; kwvsock listen 5001 < /tmp/reply > /tmp/in; echo rc=$?; sha256sum /tmp/in\n");
			await waitFor(/kwvsock: listening on port 5001/, at);
			const data = new Uint8Array(SIZE);
			for (let i = 0, x = 12345; i < SIZE; i++) data[i] = (x = (x * 1103515245 + 12345) >>> 0) >>> 24;
			const c = await v.connect(5001);
			assert.ok(c.localPort >= 49152 && c.remotePort === 5001);
			const replyP = (async () => {
				const chunks: Uint8Array[] = [];
				for await (const chunk of c.readable) chunks.push(chunk);
				return new TextDecoder().decode(Buffer.concat(chunks));
			})();
			const w = c.writable.getWriter();
			for (let i = 0; i < SIZE; i += 100000) await w.write(data.subarray(i, i + 100000));
			await w.close();
			assert.equal(await replyP, "reply-42\n");
			assert.equal(await c.closed, "closed");
			await waitFor(/rc=\d+[\s\S]*\/tmp\/in/, at, 120000);
			const out2 = s.text.slice(at);
			assert.match(out2, /rc=0/, out2);
			assert.equal(out2.match(/([0-9a-f]{64})\s+\/tmp\/in/)?.[1], sha(data), "the guest got exactly what the host sent");

			// 3. Refused both ways, and a reset by the host while the guest sends.
			await assert.rejects(v.connect(5999), (e: Error & { code?: string }) => e.name === "VsockError" && e.code === "ECONNREFUSED");
			at = s.text.length;
			vm.write("kwvsock connect 5002 < /dev/null; echo rc=$?\n");
			await waitFor(/rc=\d/, at);
			assert.match(s.text.slice(at), /kwvsock: connect: Connection reset by peer[\s\S]*rc=1/);
			let resetClosed: Promise<string> | undefined;
			const rst = v.listen(5003, (conn) => {
				resetClosed = conn.closed;
				void (async () => {
					const r = conn.readable.getReader();
					await r.read();
					conn.reset();
					await r.read().catch(() => {});
				})();
			});
			at = s.text.length;
			vm.write("yes | kwvsock connect 5003 > /dev/null; echo rc=$?\n");
			await waitFor(/rc=\d/, at);
			assert.match(s.text.slice(at), /kwvsock: send: Broken pipe[\s\S]*rc=1/);
			assert.equal(await resetClosed, "reset");
			rst.close();

			const st = v.stats;
			assert.ok(st.accepted >= 2 && st.connected >= 1 && st.refused >= 2 && st.resets >= 1 && st.violations === 0, JSON.stringify(st));
			assert.ok(st.bytesIn > SIZE && st.bytesOut === 2 * SIZE, JSON.stringify(st)); // in: the blob, the reply, some of yes; out: the echo and the data
			if (dev) assert.ok(dev.stats.refused > 0, "the refusal path ran");
			assert.equal(st.open, 0, "nothing left open");
			assert.deepEqual(vm.stats().vsock, st);
		});

		test("shm: guest shmem files read and written in place by name and by a guest export's id; sparse, resized, refused, released",
			{ skip: !kernelHasShm && "the kernel under test has no kwshm" }, async () => {
			const { createHash } = await import("node:crypto");
			const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
			const { vm, s, waitFor } = k;
			const shm = vm.shm!;
			assert.ok(shm, "vm.shm with the shm option");
			await waitFor(PROMPT);
			let marks = 0;
			/** Run a shell line and wait for it to finish; returns its output. */
			const sh = async (cmd: string, ms = 60000) => {
				const m = `done-${++marks}`;
				const at = s.text.length;
				vm.write(`${cmd}; echo done-$((${marks}))\n`);
				await waitFor(new RegExp(`\\n${m}\\r?\\n`), at, ms);
				return s.text.slice(at);
			};
			const guestSha = async (file: string) => {
				const out = await sh(`sha256sum ${file}`);
				return out.match(new RegExp(`([0-9a-f]{64})\\s+${file.replace(/\//g, "\\/")}`))?.[1];
			};
			const rejects = (p: Promise<unknown>, code: string, what: string) =>
				assert.rejects(p, (e: Error & { code?: string }) => e.name === "ShmError" && e.code === code, what);

			// 1. A patterned 8 MiB file the guest wrote, read back by checksum.
			const BIG = 8 << 20;
			await sh(`dd if=/dev/urandom of=/dev/shm/big bs=65536 count=${BIG / 65536} 2>/dev/null`);
			const big = await shm.open("big");
			assert.deepEqual({ size: big.size, pages: big.pages, origin: big.origin, writable: big.writable, gen: big.generation, name: big.name },
				{ size: BIG, pages: BIG / 4096, origin: "host", writable: true, gen: 1, name: "big" });
			let content = await big.read();
			assert.equal(content.length, BIG);
			assert.equal(sha(content), await guestSha("/dev/shm/big"), "the host read what the guest wrote");
			assert.equal(sha(await big.read(4095, 10000)), sha(content.subarray(4095, 14095)), "an unaligned read across pages");
			if (!worker) {
				const views = (big as import("../js/node.ts").InlineShmFile).views(100, BIG - 200);
				assert.ok(views.length >= 1 && views.every((v) => v.buffer === (vm as import("../js/node.ts").KernelInstance).kernel.memory.buffer), "views of the kernel's memory");
				assert.equal(sha(Buffer.concat(views)), sha(content.subarray(100, BIG - 100)), "the views cover the range in order");
			} else {
				assert.throws(() => (big as unknown as { views(): unknown }).views(), (e: Error & { code?: string }) => e.code === "EOPNOTSUPP", "no views in worker mode");
			}

			// 2. The host writes into it (unaligned, across many pages); the guest sees the bytes.
			const patch = shmPattern(3 * 1048576 + 777, 99);
			await big.write(1048576 + 123, patch);
			content.set(patch, 1048576 + 123);
			assert.equal(await guestSha("/dev/shm/big"), sha(content), "the guest reads what the host wrote");
			await rejects(big.write(BIG - 10, new Uint8Array(11)), "EINVAL", "a write past the end");
			await rejects(big.read(BIG, 1), "EINVAL", "a read past the end");

			// 3. A file the host creates, for data to the guest.
			const CR = 5 * 1048576 + 100;
			const created = await shm.create("fromhost", CR, { mode: 0o644 });
			assert.equal(created.size, CR);
			assert.equal(sha(await created.read()), sha(new Uint8Array(CR)), "created as zeros");
			const fromHost = shmPattern(CR, 5);
			await created.write(0, fromHost);
			let out = await sh("stat -c '%s %a' /dev/shm/fromhost");
			assert.match(out, new RegExp(`\\n${CR} 644\\r?\\n`));
			assert.equal(await guestSha("/dev/shm/fromhost"), sha(fromHost), "the guest reads the host's file");
			await rejects(shm.create("fromhost", 10), "EEXIST", "create does not replace");

			// 4. A memfd the guest exports through /dev/kwshm; the host opens it by id.
			const MFD = 3000000;
			let at = s.text.length;
			vm.write(`kwshm memfd ${MFD} 7\n`);
			await waitFor(/kwshm: id=(\d+) size=(\d+) pages=(\d+) fnv=([0-9a-f]{8})/, at);
			const [, idS, sizeS, pagesS, fnvS] = s.text.slice(at).match(/kwshm: id=(\d+) size=(\d+) pages=(\d+) fnv=([0-9a-f]{8})/)!;
			assert.deepEqual([Number(sizeS), Number(pagesS)], [MFD, Math.ceil(MFD / 4096)]);
			const mfd = await shm.openId(Number(idS));
			assert.deepEqual({ size: mfd.size, origin: mfd.origin, writable: mfd.writable, name: mfd.name }, { size: MFD, origin: "guest", writable: true, name: undefined });
			const mfdData = await mfd.read();
			assert.equal(fnv32(mfdData), fnvS, "the guest's memfd as it wrote it");
			assert.equal(fnv32(mfdData), fnv32(shmPattern(MFD, 7)));
			const hello = new TextEncoder().encode("hello from the host");
			await mfd.write(5000, hello);
			mfdData.set(hello, 5000);
			at = s.text.length;
			vm.write("\n");
			await waitFor(/kwshm: fnv=([0-9a-f]{8}) size=/, at);
			assert.equal(s.text.slice(at).match(/kwshm: fnv=([0-9a-f]{8})/)![1], fnv32(mfdData), "the guest sees the host's write in its memfd");
			const second = await shm.openId(Number(idS));
			await second.close(); // a guest export: only this handle ends
			assert.equal(await second.closed, "closed");
			assert.equal(mfd.size, MFD, "the other handle still works");
			at = s.text.length;
			vm.write("q\n");
			assert.equal(await mfd.closed, "released", "the export dies with the guest's /dev/kwshm file");
			await waitFor(PROMPT, at);
			await rejects(mfd.read(0, 1), "EBADF", "a closed handle");
			await rejects(shm.openId(Number(idS)), "ENOENT", "the id is gone");
			// Released by ioctl, with the helper still running; an unlinked shm file, read-only for the host, a range.
			await sh("dd if=/dev/urandom of=/dev/shm/ranged bs=65536 count=4 2>/dev/null");
			const rangedSha = createHash("sha256");
			const rangedHost = await shm.open("ranged");
			rangedSha.update((await rangedHost.read()).subarray(8192, 8192 + 50000));
			await rangedHost.close();
			at = s.text.length;
			vm.write("kwshm export /dev/shm/ranged -u -r -o 8192 -l 50000\n");
			await waitFor(/kwshm: id=(\d+) size=50000 pages=13 /, at);
			const ranged = await shm.openId(Number(s.text.slice(at).match(/kwshm: id=(\d+) size=50000/)![1]));
			assert.deepEqual({ size: ranged.size, writable: ranged.writable }, { size: 50000, writable: false });
			assert.equal(sha(await ranged.read()), rangedSha.digest("hex"), "the range of an unlinked file");
			await rejects(ranged.write(0, new Uint8Array(1)), "EACCES", "a read-only export");
			at = s.text.length;
			vm.write("release\n");
			await waitFor(/kwshm: released/, at);
			assert.equal(await ranged.closed, "released");
			vm.write("q\n");
			await waitFor(PROMPT, at);

			// 5. A sparse file: the export allocates its holes.
			await sh("truncate -s 16M /dev/shm/sparse; printf X | dd of=/dev/shm/sparse bs=1 seek=8388608 conv=notrunc 2>/dev/null");
			out = await sh("du -k /dev/shm/sparse");
			assert.ok(Number(out.match(/\n(\d+)\s+\/dev\/shm\/sparse/)![1]) < 100, `holes before the export: ${out}`);
			const sparse = await shm.open("sparse");
			assert.deepEqual([sparse.size, sparse.pages], [16 << 20, 4096]);
			const sp = await sparse.read();
			assert.equal(sp[8388608], 0x58);
			sp[8388608] = 0;
			assert.ok(sp.every((b) => b === 0), "zeros elsewhere");
			out = await sh("du -k /dev/shm/sparse");
			assert.equal(Number(out.match(/\n(\d+)\s+\/dev\/shm\/sparse/)![1]), 16384, `all allocated after the export: ${out}`);
			await sparse.close();

			// 6. The guest truncates and grows the file while the host holds it.
			assert.equal(await big.isStale(), false);
			assert.equal(await big.refresh(), false, "nothing to refresh");
			await sh("truncate -s 4M /dev/shm/big");
			assert.equal(await big.isStale(), true, "a truncation makes the view stale");
			assert.equal(big.size, BIG, "until refreshed the view keeps its pages");
			assert.equal(sha(await big.read()), sha(content), "the held pages, stale but intact");
			assert.equal(await big.refresh(), true);
			assert.deepEqual([big.size, big.generation], [4 << 20, 2]);
			content = content.slice(0, 4 << 20);
			assert.equal(sha(await big.read()), sha(content));
			await sh("truncate -s 6M /dev/shm/big");
			assert.equal(await big.isStale(), true, "growth too");
			assert.equal(await big.refresh(), true);
			assert.deepEqual([big.size, big.generation], [6 << 20, 3]);
			const grown = new Uint8Array(6 << 20);
			grown.set(content);
			assert.equal(sha(await big.read()), sha(grown), "the old bytes, then zeros");
			assert.equal(await big.refresh({ force: true }), true, "force takes the pages again");
			assert.equal(big.generation, 4);
			assert.equal(await guestSha("/dev/shm/big"), sha(grown));

			// 7. Refused names and files.
			await sh("mkdir /dev/shm/dir; ln -s big /dev/shm/link; mkfifo /dev/shm/fifo; touch /dev/shm/pv; mount --bind /proc/version /dev/shm/pv; echo x > /tmp/notshm");
			await rejects(shm.open("../x"), "EINVAL", "a name escaping /dev/shm");
			await rejects(shm.open("../../tmp/notshm"), "EINVAL", "a path");
			await rejects(shm.open("dir/x"), "EINVAL", "a path into a directory");
			await rejects(shm.open(".."), "EINVAL", "..");
			await rejects(shm.open(""), "EINVAL", "an empty name");
			await rejects(shm.open("dir"), "EISDIR", "a directory");
			await rejects(shm.open("link"), "EINVAL", "a symlink is not followed");
			await rejects(shm.open("fifo"), "EINVAL", "a FIFO");
			await rejects(shm.open("pv"), "EOPNOTSUPP", "a regular file that is not shmem (a bind mount of /proc/version)");
			await rejects(shm.open("missing"), "ENOENT", "a missing file");
			await rejects(shm.open("x".repeat(256)), "ENAMETOOLONG", "a name too long");
			await rejects(shm.openId(987654), "ENOENT", "an unknown id");

			// 8. Release and open again.
			const big2 = await shm.open("big");
			assert.notEqual(big2.id, big.id, "each open is its own export");
			await big.close();
			assert.equal(await big.closed, "closed");
			await rejects(big.read(0, 1), "EBADF", "a closed handle");
			assert.equal(sha(await big2.read()), sha(grown), "the other export is untouched");
			await big2.close();
			const again = await shm.open("big");
			assert.equal(sha(await again.read()), sha(grown), "opened again");
			const st = shm.stats;
			assert.ok(st.open === 2 && st.reads > 10 && st.writes >= 3, JSON.stringify(st)); // again and created
			assert.deepEqual(vm.stats().shm, st);
			held.push(again, created);
		});

		test("poweroff: exit code 0; the vsock and shm handles end with the kernel", async () => {
			const { vm } = k;
			vm.write("poweroff\n");
			assert.equal((await vm.exited).code, 0);
			if (kernelHasVsock) await assert.rejects(vm.vsock!.connect(5001), (e: Error & { code?: string }) => e.code === "ECONNABORTED");
			for (const f of held) assert.equal(await f.closed, "exit");
			if (kernelHasShm) await assert.rejects(vm.shm!.open("big"), (e: Error & { code?: string }) => e.name === "ShmError" && e.code === "ECONNABORTED", "after the exit");
		});
	});

	// Host file systems (js/core/9p.ts, mounts.ts; kernel/guest/kw9p.c): 9p over vsock, mounted through kwtty.
	for (const { worker, name } of MODES) describe(`host file systems over 9p, one kernel (${name})`,
		{ concurrency: 1, skip: (!kernelHasVsock && "the kernel under test has no kwvsock") || (!kernelHas9p && "the kernel under test has no 9p") }, () => {
		let reads = 0, bigReads = 0, closes = 0;
		const blob = new Uint8Array(3 << 20);
		for (let i = 0; i < blob.length; i++) blob[i] = (i * 2654435761) >>> 24;
		const easy = { "hello.txt": "hi from the host\n", dir: { "a.bin": blob, sub: { "deep.txt": "deep\n" } }, "now.txt": () => `read ${++reads}\n`,
			// Longer at each evaluation and larger than one 9p read: "N\n" repeated 50000 + N times.
			"big.txt": () => `${++bigReads}\n`.repeat(50000 + bigReads) };
		const rw = Object.assign(new MemoryFs({ "f.txt": "one\n" }), { close: () => { closes++; } });
		const scratch = mkdtempSync(path.join(tmpdir(), "unkernel-api-9p-"));
		after(() => rmSync(scratch, { recursive: true, force: true }));
		const k = sharedKernel(() => ({
			worker, log: () => {},
			mounts: { "/mnt/easy": easy, "/mnt/rw": rw, "/mnt/rw2": rw, "/mnt/ro": { fs: { "r.txt": "read only\n" }, readOnly: true } },
		}));
		const sh = async (cmd: string) => {
			const r = await k.vm.exec("sh", ["-c", cmd]);
			return { out: r.stdout.trim(), err: r.stderr.trim(), code: r.exitCode };
		};
		const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
		/** Longer than kw9p's metatimeout (1000 ms): the guest asks the host again about anything it looked up before. */
		const pastWindow = () => new Promise((res) => setTimeout(res, 1200));
		/** Run `script` on pipes until its first line, with it then waiting on stdin: `release()` lets it go on and resolves the rest of its stdout. */
		const hold = async (script: string) => {
			const p = await k.vm.spawn("sh", ["-c", script], { pty: false });
			void new Response(p.stderr).text();
			const out = p.stdout.getReader(), dec = new TextDecoder();
			let text = "";
			while (!text.includes("\n")) {
				const r = await out.read();
				if (r.done) throw new Error(`${script}: ended before its first line`);
				text += dec.decode(r.value);
			}
			const release = async () => {
				const w = p.stdin.getWriter();
				await w.write("\n");
				await w.close();
				let rest = text.slice(text.indexOf("\n") + 1);
				for (let r = await out.read(); !r.done; r = await out.read()) rest += dec.decode(r.value);
				assert.deepEqual(await p.ended, { type: "exit", code: 0 });
				return rest;
			};
			return { first: text.slice(0, text.indexOf("\n")), release };
		};

		test("createKernel({ mounts }): an object tree, one MemoryFs at two paths, a read-only one; exec() waits for them", async () => {
			// exec() waits for createKernel's mounts by itself.
			const r = await sh("cat /mnt/easy/hello.txt /mnt/easy/dir/sub/deep.txt; cat /mnt/easy/now.txt; cat /mnt/easy/now.txt; cat /mnt/rw2/f.txt; grep ' 9p ' /proc/mounts");
			assert.equal(r.code, 0, r.err);
			assert.match(r.out, /^hi from the host\ndeep\nread \d+\nread \d+\none\n/, "a computed file is evaluated again at each open");
			const [n1, n2] = [...r.out.matchAll(/read (\d+)/g)].map((m) => Number(m[1]));
			assert.ok(n2! > n1!, r.out);
			assert.match(r.out, /^kw9p:fs\d+ \/mnt\/easy 9p rw,.*metatimeout=1000,.*cache=0x3\b/m, "cache=readahead plus CACHE_META from metatimeout");
			assert.match(r.out, /^kw9p:fs\d+ \/mnt\/ro 9p ro,/m);
			assert.deepEqual([...k.vm.mounts.keys()], ["/mnt/easy", "/mnt/rw", "/mnt/rw2", "/mnt/ro"]);
			assert.ok([...k.vm.mounts.values()].every((m) => m.mounted));
			assert.ok(k.vm.mounts.get("/mnt/easy")!.stats.requests > 5);
		});

		test("a computed file whose length changes at each evaluation: each cat gets one whole result, the next cat a fresh one", async () => {
			const r = await sh("for i in 1 2 3; do cat /mnt/easy/big.txt | uniq -c; done");
			assert.equal(r.code, 0, r.err);
			const runs = r.out.split("\n").map((l) => l.trim().split(/\s+/).map(Number));
			assert.equal(runs.length, 3, `one value per cat, untorn:\n${r.out.slice(0, 500)}`);
			for (const [count, n] of runs) assert.equal(count, 50000 + n!, `the whole result for ${n}`);
			assert.ok(runs[0]![1]! < runs[1]![1]! && runs[1]![1]! < runs[2]![1]!, r.out);
		});

		test("host changes show within metatimeout's 1 s: rewrite, grow, shrink, create, delete, rename of files the guest has looked up, also of a file another process holds open", async () => {
			assert.equal((await sh("cat /mnt/rw/f.txt; [ -e /mnt/rw/later.txt ] || echo missing")).out, "one\nmissing");
			rw.writeFile("/f.txt", "two, longer\n");
			rw.writeFile("/later.txt", "later\n");
			rw.writeFile("/doomed.txt", "doomed\n");
			await pastWindow();
			// The process holds f.txt open, so its inode and pages stay cached; they are revalidated all the same.
			const held = await hold("exec 3</mnt/rw/f.txt; echo $(cat - /mnt/rw/later.txt /mnt/rw/doomed.txt <&3) $(stat -c %s /mnt/rw/f.txt); read _; cat /mnt/rw/f.txt; [ -e /mnt/rw/later.txt ] || echo gone; cat /mnt/rw/moved.txt; [ -e /mnt/rw/doomed.txt ] || echo deleted");
			assert.equal(held.first, "two, longer later doomed 12");
			rw.writeFile("/f.txt", "3\n");
			rw.move("/later.txt", "/moved.txt");
			rw.rm("/doomed.txt");
			await pastWindow();
			assert.equal(await held.release(), "3\ngone\nlater\ndeleted\n");
			rw.rm("/moved.txt");
		});

		test("within metatimeout's 1 s a repeated stat costs no round trip; the guest's own writes show at once on both sides", async () => {
			const fs = new MemoryFs({ "f.txt": "one\n" });
			const m = await k.vm.mount("/meta", fs);
			await sh("cat /meta/f.txt");
			const q = m.stats.requests;
			await sh("i=0; while [ $i -lt 50 ]; do [ -e /meta/f.txt ]; i=$((i+1)); done");
			assert.ok(m.stats.requests - q <= 2, `${m.stats.requests - q} requests for 50 stats (one revalidation if the window passed)`);
			assert.equal((await sh("echo guest > /meta/f.txt; cat /meta/f.txt; stat -c %s /meta/f.txt")).out, "guest\n6");
			assert.equal(fs.readText("/f.txt"), "guest\n");
			await m.unmount();
		});

		test("guest writes reach the host at each write(2), with no close or sync; create, rename, unlink, mkdir, symlink; hard links fail", async () => {
			const changes: string[] = [];
			const off = rw.onChange((c) => changes.push(`${c.type} ${c.path}${c.to ? ` ${c.to}` : ""}`));
			const held = await hold("exec 3>/mnt/rw/open.txt; echo still-open >&3; echo written; read _");
			assert.equal(rw.readText("/open.txt"), "still-open\n", "on the host while the guest still holds it open");
			await held.release();
			const r = await sh("echo w > /mnt/rw/w.txt && mkdir /mnt/rw/d && mv /mnt/rw/w.txt /mnt/rw/d/w.txt && ln -s d/w.txt /mnt/rw/lnk && rm /mnt/rw/open.txt; ln /mnt/rw/d/w.txt /mnt/rw/hard");
			assert.match(r.err, /hard.*Operation not permitted/);
			off();
			assert.equal(rw.readText("/d/w.txt"), "w\n");
			assert.equal(rw.readlink("/lnk"), "d/w.txt");
			assert.deepEqual(changes.filter((c) => !c.startsWith("write")), ["create /open.txt", "create /w.txt", "mkdir /d", "rename /w.txt /d/w.txt", "symlink /lnk d/w.txt", "remove /open.txt"]);
			assert.equal((await sh("cat /mnt/rw2/lnk")).out, "w", "the same MemoryFs at another path");
		});

		test("a large file both ways, by sha256", async () => {
			const r = await sh("sha256sum /mnt/easy/dir/a.bin; dd if=/dev/urandom of=/tmp/up.bin bs=64k count=48 2>/dev/null; cp /tmp/up.bin /mnt/rw/up.bin; sha256sum /tmp/up.bin");
			const [down, up] = r.out.split("\n").map((l) => l.split(" ")[0]);
			assert.equal(down, sha(blob));
			assert.equal(sha(rw.readFile("/up.bin")), up);
		});

		test("errors: ENOENT, EROFS on the read-only mount, EACCES writing a computed file", async () => {
			const r = await sh("cat /mnt/easy/nope; echo x > /mnt/ro/x; touch /mnt/ro/r.txt; rm /mnt/ro/r.txt; echo x > /mnt/easy/now.txt; cat /mnt/ro/r.txt");
			assert.match(r.err, /can't open '\/mnt\/easy\/nope': No such file or directory/);
			assert.match(r.err, /can't create \/mnt\/ro\/x: Read-only file system/);
			assert.match(r.err, /touch: \/mnt\/ro\/r.txt: Read-only file system/);
			assert.match(r.err, /rm: can't remove '\/mnt\/ro\/r.txt': Read-only file system/);
			assert.match(r.err, /now.txt: Permission denied/);
			assert.equal(r.out, "read only");
		});

		test("vm.mount() and unmount() at runtime: nodeFs (symlinks stay links, ls -i matches stat, names that are not UTF-8 left out), busy paths", async () => {
			mkdirSync(path.join(scratch, "sub"));
			writeFileSync(path.join(scratch, "sub", "h.txt"), "host file\n");
			writeFileSync(Buffer.concat([Buffer.from(path.join(scratch, "bad-")), Buffer.from([0xff])]), "not utf-8\n");
			symlinkSync("/etc/hostname", path.join(scratch, "abs-link"));
			const m = await k.vm.mount("/work", nodeFs(scratch));
			await assert.rejects(k.vm.mount("/work", { a: "b" }), (e: Error & { code?: string }) => e.name === "MountError" && e.code === "EBUSY");
			await assert.rejects(k.vm.mount("/proc", { a: "b" }), (e: Error & { code?: string }) => e.code === "EBUSY" && /already a mount point/.test(e.message), "a guest mount point");
			await assert.rejects(k.vm.mount("/etc/hostname", { a: "b" }), (e: Error & { code?: string }) => e.code === "ENOTDIR");
			const r = await sh("cat /work/sub/h.txt; readlink /work/abs-link; cat /work/abs-link; ls /work; echo made > /work/sub/g.txt; mkdir /work/nd; ln -s sub/g.txt /work/gl; mv /work/sub/g.txt /work/nd/g.txt; fsync /work/nd || echo fsync of a directory failed; ls -i /work/sub | awk '{print $1}'; stat -c %i /work/sub/h.txt");
			assert.equal(r.code, 0, r.err);
			const lines = r.out.split("\n");
			assert.deepEqual(lines.slice(0, 3), ["host file", "/etc/hostname", (await sh("cat /etc/hostname")).out], "the guest resolves a symlink in its own tree");
			assert.deepEqual(lines.slice(3, 5), ["abs-link", "sub"], "the name that is not UTF-8 is left out");
			assert.equal(lines.at(-2), lines.at(-1), "ls -i shows stat's inode number");
			assert.equal(readFileSync(path.join(scratch, "nd", "g.txt"), "utf8"), "made\n");
			assert.ok(lstatSync(path.join(scratch, "gl")).isSymbolicLink());
			// A process with its cwd there keeps it busy.
			const holder = await hold("cd /work && echo in && read _");
			await assert.rejects(m.unmount(), (e: Error & { code?: string }) => e.code === "EBUSY");
			assert.equal(m.mounted, true);
			await holder.release();
			await m.unmount();
			assert.equal(m.mounted, false);
			assert.equal(k.vm.mounts.has("/work"), false);
			assert.equal((await sh("grep -c ' /work ' /proc/mounts")).out, "0");
		});

		test("a hung handler: killed readers die at once, a waiting one gets ETIMEDOUT (after up to three requestTimeouts: the guest retries)", async () => {
			const hang: import("../js/node.ts").Fs = {
				getattr: (p) => (p === "/" ? { type: "dir" } : { type: "file", size: 10 }),
				readdir: () => [{ name: "x", type: "file" }],
				open: () => ({ read: () => new Promise<Uint8Array>(() => {}) }),
			};
			await k.vm.mount("/hang", hang, { requestTimeout: 1000 });
			const t0 = performance.now();
			const killed = await sh("cat /hang/x & p=$!; sleep 0.3; kill -9 $p; wait $p; echo killed $?");
			assert.equal(killed.out, "killed 137");
			assert.ok(performance.now() - t0 < 900, "the killed reader did not wait for the timeout");
			const r = await sh("cat /hang/x; echo cat $?");
			assert.equal(r.out, "cat 1");
			assert.match(r.err, /Operation timed out/);
			assert.ok(performance.now() - t0 < 6000);
			// One left hanging into the poweroff below.
			void k.vm.exec("cat", ["/hang/x"]).catch(() => {});
		});

		test("poweroff completes with a reader of a hung handler; the mounts end with the kernel and the backend's close() ran once", async () => {
			await new Promise((res) => setTimeout(res, 300));
			k.vm.write("poweroff\n");
			assert.equal((await k.vm.exited).code, 0);
			assert.equal(k.vm.mounts.size, 0);
			assert.equal(closes, 1, "close() once for the MemoryFs mounted twice");
			await assert.rejects(k.vm.mount("/x", { a: "b" }), (e: Error & { code?: string }) => e.code === "ECONNABORTED");
		});
	});

	test("mounts: without vsock createKernel rejects ENODEV before booting; a failed boot mount rejects the exec() that waited, later ones run",
		{ skip: (!kernelHasVsock && "the kernel under test has no kwvsock") || (!kernelHas9p && "the kernel under test has no 9p") }, async (t) => {
		await assert.rejects(createKernel({ kernel: testKernel, vsock: false, mounts: { "/m": { a: "b" } } }), (e: Error & { code?: string }) => e.name === "MountError" && e.code === "ENODEV");
		const logs: string[] = [];
		const vm = await boot(t, { log: (m) => logs.push(m), mounts: { "/etc/hostname": { a: "b" }, "/good": { "g.txt": "good" } } });
		await assert.rejects(vm.exec("true"), (e: Error & { code?: string }) => e.name === "MountError" && e.code === "ENOTDIR");
		assert.ok(logs.some((l) => /mount \/etc\/hostname/.test(l)), "logged too");
		assert.equal((await vm.exec("cat", ["/good/g.txt"])).stdout, "good");
	});

	/** Collects a terminal session's output and lets a test wait for a pattern in it. */
	const termScreen = (sess: import("../js/node.ts").Pty) => {
		const dec = new TextDecoder();
		const st = { text: "" };
		const done = (async () => {
			for await (const chunk of sess.output) st.text += dec.decode(chunk, { stream: true });
		})();
		done.catch(() => {});
		const waitFor = async (re: RegExp, from = 0, ms = 60000) => {
			const end = Date.now() + ms;
			while (!re.test(st.text.slice(from))) {
				if (Date.now() > end) throw new Error(`timeout waiting for ${re} in the terminal; tail:\n${st.text.slice(-1500)}`);
				await new Promise((r) => setTimeout(r, 50));
			}
		};
		return { st, waitFor, done };
	};

	// kwtty (kernel/guest/kwtty.c, js/core/tty.ts): terminal sessions over vsock, each with its own pty.
	for (const { worker, name } of MODES) describe(`terminal sessions over vsock (kwtty), one kernel (${name})`,
		{ concurrency: 1, skip: !kernelHasVsock && "the kernel under test has no kwvsock" }, () => {
		const k = sharedKernel(() => ({ worker, log: () => {} })); // vsock is on by default
		/** Run `cmd` on the hvc0 console and return what it printed after it, up to `done`. */
		const consoleRun = async (cmd: string, done: RegExp) => {
			const at = k.s.text.length;
			k.vm.write(`${cmd}\n`);
			await k.waitFor(done, at);
			return k.s.text.slice(at);
		};
		/** Poll the console until `echo "probe=<expr>"` prints `want` (up to about 10 s). */
		const consoleUntil = async (expr: string, want: RegExp) => {
			let out = "";
			for (let i = 0; i < 50; i++) {
				out = await consoleRun(`echo "probe=${expr}"`, /probe=[^\r\n$]*\r?\n/);
				if (want.test(out)) return out;
				await new Promise((r) => setTimeout(r, 200));
			}
			return out;
		};

		test("two sessions at once, each with its own pty and size; exit 0", async () => {
			await k.waitFor(PROMPT);
			const [a, b] = await Promise.all([k.vm.spawn(undefined, [], { rows: 30, cols: 100 }), k.vm.spawn(undefined, [], { rows: 40, cols: 120, term: "vt100" })]);
			assert.notEqual(a.pts, b.pts);
			assert.ok(a.pid > 1 && b.pid > 1 && a.pid !== b.pid);
			const sa = termScreen(a), sb = termScreen(b);
			await Promise.all([a.write("tty; stty size; echo $TERM; echo done-$((40+2))\n"), b.write("tty; stty size; echo $TERM; echo done-$((40+2))\n")]);
			await Promise.all([sa.waitFor(/done-42/), sb.waitFor(/done-42/)]);
			for (const [sess, sc, size, term] of [[a, sa, "30 100", "xterm-256color"], [b, sb, "40 120", "vt100"]] as const) {
				assert.match(sc.st.text, new RegExp(`^/dev/pts/${sess.pts}\\r?$`, "m"), sc.st.text);
				assert.match(sc.st.text, new RegExp(`^${size}\\r?$`, "m"), sc.st.text);
				assert.match(sc.st.text, new RegExp(`^${term}\\r?$`, "m"), sc.st.text);
			}
			await Promise.all([a.write("exit\n"), b.write("exit\n")]);
			assert.deepEqual(await a.ended, { type: "exit", code: 0 });
			assert.deepEqual(await b.ended, { type: "exit", code: 0 });
			await Promise.all([sa.done, sb.done]);
		});

		test("spawn(file, args, { cwd }): a program from PATH, its arguments, directory and exit code; exec and chdir failures", async () => {
			const s = await k.vm.spawn("sh", ["-c", 'pwd; tty; echo "[$0][$1]"; exit 5', "a b", ""], { cwd: "/tmp", cols: 100, rows: 30 });
			const sc = termScreen(s);
			assert.deepEqual(await s.ended, { type: "exit", code: 5 });
			await sc.done;
			assert.equal(s.exitCode, 5);
			assert.match(sc.st.text, /^\/tmp\r?$/m, sc.st.text);
			assert.match(sc.st.text, new RegExp(`^/dev/pts/${s.pts}\\r?$`, "m"), sc.st.text);
			assert.match(sc.st.text, /^\[a b\]\[\]\r?$/m, sc.st.text);
			const isRemote = (re: RegExp) => (e: Error & { code?: string }) => e.name === "PtyError" && e.code === "EREMOTE" && re.test(e.message);
			await assert.rejects(k.vm.spawn("/no/such/program"), isRemote(/exec \/no\/such\/program: No such file/));
			await assert.rejects(k.vm.spawn(undefined, [], { cwd: "/no/such/dir" }), isRemote(/chdir \/no\/such\/dir: No such file/));
		});

		test("kill(): TERM to the program, ended reports the signal", async () => {
			const s = await k.vm.spawn("sleep", ["100"]);
			const sc = termScreen(s);
			s.kill("SIGTERM");
			assert.deepEqual(await s.ended, { type: "signal", signal: 15, coreDumped: false });
			assert.equal(s.exitCode, null);
			await sc.done;
		});

		test("resize(), then stty size; exit 3", async () => {
			const s = await k.vm.spawn(undefined, [], { rows: 24, cols: 80 });
			const sc = termScreen(s);
			s.resize(132, 50);
			assert.deepEqual([s.cols, s.rows], [132, 50]);
			await s.write("stty size; echo r-$((1+1))\n");
			await sc.waitFor(/r-2/);
			assert.match(sc.st.text, /^50 132\r?$/m, sc.st.text);
			await s.write("exit 3\n");
			assert.deepEqual(await s.ended, { type: "exit", code: 3 });
		});

		test("seq 1 200000; exit: all of it arrives through a slow reader before ended settles", async () => {
			const N = 200000;
			const s = await k.vm.spawn(undefined, [], { rows: 24, cols: 80 });
			const dec = new TextDecoder();
			let text = "", chunks = 0, atEnd = -1, sinceNap = 0;
			// ended settles only when the reader asks past the last output, so by then it has all of it.
			void s.ended.then(() => { atEnd = text.length; }, () => {});
			await s.write(`seq 1 ${N}; exit\n`);
			// Slow: nothing read at first, so the guest fills the vsock window and blocks, then naps as it reads.
			await new Promise((r) => setTimeout(r, 1500));
			for await (const chunk of s.output) {
				assert.equal(atEnd, -1, "ended settled while output was still being read");
				text += dec.decode(chunk, { stream: true });
				chunks++;
				if ((sinceNap += chunk.length) >= 128 * 1024) {
					sinceNap = 0;
					await new Promise((r) => setTimeout(r, 20));
				}
			}
			assert.ok(chunks > 10, `${chunks} chunks`);
			assert.equal(atEnd, text.length, "ended settled after the last output was read");
			assert.deepEqual(await s.ended, { type: "exit", code: 0 });
			const nums = text.split(/\r?\n/).filter((l) => /^\d+$/.test(l)).map(Number);
			assert.equal(nums.length, N, `${nums.length} lines; tail: ${text.slice(-200)}`);
			assert.ok(nums.every((x, i) => x === i + 1), "every line, in order");
		});

		test("sleep 100 & exit: the session ends promptly although a background job holds the pty", async () => {
			const s = await k.vm.spawn(undefined, [], { rows: 24, cols: 80 });
			const sc = termScreen(s);
			const t0 = Date.now();
			await s.write("sleep 100 & exit\n");
			assert.deepEqual(await s.ended, { type: "exit", code: 0 });
			assert.ok(Date.now() - t0 < 5000, `${Date.now() - t0} ms`);
			await sc.done;
		});

		test("yes & exit: the session ends although a background job keeps printing, and the job is hung up", async () => {
			const s = await k.vm.spawn(undefined, [], { rows: 24, cols: 80 });
			const sc = termScreen(s);
			await s.write("yes kwtty-bg-test & exit\n");
			assert.deepEqual(await s.ended, { type: "exit", code: 0 });
			await sc.done;
			const out = await consoleUntil("$(ps | grep -c '[y]es kwtty-bg-test')", /probe=0\r?\n/);
			assert.match(out, /probe=0\r?\n/, `no leftover yes:\n${out}`);
		});

		test("close() during output: ended closed, the shell and its program are gone", async () => {
			const s = await k.vm.spawn(undefined, [], { rows: 24, cols: 80 });
			const sc = termScreen(s);
			await s.write("yes kwtty-close-test\n");
			await sc.waitFor(/(kwtty-close-test\r?\n){20}/);
			assert.match(await consoleUntil("$(ps | grep -c '[y]es kwtty-close-test')", /probe=1\r?\n/), /probe=1\r?\n/, "yes runs");
			await s.close();
			assert.deepEqual(await s.ended, { type: "closed" });
			await sc.done;
			const out = await consoleUntil(`$(ps | grep -c '[y]es kwtty-close-test')$([ -d /proc/${s.pid} ] && echo -shell-alive)`, /probe=0\r?\n/);
			assert.match(out, /probe=0\r?\n/, `no leftover yes or shell (pid ${s.pid}):\n${out}`);
		});

		// The trap is in a foreground job: the kernel signals the session leader (the login shell, which
		// then dies) and, as it exits, the foreground process group. A HUP trap in busybox ash's own
		// interactive login shell does not run once its tty is hung up (2026-11-14), so it is not used.
		test("close() hangs up: a foreground shell's HUP trap runs", async () => {
			await consoleRun("rm -f /tmp/kwtty-hup; echo rm-$((3+4))", /rm-7/);
			const s = await k.vm.spawn(undefined, [], { rows: 24, cols: 80 });
			const sc = termScreen(s);
			await s.write(`sh -c 'trap "echo hup > /tmp/kwtty-hup; exit" HUP; echo armed-$((2+3)); while :; do sleep 0.1; done'\n`);
			await sc.waitFor(/armed-5/);
			await s.close();
			assert.deepEqual(await s.ended, { type: "closed" });
			const out = await consoleUntil("$(cat /tmp/kwtty-hup 2>/dev/null)", /probe=hup\r?\n/);
			assert.match(out, /probe=hup\r?\n/, out);
		});

		// Pipes: spawn(file, args, { pty: false }) and exec().
		test("exec(): stdout and stderr apart, without a pty (no \\r, no TERM, not a tty); the exit code", async () => {
			const r = await k.vm.exec("sh", ["-c", 'echo out; echo err >&2; echo "TERM=${TERM-unset}"; [ -t 0 ] || [ -t 1 ] && echo tty || echo notty; exit 4']);
			assert.deepEqual(r, { stdout: "out\nTERM=unset\nnotty\n", stderr: "err\n", exitCode: 4, signal: null });
			const cwd = await k.vm.exec("pwd", [], { cwd: "/tmp", env: { X: "1" } });
			assert.equal(cwd.stdout, "/tmp\n");
			await assert.rejects(k.vm.exec("/no/such/program"), (e: Error & { code?: string }) => e.code === "EREMOTE" && /exec \/no\/such\/program/.test(e.message));
		});

		test("exec(): binary output byte for byte, input through stdin then EOF, 300 KB each way", async () => {
			const bin = await k.vm.exec("printf", ["\\000\\377\\r\\n\\200"], { encoding: "buffer" });
			assert.deepEqual([...bin.stdout], [0, 255, 13, 10, 128]);
			const input = new Uint8Array(300 * 1024);
			for (let i = 0; i < input.length; i++) input[i] = (i * 31 + (i >> 8)) & 0xff;
			const echo = await k.vm.exec("cat", [], { input, encoding: "buffer" });
			assert.equal(echo.exitCode, 0);
			assert.equal(echo.stdout.length, input.length);
			assert.ok(Buffer.from(echo.stdout).equals(Buffer.from(input)), "cat gives the input back unchanged");
			const wc = await k.vm.exec("wc", ["-c"], { input });
			assert.equal(wc.stdout.trim(), String(input.length));
			const seq = await k.vm.exec("seq", ["1", "100000"]);
			const lines = seq.stdout.split("\n");
			assert.equal(lines.length, 100001);
			assert.equal(lines[99999], "100000");
		});

		test("spawn(file, args, { pty: false }): stdin as a stream, EOF ends cat; kill() sends SIGTERM", async () => {
			const p = await k.vm.spawn("cat", [], { pty: false });
			const out = new Response(p.stdout).text();
			const err = new Response(p.stderr).text();
			const w = p.stdin.getWriter();
			await w.write("one\n");
			await w.write(new TextEncoder().encode("two\n"));
			await w.close();
			assert.deepEqual(await p.ended, { type: "exit", code: 0 });
			assert.equal(await out, "one\ntwo\n");
			assert.equal(await err, "");

			const sl = await k.vm.spawn("sleep", ["100"], { pty: false });
			const done = Promise.all([new Response(sl.stdout).arrayBuffer(), new Response(sl.stderr).arrayBuffer()]);
			sl.kill();
			assert.deepEqual(await sl.ended, { type: "signal", signal: 15, coreDumped: false });
			await done;
		});

		test("pipes: close() hangs up the program's process group (SIGHUP), its children included", async () => {
			const p = await k.vm.spawn("sh", ["-c", "sleep 1000 & echo $!; wait"], { pty: false });
			const reader = p.stdout.getReader();
			let text = "";
			while (!text.includes("\n")) text += new TextDecoder().decode((await reader.read()).value);
			const child = Number(text.trim());
			assert.ok(child > 1, text);
			await p.close();
			assert.deepEqual(await p.ended, { type: "closed" });
			let alive = "";
			for (let i = 0; i < 50; i++) {
				alive = (await k.vm.exec("sh", ["-c", `for p in ${p.pid} ${child}; do [ -d /proc/$p ] && echo $p; done; true`])).stdout;
				if (!alive) break;
				await new Promise((r) => setTimeout(r, 100));
			}
			assert.equal(alive, "", "the shell and its sleep are gone");
		});

		// CONNECT: vm.connect() to a TCP server on the guest's loopback, and vm.fetch() over it.
		/** A busybox nc server on the guest's 127.0.0.1:`port` running `prog` per connection; connect() once it listens. */
		const guestServer = async (port: number, prog: string[]) => {
			const srv = await k.vm.spawn("nc", ["-lk", "-s", "127.0.0.1", "-p", String(port), "-e", ...prog], { pty: false });
			void new Response(srv.stdout).arrayBuffer().catch(() => {});
			void new Response(srv.stderr).arrayBuffer().catch(() => {});
			const connect = async () => {
				for (let i = 0; ; i++) {
					try {
						return await k.vm.connect(port);
					} catch (e) {
						if ((e as { code?: string }).code !== "ECONNREFUSED" || i > 100) throw e;
						await new Promise((r) => setTimeout(r, 100));
					}
				}
			};
			return { srv, connect };
		};
		const relays = async () => (await k.vm.exec("sh", ["-c", "ps -o args | grep -c '[k]wtty serve'"])).stdout.trim();

		test("connect(): an echo server, half-close, 1 MiB each way under credit; a refused port is ECONNREFUSED; close() of an idle connection ends the guest's relay", async () => {
			const { srv, connect } = await guestServer(7000, ["cat"]);
			const before = await relays();
			const enc = new TextEncoder();
			// Half-close: cat reads EOF, exits, and the server's close ends readable.
			const s = await connect();
			assert.equal(s.port, 7000);
			const w = s.writable.getWriter();
			await w.write(enc.encode("hello, "));
			await w.write(enc.encode("guest\n"));
			await w.close();
			assert.equal(await new Response(s.readable).text(), "hello, guest\n");
			assert.equal(await s.closed, "closed");

			// 1 MiB each way at once: more than the vsock window (256 KiB) and the relay's buffers.
			const N = 1 << 20;
			const data = new Uint8Array(N);
			for (let i = 0; i < N; i++) data[i] = (i * 31 + (i >> 8)) & 0xff;
			const b = await connect();
			const sent = (async () => {
				const bw = b.writable.getWriter();
				for (let i = 0; i < N; i += 50000) await bw.write(data.subarray(i, i + 50000));
				await bw.close();
			})();
			const back = new Uint8Array(await new Response(b.readable).arrayBuffer());
			await sent;
			assert.equal(back.length, N);
			assert.ok(Buffer.from(back).equals(Buffer.from(data)), "the echo is byte for byte");
			assert.equal(await b.closed, "closed");

			await assert.rejects(k.vm.connect(7999), (e: Error & { code?: string }) =>
				e.name === "PtyError" && e.code === "ECONNREFUSED" && /127\.0\.0\.1:7999/.test(e.message));
			await assert.rejects(k.vm.connect(0), RangeError);

			// The host half-closes, the server never answers, then the host closes: the relay sees it (a probe each second) and exits.
			const idle = await guestServer(7001, ["sleep", "100"]);
			const c = await idle.connect();
			const cw = c.writable.getWriter();
			await cw.write(enc.encode("x"));
			await cw.close();
			await c.close();
			let now = "";
			for (let i = 0; i < 50; i++) {
				now = await relays();
				if (now === before) break;
				await new Promise((r) => setTimeout(r, 100));
			}
			// The idle server's own session (kwtty with PIPES) is one more.
			assert.equal(Number(now), Number(before) + 1, `kwtty processes: ${before} before, ${now} after`);
			await idle.srv.close();
			await srv.close();
		});

		test("fetch(): GET from a shell HTTP server in the guest: status, headers and body", async () => {
			const script = [
				"#!/bin/sh",
				"cr=$(printf '\\r')",
				"read -r line",
				'while IFS= read -r h; do [ "$h" = "$cr" ] || [ -z "$h" ] && break; done',
				'body="hello from the guest: ${line%$cr}"',
				`printf 'HTTP/1.1 201 Created\\r\\nContent-Type: text/plain\\r\\nX-Guest: yes\\r\\nContent-Length: %d\\r\\n\\r\\n%s' "\${#body}" "$body"`,
				"",
			].join("\n");
			await k.vm.exec("sh", ["-c", "cat > /tmp/kw-http.sh && chmod +x /tmp/kw-http.sh"], { input: script });
			const { srv, connect } = await guestServer(8000, ["/tmp/kw-http.sh"]);
			await (await connect()).close(); // listening now
			const res = await k.vm.fetch("http://guest.example:8000/some/path?q=1");
			assert.equal(res.status, 201);
			assert.equal(res.headers.get("x-guest"), "yes");
			assert.equal(res.headers.get("content-type"), "text/plain");
			assert.equal(await res.text(), "hello from the guest: GET /some/path?q=1 HTTP/1.1");
			await srv.close();
		});
	});

	test("connect() and fetch() on an instance created with vsock: false: ENODEV", async (t) => {
		const vm = await boot(t, { vsock: false, log: () => {}, cmdline: "console=hvc0 rdinit=/bin/true" });
		const isNoDev = (e: Error & { code?: string }) => e.name === "PtyError" && e.code === "ENODEV";
		await assert.rejects(vm.connect(80), isNoDev);
		await assert.rejects(vm.fetch("http://guest/"), isNoDev);
		await vm.exited;
	});

	test("snapshot() of a running machine, resumed by createKernel({ restore }) in a new instance (console only)", { skip: noSnapshots }, async (t) => {
		const vm = await boot(t, { vsock: false, log: () => {} });
		assert.ok(vm instanceof sdk.KernelInstance);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		vm.write("X=kept; echo $((6*7)) > /tmp/f; (while :; do usleep 50000; done) & echo saved-$X\n");
		await a.waitFor(/saved-kept/);
		const snap = sdk.decodeSnapshot(sdk.encodeSnapshot(await vm.snapshot()));
		assert.equal(snap.memory.byteLength, 512 * 1048576);
		assert.match(snap.fingerprint, /^Linux version /);
		vm.write("echo still-$X\n");
		await a.waitFor(/still-kept/);
		await vm.stop({ reason: "snapshot taken" });

		const vm2 = await boot(t, { vsock: false, restore: snap, log: () => {} });
		const b = screen(vm2);
		vm2.write("jobs > /tmp/j; echo got-$X-$(cat /tmp/f)-$(grep -c Running /tmp/j)\n");
		await b.waitFor(/got-kept-42-1/);
		// The restored kernel has the drivers it had: the devices must be given as when it was saved.
		await assert.rejects(boot(t, { restore: snap, log: () => {} }), /snapshot: the snapshot has no vsock device, but this machine is given one/);
	});

	test("snapshot() leaves out the free pages: after a memory-heavy workload the file stays small, and tmpfs and a running process survive", { skip: noSnapshots }, async (t) => {
		const vm = await boot(t, { vsock: false, log: () => {} });
		assert.ok(vm instanceof sdk.KernelInstance);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		// 64 MiB of random data written and removed: free pages that are not zero.
		vm.write("dd if=/dev/urandom of=/tmp/big bs=1M count=64 2>/dev/null; head -c 4194304 /tmp/big > /tmp/keep; rm /tmp/big; " +
			"(while :; do usleep 50000; done) & echo sum-$(md5sum < /tmp/keep | cut -c1-32)-done\n");
		await a.waitFor(/sum-[0-9a-f]{32}-done/);
		const sum = a.s.text.match(/sum-([0-9a-f]{32})-done/)![1]!;
		const snap = await vm.snapshot({ stop: true });
		assert.ok((snap.freeBytes ?? 0) > 256 * 1048576, `free pages left out: ${snap.freeBytes}`);
		const bytes = sdk.encodeSnapshot(snap);
		assert.ok(bytes.length < 64 * 1048576, `snapshot of ${bytes.length} bytes, the freed 64 MiB must not be in it`);

		const vm2 = await boot(t, { vsock: false, restore: sdk.decodeSnapshot(bytes), log: () => {} });
		const b = screen(vm2);
		vm2.write("jobs > /tmp/j; echo got-$(md5sum < /tmp/keep | cut -c1-32)-$(grep -c Running /tmp/j)\n");
		await b.waitFor(new RegExp(`got-${sum}-1`));
	});

	test("snapshot() with display, evdev and sound: the restored glimmer keeps its picture, its open devices and its stream, and reads a key", { skip: noSnapshots }, async (t) => {
		const opts = (events: string[], chunks: number[], modes: Array<string | null>, inputs: string[]) => ({
			log: () => {}, vsock: false, display: { width: 320, height: 240 },
			onDisplay: (m: { width: number; height: number } | null) => modes.push(m && `${m.width}x${m.height}`),
			onInput: (st: { keyboard: boolean; mouse: boolean; tablet: boolean }) => inputs.push(`${+st.keyboard}${+st.mouse}${+st.tablet}`),
			sound: { onState: (_s: unknown, ev: string) => events.push(ev), onChunk: (c: { frames: number }) => { chunks.push(c.frames); return 0; } },
		});
		const ev1: string[] = [], ch1: number[] = [], md1: Array<string | null> = [], in1: string[] = [];
		const vm = await boot(t, opts(ev1, ch1, md1, in1));
		assert.ok(vm instanceof sdk.KernelInstance);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		vm.write("glimmer --test 6\n");
		await a.waitFor(/glimmer: test ready/);
		await new Promise((r) => setTimeout(r, 300)); // the stream runs
		const before = vm.frame()!;
		const snap = sdk.decodeSnapshot(sdk.encodeSnapshot(await vm.snapshot({ stop: true })));
		assert.ok(snap.devices.display?.mode && snap.devices.input && snap.devices.sound?.state.open, JSON.stringify(snap.devices));
		assert.equal(snap.devices.vsock, undefined);

		await assert.rejects(boot(t, { ...opts([], [], [], []), display: false, restore: snap }), /the snapshot has a display device/);
		const ev2: string[] = [], ch2: number[] = [], md2: Array<string | null> = [], in2: string[] = [];
		const vm2 = await boot(t, { ...opts(ev2, ch2, md2, in2), restore: snap });
		assert.ok(vm2 instanceof sdk.KernelInstance);
		const b = screen(vm2);
		assert.deepEqual(md2, ["320x240"], "the attachment is reported again");
		assert.deepEqual(vm2.frame()!.data, before.data, "the picture is the saved one");
		assert.ok(vm2.evdev!.keyboardOpen && in2.at(-1)?.startsWith("1"), in2.join(","));
		assert.deepEqual(ev2.slice(0, 2), ["open", "prepare"], ev2.join(","));
		assert.equal(vm2.evdev!.key(30, true), true);
		assert.equal(vm2.evdev!.key(30, false), true);
		await b.waitFor(/glimmer: event event\d+ EV_KEY 30 1[\s\S]*EV_KEY 30 0/);
		await b.waitFor(/glimmer: test sound done, \d+ frames/);
		await b.waitFor(/glimmer: test done/);
		assert.ok(ch2.reduce((n, f) => n + f, 0) > 0, "the stream went on after the restore");
		await new Promise((r) => setTimeout(r, 300));
		assert.equal(md2.at(-1), null, "glimmer's close is reported");
		assert.equal(ev2.at(-1), "close", ev2.join(","));
		vm2.write("poweroff\n");
		assert.equal((await vm2.exited).code, 0);
	});

	test("snapshot() with network and vsock: the guest's old sessions end, new connections, exec() and fetch() work",
		{ skip: noSnapshots || (!kernelHasVsock && "the kernel under test has no kwvsock") }, async (t) => {
		const http = createServer((_req, res) => res.end("hello after restore\n"));
		await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
		t.after(() => http.close());
		const port = (http.address() as AddressInfo).port;
		const net = () => new NetStack({ backend: directBackend(), hostLoopback: true });
		const vm = await boot(t, { log: () => {}, net: net() });
		assert.ok(vm instanceof sdk.KernelInstance);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		// A kwtty session (a program on pipes) and a guest connection to a host listener, open at the snapshot.
		const sub = await vm.spawn("sleep", ["1001"], { pty: false });
		void new Response(sub.stdout).arrayBuffer().catch(() => {});
		void new Response(sub.stderr).arrayBuffer().catch(() => {});
		const l = vm.vsock!.listen(5005);
		vm.write("kwvsock connect 5005 </dev/null >/tmp/vs.out 2>&1 & echo vs-started\n");
		await a.waitFor(/vs-started/);
		const conn = (await l.accept())!;
		const snap = sdk.decodeSnapshot(sdk.encodeSnapshot(await vm.snapshot({ stop: true })));
		assert.deepEqual(snap.devices.network?.mac, [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]);
		assert.ok(snap.devices.vsock?.guestCid === 3, JSON.stringify(snap.devices));
		void conn.closed;

		await assert.rejects(boot(t, { log: () => {}, restore: snap }), /the snapshot has a network device/);
		const vm2 = await boot(t, { log: () => {}, net: net(), restore: snap });
		assert.ok(vm2 instanceof sdk.KernelInstance);
		const b = screen(vm2);
		// The kernel reset the old vsock connections: kwtty's program and the kwvsock client end.
		const gone = async () => {
			for (let i = 0; ; i++) {
				const r: { stdout: string } = await vm2.exec("sh", ["-c", "pgrep -f '[s]leep 1001'; pgrep -f '[k]wvsock connect 5005'; true"]);
				if (!r.stdout.trim()) return;
				if (i > 50) assert.fail(`still running after the restore: ${r.stdout}`);
				await new Promise((done) => setTimeout(done, 200));
			}
		};
		await gone();
		const at = b.s.text.length;
		vm2.write(`wget -q -O - http://10.0.2.2:${port}/ && echo fetch-ok\n`);
		await b.waitFor(/hello after restore[\s\S]*fetch-ok/, at);
		assert.equal((await vm2.exec("echo", ["exec-ok"])).stdout, "exec-ok\n");
		const srv = await vm2.spawn("nc", ["-lk", "-s", "127.0.0.1", "-p", "8001", "-e", "sh", "-c", "printf 'HTTP/1.0 200 OK\\r\\n\\r\\nguest-ok'"], { pty: false });
		void new Response(srv.stdout).arrayBuffer().catch(() => {});
		void new Response(srv.stderr).arrayBuffer().catch(() => {});
		let res: Response | undefined;
		for (let i = 0; !res; i++) {
			try { res = await vm2.fetch("http://guest:8001/"); } catch (e) { if (i > 50) throw e; await new Promise((r) => setTimeout(r, 100)); }
		}
		assert.equal(await res.text(), "guest-ok");
		vm2.write("poweroff\n");
		assert.equal((await vm2.exited).code, 0);
	});

	test("snapshot() with host file systems: the mounts and a process's open files on them survive; a file deleted on the host meanwhile answers ESTALE; refused without the mounts and in worker mode",
		{ skip: noSnapshots || (!kernelHasVsock && "the kernel under test has no kwvsock") }, async (t) => {
		const dir = mkdtempSync(path.join(tmpdir(), "unkernel-api-"));
		t.after(() => rmSync(dir, { recursive: true, force: true }));
		writeFileSync(path.join(dir, "held.txt"), "");
		writeFileSync(path.join(dir, "r.txt"), "line one\nline two\n");
		writeFileSync(path.join(dir, "gone.txt"), "soon gone\n");
		const mem = new MemoryFs({ "m.txt": "memory\n" });
		const mounts = () => ({ "/mnt/h": nodeFs(dir), "/mnt/m": mem });
		const vm = await boot(t, { log: () => {}, mounts: mounts() });
		assert.ok(vm instanceof sdk.KernelInstance);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		await vm.exec("true"); // createKernel's mounts are done
		// A process with three files open on the nodeFs mount, waiting across the snapshot.
		vm.write("echo guest > /mnt/m/g.txt; (exec 3<>/mnt/h/held.txt 4</mnt/h/r.txt 5<>/mnt/h/gone.txt; echo before >&3; " +
			"while [ ! -e /tmp/go ]; do usleep 20000; done; echo after >&3; read l <&4; echo \"$l\" > /tmp/r.out; " +
			"echo x >&5 2>/tmp/e.out || echo write-failed >> /tmp/e.out; echo done > /tmp/done) & echo held-ready\n");
		await a.waitFor(/held-ready/);
		for (let i = 0; readFileSync(path.join(dir, "held.txt"), "utf8") !== "before\n"; i++) {
			if (i > 200) assert.fail("the guest's first write did not arrive");
			await new Promise((r) => setTimeout(r, 25));
		}
		const snap = sdk.decodeSnapshot(sdk.encodeSnapshot(await vm.snapshot({ stop: true })));
		assert.deepEqual(snap.devices.vsock?.mounts?.mounts.map((m) => m.path).sort(), ["/mnt/h", "/mnt/m"]);
		rmSync(path.join(dir, "gone.txt"));

		await assert.rejects(boot(t, { log: () => {}, restore: snap }), /snapshot: the snapshot has a host file system at \/mnt\/[hm], which this machine is not given/);
		await assert.rejects(boot(t, { log: () => {}, restore: snap, mounts: { ...mounts(), "/mnt/m": { fs: mem, readOnly: true } } }), /\/mnt\/m is not read-only in the snapshot/);
		await assert.rejects(boot(t, { log: () => {}, restore: snap, mounts: mounts(), worker: true }), /resume inline only/);
		const vm2 = await boot(t, { log: () => {}, restore: snap, mounts: mounts() });
		assert.ok(vm2 instanceof sdk.KernelInstance);
		assert.deepEqual([...vm2.mounts.keys()].sort(), ["/mnt/h", "/mnt/m"]);
		assert.ok(vm2.mounts.get("/mnt/h")!.mounted);
		await vm2.exec("touch", ["/tmp/go"]);
		let out = "";
		for (let i = 0; !/done/.test(out); i++) {
			if (i > 100) assert.fail(`the process did not finish: ${out}`);
			await new Promise((r) => setTimeout(r, 50));
			out = (await vm2.exec("sh", ["-c", "cat /tmp/done 2>/dev/null; true"])).stdout;
		}
		assert.equal(readFileSync(path.join(dir, "held.txt"), "utf8"), "before\nafter\n", "a write through a file open across the restore, at its offset");
		assert.equal((await vm2.exec("cat", ["/tmp/r.out"])).stdout, "line one\n", "a read through a file open across the restore");
		assert.match((await vm2.exec("cat", ["/tmp/e.out"])).stdout, /Stale file handle[\s\S]*write-failed/, "the file deleted on the host while suspended");
		const r = await vm2.exec("sh", ["-c", "echo new > /mnt/h/new.txt && cat /mnt/m/g.txt /mnt/m/m.txt && ls /mnt/h"]);
		assert.equal(r.stdout, "guest\nmemory\nheld.txt\nnew.txt\nr.txt\n");
		assert.equal(readFileSync(path.join(dir, "new.txt"), "utf8"), "new\n");
		assert.equal(mem.readText("/g.txt"), "guest\n", "the MemoryFs passed again has the guest's write from before the snapshot");
		await vm2.mounts.get("/mnt/m")!.unmount();
		assert.equal(existsSync(path.join(dir, "new.txt")), true);
		vm2.write("poweroff\n");
		assert.equal((await vm2.exited).code, 0);
	});

	test("snapshot() with a data disk: resumes with the saved and the unsaved writes; refused once the disk changed", { skip: noSnapshots }, async (t) => {
		const dir = mkdtempSync(path.join(tmpdir(), "unkernel-api-"));
		t.after(() => rmSync(dir, { recursive: true, force: true }));
		const module = await WebAssembly.compile(readFileSync(kernelFile));
		const file = path.join(dir, "data.img");
		await createImageFromKwsparse(file, bundledBoot(module).datadisk!);
		const open: Array<InstanceType<typeof FileDisk>> = [];
		t.after(() => { for (const d of open) try { d.close(); } catch {} });
		const disk = () => { const d = new FileDisk(file); open.push(d); return d; };

		const vm = await boot(t, { kernel: module, vsock: false, disks: [disk()], log: () => {} });
		assert.ok(vm instanceof sdk.KernelInstance);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		// /data/synced reaches the disk; /data/dirty stays in the page cache (writeback and commits slowed down).
		vm.write("echo 360000 > /proc/sys/vm/dirty_expire_centisecs; echo 360000 > /proc/sys/vm/dirty_writeback_centisecs; " +
			"echo synced-1 > /data/synced; sync; mount -o remount,commit=600 /data; echo dirty-2 > /data/dirty; echo ready-$((6*7))\n");
		await a.waitFor(/ready-42/);
		const snap = sdk.decodeSnapshot(sdk.encodeSnapshot(await vm.snapshot({ stop: true })));
		assert.equal((await vm.exited).kind, "stopped", "stop: true stops the kernel after the copy");
		assert.equal(snap.disks.length, 1);
		assert.equal(snap.disks[0]!.name, file);
		assert.ok(existsSync(`${file}.kwsnap`), "the generation sidecar");

		await assert.rejects(boot(t, { kernel: module, vsock: false, restore: snap, log: () => {} }), /disk wda \(.*\) is missing/);
		const vm2 = await boot(t, { kernel: module, vsock: false, restore: snap, disks: [disk()], log: () => {} });
		assert.ok(vm2 instanceof sdk.KernelInstance);
		const b = screen(vm2);
		vm2.write("echo got-$(cat /data/synced)-$(cat /data/dirty)\n");
		await b.waitFor(/got-synced-1-dirty-2/);
		// Saved while it runs on: the next write to the disk makes this snapshot unrestorable.
		const snap2 = await vm2.snapshot();
		vm2.write("sync; echo after > /data/after; sync; echo wrote-$((6*7))\n"); // not the typed line's echo
		await b.waitFor(/wrote-42/);
		await vm2.stop({ reason: "test" });
		await assert.rejects(boot(t, { kernel: module, vsock: false, restore: snap2, disks: [disk()], log: () => {} }),
			/snapshot: disk wda \(.*data\.img\) was written after the snapshot \(generation \d+, the snapshot has \d+\)/);
		await assert.rejects(boot(t, { kernel: module, vsock: false, restore: snap, disks: [disk()], log: () => {} }), /was written after the snapshot/);
	});

	test("worker mode: snapshot() in the worker, resumed inline and in a worker (transferRestore detaches the memory)", { skip: noSnapshots }, async (t) => {
		const vm = await boot(t, { worker: true, vsock: false, log: () => {} });
		assert.ok(vm instanceof sdk.WorkerKernel);
		const a = screen(vm);
		await a.waitFor(PROMPT);
		vm.write("X=w-kept; echo saved-$X\n");
		await a.waitFor(/saved-w-kept/);
		const snap = await vm.snapshot({ stop: true });
		assert.equal((await vm.exited).kind, "stopped");
		assert.equal(snap.memory.byteLength, 512 * 1048576, "the memory came across");

		const vm2 = await boot(t, { vsock: false, restore: snap, log: () => {} });
		assert.ok(vm2 instanceof sdk.KernelInstance);
		const b = screen(vm2);
		vm2.write("echo inline-$X\n");
		await b.waitFor(/inline-w-kept/);
		await vm2.stop({ reason: "test" });

		const vm3 = await boot(t, { worker: true, vsock: false, restore: snap, transferRestore: true, log: () => {} });
		assert.equal(snap.memory.byteLength, 0, "transferRestore handed the buffer over");
		const c = screen(vm3);
		vm3.write("echo worker-$X\n");
		await c.waitFor(/worker-w-kept/);
		vm3.write("poweroff\n");
		assert.equal((await vm3.exited).code, 0);
	});

	test("worker mode: snapshot() with a data disk, resumed in a worker and saved again, then inline; refused once the disk changed", { skip: noSnapshots }, async (t) => {
		const dir = mkdtempSync(path.join(tmpdir(), "unkernel-api-"));
		t.after(() => rmSync(dir, { recursive: true, force: true }));
		const module = await WebAssembly.compile(readFileSync(kernelFile));
		const file = path.join(dir, "data.img");
		await createImageFromKwsparse(file, bundledBoot(module).datadisk!);
		const spec = { kind: "file", path: file } as const;

		const vm = await boot(t, { worker: true, kernel: module, vsock: false, disks: [spec], log: () => {} });
		const a = screen(vm);
		await a.waitFor(PROMPT);
		vm.write("echo one > /data/one; echo ready-$((6*7))\n");
		await a.waitFor(/ready-42/);
		const snapA = await vm.snapshot({ stop: true });
		assert.equal((await vm.exited).kind, "stopped");
		assert.equal(snapA.disks[0]?.name, file);

		const vm2 = await boot(t, { worker: true, kernel: module, vsock: false, disks: [spec], restore: snapA, log: () => {} });
		assert.equal(snapA.memory.byteLength, 512 * 1048576, "copied, not transferred, by default");
		const b = screen(vm2);
		vm2.write("echo two > /data/two; echo got-$(cat /data/one)\n");
		await b.waitFor(/got-one/);
		const snapB = await vm2.snapshot({ stop: true });
		await vm2.exited;

		const vm3 = await boot(t, { kernel: module, vsock: false, disks: [new FileDisk(file)], restore: snapB, log: () => {} });
		const c = screen(vm3);
		// vm2's write was still in the page cache (snapB): written back only now, which changes the disk.
		vm3.write("echo both-$(cat /data/one)-$(cat /data/two); sync; echo synced-$((6*7))\n");
		await c.waitFor(/both-one-two[\s\S]*synced-42/);
		await vm3.stop({ reason: "test" });
		await assert.rejects(boot(t, { worker: true, kernel: module, vsock: false, disks: [spec], restore: snapA, log: () => {} }),
			/snapshot: disk wda \(.*data\.img\) was written after the snapshot/);
	});

	test("SMP: ConsoleRing wrap-around, record splitting, 'take', and 'post' batching, stall drop and recovery; ConsoleOrder reordering and flush", async () => {
		const { ConsoleRing } = await import("../js/core/console-ring.ts");
		const { ConsoleOrder } = await import("../js/core/cpu.ts");
		const enc = new TextEncoder(), dec = new TextDecoder();

		// Invalid ring sizes are refused.
		assert.throws(() => new ConsoleRing(new SharedArrayBuffer(64)), /bad size/);
		assert.throws(() => new ConsoleRing(new SharedArrayBuffer(64 + 100)), /bad size/);

		// 64-byte control header + 256-byte data ring (#maxRecord = 64).
		const ring = new ConsoleRing(new SharedArrayBuffer(64 + 256));
		assert.ok(ring.quiet && !ring.pending && !ring.closed);
		// Wrap around the 256-byte ring boundary and split a 150-byte write (64 + 64 + 22) with "take".
		const taken: Uint8Array[] = [];
		const msg1 = enc.encode("A".repeat(60) + "B".repeat(60) + "C".repeat(60));
		assert.equal(ring.write(msg1, 0, msg1.length, "take", (b) => taken.push(b.bytes)), 0);
		const msg2 = enc.encode("D".repeat(150));
		assert.equal(ring.write(msg2, 0, msg2.length, "take", (b) => taken.push(b.bytes)), 0);
		const tail = ring.take();
		if (tail) taken.push(tail.bytes);
		assert.equal(dec.decode(Buffer.concat(taken)), "A".repeat(60) + "B".repeat(60) + "C".repeat(60) + "D".repeat(150));
		assert.equal(ring.dropped, 0);

		// "post": up to MAX_BATCHES (16) batches are posted out of a full ring;
		// the 17th waits STALL_MS (50 ms) for TAKEN to move, then drops, and
		// later writes drop without waiting until batchTaken() is called.
		const posted: Array<{ seq: number; bytes: Uint8Array }> = [];
		const chunk = enc.encode("X".repeat(64));
		let dropped = 0;
		for (let i = 0; i < 100 && dropped === 0; i++) {
			dropped = ring.write(chunk, 0, chunk.length, "post", (b) => posted.push(b));
		}
		assert.equal(posted.length, 16, "MAX_BATCHES posted before dropping");
		assert.equal(dropped, 64);
		assert.equal(ring.dropped, 64);
		const t0 = performance.now();
		assert.equal(ring.write(chunk, 0, chunk.length, "post", (b) => posted.push(b)), 64, "stalled writer drops at once without waiting again");
		assert.ok(performance.now() - t0 < 25);
		assert.equal(ring.dropped, 128);
		ring.batchTaken();
		for (let i = 0; i < 3; i++) {
			assert.equal(ring.write(chunk, 0, chunk.length, "post", (b) => posted.push(b)), 0, "recovers once CPU 0 takes a batch");
		}
		ring.close();
		assert.equal(ring.closed, true);
		assert.equal(ring.write(chunk, 0, chunk.length, "take", () => {}), 64, "closed full ring drops writes");

		// ConsoleOrder: out-of-order batches, flush() at exit, and a late batch that flush() skipped.
		const ordered: string[] = [];
		const ord = new ConsoleOrder((b) => ordered.push(dec.decode(b)));
		ord.put(2, enc.encode("two"));
		ord.put(0, enc.encode("zero"));
		assert.deepEqual(ordered, ["zero"]);
		assert.equal(ord.empty, false);
		ord.put(1, enc.encode("one"));
		assert.deepEqual(ordered, ["zero", "one", "two"]);
		assert.equal(ord.empty, true);
		ord.put(5, enc.encode("five"));
		ord.put(4, enc.encode("four"));
		ord.flush();
		assert.deepEqual(ordered, ["zero", "one", "two", "four", "five"]);
		ord.put(3, enc.encode("three-late"));
		assert.deepEqual(ordered, ["zero", "one", "two", "four", "five", "three-late"]);
	});

	test("SMP: runCpu boundary errors (bad initFlag, missing entry, CPU-0 device import, trap, proc_exit) all raise the stop IPI on CPU 0", async () => {
		const { runCpu } = await import("../js/core/cpu.ts");
		const { newConsoleRing } = await import("../js/core/console-ring.ts");
		const IPI_STOP = 1 << 26;
		const enc = new TextEncoder();
		const sec = (id: number, body: number[]) => [id, body.length, ...body];
		const str = (s: string) => { const b = enc.encode(s); return [b.length, ...b]; };
		const wasm = (...sections: number[][]) => new WebAssembly.Module(Uint8Array.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, ...sections.flat()]));
		const exports2 = (fnIdx: number) => sec(7, [2, ...str("ret_from_fork"), 0, fnIdx, ...str("kw_secondary_entry"), 0, fnIdx]);

		const run = async (module: WebAssembly.Module, flagVal = 2) => {
			const memory = new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true });
			const i32 = new Int32Array(memory.buffer);
			Atomics.store(i32, 16 >> 2, flagVal);
			const msgs: Array<{ t: string; msg?: string; error?: string; code?: number }> = [];
			await runCpu({
				cpu: 1, idle: 0n, module, memory, cpus: 2, initFlag: 16, irqWord0: 32,
				epochMs: 0, jit: false, memory64: false, console: newConsoleRing(), consoleFull: "wait",
			}, { post: (m) => msgs.push(m as never) });
			await new Promise((r) => setTimeout(r, 20));
			return { msgs, irq0: Atomics.load(i32, 32 >> 2) };
		};

		// 1. __wasm_init_memory_flag != 2: refuses before instantiating.
		const rFlag = await run(wasm(), 0);
		assert.ok(rFlag.msgs.some((m) => m.t === "fatal" && /data-segment flag/.test(m.msg ?? "")) && (rFlag.irq0 & IPI_STOP) !== 0);

		// 2. Missing kw_secondary_entry export.
		const rNoEntry = await run(wasm());
		assert.ok(rNoEntry.msgs.some((m) => m.t === "fatal" && /no kw_secondary_entry/.test(m.msg ?? "")) && (rNoEntry.irq0 & IPI_STOP) !== 0);

		// 3. Calling a CPU-0-only device import on CPU 1 -> fatal.
		const modDev = wasm(
			sec(1, [2, 0x60, 0, 0, 0x60, 1, 0x7e, 0]),
			sec(2, [1, ...str("unkernel"), ...str("wasm_driver_fb_init"), 0, 0]),
			sec(3, [1, 1]),
			exports2(1),
			sec(10, [1, 4, 0, 0x10, 0, 0x0b]),
		);
		const rDev = await run(modDev);
		assert.ok(rDev.msgs.some((m) => m.t === "fatal" && /unkernel\.wasm_driver_fb_init/.test(m.msg ?? "")) && (rDev.irq0 & IPI_STOP) !== 0);

		// 4. Wasm trap (unreachable) on CPU 1 -> trap.
		const modTrap = wasm(sec(1, [1, 0x60, 1, 0x7e, 0]), sec(3, [1, 0]), exports2(0), sec(10, [1, 3, 0, 0x00, 0x0b]));
		const rTrap = await run(modTrap);
		assert.ok(rTrap.msgs.some((m) => m.t === "trap") && (rTrap.irq0 & IPI_STOP) !== 0);

		// 5. proc_exit(2) on CPU 1 -> exit code 2.
		const modExit = wasm(
			sec(1, [2, 0x60, 1, 0x7f, 0, 0x60, 1, 0x7e, 0]),
			sec(2, [1, ...str("wasi_snapshot_preview1"), ...str("proc_exit"), 0, 0]),
			sec(3, [1, 1]),
			exports2(1),
			sec(10, [1, 6, 0, 0x41, 2, 0x10, 0, 0x0b]),
		);
		const rExit = await run(modExit);
		assert.ok(rExit.msgs.some((m) => m.t === "exit" && m.code === 2) && (rExit.irq0 & IPI_STOP) !== 0);
	});

	test("SMP: cpus: 2 on a UP-only module falls back to 1 CPU; on the bundle boots 2 CPUs, rejects snapshot(), and a secondary CPU's poweroff or panic stops a spinning CPU 0",
		{ skip: !kernelHasSmp && "the bundle under test has no SMP kernel" }, async (t) => {
		// 1. A pre-compiled UP WebAssembly.Module ignores cpus: 2 with a log line and runs on 1 CPU.
		if (!kernelIsSmp) {
			const logs: string[] = [];
			const up = await boot(t, { kernel: kernelModule, cpus: 2, vsock: false, log: (m) => logs.push(m) });
			assert.equal(up.stats().cpus, 1);
			assert.ok(logs.some((l) => /this kernel is not SMP: 2 CPUs asked/.test(l)), logs.join("\n"));
			await up.stop({ reason: "test" });
		}

		// 2. Booting 2 CPUs from the bundle: snapshot() rejects, and a poweroff on CPU 1 while CPU 0 spins exits 0.
		const vm = await boot(t, { worker: true, cpus: 2, vsock: false, log: () => {} });
		const { waitFor } = screen(vm);
		await waitFor(PROMPT);
		assert.equal(vm.stats().cpus, 2);
		await assert.rejects(vm.snapshot(), /cannot resume one/);
		vm.write("for c in 0 1; do (while :; do read -r l < /proc/self/stat; set -- $l; [ \"${39}\" = 1 ] && poweroff -f; done) & done\n");
		assert.deepEqual(await vm.exited.then((r) => [r.code, r.kind]), [0, "halt"]);

		// 3. A panic on CPU 1 while CPU 0 spins in user mode: CPU 1 raises the stop IPI on CPU 0 and exits 253.
		const kernelLines: string[] = [];
		const router = new ConsoleRouter({ onKernelLine: (l) => kernelLines.push(l) });
		const vm2 = await boot(t, { worker: true, cpus: 2, vsock: false, log: () => {}, onOutput: (b) => router.write(b) });
		const s2 = screen(vm2);
		await s2.waitFor(PROMPT);
		vm2.write("for c in 0 1; do (while :; do read -r l < /proc/self/stat; set -- $l; [ \"${39}\" = 1 ] && echo c > /proc/sysrq-trigger; done) & done\n");
		const res2 = await vm2.exited;
		assert.deepEqual([res2.code, res2.kind], [253, "panic"]);
		assert.ok(kernelLines.some((l) => /Kernel panic|sysrq: Trigger a crash/i.test(l)), kernelLines.slice(-10).join("\n"));
	});

	test("CLI: --smp above availableParallelism() warns on stderr", { skip: availableParallelism() >= 32 && "host has >= 32 CPU threads" }, () => {
		const cli = path.resolve(path.dirname(fileURLToPath(import.meta.url)), process.env.UNKERNEL_DIST ? "../dist/cli.mjs" : "../js/cli.ts");
		const host = availableParallelism();
		const over = spawnSync(process.execPath, [cli, "--smp", String(host + 1), "--kernel", "/nonexistent-unkernel-check.wasm"], { encoding: "utf8" });
		assert.equal(over.status, 1);
		assert.match(over.stderr, new RegExp(`warning: --smp ${host + 1} exceeds this host's ${host} CPU thread`));
		const ok = spawnSync(process.execPath, [cli, "--smp", String(Math.min(2, host)), "--kernel", "/nonexistent-unkernel-check.wasm"], { encoding: "utf8" });
		assert.equal(ok.status, 1);
		assert.doesNotMatch(ok.stderr, /warning: --smp/);
	});

});

// Not with the others: it changes globalThis.crossOriginIsolated, which every worker-mode boot reads.
test("worker mode: messages where SharedArrayBuffer cannot be used (a page that is not cross-origin isolated); shared: true then rejects", async (t) => {
	const g = globalThis as { crossOriginIsolated?: boolean };
	g.crossOriginIsolated = false;
	try {
		assert.equal(sdk.sharedMemoryAvailable(), false);
		await assert.rejects(createKernel({ worker: true, shared: true, log: () => {} }), (e: Error) =>
			e.name === "BootError" && (e as Error & { stage: string }).stage === "support" && /cross-origin isolated/.test(e.message));
		const vm = await boot(t, { worker: true, log: () => {}, cmdline: "console=hvc0 rdinit=/bin/true" });
		assert.equal(vm.transport, "messages");
		assert.equal((await vm.exited).code, 253);
	} finally {
		delete g.crossOriginIsolated;
	}
	assert.equal(sdk.sharedMemoryAvailable(), true);
});

// Not with the others: temporarily removes Atomics.waitAsync to exercise ConsoleRingReader's 4 ms polling fallback.
test("SMP: ConsoleRingReader falls back to 4 ms polling when Atomics.waitAsync is absent", async () => {
	const { ConsoleRing, ConsoleRingReader, newConsoleRing } = await import("../js/core/console-ring.ts");
	const a = Atomics as { waitAsync?: typeof Atomics.waitAsync };
	const orig = a.waitAsync;
	delete a.waitAsync;
	try {
		const ring = new ConsoleRing(newConsoleRing());
		const dec = new TextDecoder(), enc = new TextEncoder();
		let got = "";
		const reader = new ConsoleRingReader(ring, (b) => { got += dec.decode(b.bytes); });
		reader.start();
		try {
			const b1 = enc.encode("poll-1\n"), b2 = enc.encode("poll-2\n");
			await new Promise((r) => setTimeout(r, 10));
			ring.write(b1, 0, b1.length, "wait");
			await new Promise((r) => setTimeout(r, 15));
			ring.write(b2, 0, b2.length, "wait");
			for (let i = 0; i < 30 && got !== "poll-1\npoll-2\n"; i++) {
				await new Promise((r) => setTimeout(r, 5));
			}
			assert.equal(got, "poll-1\npoll-2\n");
		} finally {
			reader.stop();
			ring.close();
		}
	} finally {
		if (orig) a.waitAsync = orig;
	}
});