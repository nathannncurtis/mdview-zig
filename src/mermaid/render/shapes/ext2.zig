const std = @import("std");
const model = @import("../model.zig");
const dom = @import("../dom.zig");
const u = @import("util.zig");
const basic = @import("basic.zig");
const ext1 = @import("ext1.zig");
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;
const Opts = u.Opts;
const Error = u.Error;
const pad = basic.pad;
const pre = basic.pre;
const outer = ext1.outer;

pub fn multiPath(ctx: *const model.Ctx, p: basic.Pre, node: *NodeData, ds: []const []const u8, class: []const u8) Error!*El {
    _ = ctx;
    const g = try p.h.shape.insertFirst("g");
    try g.setAttr("class", class);
    for (ds) |d| {
        const path = try g.insert("path");
        try path.setAttr("d", d);
        if (p.st.node.len > 0) try path.setAttr("style", p.st.node);
    }
    u.updateNodeBounds(node, g);
    return g;
}

pub fn slopedRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    if (node.width != 0 or node.height != 0) {
        node.width = @max(node.width - px * 2, 10);
        node.height = @max(node.height / 1.5 - py * 2, 10);
    }
    const p = try pre(ctx, parent, node, null);
    const tw = (if (node.width != 0) node.width else p.h.w) + px * 2;
    const th = ((if (node.height != 0) node.height else p.h.h) + py * 2) * 1.5;
    const w = tw;
    const h = th / 1.5;
    const x = -w / 2;
    const y = -h / 2;
    const pts = [_]Point{ .{ .x = x, .y = y }, .{ .x = x, .y = y + h }, .{ .x = x + w, .y = y + h }, .{ .x = x + w, .y = y - h / 2 } };
    _ = try outer(ctx, p, node, &pts, "basic label-container  outer-path", try std.fmt.allocPrint(a, "translate(0, {s})", .{try u.num(a, h / 4)}));
    try p.h.label.setAttr("transform", try u.translate(a, -w / 2 + pad(node), -h / 4 + pad(node)));
    return p.h.shape;
}

pub fn card(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const p = try pre(ctx, parent, node, null);
    const n: f64 = 12;
    const w = (if (node.width != 0) node.width else p.h.w) + (if (basic.isNeo(node)) 56 else pad(node) + n);
    const h = (if (node.height != 0) node.height else p.h.h) + (if (basic.isNeo(node)) 48 else pad(node));
    const pts = [_]Point{ .{ .x = n, .y = -h }, .{ .x = w, .y = -h }, .{ .x = w, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = -h + n }, .{ .x = n, .y = -h } };
    const poly = try u.insertPolygonShape(ctx.a, p.h.shape, w, h, &pts);
    try basic.setNodeStyle(poly, p.st);
    u.updateNodeBounds(node, poly);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(ctx.a, &pts) } };
    return p.h.shape;
}

pub fn trapezoidalPentagon(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    if (node.width != 0 or node.height != 0) {
        node.height = @max(5, node.height - py * 2);
        node.width = @max(15, node.width - px * 2);
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + px * 2;
    const h = (if (node.height != 0) node.height else p.h.h) + py * 2;
    const pts = [_]Point{
        .{ .x = (-w / 2) * 0.8, .y = -h / 2 }, .{ .x = (w / 2) * 0.8, .y = -h / 2 }, .{ .x = w / 2, .y = (-h / 2) * 0.6 },
        .{ .x = w / 2, .y = h / 2 },           .{ .x = -w / 2, .y = h / 2 },          .{ .x = -w / 2, .y = (-h / 2) * 0.6 },
    };
    _ = try outer(ctx, p, node, &pts, "basic label-container outer-path", null);
    return p.h.shape;
}

pub fn dividedRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + basic.neoPad(node, 16);
    const h = p.h.h + basic.neoPad(node, 16);
    const ro = h * 0.2;
    const x = -w / 2;
    const y = -h / 2 - ro / 2;
    const pts = [_]Point{ .{ .x = x, .y = y + ro }, .{ .x = -x, .y = y + ro }, .{ .x = -x, .y = -y }, .{ .x = x, .y = -y }, .{ .x = x, .y = y }, .{ .x = -x, .y = y }, .{ .x = -x, .y = y + ro } };
    _ = try outer(ctx, p, node, &pts, "basic label-container outer-path", null);
    try p.h.label.setAttr("transform", try u.translate(a, x + pad(node) / 2, y + ro + pad(node) / 2));
    node.intersect = .rect;
    return p.h.shape;
}

