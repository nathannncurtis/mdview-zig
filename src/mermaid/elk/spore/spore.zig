const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("../util.zig");
const layered = @import("../layered.zig");
const transferrer = @import("../graph/elk_graph_layout_transferrer.zig");
const stress = @import("../stress/stress.zig");
const force = @import("../force/force.zig");
const mrtree = @import("../mrtree/mrtree.zig");
const box = @import("../box/box.zig");
const rectpacking = @import("../rectpacking/rectpacking.zig");
const radial = @import("../radial/radial.zig");
const model = @import("model.zig");
const triangulation = @import("triangulation.zig");
const Allocator = std.mem.Allocator;
const Vec = lg.Vec;
const Rect = model.Rect;
const Node = model.Node;
const Edge = model.Edge;
const EdgeSet = model.EdgeSet;

const default_padding = 8.0;
const default_spacing_node_node = 8.0;
const default_spacing_label_node = 5.0;
const default_max_iterations = 64;

const Tree = struct {
    node: u32,
    children: std.ArrayList(*Tree) = .empty,
};

// OverlapRemovalLayoutProvider.layout (SPOrE: structure extraction by Delaunay triangulation, minimum spanning tree
// with the inverted overlap cost, root selection CENTER_NODE, GrowTreePhase)
pub fn layout(a: Allocator, node: *eg.ElkNode) lg.Error!void {
    if (node.opts.underlying_layout_algorithm) |name| try runUnderlying(a, node, name);
    if (node.children.items.len == 0) return;
    const max_iterations = node.opts.overlap_removal_max_iterations orelse default_max_iterations;
    const run_scanline = node.opts.overlap_removal_run_scanline orelse true;

    var g = try Graph.import(a, node);
    var overlaps_existed = true;
    var iteration: i32 = 0;
    while (iteration < max_iterations and overlaps_existed) {
        var t_edges: EdgeSet = .{};
        if (run_scanline) {
            try g.sweep(a, &t_edges);
            if (t_edges.list.items.len == 0) break;
        }
        const points = try a.alloc(Vec, g.nodes.len);
        for (g.nodes, points) |n, *p| p.* = n.orig;
        var delaunay: EdgeSet = .{};
        try triangulation.triangulate(a, points, &delaunay);
        for (delaunay.list.items) |e| try t_edges.add(a, e);
        const tree = try g.spanningTree(a, t_edges.list.items);
        overlaps_existed = false;
        g.grow(tree, &overlaps_existed);
        for (g.nodes) |*n| n.orig = n.rect.center();
        iteration += 1;
    }
    try g.applyPositions(a);
}

fn runUnderlying(a: Allocator, node: *eg.ElkNode, name: []const u8) lg.Error!void {
    const short = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name[d + 1 ..] else name;
    const Known = enum { layered, stress, force, mrtree, box, rectpacking, radial, fixed, random, disco, sporeOverlap, sporeCompaction };
    // an unknown name is ignored (LayoutMetaDataService returns no algorithm)
    const k = std.meta.stringToEnum(Known, short) orelse return;
    return switch (k) {
        .layered => layered.layoutNode(a, node),
        .stress => stress.layout(a, node),
        .force => force.layout(a, node),
        .mrtree => mrtree.layout(a, node),
        .box => box.layout(a, node),
        .rectpacking => rectpacking.layout(a, node),
        .radial => radial.layout(a, node),
        .fixed, .random, .disco, .sporeOverlap, .sporeCompaction => error.Unsupported,
    };
}

