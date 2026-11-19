#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Build-time byte diff of two kernel modules (bundle.mjs --smp: the UP
// bundle's patch to the SMP kernel). The patch converts one module into the other;
// js/core/kpatch.ts applies it in the loader.
//
//   bun kernel/tools/kwdiff.mjs <base.wasm> <target.wasm> -o <out.kwpatch> [--remap]
//
// The matching follows bsdiff's idea (Colin Percival, "Naive differences of
// executable code", 2003): a suffix array of the base, exact matches
// extended into approximate ones, stored as byte-wise differences (mostly
// zeros, so they compress well) plus bytes with no counterpart. This file is
// an independent implementation; the suffix array is built by prefix
// doubling.
//
// --remap first renumbers the base's functions, globals and types to the
// target's (wasm-structure aware, kwremap.mjs: matched by name), so that
// calls to the same function have the same index in both, and moves data
// addresses (constants and load/store offsets in the base's code) to where
// the target has them; the patch carries the tables and the patcher applies
// the same rewrite before the byte diff.
//
// Patch format (all integers unsigned LEB128 unless noted):
//   "KWP1", flags (bit 0: remap), base length, target length,
//   base sha-256 (32 bytes), target sha-256 (32 bytes),
//   [remap tables, if flag bit 0: kwremap.mjs encodeRemap()],
//   control count, then per control: add length, copy length, seek (zigzag),
//   then the add (difference) bytes, zero-run coded (pairs of a run of zero
//   bytes and a run of literal bytes, the literals following, until every
//   add byte is accounted for: the raw patch stays small, for the GitHub
//   release asset and npm, which are not Content-Encoded), then the copied
//   (extra) bytes.
// The streams are kept apart so that a general-purpose compressor (the HTTP
// Content-Encoding, npm's gzip) sees like next to like.
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { createHash } from "node:crypto";
import { remapTables, encodeRemap, applyRemap } from "./kwremap.mjs";

/** Suffix array of `a` (Int32Array of length a.length + 1, entry 0 is the empty suffix). */
export function suffixArray(a) {
	const n = a.length;
	// Prefix doubling: rank by the first h bytes, then by pairs of ranks.
	let sa = new Int32Array(n + 1), rank = new Int32Array(n + 1), tmp = new Int32Array(n + 1);
	// Initial order: counting sort on the first byte; the empty suffix first.
	const cnt = new Int32Array(257);
	for (let i = 0; i < n; i++) cnt[a[i] + 1]++;
	cnt[0] = 1; // the empty suffix (rank 0)
	for (let i = 1; i < 257; i++) cnt[i] += cnt[i - 1];
	const pos = new Int32Array(257);
	pos[0] = 0;
	for (let i = 1; i < 257; i++) pos[i] = cnt[i - 1];
	sa[0] = n;
	rank[n] = 0;
	for (let i = 0; i < n; i++) { sa[pos[a[i] + 1]++] = i; rank[i] = a[i] + 1; }
	const key2 = new Int32Array(n + 1);
	const sa2 = new Int32Array(n + 1);
	let classes = 0;
	for (let h = 1; ; h <<= 1) {
		// Sort by (rank[i], rank[i+h]) with two counting-sort passes (LSD radix on ranks).
		const maxRank = Math.max(257, n + 1);
		for (let i = 0; i <= n; i++) key2[i] = i + h <= n ? rank[i + h] : 0;
		// pass 1: by key2
		let c = new Int32Array(maxRank + 1);
		for (let i = 0; i <= n; i++) c[key2[i] + 1]++;
		for (let i = 1; i <= maxRank; i++) c[i] += c[i - 1];
		for (let i = 0; i <= n; i++) sa2[c[key2[i]]++] = i;
		// pass 2: by rank, stable
		c = new Int32Array(maxRank + 1);
		for (let i = 0; i <= n; i++) c[rank[i] + 1]++;
		for (let i = 1; i <= maxRank; i++) c[i] += c[i - 1];
		for (let k = 0; k <= n; k++) { const i = sa2[k]; sa[c[rank[i]]++] = i; }
		// new ranks
		tmp[sa[0]] = 0;
		classes = 1;
		for (let k = 1; k <= n; k++) {
			const i = sa[k], j = sa[k - 1];
			if (rank[i] !== rank[j] || key2[i] !== key2[j]) classes++;
			tmp[i] = classes - 1;
		}
		[rank, tmp] = [tmp, rank];
		if (classes === n + 1) break;
	}
	return sa;
}

