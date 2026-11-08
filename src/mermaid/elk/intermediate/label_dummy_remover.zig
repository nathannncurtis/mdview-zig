// LabelDummyRemover. Props: spacing.edge_label, spacing.label_label, direction, edge_routing (graph); origin,
// label_side, represented_labels (label dummies); edge_thickness (edges); edge_labels_inline (labels).
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");
const joiner = @import("long_edge_joiner.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    const edge_label_spacing = g.p.spacing.edge_label;
    const label_label_spacing = g.p.spacing.label_label;
    const dir = g.p.direction;
    for (g.layers.items) |layer| {
        var i: usize = 0;
        while (i < layer.nodes.items.len) {
            const node = layer.nodes.items[i];
            if (node.type != .label) {
                i += 1;
                continue;
            }
            const origin_edge = node.p.origin.edge;
            const thickness = origin_edge.p.edge_thickness;
            const labels_below_edge = node.p.label_side == .below;
            var pos = node.pos;
            if (labels_below_edge) pos.y += thickness + edge_label_spacing;
            const space: lg.Vec = .{
                .x = node.size.x,
                .y = node.size.y + (if (gu.isInlineEdgeLabel(node)) 0 else -thickness - edge_label_spacing),
            };
            const labels = node.p.represented_labels.items;
            if (dir.isVertical()) {
                placeLabelsForVerticalLayout(labels, &pos, label_label_spacing, space, labels_below_edge, dir);
            } else {
                placeLabelsForHorizontalLayout(labels, &pos, label_label_spacing, space);
            }
            try origin_edge.labels.appendSlice(origin_edge.a, labels);
            try joiner.joinAt(node, g.p.edge_routing == .polyline);
            _ = layer.nodes.orderedRemove(i);
        }
    }
}

fn placeLabelsForHorizontalLayout(labels: []*lg.LLabel, pos: *lg.Vec, spacing: f64, space: lg.Vec) void {
    for (labels) |label| {
        label.pos.x = pos.x + (space.x - label.size.x) / 2.0;
        label.pos.y = pos.y;
        pos.y += label.size.y + spacing;
    }
}

fn placeLabelsForVerticalLayout(labels: []*lg.LLabel, pos: *lg.Vec, spacing: f64, space: lg.Vec, left_aligned: bool, dir: lg.Direction) void {
    var all_inline = true;
    for (labels) |l| if (!l.p.edge_labels_inline) {
        all_inline = false;
    };
    var k: usize = 0;
    while (k < labels.len) : (k += 1) {
        const label = if (dir == .up) labels[labels.len - 1 - k] else labels[k];
        label.pos.x = pos.x;
        if (all_inline) {
            label.pos.y = pos.y + (space.y - label.size.y) / 2;
        } else if (left_aligned) {
            label.pos.y = pos.y;
        } else {
            label.pos.y = pos.y + space.y - label.size.y;
        }
        pos.x += label.size.x + spacing;
    }
}
