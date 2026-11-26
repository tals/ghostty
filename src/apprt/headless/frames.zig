//! Frames: each presented frame goes into a slot (a copy of an IOSurface on
//! macOS, Ghostty's own readback buffer on Linux); a worker converts it to
//! top-first RGBA and publishes it only if its pixels changed (Ghostty
//! redraws an idle screen on its 600 ms cursor timer).
const std = @import("std");
const global = @import("../../global.zig");
const clock = @import("clock.zig");
const image = @import("image.zig");

const n_slots = 4; // copies waiting for the worker
const sub_queue = 8; // frames queued per /frames reader before it skips
const pool_len = 6; // released frame buffers kept for reuse

/// A frame Ghostty presented, as it is handed over.
pub const Present = struct {
    pixels: [*]const u8,
    stride: usize,
    width: u32,
    height: u32,
    /// Else RGBA.
    bgra: bool,
    /// Rows bottom first.
    bottom_up: bool,
    /// Time Ghostty spent reading it back, 0 if unknown.
    gpu_readback_ns: u64,
    colorspace: []const u8,
    /// With release, the pixels stay valid until the worker calls it, so
    /// nothing is copied while presenting. Without, they are copied during
    /// onPresent.
    release: ?Release = null,
};

pub const Release = struct {
    func: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
};

/// A published frame: premultiplied RGBA, immutable, reference counted.
pub const Frame = struct {
    refs: std.atomic.Value(u32),
    rgba: []u8,
    width: u32,
    height: u32,
    seq: u64,
    time_unix_ns: u64,
    time_mono_ns: u64,

    pub fn bytes(self: *const Frame) []const u8 {
        return self.rgba[0 .. @as(usize, self.width) * self.height * 4];
    }

    fn ref(self: *Frame) *Frame {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Frame) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const io = global.io();
        pool_mutex.lockUncancelable(io);
        if (pool_n < pool_len) {
            pool[pool_n] = self;
            pool_n += 1;
            pool_mutex.unlock(io);
            return;
        }
        pool_mutex.unlock(io);
        global.alloc().free(self.rgba);
        global.alloc().destroy(self);
    }
};

const Slot = struct {
    /// Owned copy, for frames without release.
    copy: []u8 = &.{},
    pixels: [*]const u8 = undefined,
    stride: usize = 0,
    bgra: bool = false,
    bottom_up: bool = false,
    release: ?Release = null,
    width: u32 = 0,
    height: u32 = 0,
    seq: u64 = 0,
    time_unix_ns: u64 = 0,
    time_mono_ns: u64 = 0,
    gpu_readback_ns: u64 = 0,

    fn releasePixels(self: *Slot) void {
        if (self.release) |r| r.func(r.ctx);
        self.release = null;
    }
};

const Timing = struct {
    count: u64 = 0,
    sum_ns: u64 = 0,
    max_ns: u64 = 0,
    last_ns: u64 = 0,

    fn add(self: *Timing, ns: u64) void {
        self.count += 1;
        self.sum_ns += ns;
        self.last_ns = ns;
        self.max_ns = @max(self.max_ns, ns);
    }

    fn json(self: *const Timing, w: *std.Io.Writer, name: []const u8) !void {
        try w.print("\"{s}\":{{\"frames\":{d},\"last_us\":{d},\"avg_us\":{d},\"max_us\":{d}}}", .{
            name,
            self.count,
            self.last_ns / 1000,
            if (self.count > 0) self.sum_ns / self.count / 1000 else 0,
            self.max_ns / 1000,
        });
    }
};

pub const Subscriber = struct {
    queue: [sub_queue]*Frame = undefined,
    n: usize = 0,
    skipped: u32 = 0,
    next: ?*Subscriber = null,
};