pub fn shadedProcess(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const f: f64 = 8;
    const p = try pre(ctx, parent, node, null);
    const tw = (if (node.width != 0) node.width else p.h.w) + basic.neoPad(node, 16) * 2 + (if (basic.isNeo(node)) f else f * 2);
    const th = (if (node.height != 0) node.height else p.h.h) + basic.neoPad(node, 12) * 2;
    const w = tw - f;
    const h = th;
    const x = f - tw / 2;
    const y = -th / 2;
    const pts = [_]Point{ .{ .x = x, .y = y }, .{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h }, .{ .x = x - f, .y = y + h }, .{ .x = x - f, .y = y }, .{ .x = x, .y = y }, .{ .x = x, .y = y + h } };
    _ = try outer(ctx, p, node, &pts, "basic label-container outer-path", null);
    try p.h.label.setAttr("transform", try u.translate(a, f / 2 - p.h.w / 2, -(p.h.h / 2)));
    node.intersect = .rect;
    return p.h.shape;
}

pub fn taggedRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    const ratio: f64 = 0.2;
    if (node.width != 0 or node.height != 0) {
        node.height = @max(node.height - py * 2, 10);
        node.width = @max(node.width - px * 2 - ratio * (node.height + py * 2), 10);
    }
    const p = try pre(ctx, parent, node, null);
    const th = (if (node.height != 0) node.height else p.h.h) + py * 2;
    const tag_w = ratio * th;
    const tag_h = ratio * th;
    const tw = (if (node.width != 0) node.width else p.h.w) + px * 2 + tag_w;
    const w = tw - tag_w;
    const h = th;
    const x = -w / 2;
    const y = -h / 2;
    const rect_pts = [_]Point{ .{ .x = x - tag_w / 2, .y = y }, .{ .x = x + w + tag_w / 2, .y = y }, .{ .x = x + w + tag_w / 2, .y = y + h }, .{ .x = x - tag_w / 2, .y = y + h } };
    const tag_pts = [_]Point{ .{ .x = x + w - tag_w / 2, .y = y + h }, .{ .x = x + w + tag_w / 2, .y = y + h }, .{ .x = x + w + tag_w / 2, .y = y + h - tag_h } };
    _ = try multiPath(ctx, p, node, &.{ try u.createPathFromPoints(a, &rect_pts), try u.createPathFromPoints(a, &tag_pts) }, "basic label-container outer-path");
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &rect_pts) } };
    return p.h.shape;
}

pub fn multiRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    const ro: f64 = if (basic.isNeo(node)) 10 else 5;
    if (node.width != 0 or node.height != 0) {
        node.width = @max(node.width - px * 2 - 2 * ro, 10);
        node.height = @max(node.height - py * 2 - 2 * ro, 10);
    }
    const p = try pre(ctx, parent, node, null);
    const tw = (if (node.width != 0) node.width else p.h.w) + px * 2 + 2 * ro;
    const th = (if (node.height != 0) node.height else p.h.h) + py * 2 + 2 * ro;
    const w = tw - 2 * ro;
    const h = th - 2 * ro;
    const x = -w / 2;
    const y = -h / 2;
    const op = [_]Point{
        .{ .x = x - ro, .y = y + ro },     .{ .x = x - ro, .y = y + h + ro },     .{ .x = x + w - ro, .y = y + h + ro },
        .{ .x = x + w - ro, .y = y + h },  .{ .x = x + w, .y = y + h },           .{ .x = x + w, .y = y + h - ro },
        .{ .x = x + w + ro, .y = y + h - ro }, .{ .x = x + w + ro, .y = y - ro }, .{ .x = x + ro, .y = y - ro },
        .{ .x = x + ro, .y = y },          .{ .x = x, .y = y },                   .{ .x = x, .y = y + ro },
    };
    const ip = [_]Point{ .{ .x = x, .y = y + ro }, .{ .x = x + w - ro, .y = y + ro }, .{ .x = x + w - ro, .y = y + h }, .{ .x = x + w, .y = y + h }, .{ .x = x + w, .y = y }, .{ .x = x, .y = y } };
    _ = try multiPath(ctx, p, node, &.{ try u.createPathFromPoints(a, &op), try u.createPathFromPoints(a, &ip) }, "basic label-container outer-path");
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2) - ro, -(p.h.h / 2) + ro));
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &op) } };
    return p.h.shape;
}

