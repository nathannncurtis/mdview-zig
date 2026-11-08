const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    const layers = g.layers.items;
    if (layers.len > 0) fixCoordinates(layers[0], g);
    if (layers.len > 1) fixCoordinates(layers[layers.len - 1], g);
}

fn fixCoordinates(layer: *lg.Layer, g: *lg.LGraph) void {
    const port_constraints = g.p.port_constraints;
    if (!(port_constraints.isRatioFixed() or port_constraints.isPosFixed())) return;
    const graph_height = g.actualSize().y;
    for (layer.nodes.items) |node| {
        if (node.type != .external_port) continue;
        const ext_port_side = node.p.ext_port_side;
        if (ext_port_side != .east and ext_port_side != .west) continue;
        var final_y = node.p.port_ratio_or_position;
        if (port_constraints == .fixed_ratio) final_y *= graph_height;
        node.pos.y = final_y - (node.p.port_anchor orelse lg.Vec{}).y;
        node.borderToContentAreaCoordinates(false, true);
    }
}
