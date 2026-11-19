// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! kwemu block executor: the compact op format, the decoder from RV64GC
//! into ops, the op semantics, and the dispatchers (a labeled `switch`, or
//! optionally one function per op chained with guaranteed tail calls).
//! Cache management (lookup, validation, invalidation) is in kwemu.zig.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../cpu/core.zig");
const kwemu = @import("kwemu.zig");
const options = @import("kwemu_options");
const Cpu = kwemu.Cpu;
const Regs = core.Regs;

/// Dispatch with `return_call_indirect` chains instead of a `switch` loop
/// (needs the wasm tail_call feature; `-Dkwemu-tail-call`).
pub const tail_call = options.tail_call;

pub const H = enum(u8) {
    // x[rd] = f(x[rs1], imm)
    addi,
    addiw,
    andi,
    ori,
    xori,
    slti,
    sltiu,
    slli,
    srli,
    srai,
    slliw,
    srliw,
    sraiw,
    li,
    // x[rd] = f(x[rs1], x[rs2])
    add,
    sub,
    and_,
    or_,
    xor_,
    sll,
    srl,
    sra,
    slt,
    sltu,
    addw,
    subw,
    sllw,
    srlw,
    sraw,
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    mulw,
    divw,
    divuw,
    remw,
    remuw,
    // Zkne / Zknd (only decoded while enabled): x[rd] = f(x[rs1], x[rs2])
    aes64es,
    aes64esm,
    aes64ds,
    aes64dsm,
    aes64ks2,
    // x[rd] = f(x[rs1]) (rs2 = 0); aes64ks1i: imm = rnum (0..10)
    aes64im,
    aes64ks1i,
    // Zbkb (or Zbb), Zbc/Zbkc, Zbkx (only decoded while enabled; see
    // core.bitmanip for which extension has which): x[rd] = f(x[rs1], x[rs2])
    andn,
    orn,
    xnor,
    rol,
    ror,
    rolw,
    rorw,
    pack,
    packh,
    packw,
    clmul,
    clmulh,
    clmulr,
    xperm4,
    xperm8,
    // x[rd] = f(x[rs1], imm) (rori: imm = shamt 0..63, roriw: 0..31)
    rori,
    roriw,
    rev8,
    brev8,
    // Zba, Zbb, Zbs, Zicond (only decoded while enabled). One op per
    // operation, with the variants in imm, so that the dispatch stays small
    // (bseti/bclri/binvi decode to ori/andi/xori with the mask in imm):
    /// x[rd] = ((x[rs1] & mask) << s) + x[rs2]; imm = s (0..63) | 64 for
    /// the .uw forms (mask = 0xffffffff, else all ones). sh1add..sh3add,
    /// add.uw, sh1add.uw..sh3add.uw, and slli.uw (rs2 = x0)
    shadd,
    /// clz((x[rs1] << imm) | ((1 << imm) - 1)); imm = 0, or 32 for clzw
    clz,
    /// ctz(x[rs1] | imm); imm = 0, or 1 << 32 for ctzw
    ctz,
    /// popcount(x[rs1] & imm); imm = all ones, or 0xffffffff for cpopw
    cpop,
    /// min/max: compares x[rs1] ^ b and x[rs2] ^ b signed, b = imm & 1 << 63
    /// (set for minu/maxu); imm bit 0 = max
    minmax,
    /// sign-extend from bit 63 - imm (imm = 56 sext.b, 48 sext.h)
    sext,
    orc_b,
    /// (x[rs1] & ~(m & k1)) ^ (m & k2), m = 1 << (x[rs2] & 63), k1/k2 all
    /// ones if imm bit 0/1 is set: bclr (imm 1), bset (3), binv (2)
    bitop,
    /// (x[rs1] >> ((x[rs2] + imm) & 63)) & 1: bext (imm = 0), bexti (rs2 = x0)
    bext,
    /// x[rd] = (x[rs2] == 0) != (imm != 0) ? 0 : x[rs1]; imm = 0 czero.eqz,
    /// 1 czero.nez
    czero,
    // x[rd] = mem[x[rs1] + imm]
    lb,
    lh,
    lw,
    ld,
    lbu,
    lhu,
    lwu,
    flw,
    fld,
    // mem[x[rs1] + imm] = x[rs2]
    sb,
    sh,
    sw,
    sd,
    fsw,
    fsd,
    nop,
    // F/D: rd/rs1/rs2 are FP registers unless noted; imm = rm (bits 0-2,
    // 7 = dynamic) | rs3 << 8 (fma)
    fadd_s,
    fsub_s,
    fmul_s,
    fdiv_s,
    fadd_d,
    fsub_d,
    fmul_d,
    fdiv_d,
    fmadd_s,
    fmsub_s,
    fnmsub_s,
    fnmadd_s,
    fmadd_d,
    fmsub_d,
    fnmsub_d,
    fnmadd_d,
    /// f[rd] = f(f[rs1], f[rs2]) without a rounding mode, or a rounding to
    /// an integer: imm = 0 fsgnj, 1 fsgnjn, 2 fsgnjx; 4 fmin, 5 fmax, 6
    /// fminm, 7 fmaxm (Zfa); 16 | rm fround, 24 | rm froundnx (Zfa; rs2 =
    /// 0, rm 7 = dynamic). One kind for all of them keeps the dispatch small.
    fsgnj_s,
    fsgnj_d,
    /// x[rd] = compare; imm = funct3 (2 feq, 1 flt, 0 fle; Zfa: 4 fleq,
    /// 5 fltq)
    fcmp_s,
    fcmp_d,
    /// x[rd] = raw bits (fmv.x.w sign-extends)
    fmv_x_w,
    fmv_x_d,
    /// f[rd] = x[rs1] | imm (fmv.w.x NaN-boxes); imm = 0, except for fli
    /// (Zfa), which is rs1 = x0 with the constant in imm
    fmv_w_x,
    fmv_d_x,
    /// Anything else: core.exec on `raw` with pc = imm.
    generic,
    /// A 32-bit instruction straddling the page end (always a block of its
    /// own, pc = imm): fetched through the exec TLB on every execution, so
    /// the second page is never cached. `raw` holds the in-page low half.
    straddle,
    // side exits (superblocks): taken -> leave the block at imm, else go on
    beq_x,
    bne_x,
    blt_x,
    bge_x,
    bltu_x,
    bgeu_x,
    /// Direct jump followed inside the block: x[rd] = imm (link); the next
    /// op is the jump target's (pcAt/validate recompute the target from raw).
    jal_c,
    // block terminators (imm = target)
    beq,
    bne,
    blt,
    bge,
    bltu,
    bgeu,
    jal,
    jalr,
    goto,
};

/// One decoded instruction. Integer destination 0 is redirected to slot 32
/// (regs.pc, which is always rewritten before anyone reads it), so ops never
/// need an rd != 0 test.
pub const Op = extern struct {
    h: H,
    rd: u8 = 0,
    rs1: u8 = 0,
    rs2: u8 = 0,
    /// Raw instruction (low 16 bits for compressed); 0 for `goto`.
    raw: u32 = 0,
    imm: u64 = 0,
};

