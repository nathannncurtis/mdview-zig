// macOS backend — Cocoa (AppKit) + CoreText + CoreGraphics via Objective-C runtime
const std = @import("std");
const app = @import("../../main.zig");
const md = app.md;
const hl = @import("../../markdown/highlight.zig");
const alerts = @import("../../markdown/alerts.zig");
const html = @import("html.zig");
const tables = @import("tables.zig");
const c = @import("c");

// ============================================================
// ObjC runtime helpers — cast objc_msgSend per call-site
// ============================================================
const id = ?*anyopaque;
const SEL = c.SEL;
const BOOL = i8;
pub const CGFloat = f64;
const NSUInteger = u64;

pub const CGPoint = c.CGPoint;
const CGSize = c.CGSize;
pub const CGRect = c.CGRect;

pub fn cgRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

// Typed objc_msgSend wrappers
const MsgSendFn = *const fn (id, SEL) callconv(.c) id;
const msgSend_id: MsgSendFn = @ptrCast(&c.objc_msgSend);

const msgSend_void_id: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&c.objc_msgSend);
const msgSend_void_bool: *const fn (id, SEL, BOOL) callconv(.c) void = @ptrCast(&c.objc_msgSend);
const msgSend_void_i64: *const fn (id, SEL, i64) callconv(.c) void = @ptrCast(&c.objc_msgSend);
const msgSend_void: *const fn (id, SEL) callconv(.c) void = @ptrCast(&c.objc_msgSend);
const msgSend_u16: *const fn (id, SEL) callconv(.c) u16 = @ptrCast(&c.objc_msgSend);
const msgSend_i64: *const fn (id, SEL) callconv(.c) i64 = @ptrCast(&c.objc_msgSend);
const msgSend_u64: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(&c.objc_msgSend);
const msgSend_cgfloat: *const fn (id, SEL) callconv(.c) CGFloat = @ptrCast(&c.objc_msgSend);
const msgSend_id_id: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&c.objc_msgSend);

// initWithContentRect:styleMask:backing:defer:
const msgSend_initWindow: *const fn (id, SEL, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.c) id = @ptrCast(&c.objc_msgSend);
// initWithFrame:
const msgSend_initFrame: *const fn (id, SEL, CGRect) callconv(.c) id = @ptrCast(&c.objc_msgSend);
// colorWithRed:green:blue:alpha:
const msgSend_color4: *const fn (id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) id = @ptrCast(&c.objc_msgSend);
// scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:
const msgSend_timer: *const fn (id, SEL, f64, id, SEL, id, BOOL) callconv(.c) id = @ptrCast(&c.objc_msgSend);
// convertPoint:fromView:
const msgSend_convertPoint: *const fn (id, SEL, CGPoint, id) callconv(.c) CGPoint = @ptrCast(&c.objc_msgSend);
// CGContext (returned as pointer)
const msgSend_ctx: *const fn (id, SEL) callconv(.c) c.CGContextRef = @ptrCast(&c.objc_msgSend);

// For struct returns: on arm64 all go through objc_msgSend, on x86_64 large structs need objc_msgSend_stret
const builtin_info = @import("builtin");
const msgSend_rect = if (builtin_info.cpu.arch == .x86_64)
    @as(*const fn (id, SEL) callconv(.c) CGRect, @ptrCast(@extern(*const anyopaque, .{ .name = "objc_msgSend_stret" })))
else
    @as(*const fn (id, SEL) callconv(.c) CGRect, @ptrCast(&c.objc_msgSend));

const msgSend_point: *const fn (id, SEL) callconv(.c) CGPoint = @ptrCast(&c.objc_msgSend);

fn objcClass(name: [*:0]const u8) id {
    return c.objc_getClass(name);
}

fn sel(name: [*:0]const u8) SEL {
    return c.sel_registerName(name);
}

fn alloc(class_id: id) id {
    return msgSend_id(class_id, sel("alloc"));
}

// ============================================================
// Color constants — dark theme
// ============================================================
pub const Color = struct { r: CGFloat, g: CGFloat, b: CGFloat };

pub fn hexColor(hex: u24) Color {
    return .{
        .r = @as(CGFloat, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        .g = @as(CGFloat, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        .b = @as(CGFloat, @floatFromInt(hex & 0xFF)) / 255.0,
    };
}

const bg_color = hexColor(0x0d1117);
pub const text_color = hexColor(0xc9d1d9);
const h1_color = hexColor(0xf0f6fc);
const h2_color = hexColor(0xe6edf3);
const h3_color = hexColor(0xd2d8de);
const code_bg_color = hexColor(0x161b22);
const border_color = hexColor(0x30363d);
pub const table_border_color = hexColor(0x3d444d);
pub const stripe_color = hexColor(0x151b23);
const blockquote_color = hexColor(0x8b949e);
const link_color = hexColor(0x4493f8);
const close_btn_color = hexColor(0x8b949e);

// Syntax highlighting colors

// ============================================================
// Layout constants
// ============================================================
pub const font_size_body: CGFloat = 16.0;
const font_size_code: CGFloat = 13.6;
const font_size_h1: CGFloat = 32.0;
const font_size_h2: CGFloat = 24.0;
const font_size_h3: CGFloat = 20.0;

const padding_x: CGFloat = 40.0;
const padding_top: CGFloat = 50.0;
pub const para_spacing: CGFloat = 16.0;
const code_padding: CGFloat = 12.0;
const close_btn_size: CGFloat = 28.0;

// ============================================================
// Global state
// ============================================================
var g_nsapp: id = null;
var g_view: id = null;
var g_window: id = null;
pub var g_height: CGFloat = 0;

// ============================================================
// CoreFoundation / CoreText helpers
// ============================================================

pub fn cfString(bytes: []const u8) c.CFStringRef {
    return c.CFStringCreateWithBytes(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        c.kCFStringEncodingUTF8,
        0,
    );
}

pub fn createFont(name: []const u8, size: CGFloat, bold: bool, italic: bool) c.CTFontRef {
    const cf_name = cfString(name);
    defer c.CFRelease(cf_name);

    var traits: u32 = 0;
    if (bold) traits |= @as(u32, @bitCast(@as(i32, c.kCTFontBoldTrait)));
    if (italic) traits |= @as(u32, @bitCast(@as(i32, c.kCTFontItalicTrait)));

    // Create traits dict
    const trait_keys = [_]c.CFStringRef{c.kCTFontSymbolicTrait};
    const trait_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &traits);
    defer c.CFRelease(trait_num);
    const trait_vals = [_]c.CFTypeRef{@ptrCast(trait_num)};
    const traits_dict = c.CFDictionaryCreate(
        null,
        @constCast(@ptrCast(&trait_keys)),
        @constCast(@ptrCast(&trait_vals)),
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.CFRelease(traits_dict);

    // Create font descriptor attributes
    const attrs_keys = [_]c.CFStringRef{
        c.kCTFontFamilyNameAttribute,
        c.kCTFontTraitsAttribute,
    };
    const attrs_vals = [_]c.CFTypeRef{ @ptrCast(cf_name), @ptrCast(traits_dict) };
    const attrs = c.CFDictionaryCreate(
        null,
        @constCast(@ptrCast(&attrs_keys)),
        @constCast(@ptrCast(&attrs_vals)),
        2,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.CFRelease(attrs);

    const descriptor = c.CTFontDescriptorCreateWithAttributes(attrs);
    defer c.CFRelease(descriptor);

    return c.CTFontCreateWithFontDescriptor(descriptor, size, null);
}

pub fn createMonoFont(size: CGFloat) c.CTFontRef {
    return createFont("Menlo", size, false, false);
}

// ============================================================
// Attributed string helpers
// ============================================================

pub fn setAttrColor(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex, col: Color) void {
    const cg_color = c.CGColorCreateGenericRGB(col.r, col.g, col.b, 1.0);
    defer c.CGColorRelease(cg_color);
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = start, .length = length },
        c.kCTForegroundColorAttributeName,
        @ptrCast(cg_color),
    );
}

pub fn setAttrUnderline(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex) void {
    setAttrInt(attr_str, c.CFRange{ .location = start, .length = length }, c.kCTUnderlineStyleAttributeName, c.kCTUnderlineStyleSingle);
}

pub fn setAttrIntNamed(attr_str: c.CFMutableAttributedStringRef, range: c.CFRange, name: []const u8, value: i32) void {
    const key = cfString(name);
    defer c.CFRelease(key);
    setAttrInt(attr_str, range, key, value);
}

pub fn setAttrInt(attr_str: c.CFMutableAttributedStringRef, range: c.CFRange, key: c.CFStringRef, value: i32) void {
    var v = value;
    const num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &v);
    defer c.CFRelease(num);
    c.CFAttributedStringSetAttribute(attr_str, range, key, @ptrCast(num));
}

pub fn setAttrFont(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex, font: c.CTFontRef) void {
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = start, .length = length },
        c.kCTFontAttributeName,
        @ptrCast(font),
    );
}

// ============================================================
// Text drawing
// ============================================================

