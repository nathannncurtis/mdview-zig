const lg = @import("../lgraph.zig");
const nlsc = @import("../nodespacing/node_label_and_size_calculator.zig");

// LabelAndNodeSizeProcessor: places ports and node labels and sizes NORMAL nodes. The external port dummy label
// placement that follows in Java only acts on port labels, which Mermaid's graphs never have.
pub fn process(g: *lg.LGraph) lg.Error!void {
    const env = nlsc.Env.ofGraph(g);
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type == .normal) _ = try nlsc.process(g.a, node, env, true);
        }
    }
}
