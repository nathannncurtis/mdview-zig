// SimpleNodePlacer. With external ports the driver adds HIERARCHICAL_PORT_POSITION_PROCESSOR before phase 5.
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const spacings = @import("../spacings.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    var max_height: f64 = 0;
    for (g.layers.items) |layer| {
        layer.size.y = 0;
        var last: ?*lg.LNode = null;
        for (layer.nodes.items) |node| {
            if (last) |l| layer.size.y += spacings.getVerticalSpacing(node, l);
            layer.size.y += node.margin.top + node.size.y + node.margin.bottom;
            last = node;
        }
        max_height = util.javaMax(max_height, layer.size.y);
    }

    for (g.layers.items) |layer| {
        var pos = (max_height - layer.size.y) / 2;
        var last: ?*lg.LNode = null;
        for (layer.nodes.items) |node| {
            if (last) |l| pos += spacings.getVerticalSpacing(node, l);
            pos += node.margin.top;
            node.pos.y = pos;
            pos += node.size.y + node.margin.bottom;
            last = node;
        }
    }
}
