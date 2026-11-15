const std = @import("std");
const image = @import("image.zig");
const tables = @import("vp8_tables.zig");
const Error = image.Error;

const kbands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const kzigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const kcat3 = [_]u8{ 173, 148, 140 };
const kcat4 = [_]u8{ 176, 155, 140, 135 };
const kcat5 = [_]u8{ 180, 157, 141, 134, 130 };
const kcat6 = [_]u8{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 };
const kcat = [4][]const u8{ &kcat3, &kcat4, &kcat5, &kcat6 };

const dc_table = [128]u8{
    4,   5,   6,   7,   8,   9,   10,  10,  11,  12,  13,  14,  15,  16,  17,  17,
    18,  19,  20,  20,  21,  21,  22,  22,  23,  23,  24,  25,  25,  26,  27,  28,
    29,  30,  31,  32,  33,  34,  35,  36,  37,  37,  38,  39,  40,  41,  42,  43,
    44,  45,  46,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,
    59,  60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,
    75,  76,  76,  77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,
    91,  93,  95,  96,  98,  100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
    122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
};

const ac_table = [128]u16{
    4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,  17,  18,  19,
    20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,  33,  34,  35,
    36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,
    52,  53,  54,  55,  56,  57,  58,  60,  62,  64,  66,  68,  70,  72,  74,  76,
    78,  80,  82,  84,  86,  88,  90,  92,  94,  96,  98,  100, 102, 104, 106, 108,
    110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
    155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
    213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
};

const BoolDecoder = struct {
    data: []const u8,
    pos: usize = 0,
    value: u64 = 0,
    range: u32 = 254,
    bits: i32 = -8,
    eof: bool = false,

    fn init(data: []const u8) BoolDecoder {
        var b: BoolDecoder = .{ .data = data };
        b.load();
        return b;
    }

    fn load(self: *BoolDecoder) void {
        if (self.pos < self.data.len) {
            self.bits += 8;
            self.value = (self.value << 8) | self.data[self.pos];
            self.pos += 1;
        } else if (!self.eof) {
            self.value <<= 8;
            self.bits += 8;
            self.eof = true;
        } else {
            self.bits = 0;
        }
    }

    fn bit(self: *BoolDecoder, prob: u32) u32 {
        var range = self.range;
        if (self.bits < 0) self.load();
        const pos: u6 = @intCast(self.bits);
        const split = (range * prob) >> 8;
        const v: u32 = @truncate(self.value >> pos);
        var r: u32 = 0;
        if (v > split) {
            range -= split;
            self.value -= @as(u64, split + 1) << pos;
            r = 1;
        } else {
            range = split + 1;
        }
        const shift: u5 = @intCast(7 ^ (31 - @clz(range)));
        range <<= shift;
        self.bits -= shift;
        self.range = range - 1;
        return r;
    }

    fn flag(self: *BoolDecoder) bool {
        return self.bit(0x80) != 0;
    }

    fn getValue(self: *BoolDecoder, n: u5) u32 {
        var v: u32 = 0;
        var i = n;
        while (i > 0) {
            i -= 1;
            v |= self.bit(0x80) << i;
        }
        return v;
    }

    fn signed(self: *BoolDecoder, n: u5) i32 {
        const v: i32 = @intCast(self.getValue(n));
        return if (self.flag()) -v else v;
    }

    fn optSigned(self: *BoolDecoder, n: u5) i32 {
        return if (self.flag()) self.signed(n) else 0;
    }
};

const Quant = struct { y1: [2]i32, y2: [2]i32, uv: [2]i32 };
const FInfo = struct { limit: u8 = 0, ilevel: u8 = 0, inner: bool = false, hev: u8 = 0 };
const NzCtx = struct { y: [4]u8 = @splat(0), uv: [2][2]u8 = @splat(@splat(0)), dc: u8 = 0 };
const MbData = struct {
    segment: u8 = 0,
    skip: bool = false,
    is_i4: bool = false,
    ymode: u8 = 0,
    imodes: [16]u8 = @splat(0),
    uvmode: u8 = 0,
};

pub const Yuv = struct {
    width: u32,
    height: u32,
    y: []u8,
    u: []u8,
    v: []u8,
    ystride: usize,
    uvstride: usize,
    mem: []u8,
};

fn clip(v: i32, m: i32) usize {
    return @intCast(std.math.clamp(v, 0, m));
}

fn clip8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

