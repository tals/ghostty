//! HTTP/1.1 over a Unix socket, one thread per connection.
const std = @import("std");
const c = std.c;
const global = @import("../../global.zig");
const clock = @import("clock.zig");
const frames = @import("frames.zig");
const image = @import("image.zig");
const input = @import("input.zig");
const loop = @import("loop.zig");
const main = @import("main.zig");
const shape = @import("shape.zig");

fn sendAll(fd: c.fd_t, bytes: []const u8) bool {
    var p = bytes;
    while (p.len > 0) {
        const n = c.write(fd, p.ptr, p.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return false;
        p = p[@intCast(n)..];
    }
    return true;
}

fn sendIov(fd: c.fd_t, iov_: []std.posix.iovec_const) bool {
    var iov = iov_;
    while (iov.len > 0) {
        const n = c.writev(fd, iov.ptr, @intCast(iov.len));
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return false;
        var w: usize = @intCast(n);
        while (iov.len > 0 and w >= iov[0].len) {
            w -= iov[0].len;
            iov = iov[1..];
        }
        if (iov.len > 0) {
            iov[0].base += w;
            iov[0].len -= w;
        }
    }
    return true;
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Bad Request",
    };
}

fn respond(fd: c.fd_t, status: u16, content_type: []const u8, body: []const u8, extra: []const u8) void {
    var head: [1024]u8 = undefined;
    const h = std.fmt.bufPrint(
        &head,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n",
        .{ status, reason(status), content_type, body.len, extra },
    ) catch return;
    var iov = [_]std.posix.iovec_const{
        .{ .base = h.ptr, .len = h.len },
        .{ .base = body.ptr, .len = body.len },
    };
    _ = sendIov(fd, &iov);
}

fn respondJson(fd: c.fd_t, status: u16, json: []const u8) void {
    respond(fd, status, "application/json", json, "");
}

fn respondError(fd: c.fd_t, status: u16, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":{f}}}", .{std.json.fmt(msg, .{})}) catch return;
    respondJson(fd, status, json);
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len > key.len and std.mem.startsWith(u8, pair, key) and pair[key.len] == '=') return pair[key.len + 1 ..];
    }
    return null;
}

fn queryU64(query: []const u8, key: []const u8) ?u64 {
    const v = queryParam(query, key) orelse return null;
    return std.fmt.parseInt(u64, v, 10) catch 0;
}

// --- Input timing ------------------------------------------------------------
// How long input ops wait for the main thread, and how long they take on it.

const OpTiming = struct {
    ops: u64 = 0,
    wait_sum: u64 = 0,
    wait_max: u64 = 0,
    run_sum: u64 = 0,
    run_max: u64 = 0,

    fn json(self: *const OpTiming, w: *std.Io.Writer, name: []const u8) !void {
        const n = @max(self.ops, 1);
        try w.print("\"{s}\":{{\"ops\":{d},\"wait_avg\":{d},\"wait_max\":{d},\"run_avg\":{d},\"run_max\":{d}}}", .{
            name, self.ops, self.wait_sum / n / 1000, self.wait_max / 1000, self.run_sum / n / 1000, self.run_max / 1000,
        });
    }
};

var op_mutex: std.Io.Mutex = .init;
var t_mouse: OpTiming = .{};
var t_other: OpTiming = .{};

const TimedOp = struct {
    func: *const fn (?*anyopaque) void,
    op: *input.Op,
    started: u64 = 0,
    done: u64 = 0,

    fn run(ctx: ?*anyopaque) void {
        const t: *TimedOp = @ptrCast(@alignCast(ctx));
        t.started = clock.monoNs();
        t.func(t.op);
        t.done = clock.monoNs();
    }
};

fn runOp(func: *const fn (?*anyopaque) void, o: *input.Op) void {
    var t: TimedOp = .{ .func = func, .op = o };
    const queued = clock.monoNs();
    loop.call(TimedOp.run, &t);
    const wait = t.started - queued;
    const ran = t.done - t.started;
    const io = global.io();
    op_mutex.lockUncancelable(io);
    defer op_mutex.unlock(io);
    const s = if (func == &input.opMouse) &t_mouse else &t_other;
    s.ops += 1;
    s.wait_sum += wait;
    s.run_sum += ran;
    s.wait_max = @max(s.wait_max, wait);
    s.run_max = @max(s.run_max, ran);
}

