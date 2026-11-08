const std = @import("std");

pub const Chrm = struct { wx: f64, wy: f64, rx: f64, ry: f64, gx: f64, gy: f64, bx: f64, by: f64 };

pub const Kind = enum { gray, rgb, cmyk };

const Curve = struct {
    tf: [7]f32 = .{ 1, 1, 0, 0, 0, 0, 0 },
    table: []const u8 = &.{},
    wide: bool = false,
    n: u32 = 0,

    fn identity(self: *const Curve) bool {
        return self.n == 0 and self.tf[0] == 1 and self.tf[1] == 1 and self.tf[2] == 0 and self.tf[3] == 0 and self.tf[4] == 0 and self.tf[5] == 0 and self.tf[6] == 0;
    }

    fn entry(self: *const Curve, i: usize) f32 {
        if (self.wide) return @as(f32, @floatFromInt(std.mem.readInt(u16, self.table[i * 2 ..][0..2], .big))) / 65535.0;
        return @as(f32, @floatFromInt(self.table[i])) / 255.0;
    }

    fn eval(self: *const Curve, x: f32) f32 {
        if (self.n != 0) {
            const ix = std.math.clamp(x, 0, 1) * @as(f32, @floatFromInt(self.n - 1));
            const lo: usize = @intFromFloat(ix);
            const hi: usize = if (ix > @as(f32, @floatFromInt(lo))) @min(lo + 1, self.n - 1) else lo;
            const l = self.entry(lo);
            const h = self.entry(hi);
            return l + (h - l) * (ix - @as(f32, @floatFromInt(lo)));
        }
        const ax = @abs(x);
        const t = self.tf;
        const v = if (ax < t[4]) t[3] * ax + t[6] else std.math.pow(f32, t[1] * ax + t[2], t[0]) + t[5];
        return if (x < 0) -v else v;
    }
};

const Lut = struct {
    nin: u8 = 0,
    grid_points: [4]u8 = .{ 0, 0, 0, 0 },
    grid: []const u8 = &.{},
    wide: bool = false,
    in_curves: [4]Curve = @splat(.{}),
    has_matrix: bool = false,
    m: [12]f32 = @splat(0),
    m_curves: [3]Curve = @splat(.{}),
    out_curves: [3]Curve = @splat(.{}),
    lab: bool = false,

    fn gridValue(self: *const Lut, i: usize) f32 {
        if (self.wide) return @as(f32, @floatFromInt(std.mem.readInt(u16, self.grid[i * 2 ..][0..2], .big))) / 65535.0;
        return @as(f32, @floatFromInt(self.grid[i])) / 255.0;
    }

    fn clut(self: *const Lut, ins: [4]f32) [3]f32 {
        const dim: usize = self.nin;
        var index: [8]usize = @splat(0);
        var weight: [8]f32 = @splat(0);
        var stride: usize = 1;
        var i = dim;
        while (i > 0) {
            i -= 1;
            const x = std.math.clamp(ins[i], 0, 1) * @as(f32, @floatFromInt(self.grid_points[i] - 1));
            const lo: usize = @intFromFloat(x);
            const hi: usize = if (x > @as(f32, @floatFromInt(lo))) lo + 1 else lo;
            index[i] = lo * stride;
            index[i + 4] = hi * stride;
            stride *= self.grid_points[i];
            const t = x - @as(f32, @floatFromInt(lo));
            weight[i] = 1 - t;
            weight[i + 4] = t;
        }
        var out: [3]f32 = .{ 0, 0, 0 };
        for (0..@as(usize, 1) << @intCast(dim)) |combo| {
            var ix: usize = 0;
            var w: f32 = 1;
            for (0..dim) |d| {
                const hi: usize = (combo >> @intCast(d)) & 1;
                ix += index[d + hi * 4];
                w *= weight[d + hi * 4];
            }
            out[0] += w * self.gridValue(ix * 3);
            out[1] += w * self.gridValue(ix * 3 + 1);
            out[2] += w * self.gridValue(ix * 3 + 2);
        }
        return out;
    }
};

