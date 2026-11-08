const std = @import("std");
const image = @import("image.zig");
const Error = image.Error;
const Image = image.Image;

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const Huff = struct {
    present: bool = false,
    lookup: [512]u16 = @splat(0),
    maxcode: [18]i32 = @splat(-1),
    valoff: [17]i32 = @splat(0),
    vals: [256]u8 = @splat(0),

    fn build(self: *Huff, counts: *const [16]u8, vals: []const u8) Error!void {
        var code: u32 = 0;
        var k: usize = 0;
        @memset(&self.lookup, 0);
        for (1..17) |l| {
            self.valoff[l] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            const n = counts[l - 1];
            if (n > 0) {
                if (code + n > (@as(u32, 1) << @intCast(l))) return error.Corrupt;
                for (0..n) |i| {
                    if (l <= 9) {
                        const shift: u5 = @intCast(9 - l);
                        const base = (code + @as(u32, @intCast(i))) << shift;
                        const entry: u16 = @intCast((l << 8) | vals[k + i]);
                        for (0..(@as(usize, 1) << shift)) |j| self.lookup[base + j] = entry;
                    }
                }
                code += n;
                k += n;
                self.maxcode[l] = @as(i32, @intCast(code)) - 1;
            } else self.maxcode[l] = -1;
            code <<= 1;
        }
        self.maxcode[17] = std.math.maxInt(i32);
        @memcpy(self.vals[0..k], vals[0..k]);
        self.present = true;
    }
};

const Component = struct {
    id: u8,
    h: u32,
    v: u32,
    tq: u8,
    td: u8 = 0,
    ta: u8 = 0,
    bw: usize = 0,
    bh: usize = 0,
    cw: usize = 0,
    ch: usize = 0,
    coef: []i16 = &.{},
    q: [64]u16 = @splat(0),
    q_set: bool = false,
    pred: i32 = 0,
};

const Bits = struct {
    data: []const u8,
    pos: usize,
    buf: u64 = 0,
    cnt: u7 = 0,
    zeros: u7 = 0,
    bad: bool = false,
    marker: bool = false,

    fn fill(self: *Bits) void {
        while (self.cnt <= 56) {
            var b: u8 = 0;
            if (!self.marker and self.pos < self.data.len) {
                b = self.data[self.pos];
                if (b == 0xFF) {
                    const n: u8 = if (self.pos + 1 < self.data.len) self.data[self.pos + 1] else 0xD9;
                    if (n == 0) {
                        self.pos += 2;
                    } else if (n == 0xFF) {
                        self.pos += 1;
                        continue;
                    } else {
                        self.marker = true;
                        b = 0;
                    }
                } else self.pos += 1;
            } else self.marker = true;
            if (self.marker) self.zeros += 8;
            self.buf = (self.buf << 8) | b;
            self.cnt += 8;
        }
    }

    fn consume(self: *Bits, n: u7) void {
        self.cnt -= n;
        if (self.cnt < self.zeros) {
            self.bad = true;
            self.zeros = self.cnt;
        }
    }

    fn peek(self: *Bits, n: u7) u32 {
        return @intCast((self.buf >> @intCast(self.cnt - n)) & ((@as(u64, 1) << @intCast(n)) - 1));
    }

    fn get(self: *Bits, n: u7) u32 {
        if (n == 0) return 0;
        if (self.cnt < n) self.fill();
        const v = self.peek(n);
        self.consume(n);
        return v;
    }

    fn bit(self: *Bits) u32 {
        return self.get(1);
    }

    fn decode(self: *Bits, h: *const Huff) Error!u8 {
        if (self.cnt < 16) self.fill();
        const look = h.lookup[self.peek(9)];
        if (look != 0) {
            self.consume(@intCast(look >> 8));
            return @intCast(look & 0xFF);
        }
        const p16: i32 = @intCast(self.peek(16));
        var l: u7 = 10;
        while (l <= 16) : (l += 1) {
            const code = p16 >> @intCast(16 - l);
            if (code <= h.maxcode[l]) {
                const idx = h.valoff[l] + code;
                if (idx < 0 or idx > 255) return error.Corrupt;
                self.consume(l);
                return h.vals[@intCast(idx)];
            }
        }
        return error.Corrupt;
    }

    fn restart(self: *Bits) Error!void {
        self.buf = 0;
        self.cnt = 0;
        self.zeros = 0;
        if (self.bad) return error.Corrupt;
        if (self.pos + 2 > self.data.len or self.data[self.pos] != 0xFF) return error.Corrupt;
        var p = self.pos;
        while (p + 1 < self.data.len and self.data[p + 1] == 0xFF) p += 1;
        if (p + 1 >= self.data.len or self.data[p + 1] < 0xD0 or self.data[p + 1] > 0xD7) return error.Corrupt;
        self.pos = p + 2;
        self.marker = false;
    }
};

