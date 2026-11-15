const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const options = @import("options.zig");

pub const List = std.ArrayList(*eg.ElkNode);

const two_pi = 2 * std.math.pi;
const epsilon = 1e-10;

// Java's Math.max/min return NaN when either side is NaN; Zig's drop the NaN
pub fn jmax(a: f64, b: f64) f64 {
    return if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else @max(a, b);
}

pub fn jmin(a: f64, b: f64) f64 {
    return if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else @min(a, b);
}

// Radial's own guard against cyclic or heavily shared "trees", which recurse forever in the Java code.
pub const Ctx = struct {
    a: std.mem.Allocator,
    graph: *eg.ElkNode,
    root: *eg.ElkNode,
    budget: usize = 50_000_000,
    depth: usize = 0,
    max_depth: usize = 0,
    margins: std.AutoHashMapUnmanaged(*eg.ElkNode, lg.Margin) = .empty,

    fn fail() lg.Error {
        lg.setElkMessage("radial layout does not terminate: the graph is not a tree");
        return error.ElkException;
    }

    pub fn tick(c: *Ctx) lg.Error!void {
        if (c.budget == 0) return fail();
        c.budget -= 1;
    }

    pub fn enter(c: *Ctx) lg.Error!void {
        try c.tick();
        c.depth += 1;
        if (c.depth > c.max_depth) return fail();
    }

    pub fn leave(c: *Ctx) void {
        c.depth -= 1;
    }

    pub fn bound(c: *const Ctx, steps: usize) lg.Error!void {
        if (steps > c.max_depth) return fail();
    }

    pub fn margin(c: *const Ctx, n: *eg.ElkNode) lg.Margin {
        return c.margins.get(n) orelse .{};
    }

    pub fn spacing(c: *const Ctx) f64 {
        return c.graph.opts.spacing_node_node orelse 20;
    }
};

// RadialUtil.getSuccessors
pub fn successors(c: *Ctx, node: *eg.ElkNode) lg.Error!List {
    var out: List = .empty;
    try collect(c, node, &node.outgoing_edges, &out);
    for (node.ports.items) |p| try collect(c, node, &p.outgoing_edges, &out);
    return out;
}

fn collect(c: *Ctx, node: *eg.ElkNode, edges: *const std.ArrayList(*eg.ElkEdge), out: *List) lg.Error!void {
    for (edges.items) |e| {
        if (e.sources.items[0] == .port) continue;
        const target = e.targets.items[0].toNode();
        if (std.mem.indexOfScalar(*eg.ElkNode, node.children.items, target) == null) try out.append(c.a, target);
    }
}

// RadialUtil.findRoot
pub fn findRoot(graph: *eg.ElkNode) ?*eg.ElkNode {
    for (graph.children.items) |child| {
        if (treeParentEdge(child) == null) return child;
    }
    return null;
}

fn treeParentEdge(node: *eg.ElkNode) ?*eg.ElkEdge {
    if (node.incoming_edges.items.len > 0) return node.incoming_edges.items[0];
    for (node.ports.items) |p| if (p.incoming_edges.items.len > 0) return p.incoming_edges.items[0];
    return null;
}

// RadialUtil.getTreeParent
pub fn treeParent(node: *eg.ElkNode) ?*eg.ElkNode {
    const e = treeParentEdge(node) orelse return null;
    return e.sources.items[0].toNode();
}

pub fn findRootOfNode(c: *Ctx, node: *eg.ElkNode) lg.Error!*eg.ElkNode {
    var cur = node;
    var steps: usize = 0;
    while (treeParent(cur)) |p| {
        steps += 1;
        try c.bound(steps);
        cur = p;
    }
    return cur;
}

pub fn numberOfLeaves(c: *Ctx, node: *eg.ElkNode) lg.Error!f64 {
    try c.enter();
    defer c.leave();
    const succ = try successors(c, node);
    if (succ.items.len == 0) return 1;
    var leafs: f64 = 0;
    for (succ.items) |child| leafs += try numberOfLeaves(c, child);
    return leafs;
}

pub fn findLargestNodeInGraph(graph: *const eg.ElkNode) f64 {
    var largest: f64 = 0;
    for (graph.children.items) |child| {
        const diameter = @sqrt(child.width * child.width + child.height * child.height);
        largest = jmax(diameter, largest);
        largest = jmax(findLargestNodeInGraph(child), largest);
    }
    return largest;
}

pub fn nextLevelNodes(c: *Ctx, nodes: []const *eg.ElkNode) lg.Error!List {
    var out: List = .empty;
    for (nodes) |n| {
        const s = try successors(c, n);
        try out.appendSlice(c.a, s.items);
    }
    return out;
}

// getNextLevelNodeSet, in first-insertion order
pub fn nextLevelNodeSet(c: *Ctx, nodes: []const *eg.ElkNode) lg.Error!List {
    var out: List = .empty;
    for (nodes) |n| {
        const s = try successors(c, n);
        for (s.items) |t| {
            if (std.mem.indexOfScalar(*eg.ElkNode, out.items, t) == null) try out.append(c.a, t);
        }
    }
    return out;
}

