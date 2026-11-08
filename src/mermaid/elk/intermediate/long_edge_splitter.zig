// LongEdgeSplitter. Props: edge_thickness, junction_points (edges); origin, port_constraints, long_edge_source,
// long_edge_target, long_edge_has_label_dummies (dummy nodes); edge_labels_placement, end_label_edge (labels).
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    if (g.layers.items.len <= 2) return;
    var idx: usize = 1;
    var next_layer = g.layers.items[0];
    while (idx < g.layers.items.len) : (idx += 1) {
        const layer = next_layer;
        next_layer = g.layers.items[idx];
        for (layer.nodes.items) |node| {
            for (node.ports.items) |port| {
                for (port.outgoing.items) |edge| {
                    const target_layer = edge.target.?.owner.?.layer;
                    if (target_layer != layer and target_layer != next_layer) {
                        _ = try splitEdge(edge, try createDummyNode(g, next_layer, edge));
                    }
                }
            }
        }
    }
}

fn createDummyNode(g: *lg.LGraph, target_layer: *lg.Layer, edge_to_split: *lg.LEdge) lg.Error!*lg.LNode {
    const dummy = try lg.LNode.init(g.a, g);
    dummy.type = .long_edge;
    dummy.p.origin = .{ .edge = edge_to_split };
    dummy.p.port_constraints = .fixed_pos;
    try dummy.setLayer(target_layer);
    return dummy;
}

pub fn splitEdge(edge: *lg.LEdge, dummy: *lg.LNode) lg.Error!*lg.LEdge {
    const a = edge.a;
    const old_edge_target = edge.target.?;
    var thickness = edge.p.edge_thickness;
    if (thickness < 0) {
        thickness = 0;
        edge.p.edge_thickness = thickness;
    }
    dummy.size.y = thickness;
    const port_pos = @floor(thickness / 2);

    const dummy_input = try lg.LPort.init(a);
    dummy_input.setSide(.west);
    try dummy_input.setNode(dummy);
    dummy_input.pos.y = port_pos;

    const dummy_output = try lg.LPort.init(a);
    dummy_output.setSide(.east);
    try dummy_output.setNode(dummy);
    dummy_output.pos.y = port_pos;

    try edge.setTarget(dummy_input);

    const dummy_edge = try lg.LEdge.init(a);
    dummy_edge.p = edge.p;
    dummy_edge.p.junction_points = .empty;
    try dummy_edge.setSource(dummy_output);
    try dummy_edge.setTarget(old_edge_target);

    setDummyNodeProperties(dummy, edge, dummy_edge);
    try moveHeadLabels(edge, dummy_edge);
    return dummy_edge;
}

fn setDummyNodeProperties(dummy: *lg.LNode, in_edge: *lg.LEdge, out_edge: *lg.LEdge) void {
    const in_src = in_edge.source.?.owner.?;
    const out_tgt = out_edge.target.?.owner.?;
    if (in_src.type == .long_edge) {
        dummy.p.long_edge_source = in_src.p.long_edge_source;
        dummy.p.long_edge_target = in_src.p.long_edge_target;
        dummy.p.long_edge_has_label_dummies = in_src.p.long_edge_has_label_dummies;
    } else if (in_src.type == .label) {
        dummy.p.long_edge_source = in_src.p.long_edge_source;
        dummy.p.long_edge_target = in_src.p.long_edge_target;
        dummy.p.long_edge_has_label_dummies = true;
    } else if (out_tgt.type == .label) {
        dummy.p.long_edge_source = out_tgt.p.long_edge_source;
        dummy.p.long_edge_target = out_tgt.p.long_edge_target;
        dummy.p.long_edge_has_label_dummies = true;
    } else {
        dummy.p.long_edge_source = in_edge.source;
        dummy.p.long_edge_target = out_edge.target;
    }
}

fn moveHeadLabels(old_edge: *lg.LEdge, new_edge: *lg.LEdge) lg.Error!void {
    var i: usize = 0;
    while (i < old_edge.labels.items.len) {
        const label = old_edge.labels.items[i];
        if (label.p.edge_labels_placement == .head) {
            _ = old_edge.labels.orderedRemove(i);
            try new_edge.labels.append(new_edge.a, label);
            if (label.p.end_label_edge == null) label.p.end_label_edge = old_edge;
        } else {
            i += 1;
        }
    }
}
