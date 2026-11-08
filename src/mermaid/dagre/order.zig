const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const graph = @import("../graph.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const NodeLabel = types.NodeLabel;

const LayerLabel = struct { root: []const u8 };
const LayerGraph = graph.Graph(?*NodeLabel, f64, LayerLabel);
const Constraints = graph.Graph(u8, bool, void);
const Strs = []const []const u8;

const BEntry = struct {
    v: []const u8,
    barycenter: ?f64 = null,
    weight: ?f64 = null,
};

const Entry = struct {
    vs: Strs,
    i: usize,
    barycenter: ?f64 = null,
    weight: ?f64 = null,
};

const Result = struct {
    vs: Strs,
    barycenter: ?f64 = null,
    weight: ?f64 = null,
};

fn concat(a: Allocator, parts: []const Strs) Allocator.Error!Strs {
    var out: std.ArrayList([]const u8) = .empty;
    for (parts) |p| try out.appendSlice(a, p);
    return out.items;
}

fn layerDefault(ctx: *anyopaque, v: []const u8) ?*NodeLabel {
    const g: *Graph = @ptrCast(@alignCast(ctx));
    return g.node(v);
}

fn buildLayerGraph(a: Allocator, g: *Graph, rank: f64, in_edges: bool) types.Error!LayerGraph {
    var root = try types.nextId(g.label, a, "_root");
    while (g.hasNode(root)) root = try types.nextId(g.label, a, "_root");
    var result = LayerGraph.init(a, .{ .compound = true }, .{ .root = root });
    result.default_node_fn = .{ .ctx = g, .f = layerDefault };
    for (g.nodes()) |v| {
        const node = g.node(v).?;
        const parent = g.parent(v);
        const in_range = if (node.rank) |r| r == rank else false;
        const in_span = if (node.min_rank) |lo| lo <= rank and rank <= node.max_rank.? else false;
        if (!(in_range or in_span)) continue;
        try result.ensureNode(v);
        try result.setParent(v, parent orelse root);
        for ((if (in_edges) g.inEdges(v) else g.outEdges(v)).?) |e| {
            const u = if (std.mem.eql(u8, e.v, v)) e.w else e.v;
            const prev = result.edge(u, v);
            try result.setEdge(.{ .v = u, .w = v }, g.edgeLabel(e).?.weight + (prev orelse 0));
        }
        if (node.min_rank != null) {
            const l = try a.create(NodeLabel);
            const ri: usize = @intFromFloat(rank);
            l.* = .{ .bl = node.border_left.get(ri), .br = node.border_right.get(ri) };
            try result.setNode(v, l);
        }
    }
    return result;
}

fn barycenters(a: Allocator, g: *const LayerGraph, movable: Strs) Allocator.Error![]BEntry {
    const out = try a.alloc(BEntry, movable.len);
    for (movable, out) |v, *o| {
        const in_v = g.inEdges(v).?;
        if (in_v.len == 0) {
            o.* = .{ .v = v };
            continue;
        }
        var sum: f64 = 0;
        var weight: f64 = 0;
        for (in_v) |e| {
            const w = g.edgeLabel(e).?;
            const u = g.node(e.v).?.?;
            sum += w * @as(f64, @floatFromInt(u.order));
            weight += w;
        }
        o.* = .{ .v = v, .barycenter = sum / weight, .weight = weight };
    }
    return out;
}

// vs lists join in O(1): copying them on every merge is quadratic
const Cell = struct { v: []const u8, next: ?*Cell = null };

const Mapped = struct {
    indegree: i64 = 0,
    in: std.ArrayList(*Mapped) = .empty,
    out: std.ArrayList(*Mapped) = .empty,
    head: *Cell,
    tail: *Cell,
    len: usize = 1,
    i: usize,
    barycenter: ?f64 = null,
    weight: ?f64 = null,
    merged: bool = false,
};

fn mergeEntries(target: *Mapped, source: *Mapped) void {
    var sum: f64 = 0;
    var weight: f64 = 0;
    if (target.weight) |w| if (w != 0 and !std.math.isNan(w)) {
        sum += target.barycenter.? * w;
        weight += w;
    };
    if (source.weight) |w| if (w != 0 and !std.math.isNan(w)) {
        sum += source.barycenter.? * w;
        weight += w;
    };
    source.tail.next = target.head;
    target.head = source.head;
    target.len += source.len;
    target.barycenter = sum / weight;
    target.weight = weight;
    target.i = @min(source.i, target.i);
    source.merged = true;
}

fn resolveConflicts(a: Allocator, entries: []const BEntry, cg: *const Constraints) Allocator.Error![]Entry {
    var mapped = std.StringHashMap(*Mapped).init(a);
    const list = try a.alloc(*Mapped, entries.len);
    const names = try a.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| {
        const m = try a.create(Mapped);
        const cell = try a.create(Cell);
        cell.* = .{ .v = entry.v };
        m.* = .{ .head = cell, .tail = cell, .i = i };
        if (entry.barycenter != null) {
            m.barycenter = entry.barycenter;
            m.weight = entry.weight;
        }
        try mapped.put(entry.v, m);
        list[i] = m;
        names[i] = entry.v;
    }
    for (cg.edges()) |e| {
        const ev = mapped.get(e.v) orelse continue;
        const ew = mapped.get(e.w) orelse continue;
        ew.indegree += 1;
        try ev.out.append(a, ew);
    }
    // sources are visited in JS object key order
    var source_set: std.ArrayList(*Mapped) = .empty;
    for (try graph.jsKeyOrder(a, names)) |k| {
        if (list[k].indegree == 0) try source_set.append(a, list[k]);
    }
    var done: std.ArrayList(*Mapped) = .empty;
    while (source_set.pop()) |entry| {
        try done.append(a, entry);
        std.mem.reverse(*Mapped, entry.in.items);
        for (entry.in.items) |u| {
            if (u.merged) continue;
            if (u.barycenter == null or entry.barycenter == null or u.barycenter.? >= entry.barycenter.?) {
                mergeEntries(entry, u);
            }
        }
        for (entry.out.items) |w| {
            try w.in.append(a, entry);
            w.indegree -= 1;
            if (w.indegree == 0) try source_set.append(a, w);
        }
    }
    var out: std.ArrayList(Entry) = .empty;
    for (done.items) |m| {
        if (m.merged) continue;
        const vs = try a.alloc([]const u8, m.len);
        var c: ?*Cell = m.head;
        for (vs) |*slot| {
            slot.* = c.?.v;
            c = c.?.next;
        }
        try out.append(a, .{ .vs = vs, .i = m.i, .barycenter = m.barycenter, .weight = m.weight });
    }
    return out.items;
}

fn consumeUnsortable(a: Allocator, vs: *std.ArrayList(Strs), unsortable: *std.ArrayList(Entry), index0: usize) Allocator.Error!usize {
    var index = index0;
    while (unsortable.items.len > 0 and unsortable.items[unsortable.items.len - 1].i <= index) {
        const last = unsortable.pop().?;
        try vs.append(a, last.vs);
        index += 1;
    }
    return index;
}

const Bias = struct {
    right: bool,
    fn less(self: Bias, v: Entry, w: Entry) bool {
        const vb = v.barycenter.?;
        const wb = w.barycenter.?;
        if (vb < wb) return true;
        if (vb > wb) return false;
        const vi: i64 = @intCast(v.i);
        const wi: i64 = @intCast(w.i);
        return (if (!self.right) vi - wi else wi - vi) < 0;
    }
};

fn sortEntries(a: Allocator, entries: []const Entry, bias_right: bool) Allocator.Error!Result {
    var sortable: std.ArrayList(Entry) = .empty;
    var unsortable: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        if (e.barycenter != null) try sortable.append(a, e) else try unsortable.append(a, e);
    }
    std.sort.block(Entry, unsortable.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return -@as(i64, @intCast(x.i)) < -@as(i64, @intCast(y.i));
        }
    }.lt);
    var vs: std.ArrayList(Strs) = .empty;
    var sum: f64 = 0;
    var weight: f64 = 0;
    var vs_index: usize = 0;
    std.sort.block(Entry, sortable.items, Bias{ .right = bias_right }, Bias.less);
    vs_index = try consumeUnsortable(a, &vs, &unsortable, vs_index);
    for (sortable.items) |e| {
        vs_index += e.vs.len;
        try vs.append(a, e.vs);
        sum += e.barycenter.? * e.weight.?;
        weight += e.weight.?;
        vs_index = try consumeUnsortable(a, &vs, &unsortable, vs_index);
    }
    var result: Result = .{ .vs = try concat(a, vs.items) };
    if (weight != 0 and !std.math.isNan(weight)) {
        result.barycenter = sum / weight;
        result.weight = weight;
    }
    return result;
}