fn extend(v: u32, n: u7) i32 {
    const vv: i32 = @intCast(v);
    if (n == 0) return 0;
    return if (v < (@as(u32, 1) << @intCast(n - 1))) vv - (@as(i32, 1) << @intCast(n)) + 1 else vv;
}

const Decoder = struct {
    alloc: std.mem.Allocator,
    data: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    progressive: bool = false,
    comps: [4]Component = @splat(.{ .id = 0, .h = 1, .v = 1, .tq = 0 }),
    ncomp: usize = 0,
    hmax: u32 = 1,
    vmax: u32 = 1,
    mcus_x: usize = 0,
    mcus_y: usize = 0,
    qt: [4][64]u16 = @splat(@splat(0)),
    qt_set: [4]bool = .{ false, false, false, false },
    dc: [4]Huff = .{ .{}, .{}, .{}, .{} },
    ac: [4]Huff = .{ .{}, .{}, .{}, .{} },
    restart_interval: usize = 0,
    adobe_transform: ?u8 = null,
    jfif: bool = false,
    orientation: u8 = 1,
    eobrun: u32 = 0,
    allocated: bool = false,
    scans: usize = 0,

    fn deinit(self: *Decoder) void {
        for (self.comps[0..self.ncomp]) |c| self.alloc.free(c.coef);
    }

    fn parseSof(self: *Decoder, seg: []const u8, progressive: bool) Error!void {
        if (self.ncomp != 0) return error.Corrupt;
        var c: image.Cursor = .{ .b = seg };
        const prec = try c.byte();
        if (prec != 8) return error.UnsupportedFormat;
        const h = try c.be16();
        const w = try c.be16();
        const n = try c.byte();
        if (h == 0) return error.UnsupportedFormat;
        try image.checkDims(w, h);
        if (n != 1 and n != 3 and n != 4) return error.UnsupportedFormat;
        self.width = w;
        self.height = h;
        self.progressive = progressive;
        for (0..n) |i| {
            const id = try c.byte();
            const hv = try c.byte();
            const tq = try c.byte();
            var hh: u32 = hv >> 4;
            var vv: u32 = hv & 15;
            if (hh == 0 or hh > 4 or vv == 0 or vv > 4 or tq > 3) return error.Corrupt;
            if (n == 1) {
                hh = 1;
                vv = 1;
            }
            self.comps[i] = .{ .id = id, .h = hh, .v = vv, .tq = tq };
            self.hmax = @max(self.hmax, hh);
            self.vmax = @max(self.vmax, vv);
        }
        self.ncomp = n;
        self.mcus_x = (w + 8 * self.hmax - 1) / (8 * self.hmax);
        self.mcus_y = (h + 8 * self.vmax - 1) / (8 * self.vmax);
        for (self.comps[0..n]) |*cp| {
            cp.bw = self.mcus_x * cp.h;
            cp.bh = self.mcus_y * cp.v;
            cp.cw = (w * cp.h + self.hmax - 1) / self.hmax;
            cp.ch = (h * cp.v + self.vmax - 1) / self.vmax;
        }
    }

    fn parseDqt(self: *Decoder, seg: []const u8) Error!void {
        var c: image.Cursor = .{ .b = seg };
        while (c.left() > 0) {
            const pt = try c.byte();
            const t = pt & 15;
            if (t > 3 or (pt >> 4) > 1) return error.Corrupt;
            for (0..64) |i| {
                const v: u16 = if (pt >> 4 == 0) try c.byte() else try c.be16();
                self.qt[t][zigzag[i]] = v;
            }
            self.qt_set[t] = true;
        }
    }

    fn parseDht(self: *Decoder, seg: []const u8) Error!void {
        var c: image.Cursor = .{ .b = seg };
        while (c.left() > 0) {
            const tc = try c.byte();
            const counts = (try c.take(16))[0..16];
            var total: usize = 0;
            for (counts) |n| total += n;
            if (total > 256) return error.Corrupt;
            const vals = try c.take(total);
            const t = tc & 15;
            if (t > 3 or (tc >> 4) > 1) return error.Corrupt;
            try (if (tc >> 4 == 0) &self.dc[t] else &self.ac[t]).build(counts, vals);
        }
    }

    fn parseApp(self: *Decoder, marker: u8, seg: []const u8) void {
        if (marker == 0xE0 and seg.len >= 5 and std.mem.eql(u8, seg[0..5], "JFIF\x00")) self.jfif = true;
        if (marker == 0xEE and seg.len >= 12 and std.mem.eql(u8, seg[0..5], "Adobe")) self.adobe_transform = seg[11];
        if (marker == 0xE1 and seg.len >= 14 and std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) self.parseExif(seg[6..]);
    }

    fn parseExif(self: *Decoder, t: []const u8) void {
        const endian: std.builtin.Endian = if (std.mem.eql(u8, t[0..2], "II")) .little else if (std.mem.eql(u8, t[0..2], "MM")) .big else return;
        if (std.mem.readInt(u16, t[2..4], endian) != 42) return;
        const off = std.mem.readInt(u32, t[4..8], endian);
        if (off > t.len or t.len - off < 2) return;
        const n = std.mem.readInt(u16, t[off..][0..2], endian);
        var p: usize = off + 2;
        for (0..n) |_| {
            if (p + 12 > t.len) return;
            if (std.mem.readInt(u16, t[p..][0..2], endian) == 0x0112) {
                const v = std.mem.readInt(u16, t[p + 8 ..][0..2], endian);
                if (v >= 1 and v <= 8) self.orientation = @intCast(v);
                return;
            }
            p += 12;
        }
    }

    fn allocCoefs(self: *Decoder) Error!void {
        if (self.allocated) return;
        var total: u64 = 0;
        for (self.comps[0..self.ncomp]) |c| total += @as(u64, c.bw) * c.bh * 64;
        if (total > image.max_pixels * 4) return error.TooLarge;
        for (self.comps[0..self.ncomp]) |*c| {
            c.coef = try self.alloc.alloc(i16, c.bw * c.bh * 64);
            @memset(c.coef, 0);
        }
        self.allocated = true;
    }

    fn scan(self: *Decoder, seg: []const u8, entropy_start: usize) Error!usize {
        var c: image.Cursor = .{ .b = seg };
        const ns = try c.byte();
        if (ns < 1 or ns > 4 or ns > self.ncomp) return error.Corrupt;
        var idx: [4]usize = undefined;
        for (0..ns) |i| {
            const id = try c.byte();
            const t = try c.byte();
            var found: ?usize = null;
            for (self.comps[0..self.ncomp], 0..) |*cp, j| {
                if (cp.id == id) found = j;
            }
            const j = found orelse return error.Corrupt;
            for (idx[0..i]) |o| if (o == j) return error.Corrupt;
            idx[i] = j;
            self.comps[j].td = t >> 4;
            self.comps[j].ta = t & 15;
            if (self.comps[j].td > 3 or self.comps[j].ta > 3) return error.Corrupt;
        }
        var ss: u32 = try c.byte();
        var se: u32 = try c.byte();
        const a = try c.byte();
        var ah: u32 = a >> 4;
        var al: u32 = a & 15;
        if (!self.progressive) {
            ss = 0;
            se = 63;
            ah = 0;
            al = 0;
        } else {
            if (ss > 63 or se > 63 or ss > se or al > 13 or ah > 13) return error.Corrupt;
            if (ss == 0 and se != 0) return error.Corrupt;
            if (ss > 0 and ns != 1) return error.Corrupt;
        }
        try self.allocCoefs();
        for (idx[0..ns]) |j| {
            const cp = &self.comps[j];
            if (!cp.q_set) {
                if (!self.qt_set[cp.tq]) return error.Corrupt;
                cp.q = self.qt[cp.tq];
                cp.q_set = true;
            }
            const need_dc = !self.progressive or (ss == 0 and ah == 0);
            const need_ac = !self.progressive or ss > 0;
            if (need_dc and !self.dc[cp.td].present) return error.Corrupt;
            if (need_ac and !self.ac[cp.ta].present) return error.Corrupt;
        }

        var br: Bits = .{ .data = self.data, .pos = entropy_start };
        for (self.comps[0..self.ncomp]) |*cp| cp.pred = 0;
        self.eobrun = 0;
        var mcu_count: usize = 0;
        const first = &self.comps[idx[0]];
        const sw: usize = (first.cw + 7) / 8;
        const total_mcus: usize = if (ns == 1) sw * ((first.ch + 7) / 8) else self.mcus_x * self.mcus_y;

        var m: usize = 0;
        while (m < total_mcus) : (m += 1) {
            if (self.restart_interval != 0 and mcu_count == self.restart_interval) {
                try br.restart();
                for (self.comps[0..self.ncomp]) |*cp| cp.pred = 0;
                self.eobrun = 0;
                mcu_count = 0;
            }
            mcu_count += 1;
            if (ns == 1) {
                const cp = &self.comps[idx[0]];
                const bx = m % sw;
                const by = m / sw;
                try self.block(&br, cp, cp.coef[(by * cp.bw + bx) * 64 ..][0..64], ss, se, ah, al);
            } else {
                const mx = m % self.mcus_x;
                const my = m / self.mcus_x;
                for (idx[0..ns]) |j| {
                    const cp = &self.comps[j];
                    for (0..cp.v) |v| for (0..cp.h) |h| {
                        const bx = mx * cp.h + h;
                        const by = my * cp.v + v;
                        try self.block(&br, cp, cp.coef[(by * cp.bw + bx) * 64 ..][0..64], ss, se, ah, al);
                    };
                }
            }
            if (br.bad) return error.Corrupt;
        }
        self.scans += 1;
        var p = br.pos;
        while (p + 1 < self.data.len) : (p += 1) {
            if (self.data[p] == 0xFF and self.data[p + 1] != 0 and self.data[p + 1] != 0xFF and !(self.data[p + 1] >= 0xD0 and self.data[p + 1] <= 0xD7)) break;
        }
        return @min(p, self.data.len);
    }

    fn block(self: *Decoder, br: *Bits, cp: *Component, co: []i16, ss: u32, se: u32, ah: u32, al: u32) Error!void {
        const dc = &self.dc[cp.td];
        const ac = &self.ac[cp.ta];
        if (!self.progressive) {
            const t = try br.decode(dc);
            if (t > 16) return error.Corrupt;
            const diff: i32 = if (t == 0) 0 else extend(br.get(@intCast(t)), @intCast(t));
            cp.pred +%= diff;
            co[0] = @truncate(cp.pred);
            var k: usize = 1;
            while (k < 64) {
                const rs = try br.decode(ac);
                const r = rs >> 4;
                const s: u7 = @intCast(rs & 15);
                if (s == 0) {
                    if (r == 15) {
                        k += 16;
                        continue;
                    }
                    break;
                }
                k += r;
                if (k > 63) return error.Corrupt;
                co[zigzag[k]] = @truncate(extend(br.get(s), s));
                k += 1;
            }
            return;
        }
        if (ss == 0) {
            if (ah == 0) {
                const t = try br.decode(dc);
                if (t > 16) return error.Corrupt;
                const diff: i32 = if (t == 0) 0 else extend(br.get(@intCast(t)), @intCast(t));
                cp.pred +%= diff;
                co[0] = @truncate(cp.pred << @intCast(al));
            } else if (br.bit() != 0) co[0] |= @as(i16, 1) << @intCast(al);
            return;
        }
        if (ah == 0) {
            if (self.eobrun > 0) {
                self.eobrun -= 1;
                return;
            }
            var k: usize = ss;
            while (k <= se) {
                const rs = try br.decode(ac);
                const r = rs >> 4;
                const s: u7 = @intCast(rs & 15);
                if (s != 0) {
                    k += r;
                    if (k > 63) return error.Corrupt;
                    co[zigzag[k]] = @truncate(extend(br.get(s), s) * (@as(i32, 1) << @intCast(al)));
                    k += 1;
                } else if (r == 15) {
                    k += 16;
                } else {
                    self.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                    if (r != 0) self.eobrun += br.get(@intCast(r));
                    break;
                }
            }
            return;
        }
        const p1: i16 = @as(i16, 1) << @intCast(al);
        const m1: i16 = -p1;
        var k: usize = ss;
        if (self.eobrun == 0) {
            while (k <= se) : (k += 1) {
                const rs = try br.decode(ac);
                var r: i32 = rs >> 4;
                const s0 = rs & 15;
                var s: i16 = 0;
                if (s0 != 0) {
                    s = if (br.bit() != 0) p1 else m1;
                } else if (r != 15) {
                    self.eobrun = @as(u32, 1) << @intCast(r);
                    if (r != 0) self.eobrun += br.get(@intCast(r));
                    break;
                }
                while (k <= se) : (k += 1) {
                    const t = &co[zigzag[k]];
                    if (t.* != 0) {
                        if (br.bit() != 0 and (t.* & p1) == 0) t.* += if (t.* >= 0) p1 else m1;
                    } else {
                        r -= 1;
                        if (r < 0) break;
                    }
                }
                if (s != 0) {
                    if (k > 63) return error.Corrupt;
                    co[zigzag[k]] = s;
                }
            }
        }
        if (self.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const t = &co[zigzag[k]];
                if (t.* != 0 and br.bit() != 0 and (t.* & p1) == 0) t.* += if (t.* >= 0) p1 else m1;
            }
            self.eobrun -= 1;
        }
    }
};

