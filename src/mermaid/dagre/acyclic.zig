const std = @import("std");
const types = @import("types.zig");
const graph = @import("../graph.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Edge = types.Edge;

const FasEntry = struct {
    v: []const u8,
    ins: f64 = 0,
    outs: f64 = 0,
    prev: ?*FasEntry = null,
    next: ?*FasEntry = null,
};

const Bucket = struct {
    sentinel: *FasEntry,

    fn init(a: Allocator) Allocator.Error!Bucket {
        const s = try a.create(FasEntry);
        s.* = .{ .v = "" };
        s.next = s;
        s.prev = s;
        return .{ .sentinel = s };
    }

    fn unlink(e: *FasEntry) void {
        e.prev.?.next = e.next;
        e.next.?.prev = e.prev;
        e.next = null;
        e.prev = null;
    }

    fn dequeue(self: Bucket) ?*FasEntry {
        const e = self.sentinel.prev.?;
        if (e == self.sentinel) return null;
        unlink(e);
        return e;
    }

    fn enqueue(self: Bucket, e: *FasEntry) void {
        if (e.prev != null and e.next != null) unlink(e);
        const s = self.sentinel;
        e.next = s.next;
        s.next.?.prev = e;
        s.next = e;
        e.prev = s;
    }
};

const FasGraph = graph.Graph(*FasEntry, f64, void);

fn assignBucket(buckets: []const Bucket, zero_idx: usize, e: *FasEntry) void {
    if (e.outs == 0) {
        buckets[0].enqueue(e);
    } else if (e.ins == 0) {
        buckets[buckets.len - 1].enqueue(e);
    } else {
        const idx: usize = @intFromFloat(e.outs - e.ins + @as(f64, @floatFromInt(zero_idx)));
        buckets[idx].enqueue(e);
    }
}

fn removeFasNode(a: Allocator, g: *FasGraph, buckets: []const Bucket, zero_idx: usize, entry: *FasEntry, collect: ?*std.ArrayList(Edge)) Allocator.Error!void {
    for (g.inEdges(entry.v).?) |e| {
        const weight = g.edgeLabel(e).?;
        const u = g.node(e.v).?;
        if (collect) |c| try c.append(a, .{ .v = e.v, .w = e.w });
        u.outs -= weight;
        assignBucket(buckets, zero_idx, u);
    }
    for (g.outEdges(entry.v).?) |e| {
        const weight = g.edgeLabel(e).?;
        const w = g.node(e.w).?;
        w.ins -= weight;
        assignBucket(buckets, zero_idx, w);
    }
    try g.removeNode(entry.v);
}

fn greedyFas(a: Allocator, g: *Graph) Allocator.Error![]const Edge {
    if (g.nodeCount() <= 1) return &.{};
    var fg = FasGraph.init(a, .{}, {});
    var max_in: f64 = 0;
    var max_out: f64 = 0;
    for (g.nodes()) |v| {
        const en = try a.create(FasEntry);
        en.* = .{ .v = v };
        try fg.setNode(v, en);
    }
    for (g.edges()) |e| {
        const prev = fg.edge(e.v, e.w) orelse 0;
        const weight = g.edgeLabel(e).?.weight;
        try fg.setEdge(.{ .v = e.v, .w = e.w }, prev + weight);
        const nv = fg.node(e.v).?;
        nv.outs += weight;
        max_out = @max(max_out, nv.outs);
        const nw = fg.node(e.w).?;
        nw.ins += weight;
        max_in = @max(max_in, nw.ins);
    }
    const count: usize = @intFromFloat(@ceil(max_out + max_in + 3));
    const buckets = try a.alloc(Bucket, count);
    for (buckets) |*b| b.* = try Bucket.init(a);
    const zero_idx: usize = @intFromFloat(max_in + 1);
    for (fg.nodes()) |v| assignBucket(buckets, zero_idx, fg.node(v).?);

    var results: std.ArrayList(Edge) = .empty;
    const sources = buckets[buckets.len - 1];
    const sinks = buckets[0];
    while (fg.nodeCount() > 0) {
        while (sinks.dequeue()) |entry| try removeFasNode(a, &fg, buckets, zero_idx, entry, null);
        while (sources.dequeue()) |entry| try removeFasNode(a, &fg, buckets, zero_idx, entry, null);
        if (fg.nodeCount() > 0) {
            var i = buckets.len - 2;
            while (i > 0) : (i -= 1) {
                if (buckets[i].dequeue()) |entry| {
                    try removeFasNode(a, &fg, buckets, zero_idx, entry, &results);
                    break;
                }
            }
        }
    }
    var out: std.ArrayList(Edge) = .empty;
    for (results.items) |e| try out.appendSlice(a, try g.outEdgesTo(a, e.v, e.w));
    return out.items;
}

const Dfs = struct {
    g: *const Graph,
    a: Allocator,
    fas: std.ArrayList(Edge) = .empty,
    stack: std.StringHashMap(void),
    visited: std.StringHashMap(void),

    fn visit(self: *Dfs, v: []const u8) Allocator.Error!void {
        if (self.visited.contains(v)) return;
        try self.visited.put(v, {});
        try self.stack.put(v, {});
        for (self.g.outEdges(v).?) |e| {
            if (self.stack.contains(e.w)) {
                try self.fas.append(self.a, e);
            } else try self.visit(e.w);
        }
        _ = self.stack.remove(v);
    }
};

fn dfsFas(a: Allocator, g: *Graph) Allocator.Error![]const Edge {
    var d: Dfs = .{ .g = g, .a = a, .stack = std.StringHashMap(void).init(a), .visited = std.StringHashMap(void).init(a) };
    for (g.nodes()) |v| try d.visit(v);
    return d.fas.items;
}

pub fn run(a: Allocator, g: *Graph) Allocator.Error!void {
    const greedy = if (g.label.acyclicer) |s| std.mem.eql(u8, s, "greedy") else false;
    const fas = if (greedy) try greedyFas(a, g) else try dfsFas(a, g);
    for (fas) |e| {
        const label = g.edgeLabel(e).?;
        g.removeEdge(e);
        label.forward_name = e.name;
        label.reversed = true;
        try g.setEdge(.{ .v = e.w, .w = e.v, .name = try types.nextId(g.label, a, "rev") }, label);
    }
}

pub fn undo(a: Allocator, g: *Graph) Allocator.Error!void {
    for (try a.dupe(Edge, g.edges())) |e| {
        const label = g.edgeLabel(e).?;
        if (label.reversed) {
            g.removeEdge(e);
            const forward_name = label.forward_name;
            label.reversed = false;
            label.forward_name = null;
            try g.setEdge(.{ .v = e.w, .w = e.v, .name = forward_name }, label);
        }
    }
}
