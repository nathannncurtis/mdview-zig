const std = @import("std");
const lg = @import("../../lgraph.zig");

pub const Neighbor = struct { node: *lg.LNode, edge: *lg.LEdge };

// NeighborhoodInformation: renumbers layer and node ids (node ids are global, in layer order) and caches the
// highest-priority neighbours of every node, sorted by their index in their layer.
pub const NeighborhoodInformation = struct {
    node_count: usize = 0,
    layer_index: []usize = &.{},
    node_index: []usize = &.{},
    left_neighbors: [][]Neighbor = &.{},
    right_neighbors: [][]Neighbor = &.{},

    pub fn buildFor(a: std.mem.Allocator, graph: *lg.LGraph) lg.Error!NeighborhoodInformation {
        var ni: NeighborhoodInformation = .{};
        for (graph.layers.items) |layer| ni.node_count += layer.nodes.items.len;
        ni.layer_index = try a.alloc(usize, graph.layers.items.len);
        ni.node_index = try a.alloc(usize, ni.node_count);
        var n_id: usize = 0;
        for (graph.layers.items, 0..) |l, l_id| {
            l.id = @intCast(l_id);
            ni.layer_index[l_id] = l_id;
            for (l.nodes.items, 0..) |n, n_index| {
                n.id = @intCast(n_id);
                ni.node_index[n_id] = n_index;
                n_id += 1;
            }
        }
        ni.left_neighbors = try a.alloc([]Neighbor, ni.node_count);
        ni.right_neighbors = try a.alloc([]Neighbor, ni.node_count);
        try ni.determineNeighbors(a, graph, true);
        try ni.determineNeighbors(a, graph, false);
        return ni;
    }

    fn determineNeighbors(ni: *NeighborhoodInformation, a: std.mem.Allocator, graph: *lg.LGraph, left: bool) lg.Error!void {
        for (graph.layers.items) |l| {
            for (l.nodes.items) |n| {
                var result: std.ArrayList(Neighbor) = .empty;
                var max_priority: i32 = 0;
                for (n.ports.items) |port| {
                    const edges = if (left) port.incoming.items else port.outgoing.items;
                    for (edges) |edge| {
                        if (edge.isSelfLoop() or edge.isInLayerEdge()) continue;
                        const edge_prio = edge.p.priority_straightness;
                        if (edge_prio > max_priority) {
                            max_priority = edge_prio;
                            result.clearRetainingCapacity();
                        }
                        if (edge_prio == max_priority) {
                            const other = if (left) edge.source.?.owner.? else edge.target.?.owner.?;
                            try result.append(a, .{ .node = other, .edge = edge });
                        }
                    }
                }
                std.mem.sort(Neighbor, result.items, ni, lessByIndex);
                const id: usize = @intCast(n.id);
                if (left) ni.left_neighbors[id] = result.items else ni.right_neighbors[id] = result.items;
            }
        }
    }

    fn lessByIndex(ni: *NeighborhoodInformation, x: Neighbor, y: Neighbor) bool {
        return ni.node_index[@intCast(x.node.id)] < ni.node_index[@intCast(y.node.id)];
    }

    pub fn nodeIndex(ni: *const NeighborhoodInformation, n: *const lg.LNode) usize {
        return ni.node_index[@intCast(n.id)];
    }
};
