const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");

// GraphTransformer with directionCongruency READING_DIRECTION (the default; ROTATION is never set)
pub const DirectionPreprocessor = struct {
    pub fn process(g: *lg.LGraph) lg.Error!void {
        try run(g, true);
    }
};

pub const DirectionPostprocessor = struct {
    pub fn process(g: *lg.LGraph) lg.Error!void {
        try run(g, false);
    }
};

fn run(g: *lg.LGraph, to_internal_ltr: bool) lg.Error!void {
    var nodes: std.ArrayList(*lg.LNode) = .empty;
    try nodes.appendSlice(g.a, g.layerless_nodes.items);
    for (g.layers.items) |layer| try nodes.appendSlice(g.a, layer.nodes.items);
    switch (g.p.direction) {
        .left => mirrorAllX(g, nodes.items),
        .down => transposeAll(g, nodes.items),
        .up => if (to_internal_ltr) {
            transposeAll(g, nodes.items);
            mirrorAllY(g, nodes.items);
        } else {
            mirrorAllY(g, nodes.items);
            transposeAll(g, nodes.items);
        },
        else => {},
    }
}

fn mirrorAllX(g: *lg.LGraph, nodes: []*lg.LNode) void {
    mirrorNodesX(nodes, g);
    mirrorMarginX(&g.padding);
    mirrorMarginX(&g.p.node_labels_padding);
}

fn mirrorAllY(g: *lg.LGraph, nodes: []*lg.LNode) void {
    mirrorNodesY(nodes, g);
    mirrorMarginY(&g.padding);
    mirrorMarginY(&g.p.node_labels_padding);
}

fn transposeAll(g: *lg.LGraph, nodes: []*lg.LNode) void {
    transposeNodes(nodes);
    g.p.edge_labels_side_selection = transposeSideSelection(g.p.edge_labels_side_selection);
    transposeVec(&g.offset);
    transposeVec(&g.size);
    transposeMargin(&g.padding);
    transposeMargin(&g.p.node_labels_padding);
}

fn reverseIndex(port: *lg.LPort) void {
    port.p.port_index = -port.p.port_index;
}

fn mirrorNodesX(nodes: []*lg.LNode, graph: *const lg.LGraph) void {
    var offset: f64 = 0;
    if (graph.size.x == 0) {
        for (nodes) |node| offset = util.javaMax(offset, node.pos.x + node.size.x + node.margin.right);
    } else {
        offset = graph.size.x - graph.offset.x;
    }
    offset -= graph.offset.x;
    for (nodes) |node| {
        node.pos.x = (offset - node.size.x) - node.pos.x;
        mirrorMarginX(&node.padding);
        mirrorPlacementX(&node.p.node_labels_placement);
        node.p.alignment = switch (node.p.alignment) {
            .left => .right,
            .right => .left,
            else => |x| x,
        };
        const node_size = node.size;
        for (node.ports.items) |port| {
            port.pos.x = (node_size.x - port.size.x) - port.pos.x;
            port.anchor.x = port.size.x - port.anchor.x;
            port.setSide(mirroredSideX(port.side));
            reverseIndex(port);
            for (port.outgoing.items) |edge| {
                for (edge.bend_points.items) |*bp| bp.x = offset - bp.x;
                for (edge.p.junction_points.items) |*jp| jp.x = offset - jp.x;
                for (edge.labels.items) |label| label.pos.x = (offset - label.size.x) - label.pos.x;
            }
            for (port.labels.items) |label| label.pos.x = (port.size.x - label.size.x) - label.pos.x;
        }
        if (node.type == .external_port) {
            node.p.ext_port_side = mirroredSideX(node.p.ext_port_side);
            node.p.layer_constraint = switch (node.p.layer_constraint) {
                .first => .last,
                .first_separate => .last_separate,
                .last => .first,
                .last_separate => .first_separate,
                .none => .none,
            };
        }
        for (node.labels.items) |label| {
            mirrorPlacementX(&label.p.node_labels_placement);
            label.pos.x = (node_size.x - label.size.x) - label.pos.x;
        }
    }
}

fn mirrorNodesY(nodes: []*lg.LNode, graph: *const lg.LGraph) void {
    var offset: f64 = 0;
    if (graph.size.y == 0) {
        for (nodes) |node| offset = util.javaMax(offset, node.pos.y + node.size.y + node.margin.bottom);
    } else {
        offset = graph.size.y - graph.offset.y;
    }
    offset -= graph.offset.y;
    for (nodes) |node| {
        node.pos.y = (offset - node.size.y) - node.pos.y;
        mirrorMarginY(&node.padding);
        mirrorPlacementY(&node.p.node_labels_placement);
        node.p.alignment = switch (node.p.alignment) {
            .top => .bottom,
            .bottom => .top,
            else => |x| x,
        };
        const node_size = node.size;
        for (node.ports.items) |port| {
            port.pos.y = (node_size.y - port.size.y) - port.pos.y;
            port.anchor.y = port.size.y - port.anchor.y;
            port.setSide(mirroredSideY(port.side));
            reverseIndex(port);
            for (port.outgoing.items) |edge| {
                for (edge.bend_points.items) |*bp| bp.y = offset - bp.y;
                for (edge.p.junction_points.items) |*jp| jp.y = offset - jp.y;
                for (edge.labels.items) |label| label.pos.y = (offset - label.size.y) - label.pos.y;
            }
            for (port.labels.items) |label| label.pos.y = (port.size.y - label.size.y) - label.pos.y;
        }
        if (node.type == .external_port) {
            node.p.ext_port_side = mirroredSideY(node.p.ext_port_side);
            node.p.in_layer_constraint = switch (node.p.in_layer_constraint) {
                .top => .bottom,
                .bottom => .top,
                .none => .none,
            };
        }
        for (node.labels.items) |label| {
            mirrorPlacementY(&label.p.node_labels_placement);
            label.pos.y = (node_size.y - label.size.y) - label.pos.y;
        }
    }
}

