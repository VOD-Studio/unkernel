// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! Unit tests for the kwemu library (Zig API, native). The end-to-end tests
//! that use the C ABI with real guests are in harness.zig / test/kwemu-test.mjs.

const std = @import("std");
const kwemu = @import("kwemu.zig");
const jit = @import("jit.zig");
const core = @import("../cpu/core.zig");
const t = std.testing;
const alloc = if (@hasDecl(@import("root"), "test_allocator")) @import("root").test_allocator else t.allocator;
const Cpu = kwemu.Cpu;
const Regs = kwemu.Regs;

const V = 1;
const R = 2;
const W = 4;
const X = 8;
const U = 16;
const A = 64;
const D = 128;

// ---- tiny assembler ------------------------------------------------------------

fn rtype(op: u32, f3: u32, f7: u32, rd: u32, rs1: u32, rs2: u32) u32 {
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
fn itype(op: u32, f3: u32, rd: u32, rs1: u32, imm: i32) u32 {
    return (@as(u32, @bitCast(imm)) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
fn addi(rd: u32, rs1: u32, imm: i32) u32 {
    return itype(0x13, 0, rd, rs1, imm);
}
fn ld(rd: u32, rs1: u32, imm: i32) u32 {
    return itype(0x03, 3, rd, rs1, imm);
}
fn lw(rd: u32, rs1: u32, imm: i32) u32 {
    return itype(0x03, 2, rd, rs1, imm);
}
fn store(f3: u32, rs2: u32, rs1: u32, imm: i32) u32 {
    const u: u32 = @bitCast(imm);
    return ((u >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((u & 31) << 7) | 0x23;
}
fn sd(rs2: u32, rs1: u32, imm: i32) u32 {
    return store(3, rs2, rs1, imm);
}
fn sw(rs2: u32, rs1: u32, imm: i32) u32 {
    return store(2, rs2, rs1, imm);
}
fn lui(rd: u32, imm20: u32) u32 {
    return (imm20 << 12) | (rd << 7) | 0x37;
}
fn jal(rd: u32, off: i32) u32 {
    const u: u32 = @bitCast(off);
    return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3ff) << 21) | (((u >> 11) & 1) << 20) | (((u >> 12) & 0xff) << 12) | (rd << 7) | 0x6f;
}
fn amo(f5: u32, f3: u32, rd: u32, rs1: u32, rs2: u32) u32 {
    return rtype(0x2f, f3, f5 << 2, rd, rs1, rs2);
}
const ecall: u32 = 0x73;

// ---- machine: 1 MiB of "physical memory" at pa 0x8000_0000 -------------------

const pa_base: u64 = 0x8000_0000;

const Machine = struct {
    mem: []align(4096) u8,
    next: u64 = 0,
    root: u64 = 0,
    cpu: *Cpu,
    regs: Regs = .{},

    fn init() !Machine {
        return initSize(1 << 20);
    }
    fn initSize(size: usize) !Machine {
        const mem = try alloc.alignedAlloc(u8, .fromByteUnits(4096), size);
        @memset(mem, 0);
        const cpu_mem = try alloc.alignedAlloc(u8, .fromByteUnits(8), kwemu.cpu_size);
        @memset(cpu_mem, 0xaa); // init must clear it
        const cpu: *Cpu = @ptrCast(cpu_mem.ptr);
        kwemu.cpuInit(cpu);
        var m: Machine = .{ .mem = mem, .cpu = cpu };
        cpu.phys_base = @intFromPtr(mem.ptr) -% pa_base;
        m.root = m.frame();
        kwemu.setPgd(cpu, m.root);
        return m;
    }
    fn deinit(m: *Machine) void {
        m.cpu.resetCache(); // gives JIT slots back to the host
        alloc.free(m.mem);
        const p: [*]align(8) u8 = @ptrCast(m.cpu);
        const sl: []align(8) u8 = p[0..kwemu.cpu_size];
        alloc.free(sl);
    }
    fn frame(m: *Machine) u64 {
        const pa = pa_base + m.next;
        m.next += 4096;
        return pa;
    }
    fn bytes(m: *Machine, pa: u64) []u8 {
        return m.mem[@intCast(pa - pa_base)..][0..4096];
    }
    fn tbl(m: *Machine, pa: u64) *[512]u64 {
        return @ptrCast(@alignCast(m.bytes(pa).ptr));
    }
    fn slot(m: *Machine, va: u64) *u64 {
        var tb = m.root;
        var level: u6 = 2;
        while (level > 0) : (level -= 1) {
            const e = &m.tbl(tb)[@intCast((va >> (12 + 9 * level)) & 511)];
            if (e.* & V == 0) e.* = ((m.frame() >> 12) << 10) | V;
            tb = (e.* >> 10) << 12;
        }
        return &m.tbl(tb)[@intCast((va >> 12) & 511)];
    }
    fn map(m: *Machine, va: u64, pa: u64, flags: u64) void {
        m.slot(va).* = ((pa >> 12) << 10) | flags | V;
    }
    fn code(m: *Machine, va: u64, words: []const u32) u64 {
        const pa = m.frame();
        @memcpy(m.bytes(pa)[0 .. words.len * 4], std.mem.sliceAsBytes(words));
        m.map(va, pa, R | X | U | A);
        m.cpu.flushAll();
        m.regs.pc = va;
        return pa;
    }
    fn run(m: *Machine, budget: u64) u32 {
        m.cpu.budget = budget;
        return kwemu.run(m.cpu, &m.regs);
    }
};

const EV_BUDGET = 0;
const EV_SYSCALL = 1;
const EV_FAULT = 2;
const EV_ILLEGAL = 3;
const EV_MISALIGNED = 5;
const EV_INTERRUPT = 6;

test "kwemu: syscall event advances pc, counts instructions and budget" {
    var m = try Machine.init();
    defer m.deinit();
    _ = m.code(0x10000, &.{ addi(10, 0, 5), addi(10, 10, 7), addi(17, 0, 93), ecall, addi(11, 0, 1) });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 12), m.regs.x[10]);
    try t.expectEqual(@as(u64, 0x10010), m.regs.pc);
    try t.expectEqual(@as(u64, 4), m.cpu.icount);
    try t.expectEqual(@as(u64, 96), m.cpu.budget);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.cpu.ev.kind);
    // budget exhaustion: an infinite loop
    _ = m.code(0x20000, &.{ addi(5, 5, 1), jal(0, -4) });
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(1001));
    try t.expectEqual(@as(u64, 0), m.cpu.budget);
    try t.expectEqual(@as(u64, 501), m.regs.x[5]);
    try t.expectEqual(@as(u64, 4 + 1001), m.cpu.icount);
}

test "kwemu: loop, mul, stack store/load" {
    var m = try Machine.init();
    defer m.deinit();
    m.map(0x20000, m.frame(), R | W | U | A | D);
    m.regs.x[2] = 0x21000; // sp
    // a0 = sum(1..10) via a loop; store/load through the stack; a2 = a0 * a0
    _ = m.code(0x10000, &.{
        0x00000513, // addi a0, x0, 0
        0x00a00593, // addi a1, x0, 10
        0x00b50533, // loop: add a0, a0, a1
        0xfff58593, // addi a1, a1, -1
        0xfe059ce3, // bne a1, x0, loop
        0xfea13c23, // sd a0, -8(sp)
        0xff813603, // ld a2, -8(sp)
        0x02c60633, // mul a2, a2, a2
        ecall,
    });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1000));
    try t.expectEqual(@as(u64, 55), m.regs.x[10]);
    try t.expectEqual(@as(u64, 55 * 55), m.regs.x[12]);
    try t.expectEqual(@as(u64, 0x10024), m.regs.pc);
    try t.expectEqual(@as(u64, 2 + 3 * 10 + 4), m.cpu.icount);
}

test "kwemu: compressed instructions, then a fault restarts at the right pc" {
    var m = try Machine.init();
    defer m.deinit();
    _ = m.code(0x10000, &.{
        0x050d4515, // c.li a0, 5 (0x4515) ; c.addi a0, 3 (0x050d)
        0x000302b7, // lui t0, 0x30
        0x0002b583, // ld a1, 0(t0) -> fault at 0x30000 (unmapped)
        ecall,
    });
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u64, 8), m.regs.x[10]);
    try t.expectEqual(@as(u32, 0), m.cpu.ev.access); // read
    try t.expectEqual(@as(u64, 0x30000), m.cpu.ev.addr);
    try t.expectEqual(@as(u64, 0x10008), m.regs.pc); // at the load
    const data = m.frame();
    std.mem.writeInt(u64, m.bytes(data)[0..8], 0x0123456789abcdef, .little);
    m.map(0x30000, data, R | U | A);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 0x0123456789abcdef), m.regs.x[11]);
    try t.expectEqual(@as(u64, 0x10010), m.regs.pc);
}

test "kwemu: A/D bits, U bit, and fault restart" {
    var m = try Machine.init();
    defer m.deinit();
    const code_pa = m.frame();
    const prog = [_]u32{ lui(5, 0x30), ld(6, 5, 8), sd(6, 5, 16), ecall };
    @memcpy(m.bytes(code_pa)[0..16], std.mem.sliceAsBytes(&prog));
    m.map(0x10000, code_pa, R | X | U); // A=0
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u32, 2), m.cpu.ev.access); // exec
    try t.expectEqual(@as(u64, 0x10000), m.cpu.ev.addr);
    m.slot(0x10000).* |= A;
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    // data page mapped without U: protection fault
    const data = m.frame();
    std.mem.writeInt(u64, m.bytes(data)[8..16], 0x1122334455667788, .little);
    m.map(0x30000, data, R | W | A);
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u32, 0), m.cpu.ev.access);
    try t.expectEqual(@as(u64, 0x30008), m.cpu.ev.addr);
    try t.expectEqual(@as(u64, 0x10004), m.regs.pc); // at the load
    m.slot(0x30000).* |= U;
    // load works now; the store faults on D=0
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u32, 1), m.cpu.ev.access);
    try t.expectEqual(@as(u64, 0x30010), m.cpu.ev.addr);
    try t.expectEqual(@as(u64, 0x10008), m.regs.pc);
    m.slot(0x30000).* |= D;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 0x1122334455667788), std.mem.readInt(u64, m.bytes(data)[16..24], .little));
}

test "kwemu: page-straddling accesses, invalid PTE shapes, non-canonical addresses" {
    var m = try Machine.init();
    defer m.deinit();
    const p0 = m.frame();
    m.map(0x40000, p0, R | W | U | A | D);
    // store 8 bytes at 0x40ffc: second page unmapped -> fault on it, nothing written
    _ = m.code(0x10000, &.{ lui(5, 0x41), addi(6, 0, -1), sd(6, 5, -4), ld(7, 5, -4), ecall });
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u64, 0x41000), m.cpu.ev.addr);
    try t.expectEqual(@as(u32, 1), m.cpu.ev.access);
    try t.expectEqual(@as(u8, 0), m.bytes(p0)[4095]);
    const p1 = m.frame();
    m.map(0x41000, p1, R | W | U | A | D);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, std.math.maxInt(u64)), m.regs.x[7]);
    try t.expectEqual(@as(u8, 0xff), m.bytes(p0)[4092]);
    try t.expectEqual(@as(u8, 0xff), m.bytes(p1)[3]);
    try t.expectEqual(@as(u8, 0), m.bytes(p1)[4]);

    // W without R is reserved -> fault; superpage leaf -> fault; non-canonical -> fault
    _ = m.code(0x10000, &.{ lui(5, 0x50), lw(6, 5, 0), ecall });
    m.map(0x50000, m.frame(), W | U | A | D);
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    m.map(0x50000, m.frame(), R | U | A);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    // 2 MiB leaf at level 1 for 0x4000_0000
    const l2e = &m.tbl(m.root)[1];
    l2e.* = ((m.frame() >> 12) << 10) | V;
    m.tbl((l2e.* >> 10) << 12)[0] = ((pa_base >> 12) << 10) | V | R | U | A;
    m.regs.x[5] = 0x4000_0000;
    _ = m.code(0x10000, &.{ lw(6, 5, 0), ecall });
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    m.regs.x[5] = 0x0000_8000_0000_0000;
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u64, 0x0000_8000_0000_0000), m.cpu.ev.addr);
}

test "kwemu: TLB caches until flushed; set_pgd switches address spaces" {
    var m = try Machine.init();
    defer m.deinit();
    const a = m.frame();
    const b = m.frame();
    m.bytes(a)[0] = 1;
    m.bytes(b)[0] = 2;
    m.map(0x60000, a, R | U | A);
    _ = m.code(0x10000, &.{ lui(5, 0x60), lw(6, 5, 0), ecall });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[6]);
    m.map(0x60000, b, R | U | A); // remap without flush: stale translation
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[6]);
    kwemu.Cpu.flushRange(m.cpu, 0x60000, 0x61000);
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[6]);
    // Removing the PTE + flush_all -> fault.
    m.slot(0x60000).* = 0;
    m.cpu.flushAll();
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    // A second address space sharing the code page.
    const root1 = m.root;
    m.root = m.frame();
    _ = m.code(0x10000, &.{ lui(5, 0x60), lw(6, 5, 0), ecall });
    m.map(0x60000, a, R | U | A);
    kwemu.setPgd(m.cpu, m.root);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[6]);
    kwemu.setPgd(m.cpu, root1);
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
}

test "kwemu: code page rewritten after flush runs the new code (no stale decode)" {
    var m = try Machine.init();
    defer m.deinit();
    const pa = m.code(0x10000, &.{ addi(10, 0, 1), ecall });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
    // Same physical page, new code (as after COW/reuse + flush_icache).
    @memcpy(m.bytes(pa)[0..8], std.mem.sliceAsBytes(&[_]u32{ addi(10, 0, 2), ecall }));
    m.cpu.flushAll();
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[10]);
}

test "kwemu: irq_pending polled at block ends (bounded latency)" {
    var m = try Machine.init();
    defer m.deinit();
    const data = m.frame();
    m.map(0x70000, data, R | W | U | A | D);
    const irq: *const volatile u32 = @ptrCast(@alignCast(m.bytes(data).ptr));
    m.cpu.irq_pending = irq;
    // x5 = &doorbell; x6 = 1; addi x7,x7,1; sw x6,0(x5) ; loop: addi x8,x8,1 ; j loop
    _ = m.code(0x10000, &.{ lui(5, 0x70), addi(6, 0, 1), sw(6, 5, 0), addi(8, 8, 1), jal(0, -4) });
    try t.expectEqual(@as(u32, EV_INTERRUPT), m.run(1000));
    // Within one block (<= 64 instructions; the loop is followed inside a
    // superblock), at an exact instruction boundary.
    const n = m.cpu.icount;
    try t.expect(n >= 4 and n <= 64);
    try t.expectEqual((n - 3 + 1) / 2, m.regs.x[8]);
    try t.expectEqual(@as(u64, if ((n - 3) % 2 == 1) 0x10010 else 0x1000c), m.regs.pc);
    try t.expectEqual(@as(u64, 1000 - n), m.cpu.budget);
    // still pending at entry -> returns immediately without executing
    try t.expectEqual(@as(u32, EV_INTERRUPT), m.run(1000));
    try t.expectEqual(n, m.cpu.icount);
    m.bytes(data)[0] = 0;
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(10));
}

test "kwemu: illegal, misaligned atomic, LR/SC reservation" {
    var m = try Machine.init();
    defer m.deinit();
    _ = m.code(0x10000, &.{0xffffffff});
    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10));
    try t.expectEqual(@as(u64, 0xffffffff), m.cpu.ev.insn);
    try t.expectEqual(@as(u64, 0x10000), m.regs.pc);
    try t.expectEqual(@as(u64, 0), m.cpu.icount);
    // csrrw to a read-only counter is illegal; rdinstret is not
    _ = m.code(0x10000, &.{ addi(5, 0, 3), addi(5, 5, 3), itype(0x73, 2, 6, 0, 0xc02), ecall });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10));
    try t.expectEqual(@as(u64, 2), m.regs.x[6]);
    _ = m.code(0x10000, &.{itype(0x73, 1, 6, 5, 0xc00)});
    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10));

    const data = m.frame();
    m.map(0x80000, data, R | W | U | A | D);
    m.regs.x[5] = 0x80002;
    _ = m.code(0x10000, &.{amo(0, 2, 6, 5, 7)}); // amoadd.w x6, x7, (x5)
    try t.expectEqual(@as(u32, EV_MISALIGNED), m.run(10));
    try t.expectEqual(@as(u64, 0x80002), m.cpu.ev.addr);

    // lr.d / sc.d succeeds; sc.d after clear_reservation fails
    m.regs.x[5] = 0x80008;
    m.regs.x[7] = 42;
    const lrsc = [_]u32{ amo(2, 3, 6, 5, 0), amo(3, 3, 8, 5, 7), ecall };
    _ = m.code(0x10000, &lrsc);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10));
    try t.expectEqual(@as(u64, 0), m.regs.x[8]);
    try t.expectEqual(@as(u64, 42), std.mem.readInt(u64, m.bytes(data)[8..16], .little));
    _ = m.code(0x10000, &.{ amo(2, 3, 6, 5, 0), ecall, amo(3, 3, 8, 5, 7), ecall });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10));
    kwemu.clearReservation(m.cpu);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10));
    try t.expectEqual(@as(u64, 1), m.regs.x[8]);
}

// ---- decoded-block cache: invalidation, precise state, budget, irq --------------

const fence_i: u32 = 0x0000100f;
const nop: u32 = 0x00000013;
fn branch(f3: u32, rs1: u32, rs2: u32, off: i32) u32 {
    const u: u32 = @bitCast(off);
    return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
        (((u >> 1) & 0xf) << 8) | (((u >> 11) & 1) << 7) | 0x63;
}
fn putCode(m: *Machine, pa: u64, off: usize, words: []const u32) void {
    @memcpy(m.bytes(pa)[off..][0 .. words.len * 4], std.mem.sliceAsBytes(words));
}
const RWX = R | W | X | U | A | D;

test "kwemu cache: self-modifying store later in the same block and into a cached block" {
    var m = try Machine.init();
    defer m.deinit();
    const pa = m.frame();
    m.map(0x10000, pa, RWX);
    // 0x10000: x5 = 0x10000; x6 = addi x10,x0,2; sw x6, 20(x5); nop; addi x10,x0,1; ecall
    putCode(&m, pa, 0, &.{ lui(5, 0x10), lui(6, 0x200), addi(6, 6, 0x513), sw(6, 5, 20), nop, addi(10, 0, 1), ecall });
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[10]);
    try t.expectEqual(@as(u64, 7), m.cpu.icount);

    // A block that already ran (cached), then overwritten by a store from
    // another block of the same page.
    putCode(&m, pa, 0x100, &.{ addi(10, 0, 1), ecall });
    m.regs.pc = 0x10100;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
    // 0x10200: sw x6, 0x100(x5); j 0x10100   (x5/x6 still set)
    putCode(&m, pa, 0x200, &.{ sw(6, 5, 0x100), jal(0, -0x104) });
    m.regs.pc = 0x10200;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[10]);
}

test "kwemu cache: store through a writable alias of an exec-only mapping" {
    var m = try Machine.init();
    defer m.deinit();
    const pa = m.code(0x10000, &.{ addi(10, 0, 1), ecall });
    m.map(0x40000, pa, R | W | U | A | D);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
    // 0x10100: x5 = 0x40000; x6 = addi x10,x0,2; sw x6,0(x5); j 0x10000
    putCode(&m, pa, 0x100, &.{ lui(5, 0x40), lui(6, 0x200), addi(6, 6, 0x513), sw(6, 5, 0), jal(0, -0x110) });
    m.regs.pc = 0x10100;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[10]);
    // A store to a data chunk of the code page does not disturb anything.
    // (The kernel rewrote code: it must flush.)
    putCode(&m, pa, 0x100, &.{ sw(6, 5, 0x7f0), addi(11, 0, 5), ecall });
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    m.regs.pc = 0x10100;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 0x00200513), std.mem.readInt(u32, m.bytes(pa)[0x7f0..0x7f4], .little));
    try t.expectEqual(@as(u64, 5), m.regs.x[11]);
}

test "kwemu cache: kernel rewrite + flush_tlb_range / COW copy / FENCE.I" {
    var m = try Machine.init();
    defer m.deinit();
    const pa = m.code(0x10000, &.{ addi(10, 0, 1), ecall });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
    // Kernel rewrites the page in place, then flushes just that page.
    putCode(&m, pa, 0, &.{addi(10, 0, 2)});
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[10]);
    // COW: copy to a new frame (one instruction changed), remap, flush.
    const copy = m.frame();
    @memcpy(m.bytes(copy), m.bytes(pa));
    putCode(&m, copy, 0, &.{addi(10, 0, 3)});
    m.map(0x10000, copy, R | X | U | A);
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 3), m.regs.x[10]);
    // Identical bytes in a different frame still re-resolve (host address
    // is part of the key): remap back to the original frame.
    putCode(&m, pa, 0, &.{addi(10, 0, 3)});
    m.map(0x10000, pa, R | X | U | A);
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    // Kernel rewrite with no flush, then the guest executes FENCE.I.
    putCode(&m, pa, 0, &.{addi(10, 0, 4)});
    putCode(&m, pa, 0x100, &.{ fence_i, jal(0, -0x104) });
    m.regs.pc = 0x10100;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 4), m.regs.x[10]);
    // ... and kw_flush_tlb_all (the kernel's icache flush).
    putCode(&m, pa, 0, &.{addi(10, 0, 5)});
    m.cpu.flushAll();
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 5), m.regs.x[10]);
}

test "kwemu cache: pgd switch with the same VA mapping different code" {
    var m = try Machine.init();
    defer m.deinit();
    const root1 = m.root;
    _ = m.code(0x10000, &.{ addi(10, 0, 1), ecall });
    const root2 = m.frame();
    m.root = root2;
    _ = m.code(0x10000, &.{ addi(10, 0, 2), ecall });
    for (0..4) |i| {
        const two = i % 2 == 1;
        kwemu.setPgd(m.cpu, if (two) root2 else root1);
        m.regs.pc = 0x10000;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
        try t.expectEqual(@as(u64, if (two) 2 else 1), m.regs.x[10]);
    }
}

test "kwemu cache: code running across a page boundary whose second page is remapped" {
    var m = try Machine.init();
    defer m.deinit();
    const pa = m.frame();
    const pb = m.frame();
    m.map(0x10000, pa, R | X | U | A);
    m.map(0x11000, pb, R | X | U | A);
    putCode(&m, pa, 0xff8, &.{ addi(10, 0, 1), addi(11, 0, 1) });
    putCode(&m, pb, 0, &.{ addi(12, 0, 7), ecall });
    m.regs.pc = 0x10ff8;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 7), m.regs.x[12]);
    const pb2 = m.frame();
    putCode(&m, pb2, 0, &.{ addi(12, 0, 9), ecall });
    m.map(0x11000, pb2, R | X | U | A);
    kwemu.Cpu.flushRange(m.cpu, 0x11000, 0x12000);
    m.regs.pc = 0x10ff8;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 9), m.regs.x[12]);
    try t.expectEqual(@as(u64, 8), m.cpu.icount);

    // A 32-bit instruction straddling the boundary: addi x10,x0,1; c.nop;
    // addi x12,x0,7 = 0x00700613 (low half at 0x10ffe, high half at
    // 0x11000), then ecall.
    std.mem.writeInt(u16, m.bytes(pa)[0xffc..][0..2], 0x0001, .little);
    std.mem.writeInt(u16, m.bytes(pa)[0xffe..][0..2], 0x0613, .little);
    std.mem.writeInt(u16, m.bytes(pb2)[0..2], 0x0070, .little);
    std.mem.writeInt(u32, m.bytes(pb2)[2..6], ecall, .little);
    m.regs.pc = 0x10ff8;
    m.regs.x[12] = 0;
    m.cpu.flushAll();
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 7), m.regs.x[12]);
    try t.expectEqual(@as(u64, 0x11006), m.regs.pc);
    const pb3 = m.frame();
    @memcpy(m.bytes(pb3), m.bytes(pb2));
    std.mem.writeInt(u16, m.bytes(pb3)[0..2], 0x0090, .little); // addi x12,x0,9
    m.map(0x11000, pb3, R | X | U | A);
    kwemu.Cpu.flushRange(m.cpu, 0x11000, 0x12000);
    m.regs.pc = 0x10ff8;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 9), m.regs.x[12]);
    // Second page unmapped: exec fault on it, pc on the straddling insn.
    m.slot(0x11000).* = 0;
    kwemu.Cpu.flushRange(m.cpu, 0x11000, 0x12000);
    m.regs.pc = 0x10ff8;
    m.regs.x[10] = 0;
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u32, 2), m.cpu.ev.access);
    try t.expectEqual(@as(u64, 0x10ffe), m.regs.pc);
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
}

test "kwemu cache: fault in the middle of a block is precise" {
    var m = try Machine.init();
    defer m.deinit();
    m.regs.x[8] = 0x90000; // unmapped
    _ = m.code(0x10000, &.{ addi(5, 0, 1), addi(6, 0, 2), ld(7, 8, 0), addi(9, 0, 3), ecall });
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u64, 0x10008), m.regs.pc);
    try t.expectEqual(@as(u64, 1), m.regs.x[5]);
    try t.expectEqual(@as(u64, 2), m.regs.x[6]);
    try t.expectEqual(@as(u64, 0), m.regs.x[9]);
    try t.expectEqual(@as(u64, 2), m.cpu.icount);
    try t.expectEqual(@as(u64, 98), m.cpu.budget);
    try t.expectEqual(@as(u64, 0x90000), m.cpu.ev.addr);
    // Same with a compressed prefix (c.li x5,1 = 0x4285; c.li x6,2 = 0x4309)
    // and a faulting store.
    const pa = m.frame();
    m.map(0x20000, pa, R | X | U | A);
    std.mem.writeInt(u16, m.bytes(pa)[0..2], 0x4285, .little);
    std.mem.writeInt(u16, m.bytes(pa)[2..4], 0x4309, .little);
    putCode(&m, pa, 4, &.{ sd(5, 8, 0), addi(9, 0, 3), ecall });
    m.regs.pc = 0x20000;
    m.regs.x[5] = 0;
    m.regs.x[6] = 0;
    try t.expectEqual(@as(u32, EV_FAULT), m.run(100));
    try t.expectEqual(@as(u64, 0x20004), m.regs.pc);
    try t.expectEqual(@as(u64, 1), m.regs.x[5]);
    try t.expectEqual(@as(u64, 2), m.regs.x[6]);
    try t.expectEqual(@as(u32, 1), m.cpu.ev.access);
    try t.expectEqual(@as(u64, 4), m.cpu.icount);
    // Map it and resume: the store and the rest complete.
    m.map(0x90000, m.frame(), R | W | U | A | D);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 3), m.regs.x[9]);
    try t.expectEqual(@as(u64, 7), m.cpu.icount);
}

test "kwemu cache: budget expiry inside a block is exact" {
    var m = try Machine.init();
    defer m.deinit();
    var prog: [11]u32 = undefined;
    for (prog[0..10]) |*w| w.* = addi(5, 5, 1);
    prog[10] = jal(0, -40);
    _ = m.code(0x10000, &prog);
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(5));
    try t.expectEqual(@as(u64, 5), m.regs.x[5]);
    try t.expectEqual(@as(u64, 0x10014), m.regs.pc);
    try t.expectEqual(@as(u64, 5), m.cpu.icount);
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(3));
    try t.expectEqual(@as(u64, 8), m.regs.x[5]);
    try t.expectEqual(@as(u64, 0x10020), m.regs.pc);
    // Many slices of odd sizes: count stays exact (11 insns per iteration).
    var total: u64 = 8;
    for (0..200) |i| {
        const n = 1 + (i * 7) % 23;
        try t.expectEqual(@as(u32, EV_BUDGET), m.run(n));
        total += n;
    }
    try t.expectEqual(total, m.cpu.icount);
    const iters = total / 11;
    const rem = total % 11;
    try t.expectEqual(iters * 10 + @min(rem, 10), m.regs.x[5]);
    try t.expectEqual(0x10000 + 4 * rem, m.regs.pc);
}

test "kwemu cache: irq_pending latency is bounded on straight-line code" {
    var m = try Machine.init();
    defer m.deinit();
    const data = m.frame();
    m.map(0x70000, data, R | W | U | A | D);
    m.cpu.irq_pending = @ptrCast(@alignCast(m.bytes(data).ptr));
    var prog: [900]u32 = undefined;
    prog[0] = sw(6, 5, 0);
    for (prog[1..899]) |*w| w.* = addi(7, 7, 1);
    prog[899] = ecall;
    _ = m.code(0x10000, &prog);
    m.regs.x[5] = 0x70000;
    m.regs.x[6] = 1;
    try t.expectEqual(@as(u32, EV_INTERRUPT), m.run(10000));
    try t.expect(m.cpu.icount >= 1 and m.cpu.icount <= 65);
    try t.expectEqual(m.cpu.icount - 1, m.regs.x[7]);
    try t.expectEqual(0x10000 + 4 * m.cpu.icount, m.regs.pc);
}

test "kwemu cache: decoded-op arena overflow resets the cache" {
    var m = try Machine.init();
    defer m.deinit();
    // One physical page of 1024 x `addi x5,x5,1` mapped at 160 consecutive
    // VAs (each VA gets its own blocks), then an ecall page.
    const pa = m.frame();
    var words: [1024]u32 = undefined;
    for (&words) |*w| w.* = addi(5, 5, 1);
    putCode(&m, pa, 0, &words);
    const npages = 160;
    for (0..npages) |i| m.map(0x100000 + i * 4096, pa, R | X | U | A);
    _ = m.code(0x100000 + npages * 4096, &.{ecall});
    for (0..2) |round| {
        m.regs.pc = 0x100000;
        m.regs.x[5] = 0;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 30));
        try t.expectEqual(@as(u64, npages * 1024), m.regs.x[5]);
        _ = round;
    }
}

test "kwemu cache: code pages colliding in the code-page filter" {
    // Pages 16 MiB apart share a filter slot (4096 entries of 4 KiB pages).
    var m = try Machine.initSize(40 << 20);
    defer m.deinit();
    const pa = pa_base + (1 << 20);
    const pb = pa + (16 << 20);
    const pc_ = pa + (32 << 20); // data page, same slot
    m.map(0x10000, pa, R | X | U | A);
    m.map(0x20000, pb, R | X | U | A);
    m.map(0x40000, pa, R | W | U | A | D);
    m.map(0x50000, pb, R | W | U | A | D);
    m.map(0x60000, pc_, R | W | U | A | D);
    putCode(&m, pa, 0, &.{ addi(10, 0, 1), ecall });
    putCode(&m, pb, 0, &.{ addi(11, 0, 1), ecall });
    for ([_]u64{ 0x10000, 0x20000 }) |pc| {
        m.regs.pc = pc;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    }
    // Stores from a third page: to the data page (same slot), then into
    // B's code through its alias; B must see the new instruction.
    putCode(&m, pa, 0x100, &.{ lui(5, 0x60), sd(0, 5, 0), lui(5, 0x50), lui(6, 0x200), addi(6, 6, 0x593), sw(6, 5, 0), ecall });
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    m.regs.pc = 0x10100;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    m.regs.pc = 0x20000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 2), m.regs.x[11]); // addi x11,x0,2 = 0x00200593
    // ... and A still runs its own (unchanged) code.
    m.regs.x[10] = 0;
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
    // Many stores to the colliding data page keep working.
    putCode(&m, pa, 0x200, &.{ lui(5, 0x60), addi(7, 0, 100), sd(7, 5, 8), addi(7, 7, -1), branch(1, 7, 0, -8), ecall });
    kwemu.Cpu.flushRange(m.cpu, 0x10000, 0x11000);
    m.regs.pc = 0x10200;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10000));
    try t.expectEqual(@as(u64, 1), std.mem.readInt(u64, m.bytes(pc_)[8..16], .little));
}

test "kwemu cache: a write-TLB entry filled before its page's code shares a filter slot is flagged" {
    // A and B are 16 MiB apart (same filter slot). B's write-TLB entry is
    // filled while only A is marked, so it has no code_flag. Then B's
    // block marks chunk 0, which A's bits already cover: the slot turns
    // wild, and B's entry must still get code_flag, or a store into B's
    // code takes the fast path and the stale block keeps running.
    var m = try Machine.initSize(40 << 20);
    defer m.deinit();
    const pa = pa_base + (1 << 20);
    const pb = pa + (16 << 20);
    m.map(0x10000, pa, R | X | U | A);
    m.map(0x20000, pb, R | X | U | A);
    m.map(0x50000, pb, R | W | U | A | D);
    putCode(&m, pa, 0, &.{ addi(10, 0, 1), ecall });
    // 0x10100: a store to a data chunk of B fills B's write-TLB entry.
    putCode(&m, pa, 0x100, &.{ lui(5, 0x50), sd(0, 5, 0x7f8), ecall });
    // 0x10200: rewrite B's first instruction to addi x11,x0,2 (0x00200593).
    putCode(&m, pa, 0x200, &.{ lui(5, 0x50), lui(6, 0x200), addi(6, 6, 0x593), sw(6, 5, 0), ecall });
    putCode(&m, pb, 0, &.{ addi(11, 0, 1), ecall });
    for ([_]u64{ 0x10000, 0x10100, 0x20000, 0x10200, 0x20000 }) |pc| {
        m.regs.pc = pc;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    }
    try t.expectEqual(@as(u64, 2), m.regs.x[11]);
    try t.expectEqual(@as(u64, 1), m.regs.x[10]);
}

// ---- JIT tier (src/emu/jit.zig) ------------------------------------------------------
//
// These run everywhere: natively (no JIT) they check the interpreter
// against independent reference results; in the wasm64 unit-test module
// (JIT enabled, eager host, test/kwemu-unit-wasm.mjs) the same programs run
// compiled, and the JIT-specific bookkeeping is checked as well.

const jit_on = jit.enabled;

const JitMode = enum { off, eager, threshold };

/// Compile policy for the following runs: drops every decoded block (and
/// its code), so blocks decoded from now on follow it. Without the JIT tier
/// only the cache reset remains.
fn jitMode(m: *Machine, mode: JitMode, threshold: u32) void {
    m.cpu.resetCache();
    if (!jit_on) return;
    m.cpu.priv.jit.threshold = switch (mode) {
        .off => 0,
        .eager => 1,
        .threshold => threshold,
    };
}

/// Run by the test host inside every kw_host_jit_compile, after the module
/// is installed (test/kwemu-jit-host.mjs calls the export
/// kwemu_test_compile_hook): what another CPU does while this one compiles.
var compile_hook: ?*const fn () void = null;
/// The machine a hook acts on, and its count of calls.
var hook_m: ?*Machine = null;
var hook_calls: u64 = 0;

comptime {
    if (jit_on) @export(&compileHookExport, .{ .name = "kwemu_test_compile_hook" });
}
fn compileHookExport() callconv(.c) void {
    if (compile_hook) |h| h();
}

fn jitStat(m: *Machine, comptime field: []const u8) u64 {
    if (!jit_on) return 0;
    return @field(m.cpu.priv.jit, field);
}

/// Every pool entry in use has live members (blocks whose state names that
/// entry, at their member index), every compiled block is one of them, and
/// a free entry has none.
fn checkJitSlots(m: *Machine) !void {
    if (!jit_on) return;
    const st = &m.cpu.priv.jit;
    var owned: u64 = 0;
    var live: u64 = 0;
    for (st.owner, 0..) |o, i| {
        if (o == 0) {
            for (st.members[i]) |x| try t.expectEqual(@as(u16, 0), x);
            continue;
        }
        owned += 1;
        var n: u64 = 0;
        for (st.members[i], 0..) |x, k| {
            if (x == 0 or jit.slotOf(&m.cpu.priv.blocks[x - 1]) != i + 1) continue;
            try t.expectEqual(k, jit.memberOf(&m.cpu.priv.blocks[x - 1]));
            n += 1;
        }
        try t.expect(n > 0);
        live += n;
    }
    var compiled: u64 = 0;
    for (&m.cpu.priv.blocks, 0..) |*b, i| {
        const s = jit.slotOf(b);
        if (s == 0) continue;
        compiled += 1;
        try t.expectEqual(@as(u16, @intCast(i + 1)), st.members[s - 1][jit.memberOf(b)]);
    }
    try t.expectEqual(live, compiled);
    try t.expectEqual(st.compiles - st.frees, owned);
}

fn sgn(v: u64) i64 {
    return @bitCast(v);
}
fn sx32(v: u32) u64 {
    return @bitCast(@as(i64, @as(i32, @bitCast(v))));
}

const AluCase = struct {
    name: []const u8,
    insn: u32, // x7 = f(x5, x6)
    ref: *const fn (a: u64, b: u64) u64,
};

fn r(f3: u32, f7: u32) u32 {
    return rtype(0x33, f3, f7, 7, 5, 6);
}
fn rw(f3: u32, f7: u32) u32 {
    return rtype(0x3b, f3, f7, 7, 5, 6);
}

// Spec-style references (the Sail loops of the bit-manipulation and
// scalar crypto specs), independent of core.bitmanip.
fn refClmul(a: u64, b: u64) u64 {
    var x: u64 = 0;
    for (0..64) |i| {
        if ((b >> @intCast(i)) & 1 != 0) x ^= a << @intCast(i);
    }
    return x;
}
fn refClmulh(a: u64, b: u64) u64 {
    var x: u64 = 0;
    for (1..64) |i| {
        if ((b >> @intCast(i)) & 1 != 0) x ^= a >> @intCast(64 - i);
    }
    return x;
}
fn refClmulr(a: u64, b: u64) u64 {
    var x: u64 = 0;
    for (0..64) |i| {
        if ((b >> @intCast(i)) & 1 != 0) x ^= a >> @intCast(63 - i);
    }
    return x;
}
fn refXperm(a: u64, b: u64, comptime sz: u7) u64 {
    const mask: u64 = (@as(u64, 1) << sz) - 1;
    var x: u64 = 0;
    var i: u7 = 0;
    while (i < 64) : (i += sz) {
        const idx = (b >> @intCast(i)) & mask;
        if (idx * sz < 64) x |= ((a >> @intCast(idx * sz)) & mask) << @intCast(i);
    }
    return x;
}
fn refRev8(a: u64) u64 {
    var x: u64 = 0;
    for (0..8) |i| x |= ((a >> @intCast(8 * i)) & 0xff) << @intCast(56 - 8 * i);
    return x;
}
fn refBrev8(a: u64) u64 {
    var x: u64 = 0;
    for (0..8) |i| for (0..8) |j| {
        if ((a >> @intCast(8 * i + j)) & 1 != 0) x |= @as(u64, 1) << @intCast(8 * i + 7 - j);
    };
    return x;
}
fn refRot(a: u64, n: u64, comptime w: u7, left: bool) u64 {
    const mask: u64 = if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
    const v = a & mask;
    const k = n % w;
    const s = if (left) k else (w - k) % w; // as a left rotate
    const x = if (s == 0) v else ((v << @intCast(s)) | (v >> @intCast(w - s))) & mask;
    return if (w == 64) x else sx32(@truncate(x));
}

