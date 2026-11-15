const std = @import("std");
const core = @import("../diagram.zig");
const svg = @import("../svg.zig");
const model = @import("../render/model.zig");
const dom = @import("../render/dom.zig");
const db_mod = @import("db.zig");
const parse_mod = @import("parse.zig");
const render = @import("render.zig");
const styles = @import("styles.zig");
const rt = @import("../jison/runtime.zig");
const Allocator = std.mem.Allocator;

const Parsed = struct { db: *db_mod.Db, cfg: *const model.Config, data: model.LayoutData };

fn parse(comptime id: []const u8) fn (*core.Ctx, []const u8) core.Error!*anyopaque {
    return struct {
        fn f(ctx: *core.Ctx, source: []const u8) core.Error!*anyopaque {
            const a = ctx.a;
            const cfg = try a.create(model.Config);
            cfg.* = model.Config.fromCore(ctx.cfg);
            const db = try a.create(db_mod.Db);
            db.* = db_mod.Db.init(a, cfg);
            db.setDiagramId(ctx.svg_id);
            if (ctx.title) |t| try db.setDiagramTitle(t);
            var diag: rt.Diag = .{};
            parse_mod.parse(a, db, source, &diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    ctx.err_msg = if (diag.message.len > 0) diag.message else db.err_msg orelse @errorName(e);
                    return error.Parse;
                },
            };
            const p = try a.create(Parsed);
            p.* = .{ .db = db, .cfg = cfg, .data = try db.getData() };
            p.data.diagram_id = ctx.svg_id;
            p.data.diagram_type = id;
            return p;
        }
    }.f;
}

fn parsed(m: *anyopaque) *Parsed {
    return @ptrCast(@alignCast(m));
}

fn layoutStage(ctx: *core.Ctx, m: *anyopaque) core.Error!*anyopaque {
    const p = parsed(m);
    const mctx: model.Ctx = .{ .a = ctx.a, .measurer = ctx.measurer, .cfg = p.cfg, .diagram_id = ctx.svg_id, .layout = ctx.layout.engine, .elk_algorithm = ctx.layout.algorithm, .image_probe = ctx.image_probe };
    const out = try ctx.a.create(render.Rendered);
    out.* = render.render(&mctx, &p.data) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSuchShape => {
            ctx.err_msg = "No such shape. Please check your syntax.";
            return error.Layout;
        },
        error.ImageDecode => {
            ctx.err_msg = "The source image cannot be decoded.";
            return error.Layout;
        },
        else => {
            ctx.err_msg = @errorName(e);
            return error.Layout;
        },
    };
    return out;
}

fn emit(ctx: *core.Ctx, _: *anyopaque, g: *anyopaque, w: *svg.SvgWriter) core.Error!void {
    const r: *render.Rendered = @ptrCast(@alignCast(g));
    const a = ctx.a;
    try w.setRootAttr("class", "flowchart");
    try w.configureSvgSize(r.height, r.width, ctx.cfg.boolean("flowchart.useMaxWidth") orelse true);
    if (w.max_width != null) try w.setRootAttr("style", try std.fmt.allocPrint(a, "max-width: {s}px;", .{r.max_width}));
    const vb = r.view_box;
    try w.setRootAttr("viewBox", try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ try dom.fmtNum(a, vb[0]), try dom.fmtNum(a, vb[1]), try dom.fmtNum(a, vb[2]), try dom.fmtNum(a, vb[3]) }));
    w.view_box = vb;
    var out: std.ArrayList(u8) = .empty;
    for (r.svg.kids.items) |k| try dom.serialize(&out, a, k);
    try w.raw(out.items);
}

fn diagramStyles(ctx: *core.Ctx) core.Error![]const u8 {
    return styles.css(ctx);
}

fn classDefs(ctx: *core.Ctx, m: *anyopaque) core.Error![]const core.ClassDef {
    const db = parsed(m).db;
    const out = try ctx.a.alloc(core.ClassDef, db.classes.count());
    for (db.classes.values(), out) |c, *o| o.* = .{ .id = c.id, .styles = c.styles.items, .text_styles = c.text_styles.items };
    return out;
}

fn acc(_: *core.Ctx, m: *anyopaque) core.Acc {
    const db = parsed(m).db;
    return .{ .title = db.acc_title, .descr = db.acc_descr };
}

fn define(comptime id: []const u8) core.Def {
    return .{
        .id = id,
        .parse = parse(id),
        .layout = layoutStage,
        .emit = emit,
        .styles = diagramStyles,
        .class_defs = classDefs,
        .acc = acc,
        .owns_group = true,
    };
}

