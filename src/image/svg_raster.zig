const std = @import("std");

pub const Error = error{ OutOfMemory, TooLarge };

pub const Pt = struct { x: f64, y: f64 };

pub const Mat = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Mat = .{};

    pub fn mul(m: Mat, n: Mat) Mat {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }

    pub fn translate(x: f64, y: f64) Mat {
        return .{ .e = x, .f = y };
    }

    pub fn scale(x: f64, y: f64) Mat {
        return .{ .a = x, .d = y };
    }

    pub fn apply(m: Mat, p: Pt) Pt {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }

    pub fn det(m: Mat) f64 {
        return m.a * m.d - m.b * m.c;
    }

    pub fn inverse(m: Mat) ?Mat {
        const dt = m.det();
        if (!(@abs(dt) > 1e-12) or !std.math.isFinite(dt)) return null;
        const ia = m.d / dt;
        const ib = -m.b / dt;
        const ic = -m.c / dt;
        const id = m.a / dt;
        return .{ .a = ia, .b = ib, .c = ic, .d = id, .e = -(ia * m.e + ic * m.f), .f = -(ib * m.e + id * m.f) };
    }

    pub fn meanScale(m: Mat) f64 {
        return @sqrt(@abs(m.det()));
    }
};

pub const Seg = union(enum) { move: Pt, line: Pt, cubic: [3]Pt, close };

pub const max_segs = 2_000_000;

pub const Path = struct {
    segs: std.ArrayList(Seg) = .empty,
    cur: Pt = .{ .x = 0, .y = 0 },
    start: Pt = .{ .x = 0, .y = 0 },

    fn push(p: *Path, alloc: std.mem.Allocator, s: Seg) Error!void {
        if (p.segs.items.len >= max_segs) return error.TooLarge;
        try p.segs.append(alloc, s);
    }

    pub fn moveTo(p: *Path, alloc: std.mem.Allocator, x: f64, y: f64) Error!void {
        p.cur = .{ .x = x, .y = y };
        p.start = p.cur;
        try p.push(alloc, .{ .move = p.cur });
    }

    pub fn lineTo(p: *Path, alloc: std.mem.Allocator, x: f64, y: f64) Error!void {
        p.cur = .{ .x = x, .y = y };
        try p.push(alloc, .{ .line = p.cur });
    }

    pub fn cubicTo(p: *Path, alloc: std.mem.Allocator, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) Error!void {
        p.cur = .{ .x = x, .y = y };
        try p.push(alloc, .{ .cubic = .{ .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 }, p.cur } });
    }

    pub fn quadTo(p: *Path, alloc: std.mem.Allocator, x1: f64, y1: f64, x: f64, y: f64) Error!void {
        const c = p.cur;
        try p.cubicTo(alloc, c.x + 2.0 / 3.0 * (x1 - c.x), c.y + 2.0 / 3.0 * (y1 - c.y), x + 2.0 / 3.0 * (x1 - x), y + 2.0 / 3.0 * (y1 - y), x, y);
    }

    pub fn close(p: *Path, alloc: std.mem.Allocator) Error!void {
        p.cur = p.start;
        try p.push(alloc, .close);
    }

    pub fn arcTo(p: *Path, alloc: std.mem.Allocator, rx_in: f64, ry_in: f64, rot_deg: f64, large: bool, sweep: bool, x: f64, y: f64) Error!void {
        const x0 = p.cur.x;
        const y0 = p.cur.y;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if ((x0 == x and y0 == y)) return;
        if (rx == 0 or ry == 0) return p.lineTo(alloc, x, y);
        const phi = rot_deg * std.math.pi / 180.0;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx = (x0 - x) / 2;
        const dy = (y0 - y) / 2;
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
        var coef = if (den == 0) 0 else @sqrt(@max(0, num / den));
        if (large == sweep) coef = -coef;
        const cxp = coef * rx * y1p / ry;
        const cyp = -coef * ry * x1p / rx;
        const cx = cp * cxp - sp * cyp + (x0 + x) / 2;
        const cy = sp * cxp + cp * cyp + (y0 + y) / 2;
        const th1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
        var dth = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx) - th1;
        if (sweep and dth < 0) dth += 2 * std.math.pi;
        if (!sweep and dth > 0) dth -= 2 * std.math.pi;
        const n: usize = @intFromFloat(@ceil(@abs(dth) / (std.math.pi / 2.0) - 1e-9));
        const nseg = @max(n, 1);
        const step = dth / @as(f64, @floatFromInt(nseg));
        const t = 4.0 / 3.0 * @tan(step / 4.0);
        var a = th1;
        for (0..nseg) |i| {
            const a2 = a + step;
            const c1 = @cos(a);
            const s1 = @sin(a);
            const c2 = @cos(a2);
            const s2 = @sin(a2);
            const p1 = ell(cx, cy, rx, ry, cp, sp, c1 - t * s1, s1 + t * c1);
            const p2 = ell(cx, cy, rx, ry, cp, sp, c2 + t * s2, s2 - t * c2);
            const p3 = if (i + 1 == nseg) Pt{ .x = x, .y = y } else ell(cx, cy, rx, ry, cp, sp, c2, s2);
            try p.cubicTo(alloc, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
            a = a2;
        }
    }
};

