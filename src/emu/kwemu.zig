// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! kwemu: the guest CPU emulator as a freestanding library implementing
//! include/kw_emu.h. No allocator and no global mutable state: everything
//! lives in the caller's `struct kw_cpu` (KW_CPU_SIZE bytes) and
//! `struct kw_regs`.
//!
//! MMU: walks Sv39-layout page tables straight out of linear memory
//! (`phys_base + pa`), like hardware, and caches successful translations in
//! three direct-mapped TLBs (read / write / exec) inside kw_cpu. The
//! emulator never writes PTEs: A=0 (or D=0 on a store) raises KW_EV_FAULT.
//! Only translations that were fully permitted are cached, so the kernel
//! must call the flush hooks when it downgrades or removes a PTE (as on real
//! hardware); upgrades need no flush. Linear address 0 is valid
//! (phys_base + pa may be 0): all guest-memory pointers are allowzero.
//!
//! Execution: a predecoded basic-block cache ("blocks", see the comment
//! above `Block`) with a threaded `switch` over compact ops; anything
//! uncommon is handed to the generic interpreter in cpu/core.zig.

const std = @import("std");
const core = @import("../cpu/core.zig");
const c = @import("kw_h"); // include/kw_emu.h via translate-c

pub const Regs = core.Regs;
pub const abi_version: u32 = 8;
pub const cpu_size: usize = 8 << 20;

pub const Event = extern struct {
    kind: u32 = 0,
    access: u32 = 0,
    addr: u64 = 0,
    insn: u64 = 0,
};

const page_shift = 12;
const page_size: u64 = 1 << page_shift;
const page_mask: u64 = page_size - 1;
/// Exec TLB sets.
const tlb_bits = 8;
const tlb_n = 1 << tlb_bits;
/// Data TLB entries (read and write each). The JIT derives its index mask
/// from the array length.
const dtlb_bits = 10;
const dtlb_n = 1 << dtlb_bits;
const invalid_tag = std.math.maxInt(u64);
/// Write-TLB tag flag: the page holds decoded code, so stores must take the
/// slow path (which invalidates the affected blocks). Never matches a vpn.
const code_flag: u64 = 1 << 63;

/// Data TLB entry: host address = va +% add.
const Tlb = extern struct { tag: u64, add: u64 };
/// Exec TLB entry. `gen` is unique per fill (0 = invalid); a block is only
/// trusted on the fast path while the exec entry for its page still has
/// the generation the block was validated under. The exec TLB is 2-way set
/// associative (`tlb_n` sets, entries 2i and 2i+1, the most recently filled
/// first): hot code pages whose vpns collide would otherwise refill each
/// other, and every refill gets a new generation, so all their blocks would
/// be revalidated again and again.
const XTlb = extern struct { tag: u64, add: u64, gen: u64, _pad: u64 = 0 };

const pte_v: u64 = 1 << 0;
const pte_r: u64 = 1 << 1;
const pte_w: u64 = 1 << 2;
const pte_x: u64 = 1 << 3;
const pte_u: u64 = 1 << 4;
const pte_a: u64 = 1 << 6;
const pte_d: u64 = 1 << 7;
const ppn_mask: u64 = (1 << 44) - 1;

// ---- decoded-block cache ----------------------------------------------------------
//
// A block (a superblock: single entry, side exits) is a run of up to
// `max_block` guest instructions inside one page in execution order:
// conditional branches are side exits and direct jumps within the page are
// followed; it ends at an indirect jump, a jump to another page or back to
// the block start, an ecall/ebreak, or the page end. Each instruction
// becomes one 16-byte `Op` (compressed ones are expanded into the same
// ops), so op index == retired-instruction count. Blocks are found through
// a 2-way set-associative table keyed by the virtual pc and are trusted
// without checks only while
//   block.tgen == exec-TLB[pc page].gen.
// Every exec-TLB fill gets a fresh generation, and kw_flush_tlb_all,
// kw_flush_tlb_range (for that page), kw_set_pgd and FENCE.I all retire
// generations. A block whose generation is stale is revalidated before it
// runs: same virtual pc, same host (physical) address and the same raw
// instruction bits (each op keeps its raw instruction); otherwise it is
// re-decoded. So remapping a VA, COW, page reuse and code rewritten by the
// kernel can never run stale code after the flush the kernel must issue
// anyway (or after a guest FENCE.I).
//
// Guest stores are tracked exactly: pages holding decoded code are entered
// in `marks` (a hashed set of physical pages with a 64-byte-chunk bitmap),
// and write-TLB entries of such pages carry `code_flag` so stores take the
// slow path. A store hitting a marked chunk retires the generations of
// every exec mapping of that page and ends the current block right after
// the store, so self-modifying code is seen at the next instruction.

const max_block = 64;
/// Block table: 2-way set associative (a pair of hot blocks whose pcs
/// collide must not evict each other forever).
const nsets = 16384;
const nblocks = 2 * nsets;
/// Op arena (16 bytes per op, 6 MiB). With 128K ops, node's startup
/// filled it every ~2M instructions (about 270 resets per `npx --version`,
/// each freeing every compiled block); 384K ops cut npx by ~7%.
const nops = 384 * 1024;
const nmarks = 4096;
const no_tgen = std.math.maxInt(u64);
const mark_wild = std.math.maxInt(u64);

const exec = @import("exec.zig");
const Op = exec.Op;
const jit = @import("jit.zig");

pub const Block = extern struct {
    pc: u64,
    tgen: u64,
    /// Host address of the first instruction.
    host: u64,
    /// pc after the last instruction (terminator fall-through / link value).
    end_pc: u64,
    op: u32,
    /// Ops (incl. a trailing `goto` when the block does not end in a jump).
    n: u16,
    /// Guest instructions.
    ninsn: u16,
    /// 64-byte chunks of the page the block's instructions occupy.
    mask: u64,
    /// JIT tier (-Dkwemu-jit): compile countdown / compiled slot (see
    /// jit.zig); empty otherwise.
    jx: jit.BlockState = .{},
};

