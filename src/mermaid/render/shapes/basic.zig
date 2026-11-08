const std = @import("std");
const model = @import("../model.zig");
const dom = @import("../dom.zig");
const u = @import("util.zig");
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;
const Opts = u.Opts;
const Error = u.Error;

pub fn pad(node: *const NodeData) f64 {
    return node.padding orelse 0;
}

pub fn isNeo(node: *const NodeData) bool {
    return std.mem.eql(u8, node.look, "neo");
}

pub fn neoPad(node: *const NodeData, neo_v: f64) f64 {
    return if (isNeo(node)) neo_v else pad(node);
}

pub fn setNodeStyle(el: *El, st: u.Styles) !void {
    if (st.node.len > 0) try el.setAttr("style", st.node);
}

pub const Pre = struct { st: u.Styles, h: u.Helper };

pub fn pre(ctx: *const model.Ctx, parent: *El, node: *NodeData, classes: ?[]const u8) Error!Pre {
    return preOpt(ctx, parent, node, classes, false);
}

pub fn preOpt(ctx: *const model.Ctx, parent: *El, node: *NodeData, classes: ?[]const u8, ignore_min_width: bool) Error!Pre {
    const st = try u.styles2String(ctx.a, node);
    node.label_style = st.label;
    const cls = classes orelse try u.getNodeClasses(ctx.a, node, null);
    return .{ .st = st, .h = try u.labelHelperOpt(ctx, parent, node, cls, ignore_min_width) };
}

pub fn drawRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, opt_rx: f64, opt_ry: f64, lpx: f64, lpy: f64) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const tw = @max(p.h.w + lpx * 2, node.width);
    const th = @max(p.h.h + lpy * 2, node.height);
    var rx = node.rx;
    var ry = node.ry;
    if (opt_rx != 0 and opt_ry != 0) {
        rx = opt_rx;
        ry = opt_ry;
    }
    const rect = try p.h.shape.insertFirst("rect");
    try rect.setAttr("class", "basic label-container");
    try setNodeStyle(rect, p.st);
    if (rx) |v| _ = try rect.attrNum("rx", v);
    if (ry) |v| _ = try rect.attrNum("ry", v);
    _ = try rect.attrNum("x", -tw / 2);
    _ = try rect.attrNum("y", -th / 2);
    _ = try rect.attrNum("width", tw);
    _ = try rect.attrNum("height", th);
    _ = a;
    u.updateNodeBounds(node, rect);
    node.intersect = .rect;
    return p.h.shape;
}

pub fn squareRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return drawRect(ctx, parent, node, 0, 0, if (isNeo(node)) 16 else pad(node) * 2, neoPad(node, 12));
}

pub fn roundedRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return drawRect(ctx, parent, node, 5, 5, pad(node), pad(node));
}

fn polyShape(ctx: *const model.Ctx, node: *NodeData, p: Pre, w: f64, h: f64, points: []const Point) Error!*El {
    const poly = try u.insertPolygonShape(ctx.a, p.h.shape, w, h, points);
    try setNodeStyle(poly, p.st);
    u.updateNodeBounds(node, poly);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(ctx.a, points) } };
    return p.h.shape;
}

const arc_point_count = 50;

pub fn stadium(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const neo = isNeo(node);
    const px = if (neo) 40 else pad(node);
    const py = if (neo) 24 else pad(node);
    const h = p.h.h + py;
    const inscribed = h * @cos(std.math.pi / (2.0 * (arc_point_count - 1)));
    const cap_w = @sqrt(@max(0, inscribed * inscribed - p.h.h * p.h.h));
    const w = @max(p.h.w + h / 4 + px, @max(1.5 * h + (h - inscribed), p.h.w + px + h - cap_w));
    const r = h / 2;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, .{ .x = -w / 2 + r, .y = -h / 2 });
    try pts.append(a, .{ .x = w / 2 - r, .y = -h / 2 });
    try u.generateCirclePoints(a, &pts, -w / 2 + r, 0, r, arc_point_count, 90, 270);
    try pts.append(a, .{ .x = w / 2 - r, .y = h / 2 });
    try u.generateCirclePoints(a, &pts, w / 2 - r, 0, r, arc_point_count, 270, 450);
    const g = try u.insertOuterPath(p.h.shape, try u.createPathFromPoints(a, pts.items), "basic label-container outer-path", p.st.node);
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = pts.items } };
    return p.h.shape;
}

