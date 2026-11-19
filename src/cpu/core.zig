// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! RV64GC user-mode interpreter core (decode-and-switch). The kwemu
//! library (src/emu) uses it as its reference and slow-path interpreter.
//!
//! ISA: RV64I, M, A (LR/SC + all AMOs), F, D (all rounding modes and flags,
//! see fpu.zig), C (incl. C.FLD/C.FSD/C.FLDSP/C.FSDSP), Zicsr (fflags, frm,
//! fcsr; cycle/time/instret all read the retired-instruction count, which
//! is Zicntr), Zifencei. Hints run as no-ops: PAUSE (Zihintpause), the
//! NTL hints `add x0, x0, x2..x5` and `c.add x0, x2..x5` (Zihintntl), and
//! `prefetch.{i,r,w}` = `ori x0` (Zicbop).
//!
//! Optional extensions (`Ext`, the KW_ISA_* bits of include/kw_emu.h) are
//! decoded only when this build implements them (`implemented`) and the
//! kernel enabled them (kw_set_isa, `Hart.isa`); otherwise their encodings
//! raise illegal instruction exactly like any other unknown encoding. See
//! `Ext` for how to add one. Implemented: Zkne and Zknd (RV64 scalar AES:
//! aes64es, aes64esm, aes64ds, aes64dsm, aes64im, aes64ks1i, aes64ks2; see
//! `aes`), the bit-manipulation extensions Zba (sh1add, sh2add, sh3add,
//! add.uw, sh1add.uw, sh2add.uw, sh3add.uw, slli.uw), Zbb (andn, orn, xnor,
//! clz, clzw, ctz, ctzw, cpop, cpopw, max, maxu, min, minu, sext.b, sext.h,
//! zext.h, rol, rolw, ror, rori, roriw, rorw, orc.b, rev8), Zbc (clmul,
//! clmulh, clmulr), Zbs (bclr, bclri, bext, bexti, binv, binvi, bset,
//! bseti), Zbkb (pack, packh, packw, brev8 and the ones it shares with
//! Zbb), Zbkc (clmul, clmulh) and Zbkx (xperm4, xperm8), see `bitmanip`;
//! Zicond (czero.eqz, czero.nez); and of RVA23U64: Zcb (c.lbu, c.lhu,
//! c.lh, c.sb, c.sh, c.mul, c.zext.b/h/w, c.sext.b/h, c.not), Zimop
//! (mop.r.N, mop.rr.N) and Zcmop (c.mop.N), see `isMop`; Zicbom (cbo.clean,
//! cbo.flush) and Zicboz (cbo.zero), see `Interp.cbo`; Zawrs (wrs.nto,
//! wrs.sto, no-ops); Zfa for F and D (fli, fminm, fmaxm, fround, froundnx,
//! fcvtmod.w.d, fleq, fltq; see `fli_s`/`fli_d` and fpu.zig); Zfhmin
//! (flh, fsh, fmv.x.h, fmv.h.x, fcvt.s.h, fcvt.h.s, fcvt.d.h, fcvt.h.d;
//! halves NaN-boxed in 64 bits, see `boxH`, `opFpH`); Zihpm (hpmcounter3
//! ..hpmcounter31 read 0, see `csrOp`). Not Zkt: the AES instructions look
//! the S-box up by data.
//!
//! The core is generic over the memory type `M`, which must provide
//!   load(comptime T, va) Error!T, store(comptime T, va, T) Error!void,
//!   fetch(va) Error!u32 (low 16 bits only valid for compressed parcels),
//!   rmwPtr(comptime T, va) Error!*align(1) T  (write permission, in-page)
//! and record the fault address/access itself before returning
//! error.PageFault. A faulting instruction has no architectural effect.
//! Optionally `fenceI()`, called for FENCE.I. kwemu's block cache
//! (src/emu/kwemu.zig) runs the common instructions itself and calls
//! `exec` for the rest.

const std = @import("std");
const builtin = @import("builtin");
pub const fpu = @import("fpu.zig");

/// Several harts share the memory (a wasm build with atomics, for an SMP
/// kernel: zig build -Dkwemu-atomics): AMOs are atomic read-modify-writes,
/// SC is a compare-and-swap against the value LR read, and FENCE is a full
/// barrier. Otherwise one hart owns the memory and plain accesses suffice.
pub const smp = builtin.cpu.arch.isWasm() and std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);
const F32 = fpu.F32;
const F64 = fpu.F64;

/// Guest registers; identical layout to `struct kw_regs` in include/kw_emu.h.
pub const Regs = extern struct {
    x: [32]u64 = @splat(0),
    pc: u64 = 0,
    f: [32]u64 = @splat(0),
    fcsr: u32 = 0,
    _pad: u32 = 0,
};

/// Values match `enum kw_event_kind`.
pub const Kind = enum(u32) {
    budget = 0,
    syscall = 1,
    fault = 2,
    illegal = 3,
    breakpoint = 4,
    misaligned = 5,
    interrupt = 6,
    /// Internal (never reported to the kernel): a cycle/time/instret CSR
    /// read; the run loop supplies the count with finishCounter().
    counter = 0x100,
};

/// Values match `enum kw_access`.
pub const Access = enum(u32) { read = 0, write = 1, exec = 2 };

pub const Error = error{PageFault};

pub const no_resv: u64 = std.math.maxInt(u64);

// ---- optional extensions -----------------------------------------------------
//
// One bit per extension kwemu may implement beyond RV64GC; the values are
// the KW_ISA_* bits of include/kw_emu.h (kwemu.zig checks them). To add an
// extension X:
//   1. core.exec: decode X's encodings behind `has(h, .x)`, falling through
//      to `ill(h, inst)` when it is false, e.g.
//          0x33 => ... 0x05 => if (has(h, .zbc)) clmul(a, b) else return ill(h, inst),
//   2. exec.decode: give an encoding of X a dedicated op only when
//      `enabled(isa, .x)`; otherwise (and for anything X does not make hot)
//      return `generic`, which runs core.exec and so applies step 1's gate;
//   3. jit.zig: translate only X's dedicated ops (they exist only while X is
//      enabled), never X's encodings inside `generic` ops;
//   4. add .x to `implemented`, and probes to the tests (kwemu_test.zig
//      `isa_probes`, kwtest.c `isa_exts`).
// The kernel advertises an extension (cpuinfo, riscv_hwprobe) only when
// kw_set_isa() reports it enabled, so step 4 is what makes user space see it.
// An instruction that several extensions define is legal when any of them
// is enabled, and is gated on all of them from the start (an unimplemented
// one folds to false), e.g. aes64ks2 (Zkne or Zknd), clmul (Zbc or Zbkc),
// and the instructions Zbkb shares with Zbb (`bitmanip.kbOrB`). Adding the
// second extension then means adding only the instructions it alone has.

pub const Ext = enum(u6) {
    zba = 0,
    zbb = 1,
    zbc = 2,
    zbs = 3,
    zbkb = 4,
    zbkc = 5,
    zbkx = 6,
    zknd = 7,
    zkne = 8,
    zicond = 9,
    zcb = 10,
    zimop = 11,
    zcmop = 12,
    zicbom = 13,
    zicboz = 14,
    zawrs = 15,
    zfa = 16,
    zfhmin = 17,
    zihpm = 18,
    // bits 19..63: free for further extensions
};

pub inline fn bit(e: Ext) u64 {
    return @as(u64, 1) << @intFromEnum(e);
}

/// The optional extensions this build implements (kw_isa_supported()).
pub const implemented: u64 = bit(.zba) | bit(.zbb) | bit(.zbc) | bit(.zbs) | bit(.zbkb) | bit(.zbkc) | bit(.zbkx) | bit(.zknd) | bit(.zkne) | bit(.zicond) |
    bit(.zcb) | bit(.zimop) | bit(.zcmop) | bit(.zicbom) | bit(.zicboz) | bit(.zawrs) | bit(.zfa) | bit(.zfhmin) | bit(.zihpm);

/// Whether extension `e` is implemented and enabled in `isa` (a set of
/// `bit`s). Folds to `false` at compile time for an unimplemented one.
pub inline fn enabled(isa: u64, comptime e: Ext) bool {
    return implemented & bit(e) != 0 and isa & bit(e) != 0;
}

/// Non-register hart state (lives inside the opaque part of kw_cpu).
pub const Hart = extern struct {
    /// LR/SC reservation (virtual address), or no_resv.
    resv: u64 = no_resv,
    /// Valid when step() returned .trap: syscall/illegal/breakpoint/misaligned.
    trap: Kind = .budget,
    _pad: u32 = 0,
    /// Raw instruction for .illegal, address for .misaligned.
    trap_val: u64 = 0,
    /// Enabled optional extensions (bits of `Ext`, a subset of
    /// `implemented`); set by kw_set_isa.
    isa: u64 = implemented,
    /// The value LR read at `resv` (smp: SC succeeds only if it is still there).
    resv_val: u64 = 0,
    /// Target of the atomic read-modify-write that makes FENCE a barrier (smp).
    fence_word: u32 = 0,
    _pad2: u32 = 0,
};

/// A full barrier (smp): a seq_cst read-modify-write, which V8 compiles to
/// a locked instruction on x86-64.
inline fn fullFence(h: *Hart) void {
    _ = @atomicRmw(u32, &h.fence_word, .Add, 0, .seq_cst);
}

/// Whether extension `e` is enabled on this hart (see `enabled`).
pub inline fn has(h: *const Hart, comptime e: Ext) bool {
    return enabled(h.isa, e);
}

pub const Exit = enum {
    /// Sequential instruction retired.
    next,
    /// Taken branch/jump retired (a block boundary: poll interrupts here).
    jump,
    /// The instruction did not retire (except ecall); see Hart.trap. The pc
    /// is left on the instruction.
    trap,
};

// ---- decode helpers ------------------------------------------------------------

