const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const Vec = lg.Vec;
const Allocator = std.mem.Allocator;

// The force graph model the stress provider works on: alg.force ElkGraphImporter, FGraph, FNode, FEdge, FLabel and
// ComponentsProcessor. Options not set on an element take the ForceOptions defaults.

const default_spacing_node_node = 80.0;
const default_spacing_edge_label = 5.0;
const default_aspect_ratio = 1.600000023841858;
const default_padding: lg.Margin = .{ .top = 50, .left = 50, .bottom = 50, .right = 50 };

pub const FNode = struct {
    id: usize,
    pos: Vec = .{},
    size: Vec = .{},
    origin: *eg.ElkNode,
    fixed: bool,
    priority: i32,
};

pub const FLabel = struct {
    edge: *FEdge,
    pos: Vec = .{},
    size: Vec = .{},
    origin: *eg.ElkLabel,

    // FLabel.refreshPosition
    pub fn refreshPosition(l: *FLabel) void {
        const src = l.edge.source.pos;
        const tgt = l.edge.target.pos;
        if (l.origin.opts.edge_labels_inline orelse false) {
            const dx = (tgt.x - src.x) * 0.5;
            const dy = (tgt.y - src.y) * 0.5;
            l.pos = .{ .x = src.x + dx - l.size.x * 0.5, .y = src.y + dy - l.size.y * 0.5 };
            return;
        }
        const spacing = l.edge.origin.opts.spacing_edge_label orelse default_spacing_edge_label;
        const p = &l.pos;
        if (src.x >= tgt.x) {
            if (src.y >= tgt.y) {
                p.x = tgt.x + ((src.x - tgt.x) / 2) + spacing;
                p.y = tgt.y + ((src.y - tgt.y) / 2) - spacing - l.size.y;
            } else {
                p.x = tgt.x + ((src.x - tgt.x) / 2) + spacing;
                p.y = src.y + ((tgt.y - src.y) / 2) + spacing;
            }
        } else if (src.y >= tgt.y) {
            p.x = src.x + ((tgt.x - src.x) / 2) + spacing;
            p.y = tgt.y + ((src.y - tgt.y) / 2) + spacing;
        } else {
            p.x = src.x + ((tgt.x - src.x) / 2) + spacing;
            p.y = src.y + ((tgt.y - src.y) / 2) - spacing - l.size.y;
        }
    }
};

pub const FEdge = struct {
    source: *FNode,
    target: *FNode,
    origin: *eg.ElkEdge,
    labels: std.ArrayList(*FLabel) = .empty,

    // ElkMath.clipVector applied to the centre to centre vector
    fn clippedPoint(from: *const FNode, to: *const FNode) Vec {
        var v: Vec = .{ .x = to.pos.x - from.pos.x, .y = to.pos.y - from.pos.y };
        const wh = from.size.x / 2;
        const hh = from.size.y / 2;
        const absx = @abs(v.x);
        const absy = @abs(v.y);
        const xscale = if (absx > wh) wh / absx else 1;
        const yscale = if (absy > hh) hh / absy else 1;
        const s = @min(xscale, yscale);
        v.x *= s;
        v.y *= s;
        return .{ .x = v.x + from.pos.x, .y = v.y + from.pos.y };
    }

    pub fn sourcePoint(e: *const FEdge) Vec {
        return clippedPoint(e.source, e.target);
    }

    pub fn targetPoint(e: *const FEdge) Vec {
        return clippedPoint(e.target, e.source);
    }
};

pub const FGraph = struct {
    nodes: std.ArrayList(*FNode) = .empty,
    edges: std.ArrayList(*FEdge) = .empty,
    labels: std.ArrayList(*FLabel) = .empty,
    origin: *eg.ElkNode,
    priority: i32 = 0,
    bb_upleft: Vec = .{},
    bb_lowright: Vec = .{},

    fn bbSize(g: *const FGraph) Vec {
        return .{ .x = g.bb_lowright.x - g.bb_upleft.x, .y = g.bb_lowright.y - g.bb_upleft.y };
    }
};

// ElkEdge.isHierarchical
fn isHierarchical(e: *const eg.ElkEdge) bool {
    var common: ?*eg.ElkNode = null;
    for ([_][]const eg.Shape{ e.sources.items, e.targets.items }) |list| {
        for (list) |s| {
            const n = s.toNode();
            if (common == null) {
                common = n.parent;
            } else if (common != n.parent) {
                return true;
            }
        }
    }
    return false;
}

// ElkGraphImporter.importGraph
pub fn importGraph(a: Allocator, kgraph: *eg.ElkNode) lg.Error!FGraph {
    var g: FGraph = .{ .origin = kgraph };
    var map: std.AutoHashMapUnmanaged(*eg.ElkNode, *FNode) = .empty;
    for (kgraph.children.items, 0..) |kn, i| {
        const n = try a.create(FNode);
        n.* = .{
            .id = i,
            .pos = .{ .x = kn.x + kn.width / 2, .y = kn.y + kn.height / 2 },
            .size = .{ .x = @max(kn.width, 1), .y = @max(kn.height, 1) },
            .origin = kn,
            .fixed = kn.opts.stress_fixed orelse false,
            .priority = kn.opts.priority orelse 1,
        };
        try g.nodes.append(a, n);
        try map.put(a, kn, n);
    }
    for (kgraph.children.items) |kn| {
        try importEdges(a, &g, &map, kn, kn.outgoing_edges.items);
        for (kn.ports.items) |p| try importEdges(a, &g, &map, kn, p.outgoing_edges.items);
    }
    return g;
}