// ---- decoder -----------------------------------------------------------------------

pub const Decoded = struct { op: Op, ends: bool = false };

inline fn xd(r: u32) u8 {
    return if (r == 0) 32 else @intCast(r);
}

/// An op with raw (non-redirected) register numbers.
fn fop(h: H, inst: u32, rd: u32, rs1: u8, rs2: u8, imm: u64) Decoded {
    return .{ .op = .{ .h = h, .rd = @intCast(rd), .rs1 = rs1, .rs2 = rs2, .raw = inst, .imm = imm } };
}

fn generic(inst: u32, pc: u64, ends: bool) Decoded {
    return .{ .op = .{ .h = .generic, .raw = inst, .imm = pc }, .ends = ends };
}

/// Decode one instruction into an op. Only exactly-valid encodings of the
/// hot instructions get a dedicated op; everything else (including every
/// illegal encoding) goes to `generic`, i.e. core.exec, so the semantics
/// stay those of the reference interpreter.
///
/// `isa` is the set of enabled optional extensions (core.Hart.isa). An
/// encoding of an optional extension X gets a dedicated op only under
/// `core.enabled(isa, .x)`; otherwise it goes to `generic`, where core.exec
/// gates it again and raises illegal instruction (see core.Ext).
pub fn decode(inst: u32, pc: u64, isa: u64) Decoded {
    if (inst & 3 != 3) return decodeC(@truncate(inst), pc, isa);
    const rd = (inst >> 7) & 31;
    const f3 = (inst >> 12) & 7;
    const rs1: u8 = @intCast((inst >> 15) & 31);
    const rs2: u8 = @intCast((inst >> 20) & 31);
    const f7 = inst >> 25;
    const R = struct {
        fn op(h: H, i: u32, d: u32, a: u8, b: u8, imm: u64) Decoded {
            return .{ .op = .{ .h = h, .rd = xd(d), .rs1 = a, .rs2 = b, .raw = i, .imm = imm } };
        }
    };
    const iI = core.immI(inst);
    switch (inst & 0x7f) {
        0x37 => return R.op(.li, inst, rd, 0, 0, core.immU(inst)),
        0x17 => return R.op(.li, inst, rd, 0, 0, pc +% core.immU(inst)),
        0x6f => {
            var d = R.op(.jal, inst, rd, 0, 0, pc +% core.immJ(inst));
            d.ends = true;
            return d;
        },
        0x67 => {
            if (f3 != 0) return generic(inst, pc, true);
            var d = R.op(.jalr, inst, rd, rs1, 0, iI);
            d.ends = true;
            return d;
        },
        0x63 => {
            const h: H = switch (f3) {
                0 => .beq,
                1 => .bne,
                4 => .blt,
                5 => .bge,
                6 => .bltu,
                7 => .bgeu,
                else => return generic(inst, pc, true),
            };
            var d = R.op(h, inst, 0, rs1, rs2, pc +% core.immB(inst));
            d.op.rd = 0;
            d.ends = true;
            return d;
        },
        0x03 => {
            const h: H = switch (f3) {
                0 => .lb,
                1 => .lh,
                2 => .lw,
                3 => .ld,
                4 => .lbu,
                5 => .lhu,
                6 => .lwu,
                else => return generic(inst, pc, false),
            };
            return R.op(h, inst, rd, rs1, 0, iI);
        },
        0x23 => {
            const h: H = switch (f3) {
                0 => .sb,
                1 => .sh,
                2 => .sw,
                3 => .sd,
                else => return generic(inst, pc, false),
            };
            var d = R.op(h, inst, 0, rs1, rs2, core.immS(inst));
            d.op.rd = 0;
            return d;
        },
        0x07, 0x27 => {
            const load = inst & 0x20 == 0;
            const h: H = switch (f3) {
                2 => if (load) .flw else .fsw,
                3 => if (load) .fld else .fsd,
                else => return generic(inst, pc, false),
            };
            const d: Decoded = .{ .op = .{
                .h = h,
                .rd = @intCast(rd), // FP register: no x0 redirection
                .rs1 = rs1,
                .rs2 = rs2,
                .raw = inst,
                .imm = if (load) iI else core.immS(inst),
            } };
            return d;
        },
        0x13 => {
            const sh: u64 = (inst >> 20) & 63;
            return switch (f3) {
                0 => R.op(.addi, inst, rd, rs1, 0, iI),
                1 => switch (inst >> 26) {
                    0 => R.op(.slli, inst, rd, rs1, 0, sh),
                    0x0a => if (core.enabled(isa, .zbs)) R.op(.ori, inst, rd, rs1, 0, @as(u64, 1) << @intCast(sh)) else generic(inst, pc, false), // bseti
                    0x12 => if (core.enabled(isa, .zbs)) R.op(.andi, inst, rd, rs1, 0, ~(@as(u64, 1) << @intCast(sh))) else generic(inst, pc, false), // bclri
                    0x1a => if (core.enabled(isa, .zbs)) R.op(.xori, inst, rd, rs1, 0, @as(u64, 1) << @intCast(sh)) else generic(inst, pc, false), // binvi
                    else => switch (inst >> 20) {
                        0x300 => if (core.enabled(isa, .zknd)) R.op(.aes64im, inst, rd, rs1, 0, 0) else generic(inst, pc, false),
                        0x310...0x31a => if (core.enabled(isa, .zkne) or core.enabled(isa, .zknd))
                            R.op(.aes64ks1i, inst, rd, rs1, 0, (inst >> 20) & 0xf)
                        else
                            generic(inst, pc, false),
                        0x600 => if (core.enabled(isa, .zbb)) R.op(.clz, inst, rd, rs1, 0, 0) else generic(inst, pc, false),
                        0x601 => if (core.enabled(isa, .zbb)) R.op(.ctz, inst, rd, rs1, 0, 0) else generic(inst, pc, false),
                        0x602 => if (core.enabled(isa, .zbb)) R.op(.cpop, inst, rd, rs1, 0, std.math.maxInt(u64)) else generic(inst, pc, false),
                        0x604 => if (core.enabled(isa, .zbb)) R.op(.sext, inst, rd, rs1, 0, 56) else generic(inst, pc, false),
                        0x605 => if (core.enabled(isa, .zbb)) R.op(.sext, inst, rd, rs1, 0, 48) else generic(inst, pc, false),
                        else => generic(inst, pc, false),
                    },
                },
                2 => R.op(.slti, inst, rd, rs1, 0, iI),
                3 => R.op(.sltiu, inst, rd, rs1, 0, iI),
                4 => R.op(.xori, inst, rd, rs1, 0, iI),
                5 => switch (inst >> 26) {
                    0 => R.op(.srli, inst, rd, rs1, 0, sh),
                    0x10 => R.op(.srai, inst, rd, rs1, 0, sh),
                    0x18 => if (core.bitmanip.kbOrB(isa)) R.op(.rori, inst, rd, rs1, 0, sh) else generic(inst, pc, false),
                    0x12 => if (core.enabled(isa, .zbs)) R.op(.bext, inst, rd, rs1, 0, sh) else generic(inst, pc, false), // bexti
                    else => switch (inst >> 20) {
                        0x6b8 => if (core.bitmanip.kbOrB(isa)) R.op(.rev8, inst, rd, rs1, 0, 0) else generic(inst, pc, false),
                        0x687 => if (core.enabled(isa, .zbkb)) R.op(.brev8, inst, rd, rs1, 0, 0) else generic(inst, pc, false),
                        0x287 => if (core.enabled(isa, .zbb)) R.op(.orc_b, inst, rd, rs1, 0, 0) else generic(inst, pc, false),
                        else => generic(inst, pc, false),
                    },
                },
                6 => R.op(.ori, inst, rd, rs1, 0, iI),
                7 => R.op(.andi, inst, rd, rs1, 0, iI),
                else => unreachable,
            };
        },
        0x1b => {
            const sh: u64 = (inst >> 20) & 31;
            return switch (f3) {
                0 => R.op(.addiw, inst, rd, rs1, 0, iI),
                1 => if (f7 == 0) R.op(.slliw, inst, rd, rs1, 0, sh) else if (inst >> 26 == 0x02)
                    (if (core.enabled(isa, .zba)) R.op(.shadd, inst, rd, rs1, 0, 64 | ((inst >> 20) & 63)) else generic(inst, pc, false)) // slli.uw
                else switch (inst >> 20) {
                    0x600 => if (core.enabled(isa, .zbb)) R.op(.clz, inst, rd, rs1, 0, 32) else generic(inst, pc, false),
                    0x601 => if (core.enabled(isa, .zbb)) R.op(.ctz, inst, rd, rs1, 0, 1 << 32) else generic(inst, pc, false),
                    0x602 => if (core.enabled(isa, .zbb)) R.op(.cpop, inst, rd, rs1, 0, 0xffff_ffff) else generic(inst, pc, false),
                    else => generic(inst, pc, false),
                },
                5 => switch (f7) {
                    0 => R.op(.srliw, inst, rd, rs1, 0, sh),
                    0x20 => R.op(.sraiw, inst, rd, rs1, 0, sh),
                    0x30 => if (core.bitmanip.kbOrB(isa)) R.op(.roriw, inst, rd, rs1, 0, sh) else generic(inst, pc, false),
                    else => generic(inst, pc, false),
                },
                else => generic(inst, pc, false),
            };
        },
        0x33 => {
            var imm: u64 = 0;
            const h: H = switch (f7) {
                0 => switch (f3) {
                    0 => .add,
                    1 => .sll,
                    2 => .slt,
                    3 => .sltu,
                    4 => .xor_,
                    5 => .srl,
                    6 => .or_,
                    7 => .and_,
                    else => unreachable,
                },
                0x20 => switch (f3) {
                    0 => .sub,
                    5 => .sra,
                    4 => if (core.bitmanip.kbOrB(isa)) .xnor else return generic(inst, pc, false),
                    6 => if (core.bitmanip.kbOrB(isa)) .orn else return generic(inst, pc, false),
                    7 => if (core.bitmanip.kbOrB(isa)) .andn else return generic(inst, pc, false),
                    else => return generic(inst, pc, false),
                },
                0x30 => if (!core.bitmanip.kbOrB(isa)) return generic(inst, pc, false) else switch (f3) {
                    1 => .rol,
                    5 => .ror,
                    else => return generic(inst, pc, false),
                },
                0x04 => if (!core.enabled(isa, .zbkb)) return generic(inst, pc, false) else switch (f3) {
                    4 => .pack,
                    7 => .packh,
                    else => return generic(inst, pc, false),
                },
                0x05 => switch (f3) {
                    1 => if (core.enabled(isa, .zbc) or core.enabled(isa, .zbkc)) .clmul else return generic(inst, pc, false),
                    2 => if (core.enabled(isa, .zbc)) .clmulr else return generic(inst, pc, false),
                    3 => if (core.enabled(isa, .zbc) or core.enabled(isa, .zbkc)) .clmulh else return generic(inst, pc, false),
                    // min, minu, max, maxu (Zbb)
                    4...7 => if (!core.enabled(isa, .zbb)) return generic(inst, pc, false) else blk: {
                        imm = (@as(u64, f3 & 1) << 63) | (f3 >> 1 & 1);
                        break :blk .minmax;
                    },
                    else => return generic(inst, pc, false),
                },
                0x10 => if (core.enabled(isa, .zba) and f3 & 1 == 0 and f3 != 0) blk: { // sh1add, sh2add, sh3add
                    imm = f3 >> 1;
                    break :blk .shadd;
                } else return generic(inst, pc, false),
                0x14 => switch (f3) {
                    1 => if (core.enabled(isa, .zbs)) blk: { // bset
                        imm = 3;
                        break :blk .bitop;
                    } else return generic(inst, pc, false),
                    2 => if (core.enabled(isa, .zbkx)) .xperm4 else return generic(inst, pc, false),
                    4 => if (core.enabled(isa, .zbkx)) .xperm8 else return generic(inst, pc, false),
                    else => return generic(inst, pc, false),
                },
                0x24 => if (!core.enabled(isa, .zbs)) return generic(inst, pc, false) else switch (f3) {
                    1 => blk: { // bclr
                        imm = 1;
                        break :blk .bitop;
                    },
                    5 => .bext,
                    else => return generic(inst, pc, false),
                },
                0x34 => if (f3 == 1 and core.enabled(isa, .zbs)) blk: { // binv
                    imm = 2;
                    break :blk .bitop;
                } else return generic(inst, pc, false),
                0x07 => if (!core.enabled(isa, .zicond)) return generic(inst, pc, false) else switch (f3) {
                    5 => .czero,
                    7 => blk: {
                        imm = 1;
                        break :blk .czero;
                    },
                    else => return generic(inst, pc, false),
                },
                1 => switch (f3) {
                    0 => .mul,
                    1 => .mulh,
                    2 => .mulhsu,
                    3 => .mulhu,
                    4 => .div,
                    5 => .divu,
                    6 => .rem,
                    7 => .remu,
                    else => unreachable,
                },
                0x19, 0x1b => if (f3 == 0 and core.enabled(isa, .zkne)) (if (f7 == 0x19) .aes64es else .aes64esm) else return generic(inst, pc, false),
                0x1d, 0x1f => if (f3 == 0 and core.enabled(isa, .zknd)) (if (f7 == 0x1d) .aes64ds else .aes64dsm) else return generic(inst, pc, false),
                0x3f => if (f3 == 0 and (core.enabled(isa, .zkne) or core.enabled(isa, .zknd))) .aes64ks2 else return generic(inst, pc, false),
                else => return generic(inst, pc, false),
            };
            return R.op(h, inst, rd, rs1, rs2, imm);
        },
        0x3b => {
            var imm: u64 = 0;
            const h: H = switch (f7) {
                0 => switch (f3) {
                    0 => .addw,
                    1 => .sllw,
                    5 => .srlw,
                    else => return generic(inst, pc, false),
                },
                0x20 => switch (f3) {
                    0 => .subw,
                    5 => .sraw,
                    else => return generic(inst, pc, false),
                },
                1 => switch (f3) {
                    0 => .mulw,
                    4 => .divw,
                    5 => .divuw,
                    6 => .remw,
                    7 => .remuw,
                    else => return generic(inst, pc, false),
                },
                0x30 => if (!core.bitmanip.kbOrB(isa)) return generic(inst, pc, false) else switch (f3) {
                    1 => .rolw,
                    5 => .rorw,
                    else => return generic(inst, pc, false),
                },
                0x04 => switch (f3) {
                    // add.uw (Zba)
                    0 => if (core.enabled(isa, .zba)) blk: {
                        imm = 64;
                        break :blk .shadd;
                    } else return generic(inst, pc, false),
                    // packw (Zbkb); with rs2 = x0 also zext.h (Zbb)
                    4 => if (core.enabled(isa, .zbkb) or (rs2 == 0 and core.enabled(isa, .zbb))) .packw else return generic(inst, pc, false),
                    else => return generic(inst, pc, false),
                },
                // sh1add.uw, sh2add.uw, sh3add.uw (Zba)
                0x10 => if (core.enabled(isa, .zba) and f3 & 1 == 0 and f3 != 0) blk: {
                    imm = 64 | (f3 >> 1);
                    break :blk .shadd;
                } else return generic(inst, pc, false),
                else => return generic(inst, pc, false),
            };
            return R.op(h, inst, rd, rs1, rs2, imm);
        },
        // FENCE, FENCE.TSO and PAUSE (Zihintpause) are no-ops on one hart
        // (core.smp: a barrier, in core.exec); FENCE.I is generic.
        0x0f => return if (f3 == 0 and !core.smp) .{ .op = .{ .h = .nop, .raw = inst } } else generic(inst, pc, false),
        0x43, 0x47, 0x4b, 0x4f => { // FMADD FMSUB FNMSUB FNMADD
            if (f3 == 5 or f3 == 6) return generic(inst, pc, false);
            const k = ((inst & 0x7f) - 0x43) >> 2;
            const hs = [4]H{ .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s };
            const hd = [4]H{ .fmadd_d, .fmsub_d, .fnmsub_d, .fnmadd_d };
            const h = switch (f7 & 3) {
                0 => hs[k],
                1 => hd[k],
                else => return generic(inst, pc, false),
            };
            return fop(h, inst, rd, rs1, rs2, f3 | ((inst >> 27) << 8));
        },
        0x53 => {
            const dbl = switch (f7 & 3) {
                0 => false,
                1 => true,
                else => return generic(inst, pc, false),
            };
            const f5 = inst >> 27;
            switch (f5) {
                0, 1, 2, 3 => {
                    if (f3 == 5 or f3 == 6) return generic(inst, pc, false);
                    const hs = [4]H{ .fadd_s, .fsub_s, .fmul_s, .fdiv_s };
                    const hd = [4]H{ .fadd_d, .fsub_d, .fmul_d, .fdiv_d };
                    return fop(if (dbl) hd[f5] else hs[f5], inst, rd, rs1, rs2, f3);
                },
                4 => {
                    if (f3 > 2) return generic(inst, pc, false);
                    return fop(if (dbl) .fsgnj_d else .fsgnj_s, inst, rd, rs1, rs2, f3);
                },
                5 => { // fmin, fmax; fminm, fmaxm (Zfa)
                    if (f3 > 3 or (f3 > 1 and !core.enabled(isa, .zfa))) return generic(inst, pc, false);
                    return fop(if (dbl) .fsgnj_d else .fsgnj_s, inst, rd, rs1, rs2, 4 | f3);
                },
                8 => { // fround, froundnx (Zfa); fcvt.s.d / fcvt.d.s stay generic
                    if ((rs2 != 4 and rs2 != 5) or f3 == 5 or f3 == 6 or !core.enabled(isa, .zfa)) return generic(inst, pc, false);
                    return fop(if (dbl) .fsgnj_d else .fsgnj_s, inst, rd, rs1, 0, (if (rs2 == 5) @as(u64, 24) else 16) | f3);
                },
                0x14 => {
                    if (f3 == 3 or f3 > 5 or (f3 > 2 and !core.enabled(isa, .zfa))) return generic(inst, pc, false);
                    return fop(if (dbl) .fcmp_d else .fcmp_s, inst, xd(rd), rs1, rs2, f3);
                },
                0x1c => {
                    if (rs2 != 0 or f3 != 0) return generic(inst, pc, false);
                    return fop(if (dbl) .fmv_x_d else .fmv_x_w, inst, xd(rd), rs1, 0, 0);
                },
                0x1e => {
                    if (rs2 == 1 and f3 == 0 and core.enabled(isa, .zfa)) // fli
                        return fop(if (dbl) .fmv_d_x else .fmv_w_x, inst, rd, 0, 0, if (dbl) core.fli_d[rs1] else core.fli_s[rs1]);
                    if (rs2 != 0 or f3 != 0) return generic(inst, pc, false);
                    return fop(if (dbl) .fmv_d_x else .fmv_w_x, inst, rd, rs1, 0, 0);
                },
                else => return generic(inst, pc, false),
            }
        },
        // wrs.nto / wrs.sto (Zawrs) are no-ops, mop.r.N / mop.rr.N (Zimop)
        // write 0 to rd. ecall / ebreak end the block (they trap); CSR ops
        // and cbo.* (MISC-MEM, above) do not.
        0x73 => {
            if ((inst == core.wrs_nto or inst == core.wrs_sto) and core.enabled(isa, .zawrs))
                return .{ .op = .{ .h = .nop, .raw = inst } };
            if (core.isMop(inst) and core.enabled(isa, .zimop)) return R.op(.li, inst, rd, 0, 0, 0);
            return generic(inst, pc, f3 == 0);
        },
        else => return generic(inst, pc, false),
    }
}