pub fn subroutine(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const p = try pre(ctx, parent, node, null);
    const tw = @max(p.h.w + 16 + neoPad(node, 28), node.width);
    const th = @max(p.h.h + neoPad(node, 12), node.height);
    const w = tw - 16;
    const h = th;
    const pts = [_]Point{
        .{ .x = 0, .y = 0 },      .{ .x = w, .y = 0 },      .{ .x = w, .y = -h },      .{ .x = 0, .y = -h },      .{ .x = 0, .y = 0 },
        .{ .x = -8, .y = 0 },     .{ .x = w + 8, .y = 0 },  .{ .x = w + 8, .y = -h },  .{ .x = -8, .y = -h },     .{ .x = -8, .y = 0 },
    };
    return polyShape(ctx, node, p, w, h, &pts);
}

pub fn cylinder(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const lp = neoPad(node, 24);
    const ow = node.width;
    if (node.width != 0) node.width = @max(8, node.width - lp);
    if (node.height != 0) {
        const rx0 = ow / 2;
        const ry0 = rx0 / (2.5 + ow / 50);
        node.height = @max(8, node.height - lp - ry0 * 3);
    }
    const p = try pre(ctx, parent, node, null);
    const w = @max(node.width, p.h.w) + lp;
    const rx = w / 2;
    const ry = rx / (2.5 + w / 50);
    const h = @max(node.height, p.h.h) + lp + ry;
    const d = try std.fmt.allocPrint(a, "M0,{s} a{s},{s} 0,0,0 {s},0 a{s},{s} 0,0,0 {s},0 l0,{s} a{s},{s} 0,0,0 {s},0 l0,{s}", .{
        try u.num(a, ry),  try u.num(a, rx), try u.num(a, ry), try u.num(a, w),  try u.num(a, rx), try u.num(a, ry),
        try u.num(a, -w),  try u.num(a, h),  try u.num(a, rx), try u.num(a, ry), try u.num(a, w),  try u.num(a, -h),
    });
    const path = try p.h.shape.insertFirst("path");
    try path.setAttr("d", d);
    try path.setAttr("class", "basic label-container outer-path");
    try setNodeStyle(path, p.st);
    _ = try path.attrNum("label-offset-y", ry);
    try path.setAttr("transform", try u.translate(a, -w / 2, -(h / 2 + ry)));
    u.updateNodeBounds(node, path);
    try p.h.label.setAttr("transform", try u.translate(a, -(p.h.w / 2), -(p.h.h / 2) + pad(node) / 1.5));
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

pub fn circle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const p = try preOpt(ctx, parent, node, null, true);
    const label_r = @sqrt(p.h.w * p.h.w + p.h.h * p.h.h) / 2;
    const r = if (isNeo(node)) label_r + 16 else label_r + p.h.half_padding;
    const c = try p.h.shape.insertFirst("circle");
    try c.setAttr("class", "basic label-container");
    try setNodeStyle(c, p.st);
    _ = try c.attrNum("r", r);
    _ = try c.attrNum("cx", 0);
    _ = try c.attrNum("cy", 0);
    u.updateNodeBounds(node, c);
    node.intersect = .{ .circle = r };
    return p.h.shape;
}