/// Measure attributed string and draw it. y_cg is the CG y-coordinate for the
/// top edge of the text (in bottom-up CG coordinates, i.e. height - screen_y).
/// Returns the height consumed.
pub fn measureAndDrawAttrStr(ctx: c.CGContextRef, attr_str: c.CFAttributedStringRef, x: CGFloat, y_cg: CGFloat, max_width: CGFloat) CGFloat {
    const framesetter = c.CTFramesetterCreateWithAttributedString(attr_str);
    defer c.CFRelease(framesetter);

    const constraints = CGSize{ .width = max_width, .height = 100000.0 };
    var fit_range = c.CFRange{ .location = 0, .length = 0 };
    const suggested = c.CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        c.CFRange{ .location = 0, .length = 0 },
        null,
        constraints,
        &fit_range,
    );

    // CTFrame path rect: origin at bottom-left of the text frame in CG coords.
    // y_cg is top of text in CG coords, so bottom = y_cg - suggested.height
    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(x, y_cg - suggested.height, max_width, suggested.height));

    const frame = c.CTFramesetterCreateFrame(
        framesetter,
        c.CFRange{ .location = 0, .length = 0 },
        path,
        null,
    );
    defer c.CFRelease(frame);

    c.CGContextSaveGState(ctx);
    drawCodeBackgrounds(ctx, frame, x, y_cg - suggested.height);
    html.drawBoxes(ctx, frame, x, y_cg - suggested.height);
    c.CTFrameDraw(frame, ctx);
    drawStrikes(ctx, frame, x, y_cg - suggested.height);
    drawImages(ctx, frame, x, y_cg - suggested.height);
    c.CGContextRestoreGState(ctx);

    return suggested.height;
}

// CoreText has no strikethrough, so runs tagged with this attribute get a line drawn over them.
const strike_key_name = "mdview-strikethrough";
const code_start_key_name = "mdview-code-start";
const code_end_key_name = "mdview-code-end";

pub fn cfInt32(key_value: *const anyopaque) i32 {
    var out: i32 = -1;
    _ = c.CFNumberGetValue(@ptrCast(key_value), c.kCFNumberSInt32Type, &out);
    return out;
}

fn flushCodeFragment(ctx: c.CGContextRef, left: CGFloat, right: CGFloat, bottom: CGFloat, height: CGFloat) void {
    drawRoundedRect(ctx, cgRect(left, bottom, right - left, height), md.code_radius);
    c.CGContextFillPath(ctx);
}

fn drawCodeBackgrounds(ctx: c.CGContextRef, frame: c.CTFrameRef, frame_x: CGFloat, frame_y: CGFloat) void {
    const lines = c.CTFrameGetLines(frame);
    const line_count: usize = @intCast(c.CFArrayGetCount(lines));
    if (line_count == 0) return;
    const origins = app.gpa.alloc(CGPoint, line_count) catch return;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);

    const start_key = cfString(code_start_key_name);
    defer c.CFRelease(start_key);
    const end_key = cfString(code_end_key_name);
    defer c.CFRelease(end_key);
    c.CGContextSetRGBFillColor(ctx, hexColor(md.code_bg).r, hexColor(md.code_bg).g, hexColor(md.code_bg).b, md.code_bg_alpha);
    for (origins, 0..) |origin, li| {
        const line: c.CTLineRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(lines, @intCast(li))));
        var ascent: CGFloat = 0;
        var descent: CGFloat = 0;
        var leading: CGFloat = 0;
        _ = c.CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        const bottom = frame_y + origin.y - descent;
        const height = ascent + descent;
        const runs = c.CTLineGetGlyphRuns(line);
        const run_count: usize = @intCast(c.CFArrayGetCount(runs));
        var open = false;
        var left: CGFloat = 0;
        var right: CGFloat = 0;
        for (0..run_count) |ri| {
            const glyph_run: c.CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(runs, @intCast(ri))));
            const attrs = c.CTRunGetAttributes(glyph_run);
            const start_value = c.CFDictionaryGetValue(attrs, @ptrCast(start_key));
            const end_value = c.CFDictionaryGetValue(attrs, @ptrCast(end_key));
            if (start_value == null or end_value == null) {
                if (open) flushCodeFragment(ctx, left, right, bottom, height);
                open = false;
                continue;
            }
            const range = c.CTRunGetStringRange(glyph_run);
            const font_value = c.CFDictionaryGetValue(attrs, c.kCTFontAttributeName);
            const pad = if (font_value) |f| md.code_pad_em * c.CTFontGetSize(@ptrCast(f)) else 0;
            const x0 = frame_x + origin.x + c.CTLineGetOffsetForStringIndex(line, range.location, null);
            const x1 = frame_x + origin.x + c.CTLineGetOffsetForStringIndex(line, range.location + range.length, null);
            if (!open) {
                open = true;
                left = if (cfInt32(start_value.?) == range.location) x0 - pad else x0;
            }
            right = x1;
        }
        if (open) flushCodeFragment(ctx, left, right, bottom, height);
    }
}

fn drawStrikes(ctx: c.CGContextRef, frame: c.CTFrameRef, frame_x: CGFloat, frame_y: CGFloat) void {
    const lines = c.CTFrameGetLines(frame);
    const line_count: usize = @intCast(c.CFArrayGetCount(lines));
    if (line_count == 0) return;
    const origins = app.gpa.alloc(CGPoint, line_count) catch return;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);

    const key = cfString(strike_key_name);
    defer c.CFRelease(key);
    for (origins, 0..) |origin, li| {
        const line: c.CTLineRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(lines, @intCast(li))));
        const runs = c.CTLineGetGlyphRuns(line);
        const run_count: usize = @intCast(c.CFArrayGetCount(runs));
        for (0..run_count) |ri| {
            const glyph_run: c.CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(runs, @intCast(ri))));
            const attrs = c.CTRunGetAttributes(glyph_run);
            if (c.CFDictionaryContainsKey(attrs, @ptrCast(key)) == 0) continue;

            const range = c.CTRunGetStringRange(glyph_run);
            const x0 = c.CTLineGetOffsetForStringIndex(line, range.location, null);
            const x1 = c.CTLineGetOffsetForStringIndex(line, range.location + range.length, null);
            var ascent: CGFloat = 0;
            var descent: CGFloat = 0;
            var leading: CGFloat = 0;
            _ = c.CTRunGetTypographicBounds(glyph_run, c.CFRange{ .location = 0, .length = 0 }, &ascent, &descent, &leading);

            const y = frame_y + origin.y + ascent * 0.3;
            if (c.CFDictionaryGetValue(attrs, c.kCTForegroundColorAttributeName)) |col| {
                c.CGContextSetStrokeColorWithColor(ctx, @ptrCast(@constCast(col)));
            } else {
                c.CGContextSetRGBStrokeColor(ctx, text_color.r, text_color.g, text_color.b, 1.0);
            }
            c.CGContextSetLineWidth(ctx, 1.0);
            c.CGContextBeginPath(ctx);
            c.CGContextMoveToPoint(ctx, frame_x + origin.x + x0, y);
            c.CGContextAddLineToPoint(ctx, frame_x + origin.x + x1, y);
            c.CGContextStrokePath(ctx);
        }
    }
}

const ImageKind = enum { pending, picture, broken };

/// Width of the broken image glyph with its gap to the alt text that follows, and its height.
const broken_w: CGFloat = 18;
const broken_h: CGFloat = 16;

/// One image in a layout; CoreText reads its size through the run delegate and the drawing pass finds it again by the same pointer.
pub const ImageBox = struct { w: CGFloat, h: CGFloat, kind: ImageKind, image: *const md.Image, link: bool, floated: bool = false };

/// False while laying out table cells, where a floated image stays in the line.
pub var g_float_ok = true;

var g_boxes: ?std.heap.ArenaAllocator = null;
var g_delegate: id = null;
var g_image_timer_set = false;

pub fn resetBoxes() void {
    if (g_boxes) |*a| _ = a.reset(.free_all);
}

fn boxOf(ref: ?*anyopaque) *const ImageBox {
    return @ptrCast(@alignCast(ref.?));
}

fn delegateAscent(ref: ?*anyopaque) callconv(.c) CGFloat {
    const box = boxOf(ref);
    return if (box.floated) 0 else box.h;
}

fn delegateDescent(_: ?*anyopaque) callconv(.c) CGFloat {
    return 0;
}

fn delegateWidth(ref: ?*anyopaque) callconv(.c) CGFloat {
    const box = boxOf(ref);
    return if (box.floated) 0 else box.w;
}

const delegate_callbacks = c.CTRunDelegateCallbacks{
    .version = c.kCTRunDelegateVersion1,
    .dealloc = null,
    .getAscent = delegateAscent,
    .getDescent = delegateDescent,
    .getWidth = delegateWidth,
};

fn altSize(alt: []const u8, avail: CGFloat) [2]CGFloat {
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    const cf_str = cfString(alt) orelse return .{ 0, 0 };
    defer c.CFRelease(cf_str);
    const attr_str = c.CFAttributedStringCreateMutable(null, 0) orelse return .{ 0, 0 };
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);
    setAttrFont(attr_str, 0, c.CFStringGetLength(cf_str), font);
    const size = suggestSize(@ptrCast(attr_str), avail);
    return .{ @min(@ceil(size.width), avail), size.height };
}

