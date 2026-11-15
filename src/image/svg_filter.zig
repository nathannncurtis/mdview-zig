const std = @import("std");

pub const Error = error{OutOfMemory};

pub const Img = struct {
    w: usize,
    h: usize,
    px: []f32,
    linear: bool = false,

    pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) Error!Img {
        const px = try alloc.alloc(f32, w * h * 4);
        @memset(px, 0);
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(i: Img, alloc: std.mem.Allocator) void {
        alloc.free(i.px);
    }

    pub fn clone(i: Img, alloc: std.mem.Allocator) Error!Img {
        const px = try alloc.dupe(f32, i.px);
        return .{ .w = i.w, .h = i.h, .px = px, .linear = i.linear };
    }
};

fn toLin(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn toSrgb(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

pub fn setSpace(i: *Img, linear: bool) void {
    if (i.linear == linear) return;
    var k: usize = 0;
    while (k < i.px.len) : (k += 4) {
        const a = i.px[k + 3];
        if (a <= 0) continue;
        for (0..3) |c| {
            const v = std.math.clamp(i.px[k + c] / a, 0, 1);
            i.px[k + c] = (if (linear) toLin(v) else toSrgb(v)) * a;
        }
    }
    i.linear = linear;
}

fn boxPass(src: []const f32, dst: []f32, w: usize, h: usize, horizontal: bool, left: usize, right: usize) void {
    const len = if (horizontal) w else h;
    const lines = if (horizontal) h else w;
    const step: usize = if (horizontal) 4 else w * 4;
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(left + right + 1));
    for (0..lines) |ln| {
        const base = if (horizontal) ln * w * 4 else ln * 4;
        for (0..4) |ch| {
            var sum: f32 = 0;
            const hi0 = @min(right, len - 1);
            for (0..hi0 + 1) |k| sum += src[base + k * step + ch];
            for (0..len) |x| {
                dst[base + x * step + ch] = sum * inv;
                if (x + right + 1 < len) sum += src[base + (x + right + 1) * step + ch];
                if (x >= left) sum -= src[base + (x - left) * step + ch];
            }
        }
    }
}

fn gaussKernel(alloc: std.mem.Allocator, sigma: f32) Error![]f32 {
    const r: usize = @intFromFloat(@ceil(sigma * 3));
    const k = try alloc.alloc(f32, r * 2 + 1);
    var sum: f32 = 0;
    for (k, 0..) |*v, i| {
        const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(r));
        v.* = @exp(-d * d / (2 * sigma * sigma));
        sum += v.*;
    }
    for (k) |*v| v.* /= sum;
    return k;
}

fn convPass(src: []const f32, dst: []f32, w: usize, h: usize, horizontal: bool, k: []const f32) void {
    const len: isize = @intCast(if (horizontal) w else h);
    const lines = if (horizontal) h else w;
    const step: usize = if (horizontal) 4 else w * 4;
    const r: isize = @intCast(k.len / 2);
    for (0..lines) |ln| {
        const base = if (horizontal) ln * w * 4 else ln * 4;
        var x: isize = 0;
        while (x < len) : (x += 1) {
            var acc = [4]f32{ 0, 0, 0, 0 };
            var j: isize = -r;
            while (j <= r) : (j += 1) {
                const xx = x + j;
                if (xx < 0 or xx >= len) continue;
                const wgt = k[@intCast(j + r)];
                const o = base + @as(usize, @intCast(xx)) * step;
                for (0..4) |ch| acc[ch] += src[o + ch] * wgt;
            }
            const o = base + @as(usize, @intCast(x)) * step;
            for (0..4) |ch| dst[o + ch] = acc[ch];
        }
    }
}

