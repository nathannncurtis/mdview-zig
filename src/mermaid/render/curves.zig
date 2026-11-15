const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const Point = model.Point;

pub const Curve = enum { basis, linear, cardinal, bump_x, bump_y, catmull_rom, monotone_x, monotone_y, natural, step, step_after, step_before };

pub fn fromName(name: ?[]const u8) Curve {
    const n = name orelse return .basis;
    const map = [_]struct { []const u8, Curve }{
        .{ "linear", .linear },
        .{ "basis", .basis },
        .{ "cardinal", .cardinal },
        .{ "bumpX", .bump_x },
        .{ "bumpY", .bump_y },
        .{ "catmullRom", .catmull_rom },
        .{ "monotoneX", .monotone_x },
        .{ "monotoneY", .monotone_y },
        .{ "natural", .natural },
        .{ "step", .step },
        .{ "stepAfter", .step_after },
        .{ "stepBefore", .step_before },
        .{ "rounded", .linear },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], n)) return m[1];
    return .basis;
}

// d3-path with digits=3: every number is Math.round(v*1000)/1000 printed as a JS number.
const Path = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    swap: bool = false,

    fn num(self: *Path, v: f64) Allocator.Error!void {
        const r = @floor(v * 1000 + 0.5) / 1000;
        if (std.math.isNan(r)) return self.buf.appendSlice(self.a, "NaN");
        if (r == 0) return self.buf.append(self.a, '0');
        try self.buf.print(self.a, "{d}", .{r});
    }

    fn pair(self: *Path, x: f64, y: f64) Allocator.Error!void {
        try self.num(if (self.swap) y else x);
        try self.buf.append(self.a, ',');
        try self.num(if (self.swap) x else y);
    }

    fn moveTo(self: *Path, x: f64, y: f64) Allocator.Error!void {
        try self.buf.append(self.a, 'M');
        try self.pair(x, y);
    }

    fn lineTo(self: *Path, x: f64, y: f64) Allocator.Error!void {
        try self.buf.append(self.a, 'L');
        try self.pair(x, y);
    }

    fn bezier(self: *Path, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) Allocator.Error!void {
        try self.buf.append(self.a, 'C');
        try self.pair(x1, y1);
        try self.buf.append(self.a, ',');
        try self.pair(x2, y2);
        try self.buf.append(self.a, ',');
        try self.pair(x, y);
    }

    fn close(self: *Path) Allocator.Error!void {
        try self.buf.append(self.a, 'Z');
    }
};

const nan = std.math.nan(f64);

fn sign(x: f64) f64 {
    return if (x < 0) -1 else 1;
}

fn min3(a: f64, b: f64, c: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b) or std.math.isNan(c)) return nan;
    return @min(a, @min(b, c));
}

