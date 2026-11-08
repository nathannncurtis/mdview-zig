const std = @import("std");
const lg = @import("../../lgraph.zig");
const cmu = @import("../../p3order/counting/cross_min_util.zig");

pub const NorthSouthEdgeNeighbouringNodeCrossingsCounter = struct {
    upper_lower_crossings: i32 = 0,
    lower_upper_crossings: i32 = 0,
    port_positions: std.AutoHashMapUnmanaged(*lg.LPort, i32) = .empty,

    pub fn init(a: std.mem.Allocator, layer: []*lg.LNode) lg.Error!NorthSouthEdgeNeighbouringNodeCrossingsCounter {
        var self: NorthSouthEdgeNeighbouringNodeCrossingsCounter = .{};
        for (layer) |node| {
            for ([_]lg.PortSide{ .south, .north }) |side| {
                const seq = cmu.inNorthSouthEastWestOrder(node, side);
                var port_id: i32 = 0;
                for (0..seq.len()) |i| {
                    try self.port_positions.put(a, seq.get(i), port_id);
                    port_id += 1;
                }
            }
        }
        return self;
    }

    pub fn countCrossings(self: *NorthSouthEdgeNeighbouringNodeCrossingsCounter, upper: *lg.LNode, lower: *lg.LNode) void {
        self.upper_lower_crossings = 0;
        self.lower_upper_crossings = 0;
        if (upper.type == .north_south_port and lower.type == .north_south_port and originOf(upper) == originOf(lower)) {
            if (isNorthOfNormalNode(upper)) {
                self.countCrossingsOfTwoNorthSouthDummies(upper, lower);
            } else {
                self.countCrossingsOfTwoNorthSouthDummies(lower, upper);
            }
        }
        if (upper.type == .north_south_port and lower.type == .long_edge) {
            if (isNorthOfNormalNode(upper)) self.upper_lower_crossings = 1 else self.lower_upper_crossings = 1;
        } else if (lower.type == .north_south_port and upper.type == .long_edge) {
            if (isNorthOfNormalNode(lower)) self.lower_upper_crossings = 1 else self.upper_lower_crossings = 1;
        }
        if (upper.type == .normal and lower.type == .long_edge) {
            self.upper_lower_crossings = numberOfNorthSouthEdges(upper, .south);
            self.lower_upper_crossings = numberOfNorthSouthEdges(upper, .north);
        }
        if (lower.type == .normal and upper.type == .long_edge) {
            self.upper_lower_crossings = numberOfNorthSouthEdges(lower, .north);
            self.lower_upper_crossings = numberOfNorthSouthEdges(lower, .south);
        }
    }

    fn countCrossingsOfTwoNorthSouthDummies(self: *NorthSouthEdgeNeighbouringNodeCrossingsCounter, further: *lg.LNode, closer: *lg.LNode) void {
        if (self.originPortPositionOf(further) > self.originPortPositionOf(closer)) {
            self.upper_lower_crossings = firstDegree(closer.portSideView(.east));
            self.lower_upper_crossings = firstDegree(further.portSideView(.west));
        } else {
            self.upper_lower_crossings = firstDegree(closer.portSideView(.west));
            self.lower_upper_crossings = firstDegree(further.portSideView(.east));
        }
    }

    fn firstDegree(ports: []*lg.LPort) i32 {
        return if (ports.len == 0) 0 else @intCast(ports[0].degree());
    }

    fn numberOfNorthSouthEdges(node: *lg.LNode, side: lg.PortSide) i32 {
        var n: i32 = 0;
        for (node.portSideView(side)) |port| {
            if (port.p.port_dummy != null) n += 1;
        }
        return n;
    }

    fn originPortPositionOf(self: *const NorthSouthEdgeNeighbouringNodeCrossingsCounter, node: *lg.LNode) i32 {
        const origin = originPortOf(node) orelse return 0;
        return self.port_positions.get(origin) orelse 0;
    }

    fn originPortOf(node: *lg.LNode) ?*lg.LPort {
        return switch (node.ports.items[0].p.origin) {
            .port => |p| p,
            else => null,
        };
    }

    fn isNorthOfNormalNode(node: *lg.LNode) bool {
        const p = originPortOf(node) orelse return false;
        return p.side == .north;
    }

    fn originOf(node: *lg.LNode) ?*lg.LNode {
        return switch (node.p.origin) {
            .node => |n| n,
            else => null,
        };
    }
};
