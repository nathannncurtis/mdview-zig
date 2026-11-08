// SelfLoopPreProcessor. Props: self_loop_holder (written), port_constraints (nodes), graph_properties (nested graph).
const lg = @import("../lgraph.zig");
const sl = @import("loops/self_loop_holder.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layerless_nodes.items) |node| {
        if (!sl.SelfLoopHolder.needsSelfLoopProcessing(node)) continue;
        const h = try sl.SelfLoopHolder.install(node);
        for (h.sl_hyper_loops.items) |loop| {
            for (loop.sl_edges.items) |e| {
                try e.l_edge.setSource(null);
                try e.l_edge.setTarget(null);
            }
        }
        try hidePorts(h);
    }
}

fn hidePorts(h: *sl.SelfLoopHolder) lg.Error!void {
    const node = h.l_node;
    const order_fixed = node.p.port_constraints.isOrderFixed();
    const hierarchy_mode = if (node.nested_graph) |ng| ng.p.graph_properties.external_ports else false;
    if (order_fixed or hierarchy_mode) return;
    for (h.sl_ports.items) |p| {
        if (p.had_only_self_loops) {
            try p.l_port.setNode(null);
            p.is_hidden = true;
            h.ports_hidden = true;
        }
    }
}
