const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("util.zig");
const compaction = @import("compaction.zig");
const micro = @import("micro.zig");
const Ctx = util.Ctx;
const Node = *eg.ElkNode;

const degree_to_rad = std.math.pi / 180.0;

fn countNodes(n: *const eg.ElkNode) usize {
    var count: usize = 0;
    for (n.children.items) |ch| count += 1 + countNodes(ch);
    return count;
}

// RadialLayoutProvider.layout, ELK 0.9.1: no SPOrE overlap removal and no root selection strategies
pub fn layout(a: std.mem.Allocator, graph: *eg.ElkNode) lg.Error!void {
    // SAFETY: assigned before use
    var c: Ctx = .{ .a = a, .graph = graph, .root = undefined, .max_depth = countNodes(graph) + 2 };
    if (!(graph.opts.omit_node_micro_layout orelse false)) try micro.run(&c);
    c.root = util.findRoot(graph) orelse {
        lg.setElkMessage("The given graph is not a tree!");
        return error.ElkException;
    };
    var radius = graph.opts.radial_radius orelse 0;
    if (radius == 0) radius = util.findLargestNodeInGraph(graph);
    graph.opts.radial_radius = radius;

    try eades(&c, radius);
    try compaction.removeOverlaps(&c);
    switch (graph.opts.radial_compactor orelse .none) {
        .none => {},
        .radial_compaction => try compaction.radialCompaction(&c),
        .wedge_compaction => try compaction.wedgeCompaction(&c),
    }
    if (graph.opts.radial_rotate orelse false) try rotate(&c);
    calculateGraphSize(&c);
    try routeEdges(&c, c.root);
    if (graph.opts.radial_rotation_outgoing_edge_angles orelse false) try edgeAngles(&c);
}

// EadesRadial
const Eades = struct {
    c: *Ctx,
    radius: f64,
    sorter: ?util.Sorter,

    fn wedge(e: *Eades, node: Node) lg.Error!f64 {
        if ((e.c.graph.opts.radial_wedge_criteria orelse .node_size) == .leaf_number) return util.numberOfLeaves(e.c, node);
        return nodeSpace(e.c, node);
    }

    fn positionNodes(e: *Eades, node: Node, current_radius: f64, min_alpha: f64, max_alpha: f64, offset: f64) lg.Error!void {
        try e.c.enter();
        defer e.c.leave();
        const alpha_point = (min_alpha + max_alpha) / 2 + offset;
        const x_pos = current_radius * @cos(alpha_point);
        const y_pos = current_radius * @sin(alpha_point);
        util.centerNodesOnRadi(node, x_pos, y_pos);
        const number_of_leafs = try e.wedge(node);
        const tau = 2 * std.math.acos(current_radius / current_radius + e.radius);
        // SAFETY: assigned before use
        var s: f64 = undefined;
        // SAFETY: assigned before use
        var alpha: f64 = undefined;
        if (tau < max_alpha - min_alpha) {
            s = tau / number_of_leafs;
            alpha = (min_alpha + max_alpha - tau) / 2;
        } else {
            s = (max_alpha - min_alpha) / number_of_leafs;
            alpha = min_alpha;
        }
        const succ = try util.successors(e.c, node);
        if (e.sorter) |*sorter| {
            try sorter.initialize(e.c, e.c.root);
            try sorter.sort(e.c, succ.items);
        }
        for (succ.items) |child| {
            const child_leafs = try e.wedge(child);
            try e.positionNodes(child, current_radius + e.radius, alpha, alpha + s * child_leafs, offset);
            alpha += s * child_leafs;
        }
    }
};

fn nodeSpace(c: *Ctx, node: Node) lg.Error!f64 {
    try c.enter();
    defer c.leave();
    const succ = try util.successors(c, node);
    const node_size = @sqrt(node.height * node.height + node.width * node.width);
    var child_space: f64 = 0;
    for (succ.items) |child| child_space += try nodeSpace(c, child);
    return @max(child_space, node_size);
}

fn eades(c: *Ctx, radius: f64) lg.Error!void {
    var e: Eades = .{ .c = c, .radius = radius, .sorter = util.Sorter.of(c.graph) };
    const strategy = c.graph.opts.radial_optimization_criteria orelse .none;
    var optimal_offset: f64 = 0;
    var optimal_value: f64 = std.math.floatMax(f64);
    if (strategy != .none) {
        for (0..360) |i| {
            const offset = @as(f64, @floatFromInt(i)) * degree_to_rad;
            try e.positionNodes(c.root, 0, 0, 2 * std.math.pi, offset);
            const value = try evaluate(c, strategy);
            if (value < optimal_value) {
                optimal_offset = offset;
                optimal_value = value;
            }
        }
    }
    try e.positionNodes(c.root, 0, 0, 2 * std.math.pi, optimal_offset);
}

fn center(n: Node) lg.Vec {
    return .{ .x = n.x + n.width / 2, .y = n.y + n.height / 2 };
}