/// Compressed instructions expand to the ops of their 32-bit forms; Zcb's
/// and Zcmop's (only while enabled) too: c.lbu/c.lhu/c.lh/c.sb/c.sh to the
/// loads and stores, c.mul to mul, c.zext.b/h/w to andi with the mask,
/// c.sext.b/h to sext, c.not to xori -1, c.mop.N to nop.
fn decodeC(i16_: u16, pc: u64, isa: u64) Decoded {
    const i: u32 = i16_;
    const rdp: u8 = @intCast(8 + ((i >> 2) & 7));
    const rs1p: u8 = @intCast(8 + ((i >> 7) & 7));
    const rd: u8 = @intCast((i >> 7) & 31);
    const rs2: u8 = @intCast((i >> 2) & 31);
    const imm6 = core.sext(((i >> 7) & 0x20) | ((i >> 2) & 0x1f), 6);
    const shamt: u64 = ((i >> 7) & 0x20) | ((i >> 2) & 0x1f);
    const O = struct {
        fn op(h: H, raw: u32, d: u8, a: u8, b: u8, imm: u64) Decoded {
            return .{ .op = .{ .h = h, .rd = d, .rs1 = a, .rs2 = b, .raw = raw, .imm = imm } };
        }
        fn end(h: H, raw: u32, d: u8, a: u8, b: u8, imm: u64) Decoded {
            return .{ .op = .{ .h = h, .rd = d, .rs1 = a, .rs2 = b, .raw = raw, .imm = imm }, .ends = true };
        }
    };
    const offW = ((i >> 7) & 0x38) | ((i >> 4) & 4) | ((i << 1) & 0x40);
    switch (((i & 3) << 3) | (i >> 13)) {
        0b00_000 => {
            const imm = ((i >> 7) & 0x30) | ((i >> 1) & 0x3c0) | ((i >> 4) & 0x4) | ((i >> 2) & 0x8);
            if (imm == 0) return generic(i, pc, false);
            return O.op(.addi, i, rdp, 2, 0, imm);
        },
        0b00_001 => return O.op(.fld, i, rdp, rs1p, 0, core.offD(i)),
        0b00_010 => return O.op(.lw, i, rdp, rs1p, 0, offW),
        0b00_011 => return O.op(.ld, i, rdp, rs1p, 0, core.offD(i)),
        0b00_100 => { // Zcb loads and stores
            if (!core.enabled(isa, .zcb)) return generic(i, pc, false);
            return switch ((i >> 10) & 7) {
                0 => O.op(.lbu, i, rdp, rs1p, 0, core.zcbOffB(i)),
                1 => O.op(if (i & 0x40 == 0) .lhu else .lh, i, rdp, rs1p, 0, core.zcbOffH(i)),
                2 => O.op(.sb, i, 0, rs1p, rdp, core.zcbOffB(i)),
                3 => if (i & 0x40 == 0) O.op(.sh, i, 0, rs1p, rdp, core.zcbOffH(i)) else generic(i, pc, false),
                else => generic(i, pc, false),
            };
        },
        0b00_101 => return O.op(.fsd, i, 0, rs1p, rdp, core.offD(i)),
        0b00_110 => return O.op(.sw, i, 0, rs1p, rdp, offW),
        0b00_111 => return O.op(.sd, i, 0, rs1p, rdp, core.offD(i)),
        0b01_000 => return O.op(.addi, i, xd(rd), rd, 0, imm6),
        0b01_001 => {
            if (rd == 0) return generic(i, pc, false);
            return O.op(.addiw, i, rd, rd, 0, imm6);
        },
        0b01_010 => return O.op(.li, i, xd(rd), 0, 0, imm6),
        0b01_011 => {
            if (rd == 2) {
                const v = ((i >> 3) & 0x200) | ((i >> 2) & 0x10) | ((i << 1) & 0x40) | ((i << 4) & 0x180) | ((i << 3) & 0x20);
                if (v == 0) return generic(i, pc, false);
                return O.op(.addi, i, 2, 2, 0, core.sext(v, 10));
            }
            if (imm6 == 0) {
                if (core.isCMop(i) and core.enabled(isa, .zcmop)) return .{ .op = .{ .h = .nop, .raw = i } };
                return generic(i, pc, false);
            }
            return O.op(.li, i, xd(rd), 0, 0, imm6 << 12);
        },
        0b01_100 => return switch ((i >> 10) & 3) {
            0 => O.op(.srli, i, rs1p, rs1p, 0, shamt),
            1 => O.op(.srai, i, rs1p, rs1p, 0, shamt),
            2 => O.op(.andi, i, rs1p, rs1p, 0, imm6),
            3 => if (i & (1 << 12) == 0) switch ((i >> 5) & 3) {
                0 => O.op(.sub, i, rs1p, rs1p, rdp, 0),
                1 => O.op(.xor_, i, rs1p, rs1p, rdp, 0),
                2 => O.op(.or_, i, rs1p, rs1p, rdp, 0),
                3 => O.op(.and_, i, rs1p, rs1p, rdp, 0),
                else => unreachable,
            } else switch ((i >> 5) & 3) {
                0 => O.op(.subw, i, rs1p, rs1p, rdp, 0),
                1 => O.op(.addw, i, rs1p, rs1p, rdp, 0),
                2 => if (core.enabled(isa, .zcb)) O.op(.mul, i, rs1p, rs1p, rdp, 0) else generic(i, pc, false),
                else => if (!core.enabled(isa, .zcb)) generic(i, pc, false) else switch ((i >> 2) & 7) {
                    0 => O.op(.andi, i, rs1p, rs1p, 0, 0xff), // c.zext.b
                    1 => if (core.enabled(isa, .zbb)) O.op(.sext, i, rs1p, rs1p, 0, 56) else generic(i, pc, false), // c.sext.b
                    2 => if (core.enabled(isa, .zbb)) O.op(.andi, i, rs1p, rs1p, 0, 0xffff) else generic(i, pc, false), // c.zext.h
                    3 => if (core.enabled(isa, .zbb)) O.op(.sext, i, rs1p, rs1p, 0, 48) else generic(i, pc, false), // c.sext.h
                    4 => if (core.enabled(isa, .zba)) O.op(.andi, i, rs1p, rs1p, 0, 0xffff_ffff) else generic(i, pc, false), // c.zext.w
                    5 => O.op(.xori, i, rs1p, rs1p, 0, std.math.maxInt(u64)), // c.not
                    else => generic(i, pc, false),
                },
            },
            else => unreachable,
        },
        0b01_101 => {
            const off = ((i >> 1) & 0x800) | ((i >> 7) & 0x10) | ((i >> 1) & 0x300) | ((i << 2) & 0x400) |
                ((i >> 1) & 0x40) | ((i << 1) & 0x80) | ((i >> 2) & 0xe) | ((i << 3) & 0x20);
            return O.end(.jal, i, 32, 0, 0, pc +% core.sext(off, 12));
        },
        0b01_110, 0b01_111 => {
            const off = ((i >> 4) & 0x100) | ((i >> 7) & 0x18) | ((i << 1) & 0xc0) | ((i >> 2) & 0x6) | ((i << 3) & 0x20);
            return O.end(if (i >> 13 == 0b110) .beq else .bne, i, 0, rs1p, 0, pc +% core.sext(off, 9));
        },
        0b10_000 => return O.op(.slli, i, xd(rd), rd, 0, shamt),
        0b10_001 => return O.op(.fld, i, rd, 2, 0, core.offLdsp(i)),
        0b10_010 => {
            if (rd == 0) return generic(i, pc, false);
            return O.op(.lw, i, rd, 2, 0, ((i >> 7) & 0x20) | ((i >> 2) & 0x1c) | ((i << 4) & 0xc0));
        },
        0b10_011 => {
            if (rd == 0) return generic(i, pc, false);
            return O.op(.ld, i, rd, 2, 0, core.offLdsp(i));
        },
        0b10_100 => {
            if (i & (1 << 12) == 0) {
                if (rs2 == 0) {
                    if (rd == 0) return generic(i, pc, false);
                    return O.end(.jalr, i, 32, rd, 0, 0); // C.JR
                }
                return O.op(.add, i, xd(rd), 0, rs2, 0); // C.MV
            }
            if (rs2 == 0) {
                if (rd == 0) return generic(i, pc, true); // C.EBREAK
                return O.end(.jalr, i, 1, rd, 0, 0); // C.JALR
            }
            return O.op(.add, i, xd(rd), rd, rs2, 0); // C.ADD (rd = 0: a HINT, e.g. c.ntl.*)
        },
        0b10_101 => return O.op(.fsd, i, 0, 2, rs2, core.offSdsp(i)),
        0b10_110 => return O.op(.sw, i, 0, 2, rs2, ((i >> 7) & 0x3c) | ((i >> 1) & 0xc0)),
        0b10_111 => return O.op(.sd, i, 0, 2, rs2, core.offSdsp(i)),
        else => return generic(i, pc, false),
    }
}

