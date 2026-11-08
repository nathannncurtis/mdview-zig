const std = @import("std");
const app = @import("../../main.zig");
const mac = @import("macos.zig");
const md = app.md;
const c = @import("c");

const CGFloat = mac.CGFloat;
const CGPoint = mac.CGPoint;
const CGRect = mac.CGRect;
const Color = mac.Color;
const cgRect = mac.cgRect;
const cfString = mac.cfString;
const cfInt32 = mac.cfInt32;
const drawRoundedRect = mac.drawRoundedRect;
const setAttrIntNamed = mac.setAttrIntNamed;
const setAttrUnderline = mac.setAttrUnderline;
const setAttrFont = mac.setAttrFont;
const setAttrColor = mac.setAttrColor;
const createMonoFont = mac.createMonoFont;
const imageBox = mac.imageBox;
const drawImageBox = mac.drawImageBox;
const richAttrStr = mac.richAttrStr;
const suggestSize = mac.suggestSize;
const measureAndDrawAttrStr = mac.measureAndDrawAttrStr;
const noteHit = mac.noteHit;
const text_color = mac.text_color;
const table_border_color = mac.table_border_color;


pub const box_kind_key_name = "mdview-box";
pub const box_start_key_name = "mdview-box-start";
pub const BoxKind = enum(i32) { kbd = 1, mark = 2 };
pub const Box = struct { kind: BoxKind, rect: CGRect };

pub const kbd_pad: CGFloat = 4;
pub const kbd_height: CGFloat = 20;
// vertical-align: middle puts the box centre half an x-height above the baseline
pub const kbd_mid: CGFloat = 4.3;
const kbd_bg_color = mac.hexColor(0x151b23);
pub const kbd_text_color = mac.hexColor(0xf0f6fc);
const mark_color = mac.hexColor(0xbb8009);
pub const mark_alpha: CGFloat = 0.149;

pub fn pushBox(out: *std.ArrayList(Box), kind: BoxKind, left: CGFloat, right: CGFloat, base: CGFloat, ascent: CGFloat, descent: CGFloat) void {
    const rect = switch (kind) {
        .kbd => cgRect(left, base + kbd_mid - kbd_height / 2, right - left, kbd_height),
        .mark => cgRect(left, base - descent, right - left, ascent + descent),
    };
    out.append(app.gpa, .{ .kind = kind, .rect = rect }) catch return;
}

/// The boxes kbd and mark spans take in a frame, one per line fragment.
pub fn collectBoxes(frame: c.CTFrameRef, frame_x: CGFloat, frame_y: CGFloat, out: *std.ArrayList(Box)) void {
    const lines = c.CTFrameGetLines(frame);
    const line_count: usize = @intCast(c.CFArrayGetCount(lines));
    if (line_count == 0) return;
    const origins = app.gpa.alloc(CGPoint, line_count) catch return;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);

    const kind_key = cfString(box_kind_key_name);
    defer c.CFRelease(kind_key);
    const start_key = cfString(box_start_key_name);
    defer c.CFRelease(start_key);
    for (origins, 0..) |origin, li| {
        const line: c.CTLineRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(lines, @intCast(li))));
        var ascent: CGFloat = 0;
        var descent: CGFloat = 0;
        var leading: CGFloat = 0;
        _ = c.CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        const base = frame_y + origin.y;
        const runs = c.CTLineGetGlyphRuns(line);
        const run_count: usize = @intCast(c.CFArrayGetCount(runs));
        var open: ?BoxKind = null;
        var left: CGFloat = 0;
        var right: CGFloat = 0;
        for (0..run_count) |ri| {
            const glyph_run: c.CTRunRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(runs, @intCast(ri))));
            const attrs = c.CTRunGetAttributes(glyph_run);
            const kind_value = c.CFDictionaryGetValue(attrs, @ptrCast(kind_key));
            const kind: ?BoxKind = if (kind_value) |v| switch (cfInt32(v)) {
                1 => .kbd,
                2 => .mark,
                else => null,
            } else null;
            if (open != null and open != kind) {
                pushBox(out, open.?, left, right, base, ascent, descent);
                open = null;
            }
            const k = kind orelse continue;
            const range = c.CTRunGetStringRange(glyph_run);
            const pad: CGFloat = if (k == .kbd) kbd_pad + 1 else 0;
            const x0 = frame_x + origin.x + c.CTLineGetOffsetForStringIndex(line, range.location, null);
            const x1 = frame_x + origin.x + c.CTLineGetOffsetForStringIndex(line, range.location + range.length, null);
            if (open == null) {
                open = k;
                const start_value = c.CFDictionaryGetValue(attrs, @ptrCast(start_key));
                left = if (start_value != null and cfInt32(start_value.?) == range.location) x0 - pad else x0;
            }
            right = x1;
        }
        if (open) |k| pushBox(out, k, left, right, base, ascent, descent);
    }
}

