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

fn n(a: std.mem.Allocator, v: f64) ![]const u8 {
    return u.num(a, v);
}

pub fn linedCylinder(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const lp = basic.neoPad(node, 16);
    const lpy = basic.neoPad(node, 24);
    if (node.width != 0 or node.height != 0) {
        const ow = node.width;
        node.width = @max(10, node.width - lp);
        const rx0 = ow / 2;
        const ry0 = rx0 / (2.5 + ow / 50);
        node.height = @max(10, node.height - lpy - ry0 * 3);
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + lp * 2;
    const rx = w / 2;
    const ry = rx / (2.5 + w / 50);
    const h = (if (node.height != 0) node.height else p.h.h) + ry + lpy * 2;
    const off = h * 0.1;
    const d = try std.fmt.allocPrint(a, "M0,{s} a{s},{s} 0,0,0 {s},0 a{s},{s} 0,0,0 {s},0 l0,{s} a{s},{s} 0,0,0 {s},0 l0,{s} M0,{s} a{s},{s} 0,0,0 {s},0", .{
        try n(a, ry),  try n(a, rx), try n(a, ry), try n(a, w),  try n(a, rx), try n(a, ry),  try n(a, -w),
        try n(a, h),   try n(a, rx), try n(a, ry), try n(a, w),  try n(a, -h), try n(a, ry + off), try n(a, rx),
        try n(a, ry),  try n(a, w),
    });
    const path = try p.h.shape.insertFirst("path");
    try path.setAttr("d", d);
    try path.setAttr("class", "basic label-container outer-path");
    try basic.setNodeStyle(path, p.st);
    _ = try path.attrNum("label-offset-y", ry);
    try path.setAttr("transform", try u.translate(a, -w / 2, -(h / 2 + ry)));
    u.updateNodeBounds(node, path);
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2), -(p.h.h / 2) + ry));
    node.intersect = .{ .custom = cylinderIntersect };
    return p.h.shape;
}

fn cylinderIntersect(node: *const NodeData, pt: Point) Point {
    var pos = u.intersectRect(node, pt);
    const rx = node.width / 2;
    const ry = rx / (2.5 + node.width / 50);
    const x = pos.x - node.x;
    if (rx != 0 and (@abs(x) < node.width / 2 or (@abs(x) == node.width / 2 and @abs(pos.y - node.y) > node.height / 2 - ry))) {
        var y = ry * ry * (1 - (x * x) / (rx * rx));
        if (y > 0) y = @sqrt(y);
        y = ry - y;
        if (pt.y - node.y > 0) y = -y;
        pos.y += y;
    }
    return pos;
}

pub fn tiltedCylinder(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const lp = if (basic.isNeo(node)) @as(f64, 12) else pad(node) / 2;
    const oh = node.height;
    if (node.height != 0) node.height = @max(5, node.height - lp);
    if (node.width != 0) {
        const ry0 = oh / 2;
        const rx0 = ry0 / (2.5 + oh / 50);
        node.width = @max(10, node.width - lp - rx0 * 3);
    }
    const p = try pre(ctx, parent, node, null);
    const h = @max(node.height, p.h.h) + lp;
    const ry = h / 2;
    const rx = ry / (2.5 + h / 50);
    const w = @max(node.width, p.h.w) + rx + lp;
    const d = try std.fmt.allocPrint(a, "M0,0 a{s},{s} 0,0,1 0,{s} l{s},0 a{s},{s} 0,0,1 0,{s} M{s},{s} a{s},{s} 0,0,0 0,{s} l{s},0", .{
        try n(a, rx), try n(a, ry), try n(a, -h), try n(a, w),  try n(a, rx), try n(a, ry),
        try n(a, h),  try n(a, w),  try n(a, -h), try n(a, rx), try n(a, ry), try n(a, h),
        try n(a, -w),
    });
    const path = try p.h.shape.insertFirst("path");
    try path.setAttr("d", d);
    try path.setAttr("class", "basic label-container outer-path");
    try basic.setNodeStyle(path, p.st);
    _ = try path.attrNum("label-offset-x", rx);
    try path.setAttr("transform", try std.fmt.allocPrint(a, "translate({s}, {s} )", .{ try n(a, -w / 2), try n(a, h / 2) }));
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2) - rx, -(p.h.h / 2)));
    u.updateNodeBounds(node, path);
    node.intersect = .{ .custom = tiltedIntersect };
    return p.h.shape;
}

fn tiltedIntersect(node: *const NodeData, pt: Point) Point {
    var pos = u.intersectRect(node, pt);
    const ry = node.height / 2;
    const rx = ry / (2.5 + node.height / 50);
    const y = pos.y - node.y;
    if (ry != 0 and (@abs(y) < node.height / 2 or (@abs(y) == node.height / 2 and @abs(pos.x - node.x) > node.width / 2 - rx))) {
        var x = rx * rx * (1 - (y * y) / (ry * ry));
        if (x != 0) x = @sqrt(@abs(x));
        x = rx - x;
        if (pt.x - node.x > 0) x = -x;
        pos.x += x;
    }
    return pos;
}

