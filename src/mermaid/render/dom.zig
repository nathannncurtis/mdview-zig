const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Box = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn unite(a: Box, b: Box) Box {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

pub const Attr = struct { name: []const u8, value: []const u8 };

pub fn fmtNum(a: Allocator, v: f64) Allocator.Error![]const u8 {
    if (v == 0) return "0";
    return std.fmt.allocPrint(a, "{d}", .{v});
}

pub const El = struct {
    a: Allocator,
    tag: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    kids: std.ArrayList(*El) = .empty,
    parent: ?*El = null,
    text: ?[]const u8 = null,
    box: ?Box = null,
    y_off: f64 = 0,

    pub fn create(a: Allocator, tag: []const u8) Allocator.Error!*El {
        const e = try a.create(El);
        e.* = .{ .a = a, .tag = tag };
        return e;
    }

    pub fn insert(self: *El, tag: []const u8) Allocator.Error!*El {
        const e = try create(self.a, tag);
        e.parent = self;
        try self.kids.append(self.a, e);
        return e;
    }

    pub fn insertFirst(self: *El, tag: []const u8) Allocator.Error!*El {
        const e = try create(self.a, tag);
        e.parent = self;
        try self.kids.insert(self.a, 0, e);
        return e;
    }

    pub fn append(self: *El, child: *El) Allocator.Error!void {
        child.parent = self;
        try self.kids.append(self.a, child);
    }

    pub fn detach(self: *El) void {
        const p = self.parent orelse return;
        for (p.kids.items, 0..) |k, i| if (k == self) {
            _ = p.kids.orderedRemove(i);
            break;
        };
        self.parent = null;
    }

    pub fn setAttr(self: *El, name: []const u8, value: []const u8) Allocator.Error!void {
        for (self.attrs.items) |*at| if (std.mem.eql(u8, at.name, name)) {
            at.value = value;
            return;
        };
        try self.attrs.append(self.a, .{ .name = name, .value = value });
    }

    pub fn attr(self: *El, name: []const u8, value: []const u8) Allocator.Error!*El {
        try self.setAttr(name, value);
        return self;
    }

    pub fn attrNum(self: *El, name: []const u8, v: f64) Allocator.Error!*El {
        try self.setAttr(name, try fmtNum(self.a, v));
        return self;
    }

    pub fn getAttr(self: *const El, name: []const u8) ?[]const u8 {
        for (self.attrs.items) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
        return null;
    }

    pub fn removeAttr(self: *El, name: []const u8) void {
        for (self.attrs.items, 0..) |at, i| if (std.mem.eql(u8, at.name, name)) {
            _ = self.attrs.orderedRemove(i);
            return;
        };
    }

    pub fn num(self: *const El, name: []const u8) f64 {
        const s = self.getAttr(name) orelse return 0;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch 0;
    }

    pub fn setText(self: *El, t: []const u8) Allocator.Error!void {
        self.text = try self.a.dupe(u8, t);
    }

    pub fn bbox(self: *const El) ?Box {
        const b = self.bboxRaw() orelse return null;
        return .{ .x = r32(b.x), .y = r32(b.y), .w = r32(b.w), .h = r32(b.h) };
    }

    fn bboxRaw(self: *const El) ?Box {
        if (self.box) |b| return if (b.w == 0 and b.h == 0) null else b;
        if (eq(self.tag, "rect") or eq(self.tag, "foreignObject") or eq(self.tag, "image"))
            return .{ .x = self.num("x"), .y = self.num("y"), .w = self.num("width"), .h = self.num("height") };
        if (eq(self.tag, "circle")) {
            const r = self.num("r");
            return .{ .x = self.num("cx") - r, .y = self.num("cy") - r, .w = 2 * r, .h = 2 * r };
        }
        if (eq(self.tag, "ellipse")) {
            const rx = self.num("rx");
            const ry = self.num("ry");
            return .{ .x = self.num("cx") - rx, .y = self.num("cy") - ry, .w = 2 * rx, .h = 2 * ry };
        }
        if (eq(self.tag, "line")) {
            const x1 = self.num("x1");
            const x2 = self.num("x2");
            const y1 = self.num("y1");
            const y2 = self.num("y2");
            return .{ .x = @min(x1, x2), .y = @min(y1, y2), .w = @abs(x2 - x1), .h = @abs(y2 - y1) };
        }
        if (eq(self.tag, "polygon") or eq(self.tag, "polyline")) return pointsBox(self.getAttr("points") orelse return null);
        if (eq(self.tag, "path")) return pathBox(self.getAttr("d") orelse return null);
        if (eq(self.tag, "g") or eq(self.tag, "a") or eq(self.tag, "svg") or eq(self.tag, "text") or eq(self.tag, "tspan")) {
            var acc: ?Box = null;
            for (self.kids.items) |k| {
                var b = k.bbox() orelse continue;
                if (k.getAttr("transform")) |t| b = applyTransform(t, b);
                acc = if (acc) |c| c.unite(b) else b;
            }
            return acc;
        }
        return null;
    }
};

pub fn r32(v: f64) f64 {
    return @as(f64, @floatCast(@as(f32, @floatCast(v))));
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nextNum(s: []const u8, i: *usize) ?f64 {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == ',' or s[i.*] == '\t' or s[i.*] == '\n')) i.* += 1;
    if (i.* >= s.len) return null;
    const st = i.*;
    var j = st;
    if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
    var dot = false;
    var ex = false;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (c >= '0' and c <= '9') continue;
        if (c == '.' and !dot and !ex) {
            dot = true;
            continue;
        }
        if ((c == 'e' or c == 'E') and !ex and j > st) {
            ex = true;
            if (j + 1 < s.len and (s[j + 1] == '-' or s[j + 1] == '+')) j += 1;
            continue;
        }
        break;
    }
    if (j == st) return null;
    i.* = j;
    return std.fmt.parseFloat(f64, s[st..j]) catch null;
}

