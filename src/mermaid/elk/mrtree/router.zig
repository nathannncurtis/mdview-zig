const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const t = @import("tree.zig");
const Allocator = std.mem.Allocator;
const TNode = t.TNode;
const TEdge = t.TEdge;
const TGraph = t.TGraph;
const Vec = lg.Vec;
const Dir = lg.Direction;

const one_half = 0.5;
const steep_end_edge_threshold_distance = 50.0;
const steep_end_edge_ratio = 5.3;
const steep_end_edge_sample_height = 40.0;

// p4route.EdgeRouter
pub fn route(a: Allocator, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    switch (cfg.routing_mode) {
        .middle_to_middle => for (g.edges.items) |e| try middleToMiddleEdgeRoute(a, e),
        .avoid_overlap => {
            try avoidOverlap(a, g, cfg);
            for (g.edges.items) |e| {
                if (e.bends.items.len < 2) try middleToMiddleEdgeRoute(a, e);
            }
        },
        .none => {},
    }
}

fn middleToMiddleEdgeRoute(a: Allocator, e: *TEdge) Allocator.Error!void {
    const source = e.source;
    const target = e.target;
    const sp = try a.create(Vec);
    sp.* = .{ .x = source.pos.x + source.size.x / 2, .y = source.pos.y + source.size.y / 2 };
    const tp = try a.create(Vec);
    tp.* = .{ .x = target.pos.x + target.size.x / 2, .y = target.pos.y + target.size.y / 2 };
    try e.bends.insert(a, 0, sp);
    try e.bends.append(a, tp);
    t.toNodeBorder(sp, e.bends.items[1].*, source.size);
    t.toNodeBorder(tp, e.bends.items[e.bends.items.len - 2].*, target.size);
}

fn avoidOverlap(a: Allocator, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    const pad = cfg.spacing_edge_node;
    const texture = cfg.edge_end_texture_length;
    const d = g.direction;
    try setStartPoints(a, g, d, pad);
    try specialEdges(a, g, d, pad, texture);
    try setEndPoints(a, g, d, pad, texture);
}

const BendTriple = struct { first: *Vec, second: *Vec, edge: *TEdge };

