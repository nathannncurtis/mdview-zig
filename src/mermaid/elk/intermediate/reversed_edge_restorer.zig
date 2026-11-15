// ReversedEdgeRestorer. Props: reversed (edges).
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            for (node.ports.items) |port| {
                const edges = try g.a.dupe(*lg.LEdge, port.outgoing.items);
                for (edges) |edge| {
                    if (edge.p.reversed) try gu.reverseEdgeAdapt(edge, false);
                }
            }
        }
    }
}
