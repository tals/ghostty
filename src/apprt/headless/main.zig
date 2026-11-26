//! ghostty-host: runs a command in a windowless Ghostty surface, takes
//! scripted keys and mouse input over HTTP on a Unix socket, reports the
//! pointer shape, and hands out every rendered frame's pixels.
//!
//!   ghostty-host (--dir DIR | --socket PATH) [--size COLSxROWS] [--font-size N] -- COMMAND ...
//!
//! See corgi/README.md for the API.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");
const cli = @import("../../cli.zig");
const CoreApp = @import("../../App.zig");
const Config = @import("../../config.zig").Config;
const headless = @import("../headless.zig");
const frames = @import("frames.zig");
const http = @import("http.zig");
const loop = @import("loop.zig");

const darwin = builtin.target.os.tag.isDarwin();

/// The dpi Ghostty turns points into pixels with at scale 1 (font.face.default_dpi).
const ghostty_dpi: f64 = if (darwin) 72 else 96;

pub const Options = struct {
    /// --socket, or DIR/ghostty.sock, or a /tmp fallback.
    socket_path: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    cols: u32 = 80,
    rows: u32 = 24,
    /// Points at 96 dpi, as Ghostty on Linux takes them.
    font_size: f64 = 0,
    scale: f64 = 1,
    fps: f64 = 60,
    /// --color convert (macOS); the default is passthrough.
    convert_p3: bool = false,
    /// --login: keep Ghostty's macOS login(1) wrapper.
    login: bool = false,
    cwd: ?[]const u8 = null,
    config_files: std.ArrayList([]const u8) = .empty,
    config_lines: std.ArrayList([]const u8) = .empty,
    command: []const [*:0]const u8 = &.{},
};

/// Frame size, padding and grid, fixed at startup.
pub const Geometry = struct {
    width: u32 = 0,
    height: u32 = 0,
    pad_top: u32 = 0,
    pad_bottom: u32 = 0,
    pad_left: u32 = 0,
    pad_right: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    cell_width: u32 = 0,
    cell_height: u32 = 0,
};

pub var opt: Options = .{};
pub var geo: Geometry = .{};
pub var surface: *headless.Surface = undefined;
/// From Ghostty's initial_size action, during surface init.
pub var initial_size: [2]u32 = .{ 0, 0 };
/// The command's, once it exits.
pub var exit_code: u8 = 0;

var socket_path_buf: [@sizeOf(@FieldType(std.c.sockaddr.un, "path"))]u8 = undefined;
/// DIR/socket, naming the socket in use.
var socket_file_buf: [4096]u8 = undefined;
var socket_file: ?[:0]const u8 = null;