fn ell(cx: f64, cy: f64, rx: f64, ry: f64, cp: f64, sp: f64, ux: f64, uy: f64) Pt {
    const px = rx * ux;
    const py = ry * uy;
    return .{ .x = cp * px - sp * py + cx, .y = sp * px + cp * py + cy };
}

pub const NumScan = struct {
    s: []const u8,
    i: usize = 0,

    pub fn skipSep(n: *NumScan) void {
        while (n.i < n.s.len and (std.ascii.isWhitespace(n.s[n.i]) or n.s[n.i] == ',')) n.i += 1;
    }

    pub fn atEnd(n: *NumScan) bool {
        n.skipSep();
        return n.i >= n.s.len;
    }

    pub fn peek(n: *NumScan) ?u8 {
        n.skipSep();
        return if (n.i < n.s.len) n.s[n.i] else null;
    }

    pub fn number(n: *NumScan) ?f64 {
        n.skipSep();
        const st = n.i;
        var i = n.i;
        if (i < n.s.len and (n.s[i] == '+' or n.s[i] == '-')) i += 1;
        var digits: usize = 0;
        while (i < n.s.len and std.ascii.isDigit(n.s[i])) : (i += 1) digits += 1;
        if (i < n.s.len and n.s[i] == '.') {
            i += 1;
            while (i < n.s.len and std.ascii.isDigit(n.s[i])) : (i += 1) digits += 1;
        }
        if (digits == 0) return null;
        if (i < n.s.len and (n.s[i] == 'e' or n.s[i] == 'E')) {
            var j = i + 1;
            if (j < n.s.len and (n.s[j] == '+' or n.s[j] == '-')) j += 1;
            if (j < n.s.len and std.ascii.isDigit(n.s[j])) {
                while (j < n.s.len and std.ascii.isDigit(n.s[j])) j += 1;
                i = j;
            }
        }
        const v = std.fmt.parseFloat(f64, n.s[st..i]) catch return null;
        if (!std.math.isFinite(v)) return null;
        n.i = i;
        return v;
    }

    fn flag(n: *NumScan) ?bool {
        n.skipSep();
        if (n.i >= n.s.len) return null;
        const c = n.s[n.i];
        if (c != '0' and c != '1') return null;
        n.i += 1;
        return c == '1';
    }
};

