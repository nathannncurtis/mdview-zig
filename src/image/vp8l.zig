const std = @import("std");
const image = @import("image.zig");
const Error = image.Error;

const num_literal = 256;
const num_length = 24;
const num_dist = 40;
const max_cache_bits = 11;
const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const code_to_plane = [120]u8{
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a,
    0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
    0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b,
    0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
    0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c,
    0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b,
    0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
    0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b,
    0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
    0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f,
    0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    buf: u64 = 0,
    nbits: u7 = 0,
    eos: bool = false,

    fn fill(self: *BitReader) void {
        while (self.nbits <= 56 and self.pos < self.data.len) {
            self.buf |= @as(u64, self.data[self.pos]) << @intCast(self.nbits);
            self.pos += 1;
            self.nbits += 8;
        }
    }

    fn consume(self: *BitReader, n: u7) void {
        if (n > self.nbits) {
            self.eos = true;
            self.buf = 0;
            self.nbits = 0;
            return;
        }
        self.buf >>= @intCast(n);
        self.nbits -= n;
    }

    fn read(self: *BitReader, n: u7) u32 {
        if (n == 0) return 0;
        if (self.nbits < n) self.fill();
        const v: u32 = @intCast(self.buf & ((@as(u64, 1) << @intCast(n)) - 1));
        self.consume(n);
        return v;
    }
};

