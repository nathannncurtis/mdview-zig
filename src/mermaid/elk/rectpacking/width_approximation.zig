const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const c = @import("common.zig");

const Allocator = std.mem.Allocator;
const ElkNode = eg.ElkNode;
const DrawingData = c.DrawingData;
const Descriptor = c.Descriptor;

// p1widthapproximation.GreedyWidthApproximator
pub fn greedy(a: Allocator, ctx: c.Ctx) lg.Error!void {
    const goal = ctx.node.opts.rp_optimization_goal orelse .max_scale_driven;
    const last_place_shift = ctx.node.opts.rp_last_place_shift orelse true;
    const rects = ctx.node.children.items;
    c.resetCoordinates(rects);
    const drawing = try approxBoundingBox(a, rects, ctx.aspectRatio(), goal, last_place_shift, ctx.spacing(), ctx.padding());
    ctx.st.target_width = drawing.drawing_width;
}

// p1widthapproximation.TargetWidthWidthApproximator
pub fn targetWidth(ctx: c.Ctx) lg.Error!void {
    ctx.st.target_width = ctx.node.opts.rp_target_width orelse return error.ElkException;
}

fn approxBoundingBox(a: Allocator, rects: []const *ElkNode, aspect_ratio: f64, goal: eg.OptimizationGoal, lp_shift: bool, nn: f64, padding: lg.Margin) lg.Error!DrawingData {
    const first = rects[0];
    first.x = 0;
    first.y = 0;
    var placed: std.ArrayList(*ElkNode) = .empty;
    try placed.append(a, first);
    var last_placed = first;
    var current = DrawingData.init(aspect_ratio, first.width, first.height, .whole_drawing, 0, 0);
    for (rects[1..]) |to_place| {
        const opts = [4]DrawingData{
            calcValuesForOpt(.last_placed_right, to_place, last_placed, current, placed.items, nn, aspect_ratio, lp_shift),
            calcValuesForOpt(.last_placed_below, to_place, last_placed, current, placed.items, nn, aspect_ratio, lp_shift),
            calcValuesForOpt(.whole_drawing_right, to_place, last_placed, current, placed.items, nn, aspect_ratio, lp_shift),
            calcValuesForOpt(.whole_drawing_below, to_place, last_placed, current, placed.items, nn, aspect_ratio, lp_shift),
        };
        var best = try findBestCandidate(opts, to_place, last_placed, goal, aspect_ratio, padding);
        to_place.x = best.next_x;
        to_place.y = best.next_y;
        best.placement_option = .whole_drawing;
        current = best;
        last_placed = to_place;
        try placed.append(a, to_place);
    }
    return current;
}

const Filter = enum { scale, area, aspect };

fn filterList(f: Filter, cands: []DrawingData, n: usize, aspect_ratio: f64, padding: lg.Margin) usize {
    var keep: [4]bool = @splat(false);
    switch (f) {
        .scale => {
            var max_scale = -std.math.inf(f64);
            for (cands[0..n]) |o| max_scale = @max(max_scale, c.scaleMeasure(o.drawing_width + c.horizontal(padding), o.drawing_height + c.vertical(padding), o.dar));
            for (cands[0..n], 0..) |o, i| keep[i] = c.scaleMeasure(o.drawing_width + c.horizontal(padding), o.drawing_height + c.vertical(padding), o.dar) == max_scale;
        },
        .area => {
            var min_area = std.math.inf(f64);
            for (cands[0..n]) |o| min_area = @min(min_area, (o.drawing_width + c.horizontal(padding)) * (o.drawing_height + c.vertical(padding)));
            for (cands[0..n], 0..) |o, i| keep[i] = (o.drawing_width + c.horizontal(padding)) * (o.drawing_height + c.vertical(padding)) == min_area;
        },
        .aspect => {
            var smallest = std.math.inf(f64);
            for (cands[0..n]) |o| smallest = @min(smallest, @abs((o.drawing_width + c.horizontal(padding)) / (o.drawing_height + c.vertical(padding)) - aspect_ratio));
            for (cands[0..n], 0..) |o, i| keep[i] = @abs((o.drawing_width + c.horizontal(padding)) / (o.drawing_height + c.vertical(padding)) - aspect_ratio) == smallest;
        },
    }
    var w: usize = 0;
    for (0..n) |i| if (keep[i]) {
        cands[w] = cands[i];
        w += 1;
    };
    return w;
}

fn findBestCandidate(opts: [4]DrawingData, to_place: *ElkNode, last_placed: *ElkNode, goal: eg.OptimizationGoal, aspect_ratio: f64, padding: lg.Margin) lg.Error!DrawingData {
    var cands = opts;
    var n: usize = 4;
    const filters: [3]Filter = switch (goal) {
        .max_scale_driven => .{ .scale, .area, .aspect },
        .aspect_ratio_driven => .{ .aspect, .area, .scale },
        .area_driven => .{ .area, .scale, .aspect },
    };
    for (filters) |f| {
        if (n > 1) n = filterList(f, &cands, n, aspect_ratio, padding);
    }
    if (n == 1) return cands[0];
    if (n == 2) return checkSpecialCases(cands[0], cands[1], last_placed, to_place);
    return error.ElkException;
}

