// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! kwemu JIT tier (optional: `-Dkwemu-jit`, wasm64 builds only).
//!
//! Hot decoded blocks (see `Block` in kwemu.zig) are translated into small
//! wasm modules that the host compiles and installs into a slot of the
//! module's function table; `run` then enters a block through
//! `call_indirect` instead of interpreting its ops. Everything the JIT knows
//! comes from the decoded ops, so the existing block-cache rules (tgen
//! check, revalidation, SMC tracking) decide when compiled code may run.
//!
//! Host imports (wasm import module "unkernel"; only referenced when the
//! JIT is compiled in, so the default object has no such imports):
//!   kw_host_jit_caps() -> u32
//!       bit 0: JIT available; bit 1: the memory is 32-bit (memory64-lowered
//!       module: the generated code imports a 32-bit memory and wraps every
//!       address); bit 2: eager (compile on the first entry; tests);
//!       bit 3: the memory is shared (the generated code declares its
//!       import shared, with the largest maximum of its type).
//!       Called once, by kw_cpu_init.
//!   kw_host_jit_compile(ptr, len, slot: u32, flags: u32) -> i32
//!       Compile the `len` bytes at `ptr` (a module importing env.memory and
//!       exporting function "f") and install "f" into table slot `slot`.
//!       0 = installed, < 0 = failed (the slot is left as it was). flags
//!       bit 0 (`compile_warm`): f(x, 0, irqp, jl) returns 0 at once, so the
//!       host may call it to make a lazy engine compile f inside the call.
//!   kw_host_jit_free(slot: u32)
//!       Put the slot's original function back and drop the module.
//!
//! Slots: kwemu owns `npool` stub functions; their table indices are the
//! slots. A stub returns "handed back at op 0", so a slot whose code is not
//! installed is harmless. The table never grows.
//!
//! Generated function: f(x, cpu, irqp, jl: i64) -> i64, where x = &regs.x
//! (x[32] = pc), irqp = cpu->irq_pending or a zero word, jl = budget for
//! extra self-loop iterations (`run` has already charged the first pass).
//! It returns (jl_left << 8) | code:
//!   0..63    handed back before op k (not executed), registers written back;
//!   64       done: the terminator retired, pc in x[32];
//!   128 + k  side exit taken at op k, pc in x[32].
//! Guest registers live in wasm locals (loaded on entry, written back at the
//! single exit). Loads and stores inline the data-TLB fast path; a miss
//! (fault, straddle, store into a page holding code, ...) hands the op back
//! to the interpreter. The code depends only on pc and the raw instruction
//! bits (via the ops), never on host addresses or generations, so a block
//! that is revalidated keeps its slot.
//!
//! A module may hold a region of several blocks, also of several pages (see
//! "regions" below); the code then refers to the block it left from, which
//! it names in cpu.jit.cur (`lastBlock`), and it returns "done" instead of a
//! side exit (having refunded the rest of that block itself).

const std = @import("std");
const builtin = @import("builtin");
const options = @import("kwemu_options");
const kwemu = @import("kwemu.zig");
const exec = @import("exec.zig");
const core = @import("../cpu/core.zig");
const Cpu = kwemu.Cpu;
const Block = kwemu.Block;
const Op = exec.Op;

pub const enabled = options.jit and builtin.cpu.arch == .wasm64;

/// Table slots (stub functions) owned by kwemu.
pub const npool = 1024;
/// Module emit buffer.
pub const buf_size = 16 * 1024;
/// Largest `jl` passed in (keeps `jl << 8` in 63 bits).
pub const max_jl: u64 = 1 << 55;
/// Result codes (low 8 bits of `enter`'s result): below code_done, op k
/// was handed back; code_done up to code_side, the pass is done and `run`
/// refunds nothing; from code_side, a side exit at op code - code_side.
/// The done codes say why (only statistics look at that): the terminator
/// left (code_done), a region's side exit left (code_done_side, the region
/// already refunded the rest of its member), or a budget, interrupt or
/// member check stopped the code at a block's start (code_done_stop).
pub const code_done = 64;
pub const code_done_side = code_done + 1;
pub const code_done_stop = code_done + 2;
pub const code_side = 128;

pub const cap_available: u32 = 1;
pub const cap_mem32: u32 = 2;
pub const cap_eager: u32 = 4;
pub const cap_shared: u32 = 8;
/// Most blocks in one compiled region (see "regions" below).
pub const max_members = 16;

// Block JIT state (`BlockState.st`): one word, so the per-pass test is a
// single load.
/// Not compiled, and never will be (first op unsupported, compile failed,
/// JIT unavailable).
const never: u32 = 0;
/// 1 .. ref_bit-1: interpreted instructions left before the block is
/// compiled. With `compiled` set: member `(st >> member_shift) & 0xff` of
/// the region in pool entry `st & slot_mask`; `ref_bit` is the clock's
/// referenced bit.
const compiled: u32 = 1 << 31;
const ref_bit: u32 = 1 << 30;
const member_shift = 16;
const slot_mask: u32 = (1 << member_shift) - 1;

extern "unkernel" fn kw_host_jit_caps() u32;
extern "unkernel" fn kw_host_jit_compile(ptr: [*]const u8, len: usize, slot: u32, flags: u32) i32;
/// kw_host_jit_compile flags: every module returns 0 at once when called
/// with cpu = 0 (see `emitModule`).
const compile_warm: u32 = 1;
extern "unkernel" fn kw_host_jit_free(slot: u32) void;

/// Per-block fields. Empty without the JIT, so the default build keeps the
/// block layout it always had.
pub const BlockState = if (enabled) extern struct {
    /// never / countdown / compiled | ref_bit? | pool entry (see above).
    st: u32 = never,
    /// Times `run` entered this compiled block right after compiled code
    /// of another region left towards it (see `noteExit`).
    hits: u32 = 0,
} else extern struct {};

/// JIT bookkeeping inside struct kw_cpu (empty without the JIT).
pub const State = if (enabled) extern struct {
    caps: u32,
    /// `st` of a new block: the compile threshold (`never`: JIT unavailable).
    threshold: u32,
    /// *irq_pending stand-in when cpu->irq_pending is NULL.
    zero: u32,
    /// Written by the stubs (their distinct side effect).
    last_stub: u32,
    /// Clock hand over `owner`.
    hand: u32,
    /// Largest module emitted so far (bytes).
    max_bytes: u32,
    /// Most members per region (`max_members`; tests lower it).
    region_max: u32,
    /// Exits from a region towards a compiled block of another region, per
    /// KiB of the region's module, after which that block joins the region
    /// (`noteHot`; -Dkwemu-jit-grow, tests change it).
    grow_threshold: u32,
    /// Set by `enter`: the entered block; on return, the block the result
    /// code refers to (a region stores the member it left from).
    cur: u64,
    /// Regions recompiled with an added block (a block of their page that
    /// got hot / a block they often left towards), and member blocks
    /// compiled.
    grows: u64,
    exit_grows: u64,
    members_total: u64,
    compiles: u64,
    frees: u64,
    /// Calls into compiled code.
    entries: u64,
    /// Calls that ended "handed back at op k" (counted by `handedBack`).
    handbacks: u64,
    /// Host compile failures and oversized modules.
    fails: u64,
    /// Modules emitted again for a shorter prefix (did not fit the buffer).
    shortened: u64,
    /// Blocks whose first op is not supported.
    skips: u64,
    evictions: u64,
    /// Block index + 1 per pool entry, 0 = free.
    owner: [npool]u32,
    /// Per pool entry: block index + 1 of each region member (0: none).
    /// A member that was re-decoded since is dead: its `st` no longer
    /// names this entry, and the region's code never enters it again.
    members: [npool][max_members]u16,
    /// Per pool entry: the low 16 bits of each member's `op` when it was
    /// compiled (its code is that decode; see `noteHot`).
    member_op: [npool][max_members]u16,
    /// Per pool entry: virtual page of the region (of the block it was
    /// first compiled for); | page_closed when it takes no further members.
    page: [npool]u64,
    /// Per pool entry: module size in bytes.
    size: [npool]u16,
    /// AES tables the compiled Zkne/Zknd ops read cpu-relative (`AesTab`).
    aes: AesTab,
    buf: [buf_size]u8,
} else extern struct {};

/// Tables for compiled AES ops, filled by `init` from core.aes (compiled code
/// may only address cpu-relative data, never the library's own constants).
/// te[x]: MixColumns of the column (S[x], 0, 0, 0); a byte in row r
/// contributes rotl(te[x], 8 r). td[x]: InvMixColumns of (S^-1[x], 0, 0, 0).
/// im[x]: InvMixColumns of (x, 0, 0, 0). s, is: the S-box and its inverse.
pub const AesTab = extern struct {
    te: [256]u32,
    td: [256]u32,
    im: [256]u32,
    s: [256]u8,
    is: [256]u8,
};

// ---- slots -----------------------------------------------------------------------

pub const JitFn = *const fn (x: u64, cpu: u64, irqp: u64, jl: u64) callconv(.c) u64;

fn Stub(comptime id: u32) type {
    return struct {
        fn f(x: u64, cpu: u64, irqp: u64, jl: u64) callconv(.c) u64 {
            _ = x;
            _ = irqp;
            const off = @offsetOf(Cpu, "priv") + @offsetOf(@FieldType(Cpu, "priv"), "jit") + @offsetOf(State, "last_stub");
            const p: *volatile u32 = @ptrFromInt(cpu + off);
            p.* = id;
            return jl << 8; // handed back at op 0, nothing retired
        }
    };
}

/// The stubs; pool entry i lives in table slot @intFromPtr(pool[i]).
const pool: [npool]JitFn = blk: {
    @setEvalBranchQuota(20 * npool);
    var p: [npool]JitFn = undefined;
    for (0..npool) |i| p[i] = &Stub(i).f;
    break :blk p;
};

inline fn tableSlot(i: usize) u32 {
    return @intCast(@intFromPtr(pool[i]));
}

fn blockIndex(cpu: *Cpu, b: *const Block) u32 {
    return @intCast((@intFromPtr(b) - @intFromPtr(&cpu.priv.blocks)) / @sizeOf(Block));
}

/// Ask the host what it offers and set the compile threshold from it.
fn askHost(st: *State) void {
    st.caps = kw_host_jit_caps();
    st.threshold = if (st.caps & cap_available == 0)
        never
    else if (st.caps & cap_eager != 0)
        1
    else
        std.math.clamp(options.jit_threshold, 1, ref_bit - 1);
}

/// kw_host_reset: the host that compiled the slots is gone. Forget every
/// slot without kw_host_jit_free and ask the new host. The caller then
/// drops all blocks (resetCache), which finds no slot left to free.
pub fn forgetHost(cpu: *Cpu) void {
    const st = &cpu.priv.jit;
    // Volatile stores: no memset import in the wasm object.
    const owner: *volatile [npool]u32 = &st.owner;
    const members: *volatile [npool][max_members]u16 = &st.members;
    for (0..npool) |i| {
        owner[i] = 0;
        for (0..max_members) |j| members[i][j] = 0;
    }
    // No block may name a slot any more: re-decoding one would free it.
    const bs: [*]volatile Block = &cpu.priv.blocks;
    for (0..cpu.priv.blocks.len) |i| {
        bs[i].jx.st = never;
        bs[i].jx.hits = 0;
    }
    askHost(st);
}

/// Called by kw_cpu_init after the block has been zeroed.
pub fn init(cpu: *Cpu) void {
    const st = &cpu.priv.jit;
    askHost(st);
    st.region_max = max_members;
    // 0: never (no member counts that many exits)
    st.grow_threshold = if (options.jit_grow == 0) std.math.maxInt(u32) else options.jit_grow;
    // Volatile stores: no memcpy import in the wasm object.
    const t: *volatile AesTab = &st.aes;
    const A = core.aes;
    for (0..256) |i| {
        t.te[i] = A.mixColumn(A.sbox[i]);
        t.td[i] = A.invMixColumn(A.inv_sbox[i]);
        t.im[i] = A.invMixColumn(@intCast(i));
        t.s[i] = A.sbox[i];
        t.is[i] = A.inv_sbox[i];
    }
}

/// Initial JIT state of a newly decoded block.
pub inline fn newBlock(cpu: *Cpu) BlockState {
    return .{ .st = cpu.priv.jit.threshold };
}

/// Pool entry + 1 of b's code, 0 = not compiled.
pub inline fn slotOf(b: *const Block) u32 {
    return if (b.jx.st >= compiled) (b.jx.st & slot_mask) + 1 else 0;
}

/// Member index of a compiled block in its region.
pub inline fn memberOf(b: *const Block) usize {
    return (b.jx.st >> member_shift) & 0xff;
}

/// Give pool entry `i` back to the host and detach it from its blocks.
fn freeSlot(cpu: *Cpu, i: usize) void {
    const st = &cpu.priv.jit;
    for (&st.members[i]) |*m| {
        if (m.* == 0) continue;
        const b = &cpu.priv.blocks[m.* - 1];
        if (slotOf(b) == i + 1) b.jx.st = st.threshold; // recompiled when hot again
        m.* = 0;
    }
    st.owner[i] = 0;
    kw_host_jit_free(tableSlot(i));
    st.frees += 1;
}

/// A block is about to be overwritten: drop its code. A region with other
/// live members stays: its code checks a member's `st` before entering it,
/// and the overwrite resets that.
pub inline fn drop(cpu: *Cpu, b: *Block) void {
    if (b.jx.st >= compiled) dropMember(cpu, b);
}

noinline fn dropMember(cpu: *Cpu, b: *Block) void {
    const i = b.jx.st & slot_mask;
    const me: u16 = @intCast(blockIndex(cpu, b) + 1);
    b.jx.st = never;
    for (cpu.priv.jit.members[i]) |m| {
        if (m != 0 and m != me and slotOf(&cpu.priv.blocks[m - 1]) == i + 1) return;
    }
    freeSlot(cpu, i);
}

/// Free every slot in use (cache reset).
pub fn releaseAll(cpu: *Cpu) void {
    for (0..npool) |i| {
        if (cpu.priv.jit.owner[i] != 0) freeSlot(cpu, i);
    }
}

/// Clock: whether a live member of pool entry i was entered from `run`
/// since the last sweep; clears the referenced bits.
fn referenced(cpu: *Cpu, i: usize) bool {
    var any = false;
    for (cpu.priv.jit.members[i]) |m| {
        if (m == 0) continue;
        const b = &cpu.priv.blocks[m - 1];
        if (slotOf(b) == i + 1 and b.jx.st & ref_bit != 0) {
            b.jx.st &= ~ref_bit;
            any = true;
        }
    }
    return any;
}

/// A free pool entry, evicting one (clock, second chance) if none is free.
fn allocSlot(cpu: *Cpu) usize {
    const st = &cpu.priv.jit;
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const i = st.hand;
        st.hand = (i + 1) % npool;
        const o = st.owner[i];
        if (o == 0) return i;
        if (referenced(cpu, i) and tries < 2 * npool) continue; // second chance
        freeSlot(cpu, i);
        st.evictions += 1;
        return i;
    }
}

/// Compile b (it got hot); true: `run` must look b up again before it runs
/// anything (`windowClose`).
noinline fn compile(cpu: *Cpu, b: *Block) bool {
    @branchHint(.cold);
    const st = &cpu.priv.jit;
    if (!supported(cpu.priv.ops[b.op])) {
        b.jx.st = never;
        st.skips += 1;
        return false;
    }
    windowOpen(cpu);
    // An interrupt that is already pending (an IPI sent just before the
    // window opened, whose sender may now be waiting) is taken first: the
    // block runs interpreted this pass, and its next pass compiles it.
    if (cpu.irq_pending) |p| {
        if (p.* != 0) return windowClose(cpu);
    }
    var rg: Region = .{ .cpu = cpu };
    gatherRegion(cpu, b, &rg);
    install(cpu, &rg, b.pc >> 12, null);
    return windowClose(cpu);
}

/// A compile (gathering a region, emitting its module, the host's compile
/// and the slot bookkeeping) is a window in which other CPUs need not wait
/// for this one's TLB flushes (kw_emu.h, "Flushes during a JIT compile"):
/// nothing in it runs guest code or reads guest memory or a page table
/// (only struct kw_cpu: decoded ops, exec-TLB generations, the emit
/// buffer). Without atomics (one hart) nobody sets flush_all, and these
/// are plain stores and loads.
inline fn windowOpen(cpu: *Cpu) void {
    @atomicStore(u32, &cpu.jit_busy, 1, .seq_cst);
}

/// End the window and do the flush another CPU asked for meanwhile, if
/// any. True if it did: every block revalidates, and the one `run` was
/// about to run may be gone, so `run` must look it up again before it runs
/// anything. (An interrupt raised meanwhile is taken where the interpreter
/// takes it, after that block.)
fn windowClose(cpu: *Cpu) bool {
    @atomicStore(u32, &cpu.jit_busy, 0, .seq_cst);
    if (@atomicRmw(u32, &cpu.flush_all, .Xchg, 0, .seq_cst) == 0) return false;
    cpu.flushAll();
    return true;
}

/// Compile region `rg` (member 0 first) into a free pool entry for virtual
/// page `page` and make it the home of every member that is not compiled
/// elsewhere (the others are guests: their code is copied into this module,
/// but `run` keeps entering them through their own region).
/// `grow`: rg is the region in pool entry grow.? with a block added. If it
/// does not fit the buffer, that region stays as it is (closed) instead of
/// being cut: a cut would drop members, which then run interpreted until
/// they get hot again. Otherwise member 0 is the block that got hot, which
/// is never compiled again if this fails. Called inside the window
/// (`windowOpen`).
fn install(cpu: *Cpu, rg: *Region, page: u64, grow: ?u32) void {
    const st = &cpu.priv.jit;
    const b: *Block = &cpu.priv.blocks[rg.idx[0]];
    const hot = grow == null;
    // A module that does not fit the buffer is emitted again with less in
    // it: a region drops the members found last, down to b alone, and then
    // b is emitted for a shorter prefix (the rest is handed back), so a
    // block of many large ops is still compiled. Either way no other block
    // joins this region later (it would only push others out). Every retry
    // emits strictly less, so this ends; a module that did not fit is never
    // handed to the host. The code does not depend on the pool entry, so it
    // is emitted before one is taken.
    var closed = false;
    var limit: usize = b.n;
    const len = while (true) {
        if (emitModule(cpu, b, if (rg.n > 1) rg else null, &limit)) |n| break n else |e| switch (e) {
            error.Unsupported => {
                if (hot) b.jx.st = never;
                st.skips += 1;
                return;
            },
            error.Overflow => {
                closed = true;
                if (grow) |g| {
                    st.page[g] |= page_closed;
                    return;
                }
                if (rg.n > 1) {
                    rg.n = if (rg.n > 4) rg.n * 3 / 4 else rg.n - 1;
                    st.shortened += 1;
                } else if (limit > 1) {
                    limit = limit * 3 / 4;
                    st.shortened += 1;
                } else {
                    b.jx.st = never;
                    st.fails += 1;
                    return;
                }
            },
        }
    };
    if (grow) |g| {
        freeSlot(cpu, g);
        st.exit_grows += 1;
    }
    const i = allocSlot(cpu);
    // A guest-only module would never be entered (cut down to its guests).
    var home = false;
    for (rg.idx[0..rg.n]) |x| home = home or cpu.priv.blocks[x].jx.st < compiled;
    if (!home) return;
    st.max_bytes = @max(st.max_bytes, @as(u32, @intCast(len)));
    st.size[i] = @intCast(len);
    if (kw_host_jit_compile(&st.buf, len, tableSlot(i), compile_warm) < 0) {
        if (hot) b.jx.st = never;
        st.fails += 1;
        return;
    }
    st.owner[i] = rg.idx[0] + 1;
    // A self-loop's own module takes no members either: `findRegion` would
    // otherwise pull it into the next region of its page (kbench fp's dgemm
    // loop: 457 MIPS as a member, 540 on its own).
    if (rg.n == 1 and selfLoop(cpu, b)) closed = true;
    if (rg.n >= @min(st.region_max, max_members)) closed = true;
    st.page[i] = page | (if (closed) page_closed else 0);
    for (0..max_members) |m| {
        st.members[i][m] = if (m < rg.n) @intCast(rg.idx[m] + 1) else 0;
        if (m >= rg.n) continue;
        const x = &cpu.priv.blocks[rg.idx[m]];
        st.member_op[i][m] = @truncate(x.op);
        if (x.jx.st < compiled) x.jx.st = memberSt(i, m) | ref_bit;
    }
    st.members_total += rg.n;
    st.compiles += 1;
}

