pub fn file(comptime path: []const u8) []const u8 {
    return @embedFile(path);
}
