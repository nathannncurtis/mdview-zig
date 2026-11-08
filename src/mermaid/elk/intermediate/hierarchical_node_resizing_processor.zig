const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

// HierarchicalNodeResizingProcessor
pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        try g.layerless_nodes.appendSlice(g.a, layer.nodes.items);
        layer.nodes.clearRetainingCapacity();
    }
    for (g.layerless_nodes.items) |n| n.layer = null;
    g.layers.clearRetainingCapacity();
    resizeGraph(g);
    if (g.parent_node) |pn| graphLayoutToNode(pn, g);
}

fn graphLayoutToNode(node: *lg.LNode, g: *lg.LGraph) void {
    for (g.layerless_nodes.items) |child| {
        if (child.p.origin == .port) {
            const port = child.p.origin.port;
            port.pos = gu.getExternalPortPosition(g, child, port.size.x, port.size.y);
            port.setSide(child.p.ext_port_side);
        }
    }
    const actual = g.actualSize();
    if (g.p.graph_properties.external_ports) {
        node.p.port_constraints = .fixed_pos;
        node.graph.?.p.graph_properties.non_free_ports = true;
        gu.resizeNode(node, actual, false, true);
    } else {
        gu.resizeNode(node, actual, true, true);
    }
}

// shared with ElkLayered.resizeGraph, which is the same code
pub fn resizeGraph(g: *lg.LGraph) void {
    const calculated = g.actualSize();
    var adjusted = calculated;
    if (g.p.node_size_constraints.minimum_size) {
        if (g.p.node_size_options.default_minimum_size) {
            if (g.p.node_size_minimum.x <= 0) g.p.node_size_minimum.x = 20;
            if (g.p.node_size_minimum.y <= 0) g.p.node_size_minimum.y = 20;
        }
        adjusted.x = @max(calculated.x, g.p.node_size_minimum.x);
        adjusted.y = @max(calculated.y, g.p.node_size_minimum.y);
    }
    resizeGraphNoReallyIMeanIt(g, calculated, adjusted);
}

pub fn resizeGraphNoReallyIMeanIt(g: *lg.LGraph, old: lg.Vec, new: lg.Vec) void {
    const ca = g.p.content_alignment;
    if (new.x > old.x) {
        if (ca.h_center) {
            g.offset.x += (new.x - old.x) / 2;
        } else if (ca.h_right) {
            g.offset.x += new.x - old.x;
        }
    }
    if (new.y > old.y) {
        if (ca.v_center) {
            g.offset.y += (new.y - old.y) / 2;
        } else if (ca.v_bottom) {
            g.offset.y += new.y - old.y;
        }
    }
    if (g.p.graph_properties.external_ports and (new.x > old.x or new.y > old.y)) {
        for (g.layerless_nodes.items) |n| {
            if (n.type != .external_port) continue;
            if (n.p.ext_port_side == .east) {
                n.pos.x += new.x - old.x;
            } else if (n.p.ext_port_side == .south) {
                n.pos.y += new.y - old.y;
            }
        }
    }
    g.size.x = new.x - g.padding.left - g.padding.right;
    g.size.y = new.y - g.padding.top - g.padding.bottom;
}
