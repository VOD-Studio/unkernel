// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Unit tests for the kwtty client (core/tty.ts) without a kernel: a fake
// Vsock whose connect() returns a connection made of in-memory web
// streams, and a small stand-in for the guest server (kernel/guest/kwtty.c)
// that decodes the host's frames with its own code.
//
//   bun test ./test/tty.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { TTY_PORT, PtyError, connectGuest, connectOn, encodeTtyOpen, execOn, execSubprocess, spawnOn, spawnPty, spawnSubprocess, type PtyOptions, type Pty, type Subprocess } from "../js/core/tty.ts";
import type { ByteDuplex } from "../js/core/http.ts";
import { VsockError, type Vsock, type VsockConnection, type VsockListener } from "../js/core/vsock.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();
const le16 = (n: number) => [n & 0xff, (n >> 8) & 0xff];
const le32 = (n: number) => [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >>> 24) & 0xff];
const bytes = (x: string | ArrayLike<number>) => (typeof x === "string" ? enc.encode(x) : Uint8Array.from(x));
/** A frame, built independently of tty.ts. */
const frame = (type: number, payload: string | ArrayLike<number> = [], flags = 0) => {
	const p = bytes(payload);
	return Uint8Array.from([type, flags, ...le16(p.length), ...p]);
};
const OPENED = (pid: number, pts: number, version = 1, features = 0) => frame(1, [...le16(version), ...le32(features), ...le32(pid), ...le32(pts)]);
const DATA = (s: string | ArrayLike<number>) => frame(2, s);
const EXIT = (how: number, code: number, core = 0) => frame(4, [how, code, core]);
const ERROR = (msg: string) => frame(5, msg);
const STDERR = (s: string | ArrayLike<number>) => frame(8, s);
const cat = (...parts: Uint8Array[]) => {
	const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
	let at = 0;
	for (const p of parts) {
		out.set(p, at);
		at += p.length;
	}
	return out;
};
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const isPtyError = (code: string, msg?: RegExp) => (e: unknown) =>
	e instanceof PtyError && e.name === "PtyError" && e.code === code && (!msg || msg.test(e.message));

interface Frame { type: number; flags: number; payload: Uint8Array }

/** The guest server's side of one connection: decodes what the host sends and sends raw bytes back. */
class FakeConn implements VsockConnection {
	readonly localPort = 49152;
	readonly remotePort: number;
	readonly readable: ReadableStream<Uint8Array>;
	readonly writable: WritableStream<Uint8Array | string>;
	readonly closed: Promise<"closed" | "reset">;
	/** How the host ended it, if it did. */
	hostEnd: "close" | "reset" | undefined;
	/** Bytes the host's reader took: what vsock would give back as credit. */
	taken = 0;
	frames: Frame[] = [];
	/** Everything the host sent, as sent. */
	raw = new Uint8Array(0);
	/** The host closed its writable (a half-close). */
	writeClosed = false;
	#in = new Uint8Array(0);
	#frameWaiters: Array<() => void> = [];
	#out: Uint8Array[] = [];
	#rc!: ReadableStreamDefaultController<Uint8Array>;
	#want = false;
	#eof: "eof" | "reset" | undefined;
	#done = false;
	#resolveClosed!: (how: "closed" | "reset") => void;

