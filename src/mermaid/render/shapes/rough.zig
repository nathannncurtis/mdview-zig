const std = @import("std");
const dom = @import("../dom.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;

pub const Error = Allocator.Error || error{BadPath};

/// Mermaid leaves handDrawnSeed at 0 (random per load); the references are drawn with this seed.
pub const default_seed: i32 = 1;

const pi = std.math.pi;
const P2 = [2]f64;
const arc_max: f64 = std.math.pi * @as(f64, 120) / @as(f64, 180);

pub const Rng = struct {
    seed: i32,

    pub fn next(self: *Rng) f64 {
        self.seed = self.seed *% 48271;
        return @as(f64, @floatFromInt(self.seed & 0x7fffffff)) / 2147483648.0;
    }
};

pub const Params = struct {
    roughness: f64 = 0,
    max_randomness_offset: f64 = 2,
    bowing: f64 = 1,
    curve_tightness: f64 = 0,
    curve_fitting: f64 = 0.95,
    curve_step_count: f64 = 9,
    disable_multi_stroke: bool = false,
    fill_shape_roughness_gain: f64 = 0.8,
};

pub const Kind = enum { move, line_to, bcurve };
pub const Op = struct { kind: Kind, d: [6]f64 = .{ 0, 0, 0, 0, 0, 0 } };
pub const Ops = std.ArrayList(Op);

pub const SetKind = enum { path, fill_path };
pub const Set = struct { kind: SetKind, ops: []const Op };

/// What rough.js draws as: the colours and stroke the paths carry.
pub const Style = struct {
    fill: ?[]const u8 = null,
    stroke: []const u8 = "",
    stroke_width: []const u8 = "1.3",
    dash: []const u8 = "0 0",
    seed: i32 = default_seed,
    params: Params = .{},
};

fn offset(r: *Rng, p: Params, min: f64, max: f64, gain: f64) f64 {
    return p.roughness * gain * ((r.next() * (max - min)) + min);
}

fn offsetOpt(r: *Rng, p: Params, x: f64, gain: f64) f64 {
    return offset(r, p, -x, x, gain);
}

fn line(a: Allocator, ops: *Ops, r: *Rng, p: Params, x1: f64, y1: f64, x2: f64, y2: f64, move: bool, overlay: bool) Allocator.Error!void {
    const length_sq = std.math.pow(f64, x1 - x2, 2) + std.math.pow(f64, y1 - y2, 2);
    const length = @sqrt(length_sq);
    var gain: f64 = 1;
    if (length < 200) {
        gain = 1;
    } else if (length > 500) {
        gain = 0.4;
    } else {
        gain = (-0.0016668) * length + 1.233334;
    }
    var off = p.max_randomness_offset;
    if (off * off * 100 > length_sq) off = length / 10;
    const half = off / 2;
    const diverge = 0.2 + r.next() * 0.2;
    var mid_x = p.bowing * p.max_randomness_offset * (y2 - y1) / 200;
    var mid_y = p.bowing * p.max_randomness_offset * (x1 - x2) / 200;
    mid_x = offsetOpt(r, p, mid_x, gain);
    mid_y = offsetOpt(r, p, mid_y, gain);
    if (move) {
        const o: f64 = if (overlay) half else off;
        const mx = x1 + offsetOpt(r, p, o, gain);
        const my = y1 + offsetOpt(r, p, o, gain);
        try ops.append(a, .{ .kind = .move, .d = .{ mx, my, 0, 0, 0, 0 } });
    }
    const o: f64 = if (overlay) half else off;
    var d: [6]f64 = undefined;
    d[0] = mid_x + x1 + (x2 - x1) * diverge + offsetOpt(r, p, o, gain);
    d[1] = mid_y + y1 + (y2 - y1) * diverge + offsetOpt(r, p, o, gain);
    d[2] = mid_x + x1 + 2 * (x2 - x1) * diverge + offsetOpt(r, p, o, gain);
    d[3] = mid_y + y1 + 2 * (y2 - y1) * diverge + offsetOpt(r, p, o, gain);
    d[4] = x2 + offsetOpt(r, p, o, gain);
    d[5] = y2 + offsetOpt(r, p, o, gain);
    try ops.append(a, .{ .kind = .bcurve, .d = d });
}

fn doubleLine(a: Allocator, ops: *Ops, r: *Rng, p: Params, x1: f64, y1: f64, x2: f64, y2: f64) Allocator.Error!void {
    try line(a, ops, r, p, x1, y1, x2, y2, true, false);
    if (p.disable_multi_stroke) return;
    try line(a, ops, r, p, x1, y1, x2, y2, true, true);
}

fn bezierTo(a: Allocator, ops: *Ops, r: *Rng, p: Params, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64, cur: P2) Allocator.Error!void {
    const base = if (p.max_randomness_offset != 0) p.max_randomness_offset else 1;
    const ros = [2]f64{ base, base + 0.3 };
    const iterations: usize = if (p.disable_multi_stroke) 1 else 2;
    for (0..iterations) |i| {
        if (i == 0) {
            try ops.append(a, .{ .kind = .move, .d = .{ cur[0], cur[1], 0, 0, 0, 0 } });
        } else {
            const mx = cur[0] + offsetOpt(r, p, ros[0], 1);
            const my = cur[1] + offsetOpt(r, p, ros[0], 1);
            try ops.append(a, .{ .kind = .move, .d = .{ mx, my, 0, 0, 0, 0 } });
        }
        const fx = x + offsetOpt(r, p, ros[i], 1);
        const fy = y + offsetOpt(r, p, ros[i], 1);
        var d: [6]f64 = undefined;
        d[0] = x1 + offsetOpt(r, p, ros[i], 1);
        d[1] = y1 + offsetOpt(r, p, ros[i], 1);
        d[2] = x2 + offsetOpt(r, p, ros[i], 1);
        d[3] = y2 + offsetOpt(r, p, ros[i], 1);
        d[4] = fx;
        d[5] = fy;
        try ops.append(a, .{ .kind = .bcurve, .d = d });
    }
}

pub const Seg = struct { key: u8, data: [7]f64 = .{ 0, 0, 0, 0, 0, 0, 0 } };

const Token = union(enum) { cmd: u8, num: f64, eod };

fn paramCount(c: u8) usize {
    return switch (c) {
        'A', 'a' => 7,
        'C', 'c' => 6,
        'H', 'h', 'V', 'v' => 1,
        'L', 'l', 'M', 'm', 'T', 't' => 2,
        'Q', 'q', 'S', 's' => 4,
        else => 0,
    };
}

fn tokenize(a: Allocator, d: []const u8) Error![]Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < d.len) {
        const c = d[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',') {
            i += 1;
        } else if (std.mem.indexOfScalar(u8, "aAcChHlLmMqQsStTvVzZ", c) != null) {
            try out.append(a, .{ .cmd = c });
            i += 1;
        } else {
            var j = i;
            if (j < d.len and (d[j] == '-' or d[j] == '+')) j += 1;
            const ds = j;
            while (j < d.len and std.ascii.isDigit(d[j])) j += 1;
            var digits = j - ds;
            if (j < d.len and d[j] == '.') {
                j += 1;
                const fs = j;
                while (j < d.len and std.ascii.isDigit(d[j])) j += 1;
                digits += j - fs;
            }
            if (digits == 0) return error.BadPath;
            if (j < d.len and (d[j] == 'e' or d[j] == 'E')) {
                var k = j + 1;
                if (k < d.len and (d[k] == '-' or d[k] == '+')) k += 1;
                const es = k;
                while (k < d.len and std.ascii.isDigit(d[k])) k += 1;
                if (k > es) j = k;
            }
            const v = std.fmt.parseFloat(f64, d[i..j]) catch return error.BadPath;
            try out.append(a, .{ .num = v });
            i = j;
        }
    }
    try out.append(a, .eod);
    return out.items;
}