fn blurAxis(alloc: std.mem.Allocator, img: *Img, sigma: f32, horizontal: bool) Error!void {
    if (!(sigma > 0)) return;
    const tmp = try alloc.alloc(f32, img.px.len);
    defer alloc.free(tmp);
    if (sigma < 2) {
        const k = try gaussKernel(alloc, sigma);
        defer alloc.free(k);
        convPass(img.px, tmp, img.w, img.h, horizontal, k);
        @memcpy(img.px, tmp);
        return;
    }
    const d: usize = @intFromFloat(@floor(sigma * 3 * @sqrt(2.0 * std.math.pi) / 4 + 0.5));
    if (d % 2 == 1) {
        const r = d / 2;
        boxPass(img.px, tmp, img.w, img.h, horizontal, r, r);
        boxPass(tmp, img.px, img.w, img.h, horizontal, r, r);
        boxPass(img.px, tmp, img.w, img.h, horizontal, r, r);
        @memcpy(img.px, tmp);
    } else {
        const r = d / 2;
        boxPass(img.px, tmp, img.w, img.h, horizontal, r, r - 1);
        boxPass(tmp, img.px, img.w, img.h, horizontal, r - 1, r);
        boxPass(img.px, tmp, img.w, img.h, horizontal, r, r);
        @memcpy(img.px, tmp);
    }
}

pub fn blur(alloc: std.mem.Allocator, img: *Img, sx: f32, sy: f32) Error!void {
    try blurAxis(alloc, img, @min(sx, 400), true);
    try blurAxis(alloc, img, @min(sy, 400), false);
}

pub fn offset(alloc: std.mem.Allocator, src: Img, dx: isize, dy: isize) Error!Img {
    var out = try Img.init(alloc, src.w, src.h);
    out.linear = src.linear;
    const w: isize = @intCast(src.w);
    const h: isize = @intCast(src.h);
    var y: isize = 0;
    while (y < h) : (y += 1) {
        const sy = y - dy;
        if (sy < 0 or sy >= h) continue;
        var x: isize = 0;
        while (x < w) : (x += 1) {
            const sx = x - dx;
            if (sx < 0 or sx >= w) continue;
            const d: usize = (@as(usize, @intCast(y)) * src.w + @as(usize, @intCast(x))) * 4;
            const s: usize = (@as(usize, @intCast(sy)) * src.w + @as(usize, @intCast(sx))) * 4;
            @memcpy(out.px[d..][0..4], src.px[s..][0..4]);
        }
    }
    return out;
}

pub fn flood(img: *Img, c: [4]f32) void {
    var k: usize = 0;
    while (k < img.px.len) : (k += 4) {
        img.px[k] = c[0] * c[3];
        img.px[k + 1] = c[1] * c[3];
        img.px[k + 2] = c[2] * c[3];
        img.px[k + 3] = c[3];
    }
}

pub fn colorMatrix(img: *Img, m: [20]f32) void {
    var k: usize = 0;
    while (k < img.px.len) : (k += 4) {
        const a = img.px[k + 3];
        const c = if (a > 0) [4]f32{ img.px[k] / a, img.px[k + 1] / a, img.px[k + 2] / a, a } else [4]f32{ 0, 0, 0, 0 };
        var o: [4]f32 = undefined;
        for (0..4) |r| o[r] = std.math.clamp(m[r * 5] * c[0] + m[r * 5 + 1] * c[1] + m[r * 5 + 2] * c[2] + m[r * 5 + 3] * c[3] + m[r * 5 + 4], 0, 1);
        img.px[k] = o[0] * o[3];
        img.px[k + 1] = o[1] * o[3];
        img.px[k + 2] = o[2] * o[3];
        img.px[k + 3] = o[3];
    }
}