const Huff = struct {
    trivial: ?u16 = null,
    table: [256]u16 = @splat(0),
    counts: [16]u16 = @splat(0),
    symbols: []u16 = &.{},

    fn sym(self: *const Huff, br: *BitReader) u16 {
        if (self.trivial) |s| return s;
        if (br.nbits < 15) br.fill();
        const e = self.table[br.buf & 255];
        if (e != 0) {
            br.consume(@intCast(e & 15));
            return e >> 4;
        }
        var code: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        var buf = br.buf;
        var len: u7 = 1;
        while (len <= 15) : (len += 1) {
            code |= @intCast(buf & 1);
            buf >>= 1;
            const count = self.counts[len];
            if (code < first + count) {
                br.consume(len);
                return self.symbols[index + code - first];
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        br.eos = true;
        return 0;
    }
};

fn checkLengths(lengths: []const u8) Error!?u16 {
    var counts: [16]u32 = @splat(0);
    var nsym: u32 = 0;
    var last: u16 = 0;
    for (lengths, 0..) |l, i| {
        if (l != 0) {
            counts[l] += 1;
            nsym += 1;
            last = @intCast(i);
        }
    }
    if (nsym == 0) return error.Corrupt;
    if (nsym == 1) return last;
    var kraft: u32 = 0;
    for (1..16) |l| kraft += counts[l] << @intCast(15 - l);
    if (kraft != 1 << 15) return error.Corrupt;
    return null;
}

fn buildHuff(alloc: std.mem.Allocator, lengths: []const u8) Error!Huff {
    var h: Huff = .{};
    if (try checkLengths(lengths)) |s| {
        h.trivial = s;
        return h;
    }
    var nsym: usize = 0;
    for (lengths) |l| {
        if (l != 0) {
            h.counts[l] += 1;
            nsym += 1;
        }
    }
    h.symbols = try alloc.alloc(u16, nsym);
    var offs: [17]usize = @splat(0);
    for (1..16) |l| offs[l + 1] = offs[l] + h.counts[l];
    for (lengths, 0..) |l, i| {
        if (l != 0) {
            h.symbols[offs[l]] = @intCast(i);
            offs[l] += 1;
        }
    }
    var code: u32 = 0;
    var k: usize = 0;
    for (1..16) |l| {
        for (0..h.counts[l]) |_| {
            if (l <= 8) {
                var rev: u32 = 0;
                for (0..l) |b| rev |= ((code >> @intCast(b)) & 1) << @intCast(l - 1 - b);
                const e: u16 = (h.symbols[k] << 4) | @as(u16, @intCast(l));
                var idx = rev;
                while (idx < 256) : (idx += @as(u32, 1) << @intCast(l)) h.table[idx] = e;
            }
            code += 1;
            k += 1;
        }
        code <<= 1;
    }
    return h;
}

const Transform = struct {
    kind: u2,
    bits: u5 = 0,
    xsize: u32,
    ysize: u32,
    data: []u32 = &.{},
};

const Group = [5]Huff;

const Meta = struct {
    groups: []Group,
    huff_image: []u32 = &.{},
    huff_bits: u5 = 0,
    huff_xsize: u32 = 0,
    cache_bits: u5 = 0,
};

fn subSample(size: u32, bits: u5) u32 {
    return (size + (@as(u32, 1) << bits) - 1) >> bits;
}

const Decoder = struct {
    br: BitReader,
    arena: std.mem.Allocator,
    transforms: [4]Transform = @splat(.{ .kind = 0, .xsize = 0, .ysize = 0 }),
    ntransforms: usize = 0,
    seen: u8 = 0,

    fn check(self: *Decoder) Error!void {
        if (self.br.eos) return error.Corrupt;
    }

    fn readCodeLengths(self: *Decoder, cl_lengths: *const [19]u8, num_symbols: usize, out: []u8) Error!void {
        const cl = try buildHuff(self.arena, cl_lengths);
        var max_symbol: usize = num_symbols;
        if (self.br.read(1) != 0) {
            const nbits: u7 = @intCast(2 + 2 * self.br.read(3));
            max_symbol = 2 + self.br.read(nbits);
            if (max_symbol > num_symbols) return error.Corrupt;
        }
        var symbol: usize = 0;
        var prev: u8 = 8;
        while (symbol < num_symbols) {
            if (max_symbol == 0) break;
            max_symbol -= 1;
            const code_len = cl.sym(&self.br);
            try self.check();
            if (code_len < 16) {
                out[symbol] = @intCast(code_len);
                symbol += 1;
                if (code_len != 0) prev = @intCast(code_len);
            } else {
                const slot = code_len - 16;
                const extra: u7 = switch (slot) {
                    0 => 2,
                    1 => 3,
                    else => 7,
                };
                const offset: u32 = if (slot == 2) 11 else 3;
                const repeat = self.br.read(extra) + offset;
                if (symbol + repeat > num_symbols) return error.Corrupt;
                const v: u8 = if (code_len == 16) prev else 0;
                @memset(out[symbol..][0..repeat], v);
                symbol += repeat;
            }
        }
    }

    fn readCode(self: *Decoder, alphabet: usize, lengths: []u8, build: bool) Error!Huff {
        const ls = lengths[0..alphabet];
        @memset(ls, 0);
        if (self.br.read(1) != 0) {
            const n = self.br.read(1) + 1;
            const first_len_code = self.br.read(1);
            var s = self.br.read(if (first_len_code == 0) 1 else 8);
            if (s >= alphabet) return error.Corrupt;
            ls[s] = 1;
            if (n == 2) {
                s = self.br.read(8);
                if (s >= alphabet) return error.Corrupt;
                ls[s] = 1;
            }
        } else {
            var cl: [19]u8 = @splat(0);
            const num = self.br.read(4) + 4;
            for (0..num) |i| cl[code_length_order[i]] = @intCast(self.br.read(3));
            try self.readCodeLengths(&cl, alphabet, ls);
        }
        try self.check();
        if (!build) {
            _ = try checkLengths(ls);
            return .{};
        }
        return buildHuff(self.arena, ls);
    }

    fn readStream(self: *Decoder, xsize: u32, ysize: u32, is_level0: bool) Error![]u32 {
        var txs = xsize;
        const tys = ysize;
        if (is_level0) {
            while (self.br.read(1) != 0) {
                try self.check();
                try self.readTransform(&txs, tys);
            }
        }
        var cache_bits: u5 = 0;
        if (self.br.read(1) != 0) {
            const b = self.br.read(4);
            if (b < 1 or b > max_cache_bits) return error.Corrupt;
            cache_bits = @intCast(b);
        }
        try self.check();
        const meta = try self.readGroups(txs, tys, cache_bits, is_level0);
        const total = @as(u64, txs) * tys;
        if (total > image.max_pixels) return error.TooLarge;
        const data = try self.arena.alloc(u32, @intCast(total));
        try self.decodeData(&meta, data, txs);
        return data;
    }

    fn readGroups(self: *Decoder, xsize: u32, ysize: u32, cache_bits: u5, allow_meta: bool) Error!Meta {
        var meta: Meta = .{ .groups = &.{}, .cache_bits = cache_bits };
        var num_groups: usize = 1;
        var used: ?[]bool = null;
        if (allow_meta and self.br.read(1) != 0) {
            const bits: u5 = @intCast(2 + self.br.read(3));
            const hx = subSample(xsize, bits);
            const hy = subSample(ysize, bits);
            const img = try self.readStream(hx, hy, false);
            meta.huff_bits = bits;
            meta.huff_xsize = hx;
            var max: u32 = 0;
            for (img) |*p| {
                p.* = (p.* >> 8) & 0xffff;
                max = @max(max, p.*);
            }
            meta.huff_image = img;
            num_groups = max + 1;
            const u = try self.arena.alloc(bool, num_groups);
            @memset(u, false);
            for (img) |p| u[p] = true;
            used = u;
        }
        try self.check();
        meta.groups = try self.arena.alloc(Group, num_groups);
        const max_alpha = num_literal + num_length + (if (cache_bits > 0) @as(usize, 1) << cache_bits else 0);
        const lengths = try self.arena.alloc(u8, max_alpha);
        for (meta.groups, 0..) |*g, gi| {
            const build = if (used) |u| u[gi] else true;
            for (0..5) |j| {
                var alpha: usize = switch (j) {
                    0 => num_literal + num_length,
                    4 => num_dist,
                    else => num_literal,
                };
                if (j == 0 and cache_bits > 0) alpha += @as(usize, 1) << cache_bits;
                g[j] = try self.readCode(alpha, lengths, build);
            }
        }
        return meta;
    }

    fn readTransform(self: *Decoder, xsize: *u32, ysize: u32) Error!void {
        const kind: u2 = @intCast(self.br.read(2));
        if (self.seen & (@as(u8, 1) << kind) != 0) return error.Corrupt;
        self.seen |= @as(u8, 1) << kind;
        var t: Transform = .{ .kind = kind, .xsize = xsize.*, .ysize = ysize };
        switch (kind) {
            0, 1 => {
                t.bits = @intCast(2 + self.br.read(3));
                t.data = try self.readStream(subSample(t.xsize, t.bits), subSample(ysize, t.bits), false);
            },
            3 => {
                const n = self.br.read(8) + 1;
                const bits: u5 = if (n > 16) 0 else if (n > 4) 1 else if (n > 2) 2 else 3;
                xsize.* = subSample(t.xsize, bits);
                t.bits = bits;
                const raw = try self.readStream(n, 1, false);
                const full = @as(usize, 1) << @intCast(@as(u4, 8) >> @intCast(bits));
                const pal = try self.arena.alloc(u32, full);
                @memset(pal, 0);
                pal[0] = raw[0];
                for (1..n) |i| pal[i] = addPixels(raw[i], pal[i - 1]);
                t.data = pal;
            },
            2 => {},
        }
        self.transforms[self.ntransforms] = t;
        self.ntransforms += 1;
    }

    fn decodeData(self: *Decoder, meta: *const Meta, data: []u32, width: u32) Error!void {
        const br = &self.br;
        const end = data.len;
        var pos: usize = 0;
        var col: u32 = 0;
        var row: u32 = 0;
        const mask: u32 = if (meta.huff_bits == 0) std.math.maxInt(u32) else (@as(u32, 1) << meta.huff_bits) - 1;
        const cache_size: u32 = if (meta.cache_bits > 0) @as(u32, 1) << meta.cache_bits else 0;
        var cache: []u32 = &.{};
        if (cache_size > 0) {
            cache = try self.arena.alloc(u32, cache_size);
            @memset(cache, 0);
        }
        const cshift: u5 = if (meta.cache_bits > 0) @intCast(32 - @as(u6, meta.cache_bits)) else 0;
        var group: *const Group = &meta.groups[0];
        while (pos < end) {
            if ((col & mask) == 0) group = groupAt(meta, col, row);
            const code = group[0].sym(br);
            if (code < num_literal) {
                const red = group[1].sym(br);
                const blue = group[2].sym(br);
                const alpha = group[3].sym(br);
                const px = (@as(u32, alpha) << 24) | (@as(u32, red) << 16) | (@as(u32, code) << 8) | blue;
                data[pos] = px;
                if (cache_size > 0) cache[(px *% 0x1e35a7bd) >> cshift] = px;
                pos += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                }
            } else if (code < num_literal + num_length) {
                const length = copyValue(code - num_literal, br);
                const dsym = group[4].sym(br);
                const dcode = copyValue(dsym, br);
                const dist = planeToDistance(width, dcode);
                if (pos < dist or end - pos < length) return error.Corrupt;
                var i: usize = 0;
                while (i < length) : (i += 1) {
                    const px = data[pos + i - dist];
                    data[pos + i] = px;
                    if (cache_size > 0) cache[(px *% 0x1e35a7bd) >> cshift] = px;
                }
                pos += length;
                col += @intCast(length);
                while (col >= width) {
                    col -= width;
                    row += 1;
                }
                if (pos < end and (col & mask) != 0) group = groupAt(meta, col, row);
            } else if (code - num_literal - num_length < cache_size) {
                const px = cache[code - num_literal - num_length];
                data[pos] = px;
                pos += 1;
                col += 1;
                if (col >= width) {
                    col = 0;
                    row += 1;
                }
            } else return error.Corrupt;
            if (br.eos) return error.Corrupt;
        }
        try self.check();
    }

    fn applyTransforms(self: *Decoder, alloc: std.mem.Allocator, data: []u32) Error![]u32 {
        var cur = data;
        var i = self.ntransforms;
        while (i > 0) {
            i -= 1;
            const t = self.transforms[i];
            switch (t.kind) {
                2 => for (cur) |*p| {
                    const g = (p.* >> 8) & 0xff;
                    const rb = ((p.* & 0x00ff00ff) +% ((g << 16) | g)) & 0x00ff00ff;
                    p.* = (p.* & 0xff00ff00) | rb;
                },
                0 => predictInverse(t, cur),
                1 => crossColorInverse(t, cur),
                3 => {
                    const out = try alloc.alloc(u32, @as(usize, t.xsize) * t.ysize);
                    colorIndexInverse(t, cur, out);
                    cur = out;
                },
            }
        }
        return cur;
    }
};

fn groupAt(meta: *const Meta, col: u32, row: u32) *const Group {
    if (meta.huff_bits == 0) return &meta.groups[0];
    const idx = meta.huff_image[meta.huff_xsize * (row >> meta.huff_bits) + (col >> meta.huff_bits)];
    return &meta.groups[idx];
}

fn copyValue(sym: u32, br: *BitReader) u32 {
    if (sym < 4) return sym + 1;
    const extra: u7 = @intCast((sym - 2) >> 1);
    const offset = (2 + (sym & 1)) << @intCast(extra);
    return offset + br.read(extra) + 1;
}

fn planeToDistance(xsize: u32, plane: u32) u32 {
    if (plane > 120) return plane - 120;
    const dc = code_to_plane[plane - 1];
    const yoff: i32 = dc >> 4;
    const xoff: i32 = 8 - @as(i32, dc & 15);
    const dist = yoff * @as(i32, @intCast(xsize)) + xoff;
    return if (dist >= 1) @intCast(dist) else 1;
}

fn addPixels(a: u32, b: u32) u32 {
    const alpha_green = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const red_blue = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (alpha_green & 0xff00ff00) | (red_blue & 0x00ff00ff);
}

fn avg2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) + (a & b);
}

