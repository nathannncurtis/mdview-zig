const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const Point = model.Point;

pub fn jsRound(x: f64) f64 {
    return @floor(x + 0.5);
}

pub fn roundNumber(num: f64, precision: u32) f64 {
    const factor = std.math.pow(f64, 10, @floatFromInt(precision));
    return jsRound(num * factor) / factor;
}

pub fn markerOffset(name: []const u8) ?f64 {
    const tbl = [_]struct { []const u8, f64 }{
        .{ "aggregation", 17.25 },
        .{ "extension", 17.25 },
        .{ "composition", 17.25 },
        .{ "dependency", 6 },
        .{ "lollipop", 13.5 },
        .{ "arrow_point", 4 },
        .{ "arrow_barb", 0 },
        .{ "arrow_barb_neo", 5.5 },
    };
    for (tbl) |t| if (std.mem.eql(u8, t[0], name)) return t[1];
    return null;
}

pub fn markerOffset2(name: []const u8) f64 {
    if (std.mem.eql(u8, name, "arrow_point")) return 4;
    if (std.mem.eql(u8, name, "arrow_cross") or std.mem.eql(u8, name, "arrow_circle")) return 12.5;
    return 0;
}

pub fn distance(p1: Point, p2: Point) f64 {
    return @sqrt(std.math.pow(f64, p2.x - p1.x, 2) + std.math.pow(f64, p2.y - p1.y, 2));
}

pub const PointError = error{NoSuitablePoint};

pub fn calculatePoint(points: []const Point, distance_to_traverse: f64) PointError!Point {
    var prev: ?Point = null;
    var remaining = distance_to_traverse;
    for (points) |point| {
        if (prev) |pp| {
            const vd = distance(point, pp);
            if (vd == 0) return pp;
            if (vd < remaining) {
                remaining -= vd;
            } else {
                const ratio = remaining / vd;
                if (ratio <= 0) return pp;
                if (ratio >= 1) return .{ .x = point.x, .y = point.y };
                if (ratio > 0 and ratio < 1) return .{
                    .x = roundNumber((1 - ratio) * pp.x + ratio * point.x, 5),
                    .y = roundNumber((1 - ratio) * pp.y + ratio * point.y, 5),
                };
            }
        }
        prev = point;
    }
    return error.NoSuitablePoint;
}

pub fn calcLabelPosition(points: []const Point) PointError!Point {
    if (points.len == 1) return points[0];
    var total: f64 = 0;
    var prev: ?Point = null;
    for (points) |p| {
        if (prev) |pp| total += distance(p, pp);
        prev = p;
    }
    return calculatePoint(points, total / 2);
}

pub const TerminalPos = enum { start_left, start_right, end_left, end_right };

pub fn calcTerminalLabelPosition(a: Allocator, marker_size: f64, position: TerminalPos, in: []const Point) (PointError || Allocator.Error)!Point {
    const pts = try a.dupe(Point, in);
    if (position != .start_left and position != .start_right) std.mem.reverse(Point, pts);
    const center = try calculatePoint(pts, 25 + marker_size);
    const d = 10 + marker_size * 0.5;
    const angle = std.math.atan2(pts[0].y - center.y, pts[0].x - center.x);
    const mx = (pts[0].x + center.x) / 2;
    const my = (pts[0].y + center.y) / 2;
    return switch (position) {
        .start_left => .{ .x = @sin(angle + std.math.pi) * d + mx, .y = -@cos(angle + std.math.pi) * d + my },
        .end_right => .{ .x = @sin(angle - std.math.pi) * d + mx - 5, .y = -@cos(angle - std.math.pi) * d + my - 5 },
        .end_left => .{ .x = @sin(angle) * d + mx - 5, .y = -@cos(angle) * d + my - 5 },
        .start_right => .{ .x = @sin(angle) * d + mx, .y = -@cos(angle) * d + my },
    };
}

// d attribute is searched as text; decimals are rounded the way the regex in utils.ts does.
pub fn isLabelCoordinateInPath(a: Allocator, point: Point, d_attr: []const u8) Allocator.Error!bool {
    const rx = jsRound(point.x);
    const ry = jsRound(point.y);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < d_attr.len) {
        if (std.ascii.isDigit(d_attr[i])) {
            var j = i;
            while (j < d_attr.len and std.ascii.isDigit(d_attr[j])) j += 1;
            if (j + 1 < d_attr.len and d_attr[j] == '.' and std.ascii.isDigit(d_attr[j + 1])) {
                var k = j + 1;
                while (k < d_attr.len and std.ascii.isDigit(d_attr[k])) k += 1;
                const v = std.fmt.parseFloat(f64, d_attr[i..k]) catch 0;
                try out.print(a, "{d}", .{jsRound(v)});
                i = k;
                continue;
            }
            try out.appendSlice(a, d_attr[i..j]);
            i = j;
            continue;
        }
        try out.append(a, d_attr[i]);
        i += 1;
    }
    const xs = try numStr(a, rx);
    const ys = try numStr(a, ry);
    return std.mem.indexOf(u8, out.items, xs) != null or std.mem.indexOf(u8, out.items, ys) != null;
}

