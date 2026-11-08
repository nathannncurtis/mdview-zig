// RoutingSlotAssigner. Props: random (graph). Reads LPort.id as set by the routing director.
const std = @import("std");
const lg = @import("../../../lgraph.zig");
const sl = @import("../self_loop_holder.zig");
const seg_mod = @import("../../../p5edges/orthogonal/hyper_edge_segment.zig");
const dep_mod = @import("../../../p5edges/orthogonal/hyper_edge_segment_dependency.zig");
const org = @import("../../../p5edges/orthogonal/orthogonal_routing_generator.zig");

const Segment = seg_mod.HyperEdgeSegment;

const Assigner = struct {
    a: std.mem.Allocator,
    h: *sl.SelfLoopHolder,
    crossing: [][]bool,
    segments: []*Segment,
    activity: [][]bool,

    fn indexOf(self: *const Assigner, loop: *const sl.SelfHyperLoop) usize {
        for (self.h.sl_hyper_loops.items, 0..) |l, i| if (l == loop) return i;
        unreachable;
    }

    fn labelsOverlapMatrix(self: *const Assigner, l1: *const sl.SelfHyperLoop, l2: *const sl.SelfHyperLoop) bool {
        const a1 = l1.sl_labels orelse return false;
        const a2 = l2.sl_labels orelse return false;
        return self.crossing[@intCast(a1.id)][@intCast(a2.id)];
    }

    fn countCrossings(self: *const Assigner, upper: *const sl.SelfHyperLoop, lower_index: usize) i32 {
        const lower_activity = self.activity[lower_index];
        var crossings: i32 = 0;
        for (upper.sl_ports.items) |p| {
            if (lower_activity[@intCast(p.l_port.id)]) crossings += 1;
        }
        return crossings;
    }
};

fn labelsOverlap(l1: *const sl.SelfHyperLoop, l2: *const sl.SelfHyperLoop) bool {
    const a = l1.sl_labels orelse return false;
    const b = l2.sl_labels orelse return false;
    if (a.side != b.side or a.side == .east or a.side == .west) return false;
    const start1 = a.position.x;
    const end1 = start1 + a.size.x;
    const start2 = b.position.x;
    const end2 = start2 + b.size.x;
    return start1 <= end2 and end1 >= start2;
}

pub fn assignRoutingSlots(h: *sl.SelfLoopHolder) lg.Error!void {
    const a = h.a;
    const loops = h.sl_hyper_loops.items;

    var label_id: i32 = 0;
    for (loops) |loop| {
        if (loop.sl_labels) |l| {
            l.id = label_id;
            label_id += 1;
        }
    }
    const n_labels: usize = @intCast(label_id);
    const crossing = try a.alloc([]bool, n_labels);
    for (crossing) |*row| {
        row.* = try a.alloc(bool, n_labels);
        @memset(row.*, false);
    }
    for (loops, 0..) |l1, i| {
        const lab1 = l1.sl_labels orelse continue;
        for (loops[i + 1 ..]) |l2| {
            const lab2 = l2.sl_labels orelse continue;
            const overlap = labelsOverlap(l1, l2);
            crossing[@intCast(lab1.id)][@intCast(lab2.id)] = overlap;
            crossing[@intCast(lab2.id)][@intCast(lab1.id)] = overlap;
        }
    }

    const segments = try a.alloc(*Segment, loops.len);
    // the routing direction is unused by cycle breaking; ELK passes null here
    for (segments) |*s| s.* = try Segment.init(a, .west_to_east);

    const port_count = h.l_node.ports.items.len;
    const activity = try a.alloc([]bool, loops.len);
    for (loops, 0..) |loop, li| {
        const act = try a.alloc(bool, port_count);
        @memset(act, false);
        var idx: i32 = loop.leftmost_port.?.l_port.id - 1;
        const target = loop.rightmost_port.?.l_port.id;
        while (idx != target) {
            idx = @mod(idx + 1, @as(i32, @intCast(port_count)));
            act[@intCast(idx)] = true;
        }
        activity[li] = act;
    }

    var s: Assigner = .{ .a = a, .h = h, .crossing = crossing, .segments = segments, .activity = activity };

    if (loops.len > 0) {
        for (0..loops.len - 1) |fi| {
            for (fi + 1..loops.len) |si| try createDependencies(&s, fi, si);
        }
    }

    try org.OrthogonalRoutingGenerator.breakNonCriticalCycles(a, segments, h.l_node.graph.?.p.random.?);

    try assignRawRoutingSlotsToSegments(a, segments);
    for (loops, 0..) |loop, li| {
        const slot = segments[li].routing_slot;
        for (loop.occupied_port_sides, 0..) |occ, si| {
            if (occ) loop.setRoutingSlot(@fromBackingInt(@intCast(si)), slot);
        }
    }
    const next_free = try a.alloc(i32, port_count);
    @memset(next_free, 0);
    for ([_]lg.PortSide{ .north, .east, .south, .west }) |side| try shiftTowardsNodeOnSide(&s, side, next_free);
}

