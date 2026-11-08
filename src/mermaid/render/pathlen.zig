const std = @import("std");

const tol = 0.0005;

fn dist(x0: f64, y0: f64, x1: f64, y1: f64) f64 {
    return std.math.hypot(x1 - x0, y1 - y0);
}

fn quad(x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    const ax = x0 - 2 * x1 + x2;
    const ay = y0 - 2 * y1 + y2;
    const bx = 2 * (x1 - x0);
    const by = 2 * (y1 - y0);
    const a = 4 * (ax * ax + ay * ay);
    const b = 4 * (ax * bx + ay * by);
    const c = bx * bx + by * by;
    if (a < 1e-12) return dist(x0, y0, x2, y2);
    const sa = @sqrt(a);
    const sc = @sqrt(c);
    const su = @sqrt(a + b + c);
    const flat = @abs(4 * a * c - b * b) < 1e-9 or @abs(2 * sa * sc + b) < 1e-12;
    const log_term = if (flat) 0 else (4 * a * c - b * b) * @log((2 * sa * su + 2 * a + b) / (2 * sa * sc + b)) / (8 * a * sa);
    return (2 * a + b) * su / (4 * a) - b * sc / (4 * a) + log_term;
}

fn cubic(x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64, depth: u32) f64 {
    const chord = dist(x0, y0, x3, y3);
    const poly = dist(x0, y0, x1, y1) + dist(x1, y1, x2, y2) + dist(x2, y2, x3, y3);
    if (poly - chord < tol or depth >= 24) return (poly + chord) / 2;
    const ax = (x0 + x1) / 2;
    const ay = (y0 + y1) / 2;
    const bx = (x1 + x2) / 2;
    const by = (y1 + y2) / 2;
    const cx = (x2 + x3) / 2;
    const cy = (y2 + y3) / 2;
    const dx = (ax + bx) / 2;
    const dy = (ay + by) / 2;
    const ex = (bx + cx) / 2;
    const ey = (by + cy) / 2;
    const mx = (dx + ex) / 2;
    const my = (dy + ey) / 2;
    return cubic(x0, y0, ax, ay, dx, dy, mx, my, depth + 1) + cubic(mx, my, ex, ey, cx, cy, x3, y3, depth + 1);
}

fn speed(rx: f64, ry: f64, t: f64) f64 {
    const s = @sin(t);
    const c = @cos(t);
    return @sqrt(rx * rx * s * s + ry * ry * c * c);
}

fn simpson(rx: f64, ry: f64, a: f64, b: f64, fa: f64, fm: f64, fb: f64, whole: f64, depth: u32) f64 {
    const m = (a + b) / 2;
    const lm = (a + m) / 2;
    const rm = (m + b) / 2;
    const flm = speed(rx, ry, lm);
    const frm = speed(rx, ry, rm);
    const left = (m - a) / 6 * (fa + 4 * flm + fm);
    const right = (b - m) / 6 * (fm + 4 * frm + fb);
    if (depth >= 30 or @abs(left + right - whole) < 15e-7) return left + right + (left + right - whole) / 15;
    return simpson(rx, ry, a, m, fa, flm, fm, left, depth + 1) + simpson(rx, ry, m, b, fm, frm, fb, right, depth + 1);
}

fn arc(x1: f64, y1: f64, rx0: f64, ry0: f64, phi_deg: f64, fa: bool, fs: bool, x2: f64, y2: f64) f64 {
    var rx = @abs(rx0);
    var ry = @abs(ry0);
    if (rx == 0 or ry == 0) return dist(x1, y1, x2, y2);
    if (x1 == x2 and y1 == y2) return 0;
    const phi = phi_deg * std.math.pi / 180.0;
    const cp = @cos(phi);
    const sp = @sin(phi);
    const dx = (x1 - x2) / 2;
    const dy = (y1 - y2) / 2;
    const x1p = cp * dx + sp * dy;
    const y1p = -sp * dx + cp * dy;
    const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) {
        const s = @sqrt(lam);
        rx *= s;
        ry *= s;
    }
    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co: f64 = if (den == 0) 0 else @sqrt(@max(0, num / den));
    if (fa == fs) co = -co;
    const cxp = co * rx * y1p / ry;
    const cyp = -co * ry * x1p / rx;
    const th1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
    const th2 = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx);
    var dth = th2 - th1;
    if (fs and dth < 0) dth += 2 * std.math.pi;
    if (!fs and dth > 0) dth -= 2 * std.math.pi;
    if (@abs(rx - ry) < 1e-12) return rx * @abs(dth);
    const a = th1;
    const b = th1 + dth;
    const fa_ = speed(rx, ry, a);
    const fm = speed(rx, ry, (a + b) / 2);
    const fb = speed(rx, ry, b);
    const whole = (b - a) / 6 * (fa_ + 4 * fm + fb);
    return @abs(simpson(rx, ry, a, b, fa_, fm, fb, whole, 0));
}

