const std = @import("std");
const read = @import("read.zig");
const path_mod = @import("path.zig");

const Error = read.Error;
const Mat = path_mod.Mat;

const max_stack = 48;
const max_ops = 200_000;
const max_depth = 10;

const Index = struct {
    count: usize = 0,
    off_size: usize = 0,
    offsets: usize = 0,
    base: usize = 0,
    end: usize = 0,

    fn parse(d: []const u8, at: usize) Error!Index {
        const count: usize = try read.u16At(d, at);
        if (count == 0) return .{ .end = at + 2 };
        if (at + 2 >= d.len) return error.Corrupt;
        const off_size: usize = d[at + 2];
        if (off_size < 1 or off_size > 4) return error.Corrupt;
        const offsets = at + 3;
        const base = offsets + (count + 1) * off_size - 1;
        var idx: Index = .{ .count = count, .off_size = off_size, .offsets = offsets, .base = base };
        idx.end = base + try idx.offset(d, count);
        if (idx.end > d.len) return error.Corrupt;
        return idx;
    }

    fn offset(i: Index, d: []const u8, n: usize) Error!usize {
        const at = i.offsets + n * i.off_size;
        if (at + i.off_size > d.len) return error.Corrupt;
        var v: usize = 0;
        for (d[at..][0..i.off_size]) |b| v = (v << 8) | b;
        return v;
    }

    fn get(i: Index, d: []const u8, n: usize) Error![]const u8 {
        if (n >= i.count) return error.Corrupt;
        const a = i.base + try i.offset(d, n);
        const b = i.base + try i.offset(d, n + 1);
        if (b < a or b > d.len) return error.Corrupt;
        return d[a..b];
    }
};

pub const Cff = struct {
    data: []const u8,
    charstrings: Index,
    gsubrs: Index,
    lsubrs: Index,
    num_glyphs: usize,

    pub fn init(d: []const u8, table: usize) Error!Cff {
        if (table + 4 > d.len) return error.Corrupt;
        const hdr: usize = d[table + 2];
        const names = try Index.parse(d, table + hdr);
        const tops = try Index.parse(d, names.end);
        const strings = try Index.parse(d, tops.end);
        const gsubrs = try Index.parse(d, strings.end);
        const top = try tops.get(d, 0);
        var cs_off: ?usize = null;
        var priv: ?[2]usize = null;
        var stack: [max_stack]f64 = undefined;
        var sp: usize = 0;
        var p: usize = 0;
        while (p < top.len) {
            const b = top[p];
            if (b <= 21) {
                var op: u16 = b;
                p += 1;
                if (b == 12) {
                    if (p >= top.len) return error.Corrupt;
                    op = 0x0c00 | @as(u16, top[p]);
                    p += 1;
                }
                switch (op) {
                    17 => if (sp >= 1) {
                        cs_off = @intFromFloat(@max(0, stack[sp - 1]));
                    },
                    18 => if (sp >= 2) {
                        priv = .{ @intFromFloat(@max(0, stack[sp - 2])), @intFromFloat(@max(0, stack[sp - 1])) };
                    },
                    0x0c1e, 0x0c24, 0x0c25 => return error.Unsupported,
                    else => {},
                }
                sp = 0;
                continue;
            }
            const r = try dictNumber(top, p);
            p = r.next;
            if (sp == max_stack) return error.Corrupt;
            stack[sp] = r.v;
            sp += 1;
        }
        var lsubrs: Index = .{};
        if (priv) |pr| {
            if (table + pr[1] > d.len) return error.Corrupt;
            const pd = d[table + pr[1] ..][0..@min(pr[0], d.len - table - pr[1])];
            var q: usize = 0;
            sp = 0;
            while (q < pd.len) {
                const b = pd[q];
                if (b <= 21) {
                    q += 1;
                    if (b == 12) q += 1;
                    if (b == 19 and sp >= 1) lsubrs = try Index.parse(d, table + pr[1] + @as(usize, @intFromFloat(@max(0, stack[sp - 1]))));
                    sp = 0;
                    continue;
                }
                const r = try dictNumber(pd, q);
                q = r.next;
                if (sp == max_stack) return error.Corrupt;
                stack[sp] = r.v;
                sp += 1;
            }
        }
        const cs = try Index.parse(d, table + (cs_off orelse return error.Corrupt));
        return .{ .data = d, .charstrings = cs, .gsubrs = gsubrs, .lsubrs = lsubrs, .num_glyphs = cs.count };
    }

    pub fn outline(c: *const Cff, alloc: std.mem.Allocator, g: u16, m: Mat, sink: anytype) Error!void {
        const code = try c.charstrings.get(c.data, g);
        var it: Interp(@TypeOf(sink)) = .{ .c = c, .alloc = alloc, .m = m, .sink = sink };
        _ = try it.run(code, 0);
        if (it.open) try sink.close(alloc);
    }
};

const Num = struct { v: f64, next: usize };

