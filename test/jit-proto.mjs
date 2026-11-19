// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Feasibility prototype for a kwemu wasm JIT tier (NOT used by the library).
//
// For a few hot RV64 loops it measures:
//   * the kwemu interpreter (wasm64, kwemu-harness.wasm) on the same loop,
//     packaged as a tiny static ELF;
//   * the same loop translated to a wasm function: guest registers in wasm
//     locals, loads/stores through an inline TLB check with kwemu's TLB
//     layout (tag = vpn, host = va + add; a miss is a side exit), budget
//     accounting per iteration, and the module instantiated against the
//     *same* memory64 the interpreter runs in (as a kernel JIT would);
//   * compile + instantiate latency per translated block.
// The translated code is checked against a reference run of the same loop.
//
// usage: BUN_JSC_useWasmMemory64=1 bun test/jit-proto.mjs <zig-out prefix>
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const prefix = resolve(process.argv[2] ?? "zig-out");

// ---- tiny RV64 assembler -----------------------------------------------------
const R = (op, f3, f7, rd, rs1, rs2) => ((f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op) >>> 0;
const I = (op, f3, rd, rs1, imm) => (((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op) >>> 0;
const S = (f3, rs2, rs1, imm) => ((((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | 0x23) >>> 0;
const B = (f3, rs1, rs2, off) =>
  ((((off >> 12) & 1) << 31) | (((off >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (((off >> 1) & 0xf) << 8) | (((off >> 11) & 1) << 7) | 0x63) >>> 0;
const asm = {
  add: (d, a, b) => R(0x33, 0, 0, d, a, b), sub: (d, a, b) => R(0x33, 0, 0x20, d, a, b),
  xor: (d, a, b) => R(0x33, 4, 0, d, a, b), or: (d, a, b) => R(0x33, 6, 0, d, a, b), and: (d, a, b) => R(0x33, 7, 0, d, a, b),
  mul: (d, a, b) => R(0x33, 0, 1, d, a, b),
  addw: (d, a, b) => R(0x3b, 0, 0, d, a, b),
  addi: (d, a, i) => I(0x13, 0, d, a, i), xori: (d, a, i) => I(0x13, 4, d, a, i), andi: (d, a, i) => I(0x13, 7, d, a, i),
  slli: (d, a, sh) => I(0x13, 1, d, a, sh), srli: (d, a, sh) => I(0x13, 5, d, a, sh),
  srliw: (d, a, sh) => I(0x1b, 5, d, a, sh), slliw: (d, a, sh) => I(0x1b, 1, d, a, sh),
  ld: (d, a, i) => I(0x03, 3, d, a, i), lw: (d, a, i) => I(0x03, 2, d, a, i), lbu: (d, a, i) => I(0x03, 4, d, a, i),
  sd: (s, a, i) => S(3, s, a, i), sw: (s, a, i) => S(2, s, a, i), sb: (s, a, i) => S(0, s, a, i),
  bne: (a, b, off) => B(1, a, b, off), bltu: (a, b, off) => B(6, a, b, off),
  lui: (d, imm20) => ((imm20 << 12) | (d << 7) | 0x37) >>> 0,
  ecall: () => 0x73,
};
const [A0, A1, A2, A3, A4, A5, A7, T0, T1, T2, T3, T4, T5, T6] = [10, 11, 12, 13, 14, 15, 17, 5, 6, 7, 28, 29, 30, 31];

// Loops: body runs `iters` times; `setup` registers as after the prologue.
// mmap'd buffer pointer is in a0 for memory loops.
const loops = [
  {
    name: "int (kwbench int loop: mul/add/addi/bne)",
    iters: 50_000_000, buf: 0,
    // a2 = LCG multiplier, a1 = i, a3 = N
    body: () => [asm.mul(A0, A0, A2), asm.add(A0, A0, A1), asm.addi(A1, A1, 1), asm.bne(A1, A3, -12)],
    regs: { [A0]: 1n, [A2]: 6364136223846793005n, [A1]: 0n },
  },
  {
    name: "mem (kwbench mem loop: ld/xor/add/sd)",
    iters: 8 * 1048576, buf: 8 << 20,
    // a0 = p, a4 = end, a5 = r; loop: t0 = *p; t1 = p ^ r; *p = t0 + t1; p += 8
    body: () => [asm.ld(T0, A0, 0), asm.xor(T1, A0, A5), asm.add(T0, T0, T1), asm.sd(T0, A0, 0), asm.addi(A0, A0, 8), asm.bltu(A0, A4, -20)],
    wrap: true, // re-run over the buffer
    regs: { [A5]: 3n },
  },
  {
    name: "alu (sha-like rotate/xor/add chain, 16 insns)",
    iters: 10_000_000, buf: 0,
    body: () => [
      asm.srliw(T0, A0, 6), asm.slliw(T1, A0, 26), asm.or(T0, T0, T1), asm.xor(T2, A1, A2),
      asm.and(T2, T2, A0), asm.xor(T2, T2, A2), asm.addw(A3, A3, T0), asm.addw(A3, A3, T2),
      asm.srliw(T0, A3, 2), asm.slliw(T1, A3, 30), asm.or(T0, T0, T1), asm.addw(A2, A1, T0),
      asm.addw(A1, A0, A3), asm.xori(A0, A3, 0x5a5), asm.addi(A4, A4, -1), asm.bne(A4, 0, -60),
    ],
    regs: { [A0]: 0x6a09e667n, [A1]: 0xbb67ae85n, [A2]: 0x3c6ef372n, [A3]: 0xa54ff53an },
  },
];

// ---- static ELF for the interpreter run ------------------------------------
function li(rd, v) { // any 64-bit constant: 4-bit top chunk, then 5 x 12 bits (uses t6)
  v = BigInt.asUintN(64, BigInt(v));
  const out = [asm.addi(rd, 0, Number(v >> 60n))];
  for (let sh = 48; sh >= 0; sh -= 12) {
    const chunk = Number((v >> BigInt(sh)) & 0xfffn);
    out.push(asm.slli(rd, rd, 12), asm.addi(T6, 0, chunk >> 1), asm.add(T6, T6, T6), asm.addi(T6, T6, chunk & 1), asm.or(rd, rd, T6));
  }
  return out;
}
function programFor(L) {
  const p = [];
  if (L.buf) { // a0 = mmap(0, buf, 3, 0x22, -1, 0)
    p.push(asm.addi(A0, 0, 0), ...li(A1, L.buf), asm.addi(A2, 0, 3), asm.addi(A3, 0, 0x22), asm.addi(A4, 0, -1), asm.addi(A5, 0, 0), asm.addi(A7, 0, 222), asm.ecall());
  }
  for (const [r, v] of Object.entries(L.regs)) p.push(...li(Number(r), v));
  if (L.name.startsWith("int")) p.push(...li(A3, L.iters));
  if (L.name.startsWith("alu")) p.push(...li(A4, L.iters));
  let outer = 0;
  if (L.name.startsWith("mem")) { // s1 = rounds; outer: a0 = buf, a4 = buf+len
    p.push(asm.addi(9, A0, 0), ...li(8, L.iters / (L.buf / 8)));
    outer = p.length;
    p.push(asm.addi(A0, 9, 0), ...li(A4, L.buf), asm.add(A4, A4, 9));
  }
  p.push(...L.body());
  if (L.name.startsWith("mem")) p.push(asm.addi(8, 8, -1), asm.bne(8, 0, (outer - (p.length + 1)) * 4));
  p.push(asm.addi(A0, 0, 0), asm.addi(A7, 0, 93), asm.ecall());
  return p;
}
function elf(words) {
  const code = new Uint8Array(new Uint32Array(words).buffer);
  const buf = new ArrayBuffer(0x1000 + code.length);
  const v = new DataView(buf);
  const u8 = new Uint8Array(buf);
  u8.set([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1], 0);
  v.setUint16(16, 2, true); v.setUint16(18, 243, true); v.setUint32(20, 1, true);
  v.setBigUint64(24, 0x10000n, true); v.setBigUint64(32, 64n, true);
  v.setUint16(52, 64, true); v.setUint16(54, 56, true); v.setUint16(56, 1, true);
  v.setUint32(64, 1, true); v.setUint32(68, 5, true); v.setBigUint64(72, 0x1000n, true);
  v.setBigUint64(80, 0x10000n, true); v.setBigUint64(88, 0x10000n, true);
  v.setBigUint64(96, BigInt(code.length), true); v.setBigUint64(104, BigInt(code.length), true);
  v.setBigUint64(112, 0x1000n, true);
  u8.set(code, 0x1000);
  return u8;
}

// ---- harness (interpreter) ----------------------------------------------------
const harness = await WebAssembly.compile(await readFile(join(prefix, "bin", "kwemu-harness.wasm")));
async function harnessInstance() {
  let err = "", mem;
  const inst = await WebAssembly.instantiate(harness, {
    env: {
      host_write: (fd, ptr, len) => { err += new TextDecoder().decode(new Uint8Array(mem.buffer, Number(ptr), Number(len))); },
      host_now_ns: () => Number(process.hrtime.bigint()),
    },
  });
  mem = inst.exports.memory;
  return { inst, mem, log: () => err };
}
async function interpMips(L) {
  const h = await harnessInstance();
  const image = elf(programFor(L));
  const args = new TextEncoder().encode("loop\0");
  const ptr = Number(h.inst.exports.kwh_buf(BigInt(image.length + args.length)));
  new Uint8Array(h.mem.buffer, ptr, image.length).set(image);
  new Uint8Array(h.mem.buffer, ptr + image.length, args.length).set(args);
  const st = h.inst.exports.kwh_run(BigInt(image.length), BigInt(args.length), 1);
  const m = /instret=(\d+) .*MIPS=([\d.]+)/.exec(h.log());
  if (st !== 0 || !m) throw new Error(`interpreter run failed (${st}): ${h.log()}`);
  return { mips: Number(m[2]), insns: Number(m[1]) };
}

// ---- wasm emitter --------------------------------------------------------------
const uleb = (n) => { n = BigInt(n); const o = []; do { let b = Number(n & 0x7fn); n >>= 7n; if (n) b |= 0x80; o.push(b); } while (n); return o; };
const sleb = (n) => { n = BigInt(n); const o = []; for (;;) { const b = Number(n & 0x7fn); n >>= 7n; if ((n === 0n && !(b & 0x40)) || (n === -1n && b & 0x40)) { o.push(b); return o; } o.push(b | 0x80); } };
const vec = (items) => [...uleb(items.length), ...items.flat()];
const section = (id, body) => [id, ...uleb(body.length), ...body];
const str = (s) => vec([...new TextEncoder().encode(s)].map((b) => [b]));
const op = {
  unreachable: 0x00, block: 0x02, loop: 0x03, if: 0x04, end: 0x0b, br: 0x0c, br_if: 0x0d, return: 0x0f,
  i32_const: 0x41, local_get: 0x20, local_set: 0x21, local_tee: 0x22,
  i64_load: 0x29, i64_load32_s: 0x34, i64_load32_u: 0x35, i64_load8_u: 0x31, i64_store: 0x37, i64_store32: 0x3e, i64_store8: 0x3c,
  i64_const: 0x42, i64_eqz: 0x50, i64_eq: 0x51, i64_ne: 0x52, i64_lt_u: 0x54, i64_lt_s: 0x53, i64_ge_u: 0x5a, i64_ge_s: 0x59, i64_gt_s: 0x55,
  i64_add: 0x7c, i64_sub: 0x7d, i64_mul: 0x7e, i64_and: 0x83, i64_or: 0x84, i64_xor: 0x85, i64_shl: 0x86, i64_shr_s: 0x87, i64_shr_u: 0x88,
  i32_wrap_i64: 0xa7, i64_extend_i32_s: 0xac, i64_extend_i32_u: 0xad, i32_shl: 0x74, i32_shr_u: 0x76, i32_shr_s: 0x75, i32_or: 0x72, i32_add: 0x6a,
};

/// Translate one loop (the body, ending in a backward branch to its start)
/// into a wasm module:  run(regs: i64, tlb_r: i64, tlb_w: i64, budget: i64) -> i64
/// Returns the guest pc to resume at (loop exit, budget, or the pc of an
/// access that missed the TLB); registers are written back to `regs`
/// (struct kw_regs layout). Budget is decremented per iteration.
function translate(words, startPc) {
  const L_REGS = 0, L_TLBR = 1, L_TLBW = 2, L_BUDGET = 3;
  const reg = (r) => 4 + r; // locals 4..35 = x0..x31 (x0 stays 0)
  const L_VA = 36, L_E = 37, L_EPC = 38;
  const c = [];
  const get = (r) => (r === 0 ? [op.i64_const, 0] : [op.local_get, reg(r)]);
  const set = (r) => (r === 0 ? [0x1a /* drop */] : [op.local_set, reg(r)]);
  const k = (v) => [op.i64_const, ...sleb(v)];
  const used = new Set();
  // prologue: load guest regs used by the loop
  for (const w of words) for (const r of [(w >> 7) & 31, (w >> 15) & 31, (w >> 20) & 31]) if (r) used.add(r);
  for (const r of used) c.push(op.local_get, L_REGS, op.i64_load, 3, ...uleb(r * 8), op.local_set, reg(r));
  // exit block wraps the loop; exits set L_EPC first
  c.push(op.block, 0x40, op.loop, 0x40);
  // budget check per iteration
  c.push(op.local_get, L_BUDGET, ...k(words.length), op.i64_sub, op.local_tee, L_BUDGET, ...k(0), op.i64_lt_s,
    op.if, 0x40, ...k(startPc), op.local_set, L_EPC, op.br, 2, op.end);
  const sx32 = [op.i32_wrap_i64, op.i64_extend_i32_s];
  const lo32 = [op.i32_wrap_i64];
  words.forEach((w, i) => {
    const pc = startPc + i * 4;
    const rd = (w >> 7) & 31, rs1 = (w >> 15) & 31, rs2 = (w >> 20) & 31, f3 = (w >> 12) & 7, f7 = w >>> 25;
    const immI = (w >> 20); // arithmetic shift: sign-extended
    const opc = w & 0x7f;
    const tlb = (base, size) => [ // L_E = &tlb[(va>>12)&255]; miss -> exit at pc
      op.local_get, base, op.local_get, L_VA, ...k(8), op.i64_shr_u, ...k(0xff0), op.i64_and, op.i64_add, op.local_tee, L_E,
      op.i64_load, 3, 0, op.local_get, L_VA, ...k(size - 1), op.i64_add, ...k(12), op.i64_shr_u, op.i64_ne,
      op.if, 0x40, ...k(pc + 1), op.local_set, L_EPC, op.br, 2, op.end, // odd pc = TLB miss
      op.local_get, L_E, op.i64_load, 3, 8, op.local_get, L_VA, op.i64_add,
    ];
    if (opc === 0x33 || opc === 0x3b) {
      const w32 = opc === 0x3b;
      const o = f7 === 1 ? op.i64_mul : f7 === 0x20 ? op.i64_sub : [op.i64_add, null, null, null, op.i64_xor, op.i64_shr_u, op.i64_or, op.i64_and][f3];
      c.push(...get(rs1), ...get(rs2), o, ...(w32 ? sx32 : []), ...set(rd));
    } else if (opc === 0x13 || opc === 0x1b) {
      const w32 = opc === 0x1b;
      if (f3 === 1 || f3 === 5) {
        const sh = (w >> 20) & (w32 ? 31 : 63);
        if (w32) c.push(...get(rs1), ...lo32, op.i32_const, ...sleb(sh), f3 === 1 ? op.i32_shl : op.i32_shr_u, op.i64_extend_i32_s, ...set(rd));
        else c.push(...get(rs1), ...k(sh), f3 === 1 ? op.i64_shl : op.i64_shr_u, ...set(rd));
      } else {
        const o = [op.i64_add, null, null, null, op.i64_xor, null, op.i64_or, op.i64_and][f3];
        c.push(...get(rs1), ...k(immI), o, ...(w32 ? sx32 : []), ...set(rd));
      }
    } else if (opc === 0x03) {
      c.push(...get(rs1), ...k(immI), op.i64_add, op.local_set, L_VA, ...tlb(L_TLBR, 8));
      c.push(f3 === 3 ? op.i64_load : f3 === 2 ? op.i64_load32_s : op.i64_load8_u, f3 === 3 ? 3 : 0, 0, ...set(rd));
    } else if (opc === 0x23) {
      const immS = ((w >> 25) << 5) | ((w >> 7) & 31);
      c.push(...get(rs1), ...k(immS), op.i64_add, op.local_set, L_VA, ...tlb(L_TLBW, 8));
      c.push(...get(rs2), f3 === 3 ? op.i64_store : f3 === 2 ? op.i64_store32 : op.i64_store8, f3 === 3 ? 3 : 0, 0);
    } else if (opc === 0x63) {
      if (i !== words.length - 1) throw new Error("branch must end the loop");
      const cmp = { 0: op.i64_eq, 1: op.i64_ne, 4: op.i64_lt_s, 5: op.i64_ge_s, 6: op.i64_lt_u, 7: op.i64_ge_u }[f3];
      c.push(...get(rs1), ...get(rs2), cmp, op.br_if, 0); // back to loop head
      c.push(...k(pc + 4), op.local_set, L_EPC);
    } else throw new Error(`unsupported insn ${w.toString(16)}`);
  });
  c.push(op.end, op.end); // loop, block
  // epilogue: write back and return the resume pc
  for (const r of used) c.push(op.local_get, L_REGS, op.local_get, reg(r), op.i64_store, 3, ...uleb(r * 8));
  c.push(op.local_get, L_REGS, op.local_get, L_BUDGET, op.i64_store, 3, ...uleb(66 * 8)); // scratch: budget left
  c.push(op.local_get, L_EPC, op.end);
  const locals = vec([[...uleb(35), 0x7e]]); // 35 extra i64 locals
  const body = [...locals, ...c];
  const I64 = 0x7e;
  const mod = [
    0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
    ...section(1, vec([[0x60, ...vec([[I64], [I64], [I64], [I64]]), ...vec([[I64]])]])),
    ...section(2, vec([[...str("env"), ...str("memory"), 0x02, 0x04, ...uleb(1)]])), // memory64, min 1 page
    ...section(3, vec([[0]])),
    ...section(7, vec([[...str("run"), 0x00, 0]])),
    ...section(10, vec([[...uleb(body.length), ...body]])),
  ];
  return new Uint8Array(mod);
}

// ---- JIT run against the harness's memory -------------------------------------
async function jitRun(L0, iters) {
  const L = { ...L0, iters: iters ?? L0.iters };
  const h = await harnessInstance();
  const mem = h.mem;
  // Scratch area in the harness heap (kwh_buf scratch, 48 MiB): regs, two
  // TLBs (kwemu layout: {tag, add} x 256), the data buffer.
  const base = Number(h.inst.exports.kwh_buf(BigInt(40 << 20)));
  const regs = base, tlbR = base + 4096, tlbW = base + 8192, data = base + (1 << 20);
  const dv = new DataView(mem.buffer);
  const vaBase = 0x3f00000000n; // guest VA of the buffer
  // identity-ish mapping: every buffer page has a TLB entry (256 pages = 1 MiB
  // window; the rest misses -> side exit -> refill, like kwemu's TLB)
  const fill = (va) => {
    const vpn = BigInt(va) >> 12n;
    const add = BigInt(data) - vaBase;
    for (const t of [tlbR, tlbW]) {
      const e = t + Number(vpn & 255n) * 16;
      dv.setBigUint64(e, vpn, true);
      dv.setBigUint64(e + 8, add, true);
    }
  };
  for (const [r, v] of Object.entries(L.regs)) dv.setBigUint64(regs + Number(r) * 8, BigInt.asUintN(64, v), true);
  const startPc = 0x10000;
  const words = L.body();
  const t0 = process.hrtime.bigint();
  const mod = translate(words, startPc);
  const inst = new WebAssembly.Instance(new WebAssembly.Module(mod), { env: { memory: mem } });
  const t1 = process.hrtime.bigint();
  const run = inst.exports.run;
  const setR = (r, v) => dv.setBigUint64(regs + r * 8, BigInt.asUintN(64, BigInt(v)), true);
  const getR = (r) => dv.getBigUint64(regs + r * 8, true);
  let insns = 0;
  const slice = 200_000n; // kernel slice
  const tStart = process.hrtime.bigint();
  if (L.name.startsWith("int")) {
    setR(A3, L.iters);
    let pc;
    do {
      pc = run(BigInt(regs), BigInt(tlbR), BigInt(tlbW), slice);
      const left = dv.getBigInt64(regs + 66 * 8, true);
      insns += Number(slice - (left < 0n ? left + BigInt(words.length) : left));
    } while (pc === BigInt(startPc));
  } else if (L.name.startsWith("alu")) {
    setR(A4, L.iters);
    let pc;
    do {
      pc = run(BigInt(regs), BigInt(tlbR), BigInt(tlbW), slice);
      const left = dv.getBigInt64(regs + 66 * 8, true);
      insns += Number(slice - (left < 0n ? left + BigInt(words.length) : left));
    } while (pc === BigInt(startPc));
  } else {
    const rounds = L.iters / (L.buf / 8);
    for (let r = 0; r < rounds; r++) {
      setR(A0, vaBase);
      setR(A4, vaBase + BigInt(L.buf));
      for (;;) {
        const pc = run(BigInt(regs), BigInt(tlbR), BigInt(tlbW), slice);
        const left = dv.getBigInt64(regs + 66 * 8, true);
        insns += Number(slice - (left < 0n ? left + BigInt(words.length) : left));
        if (pc === BigInt(startPc + words.length * 4)) break; // loop done
        if (pc & 1n) fill(getR(A0)); // TLB miss side exit (odd pc): refill, resume at the loop head
      }
    }
  }
  const tEnd = process.hrtime.bigint();
  return {
    compileUs: Number(t1 - t0) / 1e3,
    bytes: mod.length,
    mips: insns / (Number(tEnd - tStart) / 1e3),
    insns,
    result: { a0: getR(A0), a1: getR(A1), a3: getR(A3) },
    check: () => (L.name.startsWith("mem") ? new BigUint64Array(mem.buffer, data, 4) : null),
  };
}

// Reference for correctness: int loop result computed with BigInt.
function refInt(n) {
  let a0 = 1n;
  for (let i = 0n; i < BigInt(n); i++) a0 = BigInt.asUintN(64, a0 * 6364136223846793005n + i);
  return a0;
}

console.log("| loop | interpreter MIPS | JIT MIPS | speedup | JIT compile+instantiate | module bytes |");
console.log("| --- | ---: | ---: | ---: | ---: | ---: |");
for (const L of loops) {
  const it = await interpMips(L);
  const j = await jitRun(L);
  if (L.name.startsWith("int")) {
    const small = await jitRun(L, 300000); // several budget slices
    const want = refInt(300000);
    if (small.result.a0 !== want) throw new Error(`JIT int loop mismatch: ${small.result.a0} vs ${want}`);
  }
  if (L.name.startsWith("mem")) {
    // buf[i] = sum over rounds of (va ^ 3); 8 rounds -> 8 * ((vaBase+8i) ^ 3)
    const w = j.check();
    for (let i = 0; i < 4; i++) {
      const want = BigInt.asUintN(64, BigInt(L.iters / (L.buf / 8)) * ((0x3f00000000n + BigInt(8 * i)) ^ 3n));
      if (w[i] !== want) throw new Error(`JIT mem loop mismatch at ${i}: ${w[i]} vs ${want}`);
    }
  }
  console.log(`| ${L.name} | ${it.mips.toFixed(0)} | ${j.mips.toFixed(0)} | ${(j.mips / it.mips).toFixed(1)}x | ${j.compileUs.toFixed(0)} us | ${j.bytes} |`);
}