pub inline fn sext(v: u64, comptime bits: u7) u64 {
    const sh: u6 = @intCast(64 - @as(u32, bits));
    return @bitCast(@as(i64, @bitCast(v << sh)) >> sh);
}
pub inline fn sx32(v: u32) u64 {
    return @bitCast(@as(i64, @as(i32, @bitCast(v))));
}
pub inline fn sgn(v: u64) i64 {
    return @bitCast(v);
}
pub inline fn uns(v: i64) u64 {
    return @bitCast(v);
}
pub inline fn lo32(v: u64) u32 {
    return @truncate(v);
}
pub inline fn immI(i: u32) u64 {
    return sext(i >> 20, 12);
}
pub inline fn immS(i: u32) u64 {
    return sext(((i >> 25) << 5) | ((i >> 7) & 0x1f), 12);
}
pub inline fn immB(i: u32) u64 {
    const v = ((i >> 31) << 12) | (((i >> 7) & 1) << 11) | (((i >> 25) & 0x3f) << 5) | (((i >> 8) & 0xf) << 1);
    return sext(v, 13);
}
pub inline fn immU(i: u32) u64 {
    return sx32(i & 0xfffff000);
}
pub inline fn immJ(i: u32) u64 {
    const v = ((i >> 31) << 20) | (((i >> 12) & 0xff) << 12) | (((i >> 20) & 1) << 11) | (((i >> 21) & 0x3ff) << 1);
    return sext(v, 21);
}

// offsets of the 64-bit compressed loads/stores (C.LD/C.SD/C.FLD/C.FSD, *SP forms)
pub inline fn offD(i: u32) u64 {
    return ((i >> 7) & 0x38) | ((i << 1) & 0xc0);
}
pub inline fn offLdsp(i: u32) u64 {
    return ((i >> 7) & 0x20) | ((i >> 2) & 0x18) | ((i << 4) & 0x1c0);
}
pub inline fn offSdsp(i: u32) u64 {
    return ((i >> 7) & 0x38) | ((i >> 1) & 0x1c0);
}

/// NaN-boxing of single-precision values in the 64-bit FP registers.
pub inline fn box(v: u32) u64 {
    return 0xffff_ffff_0000_0000 | @as(u64, v);
}
pub inline fn unbox(v: u64) u32 {
    return if (v >> 32 == 0xffff_ffff) @truncate(v) else F32.qnan;
}
/// The same for half precision (Zfhmin): the upper 48 bits all ones.
pub inline fn boxH(v: u16) u64 {
    return 0xffff_ffff_ffff_0000 | @as(u64, v);
}
pub inline fn unboxH(v: u64) u16 {
    return if (v >> 16 == 0xffff_ffff_ffff) @truncate(v) else fpu.F16.qnan;
}

fn ill(h: *Hart, inst: u32) Exit {
    @branchHint(.cold);
    h.trap = .illegal;
    h.trap_val = inst;
    return .trap;
}

// ---- M extension ---------------------------------------------------------------

pub fn divs(a: i64, b: i64) i64 {
    if (b == 0) return -1;
    if (a == std.math.minInt(i64) and b == -1) return a;
    return @divTrunc(a, b);
}
pub fn rems(a: i64, b: i64) i64 {
    if (b == 0) return a;
    if (a == std.math.minInt(i64) and b == -1) return 0;
    return @rem(a, b);
}
pub fn divs32(a: i32, b: i32) i32 {
    if (b == 0) return -1;
    if (a == std.math.minInt(i32) and b == -1) return a;
    return @divTrunc(a, b);
}
pub fn rems32(a: i32, b: i32) i32 {
    if (b == 0) return a;
    if (a == std.math.minInt(i32) and b == -1) return 0;
    return @rem(a, b);
}

pub fn mulDiv(f3: u32, a: u64, b: u64) u64 {
    return switch (f3) {
        0 => a *% b,
        1 => fpu.mulh(a, b),
        2 => fpu.mulhsu(a, b),
        3 => fpu.mul64(a, b).hi,
        4 => uns(divs(sgn(a), sgn(b))),
        5 => if (b == 0) std.math.maxInt(u64) else a / b,
        6 => uns(rems(sgn(a), sgn(b))),
        7 => if (b == 0) a else a % b,
        else => unreachable,
    };
}

pub fn mulDiv32(f3: u32, a64: u64, b64: u64) ?u64 {
    const a = lo32(a64);
    const b = lo32(b64);
    const ia: i32 = @bitCast(a);
    const ib: i32 = @bitCast(b);
    return switch (f3) {
        0 => sx32(a *% b),
        4 => sx32(@bitCast(divs32(ia, ib))),
        5 => sx32(if (b == 0) std.math.maxInt(u32) else a / b),
        6 => sx32(@bitCast(rems32(ia, ib))),
        7 => sx32(if (b == 0) a else a % b),
        else => null,
    };
}

// ---- A extension ---------------------------------------------------------------

fn amoOp(comptime T: type, f5: u32, old: T, src: T) T {
    const S = @Int(.signed, @bitSizeOf(T));
    return switch (f5) {
        0x01 => src,
        0x00 => old +% src,
        0x04 => old ^ src,
        0x0c => old & src,
        0x08 => old | src,
        0x10 => if (@as(S, @bitCast(old)) < @as(S, @bitCast(src))) old else src,
        0x14 => if (@as(S, @bitCast(old)) > @as(S, @bitCast(src))) old else src,
        0x18 => @min(old, src),
        0x1c => @max(old, src),
        else => unreachable,
    };
}

// ---- Zkne / Zknd: scalar AES (RV64) ------------------------------------------------
//
// As the RISC-V scalar cryptography spec v1.0.1 defines them. rs1 holds
// state columns 0-1 and rs2 columns 2-3 (byte i of a register is state byte
// i resp. 8 + i, row i % 4). No data-dependent branches or early exits;
// SubBytes is a table lookup indexed by data, so these are not claimed
// constant-time against cache timing (kwemu does not advertise Zkt).

