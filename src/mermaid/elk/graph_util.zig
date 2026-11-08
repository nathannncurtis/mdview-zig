const std = @import("std");
const lg = @import("lgraph.zig");

// LGraphUtil.placeNodesHorizontally
pub fn placeNodesHorizontally(layer: *lg.Layer, xoffset: f64) void {
    var max_left_margin: f64 = 0;
    var max_right_margin: f64 = 0;
    for (layer.nodes.items) |node| {
        max_left_margin = @import("util.zig").javaMax(max_left_margin, node.margin.left);
        max_right_margin = @import("util.zig").javaMax(max_right_margin, node.margin.right);
    }
    for (layer.nodes.items) |node| {
        // SAFETY: set in every switch branch before it is read
        var ratio: f64 = undefined;
        switch (node.p.alignment) {
            .left => ratio = 0.0,
            .right => ratio = 1.0,
            .center => ratio = 0.5,
            else => {
                var inports: i32 = 0;
                var outports: i32 = 0;
                for (node.ports.items) |port| {
                    if (port.incoming.items.len != 0) inports += 1;
                    if (port.outgoing.items.len != 0) outports += 1;
                }
                if (inports + outports == 0) {
                    ratio = 0.5;
                } else {
                    ratio = @as(f64, @floatFromInt(outports)) / @as(f64, @floatFromInt(inports + outports));
                }
            },
        }
        const size = layer.size;
        const node_size = node.size.x;
        var xpos = (size.x - node_size) * ratio;
        if (ratio > 0.5) {
            xpos -= max_right_margin * 2 * (ratio - 0.5);
        } else if (ratio < 0.5) {
            xpos += max_left_margin * 2 * (0.5 - ratio);
        }
        const left_margin = node.margin.left;
        if (xpos < left_margin) xpos = left_margin;
        const right_margin = node.margin.right;
        if (xpos > size.x - right_margin - node_size) xpos = size.x - right_margin - node_size;
        node.pos.x = xoffset + xpos;
    }
}

// LEdge.reverse(graph, true)
pub fn reverseEdge(e: *lg.LEdge) lg.Error!void {
    return reverseEdgeAdapt(e, true);
}

// LEdge.reverse(graph, adaptPorts)
pub fn reverseEdgeAdapt(e: *lg.LEdge, adapt_ports: bool) lg.Error!void {
    const old_source = e.source.?;
    const old_target = e.target.?;
    try e.setSource(null);
    try e.setTarget(null);
    if (adapt_ports and old_target.p.input_collect) {
        try e.setSource((try provideCollectorPort(old_target.owner.?, .output, .east)).?);
    } else {
        try e.setSource(old_target);
    }
    if (adapt_ports and old_source.p.output_collect) {
        try e.setTarget((try provideCollectorPort(old_source.owner.?, .input, .west)).?);
    } else {
        try e.setTarget(old_source);
    }
    for (e.labels.items) |label| {
        switch (label.p.edge_labels_placement) {
            .tail => label.p.edge_labels_placement = .head,
            .head => label.p.edge_labels_placement = .tail,
            .center => {},
        }
    }
    e.p.reversed = !e.p.reversed;
    std.mem.reverse(lg.Vec, e.bend_points.items);
}

// LNode.isInlineEdgeLabel
pub fn isInlineEdgeLabel(node: *const lg.LNode) bool {
    if (node.type != .label) return false;
    for (node.p.represented_labels.items) |l| if (!l.p.edge_labels_inline) return false;
    return true;
}

// LGraph.toNodeArray (each layer copied with LGraphUtil.toNodeArray)
pub fn toNodeArray(g: *const lg.LGraph) lg.Error![][]*lg.LNode {
    const out = try g.a.alloc([]*lg.LNode, g.layers.items.len);
    for (g.layers.items, 0..) |layer, i| out[i] = try g.a.dupe(*lg.LNode, layer.nodes.items);
    return out;
}

// LGraphUtil.getDirection
pub fn getDirection(g: *const lg.LGraph) lg.Direction {
    if (g.p.direction != .undefined) return g.p.direction;
    return if (g.p.aspect_ratio >= 1) .right else .down;
}

// LGraphUtil.isDescendant
pub fn isDescendant(child: *const lg.LNode, parent: *const lg.LNode) bool {
    var next = child.graph.?.parent_node;
    while (next) |cur| {
        if (cur == parent) return true;
        next = cur.graph.?.parent_node;
    }
    return false;
}

