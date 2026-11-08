const std = @import("std");
const image = @import("image.zig");

const dir = "testdata/images/";

fn readFile(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, name });
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(64 << 20));
}

const Entry = struct {
    name: []const u8,
    width: u32,
    height: u32,
    frames: usize,
    loops: u32,
    crc: u32,
    delays: []const u8,
};

fn parseEntry(line: []const u8) !Entry {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const name = it.next().?;
    return .{
        .name = name,
        .width = try std.fmt.parseInt(u32, it.next().?, 10),
        .height = try std.fmt.parseInt(u32, it.next().?, 10),
        .frames = try std.fmt.parseInt(usize, it.next().?, 10),
        .loops = try std.fmt.parseInt(u32, it.next().?, 10),
        .crc = try std.fmt.parseInt(u32, it.next().?, 16),
        .delays = it.next().?,
    };
}

fn manifest(alloc: std.mem.Allocator) ![]u8 {
    return readFile(alloc, "manifest.txt");
}

test "decoded pixels match the reference checksums" {
    const alloc = std.testing.allocator;
    const text = try manifest(alloc);
    defer alloc.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const e = try parseEntry(line);
        const bytes = try readFile(alloc, e.name);
        defer alloc.free(bytes);
        var img = image.decode(alloc, bytes) catch |err| {
            std.debug.print("{s}: {t}\n", .{ e.name, err });
            return err;
        };
        defer img.deinit(alloc);
        try std.testing.expectEqual(e.width, img.width);
        try std.testing.expectEqual(e.height, img.height);
        try std.testing.expectEqual(e.frames, img.frames.len);
        try std.testing.expectEqual(e.loops, img.loop_count);
        var crc = std.hash.Crc32.init();
        var delays: std.ArrayList(u8) = .empty;
        defer delays.deinit(alloc);
        for (img.frames, 0..) |f, i| {
            try std.testing.expectEqual(@as(usize, e.width) * e.height * 4, f.rgba.len);
            crc.update(f.rgba);
            if (i > 0) try delays.append(alloc, ',');
            try delays.print(alloc, "{d}", .{f.delay_ms});
        }
        std.testing.expectEqual(e.crc, crc.final()) catch |err| {
            std.debug.print("{s}: checksum mismatch\n", .{e.name});
            return err;
        };
        try std.testing.expectEqualStrings(e.delays, delays.items);
        count += 1;
    }
    try std.testing.expect(count >= 100);
}

test "every format and variant has a fixture" {
    const alloc = std.testing.allocator;
    const text = try manifest(alloc);
    defer alloc.free(text);
    const required = [_][]const u8{
        "png_gray1",           "png_gray2",                "png_gray4",          "png_gray8",           "png_gray16",               "png_graya8",          "png_graya16",
        "png_pal1",            "png_pal2",                 "png_pal4",           "png_pal8",            "png_rgb8",                 "png_rgb16",           "png_rgba8",
        "png_rgba16",          "png_rgb8_i",               "png_rgba16_i",       "png_gray8_trns",      "png_rgb16_trns",           "png_pal4_trns",       "apng_basic",
        "apng_hidden_default", "jpeg_444",                 "jpeg_422",           "jpeg_420",            "jpeg_gray",                "jpeg_cmyk",           "jpeg_prog_420",
        "jpeg_prog_444",       "jpeg_restart",             "jpeg_exif_6",        "jpeg_exif_8",         "gif_static",               "gif_interlaced",      "gif_trans",
        "gif_anim_disposal",   "gif_anim_forever",         "gif_anim_once",      "bmp_pal1",            "bmp_pal4",                 "bmp_pal8",            "bmp_rle4",
        "bmp_rle8",            "bmp_rgb16_555",            "bmp_rgb16_565",      "bmp_rgb24",           "bmp_rgb32_alpha",          "bmp_rgb32_bitfields", "bmp_rgb24_topdown",
        "webp_lossy_q75",      "webp_lossless",            "webp_lossy_alpha",   "webp_lossless_alpha", "webp_anim_lossless",       "webp_anim_lossy",     "jpeg_arith_420",
        "jpeg_arith_444",      "jpeg_arith_gray",          "jpeg_arith_prog",    "jpeg_arith_restart",  "jpeg_440",                 "jpeg_411",            "webp_simple_filter",
        "png_icc_p3",          "png_gama_linear",          "png_gama22_chrm_p3", "jpeg_icc_p3",         "jpeg_icc_multichunk",      "webp_icc_p3_lossy",   "bmp_v5_icc_p3",
        "png_truncated",       "png_interlaced_truncated", "jpeg_truncated",     "gif_truncated",       "gif_interlaced_truncated", "bmp_truncated",       "bmp_embedded_png",
        "bmp_embedded_jpeg",
    };
    for (required) |name| {
        const key = try std.fmt.allocPrint(alloc, "{s}.", .{name});
        defer alloc.free(key);
        var found = false;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, key)) found = true;
        }
        if (!found) {
            std.debug.print("missing fixture {s}\n", .{name});
            return error.MissingFixture;
        }
    }
}

