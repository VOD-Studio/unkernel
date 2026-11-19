// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
//! Test runner for the wasm64 unit-test module (freestanding, no WASI).
//! Imports env.host_write(fd, ptr, len); exports run_tests() -> number of
//! failures. Each test prints "<name>\t<ok|skip|FAIL ...>".

const std = @import("std");
const builtin = @import("builtin");

extern "env" fn host_write(fd: i32, ptr: [*]const u8, len: usize) void;

fn write(fd: i32, s: []const u8) void {
    host_write(fd, s.ptr, s.len);
}

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        write(2, "panic: ");
        write(2, msg);
        write(2, "\n");
        @trap();
    }
}.f);

// No threads and no OS: std.debug.print and failed expectations write to
// host_write(2, ...) through an Io that is `failing` except for stderr.
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const std_options_debug_io: std.Io = .{ .userdata = null, .vtable = &debug_vtable };

const debug_vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.lockStderr = lockStderr;
    v.unlockStderr = unlockStderr;
    v.swapCancelProtection = swapCancelProtection;
    break :blk v;
};

var stderr_buf: [256]u8 = undefined;
var stderr_writer: std.Io.File.Writer = undefined;

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    write(2, w.buffered());
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        write(2, d);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| write(2, last);
    return n + last.len * splat;
}

fn lockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    stderr_writer.interface = .{ .vtable = &.{ .drain = drain }, .buffer = &stderr_buf };
    return .{ .file_writer = &stderr_writer, .terminal_mode = .no_color };
}

fn swapCancelProtection(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
    return new;
}

fn unlockStderr(_: ?*anyopaque) void {
    stderr_writer.interface.flush() catch {};
}

pub var test_allocator_instance: std.heap.DebugAllocator(.{}) = .init;
pub const test_allocator = test_allocator_instance.allocator();

export fn run_tests() u32 {
    var failed: u32 = 0;
    for (builtin.test_functions) |t| {
        // name first: if a test traps, the host shows which one
        write(1, t.name);
        write(1, "\t");
        test_allocator_instance = .init;
        if (t.func()) |_| {
            write(1, "ok");
        } else |e| {
            if (e == error.SkipZigTest) write(1, "skip") else {
                failed += 1;
                write(1, "FAIL ");
                write(1, @errorName(e));
            }
        }
        if (test_allocator_instance.deinit() == .leak) {
            failed += 1;
            write(1, " FAIL (leak)");
        }
        write(1, "\n");
    }
    return failed;
}

pub fn main() void {}