fn sortSubgraph(a: Allocator, g: *const LayerGraph, v: []const u8, cg: *const Constraints, bias_right: bool) Allocator.Error!Result {
    var movable: Strs = g.children(v).?;
    const node: ?*NodeLabel = g.node(v).?;
    const bl: ?[]const u8 = if (node) |n| n.bl else null;
    const br: ?[]const u8 = if (node) |n| n.br else null;
    if (bl != null) {
        var f: std.ArrayList([]const u8) = .empty;
        for (movable) |w| {
            if (!std.mem.eql(u8, w, bl.?) and !(br != null and std.mem.eql(u8, w, br.?))) try f.append(a, w);
        }
        movable = f.items;
    }
    const bcs = try barycenters(a, g, movable);
    var subgraphs = std.StringHashMap(Result).init(a);
    for (bcs) |*entry| {
        if (g.children(entry.v).?.len > 0) {
            const sub = try sortSubgraph(a, g, entry.v, cg, bias_right);
            try subgraphs.put(entry.v, sub);
            if (sub.barycenter) |sb| {
                if (entry.barycenter) |eb| {
                    entry.barycenter = (eb * entry.weight.? + sb * sub.weight.?) / (entry.weight.? + sub.weight.?);
                    entry.weight = entry.weight.? + sub.weight.?;
                } else {
                    entry.barycenter = sb;
                    entry.weight = sub.weight;
                }
            }
        }
    }
    const entries = try resolveConflicts(a, bcs, cg);
    for (entries) |*entry| {
        var parts: std.ArrayList(Strs) = .empty;
        for (entry.vs) |x| {
            if (subgraphs.get(x)) |sg| {
                try parts.append(a, sg.vs);
            } else {
                const one = try a.alloc([]const u8, 1);
                one[0] = x;
                try parts.append(a, one);
            }
        }
        entry.vs = try concat(a, parts.items);
    }
    var result = try sortEntries(a, entries, bias_right);
    if (bl) |bl_name| {
        const br_name = br.?;
        const vs = try a.alloc([]const u8, result.vs.len + 2);
        vs[0] = bl_name;
        @memcpy(vs[1 .. vs.len - 1], result.vs);
        vs[vs.len - 1] = br_name;
        result.vs = vs;
        const preds = g.predecessors(bl_name).?;
        if (preds.len > 0) {
            const bl_pred = g.node(preds[0]).?.?;
            const br_pred = g.node(g.predecessors(br_name).?[0]).?.?;
            if (result.barycenter == null) {
                result.barycenter = 0;
                result.weight = 0;
            }
            const w = result.weight.?;
            result.barycenter = (result.barycenter.? * w + @as(f64, @floatFromInt(bl_pred.order)) + @as(f64, @floatFromInt(br_pred.order))) / (w + 2);
            result.weight = w + 2;
        }
    }
    return result;
}