const Dec = struct {
    br: BoolDecoder,
    parts: [8]BoolDecoder = @splat(.{ .data = &.{} }),
    num_parts: usize = 1,
    mb_w: usize = 0,
    mb_h: usize = 0,
    use_segment: bool = false,
    update_map: bool = false,
    absolute_delta: bool = true,
    seg_quant: [4]i32 = @splat(0),
    seg_filter: [4]i32 = @splat(0),
    seg_probs: [3]u8 = @splat(255),
    simple: bool = false,
    level: i32 = 0,
    sharpness: i32 = 0,
    use_lf_delta: bool = false,
    ref_lf_delta: [4]i32 = @splat(0),
    mode_lf_delta: [4]i32 = @splat(0),
    filter_type: u2 = 0,
    dqm: [4]Quant = @splat(.{ .y1 = .{ 0, 0 }, .y2 = .{ 0, 0 }, .uv = .{ 0, 0 } }),
    probs: [4][8][3][11]u8 = @splat(@splat(@splat(@splat(0)))),
    use_skip: bool = false,
    skip_p: u8 = 0,
    fstrength: [4][2]FInfo = @splat(@splat(.{})),
    intra_t: []u8 = &.{},
    intra_l: [4]u8 = @splat(0),
    nz_top: []NzCtx = &.{},
    nz_left: NzCtx = .{},
    finfo: []FInfo = &.{},

    fn parseHeaders(self: *Dec) Error!void {
        const br = &self.br;
        _ = br.flag();
        _ = br.flag();
        self.use_segment = br.flag();
        if (self.use_segment) {
            self.update_map = br.flag();
            if (br.flag()) {
                self.absolute_delta = br.flag();
                for (&self.seg_quant) |*q| q.* = br.optSigned(7);
                for (&self.seg_filter) |*f| f.* = br.optSigned(6);
            }
            if (self.update_map) {
                for (&self.seg_probs) |*p| p.* = if (br.flag()) @intCast(br.getValue(8)) else 255;
            }
        }
        if (br.eof) return error.Corrupt;
        self.simple = br.flag();
        self.level = @intCast(br.getValue(6));
        self.sharpness = @intCast(br.getValue(3));
        self.use_lf_delta = br.flag();
        if (self.use_lf_delta and br.flag()) {
            for (&self.ref_lf_delta) |*d| {
                if (br.flag()) d.* = br.signed(6);
            }
            for (&self.mode_lf_delta) |*d| {
                if (br.flag()) d.* = br.signed(6);
            }
        }
        self.filter_type = if (self.level == 0) 0 else if (self.simple) 1 else 2;
        if (br.eof) return error.Corrupt;
    }

    fn parsePartitions(self: *Dec, buf: []const u8) Error!void {
        const last: usize = (@as(usize, 1) << @intCast(self.br.getValue(2))) - 1;
        self.num_parts = last + 1;
        if (buf.len < 3 * last) return error.Corrupt;
        var start = last * 3;
        var left = buf.len - start;
        for (0..last) |p| {
            var psize: usize = @as(usize, buf[p * 3]) | (@as(usize, buf[p * 3 + 1]) << 8) | (@as(usize, buf[p * 3 + 2]) << 16);
            if (psize > left) psize = left;
            self.parts[p] = BoolDecoder.init(buf[start..][0..psize]);
            start += psize;
            left -= psize;
        }
        self.parts[last] = BoolDecoder.init(buf[start..]);
        if (start >= buf.len) return error.Corrupt;
    }

    fn parseQuant(self: *Dec) void {
        const br = &self.br;
        const base: i32 = @intCast(br.getValue(7));
        const dqy1_dc = br.optSigned(4);
        const dqy2_dc = br.optSigned(4);
        const dqy2_ac = br.optSigned(4);
        const dquv_dc = br.optSigned(4);
        const dquv_ac = br.optSigned(4);
        for (0..4) |i| {
            var q: i32 = 0;
            if (self.use_segment) {
                q = self.seg_quant[i];
                if (!self.absolute_delta) q += base;
            } else {
                if (i > 0) {
                    self.dqm[i] = self.dqm[0];
                    continue;
                }
                q = base;
            }
            self.dqm[i] = .{
                .y1 = .{ dc_table[clip(q + dqy1_dc, 127)], ac_table[clip(q, 127)] },
                .y2 = .{
                    @as(i32, dc_table[clip(q + dqy2_dc, 127)]) * 2,
                    @max(8, (@as(i32, ac_table[clip(q + dqy2_ac, 127)]) * 101581) >> 16),
                },
                .uv = .{ dc_table[clip(q + dquv_dc, 117)], ac_table[clip(q + dquv_ac, 127)] },
            };
        }
    }

    fn parseProba(self: *Dec) void {
        const br = &self.br;
        for (0..4) |t| for (0..8) |b| for (0..3) |c| for (0..11) |p| {
            const idx = ((t * 8 + b) * 3 + c) * 11 + p;
            self.probs[t][b][c][p] = if (br.bit(tables.coeff_update_proba[idx]) != 0) @intCast(br.getValue(8)) else tables.coeff_proba0[idx];
        };
        self.use_skip = br.flag();
        if (self.use_skip) self.skip_p = @intCast(br.getValue(8));
    }

    fn precomputeFilter(self: *Dec) void {
        if (self.filter_type == 0) return;
        for (0..4) |s| {
            var base: i32 = self.level;
            if (self.use_segment) {
                base = self.seg_filter[s];
                if (!self.absolute_delta) base += self.level;
            }
            for (0..2) |is4| {
                var level = base;
                if (self.use_lf_delta) {
                    level += self.ref_lf_delta[0];
                    if (is4 == 1) level += self.mode_lf_delta[0];
                }
                level = std.math.clamp(level, 0, 63);
                var info: FInfo = .{ .inner = is4 == 1 };
                if (level > 0) {
                    var il = level;
                    if (self.sharpness > 0) {
                        il >>= if (self.sharpness > 4) 2 else 1;
                        if (il > 9 - self.sharpness) il = 9 - self.sharpness;
                    }
                    if (il < 1) il = 1;
                    info.ilevel = @intCast(il);
                    info.limit = @intCast(2 * level + il);
                    info.hev = if (level >= 40) 2 else if (level >= 15) 1 else 0;
                }
                self.fstrength[s][is4] = info;
            }
        }
    }

    fn parseIntraMode(self: *Dec, mb_x: usize, mb: *MbData) void {
        const br = &self.br;
        const top = self.intra_t[4 * mb_x ..][0..4];
        const left = &self.intra_l;
        if (self.update_map) {
            mb.segment = if (br.bit(self.seg_probs[0]) == 0)
                @intCast(br.bit(self.seg_probs[1]))
            else
                @intCast(br.bit(self.seg_probs[2]) + 2);
        } else mb.segment = 0;
        if (self.use_skip) mb.skip = br.bit(self.skip_p) != 0;
        mb.is_i4 = br.bit(145) == 0;
        if (!mb.is_i4) {
            const ym: u8 = if (br.bit(156) != 0)
                (if (br.bit(128) != 0) 1 else 3)
            else
                (if (br.bit(163) != 0) 2 else 0);
            mb.ymode = ym;
            @memset(top, ym);
            @memset(left, ym);
        } else {
            for (0..4) |y| {
                var ymode = left[y];
                for (0..4) |x| {
                    const prob = tables.bmodes_proba[(@as(usize, top[x]) * 10 + ymode) * 9 ..][0..9];
                    ymode = if (br.bit(prob[0]) == 0) 0 else if (br.bit(prob[1]) == 0) 1 else if (br.bit(prob[2]) == 0) 2 else if (br.bit(prob[3]) == 0)
                        (if (br.bit(prob[4]) == 0) @as(u8, 3) else if (br.bit(prob[5]) == 0) @as(u8, 4) else 5)
                    else if (br.bit(prob[6]) == 0) @as(u8, 6) else if (br.bit(prob[7]) == 0) @as(u8, 7) else if (br.bit(prob[8]) == 0) @as(u8, 8) else 9;
                    top[x] = ymode;
                    mb.imodes[y * 4 + x] = ymode;
                }
                left[y] = ymode;
            }
        }
        mb.uvmode = if (br.bit(142) == 0) 0 else if (br.bit(114) == 0) 2 else if (br.bit(183) != 0) 1 else 3;
    }

    fn largeValue(br: *BoolDecoder, p: *const [11]u8) i32 {
        if (br.bit(p[3]) == 0) {
            if (br.bit(p[4]) == 0) return 2;
            return 3 + @as(i32, @intCast(br.bit(p[5])));
        }
        if (br.bit(p[6]) == 0) {
            if (br.bit(p[7]) == 0) return 5 + @as(i32, @intCast(br.bit(159)));
            var v: i32 = 7 + 2 * @as(i32, @intCast(br.bit(165)));
            v += @intCast(br.bit(145));
            return v;
        }
        const bit1 = br.bit(p[8]);
        const bit0 = br.bit(p[9 + bit1]);
        const cat = 2 * bit1 + bit0;
        var v: i32 = 0;
        for (kcat[cat]) |t| v += v + @as(i32, @intCast(br.bit(t)));
        return v + 3 + (@as(i32, 8) << @intCast(cat));
    }

    fn coeffs(br: *BoolDecoder, probs: *const [8][3][11]u8, ctx: usize, dq: [2]i32, start: usize, out: []i16) usize {
        var n = start;
        var p = &probs[kbands[n]][ctx];
        while (n < 16) : (n += 1) {
            if (br.bit(p[0]) == 0) return n;
            while (br.bit(p[1]) == 0) {
                n += 1;
                p = &probs[kbands[n]][0];
                if (n == 16) return 16;
            }
            var v: i32 = 1;
            if (br.bit(p[2]) == 0) {
                v = 1;
                p = &probs[kbands[n + 1]][1];
            } else {
                v = largeValue(br, p);
                p = &probs[kbands[n + 1]][2];
            }
            const s = br.flag();
            const val = (if (s) -v else v) * dq[@intFromBool(n > 0)];
            out[kzigzag[n]] = @truncate(val);
        }
        return 16;
    }

    fn nzCode(nz: usize, dc_nz: bool) u2 {
        return if (nz > 3) 3 else if (nz > 1) 2 else @intFromBool(dc_nz);
    }

    fn parseResiduals(self: *Dec, mb_x: usize, mb: *const MbData, br: *BoolDecoder, co: *[384]i16, codes: *[24]u2) bool {
        const q = &self.dqm[mb.segment];
        const top = &self.nz_top[mb_x];
        const left = &self.nz_left;
        @memset(co, 0);
        var any = false;
        var first: usize = 0;
        var yprobs: *const [8][3][11]u8 = &self.probs[3];
        if (!mb.is_i4) {
            var dc: [16]i16 = @splat(0);
            const ctx = top.dc + left.dc;
            const nz = coeffs(br, &self.probs[1], ctx, q.y2, 0, &dc);
            top.dc = @intFromBool(nz > 0);
            left.dc = top.dc;
            if (nz > 1) {
                wht(&dc, co);
            } else {
                const dc0: i16 = @truncate((@as(i32, dc[0]) + 3) >> 3);
                for (0..16) |i| co[i * 16] = dc0;
            }
            first = 1;
            yprobs = &self.probs[0];
        }
        for (0..4) |y| {
            var l = left.y[y];
            for (0..4) |x| {
                const n = y * 4 + x;
                const nz = coeffs(br, yprobs, l + top.y[x], q.y1, first, co[n * 16 ..][0..16]);
                l = @intFromBool(nz > first);
                top.y[x] = l;
                codes[n] = nzCode(nz, co[n * 16] != 0);
                if (codes[n] != 0) any = true;
            }
            left.y[y] = l;
        }
        for (0..2) |ch| {
            for (0..2) |y| {
                var l = left.uv[ch][y];
                for (0..2) |x| {
                    const n = 16 + ch * 4 + y * 2 + x;
                    const nz = coeffs(br, &self.probs[2], l + top.uv[ch][x], q.uv, 0, co[n * 16 ..][0..16]);
                    l = @intFromBool(nz > 0);
                    top.uv[ch][x] = l;
                    codes[n] = nzCode(nz, co[n * 16] != 0);
                    if (codes[n] != 0) any = true;
                }
                left.uv[ch][y] = l;
            }
        }
        return !any;
    }
};