const Mark = extern struct { key: u64, mask: u64 };

pub const stats_on = @import("kwemu_options").stats;

/// Room for this many op kinds (exec.H) in the per-op counters below.
pub const max_ops = 192;

pub const Stats = extern struct {
    lookups_slow: u64 = 0,
    revalidated: u64 = 0,
    decoded: u64 = 0,
    resets: u64 = 0,
    blocks: u64 = 0,
    block_insns: u64 = 0,
    single_steps: u64 = 0,
    walks_r: u64 = 0,
    walks_w: u64 = 0,
    walks_x: u64 = 0,
    generic_ops: u64 = 0,
    /// Executed ops per handler (exec.H); with the JIT tier, interpreted
    /// ops only. Room for `max_ops` kinds (harness.zig reads this layout).
    op_hist: [max_ops]u64 = @splat(0),
    /// JIT tier counters; present only with -Dkwemu-stats, so the layout
    /// of struct kw_cpu without it is what it always was.
    jit: if (stats_on) JitStats else extern struct {} = .{},
};

pub const JitStats = extern struct {
    /// Instructions retired by compiled code, and hand-backs (compiled
    /// code returning "handed back at op k").
    insns: u64 = 0,
    handbacks: u64 = 0,
    /// Hand-backs per handler of the op handed back (exec.H).
    hb: [max_ops]u64 = @splat(0),
    /// `generic` hand-backs by instruction class (see `genericClass`).
    hb_gen: [40]u64 = @splat(0),
    /// How compiled code is entered and left, regions included (see jit.Jx).
    jx: [64]u64 = @splat(0),
};

/// Bucket of a `generic` instruction for JitStats.hb_gen: OP-FP funct5
/// (0..31), SYSTEM (32), AMO (33), MISC-MEM (34), FMA (35), FP load/store
/// (36), anything else (37).
pub fn genericClass(raw: u32) usize {
    return switch (raw & 0x7f) {
        0x53 => raw >> 27,
        0x73 => 32,
        0x2f => 33,
        0x0f => 34,
        0x43, 0x47, 0x4b, 0x4f => 35,
        0x07, 0x27 => 36,
        else => 37,
    };
}

pub inline fn count(cpu: *Cpu, comptime field: []const u8, n: u64) void {
    if (stats_on) @field(cpu.priv.stats, field) += n;
}

/// Emulator-private part of struct kw_cpu.
const Priv = extern struct {
    hart: core.Hart,
    fault_addr: u64,
    fault_access: u32,
    /// Set by a store that hit decoded code / by FENCE.I: end the block.
    smc: u32,
    gen: u64,
    ops_used: u64,
    /// Counters, maintained only with -Dkwemu-stats (see `Stats`).
    stats: Stats,
    tlb_r: [dtlb_n]Tlb,
    tlb_w: [dtlb_n]Tlb,
    tlb_x: [2 * tlb_n]XTlb,
    marks: [nmarks]Mark,
    blocks: [nblocks]Block,
    /// Per set: the way the next new block replaces.
    victim: [nsets]u8,
    ops: [nops]Op,
    /// JIT tier bookkeeping (-Dkwemu-jit); empty otherwise.
    jit: jit.State,
};

inline fn hostLoad(comptime T: type, addr: u64) T {
    return std.mem.littleToNative(T, @as(*allowzero align(1) const T, @ptrFromInt(@as(usize, @intCast(addr)))).*);
}
inline fn hostStore(comptime T: type, addr: u64, v: T) void {
    @as(*allowzero align(1) T, @ptrFromInt(@as(usize, @intCast(addr)))).* = std.mem.nativeToLittle(T, v);
}
inline fn insnLen(raw: u32) u64 {
    return if (raw & 3 == 3) 4 else 2;
}
/// Address of the instruction after `op` (at pc) in block order.
pub inline fn nextPc(op: Op, pc: u64) u64 {
    return if (op.h == .jal_c) exec.jalTarget(op.raw, pc) else pc +% insnLen(op.raw);
}

inline fn chunkMask(off: u64, len: u64) u64 {
    const lo: u6 = @intCast(off >> 6);
    const hi: u6 = @intCast((off + len - 1) >> 6);
    const top: u64 = if (hi == 63) std.math.maxInt(u64) else (@as(u64, 2) << hi) - 1;
    return top & ~((@as(u64, 1) << lo) - 1);
}
/// Index of way 0 of pc's set (way 1 follows it). Uses pc bits 1..28
/// (pc >> 16 instead of pc >> 15 left bit 15 out, so in every 64 KiB of
/// code each pc shared its set with pc ^ 0x8000, and a third hot block in
/// such a set made the three evict each other until the op arena reset).
pub inline fn blockSet(pc: u64) usize {
    return @intCast((((pc >> 1) ^ (pc >> 15)) & (nsets - 1)) * 2);
}

