// ModelOrderCycleBreaker. Reads LNode.p.model_order (set by the importer) and layer_constraint. Followed by
// intermediate/reversed_edge_restorer after P5.
const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

const Breaker = struct {
    first_separate_model_order: i32 = 0,
    last_separate_model_order: i32 = 0,

    fn computeConstraintModelOrder(self: *Breaker, node: *const lg.LNode, offset: i32) i32 {
        var model_order: i32 = 0;
        switch (node.p.layer_constraint) {
            .first_separate => {
                model_order = 2 * -offset + self.first_separate_model_order;
                self.first_separate_model_order += 1;
            },
            .first => model_order = -offset,
            .last => model_order = offset,
            .last_separate => {
                model_order = 2 * offset + self.last_separate_model_order;
                self.last_separate_model_order += 1;
            },
            .none => {},
        }
        if (node.p.model_order) |mo| model_order += mo;
        return model_order;
    }
};

pub fn process(g: *lg.LGraph) lg.Error!void {
    var b: Breaker = .{};
    var rev_edges: std.ArrayList(*lg.LEdge) = .empty;
    const nodes = g.layerless_nodes.items;

    var offset: i32 = @intCast(nodes.len);
    for (nodes) |node| {
        if (node.p.model_order) |mo| offset = @max(offset, mo + 1);
    }

    for (nodes) |source| {
        const model_order_source = b.computeConstraintModelOrder(source, offset);
        for (source.ports.items) |port| {
            for (port.outgoing.items) |edge| {
                const target = edge.target.?.owner.?;
                const model_order_target = b.computeConstraintModelOrder(target, offset);
                if (model_order_target < model_order_source) try rev_edges.append(g.a, edge);
            }
        }
    }

    for (rev_edges.items) |edge| {
        try gu.reverseEdge(edge);
        g.p.cyclic = true;
    }
}