const c_bits = 13;
const p1_bits = 2;

fn descale(x: i32, n: u5) i32 {
    return (x +% (@as(i32, 1) << (n - 1))) >> n;
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn idct(co: []const i16, q: *const [64]u16, out: []u8, stride: usize) void {
    var ws: [64]i32 = undefined;
    for (0..8) |col| {
        const i = [8]i32{
            @as(i32, co[col]) * q[col],
            @as(i32, co[8 + col]) * q[8 + col],
            @as(i32, co[16 + col]) * q[16 + col],
            @as(i32, co[24 + col]) * q[24 + col],
            @as(i32, co[32 + col]) * q[32 + col],
            @as(i32, co[40 + col]) * q[40 + col],
            @as(i32, co[48 + col]) * q[48 + col],
            @as(i32, co[56 + col]) * q[56 + col],
        };
        if (i[1] | i[2] | i[3] | i[4] | i[5] | i[6] | i[7] == 0) {
            const dc = i[0] << p1_bits;
            inline for (0..8) |r| ws[r * 8 + col] = dc;
            continue;
        }
        const o = idct1d(i, c_bits - p1_bits);
        inline for (0..8) |r| ws[r * 8 + col] = o[r];
    }
    for (0..8) |row| {
        const i = ws[row * 8 ..][0..8].*;
        const o = idct1d(i, c_bits + p1_bits + 3);
        const dst = out[row * stride ..][0..8];
        inline for (0..8) |c| dst[c] = clamp8(o[c] +% 128);
    }
}

fn idct1d(i: [8]i32, shift: u5) [8]i32 {
    var z2 = i[2];
    var z3 = i[6];
    var z1 = (z2 +% z3) *% 4433;
    const tmp2 = z1 +% z3 *% -15137;
    const tmp3 = z1 +% z2 *% 6270;
    const tmp0 = (i[0] +% i[4]) << c_bits;
    const tmp1 = (i[0] -% i[4]) << c_bits;
    const t10 = tmp0 +% tmp3;
    const t13 = tmp0 -% tmp3;
    const t11 = tmp1 +% tmp2;
    const t12 = tmp1 -% tmp2;
    var o0 = i[7];
    var o1 = i[5];
    var o2 = i[3];
    var o3 = i[1];
    z1 = o0 +% o3;
    z2 = o1 +% o2;
    z3 = o0 +% o2;
    var z4 = o1 +% o3;
    const z5 = (z3 +% z4) *% 9633;
    o0 *%= 2446;
    o1 *%= 16819;
    o2 *%= 25172;
    o3 *%= 12299;
    z1 *%= -7373;
    z2 *%= -20995;
    z3 *%= -16069;
    z4 *%= -3196;
    z3 +%= z5;
    z4 +%= z5;
    o0 +%= z1 +% z3;
    o1 +%= z2 +% z4;
    o2 +%= z2 +% z3;
    o3 +%= z1 +% z4;
    return .{
        descale(t10 +% o3, shift), descale(t11 +% o2, shift), descale(t12 +% o1, shift), descale(t13 +% o0, shift),
        descale(t13 -% o0, shift), descale(t12 -% o1, shift), descale(t11 -% o2, shift), descale(t10 -% o3, shift),
    };
}

const crr = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| t[i] = (91881 * (@as(i32, @intCast(i)) - 128) + 32768) >> 16;
    break :blk t;
};
const cbb = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| t[i] = (116130 * (@as(i32, @intCast(i)) - 128) + 32768) >> 16;
    break :blk t;
};
const crg = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| t[i] = -46802 * (@as(i32, @intCast(i)) - 128);
    break :blk t;
};
const cbg = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| t[i] = -22554 * (@as(i32, @intCast(i)) - 128) + 32768;
    break :blk t;
};

