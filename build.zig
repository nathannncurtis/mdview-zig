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
    var linux_c: ?*std.Build.Step.TranslateC = null;
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
        linux_c = c;
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

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/markdown.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run parser tests");
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    addTools(b, test_step);

    if (linux_c) |c| {
        const layout_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/linux.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        for ([_][]const u8{ "x11", "cairo", "pangocairo-1.0", "pango-1.0", "gobject-2.0" }) |lib| layout_tests.root_module.linkSystemLibrary(lib, .{});
        layout_tests.root_module.addImport("c", c.createModule());
        test_step.dependOn(&b.addRunArtifact(layout_tests).step);
    }

    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stress.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = &.{"stress files"},
    });
    const run_stress = b.addRunArtifact(stress_tests);
    if (b.option([]const u8, "stress-dir", "Directory of files from gen-stress for the stress step")) |dir| {
        run_stress.setEnvironmentVariable("MDVIEW_STRESS_DIR", dir);
    }
    if (b.option([]const u8, "stress-only", "Only parse stress files whose name contains this")) |only| {
        run_stress.setEnvironmentVariable("MDVIEW_STRESS_ONLY", only);
    }
    b.step("stress", "Parse the gen-stress files with time and memory limits (-Dstress-dir=<dir>)").dependOn(&run_stress.step);

    if (resolved.os.tag == .windows) {
        const hit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/win32.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        for ([_][]const u8{ "d2d1", "dwrite", "user32", "gdi32", "ole32", "shell32", "advapi32" }) |lib| {
            hit_tests.root_module.linkSystemLibrary(lib, .{});
        }
        test_step.dependOn(&b.addRunArtifact(hit_tests).step);
    }

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    test_step.dependOn(&run_fuzz.step);
    b.step("fuzz", "Fuzz the parser (zig build fuzz --fuzz=N)").dependOn(&run_fuzz.step);
}

fn toolExe(b: *std.Build, name: []const u8, file: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

fn toolStep(b: *std.Build, step_name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step(step_name, description).dependOn(&run.step);
    return run;
}

fn addTools(b: *std.Build, test_step: *std.Build.Step) void {
    const generators = [_]struct { step: []const u8, file: []const u8, what: []const u8 }{
        .{ .step = "gen-entities", .file = "tools/gen_entities.zig", .what = "Regenerate src/entities.zig: <entities.json> <out.zig>" },
        .{ .step = "gen-emoji", .file = "tools/gen_emoji.zig", .what = "Regenerate src/emoji.zig: <emoji.json> <out.zig>" },
        .{ .step = "gen-unicode", .file = "tools/gen_unicode.zig", .what = "Regenerate src/unicode.zig: <UnicodeData.txt> <out.zig>" },
        .{ .step = "gen-highlight-colors", .file = "tools/gen_highlight_colors.zig", .what = "Regenerate src/highlight_colors.zig: <primer-dark.json> <out.zig>" },
        .{ .step = "gen-spec-cases", .file = "tools/gen_spec_cases.zig", .what = "Regenerate src/spec_inline_cases.zig: <spec.txt> <out.zig>" },
        .{ .step = "gen-stress", .file = "tools/gen_stress.zig", .what = "Write adversarial Markdown files: <outdir> [small]" },
        .{ .step = "stress-app", .file = "tools/stress_app.zig", .what = "Run the built app on the gen-stress files: <mdview exe> <stress dir> <work dir> [options]" },
        .{ .step = "release-notes", .file = "tools/release_notes.zig", .what = "Write release notes: <tag> <out.md>" },
        .{ .step = "msix-assets", .file = "tools/make_assets.zig", .what = "Write the MSIX PNG assets from icon.ico into msix/Assets" },
        .{ .step = "pack-msix", .file = "tools/pack_msix.zig", .what = "Build the MSIX: <mdview.exe> <version> <output.msix> <work dir>" },
    };
    for (generators) |g| _ = toolStep(b, g.step, g.what, toolExe(b, g.step, g.file));

    const languages = toolExe(b, "gen-languages", "tools/gen_languages.zig");
    languages.root_module.addImport("yaml", b.createModule(.{
        .root_source_file = b.path("src/yaml.zig"),
        .target = b.graph.host,
    }));
    _ = toolStep(b, "gen-languages", "Regenerate src/languages.zig: <languages.yml> <out.zig>", languages);

    const growth = b.addRunArtifact(toolExe(b, "gen-growth", "tools/gen_growth.zig"));
    const growth_dir = growth.addOutputDirectoryArg("growth");
    for ([_][]const u8{ "packed_four_times", "packed_u32_restarts", "packed_u64_refs", "unicode_wide" }) |name| {
        const t = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = growth_dir.path(b, b.fmt("{s}.zig", .{name})),
                .target = b.graph.host,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
