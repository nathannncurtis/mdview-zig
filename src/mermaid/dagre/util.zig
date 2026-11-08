const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const NodeLabel = types.NodeLabel;
const EdgeLabel = types.EdgeLabel;
const Point = types.Point;

pub fn addDummyNode(a: Allocator, g: *Graph, dummy: types.Dummy, attrs: *NodeLabel, prefix: []const u8) Allocator.Error![]const u8 {
    var v = try types.nextId(g.label, a, prefix);
    while (g.hasNode(v)) v = try types.nextId(g.label, a, prefix);
    attrs.dummy = dummy;
    try g.setNode(v, attrs);
    return v;
}

pub fn addBorderNode(a: Allocator, g: *Graph, prefix: []const u8, rank_order: ?struct { f64, i64 }) Allocator.Error![]const u8 {
    const node = try a.create(NodeLabel);
    node.* = .{};
    if (rank_order) |ro| {
        node.rank = ro[0];
        node.order = ro[1];
    }
    return addDummyNode(a, g, .border, node, prefix);
}

pub fn simplify(a: Allocator, g: *Graph) Allocator.Error!Graph {
    var s = Graph.init(a, .{}, g.label);
    for (g.nodes()) |v| try s.setNode(v, g.node(v).?);
    for (g.edges()) |e| {
        const prev = s.edge(e.v, e.w);
        const label = g.edgeLabel(e).?;
        const n = try a.create(EdgeLabel);
        n.* = .{
            .weight = (if (prev) |p| p.weight else 0) + label.weight,
            .minlen = @max(if (prev) |p| p.minlen else 1, label.minlen),
        };
        try s.setEdge(.{ .v = e.v, .w = e.w }, n);
    }
    return s;
}

pub fn asNonCompoundGraph(a: Allocator, g: *Graph) Allocator.Error!Graph {
    var s = Graph.init(a, .{ .multigraph = g.multigraph }, g.label);
    for (g.nodes()) |v| {
        if (g.children(v).?.len == 0) try s.setNode(v, g.node(v).?);
    }
    for (g.edges()) |e| try s.setEdge(e, g.edgeLabel(e).?);
    return s;
}

pub fn intersectRect(x: f64, y: f64, width: f64, height: f64, px: f64, py: f64) error{NoIntersection}!Point {
    const dx = px - x;
    const dy = py - y;
    var w = width / 2;
    var h = height / 2;
    if (dx == 0 and dy == 0) return error.NoIntersection;
    if (@abs(dy) * w > @abs(dx) * h) {
        if (dy < 0) h = -h;
        return .{ .x = x + (h * dx) / dy, .y = y + h };
    }
    if (dx < 0) w = -w;
    return .{ .x = x + w, .y = y + (w * dy) / dx };
}

pub fn maxRank(g: *const Graph) ?f64 {
    var m: ?f64 = null;
    for (g.nodes()) |v| {
        if (g.node(v).?.rank) |r| {
            if (m == null or r > m.?) m = r;
        }
    }
    return m;
}

pub const Layering = []const []const []const u8;

pub fn buildLayerMatrix(a: Allocator, g: *const Graph) Allocator.Error!Layering {
    const mr = maxRank(g) orelse return &.{};
    const n: usize = @intFromFloat(mr + 1);
    const lists = try a.alloc(std.ArrayList([]const u8), n);
    for (lists) |*l| l.* = .empty;
    for (g.nodes()) |v| {
        const node = g.node(v).?;
        const r = node.rank orelse continue;
        const l = &lists[@intFromFloat(r)];
        const o: usize = @intCast(node.order);
        while (l.items.len <= o) try l.append(a, "");
        l.items[o] = v;
    }
    const out = try a.alloc([]const []const u8, n);
    for (lists, out) |l, *o| o.* = l.items;
    return out;
}

// Every ranked node must sit in its own slot of its layer.
pub fn checkLayering(a: Allocator, g: *const Graph) types.Error!void {
    const layers = try buildLayerMatrix(a, g);
    var placed: usize = 0;
    for (layers) |l| for (l) |v| {
        if (v.len == 0) return error.LayoutFailed;
        placed += 1;
    };
    var ranked: usize = 0;
    for (g.nodes()) |v| {
        if (g.node(v).?.rank != null) ranked += 1;
    }
    if (placed != ranked) return error.LayoutFailed;
}

pub fn normalizeRanks(g: *Graph) void {
    var min: ?f64 = null;
    for (g.nodes()) |v| {
        if (g.node(v).?.rank) |r| {
            if (min == null or r < min.?) min = r;
        }
    }
    for (g.nodes()) |v| {
        const node = g.node(v).?;
        if (node.rank) |r| node.rank = r - (min orelse 0);
    }
}

pub fn removeEmptyRanks(a: Allocator, g: *Graph) Allocator.Error!void {
    var offset: ?f64 = null;
    for (g.nodes()) |v| {
        if (g.node(v).?.rank) |r| {
            if (offset == null or r < offset.?) offset = r;
        }
    }
    const off = offset orelse return;
    var layers: std.ArrayList(?std.ArrayList([]const u8)) = .empty;
    for (g.nodes()) |v| {
        // JS stores a missing or fractional rank as a non-index property, which forEach never visits
        const r = (g.node(v).?.rank orelse continue) - off;
        if (r != @floor(r)) continue;
        const idx: usize = @intFromFloat(r);
        while (layers.items.len <= idx) try layers.append(a, null);
        if (layers.items[idx] == null) layers.items[idx] = .empty;
        try layers.items[idx].?.append(a, v);
    }
    var delta: f64 = 0;
    const factor: u64 = @intFromFloat(g.label.node_rank_factor);
    for (layers.items, 0..) |vs, i| {
        if (vs == null and i % factor != 0) {
            delta -= 1;
        } else if (delta != 0) {
            if (vs) |list| for (list.items) |v| {
                const node = g.node(v).?;
                node.rank = node.rank.? + delta;
            };
        }
    }
}
