const std = @import("std");
const eg = @import("../elk_graph.zig");
const elk_fuzz = @import("../fuzz.zig");
const stress = @import("stress.zig");

const max_input = 1024;

fn finite(v: f64) !void {
    try std.testing.expect(std.math.isFinite(v));
}

// Random graphs through the stress layout: bounded in size and iterations, nothing may crash, hang or go NaN.
pub fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: elk_fuzz.Reader = .{ .bytes = input };

    const root = try eg.createNode(a, null, "root");
    // without force there is no random start, so every other graph starts from random positions
    root.opts.interactive = r.next() % 2 == 0;
    root.opts.stress_iteration_limit = r.next() % 40;
    root.opts.stress_epsilon = @as(f64, @floatFromInt(r.next())) / 25500.0;
    root.opts.stress_dimension = switch (r.next() % 3) {
        0 => .xy,
        1 => .x,
        else => .y,
    };
    root.opts.separate_connected_components = r.next() % 4 != 0;
    if (r.next() % 2 == 0) root.opts.stress_desired_edge_length = 1 + @as(f64, @floatFromInt(r.next()));

    const n: usize = 1 + r.next() % 24;
    const nodes = try a.alloc(*eg.ElkNode, n);
    for (nodes, 0..) |*slot, i| {
        const nd = try eg.createNode(a, root, try std.fmt.allocPrint(a, "n{d}", .{i}));
        nd.width = 1 + @as(f64, @floatFromInt(r.next()));
        nd.height = 1 + @as(f64, @floatFromInt(r.next() % 120));
        nd.x = @as(f64, @floatFromInt(r.next())) * 3;
        nd.y = @as(f64, @floatFromInt(r.next())) * 3;
        nd.opts.stress_fixed = r.next() % 8 == 0;
        slot.* = nd;
    }
    const m: usize = r.next() % 40;
    for (0..m) |k| {
        const e = try eg.connect(a, root, try std.fmt.allocPrint(a, "e{d}", .{k}), nodes[r.next() % n], nodes[r.next() % n]);
        if (r.next() % 3 == 0) {
            const l = try eg.createLabel(a, &e.labels, "l");
            l.width = @floatFromInt(r.next() % 60);
            l.height = 24;
        }
        if (r.next() % 5 == 0) e.opts.stress_desired_edge_length = 1 + @as(f64, @floatFromInt(r.next()));
    }

    stress.layout(a, root) catch return;
    try finite(root.width);
    try finite(root.height);
    for (nodes) |nd| {
        try finite(nd.x);
        try finite(nd.y);
    }
    for (root.declared_edges.items) |e| for (e.sections.items) |s| {
        try finite(s.start.x);
        try finite(s.start.y);
        try finite(s.end.x);
        try finite(s.end.y);
    };
    for (root.declared_edges.items) |e| for (e.labels.items) |l| {
        try finite(l.x);
        try finite(l.y);
    };
}
