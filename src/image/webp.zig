const std = @import("std");
const image = @import("image.zig");

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) image.Error!image.Image {
    _ = alloc;
    _ = bytes;
    return error.UnsupportedFormat;
}
