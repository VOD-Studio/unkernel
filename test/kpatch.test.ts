// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Kernel patches (.agents/js.md, CPU threads): kernel/tools/kwdiff.mjs
// makes them, js/core/kpatch.ts applies them. Synthetic data always; the
// real UP and SMP kernels when given (byte-identical result, remapped and
// not, and the bundle path of bundle.mjs --smp):
//
//   bun run test:kpatch
//   KPATCH_UP=up/vmlinux32.wasm KPATCH_SMP=smp/vmlinux32.wasm bun run test:kpatch
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { applyKernelPatch, kernelPatchInfo, smpKernelFromBundle } from "../js/core/kpatch.ts";
// @ts-expect-error: a build tool in plain JavaScript, without types
import { makePatch } from "../kernel/tools/kwdiff.mjs";
// @ts-expect-error: a build tool in plain JavaScript, without types
import { bundle } from "../kernel/tools/bundle.mjs";

function rand(n: number, seed: number): Uint8Array {
	const out = new Uint8Array(n);
	let x = seed >>> 0 || 1;
	for (let i = 0; i < n; i++) {
		x ^= x << 13; x ^= x >>> 17; x ^= x << 5;
		out[i] = x & 0xff;
	}
	return out;
}

test("byte patch: edits, inserts, deletes and moved blocks round-trip", async () => {
	const base = rand(200_000, 7);
	const parts = [base.subarray(50_000, 90_000), rand(3000, 9), base.subarray(0, 50_000), base.subarray(120_000)];
	const target = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
	let o = 0;
	for (const p of parts) { target.set(p, o); o += p.length; }
	for (let i = 0; i < target.length; i += 997) target[i] = (target[i]! + 3) & 0xff;
	const { patch } = makePatch(base, target);
	assert.ok(patch.length < target.length / 4, `patch ${patch.length} bytes`);
	const info = kernelPatchInfo(patch);
	assert.equal(info.baseLength, base.length);
	assert.equal(info.targetLength, target.length);
	assert.deepEqual(await applyKernelPatch(base, patch), target);
	await assert.rejects(applyKernelPatch(base.subarray(1), patch), /the base is/);
	const wrong = base.slice();
	wrong[5]! ^= 1;
	await assert.rejects(applyKernelPatch(wrong, patch), /not the one/);
});

/** A custom section (id 0): name, then payload. */
function custom(name: string, payload: Uint8Array): Uint8Array {
	const uleb = (n: number) => { const o: number[] = []; do { let b = n & 0x7f; n = Math.floor(n / 128); if (n) b |= 0x80; o.push(b); } while (n); return o; };
	const nm = new TextEncoder().encode(name);
	const body = [...uleb(nm.length), ...nm, ...payload];
	return Uint8Array.from([0, ...uleb(body.length), ...body]);
}
const cat = (...p: Uint8Array[]) => new Uint8Array(Buffer.concat(p));

test("a bundle whose patch does not match its kernel: smpKernelFromBundle and loadKernelModule({ smp }) refuse it", async () => {
	// A module (only custom sections, which are part of the kernel unless they are unkernel.*) and a patch to another.
	const header = Uint8Array.of(0, 0x61, 0x73, 0x6d, 1, 0, 0, 0);
	const base = cat(header, custom("kernel", rand(50_000, 11)));
	const target = cat(header, custom("kernel", rand(60_000, 12)));
	const { patch } = makePatch(base, target);
	const initrd = custom("unkernel.initrd", rand(100, 13));
	const good = cat(base, initrd, custom("unkernel.kernel.smp.kwpatch", patch));
	const out = await smpKernelFromBundle(good);
	assert.ok(out && Buffer.compare(Buffer.from(out), Buffer.from(cat(target, initrd))) === 0);
	// Same length, one byte changed (another build of the kernel): the base hash.
	const changed = good.slice();
	changed[header.length + 20]! ^= 1;
	await assert.rejects(smpKernelFromBundle(changed), /the base module is not the one the patch was made for/);
	// Another length (a kernel with one more section): the base length.
	const longer = cat(base, custom("extra", rand(10, 14)), initrd, custom("unkernel.kernel.smp.kwpatch", patch));
	await assert.rejects(smpKernelFromBundle(longer), /the base is \d+ bytes, the patch wants \d+/);
	// A corrupt patch whose result is wrong: the result hash.
	const p2 = patch.slice();
	p2[p2.length - 1]! ^= 1;
	await assert.rejects(smpKernelFromBundle(cat(base, initrd, custom("unkernel.kernel.smp.kwpatch", p2))), /the result does not match/);
	// The SDK's loader turns it into a BootError at the compile stage (the CLI prints it and exits 1).
	const { loadKernelModule, BootError } = await import("../js/core/load.ts");
	await assert.rejects(loadKernelModule(changed, { smp: true }), (e: unknown) =>
		e instanceof BootError && e.stage === "compile" && /Deriving the SMP kernel from the bundle failed: kernel patch: the base module/.test(e.message));
});

