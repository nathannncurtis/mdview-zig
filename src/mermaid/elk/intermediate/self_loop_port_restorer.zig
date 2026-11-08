// SelfLoopPortRestorer. Props: self_loop_holder, original_port_constraints (nodes).
const lg = @import("../lgraph.zig");
const sl = @import("loops/self_loop_holder.zig");
const side_assigner = @import("loops/ordering/port_side_assigner.zig");
const restorer = @import("loops/ordering/port_restorer.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type != .normal) continue;
            const h = sl.SelfLoopHolder.of(node) orelse continue;
            try processNode(h);
        }
    }
}

fn computeSelfLoopTypes(h: *sl.SelfLoopHolder) lg.Error!void {
    for (h.sl_hyper_loops.items) |loop| try loop.computePortsPerSide(h.a);
}

fn processNode(h: *sl.SelfLoopHolder) lg.Error!void {
    if (!h.ports_hidden) return computeSelfLoopTypes(h);
    switch (h.l_node.p.original_port_constraints) {
        .undefined, .free => {
            try side_assigner.assignPortSides(h);
            try computeSelfLoopTypes(h);
            try restorer.restorePorts(h);
        },
        .fixed_side => {
            try computeSelfLoopTypes(h);
            try restorer.restorePorts(h);
        },
        else => {},
    }
}