pub const Cpu = extern struct {
    phys_base: u64,
    pgd: u64,
    irq_pending: ?*const volatile u32,
    budget: u64,
    icount: u64,
    ev: Event,
    /// 1 while kwemu compiles (jit.windowOpen): another CPU may then set
    /// `flush_all` instead of waiting for this one's flush.
    jit_busy: u32,
    flush_all: u32,
    priv: Priv,

    // ---- TLB ------------------------------------------------------------------

    pub fn flushAll(self: *Cpu) void {
        // Volatile stores: keep LLVM from turning this into a memset call.
        inline for (.{ &self.priv.tlb_r, &self.priv.tlb_w }) |tlb| {
            const p: [*]volatile Tlb = tlb;
            for (0..dtlb_n) |i| p[i].tag = invalid_tag;
        }
        const x: [*]volatile XTlb = &self.priv.tlb_x;
        for (0..2 * tlb_n) |i| {
            x[i].tag = invalid_tag;
            x[i].gen = 0;
        }
    }

    pub fn flushRange(self: *Cpu, start: u64, end: u64) void {
        if (end <= start) return;
        const first = start >> page_shift;
        const last = (end - 1) >> page_shift;
        if (last - first >= tlb_n) return self.flushAll();
        var vpn = first;
        while (true) : (vpn += 1) {
            const i: usize = @intCast(vpn & (tlb_n - 1));
            const d: usize = @intCast(vpn & (dtlb_n - 1));
            if (self.priv.tlb_r[d].tag == vpn) self.priv.tlb_r[d].tag = invalid_tag;
            if (self.priv.tlb_w[d].tag & ~code_flag == vpn) self.priv.tlb_w[d].tag = invalid_tag;
            for (self.priv.tlb_x[2 * i ..][0..2]) |*x| {
                if (x.tag == vpn) {
                    x.tag = invalid_tag;
                    x.gen = 0;
                }
            }
            if (vpn == last) break;
        }
    }

    /// FENCE.I: every block must be revalidated before it runs again.
    pub fn fenceI(self: *Cpu) void {
        for (&self.priv.tlb_x) |*e| {
            if (e.gen != 0) e.gen = self.newGen();
        }
        self.priv.smc = 1;
    }

    inline fn newGen(self: *Cpu) u64 {
        self.priv.gen += 1;
        return self.priv.gen;
    }

    // ---- page-table walk ----------------------------------------------------

    fn fault(self: *Cpu, va: u64, access: core.Access) core.Error {
        @branchHint(.cold);
        self.priv.fault_addr = va;
        self.priv.fault_access = @intFromEnum(access);
        return error.PageFault;
    }

    /// Walk the page table for `va` and fill the TLB. Returns the host
    /// address of the page.
    noinline fn translate(self: *Cpu, va: u64, access: core.Access) core.Error!u64 {
        switch (access) {
            .read => count(self, "walks_r", 1),
            .write => count(self, "walks_w", 1),
            .exec => count(self, "walks_x", 1),
        }
        // Sv39: bits 63..39 must equal bit 38.
        const top = va >> 38;
        if (top != 0 and top != (1 << 26) - 1) return self.fault(va, access);
        var table = self.pgd;
        var level: u6 = 2;
        const pte: u64 = while (true) : (level -= 1) {
            const idx = (va >> (page_shift + 9 * @as(u6, level))) & 511;
            const e = hostLoad(u64, self.phys_base +% table +% idx * 8);
            if (e & pte_v == 0) return self.fault(va, access);
            if (e & (pte_r | pte_w | pte_x) != 0) {
                if (level != 0) return self.fault(va, access); // no superpages
                break e;
            }
            if (level == 0) return self.fault(va, access);
            table = ((e >> 10) & ppn_mask) << page_shift;
        };
        const need: u64 = switch (access) {
            .read => pte_r | pte_u | pte_a,
            .write => pte_w | pte_u | pte_a | pte_d,
            .exec => pte_x | pte_u | pte_a,
        };
        if (pte & need != need) return self.fault(va, access);
        if (pte & (pte_w | pte_r) == pte_w) return self.fault(va, access); // reserved
        const host = self.phys_base +% (((pte >> 10) & ppn_mask) << page_shift);
        const vpn = va >> page_shift;
        const i: usize = @intCast(vpn & (tlb_n - 1));
        const add = host -% (vpn << page_shift);
        switch (access) {
            .read => self.priv.tlb_r[@intCast(vpn & (dtlb_n - 1))] = .{ .tag = vpn, .add = add },
            .write => self.priv.tlb_w[@intCast(vpn & (dtlb_n - 1))] = .{ .tag = if (self.isMarked(host)) vpn | code_flag else vpn, .add = add },
            .exec => {
                const x = self.priv.tlb_x[2 * i ..][0..2];
                if (x[0].tag != invalid_tag) x[1] = x[0];
                x[0] = .{ .tag = vpn, .add = add, .gen = self.newGen() };
            },
        }
        return host;
    }

    /// Host address of `va` for a read (no straddle handling).
    inline fn readHost(self: *Cpu, va: u64) core.Error!u64 {
        const vpn = va >> page_shift;
        const e = &self.priv.tlb_r[@intCast(vpn & (dtlb_n - 1))];
        if (e.tag == vpn) return va +% e.add;
        return (try self.translate(va, .read)) + (va & page_mask);
    }

    /// Host address of `va` for an exec fetch.
    inline fn execHost(self: *Cpu, va: u64) core.Error!u64 {
        const vpn = va >> page_shift;
        const x = self.priv.tlb_x[2 * @as(usize, @intCast(vpn & (tlb_n - 1))) ..][0..2];
        if (x[0].tag == vpn) return va +% x[0].add;
        if (x[1].tag == vpn) return va +% x[1].add;
        return (try self.translate(va, .exec)) + (va & page_mask);
    }

    /// Generation of pc's exec-TLB entry (0 if it has none).
    inline fn execGen(self: *Cpu, pc: u64) u64 {
        const vpn = pc >> page_shift;
        const x = self.priv.tlb_x[2 * @as(usize, @intCast(vpn & (tlb_n - 1))) ..][0..2];
        return if (x[0].tag == vpn) x[0].gen else if (x[1].tag == vpn) x[1].gen else 0;
    }

    /// Generation of the exec-TLB entry of pc's page (0 if it has none).
    pub fn execGenOf(self: *Cpu, pc: u64) u64 {
        return self.execGen(pc);
    }

    /// Host address of `va` for a write of `len` bytes that stays in the
    /// page; handles stores into pages with decoded code.
    fn writeHost(self: *Cpu, va: u64, len: u64) core.Error!u64 {
        const vpn = va >> page_shift;
        const i: usize = @intCast(vpn & (dtlb_n - 1));
        const e = &self.priv.tlb_w[i];
        if (e.tag == vpn) return va +% e.add;
        if (e.tag != vpn | code_flag) _ = try self.translate(va, .write);
        const host = va +% e.add;
        if (e.tag & code_flag != 0 and !self.codeStore(host, len)) e.tag = vpn; // page has no code left
        return host;
    }

    // ---- decoded-code tracking ------------------------------------------------

    inline fn markSlot(self: *Cpu, host_page: u64) *Mark {
        return &self.priv.marks[@intCast((host_page >> page_shift) & (nmarks - 1))];
    }

    fn isMarked(self: *Cpu, host: u64) bool {
        const page = host & ~page_mask;
        const m = self.markSlot(page);
        return m.mask != 0 and (m.key == page | 1 or m.key == mark_wild);
    }

    /// Record that `mask` chunks of `page` hold decoded code.
    fn markCode(self: *Cpu, page: u64, mask: u64) void {
        const m = self.markSlot(page);
        const key = page | 1;
        if (m.key == key) {
            // Only when the slot is this page's alone: then its write-TLB
            // entries were flagged when these bits were set (or at fill).
            // In a wild slot the bits may be another page's, and this
            // page's entries may predate them.
            if (m.mask & mask == mask) return;
        } else if (m.key != mark_wild) {
            if (m.key == 0 or m.mask == 0) {
                m.key = key;
                m.mask = 0;
            } else m.key = mark_wild;
        }
        m.mask |= mask;
        // Stores to this page must now take the slow path.
        for (&self.priv.tlb_w) |*e| {
            if (e.tag != invalid_tag and e.tag & code_flag == 0 and (e.tag << page_shift) +% e.add == page)
                e.tag |= code_flag;
        }
    }

    /// A store of `len` bytes at host address `host` (in a code-flagged
    /// page). Invalidates the blocks it may hit. Returns whether the page
    /// still holds marked code.
    noinline fn codeStore(self: *Cpu, host: u64, len: u64) bool {
        const page = host & ~page_mask;
        const m = self.markSlot(page);
        if (m.key != page | 1 and m.key != mark_wild) return false;
        const bits = chunkMask(host & page_mask, len);
        if (m.mask & bits != 0) {
            m.mask &= ~bits;
            for (&self.priv.tlb_x) |*e| {
                if (e.gen != 0 and (m.key == mark_wild or (e.tag << page_shift) +% e.add == page))
                    e.gen = self.newGen();
            }
            self.priv.smc = 1;
        }
        return m.mask != 0;
    }

    pub fn resetCache(self: *Cpu) void {
        count(self, "resets", 1);
        if (jit.enabled) jit.releaseAll(self);
        // Volatile stores: no memset import in the wasm object.
        const bs: [*]volatile Block = &self.priv.blocks;
        for (0..nblocks) |i| {
            bs[i].pc = std.math.maxInt(u64);
            bs[i].tgen = no_tgen;
        }
        const ms: [*]volatile Mark = &self.priv.marks;
        for (0..nmarks) |i| {
            ms[i].key = 0;
            ms[i].mask = 0;
        }
        self.priv.ops_used = 0;
    }

    // ---- memory interface used by core.Interp and the block executor ---------

    pub inline fn load(self: *Cpu, comptime T: type, va: u64) core.Error!T {
        const e = &self.priv.tlb_r[@intCast((va >> page_shift) & (dtlb_n - 1))];
        if (e.tag == (va +% (@sizeOf(T) - 1)) >> page_shift) return hostLoad(T, va +% e.add);
        return self.loadSlow(T, va);
    }

    noinline fn loadSlow(self: *Cpu, comptime T: type, va: u64) core.Error!T {
        if ((va & page_mask) + @sizeOf(T) <= page_size) return hostLoad(T, try self.readHost(va));
        const b0 = try self.readHost(va);
        const second = (va | page_mask) +% 1;
        const b1 = try self.readHost(second);
        const n0: usize = @intCast(second - va);
        var buf: [@sizeOf(T)]u8 = undefined;
        for (0..@sizeOf(T)) |k| buf[k] = if (k < n0) hostLoad(u8, b0 + k) else hostLoad(u8, b1 + (k - n0));
        return std.mem.readInt(T, &buf, .little);
    }

    /// Returns true if the store hit decoded code (the block must end).
    pub inline fn storeChk(self: *Cpu, comptime T: type, va: u64, v: T) core.Error!bool {
        const e = &self.priv.tlb_w[@intCast((va >> page_shift) & (dtlb_n - 1))];
        if (e.tag == (va +% (@sizeOf(T) - 1)) >> page_shift) {
            hostStore(T, va +% e.add, v);
            return false;
        }
        try self.storeSlow(T, va, v);
        return self.priv.smc != 0;
    }

    pub inline fn store(self: *Cpu, comptime T: type, va: u64, v: T) core.Error!void {
        _ = try self.storeChk(T, va, v);
    }

    noinline fn storeSlow(self: *Cpu, comptime T: type, va: u64, v: T) core.Error!void {
        const off = va & page_mask;
        if (off + @sizeOf(T) <= page_size) return hostStore(T, try self.writeHost(va, @sizeOf(T)), v);
        // Translate both pages first so a fault leaves memory untouched.
        const second = (va | page_mask) +% 1;
        const n0 = second - va;
        const b0 = try self.writeHost(va, n0);
        const b1 = try self.writeHost(second, @sizeOf(T) - n0);
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        for (0..@sizeOf(T)) |k| {
            if (k < n0) hostStore(u8, b0 + k, buf[k]) else hostStore(u8, b1 + (k - n0), buf[k]);
        }
    }

    pub inline fn fetch(self: *Cpu, va: u64) core.Error!u32 {
        const off = va & page_mask;
        const host = try self.execHost(va);
        if (off <= page_size - 4) return hostLoad(u32, host);
        return self.fetchSplit(host, va);
    }

    noinline fn fetchSplit(self: *Cpu, host: u64, va: u64) core.Error!u32 {
        const lo = hostLoad(u16, host);
        if (lo & 3 != 3) return lo;
        const b1 = try self.execHost(va +% 2);
        return @as(u32, lo) | (@as(u32, hostLoad(u16, b1)) << 16);
    }

    /// In-page read-modify-write (aligned atomics). W implies R in a valid PTE.
    /// For an atomic load (LR when harts share the memory): read permission, in-page.
    pub inline fn readPtr(self: *Cpu, comptime T: type, va: u64) core.Error!*allowzero align(1) T {
        return @ptrFromInt(@as(usize, @intCast(try self.readHost(va))));
    }

    pub inline fn rmwPtr(self: *Cpu, comptime T: type, va: u64) core.Error!*allowzero align(1) T {
        return @ptrFromInt(@as(usize, @intCast(try self.writeHost(va, @sizeOf(T)))));
    }

    // ---- block lookup / decode --------------------------------------------------

    inline fn lookup(self: *Cpu, pc: u64) core.Error!*Block {
        const set = blockSet(pc);
        // A generation is unique to one fill, so a block whose tgen equals
        // either entry of pc's exec-TLB set was validated under that live
        // fill of its own page.
        const x = self.priv.tlb_x[2 * @as(usize, @intCast((pc >> page_shift) & (tlb_n - 1))) ..][0..2];
        const g0 = x[0].gen;
        const g1 = x[1].gen;
        const b0 = &self.priv.blocks[set];
        if (b0.pc == pc and (b0.tgen == g0 or b0.tgen == g1)) return b0;
        const b1 = &self.priv.blocks[set + 1];
        if (b1.pc == pc and (b1.tgen == g0 or b1.tgen == g1)) return b1;
        return self.lookupSlow(set, pc);
    }

    noinline fn lookupSlow(self: *Cpu, set: usize, pc: u64) core.Error!*Block {
        count(self, "lookups_slow", 1);
        const host = try self.execHost(pc);
        const gen = self.execGen(pc);
        for (self.priv.blocks[set..][0..2]) |*b| {
            if (b.pc == pc and b.host == host and self.validate(b)) {
                b.tgen = gen;
                self.markCode(host & ~page_mask, b.mask);
                count(self, "revalidated", 1);
                return b;
            }
        }
        count(self, "decoded", 1);
        const v = &self.priv.victim[set / 2];
        // Reuse a way that already holds this pc (stale copy), else the victim.
        const way: usize = if (self.priv.blocks[set].pc == pc) 0 else if (self.priv.blocks[set + 1].pc == pc) 1 else blk: {
            const w = v.*;
            v.* ^= 1;
            break :blk w;
        };
        return self.decodeBlock(&self.priv.blocks[set + way], pc, host, gen);
    }

    /// Same pc, same host address, same raw instruction bits.
    fn validate(self: *Cpu, b: *const Block) bool {
        const page = b.host & ~page_mask;
        var pc = b.pc;
        for (self.priv.ops[b.op..][0..b.ninsn]) |op| {
            const h = page + (pc & page_mask);
            if (op.h == .straddle) return hostLoad(u16, h) == op.raw;
            if (op.raw & 3 == 3) {
                if (hostLoad(u32, h) != op.raw) return false;
            } else {
                if (hostLoad(u16, h) != op.raw) return false;
            }
            pc = nextPc(op, pc);
        }
        return true;
    }

    fn decodeBlock(self: *Cpu, b: *Block, pc: u64, host: u64, gen: u64) *Block {
        if (self.priv.ops_used + max_block + 1 > nops) self.resetCache();
        if (jit.enabled) jit.drop(self, b); // its code belongs to the old contents
        const start: u32 = @intCast(self.priv.ops_used);
        const ops = self.priv.ops[start..][0 .. max_block + 1];
        const page = host & ~page_mask;
        const vpage = pc & ~page_mask;
        var n: usize = 0;
        var cur = pc;
        var ends = false;
        var mask: u64 = 0;
        while (n < max_block) {
            const h = page + (cur & page_mask);
            const lo = hostLoad(u16, h);
            var inst: u32 = lo;
            if (lo & 3 == 3) {
                if (cur & page_mask == page_size - 2) { // straddles the page end
                    if (n == 0) { // a block of its own
                        ops[0] = .{ .h = .straddle, .raw = lo, .imm = pc };
                        mask = chunkMask(page_size - 2, 2);
                        n = 1;
                        cur +%= 4;
                    }
                    break;
                }
                inst = hostLoad(u32, h);
            }
            const len = insnLen(inst);
            var d = exec.decode(inst, cur, self.priv.hart.isa);
            mask |= chunkMask(cur & page_mask, len);
            const next = cur +% len;
            cur = next;
            ends = d.ends;
            // Superblock: keep going past conditional branches (side exits)
            // and direct jumps that stay in this page, except for branches
            // and jumps back to the block's own start: those end the block,
            // so the loop re-enters it directly (see `run`).
            if (ends and n + 1 < max_block) {
                if (exec.sideExit(d.op.h)) |hx| {
                    if (d.op.imm != pc) {
                        d.op.h = hx;
                        ends = false;
                    }
                } else if (d.op.h == .jal) {
                    const t = d.op.imm;
                    if (t & ~page_mask == vpage and t != pc) {
                        d.op = .{ .h = .jal_c, .rd = d.op.rd, .raw = inst, .imm = next };
                        cur = t;
                        ends = false;
                    }
                }
            }
            ops[n] = d.op;
            n += 1;
            if (ends or cur & page_mask == 0 or cur & ~page_mask != vpage) break;
        }
        const ninsn = n;
        if (!ends or ops[n - 1].h == .generic or ops[n - 1].h == .straddle) {
            ops[n] = .{ .h = .goto, .imm = cur };
            n += 1;
        }
        self.priv.ops_used += n;
        b.* = .{
            .pc = pc,
            .tgen = gen,
            .host = host,
            .end_pc = cur,
            .op = start,
            .n = @intCast(n),
            .ninsn = @intCast(ninsn),
            .mask = mask,
            .jx = if (jit.enabled) jit.newBlock(self) else .{},
        };
        self.markCode(page, b.mask);
        return b;
    }

    /// pc of the op `k` instructions into block `b`.
    fn pcAt(self: *Cpu, b: *const Block, k: usize) u64 {
        var pc = b.pc;
        for (self.priv.ops[b.op..][0..k]) |op| pc = nextPc(op, pc);
        return pc;
    }
};

