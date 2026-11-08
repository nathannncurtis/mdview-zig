const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const HyperEdgeSegment = @import("hyper_edge_segment.zig").HyperEdgeSegment;
const HyperEdgeSegmentDependency = @import("hyper_edge_segment_dependency.zig").HyperEdgeSegmentDependency;
const OrthogonalRoutingGenerator = @import("orthogonal_routing_generator.zig").OrthogonalRoutingGenerator;

const Allocator = std.mem.Allocator;

const FreeArea = struct {
    start_position: f64,
    end_position: f64,
    size: f64,

    fn init(start_position: f64, end_position: f64) FreeArea {
        return .{ .start_position = start_position, .end_position = end_position, .size = end_position - start_position };
    }
};

const AreaRating = struct {
    dependencies: i32 = 0,
    crossings: i32 = 0,
};

pub fn splitSegments(gen: *OrthogonalRoutingGenerator, dependencies_to_resolve: []const *HyperEdgeSegmentDependency, segments: *std.ArrayList(*HyperEdgeSegment), critical_conflict_threshold: f64) lg.Error!void {
    if (dependencies_to_resolve.len == 0) return;
    const a = gen.a;
    var free_areas = try findFreeAreas(a, segments.items, critical_conflict_threshold);
    const to_split = try decideWhichSegmentsToSplit(a, dependencies_to_resolve);
    std.mem.sort(*HyperEdgeSegment, to_split, {}, struct {
        fn lt(_: void, x: *HyperEdgeSegment, y: *HyperEdgeSegment) bool {
            return util.doubleCompare(x.length(), y.length()) == .lt;
        }
    }.lt);
    for (to_split) |segment| try split(gen, segment, segments, &free_areas, critical_conflict_threshold);
}

fn findFreeAreas(a: Allocator, segments: []const *HyperEdgeSegment, critical_conflict_threshold: f64) lg.Error!std.ArrayList(FreeArea) {
    var free_areas: std.ArrayList(FreeArea) = .empty;
    var sorted: std.ArrayList(f64) = .empty;
    for (segments) |s| try sorted.appendSlice(a, s.incoming_connection_coordinates.items);
    for (segments) |s| try sorted.appendSlice(a, s.outgoing_connection_coordinates.items);
    std.mem.sort(f64, sorted.items, {}, struct {
        fn lt(_: void, x: f64, y: f64) bool {
            return util.doubleCompare(x, y) == .lt;
        }
    }.lt);
    const c = sorted.items;
    var i: usize = 1;
    while (i < c.len) : (i += 1) {
        if (c[i] - c[i - 1] >= 2 * critical_conflict_threshold) {
            try free_areas.append(a, FreeArea.init(c[i - 1] + critical_conflict_threshold, c[i] - critical_conflict_threshold));
        }
    }
    return free_areas;
}

fn contains(list: []const *HyperEdgeSegment, s: *const HyperEdgeSegment) bool {
    for (list) |x| if (x == s) return true;
    return false;
}

fn decideWhichSegmentsToSplit(a: Allocator, dependencies: []const *HyperEdgeSegmentDependency) lg.Error![]*HyperEdgeSegment {
    var segments_to_split: std.ArrayList(*HyperEdgeSegment) = .empty;
    for (dependencies) |dependency| {
        const source_segment = dependency.source.?;
        const target_segment = dependency.target.?;
        if (contains(segments_to_split.items, source_segment) or contains(segments_to_split.items, target_segment)) continue;
        var segment_to_split = source_segment;
        var segment_causing_split = target_segment;
        if (source_segment.representsHyperedge() and !target_segment.representsHyperedge()) {
            segment_to_split = target_segment;
            segment_causing_split = source_segment;
        }
        try segments_to_split.append(a, segment_to_split);
        segment_to_split.split_by = segment_causing_split;
    }
    return segments_to_split.items;
}

fn split(gen: *OrthogonalRoutingGenerator, segment: *HyperEdgeSegment, segments: *std.ArrayList(*HyperEdgeSegment), free_areas: *std.ArrayList(FreeArea), critical_conflict_threshold: f64) lg.Error!void {
    const split_position = try computePositionToSplitAndUpdateFreeAreas(gen.a, segment, free_areas, critical_conflict_threshold);
    try segments.append(gen.a, try segment.splitAt(split_position));
    try updateDependencies(gen, segment, segments.items);
}

fn updateDependencies(gen: *OrthogonalRoutingGenerator, segment: *HyperEdgeSegment, segments: []const *HyperEdgeSegment) lg.Error!void {
    const split_causing_segment = segment.split_by.?;
    const split_partner = segment.split_partner.?;
    _ = try HyperEdgeSegmentDependency.createAndAddCritical(segment, split_causing_segment);
    _ = try HyperEdgeSegmentDependency.createAndAddCritical(split_causing_segment, split_partner);
    for (segments) |other| {
        if (other != split_causing_segment and other != segment and other != split_partner) {
            _ = try gen.createDependencyIfNecessary(other, segment);
            _ = try gen.createDependencyIfNecessary(other, split_partner);
        }
    }
}