pub const Transform = struct {
    gray: bool = false,
    use_lut: bool = false,
    lin: [3][256]f32 = @splat(@splat(0)),
    m: [9]f32 = @splat(0),
    gray_out: [256]u8 = @splat(0),
    enc: [65536]u8 = @splat(0),
    lut: Lut = .{},
    in_lut: [4][256]f32 = @splat(@splat(0)),

    pub fn apply(self: *const Transform, px: []u8) void {
        var i: usize = 0;
        while (i + 4 <= px.len) : (i += 4) {
            if (self.gray) {
                const g = self.gray_out[px[i]];
                px[i] = g;
                px[i + 1] = g;
                px[i + 2] = g;
                continue;
            }
            if (self.use_lut) {
                const o = self.lutPixel(.{ self.in_lut[0][px[i]], self.in_lut[1][px[i + 1]], self.in_lut[2][px[i + 2]], 0 });
                px[i] = o[0];
                px[i + 1] = o[1];
                px[i + 2] = o[2];
                continue;
            }
            const r = self.lin[0][px[i]];
            const g = self.lin[1][px[i + 1]];
            const b = self.lin[2][px[i + 2]];
            const m = &self.m;
            px[i] = self.enc[quant(m[0] * r + m[1] * g + m[2] * b)];
            px[i + 1] = self.enc[quant(m[3] * r + m[4] * g + m[5] * b)];
            px[i + 2] = self.enc[quant(m[6] * r + m[7] * g + m[8] * b)];
        }
    }

    pub fn cmyk(self: *const Transform, c: u8, m: u8, y: u8, k: u8) [3]u8 {
        return self.lutPixel(.{ self.in_lut[0][c], self.in_lut[1][m], self.in_lut[2][y], self.in_lut[3][k] });
    }

    fn lutPixel(self: *const Transform, ins: [4]f32) [3]u8 {
        const l = &self.lut;
        var v: [3]f32 = .{ ins[0], ins[1], ins[2] };
        if (l.nin != 0) v = l.clut(ins);
        if (l.has_matrix) {
            for (0..3) |c| v[c] = l.m_curves[c].eval(v[c]);
            const m = &l.m;
            v = .{
                m[0] * v[0] + m[1] * v[1] + m[2] * v[2] + m[9],
                m[3] * v[0] + m[4] * v[1] + m[5] * v[2] + m[10],
                m[6] * v[0] + m[7] * v[1] + m[8] * v[2] + m[11],
            };
        }
        for (0..3) |c| {
            if (!l.out_curves[c].identity()) v[c] = l.out_curves[c].eval(v[c]);
        }
        if (l.lab) v = labToXyz(v);
        const m = &self.m;
        return .{
            self.enc[quant(m[0] * v[0] + m[1] * v[1] + m[2] * v[2])],
            self.enc[quant(m[3] * v[0] + m[4] * v[1] + m[5] * v[2])],
            self.enc[quant(m[6] * v[0] + m[7] * v[1] + m[8] * v[2])],
        };
    }
};

fn labToXyz(v: [3]f32) [3]f32 {
    const L = v[0] * 100.0;
    const A = v[1] * 255.0 - 128.0;
    const B = v[2] * 255.0 - 128.0;
    const y = (L + 16.0) * (1.0 / 116.0);
    const x = y + A * (1.0 / 500.0);
    const z = y - B * (1.0 / 200.0);
    return .{ labF(x) * 0.9642, labF(y), labF(z) * 0.8249 };
}

fn labF(t: f32) f32 {
    const c = t * t * t;
    return if (c > 0.008856) c else (t - 16.0 / 116.0) * (1.0 / 7.787);
}

fn quant(x: f32) usize {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 65535));
}

const srgb_to_xyz = [9]f64{ 0.436065674, 0.385147095, 0.143066406, 0.222488403, 0.716873169, 0.060607910, 0.013916016, 0.097076416, 0.714096069 };
const d50 = [3]f64{ 0.9642, 1.0, 0.8249 };

fn srgbEncode(x: f64) f64 {
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055;
}

fn mul3(a: [9]f64, b: [9]f64) [9]f64 {
    var r: [9]f64 = undefined;
    for (0..3) |i| for (0..3) |j| {
        r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    };
    return r;
}

