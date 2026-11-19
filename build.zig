// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
const std = @import("std");

/// Zig guests (rv64imac, soft-float, no libc; see guest/rt.zig) run by the kwemu harness tests and benchmarks.
const zig_guests = [_][]const u8{ "hello", "bench" };
/// Hard-float (rv64gc, lp64d) static musl C guests used by the kwemu library tests.
const gc_guests = [_][]const u8{ "fptest", "isatest", "atomics", "kbench", "aestest", "bktest", "zbtest", "rvatest", "zfatest", "zfhtest", "jalrtest" };
/// Optional extensions (core.Ext) a gc guest is built with on top of rv64gc.
fn guestExts(name: []const u8) std.Target.Cpu.Feature.Set {
    if (std.mem.eql(u8, name, "aestest")) return std.Target.riscv.featureSet(&.{ .zkne, .zknd });
    if (std.mem.eql(u8, name, "bktest")) return std.Target.riscv.featureSet(&.{ .zbc, .zbkb, .zbkc, .zbkx });
    if (std.mem.eql(u8, name, "zbtest")) return std.Target.riscv.featureSet(&.{ .zba, .zbb, .zbs, .zicond });
    if (std.mem.eql(u8, name, "zfatest")) return std.Target.riscv.featureSet(&.{.zfa});
    if (std.mem.eql(u8, name, "zfhtest")) return std.Target.riscv.featureSet(&.{.zfhmin});
    if (std.mem.eql(u8, name, "rvatest")) return std.Target.riscv.featureSet(&.{ .zba, .zbb, .zcb, .zimop, .zcmop, .zicbom, .zicboz, .zawrs });
    return .empty;
}

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode for the native library and harness (default: fast)") orelse .fast;
    const native = b.standardTargetOptions(.{});

    // ---- guest programs (riscv64, rv64imac, soft-float) -------------------------
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .linux,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 },
        .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c }),
    });
    const rt = b.createModule(.{ .root_source_file = b.path("guest/rt.zig"), .target = guest_target });
    for (zig_guests) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("guest/{s}.zig", .{name})),
                .target = guest_target,
                .optimize = .small,
                .imports = &.{.{ .name = "rt", .module = rt }},
            }),
        });
        installGuest(b, exe, name);
    }

    // ---- kwemu: the CPU core as a library for the real kernel -----------------
    // wasm64 relocatable object + static archive with the C ABI of
    // include/kw_emu.h; conservative wasm features (mvp + memory64): no
    // threads/atomics/TLS/bulk-memory/sign-ext/nontrapping-fptoint, unless
    // -Dkwemu-atomics (below).
    const lib_optimize = b.option(std.lang.Optimize, "lib-optimize", "Optimization mode for libkwemu (default: fast)") orelse .fast;
    // Tail-call threaded dispatch (one function per op, return_call_indirect
    // chains). Adds the wasm `tail_call` feature to the object, so the
    // kernel's toolchain/runtime must support it. Off by default.
    const tail_call = b.option(bool, "kwemu-tail-call", "kwemu: tail-call threaded dispatch (wasm tail_call feature; default: false)") orelse false;
    const stats = b.option(bool, "kwemu-stats", "kwemu: block-cache counters (kw_debug_stats export, printed by the harness; default: false)") orelse false;
    // JIT tier (src/emu/jit.zig): hot blocks are compiled to wasm through the
    // optional host imports unkernel.kw_host_jit_{caps,compile,free}. wasm64
    // only; off by default (the object then has no `unkernel` imports). The
    // tests build a JIT-enabled harness and unit-test module regardless.
    const jit = b.option(bool, "kwemu-jit", "kwemu: wasm JIT tier, needs the unkernel.kw_host_jit_* host imports (default: false)") orelse false;
    const jit_threshold = b.option(u32, "kwemu-jit-threshold", "kwemu: retired instructions in a block before it is compiled (default: 131072)") orelse 1 << 17;
    const jit_grow = b.option(u32, "kwemu-jit-grow", "kwemu: exits from a region towards a compiled block before it joins the region (default: 8192 per KiB of the region's module; 0 = never)") orelse 8192;
    // Operand sets per op of the randomized F/D differential unit test
    // (interpreter vs JIT, wasm64 unit tests only); 0 = its small default.
    const fp_fuzz = b.option(u32, "kwemu-fp-fuzz", "kwemu: random operand sets per op in the F/D JIT differential test (default: 0 = 4096)") orelse 0;
    // wasm atomics + bulk memory in the wasm64 objects, so that a kernel
    // linked with --shared-memory (wasm-ld refuses objects without both)
    // can include kwemu. With them (core.smp) guest AMOs are atomic
    // read-modify-writes, SC a compare-and-swap against the value LR read,
    // and FENCE a full barrier, for an SMP kernel's harts on one memory.
    const atomics = b.option(bool, "kwemu-atomics", "kwemu: build the wasm64 objects with the atomics and bulk-memory features, for a shared-memory kernel (default: false)") orelse false;
    const kw_opts_mod = kwOptions(b, tail_call, stats, jit, jit_threshold, jit_grow, fp_fuzz);
    const kw_opts_jit_mod = if (jit) kw_opts_mod else kwOptions(b, tail_call, stats, true, jit_threshold, jit_grow, fp_fuzz);
    const wasm64 = b.resolveTargetQuery(.{
        .cpu_arch = .wasm64,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = blk: {
            var f: std.Target.Cpu.Feature.Set = .empty;
            if (tail_call) f.addFeatureSet(std.Target.wasm.featureSet(&.{.tail_call}));
            if (atomics) f.addFeatureSet(std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }));
            break :blk f;
        },
    });
    const kw_h_wasm = kwHeader(b, wasm64, lib_optimize);
    const kw_h_native = kwHeader(b, native, optimize);
    const lib_wasm_mod = kwemuModule(b, wasm64, lib_optimize, kw_h_wasm, kw_opts_mod);
    const lib_wasm = b.addLibrary(.{ .name = "kwemu", .linkage = .static, .root_module = lib_wasm_mod });
    b.installArtifact(lib_wasm); // zig-out/lib/libkwemu.a
    const obj_wasm = b.addObject(.{ .name = "kwemu", .root_module = lib_wasm_mod });
    b.getInstallStep().dependOn(&b.addInstallLibFile(obj_wasm.getEmittedBin(), "kwemu.o").step);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/kw_emu.h"), "kw_emu.h").step);
    const lib_native = b.addLibrary(.{ .name = "kwemu", .linkage = .static, .root_module = kwemuModule(b, native, optimize, kw_h_native, kw_opts_mod) });
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib_native, .{ .dest_dir = .{ .override = .{ .custom = "lib/native" } } }).step);

    // Test harness ("kernel" driving the C ABI only), native and wasm64.
    const harness_native = b.addExecutable(.{
        .name = "kwemu-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emu/harness_native.zig"),
            .target = native,
            .optimize = optimize,
            .imports = &.{ .{ .name = "kw_h", .module = kw_h_native }, .{ .name = "kwemu_options", .module = kw_opts_mod } },
        }),
    });
    harness_native.root_module.linkLibrary(lib_native);
    b.installArtifact(harness_native);
    const harness_wasm = b.addExecutable(.{
        .name = "kwemu-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emu/harness_wasm.zig"),
            .target = wasm64,
            .optimize = lib_optimize,
            .strip = lib_optimize != .debug,
            .imports = &.{ .{ .name = "kw_h", .module = kw_h_wasm }, .{ .name = "kwemu_options", .module = kw_opts_mod } },
        }),
    });
    harness_wasm.entry = .disabled;
    harness_wasm.rdynamic = true;
    harness_wasm.root_module.linkLibrary(lib_wasm);
    b.installArtifact(harness_wasm); // zig-out/bin/kwemu-harness.wasm

    // The same harness with the JIT tier, for the tests and benchmarks: it
    // imports unkernel.kw_host_jit_* and exports its function table.
    const lib_wasm_jit = if (jit) lib_wasm else b.addLibrary(.{
        .name = "kwemu-jit",
        .linkage = .static,
        .root_module = kwemuModule(b, wasm64, lib_optimize, kw_h_wasm, kw_opts_jit_mod),
    });
    const harness_jit = b.addExecutable(.{
        .name = "kwemu-harness-jit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emu/harness_wasm.zig"),
            .target = wasm64,
            .optimize = lib_optimize,
            .strip = lib_optimize != .debug,
            .imports = &.{ .{ .name = "kw_h", .module = kw_h_wasm }, .{ .name = "kwemu_options", .module = kw_opts_jit_mod } },
        }),
    });
    harness_jit.entry = .disabled;
    harness_jit.rdynamic = true;
    harness_jit.export_table = true;
    harness_jit.root_module.linkLibrary(lib_wasm_jit);
    b.installArtifact(harness_jit); // zig-out/bin/kwemu-harness-jit.wasm

    // Hard-float guests: riscv64-linux-musl, default CPU = rv64gc (lp64d).
    for (gc_guests) |name| {
        const gc_target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl, .cpu_features_add = guestExts(name) });
        const mod = b.createModule(.{ .target = gc_target, .optimize = .fast, .link_libc = true });
        mod.addCSourceFile(.{ .file = b.path(b.fmt("guest/{s}.c", .{name})), .flags = &.{ "-std=c11", "-Wall", "-frounding-math" } });
        mod.linkSystemLibrary("m", .{});
        const exe = b.addExecutable(.{ .name = name, .root_module = mod, .linkage = .static });
        installGuest(b, exe, name);
    }

    // ---- tests -------------------------------------------------------------------
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = native,
            .optimize = .debug,
            .imports = &.{ .{ .name = "kw_h", .module = kw_h_native }, .{ .name = "kwemu_options", .module = kw_opts_mod } },
        }),
    });
    // The kwemu unit tests again as wasm64 with the JIT tier, run under Node
    // by test/kwemu-unit-wasm.mjs (a JS host for the JIT imports).
    const unit_wasm = b.addTest(.{
        .name = "kwemu-unit-jit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests_wasm.zig"),
            .target = wasm64,
            .optimize = .safe,
            .single_threaded = true,
            .imports = &.{ .{ .name = "kw_h", .module = kw_h_wasm }, .{ .name = "kwemu_options", .module = kw_opts_jit_mod } },
        }),
        .test_runner = .{ .path = b.path("src/test_runner_wasm.zig"), .mode = .simple },
        .filters = &.{"kwemu"}, // not the softfloat tests (cpu/fpu.zig) pulled in through imports
    });
    unit_wasm.entry = .disabled;
    unit_wasm.rdynamic = true;
    unit_wasm.export_table = true;
    const unit_wasm_run = b.addSystemCommand(&.{"node"});
    unit_wasm_run.addFileArg(b.path("test/kwemu-unit-wasm.mjs"));
    unit_wasm_run.addFileArg(unit_wasm.getEmittedBin());
    unit_wasm_run.has_side_effects = true;

    const lib_e2e = b.addSystemCommand(&.{"node"});
    lib_e2e.addFileArg(b.path("test/kwemu-test.mjs"));
    lib_e2e.addDirectoryArg(.{ .relative = .{ .base = .install_prefix } });
    lib_e2e.step.dependOn(b.getInstallStep());
    lib_e2e.has_side_effects = true;
    const test_step = b.step("test", "Run unit tests and kwemu library tests (native + wasm64, with and without the JIT tier)");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&lib_e2e.step);
    test_step.dependOn(&unit_wasm_run.step);

    // `zig build fuzz -- N [SEED]`: the wasm64 unit tests with N seeds of the
    // randomized interpreter-vs-JIT test (src/emu/kwemu_test.zig, "kwemu jit fuzz").
    const fuzz_run = b.addSystemCommand(&.{"node"});
    fuzz_run.addFileArg(b.path("test/kwemu-unit-wasm.mjs"));
    fuzz_run.addFileArg(unit_wasm.getEmittedBin());
    fuzz_run.addPassthruArgs();
    fuzz_run.has_side_effects = true;
    b.step("fuzz", "Run the wasm64 unit tests with a long randomized interpreter-vs-JIT run (zig build fuzz -- N [SEED])").dependOn(&fuzz_run.step);
}

fn kwOptions(b: *std.Build, tail_call: bool, stats: bool, jit: bool, jit_threshold: u32, jit_grow: u32, fp_fuzz: u32) *std.Build.Module {
    const o = b.addOptions();
    o.addOption(bool, "tail_call", tail_call);
    o.addOption(bool, "stats", stats);
    o.addOption(bool, "jit", jit);
    o.addOption(u32, "jit_threshold", jit_threshold);
    o.addOption(u32, "jit_grow", jit_grow);
    o.addOption(u32, "fp_fuzz", fp_fuzz);
    return o.createModule();
}

fn kwHeader(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("include/kw_emu.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    return tc.createModule();
}

fn kwemuModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, kw_h: *std.Build.Module, opts: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/libkwemu.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .stack_protector = false,
        .strip = optimize != .debug,
        .imports = &.{ .{ .name = "kw_h", .module = kw_h }, .{ .name = "kwemu_options", .module = opts } },
    });
}

fn installGuest(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8) void {
    const inst = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "guest" } },
        .dest_sub_path = b.fmt("{s}.elf", .{name}),
    });
    b.getInstallStep().dependOn(&inst.step);
}