pub fn parsePathData(alloc: std.mem.Allocator, d: []const u8, path: *Path) Error!void {
    var sc: NumScan = .{ .s = d };
    var cmd: u8 = 0;
    var last_c2: Pt = .{ .x = 0, .y = 0 };
    var last_q: Pt = .{ .x = 0, .y = 0 };
    var prev: u8 = 0;
    var first = true;
    while (true) {
        const c = sc.peek() orelse break;
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            sc.i += 1;
            if (first and cmd != 'M' and cmd != 'm') return;
            if (cmd == 'z' or cmd == 'Z') {
                try path.close(alloc);
                prev = 'z';
                first = false;
                continue;
            }
        } else if (cmd == 0 or cmd == 'z' or cmd == 'Z') {
            return;
        }
        const rel = std.ascii.isLower(cmd);
        const o: Pt = if (rel) path.cur else .{ .x = 0, .y = 0 };
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                try path.moveTo(alloc, o.x + x, o.y + y);
                cmd = if (rel) 'l' else 'L';
                prev = 'M';
            },
            'L' => {
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                try path.lineTo(alloc, o.x + x, o.y + y);
                prev = 'L';
            },
            'H' => {
                const x = sc.number() orelse return;
                try path.lineTo(alloc, o.x + x, path.cur.y);
                prev = 'L';
            },
            'V' => {
                const y = sc.number() orelse return;
                try path.lineTo(alloc, path.cur.x, o.y + y);
                prev = 'L';
            },
            'C' => {
                const x1 = sc.number() orelse return;
                const y1 = sc.number() orelse return;
                const x2 = sc.number() orelse return;
                const y2 = sc.number() orelse return;
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                try path.cubicTo(alloc, o.x + x1, o.y + y1, o.x + x2, o.y + y2, o.x + x, o.y + y);
                last_c2 = .{ .x = o.x + x2, .y = o.y + y2 };
                prev = 'C';
            },
            'S' => {
                const x2 = sc.number() orelse return;
                const y2 = sc.number() orelse return;
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                const cur = path.cur;
                const r: Pt = if (prev == 'C') .{ .x = 2 * cur.x - last_c2.x, .y = 2 * cur.y - last_c2.y } else cur;
                try path.cubicTo(alloc, r.x, r.y, o.x + x2, o.y + y2, o.x + x, o.y + y);
                last_c2 = .{ .x = o.x + x2, .y = o.y + y2 };
                prev = 'C';
            },
            'Q' => {
                const x1 = sc.number() orelse return;
                const y1 = sc.number() orelse return;
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                try path.quadTo(alloc, o.x + x1, o.y + y1, o.x + x, o.y + y);
                last_q = .{ .x = o.x + x1, .y = o.y + y1 };
                prev = 'Q';
            },
            'T' => {
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                const cur = path.cur;
                const r: Pt = if (prev == 'Q') .{ .x = 2 * cur.x - last_q.x, .y = 2 * cur.y - last_q.y } else cur;
                try path.quadTo(alloc, r.x, r.y, o.x + x, o.y + y);
                last_q = r;
                prev = 'Q';
            },
            'A' => {
                const rx = sc.number() orelse return;
                const ry = sc.number() orelse return;
                const rot = sc.number() orelse return;
                const large = sc.flag() orelse return;
                const sweep = sc.flag() orelse return;
                const x = sc.number() orelse return;
                const y = sc.number() orelse return;
                try path.arcTo(alloc, rx, ry, rot, large, sweep, o.x + x, o.y + y);
                prev = 'A';
            },
            else => return,
        }
        first = false;
    }
}

pub const Sub = struct { start: u32, len: u32, closed: bool };

pub const Polys = struct {
    pts: std.ArrayList(Pt) = .empty,
    subs: std.ArrayList(Sub) = .empty,

    pub fn clear(p: *Polys) void {
        p.pts.clearRetainingCapacity();
        p.subs.clearRetainingCapacity();
    }

    pub fn deinit(p: *Polys, alloc: std.mem.Allocator) void {
        p.pts.deinit(alloc);
        p.subs.deinit(alloc);
    }

    pub fn transform(p: *Polys, m: Mat) void {
        for (p.pts.items) |*q| q.* = m.apply(q.*);
    }
};

const max_points = 8_000_000;

fn finite(p: Pt) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y) and @abs(p.x) < 1e9 and @abs(p.y) < 1e9;
}

pub fn flatten(alloc: std.mem.Allocator, path: *const Path, m: Mat, tol: f64, out: *Polys) Error!void {
    var sub_start: u32 = 0;
    var cur: Pt = .{ .x = 0, .y = 0 };
    var start: Pt = cur;
    var open = false;
    var segs_in_sub: u32 = 0;
    const flush = struct {
        fn f(o: *Polys, a: std.mem.Allocator, ss: u32, closed: bool, segs: u32) Error!void {
            const len: u32 = @intCast(o.pts.items.len - ss);
            if (segs > 0 and len >= 1) try o.subs.append(a, .{ .start = ss, .len = len, .closed = closed }) else o.pts.shrinkRetainingCapacity(ss);
        }
    }.f;
    for (path.segs.items) |s| {
        if (out.pts.items.len > max_points) return error.TooLarge;
        switch (s) {
            .move => |p| {
                if (open) try flush(out, alloc, sub_start, false, segs_in_sub);
                sub_start = @intCast(out.pts.items.len);
                cur = p;
                start = p;
                open = true;
                segs_in_sub = 0;
                try out.pts.append(alloc, m.apply(p));
            },
            .line => |p| {
                if (!open) {
                    sub_start = @intCast(out.pts.items.len);
                    try out.pts.append(alloc, m.apply(cur));
                    open = true;
                    segs_in_sub = 0;
                }
                cur = p;
                segs_in_sub += 1;
                try out.pts.append(alloc, m.apply(p));
            },
            .cubic => |c| {
                if (!open) {
                    sub_start = @intCast(out.pts.items.len);
                    try out.pts.append(alloc, m.apply(cur));
                    open = true;
                    segs_in_sub = 0;
                }
                const p0 = m.apply(cur);
                const p1 = m.apply(c[0]);
                const p2 = m.apply(c[1]);
                const p3 = m.apply(c[2]);
                const ddx = @max(@abs(p0.x - 2 * p1.x + p2.x), @abs(p1.x - 2 * p2.x + p3.x));
                const ddy = @max(@abs(p0.y - 2 * p1.y + p2.y), @abs(p1.y - 2 * p2.y + p3.y));
                const dd = @sqrt(ddx * ddx + ddy * ddy);
                const nf = @ceil(@sqrt(0.75 * dd / tol));
                const n: usize = if (std.math.isFinite(nf)) @intFromFloat(std.math.clamp(nf, 1, 400)) else 1;
                for (1..n + 1) |i| {
                    const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                    const u = 1 - t;
                    const w0 = u * u * u;
                    const w1 = 3 * u * u * t;
                    const w2 = 3 * u * t * t;
                    const w3 = t * t * t;
                    try out.pts.append(alloc, .{
                        .x = w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
                        .y = w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y,
                    });
                }
                cur = c[2];
                segs_in_sub += 1;
            },
            .close => {
                if (open) {
                    segs_in_sub += 1;
                    try flush(out, alloc, sub_start, true, segs_in_sub);
                    open = false;
                    cur = start;
                }
            },
        }
    }
    if (open) try flush(out, alloc, sub_start, false, segs_in_sub);
}