pub fn drawBoxes(ctx: c.CGContextRef, frame: c.CTFrameRef, frame_x: CGFloat, frame_y: CGFloat) void {
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(app.gpa);
    collectBoxes(frame, frame_x, frame_y, &boxes);
    for (boxes.items) |b| switch (b.kind) {
        .mark => {
            c.CGContextSetRGBFillColor(ctx, mark_color.r, mark_color.g, mark_color.b, mark_alpha);
            c.CGContextFillRect(ctx, b.rect);
        },
        .kbd => {
            c.CGContextSetRGBFillColor(ctx, kbd_bg_color.r, kbd_bg_color.g, kbd_bg_color.b, 1.0);
            drawRoundedRect(ctx, b.rect, md.code_radius);
            c.CGContextFillPath(ctx);
            c.CGContextSetRGBStrokeColor(ctx, table_border_color.r, table_border_color.g, table_border_color.b, 1.0);
            c.CGContextSetLineWidth(ctx, 1.0);
            drawRoundedRect(ctx, cgRect(b.rect.origin.x + 0.5, b.rect.origin.y + 0.5, b.rect.size.width - 1, b.rect.size.height - 1), md.code_radius);
            c.CGContextStrokePath(ctx);
            c.CGContextSetRGBFillColor(ctx, table_border_color.r, table_border_color.g, table_border_color.b, 1.0);
            c.CGContextFillRect(ctx, cgRect(b.rect.origin.x + md.code_radius, b.rect.origin.y + 1, b.rect.size.width - md.code_radius * 2, 1));
        },
    };
}

pub fn applyStyle(attr_str: c.CFMutableAttributedStringRef, r: c.CFRange, kind: md.StyleKind) void {
    if (r.length <= 0) return;
    switch (kind) {
        .tt => {},
        .sub => lower(attr_str, r),
        .underline => setAttrUnderline(attr_str, r.location, r.length),
        .mark => {
            setAttrIntNamed(attr_str, r, box_kind_key_name, @backingInt(BoxKind.mark));
            setAttrColor(attr_str, r.location, r.length, kbd_text_color);
        },
        .kbd => {
            const font = createMonoFont(md.kbd_font_px);
            defer c.CFRelease(font);
            setAttrFont(attr_str, r.location, r.length, font);
            setAttrColor(attr_str, r.location, r.length, kbd_text_color);
            setAttrIntNamed(attr_str, r, box_kind_key_name, @backingInt(BoxKind.kbd));
            setAttrIntNamed(attr_str, r, box_start_key_name, @intCast(r.location));
            var pad: CGFloat = kbd_pad + 1;
            const kern = c.CFNumberCreate(null, c.kCFNumberFloat64Type, &pad);
            defer c.CFRelease(kern);
            if (r.location > 0) c.CFAttributedStringSetAttribute(attr_str, c.CFRange{ .location = r.location - 1, .length = 1 }, c.kCTKernAttributeName, @ptrCast(kern));
            c.CFAttributedStringSetAttribute(attr_str, c.CFRange{ .location = r.location + r.length - 1, .length = 1 }, c.kCTKernAttributeName, @ptrCast(kern));
        },
    }
}

pub const Band = struct { right: bool, w: CGFloat, top: CGFloat, bottom: CGFloat };

pub const Sides = struct { left: CGFloat, right: CGFloat };

pub const max_bands = 256;