const Graph = struct {
    nodes: []Node,
    elk: []*eg.ElkNode,
    parent: *eg.ElkNode,
    root: u32 = 0,

    // ElkGraphImporter.importGraph
    fn import(a: Allocator, parent: *eg.ElkNode) lg.Error!Graph {
        const spacing_label_node = parent.opts.spacing_label_node orelse default_spacing_label_node;
        const spacing = parent.opts.spacing_node_node orelse default_spacing_node_node;
        const count = parent.children.items.len;
        const nodes = try a.alloc(Node, count);
        const elk = try a.dupe(*eg.ElkNode, parent.children.items);
        var rng: u64 = 0x9e3779b97f4a7c15;
        for (elk, nodes, 0..) |child, *out, i| {
            const half_w = child.width / 2;
            const half_h = child.height / 2;
            var vertex: Vec = .{ .x = child.x + half_w, .y = child.y + half_h };
            // Math.random in the Java; a fixed sequence keeps the layout reproducible
            var attempts: usize = 0;
            while (attempts < 64 and containsVertex(nodes[0..i], vertex)) : (attempts += 1) {
                vertex.x += (nextUnit(&rng) - 0.5) * 0.001;
                vertex.y += (nextUnit(&rng) - 0.5) * 0.001;
            }
            const m = margin(child, spacing_label_node);
            out.* = .{
                .orig = vertex,
                .vertex = vertex,
                .rect = .{
                    .x = vertex.x - half_w - spacing / 2 - m.left,
                    .y = vertex.y - half_h - spacing / 2 - m.top,
                    .w = child.width + spacing + (m.left + m.right),
                    .h = child.height + spacing + (m.top + m.bottom),
                },
            };
        }
        var g: Graph = .{ .nodes = nodes, .elk = elk, .parent = parent };
        var center: Vec = .{ .x = parent.width, .y = parent.height };
        center.scale(0.5);
        center.add(.{ .x = parent.x, .y = parent.y });
        var closest = std.math.inf(f64);
        for (nodes, 0..) |n, i| {
            const d = model.distance(n.orig, center);
            if (d < closest) {
                closest = d;
                g.root = @intCast(i);
            }
        }
        return g;
    }

    fn containsVertex(nodes: []const Node, v: Vec) bool {
        for (nodes) |n| if (n.orig.x == v.x and n.orig.y == v.y) return true;
        return false;
    }

    fn nextUnit(state: *u64) f64 {
        state.* ^= state.* << 13;
        state.* ^= state.* >> 7;
        state.* ^= state.* << 17;
        return @as(f64, @floatFromInt(state.* >> 11)) / 9007199254740992.0;
    }

    const SweepEvent = struct { node: u32, low: bool };

    fn eventY(g: *const Graph, e: SweepEvent) f64 {
        const r = g.nodes[e.node].rect;
        return if (e.low) r.y else r.y + r.h;
    }

    fn cmpEvent(g: *const Graph, p1: SweepEvent, p2: SweepEvent) lg.Error!i32 {
        const cmp: i32 = dcmp(g.eventY(p1), g.eventY(p2));
        if (cmp == 0) {
            if (!p1.low and p2.low) return -1;
            if (!p2.low and p1.low) return 1;
        }
        return cmp;
    }

    fn cmpLeft(g: *const Graph, n1: u32, n2: u32) i32 {
        const a = g.nodes[n1];
        const b = g.nodes[n2];
        var c: i32 = dcmp(a.rect.x, b.rect.x);
        if (c != 0) return c;
        c = dcmp(a.orig.x, b.orig.x);
        if (c != 0) return c;
        return dcmp(a.orig.y, b.orig.y);
    }

    fn overlapsX(g: *const Graph, n1: u32, n2: u32) bool {
        if (n1 == n2) return false;
        const r1 = g.nodes[n1].rect;
        const r2 = g.nodes[n2].rect;
        return model.fuzzyCompare(r1.x, r2.x + r2.w, model.fuzziness) < 0 and
            model.fuzzyCompare(r2.x, r1.x + r1.w, model.fuzziness) < 0;
    }

    // ScanlineOverlapCheck.sweep: every pair of nodes overlapping at the same time becomes an edge
    fn sweep(g: *const Graph, a: Allocator, out: *EdgeSet) lg.Error!void {
        const events = try a.alloc(SweepEvent, g.nodes.len * 2);
        for (0..g.nodes.len) |i| {
            events[2 * i] = .{ .node = @intCast(i), .low = true };
            events[2 * i + 1] = .{ .node = @intCast(i), .low = false };
        }
        try util.javaSort(SweepEvent, a, events, g, cmpEvent);
        var active: std.ArrayList(u32) = .empty;
        for (events) |ev| {
            var lo: usize = 0;
            var hi: usize = active.items.len;
            var found = false;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const c = g.cmpLeft(ev.node, active.items[mid]);
                if (c == 0) {
                    lo = mid;
                    found = true;
                    break;
                }
                if (c < 0) hi = mid else lo = mid + 1;
            }
            if (!ev.low) {
                if (found) _ = active.orderedRemove(lo);
                continue;
            }
            if (found) {
                lg.setElkMessage("Invalid hitboxes for scanline overlap calculation.");
                return error.ElkException;
            }
            try active.insert(a, lo, ev.node);
            var overlaps_found = false;
            for (active.items) |other| {
                if (g.overlapsX(ev.node, other)) {
                    try out.add(a, .{ .u = ev.node, .v = other });
                    overlaps_found = true;
                } else if (overlaps_found) break;
            }
        }
    }

    // ElkGraphImporter invertedOverlap cost function
    fn cost(g: *const Graph, e: Edge) f64 {
        const r1 = g.nodes[e.u].rect;
        const r2 = g.nodes[e.v].rect;
        const dist = model.shortestDistance(r1, r2);
        if (dist >= 0) return dist;
        var c2 = r2.center();
        c2.sub(r1.center());
        const s = @sqrt(c2.x * c2.x + c2.y * c2.y);
        return -(model.overlap(r1, r2) - 1) * s;
    }

    const Weighted = struct { e: Edge, w: f64 };

    fn cmpWeight(_: void, x: Weighted, y: Weighted) lg.Error!i32 {
        return dcmp(x.w, y.w);
    }

    // NaiveMinST.createSpanningTree
    fn spanningTree(g: *const Graph, a: Allocator, edges: []const Edge) lg.Error!*Tree {
        const sorted = try a.alloc(Weighted, edges.len);
        for (edges, sorted) |e, *w| w.* = .{ .e = e, .w = g.cost(e) };
        try util.javaSort(Weighted, a, sorted, {}, cmpWeight);
        const root = try a.create(Tree);
        root.* = .{ .node = g.root };
        const in_tree = try a.alloc(?*Tree, g.nodes.len);
        @memset(in_tree, null);
        in_tree[g.root] = root;
        var remaining: std.ArrayList(Weighted) = .empty;
        try remaining.appendSlice(a, sorted);
        while (remaining.items.len > 0) {
            var pick: ?usize = null;
            var next_node: u32 = 0;
            var node_in_tree: u32 = 0;
            for (remaining.items, 0..) |w, i| {
                if (!(w.w <= std.math.inf(f64))) continue;
                if (in_tree[w.e.u] != null and in_tree[w.e.v] == null) {
                    next_node = w.e.v;
                    node_in_tree = w.e.u;
                    pick = i;
                    break;
                }
                if (in_tree[w.e.v] != null and in_tree[w.e.u] == null) {
                    next_node = w.e.u;
                    node_in_tree = w.e.v;
                    pick = i;
                    break;
                }
            }
            const idx = pick orelse break;
            const sub = try a.create(Tree);
            sub.* = .{ .node = next_node };
            try in_tree[node_in_tree].?.children.append(a, sub);
            in_tree[next_node] = sub;
            _ = remaining.orderedRemove(idx);
        }
        return root;
    }

    // GrowTreePhase.growAt
    fn grow(g: *Graph, r: *const Tree, existed: *bool) void {
        for (r.children.items) |c| {
            const rn = &g.nodes[r.node];
            const cn = &g.nodes[c.node];
            var shift = rn.vertex;
            shift.sub(rn.orig);
            cn.translate(shift);
            const t = model.overlap(rn.rect, cn.rect);
            if (t > 1.0) existed.* = true;
            var d = cn.orig;
            d.sub(rn.orig);
            d.scale(t);
            var target = rn.vertex;
            target.add(d);
            cn.setCenterPosition(target);
            g.grow(c, existed);
        }
    }

    // ElkGraphImporter.applyPositions
    fn applyPositions(g: *const Graph, a: Allocator) lg.Error!void {
        const parent = g.parent;
        var min_x = std.math.inf(f64);
        var min_y = std.math.inf(f64);
        var max_x = -std.math.inf(f64);
        var max_y = -std.math.inf(f64);
        for (g.nodes, g.elk) |n, child| {
            child.x = n.rect.x;
            child.y = n.rect.y;
            min_x = util.javaMin(min_x, child.x);
            min_y = util.javaMin(min_y, child.y);
            max_x = util.javaMax(max_x, child.x + child.width);
            max_y = util.javaMax(max_y, child.y + child.height);
        }
        const padding = parent.opts.padding orelse lg.Margin{ .top = default_padding, .left = default_padding, .bottom = default_padding, .right = default_padding };
        transferrer.resizeElkNode(parent, max_x - min_x + (padding.left + padding.right), max_y - min_y + (padding.top + padding.bottom), true, true);
        translate(parent, -min_x + padding.left, -min_y + padding.top);

        for (parent.contained_edges.items) |e| {
            if (e.sources.items.len == 0 or e.targets.items.len == 0) continue;
            const section = if (e.sections.items.len == 0) try eg.createEdgeSection(a, e) else e.sections.items[0];
            section.bend_points = .empty;
            section.start = .{};
            section.end = .{};
            e.sections.shrinkRetainingCapacity(1);
            const source = e.sourceNode();
            const target = e.targetNode();
            var start: Vec = .{ .x = source.x + source.width / 2, .y = source.y + source.height / 2 };
            var end: Vec = .{ .x = target.x + target.width / 2, .y = target.y + target.height / 2 };
            var uv = end;
            uv.sub(start);
            clipVector(&uv, source.width, source.height);
            start.add(uv);
            var vu = start;
            vu.sub(end);
            clipVector(&vu, target.width, target.height);
            end.add(vu);
            section.start = start;
            section.end = end;
        }
    }
};