/// The side-exit form of a terminating conditional branch, or null.
pub fn sideExit(h: H) ?H {
    return switch (h) {
        .beq => .beq_x,
        .bne => .bne_x,
        .blt => .blt_x,
        .bge => .bge_x,
        .bltu => .bltu_x,
        .bgeu => .bgeu_x,
        else => null,
    };
}

/// Target of a direct jump (JAL or C.J) at pc.
pub fn jalTarget(raw: u32, pc: u64) u64 {
    if (raw & 3 == 3) return pc +% core.immJ(raw);
    const i = raw;
    const off = ((i >> 1) & 0x800) | ((i >> 7) & 0x10) | ((i >> 1) & 0x300) | ((i << 2) & 0x400) |
        ((i >> 1) & 0x40) | ((i << 1) & 0x80) | ((i >> 2) & 0xe) | ((i << 3) & 0x20);
    return pc +% core.sext(off, 12);
}

// ---- op semantics --------------------------------------------------------------------

/// How an op left the block.
pub const Next = enum(u8) {
    /// Continue with the next op.
    cont,
    /// The block's terminator ran; pc is set.
    done,
    /// This op faulted (no effect; earlier ops retired).
    fault,
    /// This (generic) op trapped; pc is on it.
    trap,
    /// This op retired and the block must stop after it (a store hit
    /// decoded code, FENCE.I).
    stop,
    /// This (generic) op jumped; pc is set.
    jumped,
    /// This (generic) op is a cycle/time/instret read; the caller supplies
    /// the count (core.finishCounter) and resumes after it.
    counter,
    /// This side-exit branch was taken; pc is set.
    side,
};

