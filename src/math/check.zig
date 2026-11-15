const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");

/// The parser's message when `tex` is not valid TeX, allocated from `a`; null when it parses.
pub fn errorMessage(a: Allocator, tex: []const u8) Allocator.Error!?[]const u8 {
    var t = try parser.parse(a, tex, .{});
    defer t.deinit();
    const msg = t.err orelse return null;
    return try a.dupe(u8, msg);
}

test "errorMessage reports what the parser rejects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try errorMessage(a, "x^2+y_1")) == null);
    try std.testing.expectEqualStrings("Missing argument for \\frac", (try errorMessage(a, "\\frac{1}")).?);
    try std.testing.expectEqualStrings("Double exponent: use braces to clarify", (try errorMessage(a, "a^b^c")).?);
}
