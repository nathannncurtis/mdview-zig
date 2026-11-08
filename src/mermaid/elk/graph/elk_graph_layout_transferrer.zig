const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const gu = @import("../graph_util.zig");
const Importer = @import("elk_graph_importer.zig").Importer;

// ElkGraphLayoutTransferrer.applyLayout
pub fn applyLayout(imp: *const Importer, g: *lg.LGraph) lg.Error!void {
    const parent_elk = imp.elkNodeOf(g.p.origin) orelse return;
    const parent_lnode = g.parent_node;
    var offset = g.offset;
    offset.x += g.padding.left;
    offset.y += g.padding.top;
    if ((parent_elk.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true }).compute_padding) {
        parent_elk.opts.padding = g.padding;
    }

    var edges: std.ArrayList(*lg.LEdge) = .empty;
    for (g.layerless_nodes.items) |lnode| {
        if (imp.elkNodeOf(lnode.p.origin) != null) try applyNodeLayout(imp, lnode, offset);
        for (lnode.ports.items) |port| {
            for (port.outgoing.items) |e| {
                if (!gu.isDescendant(e.target.?.owner.?, lnode)) try edges.append(g.a, e);
            }
        }
    }
    if (parent_lnode) |pl| {
        for (pl.ports.items) |port| {
            for (port.outgoing.items) |e| {
                if (gu.isDescendant(e.target.?.owner.?, pl)) try edges.append(g.a, e);
            }
        }
    }
    for (edges.items) |e| try applyEdgeLayout(imp, e, offset);
    applyParentNodeLayout(parent_elk, g);
    for (g.layerless_nodes.items) |lnode| {
        if (lnode.nested_graph) |ng| try applyLayout(imp, ng);
    }
}

fn applyNodeLayout(imp: *const Importer, lnode: *lg.LNode, offset: lg.Vec) lg.Error!void {
    const elknode = imp.elkNodeOf(lnode.p.origin).?;
    elknode.x = lnode.pos.x + offset.x;
    elknode.y = lnode.pos.y + offset.y;
    const sc = elknode.opts.node_size_constraints orelse lg.SizeConstraint{};
    // the NETWORK_SIMPLEX node flexibility branch is unreachable with BRANDES_KOEPF placement
    if (sc.ports or sc.port_labels or sc.node_labels or sc.minimum_size or lnode.nested_graph != null) {
        elknode.width = lnode.size.x;
        elknode.height = lnode.size.y;
    }
    const node_has_placement = @as(u9, @bitCast(lnode.p.node_labels_placement)) != 0;
    for (lnode.labels.items) |ll| {
        if (node_has_placement or @as(u9, @bitCast(ll.p.node_labels_placement)) != 0) {
            const r = imp.ref(ll.p.origin) orelse continue;
            if (r != .label) continue;
            r.label.width = ll.size.x;
            r.label.height = ll.size.y;
            r.label.x = ll.pos.x;
            r.label.y = ll.pos.y;
        }
    }
}

