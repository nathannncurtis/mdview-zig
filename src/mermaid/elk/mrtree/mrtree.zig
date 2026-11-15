const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("../util.zig");
const nls = @import("../graph/node_label_size.zig");
const transferrer = @import("../graph/elk_graph_layout_transferrer.zig");
const t = @import("tree.zig");
const phases = @import("phases.zig");
const router = @import("router.zig");
const Allocator = std.mem.Allocator;
const TNode = t.TNode;
const TEdge = t.TEdge;
const TGraph = t.TGraph;

// TreeLayoutProvider. The random seed option is never read by MrTree. Not carried over: node label placement of
// NodeMicroLayout (only the node size it computes) and the interactive and compaction options.
pub fn layout(a: Allocator, node: *eg.ElkNode) lg.Error!void {
    const cfg = config(node);
    if (cfg.compaction) return error.Unsupported;
    if (cfg.routing_mode == .none) return error.Unsupported;
    microLayout(node);
    var graph = try importGraph(a, node, &cfg);
    const components = try split(a, &graph, &cfg);
    for (components) |c| try doLayout(a, c, &cfg);
    const result = try pack(a, components, &cfg);
    try applyLayout(a, node, result, &cfg);
}

fn config(n: *const eg.ElkNode) t.Config {
    const o = n.opts;
    var c: t.Config = .{};
    if (o.spacing_node_node) |v| c.spacing_node_node = v;
    if (o.spacing_edge_node) |v| c.spacing_edge_node = v;
    if (o.mrtree_edge_end_texture_length) |v| c.edge_end_texture_length = v;
    if (o.mrtree_weighting) |v| c.weighting = v;
    if (o.mrtree_search_order) |v| c.search_order = v;
    if (o.mrtree_edge_routing_mode) |v| c.routing_mode = v;
    if (o.mrtree_compaction) |v| c.compaction = v;
    if (o.aspect_ratio) |v| c.aspect_ratio = v;
    if (o.separate_connected_components) |v| c.separate_components = v;
    if (o.node_size_fixed_graph_size) |v| c.fixed_graph_size = v;
    if (o.padding) |v| c.padding = v;
    if (o.direction) |v| c.direction = v;
    return c;
}

fn microLayout(node: *eg.ElkNode) void {
    for (node.children.items) |c| {
        const sc = c.opts.node_size_constraints orelse continue;
        if (!(sc.ports or sc.port_labels or sc.node_labels or sc.minimum_size)) continue;
        const m = nls.minimumNodeSize(c);
        c.width = m.x;
        c.height = m.y;
    }
}

fn isHierarchical(e: *const eg.ElkEdge) bool {
    var common: ?*eg.ElkNode = null;
    var have = false;
    for ([_][]const eg.Shape{ e.sources.items, e.targets.items }) |list| {
        for (list) |s| {
            const parent = s.toNode().parent;
            if (!have) {
                common = parent;
                have = true;
            } else if (common != parent) {
                return true;
            }
        }
    }
    return false;
}

fn isSelfloop(e: *const eg.ElkEdge) bool {
    var common: ?*eg.ElkNode = null;
    for ([_][]const eg.Shape{ e.sources.items, e.targets.items }) |list| {
        for (list) |s| {
            const n = s.toNode();
            if (common == null) {
                common = n;
            } else if (common != n) {
                return false;
            }
        }
    }
    return true;
}

fn importGraph(a: Allocator, parent: *eg.ElkNode, cfg: *const t.Config) lg.Error!TGraph {
    var g: TGraph = .{ .direction = cfg.direction };
    var map = std.AutoHashMap(*eg.ElkNode, *TNode).init(a);
    for (parent.children.items, 0..) |c, index| {
        const label = if (c.labels.items.len > 0) c.labels.items[0].text else "";
        const n = try t.newNode(a, @intCast(index), label);
        n.origin = c;
        n.priority = c.opts.priority orelse 1;
        n.position_constraint = c.opts.mrtree_position_constraint orelse -1;
        if (c.opts.padding) |p| n.padding = p;
        n.pos.y = c.y + c.height / 2;
        n.size.x = @max(c.width, 1);
        n.pos.x = c.x + c.width / 2;
        n.size.y = @max(c.height, 1);
        try g.nodes.append(a, n);
        try map.put(c, n);
    }
    for (parent.children.items) |c| {
        var outgoing: std.ArrayList(*eg.ElkEdge) = .empty;
        try outgoing.appendSlice(a, c.outgoing_edges.items);
        for (c.ports.items) |p| try outgoing.appendSlice(a, p.outgoing_edges.items);
        for (outgoing.items) |e| {
            if (isHierarchical(e) or isSelfloop(e)) continue;
            const source = map.get(c) orelse continue;
            const target = map.get(e.targets.items[0].toNode()) orelse continue;
            const te = try t.newEdge(a, source, target);
            te.origin = e;
            try source.outgoing.append(a, te);
            try target.incoming.append(a, te);
            try g.edges.append(a, te);
        }
    }
    return g;
}