fn parsePath(a: Allocator, d_in: []const u8) Error![]Seg {
    var d = d_in;
    var tokens = try tokenize(a, d);
    var mode: u8 = 0;
    var index: usize = 0;
    var segs: std.ArrayList(Seg) = .empty;
    if (tokens.len > 0 and tokens[0] != .eod and !(tokens[0] == .cmd and (tokens[0].cmd == 'M' or tokens[0].cmd == 'm'))) {
        d = try std.fmt.allocPrint(a, "M0,0{s}", .{d_in});
        tokens = try tokenize(a, d);
    }
    while (tokens[index] != .eod) {
        var count: usize = 0;
        switch (tokens[index]) {
            .num => count = paramCount(mode),
            .cmd => |c| {
                index += 1;
                count = paramCount(c);
                mode = c;
            },
            .eod => unreachable,
        }
        if (mode == 0) return error.BadPath;
        if (index + count >= tokens.len) return error.BadPath;
        var seg = Seg{ .key = mode };
        for (0..count) |k| switch (tokens[index + k]) {
            .num => |v| seg.data[k] = v,
            else => return error.BadPath,
        };
        try segs.append(a, seg);
        index += count;
        if (mode == 'M') mode = 'L';
        if (mode == 'm') mode = 'l';
        if (count == 0 and tokens[index] == .num) return error.BadPath;
    }
    return segs.items;
}

fn absolutize(a: Allocator, segs: []const Seg) Allocator.Error![]Seg {
    var out: std.ArrayList(Seg) = .empty;
    var cx: f64 = 0;
    var cy: f64 = 0;
    var subx: f64 = 0;
    var suby: f64 = 0;
    for (segs) |s| {
        const d = s.data;
        switch (s.key) {
            'M' => {
                try out.append(a, s);
                cx = d[0];
                cy = d[1];
                subx = cx;
                suby = cy;
            },
            'm' => {
                cx += d[0];
                cy += d[1];
                try out.append(a, .{ .key = 'M', .data = .{ cx, cy, 0, 0, 0, 0, 0 } });
                subx = cx;
                suby = cy;
            },
            'L' => {
                try out.append(a, s);
                cx = d[0];
                cy = d[1];
            },
            'l' => {
                cx += d[0];
                cy += d[1];
                try out.append(a, .{ .key = 'L', .data = .{ cx, cy, 0, 0, 0, 0, 0 } });
            },
            'C', 'c' => {
                var n = d;
                if (s.key == 'c') for (0..6) |i| {
                    n[i] = d[i] + if (i % 2 == 1) cy else cx;
                };
                try out.append(a, .{ .key = 'C', .data = n });
                cx = n[4];
                cy = n[5];
            },
            'Q', 'q', 'S', 's' => {
                var n = d;
                const up: u8 = std.ascii.toUpper(s.key);
                if (s.key >= 'a') for (0..4) |i| {
                    n[i] = d[i] + if (i % 2 == 1) cy else cx;
                };
                try out.append(a, .{ .key = up, .data = n });
                cx = n[2];
                cy = n[3];
            },
            'A' => {
                try out.append(a, s);
                cx = d[5];
                cy = d[6];
            },
            'a' => {
                cx += d[5];
                cy += d[6];
                try out.append(a, .{ .key = 'A', .data = .{ d[0], d[1], d[2], d[3], d[4], cx, cy } });
            },
            'H' => {
                try out.append(a, s);
                cx = d[0];
            },
            'h' => {
                cx += d[0];
                try out.append(a, .{ .key = 'H', .data = .{ cx, 0, 0, 0, 0, 0, 0 } });
            },
            'V' => {
                try out.append(a, s);
                cy = d[0];
            },
            'v' => {
                cy += d[0];
                try out.append(a, .{ .key = 'V', .data = .{ cy, 0, 0, 0, 0, 0, 0 } });
            },
            'T' => {
                try out.append(a, s);
                cx = d[0];
                cy = d[1];
            },
            't' => {
                cx += d[0];
                cy += d[1];
                try out.append(a, .{ .key = 'T', .data = .{ cx, cy, 0, 0, 0, 0, 0 } });
            },
            'Z', 'z' => {
                try out.append(a, .{ .key = 'Z' });
                cx = subx;
                cy = suby;
            },
            else => {},
        }
    }
    return out.items;
}