pub const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

pub fn bounds(path: *const Path) ?Rect {
    var any = false;
    var x0: f64 = 0;
    var y0: f64 = 0;
    var x1: f64 = 0;
    var y1: f64 = 0;
    var tmp: Polys = .{};
    var buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    flatten(fba.allocator(), path, Mat.identity, 0.05, &tmp) catch {
        return boundsControl(path);
    };
    for (tmp.pts.items) |p| {
        if (!finite(p)) continue;
        if (!any) {
            x0 = p.x;
            x1 = p.x;
            y0 = p.y;
            y1 = p.y;
            any = true;
        }
        x0 = @min(x0, p.x);
        x1 = @max(x1, p.x);
        y0 = @min(y0, p.y);
        y1 = @max(y1, p.y);
    }
    if (!any) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn boundsControl(path: *const Path) ?Rect {
    var r: ?Rect = null;
    for (path.segs.items) |s| {
        const pts: []const Pt = switch (s) {
            .move => |*p| p[0..1],
            .line => |*p| p[0..1],
            .cubic => |*c| c[0..3],
            .close => &.{},
        };
        for (pts) |p| {
            if (!finite(p)) continue;
            const cur = r orelse Rect{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y };
            r = .{ .x0 = @min(cur.x0, p.x), .y0 = @min(cur.y0, p.y), .x1 = @max(cur.x1, p.x), .y1 = @max(cur.y1, p.y) };
        }
    }
    return r;
}

pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };

pub const StrokeStyle = struct {
    width: f64,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f64 = 4,
    dashes: []const f64 = &.{},
    dash_offset: f64 = 0,
};

fn dashPolys(alloc: std.mem.Allocator, src: *const Polys, dashes: []const f64, offset: f64, out: *Polys) Error!void {
    var total: f64 = 0;
    for (dashes) |d| total += d;
    const n = dashes.len;
    var emitted: usize = 0;
    for (src.subs.items) |sub| {
        const pts = src.pts.items[sub.start..][0..sub.len];
        var idx: usize = 0;
        var off = @mod(offset, total * @as(f64, if (n % 2 == 1) 2.0 else 1.0));
        var on = true;
        while (off >= dashes[idx % n]) {
            off -= dashes[idx % n];
            idx += 1;
            on = !on;
            if (idx > 10000) break;
        }
        var remain = dashes[idx % n] - off;
        var cur_start: ?u32 = null;
        const count = if (sub.closed) pts.len + 1 else pts.len;
        var prev = pts[0];
        if (on) {
            cur_start = @intCast(out.pts.items.len);
            try out.pts.append(alloc, prev);
        }
        for (1..count) |k| {
            const next = pts[k % pts.len];
            const segl = std.math.hypot(next.x - prev.x, next.y - prev.y);
            const dx = next.x - prev.x;
            const dy = next.y - prev.y;
            var px = prev.x;
            var py = prev.y;
            var consumed: f64 = 0;
            while (segl - consumed > remain) {
                consumed += remain;
                const t = consumed / segl;
                px = prev.x + dx * t;
                py = prev.y + dy * t;
                if (on) {
                    try out.pts.append(alloc, .{ .x = px, .y = py });
                    try out.subs.append(alloc, .{ .start = cur_start.?, .len = @intCast(out.pts.items.len - cur_start.?), .closed = false });
                    cur_start = null;
                    emitted += 1;
                } else {
                    cur_start = @intCast(out.pts.items.len);
                    try out.pts.append(alloc, .{ .x = px, .y = py });
                }
                on = !on;
                idx += 1;
                remain = dashes[idx % n];
                if (emitted > 30_000 or out.pts.items.len > max_points) return error.TooLarge;
                if (remain <= 0) {
                    remain = 1e-9;
                }
            }
            remain -= segl - consumed;
            if (on) try out.pts.append(alloc, next);
            prev = next;
        }
        if (on and cur_start != null) {
            try out.subs.append(alloc, .{ .start = cur_start.?, .len = @intCast(out.pts.items.len - cur_start.?), .closed = false });
        }
    }
}

