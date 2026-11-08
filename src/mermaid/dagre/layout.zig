const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const acyclic = @import("acyclic.zig");
const nesting_graph = @import("nesting_graph.zig");
const rank_mod = @import("rank.zig");
const normalize = @import("normalize.zig");
const compound = @import("compound.zig");
const order_mod = @import("order.zig");
const position_mod = @import("position.zig");
const Allocator = std.mem.Allocator;
pub const Graph = types.Graph;
pub const Edge = types.Edge;
pub const NodeLabel = types.NodeLabel;
pub const EdgeLabel = types.EdgeLabel;
pub const Point = types.Point;

fn buildLayoutGraph(a: Allocator, input: *Graph) types.Error!Graph {
    const gl = try a.create(types.GraphLabel);
    const src = input.label.*;
    gl.* = .{
        .ranksep = src.ranksep,
        .edgesep = src.edgesep,
        .nodesep = src.nodesep,
        .marginx = src.marginx,
        .marginy = src.marginy,
        .rankdir = src.rankdir,
        .acyclicer = src.acyclicer,
        .ranker = src.ranker,
        .@"align" = src.@"align",
    };
    var g = Graph.init(a, .{ .multigraph = true, .compound = true }, gl);
    // a parent mentioned before its own turn is created with a placeholder, as graphlib creates it with no label
    g.default_node = try a.create(NodeLabel);
    g.default_node.?.* = .{};
    for (input.nodes()) |v| {
        const in = input.node(v).?;
        const n = try a.create(NodeLabel);
        n.* = .{ .width = in.width, .height = in.height, .user = in.user };
        try g.setNode(v, n);
        try g.setParent(v, input.parent(v));
    }
    for (input.edges()) |e| {
        const in = input.edgeLabel(e).?;
        const l = try a.create(EdgeLabel);
        l.* = .{
            .minlen = in.minlen,
            .weight = in.weight,
            .width = in.width,
            .height = in.height,
            .labeloffset = in.labeloffset,
            .labelpos = in.labelpos,
            .user = in.user,
        };
        try g.setEdge(e, l);
    }
    return g;
}

fn makeSpaceForEdgeLabels(g: *Graph) void {
    const gl = g.label;
    gl.ranksep /= 2;
    const vertical = std.mem.eql(u8, gl.rankdir, "TB") or std.mem.eql(u8, gl.rankdir, "BT");
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        edge.minlen *= 2;
        if (std.ascii.toLower(edge.labelpos) != 'c') {
            if (vertical) edge.width += edge.labeloffset else edge.height += edge.labeloffset;
        }
    }
}

fn removeSelfEdges(a: Allocator, g: *Graph) Allocator.Error!void {
    for (try a.dupe(Edge, g.edges())) |e| {
        if (std.mem.eql(u8, e.v, e.w)) {
            const node = g.node(e.v).?;
            try node.self_edges.append(a, .{ .e = e, .label = g.edgeLabel(e).? });
            g.removeEdge(e);
        }
    }
}

fn injectEdgeLabelProxies(a: Allocator, g: *Graph) Allocator.Error!void {
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        if (edge.width != 0 and edge.height != 0) {
            const v = g.node(e.v).?;
            const w = g.node(e.w).?;
            const label = try a.create(NodeLabel);
            label.* = .{ .rank = (w.rank.? - v.rank.?) / 2 + v.rank.?, .e = e };
            _ = try util.addDummyNode(a, g, .edge_proxy, label, "_ep");
        }
    }
}

fn assignRankMinMax(g: *Graph) void {
    for (g.nodes()) |v| {
        const node = g.node(v).?;
        if (node.border_top) |bt| {
            node.min_rank = g.node(bt).?.rank;
            node.max_rank = g.node(node.border_bottom.?).?.rank;
        }
    }
}

fn removeEdgeLabelProxies(a: Allocator, g: *Graph) Allocator.Error!void {
    for (try a.dupe([]const u8, g.nodes())) |v| {
        const node = g.node(v).?;
        if (node.dummy == .edge_proxy) {
            g.edgeLabel(node.e.?).?.label_rank = node.rank;
            try g.removeNode(v);
        }
    }
}

