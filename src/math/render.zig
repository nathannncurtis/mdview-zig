const std = @import("std");
const font = @import("font");
const parser = @import("parser.zig");
const layout = @import("layout.zig");
const scene = @import("scene.zig");
const image = @import("../image/image.zig");
const svg = @import("../image/svg.zig");
const images = @import("../image/images.zig");

/// GitHub pads every formula 2px on each side, and a display formula 6px above and below.
pub const pad_x: f32 = 2;
pub const pad_y: f32 = 6;
/// Widest bitmap in device pixels; a wider formula is clipped here and scrolls in its block.
pub const max_px: u32 = 4096;

const text_families = "\"Segoe UI\", \"Noto Sans\", Helvetica, Arial, sans-serif";

/// Where a formula sits in the line: `ascent` above the baseline and `descent` below, in layout units; `w` includes the side padding.
pub const Look = struct { w: f32, ascent: f32, descent: f32 };

pub const Bitmap = struct { native: *anyopaque, w: u32, h: u32 };

const Raster = struct { rgb: u24, native: ?*anyopaque, w: u32, h: u32 };

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    box: layout.Box,
    px_w: f32,
    px_h: f32,
    look: Look,
    rasters: std.ArrayList(Raster) = .empty,
};

var cache: std.StringHashMapUnmanaged(*Entry) = .empty;
var home: ?[]const u8 = null;
var text_fonts: ?layout.TextFonts = null;

pub fn init(home_dir: ?[]const u8) void {
    home = home_dir;
}

pub fn reset() void {
    var it = cache.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr.*;
        if (images.free_native) |f| for (e.rasters.items) |r| if (r.native) |n| f(n);
        e.rasters.deinit(images.gpa);
        images.gpa.free(kv.key_ptr.*);
        var arena = e.arena;
        images.gpa.destroy(e);
        arena.deinit();
    }
    cache.clearAndFree(images.gpa);
}

fn fonts() layout.TextFonts {
    if (text_fonts) |t| return t;
    const t: layout.TextFonts = .{
        .regular = font.resolveFont(images.io, text_families, 400, false),
        .bold = font.resolveFont(images.io, text_families, 700, false),
        .italic = font.resolveFont(images.io, text_families, 400, true),
        .bold_italic = font.resolveFont(images.io, text_families, 700, true),
    };
    text_fonts = t;
    return t;
}

fn keyOf(buf: []u8, src: []const u8, display: bool, size: f32) ?[]u8 {
    return std.fmt.bufPrint(buf, "{d}|{d:.2}|{d:.3}|{s}", .{ @intFromBool(display), size, images.dpi_scale, src }) catch null;
}

fn build(src: []const u8, display: bool, size: f32) ?*Entry {
    const gpa = images.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    const tree = parser.parse(a, src, .{}) catch {
        arena.deinit();
        return null;
    };
    const f = font.mathFont(images.io, home);
    const box = layout.layout(a, &tree, f, .{ .size = size * images.dpi_scale, .display = display, .text_fonts = fonts() }) catch {
        arena.deinit();
        return null;
    };
    const e = gpa.create(Entry) catch {
        arena.deinit();
        return null;
    };
    e.* = .{
        .arena = arena,
        .box = box,
        .px_w = @max(box.w, 1),
        .px_h = @max(box.h + box.d, 1),
        .look = .{ .w = box.w / images.dpi_scale + 2 * pad_x, .ascent = box.h / images.dpi_scale, .descent = box.d / images.dpi_scale },
    };
    return e;
}

fn destroy(e: *Entry) void {
    var arena = e.arena;
    images.gpa.destroy(e);
    arena.deinit();
}

fn entry(src: []const u8, display: bool, size: f32) ?*Entry {
    var buf: [256]u8 = undefined;
    const small = keyOf(&buf, src, display, size);
    if (small) |k| if (cache.get(k)) |e| return e;
    const key = std.fmt.allocPrint(images.gpa, "{d}|{d:.2}|{d:.3}|{s}", .{ @intFromBool(display), size, images.dpi_scale, src }) catch return null;
    if (cache.get(key)) |e| {
        images.gpa.free(key);
        return e;
    }
    const e = build(src, display, size) orelse {
        images.gpa.free(key);
        return null;
    };
    cache.put(images.gpa, key, e) catch {
        images.gpa.free(key);
        destroy(e);
        return null;
    };
    return e;
}

/// How big the formula `src` is at `size` (the font size around it in layout units); null only when it cannot be laid out.
pub fn look(src: []const u8, display: bool, size: f32) ?Look {
    return (entry(src, display, size) orelse return null).look;
}

fn clipHeader(a: std.mem.Allocator, bytes: []const u8, w: u32, h: u32) std.mem.Allocator.Error![]u8 {
    const body = std.mem.indexOf(u8, bytes, "<g fill=") orelse return a.dupe(u8, bytes);
    return std.fmt.allocPrint(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">{s}", .{ w, h, w, h, bytes[body..] });
}

fn rasterize(e: *Entry, rgb: u24) ?Raster {
    const a = images.gpa;
    const bytes = scene.toSvg(a, e.box, rgb) catch return null;
    defer a.free(bytes);
    const w: u32 = @intFromFloat(@ceil(e.px_w));
    const h: u32 = @intFromFloat(@ceil(e.px_h));
    const cw = @min(w, max_px);
    const ch = @min(h, max_px);
    const doc = if (cw < w or ch < h) clipHeader(a, bytes, cw, ch) catch return null else bytes;
    defer if (cw < w or ch < h) a.free(doc);
    var img = svg.render(a, doc, cw, ch) catch return null;
    defer img.deinit(a);
    const create = images.create_native orelse return null;
    const native = create(img.frames[0].rgba, img.width, img.height) orelse return null;
    return .{ .rgb = rgb, .native = native, .w = img.width, .h = img.height };
}