pub fn doubleCircle(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const p = try preOpt(ctx, parent, node, null, true);
    const label_r = @sqrt(p.h.w * p.h.w + p.h.h * p.h.h) / 2;
    const inner = (if (node.width != 0) node.width / 2 else label_r) + neoPad(node, 16);
    const outer = inner + if (isNeo(node)) @as(f64, 12) else 5;
    const g = try p.h.shape.insertFirst("g");
    try g.setAttr("class", "basic label-container");
    try setNodeStyle(g, p.st);
    const oc = try g.insertFirst("circle");
    const ic = try g.insert("circle");
    try oc.setAttr("class", "outer-circle");
    try setNodeStyle(oc, p.st);
    _ = try (try (try oc.attrNum("r", outer)).attrNum("cx", 0)).attrNum("cy", 0);
    try ic.setAttr("class", "inner-circle");
    try setNodeStyle(ic, p.st);
    _ = try (try (try ic.attrNum("r", inner)).attrNum("cx", 0)).attrNum("cy", 0);
    u.updateNodeBounds(node, g);
    node.intersect = .{ .circle = outer };
    return p.h.shape;
}

pub fn question(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const w = p.h.w + pad(node);
    const h = p.h.h + pad(node);
    const s = w + h;
    const pts = [_]Point{ .{ .x = s / 2, .y = 0 }, .{ .x = s, .y = -s / 2 }, .{ .x = s / 2, .y = -s }, .{ .x = 0, .y = -s / 2 } };
    const poly = try u.insertPolygonShape(a, p.h.shape, s, s, &pts);
    try poly.setAttr("transform", try std.fmt.allocPrint(a, "translate({s}, {s})", .{ try u.num(a, -s / 2 + 0.5), try u.num(a, s / 2) }));
    try setNodeStyle(poly, p.st);
    u.updateNodeBounds(node, poly);
    const sw = node.width;
    const pts2 = [_]Point{ .{ .x = sw / 2, .y = 0 }, .{ .x = sw, .y = -sw / 2 }, .{ .x = sw / 2, .y = -sw }, .{ .x = 0, .y = -sw / 2 } };
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &pts2) } };
    return p.h.shape;
}

pub fn hexagon(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const f: f64 = if (isNeo(node)) 3.5 else 4;
    const lpx = neoPad(node, 70);
    const lpy = neoPad(node, 32);
    if (node.width != 0 or node.height != 0) {
        const m0 = node.height / f;
        node.width = node.width - 2 * m0 - lpy;
        node.height = node.height - lpx;
    }
    const p = try pre(ctx, parent, node, null);
    const h = (if (node.height != 0) node.height else p.h.h) + lpx;
    const m = h / f;
    const w = (if (node.width != 0) node.width else p.h.w) + 2 * m + lpy;
    const pts = [_]Point{ .{ .x = m, .y = 0 }, .{ .x = w - m, .y = 0 }, .{ .x = w, .y = -h / 2 }, .{ .x = w - m, .y = -h }, .{ .x = m, .y = -h }, .{ .x = 0, .y = -h / 2 } };
    const el = try polyShape(ctx, node, p, w, h, &pts);
    return el;
}

fn leanShape(ctx: *const model.Ctx, parent: *El, node: *NodeData, kind: enum { right, left, trap }) Error!*El {
    const p = try pre(ctx, parent, node, null);
    const h = @max(p.h.h + pad(node), node.height);
    const w = @max(p.h.w + if (isNeo(node)) pad(node) * 2 else pad(node), node.width - h);
    const k = 3 * h / 6;
    const pts: [4]Point = switch (kind) {
        .right => .{ .{ .x = -k, .y = 0 }, .{ .x = w, .y = 0 }, .{ .x = w + k, .y = -h }, .{ .x = 0, .y = -h } },
        .left => .{ .{ .x = 0, .y = 0 }, .{ .x = w + k, .y = 0 }, .{ .x = w, .y = -h }, .{ .x = -k, .y = -h } },
        .trap => .{ .{ .x = -k, .y = 0 }, .{ .x = w + k, .y = 0 }, .{ .x = w, .y = -h }, .{ .x = 0, .y = -h } },
    };
    const el = try polyShape(ctx, node, p, w, h, &pts);
    return el;
}

pub fn leanRight(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return leanShape(ctx, parent, node, .right);
}

pub fn leanLeft(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return leanShape(ctx, parent, node, .left);
}

