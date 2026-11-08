const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const graph = @import("../graph.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Edge = types.Edge;

const TreeNode = struct { low: i64 = 0, lim: i64 = 0, parent: ?[]const u8 = null };
const TreeEdge = struct { cutvalue: f64 = 0 };
const Tree = graph.Graph(TreeNode, TreeEdge, void);

fn rankOf(g: *const Graph, v: []const u8) f64 {
    return g.node(v).?.rank.?;
}

fn slack(g: *const Graph, e: Edge) f64 {
    return rankOf(g, e.w) - rankOf(g, e.v) - g.edgeLabel(e).?.minlen;
}

const LongestPath = struct {
    g: *const Graph,
    visited: std.StringHashMap(void),

    fn visit(self: *LongestPath, v: []const u8) Allocator.Error!f64 {
        const label = self.g.node(v).?;
        if (self.visited.contains(v)) return label.rank orelse std.math.nan(f64);
        try self.visited.put(v, {});
        var best: ?f64 = null;
        for (self.g.outEdges(v).?) |e| {
            const r = (try self.visit(e.w)) - self.g.edgeLabel(e).?.minlen;
            if (best == null or r < best.?) best = r;
        }
        const final = best orelse 0;
        label.rank = final;
        return final;
    }
};

pub fn longestPath(a: Allocator, g: *Graph) Allocator.Error!void {
    var lp: LongestPath = .{ .g = g, .visited = std.StringHashMap(void).init(a) };
    for (try g.sources(a)) |v| _ = try lp.visit(v);
}

fn tightDfs(t: *Tree, g: *const Graph, v: []const u8) Allocator.Error!void {
    inline for (.{ g.inEdges(v).?, g.outEdges(v).? }) |list| {
        for (list) |e| {
            const w = if (std.mem.eql(u8, v, e.v)) e.w else e.v;
            if (!t.hasNode(w) and slack(g, e) == 0) {
                try t.setNode(w, .{});
                try t.setEdge(.{ .v = v, .w = w }, .{});
                try tightDfs(t, g, w);
            }
        }
    }
}

fn tightTree(a: Allocator, t: *Tree, g: *const Graph) Allocator.Error!usize {
    for (try a.dupe([]const u8, t.nodes())) |v| try tightDfs(t, g, v);
    return t.nodeCount();
}

fn feasibleTree(a: Allocator, g: *Graph) types.Error!Tree {
    var t = Tree.init(a, .{ .directed = false }, {});
    const start = g.nodes()[0];
    const size = g.nodeCount();
    try t.setNode(start, .{});
    while (try tightTree(a, &t, g) < size) {
        var best: ?Edge = null;
        var best_slack: f64 = 0;
        for (g.edges()) |e| {
            if (t.hasNode(e.v) != t.hasNode(e.w)) {
                const s = slack(g, e);
                if (std.math.isNan(s)) continue;
                if (best == null or s < best_slack) {
                    best = e;
                    best_slack = s;
                }
            }
        }
        const edge = best orelse return error.Disconnected;
        const delta = if (t.hasNode(edge.v)) slack(g, edge) else -slack(g, edge);
        for (t.nodes()) |v| {
            const n = g.node(v).?;
            n.rank = n.rank.? + delta;
        }
    }
    return t;
}

const Simplex = struct {
    a: Allocator,
    sa: Allocator,
    t: *Tree,
    g: *const Graph,

    fn dfsAssignLowLim(self: *Simplex, visited: *std.StringHashMap(void), next_lim: i64, v: []const u8, parent: ?[]const u8) Allocator.Error!i64 {
        var next = next_lim;
        const low = next;
        const label = self.t.nodePtr(v).?;
        try visited.put(v, {});
        for ((try self.t.neighbors(self.sa, v)).?) |w| {
            if (!visited.contains(w)) next = try self.dfsAssignLowLim(visited, next, w, v);
        }
        label.low = low;
        label.lim = next;
        next += 1;
        label.parent = parent;
        return next;
    }

    fn initLowLim(self: *Simplex) Allocator.Error!void {
        var visited = std.StringHashMap(void).init(self.sa);
        _ = try self.dfsAssignLowLim(&visited, 1, self.t.nodes()[0], null);
    }

    fn dfsOrder(self: *Simplex, visited: *std.StringHashMap(void), acc: *std.ArrayList([]const u8), v: []const u8, post: bool) Allocator.Error!void {
        if (visited.contains(v)) return;
        try visited.put(v, {});
        if (!post) try acc.append(self.sa, v);
        for ((try self.t.neighbors(self.sa, v)).?) |w| try self.dfsOrder(visited, acc, w, post);
        if (post) try acc.append(self.sa, v);
    }

    fn calcCutValue(self: *Simplex, child: []const u8) f64 {
        const t = self.t;
        const g = self.g;
        const parent = t.node(child).?.parent.?;
        var child_is_tail = true;
        var graph_edge = g.edge(child, parent);
        if (graph_edge == null) {
            child_is_tail = false;
            graph_edge = g.edge(parent, child);
        }
        var cut = graph_edge.?.weight;
        inline for (.{ g.inEdges(child).?, g.outEdges(child).? }) |list| {
            for (list) |e| {
                const is_out = std.mem.eql(u8, e.v, child);
                const other = if (is_out) e.w else e.v;
                if (!std.mem.eql(u8, other, parent)) {
                    const points_to_head = is_out == child_is_tail;
                    const other_weight = g.edgeLabel(e).?.weight;
                    cut += if (points_to_head) other_weight else -other_weight;
                    if (t.hasEdge(.{ .v = child, .w = other })) {
                        const oc = t.edge(child, other).?.cutvalue;
                        cut += if (points_to_head) -oc else oc;
                    }
                }
            }
        }
        return cut;
    }

    fn initCutValues(self: *Simplex) Allocator.Error!void {
        var visited = std.StringHashMap(void).init(self.sa);
        var vs: std.ArrayList([]const u8) = .empty;
        for (self.t.nodes()) |v| try self.dfsOrder(&visited, &vs, v, true);
        for (vs.items[0 .. vs.items.len - 1]) |v| {
            const parent = self.t.node(v).?.parent.?;
            self.t.edgeLabelPtr(.{ .v = v, .w = parent }).?.cutvalue = self.calcCutValue(v);
        }
    }

    fn leaveEdge(self: *Simplex) ?Edge {
        for (self.t.edges()) |e| {
            if (self.t.edgeLabel(e).?.cutvalue < 0) return e;
        }
        return null;
    }

    fn isDescendant(v: TreeNode, root: TreeNode) bool {
        return root.low <= v.lim and v.lim <= root.lim;
    }

    fn enterEdge(self: *Simplex, edge: Edge) ?Edge {
        const t = self.t;
        const g = self.g;
        var v = edge.v;
        var w = edge.w;
        if (!g.hasEdge(.{ .v = v, .w = w })) {
            v = edge.w;
            w = edge.v;
        }
        const v_label = t.node(v).?;
        const w_label = t.node(w).?;
        var tail = v_label;
        var flip = false;
        if (v_label.lim > w_label.lim) {
            tail = w_label;
            flip = true;
        }
        var best: ?Edge = null;
        var best_slack: f64 = 0;
        for (g.edges()) |e| {
            if (flip == isDescendant(t.node(e.v).?, tail) and flip != isDescendant(t.node(e.w).?, tail)) {
                const s = slack(g, e);
                if (std.math.isNan(s)) continue;
                if (best == null or s < best_slack) {
                    best = e;
                    best_slack = s;
                }
            }
        }
        return best;
    }

    fn updateRanks(self: *Simplex) Allocator.Error!void {
        const t = self.t;
        const g = self.g;
        // dagre looks the parent up on the graph labels, which never carry one, so the first node is always the root
        const root = t.nodes()[0];
        var visited = std.StringHashMap(void).init(self.sa);
        var vs: std.ArrayList([]const u8) = .empty;
        try self.dfsOrder(&visited, &vs, root, false);
        for (vs.items[1..]) |v| {
            const parent = t.node(v).?.parent.?;
            var label = g.edge(v, parent);
            var flipped = false;
            if (label == null) {
                label = g.edge(parent, v);
                flipped = true;
            }
            g.node(v).?.rank = rankOf(g, parent) + (if (flipped) label.?.minlen else -label.?.minlen);
        }
    }

    fn exchange(self: *Simplex, e: Edge, f: Edge) Allocator.Error!void {
        self.t.removeEdge(e);
        try self.t.setEdge(.{ .v = f.v, .w = f.w }, .{});
        try self.initLowLim();
        try self.initCutValues();
        try self.updateRanks();
    }
};

fn networkSimplex(g0: *Graph, opts: types.Options) types.Error!void {
    var work = std.heap.ArenaAllocator.init(opts.temp);
    defer work.deinit();
    const a = work.allocator();
    var g = try util.simplify(a, g0);
    try longestPath(a, &g);
    var t = try feasibleTree(a, &g);
    var scratch = std.heap.ArenaAllocator.init(opts.temp);
    defer scratch.deinit();
    var s: Simplex = .{ .a = a, .sa = scratch.allocator(), .t = &t, .g = &g };
    try s.initLowLim();
    try s.initCutValues();
    const cap = opts.pivot_cap orelse 100 * (g.nodeCount() + g.edgeCount()) + 10000;
    var pivots: usize = 0;
    while (s.leaveEdge()) |e| : (pivots += 1) {
        if (pivots >= cap) break;
        if (pivots % 64 == 0) try types.checkDeadline(opts);
        _ = scratch.reset(.retain_capacity);
        const f = s.enterEdge(e) orelse break;
        try s.exchange(e, f);
    }
}

pub fn rank(g: *Graph, opts: types.Options) types.Error!void {
    const ranker = g.label.ranker orelse "network-simplex";
    var work = std.heap.ArenaAllocator.init(opts.temp);
    defer work.deinit();
    const a = work.allocator();
    if (std.mem.eql(u8, ranker, "tight-tree")) {
        try longestPath(a, g);
        _ = try feasibleTree(a, g);
    } else if (std.mem.eql(u8, ranker, "longest-path")) {
        try longestPath(a, g);
    } else try networkSimplex(g, opts);
}
