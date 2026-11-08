const std = @import("std");
const app = @import("../../main.zig");
const md = app.md;
const c = @import("c");
const lx = @import("../../linux.zig");

const Color = lx.Color;
const ImageBox = lx.ImageBox;
const col_stripe = lx.col_stripe;
const col_table_border = lx.col_table_border;
const col_text = lx.col_text;
const pad_len = lx.pad_len;
const cell_pad_y = lx.cell_pad_y;
const setInline = lx.setInline;
const setColor = lx.setColor;
const drawRoundedRect = lx.drawRoundedRect;
const mapStart = lx.mapStart;
const mapEnd = lx.mapEnd;
const leftMark = lx.leftMark;
const rightMark = lx.rightMark;
const unmap = lx.unmap;
const insertRange = lx.insertRange;
const imageBox = lx.imageBox;
const drawShape = lx.drawShape;
const renderFlowed = lx.renderFlowed;
const renderTextBlock = lx.renderTextBlock;
const renderTable = lx.renderTable;
const glyphX = lx.glyphX;
const imageLayoutSize = lx.imageLayoutSize;
const layoutBlocks = lx.layoutBlocks;
const resetBoxes = lx.resetBoxes;
const textIndexAt = lx.textIndexAt;

// ============================================================
// HTML floats and details
// ============================================================
pub const Beside = struct { left: f32 = 0, right: f32 = 0, bottom: f32 = 0 };

/// The floated images placed so far in one block run: how wide each side is taken and down to which y.
pub const Bands = struct {
    left_w: f32 = 0,
    left_bottom: f32 = 0,
    right_w: f32 = 0,
    right_bottom: f32 = 0,

    pub const Spot = struct { x: f32, y: f32 };

    /// CSS float stacking: a float goes beside the ones already on its side while there is room, else below them.
    pub fn place(b: *Bands, is_left: bool, x: f32, cw: f32, y: f32, w: f32, h: f32) Spot {
        const edge = if (is_left) &b.left_bottom else &b.right_bottom;
        const wide = if (is_left) &b.left_w else &b.right_w;
        if (edge.* <= y) wide.* = 0;
        var top = y;
        if (edge.* > y and wide.* + w + md.float_gap > cw) {
            top = edge.*;
            wide.* = 0;
        }
        const fx = if (is_left) x + wide.* else x + cw - wide.* - w;
        wide.* += w + md.float_gap;
        edge.* = @max(edge.*, top + h);
        return .{ .x = fx, .y = top };
    }

    pub fn at(b: Bands, y: f32) Beside {
        var out: Beside = .{};
        if (b.left_bottom > y) {
            out.left = b.left_w;
            out.bottom = b.left_bottom;
        }
        if (b.right_bottom > y) {
            out.right = b.right_w;
            out.bottom = @max(out.bottom, b.right_bottom);
        }
        return out;
    }
};

pub var sizing_float = false;
pub var measuring = false;
pub var nested: u32 = 0;
pub var extent: f32 = 0;
pub var splits: ?std.heap.ArenaAllocator = null;

pub fn resetSplits() void {
    if (splits) |*a| _ = a.reset(.free_all);
}

pub fn floatBox(im: *const md.Image, avail: f32) ?*ImageBox {
    sizing_float = true;
    defer sizing_float = false;
    return imageBox(im, avail);
}

pub fn drawBox(cr: *c.cairo_t, box: *ImageBox, x: f32, y: f32) void {
    var attr: c.PangoAttrShape = std.mem.zeroes(c.PangoAttrShape);
    attr.data = box;
    c.cairo_move_to(cr, x, y + box.h);
    drawShape(cr, &attr, 0, null);
}

pub fn blank(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isWhitespace(ch)) return false;
    }
    return true;
}

/// A paragraph that holds only floated images takes no room of its own.
pub fn floatOnly(content: md.Inline) bool {
    if (content.images.len == 0) return false;
    var pos: usize = 0;
    for (content.images) |im| {
        if (im.float == .none or im.start < pos or !blank(content.text[pos..im.start])) return false;
        pos = im.start + im.len;
    }
    return blank(content.text[pos..]);
}

pub fn placeFloats(cr: *c.cairo_t, block: *const md.Block, x: f32, cw: f32, y: f32, bands: *Bands) void {
    for (block.content.images) |*im| {
        if (im.float == .none) continue;
        const box = floatBox(im, cw) orelse continue;
        if (box.w <= 0) continue;
        const spot = bands.place(im.float == .left, x, cw, y, box.w, box.h);
        drawBox(cr, box, spot.x, spot.y);
        floatHit(im, block.content, spot.x, spot.y, box.w, box.h);
    }
}

/// A floated image takes no room in its text, so it gets its own hit: the image alone, inside its link if it has one.
fn floatHit(im: *const md.Image, content: md.Inline, x: f32, y: f32, w: f32, h: f32) void {
    if (measuring) return;
    if (splits == null) splits = .init(app.gpa);
    const a = splits.?.allocator();
    const image = a.alloc(md.Image, 1) catch return;
    image[0] = im.*;
    image[0].start = 0;
    image[0].float = .none;
    var links: []const md.Link = &.{};
    for (content.links) |l| {
        if (l.start <= im.start and l.start + l.len >= im.start + im.len) {
            const one = a.alloc(md.Link, 1) catch return;
            one[0] = l;
            one[0].start = 0;
            one[0].len = im.len;
            links = one;
            break;
        }
    }
    app.noteHit(.{ .content = .{ .text = content.text[im.start .. im.start + im.len], .images = image, .links = links }, .x = x, .y = y + app.scroll_y, .w = w, .h = h });
}

