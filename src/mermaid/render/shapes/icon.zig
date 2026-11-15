const std = @import("std");
const model = @import("../model.zig");
const dom = @import("../dom.zig");
const u = @import("util.zig");
const basic = @import("basic.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;
const Opts = u.Opts;
const Error = u.Error;

// Stand-in for the image loader: integration sets it once src/images.zig can report natural sizes.
pub var natural_size_fn: ?*const fn (href: []const u8) ?[2]f64 = null;

const Kind = enum { square, rounded, circle, plain };

fn styleValue(node: *const NodeData, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for ([2][]const []const u8{ node.css_compiled_styles, node.css_styles }) |list| {
        for (list) |s| {
            const colon = std.mem.indexOfScalar(u8, s, ':') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, s[0..colon], " "), key)) continue;
            const rest = s[colon + 1 ..];
            const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            found = std.mem.trim(u8, rest[0..end], " ");
        }
    }
    return found;
}

fn hasLabel(node: *const NodeData) bool {
    return if (node.label) |l| l.len > 0 else false;
}

fn roundedRectD(a: Allocator, x: f64, y: f64, w: f64, h: f64, r: f64) Allocator.Error![]const u8 {
    const n = u.num;
    const rs = try n(a, r);
    return std.fmt.allocPrint(a, "M {s} {s} H {s} A {s} {s} 0 0 1 {s} {s} V {s} A {s} {s} 0 0 1 {s} {s} H {s} A {s} {s} 0 0 1 {s} {s} V {s} A {s} {s} 0 0 1 {s} {s} Z", .{
        try n(a, x + r),     try n(a, y),
        try n(a, x + w - r), rs,
        rs,                  try n(a, x + w),
        try n(a, y + r),     try n(a, y + h - r),
        rs,                  rs,
        try n(a, x + w - r), try n(a, y + h),
        try n(a, x + r),     rs,
        rs,                  try n(a, x),
        try n(a, y + h - r), try n(a, y + r),
        rs,                  rs,
        try n(a, x + r),     try n(a, y),
    });
}

fn rectD(a: Allocator, x: f64, y: f64, w: f64, h: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "M{s} {s} L{s} {s} L{s} {s} L{s} {s}", .{
        try u.num(a, x),     try u.num(a, y),
        try u.num(a, x + w), try u.num(a, y),
        try u.num(a, x + w), try u.num(a, y + h),
        try u.num(a, x),     try u.num(a, y + h),
    });
}

fn outerShape(a: Allocator, shape: *El, ow: f64, oh: f64, fill: []const u8) Allocator.Error!*El {
    const g = try shape.insert("g");
    const p = try g.insert("path");
    try p.setAttr("d", try rectD(a, -ow / 2, -oh / 2, ow, oh));
    try p.setAttr("stroke", "none");
    try p.setAttr("stroke-width", "0");
    try p.setAttr("fill", fill);
    return g;
}

// The icon packs are not registered on GitHub, so every icon draws Mermaid's unknown-icon graphic.
fn unknownIcon(parent: *El, size: f64) Allocator.Error!*El {
    const svg = try parent.insert("svg");
    try svg.setAttr("xmlns", "http://www.w3.org/2000/svg");
    _ = try svg.attrNum("width", size);
    _ = try svg.attrNum("height", size);
    try svg.setAttr("viewBox", "0 0 80 80");
    svg.box = .{ .x = 0, .y = 0, .w = size, .h = size };
    const g = try svg.insert("g");
    const r = try g.insert("rect");
    try r.setAttr("width", "80");
    try r.setAttr("height", "80");
    try r.setAttr("style", "fill: #087ebf; stroke-width: 0px;");
    const t = try g.insert("text");
    try t.setAttr("transform", "translate(21.16 64.67)");
    try t.setAttr("style", "fill: #fff; font-family: ArialMT, Arial; font-size: 67.75px;");
    const ts = try t.insert("tspan");
    try ts.setAttr("x", "0");
    try ts.setAttr("y", "0");
    try ts.setText("?");
    return svg;
}