const Acc = struct {
    has: bool = false,
    x0: f64 = 0,
    y0: f64 = 0,
    x1: f64 = 0,
    y1: f64 = 0,

    fn add(self: *Acc, x: f64, y: f64) void {
        if (!self.has) {
            self.* = .{ .has = true, .x0 = x, .y0 = y, .x1 = x, .y1 = y };
            return;
        }
        self.x0 = @min(self.x0, x);
        self.y0 = @min(self.y0, y);
        self.x1 = @max(self.x1, x);
        self.y1 = @max(self.y1, y);
    }

    fn box(self: Acc) ?Box {
        if (!self.has) return null;
        return .{ .x = self.x0, .y = self.y0, .w = self.x1 - self.x0, .h = self.y1 - self.y0 };
    }
};

fn pointsBox(s: []const u8) ?Box {
    var acc: Acc = .{};
    var i: usize = 0;
    while (nextNum(s, &i)) |x| {
        const y = nextNum(s, &i) orelse break;
        acc.add(x, y);
    }
    return acc.box();
}

fn cubicAxis(p0: f64, p1: f64, p2: f64, p3: f64, acc: *Acc, comptime axis_x: bool, other: [4]f64) void {
    const a = 3 * (-p0 + 3 * p1 - 3 * p2 + p3);
    const b = 2 * (3 * p0 - 6 * p1 + 3 * p2);
    const c = -3 * p0 + 3 * p1;
    var ts: [2]f64 = undefined;
    var n: usize = 0;
    if (@abs(a) < 1e-12) {
        if (@abs(b) > 1e-12) {
            ts[0] = -c / b;
            n = 1;
        }
    } else {
        const d = b * b - 4 * a * c;
        if (d >= 0) {
            const sq = @sqrt(d);
            ts[0] = (-b + sq) / (2 * a);
            ts[1] = (-b - sq) / (2 * a);
            n = 2;
        }
    }
    for (ts[0..n]) |t| {
        if (t <= 0 or t >= 1) continue;
        const mt = 1 - t;
        const v = mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3;
        const o = mt * mt * mt * other[0] + 3 * mt * mt * t * other[1] + 3 * mt * t * t * other[2] + t * t * t * other[3];
        if (axis_x) acc.add(v, o) else acc.add(o, v);
    }
}

fn cubicBounds(acc: *Acc, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) void {
    acc.add(x0, y0);
    acc.add(x3, y3);
    cubicAxis(x0, x1, x2, x3, acc, true, .{ y0, y1, y2, y3 });
    cubicAxis(y0, y1, y2, y3, acc, false, .{ x0, x1, x2, x3 });
}

fn arcBounds(acc: *Acc, x1: f64, y1: f64, rx0: f64, ry0: f64, phi_deg: f64, fa: bool, fs: bool, x2: f64, y2: f64) void {
    acc.add(x1, y1);
    acc.add(x2, y2);
    var rx = @abs(rx0);
    var ry = @abs(ry0);
    if (rx == 0 or ry == 0 or (x1 == x2 and y1 == y2)) return;
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
    const numr = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co: f64 = if (den == 0) 0 else @sqrt(@max(0, numr / den));
    if (fa == fs) co = -co;
    const cxp = co * rx * y1p / ry;
    const cyp = -co * ry * x1p / rx;
    const cx = cp * cxp - sp * cyp + (x1 + x2) / 2;
    const cy = sp * cxp + cp * cyp + (y1 + y2) / 2;
    const th1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
    const th2 = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx);
    var dth = th2 - th1;
    if (fs and dth < 0) dth += 2 * std.math.pi;
    if (!fs and dth > 0) dth -= 2 * std.math.pi;
    const tx = std.math.atan2(-ry * sp, rx * cp);
    const ty = std.math.atan2(ry * cp, rx * sp);
    const cands = [4]f64{ tx, tx + std.math.pi, ty, ty + std.math.pi };
    for (cands) |c| {
        var t = c - th1;
        if (dth >= 0) {
            while (t < 0) t += 2 * std.math.pi;
            while (t > 2 * std.math.pi) t -= 2 * std.math.pi;
            if (t > dth) continue;
        } else {
            while (t > 0) t -= 2 * std.math.pi;
            while (t < -2 * std.math.pi) t += 2 * std.math.pi;
            if (t < dth) continue;
        }
        const th = th1 + t;
        const ex = rx * @cos(th);
        const ey = ry * @sin(th);
        acc.add(cp * ex - sp * ey + cx, sp * ex + cp * ey + cy);
    }
}

