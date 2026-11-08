// OrthogonalSelfLoopRouter. Props: spacing.edge_edge, spacing.edge_label, spacing.node_self_loop (graph values;
// node-level overrides are not tracked). Writes LEdge.bend_points (node-relative) and LNode.margin.
const std = @import("std");
const lg = @import("../../../lgraph.zig");
const sl = @import("../self_loop_holder.zig");
const util = @import("../../../util.zig");

const Dir = enum { clockwise, counter_clockwise };
const Positions = [sl.side_count][]f64;

pub fn routeSelfLoops(h: *sl.SelfLoopHolder) lg.Error!void {
    const a = h.a;
    const node = h.l_node;
    const node_size = node.size;
    const sp = node.graph.?.p.spacing;
    var new_margins = node.margin;

    const positions = try computeRoutingSlotPositions(h, sp.edge_edge, sp.edge_label, sp.node_self_loop);

    for (h.sl_hyper_loops.items) |loop| {
        for (loop.sl_edges.items) |e| {
            const dir = computeEdgeRoutingDirection(e);
            var bend_points: std.ArrayList(lg.Vec) = .empty;
            try addOuterBendPoint(a, e, e.sl_source, positions, &bend_points);
            try addCornerBendPoints(a, e, dir, positions, &bend_points);
            try addOuterBendPoint(a, e, e.sl_target, positions, &bend_points);
            e.l_edge.bend_points.clearRetainingCapacity();
            try e.l_edge.bend_points.appendSlice(e.l_edge.a, bend_points.items);
            for (bend_points.items) |bp| updateNewNodeMargins(node_size, &new_margins, bp);
        }
        if (loop.sl_labels) |labels| {
            placeLabels(loop, labels, positions, sp.edge_label);
            var pos = labels.position;
            updateNewNodeMargins(node_size, &new_margins, pos);
            pos.add(labels.size);
            updateNewNodeMargins(node_size, &new_margins, pos);
        }
    }
    node.margin = new_margins;
}

fn computeEdgeRoutingDirection(e: *const sl.SelfLoopEdge) Dir {
    const src = e.sl_source.l_port;
    const tgt = e.sl_target.l_port;
    const ss = src.side;
    const ts = tgt.side;
    if (ss == ts) return if (src.id < tgt.id) .clockwise else .counter_clockwise;
    if (ss.right() == ts) return .clockwise;
    if (ss.left() == ts) return .counter_clockwise;
    return if (e.sl_hyper_loop.?.occupied_port_sides[sl.ord(ss.right())]) .clockwise else .counter_clockwise;
}

fn placeLabels(loop: *const sl.SelfHyperLoop, labels: *sl.SelfHyperLoopLabels, positions: Positions, edge_label: f64) void {
    const side = labels.side;
    var p = positions[sl.ord(side)][@intCast(loop.routing_slot[sl.ord(side)])];
    switch (side) {
        .north => {
            p -= edge_label + labels.size.y;
            labels.position.y = p;
        },
        .south => {
            p += edge_label;
            labels.position.y = p;
        },
        .west => {
            p -= edge_label + labels.size.x;
            labels.position.x = p;
        },
        .east => {
            p += edge_label;
            labels.position.x = p;
        },
        .undefined => unreachable,
    }
}

fn updateNewNodeMargins(node_size: lg.Vec, m: *lg.Margin, bp: lg.Vec) void {
    m.left = util.javaMax(m.left, -bp.x);
    m.right = util.javaMax(m.right, bp.x - node_size.x);
    m.top = util.javaMax(m.top, -bp.y);
    m.bottom = util.javaMax(m.bottom, bp.y - node_size.y);
}

fn computeRoutingSlotPositions(h: *sl.SelfLoopHolder, edge_edge: f64, edge_label: f64, node_sl: f64) lg.Error!Positions {
    // SAFETY: filled in before it is read
    var positions: Positions = undefined;
    for (0..sl.side_count) |i| {
        positions[i] = try h.a.alloc(f64, @intCast(h.routing_slot_count[i]));
        @memset(positions[i], 0);
    }
    initializeWithMaxLabelHeight(positions, h, .north);
    initializeWithMaxLabelHeight(positions, h, .south);
    for ([_]lg.PortSide{ .north, .east, .south, .west }) |side| computePositions(positions, h, side, edge_edge, edge_label, node_sl);
    return positions;
}

fn initializeWithMaxLabelHeight(positions: Positions, h: *const sl.SelfLoopHolder, side: lg.PortSide) void {
    const side_pos = positions[sl.ord(side)];
    for (h.sl_hyper_loops.items) |loop| {
        const labels = loop.sl_labels orelse continue;
        if (labels.side == side) {
            const slot: usize = @intCast(loop.routing_slot[sl.ord(side)]);
            side_pos[slot] = util.javaMax(side_pos[slot], labels.size.y);
        }
    }
}

fn computePositions(positions: Positions, h: *const sl.SelfLoopHolder, side: lg.PortSide, edge_edge: f64, edge_label: f64, node_sl: f64) void {
    var cur = computeBaselinePosition(h.l_node, side, node_sl);
    const factor: f64 = if (side == .north or side == .west) -1 else 1;
    for (positions[sl.ord(side)]) |*slot_pos| {
        var largest = slot_pos.*;
        if (largest > 0) largest += edge_label;
        slot_pos.* = cur;
        cur += factor * (largest + edge_edge);
    }
}

fn computeBaselinePosition(n: *const lg.LNode, side: lg.PortSide, node_sl: f64) f64 {
    const m = n.margin;
    return switch (side) {
        .north => -m.top - node_sl,
        .east => n.size.x + m.right + node_sl,
        .south => n.size.y + m.bottom + node_sl,
        .west => -m.left - node_sl,
        .undefined => -1,
    };
}

fn baseVector(side: lg.PortSide, slot: i32, positions: Positions) lg.Vec {
    const p = positions[sl.ord(side)][@intCast(slot)];
    return switch (side) {
        .north, .south => .{ .x = 0, .y = p },
        .east, .west => .{ .x = p, .y = 0 },
        .undefined => unreachable,
    };
}

fn addOuterBendPoint(a: std.mem.Allocator, e: *const sl.SelfLoopEdge, port: *const sl.SelfLoopPort, positions: Positions, out: *std.ArrayList(lg.Vec)) lg.Error!void {
    const loop = e.sl_hyper_loop.?;
    const lp = port.l_port;
    var result = baseVector(lp.side, loop.routing_slot[sl.ord(lp.side)], positions);
    var anchor = lp.pos;
    anchor.add(lp.anchor);
    switch (lp.side) {
        .north, .south => result.x += anchor.x,
        .east, .west => result.y += anchor.y,
        .undefined => unreachable,
    }
    try out.append(a, result);
}

fn addCornerBendPoints(a: std.mem.Allocator, e: *const sl.SelfLoopEdge, dir: Dir, positions: Positions, out: *std.ArrayList(lg.Vec)) lg.Error!void {
    const src = e.sl_source.l_port;
    const tgt = e.sl_target.l_port;
    if (src.side == tgt.side) return;
    const loop = e.sl_hyper_loop.?;
    var cur = src.side;
    while (cur != tgt.side) {
        const next = if (dir == .clockwise) cur.right() else cur.left();
        var v = baseVector(cur, loop.routing_slot[sl.ord(cur)], positions);
        v.add(baseVector(next, loop.routing_slot[sl.ord(next)], positions));
        try out.append(a, v);
        cur = next;
    }
}