fn addSubgraphConstraints(a: Allocator, g: *const LayerGraph, cg: *Constraints, vs: Strs) Allocator.Error!void {
    var prev = std.StringHashMap([]const u8).init(a);
    var root_prev: ?[]const u8 = null;
    for (vs) |v| {
        var child_opt = g.parent(v);
        while (child_opt) |child| {
            const parent = g.parent(child);
            var prev_child: ?[]const u8 = root_prev;
            if (parent) |p| {
                prev_child = prev.get(p);
                try prev.put(p, child);
            } else root_prev = child;
            if (prev_child) |pc| if (!std.mem.eql(u8, pc, child)) {
                try cg.setEdge(.{ .v = pc, .w = child }, true);
                break;
            };
            child_opt = parent;
        }
    }
}

fn crossCount(a: Allocator, g: *const Graph, layering: util.Layering) Allocator.Error!f64 {
    var cc: f64 = 0;
    var i: usize = 1;
    while (i < layering.len) : (i += 1) cc += try twoLayerCrossCount(a, g, layering[i - 1], layering[i]);
    return cc;
}

const SouthEntry = struct { pos: usize, weight: f64 };

fn twoLayerCrossCount(a: Allocator, g: *const Graph, north: Strs, south: Strs) Allocator.Error!f64 {
    var south_pos = std.StringHashMap(usize).init(a);
    for (south, 0..) |v, i| {
        if (v.len > 0) try south_pos.put(v, i);
    }
    var entries: std.ArrayList(SouthEntry) = .empty;
    for (north) |v| {
        const start = entries.items.len;
        for (g.outEdges(v) orelse &.{}) |e| {
            // an edge whose head lost its slot to an order collision adds nothing, as in JS
            const pos = south_pos.get(e.w) orelse continue;
            try entries.append(a, .{ .pos = pos, .weight = g.edgeLabel(e).?.weight });
        }
        std.sort.block(SouthEntry, entries.items[start..], {}, struct {
            fn lt(_: void, x: SouthEntry, y: SouthEntry) bool {
                return x.pos < y.pos;
            }
        }.lt);
    }
    var first_index: usize = 1;
    while (first_index < south.len) first_index <<= 1;
    const tree_size = 2 * first_index - 1;
    first_index -= 1;
    const tree = try a.alloc(f64, tree_size);
    @memset(tree, 0);
    var cc: f64 = 0;
    for (entries.items) |entry| {
        var index = entry.pos + first_index;
        tree[index] += entry.weight;
        var weight_sum: f64 = 0;
        while (index > 0) {
            if (index % 2 == 1) weight_sum += tree[index + 1];
            index = (index - 1) >> 1;
            tree[index] += entry.weight;
        }
        cc += entry.weight * weight_sum;
    }
    return cc;
}

