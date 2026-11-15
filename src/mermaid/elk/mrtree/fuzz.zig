const std = @import("std");
const eg = @import("../elk_graph.zig");
const mrtree = @import("mrtree.zig");

const max_input = 512;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

pub const corpus = [_][]const u8{
    seed("\x05\x00\x00\x00\x00\x00\x00\x10\x00\x01\x01\x02\x02\x03\x03\x04\x00\x04"),
    seed("\x0c\x01\x01\x01\x01\x01\x01\x02\x03\x20\x00\x01\x01\x02\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x00\x0b"),
    seed("\x18\x02\x02\x00\x00\x01\x01\x28\x00\x01\x00\x01\x00\x02\x01\x02\x03\x03\x04\x04\x05\x05\x06\x06\x07\x07\x08"),
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(self: *Reader) u8 {
        if (self.bytes.len == 0) return 0;
        const b = self.bytes[self.pos % self.bytes.len];
        self.pos += 1;
        return b;
    }
};

pub fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Reader = .{ .bytes = input };

    const root = try eg.createNode(a, null, "root");
    root.opts.algorithm = "mrtree";
    root.opts.direction = switch (r.next() % 5) {
        0 => .down,
        1 => .up,
        2 => .left,
        3 => .right,
        else => null,
    };
    root.opts.mrtree_weighting = switch (r.next() % 4) {
        0 => .model_order,
        1 => .descendants,
        2 => .fan,
        else => .constraint,
    };
    root.opts.mrtree_search_order = if (r.next() % 2 == 0) .dfs else .bfs;
    root.opts.mrtree_edge_routing_mode = if (r.next() % 3 == 0) .middle_to_middle else .avoid_overlap;
    root.opts.separate_connected_components = r.next() % 4 != 0;

    const n: usize = 1 + r.next() % 24;
    const nodes = try a.alloc(*eg.ElkNode, n);
    for (nodes, 0..) |*slot, i| {
        const nd = try eg.createNode(a, root, try std.fmt.allocPrint(a, "n{d}", .{i}));
        nd.width = 1 + @as(f64, @floatFromInt(r.next() % 120));
        nd.height = 1 + @as(f64, @floatFromInt(r.next() % 60));
        const c = r.next();
        if (c % 5 == 0) nd.opts.mrtree_position_constraint = c % 7;
        slot.* = nd;
    }
    const m: usize = r.next() % 40;
    for (0..m) |k| {
        const s: usize = r.next() % n;
        const t: usize = r.next() % n;
        _ = try eg.connect(a, root, try std.fmt.allocPrint(a, "e{d}", .{k}), nodes[s], nodes[t]);
    }

    mrtree.layout(a, root) catch return;
    for (nodes) |nd| {
        try std.testing.expect(std.math.isFinite(nd.x) and std.math.isFinite(nd.y));
    }
    try std.testing.expect(std.math.isFinite(root.width) and std.math.isFinite(root.height));
    for (root.declared_edges.items) |e| for (e.sections.items) |sec| {
        try std.testing.expect(std.math.isFinite(sec.start.x) and std.math.isFinite(sec.start.y));
        try std.testing.expect(std.math.isFinite(sec.end.x) and std.math.isFinite(sec.end.y));
        for (sec.bend_points.items) |p| try std.testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
    };
}
