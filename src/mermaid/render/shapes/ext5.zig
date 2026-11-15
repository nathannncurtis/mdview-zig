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
const pad = basic.pad;
const pre = basic.pre;

const Pts = std.ArrayList(Point);

fn circ(a: std.mem.Allocator, out: *Pts, neg: bool, cx: f64, cy: f64, r: f64, n: usize, start: f64, end: f64) !void {
    const s = start * std.math.pi / 180.0;
    const e = end * std.math.pi / 180.0;
    const step = (e - s) / @as(f64, @floatFromInt(n - 1));
    for (0..n) |i| {
        const ang = s + @as(f64, @floatFromInt(i)) * step;
        const x = cx + r * @cos(ang);
        const y = cy + r * @sin(ang);
        try out.append(a, if (neg) .{ .x = -x, .y = -y } else .{ .x = x, .y = y });
    }
}

fn openPath(a: std.mem.Allocator, pts: []const Point) ![]const u8 {
    const d = try u.createPathFromPoints(a, pts);
    return d[0 .. d.len - 2];
}

fn finish(ctx: *const model.Ctx, p: basic.Pre, node: *NodeData, braces: []const []const Point, rect_pts: []const Point, tx: f64, lx: f64, ly: f64) Error!*El {
    const a = ctx.a;
    var st = u.roughStyle(ctx, p.st.node);
    st.fill = null;
    const g = try El.create(a, "g");
    var i = braces.len;
    while (i > 0) {
        i -= 1;
        try g.append(try u.rough.drawPath(a, try openPath(a, braces[i]), st));
    }
    const rect = try u.rough.drawPath(a, try u.createPathFromPoints(a, rect_pts), st);
    try rect.setAttr("stroke-opacity", "0");
    try g.append(rect);
    _ = try u.insertRough(p.h.shape, g, "text", p.st.node);
    try g.setAttr("transform", try u.translate(a, tx, 0));
    try p.h.label.setAttr("transform", try u.translateC(a, lx, ly));
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, rect_pts) } };
    return p.h.shape;
}

pub fn curlyBraceLeft(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + basic.neoPad(node, 18);
    const h = p.h.h + basic.neoPad(node, 12);
    const r = @max(5, h * 0.1);
    var br: Pts = .empty;
    try circ(a, &br, true, w / 2, -h / 2, r, 30, -90, 0);
    try br.append(a, .{ .x = -w / 2 - r, .y = r });
    try circ(a, &br, true, w / 2 + r * 2, -r, r, 20, -180, -270);
    try circ(a, &br, true, w / 2 + r * 2, r, r, 20, -90, -180);
    try br.append(a, .{ .x = -w / 2 - r, .y = -h / 2 });
    try circ(a, &br, true, w / 2, h / 2, r, 20, 0, 90);
    var rp: Pts = .empty;
    try rp.appendSlice(a, &.{ .{ .x = w / 2, .y = -h / 2 - r }, .{ .x = -w / 2, .y = -h / 2 - r } });
    try circ(a, &rp, true, w / 2, -h / 2, r, 20, -90, 0);
    try rp.append(a, .{ .x = -w / 2 - r, .y = -r });
    try circ(a, &rp, true, w / 2 + w * 0.1, -r, r, 20, -180, -270);
    try circ(a, &rp, true, w / 2 + w * 0.1, r, r, 20, -90, -180);
    try rp.append(a, .{ .x = -w / 2 - r, .y = h / 2 });
    try circ(a, &rp, true, w / 2, h / 2, r, 20, 0, 90);
    try rp.appendSlice(a, &.{ .{ .x = -w / 2, .y = h / 2 + r }, .{ .x = w / 2, .y = h / 2 + r } });
    return finish(ctx, p, node, &.{br.items}, rp.items, r, -w / 2 + r, -h / 2 + pad(node) / 2);
}

