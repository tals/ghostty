//! A windowless apprt for ghostty-host: one surface whose frames go to the
//! host's HTTP API instead of a window. See headless/main.zig.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const macos = @import("macos");
const frames = @import("headless/frames.zig");
const loop = @import("headless/loop.zig");
const shape = @import("headless/shape.zig");
const host = @import("headless/main.zig");

const log = std.log.scoped(.headless);

pub const resourcesDir = internal_os.resourcesDir;
pub const main = host.main;

/// The passwd entry termio's macOS login(1) wrapper reads. Without a user
/// name, Exec.zig runs `/bin/sh -c CMD` as on Linux; --login keeps it.
pub const passwd = struct {
    pub fn get(alloc: Allocator) !internal_os.passwd.Entry {
        var entry = try internal_os.passwd.get(alloc);
        if (!host.opt.login) entry.name = null;
        return entry;
    }
};

pub const App = struct {
    core_app: *CoreApp,
    config: Config,
    /// The keyboard layout, loaded on first use (TIS on macOS is slow to start).
    keymap: ?input.Keymap = null,
    tick_pending: std.atomic.Value(bool) = .init(false),

    pub fn init(self: *App, core_app: *CoreApp, config: *const Config) !void {
        self.* = .{ .core_app = core_app, .config = try config.clone(core_app.alloc) };
    }

    pub fn terminate(self: *App) void {
        if (self.keymap) |*v| v.deinit();
        self.config.deinit();
    }

    /// Any thread. Ticks on the main thread, as Ghostty.App.swift does.
    pub fn wakeup(self: *App) void {
        if (!self.tick_pending.swap(true, .acq_rel)) loop.post(tick, self);
    }

    fn tick(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.tick_pending.store(false, .release);
        self.core_app.tick(self) catch |err| log.err("error app tick err={}", .{err});
        host.learnTty();
    }

    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        if (comptime builtin.target.os.tag != .macos) return .unknown;
        if (self.keymap == null) self.keymap = input.Keymap.init() catch |err| {
            log.warn("error initializing keymap err={}", .{err});
            return .unknown;
        };
        var buf: [256]u8 = undefined;
        const id = self.keymap.?.sourceId(&buf) catch return .unknown;
        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .mouse_shape => shape.record(value, null),
            .mouse_visibility => shape.record(null, value == .visible),
            .initial_size => host.initial_size = .{ value.width, value.height },
            .render => if (comptime renderer.Renderer.ExportedFrame != void) {
                const surface = switch (target) {
                    .surface => |s| s,
                    .app => return true,
                };
                presentExported(surface);
            },
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeSentinel(u8, value.title, 0) catch null;
                },
            },
            .show_child_exited => {
                // Handled: Ghostty would otherwise print its own exit banner.
                // The host goes when its command does, as a window closes.
                host.exit_code = @truncate(value.exit_code);
                std.debug.print("ghostty-host: command exited with code {d}\n", .{value.exit_code});
                loop.stop();
            },
            else => return false,
        }
        return true;
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || apprt.ipc.Errors)!bool {
        return false;
    }

    pub fn redrawInspector(_: *App, _: *Surface) void {}
};

/// The renderer's frame in CPU memory (Linux), handed to the frame worker,
/// which frees it.
fn presentExported(core: *CoreSurface) void {
    const Exported = renderer.Renderer.ExportedFrame;
    const frame = core.renderer.takeFrame() orelse return;
    const memory = switch (frame) {
        .memory => |v| v,
        else => return frame.deinit(),
    };
    const owned = global.alloc().create(Exported) catch return frame.deinit();
    owned.* = frame;
    frames.onPresent(.{
        .pixels = memory.pixels.ptr,
        .stride = @as(usize, memory.width) * 4,
        .width = memory.width,
        .height = memory.height,
        .bgra = false,
        .bottom_up = true,
        .gpu_readback_ns = memory.readback_ns,
        .colorspace = "sRGB",
        .release = .{ .func = freeExported, .ctx = owned },
    });
}