// Zba/Zbb/Zbs references, written as the spec's pseudocode loops.
fn refClz(a: u64, comptime w: u7) u64 {
    var n: u64 = 0;
    var i: i32 = w - 1;
    while (i >= 0 and (a >> @intCast(i)) & 1 == 0) : (i -= 1) n += 1;
    return n;
}
fn refCtz(a: u64, comptime w: u7) u64 {
    var n: u64 = 0;
    while (n < w and (a >> @intCast(n)) & 1 == 0) n += 1;
    return n;
}
fn refCpop(a: u64, comptime w: u7) u64 {
    var n: u64 = 0;
    for (0..w) |i| n += (a >> @intCast(i)) & 1;
    return n;
}
fn refOrcb(a: u64) u64 {
    var x: u64 = 0;
    for (0..8) |i| {
        if ((a >> @intCast(8 * i)) & 0xff != 0) x |= @as(u64, 0xff) << @intCast(8 * i);
    }
    return x;
}
fn refShadd(a: u64, b: u64, comptime n: u6, comptime uw: bool) u64 {
    const x = if (uw) a & 0xffff_ffff else a;
    return (x << n) +% b;
}
fn refBit(b: u64) u64 {
    return @as(u64, 1) << @intCast(b % 64);
}

const alu_cases = [_]AluCase{
    // Zba, Zbb, Zbs, Zicond (enabled by default)
    .{ .name = "sh1add", .insn = r(2, 0x10), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 1, false);
        }
    }.f },
    .{ .name = "sh2add", .insn = r(4, 0x10), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 2, false);
        }
    }.f },
    .{ .name = "sh3add", .insn = r(6, 0x10), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 3, false);
        }
    }.f },
    .{ .name = "add.uw", .insn = rw(0, 0x04), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 0, true);
        }
    }.f },
    .{ .name = "sh1add.uw", .insn = rw(2, 0x10), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 1, true);
        }
    }.f },
    .{ .name = "sh2add.uw", .insn = rw(4, 0x10), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 2, true);
        }
    }.f },
    .{ .name = "sh3add.uw", .insn = rw(6, 0x10), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refShadd(a, b, 3, true);
        }
    }.f },
    .{ .name = "max", .insn = r(6, 0x05), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (sgn(a) > sgn(b)) a else b;
        }
    }.f },
    .{ .name = "maxu", .insn = r(7, 0x05), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (a > b) a else b;
        }
    }.f },
    .{ .name = "min", .insn = r(4, 0x05), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (sgn(a) < sgn(b)) a else b;
        }
    }.f },
    .{ .name = "minu", .insn = r(5, 0x05), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (a < b) a else b;
        }
    }.f },
    .{ .name = "bclr", .insn = r(1, 0x24), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a & ~refBit(b);
        }
    }.f },
    .{ .name = "bset", .insn = r(1, 0x14), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a | refBit(b);
        }
    }.f },
    .{ .name = "binv", .insn = r(1, 0x34), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a ^ refBit(b);
        }
    }.f },
    .{ .name = "bext", .insn = r(5, 0x24), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @intFromBool(a & refBit(b) != 0);
        }
    }.f },
    .{ .name = "czero.eqz", .insn = r(5, 0x07), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (b == 0) 0 else a;
        }
    }.f },
    .{ .name = "czero.nez", .insn = r(7, 0x07), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (b != 0) 0 else a;
        }
    }.f },
    // Zbkb (or Zbb), Zbc/Zbkc, Zbkx (all enabled by default)
    .{ .name = "andn", .insn = r(7, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a & ~b;
        }
    }.f },
    .{ .name = "orn", .insn = r(6, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a | ~b;
        }
    }.f },
    .{ .name = "xnor", .insn = r(4, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return ~(a ^ b);
        }
    }.f },
    .{ .name = "rol", .insn = r(1, 0x30), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refRot(a, b & 63, 64, true);
        }
    }.f },
    .{ .name = "ror", .insn = r(5, 0x30), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refRot(a, b & 63, 64, false);
        }
    }.f },
    .{ .name = "rolw", .insn = rw(1, 0x30), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refRot(a, b & 31, 32, true);
        }
    }.f },
    .{ .name = "rorw", .insn = rw(5, 0x30), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refRot(a, b & 31, 32, false);
        }
    }.f },
    .{ .name = "pack", .insn = r(4, 0x04), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return (b << 32) | (a & 0xffff_ffff);
        }
    }.f },
    .{ .name = "packh", .insn = r(7, 0x04), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return ((b & 0xff) << 8) | (a & 0xff);
        }
    }.f },
    .{ .name = "packw", .insn = rw(4, 0x04), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@truncate(((b & 0xffff) << 16) | (a & 0xffff)));
        }
    }.f },
    .{ .name = "clmul", .insn = r(1, 0x05), .ref = refClmul },
    .{ .name = "clmulh", .insn = r(3, 0x05), .ref = refClmulh },
    .{ .name = "clmulr", .insn = r(2, 0x05), .ref = refClmulr },
    .{ .name = "xperm4", .insn = r(2, 0x14), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refXperm(a, b, 4);
        }
    }.f },
    .{ .name = "xperm8", .insn = r(4, 0x14), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return refXperm(a, b, 8);
        }
    }.f },
    .{ .name = "mul", .insn = r(0, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a *% b;
        }
    }.f },
    .{ .name = "mulh", .insn = r(1, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @truncate(@as(u128, @bitCast((@as(i128, sgn(a)) * sgn(b)) >> 64)));
        }
    }.f },
    .{ .name = "mulhsu", .insn = r(2, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @truncate(@as(u128, @bitCast((@as(i128, sgn(a)) * @as(i128, b)) >> 64)));
        }
    }.f },
    .{ .name = "mulhu", .insn = r(3, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @truncate((@as(u128, a) * b) >> 64);
        }
    }.f },
    .{ .name = "div", .insn = r(4, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            if (b == 0) return std.math.maxInt(u64);
            if (sgn(a) == std.math.minInt(i64) and sgn(b) == -1) return a;
            return @bitCast(@divTrunc(sgn(a), sgn(b)));
        }
    }.f },
    .{ .name = "divu", .insn = r(5, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (b == 0) std.math.maxInt(u64) else a / b;
        }
    }.f },
    .{ .name = "rem", .insn = r(6, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            if (b == 0) return a;
            if (sgn(a) == std.math.minInt(i64) and sgn(b) == -1) return 0;
            return @bitCast(@rem(sgn(a), sgn(b)));
        }
    }.f },
    .{ .name = "remu", .insn = r(7, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return if (b == 0) a else a % b;
        }
    }.f },
    .{ .name = "mulw", .insn = rw(0, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@as(u32, @truncate(a)) *% @as(u32, @truncate(b)));
        }
    }.f },
    .{ .name = "divw", .insn = rw(4, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            const x: i32 = @bitCast(@as(u32, @truncate(a)));
            const y: i32 = @bitCast(@as(u32, @truncate(b)));
            if (y == 0) return std.math.maxInt(u64);
            if (x == std.math.minInt(i32) and y == -1) return sx32(@bitCast(x));
            return sx32(@bitCast(@divTrunc(x, y)));
        }
    }.f },
    .{ .name = "divuw", .insn = rw(5, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            const x: u32 = @truncate(a);
            const y: u32 = @truncate(b);
            return if (y == 0) std.math.maxInt(u64) else sx32(x / y);
        }
    }.f },
    .{ .name = "remw", .insn = rw(6, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            const x: i32 = @bitCast(@as(u32, @truncate(a)));
            const y: i32 = @bitCast(@as(u32, @truncate(b)));
            if (y == 0) return sx32(@bitCast(x));
            if (x == std.math.minInt(i32) and y == -1) return 0;
            return sx32(@bitCast(@rem(x, y)));
        }
    }.f },
    .{ .name = "remuw", .insn = rw(7, 1), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            const x: u32 = @truncate(a);
            const y: u32 = @truncate(b);
            return sx32(if (y == 0) x else x % y);
        }
    }.f },
    .{ .name = "addw", .insn = rw(0, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@as(u32, @truncate(a)) +% @as(u32, @truncate(b)));
        }
    }.f },
    .{ .name = "subw", .insn = rw(0, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@as(u32, @truncate(a)) -% @as(u32, @truncate(b)));
        }
    }.f },
    .{ .name = "sllw", .insn = rw(1, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@as(u32, @truncate(a)) << @as(u5, @truncate(b)));
        }
    }.f },
    .{ .name = "srlw", .insn = rw(5, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@as(u32, @truncate(a)) >> @as(u5, @truncate(b)));
        }
    }.f },
    .{ .name = "sraw", .insn = rw(5, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return sx32(@bitCast(@as(i32, @bitCast(@as(u32, @truncate(a)))) >> @as(u5, @truncate(b))));
        }
    }.f },
    .{ .name = "sll", .insn = r(1, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a << @as(u6, @truncate(b));
        }
    }.f },
    .{ .name = "srl", .insn = r(5, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a >> @as(u6, @truncate(b));
        }
    }.f },
    .{ .name = "sra", .insn = r(5, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @bitCast(sgn(a) >> @as(u6, @truncate(b)));
        }
    }.f },
    .{ .name = "slt", .insn = r(2, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @intFromBool(sgn(a) < sgn(b));
        }
    }.f },
    .{ .name = "sltu", .insn = r(3, 0), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return @intFromBool(a < b);
        }
    }.f },
    .{ .name = "sub", .insn = r(0, 0x20), .ref = struct {
        fn f(a: u64, b: u64) u64 {
            return a -% b;
        }
    }.f },
};

/// Immediate forms (x7 = f(x5)); `imm` is the 12-bit field (shamt incl.
/// the srai/sraiw marker bit).
const ImmCase = struct { insn: u32, kind: enum { slli, srli, srai, slliw, srliw, sraiw, addiw, slti, sltiu, rori, roriw, rev8, brev8, clz, ctz, cpop, clzw, ctzw, cpopw, sext_b, sext_h, zext_h, orc_b, slli_uw, bseti, bclri, binvi, bexti }, imm: i32 };

fn immCase(kind: @FieldType(ImmCase, "kind"), imm: i32) ImmCase {
    const op: u32, const f3: u32, const field: i32 = switch (kind) {
        .slli => .{ 0x13, 1, imm },
        .srli => .{ 0x13, 5, imm },
        .srai => .{ 0x13, 5, imm | 0x400 },
        .slliw => .{ 0x1b, 1, imm },
        .srliw => .{ 0x1b, 5, imm },
        .sraiw => .{ 0x1b, 5, imm | 0x400 },
        .addiw => .{ 0x1b, 0, imm },
        .slti => .{ 0x13, 2, imm },
        .sltiu => .{ 0x13, 3, imm },
        .rori => .{ 0x13, 5, imm | 0x600 },
        .roriw => .{ 0x1b, 5, imm | 0x600 },
        .rev8 => .{ 0x13, 5, 0x6b8 },
        .brev8 => .{ 0x13, 5, 0x687 },
        .clz => .{ 0x13, 1, 0x600 },
        .ctz => .{ 0x13, 1, 0x601 },
        .cpop => .{ 0x13, 1, 0x602 },
        .clzw => .{ 0x1b, 1, 0x600 },
        .ctzw => .{ 0x1b, 1, 0x601 },
        .cpopw => .{ 0x1b, 1, 0x602 },
        .sext_b => .{ 0x13, 1, 0x604 },
        .sext_h => .{ 0x13, 1, 0x605 },
        .zext_h => .{ 0x3b, 4, 0x080 }, // packw rd, rs1, x0
        .orc_b => .{ 0x13, 5, 0x287 },
        .slli_uw => .{ 0x1b, 1, imm | 0x080 },
        .bseti => .{ 0x13, 1, imm | 0x280 },
        .bclri => .{ 0x13, 1, imm | 0x480 },
        .binvi => .{ 0x13, 1, imm | 0x680 },
        .bexti => .{ 0x13, 5, imm | 0x480 },
    };
    return .{ .insn = itype(op, f3, 7, 5, field), .kind = kind, .imm = imm };
}

fn immRef(c: ImmCase, a: u64) u64 {
    const sh: u6 = @intCast(c.imm & 63);
    const a32: u32 = @truncate(a);
    const imm: u64 = @bitCast(@as(i64, c.imm));
    return switch (c.kind) {
        .slli => a << sh,
        .srli => a >> sh,
        .srai => @bitCast(sgn(a) >> sh),
        .slliw => sx32(a32 << @as(u5, @intCast(sh))),
        .srliw => sx32(a32 >> @as(u5, @intCast(sh))),
        .sraiw => sx32(@bitCast(@as(i32, @bitCast(a32)) >> @as(u5, @intCast(sh)))),
        .addiw => sx32(a32 +% @as(u32, @truncate(imm))),
        .slti => @intFromBool(sgn(a) < sgn(imm)),
        .sltiu => @intFromBool(a < imm),
        .rori => refRot(a, sh, 64, false),
        .roriw => refRot(a, sh, 32, false),
        .rev8 => refRev8(a),
        .brev8 => refBrev8(a),
        .clz => refClz(a, 64),
        .ctz => refCtz(a, 64),
        .cpop => refCpop(a, 64),
        .clzw => refClz(a & 0xffff_ffff, 32),
        .ctzw => refCtz(a, 32),
        .cpopw => refCpop(a, 32),
        .sext_b => @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(a)))))),
        .sext_h => @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(a)))))),
        .zext_h => a & 0xffff,
        .orc_b => refOrcb(a),
        .slli_uw => (a & 0xffff_ffff) << sh,
        .bseti => a | refBit(sh),
        .bclri => a & ~refBit(sh),
        .binvi => a ^ refBit(sh),
        .bexti => (a >> sh) & 1,
    };
}

const imm_cases = [_]ImmCase{
    immCase(.slli, 0),    immCase(.slli, 1),     immCase(.slli, 31),     immCase(.slli, 32),    immCase(.slli, 33),    immCase(.slli, 63),
    immCase(.srli, 1),    immCase(.srli, 31),    immCase(.srli, 32),     immCase(.srli, 63),    immCase(.srai, 1),     immCase(.srai, 31),
    immCase(.srai, 32),   immCase(.srai, 40),    immCase(.srai, 63),     immCase(.slliw, 0),    immCase(.slliw, 1),    immCase(.slliw, 31),
    immCase(.srliw, 0),   immCase(.srliw, 1),    immCase(.srliw, 31),    immCase(.sraiw, 0),    immCase(.sraiw, 1),    immCase(.sraiw, 31),
    immCase(.addiw, -1),  immCase(.addiw, 2047), immCase(.addiw, -2048), immCase(.slti, -1),    immCase(.slti, 0),     immCase(.slti, 2047),
    immCase(.sltiu, -1),  immCase(.sltiu, 0),    immCase(.sltiu, 2047),  immCase(.rori, 0),     immCase(.rori, 1),     immCase(.rori, 31),
    immCase(.rori, 32),   immCase(.rori, 63),    immCase(.roriw, 0),     immCase(.roriw, 1),    immCase(.roriw, 16),   immCase(.roriw, 31),
    immCase(.rev8, 0),    immCase(.brev8, 0),
    // Zba, Zbb, Zbs
       immCase(.clz, 0),       immCase(.ctz, 0),      immCase(.cpop, 0),     immCase(.clzw, 0),
    immCase(.ctzw, 0),    immCase(.cpopw, 0),    immCase(.sext_b, 0),    immCase(.sext_h, 0),   immCase(.zext_h, 0),   immCase(.orc_b, 0),
    immCase(.slli_uw, 0), immCase(.slli_uw, 1),  immCase(.slli_uw, 31),  immCase(.slli_uw, 32), immCase(.slli_uw, 63), immCase(.bseti, 0),
    immCase(.bseti, 31),  immCase(.bseti, 32),   immCase(.bseti, 63),    immCase(.bclri, 0),    immCase(.bclri, 31),   immCase(.bclri, 32),
    immCase(.bclri, 63),  immCase(.binvi, 0),    immCase(.binvi, 31),    immCase(.binvi, 32),   immCase(.binvi, 63),   immCase(.bexti, 0),
    immCase(.bexti, 31),  immCase(.bexti, 32),   immCase(.bexti, 63),
};

const edge_values = [_]u64{
    0,                     1,                    2,                        3,                     31,                    32,            33,
    63,                    64,                   0x7fff_ffff,              0x8000_0000,           0xffff_ffff,           0x1_0000_0000, 1 << 63,
    (1 << 63) - 1,         std.math.maxInt(u64), std.math.maxInt(u64) - 1, 0xffff_ffff_8000_0000, 0x1234_5678_9abc_def0, 0xffff_fffe,   0x80,
    0x0000_8080_7f00_0001,
};
const npairs = edge_values.len * edge_values.len;

test "kwemu jit: M extension, W ops, shifts, Zba/Zbb/Zbs/Zicond and Zbkb/Zbc/Zbkx on edge values (JIT vs interpreter vs reference)" {
    var m = try Machine.init();
    defer m.deinit();
    // inputs: (a, b) pairs at 0x200000 (2 pages), outputs at 0x300000
    const in_pa = m.frame();
    _ = m.frame();
    const out_pa = m.frame();
    m.map(0x200000, in_pa, R | W | U | A | D);
    m.map(0x201000, in_pa + 4096, R | W | U | A | D);
    m.map(0x300000, out_pa, R | W | U | A | D);
    const in_bytes = m.mem[@intCast(in_pa - pa_base)..][0 .. 2 * 4096];
    for (edge_values, 0..) |a, i| for (edge_values, 0..) |b, j| {
        const k = i * edge_values.len + j;
        std.mem.writeInt(u64, in_bytes[k * 16 ..][0..8], a, .little);
        std.mem.writeInt(u64, in_bytes[k * 16 + 8 ..][0..8], b, .little);
    };
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    var interp: [npairs]u64 = undefined;
    var ncases: usize = 0;
    for (0..alu_cases.len + imm_cases.len) |ci| {
        const insn = if (ci < alu_cases.len) alu_cases[ci].insn else imm_cases[ci - alu_cases.len].insn;
        // ld x5,0(x10); ld x6,8(x10); OP x7; sd x7,0(x12); x10 += 16; x12 += 8; bne x10,x11 loop
        putCode(&m, code_pa, 0, &.{ ld(5, 10, 0), ld(6, 10, 8), insn, sd(7, 12, 0), addi(10, 10, 16), addi(12, 12, 8), branch(1, 10, 11, -24), ecall });
        m.cpu.flushRange(0x10000, 0x11000); // the kernel rewrote the page
        for ([_]JitMode{ .off, .eager }) |mode| {
            jitMode(&m, mode, 0);
            m.regs.x[10] = 0x200000;
            m.regs.x[11] = 0x200000 + npairs * 16;
            m.regs.x[12] = 0x300000;
            m.regs.pc = 0x10000;
            try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
            for (0..npairs) |k| {
                const a = edge_values[k / edge_values.len];
                const b = edge_values[k % edge_values.len];
                const got = std.mem.readInt(u64, m.bytes(out_pa)[k * 8 ..][0..8], .little);
                const want = if (ci < alu_cases.len) alu_cases[ci].ref(a, b) else immRef(imm_cases[ci - alu_cases.len], a);
                if (got != want) {
                    std.debug.print("case {d} ({s}) mode {s}: a=0x{x} b=0x{x}: got 0x{x} want 0x{x}\n", .{
                        ci, if (ci < alu_cases.len) alu_cases[ci].name else @tagName(imm_cases[ci - alu_cases.len].kind), @tagName(mode), a, b, got, want,
                    });
                    return error.TestUnexpectedResult;
                }
                if (mode == .off) interp[k] = got else try t.expectEqual(interp[k], got);
            }
        }
        ncases += 1;
    }
    try t.expectEqual(alu_cases.len + imm_cases.len, ncases);
    if (jit_on) {
        try t.expect(jitStat(&m, "compiles") >= ncases); // one loop block per case at least
        try t.expectEqual(@as(u64, 0), jitStat(&m, "fails"));
    }
    try checkJitSlots(&m);
}

test "kwemu jit: writes to x0 are dropped, x0 reads as 0, a load into x0 still faults" {
    var m = try Machine.init();
    defer m.deinit();
    m.regs.x[8] = 0x90000; // unmapped at first
    m.regs.x[9] = 300;
    // loop: addi x0,x5,7; lw x0,0(x8); mul x0,x5,x5; divu x0,x5,x0;
    //       add x6,x0,x5; sub x7,x0,x5; jal x0,+4 (followed); addi x5,x5,1; bne x5,x9,loop
    _ = m.code(0x10000, &.{
        addi(0, 5, 7),              lw(0, 8, 0),                   rtype(0x33, 0, 1, 0, 5, 5), rtype(0x33, 5, 1, 0, 5, 0),
        rtype(0x33, 0, 0, 6, 0, 5), rtype(0x33, 0, 0x20, 7, 0, 5), jal(0, 4),                  addi(5, 5, 1),
        branch(1, 5, 9, -32),       ecall,
    });
    try t.expectEqual(@as(u32, EV_FAULT), m.run(10_000));
    try t.expectEqual(@as(u64, 0x10004), m.regs.pc); // at the lw
    try t.expectEqual(@as(u64, 0x90000), m.cpu.ev.addr);
    try t.expectEqual(@as(u64, 1), m.cpu.icount);
    m.map(0x90000, m.frame(), R | U | A);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
    try t.expectEqual(@as(u64, 0), m.regs.x[0]);
    try t.expectEqual(@as(u64, 299), m.regs.x[6]);
    try t.expectEqual(@as(u64, 0) -% 299, m.regs.x[7]);
    try t.expectEqual(@as(u64, 300), m.regs.x[5]);
    try t.expectEqual(@as(u64, 0x10028), m.regs.pc);
    try t.expectEqual(@as(u64, 300 * 9 + 1), m.cpu.icount); // incl. the lw that faulted once
    if (jit_on) try t.expect(jitStat(&m, "compiles") >= 1);
    try checkJitSlots(&m);
}

test "kwemu jit: hand-back at an unsupported op in a hot loop keeps instret exact" {
    var m = try Machine.init();
    defer m.deinit();
    const n = 2000;
    m.regs.x[9] = n;
    m.regs.f[2] = @bitCast(@as(f64, 1.0));
    // loop: addi x5,x5,1; addi x8,x8,2; xor x10,x10,x5; csrrs x6,instret,x0 (generic);
    //       add x7,x7,x6; fadd.d f1,f1,f2,rtz (FP); addi x11,x11,3; bne x5,x9,loop; ecall
    _ = m.code(0x10000, &.{
        addi(5, 5, 1),              addi(8, 8, 2),              rtype(0x33, 4, 0, 10, 10, 5), itype(0x73, 2, 6, 0, 0xc02),
        rtype(0x33, 0, 0, 7, 7, 6), rtype(0x53, 1, 1, 1, 1, 2), addi(11, 11, 3),              branch(1, 5, 9, -28),
        ecall,
    });
    // odd budget slices: every slice boundary and every hand-back must be exact
    var slices: usize = 0;
    var budget: u64 = 7;
    while (true) : (slices += 1) {
        const ev = m.run(budget);
        if (ev == EV_SYSCALL) break;
        try t.expectEqual(@as(u32, EV_BUDGET), ev);
        budget = 1 + (budget * 31 + 17) % 997;
    }
    try t.expect(slices > 10);
    const per = 8;
    try t.expectEqual(@as(u64, n * per + 1), m.cpu.icount);
    try t.expectEqual(@as(u64, (n - 1) * per + 3), m.regs.x[6]); // instret before the csrrs of the last pass
    var sum: u64 = 0;
    var x10: u64 = 0;
    for (0..n) |i| {
        sum += i * per + 3;
        x10 ^= i + 1;
    }
    try t.expectEqual(sum, m.regs.x[7]);
    try t.expectEqual(x10, m.regs.x[10]);
    try t.expectEqual(@as(u64, 2 * n), m.regs.x[8]);
    try t.expectEqual(@as(u64, 3 * n), m.regs.x[11]);
    try t.expectEqual(@as(f64, n), @as(f64, @bitCast(m.regs.f[1])));
    try t.expectEqual(@as(u64, 0x10024), m.regs.pc);
    if (jit_on) {
        try t.expect(jitStat(&m, "compiles") >= 1);
        try t.expect(jitStat(&m, "entries") >= n);
    }
    try checkJitSlots(&m);

    // The same without the counter read (which leaves the block): the
    // FP op (static RTZ: not compiled) is handed back and the interpreter
    // finishes the pass; the next pass of the self-loop must start compiled
    // again.
    // L: addi x5,x5,1; addi x8,x8,2; fadd.d f1,f1,f2,rtz; addi x11,x11,3; bne x5,x9,L; ecall
    _ = m.code(0x20000, &.{ addi(5, 5, 1), addi(8, 8, 2), rtype(0x53, 1, 1, 1, 1, 2), addi(11, 11, 3), branch(1, 5, 9, -16), ecall });
    m.regs.x[5] = 0;
    m.regs.x[8] = 0;
    m.regs.x[11] = 0;
    m.regs.f[1] = 0;
    const ic = m.cpu.icount;
    const e0 = jitStat(&m, "entries");
    budget = 5;
    var slices2: u64 = 0;
    while (true) : (slices2 += 1) {
        const ev = m.run(budget);
        if (ev == EV_SYSCALL) break;
        try t.expectEqual(@as(u32, EV_BUDGET), ev);
        budget = 1 + (budget * 37 + 11) % 499;
    }
    try t.expectEqual(@as(u64, n * 5 + 1), m.cpu.icount - ic);
    try t.expectEqual(@as(u64, 2 * n), m.regs.x[8]);
    try t.expectEqual(@as(u64, 3 * n), m.regs.x[11]);
    try t.expectEqual(@as(f64, n), @as(f64, @bitCast(m.regs.f[1])));
    try t.expectEqual(@as(u64, 0x20018), m.regs.pc);
    // (a pass cut by a slice end is single-stepped instead)
    if (jit_on) try t.expect(jitStat(&m, "entries") - e0 >= n - 2 * (slices2 + 1));
    try checkJitSlots(&m);
}

test "kwemu jit: compiled self-loop: exact budget slices, huge budgets, irq polled every pass" {
    var m = try Machine.init();
    defer m.deinit();
    // 2-insn self-loop: addi x5,x5,1; jal x0,-4 (the block jumps to itself)
    _ = m.code(0x10000, &.{ addi(5, 5, 1), jal(0, -4) });
    var total: u64 = 0;
    for (0..300) |i| {
        const n: u64 = 1 + (i * 7919) % 100_003;
        try t.expectEqual(@as(u32, EV_BUDGET), m.run(n));
        total += n;
        try t.expectEqual(total, m.cpu.icount);
        try t.expectEqual((total + 1) / 2, m.regs.x[5]);
        try t.expectEqual(@as(u64, if (total % 2 == 1) 0x10004 else 0x10000), m.regs.pc);
    }
    // irq: the loop raises the doorbell itself after n passes:
    //   x5 += 1; x9 = n < x5; sw x9,0(x7); j loop   (budget 2^60: jl is capped)
    const data = m.frame();
    m.map(0x70000, data, R | W | U | A | D);
    m.cpu.irq_pending = @ptrCast(@alignCast(m.bytes(data).ptr));
    const n = 100_000;
    m.regs.x[5] = 0;
    m.regs.x[7] = 0x70000;
    m.regs.x[8] = n;
    _ = m.code(0x20000, &.{ addi(5, 5, 1), rtype(0x33, 3, 0, 9, 8, 5), sw(9, 7, 0), jal(0, -12) });
    const icount0 = m.cpu.icount;
    try t.expectEqual(@as(u32, EV_INTERRUPT), m.run(1 << 60));
    try t.expectEqual(@as(u64, n + 1), m.regs.x[5]); // stopped at the end of the pass that rang
    try t.expectEqual(@as(u64, 0x20000), m.regs.pc);
    try t.expectEqual(@as(u64, 4 * (n + 1)), m.cpu.icount - icount0);
    try t.expectEqual(@as(u64, (1 << 60) - 4 * (n + 1)), m.cpu.budget);
    if (jit_on) try t.expect(jitStat(&m, "compiles") >= 2);
    try checkJitSlots(&m);
}

test "kwemu jit: a store into the running compiled block takes effect on the next pass" {
    var m = try Machine.init();
    defer m.deinit();
    const pa = m.frame();
    m.map(0x10000, pa, RWX);
    const old = addi(10, 0, 1);
    const new = addi(10, 0, 2);
    const n = 300;
    const k = 100;
    m.regs.x[6] = k;
    m.regs.x[7] = n;
    m.regs.x[12] = 0x10000;
    m.regs.x[16] = old ^ new;
    m.regs.x[17] = old;
    // L: x5 += 1; addi x10,x0,1 (patched in pass k); x13 += x10;
    //    x14 = (x5 >= k) ? new : old; sw x14, 4(L); bne x5,x7,L; ecall
    putCode(&m, pa, 0, &.{
        addi(5, 5, 1),                 old,              rtype(0x33, 0, 0, 13, 13, 10),
        rtype(0x33, 3, 0, 15, 5, 6),   addi(15, 15, -1), rtype(0x33, 7, 0, 15, 15, 16),
        rtype(0x33, 4, 0, 14, 15, 17), sw(14, 12, 4),    branch(1, 5, 7, -32),
        ecall,
    });
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
    try t.expectEqual(@as(u64, k + 2 * (n - k)), m.regs.x[13]);
    try t.expectEqual(@as(u64, 2), m.regs.x[10]);
    try t.expectEqual(@as(u64, n * 9 + 1), m.cpu.icount);
    try t.expectEqual(new, std.mem.readInt(u32, m.bytes(pa)[4..8], .little));
    if (jit_on) {
        // Every pass stores into the block (same bytes until pass k): the
        // block is revalidated each time and keeps its code; only the real
        // change in pass k drops it.
        try t.expect(jitStat(&m, "frees") >= 1);
        try t.expect(jitStat(&m, "compiles") < 10);
    }
    try checkJitSlots(&m);
}

test "kwemu jit: flush + revalidation keeps the code; a new host page (COW) recompiles" {
    var m = try Machine.init();
    defer m.deinit();
    m.regs.x[6] = 1000;
    const prog = [_]u32{ addi(5, 5, 1), branch(1, 5, 6, -4), ecall };
    const pa = m.code(0x10000, &prog);
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
    try t.expectEqual(@as(u64, 1000), m.regs.x[5]);
    const c1 = jitStat(&m, "compiles");
    if (jit_on) try t.expect(c1 >= 1);
    // flush_tlb_all / flush_tlb_range / set_pgd: revalidated, not recompiled
    for (0..3) |i| {
        switch (i) {
            0 => m.cpu.flushAll(),
            1 => m.cpu.flushRange(0x10000, 0x11000),
            else => kwemu.setPgd(m.cpu, m.root),
        }
        m.regs.x[5] = 0;
        m.regs.pc = 0x10000;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(@as(u64, 1000), m.regs.x[5]);
        try t.expectEqual(c1, jitStat(&m, "compiles"));
    }
    // COW: identical bytes in a new frame -> re-decoded, recompiled
    const copy = m.frame();
    @memcpy(m.bytes(copy), m.bytes(pa));
    m.map(0x10000, copy, R | X | U | A);
    m.cpu.flushRange(0x10000, 0x11000);
    m.regs.x[5] = 0;
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
    try t.expectEqual(@as(u64, 1000), m.regs.x[5]);
    if (jit_on) {
        try t.expect(jitStat(&m, "compiles") > c1);
        try t.expect(jitStat(&m, "frees") >= 1);
    }
    // ... and changed bytes (x5 += 2) run the new code
    const c2 = jitStat(&m, "compiles");
    const copy2 = m.frame();
    @memcpy(m.bytes(copy2), m.bytes(copy));
    putCode(&m, copy2, 0, &.{addi(5, 5, 2)});
    m.map(0x10000, copy2, R | X | U | A);
    m.cpu.flushRange(0x10000, 0x11000);
    m.regs.x[5] = 0;
    m.regs.pc = 0x10000;
    const ic = m.cpu.icount;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
    try t.expectEqual(@as(u64, 1000), m.regs.x[5]);
    try t.expectEqual(@as(u64, 500 * 2 + 1), m.cpu.icount - ic);
    if (jit_on) try t.expect(jitStat(&m, "compiles") > c2);
    try checkJitSlots(&m);
}

test "kwemu jit: compile threshold counts retired instructions, self-loop passes included" {
    var m = try Machine.init();
    defer m.deinit();
    jitMode(&m, .threshold, 4000);
    // 4-insn self-loop, entered once: it must still get compiled
    _ = m.code(0x10000, &.{ addi(5, 5, 1), addi(6, 6, 2), rtype(0x33, 4, 0, 7, 7, 5), jal(0, -12) });
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(4 * 900));
    try t.expectEqual(@as(u64, 0), jitStat(&m, "compiles"));
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(4 * 200 + 3));
    if (jit_on) try t.expectEqual(@as(u64, 1), jitStat(&m, "compiles"));
    try t.expectEqual(@as(u32, EV_BUDGET), m.run(1_000_001));
    const total: u64 = 4 * 900 + 4 * 200 + 3 + 1_000_001;
    try t.expectEqual(total, m.cpu.icount);
    try t.expectEqual((total + 3) / 4, m.regs.x[5]);
    try t.expectEqual(2 * ((total + 2) / 4), m.regs.x[6]);
    var x7: u64 = 0;
    for (1..(total + 1) / 4 + 1) |i| x7 ^= i;
    try t.expectEqual(x7, m.regs.x[7]);
    try t.expectEqual(0x10000 + 4 * (total % 4), m.regs.pc);
    try checkJitSlots(&m);
}

test "kwemu jit: compile threshold counts self-loop passes that an interrupt ends" {
    var m = try Machine.init();
    defer m.deinit();
    jitMode(&m, .threshold, 4000);
    // 5-insn self-loop that rings the doorbell every 64th pass (IPIs on SMP
    // end interpreted self-loops that often):
    //   x5 += 1; x9 = x5 & 63; x9 = x9 == 0; sw x9,0(x7); j loop
    const data = m.frame();
    m.map(0x70000, data, R | W | U | A | D);
    const word: *u32 = @ptrCast(@alignCast(m.bytes(data).ptr));
    m.cpu.irq_pending = word;
    m.regs.x[7] = 0x70000;
    _ = m.code(0x10000, &.{ addi(5, 5, 1), itype(0x13, 7, 9, 5, 63), itype(0x13, 3, 9, 9, 1), sw(9, 7, 0), jal(0, -16) });
    // 64 passes per run, so 320 instructions: the threshold is reached
    // in the 13th run, and only if the passes before each interrupt count.
    for (1..41) |i| {
        word.* = 0;
        try t.expectEqual(@as(u32, EV_INTERRUPT), m.run(1 << 40));
        try t.expectEqual(@as(u64, 64 * i), m.regs.x[5]);
        try t.expectEqual(@as(u64, 5 * 64 * i), m.cpu.icount);
        try t.expectEqual(@as(u64, 0x10000), m.regs.pc);
        if (i == 12) try t.expectEqual(@as(u64, 0), jitStat(&m, "compiles"));
    }
    if (jit_on) try t.expectEqual(@as(u64, 1), jitStat(&m, "compiles"));
    try checkJitSlots(&m);
}

var hook_busy: u32 = 0;
var hook_pa: u64 = 0;

test "kwemu jit: a flush asked for during a compile: nothing runs before the block is looked up again" {
    if (!jit_on) return error.SkipZigTest;
    var m = try Machine.init();
    defer m.deinit();
    jitMode(&m, .eager, 0);
    const irq = m.frame();
    m.map(0x70000, irq, R | W | U | A | D);
    const word: *u32 = @ptrCast(@alignCast(m.bytes(irq).ptr));
    m.cpu.irq_pending = word;
    hook_m = &m;
    defer {
        compile_hook = null;
        hook_m = null;
    }
    // Another CPU maps another page at the block's address while this one
    // compiles the block. It finds jit_busy set and asks for a flush instead
    // of waiting (kernel: tlb.c), so its munmap/mmap may return before this
    // CPU has flushed: the old code must not run after the compile.
    _ = m.code(0x10000, &.{ addi(5, 5, 1), ecall });
    hook_pa = m.frame();
    putCode(&m, hook_pa, 0, &.{ addi(5, 5, 100), ecall });
    hook_calls = 0;
    compile_hook = struct {
        fn f() void {
            const hm = hook_m.?;
            hook_calls += 1;
            if (hook_calls != 1) return;
            hook_busy = @atomicLoad(u32, &hm.cpu.jit_busy, .seq_cst);
            hm.map(0x10000, hook_pa, R | X | U | A);
            @atomicStore(u32, &hm.cpu.flush_all, 1, .seq_cst);
        }
    }.f;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u32, 1), hook_busy);
    try t.expectEqual(@as(u64, 100), m.regs.x[5]);
    try t.expectEqual(@as(u64, 2), m.cpu.icount);
    try t.expectEqual(@as(u64, 98), m.cpu.budget);
    try t.expectEqual(@as(u32, 0), m.cpu.flush_all);
    try t.expectEqual(@as(u32, 0), m.cpu.jit_busy);
    try t.expectEqual(@as(u64, 2), jitStat(&m, "compiles")); // the old block, then the new one
    try t.expectEqual(@as(u64, 2), hook_calls);
    // An interrupt raised during the compile is taken where the
    // interpreter takes it: after the block (here at its ecall's trap, the
    // next run returns it at once).
    _ = m.code(0x20000, &.{ addi(6, 6, 1), ecall });
    hook_calls = 0;
    compile_hook = struct {
        fn f() void {
            hook_calls += 1;
            const w: *volatile u32 = @constCast(hook_m.?.cpu.irq_pending.?);
            w.* = 1;
        }
    }.f;
    const ic = m.cpu.icount;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
    try t.expectEqual(@as(u64, 1), m.regs.x[6]);
    try t.expectEqual(ic + 2, m.cpu.icount);
    try t.expectEqual(@as(u64, 1), hook_calls);
    try t.expectEqual(@as(u32, EV_INTERRUPT), m.run(100));
    try t.expectEqual(ic + 2, m.cpu.icount);
    word.* = 0;
    try t.expectEqual(@as(u64, 3), jitStat(&m, "compiles"));
    try checkJitSlots(&m);
}

