const std = @import("std");
const model = @import("model.zig");
const Point = model.Point;
const NodeData = model.NodeData;

pub fn rect(node: *const NodeData, point: Point) Point {
    const x = node.x;
    const y = node.y;
    const dx = point.x - x;
    const dy = point.y - y;
    var w = node.width / 2;
    var h = node.height / 2;
    var sx: f64 = 0;
    var sy: f64 = 0;
    if (@abs(dy) * w > @abs(dx) * h) {
        if (dy < 0) h = -h;
        sx = if (dy == 0) 0 else (h * dx) / dy;
        sy = h;
    } else {
        if (dx < 0) w = -w;
        sx = w;
        sy = if (dx == 0) 0 else (w * dy) / dx;
    }
    return .{ .x = x + sx, .y = y + sy };
}

pub fn ellipse(node: *const NodeData, rx: f64, ry: f64, point: Point) Point {
    const cx = node.x;
    const cy = node.y;
    const px = cx - point.x;
    const py = cy - point.y;
    const det = @sqrt(rx * rx * py * py + ry * ry * px * px);
    var dx = @abs((rx * ry * px) / det);
    if (point.x < cx) dx = -dx;
    var dy = @abs((rx * ry * py) / det);
    if (point.y < cy) dy = -dy;
    return .{ .x = cx + dx, .y = cy + dy };
}

pub fn circle(node: *const NodeData, rx: f64, point: Point) Point {
    return ellipse(node, rx, rx, point);
}

fn sameSign(r1: f64, r2: f64) bool {
    return r1 * r2 > 0;
}

pub fn line(p1: Point, p2: Point, q1: Point, q2: Point) ?Point {
    const a1 = p2.y - p1.y;
    const b1 = p1.x - p2.x;
    const c1 = p2.x * p1.y - p1.x * p2.y;
    const r3 = a1 * q1.x + b1 * q1.y + c1;
    const r4 = a1 * q2.x + b1 * q2.y + c1;
    const epsilon = 1e-6;
    if (r3 != 0 and r4 != 0 and sameSign(r3, r4)) return null;
    const a2 = q2.y - q1.y;
    const b2 = q1.x - q2.x;
    const c2 = q2.x * q1.y - q1.x * q2.y;
    const r1 = a2 * p1.x + b2 * p1.y + c2;
    const r2 = a2 * p2.x + b2 * p2.y + c2;
    if (@abs(r1) < epsilon and @abs(r2) < epsilon and sameSign(r1, r2)) return null;
    const denom = a1 * b2 - a2 * b1;
    if (denom == 0) return null;
    const x = (b1 * c2 - b2 * c1) / denom;
    const y = (a2 * c1 - a1 * c2) / denom;
    return .{ .x = x, .y = y };
}

pub fn polygon(node: *const NodeData, poly: []const Point, point: Point) Point {
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    for (poly) |e| {
        min_x = @min(min_x, e.x);
        min_y = @min(min_y, e.y);
    }
    const left = node.x - node.width / 2 - min_x;
    const top = node.y - node.height / 2 - min_y;
    const center: Point = .{ .x = node.x, .y = node.y };
    var best: ?Point = null;
    var best_d: f64 = 0;
    for (poly, 0..) |p1, i| {
        const p2 = poly[if (i < poly.len - 1) i + 1 else 0];
        const hit = line(center, point, .{ .x = left + p1.x, .y = top + p1.y }, .{ .x = left + p2.x, .y = top + p2.y }) orelse continue;
        const pdx = hit.x - point.x;
        const pdy = hit.y - point.y;
        const d = @sqrt(pdx * pdx + pdy * pdy);
        if (best == null or d < best_d) {
            best = hit;
            best_d = d;
        }
    }
    return best orelse center;
}

pub fn intersectNode(node: *const NodeData, point: Point) Point {
    const kind = node.intersect orelse return rect(node, point);
    return switch (kind) {
        .rect => rect(node, point),
        .circle => |r| circle(node, r, point),
        .ellipse => |e| ellipse(node, e.rx, e.ry, point),
        .polygon => |p| blk: {
            const r = polygon(node, p.points, point);
            break :blk .{ .x = r.x + p.adjust.x, .y = r.y + p.adjust.y };
        },
        .custom => |f| f(node, point),
    };
}

test "rect intersect leaves through the bottom edge" {
    const n: NodeData = .{ .id = "a", .x = 50, .y = 20, .width = 100, .height = 40 };
    const p = rect(&n, .{ .x = 50, .y = 100 });
    try std.testing.expectEqual(@as(f64, 50), p.x);
    try std.testing.expectEqual(@as(f64, 40), p.y);
}

test "circle intersect on the right" {
    const n: NodeData = .{ .id = "a", .x = 0, .y = 0, .width = 20, .height = 20 };
    const p = circle(&n, 10, .{ .x = 100, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 10), p.x, 1e-9);
}

test "polygon intersect picks the crossing nearest the outside point" {
    const n: NodeData = .{ .id = "a", .x = 10, .y = 10, .width = 20, .height = 20 };
    const sq = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 20 }, .{ .x = 0, .y = 20 } };
    const p = polygon(&n, &sq, .{ .x = 10, .y = 100 });
    try std.testing.expectApproxEqAbs(@as(f64, 20), p.y, 1e-9);
}

test "line intersect" {
    const p = line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 }, .{ .x = 10, .y = 0 }).?;
    try std.testing.expectEqual(@as(f64, 5), p.x);
    try std.testing.expect(line(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }) == null);
}

test "line intersection is exact, with no half-unit rounding" {
    const p = line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = -5 }, .{ .x = 5, .y = 5 }).?;
    try std.testing.expectEqual(@as(f64, 5), p.x);
    try std.testing.expectEqual(@as(f64, 0), p.y);
}
