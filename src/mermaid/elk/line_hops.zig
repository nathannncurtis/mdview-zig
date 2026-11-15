const std = @import("std");
const Allocator = std.mem.Allocator;
const geo = @import("geometry.zig");
const P = geo.P;

// lineJump.ts: the horizontal edge hops over a crossing one; input and output are final route points / path data.

pub const Style = enum { arc, gap };

pub const EdgeGeom = struct {
    id: []const u8,
    points: []const P,
    rounded: bool,
    marker_start: f64 = 0,
    marker_end: f64 = 0,
};

pub const Rewrite = struct { index: usize, d: []const u8 };

const rounded_corner_radius: f64 = 5;
const corner_epsilon: f64 = 1e-5;
const corner_jump_clearance: f64 = 2;
const min_useful_radius_ratio: f64 = 0.6;
const endpoint_epsilon: f64 = 1e-6;
const jump_radius: f64 = 6;

const Hit = struct { point: P, ta: f64, tb: f64 };

fn segmentIntersection(a1: P, a2: P, b1: P, b2: P) ?Hit {
    const dxa = a2.x - a1.x;
    const dya = a2.y - a1.y;
    const dxb = b2.x - b1.x;
    const dyb = b2.y - b1.y;
    const denom = dxa * dyb - dya * dxb;
    if (denom == 0) return null;
    const dx = b1.x - a1.x;
    const dy = b1.y - a1.y;
    const ta = (dx * dyb - dy * dxb) / denom;
    const tb = (dx * dya - dy * dxa) / denom;
    if (ta <= endpoint_epsilon or ta >= 1 - endpoint_epsilon or tb <= endpoint_epsilon or tb >= 1 - endpoint_epsilon) return null;
    return .{ .point = .{ .x = a1.x + ta * dxa, .y = a1.y + ta * dya }, .ta = ta, .tb = tb };
}

fn isHorizontal(a: P, b: P) bool {
    return @abs(b.x - a.x) >= @abs(b.y - a.y);
}

const Corner = struct { start: P, end: P, ctrl: P, cut_len: f64 };

fn roundedCorner(prev: P, curr: P, next: P, radius: f64) ?Corner {
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
    const dot = nx1 * nx2 + ny1 * ny2;
    const angle = std.math.acos(std.math.clamp(dot, -1, 1));
    if (angle < corner_epsilon or @abs(std.math.pi - angle) < corner_epsilon) return null;
    const cut_len = @min(@min(radius / @sin(angle / 2), len1 / 2), len2 / 2);
    return .{
        .start = .{ .x = curr.x - nx1 * cut_len, .y = curr.y - ny1 * cut_len },
        .end = .{ .x = curr.x + nx2 * cut_len, .y = curr.y + ny2 * cut_len },
        .ctrl = curr,
        .cut_len = cut_len,
    };
}

fn crossingInRoundedCorner(e: EdgeGeom, seg: usize, t: f64) bool {
    if (!e.rounded) return false;
    const pts = e.points;
    const a = pts[seg];
    const b = pts[seg + 1];
    const seg_len = std.math.hypot(b.x - a.x, b.y - a.y);
    const d = t * seg_len;
    if (seg > 0) {
        if (roundedCorner(pts[seg - 1], a, b, rounded_corner_radius)) |c| if (d < c.cut_len) return true;
    }
    if (seg + 2 < pts.len) {
        if (roundedCorner(a, b, pts[seg + 2], rounded_corner_radius)) |c| if (seg_len - d < c.cut_len) return true;
    }
    return false;
}

const Crossing = struct { jump_edge: usize, seg: usize, t: f64, point: P };

fn findIntersections(a: Allocator, edges: []const EdgeGeom) Allocator.Error![]Crossing {
    var out: std.ArrayList(Crossing) = .empty;
    for (edges, 0..) |ea, i| {
        if (ea.points.len < 2) continue;
        for (edges[i + 1 ..], i + 1..) |eb, j| {
            if (eb.points.len < 2) continue;
            for (0..ea.points.len - 1) |si| {
                for (0..eb.points.len - 1) |sj| {
                    const hit = segmentIntersection(ea.points[si], ea.points[si + 1], eb.points[sj], eb.points[sj + 1]) orelse continue;
                    if (crossingInRoundedCorner(ea, si, hit.ta) or crossingInRoundedCorner(eb, sj, hit.tb)) continue;
                    const a_horiz = isHorizontal(ea.points[si], ea.points[si + 1]);
                    const b_horiz = isHorizontal(eb.points[sj], eb.points[sj + 1]);
                    const jump_on_a = a_horiz != b_horiz and a_horiz;
                    if (jump_on_a) {
                        try out.append(a, .{ .jump_edge = i, .seg = si, .t = hit.ta, .point = hit.point });
                    } else {
                        try out.append(a, .{ .jump_edge = j, .seg = sj, .t = hit.tb, .point = hit.point });
                    }
                }
            }
        }
    }
    return out.items;
}

