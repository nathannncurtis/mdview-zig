// LongEdgeJoiner. Props: unnecessary_bendpoints (graph), junction_points (edges).
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    const add_unnecessary_bendpoints = g.p.unnecessary_bendpoints;
    for (g.layers.items) |layer| {
        var i: usize = 0;
        while (i < layer.nodes.items.len) {
            const node = layer.nodes.items[i];
            if (node.type == .long_edge) {
                try joinAt(node, add_unnecessary_bendpoints);
                _ = layer.nodes.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn firstPortOfSide(node: *lg.LNode, side: lg.PortSide) *lg.LPort {
    for (node.ports.items) |p| if (p.side == side) return p;
    unreachable;
}

pub fn joinAt(dummy: *lg.LNode, add_unnecessary_bendpoints: bool) lg.Error!void {
    const input_port = firstPortOfSide(dummy, .west);
    const output_port = firstPortOfSide(dummy, .east);
    var edge_count = input_port.incoming.items.len;
    const unnecessary_bendpoint = dummy.ports.items[0].absoluteAnchor();

    while (edge_count > 0) : (edge_count -= 1) {
        const surviving = input_port.incoming.items[0];
        const dropped = output_port.outgoing.items[0];
        const dropped_target = dropped.target.?;

        var dropped_index: usize = 0;
        for (dropped_target.incoming.items, 0..) |e, k| if (e == dropped) {
            dropped_index = k;
            break;
        };
        try surviving.setTargetAndInsertAtIndex(dropped_target, dropped_index);

        try dropped.setSource(null);
        try dropped.setTarget(null);

        const a = surviving.a;
        if (add_unnecessary_bendpoints) try surviving.bend_points.append(a, unnecessary_bendpoint);
        try surviving.bend_points.appendSlice(a, dropped.bend_points.items);
        try surviving.labels.appendSlice(a, dropped.labels.items);
        try surviving.p.junction_points.appendSlice(a, dropped.p.junction_points.items);
    }
}
