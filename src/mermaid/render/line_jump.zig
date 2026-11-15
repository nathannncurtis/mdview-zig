const std = @import("std");
const dom = @import("dom.zig");
const edges_mod = @import("edges.zig");
const geom = @import("geom.zig");
const model = @import("model.zig");
const pathlen = @import("pathlen.zig");

const Allocator = std.mem.Allocator;
const Point = model.Point;
const El = dom.El;

const rounded_corner_radius = 5.0;
const corner_epsilon = 1e-5;
const corner_jump_clearance = 2.0;
const min_useful_radius_ratio = 0.6;
const endpoint_epsilon = 1e-6;
pub const jump_radius = 6.0;

pub const JumpStyle = enum { arc, gap };

pub const EdgeGeom = struct {
    id: []const u8,
    points: []const Point,
    curve: ?[]const u8 = null,
    arrow_type_start: []const u8 = "",
    arrow_type_end: []const u8 = "",
};

pub const LineJumpConfig = struct {
    enabled: bool,
    jump_radius: f64,
    jump_style: JumpStyle,
};

pub const Crossing = struct {
    jump_edge_id: []const u8,
    other_edge_id: []const u8,
    seg_index: usize,
    t: f64,
    point: Point,
};

const SegmentIntersection = struct { point: Point, t_a: f64, t_b: f64 };

fn segmentIntersection(a1: Point, a2: Point, b1: Point, b2: Point) ?SegmentIntersection {
    const dx_a = a2.x - a1.x;
    const dy_a = a2.y - a1.y;
    const dx_b = b2.x - b1.x;
    const dy_b = b2.y - b1.y;
    const denom = dx_a * dy_b - dy_a * dx_b;
    if (denom == 0) return null;
    const dx = b1.x - a1.x;
    const dy = b1.y - a1.y;
    const t_a = (dx * dy_b - dy * dx_b) / denom;
    const t_b = (dx * dy_a - dy * dx_a) / denom;
    if (t_a <= endpoint_epsilon or t_a >= 1 - endpoint_epsilon or t_b <= endpoint_epsilon or t_b >= 1 - endpoint_epsilon) return null;
    return .{ .point = .{ .x = a1.x + t_a * dx_a, .y = a1.y + t_a * dy_a }, .t_a = t_a, .t_b = t_b };
}

fn isHorizontalSeg(a: Point, b: Point) bool {
    return @abs(b.x - a.x) >= @abs(b.y - a.y);
}

const RoundedCorner = struct {
    start_x: f64,
    start_y: f64,
    end_x: f64,
    end_y: f64,
    ctrl_x: f64,
    ctrl_y: f64,
    cut_len: f64,
};

fn computeRoundedCorner(prev: Point, curr: Point, next: Point, radius: f64) ?RoundedCorner {
    const dx1 = curr.x - prev.x;
    const dy1 = curr.y - prev.y;
    const dx2 = next.x - curr.x;
    const dy2 = next.y - curr.y;
    const len1 = std.math.hypot(dx1, dy1);
    const len2 = std.math.hypot(dx2, dy2);
    if (len1 < corner_epsilon or len2 < corner_epsilon) return null;
    const nx1 = dx1 / len1;
    const ny1 = dy1 / len1;
    const nx2 = dx2 / len2;
    const ny2 = dy2 / len2;
    const dot = std.math.clamp(nx1 * nx2 + ny1 * ny2, -1, 1);
    const angle = std.math.acos(dot);
    if (angle < corner_epsilon or @abs(std.math.pi - angle) < corner_epsilon) return null;
    const cut_len = @min(radius / @sin(angle / 2), @min(len1 / 2, len2 / 2));
    return .{
        .start_x = curr.x - nx1 * cut_len,
        .start_y = curr.y - ny1 * cut_len,
        .end_x = curr.x + nx2 * cut_len,
        .end_y = curr.y + ny2 * cut_len,
        .ctrl_x = curr.x,
        .ctrl_y = curr.y,
        .cut_len = cut_len,
    };
}

fn isRounded(edge: EdgeGeom) bool {
    const c = edge.curve orelse return false;
    return std.mem.eql(u8, c, "rounded");
}

fn crossingSitsInRoundedCorner(edge: EdgeGeom, seg_index: usize, t: f64) bool {
    if (!isRounded(edge)) return false;
    const pts = edge.points;
    if (seg_index + 1 >= pts.len) return false;
    const a = pts[seg_index];
    const b = pts[seg_index + 1];
    const seg_len = std.math.hypot(b.x - a.x, b.y - a.y);
    const d = t * seg_len;
    if (seg_index > 0) {
        if (computeRoundedCorner(pts[seg_index - 1], a, b, rounded_corner_radius)) |c| {
            if (d < c.cut_len) return true;
        }
    }
    if (seg_index + 2 < pts.len) {
        if (computeRoundedCorner(a, b, pts[seg_index + 2], rounded_corner_radius)) |c| {
            return seg_len - d < c.cut_len;
        }
    }
    return false;
}

