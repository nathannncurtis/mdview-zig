const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");
const che = @import("cross_hierarchy_edge.zig");
const CrossHierarchyEdge = che.CrossHierarchyEdge;
const CrossHierarchyMap = che.CrossHierarchyMap;

// CompoundGraphPreprocessor. Port labels and inside self loops are not reachable from Mermaid (no ports with
// labels, insideSelfLoops never activated) and are left out.
const ExternalPort = struct {
    orig_edges: std.ArrayList(*lg.LEdge) = .empty,
    new_edge: *lg.LEdge,
    dummy_node: *lg.LNode,
    dummy_port: *lg.LPort,
    type: lg.PortType,
    exported: bool,
};

const Pre = struct {
    a: std.mem.Allocator,
    map: CrossHierarchyMap = .{},
    // dummyNodeMap; a HashMap in Java, only used for lookups and order-independent updates
    dummy_keys: std.ArrayList(*lg.LPort) = .empty,
    dummy_vals: std.ArrayList(*lg.LNode) = .empty,

    fn dummyGet(self: *Pre, p: *lg.LPort) ?*lg.LNode {
        for (self.dummy_keys.items, 0..) |k, i| if (k == p) return self.dummy_vals.items[i];
        return null;
    }
    fn dummyPut(self: *Pre, p: *lg.LPort, n: *lg.LNode) lg.Error!void {
        try self.dummy_keys.append(self.a, p);
        try self.dummy_vals.append(self.a, n);
    }

    fn transformHierarchyEdges(self: *Pre, g: *lg.LGraph, parent_node: ?*lg.LNode) lg.Error![]*ExternalPort {
        var contained: std.ArrayList(*ExternalPort) = .empty;
        for (g.layerless_nodes.items) |node| {
            const nested = node.nested_graph orelse continue;
            try contained.appendSlice(self.a, try self.transformHierarchyEdges(nested, node));
            if (nested.p.graph_properties.external_ports) {
                const pc = node.p.port_constraints;
                for (node.ports.items) |port| {
                    if (self.dummyGet(port) == null) {
                        const d = try gu.createExternalPortDummy(&port.p, pc, port.side, -port.netFlow(), null, lg.Vec{}, port.size, nested.p.direction, nested);
                        d.p.origin = .{ .port = port };
                        try self.dummyPut(port, d);
                        try nested.layerless_nodes.append(self.a, d);
                    }
                }
            }
        }
        var exported: std.ArrayList(*ExternalPort) = .empty;
        try self.processInnerHierarchicalEdgeSegments(g, parent_node, contained.items, &exported);
        if (parent_node) |pn| try self.processOuterHierarchicalEdgeSegments(g, pn, &exported);
        return exported.items;
    }

    fn processInnerHierarchicalEdgeSegments(self: *Pre, g: *lg.LGraph, parent_node: ?*lg.LNode, contained: []*ExternalPort, exported: *std.ArrayList(*ExternalPort)) lg.Error!void {
        var created: std.ArrayList(*ExternalPort) = .empty;
        for (contained) |ext| {
            var current: ?*ExternalPort = null;
            if (ext.type == .output) {
                for (ext.orig_edges.items) |out_edge| {
                    const target_node = out_edge.target.?.owner.?;
                    if (target_node.graph.? == g) {
                        try self.connectChild(g, ext, out_edge, ext.dummy_port, out_edge.target.?);
                    } else if (parent_node == null or gu.isDescendant(target_node, parent_node.?)) {
                        try self.connectSiblings(g, ext, contained, out_edge);
                    } else {
                        const n = try self.introduceHierarchicalEdgeSegment(g, parent_node.?, out_edge, ext.dummy_port, .output, current);
                        if (n != current) try created.append(self.a, n);
                        if (n.exported) current = n;
                    }
                }
            } else {
                for (ext.orig_edges.items) |in_edge| {
                    const source_node = in_edge.source.?.owner.?;
                    if (source_node.graph.? == g) {
                        try self.connectChild(g, ext, in_edge, in_edge.source.?, ext.dummy_port);
                    } else if (parent_node == null or gu.isDescendant(source_node, parent_node.?)) {
                        continue;
                    } else {
                        const n = try self.introduceHierarchicalEdgeSegment(g, parent_node.?, in_edge, ext.dummy_port, .input, current);
                        if (n != current) try created.append(self.a, n);
                        if (n.exported) current = n;
                    }
                }
            }
        }
        try self.addCreated(g, created.items, exported);
    }

    fn addCreated(self: *Pre, g: *lg.LGraph, created: []*ExternalPort, exported: *std.ArrayList(*ExternalPort)) lg.Error!void {
        for (created) |ext| {
            if (std.mem.indexOfScalar(*lg.LNode, g.layerless_nodes.items, ext.dummy_node) == null) {
                try g.layerless_nodes.append(self.a, ext.dummy_node);
            }
            if (ext.exported) try exported.append(self.a, ext);
        }
    }

    fn connectChild(self: *Pre, g: *lg.LGraph, ext: *ExternalPort, orig: *lg.LEdge, source: *lg.LPort, target: *lg.LPort) lg.Error!void {
        const d = try createDummyEdge(self.a, orig);
        try d.setSource(source);
        try d.setTarget(target);
        try self.map.put(self.a, orig, .{ .edge = d, .graph = g, .type = ext.type });
    }

    fn connectSiblings(self: *Pre, g: *lg.LGraph, out_port: *ExternalPort, contained: []*ExternalPort, orig: *lg.LEdge) lg.Error!void {
        var target_ext: ?*ExternalPort = null;
        for (contained) |e2| {
            if (e2 != out_port and std.mem.indexOfScalar(*lg.LEdge, e2.orig_edges.items, orig) != null) {
                target_ext = e2;
                break;
            }
        }
        const d = try createDummyEdge(self.a, orig);
        try d.setSource(out_port.dummy_port);
        try d.setTarget(target_ext.?.dummy_port);
        try self.map.put(self.a, orig, .{ .edge = d, .graph = g, .type = out_port.type });
    }

    fn processOuterHierarchicalEdgeSegments(self: *Pre, g: *lg.LGraph, parent_node: *lg.LNode, exported: *std.ArrayList(*ExternalPort)) lg.Error!void {
        var created: std.ArrayList(*ExternalPort) = .empty;
        for (g.layerless_nodes.items) |child| {
            for (child.ports.items) |child_port| {
                var cur_out: ?*ExternalPort = null;
                const outs = try self.a.dupe(*lg.LEdge, child_port.outgoing.items);
                for (outs) |out_edge| {
                    if (!gu.isDescendant(out_edge.target.?.owner.?, parent_node)) {
                        const n = try self.introduceHierarchicalEdgeSegment(g, parent_node, out_edge, out_edge.source.?, .output, cur_out);
                        if (n != cur_out) try created.append(self.a, n);
                        if (n.exported) cur_out = n;
                    }
                }
                var cur_in: ?*ExternalPort = null;
                const ins = try self.a.dupe(*lg.LEdge, child_port.incoming.items);
                for (ins) |in_edge| {
                    if (!gu.isDescendant(in_edge.source.?.owner.?, parent_node)) {
                        const n = try self.introduceHierarchicalEdgeSegment(g, parent_node, in_edge, in_edge.target.?, .input, cur_in);
                        if (n != cur_in) try created.append(self.a, n);
                        if (n.exported) cur_in = n;
                    }
                }
            }
        }
        try self.addCreated(g, created.items, exported);
    }

    fn introduceHierarchicalEdgeSegment(self: *Pre, g: *lg.LGraph, parent_node: *lg.LNode, orig: *lg.LEdge, opposite: *lg.LPort, port_type: lg.PortType, default_ext: ?*ExternalPort) lg.Error!*ExternalPort {
        const merge = g.p.merge_hierarchy_edges;
        var parent_end: ?*lg.LPort = null;
        if (port_type == .input and orig.source.?.owner.? == parent_node) {
            parent_end = orig.source.?;
        } else if (port_type == .output and orig.target.?.owner.? == parent_node) {
            parent_end = orig.target.?;
        }
        var ext: *ExternalPort = undefined;
        if (default_ext == null or !merge or parent_end != null) {
            var side: lg.PortSide = .undefined;
            if (parent_end) |pe| {
                side = pe.side;
            } else if (parent_node.p.port_constraints.isSideFixed()) {
                side = if (port_type == .input) .west else .east;
            }
            const dummy = try self.createExternalPortDummy(g, parent_node, port_type, side, orig);
            const d = try createDummyEdge(self.a, orig);
            if (port_type == .input) {
                try d.setSource(dummy.ports.items[0]);
                try d.setTarget(opposite);
            } else {
                try d.setSource(opposite);
                try d.setTarget(dummy.ports.items[0]);
            }
            ext = try self.a.create(ExternalPort);
            ext.* = .{ .new_edge = d, .dummy_node = dummy, .dummy_port = dummy.p.origin.port, .type = port_type, .exported = parent_end == null };
            try ext.orig_edges.append(self.a, orig);
        } else {
            ext = default_ext.?;
            try ext.orig_edges.append(self.a, orig);
            ext.new_edge.p.edge_thickness = @max(ext.new_edge.p.edge_thickness, orig.p.edge_thickness);
        }
        try self.map.put(self.a, orig, .{ .edge = ext.new_edge, .graph = g, .type = port_type });
        return ext;
    }

    fn calculateNetFlow(port: *const lg.LPort) i64 {
        const node = port.owner.?;
        const inside_enabled = node.p.inside_self_loops_activate;
        var out_vote: i64 = 0;
        var in_vote: i64 = 0;
        for (port.outgoing.items) |e| {
            const self_loop = e.isSelfLoop();
            const inside = self_loop and inside_enabled and e.p.inside_self_loops_yo;
            if (self_loop and inside) {
                in_vote += 1;
            } else if (self_loop) {
                out_vote += 1;
            } else if (e.target.?.owner.?.graph.?.parent_node == node) {
                in_vote += 1;
            } else {
                out_vote += 1;
            }
        }
        for (port.incoming.items) |e| {
            const self_loop = e.isSelfLoop();
            const inside = self_loop and inside_enabled and e.p.inside_self_loops_yo;
            if (self_loop and inside) {
                out_vote += 1;
            } else if (self_loop) {
                in_vote += 1;
            } else if (e.source.?.owner.?.graph.?.parent_node == node) {
                out_vote += 1;
            } else {
                in_vote += 1;
            }
        }
        return out_vote - in_vote;
    }

    fn createExternalPortDummy(self: *Pre, g: *lg.LGraph, parent_node: *lg.LNode, port_type: lg.PortType, side: lg.PortSide, e: *lg.LEdge) lg.Error!*lg.LNode {
        var dummy: *lg.LNode = undefined;
        const outside = if (port_type == .input) e.source.? else e.target.?;
        const dir = gu.getDirection(g);
        if (outside.owner.? == parent_node) {
            dummy = self.dummyGet(outside) orelse blk: {
                const d = try gu.createExternalPortDummy(&outside.p, parent_node.p.port_constraints, side, calculateNetFlow(outside), null, outside.pos, outside.size, dir, g);
                d.p.origin = .{ .port = outside };
                try self.dummyPut(outside, d);
                break :blk d;
            };
        } else {
            const holder = try self.a.create(lg.Props);
            holder.* = .{};
            holder.port_border_offset = g.p.spacing.edge_edge / 2;
            dummy = try gu.createExternalPortDummy(holder, parent_node.p.port_constraints, side, if (port_type == .input) -1 else 1, null, lg.Vec{}, lg.Vec{}, dir, g);
            const dp = try createPortForDummy(dummy, parent_node, port_type);
            dummy.p.origin = .{ .port = dp };
            try self.dummyPut(dp, dummy);
        }
        g.p.graph_properties.external_ports = true;
        g.p.port_constraints = if (g.p.port_constraints.isSideFixed()) .fixed_side else .free;
        return dummy;
    }

    fn createPortForDummy(dummy: *lg.LNode, parent_node: *lg.LNode, t: lg.PortType) lg.Error!*lg.LPort {
        const dir = gu.getDirection(parent_node.graph.?);
        const port = try lg.LPort.init(parent_node.a);
        try port.setNode(parent_node);
        switch (t) {
            .input => port.setSide(lg.PortSide.fromDirection(dir).opposed()),
            .output => port.setSide(lg.PortSide.fromDirection(dir)),
            .undefined => {},
        }
        port.p.port_border_offset = dummy.p.port_border_offset;
        return port;
    }

    fn moveLabelsAndRemoveOriginalEdges(self: *Pre, g: *lg.LGraph) lg.Error!void {
        for (self.map.keys.items, 0..) |orig, ki| {
            if (orig.labels.items.len > 0) {
                const segs = try self.a.dupe(CrossHierarchyEdge, self.map.values.items[ki].items);
                che.sortSegments(g, segs);
                var i: usize = 0;
                while (i < orig.labels.items.len) {
                    const label = orig.labels.items[i];
                    const idx: ?usize = switch (label.p.edge_labels_placement) {
                        .head => segs.len - 1,
                        .center => shallowest(segs),
                        .tail => 0,
                    };
                    if (idx) |ti| {
                        const target = segs[ti].edge;
                        try target.labels.append(self.a, label);
                        const tg = target.source.?.owner.?.graph.?;
                        tg.p.graph_properties.end_labels = true;
                        tg.p.graph_properties.center_labels = true;
                        _ = orig.labels.orderedRemove(i);
                        label.p.original_label_edge = orig;
                    } else i += 1;
                }
            }
            try orig.setSource(null);
            try orig.setTarget(null);
        }
    }

    fn shallowest(segs: []const CrossHierarchyEdge) ?usize {
        var result: ?usize = null;
        for (segs, 0..) |s, index| {
            if (s.type == .input) {
                result = if (index == 0) 0 else index - 1;
                break;
            } else if (index == segs.len - 1) {
                result = index;
            }
        }
        return result;
    }

    fn setSidesOfPortsToSidesOfDummyNodes(self: *Pre) void {
        for (self.dummy_keys.items, self.dummy_vals.items) |ext_port, dummy| {
            dummy.p.origin = .{ .port = ext_port };
            ext_port.p.port_dummy = dummy;
            ext_port.p.inside_connections = true;
            ext_port.setSide(dummy.p.ext_port_side);
            const owner = ext_port.owner.?;
            owner.p.port_constraints = .fixed_side;
            owner.graph.?.p.graph_properties.non_free_ports = true;
        }
    }
};

fn createDummyEdge(a: std.mem.Allocator, orig: *lg.LEdge) lg.Error!*lg.LEdge {
    const d = try lg.LEdge.init(a);
    d.p = orig.p;
    d.p.junction_points = .empty;
    return d;
}

// returns the CROSS_HIERARCHY_MAP the postprocessor needs
pub fn process(g: *lg.LGraph) lg.Error!*CrossHierarchyMap {
    var pre: Pre = .{ .a = g.a };
    _ = try pre.transformHierarchyEdges(g, null);
    try pre.moveLabelsAndRemoveOriginalEdges(g);
    pre.setSidesOfPortsToSidesOfDummyNodes();
    const m = try g.a.create(CrossHierarchyMap);
    m.* = pre.map;
    return m;
}