fn emitPoly(alloc: std.mem.Allocator, out: *Polys, pts: []const Pt) Error!void {
    var area: f64 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        area += p.x * q.y - q.x * p.y;
    }
    if (@abs(area) < 1e-18) return;
    const start: u32 = @intCast(out.pts.items.len);
    if (area > 0) {
        try out.pts.appendSlice(alloc, pts);
    } else {
        var i = pts.len;
        while (i > 0) {
            i -= 1;
            try out.pts.append(alloc, pts[i]);
        }
    }
    try out.subs.append(alloc, .{ .start = start, .len = @intCast(pts.len), .closed = true });
}

fn arcSteps(hw: f64, sweep: f64, tol: f64) usize {
    const r = @max(hw, 1e-9);
    const da = 2 * std.math.acos(std.math.clamp(1 - tol / r, -1, 1));
    const n = @ceil(@abs(sweep) / @max(da, 0.05));
    return @intFromFloat(std.math.clamp(n, 1, 200));
}

fn capPoly(alloc: std.mem.Allocator, out: *Polys, p: Pt, dir: Pt, hw: f64, cap: Cap, tol: f64) Error!void {
    const nx = -dir.y * hw;
    const ny = dir.x * hw;
    if (cap == .square) {
        try emitPoly(alloc, out, &.{
            .{ .x = p.x + nx, .y = p.y + ny },
            .{ .x = p.x + nx + dir.x * hw, .y = p.y + ny + dir.y * hw },
            .{ .x = p.x - nx + dir.x * hw, .y = p.y - ny + dir.y * hw },
            .{ .x = p.x - nx, .y = p.y - ny },
        });
    } else if (cap == .round) {
        const steps = arcSteps(hw, std.math.pi, tol);
        var buf: [256]Pt = undefined;
        buf[0] = .{ .x = p.x + nx, .y = p.y + ny };
        for (1..steps + 1) |i| {
            const t = std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            buf[i] = .{ .x = p.x + nx * @cos(t) + dir.x * hw * @sin(t), .y = p.y + ny * @cos(t) + dir.y * hw * @sin(t) };
        }
        try emitPoly(alloc, out, buf[0 .. steps + 1]);
    }
}

fn joinPoly(alloc: std.mem.Allocator, out: *Polys, p: Pt, d0: Pt, d1: Pt, hw: f64, join: Join, miter_limit: f64, tol: f64) Error!void {
    const cross = d0.x * d1.y - d0.y * d1.x;
    const dot = d0.x * d1.x + d0.y * d1.y;
    if (@abs(cross) < 1e-9 and dot > 0) return;
    const s: f64 = if (cross > 0) -1 else 1;
    const n0 = Pt{ .x = -d0.y * hw * s, .y = d0.x * hw * s };
    const n1 = Pt{ .x = -d1.y * hw * s, .y = d1.x * hw * s };
    const a = Pt{ .x = p.x + n0.x, .y = p.y + n0.y };
    const b = Pt{ .x = p.x + n1.x, .y = p.y + n1.y };
    switch (join) {
        .bevel => try emitPoly(alloc, out, &.{ p, a, b }),
        .miter => {
            const ratio = 1.0 / @sqrt(@max((1 + dot) / 2, 1e-12));
            if (ratio <= miter_limit and 1 + dot > 1e-9) {
                const k = 1.0 / (1 + dot);
                try emitPoly(alloc, out, &.{ p, a, .{ .x = p.x + (n0.x + n1.x) * k, .y = p.y + (n0.y + n1.y) * k }, b });
            } else try emitPoly(alloc, out, &.{ p, a, b });
        },
        .round => {
            const a0 = std.math.atan2(n0.y, n0.x);
            var sweep = std.math.atan2(n1.y, n1.x) - a0;
            while (sweep > std.math.pi) sweep -= 2 * std.math.pi;
            while (sweep < -std.math.pi) sweep += 2 * std.math.pi;
            const steps = arcSteps(hw, sweep, tol);
            var buf: [210]Pt = undefined;
            buf[0] = p;
            buf[1] = a;
            for (1..steps) |i| {
                const t = a0 + sweep * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
                buf[i + 1] = .{ .x = p.x + hw * @cos(t), .y = p.y + hw * @sin(t) };
            }
            buf[steps + 1] = b;
            try emitPoly(alloc, out, buf[0 .. steps + 2]);
        },
    }
}

