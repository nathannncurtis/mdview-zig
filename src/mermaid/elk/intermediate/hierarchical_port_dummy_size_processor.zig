const std = @import("std");
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    var northern_dummies: std.ArrayList(*lg.LNode) = .empty;
    var southern_dummies: std.ArrayList(*lg.LNode) = .empty;
    const edge_spacing = g.p.spacing.edge_edge_between_layers;
    const delta = edge_spacing * 2;

    for (g.layers.items) |layer| {
        northern_dummies.clearRetainingCapacity();
        southern_dummies.clearRetainingCapacity();
        for (layer.nodes.items) |node| {
            if (node.type == .external_port) {
                const side = node.p.ext_port_side;
                if (side == .north) {
                    try northern_dummies.append(g.a, node);
                } else if (side == .south) {
                    try southern_dummies.append(g.a, node);
                }
            }
        }
        setWidths(northern_dummies.items, true, delta);
        setWidths(southern_dummies.items, false, delta);
    }
}

fn setWidths(nodes: []const *lg.LNode, top_down: bool, delta: f64) void {
    var current_width: f64 = 0.0;
    var step = delta;
    if (!top_down) {
        current_width = delta * @as(f64, @floatFromInt(@as(i64, @intCast(nodes.len)) - 1));
        step *= -1.0;
    }
    for (nodes) |node| {
        node.p.alignment = .center;
        node.size.x = current_width;
        for (node.ports.items) |port| {
            if (port.side == .east) port.pos.x = current_width;
        }
        current_width += step;
    }
}
