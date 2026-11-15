const std = @import("std");
const eg = @import("../elk_graph.zig");
const spore = @import("spore.zig");

const max_input = 512;
const max_nodes = 24;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

pub const corpus = [_][]const u8{
    seed("\x05\x10\x10\x20\x20\x11\x11\x22\x22\x12\x12\x24\x24\x13\x13\x26\x26\x14\x14\x28\x28\x00\x01\x01\x02"),
    seed("\x18\x00\x00\x00\x00\x01\x01\x01\x01\x02\x02\x02\x02\x03\x03\x03\x03\x04\x04\x04\x04\x05\x05\x05\x05"),
    seed("\x03\xff\xff\x00\x00\x80\x80\x80\x80\x00\x00\x00\x00\x01\x00\x01\x02"),
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
    root.opts.algorithm = "sporeOverlap";
    if (r.next() % 4 == 0) root.opts.overlap_removal_run_scanline = false;
    if (r.next() % 4 == 0) root.opts.overlap_removal_max_iterations = 1 + r.next() % 6;
    if (r.next() % 4 == 0) root.opts.spacing_node_node = @floatFromInt(r.next() % 40);
    const n: usize = 1 + r.next() % max_nodes;
    const nodes = try a.alloc(*eg.ElkNode, n);
    for (nodes, 0..) |*nd, i| {
        nd.* = try eg.createNode(a, root, try std.fmt.allocPrint(a, "n{d}", .{i}));
        nd.*.width = 1 + @as(f64, @floatFromInt(r.next() % 120));
        nd.*.height = 1 + @as(f64, @floatFromInt(r.next() % 80));
        nd.*.x = @as(f64, @floatFromInt(r.next())) / 3.0;
        nd.*.y = @as(f64, @floatFromInt(r.next())) / 3.0;
    }
    const m: usize = r.next() % 40;
    for (0..m) |k| {
        _ = try eg.connect(a, root, try std.fmt.allocPrint(a, "e{d}", .{k}), nodes[r.next() % n], nodes[r.next() % n]);
    }

    spore.layout(a, root) catch return;
    try std.testing.expect(std.math.isFinite(root.width) and std.math.isFinite(root.height));
    for (nodes) |nd| try std.testing.expect(std.math.isFinite(nd.x) and std.math.isFinite(nd.y));
    for (root.contained_edges.items) |e| for (e.sections.items) |s| {
        try std.testing.expect(std.math.isFinite(s.start.x) and std.math.isFinite(s.end.y));
    };
}