fn generateArcPoints(a: std.mem.Allocator, out: *std.ArrayList(Point), x1: f64, y1: f64, x2: f64, y2: f64, rx: f64, ry: f64, clockwise: bool) !void {
    const n = 20;
    const mid_x = (x1 + x2) / 2;
    const mid_y = (y1 + y2) / 2;
    const angle = std.math.atan2(y2 - y1, x2 - x1);
    const dx = (x2 - x1) / 2;
    const dy = (y2 - y1) / 2;
    const tx = dx / rx;
    const ty = dy / ry;
    const distance = @sqrt(tx * tx + ty * ty);
    const scd = @sqrt(@max(0, 1 - distance * distance));
    const sgn: f64 = if (clockwise) -1 else 1;
    const cx = mid_x + scd * ry * @sin(angle) * sgn;
    const cy = mid_y - scd * rx * @cos(angle) * sgn;
    const sa = std.math.atan2((y1 - cy) / ry, (x1 - cx) / rx);
    const ea = std.math.atan2((y2 - cy) / ry, (x2 - cx) / rx);
    var range = ea - sa;
    if (clockwise and range < 0) range += 2 * std.math.pi;
    if (!clockwise and range > 0) range -= 2 * std.math.pi;
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / (n - 1);
        const ang = sa + t * range;
        try out.append(a, .{ .x = cx + rx * @cos(ang), .y = cy + ry * @sin(ang) });
    }
}

pub fn bowTieRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const th = (if (node.height != 0) node.height else p.h.h) + basic.neoPad(node, 12);
    const ry = th / 2;
    const rx = ry / (2.5 + th / 50);
    const big = @max(rx, ry);
    const small = @min(rx, ry);
    const sagitta = small * (1 - @sqrt(1 - std.math.pow(f64, th / big / 2, 2)));
    const tw = (if (node.width != 0) node.width else p.h.w) + basic.neoPad(node, 16) * 2 + sagitta;
    const w = tw - sagitta;
    const h = th;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = w / 2, .y = -h / 2 });
    try pts.append(a, .{ .x = -w / 2, .y = -h / 2 });
    try generateArcPoints(a, &pts, -w / 2, -h / 2, -w / 2, h / 2, rx, ry, false);
    try pts.append(a, .{ .x = w / 2, .y = h / 2 });
    try generateArcPoints(a, &pts, w / 2, h / 2, w / 2, -h / 2, rx, ry, true);
    _ = try outer(ctx, p, node, pts.items, "basic label-container outer-path", try u.translate(a, rx / 2, 0));
    return p.h.shape;
}

pub fn curvedTrapezoid(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const h = @max(5, @max(p.h.h + basic.neoPad(node, 12) * 2, node.height));
    const radius = h / 2;
    const cap = radius - @sqrt(@max(0, radius * radius - (p.h.h / 2) * (p.h.h / 2)));
    const side = @max(h / 4, cap);
    const lpx = basic.neoPad(node, 16);
    const w = @max(@max(20, p.h.w + lpx * 2 + side * 2), @max((p.h.w + lpx * 2) * 1.25, node.width));
    const rw = w - radius;
    const tw = h / 4;
    var pts: std.ArrayList(Point) = .empty;
    try pts.appendSlice(a, &.{ .{ .x = rw, .y = 0 }, .{ .x = tw, .y = 0 }, .{ .x = 0, .y = h / 2 }, .{ .x = tw, .y = h }, .{ .x = rw, .y = h } });
    try u.generateCirclePoints(a, &pts, -rw, -h / 2, radius, 50, 270, 90);
    _ = try outer(ctx, p, node, pts.items, "basic label-container outer-path", try u.translate(a, -w / 2, -h / 2));
    return p.h.shape;
}