// p4route.MultiLevelEdgeNodeNodeGap
const Gap = struct {
    neighbor_one: ?*TNode,
    neighbor_two: ?*TNode,
    bends: std.ArrayList(BendTriple) = .empty,
    d: Dir,
    pad: f64,
    on_first_node_side: bool = false,
    on_last_node_side: bool = false,

    fn init(a: Allocator, one: ?*TNode, two: ?*TNode, triple: BendTriple, d: Dir, pad: f64) Allocator.Error!*Gap {
        const gap = try a.create(Gap);
        gap.* = .{ .neighbor_one = one, .neighbor_two = two, .d = d, .pad = pad };
        try gap.bends.append(a, triple);
        gap.update();
        return gap;
    }

    fn addBendPoints(gap: *Gap, a: Allocator, triple: BendTriple) Allocator.Error!void {
        try gap.bends.append(a, triple);
        if (t.isHorizontal(gap.d)) {
            std.mem.sort(BendTriple, gap.bends.items, {}, struct {
                fn less(_: void, x: BendTriple, y: BendTriple) bool {
                    return util.doubleCompare(x.edge.target.pos.y, y.edge.target.pos.y) == .lt;
                }
            }.less);
        } else {
            std.mem.sort(BendTriple, gap.bends.items, {}, struct {
                fn less(_: void, x: BendTriple, y: BendTriple) bool {
                    return util.doubleCompare(x.edge.target.pos.x, y.edge.target.pos.x) == .lt;
                }
            }.less);
        }
        gap.update();
    }

    fn update(gap: *Gap) void {
        const d = gap.d;
        const pad = gap.pad;
        const count: f64 = @floatFromInt(gap.bends.items.len);
        for (gap.bends.items, 0..) |p, idx| {
            const i: f64 = @floatFromInt(idx);
            const interpolation = (i + 1) / (count + 1);
            // SAFETY: assigned before use
            var bend1: Vec = undefined;
            // SAFETY: assigned before use
            var bend2: Vec = undefined;
            // SAFETY: assigned before use
            var bend_tmp: f64 = undefined;
            if (gap.neighbor_one == null and gap.neighbor_two == null) {
                return;
            } else if (gap.neighbor_one != null and gap.neighbor_two == null) {
                const n1 = gap.neighbor_one.?;
                gap.on_last_node_side = true;
                switch (d) {
                    .left => {
                        bend_tmp = n1.pos.y + n1.size.y + pad * (i + 1);
                        bend1 = .{ .x = n1.level_max + pad, .y = bend_tmp };
                        bend2 = .{ .x = n1.level_min - pad, .y = bend_tmp };
                    },
                    .right => {
                        bend_tmp = n1.pos.y + n1.size.y + pad * (i + 1);
                        bend1 = .{ .x = n1.level_min - pad, .y = bend_tmp };
                        bend2 = .{ .x = n1.level_max + pad, .y = bend_tmp };
                    },
                    .up => {
                        bend_tmp = n1.pos.x + n1.size.x + pad * (i + 1);
                        bend1 = .{ .x = bend_tmp, .y = n1.level_max + pad };
                        bend2 = .{ .x = bend_tmp, .y = n1.level_min - pad };
                    },
                    else => {
                        bend_tmp = n1.pos.x + n1.size.x + pad * (i + 1);
                        bend1 = .{ .x = bend_tmp, .y = n1.level_min - pad };
                        bend2 = .{ .x = bend_tmp, .y = n1.level_max + pad };
                    },
                }
            } else if (gap.neighbor_one != null and gap.neighbor_two != null) {
                const n1 = gap.neighbor_one.?;
                const n2 = gap.neighbor_two.?;
                switch (d) {
                    .left => {
                        bend_tmp = n2.pos.y * interpolation + (n1.pos.y + n1.size.y) * (1 - interpolation);
                        bend1 = .{ .x = n1.level_max + pad, .y = bend_tmp };
                        bend2 = .{ .x = n1.level_min - pad, .y = bend_tmp };
                    },
                    .right => {
                        bend_tmp = n2.pos.y * interpolation + (n1.pos.y + n1.size.y) * (1 - interpolation);
                        bend1 = .{ .x = n1.level_min - pad, .y = bend_tmp };
                        bend2 = .{ .x = n1.level_max + pad, .y = bend_tmp };
                    },
                    .up => {
                        bend_tmp = n2.pos.x * interpolation + (n1.pos.x + n1.size.x) * (1 - interpolation);
                        bend1 = .{ .x = bend_tmp, .y = n1.level_max + pad };
                        bend2 = .{ .x = bend_tmp, .y = n1.level_min - pad };
                    },
                    else => {
                        bend_tmp = n2.pos.x * interpolation + (n1.pos.x + n1.size.x) * (1 - interpolation);
                        bend1 = .{ .x = bend_tmp, .y = n1.level_min - pad };
                        bend2 = .{ .x = bend_tmp, .y = n1.level_max + pad };
                    },
                }
            } else {
                const n2 = gap.neighbor_two.?;
                gap.on_first_node_side = true;
                switch (d) {
                    .left => {
                        bend_tmp = n2.pos.y - pad * (i + 1);
                        bend1 = .{ .x = n2.level_max + pad, .y = bend_tmp };
                        bend2 = .{ .x = n2.level_min - pad, .y = bend_tmp };
                    },
                    .right => {
                        bend_tmp = n2.pos.y - pad * (i + 1);
                        bend1 = .{ .x = n2.level_min - pad, .y = bend_tmp };
                        bend2 = .{ .x = n2.level_max + pad, .y = bend_tmp };
                    },
                    .up => {
                        bend_tmp = n2.pos.x - pad * (i + 1);
                        bend1 = .{ .x = bend_tmp, .y = n2.level_max + pad };
                        bend2 = .{ .x = bend_tmp, .y = n2.level_min - pad };
                    },
                    else => {
                        bend_tmp = n2.pos.x - pad * (i + 1);
                        bend1 = .{ .x = bend_tmp, .y = n2.level_min - pad };
                        bend2 = .{ .x = bend_tmp, .y = n2.level_max + pad };
                    },
                }
            }
            p.first.* = bend1;
            p.second.* = bend2;
        }
    }
};

