const std = @import("std");
const builtin = @import("builtin");
const ttf = @import("ttf.zig");
const resolver = @import("resolve.zig");

pub const Font = ttf.Font;
pub const Path = ttf.Path;
pub const Mat = ttf.Mat;
pub const Pt = ttf.Pt;
pub const Error = ttf.Error;
pub const resolve = resolver.resolve;
pub const bundled = resolver.bundled;

pub const Size = struct { w: f64, h: f64 };

pub fn measure(font: *const Font, utf8: []const u8, size: f64) Size {
    const m = font.measure(utf8, size);
    return .{ .w = m.w, .h = m.h };
}

const sample = "Validate order? Wait: AV Team / Ship Today (Type 2)";

test "bundled font metrics" {
    const f = bundled(false, false);
    try std.testing.expectEqual(@as(u16, 2048), f.upem);
    try std.testing.expectEqual(@as(f64, 1366), f.advance(f.glyphIndex('A')));
    try std.testing.expect(f.kern(f.glyphIndex('A'), f.glyphIndex('V')) < 0);
    try std.testing.expectEqual(@as(u16, 0), f.glyphIndex(0x4E2D));
    try std.testing.expect(f.glyphIndex(0xE9) != 0);
    try std.testing.expect(f.glyphIndex(0x20AC) != 0);
    const b = bundled(true, false);
    try std.testing.expect(b.advance(b.glyphIndex('A')) == 1479);
}

test "bundled glyphs have outlines, composites included" {
    const a = std.testing.allocator;
    const f = bundled(false, false);
    for ([_]u32{ 'A', 'g', 0xE9, 0xC5, 0x20AC }) |cp| {
        var p: Path = .{};
        defer p.deinit(a);
        try f.outline(a, f.glyphIndex(cp), .{}, &p);
        try std.testing.expect(p.segs.items.len > 4);
    }
    var space: Path = .{};
    defer space.deinit(a);
    try f.outline(a, f.glyphIndex(' '), .{}, &space);
    try std.testing.expectEqual(@as(usize, 0), space.segs.items.len);
}

test "outlineAt scales, flips and slants" {
    const a = std.testing.allocator;
    const f = bundled(false, false);
    const g = f.glyphIndex('I');
    var p: Path = .{};
    defer p.deinit(a);
    try f.outlineAt(a, g, 16, 10, 20, &p);
    var min_y: f64 = 1e9;
    var max_y: f64 = -1e9;
    for (p.segs.items) |s| switch (s) {
        .move, .line => |q| {
            min_y = @min(min_y, q.y);
            max_y = @max(max_y, q.y);
        },
        else => {},
    };
    try std.testing.expectApproxEqAbs(@as(f64, 20), max_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 20 - 1409.0 / 2048.0 * 16), min_y, 0.1);
    const it = bundled(false, true);
    try std.testing.expect(it.oblique);
    var q: Path = .{};
    defer q.deinit(a);
    try it.outlineAt(a, g, 16, 10, 20, &q);
    var shift: f64 = 0;
    for (p.segs.items, q.segs.items) |sp, sq| switch (sp) {
        .move, .line => |pp| shift = @max(shift, switch (sq) {
            .move, .line => |qq| qq.x - pp.x,
            else => 0,
        }),
        else => {},
    };
    try std.testing.expectApproxEqAbs(0.25 * 1409.0 / 2048.0 * 16, shift, 0.1);
}

test "measure sums advances and applies kerning" {
    const f = bundled(false, false);
    const plain = f.width("AV", 16, false);
    const kerned = measure(f, "AV", 16);
    try std.testing.expectApproxEqAbs(@as(f64, (1366 + 1366) * 16.0 / 2048.0), plain, 1e-9);
    try std.testing.expect(kerned.w < plain);
    try std.testing.expectApproxEqAbs(f.lineHeight(16), kerned.h, 1e-9);
    try std.testing.expect(kerned.h > 16 and kerned.h < 20);
    try std.testing.expectEqual(@as(f64, 0), f.width("", 16, true));
    try std.testing.expect(f.width("\xff\xfe\xc3", 16, true) > 0);
}

test "resolver falls back to the bundled font" {
    const io = std.testing.io;
    try std.testing.expect(resolve(io, "no-such-family-zz", 400, false) == bundled(false, false));
    try std.testing.expect(resolve(io, "'No Such', \"Other One\"", 700, false) == bundled(true, false));
    try std.testing.expect(resolve(io, "", 400, true) == bundled(false, true));
    try std.testing.expect(resolve(io, "no-such-family-zz", 400, false) == bundled(false, false));
}

test "sans-serif resolves to a face with Arial metrics" {
    const f = resolve(std.testing.io, "sans-serif", 400, false);
    const ratio = f.advance(f.glyphIndex('A')) / @as(f64, @floatFromInt(f.upem));
    try std.testing.expectApproxEqAbs(@as(f64, 0.667), ratio, 0.002);
    const w = f.width(sample, 16, false);
    try std.testing.expectApproxEqAbs(@as(f64, 378.83), w, 0.1);
}