	constructor(port: number) {
		this.remotePort = port;
		this.closed = new Promise((r) => (this.#resolveClosed = r));
		this.readable = new ReadableStream<Uint8Array>({
			start: (c) => { this.#rc = c; },
			pull: () => {
				this.#want = true;
				this.#pump();
			},
		}, { highWaterMark: 0 });
		this.writable = new WritableStream<Uint8Array | string>({
			write: (chunk) => {
				if (this.hostEnd || this.#eof) throw new VsockError("EPIPE", "the connection is closed");
				this.#receive(typeof chunk === "string" ? enc.encode(chunk) : chunk);
			},
			close: () => {
				this.writeClosed = true;
			},
		});
	}

	#receive(b: Uint8Array): void {
		this.raw = cat(this.raw, b);
		this.#in = cat(this.#in, b);
		while (this.#in.length >= 4) {
			const n = this.#in[2]! | (this.#in[3]! << 8);
			if (this.#in.length < 4 + n) break;
			this.frames.push({ type: this.#in[0]!, flags: this.#in[1]!, payload: this.#in.slice(4, 4 + n) });
			this.#in = this.#in.slice(4 + n);
		}
		for (const w of this.#frameWaiters.splice(0)) w();
	}

	/** Wait until the host has sent `n` frames. */
	async waitFrames(n: number): Promise<Frame[]> {
		while (this.frames.length < n) await new Promise<void>((r) => this.#frameWaiters.push(r));
		return this.frames;
	}

	/** Send raw bytes to the host, as one chunk each. */
	send(...chunks: Uint8Array[]): void {
		this.#out.push(...chunks);
		this.#pump();
	}

	/** Send `b` one byte at a time. */
	trickle(b: Uint8Array): void {
		for (const x of b) this.#out.push(Uint8Array.of(x));
		this.#pump();
	}

	/** The guest closes (EOF after what was sent), or resets. */
	end(how: "eof" | "reset" = "eof"): void {
		this.#eof = how;
		this.#pump();
	}

	/** Chunks sent and not read by the host yet. */
	get unread(): number {
		return this.#out.length;
	}

	#pump(): void {
		if (this.#done || !this.#want) return;
		const c = this.#out.shift();
		if (c) {
			this.#want = false;
			this.taken += c.length;
			this.#rc.enqueue(c);
			return;
		}
		if (this.#eof) {
			this.#done = true;
			if (this.#eof === "reset") this.#rc.error(new VsockError("ECONNRESET", "the guest reset the connection"));
			else this.#rc.close();
			this.#resolveClosed(this.#eof === "reset" ? "reset" : "closed");
		}
	}

	#hostEnds(how: "close" | "reset"): void {
		this.hostEnd ??= how;
		if (!this.#done) {
			this.#done = true;
			this.#out = [];
			try { if (how === "reset") this.#rc.error(new VsockError("ECONNRESET", "reset")); else this.#rc.close(); } catch {}
		}
		this.#resolveClosed(how === "reset" ? "reset" : "closed");
	}

	close(): void {
		this.#hostEnds("close");
	}

	reset(): void {
		this.#hostEnds("reset");
	}
}

/** A Vsock whose connect() is refused `refuse` times, hangs (no answer until its timeout) with `hang`, then gives FakeConns. */
function fakeVsock(opts: { refuse?: number; hang?: boolean } = {}) {
	const conns: FakeConn[] = [];
	const waiters: Array<(c: FakeConn) => void> = [];
	const calls: Array<{ port: number; timeout?: number }> = [];
	let refused = 0;
	const vsock: Vsock = {
		guestCid: 3,
		stats: { open: 0, accepted: 0, connected: 0, refused: 0, resets: 0, bytesIn: 0, bytesOut: 0, violations: 0 },
		listen(): VsockListener {
			throw new Error("not in the fake");
		},
		async connect(port, o) {
			calls.push({ port, timeout: o?.timeout });
			await tick();
			if (refused < (opts.refuse ?? 0)) {
				refused++;
				throw new VsockError("ECONNREFUSED", "refused");
			}
			if (opts.hang) {
				await tick(o?.timeout ?? 10000);
				throw new VsockError("ETIMEDOUT", "no answer");
			}
			const c = new FakeConn(port);
			const w = waiters.shift();
			if (w) w(c);
			else conns.push(c);
			return c;
		},
	};
	const next = () => {
		const c = conns.shift();
		return c ? Promise.resolve(c) : new Promise<FakeConn>((r) => waiters.push(r));
	};
	return { vsock, next, calls };
}

/** Open a session against a fresh fake: the guest answers OPEN with OPENED. */
async function session(opts: Partial<PtyOptions> = {}, pid = 42, pts = 0) {
	const f = fakeVsock();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80, ...opts });
	const c = await f.next();
	await c.waitFrames(1);
	c.send(OPENED(pid, pts));
	const s = await p;
	return { s, c, f };
}

async function readAll(s: Pty): Promise<string> {
	let text = "";
	for await (const chunk of s.output) text += dec.decode(chunk, { stream: true });
	return text;
}

/** Settled yet? */
async function state<T>(p: Promise<T>): Promise<"pending" | "settled"> {
	const pending = {};
	const r = await Promise.race([p.then(() => "settled" as const, () => "settled" as const), tick(20).then(() => pending)]);
	return r === pending ? "pending" : "settled";
}

test("handshake: OPEN carries the version, the size, TERM and ENV options; OPENED gives pid, pts and version", async () => {
	const f = fakeVsock();
	const p = spawnPty(f.vsock, undefined, [], { rows: 30, cols: 100, xpixel: 800, ypixel: 600, term: "vt100", env: { LANG: "C.UTF-8", FOO: "a=b" } });
	const c = await f.next();
	const [open] = await c.waitFrames(1);
	assert.equal(f.calls[0]!.port, TTY_PORT);
	assert.equal(TTY_PORT, 1022);
	assert.equal(open!.type, 1);
	assert.equal(open!.flags, 0);
	const tlv = (tag: number, v: string) => [tag, ...le16(v.length), ...enc.encode(v)];
	assert.deepEqual([...open!.payload], [
		...le16(1), ...le16(30), ...le16(100), ...le16(800), ...le16(600),
		...tlv(1, "vt100"), ...tlv(2, "LANG=C.UTF-8"), ...tlv(2, "FOO=a=b"),
	]);
	// OPENED split over two chunks.
	const o = OPENED(1234, 7);
	c.send(o.subarray(0, 5), o.subarray(5));
	const s = await p;
	assert.equal(s.pid, 1234);
	assert.equal(s.pts, 7);
	assert.equal(s.version, 1);
	assert.equal(s.features, 0);
	await s.close();

	// Defaults: TERM xterm-256color, no pixels, another port.
	const g = fakeVsock();
	const p2 = spawnPty(g.vsock, undefined, [], { rows: 1, cols: 2, port: 5555 });
	const c2 = await g.next();
	const [open2] = await c2.waitFrames(1);
	assert.equal(g.calls[0]!.port, 5555);
	assert.deepEqual([...open2!.payload], [...le16(1), ...le16(1), ...le16(2), 0, 0, 0, 0, ...tlv(1, "xterm-256color")]);
	c2.send(OPENED(1, 0));
	await (await p2).close();

	// Values the guest would refuse fail before connecting.
	const bads: Array<Partial<PtyOptions>> = [{ term: "" }, { term: "x".repeat(65) }, { term: "a\tb" }, { env: { "A=B": "c" } }, { env: { "": "c" } }, { env: { A: "b\0" } }, { rows: 70000 }, { cols: -1 }, { xpixel: 1.5 }];
	for (const bad of bads)
		assert.throws(() => encodeTtyOpen({ rows: 24, cols: 80, ...bad }), RangeError, JSON.stringify(bad));
	await assert.rejects(spawnPty(g.vsock, undefined, [], { rows: 24, cols: 80, env: { BIG: "x".repeat(70000) } }), RangeError);
	assert.equal(g.calls.length, 1, "no connect for bad options");
});

test("frames split and coalesced across chunk boundaries", async () => {
	const f = fakeVsock();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80 });
	const c = await f.next();
	await c.waitFrames(1);
	// OPENED and the first output in one chunk.
	c.send(cat(OPENED(5, 1), DATA("hello ")));
	const s = await p;
	const text = readAll(s);
	c.trickle(DATA("wor")); // one byte per chunk
	const d = DATA("ld!");
	c.send(d.subarray(0, 2), d.subarray(2, 3), d.subarray(3)); // the header split
	const big = "x".repeat(20000);
	const bf = DATA(big);
	c.send(bf.subarray(0, 7000), bf.subarray(7000, 14000), bf.subarray(14000));
	c.send(cat(DATA("\r\n"), DATA(""), DATA("bye"), EXIT(0, 0)), DATA("after EXIT is ignored"));
	assert.equal(await text, `hello world!${big}\r\nbye`);
	assert.deepEqual(await s.ended, { type: "exit", code: 0 });
	assert.equal(c.hostEnd, "close", "the host closes after EXIT");
});

test("write(): UTF-8, DATA frames of at most 4096 bytes, nothing for an empty write", async () => {
	const { s, c } = await session();
	const data = new Uint8Array(10000);
	for (let i = 0; i < data.length; i++) data[i] = (i * 7) & 0xff;
	await s.write(data);
	await s.write("");
	await s.write(new Uint8Array(0));
	await s.write("héllo");
	const frames = (await c.waitFrames(5)).slice(1);
	assert.equal(frames.length, 4);
	assert.deepEqual(frames.map((x) => [x.type, x.flags, x.payload.length]), [[2, 0, 4096], [2, 0, 4096], [2, 0, 1808], [2, 0, 6]]);
	assert.deepEqual(cat(...frames.slice(0, 3).map((x) => x.payload)), data);
	assert.equal(dec.decode(frames[3]!.payload), "héllo");
	await s.close();
});

test("resize(): RESIZE frames in order with DATA", async () => {
	const { s, c } = await session();
	const w1 = s.write("a");
	s.resize(132, 50, 10, 20);
	assert.deepEqual([s.cols, s.rows], [132, 50]);
	const w2 = s.write("b".repeat(5000));
	s.resize(2, 1);
	await Promise.all([w1, w2]);
	const frames = (await c.waitFrames(6)).slice(1);
	assert.deepEqual(frames.map((x) => [x.type, x.payload.length]), [[2, 1], [3, 8], [2, 4096], [2, 904], [3, 8]]);
	assert.deepEqual([...frames[1]!.payload], [...le16(50), ...le16(132), ...le16(10), ...le16(20)]);
	assert.deepEqual([...frames[4]!.payload], [...le16(1), ...le16(2), 0, 0, 0, 0]);
	assert.throws(() => s.resize(80, 65536), RangeError);
	assert.throws(() => s.resize(NaN, 24), RangeError);
	await s.close();
});

test("spawn(file, args, { cwd }): critical ARG and CWD options after TERM and ENV; 80x24 by default", async () => {
	const f = fakeVsock();
	const p = spawnPty(f.vsock, "ls", ["-l", "", "a b"], { cwd: "/tmp", env: { A: "1" } });
	const c = await f.next();
	const [open] = await c.waitFrames(1);
	const tlv = (tag: number, v: string) => [tag, ...le16(enc.encode(v).length), ...enc.encode(v)];
	assert.deepEqual([...open!.payload], [
		...le16(1), ...le16(24), ...le16(80), 0, 0, 0, 0,
		...tlv(1, "xterm-256color"), ...tlv(2, "A=1"),
		...tlv(0x83, "ls"), ...tlv(0x83, "-l"), ...tlv(0x83, ""), ...tlv(0x83, "a b"), ...tlv(0x84, "/tmp"),
	]);
	c.send(OPENED(9, 1));
	const s = await p;
	assert.deepEqual([s.cols, s.rows], [80, 24]);
	await s.close();
	for (const [file, args, opts] of [["", [], {}], [undefined, ["x"], {}], ["a\0b", [], {}], ["ls", ["\0"], {}], ["ls", [], { cwd: "" }]] as const)
		assert.throws(() => encodeTtyOpen({ rows: 24, cols: 80, file, args, ...opts }), RangeError, JSON.stringify([file, args, opts]));
});

test("kill(): a critical SIGNAL frame by name, ordered with DATA; exitCode and await using", async () => {
	const { s, c } = await session();
	const w = s.write("a");
	s.kill();
	s.kill("SIGTERM");
	s.kill("INT");
	assert.throws(() => s.kill("SIGNOPE"), RangeError);
	await w;
	const frames = (await c.waitFrames(5)).slice(1);
	assert.deepEqual(frames.map((x) => [x.type, x.flags, dec.decode(x.payload)]), [[2, 0, "a"], [6, 1, "HUP"], [6, 1, "TERM"], [6, 1, "INT"]]);
	assert.equal(s.exitCode, null);
	c.send(EXIT(1, 15));
	assert.equal(await readAll(s), "");
	assert.deepEqual(await s.ended, { type: "signal", signal: 15, coreDumped: false });
	assert.equal(s.exitCode, null, "no exit code after a signal");
	s.kill(); // a no-op once ended
	assert.equal(c.frames.length, 5);

	const t = await session();
	t.c.send(EXIT(0, 4));
	assert.equal(await readAll(t.s), "");
	assert.equal(t.s.exitCode, 4);

	let u: Awaited<ReturnType<typeof session>>;
	{
		u = await session();
		await using _pty = u.s;
	}
	assert.deepEqual(await u.s.ended, { type: "closed" });
	assert.equal(u.c.hostEnd, "close");
});

test("EXIT: ended {exit}, after the output was read", async () => {
	const { s, c } = await session();
	c.send(cat(DATA("last words"), EXIT(0, 3)));
	await tick(10);
	assert.equal(await state(s.ended), "pending", "ended waits for the reader");
	const reader = s.output.getReader();
	assert.equal(dec.decode((await reader.read()).value), "last words");
	assert.equal(await state(s.ended), "pending", "ended waits until the reader asks past the last output");
	assert.deepEqual(await reader.read(), { done: true, value: undefined });
	assert.deepEqual(await s.ended, { type: "exit", code: 3 });
	assert.equal(c.hostEnd, "close");
	await assert.rejects(s.write("x"), isPtyError("EPIPE"));
	s.resize(10, 10); // no throw, no frame
	assert.equal(c.frames.length, 1);
});

test("EXIT by a signal: ended {signal, coreDumped}", async () => {
	const { s, c } = await session();
	c.send(EXIT(1, 9, 1));
	assert.equal(await readAll(s), "");
	assert.deepEqual(await s.ended, { type: "signal", signal: 9, coreDumped: true });
	const t = await session();
	t.c.send(EXIT(1, 15, 0));
	void readAll(t.s);
	assert.deepEqual(await t.s.ended, { type: "signal", signal: 15, coreDumped: false });
});

test("ERROR: a PtyError EREMOTE with the guest's message, before or after OPENED", async () => {
	const { s, c } = await session();
	c.send(DATA("x"), ERROR("forkpty: Out of memory"));
	const reader = s.output.getReader();
	assert.equal(dec.decode((await reader.read()).value), "x");
	await assert.rejects(reader.read(), isPtyError("EREMOTE", /forkpty: Out of memory/));
	await assert.rejects(s.ended, isPtyError("EREMOTE", /forkpty: Out of memory/));
	assert.equal(c.hostEnd, "close");

	const f = fakeVsock();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80 });
	const c2 = await f.next();
	await c2.waitFrames(1);
	c2.send(ERROR("exec /bin/ash: No such file or directory"));
	c2.end();
	await assert.rejects(p, isPtyError("EREMOTE", /exec \/bin\/ash: No such file/));
	assert.equal(c2.hostEnd, "reset");
});

test("EOF or a reset without EXIT: ended {lost}", async () => {
	const { s, c } = await session();
	c.send(DATA("partial"), DATA("frame").subarray(0, 3));
	c.end();
	assert.equal(await readAll(s), "partial");
	assert.deepEqual(await s.ended, { type: "lost" });

	const t = await session();
	t.c.send(DATA("y"));
	t.c.end("reset");
	assert.equal(await readAll(t.s), "y");
	assert.deepEqual(await t.s.ended, { type: "lost" });

	// Before OPENED.
	const f = fakeVsock();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80 });
	(await f.next()).end();
	await assert.rejects(p, isPtyError("ECONNRESET"));
});

test("close(): ended {closed}, the output ends, the connection is hung up both ways", async () => {
	const { s, c } = await session();
	c.send(DATA("some"));
	const reader = s.output.getReader();
	assert.equal(dec.decode((await reader.read()).value), "some");
	const pending = reader.read(); // waiting for more when the host hangs up
	await s.close();
	assert.equal(c.hostEnd, "close");
	assert.deepEqual(await pending, { done: true, value: undefined });
	assert.deepEqual(await s.ended, { type: "closed" });
	await assert.rejects(s.write("x"), isPtyError("EPIPE"));
	await s.close(); // again: nothing happens

	// EXIT queued but not read when the host closes: closed wins.
	const t = await session();
	t.c.send(EXIT(0, 0));
	await t.s.close();
	assert.deepEqual(await t.s.ended, { type: "closed" });
});

test("unknown frames: skipped unless CRITICAL, which fails the session (EPROTO)", async () => {
	const f = fakeVsock();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80 });
	const c = await f.next();
	await c.waitFrames(1);
	c.send(frame(9, "before OPENED"), OPENED(1, 2), frame(9, "ignored", 0xfe), DATA("a"), frame(200, []), DATA("b"), EXIT(0, 0));
	const s = await p;
	assert.equal(await readAll(s), "ab");
	assert.deepEqual(await s.ended, { type: "exit", code: 0 });

