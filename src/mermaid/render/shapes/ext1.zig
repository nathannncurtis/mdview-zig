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

pub fn outer(ctx: *const model.Ctx, p: basic.Pre, node: *NodeData, pts: []const Point, class: []const u8, transform: ?[]const u8) Error!*El {
    const a = ctx.a;
    const g = try u.insertOuterPath(p.h.shape, try u.createPathFromPoints(a, pts), class, p.st.node);
    if (transform) |t| try g.setAttr("transform", t);
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, pts) } };
    return g;
}

pub fn bareShape(ctx: *const model.Ctx, parent: *El, node: *NodeData) Error!struct { shape: *El, st: u.Styles } {
    const a = ctx.a;
    const st = try u.styles2String(a, node);
    node.label_style = st.label;
    const shape = try parent.insert("g");
    try shape.setAttr("class", try u.getNodeClasses(a, node, null));
    try shape.setAttr("id", node.dom_id orelse node.id);
    return .{ .shape = shape, .st = st };
}

pub fn hourglass(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    node.label = "";
    const p = try pre(ctx, parent, node, null);
    const w = @max(30, node.width);
    const h = @max(30, node.height);
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = w, .y = 0 }, .{ .x = 0, .y = h }, .{ .x = w, .y = h } };
    _ = try outer(ctx, p, node, &pts, "basic label-container outer-path", try u.translate(a, -w / 2, -h / 2));
    return p.h.shape;
}

pub fn triangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const lpx = if (basic.isNeo(node)) pad(node) * 2 else pad(node);
    if (node.width != 0 or node.height != 0) {
        node.width = @max(10, (node.width - lpx) / 2);
        node.height = @max(10, node.height);
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + lpx;
    const h = if (node.height != 0) node.height else w + p.h.h;
    const tw = h;
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = tw, .y = 0 }, .{ .x = tw / 2, .y = -h } };
    _ = try outer(ctx, p, node, &pts, "outer-path", try u.translate(a, -h / 2, h / 2));
    node.width = w;
    node.height = h;
    u.updateNodeBounds(node, p.h.shape.kids.items[0]);
    try p.h.label.setAttr("transform", try u.translate(a, -p.h.w / 2, h / 2 - (p.h.h + pad(node) / @as(f64, if (ctx.cfg.html_labels) 2.0 else 1.0)) + 2 * p.h.by));
    return p.h.shape;
}

pub fn flippedTriangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const lpx = if (basic.isNeo(node)) pad(node) * 2 else pad(node);
    if (node.width != 0 or node.height != 0) {
        node.height = @max(10, node.height);
        node.width = @max(10, node.width - lpx - lpx / 2);
    }
    const p = try pre(ctx, parent, node, null);
    const w = (if (node.width != 0) node.width else p.h.w) + lpx;
    const h = if (node.height != 0) node.height else w + p.h.h;
    const tw = h;
    const pts = [_]Point{ .{ .x = 0, .y = -h }, .{ .x = tw, .y = -h }, .{ .x = tw / 2, .y = 0 } };
    _ = try outer(ctx, p, node, &pts, "outer-path", try u.translate(a, -h / 2, h / 2));
    node.width = w;
    node.height = h;
    u.updateNodeBounds(node, p.h.shape.kids.items[0]);
    try p.h.label.setAttr("transform", try u.translate(a, -p.h.w / 2, -h / 2 + pad(node) / 2 + 2 * p.h.by));
    return p.h.shape;
}

pub fn lightningBolt(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    node.label = "";
    const b = try bareShape(ctx, parent, node);
    const w = @max(35, node.width);
    const h = @max(35, node.height);
    const gap: f64 = 7;
    const pts = [_]Point{
        .{ .x = w, .y = 0 },       .{ .x = 0, .y = h + gap / 2 }, .{ .x = w - 2 * gap, .y = h + gap / 2 },
        .{ .x = 0, .y = 2 * h },   .{ .x = w, .y = h - gap / 2 }, .{ .x = 2 * gap, .y = h - gap / 2 },
    };
    const g = try u.insertOuterPath(b.shape, try u.createPathFromPoints(a, &pts), "outer-path", b.st.node);
    try g.setAttr("transform", try std.fmt.allocPrint(a, "translate(-{s},{s})", .{ try u.num(a, w / 2), try u.num(a, -h) }));
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &pts) } };
    return b.shape;
}