pub fn cutSpans(a: std.mem.Allocator, spans: []const md.Span, from: u32) ?[]md.Span {
    const out = a.alloc(md.Span, spans.len) catch return null;
    var n: usize = 0;
    for (spans) |s| {
        const end = s[0] + s[1];
        if (end <= from) continue;
        const start = @max(s[0], from);
        out[n] = .{ start - from, end - start };
        n += 1;
    }
    return out[0..n];
}

/// The text from byte `from` on, with every span moved to match; lives until the next frame.
pub fn cutFrom(content: md.Inline, from: u32) ?md.Inline {
    if (splits == null) splits = .init(app.gpa);
    const a = splits.?.allocator();
    var out = content;
    out.text = content.text[from..];
    out.bold = cutSpans(a, content.bold, from) orelse return null;
    out.italic = cutSpans(a, content.italic, from) orelse return null;
    out.strike = cutSpans(a, content.strike, from) orelse return null;
    out.code = cutSpans(a, content.code, from) orelse return null;
    out.emoji = cutSpans(a, content.emoji, from) orelse return null;
    out.sup = cutSpans(a, content.sup, from) orelse return null;

    const styles = a.alloc(md.Styled, content.styles.len) catch return null;
    var n: usize = 0;
    for (content.styles) |s| {
        const end = s.span[0] + s.span[1];
        if (end <= from) continue;
        const start = @max(s.span[0], from);
        styles[n] = .{ .span = .{ start - from, end - start }, .kind = s.kind };
        n += 1;
    }
    out.styles = styles[0..n];

    const links = a.alloc(md.Link, content.links.len) catch return null;
    n = 0;
    for (content.links) |l| {
        const end = l.start + l.len;
        if (end <= from) continue;
        const start = @max(l.start, from);
        links[n] = l;
        links[n].start = start - from;
        links[n].len = end - start;
        n += 1;
    }
    out.links = links[0..n];

    const images = a.alloc(md.Image, content.images.len) catch return null;
    n = 0;
    for (content.images) |im| {
        const end = im.start + im.len;
        if (end <= from) continue;
        const start = @max(im.start, from);
        images[n] = im;
        images[n].start = start - from;
        images[n].len = end - start;
        n += 1;
    }
    out.images = images[0..n];
    return out;
}

/// Text next to a float is laid out narrow; from the first line that starts below the float the rest is laid out at full width.
pub fn renderBeside(cr: *c.cairo_t, layout: *c.PangoLayout, content_in: md.Inline, x: f32, y: f32, w: f32, color: Color, font: [*:0]const u8, beside: Beside) f32 {
    const content = app.images.flow(content_in);
    const shrink = beside.left + beside.right;
    if (shrink <= 0) return renderFlowed(cr, layout, content, x, y, w, color, font);
    const nx = x + beside.left;
    const nw = @max(w - shrink, 60);
    const rel = beside.bottom - y;

    var lines: std.ArrayList(LineInfo) = .empty;
    defer lines.deinit(app.gpa);
    setInline(layout, content, nw, font);
    collectLines(layout, &lines);
    c.pango_layout_set_attributes(layout, null);
    var cut: ?LineInfo = null;
    for (lines.items) |ln| {
        if (ln.y >= rel - 0.5) {
            cut = ln;
            break;
        }
    }
    const at = cut orelse return renderFlowed(cr, layout, content, nx, y, nw, color, font);
    const rest = cutFrom(content, @intCast(unmap(padded(content).code, at.start))) orelse return renderFlowed(cr, layout, content, nx, y, nw, color, font);

    const hits_before = app.hits.items.len;
    c.cairo_save(cr);
    c.cairo_rectangle(cr, x, y, w, at.y);
    c.cairo_clip(cr);
    _ = renderFlowed(cr, layout, content, nx, y, nw, color, font);
    c.cairo_restore(cr);
    if (app.hits.items.len > hits_before) app.hits.items[hits_before].h = at.y;
    if (rest.text.len == 0) return at.y;
    return at.y + renderFlowed(cr, layout, rest, x, y + at.y, w, color, font);
}

pub fn drawSummaryMarker(cr: *c.cairo_t, layout: *c.PangoLayout, block: *const md.Block, x: f32, top: f32, h: f32, w: f32) void {
    var i = block.frames.len;
    while (i > 0) {
        i -= 1;
        const f = block.frames[i];
        if (f.kind != .details) continue;
        const cx = x - md.details_marker_inset + 6;
        const cy = top + @min(h, 20) / 2;
        setColor(cr, col_text);
        if (app.isOpen(f)) {
            c.cairo_move_to(cr, cx - 5, cy - 3);
            c.cairo_line_to(cr, cx + 5, cy - 3);
            c.cairo_line_to(cr, cx, cy + 4);
        } else {
            c.cairo_move_to(cr, cx - 3, cy - 5);
            c.cairo_line_to(cr, cx + 4, cy);
            c.cairo_line_to(cr, cx - 3, cy + 5);
        }
        c.cairo_close_path(cr);
        c.cairo_fill(cr);
        if (!measuring) noteSummaryToggles(layout, app.images.flow(block.content), f, x, top, w);
        return;
    }
}