comptime {
    // Layout must match include/kw_emu.h exactly.
    std.debug.assert(@sizeOf(usize) == 8); // pointer field in kw_cpu
    std.debug.assert(@sizeOf(Cpu) <= cpu_size);
    // harness.zig reads this layout
    std.debug.assert(@sizeOf(Stats) == (11 + 192 + (if (stats_on) 2 + 192 + 40 + 64 else 0)) * 8);
    if (stats_on) std.debug.assert(jit.Jx.end <= 64);
    std.debug.assert(cpu_size == c.KW_CPU_SIZE);
    std.debug.assert(abi_version == c.KW_ABI_VERSION);
    std.debug.assert(@alignOf(Cpu) == 8);
    std.debug.assert(@sizeOf(Op) == 16);
    for (.{ "phys_base", "pgd", "irq_pending", "budget", "icount", "ev", "jit_busy", "flush_all" }) |f|
        std.debug.assert(@offsetOf(Cpu, f) == @offsetOf(c.struct_kw_cpu, f));
    std.debug.assert(@offsetOf(Cpu, "priv") >= @sizeOf(c.struct_kw_cpu));
    std.debug.assert(@sizeOf(Event) == @sizeOf(c.struct_kw_event));
    for (.{ "kind", "access", "addr", "insn" }) |f|
        std.debug.assert(@offsetOf(Event, f) == @offsetOf(c.struct_kw_event, f));
    std.debug.assert(@sizeOf(Regs) == @sizeOf(c.struct_kw_regs));
    for (.{ "x", "pc", "f", "fcsr", "_pad" }) |f|
        std.debug.assert(@offsetOf(Regs, f) == @offsetOf(c.struct_kw_regs, f));
    // x[32] (the redirected x0 destination) is pc.
    std.debug.assert(@offsetOf(Regs, "pc") == 32 * 8);
    for (.{ "budget", "syscall", "fault", "illegal", "breakpoint", "misaligned", "interrupt" }, .{
        c.KW_EV_BUDGET, c.KW_EV_SYSCALL, c.KW_EV_FAULT, c.KW_EV_ILLEGAL, c.KW_EV_BREAKPOINT, c.KW_EV_MISALIGNED, c.KW_EV_INTERRUPT,
    }) |name, v| std.debug.assert(@intFromEnum(@field(core.Kind, name)) == v);
    std.debug.assert(@intFromEnum(core.Access.read) == c.KW_ACCESS_READ);
    std.debug.assert(@intFromEnum(core.Access.write) == c.KW_ACCESS_WRITE);
    std.debug.assert(@intFromEnum(core.Access.exec) == c.KW_ACCESS_EXEC);
    // Optional extensions: core.Ext matches the KW_ISA_* bits one to one.
    const exts = .{ "zba", "zbb", "zbc", "zbs", "zbkb", "zbkc", "zbkx", "zknd", "zkne", "zicond", "zcb", "zimop", "zcmop", "zicbom", "zicboz", "zawrs", "zfa", "zfhmin", "zihpm" };
    std.debug.assert(exts.len == @typeInfo(core.Ext).@"enum".field_names.len);
    for (exts, .{
        c.KW_ISA_ZBA,   c.KW_ISA_ZBB,    c.KW_ISA_ZBC,    c.KW_ISA_ZBS,   c.KW_ISA_ZBKB, c.KW_ISA_ZBKC,   c.KW_ISA_ZBKX,
        c.KW_ISA_ZKND,  c.KW_ISA_ZKNE,   c.KW_ISA_ZICOND, c.KW_ISA_ZCB,   c.KW_ISA_ZIMOP, c.KW_ISA_ZCMOP, c.KW_ISA_ZICBOM,
        c.KW_ISA_ZICBOZ, c.KW_ISA_ZAWRS, c.KW_ISA_ZFA,    c.KW_ISA_ZFHMIN, c.KW_ISA_ZIHPM,
    }) |name, v| std.debug.assert(core.bit(@field(core.Ext, name)) == v);
}

