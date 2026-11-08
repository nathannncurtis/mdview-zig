const std = @import("std");
const image = @import("image.zig");
const Error = image.Error;
const Image = image.Image;
const icc = @import("icc.zig");

const Masks = struct {
    mask: [4]u32 = .{ 0, 0, 0, 0 },
    shift: [4]u5 = .{ 0, 0, 0, 0 },
    bits: [4]u6 = .{ 0, 0, 0, 0 },

    fn init(m: [4]u32) Masks {
        var r: Masks = .{ .mask = m };
        for (m, 0..) |v, i| {
            if (v == 0) continue;
            r.shift[i] = @intCast(@ctz(v));
            r.bits[i] = @intCast(32 - @clz(v >> r.shift[i]));
        }
        return r;
    }

    fn get(self: Masks, v: u32, i: usize) u8 {
        if (self.mask[i] == 0) return 255;
        const x = (v & self.mask[i]) >> self.shift[i];
        const b = self.bits[i];
        if (b >= 8) return @intCast(x >> @intCast(b - 8));
        const max = (@as(u32, 1) << @intCast(b)) - 1;
        return @intCast(x * 255 / max);
    }
};

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    var c: image.Cursor = .{ .b = bytes };
    _ = try c.take(2);
    _ = try c.le32();
    _ = try c.le32();
    const data_off = try c.le32();
    const hdr_size = try c.le32();
    var width: i64 = 0;
    var height: i64 = 0;
    var bpp: u32 = 0;
    var compression: u32 = 0;
    var colors_used: u32 = 0;
    var pal_entry: usize = 4;
    if (hdr_size == 12) {
        width = try c.le16();
        height = try c.le16();
        _ = try c.le16();
        bpp = try c.le16();
        pal_entry = 3;
    } else if (hdr_size >= 40 and hdr_size <= 124) {
        width = @as(i32, @bitCast(try c.le32()));
        height = @as(i32, @bitCast(try c.le32()));
        _ = try c.le16();
        bpp = try c.le16();
        compression = try c.le32();
        _ = try c.le32();
        _ = try c.le32();
        _ = try c.le32();
        colors_used = try c.le32();
        _ = try c.le32();
    } else return error.UnsupportedFormat;
    const top_down = height < 0;
    if (top_down) height = -height;
    if (width <= 0 or height <= 0) return error.Corrupt;
    try image.checkDims(@intCast(width), @intCast(height));
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (compression == 4 or compression == 5) {
        if (data_off > bytes.len) return error.Corrupt;
        const inner = bytes[data_off..];
        if (compression == 4) {
            if (inner.len < 3 or inner[0] != 0xFF or inner[1] != 0xD8 or inner[2] != 0xFF) return error.Corrupt;
            return @import("jpeg.zig").decode(alloc, inner);
        }
        if (inner.len < 8 or !std.mem.eql(u8, inner[0..8], "\x89PNG\r\n\x1a\n")) return error.Corrupt;
        return @import("png.zig").decode(alloc, inner);
    }
    if (compression > 3 and compression != 6) return error.Corrupt;
    const rle = compression == 1 or compression == 2;
    if (compression == 1 and bpp != 8) return error.Corrupt;
    if (compression == 2 and bpp != 4) return error.Corrupt;
    if (bpp != 1 and bpp != 4 and bpp != 8 and bpp != 16 and bpp != 24 and bpp != 32) return error.Corrupt;

    var masks: Masks = .{};
    if (bpp == 16 or bpp == 32) {
        if (compression == 3 or compression == 6) {
            var mc: image.Cursor = .{ .b = bytes, .pos = 14 + 40 };
            var m: [4]u32 = .{ 0, 0, 0, 0 };
            const n: usize = if (compression == 6 or hdr_size >= 56) 4 else 3;
            for (0..n) |i| m[i] = try mc.le32();
            masks = Masks.init(m);
        } else if (bpp == 16) {
            masks = Masks.init(.{ 0x7C00, 0x03E0, 0x001F, 0 });
        } else {
            masks = Masks.init(.{ 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000 });
        }
    } else if (compression == 3) return error.Corrupt;

    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    if (bpp <= 8) {
        const max_colors: u32 = @as(u32, 1) << @intCast(bpp);
        const n = if (colors_used == 0 or colors_used > max_colors) max_colors else colors_used;
        var pc: image.Cursor = .{ .b = bytes, .pos = 14 + hdr_size };
        for (0..n) |i| {
            const e = try pc.take(pal_entry);
            palette[i] = .{ e[2], e[1], e[0], 255 };
        }
    }

    if (data_off > bytes.len) return error.Corrupt;
    const data = bytes[data_off..];
    const out = try image.allocRgba(alloc, @intCast(w), @intCast(h));
    errdefer alloc.free(out);
    @memset(out, 0);

    if (rle) {
        try decodeRle(data, out, w, h, top_down, bpp, &palette);
    } else {
        const row_bytes = (w * bpp + 31) / 32 * 4;
        const rows = @min(data.len / row_bytes, h);
        if (rows == 0) return error.Corrupt;
        var any_alpha = false;
        for (0..rows) |ry| {
            const row = data[ry * row_bytes ..][0..row_bytes];
            const y = if (top_down) ry else h - 1 - ry;
            const dst = out[y * w * 4 ..][0 .. w * 4];
            switch (bpp) {
                1, 4, 8 => {
                    const per: usize = 8 / bpp;
                    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bpp)) - 1);
                    for (0..w) |x| {
                        const b = row[x / per];
                        const sh: u3 = @intCast((per - 1 - x % per) * bpp);
                        dst[x * 4 ..][0..4].* = palette[(b >> sh) & mask];
                    }
                },
                16 => for (0..w) |x| {
                    const v: u32 = std.mem.readInt(u16, row[x * 2 ..][0..2], .little);
                    dst[x * 4 ..][0..4].* = .{ masks.get(v, 0), masks.get(v, 1), masks.get(v, 2), masks.get(v, 3) };
                    if (dst[x * 4 + 3] != 0) any_alpha = true;
                },
                24 => for (0..w) |x| {
                    dst[x * 4 ..][0..4].* = .{ row[x * 3 + 2], row[x * 3 + 1], row[x * 3], 255 };
                },
                32 => for (0..w) |x| {
                    const v = std.mem.readInt(u32, row[x * 4 ..][0..4], .little);
                    dst[x * 4 ..][0..4].* = .{ masks.get(v, 0), masks.get(v, 1), masks.get(v, 2), masks.get(v, 3) };
                    if (dst[x * 4 + 3] != 0) any_alpha = true;
                },
                else => unreachable,
            }
        }
        if ((bpp == 32 or bpp == 16) and masks.mask[3] != 0 and !any_alpha) {
            for (0..rows) |ry| {
                const y = if (top_down) ry else h - 1 - ry;
                var i: usize = y * w * 4 + 3;
                while (i < (y + 1) * w * 4) : (i += 4) out[i] = 255;
            }
        }
    }
    if (hdr_size == 124 and bytes.len >= 14 + 124 and std.mem.readInt(u32, bytes[14 + 56 ..][0..4], .little) == 0x4D424544) {
        const off: u64 = std.mem.readInt(u32, bytes[14 + 112 ..][0..4], .little);
        const size: u64 = std.mem.readInt(u32, bytes[14 + 116 ..][0..4], .little);
        if (14 + off + size <= bytes.len) {
            var tr: icc.Transform = .{};
            if (icc.fromProfile(&tr, bytes[@intCast(14 + off)..][0..@intCast(size)], .rgb)) |t| t.apply(out);
        }
    }
    return image.single(alloc, @intCast(w), @intCast(h), out);
}