test "kwemu jit: resetCache frees every slot" {
    var m = try Machine.init();
    defer m.deinit();
    m.regs.x[6] = 100;
    _ = m.code(0x10000, &.{ addi(5, 5, 1), jal(0, 8), ecall, addi(7, 7, 1), branch(1, 5, 6, -16), ecall });
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
    try t.expectEqual(@as(u64, 100), m.regs.x[7]);
    if (jit_on) try t.expect(jitStat(&m, "compiles") > jitStat(&m, "frees"));
    try checkJitSlots(&m);
    m.cpu.resetCache();
    if (jit_on) {
        try t.expectEqual(jitStat(&m, "compiles"), jitStat(&m, "frees"));
        for (m.cpu.priv.jit.owner) |o| try t.expectEqual(@as(u32, 0), o);
        for (&m.cpu.priv.blocks) |*b| try t.expectEqual(@as(u32, 0), jit.slotOf(b));
    }
    // and everything recompiles and runs
    const c = jitStat(&m, "compiles");
    m.regs.x[5] = 0;
    m.regs.x[7] = 0;
    m.regs.pc = 0x10000;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
    try t.expectEqual(@as(u64, 100), m.regs.x[7]);
    if (jit_on) try t.expect(jitStat(&m, "compiles") > c);
    try checkJitSlots(&m);
}

test "kwemu jit: more hot blocks than pool slots: clock eviction stays consistent" {
    var m = try Machine.init();
    defer m.deinit();
    if (jit_on) m.cpu.priv.jit.region_max = 1; // one block per pool entry (regions: see below)
    // 1100 callees `addi x5,x5,1; jalr x0,0(x1)` at 0x100000 (3 pages), called
    // in turn by `D: jalr x1,0(x6); addi x6,x6,8; bne x6,x7,D; ecall`.
    const ncallee = 1100;
    var words: [3 * 1024]u32 = undefined;
    for (0..ncallee) |i| {
        words[2 * i] = addi(5, 5, 1);
        words[2 * i + 1] = itype(0x67, 0, 0, 1, 0);
    }
    for (0..3) |p| {
        const pa = m.frame();
        putCode(&m, pa, 0, words[p * 1024 ..][0..1024]);
        m.map(0x100000 + p * 4096, pa, R | X | U | A);
    }
    _ = m.code(0x10000, &.{ itype(0x67, 0, 1, 6, 0), addi(6, 6, 8), branch(1, 6, 7, -8), ecall });
    for (0..3) |pass| {
        m.regs.x[5] = 0;
        m.regs.x[6] = 0x100000;
        m.regs.x[7] = 0x100000 + 8 * ncallee;
        m.regs.pc = 0x10000;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(@as(u64, ncallee), m.regs.x[5]);
        try checkJitSlots(&m);
        _ = pass;
    }
    if (jit_on) {
        try t.expect(jitStat(&m, "evictions") > 0);
        try t.expect(jitStat(&m, "compiles") > jit.npool);
    }
}

// ---- JIT tier: F/D ------------------------------------------------------------------
//
// Every FP form the JIT translates (both formats, static RNE and dynamic
// rounding), and forms/modes it must hand back, run over edge-case operands
// by the interpreter and then by the JIT (eager); results and the accrued
// flags of every single operation must match bit for bit. Natively both runs
// are the interpreter, and the RNE arithmetic is also checked against host
// float operations.

const kw_options = @import("kwemu_options");