fn applyEdgeLayout(imp: *const Importer, le: *lg.LEdge, offset: lg.Vec) lg.Error!void {
    const r = imp.ref(le.p.origin) orelse return;
    if (r != .edge) return;
    const elkedge = r.edge;
    const a = le.a;
    var edge_offset = offset;
    edge_offset.add(calculateHierarchicalOffset(le));

    var chain: std.ArrayList(lg.Vec) = .empty;
    // SAFETY: set on every path before it is read
    var source_point: lg.Vec = undefined;
    if (gu.isDescendant(le.target.?.owner.?, le.source.?.owner.?)) {
        const sp = le.source.?;
        source_point = .{ .x = sp.pos.x + sp.anchor.x, .y = sp.pos.y + sp.anchor.y };
        source_point.sub(offset);
    } else {
        source_point = le.source.?.absoluteAnchor();
    }
    try chain.append(a, source_point);
    try chain.appendSlice(a, le.bend_points.items);
    var target_point = le.target.?.absoluteAnchor();
    if (le.p.target_offset) |to| target_point.add(to);
    try chain.append(a, target_point);
    for (chain.items) |*p| p.add(edge_offset);
    // LEdge.getBendPoints() is the chain itself in Java, so the edge keeps the end points too
    le.bend_points = chain;

    // ElkGraphUtil.firstEdgeSection(edge, true, true) + ElkUtil.applyVectorChain
    const section = if (elkedge.sections.items.len == 0) try eg.createEdgeSection(a, elkedge) else elkedge.sections.items[0];
    elkedge.sections.shrinkRetainingCapacity(1);
    section.incoming_shape = elkedge.sources.items[0];
    section.outgoing_shape = elkedge.targets.items[0];
    section.start = chain.items[0];
    section.end = chain.items[chain.items.len - 1];
    section.bend_points = .empty;
    try section.bend_points.appendSlice(a, chain.items[1 .. chain.items.len - 1]);

    for (le.labels.items) |ll| {
        const lr = imp.ref(ll.p.origin) orelse continue;
        if (lr != .label) continue;
        lr.label.width = ll.size.x;
        lr.label.height = ll.size.y;
        lr.label.x = ll.pos.x + edge_offset.x;
        lr.label.y = ll.pos.y + edge_offset.y;
    }
    elkedge.junction_points = .empty;
    for (le.p.junction_points.items) |*jp| {
        jp.add(edge_offset);
        try elkedge.junction_points.append(a, jp.*);
    }
}

fn calculateHierarchicalOffset(le: *const lg.LEdge) lg.Vec {
    const target_cs = le.p.coordinate_system_origin orelse return .{};
    var result: lg.Vec = .{};
    var cur = le.source.?.owner.?.graph.?;
    while (cur != target_cs) {
        const rep = cur.parent_node.?;
        cur = rep.graph.?;
        result.add(rep.pos);
        result.add(cur.offset);
        result.x += cur.padding.left;
        result.y += cur.padding.top;
    }
    return result;
}

fn applyParentNodeLayout(elknode: *eg.ElkNode, g: *lg.LGraph) void {
    const sc = elknode.opts.node_size_constraints orelse lg.SizeConstraint{};
    if (g.parent_node == null) {
        const actual = g.actualSize();
        if (g.p.graph_properties.external_ports) {
            elknode.opts.port_constraints = .fixed_pos;
            resizeElkNode(elknode, actual.x, actual.y, false, true);
        } else if (!(elknode.opts.node_size_fixed_graph_size orelse false)) {
            resizeElkNode(elknode, actual.x, actual.y, true, true);
        }
    }
    elknode.opts.node_size_constraints = if (sc.port_labels) lg.SizeConstraint{ .port_labels = true } else lg.SizeConstraint{};
}

// ElkUtil.resizeNode; ELK ports are not modelled (see the importer), so only labels move
pub fn resizeElkNode(n: *eg.ElkNode, new_width: f64, new_height: f64, move_ports: bool, move_labels: bool) void {
    _ = move_ports;
    const old: lg.Vec = .{ .x = n.width, .y = n.height };
    var ns: lg.Vec = .{};
    const sc = n.opts.node_size_constraints orelse lg.SizeConstraint{};
    if (sc.minimum_size) {
        const so = n.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true };
        ns = n.opts.node_size_minimum orelse lg.Vec{};
        if (so.default_minimum_size) {
            if (ns.x <= 0) ns.x = 20;
            if (ns.y <= 0) ns.y = 20;
        }
    }
    ns.x = @max(ns.x, new_width);
    ns.y = @max(ns.y, new_height);
    const width_diff = ns.x - old.x;
    const height_diff = ns.y - old.y;
    n.width = ns.x;
    n.height = ns.y;
    if (move_labels) {
        for (n.labels.items) |l| {
            const midx = l.x + l.width / 2;
            const midy = l.y + l.height / 2;
            const wp = midx / old.x;
            const hp = midy / old.y;
            if (wp + hp >= 1) {
                if (wp - hp > 0 and midy >= 0) {
                    l.x += width_diff;
                    l.y += height_diff * hp;
                } else if (wp - hp < 0 and midx >= 0) {
                    l.x += width_diff * wp;
                    l.y += height_diff;
                }
            }
        }
    }
    n.opts.node_size_constraints = .{};
}
