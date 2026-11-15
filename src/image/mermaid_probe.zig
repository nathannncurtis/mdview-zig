const std = @import("std");
const images = @import("images.zig");

pub const Probe = union(enum) { size: struct { w: f32, h: f32 }, pending, failed };

/// A load still under way is `pending`: a synchronous render cannot wait, so the caller lays the shape out at zero size and re-renders when the image lands.
pub fn probe(href: []const u8) Probe {
    return switch (images.look(href, std.math.floatMax(f32))) {
        .picture => |s| .{ .size = .{ .w = s.w, .h = s.h } },
        .pending => .pending,
        .missing => .failed,
    };
}

test "probe reports a loaded size and a failed image" {
    images.init(std.testing.allocator, std.testing.io);
    images.reset("", false);
    defer images.clearAll();
    try images.injectReady("ready.png", 30, 12);
    const s = probe("ready.png").size;
    try std.testing.expectEqual(@as(f32, 30), s.w);
    try std.testing.expectEqual(@as(f32, 12), s.h);
    try std.testing.expect(probe("data:image/png;base64,AAAA") == .failed);
}