pub fn pathBox(d: []const u8) ?Box {
    var acc: Acc = .{};
    var i: usize = 0;
    var cmd: u8 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var lcx: f64 = 0;
    var lcy: f64 = 0;
    var prev: u8 = 0;
    while (true) {
        while (i < d.len and (d[i] == ' ' or d[i] == ',' or d[i] == '\t' or d[i] == '\n')) i += 1;
        if (i >= d.len) break;
        if (std.ascii.isAlphabetic(d[i]) and d[i] != 'e' and d[i] != 'E') {
            cmd = d[i];
            i += 1;
            if (cmd == 'Z' or cmd == 'z') {
                cx = sx;
                cy = sy;
                prev = 'z';
                continue;
            }
        } else if (cmd == 0) return null;
        const rel = std.ascii.isLower(cmd);
        const ox: f64 = if (rel) cx else 0;
        const oy: f64 = if (rel) cy else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                cx = x;
                cy = y;
                sx = x;
                sy = y;
                acc.add(x, y);
                cmd = if (rel) 'l' else 'L';
                prev = 'M';
            },
            'L' => {
                cx = (nextNum(d, &i) orelse break) + ox;
                cy = (nextNum(d, &i) orelse break) + oy;
                acc.add(cx, cy);
                prev = 'L';
            },
            'H' => {
                cx = (nextNum(d, &i) orelse break) + ox;
                acc.add(cx, cy);
                prev = 'L';
            },
            'V' => {
                cy = (nextNum(d, &i) orelse break) + oy;
                acc.add(cx, cy);
                prev = 'L';
            },
            'C' => {
                const x1 = (nextNum(d, &i) orelse break) + ox;
                const y1 = (nextNum(d, &i) orelse break) + oy;
                const x2 = (nextNum(d, &i) orelse break) + ox;
                const y2 = (nextNum(d, &i) orelse break) + oy;
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                cubicBounds(&acc, cx, cy, x1, y1, x2, y2, x, y);
                lcx = x2;
                lcy = y2;
                cx = x;
                cy = y;
                prev = 'C';
            },
            'S' => {
                const x2 = (nextNum(d, &i) orelse break) + ox;
                const y2 = (nextNum(d, &i) orelse break) + oy;
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                const x1 = if (prev == 'C') 2 * cx - lcx else cx;
                const y1 = if (prev == 'C') 2 * cy - lcy else cy;
                cubicBounds(&acc, cx, cy, x1, y1, x2, y2, x, y);
                lcx = x2;
                lcy = y2;
                cx = x;
                cy = y;
                prev = 'C';
            },
            'Q' => {
                const x1 = (nextNum(d, &i) orelse break) + ox;
                const y1 = (nextNum(d, &i) orelse break) + oy;
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                quadBounds(&acc, cx, cy, x1, y1, x, y);
                lcx = x1;
                lcy = y1;
                cx = x;
                cy = y;
                prev = 'Q';
            },
            'T' => {
                const x = (nextNum(d, &i) orelse break) + ox;
                const y = (nextNum(d, &i) orelse break) + oy;
                const x1 = if (prev == 'Q') 2 * cx - lcx else cx;
                const y1 = if (prev == 'Q') 2 * cy - lcy else cy;
                quadBounds(&acc, cx, cy, x1, y1, x, y);
                lcx = x1;
                lcy = y1;
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
                arcBounds(&acc, cx, cy, rx, ry, rot, fa, fs, x, y);
                cx = x;
                cy = y;
                prev = 'A';
            },
            else => return null,
        }
    }
    return acc.box();
}

fn flag(s: []const u8, i: *usize) ?bool {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == ',')) i.* += 1;
    if (i.* >= s.len) return null;
    const c = s[i.*];
    if (c != '0' and c != '1') return null;
    i.* += 1;
    return c == '1';
}