fn wht(in: *const [16]i16, out: []i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[i]) - in[12 + i];
        tmp[i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[i * 4] + 3;
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        out[(i * 4 + 0) * 16] = @truncate((a0 + a1) >> 3);
        out[(i * 4 + 1) * 16] = @truncate((a3 + a2) >> 3);
        out[(i * 4 + 2) * 16] = @truncate((a0 - a1) >> 3);
        out[(i * 4 + 3) * 16] = @truncate((a3 - a2) >> 3);
    }
}

fn mul1(a: i32) i32 {
    return ((a *% 20091) >> 16) +% a;
}

fn mul2(a: i32) i32 {
    return (a *% 35468) >> 16;
}

fn idctAdd(in: []const i16, dst: []u8, stride: usize) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a = @as(i32, in[i]) + in[8 + i];
        const b = @as(i32, in[i]) - in[8 + i];
        const c = mul2(in[4 + i]) -% mul1(in[12 + i]);
        const d = mul1(in[4 + i]) +% mul2(in[12 + i]);
        tmp[4 * i] = a +% d;
        tmp[4 * i + 1] = b +% c;
        tmp[4 * i + 2] = b -% c;
        tmp[4 * i + 3] = a -% d;
    }
    for (0..4) |i| {
        const dc = tmp[i] +% 4;
        const a = dc +% tmp[8 + i];
        const b = dc -% tmp[8 + i];
        const c = mul2(tmp[4 + i]) -% mul1(tmp[12 + i]);
        const d = mul1(tmp[4 + i]) +% mul2(tmp[12 + i]);
        const row = dst[i * stride ..][0..4];
        row[0] = clip8(@as(i32, row[0]) +% ((a +% d) >> 3));
        row[1] = clip8(@as(i32, row[1]) +% ((b +% c) >> 3));
        row[2] = clip8(@as(i32, row[2]) +% ((b -% c) >> 3));
        row[3] = clip8(@as(i32, row[3]) +% ((a -% d) >> 3));
    }
}

