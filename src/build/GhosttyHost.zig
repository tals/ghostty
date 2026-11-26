//! What the headless apprt's executable, ghostty-host, needs beyond
//! Ghostty's own dependencies. See src/apprt/headless.
const std = @import("std");

pub fn add(b: *std.Build, step: *std.Build.Step.Compile) void {
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;
    if (target.result.os.tag.isDarwin()) {
        step.root_module.addCSourceFile(.{
            .file = b.path("src/apprt/headless/platform_macos.m"),
            .flags = &.{"-fobjc-arc"},
        });
        // The macOS app links these itself; libghostty leaves them to it.
        step.root_module.linkFramework("Foundation", .{});
        step.root_module.linkFramework("Metal", .{});
        return;
    }

    // glad's EGL loader, linked against a stand-in libEGL.so.1: the machine
    // it runs on supplies the real one.
    step.root_module.addCSourceFile(.{
        .file = b.path("vendor/glad/src/glad_egl.c"),
        .flags = &.{},
    });
    const egl = b.addLibrary(.{
        .name = "EGL",
        .linkage = .dynamic,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    egl.root_module.addCSourceFile(.{ .file = b.path("src/apprt/headless/egl_stub.c"), .flags = &.{} });
    // As a file, not linkLibrary, which would add its build folder as RUNPATH.
    step.root_module.addObjectFile(egl.getEmittedBin());
}