noinline fn execStraddle(cpu: *Cpu, regs: *Regs, pc: u64) Next {
    const inst = cpu.fetch(pc) catch return .fault;
    return execGeneric(cpu, regs, inst, pc);
}

noinline fn execGeneric(cpu: *Cpu, regs: *Regs, raw: u32, pc: u64) Next {
    kwemu.count(cpu, "generic_ops", 1);
    regs.pc = pc;
    const e = core.Interp(Cpu).exec(regs, &cpu.priv.hart, cpu, raw) catch return .fault;
    return switch (e) {
        .next => if (cpu.priv.smc != 0) .stop else .cont,
        .jump => .jumped,
        .trap => if (cpu.priv.hart.trap == .counter) .counter else .trap,
    };
}

inline fn fget(comptime B: type, v: u64) B {
    return if (B == u32) core.unbox(v) else v;
}
inline fn fbox(comptime B: type, v: B) u64 {
    return if (B == u32) core.box(v) else v;
}

/// Register slot whose index is the byte of `w` at bit `pos` (8 = rd,
/// 16 = rs1, 24 = rs2), relative to `base`. Computes index*8 straight from
/// the op word (one shift + mask).
inline fn slot(base: [*]u64, w: u64, comptime pos: u6) *u64 {
    const off: usize = @intCast((w >> (pos - 3)) & (0xff << 3));
    return @ptrFromInt(@intFromPtr(base) + off);
}

