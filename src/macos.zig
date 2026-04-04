// macOS backend — Cocoa (AppKit) + CoreText + CoreGraphics via Objective-C runtime
const std = @import("std");
const app = @import("main.zig");
const md = app.md;

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

// ============================================================
// ObjC runtime helpers — cast objc_msgSend per call-site
// ============================================================
const id = ?*anyopaque;
const SEL = c.SEL;
const Class = ?*anyopaque;
const BOOL = i8;
const CGFloat = f64;
const NSUInteger = u64;
const NSInteger = i64;

const CGPoint = c.CGPoint;
const CGSize = c.CGSize;
const CGRect = c.CGRect;

fn cgRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

// Typed objc_msgSend wrappers
const MsgSendFn = *const fn (id, SEL) callconv(.C) id;
const msgSend_id = @as(MsgSendFn, @ptrCast(&c.objc_msgSend));

const msgSend_void_id = @as(*const fn (id, SEL, id) callconv(.C) void, @ptrCast(&c.objc_msgSend));
const msgSend_void_bool = @as(*const fn (id, SEL, BOOL) callconv(.C) void, @ptrCast(&c.objc_msgSend));
const msgSend_void_i64 = @as(*const fn (id, SEL, i64) callconv(.C) void, @ptrCast(&c.objc_msgSend));
const msgSend_void = @as(*const fn (id, SEL) callconv(.C) void, @ptrCast(&c.objc_msgSend));
const msgSend_bool = @as(*const fn (id, SEL) callconv(.C) BOOL, @ptrCast(&c.objc_msgSend));
const msgSend_u16 = @as(*const fn (id, SEL) callconv(.C) u16, @ptrCast(&c.objc_msgSend));
const msgSend_u64 = @as(*const fn (id, SEL) callconv(.C) u64, @ptrCast(&c.objc_msgSend));
const msgSend_cgfloat = @as(*const fn (id, SEL) callconv(.C) CGFloat, @ptrCast(&c.objc_msgSend));
const msgSend_id_id = @as(*const fn (id, SEL, id) callconv(.C) id, @ptrCast(&c.objc_msgSend));

// initWithContentRect:styleMask:backing:defer:
const msgSend_initWindow = @as(*const fn (id, SEL, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.C) id, @ptrCast(&c.objc_msgSend));
// initWithFrame:
const msgSend_initFrame = @as(*const fn (id, SEL, CGRect) callconv(.C) id, @ptrCast(&c.objc_msgSend));
// colorWithRed:green:blue:alpha:
const msgSend_color4 = @as(*const fn (id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.C) id, @ptrCast(&c.objc_msgSend));
// scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:
const msgSend_timer = @as(*const fn (id, SEL, f64, id, SEL, id, BOOL) callconv(.C) id, @ptrCast(&c.objc_msgSend));
// convertPoint:fromView:
const msgSend_convertPoint = @as(*const fn (id, SEL, CGPoint, id) callconv(.C) CGPoint, @ptrCast(&c.objc_msgSend));
// CGContext (returned as pointer)
const msgSend_ctx = @as(*const fn (id, SEL) callconv(.C) c.CGContextRef, @ptrCast(&c.objc_msgSend));

// For struct returns: on arm64 all go through objc_msgSend, on x86_64 large structs need objc_msgSend_stret
const builtin_info = @import("builtin");
const msgSend_rect = if (builtin_info.cpu.arch == .x86_64)
    @as(*const fn (id, SEL) callconv(.C) CGRect, @ptrCast(@extern(*const anyopaque, .{ .name = "objc_msgSend_stret" })))
else
    @as(*const fn (id, SEL) callconv(.C) CGRect, @ptrCast(&c.objc_msgSend));

const msgSend_point = @as(*const fn (id, SEL) callconv(.C) CGPoint, @ptrCast(&c.objc_msgSend));

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
const Color = struct { r: CGFloat, g: CGFloat, b: CGFloat };