	const t = await session();
	t.c.send(DATA("a"), frame(9, "x", 1), DATA("b"));
	const reader = t.s.output.getReader();
	assert.equal(dec.decode((await reader.read()).value), "a");
	await assert.rejects(reader.read(), isPtyError("EPROTO", /critical/));
	await assert.rejects(t.s.ended, isPtyError("EPROTO"));
	assert.equal(t.c.hostEnd, "close");

	// Malformed: a short EXIT, a second OPENED, DATA before OPENED, an unknown critical frame before OPENED, a short OPENED, a newer version.
	for (const bad of [frame(4, [0, 0]), EXIT(2, 0), OPENED(1, 1)]) {
		const u = await session();
		u.c.send(bad);
		void readAll(u.s).catch(() => {});
		await assert.rejects(u.s.ended, isPtyError("EPROTO"), JSON.stringify([...bad]));
	}
	for (const bad of [DATA("early"), EXIT(0, 0), frame(9, "", 1), frame(1, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]), OPENED(1, 1, 2), OPENED(1, 1, 0)]) {
		const g = fakeVsock();
		const q = spawnPty(g.vsock, undefined, [], { rows: 24, cols: 80 });
		const gc = await g.next();
		await gc.waitFrames(1);
		gc.send(bad);
		await assert.rejects(q, isPtyError("EPROTO"), JSON.stringify([...bad]));
		assert.equal(gc.hostEnd, "reset");
	}
});

