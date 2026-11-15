const std = @import("std");
const mermaid = @import("mermaid.zig");
const elk_json = @import("elk_json.zig");
const recursive = @import("recursive_layout.zig");
const parity = @import("test.zig");
const Value = std.json.Value;

const algorithms = [_]mermaid.Algorithm{ .stress, .force, .sporeOverlap, .box, .rectpacking, .radial };

fn leaf(id: []const u8, parent: ?[]const u8) mermaid.Node {
    return .{ .id = id, .parent_id = parent, .width = 90, .height = 42, .outline = .rect };
}

fn group(id: []const u8, algorithm: ?[]const u8) mermaid.Node {
    return .{ .id = id, .is_group = true, .label_text = id, .label_w = 70, .label_h = 24, .padding = 8, .algorithm = algorithm };
}

fn edge(id: []const u8, start: []const u8, end: []const u8, label: []const u8) mermaid.Edge {
    return .{ .id = id, .start = start, .end = end, .label_text = label, .label_w = if (label.len > 0) 30 else 0, .label_h = if (label.len > 0) 18 else 0, .arrow_type_end = "arrow_point" };
}

fn expectSane(res: mermaid.Result, node_count: usize, edge_count: usize) !void {
    try std.testing.expectEqual(node_count, res.nodes.len);
    try std.testing.expectEqual(edge_count, res.edges.len);
    for (res.nodes) |n| {
        try std.testing.expect(std.math.isFinite(n.x) and std.math.isFinite(n.y));
        try std.testing.expect(std.math.isFinite(n.width) and std.math.isFinite(n.height));
        try std.testing.expect(n.width > 0 and n.height > 0);
    }
    for (res.edges) |e| {
        try std.testing.expect(e.points.len >= 2);
        for (e.points) |p| try std.testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
        try std.testing.expect(!e.has_label_pos or (std.math.isFinite(e.x) and std.math.isFinite(e.y)));
    }
}

fn inside(outer: mermaid.NodeOut, inner: mermaid.NodeOut) bool {
    const slack = 1.0;
    return inner.x - inner.width / 2 >= outer.x - outer.width / 2 - slack and
        inner.x + inner.width / 2 <= outer.x + outer.width / 2 + slack and
        inner.y - inner.height / 2 >= outer.y - outer.height / 2 - slack and
        inner.y + inner.height / 2 <= outer.y + outer.height / 2 + slack;
}

test "every root algorithm lays out a flat graph" {
    const nodes = [_]mermaid.Node{ leaf("A", null), leaf("B", null), leaf("C", null), leaf("D", null), leaf("E", null) };
    const edges = [_]mermaid.Edge{ edge("e1", "A", "B", ""), edge("e2", "B", "C", "yes"), edge("e3", "B", "D", "no"), edge("e4", "C", "E", ""), edge("e5", "D", "E", "") };
    for (algorithms) |alg| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const res = try mermaid.layout(arena.allocator(), &nodes, &edges, .{ .algorithm = alg });
        try expectSane(res, nodes.len, edges.len);
        try std.testing.expectEqual(@as(usize, 0), res.warnings.len);
    }
}

test "every root algorithm lays out subgraphs with cross-boundary edges" {
    const nodes = [_]mermaid.Node{
        group("S1", null),
        leaf("A1", "S1"),
        leaf("A2", "S1"),
        group("S2", null),
        leaf("B1", "S2"),
        leaf("B2", "S2"),
        leaf("X", null),
    };
    const edges = [_]mermaid.Edge{ edge("e1", "A1", "A2", ""), edge("e2", "B1", "B2", ""), edge("e3", "A2", "B1", "go"), edge("e4", "X", "A1", ""), edge("e5", "X", "B2", "") };
    for (algorithms) |alg| {
        for ([_]mermaid.Dir{ .tb, .lr }) |dir| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const res = try mermaid.layout(arena.allocator(), &nodes, &edges, .{ .algorithm = alg, .direction = dir });
            try expectSane(res, nodes.len, edges.len);
        }
    }
}

