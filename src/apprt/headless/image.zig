//! Pixel conversion and PNG encoding for ghostty-host frames.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Display P3 and sRGB share the D65 white point and the sRGB transfer
/// curve, so the conversion is: decode, 3x3 matrix in linear light, encode.
/// Linear P3 to linear sRGB (the inverse of the standard sRGB to P3 matrix).
const p3_to_srgb = [3][3]f32{
    .{ 1.2249401, -0.2249404, 0.0000000 },
    .{ -0.0420569, 1.0420571, 0.0000000 },
    .{ -0.0196376, -0.0786361, 1.0982735 },
};

const encode_steps = 16384;

const luts = luts: {
    @setEvalBranchQuota(10_000_000);
    var dec: [256]f32 = undefined;
    for (&dec, 0..) |*d, i| {
        const v: f64 = @as(f64, @floatFromInt(i)) / 255.0;
        d.* = @floatCast(if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4));
    }
    var enc: [encode_steps + 1]u8 = undefined;
    for (&enc, 0..) |*e, i| {
        const v: f64 = @as(f64, @floatFromInt(i)) / encode_steps;
        const s = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
        e.* = @intFromFloat(@round(std.math.clamp(s, 0, 1) * 255));
    }
    break :luts .{ .decode = dec, .encode = enc };
};

inline fn encode(v: f32) u8 {
    if (v <= 0) return 0;
    if (v >= 1) return 255;
    return luts.encode[@intFromFloat(v * encode_steps + 0.5)];
}

inline fn unpremul(c: u8, a: u8) u8 {
    return @intCast((@as(u32, c) * 255 + a / 2) / a);
}

inline fn premul(c: u8, a: u8) u8 {
    return @intCast((@as(u32, c) * a + 127) / 255);
}

fn convertPixel(bgra: u32) u32 {
    var b: u8 = @truncate(bgra);
    var g: u8 = @truncate(bgra >> 8);
    var r: u8 = @truncate(bgra >> 16);
    const a: u8 = @truncate(bgra >> 24);
    if (a == 0) return 0;
    // Ghostty writes premultiplied alpha; convert the color, keep the alpha.
    if (a != 255) {
        r = unpremul(r, a);
        g = unpremul(g, a);
        b = unpremul(b, a);
    }
    const lr = luts.decode[r];
    const lg = luts.decode[g];
    const lb = luts.decode[b];
    const m = p3_to_srgb;
    var sr = encode(m[0][0] * lr + m[0][1] * lg + m[0][2] * lb);
    var sg = encode(m[1][0] * lr + m[1][1] * lg + m[1][2] * lb);
    var sb = encode(m[2][0] * lr + m[2][1] * lg + m[2][2] * lb);
    if (a != 255) {
        sr = premul(sr, a);
        sg = premul(sg, a);
        sb = premul(sb, a);
    }
    return @as(u32, sr) | @as(u32, sg) << 8 | @as(u32, sb) << 16 | @as(u32, a) << 24;
}

inline fn swizzle(bgra: u32) u32 {
    // BGRA to RGBA: swap bytes 0 and 2.
    return (bgra & 0xFF00FF00) | (bgra & 0xFF) << 16 | (bgra >> 16 & 0xFF);
}

/// Converts premultiplied BGRA to premultiplied RGBA a row at a time. With
/// convert, the input is Display P3 and comes out sRGB; otherwise channels
/// are only reordered.
pub const BgraToRgba = struct {
    convert: bool,
    // Terminal frames are mostly runs of one color, so remember the last one.
    last_in: u32 = 0,
    last_out: u32 = 0,
    have_last: bool = false,

    pub fn row(self: *BgraToRgba, bgra: [*]const u8, width: u32, out: []u8) void {
        const src: [*]align(1) const u32 = @ptrCast(bgra);
        const dst: [*]align(1) u32 = @ptrCast(out.ptr);
        for (0..width) |x| {
            const px = src[x];
            if (!self.have_last or px != self.last_in) {
                self.last_in = px;
                self.last_out = if (self.convert) convertPixel(px) else swizzle(px);
                self.have_last = true;
            }
            dst[x] = self.last_out;
        }
    }
};

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Encodes tightly packed premultiplied RGBA as a PNG tagged sRGB, dropping
/// the alpha channel when every pixel is opaque. The caller frees it.
pub fn png(alloc: Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    const pixels = @as(usize, width) * height;
    var opaque_ = true;
    for (0..pixels) |i| {
        if (rgba[i * 4 + 3] != 255) {
            opaque_ = false;
            break;
        }
    }
    const channels: usize = if (opaque_) 3 else 4;
    const row = @as(usize, width) * channels + 1;
    const raw = try alloc.alloc(u8, row * height);
    defer alloc.free(raw);
    for (0..height) |y| {
        const dst = raw[y * row ..][0..row];
        const src = rgba[y * width * 4 ..][0 .. width * 4];
        dst[0] = 0;
        for (0..width) |x| {
            const px = src[x * 4 ..][0..4];
            if (opaque_) {
                @memcpy(dst[1 + x * 3 ..][0..3], px[0..3]);
            } else {
                // PNG wants straight alpha.
                const a = px[3];
                const o = dst[1 + x * 4 ..][0..4];
                for (0..3) |c| o[c] = if (a != 0) unpremul(px[c], a) else 0;
                o[3] = a;
            }
        }
    }
    // Filter "up" on every row but the first: terminal rows repeat a lot.
    var y: usize = height;
    while (y > 1) {
        y -= 1;
        const cur = raw[y * row ..][0..row];
        const prev = raw[(y - 1) * row ..][0..row];
        cur[0] = 2;
        for (1..row) |i| cur[i] -%= prev[i];
    }

    // Deflate needs room to write into from the start; terminal frames
    // compress to a small share of their raw size.
    var compressed: std.Io.Writer.Allocating = try .initCapacity(alloc, raw.len / 8 + 4096);
    defer compressed.deinit();
    {
        const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
        defer alloc.free(window);
        var deflate = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .level_6);
        try deflate.writer.writeAll(raw);
        try deflate.finish();
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = if (opaque_) 2 else 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "sRGB", &.{0}); // perceptual
    try chunk(w, "IDAT", compressed.written());
    try chunk(w, "IEND", "");
    return try out.toOwnedSlice();
}
