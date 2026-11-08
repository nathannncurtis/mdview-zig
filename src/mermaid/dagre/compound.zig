const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const NodeLabel = types.NodeLabel;
const EdgeLabel = types.EdgeLabel;

const Lowlim = struct { low: usize, lim: usize };

const Post = struct {
    g: *const Graph,
    map: std.StringHashMap(Lowlim),
    lim: usize = 0,

    fn dfs(self: *Post, v: []const u8) Allocator.Error!void {
        const low = self.lim;
        for (self.g.children(v).?) |c| try self.dfs(c);
        try self.map.put(v, .{ .low = low, .lim = self.lim });
        self.lim += 1;
    }
};

fn at(path: []const ?[]const u8, i: usize) ?[]const u8 {
    return if (i < path.len) path[i] else null;
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn parentDummyChains(a: Allocator, g: *Graph) types.Error!void {
    var post: Post = .{ .g = g, .map = std.StringHashMap(Lowlim).init(a) };
    for (g.children(null).?) |c| try post.dfs(c);
    for (g.label.dummy_chains.items) |first| {
        var v = first;
        const edge_obj = g.node(v).?.e.?;
        const lo = @min(post.map.get(edge_obj.v).?.low, post.map.get(edge_obj.w).?.low);
        const hi = @max(post.map.get(edge_obj.v).?.lim, post.map.get(edge_obj.w).?.lim);
        var v_path: std.ArrayList(?[]const u8) = .empty;
        var parent: ?[]const u8 = edge_obj.v;
        while (true) {
            parent = g.parent(parent.?);
            try v_path.append(a, parent);
            const p = parent orelse break;
            const pn = post.map.get(p).?;
            if (!(pn.low > lo or hi > pn.lim)) break;
        }
        const lca = parent;
        var w_path: std.ArrayList(?[]const u8) = .empty;
        parent = edge_obj.w;
        while (true) {
            parent = g.parent(parent.?);
            if (eqlOpt(parent, lca)) break;
            try w_path.append(a, parent);
        }
        std.mem.reverse(?[]const u8, w_path.items);
        try v_path.appendSlice(a, w_path.items);
        const path = v_path.items;
        var path_idx: usize = 0;
        var path_v = at(path, path_idx);
        var ascending = true;
        while (!std.mem.eql(u8, v, edge_obj.w)) {
            const node = g.node(v).?;
            const rank = node.rank.?;
            if (ascending) {
                while (true) {
                    path_v = at(path, path_idx);
                    if (eqlOpt(path_v, lca)) break;
                    const mr = g.node(path_v.?).?.max_rank orelse break;
                    if (!(mr < rank)) break;
                    path_idx += 1;
                }
                if (eqlOpt(path_v, lca)) ascending = false;
            }
            if (!ascending) {
                while (path_idx < path.len - 1) {
                    path_v = path[path_idx + 1];
                    const mn = g.node(path_v.?).?.min_rank orelse break;
                    if (!(mn <= rank)) break;
                    path_idx += 1;
                }
                path_v = path[path_idx];
            }
            try g.setParent(v, path_v);
            v = g.successors(v).?[0];
        }
    }
}

fn addBorder(a: Allocator, g: *Graph, left: bool, sg: []const u8, sg_node: *NodeLabel, rank: f64) types.Error!void {
    const label = try a.create(NodeLabel);
    label.* = .{ .rank = rank, .border_type = if (left) .left else .right };
    const list = if (left) &sg_node.border_left else &sg_node.border_right;
    const prev: ?[]const u8 = if (list.items.items.len > 0) list.items.items[list.items.items.len - 1] else null;
    const curr = try util.addDummyNode(a, g, .border, label, if (left) "_bl" else "_br");
    try list.items.append(a, curr);
    try g.setParent(curr, sg);
    if (prev) |p| {
        const l = try a.create(EdgeLabel);
        l.* = .{ .weight = 1 };
        try g.setEdge(.{ .v = p, .w = curr }, l);
    }
}

fn borderDfs(a: Allocator, g: *Graph, v: []const u8) types.Error!void {
    const kids = try a.dupe([]const u8, g.children(v).?);
    const node = g.node(v).?;
    for (kids) |c| try borderDfs(a, g, c);
    if (node.min_rank) |min_rank| {
        node.border_left = .{ .base = @intFromFloat(min_rank) };
        node.border_right = .{ .base = @intFromFloat(min_rank) };
        var rank = min_rank;
        const max = node.max_rank.? + 1;
        while (rank < max) : (rank += 1) {
            try addBorder(a, g, true, v, node, rank);
            try addBorder(a, g, false, v, node, rank);
        }
    }
}

pub fn addBorderSegments(a: Allocator, g: *Graph) types.Error!void {
    for (try a.dupe([]const u8, g.children(null).?)) |v| try borderDfs(a, g, v);
}