// ---- C ABI -----------------------------------------------------------------------

pub fn cpuInit(cpu: *Cpu) void {
    const words: [*]volatile u64 = @ptrCast(cpu);
    for (0..cpu_size / 8) |i| words[i] = 0;
    cpu.priv.hart = .{}; // all implemented extensions enabled
    cpu.priv.gen = 1;
    cpu.flushAll();
    cpu.resetCache();
    if (jit.enabled) jit.init(cpu);
}

fn event(cpu: *Cpu, kind: core.Kind, access: u32, addr: u64, insn: u64) u32 {
    cpu.ev = .{ .kind = @intFromEnum(kind), .access = access, .addr = addr, .insn = insn };
    return @intFromEnum(kind);
}

const I = core.Interp(Cpu);

noinline fn stepOne(cpu: *Cpu, regs: *Regs) core.Error!core.Exit {
    return I.step(regs, &cpu.priv.hart, cpu);
}

pub fn run(cpu: *Cpu, regs: *Regs) u32 {
    const start = cpu.budget;
    var left = start;
    defer {
        cpu.budget = left;
        cpu.icount +%= start - left;
    }
    const irq = cpu.irq_pending;
    if (irq) |p| if (p.* != 0) return event(cpu, .interrupt, 0, 0, 0);
    const x: [*]u64 = @ptrCast(&regs.x); // x[32] aliases regs.pc (see `Op`)
    const h = &cpu.priv.hart;
    // -Dkwemu-stats: how the last compiled pass left its block (jit.countExit).
    var xk: u32 = 0;
    var xb: *const Block = undefined;
    // JIT: pool entry of the region entered last, and whether its code left
    // through an exit (not a hand-back) towards the block looked up next.
    var xs: u32 = 0;
    var left_region = false;
    while (true) {
        if (left == 0) return event(cpu, .budget, 0, 0, 0);
        const b = cpu.lookup(regs.pc) catch
            return event(cpu, .fault, cpu.priv.fault_access, cpu.priv.fault_addr, 0);
        if (jit.enabled and left_region) {
            if (stats_on) jit.countNext(cpu, xk, xb, b, xs);
            left_region = false;
            // A grow compiled, and a flush came during the compile: look b
            // up again (see jit.windowClose).
            if (jit.noteExit(cpu, xs, b)) continue;
        }
        if (b.ninsn > left) {
            // Single-step: the budget ends inside this block.
            count(cpu, "single_steps", 1);
            const e = stepOne(cpu, regs) catch
                return event(cpu, .fault, cpu.priv.fault_access, cpu.priv.fault_addr, 0);
            cpu.priv.smc = 0;
            switch (e) {
                .next => left -= 1,
                .jump => {
                    left -= 1;
                    if (irq) |p| if (p.* != 0) return event(cpu, .interrupt, 0, 0, 0);
                },
                .trap => {
                    if (h.trap == .counter) {
                        core.finishCounter(regs, h, cpu.icount +% (start - left));
                        left -= 1;
                        continue;
                    }
                    if (h.trap == .syscall) left -= 1; // ecall retires
                    return trapEvent(cpu, regs);
                },
            }
            continue;
        }
        var blk = b;
        count(cpu, "blocks", 1);
        count(cpu, "block_insns", blk.ninsn);
        left -= blk.ninsn;
        var first: [*]const Op = cpu.priv.ops[blk.op..].ptr;
        var o = first;
        // JIT: self-loop passes continue while left >= lim (see jit.loopLimit).
        var lim: u64 = blk.ninsn;
        const entry_left = left;
        if (jit.enabled) {
            const go = jit.ready(cpu, blk);
            if (go == .again) {
                // It compiled, and a flush came during the compile: blk may
                // be gone. Nothing of it ran; take it back and look it up
                // again (jit.windowClose).
                left += blk.ninsn;
                continue;
            }
            const compiled = go == .compiled;
            if (compiled) {
                // Runs this pass (and further self-loop passes), or hands
                // op `code` back to the interpreter for the rest of it.
                const jl = @min(left, jit.max_jl);
                xs = jit.slotIndex(blk);
                const ret = jit.enter(cpu, blk, x, jl);
                left = left - jl + (ret >> 8);
                // A region charges every further member in full before it
                // runs (like blk above); `code` refers to the last one.
                blk = jit.lastBlock(cpu);
                first = cpu.priv.ops[blk.op..].ptr;
                const code: u32 = @intCast(ret & 0xff);
                if (stats_on) {
                    jitStats(cpu, b, blk, jl -% (ret >> 8), code);
                    xk = jit.countExit(cpu, blk, code);
                    xb = blk;
                }
                if (code >= jit.code_done) {
                    left_region = true;
                    if (code >= jit.code_side) left += blk.ninsn - (code - jit.code_side + 1);
                    if (irq) |p| if (p.* != 0) return event(cpu, .interrupt, 0, 0, 0);
                    continue;
                }
                jit.handedBack(cpu);
                o = first + code;
            }
            lim = jit.loopLimit(blk, compiled, left);
        }
        const r = while (true) {
            const r = exec.runOps(o, x, cpu, blk.end_pc);
            o = first;
            if (r.next == .side) {
                // Side exit after k+1 instructions: refund the rest.
                const k = (@intFromPtr(r.op) - @intFromPtr(first)) / @sizeOf(Op);
                left += blk.ninsn - (k + 1);
            } else if (r.next != .done) break r;
            if (irq) |p| if (p.* != 0) {
                // Count the passes run towards the compile threshold: with
                // frequent interrupts (IPIs on SMP) a hot self-loop would
                // otherwise never get compiled.
                if (jit.enabled and lim != blk.ninsn) jit.loopDone(blk, entry_left -| left);
                return event(cpu, .interrupt, 0, 0, 0);
            };
            // A block that branches to itself is still valid: anything that
            // could have invalidated it (a store into decoded code, FENCE.I)
            // ends the block with .stop instead of .done/.side.
            if (regs.pc != blk.pc or left < (if (jit.enabled) lim else blk.ninsn)) break r;
            left -= blk.ninsn;
        };
        if (jit.enabled and lim != blk.ninsn) jit.loopDone(blk, entry_left -| left);
        if (r.next == .done or r.next == .side) continue;
        // Left the block early: k instructions before r.op retired.
        const k: usize = (@intFromPtr(r.op) - @intFromPtr(first)) / @sizeOf(Op);
        left += blk.ninsn - k;
        switch (r.next) {
            .done, .cont, .side => unreachable,
            .fault => {
                regs.pc = cpu.pcAt(blk, k);
                return event(cpu, .fault, cpu.priv.fault_access, cpu.priv.fault_addr, 0);
            },
            .trap => {
                regs.pc = cpu.pcAt(blk, k);
                if (h.trap == .syscall) left -= 1; // ecall retires
                return trapEvent(cpu, regs);
            },
            .counter => {
                core.finishCounter(regs, h, cpu.icount +% (start - left));
                left -= 1;
                regs.pc = cpu.pcAt(blk, k + 1);
            },
            .stop => {
                left -= 1;
                regs.pc = cpu.pcAt(blk, k + 1);
                cpu.priv.smc = 0;
            },
            .jumped => {
                left -= 1;
                cpu.priv.smc = 0;
                if (irq) |p| if (p.* != 0) return event(cpu, .interrupt, 0, 0, 0);
            },
        }
    }
}