pub const aes = struct {
    /// x * 2 in GF(2^8) mod x^8 + x^4 + x^3 + x + 1, without a branch.
    pub inline fn xt(x: u8) u8 {
        return (x << 1) ^ (0x1b & (0 -% (x >> 7)));
    }

    /// x * c in GF(2^8) (c a constant).
    pub inline fn mul(x: u8, comptime c: u8) u8 {
        var p: u8 = 0;
        var a = x;
        inline for (0..8) |i| {
            if (c >> i & 1 != 0) p ^= a;
            a = xt(a);
        }
        return p;
    }

    /// FIPS-197 S-box: the inverse in GF(2^8) (0 for 0), then the affine map.
    pub const sbox: [256]u8 = blk: {
        @setEvalBranchQuota(200000);
        var t: [256]u8 = undefined;
        for (0..256) |i| {
            const x: u8 = i;
            // x^254 = x^-1 (square and multiply over the bits of 254)
            var inv: u8 = 1;
            var p: u8 = x;
            var e: u8 = 254;
            while (e != 0) : (e >>= 1) {
                if (e & 1 != 0) inv = gmulRt(inv, p);
                p = gmulRt(p, p);
            }
            if (x == 0) inv = 0;
            t[i] = inv ^ std.math.rotl(u8, inv, 1) ^ std.math.rotl(u8, inv, 2) ^ std.math.rotl(u8, inv, 3) ^ std.math.rotl(u8, inv, 4) ^ 0x63;
        }
        break :blk t;
    };
    pub const inv_sbox: [256]u8 = blk: {
        var t: [256]u8 = undefined;
        for (0..256) |i| t[sbox[i]] = i;
        break :blk t;
    };

    /// a * b in GF(2^8); used only at compile time (it branches on b).
    fn gmulRt(a0: u8, b0: u8) u8 {
        var p: u8 = 0;
        var a = a0;
        var b = b0;
        while (b != 0) : (b >>= 1) {
            if (b & 1 != 0) p ^= a;
            a = xt(a);
        }
        return p;
    }

    /// Round constants of aes64ks1i, rnum 0..10.
    pub const rcon = [11]u8{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x00 };

    inline fn byte(v: u64, comptime i: u6) u64 {
        return (v >> (8 * i)) & 0xff;
    }

    /// The low 64 bits (columns 0-1) of ShiftRows of the state rs2:rs1:
    /// out byte r + 4c = in byte r + 4((c + r) % 4).
    pub inline fn shiftRowsFwd(rs1: u64, rs2: u64) u64 {
        return byte(rs1, 0) | byte(rs1, 5) << 8 | byte(rs2, 2) << 16 | byte(rs2, 7) << 24 |
            byte(rs1, 4) << 32 | byte(rs2, 1) << 40 | byte(rs2, 6) << 48 | byte(rs1, 3) << 56;
    }
    /// Same for InvShiftRows: out byte r + 4c = in byte r + 4((c - r) % 4).
    pub inline fn shiftRowsInv(rs1: u64, rs2: u64) u64 {
        return byte(rs1, 0) | byte(rs2, 5) << 8 | byte(rs2, 2) << 16 | byte(rs1, 7) << 24 |
            byte(rs1, 4) << 32 | byte(rs1, 1) << 40 | byte(rs2, 6) << 48 | byte(rs2, 3) << 56;
    }

    pub inline fn subBytes(comptime table: *const [256]u8, v: u64) u64 {
        var r: u64 = 0;
        inline for (0..8) |i| r |= @as(u64, table[@intCast(byte(v, i))]) << (8 * i);
        return r;
    }

    pub inline fn mixColumn(col: u32) u32 {
        const s0: u8 = @truncate(col);
        const s1: u8 = @truncate(col >> 8);
        const s2: u8 = @truncate(col >> 16);
        const s3: u8 = @truncate(col >> 24);
        const b0 = xt(s0) ^ (xt(s1) ^ s1) ^ s2 ^ s3;
        const b1 = s0 ^ xt(s1) ^ (xt(s2) ^ s2) ^ s3;
        const b2 = s0 ^ s1 ^ xt(s2) ^ (xt(s3) ^ s3);
        const b3 = (xt(s0) ^ s0) ^ s1 ^ s2 ^ xt(s3);
        return @as(u32, b0) | @as(u32, b1) << 8 | @as(u32, b2) << 16 | @as(u32, b3) << 24;
    }
    pub inline fn invMixColumn(col: u32) u32 {
        const s0: u8 = @truncate(col);
        const s1: u8 = @truncate(col >> 8);
        const s2: u8 = @truncate(col >> 16);
        const s3: u8 = @truncate(col >> 24);
        const b0 = mul(s0, 0xe) ^ mul(s1, 0xb) ^ mul(s2, 0xd) ^ mul(s3, 0x9);
        const b1 = mul(s0, 0x9) ^ mul(s1, 0xe) ^ mul(s2, 0xb) ^ mul(s3, 0xd);
        const b2 = mul(s0, 0xd) ^ mul(s1, 0x9) ^ mul(s2, 0xe) ^ mul(s3, 0xb);
        const b3 = mul(s0, 0xb) ^ mul(s1, 0xd) ^ mul(s2, 0x9) ^ mul(s3, 0xe);
        return @as(u32, b0) | @as(u32, b1) << 8 | @as(u32, b2) << 16 | @as(u32, b3) << 24;
    }
    inline fn mix64(v: u64) u64 {
        return @as(u64, mixColumn(@truncate(v))) | @as(u64, mixColumn(@truncate(v >> 32))) << 32;
    }
    inline fn invMix64(v: u64) u64 {
        return @as(u64, invMixColumn(@truncate(v))) | @as(u64, invMixColumn(@truncate(v >> 32))) << 32;
    }

    pub fn es(rs1: u64, rs2: u64) u64 {
        return subBytes(&sbox, shiftRowsFwd(rs1, rs2));
    }
    pub fn esm(rs1: u64, rs2: u64) u64 {
        return mix64(es(rs1, rs2));
    }
    pub fn ds(rs1: u64, rs2: u64) u64 {
        return subBytes(&inv_sbox, shiftRowsInv(rs1, rs2));
    }
    pub fn dsm(rs1: u64, rs2: u64) u64 {
        return invMix64(ds(rs1, rs2));
    }
    pub fn im(rs1: u64) u64 {
        return invMix64(rs1);
    }
    /// rnum must be 0..10 (11..15 are reserved: illegal instruction).
    pub fn ks1i(rs1: u64, rnum: u4) u64 {
        const t: u32 = @truncate(rs1 >> 32);
        const r = if (rnum == 0xa) t else std.math.rotr(u32, t, 8);
        const w: u32 = @as(u32, @truncate(subBytes(&sbox, r))) ^ rcon[rnum];
        return @as(u64, w) << 32 | w;
    }
    pub fn ks2(rs1: u64, rs2: u64) u64 {
        const w0: u32 = @as(u32, @truncate(rs1 >> 32)) ^ @as(u32, @truncate(rs2));
        const w1: u32 = w0 ^ @as(u32, @truncate(rs2 >> 32));
        return @as(u64, w1) << 32 | w0;
    }

    /// OP-IMM funct3 = 1 encodings other than slli: aes64im (imm 0x300,
    /// Zknd) and aes64ks1i (imm 0x310 | rnum, rnum <= 10, Zkne or Zknd).
    /// null = illegal under `isa`.
    pub inline fn opImm(isa: u64, inst: u32, a: u64) ?u64 {
        const imm = inst >> 20;
        if (imm == 0x300 and enabled(isa, .zknd)) return im(a);
        if (imm >> 4 == 0x31 and imm & 0xf <= 0xa and (enabled(isa, .zkne) or enabled(isa, .zknd))) return ks1i(a, @truncate(imm));
        return null;
    }
    /// OP encodings with funct7 = f7 (funct3 = 0): aes64es, aes64esm
    /// (Zkne), aes64ds, aes64dsm (Zknd), aes64ks2 (either). null = illegal.
    pub inline fn op(isa: u64, f3: u32, f7: u32, a: u64, b: u64) ?u64 {
        if (f3 != 0) return null;
        return switch (f7) {
            0x19 => if (enabled(isa, .zkne)) es(a, b) else null,
            0x1b => if (enabled(isa, .zkne)) esm(a, b) else null,
            0x1d => if (enabled(isa, .zknd)) ds(a, b) else null,
            0x1f => if (enabled(isa, .zknd)) dsm(a, b) else null,
            0x3f => if (enabled(isa, .zkne) or enabled(isa, .zknd)) ks2(a, b) else null,
            else => null,
        };
    }
};

// ---- Zba / Zbb / Zbc / Zbs / Zbkb / Zbkc / Zbkx: bit manipulation (RV64) -------------
//
// Zba, Zbb, Zbc and Zbs as the bit-manipulation spec v1.0.0 defines them,
// Zbkb, Zbkc and Zbkx as the scalar cryptography spec v1.0.1 does. RV64
// only: zip and unzip (RV32-only Zbkb) and RV32's rev8 encoding stay
// illegal.
//
//   Zba:  sh1add, sh2add, sh3add, add.uw, sh1add.uw, sh2add.uw, sh3add.uw,
//         slli.uw
//   Zbb:  clz, clzw, ctz, ctzw, cpop, cpopw, max, maxu, min, minu, sext.b,
//         sext.h, orc.b, and the ones shared with Zbkb (below)
//   Zbs:  bclr, bclri, bext, bexti, binv, binvi, bset, bseti
//   Zbc:  clmul, clmulh, clmulr        Zbkc: clmul, clmulh
//   Zbkx: xperm4, xperm8               Zbkb: pack, packh, packw, brev8, and
//   (Zbkb or Zbb): andn, orn, xnor, rol, ror, rori, rolw, rorw, roriw, rev8,
//                  and zext.h, which on RV64 is packw rd, rs1, x0
//
// Instructions that both Zbkb and Zbb define are gated on "Zbkb or Zbb"
// (`kbOrB`); packw with rs2 != 0, pack, packh and brev8 are Zbkb only.
//
// The Zbkb/Zbkc/Zbkx instructions are on the Zkt list (data-independent
// latency), so none of them branches on or indexes by data. clmul/clmulh/
// clmulr are a fixed sequence: BearSSL's "bmul64" (16 integer
// multiplications of the operands masked to every fourth bit; a column of
// each product has at most 16 terms, so its sum never carries into the next
// column of the same class below bit 64), and the reflected high half from
// the same on bit-reversed operands: clmulr(a, b) = rev(clmul(rev a, rev b)),
// clmulh = clmulr >> 1. This is constant-time where integer multiplication
// is (x86-64, AArch64). kwemu still does not advertise Zkt (the AES S-box is
// a table lookup).