var tty_buf: [64]u8 = undefined;
var tty_len: usize = 0;
var tty_known: std.atomic.Value(bool) = .init(false);

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ghostty-host: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print(
        \\usage: ghostty-host (--dir DIR | --socket PATH) [options] [-- COMMAND ...]
        \\  --dir DIR            serve on DIR/ghostty.sock, or /tmp/ghostty-host-PID.sock when
        \\                       that is too long; DIR/socket names the one in use
        \\  --socket PATH        serve on PATH
        \\  --size COLSxROWS     terminal grid; default 80x24
        \\  --font-size N        font size in points at 96 dpi, as Ghostty on Linux takes it
        \\  --scale S            backing scale; default 1 (frame pixels = points)
        \\  --config KEY=VALUE   a Ghostty config line; repeatable, applied last
        \\  --config-file PATH   a Ghostty config file; repeatable
        \\  --color MODE         macOS: passthrough (default): Ghostty skips its sRGB-to-P3
        \\                       step, so pixels are the configured sRGB colors
        \\                       convert: Ghostty's macOS pipeline, converted back to sRGB
        \\  --fps N              Ghostty's draw rate while the screen changes; default 60
        \\  --cwd DIR            working directory for the command
        \\  --login              macOS: run the command through login(1) as Ghostty.app does
        \\The host exits with the command's exit code when the command exits.
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(alloc: Allocator, argv: []const [*:0]const u8) !void {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        const next = struct {
            fn get(v: []const [*:0]const u8, j: *usize) []const u8 {
                j.* += 1;
                if (j.* >= v.len) usage();
                return std.mem.span(v[j.*]);
            }
        }.get;
        if (std.mem.eql(u8, a, "--")) {
            opt.command = argv[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--socket")) {
            opt.socket_path = next(argv, &i);
        } else if (std.mem.eql(u8, a, "--dir")) {
            opt.dir = next(argv, &i);
        } else if (std.mem.eql(u8, a, "--size")) {
            const v = next(argv, &i);
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse usage();
            opt.cols = std.fmt.parseInt(u32, v[0..x], 10) catch usage();
            opt.rows = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch usage();
            if (opt.cols < 1 or opt.rows < 1) usage();
        } else if (std.mem.eql(u8, a, "--font-size")) {
            opt.font_size = std.fmt.parseFloat(f64, next(argv, &i)) catch usage();
        } else if (std.mem.eql(u8, a, "--scale")) {
            opt.scale = std.fmt.parseFloat(f64, next(argv, &i)) catch usage();
        } else if (std.mem.eql(u8, a, "--config")) {
            try opt.config_lines.append(alloc, next(argv, &i));
        } else if (std.mem.eql(u8, a, "--config-file")) {
            try opt.config_files.append(alloc, next(argv, &i));
        } else if (std.mem.eql(u8, a, "--color")) {
            const m = next(argv, &i);
            if (std.mem.eql(u8, m, "convert")) opt.convert_p3 = true else if (std.mem.eql(u8, m, "passthrough")) opt.convert_p3 = false else usage();
        } else if (std.mem.eql(u8, a, "--fps")) {
            opt.fps = std.fmt.parseFloat(f64, next(argv, &i)) catch usage();
            if (opt.fps < 1 or opt.fps > 1000) usage();
        } else if (std.mem.eql(u8, a, "--cwd")) {
            opt.cwd = next(argv, &i);
        } else if (std.mem.eql(u8, a, "--login")) {
            opt.login = true;
        } else usage();
    }
    if ((opt.socket_path == null) == (opt.dir == null) or opt.scale < 1) usage();
    if (!darwin) {
        if (opt.convert_p3) std.debug.print("ghostty-host: --color convert is for macOS; frames are sRGB here\n", .{});
        if (opt.login) std.debug.print("ghostty-host: --login is for macOS; Ghostty never uses login(1) here\n", .{});
        opt.convert_p3 = false;
        opt.login = false;
    }
}

/// Unix socket paths are limited to 104 bytes on macOS, 108 on Linux.
fn chooseSocket() void {
    if (opt.socket_path) |p| {
        if (p.len >= socket_path_buf.len) die("socket path is over {d} bytes: {s}", .{ socket_path_buf.len - 1, p });
        return;
    }
    const dir = opt.dir.?;
    std.Io.Dir.cwd().createDirPath(global.io(), dir) catch die("cannot create {s}", .{dir});
    opt.socket_path = std.fmt.bufPrint(&socket_path_buf, "{s}/ghostty.sock", .{dir}) catch
        std.fmt.bufPrint(&socket_path_buf, "/tmp/ghostty-host-{d}.sock", .{std.c.getpid()}) catch unreachable;
    if (opt.socket_path.?.len >= socket_path_buf.len)
        opt.socket_path = std.fmt.bufPrint(&socket_path_buf, "/tmp/ghostty-host-{d}.sock", .{std.c.getpid()}) catch unreachable;
    socket_file = std.fmt.bufPrintSentinel(&socket_file_buf, "{s}/socket", .{dir}, 0) catch die("directory path too long: {s}", .{dir});
}

/// Written once the socket listens, as ghostty-capture does.
fn writeSocketFile() void {
    const path = socket_file orelse return;
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}\n", .{opt.socket_path.?}) catch unreachable;
    std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = path, .data = text }) catch die("cannot write {s}", .{path});
}

fn cleanup() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&buf, "{s}", .{opt.socket_path orelse return}, 0)) |p| _ = std.c.unlink(p) else |_| {}
    if (socket_file) |p| _ = std.c.unlink(p);
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    cleanup();
    std.c._exit(0);
}

/// Shells ignore SIGINT in background jobs; leave ignored signals ignored.
fn installSignals() void {
    const p = std.posix;
    for ([_]p.SIG{ p.SIG.INT, p.SIG.TERM, p.SIG.HUP }) |sig| {
        var old: p.Sigaction = undefined;
        p.sigaction(sig, null, &old);
        if (old.handler.handler != p.SIG.DFL) continue;
        const sa: p.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = p.sigemptyset(), .flags = 0 };
        p.sigaction(sig, &sa, null);
    }
}

