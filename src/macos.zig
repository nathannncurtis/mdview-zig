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
// ObjC runtime helpers
// ============================================================

// objc_msgSend cast helpers — each call site needs the right signature
fn msgSend(comptime RetT: type, target: anytype, sel: c.SEL, args: anytype) RetT {
    const Target = @TypeOf(target);
    const FnArgs = .{Target} ++ .{c.SEL} ++ ArgTypes(args);
    const FnType = @Type(.{ .@"fn" = .{
        .calling_convention = .c,
        .params = blk: {
            var params: [FnArgs.len]std.builtin.Type.Fn.Param = undefined;
            inline for (0..FnArgs.len) |i| {
                params[i] = .{ .is_generic = false, .is_noalias = false, .type = FnArgs[i] };
            }
            break :blk &params;
        },
        .return_type = RetT,
        .is_generic = false,
        .is_var_args = false,
    } });
    const func: *const FnType = @ptrCast(&c.objc_msgSend);
    return @call(.auto, func, .{target} ++ .{sel} ++ args);
}

// For methods that return structs (uses objc_msgSend_stret on x86_64, regular on arm64)
fn msgSendStret(comptime RetT: type, target: anytype, sel: c.SEL, args: anytype) RetT {
    const Target = @TypeOf(target);
    const native = comptime @import("builtin").cpu.arch;
    if (native == .x86_64 and @sizeOf(RetT) > 16) {
        // On x86_64, large structs use objc_msgSend_stret
        const FnArgs = .{ *RetT, Target } ++ .{c.SEL} ++ ArgTypes(args);
        const FnType = @Type(.{ .@"fn" = .{
            .calling_convention = .c,
            .params = blk: {
                var params: [FnArgs.len]std.builtin.Type.Fn.Param = undefined;
                inline for (0..FnArgs.len) |i| {
                    params[i] = .{ .is_generic = false, .is_noalias = false, .type = FnArgs[i] };
                }
                break :blk &params;
            },
            .return_type = void,
            .is_generic = false,
            .is_var_args = false,
        } });
        const func: *const FnType = @ptrCast(@extern(*const anyopaque, .{ .name = "objc_msgSend_stret" }));
        var result: RetT = undefined;
        @call(.auto, func, .{&result} ++ .{target} ++ .{sel} ++ args);
        return result;
    } else {
        // On arm64, all structs use regular objc_msgSend
        return msgSend(RetT, target, sel, args);
    }
}

fn ArgTypes(args: anytype) type {
    const ArgsT = @TypeOf(args);
    const info = @typeInfo(ArgsT).@"struct";
    var types: [info.fields.len]type = undefined;
    inline for (info.fields, 0..) |f, i| {
        types[i] = f.type;
    }
    return types;
}

fn cls(name: [*:0]const u8) c.id {
    return @ptrCast(c.objc_getClass(name));
}

fn sel(name: [*:0]const u8) c.SEL {
    return c.sel_registerName(name);
}

fn alloc(class: c.id) c.id {
    return msgSend(c.id, class, sel("alloc"), .{});
}

fn autorelease(obj: c.id) c.id {
    return msgSend(c.id, obj, sel("autorelease"), .{});
}

// ============================================================
// CoreGraphics / CoreText type aliases
// ============================================================
const CGFloat = f64;
const CGPoint = c.CGPoint;
const CGSize = c.CGSize;
const CGRect = c.CGRect;

