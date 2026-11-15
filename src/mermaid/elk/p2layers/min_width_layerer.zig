// MinWidthLayerer. Props read: layering_min_width_upper_bound_on_width, layering_min_width_upper_layer_estimation_scaling_factor,
// spacing.edge_edge. Writes LNode.id, layers.
const std = @import("std");
const lg = @import("../lgraph.zig");

const Layering = struct {
    width: f64,
    layers: std.ArrayList(std.ArrayList(*lg.LNode)),
};

const State = struct {
    a: std.mem.Allocator,
    dummy_size: f64,
    avg_size: f64,
    norm_size: []f64,
    in_degree: []i32,
    out_degree: []i32,
    successors: []const []const *lg.LNode,

    fn selectNode(self: *const State, unplaced: []const *lg.LNode, placed_other: []const bool) ?usize {
        for (unplaced, 0..) |node, idx| {
            var all = true;
            for (self.successors[@intCast(node.id)]) |s| {
                if (!placed_other[@intCast(s.id)]) {
                    all = false;
                    break;
                }
            }
            if (all) return idx;
        }
        return null;
    }

    fn compute(self: *const State, upper_bound_on_width: i32, compensator: i32, nodes: []const *lg.LNode) lg.Error!Layering {
        const a = self.a;
        var layers: std.ArrayList(std.ArrayList(*lg.LNode)) = .empty;
        var unplaced: std.ArrayList(*lg.LNode) = .empty;
        try unplaced.appendSlice(a, nodes);
        const ubw_consider_size = @as(f64, @floatFromInt(upper_bound_on_width)) * self.avg_size;
        const comp: f64 = @floatFromInt(compensator);

        var out_deg: i32 = 0;
        const placed_current = try a.alloc(bool, nodes.len);
        const placed_other = try a.alloc(bool, nodes.len);
        @memset(placed_current, false);
        @memset(placed_other, false);
        var current_layer: std.ArrayList(*lg.LNode) = .empty;
        var width_current: f64 = 0;
        var width_up: f64 = 0;
        var max_width: f64 = 0;
        var real_width: f64 = 0;
        var current_spanning_edges: f64 = 0;
        var going_out_from_this_layer: f64 = 0;

        while (unplaced.items.len > 0) {
            const sel = self.selectNode(unplaced.items, placed_other);
            var current_node: ?*lg.LNode = null;
            if (sel) |idx| {
                const node = unplaced.orderedRemove(idx);
                current_node = node;
                const id: usize = @intCast(node.id);
                try current_layer.append(a, node);
                placed_current[id] = true;

                out_deg = self.out_degree[id];
                const od: f64 = @floatFromInt(out_deg);
                width_current += self.norm_size[id] - od * self.dummy_size;
                const idg: f64 = @floatFromInt(self.in_degree[id]);
                width_up += idg * self.dummy_size;
                going_out_from_this_layer += od * self.dummy_size;
                real_width += self.norm_size[id];
            }

            if (current_node == null or unplaced.items.len == 0 or
                (width_current >= ubw_consider_size and self.norm_size[@intCast(current_node.?.id)] > @as(f64, @floatFromInt(out_deg)) * self.dummy_size) or
                width_up >= comp * ubw_consider_size)
            {
                try layers.append(a, current_layer);
                current_layer = .empty;
                for (placed_current, 0..) |p, k| {
                    if (p) {
                        placed_other[k] = true;
                        placed_current[k] = false;
                    }
                }
                current_spanning_edges -= going_out_from_this_layer;
                max_width = @max(max_width, current_spanning_edges * self.dummy_size + real_width);
                current_spanning_edges += width_up;
                width_current = width_up;
                width_up = 0;
                going_out_from_this_layer = 0;
                real_width = 0;
            }
        }
        return .{ .width = max_width, .layers = layers };
    }
};

fn countEdgesExceptSelfLoops(node: *lg.LNode, outgoing: bool) i32 {
    var n: i32 = 0;
    for (node.ports.items) |p| {
        for (if (outgoing) p.outgoing.items else p.incoming.items) |e| {
            if (e.source.?.owner.? != e.target.?.owner.?) n += 1;
        }
    }
    return n;
}

fn outDegreeDescending(od: []i32, x: *lg.LNode, y: *lg.LNode) bool {
    return od[@intCast(x.id)] > od[@intCast(y.id)];
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    const not_inserted = &g.layerless_nodes;
    const upper_bound_on_width = g.p.layering_min_width_upper_bound_on_width;
    const compensator = g.p.layering_min_width_upper_layer_estimation_scaling_factor;

    var dummy_size = g.p.spacing.edge_edge;
    var minimum_node_size = std.math.inf(f64);
    for (not_inserted.items) |node| {
        if (node.type != .normal) continue;
        minimum_node_size = @min(minimum_node_size, node.size.y);
    }
    minimum_node_size = @max(1, minimum_node_size);

    const n = not_inserted.items.len;
    var st: State = .{
        .a = a,
        .dummy_size = 0,
        .avg_size = 0,
        .norm_size = try a.alloc(f64, n),
        .in_degree = try a.alloc(i32, n),
        .out_degree = try a.alloc(i32, n),
        .successors = undefined,
    };
    var avg_size: f64 = 0;
    for (not_inserted.items, 0..) |node, i| {
        node.id = @intCast(i);
        st.in_degree[i] = countEdgesExceptSelfLoops(node, false);
        st.out_degree[i] = countEdgesExceptSelfLoops(node, true);
        st.norm_size[i] = node.size.y / minimum_node_size;
        avg_size += st.norm_size[i];
    }
    dummy_size /= minimum_node_size;
    avg_size /= @floatFromInt(n);
    st.dummy_size = dummy_size;
    st.avg_size = avg_size;

    const successors = try a.alloc([]const *lg.LNode, n);
    for (not_inserted.items, 0..) |node, i| {
        var out: std.ArrayList(*lg.LNode) = .empty;
        for (node.ports.items) |p| {
            for (p.outgoing.items) |e| {
                const t = e.target.?.owner.?;
                if (t != node) try out.append(a, t);
            }
        }
        successors[i] = out.items;
    }
    st.successors = successors;

    // Collections.reverseOrder of the out-degree comparator on a stable sort
    std.mem.sort(*lg.LNode, not_inserted.items, st.out_degree, outDegreeDescending);

    var min_width = std.math.inf(f64);
    var min_num_of_layers: usize = std.math.maxInt(usize);
    var candidate: ?Layering = null;

    var ubw_start = upper_bound_on_width;
    var ubw_end = upper_bound_on_width;
    var c_start = compensator;
    var c_end = compensator;
    if (upper_bound_on_width < 0) {
        ubw_start = 1;
        ubw_end = 4;
    }
    if (compensator < 0) {
        c_start = 1;
        c_end = 2;
    }

    var ubw = ubw_start;
    while (ubw <= ubw_end) : (ubw += 1) {
        var c = c_start;
        while (c <= c_end) : (c += 1) {
            const result = try st.compute(ubw, c, not_inserted.items);
            const new_num = result.layers.items.len;
            if (result.width < min_width or (result.width == min_width and new_num < min_num_of_layers)) {
                min_width = result.width;
                min_num_of_layers = new_num;
                candidate = result;
            }
        }
    }

    for (candidate.?.layers.items) |layer_list| {
        const layer = try g.newLayer();
        for (layer_list.items) |node| try node.setLayer(layer);
        try g.layers.append(a, layer);
    }
    std.mem.reverse(*lg.Layer, g.layers.items);
    not_inserted.clearRetainingCapacity();
}
