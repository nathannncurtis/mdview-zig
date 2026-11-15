const std = @import("std");
const image = @import("image");
const files = @import("files.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.Usage;
    const runs: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 5;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .unlimited);
    var best: i64 = std.math.maxInt(i64);
    var w: u32 = 0;
    var h: u32 = 0;
    for (0..runs) |_| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        var img = try image.decode(std.heap.page_allocator, data);
        const ms = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toMilliseconds();
        w = img.width;
        h = img.height;
        img.deinit(std.heap.page_allocator);
        best = @min(best, ms);
    }
    files.say(init.io, "{s}: {d}x{d}, {d} bytes, best of {d} runs {d} ms\n", .{ args[1], w, h, data.len, runs, best });
}
