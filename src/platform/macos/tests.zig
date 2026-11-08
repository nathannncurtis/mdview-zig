const std = @import("std");
const app = @import("../../main.zig");
const mac = @import("macos.zig");
const html = @import("html.zig");
const tables = @import("tables.zig");
const testing = std.testing;
const md = app.md;
const c = @import("c");

const CGFloat = mac.CGFloat;
const CGPoint = mac.CGPoint;
const cgRect = mac.cgRect;
const cfInt32 = mac.cfInt32;
const createFont = mac.createFont;
const createRichAttrStr = mac.createRichAttrStr;
const createAlignedAttrStr = mac.createAlignedAttrStr;
const suggestSize = mac.suggestSize;
const makeFonts = mac.makeFonts;
const releaseFonts = mac.releaseFonts;
const layoutBlocks = mac.layoutBlocks;
const imageBox = mac.imageBox;
const resetBoxes = mac.resetBoxes;
const text_color = mac.text_color;
const font_size_body = mac.font_size_body;
const cell_pad_x = mac.cell_pad_x;
const g_height = &mac.g_height;
const collectBoxes = html.collectBoxes;
const Box = html.Box;
const BoxKind = html.BoxKind;
const kbd_height = html.kbd_height;
const kbd_pad = html.kbd_pad;
const drawTable = tables.drawTable;
const cellNaturalWidth = tables.cellNaturalWidth;


const Canvas = struct {
    ctx: c.CGContextRef,
    data: []u8,

    fn init(w: usize, h: usize) !Canvas {
        app.gpa = std.heap.page_allocator;
        app.images.init(testing.allocator, testing.io);
        app.images.reset("", false);
        const data = try testing.allocator.alloc(u8, w * h * 4);
        errdefer testing.allocator.free(data);
        @memset(data, 0);
        const space = c.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
        defer c.CGColorSpaceRelease(space);
        const ctx = c.CGBitmapContextCreate(data.ptr, w, h, 8, w * 4, space, c.kCGImageAlphaPremultipliedLast) orelse return error.NoContext;
        g_height.* = @floatFromInt(h);
        app.beginFrame();
        return .{ .ctx = ctx, .data = data };
    }

    fn deinit(self: Canvas) void {
        c.CGContextRelease(self.ctx);
        testing.allocator.free(self.data);
        resetBoxes();
        html.resetSlices();
        app.images.clearAll();
        app.hits.clearRetainingCapacity();
        app.details_open.clearRetainingCapacity();
    }
};

const TestFrame = struct {
    framesetter: c.CTFramesetterRef,
    frame: c.CTFrameRef,
    height: CGFloat,

    fn init(attr_str: c.CFMutableAttributedStringRef, w: CGFloat) TestFrame {
        const framesetter = c.CTFramesetterCreateWithAttributedString(@ptrCast(attr_str));
        const height = suggestSize(@ptrCast(attr_str), w).height;
        const path = c.CGPathCreateMutable();
        defer c.CGPathRelease(path);
        c.CGPathAddRect(path, null, cgRect(0, 0, w, height));
        const frame = c.CTFramesetterCreateFrame(framesetter, c.CFRange{ .location = 0, .length = 0 }, path, null);
        return .{ .framesetter = framesetter, .frame = frame, .height = height };
    }

    fn deinit(self: TestFrame) void {
        c.CFRelease(self.frame);
        c.CFRelease(self.framesetter);
    }

    fn line(self: TestFrame, index: usize) c.CTLineRef {
        return @ptrCast(@constCast(c.CFArrayGetValueAtIndex(c.CTFrameGetLines(self.frame), @intCast(index))));
    }

    fn origin(self: TestFrame, index: usize) CGPoint {
        var points: [8]CGPoint = undefined;
        c.CTFrameGetLineOrigins(self.frame, c.CFRange{ .location = 0, .length = 0 }, &points);
        return points[index];
    }
};

fn attrValue(attr_str: c.CFMutableAttributedStringRef, index: usize, key: c.CFStringRef) ?*const anyopaque {
    return c.CFAttributedStringGetAttribute(@ptrCast(attr_str), @intCast(index), key, null);
}

fn testLink(start: u32, len: u32) md.Link {
    return .{ .start = start, .len = len, .target = "https://example.test/" };
}

const lorem = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega ";

