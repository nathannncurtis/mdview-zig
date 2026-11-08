const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const OrthogonalRoutingGenerator = @import("../p5edges/orthogonal/orthogonal_routing_generator.zig").OrthogonalRoutingGenerator;

const NodeList = std.ArrayList(*lg.LNode);

pub fn process(g: *lg.LGraph) lg.Error!void {
    const north_south_dummies = try restoreNorthSouthDummies(g);
    try setNorthSouthDummyCoordinates(g, north_south_dummies);
    try routeEdges(g, north_south_dummies);
    try removeTemporaryNorthSouthDummies(g);
    fixCoordinatesOfGraph(g);
    correctSlantedEdgeSegmentsOfGraph(g);
}

// STEP 1: RESTORE NORTH / SOUTH DUMMIES

fn restoreNorthSouthDummies(g: *lg.LGraph) lg.Error![]*lg.LNode {
    var restored: NodeList = .empty;
    // Java checks hasProperty; an empty list restores nothing and leaves no replaced-dummy links either
    if (g.p.ext_port_replaced_dummies.items.len == 0) return restored.items;

    for (g.p.ext_port_replaced_dummies.items) |dummy| {
        restoreDummy(dummy);
        try restored.append(g.a, dummy);
    }
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type != .external_port) continue;
            if (node.p.ext_port_replaced_dummy) |replaced| try connectNodeToDummy(node, replaced);
        }
    }
    const last = g.layers.items[g.layers.items.len - 1];
    for (restored.items) |dummy| try dummy.setLayer(last);
    return restored.items;
}

// shortcut: the PORT_LABELS size-constraint branch (port label placement and margins) is left out; Mermaid
// never sets PORT_LABELS on a graph, port it with NodeMarginCalculator if that changes
fn restoreDummy(dummy: *lg.LNode) void {
    const port_side = dummy.p.ext_port_side;
    const dummy_port = dummy.ports.items[0];
    if (port_side == .north) {
        dummy_port.setSide(.south);
    } else if (port_side == .south) {
        dummy_port.setSide(.north);
    }
}

fn connectNodeToDummy(node: *lg.LNode, dummy: *lg.LNode) lg.Error!void {
    const out_port = try lg.LPort.init(node.a);
    try out_port.setNode(node);
    out_port.setSide(node.p.ext_port_side);
    const in_port = dummy.ports.items[0];
    const edge = try lg.LEdge.init(node.a);
    try edge.setSource(out_port);
    try edge.setTarget(in_port);
}

// STEP 2: SET NORTH / SOUTH DUMMY COORDINATES

fn setNorthSouthDummyCoordinates(g: *lg.LGraph, north_south_dummies: []const *lg.LNode) lg.Error!void {
    const constraints = g.p.port_constraints;
    const graph_padding = g.padding;
    const graph_width = g.size.x + graph_padding.left + graph_padding.right;
    const north_y = 0 - graph_padding.top - g.offset.y;
    const south_y = g.size.y + graph_padding.top + graph_padding.bottom - g.offset.y;

    var northern: NodeList = .empty;
    var southern: NodeList = .empty;

    for (north_south_dummies) |dummy| {
        switch (constraints) {
            .free, .fixed_side, .fixed_order => calculateNorthSouthDummyPositions(dummy),
            .fixed_ratio => {
                applyNorthSouthDummyRatio(dummy, graph_width);
                dummy.borderToContentAreaCoordinates(true, false);
            },
            .fixed_pos => {
                applyNorthSouthDummyPosition(dummy);
                dummy.borderToContentAreaCoordinates(true, false);
                g.size.x = util.javaMax(g.size.x, dummy.pos.x + dummy.size.x / 2.0);
            },
            .undefined => {},
        }
        switch (dummy.p.ext_port_side) {
            .north => {
                dummy.pos.y = north_y;
                try northern.append(g.a, dummy);
            },
            .south => {
                dummy.pos.y = south_y;
                try southern.append(g.a, dummy);
            },
            else => {},
        }
    }

    switch (constraints) {
        .free, .fixed_side => {
            try ensureUniquePositions(northern.items, g);
            try ensureUniquePositions(southern.items, g);
        },
        .fixed_order => {
            try restoreProperOrder(northern.items, g);
            try restoreProperOrder(southern.items, g);
        },
        else => {},
    }
}