fn rotate(x: f64, y: f64, ang: f64) P2 {
    return .{ x * @cos(ang) - y * @sin(ang), x * @sin(ang) + y * @cos(ang) };
}

fn toFixed9(v: f64) f64 {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.9}", .{v}) catch return v;
    return std.fmt.parseFloat(f64, s) catch v;
}

const Arc = struct { f1: f64, f2: f64, cx: f64, cy: f64 };

fn arcToCubicCurves(a: Allocator, out: *std.ArrayList([6]f64), x1_in: f64, y1_in: f64, x2_in: f64, y2_in: f64, r1_in: f64, r2_in: f64, angle: f64, large: f64, sweep: f64, recursive: ?Arc) Allocator.Error!void {
    const ang_rad = pi * angle / 180.0;
    var x1 = x1_in;
    var y1 = y1_in;
    var x2 = x2_in;
    var y2 = y2_in;
    var r1 = r1_in;
    var r2 = r2_in;
    var f1: f64 = 0;
    var f2: f64 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    if (recursive) |rc| {
        f1 = rc.f1;
        f2 = rc.f2;
        cx = rc.cx;
        cy = rc.cy;
    } else {
        const p1 = rotate(x1, y1, -ang_rad);
        x1 = p1[0];
        y1 = p1[1];
        const p2 = rotate(x2, y2, -ang_rad);
        x2 = p2[0];
        y2 = p2[1];
        const x = (x1 - x2) / 2;
        const y = (y1 - y2) / 2;
        var h = (x * x) / (r1 * r1) + (y * y) / (r2 * r2);
        if (h > 1) {
            h = @sqrt(h);
            r1 = h * r1;
            r2 = h * r2;
        }
        const sign: f64 = if (large == sweep) -1 else 1;
        const r1p = r1 * r1;
        const r2p = r2 * r2;
        const left = r1p * r2p - r1p * y * y - r2p * x * x;
        const right = r1p * y * y + r2p * x * x;
        const k = sign * @sqrt(@abs(left / right));
        cx = k * r1 * y / r2 + (x1 + x2) / 2;
        cy = k * -r2 * x / r1 + (y1 + y2) / 2;
        f1 = std.math.asin(toFixed9((y1 - cy) / r2));
        f2 = std.math.asin(toFixed9((y2 - cy) / r2));
        if (x1 < cx) f1 = pi - f1;
        if (x2 < cx) f2 = pi - f2;
        if (f1 < 0) f1 = pi * 2 + f1;
        if (f2 < 0) f2 = pi * 2 + f2;
        if (sweep != 0 and f1 > f2) f1 = f1 - pi * 2;
        if (sweep == 0 and f2 > f1) f2 = f2 - pi * 2;
    }
    var df = f2 - f1;
    var tail: std.ArrayList(P2) = .empty;
    if (@abs(df) > arc_max) {
        const f2old = f2;
        const x2old = x2;
        const y2old = y2;
        if (sweep != 0 and f2 > f1) {
            f2 = f1 + (arc_max) * 1;
        } else {
            f2 = f1 + (arc_max) * -1;
        }
        x2 = cx + r1 * @cos(f2);
        y2 = cy + r2 * @sin(f2);
        var rest: std.ArrayList([6]f64) = .empty;
        try arcToCubicCurves(a, &rest, x2, y2, x2old, y2old, r1, r2, angle, 0, sweep, .{ .f1 = f2, .f2 = f2old, .cx = cx, .cy = cy });
        for (rest.items) |c| {
            try tail.append(a, .{ c[0], c[1] });
            try tail.append(a, .{ c[2], c[3] });
            try tail.append(a, .{ c[4], c[5] });
        }
    }
    df = f2 - f1;
    const c1 = @cos(f1);
    const s1 = @sin(f1);
    const c2 = @cos(f2);
    const s2 = @sin(f2);
    const t = @tan(df / 4);
    const hx = 4.0 / 3.0 * r1 * t;
    const hy = 4.0 / 3.0 * r2 * t;
    const m1 = P2{ x1, y1 };
    var m2 = P2{ x1 + hx * s1, y1 - hy * c1 };
    const m3 = P2{ x2 + hx * s2, y2 - hy * c2 };
    const m4 = P2{ x2, y2 };
    m2[0] = 2 * m1[0] - m2[0];
    m2[1] = 2 * m1[1] - m2[1];
    var params: std.ArrayList(P2) = .empty;
    try params.appendSlice(a, &.{ m2, m3, m4 });
    try params.appendSlice(a, tail.items);
    if (recursive != null) {
        for (0..params.items.len / 3) |i| {
            const q = params.items[i * 3 ..][0..3];
            try out.append(a, .{ q[0][0], q[0][1], q[1][0], q[1][1], q[2][0], q[2][1] });
        }
        return;
    }
    for (0..params.items.len / 3) |i| {
        const q = params.items[i * 3 ..][0..3];
        const q1 = rotate(q[0][0], q[0][1], ang_rad);
        const q2 = rotate(q[1][0], q[1][1], ang_rad);
        const q3 = rotate(q[2][0], q[2][1], ang_rad);
        try out.append(a, .{ q1[0], q1[1], q2[0], q2[1], q3[0], q3[1] });
    }
}