fn put(o: []u8, w: usize, h: usize, top_down: bool, px: usize, row: usize, p: [4]u8) void {
    if (px >= w or row >= h) return;
    const y = if (top_down) row else h - 1 - row;
    o[(y * w + px) * 4 ..][0..4].* = p;
}

fn partial(ry: usize, x: usize) Error!void {
    if (ry == 0 and x == 0) return error.Corrupt;
}

fn decodeRle(data: []const u8, out: []u8, w: usize, h: usize, top_down: bool, bpp: u32, palette: *const [256][4]u8) Error!void {
    var x: usize = 0;
    var ry: usize = 0;
    var i: usize = 0;
    while (ry < h) {
        if (i + 2 > data.len) return partial(ry, x);
        const n = data[i];
        const v = data[i + 1];
        i += 2;
        if (n != 0) {
            for (0..n) |k| {
                const idx = if (bpp == 8) v else if (k % 2 == 0) v >> 4 else v & 15;
                put(out, w, h, top_down, x, ry, palette[idx]);
                x += 1;
            }
            continue;
        }
        switch (v) {
            0 => {
                x = 0;
                ry += 1;
            },
            1 => return,
            2 => {
                if (i + 2 > data.len) return partial(ry, x);
                x += data[i];
                ry += data[i + 1];
                i += 2;
            },
            else => {
                const cnt: usize = v;
                const nbytes = if (bpp == 8) cnt else (cnt + 1) / 2;
                if (i + nbytes > data.len) return partial(ry, x);
                for (0..cnt) |k| {
                    const idx = if (bpp == 8) data[i + k] else if (k % 2 == 0) data[i + k / 2] >> 4 else data[i + k / 2] & 15;
                    put(out, w, h, top_down, x, ry, palette[idx]);
                    x += 1;
                }
                i += nbytes + (nbytes & 1);
            },
        }
    }
}
