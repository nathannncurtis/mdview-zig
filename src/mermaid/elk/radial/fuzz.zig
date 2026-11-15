const std = @import("std");
const eg = @import("../elk_graph.zig");
const radial = @import("radial.zig");

const max_input = 1024;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

pub const corpus = [_][]const u8{
    seed("\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
    seed("\x10\x03\x07\x01\x02\x01\x03\x02\x01\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"),
    seed("\x18\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"),
    seed("\x0c\x06\x03\x02\x05\x01\x02\x03\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01"),
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

    const n: usize = 1 + r.next() % 24;
    const root = try eg.createNode(a, null, "root");
    const nodes = try a.alloc(*eg.ElkNode, n);
    for (nodes, 0..) |*slot, i| {
        const nd = try eg.createNode(a, root, try std.fmt.allocPrint(a, "n{d}", .{i}));
        nd.width = 1 + @as(f64, @floatFromInt(r.next() % 120));
        nd.height = 1 + @as(f64, @floatFromInt(r.next() % 60));
        nd.opts.radial_order_id = r.next() % 8;
        slot.* = nd;
    }

    const shape = r.next();
    var k: usize = 0;
    for (1..n) |i| {
        const parent = if (shape % 4 == 0) i - 1 else r.next() % i;
        _ = try eg.connect(a, root, try std.fmt.allocPrint(a, "e{d}", .{k}), nodes[parent], nodes[i]);
        k += 1;
    }
    for (0..r.next() % 3) |_| {
        const s: usize = r.next() % n;
        const t: usize = r.next() % n;
        _ = try eg.connect(a, root, try std.fmt.allocPrint(a, "e{d}", .{k}), nodes[s], nodes[t]);
        k += 1;
    }

    const o = &root.opts;
    o.algorithm = "radial";
    const flags = r.next();
    if (flags & 1 != 0) o.radial_radius = @as(f64, @floatFromInt(r.next() % 120));
    if (flags & 2 != 0) o.radial_center_on_root = true;
    o.radial_compactor = switch (r.next() % 3) {
        0 => .none,
        1 => .radial_compaction,
        else => .wedge_compaction,
    };
    o.radial_compaction_step_size = 1 + r.next() % 5;
    o.radial_sorter = if (flags & 4 != 0) .id else .none;
    o.radial_wedge_criteria = if (flags & 8 != 0) .leaf_number else .node_size;
    o.radial_optimization_criteria = if (flags & 16 != 0) .edge_length else .none;
    if (flags & 32 != 0) {
        o.radial_rotate = true;
        o.radial_rotation_target_angle = @as(f64, @floatFromInt(r.next())) / 40;
    }
    o.radial_rotation_outgoing_edge_angles = flags & 64 != 0;
    o.spacing_node_node = @as(f64, @floatFromInt(r.next() % 50));

    radial.layout(a, root) catch return;
    for (root.children.items) |c| {
        try std.testing.expect(std.math.isFinite(c.x) and std.math.isFinite(c.y));
    }
    try std.testing.expect(std.math.isFinite(root.width) and std.math.isFinite(root.height));
}