fn allOutgoing(a: std.mem.Allocator, node: Node) lg.Error!std.ArrayList(*eg.ElkEdge) {
    var out: std.ArrayList(*eg.ElkEdge) = .empty;
    try out.appendSlice(a, node.outgoing_edges.items);
    for (node.ports.items) |p| try out.appendSlice(a, p.outgoing_edges.items);
    return out;
}

fn positionOf(n: Node) lg.Error!*lg.Vec {
    if (n.opts.position) |*p| return p;
    lg.setElkMessage("node has no position property");
    return error.ElkException;
}

fn evaluate(c: *Ctx, strategy: @import("options.zig").RadialTranslationStrategy) lg.Error!f64 {
    const root = c.root;
    switch (strategy) {
        .none => return 0,
        .edge_length => {
            var edge_length: f64 = 0;
            for ((try allOutgoing(c.a, root)).items) |edge| {
                const target = edge.targets.items[0].toNode();
                var target_x = target.x + target.width / 2;
                var target_y = target.y + target.height / 2;
                var root_x = root.x + root.width / 2;
                var root_y = root.y + root.height / 2;
                var vector: lg.Vec = .{ .x = target_x - root_x, .y = target_y - root_y };
                var source_clip = vector;
                util.clipVector(&source_clip, root.width, root.height);
                vector.x -= source_clip.x;
                vector.y -= source_clip.y;
                root_x = target_x - vector.x;
                root_y = target_y - vector.y;
                var target_clip = vector;
                util.clipVector(&target_clip, target.width, target.height);
                vector.x -= target_clip.x;
                vector.y -= target_clip.y;
                target_x = root_x + vector.x;
                target_y = root_y + vector.y;
                const vx = target_x - root_x;
                const vy = target_y - root_y;
                edge_length += @sqrt(vx * vx + vy * vy);
            }
            return edge_length;
        },
        .edge_length_by_position => {
            var edge_length: f64 = 0;
            for ((try allOutgoing(c.a, root)).items) |edge| {
                const target = edge.targets.items[0].toNode();
                const target_x = target.x + target.width / 2;
                const target_y = target.y + target.height / 2;
                const position = (try positionOf(target)).*;
                const root_x = root.x + position.x + root.width / 2;
                const root_y = root.y + position.y + root.height;
                const vx = target_x - root_x;
                const vy = target_y - root_y;
                edge_length += @sqrt(vx * vx + vy * vy);
            }
            return edge_length;
        },
        .crossing_minimization_by_position => {
            var crossings: f64 = 0;
            const nodes = try util.successors(c, root);
            for (nodes.items, 0..) |node1, k| {
                for (nodes.items[k + 1 ..]) |node2| {
                    if (try isCrossing(root, node1, node2)) crossings += 1;
                }
            }
            return crossings;
        },
    }
}

// CrossingMinimizationPosition.isCrossing, including its in-place update of the POSITION vectors and rootY
// being computed from the root's x
fn isCrossing(root: Node, node1: Node, node2: Node) lg.Error!bool {
    const root_x = root.x + root.width / 2;
    const root_y = root.x + root.width / 2;
    const v1 = center(node1);
    const p1 = try positionOf(node1);
    p1.x = p1.x + root_x;
    p1.y = p1.y + root_y;
    const m1 = (v1.y - p1.y) / (v1.x - p1.x);
    const b1 = v1.y - m1 * v1.x;
    const v2 = center(node2);
    const p2 = try positionOf(node2);
    p2.x = p2.x + root_x;
    p2.y = p2.y + root_y;
    const m2 = (v2.y - p2.y) / (v2.x - p2.x);
    const b2 = v2.y - m2 * v2.x;
    const x_cut = (b1 - b2) / (m2 - m1);
    if ((p1.x < x_cut and v1.x < x_cut) or (x_cut < p1.x and x_cut < v1.x)) return false;
    if ((p2.x < x_cut and v2.x < x_cut) or (x_cut < p2.x and x_cut < v2.x)) return false;
    return true;
}

// AngleRotation
fn rotate(c: *Ctx) lg.Error!void {
    const graph = c.graph;
    var target_angle = graph.opts.radial_rotation_target_angle orelse 0;
    if (graph.opts.radial_rotation_compute_additional_wedge_space orelse false) {
        const out = c.root.outgoing_edges.items;
        if (out.len == 0) return error.ElkException;
        if (out[out.len - 1].targets.items[0] != .node or out[0].targets.items[0] != .node) return error.ElkException;
        const last_node = out[out.len - 1].targets.items[0].node;
        const first_node = out[0].targets.items[0].node;
        const last = center(last_node);
        const first = center(first_node);
        var alpha = target_angle;
        if (alpha <= 0) alpha += 2 * std.math.pi;
        var wedge_angle = std.math.acos((last.x * first.x + last.y * first.y) / (@sqrt(last.x * last.x + last.y * last.y) * @sqrt(first.x * first.x + first.y * first.y)));
        if (wedge_angle <= 0) wedge_angle += 2 * std.math.pi;
        var alignment_angle = std.math.atan2(last.y, last.x);
        if (alignment_angle <= 0) alignment_angle += 2 * std.math.pi;
        target_angle = std.math.pi - (alignment_angle - alpha + wedge_angle / 2);
    }
    for (graph.children.items) |node| {
        const pos = center(node);
        const new_x = pos.x * @cos(target_angle) - pos.y * @sin(target_angle);
        const new_y = pos.x * @sin(target_angle) + pos.y * @cos(target_angle);
        node.x = new_x - node.width / 2;
        node.y = new_y - node.height / 2;
    }
}

