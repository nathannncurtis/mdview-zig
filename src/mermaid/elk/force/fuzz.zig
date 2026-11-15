const std = @import("std");
const eg = @import("../elk_graph.zig");
const force = @import("force.zig");

const max_input = 1024;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

pub const corpus = [_][]const u8{
    seed("\x05\x00\x01\x02\x03\x04\x03\x00\x01\x01\x02\x02\x03\x03\x04\x00\x04"),
    seed("\x08\x01\x00\x00\x00\x00\x00\x00\x00\x10\x00\x01\x01\x02\x02\x03\x03\x04\x04\x05\x05\x06\x06\x07\x07\x00"),
    seed("\x0c\x02\x01\x00\x03\x01\x02\x02\x01\x00\x05\x01\x00\x20\x00\x01\x01\x02\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x00\x0b"),
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
    const eades = r.next() % 2 == 0;
    const interactive = r.next() % 4 == 0;
    root.opts.force_model = if (eades) .eades else .fruchterman_reingold;
    root.opts.force_iterations = 1 + r.next() % 20;
    root.opts.interactive = interactive;
    root.opts.random_seed = r.next() % 4;
    root.opts.separate_connected_components = r.next() % 4 != 0;
    root.opts.spacing_node_node = 1 + @as(f64, @floatFromInt(r.next()));

    const n: usize = 1 + r.next() % 24;
    const nodes = try a.alloc(*eg.ElkNode, n);
    for (nodes, 0..) |*slot, i| {
        const nd = try eg.createNode(a, root, try std.fmt.allocPrint(a, "n{d}", .{i}));
        nd.width = @floatFromInt(r.next() % 120);
        nd.height = @floatFromInt(r.next() % 80);
        if (interactive) {
            nd.x = @floatFromInt(i * 7);
            nd.y = @floatFromInt(i * 3);
        }
        if (r.next() % 8 == 0) nd.opts.priority = r.next() % 4;
        slot.* = nd;
    }
    const edge_count = r.next() % 40;
    for (0..edge_count) |i| {
        const s = nodes[r.next() % n];
        const t = nodes[r.next() % n];
        const e = try eg.connect(a, root, try std.fmt.allocPrint(a, "e{d}", .{i}), s, t);
        if (r.next() % 4 == 0) {
            const l = try eg.createLabel(a, &e.labels, "l");
            l.width = @floatFromInt(r.next() % 60);
            l.height = @floatFromInt(r.next() % 30);
            if (r.next() % 2 == 0) l.opts.edge_labels_inline = true;
        }
        if (!interactive and r.next() % 8 == 0) e.opts.force_repulsive_power = r.next() % 3;
        if (r.next() % 8 == 0) e.opts.priority = r.next() % 4;
    }

    force.layout(a, root) catch return;
    for (root.children.items) |nd| {
        try std.testing.expect(std.math.isFinite(nd.x) and std.math.isFinite(nd.y));
    }
    try std.testing.expect(std.math.isFinite(root.width) and std.math.isFinite(root.height));
    for (root.declared_edges.items) |e| for (e.sections.items) |s| {
        try std.testing.expect(std.math.isFinite(s.start.x) and std.math.isFinite(s.end.y));
        for (s.bend_points.items) |p| try std.testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
    };
}