fn cgRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn cgSize(w: CGFloat, h: CGFloat) CGSize {
    return .{ .width = w, .height = h };
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
const code_bg_color = hexColor(0x161b22);
const border_color = hexColor(0x30363d);
const blockquote_color = hexColor(0x8b949e);
const close_btn_color = hexColor(0x8b949e);
const close_btn_hover = hexColor(0xf85149);

// Syntax highlighting colors
const syn_keyword = hexColor(0xff7b72);
const syn_string = hexColor(0xa5d6ff);
const syn_comment = hexColor(0x8b949e);
const syn_number = hexColor(0x79c0ff);
const syn_type = hexColor(0xffa657);
const syn_func = hexColor(0xd2a8ff);

// ============================================================
// Font sizes
// ============================================================
const font_size_body: CGFloat = 15.0;
const font_size_code: CGFloat = 13.0;
const font_size_h1: CGFloat = 28.0;
const font_size_h2: CGFloat = 22.0;
const font_size_h3: CGFloat = 18.0;

const padding_x: f32 = 40.0;
const padding_top: f32 = 50.0;
const line_spacing: f32 = 6.0;
const para_spacing: f32 = 14.0;
const code_padding: f32 = 12.0;
const close_btn_size: f32 = 28.0;

// ============================================================
// Global state
// ============================================================
var g_nsapp: c.id = null;
var g_view: c.id = null;
var g_window: c.id = null;

// ============================================================
// CoreFoundation / CoreText helpers
// ============================================================

fn cfString(bytes: []const u8) c.CFStringRef {
    return c.CFStringCreateWithBytes(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        c.kCFStringEncodingUTF8,
        0, // false = not external representation
    );
}

fn cfNumber(val: CGFloat) c.CFNumberRef {
    return c.CFNumberCreate(null, c.kCFNumberFloat64Type, &val);
}

fn createFont(name: []const u8, size: CGFloat, bold: bool, italic: bool) c.CTFontRef {
    const cf_name = cfString(name);
    defer c.CFRelease(cf_name);

    var traits: u32 = 0;
    if (bold) traits |= @as(u32, @bitCast(@as(i32, c.kCTFontBoldTrait)));
    if (italic) traits |= @as(u32, @bitCast(@as(i32, c.kCTFontItalicTrait)));

    const attrs_keys = [_]c.CFStringRef{
        c.kCTFontFamilyNameAttribute,
        c.kCTFontTraitsAttribute,
    };

    // Create traits dictionary
    const trait_keys = [_]c.CFStringRef{c.kCTFontSymbolicTrait};
    const trait_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &traits);
    defer c.CFRelease(trait_num);
    const trait_vals = [_]c.CFTypeRef{@ptrCast(trait_num)};
    const traits_dict = c.CFDictionaryCreate(
        null,
        @ptrCast(&trait_keys),
        @ptrCast(&trait_vals),
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.CFRelease(traits_dict);

    const attrs_vals = [_]c.CFTypeRef{ @ptrCast(cf_name), @ptrCast(traits_dict) };
    const attrs = c.CFDictionaryCreate(
        null,
        @ptrCast(&attrs_keys),
        @ptrCast(&attrs_vals),
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

fn setColor(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex, col: Color) void {
    const cg_color = c.CGColorCreateGenericRGB(col.r, col.g, col.b, 1.0);
    defer c.CGColorRelease(cg_color);
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = start, .length = length },
        c.kCTForegroundColorAttributeName,
        @ptrCast(cg_color),
    );
}

fn setFont(attr_str: c.CFMutableAttributedStringRef, start: c.CFIndex, length: c.CFIndex, font: c.CTFontRef) void {
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = start, .length = length },
        c.kCTFontAttributeName,
        @ptrCast(font),
    );
}

// ============================================================
// Drawing
// ============================================================

fn drawText(ctx: c.CGContextRef, text: []const u8, x: CGFloat, y: CGFloat, max_width: CGFloat, font: c.CTFontRef, col: Color) CGFloat {
    if (text.len == 0) return 0;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len: c.CFIndex = @intCast(text.len);
    setFont(attr_str, 0, len, font);
    setColor(attr_str, 0, len, col);

    // Paragraph style for word wrapping
    const para_style = c.CTParagraphStyleCreate(null, 0);
    defer c.CFRelease(para_style);
    c.CFAttributedStringSetAttribute(
        attr_str,
        c.CFRange{ .location = 0, .length = len },
        c.kCTParagraphStyleAttributeName,
        @ptrCast(para_style),
    );

    const framesetter = c.CTFramesetterCreateWithAttributedString(@ptrCast(attr_str));
    defer c.CFRelease(framesetter);

    const constraints = cgSize(max_width, 100000.0);
    var fit_range = c.CFRange{ .location = 0, .length = 0 };
    const suggested = c.CTFramesetterSuggestFrameSizeWithConstraints(framesetter, c.CFRange{ .location = 0, .length = 0 }, null, constraints, &fit_range);

    // Create path and frame for drawing
    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(x, y - suggested.height, max_width, suggested.height));

    const frame = c.CTFramesetterCreateFrame(framesetter, c.CFRange{ .location = 0, .length = 0 }, path, null);
    defer c.CFRelease(frame);

    c.CGContextSaveGState(ctx);
    c.CTFrameDraw(frame, ctx);
    c.CGContextRestoreGState(ctx);

    return suggested.height;
}

