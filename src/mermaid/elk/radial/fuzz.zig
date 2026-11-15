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
    const root = try build(a, input);
    radial.layout(a, root) catch return;
    try checkFinite(root);
}

pub fn build(a: std.mem.Allocator, input: []const u8) anyerror!*eg.ElkNode {
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

    return root;
}

// elkjs returns NaN for some radial inputs too (the same ones: radial fixture 038 expects it), so only infinities and a
// crash count as failures.
pub fn checkFinite(root: *eg.ElkNode) !void {
    for (root.children.items) |c| {
        try std.testing.expect(!std.math.isInf(c.x) and !std.math.isInf(c.y));
    }
    try std.testing.expect(!std.math.isInf(root.width) and !std.math.isInf(root.height));
}

// A CI fuzz input whose radial layout is NaN in elkjs as well.
const nan_input = "cbcb42d0c74a2573e424d654b38527c6007ec1dd107c5071bac2ed692404e14ab908b23158b7d20e82736882944e1a03870143960be629a70aeea87ef42c58c18915e36e12015389074dd2be16f8d3a6919d78b3748c9c0fab5f461c5fafe0a36b1885e446de94d3a68c464c18b09474192d07276d6aef419fef3fb93bee2b37da7b3412a8165dd458ffa69231978864605048a29e669f8183c8cba76c413adb85c35bf5bfccbd6f5ff112f9aa9b895f3f57edef33e353b92ebcd280d02c6d3e131e36e0c75eb1f8f474a1a7f3e068946660d1e8130473c6497092eb1af84248c0fdbe8416917d6baa7c3a1dddcf481b8afd6db7cb1469f2283d2bee2d6ec28605e326fc841e9a4ec566736964575e9120f746b8d05e84e4263ff55cbe3cffcc205a38e954f9044d290917cc7aa0b7809efd57f9efee42b2bb6aab1ed50bcf77ee7af141eb7f996ca40179731206b289159a196239e584fcc1ab9bca69cf0ed1c88f35015e0ed4ae88cb6f7e72e073ee2087e9e06f509a446811de981d10ae875f9e480df61531b8e6accc12a955bb20a637b0a6077e45d99c5664f21c6b92dcc6475d5d7387bde4d5bad015c58704d5ea2f01417821b98af9a6b61b8a96b21ae94045e11bc69a32e78473b99235f1344c1c0a5d1a481600ef5e699af367091c3ccf4ce2d0b96713692f6b9e9ec64c97224b2a757a428c69b8a1d8b78da4f0c7da5487ca32b4e29436f8cd3518c38150de0003c5e6e3249ad75ffc0aca083ae78df36b4aa814c8f30e5761ce5d71204f3f5e863b91e9657c7c3b635e86ad0ade822a0bace43b334ec9be07f38beac5693aa375bbe2df5308f56c06d32a7c90658a25c8aa79646aece4153ae764232a864ef73830725d3aa7be48de36b6d03a882e84328588d28d711cd8ecd78b3bdbc2f3c88e0550e7e377e5eca78fefddf6830bc2c08e0d98f8068e92967d0d26e46ca2cd0da6d532e2492a99cfd1b74ed7fda02b85271231c223c0d85ce58cc9c018c367fb37aff4a179806e6ddea5215351996ed0970d20b7b6e300e8c791c6779286673a5f681f017cdc8e3e6973d1b2dec4a7f0025c655e0ca569fac7cfb4843f71b8b394a54564a82e34cd43a06e4b0507ff930b6258898ef6a209fa8b8de587fe923563b2c2efaa2ba36a7aacc898ce8f632caa791904ba35ed9b5f020e5eed9f3b89937907a38dea8ef1c059113a4833931fe63e97b6d4f3fa937fbfc0a669080f3d9c840679eccff508bfe61e8eddb03a6a8fe44e025a6ca01605eca5946ea4f593389613e4491c2902a0215e493b719aafe15812ff07967b5828658f91d8b2793100aa02776a78841deb6494a2a69b5cab6ac4e67548c2e26e80ebc04e82";

test "a radial layout that is NaN in elkjs is accepted by the fuzz check" {
    var bytes: [nan_input.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, nan_input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try build(a, &bytes);
    try radial.layout(a, root);
    try std.testing.expect(std.math.isNan(root.width));
    try checkFinite(root);
}
