// Port of org.eclipse.elk.alg.common.networksimplex: NGraph, NNode, NEdge, NetworkSimplex.
// Props: none (works on its own graph; NNode.origin points back at the LNode).
const std = @import("std");
const lg = @import("lgraph.zig");
const Allocator = std.mem.Allocator;

pub const NNode = struct {
    id: i32 = 0,
    internal_id: usize = 0,
    origin: ?*lg.LNode = null,
    layer: i32 = 0,
    outgoing: std.ArrayList(*NEdge) = .empty,
    incoming: std.ArrayList(*NEdge) = .empty,
    // cached union of incoming and outgoing, rebuilt after either list changes (NNode.getConnectedEdges)
    all: std.ArrayList(*NEdge) = .empty,
    all_dirty: bool = true,
    tree_node: bool = false,
    unknown_cutvalues: std.ArrayList(*NEdge) = .empty,

    pub fn connected(self: *NNode, a: Allocator) Allocator.Error![]*NEdge {
        if (self.all_dirty) {
            self.all.clearRetainingCapacity();
            try self.all.appendSlice(a, self.incoming.items);
            try self.all.appendSlice(a, self.outgoing.items);
            self.all_dirty = false;
        }
        return self.all.items;
    }

    fn addOut(self: *NNode, a: Allocator, e: *NEdge) Allocator.Error!void {
        try self.outgoing.append(a, e);
        self.all_dirty = true;
    }
    fn addIn(self: *NNode, a: Allocator, e: *NEdge) Allocator.Error!void {
        try self.incoming.append(a, e);
        self.all_dirty = true;
    }
    fn removeOut(self: *NNode, e: *NEdge) void {
        lg.removeItem(NEdge, &self.outgoing, e);
        self.all_dirty = true;
    }
    fn removeIn(self: *NNode, e: *NEdge) void {
        lg.removeItem(NEdge, &self.incoming, e);
        self.all_dirty = true;
    }
};

pub const NEdge = struct {
    id: i32 = 0,
    internal_id: usize = 0,
    origin: ?*lg.LEdge = null,
    source: *NNode,
    target: *NNode,
    weight: f64 = 0,
    delta: i32 = 1,
    tree_edge: bool = false,

    pub fn other(self: *const NEdge, some: *const NNode) *NNode {
        if (some == self.source) return self.target;
        std.debug.assert(some == self.target);
        return self.source;
    }
};

pub const NGraph = struct {
    a: Allocator,
    nodes: std.ArrayList(*NNode) = .empty,

    pub fn init(a: Allocator) NGraph {
        return .{ .a = a };
    }

    pub fn createNode(self: *NGraph, origin: ?*lg.LNode) Allocator.Error!*NNode {
        const n = try self.a.create(NNode);
        n.* = .{ .origin = origin };
        try self.nodes.append(self.a, n);
        return n;
    }

    // NEdgeBuilder.create; self loops are rejected by callers in ELK too
    pub fn createEdge(self: *NGraph, origin: ?*lg.LEdge, source: *NNode, target: *NNode, weight: f64, delta: i32) Allocator.Error!*NEdge {
        std.debug.assert(source != target);
        const e = try self.a.create(NEdge);
        e.* = .{ .origin = origin, .source = source, .target = target, .weight = weight, .delta = delta };
        try source.addOut(self.a, e);
        try target.addIn(self.a, e);
        return e;
    }
};

const remove_subtrees_thresh = 40;
const fuzzy_st_zero: f64 = -1e-10;

const Leafy = struct { node: *NNode, edge: *NEdge };

