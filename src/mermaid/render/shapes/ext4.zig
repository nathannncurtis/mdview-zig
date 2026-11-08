const std = @import("std");
const model = @import("../model.zig");
const dom = @import("../dom.zig");
const u = @import("util.zig");
const basic = @import("basic.zig");
const ext1 = @import("ext1.zig");
const ext2 = @import("ext2.zig");
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;
const Opts = u.Opts;
const Error = u.Error;
const pad = basic.pad;
const pre = basic.pre;
const outer = ext1.outer;
const sine = u.generateFullSineWavePoints;

pub fn waveEdgedRectangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    var adjust = true;
    if (node.width != 0 or node.height != 0) {
        adjust = false;
        node.width = @max(10, node.width - px * 2);
        node.height = @max(10, node.height - py * 2);
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + px * 2;
    const h = (if (node.height != 0) node.height else p.h.h) + py * 2;
    const amp = if (basic.isNeo(node)) h / 4 else h / 8;
    const fh = h + (if (adjust) amp else -amp);
    const extra = if (14 - w > 0) (14 - w) / 2 else 0;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = -w / 2 - extra, .y = fh / 2 });
    try sine(a, &pts, -w / 2 - extra, fh / 2, w / 2 + extra, fh / 2, amp, 0.8);
    try pts.append(a, .{ .x = w / 2 + extra, .y = -fh / 2 });
    try pts.append(a, .{ .x = -w / 2 - extra, .y = -fh / 2 });
    _ = try outer(ctx, p, node, pts.items, "basic label-container outer-path", try u.translateC(a, 0, -amp / 2));
    try p.h.label.setAttr("transform", try u.translateC(a, -w / 2 + pad(node), -h / 2 + pad(node) - amp));
    return p.h.shape;
}

pub fn waveRectangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 20);
    if (node.width != 0 or node.height != 0) {
        node.width = @max(20, node.width);
        node.height = @max(10, node.height);
        const amp0 = @min(node.height * 0.2, node.height / 4);
        node.height = @ceil(node.height - py - amp0 * (20.0 / 9.0));
        node.width = node.width - px * 2;
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + px * 2;
    const h = (if (node.height != 0) node.height else p.h.h) + py;
    const amp = h / 8;
    const fh = h + amp * 2;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = -w / 2, .y = fh / 2 });
    try sine(a, &pts, -w / 2, fh / 2, w / 2, fh / 2, amp, 1);
    try pts.append(a, .{ .x = w / 2, .y = -fh / 2 });
    try sine(a, &pts, w / 2, -fh / 2, -w / 2, -fh / 2, amp, -1);
    _ = try outer(ctx, p, node, pts.items, "basic label-container", null);
    return p.h.shape;
}

pub fn linedWaveEdgedRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    if (node.width != 0 or node.height != 0) {
        node.width = @max(10, node.width * 10 / 11 - px * 2);
        node.height = @max(10, node.height - py * 2);
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + px * 2;
    const h = (if (node.height != 0) node.height else p.h.h) + py * 2;
    const amp = if (basic.isNeo(node)) h / 4 else h / 8;
    const fh = h + amp;
    const e = (w / 2) * 0.1;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = -w / 2 - e, .y = -fh / 2 });
    try pts.append(a, .{ .x = -w / 2 - e, .y = fh / 2 });
    try sine(a, &pts, -w / 2 - e, fh / 2, w / 2 + e, fh / 2, amp, 0.8);
    try pts.append(a, .{ .x = w / 2 + e, .y = -fh / 2 });
    try pts.append(a, .{ .x = -w / 2 - e, .y = -fh / 2 });
    try pts.append(a, .{ .x = -w / 2, .y = -fh / 2 });
    try pts.append(a, .{ .x = -w / 2, .y = (fh / 2) * 1.1 });
    try pts.append(a, .{ .x = -w / 2, .y = -fh / 2 });
    _ = try outer(ctx, p, node, pts.items, "basic label-container outer-path", try u.translateC(a, 0, -amp / 2));
    try p.h.label.setAttr("transform", try u.translateC(a, -w / 2 + pad(node) + e / 2, -h / 2 + pad(node) - amp));
    return p.h.shape;
}