pub fn imageBox(im: *const md.Image, avail: CGFloat, link: bool) ?*ImageBox {
    if (g_boxes == null) g_boxes = .init(app.gpa);
    const box = g_boxes.?.allocator().create(ImageBox) catch return null;
    box.* = .{ .w = 0, .h = 0, .kind = .pending, .image = im, .link = link, .floated = g_float_ok and im.float != .none };
    const sized = im.width > 0 or im.height > 0;
    switch (app.images.look(im.target, if (sized) 1e9 else @floatCast(avail))) {
        .pending => {},
        .picture => |s| {
            const fitted = if (sized) app.images.requested(s, im.width, im.height, @floatCast(avail)) else s;
            box.w = fitted.w;
            box.h = fitted.h;
            box.kind = if (fitted.w > 0) .picture else .pending;
        },
        .missing => if (im.alt.len > 0) {
            box.w = broken_w;
            box.h = broken_h;
            box.kind = .broken;
        },
    }
    return box;
}

pub fn drawImages(ctx: c.CGContextRef, frame: c.CTFrameRef, frame_x: CGFloat, frame_y: CGFloat) void {
    const lines = c.CTFrameGetLines(frame);
    const line_count: usize = @intCast(c.CFArrayGetCount(lines));
    if (line_count == 0) return;
    const origins = app.gpa.alloc(CGPoint, line_count) catch return;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);

    for (origins, 0..) |origin, li| {
        const line: c.CTLineRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(lines, @intCast(li))));
        const runs = c.CTLineGetGlyphRuns(line);
        const run_count: usize = @intCast(c.CFArrayGetCount(runs));
        for (0..run_count) |ri| {
            const glyph_run: c.CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(runs, @intCast(ri))));
            const attrs = c.CTRunGetAttributes(glyph_run);
            const delegate = c.CFDictionaryGetValue(attrs, c.kCTRunDelegateAttributeName) orelse continue;
            const box = boxOf(c.CTRunDelegateGetRefCon(@ptrCast(@constCast(delegate))));
            const range = c.CTRunGetStringRange(glyph_run);
            const x = frame_x + origin.x + c.CTLineGetOffsetForStringIndex(line, range.location, null);
            const base = frame_y + origin.y;
            const top = g_height - (base + box.h);
            if (box.floated or box.w <= 0 or top + box.h < 0 or top > g_height) continue;
            drawImageBox(ctx, box, x, base);
        }
    }
}

/// `base` is the CG y of the bottom edge of the box.
pub fn drawImageBox(ctx: c.CGContextRef, box: *const ImageBox, x: CGFloat, base: CGFloat) void {
    switch (box.kind) {
        .pending => {},
        .picture => {
            const bm = app.images.bitmap(box.image.target, .{ .w = @floatCast(box.w), .h = @floatCast(box.h) }) orelse return;
            c.CGContextSetInterpolationQuality(ctx, c.kCGInterpolationHigh);
            c.CGContextDrawImage(ctx, cgRect(x, base, box.w, box.h), @ptrCast(bm.native));
        },
        .broken => {
            if (app.images.brokenIcon()) |icon| {
                c.CGContextSetInterpolationQuality(ctx, c.kCGInterpolationHigh);
                c.CGContextDrawImage(ctx, cgRect(x, base, icon.w, icon.h), @ptrCast(icon.native));
                return;
            }
            const path = c.CGPathCreateMutable();
            defer c.CGPathRelease(path);
            for (alerts.brokenImage()) |op| switch (op) {
                .move => |p| c.CGPathMoveToPoint(path, null, x + p[0], base + box.h - p[1]),
                .line => |p| c.CGPathAddLineToPoint(path, null, x + p[0], base + box.h - p[1]),
                .cubic => |q| c.CGPathAddCurveToPoint(path, null, x + q[0], base + box.h - q[1], x + q[2], base + box.h - q[3], x + q[4], base + box.h - q[5]),
                .close => c.CGPathCloseSubpath(path),
            };
            c.CGContextSetRGBFillColor(ctx, blockquote_color.r, blockquote_color.g, blockquote_color.b, 1.0);
            c.CGContextAddPath(ctx, path);
            c.CGContextFillPath(ctx);
        },
    }
}

fn releaseImageData(_: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) void {
    const bytes: [*]u8 = @ptrCast(@constCast(data orelse return));
    app.gpa.free(bytes[0..size]);
}

fn createNative(rgba: []const u8, w: u32, h: u32) ?*anyopaque {
    const data = app.gpa.alloc(u8, rgba.len) catch return null;
    var i: usize = 0;
    while (i + 3 < rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        data[i] = @intCast((@as(u32, rgba[i]) * a + 127) / 255);
        data[i + 1] = @intCast((@as(u32, rgba[i + 1]) * a + 127) / 255);
        data[i + 2] = @intCast((@as(u32, rgba[i + 2]) * a + 127) / 255);
        data[i + 3] = @intCast(a);
    }
    const provider = c.CGDataProviderCreateWithData(null, data.ptr, data.len, releaseImageData) orelse {
        app.gpa.free(data);
        return null;
    };
    defer c.CGDataProviderRelease(provider);
    const space = c.CGColorSpaceCreateDeviceRGB() orelse return null;
    defer c.CGColorSpaceRelease(space);
    return @ptrCast(c.CGImageCreate(w, h, 8, 32, w * 4, space, c.kCGImageAlphaPremultipliedLast, provider, null, false, c.kCGRenderingIntentDefault));
}

fn freeNative(handle: ?*anyopaque) void {
    c.CGImageRelease(@ptrCast(handle));
}

fn scheduleImages() void {
    const ms = app.images.timerDelay() orelse return;
    if (g_image_timer_set or g_delegate == null) return;
    g_image_timer_set = true;
    _ = msgSend_timer(
        objcClass("NSTimer"),
        sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        @as(f64, @floatFromInt(@max(ms, 15))) / 1000.0,
        g_delegate,
        sel("imageTimerFire:"),
        @as(id, null),
        @as(BOOL, 0),
    );
}

fn imageTimerCallback(_: id, _: SEL, _: id) callconv(.c) void {
    g_image_timer_set = false;
    if (app.images.tick()) invalidate() else scheduleImages();
}

fn drawTooltip(ctx: c.CGContextRef, t: app.Tooltip, width: CGFloat, height: CGFloat) void {
    const size = altSize(t.text, 360);
    const w = size[0] + 16;
    const h = size[1] + 10;
    const x = @min(@as(CGFloat, t.x) + 14, width - w - 4);
    const top = if (t.y + 22 + h > height) @as(CGFloat, t.y) - h - 6 else @as(CGFloat, t.y) + 22;
    const cg_top = height - top;
    c.CGContextSetRGBFillColor(ctx, table_border_color.r, table_border_color.g, table_border_color.b, 1.0);
    drawRoundedRect(ctx, cgRect(x - 1, cg_top - h - 1, w + 2, h + 2), 5.0);
    c.CGContextFillPath(ctx);
    c.CGContextSetRGBFillColor(ctx, code_bg_color.r, code_bg_color.g, code_bg_color.b, 1.0);
    drawRoundedRect(ctx, cgRect(x, cg_top - h, w, h), 4.0);
    c.CGContextFillPath(ctx);
    const font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(font);
    _ = drawPlainText(ctx, t.text, x + 8, cg_top - 5, 360, font, text_color);
}

fn drawPlainText(ctx: c.CGContextRef, text: []const u8, x: CGFloat, y_cg: CGFloat, max_width: CGFloat, font: c.CTFontRef, col: Color) CGFloat {
    if (text.len == 0) return 0;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len = c.CFStringGetLength(cf_str);
    setAttrFont(attr_str, 0, len, font);
    setAttrColor(attr_str, 0, len, col);

    return measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x, y_cg, max_width);
}

pub fn richAttrStr(content: md.Inline, alignment: md.Align, font: c.CTFontRef, color: Color, avail: CGFloat) c.CFMutableAttributedStringRef {
    const attr_str = createRichAttrStr(content, font, color, avail) orelse return null;
    if (alignment != .none) alignAttrStr(attr_str, alignment);
    return attr_str;
}

fn drawRichText(ctx: c.CGContextRef, content_in: md.Inline, x: CGFloat, y_cg: CGFloat, max_width: CGFloat, base_font: c.CTFontRef, base_color: Color, font: app.Font, alignment: md.Align) CGFloat {
    const content = app.images.flow(content_in);
    if (content.text.len == 0) return 0;
    const attr_str = richAttrStr(content, alignment, base_font, base_color, max_width) orelse return 0;
    defer c.CFRelease(attr_str);
    const height = measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x, y_cg, max_width);
    noteHit(content, x, y_cg, max_width, height, font, false, alignment);
    return height;
}

pub fn noteHit(content: md.Inline, x: CGFloat, y_cg: CGFloat, w: CGFloat, h: CGFloat, font: app.Font, header: bool, alignment: md.Align) void {
    app.noteHit(.{
        .content = content,
        .x = @floatCast(x),
        .y = @floatCast(g_height - y_cg + app.scroll_y),
        .w = @floatCast(w),
        .h = @floatCast(h),
        .font = font,
        .header = header,
        .alignment = alignment,
    });
}