pub fn trapezoid(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    return leanShape(ctx, parent, node, .trap);
}

pub fn invTrapezoid(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const p = try pre(ctx, parent, node, null);
    const h = @max(p.h.h + pad(node) * 2, node.height);
    const w = @max(p.h.w + (if (isNeo(node)) pad(node) * 2 else pad(node)) * 2, node.width - h);
    const k = 3 * h / 6;
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = w, .y = 0 }, .{ .x = w + k, .y = -h }, .{ .x = -k, .y = -h } };
    const el = try polyShape(ctx, node, p, w, h, &pts);
    return el;
}

pub fn rectLeftInvArrow(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const neo = isNeo(node);
    const label_w = p.h.w + if (neo) @as(f64, 42) else pad(node);
    const h = @max(p.h.h + if (neo) @as(f64, 24) else pad(node), node.height);
    const w = @max(label_w, node.width - h / 4);
    const x = -w / 2;
    const y = -h / 2;
    const notch = y / 2;
    const pts = [_]Point{ .{ .x = x + notch, .y = y }, .{ .x = x, .y = 0 }, .{ .x = x + notch, .y = -y }, .{ .x = -x, .y = -y }, .{ .x = -x, .y = y } };
    const g = try u.insertOuterPath(p.h.shape, try u.createPathFromPoints(a, &pts), "basic label-container outer-path", p.st.node);
    try g.setAttr("transform", try u.translateC(a, -notch / 2, 0));
    try p.h.label.setAttr("transform", try u.translate(a, -notch / 2 - p.h.w / 2, -(p.h.h / 2)));
    u.updateNodeBounds(node, g);
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &pts) } };
    return p.h.shape;
}

pub fn text(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const p = try pre(ctx, parent, node, null);
    const tw = @max(p.h.w + pad(node), node.width);
    const th = @max(p.h.h + pad(node), node.height);
    const rect = try p.h.shape.insertFirst("rect");
    try rect.setAttr("class", "text");
    try setNodeStyle(rect, p.st);
    _ = try (try (try (try (try (try rect.attrNum("rx", 0)).attrNum("ry", 0)).attrNum("x", -tw / 2)).attrNum("y", -th / 2)).attrNum("width", tw)).attrNum("height", th);
    u.updateNodeBounds(node, rect);
    node.intersect = .rect;
    return p.h.shape;
}

pub fn anchor(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const st = try u.styles2String(a, node);
    node.label_style = st.label;
    const shape = try parent.insert("g");
    try shape.setAttr("class", try u.getNodeClasses(a, node, null));
    try shape.setAttr("id", node.dom_id orelse node.id);
    const c = try shape.insertFirst("circle");
    try c.setAttr("class", "anchor");
    _ = try (try (try c.attrNum("r", 1)).attrNum("cx", 0)).attrNum("cy", 0);
    u.updateNodeBounds(node, c);
    node.intersect = .{ .circle = 1 };
    return shape;
}

pub fn labelRect(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const h = try u.labelHelper(ctx, parent, node, "label");
    const rect = try h.shape.insertFirst("rect");
    _ = try (try rect.attrNum("width", 0.1)).attrNum("height", 0.1);
    try h.shape.setAttr("class", "label edgeLabel");
    try h.label.setAttr("transform", try u.translate(a, -(h.w / 2), -(h.h / 2)));
    u.updateNodeBounds(node, rect);
    node.intersect = .rect;
    return h.shape;
}

pub fn note(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const p = try pre(ctx, parent, node, null);
    const tw = @max(p.h.w + pad(node) * 2, node.width);
    const th = @max(p.h.h + pad(node) * 2, node.height);
    const rect = try p.h.shape.insertFirst("rect");
    try rect.setAttr("class", "basic label-container outer-path");
    try setNodeStyle(rect, p.st);
    _ = try (try (try (try rect.attrNum("x", -tw / 2)).attrNum("y", -th / 2)).attrNum("width", tw)).attrNum("height", th);
    try p.h.label.setAttr("class", "label noteLabel");
    try p.h.label.setAttr("transform", try u.translate(a, -p.h.w / 2, -(p.h.h / 2)));
    u.updateNodeBounds(node, rect);
    node.intersect = .rect;
    return p.h.shape;
}