pub fn multiWaveEdgedRectangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    const p = try pre(ctx, parent, node, null);
    var adjust = true;
    if (node.width != 0 or node.height != 0) {
        adjust = false;
        node.width = node.width - px * 2;
        node.height = node.height - py * 3;
    }
    const w = @max(p.h.w, node.width) + px * 2;
    const h = @max(p.h.h, node.height) + py * 3;
    const amp = if (basic.isNeo(node)) h / 4 else h / 8;
    const fh = h + (if (adjust) amp / 2 else -amp / 2);
    const x = -w / 2;
    const y = -fh / 2;
    const ro: f64 = 10;
    var wave: std.ArrayList(Point) = .empty;
    try sine(a, &wave, x - ro, y + fh + ro, x + w - ro, y + fh + ro, amp, 0.8);
    const last = wave.items[wave.items.len - 1];
    var op: std.ArrayList(Point) = .empty;
    try op.append(a, .{ .x = x - ro, .y = y + ro });
    try op.append(a, .{ .x = x - ro, .y = y + fh + ro });
    try op.appendSlice(a, wave.items);
    try op.appendSlice(a, &.{
        .{ .x = x + w - ro, .y = last.y - ro },     .{ .x = x + w, .y = last.y - ro },  .{ .x = x + w, .y = last.y - 2 * ro },
        .{ .x = x + w + ro, .y = last.y - 2 * ro }, .{ .x = x + w + ro, .y = y - ro },  .{ .x = x + ro, .y = y - ro },
        .{ .x = x + ro, .y = y },                   .{ .x = x, .y = y },                .{ .x = x, .y = y + ro },
    });
    const ip = [_]Point{ .{ .x = x, .y = y + ro }, .{ .x = x + w - ro, .y = y + ro }, .{ .x = x + w - ro, .y = last.y - ro }, .{ .x = x + w, .y = last.y - ro }, .{ .x = x + w, .y = y }, .{ .x = x, .y = y } };
    const g = try ext2.multiPath(ctx, p, node, &.{ try u.createPathFromPoints(a, op.items), try u.createPathFromPoints(a, &ip) }, "basic label-container outer-path");
    try g.setAttr("transform", try u.translateC(a, 0, -amp / 2));
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2) - ro, -(p.h.h / 2) + ro - amp));
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = op.items } };
    return p.h.shape;
}

pub fn taggedWaveEdgedRectangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = @max(p.h.w + pad(node) * 2, node.width);
    const h = @max(p.h.h + pad(node) * 2, node.height);
    const amp = h / 8;
    const tag_w = 0.2 * w;
    const tag_h = 0.2 * h;
    const fh = h + amp;
    const e = (w / 2) * 0.1;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = -w / 2 - e, .y = fh / 2 });
    try sine(a, &pts, -w / 2 - e, fh / 2, w / 2 + e, fh / 2, amp, 0.8);
    try pts.append(a, .{ .x = w / 2 + e, .y = -fh / 2 });
    try pts.append(a, .{ .x = -w / 2 - e, .y = -fh / 2 });
    const x = -w / 2 + e;
    const y = -fh / 2 - tag_h * 0.4;
    var tag: std.ArrayList(Point) = .empty;
    try tag.appendSlice(a, &.{ .{ .x = x + w - tag_w, .y = (y + h) * 1.3 }, .{ .x = x + w, .y = y + h - tag_h }, .{ .x = x + w, .y = (y + h) * 0.9 } });
    try sine(a, &tag, x + w, (y + h) * 1.25, x + w - tag_w, (y + h) * 1.3, -h * 0.02, 0.5);
    const g = try ext2.multiPath(ctx, p, node, &.{ try u.createPathFromPoints(a, pts.items), try u.createPathFromPoints(a, tag.items) }, "basic label-container outer-path");
    try g.setAttr("transform", try u.translateC(a, 0, -amp / 2));
    try p.h.label.setAttr("transform", try u.translateC(a, -w / 2 + pad(node), -h / 2 + pad(node) - amp / 2));
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = pts.items } };
    return p.h.shape;
}