fn fontFor(font: app.Font) c.CTFontRef {
    return switch (font) {
        .body => createFont("Helvetica Neue", font_size_body, false, false),
        .h1 => createFont("Helvetica Neue", font_size_h1, true, false),
        .h2 => createFont("Helvetica Neue", font_size_h2, true, false),
        .h3 => createFont("Helvetica Neue", font_size_h3, true, false),
        .h4 => createFont("Helvetica Neue", font_size_body, true, false),
        .h5 => createFont("Helvetica Neue", 14.0, true, false),
        .h6 => createFont("Helvetica Neue", 13.6, true, false),
    };
}

pub fn textIndexAt(hit: app.Hit, x: f32, y: f32) ?u32 {
    resetBoxes();
    const font = if (hit.header) createFont("Helvetica Neue", font_size_body, true, false) else fontFor(hit.font);
    defer c.CFRelease(font);
    const attr_str = createAlignedAttrStr(hit.content, hit.alignment, font, hit.w) orelse return null;
    defer c.CFRelease(attr_str);
    const framesetter = c.CTFramesetterCreateWithAttributedString(@ptrCast(attr_str));
    defer c.CFRelease(framesetter);

    const height: CGFloat = hit.h;
    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(0, 0, hit.w, height));
    const frame = c.CTFramesetterCreateFrame(framesetter, c.CFRange{ .location = 0, .length = 0 }, path, null);
    defer c.CFRelease(frame);

    const lines = c.CTFrameGetLines(frame);
    const count: usize = @intCast(c.CFArrayGetCount(lines));
    if (count == 0) return null;
    const origins = app.gpa.alloc(CGPoint, count) catch return null;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);

    const cg_y: CGFloat = height - y;
    var best: usize = 0;
    var best_dist: CGFloat = std.math.floatMax(CGFloat);
    for (origins, 0..) |o, i| {
        const dist = @abs(cg_y - o.y);
        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }
    const line: c.CTLineRef = @ptrCast(c.CFArrayGetValueAtIndex(lines, @intCast(best)));
    var ascent: CGFloat = 0;
    var descent: CGFloat = 0;
    var leading: CGFloat = 0;
    const width = c.CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    const origin = origins[best];
    if (cg_y > origin.y + ascent or cg_y < origin.y - descent - leading) return null;
    const rel_x: CGFloat = x - origin.x;
    if (rel_x < 0 or rel_x > width) return null;

    var index = c.CTLineGetStringIndexForPosition(line, CGPoint{ .x = rel_x, .y = 0 });
    if (index == c.kCFNotFound) return null;
    if (index > 0 and c.CTLineGetOffsetForStringIndex(line, index, null) > rel_x) index -= 1;
    return md.byteFromUtf16(hit.content.text, @intCast(index));
}

pub fn openExternal(url: []const u8) void {
    const cf = cfString(url) orelse return;
    defer c.CFRelease(cf);
    const nsurl = msgSend_id_id(objcClass("NSURL"), sel("URLWithString:"), @constCast(@ptrCast(cf)));
    if (nsurl == null) return;
    const workspace = msgSend_id(objcClass("NSWorkspace"), sel("sharedWorkspace"));
    _ = msgSend_id_id(workspace, sel("openURL:"), nsurl);
}

pub fn createRichAttrStr(content: md.Inline, base_font: c.CTFontRef, base_color: Color, avail: CGFloat) c.CFMutableAttributedStringRef {
    const text = content.text;
    const cf_str = cfString(text) orelse return null;
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0) orelse return null;
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len = c.CFStringGetLength(cf_str);
    setAttrFont(attr_str, 0, len, base_font);
    setAttrColor(attr_str, 0, len, base_color);

    if (content.bold.len > 0) {
        const bold_font = createFont("Helvetica Neue", c.CTFontGetSize(base_font), true, false);
        defer c.CFRelease(bold_font);
        for (content.bold) |span| {
            const r = cfRange(text, span);
            setAttrFont(attr_str, r.location, r.length, bold_font);
        }
    }

    if (content.italic.len > 0) {
        const italic_font = createFont("Helvetica Neue", c.CTFontGetSize(base_font), false, true);
        defer c.CFRelease(italic_font);
        for (content.italic) |span| {
            const r = cfRange(text, span);
            setAttrFont(attr_str, r.location, r.length, italic_font);
        }
    }

    if (content.strike.len > 0) {
        const key = cfString(strike_key_name);
        defer c.CFRelease(key);
        for (content.strike) |span| {
            const r = cfRange(text, span);
            c.CFAttributedStringSetAttribute(attr_str, r, key, @ptrCast(c.kCFBooleanTrue));
        }
    }

    if (content.emoji.len > 0) {
        const name = cfString("Apple Color Emoji");
        defer c.CFRelease(name);
        const emoji_font = c.CTFontCreateWithName(name, c.CTFontGetSize(base_font), null);
        defer c.CFRelease(emoji_font);
        for (content.emoji) |span| {
            const r = cfRange(text, span);
            setAttrFont(attr_str, r.location, r.length, emoji_font);
        }
    }

    const has_tt = for (content.styles) |s| {
        if (s.kind == .tt) break true;
    } else false;
    if (content.code.len > 0 or has_tt) {
        const code_font = createMonoFont(c.CTFontGetSize(base_font) * md.code_scale);
        defer c.CFRelease(code_font);
        const start_key = cfString(code_start_key_name);
        defer c.CFRelease(start_key);
        const end_key = cfString(code_end_key_name);
        defer c.CFRelease(end_key);
        for (content.code) |span| markCode(attr_str, cfRange(text, span), code_font, start_key, end_key);
        for (content.styles) |s| if (s.kind == .tt) markCode(attr_str, cfRange(text, s.span), code_font, start_key, end_key);
    }

    for (content.links) |l| {
        const r = cfRange(text, .{ l.start, l.len });
        setAttrColor(attr_str, r.location, r.length, link_color);
        if (app.isHover(content, l)) setAttrUnderline(attr_str, r.location, r.length);
    }

    for (content.images) |*im| {
        const box = imageBox(im, avail, content.linkAt(im.start) != null) orelse continue;
        const delegate = c.CTRunDelegateCreate(&delegate_callbacks, box) orelse continue;
        defer c.CFRelease(delegate);
        c.CFAttributedStringSetAttribute(attr_str, cfRange(text, .{ im.start, im.len }), c.kCTRunDelegateAttributeName, @ptrCast(delegate));
    }

    for (content.sup) |span| {
        var one: i32 = 1;
        const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &one);
        defer c.CFRelease(number);
        c.CFAttributedStringSetAttribute(attr_str, cfRange(text, span), c.kCTSuperscriptAttributeName, @ptrCast(number));
    }

    for (content.styles) |s| html.applyStyle(attr_str, cfRange(text, s.span), s.kind);

    return attr_str;
}

fn markCode(attr_str: c.CFMutableAttributedStringRef, r: c.CFRange, code_font: c.CTFontRef, start_key: c.CFStringRef, end_key: c.CFStringRef) void {
    var first: i32 = @intCast(r.location);
    var last: i32 = @intCast(r.location + r.length);
    const start_number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &first);
    defer c.CFRelease(start_number);
    const end_number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &last);
    defer c.CFRelease(end_number);
    c.CFAttributedStringSetAttribute(attr_str, r, start_key, @ptrCast(start_number));
    c.CFAttributedStringSetAttribute(attr_str, r, end_key, @ptrCast(end_number));
    var pad: CGFloat = md.code_pad_em * c.CTFontGetSize(code_font);
    const kern = c.CFNumberCreate(null, c.kCFNumberFloat64Type, &pad);
    defer c.CFRelease(kern);
    if (r.location > 0) c.CFAttributedStringSetAttribute(attr_str, c.CFRange{ .location = r.location - 1, .length = 1 }, c.kCTKernAttributeName, @ptrCast(kern));
    c.CFAttributedStringSetAttribute(attr_str, c.CFRange{ .location = r.location + r.length - 1, .length = 1 }, c.kCTKernAttributeName, @ptrCast(kern));
    setAttrFont(attr_str, r.location, r.length, code_font);
    setAttrColor(attr_str, r.location, r.length, hexColor(0xe6edf3));
}

pub const cell_pad_x: CGFloat = 13.0;
pub const cell_pad_y: CGFloat = 6.0;

pub fn suggestSize(attr_str: c.CFAttributedStringRef, max_width: CGFloat) CGSize {
    const framesetter = c.CTFramesetterCreateWithAttributedString(attr_str);
    defer c.CFRelease(framesetter);
    var fit_range = c.CFRange{ .location = 0, .length = 0 };
    return c.CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        c.CFRange{ .location = 0, .length = 0 },
        null,
        CGSize{ .width = max_width, .height = 100000.0 },
        &fit_range,
    );
}