/// The summary row toggles the details everywhere except on its links, which keep their own click.
fn noteSummaryToggles(layout: *c.PangoLayout, content: md.Inline, f: md.Frame, x: f32, top: f32, w: f32) void {
    var lines: std.ArrayList(LineInfo) = .empty;
    defer lines.deinit(app.gpa);
    var holes: std.ArrayList(StyleRect) = .empty;
    defer holes.deinit(app.gpa);
    setInline(layout, content, w, "Sans 12");
    collectLines(layout, &lines);
    const merged = padded(content);
    const spans = merged.code;
    const text_len = content.text.len + 2 * pad_len * spans.len;
    for (content.links) |l| lineXRanges(layout, lines.items, text_len, mapStart(spans, l.start), mapEnd(spans, l.start + l.len), false, &holes);
    c.pango_layout_set_attributes(layout, null);
    const edge = x - md.details_marker_inset - 4;
    for (lines.items, 0..) |ln, i| {
        var cursor: f32 = if (i == 0) edge else x;
        for (holes.items) |hole| {
            if (hole.y != ln.y) continue;
            if (x + hole.x > cursor) toggleRect(cursor, x + hole.x, top + ln.y, ln.height, f);
            cursor = @max(cursor, x + hole.x + hole.w);
        }
        if (x + w > cursor) toggleRect(cursor, x + w, top + ln.y, ln.height, f);
    }
}

fn toggleRect(from: f32, to: f32, y: f32, h: f32, f: md.Frame) void {
    app.noteToggle(.{ .x = from, .y = y + app.scroll_y, .w = to - from, .h = h }, f);
}

// ============================================================
// HTML styling
// ============================================================
pub var block_align: md.Align = .none;

pub const kbd_pad: c_int = 4 * c.PANGO_SCALE;

pub fn setAlign(layout: *c.PangoLayout, a: md.Align) void {
    c.pango_layout_set_alignment(layout, @intCast(switch (a) {
        .none, .left => c.PANGO_ALIGN_LEFT,
        .center => c.PANGO_ALIGN_CENTER,
        .right => c.PANGO_ALIGN_RIGHT,
    }));
}

pub fn kbdScale(desc: *const c.PangoFontDescription) f64 {
    const size: f64 = @floatFromInt(c.pango_font_description_get_size(desc));
    return @as(f64, md.kbd_font_px) * 0.75 * c.PANGO_SCALE / @max(size, 1);
}

pub fn isPadded(kind: md.StyleKind) bool {
    return kind == .kbd or kind == .tt;
}

pub fn startsBefore(_: void, a: md.Span, b: md.Span) bool {
    return a[0] < b[0];
}

/// `kbd` and `tt` ranges join the code spans, so they get the same placeholder padding; a span inside another is dropped.
pub fn padded(content: md.Inline) md.Inline {
    var extra: usize = 0;
    for (content.styles) |s| {
        if (isPadded(s.kind) and s.span[1] > 0) extra += 1;
    }
    if (extra == 0) return content;
    if (lx.boxes == null) lx.boxes = .init(app.gpa);
    const all = lx.boxes.?.allocator().alloc(md.Span, content.code.len + extra) catch return content;
    var n: usize = 0;
    for (content.code) |s| {
        all[n] = s;
        n += 1;
    }
    for (content.styles) |s| {
        if (isPadded(s.kind) and s.span[1] > 0) {
            all[n] = s.span;
            n += 1;
        }
    }
    std.mem.sort(md.Span, all[0..n], {}, startsBefore);
    var kept: usize = 0;
    var end: u32 = 0;
    for (all[0..n]) |s| {
        if (kept > 0 and s[0] < end) continue;
        all[kept] = s;
        kept += 1;
        end = s[0] + s[1];
    }
    var out = content;
    out.code = all[0..kept];
    return out;
}

pub fn isKbd(content: md.Inline, span: md.Span) bool {
    for (content.styles) |s| {
        if (s.kind == .kbd and s.span[0] == span[0] and s.span[1] == span[1]) return true;
    }
    return false;
}

pub fn applyStyles(attr_list: *c.PangoAttrList, content: md.Inline, spans: []const md.Span, desc: *const c.PangoFontDescription) void {
    const size: f64 = @floatFromInt(c.pango_font_description_get_size(desc));
    for (content.styles) |s| {
        const start = mapStart(spans, s.span[0]);
        const end = mapEnd(spans, s.span[0] + s.span[1]);
        switch (s.kind) {
            .sub => {
                insertRange(attr_list, c.pango_attr_scale_new(0.75), start, end);
                insertRange(attr_list, c.pango_attr_rise_new(-@as(c_int, @intFromFloat(size * 0.2))), start, end);
            },
            .underline => insertRange(attr_list, c.pango_attr_underline_new(c.PANGO_UNDERLINE_SINGLE), start, end),
            .mark => {
                insertRange(attr_list, c.pango_attr_background_new(0xbbbb, 0x8080, 0x0909), start, end);
                insertRange(attr_list, c.pango_attr_background_alpha_new(0x2626), start, end);
            },
            .kbd, .tt => {},
        }
    }
}

pub const LineInfo = struct { start: usize, y: f32, height: f32, baseline: f32 };

pub fn collectLines(layout: *c.PangoLayout, out: *std.ArrayList(LineInfo)) void {
    const iter = c.pango_layout_get_iter(layout) orelse return;
    defer c.pango_layout_iter_free(iter);
    const scale: f32 = c.PANGO_SCALE;
    while (true) {
        var logical: c.PangoRectangle = std.mem.zeroes(c.PangoRectangle);
        c.pango_layout_iter_get_line_extents(iter, null, &logical);
        out.append(app.gpa, .{
            .start = @intCast(c.pango_layout_iter_get_index(iter)),
            .y = @as(f32, @floatFromInt(logical.y)) / scale,
            .height = @as(f32, @floatFromInt(logical.height)) / scale,
            .baseline = @as(f32, @floatFromInt(c.pango_layout_iter_get_baseline(iter))) / scale,
        }) catch return;
        if (c.pango_layout_iter_next_line(iter) == 0) break;
    }
}