pub const bitmanip = struct {
    const m0: u64 = 0x1111_1111_1111_1111;

    /// The low 64 bits of the carry-less product of a and b.
    pub fn clmul(a: u64, b: u64) u64 {
        var x: [4]u64 = undefined;
        var y: [4]u64 = undefined;
        inline for (0..4) |i| {
            x[i] = a & (m0 << i);
            y[i] = b & (m0 << i);
        }
        var r: u64 = 0;
        inline for (0..4) |k| {
            var z: u64 = 0;
            inline for (0..4) |i| z ^= x[i] *% y[(k + 4 - i) % 4];
            r |= z & (m0 << k);
        }
        return r;
    }
    /// Bits 63..126 of the carry-less product.
    pub fn clmulr(a: u64, b: u64) u64 {
        return @bitReverse(clmul(@bitReverse(a), @bitReverse(b)));
    }
    /// Bits 64..127 of the carry-less product.
    pub fn clmulh(a: u64, b: u64) u64 {
        return clmulr(a, b) >> 1;
    }

    /// The bits of every byte in reverse order.
    pub fn brev8(a: u64) u64 {
        return @byteSwap(@bitReverse(a));
    }
    pub fn rev8(a: u64) u64 {
        return @byteSwap(a);
    }
    pub fn pack(a: u64, b: u64) u64 {
        return (a & 0xffff_ffff) | b << 32;
    }
    pub fn packh(a: u64, b: u64) u64 {
        return (a & 0xff) | (b & 0xff) << 8;
    }
    pub fn packw(a: u64, b: u64) u64 {
        return sx32(@as(u32, @truncate(a & 0xffff)) | @as(u32, @truncate(b)) << 16);
    }
    /// Byte i of the result is byte (byte i of b) of a, or 0 if that index
    /// is 8 or more.
    pub fn xperm8(a: u64, b: u64) u64 {
        var r: u64 = 0;
        inline for (0..8) |i| {
            const idx = (b >> (8 * i)) & 0xff;
            const v = (a >> @truncate(idx << 3)) & 0xff;
            r |= (v & (0 -% @as(u64, @intFromBool(idx < 8)))) << (8 * i);
        }
        return r;
    }
    /// Nibble i of the result is nibble (nibble i of b) of a (every index
    /// is in range on RV64).
    pub fn xperm4(a: u64, b: u64) u64 {
        var r: u64 = 0;
        inline for (0..16) |i| {
            const idx = (b >> (4 * i)) & 0xf;
            r |= ((a >> @truncate(idx << 2)) & 0xf) << (4 * i);
        }
        return r;
    }
    pub fn rolw(a: u64, b: u64) u64 {
        return sx32(std.math.rotl(u32, @truncate(a), @as(u5, @truncate(b))));
    }
    pub fn rorw(a: u64, b: u64) u64 {
        return sx32(std.math.rotr(u32, @truncate(a), @as(u5, @truncate(b))));
    }

    // Zba: (zext.w(a) if uw) << n, plus b
    pub fn shadd(a: u64, b: u64, comptime n: u6) u64 {
        return (a << n) +% b;
    }
    pub fn shaddUw(a: u64, b: u64, n: u6) u64 {
        return ((a & 0xffff_ffff) << n) +% b;
    }

    // Zbb
    pub fn clzw(a: u64) u64 {
        return @clz(@as(u32, @truncate(a)));
    }
    pub fn ctzw(a: u64) u64 {
        return @ctz(@as(u32, @truncate(a)));
    }
    pub fn cpopw(a: u64) u64 {
        return @popCount(@as(u32, @truncate(a)));
    }
    pub fn max(a: u64, b: u64) u64 {
        return if (sgn(a) < sgn(b)) b else a;
    }
    pub fn min(a: u64, b: u64) u64 {
        return if (sgn(a) < sgn(b)) a else b;
    }
    /// Every nonzero byte becomes 0xff: bit 7 of ((a & 0x7f..) + 0x7f..) | a
    /// is set iff the byte is nonzero (no carry crosses a byte).
    pub fn orcb(a: u64) u64 {
        const lo7: u64 = 0x7f7f_7f7f_7f7f_7f7f;
        const t = ((a & lo7) +% lo7) | a;
        return ((t >> 7) & 0x0101_0101_0101_0101) *% 0xff;
    }

    // Zbs: the bit index is rs2 (or shamt) mod 64
    pub fn bclr(a: u64, b: u64) u64 {
        return a & ~(@as(u64, 1) << @as(u6, @truncate(b)));
    }
    pub fn bset(a: u64, b: u64) u64 {
        return a | (@as(u64, 1) << @as(u6, @truncate(b)));
    }
    pub fn binv(a: u64, b: u64) u64 {
        return a ^ (@as(u64, 1) << @as(u6, @truncate(b)));
    }
    pub fn bext(a: u64, b: u64) u64 {
        return (a >> @as(u6, @truncate(b))) & 1;
    }

    /// The gate of the instructions Zbkb shares with Zbb.
    pub inline fn kbOrB(isa: u64) bool {
        return enabled(isa, .zbkb) or enabled(isa, .zbb);
    }
    inline fn kc(isa: u64) bool {
        return enabled(isa, .zbc) or enabled(isa, .zbkc);
    }

    /// OP (0x33) encodings with funct7 0x20 (andn, orn, xnor; funct3 0 and
    /// 5 are sub and sra), 0x30 (rol, ror), 0x04 (pack, packh), 0x05
    /// (clmul, clmulr, clmulh; min, minu, max, maxu), 0x10 (sh1add, sh2add,
    /// sh3add), 0x14 (bset; xperm4, xperm8), 0x24 (bclr, bext) or 0x34
    /// (binv). null = illegal.
    pub inline fn op(isa: u64, f3: u32, f7: u32, a: u64, b: u64) ?u64 {
        const sh: u6 = @truncate(b);
        return switch (f7) {
            0x20 => if (!kbOrB(isa)) null else switch (f3) {
                4 => ~(a ^ b),
                6 => a | ~b,
                7 => a & ~b,
                else => null,
            },
            0x30 => if (!kbOrB(isa)) null else switch (f3) {
                1 => std.math.rotl(u64, a, sh),
                5 => std.math.rotr(u64, a, sh),
                else => null,
            },
            0x04 => if (!enabled(isa, .zbkb)) null else switch (f3) {
                4 => pack(a, b),
                7 => packh(a, b),
                else => null,
            },
            0x05 => switch (f3) {
                1 => if (kc(isa)) clmul(a, b) else null,
                2 => if (enabled(isa, .zbc)) clmulr(a, b) else null,
                3 => if (kc(isa)) clmulh(a, b) else null,
                4 => if (enabled(isa, .zbb)) min(a, b) else null,
                5 => if (enabled(isa, .zbb)) @min(a, b) else null,
                6 => if (enabled(isa, .zbb)) max(a, b) else null,
                7 => if (enabled(isa, .zbb)) @max(a, b) else null,
                else => null,
            },
            0x10 => if (!enabled(isa, .zba)) null else switch (f3) {
                2 => shadd(a, b, 1),
                4 => shadd(a, b, 2),
                6 => shadd(a, b, 3),
                else => null,
            },
            0x14 => switch (f3) {
                1 => if (enabled(isa, .zbs)) bset(a, b) else null,
                2 => if (enabled(isa, .zbkx)) xperm4(a, b) else null,
                4 => if (enabled(isa, .zbkx)) xperm8(a, b) else null,
                else => null,
            },
            0x24 => if (!enabled(isa, .zbs)) null else switch (f3) {
                1 => bclr(a, b),
                5 => bext(a, b),
                else => null,
            },
            0x34 => if (f3 == 1 and enabled(isa, .zbs)) binv(a, b) else null,
            else => null,
        };
    }
    /// OP-32 (0x3b) encodings with funct7 0x30 (rolw, rorw), 0x04 (add.uw;
    /// packw, which is zext.h when rs2 = x0) or 0x10 (sh1add.uw, sh2add.uw,
    /// sh3add.uw). null = illegal.
    pub inline fn op32(isa: u64, f3: u32, f7: u32, rs2: u32, a: u64, b: u64) ?u64 {
        return switch (f7) {
            0x30 => if (!kbOrB(isa)) null else switch (f3) {
                1 => rolw(a, b),
                5 => rorw(a, b),
                else => null,
            },
            0x04 => switch (f3) {
                0 => if (enabled(isa, .zba)) shaddUw(a, b, 0) else null,
                4 => if (enabled(isa, .zbkb) or (rs2 == 0 and enabled(isa, .zbb))) packw(a, b) else null,
                else => null,
            },
            0x10 => if (!enabled(isa, .zba)) null else switch (f3) {
                2 => shaddUw(a, b, 1),
                4 => shaddUw(a, b, 2),
                6 => shaddUw(a, b, 3),
                else => null,
            },
            else => null,
        };
    }
    /// OP-IMM (0x13) funct3 = 1 encodings other than slli and the AES ones:
    /// bseti, bclri, binvi (imm[11:6] = 0x0a, 0x12, 0x1a), clz, ctz, cpop,
    /// sext.b, sext.h (imm 0x600, 0x601, 0x602, 0x604, 0x605). null = illegal.
    pub inline fn opImm1(isa: u64, inst: u32, a: u64) ?u64 {
        const imm = inst >> 20;
        const sh: u6 = @truncate(imm);
        if (enabled(isa, .zbs)) switch (imm >> 6) {
            0x0a => return bset(a, sh),
            0x12 => return bclr(a, sh),
            0x1a => return binv(a, sh),
            else => {},
        };
        if (enabled(isa, .zbb)) switch (imm) {
            0x600 => return @clz(a),
            0x601 => return @ctz(a),
            0x602 => return @popCount(a),
            0x604 => return sext(a, 8),
            0x605 => return sext(a, 16),
            else => {},
        };
        return null;
    }
    /// OP-IMM (0x13) funct3 = 5 encodings other than srli/srai: rori
    /// (imm[11:6] = 0x18), bexti (0x12), rev8 (imm 0x6b8), brev8 (imm
    /// 0x687), orc.b (imm 0x287). null = illegal.
    pub inline fn opImm(isa: u64, inst: u32, a: u64) ?u64 {
        const imm = inst >> 20;
        if (imm >> 6 == 0x18 and kbOrB(isa)) return std.math.rotr(u64, a, @as(u6, @truncate(imm)));
        if (imm >> 6 == 0x12 and enabled(isa, .zbs)) return bext(a, imm);
        if (imm == 0x6b8 and kbOrB(isa)) return rev8(a);
        if (imm == 0x687 and enabled(isa, .zbkb)) return brev8(a);
        if (imm == 0x287 and enabled(isa, .zbb)) return orcb(a);
        return null;
    }
    /// OP-IMM-32 (0x1b) funct3 = 1 encodings other than slliw: slli.uw
    /// (imm[11:6] = 0x02, a 6-bit shamt), clzw, ctzw, cpopw (imm 0x600,
    /// 0x601, 0x602). null = illegal.
    pub inline fn opImm32(isa: u64, inst: u32, a: u64) ?u64 {
        const imm = inst >> 20;
        if (imm >> 6 == 0x02 and enabled(isa, .zba)) return shaddUw(a, 0, @truncate(imm));
        if (enabled(isa, .zbb)) switch (imm) {
            0x600 => return clzw(a),
            0x601 => return ctzw(a),
            0x602 => return cpopw(a),
            else => {},
        };
        return null;
    }
};

// ---- Zicond: integer conditional operations ------------------------------------------

/// OP (0x33) encodings with funct7 0x07: czero.eqz (funct3 5), czero.nez
/// (funct3 7). null = illegal.
pub inline fn czero(isa: u64, f3: u32, a: u64, b: u64) ?u64 {
    if (!enabled(isa, .zicond)) return null;
    return switch (f3) {
        5 => if (b == 0) 0 else a,
        7 => if (b != 0) 0 else a,
        else => null,
    };
}

// ---- Zimop / Zcmop: may-be-operations ---------------------------------------------
//
// mop.r.N (32 of them) and mop.rr.N (8) write 0 to rd, c.mop.N (8) does
// nothing. The same encodings also hold Zicfiss (sspush, sspopchk, ssrdp,
// c.sspush, c.sspopchk), which kwemu does not implement: without it (and
// with shadow stacks off, which is all Linux user space can see here) they
// are exactly these MOPs.

/// SYSTEM funct3 = 4: mop.r.N (bits 31, 29:28, 25:22 = 1, 00, 0111) or
/// mop.rr.N (bits 31, 29:28, 25 = 1, 00, 1).
pub inline fn isMop(inst: u32) bool {
    return inst & 0xb3c0_707f == 0x81c0_4073 or inst & 0xb200_707f == 0x8200_4073;
}
/// c.mop.N: c.lui with rd = x1, x3, ..., x15 and a zero immediate.
pub inline fn isCMop(i: u32) bool {
    return i & 0xf8ff == 0x6081;
}

// ---- Zcb: more compressed instructions ---------------------------------------------
//
// c.lbu, c.lhu, c.lh, c.sb, c.sh (quadrant 0, funct3 100), c.mul, c.zext.b,
// c.sext.b, c.zext.h, c.sext.h, c.zext.w, c.not (quadrant 1, funct6 100111).
// c.sext.b, c.sext.h and c.zext.h also need Zbb, c.zext.w needs Zba, c.mul
// needs M (always there).