/// -Dkwemu-stats: account one call into compiled code that entered block
/// `entry` (charged by `run`) and left from `b` (`lastBlock`: the same
/// block, or a region member), `extra` = instructions it charged against
/// its budget (self-loop passes, further members, each in full, minus the
/// refunds of a region's side exits, which may exceed the rest: a side exit
/// of the entered block refunds into `jl` too, so `extra` wraps), `code`
/// its exit code.
noinline fn jitStats(cpu: *Cpu, entry: *const Block, b: *const Block, extra: u64, code: u32) void {
    const st = &cpu.priv.stats.jit;
    const charged = entry.ninsn +% extra;
    if (code >= jit.code_side) {
        st.insns += charged - (b.ninsn - (code - jit.code_side + 1));
    } else if (code >= jit.code_done) {
        st.insns += charged;
    } else {
        st.insns += charged - (b.ninsn - code);
        st.handbacks += 1;
        const o = cpu.priv.ops[b.op + code];
        st.hb[@intFromEnum(o.h)] += 1;
        if (o.h == .generic) st.hb_gen[genericClass(o.raw)] += 1;
    }
}

noinline fn trapEvent(cpu: *Cpu, regs: *Regs) u32 {
    const h = &cpu.priv.hart;
    cpu.priv.smc = 0;
    return switch (h.trap) {
        .syscall => blk: {
            regs.pc +%= 4;
            break :blk event(cpu, .syscall, 0, 0, 0);
        },
        .illegal => event(cpu, .illegal, 0, regs.pc, h.trap_val),
        .misaligned => event(cpu, .misaligned, 0, h.trap_val, 0),
        else => event(cpu, h.trap, 0, regs.pc, 0),
    };
}

