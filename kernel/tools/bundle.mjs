#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Bundle a root file system (and a default command line) into a kernel module.
//
//   bun kernel/tools/bundle.mjs <vmlinux|vmlinux32.wasm> <initrd.cpio[.gz]> -o <out.wasm>
//        [--cmdline "console=hvc0 rdinit=/init"] [--datadisk kwdata.kwsparse.gz] [--no-gzip]
//        [--smp <SMP vmlinux32.wasm> [--smp-patch <file.kwpatch>] [--smp-optional]]
//
// The initramfs goes into a custom section "unkernel.initrd", the command
// line into "unkernel.cmdline", and the data disk template (a gzipped
// kwsparse image, kernel/build.sh datadisk) into "unkernel.datadisk".
// --smp (.agents/js.md, CPU threads) adds the patch that turns
// this kernel into the given SMP build of the same tree
// ("unkernel.kernel.smp.kwpatch", kwdiff.mjs --remap, last), which the
// loader applies when asked for more than one CPU (js/core/kpatch.ts).
// It refuses two kernels that are not the UP and SMP builds of one tree
// (smpPairError: their banners must differ only in "SMP", which with
// kernel/build.sh's build stamps means the same tree and kwemu sources;
// the same KW_ABI_VERSION in their kwemu; only the SMP one importing
// wasm_cpu_start; the same memory index type); with --smp-optional it
// warns and leaves the patch out instead. --smp-patch caches the patch
// (making it takes about 15 s): a patch in that file made from these two
// kernels (its header's SHA-256s) is reused, else a new one is written there.
// Custom sections are ignored by the engine, so
// the module is otherwise unchanged (same code, imports and memory type), and
// the kernel needs no rebuild. The host runtime (js/core/kernel.ts, see
// bundledBoot) uses them when it is given no initrd / command line of its own:
//
//   bun js/cli.ts vendor/build/bundle/unkernel-alpine.wasm
//
// The cpio is gzipped (CONFIG_RD_GZIP) unless it already is or --no-gzip is
// given. Existing unkernel.* sections are replaced, so re-bundling works.
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { makePatch } from "./kwdiff.mjs";
import { kernelPatchInfo } from "../../js/core/kpatch.ts";

export const INITRD_SECTION = "unkernel.initrd";
export const CMDLINE_SECTION = "unkernel.cmdline";
export const DATADISK_SECTION = "unkernel.datadisk";
export const SMP_PATCH_SECTION = "unkernel.kernel.smp.kwpatch";

function uleb(n) {
	const out = [];
	do {
		let b = n & 0x7f;
		n = Math.floor(n / 128);
		if (n) b |= 0x80;
		out.push(b);
	} while (n);
	return Uint8Array.from(out);
}

function customSection(name, payload) {
	const nm = new TextEncoder().encode(name);
	const body = [uleb(nm.length), nm, payload];
	const size = body.reduce((s, b) => s + b.length, 0);
	return [Uint8Array.of(0), uleb(size), ...body];
}

/** Split a wasm binary into its sections: [{id, name?, start, end}]. */
function sections(wasm) {
	if (wasm.length < 8 || wasm[0] !== 0 || wasm[1] !== 0x61 || wasm[2] !== 0x73 || wasm[3] !== 0x6d)
		throw new Error("not a WebAssembly module");
	let p = 8;
	const leb = () => {
		let v = 0, s = 1, c;
		do { c = wasm[p++]; v += (c & 0x7f) * s; s *= 128; } while (c & 0x80);
		return v;
	};
	const out = [];
	while (p < wasm.length) {
		const start = p, id = wasm[p++], size = leb(), body = p;
		let name;
		if (id === 0) {
			const n = leb();
			name = new TextDecoder().decode(wasm.subarray(p, p + n));
		}
		p = body + size;
		if (p > wasm.length) throw new Error("truncated section");
		out.push({ id, name, start, end: p });
	}
	return out;
}

/**
 * What identifies a kernel build: { banner, smp, abi, cpuStart, memory64 }.
 * banner is linux_banner without its newline and smp whether its version
 * part ("#<build> SMP <time>") says SMP; abi is what kwemu's kw_abi_version()
 * returns (its KW_ABI_VERSION; null if it is not a plain constant, or no
 * kwemu); cpuStart whether it imports wasm_cpu_start; memory64 its memory's
 * index type.
 */