fn calculateNorthSouthDummyPositions(dummy: *lg.LNode) void {
    const dummy_in_port = dummy.ports.items[0];
    if (dummy_in_port.degree() == 0) {
        dummy.pos.x = 0;
    } else {
        var pos_sum: f64 = 0.0;
        for (dummy_in_port.incoming.items) |e| pos_sum += connectedX(e.source.?);
        for (dummy_in_port.outgoing.items) |e| pos_sum += connectedX(e.target.?);
        const offset = if (dummy.p.port_anchor) |anchor| anchor.x else 0;
        dummy.pos.x = pos_sum / @as(f64, @floatFromInt(dummy_in_port.degree())) - offset;
    }
}

fn connectedX(port: *const lg.LPort) f64 {
    return port.owner.?.pos.x + port.pos.x + port.anchor.x;
}

fn applyNorthSouthDummyRatio(dummy: *lg.LNode, width: f64) void {
    const offset = if (dummy.p.port_anchor) |anchor| anchor.x else 0;
    dummy.pos.x = width * dummy.p.port_ratio_or_position - offset;
}

fn applyNorthSouthDummyPosition(dummy: *lg.LNode) void {
    const offset = if (dummy.p.port_anchor) |anchor| anchor.x else 0;
    dummy.pos.x = dummy.p.port_ratio_or_position - offset;
}

fn ensureUniquePositions(dummies: []const *lg.LNode, g: *lg.LGraph) lg.Error!void {
    if (dummies.len == 0) return;
    const arr = try g.a.dupe(*lg.LNode, dummies);
    std.mem.sort(*lg.LNode, arr, {}, struct {
        fn lt(_: void, x: *lg.LNode, y: *lg.LNode) bool {
            return util.doubleCompare(x.pos.x, y.pos.x) == .lt;
        }
    }.lt);
    assignAscendingCoordinates(arr, g);
}

fn restoreProperOrder(dummies: []const *lg.LNode, g: *lg.LGraph) lg.Error!void {
    if (dummies.len == 0) return;
    const arr = try g.a.dupe(*lg.LNode, dummies);
    std.mem.sort(*lg.LNode, arr, {}, struct {
        fn lt(_: void, x: *lg.LNode, y: *lg.LNode) bool {
            return util.doubleCompare(x.p.port_ratio_or_position, y.p.port_ratio_or_position) == .lt;
        }
    }.lt);
    assignAscendingCoordinates(arr, g);
}

fn assignAscendingCoordinates(dummies: []const *lg.LNode, g: *lg.LGraph) void {
    const spacing = g.p.spacing.port_port;
    var next_valid = dummies[0].pos.x + dummies[0].size.x + dummies[0].margin.right + spacing;
    var index: usize = 1;
    while (index < dummies.len) : (index += 1) {
        const d = dummies[index];
        const delta = d.pos.x - d.margin.left - next_valid;
        if (delta < 0) d.pos.x -= delta;
        g.size.x = util.javaMax(g.size.x, d.pos.x + d.size.x);
        next_valid = d.pos.x + d.size.x + d.margin.right + spacing;
    }
}

// STEP 3: EDGE ROUTING

fn addUnique(a: std.mem.Allocator, set: *NodeList, node: *lg.LNode) lg.Error!void {
    for (set.items) |x| if (x == node) return;
    try set.append(a, node);
}