/// A key cap box in layout pixels.
pub const StyleRect = struct { x: f32, y: f32, w: f32, h: f32, baseline: f32, kbd: bool };

pub fn lineXRanges(layout: *c.PangoLayout, lines: []const LineInfo, text_len: usize, from: usize, to: usize, kbd: bool, out: *std.ArrayList(StyleRect)) void {
    const scale: f32 = c.PANGO_SCALE;
    for (lines, 0..) |box, index| {
        const line_end: usize = if (index + 1 < lines.len) lines[index + 1].start else text_len;
        const a = @max(from, box.start);
        const b = @min(to, line_end);
        if (a >= b) continue;
        const line = c.pango_layout_get_line_readonly(layout, @intCast(index)) orelse continue;
        var found: ?[*]c_int = null;
        var n: c_int = 0;
        c.pango_layout_line_get_x_ranges(line, @intCast(a), @intCast(b), &found, &n);
        const ranges = found orelse continue;
        defer c.g_free(@ptrCast(ranges));
        var left: f32 = std.math.floatMax(f32);
        var right: f32 = 0;
        for (0..@as(usize, @intCast(n))) |i| {
            left = @min(left, @as(f32, @floatFromInt(ranges[i * 2])) / scale);
            right = @max(right, @as(f32, @floatFromInt(ranges[i * 2 + 1])) / scale);
        }
        if (right <= left) continue;
        out.append(app.gpa, .{ .x = left, .y = box.y, .w = right - left, .h = box.height, .baseline = box.baseline, .kbd = kbd }) catch return;
    }
}

pub fn needsRects(content: md.Inline) bool {
    for (content.styles) |s| {
        if (s.kind == .kbd) return true;
    }
    return false;
}

pub fn styleRects(layout: *c.PangoLayout, content_in: md.Inline, out: *std.ArrayList(StyleRect)) void {
    const content = padded(content_in);
    const spans = content.code;
    var lines: std.ArrayList(LineInfo) = .empty;
    defer lines.deinit(app.gpa);
    collectLines(layout, &lines);
    const text_len = content.text.len + 2 * pad_len * spans.len;
    for (spans, 0..) |span, k| {
        if (!isKbd(content_in, span)) continue;
        lineXRanges(layout, lines.items, text_len, leftMark(spans, k), rightMark(spans, k) + pad_len, true, out);
    }
}

pub fn drawStyleRects(cr: *c.cairo_t, layout: *c.PangoLayout, content: md.Inline, x: f32, y: f32) void {
    if (!needsRects(content)) return;
    var rects: std.ArrayList(StyleRect) = .empty;
    defer rects.deinit(app.gpa);
    styleRects(layout, content, &rects);
    for (rects.items) |r| {
        if (r.kbd) {
            const box = kbdBox(r);
            const top = y + box[0];
            const h = box[1];
            setColor(cr, col_stripe);
            drawRoundedRect(cr, x + r.x, top, r.w, h, 6);
            c.cairo_fill(cr);
            setColor(cr, col_table_border);
            c.cairo_set_line_width(cr, 1);
            drawRoundedRect(cr, x + r.x + 0.5, top + 0.5, r.w - 1, h - 1, 5.5);
            c.cairo_stroke(cr);
            c.cairo_rectangle(cr, x + r.x + 3, top + h - 2, r.w - 6, 1);
            c.cairo_fill(cr);
        }
    }
}

pub fn naturalSize(target: []const u8) app.images.Size {
    return switch (app.images.look(target, 1.0e9)) {
        .picture => |s| s,
        else => .{ .w = 0, .h = 0 },
    };
}


const Probe = struct {
    surface: *c.cairo_surface_t,
    cr: *c.cairo_t,
    layout: *c.PangoLayout,

    fn init(w: c_int, h: c_int) !Probe {
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h) orelse return error.NoSurface;
        errdefer c.cairo_surface_destroy(surface);
        const cr = c.cairo_create(surface) orelse return error.NoContext;
        errdefer c.cairo_destroy(cr);
        const layout = c.pango_cairo_create_layout(cr) orelse return error.NoLayout;
        return .{ .surface = surface, .cr = cr, .layout = layout };
    }

    fn deinit(p: Probe) void {
        c.g_object_unref(p.layout);
        c.cairo_destroy(p.cr);
        c.cairo_surface_destroy(p.surface);
    }
};

fn attrAt(layout: *c.PangoLayout, index: c_int, kind: c.PangoAttrType) ?*c.PangoAttribute {
    const list = c.pango_layout_get_attributes(layout) orelse return null;
    const iter = c.pango_attr_list_get_iterator(list) orelse return null;
    defer c.pango_attr_iterator_destroy(iter);
    while (true) {
        var start: c_int = 0;
        var end: c_int = 0;
        c.pango_attr_iterator_range(iter, &start, &end);
        if (index >= start and index < end) return c.pango_attr_iterator_get(iter, kind);
        if (c.pango_attr_iterator_next(iter) == 0) return null;
    }
}

test "alignment places the first glyph within the layout width" {
    app.gpa = std.testing.allocator;
    const p = try Probe.init(400, 100);
    defer p.deinit();
    setInline(p.layout, .{ .text = "hi" }, 400, "Sans 12");
    setAlign(p.layout, .left);
    const left = glyphX(p.layout, 0).x;
    setAlign(p.layout, .center);
    const center = glyphX(p.layout, 0).x;
    setAlign(p.layout, .right);
    const right = glyphX(p.layout, 0).x;
    try std.testing.expectEqual(@as(c_int, 0), left);
    try std.testing.expect(center > 150 * c.PANGO_SCALE);
    try std.testing.expect(right > center + 100 * c.PANGO_SCALE);
}