pub fn findEdgeIntersections(a: Allocator, edges: []const EdgeGeom) Allocator.Error![]Crossing {
    var out: std.ArrayList(Crossing) = .empty;
    for (edges, 0..) |edge_a, i| {
        for (edges[i + 1 ..]) |edge_b| {
            if (edge_a.points.len < 2 or edge_b.points.len < 2) continue;
            for (0..edge_a.points.len - 1) |si| {
                const a1 = edge_a.points[si];
                const a2 = edge_a.points[si + 1];
                for (0..edge_b.points.len - 1) |sj| {
                    const b1 = edge_b.points[sj];
                    const b2 = edge_b.points[sj + 1];
                    const hit = segmentIntersection(a1, a2, b1, b2) orelse continue;
                    if (crossingSitsInRoundedCorner(edge_a, si, hit.t_a) or crossingSitsInRoundedCorner(edge_b, sj, hit.t_b)) continue;
                    const a_horiz = isHorizontalSeg(a1, a2);
                    const b_horiz = isHorizontalSeg(b1, b2);
                    const jump_on_a = if (a_horiz != b_horiz) a_horiz else false;
                    if (jump_on_a) {
                        try out.append(a, .{ .jump_edge_id = edge_a.id, .other_edge_id = edge_b.id, .seg_index = si, .t = hit.t_a, .point = hit.point });
                    } else {
                        try out.append(a, .{ .jump_edge_id = edge_b.id, .other_edge_id = edge_a.id, .seg_index = sj, .t = hit.t_b, .point = hit.point });
                    }
                }
            }
        }
    }
    return out.items;
}

fn fmt(a: Allocator, n: f64) Allocator.Error![]const u8 {
    return edges_mod.jsNum(a, @floor(n * 1000 + 0.5) / 1000);
}

fn pointStr(a: Allocator, p: Point) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s},{s}", .{ try fmt(a, p.x), try fmt(a, p.y) });
}

fn arcSweepFlag(a: Point, b: Point) u8 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (@abs(dx) >= @abs(dy)) return if (dx >= 0) 1 else 0;
    return if (dy >= 0) 1 else 0;
}

fn applyMarkerOffsets(a: Allocator, points: []const Point, edge: EdgeGeom) Allocator.Error![]Point {
    const out = try a.dupe(Point, points);
    const n = points.len;
    if (n < 2) return out;
    const start_off = geom.markerOffset(edge.arrow_type_start) orelse 0;
    if (start_off != 0) {
        const ang = std.math.atan2(points[1].y - points[0].y, points[1].x - points[0].x);
        out[0].x = points[0].x + start_off * @cos(ang);
        out[0].y = points[0].y + start_off * @sin(ang);
    }
    const end_off = geom.markerOffset(edge.arrow_type_end) orelse 0;
    if (end_off != 0) {
        const ang = std.math.atan2(points[n - 1].y - points[n - 2].y, points[n - 1].x - points[n - 2].x);
        out[n - 1].x = points[n - 1].x - end_off * @cos(ang);
        out[n - 1].y = points[n - 1].y - end_off * @sin(ang);
    }
    return out;
}

const JumpOnSegment = struct { t: f64, point: Point, d: f64, r: f64 };

fn jumpLess(_: void, x: JumpOnSegment, y: JumpOnSegment) bool {
    return x.t < y.t;
}

fn emitJump(a: Allocator, parts: *std.ArrayList(u8), j: JumpOnSegment, ux: f64, uy: f64, sweep: u8, style: JumpStyle) Allocator.Error!void {
    const pre: Point = .{ .x = j.point.x - ux * j.r, .y = j.point.y - uy * j.r };
    const post: Point = .{ .x = j.point.x + ux * j.r, .y = j.point.y + uy * j.r };
    try parts.print(a, " L{s}", .{try pointStr(a, pre)});
    switch (style) {
        .arc => try parts.print(a, " A{s},{s} 0 0 {d} {s}", .{ try fmt(a, j.r), try fmt(a, j.r), sweep, try pointStr(a, post) }),
        .gap => try parts.print(a, " M{s}", .{try pointStr(a, post)}),
    }
}

