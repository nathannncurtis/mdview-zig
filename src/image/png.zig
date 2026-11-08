const std = @import("std");
const image = @import("image.zig");
const Error = image.Error;
const Image = image.Image;
const flate = std.compress.flate;

const Header = struct {
    w: u32,
    h: u32,
    depth: u8,
    ctype: u8,
    interlace: bool,

    fn channels(self: Header) usize {
        return switch (self.ctype) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            else => 4,
        };
    }

    fn bitsPerPixel(self: Header) usize {
        return self.channels() * self.depth;
    }
};

const FrameCtl = struct {
    w: u32,
    h: u32,
    x: u32,
    y: u32,
    delay_num: u16,
    delay_den: u16,
    dispose: u8,
    blend: u8,
    data: std.ArrayList(u8) = .empty,
};

const Palette = struct {
    rgb: [256][3]u8 = @splat(.{ 0, 0, 0 }),
    alpha: [256]u8 = @splat(255),
    len: usize = 0,
    key: ?[3]u16 = null,
};

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    var c: image.Cursor = .{ .b = bytes, .pos = 8 };
    var hdr: ?Header = null;
    var pal: Palette = .{};
    var animated = false;
    var num_plays: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);
    var frames: std.ArrayList(FrameCtl) = .empty;
    defer {
        for (frames.items) |*f| f.data.deinit(alloc);
        frames.deinit(alloc);
    }
    var seen_idat = false;
    var idat_in_anim = false;
    var cur: ?usize = null;

    while (c.left() >= 8) {
        const len = try c.be32();
        const kind = try c.take(4);
        if (len > c.left()) return error.Corrupt;
        const body = try c.take(len);
        if (c.left() >= 4) c.pos += 4 else if (!std.mem.eql(u8, kind, "IEND")) return error.Corrupt;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (hdr != null or len != 13) return error.Corrupt;
            var b: image.Cursor = .{ .b = body };
            const w = try b.be32();
            const h = try b.be32();
            const depth = try b.byte();
            const ctype = try b.byte();
            const comp = try b.byte();
            const filt = try b.byte();
            const il = try b.byte();
            if (comp != 0 or filt != 0 or il > 1) return error.Corrupt;
            const ok = switch (ctype) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                2, 4, 6 => depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                else => false,
            };
            if (!ok) return error.Corrupt;
            try image.checkDims(w, h);
            hdr = .{ .w = w, .h = h, .depth = depth, .ctype = ctype, .interlace = il == 1 };
        } else {
            const hd = hdr orelse return error.Corrupt;
            if (std.mem.eql(u8, kind, "PLTE")) {
                if (len % 3 != 0 or len == 0 or len / 3 > 256) return error.Corrupt;
                pal.len = len / 3;
                for (0..pal.len) |i| pal.rgb[i] = body[i * 3 ..][0..3].*;
            } else if (std.mem.eql(u8, kind, "tRNS")) {
                switch (hd.ctype) {
                    3 => {
                        if (len > 256) return error.Corrupt;
                        @memcpy(pal.alpha[0..len], body);
                    },
                    0 => {
                        if (len != 2) return error.Corrupt;
                        const v = std.mem.readInt(u16, body[0..2], .big);
                        pal.key = .{ v, 0, 0 };
                    },
                    2 => {
                        if (len != 6) return error.Corrupt;
                        pal.key = .{ std.mem.readInt(u16, body[0..2], .big), std.mem.readInt(u16, body[2..4], .big), std.mem.readInt(u16, body[4..6], .big) };
                    },
                    else => {},
                }
            } else if (std.mem.eql(u8, kind, "acTL")) {
                if (len != 8 or seen_idat) return error.Corrupt;
                animated = true;
                num_plays = std.mem.readInt(u32, body[4..8], .big);
            } else if (std.mem.eql(u8, kind, "fcTL")) {
                if (!animated or len != 26) return error.Corrupt;
                var b: image.Cursor = .{ .b = body };
                _ = try b.be32();
                const fc: FrameCtl = .{
                    .w = try b.be32(),
                    .h = try b.be32(),
                    .x = try b.be32(),
                    .y = try b.be32(),
                    .delay_num = try b.be16(),
                    .delay_den = try b.be16(),
                    .dispose = try b.byte(),
                    .blend = try b.byte(),
                };
                if (fc.w == 0 or fc.h == 0 or fc.dispose > 2 or fc.blend > 1) return error.Corrupt;
                if (@as(u64, fc.x) + fc.w > hd.w or @as(u64, fc.y) + fc.h > hd.h) return error.Corrupt;
                try frames.append(alloc, fc);
                cur = frames.items.len - 1;
                if (!seen_idat) idat_in_anim = true;
            } else if (std.mem.eql(u8, kind, "IDAT")) {
                seen_idat = true;
                if (idat_in_anim and cur != null and frames.items.len == 1) {
                    try frames.items[0].data.appendSlice(alloc, body);
                } else {
                    try idat.appendSlice(alloc, body);
                }
            } else if (std.mem.eql(u8, kind, "fdAT")) {
                if (len < 4 or cur == null) return error.Corrupt;
                try frames.items[cur.?].data.appendSlice(alloc, body[4..]);
            } else if (std.mem.eql(u8, kind, "IEND")) {
                break;
            }
        }
    }
    const hd = hdr orelse return error.Corrupt;
    if (pal.len == 0 and hd.ctype == 3) return error.Corrupt;
    if (!seen_idat) return error.Corrupt;

    if (!animated or frames.items.len == 0 or (frames.items.len == 1 and !idat_in_anim)) {
        const data = idat.items;
        const out = try image.allocRgba(alloc, hd.w, hd.h);
        errdefer alloc.free(out);
        try inflateImage(alloc, data, hd, hd.w, hd.h, &pal, out);
        return image.single(alloc, hd.w, hd.h, out);
    }

    var list = image.FrameList.init(alloc);
    defer list.deinit();
    const canvas = try image.allocRgba(alloc, hd.w, hd.h);
    defer alloc.free(canvas);
    @memset(canvas, 0);
    var saved: ?[]u8 = null;
    defer if (saved) |s| alloc.free(s);
    var prev: ?FrameCtl = null;
    for (frames.items) |fc| {
        if (prev) |p| switch (p.dispose) {
            1 => clearRect(canvas, hd.w, p),
            2 => if (saved) |s| @memcpy(canvas, s),
            else => {},
        };
        var dispose = fc.dispose;
        if (prev == null and dispose == 2) dispose = 1;
        if (dispose == 2) {
            if (saved == null) saved = try alloc.alloc(u8, canvas.len);
            @memcpy(saved.?, canvas);
        }
        const tmp = try alloc.alloc(u8, @as(usize, fc.w) * fc.h * 4);
        defer alloc.free(tmp);
        try inflateImage(alloc, fc.data.items, hd, fc.w, fc.h, &pal, tmp);
        for (0..fc.h) |y| {
            const d = canvas[((fc.y + y) * hd.w + fc.x) * 4 ..][0 .. fc.w * 4];
            const s = tmp[y * fc.w * 4 ..][0 .. fc.w * 4];
            if (fc.blend == 0) {
                @memcpy(d, s);
            } else {
                var x: usize = 0;
                while (x < fc.w) : (x += 1) blend(d[x * 4 ..][0..4], s[x * 4 ..][0..4]);
            }
        }
        const copy = try alloc.dupe(u8, canvas);
        errdefer alloc.free(copy);
        const den: u32 = if (fc.delay_den == 0) 100 else fc.delay_den;
        try list.add(hd.w, hd.h, copy, @as(u32, fc.delay_num) * 1000 / den);
        var f2 = fc;
        f2.dispose = dispose;
        f2.data = .empty;
        prev = f2;
    }
    return list.finish(hd.w, hd.h, num_plays);
}

