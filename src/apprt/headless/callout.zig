//! The callout a capture shows for what a click opened: a picture drawn on
//! the CPU, which the renderer lays over the terminal (renderer.State.banner).
//! A box with round corners, a border and a soft shadow; a tail pointing at
//! the click; Chrome's logo; and text in Ghostty's embedded font, a size up
//! from the terminal's. Shapes are smoothed from their distance fields.
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../../font/main.zig");

pub const Icon = enum { none, chrome };

pub const Spec = struct {
    icon: Icon = .none,
    text: []const u8 = "",
    /// Drawn after text, in bold.
    strong: []const u8 = "",
    /// What it points at, in pixels from the grid's top left: the click, and
    /// the top and bottom of its row. Without one it sits at the bottom right.
    at: ?At = null,
};

pub const At = struct { x: f64, top: f64, bottom: f64 };

/// What the callout is drawn on: the grid's size in pixels, the terminal's
/// font size and cell, and whether its background is dark.
pub const Geometry = struct {
    width: u32,
    height: u32,
    cell_width: u32,
    font_size: font.face.DesiredSize,
    dark: bool,
};

/// RGBA pixels, not premultiplied, whose top left is (x, y) on the grid.
/// `rise` is the way it moves as it fades in: toward where it points from.
pub const Picture = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    rise: i32,

    pub fn deinit(self: Picture, alloc: Allocator) void {
        alloc.free(self.pixels);
    }
};

/// How much larger than the terminal's the callout's text is.
const text_scale = 1.2;

const Fonts = struct {
    lib: font.Library,
    regular: font.Face,
    bold: font.Face,
    metrics: font.Metrics,
    atlas: font.Atlas,
    glyphs: std.AutoHashMapUnmanaged(struct { cp: u21, bold: bool }, font.Glyph) = .empty,
    points: f32,
};

/// The callout's fonts, loaded for the terminal's font size on first use.
var loaded: ?Fonts = null;

fn fonts(alloc: Allocator, terminal_size: font.face.DesiredSize) !*Fonts {
    var size = terminal_size;
    size.points *= text_scale;
    if (loaded) |*f| {
        if (f.points == size.points) return f;
        f.glyphs.deinit(alloc);
        f.atlas.deinit(alloc);
        f.bold.deinit();
        f.regular.deinit();
        f.lib.deinit();
        loaded = null;
    }
    const lib = try font.Library.init(alloc);
    var regular = try font.Face.init(lib, font.embedded.regular, .{ .size = size });
    const bold = try font.Face.init(lib, font.embedded.bold, .{ .size = size });
    loaded = .{
        .lib = lib,
        .regular = regular,
        .bold = bold,
        .metrics = .calc(regular.getMetrics()),
        .atlas = try .init(alloc, 1024, .grayscale),
        .points = size.points,
    };
    return &loaded.?;
}

fn glyph(alloc: Allocator, f: *Fonts, cp: u21, bold: bool) !font.Glyph {
    if (f.glyphs.get(.{ .cp = cp, .bold = bold })) |g| return g;
    const face = if (bold) &f.bold else &f.regular;
    const index = face.glyphIndex(cp) orelse face.glyphIndex('?') orelse 0;
    const opts: font.Glyph.RenderOptions = .{ .grid_metrics = f.metrics };
    const g = face.renderGlyph(alloc, &f.atlas, index, opts) catch |err| switch (err) {
        error.AtlasFull => retry: {
            try f.atlas.grow(alloc, f.atlas.size * 2);
            break :retry try face.renderGlyph(alloc, &f.atlas, index, opts);
        },
        else => return err,
    };
    try f.glyphs.put(alloc, .{ .cp = cp, .bold = bold }, g);
    return g;
}

const Placed = struct { g: font.Glyph, x: f64, bold: bool };

const RGB = [3]u8;

const Palette = struct { fill: RGB, border: RGB, soft: RGB, strong: RGB };
/// Light on a dark terminal, dark on a light one.
const light: Palette = .{
    .fill = .{ 0xff, 0xff, 0xff },
    .border = .{ 0x80, 0x86, 0x8b },
    .soft = .{ 0x5f, 0x63, 0x68 },
    .strong = .{ 0x1a, 0x73, 0xe8 },
};
const dark: Palette = .{
    .fill = .{ 0x30, 0x31, 0x34 },
    .border = .{ 0x9a, 0xa0, 0xa6 },
    .soft = .{ 0xbd, 0xc1, 0xc6 },
    .strong = .{ 0x8a, 0xb4, 0xf8 },
};