/// The byte offset of c.lbu / c.sb: uimm[0] is bit 6, uimm[1] bit 5.
pub inline fn zcbOffB(i: u32) u64 {
    return ((i >> 6) & 1) | ((i >> 4) & 2);
}
/// The halfword offset of c.lhu / c.lh / c.sh: uimm[1] is bit 5.
pub inline fn zcbOffH(i: u32) u64 {
    return (i >> 4) & 2;
}
/// c.zext.b ... c.not on `a` (sub-opcode in bits 4:2); null = illegal under `isa`.
pub inline fn zcbUnary(isa: u64, i: u32, a: u64) ?u64 {
    return switch ((i >> 2) & 7) {
        0 => a & 0xff, // c.zext.b
        1 => if (enabled(isa, .zbb)) sext(a, 8) else null, // c.sext.b
        2 => if (enabled(isa, .zbb)) a & 0xffff else null, // c.zext.h
        3 => if (enabled(isa, .zbb)) sext(a, 16) else null, // c.sext.h
        4 => if (enabled(isa, .zba)) a & 0xffff_ffff else null, // c.zext.w
        5 => ~a, // c.not
        else => null,
    };
}

// ---- Zawrs: wait on reservation set ------------------------------------------------
//
// wrs.nto and wrs.sto may complete at once for any reason, so kwemu runs
// them as no-ops, like PAUSE: a single hart has no other store to wait for,
// and a polling loop around them is preempted by the kernel's time slices
// like any other loop.

pub const wrs_nto: u32 = 0x00d0_0073;
pub const wrs_sto: u32 = 0x01d0_0073;

// ---- Zfa: additional floating-point instructions (S and D) ---------------------------
//
// fli.s/d, fminm/fmaxm.s/d, fround/froundnx.s/d, fcvtmod.w.d, fleq/fltq.s/d,
// as Zfa v1.0 defines them for F and D; the .h forms need Zfh (not Zfhmin)
// and fmvh.x.d / fmvp.d.x are RV32-only, so they stay illegal.

/// The 32 values of fli (rs1 = index): -1, the smallest normal, 2^-16,
/// 2^-15, 2^-8, 2^-7, 0.0625 ... 0.875 in steps of 1/16 from 0.25, 1 ...
/// 1.75, 2, 2.5, 3, 4, 8, 16, 128, 256, 2^15, 2^16, +inf, the canonical NaN.
pub fn fliTable(comptime B: type) [32]B {
    const F = fpu.Fmt(B);
    const T = if (B == u32) f32 else f64;
    const vals = [_]f64{ -1.0, 0, 0x1p-16, 0x1p-15, 0x1p-8, 0x1p-7, 0.0625, 0.125, 0.25, 0.3125, 0.375, 0.4375, 0.5, 0.625, 0.75, 0.875, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 8.0, 16.0, 128.0, 256.0, 0x1p15, 0x1p16 };
    var t: [32]B = undefined;
    for (vals, 0..) |v, i| t[i] = @bitCast(@as(T, @floatCast(v)));
    t[1] = @as(B, 1) << F.mb; // the smallest normal
    t[30] = F.inf;
    t[31] = F.qnan;
    return t;
}
pub const fli_s = fliTable(u32);
pub const fli_d = fliTable(u64);

// ---- F/D extension ---------------------------------------------------------------

inline fn resolveRm(r: *const Regs, f3: u32) ?u32 {
    const m = if (f3 == 7) (r.fcsr >> 5) & 7 else f3;
    return if (m > 4) null else m;
}

/// Read an FP operand of format B (unboxing singles).
inline fn fget(comptime B: type, r: *const Regs, i: u32) B {
    return if (B == u32) unbox(r.f[i]) else r.f[i];
}
inline fn fset(comptime B: type, r: *Regs, i: u32, v: B) void {
    r.f[i] = if (B == u32) box(v) else v;
}

noinline fn fmaOp(comptime B: type, r: *Regs, inst: u32, rm: u32) void {
    const F = fpu.Fmt(B);
    const rd = (inst >> 7) & 31;
    var a = fget(B, r, (inst >> 15) & 31);
    const b = fget(B, r, (inst >> 20) & 31);
    var c = fget(B, r, inst >> 27);
    switch (inst & 0x7f) {
        0x43 => {}, // fmadd: a*b + c
        0x47 => c ^= F.sign, // fmsub: a*b - c
        0x4b => a ^= F.sign, // fnmsub: -(a*b) + c
        else => { // fnmadd: -(a*b) - c
            a ^= F.sign;
            c ^= F.sign;
        },
    }
    var fl: u32 = 0;
    fset(B, r, rd, F.fma(a, b, c, rm, &fl));
    r.fcsr |= fl;
}

fn opFpFmt(comptime B: type, r: *Regs, h: *Hart, inst: u32) Exit {
    const F = fpu.Fmt(B);
    const rd = (inst >> 7) & 31;
    const f3 = (inst >> 12) & 7;
    const rs1 = (inst >> 15) & 31;
    const rs2 = (inst >> 20) & 31;
    const f5 = inst >> 27;
    var fl: u32 = 0;
    switch (f5) {
        0x00, 0x01, 0x02, 0x03, 0x0b => { // fadd fsub fmul fdiv fsqrt
            const rm = resolveRm(r, f3) orelse return ill(h, inst);
            const a = fget(B, r, rs1);
            const b = fget(B, r, rs2);
            const v = switch (f5) {
                0x00 => F.add(a, b, rm, &fl),
                0x01 => F.sub(a, b, rm, &fl),
                0x02 => F.mul(a, b, rm, &fl),
                0x03 => F.div(a, b, rm, &fl),
                else => if (rs2 != 0) return ill(h, inst) else F.sqrt(a, rm, &fl),
            };
            fset(B, r, rd, v);
        },
        0x08 => if (rs2 == 4 or rs2 == 5) { // fround / froundnx (Zfa)
            if (!has(h, .zfa)) return ill(h, inst);
            const rm = resolveRm(r, f3) orelse return ill(h, inst);
            fset(B, r, rd, F.roundInt(fget(B, r, rs1), rm, rs2 == 5, &fl));
        } else { // fcvt.s.d / fcvt.d.s; fcvt.s.h / fcvt.d.h (Zfhmin)
            const rm = resolveRm(r, f3) orelse return ill(h, inst);
            if (rs2 == 2) {
                if (!has(h, .zfhmin)) return ill(h, inst);
                fset(B, r, rd, F.fromOther(u16, unboxH(r.f[rs1]), rm, &fl));
            } else if (B == u32) {
                if (rs2 != 1) return ill(h, inst);
                fset(B, r, rd, F.fromOther(u64, r.f[rs1], rm, &fl));
            } else {
                if (rs2 != 0) return ill(h, inst);
                fset(B, r, rd, F.fromOther(u32, unbox(r.f[rs1]), rm, &fl));
            }
        },
        0x04 => { // fsgnj / fsgnjn / fsgnjx
            const a = fget(B, r, rs1);
            const b = fget(B, r, rs2);
            const s = switch (f3) {
                0 => b & F.sign,
                1 => ~b & F.sign,
                2 => (a ^ b) & F.sign,
                else => return ill(h, inst),
            };
            fset(B, r, rd, (a & ~F.sign) | s);
        },
        0x05 => { // fmin / fmax; fminm / fmaxm (Zfa)
            const a = fget(B, r, rs1);
            const b = fget(B, r, rs2);
            if (f3 >= 2 and !has(h, .zfa)) return ill(h, inst);
            fset(B, r, rd, switch (f3) {
                0 => F.min(a, b, &fl),
                1 => F.max(a, b, &fl),
                2 => F.minm(a, b, &fl),
                3 => F.maxm(a, b, &fl),
                else => return ill(h, inst),
            });
        },
        0x14 => { // feq / flt / fle; fleq / fltq (Zfa)
            const a = fget(B, r, rs1);
            const b = fget(B, r, rs2);
            if (f3 >= 4 and !has(h, .zfa)) return ill(h, inst);
            r.x[rd] = @intFromBool(switch (f3) {
                2 => F.eq(a, b, &fl),
                1 => F.lt(a, b, &fl),
                0 => F.le(a, b, &fl),
                4 => F.leq(a, b, &fl),
                5 => F.ltq(a, b, &fl),
                else => return ill(h, inst),
            });
        },
        0x18 => { // fcvt.{w,wu,l,lu}.fmt; fcvtmod.w.d (Zfa)
            if (B == u64 and rs2 == 8 and f3 == 1 and has(h, .zfa)) {
                r.x[rd] = fpu.fcvtmodWD(r.f[rs1], &fl);
                r.fcsr |= fl;
                return .next;
            }
            const rm = resolveRm(r, f3) orelse return ill(h, inst);
            const a = fget(B, r, rs1);
            r.x[rd] = switch (rs2) {
                0 => F.toInt(a, rm, true, 32, &fl),
                1 => F.toInt(a, rm, false, 32, &fl),
                2 => F.toInt(a, rm, true, 64, &fl),
                3 => F.toInt(a, rm, false, 64, &fl),
                else => return ill(h, inst),
            };
        },
        0x1a => { // fcvt.fmt.{w,wu,l,lu}
            const rm = resolveRm(r, f3) orelse return ill(h, inst);
            const v = r.x[rs1];
            fset(B, r, rd, switch (rs2) {
                0 => blk: {
                    const iv: i32 = @bitCast(lo32(v));
                    break :blk F.fromInt(iv < 0, @abs(iv), rm, &fl);
                },
                1 => F.fromInt(false, lo32(v), rm, &fl),
                2 => F.fromInt(sgn(v) < 0, @abs(sgn(v)), rm, &fl),
                3 => F.fromInt(false, v, rm, &fl),
                else => return ill(h, inst),
            });
        },
        0x1c => { // fmv.x.{w,d} / fclass
            if (rs2 != 0) return ill(h, inst);
            r.x[rd] = switch (f3) {
                0 => if (B == u32) sx32(lo32(r.f[rs1])) else r.f[rs1],
                1 => F.classify(fget(B, r, rs1)),
                else => return ill(h, inst),
            };
        },
        0x1e => { // fmv.{w,d}.x; fli.{s,d} (Zfa)
            if (f3 != 0) return ill(h, inst);
            if (rs2 == 1 and has(h, .zfa)) {
                fset(B, r, rd, if (B == u32) fli_s[rs1] else fli_d[rs1]);
            } else {
                if (rs2 != 0) return ill(h, inst);
                fset(B, r, rd, @truncate(r.x[rs1]));
            }
        },
        else => return ill(h, inst),
    }
    r.fcsr |= fl;
    return .next;
}

