const std = @import("std");
const eg = @import("../elk_graph.zig");
const fg = @import("fgraph.zig");
const Allocator = std.mem.Allocator;

// StressMajorization (Gansner, Koren, North). Dijkstra scans for the nearest open node instead of using a priority
// queue: the distances come out the same.
// shortcut: O(n^2) per source, so O(n^3) all pairs; switch to a heap when graphs reach thousands of nodes.

const unreachable_dist: f64 = 2147483647;

pub const Majorization = struct {
    g: *const fg.FGraph,
    n: usize,
    apsp: []f64,
    w: []f64,
    dim: eg.StressDimension,
    epsilon: f64,
    iteration_limit: i32,

    // StressMajorization.initialize
    pub fn init(a: Allocator, g: *const fg.FGraph) Allocator.Error!Majorization {
        const o = &g.origin.opts;
        const n = g.nodes.items.len;
        var m: Majorization = .{
            .g = g,
            .n = n,
            .apsp = try a.alloc(f64, n * n),
            .w = try a.alloc(f64, n * n),
            .dim = o.stress_dimension orelse .xy,
            .epsilon = o.stress_epsilon orelse 10e-4,
            .iteration_limit = o.stress_iteration_limit orelse std.math.maxInt(i32),
        };
        const common = o.stress_desired_edge_length orelse 100.0;
        const incident = try a.alloc(std.ArrayList(*fg.FEdge), n);
        @memset(incident, .empty);
        for (g.edges.items) |e| {
            try incident[e.source.id].append(a, e);
            try incident[e.target.id].append(a, e);
        }
        const mark = try a.alloc(bool, n);
        for (g.nodes.items) |source| {
            const dist = m.apsp[source.id * n ..][0..n];
            @memset(mark, false);
            @memset(dist, unreachable_dist);
            dist[source.id] = 0;
            for (0..n) |_| {
                var u: usize = n;
                for (0..n) |i| {
                    if (!mark[i] and (u == n or dist[i] < dist[u])) u = i;
                }
                mark[u] = true;
                for (incident[u].items) |e| {
                    const v = if (e.source.id == u) e.target.id else e.source.id;
                    if (mark[v]) continue;
                    const d = dist[u] + (e.origin.opts.stress_desired_edge_length orelse common);
                    if (d < dist[v]) dist[v] = d;
                }
            }
        }
        for (0..n) |i| for (0..n) |j| {
            const d = m.apsp[i * n + j];
            m.w[i * n + j] = 1.0 / (d * d);
        };
        return m;
    }

    // StressMajorization.execute
    pub fn execute(m: *Majorization) void {
        var count: i32 = 0;
        var prev = m.computeStress();
        var cur: f64 = std.math.inf(f64);
        while (true) {
            if (count > 0) prev = cur;
            for (m.g.nodes.items) |u| {
                if (u.fixed) continue;
                const p = m.newPosition(u);
                u.pos = .{ .x = 0 + p.x, .y = 0 + p.y };
            }
            cur = m.computeStress();
            const c = count;
            count +%= 1;
            // a NaN stress never satisfies the epsilon test, where ELK would loop until the iteration limit
            if (m.done(c, prev, cur) or std.math.isNan(cur)) break;
        }
    }

    fn done(m: *const Majorization, count: i32, prev: f64, cur: f64) bool {
        return prev == 0 or ((prev - cur) / prev) < m.epsilon or count >= m.iteration_limit;
    }

    fn euclid(a: *const fg.FNode, b: *const fg.FNode) f64 {
        const dx = a.pos.x - b.pos.x;
        const dy = a.pos.y - b.pos.y;
        return @sqrt((dx * dx) + (dy * dy));
    }

    fn computeStress(m: *const Majorization) f64 {
        var stress: f64 = 0;
        const nodes = m.g.nodes.items;
        for (nodes, 0..) |u, i| {
            for (nodes[i + 1 ..]) |v| {
                const disp = euclid(u, v) - m.apsp[u.id * m.n + v.id];
                stress += m.w[u.id * m.n + v.id] * disp * disp;
            }
        }
        return stress;
    }

    fn newPosition(m: *const Majorization, u: *const fg.FNode) struct { x: f64, y: f64 } {
        var weight_sum: f64 = 0;
        var xd: f64 = 0;
        var yd: f64 = 0;
        for (m.g.nodes.items) |v| {
            if (u == v) continue;
            const wij = m.w[u.id * m.n + v.id];
            const dij = m.apsp[u.id * m.n + v.id];
            weight_sum += wij;
            const euc = euclid(u, v);
            if (euc > 0 and m.dim != .y) xd += wij * (v.pos.x + dij * (u.pos.x - v.pos.x) / euc);
            if (euc > 0 and m.dim != .x) yd += wij * (v.pos.y + dij * (u.pos.y - v.pos.y) / euc);
        }
        return switch (m.dim) {
            .x => .{ .x = xd / weight_sum, .y = u.pos.y },
            .y => .{ .x = u.pos.x, .y = yd / weight_sum },
            .xy => .{ .x = xd / weight_sum, .y = yd / weight_sum },
        };
    }
};
