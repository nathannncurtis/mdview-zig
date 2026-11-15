const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Vec = lg.Vec;
const Margin = lg.Margin;
const ElkNode = eg.ElkNode;

const def_aspect_ratio = 1.3;

// BoxLayoutProvider.layout
pub fn layout(a: Allocator, node: *ElkNode) lg.Error!void {
    // the spacing option is read as a float
    const spacing_f32: f32 = @floatCast(node.opts.spacing_node_node orelse 15);
    const spacing: f64 = spacing_f32;
    const padding = node.opts.padding orelse Margin{ .top = 15, .left = 15, .bottom = 15, .right = 15 };
    const expand = node.opts.expand_nodes orelse false;
    const interactive = node.opts.interactive orelse false;
    switch (node.opts.box_packing_mode orelse .simple) {
        .simple => try placeBoxesSimple(a, node, spacing, padding, expand, interactive),
        else => try placeBoxesGrouping(a, node, spacing, padding, expand),
    }
}

fn aspectRatioOf(node: *const ElkNode) f64 {
    const ar = node.opts.aspect_ratio orelse return def_aspect_ratio;
    return if (ar <= 0) def_aspect_ratio else ar;
}

fn horizontal(p: Margin) f64 {
    return p.left + p.right;
}

fn lessBox(interactive: bool, c1: *ElkNode, c2: *ElkNode) bool {
    const p1 = c1.opts.priority orelse 0;
    const p2 = c2.opts.priority orelse 0;
    if (p1 > p2) return true;
    if (p1 < p2) return false;
    if (interactive) {
        var c = util.javaCompare(c1.y, c2.y);
        if (c != 0) return c < 0;
        c = util.javaCompare(c1.x, c2.x);
        if (c != 0) return c < 0;
    }
    return util.javaCompare(c1.width * c1.height, c2.width * c2.height) < 0;
}

fn placeBoxesSimple(a: Allocator, parent: *ElkNode, spacing: f64, padding: Margin, expand: bool, interactive: bool) lg.Error!void {
    const sorted = try a.dupe(*ElkNode, parent.children.items);
    std.mem.sort(*ElkNode, sorted, interactive, lessBox);
    const min_size = util.effectiveMinSize(parent);
    const size = try placeBoxes(a, sorted, spacing, padding, min_size.x, min_size.y, expand, aspectRatioOf(parent));
    util.resizeNode(parent, size.x, size.y, true);
}

fn areaStdDev(boxes: []const *ElkNode, mean: f64) f64 {
    var variance: f64 = 0;
    for (boxes) |box| {
        const d = box.width * box.height - mean;
        variance += d * d;
    }
    return @sqrt(variance / (@as(f64, @floatFromInt(boxes.len)) - 1));
}

fn placeBoxes(a: Allocator, boxes: []const *ElkNode, min_spacing: f64, padding: Margin, min_total_width: f64, min_total_height: f64, expand: bool, aspect_ratio: f64) lg.Error!Vec {
    var max_row_width: f64 = 0;
    var total_area: f64 = 0;
    for (boxes) |box| {
        util.resizeNodeAuto(box);
        max_row_width = @max(max_row_width, box.width);
        total_area += box.width * box.height;
    }
    const n: f64 = @floatFromInt(boxes.len);
    const mean = total_area / n;
    const stddev = areaStdDev(boxes, mean);
    total_area += n * 1 * stddev;
    max_row_width = util.jmax(max_row_width, @sqrt(total_area * aspect_ratio)) + padding.left;

    var xpos = padding.left;
    var ypos = padding.top;
    var highest: f64 = 0;
    var broadest = horizontal(padding);
    var row_indices: std.ArrayList(usize) = .empty;
    var row_heights: std.ArrayList(f64) = .empty;
    try row_indices.append(a, 0);
    for (boxes, 0..) |box, i| {
        const width = box.width;
        const height = box.height;
        if (xpos + width > max_row_width) {
            if (expand) {
                try row_heights.append(a, highest);
                try row_indices.append(a, i);
            }
            xpos = padding.left;
            ypos += highest + min_spacing;
            highest = 0;
            broadest = @max(broadest, horizontal(padding) + width);
        }
        box.x = xpos;
        box.y = ypos;
        broadest = @max(broadest, xpos + width + padding.right);
        highest = @max(highest, height);
        xpos += width + min_spacing;
    }
    broadest = @max(broadest, min_total_width);
    var total_height = ypos + highest + padding.bottom;
    if (total_height < min_total_height) {
        highest += min_total_height - total_height;
        total_height = min_total_height;
    }
    if (expand) {
        xpos = padding.left;
        try row_indices.append(a, boxes.len);
        var ri: usize = 1;
        var next_row = row_indices.items[0];
        try row_heights.append(a, highest);
        var hi: usize = 0;
        var row_height: f64 = 0;
        for (boxes, 0..) |box, i| {
            if (i == next_row) {
                xpos = padding.left;
                row_height = row_heights.items[hi];
                hi += 1;
                next_row = row_indices.items[ri];
                ri += 1;
            }
            const old_height = box.height;
            box.height = row_height;
            if (i + 1 == next_row) {
                const new_width = broadest - xpos - padding.right;
                const old_width = box.width;
                box.width = new_width;
                util.translateAligned(box, .{ .x = new_width, .y = row_height }, .{ .x = old_width, .y = old_height });
            }
            xpos += box.width + min_spacing;
        }
    }
    return .{ .x = broadest, .y = total_height };
}

