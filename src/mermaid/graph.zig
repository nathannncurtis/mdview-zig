const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Edge = struct {
    v: []const u8,
    w: []const u8,
    name: ?[]const u8 = null,

    pub fn eql(a: Edge, b: Edge) bool {
        if (!std.mem.eql(u8, a.v, b.v) or !std.mem.eql(u8, a.w, b.w)) return false;
        if (a.name) |an| return if (b.name) |bn| std.mem.eql(u8, an, bn) else false;
        return b.name == null;
    }
};

const EdgeCtx = struct {
    pub fn hash(_: EdgeCtx, e: Edge) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(e.v);
        h.update("\x01");
        h.update(e.w);
        h.update("\x01");
        h.update(e.name orelse "\x00");
        return h.final();
    }
    pub fn eql(_: EdgeCtx, a: Edge, b: Edge) bool {
        return a.eql(b);
    }
};

// JS arrays and objects order keys that look like array indices first, ascending.
pub fn indexKey(k: []const u8) ?u32 {
    if (k.len == 0 or k.len > 10) return null;
    if (k.len > 1 and k[0] == '0') return null;
    var v: u64 = 0;
    for (k) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    if (v > 4294967294) return null;
    return @intCast(v);
}

fn utf16Key(cp: u21) u32 {
    if (cp < 0x10000) return @as(u32, cp) << 16;
    const c = cp - 0x10000;
    return (@as(u32, 0xD800 + (c >> 10)) << 16) | (0xDC00 + (c & 0x3FF));
}

// JS compares strings by UTF-16 code unit, which differs from UTF-8 byte order for astral characters.
pub fn cmpUtf16(a: []const u8, b: []const u8) std.math.Order {
    if (!std.unicode.utf8ValidateSlice(a) or !std.unicode.utf8ValidateSlice(b)) return std.mem.order(u8, a, b);
    var ia = (std.unicode.Utf8View.initUnchecked(a)).iterator();
    var ib = (std.unicode.Utf8View.initUnchecked(b)).iterator();
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null and cb == null) return .eq;
        if (ca == null) return .lt;
        if (cb == null) return .gt;
        const ka = utf16Key(ca.?);
        const kb = utf16Key(cb.?);
        if (ka != kb) return std.math.order(ka, kb);
    }
}

// graphlib keeps one small map per node, so grow lists from one slot rather than std's cache-line sized first block
fn reserveOne(list: anytype, a: Allocator) Allocator.Error!void {
    if (list.items.len == list.capacity) try list.ensureTotalCapacityPrecise(a, if (list.capacity == 0) 1 else list.capacity * 2);
}

pub fn KeyList(comptime V: type) type {
    return struct {
        const Self = @This();
        keys: std.ArrayList([]const u8) = .empty,
        vals: std.ArrayList(V) = .empty,
        n_int: usize = 0,

        pub fn find(self: *const Self, key: []const u8) ?usize {
            if (indexKey(key)) |ik| {
                var lo: usize = 0;
                var hi: usize = self.n_int;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const mk = indexKey(self.keys.items[mid]).?;
                    if (mk == ik) return mid;
                    if (mk < ik) lo = mid + 1 else hi = mid;
                }
                return null;
            }
            for (self.keys.items[self.n_int..], self.n_int..) |k, i| {
                if (std.mem.eql(u8, k, key)) return i;
            }
            return null;
        }

        pub fn insert(self: *Self, a: Allocator, key: []const u8, val: V) Allocator.Error!void {
            if (indexKey(key)) |ik| {
                var lo: usize = 0;
                var hi: usize = self.n_int;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (indexKey(self.keys.items[mid]).? < ik) lo = mid + 1 else hi = mid;
                }
                try reserveOne(&self.keys, a);
                try reserveOne(&self.vals, a);
                self.keys.insertAssumeCapacity(lo, key);
                self.vals.insertAssumeCapacity(lo, val);
                self.n_int += 1;
            } else {
                try reserveOne(&self.keys, a);
                try reserveOne(&self.vals, a);
                self.keys.appendAssumeCapacity(key);
                self.vals.appendAssumeCapacity(val);
            }
        }

        pub fn removeAt(self: *Self, i: usize) void {
            if (i < self.n_int) self.n_int -= 1;
            _ = self.keys.orderedRemove(i);
            _ = self.vals.orderedRemove(i);
        }

        pub fn remove(self: *Self, key: []const u8) bool {
            const i = self.find(key) orelse return false;
            self.removeAt(i);
            return true;
        }
    };
}

