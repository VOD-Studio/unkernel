// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! A tiny "kernel" that drives kwemu through the C ABI only (include/kw_emu.h
//! via translate-c), the way the real wasm Linux kernel will:
//!
//!   * builds Sv39 page tables in its own "physical memory" buffer
//!     (physical address 0x8000_0000 = first byte of the buffer, so
//!     phys_base is non-trivial);
//!   * loads a static riscv64 ELF, builds argv/envp/auxv on the stack;
//!   * demand paging: mmap/brk/stack only *reserve* pages (non-valid PTEs
//!     carrying a software "reserved" bit + prot); faults allocate frames;
//!   * new PTEs start with A=0/D=0, so the emulator faults again and the
//!     kernel sets A (and D on writes) and flushes the TLB range - this
//!     exercises the A/D protocol on every page;
//!   * runs in budget slices, clears the LR/SC reservation on every trap
//!     return, and services ~40 Linux syscalls (enough for static musl).
//!
//! Platform-independent: native and wasm front ends supply a `Host`.

const std = @import("std");
const kw = @import("kw_h");

pub const Host = struct {
    write: *const fn (fd: i32, bytes: []const u8) void,
    now_ns: *const fn () u64,
};

pub const Options = struct {
    /// Instructions per kw_run call (the "timer tick").
    slice: u64 = 2_000_000,
    stats: bool = false,
    verbose: bool = false,
};

const page: u64 = 4096;
const pa_base: u64 = 0x8000_0000;

const pte_v: u64 = 1 << 0;
const pte_r: u64 = 1 << 1;
const pte_w: u64 = 1 << 2;
const pte_x: u64 = 1 << 3;
const pte_u: u64 = 1 << 4;
const pte_a: u64 = 1 << 6;
const pte_d: u64 = 1 << 7;
const pte_resv: u64 = 1 << 8; // software: reserved, not yet populated
const prot_bits = pte_r | pte_w | pte_x;

const stack_top: u64 = 0x3f_ffff_0000;
const stack_size: u64 = 8 << 20;
const mmap_base: u64 = 0x3f_0000_0000;

// errno
const ENOENT = 2;
const EBADF = 9;
const ENOMEM = 12;
const EFAULT = 14;
const EINVAL = 22;
const ENOTTY = 25;
const ESPIPE = 29;
const ENOSYS = 38;

pub const Stats = struct {
    syscalls: u64 = 0,
    demand_faults: u64 = 0,
    ad_faults: u64 = 0,
    spurious_faults: u64 = 0,
    slices: u64 = 0,
};