const Group = struct {
    node: ?*ElkNode = null,
    groups: []*Group = &.{},
    size: Vec = .{},
    bottom: std.ArrayList(*Group) = .empty,
    right: std.ArrayList(*Group) = .empty,

    fn ofNode(a: Allocator, node: *ElkNode) Allocator.Error!*Group {
        const g = try a.create(Group);
        g.* = .{ .node = node };
        node.x = 0;
        node.y = 0;
        return g;
    }

    fn ofGroups(a: Allocator, groups: []const *Group) Allocator.Error!*Group {
        const g = try a.create(Group);
        g.* = .{ .groups = try a.dupe(*Group, groups) };
        return g;
    }

    fn width(g: *const Group) f64 {
        return if (g.node) |nd| nd.width else g.size.x;
    }

    fn height(g: *const Group) f64 {
        return if (g.node) |nd| nd.height else g.size.y;
    }

    fn area(g: *const Group) f64 {
        return g.width() * g.height();
    }

    fn setWidth(g: *Group, w: f64) void {
        if (g.node) |nd| {
            nd.width = w;
        } else {
            const delta = w - g.width();
            for (g.right.items) |r| r.setWidth(r.width() + delta);
        }
    }

    fn setHeight(g: *Group, h: f64) void {
        if (g.node) |nd| {
            nd.height = h;
        } else {
            const delta = h - g.height();
            for (g.bottom.items) |r| r.setHeight(r.height() + delta);
        }
    }

    fn translate(g: *Group, x: f64, y: f64) void {
        if (g.node) |nd| {
            nd.x += x;
            nd.y += y;
        } else {
            for (g.groups) |c| c.translate(x, y);
        }
    }

    fn translateInnerNodes(g: *Group, x: f64, y: f64) void {
        if (g.node) |nd| {
            util.translateContent(nd, x, y);
        } else {
            for (g.groups) |c| c.translateInnerNodes(x, y);
        }
    }
};

fn placeBoxesGrouping(a: Allocator, parent: *ElkNode, spacing: f64, padding: Margin, expand: bool) lg.Error!void {
    var min_size = parent.opts.node_size_minimum orelse Vec{};
    min_size.x = @max(min_size.x - padding.left - padding.right, 0);
    min_size.y = @max(min_size.y - padding.top - padding.bottom, 0);
    const aspect_ratio = aspectRatioOf(parent);
    var groups: std.ArrayList(*Group) = .empty;
    for (parent.children.items) |nd| try groups.append(a, try Group.ofNode(a, nd));
    const to_place = switch (parent.opts.box_packing_mode orelse .simple) {
        .group_inc => try mergeAndPlaceInc(a, groups.items, spacing, min_size, expand),
        .group_dec => try mergeAndPlaceDec(a, groups.items, spacing, min_size, expand),
        else => try mergeAndPlaceMixed(a, groups.items, spacing, min_size, expand),
    };
    const final = try Group.ofGroups(a, to_place);
    const size = try placeInnerBoxes(a, final, spacing, padding, min_size.x, min_size.y, expand, aspect_ratio);
    util.resizeNode(parent, size.x, size.y, true);
}