var mutex: std.Io.Mutex = .init;
var queued: std.Io.Condition = .init;
var published: std.Io.Condition = .init;
var slots: [n_slots]Slot = @splat(.{});
var free_slots: [n_slots]usize = undefined;
var n_free: usize = 0;
var queue: [n_slots]usize = undefined;
var n_queued: usize = 0;
var drawn_seq: u64 = 0;
var latest: ?*Frame = null;
var last_publish_mono: u64 = 0;
var subs: ?*Subscriber = null;
var colorspace_buf: [64]u8 = undefined;
var colorspace: []const u8 = "";
var counts: struct { drawn: u64 = 0, published: u64 = 0, identical: u64 = 0, overrun: u64 = 0 } = .{};
var t_tap: Timing = .{};
var t_convert: Timing = .{};
var t_readback: Timing = .{};
var t_gpu_readback: Timing = .{};
/// From --color convert: frames are Display P3 and converted to sRGB.
var convert_p3 = false;

var pool_mutex: std.Io.Mutex = .init;
var pool: [pool_len]*Frame = undefined;
var pool_n: usize = 0;

fn frameAlloc(width: u32, height: u32) !*Frame {
    const need = @as(usize, width) * height * 4;
    const io = global.io();
    const alloc = global.alloc();
    pool_mutex.lockUncancelable(io);
    const pooled: ?*Frame = if (pool_n > 0) pooled: {
        pool_n -= 1;
        break :pooled pool[pool_n];
    } else null;
    pool_mutex.unlock(io);
    const f = pooled orelse f: {
        const f = try alloc.create(Frame);
        f.rgba = &.{};
        break :f f;
    };
    if (f.rgba.len < need) {
        alloc.free(f.rgba);
        f.rgba = alloc.alloc(u8, need) catch |err| {
            alloc.destroy(f);
            return err;
        };
    }
    f.refs = .init(1);
    f.width = width;
    f.height = height;
    return f;
}

/// Hands a presented frame to the worker. Any one thread at a time.
pub fn onPresent(f: Present) void {
    const io = global.io();
    const begin = clock.monoNs();
    mutex.lockUncancelable(io);
    const s = if (n_free > 0) s: {
        n_free -= 1;
        break :s free_slots[n_free];
    } else s: {
        // The worker is behind: replace the newest waiting frame.
        n_queued -= 1;
        const s = queue[n_queued];
        slots[s].releasePixels();
        counts.overrun += 1;
        break :s s;
    };
    drawn_seq += 1;
    const seq = drawn_seq;
    counts.drawn += 1;
    const n = @min(f.colorspace.len, colorspace_buf.len);
    @memcpy(colorspace_buf[0..n], f.colorspace[0..n]);
    colorspace = colorspace_buf[0..n];
    mutex.unlock(io);

    const sl = &slots[s];
    if (f.release != null) {
        sl.pixels = f.pixels;
        sl.stride = f.stride;
    } else {
        const row = @as(usize, f.width) * 4;
        const need = row * f.height;
        if (sl.copy.len < need) {
            global.alloc().free(sl.copy);
            sl.copy = global.alloc().alloc(u8, need) catch {
                sl.copy = &.{};
                mutex.lockUncancelable(io);
                free_slots[n_free] = s;
                n_free += 1;
                mutex.unlock(io);
                return;
            };
        }
        for (0..f.height) |y| @memcpy(sl.copy[y * row ..][0..row], f.pixels[y * f.stride ..][0..row]);
        sl.pixels = sl.copy.ptr;
        sl.stride = row;
    }
    sl.bgra = f.bgra;
    sl.bottom_up = f.bottom_up;
    sl.release = f.release;
    sl.width = f.width;
    sl.height = f.height;
    sl.seq = seq;
    sl.gpu_readback_ns = f.gpu_readback_ns;
    sl.time_unix_ns = clock.realNs();
    sl.time_mono_ns = clock.monoNs();

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    queue[n_queued] = s;
    n_queued += 1;
    t_tap.add(sl.time_mono_ns - begin);
    if (f.gpu_readback_ns > 0) t_gpu_readback.add(f.gpu_readback_ns);
    queued.signal(io);
}

