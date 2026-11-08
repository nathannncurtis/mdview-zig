const std = @import("std");

pub const Chrm = struct { wx: f64, wy: f64, rx: f64, ry: f64, gx: f64, gy: f64, bx: f64, by: f64 };

pub const Transform = struct {
    gray: bool,
    lin: [3][256]f32,
    m: [9]f32,
    gray_out: [256]u8,
    enc: [65536]u8,

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
            const r = self.lin[0][px[i]];
            const g = self.lin[1][px[i + 1]];
            const b = self.lin[2][px[i + 2]];
            const m = &self.m;
            px[i] = self.enc[quant(m[0] * r + m[1] * g + m[2] * b)];
            px[i + 1] = self.enc[quant(m[3] * r + m[4] * g + m[5] * b)];
            px[i + 2] = self.enc[quant(m[6] * r + m[7] * g + m[8] * b)];
        }
    }
};

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

fn s15(p: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(std.mem.readInt(i32, p[off..][0..4], .big))) / 65536.0;
}

const Tag = struct { off: usize, size: usize };

fn findTag(p: []const u8, sig: *const [4]u8) ?Tag {
    const n = std.mem.readInt(u32, p[128..132], .big);
    if (n > 200 or 132 + @as(usize, n) * 12 > p.len) return null;
    for (0..n) |i| {
        const e = p[132 + i * 12 ..][0..12];
        if (!std.mem.eql(u8, e[0..4], sig)) continue;
        const off = std.mem.readInt(u32, e[4..8], .big);
        const size = std.mem.readInt(u32, e[8..12], .big);
        if (@as(u64, off) + size > p.len or size < 8) return null;
        return .{ .off = off, .size = size };
    }
    return null;
}

fn readXyz(p: []const u8, sig: *const [4]u8) ?[3]f64 {
    const t = findTag(p, sig) orelse return null;
    if (t.size < 20 or !std.mem.eql(u8, p[t.off..][0..4], "XYZ ")) return null;
    return .{ s15(p, t.off + 8), s15(p, t.off + 12), s15(p, t.off + 16) };
}

fn evalCurve(p: []const u8, t: Tag, x: f64) ?f64 {
    const d = p[t.off .. t.off + t.size];
    if (std.mem.eql(u8, d[0..4], "curv")) {
        if (d.len < 12) return null;
        const n = std.mem.readInt(u32, d[8..12], .big);
        if (n == 0) return x;
        if (@as(u64, n) * 2 + 12 > d.len) return null;
        if (n == 1) return std.math.pow(f64, x, @as(f64, @floatFromInt(std.mem.readInt(u16, d[12..14], .big))) / 256.0);
        const pos = x * @as(f64, @floatFromInt(n - 1));
        const i: usize = @min(@as(usize, @intFromFloat(pos)), n - 2);
        const f = pos - @as(f64, @floatFromInt(i));
        const a: f64 = @floatFromInt(std.mem.readInt(u16, d[12 + i * 2 ..][0..2], .big));
        const b: f64 = @floatFromInt(std.mem.readInt(u16, d[14 + i * 2 ..][0..2], .big));
        return (a + (b - a) * f) / 65535.0;
    }
    if (std.mem.eql(u8, d[0..4], "para")) {
        if (d.len < 16) return null;
        const ft = std.mem.readInt(u16, d[8..10], .big);
        const counts = [_]usize{ 1, 3, 4, 5, 7 };
        if (ft > 4 or 12 + counts[ft] * 4 > d.len) return null;
        var q = [_]f64{ 0, 1, 0, 0, 0, 0, 0 };
        for (0..counts[ft]) |i| q[i] = s15(d, 12 + i * 4);
        const g = q[0];
        const a = q[1];
        const b = q[2];
        const c = q[3];
        const dd = q[4];
        const e = q[5];
        const f = q[6];
        const y = switch (ft) {
            0 => std.math.pow(f64, x, g),
            1 => if (a != 0 and x >= -b / a) std.math.pow(f64, a * x + b, g) else 0,
            2 => if (a != 0 and x >= -b / a) std.math.pow(f64, a * x + b, g) + c else c,
            3 => if (x >= dd) std.math.pow(f64, a * x + b, g) else c * x,
            else => if (x >= dd) std.math.pow(f64, a * x + b, g) + e else c * x + f,
        };
        return y;
    }
    return null;
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

pub fn fromProfile(out: *Transform, p: []const u8, gray_image: bool) ?*const Transform {
    if (p.len < 132 or !std.mem.eql(u8, p[36..40], "acsp")) return null;
    if (!std.mem.eql(u8, p[20..24], "XYZ ")) return null;
    if (findTag(p, "A2B0") != null) return null;
    const space = p[16..20];
    if (gray_image) {
        if (!std.mem.eql(u8, space, "GRAY")) return null;
        const k = findTag(p, "kTRC") orelse return null;
        out.gray = true;
        for (0..256) |i| {
            const y = evalCurve(p, k, @as(f64, @floatFromInt(i)) / 255.0) orelse return null;
            out.gray_out[i] = @intFromFloat(@round(std.math.clamp(srgbEncode(std.math.clamp(y, 0, 1)), 0, 1) * 255));
        }
        return finish(out);
    }
    if (!std.mem.eql(u8, space, "RGB ")) return null;
    const rx = readXyz(p, "rXYZ") orelse return null;
    const gx = readXyz(p, "gXYZ") orelse return null;
    const bx = readXyz(p, "bXYZ") orelse return null;
    const tags = [3]Tag{
        findTag(p, "rTRC") orelse return null,
        findTag(p, "gTRC") orelse return null,
        findTag(p, "bTRC") orelse return null,
    };
    out.gray = false;
    for (0..3) |c| {
        for (0..256) |i| {
            const y = evalCurve(p, tags[c], @as(f64, @floatFromInt(i)) / 255.0) orelse return null;
            out.lin[c][i] = @floatCast(std.math.clamp(y, 0, 1));
        }
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
