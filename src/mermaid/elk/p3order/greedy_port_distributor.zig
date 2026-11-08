const std = @import("std");
const lg = @import("../lgraph.zig");
const graph_util = @import("../graph_util.zig");
const CrossingsCounter = @import("counting/crossings_counter.zig").CrossingsCounter;
const cmu = @import("counting/cross_min_util.zig");
const BetweenLayerEdgeTwoNodeCrossingsCounter = @import("../intermediate/greedyswitch/between_layer_edge_two_node_crossings_counter.zig").BetweenLayerEdgeTwoNodeCrossingsCounter;

pub const GreedyPortDistributor = struct {
    a: std.mem.Allocator,
    crossings_counter: CrossingsCounter = undefined,
    n_ports: i32 = 0,
    hierarchical_crossings_counter: ?*BetweenLayerEdgeTwoNodeCrossingsCounter = null,

    pub fn create(a: std.mem.Allocator) lg.Error!*GreedyPortDistributor {
        const self = try a.create(GreedyPortDistributor);
        self.* = .{ .a = a };
        return self;
    }

    pub fn distributePortsWhileSweeping(self: *GreedyPortDistributor, order: [][]*lg.LNode, current: usize, forward: bool) lg.Error!bool {
        if (forward and current > 0) {
            try self.crossings_counter.initForCountingBetween(order[current - 1], order[current]);
        } else if (!forward and current < order.len - 1) {
            try self.crossings_counter.initForCountingBetween(order[current], order[current + 1]);
        } else {
            _ = try self.crossings_counter.initPortPositionsForInLayerCrossings(order[current], if (forward) .west else .east);
        }
        const side: lg.PortSide = if (forward) .west else .east;
        var improved = false;
        for (order[current]) |node| {
            if (node.p.port_constraints.isOrderFixed()) continue;
            const use_hierarchical = node.portSideView(side).len != 0 and node.nested_graph != null;
            if (use_hierarchical) {
                const inner = try graph_util.toNodeArray(node.nested_graph.?);
                self.hierarchical_crossings_counter = try BetweenLayerEdgeTwoNodeCrossingsCounter.create(self.a, inner, if (forward) 0 else inner.len - 1);
            }
            if (try self.distributePortsOnNode(node, side, use_hierarchical)) improved = true;
        }
        return improved;
    }

    fn distributePortsOnNode(self: *GreedyPortDistributor, node: *lg.LNode, side: lg.PortSide, use_hierarchical: bool) lg.Error!bool {
        const ports: cmu.PortSeq = .{ .items = node.portSideView(side), .reversed = side == .south or side == .west };
        var improved = false;
        var continue_switching = true;
        while (continue_switching) {
            continue_switching = false;
            var i: usize = 0;
            while (i + 1 < ports.len()) : (i += 1) {
                if (try self.switchingDecreasesCrossings(ports.get(i), ports.get(i + 1), use_hierarchical)) {
                    improved = true;
                    self.crossings_counter.switchPorts(ports.get(i), ports.get(i + 1));
                    const lower = ports.get(i + 1);
                    ports.set(i + 1, ports.get(i));
                    ports.set(i, lower);
                    continue_switching = true;
                }
            }
        }
        return improved;
    }

    fn switchingDecreasesCrossings(self: *GreedyPortDistributor, upper: *lg.LPort, lower: *lg.LPort, use_hierarchical: bool) lg.Error!bool {
        const both = try self.crossings_counter.countCrossingsBetweenPortsInBothOrders(upper, lower);
        var upper_lower = both.first;
        var lower_upper = both.second;
        if (use_hierarchical) {
            if (upper.p.port_dummy) |upper_node| {
                if (lower.p.port_dummy) |lower_node| {
                    const hc = self.hierarchical_crossings_counter.?;
                    try hc.countBothSideCrossings(upper_node, lower_node);
                    upper_lower += hc.upper_lower_crossings;
                    lower_upper += hc.lower_upper_crossings;
                }
            }
        }
        return upper_lower > lower_upper;
    }

    pub fn initAtNodeLevel(self: *GreedyPortDistributor, l: usize, n: usize, order: [][]*lg.LNode) void {
        self.n_ports += @intCast(order[l][n].ports.items.len);
    }

    pub fn initAfterTraversal(self: *GreedyPortDistributor) lg.Error!void {
        const port_pos = try self.a.alloc(i32, @intCast(self.n_ports));
        @memset(port_pos, 0);
        self.crossings_counter = CrossingsCounter.init(self.a, port_pos);
    }
};