/// Top-first RGBA from a slot, and whether it matches prev. Each row is
/// compared as soon as it is written, while it is still in cache.
fn slotToRgba(sl: *const Slot, out: []u8, prev: ?*const Frame) bool {
    const row = @as(usize, sl.width) * 4;
    var same = if (prev) |p| p.width == sl.width and p.height == sl.height else false;
    var bgra: image.BgraToRgba = .{ .convert = convert_p3 };
    for (0..sl.height) |y| {
        const from = if (sl.bottom_up) sl.height - 1 - y else y;
        const src = sl.pixels + from * sl.stride;
        const dst = out[y * row ..][0..row];
        if (sl.bgra) bgra.row(src, sl.width, dst) else @memcpy(dst, src[0..row]);
        if (same) same = std.mem.eql(u8, dst, prev.?.rgba[y * row ..][0..row]);
    }
    return same;
}

fn worker() void {
    const io = global.io();
    while (true) {
        mutex.lockUncancelable(io);
        while (n_queued == 0) queued.waitUncancelable(io, &mutex);
        const s = queue[0];
        n_queued -= 1;
        std.mem.copyForwards(usize, queue[0..n_queued], queue[1 .. n_queued + 1]);
        const prev = latest; // only this thread replaces latest
        const tap_ns = t_tap.last_ns;
        mutex.unlock(io);

        const sl = &slots[s];
        const t0 = clock.monoNs();
        const f: ?*Frame = frameAlloc(sl.width, sl.height) catch null;
        const same = if (f) |frame| same: {
            frame.seq = sl.seq;
            frame.time_unix_ns = sl.time_unix_ns;
            frame.time_mono_ns = sl.time_mono_ns;
            break :same slotToRgba(sl, frame.rgba, prev);
        } else true;
        const t1 = clock.monoNs();

        mutex.lockUncancelable(io);
        sl.releasePixels();
        free_slots[n_free] = s;
        n_free += 1;
        t_convert.add(t1 - t0);
        t_readback.add(sl.gpu_readback_ns + tap_ns + (t1 - t0));
        if (same) {
            counts.identical += 1;
            mutex.unlock(io);
            if (f) |frame| frame.release();
            continue;
        }
        const frame = f.?;
        counts.published += 1;
        latest = frame;
        last_publish_mono = frame.time_mono_ns;
        var it = subs;
        while (it) |sub| : (it = sub.next) {
            if (sub.n == sub_queue) {
                sub.queue[0].release();
                std.mem.copyForwards(*Frame, sub.queue[0 .. sub_queue - 1], sub.queue[1..sub_queue]);
                sub.n -= 1;
                sub.skipped += 1;
            }
            sub.queue[sub.n] = frame.ref();
            sub.n += 1;
        }
        published.broadcast(io);
        mutex.unlock(io);
        if (prev) |p| p.release();
    }
}

pub fn start(convert: bool) !void {
    convert_p3 = convert;
    for (0..n_slots) |i| free_slots[i] = i;
    n_free = n_slots;
    const thread = try std.Thread.spawn(.{}, worker, .{});
    thread.detach();
}

/// The seq of the last frame Ghostty presented.
pub fn drawnSeq() u64 {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return drawn_seq;
}

/// The latest frame, referenced, or null before the first.
pub fn latestFrame() ?*Frame {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return if (latest) |f| f.ref() else null;
}