test("connect: ECONNREFUSED is retried every 100 ms until the server listens", async () => {
	const f = fakeVsock({ refuse: 3 });
	const t0 = performance.now();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80 });
	const c = await f.next();
	await c.waitFrames(1);
	c.send(OPENED(9, 3));
	const s = await p;
	assert.equal(f.calls.length, 4);
	assert.ok(performance.now() - t0 >= 280, `${performance.now() - t0} ms`);
	assert.ok(f.calls.every((x) => x.timeout! > 0 && x.timeout! <= 30000), JSON.stringify(f.calls));
	assert.equal(s.pts, 3);
	await s.close();
});

test("timeout: ETIMEDOUT while refused, while connect hangs, and while OPENED does not come", async () => {
	let t0 = performance.now();
	const f = fakeVsock({ refuse: Infinity });
	await assert.rejects(spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80, timeout: 350 }), isPtyError("ETIMEDOUT", /port 1022 within 350 ms/));
	let ms = performance.now() - t0;
	assert.ok(ms >= 340 && ms < 1000, `${ms} ms`);
	assert.ok(f.calls.length >= 3 && f.calls.length <= 5, `${f.calls.length} connects`);

	t0 = performance.now();
	const h = fakeVsock({ hang: true });
	await assert.rejects(spawnPty(h.vsock, undefined, [], { rows: 24, cols: 80, timeout: 200 }), isPtyError("ETIMEDOUT"));
	ms = performance.now() - t0;
	assert.ok(ms >= 190 && ms < 1000, `${ms} ms`);
	assert.equal(h.calls.length, 1);
	assert.ok(h.calls[0]!.timeout! <= 200);

	const g = fakeVsock();
	const p = spawnPty(g.vsock, undefined, [], { rows: 24, cols: 80, timeout: 200 });
	const c = await g.next();
	await assert.rejects(p, isPtyError("ETIMEDOUT"));
	assert.equal(c.hostEnd, "reset", "the connection is reset");
});