test "a centred block keeps its alignment in the hit and is hit where it is drawn" {
    app.gpa = std.heap.page_allocator;
    defer app.hits.clearAndFree(app.gpa);
    app.hits.clearRetainingCapacity();
    const p = try Probe.init(400, 100);
    defer p.deinit();
    const content: md.Inline = .{ .text = "hi", .links = &.{.{ .start = 0, .len = 2, .target = "x" }} };
    block_align = .center;
    defer block_align = .none;
    const h = renderTextBlock(p.cr, p.layout, content, 0, 0, 400, col_text, "Sans 12");
    try std.testing.expectEqual(@as(usize, 1), app.hits.items.len);
    const hit = app.hits.items[0];
    try std.testing.expectEqual(md.Align.center, hit.alignment);
    try std.testing.expect(textIndexAt(hit, 2, h / 2) == null);
    try std.testing.expect(textIndexAt(hit, 195, h / 2) != null);
}

test "kbd is padded like code and drawn as one box" {
    app.gpa = std.testing.allocator;
    defer resetBoxes();
    const content: md.Inline = .{ .text = "press Ctrl now", .styles = &.{.{ .span = .{ 6, 4 }, .kind = .kbd }} };
    const merged = padded(content);
    try std.testing.expectEqual(@as(usize, 1), merged.code.len);
    try std.testing.expect(isKbd(content, merged.code[0]));
    try std.testing.expectEqual(@as(usize, 11), unmap(merged.code, mapEnd(merged.code, 11)));

    const p = try Probe.init(400, 100);
    defer p.deinit();
    setInline(p.layout, content, 400, "Sans 12");
    var rects: std.ArrayList(StyleRect) = .empty;
    defer rects.deinit(std.testing.allocator);
    styleRects(p.layout, content, &rects);
    try std.testing.expectEqual(@as(usize, 1), rects.items.len);
    try std.testing.expect(rects.items[0].kbd);
    try std.testing.expect(rects.items[0].w > 20 and rects.items[0].w < 80);
    try std.testing.expect(rects.items[0].h > 8);
}

test "sub, underline and mark set their Pango attributes on their own range only" {
    app.gpa = std.testing.allocator;
    defer resetBoxes();
    const content: md.Inline = .{
        .text = "a1b2c3d4e",
        .styles = &.{
            .{ .span = .{ 1, 1 }, .kind = .sub },
            .{ .span = .{ 5, 1 }, .kind = .underline },
            .{ .span = .{ 7, 1 }, .kind = .mark },
        },
    };
    const p = try Probe.init(400, 100);
    defer p.deinit();
    setInline(p.layout, content, 400, "Sans 12");

    const rise: *c.PangoAttrInt = @ptrCast(@alignCast(attrAt(p.layout, 1, c.PANGO_ATTR_RISE) orelse return error.TestUnexpectedResult));
    try std.testing.expect(rise.value < 0);
    try std.testing.expect(attrAt(p.layout, 0, c.PANGO_ATTR_RISE) == null);
    try std.testing.expect(attrAt(p.layout, 2, c.PANGO_ATTR_RISE) == null);

    const line: *c.PangoAttrInt = @ptrCast(@alignCast(attrAt(p.layout, 5, c.PANGO_ATTR_UNDERLINE) orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(c_int, c.PANGO_UNDERLINE_SINGLE), line.value);
    try std.testing.expect(attrAt(p.layout, 6, c.PANGO_ATTR_UNDERLINE) == null);

    const back: *c.PangoAttrColor = @ptrCast(@alignCast(attrAt(p.layout, 7, c.PANGO_ATTR_BACKGROUND) orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u16, 0xbbbb), back.color.red);
    try std.testing.expect(attrAt(p.layout, 8, c.PANGO_ATTR_BACKGROUND) == null);
}

test "an image with a width attribute is laid out at that width" {
    app.gpa = std.testing.allocator;
    app.images.init(std.testing.allocator, std.testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetBoxes();
    try app.images.injectReady("wide.png", 1000, 500);
    var doc = try md.parse(std.testing.allocator, "![w](wide.png)");
    defer doc.deinit();
    var content = doc.blocks[0].content;
    var im = content.images[0];
    im.width = 200;
    const sized = [_]md.Image{im};
    content.images = &sized;
    const size = try imageLayoutSize(content, 600);
    try std.testing.expect(size[0] >= 199 and size[0] < 215);
    try std.testing.expect(size[1] >= 100 and size[1] < 130);
}

test "a closed details skips its content and its marker toggles it" {
    app.gpa = std.heap.page_allocator;
    defer app.details_open.clearAndFree(app.gpa);
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const frames = [_]md.Frame{.{ .kind = .details, .key = 77 }};
    const blocks = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "Summary" }, .frames = &frames, .role = .summary },
        .{ .kind = .paragraph, .content = .{ .text = "Body" }, .frames = &frames },
        .{ .kind = .paragraph, .content = .{ .text = "After" } },
    };
    const p = try Probe.init(600, 600);
    defer p.deinit();

    app.block_y.clearRetainingCapacity();
    const closed = layoutBlocks(p.cr, p.layout, &blocks, 40, 500, 10);
    try std.testing.expectEqual(@as(usize, 3), app.block_y.items.len);
    try std.testing.expectEqual(app.block_y.items[1], app.block_y.items[2]);
    try std.testing.expect(!app.isOpen(frames[0]));

    try std.testing.expect(app.mouseDown(30, 18));
    try std.testing.expect(app.isOpen(frames[0]));
    app.block_y.clearRetainingCapacity();
    const opened = layoutBlocks(p.cr, p.layout, &blocks, 40, 500, 10);
    try std.testing.expect(opened > closed + 20);
    try std.testing.expect(app.block_y.items[2] > app.block_y.items[1] + 15);
}

