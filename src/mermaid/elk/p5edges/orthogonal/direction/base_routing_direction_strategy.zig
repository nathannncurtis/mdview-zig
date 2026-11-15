const std = @import("std");
const lg = @import("../../../lgraph.zig");
const HyperEdgeSegment = @import("../hyper_edge_segment.zig").HyperEdgeSegment;

pub const tolerance: f64 = 1e-3;

pub const RoutingDirection = enum { west_to_east, north_to_south, south_to_north };

pub fn portPositionOnHyperNode(dir: RoutingDirection, port: *const lg.LPort) f64 {
    const n = port.owner.?;
    return switch (dir) {
        .west_to_east => n.pos.y + port.pos.y + port.anchor.y,
        .north_to_south, .south_to_north => n.pos.x + port.pos.x + port.anchor.x,
    };
}

pub fn sourcePortSide(dir: RoutingDirection) lg.PortSide {
    return switch (dir) {
        .west_to_east => .east,
        .north_to_south => .south,
        .south_to_north => .north,
    };
}

pub fn targetPortSide(dir: RoutingDirection) lg.PortSide {
    return switch (dir) {
        .west_to_east => .west,
        .north_to_south => .north,
        .south_to_north => .south,
    };
}

// BaseRoutingDirectionStrategy with its WestToEast, NorthToSouth and SouthToNorth subclasses
pub const RoutingStrategy = struct {
    a: std.mem.Allocator,
    dir: RoutingDirection,
    created_junction_points: std.ArrayList(lg.Vec) = .empty,

    fn sameVec(p: lg.Vec, q: lg.Vec) bool {
        return @as(u64, @bitCast(p.x)) == @as(u64, @bitCast(q.x)) and @as(u64, @bitCast(p.y)) == @as(u64, @bitCast(q.y));
    }

    fn addJunctionPointIfNecessary(self: *RoutingStrategy, edge: *lg.LEdge, segment: *const HyperEdgeSegment, pos: lg.Vec, vertical: bool) lg.Error!void {
        const p = if (vertical) pos.y else pos.x;
        for (self.created_junction_points.items) |c| if (sameVec(c, pos)) return;
        const point_inside_edge_segment = p > segment.start_position and p < segment.end_position;
        var point_at_segment_boundary = false;
        const in = segment.incoming_connection_coordinates.items;
        const out = segment.outgoing_connection_coordinates.items;
        if (in.len != 0 and out.len != 0) {
            point_at_segment_boundary = point_at_segment_boundary or
                (@abs(p - in[0]) < tolerance and @abs(p - out[0]) < tolerance);
            point_at_segment_boundary = point_at_segment_boundary or
                (@abs(p - in[in.len - 1]) < tolerance and @abs(p - out[out.len - 1]) < tolerance);
        }
        if (point_inside_edge_segment or point_at_segment_boundary) {
            try edge.p.junction_points.append(self.a, pos);
            try self.created_junction_points.append(self.a, pos);
        }
    }

    pub fn clearCreatedJunctionPoints(self: *RoutingStrategy) void {
        self.created_junction_points.clearRetainingCapacity();
    }

    fn slotPosition(self: *const RoutingStrategy, start_pos: f64, slot: i32, edge_spacing: f64) f64 {
        const off = @as(f64, @floatFromInt(slot)) * edge_spacing;
        return if (self.dir == .south_to_north) start_pos - off else start_pos + off;
    }

    fn point(self: *const RoutingStrategy, slot_pos: f64, coord: f64) lg.Vec {
        return if (self.dir == .west_to_east) .{ .x = slot_pos, .y = coord } else .{ .x = coord, .y = slot_pos };
    }

    fn coordOf(self: *const RoutingStrategy, port: *const lg.LPort) f64 {
        const v = port.absoluteAnchor();
        return if (self.dir == .west_to_east) v.y else v.x;
    }

    pub fn calculateBendPoints(self: *RoutingStrategy, segment: *HyperEdgeSegment, start_pos: f64, edge_spacing: f64) lg.Error!void {
        if (segment.isDummy()) return;
        const vertical = self.dir == .west_to_east;
        const segment_pos = self.slotPosition(start_pos, segment.routing_slot, edge_spacing);
        for (segment.ports.items) |port| {
            const source_c = self.coordOf(port);
            for (port.outgoing.items) |edge| {
                if (edge.isSelfLoop()) continue;
                const target_c = self.coordOf(edge.target.?);
                if (@abs(source_c - target_c) > tolerance) {
                    var current_pos = segment_pos;
                    var current_segment = segment;
                    var bend = self.point(current_pos, source_c);
                    try edge.bend_points.append(edge.a, bend);
                    try self.addJunctionPointIfNecessary(edge, current_segment, bend, vertical);
                    if (segment.split_partner) |split_partner| {
                        const split_c = split_partner.incoming_connection_coordinates.items[0];
                        bend = self.point(current_pos, split_c);
                        try edge.bend_points.append(edge.a, bend);
                        try self.addJunctionPointIfNecessary(edge, current_segment, bend, vertical);
                        current_pos = self.slotPosition(start_pos, split_partner.routing_slot, edge_spacing);
                        current_segment = split_partner;
                        bend = self.point(current_pos, split_c);
                        try edge.bend_points.append(edge.a, bend);
                        try self.addJunctionPointIfNecessary(edge, current_segment, bend, vertical);
                    }
                    bend = self.point(current_pos, target_c);
                    try edge.bend_points.append(edge.a, bend);
                    try self.addJunctionPointIfNecessary(edge, current_segment, bend, vertical);
                }
            }
        }
    }
};