test("signal: ABORTED while retrying, during the handshake, or already aborted", async () => {
	const f = fakeVsock({ refuse: Infinity });
	const ac = new AbortController();
	const p = spawnPty(f.vsock, undefined, [], { rows: 24, cols: 80, signal: ac.signal });
	await tick(150);
	ac.abort();
	await assert.rejects(p, isPtyError("ABORTED"));
	const n = f.calls.length;
	await tick(250);
	assert.equal(f.calls.length, n, "no connects after the abort");

	const g = fakeVsock();
	const ac2 = new AbortController();
	const q = spawnPty(g.vsock, undefined, [], { rows: 24, cols: 80, signal: ac2.signal });
	const c = await g.next();
	await c.waitFrames(1);
	ac2.abort();
	await assert.rejects(q, isPtyError("ABORTED"));
	assert.equal(c.hostEnd, "reset");

	const h = fakeVsock();
	await assert.rejects(spawnPty(h.vsock, undefined, [], { rows: 24, cols: 80, signal: AbortSignal.abort() }), isPtyError("ABORTED"));
	assert.equal(h.calls.length, 0);

	// After OPENED the signal has no effect.
	const ac3 = new AbortController();
	const { s, c: c3 } = await session({ signal: ac3.signal });
	ac3.abort();
	c3.send(DATA("still here"), EXIT(0, 0));
	assert.equal(await readAll(s), "still here");
	assert.deepEqual(await s.ended, { type: "exit", code: 0 });
});

