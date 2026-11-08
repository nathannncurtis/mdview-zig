// EdgeAndLayerConstraintEdgeReverser. Props: layer_constraint, port_constraints (nodes), edge_constraint (written),
// reversed (edges, via reverseEdge).
const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

const Reverse = enum { input, output, undefined };

pub fn process(g: *lg.LGraph) lg.Error!void {
    const remaining = try handleOuterNodes(g);
    try handleInnerNodes(remaining);
}

fn edgeConstraintFor(lc: lg.LayerConstraint) ?Reverse {
    return switch (lc) {
        .first, .first_separate => .output,
        .last, .last_separate => .input,
        .none => null,
    };
}

fn handleOuterNodes(g: *lg.LGraph) lg.Error![]*lg.LNode {
    var remaining: std.ArrayList(*lg.LNode) = .empty;
    for (g.layerless_nodes.items) |node| {
        const lc = node.p.layer_constraint;
        if (edgeConstraintFor(lc)) |which| {
            // ELK sets OUTGOING_ONLY for both cases
            node.p.edge_constraint = .outgoing_only;
            try reverseEdges(node, lc, which);
        } else {
            try remaining.append(g.a, node);
        }
    }
    return remaining.items;
}

fn handleInnerNodes(remaining: []*lg.LNode) lg.Error!void {
    for (remaining) |node| {
        const lc = node.p.layer_constraint;
        if (edgeConstraintFor(lc)) |which| {
            node.p.edge_constraint = .outgoing_only;
            try reverseEdges(node, lc, which);
        } else if (node.p.port_constraints.isSideFixed() and node.ports.items.len > 0) {
            var all_ports_reversed = true;
            for (node.ports.items) |port| {
                if (!(port.side == .east and port.netFlow() > 0 or port.side == .west and port.netFlow() < 0)) {
                    all_ports_reversed = false;
                    break;
                }
                for (port.outgoing.items) |e| {
                    const tlc = e.target.?.owner.?.p.layer_constraint;
                    if (tlc == .last or tlc == .last_separate) {
                        all_ports_reversed = false;
                        break;
                    }
                }
                for (port.incoming.items) |e| {
                    const slc = e.source.?.owner.?.p.layer_constraint;
                    if (slc == .first or slc == .first_separate) {
                        all_ports_reversed = false;
                        break;
                    }
                }
            }
            if (all_ports_reversed) try reverseEdges(node, lc, .undefined);
        }
    }
}

fn reverseEdges(node: *lg.LNode, lc: lg.LayerConstraint, which: Reverse) lg.Error!void {
    const a = node.a;
    const ports = try a.dupe(*lg.LPort, node.ports.items);
    for (ports) |port| {
        if (which == .input or which == .undefined) {
            const outgoing = try a.dupe(*lg.LEdge, port.outgoing.items);
            for (outgoing) |edge| {
                if (canReverseOutgoingEdge(lc, edge)) try gu.reverseEdge(edge);
            }
        }
        if (which == .output or which == .undefined) {
            const incoming = try a.dupe(*lg.LEdge, port.incoming.items);
            for (incoming) |edge| {
                if (canReverseIncomingEdge(lc, edge)) try gu.reverseEdge(edge);
            }
        }
    }
}

fn canReverseOutgoingEdge(source_lc: lg.LayerConstraint, edge: *lg.LEdge) bool {
    if (edge.p.reversed) return false;
    const target_node = edge.target.?.owner.?;
    if (source_lc == .last and target_node.type == .label) return false;
    return target_node.p.layer_constraint != .last_separate;
}

fn canReverseIncomingEdge(target_lc: lg.LayerConstraint, edge: *lg.LEdge) bool {
    if (edge.p.reversed) return false;
    const source_node = edge.source.?.owner.?;
    if (target_lc == .first and source_node.type == .label) return false;
    return source_node.p.layer_constraint != .first_separate;
}
