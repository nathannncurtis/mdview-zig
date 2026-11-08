const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const nim = @import("neighborhood_information.zig");
const NeighborhoodInformation = nim.NeighborhoodInformation;
const bal_mod = @import("bk_aligned_layout.zig");
const BKAlignedLayout = bal_mod.BKAlignedLayout;
const BKAligner = @import("bk_aligner.zig").BKAligner;
const BKCompactor = @import("bk_compactor.zig").BKCompactor;

const MarkedEdges = std.AutoHashMapUnmanaged(*lg.LEdge, void);

fn ix(n: *const lg.LNode) usize {
    return @intCast(n.id);
}

// BKNodePlacer (phase 4). With external ports the driver adds HIERARCHICAL_PORT_POSITION_PROCESSOR before phase 5.
pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    const ni = try NeighborhoodInformation.buildFor(a, g);
    const alignment = g.p.bk_fixed_alignment;
    const favor_straight_edges = g.p.favor_straight_edges orelse (g.p.edge_routing == .orthogonal);
    const produce_balanced_layout = (alignment == .none and !favor_straight_edges) or alignment == .balanced;

    var marked_edges: MarkedEdges = .empty;
    try markConflicts(a, g, &ni, &marked_edges);

    var layouts: std.ArrayList(*BKAlignedLayout) = .empty;
    const n = ni.node_count;
    switch (alignment) {
        .leftdown => try layouts.append(a, try BKAlignedLayout.init(a, g, n, .down, .left)),
        .leftup => try layouts.append(a, try BKAlignedLayout.init(a, g, n, .up, .left)),
        .rightdown => try layouts.append(a, try BKAlignedLayout.init(a, g, n, .down, .right)),
        .rightup => try layouts.append(a, try BKAlignedLayout.init(a, g, n, .up, .right)),
        else => {
            const leftdown = try BKAlignedLayout.init(a, g, n, .down, .left);
            const leftup = try BKAlignedLayout.init(a, g, n, .up, .left);
            const rightdown = try BKAlignedLayout.init(a, g, n, .down, .right);
            const rightup = try BKAlignedLayout.init(a, g, n, .up, .right);
            try layouts.appendSlice(a, &.{ rightdown, rightup, leftdown, leftup });
        },
    }

    const aligner: BKAligner = .{ .layered_graph = g, .ni = &ni };
    for (layouts.items) |bal| {
        aligner.verticalAlignment(bal, &marked_edges);
        try aligner.insideBlockShift(a, bal);
    }
    var compacter = try BKCompactor.init(a, g, &ni);
    for (layouts.items) |bal| try compacter.horizontalCompaction(bal);

    var chosen_layout: ?*BKAlignedLayout = null;
    if (produce_balanced_layout) {
        const balanced = try createBalancedLayout(a, g, layouts.items, n);
        if (checkOrderConstraint(g, balanced)) chosen_layout = balanced;
    }
    if (chosen_layout == null) {
        for (layouts.items) |bal| {
            if (checkOrderConstraint(g, bal)) {
                if (chosen_layout == null or chosen_layout.?.layoutSize() > bal.layoutSize()) chosen_layout = bal;
            }
        }
    }
    const chosen = chosen_layout orelse layouts.items[0];
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| node.pos.y = chosen.y[ix(node)].? + chosen.inner_shift[ix(node)];
    }
}

