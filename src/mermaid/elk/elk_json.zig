const std = @import("std");
const eg = @import("elk_graph.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Error = error{ OutOfMemory, InvalidGraph };

// JsonImporter.transform for the elkjs JSON graph format. Everything is allocated in `a` (an arena).
pub fn parse(a: Allocator, src: []const u8) Error!*eg.ElkNode {
    const v = std.json.parseFromSliceLeaky(Value, a, src, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGraph,
    };
    return fromValue(a, v);
}

pub fn fromValue(a: Allocator, v: Value) Error!*eg.ElkNode {
    var imp: Importer = .{ .a = a };
    const root = try imp.transformNode(v, null);
    try imp.transformEdges(v, root);
    return root;
}

const Importer = struct {
    a: Allocator,
    nodes: std.StringHashMapUnmanaged(*eg.ElkNode) = .empty,
    ports: std.StringHashMapUnmanaged(*eg.ElkPort) = .empty,

    fn transformNode(self: *Importer, v: Value, parent: ?*eg.ElkNode) Error!*eg.ElkNode {
        const o = obj(v) orelse return error.InvalidGraph;
        const id = try idOf(self.a, o);
        const n = try eg.createNode(self.a, parent, id);
        try self.nodes.put(self.a, id, n);
        transformProperties(o, &n.opts);
        shapeLayout(o, &n.x, &n.y, &n.width, &n.height);
        if (arr(o, "ports")) |ps| for (ps) |pv| {
            const po = obj(pv) orelse continue;
            const pid = try idOf(self.a, po);
            const p = try eg.createPort(self.a, n, pid);
            try self.ports.put(self.a, pid, p);
            transformProperties(po, &p.opts);
            shapeLayout(po, &p.x, &p.y, &p.width, &p.height);
            try self.transformLabels(po, &p.labels);
        };
        try self.transformLabels(o, &n.labels);
        if (arr(o, "children")) |cs| for (cs) |cv| {
            if (obj(cv) != null) _ = try self.transformNode(cv, n);
        };
        return n;
    }

    fn transformEdges(self: *Importer, v: Value, node: *eg.ElkNode) Error!void {
        const o = obj(v) orelse return;
        if (arr(o, "edges")) |es| for (es) |ev| {
            const eo = obj(ev) orelse return error.InvalidGraph;
            const e = try eg.createEdge(self.a, node, try idOf(self.a, eo));
            if (eo.get("sources") != null or eo.get("targets") != null) {
                if (arr(eo, "sources")) |ss| for (ss) |sv| try eg.addSource(self.a, e, try self.shapeById(sv));
                if (arr(eo, "targets")) |ts| for (ts) |tv| try eg.addTarget(self.a, e, try self.shapeById(tv));
            } else {
                try eg.addSource(self.a, e, try self.primitiveEnd(eo, "source", "sourcePort"));
                try eg.addTarget(self.a, e, try self.primitiveEnd(eo, "target", "targetPort"));
            }
            if (e.sources.items.len == 0 or e.targets.items.len == 0) return error.InvalidGraph;
            transformProperties(eo, &e.opts);
            try self.transformLabels(eo, &e.labels);
            try eg.updateContainment(self.a, e);
        };
        if (arr(o, "children")) |cs| {
            var i: usize = 0;
            for (cs) |cv| {
                if (obj(cv) == null) continue;
                try self.transformEdges(cv, node.children.items[i]);
                i += 1;
            }
        }
    }

    fn primitiveEnd(self: *Importer, o: std.json.ObjectMap, nkey: []const u8, pkey: []const u8) Error!eg.Shape {
        const nid = try idString(self.a, o.get(nkey) orelse return error.InvalidGraph);
        const n = self.nodes.get(nid) orelse return error.InvalidGraph;
        if (o.get(pkey)) |pv| {
            if (pv != .null) {
                if (self.ports.get(try idString(self.a, pv))) |p| {
                    if (p.parent != n) return error.InvalidGraph;
                    return .{ .port = p };
                }
            }
        }
        return .{ .node = n };
    }

    fn shapeById(self: *Importer, v: Value) Error!eg.Shape {
        const id = try idString(self.a, v);
        if (self.nodes.get(id)) |n| return .{ .node = n };
        if (self.ports.get(id)) |p| return .{ .port = p };
        return error.InvalidGraph;
    }

    fn transformLabels(self: *Importer, o: std.json.ObjectMap, list: *std.ArrayList(*eg.ElkLabel)) Error!void {
        const ls = arr(o, "labels") orelse return;
        for (ls) |lv| {
            const lo = obj(lv) orelse continue;
            const text = if (lo.get("text")) |t| try stringVal(self.a, t) else "";
            const l = try eg.createLabel(self.a, list, text);
            transformProperties(lo, &l.opts);
            shapeLayout(lo, &l.x, &l.y, &l.width, &l.height);
        }
    }
};

fn obj(v: Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}

fn arr(o: std.json.ObjectMap, key: []const u8) ?[]Value {
    const v = o.get(key) orelse return null;
    return if (v == .array) v.array.items else null;
}

fn idOf(a: Allocator, o: std.json.ObjectMap) Error![]const u8 {
    return idString(a, o.get("id") orelse return error.InvalidGraph);
}

// JsonAdapter.asId: a string or an integral number
fn idString(a: Allocator, v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| if (@floor(f) == f and std.math.isFinite(f)) try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(f))}) else error.InvalidGraph,
        else => error.InvalidGraph,
    };
}

fn stringVal(a: Allocator, v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        else => "null",
    };
}