fn nextNum(d: []const u8, i: *usize) ?f64 {
    while (i.* < d.len and (d[i.*] == ' ' or d[i.*] == ',' or d[i.*] == '\t' or d[i.*] == '\n')) i.* += 1;
    const st = i.*;
    var j = st;
    if (j < d.len and (d[j] == '-' or d[j] == '+')) j += 1;
    var dot = false;
    while (j < d.len) : (j += 1) {
        const c = d[j];
        if (std.ascii.isDigit(c)) continue;
        if (c == '.' and !dot) {
            dot = true;
            continue;
        }
        if ((c == 'e' or c == 'E') and j > st) {
            if (j + 1 < d.len and (d[j + 1] == '-' or d[j + 1] == '+')) j += 1;
            continue;
        }
        break;
    }
    if (j == st) return null;
    i.* = j;
    return std.fmt.parseFloat(f64, d[st..j]) catch null;
}

fn flag(d: []const u8, i: *usize) ?bool {
    while (i.* < d.len and (d[i.*] == ' ' or d[i.*] == ',')) i.* += 1;
    if (i.* >= d.len or (d[i.*] != '0' and d[i.*] != '1')) return null;
    i.* += 1;
    return d[i.* - 1] == '1';
}

/// Length of an SVG path made of M L H V C S Q T A Z commands (absolute and relative), like SVGGeometryElement.getTotalLength.
pub fn length(d: []const u8) f64 {
    var i: usize = 0;
    var cmd: u8 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var lx: f64 = 0;
    var ly: f64 = 0;
    var prev: u8 = 0;
    var total: f64 = 0;
    while (true) {
        while (i < d.len and (d[i] == ' ' or d[i] == ',' or d[i] == '\t' or d[i] == '\n')) i += 1;
        if (i >= d.len) break;
        if (std.ascii.isAlphabetic(d[i]) and d[i] != 'e' and d[i] != 'E') {
            cmd = d[i];
            i += 1;
            if (cmd == 'Z' or cmd == 'z') {
                total += dist(cx, cy, sx, sy);
                cx = sx;
                cy = sy;
                prev = 'z';
                continue;
            }
        } else if (cmd == 0) break;
        const rel = std.ascii.isLower(cmd);
        const ox: f64 = if (rel) cx else 0;
        const oy: f64 = if (rel) cy else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                cx = (nextNum(d, &i) orelse break) + ox;
                cy = (nextNum(d, &i) orelse break) + oy;
                sx = cx;
                sy = cy;
                cmd = if (rel) 'l' else 'L';
                prev = 'M';
            },
            'L' => {
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                total += dist(cx, cy, x, y);
                cx = x;
                cy = y;
                prev = 'L';
            },
            'H' => {
                const x = (nextNum(d, &i) orelse break) + ox;
                total += @abs(x - cx);
                cx = x;
                prev = 'L';
            },
            'V' => {
                const y = (nextNum(d, &i) orelse break) + oy;
                total += @abs(y - cy);
                cy = y;
                prev = 'L';
            },
            'C', 'S' => {
                const smooth = std.ascii.toUpper(cmd) == 'S';
                var x1 = cx;
                var y1 = cy;
                if (smooth) {
                    if (prev == 'C') {
                        x1 = 2 * cx - lx;
                        y1 = 2 * cy - ly;
                    }
                } else {
                    x1 = (nextNum(d, &i) orelse break) + ox;
                    y1 = (nextNum(d, &i) orelse break) + oy;
                }
                const x2 = (nextNum(d, &i) orelse break) + ox;
                const y2 = (nextNum(d, &i) orelse break) + oy;
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                total += cubic(cx, cy, x1, y1, x2, y2, x, y, 0);
                lx = x2;
                ly = y2;
                cx = x;
                cy = y;
                prev = 'C';
            },
            'Q', 'T' => {
                const smooth = std.ascii.toUpper(cmd) == 'T';
                var x1 = cx;
                var y1 = cy;
                if (smooth) {
                    if (prev == 'Q') {
                        x1 = 2 * cx - lx;
                        y1 = 2 * cy - ly;
                    }
                } else {
                    x1 = (nextNum(d, &i) orelse break) + ox;
                    y1 = (nextNum(d, &i) orelse break) + oy;
                }
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                total += quad(cx, cy, x1, y1, x, y);
                lx = x1;
                ly = y1;
                cx = x;
                cy = y;
                prev = 'Q';
            },
            'A' => {
                const rx = nextNum(d, &i) orelse break;
                const ry = nextNum(d, &i) orelse break;
                const rot = nextNum(d, &i) orelse break;
                const fa = flag(d, &i) orelse break;
                const fs = flag(d, &i) orelse break;
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                total += arc(cx, cy, rx, ry, rot, fa, fs, x, y);
                cx = x;
                cy = y;
                prev = 'A';
            },
            else => break,
        }
    }
    return total;
}