pub fn setPgd(cpu: *Cpu, pgd: u64) void {
    cpu.pgd = pgd;
    cpu.flushAll();
    cpu.priv.hart.resv = core.no_resv;
}

pub fn clearReservation(cpu: *Cpu) void {
    cpu.priv.hart.resv = core.no_resv;
}

/// kw_set_isa: enable the optional extensions of `isa` that this build
/// implements, and return them. Decoded blocks (and their compiled code)
/// carry the old choice, so they are all dropped.
pub fn setIsa(cpu: *Cpu, isa: u64) u64 {
    cpu.priv.hart.isa = isa & core.implemented;
    cpu.resetCache();
    return cpu.priv.hart.isa;
}

/// kw_host_reset: the memory now belongs to a new module instance, whose
/// table holds the stubs again. Forget compiled code without freeing it,
/// ask the new host for its JIT, then drop every decoded block.
pub fn hostReset(cpu: *Cpu) void {
    if (jit.enabled) jit.forgetHost(cpu);
    cpu.resetCache();
}

/// Export the C ABI (called from the library root only, so that the unit
/// tests can link against the native archive without duplicate symbols).
pub fn exportAbi() void {
    @export(&kw_cpu_init, .{ .name = "kw_cpu_init" });
    @export(&kw_run, .{ .name = "kw_run" });
    @export(&kw_set_pgd, .{ .name = "kw_set_pgd" });
    @export(&kw_flush_tlb_all, .{ .name = "kw_flush_tlb_all" });
    @export(&kw_flush_tlb_range, .{ .name = "kw_flush_tlb_range" });
    @export(&kw_clear_reservation, .{ .name = "kw_clear_reservation" });
    @export(&kw_abi_version, .{ .name = "kw_abi_version" });
    @export(&kw_isa_supported, .{ .name = "kw_isa_supported" });
    @export(&kw_set_isa, .{ .name = "kw_set_isa" });
    @export(&kw_host_reset, .{ .name = "kw_host_reset" });
    if (stats_on) @export(&kw_debug_stats, .{ .name = "kw_debug_stats" });
    if (stats_on and jit.enabled) @export(&kw_debug_cpu_of_jit_buf, .{ .name = "kw_debug_cpu_of_jit_buf" });
}