pub const Transfer = struct {
    kind: enum { identity, table, discrete, linear, gamma } = .identity,
    table: []const f32 = &.{},
    slope: f32 = 1,
    intercept: f32 = 0,
    amplitude: f32 = 1,
    exponent: f32 = 1,
    off: f32 = 0,

    fn eval(t: Transfer, c: f32) f32 {
        switch (t.kind) {
            .identity => return c,
            .table => {
                if (t.table.len == 0) return c;
                const n = t.table.len - 1;
                if (n == 0) return t.table[0];
                const pos = c * @as(f32, @floatFromInt(n));
                const k: usize = @min(@as(usize, @intFromFloat(@floor(pos))), n - 1);
                const f = pos - @as(f32, @floatFromInt(k));
                return t.table[k] + f * (t.table[k + 1] - t.table[k]);
            },
            .discrete => {
                if (t.table.len == 0) return c;
                const k: usize = @min(@as(usize, @intFromFloat(@floor(c * @as(f32, @floatFromInt(t.table.len))))), t.table.len - 1);
                return t.table[k];
            },
            .linear => return t.slope * c + t.intercept,
            .gamma => return t.amplitude * std.math.pow(f32, c, t.exponent) + t.off,
        }
    }
};

pub fn componentTransfer(img: *Img, f: [4]Transfer) void {
    var k: usize = 0;
    while (k < img.px.len) : (k += 4) {
        const a = img.px[k + 3];
        var c = if (a > 0) [4]f32{ img.px[k] / a, img.px[k + 1] / a, img.px[k + 2] / a, a } else [4]f32{ 0, 0, 0, 0 };
        for (0..4) |i| c[i] = std.math.clamp(f[i].eval(c[i]), 0, 1);
        img.px[k] = c[0] * c[3];
        img.px[k + 1] = c[1] * c[3];
        img.px[k + 2] = c[2] * c[3];
        img.px[k + 3] = c[3];
    }
}

pub const CompOp = enum { over, in, out, atop, xor, arithmetic };

pub fn composite(out: *Img, a: Img, b: Img, op: CompOp, k: [4]f32) void {
    var i: usize = 0;
    while (i < out.px.len) : (i += 4) {
        const aa = a.px[i + 3];
        const ba = b.px[i + 3];
        for (0..4) |c| {
            const x = a.px[i + c];
            const y = b.px[i + c];
            out.px[i + c] = switch (op) {
                .over => x + y * (1 - aa),
                .in => x * ba,
                .out => x * (1 - ba),
                .atop => x * ba + y * (1 - aa),
                .xor => x * (1 - ba) + y * (1 - aa),
                .arithmetic => std.math.clamp(k[0] * x * y + k[1] * x + k[2] * y + k[3], 0, 1),
            };
        }
        if (op == .arithmetic) {
            const al = out.px[i + 3];
            for (0..3) |c| out.px[i + c] = @min(out.px[i + c], al);
        }
    }
}

pub const BlendMode = enum { normal, multiply, screen, darken, lighten };

pub fn blend(out: *Img, a: Img, b: Img, mode: BlendMode) void {
    var i: usize = 0;
    while (i < out.px.len) : (i += 4) {
        const qa = a.px[i + 3];
        const qb = b.px[i + 3];
        for (0..3) |c| {
            const ca = a.px[i + c];
            const cb = b.px[i + c];
            out.px[i + c] = switch (mode) {
                .normal => (1 - qa) * cb + ca,
                .multiply => (1 - qa) * cb + (1 - qb) * ca + ca * cb,
                .screen => cb + ca - ca * cb,
                .darken => @min((1 - qa) * cb + ca, (1 - qb) * ca + cb),
                .lighten => @max((1 - qa) * cb + ca, (1 - qb) * ca + cb),
            };
        }
        out.px[i + 3] = 1 - (1 - qa) * (1 - qb);
    }
}

const bsize = 0x100;
const bm = 0xff;
const perlin_n = 0x1000;