/// Execute op `o` (handler `h`, comptime; `w` is its first 8 bytes). `x` is
/// regs.x; x[32] is regs.pc and the FP registers start at x[33]. `end_pc` is
/// the block's fall-through.
pub inline fn doOp(comptime h: H, w: u64, o: [*]const Op, x: [*]u64, cpu: *Cpu, end_pc: u64) Next {
    const f = x + 33;
    const rd = slot(x, w, 8);
    const rs1 = slot(x, w, 16).*;
    const rs2 = slot(x, w, 24).*;
    const imm = o[0].imm;
    switch (h) {
        .addi, .addiw, .andi, .ori, .xori, .slti, .sltiu, .slli, .srli, .srai, .slliw, .srliw, .sraiw => {
            const a = rs1;
            rd.* = switch (h) {
                .addi => a +% imm,
                .addiw => core.sx32(core.lo32(a) +% core.lo32(imm)),
                .andi => a & imm,
                .ori => a | imm,
                .xori => a ^ imm,
                .slti => @intFromBool(core.sgn(a) < core.sgn(imm)),
                .sltiu => @intFromBool(a < imm),
                .slli => a << @as(u6, @truncate(imm)),
                .srli => a >> @as(u6, @truncate(imm)),
                .srai => core.uns(core.sgn(a) >> @as(u6, @truncate(imm))),
                .slliw => core.sx32(core.lo32(a) << @as(u5, @truncate(imm))),
                .srliw => core.sx32(core.lo32(a) >> @as(u5, @truncate(imm))),
                .sraiw => core.sx32(@bitCast(@as(i32, @bitCast(core.lo32(a))) >> @as(u5, @truncate(imm)))),
                else => comptime unreachable,
            };
            return .cont;
        },
        .li => {
            rd.* = imm;
            return .cont;
        },
        .nop => return .cont,
        .add, .sub, .and_, .or_, .xor_, .sll, .srl, .sra, .slt, .sltu, .addw, .subw, .sllw, .srlw, .sraw, .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu, .mulw, .divw, .divuw, .remw, .remuw => {
            const a = rs1;
            const b = rs2;
            const a32 = core.lo32(a);
            const b32 = core.lo32(b);
            rd.* = switch (h) {
                .add => a +% b,
                .sub => a -% b,
                .and_ => a & b,
                .or_ => a | b,
                .xor_ => a ^ b,
                .sll => a << @as(u6, @truncate(b)),
                .srl => a >> @as(u6, @truncate(b)),
                .sra => core.uns(core.sgn(a) >> @as(u6, @truncate(b))),
                .slt => @intFromBool(core.sgn(a) < core.sgn(b)),
                .sltu => @intFromBool(a < b),
                .addw => core.sx32(a32 +% b32),
                .subw => core.sx32(a32 -% b32),
                .sllw => core.sx32(a32 << @as(u5, @truncate(b32))),
                .srlw => core.sx32(a32 >> @as(u5, @truncate(b32))),
                .sraw => core.sx32(@bitCast(@as(i32, @bitCast(a32)) >> @as(u5, @truncate(b32)))),
                .mul => a *% b,
                .mulh => core.fpu.mulh(a, b),
                .mulhsu => core.fpu.mulhsu(a, b),
                .mulhu => core.fpu.mul64(a, b).hi,
                .div => core.uns(core.divs(core.sgn(a), core.sgn(b))),
                .divu => if (b == 0) std.math.maxInt(u64) else a / b,
                .rem => core.uns(core.rems(core.sgn(a), core.sgn(b))),
                .remu => if (b == 0) a else a % b,
                .mulw => core.sx32(a32 *% b32),
                .divw => core.sx32(@bitCast(core.divs32(@bitCast(a32), @bitCast(b32)))),
                .divuw => core.sx32(if (b32 == 0) std.math.maxInt(u32) else a32 / b32),
                .remw => core.sx32(@bitCast(core.rems32(@bitCast(a32), @bitCast(b32)))),
                .remuw => core.sx32(if (b32 == 0) a32 else a32 % b32),
                else => comptime unreachable,
            };
            return .cont;
        },
        .aes64es, .aes64esm, .aes64ds, .aes64dsm, .aes64ks2, .aes64im, .aes64ks1i => {
            const A = core.aes;
            rd.* = switch (h) {
                .aes64es => A.es(rs1, rs2),
                .aes64esm => A.esm(rs1, rs2),
                .aes64ds => A.ds(rs1, rs2),
                .aes64dsm => A.dsm(rs1, rs2),
                .aes64ks2 => A.ks2(rs1, rs2),
                .aes64im => A.im(rs1),
                .aes64ks1i => A.ks1i(rs1, @truncate(imm)),
                else => comptime unreachable,
            };
            return .cont;
        },
        .andn, .orn, .xnor, .rol, .ror, .rolw, .rorw, .pack, .packh, .packw, .clmul, .clmulh, .clmulr, .xperm4, .xperm8, .rori, .roriw, .rev8, .brev8 => {
            const B = core.bitmanip;
            rd.* = switch (h) {
                .andn => rs1 & ~rs2,
                .orn => rs1 | ~rs2,
                .xnor => ~(rs1 ^ rs2),
                .rol => std.math.rotl(u64, rs1, @as(u6, @truncate(rs2))),
                .ror => std.math.rotr(u64, rs1, @as(u6, @truncate(rs2))),
                .rolw => B.rolw(rs1, rs2),
                .rorw => B.rorw(rs1, rs2),
                .pack => B.pack(rs1, rs2),
                .packh => B.packh(rs1, rs2),
                .packw => B.packw(rs1, rs2),
                .clmul => B.clmul(rs1, rs2),
                .clmulh => B.clmulh(rs1, rs2),
                .clmulr => B.clmulr(rs1, rs2),
                .xperm4 => B.xperm4(rs1, rs2),
                .xperm8 => B.xperm8(rs1, rs2),
                .rori => std.math.rotr(u64, rs1, @as(u6, @truncate(imm))),
                .roriw => B.rorw(rs1, imm),
                .rev8 => B.rev8(rs1),
                .brev8 => B.brev8(rs1),
                else => comptime unreachable,
            };
            return .cont;
        },
        .shadd, .clz, .ctz, .cpop, .minmax, .sext, .orc_b, .bitop, .bext, .czero => {
            const B = core.bitmanip;
            const s: u6 = @truncate(imm);
            rd.* = switch (h) {
                .shadd => ((rs1 & (@as(u64, std.math.maxInt(u64)) >> @as(u6, @truncate((imm >> 1) & 32)))) << s) +% rs2,
                .clz => @clz((rs1 << s) | ((@as(u64, 1) << s) - 1)),
                .ctz => @ctz(rs1 | imm),
                .cpop => @popCount(rs1 & imm),
                .minmax => blk: {
                    const bias = imm & (1 << 63);
                    const lt = core.sgn(rs1 ^ bias) < core.sgn(rs2 ^ bias);
                    break :blk if (lt != (imm & 1 != 0)) rs1 else rs2;
                },
                .sext => core.uns(core.sgn(rs1 << s) >> s),
                .orc_b => B.orcb(rs1),
                .bitop => blk: {
                    const m = @as(u64, 1) << @as(u6, @truncate(rs2));
                    break :blk (rs1 & ~(m & (0 -% (imm & 1)))) ^ (m & (0 -% (imm >> 1 & 1)));
                },
                .bext => B.bext(rs1, rs2 +% imm),
                .czero => if ((rs2 == 0) != (imm != 0)) 0 else rs1,
                else => comptime unreachable,
            };
            return .cont;
        },
        .lb, .lh, .lw, .ld, .lbu, .lhu, .lwu, .flw, .fld => {
            const va = rs1 +% imm;
            const T = switch (h) {
                .lb, .lbu => u8,
                .lh, .lhu => u16,
                .lw, .lwu, .flw => u32,
                .ld, .fld => u64,
                else => comptime unreachable,
            };
            const v = cpu.load(T, va) catch return .fault;
            switch (h) {
                .lb => rd.* = core.sext(v, 8),
                .lh => rd.* = core.sext(v, 16),
                .lw => rd.* = core.sx32(v),
                .flw => slot(f, w, 8).* = core.box(v),
                .fld => slot(f, w, 8).* = v,
                else => rd.* = v,
            }
            return .cont;
        },
        .sb, .sh, .sw, .sd, .fsw, .fsd => {
            const va = rs1 +% imm;
            const fs2 = slot(f, w, 24).*;
            const smc = switch (h) {
                .sb => cpu.storeChk(u8, va, @truncate(rs2)),
                .sh => cpu.storeChk(u16, va, @truncate(rs2)),
                .sw => cpu.storeChk(u32, va, @truncate(rs2)),
                .sd => cpu.storeChk(u64, va, rs2),
                .fsw => cpu.storeChk(u32, va, @truncate(fs2)),
                .fsd => cpu.storeChk(u64, va, fs2),
                else => comptime unreachable,
            } catch return .fault;
            return if (smc) .stop else .cont;
        },
        .generic => return execGeneric(cpu, @ptrCast(x), @truncate(w >> 32), imm),
        .straddle => return execStraddle(cpu, @ptrCast(x), imm),
        .fadd_s, .fsub_s, .fmul_s, .fdiv_s, .fadd_d, .fsub_d, .fmul_d, .fdiv_d, .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s, .fmadd_d, .fmsub_d, .fnmsub_d, .fnmadd_d => {
            const B = switch (h) {
                .fadd_s, .fsub_s, .fmul_s, .fdiv_s, .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s => u32,
                else => u64,
            };
            const F = core.fpu.Fmt(B);
            const fcsr: *u32 = @ptrCast(x + 65);
            const st: u32 = @truncate(imm & 7);
            const rm = if (st == 7) (fcsr.* >> 5) & 7 else st;
            if (rm > 4) return execGeneric(cpu, @ptrCast(x), @truncate(w >> 32), 0); // illegal: let core report it
            var a = fget(B, slot(f, w, 16).*);
            const b = fget(B, slot(f, w, 24).*);
            var fl: u32 = 0;
            const v = switch (h) {
                .fadd_s, .fadd_d => F.add(a, b, rm, &fl),
                .fsub_s, .fsub_d => F.sub(a, b, rm, &fl),
                .fmul_s, .fmul_d => F.mul(a, b, rm, &fl),
                .fdiv_s, .fdiv_d => F.div(a, b, rm, &fl),
                else => blk: {
                    var cc = fget(B, f[@intCast((imm >> 8) & 31)]);
                    switch (h) {
                        .fmadd_s, .fmadd_d => {},
                        .fmsub_s, .fmsub_d => cc ^= F.sign,
                        .fnmsub_s, .fnmsub_d => a ^= F.sign,
                        else => {
                            a ^= F.sign;
                            cc ^= F.sign;
                        },
                    }
                    break :blk F.fma(a, b, cc, rm, &fl);
                },
            };
            slot(f, w, 8).* = fbox(B, v);
            fcsr.* |= fl;
            return .cont;
        },
        .fsgnj_s, .fsgnj_d => {
            const B = if (h == .fsgnj_s) u32 else u64;
            const F = core.fpu.Fmt(B);
            const a = fget(B, slot(f, w, 16).*);
            const b = fget(B, slot(f, w, 24).*);
            if (imm < 4) {
                const sg = switch (imm) {
                    0 => b & F.sign,
                    1 => ~b & F.sign,
                    else => (a ^ b) & F.sign,
                };
                slot(f, w, 8).* = fbox(B, (a & ~F.sign) | sg);
                return .cont;
            }
            const fcsr: *u32 = @ptrCast(x + 65);
            var fl: u32 = 0;
            const v = if (imm < 8) switch (imm & 3) {
                0 => F.min(a, b, &fl),
                1 => F.max(a, b, &fl),
                2 => F.minm(a, b, &fl),
                else => F.maxm(a, b, &fl),
            } else blk: {
                const st: u32 = @truncate(imm & 7);
                const rm = if (st == 7) (fcsr.* >> 5) & 7 else st;
                if (rm > 4) return execGeneric(cpu, @ptrCast(x), @truncate(w >> 32), 0); // illegal frm
                break :blk F.roundInt(a, rm, imm & 8 != 0, &fl);
            };
            slot(f, w, 8).* = fbox(B, v);
            fcsr.* |= fl;
            return .cont;
        },
        .fcmp_s, .fcmp_d => {
            const B = if (h == .fcmp_s) u32 else u64;
            const F = core.fpu.Fmt(B);
            const a = fget(B, slot(f, w, 16).*);
            const b = fget(B, slot(f, w, 24).*);
            var fl: u32 = 0;
            rd.* = @intFromBool(switch (imm) {
                2 => F.eq(a, b, &fl),
                1 => F.lt(a, b, &fl),
                0 => F.le(a, b, &fl),
                4 => F.leq(a, b, &fl),
                else => F.ltq(a, b, &fl),
            });
            @as(*u32, @ptrCast(x + 65)).* |= fl;
            return .cont;
        },
        .fmv_x_w => {
            rd.* = core.sx32(@truncate(slot(f, w, 16).*));
            return .cont;
        },
        .fmv_x_d => {
            rd.* = slot(f, w, 16).*;
            return .cont;
        },
        .fmv_w_x => {
            slot(f, w, 8).* = core.box(@truncate(rs1)) | imm;
            return .cont;
        },
        .fmv_d_x => {
            slot(f, w, 8).* = rs1 | imm;
            return .cont;
        },
        .beq, .bne, .blt, .bge, .bltu, .bgeu, .beq_x, .bne_x, .blt_x, .bge_x, .bltu_x, .bgeu_x => {
            const a = rs1;
            const b = rs2;
            const taken = switch (h) {
                .beq, .beq_x => a == b,
                .bne, .bne_x => a != b,
                .blt, .blt_x => core.sgn(a) < core.sgn(b),
                .bge, .bge_x => core.sgn(a) >= core.sgn(b),
                .bltu, .bltu_x => a < b,
                .bgeu, .bgeu_x => a >= b,
                else => comptime unreachable,
            };
            switch (h) {
                .beq, .bne, .blt, .bge, .bltu, .bgeu => {
                    x[32] = if (taken) imm else end_pc;
                    return .done;
                },
                else => {
                    if (!taken) return .cont;
                    x[32] = imm;
                    return .side;
                },
            }
        },
        .jal_c => {
            rd.* = imm;
            return .cont;
        },
        .jal => {
            rd.* = end_pc;
            x[32] = imm;
            return .done;
        },
        .jalr => {
            const t = (rs1 +% imm) & ~@as(u64, 1);
            rd.* = end_pc;
            x[32] = t;
            return .done;
        },
        .goto => {
            x[32] = imm;
            return .done;
        },
    }
}

