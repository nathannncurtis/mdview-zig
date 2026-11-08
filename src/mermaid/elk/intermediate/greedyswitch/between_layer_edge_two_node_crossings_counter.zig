const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const cmu = @import("../../p3order/counting/cross_min_util.zig");

const Adjacency = struct {
    position: i32,
    cardinality: i32 = 1,
    current_cardinality: i32 = 1,

    fn compareTo(_: void, self: Adjacency, o: Adjacency) lg.Error!i32 {
        return if (self.position < o.position) -1 else if (self.position == o.position) 0 else 1;
    }
};

const AdjacencyList = struct {
    list: std.ArrayList(Adjacency) = .empty,
    size: i32 = 0,
    current_size: i32 = 0,
    current_index: usize = 0,

    fn reset(self: *AdjacencyList) void {
        self.current_index = 0;
        self.current_size = self.size;
        if (!self.isEmpty()) self.current().current_cardinality = self.current().cardinality;
    }
    fn countAdjacenciesBelowNodeOfFirstPort(self: *AdjacencyList) i32 {
        return self.current_size - self.current().current_cardinality;
    }
    fn removeFirst(self: *AdjacencyList) void {
        if (self.isEmpty()) return;
        const entry = self.current();
        if (entry.current_cardinality == 1) {
            self.current_index += 1;
            if (self.current_index < self.list.items.len) self.current().current_cardinality = self.current().cardinality;
        } else {
            entry.current_cardinality -= 1;
        }
        self.current_size -= 1;
    }
    fn isEmpty(self: *const AdjacencyList) bool {
        return self.current_size == 0;
    }
    fn first(self: *AdjacencyList) i32 {
        return self.current().position;
    }
    fn current(self: *AdjacencyList) *Adjacency {
        return &self.list.items[self.current_index];
    }
};

const NodeMap = std.AutoHashMapUnmanaged(*lg.LNode, *AdjacencyList);

pub const BetweenLayerEdgeTwoNodeCrossingsCounter = struct {
    a: std.mem.Allocator,
    upper_lower_crossings: i32 = 0,
    lower_upper_crossings: i32 = 0,
    upper: *AdjacencyList,
    lower: *AdjacencyList,
    current_node_order: [][]*lg.LNode,
    free_layer_index: usize,
    port_positions: std.AutoHashMapUnmanaged(*lg.LPort, i32) = .empty,
    eastern_adjacencies: NodeMap = .empty,
    western_adjacencies: NodeMap = .empty,

    pub fn create(a: std.mem.Allocator, order: [][]*lg.LNode, free_layer_index: usize) lg.Error!*BetweenLayerEdgeTwoNodeCrossingsCounter {
        const self = try a.create(BetweenLayerEdgeTwoNodeCrossingsCounter);
        self.* = .{
            .a = a,
            .current_node_order = order,
            .free_layer_index = free_layer_index,
            // SAFETY: assigned before each count
            .upper = undefined,
            // SAFETY: assigned before first use
            .lower = undefined,
        };
        if (free_layer_index > 0) try self.setPortPositionsForLayer(free_layer_index - 1, .east);
        if (free_layer_index + 1 < order.len) try self.setPortPositionsForLayer(free_layer_index + 1, .west);
        return self;
    }

    fn setPortPositionsForLayer(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, layer_index: usize, side: lg.PortSide) lg.Error!void {
        var port_id: i32 = 0;
        for (self.current_node_order[layer_index]) |node| {
            const seq = cmu.inNorthSouthEastWestOrder(node, side);
            for (0..seq.len()) |i| {
                try self.port_positions.put(self.a, seq.get(i), port_id);
                port_id += 1;
            }
        }
    }

    pub fn countEasternEdgeCrossings(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, upper: *lg.LNode, lower: *lg.LNode) lg.Error!void {
        self.resetCrossingCount();
        if (upper == lower) return;
        try self.addCrossings(upper, lower, .east);
    }

    pub fn countWesternEdgeCrossings(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, upper: *lg.LNode, lower: *lg.LNode) lg.Error!void {
        self.resetCrossingCount();
        if (upper == lower) return;
        try self.addCrossings(upper, lower, .west);
    }

    pub fn countBothSideCrossings(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, upper: *lg.LNode, lower: *lg.LNode) lg.Error!void {
        self.resetCrossingCount();
        if (upper == lower) return;
        try self.addCrossings(upper, lower, .west);
        try self.addCrossings(upper, lower, .east);
    }

    fn resetCrossingCount(self: *BetweenLayerEdgeTwoNodeCrossingsCounter) void {
        self.upper_lower_crossings = 0;
        self.lower_upper_crossings = 0;
    }

    fn addCrossings(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, upper: *lg.LNode, lower: *lg.LNode, side: lg.PortSide) lg.Error!void {
        const map = if (side == .east) &self.eastern_adjacencies else &self.western_adjacencies;
        self.upper = try self.getAdjacencyFor(upper, side, map);
        self.lower = try self.getAdjacencyFor(lower, side, map);
        if (self.upper.current_size == 0 or self.lower.current_size == 0) return;
        self.countCrossingsByMergingAdjacencyLists();
    }

    fn getAdjacencyFor(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, node: *lg.LNode, side: lg.PortSide, map: *NodeMap) lg.Error!*AdjacencyList {
        if (map.count() == 0) {
            for (self.current_node_order[self.free_layer_index]) |n| {
                try map.put(self.a, n, try self.buildAdjacencyList(n, side));
            }
        }
        const al = map.get(node).?;
        al.reset();
        return al;
    }

    fn buildAdjacencyList(self: *BetweenLayerEdgeTwoNodeCrossingsCounter, node: *lg.LNode, side: lg.PortSide) lg.Error!*AdjacencyList {
        const al = try self.a.create(AdjacencyList);
        al.* = .{};
        const seq = cmu.inNorthSouthEastWestOrder(node, side);
        for (0..seq.len()) |i| {
            const port = seq.get(i);
            const edges = if (side == .west) port.incoming.items else port.outgoing.items;
            for (edges) |edge| {
                if (edge.isSelfLoop() or edge.source.?.owner.?.layer == edge.target.?.owner.?.layer) continue;
                const adjacent = if (side == .west) edge.source.? else edge.target.?;
                const pos = self.port_positions.get(adjacent) orelse 0;
                const n = al.list.items.len;
                if (n != 0 and al.list.items[n - 1].position == pos) {
                    al.list.items[n - 1].cardinality += 1;
                    al.list.items[n - 1].current_cardinality += 1;
                } else {
                    try al.list.append(self.a, .{ .position = pos });
                }
                al.size += 1;
                al.current_size += 1;
            }
        }
        try util.javaSort(Adjacency, self.a, al.list.items, {}, Adjacency.compareTo);
        return al;
    }

    fn countCrossingsByMergingAdjacencyLists(self: *BetweenLayerEdgeTwoNodeCrossingsCounter) void {
        const up = self.upper;
        const lo = self.lower;
        while (!up.isEmpty() and !lo.isEmpty()) {
            if (up.first() > lo.first()) {
                self.upper_lower_crossings += up.current_size;
                lo.removeFirst();
            } else if (lo.first() > up.first()) {
                self.lower_upper_crossings += lo.current_size;
                up.removeFirst();
            } else {
                self.upper_lower_crossings += up.countAdjacenciesBelowNodeOfFirstPort();
                self.lower_upper_crossings += lo.countAdjacenciesBelowNodeOfFirstPort();
                up.removeFirst();
                lo.removeFirst();
            }
        }
    }
};