pub fn centerNodesOnRadi(node: *eg.ElkNode, x: f64, y: f64) void {
    node.x = x - node.width / 2;
    node.y = y - node.height / 2;
}

pub fn clipVector(v: *lg.Vec, width: f64, height: f64) void {
    const wh = width / 2;
    const hh = height / 2;
    const absx = @abs(v.x);
    const absy = @abs(v.y);
    var xscale: f64 = 1;
    var yscale: f64 = 1;
    if (absx > wh) xscale = wh / absx;
    if (absy > hh) yscale = hh / absy;
    v.scale(@min(xscale, yscale));
}

fn fuzzyCompare(a: f64, b: f64) i32 {
    if (@abs(a - b) <= epsilon or a == b or (std.math.isNan(a) and std.math.isNan(b))) return 0;
    if (a < b) return -1;
    if (a > b) return 1;
    return @as(i32, @intFromBool(std.math.isNan(a))) - @as(i32, @intFromBool(std.math.isNan(b)));
}

fn position(n: *const eg.ElkNode) lg.Error!lg.Vec {
    return n.opts.position orelse {
        lg.setElkMessage("node has no position property");
        return error.ElkException;
    };
}

fn polarArc(n: *const eg.ElkNode, radial_offset: f64) lg.Error!f64 {
    const p = try position(n);
    var arc = std.math.atan2(p.y, p.x);
    if (arc < 0) arc += two_pi;
    arc += radial_offset;
    if (arc > two_pi) arc -= two_pi;
    return arc;
}

fn polarCompare(radial_offset: f64, a: *const eg.ElkNode, b: *const eg.ElkNode) lg.Error!i32 {
    return fuzzyCompare(try polarArc(a, radial_offset), try polarArc(b, radial_offset));
}

fn idOf(n: *const eg.ElkNode) i32 {
    return n.opts.radial_order_id orelse 0;
}

const Order = enum { id, right, left, top, bottom };

fn compare(order: Order, a: *const eg.ElkNode, b: *const eg.ElkNode) lg.Error!i32 {
    return switch (order) {
        .id => @as(i32, @intFromBool(idOf(a) > idOf(b))) - @intFromBool(idOf(a) < idOf(b)),
        .right => polarCompare(0, a, b),
        .left => polarCompare(std.math.pi, a, b),
        .top => polarCompare(1.5 * std.math.pi, a, b),
        .bottom => polarCompare(0.5 * std.math.pi, a, b),
    };
}

// List.sort is stable; an insertion sort gives the same order for a consistent comparator
fn sortBy(items: []*eg.ElkNode, order: Order) lg.Error!void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and try compare(order, items[j - 1], items[j]) > 0) : (j -= 1) {
            std.mem.swap(*eg.ElkNode, &items[j - 1], &items[j]);
        }
    }
}

// IRadialSorter: IDSorter or PolarCoordinateSorter, one instance per processor like the Java strategy create()
pub const Sorter = struct {
    kind: options.SortingStrategy,
    initialized: bool = false,

    pub fn of(g: *const eg.ElkNode) ?Sorter {
        const k = g.opts.radial_sorter orelse .none;
        return if (k == .none) null else .{ .kind = k };
    }

    pub fn initialize(s: *Sorter, c: *Ctx, root: *eg.ElkNode) lg.Error!void {
        if (s.kind != .polar_coordinate) return;
        s.initialized = true;
        const succ = try successors(c, root);
        try sortBy(succ.items, .right);
        _ = try setIdForNodes(c, succ.items, 0);
    }

    pub fn sort(s: *Sorter, c: *Ctx, nodes: []*eg.ElkNode) lg.Error!void {
        if (nodes.len == 0) return;
        if (s.kind == .polar_coordinate and !s.initialized) try s.initialize(c, try findRootOfNode(c, nodes[0]));
        try sortBy(nodes, .id);
    }
};

fn setIdForNodes(c: *Ctx, nodes: []*eg.ElkNode, id_offset: i32) lg.Error!i32 {
    try c.enter();
    defer c.leave();
    var id = id_offset;
    var next_layer_id: i32 = 0;
    const pi = std.math.pi;
    for (nodes) |node| {
        node.opts.radial_order_id = id;
        id += 1;
        const succ = try successors(c, node);
        var arc = std.math.atan2(node.y + node.height / 2, node.x + node.width / 2);
        arc += if (arc < 0) 2 * pi else 0;
        if (arc < 0.25 * pi or arc > 1.75 * pi) {
            try sortBy(succ.items, .left);
        } else if (arc <= 1.75 * pi and arc > 1.25 * pi) {
            try sortBy(succ.items, .top);
        } else if (arc <= 1.25 * pi and arc > 0.75 * pi) {
            try sortBy(succ.items, .right);
        } else if (arc <= 0.75 * pi) {
            try sortBy(succ.items, .bottom);
        }
        next_layer_id = try setIdForNodes(c, succ.items, next_layer_id);
    }
    return id;
}
