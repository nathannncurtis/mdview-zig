const std = @import("std");
const model = @import("model.zig");
const dom = @import("dom.zig");
const labels = @import("labels.zig");
const curves = @import("curves.zig");
const geom = @import("geom.zig");
const intersect = @import("intersect.zig");
const pathlen = @import("pathlen.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;
const Point = model.Point;
const NodeData = model.NodeData;
const EdgeData = model.EdgeData;
const Ctx = model.Ctx;

pub const Error = Allocator.Error || geom.PointError;

pub const ClusterEntry = struct { id: []const u8, node: *const NodeData };

pub const ClusterDb = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, id: []const u8) ?ClusterEntry,

    pub fn get(self: ClusterDb, id: []const u8) ?ClusterEntry {
        return self.getFn(self.ctx, id);
    }
};

pub const Paths = struct {
    updated_path: ?[]Point = null,
    original_path: []const Point = &.{},
    path_el: ?*El = null,
};

const Terminals = struct { start_left: ?*El = null, start_right: ?*El = null, end_left: ?*El = null, end_right: ?*El = null };

threadlocal var edge_labels: std.StringHashMapUnmanaged(*El) = .empty;
threadlocal var terminal_labels: std.StringHashMapUnmanaged(Terminals) = .empty;

pub fn clear() void {
    edge_labels = .empty;
    terminal_labels = .empty;
}

pub fn jsNum(a: Allocator, v: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isInf(v)) return if (v > 0) "Infinity" else "-Infinity";
    if (v == 0) return "0";
    const av = @abs(v);
    if (av < 1e-6 or av >= 1e21) {
        const s = try std.fmt.allocPrint(a, "{e}", .{v});
        if (std.mem.indexOf(u8, s, "e-") == null) {
            const i = std.mem.indexOfScalar(u8, s, 'e').?;
            return std.fmt.allocPrint(a, "{s}e+{s}", .{ s[0..i], s[i + 1 ..] });
        }
        return s;
    }
    return std.fmt.allocPrint(a, "{d}", .{v});
}

pub fn isLabelStyle(key: []const u8) bool {
    const keys = [_][]const u8{ "color", "font-size", "font-family", "font-weight", "font-style", "text-decoration", "text-align", "text-transform", "line-height", "letter-spacing", "word-spacing", "text-shadow", "text-overflow", "white-space", "word-wrap", "word-break", "overflow-wrap", "hyphens" };
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

const KV = struct { key: []const u8, value: ?[]const u8 };

fn compileStyles(a: Allocator, lists: []const []const []const u8) Allocator.Error![]KV {
    var out: std.ArrayList(KV) = .empty;
    for (lists) |list| for (list) |style| {
        const c = std.mem.indexOfScalar(u8, style, ':');
        const key = std.mem.trim(u8, if (c) |i| style[0..i] else style, " \t\r\n");
        var value: ?[]const u8 = null;
        if (c) |i| {
            const rest = style[i + 1 ..];
            const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            value = std.mem.trim(u8, rest[0..end], " \t\r\n");
        }
        for (out.items) |*kv| if (std.mem.eql(u8, kv.key, key)) {
            kv.value = value;
            break;
        } else {} else try out.append(a, .{ .key = key, .value = value });
    };
    return out.items;
}

fn labelStylesOf(a: Allocator, edge: *const EdgeData) Allocator.Error![]const u8 {
    const kvs = try compileStyles(a, &.{ edge.css_compiled_styles, edge.label_style });
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (kvs) |kv| {
        if (!isLabelStyle(kv.key)) continue;
        if (!first) try out.append(a, ';');
        first = false;
        try out.print(a, "{s}:{s} !important", .{ kv.key, kv.value orelse "" });
    }
    return out.items;
}

fn translate(a: Allocator, x: f64, y: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "translate({s}, {s})", .{ try jsNum(a, x), try jsNum(a, y) });
}