fn fpR(funct5: u32, fmt: u32, rm: u32, rd: u32, rs1: u32, rs2: u32) u32 {
    return rtype(0x53, rm, (funct5 << 2) | fmt, rd, rs1, rs2);
}
fn fpR4(opc: u32, fmt: u32, rm: u32, rd: u32, rs1: u32, rs2: u32, rs3: u32) u32 {
    return (rs3 << 27) | (fmt << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | opc;
}
fn fld(rd: u32, rs1: u32, imm: i32) u32 {
    return itype(0x07, 3, rd, rs1, imm);
}
fn flw(rd: u32, rs1: u32, imm: i32) u32 {
    return itype(0x07, 2, rd, rs1, imm);
}
fn fsd(rs2: u32, rs1: u32, imm: i32) u32 {
    return store(3, rs2, rs1, imm) ^ 0x23 ^ 0x27;
}
fn fsw(rs2: u32, rs1: u32, imm: i32) u32 {
    return store(2, rs2, rs1, imm) ^ 0x23 ^ 0x27;
}
/// csrrw x6, fflags, x0: read the accrued flags and clear them.
const read_clear_flags = itype(0x73, 1, 6, 0, 1);

fn boxS(v: u32) u64 {
    return 0xffff_ffff_0000_0000 | @as(u64, v);
}
fn bitsD(v: f64) u64 {
    return @bitCast(v);
}
fn bitsS(v: f32) u32 {
    return @bitCast(v);
}

const FpOp = struct {
    name: []const u8,
    /// Reads f1, f2, f3 (or x5), writes f4 (or x7).
    insn: u32,
    /// The operands' format (the source format for conversions).
    single: bool,
    arity: u8 = 2,
    x_in: bool = false,
    x_out: bool = false,
    /// frm while it runs.
    frm: u32 = 0,
};

const FpOps = struct {
    buf: [384]FpOp = undefined,
    n: usize = 0,
    fn add(l: *FpOps, o: FpOp) void {
        l.buf[l.n] = o;
        l.n += 1;
    }
    fn slice(l: *const FpOps) []const FpOp {
        return l.buf[0..l.n];
    }
};

/// The FP forms the JIT translates; with `other_rm` also the rounding modes
/// it hands back (static non-RNE, dynamic with frm != RNE).
fn fpOps(other_rm: bool) FpOps {
    var l: FpOps = .{};
    for (0..2) |fi| {
        const fmt: u32 = @intCast(fi);
        const s = fmt == 0;
        for ([_][]const u8{ "fadd", "fsub", "fmul", "fdiv" }, 0..) |nm, f5| {
            for ([_]u32{ 0, 7 }) |rm| l.add(.{ .name = nm, .insn = fpR(@intCast(f5), fmt, rm, 4, 1, 2), .single = s });
            if (other_rm) {
                for (1..5) |rm| l.add(.{ .name = nm, .insn = fpR(@intCast(f5), fmt, @intCast(rm), 4, 1, 2), .single = s });
                for (1..5) |frm| l.add(.{ .name = nm, .insn = fpR(@intCast(f5), fmt, 7, 4, 1, 2), .single = s, .frm = @intCast(frm) });
            }
        }
        for ([_]u32{ 0x43, 0x47, 0x4b, 0x4f }, [_][]const u8{ "fmadd", "fmsub", "fnmsub", "fnmadd" }) |opc, nm| {
            l.add(.{ .name = nm, .insn = fpR4(opc, fmt, 0, 4, 1, 2, 3), .single = s, .arity = 3 });
            l.add(.{ .name = nm, .insn = fpR4(opc, fmt, 7, 4, 1, 2, 3), .single = s, .arity = 3 });
            if (other_rm) {
                l.add(.{ .name = nm, .insn = fpR4(opc, fmt, 2, 4, 1, 2, 3), .single = s, .arity = 3 });
                l.add(.{ .name = nm, .insn = fpR4(opc, fmt, 7, 4, 1, 2, 3), .single = s, .arity = 3, .frm = 1 });
            }
        }
        for (0..3) |f3| l.add(.{ .name = "fsgnj", .insn = fpR(4, fmt, @intCast(f3), 4, 1, 2), .single = s });
        for (0..3) |f3| l.add(.{ .name = "fcmp", .insn = fpR(0x14, fmt, @intCast(f3), 7, 1, 2), .single = s, .x_out = true });
        for (0..2) |f3| l.add(.{ .name = "fminmax", .insn = fpR(5, fmt, @intCast(f3), 4, 1, 2), .single = s });
        for ([_]u32{ 0, 7 }) |rm| l.add(.{ .name = "fsqrt", .insn = fpR(0x0b, fmt, rm, 4, 1, 0), .single = s, .arity = 1 });
        if (other_rm) {
            l.add(.{ .name = "fsqrt", .insn = fpR(0x0b, fmt, 3, 4, 1, 0), .single = s, .arity = 1 });
            l.add(.{ .name = "fsqrt", .insn = fpR(0x0b, fmt, 7, 4, 1, 0), .single = s, .arity = 1, .frm = 2 });
        }
        // fcvt.s.d (source double) / fcvt.d.s (source single)
        for ([_]u32{ 0, 7 }) |rm| l.add(.{ .name = "fcvt.fmt.fmt", .insn = fpR(8, fmt, rm, 4, 1, if (s) 1 else 0), .single = !s, .arity = 1 });
        if (other_rm) {
            l.add(.{ .name = "fcvt.fmt.fmt", .insn = fpR(8, fmt, 1, 4, 1, if (s) 1 else 0), .single = !s, .arity = 1 });
            l.add(.{ .name = "fcvt.fmt.fmt", .insn = fpR(8, fmt, 7, 4, 1, if (s) 1 else 0), .single = !s, .arity = 1, .frm = 3 });
        }
        // fcvt.{w,wu,l,lu}.fmt: every static mode (RMM is handed back) and dynamic
        for (0..4) |rs2| {
            for ([_]u32{ 0, 1, 2, 3, 4, 7 }) |rm| l.add(.{ .name = "fcvt.x.fmt", .insn = fpR(0x18, fmt, rm, 7, 1, @intCast(rs2)), .single = s, .arity = 1, .x_out = true });
            if (other_rm) l.add(.{ .name = "fcvt.x.fmt", .insn = fpR(0x18, fmt, 7, 7, 1, @intCast(rs2)), .single = s, .arity = 1, .x_out = true, .frm = 1 });
        }
        // fcvt.fmt.{w,wu,l,lu}
        for (0..4) |rs2| {
            for ([_]u32{ 0, 1, 7 }) |rm| l.add(.{ .name = "fcvt.fmt.x", .insn = fpR(0x1a, fmt, rm, 4, 5, @intCast(rs2)), .single = s, .arity = 0, .x_in = true });
            if (other_rm) l.add(.{ .name = "fcvt.fmt.x", .insn = fpR(0x1a, fmt, 7, 4, 5, @intCast(rs2)), .single = s, .arity = 0, .x_in = true, .frm = 2 });
        }
        l.add(.{ .name = "fmv.x.fmt", .insn = fpR(0x1c, fmt, 0, 7, 1, 0), .single = s, .arity = 1, .x_out = true });
        l.add(.{ .name = "fmv.fmt.x", .insn = fpR(0x1e, fmt, 0, 4, 5, 0), .single = s, .arity = 0, .x_in = true });
        l.add(.{ .name = "fclass", .insn = fpR(0x1c, fmt, 1, 7, 1, 0), .single = s, .arity = 1, .x_out = true });
        // Zfa: fminm/fmaxm, fleq/fltq, fround/froundnx (RMM is handed back), fli, fcvtmod.w.d
        for (2..4) |f3| l.add(.{ .name = "fminmax.m", .insn = fpR(5, fmt, @intCast(f3), 4, 1, 2), .single = s });
        for (4..6) |f3| l.add(.{ .name = "fcmp.q", .insn = fpR(0x14, fmt, @intCast(f3), 7, 1, 2), .single = s, .x_out = true });
        for ([_]u32{ 4, 5 }) |rs2| {
            for ([_]u32{ 0, 1, 2, 3, 4, 7 }) |rm| l.add(.{ .name = "fround", .insn = fpR(8, fmt, rm, 4, 1, rs2), .single = s, .arity = 1 });
            if (other_rm) for (1..5) |frm| l.add(.{ .name = "fround", .insn = fpR(8, fmt, 7, 4, 1, rs2), .single = s, .arity = 1, .frm = @intCast(frm) });
        }
        for ([_]u32{ 0, 1, 2, 9, 16, 29, 30, 31 }) |idx| l.add(.{ .name = "fli", .insn = fpR(0x1e, fmt, 0, 4, idx, 1), .single = s, .arity = 1 });
        if (!s) l.add(.{ .name = "fcvtmod.w.d", .insn = fpR(0x18, 1, 1, 7, 1, 8), .single = false, .arity = 1, .x_out = true });
    }
    return l;
}

const d_edges = [_]u64{
    0,                     1 << 63,               0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, // ±0, ±inf
    0x7ff8_0000_0000_0000, 0x7ff8_0000_0000_1234, 0xfff8_0000_0000_5678, 0x7fff_ffff_ffff_ffff, // qNaNs
    0x7ff0_0000_0000_0001, 0x7ff4_0000_0000_0000, 0xfff0_0000_0000_00ff, // sNaNs
    1,                     0x8000_0000_0000_0001, 0x000f_ffff_ffff_ffff, 0x0008_0000_0000_0000, // subnormals
    0x0010_0000_0000_0000, 0x8010_0000_0000_0000, 0x0010_0000_0000_0001, 0x0020_0000_0000_0000, // smallest normals
    0x7fef_ffff_ffff_ffff, 0xffef_ffff_ffff_ffff, 0x7fe0_0000_0000_0000, 0x7fd0_0000_0000_0001, // largest
    bitsD(1.0),            bitsD(-1.0),           bitsD(2.0),            bitsD(3.0),
    bitsD(0.5),            bitsD(-0.5),           bitsD(1.0 / 3.0),      bitsD(0.1),
    0x3ff0_0000_0000_0001, 0x3fef_ffff_ffff_ffff, bitsD(1e300),          bitsD(-1e-300),
    bitsD(2.5),            bitsD(-2.5),           bitsD(1.5),            bitsD(-0.4),
    bitsD(0x1p63),         bitsD(-0x1p63),        bitsD(0x1p64),         bitsD(0x1p31),
    bitsD(-0x1p31),        bitsD(4294967295.5),   bitsD(0x1p53 + 2.0),   bitsD(-2147483648.5),
    bitsD(9.2233720368547748e18), bitsD(4503599761588225.0), // (2^26 + 1)^2: exact root with 27 bits
};

const s_edges = [_]u32{
    0,             0x8000_0000,    0x7f80_0000,                0xff80_0000, // ±0, ±inf
    0x7fc0_0000,   0x7fc0_1234,    0xffc0_0000,                0x7fff_ffff, // qNaNs
    0x7f80_0001,   0x7fa0_0000,    0xff80_00ff, // sNaNs
    1,             0x8000_0001,    0x007f_ffff,                0x0040_0000, // subnormals
    0x0080_0000,   0x8080_0000,    0x0080_0001,                0x0100_0000, // smallest normals
    0x7f7f_ffff,   0xff7f_ffff,    0x7f00_0000,                0x7e80_0001, // largest
    bitsS(1.0),    bitsS(-1.0),    bitsS(2.0),                 bitsS(3.0),
    bitsS(0.5),    bitsS(-0.5),    bitsS(@as(f32, 1.0) / 3.0), bitsS(0.1),
    0x3f80_0001,   0x3f7f_ffff,    bitsS(1e30),                bitsS(-1e-30),
    bitsS(2.5),    bitsS(-2.5),    bitsS(1.5),                 bitsS(-0.4),
    bitsS(0x1p63), bitsS(-0x1p63), bitsS(0x1p64),              bitsS(0x1p31),
    bitsS(-0x1p31), bitsS(0x1p24 + 2.0), bitsS(16777215.0),     bitsS(-0.75),
    bitsS(4198401.0), // (2^11 + 1)^2: exact root with 12 bits
};

/// Register values that are not NaN-boxed singles (read as the canonical NaN).
const s_unboxed = [_]u64{ 0x0000_0000_3f80_0000, 0x7fff_ffff_3f80_0000, 0xffff_fffe_4000_0000, 0, 0x3ff0_0000_0000_0000 };

const i_edges = [_]u64{
    0,                     1,                     2,                     3,
    0xffff_ffff_ffff_ffff, 0xffff_ffff_ffff_fffd, 0x7fff_ffff,           0x8000_0000,
    0xffff_ffff_8000_0000, 0xffff_ffff,           0x1_0000_0000,         0x1_0000_0001,
    (1 << 24) + 1,         (1 << 24) + 2,         (1 << 25) + 1,         0xffff_ffff_ff00_0001,
    (1 << 53) + 1,         (1 << 53) + 2,         (1 << 54) + 2,         0x7fff_ffff_ffff_ffff,
    1 << 63,               0x8000_0000_0000_0001, 0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210,
    0x0000_0000_7fff_ff80, 0xffff_ffff_ffff_fc00,
};

/// The value list for an op's operands.
fn fpValues(buf: []u64, single: bool) []u64 {
    var n: usize = 0;
    if (single) {
        for (s_edges) |v| {
            buf[n] = boxS(v);
            n += 1;
        }
        for (s_unboxed) |v| {
            buf[n] = v;
            n += 1;
        }
    } else {
        for (d_edges) |v| {
            buf[n] = v;
            n += 1;
        }
    }
    return buf[0..n];
}

const in_va: u64 = 0x200000;
const out_va: u64 = 0x800000;
const fp_code_va: u64 = 0x10000;

/// A machine with `cap` input slots (a, b, c: 24 bytes) at in_va and
/// output slots (result, flags: 16 bytes) at out_va, running the loop
///   L: fld f1,0(x10); fld f2,8(x10); fld f3,16(x10); ld x5,0(x10); OP;
///      fsd f4,0(x12) | sd x7,0(x12); csrrw x6,fflags,x0; sd x6,8(x12);
///      x10 += 24; x12 += 16; bne x10,x11,L; ecall
/// The compiled part of each pass ends at the csrrw (a CSR op is handed
/// back), so the FP op itself is compiled; the interpreter clears the flags.
const FpRig = struct {
    m: Machine,
    in: []u8,
    out: []u8,
    code_pa: u64,
    cap: usize,
    /// The loaded loop reads and clears the flags after each operation.
    per_op_flags: bool = true,

    fn init(cap: usize) !FpRig {
        const in_pages = (cap * 24 + 4095) / 4096;
        const out_pages = (cap * 16 + 4095) / 4096;
        var m = try Machine.initSize((in_pages + out_pages + 64) * 4096);
        const in = mapData(&m, in_va, in_pages);
        const out = mapData(&m, out_va, out_pages);
        const code_pa = m.frame();
        m.map(fp_code_va, code_pa, R | X | U | A);
        return .{ .m = m, .in = in, .out = out, .code_pa = code_pa, .cap = cap };
    }
    fn deinit(rg: *FpRig) void {
        rg.m.deinit();
    }
    fn load(rg: *FpRig, o: FpOp) void {
        putCode(&rg.m, rg.code_pa, 0, &.{
            fld(1, 10, 0),    fld(2, 10, 8),                                fld(3, 10, 16),         ld(5, 10, 0),
            o.insn,           if (o.x_out) sd(7, 12, 0) else fsd(4, 12, 0), read_clear_flags,       sd(6, 12, 8),
            addi(10, 10, 24), addi(12, 12, 16),                             branch(1, 10, 11, -40), ecall,
        });
        rg.m.cpu.flushRange(fp_code_va, fp_code_va + 4096); // the kernel rewrote the page
        rg.per_op_flags = true;
    }
    /// The same loop without the flags read (no CSR op): a block the JIT
    /// compiles entirely, so it hands back only if the FP op does.
    fn loadNoFlags(rg: *FpRig, o: FpOp) void {
        putCode(&rg.m, rg.code_pa, 0, &.{
            fld(1, 10, 0),    fld(2, 10, 8),                                fld(3, 10, 16),         ld(5, 10, 0),
            o.insn,           if (o.x_out) sd(7, 12, 0) else fsd(4, 12, 0), addi(10, 10, 24),       addi(12, 12, 16),
            branch(1, 10, 11, -32), ecall,
        });
        rg.m.cpu.flushRange(fp_code_va, fp_code_va + 4096);
        rg.per_op_flags = false;
    }
    fn set(rg: *FpRig, i: usize, a: u64, b: u64, c: u64) void {
        for ([_]u64{ a, b, c }, 0..) |v, j| std.mem.writeInt(u64, rg.in[i * 24 + j * 8 ..][0..8], v, .little);
    }
    fn get(rg: *FpRig, i: usize, j: usize) u64 {
        return std.mem.readInt(u64, rg.in[i * 24 + j * 8 ..][0..8], .little);
    }
    fn result(rg: *FpRig, i: usize) [2]u64 {
        return .{ std.mem.readInt(u64, rg.out[i * 16 ..][0..8], .little), std.mem.readInt(u64, rg.out[i * 16 + 8 ..][0..8], .little) };
    }
    /// Run the loaded op over cases 0..n with policy `mode`.
    fn run(rg: *FpRig, o: FpOp, n: usize, mode: JitMode) !void {
        jitMode(&rg.m, mode, 0);
        rg.m.regs.x[10] = in_va;
        rg.m.regs.x[11] = in_va + n * 24;
        rg.m.regs.x[12] = out_va;
        rg.m.regs.f[4] = 0x5555_5555_5555_5555;
        rg.m.regs.x[7] = 0x5555_5555_5555_5555;
        rg.m.regs.fcsr = o.frm << 5;
        rg.m.regs.pc = fp_code_va;
        try t.expectEqual(@as(u32, EV_SYSCALL), rg.m.run(1 << 40));
        if (rg.per_op_flags) try t.expectEqual(o.frm << 5, rg.m.regs.fcsr);
    }
};

fn mapData(m: *Machine, va: u64, npages: usize) []u8 {
    const pa = m.frame();
    for (1..npages) |_| _ = m.frame();
    for (0..npages) |i| m.map(va + i * 4096, pa + i * 4096, R | W | U | A | D);
    return m.mem[@intCast(pa - pa_base)..][0 .. npages * 4096];
}

/// Fill the rig with the edge-case operand sets of op o; returns the count.
fn fpEdgeCases(rg: *FpRig, o: FpOp) usize {
    var vb: [64]u64 = undefined;
    const vals = fpValues(&vb, o.single);
    var n: usize = 0;
    if (o.x_in) {
        for (i_edges) |a| {
            rg.set(n, a, 0, 0);
            n += 1;
        }
        // and the FP edge bit patterns as integers
        for (vals) |a| {
            rg.set(n, a, 0, 0);
            n += 1;
        }
        return n;
    }
    switch (o.arity) {
        1 => for (vals) |a| {
            rg.set(n, a, 0, 0);
            n += 1;
        },
        2 => for (vals) |a| for (vals) |b| {
            rg.set(n, a, b, 0);
            n += 1;
        },
        else => for (vals) |a| for (vals) |b| for ([_]usize{ 0, 1, 3, 4, 8, 12, 15, 19, 23, 26, 30, 36 }) |ci| {
            rg.set(n, a, b, vals[ci]);
            n += 1;
        },
    }
    return n;
}

/// Compare an interpreter run (saved in `want`) with the rig's outputs.
fn fpCompare(rg: *FpRig, o: FpOp, n: usize, want: []const [2]u64) !void {
    for (0..n) |i| {
        const got = rg.result(i);
        if (got[0] != want[i][0] or got[1] != want[i][1]) {
            std.debug.print("{s} insn 0x{x:0>8} frm {d} case {d}: a=0x{x} b=0x{x} c=0x{x}: jit 0x{x} flags 0x{x}, interpreter 0x{x} flags 0x{x}\n", .{
                o.name, o.insn, o.frm, i, rg.get(i, 0), rg.get(i, 1), rg.get(i, 2), got[0], got[1], want[i][0], want[i][1],
            });
            return error.TestUnexpectedResult;
        }
    }
}

/// Native sanity check of the rig itself: RNE arithmetic against host float
/// operations (non-NaN results), NaN results canonical.
fn fpHostCheck(rg: *FpRig, o: FpOp, n: usize) !void {
    if (o.x_in or o.x_out or o.frm != 0) return;
    const rm = (o.insn >> 12) & 7;
    if (rm != 0 and rm != 7) return;
    const f5 = o.insn >> 27;
    const opc = o.insn & 0x7f;
    const fma = opc != 0x53;
    if (!fma and f5 > 3 and f5 != 0x0b) return;
    // FMA only natively (hardware FMA): in wasm builds @mulAdd is
    // compiler-rt, which gets e.g. fmaf(0x7e800001, 3.0, -0x1p-149) =
    // 0x7f400002 (double rounding; correct: 0x7f400001) and
    // fma(0x1p-1074, 0x1p-1074, -0x1p-1074) = NaN (correct: -0x1p-1074) wrong
    if (fma and @import("builtin").cpu.arch.isWasm()) return;
    for (0..n) |i| {
        const got = rg.result(i)[0];
        if (o.single) {
            const un = struct {
                fn f(v: u64) f32 {
                    return @bitCast(if (v >> 32 == 0xffff_ffff) @as(u32, @truncate(v)) else 0x7fc0_0000);
                }
            }.f;
            const a = un(rg.get(i, 0));
            const b = un(rg.get(i, 1));
            const c = un(rg.get(i, 2));
            const want: f32 = if (fma) switch (opc) {
                0x43 => @mulAdd(f32, a, b, c),
                0x47 => @mulAdd(f32, a, b, -c),
                0x4b => @mulAdd(f32, -a, b, c),
                else => @mulAdd(f32, -a, b, -c),
            } else switch (f5) {
                0 => a + b,
                1 => a - b,
                2 => a * b,
                3 => a / b,
                else => @sqrt(a),
            };
            const wb: u64 = boxS(if (std.math.isNan(want)) 0x7fc0_0000 else bitsS(want));
            if (got != wb) {
                std.debug.print("host check {s} 0x{x:0>8} case {d}: got 0x{x} want 0x{x}\n", .{ o.name, o.insn, i, got, wb });
                return error.TestUnexpectedResult;
            }
        } else {
            const a: f64 = @bitCast(rg.get(i, 0));
            const b: f64 = @bitCast(rg.get(i, 1));
            const c: f64 = @bitCast(rg.get(i, 2));
            const want: f64 = if (fma) switch (opc) {
                0x43 => @mulAdd(f64, a, b, c),
                0x47 => @mulAdd(f64, a, b, -c),
                0x4b => @mulAdd(f64, -a, b, c),
                else => @mulAdd(f64, -a, b, -c),
            } else switch (f5) {
                0 => a + b,
                1 => a - b,
                2 => a * b,
                3 => a / b,
                else => @sqrt(a),
            };
            const wb: u64 = if (std.math.isNan(want)) 0x7ff8_0000_0000_0000 else bitsD(want);
            if (got != wb) {
                std.debug.print("host check {s} 0x{x:0>8} case {d}: got 0x{x} want 0x{x}\n", .{ o.name, o.insn, i, got, wb });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "kwemu jit: F/D ops on edge-case operands, all rounding modes (JIT vs interpreter, results and flags)" {
    const cap = 64 * 64 * 12;
    var rg = try FpRig.init(cap);
    defer rg.deinit();
    const want = try alloc.alloc([2]u64, cap);
    defer alloc.free(want);
    const ops = fpOps(true);
    var total: usize = 0;
    for (ops.slice()) |o| {
        rg.load(o);
        const n = fpEdgeCases(&rg, o);
        try rg.run(o, n, .off);
        for (0..n) |i| want[i] = rg.result(i);
        try fpHostCheck(&rg, o, n);
        @memset(rg.out, 0xee);
        try rg.run(o, n, .eager);
        try fpCompare(&rg, o, n, want);
        total += n;
    }
    try t.expect(total > 1_000_000);
    if (jit_on) {
        try t.expect(jitStat(&rg.m, "compiles") >= ops.n);
        try t.expectEqual(@as(u64, 0), jitStat(&rg.m, "fails"));
        std.debug.print("[jit] F/D edge cases: {d} forms, {d} operations: no difference\n", .{ ops.n, total });
    }
    try checkJitSlots(&rg.m);
}

test "kwemu jit: F/D ops on normal operands run compiled (no hand-back at the FP op)" {
    var rg = try FpRig.init(4096);
    defer rg.deinit();
    // (doubles also 2^31 - 1: the largest fcvt.w result is still compiled)
    const dv = [_]f64{ 1.5, 2.25, 3.0, 0.1, 1.0 / 3.0, 1000.5, 7.75, 1e-3, 2147483647.0 };
    const ops = fpOps(false);
    var checked: usize = 0;
    for (ops.slice()) |o| {
        // ops whose results stay normal and in range for these operands
        const f5 = o.insn >> 27;
        const opc = o.insn & 0x7f;
        const rm = (o.insn >> 12) & 7;
        if (opc == 0x53 and f5 == 1) continue; // fsub: a - a = 0
        if (opc == 0x47 or opc == 0x4b) continue; // fmsub/fnmsub: may cancel
        if (opc == 0x53 and (f5 == 0x18 or f5 == 8) and rm == 4) continue; // RMM: handed back
        if (opc == 0x53 and f5 == 0x18 and (o.insn >> 20) & 31 == 8) continue; // fcvtmod.w.d: generic
        if (o.x_in) continue;
        rg.loadNoFlags(o);
        var n: usize = 0;
        for (dv[0 .. dv.len - @intFromBool(o.single)]) |a| for (dv[0 .. dv.len - @intFromBool(o.single)]) |b| for ([_]f64{ 0.75, 3.5 }) |c| {
            const enc = struct {
                fn f(v: f64, single: bool) u64 {
                    return if (single) boxS(bitsS(@floatCast(v))) else bitsD(v);
                }
            }.f;
            rg.set(n, enc(a, o.single), enc(b, o.single), enc(c, o.single));
            n += 1;
        };
        try rg.run(o, n, .off);
        const want = try alloc.alloc([2]u64, n);
        defer alloc.free(want);
        for (0..n) |i| want[i] = rg.result(i);
        const hb0 = jitStat(&rg.m, "handbacks");
        try rg.run(o, n, .eager);
        try fpCompare(&rg, o, n, want);
        // the whole loop is compiled: any hand-back is the FP op's
        if (jit_on) {
            const hb = jitStat(&rg.m, "handbacks") - hb0;
            if (hb != 0) {
                std.debug.print("{s} 0x{x:0>8}: {d} hand-backs for {d} passes\n", .{ o.name, o.insn, hb, n });
                return error.TestUnexpectedResult;
            }
        }
        checked += 1;
    }
    try t.expect(checked > 60);
}

test "kwemu jit: accrued flags are sticky across a compiled self-loop; frm is kept" {
    var m = try Machine.init();
    defer m.deinit();
    const n = 1000;
    for ([_]JitMode{ .off, .eager }) |mode| {
        jitMode(&m, mode, 0);
        // L: fdiv.d f3,f1,f2 (NX); fmul.d f4,f5,f6 (exact); flt.d x7,f1,f8 (NV:
        //    f8 is a qNaN); fadd.d f9,f9,f5 (exact); addi x5,x5,-1; bne x5,x0,L
        _ = m.code(0x10000, &.{
            fpR(3, 1, 0, 3, 1, 2), fpR(2, 1, 0, 4, 5, 6), fpR(0x14, 1, 1, 7, 1, 8), fpR(0, 1, 0, 9, 9, 5),
            addi(5, 5, -1),        branch(1, 5, 0, -20),  ecall,
        });
        m.regs.f[1] = bitsD(1.0);
        m.regs.f[2] = bitsD(3.0);
        m.regs.f[5] = bitsD(2.0);
        m.regs.f[6] = bitsD(0.5);
        m.regs.f[8] = 0x7ff8_0000_0000_0000;
        m.regs.f[9] = 0;
        m.regs.x[5] = n;
        // frm = RUP with static-RNE ops: compiled, and frm must survive the
        // write-back; DZ was raised before
        m.regs.fcsr = (3 << 5) | 0x08;
        const ic = m.cpu.icount;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(@as(u32, (3 << 5) | 0x08 | 0x10 | 0x01), m.regs.fcsr);
        try t.expectEqual(bitsD(1.0 / 3.0), m.regs.f[3]);
        try t.expectEqual(bitsD(1.0), m.regs.f[4]);
        try t.expectEqual(bitsD(2.0 * n), m.regs.f[9]);
        try t.expectEqual(@as(u64, 0), m.regs.x[7]);
        try t.expectEqual(@as(u64, n * 6 + 1), m.cpu.icount - ic);
        // only exact ops: no new flags
        _ = m.code(0x20000, &.{ fpR(2, 1, 0, 4, 5, 6), fpR(0, 1, 0, 9, 9, 5), addi(5, 5, -1), branch(1, 5, 0, -12), ecall });
        m.regs.x[5] = n;
        m.regs.fcsr = 0;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(@as(u32, 0), m.regs.fcsr);
    }
    if (jit_on) try t.expect(jitStat(&m, "compiles") >= 2);
    try checkJitSlots(&m);
}

test "kwemu jit: dynamic rounding with an illegal frm traps at the FP op" {
    var m = try Machine.init();
    defer m.deinit();
    for ([_]JitMode{ .off, .eager }) |mode| {
        for ([_]u32{ 5, 6, 7 }) |frm| {
            jitMode(&m, mode, 0);
            // addi x5,x5,1; fadd.d f3,f1,f2 (dynamic); ecall
            _ = m.code(0x10000, &.{ addi(5, 5, 1), fpR(0, 1, 7, 3, 1, 2), ecall });
            m.regs.x[5] = 0;
            m.regs.fcsr = frm << 5;
            const ic = m.cpu.icount;
            try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(100));
            try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
            try t.expectEqual(@as(u64, 1), m.regs.x[5]);
            try t.expectEqual(@as(u64, 1), m.cpu.icount - ic);
            try t.expectEqual(@as(u64, fpR(0, 1, 7, 3, 1, 2)), m.cpu.ev.insn);
        }
    }
    try checkJitSlots(&m);
}

test "kwemu jit: FP loads/stores: NaN-boxing, TLB miss, page straddle, fault with exact pc" {
    var m = try Machine.init();
    defer m.deinit();
    const data = m.frame();
    const page1 = m.frame();
    const s0 = m.frame();
    const s1 = m.frame();
    const s2 = m.frame();
    for ([_]JitMode{ .off, .eager }) |mode| {
        jitMode(&m, mode, 0);
        m.map(0x90000, data, R | W | U | A | D);
        m.slot(0x91000).* = 0; // 0x91000 unmapped for now
        m.cpu.flushAll();
        @memset(m.bytes(data), 0);
        @memset(m.bytes(page1), 0);
        std.mem.writeInt(u64, m.bytes(data)[0..8], bitsD(1.5), .little);
        std.mem.writeInt(u32, m.bytes(data)[16..20], bitsS(2.5), .little);
        std.mem.writeInt(u64, m.bytes(data)[0xfd8..0xfe0], bitsD(3.25), .little);
        // L: flw f2,16(x8); fld f1,0(x8); fadd.d f3,f3,f1; fsw f2,24(x8);
        //    fsd f3,8(x8); fld f4,0(x9); fsd f4,8(x9); addi x9,x9,8;
        //    addi x5,x5,-1; bne x5,x0,L; ecall
        // x9 walks from 0x90fd8 (3.25, copied forward each pass) into the
        // unmapped page, where a store faults first
        _ = m.code(0x10000, &.{
            flw(2, 8, 16),  fld(1, 8, 0),         fpR(0, 1, 0, 3, 3, 1), fsw(2, 8, 24),
            fsd(3, 8, 8),   fld(4, 9, 0),         fsd(4, 9, 8),          addi(9, 9, 8),
            addi(5, 5, -1), branch(1, 5, 0, -36), ecall,
        });
        m.regs.x[8] = 0x90000;
        m.regs.x[9] = 0x90fd8;
        m.regs.x[5] = 10;
        m.regs.f[3] = 0;
        const ic = m.cpu.icount;
        try t.expectEqual(@as(u32, EV_FAULT), m.run(1 << 20));
        // passes 0..3 (x9 = 0x90fd8..0x90ff0) complete; pass 4's fsd at
        // 0x91000 faults: pc on it, 4 passes + 6 instructions retired
        try t.expectEqual(@as(u64, 0x10018), m.regs.pc);
        try t.expectEqual(@as(u64, 0x91000), m.cpu.ev.addr);
        try t.expectEqual(@as(u64, 4 * 10 + 6), m.cpu.icount - ic);
        try t.expectEqual(@as(u64, 0x90ff8), m.regs.x[9]);
        try t.expectEqual(boxS(bitsS(2.5)), m.regs.f[2]);
        try t.expectEqual(bitsD(1.5 * 5), m.regs.f[3]);
        try t.expectEqual(bitsD(3.25), m.regs.f[4]);
        m.map(0x91000, page1, R | W | U | A | D);
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(bitsD(1.5 * 10), m.regs.f[3]);
        try t.expectEqual(bitsD(1.5 * 10), std.mem.readInt(u64, m.bytes(data)[8..16], .little));
        try t.expectEqual(bitsS(2.5), std.mem.readInt(u32, m.bytes(data)[24..28], .little));
        for (0..6) |i| try t.expectEqual(bitsD(3.25), std.mem.readInt(u64, m.bytes(page1)[i * 8 ..][0..8], .little));
        try t.expectEqual(@as(u64, 0), std.mem.readInt(u64, m.bytes(page1)[48..56], .little));
        try t.expectEqual(@as(u64, 10 * 10 + 1), m.cpu.icount - ic);
        // page-straddling accesses (all pages mapped) are handed back to the
        // interpreter, every pass:
        // L: fld f1,0(x10); fadd.d f1,f1,f5; fsd f1,0(x10) (8 bytes over
        //    0xa0ffc..0xa1003); fsw f6,0(x11); flw f2,0(x11) (4 bytes over
        //    0xa1ffe..0xa2001); addi x5,x5,-1; bne x5,x0,L; ecall
        for ([_]u64{ s0, s1, s2 }, 0..) |pa, i| {
            m.map(0xa0000 + i * 4096, pa, R | W | U | A | D);
            @memset(m.bytes(pa), 0);
        }
        _ = m.code(0x20000, &.{ fld(1, 10, 0), fpR(0, 1, 0, 1, 1, 5), fsd(1, 10, 0), fsw(6, 11, 0), flw(2, 11, 0), addi(5, 5, -1), branch(1, 5, 0, -24), ecall });
        m.regs.x[10] = 0xa0ffc;
        m.regs.x[11] = 0xa1ffe;
        m.regs.f[5] = bitsD(1.0);
        m.regs.f[6] = boxS(0x4433_2211);
        m.regs.f[2] = 0;
        m.regs.x[5] = 50;
        const ic2 = m.cpu.icount;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(@as(u64, 50 * 7 + 1), m.cpu.icount - ic2);
        var straddle: [8]u8 = undefined;
        @memcpy(straddle[0..4], m.bytes(s0)[0xffc..0x1000]);
        @memcpy(straddle[4..8], m.bytes(s1)[0..4]);
        try t.expectEqual(bitsD(50.0), std.mem.readInt(u64, &straddle, .little));
        try t.expectEqual(bitsD(50.0), m.regs.f[1]);
        try t.expectEqual(boxS(0x4433_2211), m.regs.f[2]);
        try t.expectEqual(@as(u16, 0x2211), std.mem.readInt(u16, m.bytes(s1)[0xffe..0x1000], .little));
        try t.expectEqual(@as(u16, 0x4433), std.mem.readInt(u16, m.bytes(s2)[0..2], .little));
    }
    try checkJitSlots(&m);
}

test "kwemu jit: an FP store into the running compiled block takes effect on the next pass" {
    for ([_]bool{ false, true }) |dbl| {
        var m = try Machine.init();
        defer m.deinit();
        const pa = m.frame();
        m.map(0x10000, pa, RWX);
        const old = addi(10, 0, 1);
        const new = addi(10, 0, 2);
        const add13 = rtype(0x33, 0, 0, 13, 13, 10);
        const n = 300;
        const k = 100;
        m.regs.x[6] = k;
        m.regs.x[7] = n;
        m.regs.x[12] = 0x10000;
        m.regs.x[16] = old ^ new;
        m.regs.x[17] = old;
        m.regs.x[18] = if (dbl) @as(u64, add13) << 32 else 0;
        // L: x5 += 1; addi x10,x0,1 (patched in pass k); x13 += x10;
        //    x14 = ((x5 >= k) ? new : old) | x18; fmv.d.x f8,x14;
        //    fsw f8,4(L) or fsd f8,4(L) (which rewrites `x13 += x10` as it is);
        //    bne x5,x7,L; ecall
        putCode(&m, pa, 0, &.{
            addi(5, 5, 1),                             old,                           add13,
            rtype(0x33, 3, 0, 15, 5, 6),               addi(15, 15, -1),              rtype(0x33, 7, 0, 15, 15, 16),
            rtype(0x33, 4, 0, 14, 15, 17),             rtype(0x33, 6, 0, 14, 14, 18), fpR(0x1e, 1, 0, 8, 14, 0),
            if (dbl) fsd(8, 12, 4) else fsw(8, 12, 4), branch(1, 5, 7, -40),          ecall,
        });
        m.regs.pc = 0x10000;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
        try t.expectEqual(@as(u64, k + 2 * (n - k)), m.regs.x[13]);
        try t.expectEqual(@as(u64, 2), m.regs.x[10]);
        try t.expectEqual(@as(u64, n * 11 + 1), m.cpu.icount);
        try t.expectEqual(new, std.mem.readInt(u32, m.bytes(pa)[4..8], .little));
        try t.expectEqual(add13, std.mem.readInt(u32, m.bytes(pa)[8..12], .little));
        if (jit_on) {
            try t.expect(jitStat(&m, "frees") >= 1);
            try t.expect(jitStat(&m, "compiles") < 10);
        }
        try checkJitSlots(&m);
    }
}

test "kwemu jit: worst-case module size: 63 copies of each FP form in one block" {
    var m = try Machine.initSize(4 << 20);
    defer m.deinit();
    const ops = fpOps(false);
    var words: [64]u32 = undefined;
    var worst: u32 = 0;
    var worst_insn: u32 = 0;
    for (ops.slice(), 0..) |o, i| {
        jitMode(&m, .eager, 0);
        for (words[0..63]) |*w| w.* = o.insn;
        words[63] = jal(0, -63 * 4); // self-loop over all 64 instructions
        const va = 0x100000 + i * 4096;
        _ = m.code(va, &words);
        if (jit_on) m.cpu.priv.jit.max_bytes = 0;
        try t.expectEqual(@as(u32, EV_BUDGET), m.run(64 * 3));
        try t.expectEqual(va, m.regs.pc);
        if (jit_on and m.cpu.priv.jit.max_bytes > worst) {
            worst = m.cpu.priv.jit.max_bytes;
            worst_insn = o.insn;
        }
    }
    // Mixed: the most FMAs that are still inlined (4 x fmadd.d) and 59 x
    // fmin.s, over all 32 FP registers (largest prologue and epilogue).
    jitMode(&m, .eager, 0);
    for (words[0..63], 0..) |*w, i| {
        const r0: u32 = @intCast(i % 32);
        w.* = if (i < 4) fpR4(0x43, 1, 0, r0, (r0 + 1) % 32, (r0 + 2) % 32, (r0 + 3) % 32) else fpR(5, 0, 0, r0, (r0 + 1) % 32, (r0 + 2) % 32);
    }
    words[63] = jal(0, -63 * 4);
    // That one does not fit the emit buffer: it is compiled for a shorter
    // prefix that hands the rest back; results must still be the
    // interpreter's.
    var want_f: [32]u64 = undefined;
    var want_fcsr: u32 = 0;
    var mixed: u32 = 0;
    for ([_]JitMode{ .off, .eager }) |mode| {
        jitMode(&m, mode, 0);
        _ = m.code(0x300000, &words);
        for (&m.regs.f, 0..) |*f, i| f.* = bitsD(@as(f64, @floatFromInt(i)) * 0.37 + 1.25) | (if (i % 3 == 0) @as(u64, 0xffff_ffff_0000_0000) else 0);
        m.regs.fcsr = 0;
        if (jit_on) m.cpu.priv.jit.max_bytes = 0;
        try t.expectEqual(@as(u32, EV_BUDGET), m.run(64 * 3));
        if (mode == .off) {
            want_f = m.regs.f;
            want_fcsr = m.regs.fcsr;
        } else {
            try t.expectEqualSlices(u64, &want_f, &m.regs.f);
            try t.expectEqual(want_fcsr, m.regs.fcsr);
            if (jit_on) mixed = m.cpu.priv.jit.max_bytes;
        }
    }
    if (jit_on) {
        try t.expectEqual(@as(u64, 0), jitStat(&m, "fails"));
        try t.expect(jitStat(&m, "shortened") >= 1);
        // RMM conversions and inexact int->FP conversions with a static
        // directed mode are not compiled (first op unsupported)
        try t.expectEqual(@as(u64, ops.n + 1), jitStat(&m, "compiles") + jitStat(&m, "skips"));
        try t.expect(worst < jit.buf_size and mixed < jit.buf_size);
        std.debug.print("[jit] worst-case FP block: {d}-byte module (63 x 0x{x:0>8}); 4 inline fmadd.d + 59 fmin.s over all FP registers: {d} shortened emit(s), {d} bytes; buffer {d}; @sizeOf(Cpu) = {d} of {d}\n", .{
            worst, worst_insn, jitStat(&m, "shortened"), mixed, jit.buf_size, @sizeOf(Cpu), kwemu.cpu_size,
        });
    }
}

/// A random operand for the fuzz test, biased towards edge cases.
fn fuzzVal(rnd: std.Random, single: bool) u64 {
    const rg = rnd.uintLessThan(u32, 32);
    if (single) {
        const sg: u32 = if (rnd.boolean()) 0x8000_0000 else 0;
        const mant: u32 = switch (rnd.uintLessThan(u32, 4)) {
            0 => rnd.int(u32) & 0x7f_ff00, // short significand
            1 => 0x7f_ffff ^ (rnd.int(u32) & 0xf),
            else => rnd.int(u32) & 0x7f_ffff,
        };
        const v: u32 = switch (rg) {
            0...3 => s_edges[rnd.uintLessThan(usize, s_edges.len)],
            4, 5 => rnd.int(u32),
            6 => sg | rnd.uintLessThan(u32, 3) << 23 | mant, // subnormal / tiny
            7 => sg | (rnd.uintLessThan(u32, 4) + 251) << 23 | mant, // huge
            8 => sg | (rnd.uintLessThan(u32, 2) * 255) << 23 | mant, // NaN/inf/0/subnormal
            9 => sg | (127 + 31 + rnd.uintLessThan(u32, 3) - 1) << 23 | mant, // around 2^31
            10 => sg | (127 + 63 + rnd.uintLessThan(u32, 3) - 1) << 23 | mant, // around 2^63
            11 => sg | (126 + rnd.uintLessThan(u32, 25)) << 23 | mant, // 0.5 .. 2^24
            else => sg | (127 + rnd.uintLessThan(u32, 61) - 30) << 23 | mant,
        };
        if (rnd.uintLessThan(u32, 64) == 0) return s_unboxed[rnd.uintLessThan(usize, s_unboxed.len)] ^ (rnd.int(u64) & 0xffff);
        return boxS(v);
    }
    const sg: u64 = if (rnd.boolean()) 1 << 63 else 0;
    const mant: u64 = switch (rnd.uintLessThan(u32, 4)) {
        0 => rnd.int(u64) & 0x000f_ffff_0000_0000,
        1 => 0x000f_ffff_ffff_ffff ^ (rnd.int(u64) & 0xff),
        else => rnd.int(u64) & 0x000f_ffff_ffff_ffff,
    };
    return switch (rg) {
        0...3 => d_edges[rnd.uintLessThan(usize, d_edges.len)],
        4, 5 => rnd.int(u64),
        6 => sg | rnd.uintLessThan(u64, 3) << 52 | mant,
        7 => sg | (rnd.uintLessThan(u64, 4) + 2043) << 52 | mant,
        8 => sg | (rnd.uintLessThan(u64, 2) * 2047) << 52 | mant,
        9 => sg | (1023 + 31 + rnd.uintLessThan(u64, 3) - 1) << 52 | mant,
        10 => sg | (1023 + 63 + rnd.uintLessThan(u64, 3) - 1) << 52 | mant,
        11 => sg | (1022 + rnd.uintLessThan(u64, 54)) << 52 | mant,
        12 => sg | (1023 + 990 + rnd.uintLessThan(u64, 30)) << 52 | mant, // fma64Fast guard edges
        13 => sg | (20 + rnd.uintLessThan(u64, 30)) << 52 | mant,
        else => sg | (1023 + rnd.uintLessThan(u64, 121) - 60) << 52 | mant,
    };
}

fn fuzzInt(rnd: std.Random) u64 {
    const v = rnd.int(u64) >> @intCast(rnd.uintLessThan(u32, 64));
    return switch (rnd.uintLessThan(u32, 8)) {
        0 => i_edges[rnd.uintLessThan(usize, i_edges.len)],
        1 => 0 -% v,
        2 => v | 1 << 63,
        3 => v & ~@as(u64, 0xff),
        else => v,
    };
}

test "kwemu jit: F/D randomized differential (interpreter vs JIT; -Dkwemu-fp-fuzz=N operand sets per op)" {
    if (!jit_on) return error.SkipZigTest; // natively both runs would be the interpreter
    const per_op: usize = if (kw_options.fp_fuzz != 0) kw_options.fp_fuzz else 4096;
    const chunk = 4096;
    var rg = try FpRig.init(chunk);
    defer rg.deinit();
    const want = try alloc.alloc([2]u64, chunk);
    defer alloc.free(want);
    var prng = std.Random.DefaultPrng.init(0x6b77_656d_7520_6670);
    const rnd = prng.random();
    const ops = fpOps(false);
    for (ops.slice()) |o| {
        rg.load(o);
        var done: usize = 0;
        while (done < per_op) {
            const n = @min(chunk, per_op - done);
            for (0..n) |i| {
                if (o.x_in) {
                    rg.set(i, fuzzInt(rnd), 0, 0);
                    continue;
                }
                const a = fuzzVal(rnd, o.single);
                var b = fuzzVal(rnd, o.single);
                var c = fuzzVal(rnd, o.single);
                switch (rnd.uintLessThan(u32, 8)) {
                    // related operands: near-equal, near-opposite, fma near-
                    // cancellation (c = -(a*b) nudged), tiny addends
                    0 => b = a +% (rnd.uintLessThan(u64, 5) -% 2),
                    1 => b = (a ^ (if (o.single) @as(u64, 1 << 31) else 1 << 63)) +% (rnd.uintLessThan(u64, 5) -% 2),
                    2 => if (o.arity == 3) {
                        if (o.single) {
                            const p: f32 = @as(f32, @bitCast(@as(u32, @truncate(a)))) * @as(f32, @bitCast(@as(u32, @truncate(b))));
                            c = boxS((bitsS(p) ^ 0x8000_0000) +% (rnd.uintLessThan(u32, 5) -% 2));
                        } else {
                            const p = @as(f64, @bitCast(a)) * @as(f64, @bitCast(b));
                            c = (bitsD(p) ^ (1 << 63)) +% (rnd.uintLessThan(u64, 5) -% 2);
                        }
                    },
                    3 => if (o.arity == 3) {
                        c = if (o.single) boxS(rnd.int(u32) & 0x807f_ffff) else rnd.int(u64) & 0x800f_ffff_ffff_ffff;
                    },
                    else => {},
                }
                rg.set(i, a, b, c);
            }
            try rg.run(o, n, .off);
            for (0..n) |i| want[i] = rg.result(i);
            @memset(rg.out, 0xee);
            try rg.run(o, n, .eager);
            try fpCompare(&rg, o, n, want);
            done += n;
        }
    }
    try t.expectEqual(@as(u64, 0), jitStat(&rg.m, "fails"));
    if (kw_options.fp_fuzz != 0) std.debug.print("[jit] F/D fuzz: {d} ops x {d} operand sets: no difference\n", .{ ops.n, per_op });
}

// ---- randomized differential test: interpreter vs JIT (regions) ----------------------
//
// Random control-flow graphs of small integer blocks over two code pages:
// conditional branches, jal (also across the pages), jalr through a jump
// table, calls of leaf blocks and their returns, loops (any target may be
// an earlier block or the block itself), ecalls, stores that raise the irq
// word every few passes, loads from a page that is mapped on demand, and
// rare stores that rewrite an instruction in another block (on either
// page). Most programs
// also mix F/D instructions into their blocks (`fzFp`): arithmetic, FMA,
// sign injection, min/max, square roots, compares, classify, moves and
// conversions in both precisions, FP loads and stores, mostly RNE or
// dynamic rounding with some static directed modes (handed back), fflags
// reads and clears and frm writes (CSR ops: handed back, so frm changes
// between compiled parts of a region); FP registers and memory start with
// values biased to edge cases (`fuzzVal`), and between slices a register
// or fcsr is sometimes reset to one. The same program runs on two
// machines, the interpreter and the JIT (random compile threshold and
// region size), with the same random budget slices and the same flushes
// between slices; every slice must end with the same event, x and f
// registers, fcsr, pc, icount and budget, and memory must match at the end.
// Between slices the "kernel" also flushes one code page, rewrites the SMC
// target, remaps a code page to a copy (sometimes with that rewrite: COW),
// or unmaps it until the next fault on it, so regions whose members span
// both pages see one page change under them while the other stays valid.
// Natively there is no JIT; the test is skipped there. `zig build fuzz --
// N [SEED]` runs N seeds (default: `fuzz_seeds_default`).

const fuzz_seeds_default = 24;

const FuzzHost = if (jit_on) struct {
    extern "env" fn kwemu_fuzz_config(which: u32) u64;
} else struct {
    fn kwemu_fuzz_config(_: u32) u64 {
        return 0;
    }
};

const fz_code: u64 = 0x100000; // two pages
const fz_data: u64 = 0x200000; // data; jump table at +0x800
const fz_irq: u64 = 0x201000; // irq word
const fz_demand: u64 = 0x202000; // mapped on the first fault
const fz_blocks_per_page = 32;
const fz_words = 16; // per block slot

const FuzzProg = struct {
    code: [2 * 1024]u32 = @splat(nop),
    jt: [8]u64 = undefined,
    /// Initial FP registers and the first 1 KiB of the data page.
    f: [32]u64 = @splat(0),
    data: [128]u64 = @splat(0),
};

/// f0..f11: few enough that FP ops depend on each other.
fn fzF(rnd: std.Random) u32 {
    return rnd.uintLessThan(u32, 12);
}

/// Mostly static RNE or dynamic; sometimes a static directed mode or RMM
/// (not compiled: handed back).
fn fzRm(rnd: std.Random) u32 {
    return switch (rnd.uintLessThan(u32, 16)) {
        0 => rnd.intRangeAtMost(u32, 1, 4),
        1...6 => 0,
        else => 7,
    };
}

/// An x register for an FP op's integer operand or result (sometimes x0).
fn fzX(rnd: std.Random) u32 {
    return if (rnd.uintLessThan(u32, 16) == 0) 0 else fzReg(rnd);
}

/// One random F/D instruction (or a few: an FP load/store with its address
/// computation); returns the number of words written to `out`.
fn fzFp(rnd: std.Random, out: *[3]u32) usize {
    const fmt = rnd.uintLessThan(u32, 2);
    const rm = fzRm(rnd);
    out[0] = switch (rnd.uintLessThan(u32, 30)) {
        0...6 => fpR(rnd.uintLessThan(u32, 4), fmt, rm, fzF(rnd), fzF(rnd), fzF(rnd)), // fadd/fsub/fmul/fdiv
        7, 8 => fpR4(([_]u32{ 0x43, 0x47, 0x4b, 0x4f })[rnd.uintLessThan(usize, 4)], fmt, rm, fzF(rnd), fzF(rnd), fzF(rnd), fzF(rnd)),
        9 => fpR(4, fmt, rnd.uintLessThan(u32, 3), fzF(rnd), fzF(rnd), fzF(rnd)), // fsgnj/n/x
        10 => fpR(5, fmt, rnd.uintLessThan(u32, 4), fzF(rnd), fzF(rnd), fzF(rnd)), // fmin/fmax, fminm/fmaxm
        11 => fpR(0x0b, fmt, rm, fzF(rnd), fzF(rnd), 0), // fsqrt
        12 => fpR(8, fmt, rm, fzF(rnd), fzF(rnd), 1 - fmt), // fcvt.s.d / fcvt.d.s
        13, 14 => fpR(0x18, fmt, ([_]u32{ 0, 1, 2, 3, 4, 7, 7, 1 })[rnd.uintLessThan(usize, 8)], fzX(rnd), fzF(rnd), rnd.uintLessThan(u32, 4)), // fcvt.{w,wu,l,lu}.fmt
        15 => fpR(0x1a, fmt, ([_]u32{ 0, 1, 7, 7, 2 })[rnd.uintLessThan(usize, 5)], fzF(rnd), fzReg(rnd), rnd.uintLessThan(u32, 4)), // fcvt.fmt.{w,wu,l,lu}
        16, 17 => fpR(0x14, fmt, ([_]u32{ 0, 1, 2, 4, 5 })[rnd.uintLessThan(usize, 5)], fzX(rnd), fzF(rnd), fzF(rnd)), // fle/flt/feq/fleq/fltq
        18 => fpR(0x1c, fmt, rnd.uintLessThan(u32, 2), fzX(rnd), fzF(rnd), 0), // fmv.x.fmt / fclass
        19 => fpR(0x1e, fmt, 0, fzF(rnd), fzReg(rnd), 0), // fmv.fmt.x
        20...22 => { // x19 = x16 + (reg & 0x3f8); fld/flw/fsd/fsw
            out[0] = itype(0x13, 7, 19, fzReg(rnd), 0x3f8);
            out[1] = rtype(0x33, 0, 0, 19, 19, 16);
            const off: i32 = if (rnd.boolean()) 0 else 4;
            out[2] = switch (rnd.uintLessThan(u32, 4)) {
                0 => fld(fzF(rnd), 19, 0),
                1 => flw(fzF(rnd), 19, off),
                2 => fsd(fzF(rnd), 19, 0),
                else => fsw(fzF(rnd), 19, off),
            };
            return 3;
        },
        23 => itype(0x73, 5, 0, if (rnd.uintLessThan(u32, 3) == 0) rnd.intRangeAtMost(u32, 1, 4) else 0, 2), // csrrwi x0, frm, imm
        24 => itype(0x73, 2, fzX(rnd), 0, 1), // csrrs x, fflags, x0
        25 => fpR(8, fmt, rm, fzF(rnd), fzF(rnd), if (rnd.boolean()) 4 else 5), // fround / froundnx (Zfa)
        26 => fpR(0x1e, fmt, 0, fzF(rnd), rnd.uintLessThan(u32, 32), 1), // fli (Zfa)
        27 => fpR(0x18, 1, 1, fzX(rnd), fzF(rnd), 8), // fcvtmod.w.d (Zfa)
        28 => switch (rnd.uintLessThan(u32, 4)) { // Zfhmin (handed back)
            0 => fpR(8, fmt, rm, fzF(rnd), fzF(rnd), 2), // fcvt.s.h / fcvt.d.h
            1 => fpR(8, 2, rm, fzF(rnd), fzF(rnd), fmt), // fcvt.h.s / fcvt.h.d
            2 => fpR(0x1e, 2, 0, fzF(rnd), fzReg(rnd), 0), // fmv.h.x
            else => fpR(0x1c, 2, 0, fzX(rnd), fzF(rnd), 0), // fmv.x.h
        },
        else => itype(0x73, 1, 0, 0, 1), // csrrw x0, fflags, x0
    };
    return 1;
}

fn fzReg(rnd: std.Random) u32 {
    return 5 + rnd.uintLessThan(u32, 11); // x5..x15
}

/// A jump target for block i: usually in its own page.
fn fzTarget(rnd: std.Random, i: usize) u64 {
    const page = if (rnd.uintLessThan(u32, 4) == 0) rnd.uintLessThan(usize, 2) else i / fz_blocks_per_page;
    return fzBlockAddr(page * fz_blocks_per_page + rnd.uintLessThan(usize, fz_blocks_per_page));
}

fn fzBlockAddr(i: usize) u64 {
    return fz_code + (i / fz_blocks_per_page) * 4096 + (i % fz_blocks_per_page) * fz_words * 4;
}

fn fzAlu(rnd: std.Random) u32 {
    const rd = if (rnd.uintLessThan(u32, 16) == 0) 0 else fzReg(rnd);
    const a = fzReg(rnd);
    const b = fzReg(rnd);
    return switch (rnd.uintLessThan(u32, 64)) {
        0 => rtype(0x33, 0, 0, rd, a, b), // add
        1 => rtype(0x33, 0, 0x20, rd, a, b), // sub
        2 => rtype(0x33, 4, 0, rd, a, b), // xor
        3 => rtype(0x33, 6, 0, rd, a, b), // or
        4 => rtype(0x33, 7, 0, rd, a, b), // and
        5 => rtype(0x33, 1, 0, rd, a, b), // sll
        6 => rtype(0x33, 5, 0x20, rd, a, b), // sra
        7 => rtype(0x33, 2, 0, rd, a, b), // slt
        8 => rtype(0x33, 3, 0, rd, a, b), // sltu
        9 => rtype(0x33, 0, 1, rd, a, b), // mul
        10 => rtype(0x33, 1, 1, rd, a, b), // mulh
        11 => rtype(0x33, 4, 1, rd, a, b), // div
        12 => rtype(0x33, 7, 1, rd, a, b), // remu
        13 => rtype(0x3b, 0, 0, rd, a, b), // addw
        14 => rtype(0x3b, 1, 0, rd, a, b), // sllw
        15 => addi(rd, a, rnd.intRangeAtMost(i32, -2048, 2047)),
        16 => itype(0x13, 4, rd, a, rnd.intRangeAtMost(i32, -2048, 2047)), // xori
        17 => itype(0x13, 7, rd, a, rnd.intRangeAtMost(i32, -2048, 2047)), // andi
        18 => itype(0x13, 1, rd, a, rnd.intRangeAtMost(i32, 0, 63)), // slli
        19 => itype(0x13, 5, rd, a, rnd.intRangeAtMost(i32, 0, 63) | 0x400), // srai
        20 => itype(0x1b, 0, rd, a, rnd.intRangeAtMost(i32, -2048, 2047)), // addiw
        // Zkne / Zknd (blocks with more than 4 of es/esm/ds/dsm/im call helpers)
        22 => rtype(0x33, 0, 0x19, rd, a, b), // aes64es
        23 => rtype(0x33, 0, 0x1b, rd, a, b), // aes64esm
        24 => rtype(0x33, 0, 0x1d, rd, a, b), // aes64ds
        25 => rtype(0x33, 0, 0x1f, rd, a, b), // aes64dsm
        26 => rtype(0x33, 0, 0x3f, rd, a, b), // aes64ks2
        27 => itype(0x13, 1, rd, a, 0x300), // aes64im
        28 => itype(0x13, 1, rd, a, @intCast(0x310 | rnd.uintAtMost(u32, 10))), // aes64ks1i
        // Zbkb, Zbc/Zbkc, Zbkx (blocks with more than 12 clmul*/xperm* call helpers)
        29 => rtype(0x33, 7, 0x20, rd, a, b), // andn
        30 => rtype(0x33, 6, 0x20, rd, a, b), // orn
        31 => rtype(0x33, 4, 0x20, rd, a, b), // xnor
        32 => rtype(0x33, 1, 0x30, rd, a, b), // rol
        33 => rtype(0x33, 5, 0x30, rd, a, b), // ror
        34 => rtype(0x3b, 1, 0x30, rd, a, b), // rolw
        35 => rtype(0x3b, 5, 0x30, rd, a, b), // rorw
        36 => rtype(0x33, 4, 0x04, rd, a, b), // pack
        37 => rtype(0x33, 7, 0x04, rd, a, b), // packh
        38 => rtype(0x3b, 4, 0x04, rd, a, b), // packw
        39 => rtype(0x33, 1 + rnd.uintLessThan(u32, 3), 0x05, rd, a, b), // clmul, clmulr, clmulh
        40, 41 => rtype(0x33, 1, 0x05, rd, a, b), // clmul
        42 => rtype(0x33, if (rnd.boolean()) 2 else 4, 0x14, rd, a, b), // xperm4, xperm8
        43 => itype(0x13, 5, rd, a, @intCast(0x600 | rnd.uintAtMost(u32, 63))), // rori
        44 => itype(0x1b, 5, rd, a, @intCast(0x600 | rnd.uintAtMost(u32, 31))), // roriw
        45 => itype(0x13, 5, rd, a, 0x6b8), // rev8
        46 => itype(0x13, 5, rd, a, 0x687), // brev8
        // Zba, Zbb, Zbs, Zicond
        47 => rtype(0x33, 2 * (1 + rnd.uintLessThan(u32, 3)), 0x10, rd, a, b), // sh1add..sh3add
        48 => if (rnd.boolean()) rtype(0x3b, 2 * (1 + rnd.uintLessThan(u32, 3)), 0x10, rd, a, b) else rtype(0x3b, 0, 0x04, rd, a, b), // shNadd.uw, add.uw
        49 => itype(0x1b, 1, rd, a, @intCast(0x080 | rnd.uintAtMost(u32, 63))), // slli.uw
        50 => itype(0x13, 1, rd, a, @intCast(0x600 + ([_]u32{ 0, 1, 2, 4, 5 })[rnd.uintLessThan(u32, 5)])), // clz ctz cpop sext.b sext.h
        51 => itype(0x1b, 1, rd, a, @intCast(0x600 + rnd.uintLessThan(u32, 3))), // clzw ctzw cpopw
        52 => rtype(0x33, 4 + rnd.uintLessThan(u32, 4), 0x05, rd, a, b), // min minu max maxu
        53 => itype(0x13, 5, rd, a, 0x287), // orc.b
        54 => rtype(0x3b, 4, 0x04, rd, a, 0), // zext.h
        55 => rtype(0x33, 1, ([_]u32{ 0x14, 0x24, 0x34 })[rnd.uintLessThan(u32, 3)], rd, a, b), // bset bclr binv
        56 => rtype(0x33, 5, 0x24, rd, a, b), // bext
        57 => itype(0x13, 1, rd, a, @intCast(([_]u32{ 0x280, 0x480, 0x680 })[rnd.uintLessThan(u32, 3)] | rnd.uintAtMost(u32, 63))), // bseti bclri binvi
        58 => itype(0x13, 5, rd, a, @intCast(0x480 | rnd.uintAtMost(u32, 63))), // bexti
        59, 60 => rtype(0x33, if (rnd.boolean()) 5 else 7, 0x07, rd, a, b), // czero.eqz/nez
        // Zcb (two per word: c.mul, c.zext.*, c.sext.*, c.not on x8..x15), Zcmop
        61 => blk: {
            var c: [2]u32 = undefined;
            for (&c) |*x| x.* = switch (rnd.uintLessThan(u32, 8)) {
                0 => cMul(8 + rnd.uintLessThan(u32, 8), 8 + rnd.uintLessThan(u32, 8)),
                1 => cMop(1 + 2 * rnd.uintLessThan(u32, 8)),
                else => cZcbUnary(rnd.uintLessThan(u32, 6), 8 + rnd.uintLessThan(u32, 8)),
            };
            break :blk cPair(c[0], c[1]);
        },
        // Zimop, Zawrs
        62 => switch (rnd.uintLessThan(u32, 3)) {
            0 => mopR(rnd.uintLessThan(u32, 32), rd, a),
            1 => mopRR(rnd.uintLessThan(u32, 8), rd, a, b),
            else => if (rnd.boolean()) 0x00d00073 else 0x01d00073,
        },
        else => lui(rd, rnd.int(u32) & 0xfffff),
    };
}

/// Generate a program; returns the address and the two encodings of the
/// instruction that SMC stores toggle (xor of both in x30).
fn fzGen(rnd: std.Random, p: *FuzzProg) struct { smc_at: u64, smc_xor: u32 } {
    const nb = 2 * fz_blocks_per_page;
    // share of F/D instructions among a block's body (0..4 in 8)
    const fp_rate = rnd.uintLessThan(u32, 5);
    for (&p.f) |*f| f.* = fuzzVal(rnd, rnd.boolean());
    for (&p.data) |*v| v.* = fuzzVal(rnd, rnd.boolean());
    var leaf: [nb]bool = undefined;
    for (&leaf) |*l| l.* = rnd.uintLessThan(u32, 5) == 0;
    leaf[0] = false;
    var leaves: [nb]usize = undefined;
    var nleaves: usize = 0;
    for (0..nb) |i| if (leaf[i]) {
        leaves[nleaves] = i;
        nleaves += 1;
    };
    for (&p.jt) |*j| j.* = fzBlockAddr(rnd.uintLessThan(usize, nb));
    // the SMC target: an addi in block `sb`, word 0, addressed from the
    // start of its page (x28 or x27: a 12-bit offset)
    const sb = rnd.uintLessThan(usize, nb);
    const smc_base: u32 = if (sb < fz_blocks_per_page) 28 else 27;
    const smc_off: i32 = @intCast(fzBlockAddr(sb) % 4096);
    const smc_rd = fzReg(rnd);
    const e1 = addi(smc_rd, smc_rd, 1);
    const e2 = addi(smc_rd, smc_rd, -3);
    for (0..nb) |i| {
        const base = (fzBlockAddr(i) - fz_code) / 4;
        var w: usize = 0;
        const put = struct {
            fn f(pp: *FuzzProg, b: usize, ww: *usize, v: u32) void {
                pp.code[b + ww.*] = v;
                ww.* += 1;
            }
        }.f;
        if (i == sb) put(p, base, &w, e1);
        const nops = rnd.uintLessThan(usize, 6);
        for (0..nops) |_| {
            if (w > 8) break; // at most 4 more words here, 4 for the terminator
            if (rnd.uintLessThan(u32, 8) < fp_rate) {
                var fw: [3]u32 = undefined;
                for (fw[0..fzFp(rnd, &fw)]) |v| put(p, base, &w, v);
                continue;
            }
            switch (rnd.uintLessThan(u32, 20)) {
                0...10 => put(p, base, &w, fzAlu(rnd)),
                11...13 => { // load/store in the data page: x19 = x16 + (reg & 0x3f8)
                    put(p, base, &w, itype(0x13, 7, 19, fzReg(rnd), 0x3f8));
                    put(p, base, &w, rtype(0x33, 0, 0, 19, 19, 16));
                    put(p, base, &w, switch (rnd.uintLessThan(u32, 5)) {
                        0 => ld(fzReg(rnd), 19, 0),
                        1 => lw(fzReg(rnd), 19, 4),
                        2 => itype(0x03, 4, fzReg(rnd), 19, 1), // lbu
                        3 => sd(fzReg(rnd), 19, 0),
                        else => store(0, fzReg(rnd), 19, 3), // sb
                    });
                },
                14 => put(p, base, &w, ld(fzReg(rnd), 20, @intCast(8 * rnd.uintLessThan(u32, 64)))), // demand page
                15, 16 => { // every 2^k passes: raise the irq word
                    put(p, base, &w, addi(17, 17, 1));
                    put(p, base, &w, itype(0x13, 7, 25, 17, @intCast((@as(u32, 1) << @intCast(rnd.intRangeAtMost(u32, 3, 8))) - 1)));
                    put(p, base, &w, branch(1, 25, 0, 8)); // bne x25, x0, +8
                    put(p, base, &w, sw(24, 22, 0));
                },
                17 => if (rnd.uintLessThan(u32, 3) == 0) { // rewrite the SMC target
                    put(p, base, &w, lw(29, smc_base, smc_off));
                    put(p, base, &w, rtype(0x33, 4, 0, 29, 29, 30));
                    put(p, base, &w, sw(29, smc_base, smc_off));
                } else put(p, base, &w, fzAlu(rnd)),
                else => put(p, base, &w, fzAlu(rnd)),
            }
        }
        const here = fzBlockAddr(i);
        const rel = struct {
            fn f(from: u64, to: u64) i32 {
                return @intCast(@as(i64, @bitCast(to -% from)));
            }
        }.f;
        if (leaf[i]) {
            put(p, base, &w, itype(0x67, 0, 0, 1, 0)); // ret
            continue;
        }
        const tgt = fzTarget(rnd, i);
        const tgt2 = fzTarget(rnd, i);
        switch (rnd.uintLessThan(u32, 12)) {
            0...3 => { // bxx -> tgt, else j tgt2
                const f3s = [_]u32{ 0, 1, 4, 5, 6, 7 };
                const at = here + 4 * w;
                put(p, base, &w, branch(f3s[rnd.uintLessThan(usize, 6)], fzReg(rnd), fzReg(rnd), rel(at, fzBlockAddr((i / fz_blocks_per_page) * fz_blocks_per_page + rnd.uintLessThan(usize, fz_blocks_per_page)))));
                put(p, base, &w, jal(0, rel(here + 4 * w, tgt2)));
            },
            4, 5, 9, 11 => put(p, base, &w, jal(0, rel(here + 4 * w, tgt))),
            6 => { // jalr through the jump table
                put(p, base, &w, itype(0x13, 7, 26, fzReg(rnd), 7 * 8));
                put(p, base, &w, rtype(0x33, 0, 0, 26, 26, 18));
                put(p, base, &w, ld(26, 26, 0));
                put(p, base, &w, itype(0x67, 0, 0, 26, 0));
            },
            7, 8 => if (nleaves > 0) { // call a leaf, then j tgt2
                const l = fzBlockAddr(leaves[rnd.uintLessThan(usize, nleaves)]);
                put(p, base, &w, jal(1, rel(here + 4 * w, l)));
                put(p, base, &w, jal(0, rel(here + 4 * w, tgt2)));
            } else put(p, base, &w, jal(0, rel(here + 4 * w, tgt))),
            else => { // ecall, then j tgt
                put(p, base, &w, ecall);
                put(p, base, &w, jal(0, rel(here + 4 * w, tgt)));
            },
        }
        std.debug.assert(w <= fz_words);
    }
    return .{ .smc_at = fzBlockAddr(sb), .smc_xor = e1 ^ e2 };
}

const FuzzMachine = struct {
    m: Machine,
    code_pa: u64,
    data_pa: u64,
    irq_pa: u64,
    demand_pa: u64,
    /// Two more frames for the code pages: page j is mapped to code_pa +
    /// 4096 j or to alt_pa + 4096 j (`cur`), or unmapped until it faults.
    alt_pa: u64 = 0,
    cur: [2]u64 = undefined,
    unmapped: [2]bool = .{ false, false },
    /// The last slice ended with a fault on an unmapped code page.
    code_fault: bool = false,

    fn init(p: *const FuzzProg, smc_xor: u32) !FuzzMachine {
        var f: FuzzMachine = .{ .m = try Machine.init(), .code_pa = 0, .data_pa = 0, .irq_pa = 0, .demand_pa = 0 };
        const m = &f.m;
        f.code_pa = m.frame();
        _ = m.frame();
        @memcpy(m.mem[@intCast(f.code_pa - pa_base)..][0 .. 2 * 4096], std.mem.sliceAsBytes(&p.code));
        m.map(fz_code, f.code_pa, RWX);
        m.map(fz_code + 4096, f.code_pa + 4096, RWX);
        f.data_pa = m.frame();
        m.map(fz_data, f.data_pa, R | W | U | A | D);
        @memcpy(m.bytes(f.data_pa)[0x800..][0..64], std.mem.sliceAsBytes(&p.jt));
        @memcpy(m.bytes(f.data_pa)[0..0x400], std.mem.sliceAsBytes(&p.data));
        m.regs.f = p.f;
        m.regs.fcsr = 0;
        f.irq_pa = m.frame();
        m.map(fz_irq, f.irq_pa, R | W | U | A | D);
        f.demand_pa = m.frame();
        f.alt_pa = m.frame();
        _ = m.frame();
        f.cur = .{ f.code_pa, f.code_pa + 4096 };
        m.cpu.irq_pending = @ptrCast(@alignCast(m.bytes(f.irq_pa).ptr));
        m.cpu.flushAll();
        for (5..16) |i| m.regs.x[i] = 0x0123_4567_89ab_cdef *% (i + 1);
        m.regs.x[1] = fz_code;
        m.regs.x[16] = fz_data;
        m.regs.x[18] = fz_data + 0x800;
        m.regs.x[20] = fz_demand;
        m.regs.x[22] = fz_irq;
        m.regs.x[24] = 1;
        m.regs.x[27] = fz_code + 4096;
        m.regs.x[28] = fz_code;
        m.regs.x[30] = smc_xor;
        m.regs.pc = fz_code;
        return f;
    }

    /// One slice; handles the event like a kernel would.
    fn slice(f: *FuzzMachine, budget: u64) u32 {
        const m = &f.m;
        f.code_fault = false;
        const ev = m.run(budget);
        switch (ev) {
            EV_INTERRUPT => m.bytes(f.irq_pa)[0] = 0,
            EV_FAULT => {
                const page = m.cpu.ev.addr >> 12;
                if (page == fz_demand >> 12) {
                    m.map(fz_demand, f.demand_pa, R | W | U | A | D);
                    m.cpu.flushRange(fz_demand, fz_demand + 4096);
                }
                for (0..2) |j| if (page == (fz_code >> 12) + j and f.unmapped[j]) f.remap(j, false);
            },
            EV_SYSCALL => m.regs.x[10] = m.cpu.icount & 0xff,
            else => {},
        }
        return ev;
    }

    /// Map code page j again (to its current frame), or to the other frame
    /// with a copy of its contents (`move`), and flush it.
    fn remap(f: *FuzzMachine, j: usize, move: bool) void {
        const m = &f.m;
        const va = fz_code + 4096 * j;
        if (move) {
            const to = if (f.cur[j] == f.code_pa + 4096 * j) f.alt_pa + 4096 * j else f.code_pa + 4096 * j;
            @memcpy(m.bytes(to), m.bytes(f.cur[j]));
            f.cur[j] = to;
        } else {
            f.code_fault = true;
            f.unmapped[j] = false;
        }
        if (!f.unmapped[j]) m.map(va, f.cur[j], RWX);
        m.cpu.flushRange(va, va + 4096);
    }

    fn unmap(f: *FuzzMachine, j: usize) void {
        const va = fz_code + 4096 * j;
        f.m.slot(va).* = 0;
        f.unmapped[j] = true;
        f.m.cpu.flushRange(va, va + 4096);
    }

    /// The kernel rewrites the SMC target (in the frame its page uses now).
    fn rewrite(f: *FuzzMachine, at: u64, xor: u32) void {
        const j: usize = @intCast((at - fz_code) / 4096);
        const w = f.m.bytes(f.cur[j])[@intCast(at % 4096)..][0..4];
        std.mem.writeInt(u32, w, std.mem.readInt(u32, w, .little) ^ xor, .little);
    }
};

const FuzzTotals = struct {
    insns: u64 = 0,
    slices: u64 = 0,
    events: [8]u64 = @splat(0),
    compiles: u64 = 0,
    members: u64 = 0,
    entries: u64 = 0,
    /// -Dkwemu-stats: branches between region members, and stops at one.
    hops: u64 = 0,
    stops: u64 = 0,
    jit_insns: u64 = 0,
    /// ... into a member on another page; regions grown along exits.
    cross: u64 = 0,
    exit_grows: u64 = 0,
};

fn fuzzOne(seed: u64, tot: *FuzzTotals) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var p: FuzzProg = .{};
    const g = fzGen(rnd, &p);
    var a = try FuzzMachine.init(&p, g.smc_xor);
    defer a.m.deinit();
    var b = try FuzzMachine.init(&p, g.smc_xor);
    defer b.m.deinit();
    jitMode(&a.m, .off, 0);
    const thresholds = [_]u32{ 1, 1, 30, 200, 3000 };
    jitMode(&b.m, .threshold, thresholds[rnd.uintLessThan(usize, thresholds.len)]);
    if (jit_on) {
        b.m.cpu.priv.jit.region_max = ([_]u32{ 1, 2, 4, 16, 16, 16 })[rnd.uintLessThan(usize, 6)];
        b.m.cpu.priv.jit.grow_threshold = ([_]u32{ 1, 2, 8, 64, std.math.maxInt(u32) })[rnd.uintLessThan(usize, 5)];
    }
    // Every other compile, "another CPU" asks for a flush during it (no
    // change of mappings: the results must not change).
    hook_m = &b.m;
    hook_calls = 0;
    compile_hook = struct {
        fn f() void {
            hook_calls += 1;
            if (hook_calls & 1 == 0) @atomicStore(u32, &hook_m.?.cpu.flush_all, 1, .seq_cst);
        }
    }.f;
    defer {
        compile_hook = null;
        hook_m = null;
    }
    var total: u64 = 0;
    var slices: usize = 0;
    while (total < 60_000 and slices < 600) : (slices += 1) {
        const budget: u64 = switch (rnd.uintLessThan(u32, 4)) {
            0 => rnd.intRangeAtMost(u64, 1, 16),
            1 => rnd.intRangeAtMost(u64, 1, 300),
            2 => rnd.intRangeAtMost(u64, 1, 3000),
            else => rnd.intRangeAtMost(u64, 1, 20000),
        };
        switch (rnd.uintLessThan(u32, 40)) { // the kernel's flushes between slices
            0 => for ([_]*Machine{ &a.m, &b.m }) |m| m.cpu.flushAll(),
            1 => for ([_]*Machine{ &a.m, &b.m }) |m| m.cpu.flushRange(fz_code, fz_code + 4096),
            2 => for ([_]*Machine{ &a.m, &b.m }) |m| kwemu.setPgd(m.cpu, m.root),
            3, 4 => for ([_]*FuzzMachine{ &a, &b }) |f| { // the kernel rewrites code, then flushes
                f.rewrite(g.smc_at, g.smc_xor);
                const va = g.smc_at & ~@as(u64, 4095);
                f.m.cpu.flushRange(va, va + 4096);
            },
            5 => for ([_]*Machine{ &a.m, &b.m }) |m| m.cpu.flushRange(fz_code + 4096, fz_code + 8192),
            6, 7 => { // COW: a code page moves to a copy (sometimes with the rewrite)
                const j = rnd.uintLessThan(usize, 2);
                const change = rnd.boolean() and (g.smc_at - fz_code) / 4096 == j;
                for ([_]*FuzzMachine{ &a, &b }) |f| {
                    f.remap(j, true);
                    if (change) f.rewrite(g.smc_at, g.smc_xor);
                }
            },
            8 => { // a code page is unmapped until the next fault on it
                const j = rnd.uintLessThan(usize, 2);
                for ([_]*FuzzMachine{ &a, &b }) |f| f.unmap(j);
            },
            else => {},
        }
        // what a kernel may do to the FP state between slices (signal
        // frames, context switches): reset a register or fcsr
        switch (rnd.uintLessThan(u32, 16)) {
            0, 1 => {
                const fr = fzF(rnd);
                const v = fuzzVal(rnd, rnd.boolean());
                a.m.regs.f[fr] = v;
                b.m.regs.f[fr] = v;
            },
            2 => {
                const v = (rnd.uintLessThan(u32, 5) << 5) | rnd.uintLessThan(u32, 32);
                a.m.regs.fcsr = v;
                b.m.regs.fcsr = v;
            },
            else => {},
        }
        const ea = a.slice(budget);
        const eb = b.slice(budget);
        total += budget - a.m.cpu.budget;
        tot.events[ea & 7] += 1;
        if ((ea == EV_FAULT and a.m.cpu.ev.addr >> 12 != fz_demand >> 12 and !a.code_fault) or ea == EV_ILLEGAL) {
            std.debug.print("fuzz seed {d}: generator bug: event {d} at pc 0x{x} addr 0x{x}\n", .{ seed, ea, a.m.regs.pc, a.m.cpu.ev.addr });
            return error.TestUnexpectedResult;
        }
        if (ea != eb or a.m.regs.pc != b.m.regs.pc or a.m.cpu.icount != b.m.cpu.icount or
            a.m.cpu.budget != b.m.cpu.budget or !std.mem.eql(u64, &a.m.regs.x, &b.m.regs.x) or
            !std.mem.eql(u64, &a.m.regs.f, &b.m.regs.f) or a.m.regs.fcsr != b.m.regs.fcsr or
            a.m.cpu.ev.addr != b.m.cpu.ev.addr)
        {
            std.debug.print("fuzz seed {d} slice {d} (budget {d}): interp ev {d} pc 0x{x} icount {d} budget {d}; jit ev {d} pc 0x{x} icount {d} budget {d}\n", .{
                seed, slices, budget, ea, a.m.regs.pc, a.m.cpu.icount, a.m.cpu.budget, eb, b.m.regs.pc, b.m.cpu.icount, b.m.cpu.budget,
            });
            for (0..32) |i| if (a.m.regs.x[i] != b.m.regs.x[i])
                std.debug.print("  x{d}: 0x{x} vs 0x{x}\n", .{ i, a.m.regs.x[i], b.m.regs.x[i] });
            for (0..32) |i| if (a.m.regs.f[i] != b.m.regs.f[i])
                std.debug.print("  f{d}: 0x{x} vs 0x{x}\n", .{ i, a.m.regs.f[i], b.m.regs.f[i] });
            if (a.m.regs.fcsr != b.m.regs.fcsr) std.debug.print("  fcsr: 0x{x} vs 0x{x}\n", .{ a.m.regs.fcsr, b.m.regs.fcsr });
            return error.TestUnexpectedResult;
        }
    }
    for ([_][2]u64{ .{ a.code_pa, b.code_pa }, .{ a.code_pa + 4096, b.code_pa + 4096 }, .{ a.alt_pa, b.alt_pa }, .{ a.alt_pa + 4096, b.alt_pa + 4096 }, .{ a.data_pa, b.data_pa }, .{ a.demand_pa, b.demand_pa } }) |pp|
        try t.expectEqualSlices(u8, a.m.bytes(pp[0]), b.m.bytes(pp[1]));
    try checkJitSlots(&b.m);
    tot.insns += total;
    tot.slices += slices;
    tot.compiles += jitStat(&b.m, "compiles");
    tot.members += jitStat(&b.m, "members_total");
    tot.entries += jitStat(&b.m, "entries");
    tot.exit_grows += jitStat(&b.m, "exit_grows");
    if (jit_on and kwemu.stats_on) {
        tot.cross += b.m.cpu.priv.stats.jit.jx[jit.Jx.region_cross];
        tot.hops += b.m.cpu.priv.stats.jit.jx[jit.Jx.region_hops];
        tot.stops += b.m.cpu.priv.stats.jit.jx[jit.Jx.region_stop];
        // the compiled share is a part of what retired
        try t.expect(b.m.cpu.priv.stats.jit.insns <= b.m.cpu.icount);
        tot.jit_insns += b.m.cpu.priv.stats.jit.insns;
    }
}

test "kwemu jit fuzz: random control flow, interpreter vs JIT (budgets, irq, flushes, SMC)" {
    if (!jit_on) return error.SkipZigTest;
    const n = FuzzHost.kwemu_fuzz_config(0);
    const seed0 = FuzzHost.kwemu_fuzz_config(1);
    const seeds = if (n == 0) fuzz_seeds_default else n;
    var tot: FuzzTotals = .{};
    for (0..seeds) |i| try fuzzOne(seed0 + i, &tot);
    std.debug.print("kwemu jit fuzz: seeds {d}..{d}: {d} instructions in {d} slices (events: {d} budget, {d} syscall, {d} fault, {d} interrupt, {d} other); JIT: {d} regions of {d} blocks ({d} grown along exits), {d} entries\n", .{
        seed0,                                      seed0 + seeds - 1, tot.insns,         tot.slices,   tot.events[EV_BUDGET], tot.events[EV_SYSCALL],
        tot.events[EV_FAULT],                       tot.events[EV_INTERRUPT],
        tot.slices - tot.events[EV_BUDGET] - tot.events[EV_SYSCALL] - tot.events[EV_FAULT] - tot.events[EV_INTERRUPT],
        tot.compiles,                               tot.members,       tot.exit_grows,    tot.entries,
    });
    if (kwemu.stats_on) std.debug.print("kwemu jit fuzz: {d} branches between region members ({d} into another page), {d} stops; {d} instructions retired by compiled code\n", .{ tot.hops, tot.cross, tot.stops, tot.jit_insns });
}

// ---- JIT regions: invariants, each checked against the interpreter ------------------
//
// A dispatch loop in one code page: H (0x10000) increments x5 and jumps
// through a jump table (x20) to one of four targets T0..T3 (0x10100 ..
// 0x10400); each target runs its body, branches back to H (a side exit,
// so no target is a self-loop) unless x5 == x9, then ends in an ecall.
// H and the targets become one region. `Duo` runs the same program on an
// interpreter machine and on a JIT machine with the same budget slices and
// compares every slice (event, pc, icount, budget, x and f registers, fcsr).

const rg_code: u64 = 0x10000;
const rg_data: u64 = 0x20000;
const rg_irq: u64 = 0x30000;
const rg_demand: u64 = 0x40000;

fn rgTarget(j: usize) u64 {
    return rg_code + 0x100 * (j + 1);
}

/// The dispatcher and 2^k targets with the given bodies (at most 61 words).
fn rgProgram(m: *Machine, pa: u64, bodies: []const []const u32) void {
    const mask: i32 = @intCast(bodies.len - 1);
    putCode(m, pa, 0, &.{ addi(5, 5, 1), itype(0x13, 7, 7, 5, mask), itype(0x13, 1, 7, 7, 3), rtype(0x33, 0, 0, 7, 7, 20), ld(7, 7, 0), itype(0x67, 0, 0, 7, 0) });
    for (bodies, 0..) |body, j| {
        const off = rgTarget(j) - rg_code;
        putCode(m, pa, off, body);
        const at = off + 4 * body.len;
        putCode(m, pa, at, &.{ branch(1, 5, 9, -@as(i32, @intCast(at))), ecall, jal(0, -@as(i32, @intCast(at + 8))) });
    }
}

const Duo = struct {
    a: Machine,
    b: Machine,
    /// Per machine: physical frames of the code, data and irq pages.
    code_pa: [2]u64 = undefined,
    irq_pa: [2]u64 = undefined,
    demand_pa: [2]u64 = undefined,

    fn init(bodies: []const []const u32, threshold: u32) !Duo {
        var d: Duo = .{ .a = try Machine.init(), .b = try Machine.init() };
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            const pa = m.frame();
            rgProgram(m, pa, bodies);
            m.map(rg_code, pa, RWX);
            const data = m.frame();
            m.map(rg_data, data, R | W | U | A | D);
            for (0..bodies.len) |j| std.mem.writeInt(u64, m.bytes(data)[j * 8 ..][0..8], rgTarget(j), .little);
            const irq = m.frame();
            m.map(rg_irq, irq, R | W | U | A | D);
            m.cpu.irq_pending = @ptrCast(@alignCast(m.bytes(irq).ptr));
            d.code_pa[k] = pa;
            d.irq_pa[k] = irq;
            d.demand_pa[k] = m.frame();
            m.cpu.flushAll();
            m.regs.pc = rg_code;
            m.regs.x[20] = rg_data;
            m.regs.x[22] = rg_irq;
            m.regs.x[24] = 1;
            m.regs.x[25] = rg_demand;
        }
        jitMode(&d.a, .off, 0);
        jitMode(&d.b, .threshold, threshold);
        return d;
    }
    fn deinit(d: *Duo) void {
        d.a.deinit();
        d.b.deinit();
    }
    fn set(d: *Duo, reg: usize, v: u64) void {
        d.a.regs.x[reg] = v;
        d.b.regs.x[reg] = v;
    }
    fn setF(d: *Duo, reg: usize, v: u64) void {
        d.a.regs.f[reg] = v;
        d.b.regs.f[reg] = v;
    }
    fn setFcsr(d: *Duo, v: u32) void {
        d.a.regs.fcsr = v;
        d.b.regs.fcsr = v;
    }
    /// The same slice on both; they must agree. Interrupts are acknowledged
    /// and the demand page is mapped on its fault, as a kernel would.
    fn slice(d: *Duo, budget: u64) !u32 {
        var evs: [2]u32 = undefined;
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            evs[k] = m.run(budget);
            switch (evs[k]) {
                EV_INTERRUPT => m.bytes(d.irq_pa[k])[0] = 0,
                EV_FAULT => if (m.cpu.ev.addr >> 12 == rg_demand >> 12) {
                    m.map(rg_demand, d.demand_pa[k], R | U | A);
                    m.cpu.flushRange(rg_demand, rg_demand + 4096);
                },
                else => {},
            }
        }
        try t.expectEqual(evs[0], evs[1]);
        try t.expectEqual(d.a.regs.pc, d.b.regs.pc);
        try t.expectEqual(d.a.cpu.icount, d.b.cpu.icount);
        try t.expectEqual(d.a.cpu.budget, d.b.cpu.budget);
        try t.expectEqual(d.a.cpu.ev.addr, d.b.cpu.ev.addr);
        try t.expectEqualSlices(u64, &d.a.regs.x, &d.b.regs.x);
        try t.expectEqualSlices(u64, &d.a.regs.f, &d.b.regs.f);
        try t.expectEqual(d.a.regs.fcsr, d.b.regs.fcsr);
        return evs[0];
    }
    /// Slices of varying sizes until the program's final ecall (x5 == x9).
    fn finish(d: *Duo, seed: u64) !u64 {
        var budget = seed;
        var n: u64 = 0;
        while (true) : (n += 1) {
            budget = 1 + (budget * 7919 + 13) % 997;
            const ev = try d.slice(budget);
            if (ev == EV_SYSCALL and d.a.regs.x[5] == d.a.regs.x[9]) return n;
            try t.expect(n < 1_000_000);
        }
    }
};

const csrr_instret = itype(0x73, 2, 8, 0, 0xc02);

test "kwemu jit regions: budget and instret exact across members, odd slices" {
    var d = try Duo.init(&.{
        &.{addi(6, 6, 1)},
        &.{ addi(14, 14, 1), csrr_instret, rtype(0x33, 0, 0, 10, 10, 8) }, // hand-back in a member
        &.{ addi(6, 6, 3), rtype(0x33, 0, 1, 11, 6, 5) },
        &.{ addi(6, 6, 4), itype(0x13, 1, 12, 6, 2) },
    }, 50);
    defer d.deinit();
    d.set(9, 3000);
    const slices = try d.finish(5);
    try t.expect(slices > 20);
    // every pass: H (6) + body + bne; T1 reads instret after one addi
    var x6: u64 = 0;
    var x10: u64 = 0;
    var ic: u64 = 0;
    const lens = [_]u64{ 1, 3, 2, 2 };
    for (1..3001) |i| {
        ic += 6;
        const j = i & 3;
        if (j == 1) x10 +%= ic + 1;
        x6 += ([_]u64{ 1, 0, 3, 4 })[j];
        ic += lens[j] + 1;
    }
    try t.expectEqual(x6, d.b.regs.x[6]);
    try t.expectEqual(x10, d.b.regs.x[10]);
    try t.expectEqual(ic + 1, d.b.cpu.icount); // + the final ecall
    if (jit_on) {
        // Most passes stayed inside the region: far fewer entries than the
        // 2 * 3000 blocks run, and a few modules for one page.
        try t.expect(jitStat(&d.b, "entries") < 3000);
        try t.expect(jitStat(&d.b, "compiles") <= 6);
        try t.expect(jitStat(&d.b, "members_total") > jitStat(&d.b, "compiles"));
    }
    try checkJitSlots(&d.b);
    // a cache reset frees every region
    d.b.cpu.resetCache();
    try t.expectEqual(jitStat(&d.b, "compiles"), jitStat(&d.b, "frees"));
    try checkJitSlots(&d.b);
}

test "kwemu jit regions: exit counters (-Dkwemu-stats): side exits of members, stops, reason by next block" {
    // T0 leaves through a side exit on every other pass, to a block that
    // starts with a csrr (handed back at op 0, so never compiled): a region
    // side exit, whatever T0's terminator is.
    var d = try Duo.init(&.{
        &.{ itype(0x13, 7, 8, 5, 2), branch(0, 8, 0, 8), addi(6, 6, 1), csrr_instret },
        &.{addi(6, 6, 2)},
    }, 50);
    defer d.deinit();
    d.set(9, 4000);
    _ = try d.finish(3);
    if (!jit_on or !kwemu.stats_on) return;
    if (kwemu.stats_on) {
        const jx = &d.b.cpu.priv.stats.jit.jx;
        const J = jit.Jx;
        try t.expectEqual(jx[J.entries], jx[J.handbacks] + jx[J.exit_side] + jx[J.exit_direct] + jx[J.exit_jalr] + jx[J.exit_stop]);
        try t.expect(jx[J.exit_side_region] > 500); // of 1000 side exits taken
        try t.expect(jx[J.exit_side_region] <= jx[J.exit_side]);
        // H's jalr reaches members only, so few jalr terminators leave
        try t.expect(jx[J.exit_jalr] < 100);
        try t.expect(jx[J.exit_stop] > 0); // the odd slices end mid-region
        for ([_]u64{ jx[J.exit_side], jx[J.exit_direct], jx[J.exit_jalr], jx[J.exit_stop] }, 0..) |n, row| {
            var sum: u64 = 0;
            for (jx[J.next_by + J.n_nx * row ..][0..J.n_nx]) |v| sum += v;
            try t.expect(sum <= n);
        }
        const side_never = jx[J.next_by + J.n_nx * @intFromEnum(jit.Xr.side) + @intFromEnum(jit.Nx.never)];
        try t.expect(side_never > 500);
    }
}

test "kwemu jit regions: a budget ending mid-region and huge budgets" {
    var d = try Duo.init(&.{
        &.{ addi(6, 6, 1), addi(6, 6, 1), addi(6, 6, 1), addi(6, 6, 1), addi(6, 6, 1) },
        &.{ addi(6, 6, 2), addi(6, 6, 2) },
        &.{addi(6, 6, 3)},
        &.{ addi(6, 6, 4), addi(6, 6, 4), addi(6, 6, 4) },
    }, 1);
    defer d.deinit();
    d.set(9, 100_000);
    // tiny slices first (every possible stop inside a member and between
    // members), then budgets far beyond max_jl
    for (1..400) |i| _ = try d.slice(1 + i % 13);
    _ = try d.slice(1 << 60);
    try t.expectEqual(@as(u64, 100_000), d.b.regs.x[5]);
    try checkJitSlots(&d.b);
}

test "kwemu jit regions: the irq word is polled within 64 instructions inside a region" {
    // T2 rings the doorbell in pass n, in compiled code (no hand-back near
    // it, so only the region's own polling can stop it; T0 keeps the irq
    // page in the write TLB).
    var d = try Duo.init(&.{
        &.{sw(0, 22, 8)},
        &.{addi(6, 6, 2)},
        &.{ branch(1, 5, 23, 8), sw(24, 22, 0), addi(6, 6, 3) },
        &.{addi(6, 6, 4)},
    }, 1);
    defer d.deinit();
    const n = 4002;
    d.set(9, 1 << 40);
    d.set(23, n);
    try t.expectEqual(@as(u32, EV_INTERRUPT), try d.slice(1 << 27));
    // instructions retired up to the store: passes 1..n-1, H and bne + sw of pass n
    var rang: u64 = 0;
    for (1..n) |i| rang += 6 + @as(u64, if (i & 3 == 2) 2 else 1) + 1;
    rang += 6 + 2;
    try t.expect(d.b.cpu.icount >= rang and d.b.cpu.icount - rang <= 64);
    try t.expectEqual(@as(u64, n), d.b.regs.x[5]);
    if (jit_on) try t.expect(jitStat(&d.b, "entries") < 1000); // the passes ran inside the region
    // and it continues where it stopped
    d.set(9, 5000);
    _ = try d.finish(1);
    try checkJitSlots(&d.b);
}

test "kwemu jit regions: precise fault, trap and hand-back in a member other than the entry" {
    // T1 loads from a page that is mapped on its first fault; T2 makes a
    // syscall in the middle of a pass; T3 hands an FP op back (static RTZ
    // rounding is not compiled).
    var d = try Duo.init(&.{
        &.{addi(6, 6, 1)},
        &.{ addi(6, 6, 2), ld(13, 25, 8), rtype(0x33, 0, 0, 6, 6, 13) },
        &.{ addi(6, 6, 3), addi(17, 0, 7), ecall, addi(6, 6, 3) },
        &.{ addi(6, 6, 4), rtype(0x53, 1, 1, 1, 1, 2), addi(6, 6, 4) },
    }, 1);
    defer d.deinit();
    d.set(9, 2000);
    var faults: u64 = 0;
    var syscalls: u64 = 0;
    var budget: u64 = 3;
    while (true) {
        budget = 1 + (budget * 31 + 7) % 5000;
        const ev = try d.slice(budget);
        if (ev == EV_FAULT) {
            faults += 1;
            try t.expectEqual(rgTarget(1) + 4, d.b.regs.pc); // at the load
        }
        if (ev == EV_SYSCALL) {
            if (d.b.regs.x[5] == 2000 and d.b.regs.pc != rgTarget(2) + 12) break;
            syscalls += 1;
            try t.expectEqual(rgTarget(2) + 12, d.b.regs.pc); // after the ecall
        }
    }
    try t.expectEqual(@as(u64, 1), faults);
    try t.expectEqual(@as(u64, 500), syscalls);
    try checkJitSlots(&d.b);
}

/// The decoded block at pc (either way of its set), if any.
fn blockAt(m: *Machine, pc: u64) ?*kwemu.Block {
    const set = kwemu.blockSet(pc);
    for (m.cpu.priv.blocks[set..][0..2]) |*b| if (b.pc == pc) return b;
    return null;
}

test "kwemu jit regions: integer and FP members: flags sticky across members, hand-back in an FP member, exact instret" {
    // T0 integer; T1 fadd.d (dynamic rounding) and fdiv.d 1/3 (NX);
    // T2 fadd.d, then fdiv.d by zero (handed back: the interpreter raises DZ),
    // reads and clears fflags, reads instret; T3 flt.d against a qNaN (NV),
    // fcvt.l.d (static RTZ) into x14. T2 sees the flags of T3 and T1, raised
    // in other members of the region two and one dispatches earlier.
    const fflags_read = itype(0x73, 2, 13, 0, 1); // csrrs x13, fflags, x0
    const fflags_clear = itype(0x73, 1, 0, 0, 1); // csrrw x0, fflags, x0
    var d = try Duo.init(&.{
        &.{addi(6, 6, 1)},
        &.{ fpR(0, 1, 7, 3, 3, 1), fpR(3, 1, 0, 4, 1, 2) },
        &.{ fpR(0, 1, 7, 8, 8, 1), fpR(3, 1, 0, 5, 1, 7), fflags_read, rtype(0x33, 0, 0, 10, 10, 13), fflags_clear, csrr_instret, rtype(0x33, 0, 0, 11, 11, 8) },
        &.{ fpR(0x14, 1, 1, 15, 1, 10), fpR(0x18, 1, 1, 14, 3, 2), rtype(0x33, 0, 0, 12, 12, 14) },
    }, 50);
    defer d.deinit();
    const n = 3000;
    d.set(9, n);
    d.setF(1, bitsD(1.0));
    d.setF(2, bitsD(3.0));
    d.setF(7, 0);
    d.setF(10, 0x7ff8_0000_0000_0000);
    d.setFcsr(0);
    const slices = try d.finish(5);
    try t.expect(slices > 20);
    // reference, pass by pass (pass i runs H, then T[i & 3])
    var ic: u64 = 0;
    var x10: u64 = 0;
    var x11: u64 = 0;
    var x12: u64 = 0;
    var t1: u64 = 0;
    var flags: u64 = 0;
    const lens = [_]u64{ 1, 2, 7, 3 };
    for (1..n + 1) |i| {
        ic += 6;
        switch (i & 3) {
            1 => {
                t1 += 1;
                flags |= 0x01; // NX
            },
            2 => {
                flags |= 0x08; // DZ
                x10 += flags;
                flags = 0;
                x11 +%= ic + 5;
            },
            3 => {
                flags |= 0x10; // NV
                x12 += t1;
            },
            else => {},
        }
        ic += lens[i & 3] + 1;
    }
    try t.expectEqual(x10, d.b.regs.x[10]);
    try t.expectEqual(x11, d.b.regs.x[11]);
    try t.expectEqual(x12, d.b.regs.x[12]);
    try t.expectEqual(bitsD(@floatFromInt(t1)), d.b.regs.f[3]);
    try t.expectEqual(bitsD(1.0 / 3.0), d.b.regs.f[4]);
    try t.expectEqual(@as(u64, 0x7ff0_0000_0000_0000), d.b.regs.f[5]);
    try t.expectEqual(@as(u32, @intCast(flags)), d.b.regs.fcsr);
    try t.expectEqual(ic + 1, d.b.cpu.icount); // + the final ecall
    if (jit_on) {
        // the FP members are compiled, in a region with another block
        for (1..4) |j| {
            const s = jit.slotOf(blockAt(&d.b, rgTarget(j)).?);
            try t.expect(s != 0);
            var shared = false;
            for (d.b.cpu.priv.jit.members[s - 1]) |mb| {
                if (mb != 0 and mb - 1 != kwemu.blockSet(rgTarget(j)) and mb - 1 != kwemu.blockSet(rgTarget(j)) + 1) shared = true;
            }
            try t.expect(shared);
        }
        try t.expect(jitStat(&d.b, "entries") < n);
    }
    try checkJitSlots(&d.b);
    // frm = RUP: the dynamic-rounding ops (first op of T1 and T2) hand back
    // at their member's own frm test, entered from `run` or from another
    // member; the static ones stay compiled. Same results as the interpreter.
    for ([_]u32{ 3, 1, 0 }) |frm| {
        d.set(5, 0);
        d.set(9, 1000);
        d.setFcsr(frm << 5);
        for ([_]*Machine{ &d.a, &d.b }) |m| m.regs.pc = rg_code;
        _ = try d.finish(17 + frm);
        try t.expectEqual(frm, d.b.regs.fcsr >> 5);
    }
    try checkJitSlots(&d.b);
}

test "kwemu jit regions: a self-loop keeps its own module when a block of its page compiles later" {
    // L: x5 += 1; bne x5, x6, L (a self-loop, hot first)
    // X: x7 += 1; x5 = 0; bne x7, x8, L; ecall (hot later; its side exit
    //    targets L, and L's module is the only one of the page)
    var m = try Machine.init();
    defer m.deinit();
    jitMode(&m, .threshold, 200);
    _ = m.code(0x10000, &.{ addi(5, 5, 1), branch(1, 5, 6, -4), addi(7, 7, 1), addi(5, 0, 0), branch(1, 7, 8, -16), ecall });
    m.regs.x[6] = 50;
    m.regs.x[8] = 400;
    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 30));
    try t.expectEqual(@as(u64, 400), m.regs.x[7]);
    try t.expectEqual(@as(u64, 400 * (50 * 2 + 3) + 1), m.cpu.icount);
    if (jit_on) {
        const l = blockAt(&m, 0x10000).?;
        const x = blockAt(&m, 0x10008).?;
        try t.expect(jit.slotOf(l) != 0 and jit.slotOf(x) != 0 and jit.slotOf(l) != jit.slotOf(x));
        var n: usize = 0;
        for (m.cpu.priv.jit.members[jit.slotOf(l) - 1]) |mb| n += @intFromBool(mb != 0);
        try t.expectEqual(@as(usize, 1), n);
    }
    try checkJitSlots(&m);
}

