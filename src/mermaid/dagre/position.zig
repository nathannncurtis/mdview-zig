const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const graph = @import("../graph.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Strs = []const []const u8;
const Layers = []const Strs;

const Pair = struct { a: []const u8, b: []const u8 };

const PairCtx = struct {
    pub fn hash(_: PairCtx, p: Pair) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(p.a);
        h.update("\x01");
        h.update(p.b);
        return h.final();
    }
    pub fn eql(_: PairCtx, x: Pair, y: Pair) bool {
        return std.mem.eql(u8, x.a, y.a) and std.mem.eql(u8, x.b, y.b);
    }
};

const Conflicts = std.HashMap(Pair, void, PairCtx, 80);

fn pairOf(v: []const u8, w: []const u8) Pair {
    return if (graph.cmpUtf16(v, w) == .gt) .{ .a = w, .b = v } else .{ .a = v, .b = w };
}

fn addConflict(c: *Conflicts, v: []const u8, w: []const u8) Allocator.Error!void {
    try c.put(pairOf(v, w), {});
}

fn hasConflict(c: *const Conflicts, v: []const u8, w: []const u8) bool {
    return c.contains(pairOf(v, w));
}

fn nodeOf(g: *const Graph, v: []const u8) *types.NodeLabel {
    return g.node(v).?;
}

fn findOtherInnerSegmentNode(g: *const Graph, v: []const u8) ?[]const u8 {
    if (nodeOf(g, v).dummy == .none) return null;
    for (g.predecessors(v).?) |u| {
        if (nodeOf(g, u).dummy != .none) return u;
    }
    return null;
}

fn findType1Conflicts(g: *const Graph, layering: Layers, conflicts: *Conflicts) Allocator.Error!void {
    if (layering.len == 0) return;
    var prev_layer = layering[0];
    for (layering[1..]) |layer| {
        var k0: i64 = 0;
        var scan_pos: usize = 0;
        const prev_len: i64 = @intCast(prev_layer.len);
        const last_node: ?[]const u8 = if (layer.len > 0) layer[layer.len - 1] else null;
        for (layer, 0..) |v, i| {
            const w = findOtherInnerSegmentNode(g, v);
            const k1: i64 = if (w) |wn| nodeOf(g, wn).order else prev_len;
            if (w != null or (last_node != null and std.mem.eql(u8, v, last_node.?))) {
                for (layer[scan_pos .. i + 1]) |scan_node| {
                    for (g.predecessors(scan_node).?) |u| {
                        const u_label = nodeOf(g, u);
                        const u_pos = u_label.order;
                        if ((u_pos < k0 or k1 < u_pos) and !(u_label.dummy != .none and nodeOf(g, scan_node).dummy != .none)) {
                            try addConflict(conflicts, u, scan_node);
                        }
                    }
                }
                scan_pos = i + 1;
                k0 = k1;
            }
        }
        prev_layer = layer;
    }
}

fn lessOpt(x: i64, y: ?i64) bool {
    return y != null and x < y.?;
}

fn greaterOpt(x: i64, y: ?i64) bool {
    return y != null and x > y.?;
}

fn scan(g: *const Graph, conflicts: *Conflicts, south: Strs, south_pos: usize, south_end: usize, prev_north: ?i64, next_north: ?i64) Allocator.Error!void {
    var i = south_pos;
    while (i < south_end) : (i += 1) {
        const v = south[i];
        if (nodeOf(g, v).dummy != .none) {
            for (g.predecessors(v).?) |u| {
                const un = nodeOf(g, u);
                if (un.dummy != .none and (lessOpt(un.order, prev_north) or greaterOpt(un.order, next_north))) {
                    try addConflict(conflicts, u, v);
                }
            }
        }
    }
}