// --- GET -----------------------------------------------------------------------

/// Answers without the main thread, which may be busy presenting frames.
fn handleStatus(fd: c.fd_t) void {
    var windows_buf: [2048]u8 = undefined;
    const windows = main.windowsJson(&windows_buf);
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    statusJson(&w, windows) catch return respondError(fd, 503, "status too long");
    respondJson(fd, 200, w.buffered());
}

fn statusJson(w: *std.Io.Writer, windows: []const u8) !void {
    const g = main.geo;
    try w.print("{{\"pid\":{d},\"surface\":true,", .{c.getpid()});
    try input.stateJson(w);
    try w.print(
        ",\"real_input\":false,\"size\":{{\"width\":{d},\"height\":{d},\"scale\":{d},\"cell_width\":{d},\"cell_height\":{d}," ++
            "\"columns\":{d},\"rows\":{d},\"padding\":{{\"top\":{d},\"bottom\":{d},\"left\":{d},\"right\":{d}}}}},",
        .{ g.width, g.height, main.opt.scale, g.cell_width, g.cell_height, g.columns, g.rows, g.pad_top, g.pad_bottom, g.pad_left, g.pad_right },
    );
    try frames.statsJson(w);
    try w.writeAll(",\"shape\":");
    try shape.briefJson(w);
    try w.writeAll(",\"input_us\":{");
    {
        const io = global.io();
        op_mutex.lockUncancelable(io);
        defer op_mutex.unlock(io);
        try t_mouse.json(w, "mouse");
        try w.writeByte(',');
        try t_other.json(w, "other");
    }
    try w.print("}},\"tty\":{f},\"windows\":[{s}]}}", .{ std.json.fmt(main.tty(), .{}), windows });
}

fn frameHeaders(buf: []u8, f: *const frames.Frame) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "x-frame-seq: {d}\r\nx-frame-width: {d}\r\nx-frame-height: {d}\r\nx-frame-stride: {d}\r\n" ++
            "x-frame-format: rgba\r\nx-frame-time-unix-ns: {d}\r\nx-frame-time-mono-ns: {d}\r\n",
        .{ f.seq, f.width, f.height, f.width * 4, f.time_unix_ns, f.time_mono_ns },
    ) catch "";
}

fn handleFrame(fd: c.fd_t, query: []const u8) void {
    const after = queryU64(query, "after");
    const timeout_ms = queryU64(query, "timeout_ms") orelse 10000;
    const format = queryParam(query, "format") orelse "rgba";
    const png = std.mem.eql(u8, format, "png");
    if (!png and !std.mem.eql(u8, format, "rgba")) return respondError(fd, 400, "format is rgba or png");

    const f = (if (after) |a| frames.wait(a, timeout_ms) else frames.latestFrame() orelse frames.wait(0, timeout_ms)) orelse
        return respondError(fd, 504, "no frame before the timeout");
    defer f.release();
    var extra_buf: [512]u8 = undefined;
    const extra = frameHeaders(&extra_buf, f);
    if (png) {
        // Encoded in memory, never written to disk.
        const bytes = image.png(global.alloc(), f.bytes(), f.width, f.height) catch
            return respondError(fd, 503, "could not encode the frame");
        defer global.alloc().free(bytes);
        respond(fd, 200, "image/png", bytes, extra);
    } else {
        respond(fd, 200, "application/octet-stream", f.bytes(), extra);
    }
}

fn peerClosed(fd: c.fd_t) bool {
    var p = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&p, 1, 0) <= 0) return false;
    var byte: [1]u8 = undefined;
    return c.recv(fd, &byte, 1, c.MSG.PEEK | c.MSG.DONTWAIT) == 0 or (p[0].revents & (c.POLL.HUP | c.POLL.ERR)) != 0;
}

/// One chunk: "<hex size>\r\n" header pixels "\r\n".
fn sendChunk(fd: c.fd_t, head: []const u8, f: *const frames.Frame) bool {
    const pixels = f.bytes();
    var size_buf: [32]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{head.len + pixels.len}) catch return false;
    var iov = [_]std.posix.iovec_const{
        .{ .base = size.ptr, .len = size.len },
        .{ .base = head.ptr, .len = head.len },
        .{ .base = pixels.ptr, .len = pixels.len },
        .{ .base = "\r\n", .len = 2 },
    };
    return sendIov(fd, &iov);
}

