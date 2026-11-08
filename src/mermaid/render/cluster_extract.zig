const std = @import("std");
const graph_mod = @import("../graph.zig");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const NodeData = model.NodeData;
const EdgeData = model.EdgeData;
const Edge = graph_mod.Edge;

pub const GraphLabel = struct {
    rankdir: []const u8 = "TB",
    nodesep: f64 = 50,
    ranksep: f64 = 50,
    marginx: f64 = 8,
    marginy: f64 = 8,
};

pub const Graph = graph_mod.Graph(*NodeData, *EdgeData, *GraphLabel);

pub const Error = Allocator.Error || graph_mod.ParentError;

pub const ClusterEntry = struct {
    id: ?[]const u8,
    cluster_data: ?*NodeData = null,
    external_connections: bool = false,
    node: ?*NodeData = null,
};

const IdSet = std.StringHashMapUnmanaged(void);

pub fn subGraphOf(node: *const NodeData) ?*Graph {
    return @ptrCast(@alignCast(node.sub_graph));
}

fn placeholder(ctx: *anyopaque, id: []const u8) *NodeData {
    const a: *Allocator = @ptrCast(@alignCast(ctx));
    const n = a.create(NodeData) catch @panic("oom");
    n.* = .{ .id = id };
    return n;
}

pub const State = struct {
    a: Allocator,
    cluster_db: std.StringArrayHashMapUnmanaged(*ClusterEntry) = .empty,
    descendants: std.StringHashMapUnmanaged(*IdSet) = .empty,
    alloc_ptr: *Allocator,

    pub fn init(a: Allocator) Allocator.Error!State {
        const p = try a.create(Allocator);
        p.* = a;
        return .{ .a = a, .alloc_ptr = p };
    }

    pub fn newGraph(self: *State, dir: []const u8) Allocator.Error!*Graph {
        const gl = try self.a.create(GraphLabel);
        gl.* = .{ .rankdir = dir };
        const g = try self.a.create(Graph);
        g.* = Graph.init(self.a, .{ .multigraph = true, .compound = true }, gl);
        g.default_node_fn = .{ .ctx = self.alloc_ptr, .f = placeholder };
        return g;
    }

    pub fn get(self: *const State, id: []const u8) ?*ClusterEntry {
        return self.cluster_db.get(id);
    }

    fn isDescendant(self: *const State, id: []const u8, ancestor: []const u8) bool {
        const set = self.descendants.get(ancestor) orelse return false;
        return set.contains(id);
    }

    fn edgeInCluster(self: *const State, e: Edge, cluster_id: []const u8) bool {
        if (std.mem.eql(u8, e.v, cluster_id) or std.mem.eql(u8, e.w, cluster_id)) return false;
        return self.isDescendant(e.v, cluster_id) or self.isDescendant(e.w, cluster_id);
    }

    fn extractDescendants(self: *State, id: []const u8, g: *const Graph, out: *IdSet) Allocator.Error!void {
        const kids = g.children(id) orelse return;
        for (kids) |c| try out.put(self.a, c, {});
        for (kids) |c| try self.extractDescendants(c, g, out);
    }

    fn childCount(g: *const Graph, id: []const u8) usize {
        return if (g.children(id)) |c| c.len else 0;
    }

    fn copy(self: *State, cluster_id: []const u8, g: *Graph, new_graph: *Graph, root_id: []const u8) Error!void {
        var list: std.ArrayList([]const u8) = .empty;
        if (g.children(cluster_id)) |c| try list.appendSlice(self.a, c);
        if (!std.mem.eql(u8, cluster_id, root_id)) try list.append(self.a, cluster_id);
        for (list.items) |node| {
            if (childCount(g, node) > 0) {
                try self.copy(node, g, new_graph, root_id);
            } else if (g.node(node)) |data| {
                try new_graph.setNode(node, data);
                const par = g.parent(node);
                if (par == null or !std.mem.eql(u8, root_id, par.?)) try new_graph.setParent(node, par);
                if (!std.mem.eql(u8, cluster_id, root_id) and !std.mem.eql(u8, node, cluster_id)) try new_graph.setParent(node, cluster_id);
                const all = try self.a.dupe(Edge, g.edges());
                for (all) |edge| {
                    const edata = g.edgeLabel(edge) orelse continue;
                    if (!self.edgeInCluster(edge, root_id)) continue;
                    try new_graph.setEdge(edge, edata);
                }
            }
            try g.removeNode(node);
        }
    }

    fn findCommonEdges(g: *const Graph, id1: []const u8, id2: []const u8) bool {
        for (g.edges()) |e1| {
            if (!(std.mem.eql(u8, e1.v, id1) or std.mem.eql(u8, e1.w, id1))) continue;
            const v = if (std.mem.eql(u8, e1.v, id1)) id2 else e1.v;
            const w = if (std.mem.eql(u8, e1.w, id1)) id1 else e1.w;
            for (g.edges()) |e2| {
                if (!(std.mem.eql(u8, e2.v, id2) or std.mem.eql(u8, e2.w, id2))) continue;
                if (std.mem.eql(u8, v, e2.v) and std.mem.eql(u8, w, e2.w)) return true;
            }
        }
        return false;
    }

    pub fn findNonClusterChild(self: *const State, id: []const u8, g: *const Graph, cluster_id: ?[]const u8) ?[]const u8 {
        const kids = g.children(id) orelse return id;
        if (kids.len < 1) return id;
        var reserve: ?[]const u8 = null;
        for (kids) |child| {
            const cid = self.findNonClusterChild(child, g, cluster_id);
            if (cid) |x| {
                const common = if (cluster_id) |cl| findCommonEdges(g, cl, x) else false;
                if (common) reserve = x else return x;
            }
        }
        return reserve;
    }

    fn anchorId(self: *const State, id: []const u8) []const u8 {
        const ent = self.cluster_db.get(id) orelse return id;
        if (!ent.external_connections) return id;
        return ent.id orelse id;
    }

    fn isNodeInExtractableCluster(self: *const State, g: *const Graph, node: []const u8, root_id: []const u8) bool {
        var parent = g.parent(node);
        while (parent) |p| {
            if (std.mem.eql(u8, p, root_id)) break;
            if (self.cluster_db.get(p)) |c| if (!c.external_connections) return true;
            parent = g.parent(p);
        }
        return false;
    }

    fn findSafeAnchorNode(self: *const State, g: *const Graph, cluster_id: []const u8, excluded: ?[]const u8) ?[]const u8 {
        const kids = g.children(cluster_id) orelse return null;
        for (kids) |child| {
            if (excluded) |ex| if (std.mem.eql(u8, child, ex) or self.isDescendant(child, ex)) continue;
            const cand = self.findNonClusterChild(child, g, cluster_id) orelse continue;
            if (!self.isNodeInExtractableCluster(g, cand, cluster_id)) return cand;
        }
        return null;
    }

    pub fn adjustClustersAndEdges(self: *State, g: *Graph) Error!void {
        for (try self.a.dupe([]const u8, g.nodes())) |id| {
            if (childCount(g, id) > 0) {
                const set = try self.a.create(IdSet);
                set.* = .empty;
                try self.extractDescendants(id, g, set);
                try self.descendants.put(self.a, id, set);
                const ent = try self.a.create(ClusterEntry);
                ent.* = .{ .id = self.findNonClusterChild(id, g, id), .cluster_data = g.node(id) };
                try self.cluster_db.put(self.a, id, ent);
            }
        }

        for (try self.a.dupe([]const u8, g.nodes())) |id| {
            if (childCount(g, id) == 0) continue;
            for (g.edges()) |edge| {
                const d1 = self.isDescendant(edge.v, id);
                const d2 = self.isDescendant(edge.w, id);
                if (d1 != d2) self.cluster_db.get(id).?.external_connections = true;
            }
        }

        for (self.cluster_db.keys()) |id| {
            const ent = self.cluster_db.get(id).?;
            const non_cluster_child = ent.id;
            const parent: ?[]const u8 = if (non_cluster_child) |n| g.parent(n) else null;
            if (parent) |p| {
                if (!std.mem.eql(u8, p, id)) {
                    if (self.cluster_db.get(p)) |pe| if (!pe.external_connections) {
                        ent.id = p;
                    };
                }
            }
            var has_out = false;
            for (g.edges()) |edge| if (std.mem.eql(u8, edge.v, id)) {
                has_out = true;
                break;
            };
            if (non_cluster_child) |ncc| {
                if (ent.external_connections and has_out and self.isNodeInExtractableCluster(g, ncc, id)) {
                    if (self.findSafeAnchorNode(g, id, g.parent(ncc))) |safe| ent.id = safe;
                }
            }
        }

        for (try self.a.dupe(Edge, g.edges())) |e| {
            const edge = g.edgeLabel(e) orelse continue;
            if (self.cluster_db.get(e.v) == null and self.cluster_db.get(e.w) == null) continue;
            const v = self.anchorId(e.v);
            const w = self.anchorId(e.w);
            g.removeEdge(e);
            if (!std.mem.eql(u8, v, e.v)) {
                if (g.parent(v)) |p| if (self.cluster_db.get(p)) |pe| {
                    pe.external_connections = true;
                };
                edge.from_cluster = e.v;
            }
            if (!std.mem.eql(u8, w, e.w)) {
                if (g.parent(w)) |p| if (self.cluster_db.get(p)) |pe| {
                    pe.external_connections = true;
                };
                edge.to_cluster = e.w;
            }
            try g.setEdge(.{ .v = v, .w = w, .name = e.name }, edge);
        }
        try self.extractor(g, 0);
    }

    fn makeSub(self: *State, g: *Graph, node: []const u8, dir: []const u8) Error!void {
        const cg = try self.newGraph(dir);
        try self.copy(node, g, cg, node);
        const ent = self.cluster_db.get(node).?;
        const nd = try self.a.create(NodeData);
        nd.* = .{ .id = node, .cluster_node = true };
        nd.cluster_data = ent.cluster_data;
        nd.sub_graph = cg;
        try g.setNode(node, nd);
    }

    pub fn extractor(self: *State, g: *Graph, depth: usize) Error!void {
        if (depth > 10) return;
        var has_children = false;
        for (g.nodes()) |n| if (childCount(g, n) > 0) {
            has_children = true;
            break;
        };
        if (!has_children) return;
        for (try self.a.dupe([]const u8, g.nodes())) |node| {
            const ent = self.cluster_db.get(node) orelse continue;
            if (childCount(g, node) == 0) continue;
            if (!ent.external_connections) {
                var dir: []const u8 = if (std.mem.eql(u8, g.label.rankdir, "TB")) "LR" else "TB";
                if (ent.cluster_data) |cd| if (cd.dir) |d| {
                    dir = d;
                };
                try self.makeSub(g, node, dir);
            }
        }
        for (try self.a.dupe([]const u8, g.nodes())) |node| {
            const data = g.node(node) orelse continue;
            if (data.cluster_node) if (subGraphOf(data)) |sg| try self.extractor(sg, depth + 1);
        }
    }
};