/// Waits until no frame has been published for quiet_ms; false at timeout_ms.
pub fn settle(quiet_ms: u64, timeout_ms: u64, seq: *u64) bool {
    const io = global.io();
    const begin = clock.monoNs();
    const quiet = quiet_ms * std.time.ns_per_ms;
    const limit = begin + timeout_ms * std.time.ns_per_ms;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    while (true) {
        const now = clock.monoNs();
        // Quiet since the later of the last change and the request.
        const since = @max(last_publish_mono, begin);
        if (now - since >= quiet or now >= limit) break;
        const until = @min(since + quiet, limit);
        published.waitTimeout(io, &mutex, clock.deadline((until - now + 999_999) / std.time.ns_per_ms)) catch {};
    }
    const since = @max(last_publish_mono, begin);
    seq.* = if (latest) |f| f.seq else 0;
    return clock.monoNs() - since >= quiet;
}

/// The first frame published after `after`, referenced; null at the timeout.
pub fn wait(after: u64, timeout_ms: u64) ?*Frame {
    const io = global.io();
    const deadline = clock.deadline(timeout_ms);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    while (latest == null or latest.?.seq <= after) published.waitTimeout(io, &mutex, deadline) catch break;
    const f = latest orelse return null;
    return if (f.seq > after) f.ref() else null;
}

/// A reader of every published frame, starting with the latest unless it
/// isn't after `after`.
pub fn subscribe(after: ?u64) !*Subscriber {
    const s = try global.alloc().create(Subscriber);
    s.* = .{};
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (latest) |f| if (after == null or f.seq > after.?) {
        s.queue[0] = f.ref();
        s.n = 1;
    };
    s.next = subs;
    subs = s;
    return s;
}

/// The reader's next frame, referenced, or null at the timeout. Sets
/// skipped to the frames it missed since the last one.
pub fn next(s: *Subscriber, skipped: *u32, timeout_ms: u64) ?*Frame {
    const io = global.io();
    const deadline = clock.deadline(timeout_ms);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    while (s.n == 0) published.waitTimeout(io, &mutex, deadline) catch break;
    if (s.n == 0) return null;
    const f = s.queue[0];
    s.n -= 1;
    std.mem.copyForwards(*Frame, s.queue[0..s.n], s.queue[1 .. s.n + 1]);
    skipped.* = s.skipped;
    s.skipped = 0;
    return f;
}

pub fn unsubscribe(s: *Subscriber) void {
    const io = global.io();
    mutex.lockUncancelable(io);
    var link = &subs;
    while (link.*) |sub| : (link = &sub.next) {
        if (sub == s) {
            link.* = s.next;
            break;
        }
    }
    mutex.unlock(io);
    for (s.queue[0..s.n]) |f| f.release();
    global.alloc().destroy(s);
}

/// The frame and timing parts of /status.
pub fn statsJson(w: *std.Io.Writer) !void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (latest) |f| {
        try w.print("\"frame\":{{\"seq\":{d},\"width\":{d},\"height\":{d},\"time_unix_ns\":{d}}},", .{
            f.seq, f.width, f.height, f.time_unix_ns,
        });
    } else try w.writeAll("\"frame\":null,");
    try w.print("\"readback\":{{\"frames\":{d},\"last_us\":{d},\"avg_us\":{d},\"max_us\":{d},\"unchanged\":{d}}}", .{
        t_readback.count,
        t_readback.last_ns / 1000,
        if (t_readback.count > 0) t_readback.sum_ns / t_readback.count / 1000 else 0,
        t_readback.max_ns / 1000,
        counts.identical,
    });
    try w.print(
        ",\"frames\":{{\"drawn\":{d},\"published\":{d},\"identical\":{d},\"overrun\":{d}," ++
            "\"surface_colorspace\":\"{s}\",\"pixels\":\"{s}\",",
        .{
            counts.drawn,
            counts.published,
            counts.identical,
            counts.overrun,
            colorspace,
            if (convert_p3) "converted from Display P3 to sRGB" else "unconverted (sRGB values)",
        },
    );
    try t_tap.json(w, "tap");
    try w.writeByte(',');
    try t_convert.json(w, "convert");
    try w.writeByte(',');
    try t_gpu_readback.json(w, "gpu_readback");
    try w.writeByte('}');
}