/// Zfhmin's OP-FP forms with fmt = H: fcvt.h.s, fcvt.h.d, fmv.x.h, fmv.h.x
/// (the rest of fmt H is Zfh: illegal).
fn opFpH(r: *Regs, h: *Hart, inst: u32) Exit {
    if (!has(h, .zfhmin)) return ill(h, inst);
    const rd = (inst >> 7) & 31;
    const f3 = (inst >> 12) & 7;
    const rs1 = (inst >> 15) & 31;
    const rs2 = (inst >> 20) & 31;
    var fl: u32 = 0;
    switch (inst >> 27) {
        0x08 => { // fcvt.h.s / fcvt.h.d
            const rm = resolveRm(r, f3) orelse return ill(h, inst);
            r.f[rd] = boxH(switch (rs2) {
                0 => fpu.F16.fromOther(u32, unbox(r.f[rs1]), rm, &fl),
                1 => fpu.F16.fromOther(u64, r.f[rs1], rm, &fl),
                else => return ill(h, inst),
            });
        },
        0x1c => { // fmv.x.h: the low 16 bits, sign-extended (not unboxed)
            if (rs2 != 0 or f3 != 0) return ill(h, inst);
            r.x[rd] = sext(r.f[rs1] & 0xffff, 16);
        },
        0x1e => { // fmv.h.x
            if (rs2 != 0 or f3 != 0) return ill(h, inst);
            r.f[rd] = boxH(@truncate(r.x[rs1]));
        },
        else => return ill(h, inst),
    }
    r.fcsr |= fl;
    return .next;
}

noinline fn opFp(r: *Regs, h: *Hart, inst: u32) Exit {
    return switch ((inst >> 25) & 3) {
        0 => opFpFmt(u32, r, h, inst),
        1 => opFpFmt(u64, r, h, inst),
        2 => opFpH(r, h, inst),
        else => ill(h, inst),
    };
}

// ---- Zicsr -----------------------------------------------------------------------

noinline fn csrOp(r: *Regs, h: *Hart, inst: u32) Exit {
    const rd = (inst >> 7) & 31;
    const f3 = (inst >> 12) & 7;
    const rs1 = (inst >> 15) & 31;
    const num = inst >> 20;
    const src: u64 = if (f3 & 4 != 0) rs1 else r.x[rs1];
    const writes = (f3 & 3) == 1 or rs1 != 0;
    const old: u64 = switch (num) {
        0x001 => r.fcsr & 0x1f,
        0x002 => (r.fcsr >> 5) & 7,
        0x003 => r.fcsr & 0xff,
        0xc00, 0xc01, 0xc02 => {
            if (writes) return ill(h, inst);
            h.trap = .counter;
            h.trap_val = rd;
            return .trap;
        },
        // hpmcounter3..31 (Zihpm): no events are counted, so they read 0
        0xc03...0xc1f => if (writes or !has(h, .zihpm)) return ill(h, inst) else 0,
        else => return ill(h, inst),
    };
    if (writes) {
        const new: u64 = switch (f3 & 3) {
            1 => src,
            2 => old | src,
            3 => old & ~src,
            else => unreachable,
        };
        const n32: u32 = @truncate(new);
        r.fcsr = switch (num) {
            0x001 => (r.fcsr & ~@as(u32, 0x1f)) | (n32 & 0x1f),
            0x002 => (r.fcsr & 0x1f) | ((n32 & 7) << 5),
            else => n32 & 0xff,
        };
    }
    r.x[rd] = old;
    return .next;
}

/// Complete a cycle/time/instret read (Hart.trap == .counter): all three
/// return `now`, the number of instructions retired so far.
pub fn finishCounter(r: *Regs, h: *const Hart, now: u64) void {
    if (h.trap_val != 0) r.x[@intCast(h.trap_val)] = now;
    r.pc +%= 4;
}

// ---- interpreter -----------------------------------------------------------------

