// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Unit tests for the HTTP/1.1 client (core/http.ts) without a kernel: a
// fake GuestConnect whose connections are in-memory web streams, with the
// test playing the guest's server byte by byte.
//
//   bun test ./test/http.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { HTTP_MAX_HEADER_BYTES, fetchOver, type ByteDuplex, type GuestConnect } from "../js/core/http.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

/** The server's side of one connection. */
class ServerConn {
	readonly port: number;
	readonly duplex: ByteDuplex;
	/** Everything the host sent. */
	received = new Uint8Array(0);
	/** How the host ended its sending side: "close" (a half-close), "abort", or not yet. */
	hostEnd: "close" | "abort" | undefined;
	/** The host cancelled its reading side. */
	readCancelled = false;
	/** Bytes handed to the host's reader. */
	delivered = 0;
	/** Called on a pull with nothing queued: return the next chunk, or null for EOF. */
	produce: (() => Uint8Array | string | null) | undefined;
	#queue: Array<Uint8Array | null | Error> = [];
	#rc!: ReadableStreamDefaultController<Uint8Array>;
	#want = false;
	#waiters: Array<() => void> = [];

	constructor(port: number) {
		this.port = port;
		const readable = new ReadableStream<Uint8Array>({
			start: (c) => { this.#rc = c; },
			pull: () => {
				this.#want = true;
				this.#pump();
			},
			cancel: () => { this.readCancelled = true; },
		}, { highWaterMark: 0 });
		const writable = new WritableStream<Uint8Array>({
			write: (chunk) => {
				if (this.hostEnd) throw new Error("write after end");
				const all = new Uint8Array(this.received.length + chunk.length);
				all.set(this.received);
				all.set(chunk, this.received.length);
				this.received = all;
				for (const w of this.#waiters.splice(0)) w();
			},
			close: () => {
				this.hostEnd = "close";
				for (const w of this.#waiters.splice(0)) w();
			},
			abort: () => {
				this.hostEnd = "abort";
				for (const w of this.#waiters.splice(0)) w();
			},
		});
		this.duplex = { readable, writable };
	}

	get text(): string {
		return dec.decode(this.received);
	}

	/** Wait until what the host sent satisfies `pred`. */
	async until(pred: (text: string) => boolean): Promise<string> {
		while (!pred(this.text)) {
			if (this.hostEnd) assert.fail(`host ended (${this.hostEnd}) with ${JSON.stringify(this.text)}`);
			await new Promise<void>((r) => this.#waiters.push(r));
		}
		return this.text;
	}

	/** The request head, once it is all in. */
	head(): Promise<string> {
		return this.until((t) => t.includes("\r\n\r\n")).then((t) => t.slice(0, t.indexOf("\r\n\r\n") + 4));
	}

	/** Each send is one chunk for the host's reader. */
	send(...parts: Array<string | Uint8Array>): void {
		for (const p of parts) this.#queue.push(typeof p === "string" ? enc.encode(p) : p);
		this.#pump();
	}

	end(): void {
		this.#queue.push(null);
		this.#pump();
	}

	error(e: Error): void {
		this.#queue.push(e);
		this.#pump();
	}

	#pump(): void {
		if (!this.#want || this.readCancelled) return;
		let next = this.#queue.shift();
		if (next === undefined && this.produce) {
			const p = this.produce();
			next = p === null ? null : typeof p === "string" ? enc.encode(p) : p;
		}
		if (next === undefined) return;
		this.#want = false;
		if (next === null) this.#rc.close();
		else if (next instanceof Error) this.#rc.error(next);
		else {
			this.delivered += next.length;
			this.#rc.enqueue(next);
		}
	}
}

/** A GuestConnect whose connections the test serves. */
function fake(serve?: (c: ServerConn) => void | Promise<void>) {
	const conns: ServerConn[] = [];
	let next: ((c: ServerConn) => void) | undefined;
	const connect: GuestConnect = async (port, opts) => {
		assert.ok("signal" in opts);
		const c = new ServerConn(port);
		conns.push(c);
		next?.(c);
		next = undefined;
		if (serve) void Promise.resolve(serve(c)).catch((e) => c.error(e));
		return c.duplex;
	};
	const accept = () => (conns.length ? Promise.resolve(conns[conns.length - 1]!) : new Promise<ServerConn>((r) => (next = r)));
	return { connect, conns, accept };
}

/** Serve one fixed response once the request head is in. */
const respond = (...parts: string[]) => async (c: ServerConn) => {
	await c.head();
	c.send(...parts);
	c.end();
};

test("GET with Content-Length", async () => {
	const f = fake(respond("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"));
	const res = await fetchOver(f.connect, "http://localhost:8000/a/b?x=1&y=2");
	assert.equal(res.status, 200);
	assert.equal(res.statusText, "OK");
	assert.equal(res.ok, true);
	assert.equal(res.headers.get("content-type"), "text/plain");
	assert.equal(res.headers.get("content-length"), "5");
	assert.equal(res.headers.get("connection"), null);
	assert.equal(await res.text(), "hello");
	const c = f.conns[0]!;
	assert.equal(c.port, 8000);
	const head = c.text;
	assert.match(head, /^GET \/a\/b\?x=1&y=2 HTTP\/1\.1\r\nHost: localhost:8000\r\n/);
	assert.match(head, /\r\nConnection: close\r\n/i);
	assert.match(head, /\r\nAccept-Encoding: identity\r\n/i);
	assert.doesNotMatch(head, /content-length|transfer-encoding/i);
	await tick();
	assert.equal(c.hostEnd, "close", "closed in order after the response");
	assert.equal(c.readCancelled, true);
});

test("the host does not half-close before the response", async () => {
	const f = fake();
	const p = fetchOver(f.connect, "http://localhost:8000/", { method: "POST", body: "data" });
	const c = await f.accept();
	await c.until((t) => t.endsWith("data"));
	await tick(10);
	assert.equal(c.hostEnd, undefined);
	c.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
	const res = await p;
	assert.equal(await res.text(), "");
	await tick();
	assert.equal(c.hostEnd, "close");
});

test("default port, Host as the URL has it, caller's Accept-Encoding", async () => {
	const f = fake(respond("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"));
	const res = await fetchOver(f.connect, new URL("http://example.test/"), { headers: { "Accept-Encoding": "gzip", "X-Test": "1" } });
	assert.equal(await res.text(), "ok");
	const c = f.conns[0]!;
	assert.equal(c.port, 80);
	assert.match(c.text, /\r\nHost: example\.test\r\n/);
	assert.match(c.text, /\r\naccept-encoding: gzip\r\n/i);
	assert.doesNotMatch(c.text, /identity/);
	assert.match(c.text, /\r\nx-test: 1\r\n/i);
});

test("chunked, split at awkward places", async () => {
	const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n1a\r\n abcdefghijklmnopqrstuvwxy\r\n0\r\nX-Trailer: t\r\n\r\n";
	// Every split point, and one byte per read.
	const splits: number[][] = [];
	for (let i = 1; i < wire.length; i++) splits.push([i]);
	splits.push(Array.from({ length: wire.length - 1 }, (_, i) => i + 1));
	for (const cuts of splits) {
		const f = fake(async (c) => {
			await c.head();
			let at = 0;
			for (const cut of [...cuts, wire.length]) {
				c.send(wire.slice(at, cut));
				at = cut;
			}
			c.end();
		});
		const res = await fetchOver(f.connect, "http://localhost:8000/");
		assert.equal(res.headers.get("transfer-encoding"), null);
		assert.equal(await res.text(), "hello abcdefghijklmnopqrstuvwxy", `cuts ${cuts.join(",")}`);
	}
});

test("body until EOF", async () => {
	const f = fake(respond("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nfirst ", "second ", "third"));
	const res = await fetchOver(f.connect, "http://localhost:8000/");
	assert.equal(await res.text(), "first second third");
});

test("no body for HEAD, 204 and 304; 205 too", async () => {
	for (const [method, status, extra] of [["HEAD", 200, "Content-Length: 1234\r\n"], ["GET", 204, ""], ["GET", 304, "Content-Length: 99\r\n"], ["GET", 205, ""]] as const) {
		// No end(): the client must not wait for a body.
		const f = fake(async (c) => {
			await c.head();
			c.send(`HTTP/1.1 ${status} Whatever\r\n${extra}ETag: "x"\r\n\r\n`);
		});
		const res = await fetchOver(f.connect, "http://localhost:8000/", { method });
		assert.equal(res.status, status);
		assert.equal(res.body, null);
		assert.equal(res.headers.get("etag"), '"x"');
		assert.equal(await res.text(), "");
		await tick();
		assert.notEqual(f.conns[0]!.hostEnd, undefined);
	}
});

test("100 Continue and other interim responses are skipped", async () => {
	const f = fake(respond("HTTP/1.1 100 Continue\r\n\r\n", "HTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 3\r\n\r\nnew"));
	const res = await fetchOver(f.connect, "http://localhost:8000/", { method: "PUT", body: "x" });
	assert.equal(res.status, 201);
	assert.equal(res.statusText, "Created");
	assert.equal(res.headers.get("link"), null);
	assert.equal(await res.text(), "new");
});

test("101 is rejected", async () => {
	const f = fake(respond("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"));
	await assert.rejects(fetchOver(f.connect, "http://localhost:8000/"), (e: unknown) => e instanceof TypeError && /101/.test(e.message));
	await tick();
	assert.equal(f.conns[0]!.hostEnd, "abort");
});

test("repeated headers are kept", async () => {
	const f = fake(respond("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nset-cookie: b=2; Path=/\r\nVary: Accept\r\nVARY: Origin\r\nContent-Length: 0\r\n\r\n"));
	const res = await fetchOver(f.connect, "http://localhost:8000/");
	assert.deepEqual(res.headers.getSetCookie(), ["a=1", "b=2; Path=/"]);
	assert.equal(res.headers.get("vary"), "Accept, Origin");
});

test("hop-by-hop headers are dropped, content-encoding kept", async () => {
	const f = fake(respond("HTTP/1.1 200 OK\r\nConnection: close, X-Hop\r\nX-Hop: 1\r\nKeep-Alive: timeout=5\r\nContent-Encoding: gzip\r\nContent-Length: 1\r\n\r\nz"));
	const res = await fetchOver(f.connect, "http://localhost:8000/");
	assert.equal(res.headers.get("keep-alive"), null);
	assert.equal(res.headers.get("x-hop"), null);
	assert.equal(res.headers.get("content-encoding"), "gzip");
	assert.equal(await res.text(), "z");
});

test("POST with a string body sends Content-Length", async () => {
	const f = fake(async (c) => {
		await c.until((t) => t.endsWith("héllo"));
		c.send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		c.end();
	});
	const res = await fetchOver(f.connect, "http://localhost:8000/post", { method: "POST", body: "héllo", headers: { "Content-Type": "text/x" } });
	assert.equal(await res.text(), "ok");
	const t = f.conns[0]!.text;
	assert.match(t, /^POST \/post HTTP\/1\.1\r\n/);
	assert.match(t, /\r\nContent-Length: 6\r\n/i);
	assert.match(t, /\r\ncontent-type: text\/x\r\n/i);
	assert.doesNotMatch(t, /transfer-encoding/i);
});

test("a Request's body, and bodies of other types, go with Content-Length", async () => {
	for (const body of [new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 3]).buffer, new Blob(["abc"]), new URLSearchParams("a=1&b=2")]) {
		const f = fake(respond("HTTP/1.1 204 No Content\r\n\r\n"));
		await fetchOver(f.connect, new Request("http://localhost:8000/", { method: "POST", body }));
		const t = f.conns[0]!.text;
		const len = /\r\ncontent-length: (\d+)\r\n/i.exec(t);
		assert.ok(len, t);
		assert.equal(t.length - t.indexOf("\r\n\r\n") - 4, Number(len[1]));
	}
});

test("POST with a stream body is sent chunked", async () => {
	const f = fake(async (c) => {
		await c.until((t) => t.endsWith("0\r\n\r\n"));
		c.send("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone");
		c.end();
	});
	const parts = ["abc", "", "defghijklmnopq"];
	const body = new ReadableStream<Uint8Array>({
		async pull(ctl) {
			const p = parts.shift();
			if (p === undefined) return ctl.close();
			await tick();
			ctl.enqueue(enc.encode(p));
		},
	});
	const res = await fetchOver(f.connect, "http://localhost:8000/up", { method: "POST", body });
	assert.equal(await res.text(), "done");
	const t = f.conns[0]!.text;
	assert.match(t, /\r\nTransfer-Encoding: chunked\r\n/i);
	assert.doesNotMatch(t, /content-length/i);
	assert.equal(t.slice(t.indexOf("\r\n\r\n") + 4), "3\r\nabc\r\ne\r\ndefghijklmnopq\r\n0\r\n\r\n");
});

test("a response that arrives before the upload ends", async () => {
	const f = fake(respond("HTTP/1.1 413 Payload Too Large\r\nContent-Length: 3\r\n\r\nbig"));
	const body = new ReadableStream<Uint8Array>({ pull: () => new Promise(() => {}) }); // never ends
	const res = await fetchOver(f.connect, "http://localhost:8000/", { method: "POST", body });
	assert.equal(res.status, 413);
	assert.equal(await res.text(), "big");
	await tick();
	assert.equal(f.conns[0]!.hostEnd, "abort", "the unfinished request is reset");
});

test("only http: URLs", async () => {
	const f = fake();
	for (const url of ["https://localhost:8000/", "ftp://localhost/", "ws://localhost/"])
		await assert.rejects(fetchOver(f.connect, url), (e: unknown) => e instanceof TypeError && /only http:/.test(e.message));
	assert.equal(f.conns.length, 0);
});

test("malformed responses reject with a TypeError", async () => {
	for (const wire of ["HTTP/2 200 OK\r\n\r\n", "hello\r\n\r\n", "HTTP/1.1 20 OK\r\n\r\n", "HTTP/1.1 200 OK\r\nbad header\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 1, 2\r\n\r\nx", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", "HTTP/1.1 700 Odd\r\n\r\n"]) {
		const f = fake(respond(wire));
		await assert.rejects(fetchOver(f.connect, "http://localhost:8000/"), (e: unknown) => e instanceof TypeError && /fetchOver: malformed response/.test(e.message), wire);
	}
	const f = fake(respond("HTTP/1.1 200 OK\r\nContent-Le"));
	await assert.rejects(fetchOver(f.connect, "http://localhost:8000/"), /closed inside the response headers/);
	const g = fake(respond());
	await assert.rejects(fetchOver(g.connect, "http://localhost:8000/"), /closed before a response/);
});

test("a bad chunk errors the body", async () => {
	const f = fake(respond("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcX\r\n0\r\n\r\n"));
	const res = await fetchOver(f.connect, "http://localhost:8000/");
	await assert.rejects(res.text(), /no CRLF after a chunk/);
	const g = fake(respond("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"));
	await assert.rejects((await fetchOver(g.connect, "http://localhost:8000/")).text(), /chunk size line/);
});

test("a truncated body errors the stream", async () => {
	for (const wire of ["HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\na\r\nshort", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"]) {
		const f = fake(respond(wire));
		const res = await fetchOver(f.connect, "http://localhost:8000/");
		assert.equal(res.status, 200);
		await assert.rejects(res.text(), (e: unknown) => e instanceof TypeError && /before the end of the response body/.test(e.message), wire);
		await tick();
		assert.equal(f.conns[0]!.hostEnd, "abort");
	}
});

test("a failed connect rejects", async () => {
	const err = new Error("ECONNREFUSED");
	await assert.rejects(fetchOver(() => Promise.reject(err), "http://localhost:8000/"), (e) => e === err);
});

test("a transport error while reading the head rejects", async () => {
	const err = new Error("ECONNRESET");
	const f = fake(async (c) => {
		await c.head();
		c.send("HTTP/1.1 200");
		c.error(err);
	});
	await assert.rejects(fetchOver(f.connect, "http://localhost:8000/"), (e) => e === err);
});

test("abort before, during connect, while waiting, and mid-body", async () => {
	// Already aborted: no connect.
	const f0 = fake();
	await assert.rejects(fetchOver(f0.connect, "http://localhost:8000/", { signal: AbortSignal.abort() }), { name: "AbortError" });
	assert.equal(f0.conns.length, 0);

	// During a connect that ignores the signal: rejects at once, the late connection is reset.
	const late = new ServerConn(8000);
	let land!: () => void;
	const ac0 = new AbortController();
	const p0 = fetchOver(() => new Promise((r) => (land = () => r(late.duplex))), "http://localhost:8000/", { signal: ac0.signal });
	await tick();
	ac0.abort();
	await assert.rejects(p0, { name: "AbortError" });
	land();
	await tick();
	assert.equal(late.hostEnd, "abort");

	// Waiting for the head.
	const f1 = fake();
	const ac1 = new AbortController();
	const p1 = fetchOver(f1.connect, "http://localhost:8000/", { signal: ac1.signal });
	const c1 = await f1.accept();
	await c1.head();
	const reason = new Error("stop");
	ac1.abort(reason);
	await assert.rejects(p1, (e) => e === reason);
	await tick();
	assert.equal(c1.hostEnd, "abort");
	assert.equal(c1.readCancelled, true);

	// Mid-body.
	const f2 = fake();
	const ac2 = new AbortController();
	const p2 = fetchOver(f2.connect, "http://localhost:8000/", { signal: ac2.signal });
	const c2 = await f2.accept();
	await c2.head();
	c2.send("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nsome");
	const res = await p2;
	const reader = res.body!.getReader();
	assert.equal(dec.decode((await reader.read()).value), "some");
	const pending = reader.read();
	ac2.abort();
	await assert.rejects(pending, { name: "AbortError" });
	await tick();
	assert.equal(c2.hostEnd, "abort");
	assert.equal(c2.readCancelled, true);
});

test("cancelling the body closes the connection", async () => {
	const f = fake(respond("HTTP/1.1 200 OK\r\n\r\nendless"));
	const res = await fetchOver(f.connect, "http://localhost:8000/");
	await res.body!.cancel();
	await tick();
	assert.equal(f.conns[0]!.hostEnd, "abort");
	assert.equal(f.conns[0]!.readCancelled, true);
});

test("header block limit", async () => {
	const big = "x".repeat(1000);
	let wire = "HTTP/1.1 200 OK\r\n";
	while (wire.length < HTTP_MAX_HEADER_BYTES) wire += `X-Big: ${big}\r\n`;
	const f = fake(respond(wire + "\r\n"));
	await assert.rejects(fetchOver(f.connect, "http://localhost:8000/"), (e: unknown) => e instanceof TypeError && /header block over/.test(e.message));
	await tick();
	assert.equal(f.conns[0]!.hostEnd, "abort");
	// Just under it is fine.
	let ok = "HTTP/1.1 200 OK\r\n";
	while (ok.length + 1010 < HTTP_MAX_HEADER_BYTES) ok += `X-Big: ${big}\r\n`;
	const g = fake(respond(ok + "Content-Length: 0\r\n\r\n"));
	assert.equal((await fetchOver(g.connect, "http://localhost:8000/")).status, 200);
});

test("backpressure: the body is read from the connection only as the consumer reads", async () => {
	const CHUNK = 4096;
	const TOTAL = 4 << 20;
	let produced = 0;
	const f = fake(async (c) => {
		await c.head();
		c.send(`HTTP/1.1 200 OK\r\nContent-Length: ${TOTAL}\r\n\r\n`);
		c.produce = () => {
			if (produced >= TOTAL) return null;
			produced += CHUNK;
			return new Uint8Array(CHUNK).fill(0x61);
		};
	});
	const res = await fetchOver(f.connect, "http://localhost:8000/");
	const reader = res.body!.getReader();
	let consumed = 0;
	for (let i = 0; i < 8; i++) {
		const { value } = await reader.read();
		consumed += value!.length;
		await tick(5);
		assert.ok(produced - consumed <= 2 * CHUNK, `produced ${produced}, consumed ${consumed}`);
	}
	await tick(20);
	assert.ok(produced <= 10 * CHUNK, `produced ${produced} with nobody reading`);
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		consumed += value.length;
	}
	assert.equal(consumed, TOTAL);
});
