const std = @import("std");
const layout_mod = @import("dagre/layout.zig");
const graph_mod = @import("graph.zig");

comptime {
    _ = graph_mod;
}

const Allocator = std.mem.Allocator;

const GraphJ = struct {
    rankdir: ?[]const u8 = null,
    nodesep: ?f64 = null,
    ranksep: ?f64 = null,
    edgesep: ?f64 = null,
    marginx: ?f64 = null,
    marginy: ?f64 = null,
    ranker: ?[]const u8 = null,
    acyclicer: ?[]const u8 = null,
    @"align": ?[]const u8 = null,
};

const NodeJ = struct {
    id: []const u8,
    width: f64,
    height: f64,
    parent: ?[]const u8 = null,
};

const EdgeJ = struct {
    v: []const u8,
    w: []const u8,
    name: ?[]const u8 = null,
    minlen: ?f64 = null,
    weight: ?f64 = null,
    width: ?f64 = null,
    height: ?f64 = null,
    labelpos: ?[]const u8 = null,
    labeloffset: ?f64 = null,
};

const NodeOut = struct { x: f64, y: f64, width: ?f64 = null, height: ?f64 = null };

const EdgeOut = struct {
    v: []const u8,
    w: []const u8,
    name: ?[]const u8 = null,
    points: []const [2]f64,
    x: ?f64 = null,
    y: ?f64 = null,
};

const OutJ = struct {
    nodes: std.json.ArrayHashMap(NodeOut),
    edges: []const EdgeOut,
    width: ?f64 = null,
    height: ?f64 = null,
};

const Case = struct {
    name: []const u8,
    graph: GraphJ,
    nodes: []const NodeJ,
    edges: []const EdgeJ,
    out: OutJ,
};

const CrashCase = struct {
    name: []const u8,
    graph: GraphJ,
    nodes: []const NodeJ,
    edges: []const EdgeJ,
    jsError: []const u8,
};

const node_tol = 0.5;
const point_tol = 1.0;

const Stats = struct {
    graphs: usize = 0,
    nodes: usize = 0,
    edge_points: usize = 0,
    max_node: f64 = 0,
    max_point: f64 = 0,
    max_size: f64 = 0,
    peak_arena: usize = 0,
};

var stats: Stats = .{};

fn build(a: Allocator, graph: GraphJ, nodes: []const NodeJ, edges: []const EdgeJ) !layout_mod.Graph {
    var g = try layout_mod.newGraph(a, .{});
    const gl = g.label;
    if (graph.rankdir) |v| gl.rankdir = v;
    if (graph.nodesep) |v| gl.nodesep = v;
    if (graph.ranksep) |v| gl.ranksep = v;
    if (graph.edgesep) |v| gl.edgesep = v;
    if (graph.marginx) |v| gl.marginx = v;
    if (graph.marginy) |v| gl.marginy = v;
    gl.ranker = graph.ranker;
    gl.acyclicer = graph.acyclicer;
    gl.@"align" = graph.@"align";
    for (nodes) |n| try g.setNode(n.id, try layout_mod.newNode(a, n.width, n.height));
    for (nodes) |n| if (n.parent) |p| try g.setParent(n.id, p);
    for (edges) |e| {
        var l: layout_mod.EdgeLabel = .{};
        if (e.minlen) |v| l.minlen = v;
        if (e.weight) |v| l.weight = v;
        if (e.width) |v| l.width = v;
        if (e.height) |v| l.height = v;
        if (e.labeloffset) |v| l.labeloffset = v;
        if (e.labelpos) |v| l.labelpos = v[0];
        try g.setEdge(.{ .v = e.v, .w = e.w, .name = e.name }, try layout_mod.newEdge(a, l));
    }
    return g;
}

