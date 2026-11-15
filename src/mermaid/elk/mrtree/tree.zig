const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("../util.zig");
const opts = @import("options.zig");
const Allocator = std.mem.Allocator;
const Vec = lg.Vec;
const Dir = lg.Direction;

pub const TEdge = struct {
    source: *TNode,
    target: *TNode,
    // KVectorChain: the points are shared objects that later steps keep mutating
    bends: std.ArrayList(*Vec) = .empty,
    origin: ?*eg.ElkEdge = null,

    pub fn addFirst(e: *TEdge, a: Allocator, x: f64, y: f64) Allocator.Error!void {
        const p = try a.create(Vec);
        p.* = .{ .x = x, .y = y };
        try e.bends.insert(a, 0, p);
    }

    pub fn addLast(e: *TEdge, a: Allocator, x: f64, y: f64) Allocator.Error!void {
        const p = try a.create(Vec);
        p.* = .{ .x = x, .y = y };
        try e.bends.append(a, p);
    }

    pub fn name(e: *const TEdge, a: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(a, "{s}->{s}", .{ try e.source.name(a), try e.target.name(a) });
    }
};

pub const TNode = struct {
    id: i32,
    label: []const u8 = "",
    pos: Vec = .{},
    size: Vec = .{},
    outgoing: std.ArrayList(*TEdge) = .empty,
    incoming: std.ArrayList(*TEdge) = .empty,
    origin: ?*eg.ElkNode = null,
    root: bool = false,
    fan: i32 = 0,
    descendants: i32 = 0,
    level: i32 = 0,
    position: i32 = 0,
    priority: i32 = 1,
    position_constraint: i32 = -1,
    padding: lg.Margin = .{ .top = 20, .left = 20, .bottom = 20, .right = 20 },
    left_neighbor: ?*TNode = null,
    right_neighbor: ?*TNode = null,
    left_sibling: ?*TNode = null,
    right_sibling: ?*TNode = null,
    prelim: f64 = 0,
    modifier: f64 = 0,
    xcoor: i32 = 0,
    ycoor: i32 = 0,
    level_height: f64 = 0,
    level_min: f64 = 0,
    level_max: f64 = 0,

    pub fn name(n: *const TNode, a: Allocator) Allocator.Error![]const u8 {
        if (n.label.len == 0) return std.fmt.allocPrint(a, "n_{d}", .{n.id});
        return std.fmt.allocPrint(a, "n_{s}", .{n.label});
    }

    pub fn isLeaf(n: *const TNode) bool {
        return n.outgoing.items.len == 0;
    }

    pub fn getParent(n: *const TNode) ?*TNode {
        if (n.incoming.items.len == 0) return null;
        return n.incoming.items[0].source;
    }

    pub fn firstChild(n: *const TNode) ?*TNode {
        if (n.outgoing.items.len == 0) return null;
        return n.outgoing.items[0].target;
    }

    pub fn lastChild(n: *const TNode) ?*TNode {
        if (n.outgoing.items.len == 0) return null;
        return n.outgoing.items[n.outgoing.items.len - 1].target;
    }

    pub fn childrenCopy(n: *const TNode, a: Allocator) Allocator.Error!std.ArrayList(*TNode) {
        var out: std.ArrayList(*TNode) = .empty;
        for (n.outgoing.items) |e| try out.append(a, e.target);
        return out;
    }
};

pub const TGraph = struct {
    nodes: std.ArrayList(*TNode) = .empty,
    edges: std.ArrayList(*TEdge) = .empty,
    direction: Dir = .undefined,
    xmin: f64 = 0,
    ymin: f64 = 0,
    xmax: f64 = 0,
    ymax: f64 = 0,
    removable: std.ArrayList(*TEdge) = .empty,
    priority: i32 = 1,
    bb_upleft: Vec = .{},
    bb_lowright: Vec = .{},
};

pub const Config = struct {
    spacing_node_node: f64 = 20,
    spacing_edge_node: f64 = 3,
    edge_end_texture_length: f64 = 7,
    weighting: opts.OrderWeighting = .model_order,
    search_order: opts.TreeifyingOrder = .dfs,
    routing_mode: opts.EdgeRoutingMode = .avoid_overlap,
    compaction: bool = false,
    aspect_ratio: f64 = 1.6,
    separate_components: bool = true,
    fixed_graph_size: bool = false,
    padding: lg.Margin = .{ .top = 20, .left = 20, .bottom = 20, .right = 20 },
    direction: Dir = .undefined,
};

// Direction.isHorizontal / isVertical (UNDEFINED is neither)
pub fn isHorizontal(d: Dir) bool {
    return d == .left or d == .right;
}

pub fn isVertical(d: Dir) bool {
    return d == .up or d == .down;
}

