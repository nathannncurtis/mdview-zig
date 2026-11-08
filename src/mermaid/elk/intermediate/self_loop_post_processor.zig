// SelfLoopPostProcessor. Props: self_loop_holder (nodes).
const lg = @import("../lgraph.zig");
const sl = @import("loops/self_loop_holder.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type != .normal) continue;
            const h = sl.SelfLoopHolder.of(node) orelse continue;
            for (h.sl_hyper_loops.items) |loop| {
                for (loop.sl_edges.items) |e| {
                    try e.l_edge.setSource(e.sl_source.l_port);
                    try e.l_edge.setTarget(e.sl_target.l_port);
                    for (e.l_edge.bend_points.items) |*bp| bp.add(node.pos);
                }
            }
            for (h.sl_hyper_loops.items) |loop| {
                if (loop.sl_labels) |labels| labels.applyPlacement(node.pos);
            }
        }
    }
}