const Plane = struct {
    data: []u8,
    stride: usize,

    fn pix(self: Plane, x: isize, y: isize) i32 {
        if (y < 0) return 127;
        if (x < 0) return 129;
        return self.data[@as(usize, @intCast(y)) * self.stride + @as(usize, @intCast(x))];
    }
};

fn avg3(a: i32, b: i32, c: i32) u8 {
    return @intCast((a + 2 * b + c + 2) >> 2);
}

fn avg2(a: i32, b: i32) u8 {
    return @intCast((a + b + 1) >> 1);
}

fn pred4(mode: u8, top: *const [8]i32, left: *const [4]i32, tl: i32) [16]u8 {
    var d: [16]u8 = undefined;
    const A = top[0];
    const B = top[1];
    const C = top[2];
    const D = top[3];
    const E = top[4];
    const F = top[5];
    const G = top[6];
    const H = top[7];
    const I = left[0];
    const J = left[1];
    const K = left[2];
    const L = left[3];
    const X = tl;
    switch (mode) {
        0 => {
            const dc: u8 = @intCast((A + B + C + D + I + J + K + L + 4) >> 3);
            @memset(&d, dc);
        },
        1 => for (0..4) |y| for (0..4) |x| {
            d[y * 4 + x] = clip8(left[y] + top[x] - tl);
        },
        2 => {
            const v = [4]u8{ avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E) };
            for (0..4) |y| d[y * 4 ..][0..4].* = v;
        },
        3 => {
            const r = [4]u8{ avg3(X, I, J), avg3(I, J, K), avg3(J, K, L), avg3(K, L, L) };
            for (0..4) |y| @memset(d[y * 4 ..][0..4], r[y]);
        },
        4 => {
            d[12] = avg3(J, K, L);
            d[13] = avg3(I, J, K);
            d[8] = d[13];
            d[14] = avg3(X, I, J);
            d[9] = d[14];
            d[4] = d[14];
            d[15] = avg3(A, X, I);
            d[10] = d[15];
            d[5] = d[15];
            d[0] = d[15];
            d[11] = avg3(B, A, X);
            d[6] = d[11];
            d[1] = d[11];
            d[7] = avg3(C, B, A);
            d[2] = d[7];
            d[3] = avg3(D, C, B);
        },
        5 => {
            d[0] = avg2(X, A);
            d[9] = d[0];
            d[1] = avg2(A, B);
            d[10] = d[1];
            d[2] = avg2(B, C);
            d[11] = d[2];
            d[3] = avg2(C, D);
            d[12] = avg3(K, J, I);
            d[8] = avg3(J, I, X);
            d[4] = avg3(I, X, A);
            d[13] = d[4];
            d[5] = avg3(X, A, B);
            d[14] = d[5];
            d[6] = avg3(A, B, C);
            d[15] = d[6];
            d[7] = avg3(B, C, D);
        },
        6 => {
            d[0] = avg3(A, B, C);
            d[1] = avg3(B, C, D);
            d[4] = d[1];
            d[2] = avg3(C, D, E);
            d[5] = d[2];
            d[8] = d[2];
            d[3] = avg3(D, E, F);
            d[6] = d[3];
            d[9] = d[3];
            d[12] = d[3];
            d[7] = avg3(E, F, G);
            d[10] = d[7];
            d[13] = d[7];
            d[11] = avg3(F, G, H);
            d[14] = d[11];
            d[15] = avg3(G, H, H);
        },
        7 => {
            d[0] = avg2(A, B);
            d[1] = avg2(B, C);
            d[8] = d[1];
            d[2] = avg2(C, D);
            d[9] = d[2];
            d[3] = avg2(D, E);
            d[10] = d[3];
            d[4] = avg3(A, B, C);
            d[5] = avg3(B, C, D);
            d[12] = d[5];
            d[6] = avg3(C, D, E);
            d[13] = d[6];
            d[7] = avg3(D, E, F);
            d[14] = d[7];
            d[11] = avg3(E, F, G);
            d[15] = avg3(F, G, H);
        },
        8 => {
            d[0] = avg2(I, X);
            d[6] = d[0];
            d[4] = avg2(J, I);
            d[10] = d[4];
            d[8] = avg2(K, J);
            d[14] = d[8];
            d[12] = avg2(L, K);
            d[3] = avg3(A, B, C);
            d[2] = avg3(X, A, B);
            d[1] = avg3(I, X, A);
            d[7] = d[1];
            d[5] = avg3(J, I, X);
            d[11] = d[5];
            d[9] = avg3(K, J, I);
            d[15] = d[9];
            d[13] = avg3(L, K, J);
        },
        else => {
            d[0] = avg2(I, J);
            d[2] = avg2(J, K);
            d[4] = d[2];
            d[6] = avg2(K, L);
            d[8] = d[6];
            d[1] = avg3(I, J, K);
            d[3] = avg3(J, K, L);
            d[5] = d[3];
            d[7] = avg3(K, L, L);
            d[9] = d[7];
            const l8: u8 = @intCast(L);
            d[11] = l8;
            d[10] = l8;
            d[12] = l8;
            d[13] = l8;
            d[14] = l8;
            d[15] = l8;
        },
    }
    return d;
}