const Gen = struct {
    p: *Path,
    curve: Curve,
    point: u8 = 0,
    x0: f64 = nan,
    x1: f64 = nan,
    x2: f64 = nan,
    y0: f64 = nan,
    y1: f64 = nan,
    y2: f64 = nan,
    t0: f64 = nan,
    sx: f64 = nan,
    sy: f64 = nan,
    t: f64 = 0,
    l01_a: f64 = 0,
    l12_a: f64 = 0,
    l23_a: f64 = 0,
    l01_2a: f64 = 0,
    l12_2a: f64 = 0,
    l23_2a: f64 = 0,
    xs: std.ArrayList(f64) = .empty,
    ys: std.ArrayList(f64) = .empty,

    fn basisPoint(g: *Gen, x: f64, y: f64) Allocator.Error!void {
        try g.p.bezier((2 * g.x0 + g.x1) / 3, (2 * g.y0 + g.y1) / 3, (g.x0 + 2 * g.x1) / 3, (g.y0 + 2 * g.y1) / 3, (g.x0 + 4 * g.x1 + x) / 6, (g.y0 + 4 * g.y1 + y) / 6);
    }

    fn cardinalPoint(g: *Gen, x: f64, y: f64) Allocator.Error!void {
        const k: f64 = 1.0 / 6.0;
        try g.p.bezier(g.x1 + k * (g.x2 - g.x0), g.y1 + k * (g.y2 - g.y0), g.x2 + k * (g.x1 - x), g.y2 + k * (g.y1 - y), g.x2, g.y2);
    }

    fn catmullPoint(g: *Gen, x: f64, y: f64) Allocator.Error!void {
        const eps = 1e-6;
        var x1 = g.x1;
        var y1 = g.y1;
        var x2 = g.x2;
        var y2 = g.y2;
        if (g.l01_a > eps) {
            const a = 2 * g.l01_2a + 3 * g.l01_a * g.l12_a + g.l12_2a;
            const n = 3 * g.l01_a * (g.l01_a + g.l12_a);
            x1 = (x1 * a - g.x0 * g.l12_2a + g.x2 * g.l01_2a) / n;
            y1 = (y1 * a - g.y0 * g.l12_2a + g.y2 * g.l01_2a) / n;
        }
        if (g.l23_a > eps) {
            const b = 2 * g.l23_2a + 3 * g.l23_a * g.l12_a + g.l12_2a;
            const m = 3 * g.l23_a * (g.l23_a + g.l12_a);
            x2 = (x2 * b + g.x1 * g.l23_2a - x * g.l12_2a) / m;
            y2 = (y2 * b + g.y1 * g.l23_2a - y * g.l12_2a) / m;
        }
        try g.p.bezier(x1, y1, x2, y2, g.x2, g.y2);
    }

    fn slope3(g: *Gen, x2: f64, y2: f64) f64 {
        const h0 = g.x1 - g.x0;
        const h1 = x2 - g.x1;
        const d0: f64 = if (h0 != 0) h0 else if (h1 < 0) -0.0 else 0.0;
        const d1: f64 = if (h1 != 0) h1 else if (h0 < 0) -0.0 else 0.0;
        const s0 = (g.y1 - g.y0) / d0;
        const s1 = (y2 - g.y1) / d1;
        const p = (s0 * h1 + s1 * h0) / (h0 + h1);
        const r = (sign(s0) + sign(s1)) * min3(@abs(s0), @abs(s1), 0.5 * @abs(p));
        return if (std.math.isNan(r) or r == 0) 0 else r;
    }

    fn slope2(g: *Gen, t: f64) f64 {
        const h = g.x1 - g.x0;
        return if (h != 0) (3 * (g.y1 - g.y0) / h - t) / 2 else t;
    }

    fn monoPoint(g: *Gen, t0: f64, t1: f64) Allocator.Error!void {
        const dx = (g.x1 - g.x0) / 3;
        try g.p.bezier(g.x0 + dx, g.y0 + dx * t0, g.x1 - dx, g.y1 - dx * t1, g.x1, g.y1);
    }

    fn controlPoints(a: Allocator, x: []const f64) Allocator.Error![2][]f64 {
        const n = x.len - 1;
        const aa = try a.alloc(f64, n);
        const b = try a.alloc(f64, n);
        const r = try a.alloc(f64, n);
        aa[0] = 0;
        b[0] = 2;
        r[0] = x[0] + 2 * x[1];
        var i: usize = 1;
        while (i + 1 < n) : (i += 1) {
            aa[i] = 1;
            b[i] = 4;
            r[i] = 4 * x[i] + 2 * x[i + 1];
        }
        aa[n - 1] = 2;
        b[n - 1] = 7;
        r[n - 1] = 8 * x[n - 1] + x[n];
        i = 1;
        while (i < n) : (i += 1) {
            const m = aa[i] / b[i - 1];
            b[i] -= m;
            r[i] -= m * r[i - 1];
        }
        aa[n - 1] = r[n - 1] / b[n - 1];
        var j: usize = n - 1;
        while (j > 0) {
            j -= 1;
            aa[j] = (r[j] - aa[j + 1]) / b[j];
        }
        b[n - 1] = (x[n] + aa[n - 1]) / 2;
        i = 0;
        while (i + 1 < n) : (i += 1) b[i] = 2 * x[i + 1] - aa[i + 1];
        return .{ aa, b };
    }

    fn lineEnd(g: *Gen) Allocator.Error!void {
        switch (g.curve) {
            .linear, .bump_x, .bump_y => {},
            .basis => switch (g.point) {
                3 => {
                    try g.basisPoint(g.x1, g.y1);
                    try g.p.lineTo(g.x1, g.y1);
                },
                2 => try g.p.lineTo(g.x1, g.y1),
                else => {},
            },
            .cardinal => switch (g.point) {
                2 => try g.p.lineTo(g.x2, g.y2),
                3 => try g.cardinalPoint(g.x1, g.y1),
                else => {},
            },
            .catmull_rom => switch (g.point) {
                2 => try g.p.lineTo(g.x2, g.y2),
                3 => try g.pointCatmull(g.x2, g.y2),
                else => {},
            },
            .monotone_x, .monotone_y => switch (g.point) {
                2 => try g.p.lineTo(g.x1, g.y1),
                3 => try g.monoPoint(g.t0, g.slope2(g.t0)),
                else => {},
            },
            .step, .step_after, .step_before => {
                if (0 < g.t and g.t < 1 and g.point == 2) try g.p.lineTo(g.sx, g.sy);
            },
            .natural => {
                const n = g.xs.items.len;
                if (n > 0) {
                    const x = g.xs.items;
                    const y = g.ys.items;
                    try g.p.moveTo(x[0], y[0]);
                    if (n == 2) {
                        try g.p.lineTo(x[1], y[1]);
                    } else {
                        const px = try controlPoints(g.p.a, x);
                        const py = try controlPoints(g.p.a, y);
                        var k0: usize = 0;
                        while (k0 + 1 < n) : (k0 += 1) try g.p.bezier(px[0][k0], py[0][k0], px[1][k0], py[1][k0], x[k0 + 1], y[k0 + 1]);
                    }
                }
                if (n == 1) try g.p.close();
                return;
            },
        }
        if (g.point == 1) try g.p.close();
    }

    fn pointCatmull(g: *Gen, x: f64, y: f64) Allocator.Error!void {
        try g.addPoint(x, y);
    }

    fn addPoint(g: *Gen, x: f64, y: f64) Allocator.Error!void {
        switch (g.curve) {
            .linear => switch (g.point) {
                0 => {
                    g.point = 1;
                    try g.p.moveTo(x, y);
                },
                else => {
                    g.point = 2;
                    try g.p.lineTo(x, y);
                },
            },
            .basis => {
                switch (g.point) {
                    0 => {
                        g.point = 1;
                        try g.p.moveTo(x, y);
                    },
                    1 => g.point = 2,
                    2 => {
                        g.point = 3;
                        try g.p.lineTo((5 * g.x0 + g.x1) / 6, (5 * g.y0 + g.y1) / 6);
                        try g.basisPoint(x, y);
                    },
                    else => try g.basisPoint(x, y),
                }
                g.x0 = g.x1;
                g.x1 = x;
                g.y0 = g.y1;
                g.y1 = y;
            },
            .cardinal => {
                switch (g.point) {
                    0 => {
                        g.point = 1;
                        try g.p.moveTo(x, y);
                    },
                    1 => {
                        g.point = 2;
                        g.x1 = x;
                        g.y1 = y;
                    },
                    2 => {
                        g.point = 3;
                        try g.cardinalPoint(x, y);
                    },
                    else => try g.cardinalPoint(x, y),
                }
                g.x0 = g.x1;
                g.x1 = g.x2;
                g.x2 = x;
                g.y0 = g.y1;
                g.y1 = g.y2;
                g.y2 = y;
            },
            .catmull_rom => {
                if (g.point != 0) {
                    const x23 = g.x2 - x;
                    const y23 = g.y2 - y;
                    g.l23_2a = std.math.pow(f64, x23 * x23 + y23 * y23, 0.5);
                    g.l23_a = @sqrt(g.l23_2a);
                }
                switch (g.point) {
                    0 => {
                        g.point = 1;
                        try g.p.moveTo(x, y);
                    },
                    1 => g.point = 2,
                    2 => {
                        g.point = 3;
                        try g.catmullPoint(x, y);
                    },
                    else => try g.catmullPoint(x, y),
                }
                g.l01_a = g.l12_a;
                g.l12_a = g.l23_a;
                g.l01_2a = g.l12_2a;
                g.l12_2a = g.l23_2a;
                g.x0 = g.x1;
                g.x1 = g.x2;
                g.x2 = x;
                g.y0 = g.y1;
                g.y1 = g.y2;
                g.y2 = y;
            },
            .bump_x, .bump_y => {
                switch (g.point) {
                    0 => {
                        g.point = 1;
                        try g.p.moveTo(x, y);
                    },
                    else => {
                        g.point = 2;
                        if (g.curve == .bump_x) {
                            g.x0 = (g.x0 + x) / 2;
                            try g.p.bezier(g.x0, g.y0, g.x0, y, x, y);
                        } else {
                            g.y0 = (g.y0 + y) / 2;
                            try g.p.bezier(g.x0, g.y0, x, g.y0, x, y);
                        }
                    },
                }
                g.x0 = x;
                g.y0 = y;
            },
            .monotone_x, .monotone_y => {
                const px = if (g.curve == .monotone_y) y else x;
                const py = if (g.curve == .monotone_y) x else y;
                var t1: f64 = nan;
                if (px == g.x1 and py == g.y1) return;
                switch (g.point) {
                    0 => {
                        g.point = 1;
                        try g.p.moveTo(px, py);
                    },
                    1 => g.point = 2,
                    2 => {
                        g.point = 3;
                        t1 = g.slope3(px, py);
                        try g.monoPoint(g.slope2(t1), t1);
                    },
                    else => {
                        t1 = g.slope3(px, py);
                        try g.monoPoint(g.t0, t1);
                    },
                }
                g.x0 = g.x1;
                g.x1 = px;
                g.y0 = g.y1;
                g.y1 = py;
                g.t0 = t1;
            },
            .step, .step_after, .step_before => {
                switch (g.point) {
                    0 => {
                        g.point = 1;
                        try g.p.moveTo(x, y);
                    },
                    else => {
                        g.point = 2;
                        if (g.t <= 0) {
                            try g.p.lineTo(g.sx, y);
                            try g.p.lineTo(x, y);
                        } else {
                            const x1 = g.sx * (1 - g.t) + x * g.t;
                            try g.p.lineTo(x1, g.sy);
                            try g.p.lineTo(x1, y);
                        }
                    },
                }
                g.sx = x;
                g.sy = y;
            },
            .natural => {
                try g.xs.append(g.p.a, x);
                try g.ys.append(g.p.a, y);
            },
        }
    }
};

