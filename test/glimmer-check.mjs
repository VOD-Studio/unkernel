#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Checks the display, input and sound self-test, `glimmer --test` (the
// guest program kernel/guest/glimmer.c; its header documents the pattern,
// the test signal and the output lines).
//
//   bun test/glimmer-check.mjs FRAME.ppm [--size WxH]
//   bun test/glimmer-check.mjs --wav SOUND.wav
//   bun test/glimmer-check.mjs --run [--kernel BUNDLE] [--initrd FILE] [--smp N] [--no-jit]
//        [--boot SECONDS] [--mode WxH] [--no-sound] [--worker[=shared|messages]] [--keep] [--verbose]
//
// With a frame (a PPM, as the CLI's {fb=FILE} writes it), it compares every
// pixel with the pattern for a WxH mode at the top left (default: the whole
// frame); everything outside it must be black.
//
// With --wav (a recording of the test signal, as the CLI's --sound-wav
// writes it), it checks the format (PCM, 22050 Hz, 2 channels, 16 bit), the
// length (3 s, within 10 ms), in each second the frequency (within 1 Hz),
// level (0.5 within 0.01) and purity (99% of the power) on the channels that
// should carry it and silence on the other, and, when the length is exact,
// every sample against the formula (within 1 LSB).
//
// --run boots the CLI (bun js/cli.ts --display --sound-wav FILE) on BUNDLE
// (default: the CLI's own), waits --boot seconds for the shell (default 12,
// 45 with --no-jit), runs `glimmer --test 10` (with GLIMMER_MODE=WxH for
// --mode), saves a frame, injects keys, mouse motion, buttons and wheel
// clicks, absolute positions, a button and a wheel click on the tablet, and
// powers off. It then checks the test's lines, the frame against
// the mode the test printed, that the tablet lists ABS_X and ABS_Y over
// 0..32767, that each device reported exactly the injected events in order
// (EV_SYN aside), and the recording as --wav does, and that
// the PCM was closed. With --no-sound the guest gets no sound card, and the
// test must say so and pass the rest. --worker runs the CLI with --worker
// (the kernel in a worker thread: input and frames through shared memory,
// PCM as messages); --worker=messages and --worker=shared pick the
// transport, and the CLI must report that one. --initrd and --smp N go to
// the CLI as they are (--smp needs an SMP kernel and implies --worker).
// Files go to a temp dir, removed unless
// --keep. Exit status 0 when everything matches.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const opt = (name) => {
	const i = args.indexOf(`--${name}`);
	return i >= 0 ? args[i + 1] : undefined;
};
const flag = (name) => args.includes(`--${name}`);
const workerArg = args.find((a) => a === "--worker" || a.startsWith("--worker="));
const parseSize = (s) => {
	const m = /^(\d+)x(\d+)$/.exec(s ?? "");
	return m ? { w: Number(m[1]), h: Number(m[2]) } : undefined;
};

/** The pattern's colour (0xRRGGBB) at x, y for a w x h mode; kernel/guest/glimmer.c test_pixel(). */
export function testPixel(x, y, w, h) {
	const bars = [0xffffff, 0xffff00, 0x00ffff, 0x00ff00, 0xff00ff, 0xff0000, 0x0000ff, 0x000000];
	const div = (a, b) => Math.floor(a / b);
	if (x >= w || y >= h) return 0;
	if (x === 0 || y === 0 || x === w - 1 || y === h - 1) return 0xffffff;
	if (x < 9 && y < 9) return 0xff0000;
	if (x >= w - 9 && y < 9) return 0x00ff00;
	if (x < 9 && y >= h - 9) return 0x0000ff;
	if (x >= w - 9 && y >= h - 9) return 0xffff00;
	if (y < div(h, 4)) return bars[div(x * 8, w)];
	if (y < div(h, 2)) return div(x * 255, w - 1) * 0x010101;
	if (y < div(h * 3, 4)) return (div(x, 8) + div(y, 8)) & 1 ? 0xff8000 : 0x000040;
	const v = div(y * 255, h - 1);
	return (v << 8) | (255 - v);
}

