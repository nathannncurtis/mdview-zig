// LayerConstraintPostprocessor. Props: layer_constraint (nodes), hidden_nodes (graph), original_opposite_port (edges).
const std = @import("std");
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    if (g.layers.items.len > 0) {
        const first_layer = g.layers.items[0];
        const last_layer = g.layers.items[g.layers.items.len - 1];
        const first_label_layer = try g.newLayer();
        const last_label_layer = try g.newLayer();
        try moveFirstAndLastNodes(g, first_layer, last_layer, first_label_layer, last_label_layer);
        if (first_label_layer.nodes.items.len > 0) try g.layers.insert(a, 0, first_label_layer);
        if (last_label_layer.nodes.items.len > 0) try g.layers.append(a, last_label_layer);
    }
    if (g.p.hidden_nodes.items.len > 0) {
        const first_separate_layer = try g.newLayer();
        const last_separate_layer = try g.newLayer();
        try restoreHiddenNodes(g, first_separate_layer, last_separate_layer);
        if (first_separate_layer.nodes.items.len > 0) try g.layers.insert(a, 0, first_separate_layer);
        if (last_separate_layer.nodes.items.len > 0) try g.layers.append(a, last_separate_layer);
    }
}

fn moveFirstAndLastNodes(g: *lg.LGraph, first_layer: *lg.Layer, last_layer: *lg.Layer, first_label_layer: *lg.Layer, last_label_layer: *lg.Layer) lg.Error!void {
    for (g.layers.items) |layer| {
        const nodes = try g.a.dupe(*lg.LNode, layer.nodes.items);
        for (nodes) |node| {
            switch (node.p.layer_constraint) {
                .first => {
                    try throwUpUnlessNoEdges(node, true);
                    try node.setLayer(first_layer);
                    try moveLabelsToLabelLayer(node, true, first_label_layer);
                },
                .last => {
                    try throwUpUnlessNoEdges(node, false);
                    try node.setLayer(last_layer);
                    try moveLabelsToLabelLayer(node, false, last_label_layer);
                },
                else => {},
            }
        }
    }
    var i: usize = 0;
    while (i < g.layers.items.len) {
        if (g.layers.items[i].nodes.items.len == 0) {
            _ = g.layers.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn moveLabelsToLabelLayer(node: *lg.LNode, incoming: bool, label_layer: *lg.Layer) lg.Error!void {
    for (node.ports.items) |port| {
        for (if (incoming) port.incoming.items else port.outgoing.items) |edge| {
            const dummy = if (incoming) edge.source.?.owner.? else edge.target.?.owner.?;
            if (dummy.type == .label) try dummy.setLayer(label_layer);
        }
    }
}

fn restoreHiddenNodes(g: *lg.LGraph, first_separate_layer: *lg.Layer, last_separate_layer: *lg.Layer) lg.Error!void {
    for (g.p.hidden_nodes.items) |hidden| {
        switch (hidden.p.layer_constraint) {
            .first_separate => try hidden.setLayer(first_separate_layer),
            .last_separate => try hidden.setLayer(last_separate_layer),
            else => {},
        }
        for (hidden.ports.items) |port| {
            for ([2][]*lg.LEdge{ port.incoming.items, port.outgoing.items }) |list| {
                for (list) |edge| {
                    if (edge.source != null and edge.target != null) continue;
                    const opposite = edge.p.original_opposite_port;
                    if (edge.target == null) try edge.setTarget(opposite) else try edge.setSource(opposite);
                }
            }
        }
    }
}

fn throwUpUnlessNoEdges(node: *lg.LNode, incoming: bool) error{Unsupported}!void {
    for (node.ports.items) |port| {
        for (if (incoming) port.incoming.items else port.outgoing.items) |edge| {
            const other = if (incoming) edge.source.?.owner.? else edge.target.?.owner.?;
            if (other.type != .label) return error.Unsupported;
        }
    }
}