test "kwemu jit regions: a store into another member, the entry block or itself takes effect at the next instruction" {
    // T0 rewrites T3's first instruction (addi x6,x6,4 -> addi x6,x6,100)
    // in pass 1000; T1 rewrites H's andi (& 3 -> & 2: T1 and T3 are not
    // used any more) in pass 2001; T2 rewrites the instruction right after
    // its own store in pass 3002.
    const t3_old = addi(6, 6, 4);
    const t3_new = addi(6, 6, 100);
    const h_new = itype(0x13, 7, 7, 5, 2);
    const t2_old = addi(6, 6, 3);
    const t2_new = addi(6, 6, 1000);
    var d = try Duo.init(&.{
        &.{ branch(1, 5, 26, 8), sw(27, 28, @intCast(rgTarget(3) - rg_code)), addi(6, 6, 1) },
        &.{ branch(1, 5, 29, 8), sw(30, 28, 4), addi(6, 6, 2) },
        &.{ branch(1, 5, 31, 8), sw(21, 28, @intCast(rgTarget(2) - rg_code + 8)), t2_old },
        &.{t3_old},
    }, 1);
    defer d.deinit();
    d.set(9, 4000);
    d.set(28, rg_code);
    d.set(26, 1000);
    d.set(27, t3_new);
    d.set(29, 2001);
    d.set(30, h_new);
    d.set(31, 3002);
    d.set(21, t2_new);
    _ = try d.finish(11);
    // reference, pass by pass
    var x6: u64 = 0;
    var h3 = true;
    var t3 = t3_old;
    var t2 = t2_old;
    for (1..4001) |i| {
        const j = if (h3) i & 3 else i & 2;
        switch (j) {
            0 => {
                if (i == 1000) t3 = t3_new;
                x6 += 1;
            },
            1 => {
                if (i == 2001) h3 = false;
                x6 += 2;
            },
            2 => {
                if (i == 3002) t2 = t2_new;
                x6 += if (t2 == t2_new) 1000 else 3;
            },
            else => x6 += if (t3 == t3_new) 100 else 4,
        }
    }
    try t.expectEqual(x6, d.b.regs.x[6]);
    try checkJitSlots(&d.b);
}

test "kwemu jit regions: flushes, set_pgd and FENCE.I keep the code; a changed page recompiles; a re-decoded member leaves the rest" {
    var d = try Duo.init(&.{
        &.{addi(6, 6, 1)},
        &.{addi(6, 6, 2)},
        &.{addi(6, 6, 3)},
        &.{addi(6, 6, 4)},
    }, 1);
    defer d.deinit();
    d.set(9, 1000);
    // a guest FENCE.I on another page, then on to H
    for ([_]*Machine{ &d.a, &d.b }) |m| {
        const pa = m.frame();
        putCode(m, pa, 0, &.{ fence_i, jal(0, -0x40004) });
        m.map(0x50000, pa, R | X | U | A);
    }
    _ = try d.finish(3);
    const c0 = jitStat(&d.b, "compiles");
    for (0..4) |i| {
        for ([_]*Machine{ &d.a, &d.b }) |m| switch (i) {
            0 => m.cpu.flushAll(),
            1 => m.cpu.flushRange(rg_code, rg_code + 4096),
            2 => kwemu.setPgd(m.cpu, m.root),
            else => {},
        };
        d.set(5, 0);
        d.set(9, 1000);
        for ([_]*Machine{ &d.a, &d.b }) |m| m.regs.pc = if (i == 3) 0x50000 else rg_code;
        try t.expectEqual(@as(u32, EV_SYSCALL), try d.slice(1 << 40)); // no slice ends inside a block: no new blocks
        // revalidated, not recompiled (FENCE.I ends its block: the jal after
        // it is a block of its own, compiled once)
        try t.expectEqual(c0 + @intFromBool(i == 3 and jit_on), jitStat(&d.b, "compiles"));
    }
    // The kernel rewrites T2 (+3 -> +30) and flushes: only T2 is re-decoded;
    // the other members keep their code and the region.
    for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
        putCode(m, d.code_pa[k], rgTarget(2) - rg_code, &.{addi(6, 6, 30)});
        m.cpu.flushRange(rg_code, rg_code + 4096);
        m.regs.pc = rg_code;
    }
    d.set(5, 0);
    d.set(6, 0);
    d.set(9, 1000);
    if (jit_on) d.b.cpu.priv.jit.threshold = 1 << 20; // T2 stays interpreted
    _ = try d.finish(9);
    try t.expectEqual(@as(u64, 250 * (1 + 2 + 30 + 4)), d.b.regs.x[6]);
    if (jit_on) {
        try t.expectEqual(c0 + 1, jitStat(&d.b, "compiles"));
        var compiled: usize = 0;
        for (0..4) |j| {
            const b = &d.b.cpu.priv.blocks[kwemu.blockSet(rgTarget(j))];
            const b1 = &d.b.cpu.priv.blocks[kwemu.blockSet(rgTarget(j)) + 1];
            if (jit.slotOf(if (b.pc == rgTarget(j)) b else b1) != 0) compiled += 1;
        }
        try t.expectEqual(@as(usize, 3), compiled);
    }
    try checkJitSlots(&d.b);
    // COW: the whole page copied with a change, remapped, flushed: new code
    for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
        const copy = m.frame();
        @memcpy(m.bytes(copy), m.bytes(d.code_pa[k]));
        putCode(m, copy, rgTarget(0) - rg_code, &.{addi(6, 6, 10)});
        m.map(rg_code, copy, RWX);
        m.cpu.flushRange(rg_code, rg_code + 4096);
        m.regs.pc = rg_code;
    }
    if (jit_on) d.b.cpu.priv.jit.threshold = 1;
    d.set(5, 0);
    d.set(6, 0);
    d.set(9, 1000);
    _ = try d.finish(4);
    try t.expectEqual(@as(u64, 250 * (10 + 2 + 30 + 4)), d.b.regs.x[6]);
    try checkJitSlots(&d.b);
}

