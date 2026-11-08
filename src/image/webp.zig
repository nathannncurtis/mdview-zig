const std = @import("std");
const image = @import("image.zig");
const vp8 = @import("vp8.zig");
const vp8l = @import("vp8l.zig");
const icc = @import("icc.zig");
const Error = image.Error;
const Image = image.Image;

const Chunk = struct { tag: [4]u8, data: []const u8 };

fn u24le(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

const ChunkIter = struct {
    c: image.Cursor,

    fn next(self: *ChunkIter) Error!?Chunk {
        if (self.c.left() == 0) return null;
        const tag = (try self.c.take(4))[0..4].*;
        const size = try self.c.le32();
        const data = try self.c.take(size);
        if (size & 1 != 0 and self.c.left() > 0) _ = try self.c.take(1);
        return .{ .tag = tag, .data = data };
    }
};

const Decoded = struct { width: u32, height: u32, has_alpha: bool, rgba: []u8 };

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    const riff_size = std.mem.readInt(u32, bytes[4..8], .little);
    if (riff_size < 4) return error.Corrupt;
    if (@as(u64, riff_size) + 8 > bytes.len) return blankFromHeader(alloc, bytes);
    var it: ChunkIter = .{ .c = .{ .b = bytes[12 .. 8 + riff_size] } };
    const first = (try it.next()) orelse return error.Corrupt;
    if (std.mem.eql(u8, &first.tag, "VP8 ") or std.mem.eql(u8, &first.tag, "VP8L")) {
        const d = try decodeData(alloc, null, first);
        return image.single(alloc, d.width, d.height, d.rgba);
    }
    if (!std.mem.eql(u8, &first.tag, "VP8X") or first.data.len < 10) return error.Corrupt;
    const flags = first.data[0];
    const cw = u24le(first.data[4..7]) + 1;
    const ch = u24le(first.data[7..10]) + 1;
    try image.checkDims(cw, ch);
    var iccp: ?[]const u8 = null;
    var peek = it;
    while (try peek.next()) |c| {
        if (std.mem.eql(u8, &c.tag, "ICCP")) iccp = c.data;
    }
    if (flags & 0x02 != 0) {
        var img = try decodeAnim(alloc, &it, cw, ch);
        colorize(&img, iccp);
        return img;
    }

    var alph: ?[]const u8 = null;
    while (try it.next()) |c| {
        if (std.mem.eql(u8, &c.tag, "ALPH")) {
            if (alph == null) alph = c.data;
        } else if (std.mem.eql(u8, &c.tag, "VP8 ") or std.mem.eql(u8, &c.tag, "VP8L")) {
            const d = try decodeData(alloc, alph, c);
            errdefer alloc.free(d.rgba);
            if (d.width != cw or d.height != ch) return error.Corrupt;
            var img = try image.single(alloc, d.width, d.height, d.rgba);
            colorize(&img, iccp);
            return img;
        }
    }
    return error.Corrupt;
}

fn blankFromHeader(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    var c: image.Cursor = .{ .b = bytes, .pos = 12 };
    const tag = (try c.take(4))[0..4].*;
    _ = try c.le32();
    var w: u32 = 0;
    var h: u32 = 0;
    if (std.mem.eql(u8, &tag, "VP8X")) {
        const d = try c.take(10);
        w = u24le(d[4..7]) + 1;
        h = u24le(d[7..10]) + 1;
    } else if (std.mem.eql(u8, &tag, "VP8 ")) {
        const d = try c.take(10);
        if (d[3] != 0x9d or d[4] != 0x01 or d[5] != 0x2a) return error.Corrupt;
        w = (@as(u32, d[6]) | (@as(u32, d[7]) << 8)) & 0x3fff;
        h = (@as(u32, d[8]) | (@as(u32, d[9]) << 8)) & 0x3fff;
    } else if (std.mem.eql(u8, &tag, "VP8L")) {
        const d = try c.take(5);
        if (d[0] != 0x2f) return error.Corrupt;
        const bits = std.mem.readInt(u32, d[1..5], .little);
        w = (bits & 0x3fff) + 1;
        h = ((bits >> 14) & 0x3fff) + 1;
    } else return error.Corrupt;
    try image.checkDims(w, h);
    const out = try image.allocRgba(alloc, w, h);
    @memset(out, 0);
    return image.single(alloc, w, h, out);
}