// ComponentsProcessor.split
fn split(a: Allocator, graph: *TGraph, cfg: *const t.Config) lg.Error![]*TGraph {
    var out: std.ArrayList(*TGraph) = .empty;
    if (!cfg.separate_components) {
        const g = try a.create(TGraph);
        g.* = graph.*;
        try out.append(a, g);
        return out.items;
    }
    const n = graph.nodes.items.len;
    const incidence = try a.alloc(std.ArrayList(*TEdge), n);
    for (incidence) |*l| l.* = .empty;
    const visited = try a.alloc(bool, n);
    @memset(visited, false);
    for (graph.edges.items) |e| {
        try incidence[@intCast(e.source.id)].append(a, e);
        try incidence[@intCast(e.target.id)].append(a, e);
    }
    for (graph.nodes.items) |node| {
        if (try splitDfs(a, incidence, visited, node, null, cfg)) |comp| try out.append(a, comp);
    }
    if (out.items.len > 1) {
        for (out.items) |comp| for (comp.nodes.items, 0..) |node, i| {
            node.id = @intCast(i);
        };
    }
    return out.items;
}

fn splitDfs(a: Allocator, incidence: []std.ArrayList(*TEdge), visited: []bool, node: *TNode, graph: ?*TGraph, cfg: *const t.Config) lg.Error!?*TGraph {
    const id: usize = @intCast(node.id);
    if (visited[id]) return null;
    visited[id] = true;
    const comp = graph orelse blk: {
        const c = try a.create(TGraph);
        c.* = .{ .direction = cfg.direction };
        break :blk c;
    };
    try comp.nodes.append(a, node);
    for (incidence[id].items) |e| {
        if (e.source != node) _ = try splitDfs(a, incidence, visited, e.source, comp, cfg);
        if (e.target != node) _ = try splitDfs(a, incidence, visited, e.target, comp, cfg);
        try comp.edges.append(a, e);
    }
    return comp;
}

// MrTree.doLayout: the phases with their intermediate processors in AlgorithmAssembler order
fn doLayout(a: Allocator, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    try phases.treeify(a, g, cfg);
    try phases.rootProcessor(a, g);
    try phases.fanProcessor(a, g);
    try phases.levelProcessor(a, g);
    try phases.orderNodes(a, g, cfg);
    try phases.neighborsProcessor(a, g);
    try phases.levelHeightProcessor(a, g);
    try phases.placeNodes(a, g, cfg);
    phases.directionProcessor(g);
    try phases.nodePositionProcessor(a, g);
    try phases.levelCoordinatesProcessor(a, g);
    try phases.graphBoundsProcessor(g);
    try phases.untreeify(a, g);
    try router.route(a, g, cfg);
}

fn distinctEdges(a: Allocator, g: *const TGraph) Allocator.Error![]*TEdge {
    var seen = std.AutoHashMap(*TEdge, void).init(a);
    var out: std.ArrayList(*TEdge) = .empty;
    for (g.edges.items) |e| {
        if ((try seen.getOrPut(e)).found_existing) continue;
        try out.append(a, e);
    }
    return out.items;
}

// ComponentsProcessor.moveGraph
fn moveGraph(a: Allocator, dest: *TGraph, src: *const TGraph, offsetx: f64, offsety: f64) Allocator.Error!void {
    const ox = offsetx - src.bb_upleft.x;
    const oy = offsety - src.bb_upleft.y;
    for (src.nodes.items) |n| {
        n.pos.x += ox;
        n.pos.y += oy;
        try dest.nodes.append(a, n);
    }
    for (try distinctEdges(a, src)) |e| {
        for (e.bends.items) |p| {
            p.x += ox;
            p.y += oy;
        }
        try dest.edges.append(a, e);
    }
}

fn applyPaddingAndNormalizePositions(a: Allocator, g: *TGraph) Allocator.Error!void {
    const padding = g.nodes.items[0].padding;
    g.bb_upleft = .{ .x = 0, .y = 0 };
    var scratch: TGraph = .{};
    try moveGraph(a, &scratch, g, padding.left + padding.right - g.xmin, padding.top + padding.bottom - g.ymin);
}

fn lessComponent(_: void, g1: *TGraph, g2: *TGraph) bool {
    if (g1.priority != g2.priority) return g1.priority > g2.priority;
    const s1 = g1.bb_lowright.x - g1.bb_upleft.x;
    const s1y = g1.bb_lowright.y - g1.bb_upleft.y;
    const s2 = g2.bb_lowright.x - g2.bb_upleft.x;
    const s2y = g2.bb_lowright.y - g2.bb_upleft.y;
    return util.doubleCompare(s1 * s1y, s2 * s2y) == .lt;
}

