// StretchWidthLayerer. Props read: spacing.edge_edge. Writes LNode.id, layers.
const std = @import("std");
const lg = @import("../lgraph.zig");

fn edgeCount(node: *lg.LNode, outgoing: bool) i32 {
    var n: i32 = 0;
    for (node.ports.items) |p| n += @intCast(if (outgoing) p.outgoing.items.len else p.incoming.items.len);
    return n;
}

fn getRank(node: *lg.LNode) i32 {
    var max = edgeCount(node, true);
    for (node.ports.items) |p| {
        for (p.incoming.items) |pre_edge| {
            max = @max(max, edgeCount(pre_edge.source.?.owner.?, true));
        }
    }
    return max;
}

fn rankDescending(_: void, a: *lg.LNode, b: *lg.LNode) bool {
    return a.id > b.id;
}

const State = struct {
    width_current: f64 = 0,
    width_up: f64 = 0,
    max_width: f64 = 0,
    upper_layer_influence: f64 = 0,
    dummy_size: f64 = 0,
    out_degree: []i32 = &.{},
    in_degree: []i32 = &.{},
    remaining_out_going: []i32 = &.{},
    norm_size: []f64 = &.{},

    fn conditionGoUp(self: *const State, selected: *lg.LNode) bool {
        const id: usize = @intCast(selected.id);
        const od: f64 = @floatFromInt(self.out_degree[id]);
        const idg: f64 = @floatFromInt(self.in_degree[id]);
        const a = (self.width_current - (od * self.dummy_size) + self.norm_size[id]) > self.max_width;
        const b = (self.width_up + idg * self.dummy_size) > (self.max_width * self.upper_layer_influence * self.dummy_size);
        return a or b;
    }

    fn selectNode(self: *const State, temp: []const *lg.LNode) ?*lg.LNode {
        for (temp) |node| {
            if (self.remaining_out_going[@intCast(node.id)] <= 0) return node;
        }
        return null;
    }

    fn updateOutGoing(self: *State, layer: *lg.Layer) void {
        for (layer.nodes.items) |node| {
            for (node.ports.items) |p| {
                for (p.incoming.items) |edge| {
                    self.remaining_out_going[@intCast(edge.source.?.owner.?.id)] -= 1;
                }
            }
        }
    }
};

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    if (g.layerless_nodes.items.len == 0) return;

    var st: State = .{};
    var minimum_node_size = std.math.inf(f64);
    var maximum_node_size = -std.math.inf(f64);
    st.dummy_size = g.p.spacing.edge_edge;

    var sorted: std.ArrayList(*lg.LNode) = .empty;
    try sorted.appendSlice(a, g.layerless_nodes.items);
    for (g.layerless_nodes.items) |node| node.id = getRank(node);
    std.mem.sort(*lg.LNode, sorted.items, {}, rankDescending);

    for (sorted.items, 0..) |node, i| node.id = @intCast(i);

    const n = sorted.items.len;
    st.in_degree = try a.alloc(i32, n);
    st.out_degree = try a.alloc(i32, n);
    for (sorted.items) |node| {
        st.in_degree[@intCast(node.id)] = edgeCount(node, false);
        st.out_degree[@intCast(node.id)] = edgeCount(node, true);
    }

    for (sorted.items) |node| {
        if (node.type != .normal) continue;
        minimum_node_size = @min(minimum_node_size, node.size.y);
        maximum_node_size = @max(maximum_node_size, node.size.y);
    }
    st.norm_size = try a.alloc(f64, n);
    for (sorted.items) |node| st.norm_size[@intCast(node.id)] = node.size.y / minimum_node_size;
    minimum_node_size = @max(1, minimum_node_size);
    maximum_node_size = @max(1, maximum_node_size);

    st.dummy_size = st.dummy_size / minimum_node_size;
    st.max_width = maximum_node_size / minimum_node_size;
    var all_out: f64 = 0;
    for (g.layerless_nodes.items) |node| all_out += @floatFromInt(edgeCount(node, true));
    st.upper_layer_influence = all_out / @as(f64, @floatFromInt(g.layerless_nodes.items.len));

    var current_layer = try g.newLayer();
    try g.layers.append(a, current_layer);
    var temp: std.ArrayList(*lg.LNode) = .empty;
    try temp.appendSlice(a, sorted.items);
    st.remaining_out_going = try a.dupe(i32, st.out_degree);

    var placed_now: std.ArrayList(*lg.LNode) = .empty;

    while (temp.items.len > 0) {
        const selected = st.selectNode(temp.items);
        if (selected == null or (st.conditionGoUp(selected.?) and placed_now.items.len != 0)) {
            st.updateOutGoing(current_layer);
            current_layer = try g.newLayer();
            try g.layers.append(a, current_layer);
            placed_now.clearRetainingCapacity();
            st.width_current = st.width_up;
            st.width_up = 0;
        } else {
            const sel = selected.?;
            if (st.conditionGoUp(sel)) {
                // ELK loops forever here when the influence is 0 (every edge enters from a hidden node); report instead
                if (st.upper_layer_influence == 0 and st.in_degree[@intCast(sel.id)] > 0) {
                    lg.setElkMessage("StretchWidth layering cannot place a node");
                    return error.ElkException;
                }
                g.layers.clearRetainingCapacity();
                current_layer = try g.newLayer();
                try g.layers.append(a, current_layer);
                st.width_current = 0;
                st.width_up = 0;
                placed_now.clearRetainingCapacity();
                st.max_width += 1;
                temp.clearRetainingCapacity();
                try temp.appendSlice(a, sorted.items);
                @memcpy(st.remaining_out_going, st.out_degree);
            } else {
                try sel.setLayer(current_layer);
                lg.removeItem(lg.LNode, &temp, sel);
                try placed_now.append(a, sel);
                const id: usize = @intCast(sel.id);
                st.width_current = st.width_current - @as(f64, @floatFromInt(st.out_degree[id])) * st.dummy_size + st.norm_size[id];
                st.width_up += @as(f64, @floatFromInt(st.in_degree[id])) * st.dummy_size;
            }
        }
    }

    g.layerless_nodes.clearRetainingCapacity();
    std.mem.reverse(*lg.Layer, g.layers.items);
}