fn rewriteEdgePath(a: Allocator, edge: EdgeGeom, jumps: []const Crossing, config: LineJumpConfig) Allocator.Error![]const u8 {
    if (edge.points.len < 2) return "";
    const points = try applyMarkerOffsets(a, edge.points, edge);
    const rounded = isRounded(edge);
    var parts: std.ArrayList(u8) = .empty;
    try parts.print(a, "M{s}", .{try pointStr(a, points[0])});
    const nseg = points.len - 1;
    for (0..nseg) |i| {
        const sa = points[i];
        const sb = points[i + 1];
        const seg_len = std.math.hypot(sb.x - sa.x, sb.y - sa.y);
        const ux = if (seg_len == 0) 0 else (sb.x - sa.x) / seg_len;
        const uy = if (seg_len == 0) 0 else (sb.y - sa.y) / seg_len;
        const sweep = arcSweepFlag(sa, sb);

        var seg_start_consumed: f64 = 0;
        if (rounded and i > 0) {
            if (computeRoundedCorner(points[i - 1], points[i], points[i + 1], rounded_corner_radius)) |c| seg_start_consumed = c.cut_len;
        }

        var seg_end_stop = seg_len;
        var upcoming: ?RoundedCorner = null;
        if (rounded and i < nseg - 1) {
            const after = if (i + 2 < points.len) points[i + 2] else points[i + 1];
            upcoming = computeRoundedCorner(points[i], points[i + 1], after, rounded_corner_radius);
            if (upcoming) |c| seg_end_stop = seg_len - c.cut_len;
        }

        const min_useful = config.jump_radius * min_useful_radius_ratio;
        var list: std.ArrayList(JumpOnSegment) = .empty;
        for (jumps) |j| {
            if (j.seg_index != i) continue;
            try list.append(a, .{ .t = j.t, .point = j.point, .d = j.t * seg_len, .r = config.jump_radius });
        }
        std.sort.insertion(JumpOnSegment, list.items, {}, jumpLess);
        var kept: std.ArrayList(JumpOnSegment) = .empty;
        for (list.items) |*j| {
            const room = @min(j.d - seg_start_consumed, seg_end_stop - j.d) - corner_jump_clearance;
            j.r = @min(j.r, room);
            if (j.r >= min_useful) try kept.append(a, j.*);
        }
        const sj = kept.items;
        if (sj.len > 1) for (0..sj.len - 1) |k| {
            const gap = sj[k + 1].d - sj[k].d;
            if (sj[k].r + sj[k + 1].r > gap) {
                const half = gap / 2;
                sj[k].r = @min(sj[k].r, half);
                sj[k + 1].r = @min(sj[k + 1].r, half);
            }
        };
        for (sj) |j| {
            if (j.r < min_useful) continue;
            try emitJump(a, &parts, j, ux, uy, sweep, config.jump_style);
        }

        if (upcoming) |c| {
            try parts.print(a, " L{s},{s}", .{ try fmt(a, c.start_x), try fmt(a, c.start_y) });
            try parts.print(a, " Q{s},{s} {s},{s}", .{ try fmt(a, c.ctrl_x), try fmt(a, c.ctrl_y), try fmt(a, c.end_x), try fmt(a, c.end_y) });
        } else {
            try parts.print(a, " L{s}", .{try pointStr(a, sb)});
        }
    }
    return parts.items;
}

fn plainPath(a: Allocator, points: []const Point) Allocator.Error![]const u8 {
    if (points.len == 0) return "";
    var parts: std.ArrayList(u8) = .empty;
    try parts.print(a, "M{s}", .{try pointStr(a, points[0])});
    for (points[1..]) |p| try parts.print(a, " L{s}", .{try pointStr(a, p)});
    return parts.items;
}

const JumpMap = std.StringHashMapUnmanaged(std.ArrayList(Crossing));

fn groupByEdge(a: Allocator, crossings: []const Crossing) Allocator.Error!JumpMap {
    var m: JumpMap = .empty;
    for (crossings) |c| {
        const e = try m.getOrPut(a, c.jump_edge_id);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(a, c);
    }
    return m;
}

pub fn processEdgesWithJumps(a: Allocator, edges: []const EdgeGeom, config: LineJumpConfig) Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var result: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (!config.enabled) {
        for (edges) |e| try result.put(a, e.id, try plainPath(a, e.points));
        return result;
    }
    const jumps = try groupByEdge(a, try findEdgeIntersections(a, edges));
    for (edges) |e| {
        const d = if (jumps.get(e.id)) |l| (if (l.items.len > 0) try rewriteEdgePath(a, e, l.items, config) else try plainPath(a, e.points)) else try plainPath(a, e.points);
        try result.put(a, e.id, d);
    }
    return result;
}

pub fn isStraightPath(d: []const u8) bool {
    for (d) |c| switch (c) {
        '0'...'9', ' ', '\t', '\n', '\r', 0x0b, 0x0c, '+', ',', '.', 'L', 'M', 'e', 'l', 'm', '-' => {},
        else => return false,
    };
    return true;
}

pub fn curveSupportsLineHops(curve: ?[]const u8) bool {
    const c = curve orelse return true;
    if (c.len == 0) return true;
    const ok = [_][]const u8{ "linear", "rounded", "step", "stepBefore", "stepAfter" };
    for (ok) |o| if (std.mem.eql(u8, c, o)) return true;
    return false;
}

fn jsonNum(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn decodeDataPoints(a: Allocator, raw: ?[]const u8) Allocator.Error!?[]Point {
    const b64 = raw orelse return null;
    if (b64.len == 0) return null;
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(b64) catch return null;
    const buf = try a.alloc(u8, size);
    dec.decode(buf, b64) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, buf, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .array) return null;
    var pts: std.ArrayList(Point) = .empty;
    for (parsed.array.items) |p| {
        if (p != .object) continue;
        const x = jsonNum(p.object.get("x") orelse continue) orelse continue;
        const y = jsonNum(p.object.get("y") orelse continue) orelse continue;
        try pts.append(a, .{ .x = x, .y = y });
    }
    return if (pts.items.len >= 2) pts.items else null;
}

