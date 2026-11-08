const std = @import("std");
const md = @import("markdown.zig");

pub const Style = struct { border: u24, fg: u24 };

pub fn style(a: md.Alert) Style {
    return switch (a) {
        .none, .note => .{ .border = 0x1f6feb, .fg = 0x4493f8 },
        .tip => .{ .border = 0x238636, .fg = 0x3fb950 },
        .important => .{ .border = 0x8957e5, .fg = 0xab7df8 },
        .warning => .{ .border = 0x9e6a03, .fg = 0xd29922 },
        .caution => .{ .border = 0xda3633, .fg = 0xf85149 },
    };
}

/// A path command on the 16x16 icon grid; fill with the nonzero rule.
pub const Op = union(enum) { move: [2]f32, line: [2]f32, cubic: [6]f32, close };

// Octicons 16px: info, light-bulb, report, alert, stop (github.com/primer/octicons, MIT).
const data = [_][]const u8{
    "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z",
    "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z",
    "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
    "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
    "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z",
};

const Builder = struct {
    // SAFETY: only ops[0..n] is ever read
    ops: [160]Op = undefined,
    n: usize = 0,
    cx: f64 = 0,
    cy: f64 = 0,
    sx: f64 = 0,
    sy: f64 = 0,
    c2x: f64 = 0,
    c2y: f64 = 0,
    smooth: bool = false,

    fn push(b: *Builder, op: Op) void {
        b.ops[b.n] = op;
        b.n += 1;
    }

    fn moveTo(b: *Builder, x: f64, y: f64) void {
        b.smooth = false;
        b.push(.{ .move = .{ @floatCast(x), @floatCast(y) } });
        b.cx = x;
        b.cy = y;
        b.sx = x;
        b.sy = y;
    }

    fn lineTo(b: *Builder, x: f64, y: f64) void {
        b.smooth = false;
        b.push(.{ .line = .{ @floatCast(x), @floatCast(y) } });
        b.cx = x;
        b.cy = y;
    }

    fn cubicTo(b: *Builder, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) void {
        b.push(.{ .cubic = .{ @floatCast(x1), @floatCast(y1), @floatCast(x2), @floatCast(y2), @floatCast(x), @floatCast(y) } });
        b.c2x = x2;
        b.c2y = y2;
        b.smooth = true;
        b.cx = x;
        b.cy = y;
    }

    fn arcTo(b: *Builder, rx_in: f64, ry_in: f64, rot: f64, large: bool, sweep: bool, x: f64, y: f64) void {
        if (rx_in == 0 or ry_in == 0) return b.lineTo(x, y);
        const phi = rot * std.math.pi / 180.0;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx = (b.cx - x) / 2;
        const dy = (b.cy - y) / 2;
        const x1p = cp * dx + sp * dy;
        const y1p = -sp * dx + cp * dy;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }
        const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
        const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
        const coef = (if (large == sweep) -1.0 else 1.0) * @sqrt(@max(0.0, num / den));
        const cxp = coef * (rx * y1p / ry);
        const cyp = coef * -(ry * x1p / rx);
        const ccx = cp * cxp - sp * cyp + (b.cx + x) / 2;
        const ccy = sp * cxp + cp * cyp + (b.cy + y) / 2;
        const t1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
        const t2 = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx);
        var dt = t2 - t1;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        const segs: usize = @intFromFloat(@ceil(@abs(dt) / (std.math.pi / 2.0) - 1e-9));
        const step = dt / @as(f64, @floatFromInt(segs));
        const k = 4.0 / 3.0 * @tan(step / 4.0);
        var a0 = t1;
        for (0..segs) |i| {
            const a1 = a0 + step;
            const ca0 = @cos(a0);
            const sa0 = @sin(a0);
            const ca1 = @cos(a1);
            const sa1 = @sin(a1);
            const px = [3][2]f64{ .{ ca0 - k * sa0, sa0 + k * ca0 }, .{ ca1 + k * sa1, sa1 - k * ca1 }, .{ ca1, sa1 } };
            var out: [3][2]f64 = undefined;
            for (px, 0..) |q, j| {
                out[j] = .{ ccx + rx * cp * q[0] - ry * sp * q[1], ccy + rx * sp * q[0] + ry * cp * q[1] };
            }
            if (i + 1 == segs) out[2] = .{ x, y };
            b.cubicTo(out[0][0], out[0][1], out[1][0], out[1][1], out[2][0], out[2][1]);
            a0 = a1;
        }
    }
};

fn isSep(c: u8) bool {
    return c == ' ' or c == ',';
}