const Noise = struct {
    lattice: [bsize + bsize + 2]i32,
    grad: [4][bsize + bsize + 2][2]f64,

    fn random(seed: i64) i64 {
        var r = 16807 * @rem(seed, 127773) - 2836 * @divTrunc(seed, 127773);
        if (r <= 0) r += 2147483647;
        return r;
    }

    fn init(seed_in: i64) Noise {
        var n: Noise = .{ .lattice = @splat(0), .grad = @splat(@splat(.{ 0, 0 })) };
        var seed = seed_in;
        if (seed <= 0) seed = -@rem(seed, 2147483646) + 1;
        if (seed > 2147483646) seed = 2147483646;
        for (0..4) |k| {
            for (0..bsize) |i| {
                n.lattice[i] = @intCast(i);
                for (0..2) |j| {
                    seed = random(seed);
                    n.grad[k][i][j] = @as(f64, @floatFromInt(@rem(seed, bsize + bsize) - bsize)) / bsize;
                }
                const s = @sqrt(n.grad[k][i][0] * n.grad[k][i][0] + n.grad[k][i][1] * n.grad[k][i][1]);
                if (s > 0) {
                    n.grad[k][i][0] /= s;
                    n.grad[k][i][1] /= s;
                }
            }
        }
        var i: usize = bsize - 1;
        while (i > 0) : (i -= 1) {
            const k = n.lattice[i];
            seed = random(seed);
            const j: usize = @intCast(@rem(seed, bsize));
            n.lattice[i] = n.lattice[j];
            n.lattice[j] = k;
        }
        for (0..bsize + 2) |q| {
            n.lattice[bsize + q] = n.lattice[q];
            for (0..4) |k| n.grad[k][bsize + q] = n.grad[k][q];
        }
        return n;
    }

    fn sCurve(t: f64) f64 {
        return t * t * (3.0 - 2.0 * t);
    }

    fn lerp(t: f64, a: f64, b: f64) f64 {
        return a + t * (b - a);
    }

    fn noise2(n: *const Noise, ch: usize, vx: f64, vy: f64) f64 {
        const tx = vx + perlin_n;
        const ix: i64 = @intFromFloat(@floor(tx));
        const bx0: usize = @intCast(ix & bm);
        const bx1 = (bx0 + 1) & bm;
        const rx0 = tx - @floor(tx);
        const rx1 = rx0 - 1;
        const ty = vy + perlin_n;
        const iy: i64 = @intFromFloat(@floor(ty));
        const by0: usize = @intCast(iy & bm);
        const by1 = (by0 + 1) & bm;
        const ry0 = ty - @floor(ty);
        const ry1 = ry0 - 1;
        const i: usize = @intCast(n.lattice[bx0]);
        const j: usize = @intCast(n.lattice[bx1]);
        const b00: usize = @intCast(n.lattice[i + by0]);
        const b10: usize = @intCast(n.lattice[j + by0]);
        const b01: usize = @intCast(n.lattice[i + by1]);
        const b11: usize = @intCast(n.lattice[j + by1]);
        const sx = sCurve(rx0);
        const sy = sCurve(ry0);
        const g = &n.grad[ch];
        const a = lerp(sx, rx0 * g[b00][0] + ry0 * g[b00][1], rx1 * g[b10][0] + ry0 * g[b10][1]);
        const b = lerp(sx, rx0 * g[b01][0] + ry1 * g[b01][1], rx1 * g[b11][0] + ry1 * g[b11][1]);
        return lerp(sy, a, b);
    }
};

pub const Turbulence = struct { fx: f64, fy: f64, octaves: u32, seed: i64, fractal: bool };