pub fn createCellAttrStr(t: md.Table, row: usize, col: usize, body_font: c.CTFontRef, header_font: c.CTFontRef, avail: CGFloat) c.CFMutableAttributedStringRef {
    return createAlignedAttrStr(app.images.flow(t.cell(row, col)), t.alignAt(row, col), if ((row == 0 and t.header_row) or (col == 0 and t.header_col)) header_font else body_font, avail);
}

pub fn createAlignedAttrStr(content: md.Inline, alignment_kind: md.Align, font: c.CTFontRef, avail: CGFloat) c.CFMutableAttributedStringRef {
    const attr_str = createRichAttrStr(content, font, text_color, avail) orelse return null;
    alignAttrStr(attr_str, alignment_kind);
    return attr_str;
}

fn alignAttrStr(attr_str: c.CFMutableAttributedStringRef, alignment_kind: md.Align) void {
    var alignment: c.CTTextAlignment = @intCast(switch (alignment_kind) {
        .none, .left => c.kCTTextAlignmentLeft,
        .center => c.kCTTextAlignmentCenter,
        .right => c.kCTTextAlignmentRight,
    });
    const setting = c.CTParagraphStyleSetting{
        .spec = @intCast(c.kCTParagraphStyleSpecifierAlignment),
        .valueSize = @sizeOf(c.CTTextAlignment),
        .value = &alignment,
    };
    const style = c.CTParagraphStyleCreate(&setting, 1);
    defer c.CFRelease(style);
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = 0, .length = c.CFAttributedStringGetLength(attr_str) },
        c.kCTParagraphStyleAttributeName,
        @ptrCast(style),
    );
}

fn cfRange(text: []const u8, span: md.Span) c.CFRange {
    const start = md.utf16Offset(text, span[0]);
    const end = md.utf16Offset(text, span[0] + span[1]);
    return .{ .location = @intCast(start), .length = @intCast(end - start) };
}

fn drawCodeBlock(ctx: c.CGContextRef, text: []const u8, toks: []const hl.Token, x: CGFloat, y_cg: CGFloat, max_width: CGFloat) CGFloat {
    if (text.len == 0) return code_padding * 2;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len = c.CFStringGetLength(cf_str);
    const mono = createMonoFont(font_size_code);
    defer c.CFRelease(mono);
    setAttrFont(attr_str, 0, len, mono);
    setAttrColor(attr_str, 0, len, text_color);

    const mono_bold = createFont("Menlo", font_size_code, true, false);
    defer c.CFRelease(mono_bold);
    applySyntaxHighlighting(attr_str, text, toks, mono_bold);

    // Measure text
    const inner_width = max_width - code_padding * 2;
    const framesetter = c.CTFramesetterCreateWithAttributedString(@ptrCast(attr_str));
    defer c.CFRelease(framesetter);

    const constraints = CGSize{ .width = inner_width, .height = 100000.0 };
    var fit_range = c.CFRange{ .location = 0, .length = 0 };
    const suggested = c.CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        c.CFRange{ .location = 0, .length = 0 },
        null,
        constraints,
        &fit_range,
    );

    const total_height = suggested.height + code_padding * 2;

    // Draw background rounded rect
    const bg_rect = cgRect(x, y_cg - total_height, max_width, total_height);
    c.CGContextSetRGBFillColor(ctx, code_bg_color.r, code_bg_color.g, code_bg_color.b, 1.0);
    drawRoundedRect(ctx, bg_rect, 6.0);
    c.CGContextFillPath(ctx);

    // Draw border
    c.CGContextSetRGBStrokeColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
    c.CGContextSetLineWidth(ctx, 1.0);
    drawRoundedRect(ctx, bg_rect, 6.0);
    c.CGContextStrokePath(ctx);

    // Draw code text
    const text_x = x + code_padding;
    const text_y_cg = y_cg - code_padding;

    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(text_x, text_y_cg - suggested.height, inner_width, suggested.height));

    const frame = c.CTFramesetterCreateFrame(
        framesetter,
        c.CFRange{ .location = 0, .length = 0 },
        path,
        null,
    );
    defer c.CFRelease(frame);

    drawLineBackgrounds(ctx, frame, text, toks, x, text_y_cg - suggested.height, max_width);

    c.CGContextSaveGState(ctx);
    c.CTFrameDraw(frame, ctx);
    c.CGContextRestoreGState(ctx);

    return total_height;
}

pub fn drawRoundedRect(ctx: c.CGContextRef, rect: CGRect, radius: CGFloat) void {
    const x0 = rect.origin.x;
    const y0 = rect.origin.y;
    const w = rect.size.width;
    const h = rect.size.height;
    c.CGContextMoveToPoint(ctx, x0 + radius, y0);
    c.CGContextAddLineToPoint(ctx, x0 + w - radius, y0);
    c.CGContextAddArcToPoint(ctx, x0 + w, y0, x0 + w, y0 + radius, radius);
    c.CGContextAddLineToPoint(ctx, x0 + w, y0 + h - radius);
    c.CGContextAddArcToPoint(ctx, x0 + w, y0 + h, x0 + w - radius, y0 + h, radius);
    c.CGContextAddLineToPoint(ctx, x0 + radius, y0 + h);
    c.CGContextAddArcToPoint(ctx, x0, y0 + h, x0, y0 + h - radius, radius);
    c.CGContextAddLineToPoint(ctx, x0, y0 + radius);
    c.CGContextAddArcToPoint(ctx, x0, y0, x0 + radius, y0, radius);
    c.CGContextClosePath(ctx);
}

fn synColor(attr_str: c.CFMutableAttributedStringRef, cursor: *md.Utf16Cursor, start: usize, end: usize, col: Color) void {
    const lo = cursor.at(start);
    setAttrColor(attr_str, @intCast(lo), @intCast(cursor.at(end) - lo), col);
}

fn applySyntaxHighlighting(attr_str: c.CFMutableAttributedStringRef, text: []const u8, toks: []const hl.Token, bold: c.CTFontRef) void {
    var cursor: md.Utf16Cursor = .{ .text = text };
    for (toks) |tok| {
        const st = hl.style(tok.kind);
        const lo = cursor.at(tok.start);
        const n = cursor.at(tok.end) - lo;
        if (st.fg) |rgb| setAttrColor(attr_str, @intCast(lo), @intCast(n), hexColor(rgb));
        if (st.bold) setAttrFont(attr_str, @intCast(lo), @intCast(n), bold);
        if (st.underline) setAttrUnderline(attr_str, @intCast(lo), @intCast(n));
    }
}

/// Fills the full block width behind each visual line that starts inside a token with a background.
/// `left` and `bottom` are the CG coordinates of the frame's origin.
fn drawLineBackgrounds(ctx: c.CGContextRef, frame: c.CTFrameRef, text: []const u8, toks: []const hl.Token, left: CGFloat, bottom: CGFloat, width: CGFloat) void {
    const lines = c.CTFrameGetLines(frame);
    const count: usize = @intCast(c.CFArrayGetCount(lines));
    if (count == 0) return;
    const origins = app.gpa.alloc(c.CGPoint, count) catch return;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);
    var cursor: md.Utf16Cursor = .{ .text = text };
    var i: usize = 0;
    var have = false;
    var lo: u32 = 0;
    var hi: u32 = 0;
    for (0..count) |k| {
        const line: c.CTLineRef = @ptrCast(c.CFArrayGetValueAtIndex(lines, @intCast(k)));
        const loc: u32 = @intCast(c.CTLineGetStringRange(line).location);
        while (i < toks.len) {
            if (hl.style(toks[i].kind).bg == null) {
                i += 1;
                have = false;
                continue;
            }
            if (!have) {
                lo = cursor.at(toks[i].start);
                hi = cursor.at(toks[i].end);
                have = true;
            }
            if (hi <= loc) {
                i += 1;
                have = false;
                continue;
            }
            break;
        }
        if (i >= toks.len or lo > loc) continue;
        var ascent: CGFloat = 0;
        var descent: CGFloat = 0;
        var leading: CGFloat = 0;
        _ = c.CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        const col = hexColor(hl.style(toks[i].kind).bg.?);
        c.CGContextSetRGBFillColor(ctx, col.r, col.g, col.b, 1.0);
        c.CGContextFillRect(ctx, cgRect(left, bottom + origins[k].y - descent, width, ascent + descent + leading));
    }
}