test "truncated files decode what arrived or return an error" {
    const alloc = std.testing.allocator;
    const text = try manifest(alloc);
    defer alloc.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const e = try parseEntry(line);
        const bytes = try readFile(alloc, e.name);
        defer alloc.free(bytes);
        const cuts = [_]usize{ 0, 1, 7, 12, bytes.len / 4, bytes.len / 2, bytes.len - 1 };
        for (cuts) |n| {
            if (image.decode(alloc, bytes[0..n])) |img| {
                var m = img;
                m.deinit(alloc);
                if (n < 8) {
                    std.debug.print("{s}: {d} bytes decoded\n", .{ e.name, n });
                    return error.TruncatedInputAccepted;
                }
            } else |err| switch (err) {
                error.UnsupportedFormat, error.Corrupt, error.TooLarge => {},
                error.OutOfMemory => return err,
            }
        }
    }
}

test "corrupted files never crash" {
    const alloc = std.testing.allocator;
    const text = try manifest(alloc);
    defer alloc.free(text);
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const e = try parseEntry(line);
        const bytes = try readFile(alloc, e.name);
        defer alloc.free(bytes);
        const work = try alloc.dupe(u8, bytes);
        defer alloc.free(work);
        for (0..40) |_| {
            @memcpy(work, bytes);
            const flips = rnd.intRangeAtMost(usize, 1, 4);
            for (0..flips) |_| {
                const at = if (rnd.boolean()) rnd.uintLessThan(usize, @min(work.len, 64)) else rnd.uintLessThan(usize, work.len);
                work[at] = rnd.int(u8);
            }
            if (image.decode(alloc, work)) |img| {
                var m = img;
                m.deinit(alloc);
            } else |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            }
        }
    }
}

fn expectDecodeError(expected: anyerror, bytes: []const u8) !void {
    const r = image.decode(std.testing.allocator, bytes);
    if (r) |img| {
        var m = img;
        m.deinit(std.testing.allocator);
        return error.DecodedMalformedInput;
    } else |err| try std.testing.expectEqual(expected, err);
}

test "unknown formats are unsupported" {
    try expectDecodeError(error.UnsupportedFormat, "");
    try expectDecodeError(error.UnsupportedFormat, "hello world, not an image");
    try expectDecodeError(error.UnsupportedFormat, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>");
    try expectDecodeError(error.UnsupportedFormat, "\x00\x00\x01\x00\x01\x00");
}

fn pngWithHeader(buf: *[33]u8, w: u32, h: u32, depth: u8, ctype: u8) []const u8 {
    @memcpy(buf[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, buf[8..12], 13, .big);
    @memcpy(buf[12..16], "IHDR");
    std.mem.writeInt(u32, buf[16..20], w, .big);
    std.mem.writeInt(u32, buf[20..24], h, .big);
    buf[24] = depth;
    buf[25] = ctype;
    buf[26] = 0;
    buf[27] = 0;
    buf[28] = 0;
    @memset(buf[29..33], 0);
    return buf;
}

test "malformed and oversized PNG headers" {
    var buf: [33]u8 = undefined;
    try expectDecodeError(error.Corrupt, pngWithHeader(&buf, 0, 5, 8, 6));
    try expectDecodeError(error.Corrupt, pngWithHeader(&buf, 5, 0, 8, 6));
    try expectDecodeError(error.Corrupt, pngWithHeader(&buf, 5, 5, 3, 6));
    try expectDecodeError(error.Corrupt, pngWithHeader(&buf, 5, 5, 8, 5));
    try expectDecodeError(error.TooLarge, pngWithHeader(&buf, 100000, 100000, 8, 6));
    try expectDecodeError(error.TooLarge, pngWithHeader(&buf, 9000, 9000, 8, 6));
    try expectDecodeError(error.Corrupt, pngWithHeader(&buf, 5, 5, 8, 6));
}

test "malformed and oversized JPEG, GIF, BMP and WebP headers" {
    try expectDecodeError(error.Corrupt, "\xff\xd8\xff\xd9");
    try expectDecodeError(error.Corrupt, "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x10\x00\x10\x01\x01\x11\x00");
    try expectDecodeError(error.TooLarge, "\xff\xd8\xff\xc0\x00\x0b\x08\xff\xff\xff\xff\x01\x01\x11\x00\xff\xd9");
    try expectDecodeError(error.UnsupportedFormat, "\xff\xd8\xff\xc3\x00\x0b\x08\x00\x10\x00\x10\x01\x01\x11\x00\xff\xd9");
    try expectDecodeError(error.Corrupt, "GIF89a");
    try expectDecodeError(error.TooLarge, "GIF89a\xff\xff\xff\xff\x00\x00\x00;");
    try expectDecodeError(error.Corrupt, "GIF89a\x04\x00\x04\x00\x00\x00\x00;");
    try expectDecodeError(error.Corrupt, "BM");
    try expectDecodeError(error.UnsupportedFormat, "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x07\x00\x00\x00\x01\x00\x00\x00\x01\x00\x01\x00\x00\x00\x00\x00");
    var bmp: [54]u8 = @splat(0);
    @memcpy(bmp[0..2], "BM");
    std.mem.writeInt(u32, bmp[10..14], 54, .little);
    std.mem.writeInt(u32, bmp[14..18], 40, .little);
    std.mem.writeInt(i32, bmp[18..22], 100000, .little);
    std.mem.writeInt(i32, bmp[22..26], 100000, .little);
    std.mem.writeInt(u16, bmp[26..28], 1, .little);
    std.mem.writeInt(u16, bmp[28..30], 24, .little);
    try expectDecodeError(error.TooLarge, &bmp);
    std.mem.writeInt(i32, bmp[18..22], 0, .little);
    try expectDecodeError(error.Corrupt, &bmp);
    try expectDecodeError(error.Corrupt, "RIFF\x04\x00\x00\x00WEBP");
    try expectDecodeError(error.Corrupt, "RIFF\xff\xff\xff\x7fWEBPVP8 ");
    try expectDecodeError(error.Corrupt, "RIFF\x16\x00\x00\x00WEBPVP8 \x0a\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\x01\x00");
    try expectDecodeError(error.Corrupt, "RIFF\x16\x00\x00\x00WEBPVP8L\x0a\x00\x00\x00\x2f\x00\x00\x00\x00\x00\x00\x00\x00\x00");
}

test "animation frame delays of 10 ms or less become 100 ms" {
    const alloc = std.testing.allocator;
    const bytes = try readFile(alloc, "gif_anim_disposal.gif");
    defer alloc.free(bytes);
    var img = try image.decode(alloc, bytes);
    defer img.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 100), img.frames[1].delay_ms);
    try std.testing.expectEqual(@as(u32, 50), img.frames[0].delay_ms);
}