fn drawRichText(ctx: c.CGContextRef, block: *const md.Block, x: CGFloat, y: CGFloat, max_width: CGFloat, base_font: c.CTFontRef, base_color: Color) CGFloat {
    const text = block.text;
    if (text.len == 0) return 0;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len: c.CFIndex = @intCast(text.len);
    setFont(attr_str, 0, len, base_font);
    setColor(attr_str, 0, len, base_color);

    // Bold ranges
    if (block.bold_count > 0) {
        const bold_font = createFont("Helvetica Neue", c.CTFontGetSize(base_font), true, false);
        defer c.CFRelease(bold_font);
        for (0..block.bold_count) |i| {
            const start: c.CFIndex = @intCast(block.bold_ranges[i][0]);
            const blen: c.CFIndex = @intCast(block.bold_ranges[i][1]);
            setFont(attr_str, start, blen, bold_font);
        }
    }

    // Italic ranges
    if (block.italic_count > 0) {
        const italic_font = createFont("Helvetica Neue", c.CTFontGetSize(base_font), false, true);
        defer c.CFRelease(italic_font);
        for (0..block.italic_count) |i| {
            const start: c.CFIndex = @intCast(block.italic_ranges[i][0]);
            const ilen: c.CFIndex = @intCast(block.italic_ranges[i][1]);
            setFont(attr_str, start, ilen, italic_font);
        }
    }

    // Inline code ranges
    if (block.code_count > 0) {
        const code_font = createMonoFont(font_size_code);
        defer c.CFRelease(code_font);
        for (0..block.code_count) |i| {
            const start: c.CFIndex = @intCast(block.code_ranges[i][0]);
            const clen: c.CFIndex = @intCast(block.code_ranges[i][1]);
            setFont(attr_str, start, clen, code_font);
            setColor(attr_str, start, clen, hexColor(0xe6edf3));
        }
    }

    const framesetter = c.CTFramesetterCreateWithAttributedString(@ptrCast(attr_str));
    defer c.CFRelease(framesetter);

    const constraints = cgSize(max_width, 100000.0);
    var fit_range = c.CFRange{ .location = 0, .length = 0 };
    const suggested = c.CTFramesetterSuggestFrameSizeWithConstraints(framesetter, c.CFRange{ .location = 0, .length = 0 }, null, constraints, &fit_range);

    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(x, y - suggested.height, max_width, suggested.height));

    const frame = c.CTFramesetterCreateFrame(framesetter, c.CFRange{ .location = 0, .length = 0 }, path, null);
    defer c.CFRelease(frame);

    c.CGContextSaveGState(ctx);
    c.CTFrameDraw(frame, ctx);
    c.CGContextRestoreGState(ctx);

    return suggested.height;
}

