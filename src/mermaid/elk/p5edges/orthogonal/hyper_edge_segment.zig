const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const direction = @import("direction/base_routing_direction_strategy.zig");
const HyperEdgeSegmentDependency = @import("hyper_edge_segment_dependency.zig").HyperEdgeSegmentDependency;

const Allocator = std.mem.Allocator;

pub const PortMap = std.AutoHashMap(*lg.LPort, *HyperEdgeSegment);

pub const HyperEdgeSegment = struct {
    a: Allocator,
    dir: direction.RoutingDirection,
    ports: std.ArrayList(*lg.LPort) = .empty,
    mark: i32 = 0,
    routing_slot: i32 = 0,
    start_position: f64 = std.math.nan(f64),
    end_position: f64 = std.math.nan(f64),
    incoming_connection_coordinates: std.ArrayList(f64) = .empty,
    outgoing_connection_coordinates: std.ArrayList(f64) = .empty,
    outgoing_segment_dependencies: std.ArrayList(*HyperEdgeSegmentDependency) = .empty,
    out_dep_weight: i32 = 0,
    critical_out_dep_weight: i32 = 0,
    incoming_segment_dependencies: std.ArrayList(*HyperEdgeSegmentDependency) = .empty,
    in_dep_weight: i32 = 0,
    critical_in_dep_weight: i32 = 0,
    split_partner: ?*HyperEdgeSegment = null,
    split_by: ?*HyperEdgeSegment = null,

    pub fn init(a: Allocator, dir: direction.RoutingDirection) lg.Error!*HyperEdgeSegment {
        const s = try a.create(HyperEdgeSegment);
        s.* = .{ .a = a, .dir = dir };
        return s;
    }

    pub fn addPortPositions(self: *HyperEdgeSegment, port: *lg.LPort, map: *PortMap) lg.Error!void {
        try map.put(port, self);
        try self.ports.append(self.a, port);
        const port_pos = direction.portPositionOnHyperNode(self.dir, port);
        if (port.side == direction.sourcePortSide(self.dir)) {
            try insertSorted(self.a, &self.incoming_connection_coordinates, port_pos);
        } else {
            try insertSorted(self.a, &self.outgoing_connection_coordinates, port_pos);
        }
        self.recomputeExtent();
        for (port.incoming.items) |e| {
            const other = e.source.?;
            if (!map.contains(other)) try self.addPortPositions(other, map);
        }
        for (port.outgoing.items) |e| {
            const other = e.target.?;
            if (!map.contains(other)) try self.addPortPositions(other, map);
        }
    }

    // the existing entries are compared after a (float) narrowing, as in ELK
    fn insertSorted(a: Allocator, list: *std.ArrayList(f64), value: f64) lg.Error!void {
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            const next = util.toFloat(list.items[i]);
            if (next == value) return;
            if (next > value) break;
        }
        try list.insert(a, i, value);
    }

    pub fn length(self: *const HyperEdgeSegment) f64 {
        return self.end_position - self.start_position;
    }

    pub fn representsHyperedge(self: *const HyperEdgeSegment) bool {
        return self.incoming_connection_coordinates.items.len + self.outgoing_connection_coordinates.items.len > 2;
    }

    pub fn isDummy(self: *const HyperEdgeSegment) bool {
        return self.split_partner != null and self.split_by == null;
    }

    pub fn recomputeExtent(self: *HyperEdgeSegment) void {
        self.start_position = std.math.nan(f64);
        self.end_position = std.math.nan(f64);
        self.recomputeExtentOf(self.incoming_connection_coordinates.items);
        self.recomputeExtentOf(self.outgoing_connection_coordinates.items);
    }

    fn recomputeExtentOf(self: *HyperEdgeSegment, positions: []const f64) void {
        if (positions.len == 0) return;
        const first = positions[0];
        const last = positions[positions.len - 1];
        self.start_position = if (std.math.isNan(self.start_position)) first else util.javaMin(self.start_position, first);
        self.end_position = if (std.math.isNan(self.end_position)) last else util.javaMax(self.end_position, last);
    }

    pub const SplitPair = struct { first: *HyperEdgeSegment, second: *HyperEdgeSegment };

    pub fn simulateSplit(self: *HyperEdgeSegment) lg.Error!SplitPair {
        const new_split = try init(self.a, self.dir);
        const new_split_partner = try init(self.a, self.dir);
        try new_split.incoming_connection_coordinates.appendSlice(self.a, self.incoming_connection_coordinates.items);
        new_split.split_by = self.split_by;
        new_split.split_partner = new_split_partner;
        new_split.recomputeExtent();
        try new_split_partner.outgoing_connection_coordinates.appendSlice(self.a, self.outgoing_connection_coordinates.items);
        new_split_partner.split_partner = new_split;
        new_split_partner.recomputeExtent();
        return .{ .first = new_split, .second = new_split_partner };
    }

    pub fn splitAt(self: *HyperEdgeSegment, split_position: f64) lg.Error!*HyperEdgeSegment {
        const partner = try init(self.a, self.dir);
        self.split_partner = partner;
        partner.split_partner = self;
        try partner.outgoing_connection_coordinates.appendSlice(self.a, self.outgoing_connection_coordinates.items);
        self.outgoing_connection_coordinates.clearRetainingCapacity();
        try self.outgoing_connection_coordinates.append(self.a, split_position);
        try partner.incoming_connection_coordinates.append(self.a, split_position);
        self.recomputeExtent();
        partner.recomputeExtent();
        while (self.incoming_segment_dependencies.items.len != 0) try self.incoming_segment_dependencies.items[0].remove();
        while (self.outgoing_segment_dependencies.items.len != 0) try self.outgoing_segment_dependencies.items[0].remove();
        return partner;
    }
};
