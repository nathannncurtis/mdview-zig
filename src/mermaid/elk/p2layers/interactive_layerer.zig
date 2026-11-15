// InteractiveLayerer. Reads node pos/size; writes LNode.id, Layer.id, layers.
const std = @import("std");
const lg = @import("../lgraph.zig");

const LayerSpan = struct {
    start: f64,
    end: f64,
    nodes: std.ArrayList(*lg.LNode) = .empty,
};

fn contains(list: []const *lg.LNode, n: *lg.LNode) bool {
    for (list) |x| if (x == n) return true;
    return false;
}

// LinkedHashSet.addAll
fn addAll(a: std.mem.Allocator, set: *std.ArrayList(*lg.LNode), items: []const *lg.LNode) lg.Error!void {
    for (items) |n| if (!contains(set.items, n)) try set.append(a, n);
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    var spans: std.ArrayList(*LayerSpan) = .empty;
    for (g.layerless_nodes.items) |node| {
        const minx = node.pos.x;
        const maxx = @max(minx + 1, minx + node.size.x);
        var i: usize = 0;
        var found: ?*LayerSpan = null;
        while (i < spans.items.len) {
            const span = spans.items[i];
            i += 1;
            if (span.start >= maxx) {
                i -= 1;
                break;
            } else if (span.end > minx) {
                if (found) |f| {
                    try f.nodes.appendSlice(a, span.nodes.items);
                    f.end = @max(f.end, span.end);
                    _ = spans.orderedRemove(i - 1);
                    i -= 1;
                } else {
                    try span.nodes.append(a, node);
                    span.start = @min(span.start, minx);
                    span.end = @max(span.end, maxx);
                    found = span;
                }
            }
        }
        if (found == null) {
            const span = try a.create(LayerSpan);
            span.* = .{ .start = minx, .end = maxx };
            try span.nodes.append(a, node);
            try spans.insert(a, i, span);
        }
    }

    var next_index: i32 = 0;
    for (spans.items) |span| {
        const layer = try g.newLayer();
        layer.id = next_index;
        next_index += 1;
        try g.layers.append(a, layer);
        for (span.nodes.items) |node| {
            try node.setLayer(layer);
            node.id = 0;
        }
    }

    for (g.layerless_nodes.items) |node| {
        if (node.id == 0) {
            var shifted = try checkNode(g, node);
            while (shifted.items.len > 0) {
                const to_check = shifted.orderedRemove(0);
                const more = try checkNode(g, to_check);
                try addAll(a, &shifted, more.items);
            }
        }
    }

    var i: usize = 0;
    while (i < g.layers.items.len) {
        if (g.layers.items[i].nodes.items.len == 0) _ = g.layers.orderedRemove(i) else i += 1;
    }
    g.layerless_nodes.clearRetainingCapacity();
}

fn checkNode(g: *lg.LGraph, node1: *lg.LNode) lg.Error!std.ArrayList(*lg.LNode) {
    node1.id = 1;
    const layer1 = node1.layer.?;
    var shift: std.ArrayList(*lg.LNode) = .empty;
    for (node1.ports.items) |port| {
        for (port.outgoing.items) |edge| {
            const node2 = edge.target.?.owner.?;
            if (node1 != node2) {
                const layer2 = node2.layer.?;
                if (layer2.id <= layer1.id) {
                    const new_index: usize = @intCast(layer1.id + 1);
                    if (new_index == g.layers.items.len) {
                        const new_layer = try g.newLayer();
                        new_layer.id = @intCast(new_index);
                        try g.layers.append(g.a, new_layer);
                        try node2.setLayer(new_layer);
                    } else {
                        try node2.setLayer(g.layers.items[new_index]);
                    }
                    if (!contains(shift.items, node2)) try shift.append(g.a, node2);
                }
            }
        }
    }
    return shift;
}
