// GreedyCycleBreaker and its subclass GreedyModelOrderCycleBreaker (`model_order` selects the subclass's
// chooseNodeWithMaxOutflow). Followed by intermediate/reversed_edge_restorer after P5.
const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");
const util = @import("../util.zig");

const Breaker = struct {
    a: std.mem.Allocator,
    indeg: []i32,
    outdeg: []i32,
    mark: []i32,
    sources: std.ArrayList(*lg.LNode) = .empty,
    sources_head: usize = 0,
    sinks: std.ArrayList(*lg.LNode) = .empty,
    sinks_head: usize = 0,

    fn updateNeighbors(self: *Breaker, node: *lg.LNode) lg.Error!void {
        for (node.ports.items) |port| {
            for ([_][]*lg.LEdge{ port.incoming.items, port.outgoing.items }) |edges| {
                for (edges) |edge| {
                    const connected_port = if (edge.source.? == port) edge.target.? else edge.source.?;
                    const endpoint = connected_port.owner.?;
                    if (node == endpoint) continue;
                    var priority = edge.p.priority_direction;
                    if (priority < 0) priority = 0;
                    const index: usize = @intCast(endpoint.id);
                    if (self.mark[index] == 0) {
                        if (edge.target.? == connected_port) {
                            self.indeg[index] -= priority + 1;
                            if (self.indeg[index] <= 0 and self.outdeg[index] > 0) try self.sources.append(self.a, endpoint);
                        } else {
                            self.outdeg[index] -= priority + 1;
                            if (self.outdeg[index] <= 0 and self.indeg[index] > 0) try self.sinks.append(self.a, endpoint);
                        }
                    }
                }
            }
        }
    }
};

fn chooseNodeWithMaxOutflow(g: *lg.LGraph, nodes: []*lg.LNode, model_order: bool) lg.Error!*lg.LNode {
    if (model_order) {
        var return_node: ?*lg.LNode = null;
        var minimum_model_order: i32 = std.math.maxInt(i32);
        for (nodes) |node| {
            if (node.p.model_order) |mo| if (mo < minimum_model_order) {
                minimum_model_order = mo;
                return_node = node;
            };
        }
        if (return_node) |n| return n;
    }
    const random = try util.graphRandom(g);
    return nodes[@intCast(random.nextIntBound(@intCast(nodes.len)))];
}

pub fn process(g: *lg.LGraph, model_order: bool) lg.Error!void {
    const a = g.a;
    const nodes = g.layerless_nodes.items;
    var unprocessed_node_count: i64 = @intCast(nodes.len);
    var b: Breaker = .{
        .a = a,
        .indeg = try a.alloc(i32, nodes.len),
        .outdeg = try a.alloc(i32, nodes.len),
        .mark = try a.alloc(i32, nodes.len),
    };
    @memset(b.indeg, 0);
    @memset(b.outdeg, 0);
    @memset(b.mark, 0);

    for (nodes, 0..) |node, index| {
        node.id = @intCast(index);
        for (node.ports.items) |port| {
            for (port.incoming.items) |edge| {
                if (edge.source.?.owner.? == node) continue;
                const priority = edge.p.priority_direction;
                b.indeg[index] += if (priority > 0) priority + 1 else 1;
            }
            for (port.outgoing.items) |edge| {
                if (edge.target.?.owner.? == node) continue;
                const priority = edge.p.priority_direction;
                b.outdeg[index] += if (priority > 0) priority + 1 else 1;
            }
        }
        if (b.outdeg[index] == 0) {
            try b.sinks.append(a, node);
        } else if (b.indeg[index] == 0) {
            try b.sources.append(a, node);
        }
    }

    var next_right: i32 = -1;
    var next_left: i32 = 1;
    var max_nodes: std.ArrayList(*lg.LNode) = .empty;

    while (unprocessed_node_count > 0) {
        while (b.sinks_head < b.sinks.items.len) {
            const sink = b.sinks.items[b.sinks_head];
            b.sinks_head += 1;
            b.mark[@intCast(sink.id)] = next_right;
            next_right -= 1;
            try b.updateNeighbors(sink);
            unprocessed_node_count -= 1;
        }
        while (b.sources_head < b.sources.items.len) {
            const source = b.sources.items[b.sources_head];
            b.sources_head += 1;
            b.mark[@intCast(source.id)] = next_left;
            next_left += 1;
            try b.updateNeighbors(source);
            unprocessed_node_count -= 1;
        }
        if (unprocessed_node_count > 0) {
            var max_outflow: i32 = std.math.minInt(i32);
            for (nodes) |node| {
                const id: usize = @intCast(node.id);
                if (b.mark[id] == 0) {
                    const outflow = b.outdeg[id] - b.indeg[id];
                    if (outflow >= max_outflow) {
                        if (outflow > max_outflow) {
                            max_nodes.clearRetainingCapacity();
                            max_outflow = outflow;
                        }
                        try max_nodes.append(a, node);
                    }
                }
            }
            const max_node = try chooseNodeWithMaxOutflow(g, max_nodes.items, model_order);
            b.mark[@intCast(max_node.id)] = next_left;
            next_left += 1;
            try b.updateNeighbors(max_node);
            unprocessed_node_count -= 1;
        }
    }

    const shift_base: i32 = @intCast(nodes.len + 1);
    for (b.mark) |*m| {
        if (m.* < 0) m.* += shift_base;
    }

    for (nodes) |node| {
        const ports = try a.dupe(*lg.LPort, node.ports.items);
        for (ports) |port| {
            const outgoing = try a.dupe(*lg.LEdge, port.outgoing.items);
            for (outgoing) |edge| {
                const target_ix: usize = @intCast(edge.target.?.owner.?.id);
                if (b.mark[@intCast(node.id)] > b.mark[target_ix]) {
                    try gu.reverseEdge(edge);
                    g.p.cyclic = true;
                }
            }
        }
    }
}