fn floatBlocks(comptime side: []const u8) [2]md.Block {
    const long = comptime blk: {
        var text: []const u8 = "first words ";
        for (0..60) |_| text = text ++ "lorem ipsum dolor sit amet ";
        break :blk text ++ "last";
    };
    const image = comptime md.Image{ .start = 0, .len = 3, .target = "logo.png", .float = if (std.mem.eql(u8, side, "left")) .left else .right };
    return .{
        .{ .kind = .paragraph, .content = .{ .text = "\u{fffc}", .images = &.{image} } },
        .{ .kind = .paragraph, .content = .{ .text = long, .links = &.{
            .{ .start = 0, .len = 5, .target = "a" },
            .{ .start = long.len - 4, .len = 4, .target = "b" },
        } } },
    };
}

fn expectBeside(comptime side: []const u8, first_x: f32) !void {
    app.gpa = std.heap.page_allocator;
    app.images.init(std.testing.allocator, std.testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetBoxes();
    defer resetSplits();
    defer app.hits.clearAndFree(app.gpa);
    defer app.block_y.clearAndFree(app.gpa);
    try app.images.injectReady("logo.png", 100, 300);
    const blocks = floatBlocks(side);
    const p = try Probe.init(800, 800);
    defer p.deinit();
    app.hits.clearRetainingCapacity();
    app.block_y.clearRetainingCapacity();
    _ = layoutBlocks(p.cr, p.layout, &blocks, 0, 600, 0);

    try std.testing.expectEqual(@as(f32, 0), app.block_y.items[1]);
    try std.testing.expectEqual(@as(usize, 2), app.hits.items.len);
    const first = app.hits.items[0];
    const rest = app.hits.items[1];
    try std.testing.expectApproxEqAbs(first_x, first.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 480), first.w, 0.01);
    try std.testing.expect(first.h >= 300 and first.h < 330);
    try std.testing.expectEqual(@as(f32, 0), rest.x);
    try std.testing.expectEqual(@as(f32, 600), rest.w);
    try std.testing.expectApproxEqAbs(first.y + first.h, rest.y, 0.01);
    try std.testing.expect(rest.content.text.len < blocks[1].content.text.len);
    try std.testing.expectEqual(@as(usize, 1), rest.content.links.len);
    const float_line = try imageLayoutSize(blocks[0].content, 600);
    try std.testing.expect(float_line[1] < 40);
}

test "text beside a left float is narrow until the float ends, then full width" {
    try expectBeside("left", 120);
}

test "text beside a right float keeps its left edge" {
    try expectBeside("right", 0);
}

test "a colspan cell spreads over its columns and a rowspan cell over its rows" {
    app.gpa = std.heap.page_allocator;
    defer resetBoxes();
    const p = try Probe.init(800, 800);
    defer p.deinit();

    const wide = [_]md.Inline{ .{ .text = "a header cell that is quite wide" }, .{}, .{ .text = "b" }, .{ .text = "c" } };
    const plain: md.Table = .{ .columns = 2, .aligns = &.{ .none, .none }, .cells = &wide };
    var spanned = plain;
    const col_ext: md.Table.Extra = .{ .spans = &.{ .{ 2, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 1 } } };
    spanned.ext = &col_ext;
    var plain_w: f32 = 0;
    var spanned_w: f32 = 0;
    const plain_h = renderTable(p.cr, p.layout, plain, 0, 0, 700, false, &plain_w);
    const spanned_h = renderTable(p.cr, p.layout, spanned, 0, 0, 700, false, &spanned_w);
    try std.testing.expectApproxEqAbs(plain_h, spanned_h, 1);
    try std.testing.expect(spanned_w < plain_w - 5);

    const tall = [_]md.Inline{ .{ .text = "x\ny\nz" }, .{ .text = "p" }, .{}, .{ .text = "q" } };
    const plain_rows: md.Table = .{ .columns = 2, .aligns = &.{ .none, .none }, .cells = &tall };
    var spanned_rows = plain_rows;
    const row_ext: md.Table.Extra = .{ .spans = &.{ .{ 1, 2 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 } } };
    spanned_rows.ext = &row_ext;
    const rows_plain = renderTable(p.cr, p.layout, plain_rows, 0, 0, 700, false, null);
    const rows_spanned = renderTable(p.cr, p.layout, spanned_rows, 0, 0, 700, false, null);
    try std.testing.expect(rows_spanned < rows_plain - 15);
}

test "valign places a cell's text at the top, middle or bottom of its row" {
    app.gpa = std.heap.page_allocator;
    defer app.hits.clearAndFree(app.gpa);
    defer resetBoxes();
    const p = try Probe.init(800, 800);
    defer p.deinit();
    const link: md.Link = .{ .start = 0, .len = 1, .target = "x" };
    const cells = [_]md.Inline{ .{ .text = "a\nb\nc" }, .{ .text = "k", .links = &.{link} } };
    var t: md.Table = .{ .columns = 2, .aligns = &.{ .none, .none }, .cells = &cells, .header_row = false };
    var tops: [3]f32 = undefined;
    for ([_]md.VAlign{ .top, .middle, .bottom }, 0..) |v, i| {
        const valigns = [_]md.VAlign{ .none, v };
        const ext: md.Table.Extra = .{ .spans = &.{ .{ 1, 1 }, .{ 1, 1 } }, .valigns = &valigns };
        t.ext = &ext;
        app.hits.clearRetainingCapacity();
        _ = renderTable(p.cr, p.layout, t, 0, 0, 700, true, null);
        tops[i] = app.hits.items[0].y;
    }
    try std.testing.expectApproxEqAbs(cell_pad_y, tops[0], 0.01);
    try std.testing.expect(tops[1] > tops[0] + 10);
    try std.testing.expect(tops[2] > tops[1] + 10);
}