fn sub3(a: i32, b: i32, c: i32) i32 {
    return @as(i32, @intCast(@abs(b - c))) - @as(i32, @intCast(@abs(a - c)));
}

fn select(a: u32, b: u32, c: u32) u32 {
    var s: i32 = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |sh| {
        s += sub3(@intCast((a >> sh) & 0xff), @intCast((b >> sh) & 0xff), @intCast((c >> sh) & 0xff));
    }
    return if (s <= 0) a else b;
}

fn clip255(v: i32) u32 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn addSubFull(l: u32, t: u32, tl: u32) u32 {
    var r: u32 = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |sh| {
        const v = @as(i32, @intCast((l >> sh) & 0xff)) + @as(i32, @intCast((t >> sh) & 0xff)) - @as(i32, @intCast((tl >> sh) & 0xff));
        r |= clip255(v) << sh;
    }
    return r;
}

fn addSubHalf(l: u32, t: u32, tl: u32) u32 {
    const ave = avg2(l, t);
    var r: u32 = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |sh| {
        const a: i32 = @intCast((ave >> sh) & 0xff);
        const b: i32 = @intCast((tl >> sh) & 0xff);
        r |= clip255(a + @divTrunc(a - b, 2)) << sh;
    }
    return r;
}

fn predict(mode: u32, l: u32, t: u32, tr: u32, tl: u32) u32 {
    return switch (mode) {
        1 => l,
        2 => t,
        3 => tr,
        4 => tl,
        5 => avg2(avg2(l, tr), t),
        6 => avg2(l, tl),
        7 => avg2(l, t),
        8 => avg2(tl, t),
        9 => avg2(t, tr),
        10 => avg2(avg2(l, tl), avg2(t, tr)),
        11 => select(t, l, tl),
        12 => addSubFull(l, t, tl),
        13 => addSubHalf(l, t, tl),
        else => 0xff000000,
    };
}

