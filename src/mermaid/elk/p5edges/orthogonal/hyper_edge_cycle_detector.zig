const std = @import("std");
const lg = @import("../../lgraph.zig");
const HyperEdgeSegment = @import("hyper_edge_segment.zig").HyperEdgeSegment;
const HyperEdgeSegmentDependency = @import("hyper_edge_segment_dependency.zig").HyperEdgeSegmentDependency;

const Allocator = std.mem.Allocator;
const SegList = std.ArrayList(*HyperEdgeSegment);

pub fn detectCycles(a: Allocator, segments: []const *HyperEdgeSegment, critical_only: bool, random: *lg.JavaRandom) lg.Error![]*HyperEdgeSegmentDependency {
    var result: std.ArrayList(*HyperEdgeSegmentDependency) = .empty;
    var sources: SegList = .empty;
    var sinks: SegList = .empty;
    try initialize(a, segments, &sources, &sinks, critical_only);
    try computeLinearOrderingMarks(a, segments, &sources, &sinks, critical_only, random);
    for (segments) |source| {
        for (source.outgoing_segment_dependencies.items) |out_dep| {
            if (!critical_only or out_dep.type == .critical) {
                if (source.mark > out_dep.target.?.mark) try result.append(a, out_dep);
            }
        }
    }
    return result.items;
}

fn initialize(a: Allocator, segments: []const *HyperEdgeSegment, sources: *SegList, sinks: *SegList, critical_only: bool) lg.Error!void {
    var next_mark: i32 = -1;
    for (segments) |segment| {
        segment.mark = next_mark;
        next_mark -= 1;
        var critical_in_weight: i32 = 0;
        var all_in_weight: i32 = 0;
        for (segment.incoming_segment_dependencies.items) |dep| {
            if (dep.type == .critical) critical_in_weight += dep.weight;
            all_in_weight += dep.weight;
        }
        var critical_out_weight: i32 = 0;
        var all_out_weight: i32 = 0;
        for (segment.outgoing_segment_dependencies.items) |dep| {
            if (dep.type == .critical) critical_out_weight += dep.weight;
            all_out_weight += dep.weight;
        }
        const in_weight = if (critical_only) critical_in_weight else all_in_weight;
        const out_weight = if (critical_only) critical_out_weight else all_out_weight;
        segment.in_dep_weight = in_weight;
        segment.critical_in_dep_weight = critical_in_weight;
        segment.out_dep_weight = out_weight;
        segment.critical_out_dep_weight = critical_out_weight;
        if (out_weight == 0) {
            try sinks.append(a, segment);
        } else if (in_weight == 0) {
            try sources.append(a, segment);
        }
    }
}

// Sets.newTreeSet ordered by mark: unprocessed segments keep their initial (distinct, negative) marks, so the
// list stays sorted, and remove() matches by the current mark of its argument like TreeSet.remove does.
fn treeRemove(set: *SegList, x: *const HyperEdgeSegment) void {
    for (set.items, 0..) |s, i| if (s.mark == x.mark) {
        _ = set.orderedRemove(i);
        return;
    };
}

fn computeLinearOrderingMarks(a: Allocator, segments: []const *HyperEdgeSegment, sources: *SegList, sinks: *SegList, critical_only: bool, random: *lg.JavaRandom) lg.Error!void {
    var unprocessed: SegList = .empty;
    try unprocessed.ensureTotalCapacity(a, segments.len);
    var k = segments.len;
    while (k > 0) {
        k -= 1;
        unprocessed.appendAssumeCapacity(segments[k]);
    }
    var max_segments: SegList = .empty;
    const mark_base: i32 = @intCast(segments.len);
    var next_sink_mark: i32 = mark_base - 1;
    var next_source_mark: i32 = mark_base + 1;

    while (unprocessed.items.len != 0) {
        while (sinks.items.len != 0) {
            const sink = sinks.orderedRemove(0);
            treeRemove(&unprocessed, sink);
            sink.mark = next_sink_mark;
            next_sink_mark -= 1;
            try updateNeighbors(a, sink, sources, sinks, critical_only);
        }
        while (sources.items.len != 0) {
            const source = sources.orderedRemove(0);
            treeRemove(&unprocessed, source);
            source.mark = next_source_mark;
            next_source_mark += 1;
            try updateNeighbors(a, source, sources, sinks, critical_only);
        }
        var max_outflow: i32 = std.math.minInt(i32);
        for (unprocessed.items) |segment| {
            if (!critical_only and segment.critical_out_dep_weight > 0 and segment.critical_in_dep_weight <= 0) {
                max_segments.clearRetainingCapacity();
                try max_segments.append(a, segment);
                break;
            }
            const outflow = segment.out_dep_weight - segment.in_dep_weight;
            if (outflow >= max_outflow) {
                if (outflow > max_outflow) {
                    max_segments.clearRetainingCapacity();
                    max_outflow = outflow;
                }
                try max_segments.append(a, segment);
            }
        }
        if (max_segments.items.len != 0) {
            const idx: usize = @intCast(random.nextIntBound(@intCast(max_segments.items.len)));
            const max_node = max_segments.items[idx];
            treeRemove(&unprocessed, max_node);
            max_node.mark = next_source_mark;
            next_source_mark += 1;
            try updateNeighbors(a, max_node, sources, sinks, critical_only);
            max_segments.clearRetainingCapacity();
        }
    }

    const shift_base: i32 = @as(i32, @intCast(segments.len)) + 1;
    for (segments) |node| {
        if (node.mark < mark_base) node.mark = node.mark + shift_base;
    }
}

fn updateNeighbors(a: Allocator, node: *HyperEdgeSegment, sources: *SegList, sinks: *SegList, critical_only: bool) lg.Error!void {
    for (node.outgoing_segment_dependencies.items) |dep| {
        if (!critical_only or dep.type == .critical) {
            const target = dep.target.?;
            if (target.mark < 0 and dep.weight > 0) {
                target.in_dep_weight -= dep.weight;
                if (dep.type == .critical) target.critical_in_dep_weight -= dep.weight;
                if (target.in_dep_weight <= 0 and target.out_dep_weight > 0) try sources.append(a, target);
            }
        }
    }
    for (node.incoming_segment_dependencies.items) |dep| {
        if (!critical_only or dep.type == .critical) {
            const source = dep.source.?;
            if (source.mark < 0 and dep.weight > 0) {
                source.out_dep_weight -= dep.weight;
                if (dep.type == .critical) source.critical_out_dep_weight -= dep.weight;
                if (source.out_dep_weight <= 0 and source.in_dep_weight > 0) try sinks.append(a, source);
            }
        }
    }
}