test("output is a pull stream: the connection is read only as output is (vsock credit follows the reader); cancel discards the rest", async () => {
	const { s, c } = await session();
	const base = c.taken;
	for (let i = 0; i < 5; i++) c.send(DATA(`chunk${i};`));
	await tick(20);
	assert.equal(c.taken, base, "nothing read while nobody reads output");
	assert.equal(c.unread, 5);
	const reader = s.output.getReader();
	assert.equal(dec.decode((await reader.read()).value), "chunk0;");
	await tick(20);
	assert.equal(c.unread, 4, "one read, one chunk");
	await reader.cancel();
	c.send(EXIT(0, 7));
	assert.deepEqual(await s.ended, { type: "exit", code: 7 }, "cancelled output still lets ended settle");
	assert.equal(c.unread, 0);
});

test("spawn() on an instance without vsock: ENODEV", async () => {
	await assert.rejects(spawnOn(undefined, undefined, [], { rows: 24, cols: 80 }), isPtyError("ENODEV", /vsock: false/));
	// The kernel exited while connecting.
	const v: Vsock = { ...fakeVsock().vsock, connect: () => Promise.reject(new VsockError("ECONNABORTED", "the kernel exited")) };
	await assert.rejects(spawnPty(v, undefined, [], { rows: 24, cols: 80 }), isPtyError("ECONNABORTED"));
});

// Pipes: spawn(file, args, { pty: false }) and exec().

/** Read a stream to its end as text. */
async function text(r: ReadableStream<Uint8Array>): Promise<string> {
	let t = "";
	for await (const chunk of r) t += dec.decode(chunk, { stream: true });
	return t;
}

/** Open a pipe session against a fresh fake; OPENED says PIPES. */
async function pipeSession(file = "cat", args: string[] = []) {
	const f = fakeVsock();
	const p = spawnSubprocess(f.vsock, file, args);
	const c = await f.next();
	await c.waitFrames(1);
	c.send(OPENED(77, 0xffffffff, 1, 1));
	return { s: await p, c, f };
}

test("spawn(file, args, { pty: false }): a critical PIPES option and no TERM; DATA is stdout, STDERR stderr; stdin.close() sends EOF", async () => {
	const f = fakeVsock();
	const p = spawnOn(f.vsock, "sh", ["-c", "x"], { pty: false, cwd: "/", env: { A: "1" } }) as Promise<Subprocess>;
	const c = await f.next();
	const [open] = await c.waitFrames(1);
	const tlv = (tag: number, v: string) => [tag, ...le16(enc.encode(v).length), ...enc.encode(v)];
	assert.deepEqual([...open!.payload], [
		...le16(1), 0, 0, 0, 0, 0, 0, 0, 0,
		...tlv(2, "A=1"), ...tlv(0x83, "sh"), ...tlv(0x83, "-c"), ...tlv(0x83, "x"), ...tlv(0x84, "/"), 0x85, 0, 0,
	]);
	assert.deepEqual([...encodeTtyOpen({ rows: 0, cols: 0, pipes: true, term: "dumb" }).subarray(10)], [...tlv(1, "dumb"), 0x85, 0, 0], "TERM only when given");
	c.send(OPENED(77, 0xffffffff, 1, 1));
	const s = await p;
	assert.equal(s.pid, 77);
	assert.equal(s.features, 1);
	assert.ok(!("pts" in s) && !("write" in s) && !("resize" in s));
	const out = text(s.stdout), err = text(s.stderr);
	const w = s.stdin.getWriter();
	await w.write("in1");
	await w.write(new Uint8Array(5000));
	await w.close();
	const frames = (await c.waitFrames(5)).slice(1);
	assert.deepEqual(frames.map((x) => [x.type, x.payload.length]), [[2, 3], [2, 4096], [2, 904], [7, 0]]);
	c.send(DATA("o1 "), STDERR("e1 "), cat(DATA([0, 255, 10]), STDERR("e2"), EXIT(0, 3)));
	assert.equal(await out, "o1 \0\ufffd\n");
	assert.equal(await err, "e1 e2");
	assert.deepEqual(await s.ended, { type: "exit", code: 3 });
	assert.equal(s.exitCode, 3);
	s.kill(); // a no-op once ended
	await w.closed;
});