// CalculateGraphSize
fn calculateGraphSize(c: *Ctx) void {
    const graph = c.graph;
    var min_x = std.math.floatMax(f64);
    var min_y = std.math.floatMax(f64);
    var max_x = std.math.floatTrueMin(f64);
    var max_y = std.math.floatTrueMin(f64);
    for (graph.children.items) |node| {
        const m = c.margin(node);
        min_x = @min(min_x, node.x - m.left);
        min_y = @min(min_y, node.y - m.top);
        max_x = @max(max_x, node.x + node.width + m.right);
        max_y = @max(max_y, node.y + node.height + m.bottom);
    }
    const pad = graph.opts.padding orelse lg.Margin{ .top = 12, .left = 12, .bottom = 12, .right = 12 };
    var offset: lg.Vec = .{ .x = min_x - pad.left, .y = min_y - pad.top };
    var width = max_x - min_x + pad.left + pad.right;
    var height = max_y - min_y + pad.top + pad.bottom;
    if (graph.opts.radial_center_on_root orelse false) {
        const rm = c.margin(c.root);
        const root_x = c.root.x + c.root.width / 2 + (rm.left + rm.right) / 2 - offset.x;
        const root_y = c.root.y + c.root.height / 2 + (rm.top + rm.bottom) / 2 - offset.y;
        const dx = width - root_x;
        const dy = height - root_y;
        if (dx < width / 2) {
            const additional = dx - root_x;
            width += additional;
            offset.x -= additional;
        } else {
            width += root_x - dx;
        }
        if (dy < height / 2) {
            const additional = dy - root_y;
            height += additional;
            offset.y -= additional;
        } else {
            height += root_y - dy;
        }
    }
    for (graph.children.items) |node| {
        node.x -= offset.x;
        node.y -= offset.y;
    }
    if (!(graph.opts.node_size_fixed_graph_size orelse false)) {
        graph.width = width;
        graph.height = height;
    }
}

// StraightLineEdgeRouter
fn routeEdges(c: *Ctx, node: Node) lg.Error!void {
    try c.enter();
    defer c.leave();
    for ((try allOutgoing(c.a, node)).items) |edge| {
        if (edge.sources.items[0] == .port) continue;
        const target = edge.targets.items[0].toNode();
        if (isHierarchical(edge)) continue;
        var source_x = node.x + node.width / 2;
        var source_y = node.y + node.height / 2;
        var target_x = target.x + target.width / 2;
        var target_y = target.y + target.height / 2;
        var vector: lg.Vec = .{ .x = target_x - source_x, .y = target_y - source_y };
        var source_clip = vector;
        util.clipVector(&source_clip, node.width, node.height);
        vector.x -= source_clip.x;
        vector.y -= source_clip.y;
        source_x = target_x - vector.x;
        source_y = target_y - vector.y;
        var target_clip = vector;
        util.clipVector(&target_clip, target.width, target.height);
        vector.x -= target_clip.x;
        vector.y -= target_clip.y;
        target_x = source_x + vector.x;
        target_y = source_y + vector.y;
        const section = try firstSection(c.a, edge);
        section.start = .{ .x = source_x, .y = source_y };
        section.end = .{ .x = target_x, .y = target_y };
        try routeEdges(c, target);
    }
}

// ElkGraphUtil.firstEdgeSection(edge, true, true)
fn firstSection(a: std.mem.Allocator, edge: *eg.ElkEdge) lg.Error!*eg.ElkEdgeSection {
    if (edge.sections.items.len == 0) return eg.createEdgeSection(a, edge);
    const s = edge.sections.items[0];
    s.bend_points.clearRetainingCapacity();
    s.start = .{};
    s.end = .{};
    edge.sections.shrinkRetainingCapacity(1);
    return s;
}

// ElkEdge.isHierarchical
fn isHierarchical(e: *const eg.ElkEdge) bool {
    var common: ?*eg.ElkNode = null;
    var first = true;
    for ([_][]const eg.Shape{ e.sources.items, e.targets.items }) |list| {
        for (list) |sh| {
            const parent = sh.toNode().parent;
            if (first) {
                common = parent;
                first = false;
            } else if (common != parent) return true;
        }
    }
    return false;
}

// EdgeAngleCalculator
fn edgeAngles(c: *Ctx) lg.Error!void {
    for (c.root.outgoing_edges.items) |edge| {
        if (edge.sections.items.len == 0) return error.ElkException;
        const s = edge.sections.items[0];
        const angle = std.math.atan2(s.end.y - s.start.y, s.end.x - s.start.x);
        switch (edge.targets.items[0]) {
            .node => |n| n.opts.radial_rotation_target_angle = angle,
            .port => |p| p.opts.radial_rotation_target_angle = angle,
        }
    }
}