pub fn jsKeyOrder(a: Allocator, keys: []const []const u8) Allocator.Error![]usize {
    const out = try a.alloc(usize, keys.len);
    var n: usize = 0;
    for (keys, 0..) |k, i| {
        if (indexKey(k) != null) {
            out[n] = i;
            n += 1;
        }
    }
    const Ctx = struct {
        keys: []const []const u8,
        fn lt(c: @This(), x: usize, y: usize) bool {
            return indexKey(c.keys[x]).? < indexKey(c.keys[y]).?;
        }
    };
    std.mem.sort(usize, out[0..n], Ctx{ .keys = keys }, Ctx.lt);
    for (keys, 0..) |k, i| {
        if (indexKey(k) == null) {
            out[n] = i;
            n += 1;
        }
    }
    return out;
}

pub const ParentError = Allocator.Error || error{ Cycle, NotCompound };

pub const Options = struct {
    directed: bool = true,
    multigraph: bool = false,
    compound: bool = false,
};

pub fn Graph(comptime N: type, comptime E: type, comptime G: type) type {
    return struct {
        const Self = @This();

        pub const Rec = struct {
            label: N,
            parent: ?[]const u8 = null,
            children: KeyList(void) = .{},
            in_edges: std.ArrayList(Edge) = .empty,
            out_edges: std.ArrayList(Edge) = .empty,
            preds: KeyList(u32) = .{},
            sucs: KeyList(u32) = .{},
        };

        pub const NodeDefault = struct {
            ctx: *anyopaque,
            f: *const fn (*anyopaque, []const u8) N,
        };

        a: Allocator,
        directed: bool,
        multigraph: bool,
        compound: bool,
        label: G,
        recs: std.StringHashMap(*Rec),
        node_order: KeyList(void) = .{},
        root_children: KeyList(void) = .{},
        edge_map: std.HashMap(Edge, E, EdgeCtx, 80),
        edge_order: std.ArrayList(Edge) = .empty,
        default_node: ?N = null,
        default_node_fn: ?NodeDefault = null,
        default_edge: ?E = null,

        pub fn init(a: Allocator, opts: Options, label: G) Self {
            return .{
                .a = a,
                .directed = opts.directed,
                .multigraph = opts.multigraph,
                .compound = opts.compound,
                .label = label,
                .recs = std.StringHashMap(*Rec).init(a),
                .edge_map = std.HashMap(Edge, E, EdgeCtx, 80).init(a),
            };
        }

        pub fn nodeCount(self: *const Self) usize {
            return self.node_order.keys.items.len;
        }

        pub fn edgeCount(self: *const Self) usize {
            return self.edge_order.items.len;
        }

        pub fn nodes(self: *const Self) []const []const u8 {
            return self.node_order.keys.items;
        }

        pub fn edges(self: *const Self) []const Edge {
            return self.edge_order.items;
        }

        pub fn hasNode(self: *const Self, v: []const u8) bool {
            return self.recs.contains(v);
        }

        pub fn node(self: *const Self, v: []const u8) ?N {
            const r = self.recs.get(v) orelse return null;
            return r.label;
        }

        pub fn nodePtr(self: *const Self, v: []const u8) ?*N {
            const r = self.recs.get(v) orelse return null;
            return &r.label;
        }

        pub fn setNode(self: *Self, v: []const u8, label: N) Allocator.Error!void {
            if (self.recs.get(v)) |r| {
                r.label = label;
                return;
            }
            try self.addNode(v, label);
        }

        // setNode(v) with no value: an existing node is left alone.
        pub fn ensureNode(self: *Self, v: []const u8) Allocator.Error!void {
            if (self.recs.contains(v)) return;
            const label: N = if (self.default_node_fn) |d| d.f(d.ctx, v) else if (self.default_node) |d| d else if (comptime @typeInfo(N) == .pointer) @panic("node has no label") else std.mem.zeroes(N);
            try self.addNode(v, label);
        }

        fn addNode(self: *Self, v: []const u8, label: N) Allocator.Error!void {
            const r = try self.a.create(Rec);
            r.* = .{ .label = label };
            try self.recs.put(v, r);
            try self.node_order.insert(self.a, v, {});
            if (self.compound) try self.root_children.insert(self.a, v, {});
        }

        pub fn sources(self: *const Self, a: Allocator) Allocator.Error![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            for (self.nodes()) |v| if (self.recs.get(v).?.in_edges.items.len == 0) try out.append(a, v);
            return out.items;
        }

        pub fn parent(self: *const Self, v: []const u8) ?[]const u8 {
            if (!self.compound) return null;
            const r = self.recs.get(v) orelse return null;
            return r.parent;
        }

        pub fn children(self: *const Self, v: ?[]const u8) ?[]const []const u8 {
            if (!self.compound) {
                if (v == null) return self.nodes();
                return if (self.hasNode(v.?)) &.{} else null;
            }
            const k = v orelse return self.root_children.keys.items;
            const r = self.recs.get(k) orelse return null;
            return r.children.keys.items;
        }

        fn childList(self: *Self, p: ?[]const u8) *KeyList(void) {
            return if (p) |k| &self.recs.get(k).?.children else &self.root_children;
        }

        pub fn setParent(self: *Self, v: []const u8, p: ?[]const u8) ParentError!void {
            if (!self.compound) return error.NotCompound;
            if (p) |pk| {
                var anc: ?[]const u8 = pk;
                while (anc) |x| : (anc = self.parent(x)) {
                    if (std.mem.eql(u8, x, v)) return error.Cycle;
                }
                try self.ensureNode(pk);
            }
            try self.ensureNode(v);
            const r = self.recs.get(v).?;
            _ = self.childList(r.parent).remove(v);
            r.parent = p;
            try self.childList(p).insert(self.a, v, {});
        }

        pub fn removeNode(self: *Self, v: []const u8) Allocator.Error!void {
            const r = self.recs.get(v) orelse return;
            for (try self.a.dupe(Edge, r.in_edges.items)) |e| self.removeEdge(e);
            for (try self.a.dupe(Edge, r.out_edges.items)) |e| self.removeEdge(e);
            if (self.compound) {
                _ = self.childList(r.parent).remove(v);
                const kids = try self.a.dupe([]const u8, r.children.keys.items);
                for (kids) |c| self.setParent(c, null) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
            }
            _ = self.recs.remove(v);
            _ = self.node_order.remove(v);
        }

        pub fn predecessors(self: *const Self, v: []const u8) ?[]const []const u8 {
            const r = self.recs.get(v) orelse return null;
            return r.preds.keys.items;
        }

        pub fn successors(self: *const Self, v: []const u8) ?[]const []const u8 {
            const r = self.recs.get(v) orelse return null;
            return r.sucs.keys.items;
        }

        pub fn neighbors(self: *const Self, a: Allocator, v: []const u8) Allocator.Error!?[]const []const u8 {
            const r = self.recs.get(v) orelse return null;
            var out: std.ArrayList([]const u8) = .empty;
            try out.appendSlice(a, r.preds.keys.items);
            for (r.sucs.keys.items) |s| {
                if (r.preds.find(s) == null) try out.append(a, s);
            }
            return out.items;
        }

        fn normalize(self: *const Self, e: Edge) Edge {
            if (!self.directed and cmpUtf16(e.v, e.w) == .gt) return .{ .v = e.w, .w = e.v, .name = e.name };
            return e;
        }

        pub fn edgeKey(self: *const Self, v: []const u8, w: []const u8, name: ?[]const u8) Edge {
            return self.normalize(.{ .v = v, .w = w, .name = if (name) |n| (if (n.len == 0) null else n) else null });
        }

        pub fn edgeLabel(self: *const Self, e: Edge) ?E {
            return self.edge_map.get(self.normalize(e));
        }

        pub fn edgeLabelPtr(self: *const Self, e: Edge) ?*E {
            return self.edge_map.getPtr(self.normalize(e));
        }

        pub fn edge(self: *const Self, v: []const u8, w: []const u8) ?E {
            return self.edgeLabel(.{ .v = v, .w = w });
        }

        pub fn hasEdge(self: *const Self, e: Edge) bool {
            return self.edge_map.contains(self.normalize(e));
        }

        pub fn setEdge(self: *Self, e: Edge, label: E) Allocator.Error!void {
            try self.putEdge(e, label, true);
        }

        pub fn setEdgeDefault(self: *Self, e: Edge) Allocator.Error!void {
            try self.putEdge(e, self.default_edge orelse std.mem.zeroes(E), false);
        }

        fn putEdge(self: *Self, e0: Edge, label: E, replace: bool) Allocator.Error!void {
            const e = self.edgeKey(e0.v, e0.w, e0.name);
            if (self.edge_map.getPtr(e)) |p| {
                if (replace) p.* = label;
                return;
            }
            std.debug.assert(e.name == null or self.multigraph);
            try self.ensureNode(e.v);
            try self.ensureNode(e.w);
            try self.edge_map.put(e, label);
            try reserveOne(&self.edge_order, self.a);
            self.edge_order.appendAssumeCapacity(e);
            const rv = self.recs.get(e.v).?;
            const rw = self.recs.get(e.w).?;
            try bump(self.a, &rw.preds, e.v);
            try bump(self.a, &rv.sucs, e.w);
            try reserveOne(&rw.in_edges, self.a);
            rw.in_edges.appendAssumeCapacity(e);
            try reserveOne(&rv.out_edges, self.a);
            rv.out_edges.appendAssumeCapacity(e);
        }

        fn bump(a: Allocator, l: *KeyList(u32), k: []const u8) Allocator.Error!void {
            if (l.find(k)) |i| l.vals.items[i] += 1 else try l.insert(a, k, 1);
        }

        fn unbump(l: *KeyList(u32), k: []const u8) void {
            const i = l.find(k).?;
            l.vals.items[i] -= 1;
            if (l.vals.items[i] == 0) l.removeAt(i);
        }

        fn dropEdge(list: *std.ArrayList(Edge), e: Edge) void {
            for (list.items, 0..) |x, i| {
                if (x.eql(e)) {
                    _ = list.orderedRemove(i);
                    return;
                }
            }
        }

        pub fn removeEdge(self: *Self, e0: Edge) void {
            const e = self.normalize(e0);
            if (!self.edge_map.remove(e)) return;
            dropEdge(&self.edge_order, e);
            const rv = self.recs.get(e.v).?;
            const rw = self.recs.get(e.w).?;
            unbump(&rw.preds, e.v);
            unbump(&rv.sucs, e.w);
            dropEdge(&rw.in_edges, e);
            dropEdge(&rv.out_edges, e);
        }

        pub fn inEdges(self: *const Self, v: []const u8) ?[]const Edge {
            const r = self.recs.get(v) orelse return null;
            return r.in_edges.items;
        }

        pub fn outEdges(self: *const Self, v: []const u8) ?[]const Edge {
            const r = self.recs.get(v) orelse return null;
            return r.out_edges.items;
        }

        pub fn outEdgesTo(self: *const Self, a: Allocator, v: []const u8, w: []const u8) Allocator.Error![]const Edge {
            var out: std.ArrayList(Edge) = .empty;
            for (self.outEdges(v) orelse &.{}) |e| if (std.mem.eql(u8, e.w, w)) try out.append(a, e);
            return out.items;
        }
    };
}