test "a directional subgraph runs the diagram's algorithm" {
    var nodes = [_]mermaid.Node{ group("S1", null), leaf("A1", "S1"), leaf("A2", "S1"), leaf("X", null) };
    nodes[0].dir = .lr;
    const edges = [_]mermaid.Edge{ edge("e1", "A1", "A2", ""), edge("e2", "X", "S1", "") };
    for ([_]mermaid.Algorithm{ .stress, .box }) |alg| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const res = try mermaid.layout(arena.allocator(), &nodes, &edges, .{ .algorithm = alg });
        try expectSane(res, nodes.len, edges.len);
        try std.testing.expect(inside(res.nodes[0], res.nodes[1]));
        try std.testing.expect(inside(res.nodes[0], res.nodes[2]));
    }
}

test "a container asks for its own algorithm" {
    const requested = [_][]const u8{ "elk.layered", "elk.box", "elk.rectpacking", "elk.stress", "elk.force", "elk.radial", "elk.sporeOverlap" };
    for (requested) |req| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const nodes = [_]mermaid.Node{ group("S1", req), leaf("P1", "S1"), leaf("P2", "S1"), leaf("P3", "S1"), leaf("R", null) };
        const edges = [_]mermaid.Edge{ edge("e1", "P1", "P2", ""), edge("e2", "P1", "P3", ""), edge("e3", "R", "S1", "") };
        const res = try mermaid.layout(arena.allocator(), &nodes, &edges, .{});
        try expectSane(res, nodes.len, edges.len);
        try std.testing.expectEqual(@as(usize, 0), res.warnings.len);
        for (res.nodes[1..4]) |child| try std.testing.expect(inside(res.nodes[0], child));
    }
}

test "a container with a cross-boundary edge falls back to the diagram's algorithm" {
    for ([_][]const u8{ "elk.box", "elk.rectpacking" }) |req| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const nodes = [_]mermaid.Node{ group("S1", req), leaf("P1", "S1"), leaf("P2", "S1"), leaf("R", null) };
        const edges = [_]mermaid.Edge{ edge("e1", "P1", "P2", ""), edge("e2", "R", "P1", "") };
        const res = try mermaid.layout(arena.allocator(), &nodes, &edges, .{});
        try expectSane(res, nodes.len, edges.len);
        try std.testing.expectEqual(@as(usize, 0), res.warnings.len);
        for (res.nodes[1..3]) |child| try std.testing.expect(inside(res.nodes[0], child));
    }
}

test "an unknown container algorithm warns and keeps the diagram's algorithm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]mermaid.Node{ group("S1", "elk.nope"), leaf("P1", "S1"), leaf("P2", "S1") };
    const edges = [_]mermaid.Edge{edge("e1", "P1", "P2", "")};
    const res = try mermaid.layout(arena.allocator(), &nodes, &edges, .{});
    try expectSane(res, nodes.len, edges.len);
    try std.testing.expectEqual(@as(usize, 1), res.warnings.len);
    try std.testing.expectEqualStrings("Unknown container layout algorithm \"elk.nope\". Supported values: elk.layered, elk.box, elk.rectpacking, elk.stress, elk.force, elk.mrtree, elk.radial, elk.sporeOverlap. Falling back to the diagram's layout algorithm.", res.warnings[0]);
}

test "glue fixtures match elkjs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata/mermaid/elk", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "glue-") or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.startsWith(u8, entry.name, "glue-mrtree-")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try std.testing.expect(names.items.len >= 15);

    var stats: parity.Stats = .{};
    for (names.items) |name| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try dir.readFileAlloc(io, name, a, .unlimited);
        const doc = try std.json.parseFromSliceLeaky(Value, a, src, .{});
        const root = try elk_json.fromValue(a, parity.field(doc, "input").?);
        stats.graphs += 1;
        var c: parity.Cmp = .{ .a = a, .name = name, .stats = &stats, .expected_edges = std.StringHashMap(Value).init(a) };
        const out = parity.field(doc, "output").?;
        recursive.layout(a, root) catch |err| {
            std.debug.print("  {s}: layout failed: {s}\n", .{ name, @errorName(err) });
            stats.failed += 1;
            continue;
        };
        try c.collectEdges(out);
        c.nodes(root, out);
        if (c.errors > 0) {
            stats.failed += 1;
            std.debug.print("  {s}: {d} mismatches\n", .{ name, c.errors });
        }
    }
    std.debug.print("\nelk glue parity: graphs={d} failed={d} nodes={d} edges={d} points={d} labels={d} maxNode={d:.4} maxPoint={d:.4} maxLabel={d:.4}\n", .{ stats.graphs, stats.failed, stats.nodes, stats.edges, stats.points, stats.labels, stats.max_node, stats.max_point, stats.max_label });
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
}
