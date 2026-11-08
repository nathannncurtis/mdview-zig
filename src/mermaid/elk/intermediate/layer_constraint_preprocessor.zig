// LayerConstraintPreprocessor. Props: layer_constraint (read, may write first/last), separate_layer_connections,
// original_opposite_port (edges), hidden_nodes (graph).
const std = @import("std");
const lg = @import("../lgraph.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    var hidden: std.ArrayList(*lg.LNode) = .empty;
    var i: usize = 0;
    while (i < g.layerless_nodes.items.len) {
        const node = g.layerless_nodes.items[i];
        if (node.p.layer_constraint == .first_separate or node.p.layer_constraint == .last_separate) {
            try hide(node);
            try hidden.append(g.a, node);
            _ = g.layerless_nodes.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    if (hidden.items.len > 0) g.p.hidden_nodes = hidden;
}

fn hide(node: *lg.LNode) lg.Error!void {
    try ensureNoInacceptableEdges(node);
    const a = node.a;
    var edges: std.ArrayList(*lg.LEdge) = .empty;
    for (node.ports.items) |port| {
        try edges.appendSlice(a, port.incoming.items);
        try edges.appendSlice(a, port.outgoing.items);
    }
    for (edges.items) |edge| try hideEdge(node, edge);
}

fn hideEdge(node: *lg.LNode, edge: *lg.LEdge) lg.Error!void {
    const is_outgoing = edge.source.?.owner.? == node;
    const opposite_port = if (is_outgoing) edge.target.? else edge.source.?;
    if (is_outgoing) try edge.setTarget(null) else try edge.setSource(null);
    edge.p.original_opposite_port = opposite_port;
    updateOppositeNodeLayerConstraints(node, opposite_port.owner.?);
}

fn combine(self: lg.HiddenNodeConnections, lc: lg.LayerConstraint) lg.HiddenNodeConnections {
    return switch (self) {
        .none => if (lc == .first_separate) .first_separate else .last_separate,
        .first_separate => if (lc == .first_separate) .first_separate else .both,
        .last_separate => if (lc == .first_separate) .both else .last_separate,
        .both => .both,
    };
}

// shortcut: hasProperty(LAYER_CONSTRAINT) is read as "!= none"; an explicit NONE (GraphTransformer on external
// port dummies) is not tracked, upgrade with a set-flag if such a dummy can neighbour a *_SEPARATE node
fn updateOppositeNodeLayerConstraints(hidden_node: *lg.LNode, opposite: *lg.LNode) void {
    if (opposite.p.layer_constraint != .none) return;
    const connections = combine(opposite.p.separate_layer_connections, hidden_node.p.layer_constraint);
    opposite.p.separate_layer_connections = connections;
    for (opposite.ports.items) |p| {
        if (p.incoming.items.len > 0 or p.outgoing.items.len > 0) return;
    }
    switch (connections) {
        .first_separate => opposite.p.layer_constraint = .first,
        .last_separate => opposite.p.layer_constraint = .last,
        else => {},
    }
}

fn ensureNoInacceptableEdges(node: *lg.LNode) error{Unsupported}!void {
    const lc = node.p.layer_constraint;
    for (node.ports.items) |port| {
        if (lc == .first_separate) {
            for (port.incoming.items) |e| if (!isAcceptableIncidentEdge(e)) return error.Unsupported;
        } else if (lc == .last_separate) {
            for (port.outgoing.items) |e| if (!isAcceptableIncidentEdge(e)) return error.Unsupported;
        }
    }
}

fn isAcceptableIncidentEdge(edge: *const lg.LEdge) bool {
    return edge.source.?.owner.?.type == .external_port and edge.target.?.owner.?.type == .external_port;
}