function matchLen(a, ai, b, bi) {
	let i = 0;
	const m = Math.min(a.length - ai, b.length - bi);
	while (i < m && a[ai + i] === b[bi + i]) i++;
	return i;
}

/** Longest match of b[bi..] in a, by binary search over the suffix array: [length, position]. */
function search(sa, a, b, bi, lo, hi) {
	while (hi - lo >= 2) {
		const mid = lo + ((hi - lo) >> 1);
		// compare a[sa[mid]..] with b[bi..]
		const ai = sa[mid];
		const m = Math.min(a.length - ai, b.length - bi);
		let k = 0;
		while (k < m && a[ai + k] === b[bi + k]) k++;
		if (k === m ? (a.length - ai) < (b.length - bi) : a[ai + k] < b[bi + k]) lo = mid;
		else hi = mid;
	}
	const x = matchLen(a, sa[lo], b, bi), y = matchLen(a, sa[hi], b, bi);
	return x > y ? [x, sa[lo]] : [y, sa[hi]];
}

/** bsdiff-style diff: { ctrl: [add, copy, seek][], diff: Uint8Array, extra: Uint8Array }. */
export function diff(a, b) {
	const sa = suffixArray(a);
	const n = a.length, m = b.length;
	const ctrl = [];
	const diffOut = new Uint8Array(m), extraOut = new Uint8Array(m);
	let dlen = 0, elen = 0;
	let scan = 0, len = 0, pos = 0, lastscan = 0, lastpos = 0, lastoffset = 0;
	while (scan < m) {
		let oldscore = 0;
		let scsc = scan += len;
		for (; scan < m; scan++) {
			[len, pos] = search(sa, a, b, scan, 0, n);
			for (; scsc < scan + len; scsc++)
				if (scsc + lastoffset < n && a[scsc + lastoffset] === b[scsc]) oldscore++;
			if ((len === oldscore && len !== 0) || len > oldscore + 8) break;
			if (scan + lastoffset < n && a[scan + lastoffset] === b[scan]) oldscore--;
		}
		if (len !== oldscore || scan === m) {
			let s = 0, sf = 0, lenf = 0;
			for (let i = 0; lastscan + i < scan && lastpos + i < n;) {
				if (a[lastpos + i] === b[lastscan + i]) s++;
				i++;
				if (s * 2 - i > sf * 2 - lenf) { sf = s; lenf = i; }
			}
			let lenb = 0;
			if (scan < m) {
				let s2 = 0, sb = 0;
				for (let i = 1; scan >= lastscan + i && pos >= i; i++) {
					if (a[pos - i] === b[scan - i]) s2++;
					if (s2 * 2 - i > sb * 2 - lenb) { sb = s2; lenb = i; }
				}
			}
			if (lastscan + lenf > scan - lenb) {
				const overlap = lastscan + lenf - (scan - lenb);
				let s3 = 0, ss = 0, lens = 0;
				for (let i = 0; i < overlap; i++) {
					if (b[lastscan + lenf - overlap + i] === a[lastpos + lenf - overlap + i]) s3++;
					if (b[scan - lenb + i] === a[pos - lenb + i]) s3--;
					if (s3 > ss) { ss = s3; lens = i + 1; }
				}
				lenf += lens - overlap;
				lenb -= lens;
			}
			for (let i = 0; i < lenf; i++) diffOut[dlen++] = (b[lastscan + i] - a[lastpos + i]) & 0xff;
			const ex = scan - lenb - (lastscan + lenf);
			for (let i = 0; i < ex; i++) extraOut[elen++] = b[lastscan + lenf + i];
			ctrl.push([lenf, ex, pos - lenb - (lastpos + lenf)]);
			lastscan = scan - lenb;
			lastpos = pos - lenb;
			lastoffset = pos - scan;
		}
	}
	return { ctrl, diff: diffOut.subarray(0, dlen), extra: extraOut.subarray(0, elen) };
}

