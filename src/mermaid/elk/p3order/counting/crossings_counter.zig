const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const BinaryIndexedTree = @import("binary_indexed_tree.zig").BinaryIndexedTree;
const cmu = @import("cross_min_util.zig");

pub const Pair = struct { first: i32, second: i32 };

// LPort.getConnectedEdges: incoming, then outgoing
pub fn connectedEdge(p: *const lg.LPort, i: usize) *lg.LEdge {
    const n = p.incoming.items.len;
    return if (i < n) p.incoming.items[i] else p.outgoing.items[i - n];
}

pub const CrossingsCounter = struct {
    a: std.mem.Allocator,
    port_positions: []i32,
    index_tree: BinaryIndexedTree = .{ .binary_sums = &.{}, .nums_per_index = &.{} },
    ends: std.ArrayList(i32) = .empty,
    node_cardinalities: []i32 = &.{},

    pub fn init(a: std.mem.Allocator, port_positions: []i32) CrossingsCounter {
        return .{ .a = a, .port_positions = port_positions };
    }

    pub fn countCrossingsBetweenLayers(self: *CrossingsCounter, left: []*lg.LNode, right: []*lg.LNode) lg.Error!i32 {
        const ports = try self.initPortPositionsCounterClockwise(left, right);
        self.index_tree = try BinaryIndexedTree.init(self.a, ports.len);
        return self.countCrossingsOnPorts(ports);
    }

    pub fn countInLayerCrossingsOnSide(self: *CrossingsCounter, nodes: []*lg.LNode, side: lg.PortSide) lg.Error!i32 {
        const ports = try self.initPortPositionsForInLayerCrossings(nodes, side);
        return self.countInLayerCrossingsOnPorts(ports);
    }

    pub fn countCrossingsBetweenPortsInBothOrders(self: *CrossingsCounter, upper: *lg.LPort, lower: *lg.LPort) lg.Error!Pair {
        const ports = try self.connectedPortsSortedByPosition(upper, lower);
        const upper_lower = try self.countCrossingsOnPorts(ports);
        self.index_tree.clear();
        self.switchPorts(upper, lower);
        try util.javaSort(*lg.LPort, self.a, ports, self, cmpPosition);
        const lower_upper = try self.countCrossingsOnPorts(ports);
        self.index_tree.clear();
        self.switchPorts(lower, upper);
        return .{ .first = upper_lower, .second = lower_upper };
    }

    pub fn countInLayerCrossingsBetweenNodesInBothOrders(self: *CrossingsCounter, upper: *lg.LNode, lower: *lg.LNode, side: lg.PortSide) lg.Error!Pair {
        const ports = try self.connectedInLayerPortsSortedByPosition(upper, lower, side);
        const upper_lower = try self.countInLayerCrossingsOnPorts(ports);
        self.switchNodes(upper, lower, side);
        self.index_tree.clear();
        try util.javaSort(*lg.LPort, self.a, ports, self, cmpPosition);
        const lower_upper = try self.countInLayerCrossingsOnPorts(ports);
        self.switchNodes(lower, upper, side);
        self.index_tree.clear();
        return .{ .first = upper_lower, .second = lower_upper };
    }

    pub fn initForCountingBetween(self: *CrossingsCounter, left: []*lg.LNode, right: []*lg.LNode) lg.Error!void {
        const ports = try self.initPortPositionsCounterClockwise(left, right);
        self.index_tree = try BinaryIndexedTree.init(self.a, ports.len);
    }

    pub fn initPortPositionsForInLayerCrossings(self: *CrossingsCounter, nodes: []*lg.LNode, side: lg.PortSide) lg.Error![]*lg.LPort {
        var ports: std.ArrayList(*lg.LPort) = .empty;
        try self.initPositions(nodes, &ports, side, true, true);
        self.index_tree = try BinaryIndexedTree.init(self.a, ports.items.len);
        return ports.items;
    }

    pub fn switchPorts(self: *CrossingsCounter, top: *lg.LPort, bottom: *lg.LPort) void {
        const t = self.port_positions[idx(top.id)];
        self.port_positions[idx(top.id)] = self.port_positions[idx(bottom.id)];
        self.port_positions[idx(bottom.id)] = t;
    }

    pub fn switchNodes(self: *CrossingsCounter, was_upper: *lg.LNode, was_lower: *lg.LNode, side: lg.PortSide) void {
        var ports = cmu.inNorthSouthEastWestOrder(was_upper, side);
        for (0..ports.len()) |i| {
            const p = ports.get(i);
            self.port_positions[idx(p.id)] = self.positionOf(p) + self.node_cardinalities[idx(was_lower.id)];
        }
        ports = cmu.inNorthSouthEastWestOrder(was_lower, side);
        for (0..ports.len()) |i| {
            const p = ports.get(i);
            self.port_positions[idx(p.id)] = self.positionOf(p) - self.node_cardinalities[idx(was_upper.id)];
        }
    }

    // TreeSet ordered by position: ports with an equal position collapse into the first one added
    fn addByPosition(self: *CrossingsCounter, set: *std.ArrayList(*lg.LPort), p: *lg.LPort) lg.Error!void {
        const pos = self.positionOf(p);
        var i: usize = 0;
        while (i < set.items.len) : (i += 1) {
            const q = self.positionOf(set.items[i]);
            if (q == pos) return;
            if (q > pos) break;
        }
        try set.insert(self.a, i, p);
    }

    fn connectedInLayerPortsSortedByPosition(self: *CrossingsCounter, upper: *lg.LNode, lower: *lg.LNode, side: lg.PortSide) lg.Error![]*lg.LPort {
        var set: std.ArrayList(*lg.LPort) = .empty;
        for ([_]*lg.LNode{ upper, lower }) |node| {
            const seq = cmu.inNorthSouthEastWestOrder(node, side);
            for (0..seq.len()) |i| {
                const port = seq.get(i);
                for (0..port.degree()) |e| {
                    const edge = connectedEdge(port, e);
                    if (!edge.isSelfLoop()) {
                        try self.addByPosition(&set, port);
                        if (isInLayer(edge)) try self.addByPosition(&set, otherEndOf(edge, port));
                    }
                }
            }
        }
        return set.items;
    }

    fn connectedPortsSortedByPosition(self: *CrossingsCounter, upper: *lg.LPort, lower: *lg.LPort) lg.Error![]*lg.LPort {
        var set: std.ArrayList(*lg.LPort) = .empty;
        for ([_]*lg.LPort{ upper, lower }) |port| {
            try self.addByPosition(&set, port);
            for (0..port.degree()) |e| {
                const edge = connectedEdge(port, e);
                if (edge.source != edge.target) try self.addByPosition(&set, otherEndOf(edge, port));
            }
        }
        return set.items;
    }

    fn countCrossingsOnPorts(self: *CrossingsCounter, ports: []*lg.LPort) lg.Error!i32 {
        var crossings: i32 = 0;
        for (ports) |port| {
            self.index_tree.removeAll(self.positionOf(port));
            for (0..port.degree()) |e| {
                const end_position = self.positionOf(otherEndOf(connectedEdge(port, e), port));
                if (end_position > self.positionOf(port)) {
                    crossings +%= self.index_tree.rank(end_position);
                    try self.ends.append(self.a, end_position);
                }
            }
            while (self.ends.pop()) |x| self.index_tree.add(x);
        }
        return crossings;
    }

    fn countInLayerCrossingsOnPorts(self: *CrossingsCounter, ports: []*lg.LPort) lg.Error!i32 {
        var crossings: i32 = 0;
        for (ports) |port| {
            self.index_tree.removeAll(self.positionOf(port));
            var num_between_layer_edges: i32 = 0;
            for (0..port.degree()) |e| {
                const edge = connectedEdge(port, e);
                if (isInLayer(edge)) {
                    const end_position = self.positionOf(otherEndOf(edge, port));
                    if (end_position > self.positionOf(port)) {
                        crossings +%= self.index_tree.rank(end_position);
                        try self.ends.append(self.a, end_position);
                    }
                } else {
                    num_between_layer_edges += 1;
                }
            }
            crossings +%= self.index_tree.size *% num_between_layer_edges;
            while (self.ends.pop()) |x| self.index_tree.add(x);
        }
        return crossings;
    }

    fn initPositions(self: *CrossingsCounter, nodes: []*lg.LNode, ports: *std.ArrayList(*lg.LPort), side: lg.PortSide, top_down: bool, get_cardinalities: bool) lg.Error!void {
        var num_ports: i32 = @intCast(ports.items.len);
        if (get_cardinalities) {
            self.node_cardinalities = try self.a.alloc(i32, nodes.len);
            @memset(self.node_cardinalities, 0);
        }
        var k: usize = 0;
        while (k < nodes.len) : (k += 1) {
            const node = nodes[if (top_down) k else nodes.len - 1 - k];
            const seq = getPorts(node, side, top_down);
            if (get_cardinalities) self.node_cardinalities[idx(node.id)] = @intCast(seq.len());
            for (0..seq.len()) |i| {
                self.port_positions[idx(seq.get(i).id)] = num_ports;
                num_ports += 1;
            }
            for (0..seq.len()) |i| try ports.append(self.a, seq.get(i));
        }
    }

    fn initPortPositionsCounterClockwise(self: *CrossingsCounter, left: []*lg.LNode, right: []*lg.LNode) lg.Error![]*lg.LPort {
        var ports: std.ArrayList(*lg.LPort) = .empty;
        try self.initPositions(left, &ports, .east, true, false);
        try self.initPositions(right, &ports, .west, false, false);
        return ports.items;
    }

    fn getPorts(node: *lg.LNode, side: lg.PortSide, top_down: bool) cmu.PortSeq {
        const view = node.portSideView(side);
        if (side == .east) return .{ .items = view, .reversed = !top_down };
        return .{ .items = view, .reversed = top_down };
    }

    pub fn positionOf(self: *const CrossingsCounter, p: *const lg.LPort) i32 {
        return self.port_positions[idx(p.id)];
    }

    fn cmpPosition(self: *CrossingsCounter, x: *lg.LPort, y: *lg.LPort) lg.Error!i32 {
        return intCompare(self.positionOf(x), self.positionOf(y));
    }
};

pub fn intCompare(x: i32, y: i32) i32 {
    return if (x < y) -1 else if (x == y) 0 else 1;
}

pub fn idx(id: i32) usize {
    return @intCast(id);
}

fn isInLayer(edge: *const lg.LEdge) bool {
    return edge.source.?.owner.?.layer == edge.target.?.owner.?.layer;
}

fn otherEndOf(edge: *const lg.LEdge, from: *const lg.LPort) *lg.LPort {
    return if (from == edge.source.?) edge.target.? else edge.source.?;
}
