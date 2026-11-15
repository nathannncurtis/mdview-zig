const std = @import("std");
const lg = @import("lgraph.zig");
const eg = @import("elk_graph.zig");
const layered = @import("layered.zig");
const pre = @import("intermediate/layer_constraint_preprocessor.zig");
const post = @import("intermediate/layer_constraint_postprocessor.zig");

fn linkedPair(a: std.mem.Allocator, g: *lg.LGraph) lg.Error![2]*lg.LNode {
    // SAFETY: both elements are written by the loop below
    var nodes: [2]*lg.LNode = undefined;
    for (&nodes) |*n| {
        n.* = try lg.LNode.init(a, g);
        try g.layerless_nodes.append(a, n.*);
    }
    nodes[0].p.origin_id = "A";
    nodes[1].p.origin_id = "B";
    const out = try lg.LPort.init(a);
    try out.setNode(nodes[0]);
    const in = try lg.LPort.init(a);
    try in.setNode(nodes[1]);
    const e = try lg.LEdge.init(a);
    try e.setSource(out);
    try e.setTarget(in);
    return nodes;
}

test "FIRST node with an incoming edge throws the layer constraint message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    const nodes = try linkedPair(a, g);
    nodes[1].p.layer_constraint = .first;
    const layer = try g.newLayer();
    try nodes[0].setLayer(layer);
    try nodes[1].setLayer(layer);
    try std.testing.expectError(error.ElkException, post.process(g));
    try std.testing.expectEqualStrings("Node 'B' has its layer constraint set to FIRST, but has at least one incoming edge that  does not come from a FIRST_SEPARATE node. That must not happen.", lg.elkMessage());
}

test "LAST node with an outgoing edge throws the layer constraint message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    const nodes = try linkedPair(a, g);
    nodes[0].p.layer_constraint = .last;
    const layer = try g.newLayer();
    try nodes[0].setLayer(layer);
    try nodes[1].setLayer(layer);
    try std.testing.expectError(error.ElkException, post.process(g));
    try std.testing.expectEqualStrings("Node 'A' has its layer constraint set to LAST, but has at least one outgoing edge that  does not go to a LAST_SEPARATE node. That must not happen.", lg.elkMessage());
}

test "FIRST_SEPARATE node with an incoming edge throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    const nodes = try linkedPair(a, g);
    nodes[1].p.layer_constraint = .first_separate;
    try std.testing.expectError(error.ElkException, pre.process(g));
    try std.testing.expectEqualStrings("Node 'B' has its layer constraint set to FIRST_SEPARATE, but has at least one incoming edge. FIRST_SEPARATE nodes must not have incoming edges.", lg.elkMessage());
}

test "LAST_SEPARATE node with an outgoing edge throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    const nodes = try linkedPair(a, g);
    nodes[0].p.layer_constraint = .last_separate;
    try std.testing.expectError(error.ElkException, pre.process(g));
    try std.testing.expectEqualStrings("Node 'A' has its layer constraint set to LAST_SEPARATE, but has at least one outgoing edge. LAST_SEPARATE nodes must not have outgoing edges.", lg.elkMessage());
}

test "an edge to a node that is not laid out throws UnsupportedGraphException" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try eg.createNode(a, null, "root");
    const n1 = try eg.createNode(a, root, "n1");
    const n2 = try eg.createNode(a, root, "n2");
    n1.width = 10;
    n1.height = 10;
    n2.width = 10;
    n2.height = 10;
    n2.opts.no_layout = true;
    _ = try eg.connect(a, root, "e1", n1, n2);
    try std.testing.expectError(error.ElkException, layered.layout(a, root));
    try std.testing.expect(std.mem.startsWith(u8, lg.elkMessage(), "The source or the target of edge "));
    try std.testing.expect(std.mem.endsWith(u8, lg.elkMessage(), "option to INCLUDE_CHILDREN."));
}