// LGraphUtil.changeCoordSystem
pub fn changeCoordSystem(point: *lg.Vec, old_graph: *const lg.LGraph, new_graph: *const lg.LGraph) void {
    if (old_graph == new_graph) return;
    var g = old_graph;
    while (true) {
        point.add(g.offset);
        const node = g.parent_node orelse break;
        point.x += g.padding.left;
        point.y += g.padding.top;
        point.add(node.pos);
        g = node.graph.?;
    }
    g = new_graph;
    while (true) {
        point.sub(g.offset);
        const node = g.parent_node orelse break;
        point.x -= g.padding.left;
        point.y -= g.padding.top;
        point.sub(node.pos);
        g = node.graph.?;
    }
}

// LGraphUtil.calcPortSide
pub fn calcPortSide(port: *const lg.LPort, direction: lg.Direction) lg.PortSide {
    const node = port.owner.?;
    const node_width = node.size.x;
    const node_height = node.size.y;
    if (node_width <= 0 and node_height <= 0) return .undefined;
    const xpos = port.pos.x;
    const ypos = port.pos.y;
    const width = port.size.x;
    const height = port.size.y;
    switch (direction) {
        .left, .right => {
            if (xpos < 0) return .west;
            if (xpos + width > node_width) return .east;
        },
        .up, .down => {
            if (ypos < 0) return .north;
            if (ypos + height > node_height) return .south;
        },
        .undefined => {},
    }
    const width_percent = (xpos + width / 2) / node_width;
    const height_percent = (ypos + height / 2) / node_height;
    if (width_percent + height_percent <= 1 and width_percent - height_percent <= 0) return .west;
    if (width_percent + height_percent >= 1 and width_percent - height_percent >= 0) return .east;
    if (height_percent < 0.5) return .north;
    return .south;
}

fn centerPoint(point: *lg.Vec, boundary: lg.Vec, side: lg.PortSide) void {
    switch (side) {
        .north => point.* = .{ .x = boundary.x / 2, .y = 0 },
        .east => point.* = .{ .x = boundary.x, .y = boundary.y / 2 },
        .south => point.* = .{ .x = boundary.x / 2, .y = boundary.y },
        .west => point.* = .{ .x = 0, .y = boundary.y / 2 },
        .undefined => {},
    }
}

// LGraphUtil.provideCollectorPort
pub fn provideCollectorPort(node: *lg.LNode, port_type: lg.PortType, side: lg.PortSide) lg.Error!?*lg.LPort {
    // SAFETY: set on every path before it is read
    var port: *lg.LPort = undefined;
    switch (port_type) {
        .input => {
            for (node.ports.items) |p| if (p.p.input_collect) return p;
            port = try lg.LPort.init(node.a);
            port.p.input_collect = true;
        },
        .output => {
            for (node.ports.items) |p| if (p.p.output_collect) return p;
            port = try lg.LPort.init(node.a);
            port.p.output_collect = true;
        },
        .undefined => return null,
    }
    try port.setNode(node);
    port.setSide(side);
    centerPoint(&port.pos, node.size, side);
    return port;
}

// LGraphUtil.createPort (hypernodes are never set)
pub fn createPort(node: *lg.LNode, end_point: ?lg.Vec, port_type: lg.PortType, g: *lg.LGraph) lg.Error!*lg.LPort {
    const direction = getDirection(g);
    if (g.p.merge_edges and !node.p.port_constraints.isSideFixed()) {
        const default_side = lg.PortSide.fromDirection(direction);
        return (try provideCollectorPort(node, port_type, if (port_type == .output) default_side else default_side.opposed())).?;
    }
    const port = try lg.LPort.init(node.a);
    try port.setNode(node);
    if (end_point) |ep| {
        port.pos.x = ep.x - node.pos.x;
        port.pos.y = ep.y - node.pos.y;
        port.pos.x = @max(0, @min(port.pos.x, node.size.x));
        port.pos.y = @max(0, @min(port.pos.y, node.size.y));
        port.setSide(calcPortSide(port, direction));
    } else {
        const default_side = lg.PortSide.fromDirection(direction);
        port.setSide(if (port_type == .output) default_side else default_side.opposed());
    }
    const side = port.side;
    switch (direction) {
        .left, .right => if (side == .north or side == .south) {
            g.p.graph_properties.north_south_ports = true;
        },
        .up, .down => if (side == .east or side == .west) {
            g.p.graph_properties.north_south_ports = true;
        },
        .undefined => {},
    }
    return port;
}