test "center and right alignment move a line within its frame" {
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    for ([_]md.Align{ .center, .right }) |kind| {
        const attr_str = createAlignedAttrStr(.{ .text = "hi" }, kind, font, 400) orelse return error.NoString;
        defer c.CFRelease(attr_str);
        const f = TestFrame.init(attr_str, 400);
        defer f.deinit();
        const width = c.CTLineGetTypographicBounds(f.line(0), null, null, null);
        const want = if (kind == .center) (400 - width) / 2 else 400 - width;
        try testing.expectApproxEqAbs(want, f.origin(0).x, 1);
    }
}

test "a kbd span gets a bordered box wider than its text" {
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    const content: md.Inline = .{ .text = "a kbd b", .styles = &.{.{ .span = .{ 2, 3 }, .kind = .kbd }} };
    const attr_str = createRichAttrStr(content, font, text_color, 400) orelse return error.NoString;
    defer c.CFRelease(attr_str);
    const f = TestFrame.init(attr_str, 400);
    defer f.deinit();
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(testing.allocator);
    app.gpa = testing.allocator;
    collectBoxes(f.frame, 0, 0, &boxes);
    try testing.expectEqual(@as(usize, 1), boxes.items.len);
    try testing.expectEqual(BoxKind.kbd, boxes.items[0].kind);
    try testing.expectEqual(kbd_height, boxes.items[0].rect.size.height);
    const text_w = c.CTLineGetOffsetForStringIndex(f.line(0), 5, null) - c.CTLineGetOffsetForStringIndex(f.line(0), 2, null);
    try testing.expectApproxEqAbs(text_w + kbd_pad + 1, boxes.items[0].rect.size.width, 0.5);
}

test "a mark span gets a highlight as wide as its text and as tall as the line" {
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    const content: md.Inline = .{ .text = "a mark b", .styles = &.{.{ .span = .{ 2, 4 }, .kind = .mark }} };
    const attr_str = createRichAttrStr(content, font, text_color, 400) orelse return error.NoString;
    defer c.CFRelease(attr_str);
    const f = TestFrame.init(attr_str, 400);
    defer f.deinit();
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(testing.allocator);
    app.gpa = testing.allocator;
    collectBoxes(f.frame, 0, 0, &boxes);
    try testing.expectEqual(@as(usize, 1), boxes.items.len);
    try testing.expectEqual(BoxKind.mark, boxes.items[0].kind);
    const text_w = c.CTLineGetOffsetForStringIndex(f.line(0), 6, null) - c.CTLineGetOffsetForStringIndex(f.line(0), 2, null);
    try testing.expectApproxEqAbs(text_w, boxes.items[0].rect.size.width, 0.5);
    try testing.expect(boxes.items[0].rect.size.height > 12);
}

test "a sub span is smaller and sits below the baseline" {
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    const content: md.Inline = .{ .text = "ab", .styles = &.{.{ .span = .{ 1, 1 }, .kind = .sub }} };
    const attr_str = createRichAttrStr(content, font, text_color, 400) orelse return error.NoString;
    defer c.CFRelease(attr_str);
    try testing.expect(attrValue(attr_str, 0, c.kCTBaselineOffsetAttributeName) == null);
    try testing.expect(attrValue(attr_str, 1, c.kCTBaselineOffsetAttributeName) != null);
    const f = TestFrame.init(attr_str, 400);
    defer f.deinit();
    const runs = c.CTLineGetGlyphRuns(f.line(0));
    var lowest: CGFloat = 0;
    var smallest: CGFloat = font_size_body;
    for (0..@as(usize, @intCast(c.CFArrayGetCount(runs)))) |i| {
        const glyph_run: c.CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(runs, @intCast(i))));
        var at = CGPoint{ .x = 0, .y = 0 };
        c.CTRunGetPositions(glyph_run, c.CFRange{ .location = 0, .length = 1 }, &at);
        lowest = @min(lowest, at.y);
        const font_value = c.CFDictionaryGetValue(c.CTRunGetAttributes(glyph_run), c.kCTFontAttributeName).?;
        smallest = @min(smallest, c.CTFontGetSize(@ptrCast(@constCast(font_value))));
    }
    try testing.expect(lowest < -1);
    try testing.expectApproxEqAbs(font_size_body * 0.75, smallest, 0.01);
}