fn normalize(a: Allocator, segs: []const Seg) Allocator.Error![]Seg {
    var out: std.ArrayList(Seg) = .empty;
    var last: u8 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    var subx: f64 = 0;
    var suby: f64 = 0;
    var lcx: f64 = 0;
    var lcy: f64 = 0;
    for (segs) |s| {
        const d = s.data;
        switch (s.key) {
            'M' => {
                try out.append(a, s);
                cx = d[0];
                cy = d[1];
                subx = cx;
                suby = cy;
            },
            'C' => {
                try out.append(a, s);
                cx = d[4];
                cy = d[5];
                lcx = d[2];
                lcy = d[3];
            },
            'L' => {
                try out.append(a, s);
                cx = d[0];
                cy = d[1];
            },
            'H' => {
                cx = d[0];
                try out.append(a, .{ .key = 'L', .data = .{ cx, cy, 0, 0, 0, 0, 0 } });
            },
            'V' => {
                cy = d[0];
                try out.append(a, .{ .key = 'L', .data = .{ cx, cy, 0, 0, 0, 0, 0 } });
            },
            'S' => {
                var cx1: f64 = cx;
                var cy1: f64 = cy;
                if (last == 'C' or last == 'S') {
                    cx1 = cx + (cx - lcx);
                    cy1 = cy + (cy - lcy);
                }
                try out.append(a, .{ .key = 'C', .data = .{ cx1, cy1, d[0], d[1], d[2], d[3], 0 } });
                lcx = d[0];
                lcy = d[1];
                cx = d[2];
                cy = d[3];
            },
            'T' => {
                const x = d[0];
                const y = d[1];
                var x1: f64 = cx;
                var y1: f64 = cy;
                if (last == 'Q' or last == 'T') {
                    x1 = cx + (cx - lcx);
                    y1 = cy + (cy - lcy);
                }
                const cx1 = cx + 2 * (x1 - cx) / 3;
                const cy1 = cy + 2 * (y1 - cy) / 3;
                const cx2 = x + 2 * (x1 - x) / 3;
                const cy2 = y + 2 * (y1 - y) / 3;
                try out.append(a, .{ .key = 'C', .data = .{ cx1, cy1, cx2, cy2, x, y, 0 } });
                lcx = x1;
                lcy = y1;
                cx = x;
                cy = y;
            },
            'Q' => {
                const x1 = d[0];
                const y1 = d[1];
                const x = d[2];
                const y = d[3];
                const cx1 = cx + 2 * (x1 - cx) / 3;
                const cy1 = cy + 2 * (y1 - cy) / 3;
                const cx2 = x + 2 * (x1 - x) / 3;
                const cy2 = y + 2 * (y1 - y) / 3;
                try out.append(a, .{ .key = 'C', .data = .{ cx1, cy1, cx2, cy2, x, y, 0 } });
                lcx = x1;
                lcy = y1;
                cx = x;
                cy = y;
            },
            'A' => {
                const r1 = @abs(d[0]);
                const r2 = @abs(d[1]);
                const x = d[5];
                const y = d[6];
                if (r1 == 0 or r2 == 0) {
                    try out.append(a, .{ .key = 'C', .data = .{ cx, cy, x, y, x, y, 0 } });
                    cx = x;
                    cy = y;
                } else if (cx != x or cy != y) {
                    var curves: std.ArrayList([6]f64) = .empty;
                    try arcToCubicCurves(a, &curves, cx, cy, x, y, r1, r2, d[2], d[3], d[4], null);
                    for (curves.items) |c| try out.append(a, .{ .key = 'C', .data = .{ c[0], c[1], c[2], c[3], c[4], c[5], 0 } });
                    cx = x;
                    cy = y;
                }
            },
            'Z' => {
                try out.append(a, .{ .key = 'Z' });
                cx = subx;
                cy = suby;
            },
            else => {},
        }
        last = s.key;
    }
    return out.items;
}

fn normalized(a: Allocator, d: []const u8) Error![]Seg {
    return normalize(a, try absolutize(a, try parsePath(a, d)));
}

fn svgPathOps(a: Allocator, segs: []const Seg, r: *Rng, p: Params) Allocator.Error![]const Op {
    var ops: Ops = .empty;
    var first = P2{ 0, 0 };
    var cur = P2{ 0, 0 };
    for (segs) |s| {
        const d = s.data;
        switch (s.key) {
            'M' => {
                cur = .{ d[0], d[1] };
                first = cur;
            },
            'L' => {
                try doubleLine(a, &ops, r, p, cur[0], cur[1], d[0], d[1]);
                cur = .{ d[0], d[1] };
            },
            'C' => {
                try bezierTo(a, &ops, r, p, d[0], d[1], d[2], d[3], d[4], d[5], cur);
                cur = .{ d[4], d[5] };
            },
            'Z' => {
                try doubleLine(a, &ops, r, p, cur[0], cur[1], first[0], first[1]);
                cur = first;
            },
            else => {},
        }
    }
    return ops.items;
}

fn mergedShape(a: Allocator, ops: []const Op) Allocator.Error![]const Op {
    var out: Ops = .empty;
    for (ops, 0..) |o, i| if (i == 0 or o.kind != .move) try out.append(a, o);
    return out.items;
}

fn solidFillPolygon(a: Allocator, lists: []const []const P2, r: *Rng, p: Params) Allocator.Error!Set {
    var ops: Ops = .empty;
    for (lists) |pts| {
        if (pts.len > 2) {
            const off = p.max_randomness_offset;
            const mx = pts[0][0] + offsetOpt(r, p, off, 1);
            const my = pts[0][1] + offsetOpt(r, p, off, 1);
            try ops.append(a, .{ .kind = .move, .d = .{ mx, my, 0, 0, 0, 0 } });
            for (pts[1..]) |q| {
                const lx = q[0] + offsetOpt(r, p, off, 1);
                const ly = q[1] + offsetOpt(r, p, off, 1);
                try ops.append(a, .{ .kind = .line_to, .d = .{ lx, ly, 0, 0, 0, 0 } });
            }
        }
    }
    return .{ .kind = .fill_path, .ops = ops.items };
}