/// The bitmap of the formula drawn in `rgb`, at device size; null when it did not render. It is drawn at `pad_x` from the left edge of its box.
pub fn bitmap(src: []const u8, display: bool, size: f32, rgb: u24) ?Bitmap {
    const e = entry(src, display, size) orelse return null;
    for (e.rasters.items) |r| if (r.rgb == rgb) {
        const n = r.native orelse return null;
        return .{ .native = n, .w = r.w, .h = r.h };
    };
    const r = rasterize(e, rgb) orelse Raster{ .rgb = rgb, .native = null, .w = 0, .h = 0 };
    e.rasters.append(images.gpa, r) catch return null;
    const n = r.native orelse return null;
    return .{ .native = n, .w = r.w, .h = r.h };
}

/// The left edge of a display formula `w` wide in a column `col` wide: centred, or pinned by `scroll` when it is wider.
pub fn displayX(col: f32, w: f32, scroll: f32) f32 {
    if (w <= col) return (col - w) / 2;
    return -std.math.clamp(scroll, 0, w - col);
}

pub fn maxScroll(col: f32, w: f32) f32 {
    return @max(w - col, 0);
}

/// The height a display block takes: the formula and its padding above and below.
pub fn displayHeight(l: Look) f32 {
    return l.ascent + l.descent + 2 * pad_y;
}

const testing = std.testing;

fn setup() void {
    images.init(testing.allocator, testing.io);
    images.dpi_scale = 1;
}

fn teardown() void {
    reset();
}

test "an inline formula sits on its TeX baseline, depth below it" {
    setup();
    defer teardown();
    const x = look("x", false, 16).?;
    const sub = look("x_i", false, 16).?;
    try testing.expect(x.ascent > 0);
    try testing.expect(x.descent < 0.5);
    try testing.expect(sub.descent > x.descent + 1);
    try testing.expect(sub.ascent + sub.descent > x.ascent + x.descent);
    const frac = look("\\frac{a}{b}", false, 16).?;
    try testing.expect(frac.ascent > x.ascent);
    try testing.expect(frac.descent > 1);
}

test "the width carries the side padding and the layout size scales with the font" {
    setup();
    defer teardown();
    const a = look("x", false, 16).?;
    const b = look("x", false, 32).?;
    try testing.expect(a.w > 2 * pad_x);
    try testing.expectApproxEqAbs((a.w - 2 * pad_x) * 2, b.w - 2 * pad_x, 0.5);
    try testing.expectApproxEqAbs(a.ascent * 2, b.ascent, 0.5);
}

test "device scale changes the layout in pixels but not the metrics in layout units" {
    setup();
    defer teardown();
    const one = look("x^2", false, 16).?;
    images.dpi_scale = 2;
    const two = look("x^2", false, 16).?;
    try testing.expectApproxEqAbs(one.ascent, two.ascent, 0.1);
    try testing.expectApproxEqAbs(one.w, two.w, 0.1);
    try testing.expectEqual(@as(usize, 2), cache.count());
}

test "display style makes big operators taller than text style" {
    setup();
    defer teardown();
    const text = look("\\sum_{i=1}^n i", false, 16).?;
    const disp = look("\\sum_{i=1}^n i", true, 16).?;
    try testing.expect(disp.ascent + disp.descent > text.ascent + text.descent);
    try testing.expectApproxEqAbs(disp.ascent + disp.descent + 12, displayHeight(disp), 0.001);
}

test "a broken formula still takes room and an unknown command stays in the formula" {
    setup();
    defer teardown();
    try testing.expect(look("\\frac{1", false, 16).?.w > 2 * pad_x);
    try testing.expect(look("\\undefinedcmd x", false, 16).?.w > look("x", false, 16).?.w);
}

test "a display formula is centred in the column, or scrolled when wider" {
    try testing.expectEqual(@as(f32, 30), displayX(100, 40, 0));
    try testing.expectEqual(@as(f32, 30), displayX(100, 40, 999));
    try testing.expectEqual(@as(f32, 0), displayX(100, 100, 5));
    try testing.expectEqual(@as(f32, 0), displayX(100, 250, 0));
    try testing.expectEqual(@as(f32, -50), displayX(100, 250, 50));
    try testing.expectEqual(@as(f32, -150), displayX(100, 250, 999));
    try testing.expectEqual(@as(f32, 0), displayX(100, 250, -4));
    try testing.expectEqual(@as(f32, 150), maxScroll(100, 250));
    try testing.expectEqual(@as(f32, 0), maxScroll(100, 40));
}

var made: u32 = 0;
var freed: u32 = 0;

fn fakeCreate(_: []const u8, _: u32, _: u32) ?*anyopaque {
    made += 1;
    return @ptrFromInt(0x1000 + made);
}

fn fakeFree(_: ?*anyopaque) void {
    freed += 1;
}

test "bitmaps are cached per colour and freed on reset" {
    setup();
    defer teardown();
    made = 0;
    freed = 0;
    images.create_native = fakeCreate;
    images.free_native = fakeFree;
    defer images.create_native = null;
    defer images.free_native = null;
    const first = bitmap("x^2", false, 16, 0xffffff) orelse return error.SkipZigTest;
    const again = bitmap("x^2", false, 16, 0xffffff).?;
    try testing.expectEqual(first.native, again.native);
    try testing.expectEqual(@as(u32, 1), made);
    _ = bitmap("x^2", false, 16, 0x8b949e).?;
    try testing.expectEqual(@as(u32, 2), made);
    reset();
    try testing.expectEqual(@as(u32, 2), freed);
}