fn lessByX(_: void, x: *TNode, y: *TNode) bool {
    return util.doubleCompare(x.pos.x, y.pos.x) == .lt;
}

fn lessByY(_: void, x: *TNode, y: *TNode) bool {
    return util.doubleCompare(x.pos.y, y.pos.y) == .lt;
}

fn specialEdges(a: Allocator, g: *TGraph, d: Dir, pad: f64, texture: f64) lg.Error!void {
    var side_one: i32 = 0;
    var side_two: i32 = 0;
    var gaps = std.AutoHashMap(i64, *Gap).init(a);
    var max_level: i32 = std.math.minInt(i32);
    for (g.nodes.items) |n| max_level = @max(max_level, n.level);
    max_level += 1;
    const levels: usize = @intCast(max_level);
    const outs_per_level = try a.alloc(i32, levels);
    const ins_per_level = try a.alloc(i32, levels);
    @memset(outs_per_level, 0);
    @memset(ins_per_level, 0);
    var distinct: std.ArrayList(*TEdge) = .empty;
    for (g.edges.items) |e| {
        var seen = false;
        for (distinct.items) |x| if (x == e) {
            seen = true;
            break;
        };
        if (!seen) try distinct.append(a, e);
    }
    const horizontal = t.isHorizontal(d);
    for (distinct.items) |e| {
        const source_level = e.source.level;
        const target_level = e.target.level;
        const level_diff = target_level - source_level;
        if (level_diff > 1) {
            var cur_level = source_level + 1;
            while (cur_level < target_level) : (cur_level += 1) {
                var next_level_nodes: std.ArrayList(*TNode) = .empty;
                for (g.nodes.items) |x| if (x.level == cur_level) try next_level_nodes.append(a, x);
                const nodes = next_level_nodes.items;
                var i: usize = 0;
                if (horizontal) std.mem.sort(*TNode, nodes, {}, lessByY) else std.mem.sort(*TNode, nodes, {}, lessByX);
                const interpolation = @as(f64, @floatFromInt(cur_level - source_level)) / @as(f64, @floatFromInt(target_level - source_level));
                while (i < nodes.len) : (i += 1) {
                    const lhs = if (horizontal) nodes[i].pos.y else nodes[i].pos.x;
                    const sp = if (horizontal) e.source.pos.y else e.source.pos.x;
                    const tp = if (horizontal) e.target.pos.y else e.target.pos.x;
                    if (lhs > sp * (1 - interpolation) + tp * interpolation) break;
                }
                if (nodes.len > 0) {
                    const start: Vec = if (e.bends.items.len == 0) e.source.pos else e.bends.items[e.bends.items.len - 1].*;
                    const last_n = nodes[nodes.len - 1];
                    const last: Vec = .{ .x = last_n.pos.x + last_n.size.x, .y = last_n.pos.y + last_n.size.y };
                    const first: Vec = .{ .x = nodes[0].pos.x + nodes[0].size.x, .y = nodes[0].pos.y + nodes[0].size.y };
                    if (horizontal) {
                        if (i + 1 >= nodes.len and start.y > last.y and e.target.pos.y > last.y) continue;
                        if (i == 0 and start.y < first.x and e.target.pos.y < first.y) continue;
                    } else {
                        if (i + 1 >= nodes.len and start.x > last.x and e.target.pos.x > last.x) continue;
                        if (i == 0 and start.x < first.x and e.target.pos.x < first.x) continue;
                    }
                }
                const bend1 = try a.create(Vec);
                bend1.* = .{};
                const bend2 = try a.create(Vec);
                bend2.* = .{};
                try e.bends.append(a, bend1);
                try e.bends.append(a, bend2);
                const triple: BendTriple = .{ .first = bend1, .second = bend2, .edge = e };
                const key: i64 = (@as(i64, cur_level) << 32) | @as(i64, @intCast(i));
                // SAFETY: assigned before use
                var gap: *Gap = undefined;
                if (gaps.get(key)) |existing| {
                    gap = existing;
                    try gap.addBendPoints(a, triple);
                } else {
                    gap = try Gap.init(a, if (i == 0) null else nodes[i - 1], if (i == nodes.len) null else nodes[i], triple, d, pad);
                    try gaps.put(key, gap);
                }
                if (!horizontal) {
                    if (gap.on_first_node_side and gap.neighbor_two.?.pos.x <= g.xmin) side_one += 1;
                    if (gap.on_last_node_side and gap.neighbor_one.?.pos.x + gap.neighbor_one.?.size.x >= g.xmax) side_two += 1;
                } else {
                    if (gap.on_first_node_side and gap.neighbor_two.?.pos.y <= g.ymin) side_one += 1;
                    if (gap.on_last_node_side and gap.neighbor_one.?.pos.y + gap.neighbor_one.?.size.y >= g.ymax) side_two += 1;
                }
            }
        } else if (level_diff == 0) {
            try middleToMiddleEdgeRoute(a, e);
        } else if (level_diff < 0) {
            outs_per_level[@intCast(source_level)] += 1;
            ins_per_level[@intCast(target_level)] += 1;
            try cycleInducingEdge(a, e, d, g, &side_one, &side_two, pad, texture, ins_per_level[@intCast(target_level)], outs_per_level[@intCast(source_level)]);
        }
    }
}