test "an underline span is underlined" {
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    const content: md.Inline = .{ .text = "a b c", .styles = &.{ .{ .span = .{ 0, 1 }, .kind = .underline } } };
    const attr_str = createRichAttrStr(content, font, text_color, 400) orelse return error.NoString;
    defer c.CFRelease(attr_str);
    try testing.expectEqual(@as(i32, c.kCTUnderlineStyleSingle), cfInt32(attrValue(attr_str, 0, c.kCTUnderlineStyleAttributeName).?));
    try testing.expect(attrValue(attr_str, 2, c.kCTUnderlineStyleAttributeName) == null);
}

test "dd blocks are inset and dt blocks are not" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    const content: md.Inline = .{ .text = "term", .links = &.{testLink(0, 4)} };
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = content, .frames = &.{.{ .kind = .dd }} },
        .{ .kind = .paragraph, .content = content, .role = .dt },
    };
    _ = layoutBlocks(canvas.ctx, &list, 40, 600, 10, fonts, false);
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    try testing.expectEqual(@as(f32, 40 + md.dd_inset), app.hits.items[0].x);
    try testing.expectEqual(@as(f32, 40), app.hits.items[1].x);
    try testing.expect(app.hits.items[1].italic and !app.hits.items[0].italic);
}

test "img width and height set the box size and are capped to the line" {
    var canvas = try Canvas.init(10, 10);
    defer canvas.deinit();
    try app.images.injectReady("pic.png", 1000, 500);
    var im: md.Image = .{ .start = 0, .len = 3, .target = "pic.png", .width = 200 };
    const by_width = imageBox(&im, 600, false) orelse return error.NoBox;
    try testing.expectEqual(@as(CGFloat, 200), by_width.w);
    try testing.expectEqual(@as(CGFloat, 100), by_width.h);
    im.width = 0;
    im.height = 50;
    const by_height = imageBox(&im, 600, false) orelse return error.NoBox;
    try testing.expectEqual(@as(CGFloat, 100), by_height.w);
    im.width = 2000;
    im.height = 0;
    const capped = imageBox(&im, 600, false) orelse return error.NoBox;
    try testing.expectEqual(@as(CGFloat, 600), capped.w);
    try testing.expectEqual(@as(CGFloat, 300), capped.h);
}

fn spanTable(ext: ?*const md.Table.Extra) md.Table {
    return .{
        .columns = 2,
        .aligns = &.{ .none, .none },
        .header_row = false,
        .cells = &.{ .{ .text = "a heading cell that is wide" }, .{ .text = "b" }, .{ .text = "c" }, .{ .text = "d" } },
        .ext = ext,
    };
}

test "a colspan cell shares its width between its columns" {
    var canvas = try Canvas.init(10, 10);
    defer canvas.deinit();
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    var spanned: CGFloat = 0;
    var plain: CGFloat = 0;
    _ = drawTable(canvas.ctx, spanTable(&.{ .spans = &.{ .{ 2, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 1 } } }), 0, 600, 1000, font, false, &spanned);
    _ = drawTable(canvas.ctx, spanTable(null), 0, 600, 1000, font, false, &plain);
    const natural = cellNaturalWidth(canvas.ctx, spanTable(null), 0, 0, font, font) + cell_pad_x * 2 + 1;
    try testing.expectApproxEqAbs(natural, spanned, 1);
    try testing.expect(plain > spanned + 10);
}

test "a rowspan cell covers the rows under it" {
    var canvas = try Canvas.init(10, 10);
    defer canvas.deinit();
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    var t = spanTable(&.{ .spans = &.{ .{ 1, 2 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 } } });
    t.cells = &.{ .{ .text = "1\n2\n3\n4\n5" }, .{ .text = "b" }, .{ .text = "c" }, .{ .text = "d" } };
    const spanned = drawTable(canvas.ctx, t, 0, 600, 400, font, false, null);
    t.ext = null;
    const plain = drawTable(canvas.ctx, t, 0, 600, 400, font, false, null);
    try testing.expect(plain - spanned > 20);
}

test "valign places the text of a cell in a tall row, middle by default" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    var t: md.Table = .{
        .columns = 2,
        .aligns = &.{ .none, .none },
        .header_row = false,
        .cells = &.{ .{ .text = "1\n2\n3\n4" }, .{ .text = "x", .links = &.{testLink(0, 1)} } },
    };
    var ys: [3]f32 = undefined;
    for ([_]?*const md.Table.Extra{ &.{ .valigns = &.{ .top, .top } }, null, &.{ .valigns = &.{ .bottom, .bottom } } }, 0..) |ext, i| {
        app.hits.clearRetainingCapacity();
        t.ext = ext;
        _ = drawTable(canvas.ctx, t, 0, 600, 400, font, true, null);
        ys[i] = app.hits.items[0].y;
    }
    try testing.expect(ys[1] > ys[0] + 15);
    try testing.expect(ys[2] > ys[1] + 15);
    try testing.expectApproxEqAbs(ys[1] - ys[0], ys[2] - ys[1], 1);
}

