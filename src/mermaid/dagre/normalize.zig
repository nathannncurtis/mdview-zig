const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Edge = types.Edge;
const NodeLabel = types.NodeLabel;
const EdgeLabel = types.EdgeLabel;

fn normalizeEdge(a: Allocator, g: *Graph, e: Edge) Allocator.Error!void {
    var v = e.v;
    var v_rank = g.node(v).?.rank.?;
    const w_rank = g.node(e.w).?.rank.?;
    const edge_label = g.edgeLabel(e).?;
    const label_rank = edge_label.label_rank;
    if (w_rank == v_rank + 1) return;
    g.removeEdge(e);
    var i: usize = 0;
    v_rank += 1;
    while (v_rank < w_rank) : ({
        i += 1;
        v_rank += 1;
    }) {
        edge_label.points.clearRetainingCapacity();
        edge_label.has_points = true;
        const attrs = try a.create(NodeLabel);
        attrs.* = .{ .edge_label = edge_label, .e = e, .rank = v_rank };
        const dummy = try util.addDummyNode(a, g, .edge, attrs, "_d");
        if (label_rank != null and v_rank == label_rank.?) {
            attrs.width = edge_label.width;
            attrs.height = edge_label.height;
            attrs.dummy = .edge_label;
            attrs.labelpos = edge_label.labelpos;
        }
        const l = try a.create(EdgeLabel);
        l.* = .{ .weight = edge_label.weight };
        try g.setEdge(.{ .v = v, .w = dummy, .name = e.name }, l);
        if (i == 0) try g.label.dummy_chains.append(a, dummy);
        v = dummy;
    }
    const l = try a.create(EdgeLabel);
    l.* = .{ .weight = edge_label.weight };
    try g.setEdge(.{ .v = v, .w = e.w, .name = e.name }, l);
}

pub fn run(a: Allocator, g: *Graph) Allocator.Error!void {
    g.label.dummy_chains = .empty;
    for (try a.dupe(Edge, g.edges())) |e| try normalizeEdge(a, g, e);
}

pub fn undo(a: Allocator, g: *Graph) Allocator.Error!void {
    for (g.label.dummy_chains.items) |first| {
        var v = first;
        var node = g.node(v).?;
        const orig = node.edge_label.?;
        try g.setEdge(node.e.?, orig);
        while (node.dummy != .none) {
            const w = g.successors(v).?[0];
            try g.removeNode(v);
            try orig.points.append(a, .{ .x = node.x, .y = node.y });
            if (node.dummy == .edge_label) {
                orig.x = node.x;
                orig.y = node.y;
                orig.width = node.width;
                orig.height = node.height;
            }
            v = w;
            node = g.node(v).?;
        }
    }
}