const up = process.env.KPATCH_UP, smp = process.env.KPATCH_SMP;
test("real kernels: UP -> SMP and SMP -> UP, remapped, byte-identical", { skip: !(up && smp) && "KPATCH_UP and KPATCH_SMP not set" }, async () => {
	const a = new Uint8Array(fs.readFileSync(up!)), b = new Uint8Array(fs.readFileSync(smp!));
	for (const [x, y] of [[a, b], [b, a]] as const) {
		const { patch } = makePatch(x, y, { remap: true });
		assert.ok(kernelPatchInfo(patch).remap);
		assert.ok(Buffer.compare(Buffer.from(await applyKernelPatch(x, patch)), Buffer.from(y)) === 0);
	}
});

test("bundle.mjs --smp: the loader's SMP kernel is the SMP build plus the bundle's sections", { skip: !(up && smp) && "KPATCH_UP and KPATCH_SMP not set" }, async () => {
	const a = fs.readFileSync(up!), b = fs.readFileSync(smp!);
	const initrd = rand(1000, 3);
	const { bytes } = bundle(a, initrd, { cmdline: "console=hvc0", gzip: false, smp: b });
	const out = await smpKernelFromBundle(new Uint8Array(bytes));
	assert.ok(out);
	assert.ok(Buffer.compare(Buffer.from(out.subarray(0, b.length)), b) === 0);
	const m = await WebAssembly.compile(out as Uint8Array<ArrayBuffer>);
	assert.deepEqual(new Uint8Array(WebAssembly.Module.customSections(m, "unkernel.initrd")[0]!), initrd);
	assert.equal(new TextDecoder().decode(WebAssembly.Module.customSections(m, "unkernel.cmdline")[0]!), "console=hvc0");
	assert.equal(WebAssembly.Module.customSections(m, "unkernel.kernel.smp.kwpatch").length, 0);
	assert.ok(WebAssembly.Module.imports(m).some((i) => i.name === "wasm_cpu_start"));
	// No patch: undefined (the loader then uses the bundle as it is).
	assert.equal(await smpKernelFromBundle(new Uint8Array(bundle(a, initrd, { gzip: false }).bytes)), undefined);
});

test("bundle.mjs --smp: refuses kernels that are not the UP and SMP builds of one tree, and reuses a cached patch", { skip: !(up && smp) && "KPATCH_UP and KPATCH_SMP not set" }, async () => {
	// @ts-expect-error: a build tool in plain JavaScript, without types
	const { smpPairError, kernelInfo } = await import("../kernel/tools/bundle.mjs");
	const a = fs.readFileSync(up!), b = fs.readFileSync(smp!);
	const initrd = rand(1000, 3);
	assert.equal(smpPairError(a, b), undefined);
	const ia = kernelInfo(a), ib = kernelInfo(b);
	assert.ok(!ia.smp && ib.smp && ia.abi === ib.abi && typeof ia.abi === "number");
	assert.match(smpPairError(a, a), /banner must not say SMP/);
	assert.match(smpPairError(b, b), /banner must not say SMP/);
	// Another build of the tree: the banner's build id differs.
	const other = Buffer.from(b);
	const at = other.lastIndexOf(") #") + 3;
	other[at] = other[at] === 0x30 ? 0x31 : 0x30;
	assert.match(smpPairError(a, other), /not two builds of the same tree/);
	assert.throws(() => bundle(a, initrd, { gzip: false, smp: other }), /bundle --smp: the kernels are not two builds/);
	// --smp-optional: a warning, and the bundle without the patch.
	const skipped = bundle(a, initrd, { gzip: false, smp: other, smpOptional: true });
	assert.match(skipped.smpSkipped, /not two builds/);
	assert.equal(skipped.smpPatchBytes, 0);
	assert.equal(await smpKernelFromBundle(new Uint8Array(skipped.bytes)), undefined);
	// --smp-patch: a patch made from these two kernels is reused as it is; any other is not.
	const first = bundle(a, initrd, { gzip: false, smp: b });
	assert.equal(first.smpPatchReused, false);
	const again = bundle(a, initrd, { gzip: false, smp: b, smpPatch: first.smpPatch });
	assert.equal(again.smpPatchReused, true);
	assert.ok(Buffer.compare(again.bytes, first.bytes) === 0);
	const stale = Buffer.from(first.smpPatch);
	stale[60]! ^= 1; // inside the target's SHA-256
	assert.equal(bundle(a, initrd, { gzip: false, smp: b, smpPatch: stale }).smpPatchReused, false);
});