fn kw_cpu_init(cpu: *Cpu) callconv(.c) void {
    cpuInit(cpu);
}
fn kw_run(cpu: *Cpu, regs: *Regs) callconv(.c) u32 {
    return run(cpu, regs);
}
fn kw_set_pgd(cpu: *Cpu, pgd: u64) callconv(.c) void {
    setPgd(cpu, pgd);
}
fn kw_flush_tlb_all(cpu: *Cpu) callconv(.c) void {
    cpu.flushAll();
}
fn kw_flush_tlb_range(cpu: *Cpu, start: u64, end: u64) callconv(.c) void {
    cpu.flushRange(start, end);
}
fn kw_clear_reservation(cpu: *Cpu) callconv(.c) void {
    clearReservation(cpu);
}
/// -Dkwemu-stats only (not part of the ABI): copy the counters out.
/// Word by word through volatile pointers: a struct copy would call
/// memmove, which the kernel does not define (it becomes an import).
fn kw_debug_stats(cpu: *Cpu, out: *Stats) callconv(.c) void {
    const n = @sizeOf(Stats) / 8;
    const src: *volatile [n]u64 = @ptrCast(&cpu.priv.stats);
    const dst: *volatile [n]u64 = @ptrCast(out);
    for (0..n) |i| dst[i] = src[i];
}
/// -Dkwemu-stats with the JIT only (not part of the ABI): the struct kw_cpu
/// whose emit buffer is `buf` (the pointer kw_host_jit_compile receives),
/// so a host can find the cpu to pass to kw_debug_stats.
fn kw_debug_cpu_of_jit_buf(buf: usize) callconv(.c) usize {
    return buf - (@offsetOf(Cpu, "priv") + @offsetOf(Priv, "jit") + @offsetOf(jit.State, "buf"));
}
fn kw_abi_version() callconv(.c) u32 {
    return abi_version;
}
fn kw_isa_supported() callconv(.c) u64 {
    return core.implemented;
}
fn kw_set_isa(cpu: *Cpu, isa: u64) callconv(.c) u64 {
    return setIsa(cpu, isa);
}
fn kw_host_reset(cpu: *Cpu) callconv(.c) void {
    hostReset(cpu);
}