pub fn curlyBraceRight(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + (if (basic.isNeo(node)) 36 else pad(node));
    const h = p.h.h + (if (basic.isNeo(node)) 24 else pad(node));
    const r = @max(5, h * 0.1);
    var br: Pts = .empty;
    try circ(a, &br, false, w / 2, -h / 2, r, 20, -90, 0);
    try br.append(a, .{ .x = w / 2 + r, .y = -r });
    try circ(a, &br, false, w / 2 + r * 2, -r, r, 20, -180, -270);
    try circ(a, &br, false, w / 2 + r * 2, r, r, 20, -90, -180);
    try br.append(a, .{ .x = w / 2 + r, .y = h / 2 });
    try circ(a, &br, false, w / 2, h / 2, r, 20, 0, 90);
    var rp: Pts = .empty;
    try rp.appendSlice(a, &.{ .{ .x = -w / 2, .y = -h / 2 - r }, .{ .x = w / 2, .y = -h / 2 - r } });
    try circ(a, &rp, false, w / 2, -h / 2, r, 20, -90, 0);
    try rp.append(a, .{ .x = w / 2 + r, .y = -r });
    try circ(a, &rp, false, w / 2 + r * 2, -r, r, 20, -180, -270);
    try circ(a, &rp, false, w / 2 + r * 2, r, r, 20, -90, -180);
    try rp.append(a, .{ .x = w / 2 + r, .y = h / 2 });
    try circ(a, &rp, false, w / 2, h / 2, r, 20, 0, 90);
    try rp.appendSlice(a, &.{ .{ .x = w / 2, .y = h / 2 + r }, .{ .x = -w / 2, .y = h / 2 + r } });
    return finish(ctx, p, node, &.{br.items}, rp.items, -r, -w / 2 + pad(node) / 2, -h / 2 + pad(node) / 2);
}

pub fn curlyBraces(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + (if (basic.isNeo(node)) 36 else pad(node));
    const h = p.h.h + (if (basic.isNeo(node)) 24 else pad(node));
    const r = @max(5, h * 0.1);
    var lb: Pts = .empty;
    try circ(a, &lb, true, w / 2, -h / 2, r, 30, -90, 0);
    try lb.append(a, .{ .x = -w / 2 - r, .y = r });
    try circ(a, &lb, true, w / 2 + r * 2, -r, r, 20, -180, -270);
    try circ(a, &lb, true, w / 2 + r * 2, r, r, 20, -90, -180);
    try lb.append(a, .{ .x = -w / 2 - r, .y = -h / 2 });
    try circ(a, &lb, true, w / 2, h / 2, r, 20, 0, 90);
    var rb: Pts = .empty;
    try circ(a, &rb, true, -w / 2 + r + r / 2, -h / 2, r, 20, -90, -180);
    try rb.append(a, .{ .x = w / 2 - r / 2, .y = r });
    try circ(a, &rb, true, -w / 2 - r / 2, -r, r, 20, 0, 90);
    try circ(a, &rb, true, -w / 2 - r / 2, r, r, 20, -90, 0);
    try rb.append(a, .{ .x = w / 2 - r / 2, .y = -r });
    try circ(a, &rb, true, -w / 2 + r + r / 2, h / 2, r, 30, -180, -270);
    var rp: Pts = .empty;
    try rp.appendSlice(a, &.{ .{ .x = w / 2, .y = -h / 2 - r }, .{ .x = -w / 2, .y = -h / 2 - r } });
    try circ(a, &rp, true, w / 2, -h / 2, r, 20, -90, 0);
    try rp.append(a, .{ .x = -w / 2 - r, .y = -r });
    try circ(a, &rp, true, w / 2 + r * 2, -r, r, 20, -180, -270);
    try circ(a, &rp, true, w / 2 + r * 2, r, r, 20, -90, -180);
    try rp.append(a, .{ .x = -w / 2 - r, .y = h / 2 });
    try circ(a, &rp, true, w / 2, h / 2, r, 20, 0, 90);
    try rp.appendSlice(a, &.{ .{ .x = -w / 2, .y = h / 2 + r }, .{ .x = w / 2 - r - r / 2, .y = h / 2 + r } });
    try circ(a, &rp, true, -w / 2 + r + r / 2, -h / 2, r, 20, -90, -180);
    try rp.append(a, .{ .x = w / 2 - r / 2, .y = r });
    try circ(a, &rp, true, -w / 2 - r / 2, -r, r, 20, 0, 90);
    try circ(a, &rp, true, -w / 2 - r / 2, r, r, 20, -90, 0);
    try rp.append(a, .{ .x = w / 2 - r / 2, .y = -r });
    try circ(a, &rp, true, -w / 2 + r + r / 2, h / 2, r, 30, -180, -270);
    return finish(ctx, p, node, &.{ lb.items, rb.items }, rp.items, r - r / 4, -w / 2 + pad(node) / 2, -h / 2 + pad(node) / 2);
}