fn insertSelfEdges(a: Allocator, g: *Graph) Allocator.Error!void {
    const layers = try util.buildLayerMatrix(a, g);
    for (layers) |layer| {
        var order_shift: i64 = 0;
        for (layer, 0..) |v, i| {
            const node = g.node(v).?;
            node.order = @as(i64, @intCast(i)) + order_shift;
            for (node.self_edges.items) |se| {
                order_shift += 1;
                const l = try a.create(NodeLabel);
                l.* = .{
                    .width = se.label.width,
                    .height = se.label.height,
                    .rank = node.rank,
                    .order = @as(i64, @intCast(i)) + order_shift,
                    .e = se.e,
                    .label = se.label,
                };
                _ = try util.addDummyNode(a, g, .selfedge, l, "_se");
            }
            node.self_edges.clearRetainingCapacity();
        }
    }
}

fn positionSelfEdges(a: Allocator, g: *Graph) Allocator.Error!void {
    for (try a.dupe([]const u8, g.nodes())) |v| {
        const node = g.node(v).?;
        if (node.dummy == .selfedge) {
            const self_node = g.node(node.e.?.v).?;
            const x = self_node.x + self_node.width / 2;
            const y = self_node.y;
            const dx = node.x - x;
            const dy = self_node.height / 2;
            const label = node.label.?;
            try g.setEdge(node.e.?, label);
            try g.removeNode(v);
            label.points.clearRetainingCapacity();
            label.has_points = true;
            try label.points.appendSlice(a, &.{
                .{ .x = x + (2 * dx) / 3, .y = y - dy },
                .{ .x = x + (5 * dx) / 6, .y = y - dy },
                .{ .x = x + dx, .y = y },
                .{ .x = x + (5 * dx) / 6, .y = y + dy },
                .{ .x = x + (2 * dx) / 3, .y = y + dy },
            });
            label.x = node.x;
            label.y = node.y;
        }
    }
}

fn removeBorderNodes(a: Allocator, g: *Graph) Allocator.Error!void {
    for (g.nodes()) |v| {
        if (g.children(v).?.len > 0) {
            const node = g.node(v).?;
            const t = g.node(node.border_top.?).?;
            const b = g.node(node.border_bottom.?).?;
            const l = g.node(node.border_left.last().?).?;
            const r = g.node(node.border_right.last().?).?;
            node.width = @abs(r.x - l.x);
            node.height = @abs(b.y - t.y);
            node.x = l.x + node.width / 2;
            node.y = t.y + node.height / 2;
        }
    }
    for (try a.dupe([]const u8, g.nodes())) |v| {
        if (g.node(v).?.dummy == .border) try g.removeNode(v);
    }
}

fn fixupEdgeLabelCoords(g: *Graph) void {
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        if (edge.x != null) {
            if (edge.labelpos == 'l' or edge.labelpos == 'r') edge.width -= edge.labeloffset;
            switch (edge.labelpos) {
                'l' => edge.x = edge.x.? - (edge.width / 2 + edge.labeloffset),
                'r' => edge.x = edge.x.? + (edge.width / 2 + edge.labeloffset),
                else => {},
            }
        }
    }
}

fn swapWidthHeight(g: *Graph) void {
    for (g.nodes()) |v| {
        const n = g.node(v).?;
        std.mem.swap(f64, &n.width, &n.height);
    }
    for (g.edges()) |e| {
        const n = g.edgeLabel(e).?;
        std.mem.swap(f64, &n.width, &n.height);
    }
}

fn reverseY(g: *Graph) void {
    for (g.nodes()) |v| {
        const n = g.node(v).?;
        n.y = -n.y;
    }
    for (g.edges()) |e| {
        const n = g.edgeLabel(e).?;
        for (n.points.items) |*p| p.y = -p.y;
        if (n.y) |y| n.y = -y;
    }
}

fn swapXY(g: *Graph) void {
    for (g.nodes()) |v| {
        const n = g.node(v).?;
        std.mem.swap(f64, &n.x, &n.y);
    }
    for (g.edges()) |e| {
        const n = g.edgeLabel(e).?;
        for (n.points.items) |*p| std.mem.swap(f64, &p.x, &p.y);
        if (n.x) |x| {
            const y = n.y.?;
            n.x = y;
            n.y = x;
        }
    }
}