fn inv3(m: [9]f64) ?[9]f64 {
    const a = m[0];
    const b = m[1];
    const c = m[2];
    const d = m[3];
    const e = m[4];
    const f = m[5];
    const g = m[6];
    const h = m[7];
    const i = m[8];
    const det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (@abs(det) < 1e-9) return null;
    return .{
        (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
        (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
        (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
    };
}

fn be32(p: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .big);
}

fn be16(p: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, p[off..][0..2], .big);
}

fn s15(p: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(std.mem.readInt(i32, p[off..][0..4], .big))) / 65536.0;
}

const Tag = struct { off: usize, size: usize };

fn findTag(p: []const u8, sig: *const [4]u8) ?Tag {
    const n = be32(p, 128);
    for (0..n) |i| {
        const e = p[132 + i * 12 ..][0..12];
        if (!std.mem.eql(u8, e[0..4], sig)) continue;
        return .{ .off = be32(e, 4), .size = be32(e, 8) };
    }
    return null;
}

fn validate(p: []const u8) ?[]const u8 {
    if (p.len < 132 or !std.mem.eql(u8, p[36..40], "acsp")) return null;
    const size = be32(p, 0);
    if (size > p.len or size < 132) return null;
    const n = be32(p, 128);
    if (n > 1000 or 132 + @as(u64, n) * 12 > size) return null;
    if ((be32(p, 8) >> 24) > 4) return null;
    if (@abs(s15(p, 68) - 0.9642) > 0.01 or @abs(s15(p, 72) - 1.0) > 0.01 or @abs(s15(p, 76) - 0.8249) > 0.01) return null;
    for (0..n) |i| {
        const e = 132 + i * 12;
        const off = be32(p, e + 4);
        const sz = be32(p, e + 8);
        if (sz < 4 or @as(u64, off) + sz > size) return null;
    }
    const pcs = p[20..24];
    if (!std.mem.eql(u8, pcs, "XYZ ") and !std.mem.eql(u8, pcs, "Lab ")) return null;
    return p[0..size];
}

fn readXyz(p: []const u8, sig: *const [4]u8) ?[3]f64 {
    const t = findTag(p, sig) orelse return null;
    if (t.size < 20 or !std.mem.eql(u8, p[t.off..][0..4], "XYZ ")) return null;
    return .{ s15(p, t.off + 8), s15(p, t.off + 12), s15(p, t.off + 16) };
}

fn readCurve(p: []const u8, off: usize, avail: usize, used: *usize) ?Curve {
    if (avail < 4) return null;
    var c: Curve = .{};
    if (std.mem.eql(u8, p[off..][0..4], "para")) {
        if (avail < 12) return null;
        const ft = be16(p, off + 8);
        if (ft > 4) return null;
        const bytes = [_]usize{ 4, 12, 16, 20, 28 };
        if (avail < 12 + bytes[ft]) return null;
        used.* = 12 + bytes[ft];
        const v = struct {
            fn at(pp: []const u8, o: usize, i: usize) f32 {
                return @floatCast(s15(pp, o + 12 + i * 4));
            }
        };
        c.tf[0] = v.at(p, off, 0);
        switch (ft) {
            1, 2 => {
                c.tf[1] = v.at(p, off, 1);
                c.tf[2] = v.at(p, off, 2);
                if (c.tf[1] == 0) return null;
                c.tf[4] = -c.tf[2] / c.tf[1];
                if (ft == 2) {
                    c.tf[5] = v.at(p, off, 3);
                    c.tf[6] = c.tf[5];
                }
            },
            3, 4 => {
                for (1..5) |i| c.tf[i] = v.at(p, off, i);
                if (ft == 4) {
                    c.tf[5] = v.at(p, off, 5);
                    c.tf[6] = v.at(p, off, 6);
                }
            },
            else => {},
        }
        const t = c.tf;
        const sum = t[0] + t[1] + t[2] + t[3] + t[4] + t[5] + t[6];
        if (!std.math.isFinite(sum) or t[1] < 0 or t[3] < 0 or t[4] < 0 or t[0] < 0 or t[1] * t[4] + t[2] < 0) return null;
        return c;
    }
    if (std.mem.eql(u8, p[off..][0..4], "curv")) {
        if (avail < 12) return null;
        const n = be32(p, off + 8);
        if (@as(u64, n) * 2 + 12 > avail) return null;
        used.* = 12 + n * 2;
        if (n < 2) {
            c.tf[0] = if (n == 0) 1 else @as(f32, @floatFromInt(be16(p, off + 12))) * (1.0 / 256.0);
            return c;
        }
        if (n > 1 << 24) return null;
        c.table = p[off + 12 ..][0 .. n * 2];
        c.wide = true;
        c.n = n;
        return c;
    }
    return null;
}

