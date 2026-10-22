const std = @import("std");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

pub fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn args(init: std.process.Init, count: usize, usage: []const u8) ![]const [:0]const u8 {
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    if (all.len != count + 1) {
        std.debug.print("usage: {s}\n", .{usage});
        return error.Usage;
    }
    return all[1..];
}
