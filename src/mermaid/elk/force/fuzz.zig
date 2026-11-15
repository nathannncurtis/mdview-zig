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
    const root = try build(a, input);
    force.layout(a, root) catch return;
    try checkFinite(root);
}

pub fn build(a: std.mem.Allocator, input: []const u8) anyerror!*eg.ElkNode {
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

    return root;
}

pub fn checkFinite(root: *eg.ElkNode) !void {
    for (root.children.items) |nd| {
        try std.testing.expect(std.math.isFinite(nd.x) and std.math.isFinite(nd.y));
    }
    try std.testing.expect(std.math.isFinite(root.width) and std.math.isFinite(root.height));
    for (root.declared_edges.items) |e| for (e.sections.items) |s| {
        try std.testing.expect(std.math.isFinite(s.start.x) and std.math.isFinite(s.end.y));
        for (s.bend_points.items) |p| try std.testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
    };
}

// A CI fuzz input: eades model, two nodes and 34 edges; the positions diverge to NaN and elkjs does not return.
const diverging_input = "489ee9a5830fc19801269a1feb4ab41d87c80d4c8f7e1be1307fe72b592f8911e2cae83ebb1332c81b3c504a5971deb6e838649a3ef4651981098ce6beb390bca5c60a997547afa63386506574cbafbdf08c475b3c97576e3960760defa2c0b76eaaacaf49ad0948288882012a3fc331edce903b265f98a0dea445ff6aa25dffd5f4e94cf1b99962459465510f9d190d7058bd449d19ef198117295d20191e65cefbec8d86d8a8f8ec5bbbadb61b82d6d2031c7a9c6d5a5f54ae0daaffd4873d6adc2349870f65d43181477d55761dc9e0993a7989a95ce231bb79e3a2dd7297e18975d013f193a2dc12cc395638e3fd434c50770cf4dcc88c9f1eef6d648d6cb2d8b2a6c0c5de9a8b27040517505517d67d4ca43424c259c282ed371cc6438e8d59425cdf124634ed80eab10024e3d94d67deaa8bbf4c2a1206017039481253219b21a4d68e52ae8bf2d4e40663a2ea9b316edb8875faa50f81ce9d78e2d67a72644b67c21d20cec303d355ae757a4152893c6a360c214ff27a57126c7199d1e3a2944503afdd85c88ec0ee2b20ec8630f51391214c3e29c1d120c04e8a3925ea7def3b29388e34b6332f647164f3751040bdc04c5ba82ac105506b00049ffd659a5987c33d9ff82cb163e9ebd33e130ade85d3e9fbf8413959d1d95083955cb3c4a712a853213e423f819bea5481af702525cc1a62533a38d634b6617079b0a800169e26eb674b8b95b5813342a2558663f670c4c2630b034dbb03ec8eebc1bca921ebe225b398d7c85958f01f10147c8af9a3b4b0db7af1b72eea36e1c75923208b676adfe21e790fbba7d61e29aaee43214a8e81ac2b899ea70df65f3ec0857e6d289a3d3570";

test "a diverging eades layout reports an error instead of NaN positions" {
    var bytes: [diverging_input.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, diverging_input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try build(a, &bytes);
    try std.testing.expectError(error.ElkException, force.layout(a, root));
}
