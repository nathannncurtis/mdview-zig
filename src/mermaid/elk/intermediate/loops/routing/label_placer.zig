// LabelPlacer without label management (no label manager is configured). Props: self_loop_ordering (node).
const std = @import("std");
const lg = @import("../../../lgraph.zig");
const sl = @import("../self_loop_holder.zig");

pub fn placeLabels(h: *sl.SelfLoopHolder) lg.Error!void {
    try assignSideAndAlignment(h);
    for (h.sl_hyper_loops.items) |loop| {
        if (loop.sl_labels != null) computeCoordinates(loop);
    }
}

fn set(loop: *sl.SelfHyperLoop, side: lg.PortSide, alignment: sl.Alignment, ref: ?*sl.SelfLoopPort) void {
    const l = loop.sl_labels.?;
    l.side = side;
    l.alignment = alignment;
    l.alignment_reference_sl_port = ref;
}

fn assignSideAndAlignment(h: *sl.SelfLoopHolder) lg.Error!void {
    const a = h.a;
    const sequenced = h.l_node.p.self_loop_ordering == .sequenced;
    var northern: std.ArrayList(*sl.SelfHyperLoop) = .empty;
    var southern: std.ArrayList(*sl.SelfHyperLoop) = .empty;
    for (h.sl_hyper_loops.items) |loop| {
        if (loop.sl_labels == null) continue;
        switch (loop.self_loop_type.?) {
            .one_side => {
                const loop_side = loop.firstOccupiedSide();
                if (sequenced and loop_side == .north) {
                    try northern.append(a, loop);
                } else if (sequenced and loop_side == .south) {
                    try southern.append(a, loop);
                } else {
                    assignOneSidedSimple(loop, loop_side);
                }
            },
            .two_sides_corner => assignTwoSidesCorner(loop),
            .two_sides_opposing, .three_sides => assignTwoSidesOpposingAndThreeSides(loop),
            .four_sides => {
                const s = loop.leftmost_port.?.l_port.side;
                if (s == .north) set(loop, .south, .center, null) else set(loop, .north, .center, null);
            },
        }
    }
    if (sequenced) {
        if (northern.items.len > 0) assignOneSidedSequenced(h, northern.items, .north);
        if (southern.items.len > 0) assignOneSidedSequenced(h, southern.items, .south);
    }
}

fn assignOneSidedSimple(loop: *sl.SelfHyperLoop, side: lg.PortSide) void {
    switch (side) {
        .east, .west => {
            var topmost = loop.leftmost_port.?;
            if (loop.rightmost_port.?.l_port.pos.y < topmost.l_port.pos.y) topmost = loop.rightmost_port.?;
            set(loop, side, .top, topmost);
        },
        .north, .south => set(loop, side, .center, null),
        .undefined => unreachable,
    }
}

const SortCtx = struct { north: bool };

fn byLeftmostId(ctx: SortCtx, x: *sl.SelfHyperLoop, y: *sl.SelfHyperLoop) bool {
    const xi = x.leftmost_port.?.l_port.id;
    const yi = y.leftmost_port.?.l_port.id;
    return if (ctx.north) xi < yi else yi < xi;
}

fn assignOneSidedSequenced(h: *sl.SelfLoopHolder, loops: []*sl.SelfHyperLoop, side: lg.PortSide) void {
    for (h.l_node.ports.items, 0..) |p, i| p.id = @intCast(i);
    std.mem.sort(*sl.SelfHyperLoop, loops, SortCtx{ .north = side == .north }, byLeftmostId);
    var left: usize = 0;
    var right: usize = loops.len - 1;
    while (left < right) {
        const ll = loops[left];
        const rl = loops[right];
        set(ll, side, .right, if (side == .north) ll.rightmost_port else ll.leftmost_port);
        set(rl, side, .left, if (side == .north) rl.leftmost_port else rl.rightmost_port);
        left += 1;
        right -= 1;
    }
    if (left == right) set(loops[left], side, .center, null);
}

fn assignTwoSidesCorner(loop: *sl.SelfHyperLoop) void {
    const ls = loop.leftmost_port.?.l_port.side;
    const rs = loop.rightmost_port.?.l_port.side;
    if (ls == .north) {
        set(loop, .north, .left, loop.leftmost_port);
    } else if (rs == .north) {
        set(loop, .north, .right, loop.rightmost_port);
    } else if (ls == .south) {
        set(loop, .south, .right, loop.leftmost_port);
    } else if (rs == .south) {
        set(loop, .south, .left, loop.rightmost_port);
    }
}

fn assignTwoSidesOpposingAndThreeSides(loop: *sl.SelfHyperLoop) void {
    const occ = loop.occupied_port_sides;
    if (!occ[sl.ord(.north)]) {
        set(loop, .south, .center, null);
    } else if (!occ[sl.ord(.south)]) {
        set(loop, .north, .center, null);
    } else if (!occ[sl.ord(.west)]) {
        set(loop, .north, .left, loop.leftmost_port);
    } else if (!occ[sl.ord(.east)]) {
        set(loop, .north, .right, loop.rightmost_port);
    }
}

fn computeCoordinates(loop: *sl.SelfHyperLoop) void {
    const l = loop.sl_labels.?;
    switch (l.alignment) {
        .center => l.position.x = (loop.sl_holder.l_node.size.x - l.size.x) / 2,
        .left => {
            const p = l.alignment_reference_sl_port.?.l_port;
            l.position.x = p.pos.x + p.anchor.x;
        },
        .right => {
            const p = l.alignment_reference_sl_port.?.l_port;
            l.position.x = p.pos.x + p.anchor.x - l.size.x;
        },
        .top => {
            const p = l.alignment_reference_sl_port.?.l_port;
            l.position.y = p.pos.y + p.anchor.y;
        },
    }
}