fn routeEdges(g: *lg.LGraph, north_south_dummies: []const *lg.LNode) lg.Error!void {
    const a = g.a;
    var northern_source_layer: NodeList = .empty;
    var northern_target_layer: NodeList = .empty;
    var southern_source_layer: NodeList = .empty;
    var southern_target_layer: NodeList = .empty;
    const node_spacing = g.p.spacing.node_node;
    const edge_spacing = g.p.spacing.edge_edge;

    for (north_south_dummies) |dummy| {
        const port_side = dummy.p.ext_port_side;
        if (port_side == .north) {
            try addUnique(a, &northern_target_layer, dummy);
            for (dummy.ports.items) |port| for (port.incoming.items) |edge| try addUnique(a, &northern_source_layer, edge.source.?.owner.?);
        } else if (port_side == .south) {
            try addUnique(a, &southern_target_layer, dummy);
            for (dummy.ports.items) |port| for (port.incoming.items) |edge| try addUnique(a, &southern_source_layer, edge.source.?.owner.?);
        }
    }

    if (northern_source_layer.items.len != 0) {
        var routing_generator = OrthogonalRoutingGenerator.init(a, .south_to_north, edge_spacing);
        const slots = try routing_generator.routeEdges(g, northern_source_layer.items, northern_target_layer.items, -node_spacing - g.offset.y);
        if (slots > 0) {
            const height = node_spacing + @as(f64, @floatFromInt(slots - 1)) * edge_spacing;
            g.offset.y += height;
            g.size.y += height;
        }
    }

    if (southern_source_layer.items.len != 0) {
        var routing_generator = OrthogonalRoutingGenerator.init(a, .north_to_south, edge_spacing);
        const slots = try routing_generator.routeEdges(g, southern_source_layer.items, southern_target_layer.items, g.size.y + node_spacing - g.offset.y);
        if (slots > 0) g.size.y += node_spacing + @as(f64, @floatFromInt(slots - 1)) * edge_spacing;
    }
}

// STEP 4: REMOVE TEMPORARY DUMMIES

fn removeTemporaryNorthSouthDummies(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    var nodes_to_remove: NodeList = .empty;
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type != .external_port) continue;
            const replaced_dummy = node.p.ext_port_replaced_dummy orelse continue;

            var node_in_port: ?*lg.LPort = null;
            var node_out_port: ?*lg.LPort = null;
            var node_origin_port: ?*lg.LPort = null;
            for (node.ports.items) |port| {
                switch (port.side) {
                    .west => node_in_port = port,
                    .east => node_out_port = port,
                    else => node_origin_port = port,
                }
            }

            const node_to_origin_edge = node_origin_port.?.outgoing.items[0];

            var incoming_bend_points: std.ArrayList(lg.Vec) = .empty;
            var first_bend_point = node_origin_port.?.pos;
            first_bend_point.add(node.pos);
            try incoming_bend_points.append(a, first_bend_point);
            try incoming_bend_points.appendSlice(a, node_to_origin_edge.bend_points.items);

            var outgoing_bend_points: std.ArrayList(lg.Vec) = .empty;
            var k = node_to_origin_edge.bend_points.items.len;
            while (k > 0) {
                k -= 1;
                try outgoing_bend_points.append(a, node_to_origin_edge.bend_points.items[k]);
            }
            var last_bend_point = node_origin_port.?.pos;
            last_bend_point.add(node.pos);
            try outgoing_bend_points.append(a, last_bend_point);

            const replaced_dummy_port = replaced_dummy.ports.items[0];

            const in_edges = try a.dupe(*lg.LEdge, node_in_port.?.incoming.items);
            for (in_edges) |edge| {
                try edge.setTarget(replaced_dummy_port);
                try edge.bend_points.appendSlice(edge.a, incoming_bend_points.items);
            }
            const out_edges = try a.dupe(*lg.LEdge, node_out_port.?.outgoing.items);
            for (out_edges) |edge| {
                try edge.setSource(replaced_dummy_port);
                try edge.bend_points.insertSlice(edge.a, 0, outgoing_bend_points.items);
            }

            try node_to_origin_edge.setSource(null);
            try node_to_origin_edge.setTarget(null);
            try nodes_to_remove.append(a, node);
        }
    }
    for (nodes_to_remove.items) |node| try node.setLayer(null);
}

