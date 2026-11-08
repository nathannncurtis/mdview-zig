const std = @import("std");
const generator = @import("orthogonal/orthogonal_routing_generator.zig");
const segment = @import("orthogonal/hyper_edge_segment.zig");
const dependency = @import("orthogonal/hyper_edge_segment_dependency.zig");
const strategy = @import("orthogonal/direction/base_routing_direction_strategy.zig");

test {
    std.testing.refAllDecls(@import("orthogonal_edge_router.zig"));
    std.testing.refAllDecls(generator);
    std.testing.refAllDecls(generator.OrthogonalRoutingGenerator);
    std.testing.refAllDecls(segment);
    std.testing.refAllDecls(segment.HyperEdgeSegment);
    std.testing.refAllDecls(dependency);
    std.testing.refAllDecls(dependency.HyperEdgeSegmentDependency);
    std.testing.refAllDecls(@import("orthogonal/hyper_edge_cycle_detector.zig"));
    std.testing.refAllDecls(@import("orthogonal/hyper_edge_segment_splitter.zig"));
    std.testing.refAllDecls(strategy);
    std.testing.refAllDecls(strategy.RoutingStrategy);
    std.testing.refAllDecls(@import("../intermediate/layer_size_and_graph_height_calculator.zig"));
    std.testing.refAllDecls(@import("../intermediate/hierarchical_port_orthogonal_edge_router.zig"));
    std.testing.refAllDecls(@import("../intermediate/hierarchical_port_position_processor.zig"));
    std.testing.refAllDecls(@import("../intermediate/hierarchical_port_dummy_size_processor.zig"));
}

const lg = @import("../lgraph.zig");

fn testNode(a: std.mem.Allocator, g: *lg.LGraph, y: f64, side: lg.PortSide) !*lg.LPort {
    const n = try lg.LNode.init(a, g);
    n.pos = .{ .x = 0, .y = y };
    n.size = .{ .x = 20, .y = 20 };
    const p = try lg.LPort.init(a);
    try p.setNode(n);
    p.setSide(side);
    p.pos = .{ .x = if (side == .east) 20 else 0, .y = 10 };
    return p;
}

test "crossing pair is split around the critical cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    var rnd = lg.JavaRandom.init(1);
    g.p.random = &rnd;
    const pa = try testNode(a, g, 0, .east);
    const pb = try testNode(a, g, 40, .east);
    const pc = try testNode(a, g, 0, .west);
    const pd = try testNode(a, g, 40, .west);
    const ad = try lg.LEdge.init(a);
    try ad.setSource(pa);
    try ad.setTarget(pd);
    const bc = try lg.LEdge.init(a);
    try bc.setSource(pb);
    try bc.setTarget(pc);

    var gen = generator.OrthogonalRoutingGenerator.init(a, .west_to_east, 10);
    const slots = try gen.routeEdges(g, &.{ pa.owner.?, pb.owner.? }, &.{ pc.owner.?, pd.owner.? }, 100);
    try std.testing.expectEqual(@as(i32, 3), slots);
    try std.testing.expectEqualSlices(lg.Vec, &.{ .{ .x = 110, .y = 10 }, .{ .x = 110, .y = 50 } }, ad.bend_points.items);
    try std.testing.expectEqualSlices(lg.Vec, &.{ .{ .x = 100, .y = 50 }, .{ .x = 100, .y = 30 }, .{ .x = 120, .y = 30 }, .{ .x = 120, .y = 10 } }, bc.bend_points.items);
}
