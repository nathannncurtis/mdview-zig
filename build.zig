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
        const c = b.addTranslateC(.{
            .root_source_file = b.path("src/linux_c.h"),
            .target = target,
            .optimize = optimize,
        });
        for ([_][]const u8{ "x11", "cairo", "pangocairo-1.0", "pango-1.0", "gobject-2.0" }) |lib| {
            c.linkSystemLibrary(lib, .{});
            exe_mod.linkSystemLibrary(lib, .{});
        }
        exe_mod.addImport("c", c.createModule());
    } else if (resolved.os.tag == .macos) {
        const c = b.addTranslateC(.{
            .root_source_file = b.path("src/macos_c.h"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("c", c.createModule());
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
        exe.subsystem = .windows;
        exe_mod.addWin32ResourceFile(.{ .file = b.path("icon.rc") });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
