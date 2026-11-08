const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const EdgeLabel = types.EdgeLabel;
const NodeLabel = types.NodeLabel;

const Ctx = struct {
    a: Allocator,
    g: *Graph,
    root: []const u8,
    node_sep: f64,
    weight: f64,
    height: f64,
    depths: std.StringHashMap(f64),

    fn edgeLabel(self: *Ctx, weight: f64, minlen: f64, nesting: bool) Allocator.Error!*EdgeLabel {
        const l = try self.a.create(EdgeLabel);
        l.* = .{ .weight = weight, .minlen = minlen, .nesting_edge = nesting };
        return l;
    }

    fn dfs(self: *Ctx, v: []const u8) types.Error!void {
        const g = self.g;
        const kids = try self.a.dupe([]const u8, g.children(v).?);
        if (kids.len == 0) {
            if (!std.mem.eql(u8, v, self.root)) {
                try g.setEdge(.{ .v = self.root, .w = v }, try self.edgeLabel(0, self.node_sep, false));
            }
            return;
        }
        const top = try util.addBorderNode(self.a, g, "_bt", null);
        const bottom = try util.addBorderNode(self.a, g, "_bb", null);
        const label = g.node(v).?;
        try g.setParent(top, v);
        label.border_top = top;
        try g.setParent(bottom, v);
        label.border_bottom = bottom;
        const dv = self.depths.get(v).?;
        for (kids) |child| {
            try self.dfs(child);
            const cn = g.node(child).?;
            const child_top = cn.border_top orelse child;
            const child_bottom = cn.border_bottom orelse child;
            const this_weight = if (cn.border_top != null) self.weight else 2 * self.weight;
            const minlen: f64 = if (!std.mem.eql(u8, child_top, child_bottom)) 1 else self.height - dv + 1;
            try g.setEdge(.{ .v = top, .w = child_top }, try self.edgeLabel(this_weight, minlen, true));
            try g.setEdge(.{ .v = child_bottom, .w = bottom }, try self.edgeLabel(this_weight, minlen, true));
        }
        if (g.parent(v) == null) {
            try g.setEdge(.{ .v = self.root, .w = top }, try self.edgeLabel(0, self.height + dv, false));
        }
    }
};

fn treeDepths(a: Allocator, g: *Graph, depths: *std.StringHashMap(f64), v: []const u8, depth: f64) Allocator.Error!void {
    for (g.children(v).?) |c| try treeDepths(a, g, depths, c, depth + 1);
    try depths.put(v, depth);
}

pub fn run(a: Allocator, g: *Graph) types.Error!void {
    const root_label = try a.create(NodeLabel);
    root_label.* = .{};
    const root = try util.addDummyNode(a, g, .root, root_label, "_root");
    var depths = std.StringHashMap(f64).init(a);
    for (try a.dupe([]const u8, g.children(null).?)) |v| try treeDepths(a, g, &depths, v, 1);
    var max_depth: f64 = -std.math.inf(f64);
    var it = depths.valueIterator();
    while (it.next()) |d| max_depth = @max(max_depth, d.*);
    const height = max_depth - 1;
    const node_sep = 2 * height + 1;
    g.label.nesting_root = root;
    var sum: f64 = 0;
    for (g.edges()) |e| {
        const l = g.edgeLabel(e).?;
        l.minlen *= node_sep;
        sum += l.weight;
    }
    var ctx: Ctx = .{ .a = a, .g = g, .root = root, .node_sep = node_sep, .weight = sum + 1, .height = height, .depths = depths };
    for (try a.dupe([]const u8, g.children(null).?)) |child| try ctx.dfs(child);
    g.label.node_rank_factor = node_sep;
}

pub fn cleanup(a: Allocator, g: *Graph) Allocator.Error!void {
    try g.removeNode(g.label.nesting_root.?);
    g.label.nesting_root = null;
    for (try a.dupe(types.Edge, g.edges())) |e| {
        if (g.edgeLabel(e).?.nesting_edge) g.removeEdge(e);
    }
}
