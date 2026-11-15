const std = @import("std");
const Allocator = std.mem.Allocator;

/// Shrinks straight RGBA to `dw` x `dh` by averaging the source pixels each output pixel covers, weighted by overlap and by alpha.
pub fn shrink(a: Allocator, src: []const u8, sw: u32, sh: u32, dw: u32, dh: u32) Allocator.Error![]u8 {
    std.debug.assert(dw > 0 and dh > 0 and dw <= sw and dh <= sh and src.len == @as(usize, sw) * sh * 4);
    const out = try a.alloc(u8, @as(usize, dw) * dh * 4);
    errdefer a.free(out);
    const row = try a.alloc(f32, @as(usize, sw) * 4);
    defer a.free(row);
    const xs: f64 = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(dw));
    const ys: f64 = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(dh));
    for (0..dh) |oy| {
        const y0 = @as(f64, @floatFromInt(oy)) * ys;
        const y1 = y0 + ys;
        @memset(row, 0);
        var iy: usize = @intFromFloat(@floor(y0));
        const last_y: usize = @min(sh, @as(usize, @intFromFloat(@ceil(y1))));
        while (iy < last_y) : (iy += 1) {
            const wy: f32 = @floatCast(@min(@as(f64, @floatFromInt(iy + 1)), y1) - @max(@as(f64, @floatFromInt(iy)), y0));
            const line = src[iy * sw * 4 ..][0 .. sw * 4];
            var x: usize = 0;
            while (x < sw) : (x += 1) {
                const alpha: f32 = @floatFromInt(line[x * 4 + 3]);
                const w = wy * alpha;
                row[x * 4] += @as(f32, @floatFromInt(line[x * 4])) * w;
                row[x * 4 + 1] += @as(f32, @floatFromInt(line[x * 4 + 1])) * w;
                row[x * 4 + 2] += @as(f32, @floatFromInt(line[x * 4 + 2])) * w;
                row[x * 4 + 3] += w;
            }
        }
        for (0..dw) |ox| {
            const x0 = @as(f64, @floatFromInt(ox)) * xs;
            const x1 = x0 + xs;
            var sum = [4]f32{ 0, 0, 0, 0 };
            var ix: usize = @intFromFloat(@floor(x0));
            const last_x: usize = @min(sw, @as(usize, @intFromFloat(@ceil(x1))));
            while (ix < last_x) : (ix += 1) {
                const wx: f32 = @floatCast(@min(@as(f64, @floatFromInt(ix + 1)), x1) - @max(@as(f64, @floatFromInt(ix)), x0));
                for (0..4) |k| sum[k] += row[ix * 4 + k] * wx;
            }
            const px = out[(oy * dw + ox) * 4 ..][0..4];
            const area: f32 = @floatCast(xs * ys);
            if (sum[3] <= 0) {
                px.* = .{ 0, 0, 0, 0 };
                continue;
            }
            for (0..3) |k| px[k] = @intFromFloat(std.math.clamp(@round(sum[k] / sum[3]), 0, 255));
            px[3] = @intFromFloat(std.math.clamp(@round(sum[3] / area), 0, 255));
        }
    }
    return out;
}

const testing = std.testing;

test "a flat picture stays flat at any size" {
    const src = try testing.allocator.alloc(u8, 7 * 5 * 4);
    defer testing.allocator.free(src);
    for (0..35) |i| src[i * 4 ..][0..4].* = .{ 10, 120, 250, 255 };
    const out = try shrink(testing.allocator, src, 7, 5, 3, 2);
    defer testing.allocator.free(out);
    for (0..6) |i| try testing.expectEqualSlices(u8, &.{ 10, 120, 250, 255 }, out[i * 4 ..][0..4]);
}

test "a checker averages to grey and transparent pixels do not tint it" {
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..16) |i| {
        const white = (i % 4 + i / 4) % 2 == 0;
        src[i * 4 ..][0..4].* = if (white) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 255 };
    }
    const grey = try shrink(testing.allocator, &src, 4, 4, 1, 1);
    defer testing.allocator.free(grey);
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(grey[0])), 1);
    try testing.expectEqual(@as(u8, 255), grey[3]);

    for (0..16) |i| src[i * 4 ..][0..4].* = if (i % 2 == 0) .{ 200, 0, 0, 255 } else .{ 0, 255, 0, 0 };
    const half = try shrink(testing.allocator, &src, 4, 4, 2, 2);
    defer testing.allocator.free(half);
    try testing.expectEqual(@as(u8, 200), half[0]);
    try testing.expectEqual(@as(u8, 0), half[1]);
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(half[3])), 1);
}
