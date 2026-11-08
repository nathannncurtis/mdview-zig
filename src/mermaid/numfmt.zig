const std = @import("std");
const Allocator = std.mem.Allocator;

/// Formats like ECMAScript Number::toString.
pub fn js(a: Allocator, f: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f < 0) "-Infinity" else "Infinity";
    if (f == 0) return "0";
    var buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&buf, "{e}", .{@abs(f)}) catch @panic("float formatting");
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch @panic("float formatting");
    var digits: [32]u8 = undefined;
    var k: usize = 0;
    for (sci[0..e_at]) |c| if (c != '.') {
        digits[k] = c;
        k += 1;
    };
    const n: i32 = exp + 1;
    var out: std.ArrayList(u8) = .empty;
    if (f < 0) try out.append(a, '-');
    const ki: i32 = @intCast(k);
    if (ki <= n and n <= 21) {
        try out.appendSlice(a, digits[0..k]);
        try out.appendNTimes(a, '0', @intCast(n - ki));
    } else if (0 < n and n <= 21) {
        try out.appendSlice(a, digits[0..@intCast(n)]);
        try out.append(a, '.');
        try out.appendSlice(a, digits[@intCast(n)..k]);
    } else if (-6 < n and n <= 0) {
        try out.appendSlice(a, "0.");
        try out.appendNTimes(a, '0', @intCast(-n));
        try out.appendSlice(a, digits[0..k]);
    } else {
        try out.append(a, digits[0]);
        if (k > 1) {
            try out.append(a, '.');
            try out.appendSlice(a, digits[1..k]);
        }
        try out.print(a, "e{c}{d}", .{ if (n - 1 < 0) @as(u8, '-') else '+', @abs(n - 1) });
    }
    return out.items;
}

/// Math.round: ties go toward positive infinity.
pub fn round(x: f64) f64 {
    const fl = @floor(x);
    return if (x - fl >= 0.5) fl + 1 else fl;
}

test "js number format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { f64, []const u8 }{
        .{ 0, "0" },                       .{ 5, "5" },                       .{ -5, "-5" },
        .{ 0.5, "0.5" },                   .{ 1.5873015873, "1.5873015873" }, .{ 1e-7, "1e-7" },
        .{ 0.000001, "0.000001" },         .{ 1.5e-7, "1.5e-7" },             .{ 1e21, "1e+21" },
        .{ 123456789012, "123456789012" }, .{ 0.1, "0.1" },                   .{ 100, "100" },
        .{ 12.3, "12.3" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try js(a, c[0]));
    try std.testing.expectEqual(@as(f64, 3), round(2.5));
    try std.testing.expectEqual(@as(f64, -2), round(-2.5));
}