fn collectPaths(a: Allocator, el: *El, map: *std.StringHashMapUnmanaged(*El)) Allocator.Error!void {
    for (el.kids.items) |k| {
        if (std.mem.eql(u8, k.tag, "path")) if (k.getAttr("data-id")) |id| {
            const e = try map.getOrPut(a, id);
            if (!e.found_existing) e.value_ptr.* = k;
        };
        try collectPaths(a, k, map);
    }
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and isWs(s[j])) j += 1;
    return j;
}

fn numSpan(s: []const u8, i: usize) ?usize {
    var j = i;
    while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
    return if (j > i) j else null;
}

const key = "stroke-dasharray";

// Matches /stroke-dasharray\s*:\s*0\s+(n)\s+n\s+(n)/ and returns the first and last numbers.
fn preservedDash(style: []const u8) ?struct { f64, f64 } {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, style, from, key)) |at| : (from = at + 1) {
        var i = skipWs(style, at + key.len);
        if (i >= style.len or style[i] != ':') continue;
        i = skipWs(style, i + 1);
        if (i >= style.len or style[i] != '0') continue;
        i += 1;
        var j = skipWs(style, i);
        if (j == i) continue;
        const s0 = j;
        j = numSpan(style, j) orelse continue;
        const s1 = j;
        i = skipWs(style, j);
        if (i == j) continue;
        j = numSpan(style, i) orelse continue;
        i = skipWs(style, j);
        if (i == j) continue;
        const e0 = i;
        const e1 = numSpan(style, i) orelse continue;
        const s = std.fmt.parseFloat(f64, style[s0..s1]) catch return null;
        const e = std.fmt.parseFloat(f64, style[e0..e1]) catch return null;
        return .{ s, e };
    }
    return null;
}

fn replaceDasharray(a: Allocator, style: []const u8, new: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < style.len) {
        if (std.mem.startsWith(u8, style[i..], key)) {
            const c = skipWs(style, i + key.len);
            if (c < style.len and style[c] == ':') {
                var e = c + 1;
                while (e < style.len and style[e] != ';') e += 1;
                if (e < style.len) e += 1;
                try out.print(a, "stroke-dasharray: {s};", .{new});
                i = e;
                continue;
            }
        }
        try out.append(a, style[i]);
        i += 1;
    }
    var collapsed: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < out.items.len) {
        const ch = out.items[i];
        try collapsed.append(a, ch);
        i += 1;
        if (ch != ';') continue;
        const k = skipWs(out.items, i);
        if (k < out.items.len and out.items[k] == ';') {
            i = k;
            while (i < out.items.len and out.items[i] == ';') i += 1;
        }
    }
    return collapsed.items;
}

pub fn applyLineJumpsToSvg(a: Allocator, edge_paths: *El, edges: []const EdgeGeom, config: LineJumpConfig) Allocator.Error!void {
    if (!config.enabled) return;

    var meta: std.StringHashMapUnmanaged(EdgeGeom) = .empty;
    for (edges) |e| try meta.put(a, e.id, e);

    var by_id: std.StringHashMapUnmanaged(*El) = .empty;
    try collectPaths(a, edge_paths, &by_id);

    var rendered: std.ArrayList(EdgeGeom) = .empty;
    for (edges) |e| {
        const path_el = by_id.get(e.id) orelse continue;
        const decoded = try decodeDataPoints(a, path_el.getAttr("data-points"));
        var copy = e;
        copy.points = decoded orelse e.points;
        try rendered.append(a, copy);
    }

    const crossings = try findEdgeIntersections(a, rendered.items);
    if (crossings.len == 0) return;
    const jumps = try groupByEdge(a, crossings);

    for (rendered.items) |re| {
        const list = jumps.get(re.id) orelse continue;
        if (list.items.len == 0) continue;
        const hint = if (meta.get(re.id)) |m| m.curve else null;
        if (hint != null and !curveSupportsLineHops(hint)) continue;
        const path_el = by_id.get(re.id) orelse continue;
        if (hint == null and !isStraightPath(path_el.getAttr("d") orelse "")) continue;

        const original_style = path_el.getAttr("style") orelse "";
        const dash = preservedDash(original_style);

        const new_d = try rewriteEdgePath(a, re, list.items, config);
        try path_el.setAttr("d", new_d);

        if (dash) |sv| {
            const new_len = pathlen.length(new_d);
            const on_len = @max(0, new_len - sv[0] - sv[1]);
            const arr = try std.fmt.allocPrint(a, "0 {s} {s} {s}", .{ try edges_mod.jsNum(a, sv[0]), try edges_mod.jsNum(a, on_len), try edges_mod.jsNum(a, sv[1]) });
            try path_el.setAttr("style", try replaceDasharray(a, original_style, arr));
        }
    }
}

/// Entry point for the ELK paint path: draws a hop where two edges cross.
pub fn applyLineHops(a: Allocator, edge_paths: *El, edges: []const EdgeGeom, style: JumpStyle) Allocator.Error!void {
    var usable: std.ArrayList(EdgeGeom) = .empty;
    for (edges) |e| if (e.points.len >= 2) try usable.append(a, e);
    try applyLineJumpsToSvg(a, edge_paths, usable.items, .{ .enabled = true, .jump_radius = jump_radius, .jump_style = style });
}