fn readCurves(p: []const u8, base: usize, size: usize, curve_off: usize, out: []Curve) ?void {
    var off = curve_off;
    for (out) |*c| {
        if (off > size) return null;
        var used: usize = 0;
        c.* = readCurve(p, base + off, size - off, &used) orelse return null;
        off += (used + 3) & ~@as(usize, 3);
    }
    return {};
}

fn readTables(l: *Lut, p: []const u8, tag: Tag, fixed: usize, nout: usize, bw: usize, in_entries: usize, out_entries: usize) bool {
    if (tag.size < fixed) return false;
    const base = tag.off + fixed;
    const avail = tag.size - fixed;
    var grid: usize = nout * bw;
    for (0..l.nin) |i| grid *= l.grid_points[i];
    const in_len = in_entries * bw;
    const out_len = out_entries * bw;
    if (avail < l.nin * in_len + grid + nout * out_len) return false;
    for (0..l.nin) |i| {
        l.in_curves[i] = .{ .table = p[base + i * in_len ..][0..in_len], .wide = bw == 2, .n = @intCast(in_entries) };
    }
    l.grid = p[base + l.nin * in_len ..][0..grid];
    l.wide = bw == 2;
    const obase = base + l.nin * in_len + grid;
    for (0..3) |i| {
        l.out_curves[i] = .{ .table = p[obase + i * out_len ..][0..out_len], .wide = bw == 2, .n = @intCast(out_entries) };
    }
    return true;
}

fn parseA2b(p: []const u8, tag: Tag, pcs_xyz: bool) ?Lut {
    var l: Lut = .{};
    const t = p[tag.off..][0..tag.size];
    if (tag.size < 8) return null;
    const typ = t[0..4];
    if (std.mem.eql(u8, typ, "mft1") or std.mem.eql(u8, typ, "mft2")) {
        const is2 = typ[3] == '2';
        const fixed: usize = if (is2) 52 else 48;
        if (tag.size < fixed) return null;
        l.nin = t[8];
        if (t[9] != 3 or l.nin < 1 or l.nin > 4) return null;
        var total: u64 = 1;
        for (0..l.nin) |i| {
            l.grid_points[i] = t[10];
            total *= t[10];
        }
        if (t[10] < 2 or total > 350_000_000) return null;
        var ine: usize = 256;
        var oute: usize = 256;
        if (is2) {
            ine = be16(t, 48);
            oute = be16(t, 50);
            if (ine < 2 or ine > 4096 or oute < 2 or oute > 4096) return null;
        }
        if (!readTables(&l, p, tag, fixed, 3, if (is2) 2 else 1, ine, oute)) return null;
    } else if (std.mem.eql(u8, typ, "mAB ")) {
        if (tag.size < 32) return null;
        l.nin = t[8];
        if (t[9] != 3 or l.nin > 4) return null;
        const b_off = be32(t, 12);
        const mat_off = be32(t, 16);
        const m_off = be32(t, 20);
        const clut_off = be32(t, 24);
        const a_off = be32(t, 28);
        if (b_off == 0) return null;
        readCurves(p, tag.off, tag.size, b_off, &l.out_curves) orelse return null;
        if (m_off != 0) {
            if (mat_off == 0) return null;
            readCurves(p, tag.off, tag.size, m_off, &l.m_curves) orelse return null;
            if (tag.size < @as(u64, mat_off) + 48) return null;
            const enc: f64 = if (pcs_xyz) 65535.0 / 32768.0 else 1.0;
            for (0..12) |i| l.m[i] = @floatCast(enc * s15(t, mat_off + i * 4));
            l.has_matrix = true;
        } else if (mat_off != 0) return null;
        if (a_off != 0) {
            if (clut_off == 0) return null;
            const nin: usize = l.nin;
            readCurves(p, tag.off, tag.size, a_off, l.in_curves[0..nin]) orelse return null;
            if (tag.size < @as(u64, clut_off) + 20) return null;
            const bw = t[clut_off + 16];
            if (bw != 1 and bw != 2) return null;
            var grid: u64 = 3 * @as(u64, bw);
            var total: u64 = 1;
            for (0..nin) |i| {
                l.grid_points[i] = t[clut_off + i];
                if (l.grid_points[i] < 2) return null;
                grid *= l.grid_points[i];
                total *= l.grid_points[i];
            }
            if (total > 350_000_000 or @as(u64, clut_off) + 20 + grid > tag.size) return null;
            l.grid = t[clut_off + 20 ..][0..@intCast(grid)];
            l.wide = bw == 2;
        } else {
            if (clut_off != 0 or l.nin != 3) return null;
            l.nin = 0;
        }
    } else return null;
    l.lab = !pcs_xyz;
    return l;
}

