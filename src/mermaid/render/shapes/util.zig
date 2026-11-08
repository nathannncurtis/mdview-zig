const std = @import("std");
const model = @import("../model.zig");
const dom = @import("../dom.zig");
const labels = @import("../labels.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;

pub const Error = Allocator.Error || error{NoSuchShape};

pub const Opts = struct { dir: ?[]const u8 = null };

pub const Handler = *const fn (ctx: *const model.Ctx, parent: *El, node: *NodeData, opts: Opts) Error!*El;

pub const Styles = struct { label: []const u8, node: []const u8 };

fn isLabelStyle(key: []const u8) bool {
    const keys = [_][]const u8{ "color", "font-size", "font-family", "font-weight", "font-style", "text-decoration", "text-align", "text-transform", "line-height", "letter-spacing", "word-spacing", "text-shadow", "text-overflow", "white-space", "word-wrap", "word-break", "overflow-wrap", "hyphens" };
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

const Entry = struct { key: []const u8, value: []const u8 };

fn addStyle(a: Allocator, map: *std.ArrayList(Entry), style: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, style, ':');
    const key = std.mem.trim(u8, it.next() orelse return, " \t\r\n");
    const value = std.mem.trim(u8, it.next() orelse "", " \t\r\n");
    for (map.items) |*e| if (std.mem.eql(u8, e.key, key)) {
        e.value = value;
        return;
    };
    try map.append(a, .{ .key = key, .value = value });
}

pub fn styles2String(a: Allocator, node: *const NodeData) Allocator.Error!Styles {
    var map: std.ArrayList(Entry) = .empty;
    for (node.css_compiled_styles) |s| try addStyle(a, &map, s);
    for (node.css_styles) |s| try addStyle(a, &map, s);
    var lab: std.ArrayList(u8) = .empty;
    var nod: std.ArrayList(u8) = .empty;
    for (map.items) |e| {
        const dst = if (isLabelStyle(e.key)) &lab else &nod;
        if (dst.items.len > 0) try dst.append(a, ';');
        try dst.appendSlice(a, e.key);
        try dst.append(a, ':');
        try dst.appendSlice(a, e.value);
        try dst.appendSlice(a, " !important");
    }
    return .{ .label = lab.items, .node = nod.items };
}

pub fn getNodeClasses(a: Allocator, node: *const NodeData, extra: ?[]const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s} {s}", .{ if (std.mem.eql(u8, node.look, "handDrawn")) "rough-node" else "node", node.css_classes, extra orelse "" });
}

pub fn num(a: Allocator, v: f64) Allocator.Error![]const u8 {
    return dom.fmtNum(a, v);
}

pub fn translate(a: Allocator, x: f64, y: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "translate({s}, {s})", .{ try num(a, x), try num(a, y) });
}

pub fn translateC(a: Allocator, x: f64, y: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "translate({s},{s})", .{ try num(a, x), try num(a, y) });
}

pub const Helper = struct { shape: *El, w: f64, h: f64, half_padding: f64, label: *El, by: f64 = 0 };

pub fn labelHelper(ctx: *const model.Ctx, parent: *El, node: *NodeData, classes: ?[]const u8) Error!Helper {
    return labelHelperOpt(ctx, parent, node, classes, false);
}

pub fn labelHelperOpt(ctx: *const model.Ctx, parent: *El, node: *NodeData, classes: ?[]const u8, ignore_min_width: bool) Error!Helper {
    const a = ctx.a;
    const shape = try parent.insert("g");
    try shape.setAttr("class", classes orelse "node default");
    try shape.setAttr("id", node.dom_id orelse node.id);

    const label_el = try shape.insert("g");
    try label_el.setAttr("class", "label");
    try label_el.setAttr("style", node.label_style);

    const text = try labels.decodeEntities(a, node.label orelse "");
    const markdown = std.mem.eql(u8, node.label_type, "markdown");
    const t = try labels.createText(ctx, label_el, text, .{
        .style = node.label_style,
        .classes = if (markdown) "markdown-node-label" else "",
        .width = if (node.width != 0) node.width else node.wrapping_width orelse ctx.cfg.wrapping_width,
        .min_width = if (text.len > 0 and node.width == 0 and !ignore_min_width) node.min_width orelse 0 else 0,
        .add_svg_background = node.icon != null or node.img != null,
        .label_type = node.label_type,
        .html = ctx.cfg.node_html_labels,
    });
    const box = t.box.?;
    try label_el.setAttr("transform", try translate(a, -box.w / 2, -box.h / 2 + t.y_off));
    const r = try El.create(a, "rect");
    r.parent = label_el;
    try label_el.kids.insert(a, 0, r);
    return .{ .shape = shape, .w = box.w, .h = box.h, .half_padding = (node.padding orelse 0) / 2, .label = label_el, .by = t.y_off };
}

