//! Keyboard, mouse and focus input, applied on the main thread straight to
//! the core surface, shaped as the macOS app sends them.
const std = @import("std");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const clock = @import("clock.zig");
const frames = @import("frames.zig");
const callout = @import("callout.zig");
const loop = @import("loop.zig");
const main = @import("main.zig");

const log = std.log.scoped(.ghostty_host);

/// An op's JSON body and reply. Ops run on the main thread (loop.call).
pub const Op = struct {
    body: std.json.Value,
    status: u16 = 500,
    out: *std.Io.Writer,
};

// Modifier bits as input.Mods packs them; a right-hand key also sets its
// side bit, six above.
const shift: u16 = 1;
const ctrl: u16 = 2;
const alt: u16 = 4;
const super: u16 = 8;
const shift_right: u16 = shift << 6;

/// Modifiers held by {"action": "press"}.
var held: u16 = 0;
var focused = true;

const mod_names = std.StaticStringMapWithEql(u16, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "shift", shift },   .{ "ctrl", ctrl },    .{ "control", ctrl }, .{ "alt", alt },
    .{ "opt", alt },       .{ "option", alt },   .{ "super", super },  .{ "cmd", super },
    .{ "command", super }, .{ "meta", super },
});

/// The four modifiers in press order, with the key that carries each.
const mod_keys = [_]struct { mod: u16, code: []const u8 }{
    .{ .mod = shift, .code = "ShiftLeft" },
    .{ .mod = ctrl, .code = "ControlLeft" },
    .{ .mod = alt, .code = "AltLeft" },
    .{ .mod = super, .code = "MetaLeft" },
};

/// X keysyms and other spellings, to W3C codes.
const key_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Return", "Enter" },         .{ "return", "Enter" },        .{ "KP_Enter", "NumpadEnter" },
    .{ "BackSpace", "Backspace" },  .{ "bs", "Backspace" },        .{ "Up", "ArrowUp" },
    .{ "Down", "ArrowDown" },       .{ "Left", "ArrowLeft" },      .{ "Right", "ArrowRight" },
    .{ "Prior", "PageUp" },         .{ "Next", "PageDown" },       .{ "Page_Up", "PageUp" },
    .{ "Page_Down", "PageDown" },   .{ "pageup", "PageUp" },       .{ "pagedown", "PageDown" },
    .{ "esc", "Escape" },           .{ "del", "Delete" },          .{ "space", "Space" },
    .{ "Shift_L", "ShiftLeft" },    .{ "Shift_R", "ShiftRight" },  .{ "Control_L", "ControlLeft" },
    .{ "Control_R", "ControlRight" }, .{ "Alt_L", "AltLeft" },     .{ "Alt_R", "AltRight" },
    .{ "Super_L", "MetaLeft" },     .{ "Super_R", "MetaRight" },   .{ "Meta_L", "MetaLeft" },
    .{ "Meta_R", "MetaRight" },
});

/// US layout: the key and shift state that type each printable character.
const us = [_]struct { c: u8, code: []const u8, shift: bool }{
    .{ .c = ' ', .code = "Space", .shift = false },        .{ .c = '-', .code = "Minus", .shift = false },
    .{ .c = '_', .code = "Minus", .shift = true },         .{ .c = '=', .code = "Equal", .shift = false },
    .{ .c = '+', .code = "Equal", .shift = true },         .{ .c = '[', .code = "BracketLeft", .shift = false },
    .{ .c = '{', .code = "BracketLeft", .shift = true },   .{ .c = ']', .code = "BracketRight", .shift = false },
    .{ .c = '}', .code = "BracketRight", .shift = true },  .{ .c = '\\', .code = "Backslash", .shift = false },
    .{ .c = '|', .code = "Backslash", .shift = true },     .{ .c = ';', .code = "Semicolon", .shift = false },
    .{ .c = ':', .code = "Semicolon", .shift = true },     .{ .c = '\'', .code = "Quote", .shift = false },
    .{ .c = '"', .code = "Quote", .shift = true },         .{ .c = ',', .code = "Comma", .shift = false },
    .{ .c = '<', .code = "Comma", .shift = true },         .{ .c = '.', .code = "Period", .shift = false },
    .{ .c = '>', .code = "Period", .shift = true },        .{ .c = '/', .code = "Slash", .shift = false },
    .{ .c = '?', .code = "Slash", .shift = true },         .{ .c = '`', .code = "Backquote", .shift = false },
    .{ .c = '~', .code = "Backquote", .shift = true },     .{ .c = '1', .code = "Digit1", .shift = false },
    .{ .c = '!', .code = "Digit1", .shift = true },        .{ .c = '2', .code = "Digit2", .shift = false },
    .{ .c = '@', .code = "Digit2", .shift = true },        .{ .c = '3', .code = "Digit3", .shift = false },
    .{ .c = '#', .code = "Digit3", .shift = true },        .{ .c = '4', .code = "Digit4", .shift = false },
    .{ .c = '$', .code = "Digit4", .shift = true },        .{ .c = '5', .code = "Digit5", .shift = false },
    .{ .c = '%', .code = "Digit5", .shift = true },        .{ .c = '6', .code = "Digit6", .shift = false },
    .{ .c = '^', .code = "Digit6", .shift = true },        .{ .c = '7', .code = "Digit7", .shift = false },
    .{ .c = '&', .code = "Digit7", .shift = true },        .{ .c = '8', .code = "Digit8", .shift = false },
    .{ .c = '*', .code = "Digit8", .shift = true },        .{ .c = '9', .code = "Digit9", .shift = false },
    .{ .c = '(', .code = "Digit9", .shift = true },        .{ .c = '0', .code = "Digit0", .shift = false },
    .{ .c = ')', .code = "Digit0", .shift = true },
};