export function kernelInfo(wasm) {
	const secs = sections(wasm);
	let p = 0;
	const uleb = () => { let v = 0, s = 1, c; do { c = wasm[p++]; v += (c & 0x7f) * s; s *= 128; } while (c & 0x80); return v; };
	const str = () => { const n = uleb(); const r = new TextDecoder().decode(wasm.subarray(p, p + n)); p += n; return r; };
	let nimports = 0, cpuStart = false, memory64 = false, abiIndex, bodies = [];
	for (const s of secs) {
		p = s.start + 1;
		uleb(); // the section's size; p is at its payload
		if (s.id === 2) {
			const n = uleb();
			for (let i = 0; i < n; i++) {
				str();
				const name = str(), k = wasm[p++];
				if (k === 0) { uleb(); nimports++; if (name === "wasm_cpu_start") cpuStart = true; }
				else if (k === 1) { p++; const fl = uleb(); uleb(); if (fl & 1) uleb(); }
				else if (k === 2) { const fl = uleb(); uleb(); if (fl & 1) uleb(); memory64 = !!(fl & 4); }
				else if (k === 3) p += 2;
				else if (k === 4) { p++; uleb(); }
				else throw new Error(`kernel: unknown import kind ${k}`);
			}
		} else if (s.id === 10) {
			const n = uleb();
			for (let i = 0; i < n; i++) { const size = uleb(); bodies.push(p); p += size; }
		} else if (s.id === 0 && s.name === "name") {
			str();
			while (p < s.end) {
				const sub = wasm[p++], size = uleb(), se = p + size;
				if (sub === 1) {
					const n = uleb();
					for (let i = 0; i < n && abiIndex === undefined; i++) { const idx = uleb(); if (str() === "kw_abi_version") abiIndex = idx; }
				}
				p = se;
			}
		}
	}
	// kw_abi_version(): no locals, i32.const N, end.
	let abi = null;
	if (abiIndex !== undefined && bodies[abiIndex - nimports] !== undefined) {
		p = bodies[abiIndex - nimports];
		if (uleb() === 0 && wasm[p++] === 0x41) {
			const v = uleb();
			if (wasm[p] === 0x0b && v < 64) abi = v;
		}
	}
	// The last "Linux version <digit>": the data has two, init/version.o's,
	// made with a temporary version string, and linux_banner after it
	// (version-timestamp.o, the final one).
	const b = Buffer.from(wasm.buffer, wasm.byteOffset, wasm.length);
	let i = -1, banner = "";
	while ((i = b.indexOf("Linux version ", i + 1)) >= 0) {
		if (b[i + 14] < 0x30 || b[i + 14] > 0x39) continue;
		let e = i;
		while (e < b.length && b[e] !== 0 && b[e] !== 0x0a) e++;
		banner = b.subarray(i, e).toString("latin1");
	}
	const uts = banner.lastIndexOf(") #");
	const smp = uts >= 0 && banner.slice(uts + 2).split(" ")[1] === "SMP";
	return { banner, smp, abi, cpuStart, memory64 };
}

