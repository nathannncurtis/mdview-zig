const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const direction = @import("direction/base_routing_direction_strategy.zig");
const seg = @import("hyper_edge_segment.zig");
const HyperEdgeSegment = seg.HyperEdgeSegment;
const HyperEdgeSegmentDependency = @import("hyper_edge_segment_dependency.zig").HyperEdgeSegmentDependency;
const cycle_detector = @import("hyper_edge_cycle_detector.zig");
const splitter = @import("hyper_edge_segment_splitter.zig");

const Allocator = std.mem.Allocator;

pub const tolerance = direction.tolerance;
const critical_conflicts_detected: i32 = -1;
const conflict_threshold_factor: f64 = 0.5;
const critical_conflict_threshold_factor: f64 = 0.2;
const conflict_penalty: i32 = 1;
const crossing_penalty: i32 = 16;

pub const OrthogonalRoutingGenerator = struct {
    a: Allocator,
    routing_strategy: direction.RoutingStrategy,
    edge_spacing: f64,
    conflict_threshold: f64,
    critical_conflict_threshold: f64 = 0,

    pub fn init(a: Allocator, dir: direction.RoutingDirection, edge_spacing: f64) OrthogonalRoutingGenerator {
        return .{
            .a = a,
            .routing_strategy = .{ .a = a, .dir = dir },
            .edge_spacing = edge_spacing,
            .conflict_threshold = conflict_threshold_factor * edge_spacing,
        };
    }

    pub fn routeEdges(self: *OrthogonalRoutingGenerator, g: *lg.LGraph, source_layer_nodes: ?[]const *lg.LNode, target_layer_nodes: ?[]const *lg.LNode, start_pos: f64) lg.Error!i32 {
        const a = self.a;
        var port_map = seg.PortMap.init(a);
        var edge_segments: std.ArrayList(*HyperEdgeSegment) = .empty;
        try self.createHyperEdgeSegments(source_layer_nodes, direction.sourcePortSide(self.routing_strategy.dir), &edge_segments, &port_map);
        try self.createHyperEdgeSegments(target_layer_nodes, direction.targetPortSide(self.routing_strategy.dir), &edge_segments, &port_map);

        self.critical_conflict_threshold = critical_conflict_threshold_factor * try minimumHorizontalSegmentDistance(a, edge_segments.items);

        var critical_dependency_count: i32 = 0;
        var first_idx: usize = 0;
        while (first_idx + 1 < edge_segments.items.len) : (first_idx += 1) {
            const first = edge_segments.items[first_idx];
            var second_idx = first_idx + 1;
            while (second_idx < edge_segments.items.len) : (second_idx += 1) {
                critical_dependency_count += try self.createDependencyIfNecessary(first, edge_segments.items[second_idx]);
            }
        }

        const random = g.p.random.?;
        if (critical_dependency_count >= 2) try self.breakCriticalCycles(&edge_segments, random);
        try breakNonCriticalCycles(a, edge_segments.items, random);

        try topologicalNumbering(a, edge_segments.items);

        var rank_count: i32 = -1;
        for (edge_segments.items) |node| {
            if (@abs(node.start_position - node.end_position) < tolerance) continue;
            rank_count = @max(rank_count, node.routing_slot);
            try self.routing_strategy.calculateBendPoints(node, start_pos, self.edge_spacing);
        }
        self.routing_strategy.clearCreatedJunctionPoints();
        return rank_count + 1;
    }

    fn minimumHorizontalSegmentDistance(a: Allocator, edge_segments: []const *HyperEdgeSegment) lg.Error!f64 {
        var incoming: std.ArrayList(f64) = .empty;
        var outgoing: std.ArrayList(f64) = .empty;
        for (edge_segments) |s| try incoming.appendSlice(a, s.incoming_connection_coordinates.items);
        for (edge_segments) |s| try outgoing.appendSlice(a, s.outgoing_connection_coordinates.items);
        return util.javaMin(minimumDifference(incoming.items), minimumDifference(outgoing.items));
    }

    // Stream.sorted().distinct(): Double.compareTo order, Double.equals identity
    fn minimumDifference(numbers: []f64) f64 {
        std.mem.sort(f64, numbers, {}, struct {
            fn lt(_: void, x: f64, y: f64) bool {
                return util.doubleCompare(x, y) == .lt;
            }
        }.lt);
        var n: usize = 0;
        for (numbers) |v| {
            if (n == 0 or util.doubleToLongBits(numbers[n - 1]) != util.doubleToLongBits(v)) {
                numbers[n] = v;
                n += 1;
            }
        }
        var min_difference: f64 = std.math.floatMax(f64);
        if (n >= 2) {
            var i: usize = 1;
            while (i < n) : (i += 1) min_difference = util.javaMin(min_difference, numbers[i] - numbers[i - 1]);
        }
        return min_difference;
    }

    fn createHyperEdgeSegments(self: *OrthogonalRoutingGenerator, nodes: ?[]const *lg.LNode, port_side: lg.PortSide, hyper_edges: *std.ArrayList(*HyperEdgeSegment), port_map: *seg.PortMap) lg.Error!void {
        const list = nodes orelse return;
        for (list) |node| {
            for (node.ports.items) |port| {
                if (port.side != port_side or port.outgoing.items.len == 0) continue;
                if (port_map.get(port) == null) {
                    const hyper_edge = try HyperEdgeSegment.init(self.a, self.routing_strategy.dir);
                    try hyper_edges.append(self.a, hyper_edge);
                    try hyper_edge.addPortPositions(port, port_map);
                }
            }
        }
    }

    pub fn createDependencyIfNecessary(self: *OrthogonalRoutingGenerator, he1: *HyperEdgeSegment, he2: *HyperEdgeSegment) lg.Error!i32 {
        if (@abs(he1.start_position - he1.end_position) < tolerance or @abs(he2.start_position - he2.end_position) < tolerance) return 0;

        const conflicts1 = self.countConflicts(he1.outgoing_connection_coordinates.items, he2.incoming_connection_coordinates.items);
        const conflicts2 = self.countConflicts(he2.outgoing_connection_coordinates.items, he1.incoming_connection_coordinates.items);
        const critical = conflicts1 == critical_conflicts_detected or conflicts2 == critical_conflicts_detected;

        var critical_dependency_count: i32 = 0;
        if (critical) {
            if (conflicts1 == critical_conflicts_detected) {
                _ = try HyperEdgeSegmentDependency.createAndAddCritical(he2, he1);
                critical_dependency_count += 1;
            }
            if (conflicts2 == critical_conflicts_detected) {
                _ = try HyperEdgeSegmentDependency.createAndAddCritical(he1, he2);
                critical_dependency_count += 1;
            }
        } else {
            var crossings1 = countCrossings(he1.outgoing_connection_coordinates.items, he2.start_position, he2.end_position);
            crossings1 += countCrossings(he2.incoming_connection_coordinates.items, he1.start_position, he1.end_position);
            var crossings2 = countCrossings(he2.outgoing_connection_coordinates.items, he1.start_position, he1.end_position);
            crossings2 += countCrossings(he1.incoming_connection_coordinates.items, he2.start_position, he2.end_position);
            const dep_value1 = conflict_penalty * conflicts1 + crossing_penalty * crossings1;
            const dep_value2 = conflict_penalty * conflicts2 + crossing_penalty * crossings2;
            if (dep_value1 < dep_value2) {
                _ = try HyperEdgeSegmentDependency.createAndAddRegular(he1, he2, dep_value2 - dep_value1);
            } else if (dep_value1 > dep_value2) {
                _ = try HyperEdgeSegmentDependency.createAndAddRegular(he2, he1, dep_value1 - dep_value2);
            } else if (dep_value1 > 0 and dep_value2 > 0) {
                _ = try HyperEdgeSegmentDependency.createAndAddRegular(he1, he2, 0);
                _ = try HyperEdgeSegmentDependency.createAndAddRegular(he2, he1, 0);
            }
        }
        return critical_dependency_count;
    }

    fn countConflicts(self: *const OrthogonalRoutingGenerator, posis1: []const f64, posis2: []const f64) i32 {
        var conflicts: i32 = 0;
        if (posis1.len != 0 and posis2.len != 0) {
            var it1: usize = 1;
            var it2: usize = 1;
            var pos1 = posis1[0];
            var pos2 = posis2[0];
            var has_more = true;
            while (has_more) {
                if (pos1 > pos2 - self.critical_conflict_threshold and pos1 < pos2 + self.critical_conflict_threshold) {
                    return critical_conflicts_detected;
                } else if (pos1 > pos2 - self.conflict_threshold and pos1 < pos2 + self.conflict_threshold) {
                    conflicts += 1;
                }
                if (pos1 <= pos2 and it1 < posis1.len) {
                    pos1 = posis1[it1];
                    it1 += 1;
                } else if (pos2 <= pos1 and it2 < posis2.len) {
                    pos2 = posis2[it2];
                    it2 += 1;
                } else {
                    has_more = false;
                }
            }
        }
        return conflicts;
    }

    pub fn countCrossings(posis: []const f64, start: f64, end: f64) i32 {
        var crossings: i32 = 0;
        for (posis) |pos| {
            if (pos > end) break;
            if (pos >= start) crossings += 1;
        }
        return crossings;
    }

    fn breakCriticalCycles(self: *OrthogonalRoutingGenerator, edge_segments: *std.ArrayList(*HyperEdgeSegment), random: *lg.JavaRandom) lg.Error!void {
        const cycle_dependencies = try cycle_detector.detectCycles(self.a, edge_segments.items, true, random);
        try splitter.splitSegments(self, cycle_dependencies, edge_segments, self.critical_conflict_threshold);
    }

    pub fn breakNonCriticalCycles(a: Allocator, edge_segments: []const *HyperEdgeSegment, random: *lg.JavaRandom) lg.Error!void {
        const cycle_dependencies = try cycle_detector.detectCycles(a, edge_segments, false, random);
        for (cycle_dependencies) |dep| {
            if (dep.weight == 0) {
                try dep.remove();
            } else {
                try dep.reverse();
            }
        }
    }

    fn topologicalNumbering(a: Allocator, segments: []const *HyperEdgeSegment) lg.Error!void {
        var sources: std.ArrayList(*HyperEdgeSegment) = .empty;
        var rightward_targets: std.ArrayList(*HyperEdgeSegment) = .empty;
        for (segments) |node| {
            node.in_dep_weight = @intCast(node.incoming_segment_dependencies.items.len);
            node.out_dep_weight = @intCast(node.outgoing_segment_dependencies.items.len);
            if (node.in_dep_weight == 0) try sources.append(a, node);
            if (node.out_dep_weight == 0 and node.incoming_connection_coordinates.items.len == 0) try rightward_targets.append(a, node);
        }
        var max_rank: i32 = -1;
        while (sources.items.len != 0) {
            const node = sources.orderedRemove(0);
            for (node.outgoing_segment_dependencies.items) |dep| {
                const target = dep.target.?;
                target.routing_slot = @max(target.routing_slot, node.routing_slot + 1);
                max_rank = @max(max_rank, target.routing_slot);
                target.in_dep_weight -= 1;
                if (target.in_dep_weight == 0) try sources.append(a, target);
            }
        }
        if (max_rank > -1) {
            for (rightward_targets.items) |node| node.routing_slot = max_rank;
            while (rightward_targets.items.len != 0) {
                const node = rightward_targets.orderedRemove(0);
                for (node.incoming_segment_dependencies.items) |dep| {
                    const source = dep.source.?;
                    if (source.incoming_connection_coordinates.items.len > 0) continue;
                    source.routing_slot = @min(source.routing_slot, node.routing_slot - 1);
                    source.out_dep_weight -= 1;
                    if (source.out_dep_weight == 0) try rightward_targets.append(a, source);
                }
            }
        }
    }
};