/// Ghostty's resources (themes, shell integration, and terminfo beside
/// them) in share/ghostty next to the executable, as a release packs them.
fn bundledResources(buf: *[std.fs.max_path_bytes]u8) ?[:0]const u8 {
    // global.init isn't up yet.
    const io = std.Io.Threaded.global_single_threaded.io();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &exe_buf) catch return null;
    const path = std.fmt.bufPrintSentinel(buf, "{s}/share/ghostty", .{exe_buf[0..n]}, 0) catch return null;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return null;
    dir.close(io);
    return path;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// A parent Ghostty leaks GHOSTTY_RESOURCES_DIR (pointing into its own app
/// bundle) and shell-integration variables. Ghostty snapshots the
/// environment in global.init, so clean it first.
fn cleanEnvironment() void {
    var again = true;
    while (again) {
        again = false;
        var e: [*:null]?[*:0]u8 = std.c.environ;
        while (e[0]) |entry| : (e += 1) {
            const s = std.mem.span(entry);
            if (!std.mem.startsWith(u8, s, "GHOSTTY_") or std.mem.startsWith(u8, s, "GHOSTTY_LOG=")) continue;
            var name: [256]u8 = undefined;
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse s.len;
            const z = std.fmt.bufPrintSentinel(&name, "{s}", .{s[0..eq]}, 0) catch continue;
            _ = unsetenv(z);
            again = true;
            break;
        }
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (bundledResources(&buf)) |dir| _ = setenv("GHOSTTY_RESOURCES_DIR", dir, 1);

    // std.debug's Io took the environment's length at startup, and unsetenv
    // shifted the entries under it; point it at the cleaned environment.
    var len: usize = 0;
    while (std.c.environ[len]) |_| : (len += 1) {}
    if (std.Options.debug_threaded_io) |t| {
        t.environ = .{ .process_environ = .{ .block = .{ .slice = std.c.environ[0..len :null] } } };
        t.environ_initialized = false;
    }
}

/// Joins argv into one /bin/sh command line, each word single-quoted.
fn shellJoin(alloc: Allocator, prefix: []const u8, words: []const [*:0]const u8) ![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(prefix);
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeByte('\'');
        for (std.mem.span(word)) |c| {
            if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
        }
        try w.writeByte('\'');
    }
    return try out.toOwnedSliceSentinel(0);
}

fn loadConfigText(config: *Config, alloc: Allocator, text: []const u8) !void {
    var reader: std.Io.Reader = .fixed(text);
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = "ghostty-host" };
    try config.loadIter(alloc, &iter);
}

/// window-padding-x/y as given with --config: "N" or "LEFT,RIGHT".
fn configPadding(key: []const u8, a: *u32, b: *u32) void {
    for (opt.config_lines.items) |line| {
        if (line.len <= key.len or !std.mem.startsWith(u8, line, key) or line[key.len] != '=') continue;
        var it = std.mem.splitScalar(u8, line[key.len + 1 ..], ',');
        const x = std.fmt.parseInt(u32, std.mem.trim(u8, it.next() orelse continue, " "), 10) catch continue;
        a.* = x;
        b.* = x;
        if (it.next()) |y| b.* = std.fmt.parseInt(u32, std.mem.trim(u8, y, " "), 10) catch x;
    }
}

fn buildConfig(alloc: Allocator) !Config {
    var config = try Config.default(alloc);
    errdefer config.deinit();
    var base: std.Io.Writer.Allocating = .init(alloc);
    defer base.deinit();
    const w = &base.writer;
    try w.print("window-width = {d}\nwindow-height = {d}\n", .{ opt.cols, opt.rows });
    // --font-size is points at 96 dpi everywhere, so the same size gives the
    // same cells; Ghostty on macOS takes them at 72 dpi.
    if (opt.font_size > 0) try w.print("font-size = {d}\n", .{opt.font_size * 96.0 / ghostty_dpi});
    // Ghostty converts sRGB colors to Display P3 in its shaders unless told
    // the colors already are P3. Then the target's bytes are the configured
    // values.
    if (darwin and !opt.convert_p3) try w.writeAll("window-colorspace = display-p3\n");
    // No display link: the renderer draws on updates, paced at --fps.
    try w.writeAll("window-vsync = false\n");
    try loadConfigText(&config, alloc, base.written());
    for (opt.config_files.items) |file| {
        const cwd = try std.process.currentPathAlloc(global.io(), alloc);
        defer alloc.free(cwd);
        const path = try std.fs.path.resolveAlloc(alloc, &.{ cwd, file });
        defer alloc.free(path);
        config.loadFile(alloc, path) catch |err| std.debug.print("ghostty-host: config file {s}: {}\n", .{ path, err });
    }
    if (opt.config_lines.items.len > 0) {
        var text: std.Io.Writer.Allocating = .init(alloc);
        defer text.deinit();
        for (opt.config_lines.items) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse die("--config wants KEY=VALUE, got {s}", .{line});
            try text.writer.print("{s} = {s}\n", .{ line[0..eq], line[eq + 1 ..] });
        }
        try loadConfigText(&config, alloc, text.written());
    }
    try config.finalize();
    for (config._diagnostics.items()) |*diag|
        std.debug.print("ghostty-host: config: {f}\n", .{diag});
    return config;
}