pub const Bands = struct {
    items: [max_bands]Band = @splat(.{ .right = false, .w = 0, .top = 0, .bottom = 0 }),
    n: usize = 0,

    pub fn add(self: *Bands, b: Band) void {
        if (self.n == self.items.len) self.n = 0;
        self.items[self.n] = b;
        self.n += 1;
    }

    pub fn drop(self: *Bands, y: CGFloat) void {
        var i: usize = 0;
        while (i < self.n) {
            if (self.items[i].bottom <= y + 0.5) {
                self.n -= 1;
                self.items[i] = self.items[self.n];
            } else i += 1;
        }
    }

    pub fn widths(self: *const Bands, y: CGFloat) Sides {
        var out: Sides = .{ .left = 0, .right = 0 };
        for (self.items[0..self.n]) |b| {
            if (y + 0.5 < b.top or y >= b.bottom) continue;
            if (b.right) out.right = @max(out.right, b.w) else out.left = @max(out.left, b.w);
        }
        return out;
    }

    /// The nearest top or bottom edge below `y`, where the width beside the floats changes.
    pub fn nextEdge(self: *const Bands, y: CGFloat) ?CGFloat {
        var best: ?CGFloat = null;
        for (self.items[0..self.n]) |b| for ([_]CGFloat{ b.top, b.bottom }) |edge| {
            if (edge > y + 0.5 and (best == null or edge < best.?)) best = edge;
        };
        return best;
    }

    pub fn lowest(self: *const Bands) CGFloat {
        var y: CGFloat = 0;
        for (self.items[0..self.n]) |b| y = @max(y, b.bottom);
        return y;
    }
};

var g_slices: ?std.heap.ArenaAllocator = null;

fn slices() std.mem.Allocator {
    if (g_slices == null) g_slices = .init(app.gpa);
    return g_slices.?.allocator();
}

/// Frees what the hits of the last frame pointed into; call where the hits are cleared.
pub fn resetSlices() void {
    if (g_slices) |*a| _ = a.reset(.free_all);
}

pub fn hasFloat(block: *const md.Block) bool {
    if (block.kind != .paragraph) return false;
    for (block.content.images) |im| if (im.float != .none) return true;
    return false;
}

pub fn onlyFloat(block: *const md.Block) bool {
    const t = block.content.text;
    var i: usize = 0;
    scan: while (i < t.len) {
        for (block.content.images) |im| {
            if (im.float != .none and i >= im.start and i < im.start + im.len) {
                i = im.start + im.len;
                continue :scan;
            }
        }
        if (!std.ascii.isWhitespace(t[i])) return false;
        i += 1;
    }
    return true;
}

/// Draws a floated image at its side of the column and records the band it takes; a float on a side that is taken goes below it.
pub const Slot = struct { x: CGFloat, y: CGFloat };

/// Finds the place for a float `bw` by `bh` and records its band: beside the floats on its side when the line has room, else below them.
pub fn claimFloat(bands: *Bands, right: bool, bw: CGFloat, bh: CGFloat, x: CGFloat, w: CGFloat, screen_y: CGFloat) Slot {
    const side = bands.widths(screen_y);
    var offset = if (right) side.right else side.left;
    var y = screen_y;
    if (offset > 0 and offset + (if (right) side.left else side.right) + bw > w) {
        for (bands.items[0..bands.n]) |b| if (b.right == right) {
            y = @max(y, b.bottom);
        };
        offset = 0;
    }
    bands.add(.{ .right = right, .w = offset + bw + md.float_gap, .top = y, .bottom = y + bh });
    return .{ .x = if (right) x + w - offset - bw else x + offset, .y = y };
}

pub fn placeFloat(ctx: c.CGContextRef, im: *const md.Image, content: md.Inline, x: CGFloat, w: CGFloat, screen_y: CGFloat, bands: *Bands) void {
    const box = imageBox(im, w, false) orelse return;
    if (box.w <= 0) return;
    const slot = claimFloat(bands, im.float == .right, box.w, box.h, x, w, screen_y);
    drawImageBox(ctx, box, slot.x, mac.g_height - slot.y - box.h);
    noteFloatHit(im, content, slot.x, slot.y, box.w, box.h);
}

