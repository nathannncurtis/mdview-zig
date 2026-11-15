const std = @import("std");
const model = @import("../model.zig");
const dom = @import("../dom.zig");
const u = @import("util.zig");
const basic = @import("basic.zig");
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;
const Opts = u.Opts;
const Error = u.Error;
const pre = basic.pre;

fn labelAt(p: basic.Pre, a: std.mem.Allocator, center_y: f64) Error!void {
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2), center_y - p.h.h / 2 + p.h.by));
}

fn styled(el: *El, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error!void {
    try el.setAttr("style", try std.fmt.allocPrint(a, fmt, args));
}

pub fn folder(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const padding = node.padding orelse 12;
    const w = @max(@max(p.h.w + padding * 2, node.width), 90);
    const content_h = p.h.h + padding * 2;
    const tab_h = @max(@min(content_h * 0.16, 14), 8);
    const total_h = @max(content_h + tab_h, node.height);
    const body_h = total_h - tab_h;
    const tab_w = @max(w * 0.38, 28);
    const top = -total_h / 2;
    const pts = [_]Point{
        .{ .x = -w / 2, .y = top },
        .{ .x = -w / 2 + tab_w, .y = top },
        .{ .x = -w / 2 + tab_w, .y = top + tab_h },
        .{ .x = w / 2, .y = top + tab_h },
        .{ .x = w / 2, .y = total_h / 2 },
        .{ .x = -w / 2, .y = total_h / 2 },
    };
    const path = try p.h.shape.insertFirst("path");
    try path.setAttr("d", try u.createPathFromPoints(a, &pts));
    try path.setAttr("class", "basic label-container");
    try basic.setNodeStyle(path, p.st);
    u.updateNodeBounds(node, path);
    try labelAt(p, a, top + tab_h + body_h / 2);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &pts) } };
    return p.h.shape;
}

pub fn bucket(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const accent = ctx.cfg.node_border;
    const padding = node.padding orelse 12;
    const w = @max(@max(p.h.w + padding * 2, node.width), 80);
    const rim_ry = @max(@min(w * 0.08, 12), 5);
    const total_h = @max(p.h.h + padding * 2 + rim_ry, node.height);
    const top_y = -total_h / 2 + rim_ry;
    const bottom_y = total_h / 2;
    const bottom_w = w * 0.72;
    const body = try std.fmt.allocPrint(a, "M{s},{s} L{s},{s} A{s},{s} 0 0 0 {s},{s} L{s},{s} A{s},{s} 0 0 0 {s},{s} Z", .{
        try u.num(a, -w / 2),        try u.num(a, top_y),
        try u.num(a, -bottom_w / 2), try u.num(a, bottom_y),
        try u.num(a, bottom_w / 2),  try u.num(a, rim_ry),
        try u.num(a, bottom_w / 2),  try u.num(a, bottom_y),
        try u.num(a, w / 2),         try u.num(a, top_y),
        try u.num(a, w / 2),         try u.num(a, rim_ry),
        try u.num(a, -w / 2),        try u.num(a, top_y),
    });
    const group = try p.h.shape.insertFirst("g");
    try group.setAttr("class", "basic label-container");
    const path = try group.insert("path");
    try path.setAttr("d", body);
    try basic.setNodeStyle(path, p.st);
    const rim = try group.insert("ellipse");
    _ = try (try (try (try rim.attrNum("cx", 0)).attrNum("cy", top_y)).attrNum("rx", w / 2)).attrNum("ry", rim_ry);
    try styled(rim, a, "fill:none;stroke:{s};stroke-width:1px", .{accent});
    u.updateNodeBounds(node, group);
    try labelAt(p, a, top_y + (bottom_y - top_y) / 2);

    const segs = 12;
    var outline: std.ArrayList(Point) = .empty;
    for (0..segs + 1) |i| {
        const th = std.math.pi - @as(f64, @floatFromInt(i)) * std.math.pi / segs;
        try outline.append(a, .{ .x = w / 2 * @cos(th), .y = top_y - rim_ry * @sin(th) });
    }
    var i: usize = segs + 1;
    while (i > 0) {
        i -= 1;
        const th = std.math.pi - @as(f64, @floatFromInt(i)) * std.math.pi / segs;
        try outline.append(a, .{ .x = bottom_w / 2 * @cos(th), .y = bottom_y + rim_ry * @sin(th) });
    }
    node.intersect = .{ .polygon = .{ .points = outline.items } };
    return p.h.shape;
}