/** The difference bytes as (zero run, literal run, literals) groups. */
export function zeroRuns(d) {
	const w = new Writer();
	let i = 0;
	while (i < d.length) {
		let z = i;
		while (z < d.length && d[z] === 0) z++;
		// A literal run ends at the next run of 4+ zeros (shorter ones stay literal).
		let e = z;
		while (e < d.length) {
			if (d[e] === 0) {
				let k = e;
				while (k < d.length && d[k] === 0 && k - e < 4) k++;
				if (k - e >= 4 || k === d.length) break;
				e = k;
			} else e++;
		}
		w.uleb(z - i);
		w.uleb(e - z);
		w.bytes(d.subarray(z, e));
		i = e;
	}
	return w.done();
}

class Writer {
	constructor() { this.parts = []; this.cur = []; }
	byte(b) { this.cur.push(b); }
	uleb(n) { do { let b = n & 0x7f; n = Math.floor(n / 128); if (n) b |= 0x80; this.cur.push(b); } while (n); }
	zig(n) { this.uleb(n < 0 ? -2 * n - 1 : 2 * n); }
	bytes(u8) { this.flush(); this.parts.push(u8); }
	flush() { if (this.cur.length) { this.parts.push(Uint8Array.from(this.cur)); this.cur = []; } }
	done() { this.flush(); return Buffer.concat(this.parts); }
}

export function makePatch(base, target, { remap = false } = {}) {
	const sha = (u8) => createHash("sha256").update(u8).digest();
	const w = new Writer();
	for (const c of "KWP1") w.byte(c.charCodeAt(0));
	w.uleb(remap ? 1 : 0);
	w.uleb(base.length);
	w.uleb(target.length);
	w.bytes(sha(base));
	w.bytes(sha(target));
	let src = base;
	if (remap) {
		const tables = remapTables(base, target);
		console.error(`kwdiff: remap ${tables.stats}`);
		w.bytes(encodeRemap(tables));
		src = applyRemap(base, tables);
	}
	const { ctrl, diff: d, extra } = diff(src, target);
	w.uleb(ctrl.length);
	for (const [add, copy, seek] of ctrl) { w.uleb(add); w.uleb(copy); w.zig(seek); }
	w.bytes(zeroRuns(d));
	w.bytes(extra);
	return { patch: w.done(), ctrl: ctrl.length, diffBytes: d.length, extraBytes: extra.length };
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const args = process.argv.slice(2);
	const oi = args.indexOf("-o");
	const out = oi >= 0 ? args.splice(oi, 2)[1] : undefined;
	const remap = args.includes("--remap");
	const [basePath, targetPath] = args.filter((a) => !a.startsWith("--"));
	if (!basePath || !targetPath || !out) {
		console.error("usage: kwdiff.mjs <base.wasm> <target.wasm> -o <out.kwpatch> [--remap]");
		process.exit(2);
	}
	const t0 = performance.now();
	const r = makePatch(readFileSync(basePath), readFileSync(targetPath), { remap });
	writeFileSync(out + ".tmp", r.patch);
	renameSync(out + ".tmp", out);
	console.log(`kwdiff: ${out} ${r.patch.length} bytes (${r.ctrl} controls, ${r.diffBytes} difference bytes, ${r.extraBytes} new bytes${remap ? ", remapped" : ""}) in ${((performance.now() - t0) / 1000).toFixed(1)} s`);
}