pub const Result = union(enum) { ok: struct { svg: []const u8 }, err: []const u8 };

/// Parses and renders `source` without the core's frame, returning the serialised `svg` element.
pub fn renderSource(ctx: *const model.Ctx, source: []const u8) Allocator.Error!Result {
    const a = ctx.a;
    const db = try a.create(db_mod.Db);
    db.* = db_mod.Db.init(a, ctx.cfg);
    db.setDiagramId(ctx.diagram_id);
    var diag: rt.Diag = .{};
    parse_mod.parse(a, db, source, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = if (diag.message.len > 0) diag.message else db.err_msg orelse @errorName(e) },
    };
    var data = try db.getData();
    data.diagram_id = ctx.diagram_id;
    data.diagram_type = "flowchart-v2";
    const r = render.render(ctx, &data) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSuchShape => return .{ .err = "No such shape. Please check your syntax." },
        error.ImageDecode => return .{ .err = "The source image cannot be decoded." },
        else => return .{ .err = @errorName(e) },
    };
    var out: std.ArrayList(u8) = .empty;
    try dom.serialize(&out, a, r.svg);
    return .{ .ok = .{ .svg = out.items } };
}

fn fakeWidth(_: ?*anyopaque, t: []const u8, _: model.Font) f64 {
    return 8 * @as(f64, @floatFromInt(t.len));
}

test "renders a small chart and reports parse errors verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = model.testConfig(arena.allocator());
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = model.widthMeasurer(null, fakeWidth), .cfg = &cfg, .diagram_id = "d" };
    const ok = try renderSource(&ctx, "graph TD\n  A-->B\n");
    try std.testing.expect(std.mem.indexOf(u8, ok.ok.svg, "id=\"d-flowchart-A-0\"") != null);
    try std.testing.expect(ok.ok.svg.len > 1000);
    const bad = try renderSource(&ctx, "flowchart TD\n  A -->\n\n");
    try std.testing.expect(std.mem.startsWith(u8, bad.err, "Parse error on line 4:"));
}

fn probeSize(_: []const u8) model.ImageProbe {
    return .{ .size = .{ .w = 40, .h = 20 } };
}

fn probeFailed(_: []const u8) model.ImageProbe {
    return .failed;
}

test "an image node takes its size from the probe and fails with Mermaid's decode error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = model.testConfig(arena.allocator());
    const src = "flowchart TD\n  C@{ img: \"a.png\", label: \"p\", pos: b }\n";
    var ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = model.widthMeasurer(null, fakeWidth), .cfg = &cfg, .diagram_id = "d", .image_probe = probeSize };
    const ok = try renderSource(&ctx, src);
    try std.testing.expect(std.mem.indexOf(u8, ok.ok.svg, "<image") != null);
    ctx.image_probe = probeFailed;
    const bad = try renderSource(&ctx, src);
    try std.testing.expectEqualStrings("The source image cannot be decoded.", bad.err);
    ctx.image_probe = null;
    try std.testing.expectEqualStrings("The source image cannot be decoded.", (try renderSource(&ctx, src)).err);
}

test "self loop inside a directed subgraph renders through the dagre path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = model.testConfig(arena.allocator());
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = model.widthMeasurer(null, fakeWidth), .cfg = &cfg, .diagram_id = "diagram", .layout = .dagre };
    const src = "flowchart LR\n  subgraph G1[Group 1]\n    direction TB\n    N3 ==>|ok?| N3\n    N6 --> N3\n  end\n  N4 --> N6\n\n";
    const r = try renderSource(&ctx, src);
    try std.testing.expect(std.mem.indexOf(u8, r.ok.svg, "diagram-L_N3_N3_0") != null);
}

pub const def_v2 = define("flowchart-v2");
pub const def_elk = define("flowchart-elk");

test {
    _ = @import("../render/dom.zig");
    _ = @import("../render/model.zig");
    _ = @import("../render/cluster_extract.zig");
    _ = @import("../render/clusters.zig");
    _ = @import("../render/curves.zig");
    _ = @import("../render/edges.zig");
    _ = @import("../render/geom.zig");
    _ = @import("../render/pathlen.zig");
    _ = @import("../render/intersect.zig");
    _ = @import("../render/line_jump.zig");
    _ = @import("../render/labels.zig");
    _ = @import("../render/markers.zig");
    _ = @import("../render/shapes_test.zig");
    _ = @import("../render/svg_labels_test.zig");
    _ = @import("../render/shapes_icon_test.zig");
    _ = @import("render.zig");
    _ = @import("../render/neo_test.zig");
    _ = @import("db_test.zig");
    _ = @import("parse_test.zig");
}