fn colorOf(hex: u24) Color {
    return .{
        .r = @as(CGFloat, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        .g = @as(CGFloat, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        .b = @as(CGFloat, @floatFromInt(hex & 0xFF)) / 255.0,
    };
}

const bar_color = hexColor(0x3d444d);
const err_bg_color = hexColor(0x25171c);
const err_border_color = hexColor(0x6b2b2b);
const check_color = hexColor(0x1f6feb);

fn drawAlertIcon(ctx: c.CGContextRef, alert: md.Alert, x: CGFloat, cg_top: CGFloat) void {
    const col = colorOf(alerts.style(alert).fg);
    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    for (alerts.icon(alert)) |op| switch (op) {
        .move => |p| c.CGPathMoveToPoint(path, null, x + p[0], cg_top - p[1]),
        .line => |p| c.CGPathAddLineToPoint(path, null, x + p[0], cg_top - p[1]),
        .cubic => |q| c.CGPathAddCurveToPoint(path, null, x + q[0], cg_top - q[1], x + q[2], cg_top - q[3], x + q[4], cg_top - q[5]),
        .close => c.CGPathCloseSubpath(path),
    };
    c.CGContextSetRGBFillColor(ctx, col.r, col.g, col.b, 1.0);
    c.CGContextAddPath(ctx, path);
    c.CGContextFillPath(ctx);
}

fn drawErrorBox(ctx: c.CGContextRef, content_in: md.Inline, x: CGFloat, cg_y: CGFloat, w: CGFloat, font: c.CTFontRef) CGFloat {
    const content = app.images.flow(content_in);
    const attr_str = createRichAttrStr(content, font, text_color, @max(w - 34, 20)) orelse return 0;
    defer c.CFRelease(attr_str);
    const h = suggestSize(@ptrCast(attr_str), @max(w - 34, 20)).height + 32;
    c.CGContextSetRGBFillColor(ctx, err_border_color.r, err_border_color.g, err_border_color.b, 1.0);
    drawRoundedRect(ctx, cgRect(x, cg_y - h, w, h), 6.0);
    c.CGContextFillPath(ctx);
    c.CGContextSetRGBFillColor(ctx, err_bg_color.r, err_bg_color.g, err_bg_color.b, 1.0);
    drawRoundedRect(ctx, cgRect(x + 1, cg_y - h + 1, w - 2, h - 2), 5.0);
    c.CGContextFillPath(ctx);
    _ = measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x + 17, cg_y - 16, @max(w - 34, 20));
    return h;
}

fn drawMarker(ctx: c.CGContextRef, m: md.Mark, x: CGFloat, cg_y: CGFloat, font: c.CTFontRef) void {
    switch (m.kind) {
        .none => {},
        .bullet => {
            const cx = x - 13;
            const cy = cg_y - 9.5;
            c.CGContextSetRGBFillColor(ctx, text_color.r, text_color.g, text_color.b, 1.0);
            c.CGContextSetRGBStrokeColor(ctx, text_color.r, text_color.g, text_color.b, 1.0);
            switch (m.depth % 3) {
                0 => c.CGContextFillEllipseInRect(ctx, cgRect(cx - 2.8, cy - 2.8, 5.6, 5.6)),
                1 => {
                    c.CGContextSetLineWidth(ctx, 1.0);
                    c.CGContextStrokeEllipseInRect(ctx, cgRect(cx - 2.4, cy - 2.4, 4.8, 4.8));
                },
                else => c.CGContextFillRect(ctx, cgRect(cx - 2.5, cy - 2.5, 5, 5)),
            }
        },
        .number => {
            var buf: [16]u8 = undefined;
            const attr_str = createRichAttrStr(.{ .text = md.markerLabel(&buf, m) }, font, text_color, 200) orelse return;
            defer c.CFRelease(attr_str);
            const width = suggestSize(@ptrCast(attr_str), 200).width;
            _ = measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x - 6 - width, cg_y, width + 2);
        },
        .task_open, .task_done => {
            const bx = x - 23;
            const top = cg_y - 5;
            if (m.kind == .task_done) {
                c.CGContextSetRGBFillColor(ctx, check_color.r, check_color.g, check_color.b, 1.0);
                drawRoundedRect(ctx, cgRect(bx, top - 14, 14, 14), 3.0);
                c.CGContextFillPath(ctx);
                c.CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 1.0);
                c.CGContextSetLineWidth(ctx, 1.8);
                c.CGContextMoveToPoint(ctx, bx + 3.5, top - 7.5);
                c.CGContextAddLineToPoint(ctx, bx + 6, top - 10);
                c.CGContextAddLineToPoint(ctx, bx + 10.5, top - 4.5);
                c.CGContextStrokePath(ctx);
            } else {
                c.CGContextSetRGBStrokeColor(ctx, blockquote_color.r, blockquote_color.g, blockquote_color.b, 1.0);
                c.CGContextSetLineWidth(ctx, 1.0);
                drawRoundedRect(ctx, cgRect(bx + 0.5, top - 13.5, 13, 13), 2.5);
                c.CGContextStrokePath(ctx);
            }
        },
    }
}

// ============================================================
// Main draw routine (called from drawRect:)
// ============================================================

pub const Fonts = struct {
    body: c.CTFontRef,
    h1: c.CTFontRef,
    h2: c.CTFontRef,
    h3: c.CTFontRef,
    h4: c.CTFontRef,
    h5: c.CTFontRef,
    h6: c.CTFontRef,
};

pub fn makeFonts() Fonts {
    return .{
        .body = createFont("Helvetica Neue", font_size_body, false, false),
        .h1 = createFont("Helvetica Neue", font_size_h1, true, false),
        .h2 = createFont("Helvetica Neue", font_size_h2, true, false),
        .h3 = createFont("Helvetica Neue", font_size_h3, true, false),
        .h4 = createFont("Helvetica Neue", font_size_body, true, false),
        .h5 = createFont("Helvetica Neue", 14.0, true, false),
        .h6 = createFont("Helvetica Neue", 13.6, true, false),
    };
}

pub fn releaseFonts(f: Fonts) void {
    for ([_]c.CTFontRef{ f.body, f.h1, f.h2, f.h3, f.h4, f.h5, f.h6 }) |font| c.CFRelease(font);
}

fn drawParagraph(ctx: c.CGContextRef, block: *const md.Block, x: CGFloat, cg_y: CGFloat, w: CGFloat, f: Fonts, base_col: Color, bands: *const html.Bands, screen_y: CGFloat, full_x: CGFloat, full_w: CGFloat) CGFloat {
    const dt = block.role == .dt;
    const font = if (dt) createFont("Helvetica Neue", font_size_body, true, true) else f.body;
    defer if (dt) c.CFRelease(font);
    if (bands.n == 0) return drawRichText(ctx, block.content, x, cg_y, w, font, base_col, .body, block.alignment);
    return html.drawFlowing(ctx, block.content, full_x, full_w, screen_y, font, base_col, block.alignment, bands);
}

fn isCollapsed(block: *const md.Block) bool {
    return app.collapsed(block.*);
}

/// Draws `list` from `y0` (distance from the visual top) in a column `avail` wide starting at `left`; returns the y below the last block.
pub fn layoutBlocks(ctx: c.CGContextRef, list: []const md.Block, left: CGFloat, avail: CGFloat, y0: CGFloat, f: Fonts, top: bool) CGFloat {
    const scroll: CGFloat = @floatCast(app.scroll_y);
    var screen_y = y0;
    var bands: html.Bands = .{};

    for (list) |*block| {
        // Cull blocks far below the visible area, unless a jump needs every block placed
        if (top and !app.full_layout and screen_y > g_height + 200) break;
        if (top) app.noteBlock(@floatCast(screen_y + scroll));
        if (isCollapsed(block)) continue;
        bands.drop(screen_y);

        const cg_y = g_height - screen_y;
        const inset: CGFloat = block.inset();
        const full_x = left + inset;
        const full_w = @max(avail - inset, 60);
        const floated = top and g_float_ok and html.hasFloat(block);
        if (floated) for (block.content.images) |*im| {
            if (im.float != .none) html.placeFloat(ctx, im, block.content, full_x, full_w, screen_y, &bands);
        };
        const side = bands.widths(screen_y);
        const x = full_x + side.left;
        const w = @max(full_w - side.left - side.right, 60);
        const text_col = if (block.muted()) blockquote_color else text_color;
        var content_h: CGFloat = 0;
        var gap: CGFloat = para_spacing;

        for (block.marks) |l| drawMarker(ctx, l.mark, left + l.inset, cg_y, f.body);

        switch (block.kind) {
            .h1, .h2 => {
                const first = block.kind == .h1;
                const lead: CGFloat = if (first) 24 else 20;
                const after: CGFloat = if (first) 8 else 6;
                const th = drawRichText(ctx, block.content, x, cg_y - lead, w, if (first) f.h1 else f.h2, if (first) h1_color else h2_color, if (first) .h1 else .h2, block.alignment);
                c.CGContextSetRGBFillColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
                c.CGContextFillRect(ctx, cgRect(x, cg_y - lead - th - after - 1, w, 1));
                content_h = lead + th + after + 1;
            },
            .h3 => {
                content_h = 16 + drawRichText(ctx, block.content, x, cg_y - 16, w, f.h3, h3_color, .h3, block.alignment);
                gap = 12;
            },
            .h4, .h5, .h6 => {
                const font = switch (block.kind) {
                    .h4 => f.h4,
                    .h5 => f.h5,
                    else => f.h6,
                };
                const tag: app.Font = switch (block.kind) {
                    .h4 => .h4,
                    .h5 => .h5,
                    else => .h6,
                };
                content_h = 24 + drawRichText(ctx, block.content, x, cg_y - 24, w, font, if (block.kind == .h6) blockquote_color else h3_color, tag, block.alignment);
            },
            .error_box => content_h = drawErrorBox(ctx, block.content, x, cg_y, w, f.body),
            .paragraph => {
                if (block.role == .empty) {
                    content_h = 0;
                } else if (block.role == .break_lines) {
                    content_h = html.break_line_height * @as(CGFloat, @floatFromInt(std.mem.count(u8, block.content.text, "\n")));
                    gap = 0;
                } else if (floated and html.onlyFloat(block)) {
                    gap = 0;
                } else {
                    content_h = drawParagraph(ctx, block, x, cg_y, w, f, text_col, &bands, screen_y, full_x, full_w);
                    if (block.compact) gap = 4;
                }
            },
            .alert_title => {
                const alert = block.frames[block.frames.len - 1].alert;
                drawAlertIcon(ctx, alert, x, cg_y - 8);
                _ = drawRichText(ctx, block.content, x + 24, cg_y - 6, w - 24, f.h4, colorOf(alerts.style(alert).fg), .h4, .none);
                content_h = 24;
            },
            .code_block => content_h = drawCodeBlock(ctx, block.content.text, block.tokens, x, cg_y, w),
            .table => content_h = tables.drawTable(ctx, block.table, x, cg_y, w, f.body, true, null),
            .hr => {
                c.CGContextSetRGBStrokeColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
                c.CGContextSetLineWidth(ctx, 1.0);
                const hr_cg_y = cg_y - 8;
                c.CGContextMoveToPoint(ctx, x, hr_cg_y);
                c.CGContextAddLineToPoint(ctx, x + w, hr_cg_y);
                c.CGContextStrokePath(ctx);
                content_h = 16.0;
            },
        }

        if (block.role == .summary and block.kind == .paragraph) {
            if (html.summaryFrame(block)) |frame| {
                html.drawDisclosure(ctx, x, cg_y, app.isOpen(frame));
                app.noteToggle(.{ .x = @floatCast(x - md.details_marker_inset), .y = @floatCast(screen_y + scroll), .w = @floatCast(w + md.details_marker_inset), .h = @floatCast(content_h) }, frame);
            }
        }

        for (block.frames, 0..) |fr, i| {
            if (fr.kind != .quote) continue;
            if (fr.alert != .none and !fr.open) content_h += 8;
            const col = if (fr.alert == .none) bar_color else colorOf(alerts.style(fr.alert).border);
            const bar_h = content_h + (if (fr.open) gap else 0);
            c.CGContextSetRGBFillColor(ctx, col.r, col.g, col.b, 1.0);
            c.CGContextFillRect(ctx, cgRect(left + block.insetBefore(i), cg_y - bar_h, md.quote_bar, bar_h));
        }

        screen_y += content_h + gap;
    }

    if (top) screen_y = @max(screen_y, bands.lowest());
    return screen_y;
}