fn terminalLabel(ctx: *const Ctx, elem: *El, text: []const u8, style: []const u8, own_inner: bool) !*El {
    const a = ctx.a;
    const outer = try elem.insert("g");
    try outer.setAttr("class", "edgeTerminals");
    const inner = try outer.insert("g");
    try inner.setAttr("class", "inner");
    const l = try labels.createLabel(ctx, text, style, false, false);
    try (if (own_inner) inner else outer).append(l);
    const box = l.box orelse dom.Box{ .x = 0, .y = 0, .w = 0, .h = 0 };
    try inner.setAttr("transform", try translate(a, if (ctx.cfg.html_labels) -box.w / 2 else 0, -box.h / 2));
    return outer;
}

pub fn insertEdgeLabel(ctx: *const Ctx, elem: *El, edge: *EdgeData) !void {
    const a = ctx.a;
    const label_styles = try labelStylesOf(a, edge);
    const edge_label = try elem.insert("g");
    try edge_label.setAttr("class", "edgeLabel");
    const label = try edge_label.insert("g");
    try label.setAttr("class", "label");
    try label.setAttr("data-id", edge.id);
    const md = std.mem.eql(u8, edge.label_type, "markdown");
    const text_el = try labels.createText(ctx, label, edge.label orelse "", .{
        .style = label_styles,
        .is_node = false,
        .add_svg_background = true,
        .label_type = if (md) "markdown" else "text",
    });
    const box = text_el.box orelse dom.Box{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var tb = box;
    if (!ctx.cfg.html_labels) for (text_el.kids.items) |k| if (std.mem.eql(u8, k.tag, "text")) {
        tb = k.box orelse box;
    };
    try label.setAttr("transform", try translate(a, if (ctx.cfg.html_labels) -box.w / 2 else -(tb.x + tb.w / 2), -tb.h / 2));
    try edge_labels.put(a, edge.id, edge_label);
    edge.width = box.w;
    edge.height = box.h;

    var t: Terminals = .{};
    if (nonEmpty(edge.start_label_left)) |s| t.start_left = try terminalLabel(ctx, elem, s, label_styles, true);
    if (nonEmpty(edge.start_label_right)) |s| t.start_right = try terminalLabel(ctx, elem, s, label_styles, true);
    if (nonEmpty(edge.end_label_left)) |s| t.end_left = try terminalLabel(ctx, elem, s, label_styles, false);
    if (nonEmpty(edge.end_label_right)) |s| t.end_right = try terminalLabel(ctx, elem, s, label_styles, false);
    if (t.start_left != null or t.start_right != null or t.end_left != null or t.end_right != null) {
        const gop = try terminal_labels.getOrPut(a, edge.id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (t.start_left) |e| gop.value_ptr.start_left = e;
        if (t.start_right) |e| gop.value_ptr.start_right = e;
        if (t.end_left) |e| gop.value_ptr.end_left = e;
        if (t.end_right) |e| gop.value_ptr.end_right = e;
    }
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

pub fn positionEdgeLabel(ctx: *const Ctx, edge: *const EdgeData, paths: Paths) Error!void {
    const a = ctx.a;
    const path: ?[]const Point = if (paths.updated_path) |p| p else if (paths.original_path.len > 0) paths.original_path else null;
    const margin = ctx.cfg.sub_graph_title_margin.top + ctx.cfg.sub_graph_title_margin.bottom;
    if (nonEmpty(edge.label) != null) {
        if (edge_labels.get(edge.id)) |el| {
            var x = edge.x;
            var y = edge.y;
            if (path) |p| {
                const pos = try geom.calcLabelPosition(p);
                if (paths.updated_path != null) {
                    if (paths.original_path.len > 0) {
                        const orig = try geom.calcLabelPosition(paths.original_path);
                        x = edge.x + (pos.x - orig.x);
                        y = edge.y + (pos.y - orig.y);
                    } else {
                        x = pos.x;
                        y = pos.y;
                    }
                }
            }
            try el.setAttr("transform", try translate(a, x, y + margin / 2));
        }
    }
    const term = terminal_labels.get(edge.id) orelse return;
    const kinds = [_]struct { ?[]const u8, ?*El, []const u8, geom.TerminalPos }{
        .{ edge.start_label_left, term.start_left, edge.arrow_type_start, .start_left },
        .{ edge.start_label_right, term.start_right, edge.arrow_type_start, .start_right },
        .{ edge.end_label_left, term.end_left, edge.arrow_type_end, .end_left },
        .{ edge.end_label_right, term.end_right, edge.arrow_type_end, .end_right },
    };
    for (kinds) |k| {
        if (nonEmpty(k[0]) == null) continue;
        const el = k[1] orelse continue;
        var x = edge.x;
        var y = edge.y;
        if (path) |p| {
            const pos = try geom.calcTerminalLabelPosition(a, if (k[2].len > 0) 10 else 0, k[3], p);
            x = pos.x;
            y = pos.y;
        }
        try el.setAttr("transform", try translate(a, x, y));
    }
}

fn outsideNode(node: *const NodeData, point: Point) bool {
    const dx = @abs(point.x - node.x);
    const dy = @abs(point.y - node.y);
    return dx >= node.width / 2 or dy >= node.height / 2;
}

pub fn intersection(node: *const NodeData, outside: Point, inside: Point) Point {
    const x = node.x;
    const y = node.y;
    const dx = @abs(x - inside.x);
    const w = node.width / 2;
    var r: f64 = if (inside.x < outside.x) w - dx else w + dx;
    const h = node.height / 2;
    const q_ = @abs(outside.y - inside.y);
    const r_ = @abs(outside.x - inside.x);
    if (@abs(y - outside.y) * w > @abs(x - outside.x) * h) {
        const q: f64 = if (inside.y < outside.y) outside.y - h - y else y - h - outside.y;
        r = (r_ * q) / q_;
        var res: Point = .{
            .x = if (inside.x < outside.x) inside.x + r else inside.x - r_ + r,
            .y = if (inside.y < outside.y) inside.y + q_ - q else inside.y - q_ + q,
        };
        if (r == 0) res = outside;
        if (r_ == 0) res.x = outside.x;
        if (q_ == 0) res.y = outside.y;
        return res;
    }
    r = if (inside.x < outside.x) outside.x - w - x else x - w - outside.x;
    const q = (q_ * r) / r_;
    var px: f64 = if (inside.x < outside.x) inside.x + r_ - r else inside.x - r_ + r;
    var py: f64 = if (inside.y < outside.y) inside.y + q else inside.y - q;
    if (r == 0) {
        px = outside.x;
        py = outside.y;
    }
    if (r_ == 0) px = outside.x;
    if (q_ == 0) py = outside.y;
    return .{ .x = px, .y = py };
}

fn cutPathAtIntersect(a: Allocator, pts: []const Point, boundary: *const NodeData) Allocator.Error![]Point {
    var out: std.ArrayList(Point) = .empty;
    if (pts.len == 0) return out.items;
    var last_outside = pts[0];
    var inside = false;
    for (pts) |point| {
        if (!outsideNode(boundary, point) and !inside) {
            const inter = intersection(boundary, last_outside, point);
            var present = false;
            for (out.items) |e| if (e.x == inter.x and e.y == inter.y) {
                present = true;
            };
            if (!present) try out.append(a, inter);
            inside = true;
        } else {
            last_outside = point;
            if (!inside) try out.append(a, point);
        }
    }
    return out.items;
}

fn findAdjacentPoint(pa: Point, pb: Point, dist: f64) Point {
    const xd = pb.x - pa.x;
    const yd = pb.y - pa.y;
    const len = @sqrt(xd * xd + yd * yd);
    const ratio = dist / len;
    return .{ .x = pb.x - ratio * xd, .y = pb.y - ratio * yd };
}

fn isCorner(pts: []const Point, i: usize) bool {
    const prev = pts[i - 1];
    const curr = pts[i];
    const next = pts[i + 1];
    if (prev.x == curr.x and curr.y == next.y and @abs(curr.x - next.x) > 5 and @abs(curr.y - prev.y) > 5) return true;
    return prev.y == curr.y and curr.x == next.x and @abs(curr.x - prev.x) > 5 and @abs(curr.y - next.y) > 5;
}

fn fixCorners(a: Allocator, line_data: []const Point) Allocator.Error![]Point {
    var out: std.ArrayList(Point) = .empty;
    for (line_data, 0..) |p, i| {
        if (i > 0 and i + 1 < line_data.len and isCorner(line_data, i)) {
            const prev = line_data[i - 1];
            const next = line_data[i + 1];
            const np = findAdjacentPoint(prev, p, 5);
            const nn = findAdjacentPoint(next, p, 5);
            const xd = nn.x - np.x;
            const yd = nn.y - np.y;
            try out.append(a, np);
            const k = @sqrt(2.0) * 2;
            var nc: Point = .{ .x = p.x, .y = p.y };
            if (@abs(next.x - prev.x) > 10 and @abs(next.y - prev.y) >= 10) {
                const r = 5.0;
                if (p.x == np.x) {
                    nc = .{ .x = if (xd < 0) np.x - r + k else np.x + r - k, .y = if (yd < 0) np.y - k else np.y + k };
                } else {
                    nc = .{ .x = if (xd < 0) np.x - k else np.x + k, .y = if (yd < 0) np.y - r + k else np.y + r - k };
                }
            }
            try out.append(a, nc);
            try out.append(a, nn);
        } else try out.append(a, p);
    }
    return out.items;
}

fn applyMarkerOffsetsToPoints(a: Allocator, pts: []const Point, edge: *const EdgeData) Allocator.Error![]Point {
    const out = try a.dupe(Point, pts);
    const n = pts.len;
    if (n >= 2) if (geom.markerOffset(edge.arrow_type_start)) |ov| if (ov != 0) {
        const angle = std.math.atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x);
        out[0].x = pts[0].x + ov * @cos(angle);
        out[0].y = pts[0].y + ov * @sin(angle);
    };
    if (n >= 2) if (geom.markerOffset(edge.arrow_type_end)) |ov| if (ov != 0) {
        const angle = std.math.atan2(pts[n - 1].y - pts[n - 2].y, pts[n - 1].x - pts[n - 2].x);
        out[n - 1].x = pts[n - 1].x - ov * @cos(angle);
        out[n - 1].y = pts[n - 1].y - ov * @sin(angle);
    };
    return out;
}

pub fn generateRoundedPath(a: Allocator, pts: []const Point, radius: f64) Allocator.Error![]const u8 {
    if (pts.len < 2) return "";
    var out: std.ArrayList(u8) = .empty;
    const eps = 1e-5;
    const size = pts.len;
    for (pts, 0..) |c, i| {
        if (i == 0) {
            try out.print(a, "M{s},{s}", .{ try jsNum(a, c.x), try jsNum(a, c.y) });
        } else if (i == size - 1) {
            try out.print(a, "L{s},{s}", .{ try jsNum(a, c.x), try jsNum(a, c.y) });
        } else {
            const pr = pts[i - 1];
            const nx_ = pts[i + 1];
            const dx1 = c.x - pr.x;
            const dy1 = c.y - pr.y;
            const dx2 = nx_.x - c.x;
            const dy2 = nx_.y - c.y;
            const len1 = std.math.hypot(dx1, dy1);
            const len2 = std.math.hypot(dx2, dy2);
            if (len1 < eps or len2 < eps) {
                try out.print(a, "L{s},{s}", .{ try jsNum(a, c.x), try jsNum(a, c.y) });
                continue;
            }
            const nx1 = dx1 / len1;
            const ny1 = dy1 / len1;
            const nx2 = dx2 / len2;
            const ny2 = dy2 / len2;
            const dot = std.math.clamp(nx1 * nx2 + ny1 * ny2, -1, 1);
            const angle = std.math.acos(dot);
            if (angle < eps or @abs(std.math.pi - angle) < eps) {
                try out.print(a, "L{s},{s}", .{ try jsNum(a, c.x), try jsNum(a, c.y) });
                continue;
            }
            const cut = @min(radius / @sin(angle / 2), @min(len1 / 2, len2 / 2));
            const sx = c.x - nx1 * cut;
            const sy = c.y - ny1 * cut;
            const ex = c.x + nx2 * cut;
            const ey = c.y + ny2 * cut;
            try out.print(a, "L{s},{s}", .{ try jsNum(a, sx), try jsNum(a, sy) });
            try out.print(a, "Q{s},{s} {s},{s}", .{ try jsNum(a, c.x), try jsNum(a, c.y), try jsNum(a, ex), try jsNum(a, ey) });
        }
    }
    return out.items;
}

fn pointsJsonB64(a: Allocator, pts: []const Point) Allocator.Error![]const u8 {
    var j: std.ArrayList(u8) = .empty;
    try j.append(a, '[');
    for (pts, 0..) |p, i| {
        if (i > 0) try j.append(a, ',');
        const xs = if (std.math.isNan(p.x) or std.math.isInf(p.x)) "null" else try jsNum(a, p.x);
        const ys = if (std.math.isNan(p.y) or std.math.isInf(p.y)) "null" else try jsNum(a, p.y);
        try j.print(a, "{{\"x\":{s},\"y\":{s}}}", .{ xs, ys });
    }
    try j.append(a, ']');
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(j.items.len));
    return enc.encode(buf, j.items);
}

const ArrowInfo = struct { kind: []const u8, fill: bool };

fn arrowInfo(name: []const u8) ?ArrowInfo {
    const tbl = [_]struct { []const u8, ArrowInfo }{
        .{ "arrow_cross", .{ .kind = "cross", .fill = false } },
        .{ "arrow_point", .{ .kind = "point", .fill = true } },
        .{ "arrow_barb", .{ .kind = "barb", .fill = true } },
        .{ "arrow_barb_neo", .{ .kind = "barb", .fill = true } },
        .{ "arrow_circle", .{ .kind = "circle", .fill = false } },
        .{ "arrow_hierarchy", .{ .kind = "hierarchy", .fill = false } },
        .{ "aggregation", .{ .kind = "aggregation", .fill = false } },
        .{ "extension", .{ .kind = "extension", .fill = false } },
        .{ "composition", .{ .kind = "composition", .fill = true } },
        .{ "dependency", .{ .kind = "dependency", .fill = true } },
        .{ "lollipop", .{ .kind = "lollipop", .fill = false } },
        .{ "only_one", .{ .kind = "onlyOne", .fill = false } },
        .{ "zero_or_one", .{ .kind = "zeroOrOne", .fill = false } },
        .{ "one_or_more", .{ .kind = "oneOrMore", .fill = false } },
        .{ "zero_or_more", .{ .kind = "zeroOrMore", .fill = false } },
        .{ "requirement_arrow", .{ .kind = "requirement_arrow", .fill = false } },
        .{ "requirement_contains", .{ .kind = "requirement_contains", .fill = false } },
    };
    for (tbl) |t| if (std.mem.eql(u8, t[0], name)) return t[1];
    return null;
}

fn findById(e: *El, id: []const u8) ?*El {
    if (e.getAttr("id")) |v| if (std.mem.eql(u8, v, id)) return e;
    for (e.kids.items) |k| if (findById(k, id)) |f| return f;
    return null;
}

fn cloneColored(a: Allocator, src: *const El, id: []const u8, color: []const u8, fill: bool, top: bool) Allocator.Error!*El {
    const e = try El.create(a, src.tag);
    for (src.attrs.items) |at| try e.setAttr(at.name, at.value);
    e.text = src.text;
    e.box = src.box;
    if (top) try e.setAttr("id", id);
    const t = src.tag;
    if (std.mem.eql(u8, t, "path") or std.mem.eql(u8, t, "circle") or std.mem.eql(u8, t, "line")) {
        try e.setAttr("stroke", color);
        if (fill) try e.setAttr("fill", color);
    }
    for (src.kids.items) |k| try e.append(try cloneColored(a, k, id, color, fill, false));
    return e;
}

fn addEdgeMarker(a: Allocator, svg_path: *El, position: []const u8, arrow_type: []const u8, id: []const u8, diagram_type: []const u8, stroke_color: ?[]const u8, use_margin: bool) Allocator.Error!void {
    const info = arrowInfo(arrow_type) orelse return;
    const suffix = if (std.mem.eql(u8, position, "start")) "Start" else "End";
    const margin = use_margin and marginSupport(info.kind);
    const original = try std.fmt.allocPrint(a, "{s}_{s}-{s}{s}{s}", .{ id, diagram_type, info.kind, suffix, if (margin) "-margin" else "" });
    const attr_name = try std.fmt.allocPrint(a, "marker-{s}", .{position});
    if (stroke_color) |sc| if (std.mem.trim(u8, sc, " \t\r\n").len > 0) {
        const cid = try a.dupe(u8, sc);
        for (cid) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
            c.* = '_';
        };
        const colored = try std.fmt.allocPrint(a, "{s}_{s}", .{ original, cid });
        var root: *El = svg_path;
        while (root.parent) |p| root = p;
        if (findById(root, colored) == null) {
            if (findById(root, original)) |om| {
                const clone = try cloneColored(a, om, colored, sc, info.fill, true);
                if (om.parent) |p| try p.append(clone);
            }
        }
        try svg_path.setAttr(attr_name, try std.fmt.allocPrint(a, "url(#{s})", .{colored}));
        return;
    };
    try svg_path.setAttr(attr_name, try std.fmt.allocPrint(a, "url(#{s})", .{original}));
}