test "key order puts index keys first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Graph(u8, u8, void).init(a, .{}, {});
    for ([_][]const u8{ "b", "10", "a", "9", "01", "2" }) |k| try g.setNode(k, 0);
    const want = [_][]const u8{ "2", "9", "10", "b", "a", "01" };
    try std.testing.expectEqual(want.len, g.nodes().len);
    for (want, g.nodes()) |x, y| try std.testing.expectEqualStrings(x, y);
    try g.removeNode("9");
    try g.setNode("9", 0);
    try std.testing.expectEqualStrings("9", g.nodes()[1]);
}

test "edges, parents and removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Graph(u8, u8, void).init(a, .{ .multigraph = true, .compound = true }, {});
    for ([_][]const u8{ "a", "b", "c" }) |k| try g.setNode(k, 0);
    try g.setParent("a", "c");
    try g.setEdge(.{ .v = "a", .w = "b" }, 1);
    try g.setEdge(.{ .v = "a", .w = "b", .name = "x" }, 2);
    try std.testing.expectEqual(@as(usize, 2), g.edgeCount());
    try std.testing.expectEqual(@as(?u8, 2), g.edgeLabel(.{ .v = "a", .w = "b", .name = "x" }));
    try std.testing.expectEqual(@as(usize, 1), g.successors("a").?.len);
    try std.testing.expectError(error.Cycle, g.setParent("c", "a"));
    try g.removeNode("c");
    try std.testing.expect(g.parent("a") == null);
    g.removeEdge(.{ .v = "a", .w = "b" });
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());
    try std.testing.expectEqual(@as(usize, 1), g.predecessors("b").?.len);
    g.removeEdge(.{ .v = "a", .w = "b", .name = "x" });
    try std.testing.expectEqual(@as(usize, 0), g.predecessors("b").?.len);
}

test "undirected edges are normalized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g = Graph(u8, u8, void).init(arena.allocator(), .{ .directed = false }, {});
    try g.setNode("a", 0);
    try g.setNode("b", 0);
    try g.setEdge(.{ .v = "b", .w = "a" }, 7);
    try std.testing.expectEqual(@as(?u8, 7), g.edge("a", "b"));
    try std.testing.expectEqualStrings("a", g.edges()[0].v);
}

test "utf16 order differs from byte order for astral characters" {
    try std.testing.expectEqual(std.math.Order.lt, cmpUtf16("\u{1F600}", "\u{E000}"));
    try std.testing.expectEqual(std.math.Order.gt, std.mem.order(u8, "\u{1F600}", "\u{E000}"));
}