fn noteFloatHit(im: *const md.Image, content: md.Inline, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) void {
    const link = content.linkAt(im.start);
    if (link == null and im.title.len == 0) return;
    const a = slices();
    const images = a.alloc(md.Image, 1) catch return;
    images[0] = im.*;
    images[0].start = 0;
    images[0].float = .none;
    const links = a.alloc(md.Link, if (link == null) 0 else 1) catch return;
    if (link) |l| {
        links[0] = l;
        links[0].start = 0;
        links[0].len = im.len;
    }
    const text = a.dupe(u8, content.text[im.start .. im.start + im.len]) catch return;
    noteHit(.{ .text = text, .images = images, .links = links }, x, mac.g_height - y, w, h, .body, false, .none);
}

/// The index of the first line that starts at or below `room`, or 0 when every line is above it.
pub fn splitIndex(attr_str: c.CFAttributedStringRef, w: CGFloat, h: CGFloat, room: CGFloat) c.CFIndex {
    const framesetter = c.CTFramesetterCreateWithAttributedString(attr_str);
    defer c.CFRelease(framesetter);
    const path = c.CGPathCreateMutable();
    defer c.CGPathRelease(path);
    c.CGPathAddRect(path, null, cgRect(0, 0, w, h));
    const frame = c.CTFramesetterCreateFrame(framesetter, c.CFRange{ .location = 0, .length = 0 }, path, null);
    defer c.CFRelease(frame);
    const lines = c.CTFrameGetLines(frame);
    const count: usize = @intCast(c.CFArrayGetCount(lines));
    if (count < 2) return 0;
    const origins = app.gpa.alloc(CGPoint, count) catch return 0;
    defer app.gpa.free(origins);
    c.CTFrameGetLineOrigins(frame, c.CFRange{ .location = 0, .length = 0 }, origins.ptr);
    for (origins[1..], 1..) |origin, li| {
        const line: c.CTLineRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(lines, @intCast(li))));
        var ascent: CGFloat = 0;
        _ = c.CTLineGetTypographicBounds(line, &ascent, null, null);
        if (h - origin.y - ascent >= room - 0.5) return c.CTLineGetStringRange(line).location;
    }
    return 0;
}

fn shifted(start: u32, len: u32, from: u32) ?[2]u32 {
    const end = start + len;
    if (end <= from) return null;
    const s = @max(start, from);
    return .{ s - from, end - s };
}

fn cutSpans(a: std.mem.Allocator, items: []const md.Span, from: u32) []const md.Span {
    var out: std.ArrayList(md.Span) = .empty;
    for (items) |s| if (shifted(s[0], s[1], from)) |n| out.append(a, n) catch break;
    return out.items;
}

/// The part of `content` from byte `from` on, with every span moved along.
pub fn sliceInline(content: md.Inline, from: u32) md.Inline {
    const a = slices();
    var out = content;
    out.text = content.text[from..];
    out.bold = cutSpans(a, content.bold, from);
    out.italic = cutSpans(a, content.italic, from);
    out.code = cutSpans(a, content.code, from);
    out.strike = cutSpans(a, content.strike, from);
    out.emoji = cutSpans(a, content.emoji, from);
    out.sup = cutSpans(a, content.sup, from);
    var links: std.ArrayList(md.Link) = .empty;
    for (content.links) |l| if (shifted(l.start, l.len, from)) |n| {
        var m = l;
        m.start = n[0];
        m.len = n[1];
        links.append(a, m) catch break;
    };
    out.links = links.items;
    var images: std.ArrayList(md.Image) = .empty;
    for (content.images) |im| if (shifted(im.start, im.len, from)) |n| {
        var m = im;
        m.start = n[0];
        m.len = n[1];
        images.append(a, m) catch break;
    };
    out.images = images.items;
    var styles: std.ArrayList(md.Styled) = .empty;
    for (content.styles) |s| if (shifted(s.span[0], s.span[1], from)) |n| {
        var m = s;
        m.span = n;
        styles.append(a, m) catch break;
    };
    out.styles = styles.items;
    return out;
}