fn dashArray(a: Allocator, len: f64, o_s: f64, o_e: f64) Allocator.Error![]const u8 {
    const middle = len - o_s - o_e;
    const pairs: usize = @intFromFloat(@max(0, @floor(middle / 4)));
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "0 {s} ", .{try jsNum(a, o_s)});
    for (0..pairs) |k| {
        if (k > 0) try out.append(a, ' ');
        try out.appendSlice(a, "2 2");
    }
    try out.print(a, " {s}", .{try jsNum(a, o_e)});
    return out.items;
}

fn marginSupport(kind: []const u8) bool {
    const kinds = [_][]const u8{ "cross", "point", "circle", "lollipop", "aggregation", "extension", "composition", "dependency", "barb" };
    for (kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

fn markerOffset2(arrow: []const u8) f64 {
    if (std.mem.eql(u8, arrow, "arrow_point")) return 4;
    if (std.mem.eql(u8, arrow, "arrow_cross") or std.mem.eql(u8, arrow, "arrow_circle")) return 12.5;
    return 0;
}

pub const pathLength = pathlen.length;

fn strokeColorOf(s: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, "stroke:") orelse return null;
    const rest = s[i + 7 ..];
    const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

pub fn insertEdge(ctx: *const Ctx, elem: *El, edge: *EdgeData, cluster_db: ClusterDb, diagram_type: []const u8, start_node: *const NodeData, end_node: *const NodeData, diagram_id: []const u8) !Paths {
    const a = ctx.a;
    var points: []Point = try a.dupe(Point, edge.points);
    var changed = false;
    if (start_node.intersect != null and end_node.intersect != null and edge.points.len > 2) {
        const inner = edge.points[1 .. edge.points.len - 1];
        const np = try a.alloc(Point, inner.len + 2);
        @memcpy(np[1 .. inner.len + 1], inner);
        np[0] = intersect.intersectNode(start_node, inner[0]);
        np[np.len - 1] = intersect.intersectNode(end_node, np[np.len - 2]);
        points = np;
    }
    const points_str = try pointsJsonB64(a, points);
    if (edge.to_cluster) |tc| {
        if (cluster_db.get(tc)) |c| {
            points = try cutPathAtIntersect(a, edge.points, c.node);
            changed = true;
        }
    }
    if (edge.from_cluster) |fc| {
        if (cluster_db.get(fc)) |c| {
            std.mem.reverse(Point, points);
            points = try cutPathAtIntersect(a, points, c.node);
            std.mem.reverse(Point, points);
            changed = true;
        }
    }

    var ld: std.ArrayList(Point) = .empty;
    for (points) |p| if (!std.math.isNan(p.y)) try ld.append(a, p);
    var line_data: []Point = ld.items;
    const curve_type = edge.curve orelse ctx.cfg.curve;
    const rounded = std.mem.eql(u8, curve_type, "rounded");
    if (!rounded) line_data = try fixCorners(a, line_data);

    var stroke_classes: []const u8 = "edge-thickness-normal";
    if (std.mem.eql(u8, edge.thickness, "thick")) stroke_classes = "edge-thickness-thick" else if (std.mem.eql(u8, edge.thickness, "invisible")) stroke_classes = "edge-thickness-invisible";
    const pat: []const u8 = if (std.mem.eql(u8, edge.pattern, "dotted")) " edge-pattern-dotted" else if (std.mem.eql(u8, edge.pattern, "dashed")) " edge-pattern-dashed" else " edge-pattern-solid";
    stroke_classes = try std.fmt.allocPrint(a, "{s}{s}", .{ stroke_classes, pat });

    const line_path = if (rounded)
        try generateRoundedPath(a, try applyMarkerOffsetsToPoints(a, line_data, edge), 5)
    else
        try curves.line(a, try geom.offsetPoints(a, line_data, edge.arrow_type_start, edge.arrow_type_end), curves.fromName(curve_type));

    var animation_class: []const u8 = "";
    if (edge.animate) animation_class = "edge-animation-fast";
    if (edge.animation) |an| animation_class = try std.fmt.allocPrint(a, "edge-animation-{s}", .{an});

    var from_classes: std.ArrayList(u8) = .empty;
    for (edge.css_compiled_styles, 0..) |s, i| {
        if (i > 0) try from_classes.append(a, ';');
        try from_classes.appendSlice(a, s);
    }
    var styles: std.ArrayList(u8) = .empty;
    var tail: std.ArrayList(u8) = .empty;
    for (edge.style) |s| {
        try styles.print(a, "{s};", .{s});
        try tail.print(a, ";{s}", .{s});
    }
    const path_style = if (from_classes.items.len > 0)
        try std.fmt.allocPrint(a, "{s};{s};;{s}", .{ from_classes.items, styles.items, tail.items })
    else
        try std.fmt.allocPrint(a, "{s};{s}", .{ styles.items, tail.items });

    const svg_path = try elem.insert("path");
    try svg_path.setAttr("d", line_path);
    try svg_path.setAttr("id", try std.fmt.allocPrint(a, "{s}-{s}", .{ diagram_id, edge.id }));
    try svg_path.setAttr("class", try std.fmt.allocPrint(a, " {s}{s}{s}{s}{s}", .{
        stroke_classes,
        if (edge.classes.len > 0) " " else "",
        edge.classes,
        if (animation_class.len > 0) " " else "",
        animation_class,
    }));
    try svg_path.setAttr("style", path_style);
    try svg_path.setAttr("data-edge", "true");
    try svg_path.setAttr("data-et", "edge");
    try svg_path.setAttr("data-id", edge.id);
    try svg_path.setAttr("data-points", points_str);
    try svg_path.setAttr("data-look", edge.look);

    const stroke_color = strokeColorOf(path_style);
    const neo = std.mem.eql(u8, edge.look, "neo");
    const animated = edge.animate or edge.animation != null or std.mem.indexOf(u8, from_classes.items, "animation") != null;
    if (neo and !animated) {
        const len = pathLength(line_path);
        const o_s = markerOffset2(edge.arrow_type_start);
        const o_e = markerOffset2(edge.arrow_type_end);
        const dash = if (std.mem.eql(u8, edge.pattern, "dotted") or std.mem.eql(u8, edge.pattern, "dashed")) try dashArray(a, len, o_s, o_e) else try std.fmt.allocPrint(a, "0 {s} {s} {s}", .{ try jsNum(a, o_s), try jsNum(a, len - o_s - o_e), try jsNum(a, o_e) });
        try svg_path.setAttr("style", try std.fmt.allocPrint(a, "stroke-dasharray: {s}; stroke-dashoffset: 0;{s}", .{ dash, path_style }));
    }
    const use_margin = !animated and neo;
    if (edge.arrow_type_start.len > 0) try addEdgeMarker(a, svg_path, "start", edge.arrow_type_start, diagram_id, diagram_type, stroke_color, use_margin);
    if (edge.arrow_type_end.len > 0) try addEdgeMarker(a, svg_path, "end", edge.arrow_type_end, diagram_id, diagram_type, stroke_color, use_margin);

    if (points.len > 0) {
        const mid = points[points.len / 2];
        if (!try geom.isLabelCoordinateInPath(a, mid, line_path)) changed = true;
    }
    return .{ .updated_path = if (changed) points else null, .original_path = edge.points, .path_el = svg_path };
}

const fake = struct {
    fn w(_: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
        return 8 * @as(f64, @floatFromInt(text.len));
    }
    fn none(_: *anyopaque, _: []const u8) ?ClusterEntry {
        return null;
    }
};

test "straight edge between two rect nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var dummy: u8 = 0;
    const ctx: Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = fake.w }, .cfg = &cfg, .diagram_id = "d" };
    const root = try El.create(ctx.a, "g");
    const paths_g = try root.insert("g");
    var pts = [_]Point{ .{ .x = 50, .y = 20 }, .{ .x = 50, .y = 60 }, .{ .x = 50, .y = 100 } };
    var edge: EdgeData = .{ .id = "L_A_B_0", .start = "A", .end = "B", .points = &pts, .arrow_type_end = "arrow_point", .arrow_type_start = "none", .look = "classic" };
    const a_node: NodeData = .{ .id = "A", .x = 50, .y = 20, .width = 100, .height = 40, .intersect = .rect };
    const b_node: NodeData = .{ .id = "B", .x = 50, .y = 100, .width = 100, .height = 40, .intersect = .rect };
    const db: ClusterDb = .{ .ctx = &dummy, .getFn = fake.none };
    const res = try insertEdge(&ctx, paths_g, &edge, db, "flowchart-v2", &a_node, &b_node, "d");
    const p = res.path_el.?;
    try std.testing.expectEqualStrings("d-L_A_B_0", p.getAttr("id").?);
    try std.testing.expectEqualStrings(" edge-thickness-normal edge-pattern-solid", p.getAttr("class").?);
    try std.testing.expectEqualStrings("url(#d_flowchart-v2-pointEnd)", p.getAttr("marker-end").?);
    try std.testing.expect(std.mem.startsWith(u8, p.getAttr("d").?, "M50,40L50,"));
    try std.testing.expect(res.updated_path == null);
}