test("pipes: reading only stderr does not stall behind stdout; kill() defaults to SIGTERM; cancel discards", async () => {
	const { s, c } = await pipeSession();
	const errReader = s.stderr.getReader();
	const r1 = errReader.read();
	c.send(DATA("x".repeat(100)), DATA("y"), STDERR("first"));
	assert.equal(dec.decode((await r1).value), "first", "stderr's read is answered although stdout's output is ahead of it");
	s.kill();
	s.kill("INT");
	const frames = (await c.waitFrames(3)).slice(1);
	assert.deepEqual(frames.map((x) => [x.type, dec.decode(x.payload)]), [[6, "TERM"], [6, "INT"]]);
	await s.stdout.cancel();
	c.send(DATA("dropped"), STDERR("second"), EXIT(1, 15));
	assert.equal(dec.decode((await errReader.read()).value), "second");
	assert.equal((await errReader.read()).done, true);
	assert.deepEqual(await s.ended, { type: "signal", signal: 15, coreDumped: false });
	assert.equal(s.exitCode, null);
	await assert.rejects(s.stdin.getWriter().write("late"), isPtyError("EPIPE"));
});

test("exec(): input then EOF, stdout and stderr as strings or bytes, a non-zero exit resolves", async () => {
	const f = fakeVsock();
	const r = execSubprocess(f.vsock, "cat", [], { input: "héllo" });
	const c = await f.next();
	await c.waitFrames(1);
	c.send(OPENED(5, 0xffffffff, 1, 1));
	const frames = (await c.waitFrames(3)).slice(1);
	assert.deepEqual(frames.map((x) => [x.type, dec.decode(x.payload)]), [[2, "héllo"], [7, ""]]);
	c.send(DATA("hé"), DATA([0xc3]), DATA([0xa9]), STDERR("warn"), EXIT(0, 2));
	assert.deepEqual(await r, { stdout: "héé", stderr: "warn", exitCode: 2, signal: null });

	const g = fakeVsock();
	const rb = execSubprocess(g.vsock, "head", ["-c", "3", "/dev/urandom"], { encoding: "buffer" });
	const d = await g.next();
	await d.waitFrames(1);
	d.send(OPENED(6, 0xffffffff, 1, 1), DATA([0, 0xff, 0x80]), EXIT(1, 9, 1));
	const res = await rb;
	assert.deepEqual([...res.stdout], [0, 0xff, 0x80]);
	assert.deepEqual([...res.stderr], []);
	assert.deepEqual([res.exitCode, res.signal], [null, 9]);
	const frames2 = await d.waitFrames(2);
	assert.equal(frames2[1]!.type, 7, "no input: EOF at once");
});

test("exec(): maxBuffer kills with SIGKILL (ENOBUFS); abort kills (ABORTED); a lost session is ECONNRESET; ENODEV without vsock", async () => {
	const f = fakeVsock();
	const r = execSubprocess(f.vsock, "yes", [], { maxBuffer: 10 });
	const c = await f.next();
	await c.waitFrames(1);
	c.send(OPENED(5, 0xffffffff, 1, 1), DATA("y\ny\ny\n"), DATA("y\ny\ny\n"));
	const frames = await c.waitFrames(3);
	assert.deepEqual([frames[2]!.type, dec.decode(frames[2]!.payload)], [6, "KILL"]);
	c.send(DATA("more"), EXIT(1, 9));
	await assert.rejects(r, isPtyError("ENOBUFS", /stdout went over maxBuffer \(10 bytes\)/));

	const g = fakeVsock();
	const ac = new AbortController();
	const ra = execSubprocess(g.vsock, "sleep", ["9"], { signal: ac.signal });
	const d = await g.next();
	await d.waitFrames(1);
	d.send(OPENED(6, 0xffffffff, 1, 1));
	await d.waitFrames(2); // EOF
	ac.abort();
	const fr = await d.waitFrames(3);
	assert.equal(dec.decode(fr[2]!.payload), "KILL");
	d.send(EXIT(1, 9));
	await assert.rejects(ra, isPtyError("ABORTED"));

	const h = fakeVsock();
	const rl = execSubprocess(h.vsock, "true");
	const e = await h.next();
	await e.waitFrames(1);
	e.send(OPENED(7, 0xffffffff, 1, 1), DATA("partial"));
	e.end();
	await assert.rejects(rl, isPtyError("ECONNRESET"));

	const old = fakeVsock();
	const ro = execSubprocess(old.vsock, "true");
	const o = await old.next();
	await o.waitFrames(1);
	o.send(ERROR("unknown critical OPEN option"));
	await assert.rejects(ro, isPtyError("EREMOTE", /unknown critical OPEN option/));

	await assert.rejects(execOn(undefined, "true"), isPtyError("ENODEV", /vsock: false/));
	await assert.rejects(execSubprocess(old.vsock, ""), RangeError);
});

// CONNECT: connectGuest(), a raw byte stream to a guest TCP port.