fn drawCodeBlock(ctx: c.CGContextRef, text: []const u8, x: CGFloat, y: CGFloat, max_width: CGFloat) CGFloat {
    if (text.len == 0) return code_padding * 2;

    const cf_str = cfString(text);
    defer c.CFRelease(cf_str);

    const attr_str = c.CFAttributedStringCreateMutable(null, 0);
    defer c.CFRelease(attr_str);
    c.CFAttributedStringReplaceString(attr_str, c.CFRange{ .location = 0, .length = 0 }, cf_str);

    const len: c.CFIndex = @intCast(text.len);
    const mono = createMonoFont(font_size_code);
    defer c.CFRelease(mono);
    setFont(attr_str, 0, len, mono);
    setColor(attr_str, 0, len, text_color);

    // Syntax highlighting
    applySyntaxHighlighting(attr_str, text, mono);

    const inner_width = max_width - code_padding * 2;
    const framesetter = c.CTFramesetterCreateWithAttributedString(@ptrCast(attr_str));
    defer c.CFRelease(framesetter);

    const constraints = cgSize(inner_width, 100000.0);
    var fit_range = c.CFRange{ .location = 0, .length = 0 };
    const suggested = c.CTFramesetterSuggestFrameSizeWithConstraints(framesetter, c.CFRange{ .location = 0, .length = 0 }, null, constraints, &fit_range);

    const total_height = suggested.height + code_padding * 2;

    // Draw code block background with rounded rect
    const bg_rect = cgRect(x, y - total_height, max_width, total_height);
    c.CGContextSetRGBFillColor(ctx, code_bg_color.r, code_bg_color.g, code_bg_color.b, 1.0);
    drawRoundedRect(ctx, bg_rect, 6.0);
    c.CGContextFillPath(ctx);

    // Draw border
    c.CGContextSetRGBStrokeColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
    c.CGContextSetLineWidth(ctx, 1.0);
    drawRoundedRect(ctx, bg_rect, 6.0);
    c.CGContextStrokePath(ctx);

    // Draw text inside
    const text_x = x + code_padding;
    const text_y = y - code_padding;

    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(text_x, text_y - suggested.height, inner_width, suggested.height));

    const frame = c.CTFramesetterCreateFrame(framesetter, c.CFRange{ .location = 0, .length = 0 }, path, null);
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

fn applySyntaxHighlighting(attr_str: c.CFMutableAttributedStringRef, text: []const u8, mono: c.CTFontRef) void {
    _ = mono;
    var i: usize = 0;
    while (i < text.len) {
        // Comments
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
            const start = i;
            while (i < text.len and text[i] != '\n') i += 1;
            setColor(attr_str, @intCast(start), @intCast(i - start), syn_comment);
            continue;
        }
        // Hash comments
        if (text[i] == '#' and (i == 0 or text[i - 1] == '\n')) {
            const start = i;
            while (i < text.len and text[i] != '\n') i += 1;
            setColor(attr_str, @intCast(start), @intCast(i - start), syn_comment);
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
            setColor(attr_str, @intCast(start), @intCast(i - start), syn_string);
            continue;
        }
        // Numbers
        if (text[i] >= '0' and text[i] <= '9') {
            const start = i;
            while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.' or text[i] == 'x' or text[i] == 'X' or (text[i] >= 'a' and text[i] <= 'f') or (text[i] >= 'A' and text[i] <= 'F'))) i += 1;
            setColor(attr_str, @intCast(start), @intCast(i - start), syn_number);
            continue;
        }
        // Identifiers / keywords
        if (md.isIdentStart(text[i])) {
            const start = i;
            while (i < text.len and md.isIdentChar(text[i])) i += 1;
            const word = text[start..i];

            // Check if it's a keyword
            var is_kw = false;
            for (md.hl_keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    is_kw = true;
                    break;
                }
            }
            if (is_kw) {
                setColor(attr_str, @intCast(start), @intCast(i - start), syn_keyword);
            } else if (word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') {
                // Type names (PascalCase)
                setColor(attr_str, @intCast(start), @intCast(i - start), syn_type);
            } else if (i < text.len and text[i] == '(') {
                // Function calls
                setColor(attr_str, @intCast(start), @intCast(i - start), syn_func);
            }
            continue;
        }
        i += 1;
    }
}

// ============================================================
// Main draw routine
// ============================================================

