// LabelDummyInserter. Props: spacing.edge_label, spacing.label_label, direction (graph); edge_thickness (edges);
// edge_labels_placement (labels); origin, represented_labels, port_constraints, long_edge_source/target (dummies).
const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const splitter = @import("long_edge_splitter.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    var new_dummy_nodes: std.ArrayList(*lg.LNode) = .empty;
    const edge_label_spacing = g.p.spacing.edge_label;
    const label_label_spacing = g.p.spacing.label_label;
    const vertical = g.p.direction.isVertical();

    for (g.layerless_nodes.items) |node| {
        for (node.ports.items) |port| {
            for (port.outgoing.items) |edge| {
                if (!edgeNeedsToBeProcessed(edge)) continue;
                const thickness = retrieveThickness(edge);
                const dummy = try createLabelDummy(g, edge, thickness);
                try new_dummy_nodes.append(a, dummy);

                const size = &dummy.size;
                var i: usize = 0;
                while (i < edge.labels.items.len) {
                    const label = edge.labels.items[i];
                    if (label.p.edge_labels_placement == .center) {
                        if (vertical) {
                            size.x += label.size.x + label_label_spacing;
                            size.y = util.javaMax(size.y, label.size.y);
                        } else {
                            size.x = util.javaMax(size.x, label.size.x);
                            size.y += label.size.y + label_label_spacing;
                        }
                        try dummy.p.represented_labels.append(a, label);
                        _ = edge.labels.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
                if (vertical) {
                    size.x -= label_label_spacing;
                    size.y += edge_label_spacing + thickness;
                } else {
                    size.y += edge_label_spacing - label_label_spacing + thickness;
                }
            }
        }
    }
    try g.layerless_nodes.appendSlice(a, new_dummy_nodes.items);
}

fn edgeNeedsToBeProcessed(edge: *const lg.LEdge) bool {
    if (edge.source.?.owner.? == edge.target.?.owner.?) return false;
    for (edge.labels.items) |l| if (l.p.edge_labels_placement == .center) return true;
    return false;
}

fn retrieveThickness(edge: *lg.LEdge) f64 {
    var thickness = edge.p.edge_thickness;
    if (thickness < 0) {
        thickness = 0;
        edge.p.edge_thickness = thickness;
    }
    return thickness;
}

fn createLabelDummy(g: *lg.LGraph, edge: *lg.LEdge, thickness: f64) lg.Error!*lg.LNode {
    const dummy = try lg.LNode.init(g.a, g);
    dummy.type = .label;
    dummy.p.origin = .{ .edge = edge };
    dummy.p.port_constraints = .fixed_pos;
    dummy.p.long_edge_source = edge.source;
    dummy.p.long_edge_target = edge.target;
    _ = try splitter.splitEdge(edge, dummy);
    const port_pos = @floor(thickness / 2);
    for (dummy.ports.items) |p| p.pos.y = port_pos;
    return dummy;
}
