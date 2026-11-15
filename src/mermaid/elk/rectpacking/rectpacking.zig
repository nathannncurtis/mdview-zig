const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const box = @import("../box/box.zig");
const util = @import("../box/util.zig");
const elk_util = @import("../util.zig");
const c = @import("common.zig");
const approx = @import("width_approximation.zig");
const packing = @import("packing.zig");
const micro = @import("micro_layout.zig");

const Allocator = std.mem.Allocator;
const ElkNode = eg.ElkNode;

// RectPackingLayoutProvider.layout
pub fn layout(a: Allocator, graph: *ElkNode) lg.Error!void {
    const padding = graph.opts.padding orelse c.default_padding;
    const fixed_graph_size = graph.opts.node_size_fixed_graph_size orelse false;
    const nn = graph.opts.spacing_node_node orelse c.default_spacing;
    const try_box = graph.opts.rp_trybox orelse false;
    const omit_micro = graph.opts.omit_node_micro_layout orelse false;
    const rects = graph.children.items;
    const original = try a.dupe(*ElkNode, rects);
    defer graph.children.replaceRangeAssumeCapacity(0, original.len, original);

    if (!omit_micro) micro.run(graph);

    var stackable = false;
    if (try_box and rects.len >= 3) {
        var region2 = rects[0];
        var region3 = rects[1];
        var counter: usize = 0;
        while (counter + 2 < rects.len) {
            const region1 = region2;
            region2 = region3;
            region3 = rects[counter + 2];
            if (region1.height >= region2.height + region3.height + nn or region3.height >= region1.height + region2.height + nn) {
                stackable = true;
                break;
            }
            counter += 1;
        }
    } else {
        stackable = true;
    }
    if (!stackable) {
        var priority: i32 = @intCast(rects.len);
        for (rects) |n| {
            n.opts.priority = priority;
            priority -= 1;
        }
        return box.layout(a, graph);
    }

    var st: c.Internal = .{};
    const ctx: c.Ctx = .{ .node = graph, .st = &st };
    if (graph.opts.interactive orelse false) try reorder(a, graph);
    const min = util.effectiveMinSize(graph);
    st.min_width = min.x;
    st.min_height = min.y;
    switch (graph.opts.rp_width_approximation_strategy orelse .greedy) {
        .greedy => try approx.greedy(a, ctx),
        .target_width => try approx.targetWidth(ctx),
    }
    st.target_width = @max(st.target_width, st.min_width);
    switch (graph.opts.rp_packing_strategy orelse .compaction) {
        .compaction => try packing.compactor(a, ctx),
        .simple => try packing.simple(a, ctx),
        .none => packing.none(ctx),
    }
    if (graph.opts.rp_white_space_elimination) |strategy| try eliminateWhitespace(ctx, strategy);

    var real_width: f64 = 0;
    var real_height: f64 = 0;
    for (graph.children.items) |r| {
        real_width = @max(real_width, r.x + r.width);
        real_height = @max(real_height, r.y + r.height);
    }
    util.translateAligned(graph, .{ .x = st.drawing_width, .y = st.drawing_height }, .{ .x = real_width, .y = real_height });
    for (graph.children.items) |r| {
        r.x += padding.left;
        r.y += padding.top;
    }
    if (!fixed_graph_size) {
        util.resizeNode(graph, st.drawing_width + c.horizontal(padding), st.drawing_height + c.vertical(padding), true);
    }
    if (!omit_micro) micro.run(graph);
}

// p3whitespaceelimination
fn eliminateWhitespace(ctx: c.Ctx, strategy: eg.WhiteSpaceEliminationStrategy) lg.Error!void {
    const st = ctx.st;
    if (strategy == .to_aspect_ratio) {
        var width = st.drawing_width;
        const height = st.drawing_height;
        const desired = ctx.aspectRatio();
        var additional_height = st.additional_height;
        if (width / height < desired) {
            width = height * desired;
            st.drawing_width = width;
        } else {
            additional_height += (width / desired) - height;
            st.additional_height = additional_height;
            st.drawing_height = height + additional_height;
        }
    }
    const rows = st.rows orelse return error.ElkException;
    const height_per_row = st.additional_height / @as(f64, @floatFromInt(rows.items.len));
    for (rows.items, 0..) |row, index| {
        row.setY(row.y + height_per_row * @as(f64, @floatFromInt(index)));
        row.expand(st.drawing_width, height_per_row);
    }
}

fn cmpDesired(_: void, a: *ElkNode, b: *ElkNode) lg.Error!i32 {
    const pa = a.opts.rp_desired_position.?;
    const pb = b.opts.rp_desired_position.?;
    if (pa == pb) return -1;
    return if (pa < pb) -1 else 1;
}

// intermediate.InteractiveNodeReorderer
fn reorder(a: Allocator, graph: *ElkNode) lg.Error!void {
    var fixed: std.ArrayList(*ElkNode) = .empty;
    var rest: std.ArrayList(*ElkNode) = .empty;
    for (graph.children.items) |n| {
        if (n.opts.rp_desired_position != null) try fixed.append(a, n) else try rest.append(a, n);
    }
    try elk_util.javaSort(*ElkNode, a, fixed.items, {}, cmpDesired);
    for (fixed.items) |n| {
        const position: usize = @min(@as(usize, @intCast(@max(n.opts.rp_desired_position.?, 0))), rest.items.len);
        try rest.insert(a, position, n);
    }
    graph.children = rest;
}