fn predBlock(pl: Plane, x0: usize, y0: usize, size: usize, mode: u8, has_top: bool, has_left: bool) void {
    var top: [16]i32 = undefined;
    var left: [16]i32 = undefined;
    const xi: isize = @intCast(x0);
    const yi: isize = @intCast(y0);
    for (0..size) |i| {
        top[i] = pl.pix(xi + @as(isize, @intCast(i)), yi - 1);
        left[i] = pl.pix(xi - 1, yi + @as(isize, @intCast(i)));
    }
    const tl = pl.pix(xi - 1, yi - 1);
    switch (mode) {
        0 => {
            var sum: i32 = 0;
            var shift: u5 = if (size == 16) 3 else 2;
            if (has_top) for (top[0..size]) |v| {
                sum += v;
            };
            if (has_left) for (left[0..size]) |v| {
                sum += v;
            };
            var dc: i32 = 128;
            if (has_top and has_left) {
                shift += 2;
                dc = (sum + (@as(i32, 1) << (shift - 1))) >> shift;
            } else if (has_top or has_left) {
                shift += 1;
                dc = (sum + (@as(i32, 1) << (shift - 1))) >> shift;
            }
            for (0..size) |y| @memset(pl.data[(y0 + y) * pl.stride + x0 ..][0..size], @intCast(dc));
        },
        1 => for (0..size) |y| for (0..size) |x| {
            pl.data[(y0 + y) * pl.stride + x0 + x] = clip8(left[y] + top[x] - tl);
        },
        2 => for (0..size) |y| for (0..size) |x| {
            pl.data[(y0 + y) * pl.stride + x0 + x] = @intCast(top[x]);
        },
        else => for (0..size) |y| @memset(pl.data[(y0 + y) * pl.stride + x0 ..][0..size], @intCast(left[y])),
    }
}