fn colorize(img: *Image, profile: ?[]const u8) void {
    const p = profile orelse return;
    var tr: icc.Transform = .{};
    if (icc.fromProfile(&tr, p, .rgb)) |t| for (img.frames) |f| t.apply(f.rgba);
}

fn decodeAnim(alloc: std.mem.Allocator, it: *ChunkIter, cw: u32, ch: u32) Error!Image {
    var list = image.FrameList.init(alloc);
    defer list.deinit();
    const canvas = try image.allocRgba(alloc, cw, ch);
    defer alloc.free(canvas);
    const disposed = try alloc.alloc(u8, canvas.len);
    defer alloc.free(disposed);
    @memset(canvas, 0);
    @memset(disposed, 0);
    var loops: u32 = 0;
    var n: usize = 0;
    var prev: ?struct { x: u32, y: u32, w: u32, h: u32, dispose_bg: bool, key: bool } = null;
    while (try it.next()) |c| {
        if (std.mem.eql(u8, &c.tag, "ANIM")) {
            if (c.data.len >= 6) loops = std.mem.readInt(u16, c.data[4..6], .little);
            continue;
        }
        if (!std.mem.eql(u8, &c.tag, "ANMF")) continue;
        if (c.data.len < 16) return error.Corrupt;
        const fx = u24le(c.data[0..3]) * 2;
        const fy = u24le(c.data[3..6]) * 2;
        const fw = u24le(c.data[6..9]) + 1;
        const fh = u24le(c.data[9..12]) + 1;
        const dur = u24le(c.data[12..15]);
        const fl = c.data[15];
        if (@as(u64, fx) + fw > cw or @as(u64, fy) + fh > ch) return error.Corrupt;
        var sub: ChunkIter = .{ .c = .{ .b = c.data[16..] } };
        var alph: ?[]const u8 = null;
        var frame: ?Decoded = null;
        defer if (frame) |f| alloc.free(f.rgba);
        while (try sub.next()) |sc| {
            if (std.mem.eql(u8, &sc.tag, "ALPH")) {
                if (alph == null) alph = sc.data;
            } else if (std.mem.eql(u8, &sc.tag, "VP8 ") or std.mem.eql(u8, &sc.tag, "VP8L")) {
                frame = try decodeData(alloc, alph, sc);
                break;
            }
        }
        const f = frame orelse return error.Corrupt;
        if (f.width != fw or f.height != fh) return error.Corrupt;
        const blend = fl & 2 == 0;
        const dispose_bg = fl & 1 != 0;
        n += 1;
        const full = fw == cw and fh == ch;
        const key = if (n == 1) true else if ((!f.has_alpha or !blend) and full) true else if (prev.?.dispose_bg) ((prev.?.w == cw and prev.?.h == ch) or prev.?.key) else false;
        if (key) @memset(canvas, 0) else @memcpy(canvas, disposed);
        for (0..fh) |y| {
            const d = canvas[((fy + y) * cw + fx) * 4 ..][0 .. fw * 4];
            @memcpy(d, f.rgba[y * fw * 4 ..][0 .. fw * 4]);
        }
        if (n > 1 and blend and !key) {
            for (0..fh) |y| {
                const row = canvas[((fy + y) * cw + fx) * 4 ..][0 .. fw * 4];
                const under = disposed[((fy + y) * cw + fx) * 4 ..][0 .. fw * 4];
                for (0..fw) |x| {
                    if (prev.?.dispose_bg) {
                        const p = prev.?;
                        const cy = fy + y;
                        const cx = fx + x;
                        if (cy >= p.y and cy < p.y + p.h and cx >= p.x and cx < p.x + p.w) continue;
                    }
                    blendPixel(row[x * 4 ..][0..4], under[x * 4 ..][0..4]);
                }
            }
        }
        const copy = try alloc.dupe(u8, canvas);
        errdefer alloc.free(copy);
        try list.add(cw, ch, copy, dur);
        @memcpy(disposed, canvas);
        if (dispose_bg) {
            for (0..fh) |y| @memset(disposed[((fy + y) * cw + fx) * 4 ..][0 .. fw * 4], 0);
        }
        prev = .{ .x = fx, .y = fy, .w = fw, .h = fh, .dispose_bg = dispose_bg, .key = key };
    }
    if (list.list.items.len == 0) return error.Corrupt;
    return list.finish(cw, ch, loops);
}