pub fn turbulence(img: *Img, ox: f64, oy: f64, inv: anytype, t: Turbulence) void {
    const n = Noise.init(t.seed);
    for (0..img.h) |row| {
        for (0..img.w) |col| {
            const p = inv.apply(.{ .x = ox + @as(f64, @floatFromInt(col)) + 0.5, .y = oy + @as(f64, @floatFromInt(row)) + 0.5 });
            var c: [4]f32 = .{ 0, 0, 0, 0 };
            for (0..4) |ch| {
                var sum: f64 = 0;
                var vx = p.x * t.fx;
                var vy = p.y * t.fy;
                var ratio: f64 = 1;
                for (0..t.octaves) |_| {
                    const v = n.noise2(ch, vx, vy);
                    sum += (if (t.fractal) v else @abs(v)) / ratio;
                    vx *= 2;
                    vy *= 2;
                    ratio *= 2;
                }
                const v = if (t.fractal) (sum + 1) / 2 else sum;
                c[ch] = @floatCast(std.math.clamp(v, 0, 1));
            }
            const o = (row * img.w + col) * 4;
            img.px[o] = c[0] * c[3];
            img.px[o + 1] = c[1] * c[3];
            img.px[o + 2] = c[2] * c[3];
            img.px[o + 3] = c[3];
        }
    }
}

fn morphAxis(alloc: std.mem.Allocator, img: *Img, radius: usize, horizontal: bool, dilate: bool) Error!void {
    if (radius == 0) return;
    const tmp = try alloc.alloc(f32, img.px.len);
    defer alloc.free(tmp);
    const len = if (horizontal) img.w else img.h;
    const lines = if (horizontal) img.h else img.w;
    const step: usize = if (horizontal) 4 else img.w * 4;
    for (0..lines) |ln| {
        const base = if (horizontal) ln * img.w * 4 else ln * 4;
        for (0..len) |x| {
            const lo = x -| radius;
            const hi = @min(x + radius, len - 1);
            for (0..4) |ch| {
                var v: f32 = if (dilate) 0 else 1;
                var k = lo;
                while (k <= hi) : (k += 1) {
                    const s = img.px[base + k * step + ch];
                    v = if (dilate) @max(v, s) else @min(v, s);
                }
                if (!dilate and (x < radius or x + radius >= len)) v = 0;
                tmp[base + x * step + ch] = v;
            }
        }
    }
    @memcpy(img.px, tmp);
}

pub fn morphology(alloc: std.mem.Allocator, img: *Img, rx: f64, ry: f64, dilate: bool) Error!void {
    try morphAxis(alloc, img, @intFromFloat(std.math.clamp(@round(rx), 0, 100)), true, dilate);
    try morphAxis(alloc, img, @intFromFloat(std.math.clamp(@round(ry), 0, 100)), false, dilate);
}

pub fn displacement(alloc: std.mem.Allocator, src: Img, map: Img, sx: f64, sy: f64, xch: usize, ych: usize) Error!Img {
    var out = try Img.init(alloc, src.w, src.h);
    out.linear = src.linear;
    const w: isize = @intCast(src.w);
    const h: isize = @intCast(src.h);
    for (0..src.h) |row| {
        for (0..src.w) |col| {
            const o = (row * src.w + col) * 4;
            const a = map.px[o + 3];
            const cx = if (xch == 3) a else if (a > 0) map.px[o + xch] / a else 0;
            const cy = if (ych == 3) a else if (a > 0) map.px[o + ych] / a else 0;
            const fx = @as(f64, @floatFromInt(col)) + sx * (cx - 0.5);
            const fy = @as(f64, @floatFromInt(row)) + sy * (cy - 0.5);
            const px: isize = @intFromFloat(std.math.clamp(@floor(fx + 0.5), -1e6, 1e6));
            const py: isize = @intFromFloat(std.math.clamp(@floor(fy + 0.5), -1e6, 1e6));
            if (px < 0 or py < 0 or px >= w or py >= h) continue;
            const s: usize = (@as(usize, @intCast(py)) * src.w + @as(usize, @intCast(px))) * 4;
            @memcpy(out.px[o..][0..4], src.px[s..][0..4]);
        }
    }
    return out;
}

pub const Convolve = struct {
    order_x: usize,
    order_y: usize,
    kernel: []const f32,
    divisor: f32,
    bias: f32,
    target_x: usize,
    target_y: usize,
    edge: enum { duplicate, wrap, none },
    preserve_alpha: bool,
};