const Plane = struct { data: []u8, stride: usize };

fn upsampleRow(comp: *const Component, pl: Plane, y: usize, hs: u32, vs: u32, hmax: u32, vmax: u32, out: []u8) void {
    const w = out.len;
    if (hs == 1 and vs == 1) {
        @memcpy(out, pl.data[y * pl.stride ..][0..w]);
        return;
    }
    const cw = comp.cw;
    if (hs == 2 and vs == 1 and cw > 2) {
        const in = pl.data[y * pl.stride ..][0..cw];
        fancyH2(in, out);
        return;
    }
    if (hs == 2 and vs == 2 and cw > 2) {
        const r = y / 2;
        const nb = if (y % 2 == 0) (if (r == 0) 0 else r - 1) else @min(r + 1, comp.ch - 1);
        const in0 = pl.data[r * pl.stride ..][0..cw];
        const in1 = pl.data[nb * pl.stride ..][0..cw];
        fancyH2V2(in0, in1, out);
        return;
    }
    if (hs == 1 and vs == 2) {
        const r = y / 2;
        const nb = if (y % 2 == 0) (if (r == 0) 0 else r - 1) else @min(r + 1, comp.ch - 1);
        const bias: i32 = if (y % 2 == 0) 1 else 2;
        const in0 = pl.data[r * pl.stride ..][0..w];
        const in1 = pl.data[nb * pl.stride ..][0..w];
        for (0..w) |x| out[x] = @intCast((@as(i32, in0[x]) * 3 + in1[x] + bias) >> 2);
        return;
    }
    const sy = @min(y * comp.v / vmax, comp.ch - 1);
    const row = pl.data[sy * pl.stride ..];
    for (0..w) |x| out[x] = row[x * comp.h / hmax];
}