fn findType2Conflicts(g: *const Graph, layering: Layers, conflicts: *Conflicts) Allocator.Error!void {
    if (layering.len == 0) return;
    var north = layering[0];
    for (layering[1..]) |south| {
        var prev_north_pos: ?i64 = -1;
        var next_north_pos: ?i64 = null;
        var south_pos: usize = 0;
        for (south, 0..) |v, lookahead| {
            if (nodeOf(g, v).dummy == .border) {
                const preds = g.predecessors(v).?;
                if (preds.len > 0) {
                    next_north_pos = nodeOf(g, preds[0]).order;
                    try scan(g, conflicts, south, south_pos, lookahead, prev_north_pos, next_north_pos);
                    south_pos = lookahead;
                    prev_north_pos = next_north_pos;
                }
            }
            try scan(g, conflicts, south, south_pos, south.len, next_north_pos, @intCast(north.len));
        }
        north = south;
    }
}

const Names = std.StringHashMap([]const u8);
const Xs = std.StringHashMap(f64);

const Alignment = struct { root: Names, align_: Names };

fn verticalAlignment(a: Allocator, g: *const Graph, layering: Layers, conflicts: *const Conflicts, preds: bool) Allocator.Error!Alignment {
    var root = Names.init(a);
    var align_ = Names.init(a);
    var pos = std.StringHashMap(i64).init(a);
    for (layering) |layer| for (layer, 0..) |v, order| {
        try root.put(v, v);
        try align_.put(v, v);
        try pos.put(v, @intCast(order));
    };
    const Ctx = struct {
        pos: *const std.StringHashMap(i64),
        fn lt(c: @This(), x: []const u8, y: []const u8) bool {
            return c.pos.get(x).? < c.pos.get(y).?;
        }
    };
    for (layering) |layer| {
        var prev_idx: i64 = -1;
        for (layer) |v| {
            const nb = (if (preds) g.predecessors(v) else g.successors(v)).?;
            if (nb.len == 0) continue;
            const ws = try a.dupe([]const u8, nb);
            std.sort.block([]const u8, ws, Ctx{ .pos = &pos }, Ctx.lt);
            const mp = @as(f64, @floatFromInt(ws.len - 1)) / 2;
            var i: usize = @intFromFloat(@floor(mp));
            const il: usize = @intFromFloat(@ceil(mp));
            while (i <= il) : (i += 1) {
                const w = ws[i];
                if (std.mem.eql(u8, align_.get(v).?, v) and prev_idx < pos.get(w).? and !hasConflict(conflicts, v, w)) {
                    try align_.put(w, v);
                    const rw = root.get(w).?;
                    try root.put(v, rw);
                    try align_.put(v, rw);
                    prev_idx = pos.get(w).?;
                }
            }
        }
    }
    return .{ .root = root, .align_ = align_ };
}

fn sep(g: *const Graph, node_sep: f64, edge_sep: f64, reverse_sep: bool, v: []const u8, w: []const u8) f64 {
    const vl = nodeOf(g, v);
    const wl = nodeOf(g, w);
    var sum: f64 = 0;
    var delta: f64 = 0;
    sum += vl.width / 2;
    if (vl.labelpos) |lp| switch (std.ascii.toLower(lp)) {
        'l' => delta = -vl.width / 2,
        'r' => delta = vl.width / 2,
        else => {},
    };
    if (delta != 0) sum += if (reverse_sep) delta else -delta;
    delta = 0;
    sum += (if (vl.dummy != .none) edge_sep else node_sep) / 2;
    sum += (if (wl.dummy != .none) edge_sep else node_sep) / 2;
    sum += wl.width / 2;
    if (wl.labelpos) |lp| switch (std.ascii.toLower(lp)) {
        'l' => delta = wl.width / 2,
        'r' => delta = -wl.width / 2,
        else => {},
    };
    if (delta != 0) sum += if (reverse_sep) delta else -delta;
    return sum;
}

const BlockGraph = graph.Graph(u8, f64, void);