fn areaStdDev2(boxes: []const *Group, mean: f64) f64 {
    var variance: f64 = 0;
    for (boxes) |box| {
        const d = box.area() - mean;
        variance += d * d;
    }
    return @sqrt(variance / (@as(f64, @floatFromInt(boxes.len)) - 1));
}

fn placeInnerBoxes(a: Allocator, group: *Group, min_spacing: f64, padding: Margin, min_total_width: f64, min_total_height: f64, expand: bool, aspect_ratio: f64) lg.Error!Vec {
    var max_row_width: f64 = 0;
    var total_area: f64 = 0;
    for (group.groups) |box| {
        if (box.node) |nd| util.resizeNodeAuto(nd);
        max_row_width = @max(max_row_width, box.width());
        total_area += box.area();
    }
    const n: f64 = @floatFromInt(group.groups.len);
    const mean = total_area / n;
    const stddev = areaStdDev2(group.groups, mean);
    total_area += n * 1 * stddev;
    max_row_width = util.jmax(max_row_width, @sqrt(total_area * aspect_ratio)) + padding.left;

    var xpos = padding.left;
    var ypos = padding.top;
    var highest: f64 = 0;
    var broadest = horizontal(padding);
    var row_indices: std.ArrayList(usize) = .empty;
    var row_heights: std.ArrayList(f64) = .empty;
    try row_indices.append(a, 0);
    var last: ?*Group = null;
    var bottoms: std.ArrayList(*Group) = .empty;
    for (group.groups, 0..) |box, i| {
        const width = box.width();
        const height = box.height();
        if (xpos + width > max_row_width) {
            if (expand) {
                try row_heights.append(a, highest);
                try row_indices.append(a, i);
                if (last) |l| try group.right.append(a, l);
                bottoms.clearRetainingCapacity();
            }
            xpos = padding.left;
            ypos += highest + min_spacing;
            highest = 0;
            broadest = @max(broadest, horizontal(padding) + width);
        }
        try bottoms.append(a, box);
        box.translate(xpos, ypos);
        broadest = @max(broadest, xpos + width + padding.right);
        highest = @max(highest, height);
        xpos += width + min_spacing;
        last = box;
    }
    try group.bottom.appendSlice(a, bottoms.items);
    try group.right.append(a, bottoms.items[bottoms.items.len - 1]);
    broadest = @max(broadest, min_total_width);
    var total_height = ypos + highest + padding.bottom;
    if (total_height < min_total_height) {
        highest += min_total_height - total_height;
        total_height = min_total_height;
    }
    if (expand) {
        xpos = padding.left;
        try row_indices.append(a, group.groups.len);
        var ri: usize = 1;
        var next_row = row_indices.items[0];
        try row_heights.append(a, highest);
        var hi: usize = 0;
        var row_height: f64 = 0;
        for (group.groups, 0..) |box, i| {
            if (i == next_row) {
                xpos = padding.left;
                row_height = row_heights.items[hi];
                hi += 1;
                next_row = row_indices.items[ri];
                ri += 1;
            }
            box.setHeight(row_height);
            if (i + 1 == next_row) {
                const new_width = broadest - xpos - padding.right;
                const old_width = box.width();
                box.setWidth(new_width);
                box.translateInnerNodes((new_width - old_width) / 2, 0);
            }
            xpos += box.width() + min_spacing;
        }
    }
    return .{ .x = broadest, .y = total_height };
}

fn placeMerged(a: Allocator, inner: *Group, ref: *const Group, spacing: f64, min_size: Vec, expand: bool) lg.Error!void {
    const inner_aspect = ref.width() / ref.height();
    inner.size = try placeInnerBoxes(a, inner, spacing, .{}, min_size.x, min_size.y, expand, inner_aspect);
}

fn greaterArea(_: void, g1: *Group, g2: *Group) bool {
    return util.javaCompare(g1.area(), g2.area()) > 0;
}

fn lessArea(_: void, g1: *Group, g2: *Group) bool {
    return util.javaCompare(g1.area(), g2.area()) < 0;
}