const KeyInfo = struct {
    key: input.Key = .unidentified,
    /// The modifier this key is, if any.
    modifier: u16 = 0,
    /// Text on a US layout, empty for none.
    plain: []const u8 = "",
    shifted: []const u8 = "",
    /// Codepoint with no modifiers.
    unshifted: u21 = 0,
};

/// One-character strings for the US table's text.
const ascii = ascii: {
    var table: [128][1]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = .{i};
    break :ascii table;
};

fn keyInfo(code: []const u8) KeyInfo {
    var k: KeyInfo = .{};
    for (input.keycodes.entries) |e| {
        if (std.mem.eql(u8, e.code, code)) {
            k.key = e.key;
            break;
        }
    }
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key") and std.ascii.isUpper(code[3])) {
        k.plain = &ascii[code[3] + 32];
        k.shifted = &ascii[code[3]];
    }
    for (us) |u| {
        if (!std.mem.eql(u8, u.code, code)) continue;
        if (u.shift) k.shifted = &ascii[u.c] else k.plain = &ascii[u.c];
    }
    if (k.plain.len > 0) k.unshifted = k.plain[0];
    if (std.mem.eql(u8, code, "Enter") or std.mem.eql(u8, code, "NumpadEnter")) k.unshifted = '\r';
    if (std.mem.eql(u8, code, "Tab")) k.unshifted = '\t';
    if (std.mem.eql(u8, code, "Backspace")) k.unshifted = 0x7f;
    if (std.mem.eql(u8, code, "Escape")) k.unshifted = 0x1b;
    if (std.mem.startsWith(u8, code, "Shift")) k.modifier = shift;
    if (std.mem.startsWith(u8, code, "Control")) k.modifier = ctrl;
    if (std.mem.startsWith(u8, code, "Alt")) k.modifier = alt;
    if (std.mem.startsWith(u8, code, "Meta")) k.modifier = super;
    // Right-hand modifiers also set their side bit, as the macOS app does.
    if (k.modifier != 0 and std.mem.indexOf(u8, code, "Right") != null) k.modifier |= k.modifier << 6;
    return k;
}

/// Ghostty's name for a key: its tag without "key_" ("a", "enter", "arrow_up").
fn keyName(key: input.Key) []const u8 {
    const tag = @tagName(key);
    return if (std.mem.startsWith(u8, tag, "key_")) tag[4..] else tag;
}

/// Resolves a key name: one character (US layout), a W3C code, a Ghostty key
/// name or an X keysym. implied gets shift for characters that need it.
fn resolveKey(name_: []const u8, implied: *u16) ?KeyInfo {
    implied.* = 0;
    if (name_.len == 1) {
        const c = name_[0];
        if (std.ascii.isAlphabetic(c)) {
            const code = [_]u8{ 'K', 'e', 'y', std.ascii.toUpper(c) };
            implied.* = if (std.ascii.isUpper(c)) shift else 0;
            return keyInfo(&code);
        }
        for (us) |u| if (u.c == c) {
            implied.* = if (u.shift) shift else 0;
            return keyInfo(u.code);
        };
    }
    var name = key_aliases.get(name_) orelse name_;
    var digit: [16]u8 = undefined;
    if (name.len > 6 and std.ascii.startsWithIgnoreCase(name, "digit") and name[5] == '_')
        name = std.fmt.bufPrint(&digit, "Digit{s}", .{name[6..]}) catch name;
    for (input.keycodes.entries) |e| {
        if (e.key == .unidentified) continue;
        if (std.mem.eql(u8, name, e.code) or std.ascii.eqlIgnoreCase(name, keyName(e.key))) return keyInfo(e.code);
    }
    return null;
}