fn clearRect(canvas: []u8, cw: u32, f: FrameCtl) void {
    for (0..f.h) |y| {
        const d = canvas[((f.y + y) * cw + f.x) * 4 ..][0 .. f.w * 4];
        @memset(d, 0);
    }
}

fn blend(d: *[4]u8, s: *const [4]u8) void {
    const sa: u32 = s[3];
    if (sa == 255) {
        d.* = s.*;
        return;
    }
    if (sa == 0) return;
    const da: u32 = d[3];
    const dw = da * (255 - sa) / 255;
    const oa = sa + dw;
    for (0..3) |i| d[i] = @intCast((@as(u32, s[i]) * sa + @as(u32, d[i]) * dw + oa / 2) / oa);
    d[3] = @intCast(oa);
}

fn unfilter(ft: u8, row: []u8, prev: []const u8, bpp: usize) Error!void {
    switch (ft) {
        0 => {},
        1 => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => for (0..row.len) |i| {
            row[i] +%= prev[i];
        },
        3 => for (0..row.len) |i| {
            const a: u32 = if (i >= bpp) row[i - bpp] else 0;
            row[i] +%= @intCast((a + prev[i]) / 2);
        },
        4 => for (0..row.len) |i| {
            const a: i32 = if (i >= bpp) row[i - bpp] else 0;
            const b: i32 = prev[i];
            const cc: i32 = if (i >= bpp) prev[i - bpp] else 0;
            const p = a + b - cc;
            const pa = @abs(p - a);
            const pb = @abs(p - b);
            const pc = @abs(p - cc);
            const pred: u8 = if (pa <= pb and pa <= pc) @intCast(a) else if (pb <= pc) @intCast(b) else @intCast(cc);
            row[i] +%= pred;
        },
        else => return error.Corrupt,
    }
}