fn hexColor(comptime hex: u24) Color {
    return .{
        .r = @as(CGFloat, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        .g = @as(CGFloat, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        .b = @as(CGFloat, @floatFromInt(hex & 0xFF)) / 255.0,
    };
}

const bg_color = hexColor(0x0d1117);
const text_color = hexColor(0xc9d1d9);
const h1_color = hexColor(0xf0f6fc);
const h2_color = hexColor(0xe6edf3);
const h3_color = hexColor(0xd2d8de);
const code_bg_color = hexColor(0x161b22);
const border_color = hexColor(0x30363d);
const blockquote_color = hexColor(0x8b949e);
const close_btn_color = hexColor(0x8b949e);

// Syntax highlighting colors
const syn_keyword = hexColor(0xff7b72);
const syn_string = hexColor(0xa5d6ff);
const syn_comment = hexColor(0x8b949e);
const syn_number = hexColor(0x79c0ff);
const syn_type = hexColor(0xffa657);
const syn_func = hexColor(0xd2a8ff);

// ============================================================
// Layout constants
// ============================================================
const font_size_body: CGFloat = 15.0;
const font_size_code: CGFloat = 13.0;
const font_size_h1: CGFloat = 28.0;
const font_size_h2: CGFloat = 22.0;
const font_size_h3: CGFloat = 18.0;

const padding_x: CGFloat = 40.0;
const padding_top: CGFloat = 50.0;
const line_spacing: CGFloat = 6.0;
const para_spacing: CGFloat = 14.0;
const code_padding: CGFloat = 12.0;
const close_btn_size: CGFloat = 28.0;

// ============================================================
// Global state
// ============================================================
var g_nsapp: id = null;
var g_view: id = null;
var g_window: id = null;

// ============================================================
// CoreFoundation / CoreText helpers
// ============================================================

fn cfString(bytes: []const u8) c.CFStringRef {
    return c.CFStringCreateWithBytes(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        c.kCFStringEncodingUTF8,
        0,
    );
}

fn createFont(name: []const u8, size: CGFloat, bold: bool, italic: bool) c.CTFontRef {
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

fn createMonoFont(size: CGFloat) c.CTFontRef {
    return createFont("Menlo", size, false, false);
}

// ============================================================
// Attributed string helpers
// ============================================================

fn setAttrColor(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex, col: Color) void {
    const cg_color = c.CGColorCreateGenericRGB(col.r, col.g, col.b, 1.0);
    defer c.CGColorRelease(cg_color);
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = start, .length = length },
        c.kCTForegroundColorAttributeName,
        @ptrCast(cg_color),
    );
}

fn setAttrFont(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex, font: c.CTFontRef) void {
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
fn measureAndDrawAttrStr(ctx: c.CGContextRef, attr_str: c.CFAttributedStringRef, x: CGFloat, y_cg: CGFloat, max_width: CGFloat) CGFloat {
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
    c.CTFrameDraw(frame, ctx);
    c.CGContextRestoreGState(ctx);

    return suggested.height;
}

fn drawPlainText(ctx: c.CGContextRef, text: []const u8, x: CGFloat, y_cg: CGFloat, max_width: CGFloat, font: c.CTFontRef, col: Color) CGFloat {
    if (text.len == 0) return 0;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len: c.CFIndex = @intCast(text.len);
    setAttrFont(attr_str, 0, len, font);
    setAttrColor(attr_str, 0, len, col);

    return measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x, y_cg, max_width);
}

fn drawRichText(ctx: c.CGContextRef, block: *const md.Block, x: CGFloat, y_cg: CGFloat, max_width: CGFloat, base_font: c.CTFontRef, base_color: Color) CGFloat {
    const text = block.text;
    if (text.len == 0) return 0;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len: c.CFIndex = @intCast(text.len);
    setAttrFont(attr_str, 0, len, base_font);
    setAttrColor(attr_str, 0, len, base_color);

    // Bold ranges
    if (block.bold_count > 0) {
        const bold_font = createFont("Helvetica Neue", c.CTFontGetSize(base_font), true, false);
        defer c.CFRelease(bold_font);
        for (0..block.bold_count) |i| {
            const start: c.CFIndex = @intCast(block.bold_ranges[i][0]);
            const blen: c.CFIndex = @intCast(block.bold_ranges[i][1]);
            setAttrFont(attr_str, start, blen, bold_font);
        }
    }

    // Italic ranges
    if (block.italic_count > 0) {
        const italic_font = createFont("Helvetica Neue", c.CTFontGetSize(base_font), false, true);
        defer c.CFRelease(italic_font);
        for (0..block.italic_count) |i| {
            const start: c.CFIndex = @intCast(block.italic_ranges[i][0]);
            const ilen: c.CFIndex = @intCast(block.italic_ranges[i][1]);
            setAttrFont(attr_str, start, ilen, italic_font);
        }
    }

    // Inline code ranges
    if (block.code_count > 0) {
        const code_font = createMonoFont(font_size_code);
        defer c.CFRelease(code_font);
        for (0..block.code_count) |i| {
            const start: c.CFIndex = @intCast(block.code_ranges[i][0]);
            const clen: c.CFIndex = @intCast(block.code_ranges[i][1]);
            setAttrFont(attr_str, start, clen, code_font);
            setAttrColor(attr_str, start, clen, hexColor(0xe6edf3));
        }
    }

    return measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x, y_cg, max_width);
}

