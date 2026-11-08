const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const spacings = @import("../../spacings.zig");
const BKAlignedLayout = @import("bk_aligned_layout.zig").BKAlignedLayout;
const NeighborhoodInformation = @import("neighborhood_information.zig").NeighborhoodInformation;
const ThresholdStrategy = @import("threshold_strategy.zig").ThresholdStrategy;

fn ix(n: *const lg.LNode) usize {
    return @intCast(n.id);
}

const ClassEdge = struct { separation: f64, target: *ClassNode };

const ClassNode = struct {
    class_shift: ?f64 = null,
    node: *lg.LNode,
    outgoing: std.ArrayList(ClassEdge) = .empty,
    indegree: i32 = 0,

    fn addEdge(self: *ClassNode, a: std.mem.Allocator, target: *ClassNode, separation: f64) lg.Error!void {
        target.indegree += 1;
        try self.outgoing.append(a, .{ .separation = separation, .target = target });
    }
};

// BKCompactor
pub const BKCompactor = struct {
    a: std.mem.Allocator,
    layered_graph: *lg.LGraph,
    thresh_strategy: ThresholdStrategy,
    ni: *const NeighborhoodInformation,
    sink_nodes: std.ArrayList(*ClassNode) = .empty,
    sink_node_of: []?*ClassNode,

    pub fn init(a: std.mem.Allocator, layered_graph: *lg.LGraph, ni: *const NeighborhoodInformation) lg.Error!BKCompactor {
        const map = try a.alloc(?*ClassNode, ni.node_count);
        @memset(map, null);
        return .{
            .a = a,
            .layered_graph = layered_graph,
            .thresh_strategy = .{ .a = a, .simple = layered_graph.p.bk_edge_straightening },
            .ni = ni,
            .sink_node_of = map,
        };
    }

    pub fn horizontalCompaction(self: *BKCompactor, bal: *BKAlignedLayout) lg.Error!void {
        for (self.layered_graph.layers.items) |layer| {
            for (layer.nodes.items) |node| {
                bal.sink[ix(node)] = node;
                bal.shift[ix(node)] = if (bal.vdir == .up) -std.math.inf(f64) else std.math.inf(f64);
            }
        }
        self.sink_nodes.clearRetainingCapacity();
        @memset(self.sink_node_of, null);
        const layers = self.layered_graph.layers.items;
        try self.thresh_strategy.init(bal, self.ni);
        @memset(bal.y, null);
        for (0..layers.len) |li| {
            const layer = if (bal.hdir == .left) layers[layers.len - 1 - li] else layers[li];
            const nodes = layer.nodes.items;
            for (0..nodes.len) |ki| {
                const v = if (bal.vdir == .up) nodes[nodes.len - 1 - ki] else nodes[ki];
                if (bal.root[ix(v)] == v) try self.placeBlock(v, bal);
            }
        }
        try self.placeClasses(bal);
        for (0..layers.len) |li| {
            const layer = if (bal.hdir == .left) layers[layers.len - 1 - li] else layers[li];
            for (layer.nodes.items) |v| {
                bal.y[ix(v)] = bal.y[ix(bal.root[ix(v)])];
                if (v == bal.root[ix(v)]) {
                    const sink_shift = bal.shift[ix(bal.sink[ix(v)])];
                    if ((bal.vdir == .up and sink_shift > -std.math.inf(f64)) or (bal.vdir == .down and sink_shift < std.math.inf(f64))) {
                        bal.y[ix(v)] = bal.y[ix(v)].? + sink_shift;
                    }
                }
            }
        }
        try self.thresh_strategy.postProcess();
    }

    fn placeBlock(self: *BKCompactor, root: *lg.LNode, bal: *BKAlignedLayout) lg.Error!void {
        if (bal.y[ix(root)] != null) return;
        var is_initial_assignment = true;
        bal.y[ix(root)] = 0.0;
        var current_node = root;
        var thresh = if (bal.vdir == .down) -std.math.inf(f64) else std.math.inf(f64);
        while (true) {
            const current_index_in_layer = self.ni.nodeIndex(current_node);
            const layer_nodes = current_node.layer.?.nodes.items;
            if ((bal.vdir == .down and current_index_in_layer > 0) or (bal.vdir == .up and current_index_in_layer + 1 < layer_nodes.len)) {
                const neighbor = if (bal.vdir == .up) layer_nodes[current_index_in_layer + 1] else layer_nodes[current_index_in_layer - 1];
                const neighbor_root = bal.root[ix(neighbor)];
                try self.placeBlock(neighbor_root, bal);
                thresh = try self.thresh_strategy.calculateThreshold(thresh, root, current_node);
                if (bal.sink[ix(root)] == root) bal.sink[ix(root)] = bal.sink[ix(neighbor_root)];
                if (bal.sink[ix(root)] == bal.sink[ix(neighbor_root)]) {
                    const spacing = spacings.getVerticalSpacing(current_node, neighbor);
                    const current_block_position = bal.y[ix(root)].?;
                    if (bal.vdir == .up) {
                        const new_position = bal.y[ix(neighbor_root)].? + bal.inner_shift[ix(neighbor)] - neighbor.margin.top - spacing -
                            current_node.margin.bottom - current_node.size.y - bal.inner_shift[ix(current_node)];
                        if (is_initial_assignment) {
                            is_initial_assignment = false;
                            bal.y[ix(root)] = util.javaMin(new_position, thresh);
                        } else {
                            bal.y[ix(root)] = util.javaMin(current_block_position, util.javaMin(new_position, thresh));
                        }
                    } else {
                        const new_position = bal.y[ix(neighbor_root)].? + bal.inner_shift[ix(neighbor)] + neighbor.size.y + neighbor.margin.bottom +
                            spacing + current_node.margin.top - bal.inner_shift[ix(current_node)];
                        if (is_initial_assignment) {
                            is_initial_assignment = false;
                            bal.y[ix(root)] = util.javaMax(new_position, thresh);
                        } else {
                            bal.y[ix(root)] = util.javaMax(current_block_position, util.javaMax(new_position, thresh));
                        }
                    }
                } else {
                    const spacing = self.layered_graph.p.spacing.node_node;
                    const sink_node = try self.getOrCreateClassNode(bal.sink[ix(root)]);
                    const neighbor_sink = try self.getOrCreateClassNode(bal.sink[ix(neighbor_root)]);
                    if (bal.vdir == .up) {
                        const required_space = bal.y[ix(root)].? + bal.inner_shift[ix(current_node)] + current_node.size.y + current_node.margin.bottom +
                            spacing - (bal.y[ix(neighbor_root)].? + bal.inner_shift[ix(neighbor)] - neighbor.margin.top);
                        try sink_node.addEdge(self.a, neighbor_sink, required_space);
                    } else {
                        const required_space = bal.y[ix(root)].? + bal.inner_shift[ix(current_node)] - current_node.margin.top - bal.y[ix(neighbor_root)].? -
                            bal.inner_shift[ix(neighbor)] - neighbor.size.y - neighbor.margin.bottom - spacing;
                        try sink_node.addEdge(self.a, neighbor_sink, required_space);
                    }
                }
            } else {
                thresh = try self.thresh_strategy.calculateThreshold(thresh, root, current_node);
            }
            current_node = bal.align_[ix(current_node)];
            if (current_node == root) break;
        }
        self.thresh_strategy.finishBlock(root);
    }

    // The result does not depend on the order of the Java HashMap: every class is final before it is polled.
    fn placeClasses(self: *BKCompactor, bal: *BKAlignedLayout) lg.Error!void {
        var sinks: std.ArrayList(*ClassNode) = .empty;
        for (self.sink_nodes.items) |n| if (n.indegree == 0) try sinks.append(self.a, n);
        var head: usize = 0;
        while (head < sinks.items.len) {
            const n = sinks.items[head];
            head += 1;
            if (n.class_shift == null) n.class_shift = 0;
            for (n.outgoing.items) |e| {
                const cand = n.class_shift.? + e.separation;
                if (e.target.class_shift) |cs| {
                    e.target.class_shift = if (bal.vdir == .down) util.javaMin(cs, cand) else util.javaMax(cs, cand);
                } else {
                    e.target.class_shift = cand;
                }
                e.target.indegree -= 1;
                if (e.target.indegree == 0) try sinks.append(self.a, e.target);
            }
        }
        for (self.sink_nodes.items) |n| {
            if (n.class_shift) |cs| bal.shift[ix(n.node)] = cs;
        }
    }

    fn getOrCreateClassNode(self: *BKCompactor, sink_node: *lg.LNode) lg.Error!*ClassNode {
        if (self.sink_node_of[ix(sink_node)]) |n| return n;
        const node = try self.a.create(ClassNode);
        node.* = .{ .node = sink_node };
        self.sink_node_of[ix(sink_node)] = node;
        try self.sink_nodes.append(self.a, node);
        return node;
    }
};
