const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const bal_mod = @import("bk_aligned_layout.zig");
const BKAlignedLayout = bal_mod.BKAlignedLayout;
const NeighborhoodInformation = @import("neighborhood_information.zig").NeighborhoodInformation;

fn ix(n: *const lg.LNode) usize {
    return @intCast(n.id);
}

// BKNodePlacer.getEdge
pub fn getEdge(source: *lg.LNode, target: *lg.LNode) ?*lg.LEdge {
    for (source.ports.items) |port| {
        for ([2][]*lg.LEdge{ port.incoming.items, port.outgoing.items }) |edges| {
            for (edges) |edge| {
                if (edge.target.?.owner.? == target or edge.source.?.owner.? == target) return edge;
            }
        }
    }
    return null;
}

// BKNodePlacer.getBlocks key order: block roots in order of their first member in layer order
pub fn blockRoots(a: std.mem.Allocator, bal: *const BKAlignedLayout) lg.Error![]*lg.LNode {
    const seen = try a.alloc(bool, bal.root.len);
    @memset(seen, false);
    var roots: std.ArrayList(*lg.LNode) = .empty;
    for (bal.layered_graph.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            const root = bal.root[ix(node)];
            if (!seen[ix(root)]) {
                seen[ix(root)] = true;
                try roots.append(a, root);
            }
        }
    }
    return roots.items;
}

// BKAligner
pub const BKAligner = struct {
    layered_graph: *lg.LGraph,
    ni: *const NeighborhoodInformation,

    pub fn verticalAlignment(self: *const BKAligner, bal: *BKAlignedLayout, marked_edges: *const std.AutoHashMapUnmanaged(*lg.LEdge, void)) void {
        for (self.layered_graph.layers.items) |layer| {
            for (layer.nodes.items) |v| {
                bal.root[ix(v)] = v;
                bal.align_[ix(v)] = v;
                bal.inner_shift[ix(v)] = 0.0;
            }
        }
        const layers = self.layered_graph.layers.items;
        const ni = self.ni;
        for (0..layers.len) |li| {
            const layer = if (bal.hdir == .left) layers[layers.len - 1 - li] else layers[li];
            var r: i64 = -1;
            const nodes = layer.nodes.items;
            if (bal.vdir == .up) r = std.math.maxInt(i32);
            for (0..nodes.len) |ki| {
                const v_i_k = if (bal.vdir == .up) nodes[nodes.len - 1 - ki] else nodes[ki];
                const neighbors = if (bal.hdir == .left) ni.right_neighbors[ix(v_i_k)] else ni.left_neighbors[ix(v_i_k)];
                if (neighbors.len == 0) continue;
                const d: f64 = @floatFromInt(neighbors.len);
                const low: i64 = @as(i64, @intFromFloat(@floor((d + 1.0) / 2.0))) - 1;
                const high: i64 = @as(i64, @intFromFloat(@ceil((d + 1.0) / 2.0))) - 1;
                if (bal.vdir == .up) {
                    var m = high;
                    while (m >= low) : (m -= 1) {
                        if (bal.align_[ix(v_i_k)] == v_i_k) {
                            const u_m_pair = neighbors[@intCast(m)];
                            const u_m = u_m_pair.node;
                            const u_idx: i64 = @intCast(ni.nodeIndex(u_m));
                            if (!marked_edges.contains(u_m_pair.edge) and r > u_idx) {
                                bal.align_[ix(u_m)] = v_i_k;
                                bal.root[ix(v_i_k)] = bal.root[ix(u_m)];
                                bal.align_[ix(v_i_k)] = bal.root[ix(v_i_k)];
                                const rid = ix(bal.root[ix(v_i_k)]);
                                bal.od[rid] = bal.od[rid] and v_i_k.type == .long_edge;
                                r = u_idx;
                            }
                        }
                    }
                } else {
                    var m = low;
                    while (m <= high) : (m += 1) {
                        if (bal.align_[ix(v_i_k)] == v_i_k) {
                            const um_pair = neighbors[@intCast(m)];
                            const um = um_pair.node;
                            const u_idx: i64 = @intCast(ni.nodeIndex(um));
                            if (!marked_edges.contains(um_pair.edge) and r < u_idx) {
                                bal.align_[ix(um)] = v_i_k;
                                bal.root[ix(v_i_k)] = bal.root[ix(um)];
                                bal.align_[ix(v_i_k)] = bal.root[ix(v_i_k)];
                                const rid = ix(bal.root[ix(v_i_k)]);
                                bal.od[rid] = bal.od[rid] and v_i_k.type == .long_edge;
                                r = u_idx;
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn insideBlockShift(_: *const BKAligner, a: std.mem.Allocator, bal: *BKAlignedLayout) lg.Error!void {
        const roots = try blockRoots(a, bal);
        for (roots) |root| {
            var space_above: f64 = root.margin.top;
            var space_below: f64 = root.size.y + root.margin.bottom;
            bal.inner_shift[ix(root)] = 0.0;
            var current = root;
            while (true) {
                const next = bal.align_[ix(current)];
                if (next == root) break;
                const edge = getEdge(current, next).?;
                const port_pos_diff = if (bal.hdir == .left)
                    edge.target.?.pos.y + edge.target.?.anchor.y - edge.source.?.pos.y - edge.source.?.anchor.y
                else
                    edge.source.?.pos.y + edge.source.?.anchor.y - edge.target.?.pos.y - edge.target.?.anchor.y;
                const next_inner_shift = bal.inner_shift[ix(current)] + port_pos_diff;
                bal.inner_shift[ix(next)] = next_inner_shift;
                space_above = util.javaMax(space_above, next.margin.top - next_inner_shift);
                space_below = util.javaMax(space_below, next_inner_shift + next.size.y + next.margin.bottom);
                current = next;
            }
            current = root;
            while (true) {
                bal.inner_shift[ix(current)] = bal.inner_shift[ix(current)] + space_above;
                current = bal.align_[ix(current)];
                if (current == root) break;
            }
            bal.block_size[ix(root)] = space_above + space_below;
        }
    }
};