/** Why `smp` is not the SMP build of the tree `up` was built from, or undefined if it is. */
export function smpPairError(up, smp) {
	const a = kernelInfo(up), b = kernelInfo(smp);
	if (!a.banner || !b.banner) return `no linux_banner in the ${a.banner ? "SMP" : "UP"} kernel`;
	if (a.smp || !b.smp) return `the UP kernel's banner must not say SMP and the SMP kernel's must:\n  UP:  ${a.banner}\n  SMP: ${b.banner}`;
	const u = a.banner.lastIndexOf(") #"), s = b.banner.lastIndexOf(") #");
	const plain = b.banner.slice(0, s + 2) + b.banner.slice(s + 2).replace(/^(#\S+) SMP /, "$1 ");
	if (plain !== a.banner || u !== s)
		return `the kernels are not two builds of the same tree (their banners differ in more than "SMP"; rebuild both: kernel/build.sh kernel, then smp):\n  UP:  ${a.banner}\n  SMP: ${b.banner}`;
	if (a.abi !== b.abi) return `the kernels' kwemu differ in KW_ABI_VERSION: UP ${a.abi}, SMP ${b.abi}`;
	if (a.cpuStart || !b.cpuStart) return `only the SMP kernel imports wasm_cpu_start (UP: ${a.cpuStart}, SMP: ${b.cpuStart})`;
	if (a.memory64 !== b.memory64) return `one kernel is lowered (vmlinux32.wasm) and the other is not (memory64: UP ${a.memory64}, SMP ${b.memory64})`;
	return undefined;
}

const sha256 = (u8) => createHash("sha256").update(u8).digest();

export function bundle(wasm, initrd, { cmdline, datadisk, gzip = true, smp, smpPatch, smpOptional = false } = {}) {
	const isGz = initrd[0] === 0x1f && initrd[1] === 0x8b;
	if (gzip && !isGz) initrd = gzipSync(initrd, { level: 9 });
	const parts = [wasm.subarray(0, 8)];
	for (const s of sections(wasm))
		if (!(s.id === 0 && s.name.startsWith("unkernel."))) parts.push(wasm.subarray(s.start, s.end));
	const kernelBytes = parts.reduce((n, b) => n + b.length, 0);
	parts.push(...customSection(INITRD_SECTION, initrd));
	if (cmdline) parts.push(...customSection(CMDLINE_SECTION, new TextEncoder().encode(cmdline)));
	if (datadisk) {
		if (!(datadisk[0] === 0x1f && datadisk[1] === 0x8b)) throw new Error("the data disk template must be a gzipped kwsparse image");
		parts.push(...customSection(DATADISK_SECTION, datadisk));
	}
	let patch, smpSkipped, smpPatchReused = false;
	if (smp) {
		// The base is what the loader takes from the bundle: every section but the unkernel.* ones.
		const base = Buffer.concat(parts).subarray(0, kernelBytes);
		smpSkipped = smpPairError(base, smp);
		if (smpSkipped && !smpOptional) throw new Error(`bundle --smp: ${smpSkipped}`);
		if (!smpSkipped) {
			if (smpPatch) {
				const h = kernelPatchInfo(smpPatch);
				if (h.remap && sha256(base).equals(h.baseSha256) && sha256(smp).equals(h.targetSha256)) {
					patch = smpPatch;
					smpPatchReused = true;
				}
			}
			patch ??= makePatch(base, smp, { remap: true }).patch;
			parts.push(...customSection(SMP_PATCH_SECTION, patch));
		}
	}
	return {
		bytes: Buffer.concat(parts), kernelBytes, initrdBytes: initrd.length, datadiskBytes: datadisk?.length ?? 0,
		smpPatch: patch, smpPatchBytes: patch?.length ?? 0, smpPatchReused, smpSkipped,
	};
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const args = process.argv.slice(2);
	const take = (name) => {
		const i = args.indexOf(name);
		if (i < 0) return undefined;
		const v = args[i + 1];
		args.splice(i, 2);
		return v;
	};
	const out = take("-o");
	const cmdline = take("--cmdline");
	const datadiskPath = take("--datadisk");
	const smpPath = take("--smp");
	const smpPatchPath = take("--smp-patch");
	const flags = new Set(args.filter((a) => a === "--no-gzip" || a === "--smp-optional"));
	const [kernelPath, initrdPath, extra] = args.filter((a) => !flags.has(a));
	if (!kernelPath || !initrdPath || extra || !out || ((smpPatchPath || flags.has("--smp-optional")) && !smpPath)) {
		console.error("usage: bundle.mjs <vmlinux|vmlinux32.wasm> <initrd.cpio[.gz]> -o <out.wasm> [--cmdline STR] [--datadisk FILE] [--no-gzip] [--smp SMP.wasm [--smp-patch FILE] [--smp-optional]]");
		process.exit(2);
	}
	const wasm = readFileSync(kernelPath);
	const datadisk = datadiskPath ? readFileSync(datadiskPath) : undefined;
	const smp = smpPath ? readFileSync(smpPath) : undefined;
	const smpPatch = smpPatchPath && existsSync(smpPatchPath) ? readFileSync(smpPatchPath) : undefined;
	let r;
	try {
		r = bundle(wasm, readFileSync(initrdPath), { cmdline, datadisk, gzip: !flags.has("--no-gzip"), smp, smpPatch, smpOptional: flags.has("--smp-optional") });
	} catch (e) {
		console.error(`bundle: ${e.message}`);
		process.exit(1);
	}
	const { bytes, kernelBytes, initrdBytes, datadiskBytes, smpPatchBytes, smpPatchReused, smpSkipped } = r;
	if (smpSkipped) console.error(`bundle: warning: no SMP patch: ${smpSkipped}`);
	if (smpPatchPath && r.smpPatch && !smpPatchReused) {
		writeFileSync(smpPatchPath + ".tmp", r.smpPatch);
		renameSync(smpPatchPath + ".tmp", smpPatchPath);
	}
	writeFileSync(out + ".tmp", bytes);
	renameSync(out + ".tmp", out);
	const mib = (n) => (n / 1048576).toFixed(1) + " MiB";
	console.log(`bundle: ${out} (${mib(bytes.length)}: kernel ${mib(kernelBytes)} + initrd ${mib(initrdBytes)}` +
		`${datadiskBytes ? ` + data disk template ${(datadiskBytes / 1024).toFixed(0)} KiB` : ""}` +
		`${smpPatchBytes ? ` + SMP patch ${(smpPatchBytes / 1024).toFixed(0)} KiB${smpPatchReused ? ` (from ${smpPatchPath})` : ""}` : ""}` +
		`${cmdline ? `, cmdline "${cmdline}"` : ""})`);
}