// ---- dispatchers ---------------------------------------------------------------------

pub const Exit = struct { next: Next, op: [*]const Op };

/// The first 8 bytes of an op (h, rd, rs1, rs2, raw) in one load.
inline fn word(o: [*]const Op) u64 {
    return @as(*const u64, @ptrCast(o)).*;
}

/// Run the ops starting at `o` until one does not return .cont.
pub inline fn runOps(o0: [*]const Op, x: [*]u64, cpu: *Cpu, end_pc: u64) Exit {
    if (tail_call) {
        const r = table[@intFromEnum(o0[0].h)](o0, x, cpu, end_pc);
        return .{ .next = @enumFromInt(r & 7), .op = @ptrFromInt(r & ~@as(usize, 7)) };
    }
    @setEvalBranchQuota(5000); // the comptime switches of ~140 inlined handlers
    var o = o0;
    var w = word(o);
    // One central dispatch (a plain loop around the switch). The threaded
    // form (`continue :sw` per handler) made LLVM emit a br_table per handler
    // and a 7x larger `run`, which V8 runs much slower on cold code.
    while (true) {
        switch (@as(H, @enumFromInt(@as(u8, @truncate(w))))) {
            inline else => |h| {
                if (kwemu.stats_on) cpu.priv.stats.op_hist[@intFromEnum(h)] += 1;
                const r = doOp(h, w, o, x, cpu, end_pc);
                if (r != .cont) return .{ .next = r, .op = o };
                o += 1;
                w = word(o);
            },
        }
    }
}