fn lerp(p: P2, q: P2, t: f64) P2 {
    return .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
}

fn dist(p: P2, q: P2) f64 {
    return @sqrt(std.math.pow(f64, p[0] - q[0], 2) + std.math.pow(f64, p[1] - q[1], 2));
}

fn flatness(pts: []const P2, off: usize) f64 {
    const p1 = pts[off];
    const p2 = pts[off + 1];
    const p3 = pts[off + 2];
    const p4 = pts[off + 3];
    var ux = 3 * p2[0] - 2 * p1[0] - p4[0];
    ux *= ux;
    var uy = 3 * p2[1] - 2 * p1[1] - p4[1];
    uy *= uy;
    var vx = 3 * p3[0] - 2 * p4[0] - p1[0];
    vx *= vx;
    var vy = 3 * p3[1] - 2 * p4[1] - p1[1];
    vy *= vy;
    if (ux < vx) ux = vx;
    if (uy < vy) uy = vy;
    return ux + uy;
}

fn bezierSplit(a: Allocator, pts: []const P2, off: usize, tol: f64, out: *std.ArrayList(P2)) Allocator.Error!void {
    if (flatness(pts, off) < tol) {
        const p0 = pts[off];
        if (out.items.len > 0) {
            if (dist(out.items[out.items.len - 1], p0) > 1) try out.append(a, p0);
        } else try out.append(a, p0);
        try out.append(a, pts[off + 3]);
        return;
    }
    const p1 = pts[off];
    const p2 = pts[off + 1];
    const p3 = pts[off + 2];
    const p4 = pts[off + 3];
    const q1 = lerp(p1, p2, 0.5);
    const q2 = lerp(p2, p3, 0.5);
    const q3 = lerp(p3, p4, 0.5);
    const r1 = lerp(q1, q2, 0.5);
    const r2 = lerp(q2, q3, 0.5);
    const red = lerp(r1, r2, 0.5);
    try bezierSplit(a, &.{ p1, q1, r1, red }, 0, tol, out);
    try bezierSplit(a, &.{ red, r2, q3, p4 }, 0, tol, out);
}

fn distToSegSq(p: P2, v: P2, w: P2) f64 {
    const l2 = std.math.pow(f64, v[0] - w[0], 2) + std.math.pow(f64, v[1] - w[1], 2);
    if (l2 == 0) return std.math.pow(f64, p[0] - v[0], 2) + std.math.pow(f64, p[1] - v[1], 2);
    var t = ((p[0] - v[0]) * (w[0] - v[0]) + (p[1] - v[1]) * (w[1] - v[1])) / l2;
    t = @max(0, @min(1, t));
    const q = lerp(v, w, t);
    return std.math.pow(f64, p[0] - q[0], 2) + std.math.pow(f64, p[1] - q[1], 2);
}

fn simplifyPoints(a: Allocator, pts: []const P2, start: usize, end: usize, eps: f64, out: *std.ArrayList(P2)) Allocator.Error!void {
    const s = pts[start];
    const e = pts[end - 1];
    var max_sq: f64 = 0;
    var max_ndx: usize = 1;
    var i = start + 1;
    while (i + 1 < end) : (i += 1) {
        const dsq = distToSegSq(pts[i], s, e);
        if (dsq > max_sq) {
            max_sq = dsq;
            max_ndx = i;
        }
    }
    if (@sqrt(max_sq) > eps) {
        try simplifyPoints(a, pts, start, max_ndx + 1, eps, out);
        try simplifyPoints(a, pts, max_ndx, end, eps, out);
    } else {
        if (out.items.len == 0) try out.append(a, s);
        try out.append(a, e);
    }
}

fn pointsOnPath(a: Allocator, segs: []const Seg, tol: f64, distance: f64) Allocator.Error![]const []const P2 {
    var sets: std.ArrayList([]const P2) = .empty;
    var current: std.ArrayList(P2) = .empty;
    var pending: std.ArrayList(P2) = .empty;
    var start = P2{ 0, 0 };
    for (segs) |s| {
        const d = s.data;
        switch (s.key) {
            'M' => {
                try flushCurve(a, &pending, &current, tol);
                if (current.items.len > 0) {
                    try sets.append(a, current.items);
                    current = .empty;
                }
                start = .{ d[0], d[1] };
                try current.append(a, start);
            },
            'L' => {
                try flushCurve(a, &pending, &current, tol);
                try current.append(a, .{ d[0], d[1] });
            },
            'C' => {
                if (pending.items.len == 0) try pending.append(a, if (current.items.len > 0) current.items[current.items.len - 1] else start);
                try pending.append(a, .{ d[0], d[1] });
                try pending.append(a, .{ d[2], d[3] });
                try pending.append(a, .{ d[4], d[5] });
            },
            'Z' => {
                try flushCurve(a, &pending, &current, tol);
                try current.append(a, start);
            },
            else => {},
        }
    }
    try flushCurve(a, &pending, &current, tol);
    if (current.items.len > 0) try sets.append(a, current.items);
    var out: std.ArrayList([]const P2) = .empty;
    for (sets.items) |set| {
        var simp: std.ArrayList(P2) = .empty;
        try simplifyPoints(a, set, 0, set.len, distance, &simp);
        if (simp.items.len > 0) try out.append(a, simp.items);
    }
    return out.items;
}

fn flushCurve(a: Allocator, pending: *std.ArrayList(P2), current: *std.ArrayList(P2), tol: f64) Allocator.Error!void {
    if (pending.items.len >= 4) {
        const nseg = (pending.items.len - 1) / 3;
        for (0..nseg) |i| try bezierSplit(a, pending.items, i * 3, tol, current);
    }
    pending.* = .empty;
}