fn drawContent(ctx: c.CGContextRef, width: CGFloat, height: CGFloat) void {
    // Clear background
    c.CGContextSetRGBFillColor(ctx, bg_color.r, bg_color.g, bg_color.b, 1.0);
    c.CGContextFillRect(ctx, cgRect(0, 0, width, height));

    // CoreText uses a bottom-up coordinate system. We flip it.
    c.CGContextTranslateCTM(ctx, 0, height);
    c.CGContextScaleCTM(ctx, 1.0, -1.0);

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

    // In our flipped coords: y goes down from 0 at top.
    // But CTFrame draws in original CG coords (bottom-up within the path rect).
    // After the flip, to place text at screen-y, we draw at screen-y.
    // CTFrame with path at (x, height - screen_y - text_h, w, text_h) in original coords
    // becomes (x, screen_y, w, text_h) in flipped coords.
    // Our drawText helper places path at (x, y - text_h, w, text_h) in the current coords.
    // After flip, y should be height - screen_y. So screen_y mapped = height - y_screen.

    var y_pos: CGFloat = padding_top - scroll;

    for (0..md.block_count) |i| {
        const block = &md.blocks[i];

        // Skip blocks entirely above or below visible area
        if (y_pos > height + 200) break;

        var block_height: CGFloat = 0;

        switch (block.kind) {
            .h1 => {
                // In flipped coords, drawText needs y = height - y_pos (the CG y for top of text)
                block_height = drawRichText(ctx, block, padding_x, height - y_pos, max_text_width, h1_font, h1_color);
                block_height += para_spacing;
            },
            .h2 => {
                block_height = drawRichText(ctx, block, padding_x, height - y_pos, max_text_width, h2_font, h2_color);
                block_height += para_spacing;
            },
            .h3 => {
                block_height = drawRichText(ctx, block, padding_x, height - y_pos, max_text_width, h3_font, h3_color);
                block_height += para_spacing;
            },
            .paragraph => {
                block_height = drawRichText(ctx, block, padding_x, height - y_pos, max_text_width, body_font, text_color);
                block_height += para_spacing;
            },
            .code_block => {
                block_height = drawCodeBlock(ctx, block.text, padding_x, height - y_pos, max_text_width);
                block_height += para_spacing;
            },
            .blockquote => {
                // Draw left border
                const bar_x = padding_x;
                const bar_y = y_pos;
                const text_h = drawRichText(ctx, block, padding_x + 16, height - y_pos, max_text_width - 16, body_font, blockquote_color);
                // Draw the bar in flipped coords
                c.CGContextSetRGBFillColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
                c.CGContextFillRect(ctx, cgRect(bar_x, height - bar_y - text_h, 3.0, text_h));
                block_height = text_h + para_spacing;
            },
            .hr => {
                c.CGContextSetRGBStrokeColor(ctx, border_color.r, border_color.g, border_color.b, 1.0);
                c.CGContextSetLineWidth(ctx, 1.0);
                const hr_y = height - y_pos - 8;
                c.CGContextMoveToPoint(ctx, padding_x, hr_y);
                c.CGContextAddLineToPoint(ctx, width - padding_x, hr_y);
                c.CGContextStrokePath(ctx);
                block_height = 16.0 + para_spacing;
            },
            .list_item => {
                // Draw bullet
                const bullet_y = height - y_pos - font_size_body * 0.7;
                c.CGContextSetRGBFillColor(ctx, text_color.r, text_color.g, text_color.b, 1.0);
                c.CGContextFillEllipseInRect(ctx, cgRect(padding_x + 4, bullet_y, 5, 5));
                block_height = drawRichText(ctx, block, padding_x + 20, height - y_pos, max_text_width - 20, body_font, text_color);
                block_height += line_spacing;
            },
            .blank => {
                block_height = line_spacing;
            },
        }

        y_pos += block_height;
    }

    // Update content height
    app.content_height = @floatCast(y_pos + scroll);

    // Draw close button (top-right) — draw in flipped coords
    const btn_x = width - close_btn_size - 8;
    const btn_y: CGFloat = 8;
    c.CGContextSetRGBFillColor(ctx, 0.2, 0.2, 0.2, 0.8);
    c.CGContextFillEllipseInRect(ctx, cgRect(btn_x, btn_y, close_btn_size, close_btn_size));

    // Draw X
    c.CGContextSetRGBStrokeColor(ctx, close_btn_color.r, close_btn_color.g, close_btn_color.b, 1.0);
    c.CGContextSetLineWidth(ctx, 2.0);
    const cx = btn_x + close_btn_size / 2.0;
    const cy = btn_y + close_btn_size / 2.0;
    const off: CGFloat = 6.0;
    c.CGContextMoveToPoint(ctx, cx - off, cy - off);
    c.CGContextAddLineToPoint(ctx, cx + off, cy + off);
    c.CGContextStrokePath(ctx);
    c.CGContextMoveToPoint(ctx, cx + off, cy - off);
    c.CGContextAddLineToPoint(ctx, cx - off, cy + off);
    c.CGContextStrokePath(ctx);
}