fn cycleInducingEdge(a: Allocator, e: *TEdge, d: Dir, g: *TGraph, side_one: *i32, side_two: *i32, pad: f64, texture: f64, ins: i32, outs: i32) lg.Error!void {
    const s = e.source;
    const tt = e.target;
    var bend_tmp: f64 = 0;
    var sum: f64 = 0;
    if (t.isHorizontal(d)) {
        for (g.nodes.items) |x| sum += x.pos.y + x.size.y / 2;
        const middle_tree = sum / @as(f64, @floatFromInt(g.nodes.items.len));
        if (s.pos.y + s.size.y / 2 > middle_tree) {
            side_two.* += 1;
            const k: f64 = @floatFromInt(side_two.*);
            bend_tmp = -std.math.inf(f64);
            for (g.nodes.items) |x| bend_tmp = @max(bend_tmp, x.pos.y + x.size.y + pad * k);
        } else {
            side_one.* += 1;
            const k: f64 = @floatFromInt(side_one.*);
            bend_tmp = std.math.inf(f64);
            for (g.nodes.items) |x| bend_tmp = @min(bend_tmp, x.pos.y - pad * k);
        }
    } else {
        for (g.nodes.items) |x| sum += x.pos.x + x.size.x / 2;
        const middle_tree = sum / @as(f64, @floatFromInt(g.nodes.items.len));
        if (s.pos.x + s.size.x / 2 > middle_tree) {
            side_two.* += 1;
            const k: f64 = @floatFromInt(side_two.*);
            bend_tmp = -std.math.inf(f64);
            for (g.nodes.items) |x| bend_tmp = @max(bend_tmp, x.pos.x + x.size.x + pad * k);
        } else {
            side_one.* += 1;
            const k: f64 = @floatFromInt(side_one.*);
            bend_tmp = std.math.inf(f64);
            for (g.nodes.items) |x| bend_tmp = @min(bend_tmp, x.pos.x - pad * k);
        }
    }
    const ins_f: f64 = @floatFromInt(ins);
    const outs_f: f64 = @floatFromInt(outs);
    switch (d) {
        .left => {
            try e.addLast(a, s.level_min - pad, bend_tmp);
            try e.addLast(a, tt.pos.x + tt.size.x + pad + texture, bend_tmp);
            try e.addLast(a, tt.pos.x + tt.size.x + pad + texture, tt.pos.y + tt.size.y / 2);
            try e.addLast(a, tt.pos.x + tt.size.x, tt.pos.y + tt.size.y / 2);
        },
        .right => {
            try e.addLast(a, s.level_max + pad, s.pos.y + s.size.y / 2);
            try e.addLast(a, s.pos.x + s.size.x + pad, bend_tmp);
            try e.addLast(a, tt.pos.x - pad - texture, bend_tmp);
            try e.addLast(a, tt.pos.x - pad - texture, tt.pos.y + tt.size.y / 2);
            try e.addLast(a, tt.pos.x, tt.pos.y + tt.size.y / 2);
        },
        .up => {
            try e.addLast(a, bend_tmp, s.level_min - pad);
            try e.addLast(a, bend_tmp, tt.pos.y + tt.size.y + pad + texture);
            try e.addLast(a, tt.pos.x + tt.size.x / 2, tt.pos.y + tt.size.y + pad + texture);
            try e.addLast(a, tt.pos.x + tt.size.x / 2, tt.pos.y + tt.size.y + pad);
        },
        else => {
            if (e.bends.items.len > 0) {
                e.bends.items[e.bends.items.len - 1].y = s.level_max + pad * outs_f;
            }
            try e.addLast(a, bend_tmp, s.level_max + pad * outs_f);
            try e.addLast(a, bend_tmp, tt.pos.y - pad * ins_f - texture);
        },
    }
}