// ElkMath.clipVector
fn clipVector(v: *Vec, width: f64, height: f64) void {
    const wh = width / 2;
    const hh = height / 2;
    const absx = @abs(v.x);
    const absy = @abs(v.y);
    var xscale: f64 = 1;
    var yscale: f64 = 1;
    if (absx > wh) xscale = wh / absx;
    if (absy > hh) yscale = hh / absy;
    v.scale(util.javaMin(xscale, yscale));
}

// ElkUtil.translate(ElkNode, dx, dy): children and every contained edge
fn translate(parent: *eg.ElkNode, dx: f64, dy: f64) void {
    for (parent.children.items) |c| {
        c.x += dx;
        c.y += dy;
    }
    for (parent.contained_edges.items) |e| {
        for (e.sections.items) |s| {
            s.start.x += dx;
            s.start.y += dy;
            for (s.bend_points.items) |*b| {
                b.x += dx;
                b.y += dy;
            }
            s.end.x += dx;
            s.end.y += dy;
        }
        for (e.labels.items) |l| {
            l.x += dx;
            l.y += dy;
        }
        for (e.junction_points.items) |*j| {
            j.x += dx;
            j.y += dy;
        }
    }
}

fn unionRect(r: *Rect, o: Rect) void {
    var x1 = util.javaMin(r.x, o.x);
    var y1 = util.javaMin(r.y, o.y);
    var x2 = util.javaMax(r.x + r.w, o.x + o.w);
    var y2 = util.javaMax(r.y + r.h, o.y + o.h);
    if (x2 < x1) std.mem.swap(f64, &x1, &x2);
    if (y2 < y1) std.mem.swap(f64, &y1, &y2);
    r.* = .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

// NodeMarginCalculator.processNode: how far labels, ports and head/tail edge labels reach beyond the node
fn margin(n: *const eg.ElkNode, label_spacing: f64) lg.Margin {
    var bb: Rect = .{ .x = n.x, .y = n.y, .w = n.width, .h = n.height };
    for (n.labels.items) |l| unionRect(&bb, .{ .x = l.x + n.x, .y = l.y + n.y, .w = l.width, .h = l.height });
    for (n.ports.items) |p| {
        const px = p.x + n.x;
        const py = p.y + n.y;
        unionRect(&bb, .{ .x = px, .y = py, .w = p.width, .h = p.height });
        for (p.labels.items) |l| unionRect(&bb, .{ .x = l.x + px, .y = l.y + py, .w = l.width, .h = l.height });
        headTailLabels(&bb, p.outgoing_edges.items, p.incoming_edges.items, n, p, label_spacing);
    }
    headTailLabels(&bb, n.outgoing_edges.items, n.incoming_edges.items, n, null, label_spacing);
    return .{
        .top = util.javaMax(0, n.y - bb.y),
        .bottom = util.javaMax(0, bb.y + bb.h - (n.y + n.height)),
        .left = util.javaMax(0, n.x - bb.x),
        .right = util.javaMax(0, bb.x + bb.w - (n.x + n.width)),
    };
}

fn headTailLabels(bb: *Rect, outgoing: []const *eg.ElkEdge, incoming: []const *eg.ElkEdge, n: *const eg.ElkNode, port: ?*const eg.ElkPort, ls: f64) void {
    for (outgoing) |e| for (e.labels.items) |l| {
        if ((l.opts.edge_labels_placement orelse .center) == .tail) unionRect(bb, labelBox(l, false, n, port, ls));
    };
    for (incoming) |e| for (e.labels.items) |l| {
        if ((l.opts.edge_labels_placement orelse .center) == .head) unionRect(bb, labelBox(l, true, n, port, ls));
    };
}

// the port label space is zero: the default port label placement is not OUTSIDE
fn labelBox(l: *const eg.ElkLabel, incoming: bool, n: *const eg.ElkNode, port: ?*const eg.ElkPort, ls: f64) Rect {
    var r: Rect = .{ .x = n.x, .y = n.y, .w = l.width, .h = l.height };
    if (port) |p| {
        r.x += p.x;
        r.y += p.y;
        switch (p.opts.port_side orelse .undefined) {
            .undefined, .east => r.x += p.width + ls + 0 + ls,
            .west => r.x -= ls + 0 + ls + l.width,
            .north => {
                r.x += p.width + ls;
                r.y -= ls + 0 + ls + l.height;
            },
            .south => {
                r.x += p.width + ls;
                r.y += p.height + ls + 0 + ls;
            },
        }
    } else if (incoming) {
        r.x -= ls + l.width;
    } else {
        r.x += n.width + ls;
    }
    return r;
}

fn dcmp(x: f64, y: f64) i32 {
    return switch (util.doubleCompare(x, y)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}