fn createDependencies(s: *Assigner, first: usize, second: usize) lg.Error!void {
    const l1 = s.h.sl_hyper_loops.items[first];
    const l2 = s.h.sl_hyper_loops.items[second];
    const first_above = s.countCrossings(l1, second);
    const second_above = s.countCrossings(l2, first);
    const seg1 = s.segments[first];
    const seg2 = s.segments[second];
    if (first_above < second_above) {
        _ = try dep_mod.HyperEdgeSegmentDependency.createAndAddRegular(seg1, seg2, second_above - first_above);
    } else if (second_above < first_above) {
        _ = try dep_mod.HyperEdgeSegmentDependency.createAndAddRegular(seg2, seg1, first_above - second_above);
    } else if (first_above != 0 or s.labelsOverlapMatrix(l1, l2)) {
        _ = try dep_mod.HyperEdgeSegmentDependency.createAndAddRegular(seg1, seg2, 0);
        _ = try dep_mod.HyperEdgeSegmentDependency.createAndAddRegular(seg2, seg1, 0);
    }
}

fn assignRawRoutingSlotsToSegments(a: std.mem.Allocator, segments: []*Segment) lg.Error!void {
    var sinks: std.ArrayList(*Segment) = .empty;
    var head: usize = 0;
    for (segments) |seg| {
        seg.in_dep_weight = @intCast(seg.incoming_segment_dependencies.items.len);
        seg.out_dep_weight = @intCast(seg.outgoing_segment_dependencies.items.len);
        if (seg.out_dep_weight == 0) {
            seg.routing_slot = 0;
            try sinks.append(a, seg);
        }
    }
    while (head < sinks.items.len) {
        const seg = sinks.items[head];
        head += 1;
        const next_slot = seg.routing_slot + 1;
        for (seg.incoming_segment_dependencies.items) |dep| {
            const src = dep.source.?;
            src.routing_slot = @max(src.routing_slot, next_slot);
            src.out_dep_weight -= 1;
            if (src.out_dep_weight == 0) try sinks.append(a, src);
        }
    }
}

const SlotCtx = struct { side: lg.PortSide };

fn bySlot(ctx: SlotCtx, x: *sl.SelfHyperLoop, y: *sl.SelfHyperLoop) bool {
    return x.routing_slot[sl.ord(ctx.side)] < y.routing_slot[sl.ord(ctx.side)];
}

fn shiftTowardsNodeOnSide(s: *Assigner, side: lg.PortSide, next_free: []i32) lg.Error!void {
    const a = s.a;
    var loops: std.ArrayList(*sl.SelfHyperLoop) = .empty;
    for (s.h.sl_hyper_loops.items) |loop| {
        if (loop.occupied_port_sides[sl.ord(side)]) try loops.append(a, loop);
    }
    std.mem.sort(*sl.SelfHyperLoop, loops.items, SlotCtx{ .side = side }, bySlot);

    var min_idx: i32 = std.math.maxInt(i32);
    var max_idx: i32 = std.math.minInt(i32);
    for (s.h.l_node.ports.items) |p| {
        if (p.side == side) {
            min_idx = @min(min_idx, p.id);
            max_idx = @max(max_idx, p.id);
        }
    }

    if (min_idx == std.math.maxInt(i32)) {
        for (loops.items, 0..) |loop, i| loop.setRoutingSlot(side, @intCast(i));
        return;
    }

    const slot_assigned_to_label = try a.alloc(i32, s.crossing.len);
    @memset(slot_assigned_to_label, -1);
    for (loops.items) |loop| {
        const active = s.activity[s.indexOf(loop)];
        var lowest: i32 = 0;
        var pi = min_idx;
        while (pi <= max_idx) : (pi += 1) {
            if (active[@intCast(pi)]) lowest = @max(lowest, next_free[@intCast(pi)]);
        }
        if (loop.sl_labels) |lab| {
            const ours: usize = @intCast(lab.id);
            var conflicts: std.ArrayList(i32) = .empty;
            for (s.crossing[ours], 0..) |c, other| {
                if (c) try conflicts.append(a, slot_assigned_to_label[other]);
            }
            while (std.mem.indexOfScalar(i32, conflicts.items, lowest) != null) lowest += 1;
        }
        loop.setRoutingSlot(side, lowest);
        pi = min_idx;
        while (pi <= max_idx) : (pi += 1) {
            if (active[@intCast(pi)]) next_free[@intCast(pi)] = lowest + 1;
        }
        if (loop.sl_labels) |lab| slot_assigned_to_label[@intCast(lab.id)] = lowest;
    }
}
