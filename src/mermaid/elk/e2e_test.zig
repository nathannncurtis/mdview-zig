const std = @import("std");
const mermaid = @import("mermaid.zig");

const NodeJ = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
    isGroup: bool,
    shape: []const u8,
    w: f64,
    h: f64,
    labelText: []const u8,
    labelW: f64,
    labelH: f64,
    padding: f64,
    dir: ?[]const u8 = null,
    ex: f64,
    ey: f64,
    ew: ?f64 = null,
    eh: ?f64 = null,
};

const EdgeJ = struct {
    id: []const u8,
    start: []const u8,
    end: []const u8,
    labelText: []const u8,
    labelW: f64,
    labelH: f64,
    as: []const u8,
    ae: []const u8,
    pts: []const [2]f64,
    lx: ?f64 = null,
    ly: ?f64 = null,
};

const CaseJ = struct {
    name: []const u8,
    dir: []const u8,
    nodes: []const NodeJ,
    edges: []const EdgeJ,
};

const rect_shapes = [_][]const u8{ "squareRect", "rect", "roundedRect", "rounded" };

fn isRectShape(s: []const u8) bool {
    for (rect_shapes) |r| if (std.mem.eql(u8, r, s)) return true;
    return false;
}

fn outlineOf(s: []const u8) mermaid.Outline {
    const diamonds = [_][]const u8{ "diamond", "diam" };
    const circles = [_][]const u8{ "circle", "circ", "doublecircle", "dbl-circ" };
    for (diamonds) |d| if (std.mem.eql(u8, d, s)) return .diamond;
    for (circles) |d| if (std.mem.eql(u8, d, s)) return .circle;
    return if (isRectShape(s)) .rect else .none;
}

fn dirOf(s: []const u8) mermaid.Dir {
    if (std.mem.eql(u8, s, "lr")) return .lr;
    if (std.mem.eql(u8, s, "rl")) return .rl;
    if (std.mem.eql(u8, s, "bt")) return .bt;
    return .tb;
}

const Report = struct {
    cases: usize = 0,
    matched: usize = 0,
    rect_cases: usize = 0,
    rect_matched: usize = 0,
    nodes: usize = 0,
    node_ok: usize = 0,
    edges: usize = 0,
    edge_ok: usize = 0,
    labels: usize = 0,
    label_ok: usize = 0,
};

fn near(a: f64, b: f64, tol: f64) bool {
    return @abs(a - b) <= tol;
}

fn runCase(gpa: std.mem.Allocator, c: CaseJ, rep: *Report, verbose: bool) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try a.alloc(mermaid.Node, c.nodes.len);
    var rect_only = true;
    for (c.nodes, 0..) |n, i| {
        if (!isRectShape(n.shape) and !n.isGroup) rect_only = false;
        nodes[i] = .{
            .id = n.id,
            .parent_id = n.parent,
            .is_group = n.isGroup,
            .width = n.w,
            .height = n.h,
            .label_text = n.labelText,
            .label_w = n.labelW,
            .label_h = n.labelH,
            .padding = n.padding,
            .dir = if (n.dir) |d| dirOf(d) else null,
            .outline = if (n.isGroup) .none else outlineOf(n.shape),
        };
    }
    const edges = try a.alloc(mermaid.Edge, c.edges.len);
    for (c.edges, 0..) |e, i| edges[i] = .{
        .id = e.id,
        .start = e.start,
        .end = e.end,
        .label_text = e.labelText,
        .label_w = e.labelW,
        .label_h = e.labelH,
        .arrow_type_start = e.as,
        .arrow_type_end = e.ae,
    };
    const res = try mermaid.layout(a, nodes, edges, .{ .direction = dirOf(c.dir) });

    var ok = true;
    for (c.nodes, 0..) |n, i| {
        rep.nodes += 1;
        const got = res.nodes[i];
        var good = near(got.x, n.ex, 0.5) and near(got.y, n.ey, 0.5);
        if (n.isGroup) good = good and near(@max(got.width, n.labelW + n.padding), n.ew.?, 0.5) and near(got.height, n.eh.?, 0.5);
        if (good) rep.node_ok += 1 else {
            ok = false;
            if (verbose) std.debug.print("  {s}: node {s} got {d:.2},{d:.2} {d:.2}x{d:.2} want {d:.2},{d:.2}\n", .{ c.name, n.id, got.x, got.y, got.width, got.height, n.ex, n.ey });
        }
    }
    for (c.edges, 0..) |e, i| {
        rep.edges += 1;
        const got = res.edges[i];
        var good = got.points.len == e.pts.len;
        if (good) for (got.points, e.pts) |p, q| {
            if (!near(p.x, q[0], 1) or !near(p.y, q[1], 1)) good = false;
        };
        if (good) rep.edge_ok += 1 else {
            ok = false;
            if (verbose) {
                std.debug.print("  {s}: edge {s} got {d} points want {d}:", .{ c.name, e.id, got.points.len, e.pts.len });
                for (got.points) |p| std.debug.print(" ({d:.2},{d:.2})", .{ p.x, p.y });
                std.debug.print(" |", .{});
                for (e.pts) |q| std.debug.print(" ({d:.2},{d:.2})", .{ q[0], q[1] });
                std.debug.print("\n", .{});
            }
        }
        if (e.lx != null and e.labelText.len > 0) {
            rep.labels += 1;
            if (got.has_label_pos and near(got.x, e.lx.?, 1) and near(got.y, e.ly.?, 1)) rep.label_ok += 1 else {
                ok = false;
                if (verbose) std.debug.print("  {s}: label of {s} got {d:.2},{d:.2} want {d:.2},{d:.2}\n", .{ c.name, e.id, got.x, got.y, e.lx.?, e.ly.? });
            }
        }
    }
    rep.cases += 1;
    if (ok) rep.matched += 1;
    if (rect_only) {
        rep.rect_cases += 1;
        if (ok) rep.rect_matched += 1;
    }
    return ok and rect_only or !rect_only;
}

test "mermaid.zig matches the 12.2.0 flowchart references" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cases = try std.json.parseFromSliceLeaky([]const CaseJ, arena.allocator(), @import("testdata").file("mermaid/elk/e2e/cases.json"), .{ .ignore_unknown_fields = true });
    var rep: Report = .{};
    var rect_failed: usize = 0;
    for (cases) |c| {
        const good = runCase(gpa, c, &rep, true) catch |err| {
            std.debug.print("  {s}: layout failed: {s}\n", .{ c.name, @errorName(err) });
            rect_failed += 1;
            continue;
        };
        if (!good) rect_failed += 1;
    }
    std.debug.print("\nflowchart e2e: cases={d} matched={d} rectOnly={d} rectOnlyMatched={d} nodes={d}/{d} edges={d}/{d} labels={d}/{d}\n", .{ rep.cases, rep.matched, rep.rect_cases, rep.rect_matched, rep.node_ok, rep.nodes, rep.edge_ok, rep.edges, rep.label_ok, rep.labels });
    try std.testing.expectEqual(@as(usize, 0), rect_failed);
}
