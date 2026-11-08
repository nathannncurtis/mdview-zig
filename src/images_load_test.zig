const std = @import("std");
const images = @import("images.zig");
const testing = std.testing;

fn waitFor(target: []const u8, avail: f32) !images.Look {
    const deadline = images.now() + 5000;
    while (images.now() < deadline) {
        _ = images.tick();
        const l = images.look(target, avail);
        if (l != .pending) return l;
        std.Io.sleep(images.io, .fromMilliseconds(5), .awake) catch break;
    }
    return error.Timeout;
}

test "a fixture loads on the worker thread, scales down and animates" {
    images.init(testing.allocator, testing.io);
    images.reset("testdata/images", false);
    defer images.clearAll();

    const png = try waitFor("png_rgba8.png", 10000);
    try testing.expect(png == .picture);
    try testing.expect(png.picture.w > 0 and png.picture.h > 0);
    const half = images.look("png_rgba8.png", png.picture.w / 2).picture;
    try testing.expectApproxEqAbs(png.picture.w / 2, half.w, 0.01);
    try testing.expectApproxEqAbs(png.picture.h / 2, half.h, 0.01);

    const gif = try waitFor("gif_anim_forever.gif", 10000);
    try testing.expect(gif == .picture);
    try testing.expect(try waitFor("images/not-here.png", 100) == .missing);
}
