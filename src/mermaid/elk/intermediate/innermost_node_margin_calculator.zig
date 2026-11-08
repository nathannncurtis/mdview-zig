const lg = @import("../lgraph.zig");
const nmc = @import("../nodespacing/node_margin_calculator.zig");

// InnermostNodeMarginCalculator: margins of every node from its labels and ports (edge end labels excluded)
pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| nmc.processNode(node);
    }
}