const testing = std.testing;

const arc_config: LineJumpConfig = .{ .enabled = true, .jump_radius = 1, .jump_style = .arc };

fn mk(comptime coords: []const [2]f64) [coords.len]Point {
    var out: [coords.len]Point = undefined;
    for (coords, 0..) |c, i| out[i] = .{ .x = c[0], .y = c[1] };
    return out;
}

fn pathOf(m: std.StringHashMapUnmanaged([]const u8), id: []const u8) []const u8 {
    return m.get(id).?;
}

fn parseAfter(s: []const u8, from: usize) !f64 {
    var e = from;
    while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.')) e += 1;
    return std.fmt.parseFloat(f64, s[from..e]);
}

const H = mk(&.{ .{ 0, 5 }, .{ 10, 5 } });
const V = mk(&.{ .{ 5, 0 }, .{ 5, 10 } });

test "single perpendicular crossing assigns the jump to the horizontal edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "e1", .points = &H }, .{ .id = "e2", .points = &V } };
    const cs = try findEdgeIntersections(a, &es);
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqualStrings("e1", cs[0].jump_edge_id);
    try testing.expectEqualStrings("e2", cs[0].other_edge_id);
    try testing.expectApproxEqAbs(5, cs[0].point.x, 1e-9);
    try testing.expectApproxEqAbs(5, cs[0].point.y, 1e-9);
}

test "horizontal still hops when input order is reversed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "vertical", .points = &V }, .{ .id = "horizontal", .points = &H } };
    const cs = try findEdgeIntersections(a, &es);
    try testing.expectEqualStrings("horizontal", cs[0].jump_edge_id);
    try testing.expectEqualStrings("vertical", cs[0].other_edge_id);
}

test "later index wins when both segments share orientation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pa = mk(&.{ .{ 0, 0 }, .{ 10, 2 } });
    const pb = mk(&.{ .{ 0, 2 }, .{ 10, 0 } });
    const es = [_]EdgeGeom{ .{ .id = "a", .points = &pa }, .{ .id = "b", .points = &pb } };
    const cs = try findEdgeIntersections(a, &es);
    try testing.expectEqualStrings("b", cs[0].jump_edge_id);
    try testing.expectEqualStrings("a", cs[0].other_edge_id);
}

test "T-junction, shared endpoints and parallel segments are not crossings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t2 = mk(&.{ .{ 5, 0 }, .{ 5, 5 } });
    const s1 = mk(&.{ .{ 0, 0 }, .{ 10, 5 } });
    const s2 = mk(&.{ .{ 0, 0 }, .{ 10, -5 } });
    const e1 = mk(&.{ .{ 0, 10 }, .{ 10, 5 } });
    const p1 = mk(&.{ .{ 0, 0 }, .{ 10, 0 } });
    const p2 = mk(&.{ .{ 0, 5 }, .{ 10, 5 } });
    const t = [_][2]EdgeGeom{
        .{ .{ .id = "e1", .points = &H }, .{ .id = "e2", .points = &t2 } },
        .{ .{ .id = "e1", .points = &s1 }, .{ .id = "e2", .points = &s2 } },
        .{ .{ .id = "e1", .points = &s1 }, .{ .id = "e2", .points = &e1 } },
        .{ .{ .id = "e1", .points = &p1 }, .{ .id = "e2", .points = &p2 } },
    };
    for (&t) |*pair| try testing.expectEqual(@as(usize, 0), (try findEdgeIntersections(a, pair)).len);
}

test "arc jump goes on the horizontal edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "h", .points = &H }, .{ .id = "v", .points = &V } };
    const m = try processEdgesWithJumps(a, &es, arc_config);
    try testing.expectEqualStrings("M5,0 L5,10", pathOf(m, "v"));
    try testing.expectEqualStrings("M0,5 L4,5 A1,1 0 0 1 6,5 L10,5", pathOf(m, "h"));
}

test "two arcs in t-order across multiple verticals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = mk(&.{ .{ 3, 0 }, .{ 3, 10 } });
    const v2 = mk(&.{ .{ 7, 0 }, .{ 7, 10 } });
    const es = [_]EdgeGeom{ .{ .id = "v1", .points = &v1 }, .{ .id = "v2", .points = &v2 }, .{ .id = "h", .points = &H } };
    const m = try processEdgesWithJumps(a, &es, arc_config);
    try testing.expectEqualStrings("M3,0 L3,10", pathOf(m, "v1"));
    try testing.expectEqualStrings("M7,0 L7,10", pathOf(m, "v2"));
    try testing.expectEqualStrings("M0,5 L2,5 A1,1 0 0 1 4,5 L6,5 A1,1 0 0 1 8,5 L10,5", pathOf(m, "h"));
}