pub fn convolve(alloc: std.mem.Allocator, src: Img, c: Convolve) Error!Img {
    var out = try Img.init(alloc, src.w, src.h);
    out.linear = src.linear;
    const w: isize = @intCast(src.w);
    const h: isize = @intCast(src.h);
    for (0..src.h) |row| {
        for (0..src.w) |col| {
            var acc = [4]f32{ 0, 0, 0, 0 };
            for (0..c.order_y) |j| {
                for (0..c.order_x) |i| {
                    var xx: isize = @as(isize, @intCast(col)) - @as(isize, @intCast(c.target_x)) + @as(isize, @intCast(i));
                    var yy: isize = @as(isize, @intCast(row)) - @as(isize, @intCast(c.target_y)) + @as(isize, @intCast(j));
                    switch (c.edge) {
                        .duplicate => {
                            xx = std.math.clamp(xx, 0, w - 1);
                            yy = std.math.clamp(yy, 0, h - 1);
                        },
                        .wrap => {
                            xx = @mod(xx, w);
                            yy = @mod(yy, h);
                        },
                        .none => if (xx < 0 or yy < 0 or xx >= w or yy >= h) continue,
                    }
                    const kv = c.kernel[(c.order_y - 1 - j) * c.order_x + (c.order_x - 1 - i)];
                    const s: usize = (@as(usize, @intCast(yy)) * src.w + @as(usize, @intCast(xx))) * 4;
                    var px = [4]f32{ src.px[s], src.px[s + 1], src.px[s + 2], src.px[s + 3] };
                    if (c.preserve_alpha and px[3] > 0) for (0..3) |k| {
                        px[k] /= px[3];
                    };
                    for (0..4) |k| acc[k] += px[k] * kv;
                }
            }
            const o = (row * src.w + col) * 4;
            const a_src = src.px[o + 3];
            var res: [4]f32 = .{ 0, 0, 0, 0 };
            for (0..4) |k| res[k] = acc[k] / c.divisor + c.bias;
            if (c.preserve_alpha) {
                res[3] = a_src;
                for (0..3) |k| res[k] = std.math.clamp(res[k], 0, 1) * a_src;
            } else {
                res[3] = std.math.clamp(res[3], 0, 1);
                for (0..3) |k| res[k] = std.math.clamp(res[k], 0, res[3]);
            }
            @memcpy(out.px[o..][0..4], &res);
        }
    }
    return out;
}

pub const Light = union(enum) {
    distant: struct { az: f64, el: f64 },
    point: [3]f64,
    spot: struct { pos: [3]f64, at: [3]f64, exp: f64, cone: ?f64 },
};

pub const Lighting = struct { light: Light, color: [3]f32, scale: f64, k: f64, exponent: f64, specular: bool };

fn norm3(v: [3]f64) [3]f64 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l == 0) return .{ 0, 0, 1 };
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