const h3_color = hexColor(0xd2d8de);

// ============================================================
// ObjC callback trampolines
// ============================================================

fn drawRectCallback(self: c.id, _sel: c.SEL, dirty_rect: CGRect) callconv(.C) void {
    _ = _sel;
    _ = dirty_rect;

    // Get current NSGraphicsContext
    const nsgfx_cls = cls("NSGraphicsContext");
    const current_ctx = msgSend(c.id, nsgfx_cls, sel("currentContext"), .{});
    if (current_ctx == null) return;

    // Get CGContext
    const cg_ctx: c.CGContextRef = msgSend(c.CGContextRef, current_ctx, sel("CGContext"), .{});
    if (cg_ctx == null) return;

    // Get view bounds
    const bounds = msgSendStret(CGRect, self, sel("bounds"), .{});
    app.window_width = @floatCast(bounds.size.width);
    app.window_height = @floatCast(bounds.size.height);

    drawContent(cg_ctx, bounds.size.width, bounds.size.height);
}

fn scrollWheelCallback(self: c.id, _sel: c.SEL, event: c.id) callconv(.C) void {
    _ = _sel;

    // Get scroll delta — deltaY returns CGFloat
    const dy: CGFloat = msgSend(CGFloat, event, sel("deltaY"), .{});

    app.scroll_y -= @as(f32, @floatCast(dy * 10.0));
    if (app.scroll_y < 0) app.scroll_y = 0;
    const max_scroll = app.content_height - app.window_height;
    if (max_scroll > 0 and app.scroll_y > max_scroll) {
        app.scroll_y = max_scroll;
    }

    // Request redraw
    msgSend(void, self, sel("setNeedsDisplay:"), .{@as(c.BOOL, 1)});
}

fn keyDownCallback(_self: c.id, _sel: c.SEL, event: c.id) callconv(.C) void {
    _ = _self;
    _ = _sel;

    // Get keyCode
    const key_code: u16 = msgSend(u16, event, sel("keyCode"), .{});
    // Get modifier flags
    const mod_flags: u64 = msgSend(u64, event, sel("modifierFlags"), .{});

    const cmd_mask: u64 = 1 << 20; // NSEventModifierFlagCommand
    const ctrl_mask: u64 = 1 << 18; // NSEventModifierFlagControl

    // Q key = keyCode 12
    if (key_code == 12 and ((mod_flags & cmd_mask) != 0 or (mod_flags & ctrl_mask) != 0)) {
        app.saveScrollPosition();
        // Terminate app
        const nsapp_cls = cls("NSApplication");
        const nsapp_inst = msgSend(c.id, nsapp_cls, sel("sharedApplication"), .{});
        msgSend(void, nsapp_inst, sel("terminate:"), .{@as(c.id, null)});
    }
}

fn mouseDownCallback(self: c.id, _sel: c.SEL, event: c.id) callconv(.C) void {
    _ = _sel;

    // Get click location in view coordinates
    const loc_in_window = msgSendStret(CGPoint, event, sel("locationInWindow"), .{});
    const loc = msgSendStret(CGPoint, self, sel("convertPoint:fromView:"), .{ loc_in_window, @as(c.id, null) });

    // Get bounds for close button detection
    const bounds = msgSendStret(CGRect, self, sel("bounds"), .{});
    const btn_x = bounds.size.width - close_btn_size - 8;
    // In flipped coords, close button is at top (y near bounds.height - close area)
    // The view is NOT flipped in AppKit coords, so y=0 is bottom.
    // Close button in draw is at y_flipped=8, which means AppKit y = height - 8 - close_btn_size
    const btn_y = bounds.size.height - 8 - close_btn_size;

    if (loc.x >= btn_x and loc.x <= btn_x + close_btn_size and
        loc.y >= btn_y and loc.y <= btn_y + close_btn_size)
    {
        app.saveScrollPosition();
        const nsapp_cls = cls("NSApplication");
        const nsapp_inst = msgSend(c.id, nsapp_cls, sel("sharedApplication"), .{});
        msgSend(void, nsapp_inst, sel("terminate:"), .{@as(c.id, null)});
        return;
    }

    // Allow window dragging from anywhere else
    if (g_window != null) {
        msgSend(void, g_window, sel("performWindowDragWithEvent:"), .{event});
    }
}