fn sorter(a: Allocator, g: *const Graph, nodes: []const []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (nodes.len == 0) return;
    try out.appendSlice(a, nodes);
    for (nodes) |n| {
        const kids = g.children(n) orelse continue;
        try sorter(a, g, kids, out);
    }
}

pub fn sortNodesByHierarchy(a: Allocator, g: *const Graph) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try sorter(a, g, g.children(null) orelse &.{}, &out);
    return out.items;
}

test "a subgraph without outside edges is extracted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = try State.init(a);
    const g = try st.newGraph("TB");
    const names = [_][]const u8{ "sg", "A", "B" };
    for (names) |n| {
        const nd = try a.create(NodeData);
        nd.* = .{ .id = n, .is_group = std.mem.eql(u8, n, "sg") };
        try g.setNode(n, nd);
    }
    try g.setParent("A", "sg");
    try g.setParent("B", "sg");
    const ed = try a.create(EdgeData);
    ed.* = .{ .id = "L1", .start = "A", .end = "B" };
    try g.setEdge(.{ .v = "A", .w = "B", .name = "L1" }, ed);
    try st.adjustClustersAndEdges(g);
    const sg = g.node("sg").?;
    try std.testing.expect(sg.cluster_node);
    const inner = subGraphOf(sg).?;
    try std.testing.expectEqual(@as(usize, 1), inner.edgeCount());
    try std.testing.expectEqual(@as(usize, 1), g.nodeCount());
}

test "a cluster with an explicit direction and outside edges is not extracted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = try State.init(a);
    const g = try st.newGraph("TB");
    const names = [_][]const u8{ "sg", "A", "B", "X" };
    for (names) |n| {
        const nd = try a.create(NodeData);
        nd.* = .{ .id = n, .is_group = std.mem.eql(u8, n, "sg"), .explicit_dir = std.mem.eql(u8, n, "sg"), .dir = if (std.mem.eql(u8, n, "sg")) "LR" else null };
        try g.setNode(n, nd);
    }
    try g.setParent("A", "sg");
    try g.setParent("B", "sg");
    const e1 = try a.create(EdgeData);
    e1.* = .{ .id = "L1", .start = "A", .end = "B" };
    try g.setEdge(.{ .v = "A", .w = "B", .name = "L1" }, e1);
    const e2 = try a.create(EdgeData);
    e2.* = .{ .id = "L2", .start = "X", .end = "A" };
    try g.setEdge(.{ .v = "X", .w = "A", .name = "L2" }, e2);
    try st.adjustClustersAndEdges(g);
    try std.testing.expect(!g.node("sg").?.cluster_node);
    try std.testing.expectEqual(@as(usize, 4), g.nodeCount());
}
