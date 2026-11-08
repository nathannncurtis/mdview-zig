const lg = @import("../lgraph.zig");
const graph_util = @import("../graph_util.zig");
const OrthogonalRoutingGenerator = @import("orthogonal/orthogonal_routing_generator.zig").OrthogonalRoutingGenerator;

// PolylineEdgeRouter.PRED_EXTERNAL_WEST_OR_EAST_PORT over a whole layer
fn allExternalWestOrEast(nodes: []const *lg.LNode) bool {
    for (nodes) |node| {
        const side = node.p.ext_port_side;
        if (!(node.type == .external_port and (side == .west or side == .east))) return false;
    }
    return true;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const node_node_spacing = g.p.spacing.node_node_between_layers;
    const edge_edge_spacing = g.p.spacing.edge_edge_between_layers;
    const edge_node_spacing = g.p.spacing.edge_node_between_layers;

    var routing_generator = OrthogonalRoutingGenerator.init(g.a, .west_to_east, edge_edge_spacing);
    // elkjs (GWT) keeps Java floats as doubles
    var xpos: f64 = 0.0;
    var next_layer: usize = 0;
    var left_layer: ?*lg.Layer = null;
    var left_layer_nodes: ?[]const *lg.LNode = null;

    while (true) {
        var right_layer: ?*lg.Layer = null;
        if (next_layer < g.layers.items.len) {
            right_layer = g.layers.items[next_layer];
            next_layer += 1;
        }
        const right_layer_nodes: ?[]const *lg.LNode = if (right_layer) |l| l.nodes.items else null;

        if (left_layer) |l| {
            graph_util.placeNodesHorizontally(l, xpos);
            xpos += l.size.x;
        }

        const start_pos: f64 = if (left_layer == null) xpos else xpos + edge_node_spacing;
        const slots_count = try routing_generator.routeEdges(g, left_layer_nodes, right_layer_nodes, start_pos);

        const is_left_layer_external = left_layer == null or allExternalWestOrEast(left_layer_nodes.?);
        const is_right_layer_external = right_layer == null or allExternalWestOrEast(right_layer_nodes.?);

        if (slots_count > 0) {
            var routing_width = @as(f64, @floatFromInt(slots_count - 1)) * edge_edge_spacing;
            if (left_layer != null) routing_width += edge_node_spacing;
            if (right_layer != null) routing_width += edge_node_spacing;
            if (routing_width < node_node_spacing and !is_left_layer_external and !is_right_layer_external) {
                routing_width = node_node_spacing;
            }
            xpos += routing_width;
        } else if (!is_left_layer_external and !is_right_layer_external) {
            xpos += node_node_spacing;
        }

        left_layer = right_layer;
        left_layer_nodes = right_layer_nodes;
        if (right_layer == null) break;
    }

    g.size.x = xpos;
}