// JS Math.round(n * 1e3) / 1e3, printed the way a JS number prints
fn fmt(a: Allocator, n: f64) Allocator.Error![]const u8 {
    var r = @floor(n * 1e3 + 0.5) / 1e3;
    if (r == 0) r = 0;
    return std.fmt.allocPrint(a, "{d}", .{r});
}

fn pointStr(a: Allocator, p: P) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s},{s}", .{ try fmt(a, p.x), try fmt(a, p.y) });
}

const Jump = struct { t: f64, point: P, d: f64, r: f64 };

fn lessJump(_: void, x: Jump, y: Jump) bool {
    return x.t < y.t;
}

fn applyMarkerOffsets(a: Allocator, e: EdgeGeom) Allocator.Error![]P {
    const out = try a.dupe(P, e.points);
    const n = e.points.len;
    if (e.marker_start != 0) {
        const ang = std.math.atan2(e.points[1].y - e.points[0].y, e.points[1].x - e.points[0].x);
        out[0].x = e.points[0].x + e.marker_start * @cos(ang);
        out[0].y = e.points[0].y + e.marker_start * @sin(ang);
    }
    if (e.marker_end != 0) {
        const ang = std.math.atan2(e.points[n - 1].y - e.points[n - 2].y, e.points[n - 1].x - e.points[n - 2].x);
        out[n - 1].x = e.points[n - 1].x - e.marker_end * @cos(ang);
        out[n - 1].y = e.points[n - 1].y - e.marker_end * @sin(ang);
    }
    return out;
}

fn rewriteEdgePath(a: Allocator, e: EdgeGeom, jumps: []const Crossing, style: Style) Allocator.Error![]const u8 {
    const points = try applyMarkerOffsets(a, e);
    const nseg = points.len - 1;
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(a, try std.fmt.allocPrint(a, "M{s}", .{try pointStr(a, points[0])}));
    for (0..nseg) |i| {
        const sa = points[i];
        const sb = points[i + 1];
        const seg_len = std.math.hypot(sb.x - sa.x, sb.y - sa.y);
        const ux = if (seg_len == 0) 0 else (sb.x - sa.x) / seg_len;
        const uy = if (seg_len == 0) 0 else (sb.y - sa.y) / seg_len;
        const dx = sb.x - sa.x;
        const dy = sb.y - sa.y;
        const sweep: u8 = if (@abs(dx) >= @abs(dy)) (if (dx >= 0) 1 else 0) else (if (dy >= 0) 1 else 0);
        var consumed: f64 = 0;
        if (e.rounded and i > 0) {
            if (roundedCorner(points[i - 1], points[i], points[i + 1], rounded_corner_radius)) |c| consumed = c.cut_len;
        }
        var end_stop = seg_len;
        var upcoming: ?Corner = null;
        if (e.rounded and i < nseg - 1) {
            upcoming = roundedCorner(points[i], points[i + 1], points[i + 2], rounded_corner_radius);
            if (upcoming) |c| end_stop = seg_len - c.cut_len;
        }
        const min_useful = jump_radius * min_useful_radius_ratio;
        var list: std.ArrayList(Jump) = .empty;
        for (jumps) |j| {
            if (j.seg != i) continue;
            try list.append(a, .{ .t = j.t, .point = j.point, .d = j.t * seg_len, .r = jump_radius });
        }
        std.mem.sort(Jump, list.items, {}, lessJump);
        var kept: std.ArrayList(Jump) = .empty;
        for (list.items) |*j| {
            const room = @min(j.d - consumed, end_stop - j.d) - corner_jump_clearance;
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
            const pre: P = .{ .x = j.point.x - ux * j.r, .y = j.point.y - uy * j.r };
            const post: P = .{ .x = j.point.x + ux * j.r, .y = j.point.y + uy * j.r };
            try parts.append(a, try std.fmt.allocPrint(a, "L{s}", .{try pointStr(a, pre)}));
            switch (style) {
                .arc => try parts.append(a, try std.fmt.allocPrint(a, "A{s},{s} 0 0 {d} {s}", .{ try fmt(a, j.r), try fmt(a, j.r), sweep, try pointStr(a, post) })),
                .gap => try parts.append(a, try std.fmt.allocPrint(a, "M{s}", .{try pointStr(a, post)})),
            }
        }
        if (upcoming) |c| {
            try parts.append(a, try std.fmt.allocPrint(a, "L{s},{s}", .{ try fmt(a, c.start.x), try fmt(a, c.start.y) }));
            try parts.append(a, try std.fmt.allocPrint(a, "Q{s},{s} {s},{s}", .{ try fmt(a, c.ctrl.x), try fmt(a, c.ctrl.y), try fmt(a, c.end.x), try fmt(a, c.end.y) }));
        } else {
            try parts.append(a, try std.fmt.allocPrint(a, "L{s}", .{try pointStr(a, sb)}));
        }
    }
    return std.mem.join(a, " ", parts.items);
}