fn simpleFilterNeeds(p: []const u8, i: usize, step: usize, t: i32) bool {
    const p1: i32 = p[i - 2 * step];
    const p0: i32 = p[i - step];
    const q0: i32 = p[i];
    const q1: i32 = p[i + step];
    return 4 * @as(i32, @intCast(@abs(p0 - q0))) + @as(i32, @intCast(@abs(p1 - q1))) <= t;
}

fn sclip1(v: i32) i32 {
    return std.math.clamp(v, -128, 127);
}

fn sclip2(v: i32) i32 {
    return std.math.clamp(v, -16, 15);
}

fn doFilter2(p: []u8, i: usize, step: usize) void {
    const p1: i32 = p[i - 2 * step];
    const p0: i32 = p[i - step];
    const q0: i32 = p[i];
    const q1: i32 = p[i + step];
    const a = 3 * (q0 - p0) + sclip1(p1 - q1);
    const a1 = sclip2((a + 4) >> 3);
    const a2 = sclip2((a + 3) >> 3);
    p[i - step] = clip8(p0 + a2);
    p[i] = clip8(q0 - a1);
}

fn doFilter4(p: []u8, i: usize, step: usize) void {
    const p1: i32 = p[i - 2 * step];
    const p0: i32 = p[i - step];
    const q0: i32 = p[i];
    const q1: i32 = p[i + step];
    const a = 3 * (q0 - p0);
    const a1 = sclip2((a + 4) >> 3);
    const a2 = sclip2((a + 3) >> 3);
    const a3 = (a1 + 1) >> 1;
    p[i - 2 * step] = clip8(p1 + a3);
    p[i - step] = clip8(p0 + a2);
    p[i] = clip8(q0 - a1);
    p[i + step] = clip8(q1 - a3);
}

fn doFilter6(p: []u8, i: usize, step: usize) void {
    const p2: i32 = p[i - 3 * step];
    const p1: i32 = p[i - 2 * step];
    const p0: i32 = p[i - step];
    const q0: i32 = p[i];
    const q1: i32 = p[i + step];
    const q2: i32 = p[i + 2 * step];
    const a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1));
    const a1 = (27 * a + 63) >> 7;
    const a2 = (18 * a + 63) >> 7;
    const a3 = (9 * a + 63) >> 7;
    p[i - 3 * step] = clip8(p2 + a3);
    p[i - 2 * step] = clip8(p1 + a2);
    p[i - step] = clip8(p0 + a1);
    p[i] = clip8(q0 - a1);
    p[i + step] = clip8(q1 - a2);
    p[i + 2 * step] = clip8(q2 - a3);
}

fn absd(a: i32, b: i32) i32 {
    return @intCast(@abs(a - b));
}

fn needs2(p: []const u8, i: usize, step: usize, t: i32, it: i32) bool {
    const p3: i32 = p[i - 4 * step];
    const p2: i32 = p[i - 3 * step];
    const p1: i32 = p[i - 2 * step];
    const p0: i32 = p[i - step];
    const q0: i32 = p[i];
    const q1: i32 = p[i + step];
    const q2: i32 = p[i + 2 * step];
    const q3: i32 = p[i + 3 * step];
    if (4 * absd(p0, q0) + absd(p1, q1) > t) return false;
    return absd(p3, p2) <= it and absd(p2, p1) <= it and absd(p1, p0) <= it and absd(q3, q2) <= it and absd(q2, q1) <= it and absd(q1, q0) <= it;
}

fn hev(p: []const u8, i: usize, step: usize, thresh: i32) bool {
    const p1: i32 = p[i - 2 * step];
    const p0: i32 = p[i - step];
    const q0: i32 = p[i];
    const q1: i32 = p[i + step];
    return absd(p1, p0) > thresh or absd(q1, q0) > thresh;
}

fn simpleLoop(p: []u8, start: usize, hstride: usize, vstride: usize, thresh: i32) void {
    const t2 = 2 * thresh + 1;
    for (0..16) |k| {
        const i = start + k * vstride;
        if (simpleFilterNeeds(p, i, hstride, t2)) doFilter2(p, i, hstride);
    }
}

fn loop26(p: []u8, start: usize, hstride: usize, vstride: usize, size: usize, thresh: i32, ithresh: i32, hev_t: i32) void {
    const t2 = 2 * thresh + 1;
    for (0..size) |k| {
        const i = start + k * vstride;
        if (needs2(p, i, hstride, t2, ithresh)) {
            if (hev(p, i, hstride, hev_t)) doFilter2(p, i, hstride) else doFilter6(p, i, hstride);
        }
    }
}