fn dictNumber(d: []const u8, p: usize) Error!Num {
    if (p >= d.len) return error.Corrupt;
    const b: i32 = d[p];
    switch (b) {
        28 => return .{ .v = @floatFromInt(try read.i16At(d, p + 1)), .next = p + 3 },
        29 => return .{ .v = @floatFromInt(@as(i32, @bitCast(try read.u32At(d, p + 1)))), .next = p + 5 },
        30 => {
            var q = p + 1;
            while (q < d.len and d[q] & 0x0f != 0x0f and d[q] >> 4 != 0x0f) q += 1;
            return .{ .v = 0, .next = q + 1 };
        },
        32...246 => return .{ .v = @floatFromInt(b - 139), .next = p + 1 },
        247...250 => {
            if (p + 1 >= d.len) return error.Corrupt;
            return .{ .v = @floatFromInt((b - 247) * 256 + @as(i32, d[p + 1]) + 108), .next = p + 2 };
        },
        251...254 => {
            if (p + 1 >= d.len) return error.Corrupt;
            return .{ .v = @floatFromInt(-(b - 251) * 256 - @as(i32, d[p + 1]) - 108), .next = p + 2 };
        },
        else => return error.Corrupt,
    }
}

fn bias(n: usize) usize {
    return if (n < 1240) 107 else if (n < 33900) 1131 else 32768;
}

