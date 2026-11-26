//! The main thread's loop: queued calls run in order, ticks from Ghostty's
//! wakeups and input ops from HTTP threads, which wait for theirs.
const std = @import("std");
const builtin = @import("builtin");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");

/// Runs this thread at the priority of a window's main thread (macOS gives
/// AppKit's user-interactive), so input never waits behind other work.
pub fn interactive() void {
    if (comptime !builtin.target.os.tag.isDarwin()) return;
    internal_os.macos.setQosClass(.user_interactive) catch {};
}

const Call = struct {
    func: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
    sync: bool,
    done: bool = false,
    next: ?*Call = null,
};

var mutex: std.Io.Mutex = .init;
/// The main thread waits here for calls.
var wake: std.Io.Condition = .init;
/// Sync callers wait here for theirs.
var ran: std.Io.Condition = .init;
var head: ?*Call = null;
var tail: ?*Call = null;
var stopping = false;

fn enqueue(c: *Call) void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (tail) |t| t.next = c else head = c;
    tail = c;
    wake.signal(io);
}

/// Runs func on the main thread soon. Any thread.
pub fn post(func: *const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    const c = global.alloc().create(Call) catch {
        std.log.err("ghostty-host: out of memory queueing a call", .{});
        return;
    };
    c.* = .{ .func = func, .ctx = ctx, .sync = false };
    enqueue(c);
}

/// Runs func on the main thread and waits for it. Not on the main thread.
pub fn call(func: *const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    var c: Call = .{ .func = func, .ctx = ctx, .sync = true };
    enqueue(&c);
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    while (!c.done) ran.waitUncancelable(io, &mutex);
}

/// Runs queued calls until stop.
pub fn run() void {
    interactive();
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    while (!stopping) {
        const c = head orelse {
            wake.waitUncancelable(io, &mutex);
            continue;
        };
        head = c.next;
        if (head == null) tail = null;
        mutex.unlock(io);
        c.func(c.ctx);
        mutex.lockUncancelable(io);
        if (c.sync) {
            c.done = true;
            ran.broadcast(io);
        } else {
            global.alloc().destroy(c);
        }
    }
}

/// Ends run. Calls still queued are dropped; sync callers stay blocked
/// until exit. Any thread.
pub fn stop() void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    stopping = true;
    wake.signal(io);
}
