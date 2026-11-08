// HyperedgeDummyMerger. Props: long_edge_source, long_edge_target, long_edge_has_label_dummies,
// long_edge_before_label_dummy (long edge dummies); port ids are overwritten.
const std = @import("std");
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    identifyHyperedges(g);
    for (g.layers.items) |layer| {
        const nodes = &layer.nodes;
        if (nodes.items.len == 0) continue;
        var last_node: ?*lg.LNode = null;
        var last_type: ?lg.NodeType = null;
        var node_index: usize = 0;
        while (node_index < nodes.items.len) : (node_index += 1) {
            var curr_node = nodes.items[node_index];
            var curr_type: ?lg.NodeType = curr_node.type;
            if (curr_type == .long_edge and last_type == .long_edge) {
                const state = checkMergeAllowed(curr_node, last_node.?);
                if (state.allow_merge) {
                    try mergeNodes(curr_node, last_node.?, state.same_source, state.same_target);
                    _ = nodes.orderedRemove(node_index);
                    node_index -= 1;
                    curr_node = last_node.?;
                    curr_type = last_type;
                }
            }
            last_node = curr_node;
            last_type = curr_type;
        }
    }
}

const MergeState = struct { allow_merge: bool, same_source: bool, same_target: bool };

fn checkMergeAllowed(curr: *lg.LNode, last: *lg.LNode) MergeState {
    const curr_has = curr.p.long_edge_has_label_dummies;
    const last_has = last.p.long_edge_has_label_dummies;
    const same_source = curr.p.long_edge_source != null and curr.p.long_edge_source == last.p.long_edge_source;
    const same_target = curr.p.long_edge_target != null and curr.p.long_edge_target == last.p.long_edge_target;
    if (!curr_has and !last_has) {
        return .{ .allow_merge = curr.ports.items[0].id == last.ports.items[0].id, .same_source = same_source, .same_target = same_target };
    }
    const eligible_source = (!curr_has or curr.p.long_edge_before_label_dummy) and (!last_has or last.p.long_edge_before_label_dummy);
    const eligible_target = (!curr_has or !curr.p.long_edge_before_label_dummy) and (!last_has or !last.p.long_edge_before_label_dummy);
    return .{
        .allow_merge = (same_source and eligible_source) or (same_target and eligible_target),
        .same_source = same_source,
        .same_target = same_target,
    };
}

fn firstPortOfSide(node: *lg.LNode, side: lg.PortSide) *lg.LPort {
    for (node.ports.items) |p| if (p.side == side) return p;
    unreachable;
}

fn mergeNodes(merge_source: *lg.LNode, merge_target: *lg.LNode, keep_source_port: bool, keep_target_port: bool) lg.Error!void {
    const target_input = firstPortOfSide(merge_target, .west);
    const target_output = firstPortOfSide(merge_target, .east);
    for (merge_source.ports.items) |port| {
        while (port.incoming.items.len > 0) try port.incoming.items[0].setTarget(target_input);
        while (port.outgoing.items.len > 0) try port.outgoing.items[0].setSource(target_output);
    }
    if (!keep_source_port) merge_target.p.long_edge_source = null;
    if (!keep_target_port) merge_target.p.long_edge_target = null;
}

fn identifyHyperedges(g: *lg.LGraph) void {
    for (g.layers.items) |l| for (l.nodes.items) |n| for (n.ports.items) |p| {
        p.id = -1;
    };
    var index: i32 = 0;
    for (g.layers.items) |l| for (l.nodes.items) |n| for (n.ports.items) |p| {
        if (p.id == -1) {
            dfs(p, index);
            index += 1;
        }
    };
}

fn dfs(p: *lg.LPort, index: i32) void {
    p.id = index;
    for (p.incoming.items) |e| if (e.source.?.id == -1) dfs(e.source.?, index);
    for (p.outgoing.items) |e| if (e.target.?.id == -1) dfs(e.target.?, index);
    if (p.owner.?.type == .long_edge) {
        for (p.owner.?.ports.items) |p2| if (p2 != p and p2.id == -1) dfs(p2, index);
    }
}

test "merges two long edge dummies of one hyperedge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try lg.LGraph.init(a);
    const layer = try g.newLayer();
    const src_port = try lg.LPort.init(a);
    try src_port.setNode(try lg.LNode.init(a, g));
    // SAFETY: every element is written by the loop below
    var dummies: [2]*lg.LNode = undefined;
    for (&dummies) |*d| {
        d.* = try lg.LNode.init(a, g);
        d.*.type = .long_edge;
        try d.*.setLayer(layer);
        const in = try lg.LPort.init(a);
        try in.setNode(d.*);
        in.setSide(.west);
        const out = try lg.LPort.init(a);
        try out.setNode(d.*);
        out.setSide(.east);
        const e = try lg.LEdge.init(a);
        try e.setSource(src_port);
        try e.setTarget(in);
        d.*.p.long_edge_source = src_port;
    }
    try process(g);
    try std.testing.expectEqual(@as(usize, 1), layer.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 2), dummies[0].ports.items[0].incoming.items.len);
    try std.testing.expect(dummies[0].p.long_edge_source == src_port);
}
