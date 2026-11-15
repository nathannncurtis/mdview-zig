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

const DictInfo = struct {
    charset: usize = 0,
    charstrings: ?usize = null,
    private: ?[2]usize = null,
    subrs: ?usize = null,
    fd_array: ?usize = null,
    fd_select: ?usize = null,
    cid: bool = false,
};

fn parseDict(dict: []const u8) Error!DictInfo {
    var info: DictInfo = .{};
    var stack: [max_stack]f64 = @splat(0);
    var sp: usize = 0;
    var p: usize = 0;
    while (p < dict.len) {
        const b = dict[p];
        if (b > 21) {
            const r = try dictNumber(dict, p);
            p = r.next;
            if (sp == max_stack) return error.Corrupt;
            stack[sp] = r.v;
            sp += 1;
            continue;
        }
        var op: u16 = b;
        p += 1;
        if (b == 12) {
            if (p >= dict.len) return error.Corrupt;
            op = 0x0c00 | @as(u16, dict[p]);
            p += 1;
        }
        const last: usize = if (sp >= 1) @intFromFloat(@max(0, stack[sp - 1])) else 0;
        switch (op) {
            15 => info.charset = last,
            17 => info.charstrings = last,
            18 => if (sp >= 2) {
                info.private = .{ @intFromFloat(@max(0, stack[sp - 2])), last };
            },
            19 => info.subrs = last,
            0x0c1e => info.cid = true,
            0x0c24 => info.fd_array = last,
            0x0c25 => info.fd_select = last,
            else => {},
        }
        sp = 0;
    }
    return info;
}

pub const Cff = struct {
    data: []const u8,
    table: usize,
    charstrings: Index,
    gsubrs: Index,
    lsubrs: Index,
    fd_array: Index,
    fd_select: usize,
    charset: usize,
    num_glyphs: usize,

    fn privateSubrs(d: []const u8, table: usize, size: usize, off: usize) Error!Index {
        if (table + off > d.len) return error.Corrupt;
        const pd = d[table + off ..][0..@min(size, d.len - table - off)];
        const info = try parseDict(pd);
        const subrs = info.subrs orelse return .{};
        return Index.parse(d, table + off + subrs);
    }

    pub fn init(d: []const u8, table: usize) Error!Cff {
        if (table + 4 > d.len) return error.Corrupt;
        const hdr: usize = d[table + 2];
        const names = try Index.parse(d, table + hdr);
        const tops = try Index.parse(d, names.end);
        const strings = try Index.parse(d, tops.end);
        const gsubrs = try Index.parse(d, strings.end);
        const top = try parseDict(try tops.get(d, 0));
        const cs = try Index.parse(d, table + (top.charstrings orelse return error.Corrupt));
        var c: Cff = .{
            .data = d,
            .table = table,
            .charstrings = cs,
            .gsubrs = gsubrs,
            .lsubrs = .{},
            .fd_array = .{},
            .fd_select = 0,
            .charset = top.charset,
            .num_glyphs = cs.count,
        };
        if (top.cid) {
            c.fd_array = try Index.parse(d, table + (top.fd_array orelse return error.Corrupt));
            c.fd_select = table + (top.fd_select orelse return error.Corrupt);
            if (c.fd_array.count == 0) return error.Corrupt;
        } else if (top.private) |pr| {
            c.lsubrs = try privateSubrs(d, table, pr[0], pr[1]);
        }
        return c;
    }

    fn fdOf(c: *const Cff, g: u16) Error!usize {
        const d = c.data;
        if (c.fd_select >= d.len) return error.Corrupt;
        const fmt = d[c.fd_select];
        if (fmt == 0) {
            if (c.fd_select + 1 + g >= d.len) return error.Corrupt;
            return d[c.fd_select + 1 + g];
        }
        if (fmt != 3) return error.Unsupported;
        const n = try read.u16At(d, c.fd_select + 1);
        var fd: usize = 0;
        for (0..n) |i| {
            const at = c.fd_select + 3 + i * 3;
            if (at + 3 > d.len) return error.Corrupt;
            if ((try read.u16At(d, at)) > g) break;
            fd = d[at + 2];
        }
        return fd;
    }

    fn localSubrs(c: *const Cff, g: u16) Error!Index {
        if (c.fd_array.count == 0) return c.lsubrs;
        const dict = try c.fd_array.get(c.data, try c.fdOf(g));
        const info = try parseDict(dict);
        const pr = info.private orelse return .{};
        return privateSubrs(c.data, c.table, pr[0], pr[1]);
    }

    fn gidForSid(c: *const Cff, sid: u16) ?u16 {
        if (c.charset <= 2) {
            return if (c.charset == 0 and sid <= 228 and sid < c.num_glyphs) sid else null;
        }
        const d = c.data;
        var p = c.table + c.charset;
        if (p >= d.len) return null;
        const fmt = d[p];
        p += 1;
        var gid: usize = 1;
        while (gid < c.num_glyphs) {
            if (fmt == 0) {
                if ((read.u16At(d, p) catch return null) == sid) return @intCast(gid);
                p += 2;
                gid += 1;
                continue;
            }
            const first = read.u16At(d, p) catch return null;
            const left: usize = if (fmt == 1) (if (p + 2 < d.len) d[p + 2] else return null) else (read.u16At(d, p + 2) catch return null);
            p += if (fmt == 1) 3 else 4;
            if (sid >= first and sid - first <= left) return @intCast(gid + (sid - first));
            gid += left + 1;
        }
        return null;
    }

    pub fn outline(c: *const Cff, alloc: std.mem.Allocator, g: u16, m: Mat, sink: anytype) Error!void {
        try c.outlineDepth(alloc, g, m, sink, 0);
    }

    fn outlineDepth(c: *const Cff, alloc: std.mem.Allocator, g: u16, m: Mat, sink: anytype, depth: u32) Error!void {
        const code = try c.charstrings.get(c.data, g);
        var it: Interp(@TypeOf(sink)) = .{ .c = c, .alloc = alloc, .m = m, .sink = sink, .lsubrs = try c.localSubrs(g), .seac_depth = depth };
        _ = try it.run(code, 0);
        if (it.open) try sink.close(alloc);
    }
};