pub const NetworkSimplex = struct {
    a: Allocator,
    graph: *NGraph,
    previous_layering_node_counts: ?[]const i32 = null,
    balance_layers: bool = false,
    iteration_limit: i32 = std.math.maxInt(i32),

    edges: []*NEdge = &.{},
    tree_edges: std.ArrayList(*NEdge) = .empty,
    sources: std.ArrayList(*NNode) = .empty,
    edge_visited: []bool = &.{},
    post_order: i32 = 1,
    po_id: []i32 = &.{},
    lowest_po_id: []i32 = &.{},
    cutvalue: []f64 = &.{},
    subtree_nodes_stack: std.ArrayList(Leafy) = .empty,

    pub fn forGraph(graph: *NGraph) NetworkSimplex {
        return .{ .a = graph.a, .graph = graph };
    }

    fn initialize(self: *NetworkSimplex) Allocator.Error!void {
        const a = self.a;
        const num_nodes = self.graph.nodes.items.len;
        for (self.graph.nodes.items) |n| n.tree_node = false;
        self.po_id = try a.alloc(i32, num_nodes);
        @memset(self.po_id, 0);
        self.lowest_po_id = try a.alloc(i32, num_nodes);
        @memset(self.lowest_po_id, 0);
        self.sources = .empty;

        var the_edges: std.ArrayList(*NEdge) = .empty;
        for (self.graph.nodes.items, 0..) |node, index| {
            node.internal_id = index;
            if (node.incoming.items.len == 0) try self.sources.append(a, node);
            try the_edges.appendSlice(a, node.outgoing.items);
        }
        for (the_edges.items, 0..) |edge, counter| {
            edge.internal_id = counter;
            edge.tree_edge = false;
        }
        const num_edges = the_edges.items.len;
        self.cutvalue = try a.alloc(f64, num_edges);
        @memset(self.cutvalue, 0);
        self.edge_visited = try a.alloc(bool, num_edges);
        @memset(self.edge_visited, false);
        self.edges = the_edges.items;
        self.tree_edges = .empty;
        self.post_order = 1;
    }

    pub fn execute(self: *NetworkSimplex) Allocator.Error!void {
        if (self.graph.nodes.items.len < 1) return;
        for (self.graph.nodes.items) |node| node.layer = 0;

        const remove_subtrees = self.graph.nodes.items.len >= remove_subtrees_thresh;
        if (remove_subtrees) try self.removeSubtrees();

        try self.initialize();
        try self.feasibleTree();
        var e = self.leaveEdge();
        var iter: i32 = 0;
        while (e) |leave| {
            if (iter >= self.iteration_limit) break;
            try self.exchange(leave, self.enterEdge(leave).?);
            e = self.leaveEdge();
            iter += 1;
        }

        if (remove_subtrees) try self.reattachSubtrees();

        if (self.balance_layers) {
            try self.balance(try self.normalize());
        } else {
            _ = try self.normalize();
        }
    }

    fn removeSubtrees(self: *NetworkSimplex) Allocator.Error!void {
        const a = self.a;
        self.subtree_nodes_stack = .empty;

        var leafs: std.ArrayList(*NNode) = .empty;
        var head: usize = 0;
        for (self.graph.nodes.items) |node| {
            if ((try node.connected(a)).len == 1) try leafs.append(a, node);
        }

        while (head < leafs.items.len) {
            const node = leafs.items[head];
            head += 1;
            const conn = try node.connected(a);
            if (conn.len == 0) continue;
            const edge = conn[0];
            const is_out_edge = node.outgoing.items.len > 0;

            const other = edge.other(node);
            if (is_out_edge) other.removeIn(edge) else other.removeOut(edge);

            if ((try other.connected(a)).len == 1) try leafs.append(a, other);

            try self.subtree_nodes_stack.append(a, .{ .node = node, .edge = edge });
            lg.removeItem(NNode, &self.graph.nodes, node);
        }
    }

    fn reattachSubtrees(self: *NetworkSimplex) Allocator.Error!void {
        const a = self.a;
        while (self.subtree_nodes_stack.pop()) |leafy| {
            const node = leafy.node;
            const edge = leafy.edge;
            const placed = edge.other(node);
            if (edge.target == node) {
                try placed.addOut(a, edge);
                node.layer = placed.layer + edge.delta;
            } else {
                try placed.addIn(a, edge);
                node.layer = placed.layer - edge.delta;
            }
            try self.graph.nodes.append(a, node);
        }
    }

    fn feasibleTree(self: *NetworkSimplex) Allocator.Error!void {
        try self.layeringTopologicalNumbering(self.sources.items);

        if (self.edges.len > 0) {
            @memset(self.edge_visited, false);
            while (try self.tightTreeDFS(self.graph.nodes.items[0]) < self.graph.nodes.items.len) {
                const e = self.minimalSlack().?;
                var slack = e.target.layer - e.source.layer - e.delta;
                if (e.target.tree_node) slack = -slack;
                for (self.graph.nodes.items) |node| {
                    if (node.tree_node) node.layer += slack;
                }
                @memset(self.edge_visited, false);
            }
            @memset(self.edge_visited, false);
            _ = try self.postorderTraversal(self.graph.nodes.items[0]);
            try self.cutvalues();
        }
    }

    fn layeringTopologicalNumbering(self: *NetworkSimplex, initial_root_nodes: []const *NNode) Allocator.Error!void {
        const a = self.a;
        const incident = try a.alloc(i32, self.graph.nodes.items.len);
        @memset(incident, 0);
        for (self.graph.nodes.items) |node| {
            incident[node.internal_id] += @intCast(node.incoming.items.len);
        }

        var roots: std.ArrayList(*NNode) = .empty;
        try roots.appendSlice(a, initial_root_nodes);
        var head: usize = 0;
        while (head < roots.items.len) {
            const node = roots.items[head];
            head += 1;
            for (node.outgoing.items) |edge| {
                const target = edge.target;
                target.layer = @max(target.layer, node.layer + edge.delta);
                incident[target.internal_id] -= 1;
                if (incident[target.internal_id] == 0) try roots.append(a, target);
            }
        }
    }

    const Span = struct { in: i32, out: i32 };

    // the else-branch also takes incoming edges whose span is not below minSpanIn; ELK does this too
    fn minimalSpan(self: *NetworkSimplex, node: *NNode) Allocator.Error!Span {
        var min_span_out: i32 = std.math.maxInt(i32);
        var min_span_in: i32 = std.math.maxInt(i32);
        for (try node.connected(self.a)) |edge| {
            const current_span = edge.target.layer - edge.source.layer;
            if (edge.target == node and current_span < min_span_in) {
                min_span_in = current_span;
            } else if (current_span < min_span_out) {
                min_span_out = current_span;
            }
        }
        if (min_span_in == std.math.maxInt(i32)) min_span_in = -1;
        if (min_span_out == std.math.maxInt(i32)) min_span_out = -1;
        return .{ .in = min_span_in, .out = min_span_out };
    }

    fn tightTreeDFS(self: *NetworkSimplex, node: *NNode) Allocator.Error!usize {
        var node_count: usize = 1;
        node.tree_node = true;
        for (try node.connected(self.a)) |edge| {
            if (!self.edge_visited[edge.internal_id]) {
                self.edge_visited[edge.internal_id] = true;
                const opposite = edge.other(node);
                if (edge.tree_edge) {
                    node_count += try self.tightTreeDFS(opposite);
                } else if (!opposite.tree_node and edge.delta == edge.target.layer - edge.source.layer) {
                    edge.tree_edge = true;
                    try self.tree_edges.append(self.a, edge);
                    node_count += try self.tightTreeDFS(opposite);
                }
            }
        }
        return node_count;
    }

    fn minimalSlack(self: *NetworkSimplex) ?*NEdge {
        var min_slack: i32 = std.math.maxInt(i32);
        var min_slack_edge: ?*NEdge = null;
        for (self.edges) |edge| {
            if (edge.source.tree_node != edge.target.tree_node) {
                const cur_slack = edge.target.layer - edge.source.layer - edge.delta;
                if (cur_slack < min_slack) {
                    min_slack = cur_slack;
                    min_slack_edge = edge;
                }
            }
        }
        return min_slack_edge;
    }

    fn postorderTraversal(self: *NetworkSimplex, node: *NNode) Allocator.Error!i32 {
        var lowest: i32 = std.math.maxInt(i32);
        for (try node.connected(self.a)) |edge| {
            if (edge.tree_edge and !self.edge_visited[edge.internal_id]) {
                self.edge_visited[edge.internal_id] = true;
                lowest = @min(lowest, try self.postorderTraversal(edge.other(node)));
            }
        }
        self.po_id[node.internal_id] = self.post_order;
        self.lowest_po_id[node.internal_id] = @min(lowest, self.post_order);
        self.post_order += 1;
        return self.lowest_po_id[node.internal_id];
    }

    fn isInHead(self: *const NetworkSimplex, node: *const NNode, edge: *const NEdge) bool {
        const s = edge.source.internal_id;
        const t = edge.target.internal_id;
        const n = node.internal_id;
        const po = self.po_id;
        const low = self.lowest_po_id;
        if (low[s] <= po[n] and po[n] <= po[s] and low[t] <= po[n] and po[n] <= po[t]) {
            return !(po[s] < po[t]);
        }
        return po[s] < po[t];
    }

    fn cutvalues(self: *NetworkSimplex) Allocator.Error!void {
        const a = self.a;
        var leafs: std.ArrayList(*NNode) = .empty;
        for (self.graph.nodes.items) |node| {
            var tree_edge_count: usize = 0;
            node.unknown_cutvalues.clearRetainingCapacity();
            for (try node.connected(a)) |edge| {
                if (edge.tree_edge) {
                    try node.unknown_cutvalues.append(a, edge);
                    tree_edge_count += 1;
                }
            }
            if (tree_edge_count == 1) try leafs.append(a, node);
        }

        const cv = self.cutvalue;
        for (leafs.items) |leaf| {
            var node = leaf;
            while (node.unknown_cutvalues.items.len == 1) {
                const to_determine = node.unknown_cutvalues.items[0];
                const td = to_determine.internal_id;
                cv[td] = to_determine.weight;
                const source = to_determine.source;
                const target = to_determine.target;
                for (try node.connected(a)) |edge| {
                    if (edge == to_determine) continue;
                    if (edge.tree_edge) {
                        if (source == edge.source or target == edge.target) {
                            cv[td] -= cv[edge.internal_id] - edge.weight;
                        } else {
                            cv[td] += cv[edge.internal_id] - edge.weight;
                        }
                    } else {
                        if (node == source) {
                            if (edge.source == node) cv[td] += edge.weight else cv[td] -= edge.weight;
                        } else {
                            if (edge.source == node) cv[td] -= edge.weight else cv[td] += edge.weight;
                        }
                    }
                }
                lg.removeItem(NEdge, &source.unknown_cutvalues, to_determine);
                lg.removeItem(NEdge, &target.unknown_cutvalues, to_determine);
                node = if (source == node) to_determine.target else to_determine.source;
            }
        }
    }

    fn leaveEdge(self: *NetworkSimplex) ?*NEdge {
        for (self.tree_edges.items) |edge| {
            if (edge.tree_edge and self.cutvalue[edge.internal_id] < fuzzy_st_zero) return edge;
        }
        return null;
    }

    fn enterEdge(self: *NetworkSimplex, leave: *NEdge) ?*NEdge {
        std.debug.assert(leave.tree_edge);
        var replace: ?*NEdge = null;
        var rep_slack: i32 = std.math.maxInt(i32);
        for (self.edges) |edge| {
            const source = edge.source;
            const target = edge.target;
            if (self.isInHead(source, leave) and !self.isInHead(target, leave)) {
                const slack = target.layer - source.layer - edge.delta;
                if (slack < rep_slack) {
                    rep_slack = slack;
                    replace = edge;
                }
            }
        }
        return replace;
    }

    fn exchange(self: *NetworkSimplex, leave: *NEdge, enter: *NEdge) Allocator.Error!void {
        std.debug.assert(leave.tree_edge and !enter.tree_edge);
        leave.tree_edge = false;
        lg.removeItem(NEdge, &self.tree_edges, leave);
        enter.tree_edge = true;
        try self.tree_edges.append(self.a, enter);
        var delta = enter.target.layer - enter.source.layer - enter.delta;
        if (!self.isInHead(enter.target, leave)) delta = -delta;
        for (self.graph.nodes.items) |node| {
            if (!self.isInHead(node, leave)) node.layer += delta;
        }

        self.post_order = 1;
        @memset(self.edge_visited, false);
        _ = try self.postorderTraversal(self.graph.nodes.items[0]);
        try self.cutvalues();
    }

    fn normalize(self: *NetworkSimplex) Allocator.Error![]i32 {
        var highest: i32 = std.math.minInt(i32);
        var lowest: i32 = std.math.maxInt(i32);
        for (self.graph.nodes.items) |node| {
            lowest = @min(lowest, node.layer);
            highest = @max(highest, node.layer);
        }
        const filling = try self.a.alloc(i32, @intCast(highest - lowest + 1));
        @memset(filling, 0);
        for (self.graph.nodes.items) |node| {
            node.layer -= lowest;
            filling[@intCast(node.layer)] += 1;
        }
        if (self.previous_layering_node_counts) |prev| {
            var layer_id: usize = 0;
            for (prev) |cnt| {
                filling[layer_id] += cnt;
                layer_id += 1;
                if (filling.len == layer_id) break;
            }
        }
        return filling;
    }

    fn balance(self: *NetworkSimplex, filling: []i32) Allocator.Error!void {
        for (self.graph.nodes.items) |node| {
            if (node.incoming.items.len == node.outgoing.items.len) {
                var new_layer = node.layer;
                const range = try self.minimalSpan(node);
                var i = node.layer - range.in + 1;
                while (i < node.layer + range.out) : (i += 1) {
                    if (filling[@intCast(i)] < filling[@intCast(new_layer)]) new_layer = i;
                }
                if (filling[@intCast(new_layer)] < filling[@intCast(node.layer)]) {
                    filling[@intCast(node.layer)] -= 1;
                    filling[@intCast(new_layer)] += 1;
                    node.layer = new_layer;
                }
            }
        }
    }
};