fn drawContent(ctx: c.CGContextRef, width: CGFloat, height: CGFloat) void {
    // Clear background
    c.CGContextSetRGBFillColor(ctx, bg_color.r, bg_color.g, bg_color.b, 1.0);
    c.CGContextFillRect(ctx, cgRect(0, 0, width, height));

    // CoreText uses bottom-up CG coordinates (y=0 at bottom).
    // We work in native CG coords: "screen_y" = distance from visual top.
    // CG y = height - screen_y.

    const scroll: CGFloat = @floatCast(app.scroll_y);
    const fonts = makeFonts();
    defer releaseFonts(fonts);

    resetBoxes();
    html.resetSlices();
    g_height = height;
    app.beginFrame();
    const screen_y = layoutBlocks(ctx, app.blocks, padding_x, width - padding_x * 2, padding_top - scroll, fonts, true);

    // Update content height for scroll bounds
    app.content_height = @floatCast(screen_y + scroll);
    if (app.afterRender()) invalidate();

    // Draw close button (top-right corner) — in CG coords, top = near height
    const btn_x = width - close_btn_size - 8;
    const btn_cg_y = height - 8 - close_btn_size;

    // Button background circle
    c.CGContextSetRGBFillColor(ctx, 0.2, 0.2, 0.2, 0.8);
    c.CGContextFillEllipseInRect(ctx, cgRect(btn_x, btn_cg_y, close_btn_size, close_btn_size));

    // Draw X
    c.CGContextSetRGBStrokeColor(ctx, close_btn_color.r, close_btn_color.g, close_btn_color.b, 1.0);
    c.CGContextSetLineWidth(ctx, 2.0);
    const cx = btn_x + close_btn_size / 2.0;
    const cy = btn_cg_y + close_btn_size / 2.0;
    const off: CGFloat = 6.0;
    c.CGContextMoveToPoint(ctx, cx - off, cy - off);
    c.CGContextAddLineToPoint(ctx, cx + off, cy + off);
    c.CGContextStrokePath(ctx);
    c.CGContextMoveToPoint(ctx, cx + off, cy - off);
    c.CGContextAddLineToPoint(ctx, cx - off, cy + off);
    c.CGContextStrokePath(ctx);
    if (app.tooltip) |t| drawTooltip(ctx, t, width, height);
}

// ============================================================
// ObjC callback trampolines (called by the runtime)
// ============================================================

fn drawRectCallback(self: id, _sel: SEL, dirty_rect: CGRect) callconv(.c) void {
    _ = _sel;
    _ = dirty_rect;

    // NSGraphicsContext.currentContext
    const nsgfx_cls = objcClass("NSGraphicsContext");
    const current_ctx = msgSend_id(nsgfx_cls, sel("currentContext"));
    if (current_ctx == null) return;

    // .CGContext
    const cg_ctx = msgSend_ctx(current_ctx, sel("CGContext"));
    if (cg_ctx == null) return;

    // View bounds
    const bounds = msgSend_rect(self, sel("bounds"));
    app.window_width = @floatCast(bounds.size.width);
    app.window_height = @floatCast(bounds.size.height);

    if (g_window != null) app.images.dpi_scale = @floatCast(msgSend_cgfloat(g_window, sel("backingScaleFactor")));
    drawContent(cg_ctx, bounds.size.width, bounds.size.height);
    scheduleImages();
}

fn scrollWheelCallback(self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _sel;

    // deltaY
    const dy = msgSend_cgfloat(event, sel("deltaY"));

    app.scroll_y -= @as(f32, @floatCast(dy * 10.0));
    if (app.scroll_y < 0) app.scroll_y = 0;
    const max_scroll = app.content_height - app.window_height;
    if (max_scroll > 0 and app.scroll_y > max_scroll) {
        app.scroll_y = max_scroll;
    }

    // Redraw
    msgSend_void_bool(self, sel("setNeedsDisplay:"), 1);
}

fn keyDownCallback(_self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _self;
    _ = _sel;

    const key_code = msgSend_u16(event, sel("keyCode"));
    const mod_flags = msgSend_u64(event, sel("modifierFlags"));

    const cmd_mask: u64 = 1 << 20; // NSEventModifierFlagCommand
    const ctrl_mask: u64 = 1 << 18; // NSEventModifierFlagControl

    const option_mask: u64 = 1 << 19;
    if ((mod_flags & option_mask) != 0) {
        if (key_code == 123) app.goBack();
        if (key_code == 124) app.goForward();
    }
    if ((mod_flags & cmd_mask) != 0) {
        if (key_code == 33) app.goBack();
        if (key_code == 30) app.goForward();
    }

    // Q = keyCode 12
    if (key_code == 12 and ((mod_flags & cmd_mask) != 0 or (mod_flags & ctrl_mask) != 0)) {
        app.saveScrollPosition();
        const nsapp_inst = msgSend_id(objcClass("NSApplication"), sel("sharedApplication"));
        msgSend_void_id(nsapp_inst, sel("terminate:"), null);
    }
}

fn mouseDownCallback(self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _sel;

    // Get click location in view coords
    const loc_in_window = msgSend_point(event, sel("locationInWindow"));
    const loc = msgSend_convertPoint(self, sel("convertPoint:fromView:"), loc_in_window, null);

    // Get bounds
    const bounds = msgSend_rect(self, sel("bounds"));

    // Close button hit test — in AppKit coords (y=0 at bottom, same as CG for non-flipped view)
    const btn_x = bounds.size.width - close_btn_size - 8;
    const btn_y = bounds.size.height - 8 - close_btn_size;

    if (loc.x >= btn_x and loc.x <= btn_x + close_btn_size and
        loc.y >= btn_y and loc.y <= btn_y + close_btn_size)
    {
        app.saveScrollPosition();
        const nsapp_inst = msgSend_id(objcClass("NSApplication"), sel("sharedApplication"));
        msgSend_void_id(nsapp_inst, sel("terminate:"), null);
        return;
    }

    if (app.mouseDown(@floatCast(loc.x), @floatCast(bounds.size.height - loc.y))) return;

    // Allow window dragging from anywhere else (borderless window)
    if (g_window != null) {
        msgSend_void_id(g_window, sel("performWindowDragWithEvent:"), event);
    }
}

fn mouseUpCallback(self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _sel;
    const loc_in_window = msgSend_point(event, sel("locationInWindow"));
    const loc = msgSend_convertPoint(self, sel("convertPoint:fromView:"), loc_in_window, null);
    const bounds = msgSend_rect(self, sel("bounds"));
    _ = app.mouseUp(@floatCast(loc.x), @floatCast(bounds.size.height - loc.y));
}