/// `run` is about to enter compiled block `b` right after compiled code of
/// the region in pool entry `s` left (terminator or side exit) towards it.
/// Cheap unless b is compiled in another region. True: a grow compiled, and
/// `run` must look b up again (`windowClose`).
pub inline fn noteExit(cpu: *Cpu, s: u32, b: *Block) bool {
    if (b.jx.st < compiled or b.jx.st & slot_mask == s) return false;
    return noteHot(cpu, s, b);
}

/// Region growth along hot exits: a block compiled in another region, on
/// another page than the region's own, that `run` entered `grow_threshold`
/// times per KiB of the region's module right after a region left towards
/// it, joins the region that left last as a guest member (it keeps its own
/// module, which `run` still enters). Calls, returns and jumps into other
/// pages (libc, PLT stubs, functions that span pages) then stay inside one
/// module. Targets on the region's own page are left to `findRegion`, and
/// closed or full regions and self-loops (which keep their own module) are
/// left alone: in measurements, growing towards those cost more in compiles
/// than the exits it saved.
noinline fn noteHot(cpu: *Cpu, s: u32, b: *Block) bool {
    const st = &cpu.priv.jit;
    // Called on every such exit: only the cheap tests before counting.
    if (st.page[s] & page_closed != 0 or b.pc >> 12 == st.page[s]) return false;
    b.jx.hits += 1;
    // A grow recompiles the whole region: the bigger it is, the more exits
    // it takes (grow_threshold per KiB of module).
    if (b.jx.hits < st.grow_threshold *| @max(1, st.size[s] >> 10)) return false;
    b.jx.hits = 0;
    if (selfLoop(cpu, b)) return false;
    // Already a member with this decode: the region stopped before it
    // (budget, interrupt, a page revalidated since).
    const me = blockIndex(cpu, b) + 1;
    for (st.members[s], st.member_op[s]) |m, o| {
        if (m == me and o == @as(u16, @truncate(b.op))) return false;
    }
    const limit = @min(st.region_max, max_members);
    var rg: Region = .{ .cpu = cpu };
    for (st.members[s]) |m| {
        if (m != 0 and usable(cpu, &cpu.priv.blocks[m - 1])) addMember(&rg, m - 1);
    }
    if (rg.n == 0 or rg.n >= limit) {
        st.page[s] |= page_closed; // full: stop counting its exits
        return false;
    }
    addMember(&rg, blockIndex(cpu, b));
    windowOpen(cpu);
    install(cpu, &rg, st.page[s], s);
    return windowClose(cpu);
}

/// A decoded block that may be a region member.
fn usable(cpu: *Cpu, b: *const Block) bool {
    return b.pc != std.math.maxInt(u64) and supported(cpu.priv.ops[b.op]) and !selfLoop(cpu, b);
}

/// What `ready` decided for a pass through a block: interpret it, run its
/// compiled code, or neither: a compile asked `run` to look the block up
/// again first (`windowClose`).
pub const Go = enum { interp, compiled, again };

/// A pass through `b` is about to run: whether it runs compiled. Counts the
/// pass towards the threshold and compiles the block once it is hot. One
/// load and no store for a block that is never compiled.
pub inline fn ready(cpu: *Cpu, b: *Block) Go {
    const s = b.jx.st;
    if (s >= compiled) return .compiled;
    if (s == never) return .interp;
    if (s > b.ninsn) {
        b.jx.st = s - b.ninsn;
        return .interp;
    }
    if (compile(cpu, b)) return .again;
    return if (b.jx.st >= compiled) .compiled else .interp;
}

/// The interpreter's self-loop over b continues while `left >= limit`
/// (instead of `left >= b.ninsn`), so the JIT adds no work to that loop:
/// a compiled block (the interpreter finished a handed-back pass) stops at
/// once and re-enters through `enter`; a block counting towards its
/// threshold stops when the countdown runs out (charged by `loopDone`), so
/// the next pass is compiled; anything else keeps b.ninsn.
pub inline fn loopLimit(b: *const Block, is_compiled: bool, left: u64) u64 {
    if (is_compiled) return std.math.maxInt(u64);
    const s = b.jx.st;
    if (s == never) return b.ninsn;
    return @max(@as(u64, b.ninsn) + 1, left -| s);
}

/// The interpreter leaves b after `n` more instructions in its self-loop.
pub inline fn loopDone(b: *Block, n: u64) void {
    const s = b.jx.st;
    if (s != never and s < compiled) b.jx.st = @intCast(@max(1, s -| n));
}

/// Run `b`'s compiled code (`ready` returned true) with `jl` extra
/// self-loop instructions allowed; returns (jl_left << 8) | code. Not
/// inlined: keeps the indirect call out of the interpreter's hot loop.
/// `run` has charged b in full; a region charges every further member it
/// enters against `jl` the same way, and `code` refers to `lastBlock`.
pub noinline fn enter(cpu: *Cpu, b: *Block, x: [*]u64, jl: u64) u64 {
    const s = b.jx.st;
    b.jx.st = s | ref_bit; // referenced (clock)
    cpu.priv.jit.entries += 1;
    cpu.priv.jit.cur = @intFromPtr(b);
    const irqp: u64 = if (cpu.irq_pending) |p| @intFromPtr(p) else @intFromPtr(&cpu.priv.jit.zero);
    return pool[s & slot_mask](@intFromPtr(x), @intFromPtr(cpu), irqp, jl);
}

/// `enter` returned "handed back" (the interpreter finishes the pass).
pub inline fn handedBack(cpu: *Cpu) void {
    cpu.priv.jit.handbacks += 1;
}

/// The block whose code returned from `enter`: the entered block, or the
/// region member it left from. The result code refers to that block.
pub inline fn lastBlock(cpu: *Cpu) *Block {
    return @ptrFromInt(@as(usize, @intCast(cpu.priv.jit.cur)));
}

// ---- statistics (-Dkwemu-stats) ----------------------------------------------------

/// Indices into Stats.jit.jx.
pub const Jx = struct {
    /// Calls from `run` into compiled code.
    pub const entries = 0;
    /// Compiled passes that handed an op back to the interpreter.
    pub const handbacks = 1;
    /// Compiled passes that left through a side exit (regions' included) /
    /// the terminator (conditional branch, jal, goto) / a jalr terminator.
    /// With exit_stop and handbacks these add up to entries.
    pub const exit_side = 2;
    pub const exit_direct = 3;
    pub const exit_jalr = 4;
    /// The block run next after a compiled pass that left through an exit
    /// (not a stop): 5 + 4 * (left through a jalr terminator) + 2 * (same
    /// page) + (compiled).
    pub const next = 5;
    /// ... of which the same block again / a block that is never compiled.
    pub const next_self = 13;
    pub const next_never = 14;
    /// Region code: branches from one member into another (or itself) /
    /// to a member that was not valid (stale tgen, re-decoded) / to a
    /// member when the budget or a pending interrupt stopped it / to a pc
    /// that is no member (these return to `run`).
    pub const region_hops = 15;
    pub const region_stale = 16;
    pub const region_stop = 17;
    pub const region_out = 18;
    /// The compiled block run next after a compiled pass is a member of the
    /// region that was entered / a self-loop's own module / in another
    /// region (... of which the entered region was closed or full).
    pub const next_same_region = 19;
    pub const next_selfloop = 20;
    pub const next_other_region = 21;
    pub const next_other_full = 22;
    /// Region code: branches from one member towards a member on another
    /// page (counted at the branch site, before the checked entry).
    pub const region_cross = 23;
    /// Compiled passes stopped at a block's start: the budget did not
    /// cover the next pass or member, an interrupt was pending, or a
    /// member's checked entry failed (code_done_stop).
    pub const exit_stop = 24;
    /// ... of exit_side: side exits of a region member (code_done_side).
    pub const exit_side_region = 25;
    /// How a compiled pass left (Xr) by the block `run` looked up next
    /// (Nx): next_by + n_nx * reason + class. Counted for every pass but
    /// hand-backs, unless `run` returned first (budget used up, interrupt
    /// pending), so a row adds up to at most its exit counter.
    pub const next_by = 26;
    pub const n_nx = 7;
    pub const end = next_by + 4 * n_nx;
};

/// Exit reasons of Jx.next_by.
pub const Xr = enum(u32) { side, direct, jalr, stop };

/// Classes of the block run next, in Jx.next_by (the first that holds):
/// the block left, again / never compiled / not compiled yet / compiled:
/// a member of the region left / a self-loop's own module / in another
/// region, and the region left could still grow / ... and the region left
/// is closed or full.
pub const Nx = enum(u32) { self, never, interp, same_region, selfloop, other, other_full };

inline fn jx(cpu: *Cpu, i: usize, n: u64) void {
    if (kwemu.stats_on) cpu.priv.stats.jit.jx[i] += n;
}

/// Statistics: how the compiled pass of `b` that returned `code` left it:
/// 0 = handed back, else Jx.exit_*.
pub fn countExit(cpu: *Cpu, b: *const Block, code: u32) u32 {
    jx(cpu, Jx.entries, 1);
    const kind: u32 = if (code < code_done)
        Jx.handbacks
    else if (code >= code_side or code == code_done_side)
        Jx.exit_side
    else if (code == code_done_stop)
        Jx.exit_stop
    else if (cpu.priv.ops[b.op + b.n - 1].h == .jalr)
        Jx.exit_jalr
    else
        Jx.exit_direct;
    jx(cpu, kind, 1);
    if (code == code_done_side) jx(cpu, Jx.exit_side_region, 1);
    return if (kind == Jx.handbacks) 0 else kind;
}

/// Statistics: block `b` runs after a compiled pass of `from` that left it
/// the way `kind` (countExit) says.
pub fn countNext(cpu: *Cpu, kind: u32, from: *const Block, b: *const Block, slot: u32) void {
    const xr: Xr = switch (kind) {
        Jx.exit_side => .side,
        Jx.exit_jalr => .jalr,
        Jx.exit_stop => .stop,
        else => .direct,
    };
    var nx: Nx = if (b == from) .self else if (b.jx.st == never) .never else .interp;
    if (kind != Jx.exit_stop) {
        const same_page = (from.pc ^ b.pc) >> 12 == 0;
        const i = Jx.next + 4 * @as(usize, @intFromBool(kind == Jx.exit_jalr)) + 2 * @as(usize, @intFromBool(same_page)) + @intFromBool(b.jx.st >= compiled);
        jx(cpu, i, 1);
        if (b == from) jx(cpu, Jx.next_self, 1);
        if (b.jx.st == never) jx(cpu, Jx.next_never, 1);
    }
    if (b.jx.st >= compiled) {
        const s = b.jx.st & slot_mask;
        const st = &cpu.priv.jit;
        const nc: Nx = if (s == slot)
            .same_region
        else if (st.members[s][1] == 0 and selfLoop(cpu, b))
            .selfloop
        else full: {
            var n: usize = 0;
            for (st.members[slot]) |m| n += @intFromBool(m != 0);
            break :full if (st.page[slot] & page_closed != 0 or n >= st.region_max) .other_full else .other;
        };
        if (kind != Jx.exit_stop) switch (nc) {
            .same_region => jx(cpu, Jx.next_same_region, 1),
            .selfloop => jx(cpu, Jx.next_selfloop, 1),
            .other => jx(cpu, Jx.next_other_region, 1),
            .other_full => {
                jx(cpu, Jx.next_other_region, 1);
                jx(cpu, Jx.next_other_full, 1);
            },
            else => unreachable,
        };
        if (nx != .self) nx = nc;
    }
    jx(cpu, Jx.next_by + Jx.n_nx * @as(usize, @intFromEnum(xr)) + @intFromEnum(nx), 1);
}

/// The pool entry `enter` is about to run (for `noteExit`).
pub inline fn slotIndex(b: *const Block) u32 {
    return b.jx.st & slot_mask;
}

// ---- emitter ---------------------------------------------------------------------

/// Whether the JIT translates op `o` (anything else hands back to the
/// interpreter at that op). FP arithmetic is translated only with a static
/// RNE rounding mode or a dynamic one (checked against frm at run time).
/// Optional extensions (core.Ext) need no gate here: the decoder emits
/// their dedicated ops only while they are enabled, and `generic` ops that
/// hold their encodings must stay handed back (core.exec gates them).
fn supported(o: Op) bool {
    return switch (o.h) {
        .addi, .addiw, .andi, .ori, .xori, .slti, .sltiu, .slli, .srli, .srai, .slliw, .srliw, .sraiw, .li => true,
        .add, .sub, .and_, .or_, .xor_, .sll, .srl, .sra, .slt, .sltu, .addw, .subw, .sllw, .srlw, .sraw => true,
        .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu, .mulw, .divw, .divuw, .remw, .remuw => true,
        .aes64es, .aes64esm, .aes64ds, .aes64dsm, .aes64im, .aes64ks1i, .aes64ks2 => true,
        .andn, .orn, .xnor, .rol, .ror, .rolw, .rorw, .pack, .packh, .packw, .rori, .roriw, .rev8, .brev8 => true,
        .clmul, .clmulh, .clmulr, .xperm4, .xperm8 => true,
        .shadd, .clz, .ctz, .cpop, .minmax, .sext, .orc_b, .bitop, .bext, .czero => true,
        .lb, .lh, .lw, .ld, .lbu, .lhu, .lwu, .sb, .sh, .sw, .sd, .nop => true,
        .beq_x, .bne_x, .blt_x, .bge_x, .bltu_x, .bgeu_x, .jal_c => true,
        .beq, .bne, .blt, .bge, .bltu, .bgeu, .jal, .jalr, .goto => true,
        .flw, .fld, .fsw, .fsd, .fmv_x_w, .fmv_x_d, .fmv_w_x, .fmv_d_x, .fcmp_s, .fcmp_d => true,
        // fsgnj*, fmin/fmax(m); fround(nx) only with a static mode but RMM, or dynamic
        .fsgnj_s, .fsgnj_d => o.imm < 16 or o.imm & 7 != 4,
        .fadd_s, .fsub_s, .fmul_s, .fdiv_s, .fadd_d, .fsub_d, .fmul_d, .fdiv_d => rmOk(o),
        .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s, .fmadd_d, .fmsub_d, .fnmsub_d, .fnmadd_d => rmOk(o),
        .generic => fpGeneric(o.raw) != null,
        else => false,
    };
}

/// Static rounding mode RNE (0) or dynamic (7).
fn rmOk(o: Op) bool {
    const rm = o.imm & 7;
    return rm == 0 or rm == 7;
}

/// FP instructions that the decoder leaves to `generic` (core.exec) but the
/// JIT translates: the exact encodings core.zig accepts, with rm checked
/// like rmOk. null = not translated (hand back).
const FpGen = enum { fsqrt_s, fsqrt_d, fcvt_s_d, fcvt_d_s, fcvt_f_x_s, fcvt_f_x_d, fcvt_x_f_s, fcvt_x_f_d, fclass_s, fclass_d };

fn fpGeneric(raw: u32) ?FpGen {
    if (raw & 0x7f != 0x53) return null;
    const f3 = (raw >> 12) & 7;
    const rs2 = (raw >> 20) & 31;
    const dbl = switch ((raw >> 25) & 3) {
        0 => false,
        1 => true,
        else => return null,
    };
    const rm_ok = f3 == 0 or f3 == 7;
    return switch (raw >> 27) {
        0x0b => if (rs2 == 0 and rm_ok) (if (dbl) .fsqrt_d else .fsqrt_s) else null,
        0x08 => if (!rm_ok) null else if (dbl and rs2 == 0) .fcvt_d_s else if (!dbl and rs2 == 1) .fcvt_s_d else null,
        // fcvt.{s,d}.{w,wu,l,lu}: fcvt.d.w/wu are always exact, so any
        // legal static mode does; the others need RNE.
        0x1a => if (rs2 <= 3 and (rm_ok or (dbl and rs2 <= 1 and f3 <= 4))) (if (dbl) .fcvt_f_x_d else .fcvt_f_x_s) else null,
        // fcvt.{w,wu,l,lu}.{s,d}: any static mode but RMM, or dynamic
        0x18 => if (rs2 <= 3 and f3 != 4 and f3 != 5 and f3 != 6) (if (dbl) .fcvt_x_f_d else .fcvt_x_f_s) else null,
        0x1c => if (rs2 == 0 and f3 == 1) (if (dbl) .fclass_d else .fclass_s) else null,
        else => null,
    };
}

const Use = struct {
    read: u32 = 0,
    write: u32 = 0,
    fread: u32 = 0,
    fwrite: u32 = 0,
    /// Reads fcsr (dynamic rounding mode) / accrues flags into it.
    fcsr_r: bool = false,
    fcsr_w: bool = false,
    fmad: bool = false,
    fmas: bool = false,
    nfma: u32 = 0,
    /// AES ops with a table body (bit per `AesK`), and how many.
    aes: u8 = 0,
    naes: u32 = 0,
    /// clmul/xperm ops (bit per `BkK`), and how many.
    bk: u8 = 0,
    nbk: u32 = 0,

    fn add(u: *Use, x: Use) void {
        u.read |= x.read;
        u.write |= x.write;
        u.fread |= x.fread;
        u.fwrite |= x.fwrite;
        u.fcsr_r = u.fcsr_r or x.fcsr_r;
        u.fcsr_w = u.fcsr_w or x.fcsr_w;
        u.fmad = u.fmad or x.fmad;
        u.fmas = u.fmas or x.fmas;
        u.nfma += x.nfma;
        u.aes |= x.aes;
        u.naes += x.naes;
        u.bk |= x.bk;
        u.nbk += x.nbk;
    }
};

fn regBit(r: u8) u32 {
    return if (r == 0 or r >= 32) 0 else @as(u32, 1) << @intCast(r);
}
fn fregBit(r: u32) u32 {
    return @as(u32, 1) << @intCast(r & 31);
}

fn usage(o: Op) Use {
    const a = regBit(o.rs1);
    const b = regBit(o.rs2);
    const d = regBit(o.rd);
    const fa = fregBit(o.rs1);
    const fb = fregBit(o.rs2);
    const fd = fregBit(o.rd);
    return switch (o.h) {
        .addi, .addiw, .andi, .ori, .xori, .slti, .sltiu, .slli, .srli, .srai, .slliw, .srliw, .sraiw => .{ .read = a, .write = d },
        .lb, .lh, .lw, .ld, .lbu, .lhu, .lwu => .{ .read = a, .write = d },
        .li, .jal_c, .jal => .{ .write = d },
        .jalr => .{ .read = a, .write = d },
        .sb, .sh, .sw, .sd, .beq_x, .bne_x, .blt_x, .bge_x, .bltu_x, .bgeu_x, .beq, .bne, .blt, .bge, .bltu, .bgeu => .{ .read = a | b },
        .nop, .goto => .{},
        .flw, .fld => .{ .read = a, .fwrite = fd },
        .fsw, .fsd => .{ .read = a, .fread = fb },
        .fmv_x_w, .fmv_x_d => .{ .fread = fa, .write = d },
        .fmv_w_x, .fmv_d_x => .{ .read = a, .fwrite = fd },
        .fsgnj_s, .fsgnj_d => if (o.imm < 4)
            .{ .fread = fa | fb, .fwrite = fd }
        else if (o.imm < 8) // fmin/fmax(m): NV
            .{ .fread = fa | fb, .fwrite = fd, .fcsr_r = true, .fcsr_w = true }
        else // fround(nx): frm, NV/NX
            .{ .fread = fa, .fwrite = fd, .fcsr_r = true, .fcsr_w = true },
        .fcmp_s, .fcmp_d => .{ .fread = fa | fb, .write = d, .fcsr_r = true, .fcsr_w = true },
        .fadd_s, .fsub_s, .fmul_s, .fdiv_s, .fadd_d, .fsub_d, .fmul_d, .fdiv_d => .{ .fread = fa | fb, .fwrite = fd, .fcsr_r = true, .fcsr_w = true },
        .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s, .fmadd_d, .fmsub_d, .fnmsub_d, .fnmadd_d => .{
            .fread = fa | fb | fregBit(@intCast(o.imm >> 8)),
            .fwrite = fd,
            .fcsr_r = true,
            .fcsr_w = true,
            .fmad = o.h == .fmadd_d or o.h == .fmsub_d or o.h == .fnmsub_d or o.h == .fnmadd_d,
            .fmas = o.h == .fmadd_s or o.h == .fmsub_s or o.h == .fnmsub_s or o.h == .fnmadd_s,
            .nfma = 1,
        },
        .generic => genUsage(o.raw),
        .aes64es, .aes64esm, .aes64ds, .aes64dsm, .aes64im => .{
            .read = a | b,
            .write = d,
            .aes = @as(u8, 1) << @intFromEnum(aesKind(o.h)),
            .naes = 1,
        },
        .clmul, .clmulh, .clmulr, .xperm4, .xperm8 => .{
            .read = a | b,
            .write = d,
            .bk = @as(u8, 1) << @intFromEnum(bkKind(o.h)),
            .nbk = 1,
        },
        // R-type; also the I-forms with rs2 = 0 (aes64ks1i, rori, rev8, ...)
        else => .{ .read = a | b, .write = d },
    };
}