/// One key event shaped like the macOS app's (NSEvent+Extension.swift): text
/// never starts with a control character, and control and command never
/// count as consumed. Option acts as alt, so it isn't consumed either.
fn keyEvent(action: input.Action, k: KeyInfo, mods: u16, text_: ?[]const u8) bool {
    var text: []const u8 = text_ orelse if (mods & shift != 0 and k.shifted.len > 0) k.shifted else k.plain;
    if (action == .release) text = "";
    if (text.len > 0 and (text[0] < 0x20 or text[0] == 0x7f)) text = "";
    const effect = main.surface.core_surface.keyCallback(.{
        .action = action,
        .key = k.key,
        .mods = @bitCast(mods),
        .consumed_mods = @bitCast(mods & (shift | shift_right)),
        .composing = false,
        .utf8 = text,
        .unshifted_codepoint = k.unshifted,
    }) catch |err| {
        log.warn("error processing key event err={}", .{err});
        return false;
    };
    return effect != .ignored;
}

/// Presses each modifier in mods not already held, as its own key. Returns
/// the modifiers it pressed.
fn pressMods(mods: u16) u16 {
    var pressed: u16 = 0;
    for (mod_keys) |m| {
        if (mods & m.mod == 0 or held & m.mod != 0) continue;
        pressed |= m.mod;
        _ = keyEvent(.press, keyInfo(m.code), held | pressed, null);
    }
    return pressed;
}

fn releaseMods(pressed_: u16) void {
    var pressed = pressed_;
    var i: usize = mod_keys.len;
    while (i > 0) {
        i -= 1;
        const m = mod_keys[i];
        if (pressed & m.mod == 0) continue;
        pressed &= ~m.mod;
        _ = keyEvent(.release, keyInfo(m.code), held | pressed, null);
    }
}

const ModError = error{BadMods};

/// Modifiers from a "ctrl+shift" string.
fn parseModString(s: []const u8, bad: *[]const u8) u16 {
    var mods: u16 = 0;
    var it = std.mem.splitScalar(u8, s, '+');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (mod_names.get(tok)) |m| mods |= m else bad.* = "unknown modifier";
    }
    return mods;
}

/// Modifiers from a string or an array of strings, each of which may itself
/// be "ctrl+shift".
fn parseModList(v: ?std.json.Value, bad: *[]const u8) u16 {
    const value = v orelse return 0;
    switch (value) {
        .string => |s| return parseModString(s, bad),
        .array => |a| {
            var mods: u16 = 0;
            for (a.items) |item| switch (item) {
                .string => |s| mods |= parseModString(s, bad),
                else => {
                    bad.* = "mods is a string or an array of strings";
                    return 0;
                },
            };
            return mods;
        },
        else => {
            bad.* = "mods is a string or an array of strings";
            return 0;
        },
    }
}

const KeyAction = enum { tap, press, release, repeat };

/// Sends one key spec in keybind syntax ("ctrl+shift+t", "Return", "A").
/// Returns an error message, or null.
fn sendSpec(spec: []const u8, action: KeyAction, text: ?[]const u8, consumed: *bool) ?[]const u8 {
    // The last '+'-separated token is the key; a trailing "+" is the plus key.
    var key = spec;
    var mods: u16 = 0;
    const last_plus: ?usize = if (spec.len > 1 and spec[spec.len - 1] == '+' and spec[spec.len - 2] == '+')
        spec.len - 2
    else
        std.mem.lastIndexOfScalar(u8, spec, '+');
    if (last_plus) |p| if (p > 0) {
        key = spec[p + 1 ..];
        var bad: []const u8 = "";
        mods = parseModString(spec[0..p], &bad);
        if (bad.len > 0) return bad;
    };
    var implied: u16 = 0;
    const k = resolveKey(key, &implied) orelse return "unknown key";
    mods |= implied;

    switch (action) {
        .tap => {
            const pressed = pressMods(mods);
            consumed.* = keyEvent(.press, k, held | mods | k.modifier, text);
            _ = keyEvent(.release, k, held | mods, null);
            releaseMods(pressed);
        },
        .press => {
            held |= pressMods(mods);
            consumed.* = keyEvent(.press, k, held | k.modifier, text);
            held |= k.modifier;
        },
        .release => {
            held &= ~k.modifier;
            consumed.* = keyEvent(.release, k, held, null);
            releaseMods(mods & held);
            held &= ~mods;
        },
        .repeat => consumed.* = keyEvent(.repeat, k, held | mods, text),
    }
    return null;
}