fn fancyH2(in: []const u8, out: []u8) void {
    const n = in.len;
    const w = out.len;
    var x: usize = 0;
    while (x < n) : (x += 1) {
        const v: i32 = @as(i32, in[x]) * 3;
        const lo: i32 = if (x == 0) in[0] else @as(i32, in[x - 1]) * 1;
        const hi: i32 = if (x + 1 == n) in[n - 1] else in[x + 1];
        const o0: i32 = if (x == 0) in[0] else (v + lo + 1) >> 2;
        const o1: i32 = if (x + 1 == n) in[n - 1] else (v + hi + 2) >> 2;
        if (2 * x < w) out[2 * x] = @intCast(o0);
        if (2 * x + 1 < w) out[2 * x + 1] = @intCast(o1);
    }
}

fn fancyH2V2(in0: []const u8, in1: []const u8, out: []u8) void {
    const n = in0.len;
    const w = out.len;
    var x: usize = 0;
    while (x < n) : (x += 1) {
        const this: i32 = @as(i32, in0[x]) * 3 + in1[x];
        const last: i32 = if (x == 0) 0 else @as(i32, in0[x - 1]) * 3 + in1[x - 1];
        const next: i32 = if (x + 1 == n) 0 else @as(i32, in0[x + 1]) * 3 + in1[x + 1];
        const o0: i32 = if (x == 0) (this * 4 + 8) >> 4 else (this * 3 + last + 8) >> 4;
        const o1: i32 = if (x + 1 == n) (this * 4 + 7) >> 4 else (this * 3 + next + 7) >> 4;
        if (2 * x < w) out[2 * x] = @intCast(o0);
        if (2 * x + 1 < w) out[2 * x + 1] = @intCast(o1);
    }
}

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    var d: Decoder = .{ .alloc = alloc, .data = bytes };
    defer d.deinit();
    var pos: usize = 2;
    while (true) {
        while (pos < bytes.len and bytes[pos] != 0xFF) pos += 1;
        while (pos < bytes.len and bytes[pos] == 0xFF) pos += 1;
        if (pos >= bytes.len) break;
        const m = bytes[pos];
        pos += 1;
        if (m == 0xD9) break;
        if (m == 0 or m == 0x01 or (m >= 0xD0 and m <= 0xD8)) continue;
        if (pos + 2 > bytes.len) return error.Corrupt;
        const len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        if (len < 2 or pos + len > bytes.len) return error.Corrupt;
        const seg = bytes[pos + 2 .. pos + len];
        pos += len;
        switch (m) {
            0xC0, 0xC1 => try d.parseSof(seg, false),
            0xC2 => try d.parseSof(seg, true),
            0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return error.UnsupportedFormat,
            0xC4 => try d.parseDht(seg),
            0xDB => try d.parseDqt(seg),
            0xDD => {
                if (seg.len != 2) return error.Corrupt;
                d.restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            0xDA => {
                if (d.ncomp == 0) return error.Corrupt;
                pos = try d.scan(seg, pos);
            },
            0xE0...0xEF => d.parseApp(m, seg),
            else => {},
        }
    }
    if (d.ncomp == 0 or d.scans == 0) return error.Corrupt;
    return render(&d);
}