/// GET /frames: every published frame, GCF1 header + pixels, as
/// ghostty-capture streams them. ?format=raw drops the headers; with &fps=N
/// it repeats the latest frame at a constant rate, which ffmpeg's rawvideo
/// input expects.
fn handleFrames(fd: c.fd_t, query: []const u8) void {
    const after = queryU64(query, "after");
    const fps = queryU64(query, "fps") orelse 0;
    const format = queryParam(query, "format") orelse "gcf1";
    const raw = std.mem.eql(u8, format, "raw");
    if (!raw and !std.mem.eql(u8, format, "gcf1")) return respondError(fd, 400, "format is gcf1 or raw");
    if (fps > 0 and !raw) return respondError(fd, 400, "fps needs format=raw");
    if (fps > 240) return respondError(fd, 400, "fps is at most 240");

    const first = frames.wait(0, 10000) orelse return respondError(fd, 504, "no frame yet");
    var head_buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n" ++
            "Connection: close\r\nx-frame-format: {s}\r\nx-frame-width: {d}\r\nx-frame-height: {d}\r\n" ++
            "x-frame-pixel-format: rgba\r\n\r\n",
        .{ if (raw) "raw" else "gcf1", first.width, first.height },
    ) catch unreachable;
    first.release();
    if (!sendAll(fd, head)) return;

    if (fps > 0) {
        const period = std.time.ns_per_s / fps;
        const begin = clock.monoNs();
        var k: u64 = 0;
        while (true) : (k += 1) {
            const due = begin + k * period;
            const now = clock.monoNs();
            if (due > now) clock.sleepNs(due - now);
            const f = frames.latestFrame() orelse continue;
            const ok = sendChunk(fd, "", f);
            f.release();
            if (!ok) break;
        }
        return;
    }

    const s = frames.subscribe(after) catch return;
    defer frames.unsubscribe(s);
    while (true) {
        var skipped: u32 = 0;
        const f = frames.next(s, &skipped, 1000) orelse {
            if (peerClosed(fd)) break;
            continue;
        };
        defer f.release();
        var gcf: [64]u8 = @splat(0);
        @memcpy(gcf[0..4], "GCF1");
        std.mem.writeInt(u32, gcf[4..8], 64, .little);
        std.mem.writeInt(u32, gcf[8..12], f.width, .little);
        std.mem.writeInt(u32, gcf[12..16], f.height, .little);
        std.mem.writeInt(u32, gcf[16..20], f.width * 4, .little);
        std.mem.writeInt(u32, gcf[20..24], 1, .little); // RGBA8, premultiplied alpha
        std.mem.writeInt(u64, gcf[24..32], f.seq, .little);
        std.mem.writeInt(u64, gcf[32..40], f.time_unix_ns, .little);
        std.mem.writeInt(u64, gcf[40..48], f.time_mono_ns, .little);
        std.mem.writeInt(u32, gcf[48..52], skipped, .little);
        std.mem.writeInt(u64, gcf[56..64], @as(u64, f.width) * f.height * 4, .little);
        if (!sendChunk(fd, if (raw) "" else &gcf, f)) break;
    }
}

// --- Requests -------------------------------------------------------------------

const post_routes = std.StaticStringMap(*const fn (?*anyopaque) void).initComptime(.{
    .{ "/key", &input.opKey },
    .{ "/type", &input.opType },
    .{ "/mouse", &input.opMouse },
    .{ "/focus", &input.opFocus },
    .{ "/action", &input.opAction },
    .{ "/quit", &input.opQuit },
});

const get_paths = std.StaticStringMap(void).initComptime(.{
    .{"/status"}, .{"/frame"}, .{"/frames"}, .{"/shape"}, .{"/settle"},
});