fn drawCodeBlock(ctx: c.CGContextRef, text: []const u8, x: CGFloat, y_cg: CGFloat, max_width: CGFloat) CGFloat {
    if (text.len == 0) return code_padding * 2;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len: c.CFIndex = @intCast(text.len);
    const mono = createMonoFont(font_size_code);
    defer c.CFRelease(mono);
    setAttrFont(attr_str, 0, len, mono);
    setAttrColor(attr_str, 0, len, text_color);

    // Syntax highlighting
    applySyntaxHighlighting(attr_str, text);

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

    c.CGContextSaveGState(ctx);
    c.CTFrameDraw(frame, ctx);
    c.CGContextRestoreGState(ctx);

    return total_height;
}

fn drawRoundedRect(ctx: c.CGContextRef, rect: CGRect, radius: CGFloat) void {
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

fn applySyntaxHighlighting(attr_str: c.CFMutableAttributedStringRef, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        // Line comments: //
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
            const start = i;
            while (i < text.len and text[i] != '\n') i += 1;
            setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_comment);
            continue;
        }
        // Hash comments at line start
        if (text[i] == '#' and (i == 0 or text[i - 1] == '\n')) {
            const start = i;
            while (i < text.len and text[i] != '\n') i += 1;
            setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_comment);
            continue;
        }
        // Strings
        if (text[i] == '"' or text[i] == '\'') {
            const quote = text[i];
            const start = i;
            i += 1;
            while (i < text.len and text[i] != quote and text[i] != '\n') {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
                i += 1;
            }
            if (i < text.len and text[i] == quote) i += 1;
            setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_string);
            continue;
        }
        // Numbers
        if (text[i] >= '0' and text[i] <= '9') {
            const start = i;
            while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.' or
                text[i] == 'x' or text[i] == 'X' or
                (text[i] >= 'a' and text[i] <= 'f') or
                (text[i] >= 'A' and text[i] <= 'F'))) i += 1;
            setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_number);
            continue;
        }
        // Identifiers and keywords
        if (md.isIdentStart(text[i])) {
            const start = i;
            while (i < text.len and md.isIdentChar(text[i])) i += 1;
            const word = text[start..i];

            var is_kw = false;
            for (md.hl_keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    is_kw = true;
                    break;
                }
            }
            if (is_kw) {
                setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_keyword);
            } else if (word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') {
                setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_type);
            } else if (i < text.len and text[i] == '(') {
                setAttrColor(attr_str, @intCast(start), @intCast(i - start), syn_func);
            }
            continue;
        }
        i += 1;
    }
}

// ============================================================
// Main draw routine (called from drawRect:)
// ============================================================

fn drawContent(ctx: c.CGContextRef, width: CGFloat, height: CGFloat) void {
    // Clear background
    c.CGContextSetRGBFillColor(ctx, bg_color.r, bg_color.g, bg_color.b, 1.0);
    c.CGContextFillRect(ctx, cgRect(0, 0, width, height));

    // CoreText uses bottom-up CG coordinates (y=0 at bottom).
    // We work in native CG coords: "screen_y" = distance from visual top.
    // CG y = height - screen_y.

    const scroll: CGFloat = @floatCast(app.scroll_y);
    const max_text_width = width - padding_x * 2;

    // Create fonts
    const body_font = createFont("Helvetica Neue", font_size_body, false, false);
    defer c.CFRelease(body_font);
    const h1_font = createFont("Helvetica Neue", font_size_h1, true, false);
    defer c.CFRelease(h1_font);
    const h2_font = createFont("Helvetica Neue", font_size_h2, true, false);
    defer c.CFRelease(h2_font);
    const h3_font = createFont("Helvetica Neue", font_size_h3, true, false);
    defer c.CFRelease(h3_font);

    var screen_y: CGFloat = padding_top - scroll;

    for (0..md.block_count) |i| {
        const block = &md.blocks[i];

        // Cull blocks far below the visible area
        if (screen_y > height + 200) break;

        // CG y for the top of this block
        const cg_y = height - screen_y;

        var block_height: CGFloat = 0;

        switch (block.kind) {
            .h1 => {
                block_height = drawRichText(ctx, block, padding_x, cg_y, max_text_width, h1_font, h1_color);
                block_height += para_spacing;
            },
            .h2 => {
                block_height = drawRichText(ctx, block, padding_x, cg_y, max_text_width, h2_font, h2_color);
                block_height += para_spacing;
            },
            .h3 => {
                block_height = drawRichText(ctx, block, padding_x, cg_y, max_text_width, h3_font, h3_color);
                block_height += para_spacing;
            },
            .paragraph => {
                block_height = drawRichText(ctx, block, padding_x, cg_y, max_text_width, body_font, text_color);
                block_height += para_spacing;
            },
            .code_block => {
                block_height = drawCodeBlock(ctx, block.text, padding_x, cg_y, max_text_width);
                block_height += para_spacing;
            },
            .blockquote => {
                // Draw text indented
                const text_h = drawRichText(ctx, block, padding_x + 16, cg_y, max_text_width - 16, body_font, blockquote_color);
                // Draw left border bar
                c.CGContextSetRGBFillColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
                c.CGContextFillRect(ctx, cgRect(padding_x, cg_y - text_h, 3.0, text_h));
                block_height = text_h + para_spacing;
            },
            .hr => {
                c.CGContextSetRGBStrokeColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
                c.CGContextSetLineWidth(ctx, 1.0);
                const hr_cg_y = cg_y - 8;
                c.CGContextMoveToPoint(ctx, padding_x, hr_cg_y);
                c.CGContextAddLineToPoint(ctx, width - padding_x, hr_cg_y);
                c.CGContextStrokePath(ctx);
                block_height = 16.0 + para_spacing;
            },
            .list_item => {
                // Draw bullet
                const bullet_cg_y = cg_y - font_size_body * 0.7;
                c.CGContextSetRGBFillColor(ctx, text_color.r, text_color.g, text_color.b, 1.0);
                c.CGContextFillEllipseInRect(ctx, cgRect(padding_x + 4, bullet_cg_y, 5, 5));
                block_height = drawRichText(ctx, block, padding_x + 20, cg_y, max_text_width - 20, body_font, text_color);
                block_height += line_spacing;
            },
            .blank => {
                block_height = line_spacing;
            },
        }

        screen_y += block_height;
    }

    // Update content height for scroll bounds
    app.content_height = @floatCast(screen_y + scroll);

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
}