fn render(d: *Decoder) Error!Image {
    const alloc = d.alloc;
    var planes: [4]Plane = undefined;
    var made: usize = 0;
    defer for (planes[0..made]) |p| alloc.free(p.data);
    for (d.comps[0..d.ncomp], 0..) |*cp, i| {
        const stride = cp.bw * 8;
        const data = try alloc.alloc(u8, stride * cp.bh * 8);
        planes[i] = .{ .data = data, .stride = stride };
        made += 1;
        if (!cp.q_set) {
            @memset(data, 128);
            continue;
        }
        for (0..cp.bh) |by| for (0..cp.bw) |bx| {
            idct(cp.coef[(by * cp.bw + bx) * 64 ..][0..64], &cp.q, data[by * 8 * stride + bx * 8 ..], stride);
        };
    }

    const w: usize = d.width;
    const h: usize = d.height;
    const o = d.orientation;
    const swap = o >= 5;
    const ow: u32 = if (swap) d.height else d.width;
    const oh: u32 = if (swap) d.width else d.height;
    const out = try image.allocRgba(alloc, ow, oh);
    errdefer alloc.free(out);

    var lines: [4][]u8 = undefined;
    const line_mem = try alloc.alloc(u8, w * d.ncomp + 8);
    defer alloc.free(line_mem);
    for (0..d.ncomp) |i| lines[i] = line_mem[i * w ..][0..w];
    var rgba_row = try alloc.alloc(u8, w * 4);
    defer alloc.free(rgba_row);

    const transform: bool = switch (d.ncomp) {
        3 => if (d.adobe_transform) |t| t != 0 else if (d.jfif) true else !(d.comps[0].id == 'R' and d.comps[1].id == 'G' and d.comps[2].id == 'B'),
        4 => if (d.adobe_transform) |t| t == 2 else false,
        else => false,
    };
    const inverted = d.ncomp == 4 and d.adobe_transform != null;

    for (0..h) |y| {
        for (d.comps[0..d.ncomp], 0..) |*cp, i| {
            const hs = if (d.hmax % cp.h == 0) d.hmax / cp.h else 0;
            const vs = if (d.vmax % cp.v == 0) d.vmax / cp.v else 0;
            upsampleRow(cp, planes[i], y, hs, vs, d.hmax, d.vmax, lines[i]);
        }
        switch (d.ncomp) {
            1 => for (0..w) |x| {
                const g = lines[0][x];
                rgba_row[x * 4 ..][0..4].* = .{ g, g, g, 255 };
            },
            3 => for (0..w) |x| {
                const yy: i32 = lines[0][x];
                if (transform) {
                    const cb = lines[1][x];
                    const cr = lines[2][x];
                    rgba_row[x * 4 ..][0..4].* = .{ clamp8(yy + crr[cr]), clamp8(yy + ((cbg[cb] + crg[cr]) >> 16)), clamp8(yy + cbb[cb]), 255 };
                } else rgba_row[x * 4 ..][0..4].* = .{ lines[0][x], lines[1][x], lines[2][x], 255 };
            },
            else => for (0..w) |x| {
                var c: [3]i32 = undefined;
                if (transform) {
                    const yy: i32 = lines[0][x];
                    const cb = lines[1][x];
                    const cr = lines[2][x];
                    c = .{ 255 - clamp8(yy + crr[cr]), 255 - clamp8(yy + ((cbg[cb] + crg[cr]) >> 16)), 255 - clamp8(yy + cbb[cb]) };
                } else c = .{ lines[0][x], lines[1][x], lines[2][x] };
                const k: i32 = lines[3][x];
                var px: [4]u8 = undefined;
                for (0..3) |j| {
                    px[j] = if (inverted) @intCast(@divTrunc(c[j] * k + 127, 255)) else @intCast(@divTrunc((255 - c[j]) * (255 - k) + 127, 255));
                }
                px[3] = 255;
                rgba_row[x * 4 ..][0..4].* = px;
            },
        }
        if (o == 1) {
            @memcpy(out[y * w * 4 ..][0 .. w * 4], rgba_row);
            continue;
        }
        for (0..w) |x| {
            const dx: usize, const dy: usize = switch (o) {
                2 => .{ w - 1 - x, y },
                3 => .{ w - 1 - x, h - 1 - y },
                4 => .{ x, h - 1 - y },
                5 => .{ y, x },
                6 => .{ h - 1 - y, x },
                7 => .{ h - 1 - y, w - 1 - x },
                else => .{ y, w - 1 - x },
            };
            out[(dy * ow + dx) * 4 ..][0..4].* = rgba_row[x * 4 ..][0..4].*;
        }
    }
    return image.single(alloc, ow, oh, out);
}
