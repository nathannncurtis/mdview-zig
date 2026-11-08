// PortRestorer. Props: self_loop_ordering (node), port_dummy (ports), origin (dummy ports).
const std = @import("std");
const lg = @import("../../../lgraph.zig");
const sl = @import("../self_loop_holder.zig");

const Area = enum { start, middle, end };
const AddMode = enum { prepend, append };
const PortList = std.ArrayList(*sl.SelfLoopPort);

const Restorer = struct {
    a: std.mem.Allocator,
    target_areas: [sl.side_count][3]PortList = @splat(@splat(.empty)),

    fn area(self: *Restorer, side: lg.PortSide, ar: Area) *PortList {
        return &self.target_areas[sl.ord(side)][@backingInt(ar)];
    }

    fn addPorts(self: *Restorer, ports: []const *sl.SelfLoopPort, side: lg.PortSide, ar: Area, mode: AddMode) lg.Error!void {
        var hidden: PortList = .empty;
        for (ports) |p| if (p.is_hidden) try hidden.append(self.a, p);
        std.mem.reverse(*sl.SelfLoopPort, hidden.items);
        const t = self.area(side, ar);
        if (mode == .prepend) try t.insertSlice(self.a, 0, hidden.items) else try t.appendSlice(self.a, hidden.items);
    }

    fn addLoop(self: *Restorer, loop: *const sl.SelfHyperLoop, side: lg.PortSide, ar: Area, mode: AddMode) lg.Error!void {
        try self.addPorts(loop.portsOnSide(side), side, ar, mode);
    }
};

fn bySlNetFlow(_: void, x: *sl.SelfLoopPort, y: *sl.SelfLoopPort) bool {
    return x.slNetFlow() < y.slNetFlow();
}

pub fn restorePorts(h: *sl.SelfLoopHolder) lg.Error!void {
    var r: Restorer = .{ .a = h.a };
    const ordering = h.l_node.p.self_loop_ordering;

    for (h.sl_hyper_loops.items) |loop| {
        if (loop.self_loop_type != .one_side) continue;
        const side = loop.sl_ports.items[0].l_port.side;
        const sorted = try h.a.dupe(*sl.SelfLoopPort, loop.sl_ports.items);
        std.mem.sort(*sl.SelfLoopPort, sorted, {}, bySlNetFlow);
        switch (ordering) {
            .sequenced => try r.addPorts(sorted, side, .middle, .append),
            .stacked => {
                const split = computePortListSplitIndex(sorted);
                try r.addPorts(sorted[0..split], side, .middle, .prepend);
                try r.addPorts(sorted[split..], side, .middle, .append);
            },
        }
    }
    for (h.sl_hyper_loops.items) |loop| {
        if (loop.self_loop_type != .two_sides_corner) continue;
        const sides = sortedTwoSideLoopPortSides(loop);
        try r.addLoop(loop, sides[0], .end, .prepend);
        try r.addLoop(loop, sides[1], .start, .append);
    }
    for (h.sl_hyper_loops.items) |loop| {
        if (loop.self_loop_type != .three_sides) continue;
        const sides = determineLoopConstellation(loop);
        try r.addLoop(loop, sides[0], .end, .prepend);
        try r.addLoop(loop, sides[1], .middle, .append);
        try r.addLoop(loop, sides[2], .start, .append);
    }
    for (h.sl_hyper_loops.items) |loop| {
        if (loop.self_loop_type != .four_sides) continue;
        for (loop.side_keys.items) |side| try r.addLoop(loop, side, .middle, .append);
    }
    for (h.sl_hyper_loops.items) |loop| {
        if (loop.self_loop_type != .two_sides_opposing) continue;
        const sides = sortedTwoSideLoopPortSides(loop);
        try r.addLoop(loop, sides[0], .end, .prepend);
        try r.addLoop(loop, sides[1], .start, .append);
    }

    try restore(&r, h);

    for (&r.target_areas) |*per_side| {
        for (per_side) |list| {
            for (list.items) |p| p.is_hidden = false;
        }
    }
    h.ports_hidden = false;
}