fn expectPartial(name: []const u8, keep: usize) !void {
    const alloc = std.testing.allocator;
    const bytes = try readFile(alloc, name);
    defer alloc.free(bytes);
    var img = try image.decode(alloc, bytes[0..keep]);
    defer img.deinit(alloc);
    const f = img.frames[0].rgba;
    var clear: usize = 0;
    var set: usize = 0;
    var px: usize = 0;
    while (px < f.len) : (px += 4) {
        if (f[px + 3] == 0) clear += 1 else set += 1;
    }
    try std.testing.expect(clear > 0 and set > 0);
}

test "a file cut after some pixel rows keeps them and leaves the rest transparent" {
    try expectPartial("png_rgba8.png", 800);
    try expectPartial("png_rgba8_i.png", 1000);
    try expectPartial("gif_static.gif", 150);
    try expectPartial("bmp_rgb32_alpha.bmp", 1200);
}

test "a file cut before any pixel data is an error" {
    const alloc = std.testing.allocator;
    const cuts = [_]struct { name: []const u8, keep: usize }{
        .{ .name = "png_rgb8.png", .keep = 45 },
        .{ .name = "jpeg_420.jpg", .keep = 200 },
        .{ .name = "gif_static.gif", .keep = 40 },
        .{ .name = "bmp_rgb24.bmp", .keep = 60 },
    };
    for (cuts) |c| {
        const bytes = try readFile(alloc, c.name);
        defer alloc.free(bytes);
        try expectDecodeError(error.Corrupt, bytes[0..c.keep]);
    }
}

test "decoded pixels match Chromium read-back references" {
    const alloc = std.testing.allocator;
    const text = try readFile(alloc, "refs.txt");
    defer alloc.free(text);
    var failed = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const name = it.next().?;
        const w = try std.fmt.parseInt(u32, it.next().?, 10);
        const h = try std.fmt.parseInt(u32, it.next().?, 10);
        const tol = try std.fmt.parseInt(u8, it.next().?, 10);
        const bytes = try readFile(alloc, name);
        defer alloc.free(bytes);
        const ref_name = try std.fmt.allocPrint(alloc, "ref/{s}.rgba", .{std.fs.path.stem(name)});
        defer alloc.free(ref_name);
        const ref = try readFile(alloc, ref_name);
        defer alloc.free(ref);
        var img = image.decode(alloc, bytes) catch |err| {
            std.debug.print("{s}: {t}\n", .{ name, err });
            failed = true;
            continue;
        };
        defer img.deinit(alloc);
        if (img.width != w or img.height != h) {
            std.debug.print("{s}: size {d}x{d}, want {d}x{d}\n", .{ name, img.width, img.height, w, h });
            failed = true;
            continue;
        }
        const got = img.frames[0].rgba;
        var worst: u8 = 0;
        var count: usize = 0;
        var first: usize = got.len;
        for (got, ref, 0..) |a, b, i| {
            const d = if (a > b) a - b else b - a;
            if (d > tol) {
                count += 1;
                if (first == got.len) first = i;
            }
            worst = @max(worst, d);
        }
        if (count != 0) {
            std.debug.print("{s}: {d} bytes differ by more than {d} (worst {d}), first at pixel {d} channel {d}\n", .{ name, count, tol, worst, first / 4, first % 4 });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}