test "radii shrink when adjacent crossings would overlap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = mk(&.{ .{ 4.2, 0 }, .{ 4.2, 10 } });
    const v2 = mk(&.{ .{ 5.8, 0 }, .{ 5.8, 10 } });
    const es = [_]EdgeGeom{ .{ .id = "v1", .points = &v1 }, .{ .id = "v2", .points = &v2 }, .{ .id = "h", .points = &H } };
    const d = pathOf(try processEdgesWithJumps(a, &es, arc_config), "h");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, d, "A"));
    try testing.expect(std.mem.startsWith(u8, d, "M0,5 "));
    try testing.expect(std.mem.endsWith(u8, d, " L10,5"));
    const r = try parseAfter(d, std.mem.indexOfScalar(u8, d, 'A').? + 1);
    try testing.expect(r <= 0.8 and r > 0);
}

test "both hops dropped when crossings are too close to carry one each" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = mk(&.{ .{ 4.7, 0 }, .{ 4.7, 10 } });
    const v2 = mk(&.{ .{ 5.3, 0 }, .{ 5.3, 10 } });
    const es = [_]EdgeGeom{ .{ .id = "v1", .points = &v1 }, .{ .id = "v2", .points = &v2 }, .{ .id = "h", .points = &H } };
    const d = pathOf(try processEdgesWithJumps(a, &es, arc_config), "h");
    try testing.expect(std.mem.indexOfScalar(u8, d, 'A') == null);
    try testing.expectEqualStrings("M0,5 L10,5", d);
}

test "disabled returns plain polylines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "h", .points = &H }, .{ .id = "v", .points = &V } };
    var cfg = arc_config;
    cfg.enabled = false;
    const m = try processEdgesWithJumps(a, &es, cfg);
    try testing.expectEqualStrings("M0,5 L10,5", pathOf(m, "h"));
    try testing.expectEqualStrings("M5,0 L5,10", pathOf(m, "v"));
}

test "gap style emits M on the horizontal edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "h", .points = &H }, .{ .id = "v", .points = &V } };
    var cfg = arc_config;
    cfg.jump_style = .gap;
    const m = try processEdgesWithJumps(a, &es, cfg);
    try testing.expectEqualStrings("M5,0 L5,10", pathOf(m, "v"));
    try testing.expectEqualStrings("M0,5 L4,5 M6,5 L10,5", pathOf(m, "h"));
}

test "isStraightPath" {
    try testing.expect(isStraightPath("M0,5 L10,5"));
    try testing.expect(isStraightPath("M5,0 L5,4 L5,10"));
    try testing.expect(!isStraightPath("M0,0 C1,1 2,2 3,3"));
    try testing.expect(!isStraightPath("M0,0 Q1,1 2,2"));
    try testing.expect(!isStraightPath("M0,0 L1,1 A1,1 0 0 1 2,2"));
}

test "curveSupportsLineHops" {
    try testing.expect(curveSupportsLineHops(null));
    try testing.expect(curveSupportsLineHops("rounded"));
    try testing.expect(curveSupportsLineHops("stepAfter"));
    try testing.expect(!curveSupportsLineHops("basis"));
    try testing.expect(!curveSupportsLineHops("monotoneX"));
}

fn makeGroup(a: Allocator, items: []const [2][]const u8) !*El {
    const g = try El.create(a, "g");
    for (items) |it| {
        const p = try g.insert("path");
        try p.setAttr("data-id", it[0]);
        try p.setAttr("d", it[1]);
    }
    return g;
}

fn pathById(g: *El, id: []const u8) *El {
    for (g.kids.items) |k| if (std.mem.eql(u8, k.getAttr("data-id").?, id)) return k;
    unreachable;
}

test "applyLineJumpsToSvg rewrites the horizontal edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "h", .points = &H }, .{ .id = "v", .points = &V } };
    const g = try makeGroup(a, &.{ .{ "h", "M0,5 L10,5" }, .{ "v", "M5,0 L5,10" } });
    try applyLineJumpsToSvg(a, g, &es, arc_config);
    try testing.expectEqualStrings("M5,0 L5,10", pathById(g, "v").getAttr("d").?);
    try testing.expectEqualStrings("M0,5 L4,5 A1,1 0 0 1 6,5 L10,5", pathById(g, "h").getAttr("d").?);
}

test "applyLineJumpsToSvg rewrites a rounded edge and keeps its corner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vl = mk(&.{ .{ 10, 0 }, .{ 10, 25 } });
    const hb = mk(&.{ .{ 0, 5 }, .{ 20, 5 }, .{ 20, 15 } });
    const es = [_]EdgeGeom{ .{ .id = "verticalLine", .points = &vl, .curve = "rounded" }, .{ .id = "horizontalBend", .points = &hb, .curve = "rounded" } };
    const rendered = "M0,5 L17.5,5 Q20,5 20,7.5 L20,15";
    const g = try makeGroup(a, &.{ .{ "verticalLine", "M10,0 L10,25" }, .{ "horizontalBend", rendered } });
    try applyLineJumpsToSvg(a, g, &es, arc_config);
    const d = pathById(g, "horizontalBend").getAttr("d").?;
    try testing.expect(!std.mem.eql(u8, d, rendered));
    try testing.expect(std.mem.indexOf(u8, d, "A1,1 0 0 1") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Q20,5") != null);
}