/// Tail-call threading: each op is a function that ends by tail-calling the
/// next op's handler; the chain returns `op address | Next` (ops are
/// 8-byte aligned).
const Handler = *const fn (o: [*]const Op, x: [*]u64, cpu: *Cpu, end_pc: u64) callconv(.c) usize;

fn handler(comptime h: H) Handler {
    return &struct {
        fn f(o: [*]const Op, x: [*]u64, cpu: *Cpu, end_pc: u64) callconv(.c) usize {
            const r = doOp(h, word(o), o, x, cpu, end_pc);
            if (r == .cont) return @call(.always_tail, table[@intFromEnum(o[1].h)], .{ o + 1, x, cpu, end_pc });
            return @intFromPtr(o) | @intFromEnum(r);
        }
    }.f;
}

const table: [@typeInfo(H).@"enum".field_names.len]Handler = blk: {
    var t: [@typeInfo(H).@"enum".field_names.len]Handler = undefined;
    for (@typeInfo(H).@"enum".field_values) |v| t[v] = handler(@enumFromInt(v));
    break :blk t;
};

comptime {
    std.debug.assert(@sizeOf(Op) == 16 and @alignOf(Op) == 8);
    std.debug.assert(builtin.cpu.arch.endian() == .little); // word() field layout
    std.debug.assert(@typeInfo(H).@"enum".field_names.len <= @typeInfo(@FieldType(kwemu.Stats, "op_hist")).array.len);
    std.debug.assert(@typeInfo(Next).@"enum".field_names.len <= 8); // packed into an 8-aligned op address
}