fn linearPathOps(a: Allocator, pts: []const P2, close: bool, r: *Rng, p: Params) Allocator.Error!Set {
    var ops: Ops = .empty;
    const n = pts.len;
    if (n > 2) {
        for (0..n - 1) |i| try doubleLine(a, &ops, r, p, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]);
        if (close) try doubleLine(a, &ops, r, p, pts[n - 1][0], pts[n - 1][1], pts[0][0], pts[0][1]);
    } else if (n == 2) {
        try doubleLine(a, &ops, r, p, pts[0][0], pts[0][1], pts[1][0], pts[1][1]);
    }
    return .{ .kind = .path, .ops = ops.items };
}

fn curveOps(a: Allocator, pts: []const P2, p: Params, ops: *Ops) Allocator.Error!void {
    const len = pts.len;
    if (len > 3) {
        const s = 1 - p.curve_tightness;
        try ops.append(a, .{ .kind = .move, .d = .{ pts[1][0], pts[1][1], 0, 0, 0, 0 } });
        var i: usize = 1;
        while (i + 2 < len) : (i += 1) {
            const c = pts[i];
            const b1 = P2{ c[0] + (s * pts[i + 1][0] - s * pts[i - 1][0]) / 6, c[1] + (s * pts[i + 1][1] - s * pts[i - 1][1]) / 6 };
            const b2 = P2{ pts[i + 1][0] + (s * pts[i][0] - s * pts[i + 2][0]) / 6, pts[i + 1][1] + (s * pts[i][1] - s * pts[i + 2][1]) / 6 };
            try ops.append(a, .{ .kind = .bcurve, .d = .{ b1[0], b1[1], b2[0], b2[1], pts[i + 1][0], pts[i + 1][1] } });
        }
    } else if (len == 3) {
        try ops.append(a, .{ .kind = .move, .d = .{ pts[1][0], pts[1][1], 0, 0, 0, 0 } });
        try ops.append(a, .{ .kind = .bcurve, .d = .{ pts[1][0], pts[1][1], pts[2][0], pts[2][1], pts[2][0], pts[2][1] } });
    }
}

const EllipseParams = struct { increment: f64, rx: f64, ry: f64 };

fn ellipseParams(w: f64, h: f64, r: *Rng, p: Params) EllipseParams {
    const psq = @sqrt(pi * 2 * @sqrt((std.math.pow(f64, w / 2, 2) + std.math.pow(f64, h / 2, 2)) / 2));
    const step_count = @ceil(@max(p.curve_step_count, (p.curve_step_count / @sqrt(@as(f64, 200))) * psq));
    const increment = (pi * 2) / step_count;
    var rx = @abs(w / 2);
    var ry = @abs(h / 2);
    const rnd = 1 - p.curve_fitting;
    rx += offsetOpt(r, p, rx * rnd, 1);
    ry += offsetOpt(r, p, ry * rnd, 1);
    return .{ .increment = increment, .rx = rx, .ry = ry };
}

fn ellipsePoints(a: Allocator, inc_in: f64, cx: f64, cy: f64, rx: f64, ry: f64, off: f64, overlap: f64, r: *Rng, p: Params) Allocator.Error![]const P2 {
    var all: std.ArrayList(P2) = .empty;
    var inc = inc_in;
    if (p.roughness == 0) {
        inc = inc / 4;
        try all.append(a, .{ cx + rx * @cos(-inc), cy + ry * @sin(-inc) });
        var angle: f64 = 0;
        while (angle <= pi * 2) : (angle = angle + inc) try all.append(a, .{ cx + rx * @cos(angle), cy + ry * @sin(angle) });
        try all.append(a, .{ cx + rx * @cos(@as(f64, 0)), cy + ry * @sin(@as(f64, 0)) });
        try all.append(a, .{ cx + rx * @cos(inc), cy + ry * @sin(inc) });
    } else {
        const rad_off = offsetOpt(r, p, 0.5, 1) - (pi / 2.0);
        const f0 = offsetOpt(r, p, off, 1) + cx + 0.9 * rx * @cos(rad_off - inc);
        const f1 = offsetOpt(r, p, off, 1) + cy + 0.9 * ry * @sin(rad_off - inc);
        try all.append(a, .{ f0, f1 });
        const end_angle = pi * 2 + rad_off - 0.01;
        var angle = rad_off;
        while (angle < end_angle) : (angle = angle + inc) {
            const x = offsetOpt(r, p, off, 1) + cx + rx * @cos(angle);
            const y = offsetOpt(r, p, off, 1) + cy + ry * @sin(angle);
            try all.append(a, .{ x, y });
        }
        const e1x = offsetOpt(r, p, off, 1) + cx + rx * @cos(rad_off + pi * 2 + overlap * 0.5);
        const e1y = offsetOpt(r, p, off, 1) + cy + ry * @sin(rad_off + pi * 2 + overlap * 0.5);
        try all.append(a, .{ e1x, e1y });
        const e2x = offsetOpt(r, p, off, 1) + cx + 0.98 * rx * @cos(rad_off + overlap);
        const e2y = offsetOpt(r, p, off, 1) + cy + 0.98 * ry * @sin(rad_off + overlap);
        try all.append(a, .{ e2x, e2y });
        const e3x = offsetOpt(r, p, off, 1) + cx + 0.9 * rx * @cos(rad_off + overlap * 0.5);
        const e3y = offsetOpt(r, p, off, 1) + cy + 0.9 * ry * @sin(rad_off + overlap * 0.5);
        try all.append(a, .{ e3x, e3y });
    }
    return all.items;
}

fn ellipseOps(a: Allocator, x: f64, y: f64, ep: EllipseParams, r: *Rng, p: Params) Allocator.Error![]const Op {
    const ov = ep.increment * offset(r, p, 0.1, offset(r, p, 0.4, 1, 1), 1);
    var ops: Ops = .empty;
    try curveOps(a, try ellipsePoints(a, ep.increment, x, y, ep.rx, ep.ry, 1, ov, r, p), p, &ops);
    if (!p.disable_multi_stroke and p.roughness != 0) {
        try curveOps(a, try ellipsePoints(a, ep.increment, x, y, ep.rx, ep.ry, 1.5, 0, r, p), p, &ops);
    }
    return ops.items;
}