fn blendPixel(src: *[4]u8, dst: *const [4]u8) void {
    const sa: u32 = src[3];
    if (sa == 255) return;
    if (sa == 0) {
        src.* = dst.*;
        return;
    }
    const da: u32 = dst[3];
    const dfa: u32 = (da * (256 - sa)) >> 8;
    const ba = sa + dfa;
    const scale: u32 = (@as(u32, 1) << 24) / ba;
    for (0..3) |i| {
        const unscaled = @as(u32, src[i]) * sa + @as(u32, dst[i]) * dfa;
        src[i] = @truncate((unscaled *% scale) >> 24);
    }
    src[3] = @intCast(ba);
}

fn decodeData(alloc: std.mem.Allocator, alph: ?[]const u8, c: Chunk) Error!Decoded {
    if (std.mem.eql(u8, &c.tag, "VP8L")) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const d = try vp8l.decode(arena.allocator(), c.data);
        const out = try image.allocRgba(alloc, d.width, d.height);
        for (d.argb, 0..) |p, i| {
            out[i * 4 ..][0..4].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), if (d.has_alpha) @truncate(p >> 24) else 255 };
        }
        return .{ .width = d.width, .height = d.height, .has_alpha = d.has_alpha, .rgba = out };
    }
    const yuv = try vp8.decode(alloc, c.data);
    defer alloc.free(yuv.mem);
    const out = try image.allocRgba(alloc, yuv.width, yuv.height);
    errdefer alloc.free(out);
    var alpha_plane: ?[]u8 = null;
    defer if (alpha_plane) |a| alloc.free(a);
    if (alph) |a| {
        alpha_plane = try decodeAlpha(alloc, a, yuv.width, yuv.height);
    }
    toRgba(yuv, alpha_plane, out);
    return .{ .width = yuv.width, .height = yuv.height, .has_alpha = alpha_plane != null, .rgba = out };
}

fn decodeAlpha(alloc: std.mem.Allocator, a: []const u8, w: u32, h: u32) Error![]u8 {
    if (a.len < 2) return error.Corrupt;
    const method = a[0] & 3;
    const filter = (a[0] >> 2) & 3;
    const pre = (a[0] >> 4) & 3;
    if (method > 1 or pre > 1 or (a[0] >> 6) != 0) return error.Corrupt;
    const n = @as(usize, w) * h;
    const plane = try alloc.alloc(u8, n);
    errdefer alloc.free(plane);
    if (method == 0) {
        if (a.len - 1 < n) return error.Corrupt;
        @memcpy(plane, a[1..][0..n]);
    } else {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        try vp8l.decodeAlpha(arena.allocator(), a[1..], w, h, plane);
    }
    unfilter(plane, w, h, filter);
    return plane;
}

fn gradPred(a: u8, b: u8, c: u8) u8 {
    return @intCast(std.math.clamp(@as(i32, a) + b - c, 0, 255));
}

fn unfilter(p: []u8, w: usize, h: usize, filter: u8) void {
    if (filter == 0) return;
    for (0..h) |y| {
        const row = p[y * w ..][0..w];
        if (y == 0) {
            for (1..w) |x| row[x] +%= row[x - 1];
            continue;
        }
        const prev = p[(y - 1) * w ..][0..w];
        switch (filter) {
            1 => {
                row[0] +%= prev[0];
                for (1..w) |x| row[x] +%= row[x - 1];
            },
            2 => for (0..w) |x| {
                row[x] +%= prev[x];
            },
            else => {
                row[0] +%= prev[0];
                for (1..w) |x| row[x] +%= gradPred(row[x - 1], prev[x], prev[x - 1]);
            },
        }
    }
}

fn mulHi(v: i32, coeff: i32) i32 {
    return (v * coeff) >> 8;
}

fn clip8(v: i32) u8 {
    if (v & ~@as(i32, (256 << 6) - 1) == 0) return @intCast(v >> 6);
    return if (v < 0) 0 else 255;
}

fn putRgb(y: u8, u: i32, v: i32, dst: []u8) void {
    const yy: i32 = y;
    dst[0] = clip8(mulHi(yy, 19077) + mulHi(v, 26149) - 14234);
    dst[1] = clip8(mulHi(yy, 19077) - mulHi(u, 6419) - mulHi(v, 13320) + 8708);
    dst[2] = clip8(mulHi(yy, 19077) + mulHi(u, 33050) - 17685);
    dst[3] = 255;
}