/// Draws the callout for spec on geo.
pub fn draw(alloc: Allocator, spec: Spec, geo: Geometry) !Picture {
    const f = try fonts(alloc, geo.font_size);
    const advance: f64 = @floatFromInt(f.metrics.cell_width);
    const baseline_up: f64 = @floatFromInt(f.metrics.cell_baseline);
    // Its padding all round: half of what the terminal's cells gave it.
    const pad: f64 = @floatFromInt(geo.cell_width);
    const border = 1.25;
    const tail_w = 18.0;
    const tail_h = 9.0;
    const shadow = 10.0;

    // The text, then strong after a space, shortened with an ellipsis to fit.
    var codepoints: std.ArrayList(struct { cp: u21, bold: bool }) = .empty;
    defer codepoints.deinit(alloc);
    for ([_][]const u8{ spec.text, spec.strong }, [_]bool{ false, true }) |part, bold| {
        if (part.len == 0) continue;
        if (bold and codepoints.items.len > 0) try codepoints.append(alloc, .{ .cp = ' ', .bold = false });
        var it = (try std.unicode.Utf8View.init(part)).iterator();
        while (it.nextCodepoint()) |cp| try codepoints.append(alloc, .{ .cp = cp, .bold = bold });
    }
    const logo: f64 = if (spec.icon == .none) 0 else 1;
    const room = @as(f64, @floatFromInt(geo.width)) - 2 * shadow - 2 * pad - logo * 2.2 * advance;
    const fits: usize = @intFromFloat(@max(1, @floor(room / advance)));
    if (codepoints.items.len > fits) {
        const bold = codepoints.items[fits - 1].bold;
        codepoints.shrinkRetainingCapacity(fits - 1);
        try codepoints.append(alloc, .{ .cp = '…', .bold = bold });
    }

    // The glyphs, and how far their ink reaches above and below the baseline.
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(alloc);
    var ink_top: f64 = 0;
    var ink_bottom: f64 = 0;
    for (codepoints.items, 0..) |c, i| {
        const g = try glyph(alloc, f, c.cp, c.bold);
        try placed.append(alloc, .{ .g = g, .x = @as(f64, @floatFromInt(i)) * advance, .bold = c.bold });
        if (g.height == 0) continue;
        const top = baseline_up - @as(f64, @floatFromInt(g.offset_y));
        ink_top = @min(ink_top, top);
        ink_bottom = @max(ink_bottom, top + @as(f64, @floatFromInt(g.height)));
    }
    const ink = ink_bottom - ink_top;
    const text_w = @as(f64, @floatFromInt(codepoints.items.len)) * advance;
    const logo_d = if (spec.icon == .none) 0 else @round(ink * 0.95);
    const gap = if (spec.icon == .none) 0 else @round(advance * 0.6);
    const w = @round(pad + logo_d + gap + text_w + pad);
    const h = @round(pad + ink + pad);
    const radius = @round(h * 0.22);

    // Where it goes: two rows' height or so above the click with its tail
    // pointing down at it, or below when there's no room above.
    const screen_w: f64 = @floatFromInt(geo.width);
    const screen_h: f64 = @floatFromInt(geo.height);
    var left = screen_w - w - 16;
    var top = screen_h - h - 16;
    var tail: ?Tail = null;
    if (spec.at) |at| {
        const down = at.top - 1 - tail_h - h >= 0;
        const tip_y = if (down) at.top + 1 else at.bottom - 1;
        top = if (down) tip_y - tail_h - h else tip_y + tail_h;
        // The tail leaves from under the logo, or the text's start.
        left = std.math.clamp(at.x - pad - @max(logo_d, advance) / 2, 4, @max(4, screen_w - w - 4));
        const base_x = std.math.clamp(at.x, left + radius + tail_w / 2, left + w - radius - tail_w / 2);
        // Its base reaches into the box, past the border, so they join.
        const base_y = if (down) top + h - border - 2 else top + border + 2;
        tail = .init(.{ base_x - tail_w / 2, base_y }, .{ base_x + tail_w / 2, base_y }, .{ at.x, tip_y });
    }

    // The picture, with room for the shadow, within the grid.
    const tail_top = if (tail) |t| @min(t.a[1], t.c[1]) else top;
    const ox: f64 = @max(0, @floor(left - shadow));
    const oy: f64 = @max(0, @floor(@min(top, tail_top) - shadow));
    const pw: u32 = @intFromFloat(@ceil(left + w + shadow - ox));
    const ph: u32 = @intFromFloat(@ceil(@max(top + h, if (tail) |t| @max(t.a[1], t.c[1]) else top + h) + shadow - oy));
    const pixels = try alloc.alloc(u8, @as(usize, pw) * ph * 4);
    errdefer alloc.free(pixels);
    @memset(pixels, 0);
    const pic: Canvas = .{ .pixels = pixels, .width = pw, .height = ph };
    const palette = if (geo.dark) light else dark;

    const shape: Shape = .{ .box = .{ .x = left, .y = top, .w = w, .h = h, .r = radius }, .tail = tail };
    for (0..ph) |py| {
        for (0..pw) |px| {
            const x = ox + @as(f64, @floatFromInt(px)) + 0.5;
            const y = oy + @as(f64, @floatFromInt(py)) + 0.5;
            const d = shape.distance(x, y);
            const s = shape.distance(x, y - 3);
            pic.over(px, py, .{ 0, 0, 0 }, 0.3 * (1 - smoothstep(-3, shadow - 2, s)));
            pic.over(px, py, palette.border, clamp(0.5 - d));
            pic.over(px, py, palette.fill, clamp(0.5 - (d + border)));
        }
    }

    // The logo, centered on the text's ink.
    if (spec.icon == .chrome) {
        const c: Logo = .{ .cx = left + pad + logo_d / 2 - ox, .cy = top + h / 2 - oy, .r = logo_d / 2 };
        c.draw(pic);
    }

    // The text.
    const text_x = left + pad + logo_d + gap - ox;
    const baseline = top + pad - ink_top - oy;
    for (placed.items) |p| {
        const g = p.g;
        const gx: i64 = @as(i64, @intFromFloat(@round(text_x + p.x))) + g.offset_x;
        const gy: i64 = @intFromFloat(@round(baseline - (@as(f64, @floatFromInt(g.offset_y)) - baseline_up)));
        const color = if (p.bold) palette.strong else palette.soft;
        for (0..g.height) |j| {
            for (0..g.width) |i| {
                const a = f.atlas.data[(g.atlas_y + j) * f.atlas.size + g.atlas_x + i];
                if (a == 0) continue;
                const px = gx + @as(i64, @intCast(i));
                const py = gy + @as(i64, @intCast(j));
                if (px < 0 or py < 0 or px >= pw or py >= ph) continue;
                pic.over(@intCast(px), @intCast(py), color, @as(f64, @floatFromInt(a)) / 255);
            }
        }
    }

    return .{
        .pixels = pixels,
        .width = pw,
        .height = ph,
        .x = @intFromFloat(ox),
        .y = @intFromFloat(oy),
        .rise = if (tail) |t| (if (t.c[1] > t.a[1]) 1 else -1) else 1,
    };
}