fn lessFirstX(_: void, x: *TEdge, y: *TEdge) bool {
    return util.doubleCompare(t.firstPoint(x).x, t.firstPoint(y).x) == .lt;
}

fn lessFirstY(_: void, x: *TEdge, y: *TEdge) bool {
    return util.doubleCompare(t.firstPoint(x).y, t.firstPoint(y).y) == .lt;
}

fn lessLastX(_: void, x: *TEdge, y: *TEdge) bool {
    return util.doubleCompare(t.lastPoint(x).x, t.lastPoint(y).x) == .lt;
}

fn lessLastY(_: void, x: *TEdge, y: *TEdge) bool {
    return util.doubleCompare(t.lastPoint(x).y, t.lastPoint(y).y) == .lt;
}

fn setStartPoints(a: Allocator, g: *TGraph, d: Dir, pad: f64) lg.Error!void {
    for (g.nodes.items) |n| {
        if (std.mem.eql(u8, n.label, "SUPER_ROOT")) continue;
        const outs = try t.allOutgoingEdges(a, n, g);
        if (t.isHorizontal(d)) std.mem.sort(*TEdge, outs.items, {}, lessFirstY) else std.mem.sort(*TEdge, outs.items, {}, lessFirstX);
        const num = outs.items.len;
        for (outs.items, 0..) |e, i| {
            const interpolation: f64 = if (num == 1) one_half else @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(num + 1));
            switch (d) {
                .left => {
                    const level_end = n.level_min;
                    const y = n.pos.y + n.size.y * interpolation;
                    try e.addFirst(a, @min(level_end, n.pos.x - pad), y);
                    try e.addFirst(a, n.pos.x, y);
                },
                .right => {
                    const level_end = n.level_max + pad;
                    const y = n.pos.y + n.size.y * interpolation;
                    try e.addFirst(a, level_end, y);
                    try e.addFirst(a, n.pos.x + n.size.x, y);
                },
                .up => {
                    const level_end = n.level_min;
                    const x = n.pos.x + n.size.x * interpolation;
                    try e.addFirst(a, x, @min(n.pos.y - pad, level_end));
                    try e.addFirst(a, x, n.pos.y);
                },
                else => {
                    const level_end = n.level_max + pad;
                    const x = n.pos.x + n.size.x * interpolation;
                    try e.addFirst(a, x, level_end);
                    try e.addFirst(a, x, n.pos.y + n.size.y);
                },
            }
        }
    }
}

fn steep(a: f64, b: f64) bool {
    return @abs(a) / (@abs(b) / steep_end_edge_sample_height) > steep_end_edge_threshold_distance;
}