pub fn updateNodeBounds(node: *NodeData, el: *const El) void {
    if (el.bbox()) |b| {
        node.width = b.w;
        node.height = b.h;
    } else {
        node.width = 0;
        node.height = 0;
    }
}

pub fn pointsAttr(a: Allocator, points: []const Point) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (points, 0..) |p, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, try num(a, p.x));
        try out.append(a, ',');
        try out.appendSlice(a, try num(a, p.y));
    }
    return out.items;
}

pub fn insertPolygonShape(a: Allocator, parent: *El, w: f64, h: f64, points: []const Point) Allocator.Error!*El {
    const p = try parent.insertFirst("polygon");
    try p.setAttr("points", try pointsAttr(a, points));
    try p.setAttr("class", "label-container");
    try p.setAttr("transform", try translateC(a, -w / 2, h / 2));
    return p;
}

pub fn createPathFromPoints(a: Allocator, points: []const Point) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (points, 0..) |p, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{c}{s},{s}", .{ @as(u8, if (i == 0) 'M' else 'L'), try num(a, p.x), try num(a, p.y) }));
    }
    try out.appendSlice(a, " Z");
    return out.items;
}

// Rough.js with roughness 0 draws the exact outline, so one path stands in for its fill+stroke pair.
pub fn insertOuterPath(shape: *El, d: []const u8, class: []const u8, style: []const u8) Allocator.Error!*El {
    const g = try shape.insertFirst("g");
    try g.setAttr("class", class);
    const p = try g.insert("path");
    try p.setAttr("d", d);
    if (style.len > 0) try p.setAttr("style", style);
    return g;
}

pub fn generateCirclePoints(a: Allocator, out: *std.ArrayList(Point), cx: f64, cy: f64, radius: f64, n: usize, start_deg: f64, end_deg: f64) Allocator.Error!void {
    const s = start_deg * std.math.pi / 180.0;
    const e = end_deg * std.math.pi / 180.0;
    const step = (e - s) / @as(f64, @floatFromInt(n - 1));
    for (0..n) |i| {
        const ang = s + @as(f64, @floatFromInt(i)) * step;
        try out.append(a, .{ .x = -(cx + radius * @cos(ang)), .y = -(cy + radius * @sin(ang)) });
    }
}

pub fn generateFullSineWavePoints(a: Allocator, out: *std.ArrayList(Point), x1: f64, y1: f64, x2: f64, y2: f64, amplitude: f64, cycles: f64) Allocator.Error!void {
    const steps = 50;
    const dx = x2 - x1;
    const dy = y2 - y1;
    const cycle_len = dx / cycles;
    const freq = 2 * std.math.pi / cycle_len;
    const mid = y1 + dy / 2;
    for (0..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / steps;
        const x = x1 + t * dx;
        try out.append(a, .{ .x = x, .y = mid + amplitude * @sin(freq * (x - x1)) });
    }
}

pub fn intersectRect(node: *const NodeData, p: Point) Point {
    const dx = p.x - node.x;
    const dy = p.y - node.y;
    var w = node.width / 2;
    var h = node.height / 2;
    var sx: f64 = 0;
    var sy: f64 = 0;
    if (@abs(dy) * w > @abs(dx) * h) {
        if (dy < 0) h = -h;
        sx = if (dy == 0) 0 else h * dx / dy;
        sy = h;
    } else {
        if (dx < 0) w = -w;
        sx = w;
        sy = if (dx == 0) 0 else w * dy / dx;
    }
    return .{ .x = node.x + sx, .y = node.y + sy };
}

pub fn dupePoints(a: Allocator, pts: []const Point) Allocator.Error![]const Point {
    return a.dupe(Point, pts);
}

pub const test_support = struct {
    fn w(_: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
        return 8 * @as(f64, @floatFromInt(text.len));
    }

    pub fn ctx(arena: *std.heap.ArenaAllocator, cfg: *const model.Config) model.Ctx {
        const S = struct { var dummy: u8 = 0; };
        return .{ .a = arena.allocator(), .measurer = .{ .ctx = &S.dummy, .widthFn = w }, .cfg = cfg, .diagram_id = "t" };
    }
};