fn loop24(p: []u8, start: usize, hstride: usize, vstride: usize, size: usize, thresh: i32, ithresh: i32, hev_t: i32) void {
    const t2 = 2 * thresh + 1;
    for (0..size) |k| {
        const i = start + k * vstride;
        if (needs2(p, i, hstride, t2, ithresh)) {
            if (hev(p, i, hstride, hev_t)) doFilter2(p, i, hstride) else doFilter4(p, i, hstride);
        }
    }
}

fn loopFilter(d: *const Dec, y: Plane, u: Plane, v: Plane) void {
    for (0..d.mb_h) |mb_y| for (0..d.mb_w) |mb_x| {
        const f = d.finfo[mb_y * d.mb_w + mb_x];
        if (f.limit == 0) continue;
        const limit: i32 = f.limit;
        const il: i32 = f.ilevel;
        const hv: i32 = f.hev;
        const ys = y.stride;
        const yo = mb_y * 16 * ys + mb_x * 16;
        if (d.filter_type == 1) {
            if (mb_x > 0) simpleLoop(y.data, yo, 1, ys, limit + 4);
            if (f.inner) for (1..4) |k| simpleLoop(y.data, yo + 4 * k, 1, ys, limit);
            if (mb_y > 0) simpleLoop(y.data, yo, ys, 1, limit + 4);
            if (f.inner) for (1..4) |k| simpleLoop(y.data, yo + 4 * k * ys, ys, 1, limit);
            continue;
        }
        const us = u.stride;
        const uo = mb_y * 8 * us + mb_x * 8;
        if (mb_x > 0) {
            loop26(y.data, yo, 1, ys, 16, limit + 4, il, hv);
            loop26(u.data, uo, 1, us, 8, limit + 4, il, hv);
            loop26(v.data, uo, 1, us, 8, limit + 4, il, hv);
        }
        if (f.inner) {
            for (1..4) |k| loop24(y.data, yo + 4 * k, 1, ys, 16, limit, il, hv);
            loop24(u.data, uo + 4, 1, us, 8, limit, il, hv);
            loop24(v.data, uo + 4, 1, us, 8, limit, il, hv);
        }
        if (mb_y > 0) {
            loop26(y.data, yo, ys, 1, 16, limit + 4, il, hv);
            loop26(u.data, uo, us, 1, 8, limit + 4, il, hv);
            loop26(v.data, uo, us, 1, 8, limit + 4, il, hv);
        }
        if (f.inner) {
            for (1..4) |k| loop24(y.data, yo + 4 * k * ys, ys, 1, 16, limit, il, hv);
            loop24(u.data, uo + 4 * us, us, 1, 8, limit, il, hv);
            loop24(v.data, uo + 4 * us, us, 1, 8, limit, il, hv);
        }
    };
}

pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!Yuv {
    if (data.len < 10) return error.Corrupt;
    const bits: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    if (bits & 1 != 0) return error.UnsupportedFormat;
    if (((bits >> 1) & 7) > 3) return error.Corrupt;
    if ((bits >> 4) & 1 == 0) return error.UnsupportedFormat;
    const part_len: usize = bits >> 5;
    if (data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) return error.Corrupt;
    const width: u32 = (@as(u32, data[6]) | (@as(u32, data[7]) << 8)) & 0x3fff;
    const height: u32 = (@as(u32, data[8]) | (@as(u32, data[9]) << 8)) & 0x3fff;
    try image.checkDims(width, height);
    const rest = data[10..];
    if (part_len > rest.len) return error.Corrupt;

    var d: Dec = .{ .br = BoolDecoder.init(rest[0..part_len]) };
    d.mb_w = (width + 15) >> 4;
    d.mb_h = (height + 15) >> 4;
    try d.parseHeaders();
    try d.parsePartitions(rest[part_len..]);
    d.parseQuant();
    _ = d.br.flag();
    d.parseProba();
    d.precomputeFilter();

    const ystride = d.mb_w * 16;
    const uvstride = d.mb_w * 8;
    const ysz = ystride * d.mb_h * 16;
    const uvsz = uvstride * d.mb_h * 8;
    const mem = try alloc.alloc(u8, ysz + 2 * uvsz);
    errdefer alloc.free(mem);
    const ypl: Plane = .{ .data = mem[0..ysz], .stride = ystride };
    const upl: Plane = .{ .data = mem[ysz..][0..uvsz], .stride = uvstride };
    const vpl: Plane = .{ .data = mem[ysz + uvsz ..][0..uvsz], .stride = uvstride };

    const intra_t = try alloc.alloc(u8, d.mb_w * 4);
    defer alloc.free(intra_t);
    const nz_top = try alloc.alloc(NzCtx, d.mb_w);
    defer alloc.free(nz_top);
    const finfo = try alloc.alloc(FInfo, d.mb_w * d.mb_h);
    defer alloc.free(finfo);
    @memset(intra_t, 0);
    d.intra_t = intra_t;
    d.nz_top = nz_top;
    @memset(nz_top, .{});
    d.finfo = finfo;
    @memset(finfo, .{});

    var co: [384]i16 = undefined;
    var codes: [24]u2 = undefined;
    for (0..d.mb_h) |mb_y| {
        const tbr = &d.parts[mb_y & (d.num_parts - 1)];
        d.nz_left = .{};
        @memset(&d.intra_l, 0);
        for (0..d.mb_w) |mb_x| {
            var mb: MbData = .{};
            d.parseIntraMode(mb_x, &mb);
            if (d.br.eof) return error.Corrupt;
            var skip = if (d.use_skip) mb.skip else false;
            if (!skip) {
                skip = d.parseResiduals(mb_x, &mb, tbr, &co, &codes);
            } else {
                d.nz_left.y = @splat(0);
                d.nz_left.uv = @splat(@splat(0));
                nz_top[mb_x].y = @splat(0);
                nz_top[mb_x].uv = @splat(@splat(0));
                if (!mb.is_i4) {
                    d.nz_left.dc = 0;
                    nz_top[mb_x].dc = 0;
                }
                @memset(&co, 0);
                @memset(&codes, 0);
            }
            if (tbr.eof) return error.Corrupt;
            if (d.filter_type > 0) {
                var fi = d.fstrength[mb.segment][@intFromBool(mb.is_i4)];
                fi.inner = fi.inner or !skip;
                finfo[mb_y * d.mb_w + mb_x] = fi;
            }
            reconstruct(&d, ypl, upl, vpl, mb_x, mb_y, &mb, &co, &codes);
        }
    }
    if (d.filter_type > 0) loopFilter(&d, ypl, upl, vpl);
    return .{ .width = width, .height = height, .y = ypl.data, .u = upl.data, .v = vpl.data, .ystride = ystride, .uvstride = uvstride, .mem = mem };
}