fn mergeAndPlaceDec(a: Allocator, groups: []*Group, spacing: f64, min_size: Vec, expand: bool) lg.Error![]*Group {
    std.mem.sort(*Group, groups, {}, greaterArea);
    var to_be_placed: std.ArrayList(*Group) = .empty;
    var maybe: std.ArrayList(*Group) = .empty;
    var box_to_beat: ?*Group = null;
    var collected: f64 = 0;
    for (groups, 0..) |box, qi| {
        if (box_to_beat == null or box_to_beat.?.area() / 2 < box.area()) {
            box_to_beat = box;
            try to_be_placed.append(a, box);
        } else {
            collected += box.area();
            try maybe.append(a, box);
            if (maybe.items.len > 1 and (collected > box_to_beat.?.area() / 2 or qi + 1 == groups.len)) {
                const inner = try Group.ofGroups(a, maybe.items);
                try placeMerged(a, inner, box_to_beat.?, spacing, min_size, expand);
                box_to_beat = inner;
                try to_be_placed.append(a, inner);
                collected = 0;
                maybe.clearRetainingCapacity();
            }
        }
    }
    try to_be_placed.appendSlice(a, maybe.items);
    return to_be_placed.items;
}

fn mergeAndPlaceInc(a: Allocator, groups: []*Group, spacing: f64, min_size: Vec, expand: bool) lg.Error![]*Group {
    std.mem.sort(*Group, groups, {}, lessArea);
    var to_be_placed: std.ArrayList(*Group) = .empty;
    var common_area: f64 = 0;
    for (groups) |g| {
        if (to_be_placed.items.len > 0 and g.area() > common_area * 2) {
            const merged = try Group.ofGroups(a, to_be_placed.items);
            try placeMerged(a, merged, g, spacing, min_size, expand);
            to_be_placed.clearRetainingCapacity();
            try to_be_placed.append(a, merged);
            try to_be_placed.append(a, g);
            common_area = merged.area() + g.area();
        } else {
            try to_be_placed.append(a, g);
            common_area += g.area();
        }
    }
    return to_be_placed.items;
}

// java.util.PriorityQueue ordered by group area; the sift order decides ties
const AreaQueue = struct {
    items: std.ArrayList(*Group) = .empty,

    fn cmp(x: *Group, y: *Group) i32 {
        return util.javaCompare(x.area(), y.area());
    }

    fn add(q: *AreaQueue, a: Allocator, x: *Group) Allocator.Error!void {
        try q.items.append(a, x);
        var k = q.items.items.len - 1;
        while (k > 0) {
            const parent = (k - 1) >> 1;
            const e = q.items.items[parent];
            if (cmp(x, e) >= 0) break;
            q.items.items[k] = e;
            k = parent;
        }
        q.items.items[k] = x;
    }

    fn peek(q: *const AreaQueue) *Group {
        return q.items.items[0];
    }

    fn poll(q: *AreaQueue) void {
        const n = q.items.items.len - 1;
        const x = q.items.items[n];
        q.items.items.len = n;
        if (n == 0) return;
        const items = q.items.items;
        var k: usize = 0;
        const half = n >> 1;
        while (k < half) {
            var child = 2 * k + 1;
            var c = items[child];
            const right = child + 1;
            if (right < n and cmp(c, items[right]) > 0) {
                child = right;
                c = items[child];
            }
            if (cmp(x, c) <= 0) break;
            items[k] = c;
            k = child;
        }
        items[k] = x;
    }
};

fn mergeAndPlaceMixed(a: Allocator, groups: []*Group, spacing: f64, min_size: Vec, expand: bool) lg.Error![]*Group {
    const cum = try a.alloc(f64, groups.len);
    @memset(cum, 0);
    var pq: AreaQueue = .{};
    for (groups) |g| try pq.add(a, g);
    var index: usize = 0;
    var to_be_placed: std.ArrayList(*Group) = .empty;
    while (pq.items.items.len > 0) {
        const box = pq.peek();
        if (index > 1 and box.area() / 2 > cum[0]) {
            var an_index: usize = 0;
            while (an_index < to_be_placed.items.len - 1 and box.area() / 2 > cum[an_index]) an_index += 1;
            const inner = try Group.ofGroups(a, to_be_placed.items[0 .. an_index + 1]);
            try placeMerged(a, inner, box, spacing, min_size, expand);
            try pq.add(a, inner);
            for (to_be_placed.items[an_index + 1 ..]) |g| try pq.add(a, g);
            to_be_placed.clearRetainingCapacity();
            index = 0;
            @memset(cum, 0);
        } else {
            pq.poll();
            if (index > 0) cum[index] = cum[index - 1];
            cum[index] += box.area();
            index += 1;
            try to_be_placed.append(a, box);
        }
    }
    return to_be_placed.items;
}