fn buildBlockGraph(a: Allocator, g: *const Graph, layering: Layers, root: *const Names, reverse_sep: bool) Allocator.Error!BlockGraph {
    var bg = BlockGraph.init(a, .{}, {});
    for (layering) |layer| {
        var u: ?[]const u8 = null;
        for (layer) |v| {
            const v_root = root.get(v).?;
            try bg.setNode(v_root, 0);
            if (u) |un| {
                const u_root = root.get(un).?;
                const prev_max = bg.edge(u_root, v_root) orelse 0;
                try bg.setEdge(.{ .v = u_root, .w = v_root }, @max(sep(g, g.label.nodesep, g.label.edgesep, reverse_sep, v, un), prev_max));
            }
            u = v;
        }
    }
    return bg;
}

const Compaction = struct {
    a: Allocator,
    bg: *const BlockGraph,
    g: *const Graph,
    xs: *Xs,
    border_type: types.BorderType,

    fn pass1(self: Compaction, elem: []const u8) Allocator.Error!void {
        var acc: f64 = 0;
        for (self.bg.inEdges(elem).?) |e| acc = @max(acc, (self.xs.get(e.v) orelse std.math.nan(f64)) + self.bg.edgeLabel(e).?);
        try self.xs.put(elem, acc);
    }

    fn pass2(self: Compaction, elem: []const u8) Allocator.Error!void {
        var min = std.math.inf(f64);
        for (self.bg.outEdges(elem).?) |e| min = @min(min, (self.xs.get(e.w) orelse std.math.nan(f64)) - self.bg.edgeLabel(e).?);
        const node = nodeOf(self.g, elem);
        if (min != std.math.inf(f64) and node.border_type != self.border_type) {
            try self.xs.put(elem, @max(self.xs.get(elem).?, min));
        }
    }

    fn iterate(self: Compaction, first_pass: bool) Allocator.Error!void {
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.appendSlice(self.a, self.bg.nodes());
        var visited = std.StringHashMap(void).init(self.a);
        while (stack.pop()) |elem| {
            if (visited.contains(elem)) {
                if (first_pass) try self.pass1(elem) else try self.pass2(elem);
            } else {
                try visited.put(elem, {});
                try stack.append(self.a, elem);
                try stack.appendSlice(self.a, (if (first_pass) self.bg.predecessors(elem) else self.bg.successors(elem)).?);
            }
        }
    }
};

fn horizontalCompaction(a: Allocator, g: *const Graph, layering: Layers, al: Alignment, reverse_sep: bool) Allocator.Error!Xs {
    var xs = Xs.init(a);
    var bg = try buildBlockGraph(a, g, layering, &al.root, reverse_sep);
    const c: Compaction = .{ .a = a, .bg = &bg, .g = g, .xs = &xs, .border_type = if (reverse_sep) .left else .right };
    try c.iterate(true);
    try c.iterate(false);
    for (layering) |layer| for (layer) |v| try xs.put(v, xs.get(al.root.get(v).?).?);
    return xs;
}

fn widthOf(g: *const Graph, v: []const u8) f64 {
    return nodeOf(g, v).width;
}

fn minMax(xs: *const Xs) struct { min: f64, max: f64 } {
    var mn = std.math.inf(f64);
    var mx = -std.math.inf(f64);
    var it = xs.valueIterator();
    while (it.next()) |x| {
        mn = @min(mn, x.*);
        mx = @max(mx, x.*);
    }
    return .{ .min = mn, .max = mx };
}

fn findSmallestWidthAlignment(g: *const Graph, xss: *const [4]Xs) usize {
    var best: usize = 0;
    var best_w: f64 = 0;
    for (xss, 0..) |*xs, i| {
        var mx = -std.math.inf(f64);
        var mn = std.math.inf(f64);
        var it = xs.iterator();
        while (it.next()) |en| {
            const half = widthOf(g, en.key_ptr.*) / 2;
            mx = @max(en.value_ptr.* + half, mx);
            mn = @min(en.value_ptr.* - half, mn);
        }
        const w = mx - mn;
        if (std.math.isNan(w)) continue;
        if (i == 0 or w < best_w) {
            best = i;
            best_w = w;
        }
    }
    return best;
}