pub fn lighting(alloc: std.mem.Allocator, src: Img, p: Lighting) Error!Img {
    var out = try Img.init(alloc, src.w, src.h);
    const w: isize = @intCast(src.w);
    const h: isize = @intCast(src.h);
    const alphaAt = struct {
        fn f(im: Img, x: isize, y: isize, ww: isize, hh: isize) f64 {
            const cx: usize = @intCast(std.math.clamp(x, 0, ww - 1));
            const cy: usize = @intCast(std.math.clamp(y, 0, hh - 1));
            return im.px[(cy * im.w + cx) * 4 + 3];
        }
    }.f;
    var y: isize = 0;
    while (y < h) : (y += 1) {
        var x: isize = 0;
        while (x < w) : (x += 1) {
            const nx = -p.scale / 4 * ((alphaAt(src, x + 1, y - 1, w, h) + 2 * alphaAt(src, x + 1, y, w, h) + alphaAt(src, x + 1, y + 1, w, h)) - (alphaAt(src, x - 1, y - 1, w, h) + 2 * alphaAt(src, x - 1, y, w, h) + alphaAt(src, x - 1, y + 1, w, h)));
            const ny = -p.scale / 4 * ((alphaAt(src, x - 1, y + 1, w, h) + 2 * alphaAt(src, x, y + 1, w, h) + alphaAt(src, x + 1, y + 1, w, h)) - (alphaAt(src, x - 1, y - 1, w, h) + 2 * alphaAt(src, x, y - 1, w, h) + alphaAt(src, x + 1, y - 1, w, h)));
            const n = norm3(.{ nx, ny, 1 });
            const z = p.scale * alphaAt(src, x, y, w, h);
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            var lv = [3]f64{ 0, 0, 1 };
            var lc = [3]f64{ p.color[0], p.color[1], p.color[2] };
            switch (p.light) {
                .distant => |d| {
                    const az = d.az * std.math.pi / 180.0;
                    const el = d.el * std.math.pi / 180.0;
                    lv = .{ @cos(az) * @cos(el), @sin(az) * @cos(el), @sin(el) };
                },
                .point => |q| lv = norm3(.{ q[0] - fx, q[1] - fy, q[2] - z }),
                .spot => |sp| {
                    lv = norm3(.{ sp.pos[0] - fx, sp.pos[1] - fy, sp.pos[2] - z });
                    const sv = norm3(.{ sp.at[0] - sp.pos[0], sp.at[1] - sp.pos[1], sp.at[2] - sp.pos[2] });
                    const minus_l_dot_s = -(lv[0] * sv[0] + lv[1] * sv[1] + lv[2] * sv[2]);
                    var f: f64 = 0;
                    if (minus_l_dot_s > 0) {
                        f = std.math.pow(f64, minus_l_dot_s, sp.exp);
                        if (sp.cone) |cone| if (minus_l_dot_s < cone) {
                            f = 0;
                        };
                    }
                    for (&lc) |*c| c.* *= f;
                },
            }
            var rgb = [3]f64{ 0, 0, 0 };
            if (p.specular) {
                const hv = norm3(.{ lv[0], lv[1], lv[2] + 1 });
                const nh = @max(0, n[0] * hv[0] + n[1] * hv[1] + n[2] * hv[2]);
                const f = p.k * std.math.pow(f64, nh, p.exponent);
                for (&rgb, lc) |*o, c| o.* = std.math.clamp(f * c, 0, 1);
            } else {
                const f = p.k * @max(0, n[0] * lv[0] + n[1] * lv[1] + n[2] * lv[2]);
                for (&rgb, lc) |*o, c| o.* = std.math.clamp(f * c, 0, 1);
            }
            const o = (@as(usize, @intCast(y)) * src.w + @as(usize, @intCast(x))) * 4;
            out.px[o] = @floatCast(rgb[0]);
            out.px[o + 1] = @floatCast(rgb[1]);
            out.px[o + 2] = @floatCast(rgb[2]);
            out.px[o + 3] = if (p.specular) @floatCast(@max(rgb[0], @max(rgb[1], rgb[2]))) else 1;
        }
    }
    return out;
}

test "blur preserves mass and offset shifts" {
    const a = std.testing.allocator;
    var img = try Img.init(a, 16, 16);
    defer img.deinit(a);
    img.px[(8 * 16 + 8) * 4 + 3] = 1;
    try blur(a, &img, 2.5, 2.5);
    var sum: f32 = 0;
    var k: usize = 3;
    while (k < img.px.len) : (k += 4) sum += img.px[k];
    try std.testing.expectApproxEqAbs(@as(f32, 1), sum, 0.02);
    const o = try offset(a, img, 2, 0);
    defer o.deinit(a);
    try std.testing.expectApproxEqAbs(img.px[(8 * 16 + 8) * 4 + 3], o.px[(8 * 16 + 10) * 4 + 3], 1e-6);
}