fn predictInverse(t: Transform, px: []u32) void {
    const w: usize = t.xsize;
    const h: usize = t.ysize;
    px[0] = addPixels(px[0], 0xff000000);
    for (1..w) |x| px[x] = addPixels(px[x], px[x - 1]);
    const tile: usize = @as(usize, 1) << t.bits;
    const tiles_per_row = subSample(t.xsize, t.bits);
    for (1..h) |y| {
        const base = y * w;
        px[base] = addPixels(px[base], px[base - w]);
        const modes = t.data[(y >> t.bits) * tiles_per_row ..];
        var x: usize = 1;
        while (x < w) {
            const mode = (modes[x >> t.bits] >> 8) & 0xf;
            const x_end = @min((x & ~(tile - 1)) + tile, w);
            while (x < x_end) : (x += 1) {
                const i = base + x;
                px[i] = addPixels(px[i], predict(mode, px[i - 1], px[i - w], px[i - w + 1], px[i - w - 1]));
            }
        }
    }
}

fn mulDelta(pred: u32, color: u32) i32 {
    const a: i8 = @bitCast(@as(u8, @truncate(pred)));
    const c: i8 = @bitCast(@as(u8, @truncate(color)));
    return (@as(i32, a) * @as(i32, c)) >> 5;
}

