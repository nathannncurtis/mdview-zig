const std = @import("std");
const eg = @import("elk_graph.zig");
const elk_json = @import("elk_json.zig");
const layered = @import("layered.zig");
const Value = std.json.Value;

test {
    _ = @import("p1cycles/test.zig");
    _ = @import("p3order/test.zig");
    _ = @import("p4nodes/test.zig");
    _ = @import("p5edges/test.zig");
    _ = @import("graph/test.zig");
}

const node_tol = 0.5;
const point_tol = 1.0;

const Stats = struct {
    graphs: usize = 0,
    failed: usize = 0,
    nodes: usize = 0,
    edges: usize = 0,
    points: usize = 0,
    labels: usize = 0,
    max_node: f64 = 0,
    max_point: f64 = 0,
    max_label: f64 = 0,
};

fn num(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

fn field(v: Value, name: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(name);
}

const Cmp = struct {
    a: std.mem.Allocator,
    name: []const u8,
    stats: *Stats,
    expected_edges: std.StringHashMap(Value),
    errors: usize = 0,

    fn report(self: *Cmp, comptime fmt: []const u8, args: anytype) void {
        self.errors += 1;
        if (self.errors <= 4) std.debug.print("  {s}: " ++ fmt ++ "\n", .{self.name} ++ args);
    }

    fn collectEdges(self: *Cmp, out: Value) !void {
        if (field(out, "edges")) |es| for (es.array.items) |e| {
            try self.expected_edges.put(field(e, "id").?.string, e);
        };
        if (field(out, "children")) |cs| for (cs.array.items) |c| try self.collectEdges(c);
    }

    fn nodes(self: *Cmp, got: *const eg.ElkNode, want: Value) void {
        self.stats.nodes += 1;
        const wx = num(field(want, "x") orelse .null);
        const wy = num(field(want, "y") orelse .null);
        const ww = num(field(want, "width") orelse .null);
        const wh = num(field(want, "height") orelse .null);
        const d = @max(@max(@abs(got.x - wx), @abs(got.y - wy)), @max(@abs(got.width - ww), @abs(got.height - wh)));
        self.stats.max_node = @max(self.stats.max_node, d);
        if (!(d <= node_tol)) self.report("node {s}: got {d:.3},{d:.3} {d:.3}x{d:.3} want {d:.3},{d:.3} {d:.3}x{d:.3}", .{ got.id, got.x, got.y, got.width, got.height, wx, wy, ww, wh });
        if (field(want, "labels")) |wls| for (wls.array.items, 0..) |wl, i| {
            if (i >= got.labels.items.len) break;
            const gl = got.labels.items[i];
            const ld = @max(@abs(gl.x - num(field(wl, "x").?)), @abs(gl.y - num(field(wl, "y").?)));
            self.stats.labels += 1;
            self.stats.max_label = @max(self.stats.max_label, ld);
            if (!(ld <= point_tol)) self.report("node label of {s}: got {d:.3},{d:.3} want {d:.3},{d:.3}", .{ got.id, gl.x, gl.y, num(field(wl, "x").?), num(field(wl, "y").?) });
        };
        if (field(want, "children")) |wcs| {
            if (wcs.array.items.len != got.children.items.len) {
                self.report("node {s}: {d} children, want {d}", .{ got.id, got.children.items.len, wcs.array.items.len });
                return;
            }
            for (got.children.items, wcs.array.items) |gc, wc| {
                if (!std.mem.eql(u8, gc.id, field(wc, "id").?.string)) {
                    self.report("child order under {s}: {s} vs {s}", .{ got.id, gc.id, field(wc, "id").?.string });
                    return;
                }
                self.nodes(gc, wc);
            }
        }
        for (got.declared_edges.items) |e| self.edge(e);
    }

    fn edge(self: *Cmp, e: *const eg.ElkEdge) void {
        self.stats.edges += 1;
        const want = self.expected_edges.get(e.id) orelse {
            self.report("edge {s} not in output", .{e.id});
            return;
        };
        const wsecs = (field(want, "sections") orelse return).array.items;
        if (wsecs.len != e.sections.items.len) {
            self.report("edge {s}: {d} sections, want {d}", .{ e.id, e.sections.items.len, wsecs.len });
            return;
        }
        for (e.sections.items, wsecs) |gs, ws| {
            const wb = if (field(ws, "bendPoints")) |b| b.array.items else &[_]Value{};
            if (wb.len != gs.bend_points.items.len) {
                self.report("edge {s}: {d} bend points, want {d}", .{ e.id, gs.bend_points.items.len, wb.len });
                continue;
            }
            const sp = field(ws, "startPoint").?;
            const ep = field(ws, "endPoint").?;
            self.point(e.id, gs.start.x, gs.start.y, num(field(sp, "x").?), num(field(sp, "y").?));
            self.point(e.id, gs.end.x, gs.end.y, num(field(ep, "x").?), num(field(ep, "y").?));
            for (gs.bend_points.items, wb) |gp, wp| self.point(e.id, gp.x, gp.y, num(field(wp, "x").?), num(field(wp, "y").?));
        }
        if (field(want, "labels")) |wls| for (wls.array.items, 0..) |wl, i| {
            if (i >= e.labels.items.len) break;
            const gl = e.labels.items[i];
            const ld = @max(@abs(gl.x - num(field(wl, "x").?)), @abs(gl.y - num(field(wl, "y").?)));
            self.stats.labels += 1;
            self.stats.max_label = @max(self.stats.max_label, ld);
            if (!(ld <= point_tol)) self.report("edge label of {s}: got {d:.3},{d:.3} want {d:.3},{d:.3}", .{ e.id, gl.x, gl.y, num(field(wl, "x").?), num(field(wl, "y").?) });
        };
    }

    fn point(self: *Cmp, id: []const u8, gx: f64, gy: f64, wx: f64, wy: f64) void {
        self.stats.points += 1;
        const d = @max(@abs(gx - wx), @abs(gy - wy));
        self.stats.max_point = @max(self.stats.max_point, d);
        if (!(d <= point_tol)) self.report("edge {s} point got {d:.3},{d:.3} want {d:.3},{d:.3}", .{ id, gx, gy, wx, wy });
    }
};

test "elk layout matches elkjs on the fixtures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    const only = env.get("MDVIEW_ELK_ONLY");

    var dir = try std.Io.Dir.cwd().openDir(io, "testdata/mermaid/elk", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try std.testing.expect(names.items.len >= 200);

    var stats: Stats = .{};
    for (names.items) |name| {
        if (only) |o| if (std.mem.find(u8, name, o) == null) continue;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try dir.readFileAlloc(io, name, a, .unlimited);
        const doc = try std.json.parseFromSliceLeaky(Value, a, src, .{});
        const root = try elk_json.fromValue(a, field(doc, "input").?);
        stats.graphs += 1;
        var c: Cmp = .{ .a = a, .name = name, .stats = &stats, .expected_edges = std.StringHashMap(Value).init(a) };
        const out = field(doc, "output").?;
        layered.layout(a, root) catch |err| {
            std.debug.print("  {s}: layout failed: {s}\n", .{ name, @errorName(err) });
            stats.failed += 1;
            continue;
        };
        try c.collectEdges(out);
        c.nodes(root, out);
        if (c.errors > 0) {
            stats.failed += 1;
            std.debug.print("  {s}: {d} mismatches\n", .{ name, c.errors });
        }
    }
    std.debug.print("\nelk parity: graphs={d} failed={d} nodes={d} edges={d} points={d} labels={d} maxNode={d:.4} maxPoint={d:.4} maxLabel={d:.4}\n", .{ stats.graphs, stats.failed, stats.nodes, stats.edges, stats.points, stats.labels, stats.max_node, stats.max_point, stats.max_label });
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
}