pub const Machine = struct {
    host: Host,
    opt: Options,
    mem: []align(4096) u8,
    next_frame: u64 = 0,
    root: u64 = 0,
    cpu: *kw.struct_kw_cpu,
    regs: kw.struct_kw_regs = std.mem.zeroes(kw.struct_kw_regs),
    brk_start: u64 = 0,
    brk: u64 = 0,
    mmap_top: u64 = mmap_base,
    exit_code: ?u8 = null,
    rng: u64 = 0x9e37_79b9_7f4a_7c15,
    stats: Stats = .{},

    pub fn init(host: Host, opt: Options, mem: []align(4096) u8, cpu_block: *align(8) [kw.KW_CPU_SIZE]u8) Machine {
        var m: Machine = .{ .host = host, .opt = opt, .mem = mem, .cpu = @ptrCast(cpu_block) };
        kw.kw_cpu_init(m.cpu);
        m.cpu.phys_base = @intFromPtr(mem.ptr) -% pa_base;
        m.root = m.allocFrame();
        kw.kw_set_pgd(m.cpu, m.root);
        return m;
    }

    fn print(m: *Machine, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        m.host.write(2, std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    // ---- physical memory / page tables ------------------------------------------

    fn allocFrame(m: *Machine) u64 {
        if (m.next_frame + page > m.mem.len) {
            m.print("harness: out of physical memory\n", .{});
            @panic("oom");
        }
        const pa = pa_base + m.next_frame;
        m.next_frame += page; // bump allocator: frames are never reused, so already zero
        return pa;
    }

    fn hostPtr(m: *Machine, pa: u64) [*]u8 {
        return m.mem.ptr + @as(usize, @intCast(pa - pa_base));
    }

    fn table(m: *Machine, pa: u64) *[512]u64 {
        return @ptrCast(@alignCast(m.hostPtr(pa)));
    }

    /// Leaf PTE slot for `va`, creating intermediate tables if `create`.
    fn slot(m: *Machine, va: u64, create: bool) ?*u64 {
        var t = m.root;
        var level: u6 = 2;
        while (level > 0) : (level -= 1) {
            const e = &m.table(t)[@intCast((va >> (12 + 9 * level)) & 511)];
            if (e.* & pte_v == 0) {
                if (!create) return null;
                e.* = ((m.allocFrame() >> 12) << 10) | pte_v; // non-leaf
            }
            t = (e.* >> 10) << 12;
        }
        return &m.table(t)[@intCast((va >> 12) & 511)];
    }

    fn protPte(prot: u64) u64 {
        var p: u64 = 0;
        if (prot & 1 != 0) p |= pte_r;
        if (prot & 2 != 0) p |= pte_w | pte_r; // W requires R in Sv39
        if (prot & 4 != 0) p |= pte_x;
        return p;
    }

    fn reserve(m: *Machine, start: u64, end: u64, prot: u64) void {
        var va = start;
        while (va < end) : (va += page) {
            const s = m.slot(va, true).?;
            if (s.* & pte_v != 0) {
                s.* = (s.* & ~prot_bits) | protPte(prot);
            } else s.* = pte_resv | protPte(prot);
        }
        kw.kw_flush_tlb_range(m.cpu, start, end);
    }

    fn unmap(m: *Machine, start: u64, end: u64) void {
        var va = start;
        while (va < end) : (va += page) {
            if (m.slot(va, false)) |s| s.* = 0; // frames leak; fine for tests
        }
        kw.kw_flush_tlb_range(m.cpu, start, end);
    }

    fn protect(m: *Machine, start: u64, end: u64, prot: u64) void {
        var va = start;
        while (va < end) : (va += page) {
            const s = m.slot(va, false) orelse continue;
            if (s.* & (pte_v | pte_resv) != 0) s.* = (s.* & ~prot_bits) | protPte(prot);
        }
        kw.kw_flush_tlb_range(m.cpu, start, end);
    }

    /// Give a reserved page a frame. New PTEs have A=0, D=0.
    fn populate(m: *Machine, s: *u64) void {
        const frame = m.allocFrame();
        s.* = ((frame >> 12) << 10) | (s.* & prot_bits) | pte_v | pte_u;
        m.stats.demand_faults += 1;
    }

    /// Kernel-side access to user memory (copy_{to,from}_user): returns the
    /// host bytes of the page containing `va`, from `va` to the page end.
    fn userPage(m: *Machine, va: u64) ?[]u8 {
        const s = m.slot(va, false) orelse return null;
        if (s.* & pte_v == 0) {
            if (s.* & pte_resv == 0) return null;
            m.populate(s);
        }
        const off: usize = @intCast(va & (page - 1));
        return m.hostPtr(((s.* >> 10) & ((1 << 44) - 1)) << 12)[off..page];
    }

    fn copyOut(m: *Machine, va: u64, bytes: []const u8) bool {
        var done: usize = 0;
        while (done < bytes.len) {
            const p = m.userPage(va + done) orelse return false;
            const n = @min(p.len, bytes.len - done);
            @memcpy(p[0..n], bytes[done..][0..n]);
            done += n;
        }
        return true;
    }

    fn copyIn(m: *Machine, va: u64, out: []u8) bool {
        var done: usize = 0;
        while (done < out.len) {
            const p = m.userPage(va + done) orelse return false;
            const n = @min(p.len, out.len - done);
            @memcpy(out[done..][0..n], p[0..n]);
            done += n;
        }
        return true;
    }

    fn put64(m: *Machine, va: u64, v: u64) void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        _ = m.copyOut(va, &b);
    }
    fn get64(m: *Machine, va: u64) ?u64 {
        var b: [8]u8 = undefined;
        if (!m.copyIn(va, &b)) return null;
        return std.mem.readInt(u64, &b, .little);
    }

    // ---- ELF loading ---------------------------------------------------------------

    pub fn load(m: *Machine, image: []const u8, argv: []const []const u8, envp: []const []const u8) !void {
        const rd = struct {
            fn f(comptime T: type, b: []const u8, off: u64) T {
                return std.mem.readInt(T, b[@intCast(off)..][0..@sizeOf(T)], .little);
            }
        }.f;
        if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF") or image[4] != 2 or image[5] != 1) return error.BadElf;
        if (rd(u16, image, 18) != 243) return error.NotRiscv;
        const etype = rd(u16, image, 16);
        const flags = rd(u32, image, 48);
        const entry0 = rd(u64, image, 24);
        const phoff = rd(u64, image, 32);
        const phentsize = rd(u16, image, 54);
        const phnum = rd(u16, image, 56);
        const bias: u64 = if (etype == 3) 0x1000_0000 else 0;
        if (m.opt.verbose) m.print("[harness] e_flags=0x{x} (float abi {s}, rvc={})\n", .{
            flags, switch ((flags >> 1) & 3) {
                0 => "soft",
                1 => "single",
                2 => "double",
                else => "quad",
            }, flags & 1 != 0,
        });

        var phdr_va: u64 = 0;
        var max_end: u64 = 0;
        for (0..phnum) |i| {
            const ph = phoff + i * phentsize;
            const ptype = rd(u32, image, ph);
            const pflags = rd(u32, image, ph + 4);
            const off = rd(u64, image, ph + 8);
            const vaddr = rd(u64, image, ph + 16) + bias;
            const filesz = rd(u64, image, ph + 32);
            const memsz = rd(u64, image, ph + 40);
            if (ptype == 3) return error.DynamicElf; // PT_INTERP
            if (ptype == 6) phdr_va = vaddr; // PT_PHDR
            if (ptype != 1 or memsz == 0) continue;
            if (phdr_va == 0 and off <= phoff and phoff < off + filesz) phdr_va = vaddr + (phoff - off);
            const start = vaddr & ~(page - 1);
            const end = (vaddr + memsz + page - 1) & ~(page - 1);
            var prot: u64 = 0;
            if (pflags & 4 != 0) prot |= 1;
            if (pflags & 2 != 0) prot |= 2;
            if (pflags & 1 != 0) prot |= 4;
            // Segments may share a page: merge permissions.
            var va = start;
            while (va < end) : (va += page) {
                const s = m.slot(va, true).?;
                s.* |= protPte(prot);
                if (s.* & pte_v == 0) s.* |= pte_resv;
            }
            if (!m.copyOut(vaddr, image[@intCast(off)..][0..@intCast(filesz)])) return error.BadElf;
            max_end = @max(max_end, end);
        }
        m.brk_start = max_end;
        m.brk = max_end;

        // Stack: reserve, then argv/envp/auxv at the top.
        m.reserve(stack_top - stack_size, stack_top, 3);
        var sp = stack_top;
        var ptrs: [64]u64 = undefined;
        var n: usize = 0;
        for (argv) |a| {
            sp -= a.len + 1;
            _ = m.copyOut(sp, a);
            _ = m.copyOut(sp + a.len, &.{0});
            ptrs[n] = sp;
            n += 1;
        }
        for (envp) |e| {
            sp -= e.len + 1;
            _ = m.copyOut(sp, e);
            _ = m.copyOut(sp + e.len, &.{0});
            ptrs[n] = sp;
            n += 1;
        }
        sp -= 16;
        const random_va = sp;
        var rnd: [16]u8 = undefined;
        for (&rnd) |*b| b.* = @truncate(m.random());
        _ = m.copyOut(random_va, &rnd);
        const hwcap: u64 = (1 << ('i' - 'a')) | (1 << ('m' - 'a')) | (1 << ('a' - 'a')) |
            (1 << ('f' - 'a')) | (1 << ('d' - 'a')) | (1 << ('c' - 'a'));
        const auxv = [_][2]u64{
            .{ 3, phdr_va },      .{ 4, phentsize }, .{ 5, phnum }, .{ 6, page },
            .{ 7, 0 },            .{ 8, 0 },         .{ 9, entry0 + bias }, .{ 11, 0 },
            .{ 12, 0 },           .{ 13, 0 },        .{ 14, 0 },    .{ 16, hwcap },
            .{ 17, 100 },         .{ 23, 0 },        .{ 25, random_va },
            .{ 31, if (argv.len > 0) ptrs[0] else 0 }, .{ 0, 0 },
        };
        const words = 1 + argv.len + 1 + envp.len + 1 + auxv.len * 2;
        sp = (sp - words * 8) & ~@as(u64, 15);
        var w = sp;
        m.put64(w, argv.len);
        w += 8;
        for (0..argv.len) |i| {
            m.put64(w, ptrs[i]);
            w += 8;
        }
        m.put64(w, 0);
        w += 8;
        for (0..envp.len) |i| {
            m.put64(w, ptrs[argv.len + i]);
            w += 8;
        }
        m.put64(w, 0);
        w += 8;
        for (auxv) |av| {
            m.put64(w, av[0]);
            m.put64(w + 8, av[1]);
            w += 16;
        }
        m.regs.pc = entry0 + bias;
        m.regs.x[2] = sp;
    }

    fn random(m: *Machine) u64 {
        m.rng ^= m.rng << 13;
        m.rng ^= m.rng >> 7;
        m.rng ^= m.rng << 17;
        return m.rng;
    }

    // ---- run loop ------------------------------------------------------------------

    /// Run until the guest exits; returns its exit status (128+sig on a fatal trap).
    pub fn run(m: *Machine) u8 {
        const t0 = m.host.now_ns();
        while (m.exit_code == null) {
            m.cpu.budget = m.opt.slice;
            const kind = kw.kw_run(m.cpu, &m.regs);
            const ev = m.cpu.ev;
            switch (kind) {
                kw.KW_EV_BUDGET => m.stats.slices += 1,
                kw.KW_EV_INTERRUPT => {},
                kw.KW_EV_SYSCALL => {
                    m.syscall();
                    kw.kw_clear_reservation(m.cpu);
                },
                kw.KW_EV_FAULT => {
                    m.fault(ev.addr, ev.access);
                    kw.kw_clear_reservation(m.cpu);
                },
                kw.KW_EV_ILLEGAL => m.die(4, "illegal instruction 0x{x} at pc=0x{x}", .{ ev.insn, m.regs.pc }),
                kw.KW_EV_BREAKPOINT => m.die(5, "breakpoint at pc=0x{x}", .{m.regs.pc}),
                kw.KW_EV_MISALIGNED => m.die(7, "misaligned atomic at 0x{x} pc=0x{x}", .{ ev.addr, m.regs.pc }),
                else => m.die(6, "unknown event {d}", .{kind}),
            }
        }
        const dt = @max(m.host.now_ns() - t0, 1);
        if (m.opt.stats and @import("kwemu_options").stats) {
            // layout of kwemu.Stats: 11 counters, op_hist[nk], jit_insns,
            // jit_handbacks, jit_hb[nk], jit_hb_gen[40], jit_jx[64], with nk =
            // kwemu.max_ops (192)
            const nk = 192;
            const n_st = 11 + nk + 2 + nk + 40 + 64;
            var st: [n_st]u64 = undefined;
            @extern(*const fn (*kw.struct_kw_cpu, *[n_st]u64) callconv(.c) void, .{ .name = "kw_debug_stats" })(m.cpu, &st);
            printJitStats(m, st[n_st - 64 ..]);
            var line: [2048]u8 = undefined;
            var pos: usize = 0;
            for (st[11..][0..nk], 0..) |v, i| {
                if (v * 200 < m.cpu.icount) continue; // >= 0.5%
                const sl = std.fmt.bufPrint(line[pos..], " op{d}={d:.1}%", .{ i, @as(f64, @floatFromInt(v)) * 100 / @as(f64, @floatFromInt(m.cpu.icount)) }) catch break;
                pos += sl.len;
            }
            m.print("[kwemu-ops]{s}\n", .{line[0..pos]});
            const jit_insns = st[11 + nk];
            const hbs = st[12 + nk];
            if (jit_insns != 0 or hbs != 0) {
                pos = 0;
                // hand-backs per op handler (>= 1% of all hand-backs), then
                // per generic class (g<OP-FP funct5>, g32 SYSTEM, g33 AMO, ...)
                for (st[13 + nk ..][0..nk], 0..) |v, i| {
                    if (v == 0 or v * 100 < hbs) continue;
                    const sl = std.fmt.bufPrint(line[pos..], " op{d}={d}", .{ i, v }) catch break;
                    pos += sl.len;
                }
                for (st[13 + 2 * nk ..][0..40], 0..) |v, i| {
                    if (v == 0 or v * 100 < hbs) continue;
                    const sl = std.fmt.bufPrint(line[pos..], " g{d}={d}", .{ i, v }) catch break;
                    pos += sl.len;
                }
                m.print("[kwemu-jit] compiled insns={d:.2}% handbacks={d} (per 1M insns: {d:.1}):{s}\n", .{
                    @as(f64, @floatFromInt(jit_insns)) * 100 / @as(f64, @floatFromInt(@max(m.cpu.icount, 1))),
                    hbs,
                    @as(f64, @floatFromInt(hbs)) * 1e6 / @as(f64, @floatFromInt(@max(m.cpu.icount, 1))),
                    line[0..pos],
                });
            }
            m.print("[kwemu-stats] lookups_slow={d} revalidated={d} decoded={d} resets={d} blocks={d} insns/block={d:.2} single_steps={d} walks r/w/x={d}/{d}/{d} generic={d}\n", .{
                st[0], st[1], st[2], st[3], st[4], @as(f64, @floatFromInt(st[5])) / @as(f64, @floatFromInt(@max(st[4], 1))), st[6], st[7], st[8], st[9], st[10],
            });
        }
        if (m.opt.stats) {
            const n = m.cpu.icount;
            const mips = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(dt)) * 1000.0;
            m.print("[kwemu] instret={d} time={d}ms MIPS={d:.1} syscalls={d} demand_faults={d} ad_faults={d} spurious={d} frames={d}\n", .{
                n,                     dt / 1_000_000,          mips,                    m.stats.syscalls,
                m.stats.demand_faults, m.stats.ad_faults,       m.stats.spurious_faults, m.next_frame / page,
            });
        }
        return m.exit_code.?;
    }

    /// -Dkwemu-stats: the JIT counters (Stats.jit.jx, indices in jit.zig `Jx`), if any.
    fn printJitStats(m: *Machine, jx: []const u64) void {
        var line: [64 * 21]u8 = undefined;
        var pos: usize = 0;
        var any = false;
        for (jx) |v| {
            any = any or v != 0;
            const sl = std.fmt.bufPrint(line[pos..], " {d}", .{v}) catch break;
            pos += sl.len;
        }
        if (any) m.print("[kwemu-jx]{s}\n", .{line[0..pos]});
    }

    fn die(m: *Machine, sig: u8, comptime fmt: []const u8, args: anytype) void {
        m.print("[harness] " ++ fmt ++ "\n", args);
        m.exit_code = 128 + sig;
    }

    fn fault(m: *Machine, va: u64, access: u32) void {
        const pg = va & ~(page - 1);
        const s = m.slot(va, false) orelse return m.die(11, "segfault at 0x{x} (no table) pc=0x{x}", .{ va, m.regs.pc });
        const pte = s.*;
        if (pte & pte_v == 0) {
            if (pte & pte_resv == 0) return m.die(11, "segfault at 0x{x} pc=0x{x}", .{ va, m.regs.pc });
            m.populate(s);
            return; // retry: will fault again for A (and D)
        }
        const need: u64 = switch (access) {
            kw.KW_ACCESS_READ => pte_r,
            kw.KW_ACCESS_WRITE => pte_w,
            else => pte_x,
        };
        if (pte & need == 0 or pte & pte_u == 0)
            return m.die(11, "protection fault ({d}) at 0x{x} pc=0x{x}", .{ access, va, m.regs.pc });
        const new = pte | pte_a | (if (access == kw.KW_ACCESS_WRITE) pte_d else 0);
        if (new == pte) {
            m.stats.spurious_faults += 1;
            if (m.stats.spurious_faults > 1000) return m.die(11, "fault loop at 0x{x}", .{va});
        } else m.stats.ad_faults += 1;
        s.* = new;
        kw.kw_flush_tlb_range(m.cpu, pg, pg + page);
    }

    // ---- syscalls --------------------------------------------------------------------

    fn neg(e: u64) u64 {
        return 0 -% e;
    }

    fn syscall(m: *Machine) void {
        m.stats.syscalls += 1;
        const nr = m.regs.x[17];
        const a = m.regs.x[10..16];
        const ret: u64 = switch (nr) {
            29 => neg(ENOTTY), // ioctl
            56, 48, 78 => neg(ENOENT), // openat, faccessat, readlinkat
            57 => 0, // close
            62 => neg(ESPIPE), // lseek
            63 => 0, // read: EOF
            64 => m.sysWrite(a[0], a[1], a[2]),
            66 => blk: { // writev
                var total: u64 = 0;
                for (0..a[2]) |i| {
                    const base = m.get64(a[1] + i * 16) orelse break :blk neg(EFAULT);
                    const len = m.get64(a[1] + i * 16 + 8) orelse break :blk neg(EFAULT);
                    const r = m.sysWrite(a[0], base, len);
                    if (@as(i64, @bitCast(r)) < 0) break :blk r;
                    total += r;
                }
                break :blk total;
            },
            79, 80, 291 => neg(ENOSYS), // fstatat, fstat, statx
            93, 94 => { // exit, exit_group
                m.exit_code = @truncate(a[0]);
                return;
            },
            96 => 1, // set_tid_address
            98 => 0, // futex
            99 => 0, // set_robust_list
            101, 124 => 0, // nanosleep, sched_yield
            113 => blk: { // clock_gettime
                const ns = m.host.now_ns();
                m.put64(a[1], ns / 1_000_000_000);
                m.put64(a[1] + 8, ns % 1_000_000_000);
                break :blk 0;
            },
            129, 130, 131 => { // kill, tkill, tgkill
                const sig = if (nr == 131) a[2] else a[1];
                m.die(@truncate(sig), "killed by signal {d}", .{sig});
                return;
            },
            132, 134, 135 => 0, // sigaltstack, rt_sigaction, rt_sigprocmask
            160 => blk: { // uname
                var u: [6 * 65]u8 = @splat(0);
                for ([_][]const u8{ "Linux", "kwemu", "6.12.0", "#1", "riscv64", "" }, 0..) |s, i| @memcpy(u[i * 65 ..][0..s.len], s);
                break :blk if (m.copyOut(a[0], &u)) 0 else neg(EFAULT);
            },
            172, 178 => 1, // getpid, gettid
            173, 174, 175, 176, 177 => 0, // getppid, get[e]uid, get[e]gid
            214 => m.sysBrk(a[0]),
            215 => blk: { // munmap
                if (a[0] & (page - 1) != 0) break :blk neg(EINVAL);
                m.unmap(a[0], a[0] + pageUp(a[1]));
                break :blk 0;
            },
            216 => neg(ENOMEM), // mremap
            222 => m.sysMmap(a[0], a[1], a[2], a[3], a[4]),
            226 => blk: { // mprotect
                m.protect(a[0], a[0] + pageUp(a[1]), a[2]);
                break :blk 0;
            },
            233 => 0, // madvise
            259 => 0, // riscv_flush_icache
            261, 163, 293 => neg(ENOSYS), // prlimit64, getrlimit, rseq
            278 => blk: { // getrandom
                var i: u64 = 0;
                while (i < a[1]) : (i += 1) _ = m.copyOut(a[0] + i, &.{@as(u8, @truncate(m.random()))});
                break :blk a[1];
            },
            else => blk: {
                if (m.opt.verbose) m.print("[harness] unimplemented syscall {d}\n", .{nr});
                break :blk neg(ENOSYS);
            },
        };
        m.regs.x[10] = ret;
    }

    fn pageUp(v: u64) u64 {
        return (v + page - 1) & ~(page - 1);
    }

    fn sysWrite(m: *Machine, fd: u64, buf: u64, len: u64) u64 {
        if (fd != 1 and fd != 2) return neg(EBADF);
        var done: u64 = 0;
        while (done < len) {
            const p = m.userPage(buf + done) orelse return if (done > 0) done else neg(EFAULT);
            const n = @min(p.len, len - done);
            m.host.write(@intCast(fd), p[0..@intCast(n)]);
            done += n;
        }
        return len;
    }

    fn sysBrk(m: *Machine, want: u64) u64 {
        if (want < m.brk_start) return m.brk;
        const old_end = pageUp(m.brk);
        const new_end = pageUp(want);
        if (new_end > old_end) m.reserve(old_end, new_end, 3) else if (new_end < old_end) m.unmap(new_end, old_end);
        m.brk = want;
        return m.brk;
    }

    fn sysMmap(m: *Machine, addr: u64, len0: u64, prot: u64, flags: u64, fd: u64) u64 {
        const MAP_FIXED = 0x10;
        const MAP_ANONYMOUS = 0x20;
        if (flags & MAP_ANONYMOUS == 0 or @as(i32, @bitCast(@as(u32, @truncate(fd)))) != -1) return neg(ENOSYS);
        if (len0 == 0) return neg(EINVAL);
        const len = pageUp(len0);
        var va: u64 = undefined;
        if (flags & MAP_FIXED != 0) {
            if (addr & (page - 1) != 0) return neg(EINVAL);
            va = addr;
            m.unmap(va, va + len);
        } else {
            m.mmap_top -= len;
            va = m.mmap_top;
        }
        m.reserve(va, va + len, prot);
        return va;
    }
};