fn numStr(a: Allocator, v: f64) Allocator.Error![]const u8 {
    if (v == 0) return "0";
    return std.fmt.allocPrint(a, "{d}", .{v});
}

const Delta = struct { angle: f64, dx: f64, dy: f64 };

fn deltaAngle(p1: ?Point, p2: ?Point) Delta {
    const a = p1 orelse return .{ .angle = 0, .dx = 0, .dy = 0 };
    const b = p2 orelse return .{ .angle = 0, .dx = 0, .dy = 0 };
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return .{ .angle = std.math.atan(dy / dx), .dx = dx, .dy = dy };
}

fn at(data: []const Point, i: usize) ?Point {
    return if (i < data.len) data[i] else null;
}

// getLineFunctionsWithOffset from utils/lineWithOffset.ts applied to every point of `data`.
pub fn offsetPoints(a: Allocator, data: []const Point, arrow_start: []const u8, arrow_end: []const u8) Allocator.Error![]Point {
    const out = try a.alloc(Point, data.len);
    const n = data.len;
    if (n == 0) return out;
    const sm = markerOffset(arrow_start);
    const em = markerOffset(arrow_end);
    const dir_left = data[0].x < data[n - 1].x;
    const dir_down = data[0].y < data[n - 1].y;
    const extra = 1.0;
    for (data, 0..) |d, i| {
        var ox: f64 = 0;
        var oy: f64 = 0;
        if (i == 0 and sm != null) {
            const r = deltaAngle(data[0], at(data, 1));
            ox = sm.? * @cos(r.angle) * (if (r.dx >= 0) @as(f64, 1) else -1);
            oy = sm.? * @abs(@sin(r.angle)) * (if (r.dy >= 0) @as(f64, 1) else -1);
        } else if (i == n - 1 and em != null) {
            const r = deltaAngle(data[n - 1], if (n >= 2) data[n - 2] else null);
            ox = em.? * @cos(r.angle) * (if (r.dx >= 0) @as(f64, 1) else -1);
            oy = em.? * @abs(@sin(r.angle)) * (if (r.dy >= 0) @as(f64, 1) else -1);
        }
        const dte_x = @abs(d.x - data[n - 1].x);
        const diy_end = @abs(d.y - data[n - 1].y);
        const dts_x = @abs(d.x - data[0].x);
        const diy_start = @abs(d.y - data[0].y);
        if (em) |h| if (dte_x < h and dte_x > 0 and diy_end < h) {
            var adj = h + extra - dte_x;
            adj *= if (!dir_left) @as(f64, -1) else 1;
            ox -= adj;
        };
        if (sm) |h| if (dts_x < h and dts_x > 0 and diy_start < h) {
            var adj = h + extra - dts_x;
            adj *= if (!dir_left) @as(f64, -1) else 1;
            ox += adj;
        };
        const dte_y = @abs(d.y - data[n - 1].y);
        const dix_end = @abs(d.x - data[n - 1].x);
        const dts_y = @abs(d.y - data[0].y);
        const dix_start = @abs(d.x - data[0].x);
        if (em) |h| if (dte_y < h and dte_y > 0 and dix_end < h) {
            var adj = h + extra - dte_y;
            adj *= if (!dir_down) @as(f64, -1) else 1;
            oy -= adj;
        };
        if (sm) |h| if (dts_y < h and dts_y > 0 and dix_start < h) {
            var adj = h + extra - dts_y;
            adj *= if (!dir_down) @as(f64, -1) else 1;
            oy += adj;
        };
        out[i] = .{ .x = d.x + ox, .y = d.y + oy };
    }
    return out;
}

test "label position is the midpoint of a straight path" {
    const p = try calcLabelPosition(&.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 100 } });
    try std.testing.expectEqual(@as(f64, 50), p.y);
}

test "arrow_point end shortens the path by 4" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try offsetPoints(arena.allocator(), &.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 100 } }, "none", "arrow_point");
    try std.testing.expectApproxEqAbs(@as(f64, 96), out[1].y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), out[1].x, 1e-12);
}

test "label coordinate lookup rounds decimals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try isLabelCoordinateInPath(arena.allocator(), .{ .x = 10, .y = 99 }, "M10.2,5L30.4,60.7"));
    try std.testing.expect(!(try isLabelCoordinateInPath(arena.allocator(), .{ .x = 11, .y = 99 }, "M10.2,5L30.4,60.7")));
}