test "file names follow each platform's layout" {
    const win = resolver.fileNames(.windows, "trebuchet ms", true, false);
    try std.testing.expectEqualStrings("trebucbd.ttf", win.get(0));
    const mac = resolver.fileNames(.macos, "trebuchet ms", true, true);
    try std.testing.expectEqualStrings("Trebuchet MS Bold Italic.ttf", mac.get(0));
    const lin = resolver.fileNames(.linux, "trebuchet ms", false, false);
    try std.testing.expectEqualStrings("trebuc.ttf", lin.get(0));
    try std.testing.expectEqualStrings("trebuchet_ms.ttf", lin.get(1));
    try std.testing.expectEqual(@as(usize, 0), resolver.fileNames(.windows, "tahoma", false, true).n);
}

test "collections pick the face by family and style" {
    const a = std.testing.allocator;
    const one = @embedFile("sans_regular.ttf");
    const bold = @embedFile("sans_bold.ttf");
    const head = 12 + 8;
    const out = try a.alloc(u8, head + one.len + bold.len);
    defer a.free(out);
    @memcpy(out[0..4], "ttcf");
    std.mem.writeInt(u32, out[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, out[8..12], 2, .big);
    std.mem.writeInt(u32, out[12..16], head, .big);
    std.mem.writeInt(u32, out[16..20], head + one.len, .big);
    for ([_]struct { src: []const u8, at: usize }{ .{ .src = one, .at = head }, .{ .src = bold, .at = head + one.len } }) |part| {
        @memcpy(out[part.at..][0..part.src.len], part.src);
        const n = std.mem.readInt(u16, part.src[4..6], .big);
        for (0..n) |i| {
            const rec = part.at + 12 + i * 16 + 8;
            std.mem.writeInt(u32, out[rec..][0..4], std.mem.readInt(u32, out[rec..][0..4], .big) + @as(u32, @intCast(part.at)), .big);
        }
    }
    try std.testing.expectEqual(@as(u32, 2), ttf.faceCount(out));
    try std.testing.expectEqual(@as(?u32, 0), resolver.pickFace(out, "mdview sans", false, false));
    try std.testing.expectEqual(@as(?u32, 1), resolver.pickFace(out, "mdview sans", true, false));
    try std.testing.expectEqual(@as(?u32, null), resolver.pickFace(out, "mdview sans", false, true));
    try std.testing.expectEqual(@as(?u32, null), resolver.pickFace(out, "other", false, false));
    const f1 = try Font.init(out, 1);
    try std.testing.expectEqual(@as(f64, 1479), f1.advance(f1.glyphIndex('A')));
}

test "damaged fonts never crash the parser" {
    const a = std.testing.allocator;
    const src = @embedFile("sans_regular.ttf");
    const buf = try a.dupe(u8, src);
    defer a.free(buf);
    var prng = std.Random.DefaultPrng.init(0x464f4e54);
    const r = prng.random();
    for (0..300) |round| {
        @memcpy(buf, src);
        for (0..1 + round % 24) |_| buf[r.uintLessThan(usize, buf.len)] = r.int(u8);
        const cut = if (round % 5 == 0) r.uintLessThan(usize, buf.len) else buf.len;
        const f = Font.init(buf[0..cut], 0) catch continue;
        _ = f.width(sample, 16, true);
        for ([_]u32{ 'A', 'g', 0xE9, 0xC5 }) |cp| {
            var p: Path = .{};
            defer p.deinit(a);
            f.outline(a, f.glyphIndex(cp), .{}, &p) catch {};
        }
    }
}

test "installed fonts match DirectWrite advances on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const cases = [_]struct { families: []const u8, weight: u16, expect: f64 }{
        .{ .families = "\"trebuchet ms\", verdana, arial, sans-serif", .weight = 400, .expect = 381.1094 },
        .{ .families = "trebuchet ms", .weight = 700, .expect = 395.0703 },
        .{ .families = "sans-serif", .weight = 400, .expect = 378.8281 },
        .{ .families = "arial", .weight = 700, .expect = 398.2891 },
        .{ .families = "verdana", .weight = 400, .expect = 431.6250 },
    };
    for (cases) |c| {
        const f = resolve(io, c.families, c.weight, false);
        if (f == bundled(c.weight >= 600, false)) return error.SkipZigTest;
        try std.testing.expectApproxEqAbs(c.expect, f.width(sample, 16, false), 0.1);
        try std.testing.expect(f.width(sample, 16, true) < c.expect);
    }
    const arial = resolve(io, "arial", 400, false);
    try std.testing.expectEqual(@as(f64, -152), arial.kern(arial.glyphIndex('A'), arial.glyphIndex('V')));
    try std.testing.expectEqual(@as(f64, 18), arial.lineHeight(16));
}