fn labelBox(h: u.Helper) [2]f64 {
    return if (h.w > 0 or h.h > 0) .{ h.w + 4, h.h + 4 } else .{ 0, 0 };
}

fn iconShape(ctx: *const model.Ctx, parent: *El, node: *NodeData, kind: Kind) Error!*El {
    const a = ctx.a;
    const icon_size = @max(node.asset_height orelse 48, node.asset_width orelse 48);
    node.width = @max(icon_size, ctx.cfg.wrapping_width);
    const p = try basic.pre(ctx, parent, node, "icon-shape default");
    const bw = labelBox(p.h)[0];
    const bh = labelBox(p.h)[1];
    const top = if (node.pos) |c| c == 't' else false;
    const lp: f64 = if (hasLabel(node)) 8 else 0;
    const shape = p.h.shape;
    const fill = styleValue(node, "fill");

    var icon_el: ?*El = null;
    var iw: f64 = 0;
    var ih: f64 = 0;
    if (node.icon != null or kind == .circle) {
        const holder = try El.create(a, "g");
        if (node.icon != null) {
            const inner = try holder.insert("g");
            _ = try unknownIcon(inner, icon_size);
        }
        if (holder.bbox()) |b| {
            iw = b.w;
            ih = b.h;
        }
        icon_el = holder;
    }

    var width: f64 = icon_size;
    var height: f64 = icon_size;
    var bg: ?*El = null;
    switch (kind) {
        .square, .rounded => {
            width = icon_size + p.h.half_padding * 2;
            height = width;
            const el = try shape.insertFirst("path");
            try el.setAttr("d", try roundedRectD(a, -width / 2, -height / 2, width, height, if (kind == .rounded) 5 else 0.1));
            if (kind == .rounded) try el.setAttr("class", "icon-shape2");
            bg = el;
        },
        .circle => {
            const diameter = @max(iw, ih) * std.math.sqrt2 + 40;
            width = diameter;
            height = diameter;
            const el = try shape.insertFirst("circle");
            _ = try (try (try el.attrNum("r", diameter / 2)).attrNum("cx", 0)).attrNum("cy", 0);
            bg = el;
        },
        .plain => {},
    }
    if (bg) |el| {
        if (fill) |f| {
            try el.setAttr("fill", f);
            try el.setAttr("stroke", f);
        } else try el.setAttr("style", "stroke: none");
    }

    const ow = @max(width, bw);
    const oh = height + bh + lp;
    const outer = try outerShape(a, shape, ow, oh, "transparent");

    if (icon_el) |holder| {
        const g = try shape.insert("g");
        for (holder.kids.items) |k| try g.append(k);
        const ty = if (top) bh / 2 + lp / 2 - ih / 2 else -bh / 2 - lp / 2 - ih / 2;
        try g.setAttr("transform", try u.translateC(a, -iw / 2, ty));
        if (styleValue(node, "stroke")) |s| try g.setAttr("style", try std.fmt.allocPrint(a, "color: {s};", .{s}));
    }
    try p.h.label.setAttr("transform", try u.translateC(a, -bw / 2, if (top) -oh / 2 else oh / 2 - bh));
    if (bg) |el| try el.setAttr("transform", try u.translateC(a, 0, if (top) bh / 2 + lp / 2 else -bh / 2 - lp / 2));
    u.updateNodeBounds(node, outer);

    if (!hasLabel(node) or kind == .circle) {
        node.intersect = .rect;
    } else {
        node.intersect = .{ .polygon = .{ .points = try labelPoints(a, node, top, bw, bh, lp, width, height) } };
    }
    return shape;
}