fn run(a: Allocator, c: Case) !void {
    var g = try build(a, c.graph, c.nodes, c.edges);
    try layout_mod.layout(a, &g, .{});

    var it = c.out.nodes.map.iterator();
    while (it.next()) |en| {
        const got = g.node(en.key_ptr.*) orelse {
            std.debug.print("{s}: node {s} missing\n", .{ c.name, en.key_ptr.* });
            return error.Mismatch;
        };
        const want = en.value_ptr.*;
        const d = @max(@abs(got.x - want.x), @abs(got.y - want.y));
        stats.max_node = @max(stats.max_node, d);
        stats.nodes += 1;
        if (!(d <= node_tol)) {
            std.debug.print("{s}: node {s} got ({d}, {d}) want ({d}, {d})\n", .{ c.name, en.key_ptr.*, got.x, got.y, want.x, want.y });
            return error.Mismatch;
        }
        if (want.width) |w| {
            const ds = @max(@abs(got.width - w), @abs(got.height - want.height.?));
            stats.max_size = @max(stats.max_size, ds);
            if (!(ds <= node_tol)) {
                std.debug.print("{s}: node {s} size got ({d}, {d}) want ({d}, {d})\n", .{ c.name, en.key_ptr.*, got.width, got.height, w, want.height.? });
                return error.Mismatch;
            }
        }
    }
    try std.testing.expectEqual(c.out.nodes.map.count(), g.nodeCount());

    try std.testing.expectEqual(c.out.edges.len, g.edgeCount());
    for (c.out.edges) |we| {
        const got = g.edgeLabel(.{ .v = we.v, .w = we.w, .name = we.name }) orelse {
            std.debug.print("{s}: edge {s}->{s} missing\n", .{ c.name, we.v, we.w });
            return error.Mismatch;
        };
        if (got.points.items.len != we.points.len) {
            std.debug.print("{s}: edge {s}->{s} has {d} points, want {d}\n", .{ c.name, we.v, we.w, got.points.items.len, we.points.len });
            return error.Mismatch;
        }
        for (got.points.items, we.points) |gp, wp| {
            const d = @max(@abs(gp.x - wp[0]), @abs(gp.y - wp[1]));
            stats.max_point = @max(stats.max_point, d);
            stats.edge_points += 1;
            if (!(d <= point_tol)) {
                std.debug.print("{s}: edge {s}->{s} point got ({d}, {d}) want ({d}, {d})\n", .{ c.name, we.v, we.w, gp.x, gp.y, wp[0], wp[1] });
                return error.Mismatch;
            }
        }
        try std.testing.expectEqual(we.x != null, got.x != null);
        if (we.x) |wx| {
            const d = @max(@abs(got.x.? - wx), @abs(got.y.? - we.y.?));
            stats.max_point = @max(stats.max_point, d);
            if (!(d <= point_tol)) {
                std.debug.print("{s}: edge {s}->{s} label got ({d}, {d}) want ({d}, {d})\n", .{ c.name, we.v, we.w, got.x.?, got.y.?, wx, we.y.? });
                return error.Mismatch;
            }
        }
    }
    if (c.out.width) |w| {
        const dw = @max(@abs(g.label.width - w), @abs(g.label.height - c.out.height.?));
        stats.max_size = @max(stats.max_size, dw);
        if (!(dw <= point_tol)) {
            std.debug.print("{s}: graph size got ({d}, {d}) want ({d}, {d})\n", .{ c.name, g.label.width, g.label.height, w, c.out.height.? });
            return error.Mismatch;
        }
    } else try std.testing.expect(!std.math.isFinite(g.label.width) and !std.math.isFinite(g.label.height));
    stats.graphs += 1;
}

fn runFile(comptime name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]const Case, a, @embedFile("dagre/fixtures/" ++ name ++ ".json"), .{});
    var failed: usize = 0;
    for (cases) |c| {
        var case_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer case_arena.deinit();
        run(case_arena.allocator(), c) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ c.name, @errorName(err) });
            failed += 1;
        };
        stats.peak_arena = @max(stats.peak_arena, case_arena.queryCapacity());
    }
    std.debug.print("{s}: {d} graphs, {d} failed\n", .{ name, cases.len, failed });
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "dagre parity: random DAGs" {
    try runFile("dag");
}

test "dagre parity: cyclic graphs" {
    try runFile("cyclic");
}

test "dagre parity: compound graphs" {
    try runFile("compound");
}

test "dagre parity: edge labels" {
    try runFile("labels");
}

test "dagre parity: rank directions and rankers" {
    try runFile("dirs");
}

test "dagre parity: special cases" {
    try runFile("special");
}

test "dagre parity: 500 edge graphs" {
    try runFile("large");
}

test "dagre: inputs that make dagre throw return an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = try std.json.parseFromSliceLeaky([]const CrashCase, arena.allocator(), @embedFile("dagre/fixtures/crash.json"), .{});
    try std.testing.expect(cases.len > 0);
    for (cases) |c| {
        var case_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer case_arena.deinit();
        const a = case_arena.allocator();
        var g = try build(a, c.graph, c.nodes, c.edges);
        try std.testing.expectError(error.LayoutFailed, layout_mod.layout(a, &g, .{}));
    }
}

test "dagre: an expired deadline stops the layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = try layout_mod.newGraph(a, .{});
    for ([_][]const u8{ "a", "b", "c" }) |v| try g.setNode(v, try layout_mod.newNode(a, 10, 10));
    try g.setEdge(.{ .v = "a", .w = "b" }, try layout_mod.newEdge(a, .{}));
    try g.setEdge(.{ .v = "b", .w = "c" }, try layout_mod.newEdge(a, .{}));
    var flag = true;
    const expired = struct {
        fn f(ctx: *anyopaque) bool {
            const p: *bool = @ptrCast(@alignCast(ctx));
            return p.*;
        }
    }.f;
    try std.testing.expectError(error.Deadline, layout_mod.layout(a, &g, .{ .deadline = .{ .ctx = &flag, .expired = expired } }));
}

test "dagre: invalid numbers are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = try layout_mod.newGraph(a, .{});
    try g.setNode("a", try layout_mod.newNode(a, std.math.nan(f64), 10));
    try std.testing.expectError(error.InvalidInput, layout_mod.layout(a, &g, .{}));
    var h = try layout_mod.newGraph(a, .{});
    try h.setNode("a", try layout_mod.newNode(a, 10, 10));
    try h.setNode("b", try layout_mod.newNode(a, 10, 10));
    try h.setEdge(.{ .v = "a", .w = "b" }, try layout_mod.newEdge(a, .{ .minlen = 0.5 }));
    try std.testing.expectError(error.InvalidInput, layout_mod.layout(a, &h, .{}));
}

test "dagre parity summary" {
    std.debug.print(
        "dagre parity: {d} graphs, {d} nodes (max diff {d:.4}), {d} edge points (max diff {d:.4}), max size diff {d:.4}, peak arena {d} KiB\n",
        .{ stats.graphs, stats.nodes, stats.max_node, stats.edge_points, stats.max_point, stats.max_size, stats.peak_arena / 1024 },
    );
}