fn number(comptime d: []const u8, i: *usize) f64 {
    while (i.* < d.len and isSep(d[i.*])) i.* += 1;
    var neg = false;
    if (d[i.*] == '-') {
        neg = true;
        i.* += 1;
    }
    var v: f64 = 0;
    while (i.* < d.len and d[i.*] >= '0' and d[i.*] <= '9') : (i.* += 1) v = v * 10 + @as(f64, @floatFromInt(d[i.*] - '0'));
    if (i.* < d.len and d[i.*] == '.') {
        i.* += 1;
        var scale: f64 = 0.1;
        while (i.* < d.len and d[i.*] >= '0' and d[i.*] <= '9') : (i.* += 1) {
            v += scale * @as(f64, @floatFromInt(d[i.*] - '0'));
            scale /= 10;
        }
    }
    return if (neg) -v else v;
}

fn flag(comptime d: []const u8, i: *usize) bool {
    while (i.* < d.len and isSep(d[i.*])) i.* += 1;
    const v = d[i.*] == '1';
    i.* += 1;
    return v;
}

fn build(comptime d: []const u8) Builder {
    @setEvalBranchQuota(400000);
    var b: Builder = .{};
    var i: usize = 0;
    var cmd: u8 = 0;
    while (true) {
        while (i < d.len and isSep(d[i])) i += 1;
        if (i >= d.len) break;
        if (std.ascii.isAlphabetic(d[i])) {
            cmd = d[i];
            i += 1;
            if (cmd == 'Z' or cmd == 'z') {
                b.push(.close);
                b.cx = b.sx;
                b.cy = b.sy;
                continue;
            }
        }
        const rel = cmd >= 'a';
        const ox = if (rel) b.cx else 0;
        const oy = if (rel) b.cy else 0;
        switch (cmd | 0x20) {
            'm' => {
                const x = number(d, &i);
                const y = number(d, &i);
                b.moveTo(ox + x, oy + y);
                cmd = if (rel) 'l' else 'L';
            },
            'l' => {
                const x = number(d, &i);
                const y = number(d, &i);
                b.lineTo(ox + x, oy + y);
            },
            'h' => b.lineTo(ox + number(d, &i), b.cy),
            'v' => b.lineTo(b.cx, oy + number(d, &i)),
            'c' => {
                const x1 = number(d, &i);
                const y1 = number(d, &i);
                const x2 = number(d, &i);
                const y2 = number(d, &i);
                const x = number(d, &i);
                const y = number(d, &i);
                b.cubicTo(ox + x1, oy + y1, ox + x2, oy + y2, ox + x, oy + y);
            },
            's' => {
                const x2 = number(d, &i);
                const y2 = number(d, &i);
                const x = number(d, &i);
                const y = number(d, &i);
                const x1 = if (b.smooth) 2 * b.cx - b.c2x else b.cx;
                const y1 = if (b.smooth) 2 * b.cy - b.c2y else b.cy;
                b.cubicTo(x1, y1, ox + x2, oy + y2, ox + x, oy + y);
            },
            'a' => {
                const rx = number(d, &i);
                const ry = number(d, &i);
                const rot = number(d, &i);
                const large = flag(d, &i);
                const sweep = flag(d, &i);
                const x = number(d, &i);
                const y = number(d, &i);
                b.arcTo(rx, ry, rot, large, sweep, ox + x, oy + y);
            },
            else => @compileError("unsupported path command"),
        }
    }
    return b;
}

fn ops(comptime a: md.Alert) []const Op {
    const b = comptime build(data[@intFromEnum(a) -| 1]);
    const out = b.ops[0..b.n].*;
    return &out;
}

pub fn icon(a: md.Alert) []const Op {
    return switch (a) {
        inline else => |k| ops(k),
    };
}

test "icons end where they start and stay on the grid" {
    for ([_]md.Alert{ .note, .tip, .important, .warning, .caution }) |a| {
        const o = icon(a);
        try std.testing.expect(o.len > 10);
        try std.testing.expect(o[0] == .move);
        try std.testing.expect(o[o.len - 1] == .close);
        for (o) |op| switch (op) {
            .move, .line => |p| try std.testing.expect(p[0] >= -0.01 and p[0] <= 16.01 and p[1] >= -0.01 and p[1] <= 16.01),
            .cubic => |c| try std.testing.expect(c[4] >= -0.01 and c[4] <= 16.01 and c[5] >= -0.01 and c[5] <= 16.01),
            .close => {},
        };
    }
    const info = icon(.note);
    try std.testing.expectEqual(@as(f32, 16), info[2].cubic[4]);
    try std.testing.expectEqual(@as(f32, 8), info[2].cubic[5]);
}
