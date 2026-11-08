const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    var min_y: f64 = std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var found_nodes = false;

    for (g.layers.items) |layer| {
        layer.size.x = 0.0;
        layer.size.y = 0.0;
        if (layer.nodes.items.len == 0) continue;
        found_nodes = true;

        for (layer.nodes.items) |node| {
            layer.size.x = util.javaMax(layer.size.x, node.size.x + node.margin.left + node.margin.right);
        }

        const first_node = layer.nodes.items[0];
        var top = first_node.pos.y - first_node.margin.top;
        if (first_node.type == .external_port) top -= g.p.spacing.ports_surrounding.top;
        const last_node = layer.nodes.items[layer.nodes.items.len - 1];
        var bottom = last_node.pos.y + last_node.size.y + last_node.margin.bottom;
        if (last_node.type == .external_port) bottom += g.p.spacing.ports_surrounding.bottom;
        layer.size.y = bottom - top;

        min_y = util.javaMin(min_y, top);
        max_y = util.javaMax(max_y, bottom);
    }

    if (!found_nodes) {
        min_y = 0;
        max_y = 0;
    }

    g.size.y = max_y - min_y;
    g.offset.y -= min_y;
}