fn setEndPoints(a: Allocator, g: *TGraph, d: Dir, pad: f64, texture: f64) lg.Error!void {
    for (g.nodes.items) |n| {
        if (std.mem.eql(u8, n.label, "SUPER_ROOT")) continue;
        const ins = try t.allIncomingEdges(a, n, g);
        if (t.isHorizontal(d)) std.mem.sort(*TEdge, ins.items, {}, lessLastY) else std.mem.sort(*TEdge, ins.items, {}, lessLastX);
        const num = ins.items.len;
        for (ins.items, 0..) |e, i| {
            const interpolation: f64 = if (num == 1) one_half else @as(f64, @floatFromInt(1 + i)) / @as(f64, @floatFromInt(num + 1));
            const bends = &e.bends;
            switch (d) {
                .left => {
                    const level_start = n.level_max;
                    if (n.pos.x + n.size.x + texture < level_start) {
                        try e.addLast(a, level_start + pad, n.pos.y + n.size.y * interpolation);
                    } else if (bends.items.len > 0) {
                        const last = bends.items[bends.items.len - 1].*;
                        const next_x = n.pos.x + n.size.x / 2;
                        const next_y = n.pos.y + n.size.y / 2;
                        if (texture > 0 and steep(last.y - next_y, last.x - next_x)) {
                            const dy = if (next_y > last.y) -texture / 2 else texture / 2;
                            try e.addLast(a, n.pos.x + n.size.x + texture / steep_end_edge_ratio, n.pos.y + n.size.y * interpolation + dy);
                        }
                    }
                    try e.addLast(a, n.pos.x + n.size.x, n.pos.y + n.size.y * interpolation);
                },
                .right => {
                    const level_start = n.level_min;
                    if (n.pos.x - texture > level_start) {
                        try e.addLast(a, level_start - pad, n.pos.y + n.size.y * interpolation);
                    } else if (bends.items.len > 0) {
                        const last = bends.items[bends.items.len - 1].*;
                        const next_x = n.pos.x + n.size.x / 2;
                        const next_y = n.pos.y + n.size.y / 2;
                        if (texture > 0 and steep(last.y - next_y, last.x - next_x)) {
                            const dy = if (next_y > last.y) -texture / 2 else texture / 2;
                            try e.addLast(a, n.pos.x - texture / steep_end_edge_ratio, n.pos.y + n.size.y * interpolation + dy);
                        }
                    }
                    try e.addLast(a, n.pos.x, n.pos.y + n.size.y * interpolation);
                },
                .up => {
                    const level_start = n.level_max;
                    if (n.pos.y + n.size.y + texture < level_start) {
                        try e.addLast(a, n.pos.x + n.size.x * interpolation, level_start + pad);
                    } else if (bends.items.len > 0) {
                        const last = bends.items[bends.items.len - 1].*;
                        const next_x = n.pos.x + n.size.x / 2;
                        const next_y = n.pos.y + n.size.y / 2;
                        if (texture > 0 and steep(last.x - next_x, last.y - next_y)) {
                            const dx = if (next_x > last.x) -texture / 2 else texture / 2;
                            try e.addLast(a, n.pos.x + n.size.x * interpolation + dx, n.pos.y + texture / steep_end_edge_ratio + n.size.y);
                        }
                    }
                    try e.addLast(a, n.pos.x + n.size.x * interpolation, n.pos.y + n.size.y);
                },
                else => {
                    const level_start = n.level_min;
                    if (t.isCycleInducing(e, g)) {
                        if (bends.items.len == 0) return error.ElkException;
                        try e.addLast(a, n.pos.x + n.size.x * interpolation, bends.items[bends.items.len - 1].y);
                    } else if (n.pos.y - texture > level_start) {
                        try e.addLast(a, n.pos.x + n.size.x * interpolation, level_start - pad);
                    } else if (bends.items.len > 0) {
                        const last = bends.items[bends.items.len - 1].*;
                        const next_x = n.pos.x + n.size.x / 2;
                        const next_y = n.pos.y + n.size.y / 2;
                        if (texture > 0 and steep(last.x - next_x, last.y - next_y)) {
                            const dx = if (next_x > last.x) -texture / 2 else texture / 2;
                            try e.addLast(a, n.pos.x + n.size.x * interpolation + dx, n.pos.y - texture / steep_end_edge_ratio);
                        }
                    }
                    try e.addLast(a, n.pos.x + n.size.x * interpolation, n.pos.y);
                },
            }
        }
    }
}
