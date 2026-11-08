const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const gu = @import("../graph_util.zig");
const spacings = @import("../spacings.zig");
const nls = @import("node_label_size.zig");

// The ELK element an LGraph element was made from; InternalProperties.ORIGIN holds `.src` = an index into `refs`.
pub const ElkRef = union(enum) {
    node: *eg.ElkNode,
    port: *eg.ElkPort,
    edge: *eg.ElkEdge,
    label: *eg.ElkLabel,
};

// ElkGraphImporter.
// shortcut: explicit ELK ports (external ports, port labels, transformPort) and edges attached to ports are not
// imported; Mermaid's ELK graphs only connect nodes. Port them from ElkGraphImporter if that changes.
pub const Importer = struct {
    a: std.mem.Allocator,
    refs: std.ArrayList(ElkRef) = .empty,
    node_map: std.AutoHashMapUnmanaged(*const eg.ElkNode, *lg.LNode) = .empty,

    pub fn origin(self: *Importer, r: ElkRef) lg.Error!lg.Origin {
        try self.refs.append(self.a, r);
        return .{ .src = @intCast(self.refs.items.len - 1) };
    }

    pub fn ref(self: *const Importer, o: lg.Origin) ?ElkRef {
        return switch (o) {
            .src => |i| self.refs.items[i],
            else => null,
        };
    }

    pub fn elkNodeOf(self: *const Importer, o: lg.Origin) ?*eg.ElkNode {
        const r = self.ref(o) orelse return null;
        return if (r == .node) r.node else null;
    }

    pub fn importGraph(self: *Importer, elkgraph: *eg.ElkNode) lg.Error!*lg.LGraph {
        const top = try self.createLGraph(elkgraph);
        if (shouldCalculateMinimumGraphSize(elkgraph)) calculateMinimumGraphSize(elkgraph, top);
        if (elkgraph.opts.spacing_base_value) |base| spacings.withBaseValue(&top.p.spacing, base, &elkgraph.opts);
        if (elkgraph.hierarchyHandling() == .include_children) {
            try self.importHierarchicalGraph(elkgraph, top);
        } else {
            try self.importFlatGraph(elkgraph, top);
        }
        return top;
    }

    fn importFlatGraph(self: *Importer, elkgraph: *eg.ElkNode, g: *lg.LGraph) lg.Error!void {
        var index: i32 = 0;
        for (elkgraph.children.items) |child| {
            if (child.opts.no_layout orelse false) continue;
            if (needsModelOrder(child)) {
                child.opts.model_order = index;
                index += 1;
            }
            _ = try self.transformNode(child, g);
        }
        index = 0;
        for (elkgraph.contained_edges.items) |e| {
            if (needsModelOrderBasedOnParent(elkgraph)) {
                e.opts.model_order = index;
                index += 1;
            }
            const source = e.sourceNode();
            const target = e.targetNode();
            const inside_enabled = source.opts.inside_self_loops_activate orelse false;
            const to_be_laid_out = !(e.opts.no_layout orelse false);
            const inside_self_loop = inside_enabled and e.isSelfloop() and (e.opts.inside_self_loops_yo orelse false);
            const connects_siblings = source.parent == elkgraph and source.parent == target.parent;
            const connects_to_graph = (source.parent == elkgraph and target == elkgraph) != (target.parent == elkgraph and source == elkgraph);
            if (to_be_laid_out and !inside_self_loop and (connects_to_graph or connects_siblings)) {
                _ = try self.transformEdge(e, elkgraph, g);
            }
        }
        if (elkgraph.parent) |p| {
            for (p.contained_edges.items) |e| {
                const source = e.sourceNode();
                if (source == elkgraph and e.isSelfloop()) {
                    if ((source.opts.inside_self_loops_activate orelse false) and (e.opts.inside_self_loops_yo orelse false)) {
                        _ = try self.transformEdge(e, elkgraph, g);
                    }
                }
            }
        }
    }

    fn importHierarchicalGraph(self: *Importer, elkgraph: *eg.ElkNode, g: *lg.LGraph) lg.Error!void {
        var queue: std.ArrayList(*eg.ElkNode) = .empty;
        var head: usize = 0;
        const parent_direction = g.p.direction;
        var index: i32 = 0;
        try queue.appendSlice(self.a, elkgraph.children.items);
        while (head < queue.items.len) {
            const elknode = queue.items[head];
            head += 1;
            if (needsModelOrder(elknode)) {
                elknode.opts.model_order = index;
                index += 1;
            }
            if (elknode.opts.no_layout orelse false) continue;
            const has_children = elknode.children.items.len > 0;
            const has_inside_self_loops = hasInsideSelfLoops(elknode);
            const hierarchy_enabled = elknode.hierarchyHandling() == .include_children;
            const uses_layered = usesElkLayered(elknode);
            var nested: ?*lg.LGraph = null;
            if (uses_layered and hierarchy_enabled and (has_children or has_inside_self_loops)) {
                const ng = try self.createLGraph(elknode);
                ng.p.direction = parent_direction;
                if (elknode.opts.spacing_base_value) |base| spacings.withBaseValue(&ng.p.spacing, base, &elknode.opts);
                if (shouldCalculateMinimumGraphSize(elknode)) calculateMinimumGraphSize(elknode, ng);
                nested = ng;
            }
            var parent_lgraph = g;
            if (elknode.parent) |p| if (self.node_map.get(p)) |pl| {
                parent_lgraph = pl.nested_graph.?;
            };
            const lnode = try self.transformNode(elknode, parent_lgraph);
            if (nested) |ng| {
                lnode.nested_graph = ng;
                ng.parent_node = lnode;
                try queue.appendSlice(self.a, elknode.children.items);
            }
        }

        index = 0;
        queue.clearRetainingCapacity();
        head = 0;
        try queue.append(self.a, elkgraph);
        while (head < queue.items.len) {
            const graph_node = queue.items[head];
            head += 1;
            for (graph_node.contained_edges.items) |e| {
                if (needsModelOrderBasedOnParent(elkgraph)) {
                    e.opts.model_order = index;
                    index += 1;
                }
                const source = e.sourceNode();
                const target = e.targetNode();
                if ((e.opts.no_layout orelse false) or (source.opts.no_layout orelse false) or (target.opts.no_layout orelse false)) continue;
                const inside_self_loop = e.isSelfloop() and (source.opts.inside_self_loops_activate orelse false) and (e.opts.inside_self_loops_yo orelse false);
                var parent_elk = graph_node;
                if (inside_self_loop or eg.isDescendant(target, source)) {
                    parent_elk = source;
                } else if (eg.isDescendant(source, target)) {
                    parent_elk = target;
                }
                var parent_lgraph = g;
                if (self.node_map.get(parent_elk)) |pl| parent_lgraph = pl.nested_graph.?;
                const le = try self.transformEdge(e, parent_elk, parent_lgraph) orelse continue;
                le.p.coordinate_system_origin = self.findCoordinateSystemOrigin(e, elkgraph, g);
            }
            if (graph_node.hierarchyHandling() == .include_children) {
                for (graph_node.children.items) |child| {
                    if (usesElkLayered(child) and child.hierarchyHandling() == .include_children) {
                        try queue.append(self.a, child);
                    }
                }
            }
        }
    }

    fn findCoordinateSystemOrigin(self: *Importer, e: *eg.ElkEdge, top_elk: *eg.ElkNode, top: *lg.LGraph) ?*lg.LGraph {
        const source = e.sourceNode();
        const target = e.targetNode();
        if (source.parent == target.parent) return null;
        if (eg.isDescendant(target, source)) return null;
        const o = e.container orelse return null;
        if (o == top_elk) return top;
        if (self.node_map.get(o)) |ln| if (ln.nested_graph) |ng| return ng;
        return null;
    }

    fn createLGraph(self: *Importer, elkgraph: *eg.ElkNode) lg.Error!*lg.LGraph {
        const g = try lg.LGraph.init(self.a);
        elkgraph.opts.applyTo(&g.p);
        if (g.p.direction == .undefined) g.p.direction = gu.getDirection(g);
        g.p.origin = try self.origin(.{ .node = elkgraph });
        g.p.graph_properties = .{};
        const label_padding = nls.insideNodeLabelPadding(elkgraph);
        const pad = g.p.padding;
        g.padding.top += pad.top;
        g.padding.left += pad.left;
        g.padding.bottom += pad.bottom;
        g.padding.right += pad.right;
        g.padding.top += label_padding.top;
        g.padding.left += label_padding.left;
        g.padding.bottom += label_padding.bottom;
        g.padding.right += label_padding.right;
        return g;
    }

    fn transformNode(self: *Importer, elknode: *eg.ElkNode, g: *lg.LGraph) lg.Error!*lg.LNode {
        const lnode = try lg.LNode.init(self.a, g);
        elknode.opts.applyTo(&lnode.p);
        lnode.p.origin = try self.origin(.{ .node = elknode });
        lnode.p.debug_id = elknode.id;
        lnode.size = .{ .x = elknode.width, .y = elknode.height };
        lnode.pos = .{ .x = elknode.x, .y = elknode.y };
        try g.layerless_nodes.append(self.a, lnode);
        try self.node_map.put(self.a, elknode, lnode);
        if (elknode.children.items.len > 0 or (elknode.opts.inside_self_loops_activate orelse false)) lnode.p.compound_node = true;
        if (lnode.p.port_constraints == .undefined) {
            lnode.p.port_constraints = .free;
        } else if (lnode.p.port_constraints != .free) {
            g.p.graph_properties.non_free_ports = true;
        }
        for (elknode.labels.items) |l| {
            if ((l.opts.no_layout orelse false) or l.text.len == 0) continue;
            try lnode.labels.append(self.a, try self.transformLabel(l));
        }
        return lnode;
    }

    fn transformEdge(self: *Importer, e: *eg.ElkEdge, elkparent: *eg.ElkNode, g: *lg.LGraph) lg.Error!?*lg.LEdge {
        const src_node = e.sourceNode();
        const tgt_node = e.targetNode();
        const section: ?*eg.ElkEdgeSection = if (e.sections.items.len > 0) e.sections.items[0] else null;
        // Java throws UnsupportedGraphException here; Mermaid turns such subgraphs back into INCLUDE_CHILDREN
        const source_lnode = self.node_map.get(src_node) orelse return null;
        const target_lnode = self.node_map.get(tgt_node) orelse return null;
        const le = try lg.LEdge.init(self.a);
        e.opts.applyTo(&le.p);
        le.p.origin = try self.origin(.{ .edge = e });
        le.p.junction_points = .empty;
        if (source_lnode == target_lnode) g.p.graph_properties.self_loops = true;

        var source_point: ?lg.Vec = null;
        var source_type: lg.PortType = .output;
        if (section) |sec| if (source_lnode.p.port_constraints.isSideFixed()) {
            var sp = sec.start;
            eg.toAbsolute(&sp, e.container);
            eg.toRelative(&sp, elkparent);
            if (eg.isDescendant(tgt_node, src_node)) {
                source_type = .input;
                sp.add(source_lnode.pos);
            }
            source_point = sp;
        };
        const source_port = try gu.createPort(source_lnode, source_point, source_type, g);

        var target_point: ?lg.Vec = null;
        if (section) |sec| if (target_lnode.p.port_constraints.isSideFixed()) {
            var tp = sec.end;
            eg.toAbsolute(&tp, e.container);
            eg.toRelative(&tp, elkparent);
            target_point = tp;
        };
        const target_port = try gu.createPort(target_lnode, target_point, .input, target_lnode.graph.?);

        try le.setSource(source_port);
        try le.setTarget(target_port);
        if (source_port.incoming.items.len > 1 or source_port.outgoing.items.len > 1 or
            target_port.incoming.items.len > 1 or target_port.outgoing.items.len > 1)
        {
            g.p.graph_properties.hyperedges = true;
        }
        for (e.labels.items) |l| {
            if ((l.opts.no_layout orelse false) or l.text.len == 0) continue;
            const ll = try self.transformLabel(l);
            try le.labels.append(self.a, ll);
            switch (ll.p.edge_labels_placement) {
                .head, .tail => g.p.graph_properties.end_labels = true,
                .center => {
                    g.p.graph_properties.center_labels = true;
                    ll.p.edge_labels_placement = .center;
                },
            }
        }
        return le;
    }

    fn transformLabel(self: *Importer, l: *eg.ElkLabel) lg.Error!*lg.LLabel {
        const ll = try lg.LLabel.init(self.a);
        ll.text = l.text;
        l.opts.applyTo(&ll.p);
        ll.p.origin = try self.origin(.{ .label = l });
        ll.size = .{ .x = l.width, .y = l.height };
        ll.pos = .{ .x = l.x, .y = l.y };
        return ll;
    }
};