fn adjustCoordinateSystem(g: *Graph) void {
    const d = g.label.rankdir;
    if (std.ascii.eqlIgnoreCase(d, "lr") or std.ascii.eqlIgnoreCase(d, "rl")) swapWidthHeight(g);
}

fn undoCoordinateSystem(g: *Graph) void {
    const d = g.label.rankdir;
    if (std.ascii.eqlIgnoreCase(d, "bt") or std.ascii.eqlIgnoreCase(d, "rl")) reverseY(g);
    if (std.ascii.eqlIgnoreCase(d, "lr") or std.ascii.eqlIgnoreCase(d, "rl")) {
        swapXY(g);
        swapWidthHeight(g);
    }
}

fn translateGraph(g: *Graph) void {
    var min_x = std.math.inf(f64);
    var max_x: f64 = 0;
    var min_y = std.math.inf(f64);
    var max_y: f64 = 0;
    const gl = g.label;
    const margin_x = gl.marginx;
    const margin_y = gl.marginy;
    for (g.nodes()) |v| {
        const n = g.node(v).?;
        min_x = jsMin(min_x, n.x - n.width / 2);
        max_x = jsMax(max_x, n.x + n.width / 2);
        min_y = jsMin(min_y, n.y - n.height / 2);
        max_y = jsMax(max_y, n.y + n.height / 2);
    }
    for (g.edges()) |e| {
        const n = g.edgeLabel(e).?;
        if (n.x) |x| {
            const y = n.y.?;
            min_x = jsMin(min_x, x - n.width / 2);
            max_x = jsMax(max_x, x + n.width / 2);
            min_y = jsMin(min_y, y - n.height / 2);
            max_y = jsMax(max_y, y + n.height / 2);
        }
    }
    min_x -= margin_x;
    min_y -= margin_y;
    for (g.nodes()) |v| {
        const n = g.node(v).?;
        n.x -= min_x;
        n.y -= min_y;
    }
    for (g.edges()) |e| {
        const n = g.edgeLabel(e).?;
        for (n.points.items) |*p| {
            p.x -= min_x;
            p.y -= min_y;
        }
        if (n.x) |x| n.x = x - min_x;
        if (n.y) |y| n.y = y - min_y;
    }
    gl.width = max_x - min_x + margin_x;
    gl.height = max_y - min_y + margin_y;
}

fn jsMin(a: f64, b: f64) f64 {
    return if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else @min(a, b);
}

fn jsMax(a: f64, b: f64) f64 {
    return if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else @max(a, b);
}

fn assignNodeIntersects(a: Allocator, g: *Graph) types.Error!void {
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        const node_v = g.node(e.v).?;
        const node_w = g.node(e.w).?;
        const p1: Point = if (edge.has_points) edge.points.items[0] else .{ .x = node_w.x, .y = node_w.y };
        const p2: Point = if (edge.has_points) edge.points.items[edge.points.items.len - 1] else .{ .x = node_v.x, .y = node_v.y };
        if (!edge.has_points) {
            edge.has_points = true;
            edge.points = .empty;
        }
        const first = try util.intersectRect(node_v.x, node_v.y, node_v.width, node_v.height, p1.x, p1.y);
        const last = try util.intersectRect(node_w.x, node_w.y, node_w.width, node_w.height, p2.x, p2.y);
        try edge.points.insert(a, 0, first);
        try edge.points.append(a, last);
    }
}

fn reversePointsForReversedEdges(g: *Graph) void {
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        if (edge.reversed) std.mem.reverse(Point, edge.points.items);
    }
}

