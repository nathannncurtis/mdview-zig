const std = @import("std");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

pub fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn say(io: std.Io, comptime fmt: []const u8, args_: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args_) catch return;
    w.interface.flush() catch return;
}

pub fn args(init: std.process.Init, count: usize, usage: []const u8) ![]const [:0]const u8 {
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    if (all.len != count + 1) {
        say(init.io, "usage: {s}\n", .{usage});
        return error.Usage;
    }
    return all[1..];
}