const std_high = [_][2]u16{
    .{ 161, 96 },  .{ 162, 97 },  .{ 163, 98 },  .{ 164, 99 },  .{ 165, 100 }, .{ 166, 101 }, .{ 167, 102 }, .{ 168, 103 },
    .{ 169, 104 }, .{ 170, 105 }, .{ 171, 106 }, .{ 172, 107 }, .{ 173, 108 }, .{ 174, 109 }, .{ 175, 110 }, .{ 177, 111 },
    .{ 178, 112 }, .{ 179, 113 }, .{ 180, 114 }, .{ 182, 115 }, .{ 183, 116 }, .{ 184, 117 }, .{ 185, 118 }, .{ 186, 119 },
    .{ 187, 120 }, .{ 188, 121 }, .{ 189, 122 }, .{ 191, 123 }, .{ 193, 124 }, .{ 194, 125 }, .{ 195, 126 }, .{ 196, 127 },
    .{ 197, 128 }, .{ 198, 129 }, .{ 199, 130 }, .{ 200, 131 }, .{ 202, 132 }, .{ 203, 133 }, .{ 205, 134 }, .{ 206, 135 },
    .{ 207, 136 }, .{ 208, 137 }, .{ 225, 138 }, .{ 227, 139 }, .{ 232, 140 }, .{ 233, 141 }, .{ 234, 142 }, .{ 235, 143 },
    .{ 241, 144 }, .{ 245, 145 }, .{ 248, 146 }, .{ 249, 147 }, .{ 250, 148 }, .{ 251, 149 },
};

fn standardSid(code: f64) ?u16 {
    if (code < 0 or code > 255) return null;
    const k: u16 = @intFromFloat(code);
    if (k >= 32 and k <= 126) return k - 31;
    for (std_high) |e| if (e[0] == k) return e[1];
    return null;
}

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
        lsubrs: Index,
        seac_depth: u32,
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

        fn seac(s: *Self) Error!void {
            if (s.seac_depth >= 2) return error.Corrupt;
            const adx = s.stack[s.sp - 4];
            const ady = s.stack[s.sp - 3];
            const base = s.c.gidForSid(standardSid(s.stack[s.sp - 2]) orelse return error.Corrupt) orelse return error.Corrupt;
            const accent = s.c.gidForSid(standardSid(s.stack[s.sp - 1]) orelse return error.Corrupt) orelse return error.Corrupt;
            if (s.open) {
                try s.sink.close(s.alloc);
                s.open = false;
            }
            try s.c.outlineDepth(s.alloc, base, s.m, s.sink, s.seac_depth + 1);
            try s.c.outlineDepth(s.alloc, accent, s.m.mul(.{ .e = adx, .f = ady }), s.sink, s.seac_depth + 1);
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
                        const idx = if (b == 10) s.lsubrs else s.c.gsubrs;
                        const n: i64 = @as(i64, @intFromFloat(s.stack[s.sp])) + @as(i64, @intCast(bias(idx.count)));
                        if (n < 0) return error.Corrupt;
                        if (try s.run(try idx.get(s.c.data, @intCast(n)), depth + 1)) return true;
                    },
                    11 => return false,
                    14 => {
                        s.dropWidth(a.len == 1 or a.len == 5);
                        if (s.sp >= 4) try s.seac();
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

fn testIndex(a: std.mem.Allocator, objs: []const []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, &.{ 0, @intCast(objs.len) });
    if (objs.len == 0) return b.items;
    try b.append(a, 1);
    var off: usize = 1;
    try b.append(a, @intCast(off));
    for (objs) |o| {
        off += o.len;
        try b.append(a, @intCast(off));
    }
    for (objs) |o| try b.appendSlice(a, o);
    return b.items;
}

fn testInt(b: *std.ArrayList(u8), a: std.mem.Allocator, v: usize) !void {
    var t: [4]u8 = undefined;
    std.mem.writeInt(u32, &t, @intCast(v), .big);
    try b.append(a, 29);
    try b.appendSlice(a, &t);
}