fn importEdges(a: Allocator, g: *FGraph, map: *std.AutoHashMapUnmanaged(*eg.ElkNode, *FNode), kn: *eg.ElkNode, edges: []const *eg.ElkEdge) lg.Error!void {
    for (edges) |ke| {
        if (ke.isHyperedge()) return error.Unsupported;
        const tn = ke.targets.items[0].toNode();
        if (isHierarchical(ke) or kn == tn) continue;
        const fe = try a.create(FEdge);
        fe.* = .{ .source = map.get(kn).?, .target = map.get(tn).?, .origin = ke };
        try g.edges.append(a, fe);
        for (ke.labels.items) |kl| {
            const fl = try a.create(FLabel);
            fl.* = .{ .edge = fe, .origin = kl, .size = .{ .x = @max(kl.width, 1), .y = @max(kl.height, 1) } };
            fl.refreshPosition();
            try fe.labels.append(a, fl);
            try g.labels.append(a, fl);
        }
    }
}

const Splitter = struct {
    a: Allocator,
    visited: []bool,
    incidence: []std.ArrayList(*FEdge),

    // ComponentsProcessor.dfs: an edge to a node already reached through another path is added once per end
    fn dfs(s: *Splitter, node: *FNode, last: ?*FNode, comp: *FGraph) Allocator.Error!void {
        if (s.visited[node.id]) return;
        s.visited[node.id] = true;
        try comp.nodes.append(s.a, node);
        for (s.incidence[node.id].items) |e| {
            if (e.target == last or e.source == last) continue;
            if (e.source != node) try s.dfs(e.source, node, comp);
            if (e.target != node) try s.dfs(e.target, node, comp);
            try comp.edges.append(s.a, e);
            try comp.labels.appendSlice(s.a, e.labels.items);
        }
    }
};

// ComponentsProcessor.split
pub fn split(a: Allocator, g: *FGraph) Allocator.Error![]*FGraph {
    var out: std.ArrayList(*FGraph) = .empty;
    if (!(g.origin.opts.separate_connected_components orelse true)) {
        const self = try a.create(FGraph);
        self.* = g.*;
        try out.append(a, self);
        return out.items;
    }
    const n = g.nodes.items.len;
    var s: Splitter = .{ .a = a, .visited = try a.alloc(bool, n), .incidence = try a.alloc(std.ArrayList(*FEdge), n) };
    @memset(s.visited, false);
    @memset(s.incidence, .empty);
    for (g.edges.items) |e| {
        try s.incidence[e.source.id].append(a, e);
        try s.incidence[e.target.id].append(a, e);
    }
    for (g.nodes.items) |node| {
        if (s.visited[node.id]) continue;
        const comp = try a.create(FGraph);
        comp.* = .{ .origin = g.origin };
        try s.dfs(node, null, comp);
        try out.append(a, comp);
    }
    if (out.items.len > 1) {
        for (out.items) |comp| for (comp.nodes.items, 0..) |node, id| {
            node.id = id;
        };
    }
    return out.items;
}

fn lessThan(_: void, g1: *FGraph, g2: *FGraph) bool {
    if (g1.priority != g2.priority) return g2.priority < g1.priority;
    const s1 = g1.bbSize();
    const s2 = g2.bbSize();
    return s1.x * s1.y < s2.x * s2.y;
}