fn computePositionToSplitAndUpdateFreeAreas(a: Allocator, segment: *HyperEdgeSegment, free_areas: *std.ArrayList(FreeArea), critical_conflict_threshold: f64) lg.Error!f64 {
    var first_possible: i64 = -1;
    var last_possible: i64 = -1;
    for (free_areas.items, 0..) |curr, i| {
        if (curr.start_position > segment.end_position) {
            break;
        } else if (curr.end_position >= segment.start_position) {
            if (first_possible < 0) first_possible = @intCast(i);
            last_possible = @intCast(i);
        }
    }
    var split_position = center(segment.start_position, segment.end_position);
    if (first_possible >= 0) {
        const best = try chooseBestAreaIndex(segment, free_areas.items, @intCast(first_possible), @intCast(last_possible));
        const area = free_areas.items[best];
        split_position = center(area.start_position, area.end_position);
        try useArea(a, free_areas, best, critical_conflict_threshold);
    }
    return split_position;
}

fn chooseBestAreaIndex(segment: *HyperEdgeSegment, free_areas: []const FreeArea, from: usize, to: usize) lg.Error!usize {
    var best_index = from;
    if (from < to) {
        const pair = try segment.simulateSplit();
        var best_area = free_areas[best_index];
        var best_rating = try rateArea(segment, pair.first, pair.second, best_area);
        var i = from + 1;
        while (i <= to) : (i += 1) {
            const curr_area = free_areas[i];
            const curr_rating = try rateArea(segment, pair.first, pair.second, curr_area);
            if (isBetter(curr_area, curr_rating, best_area, best_rating)) {
                best_area = curr_area;
                best_rating = curr_rating;
                best_index = i;
            }
        }
    }
    return best_index;
}

// the split segments' extents are deliberately not recomputed after the centre is added, as in ELK
fn rateArea(segment: *HyperEdgeSegment, split_segment: *HyperEdgeSegment, split_partner: *HyperEdgeSegment, area: FreeArea) lg.Error!AreaRating {
    const area_centre = center(area.start_position, area.end_position);
    split_segment.outgoing_connection_coordinates.clearRetainingCapacity();
    try split_segment.outgoing_connection_coordinates.append(split_segment.a, area_centre);
    split_partner.incoming_connection_coordinates.clearRetainingCapacity();
    try split_partner.incoming_connection_coordinates.append(split_partner.a, area_centre);
    var rating: AreaRating = .{};
    for (segment.incoming_segment_dependencies.items) |dependency| {
        const other = dependency.source.?;
        updateConsideringBothOrderings(&rating, split_segment, other);
        updateConsideringBothOrderings(&rating, split_partner, other);
    }
    for (segment.outgoing_segment_dependencies.items) |dependency| {
        const other = dependency.target.?;
        updateConsideringBothOrderings(&rating, split_segment, other);
        updateConsideringBothOrderings(&rating, split_partner, other);
    }
    rating.dependencies += 2;
    rating.crossings += countCrossingsForSingleOrdering(split_segment, segment.split_by.?);
    rating.crossings += countCrossingsForSingleOrdering(segment.split_by.?, split_partner);
    return rating;
}

fn updateConsideringBothOrderings(rating: *AreaRating, s1: *const HyperEdgeSegment, s2: *const HyperEdgeSegment) void {
    const c12 = countCrossingsForSingleOrdering(s1, s2);
    const c21 = countCrossingsForSingleOrdering(s2, s1);
    if (c12 == c21) {
        if (c12 > 0) {
            rating.dependencies += 2;
            rating.crossings += c12;
        }
    } else {
        rating.dependencies += 1;
        rating.crossings += @min(c12, c21);
    }
}

fn countCrossingsForSingleOrdering(left: *const HyperEdgeSegment, right: *const HyperEdgeSegment) i32 {
    return OrthogonalRoutingGenerator.countCrossings(left.outgoing_connection_coordinates.items, right.start_position, right.end_position) +
        OrthogonalRoutingGenerator.countCrossings(right.incoming_connection_coordinates.items, left.start_position, left.end_position);
}

fn isBetter(curr_area: FreeArea, curr: AreaRating, best_area: FreeArea, best: AreaRating) bool {
    if (curr.crossings < best.crossings) return true;
    if (curr.crossings == best.crossings) {
        if (curr.dependencies < best.dependencies) return true;
        if (curr.dependencies == best.dependencies and curr_area.size > best_area.size) return true;
    }
    return false;
}

fn useArea(a: Allocator, free_areas: *std.ArrayList(FreeArea), used_index: usize, critical_conflict_threshold: f64) lg.Error!void {
    const old = free_areas.orderedRemove(used_index);
    if (old.size / 2 >= critical_conflict_threshold) {
        var insert_index = used_index;
        const old_centre = center(old.start_position, old.end_position);
        const new_end1 = old_centre - critical_conflict_threshold;
        if (old.start_position <= old_centre - critical_conflict_threshold) {
            try free_areas.insert(a, insert_index, FreeArea.init(old.start_position, new_end1));
            insert_index += 1;
        }
        const new_start2 = old_centre + critical_conflict_threshold;
        if (new_start2 <= old.end_position) {
            try free_areas.insert(a, insert_index, FreeArea.init(new_start2, old.end_position));
        }
    }
}

fn center(p1: f64, p2: f64) f64 {
    return (p1 + p2) / 2;
}