fn checkSpecialCases(d1: DrawingData, d2: DrawingData, last_placed: *ElkNode, to_place: *ElkNode) DrawingData {
    const o1 = d1.placement_option;
    const o2 = d2.placement_option;
    const first_below = o1 == .last_placed_below or o1 == .whole_drawing_below;
    const second_below = o2 == .last_placed_below or o2 == .whole_drawing_below;
    const first_right = o1 == .last_placed_right or o1 == .whole_drawing_right;
    const second_right = o2 == .last_placed_right or o2 == .whole_drawing_right;
    const first_lp = o1 == .last_placed_right or o1 == .last_placed_below;
    const second_lp = o2 == .last_placed_right or o2 == .last_placed_below;
    if (first_below and second_below) {
        return if (o1 == .whole_drawing_below) d1 else d2;
    } else if (first_right and second_right) {
        return if (o1 == .whole_drawing_right) d1 else d2;
    } else if (first_lp and second_lp) {
        const lpr = if (o1 == .last_placed_right) d1 else d2;
        const lpb = if (o1 == .last_placed_right) d2 else d1;
        const area_lpr = areaLpr(last_placed, to_place, lpr);
        const area_lpb = areaLpb(last_placed, to_place, lpb);
        if (area_lpr <= area_lpb) {
            return if (o1 == .last_placed_right) d1 else d2;
        } else {
            return if (o1 == .last_placed_below) d1 else d2;
        }
    }
    return d1;
}

fn calcValuesForOpt(option: Descriptor, to_place: *ElkNode, last_placed: *ElkNode, drawing: DrawingData, placed: []const *ElkNode, nn: f64, aspect_ratio: f64, lp_shift: bool) DrawingData {
    var x: f64 = 0;
    var y: f64 = 0;
    const dw = drawing.drawing_width;
    const dh = drawing.drawing_height;
    const hp = to_place.height;
    const wp = to_place.width;
    var width: f64 = 0;
    var height: f64 = 0;
    switch (option) {
        .last_placed_right => {
            x = last_placed.x + last_placed.width + nn;
            y = if (lp_shift) calculateYforLpr(x, placed, last_placed, nn) else last_placed.y;
            width = @max(dw, x + wp);
            height = @max(dh, y + hp);
        },
        .last_placed_below => {
            y = last_placed.y + last_placed.height + nn;
            x = if (lp_shift) calculateXforLpb(y, placed, last_placed, nn) else last_placed.x;
            width = @max(dw, x + wp);
            height = @max(dh, y + hp);
        },
        .whole_drawing_right => {
            x = dw + nn;
            y = 0;
            width = dw + nn + wp;
            height = @max(dh, hp);
        },
        .whole_drawing_below => {
            x = 0;
            y = dh + nn;
            width = @max(dw, wp);
            height = dh + nn + hp;
        },
        .whole_drawing => unreachable,
    }
    return DrawingData.init(aspect_ratio, width, height, option, x, y);
}

fn calculateYforLpr(x: f64, placed: []const *ElkNode, last_placed: *ElkNode, nn: f64) f64 {
    var closest: ?*ElkNode = null;
    var closest_bottom: f64 = 0;
    for (placed) |p| {
        const bottom = p.y + p.height;
        if (x < p.x + p.width + nn) {
            if (closest == null) {
                closest = p;
            } else if (last_placed.y - bottom < last_placed.y - closest_bottom) {
                closest = p;
            }
            closest_bottom = closest.?.y + closest.?.height;
        }
    }
    return if (closest == null) 0 else closest_bottom + nn;
}

fn calculateXforLpb(y: f64, placed: []const *ElkNode, last_placed: *ElkNode, nn: f64) f64 {
    var closest: ?*ElkNode = null;
    var closest_right: f64 = 0;
    for (placed) |p| {
        const right = p.x + p.width;
        if (y < p.y + p.height + nn) {
            if (closest == null) {
                closest = p;
            } else if (last_placed.x - right < last_placed.x - closest_right) {
                closest = p;
            }
            closest_right = closest.?.x + closest.?.width;
        }
    }
    return if (closest == null) 0 else closest_right + nn;
}

fn areaLpr(last_placed: *ElkNode, to_place: *ElkNode, lpr: DrawingData) f64 {
    const last_bottom = last_placed.y + last_placed.height;
    const to_place_bottom = lpr.next_y + to_place.height;
    const max_y = @max(last_bottom, to_place_bottom);
    const height = max_y - @min(last_placed.y, lpr.next_y);
    const width = lpr.next_x + to_place.width - last_placed.x;
    return width * height;
}

fn areaLpb(last_placed: *ElkNode, to_place: *ElkNode, lpb: DrawingData) f64 {
    const last_right = last_placed.x + last_placed.width;
    const to_place_right = lpb.next_x + to_place.width;
    const max_x = @max(last_right, to_place_right);
    const width = max_x - @min(last_placed.x, lpb.next_x);
    const height = lpb.next_y + to_place.height - last_placed.y;
    return width * height;
}
