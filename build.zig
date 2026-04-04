const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const resolved = target.result;
    if (resolved.os.tag == .windows) {
        exe_mod.linkSystemLibrary("d2d1", .{});
        exe_mod.linkSystemLibrary("dwrite", .{});
        exe_mod.linkSystemLibrary("user32", .{});
        exe_mod.linkSystemLibrary("gdi32", .{});
        exe_mod.linkSystemLibrary("ole32", .{});
        exe_mod.linkSystemLibrary("shell32", .{});
        exe_mod.linkSystemLibrary("advapi32", .{});
    } else if (resolved.os.tag == .linux) {
        exe_mod.linkSystemLibrary("x11", .{});
        exe_mod.linkSystemLibrary("cairo", .{});
        exe_mod.linkSystemLibrary("pangocairo-1.0", .{});
        exe_mod.linkSystemLibrary("pango-1.0", .{});
        exe_mod.linkSystemLibrary("gobject-2.0", .{});
    } else if (resolved.os.tag == .macos) {
        exe_mod.linkFramework("Cocoa", .{});
        exe_mod.linkFramework("CoreText", .{});
        exe_mod.linkFramework("CoreGraphics", .{});
        exe_mod.linkFramework("CoreFoundation", .{});
    }

    const exe = b.addExecutable(.{
        .name = "mdview",
        .root_module = exe_mod,
    });

    if (resolved.os.tag == .windows) {
        exe.subsystem = .Windows;
        exe.addWin32ResourceFile(.{ .file = b.path("icon.rc") });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
