//! Sprites for the headless app runtime's callouts, which special.zig names
//! after Sprite's fields: a callout's ends with round corners, its tail
//! pointing down or up, and Chrome's logo in layers, red, yellow, green and
//! blue, which the renderer stacks in each one's color. Edges are smoothed
//! from 4×4 samples a pixel.

const std = @import("std");
const font = @import("../../main.zig");

const samples = 4;

/// Fills the pixels from (x0, y0) to (x1, y1), relative to the cell, by how
/// much of each `shape.contains` covers.
fn fill(canvas: *font.sprite.Canvas, x0: i32, y0: i32, x1: i32, y1: i32, shape: anytype) void {
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            var n: u32 = 0;
            for (0..samples) |j| {
                for (0..samples) |i| {
                    const sx = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(i)) + 0.5) / samples;
                    const sy = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(j)) + 0.5) / samples;
                    if (shape.contains(sx, sy)) n += 1;
                }
            }
            if (n > 0) canvas.pixel(x, y, @enumFromInt(@as(u8, @intCast(n * 255 / (samples * samples)))));
        }
    }
}

const End = struct {
    w: f64,
    h: f64,
    r: f64,
    left: bool,

    fn contains(self: End, x_: f64, y: f64) bool {
        // The right end is the left one mirrored.
        const x = if (self.left) x_ else self.w - x_;
        if (x >= self.r) return true;
        const cy = if (y < self.r) self.r else if (y > self.h - self.r) self.h - self.r else return true;
        return std.math.hypot(x - self.r, y - cy) <= self.r;
    }
};

/// A callout's end: the cell filled but for round corners on the outside.
fn drawEnd(canvas: *font.sprite.Canvas, width: u32, height: u32, on_left: bool) void {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const end: End = .{ .w = w, .h = h, .r = @min(w, h * 0.3), .left = on_left };
    fill(canvas, 0, 0, @intCast(width), @intCast(height), end);
}

pub fn left(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawEnd(canvas, width, height, true);
}

pub fn right(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawEnd(canvas, width, height, false);
}

const Tail = struct {
    w: f64,
    h: f64,
    down: bool,

    fn contains(self: Tail, x: f64, y_: f64) bool {
        // From the callout's edge to a point most of the way across the cell.
        const y = if (self.down) y_ else self.h - y_;
        const tip = self.h * 0.6;
        if (y < 0 or y > tip) return false;
        return @abs(x - self.w / 2) <= self.w * 0.75 * (1 - y / tip);
    }
};

/// A callout's tail, as wide as a cell and a half where it leaves the callout.
fn drawTail(canvas: *font.sprite.Canvas, width: u32, height: u32, down: bool) void {
    const tail: Tail = .{ .w = @floatFromInt(width), .h = @floatFromInt(height), .down = down };
    const reach: i32 = @intCast(width / 4);
    fill(canvas, -reach, 0, @as(i32, @intCast(width)) + reach, @intCast(height), tail);
}

pub fn tail_down(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawTail(canvas, width, height, true);
}

pub fn tail_up(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawTail(canvas, width, height, false);
}

const Logo = struct {
    cx: f64,
    cy: f64,
    r: f64,
    /// Red, yellow, green or blue.
    layer: u32,

    fn contains(self: Logo, x: f64, y: f64) bool {
        const dx = x - self.cx;
        const dy = self.cy - y;
        const rho = std.math.hypot(dx, dy) / self.r;
        if (self.layer == 3) return rho <= 0.4;
        if (rho < 0.5 or rho > 1) return false;
        // Each blade's edge runs out from the white ring along a tangent to
        // it, reaching the rim 30° on from where it left the ring.
        const theta = std.math.radiansToDegrees(std.math.atan2(dy, dx));
        const turned = @mod(theta - std.math.radiansToDegrees(std.math.asin(0.5 / rho)), 360);
        const blade: u32 = @intFromFloat(@floor(turned / 120));
        // Counterclockwise from the right: red over the top, then green, then yellow.
        const blades = [_]u32{ 0, 2, 1 };
        return blade == blades[self.layer];
    }
};

/// One color of Chrome's logo, centered in the cells it's given.
fn drawLogo(canvas: *font.sprite.Canvas, width: u32, height: u32, layer: u32) void {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const logo: Logo = .{ .cx = w / 2, .cy = h / 2, .r = @min(w, h) * 0.38, .layer = layer };
    fill(canvas, 0, 0, @intCast(width), @intCast(height), logo);
}

pub fn chrome_red(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawLogo(canvas, width, height, 0);
}

pub fn chrome_yellow(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawLogo(canvas, width, height, 1);
}

pub fn chrome_green(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawLogo(canvas, width, height, 2);
}

pub fn chrome_blue(cp: u32, canvas: *font.sprite.Canvas, width: u32, height: u32, metrics: font.Metrics) !void {
    _ = .{ cp, metrics };
    drawLogo(canvas, width, height, 3);
}
