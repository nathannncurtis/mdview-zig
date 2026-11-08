const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const testdata = b.createModule(.{ .root_source_file = b.path("testdata/embed.zig") });

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
            .root_source_file = b.path("src/platform/linux/linux_c.h"),
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
            .root_source_file = b.path("src/platform/macos/macos_c.h"),
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
            .root_source_file = b.path("src/markdown_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parser_tests.root_module.addImport("testdata", testdata);
    const test_step = b.step("test", "Run parser tests");
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    const dagre_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mermaid/dagre_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dagre_tests.root_module.addImport("testdata", testdata);
    test_step.dependOn(&b.addRunArtifact(dagre_tests).step);
    const elk_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mermaid/elk/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(elk_tests).step);
    addTools(b, test_step, testdata);

    if (linux_c) |c| {
        const layout_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        for ([_][]const u8{ "x11", "cairo", "pangocairo-1.0", "pango-1.0", "gobject-2.0" }) |lib| layout_tests.root_module.linkSystemLibrary(lib, .{});
        layout_tests.root_module.addImport("c", c.createModule());
        layout_tests.root_module.addImport("testdata", testdata);
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
    stress_tests.root_module.addImport("testdata", testdata);
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
                .root_source_file = b.path("src/platform_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        for ([_][]const u8{ "d2d1", "dwrite", "user32", "gdi32", "ole32", "shell32", "advapi32" }) |lib| {
            hit_tests.root_module.linkSystemLibrary(lib, .{});
        }
        hit_tests.root_module.addImport("testdata", testdata);
        test_step.dependOn(&b.addRunArtifact(hit_tests).step);
    }

    const fuzz_filter = b.option([]const u8, "fuzz-filter", "Run only the fuzz tests whose name contains this");
    const fuzz_tests = b.addTest(.{
        .filters = if (fuzz_filter) |f| b.dupeStrings(&.{f}) else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_tests.root_module.addImport("testdata", testdata);
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    test_step.dependOn(&run_fuzz.step);
    b.step("fuzz", "Fuzz the parser (zig build fuzz --fuzz=N)").dependOn(&run_fuzz.step);
}

fn toolExe(b: *std.Build, name: []const u8, file: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    exe.root_module.addImport("files", b.createModule(.{
        .root_source_file = b.path("tools/files.zig"),
        .target = b.graph.host,
    }));
    return exe;
}

fn toolStep(b: *std.Build, step_name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step(step_name, description).dependOn(&run.step);
    return run;
}

fn addTools(b: *std.Build, test_step: *std.Build.Step, testdata: *std.Build.Module) void {
    const generators = [_]struct { step: []const u8, file: []const u8, what: []const u8 }{
        .{ .step = "gen-entities", .file = "tools/gen/gen_entities.zig", .what = "Regenerate src/data/entities.zig: <entities.json> <out.zig>" },
        .{ .step = "gen-emoji", .file = "tools/gen/gen_emoji.zig", .what = "Regenerate src/data/emoji.zig: <emoji.json> <out.zig>" },
        .{ .step = "gen-unicode", .file = "tools/gen/gen_unicode.zig", .what = "Regenerate src/data/unicode.zig: <UnicodeData.txt> <out.zig>" },
        .{ .step = "gen-highlight-colors", .file = "tools/gen/gen_highlight_colors.zig", .what = "Regenerate src/data/highlight_colors.zig: <primer-dark.json> <out.zig>" },
        .{ .step = "gen-spec-cases", .file = "tools/gen/gen_spec_cases.zig", .what = "Regenerate src/markdown/spec_inline_cases.zig: <spec.txt> <out.zig>" },
        .{ .step = "gen-stress", .file = "tools/gen/gen_stress.zig", .what = "Write adversarial Markdown files: <outdir> [small]" },
        .{ .step = "stress-app", .file = "tools/check/stress_app.zig", .what = "Run the built app on the gen-stress files: <mdview exe> <stress dir> <work dir> [options]" },
        .{ .step = "release-notes", .file = "tools/release/release_notes.zig", .what = "Write release notes: <tag> <out.md>" },
        .{ .step = "msix-assets", .file = "tools/release/make_assets.zig", .what = "Write the MSIX PNG assets from icon.ico into msix/Assets" },
        .{ .step = "pack-msix", .file = "tools/release/pack_msix.zig", .what = "Build the MSIX: <mdview.exe> <version> <output.msix> <work dir>" },
    };
    for (generators) |g| _ = toolStep(b, g.step, g.what, toolExe(b, g.step, g.file));

    const jison_runtime = b.createModule(.{
        .root_source_file = b.path("src/mermaid/jison/runtime.zig"),
        .target = b.graph.host,
    });
    const jison = toolExe(b, "gen-jison", "tools/gen/gen_jison.zig");
    jison.root_module.addImport("jison_runtime", jison_runtime);
    _ = toolStep(b, "gen-jison", "Generate jison tables: <grammar.jison> <out.zig> [stub=<stub.zig>] [json=<tables.json>], or check <grammar.jison> <jison-tables.json>", jison);
    addJisonTests(b, test_step, jison, jison_runtime, testdata);

    const languages = toolExe(b, "gen-languages", "tools/gen/gen_languages.zig");
    languages.root_module.addImport("yaml", b.createModule(.{
        .root_source_file = b.path("src/yaml_api.zig"),
        .target = b.graph.host,
    }));
    _ = toolStep(b, "gen-languages", "Regenerate src/data/languages.zig: <languages.yml> <out.zig>", languages);

    const growth = b.addRunArtifact(toolExe(b, "gen-growth", "tools/gen/gen_growth.zig"));
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

fn addJisonTests(b: *std.Build, test_step: *std.Build.Step, gen: *std.Build.Step.Compile, runtime: *std.Build.Module, testdata: *std.Build.Module) void {
    const dir = "testdata/mermaid/jison/";
    for ([_][]const u8{ "flow", "sequenceDiagram", "expr", "dangling" }) |name| {
        const check = b.addRunArtifact(gen);
        check.addArg("check");
        check.addFileArg(b.path(b.fmt("{s}{s}.jison", .{ dir, name })));
        check.addFileArg(b.path(b.fmt("{s}{s}.tables.json", .{ dir, name })));
        test_step.dependOn(&check.step);
    }

    const all_dir = "testdata/mermaid/jison/";
    for ([_][]const u8{ "agentflow", "block", "c4Diagram", "classDiagram", "erDiagram", "exampleDiagram", "gantt", "ishikawa", "journey", "kanban", "mindmap", "quadrant", "requirementDiagram", "sankey", "stateDiagram", "timeline", "venn", "xychart" }) |name| {
        const check = b.addRunArtifact(gen);
        check.addArg("check");
        check.addFileArg(b.path(b.fmt("{s}{s}.jison", .{ all_dir, name })));
        check.addFileArg(b.path(b.fmt("{s}{s}.tables.json", .{ all_dir, name })));
        test_step.dependOn(&check.step);
    }

    const regex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mermaid/jison/regex.zig"),
            .target = b.graph.host,
        }),
    });
    regex_tests.root_module.addImport("testdata", testdata);
    test_step.dependOn(&b.addRunArtifact(regex_tests).step);

    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mermaid/jison/runtime.zig"),
            .target = b.graph.host,
        }),
    });
    runtime_tests.root_module.addImport("testdata", testdata);
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);

    const parity = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mermaid/jison/parity_test.zig"),
            .target = b.graph.host,
        }),
    });
    parity.root_module.addImport("jison_runtime", runtime);
    parity.root_module.addImport("testdata", testdata);
    for ([_]struct { name: []const u8, prefix: []const u8 }{
        .{ .name = "flow", .prefix = "flow" },
        .{ .name = "sequenceDiagram", .prefix = "seq" },
    }) |g| {
        const run = b.addRunArtifact(gen);
        run.addFileArg(b.path(b.fmt("{s}{s}.jison", .{ dir, g.name })));
        const grammar = run.addOutputFileArg(b.fmt("{s}_grammar.zig", .{g.prefix}));
        const stub = run.addPrefixedOutputFileArg("stub=", b.fmt("{s}_stub.zig", .{g.prefix}));
        const grammar_module = b.createModule(.{ .root_source_file = grammar });
        const stub_module = b.createModule(.{ .root_source_file = stub });
        stub_module.addImport("jison_runtime", runtime);
        stub_module.addImport("grammar", grammar_module);
        parity.root_module.addImport(b.fmt("{s}_grammar", .{g.prefix}), grammar_module);
        parity.root_module.addImport(b.fmt("{s}_stub", .{g.prefix}), stub_module);
    }
    test_step.dependOn(&b.addRunArtifact(parity).step);
}