pub fn stroke(alloc: std.mem.Allocator, src: *const Polys, st: StrokeStyle, tol: f64, out: *Polys) Error!void {
    const hw = st.width / 2;
    if (!(hw > 0)) return;
    var dashed: Polys = .{};
    defer dashed.deinit(alloc);
    var in = src;
    var dash_total: f64 = 0;
    for (st.dashes) |d| dash_total += d;
    if (dash_total > 0) {
        if (dashPolys(alloc, src, st.dashes, st.dash_offset, &dashed)) |_| {
            in = &dashed;
        } else |e| if (e != error.TooLarge) return e;
    }
    var clean: std.ArrayList(Pt) = .empty;
    defer clean.deinit(alloc);
    for (in.subs.items) |sub| {
        const raw = in.pts.items[sub.start..][0..sub.len];
        clean.clearRetainingCapacity();
        for (raw) |p| {
            if (!finite(p)) continue;
            if (clean.items.len > 0) {
                const q = clean.items[clean.items.len - 1];
                if (@abs(p.x - q.x) < 1e-9 and @abs(p.y - q.y) < 1e-9) continue;
            }
            try clean.append(alloc, p);
        }
        var closed = sub.closed;
        if (closed and clean.items.len > 1) {
            const f = clean.items[0];
            const l = clean.items[clean.items.len - 1];
            if (@abs(f.x - l.x) < 1e-9 and @abs(f.y - l.y) < 1e-9) _ = clean.pop();
        }
        const pts = clean.items;
        if (pts.len == 0) continue;
        if (pts.len == 1) {
            if (st.cap == .round) {
                var buf: [200]Pt = undefined;
                const steps = arcSteps(hw, 2 * std.math.pi, tol);
                for (0..steps) |i| {
                    const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
                    buf[i] = .{ .x = pts[0].x + hw * @cos(t), .y = pts[0].y + hw * @sin(t) };
                }
                try emitPoly(alloc, out, buf[0..steps]);
            } else if (st.cap == .square) {
                try emitPoly(alloc, out, &.{
                    .{ .x = pts[0].x - hw, .y = pts[0].y - hw },
                    .{ .x = pts[0].x + hw, .y = pts[0].y - hw },
                    .{ .x = pts[0].x + hw, .y = pts[0].y + hw },
                    .{ .x = pts[0].x - hw, .y = pts[0].y + hw },
                });
            }
            continue;
        }
        if (pts.len == 2) closed = false;
        const nseg = if (closed) pts.len else pts.len - 1;
        var first_dir: Pt = .{ .x = 0, .y = 0 };
        var prev_dir: Pt = .{ .x = 0, .y = 0 };
        for (0..nseg) |i| {
            const p0 = pts[i];
            const p1 = pts[(i + 1) % pts.len];
            const l = std.math.hypot(p1.x - p0.x, p1.y - p0.y);
            const d = Pt{ .x = (p1.x - p0.x) / l, .y = (p1.y - p0.y) / l };
            const nx = -d.y * hw;
            const ny = d.x * hw;
            try emitPoly(alloc, out, &.{
                .{ .x = p0.x + nx, .y = p0.y + ny },
                .{ .x = p1.x + nx, .y = p1.y + ny },
                .{ .x = p1.x - nx, .y = p1.y - ny },
                .{ .x = p0.x - nx, .y = p0.y - ny },
            });
            if (i == 0) {
                first_dir = d;
            } else try joinPoly(alloc, out, p0, prev_dir, d, hw, st.join, st.miter_limit, tol);
            prev_dir = d;
        }
        if (closed) {
            try joinPoly(alloc, out, pts[0], prev_dir, first_dir, hw, st.join, st.miter_limit, tol);
        } else {
            try capPoly(alloc, out, pts[0], .{ .x = -first_dir.x, .y = -first_dir.y }, hw, st.cap, tol);
            try capPoly(alloc, out, pts[pts.len - 1], prev_dir, hw, st.cap, tol);
        }
        if (out.pts.items.len > max_points) return error.TooLarge;
    }
}

