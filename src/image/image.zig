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
    }
};

pub const Error = error{ UnsupportedFormat, Corrupt, TooLarge, OutOfMemory };

pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    _ = alloc;
    _ = bytes;
    return error.UnsupportedFormat;
}