test "a closed details hides its content until its summary is clicked" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    const frames = [_]md.Frame{.{ .kind = .details, .key = 7 }};
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "Summary" }, .frames = &frames, .role = .summary },
        .{ .kind = .paragraph, .content = .{ .text = "Hidden body" }, .frames = &frames },
    };
    const closed = layoutBlocks(canvas.ctx, &list, 40, 600, 10, fonts, false);
    try testing.expect(closed < 10 + 40);
    try testing.expect(app.mouseDown(60, 15));
    app.beginFrame();
    const open = layoutBlocks(canvas.ctx, &list, 40, 600, 10, fonts, false);
    try testing.expect(open > closed + 15);
}

test "a floated image narrows the text beside it" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const images = [_]md.Image{.{ .start = 0, .len = 3, .target = "logo.png", .width = 100, .float = .left }};
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = &images } },
        .{ .kind = .paragraph, .content = .{ .text = "beside", .links = &.{testLink(0, 6)} } },
        .{ .kind = .paragraph, .content = .{ .text = lorem ++ lorem ++ lorem ++ lorem } },
        .{ .kind = .paragraph, .content = .{ .text = "far below", .links = &.{testLink(0, 9)} } },
    };
    const end = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    try testing.expectEqual(@as(f32, 40 + 100 + md.float_gap), app.hits.items[0].x);
    try testing.expectEqual(@as(f32, 400 - 100 - md.float_gap), app.hits.items[0].w);
    try testing.expectEqual(@as(f32, 40), app.hits.items[1].x);
    try testing.expect(end >= 10 + 100);
}

test "a paragraph that passes the bottom of a float continues at the full width" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const images = [_]md.Image{.{ .start = 0, .len = 3, .target = "logo.png", .width = 100, .float = .right }};
    const text = lorem ++ lorem ++ lorem ++ lorem ++ lorem ++ lorem;
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = &images } },
        .{ .kind = .paragraph, .content = .{ .text = text, .links = &.{testLink(0, 5)} } },
    };
    const narrow = 400 - 100 - md.float_gap;
    const end = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    const whole_attr = createRichAttrStr(.{ .text = text }, fonts.body, text_color, narrow) orelse return error.NoString;
    defer c.CFRelease(whole_attr);
    const whole_narrow = suggestSize(@ptrCast(whole_attr), narrow).height;
    try testing.expectEqual(@as(usize, 1), app.hits.items.len);
    const hit = app.hits.items[0];
    try testing.expectEqual(@as(f32, narrow), hit.w);
    try testing.expect(hit.h >= 95 and hit.h <= 140);
    try testing.expect(hit.h < whole_narrow - 50);
    try testing.expect(end < 10 + whole_narrow);
}

test "a table cell lays out its own blocks" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    const blocks = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "first", .links = &.{testLink(0, 5)} } },
        .{ .kind = .paragraph, .content = .{ .text = "second", .links = &.{testLink(0, 6)} } },
    };
    const t: md.Table = .{
        .columns = 1,
        .aligns = &.{.none},
        .header_row = false,
        .cells = &.{.{ .text = "" }},
        .ext = &.{ .cell_blocks = &.{&blocks} },
    };
    const height = drawTable(canvas.ctx, t, 0, 600, 400, font, true, null);
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    try testing.expectEqual(@as(f32, cell_pad_x), app.hits.items[0].x);
    try testing.expect(app.hits.items[1].y > app.hits.items[0].y + 30);
    try testing.expect(height > 2 * 19 + 16);
}

test "floats on both sides narrow the text from both" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const left = [_]md.Image{.{ .start = 0, .len = 3, .target = "logo.png", .width = 100, .float = .left }};
    const right = [_]md.Image{.{ .start = 0, .len = 3, .target = "logo.png", .width = 80, .float = .right }};
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = &left } },
        .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = &right } },
        .{ .kind = .paragraph, .content = .{ .text = "between", .links = &.{testLink(0, 7)} } },
    };
    _ = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    try testing.expectEqual(@as(usize, 1), app.hits.items.len);
    try testing.expectEqual(@as(f32, 40 + 100 + md.float_gap), app.hits.items[0].x);
    try testing.expectEqual(@as(f32, 400 - 100 - 80 - 2 * md.float_gap), app.hits.items[0].w);
}


