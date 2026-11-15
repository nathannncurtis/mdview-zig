// RoutingDirector. Overwrites LPort.id with the port's index in its node.
const std = @import("std");
const lg = @import("../../../lgraph.zig");
const sl = @import("../self_loop_holder.zig");
const restorer = @import("../ordering/port_restorer.zig");

const unconnected_port_penalty = 1;
const connected_port_penalty = 3;

const Director = struct {
    h: *sl.SelfLoopHolder,
    port_penalties: ?[]i32 = null,

    fn computeEdgePenalty(self: *Director, leftmost: *const sl.SelfLoopPort, rightmost: *const sl.SelfLoopPort) lg.Error!i32 {
        if (self.port_penalties == null) try self.computePenalties();
        const pen = self.port_penalties.?;
        const port_count: i32 = @intCast(self.h.l_node.ports.items.len);
        const left_id = leftmost.l_port.id;
        var left_of_right = rightmost.l_port.id - 1;
        if (left_of_right < 0) left_of_right = port_count - 1;
        const at = struct {
            fn f(p: []i32, i: i32) i32 {
                return p[@intCast(i)];
            }
        }.f;
        if (left_id <= left_of_right) return at(pen, left_of_right) - at(pen, left_id);
        return at(pen, port_count - 1) - at(pen, left_id) + at(pen, left_of_right);
    }

    fn computePenalties(self: *Director) lg.Error!void {
        const ports = self.h.l_node.ports.items;
        const pen = try self.h.a.alloc(i32, ports.len);
        var sum: i32 = 0;
        for (ports, 0..) |p, i| {
            sum += if (p.incoming.items.len == 0 and p.outgoing.items.len == 0) unconnected_port_penalty else connected_port_penalty;
            pen[i] = sum;
        }
        self.port_penalties = pen;
    }
};

fn byId(_: void, x: *sl.SelfLoopPort, y: *sl.SelfLoopPort) bool {
    return x.l_port.id < y.l_port.id;
}

fn lowestPortOnSide(loop: *const sl.SelfHyperLoop, side: lg.PortSide) *sl.SelfLoopPort {
    const ports = loop.portsOnSide(side);
    var best = ports[0];
    for (ports[1..]) |p| if (p.l_port.id < best.l_port.id) {
        best = p;
    };
    return best;
}

fn highestPortOnSide(loop: *const sl.SelfHyperLoop, side: lg.PortSide) *sl.SelfLoopPort {
    const ports = loop.portsOnSide(side);
    var best = ports[0];
    for (ports[1..]) |p| if (p.l_port.id > best.l_port.id) {
        best = p;
    };
    return best;
}

fn assignLeftmostRightmost(loop: *sl.SelfHyperLoop, left_side: lg.PortSide, right_side: lg.PortSide) void {
    loop.leftmost_port = lowestPortOnSide(loop, left_side);
    loop.rightmost_port = highestPortOnSide(loop, right_side);
}

pub fn determineLoopRoutes(h: *sl.SelfLoopHolder) lg.Error!void {
    for (h.l_node.ports.items, 0..) |p, i| p.id = @intCast(i);
    for (h.sl_hyper_loops.items) |loop| std.mem.sort(*sl.SelfLoopPort, loop.sl_ports.items, {}, byId);

    var d: Director = .{ .h = h };
    for (h.sl_hyper_loops.items) |loop| {
        switch (loop.self_loop_type.?) {
            .one_side => {
                const side = loop.sl_ports.items[0].l_port.side;
                assignLeftmostRightmost(loop, side, side);
            },
            .two_sides_corner => {
                const sides = restorer.sortedTwoSideLoopPortSides(loop);
                assignLeftmostRightmost(loop, sides[0], sides[1]);
            },
            .two_sides_opposing => {
                const s0 = loop.side_keys.items[0];
                const s1 = loop.side_keys.items[1];
                const l1 = lowestPortOnSide(loop, s0);
                const r1 = highestPortOnSide(loop, s1);
                const p1 = try d.computeEdgePenalty(l1, r1);
                const l2 = lowestPortOnSide(loop, s1);
                const r2 = highestPortOnSide(loop, s0);
                const p2 = try d.computeEdgePenalty(l2, r2);
                if (p1 <= p2) {
                    loop.leftmost_port = l1;
                    loop.rightmost_port = r1;
                } else {
                    loop.leftmost_port = l2;
                    loop.rightmost_port = r2;
                }
            },
            .three_sides => {
                var missing: lg.PortSide = .undefined;
                for ([_]lg.PortSide{ .north, .east, .south, .west }) |s| {
                    if (!loop.hasSide(s)) {
                        missing = s;
                        break;
                    }
                }
                switch (missing) {
                    .north => assignLeftmostRightmost(loop, .east, .west),
                    .east => assignLeftmostRightmost(loop, .south, .north),
                    .south => assignLeftmostRightmost(loop, .west, .east),
                    .west => assignLeftmostRightmost(loop, .north, .south),
                    .undefined => unreachable,
                }
            },
            .four_sides => {
                const sorted = loop.sl_ports.items;
                var worst_left = sorted[sorted.len - 1];
                var worst_right = sorted[0];
                var worst = try d.computeEdgePenalty(worst_left, worst_right);
                for (1..sorted.len) |ri| {
                    const cur = try d.computeEdgePenalty(sorted[ri - 1], sorted[ri]);
                    if (cur > worst) {
                        worst_left = sorted[ri - 1];
                        worst_right = sorted[ri];
                        worst = cur;
                    }
                }
                loop.leftmost_port = worst_right;
                loop.rightmost_port = worst_left;
            },
        }
        var cur = loop.leftmost_port.?.l_port.side;
        const target = loop.rightmost_port.?.l_port.side;
        while (cur != target) {
            loop.occupied_port_sides[sl.ord(cur)] = true;
            cur = cur.right();
        }
        loop.occupied_port_sides[sl.ord(cur)] = true;
    }
}
