const std = @import("std");
const elk_json = @import("../elk_json.zig");
const recursive = @import("../recursive_layout.zig");
const t = @import("../test.zig");
const Value = std.json.Value;

// Runs every testdata/mermaid/elk/<prefix>*.json fixture through the layout and compares it with the elkjs output.
pub fn check(prefix: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata/mermaid/elk", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try std.testing.expect(names.items.len >= 80);

    var stats: t.Stats = .{};
    for (names.items) |name| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try dir.readFileAlloc(io, name, a, .unlimited);
        const doc = try std.json.parseFromSliceLeaky(Value, a, src, .{});
        const root = try elk_json.fromValue(a, t.field(doc, "input").?);
        stats.graphs += 1;
        var c: t.Cmp = .{ .a = a, .name = name, .stats = &stats, .expected_edges = std.StringHashMap(Value).init(a) };
        recursive.layout(a, root) catch |err| {
            std.debug.print("  {s}: layout failed: {s}\n", .{ name, @errorName(err) });
            stats.failed += 1;
            continue;
        };
        const out = t.field(doc, "output").?;
        try c.collectEdges(out);
        c.nodes(root, out);
        if (c.errors > 0) {
            stats.failed += 1;
            std.debug.print("  {s}: {d} mismatches\n", .{ name, c.errors });
        }
    }
    std.debug.print("\n{s} parity: graphs={d} failed={d} nodes={d} edges={d} points={d} labels={d} maxNode={d:.4} maxPoint={d:.4} maxLabel={d:.4}\n", .{ prefix, stats.graphs, stats.failed, stats.nodes, stats.edges, stats.points, stats.labels, stats.max_node, stats.max_point, stats.max_label });
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
}