// ComponentsProcessor.pack
fn pack(a: Allocator, components: []*TGraph, cfg: *const t.Config) lg.Error!*TGraph {
    if (components.len == 0) return error.ElkException;
    if (components.len == 1) {
        try applyPaddingAndNormalizePositions(a, components[0]);
        return components[0];
    }
    for (components) |g| {
        var priority: i32 = 0;
        var minx: f64 = 2147483647;
        var miny: f64 = 2147483647;
        var maxx: f64 = -2147483648;
        var maxy: f64 = -2147483648;
        for (g.nodes.items) |n| {
            priority += n.priority;
            minx = @min(minx, n.pos.x);
            miny = @min(miny, n.pos.y);
            maxx = @max(maxx, n.pos.x + n.size.x);
            maxy = @max(maxy, n.pos.y + n.size.y);
        }
        g.priority = priority;
        g.bb_upleft = .{ .x = minx, .y = miny };
        g.bb_lowright = .{ .x = maxx, .y = maxy };
    }
    std.mem.sort(*TGraph, components, {}, lessComponent);
    const result = try a.create(TGraph);
    result.* = components[0].*;
    result.nodes = .empty;
    result.edges = .empty;
    var max_row_width: f64 = 0;
    var total_area: f64 = 0;
    for (components) |g| {
        const sx = g.bb_lowright.x - g.bb_upleft.x;
        const sy = g.bb_lowright.y - g.bb_upleft.y;
        max_row_width = @max(max_row_width, sx);
        total_area += sx * sy;
    }
    max_row_width = @max(max_row_width, @sqrt(total_area) * cfg.aspect_ratio);
    const spacing = cfg.spacing_node_node;
    var xpos: f64 = 0;
    var ypos: f64 = 0;
    var highest_box: f64 = 0;
    for (components) |g| {
        const sx = g.bb_lowright.x - g.bb_upleft.x;
        const sy = g.bb_lowright.y - g.bb_upleft.y;
        if (xpos + sx > max_row_width) {
            xpos = 0;
            ypos += highest_box + spacing;
            highest_box = 0;
        }
        try moveGraph(a, result, g, xpos, ypos);
        highest_box = @max(highest_box, sy);
        xpos += sx + spacing;
    }
    // property merge: a later component overrides unless its value equals the default
    for (components[1..]) |g| {
        if (g.xmin != 0) result.xmin = g.xmin;
        if (g.ymin != 0) result.ymin = g.ymin;
        if (g.xmax != 0) result.xmax = g.xmax;
        if (g.ymax != 0) result.ymax = g.ymax;
        if (g.direction != .undefined) result.direction = g.direction;
    }
    try applyPaddingAndNormalizePositions(a, result);
    return result;
}

// ElkGraphImporter.applyLayout
fn applyLayout(a: Allocator, elkgraph: *eg.ElkNode, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    var min_x: f64 = 2147483647;
    var min_y: f64 = 2147483647;
    var max_x: f64 = -2147483648;
    var max_y: f64 = -2147483648;
    for (g.nodes.items) |n| {
        min_x = @min(min_x, n.pos.x - n.size.x / 2);
        min_y = @min(min_y, n.pos.y - n.size.y / 2);
        max_x = @max(max_x, n.pos.x + n.size.x / 2);
        max_y = @max(max_y, n.pos.y + n.size.y / 2);
    }
    const padding = cfg.padding;
    for (g.nodes.items) |n| {
        if (n.origin) |o| {
            o.x = n.pos.x;
            o.y = n.pos.y;
        }
    }
    for (g.edges.items) |te| {
        const e = te.origin orelse continue;
        if (te.bends.items.len < 2) return error.ElkException;
        const section: *eg.ElkEdgeSection = if (e.sections.items.len == 0) try eg.createEdgeSection(a, e) else blk: {
            const s = e.sections.items[0];
            e.sections.shrinkRetainingCapacity(1);
            break :blk s;
        };
        const pts = te.bends.items;
        section.bend_points.clearRetainingCapacity();
        section.start = pts[0].*;
        for (pts[1 .. pts.len - 1]) |p| try section.bend_points.append(a, p.*);
        section.end = pts[pts.len - 1].*;
    }
    const width = max_x - min_x + padding.left + padding.right;
    const height = max_y - min_y + padding.top + padding.bottom;
    if (!cfg.fixed_graph_size) transferrer.resizeElkNode(elkgraph, width, height, false, false);
}

test {
    _ = @import("tree.zig");
}