fn alignCoordinates(a: Allocator, xss: *[4]Xs, align_to: usize) Allocator.Error!void {
    const target = minMax(&xss[align_to]);
    // order is ul, ur, dl, dr
    for (0..4) |i| {
        if (i == align_to) continue;
        const left = i % 2 == 0;
        const mm = minMax(&xss[i]);
        const delta = if (left) target.min - mm.min else target.max - mm.max;
        if (delta != 0 and !std.math.isNan(delta)) {
            var next = Xs.init(a);
            var it = xss[i].iterator();
            while (it.next()) |en| try next.put(en.key_ptr.*, en.value_ptr.* + delta);
            xss[i] = next;
        }
    }
}

fn balance(a: Allocator, xss: *const [4]Xs, align_: ?[]const u8) Allocator.Error!Xs {
    var out = Xs.init(a);
    var it = xss[0].iterator();
    while (it.next()) |en| {
        const v = en.key_ptr.*;
        if (align_) |al| {
            const names = [_][]const u8{ "ul", "ur", "dl" };
            var idx: usize = 3;
            for (names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(al, n)) idx = i;
            }
            try out.put(v, xss[idx].get(v).?);
        } else {
            var vals: [4]f64 = .{ 0, 0, 0, 0 };
            for (xss, 0..) |*xs, i| vals[i] = xs.get(v).?;
            std.mem.sort(f64, &vals, {}, std.sort.asc(f64));
            try out.put(v, (vals[1] + vals[2]) / 2);
        }
    }
    return out;
}

fn reversedInner(a: Allocator, layers: Layers) Allocator.Error!Layers {
    const out = try a.alloc(Strs, layers.len);
    for (layers, out) |l, *o| {
        const c = try a.dupe([]const u8, l);
        std.mem.reverse([]const u8, c);
        o.* = c;
    }
    return out;
}

fn positionX(a: Allocator, g: *const Graph) Allocator.Error!Xs {
    const layering = try util.buildLayerMatrix(a, g);
    var conflicts = Conflicts.init(a);
    try findType1Conflicts(g, layering, &conflicts);
    try findType2Conflicts(g, layering, &conflicts);
    var xss: [4]Xs = .{ Xs.init(a), Xs.init(a), Xs.init(a), Xs.init(a) };
    const reversed_outer = try a.dupe(Strs, layering);
    std.mem.reverse(Strs, reversed_outer);
    var k: usize = 0;
    for ([_]bool{ true, false }) |up| {
        var adjusted: Layers = if (up) layering else reversed_outer;
        for ([_]bool{ true, false }) |left| {
            if (!left) adjusted = try reversedInner(a, adjusted);
            const al = try verticalAlignment(a, g, adjusted, &conflicts, up);
            var xs = try horizontalCompaction(a, g, adjusted, al, !left);
            if (!left) {
                var it = xs.iterator();
                while (it.next()) |en| en.value_ptr.* = -en.value_ptr.*;
            }
            xss[k] = xs;
            k += 1;
        }
    }
    const smallest = findSmallestWidthAlignment(g, &xss);
    try alignCoordinates(a, &xss, smallest);
    return balance(a, &xss, g.label.@"align");
}

fn positionY(a: Allocator, g: *const Graph) Allocator.Error!void {
    const layering = try util.buildLayerMatrix(a, g);
    const rank_sep = g.label.ranksep;
    var prev_y: f64 = 0;
    for (layering) |layer| {
        var max_h: ?f64 = null;
        for (layer) |v| {
            const h = nodeOf(g, v).height;
            if (max_h == null or h > max_h.?) max_h = h;
        }
        const mh = max_h orelse std.math.nan(f64);
        for (layer) |v| nodeOf(g, v).y = prev_y + mh / 2;
        prev_y += mh + rank_sep;
    }
}

pub fn position(g0: *Graph, opts: types.Options) Allocator.Error!void {
    var work = std.heap.ArenaAllocator.init(opts.temp);
    defer work.deinit();
    const a = work.allocator();
    var g = try util.asNonCompoundGraph(a, g0);
    try positionY(a, &g);
    var xs = try positionX(a, &g);
    var it = xs.iterator();
    while (it.next()) |en| nodeOf(&g, en.key_ptr.*).x = en.value_ptr.*;
}