test "kwemu jit regions: a region that does not fit the emit buffer is cut and closed" {
    // Eight targets of 58 loads and stores each (with H, over 16 KiB of
    // wasm); then the same with FP loads, FMAs (more than inline: helper
    // functions) and FP stores.
    for ([_]bool{ false, true }) |fp| {
        var big: [8][58]u32 = undefined;
        for (&big, 0..) |*body, j| for (body, 0..) |*w, i| {
            w.* = if (!fp)
                (if (i % 2 == 0) ld(13, 20, @intCast(8 * (i % 64))) else sd(13, 20, @intCast(256 + 8 * j)))
            else switch (i % 3) {
                0 => fld(5, 20, @intCast(256 + 8 * (i % 32))),
                1 => fpR4(if (j % 2 == 0) 0x43 else 0x4b, @intCast(j % 2), 7, 4, 2, 3, 4),
                else => fsd(4, 20, @intCast(512 + 8 * j)),
            };
        };
        var d = try Duo.init(&.{ &big[0], &big[1], &big[2], &big[3], &big[4], &big[5], &big[6], &big[7] }, 200);
        defer d.deinit();
        d.set(9, 2000);
        d.setF(2, bitsD(1.5));
        d.setF(3, bitsD(0.75));
        _ = try d.finish(7);
        if (jit_on) {
            var closed: usize = 0;
            for (d.b.cpu.priv.jit.owner, d.b.cpu.priv.jit.page) |o, p| {
                if (o != 0 and p >> 63 != 0) closed += 1;
            }
            try t.expect(closed > 0);
            try t.expectEqual(@as(u64, 0), jitStat(&d.b, "fails"));
            try t.expect(jitStat(&d.b, "compiles") < 40); // no recompile churn
            try t.expect(jitStat(&d.b, "max_bytes") <= jit.buf_size);
            if (fp) std.debug.print("[jit] FP region cut to fit: {d} compiles, {d} member blocks, {d} re-emits, largest module {d} bytes\n", .{
                jitStat(&d.b, "compiles"), jitStat(&d.b, "members_total"), jitStat(&d.b, "shortened"), jitStat(&d.b, "max_bytes"),
            });
        }
        try checkJitSlots(&d.b);
    }
}

// Regions across two code pages: A (0x10000) calls into B (0x11000), and B
// returns into A:
//   A+0:  L:  addi x5,x5,1; (`heavy`: 5 x addi x10,x10,1;) jal x1, F
//   A+n:  R:  bne x5,x9, L; ecall; jal x0, L        (the return site)
//   B+0:  F:  addi x6,x6,1; andi x7,x5,1; beq x7,x0, F2; jalr x0, 0(x1)
//   B+64: F2: addi x6,x6,2; jalr x0, 0(x1)
// With a heavy L, L gets hot first and its region takes R, F and F2 as
// members of its own (found from L's call). With a light L, F gets hot
// first (a region with F2), L's region starts with R, and F and F2 join it
// as guests once enough of its exits lead there (growth along exits).
const xp_a: u64 = 0x10000;
const xp_b: u64 = 0x11000;

fn xpDuo(heavy: bool, grow: u32) !Duo {
    var d: Duo = .{ .a = try Machine.init(), .b = try Machine.init() };
    for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
        const pa = m.frame();
        const pb = m.frame();
        var code: [12]u32 = undefined;
        var n: usize = 0;
        code[n] = addi(5, 5, 1);
        n += 1;
        if (heavy) for (0..5) |_| {
            code[n] = addi(10, 10, 1);
            n += 1;
        };
        const ro: i32 = @intCast(4 * (n + 1)); // offset of R
        code[n] = jal(1, @intCast(@as(i64, xp_b) - @as(i64, @intCast(xp_a + 4 * n))));
        n += 1;
        code[n] = branch(1, 5, 9, -ro);
        code[n + 1] = ecall;
        code[n + 2] = jal(0, -(ro + 8));
        n += 3;
        putCode(m, pa, 0, code[0..n]);
        putCode(m, pb, 0, &.{ addi(6, 6, 1), itype(0x13, 7, 7, 5, 1), branch(0, 7, 0, 56), itype(0x67, 0, 0, 1, 0) });
        putCode(m, pb, 64, &.{ addi(6, 6, 2), itype(0x67, 0, 0, 1, 0) });
        m.map(xp_a, pa, RWX);
        m.map(xp_b, pb, RWX);
        const irq = m.frame();
        m.map(rg_irq, irq, R | W | U | A | D);
        m.cpu.irq_pending = @ptrCast(@alignCast(m.bytes(irq).ptr));
        d.code_pa[k] = pa;
        d.demand_pa[k] = pb; // page B's frame
        d.irq_pa[k] = irq;
        m.cpu.flushAll();
        m.regs.pc = xp_a;
    }
    jitMode(&d.a, .off, 0);
    jitMode(&d.b, .threshold, 200);
    if (jit_on) d.b.cpu.priv.jit.grow_threshold = grow;
    return d;
}

fn xpRestart(d: *Duo, n: u64) void {
    d.set(5, 0);
    d.set(6, 0);
    d.set(9, n);
    for ([_]*Machine{ &d.a, &d.b }) |m| m.regs.pc = xp_a;
}

/// L and F share a module; branches into the other page happened (stats).
fn xpShared(d: *Duo) !void {
    if (!jit_on) return;
    const l = blockAt(&d.b, xp_a).?;
    const f = blockAt(&d.b, xp_b).?;
    const s = jit.slotOf(l);
    try t.expect(s != 0);
    var has_f = false;
    for (d.b.cpu.priv.jit.members[s - 1]) |m| has_f = has_f or (m != 0 and &d.b.cpu.priv.blocks[m - 1] == f);
    try t.expect(has_f);
    if (kwemu.stats_on) try t.expect(d.b.cpu.priv.stats.jit.jx[jit.Jx.region_cross] > 0);
}

test "kwemu jit regions across pages: calls and returns stay in one module; flushing, rewriting, remapping or unmapping one page" {
    for ([_]bool{ true, false }) |heavy| {
        var d = try xpDuo(heavy, if (heavy) std.math.maxInt(u32) else 4);
        defer d.deinit();
        xpRestart(&d, 3000);
        _ = try d.finish(5);
        try t.expectEqual(@as(u64, 3000 + 1500 * 2), d.b.regs.x[6]);
        try xpShared(&d);
        if (jit_on) try t.expectEqual(@as(u64, @intFromBool(!heavy)), @intFromBool(jitStat(&d.b, "exit_grows") > 0));
        try checkJitSlots(&d.b);
        // Flushing either page, or both, only revalidates: nothing is
        // recompiled, and the members on the other page keep their code.
        const c0 = jitStat(&d.b, "compiles");
        for (0..3) |i| {
            for ([_]*Machine{ &d.a, &d.b }) |m| switch (i) {
                0 => m.cpu.flushRange(xp_b, xp_b + 4096),
                1 => m.cpu.flushRange(xp_a, xp_a + 4096),
                else => kwemu.setPgd(m.cpu, m.root),
            };
            xpRestart(&d, 1000);
            try t.expectEqual(@as(u32, EV_SYSCALL), try d.slice(1 << 40));
            if (heavy) try t.expectEqual(c0, jitStat(&d.b, "compiles")); // growth may still add a member
            try t.expectEqual(@as(u64, 1000 + 500 * 2), d.b.regs.x[6]);
        }
        try xpShared(&d);
        // The kernel rewrites F2 in page B (+2 -> +20) and flushes page B.
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            putCode(m, d.demand_pa[k], 64, &.{addi(6, 6, 20)});
            m.cpu.flushRange(xp_b, xp_b + 4096);
        }
        xpRestart(&d, 3000);
        _ = try d.finish(7);
        try t.expectEqual(@as(u64, 3000 + 1500 * 20), d.b.regs.x[6]);
        try checkJitSlots(&d.b);
        // COW: page B is copied with F changed (+1 -> +10), remapped, flushed.
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            const copy = m.frame();
            @memcpy(m.bytes(copy), m.bytes(d.demand_pa[k]));
            putCode(m, copy, 0, &.{addi(6, 6, 10)});
            m.map(xp_b, copy, RWX);
            m.cpu.flushRange(xp_b, xp_b + 4096);
            d.demand_pa[k] = copy;
        }
        xpRestart(&d, 3000);
        _ = try d.finish(9);
        try t.expectEqual(@as(u64, 3000 * 10 + 1500 * 20), d.b.regs.x[6]);
        try checkJitSlots(&d.b);
        // Page B unmapped: the next call into it faults (exact pc and
        // icount on both), then it is mapped again.
        xpRestart(&d, 3000);
        _ = try d.slice(5000);
        for ([_]*Machine{ &d.a, &d.b }) |m| {
            m.slot(xp_b).* = 0;
            m.cpu.flushRange(xp_b, xp_b + 4096);
        }
        try t.expectEqual(@as(u32, EV_FAULT), try d.slice(1 << 40));
        try t.expectEqual(xp_b >> 12, d.b.cpu.ev.addr >> 12);
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            m.map(xp_b, d.demand_pa[k], RWX);
            m.cpu.flushRange(xp_b, xp_b + 4096);
        }
        _ = try d.finish(11);
        try t.expectEqual(@as(u64, 3000 * 10 + 1500 * 20), d.b.regs.x[6]);
        try xpShared(&d);
        try checkJitSlots(&d.b);
    }
}

// jalr into region members (checked entries), two code pages:
//   A+0:  L:  addi x5,x5,1; andi x7,x5,1; slli x7,x7,6; add x11,x20,x7;
//             beq x5,x13, S; C: jalr x1, 0(x11)      (calls F or G in turn)
//   A+24: R:  bne x5,x9, L; ecall; jal x0, L
//   A+40: S:  sw x14, 64(x20); jal x0, C           (rewrites G's first insn)
//   B+0:  F:  addi x6,x6,1; addi x12,x1,0; jalr x1, 128(x20)
//   B+12: F2: addi x6,x6,3; jalr x1, 128(x20)
//   B+20: F3: addi x6,x6,5; jalr x0, 0(x12)
//   B+64: G:  addi x6,x6,7; jalr x0, 0(x1)
//   B+128: H: addi x6,x6,100; sw x15, 0(x21); jalr x0, 0(x1)
//                                    (returns to F2 or F3; x21 = the irq word)
//   C+0:   P: addi x6,x6,2; jal x0, D
//   C+12:  D: addi x6,x6,1; sw x15, 0(x21); jalr x0, 12(x23)    (to itself)
// The indirect call's target alternates every iteration and H returns to two
// sites, so every jalr's target changes from one execution to the next; the
// guest's store into G (in iteration x13) and the kernel's rewrite of H
// must stop the copies of G and H that other modules hold.
const jr_a: u64 = 0x10000;
const jr_b: u64 = 0x11000;
const jr_c: u64 = 0x12000;

fn jrDuo(grow: u32) !Duo {
    var d: Duo = .{ .a = try Machine.init(), .b = try Machine.init() };
    for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
        const pa = m.frame();
        const pb = m.frame();
        putCode(m, pa, 0, &.{
            addi(5, 5, 1),          itype(0x13, 7, 7, 5, 1),          itype(0x13, 1, 7, 7, 6), rtype(0x33, 0, 0, 11, 20, 7),
            branch(0, 5, 13, 24),   itype(0x67, 0, 1, 11, 0),         branch(1, 5, 9, -24),    ecall,
            jal(0, -32),            0,                                sw(14, 20, 64),          jal(0, -24),
        });
        putCode(m, pb, 0, &.{ addi(6, 6, 1), addi(12, 1, 0), itype(0x67, 0, 1, 20, 128), addi(6, 6, 3), itype(0x67, 0, 1, 20, 128), addi(6, 6, 5), itype(0x67, 0, 0, 12, 0) });
        putCode(m, pb, 64, &.{ addi(6, 6, 7), itype(0x67, 0, 0, 1, 0) });
        putCode(m, pb, 128, &.{ addi(6, 6, 100), sw(15, 21, 0), itype(0x67, 0, 0, 1, 0) });
        const pc = m.frame();
        putCode(m, pc, 0, &.{ addi(6, 6, 2), jal(0, 8), 0, addi(6, 6, 1), sw(15, 21, 0), itype(0x67, 0, 0, 23, 12) });
        m.map(jr_c, pc, RWX);
        m.map(jr_a, pa, RWX);
        m.map(jr_b, pb, RWX);
        const irq = m.frame();
        m.map(rg_irq, irq, R | W | U | A | D);
        m.cpu.irq_pending = @ptrCast(@alignCast(m.bytes(irq).ptr));
        d.code_pa[k] = pa;
        d.demand_pa[k] = pb; // page B's frame
        d.irq_pa[k] = irq;
        m.cpu.flushAll();
        m.regs.x[20] = jr_b;
        m.regs.x[14] = addi(6, 6, 11);
        m.regs.x[21] = rg_irq;
        m.regs.x[23] = jr_c;
    }
    jitMode(&d.a, .off, 0);
    jitMode(&d.b, .threshold, 200);
    if (jit_on) d.b.cpu.priv.jit.grow_threshold = grow;
    return d;
}

fn jrRestart(d: *Duo, n: u64, smc_at: u64) void {
    d.set(5, 0);
    d.set(6, 0);
    d.set(9, n);
    d.set(13, smc_at);
    for ([_]*Machine{ &d.a, &d.b }) |m| m.regs.pc = jr_a;
}

/// x6 after n iterations: F (even) adds 1 + h + 3 + h + 5, G (odd) adds g.
fn jrSum(n: u64, h: u64, g: u64) u64 {
    return (n / 2) * (9 + 2 * h) + ((n + 1) / 2) * g;
}

/// Whether the module of L holds F, G and H too.
fn jrShared(m: *Machine) bool {
    const s = jit.slotOf(blockAt(m, jr_a) orelse return false);
    if (s == 0) return false;
    var n: usize = 0;
    for ([_]u64{ jr_b, jr_b + 64, jr_b + 128 }) |pc| {
        const b = blockAt(m, pc) orelse return false;
        for (m.cpu.priv.jit.members[s - 1]) |x| n += @intFromBool(x != 0 and &m.cpu.priv.blocks[x - 1] == b);
    }
    return n == 3;
}

test "kwemu jit regions: jalr into members: changing targets, a member rewritten by a guest store or the kernel, its page unmapped" {
    for ([_]u32{ 4, std.math.maxInt(u32) }) |grow| {
        var d = try jrDuo(grow);
        defer d.deinit();
        jrRestart(&d, 4001, 1 << 40);
        _ = try d.finish(3);
        try t.expectEqual(jrSum(4001, 100, 7), d.b.regs.x[6]);
        if (jit_on and grow == 4) {
            try t.expect(jrShared(&d.b));
            if (kwemu.stats_on) try t.expect(d.b.cpu.priv.stats.jit.jx[jit.Jx.region_hops] > 4 * 4001 / 2);
        }
        try checkJitSlots(&d.b);
        // Warm, in one slice: the jalrs stay in the module (`entries` counts
        // the calls from `run` into compiled code; every iteration has two
        // or five jalrs).
        jrRestart(&d, 4001, 1 << 40);
        const entries0 = jitStat(&d.b, "entries");
        try t.expectEqual(@as(u32, EV_SYSCALL), try d.slice(1 << 40));
        try t.expectEqual(jrSum(4001, 100, 7), d.b.regs.x[6]);
        if (jit_on and grow == 4) try t.expect(jitStat(&d.b, "entries") - entries0 < 64);
        // H raises an interrupt (x15 = 1) on each of its 400 calls: the
        // member it returns to must not start (`slice` compares pc and
        // icount with the interpreter's, and acknowledges).
        jrRestart(&d, 401, 1 << 40);
        d.set(15, 1);
        var irqs: u32 = 0;
        while (try d.slice(1 << 40) == EV_INTERRUPT) irqs += 1;
        try t.expectEqual(@as(u32, 400), irqs);
        try t.expectEqual(jrSum(401, 100, 7), d.b.regs.x[6]);
        // D jumps to its own start, in a region with P: only the budget
        // stops it (without that test in the jalr to itself, this does not
        // return). With x15 = 1, D's interrupt stops it after one pass.
        d.set(15, 0);
        for (0..40) |k| {
            for ([_]*Machine{ &d.a, &d.b }) |m| m.regs.pc = jr_c;
            try t.expectEqual(@as(u32, EV_BUDGET), try d.slice(100 + 37 * k));
        }
        for ([_]*Machine{ &d.a, &d.b }) |m| m.regs.pc = jr_c;
        d.set(15, 1);
        const ic0 = d.b.cpu.icount;
        try t.expectEqual(@as(u32, EV_INTERRUPT), try d.slice(100_000));
        try t.expectEqual(@as(u64, 5), d.b.cpu.icount - ic0);
        d.set(15, 0);
        try checkJitSlots(&d.b);
        // The guest rewrites G (+7 -> +11) in iteration 2001.
        jrRestart(&d, 4001, 2001);
        _ = try d.finish(5);
        try t.expectEqual(jrSum(2000, 100, 7) + jrSum(2001, 100, 11), d.b.regs.x[6]);
        try checkJitSlots(&d.b);
        // The kernel rewrites H (+100 -> +1000) and flushes page B.
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            putCode(m, d.demand_pa[k], 128, &.{addi(6, 6, 1000)});
            m.cpu.flushRange(jr_b, jr_b + 4096);
        }
        jrRestart(&d, 4001, 1 << 40);
        _ = try d.finish(7);
        try t.expectEqual(jrSum(4001, 1000, 11), d.b.regs.x[6]);
        try checkJitSlots(&d.b);
        // Page B unmapped in the middle: the next jalr into it faults with
        // the exact pc and icount on both; mapped again, it finishes.
        jrRestart(&d, 4001, 1 << 40);
        _ = try d.slice(7777);
        for ([_]*Machine{ &d.a, &d.b }) |m| {
            m.slot(jr_b).* = 0;
            m.cpu.flushRange(jr_b, jr_b + 4096);
        }
        try t.expectEqual(@as(u32, EV_FAULT), try d.slice(1 << 40));
        try t.expectEqual(jr_b >> 12, d.b.cpu.ev.addr >> 12);
        for ([_]*Machine{ &d.a, &d.b }, 0..) |m, k| {
            m.map(jr_b, d.demand_pa[k], RWX);
            m.cpu.flushRange(jr_b, jr_b + 4096);
        }
        _ = try d.finish(11);
        try t.expectEqual(jrSum(4001, 1000, 11), d.b.regs.x[6]);
        if (jit_on and grow == 4) try t.expect(jrShared(&d.b));
        try checkJitSlots(&d.b);
    }
}

test "kwemu jit regions: more regions than pool slots: clock eviction stays consistent" {
    // 1100 virtual pages map one physical page holding a call into a leaf
    // and a return to the dispatcher (two blocks: a region per page):
    //   0: jal x1, +8; 4: jalr x0, 0(x10); 8: addi x5,x5,1; 12: jalr x0, 0(x1)
    var m = try Machine.initSize(2 << 20);
    defer m.deinit();
    const pa = m.frame();
    putCode(&m, pa, 0, &.{ jal(1, 8), itype(0x67, 0, 0, 10, 0), addi(5, 5, 1), itype(0x67, 0, 0, 1, 0) });
    const npages = 1100;
    for (0..npages) |i| m.map(0x1000000 + i * 4096, pa, R | X | U | A);
    // D: jalr x10, 0(x6); x6 += 4096; bne x6, x7, D; ecall
    _ = m.code(0x10000, &.{ itype(0x67, 0, 10, 6, 0), addi(6, 6, 2047), addi(6, 6, 2047), addi(6, 6, 2), branch(1, 6, 7, -16), ecall });
    for (0..3) |pass| {
        m.regs.x[5] = 0;
        m.regs.x[6] = 0x1000000;
        m.regs.x[7] = 0x1000000 + npages * 4096;
        m.regs.pc = 0x10000;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 30));
        try t.expectEqual(@as(u64, npages), m.regs.x[5]);
        try checkJitSlots(&m);
        _ = pass;
    }
    if (jit_on) {
        try t.expect(jitStat(&m, "evictions") > 0);
        try t.expect(jitStat(&m, "grows") > 0);
        try t.expect(jitStat(&m, "members_total") > jitStat(&m, "compiles"));
    }
}

// ---- optional ISA extensions (core.Ext, kw_set_isa) ------------------------------

/// One instruction per optional extension that only that extension (or
/// `alt`) defines; rd = a0, rs1 = a0, rs2 = a1, fd = fa0, a0 the address of
/// a writable page. A compressed probe is followed by c.nop in the same
/// word. kwtest.c has the same list.
const isa_probes = [_]struct { ext: core.Ext, alt: ?core.Ext = null, insn: u32 }{
    .{ .ext = .zba, .insn = 0x20b52533 }, // sh1add
    .{ .ext = .zbb, .insn = 0x60051513 }, // clz
    .{ .ext = .zbc, .insn = 0x0ab52533 }, // clmulr
    .{ .ext = .zbs, .insn = 0x28b51533 }, // bset
    .{ .ext = .zbkb, .insn = 0x08b54533 }, // pack
    .{ .ext = .zbkc, .alt = .zbc, .insn = 0x0ab51533 }, // clmul
    .{ .ext = .zbkx, .insn = 0x28b54533 }, // xperm8
    .{ .ext = .zknd, .insn = 0x3ab50533 }, // aes64ds
    .{ .ext = .zkne, .insn = 0x32b50533 }, // aes64es
    .{ .ext = .zicond, .insn = 0x0eb55533 }, // czero.eqz
    .{ .ext = .zcb, .insn = 0x0001_9d75 }, // c.not a0; c.nop
    .{ .ext = .zimop, .insn = 0x81c54573 }, // mop.r.0 a0, a0
    .{ .ext = .zcmop, .insn = 0x0001_6081 }, // c.mop.1; c.nop
    .{ .ext = .zicbom, .insn = 0x0015200f }, // cbo.clean (a0)
    .{ .ext = .zicboz, .insn = 0x0045200f }, // cbo.zero (a0)
    .{ .ext = .zawrs, .insn = 0x00d00073 }, // wrs.nto
    .{ .ext = .zfa, .insn = 0xf2180553 }, // fli.d fa0, 1.0
    .{ .ext = .zfhmin, .insn = 0xf4050553 }, // fmv.h.x fa0, a0
    .{ .ext = .zihpm, .insn = 0xc0302573 }, // csrr a0, hpmcounter3
};

test "kwemu isa: an extension that is not implemented or not enabled raises illegal instruction" {
    comptime std.debug.assert(isa_probes.len == @typeInfo(core.Ext).@"enum".field_names.len);
    var m = try Machine.init();
    defer m.deinit();
    // kw_cpu_init enables everything implemented; kw_set_isa keeps only that.
    try t.expectEqual(core.implemented, m.cpu.priv.hart.isa);
    try t.expectEqual(core.implemented, kwemu.setIsa(m.cpu, std.math.maxInt(u64)));
    try t.expectEqual(@as(u64, 0), kwemu.setIsa(m.cpu, 0));
    m.map(0x20000, m.frame(), R | W | U | A | D);
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (isa_probes) |p| {
            const own = core.bit(p.ext) | (if (p.alt) |a| core.bit(a) else 0);
            for ([_]u64{ std.math.maxInt(u64), 0, ~own, own }) |want| {
                jitMode(&m, mode, 0);
                const on = kwemu.setIsa(m.cpu, want);
                try t.expectEqual(want & core.implemented, on);
                try t.expectEqual(@as(u64, 0), m.cpu.priv.ops_used); // decoded code dropped
                // a hot loop around the probe, so an eager JIT compiles it
                m.regs.x[5] = 0;
                m.regs.x[6] = 100;
                m.regs.x[10] = 0x20000;
                _ = m.code(0x10000, &.{ addi(5, 5, 1), p.insn, branch(1, 5, 6, -8), ecall });
                const ic = m.cpu.icount;
                if (on & own != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                    try t.expectEqual(@as(u64, 100), m.regs.x[5]);
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, if (p.insn & 3 == 3) p.insn else p.insn & 0xffff), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
                    try t.expectEqual(ic + 1, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}

test "kwemu isa: hints are no-ops (Zihintpause, Zihintntl, Zicbop) and the counters read instret (Zicntr)" {
    var m = try Machine.init();
    defer m.deinit();
    const code = [_]u32{
        0x0100000f, // pause
        0x00200033, 0x00300033, 0x00400033, 0x00500033, // ntl.p1, ntl.pall, ntl.s1, ntl.all
        0x00056013, 0x00156013, 0x00356013, // prefetch.i/r/w 0(a0)
        0x900e900a, 0x90169012, // c.ntl.p1, c.ntl.pall, c.ntl.s1, c.ntl.all
        0xc0002673, // rdcycle a2
        0xc01026f3, // rdtime a3
        0xc0202773, // rdinstret a4
        ecall,
    };
    for ([_]JitMode{ .off, .eager }) |mode| {
        jitMode(&m, mode, 0);
        var want: Regs = .{};
        for (1..32) |i| want.x[i] = 0x1111 *% i;
        m.regs = want;
        _ = m.code(0x10000, &code);
        const ic = m.cpu.icount;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1000));
        // 8 + 4 instructions before rdcycle; each counter read sees the ones before it
        want.x[12] = ic + 12;
        want.x[13] = ic + 13;
        want.x[14] = ic + 14;
        try t.expectEqualSlices(u64, &want.x, &m.regs.x);
        try t.expectEqual(@as(u64, 0x10000 + code.len * 4), m.regs.pc);
        try t.expectEqual(ic + 16, m.cpu.icount);
    }
}

// ---- Zkne / Zknd (scalar AES) ----------------------------------------------------

const aes = core.aes;

fn aesR(f7: u32, rd: u32, rs1: u32, rs2: u32) u32 {
    return rtype(0x33, 0, f7, rd, rs1, rs2);
}
fn aesIm(rd: u32, rs1: u32) u32 {
    return itype(0x13, 1, rd, rs1, 0x300);
}
fn aesKs1i(rd: u32, rs1: u32, rnum: u32) u32 {
    return itype(0x13, 1, rd, rs1, @intCast(0x310 | rnum));
}

fn le64(b: *const [16]u8, half: usize) u64 {
    return std.mem.readInt(u64, b[8 * half ..][0..8], .little);
}
fn hexBytes(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

/// The AES key schedule and cipher as OpenSSL's riscv64 Zkn code does it,
/// one u64 pair per round key.
const AesRef = struct {
    rk: [15][2]u64 = undefined,
    nr: usize,

    fn init(key: []const u8) AesRef {
        var k: AesRef = .{ .nr = if (key.len == 16) 10 else 14 };
        var w: [4]u64 = undefined;
        for (0..key.len / 8) |i| w[i] = std.mem.readInt(u64, key[8 * i ..][0..8], .little);
        k.rk[0] = .{ w[0], w[1] };
        if (key.len == 16) {
            for (0..10) |i| {
                const tmp = aes.ks1i(w[1], @intCast(i));
                w[0] = aes.ks2(tmp, w[0]);
                w[1] = aes.ks2(w[0], w[1]);
                k.rk[i + 1] = .{ w[0], w[1] };
            }
        } else {
            k.rk[1] = .{ w[2], w[3] };
            var rr: usize = 2;
            var i: u4 = 0;
            while (rr <= 14) : (i += 1) {
                w[0] = aes.ks2(aes.ks1i(w[3], i), w[0]);
                w[1] = aes.ks2(w[0], w[1]);
                k.rk[rr] = .{ w[0], w[1] };
                rr += 1;
                if (rr > 14) break;
                w[2] = aes.ks2(aes.ks1i(w[1], 0xa), w[2]);
                w[3] = aes.ks2(w[2], w[3]);
                k.rk[rr] = .{ w[2], w[3] };
                rr += 1;
            }
        }
        return k;
    }

    fn encrypt(k: *const AesRef, in: [16]u8) [16]u8 {
        var s0 = le64(&in, 0) ^ k.rk[0][0];
        var s1 = le64(&in, 1) ^ k.rk[0][1];
        for (1..k.nr) |rd| {
            const n0 = aes.esm(s0, s1);
            const n1 = aes.esm(s1, s0);
            s0 = n0 ^ k.rk[rd][0];
            s1 = n1 ^ k.rk[rd][1];
        }
        const n0 = aes.es(s0, s1) ^ k.rk[k.nr][0];
        const n1 = aes.es(s1, s0) ^ k.rk[k.nr][1];
        var out: [16]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], n0, .little);
        std.mem.writeInt(u64, out[8..16], n1, .little);
        return out;
    }

    /// The equivalent inverse cipher (round keys through aes64im).
    fn decrypt(k: *const AesRef, in: [16]u8) [16]u8 {
        var s0 = le64(&in, 0) ^ k.rk[k.nr][0];
        var s1 = le64(&in, 1) ^ k.rk[k.nr][1];
        var rd = k.nr - 1;
        while (rd >= 1) : (rd -= 1) {
            const n0 = aes.dsm(s0, s1);
            const n1 = aes.dsm(s1, s0);
            s0 = n0 ^ aes.im(k.rk[rd][0]);
            s1 = n1 ^ aes.im(k.rk[rd][1]);
        }
        const n0 = aes.ds(s0, s1) ^ k.rk[0][0];
        const n1 = aes.ds(s1, s0) ^ k.rk[0][1];
        var out: [16]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], n0, .little);
        std.mem.writeInt(u64, out[8..16], n1, .little);
        return out;
    }
};

test "kwemu aes: FIPS-197 vectors for each instruction and the whole cipher" {
    // S-box spot values (FIPS-197 figure 7 and 14)
    try t.expectEqual(@as(u8, 0x63), aes.sbox[0x00]);
    try t.expectEqual(@as(u8, 0x7c), aes.sbox[0x01]);
    try t.expectEqual(@as(u8, 0xed), aes.sbox[0x53]);
    try t.expectEqual(@as(u8, 0x16), aes.sbox[0xff]);
    try t.expectEqual(@as(u8, 0x52), aes.inv_sbox[0x00]);
    try t.expectEqual(@as(u8, 0x53), aes.inv_sbox[0xed]);
    // FIPS-197 appendix B, round 1: start, after SubBytes+ShiftRows, after MixColumns
    const start = hexBytes("193de3bea0f4e22b9ac68d2ae9f84808");
    const sr = hexBytes("d4bf5d30e0b452aeb84111f11e2798e5");
    const mc = hexBytes("046681e5e0cb199a48f8d37a2806264c");
    for (0..2) |h| {
        // the low half from (s0, s1), the high half from (s1, s0)
        const a = le64(&start, h);
        const b = le64(&start, 1 - h);
        try t.expectEqual(le64(&sr, h), aes.es(a, b));
        try t.expectEqual(le64(&mc, h), aes.esm(a, b));
        try t.expectEqual(le64(&start, h), aes.ds(le64(&sr, h), le64(&sr, 1 - h)));
        try t.expectEqual(le64(&sr, h), aes.im(le64(&mc, h)));
    }
    // key expansion, round 1 (aes64ks1i + aes64ks2) and the round-1 output
    const key = hexBytes("2b7e151628aed2a6abf7158809cf4f3c");
    const rk1 = hexBytes("a0fafe1788542cb123a339392a6c7605");
    const tmp = aes.ks1i(le64(&key, 1), 0);
    const k0 = aes.ks2(tmp, le64(&key, 0));
    try t.expectEqual(le64(&rk1, 0), k0);
    try t.expectEqual(le64(&rk1, 1), aes.ks2(k0, le64(&key, 1)));
    // rnum 10: SubWord without RotWord or a round constant
    try t.expectEqual(@as(u64, 0x167c6363_167c6363), aes.ks1i(0xff01_0000_0000_0000, 0xa));
    // whole cipher: appendix B (AES-128), C.1 (AES-128), C.3 (AES-256)
    const cases = [_]struct { key: []const u8, pt: [16]u8, ct: [16]u8 }{
        .{ .key = &key, .pt = hexBytes("3243f6a8885a308d313198a2e0370734"), .ct = hexBytes("3925841d02dc09fbdc118597196a0b32") },
        .{ .key = &hexBytes("000102030405060708090a0b0c0d0e0f"), .pt = hexBytes("00112233445566778899aabbccddeeff"), .ct = hexBytes("69c4e0d86a7b0430d8cdb78070b4c55a") },
        .{ .key = &hexBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), .pt = hexBytes("00112233445566778899aabbccddeeff"), .ct = hexBytes("8ea2b7ca516745bfeafc49904b496089") },
    };
    for (cases) |c| {
        const k = AesRef.init(c.key);
        try t.expectEqualSlices(u8, &c.ct, &k.encrypt(c.pt));
        try t.expectEqualSlices(u8, &c.pt, &k.decrypt(c.ct));
    }
    // inverse relations over random operands
    var prng = std.Random.DefaultPrng.init(0xae5);
    const rnd = prng.random();
    for (0..10000) |_| {
        const a = rnd.int(u64);
        const b = rnd.int(u64);
        try t.expectEqual(a, aes.ds(aes.es(a, b), aes.es(b, a)));
        try t.expectEqual(aes.es(a, b), aes.im(aes.esm(a, b)));
        try t.expectEqual(aes.im(aes.ds(a, b)), aes.dsm(a, b));
    }
}

test "kwemu aes: encodings, gates (ks1i/ks2 need either extension), reserved rnum 11..15" {
    var m = try Machine.init();
    defer m.deinit();
    const zkne = core.bit(.zkne);
    const zknd = core.bit(.zknd);
    const Probe = struct { insn: u32, need: u64 };
    const probes = [_]Probe{
        .{ .insn = aesR(0x19, 10, 10, 11), .need = zkne }, // aes64es
        .{ .insn = aesR(0x1b, 10, 10, 11), .need = zkne }, // aes64esm
        .{ .insn = aesR(0x1d, 10, 10, 11), .need = zknd }, // aes64ds
        .{ .insn = aesR(0x1f, 10, 10, 11), .need = zknd }, // aes64dsm
        .{ .insn = aesR(0x3f, 10, 10, 11), .need = zkne | zknd }, // aes64ks2
        .{ .insn = aesIm(10, 10), .need = zknd }, // aes64im
        .{ .insn = aesKs1i(10, 10, 0), .need = zkne | zknd },
        .{ .insn = aesKs1i(10, 10, 10), .need = zkne | zknd },
        // never legal: rnum 11..15, aes64im with rs2 != 0, funct3 != 0, aes32 (RV32 only)
        .{ .insn = aesKs1i(10, 10, 11), .need = 0 },
        .{ .insn = aesKs1i(10, 10, 15), .need = 0 },
        .{ .insn = itype(0x13, 1, 10, 10, 0x301), .need = 0 },
        .{ .insn = itype(0x13, 1, 10, 10, 0x320), .need = 0 },
        .{ .insn = rtype(0x33, 1, 0x19, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 0, 0x3e, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 0, 0x11, 10, 10, 11), .need = 0 }, // aes32esi bs=0
    };
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (probes) |p| {
            for ([_]u64{ zkne | zknd, zkne, zknd, 0 }) |isa| {
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 100;
                m.regs.x[10] = 0x0123_4567_89ab_cdef;
                m.regs.x[11] = 0xfedc_ba98_7654_3210;
                // a hot loop that keeps x10 at the same value: x10 = op(x12, x11)
                _ = m.code(0x10000, &.{ addi(12, 10, 0), addi(5, 5, 1), p.insn, addi(10, 12, 0), branch(1, 5, 6, -12), ecall });
                const ic = m.cpu.icount;
                if (p.need & isa != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                    try t.expectEqual(@as(u64, 100), m.regs.x[5]);
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, p.insn), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10008), m.regs.pc);
                    try t.expectEqual(ic + 2, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}

const AesCase = struct { name: []const u8, insn: u32, imm: bool = false, ref: *const fn (a: u64, b: u64) u64 };

/// x7 = f(x5, x6) (x7 = f(x5) for aes64im / aes64ks1i).
const aes_cases = blk: {
    var c: []const AesCase = &.{
        .{ .name = "aes64es", .insn = aesR(0x19, 7, 5, 6), .ref = aes.es },
        .{ .name = "aes64esm", .insn = aesR(0x1b, 7, 5, 6), .ref = aes.esm },
        .{ .name = "aes64ds", .insn = aesR(0x1d, 7, 5, 6), .ref = aes.ds },
        .{ .name = "aes64dsm", .insn = aesR(0x1f, 7, 5, 6), .ref = aes.dsm },
        .{ .name = "aes64ks2", .insn = aesR(0x3f, 7, 5, 6), .ref = aes.ks2 },
        .{ .name = "aes64im", .insn = aesIm(7, 5), .imm = true, .ref = struct {
            fn f(a: u64, b: u64) u64 {
                _ = b;
                return aes.im(a);
            }
        }.f },
    };
    for (0..11) |n| c = c ++ &[_]AesCase{.{ .name = "aes64ks1i", .insn = aesKs1i(7, 5, n), .imm = true, .ref = struct {
        fn f(a: u64, b: u64) u64 {
            _ = b;
            return aes.ks1i(a, n);
        }
    }.f }};
    break :blk c[0..c.len].*;
};

test "kwemu jit: Zkne/Zknd on random operands, inline and through helpers, x0 operands (JIT vs interpreter vs core.aes)" {
    var m = try Machine.init();
    defer m.deinit();
    const npair = 512; // (a, b) pairs at 0x200000 (2 pages), outputs at 0x300000
    const in_pa = m.frame();
    _ = m.frame();
    const out_pa = m.frame();
    m.map(0x200000, in_pa, R | W | U | A | D);
    m.map(0x201000, in_pa + 4096, R | W | U | A | D);
    m.map(0x300000, out_pa, R | W | U | A | D);
    var prng = std.Random.DefaultPrng.init(0x5eed_ae5);
    const rnd = prng.random();
    var ins: [npair][2]u64 = undefined;
    for (&ins) |*p| p.* = .{ rnd.int(u64), rnd.int(u64) };
    ins[0] = .{ 0, 0 };
    ins[1] = .{ std.math.maxInt(u64), std.math.maxInt(u64) };
    @memcpy(m.mem[@intCast(in_pa - pa_base)..][0 .. 2 * 4096], std.mem.sliceAsBytes(&ins));
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    var interp: [npair]u64 = undefined;
    for (aes_cases) |c| {
        // variant 0: one op (inline); 1: six copies (helper calls); 2: rs1 = x0 (rs2 = x0 for the I-forms is implicit)
        for (0..3) |variant| {
            const op = if (variant == 2) (c.insn & ~@as(u32, 31 << 15)) else c.insn;
            const n: usize = if (variant == 1) 6 else 1;
            var words: [16]u32 = undefined;
            var w: usize = 0;
            words[w] = ld(5, 10, 0);
            w += 1;
            words[w] = ld(6, 10, 8);
            w += 1;
            for (0..n) |_| {
                words[w] = op;
                w += 1;
            }
            for ([_]u32{ sd(7, 12, 0), addi(10, 10, 16), addi(12, 12, 8) }) |x| {
                words[w] = x;
                w += 1;
            }
            words[w] = branch(1, 10, 11, -@as(i32, @intCast(4 * w)));
            w += 1;
            words[w] = ecall;
            w += 1;
            putCode(&m, code_pa, 0, words[0..w]);
            m.cpu.flushRange(0x10000, 0x11000);
            var retired: u64 = 0;
            for ([_]JitMode{ .off, .eager }) |mode| {
                jitMode(&m, mode, 0);
                m.regs.x[10] = 0x200000;
                m.regs.x[11] = 0x200000 + npair * 16;
                m.regs.x[12] = 0x300000;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
                if (mode == .off) retired = m.cpu.icount - ic else try t.expectEqual(retired, m.cpu.icount - ic);
                for (0..npair) |k| {
                    const a = if (variant == 2) 0 else ins[k][0];
                    const got = std.mem.readInt(u64, m.bytes(out_pa)[k * 8 ..][0..8], .little);
                    const want = c.ref(a, ins[k][1]);
                    if (got != want) {
                        std.debug.print("{s} variant {d} mode {s}: a=0x{x} b=0x{x}: got 0x{x} want 0x{x}\n", .{ c.name, variant, @tagName(mode), a, ins[k][1], got, want });
                        return error.TestUnexpectedResult;
                    }
                    if (mode == .off) interp[k] = got else try t.expectEqual(interp[k], got);
                }
            }
        }
    }
    if (jit_on) {
        try t.expectEqual(@as(u64, 0), jitStat(&m, "fails"));
        try t.expectEqual(@as(u64, 0), jitStat(&m, "handbacks"));
    }
    try checkJitSlots(&m);
}

// ---- Zbc / Zbkb / Zbkc / Zbkx ---------------------------------------------------------

const bm = core.bitmanip;

/// GF(2^128) multiplication as NIST SP 800-38D algorithm 1 (bit by bit, in
/// GCM's bit order: bit 0 is the MSB of byte 0), the reference for `ghashMul`.
fn gfMulRef(x: [16]u8, y: [16]u8) [16]u8 {
    var z: u128 = 0;
    var v = std.mem.readInt(u128, &y, .big);
    const xx = std.mem.readInt(u128, &x, .big);
    for (0..128) |i| {
        if ((xx >> @intCast(127 - i)) & 1 != 0) z ^= v;
        v = if (v & 1 != 0) (v >> 1) ^ (@as(u128, 0xe1) << 120) else v >> 1;
    }
    var out: [16]u8 = undefined;
    std.mem.writeInt(u128, &out, z, .big);
    return out;
}

/// The same with clmul/clmulh and brev8, as OpenSSL's gcm_gmult_rv64i_zbc
/// __zbkb does it: brev8 turns GCM's bit order into polynomial order in two
/// little-endian words, then a 128 x 128 product and a reduction by
/// x^128 = x^7 + x^2 + x + 1 (0x87).
fn ghashMul(x: [16]u8, y: [16]u8) [16]u8 {
    const x0 = bm.brev8(std.mem.readInt(u64, x[0..8], .little));
    const x1 = bm.brev8(std.mem.readInt(u64, x[8..16], .little));
    const y0 = bm.brev8(std.mem.readInt(u64, y[0..8], .little));
    const y1 = bm.brev8(std.mem.readInt(u64, y[8..16], .little));
    var z0 = bm.clmul(x0, y0);
    var z1 = bm.clmulh(x0, y0) ^ bm.clmul(x0, y1) ^ bm.clmul(x1, y0);
    var z2 = bm.clmulh(x0, y1) ^ bm.clmulh(x1, y0) ^ bm.clmul(x1, y1);
    const z3 = bm.clmulh(x1, y1);
    z1 ^= bm.clmul(z3, 0x87);
    z2 ^= bm.clmulh(z3, 0x87);
    z0 ^= bm.clmul(z2, 0x87);
    z1 ^= bm.clmulh(z2, 0x87);
    var out: [16]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], bm.brev8(z0), .little);
    std.mem.writeInt(u64, out[8..16], bm.brev8(z1), .little);
    return out;
}

