const std = @import("std");
const model = @import("../render/model.zig");
const db_mod = @import("db.zig");
const parse_mod = @import("parse.zig");
const render = @import("render.zig");
const styles = @import("styles.zig");
const rt = @import("../jison/runtime.zig");
const Allocator = std.mem.Allocator;

pub const Output = render.Output;

pub const Result = union(enum) {
    ok: Output,
    err: []const u8,
};

/// Parses `source` (the text after preprocessing, with the trailing newline Mermaid's parser sees) and renders it.
/// Everything allocated, including the result, lives in `ctx.a`, which must be an arena.
pub fn renderSource(ctx: *const model.Ctx, gpa: Allocator, source: []const u8, palette: styles.Palette) Allocator.Error!Result {
    const a = ctx.a;
    const db = try a.create(db_mod.Db);
    db.* = db_mod.Db.init(a, ctx.cfg);
    db.setDiagramId(ctx.diagram_id);
    var diag: rt.Diag = .{};
    defer diag.deinit(gpa);
    parse_mod.parse(gpa, db, source, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try a.dupe(u8, if (diag.message.len > 0) diag.message else db.err_msg orelse @errorName(e)) },
    };
    var data = try db.getData();
    data.diagram_id = ctx.diagram_id;
    data.diagram_type = "flowchart-v2";
    data.config = ctx.cfg.*;
    var defs: std.ArrayList(styles.ClassDef) = .empty;
    for (db.classes.values()) |c| try defs.append(a, .{ .id = c.id, .styles = c.styles.items, .text_styles = c.text_styles.items });
    const css = try styles.build(a, palette, ctx.diagram_id, defs.items);
    const out = render.render(ctx, &data, css) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSuchShape => return .{ .err = "No such shape. Please check your syntax." },
        else => return .{ .err = try a.dupe(u8, @errorName(e)) },
    };
    return .{ .ok = out };
}

const fake = struct {
    fn w(_: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
        return 8 * @as(f64, @floatFromInt(text.len));
    }
};

test "renders a small chart and reports parse errors verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var dummy: u8 = 0;
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = fake.w }, .cfg = &cfg, .diagram_id = "d" };
    const ok = try renderSource(&ctx, std.testing.allocator, "graph TD\n  A-->B\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, ok.ok.svg, "id=\"d-flowchart-A-0\"") != null);
    try std.testing.expect(ok.ok.svg.len > 1000);
    const bad = try renderSource(&ctx, std.testing.allocator, "flowchart TD\n  A -->\n\n", .{});
    try std.testing.expect(std.mem.startsWith(u8, bad.err, "Parse error on line 4:"));
}

test "self loop inside a directed subgraph renders through the dagre path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: model.Config = .{};
    cfg.layout = "dagre";
    var dummy: u8 = 0;
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = fake.w }, .cfg = &cfg, .diagram_id = "diagram" };
    const src = "flowchart LR\n  subgraph G1[Group 1]\n    direction TB\n    N3 ==>|ok?| N3\n    N6 --> N3\n  end\n  N4 --> N6\n\n";
    const r = try renderSource(&ctx, std.testing.allocator, src, .{});
    try std.testing.expect(std.mem.indexOf(u8, r.ok.svg, "diagram-L_N3_N3_0") != null);
}