pub fn newNode(a: Allocator, id: i32, label: []const u8) Allocator.Error!*TNode {
    const n = try a.create(TNode);
    n.* = .{ .id = id, .label = label };
    return n;
}

pub fn newEdge(a: Allocator, source: *TNode, target: *TNode) Allocator.Error!*TEdge {
    const e = try a.create(TEdge);
    e.* = .{ .source = source, .target = target };
    return e;
}

// TNode.addChild
pub fn addChild(a: Allocator, g: *TGraph, parent: *TNode, child: *TNode) Allocator.Error!void {
    const e = try newEdge(a, parent, child);
    try g.edges.append(a, e);
    try parent.outgoing.append(a, e);
    try child.incoming.append(a, e);
}

pub fn getRoot(g: *const TGraph) lg.Error!*TNode {
    for (g.nodes.items) |n| if (n.root) return n;
    return error.ElkException;
}

pub fn directionVector(d: Dir) Vec {
    return switch (d) {
        .up => .{ .x = 0, .y = -1 },
        .right => .{ .x = 1, .y = 0 },
        .left => .{ .x = -1, .y = 0 },
        else => .{ .x = 0, .y = 1 },
    };
}

pub fn toNodeBorder(center: *Vec, next: Vec, size: Vec) void {
    const wh = size.x / 2;
    const hh = size.y / 2;
    const absx = @abs(next.x - center.x);
    const absy = @abs(next.y - center.y);
    var xscale: f64 = 1;
    var yscale: f64 = 1;
    if (absx > wh) xscale = wh / absx;
    if (absy > hh) yscale = hh / absy;
    const scale = @min(xscale, yscale);
    center.x += scale * (next.x - center.x);
    center.y += scale * (next.y - center.y);
}

pub fn isCycleInducing(e: *const TEdge, g: *const TGraph) bool {
    const v = directionVector(g.direction);
    return v.x * (e.target.pos.x - e.source.pos.x) + v.y * (e.target.pos.y - e.source.pos.y) <= 0;
}

pub fn firstPoint(e: *const TEdge) Vec {
    if (e.bends.items.len == 0) return .{ .x = e.target.pos.x, .y = e.target.pos.y };
    return e.bends.items[0].*;
}

// getLastPoint falls back to the source position, not the target
pub fn lastPoint(e: *const TEdge) Vec {
    if (e.bends.items.len == 0) return .{ .x = e.source.pos.x, .y = e.source.pos.y };
    return e.bends.items[e.bends.items.len - 1].*;
}

// TreeUtil.getLeftMost(level, depth)
pub fn getLeftMost(a: Allocator, level: []const *TNode, depth: i32) Allocator.Error!?*TNode {
    var cur = level;
    var d = depth;
    while (true) {
        if (cur.len == 0) return null;
        if (1 < d or d < 0) {
            var next: std.ArrayList(*TNode) = .empty;
            for (cur) |n| for (n.outgoing.items) |e| try next.append(a, e.target);
            if (1 < d) {
                d -= 1;
                cur = next.items;
                continue;
            }
            if (next.items.len > 0) {
                cur = next.items;
                continue;
            }
        }
        return cur[0];
    }
}

fn nameIn(names: []const []const u8, s: []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn lessSourceX(_: void, x: *TEdge, y: *TEdge) bool {
    return util.doubleCompare(x.source.pos.x, y.source.pos.x) == .lt;
}

fn lessTargetX(_: void, x: *TEdge, y: *TEdge) bool {
    return util.doubleCompare(x.target.pos.x, y.target.pos.x) == .lt;
}

pub fn allIncomingEdges(a: Allocator, n: *const TNode, g: *const TGraph) Allocator.Error!std.ArrayList(*TEdge) {
    var re: std.ArrayList(*TEdge) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (g.edges.items) |e| {
        if (e.target.id != n.id or e.source.level == e.target.level) continue;
        const s = try e.name(a);
        if (nameIn(names.items, s)) continue;
        try names.append(a, s);
        try re.append(a, e);
    }
    std.mem.sort(*TEdge, re.items, {}, lessSourceX);
    return re;
}

pub fn allOutgoingEdges(a: Allocator, n: *const TNode, g: *const TGraph) Allocator.Error!std.ArrayList(*TEdge) {
    var re: std.ArrayList(*TEdge) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (g.edges.items) |e| {
        if (e.source.id != n.id or std.mem.eql(u8, e.source.label, "SUPER_ROOT")) continue;
        if (e.source.level == e.target.level) continue;
        const s = try e.name(a);
        if (nameIn(names.items, s)) continue;
        try names.append(a, s);
        try re.append(a, e);
    }
    std.mem.sort(*TEdge, re.items, {}, lessTargetX);
    return re;
}