var state_mutex: std.Io.Mutex = .init;
var shared_focused = true;
var shared_held: u16 = 0;

/// Ops run on the main thread; publish what /status reports after each one.
fn publishState() void {
    const io = global.io();
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    shared_focused = focused;
    shared_held = held;
}

/// Focus and held modifiers for /status. Any thread.
pub fn stateJson(w: *std.Io.Writer) !void {
    const io = global.io();
    state_mutex.lockUncancelable(io);
    const f = shared_focused;
    const h = shared_held;
    state_mutex.unlock(io);
    try w.print("\"focused\":{},\"held_mods\":[", .{f});
    const names = [_][]const u8{ "shift", "ctrl", "alt", "super" };
    var first = true;
    for (mod_keys, names) |m, n| {
        if (h & m.mod == 0) continue;
        try w.print("{s}\"{s}\"", .{ if (first) "" else ",", n });
        first = false;
    }
    try w.writeByte(']');
}

fn reply(o: *Op, status: u16, err: ?[]const u8) void {
    publishState();
    o.status = status;
    if (err) |e| {
        o.out.print("{{\"ok\":false,\"error\":{f}}}", .{std.json.fmt(e, .{})}) catch {};
    } else {
        // N is the last frame drawn before this input, so GET /frame?after=N
        // waits for one drawn after it.
        o.out.print("{{\"ok\":true,\"frame\":{d}}}", .{frames.drawnSeq()}) catch {};
    }
}