fn upsamplePair(top_y: []const u8, bot_y: ?[]const u8, top_u: []const u8, top_v: []const u8, cur_u: []const u8, cur_v: []const u8, top_dst: []u8, bot_dst: ?[]u8, len: usize) void {
    const last_pair = (len - 1) >> 1;
    var tl_u: i32 = top_u[0];
    var tl_v: i32 = top_v[0];
    var l_u: i32 = cur_u[0];
    var l_v: i32 = cur_v[0];
    putRgb(top_y[0], (3 * tl_u + l_u + 2) >> 2, (3 * tl_v + l_v + 2) >> 2, top_dst[0..4]);
    if (bot_y) |by| putRgb(by[0], (3 * l_u + tl_u + 2) >> 2, (3 * l_v + tl_v + 2) >> 2, bot_dst.?[0..4]);
    var x: usize = 1;
    while (x <= last_pair) : (x += 1) {
        const t_u: i32 = top_u[x];
        const t_v: i32 = top_v[x];
        const c_u: i32 = cur_u[x];
        const c_v: i32 = cur_v[x];
        const avg_u = tl_u + t_u + l_u + c_u + 8;
        const avg_v = tl_v + t_v + l_v + c_v + 8;
        const d12_u = (avg_u + 2 * (t_u + l_u)) >> 3;
        const d12_v = (avg_v + 2 * (t_v + l_v)) >> 3;
        const d03_u = (avg_u + 2 * (tl_u + c_u)) >> 3;
        const d03_v = (avg_v + 2 * (tl_v + c_v)) >> 3;
        putRgb(top_y[2 * x - 1], (d12_u + tl_u) >> 1, (d12_v + tl_v) >> 1, top_dst[(2 * x - 1) * 4 ..][0..4]);
        putRgb(top_y[2 * x], (d03_u + t_u) >> 1, (d03_v + t_v) >> 1, top_dst[2 * x * 4 ..][0..4]);
        if (bot_y) |by| {
            const bd = bot_dst.?;
            putRgb(by[2 * x - 1], (d03_u + l_u) >> 1, (d03_v + l_v) >> 1, bd[(2 * x - 1) * 4 ..][0..4]);
            putRgb(by[2 * x], (d12_u + c_u) >> 1, (d12_v + c_v) >> 1, bd[2 * x * 4 ..][0..4]);
        }
        tl_u = t_u;
        tl_v = t_v;
        l_u = c_u;
        l_v = c_v;
    }
    if (len & 1 == 0) {
        putRgb(top_y[len - 1], (3 * tl_u + l_u + 2) >> 2, (3 * tl_v + l_v + 2) >> 2, top_dst[(len - 1) * 4 ..][0..4]);
        if (bot_y) |by| putRgb(by[len - 1], (3 * l_u + tl_u + 2) >> 2, (3 * l_v + tl_v + 2) >> 2, bot_dst.?[(len - 1) * 4 ..][0..4]);
    }
}

fn toRgba(yuv: vp8.Yuv, alpha: ?[]const u8, out: []u8) void {
    const w: usize = yuv.width;
    const h: usize = yuv.height;
    const ys = yuv.ystride;
    const us = yuv.uvstride;
    const rs = w * 4;
    upsamplePair(yuv.y[0..w], null, yuv.u[0..], yuv.v[0..], yuv.u[0..], yuv.v[0..], out[0..rs], null, w);
    var k: usize = 1;
    while (2 * k < h) : (k += 1) {
        const r1 = 2 * k - 1;
        const r2 = 2 * k;
        upsamplePair(yuv.y[r1 * ys ..][0..w], yuv.y[r2 * ys ..][0..w], yuv.u[(k - 1) * us ..], yuv.v[(k - 1) * us ..], yuv.u[k * us ..], yuv.v[k * us ..], out[r1 * rs ..][0..rs], out[r2 * rs ..][0..rs], w);
    }
    if (h > 1 and h % 2 == 0) {
        const r = h - 1;
        const uvr = h / 2 - 1;
        upsamplePair(yuv.y[r * ys ..][0..w], null, yuv.u[uvr * us ..], yuv.v[uvr * us ..], yuv.u[uvr * us ..], yuv.v[uvr * us ..], out[r * rs ..][0..rs], null, w);
    }
    if (alpha) |a| {
        for (0..h) |y| for (0..w) |x| {
            out[y * rs + x * 4 + 3] = a[y * w + x];
        };
    }
}