test "applyLineJumpsToSvg skips smoothing curves and curved paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const curved = "M5,0 C5,3 5,7 5,10";
    const es1 = [_]EdgeGeom{ .{ .id = "horiz", .points = &H, .curve = "linear" }, .{ .id = "vert", .points = &V, .curve = "basis" } };
    const g1 = try makeGroup(a, &.{ .{ "horiz", "M0,5 L10,5" }, .{ "vert", curved } });
    try applyLineJumpsToSvg(a, g1, &es1, arc_config);
    try testing.expectEqualStrings(curved, pathById(g1, "vert").getAttr("d").?);

    const es2 = [_]EdgeGeom{ .{ .id = "e1", .points = &V }, .{ .id = "e2", .points = &H } };
    const g2 = try makeGroup(a, &.{ .{ "e1", curved }, .{ "e2", "M0,5 L10,5" } });
    try applyLineJumpsToSvg(a, g2, &es2, arc_config);
    try testing.expectEqualStrings(curved, pathById(g2, "e1").getAttr("d").?);
}

test "applyLineJumpsToSvg prefers data-points over edge.points" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hp = mk(&.{ .{ 0, 5 }, .{ 20, 5 } });
    const vp = mk(&.{ .{ 10, 0 }, .{ 10, 20 } });
    const es = [_]EdgeGeom{ .{ .id = "horiz", .points = &hp, .curve = "linear" }, .{ .id = "vert", .points = &vp, .curve = "linear" } };
    const g = try makeGroup(a, &.{ .{ "horiz", "M0,5 L20,5" }, .{ "vert", "M10,2 L10,18" } });
    const json = "[{\"x\":10,\"y\":2},{\"x\":10,\"y\":18}]";
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(json.len));
    try pathById(g, "vert").setAttr("data-points", enc.encode(buf, json));
    try applyLineJumpsToSvg(a, g, &es, arc_config);
    const d = pathById(g, "horiz").getAttr("d").?;
    try testing.expectEqualStrings("M0,5 L9,5 A1,1 0 0 1 11,5 L20,5", d);
    try testing.expectEqualStrings("M10,2 L10,18", pathById(g, "vert").getAttr("d").?);
}

test "applyLineJumpsToSvg applies marker offsets to the rewritten endpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hp = mk(&.{ .{ 0, 5 }, .{ 20, 5 } });
    const vp = mk(&.{ .{ 10, 0 }, .{ 10, 20 } });
    const es = [_]EdgeGeom{ .{ .id = "horiz", .points = &hp, .curve = "linear", .arrow_type_end = "arrow_point" }, .{ .id = "vert", .points = &vp, .curve = "linear" } };
    const g = try makeGroup(a, &.{ .{ "horiz", "M0,5 L20,5" }, .{ "vert", "M10,0 L10,20" } });
    try applyLineJumpsToSvg(a, g, &es, arc_config);
    try testing.expect(std.mem.endsWith(u8, pathById(g, "horiz").getAttr("d").?, "L16,5"));
}

test "applyLineJumpsToSvg recomputes the neo stroke-dasharray and keeps other declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hp = mk(&.{ .{ 0, 5 }, .{ 20, 5 } });
    const vp = mk(&.{ .{ 10, 0 }, .{ 10, 20 } });
    const es = [_]EdgeGeom{ .{ .id = "horiz", .points = &hp, .curve = "linear" }, .{ .id = "vert", .points = &vp, .curve = "linear" } };
    const g = try makeGroup(a, &.{ .{ "horiz", "M0,5 L20,5" }, .{ "vert", "M10,0 L10,20" } });
    const style = "stroke-dasharray: 0 9 42 9; stroke-dashoffset: 0; stroke: #000;";
    try pathById(g, "horiz").setAttr("style", style);
    try pathById(g, "vert").setAttr("style", style);
    try applyLineJumpsToSvg(a, g, &es, arc_config);
    try testing.expectEqualStrings(style, pathById(g, "vert").getAttr("style").?);
    const s = pathById(g, "horiz").getAttr("style").?;
    const want = try std.fmt.allocPrint(a, "stroke-dasharray: 0 9 {s} 9; stroke-dashoffset: 0; stroke: #000;", .{try edges_mod.jsNum(a, pathlen.length(pathById(g, "horiz").getAttr("d").?) - 18)});
    try testing.expectEqualStrings(want, s);
}

test "applyLineJumpsToSvg does nothing when disabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "e1", .points = &H }, .{ .id = "e2", .points = &V } };
    const g = try makeGroup(a, &.{ .{ "e1", "M0,5 L10,5" }, .{ "e2", "M5,0 L5,10" } });
    var cfg = arc_config;
    cfg.enabled = false;
    try applyLineJumpsToSvg(a, g, &es, cfg);
    try testing.expectEqualStrings("M0,5 L10,5", pathById(g, "e1").getAttr("d").?);
    try testing.expectEqualStrings("M5,0 L5,10", pathById(g, "e2").getAttr("d").?);
}