// ComponentsProcessor.recombine
pub fn recombine(a: Allocator, comps: []*FGraph) Allocator.Error!*FGraph {
    if (comps.len == 1) return comps[0];
    for (comps) |g| {
        var priority: i32 = 0;
        var minx: f64 = 2147483647;
        var miny: f64 = 2147483647;
        var maxx: f64 = -2147483648;
        var maxy: f64 = -2147483648;
        for (g.nodes.items) |n| {
            priority += n.priority;
            minx = @min(minx, n.pos.x - n.size.x / 2);
            miny = @min(miny, n.pos.y - n.size.y / 2);
            maxx = @max(maxx, n.pos.x + n.size.x / 2);
            maxy = @max(maxy, n.pos.y + n.size.y / 2);
        }
        g.priority = priority;
        g.bb_upleft = .{ .x = minx, .y = miny };
        g.bb_lowright = .{ .x = maxx, .y = maxy };
    }
    std.mem.sort(*FGraph, comps, {}, lessThan);

    const origin = comps[0].origin;
    const result = try a.create(FGraph);
    result.* = .{ .origin = origin };
    var max_row_width: f64 = 0;
    var total_area: f64 = 0;
    for (comps) |g| {
        const size = g.bbSize();
        max_row_width = @max(max_row_width, size.x);
        total_area += size.x * size.y;
    }
    const aspect = origin.opts.aspect_ratio orelse default_aspect_ratio;
    const sqrt_f32: f32 = @floatCast(@sqrt(total_area));
    max_row_width = @max(max_row_width, @as(f64, sqrt_f32) * aspect);
    const spacing = origin.opts.spacing_node_node orelse default_spacing_node_node;

    var xpos: f64 = 0;
    var ypos: f64 = 0;
    var highest: f64 = 0;
    for (comps) |g| {
        const size = g.bbSize();
        if (xpos + size.x > max_row_width) {
            xpos = 0;
            ypos += highest + spacing;
            highest = 0;
        }
        const dx = xpos - g.bb_upleft.x;
        const dy = ypos - g.bb_upleft.y;
        for (g.nodes.items) |n| {
            n.pos.x += dx;
            n.pos.y += dy;
            try result.nodes.append(a, n);
        }
        try result.edges.appendSlice(a, g.edges.items);
        for (g.labels.items) |l| {
            l.pos.x += dx;
            l.pos.y += dy;
            try result.labels.append(a, l);
        }
        highest = @max(highest, size.y);
        xpos += size.x + spacing;
    }
    return result;
}

// ElkUtil.effectiveMinSizeConstraintFor
fn effectiveMinSize(n: *const eg.ElkNode) Vec {
    const sc = n.opts.node_size_constraints orelse lg.SizeConstraint{};
    if (!sc.minimum_size) return .{};
    const so = n.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true };
    var min = n.opts.node_size_minimum orelse Vec{};
    if (so.default_minimum_size) {
        if (min.x <= 0) min.x = 20;
        if (min.y <= 0) min.y = 20;
    }
    return min;
}

// ElkUtil.resizeNode(node, w, h, false, true); a node without ports has nothing else to move
fn resizeNode(n: *eg.ElkNode, new_width: f64, new_height: f64) void {
    const old_w = n.width;
    const old_h = n.height;
    var new_size = effectiveMinSize(n);
    new_size.x = @max(new_size.x, new_width);
    new_size.y = @max(new_size.y, new_height);
    const width_diff = new_size.x - old_w;
    const height_diff = new_size.y - old_h;
    n.width = new_size.x;
    n.height = new_size.y;
    for (n.labels.items) |l| {
        const midx = l.x + l.width / 2;
        const midy = l.y + l.height / 2;
        const wp = midx / old_w;
        const hp = midy / old_h;
        if (wp + hp >= 1) {
            if (wp - hp > 0 and midy >= 0) {
                l.x += width_diff;
                l.y += height_diff * hp;
            } else if (wp - hp < 0 and midx >= 0) {
                l.x += width_diff * wp;
                l.y += height_diff;
            }
        }
    }
    n.opts.node_size_constraints = .{};
}

// ElkGraphUtil.firstEdgeSection(edge, true, true)
fn firstSection(a: Allocator, e: *eg.ElkEdge) Allocator.Error!*eg.ElkEdgeSection {
    if (e.sections.items.len == 0) return eg.createEdgeSection(a, e);
    const s = e.sections.items[0];
    s.bend_points.clearRetainingCapacity();
    s.start = .{};
    s.end = .{};
    e.sections.shrinkRetainingCapacity(1);
    return s;
}

// ElkGraphImporter.applyLayout
pub fn applyLayout(a: Allocator, g: *const FGraph) Allocator.Error!void {
    const kgraph = g.origin;
    var minx: f64 = 2147483647;
    var miny: f64 = 2147483647;
    var maxx: f64 = -2147483648;
    var maxy: f64 = -2147483648;
    for (g.nodes.items) |n| {
        minx = @min(minx, n.pos.x - n.size.x / 2);
        miny = @min(miny, n.pos.y - n.size.y / 2);
        maxx = @max(maxx, n.pos.x + n.size.x / 2);
        maxy = @max(maxy, n.pos.y + n.size.y / 2);
    }
    const padding = kgraph.opts.padding orelse default_padding;
    const ox = padding.left - minx;
    const oy = padding.top - miny;
    for (g.nodes.items) |n| {
        n.origin.x = n.pos.x + ox - n.origin.width / 2;
        n.origin.y = n.pos.y + oy - n.origin.height / 2;
    }
    for (g.edges.items) |e| {
        const s = try firstSection(a, e.origin);
        const sp = e.sourcePoint();
        s.start = .{ .x = sp.x + ox, .y = sp.y + oy };
        const tp = e.targetPoint();
        s.end = .{ .x = tp.x + ox, .y = tp.y + oy };
    }
    for (g.labels.items) |l| {
        l.origin.x = l.pos.x + ox;
        l.origin.y = l.pos.y + oy;
    }
    const width = (maxx - minx) + padding.left + padding.right;
    const height = (maxy - miny) + padding.top + padding.bottom;
    if (!(kgraph.opts.node_size_fixed_graph_size orelse false)) resizeNode(kgraph, width, height);
}