pub fn Interp(comptime M: type) type {
    return struct {
        /// Execute one instruction.
        pub inline fn step(r: *Regs, h: *Hart, m: *M) Error!Exit {
            return exec(r, h, m, try m.fetch(r.pc));
        }

        /// Execute the already-fetched instruction `inst` at r.pc (low 16
        /// bits only for a compressed one).
        pub inline fn exec(r: *Regs, h: *Hart, m: *M, inst: u32) Error!Exit {
            const pc = r.pc;
            if (inst & 3 != 3) return stepC(r, h, m, @truncate(inst));
            const x = &r.x;
            const rd = (inst >> 7) & 31;
            const f3 = (inst >> 12) & 7;
            const rs1 = (inst >> 15) & 31;
            const rs2 = (inst >> 20) & 31;
            const f7 = inst >> 25;
            var next = pc +% 4;
            var exit: Exit = .next;
            switch (inst & 0x7f) {
                0x37 => x[rd] = immU(inst), // LUI
                0x17 => x[rd] = pc +% immU(inst), // AUIPC
                0x6f => { // JAL
                    x[rd] = next;
                    next = pc +% immJ(inst);
                    exit = .jump;
                },
                0x67 => { // JALR
                    if (f3 != 0) return ill(h, inst);
                    const tgt = (x[rs1] +% immI(inst)) & ~@as(u64, 1);
                    x[rd] = next;
                    next = tgt;
                    exit = .jump;
                },
                0x63 => { // BRANCH
                    const a = x[rs1];
                    const b = x[rs2];
                    const taken = switch (f3) {
                        0 => a == b,
                        1 => a != b,
                        4 => sgn(a) < sgn(b),
                        5 => sgn(a) >= sgn(b),
                        6 => a < b,
                        7 => a >= b,
                        else => return ill(h, inst),
                    };
                    if (taken) {
                        next = pc +% immB(inst);
                        exit = .jump;
                    }
                },
                0x03 => { // LOAD
                    const addr = x[rs1] +% immI(inst);
                    x[rd] = switch (f3) {
                        0 => sext(try m.load(u8, addr), 8),
                        1 => sext(try m.load(u16, addr), 16),
                        2 => sx32(try m.load(u32, addr)),
                        3 => try m.load(u64, addr),
                        4 => try m.load(u8, addr),
                        5 => try m.load(u16, addr),
                        6 => try m.load(u32, addr),
                        else => return ill(h, inst),
                    };
                },
                0x23 => { // STORE
                    const addr = x[rs1] +% immS(inst);
                    const v = x[rs2];
                    switch (f3) {
                        0 => try m.store(u8, addr, @truncate(v)),
                        1 => try m.store(u16, addr, @truncate(v)),
                        2 => try m.store(u32, addr, @truncate(v)),
                        3 => try m.store(u64, addr, v),
                        else => return ill(h, inst),
                    }
                },
                0x13 => { // OP-IMM
                    const a = x[rs1];
                    const imm = immI(inst);
                    const sh: u6 = @truncate(inst >> 20);
                    x[rd] = switch (f3) {
                        0 => a +% imm,
                        // aes64im / aes64ks1i (Zknd / Zkne); bseti, bclri, binvi
                        // (Zbs); clz, ctz, cpop, sext.b, sext.h (Zbb)
                        1 => if (inst >> 26 == 0) a << sh else aes.opImm(h.isa, inst, a) orelse
                            bitmanip.opImm1(h.isa, inst, a) orelse return ill(h, inst),
                        2 => @intFromBool(sgn(a) < sgn(imm)),
                        3 => @intFromBool(a < imm),
                        4 => a ^ imm,
                        5 => switch (inst >> 26) {
                            0 => a >> sh,
                            0x10 => uns(sgn(a) >> sh),
                            // rori, rev8 (Zbkb or Zbb), brev8 (Zbkb), bexti (Zbs), orc.b (Zbb)
                            else => bitmanip.opImm(h.isa, inst, a) orelse return ill(h, inst),
                        },
                        6 => a | imm,
                        7 => a & imm,
                        else => unreachable,
                    };
                },
                0x1b => { // OP-IMM-32
                    const a = lo32(x[rs1]);
                    const sh: u5 = @truncate(inst >> 20);
                    x[rd] = switch (f3) {
                        0 => sx32(a +% lo32(immI(inst))),
                        // slli.uw (Zba), clzw, ctzw, cpopw (Zbb)
                        1 => if (f7 == 0) sx32(a << sh) else bitmanip.opImm32(h.isa, inst, a) orelse return ill(h, inst),
                        5 => switch (f7) {
                            0 => sx32(a >> sh),
                            0x20 => sx32(@bitCast(@as(i32, @bitCast(a)) >> sh)),
                            // roriw (Zbkb or Zbb)
                            0x30 => if (bitmanip.kbOrB(h.isa)) bitmanip.rorw(a, sh) else return ill(h, inst),
                            else => return ill(h, inst),
                        },
                        else => return ill(h, inst),
                    };
                },
                0x33 => { // OP
                    const a = x[rs1];
                    const b = x[rs2];
                    const sh: u6 = @truncate(b);
                    x[rd] = switch (f7) {
                        0 => switch (f3) {
                            0 => a +% b,
                            1 => a << sh,
                            2 => @intFromBool(sgn(a) < sgn(b)),
                            3 => @intFromBool(a < b),
                            4 => a ^ b,
                            5 => a >> sh,
                            6 => a | b,
                            7 => a & b,
                            else => unreachable,
                        },
                        0x20 => switch (f3) {
                            0 => a -% b,
                            5 => uns(sgn(a) >> sh),
                            // andn, orn, xnor (Zbkb or Zbb)
                            else => bitmanip.op(h.isa, f3, f7, a, b) orelse return ill(h, inst),
                        },
                        1 => mulDiv(f3, a, b),
                        // rol/ror, pack/packh, clmul/clmulr/clmulh, min/max(u),
                        // sh1add..sh3add, bset, xperm4/xperm8, bclr/bext, binv
                        0x30, 0x04, 0x05, 0x10, 0x14, 0x24, 0x34 => bitmanip.op(h.isa, f3, f7, a, b) orelse return ill(h, inst),
                        0x07 => czero(h.isa, f3, a, b) orelse return ill(h, inst), // czero.eqz/nez (Zicond)
                        // aes64es/esm/ds/dsm/ks2 (Zkne / Zknd)
                        0x19, 0x1b, 0x1d, 0x1f, 0x3f => aes.op(h.isa, f3, f7, a, b) orelse return ill(h, inst),
                        else => return ill(h, inst),
                    };
                },
                0x3b => { // OP-32
                    const a = lo32(x[rs1]);
                    const b = lo32(x[rs2]);
                    const sh: u5 = @truncate(b);
                    x[rd] = switch (f7) {
                        0 => switch (f3) {
                            0 => sx32(a +% b),
                            1 => sx32(a << sh),
                            5 => sx32(a >> sh),
                            else => return ill(h, inst),
                        },
                        0x20 => switch (f3) {
                            0 => sx32(a -% b),
                            5 => sx32(@bitCast(@as(i32, @bitCast(a)) >> sh)),
                            else => return ill(h, inst),
                        },
                        1 => mulDiv32(f3, x[rs1], x[rs2]) orelse return ill(h, inst),
                        // rolw/rorw (Zbkb or Zbb), packw (Zbkb; zext.h: also Zbb),
                        // add.uw, sh1add.uw..sh3add.uw (Zba)
                        0x30, 0x04, 0x10 => bitmanip.op32(h.isa, f3, f7, rs2, x[rs1], x[rs2]) orelse return ill(h, inst),
                        else => return ill(h, inst),
                    };
                },
                0x0f => switch (f3) { // MISC-MEM
                    // FENCE / FENCE.TSO / PAUSE: a no-op on a single hart
                    // with coherent memory; a full barrier when harts share
                    // it (the decoder sends it here only then).
                    0 => if (smp) fullFence(h),
                    // FENCE.I tells a memory with a decoded-code cache.
                    1 => if (@hasDecl(M, "fenceI")) m.fenceI(),
                    // cbo.clean / cbo.flush (Zicbom), cbo.zero (Zicboz)
                    2 => if (!try cbo(r, h, m, inst)) return .trap,
                    else => return ill(h, inst),
                },
                0x73 => { // SYSTEM
                    if (f3 == 0) {
                        switch (inst) {
                            0x00000073 => { // ECALL: pc stays on it
                                h.trap = .syscall;
                                return .trap;
                            },
                            0x00100073 => {
                                h.trap = .breakpoint;
                                return .trap;
                            },
                            // wrs.nto / wrs.sto (Zawrs): no-ops
                            wrs_nto, wrs_sto => if (!has(h, .zawrs)) return ill(h, inst),
                            else => return ill(h, inst),
                        }
                    } else if (f3 == 4) {
                        // mop.r.N / mop.rr.N (Zimop): rd = 0
                        if (!has(h, .zimop) or !isMop(inst)) return ill(h, inst);
                        x[rd] = 0;
                    } else if (csrOp(r, h, inst) == .trap) return .trap;
                },
                0x2f => { // AMO
                    const ok = switch (f3) {
                        2 => try amo(r, h, m, u32, inst),
                        3 => try amo(r, h, m, u64, inst),
                        else => return ill(h, inst),
                    };
                    if (!ok) return .trap;
                },
                0x07, 0x27 => if (!try fpMem(r, h, m, inst)) return .trap, // FLW/FLD/FSW/FSD
                0x43, 0x47, 0x4b, 0x4f => { // FMADD FMSUB FNMSUB FNMADD
                    const rm = resolveRm(r, f3) orelse return ill(h, inst);
                    switch (f7 & 3) {
                        0 => fmaOp(u32, r, inst, rm),
                        1 => fmaOp(u64, r, inst, rm),
                        else => return ill(h, inst),
                    }
                },
                0x53 => if (opFp(r, h, inst) == .trap) return .trap,
                else => return ill(h, inst),
            }
            r.pc = next;
            x[0] = 0;
            return exit;
        }

        /// Zicbom / Zicboz (block size 64 bytes); false = illegal (recorded).
        /// cbo.clean and cbo.flush only check that a load or a store to the
        /// block would be permitted (memory is coherent and has no cache to
        /// write back), and report a store page fault if neither is, as the
        /// spec says. cbo.zero zeroes the aligned 64-byte block through the
        /// memory's write path (permissions, A/D, decoded-code tracking).
        /// cbo.inval is illegal: Linux leaves senvcfg.CBIE at 0 for user
        /// mode. rd must be x0; other immediates are reserved.
        noinline fn cbo(r: *Regs, h: *Hart, m: *M, inst: u32) Error!bool {
            const addr = r.x[(inst >> 15) & 31];
            if ((inst >> 7) & 31 != 0) return ill(h, inst) != .trap;
            switch (inst >> 20) {
                1, 2 => { // cbo.clean, cbo.flush
                    if (!has(h, .zicbom)) return ill(h, inst) != .trap;
                    if (m.load(u8, addr)) |_| {} else |_| _ = try m.rmwPtr(u8, addr);
                },
                4 => { // cbo.zero
                    if (!has(h, .zicboz)) return ill(h, inst) != .trap;
                    const p = try m.rmwPtr([64]u8, addr & ~@as(u64, 63));
                    // volatile: no memset call in the freestanding object
                    const q: *allowzero volatile align(1) [8]u64 = @ptrCast(p);
                    inline for (0..8) |k| q[k] = 0;
                },
                else => return ill(h, inst) != .trap, // cbo.inval (0), reserved
            }
            return true;
        }

        /// Returns false (trap recorded) for illegal/misaligned.
        noinline fn amo(r: *Regs, h: *Hart, m: *M, comptime T: type, inst: u32) Error!bool {
            const rd = (inst >> 7) & 31;
            const rs1 = (inst >> 15) & 31;
            const rs2 = (inst >> 20) & 31;
            const f5 = inst >> 27;
            switch (f5) {
                0x02, 0x03, 0x01, 0x00, 0x04, 0x0c, 0x08, 0x10, 0x14, 0x18, 0x1c => {},
                else => return ill(h, inst) != .trap,
            }
            const addr = r.x[rs1];
            if (addr % @sizeOf(T) != 0) {
                h.trap = .misaligned;
                h.trap_val = addr;
                return false;
            }
            const ext = struct {
                inline fn f(v: T) u64 {
                    return if (T == u32) sx32(v) else v;
                }
            }.f;
            if (smp) return amoShared(r, h, m, T, inst, f5, rd, rs2, addr);
            switch (f5) {
                0x02 => { // LR
                    if (rs2 != 0) return ill(h, inst) != .trap;
                    const v = try m.load(T, addr);
                    r.x[rd] = ext(v);
                    h.resv = addr;
                },
                0x03 => { // SC
                    if (h.resv == addr) {
                        try m.store(T, addr, @truncate(r.x[rs2]));
                        r.x[rd] = 0;
                    } else r.x[rd] = 1;
                    h.resv = no_resv;
                },
                else => {
                    const p = try m.rmwPtr(T, addr);
                    const old = p.*;
                    p.* = amoOp(T, f5, old, @truncate(r.x[rs2]));
                    r.x[rd] = ext(old);
                },
            }
            return true;
        }

        /// amo() when harts share the memory (smp): every AMO is one
        /// atomic instruction, LR an atomic load whose value SC
        /// compare-and-swaps against (an ABA store between them goes
        /// unnoticed, as in QEMU's emulation), and all of them are
        /// seq_cst, which covers the aq and rl bits.
        noinline fn amoShared(r: *Regs, h: *Hart, m: *M, comptime T: type, inst: u32, f5: u32, rd: u32, rs2: u32, addr: u64) Error!bool {
            const S = @Int(.signed, @bitSizeOf(T));
            const src: T = @truncate(r.x[rs2]);
            const old: T = switch (f5) {
                0x02 => blk: { // LR
                    if (rs2 != 0) return ill(h, inst) != .trap;
                    const p = try readPtr(m, T, addr);
                    const v = @atomicLoad(T, p, .seq_cst);
                    h.resv = addr;
                    h.resv_val = v;
                    break :blk v;
                },
                0x03 => { // SC
                    var ok = false;
                    if (h.resv == addr) {
                        const p = shared(T, try m.rmwPtr(T, addr));
                        ok = @cmpxchgStrong(T, p, @truncate(h.resv_val), src, .seq_cst, .seq_cst) == null;
                    }
                    r.x[rd] = @intFromBool(!ok);
                    h.resv = no_resv;
                    return true;
                },
                else => blk: {
                    const p = shared(T, try m.rmwPtr(T, addr));
                    const ps: *S = @ptrCast(p);
                    break :blk switch (f5) {
                        0x01 => @atomicRmw(T, p, .Xchg, src, .seq_cst),
                        0x00 => @atomicRmw(T, p, .Add, src, .seq_cst),
                        0x04 => @atomicRmw(T, p, .Xor, src, .seq_cst),
                        0x0c => @atomicRmw(T, p, .And, src, .seq_cst),
                        0x08 => @atomicRmw(T, p, .Or, src, .seq_cst),
                        0x10 => @bitCast(@atomicRmw(S, ps, .Min, @bitCast(src), .seq_cst)),
                        0x14 => @bitCast(@atomicRmw(S, ps, .Max, @bitCast(src), .seq_cst)),
                        0x18 => @atomicRmw(T, p, .Min, src, .seq_cst),
                        0x1c => @atomicRmw(T, p, .Max, src, .seq_cst),
                        else => unreachable,
                    };
                },
            };
            r.x[rd] = if (T == u32) sx32(old) else old;
            return true;
        }

        /// The host pointer behind a guest read of `addr` (aligned, in-page),
        /// for an atomic load: the memory's readPtr, else its rmwPtr.
        inline fn readPtr(m: *M, comptime T: type, addr: u64) Error!*T {
            if (@hasDecl(M, "readPtr")) return shared(T, try m.readPtr(T, addr));
            return shared(T, try m.rmwPtr(T, addr));
        }

        /// An aligned pointer for the atomic builtins (AMO addresses are
        /// checked for alignment, and pages are aligned on the host).
        inline fn shared(comptime T: type, p: anytype) *T {
            return @ptrFromInt(@intFromPtr(p));
        }

        noinline fn fpMem(r: *Regs, h: *Hart, m: *M, inst: u32) Error!bool {
            const rs1 = (inst >> 15) & 31;
            const rd = (inst >> 7) & 31;
            const rs2 = (inst >> 20) & 31;
            if (inst & 0x20 == 0) { // LOAD-FP
                const addr = r.x[rs1] +% immI(inst);
                r.f[rd] = switch ((inst >> 12) & 7) {
                    1 => if (has(h, .zfhmin)) boxH(try m.load(u16, addr)) else return ill(h, inst) != .trap, // flh
                    2 => box(try m.load(u32, addr)),
                    3 => try m.load(u64, addr),
                    else => return ill(h, inst) != .trap,
                };
            } else { // STORE-FP
                const addr = r.x[rs1] +% immS(inst);
                switch ((inst >> 12) & 7) {
                    1 => if (has(h, .zfhmin)) try m.store(u16, addr, @truncate(r.f[rs2])) else return ill(h, inst) != .trap, // fsh
                    2 => try m.store(u32, addr, @truncate(r.f[rs2])),
                    3 => try m.store(u64, addr, r.f[rs2]),
                    else => return ill(h, inst) != .trap,
                }
            }
            return true;
        }

        noinline fn stepC(r: *Regs, h: *Hart, m: *M, inst16: u16) Error!Exit {
            const i: u32 = inst16;
            const x = &r.x;
            const pc = r.pc;
            var next = pc +% 2;
            var exit: Exit = .next;
            const rdp = 8 + ((i >> 2) & 7); // rd' / rs2'
            const rs1p = 8 + ((i >> 7) & 7); // rs1' / rd'
            const rd = (i >> 7) & 31;
            const rs2 = (i >> 2) & 31;
            const imm6 = sext(((i >> 7) & 0x20) | ((i >> 2) & 0x1f), 6);
            const shamt: u6 = @truncate(((i >> 7) & 0x20) | ((i >> 2) & 0x1f));
            switch (((i & 3) << 3) | (i >> 13)) {
                // ---- quadrant 0
                0b00_000 => { // C.ADDI4SPN
                    const imm = ((i >> 7) & 0x30) | ((i >> 1) & 0x3c0) | ((i >> 4) & 0x4) | ((i >> 2) & 0x8);
                    if (imm == 0) return ill(h, i);
                    x[rdp] = x[2] +% imm;
                },
                0b00_001 => r.f[rdp] = try m.load(u64, x[rs1p] +% offD(i)), // C.FLD
                0b00_010 => { // C.LW
                    const off = ((i >> 7) & 0x38) | ((i >> 4) & 4) | ((i << 1) & 0x40);
                    x[rdp] = sx32(try m.load(u32, x[rs1p] +% off));
                },
                0b00_011 => x[rdp] = try m.load(u64, x[rs1p] +% offD(i)), // C.LD
                0b00_100 => { // Zcb: c.lbu, c.lhu, c.lh, c.sb, c.sh
                    if (!has(h, .zcb)) return ill(h, i);
                    const base = x[rs1p];
                    switch ((i >> 10) & 7) {
                        0 => x[rdp] = try m.load(u8, base +% zcbOffB(i)),
                        1 => {
                            const v = try m.load(u16, base +% zcbOffH(i));
                            x[rdp] = if (i & 0x40 == 0) v else sext(v, 16);
                        },
                        2 => try m.store(u8, base +% zcbOffB(i), @truncate(x[rdp])),
                        3 => if (i & 0x40 == 0) try m.store(u16, base +% zcbOffH(i), @truncate(x[rdp])) else return ill(h, i),
                        else => return ill(h, i),
                    }
                },
                0b00_101 => try m.store(u64, x[rs1p] +% offD(i), r.f[rdp]), // C.FSD
                0b00_110 => { // C.SW
                    const off = ((i >> 7) & 0x38) | ((i >> 4) & 4) | ((i << 1) & 0x40);
                    try m.store(u32, x[rs1p] +% off, @truncate(x[rdp]));
                },
                0b00_111 => try m.store(u64, x[rs1p] +% offD(i), x[rdp]), // C.SD
                // ---- quadrant 1
                0b01_000 => x[rd] = x[rd] +% imm6, // C.ADDI / C.NOP
                0b01_001 => { // C.ADDIW
                    if (rd == 0) return ill(h, i);
                    x[rd] = sx32(lo32(x[rd]) +% lo32(imm6));
                },
                0b01_010 => x[rd] = imm6, // C.LI
                0b01_011 => {
                    if (rd == 2) { // C.ADDI16SP
                        const v = ((i >> 3) & 0x200) | ((i >> 2) & 0x10) | ((i << 1) & 0x40) | ((i << 4) & 0x180) | ((i << 3) & 0x20);
                        if (v == 0) return ill(h, i);
                        x[2] = x[2] +% sext(v, 10);
                    } else if (imm6 != 0) { // C.LUI
                        x[rd] = imm6 << 12;
                    } else if (!isCMop(i) or !has(h, .zcmop)) return ill(h, i); // else c.mop.N (Zcmop)
                },
                0b01_100 => switch ((i >> 10) & 3) {
                    0 => x[rs1p] = x[rs1p] >> shamt, // C.SRLI
                    1 => x[rs1p] = uns(sgn(x[rs1p]) >> shamt), // C.SRAI
                    2 => x[rs1p] = x[rs1p] & imm6, // C.ANDI
                    3 => {
                        const a = x[rs1p];
                        const b = x[rdp];
                        x[rs1p] = if (i & (1 << 12) == 0) switch ((i >> 5) & 3) {
                            0 => a -% b,
                            1 => a ^ b,
                            2 => a | b,
                            3 => a & b,
                            else => unreachable,
                        } else switch ((i >> 5) & 3) {
                            0 => sx32(lo32(a) -% lo32(b)),
                            1 => sx32(lo32(a) +% lo32(b)),
                            2 => if (has(h, .zcb)) a *% b else return ill(h, i), // c.mul
                            // c.zext.b ... c.not (Zcb)
                            else => if (has(h, .zcb)) zcbUnary(h.isa, i, a) orelse return ill(h, i) else return ill(h, i),
                        };
                    },
                    else => unreachable,
                },
                0b01_101 => { // C.J
                    const off = ((i >> 1) & 0x800) | ((i >> 7) & 0x10) | ((i >> 1) & 0x300) | ((i << 2) & 0x400) |
                        ((i >> 1) & 0x40) | ((i << 1) & 0x80) | ((i >> 2) & 0xe) | ((i << 3) & 0x20);
                    next = pc +% sext(off, 12);
                    exit = .jump;
                },
                0b01_110, 0b01_111 => { // C.BEQZ / C.BNEZ
                    const off = ((i >> 4) & 0x100) | ((i >> 7) & 0x18) | ((i << 1) & 0xc0) | ((i >> 2) & 0x6) | ((i << 3) & 0x20);
                    const z = x[rs1p] == 0;
                    if (z == ((i >> 13) == 0b110)) {
                        next = pc +% sext(off, 9);
                        exit = .jump;
                    }
                },
                // ---- quadrant 2
                0b10_000 => x[rd] = x[rd] << shamt, // C.SLLI
                0b10_001 => r.f[rd] = try m.load(u64, x[2] +% offLdsp(i)), // C.FLDSP
                0b10_010 => { // C.LWSP
                    if (rd == 0) return ill(h, i);
                    const off = ((i >> 7) & 0x20) | ((i >> 2) & 0x1c) | ((i << 4) & 0xc0);
                    x[rd] = sx32(try m.load(u32, x[2] +% off));
                },
                0b10_011 => { // C.LDSP
                    if (rd == 0) return ill(h, i);
                    x[rd] = try m.load(u64, x[2] +% offLdsp(i));
                },
                0b10_100 => {
                    if (i & (1 << 12) == 0) {
                        if (rs2 == 0) { // C.JR
                            if (rd == 0) return ill(h, i);
                            next = x[rd] & ~@as(u64, 1);
                            exit = .jump;
                        } else x[rd] = x[rs2]; // C.MV
                    } else {
                        if (rs2 == 0) {
                            if (rd == 0) { // C.EBREAK
                                h.trap = .breakpoint;
                                return .trap;
                            }
                            const tgt = x[rd] & ~@as(u64, 1); // C.JALR
                            x[1] = next;
                            next = tgt;
                            exit = .jump;
                        } else x[rd] = x[rd] +% x[rs2]; // C.ADD (rd = 0: a HINT, e.g. c.ntl.*)
                    }
                },
                0b10_101 => try m.store(u64, x[2] +% offSdsp(i), r.f[rs2]), // C.FSDSP
                0b10_110 => { // C.SWSP
                    const off = ((i >> 7) & 0x3c) | ((i >> 1) & 0xc0);
                    try m.store(u32, x[2] +% off, @truncate(x[rs2]));
                },
                0b10_111 => try m.store(u64, x[2] +% offSdsp(i), x[rs2]), // C.SDSP
                else => return ill(h, i),
            }
            r.pc = next;
            x[0] = 0;
            return exit;
        }
    };
}