/// The pty opens after the surface does; note its name once known.
pub fn learnTty() void {
    if (tty_known.load(.acquire)) return;
    const name = surface.core_surface.getProcessInfo(.tty_name) orelse return;
    tty_len = @min(name.len, tty_buf.len);
    @memcpy(tty_buf[0..tty_len], name[0..tty_len]);
    tty_known.store(true, .release);
}

/// The pty's name, or "" before it is known.
pub fn tty() []const u8 {
    return if (tty_known.load(.acquire)) tty_buf[0..tty_len] else "";
}

extern "c" fn IOSurfaceLock(buffer: *anyopaque, options: u32, seed: ?*u32) c_int;
extern "c" fn IOSurfaceUnlock(buffer: *anyopaque, options: u32, seed: ?*u32) c_int;
extern "c" fn IOSurfaceGetID(buffer: *anyopaque) u32;
extern "c" fn ghostty_host_iosurface_colorspace(surface: *anyopaque, out: [*]u8, len: usize) void;
extern "c" fn ghostty_host_begin_activity() void;
extern "c" fn ghostty_host_windows_json(pid: c_int, out: [*]u8, len: usize) void;

/// Ghostty keeps three surfaces; name each one's color space once.
var seen: [8]struct { id: u32 = 0, name: [64]u8 = undefined, len: usize = 0 } = @splat(.{});
var seen_next: usize = 0;
/// Metal may complete frames on more than one thread; take them in turn.
var present_mutex: std.Io.Mutex = .init;

/// The Metal renderer's finished frame, read on its completion handler
/// while the IOSurface is locked, before the renderer can reuse it.
pub fn presentIOSurface(io_surface: anytype) void {
    present_mutex.lockUncancelable(global.io());
    defer present_mutex.unlock(global.io());
    const ptr: *anyopaque = @ptrCast(io_surface);
    const start = @import("clock.zig").monoNs();
    if (IOSurfaceLock(ptr, 1, null) != 0) return; // kIOSurfaceLockReadOnly
    defer _ = IOSurfaceUnlock(ptr, 1, null);
    const id = IOSurfaceGetID(ptr);
    const i = for (seen, 0..) |s, i| {
        if (s.id == id) break i;
    } else i: {
        const i = seen_next % seen.len;
        seen_next += 1;
        seen[i].id = id;
        ghostty_host_iosurface_colorspace(ptr, &seen[i].name, seen[i].name.len);
        seen[i].len = std.mem.indexOfScalar(u8, &seen[i].name, 0) orelse seen[i].name.len;
        break :i i;
    };
    frames.onPresent(.{
        .pixels = io_surface.getBaseAddress() orelse return,
        .stride = io_surface.getBytesPerRow(),
        .width = @intCast(io_surface.getWidth()),
        .height = @intCast(io_surface.getHeight()),
        .bgra = true,
        .bottom_up = false,
        .gpu_readback_ns = @import("clock.zig").monoNs() - start, // the lock
        .colorspace = seen[i].name[0..seen[i].len],
    });
}

/// Windows the window server knows for this process, for /status.
pub fn windowsJson(buf: []u8) []const u8 {
    if (comptime !darwin) return "";
    ghostty_host_windows_json(std.c.getpid(), buf.ptr, buf.len);
    return std.mem.sliceTo(buf, 0);
}