pub fn apply(a: Allocator, edges: []const EdgeGeom, style: Style) Allocator.Error![]Rewrite {
    const crossings = try findIntersections(a, edges);
    var out: std.ArrayList(Rewrite) = .empty;
    if (crossings.len == 0) return out.items;
    for (edges, 0..) |e, i| {
        if (e.points.len < 2) continue;
        var mine: std.ArrayList(Crossing) = .empty;
        for (crossings) |c| if (c.jump_edge == i) try mine.append(a, c);
        if (mine.items.len == 0) continue;
        try out.append(a, .{ .index = i, .d = try rewriteEdgePath(a, e, mine.items, style) });
    }
    return out.items;
}

test "the horizontal edge hops over the vertical one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = [_]P{ .{ .x = 0, .y = 50 }, .{ .x = 100, .y = 50 } };
    const v = [_]P{ .{ .x = 50, .y = 0 }, .{ .x = 50, .y = 100 } };
    const edges = [_]EdgeGeom{
        .{ .id = "h", .points = &h, .rounded = false },
        .{ .id = "v", .points = &v, .rounded = false },
    };
    const out = try apply(a, &edges, .arc);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 0), out[0].index);
    try std.testing.expectEqualStrings("M0,50 L44,50 A6,6 0 0 1 56,50 L100,50", out[0].d);
    const gap = try apply(a, &edges, .gap);
    try std.testing.expectEqualStrings("M0,50 L44,50 M56,50 L100,50", gap[0].d);
}

test "edges that do not cross are left alone, and a crossing inside a corner is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p1 = [_]P{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } };
    const p2 = [_]P{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const none = try apply(a, &[_]EdgeGeom{ .{ .id = "a", .points = &p1, .rounded = false }, .{ .id = "b", .points = &p2, .rounded = false } }, .arc);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const bent = [_]P{ .{ .x = 0, .y = 50 }, .{ .x = 52, .y = 50 }, .{ .x = 52, .y = 100 } };
    const v = [_]P{ .{ .x = 50, .y = 0 }, .{ .x = 50, .y = 100 } };
    const skipped = try apply(a, &[_]EdgeGeom{ .{ .id = "bent", .points = &bent, .rounded = true }, .{ .id = "v", .points = &v, .rounded = true } }, .arc);
    try std.testing.expectEqual(@as(usize, 0), skipped.len);
}

test "a marker offset shortens the rewritten path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = [_]P{ .{ .x = 0, .y = 50 }, .{ .x = 100, .y = 50 } };
    const v = [_]P{ .{ .x = 50, .y = 0 }, .{ .x = 50, .y = 100 } };
    const out = try apply(a, &[_]EdgeGeom{ .{ .id = "h", .points = &h, .rounded = false, .marker_end = 4 }, .{ .id = "v", .points = &v, .rounded = false } }, .arc);
    try std.testing.expectEqualStrings("M0,50 L44,50 A6,6 0 0 1 56,50 L96,50", out[0].d);
}