pub const Shape = enum { path, polygon, rectangle, ellipse };

pub const Drawing = struct { shape: Shape, sets: []const Set };

/// rough.path with a solid fill.
pub fn path(a: Allocator, d_in: []const u8, st: Style) Error!Drawing {
    var r = Rng{ .seed = st.seed };
    const p = st.params;
    const d = try std.mem.replaceOwned(u8, a, d_in, "\n", " ");
    const segs = try normalized(a, d);
    const sets = try pointsOnPath(a, segs, 1, (1 + p.roughness) / 2);
    const shape_ops = try svgPathOps(a, segs, &r, p);
    var out: std.ArrayList(Set) = .empty;
    const has_fill = if (st.fill) |f| f.len > 0 and !std.mem.eql(u8, f, "transparent") and !std.mem.eql(u8, f, "none") else false;
    if (has_fill) {
        if (sets.len == 1) {
            var fp = p;
            fp.disable_multi_stroke = true;
            fp.roughness = if (p.roughness != 0) p.roughness + p.fill_shape_roughness_gain else 0;
            const fill_ops = try svgPathOps(a, segs, &r, fp);
            try out.append(a, .{ .kind = .fill_path, .ops = try mergedShape(a, fill_ops) });
        } else {
            try out.append(a, try solidFillPolygon(a, sets, &r, p));
        }
    }
    try out.append(a, .{ .kind = .path, .ops = shape_ops });
    return .{ .shape = .path, .sets = out.items };
}

pub fn polygon(a: Allocator, pts: []const P2, st: Style) Error!Drawing {
    var r = Rng{ .seed = st.seed };
    const p = st.params;
    const outline = try linearPathOps(a, pts, true, &r, p);
    var out: std.ArrayList(Set) = .empty;
    if (st.fill != null) try out.append(a, try solidFillPolygon(a, &.{pts}, &r, p));
    try out.append(a, outline);
    return .{ .shape = .polygon, .sets = out.items };
}

pub fn rectangle(a: Allocator, x: f64, y: f64, w: f64, h: f64, st: Style) Error!Drawing {
    const pts = try a.dupe(P2, &.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } });
    var d = try polygon(a, pts, st);
    d.shape = .rectangle;
    return d;
}

pub fn circle(a: Allocator, x: f64, y: f64, diameter: f64, st: Style) Error!Drawing {
    var r = Rng{ .seed = st.seed };
    const p = st.params;
    const ep = ellipseParams(diameter, diameter, &r, p);
    const outline = try ellipseOps(a, x, y, ep, &r, p);
    var out: std.ArrayList(Set) = .empty;
    if (st.fill != null) try out.append(a, .{ .kind = .fill_path, .ops = try ellipseOps(a, x, y, ep, &r, p) });
    try out.append(a, .{ .kind = .path, .ops = outline });
    return .{ .shape = .ellipse, .sets = out.items };
}

pub fn jsNum(a: Allocator, v: f64) Allocator.Error![]const u8 {
    if (v == 0) return "0";
    const m = @abs(v);
    if (m < 1e-6 or m >= 1e21) return std.fmt.allocPrint(a, "{e}", .{v});
    return std.fmt.allocPrint(a, "{d}", .{v});
}

pub fn opsToPath(a: Allocator, ops: []const Op) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ops) |o| {
        const d = o.d;
        switch (o.kind) {
            .move => try out.print(a, "M{s} {s} ", .{ try jsNum(a, d[0]), try jsNum(a, d[1]) }),
            .line_to => try out.print(a, "L{s} {s} ", .{ try jsNum(a, d[0]), try jsNum(a, d[1]) }),
            .bcurve => try out.print(a, "C{s} {s}, {s} {s}, {s} {s} ", .{ try jsNum(a, d[0]), try jsNum(a, d[1]), try jsNum(a, d[2]), try jsNum(a, d[3]), try jsNum(a, d[4]), try jsNum(a, d[5]) }),
        }
    }
    return std.mem.trim(u8, out.items, " ");
}

/// Builds the `<g>` rough.js's svg draw() makes: one path per set, fills as fillPath, outlines as stroked paths.
pub fn draw(a: Allocator, dr: Drawing, st: Style) Error!*El {
    const g = try El.create(a, "g");
    for (dr.sets) |s| {
        const p = try g.insert("path");
        try p.setAttr("d", try opsToPath(a, s.ops));
        switch (s.kind) {
            .path => {
                try p.setAttr("stroke", st.stroke);
                try p.setAttr("stroke-width", st.stroke_width);
                try p.setAttr("fill", "none");
                try p.setAttr("stroke-dasharray", st.dash);
            },
            .fill_path => {
                try p.setAttr("stroke", "none");
                try p.setAttr("stroke-width", "0");
                try p.setAttr("fill", st.fill orelse "");
                if (dr.shape == .polygon) try p.setAttr("fill-rule", "evenodd");
            },
        }
    }
    return g;
}

pub fn polygonG(a: Allocator, pts: []const P2, st: Style) Error!*El {
    return draw(a, try polygon(a, pts, st), st);
}

pub fn rectangleG(a: Allocator, x: f64, y: f64, w: f64, h: f64, st: Style) Error!*El {
    return draw(a, try rectangle(a, x, y, w, h, st), st);
}

pub fn circleG(a: Allocator, x: f64, y: f64, diameter: f64, st: Style) Error!*El {
    return draw(a, try circle(a, x, y, diameter, st), st);
}