pub fn main(minimal: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    const arena = arena_state.allocator();
    try parseArgs(arena, minimal.args.vector);
    cleanEnvironment();

    // Initialize as the C API does: with this program's name only, so
    // Ghostty reads no CLI actions or config from our arguments, and with
    // the cleaned environment.
    var argv0 = [_][*:0]u8{@constCast(minimal.args.vector[0])};
    var env_len: usize = 0;
    while (std.c.environ[env_len]) |_| : (env_len += 1) {}
    try global.init(.{ .c = .{
        .argc = 1,
        .argv = &argv0,
        .environ = .{ .block = .{ .slice = std.c.environ[0..env_len :null] } },
    } });
    defer global.deinit();
    const alloc = global.alloc();

    chooseSocket();
    installSignals();
    if (darwin) ghostty_host_begin_activity();

    var config = try buildConfig(alloc);
    defer config.deinit();

    const core_app = try CoreApp.create(alloc);
    defer core_app.destroy();
    var app: headless.App = undefined;
    try app.init(core_app, &config);
    defer app.terminate();
    core_app.focusEvent(true);
    try frames.start(opt.convert_p3);

    const command: ?[:0]const u8 = if (opt.command.len > 0) try shellJoin(arena, "exec ", opt.command) else null;
    const s = try alloc.create(headless.Surface);
    try s.init(&app, .{
        .scale = opt.scale,
        .fps = opt.fps,
        .working_directory = opt.cwd,
        .command = command,
    });
    surface = s;

    // window-width/height make Ghostty report the window size for the grid
    // (Surface.recomputeInitialSize): ceil(cells / scale) + padding in pixels.
    // Undo the scale on the cells to get the framebuffer size.
    const size = &s.core_surface.size;
    const cw = size.cell.width;
    const ch = size.cell.height;
    if (initial_size[0] == 0 or cw == 0) die("Ghostty reported no initial size", .{});
    const cells_w: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(opt.cols * cw)) / opt.scale));
    const cells_h: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(opt.rows * ch)) / opt.scale));
    const pad_w = initial_size[0] - cells_w;
    const pad_h = initial_size[1] - cells_h;
    geo.width = opt.cols * cw + pad_w;
    geo.height = opt.rows * ch + pad_h;
    // Ghostty's default padding is 2 points per side; --config can change it.
    var px = [2]u32{ 2, 2 };
    var py = [2]u32{ 2, 2 };
    configPadding("window-padding-x", &px[0], &px[1]);
    configPadding("window-padding-y", &py[0], &py[1]);
    const pt = opt.scale * ghostty_dpi / 72;
    geo.pad_left = @intFromFloat(@floor(@as(f64, @floatFromInt(px[0])) * pt));
    geo.pad_right = @intFromFloat(@floor(@as(f64, @floatFromInt(px[1])) * pt));
    geo.pad_top = @intFromFloat(@floor(@as(f64, @floatFromInt(py[0])) * pt));
    geo.pad_bottom = @intFromFloat(@floor(@as(f64, @floatFromInt(py[1])) * pt));
    if (geo.pad_left + geo.pad_right != pad_w) {
        geo.pad_left = pad_w / 2;
        geo.pad_right = pad_w - pad_w / 2;
    }
    if (geo.pad_top + geo.pad_bottom != pad_h) {
        geo.pad_top = pad_h / 2;
        geo.pad_bottom = pad_h - pad_h / 2;
    }
    s.updateSize(geo.width, geo.height);
    s.core_surface.focusCallback(true) catch {};

    const grid = s.core_surface.size.grid();
    geo.columns = grid.columns;
    geo.rows = grid.rows;
    geo.cell_width = s.core_surface.size.cell.width;
    geo.cell_height = s.core_surface.size.cell.height;
    learnTty();
    if (grid.columns != opt.cols or grid.rows != opt.rows)
        std.debug.print("ghostty-host: asked for {d}x{d} cells, Ghostty made {d}x{d}\n", .{ opt.cols, opt.rows, grid.columns, grid.rows });

    try http.start(opt.socket_path.?);
    writeSocketFile();
    {
        var buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(global.io(), &buf);
        try stdout.interface.print(
            "{{\"ready\":true,\"socket\":{f},\"pid\":{d},\"width\":{d},\"height\":{d},\"columns\":{d},\"rows\":{d}," ++
                "\"cell_width\":{d},\"cell_height\":{d}}}\n",
            .{ std.json.fmt(opt.socket_path.?, .{}), std.c.getpid(), geo.width, geo.height, geo.columns, geo.rows, geo.cell_width, geo.cell_height },
        );
        try stdout.interface.flush();
    }

    loop.run();
    cleanup();
    s.deinit();
    alloc.destroy(s);
    std.process.exit(exit_code);
}