// LGraphUtil.initializePort; `border_offset_set` is LPort.getAllProperties().containsKey(PORT_BORDER_OFFSET)
pub fn initializePort(port: *lg.LPort, port_constraints: lg.PortConstraints, direction: lg.Direction, anchor_pos: ?lg.Vec, border_offset_set: bool) void {
    var port_side = port.side;
    if (port_side == .undefined and port_constraints.isSideFixed()) {
        port_side = calcPortSide(port, direction);
        port.setSide(port_side);
        if (!border_offset_set and port_side != .undefined and (port.pos.x != 0 or port.pos.y != 0)) {
            const node = port.owner.?;
            port.p.port_border_offset = switch (port_side) {
                .north => -(port.pos.y + port.size.y),
                .east => port.pos.x - node.size.x,
                .south => port.pos.y - node.size.y,
                .west => -(port.pos.x + port.size.x),
                .undefined => 0,
            };
        }
    }
    if (port_constraints.isRatioFixed()) {
        var ratio: f64 = 0;
        switch (port_side) {
            .north, .south => if (port.owner.?.size.x > 0) {
                ratio = port.pos.x / port.owner.?.size.x;
            },
            .east, .west => if (port.owner.?.size.y > 0) {
                ratio = port.pos.y / port.owner.?.size.y;
            },
            .undefined => {},
        }
        port.p.port_ratio_or_position = ratio;
    }
    const size = port.size;
    if (anchor_pos) |ap| {
        port.anchor = ap;
        port.explicitly_supplied_port_anchor = true;
    } else if (port_constraints.isSideFixed() and port_side != .undefined) {
        switch (port_side) {
            .north => port.anchor.x = size.x / 2,
            .east => {
                port.anchor.x = size.x;
                port.anchor.y = size.y / 2;
            },
            .south => {
                port.anchor.x = size.x / 2;
                port.anchor.y = size.y;
            },
            .west => port.anchor.y = size.y / 2,
            .undefined => {},
        }
    } else {
        port.anchor.x = size.x / 2;
        port.anchor.y = size.y / 2;
    }
}

// LGraphUtil.createExternalPortDummy. `holder` is the property holder Java passes (an LPort's or a fresh one);
// PORT_INDEX is never set by Mermaid, so the FIXED_ORDER index branch reads positions like the other orders.
pub fn createExternalPortDummy(holder: *lg.Props, port_constraints: lg.PortConstraints, port_side: lg.PortSide, net_flow: i64, port_node_size: ?lg.Vec, port_position: ?lg.Vec, port_size: lg.Vec, layout_direction: lg.Direction, g: *lg.LGraph) lg.Error!*lg.LNode {
    var final_side = port_side;
    const dummy = try lg.LNode.init(g.a, g);
    dummy.type = .external_port;
    dummy.p.ext_port_size = port_size;
    dummy.p.port_constraints = .fixed_pos;
    const border_offset = holder.port_border_offset;
    dummy.p.port_border_offset = border_offset;
    const dummy_port = try lg.LPort.init(g.a);
    try dummy_port.setNode(dummy);
    if (!port_constraints.isSideFixed()) {
        final_side = if (net_flow >= 0) lg.PortSide.fromDirection(layout_direction) else lg.PortSide.fromDirection(layout_direction).opposed();
        holder.port_side = final_side;
    }
    // SAFETY: set on every path before it is read
    var anchor: lg.Vec = undefined;
    var explicit_anchor = false;
    if (holder.port_anchor) |pa| {
        anchor = pa;
        explicit_anchor = true;
    } else {
        anchor = .{ .x = port_size.x / 2, .y = port_size.y / 2 };
    }
    switch (final_side) {
        .west => {
            dummy.p.layer_constraint = .first_separate;
            dummy.p.edge_constraint = .outgoing_only;
            dummy.size.y = port_size.y;
            if (border_offset < 0) dummy.size.x = -border_offset;
            dummy_port.setSide(.east);
            if (!explicit_anchor) anchor.x = port_size.x;
            anchor.x -= port_size.x;
        },
        .east => {
            dummy.p.layer_constraint = .last_separate;
            dummy.p.edge_constraint = .incoming_only;
            dummy.size.y = port_size.y;
            if (border_offset < 0) dummy.size.x = -border_offset;
            dummy_port.setSide(.west);
            if (!explicit_anchor) anchor.x = 0;
        },
        .north => {
            dummy.p.in_layer_constraint = .top;
            dummy.size.x = port_size.x;
            if (border_offset < 0) dummy.size.y = -border_offset;
            dummy_port.setSide(.south);
            if (!explicit_anchor) anchor.y = port_size.y;
            anchor.y -= port_size.y;
        },
        .south => {
            dummy.p.in_layer_constraint = .bottom;
            dummy.size.x = port_size.x;
            if (border_offset < 0) dummy.size.y = -border_offset;
            dummy_port.setSide(.north);
            if (!explicit_anchor) anchor.y = 0;
        },
        .undefined => {},
    }
    dummy_port.pos = anchor;
    dummy.p.port_anchor = anchor;
    if (port_constraints.isOrderFixed()) {
        var info: f64 = 0;
        switch (final_side) {
            .west, .east => {
                info = port_position.?.y;
                if (port_constraints.isRatioFixed()) info /= port_node_size.?.y;
            },
            .north, .south => {
                info = port_position.?.x;
                if (port_constraints.isRatioFixed()) info /= port_node_size.?.x;
            },
            .undefined => {},
        }
        dummy.p.port_ratio_or_position = info;
    }
    dummy.p.ext_port_side = final_side;
    return dummy;
}

