// DepthFirstCycleBreaker. Reads: layerless_nodes, LNode.id (overwritten as index). Writes: LEdge.p.reversed
// (via reverseEdge), LGraph.p.cyclic. Followed by intermediate/reversed_edge_restorer after P5.
const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

const State = struct {
    visited: []bool,
    active: []bool,
    edges_to_be_reversed: std.ArrayList(*lg.LEdge) = .empty,

    fn dfs(self: *State, a: std.mem.Allocator, n: *lg.LNode) lg.Error!void {
        const id: usize = @intCast(n.id);
        if (self.visited[id]) return;
        self.visited[id] = true;
        self.active[id] = true;
        for (n.ports.items) |port| {
            for (port.outgoing.items) |out| {
                if (out.isSelfLoop()) continue;
                const target = out.target.?.owner.?;
                if (self.active[@intCast(target.id)]) {
                    try self.edges_to_be_reversed.append(a, out);
                } else {
                    try self.dfs(a, target);
                }
            }
        }
        self.active[id] = false;
    }
};

fn hasIncoming(n: *const lg.LNode) bool {
    for (n.ports.items) |p| if (p.incoming.items.len > 0) return true;
    return false;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    const nodes = g.layerless_nodes.items;
    const node_count = nodes.len;

    var st: State = .{ .visited = try a.alloc(bool, node_count), .active = try a.alloc(bool, node_count) };
    @memset(st.visited, false);
    @memset(st.active, false);

    var sources: std.ArrayList(*lg.LNode) = .empty;
    for (nodes, 0..) |node, index| {
        node.id = @intCast(index);
        if (!hasIncoming(node)) try sources.append(a, node);
    }

    for (sources.items) |source| try st.dfs(a, source);

    for (0..node_count) |i| {
        if (!st.visited[i]) try st.dfs(a, nodes[i]);
    }

    for (st.edges_to_be_reversed.items) |edge| {
        try gu.reverseEdge(edge);
        g.p.cyclic = true;
    }
}
