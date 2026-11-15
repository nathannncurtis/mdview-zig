const std = @import("std");
const elk_test = @import("../test.zig");
const elk_json = @import("../elk_json.zig");
const layered = @import("../layered.zig");
const Value = std.json.Value;

test {
    std.testing.refAllDecls(@import("spore.zig"));
    std.testing.refAllDecls(@import("fuzz.zig"));
}

test "sporeOverlap matches elkjs on the fixtures" {
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
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "spore-") or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try std.testing.expect(names.items.len >= 80);

    var stats: elk_test.Stats = .{};
    for (names.items) |name| {
        if (only) |o| if (std.mem.find(u8, name, o) == null) continue;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try dir.readFileAlloc(io, name, a, .unlimited);
        const doc = try std.json.parseFromSliceLeaky(Value, a, src, .{});
        const root = try elk_json.fromValue(a, elk_test.field(doc, "input").?);
        stats.graphs += 1;
        var c: elk_test.Cmp = .{ .a = a, .name = name, .stats = &stats, .expected_edges = std.StringHashMap(Value).init(a) };
        layered.layout(a, root) catch |err| {
            std.debug.print("  {s}: layout failed: {s}\n", .{ name, @errorName(err) });
            stats.failed += 1;
            continue;
        };
        try c.collectEdges(elk_test.field(doc, "output").?);
        c.nodes(root, elk_test.field(doc, "output").?);
        if (c.errors > 0) {
            stats.failed += 1;
            std.debug.print("  {s}: {d} mismatches\n", .{ name, c.errors });
        }
    }
    std.debug.print("\nspore parity: graphs={d} failed={d} nodes={d} edges={d} points={d} labels={d} maxNode={d:.4} maxPoint={d:.4} maxLabel={d:.4}\n", .{ stats.graphs, stats.failed, stats.nodes, stats.edges, stats.points, stats.labels, stats.max_node, stats.max_point, stats.max_label });
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
}