fn sampled(d: []const u8, n: usize) f64 {
    var i: usize = 0;
    var cmd: u8 = 0;
    var nums: [8]f64 = undefined;
    var cx: f64 = 0;
    var cy: f64 = 0;
    var total: f64 = 0;
    while (true) {
        while (i < d.len and (d[i] == ' ' or d[i] == ',')) i += 1;
        if (i >= d.len) break;
        if (std.ascii.isAlphabetic(d[i])) {
            cmd = d[i];
            i += 1;
        }
        const want: usize = switch (cmd) {
            'M', 'L' => 2,
            'Q' => 4,
            'C' => 6,
            else => break,
        };
        for (0..want) |k| nums[k] = nextNum(d, &i) orelse return total;
        if (cmd == 'M') {
            cx = nums[0];
            cy = nums[1];
            cmd = 'L';
            continue;
        }
        var px = cx;
        var py = cy;
        for (1..n + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const m = 1 - t;
            var qx: f64 = 0;
            var qy: f64 = 0;
            switch (cmd) {
                'L' => {
                    qx = cx + (nums[0] - cx) * t;
                    qy = cy + (nums[1] - cy) * t;
                },
                'Q' => {
                    qx = m * m * cx + 2 * m * t * nums[0] + t * t * nums[2];
                    qy = m * m * cy + 2 * m * t * nums[1] + t * t * nums[3];
                },
                else => {
                    qx = m * m * m * cx + 3 * m * m * t * nums[0] + 3 * m * t * t * nums[2] + t * t * t * nums[4];
                    qy = m * m * m * cy + 3 * m * m * t * nums[1] + 3 * m * t * t * nums[3] + t * t * t * nums[5];
                },
            }
            total += dist(px, py, qx, qy);
            px = qx;
            py = qy;
        }
        cx = px;
        cy = py;
    }
    return total;
}

test "lines and closing" {
    try std.testing.expectApproxEqAbs(@as(f64, 5), length("M0,0L3,4"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 12), length("M0,0 L3,0 L3,4 Z"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), length("M0 0 H3 V4"), 1e-12);
}

test "arcs" {
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, length("M1,0 A1,1 0 0,1 0,1"), 1e-9);
    try std.testing.expectApproxEqAbs(std.math.pi, length("M0,0 A5,5 0 0,1 10,0") / 5.0, 1e-9);
    // quarter of an ellipse a=2,b=1: perimeter 9.688448220547675 / 4
    try std.testing.expectApproxEqAbs(@as(f64, 2.4221120551369187), length("M2,0 A2,1 0 0,1 0,1"), 1e-5);
}

test "quadratic closed form" {
    // parabola y = x^2 on [0,1] as a quadratic: length 1.4789428575445974
    try std.testing.expectApproxEqAbs(@as(f64, 1.4789428575445974), length("M0,0 Q0.5,0 1,1"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), length("M0,0 Q5,0 10,0"), 1e-9);
}

test "cubic quarter circle" {
    const k = 0.5522847498307936;
    var buf: [96]u8 = undefined;
    const d = try std.fmt.bufPrint(&buf, "M1,0 C1,{d} {d},1 0,1", .{ k, k });
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, length(d), 3e-4);
}

test "exact length matches a fine sampling of generated rounded paths" {
    const d = "M10,10L40,10Q50,10 50,20L50,50C50,60 60,60 70,60";
    try std.testing.expectApproxEqAbs(sampled(d, 10000), length(d), 1e-3);
}