// d3 line().curve(c) over the already offset points; "" for no points.
pub fn line(a: Allocator, pts: []const Point, curve: Curve) Allocator.Error![]const u8 {
    if (pts.len == 0) return "";
    var p: Path = .{ .a = a, .swap = curve == .monotone_y };
    var g: Gen = .{ .p = &p, .curve = curve };
    g.t = switch (curve) {
        .step => 0.5,
        .step_after => 1,
        .step_before => 0,
        else => 0,
    };
    for (pts) |pt| try g.addPoint(pt.x, pt.y);
    try g.lineEnd();
    return p.buf.items;
}

fn expectPath(pts: []const Point, curve: Curve, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try line(arena.allocator(), pts, curve);
    try std.testing.expectEqualStrings(want, got);
}

test "linear" {
    try expectPath(&.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 5.12345 } }, .linear, "M0,0L10,5.123");
}

test "basis with two points is a line, three points follow d3" {
    try expectPath(&.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 60 } }, .basis, "M0,0L0,60");
    try expectPath(&.{ .{ .x = 0, .y = 0 }, .{ .x = 30, .y = 0 }, .{ .x = 30, .y = 60 } }, .basis, "M0,0L5,0C10,0,20,0,25,10C30,20,30,40,30,50L30,60");
}

test "every curve starts at the first point and ends at the last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 30, .y = 10 }, .{ .x = 20, .y = 40 }, .{ .x = 40, .y = 60 } };
    for (std.enums.values(Curve)) |c| {
        const s = try line(arena.allocator(), &pts, c);
        try std.testing.expect(std.mem.startsWith(u8, s, "M0,0"));
        try std.testing.expect(std.mem.endsWith(u8, s, "40,60"));
    }
}

test "step curve" {
    try expectPath(&.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 20 } }, .step, "M0,0L5,0L5,20L10,20");
}