fn mirrorMarginX(m: *lg.Margin) void {
    std.mem.swap(f64, &m.left, &m.right);
}

fn mirrorMarginY(m: *lg.Margin) void {
    std.mem.swap(f64, &m.top, &m.bottom);
}

// An unset placement is the empty default, which every placement transform leaves unchanged.
fn mirrorPlacementX(p: *lg.NodeLabelPlacement) void {
    if (p.h_left) {
        p.h_left = false;
        p.h_right = true;
    } else if (p.h_right) {
        p.h_right = false;
        p.h_left = true;
    }
}

fn mirrorPlacementY(p: *lg.NodeLabelPlacement) void {
    if (p.v_top) {
        p.v_top = false;
        p.v_bottom = true;
    } else if (p.v_bottom) {
        p.v_bottom = false;
        p.v_top = true;
    }
}

fn mirroredSideX(side: lg.PortSide) lg.PortSide {
    return switch (side) {
        .east => .west,
        .west => .east,
        else => side,
    };
}

fn mirroredSideY(side: lg.PortSide) lg.PortSide {
    return switch (side) {
        .north => .south,
        .south => .north,
        else => side,
    };
}

fn transposeNodes(nodes: []*lg.LNode) void {
    for (nodes) |node| {
        transposeVec(&node.pos);
        transposeVec(&node.size);
        transposeMargin(&node.padding);
        transposePlacement(&node.p.node_labels_placement);
        transposeProperties(node);
        for (node.ports.items) |port| {
            transposeVec(&port.pos);
            transposeVec(&port.anchor);
            transposeVec(&port.size);
            port.setSide(transposedSide(port.side));
            reverseIndex(port);
            for (port.outgoing.items) |edge| {
                for (edge.bend_points.items) |*bp| transposeVec(bp);
                for (edge.p.junction_points.items) |*jp| transposeVec(jp);
                for (edge.labels.items) |label| {
                    transposeVec(&label.pos);
                    transposeVec(&label.size);
                }
            }
            for (port.labels.items) |label| {
                transposeVec(&label.pos);
                transposeVec(&label.size);
            }
        }
        if (node.type == .external_port) {
            node.p.ext_port_side = transposedSide(node.p.ext_port_side);
            transposeLayerConstraint(node);
        }
        for (node.labels.items) |label| {
            transposePlacement(&label.p.node_labels_placement);
            transposeVec(&label.size);
            transposeVec(&label.pos);
        }
    }
}

fn transposeVec(v: *lg.Vec) void {
    std.mem.swap(f64, &v.x, &v.y);
}

fn transposeMargin(m: *lg.Margin) void {
    const old = m.*;
    m.* = .{ .top = old.left, .bottom = old.right, .left = old.top, .right = old.bottom };
}

fn transposePlacement(p: *lg.NodeLabelPlacement) void {
    const old = p.*;
    if (@as(u9, @bitCast(old)) == 0) return;
    var new: lg.NodeLabelPlacement = .{};
    if (old.inside) new.inside = true else new.outside = true;
    if (!old.h_priority) new.h_priority = true;
    if (old.h_left) {
        new.v_top = true;
    } else if (old.h_center) {
        new.v_center = true;
    } else if (old.h_right) {
        new.v_bottom = true;
    }
    if (old.v_top) {
        new.h_left = true;
    } else if (old.v_center) {
        new.h_center = true;
    } else if (old.v_bottom) {
        new.h_right = true;
    }
    p.* = new;
}

fn transposedSide(side: lg.PortSide) lg.PortSide {
    return switch (side) {
        .north => .west,
        .west => .north,
        .south => .east,
        .east => .south,
        .undefined => .undefined,
    };
}

fn transposeSideSelection(s: lg.EdgeLabelSideSelection) lg.EdgeLabelSideSelection {
    return switch (s) {
        .always_up => .always_down,
        .always_down => .always_up,
        .direction_up => .direction_down,
        .direction_down => .direction_up,
        .smart_up => .smart_down,
        .smart_down => .smart_up,
    };
}

fn transposeLayerConstraint(node: *lg.LNode) void {
    const layer_constraint = node.p.layer_constraint;
    const in_layer_constraint = node.p.in_layer_constraint;
    if (layer_constraint == .first_separate) {
        node.p.layer_constraint = .none;
        node.p.in_layer_constraint = .top;
    } else if (layer_constraint == .last_separate) {
        node.p.layer_constraint = .none;
        node.p.in_layer_constraint = .bottom;
    } else if (in_layer_constraint == .top) {
        node.p.layer_constraint = .first_separate;
        node.p.in_layer_constraint = .none;
    } else if (in_layer_constraint == .bottom) {
        node.p.layer_constraint = .last_separate;
        node.p.in_layer_constraint = .none;
    }
}

fn transposeProperties(node: *lg.LNode) void {
    transposeVec(&node.p.node_size_minimum);
    node.p.alignment = switch (node.p.alignment) {
        .left => .top,
        .right => .bottom,
        .top => .left,
        .bottom => .right,
        else => |x| x,
    };
}