pub const Measured = struct { w: f32, h: f32 };

/// Lays `blocks` out on a scratch surface to learn their natural width (at `width`) and height, noting nothing.
pub fn measureBlocks(layout: *c.PangoLayout, blocks: []const md.Block, width: f32) Measured {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) orelse return .{ .w = 0, .h = 0 };
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return .{ .w = 0, .h = 0 };
    defer c.cairo_destroy(cr);
    const saved = .{ measuring, extent, block_align };
    measuring = true;
    extent = 0;
    defer {
        measuring = saved[0];
        extent = saved[1];
        block_align = saved[2];
    }
    const y = layoutBlocks(cr, layout, blocks, 0, width, 0);
    return .{ .w = extent, .h = y };
}

pub fn noteHit(hit: app.Hit) void {
    if (!measuring) app.noteHit(hit);
}

pub fn kbdBox(r: StyleRect) [2]f32 {
    return .{ r.baseline - 4.5 - kbd_box_h / 2, kbd_box_h };
}

pub const kbd_box_h: f32 = 20;
pub const break_line_h: f32 = 24;

/// A block of only line breaks is one 24px line per break.
pub fn breakLinesHeight(content: md.Inline) f32 {
    return break_line_h * @as(f32, @floatFromInt(std.mem.count(u8, content.text, "\n")));
}

test "a cell holds blocks laid out inside it and not noted as top-level blocks" {
    app.gpa = std.heap.page_allocator;
    defer app.hits.clearAndFree(app.gpa);
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const p = try Probe.init(800, 800);
    defer p.deinit();
    const link: md.Link = .{ .start = 0, .len = 3, .target = "x" };
    const one = [_]md.Block{.{ .kind = .paragraph, .content = .{ .text = "one", .links = &.{link} } }};
    const two = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "one", .links = &.{link} } },
        .{ .kind = .paragraph, .content = .{ .text = "two" } },
    };
    const cells = [_]md.Inline{ .{}, .{} };
    const with_one = [_][]const md.Block{ &one, &.{} };
    const with_two = [_][]const md.Block{ &two, &.{} };
    const ext_one: md.Table.Extra = .{ .cell_blocks = &with_one };
    const ext_two: md.Table.Extra = .{ .cell_blocks = &with_two };
    var t: md.Table = .{ .columns = 2, .aligns = &.{ .none, .none }, .cells = &cells, .header_row = false, .ext = &ext_one };

    app.hits.clearRetainingCapacity();
    app.block_y.clearRetainingCapacity();
    const h_one = renderTable(p.cr, p.layout, t, 0, 0, 700, true, null);
    try std.testing.expectEqual(@as(usize, 1), app.hits.items.len);
    try std.testing.expect(app.hits.items[0].x >= 13 and app.hits.items[0].y >= 6);
    try std.testing.expectEqual(@as(usize, 0), app.block_y.items.len);
    t.ext = &ext_two;
    const h_two = renderTable(p.cr, p.layout, t, 0, 0, 700, false, null);
    try std.testing.expect(h_two > h_one + 15);
}

test "a nested table inside a cell block sets the cell width" {
    app.gpa = std.heap.page_allocator;
    defer resetBoxes();
    const p = try Probe.init(800, 800);
    defer p.deinit();
    const inner_cells = [_]md.Inline{ .{ .text = "a fairly wide inner cell" }, .{ .text = "b" } };
    const inner: md.Table = .{ .columns = 2, .aligns = &.{ .none, .none }, .cells = &inner_cells };
    const holder = [_]md.Block{.{ .kind = .table, .table = inner }};
    const measured = measureFlat(p.layout, &holder);
    var inner_w: f32 = 0;
    _ = renderTable(p.cr, p.layout, inner, 0, 0, 100000, false, &inner_w);
    try std.testing.expectApproxEqAbs(inner_w, measured.w, 1);
    try std.testing.expect(measured.h > 20);
}

fn measureFlat(layout: *c.PangoLayout, blocks: []const md.Block) Measured {
    return measureBlocks(layout, blocks, 100000);
}

test "a floated image inside a link is clickable and a second float sits beside the first" {
    app.gpa = std.heap.page_allocator;
    app.images.init(std.testing.allocator, std.testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer resetBoxes();
    defer resetSplits();
    defer app.hits.clearAndFree(app.gpa);
    defer app.block_y.clearAndFree(app.gpa);
    try app.images.injectReady("a.png", 100, 50);
    try app.images.injectReady("b.png", 80, 50);
    const text = "\u{fffc}\u{fffc}";
    const images = [_]md.Image{
        .{ .start = 0, .len = 3, .target = "a.png", .title = "first", .float = .left },
        .{ .start = 3, .len = 3, .target = "b.png", .title = "second", .float = .left },
    };
    const links = [_]md.Link{.{ .start = 0, .len = 3, .target = "https://example.com/a" }};
    const blocks = [_]md.Block{.{ .kind = .paragraph, .content = .{ .text = text, .images = &images, .links = &links } }};
    const p = try Probe.init(800, 800);
    defer p.deinit();
    app.hits.clearRetainingCapacity();
    _ = layoutBlocks(p.cr, p.layout, &blocks, 0, 600, 0);

    try std.testing.expectEqual(@as(usize, 2), app.hits.items.len);
    const first = app.hits.items[0];
    const second = app.hits.items[1];
    try std.testing.expectEqual(@as(f32, 0), first.x);
    try std.testing.expectEqual(@as(f32, 100), first.w);
    try std.testing.expectEqual(@as(f32, 50), first.h);
    try std.testing.expectEqual(@as(f32, 120), second.x);
    try std.testing.expectEqual(first.y, second.y);
    const index = textIndexAt(first, 50, 25) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.content.linkAt(index) != null);
    try std.testing.expectEqualStrings("first", first.content.imageAt(index).?.title);
    try std.testing.expect(second.content.linkAt(textIndexAt(second, 40, 25) orelse return error.TestUnexpectedResult) == null);
}

