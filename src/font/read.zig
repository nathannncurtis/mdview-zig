const std = @import("std");

pub const Error = error{ Corrupt, Unsupported, OutOfMemory, TooLarge };

pub fn u16At(d: []const u8, off: usize) Error!u16 {
    if (off > d.len or d.len - off < 2) return error.Corrupt;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

pub fn i16At(d: []const u8, off: usize) Error!i16 {
    return @bitCast(try u16At(d, off));
}

pub fn u32At(d: []const u8, off: usize) Error!u32 {
    if (off > d.len or d.len - off < 4) return error.Corrupt;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}