/// Lays text out beside the floats: the lines that start where a float ends or begins continue at the new width.
pub fn drawFlowing(ctx: c.CGContextRef, content_in: md.Inline, left: CGFloat, full_w: CGFloat, screen_y: CGFloat, font: c.CTFontRef, col: Color, alignment: md.Align, bands: *const Bands) CGFloat {
    var seg = app.images.flow(content_in);
    var used: CGFloat = 0;
    for (0..64) |_| {
        if (seg.text.len == 0) return used;
        const y = screen_y + used;
        const side = bands.widths(y);
        const x = left + side.left;
        const w = @max(full_w - side.left - side.right, 60);
        const cg_y = mac.g_height - y;
        const attr_str = richAttrStr(seg, alignment, font, col, w) orelse return used;
        defer c.CFRelease(attr_str);
        const room = if (bands.nextEdge(y)) |edge| edge - y else 0;
        const split = if (room > 0) splitIndex(@ptrCast(attr_str), w, suggestSize(@ptrCast(attr_str), w).height, room) else 0;
        const from = if (split > 0) md.byteFromUtf16(seg.text, @intCast(split)) else 0;
        if (from == 0) {
            const h = measureAndDrawAttrStr(ctx, @ptrCast(attr_str), x, cg_y, w);
            noteHit(seg, x, cg_y, w, h, .body, false, alignment);
            return used + h;
        }
        const head = c.CFAttributedStringCreateWithSubstring(null, @ptrCast(attr_str), c.CFRange{ .location = 0, .length = split }) orelse return used;
        defer c.CFRelease(head);
        const head_h = measureAndDrawAttrStr(ctx, head, x, cg_y, w);
        noteHit(seg, x, cg_y, w, head_h, .body, false, alignment);
        used += head_h;
        seg = sliceInline(seg, from);
    }
    return used;
}

pub fn summaryFrame(block: *const md.Block) ?md.Frame {
    var i = block.frames.len;
    while (i > 0) : (i -= 1) if (block.frames[i - 1].kind == .details) return block.frames[i - 1];
    return null;
}

pub fn drawDisclosure(ctx: c.CGContextRef, x: CGFloat, cg_y: CGFloat, open: bool) void {
    const left = x - md.details_marker_inset + 3;
    const cy = cg_y - 10;
    c.CGContextSetRGBFillColor(ctx, text_color.r, text_color.g, text_color.b, 1.0);
    c.CGContextBeginPath(ctx);
    if (open) {
        c.CGContextMoveToPoint(ctx, left - 0.5, cy + 3);
        c.CGContextAddLineToPoint(ctx, left + 8.5, cy + 3);
        c.CGContextAddLineToPoint(ctx, left + 4, cy - 4.5);
    } else {
        c.CGContextMoveToPoint(ctx, left + 1, cy + 4.5);
        c.CGContextAddLineToPoint(ctx, left + 1, cy - 4.5);
        c.CGContextAddLineToPoint(ctx, left + 8, cy);
    }
    c.CGContextClosePath(ctx);
    c.CGContextFillPath(ctx);
}

/// Gives every font in `r` the size times `factor`, keeping its family and traits.
fn scaleFonts(attr_str: c.CFMutableAttributedStringRef, r: c.CFRange, factor: CGFloat) void {
    var at = r.location;
    const end = r.location + r.length;
    while (at < end) {
        var effective = c.CFRange{ .location = 0, .length = 0 };
        const value = c.CFAttributedStringGetAttributeAndLongestEffectiveRange(attr_str, at, c.kCTFontAttributeName, c.CFRange{ .location = at, .length = end - at }, &effective);
        if (effective.length <= 0) break;
        if (value) |v| {
            const font: c.CTFontRef = @ptrCast(@constCast(v));
            if (c.CTFontCreateCopyWithAttributes(font, c.CTFontGetSize(font) * factor, null, null)) |scaled| {
                defer c.CFRelease(scaled);
                setAttrFont(attr_str, at, effective.location + effective.length - at, scaled);
            }
        }
        at = effective.location + effective.length;
    }
}

/// sub: 75% size, baseline a quarter of the new size lower.
fn lower(attr_str: c.CFMutableAttributedStringRef, r: c.CFRange) void {
    scaleFonts(attr_str, r, 0.75);
    const value = c.CFAttributedStringGetAttribute(@ptrCast(attr_str), r.location, c.kCTFontAttributeName, null) orelse return;
    var offset: CGFloat = -0.25 * c.CTFontGetSize(@ptrCast(@constCast(value)));
    const number = c.CFNumberCreate(null, c.kCFNumberFloat64Type, &offset);
    defer c.CFRelease(number);
    c.CFAttributedStringSetAttribute(attr_str, r, c.kCTBaselineOffsetAttributeName, @ptrCast(number));
}
pub const break_line_height: CGFloat = 24;