fn acceptsFirstResponderCallback(_self: c.id, _sel: c.SEL) callconv(.C) c.BOOL {
    _ = _self;
    _ = _sel;
    return 1; // YES
}

fn isFlippedCallback(_self: c.id, _sel: c.SEL) callconv(.C) c.BOOL {
    _ = _self;
    _ = _sel;
    return 0; // NO — we handle flipping manually in drawContent
}

fn canBecomeKeyWindowCallback(_self: c.id, _sel: c.SEL) callconv(.C) c.BOOL {
    _ = _self;
    _ = _sel;
    return 1;
}

fn canBecomeMainWindowCallback(_self: c.id, _sel: c.SEL) callconv(.C) c.BOOL {
    _ = _self;
    _ = _sel;
    return 1;
}

fn timerFireCallback(_self: c.id, _sel: c.SEL, _timer: c.id) callconv(.C) void {
    _ = _self;
    _ = _sel;
    _ = _timer;
    app.checkFileChanged();
}

fn applicationShouldTerminateCallback(_self: c.id, _sel: c.SEL, _sender: c.id) callconv(.C) u64 {
    _ = _self;
    _ = _sel;
    _ = _sender;
    app.saveScrollPosition();
    return 0; // NSTerminateNow
}

// ============================================================
// Public API
// ============================================================

pub fn run() void {
    app.log("macOS backend starting");

    // Create autorelease pool
    const pool = msgSend(c.id, alloc(cls("NSAutoreleasePool")), sel("init"), .{});
    defer msgSend(void, pool, sel("drain"), .{});

    // Get shared NSApplication
    const nsapp_cls = cls("NSApplication");
    g_nsapp = msgSend(c.id, nsapp_cls, sel("sharedApplication"), .{});

    // Set activation policy to regular (shows in dock)
    msgSend(void, g_nsapp, sel("setActivationPolicy:"), .{@as(i64, 0)}); // NSApplicationActivationPolicyRegular

    // Register custom NSView subclass
    const view_cls = registerViewClass();

    // Register custom NSWindow subclass (for canBecomeKeyWindow)
    const win_cls = registerWindowClass();

    // Create window
    const style_mask: u64 = 0 | 8; // NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
    const content_rect = cgRect(100, 100, @floatCast(app.window_width), @floatCast(app.window_height));

    g_window = msgSend(c.id, alloc(@ptrCast(win_cls)), sel("initWithContentRect:styleMask:backing:defer:"), .{
        content_rect,
        style_mask,
        @as(u64, 2), // NSBackingStoreBuffered
        @as(c.BOOL, 0), // NO
    });

    // Set window background color
    const ns_color_cls = cls("NSColor");
    const bg = msgSend(c.id, ns_color_cls, sel("colorWithRed:green:blue:alpha:"), .{
        @as(CGFloat, bg_color.r),
        @as(CGFloat, bg_color.g),
        @as(CGFloat, bg_color.b),
        @as(CGFloat, 1.0),
    });
    msgSend(void, g_window, sel("setBackgroundColor:"), .{bg});

    // Set window title
    const title = cfString("mdview");
    defer c.CFRelease(title);
    msgSend(void, g_window, sel("setTitle:"), .{@as(c.id, @ptrCast(title))});

    // Create and set content view
    g_view = msgSend(c.id, alloc(@ptrCast(view_cls)), sel("initWithFrame:"), .{content_rect});
    msgSend(void, g_window, sel("setContentView:"), .{g_view});

    // Center and show window
    msgSend(void, g_window, sel("center"), .{});
    msgSend(void, g_window, sel("makeKeyAndOrderFront:"), .{@as(c.id, null)});

    // Activate app
    msgSend(void, g_nsapp, sel("activateIgnoringOtherApps:"), .{@as(c.BOOL, 1)});

    // Set up app delegate for termination handling
    const delegate_cls = registerDelegateClass();
    const delegate = msgSend(c.id, alloc(@ptrCast(delegate_cls)), sel("init"), .{});
    msgSend(void, g_nsapp, sel("setDelegate:"), .{delegate});

    // Set up file watch timer (every 0.5s)
    const timer_cls = cls("NSTimer");
    _ = msgSend(c.id, timer_cls, sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"), .{
        @as(f64, 0.5),
        delegate,
        sel("timerFire:"),
        @as(c.id, null),
        @as(c.BOOL, 1), // YES
    });

    app.log("entering run loop");

    // Run the application
    msgSend(void, g_nsapp, sel("run"), .{});
}