fn usesElkLayered(n: *const eg.ElkNode) bool {
    const alg = n.opts.algorithm orelse return true;
    return std.mem.endsWith(u8, "org.eclipse.elk.layered", alg);
}

fn hasInsideSelfLoops(n: *const eg.ElkNode) bool {
    if (!(n.opts.inside_self_loops_activate orelse false)) return false;
    for (n.outgoing_edges.items) |e| {
        if (e.isSelfloop() and (e.opts.inside_self_loops_yo orelse false)) return true;
    }
    return false;
}

fn needsModelOrder(child: *const eg.ElkNode) bool {
    // CONSIDER_MODEL_ORDER_NO_MODEL_ORDER is never set
    return needsModelOrderBasedOnParent(child.parent.?);
}

fn needsModelOrderBasedOnParent(g: *const eg.ElkNode) bool {
    const o = &g.opts;
    const cb = o.cycle_breaking orelse .greedy;
    const lay = o.layering orelse .network_simplex;
    return (o.consider_model_order orelse .none) != .none or cb == .model_order or cb == .greedy_model_order or
        (o.force_node_model_order orelse false) or lay == .bf_model_order or lay == .df_model_order;
}

fn shouldCalculateMinimumGraphSize(n: *const eg.ElkNode) bool {
    const sc = n.opts.node_size_constraints orelse return false;
    return sc.ports or sc.port_labels or sc.node_labels or sc.minimum_size;
}

// ElkGraphImporter.calculateMinimumGraphSize. The size constraint set and the minimum size vector are the same
// objects on the ELK node and the LGraph in Java, so both are updated.
fn calculateMinimumGraphSize(elkgraph: *eg.ElkNode, g: *lg.LGraph) void {
    if (elkgraph.parent == null) return;
    if ((elkgraph.opts.port_constraints orelse .undefined) == .undefined) elkgraph.opts.port_constraints = .free;
    const min = nls.minimumNodeSize(elkgraph);
    g.p.node_size_constraints.minimum_size = true;
    if (elkgraph.opts.node_size_constraints) |*sc| sc.minimum_size = true;
    g.p.node_size_minimum.x = @max(min.x, g.p.node_size_minimum.x);
    g.p.node_size_minimum.y = @max(min.y, g.p.node_size_minimum.y);
    if (elkgraph.opts.node_size_minimum != null) elkgraph.opts.node_size_minimum = g.p.node_size_minimum;
}