test("connectGuest(): a critical CONNECT option, then raw bytes both ways (bytes that came with OPENED first); half-close", async () => {
	const f = fakeVsock();
	const p = connectGuest(f.vsock, 8080);
	const c = await f.next();
	const [open] = await c.waitFrames(1);
	assert.equal(f.calls[0]!.port, TTY_PORT);
	assert.deepEqual([...open!.payload], [...le16(1), 0, 0, 0, 0, 0, 0, 0, 0, 0x86, 2, 0, ...le16(8080)], "no TERM, the port as u16");
	// OPENED and the start of the stream in one chunk; the stream looks like frames (a whole one and part of one), which must not matter.
	const early = cat(DATA("looks like a frame"), Uint8Array.from([2, 0, 9]));
	const o = OPENED(0, 0xffffffff, 1, 3);
	c.send(cat(o, early.subarray(0, 5)), early.subarray(5));
	const sock = await p;
	const duplex: ByteDuplex = sock; // the shape fetchOver() takes
	assert.equal(duplex, sock);
	assert.equal(sock.port, 8080);
	const reader = sock.readable.getReader();
	const got: Uint8Array[] = [];
	const readTo = async (n: number) => {
		while (got.reduce((k, x) => k + x.length, 0) < n) {
			const r = await reader.read();
			assert.equal(r.done, false);
			got.push(r.value!);
		}
		return cat(...got);
	};
	assert.deepEqual(await readTo(early.length), early);
	c.send(bytes([5, 0, 0xff, 0xff]));
	assert.deepEqual([...(await readTo(early.length + 4)).subarray(early.length)], [5, 0, 0xff, 0xff]);
	const w = sock.writable.getWriter();
	await w.write(bytes("GET / HTTP/1.1\r\n\r\n"));
	await w.write(Uint8Array.of(1, 0x80, 0xff, 0));
	assert.deepEqual(c.raw.subarray(4 + open!.payload.length), cat(bytes("GET / HTTP/1.1\r\n\r\n"), Uint8Array.of(1, 0x80, 0xff, 0)), "raw, no frames");
	await w.close();
	assert.equal(c.writeClosed, true, "writable.close() is a half-close");
	c.send(bytes("reply after EOF"));
	c.end();
	const tail = await readTo(early.length + 4 + 15);
	assert.equal(dec.decode(tail.subarray(early.length + 4)), "reply after EOF");
	assert.equal((await reader.read()).done, true);
	await sock.close();

	// Nothing came with OPENED: still a pull stream, and one never read (new Response() takes it).
	const g = fakeVsock();
	const q = connectGuest(g.vsock, 1, { ttyPort: 5555 });
	const d = await g.next();
	await d.waitFrames(1);
	assert.equal(g.calls[0]!.port, 5555);
	d.send(OPENED(0, 0xffffffff, 1, 3));
	const s2 = await q;
	const base = d.taken;
	d.send(bytes("a"), bytes("b"));
	await tick(20);
	assert.equal(d.taken, base, "nothing read while nobody reads");
	const r2 = s2.readable.getReader();
	assert.equal(dec.decode((await r2.read()).value), "a");
	r2.releaseLock();
	await s2.close();
	assert.equal(d.hostEnd, "close");
});

test("connectGuest(): ECONNREFUSED, other guest errors EREMOTE, an old guest EREMOTE, no feature EPROTO, bad ports, ENODEV", async () => {
	const answer = async (port: number, ...reply: Uint8Array[]) => {
		const f = fakeVsock();
		const p = connectGuest(f.vsock, port);
		const c = await f.next();
		await c.waitFrames(1);
		c.send(...reply);
		return { p, c };
	};
	const refused = await answer(81, ERROR("ECONNREFUSED: connect to 127.0.0.1:81: Connection refused"));
	await assert.rejects(refused.p, isPtyError("ECONNREFUSED", /127\.0\.0\.1:81/));
	assert.equal(refused.c.hostEnd, "reset");
	await assert.rejects((await answer(81, ERROR("ETIMEDOUT: connect to 127.0.0.1:81: Operation timed out"))).p, isPtyError("EREMOTE", /ETIMEDOUT/));
	await assert.rejects((await answer(81, ERROR("unknown critical OPEN option"))).p, isPtyError("EREMOTE", /unknown critical OPEN option/));
	const nofeat = await answer(81, OPENED(0, 0xffffffff, 1, 1));
	await assert.rejects(nofeat.p, isPtyError("EPROTO", /CONNECT/));
	assert.equal(nofeat.c.hostEnd, "reset");
	for (const bad of [0, 65536, 1.5, NaN, -1]) {
		const f = fakeVsock();
		await assert.rejects(connectGuest(f.vsock, bad), RangeError, String(bad));
		assert.equal(f.calls.length, 0);
	}
	await assert.rejects(connectOn(undefined, 80), isPtyError("ENODEV", /connect\(\).*vsock: false/));
	const ac = new AbortController();
	const f = fakeVsock({ refuse: Infinity });
	const p = connectGuest(f.vsock, 80, { signal: ac.signal, timeout: 5000 });
	await tick(50);
	ac.abort();
	await assert.rejects(p, isPtyError("ABORTED"));
});