fn windowShape(ctx: *const model.Ctx, parent: *El, node: *NodeData, band: f64, glyph: bool) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const accent = ctx.cfg.node_border;
    const padding = node.padding orelse 12;
    const radius = 12.0;
    const w = @max(@max(p.h.w + padding * 2, node.width), 90);
    const h = @max(p.h.h + padding * 2 + band, node.height);
    const top = -h / 2;
    const group = try p.h.shape.insertFirst("g");
    try group.setAttr("class", "basic label-container");
    const rect = try group.insert("rect");
    _ = try (try (try (try (try (try rect.attrNum("x", -w / 2)).attrNum("y", top)).attrNum("width", w)).attrNum("height", h)).attrNum("rx", radius)).attrNum("ry", radius);
    try basic.setNodeStyle(rect, p.st);
    if (glyph) {
        const t = try group.insert("text");
        _ = try (try t.attrNum("x", -w / 2 + 12)).attrNum("y", top + 16);
        try t.setAttr("class", "console-glyph");
        try styled(t, a, "font-family:monospace;font-weight:bold;font-size:14px;fill:{s}", .{accent});
        try t.setText(">_");
        t.box = .{ .x = -w / 2 + 12, .y = top + 16 - 14, .w = 17, .h = 17 };
    } else {
        const line = try group.insert("line");
        _ = try (try (try (try line.attrNum("x1", -w / 2)).attrNum("y1", top + band)).attrNum("x2", w / 2)).attrNum("y2", top + band);
        try styled(line, a, "stroke:{s};stroke-width:1px", .{accent});
        for (0..3) |i| {
            const c = try group.insert("circle");
            _ = try (try (try c.attrNum("cx", -w / 2 + 12 + @as(f64, @floatFromInt(i)) * 9)).attrNum("cy", top + band / 2)).attrNum("r", 2.5);
            try styled(c, a, "fill:{s};stroke:none", .{accent});
        }
        const bar = try group.insert("rect");
        try bar.setAttr("class", "browser-address-bar");
        _ = try (try (try (try (try (try bar.attrNum("x", -w / 2 + 44)).attrNum("y", top + 4)).attrNum("width", @max(w - 56, 10))).attrNum("height", band - 8)).attrNum("rx", 3)).attrNum("ry", 3);
        try styled(bar, a, "fill:none;stroke:{s};stroke-width:1px;opacity:0.6", .{accent});
    }
    u.updateNodeBounds(node, group);
    try labelAt(p, a, top + band + (h - band) / 2);
    node.intersect = .rect;
    return p.h.shape;
}

pub fn consoleWindow(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return windowShape(ctx, parent, node, 20, true);
}

pub fn browser(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return windowShape(ctx, parent, node, 18, false);
}