fn initOrder(a: Allocator, g: *const Graph) Allocator.Error![]std.ArrayList([]const u8) {
    var simple: std.ArrayList([]const u8) = .empty;
    var max_rank: f64 = 0;
    for (g.nodes()) |v| {
        if (g.children(v).?.len == 0) {
            try simple.append(a, v);
            max_rank = @max(max_rank, g.node(v).?.rank.?);
        }
    }
    const layers = try a.alloc(std.ArrayList([]const u8), @as(usize, @intFromFloat(max_rank)) + 1);
    for (layers) |*l| l.* = .empty;
    const Ctx = struct {
        g: *const Graph,
        fn lt(c: @This(), x: []const u8, y: []const u8) bool {
            return c.g.node(x).?.rank.? < c.g.node(y).?.rank.?;
        }
    };
    std.sort.block([]const u8, simple.items, Ctx{ .g = g }, Ctx.lt);
    var visited = std.StringHashMap(void).init(a);
    const Dfs = struct {
        g: *const Graph,
        a: Allocator,
        visited: *std.StringHashMap(void),
        layers: []std.ArrayList([]const u8),
        fn visit(self: @This(), v: []const u8) Allocator.Error!void {
            if (self.visited.contains(v)) return;
            try self.visited.put(v, {});
            const node = self.g.node(v).?;
            try self.layers[@intFromFloat(node.rank.?)].append(self.a, v);
            for (self.g.successors(v).?) |w| try self.visit(w);
        }
    };
    const d: Dfs = .{ .g = g, .a = a, .visited = &visited, .layers = layers };
    for (simple.items) |v| try d.visit(v);
    return layers;
}

// A hole in the layering is a node that lost its slot to an order collision; dagre throws on it
fn assignOrder(g: *Graph, layering: util.Layering) types.Error!void {
    for (layering) |layer| for (layer, 0..) |v, i| {
        (g.node(v) orelse return error.LayoutFailed).order = @intCast(i);
    };
}

fn sweep(a: Allocator, layer_graphs: []LayerGraph, bias_right: bool) Allocator.Error!void {
    var cg = Constraints.init(a, .{}, {});
    for (layer_graphs) |*lg| {
        const sorted = try sortSubgraph(a, lg, lg.label.root, &cg, bias_right);
        for (sorted.vs, 0..) |v, i| lg.node(v).?.?.order = @intCast(i);
        try addSubgraphConstraints(a, lg, &cg, sorted.vs);
    }
}

fn cloneLayering(a: Allocator, layering: util.Layering) Allocator.Error!util.Layering {
    const out = try a.alloc([]const []const u8, layering.len);
    for (layering, out) |l, *o| o.* = try a.dupe([]const u8, l);
    return out;
}

pub fn order(g: *Graph, opts: types.Options) types.Error!void {
    const max_rank_f = util.maxRank(g) orelse return;
    var work = std.heap.ArenaAllocator.init(opts.temp);
    defer work.deinit();
    const a = work.allocator();
    const max_rank: i64 = @intFromFloat(max_rank_f);
    var down: std.ArrayList(LayerGraph) = .empty;
    var r: i64 = 1;
    while (r <= max_rank) : (r += 1) try down.append(a, try buildLayerGraph(a, g, @floatFromInt(r), true));
    var up: std.ArrayList(LayerGraph) = .empty;
    r = max_rank - 1;
    while (r >= 0) : (r -= 1) try up.append(a, try buildLayerGraph(a, g, @floatFromInt(r), false));

    var scratch = std.heap.ArenaAllocator.init(opts.temp);
    defer scratch.deinit();
    const initial = try initOrder(a, g);
    const layering0 = try a.alloc([]const []const u8, initial.len);
    for (initial, layering0) |l, *o| o.* = l.items;
    try assignOrder(g, layering0);
    var best_cc = std.math.inf(f64);
    var best: util.Layering = &.{};
    var i: usize = 0;
    var last_best: usize = 0;
    while (last_best < 4) : ({
        i += 1;
        last_best += 1;
    }) {
        try types.checkDeadline(opts);
        _ = scratch.reset(.retain_capacity);
        const sa = scratch.allocator();
        try sweep(sa, if (i % 2 == 1) down.items else up.items, i % 4 >= 2);
        const layering = try util.buildLayerMatrix(sa, g);
        const cc = try crossCount(sa, g, layering);
        if (cc < best_cc) {
            last_best = 0;
            best = try cloneLayering(a, layering);
            best_cc = cc;
        }
    }
    try assignOrder(g, best);
    try util.checkLayering(a, g);
}
