// CoffmanGrahamLayerer. Props read: layering_coffman_graham_layer_bound. Writes LNode.id, LEdge.id, layers.
const std = @import("std");
const lg = @import("../lgraph.zig");

// GWT java.util.PriorityQueue (binary heap); sift-down stops only on a strict win, so ties move down
fn PriorityQueue(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        a: std.mem.Allocator,
        ctx: Ctx,
        heap: std.ArrayList(*lg.LNode) = .empty,

        fn cmp(self: *const Self, x: *lg.LNode, y: *lg.LNode) i32 {
            return self.ctx.compare(x, y);
        }

        fn add(self: *Self, e: *lg.LNode) lg.Error!void {
            var k = self.heap.items.len;
            try self.heap.append(self.a, e);
            const q = self.heap.items;
            while (k > 0) {
                const parent = (k - 1) >> 1;
                if (self.cmp(q[parent], e) <= 0) break;
                q[k] = q[parent];
                k = parent;
            }
            q[k] = e;
        }

        fn poll(self: *Self) ?*lg.LNode {
            if (self.heap.items.len == 0) return null;
            const result = self.heap.items[0];
            const x = self.heap.pop().?;
            const n = self.heap.items.len;
            if (n != 0) {
                const q = self.heap.items;
                var k: usize = 0;
                const half = n >> 1;
                while (k < half) {
                    var child = 2 * k + 1;
                    var c = q[child];
                    const right = child + 1;
                    if (right < n and self.cmp(q[right], c) < 0) {
                        child = right;
                        c = q[child];
                    }
                    if (self.cmp(x, c) < 0) break;
                    q[k] = c;
                    k = child;
                }
                q[k] = x;
            }
            return result;
        }
    };
}

const SourceCtx = struct {
    in_topo: []const std.ArrayList(i32),

    fn compare(self: SourceCtx, u: *lg.LNode, v: *lg.LNode) i32 {
        const list_u = self.in_topo[@intCast(u.id)].items;
        const list_v = self.in_topo[@intCast(v.id)].items;
        var iu = list_u.len;
        var iv = list_v.len;
        var consumed = false;
        while (iu > 0 and iv > 0) {
            iu -= 1;
            iv -= 1;
            consumed = true;
            // elkjs compares the boxed Integers by reference: equal values above 127 are distinct objects
            if (list_u[iu] != list_v[iv] or list_u[iu] > 127 or list_u[iu] < -128) return if (list_u[iu] < list_v[iv]) -1 else if (list_u[iu] > list_v[iv]) 1 else 0;
        }
        // elkjs asks the iterators hasNext, which is true only for a list that was walked
        return if (consumed) 1 else 0;
    }
};

const SinkCtx = struct {
    topo_ord: []const i32,

    fn compare(self: SinkCtx, n1: *lg.LNode, n2: *lg.LNode) i32 {
        const x = self.topo_ord[@intCast(n1.id)];
        const y = self.topo_ord[@intCast(n2.id)];
        return if (x < y) 1 else if (x > y) @as(i32, -1) else 0;
    }
};

const Reduction = struct {
    node_mark: []bool,
    edge_mark: []bool,

    fn dfs(self: *Reduction, start: *lg.LNode, v: *lg.LNode) void {
        if (self.node_mark[@intCast(v.id)]) return;
        for (v.ports.items) |vp| for (vp.outgoing.items) |out| {
            const w = out.target.?.owner.?;
            for (w.ports.items) |wp| for (wp.incoming.items) |transitive| {
                if (transitive.source.?.owner.? == start) self.edge_mark[@intCast(transitive.id)] = true;
            };
            self.dfs(start, w);
        };
        self.node_mark[@intCast(v.id)] = true;
    }
};

fn canAdd(n: *lg.LNode, l: *lg.Layer) bool {
    for (n.ports.items) |p| for (p.outgoing.items) |e| {
        if (e.target.?.owner.?.layer == l) return false;
    };
    return true;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    const nodes = g.layerless_nodes.items;
    if (nodes.len == 0) return;
    const w = g.p.layering_coffman_graham_layer_bound;

    var index: usize = 0;
    var edge_index: usize = 0;
    for (nodes) |n| {
        n.id = @intCast(index);
        index += 1;
        for (n.ports.items) |p| for (p.outgoing.items) |e| {
            e.id = @intCast(edge_index);
            edge_index += 1;
        };
    }
    const node_mark = try a.alloc(bool, index);
    const edge_mark = try a.alloc(bool, edge_index);
    const in_deg = try a.alloc(i32, index);
    const out_deg = try a.alloc(i32, index);
    const topo_ord = try a.alloc(i32, index);
    const in_topo = try a.alloc(std.ArrayList(i32), index);
    @memset(edge_mark, false);
    @memset(in_deg, 0);
    @memset(out_deg, 0);
    @memset(topo_ord, 0);
    @memset(in_topo, .empty);

    var red: Reduction = .{ .node_mark = node_mark, .edge_mark = edge_mark };
    for (nodes) |start| {
        @memset(node_mark, false);
        for (start.ports.items) |p| for (p.outgoing.items) |out| red.dfs(start, out.target.?.owner.?);
    }

    var sources: PriorityQueue(SourceCtx) = .{ .a = a, .ctx = .{ .in_topo = in_topo } };
    for (nodes) |v| {
        for (v.ports.items) |p| for (p.incoming.items) |e| {
            if (!edge_mark[@intCast(e.id)]) in_deg[@intCast(v.id)] += 1;
        };
        if (in_deg[@intCast(v.id)] == 0) try sources.add(v);
    }
    var i: i32 = 0;
    while (sources.poll()) |v| {
        topo_ord[@intCast(v.id)] = i;
        i += 1;
        for (v.ports.items) |p| for (p.outgoing.items) |e| {
            if (edge_mark[@intCast(e.id)]) continue;
            const tgt = e.target.?.owner.?;
            in_deg[@intCast(tgt.id)] -= 1;
            try in_topo[@intCast(tgt.id)].append(a, topo_ord[@intCast(v.id)]);
            if (in_deg[@intCast(tgt.id)] == 0) try sources.add(tgt);
        };
    }

    var sinks: PriorityQueue(SinkCtx) = .{ .a = a, .ctx = .{ .topo_ord = topo_ord } };
    for (nodes) |v| {
        for (v.ports.items) |p| for (p.outgoing.items) |e| {
            if (!edge_mark[@intCast(e.id)]) out_deg[@intCast(v.id)] += 1;
        };
        if (out_deg[@intCast(v.id)] == 0) try sinks.add(v);
    }

    var layers: std.ArrayList(*lg.Layer) = .empty;
    var current = try g.newLayer();
    try layers.append(a, current);
    while (sinks.poll()) |u| {
        if (@as(i64, @intCast(current.nodes.items.len)) >= w or !canAdd(u, current)) {
            current = try g.newLayer();
            try layers.append(a, current);
        }
        try u.setLayer(current);
        for (u.ports.items) |p| for (p.incoming.items) |e| {
            if (edge_mark[@intCast(e.id)]) continue;
            const src = e.source.?.owner.?;
            out_deg[@intCast(src.id)] -= 1;
            if (out_deg[@intCast(src.id)] == 0) try sinks.add(src);
        };
    }

    var j = layers.items.len;
    while (j > 0) {
        j -= 1;
        try g.layers.append(a, layers.items[j]);
    }
    g.layerless_nodes.clearRetainingCapacity();
}