const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    /// Lays color over a pixel at alpha, straight alpha.
    fn over(self: Canvas, x: usize, y: usize, color: RGB, alpha: f64) void {
        if (alpha <= 0) return;
        const o = (y * self.width + x) * 4;
        const below = @as(f64, @floatFromInt(self.pixels[o + 3])) / 255;
        const a = alpha + below * (1 - alpha);
        for (0..3) |k| {
            const mixed = (@as(f64, @floatFromInt(color[k])) * alpha + @as(f64, @floatFromInt(self.pixels[o + k])) * below * (1 - alpha)) / a;
            self.pixels[o + k] = @intFromFloat(@round(mixed));
        }
        self.pixels[o + 3] = @intFromFloat(@round(a * 255));
    }
};

fn clamp(v: f64) f64 {
    return std.math.clamp(v, 0, 1);
}

fn smoothstep(a: f64, b: f64, v: f64) f64 {
    const t = clamp((v - a) / (b - a));
    return t * t * (3 - 2 * t);
}

const Box = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    r: f64,

    fn distance(self: Box, x: f64, y: f64) f64 {
        const qx = @abs(x - (self.x + self.w / 2)) - (self.w / 2 - self.r);
        const qy = @abs(y - (self.y + self.h / 2)) - (self.h / 2 - self.r);
        return std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - self.r;
    }
};

