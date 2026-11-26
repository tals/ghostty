//! Wall and monotonic time in nanoseconds, and timeouts on the awake clock.
const std = @import("std");
const global = @import("../../global.zig");

/// Nanoseconds since the Unix epoch.
pub fn realNs() u64 {
    return @intCast(std.Io.Timestamp.now(global.io(), .real).nanoseconds);
}

/// Nanoseconds on the clock that stops while the machine sleeps.
pub fn monoNs() u64 {
    return @intCast(std.Io.Timestamp.now(global.io(), .awake).nanoseconds);
}

/// A deadline ms from now, for Condition.waitTimeout.
pub fn deadline(ms: u64) std.Io.Timeout {
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))),
        .clock = .awake,
    } };
    return timeout.toDeadline(global.io());
}

/// Sleeps for ns on the awake clock.
pub fn sleepNs(ns: u64) void {
    std.Io.sleep(global.io(), .fromNanoseconds(ns), .awake) catch {};
}