fn runLayout(a: Allocator, g: *Graph, opts: types.Options) types.Error!void {
    makeSpaceForEdgeLabels(g);
    try removeSelfEdges(a, g);
    try acyclic.run(a, g);
    try nesting_graph.run(a, g);
    {
        var tmp = std.heap.ArenaAllocator.init(opts.temp);
        defer tmp.deinit();
        var nc = try util.asNonCompoundGraph(tmp.allocator(), g);
        try rank_mod.rank(&nc, opts);
    }
    try injectEdgeLabelProxies(a, g);
    try util.removeEmptyRanks(a, g);
    try nesting_graph.cleanup(a, g);
    util.normalizeRanks(g);
    assignRankMinMax(g);
    try removeEdgeLabelProxies(a, g);
    try normalize.run(a, g);
    try compound.parentDummyChains(a, g);
    try compound.addBorderSegments(a, g);
    try order_mod.order(g, opts);
    try insertSelfEdges(a, g);
    adjustCoordinateSystem(g);
    try position_mod.position(g, opts);
    try positionSelfEdges(a, g);
    try removeBorderNodes(a, g);
    try normalize.undo(a, g);
    fixupEdgeLabelCoords(g);
    undoCoordinateSystem(g);
    translateGraph(g);
    try assignNodeIntersects(a, g);
    reversePointsForReversedEdges(g);
    try acyclic.undo(a, g);
}

fn updateInputGraph(input: *Graph, layout_graph: *Graph) void {
    for (input.nodes()) |v| {
        const in = input.node(v).?;
        const out = layout_graph.node(v).?;
        in.x = out.x;
        in.y = out.y;
        if (layout_graph.children(v).?.len > 0) {
            in.width = out.width;
            in.height = out.height;
        }
    }
    for (input.edges()) |e| {
        const in = input.edgeLabel(e).?;
        const out = layout_graph.edgeLabel(e).?;
        in.points = out.points;
        in.has_points = out.has_points;
        if (out.x) |x| {
            in.x = x;
            in.y = out.y;
        }
    }
    input.label.width = layout_graph.label.width;
    input.label.height = layout_graph.label.height;
}

fn finite(x: f64) bool {
    return std.math.isFinite(x);
}

fn countOk(x: f64) bool {
    return finite(x) and x >= 0 and x <= 1024 and x == @floor(x);
}

fn validate(input: *const Graph) types.Error!void {
    if (input.nodeCount() > types.max_nodes) return error.LayoutFailed;
    // deep recursion would overflow a small worker stack
    for (input.nodes()) |v| {
        var depth: usize = 0;
        var p = input.parent(v);
        while (p) |x| : (p = input.parent(x)) {
            depth += 1;
            if (depth > types.max_nesting) return error.LayoutFailed;
        }
    }
    const gl = input.label;
    for ([_]f64{ gl.ranksep, gl.edgesep, gl.nodesep, gl.marginx, gl.marginy }) |x| if (!finite(x)) return error.InvalidInput;
    for (input.nodes()) |v| {
        const n = input.node(v).?;
        if (!finite(n.width) or !finite(n.height)) return error.InvalidInput;
    }
    for (input.edges()) |e| {
        const l = input.edgeLabel(e).?;
        if (!finite(l.width) or !finite(l.height) or !finite(l.labeloffset)) return error.InvalidInput;
        if (!countOk(l.minlen) or !countOk(l.weight)) return error.InvalidInput;
    }
}

pub fn layout(a: Allocator, input: *Graph, opts: types.Options) types.Error!void {
    try validate(input);
    var limited: types.Limited = .{ .limit = opts.temp_limit };
    var o = opts;
    o.temp = limited.allocator();
    var g = try buildLayoutGraph(a, input);
    try runLayout(a, &g, o);
    updateInputGraph(input, &g);
}

pub const Options = types.Options;
pub const Error = types.Error;
pub const Deadline = types.Deadline;
pub const GraphLabel = types.GraphLabel;

pub fn newGraph(a: Allocator, opts: struct { multigraph: bool = true, compound: bool = true }) Allocator.Error!Graph {
    const gl = try a.create(types.GraphLabel);
    gl.* = .{};
    return Graph.init(a, .{ .multigraph = opts.multigraph, .compound = opts.compound }, gl);
}

pub fn newNode(a: Allocator, width: f64, height: f64) Allocator.Error!*NodeLabel {
    const n = try a.create(NodeLabel);
    n.* = .{ .width = width, .height = height };
    return n;
}

pub fn newEdge(a: Allocator, label: EdgeLabel) Allocator.Error!*EdgeLabel {
    const l = try a.create(EdgeLabel);
    l.* = label;
    return l;
}