const Tail = struct {
    a: [2]f64,
    b: [2]f64,
    c: [2]f64,

    fn init(a: [2]f64, b: [2]f64, c: [2]f64) Tail {
        return .{ .a = a, .b = b, .c = c };
    }

    /// The largest distance past any edge's line: exact inside, close outside.
    fn distance(self: Tail, x: f64, y: f64) f64 {
        const mid = [2]f64{ (self.a[0] + self.b[0] + self.c[0]) / 3, (self.a[1] + self.b[1] + self.c[1]) / 3 };
        var d: f64 = -std.math.inf(f64);
        for ([_][2][2]f64{ .{ self.a, self.b }, .{ self.b, self.c }, .{ self.c, self.a } }) |e| {
            const dx = e[1][0] - e[0][0];
            const dy = e[1][1] - e[0][1];
            const len = std.math.hypot(dx, dy);
            var nx = dy / len;
            var ny = -dx / len;
            if ((mid[0] - e[0][0]) * nx + (mid[1] - e[0][1]) * ny > 0) {
                nx = -nx;
                ny = -ny;
            }
            d = @max(d, (x - e[0][0]) * nx + (y - e[0][1]) * ny);
        }
        return d;
    }
};

const Shape = struct {
    box: Box,
    tail: ?Tail,

    fn distance(self: Shape, x: f64, y: f64) f64 {
        const d = self.box.distance(x, y);
        return if (self.tail) |t| @min(d, t.distance(x, y)) else d;
    }
};

/// Chrome's logo: three blades around a white ring and a blue center. Each
/// blade's edge leaves the ring along a tangent to it and meets the rim 30°
/// on, so they swirl.
const Logo = struct {
    cx: f64,
    cy: f64,
    r: f64,

    const red: RGB = .{ 0xea, 0x43, 0x35 };
    const yellow: RGB = .{ 0xfb, 0xbc, 0x04 };
    const green: RGB = .{ 0x34, 0xa8, 0x53 };
    const blue: RGB = .{ 0x1a, 0x73, 0xe8 };
    const white: RGB = .{ 0xff, 0xff, 0xff };

    /// What's at (x, y): a color, or nothing outside.
    fn at(self: Logo, x: f64, y: f64) ?RGB {
        const dx = x - self.cx;
        const dy = self.cy - y;
        const rho = std.math.hypot(dx, dy) / self.r;
        if (rho > 1) return null;
        if (rho <= 0.4) return blue;
        if (rho < 0.5) return white;
        const theta = std.math.radiansToDegrees(std.math.atan2(dy, dx));
        const turned = @mod(theta - std.math.radiansToDegrees(std.math.asin(0.5 / rho)), 360);
        // Counterclockwise from the right: red over the top, green, yellow.
        return if (turned < 120) red else if (turned < 240) green else yellow;
    }

    /// Draws it, each pixel from 4×4 samples.
    fn draw(self: Logo, pic: Canvas) void {
        const x0: usize = @intFromFloat(@max(0, @floor(self.cx - self.r)));
        const y0: usize = @intFromFloat(@max(0, @floor(self.cy - self.r)));
        const x1: usize = @min(pic.width, @as(usize, @intFromFloat(@ceil(self.cx + self.r))) + 1);
        const y1: usize = @min(pic.height, @as(usize, @intFromFloat(@ceil(self.cy + self.r))) + 1);
        for (y0..y1) |py| {
            for (x0..x1) |px| {
                var sum = [3]f64{ 0, 0, 0 };
                var n: f64 = 0;
                for (0..4) |j| {
                    for (0..4) |i| {
                        const sx = @as(f64, @floatFromInt(px)) + (@as(f64, @floatFromInt(i)) + 0.5) / 4;
                        const sy = @as(f64, @floatFromInt(py)) + (@as(f64, @floatFromInt(j)) + 0.5) / 4;
                        const color = self.at(sx, sy) orelse continue;
                        for (0..3) |k| sum[k] += @floatFromInt(color[k]);
                        n += 1;
                    }
                }
                if (n == 0) continue;
                const avg: RGB = .{
                    @intFromFloat(@round(sum[0] / n)),
                    @intFromFloat(@round(sum[1] / n)),
                    @intFromFloat(@round(sum[2] / n)),
                };
                pic.over(px, py, avg, n / 16);
            }
        }
    }
};