fn genUsage(raw: u32) Use {
    const rd: u8 = @intCast((raw >> 7) & 31);
    const rs1: u8 = @intCast((raw >> 15) & 31);
    const fl: Use = .{ .fcsr_r = true, .fcsr_w = true };
    var u = fl;
    switch (fpGeneric(raw).?) {
        .fsqrt_s, .fsqrt_d, .fcvt_s_d, .fcvt_d_s => {
            u.fread = fregBit(rs1);
            u.fwrite = fregBit(rd);
        },
        .fcvt_f_x_s, .fcvt_f_x_d => {
            u.read = regBit(rs1);
            u.fwrite = fregBit(rd);
        },
        .fcvt_x_f_s, .fcvt_x_f_d, .fclass_s, .fclass_d => {
            u.fread = fregBit(rs1);
            u.write = regBit(rd);
        },
    }
    return u;
}

// wasm opcodes
const W = struct {
    const block = 0x02;
    const loop = 0x03;
    const @"if" = 0x04;
    const @"else" = 0x05;
    const end = 0x0b;
    const br = 0x0c;
    const drop = 0x1a;
    const select = 0x1b;
    const local_get = 0x20;
    const local_set = 0x21;
    const local_tee = 0x22;
    const i32_load = 0x28;
    const i64_load = 0x29;
    const i64_store = 0x37;
    const i32_const = 0x41;
    const i64_const = 0x42;
    const i32_eqz = 0x45;
    const i32_eq = 0x46;
    const i64_eqz = 0x50;
    const i64_eq = 0x51;
    const i64_ne = 0x52;
    const i64_lt_s = 0x53;
    const i64_lt_u = 0x54;
    const i64_ge_s = 0x59;
    const i64_ge_u = 0x5a;
    const i32_and = 0x71;
    const i32_or = 0x72;
    const i32_shl = 0x74;
    const i32_shr_s = 0x75;
    const i32_shr_u = 0x76;
    const i32_div_s = 0x6d;
    const i32_div_u = 0x6e;
    const i32_rem_s = 0x6f;
    const i32_rem_u = 0x70;
    const i64_add = 0x7c;
    const i64_sub = 0x7d;
    const i64_mul = 0x7e;
    const i64_div_s = 0x7f;
    const i64_div_u = 0x80;
    const i64_rem_s = 0x81;
    const i64_rem_u = 0x82;
    const i64_and = 0x83;
    const i64_or = 0x84;
    const i64_xor = 0x85;
    const i64_shl = 0x86;
    const i64_shr_s = 0x87;
    const i64_shr_u = 0x88;
    const i32_wrap = 0xa7;
    const i64_ext_s = 0xac;
    const i64_ext_u = 0xad;
    const void_t = 0x40;
    const i64_t = 0x7e;
    const i32_t = 0x7f;
    const f64_t = 0x7c;
    // FP and the rest (all MVP)
    const @"return" = 0x0f;
    const call = 0x10;
    const global_get = 0x23;
    const global_set = 0x24;
    const i64_load32_u = 0x35;
    const i64_store32 = 0x3e;
    const f64_const = 0x44;
    const i32_ne = 0x47;
    const i64_gt_s = 0x55;
    const i64_gt_u = 0x56;
    const i64_le_u = 0x58;
    const f32_eq = 0x5b;
    const f32_lt = 0x5d;
    const f32_le = 0x5f;
    const f64_eq = 0x61;
    const f64_ne = 0x62;
    const f64_lt = 0x63;
    const f64_gt = 0x64;
    const f64_le = 0x65;
    const f64_ge = 0x66;
    const i32_xor = 0x73;
    const i32_rotl = 0x77;
    const i32_rotr = 0x78;
    const i64_rotl = 0x89;
    const i64_rotr = 0x8a;
    const i64_load8_u = 0x31;
    const i64_clz = 0x79;
    const i64_ctz = 0x7a;
    const i64_popcnt = 0x7b;
    const i32_clz = 0x67;
    const i32_ctz = 0x68;
    const i32_popcnt = 0x69;
    const f32_sqrt = 0x91;
    const f64_ceil = 0x9b;
    const f64_floor = 0x9c;
    const f64_trunc = 0x9d;
    const f64_nearest = 0x9e;
    const f64_sqrt = 0x9f;
    const f64_add = 0xa0;
    const f64_sub = 0xa1;
    const f64_mul = 0xa2;
    const f64_div = 0xa3;
    const i64_trunc_f64_s = 0xb0;
    const i64_trunc_f64_u = 0xb1;
    const f32_convert_i32_s = 0xb2;
    const f32_convert_i32_u = 0xb3;
    const f32_convert_i64_s = 0xb4;
    const f32_convert_i64_u = 0xb5;
    const f32_demote = 0xb6;
    const f64_convert_i32_s = 0xb7;
    const f64_convert_i32_u = 0xb8;
    const f64_convert_i64_s = 0xb9;
    const f64_convert_i64_u = 0xba;
    const f64_promote = 0xbb;
    const i32_reinterpret = 0xbc;
    const i64_reinterpret = 0xbd;
    const f32_reinterpret = 0xbe;
    const f64_reinterpret = 0xbf;
};

// locals
const l_x = 0;
const l_cpu = 1;
const l_irq = 2;
const l_jl = 3;
inline fn lreg(r: u8) u32 {
    return 3 + @as(u32, r); // x1..x31 -> 4..34
}
const l_npc = 35;
const l_va = 36;
const l_e = 37;
const l_code = 38;
const l_t0 = 39; // ..43
/// f0..f31 (raw 64-bit register contents) -> 44..75
inline fn lf(r: u32) u32 {
    return 44 + (r & 31);
}
const l_fcsr = 76;
const l_t5 = 77; // ..81
/// An inline FMA body's i64 locals (its a, b, c and temporaries) ..91,
/// and its status (0 exact, 1 inexact, 2 hand back).
const l_fma_i = 82;
const l_fma_st = 92;
const n_i64 = 93 - 4;
const l_d0 = 93; // f64 temporaries ..98
/// An inline FMA body's f64 locals ..114.
const l_fma_f = 99;
const n_f64 = 22;
/// Blocks with at most this many FMA ops get them inline; more share one
/// helper function per format (bounding the module size). Decided per
/// block, also for region members (a region of several FMA blocks keeps
/// them inline; the buffer limit cuts the region if needed).
const fma_inline_max = 4;

/// The FMA, AES and clmul/xperm helpers a block with usage `x` calls: none
/// if its FMAs (AES ops, clmul/xperm ops) are inline (fmad/fmas, aes, bk
/// then cleared).
fn helpers(x: *Use) void {
    if (x.nfma <= fma_inline_max) {
        x.fmad = false;
        x.fmas = false;
    }
    if (x.naes <= aes_inline_max) x.aes = 0;
    if (x.nbk <= bk_inline_max) x.bk = 0;
}

/// Blocks with at most this many AES table ops (aes64es/esm/ds/dsm/im) get
/// them inline; more call one helper function per kind, shared by the
/// module. Decided per block, like FMAs.
const aes_inline_max = 4;

/// Register file offsets (core.Regs: x[32], pc, f[32], fcsr).
const f_off: u64 = 33 * 8;
const fcsr_off: u64 = 65 * 8;
const box_hi: u64 = 0xffff_ffff_0000_0000;
const sign_d: u64 = 1 << 63;
const sign_s: u64 = 1 << 31;
const inf_d: u64 = 0x7ff0_0000_0000_0000;
const inf_s: u64 = 0x7f80_0000;
const qnan_d: u64 = 0x7ff8_0000_0000_0000;
const qnan_s: u64 = 0x7fc0_0000;

const priv_off = @offsetOf(Cpu, "priv");
const tlb_r_off = priv_off + @offsetOf(@FieldType(Cpu, "priv"), "tlb_r");
const tlb_w_off = priv_off + @offsetOf(@FieldType(Cpu, "priv"), "tlb_w");
/// Data-TLB index mask applied to va >> 8: (entries - 1) * 16-byte entries.
const dtlb_mask: u64 = (@typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_r")).array.len - 1) << 4;

const Emit = struct {
    buf: *[buf_size]u8,
    pos: usize = 0,
    ok: bool = true,
    mem32: bool,
    /// The kernel's memory is shared (cap_shared): the import says so.
    shared: bool = false,
    /// Open blocks/loops/ifs; the exit block is the outermost.
    nest: u32 = 0,
    /// The frm == RNE test for dynamic rounding modes has been emitted (frm
    /// cannot change inside compiled code, so the first test covers every
    /// later op of the pass). Per region member: a member can be entered
    /// without running the code of the members emitted before it.
    frm_checked: bool = false,
    /// Function indices of the FMA helpers (0 = not in this module).
    fn_fmad: u32 = 0,
    fn_fmas: u32 = 0,
    /// FMA bodies are emitted inline (see fma_inline_max).
    fma_inline: bool = false,
    /// Function indices of the AES helpers per `AesK` (0 = not in this module).
    fn_aes: [n_aes_k]u32 = @splat(0),
    /// AES bodies are emitted inline (see aes_inline_max).
    aes_inline: bool = false,
    /// Function indices of the clmul/xperm helpers per `BkK` (0 = not in
    /// this module).
    fn_bk: [n_bk_k]u32 = @splat(0),
    /// clmul/xperm bodies are emitted inline (see bk_inline_max).
    bk_inline: bool = false,
    /// While an inline FMA body is emitted: the nesting level of its
    /// result block (its "return" is a br there).
    fma_nest: u32 = 0,
    /// Emitting the members of a region (see `emitMembers`).
    rg: ?*Region = null,

    fn op(e: *Emit, b: u8) void {
        if (e.pos < buf_size) {
            e.buf[e.pos] = b;
            e.pos += 1;
        } else e.ok = false;
    }
    fn ops(e: *Emit, bs: []const u8) void {
        for (bs) |b| e.op(b);
    }
    fn uleb(e: *Emit, v0: u64) void {
        var v = v0;
        while (true) {
            const b: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v == 0) return e.op(b);
            e.op(b | 0x80);
        }
    }
    fn sleb(e: *Emit, v0: i64) void {
        var v = v0;
        while (true) {
            const b: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7f);
            v >>= 7;
            if ((v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0)) return e.op(b);
            e.op(b | 0x80);
        }
    }
    /// A 5-byte (padded) u32 LEB placeholder; returns its position.
    fn reserve(e: *Emit) usize {
        const at = e.pos;
        e.ops(&.{ 0x80, 0x80, 0x80, 0x80, 0x00 });
        return at;
    }
    /// Patch a placeholder with the byte count from after it to the end.
    fn patch(e: *Emit, at: usize) void {
        if (!e.ok) return;
        var v: u32 = @intCast(e.pos - at - 5);
        for (0..5) |i| {
            e.buf[at + i] = @as(u8, @truncate(v & 0x7f)) | (if (i < 4) @as(u8, 0x80) else 0);
            v >>= 7;
        }
    }
    fn k64(e: *Emit, v: u64) void {
        e.op(W.i64_const);
        e.sleb(@bitCast(v));
    }
    fn k32(e: *Emit, v: i32) void {
        e.op(W.i32_const);
        e.sleb(v);
    }
    fn get(e: *Emit, l: u32) void {
        e.op(W.local_get);
        e.uleb(l);
    }
    fn set(e: *Emit, l: u32) void {
        e.op(W.local_set);
        e.uleb(l);
    }
    fn tee(e: *Emit, l: u32) void {
        e.op(W.local_tee);
        e.uleb(l);
    }
    fn kf(e: *Emit, v: f64) void {
        e.op(W.f64_const);
        const u: u64 = @bitCast(v);
        for (0..8) |i| e.op(@truncate(u >> @intCast(8 * i)));
    }
    fn call(e: *Emit, f: u32) void {
        e.op(W.call);
        e.uleb(f);
    }
    fn gget(e: *Emit) void {
        e.ops(&.{ W.global_get, 0 });
    }
    fn gset(e: *Emit) void {
        e.ops(&.{ W.global_set, 0 });
    }
    /// local l (i64) as f64 / an f32 held in the low 32 bits, widened.
    fn getD(e: *Emit, l: u32) void {
        e.get(l);
        e.op(W.f64_reinterpret);
    }
    fn getS(e: *Emit, l: u32) void {
        e.get(l);
        e.ops(&.{ W.i32_wrap, W.f32_reinterpret, W.f64_promote });
    }
    /// Push guest register r (x0 reads as 0).
    fn reg(e: *Emit, r: u8) void {
        if (r == 0) e.k64(0) else e.get(lreg(r));
    }
    /// Pop into guest register r (x0 / the redirected x0 slot: dropped).
    fn setReg(e: *Emit, r: u8) void {
        if (r == 0 or r >= 32) e.op(W.drop) else e.set(lreg(r));
    }
    /// The i64 address on the stack becomes a memory address operand.
    fn addr(e: *Emit) void {
        if (e.mem32) e.op(W.i32_wrap);
    }
    fn mem(e: *Emit, opc: u8, alignment: u8, off: u64) void {
        e.op(opc);
        e.uleb(alignment);
        e.uleb(off);
    }
    /// Push *irqp (the CPU's word of pending interrupts). With a shared
    /// memory another CPU sets it (an IPI: a TLB shootdown waits for the
    /// answer), so the load is atomic (i32.atomic.load, a plain load on
    /// x86-64 and arm64): an engine may hoist a plain load out of a loop
    /// that stores nothing, which would leave a compiled self-loop deaf.
    fn irqWord(e: *Emit) void {
        e.get(l_irq);
        e.addr();
        if (e.shared) {
            e.ops(&.{ 0xfe, 0x10 }); // i32.atomic.load
            e.uleb(2);
            e.uleb(0);
        } else e.mem(W.i32_load, 2, 0);
    }
    fn open(e: *Emit, kind: u8, bt: u8) void {
        e.op(kind);
        e.op(bt);
        e.nest += 1;
    }
    fn close(e: *Emit) void {
        e.op(W.end);
        e.nest -= 1;
    }
    fn brExit(e: *Emit) void {
        e.op(W.br);
        e.uleb(e.nest - 1);
    }
    fn exit(e: *Emit, npc: u64, code: u64) void {
        e.k64(npc);
        e.set(l_npc);
        e.k64(code);
        e.set(l_code);
    }
    /// Leave the function: hand op k (at pc) back to the interpreter.
    fn handBack(e: *Emit, k: usize, pc: u64) void {
        e.exit(pc, k);
        e.brExit();
    }
};

const Error = error{ Unsupported, Overflow };

