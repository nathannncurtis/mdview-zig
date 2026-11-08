const std = @import("std");
const mermaid = @import("mermaid.zig");

const seeds = [_][]const u8{
    "info",
    "info showInfo\ntitle x\naccTitle: y\naccDescr {z}\n",
    "---\ntitle: t\nconfig:\n  theme: forest\n  themeVariables:\n    primaryColor: '#ff0'\n---\ninfo",
    "%%{init: {\"theme\":\"base\",\"themeVariables\":{\"primaryColor\":\"#ff0000\"}}}%%\n%% c\ninfo",
    "flowchart TD\nA[<a href=\"x\">y</a>]-->B #35; style a fill:#fff;\n",
};

const insertable = "%{}[]\"'-:#\n ;";

fn renderAndFree(text: []const u8) !void {
    const r = try mermaid.render(std.testing.allocator, text, .{});
    mermaid.free(std.testing.allocator, r);
}

test "mutated input never crashes or leaks" {
    var prng = std.Random.DefaultPrng.init(0x6d6d6372);
    const rng = prng.random();
    var buf: [256]u8 = undefined;
    for (0..1500) |_| {
        const seed = seeds[rng.uintLessThan(usize, seeds.len)];
        var len = seed.len;
        @memcpy(buf[0..len], seed);
        for (0..rng.uintLessThan(usize, 6)) |_| {
            switch (rng.uintLessThan(u8, 3)) {
                0 => if (len > 0) {
                    buf[rng.uintLessThan(usize, len)] = rng.int(u8);
                },
                1 => if (len + 1 < buf.len) {
                    const at = rng.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = insertable[rng.uintLessThan(usize, insertable.len)];
                    len += 1;
                },
                else => if (len > 0) {
                    const at = rng.uintLessThan(usize, len);
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
            }
        }
        try renderAndFree(buf[0..len]);
    }
}

test "hostile input" {
    const deep = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(deep);
    @memset(deep, '[');
    for ([_][]const u8{ "%%{init: ", "---\nconfig: ", "info " }) |prefix| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, deep, "\ninfo" });
        defer std.testing.allocator.free(text);
        try renderAndFree(text);
    }
    const big = try std.testing.allocator.alloc(u8, 60_000);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try renderAndFree(big);
    try renderAndFree("info \xff\xfe\x80 \xf0\x9f");
}
