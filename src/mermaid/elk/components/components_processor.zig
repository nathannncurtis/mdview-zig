const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

// ComponentsProcessor + SimpleRowGraphPlacer; the group placers need external ports, which flat Mermaid runs lack
pub fn split(g: *lg.LGraph) lg.Error![]*lg.LGraph {
    const a = g.a;
    var result: std.ArrayList(*lg.LGraph) = .empty;
    const ext_ports = g.p.graph_properties.external_ports;
    if (g.p.separate_connected_components and (!g.p.port_constraints.isOrderFixed() or !ext_ports)) {
        for (g.layerless_nodes.items) |n| n.id = 0;
        for (g.layerless_nodes.items) |n| {
            if (n.id != 0) continue;
            const ng = try lg.LGraph.init(a);
            ng.p = g.p;
            ng.padding = g.padding;
            ng.p.node_size_minimum = .{};
            try dfs(n, ng);
            try result.append(a, ng);
        }
    } else {
        try result.append(a, g);
    }
    return result.items;
}

fn dfs(node: *lg.LNode, ng: *lg.LGraph) lg.Error!void {
    if (node.id != 0) return;
    node.id = 1;
    try ng.layerless_nodes.append(ng.a, node);
    node.graph = ng;
    if (node.type == .external_port) switch (node.p.ext_port_side) {
        .north => ng.p.ext_port_connections.north = true,
        .east => ng.p.ext_port_connections.east = true,
        .south => ng.p.ext_port_connections.south = true,
        .west => ng.p.ext_port_connections.west = true,
        .undefined => {},
    };
    for (node.ports.items) |p| {
        for (p.incoming.items) |e| try dfs(e.source.?.owner.?, ng);
        for (p.outgoing.items) |e| try dfs(e.target.?.owner.?, ng);
    }
}

fn moveGraph(dest: *lg.LGraph, src: *lg.LGraph, dx: f64, dy: f64) lg.Error!void {
    src.offset.x += dx;
    src.offset.y += dy;
    const off = src.offset;
    for (src.layerless_nodes.items) |node| {
        node.pos.add(off);
        for (node.ports.items) |port| {
            for (port.outgoing.items) |e| {
                for (e.bend_points.items) |*b| b.add(off);
                for (e.p.junction_points.items) |*j| j.add(off);
                for (e.labels.items) |l| l.pos.add(off);
            }
        }
        try dest.layerless_nodes.append(dest.a, node);
        node.graph = dest;
    }
}

// copyProperties back onto the target: the components had NODE_SIZE_MINIMUM removed, so the target keeps its own
fn copyBack(target: *lg.LGraph, src: *const lg.LGraph) void {
    const min = target.p.node_size_minimum;
    target.p = src.p;
    target.p.node_size_minimum = min;
}

pub fn combine(components: []*lg.LGraph, target: *lg.LGraph) lg.Error!void {
    if (components.len == 1) {
        const src = components[0];
        if (src != target) {
            target.layerless_nodes.clearRetainingCapacity();
            try moveGraph(target, src, 0, 0);
            copyBack(target, src);
            target.padding = src.padding;
            target.size = src.size;
        }
        return;
    }
    if (components.len == 0) {
        target.layerless_nodes.clearRetainingCapacity();
        target.size = .{};
        return;
    }
    // sortComponents: node priorities are all 0, so the order is by area, smallest first (stable)
    std.mem.sort(*lg.LGraph, components, {}, struct {
        fn lt(_: void, g1: *lg.LGraph, g2: *lg.LGraph) bool {
            return g1.size.x * g1.size.y < g2.size.x * g2.size.y;
        }
    }.lt);
    const first = components[0];
    target.layerless_nodes.clearRetainingCapacity();
    copyBack(target, first);
    var max_row_width: f64 = 0;
    var total_area: f64 = 0;
    for (components) |c| {
        max_row_width = @max(max_row_width, c.size.x);
        total_area += c.size.x * c.size.y;
    }
    max_row_width = @max(max_row_width, @sqrt(total_area) * target.p.aspect_ratio);
    const spacing = target.p.spacing.component_component;
    var xpos: f64 = 0;
    var ypos: f64 = 0;
    var highest: f64 = 0;
    var broadest: f64 = spacing;
    for (components) |c| {
        const size = c.size;
        if (xpos + size.x > max_row_width) {
            xpos = 0;
            ypos += highest + spacing;
            highest = 0;
        }
        gu.offsetGraph(c, xpos + c.offset.x, ypos + c.offset.y);
        c.offset = .{};
        broadest = @max(broadest, xpos + size.x);
        highest = @max(highest, size.y);
        xpos += size.x + spacing;
    }
    target.size = .{ .x = broadest, .y = ypos + highest };
    for (components) |c| try moveGraph(target, c, 0, 0);
}
