// InteractiveExternalPortPositioner. AlgorithmAssembler caches one instance per layout provider and never resets
// its bounds, so they persist for the life of the thread like the pooled Java instance.
const std = @import("std");
const lg = @import("../lgraph.zig");

const arbitrary_spacing = 10;

threadlocal var min_x: f64 = std.math.inf(f64);
threadlocal var max_x: f64 = -std.math.inf(f64);
threadlocal var min_y: f64 = std.math.inf(f64);
threadlocal var max_y: f64 = -std.math.inf(f64);

fn findYCoordinate(dummy: *const lg.LNode, source_side: bool) ?f64 {
    for (dummy.ports.items) |port| {
        for ([_][]*lg.LEdge{ port.incoming.items, port.outgoing.items }) |edges| {
            for (edges) |e| {
                const other = if (source_side) e.source.?.owner.? else e.target.?.owner.?;
                return other.pos.y + other.size.y / 2;
            }
        }
    }
    return null;
}

fn findNorthSouthPortXCoordinate(dummy: *const lg.LNode) lg.Error!?f64 {
    const port = dummy.ports.items[0];
    if (port.outgoing.items.len != 0 and port.incoming.items.len != 0) {
        lg.setElkMessage("Interactive layout does not support NORTH/SOUTH ports with incoming _and_ outgoing edges.");
        return error.ElkException;
    }
    if (port.outgoing.items.len != 0) {
        var min = std.math.inf(f64);
        for (port.outgoing.items) |e| {
            const n = e.target.?.owner.?;
            min = @min(min, n.pos.x - n.margin.left);
        }
        return min;
    }
    if (port.incoming.items.len != 0) {
        var max = -std.math.inf(f64);
        for (port.incoming.items) |e| {
            const n = e.source.?.owner.?;
            max = @max(max, n.pos.x + n.size.x + n.margin.right);
        }
        return max;
    }
    return null;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    if (!g.p.graph_properties.external_ports) return;

    for (g.layerless_nodes.items) |node| {
        if (node.type == .normal) {
            const m = node.margin;
            min_x = @min(min_x, node.pos.x - m.left);
            max_x = @max(max_x, node.pos.x + node.size.x + m.right);
            min_y = @min(min_y, node.pos.y - m.top);
            max_y = @max(max_y, node.pos.y + node.size.y + m.bottom);
        }
    }

    for (g.layerless_nodes.items) |node| {
        if (node.type == .normal) continue;
        if (node.type != .external_port) {
            var buf: [256]u8 = undefined;
            var upper: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "The node type {s} is not supported by the class org.eclipse.elk.alg.layered.intermediate.InteractiveExternalPortPositioner", .{std.ascii.upperString(&upper, @tagName(node.type))}) catch unreachable;
            lg.setElkMessage(msg);
            return error.ElkException;
        }
        const lc = node.p.layer_constraint;
        if (lc == .first_separate) {
            node.pos.x = min_x - arbitrary_spacing;
            if (findYCoordinate(node, false)) |d| node.pos.y = d;
            continue;
        }
        if (lc == .last_separate) {
            node.pos.x = max_x + arbitrary_spacing;
            if (findYCoordinate(node, true)) |d| node.pos.y = d;
            continue;
        }
        const ilc = node.p.in_layer_constraint;
        if (ilc == .top) {
            if (try findNorthSouthPortXCoordinate(node)) |x| node.pos.x = x + arbitrary_spacing;
            node.pos.y = min_y - arbitrary_spacing;
            continue;
        }
        if (ilc == .bottom) {
            if (try findNorthSouthPortXCoordinate(node)) |x| node.pos.x = x + arbitrary_spacing;
            node.pos.y = max_y + arbitrary_spacing;
        }
    }
}
