const std = @import("std");
const eg = @import("../elk_graph.zig");
const recursive = @import("../recursive_layout.zig");

const max_input = 512;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

pub const corpus = [_][]const u8{
    seed("\x05\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"),
    seed("\x18\xff\x00\xff\x00\xff\x00\xff\x00\x10\x20\x30\x40\x50\x60\x70\x80"),
    seed("\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *Reader) u8 {
        if (self.bytes.len == 0) return 0;
        const b = self.bytes[self.pos % self.bytes.len];
        self.pos += 1;
        return b;
    }
};

fn setBool(r: *Reader) ?bool {
    return switch (r.next() % 3) {
        0 => null,
        1 => false,
        else => true,
    };
}

// A random flat or two level graph of at most 24 nodes whose parents all use `algorithm`.
pub fn randomGraph(a: std.mem.Allocator, r: *Reader, algorithm: []const u8) !*eg.ElkNode {
    const root = try eg.createNode(a, null, "root");
    root.opts.algorithm = algorithm;
    const n = 1 + r.next() % 24;
    var groups: std.ArrayList(*eg.ElkNode) = .empty;
    for (0..n) |i| {
        var parent = root;
        if (groups.items.len > 0 and r.next() % 3 == 0) parent = groups.items[r.next() % groups.items.len];
        const node = try eg.createNode(a, parent, try std.fmt.allocPrint(a, "n{d}", .{i}));
        node.width = 1 + @as(f64, @floatFromInt(r.next()));
        node.height = 1 + @as(f64, @floatFromInt(r.next()));
        if (parent == root and r.next() % 5 == 0 and i + 1 < n) {
            node.opts.algorithm = algorithm;
            try groups.append(a, node);
        }
        if (r.next() % 4 == 0) node.opts.priority = @as(i32, r.next() % 5) - 2;
        node.opts.rp_in_new_row = if (r.next() % 8 == 0) true else null;
        const pos = r.next();
        node.opts.rp_desired_position = if (pos % 8 == 0) @as(i32, pos / 8 % 8) else null;
    }
    root.opts.padding = if (r.next() % 2 == 0) null else .{ .top = @floatFromInt(r.next() % 40), .left = @floatFromInt(r.next() % 40), .bottom = @floatFromInt(r.next() % 40), .right = @floatFromInt(r.next() % 40) };
    root.opts.spacing_node_node = if (r.next() % 2 == 0) null else @floatFromInt(r.next() % 40);
    root.opts.aspect_ratio = if (r.next() % 2 == 0) null else 0.2 + @as(f64, @floatFromInt(r.next() % 50)) / 10;
    root.opts.expand_nodes = setBool(r);
    root.opts.interactive = setBool(r);
    root.opts.node_size_constraints = if (r.next() % 3 == 0) .{ .minimum_size = true } else null;
    root.opts.node_size_minimum = if (r.next() % 3 == 0) .{ .x = @floatFromInt(r.next()), .y = @floatFromInt(r.next()) } else null;
    for (groups.items) |g| {
        g.opts.padding = root.opts.padding;
        g.opts.expand_nodes = root.opts.expand_nodes;
    }
    return root;
}

pub fn checkFinite(node: *const eg.ElkNode) !void {
    try std.testing.expect(std.math.isFinite(node.x) and std.math.isFinite(node.y));
    try std.testing.expect(std.math.isFinite(node.width) and std.math.isFinite(node.height));
    for (node.children.items) |c| try checkFinite(c);
}

pub fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Reader = .{ .bytes = input };
    const root = try randomGraph(a, &r, "box");
    root.opts.box_packing_mode = switch (r.next() % 4) {
        0 => .simple,
        1 => .group_dec,
        2 => .group_mixed,
        else => .group_inc,
    };
    recursive.layout(a, root) catch return;
    try checkFinite(root);
}