pub fn invalidate() void {
    if (g_view != null) {
        msgSend(void, g_view, sel("setNeedsDisplay:"), .{@as(c.BOOL, 1)});
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

// ============================================================
// Class registration
// ============================================================

fn registerViewClass() c.Class {
    const superclass = c.objc_getClass("NSView");
    const new_cls = c.objc_allocateClassPair(superclass, "MdviewContentView", 0) orelse {
        app.log("failed to allocate view class");
        return @ptrCast(superclass);
    };

    // drawRect:
    _ = c.class_addMethod(
        new_cls,
        sel("drawRect:"),
        @as(c.IMP, @ptrCast(&drawRectCallback)),
        "v@:{CGRect={CGPoint=dd}{CGSize=dd}}",
    );

    // scrollWheel:
    _ = c.class_addMethod(
        new_cls,
        sel("scrollWheel:"),
        @as(c.IMP, @ptrCast(&scrollWheelCallback)),
        "v@:@",
    );

    // keyDown:
    _ = c.class_addMethod(
        new_cls,
        sel("keyDown:"),
        @as(c.IMP, @ptrCast(&keyDownCallback)),
        "v@:@",
    );

    // mouseDown:
    _ = c.class_addMethod(
        new_cls,
        sel("mouseDown:"),
        @as(c.IMP, @ptrCast(&mouseDownCallback)),
        "v@:@",
    );

    // acceptsFirstResponder
    _ = c.class_addMethod(
        new_cls,
        sel("acceptsFirstResponder"),
        @as(c.IMP, @ptrCast(&acceptsFirstResponderCallback)),
        "B@:",
    );

    // isFlipped
    _ = c.class_addMethod(
        new_cls,
        sel("isFlipped"),
        @as(c.IMP, @ptrCast(&isFlippedCallback)),
        "B@:",
    );

    c.objc_registerClassPair(new_cls);
    return new_cls;
}

fn registerWindowClass() c.Class {
    const superclass = c.objc_getClass("NSWindow");
    const new_cls = c.objc_allocateClassPair(superclass, "MdviewWindow", 0) orelse {
        app.log("failed to allocate window class");
        return @ptrCast(superclass);
    };

    _ = c.class_addMethod(
        new_cls,
        sel("canBecomeKeyWindow"),
        @as(c.IMP, @ptrCast(&canBecomeKeyWindowCallback)),
        "B@:",
    );

    _ = c.class_addMethod(
        new_cls,
        sel("canBecomeMainWindow"),
        @as(c.IMP, @ptrCast(&canBecomeMainWindowCallback)),
        "B@:",
    );

    c.objc_registerClassPair(new_cls);
    return new_cls;
}

fn registerDelegateClass() c.Class {
    const superclass = c.objc_getClass("NSObject");
    const new_cls = c.objc_allocateClassPair(superclass, "MdviewAppDelegate", 0) orelse {
        app.log("failed to allocate delegate class");
        return @ptrCast(superclass);
    };

    _ = c.class_addMethod(
        new_cls,
        sel("applicationShouldTerminate:"),
        @as(c.IMP, @ptrCast(&applicationShouldTerminateCallback)),
        "Q@:@",
    );

    _ = c.class_addMethod(
        new_cls,
        sel("timerFire:"),
        @as(c.IMP, @ptrCast(&timerFireCallback)),
        "v@:@",
    );

    // Conform to NSApplicationDelegate protocol
    const protocol = c.objc_getProtocol("NSApplicationDelegate");
    if (protocol != null) {
        _ = c.class_addProtocol(new_cls, protocol);
    }

    c.objc_registerClassPair(new_cls);
    return new_cls;
}