test "a link in the text below a float is clickable" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const images = [_]md.Image{.{ .start = 0, .len = 3, .target = "logo.png", .width = 100, .float = .right }};
    const text = lorem ++ lorem ++ lorem ++ lorem ++ lorem ++ lorem ++ "tail";
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = &images } },
        .{ .kind = .paragraph, .content = .{ .text = text, .links = &.{testLink(text.len - 4, 4)} } },
    };
    _ = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    try testing.expect(app.hits.items.len >= 2);
    const last = app.hits.items[app.hits.items.len - 1];
    try testing.expectEqual(@as(f32, 40), last.x);
    try testing.expectEqual(@as(f32, 400), last.w);
    try testing.expectEqualStrings("tail", last.content.text[last.content.links[0].start..][0..last.content.links[0].len]);
    const index = mac.textIndexAt(last, 1, 5) orelse return error.NoIndex;
    try testing.expect(index < last.content.text.len);
}

test "a floated image inside a link is clickable" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const images = [_]md.Image{.{ .start = 0, .len = 3, .target = "logo.png", .width = 100, .float = .right }};
    const list = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = &images, .links = &.{testLink(0, 3)} } },
    };
    _ = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    try testing.expectEqual(@as(usize, 1), app.hits.items.len);
    const hit = app.hits.items[0];
    try testing.expectEqual(@as(f32, 40 + 400 - 100), hit.x);
    try testing.expectEqual(@as(f32, 100), hit.w);
    const index = mac.textIndexAt(hit, 50, 50) orelse return error.NoIndex;
    try testing.expect(hit.content.linkAt(index) != null);
}

test "an empty block takes no height and keeps the usual gap" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    const list = [_]md.Block{.{ .kind = .paragraph, .role = .empty }};
    try testing.expectEqual(@as(CGFloat, 10 + mac.para_spacing), layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, false));
}

test "break lines take one tall line per break and no gap" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    const list = [_]md.Block{.{ .kind = .paragraph, .role = .break_lines, .content = .{ .text = "\n\n\n" } }};
    try testing.expectEqual(@as(CGFloat, 10 + 3 * html.break_line_height), layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, false));
}

fn linkedFloats(width: f32, images: *[2]md.Image, blocks: *[2]md.Block, linked: *const [1]md.Link) void {
    for (images) |*im| im.* = .{ .start = 0, .len = 3, .target = "logo.png", .width = width, .float = .left };
    for (blocks, images) |*b, *im| b.* = .{ .kind = .paragraph, .content = .{ .text = "\u{FFFC}", .images = im[0..1], .links = linked } };
}

test "a second float on a side goes beside the first when it fits" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const linked = [_]md.Link{testLink(0, 3)};
    var images: [2]md.Image = undefined;
    var list: [2]md.Block = undefined;
    linkedFloats(100, &images, &list, &linked);
    _ = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    try testing.expectEqual(@as(f32, 40), app.hits.items[0].x);
    try testing.expectEqual(@as(f32, 40 + 100 + md.float_gap), app.hits.items[1].x);
    try testing.expectEqual(app.hits.items[0].y, app.hits.items[1].y);
}

test "a second float on a side goes below the first when it does not fit" {
    var canvas = try Canvas.init(800, 600);
    defer canvas.deinit();
    const fonts = makeFonts();
    defer releaseFonts(fonts);
    try app.images.injectReady("logo.png", 200, 200);
    const linked = [_]md.Link{testLink(0, 3)};
    var images: [2]md.Image = undefined;
    var list: [2]md.Block = undefined;
    linkedFloats(250, &images, &list, &linked);
    _ = layoutBlocks(canvas.ctx, &list, 40, 400, 10, fonts, true);
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    try testing.expectEqual(@as(f32, 40), app.hits.items[1].x);
    try testing.expectApproxEqAbs(app.hits.items[0].y + 250, app.hits.items[1].y, 0.5);
}

test "float bands past the cap clear the list instead of dropping the new one" {
    var bands: html.Bands = .{};
    for (0..html.max_bands + 1) |i| bands.add(.{ .right = false, .w = 10, .top = @floatFromInt(i), .bottom = 1000 });
    try testing.expectEqual(@as(usize, 1), bands.n);
    try testing.expectEqual(@as(CGFloat, html.max_bands), bands.items[0].top);
}