// ============================================================
// ObjC callback trampolines (called by the runtime)
// ============================================================

fn drawRectCallback(self: id, _sel: SEL, dirty_rect: CGRect) callconv(.C) void {
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

    drawContent(cg_ctx, bounds.size.width, bounds.size.height);
}

fn scrollWheelCallback(self: id, _sel: SEL, event: id) callconv(.C) void {
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

fn keyDownCallback(_self: id, _sel: SEL, event: id) callconv(.C) void {
    _ = _self;
    _ = _sel;

    const key_code = msgSend_u16(event, sel("keyCode"));
    const mod_flags = msgSend_u64(event, sel("modifierFlags"));

    const cmd_mask: u64 = 1 << 20; // NSEventModifierFlagCommand
    const ctrl_mask: u64 = 1 << 18; // NSEventModifierFlagControl

    // Q = keyCode 12
    if (key_code == 12 and ((mod_flags & cmd_mask) != 0 or (mod_flags & ctrl_mask) != 0)) {
        app.saveScrollPosition();
        const nsapp_inst = msgSend_id(objcClass("NSApplication"), sel("sharedApplication"));
        msgSend_void_id(nsapp_inst, sel("terminate:"), null);
    }
}

fn mouseDownCallback(self: id, _sel: SEL, event: id) callconv(.C) void {
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

    // Allow window dragging from anywhere else (borderless window)
    if (g_window != null) {
        msgSend_void_id(g_window, sel("performWindowDragWithEvent:"), event);
    }
}

fn acceptsFirstResponderCallback(_self: id, _sel: SEL) callconv(.C) BOOL {
    _ = _self;
    _ = _sel;
    return 1; // YES
}

fn isFlippedCallback(_self: id, _sel: SEL) callconv(.C) BOOL {
    _ = _self;
    _ = _sel;
    return 0; // NO — we work in native CG coordinates
}

fn canBecomeKeyWindowCallback(_self: id, _sel: SEL) callconv(.C) BOOL {
    _ = _self;
    _ = _sel;
    return 1;
}

fn canBecomeMainWindowCallback(_self: id, _sel: SEL) callconv(.C) BOOL {
    _ = _self;
    _ = _sel;
    return 1;
}

fn timerFireCallback(_self: id, _sel: SEL, _timer: id) callconv(.C) void {
    _ = _self;
    _ = _sel;
    _ = _timer;
    app.checkFileChanged();
}

fn applicationShouldTerminateCallback(_self: id, _sel: SEL, _sender: id) callconv(.C) NSUInteger {
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

    // Center and show
    msgSend_void(g_window, sel("center"));
    msgSend_void_id(g_window, sel("makeKeyAndOrderFront:"), null);

    // Activate
    msgSend_void_bool(g_nsapp, sel("activateIgnoringOtherApps:"), 1);

    // App delegate
    const delegate = msgSend_id(alloc(@ptrCast(delegate_cls)), sel("init"));
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
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(
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
    ) catch {};
}
