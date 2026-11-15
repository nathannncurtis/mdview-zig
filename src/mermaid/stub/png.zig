const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Image = struct { width: u32, height: u32, rgba: []u8 };

pub const Error = error{ Unsupported, Corrupt, OutOfMemory };

const signature = "\x89PNG\r\n\x1a\n";
const max_pixels: u64 = 64 * 1024 * 1024;

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

pub fn decode(arena: Allocator, bytes: []const u8) Error!Image {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.Corrupt;
    var pos: usize = signature.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var color: u8 = 0;
    var palette: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    while (pos + 12 <= bytes.len) {
        const len = be32(bytes[pos..]);
        const kind = bytes[pos + 4 ..][0..4];
        if (len > bytes.len - pos - 12) return error.Corrupt;
        const body = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13 or body[8] != 8 or body[12] != 0) return error.Unsupported;
            width = be32(body);
            height = be32(body[4..]);
            color = body[9];
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = body;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(arena, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (width == 0 or height == 0 or @as(u64, width) * height > max_pixels) return error.Corrupt;
    const bpp: usize = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    const stride = @as(usize, width) * bpp;
    var in: std.Io.Reader = .fixed(idat.items);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &window);
    const raw = dec.reader.allocRemaining(arena, .limited((stride + 1) * @as(usize, height))) catch return error.Corrupt;
    if (raw.len != (stride + 1) * height) return error.Corrupt;
    const rgba = try arena.alloc(u8, @as(usize, width) * height * 4);
    const prev = try arena.alloc(u8, stride);
    @memset(prev, 0);
    const line = try arena.alloc(u8, stride);
    for (0..height) |y| {
        const row = raw[y * (stride + 1) ..][0 .. stride + 1];
        @memcpy(line, row[1..]);
        try unfilter(row[0], line, prev, bpp);
        for (0..width) |x| {
            const px = line[x * bpp ..][0..bpp];
            const o = rgba[(y * width + x) * 4 ..][0..4];
            switch (color) {
                0 => o.* = .{ px[0], px[0], px[0], 255 },
                2 => o.* = .{ px[0], px[1], px[2], 255 },
                3 => {
                    if (@as(usize, px[0]) * 3 + 3 > palette.len) return error.Corrupt;
                    o.* = .{ palette[px[0] * 3], palette[px[0] * 3 + 1], palette[px[0] * 3 + 2], 255 };
                },
                4 => o.* = .{ px[0], px[0], px[0], px[1] },
                else => o.* = px[0..4].*,
            }
        }
        @memcpy(prev, line);
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn unfilter(filter: u8, line: []u8, prev: []const u8, bpp: usize) Error!void {
    for (line, 0..) |*c, i| {
        const a: i32 = if (i >= bpp) line[i - bpp] else 0;
        const b: i32 = prev[i];
        const d: i32 = if (i >= bpp) prev[i - bpp] else 0;
        const add: i32 = switch (filter) {
            0 => 0,
            1 => a,
            2 => b,
            3 => (a + b) >> 1,
            4 => paeth(a, b, d),
            else => return error.Corrupt,
        };
        c.* +%= @intCast(add & 255);
    }
}

fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}