test "kwemu bitmanip: known vectors, spec references on random operands, AES-GCM test case" {
    // clmul family
    try t.expectEqual(@as(u64, 15), bm.clmul(3, 5));
    try t.expectEqual(@as(u64, 0), bm.clmulh(3, 5));
    try t.expectEqual(@as(u64, 0x5555_5555_5555_5555), bm.clmul(std.math.maxInt(u64), std.math.maxInt(u64)));
    try t.expectEqual(@as(u64, 0x5555_5555_5555_5555), bm.clmulh(std.math.maxInt(u64), std.math.maxInt(u64)));
    try t.expectEqual(@as(u64, 0xaaaa_aaaa_aaaa_aaaa), bm.clmulr(std.math.maxInt(u64), std.math.maxInt(u64)));
    try t.expectEqual(@as(u64, 1), bm.clmulh(1 << 63, 2));
    try t.expectEqual(@as(u64, 1), bm.clmulr(1 << 63, 1)); // bit 63 of the product
    try t.expectEqual(@as(u64, 0), bm.clmulr(1 << 62, 1));
    try t.expectEqual(@as(u64, 0x43), bm.clmulh(1 << 63, 0x87)); // x^63 * (x^7+x^2+x+1) >> 64
    // the rest
    try t.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), bm.rev8(0xefcd_ab89_6745_2301));
    try t.expectEqual(@as(u64, 0x8040_c020_a060_e010), bm.brev8(0x0102_0304_0506_0708));
    try t.expectEqual(@as(u64, 0x0000_0005_0000_0003), bm.pack(3, 5));
    try t.expectEqual(@as(u64, 0x0503), bm.packh(0x1203, 0x3405));
    try t.expectEqual(@as(u64, 0xffff_ffff_8765_4321), bm.packw(0xffff_4321, 0x1_8765));
    try t.expectEqual(@as(u64, 0x0303_0303_0303_0300), bm.xperm8(3, 5));
    try t.expectEqual(@as(u64, 0x0706_0504_0302_0100), bm.xperm8(0x0706_0504_0302_0100, 0x0706_0504_0302_0100));
    try t.expectEqual(@as(u64, 0x0000_ff00_0000_0001), bm.xperm8(0xff01, 0x0808_0108_ff10_8000));
    try t.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), bm.xperm4(0xfedc_ba98_7654_3210, 0xfedc_ba98_7654_3210));
    try t.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), bm.xperm4(0xfedc_ba98_7654_3210, 0xfedc_ba98_7654_3210 ^ std.math.maxInt(u64)));
    try t.expectEqual(@as(u64, 0xffff_ffff_8000_0000), bm.rolw(0x1_4000_0000, 33)); // count mod 32
    try t.expectEqual(@as(u64, 0x0000_0000_4000_0000), bm.rorw(0x8000_0000, 1));

    var prng = std.Random.DefaultPrng.init(0xb17);
    const rnd = prng.random();
    for (0..20000) |i| {
        var a = rnd.int(u64);
        var b = rnd.int(u64);
        if (i < 4) {
            a = if (i & 1 != 0) std.math.maxInt(u64) else 0;
            b = if (i & 2 != 0) std.math.maxInt(u64) else 0;
        } else if (i % 7 == 0) b &= 0x0f0f_0707_0303_0101; // xperm8 indices in range
        try t.expectEqual(refClmul(a, b), bm.clmul(a, b));
        try t.expectEqual(refClmulh(a, b), bm.clmulh(a, b));
        try t.expectEqual(refClmulr(a, b), bm.clmulr(a, b));
        try t.expectEqual(refXperm(a, b, 8), bm.xperm8(a, b));
        try t.expectEqual(refXperm(a, b, 4), bm.xperm4(a, b));
        try t.expectEqual(refRev8(a), bm.rev8(a));
        try t.expectEqual(refBrev8(a), bm.brev8(a));
        try t.expectEqual(refRot(a, b & 31, 32, true), bm.rolw(a, b));
        try t.expectEqual(refRot(a, b & 31, 32, false), bm.rorw(a, b));
        // the product's halves: commutative, and clmulr overlaps both
        try t.expectEqual(bm.clmul(a, b), bm.clmul(b, a));
        try t.expectEqual(bm.clmulh(a, b) << 1 | bm.clmul(a, b) >> 63, bm.clmulr(a, b));
    }

    // GHASH multiplication against SP 800-38D algorithm 1
    for (0..2000) |_| {
        var x: [16]u8 = undefined;
        var y: [16]u8 = undefined;
        rnd.bytes(&x);
        rnd.bytes(&y);
        try t.expectEqualSlices(u8, &gfMulRef(x, y), &ghashMul(x, y));
    }
    // AES-GCM test case 2 (zero key, IV and one zero block; McGrew & Viega,
    // the GCM spec's appendix B) through core.aes and ghashMul
    const k = AesRef.init(&@as([16]u8, @splat(0)));
    const h = k.encrypt(@splat(0));
    try t.expectEqualSlices(u8, &hexBytes("66e94bd4ef8a2c3b884cfa59ca342b2e"), &h);
    var y0: [16]u8 = @splat(0);
    y0[15] = 1;
    const ek_y0 = k.encrypt(y0);
    var y1 = y0;
    y1[15] = 2;
    const ct = k.encrypt(y1); // xor a zero plaintext block
    try t.expectEqualSlices(u8, &hexBytes("0388dace60b6a392f328c2b971b2fe78"), &ct);
    var g = ghashMul(ct, h);
    var lens: [16]u8 = @splat(0);
    lens[15] = 128; // len(A) = 0, len(C) = 128 bits
    for (&g, lens) |*gb, lb| gb.* ^= lb;
    g = ghashMul(g, h);
    for (&g, ek_y0) |*gb, eb| gb.* ^= eb;
    try t.expectEqualSlices(u8, &hexBytes("ab6e47d42cec13bdf53a67b21257bddf"), &g);
}

