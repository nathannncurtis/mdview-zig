const std = @import("std");
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    var current: ?*lg.Layer = null;
    var unassigned: std.ArrayList(*lg.LNode) = .empty;
    for (g.layers.items) |layer| {
        const previous = current;
        current = layer;
        for (unassigned.items) |node| try node.setLayer(previous);
        unassigned.clearRetainingCapacity();
        for (layer.nodes.items) |node| {
            if (node.type != .normal or !node.p.port_constraints.isSideFixed()) continue;
            for (node.ports.items) |port| {
                if (port.incoming.items.len == 0 or port.side != .east) continue;
                const edges = try g.a.dupe(*lg.LEdge, port.incoming.items);
                for (edges) |edge| try createEastPortSideDummies(g, port, edge, &unassigned);
            }
            for (node.ports.items) |port| {
                if (port.outgoing.items.len == 0 or port.side != .west) continue;
                const edges = try g.a.dupe(*lg.LEdge, port.outgoing.items);
                for (edges) |edge| try createWestPortSideDummies(g, port, edge, &unassigned);
            }
        }
    }
    for (unassigned.items) |node| try node.setLayer(current);
}

const Dummy = struct { node: *lg.LNode, input: *lg.LPort, output: *lg.LPort };

fn newDummy(g: *lg.LGraph, edge: *lg.LEdge, list: *std.ArrayList(*lg.LNode)) lg.Error!Dummy {
    const dummy = try lg.LNode.init(g.a, g);
    dummy.type = .long_edge;
    dummy.p.origin = .{ .edge = edge };
    dummy.p.port_constraints = .fixed_pos;
    try list.append(g.a, dummy);
    const input = try lg.LPort.init(g.a);
    try input.setNode(dummy);
    input.setSide(.west);
    const output = try lg.LPort.init(g.a);
    try output.setNode(dummy);
    output.setSide(.east);
    return .{ .node = dummy, .input = input, .output = output };
}

fn newDummyEdge(g: *lg.LGraph, edge: *lg.LEdge, source: *lg.LPort, target: *lg.LPort) lg.Error!*lg.LEdge {
    const e = try lg.LEdge.init(g.a);
    e.p = edge.p;
    e.p.junction_points = .empty;
    try e.setSource(source);
    try e.setTarget(target);
    return e;
}

fn moveHeadLabels(g: *lg.LGraph, edge: *lg.LEdge, dummy_edge: *lg.LEdge, only_if_unset: bool) lg.Error!void {
    var i: usize = 0;
    while (i < edge.labels.items.len) {
        const label = edge.labels.items[i];
        if (label.p.edge_labels_placement == .head) {
            if (!only_if_unset or label.p.end_label_edge == null) label.p.end_label_edge = edge;
            _ = edge.labels.orderedRemove(i);
            try dummy_edge.labels.append(g.a, label);
        } else {
            i += 1;
        }
    }
}

fn createEastPortSideDummies(g: *lg.LGraph, eastward: *lg.LPort, edge: *lg.LEdge, list: *std.ArrayList(*lg.LNode)) lg.Error!void {
    if (edge.source.?.owner == eastward.owner) return;
    const d = try newDummy(g, edge, list);
    try edge.setTarget(d.input);
    const dummy_edge = try newDummyEdge(g, edge, d.output, eastward);
    setLongEdgeSourceAndTarget(d.node, d.input, d.output);
    try moveHeadLabels(g, edge, dummy_edge, true);
}

fn createWestPortSideDummies(g: *lg.LGraph, westward: *lg.LPort, edge: *lg.LEdge, list: *std.ArrayList(*lg.LNode)) lg.Error!void {
    if (edge.target.?.owner == westward.owner) return;
    const d = try newDummy(g, edge, list);
    const original_target = edge.target.?;
    try edge.setTarget(d.input);
    const dummy_edge = try newDummyEdge(g, edge, d.output, original_target);
    try moveHeadLabels(g, edge, dummy_edge, false);
    setLongEdgeSourceAndTarget(d.node, d.input, d.output);
}

fn setLongEdgeSourceAndTarget(dummy: *lg.LNode, input: *lg.LPort, output: *lg.LPort) void {
    const source_port = input.incoming.items[0].source.?;
    const source_node = source_port.owner.?;
    const target_port = output.outgoing.items[0].target.?;
    const target_node = target_port.owner.?;
    dummy.p.long_edge_source = if (source_node.type == .long_edge) source_node.p.long_edge_source else source_port;
    dummy.p.long_edge_target = if (target_node.type == .long_edge) target_node.p.long_edge_target else target_port;
}