pub const FillRule = enum { nonzero, evenodd };

pub const Cover = struct { x0: usize, y0: usize, w: usize, h: usize, data: []u8 };

const Cross = struct { x: f32, dir: i8 };

fn crossLess(_: void, a: Cross, b: Cross) bool {
    return a.x < b.x;
}

const max_crossings: usize = 150_000_000;

const Edge = struct { x0: f32, y0: f32, y1: f32, slope: f32, dir: i8 };

pub const sub_scans = 16;

pub const Raster = struct {
    alloc: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    active: std.ArrayList(u32) = .empty,
    xs: std.ArrayList(Cross) = .empty,
    cov: std.ArrayList(f32) = .empty,
    delta: std.ArrayList(f32) = .empty,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Raster {
        return .{ .alloc = alloc };
    }

    pub fn deinit(r: *Raster) void {
        r.edges.deinit(r.alloc);
        r.active.deinit(r.alloc);
        r.xs.deinit(r.alloc);
        r.cov.deinit(r.alloc);
        r.delta.deinit(r.alloc);
        r.buf.deinit(r.alloc);
    }

    fn edgeLess(_: void, a: Edge, b: Edge) bool {
        return a.y0 < b.y0;
    }

    pub fn fill(r: *Raster, polys: *const Polys, rule: FillRule, width: usize, height: usize) Error!?Cover {
        var minx: f64 = std.math.inf(f64);
        var maxx: f64 = -std.math.inf(f64);
        var miny: f64 = std.math.inf(f64);
        var maxy: f64 = -std.math.inf(f64);
        for (polys.pts.items) |p| {
            if (!finite(p)) continue;
            minx = @min(minx, p.x);
            maxx = @max(maxx, p.x);
            miny = @min(miny, p.y);
            maxy = @max(maxy, p.y);
        }
        if (!(minx <= maxx)) return null;
        const bx0 = @max(@floor(minx), 0);
        const by0 = @max(@floor(miny), 0);
        const bx1 = @min(@ceil(maxx), @as(f64, @floatFromInt(width)));
        const by1 = @min(@ceil(maxy), @as(f64, @floatFromInt(height)));
        if (!(bx0 < bx1 and by0 < by1)) return null;
        const ox: usize = @intFromFloat(bx0);
        const oy: usize = @intFromFloat(by0);
        const bw: usize = @as(usize, @intFromFloat(bx1)) - ox;
        const bh: usize = @as(usize, @intFromFloat(by1)) - oy;

        r.edges.clearRetainingCapacity();
        for (polys.subs.items) |sub| {
            const pts = polys.pts.items[sub.start..][0..sub.len];
            if (pts.len < 2) continue;
            var prev = pts[pts.len - 1];
            for (pts) |p| {
                const a = prev;
                prev = p;
                if (!finite(a) or !finite(p) or a.y == p.y) continue;
                const down = p.y > a.y;
                const lo = if (down) a else p;
                const hi = if (down) p else a;
                if (hi.y <= @as(f64, @floatFromInt(oy)) or lo.y >= @as(f64, @floatFromInt(oy + bh))) continue;
                try r.edges.append(r.alloc, .{
                    .x0 = @floatCast(lo.x - @as(f64, @floatFromInt(ox))),
                    .y0 = @floatCast(lo.y - @as(f64, @floatFromInt(oy))),
                    .y1 = @floatCast(hi.y - @as(f64, @floatFromInt(oy))),
                    .slope = @floatCast((hi.x - lo.x) / (hi.y - lo.y)),
                    .dir = if (down) 1 else -1,
                });
            }
        }
        if (r.edges.items.len == 0) return null;
        std.mem.sort(Edge, r.edges.items, {}, edgeLess);

        try r.buf.resize(r.alloc, bw * bh);
        try r.cov.resize(r.alloc, bw + 2);
        try r.delta.resize(r.alloc, bw + 2);
        r.active.clearRetainingCapacity();
        var next: usize = 0;
        var crossings: usize = 0;
        const fw: f32 = @floatFromInt(bw);
        const inv: f32 = 1.0 / @as(f32, sub_scans);
        for (0..bh) |row| {
            @memset(r.cov.items, 0);
            @memset(r.delta.items, 0);
            for (0..sub_scans) |s| {
                const sy: f32 = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(s)) + 0.5) * inv;
                while (next < r.edges.items.len and r.edges.items[next].y0 <= sy) : (next += 1) try r.active.append(r.alloc, @intCast(next));
                var k: usize = 0;
                r.xs.clearRetainingCapacity();
                while (k < r.active.items.len) {
                    const e = r.edges.items[r.active.items[k]];
                    if (e.y1 <= sy) {
                        _ = r.active.swapRemove(k);
                        continue;
                    }
                    k += 1;
                    const x = e.x0 + (sy - e.y0) * e.slope;
                    try r.xs.append(r.alloc, .{ .x = x, .dir = e.dir });
                }
                crossings += r.xs.items.len;
                if (crossings > max_crossings) return error.TooLarge;
                std.mem.sort(Cross, r.xs.items, {}, crossLess);
                var wind: i32 = 0;
                var xin: f32 = 0;
                for (r.xs.items) |c| {
                    const was = if (rule == .nonzero) wind != 0 else (wind & 1) != 0;
                    wind += c.dir;
                    const now = if (rule == .nonzero) wind != 0 else (wind & 1) != 0;
                    if (!was and now) {
                        xin = c.x;
                    } else if (was and !now) {
                        const xa = std.math.clamp(xin, 0, fw);
                        const xb = std.math.clamp(c.x, 0, fw);
                        if (xb > xa) addSpan(r, xa, xb, inv);
                    }
                }
            }
            var run: f32 = 0;
            const out = r.buf.items[row * bw ..][0..bw];
            for (out, 0..) |*o, x| {
                run += r.delta.items[x];
                const v = std.math.clamp(r.cov.items[x] + run, 0, 1);
                o.* = @intFromFloat(v * 255 + 0.5);
            }
        }
        return .{ .x0 = ox, .y0 = oy, .w = bw, .h = bh, .data = r.buf.items };
    }

    fn addSpan(r: *Raster, xa: f32, xb: f32, inv: f32) void {
        const ia: usize = @intFromFloat(xa);
        const ib: usize = @intFromFloat(xb);
        if (ia == ib) {
            r.cov.items[ia] += (xb - xa) * inv;
            return;
        }
        r.cov.items[ia] += (@as(f32, @floatFromInt(ia + 1)) - xa) * inv;
        r.cov.items[ib] += (xb - @as(f32, @floatFromInt(ib))) * inv;
        r.delta.items[ia + 1] += inv;
        r.delta.items[ib] -= inv;
    }
};