fn field(body: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (body) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(body: std.json.Value, key: []const u8) ?[]const u8 {
    const v = field(body, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn num(body: std.json.Value, key: []const u8) ?f64 {
    const v = field(body, key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn opKey(ctx: ?*anyopaque) void {
    const o: *Op = @ptrCast(@alignCast(ctx));
    const a = str(o.body, "action");
    const action: KeyAction = if (a) |s| std.meta.stringToEnum(KeyAction, s) orelse
        return reply(o, 400, "action is tap, press, release or repeat") else .tap;
    const text = str(o.body, "text");
    const keys = field(o.body, "key") orelse return reply(o, 400, "key is a string or an array");
    var consumed = false;
    switch (keys) {
        .string => |s| if (sendSpec(s, action, text, &consumed)) |err| return reply(o, 400, err),
        .array => |list| for (list.items) |item| switch (item) {
            .string => |s| if (sendSpec(s, action, text, &consumed)) |err| return reply(o, 400, err),
            else => return reply(o, 400, "key is a string or an array"),
        },
        else => return reply(o, 400, "key is a string or an array"),
    }
    reply(o, 200, null);
}

pub fn opType(ctx: ?*anyopaque) void {
    const o: *Op = @ptrCast(@alignCast(ctx));
    const text = str(o.body, "text") orelse return reply(o, 400, "text is required");
    var consumed = false;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const bytes = text[i..end];
        const cp: u21 = std.unicode.utf8Decode(bytes) catch 0xFFFD;
        i = end;
        switch (cp) {
            '\n', '\r' => _ = sendSpec("Enter", .tap, null, &consumed),
            '\t' => _ = sendSpec("Tab", .tap, null, &consumed),
            0x7f, 0x08 => _ = sendSpec("Backspace", .tap, null, &consumed),
            0x1b => _ = sendSpec("Escape", .tap, null, &consumed),
            1...7, 11, 12, 14...26 => {
                const spec = [_]u8{ 'c', 't', 'r', 'l', '+', @intCast('a' + cp - 1) };
                _ = sendSpec(&spec, .tap, null, &consumed);
            },
            0, 0x1c...0x1f => {},
            0x20...0x7e => _ = sendSpec(&ascii[cp], .tap, null, &consumed),
            else => {
                // Not on a US keyboard: committed text from no particular key.
                const k: KeyInfo = .{ .unshifted = cp };
                _ = keyEvent(.press, k, held, bytes);
                _ = keyEvent(.release, k, held, null);
            },
        }
    }
    reply(o, 200, null);
}

fn mouseOne(m: std.json.Value) ?[]const u8 {
    if (m != .object) return "each mouse event is an object";
    var bad: []const u8 = "";
    const mods = parseModList(field(m, "mods"), &bad);
    if (bad.len > 0) return bad;
    const action = str(m, "action") orelse "move";
    const x = num(m, "x");
    const y = num(m, "y");
    if ((x == null) != (y == null)) return "give both x and y";
    if (x == null and std.mem.eql(u8, action, "move")) return "move needs x and y";

    var button: input.MouseButton = .left;
    if (str(m, "button")) |b| {
        button = std.meta.stringToEnum(input.MouseButton, b) orelse return "unknown button";
        if (button == .unknown) return "unknown button";
    }
    const count: usize = if (num(m, "count")) |c| @intFromFloat(@max(0, c)) else 1;
    const Act = enum { move, press, release, click, scroll, leave };
    const act = std.meta.stringToEnum(Act, action) orelse
        return "action is move, press, release, click, scroll or leave";

    const pressed = pressMods(mods);
    defer releaseMods(pressed);
    const all: input.Mods = @bitCast(held | mods);
    const surface = main.surface;
    if (x) |px| surface.cursorPos(px, y.?, all);
    const core = &surface.core_surface;
    switch (act) {
        .move => {},
        .press => _ = core.mouseButtonCallback(.press, button, all) catch {},
        .release => _ = core.mouseButtonCallback(.release, button, all) catch {},
        // Ghostty counts double and triple clicks itself, by timing.
        .click => for (0..count) |_| {
            _ = core.mouseButtonCallback(.press, button, all) catch {};
            _ = core.mouseButtonCallback(.release, button, all) catch {};
        },
        .scroll => {
            const precise = if (field(m, "precise")) |p| p == .bool and p.bool else false;
            core.scrollCallback(num(m, "dx") orelse 0, num(m, "dy") orelse 0, .{ .precision = precise }) catch {};
        },
        // What the macOS app sends from mouseExited.
        .leave => surface.cursorPos(-1, -1, all),
    }
    return null;
}

pub fn opMouse(ctx: ?*anyopaque) void {
    const o: *Op = @ptrCast(@alignCast(ctx));
    switch (o.body) {
        .array => |list| for (list.items) |m| if (mouseOne(m)) |err| return reply(o, 400, err),
        else => if (mouseOne(o.body)) |err| return reply(o, 400, err),
    }
    reply(o, 200, null);
}

pub fn opFocus(ctx: ?*anyopaque) void {
    const o: *Op = @ptrCast(@alignCast(ctx));
    const f = field(o.body, "focused") orelse return reply(o, 400, "focused is true or false");
    if (f != .bool) return reply(o, 400, "focused is true or false");
    focused = f.bool;
    main.surface.core_surface.focusCallback(focused) catch {};
    reply(o, 200, null);
}

pub fn opAction(ctx: ?*anyopaque) void {
    const o: *Op = @ptrCast(@alignCast(ctx));
    const s = str(o.body, "action") orelse return reply(o, 400, "action is required");
    const performed = performed: {
        const a = input.Binding.Action.parse(s) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ s, err });
            break :performed false;
        };
        break :performed main.surface.core_surface.performBindingAction(a) catch false;
    };
    publishState();
    o.status = 200;
    o.out.print("{{\"ok\":true,\"performed\":{},\"frame\":{d}}}", .{ performed, frames.drawnSeq() }) catch {};
}

/// The latest toast; an earlier one's animation leaves it alone.
var toast_gen: usize = 0;
/// The latest toast's callout at full strength, which each step fades.
var toast_picture: ?callout.Picture = null;
/// Each picture the renderer gets is a new generation.
var picture_gen: u64 = 0;

/// {"icon": "chrome", "text": "...", "strong": "...", "x": 120, "y": 40,
/// "ms": 2500}: shows a callout with the icon, text, then strong in bold,
/// for ms. It points at frame pixel (x, y), such as where a click opened a
/// link, from above it, or below near the top; without one it sits at the
/// bottom right. It fades in and out.
pub fn opToast(ctx: ?*anyopaque) void {
    const o: *Op = @ptrCast(@alignCast(ctx));
    const text = str(o.body, "text") orelse "";
    const strong = str(o.body, "strong") orelse "";
    if (text.len == 0 and strong.len == 0) return reply(o, 400, "text or strong is required");
    const icon: callout.Icon = if (str(o.body, "icon")) |name|
        std.meta.stringToEnum(callout.Icon, name) orelse return reply(o, 400, "icon is chrome or none")
    else
        .none;
    const ms: u64 = @intFromFloat(std.math.clamp(num(o.body, "ms") orelse 2500, 0, 60_000));
    const surface = &main.surface.core_surface;
    const size = surface.size;
    const grid = size.grid();
    // What it points at, from the grid's top left: the click and its row.
    const at: ?callout.At = if (num(o.body, "x")) |x| if (num(o.body, "y")) |y| at: {
        const cell_h: f64 = @floatFromInt(@max(1, size.cell.height));
        const gy = y - @as(f64, @floatFromInt(size.padding.top));
        const row = std.math.clamp(@floor(gy / cell_h), 0, @as(f64, @floatFromInt(grid.rows -| 1)));
        break :at .{ .x = x - @as(f64, @floatFromInt(size.padding.left)), .top = row * cell_h, .bottom = (row + 1) * cell_h };
    } else null else null;
    const background = background: {
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        const black: @TypeOf(surface.renderer_state.terminal.colors.background.get().?) = .{ .r = 0, .g = 0, .b = 0 };
        break :background surface.renderer_state.terminal.colors.background.get() orelse black;
    };
    const picture = callout.draw(surface.alloc, .{ .icon = icon, .text = text, .strong = strong, .at = at }, .{
        .width = @as(u32, grid.columns) * size.cell.width,
        .height = @as(u32, grid.rows) * size.cell.height,
        .cell_width = size.cell.width,
        .font_size = surface.font_size,
        .dark = @as(u32, background.r) * 299 + @as(u32, background.g) * 587 + @as(u32, background.b) * 114 < 128_000,
    }) catch |err| {
        log.err("error drawing a toast err={}", .{err});
        return reply(o, 500, "could not draw the toast");
    };
    if (toast_picture) |p| p.deinit(surface.alloc);
    toast_picture = picture;
    toast_gen += 1;
    if (std.Thread.spawn(.{}, animate, .{ toast_gen, ms })) |t| t.detach() else |_| show(toast_gen, fade_steps);
    reply(o, 200, null);
}

/// Frames to fade in, and out.
const fade_steps = 9;

/// Fades the callout in as it moves a little toward where it points from,
/// holds it, and fades it out.
fn animate(gen: usize, ms: u64) void {
    for (1..2 * fade_steps + 2) |k| {
        clock.sleepNs(if (k == fade_steps + 1) ms * std.time.ns_per_ms else 16 * std.time.ns_per_ms);
        loop.post(step, @ptrFromInt(gen << 16 | k));
    }
}

fn step(ctx: ?*anyopaque) void {
    const v = @intFromPtr(ctx);
    show(v >> 16, v & 0xffff);
}

/// Shows step k of the latest toast: fading in up to fade_steps, out after,
/// and gone past 2 × fade_steps.
fn show(gen: usize, k: usize) void {
    if (gen != toast_gen) return;
    const surface = &main.surface.core_surface;
    const full = toast_picture orelse return;
    var banner: ?renderer.State.Banner = null;
    if (k <= 2 * fade_steps) {
        const t = @as(f64, @floatFromInt(@min(k, 2 * fade_steps - k))) / fade_steps;
        const eased = 1 - std.math.pow(f64, 1 - @min(t, 1), 3);
        const alpha = if (k <= fade_steps) eased else t;
        const pixels = surface.alloc.dupe(u8, full.pixels) catch return;
        var i: usize = 3;
        while (i < pixels.len) : (i += 4) pixels[i] = @intFromFloat(@round(@as(f64, @floatFromInt(pixels[i])) * alpha));
        const slide: i64 = if (k < fade_steps) @intFromFloat(@round(6 * (1 - eased))) else 0;
        picture_gen += 1;
        banner = .{
            .pixels = pixels,
            .width = full.width,
            .height = full.height,
            .x = full.x,
            .y = @intCast(@max(0, @as(i64, full.y) + slide * full.rise)),
            .generation = picture_gen,
        };
    }
    {
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        if (surface.renderer_state.banner) |b| surface.alloc.free(b.pixels);
        surface.renderer_state.banner = banner;
    }
    surface.renderer_thread.wakeup.notify() catch {};
}

pub fn opQuit(ctx: ?*anyopaque) void {
    loop.stop();
    reply(@ptrCast(@alignCast(ctx)), 200, null);
}
