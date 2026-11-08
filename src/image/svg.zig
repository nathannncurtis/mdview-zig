const std = @import("std");
const image = @import("image.zig");

pub fn isSvg(bytes: []const u8) bool {
    _ = bytes;
    return false;
}

pub fn intrinsicSize(bytes: []const u8) image.Error!struct { w: f32, h: f32 } {
    _ = bytes;
    return error.UnsupportedFormat;
}

pub fn render(alloc: std.mem.Allocator, bytes: []const u8, width: u32, height: u32) image.Error!image.Image {
    _ = alloc;
    _ = bytes;
    _ = width;
    _ = height;
    return error.UnsupportedFormat;
}

pub fn isAnimated(bytes: []const u8) bool {
    _ = bytes;
    return false;
}

pub fn renderAt(alloc: std.mem.Allocator, bytes: []const u8, width: u32, height: u32, t_ms: u32) image.Error!image.Image {
    _ = alloc;
    _ = bytes;
    _ = width;
    _ = height;
    _ = t_ms;
    return error.UnsupportedFormat;
}