function readPpm(file) {
	const d = fs.readFileSync(file);
	const tokens = [];
	let i = 0;
	while (tokens.length < 4) {
		while (/\s/.test(String.fromCharCode(d[i]))) i++;
		if (d[i] === 0x23) { // a comment
			while (d[i] !== 0x0a) i++;
			continue;
		}
		const start = i;
		while (!/\s/.test(String.fromCharCode(d[i]))) i++;
		tokens.push(d.subarray(start, i).toString());
	}
	if (tokens[0] !== "P6" || tokens[3] !== "255") throw new Error(`${file}: not a binary PPM with maxval 255`);
	const w = Number(tokens[1]), h = Number(tokens[2]);
	const px = d.subarray(i + 1);
	if (px.length < w * h * 3) throw new Error(`${file}: truncated (${px.length} of ${w * h * 3} bytes)`);
	return { w, h, px };
}

/** Compare a frame with the pattern; returns a list of problems (empty = ok). */
export function checkFrame(file, size) {
	const { w, h, px } = readPpm(file);
	const pw = size?.w ?? w, ph = size?.h ?? h;
	if (pw > w || ph > h) return [`pattern ${pw}x${ph} does not fit the ${w}x${h} frame`];
	const bad = [];
	let wrong = 0;
	for (let y = 0; y < h; y++)
		for (let x = 0; x < w; x++) {
			const o = (y * w + x) * 3, got = (px[o] << 16) | (px[o + 1] << 8) | px[o + 2], want = testPixel(x, y, pw, ph);
			if (got !== want && wrong++ < 5) bad.push(`(${x},${y}) is ${hex(got)}, want ${hex(want)}`);
		}
	if (wrong > 5) bad.push(`... ${wrong} wrong pixels in all`);
	return bad;
}

const hex = (c) => `#${c.toString(16).padStart(6, "0")}`;

// ---- the test signal --------------------------------------------------------

/** The test signal: rate, and per second the frequency and which channels carry it; kernel/guest/glimmer.c test_signal(). */
export const SIGNAL = { rate: 22050, channels: 2, segments: [{ hz: 440, on: [1, 1] }, { hz: 660, on: [1, 0] }, { hz: 880, on: [0, 1] }] };

/** The sample the guest writes at frame f on channel c (0.5 * sin, times 32767, rounded half away from zero). */
export function signalSample(f, c) {
	const seg = SIGNAL.segments[Math.floor(f / SIGNAL.rate)];
	if (!seg || !seg.on[c]) return 0;
	const v = 0.5 * Math.sin(2 * Math.PI * ((seg.hz * f) % SIGNAL.rate) / SIGNAL.rate) * 32767;
	return Math.sign(v) * Math.floor(Math.abs(v) + 0.5);
}