// LGraphUtil.getExternalPortPosition
pub fn getExternalPortPosition(g: *const lg.LGraph, dummy: *lg.LNode, port_width: f64, port_height: f64) lg.Vec {
    var pos = dummy.pos;
    pos.x += dummy.size.x / 2.0;
    pos.y += dummy.size.y / 2.0;
    const off = dummy.p.port_border_offset;
    const size = g.size;
    const pad = g.padding;
    const go = g.offset;
    switch (dummy.p.ext_port_side) {
        .north => {
            pos.x += pad.left + go.x - (port_width / 2.0);
            pos.y = -port_height - off;
            dummy.pos.y = -(pad.top + off + go.y);
        },
        .east => {
            pos.x = size.x + pad.left + pad.right + off;
            pos.y += pad.top + go.y - (port_height / 2.0);
            dummy.pos.x = size.x + pad.right + off - go.x;
        },
        .south => {
            pos.x += pad.left + go.x - (port_width / 2.0);
            pos.y = size.y + pad.top + pad.bottom + off;
            dummy.pos.y = size.y + pad.bottom + off - go.y;
        },
        .west => {
            pos.x = -port_width - off;
            pos.y += pad.top + go.y - (port_height / 2.0);
            dummy.pos.x = -(pad.left + off + go.x);
        },
        .undefined => {},
    }
    return pos;
}

// LGraphUtil.offsetGraph
pub fn offsetGraph(g: *lg.LGraph, dx: f64, dy: f64) void {
    const off: lg.Vec = .{ .x = dx, .y = dy };
    for (g.layerless_nodes.items) |node| {
        node.pos.add(off);
        for (node.ports.items) |port| {
            for (port.outgoing.items) |e| {
                for (e.bend_points.items) |*b| b.add(off);
                for (e.p.junction_points.items) |*j| j.add(off);
                for (e.labels.items) |l| l.pos.add(off);
            }
        }
    }
}

// LGraphUtil.resizeNode (its float locals are plain doubles in elkjs)
pub fn resizeNode(node: *lg.LNode, new_size: lg.Vec, move_ports: bool, move_labels: bool) void {
    const old = node.size;
    const width_ratio = new_size.x / old.x;
    const height_ratio = new_size.y / old.y;
    const width_diff = new_size.x - old.x;
    const height_diff = new_size.y - old.y;
    if (move_ports) {
        const fixed = node.p.port_constraints == .fixed_pos;
        for (node.ports.items) |port| switch (port.side) {
            .north => if (!fixed) {
                port.pos.x *= width_ratio;
            },
            .east => {
                port.pos.x += width_diff;
                if (!fixed) port.pos.y *= height_ratio;
            },
            .south => {
                if (!fixed) port.pos.x *= width_ratio;
                port.pos.y += height_diff;
            },
            .west => if (!fixed) {
                port.pos.y *= height_ratio;
            },
            .undefined => {},
        };
    }
    if (move_labels) {
        for (node.labels.items) |label| {
            const midx = label.pos.x + label.size.x / 2;
            const midy = label.pos.y + label.size.y / 2;
            const wp = midx / old.x;
            const hp = midy / old.y;
            if (wp + hp >= 1) {
                if (wp - hp > 0 and midy >= 0) {
                    label.pos.x += width_diff;
                    label.pos.y += height_diff * hp;
                } else if (wp - hp < 0 and midx >= 0) {
                    label.pos.x += width_diff * wp;
                    label.pos.y += height_diff;
                }
            }
        }
    }
    node.size = new_size;
    node.p.node_size_constraints = .{};
}
