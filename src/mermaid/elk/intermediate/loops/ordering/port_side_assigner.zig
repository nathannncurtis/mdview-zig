// PortSideAssigner. Props: self_loop_distribution (node; Mermaid's root option does not reach nodes, so NORTH).
const std = @import("std");
const lg = @import("../../../lgraph.zig");
const sl = @import("../self_loop_holder.zig");

pub fn assignPortSides(h: *sl.SelfLoopHolder) lg.Error!void {
    switch (h.l_node.p.self_loop_distribution) {
        .north => {
            for (h.sl_hyper_loops.items) |loop| {
                for (loop.sl_ports.items) |p| if (p.is_hidden) p.l_port.setSide(.north);
            }
        },
        .north_south => assignToNorthOrSouthSide(h),
        .equally => try assignToAllSides(h),
    }
}

fn hiddenCount(loop: *const sl.SelfHyperLoop) i32 {
    var n: i32 = 0;
    for (loop.sl_ports.items) |p| n += @intFromBool(p.is_hidden);
    return n;
}

fn assignToNorthOrSouthSide(h: *sl.SelfLoopHolder) void {
    var north_ports: i32 = 0;
    var south_ports: i32 = 0;
    for (h.sl_hyper_loops.items) |loop| {
        var side: lg.PortSide = .undefined;
        if (north_ports <= south_ports) {
            side = .north;
            north_ports += hiddenCount(loop);
        } else if (south_ports < north_ports) {
            side = .south;
            south_ports += hiddenCount(loop);
        }
        for (loop.sl_ports.items) |p| if (p.is_hidden) p.l_port.setSide(side);
    }
}

const Target = struct { first: lg.PortSide, second: lg.PortSide };

const targets = [_]Target{
    .{ .first = .north, .second = .north },
    .{ .first = .south, .second = .south },
    .{ .first = .east, .second = .east },
    .{ .first = .west, .second = .west },
    .{ .first = .west, .second = .north },
    .{ .first = .north, .second = .east },
    .{ .first = .south, .second = .west },
    .{ .first = .east, .second = .south },
};

fn byPortCountDesc(_: void, x: *sl.SelfHyperLoop, y: *sl.SelfHyperLoop) bool {
    return y.sl_ports.items.len < x.sl_ports.items.len;
}

fn byNetFlow(_: void, x: *sl.SelfLoopPort, y: *sl.SelfLoopPort) bool {
    return x.l_port.netFlow() < y.l_port.netFlow();
}

fn assignToAllSides(h: *sl.SelfLoopHolder) lg.Error!void {
    const sorted = try h.a.dupe(*sl.SelfHyperLoop, h.sl_hyper_loops.items);
    std.mem.sort(*sl.SelfHyperLoop, sorted, {}, byPortCountDesc);
    for (sorted, 0..) |loop, i| assignToTarget(loop, targets[i % targets.len]);
}

fn assignToTarget(loop: *sl.SelfHyperLoop, target: Target) void {
    const ports = loop.sl_ports.items;
    if (target.first != target.second) std.mem.sort(*sl.SelfLoopPort, ports, {}, byNetFlow);
    const second_half_start = ports.len / 2;
    for (ports, 0..) |p, i| {
        if (p.is_hidden) p.l_port.setSide(if (i < second_half_start) target.first else target.second);
    }
}