/// util.mergePaths: fill and stroke path of one rough drawing joined into a single path.
pub fn mergePaths(a: Allocator, g: *const El) Allocator.Error!*El {
    var d: std.ArrayList(u8) = .empty;
    var fill_path: ?*El = null;
    var stroke_path: ?*El = null;
    for (g.kids.items) |k| {
        if (!std.mem.eql(u8, k.tag, "path")) continue;
        if (d.items.len > 0) try d.append(a, ' ');
        try d.appendSlice(a, k.getAttr("d") orelse "");
        if (fill_path == null and !std.mem.eql(u8, k.getAttr("fill") orelse "", "none")) fill_path = k;
        if (stroke_path == null and !std.mem.eql(u8, k.getAttr("stroke") orelse "", "none")) stroke_path = k;
    }
    const merged = try El.create(a, "g");
    const p = try merged.insert("path");
    try p.setAttr("d", d.items);
    if (fill_path) |f| {
        try p.setAttr("fill", f.getAttr("fill") orelse "");
        try p.setAttr("fill-opacity", "1");
    }
    if (stroke_path) |s| {
        try p.setAttr("stroke", s.getAttr("stroke") orelse "");
        try p.setAttr("stroke-width", s.getAttr("stroke-width") orelse "1");
        try p.setAttr("stroke-opacity", "1");
    }
    return merged;
}

pub fn drawPath(a: Allocator, d: []const u8, st: Style) Error!*El {
    return draw(a, try path(a, d, st), st);
}

fn expectPath(expected: []const u8, got: []const u8) !void {
    try std.testing.expectEqualStrings(expected, got);
}

test "rng matches rough.js for seed 1" {
    var r = Rng{ .seed = 1 };
    try std.testing.expectEqual(@as(f64, 48271.0 / 2147483648.0), r.next());
}

test "straight line is two strokes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dr = try path(a, "M0,0 L10,0", .{ .fill = null });
    try std.testing.expectEqual(@as(usize, 1), dr.sets.len);
    const s = try opsToPath(a, dr.sets[0].ops);
    try std.testing.expect(std.mem.startsWith(u8, s, "M0 0 C"));
}

const ref_asym_fill = "M-93 -24 C-88.97493626587092 -15.949872531741857, -84.94987253174186 -7.899745063483714, -81 0 C-83.91888667456806 5.837773349136114, -86.83777334913611 11.675546698272228, -93 24 C-54.91607387792319 24, -16.83214775584638 24, 81 24 C81 9.371293254196644, 81 -5.257413491606712, 81 -24 C19.057452203147108 -24, -42.885095593705785 -24, -93 -24";
const ref_asym_stroke = "M-93 -24 C-90.5999460529536 -19.199892105907203, -88.1998921059072 -14.399784211814403, -81 0 M-93 -24 C-90.34377729780972 -18.68755459561944, -87.68755459561945 -13.375109191238879, -81 0 M-81 0 C-83.61002767570317 5.220055351406336, -86.22005535140633 10.440110702812673, -93 24 M-81 0 C-84.22074905745686 6.441498114913703, -87.4414981149137 12.882996229827405, -93 24 M-93 24 C-55.47298908960074 24, -17.945978179201475 24, 81 24 M-93 24 C-27.59121056366712 24, 37.81757887266576 24, 81 24 M81 24 C81 10.233152751624583, 81 -3.533694496750833, 81 -24 M81 24 C81 6.5392191365361185, 81 -10.921561726927763, 81 -24 M81 -24 C42.72269958984106 -24, 4.445399179682127 -24, -93 -24 M81 -24 C24.38808075953275 -24, -32.2238384809345 -24, -93 -24";
const ref_win_fill = "M-86 -34 L76 -34 L76 24 L-86 24 L-86 -34";
const ref_win_stroke = "M-86 -34 C-53.59927171487361 -34, -21.198543429747218 -34, 76 -34 M-86 -34 C-50.140993520431216 -34, -14.281987040862433 -34, 76 -34 M76 -34 C76 -21.384866234101352, 76 -8.769732468202708, 76 24 M76 -34 C76 -18.433046222291885, 76 -2.8660924445837708, 76 24 M76 24 C41.06105880755931 24, 6.122117615118626 24, -86 24 M76 24 C15.102161559276283 24, -45.795676881447434 24, -86 24 M-86 24 C-86 7.365059574879705, -86 -9.26988085024059, -86 -34 M-86 24 C-86 2.9015564566478105, -86 -18.19688708670438, -86 -34 M-86 -24 C-50.36251341123134 -24, -14.72502682246268 -24, 76 -24 M-86 -24 C-33.29235105197876 -24, 19.415297896042475 -24, 76 -24 M-76 -34 C-76 -14.545525285042821, -76 4.908949429914358, -76 24 M-76 -34 C-76 -19.892047739587724, -76 -5.784095479175448, -76 24";

fn drawn(a: Allocator, d: []const u8) !Drawing {
    return path(a, d, .{ .fill = "#1f2020" });
}

test "asymmetric shape matches rough.js path data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dr = try drawn(a, "M-93,-24 L-81,0 L-93,24 L81,24 L81,-24 Z");
    try std.testing.expectEqual(@as(usize, 2), dr.sets.len);
    try std.testing.expectEqual(SetKind.fill_path, dr.sets[0].kind);
    try expectPath(ref_asym_fill, try opsToPath(a, dr.sets[0].ops));
    try expectPath(ref_asym_stroke, try opsToPath(a, dr.sets[1].ops));
}

test "window pane with two subpaths fills as polygons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dr = try drawn(a, "M-86,-34 L76,-34 L76,24 L-86,24 L-86,-34 M-86,-24 L76,-24 M-76,-34 L-76,24");
    try expectPath(ref_win_fill, try opsToPath(a, dr.sets[0].ops));
    try expectPath(ref_win_stroke, try opsToPath(a, dr.sets[1].ops));
}

test "arcs normalize to curves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = try normalized(a, "M0,0 A10,10 0 0 1 10,10 Z");
    try std.testing.expectEqual(@as(u8, 'C'), segs[1].key);
    try std.testing.expectEqual(@as(u8, 'Z'), segs[segs.len - 1].key);
}
