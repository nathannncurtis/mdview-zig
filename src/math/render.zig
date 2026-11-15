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
/// Widest bitmap in device pixels; a wider formula is drawn as tiles this wide.
pub const max_px: u32 = 4096;
pub const max_tiles = 16;

const text_families = "\"Segoe UI\", \"Noto Sans\", Helvetica, Arial, sans-serif";

/// Where a formula sits in the line: `ascent` above the baseline and `descent` below, in layout units; `w` includes the side padding.
pub const Look = struct { w: f32, ascent: f32, descent: f32 };

/// One tile of a formula's bitmap: `x` and `w` place it, in layout units, from the left edge of the bitmap (which is `pad_x` in from the box).
pub const Piece = struct { native: *anyopaque, px_w: u32, px_h: u32, x: f32, w: f32 };

const Raster = struct { rgb: u24, tile: u8, native: ?*anyopaque, w: u32, h: u32 };

var raster_fn: *const fn (std.mem.Allocator, []const u8, u32, u32) image.Error!image.Image = svg.render;
var errors: std.StringHashMapUnmanaged(void) = .empty;

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
    var bad = errors.keyIterator();
    while (bad.next()) |k| images.gpa.free(k.*);
    errors.clearAndFree(images.gpa);
}

/// True when `src` is a TeX error, which MathJax shows as its message; the source is the tooltip.
pub fn failed(src: []const u8) bool {
    return errors.contains(src);
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
    if (tree.err != null and !errors.contains(src)) {
        if (images.gpa.dupe(u8, src)) |own| errors.put(images.gpa, own, {}) catch images.gpa.free(own) else |_| {}
    }
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

fn clipHeader(a: std.mem.Allocator, bytes: []const u8, x0: u32, w: u32, h: u32) std.mem.Allocator.Error![]u8 {
    const body = std.mem.indexOf(u8, bytes, "<g fill=") orelse return a.dupe(u8, bytes);
    return std.fmt.allocPrint(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"{d} 0 {d} {d}\">{s}", .{ w, h, x0, w, h, bytes[body..] });
}

fn rasterize(e: *Entry, rgb: u24, tile: u8) ?Raster {
    const a = images.gpa;
    const w: u32 = @intFromFloat(@ceil(e.px_w));
    const full_h: u32 = @intFromFloat(@ceil(e.px_h));
    const h = @min(full_h, max_px);
    const x0 = @as(u32, tile) * max_px;
    if (x0 >= w) return null;
    const cw = @min(max_px, w - x0);
    const bytes = scene.toSvg(a, e.box, rgb) catch return null;
    defer a.free(bytes);
    const whole = x0 == 0 and cw == w and h == full_h;
    const doc = if (whole) bytes else clipHeader(a, bytes, x0, cw, h) catch return null;
    defer if (!whole) a.free(doc);
    var img = raster_fn(a, doc, cw, h) catch return null;
    defer img.deinit(a);
    const create = images.create_native orelse return null;
    const native = create(img.frames[0].rgba, img.width, img.height) orelse return null;
    return .{ .rgb = rgb, .tile = tile, .native = native, .w = img.width, .h = img.height };
}

/// The tiles of the formula drawn in `rgb` that overlap `from..to` (layout units from the left edge of its bitmap), at device size.
pub fn pieces(src: []const u8, display: bool, size: f32, rgb: u24, from: f32, to: f32, out: *[max_tiles]Piece) []const Piece {
    const e = entry(src, display, size) orelse return out[0..0];
    const w: u32 = @intFromFloat(@ceil(e.px_w));
    const per_px = (e.box.w / images.dpi_scale) / @as(f32, @floatFromInt(w));
    const tiles = @min((w + max_px - 1) / max_px, max_tiles);
    var n: usize = 0;
    for (0..tiles) |t| {
        const x = @as(f32, @floatFromInt(t * max_px)) * per_px;
        const tw = @as(f32, @floatFromInt(@min(max_px, w - @as(u32, @intCast(t)) * max_px))) * per_px;
        if (x + tw <= from or x >= to) continue;
        const r = for (e.rasters.items) |r| {
            if (r.rgb == rgb and r.tile == t) break r;
        } else blk: {
            const fresh = rasterize(e, rgb, @intCast(t)) orelse Raster{ .rgb = rgb, .tile = @intCast(t), .native = null, .w = 0, .h = 0 };
            e.rasters.append(images.gpa, fresh) catch continue;
            break :blk fresh;
        };
        out[n] = .{ .native = r.native orelse continue, .px_w = r.w, .px_h = r.h, .x = x, .w = tw };
        n += 1;
    }
    return out[0..n];
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

fn fakeRaster(a: std.mem.Allocator, _: []const u8, w: u32, h: u32) image.Error!image.Image {
    const frames = try a.alloc(image.Frame, 1);
    errdefer a.free(frames);
    frames[0] = .{ .rgba = try a.alloc(u8, w * h * 4), .delay_ms = 0 };
    return .{ .width = w, .height = h, .frames = frames, .loop_count = 0 };
}

fn fakes() void {
    images.create_native = fakeCreate;
    images.free_native = fakeFree;
    raster_fn = fakeRaster;
    made = 0;
    freed = 0;
}

fn unfake() void {
    images.create_native = null;
    images.free_native = null;
    raster_fn = svg.render;
}

test "tiles are cached per colour and freed on reset" {
    setup();
    defer teardown();
    fakes();
    defer unfake();
    var out: [max_tiles]Piece = undefined;
    const first = pieces("x^2", false, 16, 0xffffff, 0, 1000, &out);
    try testing.expectEqual(@as(usize, 1), first.len);
    const native = first[0].native;
    try testing.expectEqual(native, pieces("x^2", false, 16, 0xffffff, 0, 1000, &out)[0].native);
    try testing.expectEqual(@as(u32, 1), made);
    _ = pieces("x^2", false, 16, 0x8b949e, 0, 1000, &out);
    try testing.expectEqual(@as(u32, 2), made);
    reset();
    try testing.expectEqual(@as(u32, 2), freed);
}

test "a formula wider than a tile is drawn in tiles, only those in view" {
    setup();
    defer teardown();
    fakes();
    defer unfake();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..1500) |_| try src.appendSlice(testing.allocator, "x+");
    try src.append(testing.allocator, 'x');
    const l = look(src.items, false, 16).?;
    try testing.expect(l.w > @as(f32, max_px) * 2);
    var out: [max_tiles]Piece = undefined;
    const all = pieces(src.items, false, 16, 0xffffff, 0, l.w, &out);
    try testing.expect(all.len >= 3);
    for (all[0 .. all.len - 1], all[1..]) |a, b| try testing.expectApproxEqAbs(a.x + a.w, b.x, 0.01);
    try testing.expect(all[0].px_w == max_px);
    const made_all = made;
    const one = pieces(src.items, false, 16, 0xffffff, 10, 50, &out);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(made_all, made);
}

test "a broken formula is listed as failed, a good one is not" {
    setup();
    defer teardown();
    _ = look("\\frac{1", false, 16);
    _ = look("x", false, 16);
    try testing.expect(failed("\\frac{1"));
    try testing.expect(!failed("x"));
}