function readWav(file) {
	const buf = fs.readFileSync(file);
	const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
	const tag = (o) => buf.toString("ascii", o, o + 4);
	if (buf.length < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") throw new Error(`${file}: not a WAV file`);
	let fmt, data;
	for (let o = 12; o + 8 <= buf.length;) {
		const id = tag(o), size = dv.getUint32(o + 4, true);
		if (id === "fmt ") fmt = { pcm: dv.getUint16(o + 8, true), channels: dv.getUint16(o + 10, true), rate: dv.getUint32(o + 12, true), bits: dv.getUint16(o + 22, true) };
		if (id === "data") data = { off: o + 8, size: Math.min(size, buf.length - o - 8) };
		o += 8 + size + (size & 1);
	}
	if (!fmt || !data) throw new Error(`${file}: no fmt or data chunk`);
	return { ...fmt, dv, data };
}

/** Check a recording of the test signal; returns { problems, summary }. */
export function checkWav(file) {
	let w;
	try { w = readWav(file); } catch (e) { return { problems: [e.message] }; }
	const problems = [];
	const { rate, channels } = SIGNAL;
	if (w.pcm !== 1 || w.rate !== rate || w.channels !== channels || w.bits !== 16)
		return { problems: [`format: PCM=${w.pcm}, ${w.rate} Hz, ${w.channels} ch, ${w.bits} bit; want PCM, ${rate} Hz, ${channels} ch, 16 bit`] };
	const frames = Math.floor(w.data.size / 4), want = SIGNAL.segments.length * rate;
	const sample = (f, c) => w.dv.getInt16(w.data.off + f * 4 + c * 2, true);
	if (Math.abs(frames - want) > rate / 100) problems.push(`length: ${frames} frames, want ${want} (within ${rate / 100})`);
	// Goertzel: the amplitude (of full scale) of a sine at hz in n frames from s
	const amp = (s, n, c, hz) => {
		const k = 2 * Math.cos(2 * Math.PI * hz / rate);
		let s1 = 0, s2 = 0;
		for (let i = 0; i < n; i++) { const s0 = sample(s + i, c) / 32768 + k * s1 - s2; s2 = s1; s1 = s0; }
		return Math.sqrt(Math.max(0, s1 * s1 + s2 * s2 - k * s1 * s2)) * 2 / n;
	};
	const parts = [];
	SIGNAL.segments.forEach((seg, i) => {
		const edge = Math.round(rate / 100), s = i * rate + edge, n = Math.min(rate - 2 * edge, frames - s);
		if (n < rate / 2) return problems.push(`second ${i + 1} (${seg.hz} Hz): missing`);
		for (let c = 0; c < channels; c++) {
			let rms = 0;
			for (let k = 0; k < n; k++) rms += (sample(s + k, c) / 32768) ** 2;
			rms = Math.sqrt(rms / n);
			const where = `second ${i + 1} ${c ? "right" : "left"}`;
			if (!seg.on[c]) {
				if (rms > 1e-3) problems.push(`${where}: should be silent, rms ${rms.toFixed(4)}`);
				continue;
			}
			if (rms < 1e-3) {
				problems.push(`${where}: silent, want ${seg.hz} Hz at 0.5`);
				continue;
			}
			let best = 0, bf = 0;
			for (let f = 100; f <= 4000; f += 5) { const a = amp(s, n, c, f); if (a > best) best = a, bf = f; }
			for (let f = bf - 5; f <= bf + 5; f += 0.1) { const a = amp(s, n, c, f); if (a > best) best = a, bf = f; }
			const share = best * best / 2 / (rms * rms || 1);
			if (Math.abs(bf - seg.hz) >= 1 || Math.abs(best - 0.5) > 0.01 || share < 0.99)
				problems.push(`${where}: ${bf.toFixed(1)} Hz at ${best.toFixed(3)} (${(share * 100).toFixed(1)}% of the power), want ${seg.hz} Hz at 0.5`);
		}
		parts.push(`${seg.hz} Hz ${seg.on[0] && seg.on[1] ? "both" : seg.on[0] ? "left" : "right"}`);
	});
	let exact = "";
	if (frames === want) {
		let off = 0, first = "";
		for (let f = 0; f < frames; f++)
			for (let c = 0; c < channels; c++) {
				const d = sample(f, c) - signalSample(f, c);
				if (Math.abs(d) > 1 && !off++) first = ` (first at frame ${f} ch ${c}: ${sample(f, c)}, want ${signalSample(f, c)})`;
			}
		if (off) problems.push(`samples: ${off} differ from the formula by more than 1${first}`);
		exact = ", sample exact";
	}
	return { problems, summary: `${rate} Hz ${channels} ch 16 bit, ${frames} frames (${(frames / rate).toFixed(3)} s), ${parts.join(", ")}${exact}` };
}

// ---- --run ------------------------------------------------------------------

// What --run injects, and what each device must report (EV_SYN left out).
// Tablet positions are fractions of the picture (x * 32768, clamped to 32767);
// the axes start at 0, which the kernel would not report again.
const INJECT = "{key=KeyA}{key=ArrowLeft:1}{key=ArrowLeft:0}{key=29}{rel=5,-3}{btn=left}{btn=right:1}{btn=right:0}{wheel=2}{wheel=-1}" +
	"{abs=25%,75%}{abs=100%,0%}{abtn=middle}{awheel=1}";
const EXPECT = {
	keyboard: ["EV_KEY 30 1", "EV_KEY 30 0", "EV_KEY 105 1", "EV_KEY 105 0", "EV_KEY 29 1", "EV_KEY 29 0"],
	mouse: ["EV_REL 0 5", "EV_REL 1 -3", "EV_KEY 272 1", "EV_KEY 272 0", "EV_KEY 273 1", "EV_KEY 273 0", "EV_REL 8 2", "EV_REL 8 -1"],
	tablet: ["EV_ABS 0 8192", "EV_ABS 1 24576", "EV_ABS 0 32767", "EV_ABS 1 0", "EV_KEY 274 1", "EV_KEY 274 0", "EV_REL 8 1"],
};

async function run() {
	const jit = !flag("no-jit");
	const sound = !flag("no-sound");
	const boot = Number(opt("boot") ?? (jit ? 12 : 45));
	const mode = opt("mode");
	if (mode && !parseSize(mode)) throw new Error(`--mode ${mode}: want WxH`);
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glimmer-check-"));
	const frame = path.join(dir, "frame.ppm"), wav = path.join(dir, "sound.wav");
	const cmd = `${mode ? `GLIMMER_MODE=${mode} ` : ""}glimmer --test 10`;
	const input = `{${boot}}${cmd}\\n{4}{fb=${frame}}{1}${INJECT}{9}poweroff\\n`;
	const cli = [path.join(root, "js/cli.ts"), "--display", "--no-net", "--timeout", String(boot + 60), "--input", input];
	if (sound) cli.push("--sound-wav", wav);
	if (opt("kernel")) cli.push("--kernel", opt("kernel"));
	if (opt("initrd")) cli.push("--initrd", opt("initrd"));
	if (opt("smp")) cli.push("--smp", opt("smp"));
	if (!jit) cli.push("--no-jit");
	if (workerArg) cli.push(workerArg);
	const child = spawn(process.execPath, cli, { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
	let out = "", err = "";
	child.stdout.on("data", (d) => (out += d));
	child.stderr.on("data", (d) => (err += d));
	const code = await new Promise((resolve) => child.on("exit", resolve));

	const problems = [];
	const lines = out.split(/\r?\n/).map((l) => l.replace(/^.*?(glimmer: )/, "$1")).filter((l) => l.startsWith("glimmer: "));
	const find = (re) => lines.map((l) => re.exec(l)).find(Boolean);
	if (code !== 0) problems.push(`the CLI exited with ${code} (want 0, power off)`);
	const transport = /\[host\] kernel worker: input and frames by (shared memory|messages)/.exec(err)?.[1];
	const wantTransport = workerArg === "--worker=messages" ? "messages" : workerArg === "--worker=shared" ? "shared memory" : undefined;
	if (wantTransport && transport !== wantTransport) problems.push(`the CLI reported input and frames by ${transport ?? "nothing"} (want ${wantTransport})`);
	const fb = find(/^glimmer: test fb "[^"]*" (\d+)x(\d+), 32 bpp, rgb 16\/8\/0/);
	const pat = find(/^glimmer: test pattern (\d+)x(\d+) at 0,0$/);
	if (!fb) problems.push("no \"glimmer: test fb ...\" line with a 32 bpp XRGB8888 mode");
	if (!pat) problems.push("no \"glimmer: test pattern WxH\" line");
	for (const want of [/^glimmer: test pwrite\/pread of rows 0\.\.\d+ ok$/, /^glimmer: test mmap ok, pattern drawn$/,
		/^glimmer: test ready/, /^glimmer: test done, \d+ events$/])
		if (!find(want)) problems.push(`no line matching ${want}`);
	if (!/\[host\] display: closed/.test(err)) problems.push("the host never saw the display closed");

	let soundSummary = "no sound device, as asked";
	if (sound) {
		if (!find(/^glimmer: test sound card 0: /)) problems.push("no \"glimmer: test sound card 0: ...\" line");
		if (!find(/^glimmer: test sound signal 22050 Hz, 2 ch, S16_LE, .*, 66150 frames$/)) problems.push("no \"glimmer: test sound signal ...\" line");
		const done = find(/^glimmer: test sound done, (\d+) frames in [\d.]+ s, (\d+) underrun\(s\)$/);
		if (!done) problems.push("no \"glimmer: test sound done ...\" line");
		else if (Number(done[1]) !== 66150) problems.push(`the test wrote ${done[1]} frames, want 66150`);
		const opens = (err.match(/\[host\] sound: open/g) ?? []).length, closes = (err.match(/\[host\] sound: close/g) ?? []).length;
		if (!opens || opens !== closes) problems.push(`the PCM was opened ${opens} times and closed ${closes} times`);
		if (fs.existsSync(wav) && fs.statSync(wav).size > 44) {
			const r = checkWav(wav);
			for (const p of r.problems) problems.push(`sound: ${p}`);
			soundSummary = `sound ${r.summary ?? "?"}${done ? `, ${done[2]} underrun(s)` : ""}`;
		} else {
			problems.push("nothing was recorded (no sound played)");
		}
	} else if (!find(/^glimmer: test sound: no sound device /)) {
		problems.push("no \"glimmer: test sound: no sound device\" line (run without a sound card)");
	}

	if (fb && pat && fs.existsSync(frame)) {
		const { w, h } = readPpm(frame);
		if (w !== Number(fb[1]) || h !== Number(fb[2])) problems.push(`the frame is ${w}x${h}, the test printed ${fb[1]}x${fb[2]}`);
		for (const p of checkFrame(frame, { w: Number(pat[1]), h: Number(pat[2]) })) problems.push(`frame: ${p}`);
	} else if (!fs.existsSync(frame)) {
		problems.push("no frame was saved");
	}

	// devices by name, then their events in order
	const devices = {};
	for (const l of lines) {
		const m = /^glimmer: test input (event\d+) "([^"]*)"/.exec(l);
		if (m) devices[/keyboard/i.test(m[2]) ? "keyboard" : /mouse/i.test(m[2]) ? "mouse" : /tablet/i.test(m[2]) ? "tablet" : m[2]] = m[1];
	}
	if (!find(/^glimmer: test input event\d+ "[^"]*tablet".*, abs0 0\.\.32767, abs1 0\.\.32767$/))
		problems.push("the tablet is not listed with ABS_X and ABS_Y over 0..32767");
	const counts = {};
	for (const [kind, want] of Object.entries(EXPECT)) {
		const node = devices[kind];
		if (!node) {
			problems.push(`no ${kind} device listed`);
			continue;
		}
		const got = lines.map((l) => new RegExp(`^glimmer: event ${node} (EV_\\w+ \\d+ -?\\d+)$`).exec(l)?.[1])
			.filter((e) => e && !e.startsWith("EV_SYN"));
		counts[kind] = got.length;
		if (got.join(", ") !== want.join(", ")) problems.push(`${kind} (${node}) events: got [${got.join(", ")}], want [${want.join(", ")}]`);
	}

	if (flag("verbose") || problems.length) process.stdout.write(lines.join("\n") + "\n");
	if (problems.length) {
		for (const p of problems) process.stdout.write(`glimmer-check: FAIL ${p}\n`);
		process.stdout.write(`glimmer-check: files kept in ${dir}\n`);
		return 1;
	}
	process.stdout.write(`glimmer-check: ok: mode ${fb[1]}x${fb[2]}, pattern ${pat[1]}x${pat[2]} pixel exact, ` +
		`${counts.keyboard} keyboard, ${counts.mouse} mouse and ${counts.tablet} tablet events as injected, ${soundSummary} (${jit ? "JIT" : "no JIT"}${workerArg ? `, worker${transport ? ` (${transport})` : ""}` : ""})\n`);
	if (flag("keep")) process.stdout.write(`glimmer-check: files kept in ${dir}\n`);
	else fs.rmSync(dir, { recursive: true, force: true });
	return 0;
}

if (flag("run")) {
	process.exit(await run());
} else if (opt("wav")) {
	const { problems, summary } = checkWav(opt("wav"));
	for (const p of problems) process.stdout.write(`glimmer-check: FAIL ${p}\n`);
	if (!problems.length) process.stdout.write(`glimmer-check: ok: ${opt("wav")}: ${summary}\n`);
	process.exit(problems.length ? 1 : 0);
} else if (args[0] && !args[0].startsWith("--")) {
	const size = opt("size");
	if (size && !parseSize(size)) throw new Error(`--size ${size}: want WxH`);
	const problems = checkFrame(args[0], parseSize(size));
	for (const p of problems) process.stdout.write(`glimmer-check: FAIL ${p}\n`);
	if (!problems.length) process.stdout.write(`glimmer-check: ok: ${args[0]} matches the pattern\n`);
	process.exit(problems.length ? 1 : 0);
} else {
	process.stdout.write("usage: bun test/glimmer-check.mjs FRAME.ppm [--size WxH]\n" +
		"       bun test/glimmer-check.mjs --wav SOUND.wav\n" +
		"       bun test/glimmer-check.mjs --run [--kernel BUNDLE] [--initrd FILE] [--smp N] [--no-jit] [--boot S] [--mode WxH] [--no-sound] [--worker[=shared|messages]] [--keep] [--verbose]\n");
	process.exit(2);
}