fn otherMouseDownCallback(_self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    switch (msgSend_i64(event, sel("buttonNumber"))) {
        3 => app.goBack(),
        4 => app.goForward(),
        else => {},
    }
}

fn mouseMovedCallback(self: id, _sel: SEL, event: id) callconv(.c) void {
    _ = _sel;
    const loc_in_window = msgSend_point(event, sel("locationInWindow"));
    const loc = msgSend_convertPoint(self, sel("convertPoint:fromView:"), loc_in_window, null);
    const bounds = msgSend_rect(self, sel("bounds"));
    const over = app.pointerMoved(@floatCast(loc.x), @floatCast(bounds.size.height - loc.y));
    const cursor = msgSend_id(objcClass("NSCursor"), sel(if (over) "pointingHandCursor" else "arrowCursor"));
    msgSend_void(cursor, sel("set"));
}

fn acceptsFirstResponderCallback(_self: id, _sel: SEL) callconv(.c) BOOL {
    _ = _self;
    _ = _sel;
    return 1; // YES
}

fn isFlippedCallback(_self: id, _sel: SEL) callconv(.c) BOOL {
    _ = _self;
    _ = _sel;
    return 0; // NO — we work in native CG coordinates
}

fn canBecomeKeyWindowCallback(_self: id, _sel: SEL) callconv(.c) BOOL {
    _ = _self;
    _ = _sel;
    return 1;
}

fn canBecomeMainWindowCallback(_self: id, _sel: SEL) callconv(.c) BOOL {
    _ = _self;
    _ = _sel;
    return 1;
}

fn timerFireCallback(_self: id, _sel: SEL, _timer: id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = _timer;
    app.checkFileChanged();
}

fn applicationShouldTerminateCallback(_self: id, _sel: SEL, _sender: id) callconv(.c) NSUInteger {
    _ = _self;
    _ = _sel;
    _ = _sender;
    app.saveScrollPosition();
    return 0; // NSTerminateNow
}

// ============================================================
// Class registration
// ============================================================

fn registerViewClass() c.Class {
    const superclass = c.objc_getClass("NSView");
    const new_cls = c.objc_allocateClassPair(superclass, "MdviewContentView", 0) orelse {
        app.log("failed to allocate view class");
        return superclass;
    };

    _ = c.class_addMethod(new_cls, sel("drawRect:"), @as(c.IMP, @ptrCast(&drawRectCallback)), "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    _ = c.class_addMethod(new_cls, sel("scrollWheel:"), @as(c.IMP, @ptrCast(&scrollWheelCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("keyDown:"), @as(c.IMP, @ptrCast(&keyDownCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("mouseDown:"), @as(c.IMP, @ptrCast(&mouseDownCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("mouseUp:"), @as(c.IMP, @ptrCast(&mouseUpCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("otherMouseDown:"), @as(c.IMP, @ptrCast(&otherMouseDownCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("mouseMoved:"), @as(c.IMP, @ptrCast(&mouseMovedCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("acceptsFirstResponder"), @as(c.IMP, @ptrCast(&acceptsFirstResponderCallback)), "B@:");
    _ = c.class_addMethod(new_cls, sel("isFlipped"), @as(c.IMP, @ptrCast(&isFlippedCallback)), "B@:");

    c.objc_registerClassPair(new_cls);
    return new_cls;
}

fn registerWindowClass() c.Class {
    const superclass = c.objc_getClass("NSWindow");
    const new_cls = c.objc_allocateClassPair(superclass, "MdviewWindow", 0) orelse {
        app.log("failed to allocate window class");
        return superclass;
    };

    _ = c.class_addMethod(new_cls, sel("canBecomeKeyWindow"), @as(c.IMP, @ptrCast(&canBecomeKeyWindowCallback)), "B@:");
    _ = c.class_addMethod(new_cls, sel("canBecomeMainWindow"), @as(c.IMP, @ptrCast(&canBecomeMainWindowCallback)), "B@:");

    c.objc_registerClassPair(new_cls);
    return new_cls;
}

fn registerDelegateClass() c.Class {
    const superclass = c.objc_getClass("NSObject");
    const new_cls = c.objc_allocateClassPair(superclass, "MdviewAppDelegate", 0) orelse {
        app.log("failed to allocate delegate class");
        return superclass;
    };

    _ = c.class_addMethod(new_cls, sel("applicationShouldTerminate:"), @as(c.IMP, @ptrCast(&applicationShouldTerminateCallback)), "Q@:@");
    _ = c.class_addMethod(new_cls, sel("timerFire:"), @as(c.IMP, @ptrCast(&timerFireCallback)), "v@:@");
    _ = c.class_addMethod(new_cls, sel("imageTimerFire:"), @as(c.IMP, @ptrCast(&imageTimerCallback)), "v@:@");

    const protocol = c.objc_getProtocol("NSApplicationDelegate");
    if (protocol != null) {
        _ = c.class_addProtocol(new_cls, protocol);
    }

    c.objc_registerClassPair(new_cls);
    return new_cls;
}

// ============================================================
// Public API
// ============================================================

pub fn run() void {
    app.log("macOS backend starting");

    // Create autorelease pool
    const pool = msgSend_id(alloc(objcClass("NSAutoreleasePool")), sel("init"));

    // Get shared NSApplication
    g_nsapp = msgSend_id(objcClass("NSApplication"), sel("sharedApplication"));

    // Set activation policy: NSApplicationActivationPolicyRegular = 0
    msgSend_void_i64(g_nsapp, sel("setActivationPolicy:"), 0);

    // Register custom classes
    const view_cls = registerViewClass();
    const win_cls = registerWindowClass();
    const delegate_cls = registerDelegateClass();

    // Create window: borderless (0) | resizable (8) = 8
    const style_mask: NSUInteger = 0 | 8;
    const content_rect = cgRect(100, 100, @as(CGFloat, @floatCast(app.window_width)), @as(CGFloat, @floatCast(app.window_height)));

    g_window = msgSend_initWindow(
        alloc(@ptrCast(win_cls)),
        sel("initWithContentRect:styleMask:backing:defer:"),
        content_rect,
        style_mask,
        @as(NSUInteger, 2), // NSBackingStoreBuffered
        @as(BOOL, 0), // NO defer
    );

    // Set window background color
    const bg = msgSend_color4(
        objcClass("NSColor"),
        sel("colorWithRed:green:blue:alpha:"),
        bg_color.r,
        bg_color.g,
        bg_color.b,
        @as(CGFloat, 1.0),
    );
    msgSend_void_id(g_window, sel("setBackgroundColor:"), bg);

    // Set window title
    const title = cfString("mdview");
    defer c.CFRelease(title);
    msgSend_void_id(g_window, sel("setTitle:"), @constCast(@ptrCast(title)));

    // Create content view
    g_view = msgSend_initFrame(alloc(@ptrCast(view_cls)), sel("initWithFrame:"), content_rect);
    msgSend_void_id(g_window, sel("setContentView:"), g_view);
    msgSend_void_bool(g_window, sel("setAcceptsMouseMovedEvents:"), 1);
    msgSend_void_id(g_window, sel("makeFirstResponder:"), g_view);

    // Center and show
    msgSend_void(g_window, sel("center"));
    msgSend_void_id(g_window, sel("makeKeyAndOrderFront:"), null);

    // Activate
    msgSend_void_bool(g_nsapp, sel("activateIgnoringOtherApps:"), 1);

    // App delegate
    const delegate = msgSend_id(alloc(@ptrCast(delegate_cls)), sel("init"));
    g_delegate = delegate;
    app.images.create_native = createNative;
    app.images.free_native = freeNative;
    msgSend_void_id(g_nsapp, sel("setDelegate:"), delegate);

    // File watch timer — fires every 0.5s
    _ = msgSend_timer(
        objcClass("NSTimer"),
        sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        @as(f64, 0.5),
        delegate,
        sel("timerFire:"),
        @as(id, null),
        @as(BOOL, 1),
    );

    app.log("entering run loop");

    // Run the application event loop (does not return until terminated)
    msgSend_void(g_nsapp, sel("run"));

    // Drain pool (unreachable in practice, but correct)
    msgSend_void(pool, sel("drain"));
}

pub fn invalidate() void {
    if (g_view != null) {
        msgSend_void_bool(g_view, sel("setNeedsDisplay:"), 1);
    }
}

pub fn registerFileAssociation() void {
    std.Io.File.stdout().writeStreamingAll(app.io,
        \\To associate .md files with mdview on macOS:
        \\1. Add a CFBundleDocumentTypes entry to your app's Info.plist:
        \\   <key>CFBundleDocumentTypes</key>
        \\   <array>
        \\     <dict>
        \\       <key>CFBundleTypeExtensions</key>
        \\       <array><string>md</string><string>markdown</string></array>
        \\       <key>CFBundleTypeRole</key>
        \\       <string>Viewer</string>
        \\     </dict>
        \\   </array>
        \\2. Rebuild and re-register the app bundle.
        \\
    ) catch return;
}


test {
    _ = @import("tests.zig");
}
