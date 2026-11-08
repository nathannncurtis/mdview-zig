// InteractiveCycleBreaker. Reads node positions (INTERACTIVE_REFERENCE_POINT is always its default CENTER).
// Preceded by intermediate/interactive_external_port_positioner, followed by reversed_edge_restorer after P5.
const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

fn referenceX(n: *const lg.LNode) f64 {
    return n.pos.x + n.size.x / 2.0;
}

fn findCycles(a: std.mem.Allocator, node1: *lg.LNode, rev_edges: *std.ArrayList(*lg.LEdge)) lg.Error!void {
    node1.id = -1;
    for (node1.ports.items) |port| {
        for (port.outgoing.items) |edge| {
            const node2 = edge.target.?.owner.?;
            if (node1 != node2) {
                if (node2.id < 0) {
                    try rev_edges.append(a, edge);
                } else if (node2.id > 0) {
                    try findCycles(a, node2, rev_edges);
                }
            }
        }
    }
    node1.id = 0;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    var rev_edges: std.ArrayList(*lg.LEdge) = .empty;
    for (g.layerless_nodes.items) |source| {
        source.id = 1;
        const sourcex = referenceX(source);
        for (source.ports.items) |port| {
            for (port.outgoing.items) |edge| {
                const target = edge.target.?.owner.?;
                if (target != source) {
                    if (referenceX(target) < sourcex) try rev_edges.append(a, edge);
                }
            }
        }
    }
    for (rev_edges.items) |edge| try gu.reverseEdge(edge);

    rev_edges.clearRetainingCapacity();
    for (g.layerless_nodes.items) |node| {
        if (node.id > 0) try findCycles(a, node, &rev_edges);
    }
    for (rev_edges.items) |edge| try gu.reverseEdge(edge);
}