fn Interp(comptime Sink: type) type {
    return struct {
        c: *const Cff,
        alloc: std.mem.Allocator,
        m: Mat,
        sink: Sink,
        stack: [max_stack]f64 = @splat(0),
        sp: usize = 0,
        x: f64 = 0,
        y: f64 = 0,
        open: bool = false,
        have_width: bool = false,
        stems: usize = 0,
        ops: usize = 0,

        const Self = @This();

        fn pt(s: *Self, x: f64, y: f64) path_mod.Pt {
            return s.m.apply(.{ .x = x, .y = y });
        }

        fn moveTo(s: *Self, dx: f64, dy: f64) Error!void {
            if (s.open) try s.sink.close(s.alloc);
            s.x += dx;
            s.y += dy;
            const p = s.pt(s.x, s.y);
            try s.sink.moveTo(s.alloc, p.x, p.y);
            s.open = true;
        }

        fn lineTo(s: *Self, dx: f64, dy: f64) Error!void {
            if (!s.open) return error.Corrupt;
            s.x += dx;
            s.y += dy;
            const p = s.pt(s.x, s.y);
            try s.sink.lineTo(s.alloc, p.x, p.y);
        }

        fn curveTo(s: *Self, d1x: f64, d1y: f64, d2x: f64, d2y: f64, d3x: f64, d3y: f64) Error!void {
            if (!s.open) return error.Corrupt;
            const x1 = s.x + d1x;
            const y1 = s.y + d1y;
            const x2 = x1 + d2x;
            const y2 = y1 + d2y;
            s.x = x2 + d3x;
            s.y = y2 + d3y;
            const a = s.pt(x1, y1);
            const b = s.pt(x2, y2);
            const e = s.pt(s.x, s.y);
            try s.sink.cubicTo(s.alloc, a.x, a.y, b.x, b.y, e.x, e.y);
        }

        fn dropWidth(s: *Self, extra: bool) void {
            if (s.have_width) return;
            s.have_width = true;
            if (extra and s.sp > 0) {
                std.mem.copyForwards(f64, s.stack[0 .. s.sp - 1], s.stack[1..s.sp]);
                s.sp -= 1;
            }
        }

        fn run(s: *Self, code: []const u8, depth: u32) Error!bool {
            if (depth > max_depth) return error.Corrupt;
            var p: usize = 0;
            while (p < code.len) {
                s.ops += 1;
                if (s.ops > max_ops) return error.TooLarge;
                const b: i32 = code[p];
                if (b >= 32 or b == 28) {
                    const r: Num = if (b == 255) .{
                        .v = @as(f64, @floatFromInt(@as(i32, @bitCast(try read.u32At(code, p + 1))))) / 65536.0,
                        .next = p + 5,
                    } else try dictNumber(code, p);
                    if (s.sp == max_stack) return error.Corrupt;
                    s.stack[s.sp] = r.v;
                    s.sp += 1;
                    p = r.next;
                    continue;
                }
                p += 1;
                const a = s.stack[0..s.sp];
                switch (b) {
                    1, 3, 18, 23 => {
                        s.dropWidth(a.len % 2 == 1);
                        s.stems += s.sp / 2;
                        s.sp = 0;
                    },
                    19, 20 => {
                        s.dropWidth(a.len % 2 == 1);
                        s.stems += s.sp / 2;
                        s.sp = 0;
                        p += (s.stems + 7) / 8;
                    },
                    21 => {
                        s.dropWidth(a.len > 2);
                        if (s.sp < 2) return error.Corrupt;
                        try s.moveTo(s.stack[s.sp - 2], s.stack[s.sp - 1]);
                        s.sp = 0;
                    },
                    22 => {
                        s.dropWidth(a.len > 1);
                        if (s.sp < 1) return error.Corrupt;
                        try s.moveTo(s.stack[s.sp - 1], 0);
                        s.sp = 0;
                    },
                    4 => {
                        s.dropWidth(a.len > 1);
                        if (s.sp < 1) return error.Corrupt;
                        try s.moveTo(0, s.stack[s.sp - 1]);
                        s.sp = 0;
                    },
                    5 => {
                        var i: usize = 0;
                        while (i + 2 <= s.sp) : (i += 2) try s.lineTo(a[i], a[i + 1]);
                        s.sp = 0;
                    },
                    6, 7 => {
                        var horiz = b == 6;
                        for (a) |v| {
                            if (horiz) try s.lineTo(v, 0) else try s.lineTo(0, v);
                            horiz = !horiz;
                        }
                        s.sp = 0;
                    },
                    8 => {
                        var i: usize = 0;
                        while (i + 6 <= s.sp) : (i += 6) try s.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                        s.sp = 0;
                    },
                    24 => {
                        var i: usize = 0;
                        while (i + 8 <= s.sp) : (i += 6) try s.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                        if (i + 2 <= s.sp) try s.lineTo(a[i], a[i + 1]);
                        s.sp = 0;
                    },
                    25 => {
                        var i: usize = 0;
                        while (i + 8 <= s.sp) : (i += 2) try s.lineTo(a[i], a[i + 1]);
                        if (i + 6 <= s.sp) try s.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                        s.sp = 0;
                    },
                    26 => {
                        var i: usize = 0;
                        var dx1: f64 = 0;
                        if (a.len % 4 == 1) {
                            dx1 = a[0];
                            i = 1;
                        }
                        while (i + 4 <= s.sp) : (i += 4) {
                            try s.curveTo(dx1, a[i], a[i + 1], a[i + 2], 0, a[i + 3]);
                            dx1 = 0;
                        }
                        s.sp = 0;
                    },
                    27 => {
                        var i: usize = 0;
                        var dy1: f64 = 0;
                        if (a.len % 4 == 1) {
                            dy1 = a[0];
                            i = 1;
                        }
                        while (i + 4 <= s.sp) : (i += 4) {
                            try s.curveTo(a[i], dy1, a[i + 1], a[i + 2], a[i + 3], 0);
                            dy1 = 0;
                        }
                        s.sp = 0;
                    },
                    30, 31 => {
                        var horiz = b == 31;
                        var i: usize = 0;
                        while (i + 4 <= s.sp) : (i += 4) {
                            const last: f64 = if (s.sp - i == 5) a[i + 4] else 0;
                            if (horiz) try s.curveTo(a[i], 0, a[i + 1], a[i + 2], last, a[i + 3]) else try s.curveTo(0, a[i], a[i + 1], a[i + 2], a[i + 3], last);
                            horiz = !horiz;
                        }
                        s.sp = 0;
                    },
                    10, 29 => {
                        if (s.sp < 1) return error.Corrupt;
                        s.sp -= 1;
                        const idx = if (b == 10) s.c.lsubrs else s.c.gsubrs;
                        const n: i64 = @as(i64, @intFromFloat(s.stack[s.sp])) + @as(i64, @intCast(bias(idx.count)));
                        if (n < 0) return error.Corrupt;
                        if (try s.run(try idx.get(s.c.data, @intCast(n)), depth + 1)) return true;
                    },
                    11 => return false,
                    14 => {
                        s.dropWidth(a.len == 1 or a.len == 5);
                        return true;
                    },
                    12 => {
                        if (p >= code.len) return error.Corrupt;
                        const e = code[p];
                        p += 1;
                        switch (e) {
                            34 => if (s.sp >= 7) {
                                try s.curveTo(a[0], 0, a[1], a[2], a[3], 0);
                                try s.curveTo(a[4], 0, a[5], -a[2], a[6], 0);
                            },
                            35 => if (s.sp >= 12) {
                                try s.curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
                                try s.curveTo(a[6], a[7], a[8], a[9], a[10], a[11]);
                            },
                            36 => if (s.sp >= 9) {
                                try s.curveTo(a[0], a[1], a[2], a[3], a[4], 0);
                                try s.curveTo(a[5], 0, a[6], a[7], a[8], -(a[1] + a[3] + a[7]));
                            },
                            37 => if (s.sp >= 11) {
                                const dx = a[0] + a[2] + a[4] + a[6] + a[8];
                                const dy = a[1] + a[3] + a[5] + a[7] + a[9];
                                try s.curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
                                if (@abs(dx) > @abs(dy)) {
                                    try s.curveTo(a[6], a[7], a[8], a[9], a[10], -dy);
                                } else try s.curveTo(a[6], a[7], a[8], a[9], -dx, a[10]);
                            },
                            else => return error.Unsupported,
                        }
                        s.sp = 0;
                    },
                    else => return error.Unsupported,
                }
            }
            return false;
        }
    };
}
