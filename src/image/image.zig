const std = @import("std");

pub const Frame = struct { rgba: []u8, delay_ms: u32 };

pub const Image = struct {
    width: u32,
    height: u32,
    frames: []Frame,
    loop_count: u32,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        for (self.frames) |f| alloc.free(f.rgba);
        alloc.free(self.frames);
        self.* = undefined;
    }
};

pub const Error = error{ UnsupportedFormat, Corrupt, TooLarge, OutOfMemory };

pub const max_pixels: u64 = 64 * 1024 * 1024;
pub const max_total_pixels: u64 = 128 * 1024 * 1024;

pub const bmp = @import("bmp.zig");
pub const gif = @import("gif.zig");
pub const jpeg = @import("jpeg.zig");
pub const png = @import("png.zig");
pub const webp = @import("webp.zig");

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    var img = try decodeRaw(alloc, bytes);
    for (img.frames) |*f| {
        if (f.delay_ms <= 10) f.delay_ms = 100;
    }
    if (img.frames.len == 1) img.frames[0].delay_ms = 0;
    return img;
}

fn decodeRaw(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return png.decode(alloc, bytes);
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return jpeg.decode(alloc, bytes);
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return gif.decode(alloc, bytes);
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return webp.decode(alloc, bytes);
    if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M') return bmp.decode(alloc, bytes);
    return error.UnsupportedFormat;
}

pub fn checkDims(w: u64, h: u64) Error!void {
    if (w == 0 or h == 0) return error.Corrupt;
    if (w > std.math.maxInt(u31) or h > std.math.maxInt(u31)) return error.TooLarge;
    if (w * h > max_pixels) return error.TooLarge;
}

pub fn allocRgba(alloc: std.mem.Allocator, w: u32, h: u32) Error![]u8 {
    try checkDims(w, h);
    return alloc.alloc(u8, @as(usize, w) * h * 4);
}

pub const Cursor = struct {
    b: []const u8,
    pos: usize = 0,

    pub fn left(c: *const Cursor) usize {
        return c.b.len - c.pos;
    }

    pub fn take(c: *Cursor, n: usize) Error![]const u8 {
        if (n > c.left()) return error.Corrupt;
        const s = c.b[c.pos..][0..n];
        c.pos += n;
        return s;
    }

    pub fn byte(c: *Cursor) Error!u8 {
        return (try c.take(1))[0];
    }

    pub fn le16(c: *Cursor) Error!u16 {
        return std.mem.readInt(u16, (try c.take(2))[0..2], .little);
    }

    pub fn le32(c: *Cursor) Error!u32 {
        return std.mem.readInt(u32, (try c.take(4))[0..4], .little);
    }

    pub fn be16(c: *Cursor) Error!u16 {
        return std.mem.readInt(u16, (try c.take(2))[0..2], .big);
    }

    pub fn be32(c: *Cursor) Error!u32 {
        return std.mem.readInt(u32, (try c.take(4))[0..4], .big);
    }
};

pub const FrameList = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(Frame) = .empty,
    total_pixels: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) FrameList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FrameList) void {
        for (self.list.items) |f| self.alloc.free(f.rgba);
        self.list.deinit(self.alloc);
    }

    pub fn add(self: *FrameList, w: u32, h: u32, rgba: []u8, delay_ms: u32) Error!void {
        self.total_pixels += @as(u64, w) * h;
        if (self.total_pixels > max_total_pixels) return error.TooLarge;
        try self.list.append(self.alloc, .{ .rgba = rgba, .delay_ms = delay_ms });
    }

    pub fn finish(self: *FrameList, w: u32, h: u32, loop_count: u32) Error!Image {
        const frames = try self.list.toOwnedSlice(self.alloc);
        return .{ .width = w, .height = h, .frames = frames, .loop_count = loop_count };
    }
};

pub fn single(alloc: std.mem.Allocator, w: u32, h: u32, rgba: []u8) Error!Image {
    const frames = alloc.alloc(Frame, 1) catch |e| {
        alloc.free(rgba);
        return e;
    };
    frames[0] = .{ .rgba = rgba, .delay_ms = 0 };
    return .{ .width = w, .height = h, .frames = frames, .loop_count = 0 };
}