test "kwemu bitmanip: encodings and gates (shared with Zbb, Zbc or Zbkc), RV32-only zip/unzip" {
    var m = try Machine.init();
    defer m.deinit();
    const zbc = core.bit(.zbc);
    const zbkb = core.bit(.zbkb);
    const zbkc = core.bit(.zbkc);
    const zbkx = core.bit(.zbkx);
    const zbb = core.bit(.zbb);
    const Probe = struct { insn: u32, need: u64 };
    const probes = [_]Probe{
        .{ .insn = rtype(0x33, 7, 0x20, 10, 10, 11), .need = zbkb | zbb }, // andn (or Zbb)
        .{ .insn = rtype(0x33, 6, 0x20, 10, 10, 11), .need = zbkb | zbb }, // orn
        .{ .insn = rtype(0x33, 4, 0x20, 10, 10, 11), .need = zbkb | zbb }, // xnor
        .{ .insn = rtype(0x33, 1, 0x30, 10, 10, 11), .need = zbkb | zbb }, // rol
        .{ .insn = rtype(0x33, 5, 0x30, 10, 10, 11), .need = zbkb | zbb }, // ror
        .{ .insn = rtype(0x3b, 1, 0x30, 10, 10, 11), .need = zbkb | zbb }, // rolw
        .{ .insn = rtype(0x3b, 5, 0x30, 10, 10, 11), .need = zbkb | zbb }, // rorw
        .{ .insn = itype(0x13, 5, 10, 10, 0x600 | 37), .need = zbkb | zbb }, // rori
        .{ .insn = itype(0x1b, 5, 10, 10, 0x600 | 17), .need = zbkb | zbb }, // roriw
        .{ .insn = itype(0x13, 5, 10, 10, 0x6b8), .need = zbkb | zbb }, // rev8
        .{ .insn = rtype(0x3b, 4, 0x04, 10, 10, 0), .need = zbkb | zbb }, // zext.h = packw rd, rs1, x0 (or Zbb)
        .{ .insn = rtype(0x33, 4, 0x04, 10, 10, 11), .need = zbkb }, // pack
        .{ .insn = rtype(0x33, 7, 0x04, 10, 10, 11), .need = zbkb }, // packh
        .{ .insn = rtype(0x3b, 4, 0x04, 10, 10, 11), .need = zbkb }, // packw
        .{ .insn = itype(0x13, 5, 10, 10, 0x687), .need = zbkb }, // brev8
        .{ .insn = rtype(0x33, 1, 0x05, 10, 10, 11), .need = zbc | zbkc }, // clmul
        .{ .insn = rtype(0x33, 3, 0x05, 10, 10, 11), .need = zbc | zbkc }, // clmulh
        .{ .insn = rtype(0x33, 2, 0x05, 10, 10, 11), .need = zbc }, // clmulr
        .{ .insn = rtype(0x33, 2, 0x14, 10, 10, 11), .need = zbkx }, // xperm4
        .{ .insn = rtype(0x33, 4, 0x14, 10, 10, 11), .need = zbkx }, // xperm8
        // Zbb's own neighbours
        .{ .insn = itype(0x13, 5, 10, 10, 0x287), .need = zbb }, // orc.b
        .{ .insn = rtype(0x33, 4, 0x05, 10, 10, 11), .need = zbb }, // min
        // never legal on RV64 with these extensions: zip/unzip (RV32
        // only), RV32 rev8, roriw with shamt[5] set, neighbouring
        // funct3/funct7 values
        .{ .insn = itype(0x13, 1, 10, 10, 0x08f), .need = 0 }, // zip
        .{ .insn = itype(0x13, 5, 10, 10, 0x08f), .need = 0 }, // unzip
        .{ .insn = itype(0x13, 5, 10, 10, 0x698), .need = 0 }, // rev8 (RV32)
        .{ .insn = itype(0x13, 5, 10, 10, 0x688), .need = 0 },
        .{ .insn = itype(0x1b, 5, 10, 10, 0x620), .need = 0 }, // roriw, shamt 32
        .{ .insn = rtype(0x33, 0, 0x05, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 3, 0x30, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 1, 0x20, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 0, 0x14, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 5, 0x04, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x3b, 7, 0x04, 10, 10, 11), .need = 0 }, // packhw does not exist
        .{ .insn = rtype(0x3b, 1, 0x05, 10, 10, 11), .need = 0 }, // no clmulw
    };
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (probes) |p| {
            for ([_]u64{ zbc | zbkb | zbkc | zbkx, zbc, zbkb, zbkc, zbkx, zbb, core.implemented & ~(zbc | zbkb | zbkc | zbkx), 0 }) |isa| {
                // a hot loop that keeps x10 at the same value: x10 = op(x12, x11)
                putCode(&m, code_pa, 0, &.{ addi(12, 10, 0), addi(5, 5, 1), p.insn, addi(10, 12, 0), branch(1, 5, 6, -12), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 100;
                m.regs.x[10] = 0x0123_4567_89ab_cdef;
                m.regs.x[11] = 0xfedc_ba98_7654_3210;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                if (p.need & isa != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                    try t.expectEqual(@as(u64, 100), m.regs.x[5]);
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, p.insn), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10008), m.regs.pc);
                    try t.expectEqual(ic + 2, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}

test "kwemu zb: Zba/Zbb/Zbs/Zicond encodings and gates, neighbours that stay illegal" {
    var m = try Machine.init();
    defer m.deinit();
    const zba = core.bit(.zba);
    const zbb = core.bit(.zbb);
    const zbs = core.bit(.zbs);
    const zicond = core.bit(.zicond);
    const zbkb = core.bit(.zbkb);
    const Probe = struct { insn: u32, need: u64 };
    const probes = [_]Probe{
        .{ .insn = rtype(0x33, 2, 0x10, 10, 10, 11), .need = zba }, // sh1add
        .{ .insn = rtype(0x33, 4, 0x10, 10, 10, 11), .need = zba }, // sh2add
        .{ .insn = rtype(0x33, 6, 0x10, 10, 10, 11), .need = zba }, // sh3add
        .{ .insn = rtype(0x3b, 0, 0x04, 10, 10, 11), .need = zba }, // add.uw
        .{ .insn = rtype(0x3b, 0, 0x04, 10, 10, 0), .need = zba }, // zext.w = add.uw rd, rs1, x0
        .{ .insn = rtype(0x3b, 2, 0x10, 10, 10, 11), .need = zba }, // sh1add.uw
        .{ .insn = rtype(0x3b, 4, 0x10, 10, 10, 11), .need = zba }, // sh2add.uw
        .{ .insn = rtype(0x3b, 6, 0x10, 10, 10, 11), .need = zba }, // sh3add.uw
        .{ .insn = itype(0x1b, 1, 10, 10, 0x080 | 0), .need = zba }, // slli.uw 0
        .{ .insn = itype(0x1b, 1, 10, 10, 0x080 | 63), .need = zba }, // slli.uw 63
        .{ .insn = itype(0x13, 1, 10, 10, 0x600), .need = zbb }, // clz
        .{ .insn = itype(0x13, 1, 10, 10, 0x601), .need = zbb }, // ctz
        .{ .insn = itype(0x13, 1, 10, 10, 0x602), .need = zbb }, // cpop
        .{ .insn = itype(0x1b, 1, 10, 10, 0x600), .need = zbb }, // clzw
        .{ .insn = itype(0x1b, 1, 10, 10, 0x601), .need = zbb }, // ctzw
        .{ .insn = itype(0x1b, 1, 10, 10, 0x602), .need = zbb }, // cpopw
        .{ .insn = itype(0x13, 1, 10, 10, 0x604), .need = zbb }, // sext.b
        .{ .insn = itype(0x13, 1, 10, 10, 0x605), .need = zbb }, // sext.h
        .{ .insn = itype(0x13, 5, 10, 10, 0x287), .need = zbb }, // orc.b
        .{ .insn = rtype(0x33, 4, 0x05, 10, 10, 11), .need = zbb }, // min
        .{ .insn = rtype(0x33, 5, 0x05, 10, 10, 11), .need = zbb }, // minu
        .{ .insn = rtype(0x33, 6, 0x05, 10, 10, 11), .need = zbb }, // max
        .{ .insn = rtype(0x33, 7, 0x05, 10, 10, 11), .need = zbb }, // maxu
        .{ .insn = rtype(0x3b, 4, 0x04, 10, 10, 0), .need = zbb | zbkb }, // zext.h (packw rd, rs1, x0)
        .{ .insn = rtype(0x3b, 4, 0x04, 10, 10, 11), .need = zbkb }, // packw: not Zbb
        .{ .insn = rtype(0x33, 7, 0x20, 10, 10, 11), .need = zbb | zbkb }, // andn
        .{ .insn = itype(0x13, 5, 10, 10, 0x6b8), .need = zbb | zbkb }, // rev8
        .{ .insn = rtype(0x33, 1, 0x24, 10, 10, 11), .need = zbs }, // bclr
        .{ .insn = rtype(0x33, 5, 0x24, 10, 10, 11), .need = zbs }, // bext
        .{ .insn = rtype(0x33, 1, 0x34, 10, 10, 11), .need = zbs }, // binv
        .{ .insn = rtype(0x33, 1, 0x14, 10, 10, 11), .need = zbs }, // bset
        .{ .insn = itype(0x13, 1, 10, 10, 0x480 | 63), .need = zbs }, // bclri
        .{ .insn = itype(0x13, 5, 10, 10, 0x480 | 33), .need = zbs }, // bexti
        .{ .insn = itype(0x13, 1, 10, 10, 0x680 | 32), .need = zbs }, // binvi
        .{ .insn = itype(0x13, 1, 10, 10, 0x280 | 1), .need = zbs }, // bseti
        .{ .insn = rtype(0x33, 5, 0x07, 10, 10, 11), .need = zicond }, // czero.eqz
        .{ .insn = rtype(0x33, 7, 0x07, 10, 10, 11), .need = zicond }, // czero.nez
        // never legal on RV64: reserved neighbours, RV32-only encodings,
        // OP-IMM forms in OP-IMM-32 and back
        .{ .insn = rtype(0x33, 0, 0x10, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 3, 0x10, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x3b, 1, 0x04, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x3b, 7, 0x10, 10, 10, 11), .need = 0 },
        .{ .insn = itype(0x13, 1, 10, 10, 0x080 | 3), .need = 0 }, // slli.uw in OP-IMM
        .{ .insn = itype(0x13, 1, 10, 10, 0x603), .need = 0 },
        .{ .insn = itype(0x13, 1, 10, 10, 0x606), .need = 0 },
        .{ .insn = itype(0x13, 1, 10, 10, 0x620), .need = 0 },
        .{ .insn = itype(0x1b, 1, 10, 10, 0x603), .need = 0 },
        .{ .insn = itype(0x1b, 1, 10, 10, 0x604), .need = 0 }, // no sext.b in OP-IMM-32
        .{ .insn = itype(0x1b, 5, 10, 10, 0x287), .need = 0 }, // no orc.b in OP-IMM-32
        .{ .insn = itype(0x13, 5, 10, 10, 0x288), .need = 0 },
        .{ .insn = itype(0x13, 5, 10, 10, 0x280), .need = 0 }, // bseti's funct6 under funct3 5
        .{ .insn = itype(0x1b, 1, 10, 10, 0x480 | 3), .need = 0 }, // no bclriw
        .{ .insn = itype(0x1b, 5, 10, 10, 0x480 | 3), .need = 0 }, // no bextiw
        .{ .insn = rtype(0x3b, 1, 0x24, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 2, 0x24, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 5, 0x34, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 5, 0x14, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 6, 0x07, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x33, 1, 0x07, 10, 10, 11), .need = 0 },
        .{ .insn = rtype(0x3b, 5, 0x07, 10, 10, 11), .need = 0 }, // no czero.eqzw
    };
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    const all4 = zba | zbb | zbs | zicond;
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (probes) |p| {
            for ([_]u64{ all4, zba, zbb, zbs, zicond, zbkb, core.implemented & ~all4, core.implemented, 0 }) |isa| {
                // a hot loop that keeps x10 at the same value: x10 = op(x12, x11)
                putCode(&m, code_pa, 0, &.{ addi(12, 10, 0), addi(5, 5, 1), p.insn, addi(10, 12, 0), branch(1, 5, 6, -12), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 100;
                m.regs.x[10] = 0x0123_4567_89ab_cdef;
                m.regs.x[11] = 0xfedc_ba98_7654_3210;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                if (p.need & isa != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                    try t.expectEqual(@as(u64, 100), m.regs.x[5]);
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, p.insn), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10008), m.regs.pc);
                    try t.expectEqual(ic + 2, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));

    // known values of core.bitmanip
    try t.expectEqual(@as(u64, 0xff00_ffff_00ff_00ff), bm.orcb(0x8000_0102_0080_0001));
    try t.expectEqual(@as(u64, 0), bm.orcb(0));
    try t.expectEqual(@as(u64, 32), bm.clzw(0xffff_ffff_0000_0000));
    try t.expectEqual(@as(u64, 32), bm.ctzw(0xffff_ffff_0000_0000));
    try t.expectEqual(@as(u64, 0), bm.cpopw(0xffff_ffff_0000_0000));
    try t.expectEqual(@as(u64, 0x1_ffff_fffe), bm.shaddUw(0xffff_ffff_ffff_ffff, 0, 1));
    try t.expectEqual(@as(u64, 1 << 63), bm.max(1 << 63, 1 << 63));
    try t.expectEqual(@as(u64, 5), bm.max(1 << 63, 5));
    try t.expectEqual(@as(u64, 1 << 63), bm.min(1 << 63, 5));
}

const BkCase = struct { name: []const u8, insn: u32, ref: *const fn (a: u64, b: u64) u64 };

fn bkImm(comptime kind: @FieldType(ImmCase, "kind"), comptime imm: i32) BkCase {
    const c = immCase(kind, imm);
    return .{ .name = @tagName(kind), .insn = c.insn, .ref = struct {
        fn f(a: u64, b: u64) u64 {
            _ = b;
            return immRef(c, a);
        }
    }.f };
}

/// The alu_cases with these names.
fn aluPick(comptime names: []const []const u8) []const BkCase {
    var c: []const BkCase = &.{};
    for (names) |n| {
        const a = for (alu_cases) |a| {
            if (std.mem.eql(u8, a.name, n)) break a;
        } else @compileError("no alu case " ++ n);
        c = c ++ &[_]BkCase{.{ .name = a.name, .insn = a.insn, .ref = a.ref }};
    }
    return c;
}

/// x7 = f(x5, x6): every Zbkb/Zbc/Zbkx op, from alu_cases and imm forms.
const bk_cases = blk: {
    const c = aluPick(&.{ "andn", "orn", "xnor", "rol", "ror", "rolw", "rorw", "pack", "packh", "packw", "clmul", "clmulh", "clmulr", "xperm4", "xperm8" }) ++
        &[_]BkCase{ bkImm(.rori, 0), bkImm(.rori, 13), bkImm(.rori, 63), bkImm(.roriw, 7), bkImm(.roriw, 31), bkImm(.rev8, 0), bkImm(.brev8, 0) };
    break :blk c[0..c.len].*;
};

/// x7 = f(x5, x6): every Zba/Zbb/Zbs/Zicond op (the ones Zbb shares with
/// Zbkb are in bk_cases).
const zb_cases = blk: {
    const c = aluPick(&.{ "sh1add", "sh2add", "sh3add", "add.uw", "sh1add.uw", "sh2add.uw", "sh3add.uw", "max", "maxu", "min", "minu", "bclr", "bset", "binv", "bext", "czero.eqz", "czero.nez" }) ++
        &[_]BkCase{
            bkImm(.clz, 0),      bkImm(.ctz, 0),      bkImm(.cpop, 0),   bkImm(.clzw, 0),   bkImm(.ctzw, 0),    bkImm(.cpopw, 0),
            bkImm(.sext_b, 0),   bkImm(.sext_h, 0),   bkImm(.zext_h, 0), bkImm(.orc_b, 0),  bkImm(.slli_uw, 0), bkImm(.slli_uw, 5),
            bkImm(.slli_uw, 32), bkImm(.slli_uw, 63), bkImm(.bseti, 7),  bkImm(.bseti, 63), bkImm(.bclri, 0),   bkImm(.bclri, 40),
            bkImm(.binvi, 31),   bkImm(.binvi, 32),   bkImm(.bexti, 1),  bkImm(.bexti, 63),
        };
    break :blk c[0..c.len].*;
};

/// Operand variants of `randomCases`.
const RandVariant = enum {
    plain, // x7 = op(x5, x6)
    copies, // 13 copies of the op in the block (helper calls for clmul*/xperm*)
    rs1_x0, // x7 = op(x0, x6)
    rs2_x0, // x7 = op(x5, x0) (R-types only)
    rd_rs1, // x5 = op(x5, x6)
    rd_rs2, // x6 = op(x5, x6) (R-types only)
    rd_x0, // x0 = op(x5, x6): x7 keeps the 0x55 set before
    same, // x5 = op(x5, x5) (R-types only)
};

/// Run each case over 512 random operand pairs (plus all-zero and
/// all-ones) in a hot loop, interpreted and eagerly compiled: the results
/// must equal the reference and each other, with the same instret.
fn randomCases(cases: []const BkCase, variants: []const RandVariant) !void {
    var m = try Machine.init();
    defer m.deinit();
    const npair = 512; // (a, b) pairs at 0x200000 (2 pages), outputs at 0x300000
    const in_pa = m.frame();
    _ = m.frame();
    const out_pa = m.frame();
    m.map(0x200000, in_pa, R | W | U | A | D);
    m.map(0x201000, in_pa + 4096, R | W | U | A | D);
    m.map(0x300000, out_pa, R | W | U | A | D);
    var prng = std.Random.DefaultPrng.init(0x5eed_b17);
    const rnd = prng.random();
    var ins: [npair][2]u64 = undefined;
    for (&ins, 0..) |*p, i| {
        p.* = .{ rnd.int(u64), rnd.int(u64) };
        if (i % 4 == 1) p[1] &= 0x0707_0707_0707_0707; // xperm8 indices in range
        if (i % 4 == 2) p[1] &= 0xff; // a short clmul operand (e.g. 0x87), a small bit index
        if (i % 8 == 3) p[1] = 0; // czero
        if (i % 8 == 7) p[0] >>= @intCast(rnd.uintLessThan(u32, 64)); // leading zeros
    }
    ins[0] = .{ 0, 0 };
    ins[1] = .{ std.math.maxInt(u64), std.math.maxInt(u64) };
    @memcpy(m.mem[@intCast(in_pa - pa_base)..][0 .. 2 * 4096], std.mem.sliceAsBytes(&ins));
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    var interp: [npair]u64 = undefined;
    for (cases) |c| {
        const rtyp = c.insn & 0x7f == 0x33 or (c.insn & 0x7f == 0x3b and (c.insn >> 20) & 31 != 0);
        for (variants) |variant| {
            const set_rd = struct {
                fn f(i: u32, rd: u32) u32 {
                    return (i & ~@as(u32, 31 << 7)) | rd << 7;
                }
            }.f;
            const op, const out: u32 = switch (variant) {
                .plain, .copies => .{ c.insn, 7 },
                .rs1_x0 => .{ c.insn & ~@as(u32, 31 << 15), 7 },
                .rs2_x0 => .{ c.insn & ~@as(u32, 31 << 20), 7 },
                .rd_rs1 => .{ set_rd(c.insn, 5), 5 },
                .rd_rs2 => .{ set_rd(c.insn, 6), 6 },
                .rd_x0 => .{ set_rd(c.insn, 0), 7 },
                .same => .{ set_rd((c.insn & ~@as(u32, 31 << 20)) | 5 << 20, 5), 5 },
            };
            if (!rtyp and (variant == .rs2_x0 or variant == .rd_rs2 or variant == .same)) continue;
            const n: usize = if (variant == .copies) 13 else 1;
            var words: [24]u32 = undefined;
            var w: usize = 0;
            for ([_]u32{ ld(5, 10, 0), ld(6, 10, 8), addi(7, 0, 0x55) }) |x| {
                words[w] = x;
                w += 1;
            }
            for (0..n) |_| {
                words[w] = op;
                w += 1;
            }
            for ([_]u32{ sd(out, 12, 0), addi(10, 10, 16), addi(12, 12, 8) }) |x| {
                words[w] = x;
                w += 1;
            }
            words[w] = branch(1, 10, 11, -@as(i32, @intCast(4 * w)));
            w += 1;
            words[w] = ecall;
            w += 1;
            putCode(&m, code_pa, 0, words[0..w]);
            m.cpu.flushRange(0x10000, 0x11000);
            var retired: u64 = 0;
            for ([_]JitMode{ .off, .eager }) |mode| {
                jitMode(&m, mode, 0);
                m.regs.x[10] = 0x200000;
                m.regs.x[11] = 0x200000 + npair * 16;
                m.regs.x[12] = 0x300000;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                try t.expectEqual(@as(u32, EV_SYSCALL), m.run(1 << 20));
                if (mode == .off) retired = m.cpu.icount - ic else try t.expectEqual(retired, m.cpu.icount - ic);
                for (0..npair) |k| {
                    const a = if (variant == .rs1_x0) 0 else ins[k][0];
                    const b = switch (variant) {
                        .rs2_x0 => 0,
                        .same => a,
                        else => ins[k][1],
                    };
                    const got = std.mem.readInt(u64, m.bytes(out_pa)[k * 8 ..][0..8], .little);
                    const want = if (variant == .rd_x0) 0x55 else c.ref(a, b);
                    if (got != want) {
                        std.debug.print("{s} variant {s} mode {s}: a=0x{x} b=0x{x}: got 0x{x} want 0x{x}\n", .{ c.name, @tagName(variant), @tagName(mode), a, b, got, want });
                        return error.TestUnexpectedResult;
                    }
                    if (mode == .off) interp[k] = got else try t.expectEqual(interp[k], got);
                }
            }
        }
    }
    if (jit_on) {
        try t.expectEqual(@as(u64, 0), jitStat(&m, "fails"));
        try t.expectEqual(@as(u64, 0), jitStat(&m, "handbacks"));
    }
    try checkJitSlots(&m);
}

test "kwemu jit: Zbkb/Zbc/Zbkx on random operands, inline and through helpers, x0 operands (JIT vs interpreter vs reference)" {
    comptime std.debug.assert(bk_cases.len == 22);
    try randomCases(&bk_cases, &.{ .plain, .copies, .rs1_x0, .rs2_x0 });
}

test "kwemu jit: Zba/Zbb/Zbs/Zicond on random operands, x0 and rd = rs operands (JIT vs interpreter vs reference)" {
    comptime std.debug.assert(zb_cases.len == 39);
    try randomCases(&zb_cases, std.enums.values(RandVariant));
}

// ---- Zcb, Zimop, Zcmop, Zawrs, Zicbom, Zicboz ---------------------------------------

/// Zcb loads/stores (quadrant 0, funct3 100): funct6 low bits f, bits 6
/// and 5, rs1' and rd'/rs2' (x8..x15).
fn cZcbMem(f: u32, b6: u32, b5: u32, rs1p: u32, rp: u32) u32 {
    return (0b100 << 13) | (f << 10) | ((rs1p - 8) << 7) | (b6 << 6) | (b5 << 5) | ((rp - 8) << 2);
}
/// c.zext.b (0), c.sext.b (1), c.zext.h (2), c.sext.h (3), c.zext.w (4), c.not (5)
fn cZcbUnary(sub: u32, rdp: u32) u32 {
    return 0x9c61 | ((rdp - 8) << 7) | (sub << 2);
}
fn cMul(rdp: u32, rs2p: u32) u32 {
    return 0x9c41 | ((rdp - 8) << 7) | ((rs2p - 8) << 2);
}
const c_nop: u32 = 0x0001;
/// Two compressed instructions in one word (the first at the lower address).
fn cPair(c1: u32, c2: u32) u32 {
    return c1 | (c2 << 16);
}
fn mopR(n: u32, rd: u32, rs1: u32) u32 {
    return 0x81c04073 | (((n >> 4) & 1) << 30) | (((n >> 2) & 3) << 26) | ((n & 3) << 20) | (rs1 << 15) | (rd << 7);
}
fn mopRR(n: u32, rd: u32, rs1: u32, rs2: u32) u32 {
    return 0x82004073 | (((n >> 2) & 1) << 30) | ((n & 3) << 26) | (rs2 << 20) | (rs1 << 15) | (rd << 7);
}
/// c.mop.N, N = 1, 3, ..., 15
fn cMop(n: u32) u32 {
    return 0x6081 | (((n >> 1) & 7) << 8);
}
fn cbo(imm: u32, rs1: u32) u32 {
    return (imm << 20) | (rs1 << 15) | (2 << 12) | 0x0f;
}

/// The data page of the Zcb tests: byte i is (37 i + 11) & 0xff.
fn zcbByte(i: u64) u8 {
    return @truncate(i *% 37 +% 11);
}
fn zcbMem(off: u64, comptime T: type) T {
    var v: T = 0;
    for (0..@sizeOf(T)) |k| v |= @as(T, zcbByte(off + k)) << @intCast(8 * k);
    return v;
}

const ZcbCase = struct {
    name: []const u8,
    insn: u32,
    /// Every extension it needs (0 bits of `implemented`: never legal).
    need: u64,
    /// a0 after `a0 = a2; insn` (a1 = b: a value, or 0x20000 + offset of the data page)
    ref: *const fn (a: u64, b: u64) u64,
    mem: bool = false,
};

fn zcbLoad(comptime name: []const u8, comptime f: u32, comptime b6: u32, comptime b5: u32, comptime T: type, comptime signed: bool) ZcbCase {
    const off: u64 = if (f == 0) b6 | (b5 << 1) else b5 << 1;
    return .{ .name = name, .insn = cPair(cZcbMem(f, b6, b5, 11, 10), c_nop), .need = core.bit(.zcb), .mem = true, .ref = struct {
        fn r(a: u64, b: u64) u64 {
            _ = a;
            const v = zcbMem(b - 0x20000 + off, T);
            return if (signed) core.sext(v, @bitSizeOf(T)) else v;
        }
    }.r };
}

fn zcbVal(comptime name: []const u8, comptime insn: u32, comptime need: u64, comptime f: fn (a: u64, b: u64) u64) ZcbCase {
    return .{ .name = name, .insn = insn, .need = need, .ref = f };
}
fn refSame(a: u64, b: u64) u64 {
    _ = b;
    return a;
}
fn refZero(a: u64, b: u64) u64 {
    _ = a;
    _ = b;
    return 0;
}

const never: u64 = 1 << 63; // no such extension: never legal
const zcb_cases = blk: {
    const zcb = core.bit(.zcb);
    const zbb = core.bit(.zbb);
    const zba = core.bit(.zba);
    break :blk [_]ZcbCase{
        zcbVal("c.zext.b", cPair(cZcbUnary(0, 10), c_nop), zcb, struct {
            fn r(a: u64, _: u64) u64 {
                return a & 0xff;
            }
        }.r),
        zcbVal("c.sext.b", cPair(cZcbUnary(1, 10), c_nop), zcb | zbb, struct {
            fn r(a: u64, _: u64) u64 {
                return core.sext(a, 8);
            }
        }.r),
        zcbVal("c.zext.h", cPair(cZcbUnary(2, 10), c_nop), zcb | zbb, struct {
            fn r(a: u64, _: u64) u64 {
                return a & 0xffff;
            }
        }.r),
        zcbVal("c.sext.h", cPair(cZcbUnary(3, 10), c_nop), zcb | zbb, struct {
            fn r(a: u64, _: u64) u64 {
                return core.sext(a, 16);
            }
        }.r),
        zcbVal("c.zext.w", cPair(cZcbUnary(4, 10), c_nop), zcb | zba, struct {
            fn r(a: u64, _: u64) u64 {
                return a & 0xffff_ffff;
            }
        }.r),
        zcbVal("c.not", cPair(cZcbUnary(5, 10), c_nop), zcb, struct {
            fn r(a: u64, _: u64) u64 {
                return ~a;
            }
        }.r),
        zcbVal("c.mul", cPair(cMul(10, 11), c_nop), zcb, struct {
            fn r(a: u64, b: u64) u64 {
                return a *% b;
            }
        }.r),
        zcbVal("c.mul (c.nop first)", cPair(c_nop, cMul(10, 11)), zcb, struct {
            fn r(a: u64, b: u64) u64 {
                return a *% b;
            }
        }.r),
        zcbLoad("c.lbu 0", 0, 0, 0, u8, false),
        zcbLoad("c.lbu 1", 0, 1, 0, u8, false),
        zcbLoad("c.lbu 2", 0, 0, 1, u8, false),
        zcbLoad("c.lbu 3", 0, 1, 1, u8, false),
        zcbLoad("c.lhu 0", 1, 0, 0, u16, false),
        zcbLoad("c.lhu 2", 1, 0, 1, u16, false),
        zcbLoad("c.lh 0", 1, 1, 0, u16, true),
        zcbLoad("c.lh 2", 1, 1, 1, u16, true),
        zcbVal("mop.r.0", mopR(0, 10, 11), core.bit(.zimop), refZero),
        zcbVal("mop.r.13", mopR(13, 10, 11), core.bit(.zimop), refZero),
        zcbVal("mop.r.28", mopR(28, 10, 11), core.bit(.zimop), refZero),
        zcbVal("mop.r.31", mopR(31, 10, 10), core.bit(.zimop), refZero),
        zcbVal("mop.rr.0", mopRR(0, 10, 11, 12), core.bit(.zimop), refZero),
        zcbVal("mop.rr.7", mopRR(7, 10, 10, 11), core.bit(.zimop), refZero),
        zcbVal("mop.r.5 x0", mopR(5, 0, 10), core.bit(.zimop), refSame),
        zcbVal("c.mop.1", cPair(cMop(1), c_nop), core.bit(.zcmop), refSame),
        zcbVal("c.mop.5", cPair(c_nop, cMop(5)), core.bit(.zcmop), refSame),
        zcbVal("c.mop.11", cPair(cMop(11), cMop(15)), core.bit(.zcmop), refSame),
        zcbVal("wrs.nto", 0x00d00073, core.bit(.zawrs), refSame),
        zcbVal("wrs.sto", 0x01d00073, core.bit(.zawrs), refSame),
        // neighbours that stay illegal
        zcbVal("c.sh with bit 6", cPair(cZcbMem(3, 1, 0, 11, 10), c_nop), never, refSame),
        zcbVal("quadrant 0, funct6 100100", cPair(cZcbMem(4, 0, 0, 11, 10), c_nop), never, refSame),
        zcbVal("quadrant 0, funct6 100111", cPair(cZcbMem(7, 1, 1, 11, 10), c_nop), never, refSame),
        zcbVal("Zcb unary 6", cPair(cZcbUnary(6, 10), c_nop), never, refSame),
        zcbVal("Zcb unary 7", cPair(cZcbUnary(7, 10), c_nop), never, refSame),
        zcbVal("c.lui x4, 0", cPair(0x6201, c_nop), never, refSame),
        zcbVal("c.lui x17, 0", cPair(0x6881, c_nop), never, refSame),
        zcbVal("mop.r with bit 28", mopR(0, 10, 11) | (1 << 28), never, refSame),
        zcbVal("mop.r with bit 31 clear", mopR(0, 10, 11) & ~@as(u32, 1 << 31), never, refSame),
        zcbVal("mop.r with bits 25:22 0110", mopR(0, 10, 11) & ~@as(u32, 1 << 22), never, refSame),
        zcbVal("wrs.nto with rd", 0x00d00573, never, refSame),
        zcbVal("wrs (imm 0x00e)", 0x00e00073, never, refSame),
    };
};

test "kwemu rva23: Zcb, Zimop, Zcmop, Zawrs: results, gates and reserved neighbours (interpreter, eager JIT, reference)" {
    var m = try Machine.init();
    defer m.deinit();
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    const data_pa = m.frame();
    m.map(0x20000, data_pa, R | W | U | A | D);
    for (m.bytes(data_pa), 0..) |*b, i| b.* = zcbByte(i);
    var prng = std.Random.DefaultPrng.init(23);
    const rnd = prng.random();
    const zcb = core.bit(.zcb);
    const masks = [_]u64{ core.implemented, 0, core.implemented & ~zcb, core.implemented & ~core.bit(.zbb), core.implemented & ~core.bit(.zba), core.implemented & ~core.bit(.zimop), core.implemented & ~core.bit(.zcmop), core.implemented & ~core.bit(.zawrs) };
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (zcb_cases) |c| {
            for (masks ++ [_]u64{c.need & core.implemented}) |isa| {
                const legal = c.need & ~isa == 0;
                // a hot loop: a0 = a2; insn; 100 times
                putCode(&m, code_pa, 0, &.{ addi(10, 12, 0), c.insn, addi(5, 5, 1), branch(1, 5, 6, -12), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                const nvals: usize = if (legal and (isa == core.implemented or isa == c.need)) 24 else 1;
                for (0..nvals) |vi| {
                    const a = if (vi < 4) ([_]u64{ 0, std.math.maxInt(u64), 0x8000_0000_0000_0080, 0x0000_0000_8000_7fff })[vi] else rnd.int(u64);
                    const b = if (c.mem) 0x20000 + rnd.uintLessThan(u64, 4092) else rnd.int(u64);
                    m.regs.x[5] = 0;
                    m.regs.x[6] = 100;
                    m.regs.x[11] = b;
                    m.regs.x[12] = a;
                    m.regs.pc = 0x10000;
                    const ic = m.cpu.icount;
                    if (legal) {
                        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                        try t.expectEqual(@as(u64, 100), m.regs.x[5]);
                        if (m.regs.x[10] != c.ref(a, b) or m.regs.x[11] != b or m.regs.x[12] != a) {
                            std.debug.print("{s} ({s}, isa 0x{x}): a=0x{x} b=0x{x}: a0=0x{x} want 0x{x}\n", .{ c.name, @tagName(mode), isa, a, b, m.regs.x[10], c.ref(a, b) });
                            return error.TestUnexpectedResult;
                        }
                    } else {
                        try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                        // the trapping instruction is the first one of the word unless that is c.nop
                        const first_c = c.insn & 0xffff;
                        const at: u64 = if (first_c == c_nop and c.insn & 3 != 3) 0x10006 else 0x10004;
                        try t.expectEqual(at, m.regs.pc);
                        try t.expectEqual(@as(u64, if (c.insn & 3 == 3) c.insn else if (at == 0x10006) c.insn >> 16 else first_c), m.cpu.ev.insn);
                        try t.expectEqual(ic + 1 + (at - 0x10004) / 2, m.cpu.icount);
                    }
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}

test "kwemu rva23: Zcb c.sb / c.sh store exactly their bytes; a fault is precise" {
    var m = try Machine.init();
    defer m.deinit();
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    const data_pa = m.frame();
    m.map(0x20000, data_pa, R | W | U | A | D);
    m.map(0x21000, m.frame(), R | U | A); // read-only
    for ([_]JitMode{ .off, .eager }) |mode| {
        for ([_][3]u32{ .{ 2, 0, 0 }, .{ 2, 1, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 1 }, .{ 3, 0, 0 }, .{ 3, 0, 1 } }) |e| {
            const off: u64 = if (e[0] == 2) e[1] | (e[2] << 1) else e[2] << 1;
            const size: u64 = if (e[0] == 2) 1 else 2;
            @memset(m.bytes(data_pa), 0x5a);
            putCode(&m, code_pa, 0, &.{ addi(10, 12, 0), cPair(cZcbMem(e[0], e[1], e[2], 11, 10), c_nop), addi(12, 12, 1), addi(5, 5, 1), branch(1, 5, 6, -16), ecall });
            m.cpu.flushRange(0x10000, 0x11000);
            jitMode(&m, mode, 0);
            m.regs.x[5] = 0;
            m.regs.x[6] = 100;
            m.regs.x[11] = 0x20100;
            m.regs.x[12] = 0x1234_5678_9abc_de00;
            m.regs.pc = 0x10000;
            try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
            const last: u64 = 0x1234_5678_9abc_de00 + 99;
            for (m.bytes(data_pa), 0..) |b, i| {
                const want: u8 = if (i >= 0x100 + off and i < 0x100 + off + size) @truncate(last >> @intCast(8 * (i - 0x100 - off))) else 0x5a;
                try t.expectEqual(want, b);
            }
            // into the read-only page: a write fault at the store, nothing written
            m.regs.x[11] = 0x21000;
            m.regs.x[5] = 0;
            m.regs.pc = 0x10000;
            try t.expectEqual(@as(u32, EV_FAULT), m.run(10_000));
            try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
            try t.expectEqual(@as(u32, 1), m.cpu.ev.access);
            try t.expectEqual(@as(u64, 0x21000 + off), m.cpu.ev.addr);
            try checkJitSlots(&m);
        }
    }
}

test "kwemu rva23: Zicbom / Zicboz: cbo.zero zeroes the aligned block, permissions, A/D, SMC, cbo.inval and reserved encodings" {
    var m = try Machine.init();
    defer m.deinit();
    const code_pa = m.frame();
    m.map(0x10000, code_pa, RWX);
    const rw_pa = m.frame();
    m.map(0x20000, rw_pa, R | W | U | A | D);
    const ro_pa = m.frame();
    m.map(0x21000, ro_pa, R | U | A);
    const xo_pa = m.frame();
    m.map(0x22000, xo_pa, X | U | A);
    const nd_pa = m.frame();
    m.map(0x23000, nd_pa, R | W | U | A); // D clear: a store faults (the kernel sets D)
    // 0x24000 is not mapped
    const zicbom = core.bit(.zicbom);
    const zicboz = core.bit(.zicboz);
    const Ev = struct { ev: u32, access: u32 = 0 };
    const Case = struct { insn: u32, a0: u64, need: u64, want: Ev };
    const cases = [_]Case{
        .{ .insn = cbo(4, 10), .a0 = 0x20047, .need = zicboz, .want = .{ .ev = EV_SYSCALL } },
        .{ .insn = cbo(4, 10), .a0 = 0x20fff, .need = zicboz, .want = .{ .ev = EV_SYSCALL } },
        .{ .insn = cbo(4, 10), .a0 = 0x21040, .need = zicboz, .want = .{ .ev = EV_FAULT, .access = 1 } },
        .{ .insn = cbo(4, 10), .a0 = 0x22040, .need = zicboz, .want = .{ .ev = EV_FAULT, .access = 1 } },
        .{ .insn = cbo(4, 10), .a0 = 0x23040, .need = zicboz, .want = .{ .ev = EV_FAULT, .access = 1 } },
        .{ .insn = cbo(4, 10), .a0 = 0x24040, .need = zicboz, .want = .{ .ev = EV_FAULT, .access = 1 } },
        .{ .insn = cbo(1, 10), .a0 = 0x20047, .need = zicbom, .want = .{ .ev = EV_SYSCALL } },
        .{ .insn = cbo(2, 10), .a0 = 0x21001, .need = zicbom, .want = .{ .ev = EV_SYSCALL } }, // read-only: a load is permitted
        .{ .insn = cbo(1, 10), .a0 = 0x23040, .need = zicbom, .want = .{ .ev = EV_SYSCALL } },
        .{ .insn = cbo(2, 10), .a0 = 0x22040, .need = zicbom, .want = .{ .ev = EV_FAULT, .access = 1 } }, // exec-only
        .{ .insn = cbo(1, 10), .a0 = 0x24040, .need = zicbom, .want = .{ .ev = EV_FAULT, .access = 1 } }, // unmapped: a store fault
        .{ .insn = cbo(0, 10), .a0 = 0x20040, .need = never, .want = .{ .ev = EV_ILLEGAL } }, // cbo.inval: CBIE = 0
        .{ .insn = cbo(3, 10), .a0 = 0x20040, .need = never, .want = .{ .ev = EV_ILLEGAL } },
        .{ .insn = cbo(5, 10), .a0 = 0x20040, .need = never, .want = .{ .ev = EV_ILLEGAL } },
        .{ .insn = cbo(4, 10) | (1 << 7), .a0 = 0x20040, .need = never, .want = .{ .ev = EV_ILLEGAL } }, // rd != x0
        .{ .insn = cbo(1, 10) | (3 << 12), .a0 = 0x20040, .need = never, .want = .{ .ev = EV_ILLEGAL } }, // funct3 3
    };
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (cases) |c| {
            for ([_]u64{ core.implemented, core.implemented & ~zicbom, core.implemented & ~zicboz, 0 }) |isa| {
                @memset(m.bytes(rw_pa), 0xaa);
                @memset(m.bytes(ro_pa), 0xbb);
                @memset(m.bytes(nd_pa), 0xcc);
                putCode(&m, code_pa, 0, &.{ addi(5, 5, 1), c.insn, branch(1, 5, 6, -8), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 50;
                m.regs.x[10] = c.a0;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                const want: Ev = if (c.need & ~isa != 0 and c.need != never) .{ .ev = EV_ILLEGAL } else c.want;
                try t.expectEqual(want.ev, m.run(10_000));
                if (want.ev == EV_SYSCALL) {
                    try t.expectEqual(@as(u64, 50), m.regs.x[5]);
                } else {
                    try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
                    try t.expectEqual(ic + 1, m.cpu.icount);
                    if (want.ev == EV_ILLEGAL) try t.expectEqual(@as(u64, c.insn), m.cpu.ev.insn);
                    if (want.ev == EV_FAULT) {
                        try t.expectEqual(want.access, m.cpu.ev.access);
                        try t.expectEqual(c.a0 >> 12, m.cpu.ev.addr >> 12);
                    }
                }
                // only a cbo.zero that ran changed memory: its aligned 64-byte block
                const zeroed = want.ev == EV_SYSCALL and (c.insn >> 20) == 4;
                for (m.bytes(rw_pa), 0..) |b, i| {
                    const in_block = zeroed and i >> 6 == (c.a0 & 0xfff) >> 6;
                    try t.expectEqual(@as(u8, if (in_block) 0 else 0xaa), b);
                }
                for (m.bytes(ro_pa)) |b| try t.expectEqual(@as(u8, 0xbb), b);
                for (m.bytes(nd_pa)) |b| try t.expectEqual(@as(u8, 0xcc), b);
                try checkJitSlots(&m);
            }
        }
        // SMC: cbo.zero over code later in the same block, and over a block
        // that ran before; both take effect at the next instruction (0000 is
        // an illegal instruction).
        _ = kwemu.setIsa(m.cpu, core.implemented);
        for ([_]u64{ 0x10040, 0x10080 }) |target| {
            @memset(m.bytes(code_pa), 0);
            var words: [40]u32 = @splat(addi(7, 7, 1));
            words[0] = cbo(4, 10); // at 0x10000
            putCode(&m, code_pa, 0, &words);
            putCode(&m, code_pa, 0x100, &.{ addi(10, 0, 0), ecall });
            m.cpu.flushRange(0x10000, 0x11000);
            jitMode(&m, mode, 0);
            // first run the code at the target once (so it is decoded and,
            // with the eager JIT, compiled), from 0x10004 on
            m.regs.x[10] = 0x20000;
            m.regs.x[7] = 0;
            m.regs.pc = 0x10004;
            try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(1000)); // runs into the zero words at 0x100a0
            try t.expectEqual(@as(u64, 0x100a0), m.regs.pc);
            m.regs.x[10] = target;
            m.regs.x[7] = 0;
            m.regs.pc = 0x10000;
            try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(1000));
            try t.expectEqual(target, m.regs.pc);
            try t.expectEqual(@as(u64, 0), m.cpu.ev.insn);
            try t.expectEqual((target - 0x10004) / 4, m.regs.x[7]);
            try checkJitSlots(&m);
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}

// ---- Zfa -----------------------------------------------------------------------------

/// Round to an integral double with rm (host reference; NaN not handled).
fn refRoundInt(x: f64, rm: u32) f64 {
    const v = switch (rm) {
        0 => blk: { // RNE
            const tr = @trunc(x);
            if (@abs(x - tr) == 0.5) break :blk 2 * @round(x / 2);
            break :blk @round(x);
        },
        1 => @trunc(x),
        2 => @floor(x),
        3 => @ceil(x),
        else => @round(x), // RMM: half away from zero
    };
    return std.math.copysign(v, x); // a zero result keeps the sign
}

/// fcvtmod.w.d reference with 128-bit integers.
fn refFcvtmod(a: u64) struct { v: u64, fl: u32 } {
    const x: f64 = @bitCast(a);
    if (std.math.isNan(x) or std.math.isInf(x)) return .{ .v = 0, .fl = 0x10 };
    const tr = @trunc(x);
    var mag: u128 = 0;
    const ax = @abs(tr);
    if (ax >= 1) {
        const bits: u64 = @bitCast(ax);
        const e: i32 = @as(i32, @intCast(bits >> 52)) - 1075;
        const sig: u128 = (bits & ((1 << 52) - 1)) | (1 << 52);
        mag = if (e >= 0) (if (e < 128) sig << @intCast(e) else 0) else sig >> @intCast(-e);
    }
    const big = ax >= 0x1p64;
    const neg = x < 0;
    const fits = !big and (if (neg) mag <= 1 << 31 else mag < 1 << 31);
    const low: u32 = @truncate(if (neg) 0 -% mag else mag);
    const fl: u32 = if (!fits) 0x10 else if (tr != x) 0x01 else 0;
    return .{ .v = @bitCast(@as(i64, @as(i32, @bitCast(low)))), .fl = fl };
}

test "kwemu zfa: fli values, fround/froundnx, fminm/fmaxm, fleq/fltq, fcvtmod.w.d against references" {
    const F64 = core.fpu.F64;
    const F32 = core.fpu.F32;
    // fli: the spec's table
    const want = [_]f64{ -1.0, 0x1p-1022, 0x1p-16, 0x1p-15, 0x1p-8, 0x1p-7, 0.0625, 0.125, 0.25, 0.3125, 0.375, 0.4375, 0.5, 0.625, 0.75, 0.875, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 8.0, 16.0, 128.0, 256.0, 32768.0, 65536.0 };
    for (want, 0..) |v, i| {
        if (i != 1) try t.expectEqual(bitsD(v), core.fli_d[i]);
        if (i != 1) try t.expectEqual(bitsS(@floatCast(v)), core.fli_s[i]);
    }
    try t.expectEqual(@as(u64, 0x0010_0000_0000_0000), core.fli_d[1]);
    try t.expectEqual(@as(u32, 0x0080_0000), core.fli_s[1]);
    try t.expectEqual(F64.inf, core.fli_d[30]);
    try t.expectEqual(F64.qnan, core.fli_d[31]);
    try t.expectEqual(F32.inf, core.fli_s[30]);
    try t.expectEqual(F32.qnan, core.fli_s[31]);

    var prng = std.Random.DefaultPrng.init(0x7a6661);
    const rnd = prng.random();
    var vals: [20000]u64 = undefined;
    for (&vals, 0..) |*v, i| v.* = if (i < d_edges.len) d_edges[i] else switch (i % 4) {
        0 => fuzzVal(rnd, false),
        1 => bitsD(@as(f64, @floatFromInt(rnd.intRangeAtMost(i64, -5000, 5000))) / 4.0), // halves, quarters
        2 => bitsD(@as(f64, @floatFromInt(rnd.int(i64))) * 0x1p-20),
        else => rnd.int(u64),
    };
    for (vals) |a| {
        const x: f64 = @bitCast(a);
        // fround / froundnx, every mode
        for (0..5) |rmi| {
            const rm: u32 = @intCast(rmi);
            var fl: u32 = 0;
            var fl2: u32 = 0;
            const got = F64.roundInt(a, rm, false, &fl);
            const r2 = F64.roundInt(a, rm, true, &fl2);
            try t.expectEqual(got, r2);
            if (F64.isNan(a)) {
                try t.expectEqual(F64.qnan, got);
                try t.expectEqual(@as(u32, if (F64.isSnan(a)) 0x10 else 0), fl);
                continue;
            }
            const want_r = refRoundInt(x, rm);
            if (got != bitsD(want_r)) {
                std.debug.print("fround.d 0x{x} rm {d}: 0x{x}, want 0x{x}\n", .{ a, rm, got, bitsD(want_r) });
                return error.TestUnexpectedResult;
            }
            try t.expectEqual(@as(u32, 0), fl);
            try t.expectEqual(@as(u32, if (want_r != x) 1 else 0), fl2);
            // the single precision form on the value rounded to single
            const sx: f32 = @floatCast(x);
            const sb = bitsS(sx);
            var fs: u32 = 0;
            const rs = F32.roundInt(sb, rm, true, &fs);
            const want_s: f32 = @floatCast(refRoundInt(sx, rm));
            if (!std.math.isNan(sx)) {
                try t.expectEqual(bitsS(want_s), rs);
                try t.expectEqual(@as(u32, if (want_s != sx) 1 else 0), fs);
            }
        }
        // fcvtmod.w.d
        var fl: u32 = 0;
        const got = core.fpu.fcvtmodWD(a, &fl);
        const ref = refFcvtmod(a);
        if (got != ref.v or fl != ref.fl) {
            std.debug.print("fcvtmod.w.d 0x{x}: 0x{x} flags {x}, want 0x{x} flags {x}\n", .{ a, got, fl, ref.v, ref.fl });
            return error.TestUnexpectedResult;
        }
    }
    // fminm / fmaxm / fleq / fltq against fmin / fmax / fle / flt
    for (d_edges) |a| for (d_edges) |b| {
        const nan = F64.isNan(a) or F64.isNan(b);
        const snan = F64.isSnan(a) or F64.isSnan(b);
        var f1: u32 = 0;
        var f2: u32 = 0;
        try t.expectEqual(if (nan) F64.qnan else F64.min(a, b, &f2), F64.minm(a, b, &f1));
        try t.expectEqual(if (nan) F64.qnan else F64.max(a, b, &f2), F64.maxm(a, b, &f1));
        try t.expectEqual(@as(u32, if (snan) 0x10 else 0), f1);
        f1 = 0;
        f2 = 0;
        try t.expectEqual(F64.le(a, b, &f2), F64.leq(a, b, &f1));
        try t.expectEqual(F64.lt(a, b, &f2), F64.ltq(a, b, &f1));
        try t.expectEqual(@as(u32, if (snan) 0x10 else 0), f1);
        try t.expectEqual(@as(u32, if (nan) 0x10 else 0), f2);
    };
}

test "kwemu zfa: encodings and gates; .h forms, fmvh/fmvp and other neighbours stay illegal" {
    var m = try Machine.init();
    defer m.deinit();
    const zfa = core.bit(.zfa);
    const Probe = struct { insn: u32, need: u64 };
    const probes = [_]Probe{
        .{ .insn = fpR(0x1e, 0, 0, 10, 16, 1), .need = zfa }, // fli.s
        .{ .insn = fpR(0x1e, 1, 0, 10, 31, 1), .need = zfa }, // fli.d
        .{ .insn = fpR(5, 0, 2, 10, 11, 12), .need = zfa }, // fminm.s
        .{ .insn = fpR(5, 1, 3, 10, 11, 12), .need = zfa }, // fmaxm.d
        .{ .insn = fpR(8, 0, 2, 10, 11, 4), .need = zfa }, // fround.s rdn
        .{ .insn = fpR(8, 1, 7, 10, 11, 5), .need = zfa }, // froundnx.d dyn
        .{ .insn = fpR(0x18, 1, 1, 10, 11, 8), .need = zfa }, // fcvtmod.w.d
        .{ .insn = fpR(0x14, 0, 4, 10, 11, 12), .need = zfa }, // fleq.s
        .{ .insn = fpR(0x14, 1, 5, 10, 11, 12), .need = zfa }, // fltq.d
        .{ .insn = fpR(5, 0, 0, 10, 11, 12), .need = 1 }, // fmin.s: base F
        .{ .insn = fpR(0x14, 1, 1, 10, 11, 12), .need = 1 }, // flt.d
        // never legal here
        .{ .insn = fpR(0x1e, 2, 0, 10, 16, 1), .need = 0 }, // fli.h (needs Zfh)
        .{ .insn = fpR(5, 2, 2, 10, 11, 12), .need = 0 }, // fminm.h
        .{ .insn = fpR(8, 2, 0, 10, 11, 4), .need = 0 }, // fround.h
        .{ .insn = fpR(0x14, 2, 4, 10, 11, 12), .need = 0 }, // fleq.h
        .{ .insn = fpR(0x1e, 0, 1, 10, 16, 1), .need = 0 }, // fli.s with funct3 1
        .{ .insn = fpR(0x1e, 1, 0, 10, 16, 2), .need = 0 }, // rs2 2
        .{ .insn = fpR(5, 1, 4, 10, 11, 12), .need = 0 }, // fmin funct3 4
        .{ .insn = fpR(8, 1, 5, 10, 11, 4), .need = 0 }, // fround rm 5
        .{ .insn = fpR(8, 0, 0, 10, 11, 6), .need = 0 }, // funct5 8, rs2 6
        .{ .insn = fpR(0x18, 1, 0, 10, 11, 8), .need = 0 }, // fcvtmod.w.d with rne
        .{ .insn = fpR(0x18, 0, 1, 10, 11, 8), .need = 0 }, // fcvtmod.w.s does not exist
        .{ .insn = fpR(0x1c, 1, 0, 10, 11, 1), .need = 0 }, // fmvh.x.d (RV32 only)
        .{ .insn = fpR(0x16, 1, 0, 10, 11, 12), .need = 0 }, // fmvp.d.x (RV32 only)
        .{ .insn = fpR(0x14, 1, 3, 10, 11, 12), .need = 0 }, // fcmp funct3 3
        .{ .insn = fpR(0x14, 1, 6, 10, 11, 12), .need = 0 }, // fcmp funct3 6
    };
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (probes) |p| {
            for ([_]u64{ core.implemented, core.implemented & ~zfa, 0 }) |isa| {
                putCode(&m, code_pa, 0, &.{ addi(5, 5, 1), p.insn, branch(1, 5, 6, -8), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 50;
                m.regs.fcsr = 0;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                if (p.need == 1 or p.need & isa != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, p.insn), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
                    try t.expectEqual(ic + 1, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}

// ---- Zfhmin --------------------------------------------------------------------------

test "kwemu zfhmin: conversions between half and single/double against host conversions" {
    const F16 = core.fpu.F16;
    const F32 = core.fpu.F32;
    const F64 = core.fpu.F64;
    // every half: widening is exact (host f16 -> f32 / f64), and narrowing back gives it again
    for (0..65536) |i| {
        const hv: u16 = @intCast(i);
        var fl: u32 = 0;
        const s = F32.fromOther(u16, hv, 0, &fl);
        const d = F64.fromOther(u16, hv, 0, &fl);
        const hf: f16 = @bitCast(hv);
        if (F16.isNan(hv)) {
            try t.expectEqual(F32.qnan, s);
            try t.expectEqual(F64.qnan, d);
            try t.expectEqual(@as(u32, if (F16.isSnan(hv)) 0x10 else 0), fl);
            continue;
        }
        try t.expectEqual(@as(u32, 0), fl);
        try t.expectEqual(bitsS(@floatCast(hf)), s);
        try t.expectEqual(bitsD(@floatCast(hf)), d);
        for (0..5) |rm| {
            try t.expectEqual(hv, F16.fromOther(u32, s, @intCast(rm), &fl));
            try t.expectEqual(hv, F16.fromOther(u64, d, @intCast(rm), &fl));
        }
        try t.expectEqual(@as(u32, 0), fl);
    }
    // narrowing random singles and doubles with RNE: host conversion; NX iff
    // not exact; OF iff a finite value becomes infinite
    var prng = std.Random.DefaultPrng.init(0x7a6668);
    const rnd = prng.random();
    for (0..200_000) |i| {
        var sv = rnd.int(u32);
        if (i % 2 == 0) sv = (sv & 0x807f_ffff) | (@as(u32, 100 + rnd.uintLessThan(u32, 50)) << 23);
        const sf: f32 = @bitCast(sv);
        if (std.math.isNan(sf)) continue;
        var fl: u32 = 0;
        const got = F16.fromOther(u32, sv, 0, &fl);
        const want: f16 = @floatCast(sf);
        try t.expectEqual(@as(u16, @bitCast(want)), got);
        const exact = @as(f32, @floatCast(want)) == sf;
        try t.expectEqual(!exact, fl & 1 != 0);
        try t.expectEqual(std.math.isInf(want) and !std.math.isInf(sf), fl & 4 != 0);
    }
}

test "kwemu zfhmin: flh/fsh, fmv.x.h/fmv.h.x, NaN-boxing, encodings and gates; Zfh forms stay illegal" {
    var m = try Machine.init();
    defer m.deinit();
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    const data_pa = m.frame();
    m.map(0x20000, data_pa, R | W | U | A | D);
    const zfh = core.bit(.zfhmin);
    const flh = itype(0x07, 1, 10, 11, 6); // flh fa0, 6(a1)
    const fsh = store(1, 12, 11, 10) ^ 0x23 ^ 0x27; // fsh fa2, 10(a1)
    const Probe = struct { insn: u32, need: u64 };
    const probes = [_]Probe{
        .{ .insn = flh, .need = zfh },
        .{ .insn = fsh, .need = zfh },
        .{ .insn = fpR(0x1c, 2, 0, 13, 12, 0), .need = zfh }, // fmv.x.h a3, fa2
        .{ .insn = fpR(0x1e, 2, 0, 14, 13, 0), .need = zfh }, // fmv.h.x fa4, a3
        .{ .insn = fpR(8, 0, 7, 15, 12, 2), .need = zfh }, // fcvt.s.h fa5, fa2
        .{ .insn = fpR(8, 1, 0, 16, 12, 2), .need = zfh }, // fcvt.d.h fa6, fa2
        .{ .insn = fpR(8, 2, 0, 17, 15, 0), .need = zfh }, // fcvt.h.s fa7, fa5
        .{ .insn = fpR(8, 2, 3, 17, 16, 1), .need = zfh }, // fcvt.h.d fa7, fa6, rup
        // Zfh (not Zfhmin), and reserved neighbours
        .{ .insn = fpR(0, 2, 0, 10, 11, 12), .need = 0 }, // fadd.h
        .{ .insn = fpR(0x0b, 2, 0, 10, 11, 0), .need = 0 }, // fsqrt.h
        .{ .insn = fpR(4, 2, 0, 10, 11, 12), .need = 0 }, // fsgnj.h
        .{ .insn = fpR(0x14, 2, 2, 10, 11, 12), .need = 0 }, // feq.h
        .{ .insn = fpR(0x1c, 2, 1, 10, 11, 0), .need = 0 }, // fclass.h
        .{ .insn = fpR(0x18, 2, 0, 10, 11, 0), .need = 0 }, // fcvt.w.h
        .{ .insn = fpR(0x1a, 2, 0, 10, 11, 0), .need = 0 }, // fcvt.h.w
        .{ .insn = fpR(8, 2, 0, 10, 11, 2), .need = 0 }, // fcvt.h.h
        .{ .insn = fpR(8, 2, 5, 17, 15, 0), .need = 0 }, // fcvt.h.s with rm 5
        .{ .insn = fpR(8, 0, 6, 15, 12, 2), .need = 0 }, // fcvt.s.h with rm 6
        .{ .insn = fpR(0x1c, 2, 0, 13, 12, 1), .need = 0 }, // fmv.x.h with rs2 1
        .{ .insn = fpR(8, 3, 0, 10, 11, 2), .need = 0 }, // fcvt.q.h
        .{ .insn = itype(0x07, 4, 10, 11, 0), .need = 0 }, // flq
    };
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (probes) |p| {
            for ([_]u64{ core.implemented, core.implemented & ~zfh, 0 }) |isa| {
                putCode(&m, code_pa, 0, &.{ addi(5, 5, 1), p.insn, branch(1, 5, 6, -8), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 20;
                m.regs.x[11] = 0x20000;
                m.regs.x[13] = 0x1234_5678_9abc_bc00;
                m.regs.f[12] = 0xffff_ffff_ffff_c500; // -5.0 (half)
                m.regs.f[15] = 0xffff_ffff_4049_0fdb; // pi (single)
                m.regs.f[16] = 0x3ff0_0000_0000_0001; // 1 + 2^-52
                m.regs.fcsr = 0;
                m.regs.pc = 0x10000;
                @memset(m.bytes(data_pa), 0);
                std.mem.writeInt(u16, m.bytes(data_pa)[6..8], 0x7bff, .little);
                const ic = m.cpu.icount;
                if (p.need & isa != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, p.insn), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
                    try t.expectEqual(ic + 1, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    // the results
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
    for ([_]JitMode{ .off, .eager }) |mode| {
        putCode(&m, code_pa, 0, &.{
            flh, fsh, probes[2].insn, probes[3].insn, probes[4].insn, probes[5].insn, probes[6].insn, probes[7].insn,
            fpR(0x1c, 2, 0, 18, 16, 0), // fmv.x.h s2, fa6 (the low 16 bits of a double, not unboxed)
            fpR(8, 1, 0, 9, 16, 2), // fcvt.d.h fs1, fa6: fa6 is not a boxed half: the canonical NaN
            ecall,
        });
        m.cpu.flushRange(0x10000, 0x11000);
        jitMode(&m, mode, 0);
        @memset(m.bytes(data_pa), 0);
        std.mem.writeInt(u16, m.bytes(data_pa)[6..8], 0x7bff, .little); // 65504, the largest half
        m.regs.x[11] = 0x20000;
        m.regs.x[13] = 0;
        m.regs.f[12] = 0xffff_ffff_ffff_c500;
        m.regs.fcsr = 0;
        m.regs.pc = 0x10000;
        try t.expectEqual(@as(u32, EV_SYSCALL), m.run(100));
        try t.expectEqual(core.boxH(0x7bff), m.regs.f[10]); // flh
        try t.expectEqual(@as(u16, 0xc500), std.mem.readInt(u16, m.bytes(data_pa)[10..12], .little)); // fsh
        try t.expectEqual(@as(u64, 0xffff_ffff_ffff_c500), m.regs.x[13]); // fmv.x.h sign-extends
        try t.expectEqual(core.boxH(0xc500), m.regs.f[14]); // fmv.h.x
        try t.expectEqual(core.box(bitsS(-5.0)), m.regs.f[15]); // fcvt.s.h
        try t.expectEqual(bitsD(-5.0), m.regs.f[16]); // fcvt.d.h
        try t.expectEqual(core.boxH(0xc500), m.regs.f[17]); // fcvt.h.d (rup) of -5.0
        try t.expectEqual(@as(u64, 0), m.regs.x[18]); // -5.0 = 0xc014000000000000: low 16 bits 0
        try t.expectEqual(core.fpu.F64.qnan, m.regs.f[9]);
        try t.expectEqual(@as(u32, 0), m.regs.fcsr);
    }
}

// ---- Zihpm ---------------------------------------------------------------------------

test "kwemu zihpm: hpmcounter3..31 read 0; writes, hpmcounterNh and neighbours stay illegal" {
    var m = try Machine.init();
    defer m.deinit();
    const code_pa = m.frame();
    m.map(0x10000, code_pa, R | X | U | A);
    const zihpm = core.bit(.zihpm);
    const csr = struct {
        fn f(f3: u32, rd: u32, rs1: u32, num: u32) u32 {
            return (num << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73;
        }
    }.f;
    const Probe = struct { insn: u32, need: u64 };
    var probes: [29 + 8]Probe = undefined;
    for (3..32) |n| probes[n - 3] = .{ .insn = csr(2, 10, 0, @intCast(0xc00 + n)), .need = zihpm }; // csrr a0, hpmcounterN
    probes[29] = .{ .insn = csr(6, 10, 0, 0xc11), .need = zihpm }; // csrrsi a0, hpmcounter17, 0
    probes[30] = .{ .insn = csr(3, 10, 0, 0xc1f), .need = zihpm }; // csrrc a0, hpmcounter31, x0
    probes[31] = .{ .insn = csr(1, 10, 11, 0xc03), .need = 0 }; // csrw: read-only
    probes[32] = .{ .insn = csr(2, 10, 11, 0xc04), .need = 0 }; // csrrs with rs1 != x0: a write
    probes[33] = .{ .insn = csr(5, 10, 1, 0xc05), .need = 0 }; // csrrwi
    probes[34] = .{ .insn = csr(2, 10, 0, 0xc83), .need = 0 }; // hpmcounter3h (RV32)
    probes[35] = .{ .insn = csr(2, 10, 0, 0xc20), .need = 0 };
    probes[36] = .{ .insn = csr(2, 10, 0, 0xb03), .need = 0 }; // mhpmcounter3 (M-mode)
    for ([_]JitMode{ .off, .eager }) |mode| {
        for (probes) |p| {
            for ([_]u64{ core.implemented, core.implemented & ~zihpm, 0 }) |isa| {
                putCode(&m, code_pa, 0, &.{ addi(5, 5, 1), p.insn, branch(1, 5, 6, -8), ecall });
                m.cpu.flushRange(0x10000, 0x11000);
                jitMode(&m, mode, 0);
                _ = kwemu.setIsa(m.cpu, isa);
                m.regs.x[5] = 0;
                m.regs.x[6] = 20;
                m.regs.x[10] = 0x5555;
                m.regs.x[11] = 7;
                m.regs.pc = 0x10000;
                const ic = m.cpu.icount;
                if (p.need & isa != 0) {
                    try t.expectEqual(@as(u32, EV_SYSCALL), m.run(10_000));
                    try t.expectEqual(@as(u64, 0), m.regs.x[10]);
                    try t.expectEqual(ic + 61, m.cpu.icount);
                } else {
                    try t.expectEqual(@as(u32, EV_ILLEGAL), m.run(10_000));
                    try t.expectEqual(@as(u64, p.insn), m.cpu.ev.insn);
                    try t.expectEqual(@as(u64, 0x10004), m.regs.pc);
                    try t.expectEqual(@as(u64, 0x5555), m.regs.x[10]);
                    try t.expectEqual(ic + 1, m.cpu.icount);
                }
                try checkJitSlots(&m);
            }
        }
    }
    _ = kwemu.setIsa(m.cpu, std.math.maxInt(u64));
}