fn buildEncode(t: *Transform) void {
    for (0..65536) |i| {
        const v = srgbEncode(@as(f64, @floatFromInt(i)) / 65535.0);
        t.enc[i] = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
    }
}

fn finish(t: *Transform) ?*const Transform {
    if (t.gray) {
        var same = true;
        for (0..256) |i| {
            if (@abs(@as(i32, t.gray_out[i]) - @as(i32, @intCast(i))) > 1) same = false;
        }
        return if (same) null else t;
    }
    var worst: i32 = 0;
    const steps = [_]u8{ 0, 51, 102, 153, 204, 255 };
    for (steps) |r| for (steps) |g| for (steps) |b| {
        var px = [4]u8{ r, g, b, 255 };
        t.apply(&px);
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, px[0]) - r))), @as(i32, @intCast(@abs(@as(i32, px[1]) - g))), @as(i32, @intCast(@abs(@as(i32, px[2]) - b))));
    };
    for (0..256) |v| {
        var px = [4]u8{ @intCast(v), @intCast(v), @intCast(v), 255 };
        t.apply(&px);
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, px[0]) - @as(i32, @intCast(v))))));
    }
    return if (worst <= 1) null else t;
}

pub fn fromProfile(out: *Transform, whole: []const u8, kind: Kind) ?*const Transform {
    const p = validate(whole) orelse return null;
    const space = p[16..20];
    const is_gray = std.mem.eql(u8, space, "GRAY");
    const is_rgb = std.mem.eql(u8, space, "RGB ");
    const is_cmyk = std.mem.eql(u8, space, "CMYK");
    const pcs_xyz = std.mem.eql(u8, p[20..24], "XYZ ");
    switch (kind) {
        .gray => if (!is_gray and !is_rgb) return null,
        .rgb => if (!is_rgb) return null,
        .cmyk => if (!is_cmyk) return null,
    }
    const a2b_tag = findTag(p, "A2B0") orelse findTag(p, "A2B1");
    if (a2b_tag != null and !is_gray) {
        out.lut = parseA2b(p, a2b_tag.?, pcs_xyz) orelse return null;
        const nin = out.lut.nin;
        if (kind == .cmyk) {
            if (nin != 4) return null;
        } else if (nin != 3 and nin != 0) return null;
        out.gray = false;
        out.use_lut = true;
        const inv = inv3(srgb_to_xyz) orelse return null;
        for (0..9) |i| out.m[i] = @floatCast(inv[i]);
        buildEncode(out);
        if (nin != 0) {
            for (0..nin) |c| for (0..256) |v| {
                var x = @as(f32, @floatFromInt(v)) / 255.0;
                if (kind == .cmyk) x = 1 - x;
                out.in_lut[c][v] = std.math.clamp(out.lut.in_curves[c].eval(x), 0, 1);
            };
        } else for (0..3) |c| for (0..256) |v| {
            out.in_lut[c][v] = @as(f32, @floatFromInt(v)) / 255.0;
        };
        return out;
    }
    if (kind == .cmyk) return null;
    if (is_gray) {
        const k = findTag(p, "kTRC") orelse return null;
        var used: usize = 0;
        const curve = readCurve(p, k.off, k.size, &used) orelse return null;
        out.gray = true;
        for (0..256) |i| {
            const y = curve.eval(@as(f32, @floatFromInt(i)) / 255.0);
            out.gray_out[i] = @intFromFloat(@round(std.math.clamp(srgbEncode(std.math.clamp(y, 0, 1)), 0, 1) * 255));
        }
        return finish(out);
    }
    const rx = readXyz(p, "rXYZ") orelse return null;
    const gx = readXyz(p, "gXYZ") orelse return null;
    const bx = readXyz(p, "bXYZ") orelse return null;
    const tags = [3]Tag{
        findTag(p, "rTRC") orelse return null,
        findTag(p, "gTRC") orelse return null,
        findTag(p, "bTRC") orelse return null,
    };
    out.gray = false;
    out.use_lut = false;
    for (0..3) |c| {
        var used: usize = 0;
        const curve = readCurve(p, tags[c].off, tags[c].size, &used) orelse return null;
        for (0..256) |i| out.lin[c][i] = std.math.clamp(curve.eval(@as(f32, @floatFromInt(i)) / 255.0), 0, 1);
    }
    const src = [9]f64{ rx[0], gx[0], bx[0], rx[1], gx[1], bx[1], rx[2], gx[2], bx[2] };
    return setMatrix(out, src);
}

