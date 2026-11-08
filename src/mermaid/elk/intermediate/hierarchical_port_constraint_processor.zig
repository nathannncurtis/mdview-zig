const std = @import("std");
const lg = @import("../lgraph.zig");

// HierarchicalPortConstraintProcessor. Mermaid's nested graphs keep FREE port constraints (the compound
// preprocessor only fixes them when they already were side-fixed), so both steps return early in practice.
pub fn process(g: *lg.LGraph) lg.Error!void {
    if (g.p.port_constraints.isOrderFixed() and g.layers.items.len > 0) {
        try processEastWest(g, g.layers.items[0]);
        try processEastWest(g, g.layers.items[g.layers.items.len - 1]);
    }
    try processNorthSouth(g);
}

fn lessThan(_: void, n1: *lg.LNode, n2: *lg.LNode) bool {
    if (n2.type != .external_port) return false;
    if (n1.type != .external_port) return false;
    return n1.p.port_ratio_or_position < n2.p.port_ratio_or_position;
}

fn processEastWest(g: *lg.LGraph, layer: *lg.Layer) lg.Error!void {
    const nodes = try g.a.dupe(*lg.LNode, layer.nodes.items);
    // NodeComparator orders external port dummies first by position (stable merge sort)
    std.mem.sort(*lg.LNode, nodes, {}, struct {
        fn lt(_: void, a: *lg.LNode, b: *lg.LNode) bool {
            if (a.type == .external_port and b.type != .external_port) return true;
            return lessThan({}, a, b);
        }
    }.lt);
    var last: ?*lg.LNode = null;
    for (nodes) |node| {
        if (node.type != .external_port) break;
        const side = node.p.ext_port_side;
        if (side != .west and side != .east) continue;
        if (last) |l| try l.p.in_layer_successor_constraints.append(g.a, node);
        last = node;
    }
}

fn isNorthernOrSouthernDummy(n: *const lg.LNode) bool {
    return n.type == .external_port and (n.p.ext_port_side == .north or n.p.ext_port_side == .south);
}

const DummyMap = std.ArrayList(struct { *lg.LPort, *lg.LNode });

fn mapGet(m: *const DummyMap, k: *lg.LPort) ?*lg.LNode {
    for (m.items) |e| if (e[0] == k) return e[1];
    return null;
}

fn processNorthSouth(g: *lg.LGraph) lg.Error!void {
    if (!g.p.port_constraints.isSideFixed()) return;
    const a = g.a;
    const layer_count = g.layers.items.len;
    var maps: std.ArrayList(DummyMap) = .empty;
    var new_dummies: std.ArrayList(std.ArrayList(*lg.LNode)) = .empty;
    try maps.appendNTimes(a, .empty, 2);
    try new_dummies.appendNTimes(a, .empty, 2);
    var originals: std.ArrayList(*lg.LNode) = .empty;
    for (0..layer_count) |li| {
        try maps.append(a, .empty);
        try new_dummies.append(a, .empty);
        const prev_map = &maps.items[li];
        const prev_new = &new_dummies.items[li];
        const next_map = &maps.items[li + 2];
        const next_new = &new_dummies.items[li + 2];
        for (g.layers.items[li].nodes.items) |node| {
            if (isNorthernOrSouthernDummy(node)) {
                try originals.append(a, node);
                continue;
            }
            for (node.ports.items) |port| {
                const ins = try a.dupe(*lg.LEdge, port.incoming.items);
                for (ins) |e| {
                    const src = e.source.?.owner.?;
                    if (!isNorthernOrSouthernDummy(src)) continue;
                    const key = src.p.origin.port;
                    const d = mapGet(prev_map, key) orelse blk: {
                        const nd = try createDummy(g, src);
                        try prev_map.append(a, .{ key, nd });
                        try prev_new.append(a, nd);
                        break :blk nd;
                    };
                    try e.setSource(d.ports.items[1]);
                }
            }
            for (node.ports.items) |port| {
                const outs = try a.dupe(*lg.LEdge, port.outgoing.items);
                for (outs) |e| {
                    const tgt = e.target.?.owner.?;
                    if (!isNorthernOrSouthernDummy(tgt)) continue;
                    const key = tgt.p.origin.port;
                    const d = mapGet(next_map, key) orelse blk: {
                        const nd = try createDummy(g, tgt);
                        try next_map.append(a, .{ key, nd });
                        try next_new.append(a, nd);
                        break :blk nd;
                    };
                    try e.setTarget(d.ports.items[0]);
                }
            }
        }
    }
    for (new_dummies.items, 0..) |list, i| {
        if (list.items.len == 0) continue;
        var layer: *lg.Layer = undefined;
        if (i == 0) {
            layer = try g.newLayer();
            try g.layers.insert(a, 0, layer);
        } else if (i == maps.items.len - 1) {
            layer = try g.newLayer();
            try g.layers.append(a, layer);
        } else {
            layer = g.layers.items[i - 1];
        }
        for (list.items) |d| try d.setLayer(layer);
    }
    for (originals.items) |o| try o.setLayer(null);
    g.p.ext_port_replaced_dummies = originals;
}

fn createDummy(g: *lg.LGraph, original: *lg.LNode) lg.Error!*lg.LNode {
    const d = try lg.LNode.init(g.a, g);
    d.p = original.p;
    d.p.ext_port_replaced_dummy = original;
    d.p.port_constraints = .fixed_pos;
    d.p.alignment = .center;
    d.type = .external_port;
    const in_port = try lg.LPort.init(g.a);
    try in_port.setNode(d);
    in_port.setSide(.west);
    const out_port = try lg.LPort.init(g.a);
    try out_port.setNode(d);
    out_port.setSide(.east);
    return d;
}
