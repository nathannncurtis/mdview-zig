const std = @import("std");
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        var top_insertion_index: ?usize = null;
        var bottom: std.ArrayList(*lg.LNode) = .empty;
        const nodes = try g.a.dupe(*lg.LNode, layer.nodes.items);
        for (nodes, 0..) |node, i| {
            const constraint = node.p.in_layer_constraint;
            if (top_insertion_index) |*t| {
                if (constraint == .top) {
                    try node.setLayer(null);
                    try node.setLayerAt(t.*, layer);
                    t.* += 1;
                }
            } else if (constraint != .top) {
                top_insertion_index = i;
            }
            if (constraint == .bottom) try bottom.append(g.a, node);
        }
        for (bottom.items) |node| {
            try node.setLayer(null);
            try node.setLayer(layer);
        }
    }
}
