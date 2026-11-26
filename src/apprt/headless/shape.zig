//! The pointer shape Ghostty last asked for, with a history of changes that
//! GET /shape waits on.
const std = @import("std");
const global = @import("../../global.zig");
const terminal = @import("../../terminal/main.zig");
const clock = @import("clock.zig");

const history_len = 256;

const State = struct {
    seq: u64 = 0,
    shape: terminal.MouseShape = .text,
    visible: bool = true,
    time_unix_ns: u64 = 0,
};

var mutex: std.Io.Mutex = .init;
var changed: std.Io.Condition = .init;
/// Ghostty's terminal starts at text and reports only changes; the macOS
/// app's view starts with the I-beam too.
var now: State = .{};
var history: [history_len]State = undefined;

/// The shape's CSS cursor name: Ghostty's tag with dashes.
pub fn name(shape: terminal.MouseShape) []const u8 {
    return switch (shape) {
        inline else => |s| comptime dashed: {
            const tag = @tagName(s);
            var out: [tag.len]u8 = undefined;
            for (tag, 0..) |c, i| out[i] = if (c == '_') '-' else c;
            const final = out;
            break :dashed &final;
        },
    };
}

/// Ghostty asks for a shape on every key and mouse move; keep real changes.
pub fn record(shape: ?terminal.MouseShape, visible: ?bool) void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if ((shape == null or shape.? == now.shape) and (visible == null or visible.? == now.visible)) return;
    if (shape) |s| now.shape = s;
    if (visible) |v| now.visible = v;
    now.seq += 1;
    now.time_unix_ns = clock.realNs();
    history[now.seq % history_len] = now;
    changed.broadcast(io);
}

fn entry(w: *std.Io.Writer, s: State, with_time: bool) !void {
    try w.print("{{\"seq\":{d},\"shape\":\"{s}\",\"visible\":{}", .{ s.seq, name(s.shape), s.visible });
    if (with_time) try w.print(",\"time_unix_ns\":{d}", .{s.time_unix_ns});
    try w.writeByte('}');
}

/// The shape now, for /status.
pub fn briefJson(w: *std.Io.Writer) !void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    try entry(w, now, false);
}

/// The shape with the changes after `after`, waiting up to timeout_ms for one.
pub fn json(w: *std.Io.Writer, after: ?u64, timeout_ms: u64) !void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (after) |a| {
        const deadline = clock.deadline(timeout_ms);
        while (now.seq <= a) changed.waitTimeout(io, &mutex, deadline) catch break;
    }
    try w.print("{{\"seq\":{d},\"shape\":\"{s}\",\"visible\":{},\"changes\":[", .{ now.seq, name(now.shape), now.visible });
    var first = (after orelse 0) + 1;
    if (now.seq >= history_len and first <= now.seq - history_len) first = now.seq - history_len + 1;
    var s = first;
    while (s <= now.seq) : (s += 1) {
        if (s > first) try w.writeByte(',');
        try entry(w, history[s % history_len], true);
    }
    try w.writeAll("]}");
}