test "seac composes a base glyph and an accent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try testIndex(a, &.{
        &.{14},
        &.{ 139, 139, 21, 239, 6, 239, 7, 39, 6, 14 },
        &.{ 149, 149, 21, 159, 6, 159, 7, 119, 6, 14 },
        &.{ 189, 199, 204, 247, 86, 14 },
    });
    const name = try testIndex(a, &.{"t"});
    const charset = [_]u8{ 0, 0, 34, 0, 125, 1, 0x87 };
    const top_idx_len = 2 + 1 + 2 + 23;
    const charset_off = 4 + name.len + top_idx_len + 4;
    const cs_off = charset_off + charset.len;
    const priv_off = cs_off + cs.len;
    var top: std.ArrayList(u8) = .empty;
    try testInt(&top, a, charset_off);
    try top.append(a, 15);
    try testInt(&top, a, cs_off);
    try top.append(a, 17);
    try testInt(&top, a, 4);
    try testInt(&top, a, priv_off);
    try top.append(a, 18);
    var font: std.ArrayList(u8) = .empty;
    try font.appendSlice(a, &.{ 1, 0, 4, 1 });
    try font.appendSlice(a, name);
    try font.appendSlice(a, try testIndex(a, &.{top.items}));
    try font.appendSlice(a, &.{ 0, 0, 0, 0 });
    try font.appendSlice(a, &charset);
    try font.appendSlice(a, cs);
    try font.appendSlice(a, &.{ 139, 20, 139, 21 });
    const cff = try Cff.init(font.items, 0);
    try std.testing.expectEqual(@as(usize, 4), cff.num_glyphs);
    var p: path_mod.Path = .{};
    try cff.outline(a, 3, .{}, &p);
    try std.testing.expectEqual(@as(usize, 10), p.segs.items.len);
    try std.testing.expectEqual(@as(f64, 100), p.segs.items[2].line.x);
    try std.testing.expectEqual(@as(f64, 60), p.segs.items[5].move.x);
    try std.testing.expectEqual(@as(f64, 70), p.segs.items[5].move.y);
    try std.testing.expectEqual(@as(f64, 80), p.segs.items[6].line.x);
}

test "CID-keyed fonts take local subrs from the glyph's font dict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 139, 139, 21, 32, 10, 239, 7, 14 };
    const cs = try testIndex(a, &.{ &.{14}, &body, &body });
    const name = try testIndex(a, &.{"t"});
    const select = [_]u8{ 3, 0, 2, 0, 0, 0, 0, 2, 1, 0, 3 };
    const subrs0 = try testIndex(a, &.{&.{ 239, 6, 11 }});
    const subrs1 = try testIndex(a, &.{&.{ 189, 6, 11 }});
    const top_idx_len = 2 + 1 + 2 + 25;
    const select_off = 4 + name.len + top_idx_len + 4;
    const cs_off = select_off + select.len;
    const fdarray_off = cs_off + cs.len;
    const fdarray_len = 2 + 1 + 3 + 22;
    const priv0 = fdarray_off + fdarray_len;
    const priv1 = priv0 + 6 + subrs0.len;
    var fd0: std.ArrayList(u8) = .empty;
    try testInt(&fd0, a, 6);
    try testInt(&fd0, a, priv0);
    try fd0.append(a, 18);
    var fd1: std.ArrayList(u8) = .empty;
    try testInt(&fd1, a, 6);
    try testInt(&fd1, a, priv1);
    try fd1.append(a, 18);
    var top: std.ArrayList(u8) = .empty;
    try top.appendSlice(a, &.{ 139, 139, 139, 12, 30 });
    try testInt(&top, a, fdarray_off);
    try top.appendSlice(a, &.{ 12, 36 });
    try testInt(&top, a, select_off);
    try top.appendSlice(a, &.{ 12, 37 });
    try testInt(&top, a, cs_off);
    try top.append(a, 17);
    var font: std.ArrayList(u8) = .empty;
    try font.appendSlice(a, &.{ 1, 0, 4, 1 });
    try font.appendSlice(a, name);
    try font.appendSlice(a, try testIndex(a, &.{top.items}));
    try font.appendSlice(a, &.{ 0, 0, 0, 0 });
    try font.appendSlice(a, &select);
    try font.appendSlice(a, cs);
    try font.appendSlice(a, try testIndex(a, &.{ fd0.items, fd1.items }));
    try font.appendSlice(a, &.{ 29, 0, 0, 0, 6, 19 });
    try font.appendSlice(a, subrs0);
    try font.appendSlice(a, &.{ 29, 0, 0, 0, 6, 19 });
    try font.appendSlice(a, subrs1);
    const cff = try Cff.init(font.items, 0);
    var p1: path_mod.Path = .{};
    try cff.outline(a, 1, .{}, &p1);
    try std.testing.expectEqual(@as(usize, 4), p1.segs.items.len);
    try std.testing.expectEqual(@as(f64, 100), p1.segs.items[1].line.x);
    var p2: path_mod.Path = .{};
    try cff.outline(a, 2, .{}, &p2);
    try std.testing.expectEqual(@as(f64, 50), p2.segs.items[1].line.x);
}