fn reconstruct(d: *const Dec, ypl: Plane, upl: Plane, vpl: Plane, mb_x: usize, mb_y: usize, mb: *const MbData, co: *const [384]i16, codes: *const [24]u2) void {
    const x0 = mb_x * 16;
    const y0 = mb_y * 16;
    if (!mb.is_i4) {
        predBlock(ypl, x0, y0, 16, mb.ymode, mb_y > 0, mb_x > 0);
        for (0..16) |n| {
            if (codes[n] != 0) idctAdd(co[n * 16 ..][0..16], ypl.data[(y0 + (n / 4) * 4) * ypl.stride + x0 + (n % 4) * 4 ..], ypl.stride);
        }
    } else {
        const mbx: isize = @intCast(x0);
        const mby: isize = @intCast(y0);
        var mb_tr: [4]i32 = undefined;
        for (0..4) |i| {
            mb_tr[i] = if (mb_y == 0) 127 else if (mb_x + 1 >= d.mb_w) ypl.pix(mbx + 15, mby - 1) else ypl.pix(mbx + 16 + @as(isize, @intCast(i)), mby - 1);
        }
        for (0..16) |n| {
            const bx = n % 4;
            const by = n / 4;
            const px: isize = mbx + @as(isize, @intCast(bx * 4));
            const py: isize = mby + @as(isize, @intCast(by * 4));
            var top: [8]i32 = undefined;
            var left: [4]i32 = undefined;
            for (0..4) |i| {
                top[i] = ypl.pix(px + @as(isize, @intCast(i)), py - 1);
                left[i] = ypl.pix(px - 1, py + @as(isize, @intCast(i)));
            }
            for (0..4) |i| {
                top[4 + i] = if (bx == 3) mb_tr[i] else ypl.pix(px + 4 + @as(isize, @intCast(i)), py - 1);
            }
            const tl = ypl.pix(px - 1, py - 1);
            const pr = pred4(mb.imodes[n], &top, &left, tl);
            const base = @as(usize, @intCast(py)) * ypl.stride + @as(usize, @intCast(px));
            for (0..4) |yy| ypl.data[base + yy * ypl.stride ..][0..4].* = pr[yy * 4 ..][0..4].*;
            if (codes[n] != 0) idctAdd(co[n * 16 ..][0..16], ypl.data[base..], ypl.stride);
        }
    }
    predBlock(upl, mb_x * 8, mb_y * 8, 8, mb.uvmode, mb_y > 0, mb_x > 0);
    predBlock(vpl, mb_x * 8, mb_y * 8, 8, mb.uvmode, mb_y > 0, mb_x > 0);
    for (0..4) |k| {
        const off = (mb_y * 8 + (k / 2) * 4) * upl.stride + mb_x * 8 + (k % 2) * 4;
        if (codes[16 + k] != 0) idctAdd(co[(16 + k) * 16 ..][0..16], upl.data[off..], upl.stride);
        if (codes[20 + k] != 0) idctAdd(co[(20 + k) * 16 ..][0..16], vpl.data[off..], vpl.stride);
    }
}
