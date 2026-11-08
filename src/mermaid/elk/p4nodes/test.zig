const std = @import("std");
const spacings = @import("../spacings.zig");
const placer = @import("bk/bk_node_placer.zig");
const aligner = @import("bk/bk_aligner.zig");
const compactor = @import("bk/bk_compactor.zig");
const layout = @import("bk/bk_aligned_layout.zig");
const threshold = @import("bk/threshold_strategy.zig");
const neighborhood = @import("bk/neighborhood_information.zig");
const cellsystem = @import("../nodespacing/cellsystem.zig");
const location = @import("../nodespacing/node_label_location.zig");
const nlsc = @import("../nodespacing/node_label_and_size_calculator.zig");
const transformer = @import("../intermediate/graph_transformer.zig");

test {
    std.testing.refAllDecls(spacings);
    std.testing.refAllDecls(placer);
    std.testing.refAllDecls(aligner);
    std.testing.refAllDecls(aligner.BKAligner);
    std.testing.refAllDecls(compactor);
    std.testing.refAllDecls(compactor.BKCompactor);
    std.testing.refAllDecls(layout.BKAlignedLayout);
    std.testing.refAllDecls(threshold.ThresholdStrategy);
    std.testing.refAllDecls(neighborhood.NeighborhoodInformation);
    std.testing.refAllDecls(cellsystem.Cell);
    std.testing.refAllDecls(cellsystem.Rect);
    std.testing.refAllDecls(location.NodeLabelLocation);
    std.testing.refAllDecls(nlsc);
    std.testing.refAllDecls(nlsc.Env);
    std.testing.refAllDecls(@import("../nodespacing/node_margin_calculator.zig"));
    std.testing.refAllDecls(@import("../intermediate/innermost_node_margin_calculator.zig"));
    std.testing.refAllDecls(@import("../intermediate/label_and_node_size_processor.zig"));
    std.testing.refAllDecls(transformer.DirectionPreprocessor);
    std.testing.refAllDecls(transformer.DirectionPostprocessor);
}

fn testNode(a: std.mem.Allocator, g: *lg.LGraph, layer: *lg.Layer) !*lg.LNode {
    const n = try lg.LNode.init(a, g);
    n.size = .{ .x = 10, .y = 10 };
    try n.setLayer(layer);
    return n;
}

fn testPort(a: std.mem.Allocator, n: *lg.LNode, side: lg.PortSide) !*lg.LPort {
    const p = try lg.LPort.init(a);
    try p.setNode(n);
    p.setSide(side);
    return p;
}

const lg = @import("../lgraph.zig");

test "bk places a straight chain on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    g.p.bk_fixed_alignment = .balanced;
    var prev: ?*lg.LPort = null;
    var nodes: [3]*lg.LNode = undefined;
    for (&nodes) |*slot| {
        const layer = try g.newLayer();
        try g.layers.append(a, layer);
        const n = try testNode(a, g, layer);
        const in = try testPort(a, n, .west);
        in.pos.y = 5;
        const out = try testPort(a, n, .east);
        out.pos = .{ .x = 10, .y = 5 };
        if (prev) |p| {
            const e = try lg.LEdge.init(a);
            try e.setSource(p);
            try e.setTarget(in);
        }
        prev = out;
        slot.* = n;
    }
    try placer.process(g);
    for (nodes) |n| try std.testing.expectEqual(@as(f64, 0), n.pos.y);
}

test "justified east ports inside the surrounding margins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    g.p.spacing.ports_surrounding = .{ .top = 12, .left = 12, .bottom = 12, .right = 12 };
    const layer = try g.newLayer();
    try g.layers.append(a, layer);
    const n = try testNode(a, g, layer);
    n.size = .{ .x = 100, .y = 40 };
    n.p.port_constraints = .fixed_order;
    const p1 = try testPort(a, n, .east);
    const p2 = try testPort(a, n, .east);
    _ = try nlsc.process(a, n, nlsc.Env.ofGraph(g), true);
    try std.testing.expectEqual(@as(f64, 100), p1.pos.x);
    try std.testing.expectEqual(@as(f64, 11), p1.pos.y);
    try std.testing.expectEqual(@as(f64, 29), p2.pos.y);
}

test "subgraph label is centered at the top" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    const layer = try g.newLayer();
    try g.layers.append(a, layer);
    const n = try testNode(a, g, layer);
    n.size = .{ .x = 200, .y = 100 };
    n.p.node_labels_placement = .{ .h_center = true, .v_top = true, .inside = true };
    const label = try lg.LLabel.init(a);
    label.size = .{ .x = 40, .y = 22 };
    try n.labels.append(a, label);
    _ = try nlsc.process(a, n, nlsc.Env.ofGraph(g), true);
    try std.testing.expectEqual(@as(f64, 80), label.pos.x);
    try std.testing.expectEqual(@as(f64, 5), label.pos.y);
}