fn markConflicts(a: std.mem.Allocator, g: *lg.LGraph, ni: *const NeighborhoodInformation, marked_edges: *MarkedEdges) lg.Error!void {
    const layers = g.layers.items;
    const number_of_layers = layers.len;
    if (number_of_layers < 3) return;
    const layer_size = try a.alloc(usize, number_of_layers);
    for (layers, 0..) |layer, li| layer_size[li] = layer.nodes.items.len;

    for (1..number_of_layers - 1) |i| {
        const current_layer = layers[i + 1];
        var k_0: i64 = 0;
        var l: usize = 0;
        for (0..layer_size[i + 1]) |l_1| {
            const v_l_i = current_layer.nodes.items[l_1];
            if (l_1 == layer_size[i + 1] - 1 or incidentToInnerSegment(ni, v_l_i, i + 1, i)) {
                var k_1: i64 = @as(i64, @intCast(layer_size[i])) - 1;
                if (incidentToInnerSegment(ni, v_l_i, i + 1, i)) {
                    k_1 = @intCast(ni.nodeIndex(ni.left_neighbors[ix(v_l_i)][0].node));
                }
                while (l <= l_1) : (l += 1) {
                    const v_l = current_layer.nodes.items[l];
                    if (!incidentToInnerSegment(ni, v_l, i + 1, i)) {
                        for (ni.left_neighbors[ix(v_l)]) |upper_neighbor| {
                            const k: i64 = @intCast(ni.nodeIndex(upper_neighbor.node));
                            if (k < k_0 or k > k_1) try marked_edges.put(a, upper_neighbor.edge, {});
                        }
                    }
                }
                k_0 = k_1;
            }
        }
    }
}

fn createBalancedLayout(a: std.mem.Allocator, g: *lg.LGraph, layouts: []*BKAlignedLayout, node_count: usize) lg.Error!*BKAlignedLayout {
    const no_of_layouts = layouts.len;
    const balanced = try BKAlignedLayout.init(a, g, node_count, null, null);
    const width = try a.alloc(f64, no_of_layouts);
    const min = try a.alloc(f64, no_of_layouts);
    const max = try a.alloc(f64, no_of_layouts);
    var min_width_layout: usize = 0;
    @memset(min, @floatFromInt(std.math.maxInt(i32)));
    @memset(max, @floatFromInt(std.math.minInt(i32)));
    for (layouts, 0..) |bal, i| {
        width[i] = bal.layoutSize();
        if (width[min_width_layout] > width[i]) min_width_layout = i;
        for (g.layers.items) |l| {
            for (l.nodes.items) |n| {
                const node_pos_y = bal.y[ix(n)].? + bal.inner_shift[ix(n)];
                min[i] = util.javaMin(min[i], node_pos_y);
                max[i] = util.javaMax(max[i], node_pos_y + n.size.y);
            }
        }
    }
    const shift = try a.alloc(f64, no_of_layouts);
    for (layouts, 0..) |bal, i| {
        shift[i] = if (bal.vdir == .down) min[min_width_layout] - min[i] else max[min_width_layout] - max[i];
    }
    const calculated_ys = try a.alloc(f64, no_of_layouts);
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            for (layouts, 0..) |bal, i| calculated_ys[i] = bal.y[ix(node)].? + bal.inner_shift[ix(node)] + shift[i];
            std.mem.sort(f64, calculated_ys, {}, lessDouble);
            balanced.y[ix(node)] = (calculated_ys[1] + calculated_ys[2]) / 2.0;
            balanced.inner_shift[ix(node)] = 0;
        }
    }
    return balanced;
}

// Arrays.sort(double[]) order
fn lessDouble(_: void, x: f64, y: f64) bool {
    return util.doubleCompare(x, y) == .lt;
}

fn incidentToInnerSegment(ni: *const NeighborhoodInformation, node: *const lg.LNode, layer1: usize, layer2: usize) bool {
    if (node.type != .long_edge) return false;
    for (node.ports.items) |port| {
        for (port.incoming.items) |edge| {
            const src = edge.source.?.owner.?;
            if (src.type == .long_edge and ni.layer_index[@intCast(src.layer.?.id)] == layer2 and ni.layer_index[@intCast(node.layer.?.id)] == layer1) return true;
        }
    }
    return false;
}

fn checkOrderConstraint(g: *const lg.LGraph, bal: *const BKAlignedLayout) bool {
    for (g.layers.items) |layer| {
        var pos = -std.math.inf(f64);
        for (layer.nodes.items) |node| {
            const y = bal.y[ix(node)].? + bal.inner_shift[ix(node)];
            const top = y - node.margin.top;
            const bottom = y + node.size.y + node.margin.bottom;
            if (top > pos and bottom > pos) {
                pos = y + node.size.y + node.margin.bottom;
            } else {
                return false;
            }
        }
    }
    return true;
}