fn transformProperties(o: std.json.ObjectMap, opts: *eg.Options) void {
    const lo = o.get("layoutOptions") orelse o.get("properties") orelse return;
    if (lo != .object) return;
    var it = lo.object.iterator();
    var buf: [64]u8 = undefined;
    while (it.next()) |kv| {
        const s: []const u8 = switch (kv.value_ptr.*) {
            .string => |s| s,
            .integer => |i| std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue,
            .float => |f| std.fmt.bufPrint(&buf, "{d}", .{f}) catch continue,
            .number_string => |s| s,
            .bool => |b| if (b) "true" else "false",
            else => continue,
        };
        eg.setOption(opts, kv.key_ptr.*, s);
    }
}

// JsonImporter.transformShapeLayout: missing, infinite or NaN values become 0
fn shapeLayout(o: std.json.ObjectMap, x: *f64, y: *f64, w: *f64, h: *f64) void {
    x.* = num(o, "x");
    y.* = num(o, "y");
    w.* = num(o, "width");
    h.* = num(o, "height");
}

fn num(o: std.json.ObjectMap, key: []const u8) f64 {
    const v = o.get(key) orelse return 0;
    const d: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
    return if (std.math.isFinite(d)) d else 0;
}

// Writes the laid out graph in the shape of the fixtures' `output` (JsonImporter.transferLayout, filtered to the
// fields elkjs returns that Mermaid reads).
pub fn write(a: Allocator, root: *const eg.ElkNode) Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    writeNode(&s, root, true) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

fn writeNum(s: *std.json.Stringify, key: []const u8, v: f64) std.Io.Writer.Error!void {
    try s.objectField(key);
    try s.print("{d}", .{v});
}

fn writeNode(s: *std.json.Stringify, n: *const eg.ElkNode, is_root: bool) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(n.id);
    if (is_root) {
        try writeNum(s, "width", n.width);
        try writeNum(s, "height", n.height);
        try writeNum(s, "x", n.x);
        try writeNum(s, "y", n.y);
    } else {
        try writeNum(s, "x", n.x);
        try writeNum(s, "y", n.y);
        try writeNum(s, "width", n.width);
        try writeNum(s, "height", n.height);
        if (n.labels.items.len > 0) try writeLabels(s, n.labels.items);
    }
    if (is_root or n.children.items.len > 0) {
        try s.objectField("children");
        try s.beginArray();
        for (n.children.items) |c| try writeNode(s, c, false);
        try s.endArray();
    }
    if (is_root or n.declared_edges.items.len > 0) {
        try s.objectField("edges");
        try s.beginArray();
        for (n.declared_edges.items) |e| try writeEdge(s, e);
        try s.endArray();
    }
    try s.endObject();
}

fn writeLabels(s: *std.json.Stringify, ls: []const *eg.ElkLabel) std.Io.Writer.Error!void {
    try s.objectField("labels");
    try s.beginArray();
    for (ls) |l| {
        try s.beginObject();
        try writeNum(s, "x", l.x);
        try writeNum(s, "y", l.y);
        try writeNum(s, "width", l.width);
        try writeNum(s, "height", l.height);
        try s.endObject();
    }
    try s.endArray();
}

fn writePoint(s: *std.json.Stringify, p: @import("lgraph.zig").Vec) std.Io.Writer.Error!void {
    try s.beginObject();
    try writeNum(s, "x", p.x);
    try writeNum(s, "y", p.y);
    try s.endObject();
}

fn writeShapeId(s: *std.json.Stringify, sh: eg.Shape) std.Io.Writer.Error!void {
    try s.write(switch (sh) {
        .node => |n| n.id,
        .port => |p| p.id,
    });
}

fn writeEdge(s: *std.json.Stringify, e: *const eg.ElkEdge) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(e.id);
    try s.objectField("sources");
    try s.beginArray();
    for (e.sources.items) |sh| try writeShapeId(s, sh);
    try s.endArray();
    try s.objectField("targets");
    try s.beginArray();
    for (e.targets.items) |sh| try writeShapeId(s, sh);
    try s.endArray();
    try s.objectField("sections");
    try s.beginArray();
    for (e.sections.items) |sec| {
        try s.beginObject();
        try s.objectField("startPoint");
        try writePoint(s, sec.start);
        try s.objectField("endPoint");
        try writePoint(s, sec.end);
        if (sec.bend_points.items.len > 0) {
            try s.objectField("bendPoints");
            try s.beginArray();
            for (sec.bend_points.items) |p| try writePoint(s, p);
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    try writeLabels(s, e.labels.items);
    try s.endObject();
}

test "parse and write a nested graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\{"id":"root","layoutOptions":{"elk.direction":"DOWN","spacing.baseValue":40},
        \\ "children":[{"id":"A","layoutOptions":{"elk.padding":"[top=24,left=24,bottom=24,right=24]"},
        \\   "labels":[{"text":"A","width":9.5,"height":22}],
        \\   "children":[{"id":"a1","width":152,"height":48},{"id":"a2","width":152,"height":48}]},
        \\  {"id":"top","width":152,"height":48}],
        \\ "edges":[{"id":"e1","sources":["a1"],"targets":["a2"],"labels":[{"text":"","width":0,"height":0,
        \\   "layoutOptions":{"edgeLabels.inline":"true"}}]},{"id":"e2","sources":["top"],"targets":["a1"]}]}
    ;
    const root = try parse(a, src);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    const A = root.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), A.contained_edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), root.contained_edges.items.len);
    try std.testing.expectEqual(@as(usize, 2), root.declared_edges.items.len);
    try std.testing.expectEqual(true, root.declared_edges.items[0].labels.items[0].opts.edge_labels_inline.?);
    try std.testing.expectEqual(@as(f64, 40), root.opts.spacing_base_value.?);
    const out = try write(a, root);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"a2\"") != null);
}