fn labelPoints(a: Allocator, node: *const NodeData, top: bool, bw: f64, bh: f64, lp: f64, w: f64, h: f64) Allocator.Error![]const Point {
    const nh = node.height;
    const pts: [8]Point = if (top) .{
        .{ .x = -bw / 2, .y = -nh / 2 },
        .{ .x = bw / 2, .y = -nh / 2 },
        .{ .x = bw / 2, .y = -nh / 2 + bh + lp },
        .{ .x = w / 2, .y = -nh / 2 + bh + lp },
        .{ .x = w / 2, .y = nh / 2 },
        .{ .x = -w / 2, .y = nh / 2 },
        .{ .x = -w / 2, .y = -nh / 2 + bh + lp },
        .{ .x = -bw / 2, .y = -nh / 2 + bh + lp },
    } else .{
        .{ .x = -w / 2, .y = -nh / 2 },
        .{ .x = w / 2, .y = -nh / 2 },
        .{ .x = w / 2, .y = -nh / 2 + h },
        .{ .x = bw / 2, .y = -nh / 2 + h },
        .{ .x = bw / 2 / 2, .y = nh / 2 },
        .{ .x = -bw / 2, .y = nh / 2 },
        .{ .x = -bw / 2, .y = -nh / 2 + h },
        .{ .x = -w / 2, .y = -nh / 2 + h },
    };
    return a.dupe(Point, &pts);
}

pub fn iconSquare(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return iconShape(ctx, parent, node, .square);
}

pub fn iconRounded(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return iconShape(ctx, parent, node, .rounded);
}

pub fn iconCircle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return iconShape(ctx, parent, node, .circle);
}

pub fn icon(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return iconShape(ctx, parent, node, .plain);
}

pub fn imageSquare(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const href = node.img orelse "";
    const natural: [2]f64 = if (natural_size_fn) |f| (f(href) orelse .{ 0, 0 }) else .{ 0, 0 };
    const aspect: f64 = if (natural[1] != 0) natural[0] / natural[1] else 1;
    node.image_aspect_ratio = aspect;

    const default_width = ctx.cfg.wrapping_width;
    const raw_w = @max(if (hasLabel(node)) default_width else 0, node.asset_width orelse natural[0]);
    const on = if (node.constraint) |c| std.mem.eql(u8, c, "on") else false;
    const ah = node.asset_height orelse 0;
    const iw = if (on) (if (ah != 0) ah * aspect else raw_w) else raw_w;
    const ih = if (on) iw / aspect else (node.asset_height orelse natural[1]);
    node.width = @max(iw, default_width);

    const p = try basic.pre(ctx, parent, node, "image-shape default");
    const bw = labelBox(p.h)[0];
    const bh = labelBox(p.h)[1];
    const top = if (node.pos) |c| c == 't' else false;
    const lp: f64 = if (hasLabel(node)) 8 else 0;
    const shape = p.h.shape;

    const bg = try shape.insertFirst("rect");
    _ = try (try (try (try bg.attrNum("x", -iw / 2)).attrNum("y", -ih / 2)).attrNum("width", iw)).attrNum("height", ih);

    const ow = @max(iw, bw);
    const oh = ih + bh + lp;
    const outer = try outerShape(a, shape, ow, oh, "none");

    if (node.img) |src| {
        const im = try shape.insert("image");
        try im.setAttr("href", src);
        _ = try (try im.attrNum("width", iw)).attrNum("height", ih);
        try im.setAttr("preserveAspectRatio", "none");
        try im.setAttr("transform", try u.translateC(a, -iw / 2, if (top) oh / 2 - ih else -oh / 2));
    }
    try p.h.label.setAttr("transform", try u.translateC(a, -bw / 2, if (top) -ih / 2 - bh / 2 - lp / 2 else ih / 2 - bh / 2 + lp / 2));
    try bg.setAttr("transform", try u.translateC(a, 0, if (top) bh / 2 + lp / 2 else -bh / 2 - lp / 2));
    u.updateNodeBounds(node, outer);

    if (!hasLabel(node)) {
        node.intersect = .rect;
    } else {
        node.intersect = .{ .polygon = .{ .points = try labelPoints(a, node, top, bw, bh, lp, iw, ih) } };
    }
    return shape;
}
