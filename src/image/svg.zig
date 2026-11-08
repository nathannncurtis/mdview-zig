const std = @import("std");
const image = @import("image.zig");
const xml = @import("svg_xml.zig");
const css = @import("svg_css.zig");
const raster = @import("svg_raster.zig");
const sty = @import("svg_style.zig");
const draw = @import("svg_draw.zig");
const anim = @import("svg_anim.zig");

pub const isSvg = xml.isSvg;
pub const setIo = @import("svg_text.zig").setIo;

const Mat = raster.Mat;
const Node = xml.Node;
const Error = image.Error;

pub const max_pixels: u64 = 64 * 1024 * 1024;

fn lenAttr(n: *const Node, name: []const u8) ?sty.Len {
    return sty.parseLen(n.attr(name) orelse return null);
}

fn intrinsicOf(root: *const Node) struct { w: f64, h: f64 } {
    const vb = draw.parseViewBox(root.attr("viewBox"));
    var wa: ?f64 = null;
    var ha: ?f64 = null;
    if (lenAttr(root, "width")) |l| {
        if (l.unit != .pct and l.v > 0) wa = sty.resolveLen(l, .x, .{});
    }
    if (lenAttr(root, "height")) |l| {
        if (l.unit != .pct and l.v > 0) ha = sty.resolveLen(l, .y, .{});
    }
    if (wa != null and ha != null) return .{ .w = wa.?, .h = ha.? };
    if (vb) |v| {
        if (wa) |w| return .{ .w = w, .h = w * v.h / v.w };
        if (ha) |h| return .{ .w = h * v.w / v.h, .h = h };
        return .{ .w = v.w, .h = v.h };
    }
    return .{ .w = wa orelse 300, .h = ha orelse 150 };
}

pub fn intrinsicSize(bytes: []const u8) Error!struct { w: f32, h: f32 } {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = try xml.parseRootTag(arena.allocator(), bytes);
    if (!std.mem.eql(u8, root.tag, "svg")) return error.Corrupt;
    const s = intrinsicOf(root);
    return .{ .w = @floatCast(s.w), .h = @floatCast(s.h) };
}

pub fn render(alloc: std.mem.Allocator, bytes: []const u8, width: u32, height: u32) Error!image.Image {
    return renderNested(alloc, bytes, width, height, 0, 0);
}

pub fn renderAt(alloc: std.mem.Allocator, bytes: []const u8, width: u32, height: u32, t_ms: u64) Error!image.Image {
    return renderNested(alloc, bytes, width, height, 0, @floatFromInt(t_ms));
}

pub fn isAnimated(bytes: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = xml.parse(arena.allocator(), bytes) catch return false;
    return anim.hasSmil(root) or anim.hasCssAnimation(root);
}

fn renderNested(alloc: std.mem.Allocator, bytes: []const u8, width: u32, height: u32, nest: u32, time_ms: f64) Error!image.Image {
    try image.checkDims(width, height);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try xml.parse(arena, bytes);
    if (!std.mem.eql(u8, root.tag, "svg")) return error.Corrupt;

    try anim.applySmil(arena, root, time_ms);
    var r = draw.Renderer.init(alloc, arena);
    defer r.deinit();
    r.nest = nest;
    r.renderNested = renderNested;
    r.time_ms = time_ms;
    r.w = width;
    r.h = height;
    try r.collect(root);
    std.mem.sort(css.Rule, r.rules.items, {}, ruleLess);

    const w: usize = width;
    const h: usize = height;
    var layer = try draw.Layer.init(alloc, w, h);
    errdefer layer.deinit(alloc);
    r.w = w;
    r.h = h;

    const intr = intrinsicOf(root);
    var ctm = Mat.scale(@as(f64, @floatFromInt(width)) / intr.w, @as(f64, @floatFromInt(height)) / intr.h);
    var vw = intr.w;
    var vh = intr.h;
    if (draw.parseViewBox(root.attr("viewBox"))) |vb| {
        ctm = draw.viewBoxMat(vb, draw.parsePar(root.attr("preserveAspectRatio")), @floatFromInt(width), @floatFromInt(height));
        vw = vb.w;
        vh = vb.h;
    }
    var st: draw.State = .{ .ctm = ctm, .style = .{}, .vw = vw, .vh = vh, .target = &layer };
    st.style = try r.computeStyle(root, &st.style, .{ .vw = vw, .vh = vh });
    st.is_root = true;
    if (st.style.transform orelse root.attr("transform")) |t| {
        if (sty.parseTransform(t)) |m| st.ctm = st.ctm.mul(m);
    }
    if (st.style.display) try r.drawWithEffects(root, &st);

    layer.unpremultiply();
    const px = layer.px;
    layer.px = &.{};
    return image.single(alloc, width, height, px);
}

fn ruleLess(_: void, a: css.Rule, b: css.Rule) bool {
    if (a.spec != b.spec) return a.spec < b.spec;
    return a.order < b.order;
}

test {
    _ = @import("svg_xml.zig");
    _ = @import("svg_css.zig");
    _ = @import("svg_raster.zig");
    _ = @import("svg_style.zig");
    _ = @import("svg_shape.zig");
    _ = @import("svg_filter.zig");
    _ = @import("svg_anim.zig");
}

test "render simple" {
    const a = std.testing.allocator;
    const src = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect x='2' y='2' width='6' height='6' fill='#ff0000'/></svg>";
    try std.testing.expect(isSvg(src));
    const sz = try intrinsicSize(src);
    try std.testing.expectEqual(@as(f32, 10), sz.w);
    var img = try render(a, src, 20, 20);
    defer img.deinit(a);
    const px = img.frames[0].rgba;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px[(10 * 20 + 10) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, px[0..4]);
}