fn quadBounds(acc: *Acc, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64) void {
    acc.add(x0, y0);
    acc.add(x2, y2);
    const dxs = [2]f64{ x0 - 2 * x1 + x2, y0 - 2 * y1 + y2 };
    if (dxs[0] != 0) {
        const t = (x0 - x1) / dxs[0];
        if (t > 0 and t < 1) acc.add(qpt(x0, x1, x2, t), qpt(y0, y1, y2, t));
    }
    if (dxs[1] != 0) {
        const t = (y0 - y1) / dxs[1];
        if (t > 0 and t < 1) acc.add(qpt(x0, x1, x2, t), qpt(y0, y1, y2, t));
    }
}

fn qpt(p0: f64, p1: f64, p2: f64, t: f64) f64 {
    const m = 1 - t;
    return m * m * p0 + 2 * m * t * p1 + t * t * p2;
}

pub fn applyTransform(t: []const u8, b: Box) Box {
    var m = [6]f64{ 1, 0, 0, 1, 0, 0 };
    var i: usize = 0;
    while (i < t.len) {
        while (i < t.len and (t[i] == ' ' or t[i] == ',')) i += 1;
        const st = i;
        while (i < t.len and t[i] != '(') i += 1;
        if (i >= t.len) break;
        const name = std.mem.trim(u8, t[st..i], " ");
        i += 1;
        var args: [6]f64 = @splat(0);
        var n: usize = 0;
        while (n < 6) {
            const v = nextNum(t, &i) orelse break;
            args[n] = v;
            n += 1;
        }
        while (i < t.len and t[i] != ')') i += 1;
        i += 1;
        var op = [6]f64{ 1, 0, 0, 1, 0, 0 };
        if (eq(name, "translate")) {
            op[4] = args[0];
            op[5] = if (n > 1) args[1] else 0;
        } else if (eq(name, "scale")) {
            op[0] = args[0];
            op[3] = if (n > 1) args[1] else args[0];
        } else if (eq(name, "rotate")) {
            const r = args[0] * std.math.pi / 180.0;
            const c = @cos(r);
            const s = @sin(r);
            op = .{ c, s, -s, c, 0, 0 };
            if (n == 3) {
                op[4] = args[1] - c * args[1] + s * args[2];
                op[5] = args[2] - s * args[1] - c * args[2];
            }
        } else if (eq(name, "matrix") and n == 6) {
            op = args;
        }
        m = mul(m, op);
    }
    const xs = [4]f64{ b.x, b.x + b.w, b.x, b.x + b.w };
    const ys = [4]f64{ b.y, b.y, b.y + b.h, b.y + b.h };
    var acc: Acc = .{};
    for (0..4) |k| acc.add(m[0] * xs[k] + m[2] * ys[k] + m[4], m[1] * xs[k] + m[3] * ys[k] + m[5]);
    return acc.box().?;
}

fn mul(a: [6]f64, b: [6]f64) [6]f64 {
    return .{
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    };
}

pub fn escape(out: *std.ArrayList(u8), a: Allocator, s: []const u8, quote: bool) Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => if (quote) try out.appendSlice(a, "&quot;") else try out.append(a, c),
        else => try out.append(a, c),
    };
}

pub fn serialize(out: *std.ArrayList(u8), a: Allocator, e: *const El) Allocator.Error!void {
    try out.append(a, '<');
    try out.appendSlice(a, e.tag);
    for (e.attrs.items) |at| {
        try out.append(a, ' ');
        try out.appendSlice(a, at.name);
        try out.appendSlice(a, "=\"");
        try escape(out, a, at.value, true);
        try out.append(a, '"');
    }
    if (e.kids.items.len == 0 and e.text == null) {
        try out.appendSlice(a, "/>");
        return;
    }
    try out.append(a, '>');
    if (e.text) |t| {
        if (eq(e.tag, "style")) try out.appendSlice(a, t) else try escape(out, a, t, false);
    }
    for (e.kids.items) |k| try serialize(out, a, k);
    try out.appendSlice(a, "</");
    try out.appendSlice(a, e.tag);
    try out.append(a, '>');
}

test "path bbox covers curve extrema and arcs" {
    const b = pathBox("M0,0 C0,10 10,10 10,0").?;
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), b.h, 1e-9);
    const c = pathBox("M0,0 A5,5 0 0,1 10,0").?;
    try std.testing.expectApproxEqAbs(@as(f64, 5), c.h, 1e-9);
}

test "bbox of group applies translate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = try El.create(arena.allocator(), "g");
    const r = try g.insert("g");
    try r.setAttr("transform", "translate(10, 20)");
    const rect = try r.insert("rect");
    _ = try (try rect.attrNum("width", 4)).attrNum("height", 6);
    const b = g.bbox().?;
    try std.testing.expectEqual(@as(f64, 10), b.x);
    try std.testing.expectEqual(@as(f64, 26), b.y + b.h);
}