fn serveConn(fd: c.fd_t) void {
    loop.interactive();
    defer _ = c.close(fd);
    const alloc = global.alloc();
    const cap = (1 << 20) - 1;
    const req = alloc.alloc(u8, cap + 1) catch return;
    defer alloc.free(req);
    var len: usize = 0;
    var body: []u8 = &.{};
    while (true) {
        const n = c.read(fd, req[len..cap].ptr, cap - len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return;
        len += @intCast(n);
        const end = std.mem.indexOf(u8, req[0..len], "\r\n\r\n") orelse {
            if (len == cap) return;
            continue;
        };
        const head = req[0..end];
        const body_start = end + 4;
        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
        }
        if (content_length > cap - body_start) return respondError(fd, 400, "body too large");
        while (len - body_start < content_length) {
            const m = c.read(fd, req[len..cap].ptr, cap - len);
            if (m < 0 and std.posix.errno(m) == .INTR) continue;
            if (m <= 0) return;
            len += @intCast(m);
        }
        body = req[body_start..][0..content_length];
        break;
    }

    const line_end = std.mem.indexOf(u8, req[0..len], "\r\n") orelse len;
    var parts = std.mem.tokenizeScalar(u8, req[0..line_end], ' ');
    const method = parts.next() orelse return respondError(fd, 400, "bad request line");
    const target = parts.next() orelse return respondError(fd, 400, "bad request line");
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |i| target[i + 1 ..] else "";
    const get = std.mem.eql(u8, method, "GET");
    const post = std.mem.eql(u8, method, "POST");
    const route = post_routes.get(path);

    if (get and std.mem.eql(u8, path, "/status")) {
        handleStatus(fd);
    } else if (get and std.mem.eql(u8, path, "/frame")) {
        handleFrame(fd, query);
    } else if (get and std.mem.eql(u8, path, "/frames")) {
        handleFrames(fd, query);
    } else if (get and std.mem.eql(u8, path, "/settle")) {
        var seq: u64 = 0;
        const settled = frames.settle(queryU64(query, "quiet_ms") orelse 500, queryU64(query, "timeout_ms") orelse 10000, &seq);
        var buf: [128]u8 = undefined;
        respondJson(fd, 200, std.fmt.bufPrint(&buf, "{{\"settled\":{},\"frame\":{d}}}", .{ settled, seq }) catch unreachable);
    } else if (get and std.mem.eql(u8, path, "/shape")) {
        const buf = alloc.alloc(u8, 32768) catch return respondError(fd, 503, "out of memory");
        defer alloc.free(buf);
        var w: std.Io.Writer = .fixed(buf);
        shape.json(&w, queryU64(query, "after"), queryU64(query, "timeout_ms") orelse 10000) catch {};
        respondJson(fd, 200, w.buffered());
    } else if (post and route != null) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, if (body.len > 0) body else "{}", .{}) catch
            return respondError(fd, 400, "body must be JSON");
        defer parsed.deinit();
        const func = route.?;
        const ok_shape = parsed.value == .object or (parsed.value == .array and func == &input.opMouse);
        if (!ok_shape) return respondError(fd, 400, "body must be a JSON object");
        var out: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        var o: input.Op = .{ .body = parsed.value, .out = &w };
        runOp(func, &o);
        respondJson(fd, o.status, w.buffered());
    } else if (route != null or get_paths.has(path)) {
        respondError(fd, 405, "wrong method");
    } else {
        respondError(fd, 404, "no such endpoint");
    }
}

var listen_fd: c.fd_t = -1;

fn server() void {
    while (true) {
        const fd = c.accept(listen_fd, null, null);
        if (fd < 0) {
            if (std.posix.errno(fd) == .INTR) continue;
            std.debug.print("ghostty-host: accept failed\n", .{});
            return;
        }
        const t = std.Thread.spawn(.{}, serveConn, .{fd}) catch {
            _ = c.close(fd);
            continue;
        };
        t.detach();
    }
}

pub fn start(socket_path: []const u8) !void {
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    _ = c.unlink(@ptrCast(&addr.path));
    listen_fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (listen_fd < 0 or
        c.bind(listen_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0 or
        c.listen(listen_fd, 64) < 0)
    {
        std.debug.print("ghostty-host: cannot listen on {s}\n", .{socket_path});
        std.process.exit(1);
    }
    const t = try std.Thread.spawn(.{}, server, .{});
    t.detach();
}
