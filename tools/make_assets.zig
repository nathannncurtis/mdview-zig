const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const files = @import("files.zig");

const Image = struct { w: usize, h: usize, rgba: []u8 };

fn le16(b: []const u8, at: usize) usize {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) usize {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn decodeIco(arena: Allocator, ico: []const u8) !Image {
    if (ico.len < 6 or le16(ico, 0) != 0 or le16(ico, 2) != 1) return error.NotAnIcon;
    var best: ?usize = null;
    var best_w: usize = 0;
    for (0..le16(ico, 4)) |i| {
        const w: usize = if (ico[6 + i * 16] == 0) 256 else ico[6 + i * 16];
        if (w > best_w) {
            best_w = w;
            best = 6 + i * 16;
        }
    }
    const entry = best orelse return error.NotAnIcon;
    const dib = ico[le32(ico, entry + 12)..][0..le32(ico, entry + 8)];
    if (dib.len < 40 or le32(dib, 0) != 40) return error.UnsupportedIconEntry;
    const w = le32(dib, 4);
    const raw_h: i32 = @bitCast(@as(u32, @intCast(le32(dib, 8))));
    const h: usize = @intCast(@divTrunc(raw_h, 2));
    const bpp = le16(dib, 14);
    if (le32(dib, 16) != 0 or (bpp != 32 and bpp != 24)) return error.UnsupportedIconEntry;
    const pixels = dib[40..];
    const px_stride = (w * bpp / 8 + 3) / 4 * 4;
    const mask = pixels[px_stride * h ..];
    const mask_stride = (w + 31) / 32 * 4;
    const rgba = try arena.alloc(u8, w * h * 4);
    for (0..h) |y| {
        const row = pixels[(h - 1 - y) * px_stride ..];
        for (0..w) |x| {
            const o = (y * w + x) * 4;
            const bytes = bpp / 8;
            rgba[o] = row[x * bytes + 2];
            rgba[o + 1] = row[x * bytes + 1];
            rgba[o + 2] = row[x * bytes];
            rgba[o + 3] = if (bpp == 32) row[x * 4 + 3] else blk: {
                const bit = mask[(h - 1 - y) * mask_stride + x / 8] >> @intCast(7 - x % 8) & 1;
                break :blk if (bit == 1) 0 else 255;
            };
        }
    }
    return .{ .w = w, .h = h, .rgba = rgba };
}

fn cubic(x: f32) f32 {
    const a = @abs(x);
    if (a < 1) return 1.5 * a * a * a - 2.5 * a * a + 1;
    if (a < 2) return -0.5 * a * a * a + 2.5 * a * a - 4 * a + 2;
    return 0;
}

const Tap = struct { first: usize, weights: []f32 };

fn taps(arena: Allocator, src: usize, dst: usize) ![]Tap {
    const scale = @as(f32, @floatFromInt(src)) / @as(f32, @floatFromInt(dst));
    const widen = @max(scale, 1);
    const out = try arena.alloc(Tap, dst);
    for (out, 0..) |*t, i| {
        const centre = (@as(f32, @floatFromInt(i)) + 0.5) * scale - 0.5;
        const lo: i64 = @intFromFloat(@floor(centre - 2 * widen));
        const hi: i64 = @intFromFloat(@ceil(centre + 2 * widen));
        const first: i64 = @max(lo, 0);
        const last: i64 = @min(hi, @as(i64, @intCast(src)) - 1);
        const weights = try arena.alloc(f32, @intCast(last - first + 1));
        var sum: f32 = 0;
        for (weights, 0..) |*wt, k| {
            wt.* = cubic((@as(f32, @floatFromInt(first + @as(i64, @intCast(k)))) - centre) / widen);
            sum += wt.*;
        }
        for (weights) |*wt| wt.* /= sum;
        t.* = .{ .first = @intCast(first), .weights = weights };
    }
    return out;
}

fn resize(arena: Allocator, src: Image, size: usize) !Image {
    const premul = try arena.alloc(f32, src.w * src.h * 4);
    for (0..src.w * src.h) |i| {
        const alpha = @as(f32, @floatFromInt(src.rgba[i * 4 + 3])) / 255;
        for (0..3) |c| premul[i * 4 + c] = @as(f32, @floatFromInt(src.rgba[i * 4 + c])) * alpha;
        premul[i * 4 + 3] = alpha * 255;
    }
    const xt = try taps(arena, src.w, size);
    const yt = try taps(arena, src.h, size);
    const mid = try arena.alloc(f32, size * src.h * 4);
    for (0..src.h) |y| for (0..size) |x| for (0..4) |c| {
        var acc: f32 = 0;
        for (xt[x].weights, 0..) |wt, k| acc += wt * premul[(y * src.w + xt[x].first + k) * 4 + c];
        mid[(y * size + x) * 4 + c] = acc;
    };
    const out = try arena.alloc(u8, size * size * 4);
    for (0..size) |y| for (0..size) |x| {
        var acc: [4]f32 = @splat(0);
        for (yt[y].weights, 0..) |wt, k| for (0..4) |c| {
            acc[c] += wt * mid[((yt[y].first + k) * size + x) * 4 + c];
        };
        const alpha = std.math.clamp(acc[3], 0, 255);
        for (0..3) |c| {
            const v = if (alpha > 0) acc[c] * 255 / alpha else 0;
            out[(y * size + x) * 4 + c] = @intFromFloat(@round(std.math.clamp(v, 0, 255)));
        }
        out[(y * size + x) * 4 + 3] = @intFromFloat(@round(alpha));
    };
    return .{ .w = size, .h = size, .rgba = out };
}

fn chunk(w: *Writer, kind: *const [4]u8, data: []const u8) !void {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

fn encodePng(arena: Allocator, img: Image) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..img.h) |y| {
        try raw.append(arena, 0);
        try raw.appendSlice(arena, img.rgba[y * img.w * 4 ..][0 .. img.w * 4]);
    }
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var drain = try Writer.Allocating.initCapacity(arena, 4096);
    var compress = try std.compress.flate.Compress.init(&drain.writer, &window, .zlib, .default);
    try compress.writer.writeAll(raw.items);
    try compress.finish();

    var png: Writer.Allocating = .init(arena);
    const w = &png.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(img.w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(img.h), .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", drain.written());
    try chunk(w, "IEND", "");
    return png.written();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    if (all.len != 1 and all.len != 3) {
        std.debug.print("usage: msix-assets [<icon.ico> <out dir>]\n", .{});
        return error.Usage;
    }
    const icon = if (all.len == 3) all[1] else "icon.ico";
    const out_dir = if (all.len == 3) all[2] else "msix/Assets";
    const src = try decodeIco(arena, try files.read(init.io, arena, icon));
    try std.Io.Dir.cwd().createDirPath(init.io, out_dir);

    const Asset = struct { size: usize, name: []const u8 };
    var assets: std.ArrayList(Asset) = .empty;
    try assets.appendSlice(arena, &.{
        .{ .size = 50, .name = "StoreLogo.png" },
        .{ .size = 150, .name = "Square150x150Logo.png" },
        .{ .size = 44, .name = "Square44x44Logo.png" },
    });
    for ([_]usize{ 16, 24, 32, 48, 256 }) |s| {
        for ([_][]const u8{ "unplated", "lightunplated" }) |form| {
            try assets.append(arena, .{ .size = s, .name = try std.fmt.allocPrint(arena, "Square44x44Logo.targetsize-{d}_altform-{s}.png", .{ s, form }) });
        }
    }
    for (assets.items) |asset| {
        const png = try encodePng(arena, try resize(arena, src, asset.size));
        try files.write(init.io, try std.fs.path.join(arena, &.{ out_dir, asset.name }), png);
        std.debug.print("{s} {d}x{d}\n", .{ asset.name, asset.size, asset.size });
    }
}