// ELK's second scan repeats the "> 0" test and the positive index bound; reproduced as is
fn computePortListSplitIndex(sorted: []const *sl.SelfLoopPort) usize {
    var positive: usize = 0;
    while (positive < sorted.len) : (positive += 1) {
        if (sorted[positive].slNetFlow() > 0) break;
    }
    if (positive > 0 and positive + 1 < sorted.len) return positive;
    var non_negative: usize = 0;
    while (non_negative < sorted.len) : (non_negative += 1) {
        if (sorted[non_negative].slNetFlow() > 0) break;
    }
    if (non_negative > 0 and positive + 1 < sorted.len) return non_negative;
    return sorted.len / 2;
}

pub fn sortedTwoSideLoopPortSides(loop: *const sl.SelfHyperLoop) [2]lg.PortSide {
    var sides: [2]lg.PortSide = undefined;
    var n: usize = 0;
    for (0..sl.side_count) |i| {
        if (loop.ports_by_side[i].items.len > 0) {
            sides[n] = @fromBackingInt(@intCast(i));
            n += 1;
        }
    }
    std.debug.assert(n == 2);
    if (sides[0] == .north and sides[1] == .west) return .{ .west, .north };
    return sides;
}

fn determineLoopConstellation(loop: *const sl.SelfHyperLoop) [3]lg.PortSide {
    if (!loop.hasSide(.north)) return .{ .east, .south, .west };
    if (!loop.hasSide(.east)) return .{ .south, .west, .north };
    if (!loop.hasSide(.south)) return .{ .west, .north, .east };
    return .{ .north, .east, .south };
}

fn addAll(r: *Restorer, side: lg.PortSide, ar: Area, node: *lg.LNode) lg.Error!void {
    for (r.area(side, ar).items) |p| try p.l_port.setNode(node);
}

fn addAllThat(old: []const *lg.LPort, from: usize, node: *lg.LNode, comptime cond: fn (*lg.LPort) bool) lg.Error!usize {
    var i = from;
    while (i < old.len) : (i += 1) {
        if (cond(old[i])) try node.ports.append(node.a, old[i]) else return i;
    }
    return old.len;
}

fn isNorth(p: *lg.LPort) bool {
    return p.side == .north;
}
fn isNorthWithWest(p: *lg.LPort) bool {
    return p.side == .north and northSouthPortConnectionSides(p)[sl.ord(.west)];
}
fn isEast(p: *lg.LPort) bool {
    return p.side == .east;
}
fn isSouthWithEast(p: *lg.LPort) bool {
    return p.side == .south and northSouthPortConnectionSides(p)[sl.ord(.east)];
}
fn isSouth(p: *lg.LPort) bool {
    return p.side == .south;
}
fn isWest(p: *lg.LPort) bool {
    return p.side == .west;
}

fn northSouthPortConnectionSides(p: *lg.LPort) [sl.side_count]bool {
    var sides: [sl.side_count]bool = @splat(false);
    const dummy = p.p.port_dummy orelse return sides;
    for (dummy.ports.items) |dp| {
        const from_port = switch (dp.p.origin) {
            .port => |o| o == p,
            else => false,
        };
        if (from_port and dp.degree() > 0) sides[sl.ord(dp.side)] = true;
    }
    return sides;
}

fn restore(r: *Restorer, h: *sl.SelfLoopHolder) lg.Error!void {
    const node = h.l_node;
    const old = try h.a.dupe(*lg.LPort, node.ports.items);
    node.ports.clearRetainingCapacity();
    node.port_sides_cached = false;
    var next: usize = 0;

    try addAll(r, .north, .start, node);
    next = try addAllThat(old, next, node, isNorthWithWest);
    try addAll(r, .north, .middle, node);
    next = try addAllThat(old, next, node, isNorth);
    try addAll(r, .north, .end, node);
    try addAll(r, .east, .start, node);
    try addAll(r, .east, .middle, node);
    next = try addAllThat(old, next, node, isEast);
    try addAll(r, .east, .end, node);
    try addAll(r, .south, .start, node);
    next = try addAllThat(old, next, node, isSouthWithEast);
    try addAll(r, .south, .middle, node);
    next = try addAllThat(old, next, node, isSouth);
    try addAll(r, .south, .end, node);
    try addAll(r, .west, .start, node);
    next = try addAllThat(old, next, node, isWest);
    try addAll(r, .west, .middle, node);
    try addAll(r, .west, .end, node);
}