test "a link in a summary keeps its click and the rest of the row toggles" {
    app.gpa = std.heap.page_allocator;
    defer app.details_open.clearAndFree(app.gpa);
    defer app.hits.clearAndFree(app.gpa);
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const frames = [_]md.Frame{.{ .kind = .details, .key = 91 }};
    const links = [_]md.Link{.{ .start = 0, .len = 4, .target = "https://example.com" }};
    const blocks = [_]md.Block{.{ .kind = .paragraph, .content = .{ .text = "link then more words", .links = &links }, .frames = &frames, .role = .summary }};
    const p = try Probe.init(600, 600);
    defer p.deinit();
    app.hits.clearRetainingCapacity();
    _ = layoutBlocks(p.cr, p.layout, &blocks, 40, 500, 300);

    try std.testing.expect(app.mouseDown(45, 308));
    try std.testing.expect(!app.isOpen(frames[0]));
    try std.testing.expect(app.mouseDown(400, 308));
    try std.testing.expect(app.isOpen(frames[0]));
    try std.testing.expect(app.mouseDown(30, 308));
    try std.testing.expect(!app.isOpen(frames[0]));
}

test "the kbd box is centred on the middle of the lower-case letters" {
    const box = kbdBox(.{ .x = 0, .y = 0, .w = 10, .h = 19, .baseline = 15, .kbd = true });
    try std.testing.expectEqual(kbd_box_h, box[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 15 - 4.5), box[0] + box[1] / 2, 0.01);
}

test "a rule is 4px with 24px margins that collapse into the paragraph gap" {
    app.gpa = std.heap.page_allocator;
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const blocks = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "above" } },
        .{ .kind = .hr },
        .{ .kind = .paragraph, .content = .{ .text = "below" } },
    };
    const p = try Probe.init(600, 600);
    defer p.deinit();
    app.block_y.clearRetainingCapacity();
    _ = layoutBlocks(p.cr, p.layout, &blocks, 0, 500, 0);
    try std.testing.expectEqual(@as(usize, 3), app.block_y.items.len);
    try std.testing.expectApproxEqAbs(md.hr_margin - 16 + md.hr_height + md.hr_margin, app.block_y.items[2] - app.block_y.items[1], 0.01);
}

test "a block of line breaks is one 24px line per break with no gap after" {
    app.gpa = std.heap.page_allocator;
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const blocks = [_]md.Block{
        .{ .kind = .paragraph, .content = .{ .text = "above" } },
        .{ .kind = .paragraph, .role = .break_lines, .content = .{ .text = "\n\n\n" } },
        .{ .kind = .paragraph, .content = .{ .text = "below" } },
    };
    const p = try Probe.init(600, 600);
    defer p.deinit();
    app.block_y.clearRetainingCapacity();
    _ = layoutBlocks(p.cr, p.layout, &blocks, 0, 500, 0);
    try std.testing.expectEqual(@as(usize, 3), app.block_y.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 72), app.block_y.items[2] - app.block_y.items[1], 0.01);
}

test "an empty block has no height and is followed by the usual 16px gap" {
    app.gpa = std.heap.page_allocator;
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const blocks = [_]md.Block{
        .{ .kind = .paragraph, .role = .empty },
        .{ .kind = .paragraph, .content = .{ .text = "after" } },
    };
    const p = try Probe.init(600, 600);
    defer p.deinit();
    app.block_y.clearRetainingCapacity();
    _ = layoutBlocks(p.cr, p.layout, &blocks, 0, 500, 0);
    try std.testing.expectEqual(@as(usize, 2), app.block_y.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 16), app.block_y.items[1] - app.block_y.items[0], 0.01);
}

test "a table with align right floats and the text beside it is narrower" {
    app.gpa = std.heap.page_allocator;
    defer app.hits.clearAndFree(app.gpa);
    defer app.block_y.clearAndFree(app.gpa);
    defer resetBoxes();
    const cells = [_]md.Inline{ .{ .text = "one" }, .{ .text = "two" } };
    const table: md.Table = .{ .columns = 2, .aligns = &.{ .none, .none }, .cells = &cells, .header_row = false, .float = .right };
    const link: md.Link = .{ .start = 0, .len = 4, .target = "x" };
    const blocks = [_]md.Block{
        .{ .kind = .table, .table = table },
        .{ .kind = .paragraph, .content = .{ .text = "text beside", .links = &.{link} } },
    };
    const p = try Probe.init(800, 800);
    defer p.deinit();
    app.hits.clearRetainingCapacity();
    app.block_y.clearRetainingCapacity();
    var table_w: f32 = 0;
    _ = renderTable(p.cr, p.layout, table, 0, 0, 600, false, &table_w);
    _ = layoutBlocks(p.cr, p.layout, &blocks, 0, 600, 0);
    try std.testing.expectEqual(@as(f32, 0), app.block_y.items[1]);
    try std.testing.expectEqual(@as(usize, 1), app.hits.items.len);
    try std.testing.expectEqual(@as(f32, 0), app.hits.items[0].x);
    try std.testing.expectApproxEqAbs(600 - table_w - md.float_gap, app.hits.items[0].w, 0.01);
}