test "applyLineHops uses radius 6 and the chosen style" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hp = mk(&.{ .{ 0, 50 }, .{ 100, 50 } });
    const vp = mk(&.{ .{ 50, 0 }, .{ 50, 100 } });
    const one = mk(&.{.{ 1, 1 }});
    const es = [_]EdgeGeom{ .{ .id = "h", .points = &hp }, .{ .id = "v", .points = &vp }, .{ .id = "x", .points = &one } };
    const g = try makeGroup(a, &.{ .{ "h", "M0,50 L100,50" }, .{ "v", "M50,0 L50,100" } });
    try applyLineHops(a, g, &es, .gap);
    try testing.expectEqualStrings("M0,50 L44,50 M56,50 L100,50", pathById(g, "h").getAttr("d").?);
}

const ROOMY: LineJumpConfig = .{ .enabled = true, .jump_radius = 6, .jump_style = .arc };

const cramped_a = mk(&.{ .{ 395.6, 275.3 }, .{ 430.6, 275.3 }, .{ 430.6, 180.1 }, .{ 502.1, 180.1 } });
const cramped_b = mk(&.{ .{ 440.6, 120 }, .{ 440.6, 320 } });

test "cramped bend: crossing found but no undersized arc drawn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "designSystemToApp", .points = &cramped_a, .curve = "rounded" }, .{ .id = "infrastructureToAuth", .points = &cramped_b, .curve = "rounded" } };
    const d = pathOf(try processEdgesWithJumps(a, &es, ROOMY), "designSystemToApp");
    try testing.expectEqual(@as(usize, 1), (try findEdgeIntersections(a, &es)).len);
    try testing.expect(std.mem.indexOfScalar(u8, d, 'A') == null);
    try testing.expect(std.mem.indexOf(u8, d, "L437.696,180.086 L437.696,180.086") == null);
}

test "cramped bend: still hops once the bend is far enough away" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var roomy = cramped_a;
    roomy[1] = .{ .x = 420.6, .y = 275.3 };
    roomy[2] = .{ .x = 420.6, .y = 180.1 };
    const es = [_]EdgeGeom{ .{ .id = "designSystemToApp", .points = &roomy, .curve = "rounded" }, .{ .id = "infrastructureToAuth", .points = &cramped_b, .curve = "rounded" } };
    const d = pathOf(try processEdgesWithJumps(a, &es, ROOMY), "designSystemToApp");
    try testing.expect(std.mem.indexOf(u8, d, "A6,6 0 0 1") != null);
}

const across_a = mk(&.{ .{ 169, 1031.102 }, .{ 249, 1031.102 }, .{ 249, 1345.091 }, .{ 552.5, 1345.091 } });
const across_b = mk(&.{ .{ 229, 1382.007 }, .{ 229, 1033.625 }, .{ 269, 1033.625 }, .{ 351.5, 1033.625 } });

test "crossing inside the other edge's corner is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = [_]EdgeGeom{ .{ .id = "orgToPlatform", .points = &across_a, .curve = "rounded" }, .{ .id = "designToApp", .points = &across_b, .curve = "rounded" } };
    try testing.expectEqual(@as(usize, 0), (try findEdgeIntersections(a, &es)).len);
    const d = pathOf(try processEdgesWithJumps(a, &es, ROOMY), "designToApp");
    try testing.expect(std.mem.indexOfScalar(u8, d, 'A') == null);
}

test "hops normally once that corner is out of the way" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var clear = across_a;
    clear[0] = .{ .x = 169, .y = 1001.102 };
    clear[1] = .{ .x = 249, .y = 1001.102 };
    const es = [_]EdgeGeom{ .{ .id = "orgToPlatform", .points = &clear, .curve = "rounded" }, .{ .id = "designToApp", .points = &across_b, .curve = "rounded" } };
    try testing.expectEqual(@as(usize, 1), (try findEdgeIntersections(a, &es)).len);
    try testing.expect(std.mem.indexOf(u8, pathOf(try processEdgesWithJumps(a, &es, ROOMY), "designToApp"), "A6,6") != null);
}

test "a straight run is kept between the corner and a hop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bend = mk(&.{ .{ 100, 0 }, .{ 100, 100 }, .{ 300, 100 } });
    const crosser = mk(&.{ .{ 113, 0 }, .{ 113, 200 } });
    const es = [_]EdgeGeom{ .{ .id = "bend", .points = &bend, .curve = "rounded" }, .{ .id = "crosser", .points = &crosser } };
    const d = pathOf(try processEdgesWithJumps(a, &es, ROOMY), "bend");
    const at = std.mem.indexOf(u8, d, ",100 A").?;
    const l = std.mem.lastIndexOfScalar(u8, d[0..at], 'L').?;
    const open_at = try parseAfter(d, l + 1);
    const radius = try parseAfter(d, at + 6);
    try testing.expectApproxEqAbs(2, open_at - 107.071, 0.005);
    try testing.expectApproxEqAbs(3.929, radius, 0.005);
}