test "fill rect coverage" {
    const a = std.testing.allocator;
    var r = Raster.init(a);
    defer r.deinit();
    var p: Path = .{};
    defer p.segs.deinit(a);
    try parsePathData(a, "M1.5 1 H4 V3 H1.5z", &p);
    var polys: Polys = .{};
    defer polys.deinit(a);
    try flatten(a, &p, Mat.identity, 0.1, &polys);
    const c = (try r.fill(&polys, .nonzero, 8, 8)).?;
    try std.testing.expectEqual(@as(usize, 1), c.x0);
    try std.testing.expectEqual(@as(usize, 1), c.y0);
    try std.testing.expectEqual(@as(u8, 128), c.data[0]);
    try std.testing.expectEqual(@as(u8, 255), c.data[1]);
    try std.testing.expectEqual(@as(u8, 255), c.data[c.w + 1]);
}

test "even-odd hole and stroke" {
    const a = std.testing.allocator;
    var r = Raster.init(a);
    defer r.deinit();
    var p: Path = .{};
    defer p.segs.deinit(a);
    try parsePathData(a, "M0 0H8V8H0zM2 2H6V6H2z", &p);
    var polys: Polys = .{};
    defer polys.deinit(a);
    try flatten(a, &p, Mat.identity, 0.1, &polys);
    const c = (try r.fill(&polys, .evenodd, 8, 8)).?;
    try std.testing.expectEqual(@as(u8, 255), c.data[0]);
    try std.testing.expectEqual(@as(u8, 0), c.data[3 * 8 + 3]);
    var st: Polys = .{};
    defer st.deinit(a);
    try stroke(a, &polys, .{ .width = 1, .join = .round }, 0.1, &st);
    try std.testing.expect(st.subs.items.len > 8);
}

test "path data odd forms" {
    const a = std.testing.allocator;
    var p: Path = .{};
    defer p.segs.deinit(a);
    try parsePathData(a, "m10-20.5.5e1 3 1-2 a5 5 0 1010 0 L junk", &p);
    try std.testing.expect(p.segs.items.len >= 4);
}
