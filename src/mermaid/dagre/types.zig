const std = @import("std");
const graph = @import("../graph.zig");

pub const Edge = graph.Edge;

pub const Point = struct { x: f64, y: f64 };

pub const Dummy = enum { none, root, border, edge, edge_label, edge_proxy, selfedge };

pub const BorderType = enum { none, left, right };

pub const BorderList = struct {
    base: usize = 0,
    items: std.ArrayList([]const u8) = .empty,

    pub fn get(self: BorderList, rank: usize) ?[]const u8 {
        if (rank < self.base or rank - self.base >= self.items.items.len) return null;
        return self.items.items[rank - self.base];
    }

    pub fn last(self: BorderList) ?[]const u8 {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }
};

pub const SelfEdge = struct { e: Edge, label: *EdgeLabel };

pub const NodeLabel = struct {
    width: f64 = 0,
    height: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    user: usize = 0,
    rank: ?f64 = null,
    order: i64 = 0,
    dummy: Dummy = .none,
    border_type: BorderType = .none,
    min_rank: ?f64 = null,
    max_rank: ?f64 = null,
    border_top: ?[]const u8 = null,
    border_bottom: ?[]const u8 = null,
    border_left: BorderList = .{},
    border_right: BorderList = .{},
    bl: ?[]const u8 = null,
    br: ?[]const u8 = null,
    self_edges: std.ArrayList(SelfEdge) = .empty,
    e: ?Edge = null,
    label: ?*EdgeLabel = null,
    edge_label: ?*EdgeLabel = null,
    labelpos: ?u8 = null,
};

pub const EdgeLabel = struct {
    minlen: f64 = 1,
    weight: f64 = 1,
    width: f64 = 0,
    height: f64 = 0,
    labeloffset: f64 = 10,
    labelpos: u8 = 'r',
    user: usize = 0,
    points: std.ArrayList(Point) = .empty,
    has_points: bool = false,
    x: ?f64 = null,
    y: ?f64 = null,
    reversed: bool = false,
    forward_name: ?[]const u8 = null,
    label_rank: ?f64 = null,
    nesting_edge: bool = false,
};

pub const GraphLabel = struct {
    ranksep: f64 = 50,
    edgesep: f64 = 20,
    nodesep: f64 = 50,
    marginx: f64 = 0,
    marginy: f64 = 0,
    rankdir: []const u8 = "tb",
    acyclicer: ?[]const u8 = null,
    ranker: ?[]const u8 = null,
    @"align": ?[]const u8 = null,
    width: f64 = 0,
    height: f64 = 0,
    nesting_root: ?[]const u8 = null,
    node_rank_factor: f64 = 0,
    dummy_chains: std.ArrayList([]const u8) = .empty,
    uid: u32 = 0,
};

pub const Graph = graph.Graph(*NodeLabel, *EdgeLabel, *GraphLabel);

pub fn nextId(gl: *GraphLabel, a: std.mem.Allocator, prefix: []const u8) std.mem.Allocator.Error![]const u8 {
    gl.uid += 1;
    return std.fmt.allocPrint(a, "{s}{d}", .{ prefix, gl.uid });
}

pub fn edgeOf(g: *const Graph, e: Edge) *EdgeLabel {
    return g.edgeLabel(e).?;
}

pub fn nodeOf(g: *const Graph, v: []const u8) *NodeLabel {
    return g.node(v).?;
}

pub const Deadline = struct {
    ctx: *anyopaque,
    expired: *const fn (*anyopaque) bool,
};

pub const Options = struct {
    // working memory is freed when each phase ends; its live total may not pass this many bytes
    temp_limit: usize = 256 << 20,
    // set by layout from temp_limit
    temp: std.mem.Allocator = std.heap.page_allocator,
    deadline: ?Deadline = null,
    pivot_cap: ?usize = null,
};

pub const Error = std.mem.Allocator.Error || graph.ParentError || error{ Disconnected, NoIntersection, Deadline, LayoutFailed, InvalidInput };

pub fn checkDeadline(opts: Options) error{Deadline}!void {
    if (opts.deadline) |d| if (d.expired(d.ctx)) return error.Deadline;
}

pub const max_nesting = 64;
pub const max_nodes = 20000;

// page_allocator that refuses to hold more than `limit` live bytes
pub const Limited = struct {
    limit: usize,
    live: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (len > self.limit - self.live) return null;
        const p = std.heap.page_allocator.rawAlloc(len, al, ra) orelse return null;
        self.live += len;
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (n > m.len and n - m.len > self.limit - self.live) return false;
        if (!std.heap.page_allocator.rawResize(m, al, n, ra)) return false;
        self.live = self.live - m.len + n;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (n > m.len and n - m.len > self.limit - self.live) return null;
        const p = std.heap.page_allocator.rawRemap(m, al, n, ra) orelse return null;
        self.live = self.live - m.len + n;
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        std.heap.page_allocator.rawFree(m, al, ra);
        self.live -= m.len;
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    pub fn allocator(self: *Limited) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};