pub fn forkJoin(ctx: *const model.Ctx, parent: *El, node: *NodeData, opts: Opts) Error!*El {
    const a = ctx.a;
    node.label = "";
    const st = try u.styles2String(a, node);
    const shape = try parent.insert("g");
    try shape.setAttr("class", try u.getNodeClasses(a, node, null));
    try shape.setAttr("id", node.dom_id orelse node.id);
    var w = @max(70, node.width);
    var h = @max(10, node.height);
    if (opts.dir) |d| if (std.mem.eql(u8, d, "LR") or std.mem.eql(u8, d, "RL")) {
        w = @max(10, node.width);
        h = @max(70, node.height);
    };
    const rect = try shape.insertFirst("rect");
    try setNodeStyle(rect, st);
    _ = try (try (try (try rect.attrNum("x", -w / 2)).attrNum("y", -h / 2)).attrNum("width", w)).attrNum("height", h);
    u.updateNodeBounds(node, rect);
    // state.padding default (config.schema.yaml) halved, as forkJoin.ts does
    node.width += 4;
    node.height += 4;
    node.intersect = .rect;
    return shape;
}

fn stateDims(node: *NodeData) void {
    if (node.width != 0 or node.height != 0) {
        if (node.width < 14) node.width = 14;
        if (node.height < 14) node.height = 14;
    }
    if (node.width == 0) node.width = 14;
    if (node.height == 0) node.height = 14;
}

pub fn stateStart(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    stateDims(node);
    const shape = try parent.insert("g");
    try shape.setAttr("class", "node default");
    try shape.setAttr("id", node.dom_id orelse node.id);
    const c = try shape.insertFirst("circle");
    try c.setAttr("class", "state-start");
    _ = try (try (try c.attrNum("r", node.width / 2)).attrNum("width", node.width)).attrNum("height", node.height);
    u.updateNodeBounds(node, c);
    node.intersect = .{ .circle = node.width / 2 };
    _ = ctx;
    return shape;
}

pub fn stateEnd(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    const st = try u.styles2String(a, node);
    node.label_style = st.label;
    stateDims(node);
    const shape = try parent.insert("g");
    try shape.setAttr("class", "node default");
    try shape.setAttr("id", node.dom_id orelse node.id);
    const g = try shape.insertFirst("g");
    try g.setAttr("class", "outer-path");
    const outer = try g.insert("circle");
    _ = try (try (try outer.attrNum("r", node.width / 2)).attrNum("cx", 0)).attrNum("cy", 0);
    try outer.setAttr("class", "state-end-outer");
    const inner = try g.insert("circle");
    _ = try (try (try inner.attrNum("r", node.width * 5 / 28)).attrNum("cx", 0)).attrNum("cy", 0);
    try inner.setAttr("class", "state-end-inner");
    u.updateNodeBounds(node, g);
    node.intersect = .{ .circle = node.width / 2 };
    return shape;
}

pub fn choice(ctx: *const model.Ctx, parent: *El, node: *NodeData, _: Opts) Error!*El {
    const a = ctx.a;
    node.label = "";
    const st = try u.styles2String(a, node);
    const shape = try parent.insert("g");
    try shape.setAttr("class", try u.getNodeClasses(a, node, null));
    try shape.setAttr("id", node.dom_id orelse node.id);
    const s = @max(28, node.width);
    const pts = [_]Point{ .{ .x = 0, .y = s / 2 }, .{ .x = s / 2, .y = 0 }, .{ .x = 0, .y = -s / 2 }, .{ .x = -s / 2, .y = 0 } };
    _ = try u.insertOuterPath(shape, try u.createPathFromPoints(a, &pts), "", st.node);
    node.width = 28;
    node.height = 28;
    node.intersect = .{ .polygon = .{ .points = try u.dupePoints(a, &pts) } };
    return shape;
}