// STEP 5: FIX DUMMY COORDINATES

fn fixCoordinatesOfGraph(g: *lg.LGraph) void {
    const constraints = g.p.port_constraints;
    const layers = g.layers.items;
    if (layers.len == 0) return;
    fixCoordinates(layers[0], constraints, g);
    fixCoordinates(layers[layers.len - 1], constraints, g);
}

fn fixCoordinates(layer: *lg.Layer, constraints: lg.PortConstraints, g: *lg.LGraph) void {
    const padding = g.padding;
    const offset = &g.offset;
    const graph_actual_size = g.actualSize();
    var new_actual_graph_height = graph_actual_size.y;

    for (layer.nodes.items) |node| {
        if (node.type != .external_port) continue;
        const ext_port_side = node.p.ext_port_side;
        const ext_port_size = node.p.ext_port_size;
        switch (ext_port_side) {
            .east => node.pos.x = g.size.x + padding.right - offset.x,
            .west => node.pos.x = -offset.x - padding.left,
            else => {},
        }
        var required_actual_graph_height: f64 = 0.0;
        switch (ext_port_side) {
            .east, .west => {
                const anchor_y = (node.p.port_anchor orelse lg.Vec{}).y;
                if (constraints == .fixed_ratio) {
                    const ratio = node.p.port_ratio_or_position;
                    node.pos.y = graph_actual_size.y * ratio - anchor_y;
                    required_actual_graph_height = node.pos.y + ext_port_size.y;
                    node.borderToContentAreaCoordinates(false, true);
                } else if (constraints == .fixed_pos) {
                    node.pos.y = node.p.port_ratio_or_position - anchor_y;
                    required_actual_graph_height = node.pos.y + ext_port_size.y;
                    node.borderToContentAreaCoordinates(false, true);
                }
            },
            else => {},
        }
        new_actual_graph_height = util.javaMax(new_actual_graph_height, required_actual_graph_height);
    }

    g.size.y += new_actual_graph_height - graph_actual_size.y;

    for (layer.nodes.items) |node| {
        if (node.type != .external_port) continue;
        switch (node.p.ext_port_side) {
            .north => node.pos.y = -offset.y - padding.top,
            .south => node.pos.y = g.size.y + padding.bottom - offset.y,
            else => {},
        }
    }
}

// STEP 6: SLANTED EDGE SEGMENT CORRECTION

fn correctSlantedEdgeSegmentsOfGraph(g: *lg.LGraph) void {
    const layers = g.layers.items;
    if (layers.len == 0) return;
    correctSlantedEdgeSegments(layers[0]);
    correctSlantedEdgeSegments(layers[layers.len - 1]);
}

fn correctSlantedEdge(node: *const lg.LNode, edge: *lg.LEdge) void {
    const bend_points = edge.bend_points.items;
    if (bend_points.len == 0) return;
    const source_port = edge.source.?;
    if (source_port.owner.? == node) bend_points[0].y = source_port.absoluteAnchor().y;
    const target_port = edge.target.?;
    if (target_port.owner.? == node) bend_points[bend_points.len - 1].y = target_port.absoluteAnchor().y;
}

fn correctSlantedEdgeSegments(layer: *lg.Layer) void {
    for (layer.nodes.items) |node| {
        if (node.type != .external_port) continue;
        const ext_port_side = node.p.ext_port_side;
        if (ext_port_side == .east or ext_port_side == .west) {
            for (node.ports.items) |port| {
                for (port.incoming.items) |edge| correctSlantedEdge(node, edge);
                for (port.outgoing.items) |edge| correctSlantedEdge(node, edge);
            }
        }
    }
}