pub fn datastore(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const shape = try basic.drawRect(ctx, parent, node, 0, 0, pad(node) * 2, pad(node));
    for (shape.kids.items) |k| {
        const cls = k.getAttr("class") orelse continue;
        if (std.mem.eql(u8, cls, "basic label-container")) {
            const w = k.num("width");
            const h = k.num("height");
            if (w > 0 and h > 0) try k.setAttr("stroke-dasharray", try std.fmt.allocPrint(ctx.a, "{s} {s}", .{ try n(ctx.a, w), try n(ctx.a, h) }));
        }
    }
    return shape;
}

fn arc(a: std.mem.Allocator, out: *std.ArrayList(u8), rx: f64, ry: f64, rot: u8, sweep: u8, dx: f64, dy: f64) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, "a{s},{s} {d} 0,{d} {s},{s} ", .{ try n(a, rx), try n(a, ry), rot, sweep, try n(a, dx), try n(a, dy) }));
}

pub fn cloud(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + 2 * p.h.half_padding;
    const h = p.h.h + 2 * p.h.half_padding;
    const r1 = 0.15 * w;
    const r2 = 0.25 * w;
    const r3 = 0.35 * w;
    const r4 = 0.2 * w;
    var d: std.ArrayList(u8) = .empty;
    try d.appendSlice(a, "M0 0 ");
    try arc(a, &d, r1, r1, 0, 1, w * 0.25, -1 * w * 0.1);
    try arc(a, &d, r3, r3, 1, 1, w * 0.4, -1 * w * 0.1);
    try arc(a, &d, r2, r2, 1, 1, w * 0.35, w * 0.2);
    try arc(a, &d, r1, r1, 1, 1, w * 0.15, h * 0.35);
    try arc(a, &d, r4, r4, 1, 1, -1 * w * 0.15, h * 0.65);
    try arc(a, &d, r2, r1, 1, 1, -1 * w * 0.25, w * 0.15);
    try arc(a, &d, r3, r3, 1, 1, -1 * w * 0.5, 0);
    try arc(a, &d, r1, r1, 1, 1, -1 * w * 0.25, -1 * w * 0.15);
    try arc(a, &d, r1, r1, 1, 1, -1 * w * 0.1, -1 * h * 0.35);
    try arc(a, &d, r4, r4, 1, 1, w * 0.1, -1 * h * 0.65);
    try d.appendSlice(a, "H0 V0 Z");
    const path = try p.h.shape.insertFirst("path");
    try path.setAttr("class", "basic label-container");
    try basic.setNodeStyle(path, p.st);
    try path.setAttr("d", d.items);
    try p.h.label.setAttr("transform", try u.translate(a, -p.h.w / 2, -p.h.h / 2));
    try path.setAttr("transform", try u.translate(a, -w / 2, -h / 2));
    u.updateNodeBounds(node, path);
    node.intersect = .rect;
    return p.h.shape;
}

pub fn bang(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + 10 * p.h.half_padding;
    const h = p.h.h + 8 * p.h.half_padding;
    const r = 0.15 * w;
    const ew = @max(w, p.h.w + 20);
    const eh = @max(h, p.h.h + 20);
    try p.h.label.setAttr("transform", try u.translate(a, -p.h.w / 2, -p.h.h / 2));
    var d: std.ArrayList(u8) = .empty;
    try d.appendSlice(a, "M0 0 ");
    try arc(a, &d, r, r, 1, 0, ew * 0.25, -1 * eh * 0.1);
    try arc(a, &d, r, r, 1, 0, ew * 0.25, 0);
    try arc(a, &d, r, r, 1, 0, ew * 0.25, 0);
    try arc(a, &d, r, r, 1, 0, ew * 0.25, eh * 0.1);
    try arc(a, &d, r, r, 1, 0, ew * 0.15, eh * 0.33);
    try arc(a, &d, r * 0.8, r * 0.8, 1, 0, 0, eh * 0.34);
    try arc(a, &d, r, r, 1, 0, -1 * ew * 0.15, eh * 0.33);
    try arc(a, &d, r, r, 1, 0, -1 * ew * 0.25, eh * 0.15);
    try arc(a, &d, r, r, 1, 0, -1 * ew * 0.25, 0);
    try arc(a, &d, r, r, 1, 0, -1 * ew * 0.25, 0);
    try arc(a, &d, r, r, 1, 0, -1 * ew * 0.25, -1 * eh * 0.15);
    try arc(a, &d, r, r, 1, 0, -1 * ew * 0.1, -1 * eh * 0.33);
    try arc(a, &d, r * 0.8, r * 0.8, 1, 0, 0, -1 * eh * 0.34);
    try arc(a, &d, r, r, 1, 0, ew * 0.1, -1 * eh * 0.33);
    try d.appendSlice(a, "H0 V0 Z");
    const path = try p.h.shape.insertFirst("path");
    try path.setAttr("class", "basic label-container");
    try basic.setNodeStyle(path, p.st);
    try path.setAttr("d", d.items);
    try path.setAttr("transform", try u.translate(a, -ew / 2, -eh / 2));
    u.updateNodeBounds(node, path);
    node.intersect = .rect;
    return p.h.shape;
}
