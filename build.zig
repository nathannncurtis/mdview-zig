const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.linkSystemLibrary("d2d1", .{});
    exe_mod.linkSystemLibrary("dwrite", .{});
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("ole32", .{});

    const exe = b.addExecutable(.{
        .name = "mdview",
        .root_module = exe_mod,
    });
    exe.subsystem = .Windows;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