fn crossColorInverse(t: Transform, px: []u32) void {
    const w: usize = t.xsize;
    const tiles_per_row = subSample(t.xsize, t.bits);
    for (0..t.ysize) |y| {
        const row = px[y * w ..][0..w];
        const tdata = t.data[(y >> t.bits) * tiles_per_row ..];
        for (row, 0..) |*p, x| {
            const code = tdata[x >> t.bits];
            const g2r = code & 0xff;
            const g2b = (code >> 8) & 0xff;
            const r2b = (code >> 16) & 0xff;
            const green = (p.* >> 8) & 0xff;
            var red: i32 = @intCast((p.* >> 16) & 0xff);
            var blue: i32 = @intCast(p.* & 0xff);
            red += mulDelta(g2r, green);
            red &= 0xff;
            blue += mulDelta(g2b, green);
            blue += mulDelta(r2b, @intCast(red));
            blue &= 0xff;
            p.* = (p.* & 0xff00ff00) | (@as(u32, @intCast(red)) << 16) | @as(u32, @intCast(blue));
        }
    }
}

fn colorIndexInverse(t: Transform, src: []const u32, dst: []u32) void {
    const w: usize = t.xsize;
    const bpp: u5 = @intCast(@as(u4, 8) >> @intCast(t.bits));
    if (bpp == 8) {
        for (dst, src) |*d, s| d.* = t.data[(s >> 8) & 0xff];
        return;
    }
    const per: usize = @as(usize, 1) << t.bits;
    const bmask: u32 = (@as(u32, 1) << bpp) - 1;
    const sw = subSample(t.xsize, t.bits);
    for (0..t.ysize) |y| {
        const srow = src[y * sw ..][0..sw];
        const drow = dst[y * w ..][0..w];
        var packed_px: u32 = 0;
        for (drow, 0..) |*d, x| {
            if (x % per == 0) packed_px = (srow[x / per] >> 8) & 0xff;
            d.* = t.data[packed_px & bmask];
            packed_px >>= bpp;
        }
    }
}

pub const Decoded = struct { width: u32, height: u32, has_alpha: bool, argb: []u32 };

pub fn decode(arena: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (data.len < 5 or data[0] != 0x2f) return error.Corrupt;
    var d: Decoder = .{ .br = .{ .data = data[1..] }, .arena = arena };
    const w = d.br.read(14) + 1;
    const h = d.br.read(14) + 1;
    const alpha = d.br.read(1);
    if (d.br.read(3) != 0) return error.Corrupt;
    try d.check();
    try image.checkDims(w, h);
    const px = try d.readStream(w, h, true);
    const out = try d.applyTransforms(arena, px);
    return .{ .width = w, .height = h, .has_alpha = alpha != 0, .argb = out };
}

pub fn decodeAlpha(arena: std.mem.Allocator, data: []const u8, w: u32, h: u32, out: []u8) Error!void {
    var d: Decoder = .{ .br = .{ .data = data }, .arena = arena };
    const px = try d.readStream(w, h, true);
    const res = try d.applyTransforms(arena, px);
    for (res, out) |p, *o| o.* = @truncate(p >> 8);
}
