// NetworkSimplexLayerer. Props read: thoroughness (graph), priority_shortness (edges). Writes LNode.id, layers.
const std = @import("std");
const lg = @import("../lgraph.zig");
const ns = @import("../network_simplex.zig");

const iter_limit_factor = 4;

const Components = struct {
    a: std.mem.Allocator,
    node_visited: []bool,
    component_nodes: std.ArrayList(*lg.LNode) = .empty,

    fn dfs(self: *Components, node: *lg.LNode) lg.Error!void {
        self.node_visited[@intCast(node.id)] = true;
        try self.component_nodes.append(self.a, node);
        for (node.ports.items) |port| {
            for ([2][]*lg.LEdge{ port.incoming.items, port.outgoing.items }) |list| {
                for (list) |edge| {
                    const opposite = (if (edge.source.? == port) edge.target.? else edge.source.?).owner.?;
                    if (!self.node_visited[@intCast(opposite.id)]) try self.dfs(opposite);
                }
            }
        }
    }
};

fn connectedComponents(a: std.mem.Allocator, the_nodes: []*lg.LNode) lg.Error![][]*lg.LNode {
    var c: Components = .{ .a = a, .node_visited = try a.alloc(bool, the_nodes.len) };
    @memset(c.node_visited, false);
    for (the_nodes, 0..) |node, counter| node.id = @intCast(counter);

    var components: std.ArrayList([]*lg.LNode) = .empty;
    for (the_nodes) |node| {
        if (!c.node_visited[@intCast(node.id)]) {
            try c.dfs(node);
            if (components.items.len == 0 or components.items[0].len < c.component_nodes.items.len) {
                try components.insert(a, 0, c.component_nodes.items);
            } else {
                try components.append(a, c.component_nodes.items);
            }
            c.component_nodes = .empty;
        }
    }
    return components.items;
}

fn initialize(a: std.mem.Allocator, the_nodes: []*lg.LNode) lg.Error!*ns.NGraph {
    const graph = try a.create(ns.NGraph);
    graph.* = ns.NGraph.init(a);
    var max_id: usize = 0;
    for (the_nodes) |n| max_id = @max(max_id, @as(usize, @intCast(n.id)));
    const by_id = try a.alloc(?*ns.NNode, max_id + 1);
    @memset(by_id, null);
    for (the_nodes) |l_node| by_id[@intCast(l_node.id)] = try graph.createNode(l_node);
    for (the_nodes) |l_node| {
        for (l_node.ports.items) |port| {
            for (port.outgoing.items) |l_edge| {
                if (l_edge.isSelfLoop()) continue;
                const w: f64 = @floatFromInt(1 * @max(1, l_edge.p.priority_shortness));
                _ = try graph.createEdge(
                    l_edge,
                    by_id[@intCast(l_edge.source.?.owner.?.id)].?,
                    by_id[@intCast(l_edge.target.?.owner.?.id)].?,
                    w,
                    1,
                );
            }
        }
    }
    return graph;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    const thoroughness = g.p.thoroughness * iter_limit_factor;
    const the_nodes = g.layerless_nodes.items;
    if (the_nodes.len < 1) return;

    const connected_components = try connectedComponents(a, the_nodes);
    var previous_layering_node_counts: ?[]i32 = null;
    for (connected_components) |conn_comp| {
        const sq: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(conn_comp.len))));
        const iter_limit = thoroughness *% sq;

        const graph = try initialize(a, conn_comp);
        var simplex = ns.NetworkSimplex.forGraph(graph);
        simplex.iteration_limit = iter_limit;
        simplex.previous_layering_node_counts = previous_layering_node_counts;
        simplex.balance_layers = true;
        try simplex.execute();

        for (graph.nodes.items) |n_node| {
            while (g.layers.items.len <= @as(usize, @intCast(n_node.layer))) {
                try g.layers.append(a, try g.newLayer());
            }
            try n_node.origin.?.setLayer(g.layers.items[@intCast(n_node.layer)]);
        }

        if (connected_components.len > 1) {
            const counts = try a.alloc(i32, g.layers.items.len);
            for (g.layers.items, 0..) |l, i| counts[i] = @intCast(l.nodes.items.len);
            previous_layering_node_counts = counts;
        }
    }
    g.layerless_nodes.clearRetainingCapacity();
}