test "cluster cut clips at the boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node: NodeData = .{ .id = "c", .x = 50, .y = 100, .width = 100, .height = 100 };
    const out = try cutPathAtIntersect(arena.allocator(), &.{ .{ .x = 20, .y = 0 }, .{ .x = 60, .y = 100 } }, &node);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(f64, 50), out[1].y);
    try std.testing.expectEqual(@as(f64, 40), out[1].x);
}

test "label sizes come from the label box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var dummy: u8 = 0;
    const ctx: Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = fake.w }, .cfg = &cfg, .diagram_id = "d" };
    clear();
    const root = try El.create(ctx.a, "g");
    var edge: EdgeData = .{ .id = "e1", .start = "A", .end = "B", .label = "yes" };
    try insertEdgeLabel(&ctx, root, &edge);
    try std.testing.expectEqual(@as(f64, 24), edge.width);
    try std.testing.expectEqual(@as(f64, 24), edge.height);
    edge.x = 10;
    edge.y = 20;
    try positionEdgeLabel(&ctx, &edge, .{});
    try std.testing.expectEqualStrings("translate(10, 20)", root.kids.items[0].getAttr("transform").?);
}

test "colored marker clone for stroke style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try El.create(a, "g");
    const m = @import("markers.zig");
    try m.insertMarkers(a, root, &.{"point"}, "flowchart-v2", "d");
    const p = try root.insert("path");
    try addEdgeMarker(a, p, "end", "arrow_point", "d", "flowchart-v2", "#f00", false);
    try std.testing.expectEqualStrings("url(#d_flowchart-v2-pointEnd__f00)", p.getAttr("marker-end").?);
    try std.testing.expect(findById(root, "d_flowchart-v2-pointEnd__f00") != null);
}