fn freeExported(ctx: ?*anyopaque) void {
    const frame: *renderer.Renderer.ExportedFrame = @ptrCast(@alignCast(ctx));
    frame.deinit();
    global.alloc().destroy(frame);
}

pub const Surface = struct {
    app: *App,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
    title: ?[:0]const u8 = null,
    /// Minimum time between frames for the renderer thread, in nanoseconds.
    frame_interval_ns: u64,

    pub const Options = struct {
        scale: f64,
        fps: f64,
        working_directory: ?[]const u8,
        /// Run with /bin/sh -c (with --login, inside login and bash).
        command: ?[:0]const u8,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .core_surface = undefined,
            .content_scale = .{ .x = @floatCast(opts.scale), .y = @floatCast(opts.scale) },
            // The macOS app's view starts at 800x600 points until it is laid out.
            .size = .{ .width = 800, .height = 600 },
            .frame_interval_ns = @intFromFloat(std.time.ns_per_s / opts.fps),
        };

        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
        defer config.deinit();
        if (opts.working_directory) |wd| {
            var value: configpkg.WorkingDirectory = .{ .path = wd };
            value.finalize(config.arenaAlloc()) catch |err| {
                log.warn("error finalizing working directory dir={s} err={}", .{ wd, err });
            };
            config.@"working-directory" = value;
        }
        if (opts.command) |cmd| {
            config.command = .{ .shell = cmd };
            config.@"wait-after-command" = true;
        }

        // The renderer starts with presentation unhealthy for this apprt
        // (renderer/generic.zig), so every frame comes in CPU memory.
        try self.core_surface.init(app.core_app.alloc, &config, app.core_app, app, self);
    }

    pub fn deinit(self: *Surface) void {
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(_: *const Surface, _: bool) void {}

    pub fn frameInterval(self: *const Surface) u64 {
        return self.frame_interval_ns;
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    /// No clipboard: reads are refused and writes dropped.
    pub fn supportsClipboard(_: *const Surface, _: apprt.Clipboard) bool {
        return false;
    }

    pub fn clipboardRequest(_: *Surface, _: apprt.Clipboard, _: apprt.ClipboardRequest) !apprt.ClipboardReadResult {
        return .unavailable;
    }

    pub fn setClipboard(_: *const Surface, _: apprt.Clipboard, _: []const apprt.ClipboardContent, _: bool) !void {}

    pub fn defaultTermioEnv(_: *const Surface) !std.process.Environ.Map {
        return try global.environMap();
    }

    pub fn renderDeviceOptions(_: *const Surface) !renderer.Device.Options {
        return .{};
    }

    /// Sets the surface size in pixels, as a window's resize does.
    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        if (self.size.width == width and self.size.height == height) return;
        self.size = .{ .width = width, .height = height };
        self.core_surface.sizeCallback(self.size) catch |err| log.err("error in size callback err={}", .{err});
    }

    /// Moves the pointer, in frame pixels. Moves under a pixel are dropped,
    /// as the macOS app drops phantom ones.
    pub fn cursorPos(self: *Surface, x: f64, y: f64, mods: input.Mods) void {
        const pos: apprt.CursorPos = .{ .x = @floatCast(x), .y = @floatCast(y) };
        if (@abs(self.cursor_pos.x - pos.x) < 1 and @abs(self.cursor_pos.y - pos.y) < 1) return;
        self.cursor_pos = pos;
        self.core_surface.cursorPosCallback(pos, mods) catch |err| log.err("error in cursor pos callback err={}", .{err});
    }

    /// The Metal renderer's finished frame (macOS), on its completion thread.
    /// The IOSurface is read while it is locked, then handed back.
    pub fn presentIOSurface(_: *Surface, surface: *macos.iosurface.IOSurface) void {
        host.presentIOSurface(surface);
    }
};