pub fn person(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const padding = node.padding orelse 20;
    const w = @max(@max(p.h.w + padding * 2, node.width), 100);
    const head_r = @min(@max(w * 0.23, 16), 56);
    const overlap = head_r * 0.27;
    const body_h = @max(p.h.h + padding * 2, if (node.height != 0) node.height - (2 * head_r - overlap) else 0);
    const body_r = @min(w * 0.177, body_h * 0.45);
    const total_h = body_h + 2 * head_r - overlap;
    const top = -total_h / 2;
    const body_top = top + 2 * head_r - overlap;

    const group = try p.h.shape.insertFirst("g");
    try group.setAttr("class", "basic label-container");
    const body = try group.insert("rect");
    _ = try (try (try (try (try (try body.attrNum("x", -w / 2)).attrNum("y", body_top)).attrNum("width", w)).attrNum("height", body_h)).attrNum("rx", body_r)).attrNum("ry", body_r);
    try basic.setNodeStyle(body, p.st);
    const head = try group.insert("circle");
    _ = try (try (try head.attrNum("cx", 0)).attrNum("cy", top + head_r)).attrNum("r", head_r);
    try basic.setNodeStyle(head, p.st);
    u.updateNodeBounds(node, group);
    try labelAt(p, a, body_top + body_h / 2);

    const head_cy = top + head_r;
    const phi = std.math.asin(@min(1, (body_top - head_cy) / head_r)) * 180.0 / std.math.pi;
    var outline: std.ArrayList(Point) = .empty;
    try u.generateCirclePoints(a, &outline, 0, -head_cy, head_r, 24, 180 + phi, -phi);
    try u.generateCirclePoints(a, &outline, -(-w / 2 + body_r), -(body_top + body_r), body_r, 12, 90, 0);
    try u.generateCirclePoints(a, &outline, -(-w / 2 + body_r), -(total_h / 2 - body_r), body_r, 12, 360, 270);
    try u.generateCirclePoints(a, &outline, -(w / 2 - body_r), -(total_h / 2 - body_r), body_r, 12, 270, 180);
    try u.generateCirclePoints(a, &outline, -(w / 2 - body_r), -(body_top + body_r), body_r, 12, 180, 90);
    node.intersect = .{ .polygon = .{ .points = outline.items } };
    return p.h.shape;
}

pub fn collapsedGroup(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const indicator_row = 20.0;
    const gap = 8.0;
    const p = try pre(ctx, parent, node, null);
    const padding = node.padding orelse 8;
    const total_w = @max(@max(p.h.w + padding * 2, 80), node.width);
    const total_h = @max(p.h.h + gap + indicator_row + padding * 2, node.height);
    const x = -total_w / 2;
    const y = -total_h / 2;
    const shift = -(gap + indicator_row) / 2;
    const lx: f64 = if (ctx.cfg.node_html_labels) -p.h.w / 2 else 0;
    try p.h.label.setAttr("transform", try u.translate(a, lx, -p.h.h / 2 + shift + p.h.by));
    const cfg = ctx.cfg;
    const rect = try p.h.shape.insertFirst("rect");
    try rect.setAttr("class", "basic label-container collapsed-group");
    try rect.setAttr("style", p.st.node);
    try rect.setAttr("rx", "8");
    try rect.setAttr("ry", "8");
    _ = try (try (try (try rect.attrNum("x", x)).attrNum("y", y)).attrNum("width", total_w)).attrNum("height", total_h);
    try rect.setAttr("fill", cfg.cluster_bkg);
    try rect.setAttr("stroke", cfg.cluster_border);
    const sep_y = y + padding + p.h.h + gap;
    const line = try p.h.shape.insert("line");
    try line.setAttr("class", "collapsed-separator");
    _ = try (try (try (try line.attrNum("x1", x + 8)).attrNum("y1", sep_y)).attrNum("x2", x + total_w - 8)).attrNum("y2", sep_y);
    try line.setAttr("stroke", cfg.cluster_border);
    try line.setAttr("stroke-dasharray", "3, 3");
    const dot_y = sep_y + indicator_row / 2;
    var i: i32 = -1;
    while (i <= 1) : (i += 1) {
        const c = try p.h.shape.insert("circle");
        try c.setAttr("class", "collapsed-indicator");
        _ = try (try (try c.attrNum("cx", @as(f64, @floatFromInt(i)) * 10)).attrNum("cy", dot_y)).attrNum("r", 2.5);
        try c.setAttr("fill", cfg.cluster_border);
    }
    u.updateNodeBounds(node, rect);
    node.intersect = .rect;
    return p.h.shape;
}