pub fn halfRoundedRectangle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    if (node.width != 0 or node.height != 0) {
        node.height = @max(10, node.height - py * 2);
        node.width = @max(15, node.width - px * 2);
    }
    const p = try pre(ctx, parent, node, null);
    const h = (if (node.height != 0) node.height else @max(10, p.h.h)) + py * 2;
    const r = h / 2;
    const cap = r - @sqrt(@max(0, r * r - (p.h.h / 2) * (p.h.h / 2)));
    const w = (if (node.width != 0) node.width else @max(15, p.h.w) + cap * 2) + px * 2;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = -w / 2, .y = -h / 2 });
    try pts.append(a, .{ .x = w / 2 - r, .y = -h / 2 });
    try u.generateCirclePoints(a, &pts, -w / 2 + r, 0, r, 50, 90, 270);
    try pts.append(a, .{ .x = w / 2 - r, .y = h / 2 });
    try pts.append(a, .{ .x = -w / 2, .y = h / 2 });
    _ = try outer(ctx, p, node, pts.items, "basic label-container outer-path", null);
    return p.h.shape;
}

pub fn windowPane(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const off: f64 = 10;
    const px = basic.neoPad(node, 16);
    const py = basic.neoPad(node, 12);
    if (node.width != 0 or node.height != 0) {
        node.width = @max(node.width - px * 2 - off, 10);
        node.height = @max(node.height - py * 2 - off, 10);
    }
    const p = try pre(ctx, parent, node, null);
    const tw = (if (node.width != 0) node.width else p.h.w) + px * 2 + off;
    const th = (if (node.height != 0) node.height else p.h.h) + py * 2 + off;
    const w = tw - off;
    const h = th - off;
    const x = -w / 2;
    const y = -h / 2;
    const n = struct {
        fn f(al: std.mem.Allocator, v: f64) ![]const u8 {
            return u.num(al, v);
        }
    }.f;
    const d = try std.fmt.allocPrint(a, "M{s},{s} L{s},{s} L{s},{s} L{s},{s} L{s},{s} M{s},{s} L{s},{s} M{s},{s} L{s},{s}", .{
        try n(a, x - off), try n(a, y - off), try n(a, x + w),   try n(a, y - off), try n(a, x + w), try n(a, y + h),
        try n(a, x - off), try n(a, y + h),   try n(a, x - off), try n(a, y - off), try n(a, x - off), try n(a, y),
        try n(a, x + w),   try n(a, y),       try n(a, x),       try n(a, y - off), try n(a, x),     try n(a, y + h),
    });
    const g = try u.insertOuterPath(p.h.shape, d, "basic label-container outer-path", p.st.node);
    try g.setAttr("transform", try u.translate(a, off / 2, off / 2));
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2) + off / 2, -(p.h.h / 2) + off / 2));
    u.updateNodeBounds(node, g);
    const pts = [_]Point{ .{ .x = x - off, .y = y - off }, .{ .x = x - off, .y = y + h }, .{ .x = x + w, .y = y + h }, .{ .x = x + w, .y = y - off } };
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &pts) } };
    return p.h.shape;
}

pub fn filledCircle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    node.label = "";
    const b = try bareShape(ctx, parent, node);
    const c = try b.shape.insertFirst("circle");
    try c.setAttr("class", "filled-circle");
    if (b.st.node.len > 0) try c.setAttr("style", b.st.node);
    _ = try (try (try c.attrNum("r", 7)).attrNum("cx", 0)).attrNum("cy", 0);
    u.updateNodeBounds(node, c);
    node.intersect = .{ .circle = 7 };
    return b.shape;
}

pub fn crossedCircle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    node.label = "";
    const b = try bareShape(ctx, parent, node);
    const r = @max(30, node.width);
    const k = @cos(std.math.pi / 4.0) * r;
    const g = try b.shape.insertFirst("g");
    try g.setAttr("class", "outer-path");
    const c = try g.insert("circle");
    _ = try (try (try c.attrNum("r", r)).attrNum("cx", 0)).attrNum("cy", 0);
    const line = try g.insert("path");
    try line.setAttr("d", try std.fmt.allocPrint(a, "M {s},{s} L {s},{s} M {s},{s} L {s},{s}", .{
        try u.num(a, -k), try u.num(a, k),  try u.num(a, k),  try u.num(a, -k),
        try u.num(a, k),  try u.num(a, k),  try u.num(a, -k), try u.num(a, -k),
    }));
    if (b.st.node.len > 0) {
        try c.setAttr("style", b.st.node);
        try line.setAttr("style", b.st.node);
    }
    u.updateNodeBounds(node, g);
    node.intersect = .{ .circle = r };
    return b.shape;
}