fn setMatrix(out: *Transform, src: [9]f64) ?*const Transform {
    const inv = inv3(srgb_to_xyz) orelse return null;
    const m = mul3(inv, src);
    for (0..9) |i| out.m[i] = @floatCast(m[i]);
    buildEncode(out);
    return finish(out);
}

pub fn fromGamma(out: *Transform, file_gamma: f64, chrm: ?Chrm) ?*const Transform {
    if (file_gamma <= 0) return null;
    const e = 1.0 / file_gamma;
    var src = srgb_to_xyz;
    if (chrm) |c| {
        src = primariesToXyzD50(c) orelse return null;
    } else if (e >= 2.1 and e <= 2.3) return null;
    out.gray = false;
    out.use_lut = false;
    for (0..3) |c| for (0..256) |i| {
        out.lin[c][i] = @floatCast(std.math.pow(f64, @as(f64, @floatFromInt(i)) / 255.0, e));
    };
    return setMatrix(out, src);
}

fn primariesToXyzD50(c: Chrm) ?[9]f64 {
    if (c.ry == 0 or c.gy == 0 or c.by == 0 or c.wy == 0) return null;
    const p = [9]f64{ c.rx / c.ry, c.gx / c.gy, c.bx / c.by, 1, 1, 1, (1 - c.rx - c.ry) / c.ry, (1 - c.gx - c.gy) / c.gy, (1 - c.bx - c.by) / c.by };
    const w = [3]f64{ c.wx / c.wy, 1, (1 - c.wx - c.wy) / c.wy };
    const pi = inv3(p) orelse return null;
    const s = [3]f64{
        pi[0] * w[0] + pi[1] * w[1] + pi[2] * w[2],
        pi[3] * w[0] + pi[4] * w[1] + pi[5] * w[2],
        pi[6] * w[0] + pi[7] * w[1] + pi[8] * w[2],
    };
    const m = [9]f64{ p[0] * s[0], p[1] * s[1], p[2] * s[2], p[3] * s[0], p[4] * s[1], p[5] * s[2], p[6] * s[0], p[7] * s[1], p[8] * s[2] };
    const bfd = [9]f64{ 0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296 };
    const bi = inv3(bfd) orelse return null;
    const ws = [3]f64{
        bfd[0] * w[0] + bfd[1] * w[1] + bfd[2] * w[2],
        bfd[3] * w[0] + bfd[4] * w[1] + bfd[5] * w[2],
        bfd[6] * w[0] + bfd[7] * w[1] + bfd[8] * w[2],
    };
    const wd = [3]f64{
        bfd[0] * d50[0] + bfd[1] * d50[1] + bfd[2] * d50[2],
        bfd[3] * d50[0] + bfd[4] * d50[1] + bfd[5] * d50[2],
        bfd[6] * d50[0] + bfd[7] * d50[1] + bfd[8] * d50[2],
    };
    if (ws[0] == 0 or ws[1] == 0 or ws[2] == 0) return null;
    const diag = [9]f64{ wd[0] / ws[0], 0, 0, 0, wd[1] / ws[1], 0, 0, 0, wd[2] / ws[2] };
    return mul3(mul3(mul3(bi, diag), bfd), m);
}