const adam7 = [7][4]u8{
    .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
};

fn inflateImage(alloc: std.mem.Allocator, data: []const u8, hd: Header, w: u32, h: u32, pal: *const Palette, out: []u8) Error!void {
    var in: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &window);
    const bpp = @max(1, hd.bitsPerPixel() / 8);
    const max_row = (@as(usize, w) * hd.bitsPerPixel() + 7) / 8;
    const mem = try alloc.alloc(u8, (max_row + 1) * 2);
    defer alloc.free(mem);
    var bufs: [2][]u8 = .{ mem[0 .. max_row + 1], mem[max_row + 1 ..] };

    if (!hd.interlace) {
        try passRows(&dec, hd, pal, out, w, h, 0, 0, 1, 1, w, &bufs, bpp);
    } else for (adam7) |p| {
        if (w <= p[0] or h <= p[1]) continue;
        const pw = (w + p[2] - 1 - p[0]) / p[2];
        const ph = (h + p[3] - 1 - p[1]) / p[3];
        try passRows(&dec, hd, pal, out, w, ph, p[0], p[1], p[2], p[3], pw, &bufs, bpp);
    }
}

fn passRows(dec: *flate.Decompress, hd: Header, pal: *const Palette, out: []u8, w: u32, ph: u32, x0: u32, y0: u32, dx: u32, dy: u32, pw: u32, bufs: *[2][]u8, bpp: usize) Error!void {
    const row_len = (@as(usize, pw) * hd.bitsPerPixel() + 7) / 8;
    @memset(bufs[0][0 .. row_len + 1], 0);
    var prev = bufs[0][0 .. row_len + 1];
    var curb = bufs[1][0 .. row_len + 1];
    for (0..ph) |ry| {
        dec.reader.readSliceAll(curb) catch return error.Corrupt;
        try unfilter(curb[0], curb[1..], prev[1..], bpp);
        const y: usize = y0 + ry * dy;
        convertRow(hd, pal, curb[1..], out[(y * w) * 4 ..][0 .. w * 4], x0, dx, pw);
        std.mem.swap([]u8, &prev, &curb);
    }
}

fn sample(row: []const u8, depth: u8, i: usize) u16 {
    return switch (depth) {
        1 => (row[i / 8] >> @intCast(7 - i % 8)) & 1,
        2 => (row[i / 4] >> @intCast((3 - i % 4) * 2)) & 3,
        4 => (row[i / 2] >> @intCast((1 - i % 2) * 4)) & 15,
        8 => row[i],
        else => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
    };
}

fn convertRow(hd: Header, pal: *const Palette, row: []const u8, dst: []u8, x0: u32, dx: u32, pw: u32) void {
    const d = hd.depth;
    for (0..pw) |i| {
        const o = dst[(x0 + i * dx) * 4 ..][0..4];
        switch (hd.ctype) {
            0 => {
                const v = sample(row, d, i);
                const g: u8 = if (d == 16) @intCast(v >> 8) else @intCast(v * 255 / ((@as(u16, 1) << @intCast(d)) - 1));
                const a: u8 = if (pal.key != null and pal.key.?[0] == v) 0 else 255;
                o.* = .{ g, g, g, a };
            },
            2 => {
                const r = sample(row, d, i * 3);
                const g = sample(row, d, i * 3 + 1);
                const b = sample(row, d, i * 3 + 2);
                const a: u8 = if (pal.key) |k| (if (k[0] == r and k[1] == g and k[2] == b) 0 else 255) else 255;
                if (d == 16) {
                    o.* = .{ @intCast(r >> 8), @intCast(g >> 8), @intCast(b >> 8), a };
                } else o.* = .{ @intCast(r), @intCast(g), @intCast(b), a };
            },
            3 => {
                const idx = sample(row, d, i);
                if (idx < pal.len) {
                    o.* = .{ pal.rgb[idx][0], pal.rgb[idx][1], pal.rgb[idx][2], pal.alpha[idx] };
                } else o.* = .{ 0, 0, 0, 255 };
            },
            4 => {
                const g: u8 = @intCast(if (d == 16) sample(row, d, i * 2) >> 8 else sample(row, d, i * 2));
                const a: u8 = @intCast(if (d == 16) sample(row, d, i * 2 + 1) >> 8 else sample(row, d, i * 2 + 1));
                o.* = .{ g, g, g, a };
            },
            else => {
                var px: [4]u8 = undefined;
                for (0..4) |k| {
                    const v = sample(row, d, i * 4 + k);
                    px[k] = @intCast(if (d == 16) v >> 8 else v);
                }
                o.* = px;
            },
        }
    }
}
