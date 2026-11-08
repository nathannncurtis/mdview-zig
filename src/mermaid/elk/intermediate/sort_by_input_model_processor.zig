const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const ModelOrderNodeComparator = @import("preserveorder/model_order_node_comparator.zig").ModelOrderNodeComparator;
const ModelOrderPortComparator = @import("preserveorder/model_order_port_comparator.zig").ModelOrderPortComparator;

// SortByInputModelProcessor: before P3 whenever considerModelOrder.strategy != NONE
pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    for (g.layers.items, 0..) |layer, layer_index| {
        const previous_layer = g.layers.items[if (layer_index == 0) 0 else layer_index - 1];
        for (layer.nodes.items) |node| {
            if (node.p.port_constraints != .fixed_order and node.p.port_constraints != .fixed_pos) {
                var cmp = ModelOrderPortComparator.init(a, previous_layer.nodes.items, try longEdgeTargetNodePreprocessing(node), g.p.consider_model_order_port_model_order);
                try util.javaSort(*lg.LPort, a, node.ports.items, &cmp, ModelOrderPortComparator.compare);
            }
        }
        var cmp = ModelOrderNodeComparator.init(a, previous_layer.nodes.items, g.p.consider_model_order, g.p.consider_model_order_long_edge_strategy);
        try util.javaSort(*lg.LNode, a, layer.nodes.items, &cmp, ModelOrderNodeComparator.compare);
    }
}

pub fn longEdgeTargetNodePreprocessing(node: *lg.LNode) lg.Error!*std.AutoHashMapUnmanaged(*lg.LNode, i32) {
    if (node.p.target_node_model_order) |m| return m;
    const m = try node.a.create(std.AutoHashMapUnmanaged(*lg.LNode, i32));
    m.* = .empty;
    for (node.ports.items) |p| {
        if (p.outgoing.items.len == 0) continue;
        const target_node = getTargetNode(p);
        p.p.long_edge_target_node = target_node;
        if (target_node) |t| {
            const previous_order = m.get(t) orelse std.math.maxInt(i32);
            const edge = p.outgoing.items[0];
            if (!edge.p.reversed) try m.put(node.a, t, @min(edge.p.model_order orelse 0, previous_order));
        }
    }
    node.p.target_node_model_order = m;
    return m;
}

pub fn getTargetNode(port: *lg.LPort) ?*lg.LNode {
    var edge = port.outgoing.items[0];
    while (true) {
        const node = edge.target.?.owner.?;
        if (node.p.long_edge_target) |t| return t.owner;
        if (node.type != .normal) {
            edge = firstOutgoing(node) orelse return null;
        } else {
            return node;
        }
    }
}

fn firstOutgoing(node: *lg.LNode) ?*lg.LEdge {
    for (node.ports.items) |p| {
        if (p.outgoing.items.len != 0) return p.outgoing.items[0];
    }
    return null;
}