/// Translate block `b`, at most its first `limit.*` ops, or region `rg`
/// (whose member 0 is b; members are emitted in full and `limit` only
/// reports b's translated prefix), into a module in cpu.priv.jit.buf;
/// returns its length. On error.Overflow, `limit.*` is the number of ops of
/// b that were emitted.
fn emitModule(cpu: *Cpu, b: *const Block, rg: ?*Region, limit: *usize) Error!usize {
    const all = cpu.priv.ops[b.op..][0..b.n];
    var u: usize = 0;
    while (u < all.len and u < limit.* and supported(all[u])) u += 1;
    if (u == 0) return error.Unsupported;
    limit.* = u;
    const full = u == all.len;
    const last = all[all.len - 1];
    const self_loop = rg == null and full and switch (last.h) {
        .beq, .bne, .blt, .bge, .bltu, .bgeu, .jal, .goto => last.imm == b.pc,
        else => false,
    };
    var use: Use = .{};
    for (all[0..u]) |o| use.add(usage(o));
    const fma_inline = use.nfma <= fma_inline_max;
    const aes_inline = use.naes <= aes_inline_max;
    const bk_inline = use.nbk <= bk_inline_max;
    helpers(&use);
    // A region's prologue and epilogue cover the union over its members
    // (integer and FP registers, fcsr, FMA, AES and clmul/xperm helpers):
    // one member may enter another without returning.
    if (rg) |r| regionUse(cpu, r, &use);
    // Load every register the block writes as well: a hand-back writes all
    // of them back, including those the executed part did not reach.
    const live = use.read | use.write;
    const flive = use.fread | use.fwrite;

    var e: Emit = .{ .buf = &cpu.priv.jit.buf, .mem32 = cpu.priv.jit.caps & cap_mem32 != 0, .shared = cpu.priv.jit.caps & cap_shared != 0 };
    e.rg = rg;
    e.fma_inline = fma_inline; // a region's members set their own
    e.aes_inline = aes_inline;
    e.bk_inline = bk_inline;
    var nfn: u32 = 1;
    if (use.fmad) {
        e.fn_fmad = nfn;
        nfn += 1;
    }
    if (use.fmas) {
        e.fn_fmas = nfn;
        nfn += 1;
    }
    for (0..n_aes_k) |i| {
        if (use.aes & (@as(u8, 1) << @intCast(i)) == 0) continue;
        e.fn_aes[i] = nfn;
        nfn += 1;
    }
    for (0..n_bk_k) |i| {
        if (use.bk & (@as(u8, 1) << @intCast(i)) == 0) continue;
        e.fn_bk[i] = nfn;
        nfn += 1;
    }
    e.ops(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // type 0: (i64 i64 i64 i64) -> i64 (f); type 1: (i64 i64 i64) -> i64 (the helpers)
    e.ops(&.{ 0x01, 0x10, 0x02, 0x60, 0x04, W.i64_t, W.i64_t, W.i64_t, W.i64_t, 0x01, W.i64_t });
    e.ops(&.{ 0x60, 0x03, W.i64_t, W.i64_t, W.i64_t, 0x01, W.i64_t });
    // import env.memory: memory64 (flags 4) or memory32, min 0; a shared
    // memory (flags | 3) needs a maximum, which an import matches when the
    // memory's is not larger: 65536 pages (4 GiB) for memory32, 262144
    // (16 GiB, the kernel's --max-memory) for memory64.
    e.ops(&.{ 0x02, if (e.shared) 0x12 else 0x0f, 0x01, 0x03, 'e', 'n', 'v', 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02 });
    if (e.shared)
        e.ops(&.{ if (e.mem32) 0x03 else 0x07, 0x00, 0x80, 0x80, if (e.mem32) 0x04 else 0x10 })
    else
        e.ops(&.{ if (e.mem32) 0x00 else 0x04, 0x00 });
    // functions: f (type 0), then the helpers (type 1)
    e.ops(&.{ 0x03, @intCast(1 + nfn), @intCast(nfn), 0x00 });
    for (1..nfn) |_| e.op(0x01);
    // the helpers' status word: global 0, mutable i32 (not exported)
    if (nfn > 1) e.ops(&.{ 0x06, 0x06, 0x01, 0x7f, 0x01, W.i32_const, 0x00, W.end });
    // export "f"
    e.ops(&.{ 0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00 });
    e.op(0x0a);
    const code_sec = e.reserve();
    e.uleb(nfn);
    const body = e.reserve();
    // locals: i64 x n_i64, f64 x n_f64, and a region's i64 x n_region_locals
    e.op(if (rg != null) 0x03 else 0x02);
    e.uleb(n_i64);
    e.op(W.i64_t);
    e.uleb(n_f64);
    e.op(W.f64_t);
    if (rg != null) {
        e.uleb(n_region_locals);
        e.op(W.i64_t);
    }

    // cpu == 0 (never from `run`): return at once. The host calls f so
    // inside kw_host_jit_compile, so that an engine that compiles a
    // function only at its first call (V8) does it there, inside the
    // jit_busy window, instead of in `run`'s first call (kw_emu.h).
    e.get(l_cpu);
    e.op(W.i64_eqz);
    e.open(W.@"if", W.void_t);
    e.k64(0);
    e.op(W.@"return");
    e.close();

    // prologue
    for (1..32) |r| {
        if (live & (@as(u32, 1) << @intCast(r)) == 0) continue;
        e.get(l_x);
        e.addr();
        e.mem(W.i64_load, 3, r * 8);
        e.set(lreg(@intCast(r)));
    }
    for (0..32) |r| {
        if (flive & (@as(u32, 1) << @intCast(r)) == 0) continue;
        e.get(l_x);
        e.addr();
        e.mem(W.i64_load, 3, f_off + r * 8);
        e.set(lf(@intCast(r)));
    }
    if (use.fcsr_r or use.fcsr_w) {
        e.get(l_x);
        e.addr();
        e.mem(W.i64_load32_u, 2, fcsr_off);
        e.set(l_fcsr);
    }
    e.open(W.block, W.void_t); // exit
    if (rg) |r| emitMembers(&e, cpu, r) else {
        if (self_loop) e.open(W.loop, W.void_t);
        var pc = b.pc;
        for (all[0..u], 0..) |o, k| {
            emitOp(&e, o, k, pc, b, self_loop);
            pc = kwemu.nextPc(o, pc);
        }
        if (!full) e.handBack(u, pc);
        if (self_loop) e.close();
    }
    e.close();

    // epilogue: write back, pc, return (jl << 8) | code
    for (1..32) |r| {
        if (use.write & (@as(u32, 1) << @intCast(r)) == 0) continue;
        e.get(l_x);
        e.addr();
        e.get(lreg(@intCast(r)));
        e.mem(W.i64_store, 3, r * 8);
    }
    for (0..32) |r| {
        if (use.fwrite & (@as(u32, 1) << @intCast(r)) == 0) continue;
        e.get(l_x);
        e.addr();
        e.get(lf(@intCast(r)));
        e.mem(W.i64_store, 3, f_off + r * 8);
    }
    if (use.fcsr_w) {
        e.get(l_x);
        e.addr();
        e.get(l_fcsr);
        e.mem(W.i64_store32, 2, fcsr_off);
    }
    e.get(l_x);
    e.addr();
    e.get(l_npc);
    e.mem(W.i64_store, 3, 32 * 8);
    if (rg != null) regionExit(&e);
    e.get(l_jl);
    e.k64(8);
    e.op(W.i64_shl);
    e.get(l_code);
    e.op(W.i64_or);
    e.op(W.end);
    e.patch(body);
    if (e.fn_fmad != 0) fmaBody(&e, u64, false);
    if (e.fn_fmas != 0) fmaBody(&e, u32, false);
    for (0..n_aes_k) |i| if (e.fn_aes[i] != 0) aesHelper(&e, @enumFromInt(i));
    for (0..n_bk_k) |i| if (e.fn_bk[i] != 0) bkHelper(&e, @enumFromInt(i));
    e.patch(code_sec);
    if (!e.ok) return error.Overflow;
    return e.pos;
}

/// Self-loop back edge: stop (pc = block start, done) on a pending
/// interrupt or when the budget does not cover another pass.
fn backEdge(e: *Emit, b: *const Block) void {
    e.irqWord();
    e.get(l_jl);
    e.k64(b.ninsn);
    e.op(W.i64_lt_u);
    e.op(W.i32_or);
    e.open(W.@"if", W.void_t);
    e.exit(b.pc, code_done_stop);
    e.brExit();
    e.close();
    e.get(l_jl);
    e.k64(b.ninsn);
    e.op(W.i64_sub);
    e.set(l_jl);
    e.op(W.br);
    e.uleb(e.nest - 2); // the loop
}

fn cmpOp(h: exec.H) u8 {
    return switch (h) {
        .beq, .beq_x => W.i64_eq,
        .bne, .bne_x => W.i64_ne,
        .blt, .blt_x => W.i64_lt_s,
        .bge, .bge_x => W.i64_ge_s,
        .bltu, .bltu_x => W.i64_lt_u,
        .bgeu, .bgeu_x => W.i64_ge_u,
        else => unreachable,
    };
}

/// Upper 64 bits of the unsigned product of x[rs1] and x[rs2] (t0..t4).
fn mulhu(e: *Emit, o: Op) void {
    const t0 = l_t0;
    const t1 = l_t0 + 1;
    const t2 = l_t0 + 2;
    const t3 = l_t0 + 3;
    const t4 = l_t0 + 4;
    const lo: u64 = 0xffff_ffff;
    e.reg(o.rs1);
    e.k64(lo);
    e.op(W.i64_and);
    e.set(t0);
    e.reg(o.rs1);
    e.k64(32);
    e.op(W.i64_shr_u);
    e.set(t1);
    e.reg(o.rs2);
    e.k64(lo);
    e.op(W.i64_and);
    e.set(t2);
    e.reg(o.rs2);
    e.k64(32);
    e.op(W.i64_shr_u);
    e.set(t3);
    // t4 = ahi*blo + (alo*blo >> 32)
    e.get(t1);
    e.get(t2);
    e.op(W.i64_mul);
    e.get(t0);
    e.get(t2);
    e.op(W.i64_mul);
    e.k64(32);
    e.op(W.i64_shr_u);
    e.op(W.i64_add);
    e.set(t4);
    // ahi*bhi + (t4 >> 32) + ((alo*bhi + (t4 & lo)) >> 32)
    e.get(t1);
    e.get(t3);
    e.op(W.i64_mul);
    e.get(t4);
    e.k64(32);
    e.op(W.i64_shr_u);
    e.op(W.i64_add);
    e.get(t0);
    e.get(t3);
    e.op(W.i64_mul);
    e.get(t4);
    e.k64(lo);
    e.op(W.i64_and);
    e.op(W.i64_add);
    e.k64(32);
    e.op(W.i64_shr_u);
    e.op(W.i64_add);
}

/// Signed-operand correction: subtract ((s >> 63) & other).
fn mulCorr(e: *Emit, s: u8, other: u8) void {
    e.reg(s);
    e.k64(63);
    e.op(W.i64_shr_s);
    e.reg(other);
    e.op(W.i64_and);
    e.op(W.i64_sub);
}

/// x[rs2] == 0 test for the M-extension divisions (`w`: low 32 bits).
fn divZero(e: *Emit, o: Op, w: bool) void {
    e.reg(o.rs2);
    if (w) {
        e.op(W.i32_wrap);
        e.op(W.i32_eqz);
    } else e.op(W.i64_eqz);
    e.open(W.@"if", W.i64_t);
}

fn lo32(e: *Emit, r: u8) void {
    e.reg(r);
    e.op(W.i32_wrap);
}

fn emitOp(e: *Emit, o: Op, k: usize, pc: u64, b: *const Block, self_loop: bool) void {
    switch (o.h) {
        .addi, .andi, .ori, .xori, .addiw => {
            e.reg(o.rs1);
            e.k64(o.imm);
            e.op(switch (o.h) {
                .addi, .addiw => W.i64_add,
                .andi => W.i64_and,
                .ori => W.i64_or,
                else => W.i64_xor,
            });
            if (o.h == .addiw) e.ops(&.{ W.i32_wrap, W.i64_ext_s });
            e.setReg(o.rd);
        },
        .slti, .sltiu => {
            e.reg(o.rs1);
            e.k64(o.imm);
            e.ops(&.{ if (o.h == .slti) W.i64_lt_s else W.i64_lt_u, W.i64_ext_u });
            e.setReg(o.rd);
        },
        .slli, .srli, .srai => {
            e.reg(o.rs1);
            e.k64(o.imm & 63);
            e.op(switch (o.h) {
                .slli => W.i64_shl,
                .srli => W.i64_shr_u,
                else => W.i64_shr_s,
            });
            e.setReg(o.rd);
        },
        .slliw, .srliw, .sraiw => {
            lo32(e, o.rs1);
            e.k32(@intCast(o.imm & 31));
            e.op(switch (o.h) {
                .slliw => W.i32_shl,
                .srliw => W.i32_shr_u,
                else => W.i32_shr_s,
            });
            e.op(W.i64_ext_s);
            e.setReg(o.rd);
        },
        .li => {
            e.k64(o.imm);
            e.setReg(o.rd);
        },
        .add, .sub, .and_, .or_, .xor_, .sll, .srl, .sra, .mul, .addw, .subw, .mulw => {
            e.reg(o.rs1);
            e.reg(o.rs2);
            e.op(switch (o.h) {
                .add, .addw => W.i64_add,
                .sub, .subw => W.i64_sub,
                .and_ => W.i64_and,
                .or_ => W.i64_or,
                .xor_ => W.i64_xor,
                .sll => W.i64_shl, // wasm masks the count to 6 bits, as RV does
                .srl => W.i64_shr_u,
                .sra => W.i64_shr_s,
                else => W.i64_mul,
            });
            if (o.h == .addw or o.h == .subw or o.h == .mulw) e.ops(&.{ W.i32_wrap, W.i64_ext_s });
            e.setReg(o.rd);
        },
        .slt, .sltu => {
            e.reg(o.rs1);
            e.reg(o.rs2);
            e.ops(&.{ if (o.h == .slt) W.i64_lt_s else W.i64_lt_u, W.i64_ext_u });
            e.setReg(o.rd);
        },
        .sllw, .srlw, .sraw => {
            lo32(e, o.rs1);
            lo32(e, o.rs2); // wasm masks the count to 5 bits
            e.op(switch (o.h) {
                .sllw => W.i32_shl,
                .srlw => W.i32_shr_u,
                else => W.i32_shr_s,
            });
            e.op(W.i64_ext_s);
            e.setReg(o.rd);
        },
        .mulhu, .mulh, .mulhsu => {
            mulhu(e, o);
            if (o.h != .mulhu) mulCorr(e, o.rs1, o.rs2);
            if (o.h == .mulh) mulCorr(e, o.rs2, o.rs1);
            e.setReg(o.rd);
        },
        .div, .divu, .rem, .remu => {
            // RV: x/0 = -1 (all ones), x%0 = x, MIN/-1 = MIN, MIN%-1 = 0
            // (wasm rem_s(MIN, -1) is 0; div_s would trap, so divide by 1).
            divZero(e, o, false);
            if (o.h == .div or o.h == .divu) e.k64(std.math.maxInt(u64)) else e.reg(o.rs1);
            e.op(W.@"else");
            e.reg(o.rs1);
            if (o.h == .div) {
                e.k64(1);
                e.reg(o.rs2);
                e.reg(o.rs1);
                e.k64(1 << 63);
                e.op(W.i64_eq);
                e.reg(o.rs2);
                e.k64(std.math.maxInt(u64));
                e.op(W.i64_eq);
                e.op(W.i32_and);
                e.op(W.select);
            } else e.reg(o.rs2);
            e.op(switch (o.h) {
                .div => W.i64_div_s,
                .divu => W.i64_div_u,
                .rem => W.i64_rem_s,
                else => W.i64_rem_u,
            });
            e.close();
            e.setReg(o.rd);
        },
        .divw, .divuw, .remw, .remuw => {
            divZero(e, o, true);
            if (o.h == .divw or o.h == .divuw) e.k64(std.math.maxInt(u64)) else {
                lo32(e, o.rs1);
                e.op(W.i64_ext_s);
            }
            e.op(W.@"else");
            lo32(e, o.rs1);
            if (o.h == .divw) {
                e.k32(1);
                lo32(e, o.rs2);
                lo32(e, o.rs1);
                e.k32(std.math.minInt(i32));
                e.op(W.i32_eq);
                lo32(e, o.rs2);
                e.k32(-1);
                e.op(W.i32_eq);
                e.op(W.i32_and);
                e.op(W.select);
            } else lo32(e, o.rs2);
            e.op(switch (o.h) {
                .divw => W.i32_div_s,
                .divuw => W.i32_div_u,
                .remw => W.i32_rem_s,
                else => W.i32_rem_u,
            });
            e.op(W.i64_ext_s);
            e.close();
            e.setReg(o.rd);
        },
        .lb, .lh, .lw, .ld, .lbu, .lhu, .lwu => {
            const size: u64, const opc: u8 = switch (o.h) {
                .lb => .{ 1, 0x30 },
                .lbu => .{ 1, 0x31 },
                .lh => .{ 2, 0x32 },
                .lhu => .{ 2, 0x33 },
                .lw => .{ 4, 0x34 },
                .lwu => .{ 4, 0x35 },
                else => .{ 8, 0x29 },
            };
            hostAddr(e, o, k, pc, tlb_r_off, size);
            e.mem(opc, 0, 0);
            e.setReg(o.rd);
        },
        .sb, .sh, .sw, .sd => {
            const size: u64, const opc: u8 = switch (o.h) {
                .sb => .{ 1, 0x3c },
                .sh => .{ 2, 0x3d },
                .sw => .{ 4, 0x3e },
                else => .{ 8, 0x37 },
            };
            hostAddr(e, o, k, pc, tlb_w_off, size);
            e.reg(o.rs2);
            e.mem(opc, 0, 0);
        },
        .nop => {},
        .beq_x, .bne_x, .blt_x, .bge_x, .bltu_x, .bgeu_x => {
            e.reg(o.rs1);
            e.reg(o.rs2);
            e.op(cmpOp(o.h));
            e.open(W.@"if", W.void_t);
            if (e.rg) |r| regionSide(e, r, o.imm, k, b) else {
                e.exit(o.imm, code_side + k);
                e.brExit();
            }
            e.close();
        },
        .jal_c => {
            e.k64(o.imm);
            e.setReg(o.rd);
        },
        .beq, .bne, .blt, .bge, .bltu, .bgeu => {
            if (self_loop) {
                e.reg(o.rs1);
                e.reg(o.rs2);
                e.op(cmpOp(o.h));
                e.open(W.@"if", W.void_t);
                backEdge(e, b);
                e.close();
                e.exit(b.end_pc, code_done);
            } else {
                e.k64(o.imm);
                e.k64(b.end_pc);
                e.reg(o.rs1);
                e.reg(o.rs2);
                e.op(cmpOp(o.h));
                e.op(W.select);
                e.set(l_npc);
                e.k64(code_done);
                e.set(l_code);
            }
        },
        .jal => {
            e.k64(b.end_pc);
            e.setReg(o.rd);
            if (self_loop) backEdge(e, b) else e.exit(o.imm, code_done);
        },
        .jalr => {
            e.reg(o.rs1);
            e.k64(o.imm);
            e.op(W.i64_add);
            e.k64(~@as(u64, 1));
            e.op(W.i64_and);
            e.set(l_npc);
            e.k64(b.end_pc);
            e.setReg(o.rd);
            e.k64(code_done);
            e.set(l_code);
        },
        .goto => {
            if (self_loop) backEdge(e, b) else e.exit(o.imm, code_done);
        },
        .flw, .fld => {
            const size: u64 = if (o.h == .flw) 4 else 8;
            hostAddr(e, o, k, pc, tlb_r_off, size);
            if (o.h == .flw) {
                e.mem(W.i64_load32_u, 0, 0);
                e.k64(box_hi);
                e.op(W.i64_or);
            } else e.mem(W.i64_load, 0, 0);
            e.set(lf(o.rd));
        },
        .fsw, .fsd => {
            hostAddr(e, o, k, pc, tlb_w_off, if (o.h == .fsw) 4 else 8);
            e.get(lf(o.rs2)); // fsw stores the low 32 bits as they are (no unboxing)
            e.mem(if (o.h == .fsw) W.i64_store32 else W.i64_store, 0, 0);
        },
        .fmv_x_w => {
            e.get(lf(o.rs1));
            e.ops(&.{ W.i32_wrap, W.i64_ext_s });
            e.setReg(o.rd);
        },
        .fmv_x_d => {
            e.get(lf(o.rs1));
            e.setReg(o.rd);
        },
        .fmv_w_x, .fmv_d_x => { // f[rd] = x[rs1] | imm (fli: rs1 = x0)
            if (o.rs1 == 0) {
                e.k64((if (o.h == .fmv_w_x) box_hi else 0) | o.imm);
            } else {
                e.reg(o.rs1);
                if (o.h == .fmv_w_x or o.imm != 0) {
                    e.k64((if (o.h == .fmv_w_x) box_hi else 0) | o.imm);
                    e.op(W.i64_or);
                }
            }
            e.set(lf(o.rd));
        },
        .fsgnj_s, .fsgnj_d => if (o.imm < 4) fSgnj(e, o) else if (o.imm < 8) fMinMax(e, o) else fRound(e, o, k, pc),
        .fcmp_s, .fcmp_d => fCmp(e, o),
        .fadd_s, .fsub_s, .fmul_s, .fdiv_s, .fadd_d, .fsub_d, .fmul_d, .fdiv_d => fArith(e, o, k, pc),
        .fmadd_s, .fmsub_s, .fnmsub_s, .fnmadd_s, .fmadd_d, .fmsub_d, .fnmsub_d, .fnmadd_d => fFma(e, o, k, pc),
        .generic => fGeneric(e, o.raw, k, pc),
        .aes64es, .aes64esm, .aes64ds, .aes64dsm, .aes64im => {
            const kind = aesKind(o.h);
            if (e.aes_inline) {
                aesBody(e, kind, .{ .reg = o.rs1 }, .{ .reg = o.rs2 }, .{ .local = l_cpu });
            } else {
                e.reg(o.rs1);
                e.reg(o.rs2);
                e.get(l_cpu);
                e.call(e.fn_aes[@intFromEnum(kind)]);
            }
            e.setReg(o.rd);
        },
        .aes64ks1i => aesKs1i(e, o),
        .andn, .orn, .xnor, .rol, .ror, .rolw, .rorw, .pack, .packh, .packw, .rori, .roriw, .rev8, .brev8 => bkSimple(e, o),
        .shadd, .clz, .ctz, .cpop, .minmax, .sext, .orc_b, .bitop, .bext, .czero => zbOp(e, o),
        .clmul, .clmulh, .clmulr, .xperm4, .xperm8 => {
            const kind = bkKind(o.h);
            if (e.bk_inline) {
                bkBody(e, kind, .{ .reg = o.rs1 }, .{ .reg = o.rs2 }, l_bk);
            } else {
                e.reg(o.rs1);
                e.reg(o.rs2);
                e.k64(0);
                e.call(e.fn_bk[@intFromEnum(kind)]);
            }
            e.setReg(o.rd);
        },
        .aes64ks2 => {
            // w0 = hi(rs1) ^ lo(rs2); rd = (w0 ^ hi(rs2)) << 32 | w0
            e.reg(o.rs1);
            e.k64(32);
            e.op(W.i64_shr_u);
            e.reg(o.rs2);
            e.op(W.i64_xor);
            e.k64(0xffff_ffff);
            e.op(W.i64_and);
            e.tee(l_t0);
            e.reg(o.rs2);
            e.k64(32);
            e.op(W.i64_shr_u);
            e.op(W.i64_xor);
            e.k64(32);
            e.op(W.i64_shl);
            e.get(l_t0);
            e.op(W.i64_or);
            e.setReg(o.rd);
        },
        else => unreachable,
    }
}

// ---- Zkne / Zknd -----------------------------------------------------------------
//
// The same results as core.aes, from the tables in `AesTab` (cpu-relative):
// SubBytes is a byte-table load, SubBytes + (Inv)MixColumns of a column is
// four word-table loads, rotated by row, XORed. Pure integer code, so the
// results are exact by construction; the tests compare them with the
// interpreter (core.aes, which computes MixColumns arithmetically).

const AesK = enum(u3) { es, esm, ds, dsm, im };
const n_aes_k = @typeInfo(AesK).@"enum".field_names.len;

fn aesKind(h: exec.H) AesK {
    return switch (h) {
        .aes64es => .es,
        .aes64esm => .esm,
        .aes64ds => .ds,
        .aes64dsm => .dsm,
        .aes64im => .im,
        else => unreachable,
    };
}

const aes_off = jit_off + @offsetOf(State, "aes");

/// An i64 operand: a guest register (x0 reads as 0) or a local.
const Src = union(enum) {
    reg: u8,
    local: u32,

    fn push(s: Src, e: *Emit) void {
        switch (s) {
            .reg => |r| e.reg(r),
            .local => |l| e.get(l),
        }
    }
};

/// Push the address cpu + (byte k of src) << sc (sc = 2: a u32 table).
fn aesIdx(e: *Emit, src: Src, k: u6, sc: u6, cpu: Src) void {
    src.push(e);
    const sh: i32 = 8 * @as(i32, k) - @as(i32, sc);
    if (sh > 0) {
        e.k64(@intCast(sh));
        e.op(W.i64_shr_u);
    } else if (sh < 0) {
        e.k64(@intCast(-sh));
        e.op(W.i64_shl);
    }
    e.k64(@as(u64, 0xff) << sc);
    e.op(W.i64_and);
    cpu.push(e);
    e.op(W.i64_add);
    e.addr();
}

/// Push the i64 result of AES op `kind` on operands a (rs1) and b (rs2).
fn aesBody(e: *Emit, kind: AesK, a: Src, b: Src, cpu: Src) void {
    // state bytes of the result's 8 bytes before SubBytes: (operand b?, byte)
    const BS = struct { bool, u6 };
    const fwd = [8]BS{ .{ false, 0 }, .{ false, 5 }, .{ true, 2 }, .{ true, 7 }, .{ false, 4 }, .{ true, 1 }, .{ true, 6 }, .{ false, 3 } };
    const inv = [8]BS{ .{ false, 0 }, .{ true, 5 }, .{ true, 2 }, .{ false, 7 }, .{ false, 4 }, .{ false, 1 }, .{ true, 6 }, .{ true, 3 } };
    const ident = [8]BS{ .{ false, 0 }, .{ false, 1 }, .{ false, 2 }, .{ false, 3 }, .{ false, 4 }, .{ false, 5 }, .{ false, 6 }, .{ false, 7 } };
    const src = switch (kind) {
        .es, .esm => fwd,
        .ds, .dsm => inv,
        .im => ident,
    };
    switch (kind) {
        .es, .ds => {
            const off: u64 = aes_off + @as(u64, if (kind == .es) @offsetOf(AesTab, "s") else @offsetOf(AesTab, "is"));
            for (src, 0..) |sb, j| {
                aesIdx(e, if (sb[0]) b else a, sb[1], 0, cpu);
                e.mem(W.i64_load8_u, 0, off);
                if (j > 0) {
                    e.k64(8 * j);
                    e.op(W.i64_shl);
                    e.op(W.i64_or);
                }
            }
        },
        .esm, .dsm, .im => {
            const off: u64 = aes_off + @as(u64, switch (kind) {
                .esm => @offsetOf(AesTab, "te"),
                .dsm => @offsetOf(AesTab, "td"),
                else => @offsetOf(AesTab, "im"),
            });
            for (0..2) |c| {
                for (0..4) |r| {
                    const sb = src[4 * c + r];
                    aesIdx(e, if (sb[0]) b else a, sb[1], 2, cpu);
                    e.mem(W.i32_load, 2, off);
                    if (r > 0) {
                        e.k32(@intCast(8 * r));
                        e.op(W.i32_rotl);
                        e.op(W.i32_xor);
                    }
                }
                e.op(W.i64_ext_u);
                if (c == 1) {
                    e.k64(32);
                    e.op(W.i64_shl);
                    e.op(W.i64_or);
                }
            }
        },
    }
}

/// A helper function of type 1, (rs1, rs2, cpu) -> result, for AES op `kind`.
fn aesHelper(e: *Emit, kind: AesK) void {
    const body = e.reserve();
    e.op(0x00); // no locals besides the parameters
    aesBody(e, kind, .{ .local = 0 }, .{ .local = 1 }, .{ .local = 2 });
    e.op(W.end);
    e.patch(body);
}

/// aes64ks1i: w = SubWord(rnum == 10 ? hi(rs1) : ror32(hi(rs1), 8)) ^ rcon;
/// rd = w << 32 | w (t0 holds the word).
fn aesKs1i(e: *Emit, o: Op) void {
    const rnum: u4 = @intCast(o.imm & 0xf);
    e.reg(o.rs1);
    e.k64(32);
    e.op(W.i64_shr_u);
    if (rnum != 0xa) {
        e.tee(l_t0);
        e.k64(8);
        e.op(W.i64_shr_u);
        e.get(l_t0);
        e.k64(24);
        e.op(W.i64_shl);
        e.op(W.i64_or);
    }
    e.set(l_t0);
    const off: u64 = aes_off + @offsetOf(AesTab, "s");
    for (0..4) |j| {
        aesIdx(e, .{ .local = l_t0 }, @intCast(j), 0, .{ .local = l_cpu });
        e.mem(W.i64_load8_u, 0, off);
        if (j > 0) {
            e.k64(8 * j);
            e.op(W.i64_shl);
            e.op(W.i64_or);
        }
    }
    e.k64(core.aes.rcon[rnum]);
    e.op(W.i64_xor);
    e.tee(l_t0);
    e.k64(32);
    e.op(W.i64_shl);
    e.get(l_t0);
    e.op(W.i64_or);
    e.setReg(o.rd);
}

// ---- Zbkb / Zbc / Zbkc / Zbkx --------------------------------------------------------
//
// The same results as core.bitmanip, in MVP integer code: rotates are wasm
// rotates (whose counts wrap like RISC-V's), rev8 and brev8 swap bit groups
// with masks, clmul* are core.bitmanip's fixed multiplication sequence
// (bmul64, and bit reversals for the high half), xperm* select every byte
// or nibble with a shift (and `select` for an out-of-range byte index). No
// branches, so like the interpreter's these take the same time for any
// data. clmul* and xperm* are 100-300 instructions: a block with at most
// `bk_inline_max` of them gets them inline, more call one helper per kind.

const BkK = enum(u3) { clmul, clmulh, clmulr, xperm4, xperm8 };
const n_bk_k = @typeInfo(BkK).@"enum".field_names.len;

/// Blocks with at most this many clmul/clmulh/clmulr/xperm4/xperm8 ops get
/// them inline; more call one helper function per kind, shared by the
/// module. Decided per block, like FMAs and AES ops. 12 covers OpenSSL's
/// GHASH loop (6 clmul + 6 clmulh, about 6.5 KB of module inline), which
/// runs 3-4% faster inline than through helpers.
const bk_inline_max = 12;

/// The i64 scratch locals of an inline clmul/xperm body: those of an inline
/// FMA body (which holds nothing across ops either).
const l_bk = l_fma_i;
/// How many of them a body uses (t .. t + 9).
const n_bk_locals = 10;

fn bkKind(h: exec.H) BkK {
    return switch (h) {
        .clmul => .clmul,
        .clmulh => .clmulh,
        .clmulr => .clmulr,
        .xperm4 => .xperm4,
        .xperm8 => .xperm8,
        else => unreachable,
    };
}

/// The i64 on the stack, v -> ((v >> s) & m) | ((v & m) << s): swaps the
/// bit groups that m selects with their neighbours s bits up (t: scratch).
fn swapBits(e: *Emit, s: u6, m: u64, t: u32) void {
    e.tee(t);
    e.k64(s);
    e.op(W.i64_shr_u);
    e.k64(m);
    e.op(W.i64_and);
    e.get(t);
    e.k64(m);
    e.op(W.i64_and);
    e.k64(s);
    e.op(W.i64_shl);
    e.op(W.i64_or);
}
/// Byte-reverse the i64 on the stack (rev8).
fn rev8Seq(e: *Emit, t: u32) void {
    e.k64(32);
    e.op(W.i64_rotl);
    swapBits(e, 16, 0x0000_ffff_0000_ffff, t);
    swapBits(e, 8, 0x00ff_00ff_00ff_00ff, t);
}
/// Reverse the bits of every byte of the i64 on the stack (brev8).
fn brev8Seq(e: *Emit, t: u32) void {
    swapBits(e, 4, 0x0f0f_0f0f_0f0f_0f0f, t);
    swapBits(e, 2, 0x3333_3333_3333_3333, t);
    swapBits(e, 1, 0x5555_5555_5555_5555, t);
}

/// Push clmul(a, b), core.bitmanip.clmul's sequence (locals t .. t + 7).
fn bmul64(e: *Emit, a: Src, b: Src, t: u32) void {
    const m0: u64 = 0x1111_1111_1111_1111;
    for (0..4) |i| {
        a.push(e);
        e.k64(m0 << @intCast(i));
        e.op(W.i64_and);
        e.set(t + @as(u32, @intCast(i)));
    }
    for (0..4) |i| {
        b.push(e);
        e.k64(m0 << @intCast(i));
        e.op(W.i64_and);
        e.set(t + 4 + @as(u32, @intCast(i)));
    }
    for (0..4) |k| {
        for (0..4) |i| {
            e.get(t + @as(u32, @intCast(i)));
            e.get(t + 4 + @as(u32, @intCast((k + 4 - i) % 4)));
            e.op(W.i64_mul);
            if (i > 0) e.op(W.i64_xor);
        }
        e.k64(m0 << @intCast(k));
        e.op(W.i64_and);
        if (k > 0) e.op(W.i64_or);
    }
}

/// Push the i64 result of op `kind` on a (rs1) and b (rs2); scratch locals
/// t .. t + n_bk_locals - 1.
fn bkBody(e: *Emit, kind: BkK, a: Src, b: Src, t: u32) void {
    switch (kind) {
        .clmul => bmul64(e, a, b, t),
        .clmulh, .clmulr => {
            // rev(clmul(rev a, rev b)), shifted right by one for clmulh
            const ra = t + 8;
            const rb = t + 9;
            a.push(e);
            rev8Seq(e, ra);
            brev8Seq(e, ra);
            e.set(ra);
            b.push(e);
            rev8Seq(e, rb);
            brev8Seq(e, rb);
            e.set(rb);
            bmul64(e, .{ .local = ra }, .{ .local = rb }, t);
            rev8Seq(e, ra);
            brev8Seq(e, ra);
            if (kind == .clmulh) {
                e.k64(1);
                e.op(W.i64_shr_u);
            }
        },
        .xperm8 => for (0..8) |i| {
            // idx = byte i of b; (a >> 8 idx) & 0xff if idx < 8, else 0
            b.push(e);
            if (i > 0) {
                e.k64(8 * i);
                e.op(W.i64_shr_u);
            }
            e.k64(0xff);
            e.op(W.i64_and);
            e.set(t);
            a.push(e);
            e.get(t);
            e.k64(3);
            e.op(W.i64_shl);
            e.op(W.i64_shr_u);
            e.k64(0xff);
            e.op(W.i64_and);
            if (i > 0) {
                e.k64(8 * i);
                e.op(W.i64_shl);
            }
            e.k64(0);
            e.get(t);
            e.k64(8);
            e.op(W.i64_lt_u);
            e.op(W.select);
            if (i > 0) e.op(W.i64_or);
        },
        .xperm4 => for (0..16) |i| {
            // (a >> 4 idx) & 0xf, idx = nibble i of b (4 idx = (b >> (4i - 2)) & 0x3c)
            a.push(e);
            b.push(e);
            if (i == 0) {
                e.k64(2);
                e.op(W.i64_shl);
            } else {
                e.k64(4 * i - 2);
                e.op(W.i64_shr_u);
            }
            e.k64(0x3c);
            e.op(W.i64_and);
            e.op(W.i64_shr_u);
            e.k64(0xf);
            e.op(W.i64_and);
            if (i > 0) {
                e.k64(4 * i);
                e.op(W.i64_shl);
                e.op(W.i64_or);
            }
        },
    }
}

/// A helper function of type 1, (rs1, rs2, unused) -> result, for op `kind`.
fn bkHelper(e: *Emit, kind: BkK) void {
    const body = e.reserve();
    e.ops(&.{ 0x01, n_bk_locals, W.i64_t });
    bkBody(e, kind, .{ .local = 0 }, .{ .local = 1 }, 3);
    e.op(W.end);
    e.patch(body);
}

/// The Zbkb ops (and those Zbb shares), always inline.
fn bkSimple(e: *Emit, o: Op) void {
    const ones = std.math.maxInt(u64);
    switch (o.h) {
        .andn, .orn => {
            e.reg(o.rs1);
            e.reg(o.rs2);
            e.k64(ones);
            e.op(W.i64_xor);
            e.op(if (o.h == .andn) W.i64_and else W.i64_or);
        },
        .xnor => {
            e.reg(o.rs1);
            e.reg(o.rs2);
            e.op(W.i64_xor);
            e.k64(ones);
            e.op(W.i64_xor);
        },
        .rol, .ror => {
            e.reg(o.rs1);
            e.reg(o.rs2); // wasm takes the count mod 64, as RISC-V does
            e.op(if (o.h == .rol) W.i64_rotl else W.i64_rotr);
        },
        .rori => {
            e.reg(o.rs1);
            e.k64(o.imm & 63);
            e.op(W.i64_rotr);
        },
        .rolw, .rorw => {
            lo32(e, o.rs1);
            lo32(e, o.rs2); // mod 32
            e.ops(&.{ if (o.h == .rolw) W.i32_rotl else W.i32_rotr, W.i64_ext_s });
        },
        .roriw => {
            lo32(e, o.rs1);
            e.k32(@intCast(o.imm & 31));
            e.ops(&.{ W.i32_rotr, W.i64_ext_s });
        },
        .pack => {
            e.reg(o.rs1);
            e.ops(&.{ W.i32_wrap, W.i64_ext_u });
            e.reg(o.rs2);
            e.k64(32);
            e.op(W.i64_shl);
            e.op(W.i64_or);
        },
        .packh => {
            e.reg(o.rs1);
            e.k64(0xff);
            e.op(W.i64_and);
            e.reg(o.rs2);
            e.k64(0xff);
            e.op(W.i64_and);
            e.k64(8);
            e.op(W.i64_shl);
            e.op(W.i64_or);
        },
        .packw => {
            lo32(e, o.rs1);
            e.k32(0xffff);
            e.op(W.i32_and);
            lo32(e, o.rs2);
            e.k32(16);
            e.op(W.i32_shl);
            e.ops(&.{ W.i32_or, W.i64_ext_s });
        },
        .rev8 => {
            e.reg(o.rs1);
            rev8Seq(e, l_t0);
        },
        .brev8 => {
            e.reg(o.rs1);
            brev8Seq(e, l_t0);
        },
        else => unreachable,
    }
    e.setReg(o.rd);
}

// ---- Zba / Zbb / Zbs / Zicond ------------------------------------------------------
//
// One short MVP sequence per op, specialised on the op's imm (which picks
// the variant, see exec.H): wasm clz/ctz/popcnt (i32 forms for the W
// variants), compare + select for min/max and czero, shifts for sext.b/h
// (sign-extension opcodes are not MVP), shift-and-mask for the bit ops.

fn zbOp(e: *Emit, o: Op) void {
    const ones = std.math.maxInt(u64);
    switch (o.h) {
        .shadd => {
            e.reg(o.rs1);
            if (o.imm & 64 != 0) e.ops(&.{ W.i32_wrap, W.i64_ext_u }); // .uw
            if (o.imm & 63 != 0) {
                e.k64(o.imm & 63);
                e.op(W.i64_shl);
            }
            if (o.rs2 != 0) {
                e.reg(o.rs2);
                e.op(W.i64_add);
            }
        },
        .clz, .ctz, .cpop => {
            const w = o.imm != 0 and o.imm != ones; // clzw, ctzw, cpopw
            if (w) {
                lo32(e, o.rs1);
                e.ops(&.{ switch (o.h) {
                    .clz => W.i32_clz,
                    .ctz => W.i32_ctz,
                    else => W.i32_popcnt,
                }, W.i64_ext_u });
            } else {
                e.reg(o.rs1);
                e.op(switch (o.h) {
                    .clz => W.i64_clz,
                    .ctz => W.i64_ctz,
                    else => W.i64_popcnt,
                });
            }
        },
        .minmax => {
            // select(rs1, rs2, rs1 > rs2) (max) or rs1 < rs2 (min)
            e.reg(o.rs1);
            e.reg(o.rs2);
            e.reg(o.rs1);
            e.reg(o.rs2);
            const u = o.imm >> 63 != 0;
            e.op(if (o.imm & 1 != 0) (if (u) W.i64_gt_u else W.i64_gt_s) else (if (u) W.i64_lt_u else W.i64_lt_s));
            e.op(W.select);
        },
        .sext => {
            e.reg(o.rs1);
            e.k64(o.imm & 63);
            e.op(W.i64_shl);
            e.k64(o.imm & 63);
            e.op(W.i64_shr_s);
        },
        .orc_b => {
            // core.bitmanip.orcb: ((((a & 0x7f..) + 0x7f..) | a) >> 7 & 0x01..) * 0xff
            const lo7: u64 = 0x7f7f_7f7f_7f7f_7f7f;
            e.reg(o.rs1);
            e.k64(lo7);
            e.op(W.i64_and);
            e.k64(lo7);
            e.op(W.i64_add);
            e.reg(o.rs1);
            e.op(W.i64_or);
            e.k64(7);
            e.op(W.i64_shr_u);
            e.k64(0x0101_0101_0101_0101);
            e.op(W.i64_and);
            e.k64(0xff);
            e.op(W.i64_mul);
        },
        .bitop => {
            // bclr (imm 1): a & ~m, bset (3): a | m, binv (2): a ^ m
            e.reg(o.rs1);
            e.k64(1);
            e.reg(o.rs2); // wasm takes the count mod 64, as RISC-V does
            e.op(W.i64_shl);
            if (o.imm == 1) {
                e.k64(ones);
                e.op(W.i64_xor);
            }
            e.op(switch (o.imm) {
                1 => W.i64_and,
                3 => W.i64_or,
                else => W.i64_xor,
            });
        },
        .bext => {
            e.reg(o.rs1);
            if (o.rs2 == 0) e.k64(o.imm & 63) else {
                e.reg(o.rs2);
                if (o.imm != 0) {
                    e.k64(o.imm);
                    e.op(W.i64_add);
                }
            }
            e.op(W.i64_shr_u);
            e.k64(1);
            e.op(W.i64_and);
        },
        .czero => {
            // eqz: select(0, rs1, rs2 == 0); nez: select(rs1, 0, rs2 == 0)
            if (o.imm == 0) {
                e.k64(0);
                e.reg(o.rs1);
            } else {
                e.reg(o.rs1);
                e.k64(0);
            }
            e.reg(o.rs2);
            e.op(W.i64_eqz);
            e.op(W.select);
        },
        else => unreachable,
    }
    e.setReg(o.rd);
}

// ---- F/D -------------------------------------------------------------------------
//
// The emitted code computes exactly what exec.doOp / core.exec compute
// (src/cpu/fpu.zig), bit for bit and flag for flag, or hands the op back:
//   * Pure bit operations (loads, stores, moves, sign injection, NaN-boxing,
//     compares, classify, min/max) are mirrored exactly; wasm float compares
//     are deterministic.
//   * Arithmetic mirrors fpu.zig's RNE fast paths: the same host operation
//     (IEEE round-to-nearest-even in wasm as on the native host), the same
//     result-range test (a normal result with biased exponent in
//     [2, emax - 2], so no NaN, infinity, zero, subnormal or overflow), and
//     the same exact inexact test. Everything outside that range (where the
//     interpreter takes its integer path, or where wasm NaN bits would be
//     nondeterministic) is handed back before it executes.
//   * Rounding: static RNE, or dynamic with frm == RNE (tested at run time;
//     anything else, including an illegal frm, is handed back).
//   * Flags are ORed into a local copy of fcsr, written back at the exit.

/// The bits of FP operand f[r]: the register's local for doubles; for
/// singles the unboxed value (a register that is not NaN-boxed reads as the
/// canonical NaN, core.unbox) zero-extended, in local `tmp`.
fn fsrc(e: *Emit, r: u32, dbl: bool, tmp: u32) u32 {
    if (dbl) return lf(r);
    e.get(lf(r));
    e.k64(qnan_s);
    e.get(lf(r));
    e.k64(box_hi);
    e.op(W.i64_ge_u);
    e.op(W.select);
    e.k64(0xffff_ffff);
    e.op(W.i64_and);
    e.set(tmp);
    return tmp;
}

/// Hand op k back unless frm is RNE (only for a dynamic rounding mode, and
/// only once per module: see Emit.frm_checked).
fn frmCheck(e: *Emit, dyn: bool, k: usize, pc: u64) void {
    if (!dyn or e.frm_checked) return;
    e.frm_checked = true;
    e.get(l_fcsr);
    e.k64(0xe0);
    e.op(W.i64_and);
    e.op(W.i64_eqz);
    e.op(W.i32_eqz);
    e.open(W.@"if", W.void_t);
    e.handBack(k, pc);
    e.close();
}

/// fcsr |= (the i32 condition on the stack) << shift.
fn orFlag(e: *Emit, shift: u6) void {
    e.op(W.i64_ext_u);
    if (shift != 0) {
        e.k64(shift);
        e.op(W.i64_shl);
    }
    e.get(l_fcsr);
    e.op(W.i64_or);
    e.set(l_fcsr);
}

/// Push i32: the biased exponent of the result bits in local l is outside
/// [2, emax - 2] (fpu.zig's fast-path range).
fn outOfRange(e: *Emit, l: u32, dbl: bool) void {
    e.get(l);
    e.k64(if (dbl) 52 else 23);
    e.op(W.i64_shr_u);
    e.k64(if (dbl) 0x7ff else 0xff);
    e.op(W.i64_and);
    e.k64(2);
    e.op(W.i64_sub);
    e.k64(if (dbl) 2044 else 252);
    e.op(W.i64_ge_u);
}

fn handBackIf(e: *Emit, k: usize, pc: u64) void {
    e.open(W.@"if", W.void_t);
    e.handBack(k, pc);
    e.close();
}

/// Push fpu.oddSig of the finite bits in local l (tmp: scratch).
fn oddSig(e: *Emit, l: u32, dbl: bool, tmp: u32) void {
    const mb: u64 = if (dbl) 52 else 23;
    e.get(l);
    e.k64((@as(u64, 1) << @intCast(mb)) - 1);
    e.op(W.i64_and);
    e.get(l);
    e.k64(if (dbl) inf_d else inf_s);
    e.op(W.i64_and);
    e.k64(0);
    e.op(W.i64_ne);
    e.op(W.i64_ext_u);
    e.k64(mb);
    e.op(W.i64_shl);
    e.op(W.i64_or);
    e.tee(tmp);
    e.get(tmp);
    e.op(W.i64_ctz);
    e.op(W.i64_shr_u);
}

/// Push i32: bits in l are a NaN / a signalling NaN (fpu isNan / isSnan).
fn isNan(e: *Emit, l: u32, dbl: bool) void {
    e.get(l);
    e.k64(if (dbl) ~sign_d else sign_s - 1);
    e.op(W.i64_and);
    e.k64(if (dbl) inf_d else inf_s);
    e.op(W.i64_gt_u);
}
fn isSnan(e: *Emit, l: u32, dbl: bool, tmp: u32) void {
    e.get(l);
    e.k64(if (dbl) ~sign_d else sign_s - 1);
    e.op(W.i64_and);
    e.tee(tmp);
    e.k64(if (dbl) inf_d else inf_s);
    e.op(W.i64_gt_u);
    e.get(tmp);
    e.k64(if (dbl) qnan_d else qnan_s);
    e.op(W.i64_lt_u);
    e.op(W.i32_and);
}

/// Push the float compare `la <op> lb` (i32) of the bits in two locals.
fn fCompare(e: *Emit, la: u32, lb: u32, dbl: bool, comptime which: enum { eq, lt, le }) void {
    for ([_]u32{ la, lb }) |l| {
        e.get(l);
        if (dbl) e.op(W.f64_reinterpret) else e.ops(&.{ W.i32_wrap, W.f32_reinterpret });
    }
    e.op(switch (which) {
        .eq => if (dbl) W.f64_eq else W.f32_eq,
        .lt => if (dbl) W.f64_lt else W.f32_lt,
        .le => if (dbl) W.f64_le else W.f32_le,
    });
}

/// Pop result bits into f[rd] (NaN-boxing singles).
fn fdst(e: *Emit, rd: u32, dbl: bool) void {
    if (!dbl) {
        e.k64(box_hi);
        e.op(W.i64_or);
    }
    e.set(lf(rd));
}

fn fSgnj(e: *Emit, o: Op) void {
    const dbl = o.h == .fsgnj_d;
    const sg: u64 = if (dbl) sign_d else sign_s;
    const a = fsrc(e, o.rs1, dbl, l_t5);
    const b = fsrc(e, o.rs2, dbl, l_t5 + 1);
    e.get(a);
    e.k64(sg - 1); // ~sign within the format
    e.op(W.i64_and);
    switch (o.imm) {
        0, 1 => {
            e.get(b);
            e.k64(sg);
            e.op(W.i64_and);
            if (o.imm == 1) {
                e.k64(sg);
                e.op(W.i64_xor);
            }
        },
        else => {
            e.get(a);
            e.get(b);
            e.op(W.i64_xor);
            e.k64(sg);
            e.op(W.i64_and);
        },
    }
    e.op(W.i64_or);
    fdst(e, o.rd, dbl);
}

fn fCmp(e: *Emit, o: Op) void {
    const dbl = o.h == .fcmp_d;
    const a = fsrc(e, o.rs1, dbl, l_t5);
    const b = fsrc(e, o.rs2, dbl, l_t5 + 1);
    // feq, fleq and fltq are quiet compares (NV only for signalling NaNs);
    // flt/fle signal on any NaN.
    if (o.imm == 2 or o.imm >= 4) {
        isSnan(e, a, dbl, l_t5 + 2);
        isSnan(e, b, dbl, l_t5 + 2);
    } else {
        isNan(e, a, dbl);
        isNan(e, b, dbl);
    }
    e.op(W.i32_or);
    orFlag(e, 4);
    switch (o.imm) {
        2 => fCompare(e, a, b, dbl, .eq),
        1, 5 => fCompare(e, a, b, dbl, .lt),
        else => fCompare(e, a, b, dbl, .le),
    }
    e.op(W.i64_ext_u);
    e.setReg(o.rd);
}

/// fmin / fmax, fminm / fmaxm (Zfa): fsgnj kind, imm = 4 | funct3.
fn fMinMax(e: *Emit, o: Op) void {
    const dbl = o.h == .fsgnj_d;
    const a = fsrc(e, o.rs1, dbl, l_t5);
    const b = fsrc(e, o.rs2, dbl, l_t5 + 1);
    const max = o.imm & 1 != 0;
    const m = o.imm & 2 != 0; // fminm / fmaxm: any NaN gives the canonical NaN
    isSnan(e, a, dbl, l_t5 + 2);
    isSnan(e, b, dbl, l_t5 + 2);
    e.op(W.i32_or);
    orFlag(e, 4);
    // nan(a) ? (nan(b) or m ? qnan : b) : nan(b) ? (m ? qnan : a) : compare
    e.k64(if (dbl) qnan_d else qnan_s);
    if (!m) {
        e.get(b);
        isNan(e, b, dbl);
        e.op(W.select);
    }
    if (m) e.k64(if (dbl) qnan_d else qnan_s) else e.get(a);
    // compare: min: a < b ? a : b < a ? b : a | b
    //          max: b < a ? a : a < b ? b : a & b
    e.get(a);
    e.get(b);
    e.get(a);
    e.get(b);
    e.op(if (max) W.i64_and else W.i64_or);
    if (max) fCompare(e, a, b, dbl, .lt) else fCompare(e, b, a, dbl, .lt);
    e.op(W.select);
    if (max) fCompare(e, b, a, dbl, .lt) else fCompare(e, a, b, dbl, .lt);
    e.op(W.select);
    isNan(e, b, dbl);
    e.op(W.select);
    isNan(e, a, dbl);
    e.op(W.select);
    fdst(e, o.rd, dbl);
}

/// fround / froundnx (Zfa): fsgnj kind, imm = 16 | rm (24 | rm: froundnx).
/// wasm's nearest/trunc/floor/ceil are exact (RNE/RTZ/RDN/RUP) and keep
/// the sign of a zero result; a NaN is handed back, RMM is not translated,
/// a dynamic mode must be RNE (frmCheck). A single rounds through f64:
/// promoting is exact, and so is demoting an integral value.
fn fRound(e: *Emit, o: Op, k: usize, pc: u64) void {
    const dbl = o.h == .fsgnj_d;
    const rm = o.imm & 7;
    frmCheck(e, rm == 7, k, pc);
    const a = fsrc(e, o.rs1, dbl, l_t5);
    const r = l_t5 + 1;
    isNan(e, a, dbl);
    handBackIf(e, k, pc);
    if (dbl) e.getD(a) else e.getS(a);
    e.op(switch (rm) {
        1 => W.f64_trunc,
        2 => W.f64_floor,
        3 => W.f64_ceil,
        else => W.f64_nearest, // 0, or 7 with frm = RNE
    });
    if (dbl) e.op(W.i64_reinterpret) else e.ops(&.{ W.f32_demote, W.i32_reinterpret, W.i64_ext_u });
    e.set(r);
    if (o.imm & 8 != 0) { // froundnx: inexact iff the value changed
        if (dbl) e.getD(r) else e.getS(r);
        if (dbl) e.getD(a) else e.getS(a);
        e.op(W.f64_ne);
        orFlag(e, 0);
    }
    e.get(r);
    fdst(e, o.rd, dbl);
}

fn fArith(e: *Emit, o: Op, k: usize, pc: u64) void {
    const dbl = switch (o.h) {
        .fadd_d, .fsub_d, .fmul_d, .fdiv_d => true,
        else => false,
    };
    const kind: enum { add, mul, div } = switch (o.h) {
        .fadd_s, .fsub_s, .fadd_d, .fsub_d => .add,
        .fmul_s, .fmul_d => .mul,
        else => .div,
    };
    const x = l_d0;
    const y = l_d0 + 1;
    const r = l_d0 + 2;
    const tr = l_t5 + 2;
    frmCheck(e, o.imm & 7 == 7, k, pc);
    const a = fsrc(e, o.rs1, dbl, l_t5);
    var b = fsrc(e, o.rs2, dbl, l_t5 + 1);
    if (o.h == .fsub_s or o.h == .fsub_d) { // sub(a, b) = add(a, b ^ sign)
        e.get(b);
        e.k64(if (dbl) sign_d else sign_s);
        e.op(W.i64_xor);
        e.set(l_t5 + 1);
        b = l_t5 + 1;
    }
    if (dbl) e.getD(a) else e.getS(a);
    e.set(x);
    if (dbl) e.getD(b) else e.getS(b);
    e.set(y);
    e.get(x);
    e.get(y);
    e.op(switch (kind) {
        .add => W.f64_add,
        .mul => W.f64_mul,
        .div => W.f64_div,
    });
    // f64: rb = bits(x op y); f32: rb = bits(f32(x op y)) (the f64 sum and
    // product are what fpu.zig rounds, the quotient is rounded directly)
    if (dbl) {
        e.tee(r);
        e.op(W.i64_reinterpret);
    } else {
        if (kind != .div) e.tee(r);
        e.ops(&.{ W.f32_demote, W.i32_reinterpret, W.i64_ext_u });
    }
    e.set(tr);
    outOfRange(e, tr, dbl);
    handBackIf(e, k, pc);
    // inexact (only while NX is clear: once set, it cannot change fcsr)
    nxClear(e);
    switch (kind) {
        .add => {
            // TwoSum: bv = r - x, av = r - bv, err = (x - av) + (y - bv)
            const bv = l_d0 + 3;
            const av = l_d0 + 4;
            e.get(r);
            e.get(x);
            e.op(W.f64_sub);
            e.set(bv);
            e.get(r);
            e.get(bv);
            e.op(W.f64_sub);
            e.set(av);
            e.get(x);
            e.get(av);
            e.op(W.f64_sub);
            e.get(y);
            e.get(bv);
            e.op(W.f64_sub);
            e.op(W.f64_add);
            e.kf(0);
            e.op(W.f64_ne);
            if (!dbl) {
                e.getS(tr);
                e.get(r);
                e.op(W.f64_ne);
                e.op(W.i32_or);
            }
        },
        .mul => if (dbl) {
            // exact iff the product of the odd significands fits in 53 bits
            const oa = l_t5 + 3;
            const ob = l_t5 + 4;
            const n = l_t5;
            oddSig(e, a, true, oa);
            e.set(oa);
            oddSig(e, b, true, ob);
            e.set(ob);
            e.k64(128);
            e.get(oa);
            e.op(W.i64_clz);
            e.op(W.i64_sub);
            e.get(ob);
            e.op(W.i64_clz);
            e.op(W.i64_sub);
            e.tee(n);
            e.k64(53);
            e.op(W.i64_le_u);
            e.get(n);
            e.k64(54);
            e.op(W.i64_eq);
            e.get(oa);
            e.get(ob);
            e.op(W.i64_mul);
            e.k64(1 << 53);
            e.op(W.i64_lt_u);
            e.op(W.i32_and);
            e.op(W.i32_or);
            e.op(W.i32_eqz);
        } else {
            e.getS(tr);
            e.get(r);
            e.op(W.f64_ne);
        },
        .div => if (dbl) {
            // exact iff oddSig(b) divides oddSig(a)
            oddSig(e, a, true, l_t5 + 3);
            oddSig(e, b, true, l_t5 + 4);
            e.op(W.i64_rem_u);
            e.k64(0);
            e.op(W.i64_ne);
        } else {
            e.getS(tr);
            e.get(y);
            e.op(W.f64_mul);
            e.get(x);
            e.op(W.f64_ne);
        },
    }
    orFlag(e, 0);
    e.close();
    e.get(tr);
    fdst(e, o.rd, dbl);
}

/// if (fcsr.NX == 0) { ... }: the caller closes it.
fn nxClear(e: *Emit) void {
    e.get(l_fcsr);
    e.k64(1);
    e.op(W.i64_and);
    e.op(W.i64_eqz);
    e.open(W.@"if", W.void_t);
}

fn fFma(e: *Emit, o: Op, k: usize, pc: u64) void {
    const dbl = switch (o.h) {
        .fmadd_d, .fmsub_d, .fnmsub_d, .fnmadd_d => true,
        else => false,
    };
    const neg_a = switch (o.h) {
        .fnmsub_s, .fnmsub_d, .fnmadd_s, .fnmadd_d => true,
        else => false,
    };
    const neg_c = switch (o.h) {
        .fmsub_s, .fmsub_d, .fnmadd_s, .fnmadd_d => true,
        else => false,
    };
    const sg: u64 = if (dbl) sign_d else sign_s;
    frmCheck(e, o.imm & 7 == 7, k, pc);
    const regs = [3]u32{ o.rs1, o.rs2, @intCast((o.imm >> 8) & 31) };
    for (regs, 0..) |rr, i| {
        const l = fsrc(e, rr, dbl, l_t5 + @as(u32, @intCast(i)));
        e.get(l);
        if ((i == 0 and neg_a) or (i == 2 and neg_c)) {
            e.k64(sg);
            e.op(W.i64_xor);
        }
    }
    if (e.fma_inline) {
        for (0..3) |i| e.set(l_fma_i + 2 - @as(u32, @intCast(i)));
        e.open(W.block, W.i64_t);
        e.fma_nest = e.nest;
        if (dbl) fmaBody(e, u64, true) else fmaBody(e, u32, true);
        e.close();
        e.fma_nest = 0;
    } else e.call(if (dbl) e.fn_fmad else e.fn_fmas);
    e.set(l_t5 + 3);
    // status: 0 exact, 1 inexact, 2 hand back
    fmaStatus(e);
    e.k32(2);
    e.op(W.i32_eq);
    handBackIf(e, k, pc);
    fmaStatus(e);
    orFlag(e, 0);
    e.get(l_t5 + 3);
    fdst(e, o.rd, dbl);
}

/// Push the last FMA body's status (i32).
fn fmaStatus(e: *Emit) void {
    if (e.fma_inline) {
        e.get(l_fma_st);
        e.op(W.i32_wrap);
    } else e.gget();
}

/// The FMA body for format B: (a, b, c) -> result bits, operands already
/// sign-adjusted and unboxed, mirroring fpu.Fmt(B).fma for RNE: the
/// zero-product case, for f64 the zero-addend case (the product, as fpu's
/// mul fast path) and Boldo & Melquiond's emulated FMA (fma64Fast) with its
/// operand and result guards, for f32 fma32Fast. Its status is 0 (exact),
/// 1 (inexact) or 2 (the interpreter must do it: NaN/infinite operands,
/// out-of-range operands or results). Emitted either as a helper function
/// of type 1 (status in global 0) or inline in f inside a `block (result
/// i64)` whose nesting level is e.fma_nest (operands in l_fma_i.., status
/// in l_fma_st).
fn fmaBody(e: *Emit, comptime B: type, comptime inl: bool) void {
    const dbl = B == u64;
    const shift: u64 = if (dbl) 52 else 23;
    const emax: u64 = if (dbl) 0x7ff else 0xff;
    const body = if (inl) 0 else e.reserve();
    if (!inl) {
        e.op(0x02);
        e.uleb(7);
        e.op(W.i64_t);
        e.uleb(16);
        e.op(W.f64_t);
    }
    // i64 locals 0..9 (params a, b, c first), f64 locals 10..25
    const L = struct {
        fn i(n: u32) u32 {
            return if (inl) l_fma_i + n else n;
        }
        fn f(n: u32) u32 {
            return if (inl) l_fma_f + n - 10 else n;
        }
    };
    const pa = L.i(0);
    const pb = L.i(1);
    const pc_ = L.i(2);
    const ea = L.i(3);
    const eb = L.i(4);
    const ec = L.i(5);
    const t = L.i(6);
    const t2 = L.i(7);
    const t3 = L.i(8);
    const t4 = L.i(9);
    const fx = L.f(10);
    const fy = L.f(11);
    const fz = L.f(12);
    const fp = L.f(13);
    const xh = L.f(14);
    const xl = L.f(15);
    const yh = L.f(16);
    const yl = L.f(17);
    const pl = L.f(18);
    const sh = L.f(19);
    const sl = L.f(20);
    const fu = L.f(21);
    const ue = L.f(22);
    const fr = L.f(23);
    const tmp = L.f(24);
    const tmp2 = L.f(25);
    const H = struct {
        /// status = (i32 on the stack)
        fn status(em: *Emit) void {
            if (inl) {
                em.op(W.i64_ext_u);
                em.set(l_fma_st);
            } else em.gset();
        }
        /// return (the result bits on the stack)
        fn ret(em: *Emit) void {
            if (inl) {
                em.op(W.br);
                em.uleb(em.nest - em.fma_nest);
            } else em.op(W.@"return");
        }
        fn handBack(em: *Emit) void {
            em.k32(2);
            status(em);
            em.k64(0);
            ret(em);
        }
        fn handBackIf(em: *Emit) void {
            em.open(W.@"if", W.void_t);
            handBack(em);
            em.close();
        }
        /// Push f64 of the operand bits in local l.
        fn val(em: *Emit, l: u32) void {
            if (dbl) em.getD(l) else em.getS(l);
        }
        fn sub(em: *Emit, a: u32, b: u32) void {
            em.get(a);
            em.get(b);
            em.op(W.f64_sub);
        }
    };
    for ([_][2]u32{ .{ pa, ea }, .{ pb, eb }, .{ pc_, ec } }) |pe| {
        e.get(pe[0]);
        e.k64(shift);
        e.op(W.i64_shr_u);
        e.k64(emax);
        e.op(W.i64_and);
        e.set(pe[1]);
    }
    if (dbl) {
        // fma64Fast's operand guards (exponents of a, b in [33, 2013], of c
        // in [1, 2023], product exponent in [-900, 1000]) exclude NaN,
        // infinite, zero and subnormal operands, so when they hold, fpu's
        // fma goes straight to fma64Fast; test them first (the common case)
        // and take the special cases below only when they fail.
        e.get(ea);
        e.k64(33);
        e.op(W.i64_sub);
        e.k64(1981);
        e.op(W.i64_lt_u);
        e.get(eb);
        e.k64(33);
        e.op(W.i64_sub);
        e.k64(1981);
        e.op(W.i64_lt_u);
        e.op(W.i32_and);
        e.get(ec);
        e.k64(1);
        e.op(W.i64_sub);
        e.k64(2023);
        e.op(W.i64_lt_u);
        e.op(W.i32_and);
        e.get(ea);
        e.get(eb);
        e.op(W.i64_add);
        e.k64(1146);
        e.op(W.i64_sub);
        e.k64(1901);
        e.op(W.i64_lt_u);
        e.op(W.i32_and);
        e.op(W.i32_eqz);
        e.open(W.@"if", W.void_t);
    }
    // NaN or infinite operand
    for ([_]u32{ ea, eb, ec }, 0..) |l, i| {
        e.get(l);
        e.k64(emax);
        e.op(W.i64_eq);
        if (i > 0) e.op(W.i32_or);
    }
    H.handBackIf(e);
    // a or b zero (all finite): c, or for c = 0 the RNE sign rule
    const zshift: u64 = if (dbl) 1 else 33;
    for ([_]u32{ pa, pb }, 0..) |l, i| {
        e.get(l);
        e.k64(zshift);
        e.op(W.i64_shl);
        e.op(W.i64_eqz);
        if (i > 0) e.op(W.i32_or);
    }
    e.open(W.@"if", W.void_t);
    e.k32(0);
    H.status(e);
    e.get(pc_);
    e.k64(zshift);
    e.op(W.i64_shl);
    e.op(W.i64_eqz);
    e.open(W.@"if", W.i64_t);
    e.get(pc_);
    e.k64(0);
    e.get(pc_);
    e.get(pa);
    e.op(W.i64_xor);
    e.get(pb);
    e.op(W.i64_xor);
    e.k64(if (dbl) 63 else 31);
    e.op(W.i64_shr_u);
    e.op(W.i64_eqz);
    e.op(W.select);
    e.op(W.@"else");
    e.get(pc_);
    e.close();
    H.ret(e);
    e.close();
    if (dbl) {
        // c = 0, a and b finite non-zero: fmaSlow returns mulCore(a, b),
        // which is fpu's mul (fast path) for RNE.
        e.get(pc_);
        e.k64(1);
        e.op(W.i64_shl);
        e.op(W.i64_eqz);
        e.open(W.@"if", W.void_t);
        e.getD(pa);
        e.getD(pb);
        e.op(W.f64_mul);
        e.op(W.i64_reinterpret);
        e.set(t);
        outOfRange(e, t, true);
        H.handBackIf(e);
        oddSig(e, pa, true, t2);
        e.set(t2);
        oddSig(e, pb, true, t3);
        e.set(t3);
        e.k64(128);
        e.get(t2);
        e.op(W.i64_clz);
        e.op(W.i64_sub);
        e.get(t3);
        e.op(W.i64_clz);
        e.op(W.i64_sub);
        e.tee(t4);
        e.k64(53);
        e.op(W.i64_le_u);
        e.get(t4);
        e.k64(54);
        e.op(W.i64_eq);
        e.get(t2);
        e.get(t3);
        e.op(W.i64_mul);
        e.k64(1 << 53);
        e.op(W.i64_lt_u);
        e.op(W.i32_and);
        e.op(W.i32_or);
        e.op(W.i32_eqz);
        H.status(e);
        e.get(t);
        H.ret(e);
        e.close();
        // anything else outside the guards: the integer path
        H.handBack(e);
        e.close();
        H.val(e, pa);
        e.set(fx);
        H.val(e, pb);
        e.set(fy);
        H.val(e, pc_);
        e.set(fz);
        // Dekker TwoProduct (Veltkamp split with 2^27 + 1)
        e.get(fx);
        e.get(fy);
        e.op(W.f64_mul);
        e.set(fp);
        for ([_][3]u32{ .{ fx, xh, xl }, .{ fy, yh, yl } }) |s| {
            e.kf(134217729.0);
            e.get(s[0]);
            e.op(W.f64_mul);
            e.tee(tmp);
            H.sub(e, tmp, s[0]);
            e.op(W.f64_sub);
            e.set(s[1]); // h = t - (t - v)
            H.sub(e, s[0], s[1]);
            e.set(s[2]); // l = v - h
        }
        // pl = ((xh*yh - p) + xh*yl + xl*yh) + xl*yl
        e.get(xh);
        e.get(yh);
        e.op(W.f64_mul);
        e.get(fp);
        e.op(W.f64_sub);
        e.get(xh);
        e.get(yl);
        e.op(W.f64_mul);
        e.op(W.f64_add);
        e.get(xl);
        e.get(yh);
        e.op(W.f64_mul);
        e.op(W.f64_add);
        e.get(xl);
        e.get(yl);
        e.op(W.f64_mul);
        e.op(W.f64_add);
        e.set(pl);
        // TwoSum(z, p): sh + sl
        e.get(fz);
        e.get(fp);
        e.op(W.f64_add);
        e.set(sh);
        twoSumErr(e, sh, fz, fp, tmp, tmp2);
        e.set(sl);
        // Exact product (pl = ±0): the steps below reduce to u = sl (or ±0
        // when sl is), ue = 0, r = RN(sh + u) = sh and re = u, so the result
        // is sh and it is inexact iff sl != 0. Taking that shortcut keeps
        // the addend's dependency chain at one add.
        e.get(pl);
        e.kf(0);
        e.op(W.f64_eq);
        e.open(W.@"if", W.void_t);
        e.get(sh);
        e.op(W.i64_reinterpret);
        e.set(t);
        outOfRange(e, t, true);
        H.handBackIf(e);
        e.get(sl);
        e.kf(0);
        e.op(W.f64_ne);
        H.status(e);
        e.get(t);
        H.ret(e);
        e.close();
        // u = sl + pl, ue = its TwoSum error
        e.get(sl);
        e.get(pl);
        e.op(W.f64_add);
        e.set(fu);
        twoSumErr(e, fu, sl, pl, tmp, tmp2);
        e.set(ue);
        // round u to odd: ue != 0 (u must be normal), even u moves one ulp
        // towards the exact sum
        e.get(ue);
        e.kf(0);
        e.op(W.f64_ne);
        e.open(W.@"if", W.void_t);
        e.get(fu);
        e.op(W.i64_reinterpret);
        e.set(t);
        e.get(t);
        e.k64(52);
        e.op(W.i64_shr_u);
        e.k64(0x7ff);
        e.op(W.i64_and);
        e.tee(t2);
        e.op(W.i64_eqz);
        e.get(t2);
        e.k64(0x7ff);
        e.op(W.i64_eq);
        e.op(W.i32_or);
        H.handBackIf(e);
        roundOdd(e, t, ue, fu);
        e.close();
        // r = sh + u
        e.get(sh);
        e.get(fu);
        e.op(W.f64_add);
        e.tee(fr);
        e.op(W.i64_reinterpret);
        e.set(t);
        outOfRange(e, t, true);
        H.handBackIf(e);
        twoSumErr(e, fr, sh, fu, tmp, tmp2);
        e.kf(0);
        e.op(W.f64_ne);
        e.get(ue);
        e.kf(0);
        e.op(W.f64_ne);
        e.op(W.i32_or);
        H.status(e);
        e.get(t);
    } else {
        // fma32Fast: the f64 product is exact; the f64 sum is rounded to
        // odd, so rounding it to f32 is correct.
        H.val(e, pa);
        H.val(e, pb);
        e.op(W.f64_mul);
        e.set(fp);
        H.val(e, pc_);
        e.set(fy);
        e.get(fp);
        e.get(fy);
        e.op(W.f64_add);
        e.set(fr);
        twoSumErr(e, fr, fp, fy, tmp, tmp2);
        e.set(ue); // err
        e.get(ue);
        e.kf(0);
        e.op(W.f64_ne);
        e.open(W.@"if", W.void_t);
        e.get(fr);
        e.op(W.i64_reinterpret);
        e.set(t);
        roundOdd(e, t, ue, fr);
        e.close();
        e.get(fr);
        e.ops(&.{ W.f32_demote, W.i32_reinterpret, W.i64_ext_u });
        e.set(t);
        outOfRange(e, t, false);
        H.handBackIf(e);
        e.get(ue);
        e.kf(0);
        e.op(W.f64_ne);
        e.getS(t);
        e.get(fr);
        e.op(W.f64_ne);
        e.op(W.i32_or);
        H.status(e);
        e.get(t);
    }
    if (!inl) {
        e.op(W.end);
        e.patch(body);
    }
}

/// Push the TwoSum error of s = a + b (s already computed):
/// (a - (s - (s - a))) + (b - (s - a)).
fn twoSumErr(e: *Emit, s: u32, a: u32, b: u32, tmp: u32, tmp2: u32) void {
    e.get(s);
    e.get(a);
    e.op(W.f64_sub);
    e.set(tmp); // bv
    e.get(s);
    e.get(tmp);
    e.op(W.f64_sub);
    e.set(tmp2); // av
    e.get(a);
    e.get(tmp2);
    e.op(W.f64_sub);
    e.get(b);
    e.get(tmp);
    e.op(W.f64_sub);
    e.op(W.f64_add);
}

/// If the bits t of v are even, move v one ulp towards the exact value
/// (away from zero iff (err > 0) == (v > 0)), as fpu.zig's round-to-odd.
fn roundOdd(e: *Emit, t: u32, err: u32, v: u32) void {
    e.get(t);
    e.k64(1);
    e.op(W.i64_and);
    e.op(W.i64_eqz);
    e.open(W.@"if", W.void_t);
    e.get(t);
    e.k64(1);
    e.op(W.i64_add);
    e.get(t);
    e.k64(1);
    e.op(W.i64_sub);
    e.get(err);
    e.kf(0);
    e.op(W.f64_gt);
    e.get(v);
    e.kf(0);
    e.op(W.f64_gt);
    e.op(W.i32_eq);
    e.op(W.select);
    e.op(W.f64_reinterpret);
    e.set(v);
    e.close();
}

/// FP instructions that reach the JIT as `generic` ops (see fpGeneric).
fn fGeneric(e: *Emit, raw: u32, k: usize, pc: u64) void {
    const g = fpGeneric(raw).?;
    const rd = (raw >> 7) & 31;
    const rs1 = (raw >> 15) & 31;
    const rs2 = (raw >> 20) & 31;
    const f3 = (raw >> 12) & 7;
    const dbl = switch (g) {
        .fsqrt_d, .fcvt_d_s, .fcvt_f_x_d, .fcvt_x_f_d, .fclass_d => true,
        else => false,
    };
    const sg: u64 = if (dbl) sign_d else sign_s;
    const inf: u64 = if (dbl) inf_d else inf_s;
    frmCheck(e, f3 == 7 and g != .fclass_s and g != .fclass_d, k, pc);
    switch (g) {
        .fsqrt_s, .fsqrt_d => {
            // NaN or negative non-zero: NaN result (interpreter)
            const a = fsrc(e, rs1, dbl, l_t5);
            e.get(a);
            e.k64(inf);
            e.op(W.i64_gt_u);
            e.get(a);
            e.k64(sg);
            e.op(W.i64_ne);
            e.op(W.i32_and);
            handBackIf(e, k, pc);
            // rb = host sqrt (correctly rounded; ±0 and +inf give themselves)
            if (dbl) {
                e.getD(a);
                e.ops(&.{ W.f64_sqrt, W.i64_reinterpret });
            } else {
                e.get(a);
                e.ops(&.{ W.i32_wrap, W.f32_reinterpret, W.f32_sqrt, W.i32_reinterpret, W.i64_ext_u });
            }
            e.set(l_t5 + 1);
            // inexact unless a is ±0/+inf or odd(rb)^2 == odd(a) with
            // bitLen(odd(rb)) <= (mb + 2) / 2
            nxClear(e);
            oddSig(e, l_t5 + 1, dbl, l_t5 + 2);
            e.set(l_t5 + 2);
            e.k64(64);
            e.get(l_t5 + 2);
            e.op(W.i64_clz);
            e.op(W.i64_sub);
            e.k64(if (dbl) 27 else 12);
            e.op(W.i64_le_u);
            e.get(l_t5 + 2);
            e.get(l_t5 + 2);
            e.op(W.i64_mul);
            oddSig(e, a, dbl, l_t5 + 3);
            e.op(W.i64_eq);
            e.op(W.i32_and);
            e.get(a);
            e.k64(if (dbl) 1 else 33);
            e.op(W.i64_shl);
            e.op(W.i64_eqz);
            e.op(W.i32_or);
            e.get(a);
            e.k64(inf);
            e.op(W.i64_eq);
            e.op(W.i32_or);
            e.op(W.i32_eqz);
            orFlag(e, 0);
            e.close();
            e.get(l_t5 + 1);
            fdst(e, rd, dbl);
        },
        .fcvt_d_s => {
            // f32 -> f64 is exact; a NaN source is handed back
            const a = fsrc(e, rs1, false, l_t5);
            isNan(e, a, false);
            handBackIf(e, k, pc);
            e.getS(a);
            e.op(W.i64_reinterpret);
            e.set(lf(rd));
        },
        .fcvt_s_d => {
            const a = lf(rs1);
            const m = l_t5;
            const r = l_t5 + 1;
            e.get(a);
            e.k64(~sign_d);
            e.op(W.i64_and);
            e.tee(m);
            e.k64(inf_d);
            e.op(W.i64_gt_u);
            handBackIf(e, k, pc);
            e.getD(a);
            e.ops(&.{ W.f32_demote, W.i32_reinterpret, W.i64_ext_u });
            e.set(r);
            // ±0 and ±inf convert exactly; finite values only to a result
            // in the fast-path range (roundPack is IEEE RNE there)
            outOfRange(e, r, false);
            e.get(m);
            e.op(W.i64_eqz);
            e.op(W.i32_eqz);
            e.op(W.i32_and);
            e.get(m);
            e.k64(inf_d);
            e.op(W.i64_ne);
            e.op(W.i32_and);
            handBackIf(e, k, pc);
            e.getS(r);
            e.getD(a);
            e.op(W.f64_ne);
            orFlag(e, 0);
            e.get(r);
            fdst(e, rd, false);
        },
        .fcvt_f_x_s, .fcvt_f_x_d => {
            // integer -> FP: wasm converts with RNE; no overflow or
            // underflow is possible, inexact iff the magnitude spans more
            // than the significand's bits
            const mag = l_t5;
            e.reg(@intCast(rs1));
            switch (rs2) {
                0 => e.ops(&.{ W.i32_wrap, W.i64_ext_s }),
                1 => {
                    e.k64(0xffff_ffff);
                    e.op(W.i64_and);
                },
                else => {},
            }
            e.set(mag);
            e.get(mag);
            if (rs2 == 0 or rs2 == 1) {
                e.op(W.i32_wrap);
                e.op(if (rs2 == 0)
                    (if (dbl) W.f64_convert_i32_s else W.f32_convert_i32_s)
                else
                    (if (dbl) W.f64_convert_i32_u else W.f32_convert_i32_u));
            } else e.op(if (rs2 == 2)
                (if (dbl) W.f64_convert_i64_s else W.f32_convert_i64_s)
            else
                (if (dbl) W.f64_convert_i64_u else W.f32_convert_i64_u));
            if (dbl) e.op(W.i64_reinterpret) else e.ops(&.{ W.i32_reinterpret, W.i64_ext_u });
            fdst(e, rd, dbl);
            if (!(dbl and rs2 <= 1)) {
                if (rs2 == 0 or rs2 == 2) { // |v|
                    e.k64(0);
                    e.get(mag);
                    e.op(W.i64_sub);
                    e.get(mag);
                    e.get(mag);
                    e.k64(0);
                    e.op(W.i64_lt_s);
                    e.op(W.select);
                    e.set(mag);
                }
                e.k64(64);
                e.get(mag);
                e.op(W.i64_clz);
                e.op(W.i64_sub);
                e.get(mag);
                e.op(W.i64_ctz);
                e.op(W.i64_sub);
                e.k64(if (dbl) 53 else 24);
                e.op(W.i64_gt_s);
                orFlag(e, 0);
            }
        },
        .fcvt_x_f_s, .fcvt_x_f_d => {
            // FP -> integer: round with the instruction's mode, then
            // convert only when the rounded value is in range (anything
            // else, NaN and infinities included, is the NV case)
            const x = l_d0;
            const r = l_d0 + 1;
            if (dbl) e.getD(lf(rs1)) else e.getS(fsrc(e, rs1, false, l_t5));
            e.tee(x);
            e.op(switch (if (f3 == 7) 0 else f3) {
                0 => W.f64_nearest,
                1 => W.f64_trunc,
                2 => W.f64_floor,
                else => W.f64_ceil,
            });
            e.set(r);
            const lo: f64, const hi: f64, const hi_incl = switch (rs2) {
                0 => .{ -2147483648.0, 2147483647.0, true },
                1 => .{ 0.0, 4294967295.0, true },
                2 => .{ -9223372036854775808.0, 9223372036854775808.0, false },
                else => .{ 0.0, 18446744073709551616.0, false },
            };
            e.get(r);
            e.kf(lo);
            e.op(W.f64_ge);
            e.get(r);
            e.kf(hi);
            e.op(if (hi_incl) W.f64_le else W.f64_lt);
            e.op(W.i32_and);
            e.op(W.i32_eqz);
            handBackIf(e, k, pc);
            e.get(r);
            e.op(if (rs2 == 3) W.i64_trunc_f64_u else W.i64_trunc_f64_s);
            if (rs2 <= 1) e.ops(&.{ W.i32_wrap, W.i64_ext_s });
            e.setReg(@intCast(rd));
            e.get(r);
            e.get(x);
            e.op(W.f64_ne);
            orFlag(e, 0);
        },
        .fclass_s, .fclass_d => {
            const a = fsrc(e, rs1, dbl, l_t5);
            const m = l_t5 + 1;
            const s = l_t5 + 2;
            e.get(a);
            e.k64(if (dbl) 63 else 31);
            e.op(W.i64_shr_u);
            e.set(s);
            e.get(a);
            e.k64(sg - 1);
            e.op(W.i64_and);
            e.set(m);
            const r = l_t5 + 3;
            const C = struct {
                /// push (sign ? neg : pos)
                fn pick(em: *Emit, sl: u32, neg: u64, pos: u64) void {
                    em.k64(neg);
                    em.k64(pos);
                    em.get(sl);
                    em.op(W.i32_wrap);
                    em.op(W.select);
                }
                /// r = cond ? (the value pushed before) : r; cond: m <cmp> v
                fn over(em: *Emit, rl: u32, ml: u32, cmp: u8, v: u64) void {
                    em.get(rl);
                    em.get(ml);
                    em.k64(v);
                    em.op(cmp);
                    em.op(W.select);
                    em.set(rl);
                }
            };
            // normal, then overridden by subnormal, zero, infinity, NaN
            C.pick(e, s, 1 << 1, 1 << 6);
            e.set(r);
            C.pick(e, s, 1 << 2, 1 << 5);
            C.over(e, r, m, W.i64_lt_u, if (dbl) 1 << 52 else 1 << 23);
            C.pick(e, s, 1 << 3, 1 << 4);
            C.over(e, r, m, W.i64_eq, 0);
            C.pick(e, s, 1 << 0, 1 << 7);
            C.over(e, r, m, W.i64_eq, inf);
            e.k64(1 << 8);
            e.k64(1 << 9);
            e.get(m);
            e.k64(if (dbl) qnan_d else qnan_s);
            e.op(W.i64_lt_u);
            e.op(W.select);
            C.over(e, r, m, W.i64_gt_u, inf);
            e.get(r);
            e.setReg(@intCast(rd));
        },
    }
}

/// Inline data-TLB lookup for an access of `size` bytes at x[rs1] + imm:
/// leaves the host address on the stack, or hands op k back on a miss
/// (same test as Cpu.load/storeChk: tag == vpn of the last byte).
fn hostAddr(e: *Emit, o: Op, k: usize, pc: u64, tlb_off: u64, size: u64) void {
    e.reg(o.rs1);
    if (o.imm != 0) {
        e.k64(o.imm);
        e.op(W.i64_add);
    }
    e.set(l_va);
    e.get(l_cpu);
    e.get(l_va);
    e.k64(8);
    e.op(W.i64_shr_u);
    e.k64(dtlb_mask);
    e.op(W.i64_and);
    e.op(W.i64_add);
    e.op(W.local_tee);
    e.uleb(l_e);
    e.addr();
    e.mem(W.i64_load, 3, tlb_off); // tag
    e.get(l_va);
    if (size > 1) {
        e.k64(size - 1);
        e.op(W.i64_add);
    }
    e.k64(12);
    e.op(W.i64_shr_u);
    e.op(W.i64_ne);
    e.open(W.@"if", W.void_t);
    e.handBack(k, pc);
    e.close();
    e.get(l_e);
    e.addr();
    e.mem(W.i64_load, 3, tlb_off + 8); // add
    e.get(l_va);
    e.op(W.i64_add);
    e.addr();
}

// ---- regions -------------------------------------------------------------------------
//
// A compiled module holds a region: up to `max_members` decoded blocks
// (members), on any number of pages, not just one block. Guest registers
// stay in wasm locals across the whole region: a member that leaves through
// its terminator (a jalr compares its target against every member's pc) or
// a side exit towards a member (itself included) continues there inside the
// module, through a `loop` over a `br_table`. The table has two entries per
// member: its checked entry (the checks below, then the member) and the
// member itself (only for the member `run` entered; a jalr to the start of
// the member being run continues in the member's own loop). A branch site only
// sets the index and branches to the loop, so a module carries the checks
// once per member, not once per branch site and target. Only exits to other
// pcs, hand-backs and stops return to `run`.
//
// Home and guest members: a block's `st` names one region, its home, and
// `run` enters the block only through that module. A region may also hold
// copies of blocks whose home is another region (guests). A member's code
// depends only on its decoded ops, so a copy is exact as long as the block
// still holds the same decode; the checks below do not look at `st`.
//
// Entering a member: `run` looked the entered block up, so it is valid
// under its page's current exec-TLB fill. A branch to a member m (from any
// member, m itself included) goes through m's checked entry:
//  - blocks[m].op is the op index m had when the module was emitted. A
//    re-decode takes new ops (the arena only grows until a cache reset,
//    which frees every module), so this is "still the same decode".
//  - m is valid under the current fill of its own page: blocks[m].tgen
//    equals l_g, the tgen of the member being run (a generation is unique
//    to one fill of one page, and that fill is live), or else the
//    generation of one of the two exec-TLB entries of m's page's set,
//    exactly what `lookup` checks; l_g then becomes m's tgen. Nothing in
//    compiled code changes the exec TLB (stores into code hand back), so a
//    check made here holds until the module returns.
//  - like `run`: the budget covers all of m (jl >= its instructions) and no
//    interrupt is pending.
// Then it charges m in full and enters it; a side exit first refunds the
// rest of the member it leaves, so `jl` stays exact. Every member entry
// polls *irqp, so the irq word is read at least every 64 instructions. If
// a check fails, the module returns "done" with pc = the member's start,
// and `run` takes over (looks it up, revalidates or re-decodes it).
// `cpu.jit.cur` names the member a hand-back came from (`lastBlock`).
// Nothing in compiled code frees or reuses a slot or rewrites a block
// (only `run` does, between entries), so a region never outlives its
// members while it runs.
//
// The emitted code depends on pc, the raw instruction bits, cpu-relative
// layout offsets, the members' block-table positions and op indices, never
// on host addresses, generations or the pool entry: a revalidated member
// keeps its code. Regions are formed when a block gets hot (`compile`):
// that block, the members of an open region of its page that has room
// (which is then replaced, so a page tends to have one module), then
// blocks reachable from those through branch, jal and call-return targets
// that are already decoded, valid under their page's current fill and not
// compiled elsewhere, on any page, in breadth-first order. They grow later
// along hot exits (`noteHot`): a block compiled in another region, on
// another page, that `run` often enters right after the region left joins
// it as a guest. A member that is re-decoded only loses its own entry
// (`dropMember`); copies of it in other regions fail the op check from then
// on. A region is freed when no home member is left, when the clock evicts
// it, when it is grown (replaced) or on a cache reset.

/// Region locals: a third group of i64 locals, after the f64 ones.
const n_region_locals = 4;
/// `br_table` index of the code to run next: 2 m = member m's checked
/// entry, 2 m + 1 = member m itself (see `emitMembers`).
const l_next = l_d0 + n_f64;
/// Address of the member being run (stored to cpu.jit.cur on exit).
const l_cur = l_next + 1;
/// tgen of a member while its checked entry tests it.
const l_tg = l_next + 2;
/// tgen of the member being run: the generation of the current exec-TLB
/// fill of its page.
const l_g = l_next + 3;

const blocks_off = priv_off + @offsetOf(@FieldType(Cpu, "priv"), "blocks");
const tlb_x_off = priv_off + @offsetOf(@FieldType(Cpu, "priv"), "tlb_x");
const XTlb = @typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_x")).array.child;
/// Exec-TLB sets (2 ways each).
const xtlb_sets = @typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_x")).array.len / 2;
const jit_off = priv_off + @offsetOf(@FieldType(Cpu, "priv"), "jit");
const jst_off = @offsetOf(Block, "jx") + @offsetOf(BlockState, "st");

/// Opcodes used only here.
const WR = struct {
    const br_table = 0x0e;
};

/// The blocks of a region being compiled (indices into cpu.priv.blocks;
/// [0] is the block that got hot) and its emission state.
pub const Region = struct {
    cpu: *Cpu,
    n: usize = 0,
    idx: [max_members]u32 = undefined,
    /// Member being emitted.
    cur: usize = 0,
    /// Nesting levels of the dispatch loop and of the current member's loop.
    top: u32 = 0,
    self: u32 = 0,

    fn block(rg: *const Region, m: usize) *const Block {
        return &rg.cpu.priv.blocks[rg.idx[m]];
    }
    /// Member whose block starts at pc.
    fn memberAt(rg: *const Region, pc: u64) ?usize {
        for (0..rg.n) |m| {
            if (rg.block(m).pc == pc) return m;
        }
        return null;
    }
};

/// State.page flag: the region takes no further members (it did not fit,
/// or it is a self-loop's module of its own).
const page_closed: u64 = 1 << 63;

/// `st` of member m of the region in pool entry i (without ref_bit).
inline fn memberSt(i: usize, m: usize) u32 {
    return compiled | (@as(u32, @intCast(m)) << member_shift) | @as(u32, @intCast(i));
}

/// Pool entry of an open region of b's page with room for another member
/// whose live (home) members on that page are on b's host page.
fn findRegion(cpu: *Cpu, b: *const Block, limit: usize) ?usize {
    const st = &cpu.priv.jit;
    for (0..npool) |i| {
        if (st.owner[i] == 0 or st.page[i] != b.pc >> 12) continue;
        var n: usize = 0;
        var live: usize = 0;
        var same = true;
        for (st.members[i]) |m| {
            if (m == 0) continue;
            n += 1;
            const o = &cpu.priv.blocks[m - 1];
            if (slotOf(o) != i + 1) continue;
            live += 1;
            if ((o.pc ^ b.pc) >> 12 == 0) same = same and o.host >> 12 == b.host >> 12;
        }
        if (same and live > 0 and n < limit) return i;
    }
    return null;
}

/// Whether block c is valid under the current exec-TLB fill of its page
/// (what `lookup` checks).
fn current(cpu: *Cpu, c: *const Block) bool {
    return c.tgen != 0 and c.tgen == cpu.execGenOf(c.pc);
}

/// Index of the decoded block at pc t that may join b's region: valid under
/// the current fill of its page (on b's page: also on b's host page), not
/// compiled, compilable, no self-loop.
fn candidate(cpu: *Cpu, b: *const Block, t: u64) ?u32 {
    const set = kwemu.blockSet(t);
    for (cpu.priv.blocks[set..][0..2], set..) |*c, i| {
        if (c.pc != t) continue;
        if ((t ^ b.pc) >> 12 == 0) {
            if (c.tgen != b.tgen or c.host >> 12 != b.host >> 12) continue;
        } else if (!current(cpu, c)) continue;
        if (c.jx.st == never or c.jx.st >= compiled or !supported(cpu.priv.ops[c.op]) or selfLoop(cpu, c)) return null;
        return @intCast(i);
    }
    return null;
}

/// A block that branches or jumps back to its own start keeps a module of
/// its own: as a plain wasm loop that loads only its own registers it is
/// faster than inside a region, and much cheaper to leave and re-enter
/// (data-TLB misses hand back to `run` every few passes in loops over large
/// arrays).
fn selfLoop(cpu: *Cpu, b: *const Block) bool {
    const last = cpu.priv.ops[b.op + b.n - 1];
    return switch (last.h) {
        .beq, .bne, .blt, .bge, .bltu, .bgeu, .jal, .goto => last.imm == b.pc,
        else => false,
    };
}

fn addMember(rg: *Region, i: u32) void {
    for (rg.idx[0..rg.n]) |j| if (j == i) return;
    rg.idx[rg.n] = i;
    rg.n += 1;
}

/// Collect the region for b (see above).
fn gatherRegion(cpu: *Cpu, b: *Block, rg: *Region) void {
    const st = &cpu.priv.jit;
    const limit = @min(st.region_max, max_members);
    rg.idx[0] = blockIndex(cpu, b);
    rg.n = 1;
    if (limit <= 1 or selfLoop(cpu, b)) return;
    if (findRegion(cpu, b, limit)) |i| {
        for (st.members[i]) |m| {
            if (m != 0 and usable(cpu, &cpu.priv.blocks[m - 1])) addMember(rg, m - 1);
        }
        freeSlot(cpu, i);
        st.grows += 1;
    }
    var q: usize = 0;
    while (q < rg.n and rg.n < limit) : (q += 1) {
        const m = rg.block(q);
        for (cpu.priv.ops[m.op..][0..m.n]) |o| {
            // targets of side exits and terminators; return sites of calls
            const call = o.rd != 0 and o.rd < 32;
            const ts: [2]?u64 = switch (o.h) {
                .beq_x, .bne_x, .blt_x, .bge_x, .bltu_x, .bgeu_x, .goto => .{ o.imm, null },
                .jal_c => .{ if (call) o.imm else null, null },
                .beq, .bne, .blt, .bge, .bltu, .bgeu => .{ o.imm, m.end_pc },
                .jal => .{ o.imm, if (call) m.end_pc else null },
                .jalr => .{ if (call) m.end_pc else null, null },
                else => .{ null, null },
            };
            for (ts) |t| {
                if (rg.n == limit) return;
                if (t) |pc| if (candidate(cpu, b, pc)) |i| addMember(rg, i);
            }
        }
    }
}

/// OR the register usage of members 1.. into `use` (member 0 is the block
/// emitModule was called for).
fn regionUse(cpu: *Cpu, rg: *const Region, use: *Use) void {
    for (1..rg.n) |m| {
        const b = rg.block(m);
        var x: Use = .{};
        for (cpu.priv.ops[b.op..][0..b.n]) |o| {
            if (!supported(o)) break;
            x.add(usage(o));
        }
        helpers(&x);
        use.add(x);
    }
}

/// The body of a region (inside the exit block): dispatch to the entered
/// member, then every member, each after its checked entry. The `br_table`
/// targets are, in order, checked entry 0, member 0, checked entry 1, ...:
/// a checked entry falls through into its member, and a member never falls
/// through (every path of it ends in a branch).
fn emitMembers(e: *Emit, cpu: *Cpu, rg: *Region) void {
    // l_cur = cpu.jit.cur (the entered member), l_g = its tgen,
    // l_next = 2 * its index + 1
    e.get(l_cpu);
    e.addr();
    e.mem(W.i64_load, 3, jit_off + @offsetOf(State, "cur"));
    e.set(l_cur);
    e.get(l_cur);
    e.addr();
    e.mem(W.i64_load, 3, @offsetOf(Block, "tgen"));
    e.set(l_g);
    e.get(l_cur);
    e.addr();
    e.mem(W.i64_load32_u, 2, jst_off);
    e.k64(member_shift - 1);
    e.op(W.i64_shr_u);
    e.k64(0x1fe);
    e.op(W.i64_and);
    e.k64(1);
    e.op(W.i64_or);
    e.set(l_next);
    e.open(W.loop, W.void_t);
    rg.top = e.nest;
    for (0..2 * rg.n) |_| e.open(W.block, W.void_t);
    e.get(l_next);
    e.op(W.i32_wrap);
    e.op(WR.br_table);
    e.uleb(2 * rg.n);
    for (0..2 * rg.n) |i| e.uleb(i);
    e.uleb(2 * rg.n - 1);
    for (0..rg.n) |m| {
        e.close();
        checkedEntry(e, rg, m);
        e.close();
        emitMember(e, cpu, rg, m);
    }
    e.close();
}

fn emitMember(e: *Emit, cpu: *Cpu, rg: *Region, m: usize) void {
    const b = rg.block(m);
    const all = cpu.priv.ops[b.op..][0..b.n];
    var u: usize = 0;
    while (u < all.len and supported(all[u])) u += 1;
    rg.cur = m;
    // A member may be entered first: its own code checks frm (frmCheck).
    e.frm_checked = false;
    var nfma: u32 = 0;
    for (all[0..u]) |o| nfma += usage(o).nfma;
    e.fma_inline = nfma <= fma_inline_max;
    var naes: u32 = 0;
    var nbk: u32 = 0;
    for (all[0..u]) |o| {
        naes += usage(o).naes;
        nbk += usage(o).nbk;
    }
    e.aes_inline = naes <= aes_inline_max;
    e.bk_inline = nbk <= bk_inline_max;
    e.get(l_cpu);
    e.k64(blocks_off + @as(u64, rg.idx[m]) * @sizeOf(Block));
    e.op(W.i64_add);
    e.set(l_cur);
    e.open(W.loop, W.void_t);
    rg.self = e.nest;
    var pc = b.pc;
    for (all[0..u], 0..) |o, k| {
        emitOp(e, o, k, pc, b, false);
        pc = kwemu.nextPc(o, pc);
    }
    if (u < all.len) {
        e.handBack(u, pc);
    } else {
        // The terminator set l_npc (and l_code = done): continue at a member.
        const last = all[all.len - 1];
        switch (last.h) {
            .jal, .goto => if (rg.memberAt(last.imm)) |t| toMember(e, rg, t),
            .beq, .bne, .blt, .bge, .bltu, .bgeu => {
                for ([_]u64{ last.imm, b.end_pc }) |pt| {
                    if (rg.memberAt(pt)) |t| targetIf(e, rg, t);
                }
            },
            .jalr => for (0..rg.n) |t| targetIf(e, rg, t),
            else => {},
        }
        statInc(e, Jx.region_out);
        e.brExit();
    }
    e.close();
}

/// if (l_npc == member t's pc) toMember(t)
fn targetIf(e: *Emit, rg: *Region, t: usize) void {
    e.get(l_npc);
    e.k64(rg.block(t).pc);
    e.op(W.i64_eq);
    e.open(W.@"if", W.void_t);
    toMember(e, rg, t);
    e.close();
}

/// Branch to member t's checked entry. A branch to the start of the member
/// being run (a jalr) needs no op or generation test, and continues in the
/// member's own loop.
fn toMember(e: *Emit, rg: *Region, t: usize) void {
    if (t == rg.cur) {
        const b = rg.block(t);
        e.irqWord();
        e.get(l_jl);
        e.k64(b.ninsn);
        e.op(W.i64_lt_u);
        e.op(W.i32_or);
        e.open(W.@"if", W.void_t);
        statInc(e, Jx.region_stop);
        e.exit(b.pc, code_done_stop);
        e.brExit();
        e.close();
        e.get(l_jl);
        e.k64(b.ninsn);
        e.op(W.i64_sub);
        e.set(l_jl);
        statInc(e, Jx.region_hops);
        e.op(W.br);
        e.uleb(e.nest - rg.self);
        return;
    }
    if ((rg.block(t).pc ^ rg.block(rg.cur).pc) >> 12 != 0) statInc(e, Jx.region_cross);
    e.k64(2 * t);
    e.set(l_next);
    e.op(W.br);
    e.uleb(e.nest - rg.top);
}

/// Member m's checked entry (see above): checks, charge, then fall through
/// into m; or return to `run` with pc = m's start.
fn checkedEntry(e: *Emit, rg: *Region, m: usize) void {
    const b = rg.block(m);
    const at = blocks_off + @as(u64, rg.idx[m]) * @sizeOf(Block);
    e.irqWord();
    e.get(l_jl);
    e.k64(b.ninsn);
    e.op(W.i64_lt_u);
    e.op(W.i32_or);
    // The same decoded block: its ops start where they did when this
    // module was emitted (a re-decode takes new ops until a cache reset,
    // which frees every module).
    e.get(l_cpu);
    e.addr();
    e.mem(W.i32_load, 2, at + @offsetOf(Block, "op"));
    e.k32(@bitCast(b.op));
    e.op(W.i32_ne);
    e.op(W.i32_or);
    // Valid under the current fill of its page: the generation the member
    // being run was validated under (l_g), else the generation of one of
    // the two exec-TLB entries of its page's set (like `lookup`).
    const set: u64 = tlb_x_off + 2 * ((b.pc >> 12) % xtlb_sets) * @sizeOf(XTlb) + @offsetOf(XTlb, "gen");
    e.get(l_cpu);
    e.addr();
    e.mem(W.i64_load, 3, at + @offsetOf(Block, "tgen"));
    e.tee(l_tg);
    e.get(l_g);
    e.op(W.i64_ne);
    e.open(W.@"if", W.i32_t);
    e.get(l_tg);
    e.get(l_cpu);
    e.addr();
    e.mem(W.i64_load, 3, set);
    e.op(W.i64_ne);
    e.get(l_tg);
    e.get(l_cpu);
    e.addr();
    e.mem(W.i64_load, 3, set + @sizeOf(XTlb));
    e.op(W.i64_ne);
    e.op(W.i32_and);
    e.op(W.@"else");
    e.k32(0);
    e.close();
    e.op(W.i32_or);
    e.open(W.@"if", W.void_t);
    statInc(e, Jx.region_stop);
    e.exit(b.pc, code_done_stop);
    e.brExit();
    e.close();
    e.get(l_jl);
    e.k64(b.ninsn);
    e.op(W.i64_sub);
    e.set(l_jl);
    e.get(l_tg);
    e.set(l_g);
    statInc(e, Jx.region_hops);
}

/// Side exit at op k of member b towards pc: refund the rest of b, then
/// continue at a member or leave ("done": `run` refunds nothing).
fn regionSide(e: *Emit, rg: *Region, pc: u64, k: usize, b: *const Block) void {
    const refund = b.ninsn - (k + 1);
    if (refund > 0) {
        e.get(l_jl);
        e.k64(refund);
        e.op(W.i64_add);
        e.set(l_jl);
    }
    if (rg.memberAt(pc)) |t| toMember(e, rg, t);
    statInc(e, Jx.region_out);
    e.exit(pc, code_done_side);
    e.brExit();
}

/// Epilogue part: name the member the code leaves from.
fn regionExit(e: *Emit) void {
    e.get(l_cpu);
    e.addr();
    e.get(l_cur);
    e.mem(W.i64_store, 3, jit_off + @offsetOf(State, "cur"));
}

/// -Dkwemu-stats: count Stats.jx[i] in the generated code.
fn statInc(e: *Emit, i: usize) void {
    if (!kwemu.stats_on) return;
    const off = priv_off + @offsetOf(@FieldType(Cpu, "priv"), "stats") + @offsetOf(kwemu.Stats, "jit") + @offsetOf(kwemu.JitStats, "jx") + 8 * i;
    e.get(l_cpu);
    e.addr();
    e.get(l_cpu);
    e.addr();
    e.mem(W.i64_load, 3, off);
    e.k64(1);
    e.op(W.i64_add);
    e.mem(W.i64_store, 3, off);
}

comptime {
    std.debug.assert(@sizeOf(Op) == 16);
    // TLB index (va >> 8) & dtlb_mask assumes 16-byte entries, a power-of-two
    // count, and read and write TLBs of the same length.
    std.debug.assert(@sizeOf(@typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_r")).array.child) == 16);
    std.debug.assert(std.math.isPowerOfTwo(@typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_r")).array.len));
    std.debug.assert(@typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_r")).array.len ==
        @typeInfo(@FieldType(@FieldType(Cpu, "priv"), "tlb_w")).array.len);
}
