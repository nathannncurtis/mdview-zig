const std = @import("std");
const win = @import("../../win32.zig");
const app = @import("../../main.zig");
const md = app.md;
const alerts = @import("../../alerts.zig");
const tables = @import("tables.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const testing = std.testing;

pub fn hasStyle(content: md.Inline, kind: md.StyleKind) bool {
    for (content.styles) |s| if (s.kind == kind) return true;
    return false;
}

pub fn drawStyleBackgrounds(vt_rt: *const win.ID2D1RT_VTable, rt: *anyopaque, lay: *anyopaque, x: f32, y: f32, content: md.Inline) void {
    var rects: std.ArrayList(win.D2D1_RECT_F) = .empty;
    defer rects.deinit(app.gpa);
    for (content.styles) |s| {
        rects.clearRetainingCapacity();
        switch (s.kind) {
            .mark, .kbd, .tt => {},
            else => continue,
        }
        win.rangeRects(lay, win.wideRange(content.text, s.span), &rects) catch return;
        for (rects.items) |r| {
            const rect: win.D2D1_RECT_F = .{ .left = x + r.left, .top = y + r.top, .right = x + r.right, .bottom = y + r.bottom };
            switch (s.kind) {
                .mark => if (win.g_brush_mark_bg) |b| vt_rt.FillRectangle(rt, &rect, b),
                .tt => if (win.g_brush_code_span) |b| vt_rt.FillRoundedRectangle(rt, &.{ .rect = rect, .radiusX = md.code_radius, .radiusY = md.code_radius }, b),
                .kbd => drawKbdBox(vt_rt, rt, rect),
                else => {},
            }
        }
    }
}

fn drawKbdBox(vt_rt: *const win.ID2D1RT_VTable, rt: *anyopaque, r: win.D2D1_RECT_F) void {
    const border = win.g_brush_table_border orelse return;
    const fill = win.g_brush_stripe orelse return;
    const mid = (r.top + r.bottom) / 2;
    const top = mid - win.kbd_box_h / 2;
    const bottom = mid + win.kbd_box_h / 2;
    vt_rt.FillRoundedRectangle(rt, &.{ .rect = .{ .left = r.left, .top = top, .right = r.right, .bottom = bottom }, .radiusX = win.kbd_radius, .radiusY = win.kbd_radius }, border);
    vt_rt.FillRoundedRectangle(rt, &.{ .rect = .{ .left = r.left + 1, .top = top + 1, .right = r.right - 1, .bottom = bottom - 1 }, .radiusX = win.kbd_radius - 1, .radiusY = win.kbd_radius - 1 }, fill);
    vt_rt.FillRectangle(rt, &.{ .left = r.left + 3, .top = bottom - 2, .right = r.right - 3, .bottom = bottom - 1 }, border);
}

const Side = enum { left, right };

/// A float: blocks beside it keep clear of `edge` (its inner edge plus the gap) from `top` to `bottom`.
const FloatBox = struct { side: Side, edge: f32, top: f32, bottom: f32 };

const max_floats = 16;

const Region = struct { x: f32, w: f32 };

const Floats = struct {
    items: [max_floats]FloatBox = @splat(.{ .side = .left, .edge = 0, .top = 0, .bottom = 0 }),
    len: usize = 0,

    fn active(f: FloatBox, y: f32) bool {
        return f.top <= y and y < f.bottom;
    }

    fn limits(s: *const Floats, y: f32, bx: f32, bw: f32) Region {
        var left = bx;
        var right = bx + bw;
        for (s.items[0..s.len]) |f| {
            if (!active(f, y)) continue;
            switch (f.side) {
                .left => left = @max(left, f.edge),
                .right => right = @min(right, f.edge),
            }
        }
        return .{ .x = left, .w = right - left };
    }

    fn region(s: *const Floats, y: f32, bx: f32, bw: f32) Region {
        const r = s.limits(y, bx, bw);
        return .{ .x = r.x, .w = @max(r.w, 60) };
    }

    /// The next y below `y` where a float starts or ends.
    fn change(s: *const Floats, y: f32) ?f32 {
        var best: ?f32 = null;
        for (s.items[0..s.len]) |f| {
            for ([_]f32{ f.top, f.bottom }) |edge| {
                if (edge > y and (best == null or edge < best.?)) best = edge;
            }
        }
        return best;
    }

    /// Moves `y` down until a region at least `need` wide is free.
    fn clear(s: *const Floats, y_in: f32, bx: f32, bw: f32, need: f32) f32 {
        var y = y_in;
        while (s.limits(y, bx, bw).w < need) y = s.change(y) orelse return y;
        return y;
    }

    fn anyActive(s: *const Floats, y: f32) bool {
        for (s.items[0..s.len]) |f| if (active(f, y)) return true;
        return false;
    }

    /// Places a float `size` big at the first y at or below `y` where it fits, and returns its top left.
    fn place(s: *Floats, side: Side, size: Extent, y_in: f32, bx: f32, bw: f32) struct { x: f32, y: f32 } {
        var y = y_in;
        var x: f32 = bx;
        while (true) {
            const r = s.limits(y, bx, bw);
            x = if (side == .left) r.x else r.x + r.w - size.w;
            if (size.w <= r.w or !s.anyActive(y)) break;
            y = s.change(y) orelse break;
        }
        if (s.len < max_floats) {
            s.items[s.len] = .{
                .side = side,
                .edge = if (side == .left) x + size.w + md.float_gap else x - md.float_gap,
                .top = y,
                .bottom = y + size.h,
            };
            s.len += 1;
        }
        return .{ .x = x, .y = y };
    }
};

const breakLineHeight: f32 = 24;

pub const Measure = struct { width: f32 = 0, trailing: f32 = 0 };

fn blockStyleOf(block: *const md.Block) win.BlockStyle {
    return .{ .alignment = block.alignment };
}

fn hidden(block: *const md.Block) bool {
    return app.collapsed(block.*);
}

fn detailsFrame(block: *const md.Block) ?md.Frame {
    var i = block.frames.len;
    while (i > 0) {
        i -= 1;
        if (block.frames[i].kind == .details) return block.frames[i];
    }
    return null;
}

fn detailsOpen(f: md.Frame) bool {
    return app.isOpen(f);
}

fn tableFloat(t: md.Table) ?Side {
    if (comptime @hasField(md.Table, "float")) {
        if (std.mem.eql(u8, @tagName(t.float), "left")) return .left;
        if (std.mem.eql(u8, @tagName(t.float), "right")) return .right;
    }
    return null;
}

fn isFloat(im: md.Image) bool {
    return im.float != .none;
}

/// `c` without its floated images, which are drawn on their own; the result stays valid until the next frame.
fn withoutFloats(c: md.Inline) std.mem.Allocator.Error!md.Inline {
    var any = false;
    for (c.images) |im| any = any or isFloat(im);
    if (!any) return c;
    const a = sliceArena();
    var cuts: std.ArrayList(md.Span) = .empty;
    for (c.images) |im| if (isFloat(im)) try cuts.append(a, .{ im.start, im.len });
    std.mem.sort(md.Span, cuts.items, {}, struct {
        fn less(_: void, x: md.Span, y: md.Span) bool {
            return x[0] < y[0];
        }
    }.less);
    var text: std.ArrayList(u8) = .empty;
    var pos: u32 = 0;
    for (cuts.items) |cut| {
        if (cut[0] < pos) continue;
        try text.appendSlice(a, c.text[pos..cut[0]]);
        pos = cut[0] + cut[1];
    }
    try text.appendSlice(a, c.text[pos..]);
    const Map = struct {
        cuts: []const md.Span,
        fn at(m: @This(), p: u32) u32 {
            var removed: u32 = 0;
            for (m.cuts) |cut| {
                if (p > cut[0]) removed += @min(cut[1], p - cut[0]);
            }
            return p - removed;
        }
    };
    const m: Map = .{ .cuts = cuts.items };
    var out: md.Inline = .{ .text = text.items };
    inline for (.{ "bold", "italic", "code", "strike", "emoji", "sup", "links", "styles" }) |name| {
        @field(out, name) = try remap(a, @field(c, name), m);
    }
    var images: std.ArrayList(md.Image) = .empty;
    for (c.images) |im| {
        if (isFloat(im)) continue;
        var copy = im;
        copy.start = m.at(im.start);
        try images.append(a, copy);
    }
    out.images = images.items;
    return out;
}

fn remap(a: std.mem.Allocator, src: anytype, m: anytype) std.mem.Allocator.Error!@TypeOf(src) {
    const T = std.meta.Child(@TypeOf(src));
    var out: std.ArrayList(T) = .empty;
    for (src) |item| {
        var copy = item;
        const span: md.Span = if (T == md.Span) item else if (@hasField(T, "span")) item.span else .{ item.start, item.len };
        const s = m.at(span[0]);
        const e = m.at(span[0] + span[1]);
        if (e <= s) continue;
        if (T == md.Span) {
            copy = .{ s, e - s };
        } else if (@hasField(T, "span")) {
            copy.span = .{ s, e - s };
        } else {
            copy.start = s;
            copy.len = e - s;
        }
        try out.append(a, copy);
    }
    return out.items;
}

/// `c` cut down to the one floated image `im`, drawn as an ordinary image.
fn floatPiece(c: md.Inline, im: md.Image) std.mem.Allocator.Error!md.Inline {
    const a = sliceArena();
    var piece = try sliceInline(c, im.start, im.start + im.len);
    const images = try a.dupe(md.Image, piece.images);
    for (images) |*i| i.float = .none;
    piece.images = images;
    return piece;
}

/// Bold italic over the whole run, so a `dt` lays out the same way for hit testing.
fn dtContent(c: md.Inline) std.mem.Allocator.Error!md.Inline {
    const a = sliceArena();
    const all = try a.dupe(md.Span, &.{.{ 0, @as(u32, @intCast(c.text.len)) }});
    var out = c;
    out.bold = all;
    out.italic = all;
    return out;
}

/// Lays `blocks` out `w0` wide from (`x0`, `y_start`) and returns the height, drawing as it goes when `draw` is set.
/// The page itself is the top level, which also records where each block starts for anchor jumps; `measure` gets the
/// widest line and the gap after the last block.
pub fn layoutBlocks(g: win.Gfx, blocks: []const md.Block, x0: f32, w0: f32, y_start: f32, draw: bool, top_level: bool, measure: ?*Measure) f32 {
    const vt_rt = g.vt_rt;
    const rt = g.rt;
    var y = y_start;
    var floats: Floats = .{};
    var last_gap: f32 = 0;
    for (blocks) |*block| {
        if (top_level) app.noteBlock(y);
        if (hidden(block)) continue;
        const inset = block.inset();
        const bx = x0 + inset;
        const bw = @max(w0 - inset, 60);
        var content = block.content;
        if (block.kind == .paragraph and block.role != .summary) {
            const cleaned = withoutFloats(content) catch content;
            if (cleaned.text.ptr != content.text.ptr or cleaned.text.len != content.text.len) {
                for (content.images) |im| if (isFloat(im)) {
                    const piece = floatPiece(app.images.flow(content), im) catch continue;
                    placeFloat(g, draw, &floats, piece, if (im.float == .left) .left else .right, y, bx, bw);
                };
                content = cleaned;
                if (std.mem.trim(u8, content.text, " \n").len == 0) continue;
            }
        }
        if (block.kind == .table) if (tableFloat(block.table)) |side| {
            var tw: f32 = 0;
            const th = tables.renderTable(vt_rt, g.vt_dw, rt, g.dwf, block.table, bx, y, bw, false, &tw);
            const at = floats.place(side, .{ .w = tw, .h = th }, y, bx, bw);
            if (draw) _ = tables.renderTable(vt_rt, g.vt_dw, rt, g.dwf, block.table, at.x, at.y, tw, true, null);
            continue;
        };
        y = floats.clear(y, bx, bw, 120);
        const reg = floats.region(y, bx, bw);
        const x = reg.x;
        const w = reg.w;
        const shift = x - bx;
        const top = y;
        var gap: f32 = 0;
        var natural: f32 = 0;
        const text_brush = if (block.muted()) win.g_brush_quote.? else win.g_brush_text.?;
        const style = blockStyleOf(block);
        if (block.role == .dt) content = dtContent(content) catch content;
        if (draw) for (block.marks) |l| win.drawMarker(vt_rt, g.vt_dw, rt, g.dwf, l.mark, x0 + l.inset + shift, y);

        switch (block.kind) {
            .h1 => {
                y += 24;
                y += win.textBlock(g, draw, content, win.g_text_format_h1.?, x, y, w, win.g_brush_heading.?, style);
                natural = win.g_last_text_w;
                y += 8;
                if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 1 }, win.g_brush_hr.?);
                y += 1;
                gap = 16;
            },
            .h2 => {
                y += 20;
                y += win.textBlock(g, draw, content, win.g_text_format_h2.?, x, y, w, win.g_brush_heading.?, style);
                natural = win.g_last_text_w;
                y += 6;
                if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 1 }, win.g_brush_hr.?);
                y += 1;
                gap = 16;
            },
            .h3 => {
                y += 16;
                y += win.textBlock(g, draw, content, win.g_text_format_h3.?, x, y, w, win.g_brush_heading.?, style);
                natural = win.g_last_text_w;
                gap = 12;
            },
            .h4, .h5, .h6 => {
                y += 24;
                const fmt = switch (block.kind) {
                    .h4 => win.g_text_format_h4,
                    .h5 => win.g_text_format_h5,
                    else => win.g_text_format_h6,
                };
                const brush = if (block.kind == .h6) win.g_brush_quote.? else win.g_brush_heading.?;
                y += win.textBlock(g, draw, content, fmt.?, x, y, w, brush, style);
                natural = win.g_last_text_w;
                gap = 16;
            },
            .paragraph => if (block.role == .empty) {
                gap = block.paragraphGap();
            } else if (block.role == .break_lines) {
                y += breakLineHeight * (f32, (std.mem.count(u8, content.text, "
")));
            } else if (block.role == .summary) {
                gap = summaryBlock(g, draw, block, x, &y, w, text_brush);
                natural = win.g_last_text_w + md.details_marker_inset;
            } else {
                y += flowParagraph(g, draw, content, bx, bw, y, text_brush, style, &floats, &natural);
                gap = if (block.role == .dt) 0 else block.paragraphGap();
            },
            .alert_title => {
                const alert = block.frames[block.frames.len - 1].alert;
                y += 8;
                if (draw) win.drawAlertIcon(vt_rt, rt, alert, x, y);
                _ = win.textBlock(g, draw, content, win.g_text_format_h4.?, x + 24, y - 2, w - 24, win.g_alert_fg[@intFromEnum(alert) - 1].?, .{});
                natural = win.g_last_text_w + 24;
                y += 16;
                gap = 16;
            },
            .error_box => {
                y += win.renderErrorBox(vt_rt, g.vt_dw, rt, g.dwf, content, x, y, w, draw);
                gap = 16;
            },
            .code_block => {
                y += win.renderCodeBlock(vt_rt, g.vt_dw, rt, g.dwf, content.text, block.tokens, x, y, w, draw);
                natural = win.g_last_text_w;
                gap = 16;
            },
            .table => {
                y += tables.renderTable(vt_rt, g.vt_dw, rt, g.dwf, block.table, x, y, w, draw, &natural);
                gap = 16;
            },
            .hr => {
                y += @max(md.hr_margin - last_gap, 0);
                if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + md.hr_height }, win.g_brush_hr.?);
                y += md.hr_height;
                gap = md.hr_margin;
            },
        }

        if (draw) for (block.frames, 0..) |f, i| {
            if (f.kind != .quote) continue;
            if (f.alert != .none and !f.open) y += 8;
            const brush = if (f.alert == .none) win.g_brush_bar.? else win.g_alert_border[@intFromEnum(f.alert) - 1].?;
            const bar_x = x0 + block.insetBefore(i) + shift;
            vt_rt.FillRectangle(rt, &.{ .left = bar_x, .top = top, .right = bar_x + md.quote_bar, .bottom = y + if (f.open) gap else 0 }, brush);
        };
        if (measure) |m| m.width = @max(m.width, x - x0 + natural);
        y += gap;
        last_gap = gap;
    }
    for (floats.items[0..floats.len]) |f| y = @max(y, f.bottom);
    if (measure) |m| m.trailing = last_gap;
    return y - y_start;
}

fn placeFloat(g: win.Gfx, draw: bool, floats: *Floats, piece: md.Inline, side: Side, y: f32, bx: f32, bw: f32) void {
    const size = pieceSize(g, piece, bw);
    const at = floats.place(side, size, y, bx, bw);
    if (draw) _ = win.textBlock(g, true, piece, win.g_text_format.?, at.x, at.y, size.w + 1, win.g_brush_text.?, .{});
}

/// A `summary` line: triangle, text shifted right of it, and the rectangle that toggles its details.
fn summaryBlock(g: win.Gfx, draw: bool, block: *const md.Block, x: f32, y: *f32, w: f32, brush: *anyopaque) f32 {
    const frame = detailsFrame(block);
    const open = if (frame) |f| detailsOpen(f) else true;
    const h = win.textBlock(g, draw, block.content, win.g_text_format.?, x + md.details_marker_inset, y.*, @max(w - md.details_marker_inset, 40), brush, .{});
    const row = @max(h, 21);
    if (draw) {
        drawDisclosure(g, x + 4, y.* + row / 2, open);
        if (frame) |f| app.noteToggle(.{ .x = x, .y = y.*, .w = w, .h = row }, f);
    }
    y.* += row;
    return if (open) 0 else 16;
}

const disclosure_closed = [_]alerts.Op{ .{ .move = .{ 0, -5 } }, .{ .line = .{ 7, 0 } }, .{ .line = .{ 0, 5 } }, .close };
const disclosure_open = [_]alerts.Op{ .{ .move = .{ 0, -3 } }, .{ .line = .{ 8, -3 } }, .{ .line = .{ 4, 3.5 } }, .close };
var g_disclosure: [2]?*anyopaque = @splat(null);

fn drawDisclosure(g: win.Gfx, x: f32, cy: f32, open: bool) void {
    const slot = @intFromBool(open);
    if (g_disclosure[slot] == null) {
        const factory = win.g_d2d_factory orelse return;
        g_disclosure[slot] = win.geometryFromOps(factory, if (open) &disclosure_open else &disclosure_closed);
    }
    const geom = g_disclosure[slot] orelse return;
    const brush = win.g_brush_text orelse return;
    g.vt_rt.SetTransform(g.rt, &win.matrix(x, cy - app.scroll_y));
    g.vt_rt.FillGeometry(g.rt, geom, brush, null);
    g.vt_rt.SetTransform(g.rt, &win.matrix(0, -app.scroll_y));
}

const Extent = struct { w: f32, h: f32 };

fn pieceSize(g: win.Gfx, content: md.Inline, w: f32) Extent {
    const lay = win.createLayout(g.vt_dw, g.dwf, app.images.flow(content), win.g_text_format.?, w) orelse return .{ .w = 0, .h = 0 };
    defer _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
    // SAFETY: written by GetMetrics
    var m: win.DWRITE_TEXT_METRICS = undefined;
    _ = win.vtable(win.IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
    return .{ .w = @min(@ceil(m.width), w), .h = m.height };
}

var g_slices: ?std.heap.ArenaAllocator = null;

fn sliceArena() std.mem.Allocator {
    if (g_slices == null) g_slices = .init(app.gpa);
    return g_slices.?.allocator();
}

pub fn resetSlices() void {
    if (g_slices) |*a| _ = a.reset(.free_all);
}

fn clipSpans(a: std.mem.Allocator, src: anytype, lo: u32, hi: u32) std.mem.Allocator.Error!@TypeOf(src) {
    const T = std.meta.Child(@TypeOf(src));
    var out: std.ArrayList(T) = .empty;
    for (src) |item| {
        const span: md.Span = if (T == md.Span) item else if (@hasField(T, "span")) item.span else .{ item.start, item.len };
        const s = @max(span[0], lo);
        const e = @min(span[0] + span[1], hi);
        if (e <= s) continue;
        var copy = item;
        if (T == md.Span) {
            copy = .{ s - lo, e - s };
        } else if (@hasField(T, "span")) {
            copy.span = .{ s - lo, e - s };
        } else {
            copy.start = s - lo;
            copy.len = e - s;
        }
        try out.append(a, copy);
    }
    return out.items;
}

fn sliceInline(c: md.Inline, lo: u32, hi: u32) std.mem.Allocator.Error!md.Inline {
    const a = sliceArena();
    return .{
        .text = c.text[lo..hi],
        .bold = try clipSpans(a, c.bold, lo, hi),
        .italic = try clipSpans(a, c.italic, lo, hi),
        .code = try clipSpans(a, c.code, lo, hi),
        .strike = try clipSpans(a, c.strike, lo, hi),
        .emoji = try clipSpans(a, c.emoji, lo, hi),
        .sup = try clipSpans(a, c.sup, lo, hi),
        .links = try clipSpans(a, c.links, lo, hi),
        .images = try clipSpans(a, c.images, lo, hi),
        .styles = try clipSpans(a, c.styles, lo, hi),
    };
}

/// The byte offset of the first line that starts at or below `limit` when `content` is laid out `w` wide.
fn lineSplit(g: win.Gfx, content: md.Inline, w: f32, limit: f32) ?u32 {
    if (limit <= 0) return null;
    const lay = win.createLayout(g.vt_dw, g.dwf, content, win.g_text_format.?, w) orelse return null;
    defer _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
    const vt = win.vtable(win.IDWriteTextLayout_VTable, lay);
    // SAFETY: written by GetMetrics
    var m: win.DWRITE_TEXT_METRICS = undefined;
    _ = vt.GetMetrics(lay, &m);
    if (m.height <= limit or m.lineCount < 2) return null;
    const lines = app.gpa.alloc(win.DWRITE_LINE_METRICS, m.lineCount) catch return null;
    defer app.gpa.free(lines);
    var count: u32 = 0;
    if (vt.GetLineMetrics(lay, lines.ptr, m.lineCount, &count) < 0) return null;
    var top: f32 = 0;
    var units: u32 = 0;
    for (lines[0..count], 0..) |l, i| {
        if (i > 0 and top >= limit) return md.byteFromUtf16(content.text, units);
        top += l.height;
        units += l.length;
    }
    return null;
}

/// A paragraph keeps clear of every float it meets: each stretch of lines is laid out in the room left at its top, and the
/// rest of the text starts again where a float starts or ends.
fn flowParagraph(g: win.Gfx, draw: bool, content_in: md.Inline, bx: f32, bw: f32, y0: f32, brush: *anyopaque, style: win.BlockStyle, floats: *const Floats, natural: *f32) f32 {
    var content = app.images.flow(content_in);
    var used: f32 = 0;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        const y = y0 + used;
        const reg = floats.region(y, bx, bw);
        const next = if (rounds < 64) floats.change(y) else null;
        const at = if (next) |n| lineSplit(g, content, reg.w, n - y) else null;
        const cut = at orelse {
            used += win.textBlock(g, draw, content, win.g_text_format.?, reg.x, y, reg.w, brush, style);
            natural.* = @max(natural.*, win.g_last_text_w);
            return used;
        };
        var tail_lo = cut;
        while (tail_lo < content.text.len and (content.text[tail_lo] == ' ' or content.text[tail_lo] == '\n')) tail_lo += 1;
        const head = sliceInline(content, 0, cut) catch {
            used += win.textBlock(g, draw, content, win.g_text_format.?, reg.x, y, reg.w, brush, style);
            return used;
        };
        const tail = sliceInline(content, tail_lo, @intCast(content.text.len)) catch {
            used += win.textBlock(g, draw, content, win.g_text_format.?, reg.x, y, reg.w, brush, style);
            return used;
        };
        used += win.textBlock(g, draw, head, win.g_text_format.?, reg.x, y, reg.w, brush, style);
        natural.* = @max(natural.*, win.g_last_text_w);
        content = tail;
    }
}

pub fn applyStyle(lay: *anyopaque, content: md.Inline, s: md.Styled, base: f32) void {
    const vt = win.vtable(win.IDWriteTextLayout_VTable, lay);
    const range = win.wideRange(content.text, s.span);
    if (range.length == 0) return;
    switch (s.kind) {
        .kbd => {
            _ = vt.SetFontFamilyName(lay, L("Consolas"), range);
            _ = vt.SetFontSize(lay, md.kbd_font_px, range);
            if (win.g_brush_bright) |b| _ = vt.SetDrawingEffect(lay, b, range);
            padRange(lay, range, win.kbd_pad);
        },
        .tt => {
            _ = vt.SetFontFamilyName(lay, L("Consolas"), range);
            _ = vt.SetFontSize(lay, base * md.code_scale, range);
            padRange(lay, range, md.code_pad_em * md.code_scale * base);
        },
        .underline => _ = vt.SetUnderline(lay, 1, range),
        .mark => if (win.g_brush_bright) |b| {
            _ = vt.SetDrawingEffect(lay, b, range);
        },
        .sub => {},
    }
}

fn padRange(lay: *anyopaque, range: win.DWRITE_TEXT_RANGE, pad: f32) void {
    const query: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.c) win.HRESULT = @ptrCast(win.vtable(win.IDWriteTextLayout_VTable, lay).QueryInterface);
    var l1: ?*anyopaque = null;
    if (query(lay, &win.IID_IDWriteTextLayout1, &l1) < 0) return;
    const layout1 = l1 orelse return;
    defer _ = win.vtable(win.IDWriteTextLayout1_VTable, layout1).Release(layout1);
    const set = win.vtable(win.IDWriteTextLayout1_VTable, layout1).SetCharacterSpacing;
    _ = set(layout1, pad, 0, 0, .{ .startPosition = range.startPosition, .length = 1 });
    _ = set(layout1, if (range.length == 1) pad else 0, pad, 0, .{ .startPosition = range.startPosition + range.length - 1, .length = 1 });
}

const Fixture = struct {
    hwnd: win.HWND,

    fn init(blocks: []const md.Block) !Fixture {
        app.gpa = std.heap.page_allocator;
        app.images.init(testing.allocator, testing.io);
        app.images.reset("", false);
        _ = win.CoInitializeEx(null, 0x2);
        win.initD2D();
        const hwnd = win.CreateWindowExW(0, L("STATIC"), L("t"), win.WS_POPUP, 0, 0, 300, 200, null, null, null, null) orelse return error.NoWindow;
        win.createRenderTarget(hwnd);
        try testing.expect(win.g_render_target != null);
        app.blocks = blocks;
        app.window_width = 900;
        app.window_height = 700;
        app.scroll_y = 0;
        return .{ .hwnd = hwnd };
    }

    fn deinit(f: *Fixture) void {
        _ = win.DestroyWindow(f.hwnd);
        app.blocks = &.{};
        app.hits = .empty;
        app.block_y = .empty;
        app.details_open = .empty;
        app.images.clearAll();
        win.resetObjects();
        resetSlices();
        app.gpa = testing.allocator;
    }
};

fn paragraph(a: std.mem.Allocator, src: []const u8) !md.Block {
    const doc = try md.parse(a, src);
    return doc.blocks[0];
}

fn gfxOf() win.Gfx {
    const rt = win.g_render_target.?;
    const dwf = win.g_dwrite_factory.?;
    return .{ .vt_rt = win.vtable(win.ID2D1RT_VTable, rt), .vt_dw = win.vtable(win.IDWriteFactory_VTable, dwf), .rt = rt, .dwf = dwf };
}

fn initText() void {
    app.gpa = testing.allocator;
    _ = win.CoInitializeEx(null, 0x2);
    win.initD2D();
}

test "block alignment moves the text and reaches the hit rectangle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b = try paragraph(arena.allocator(), "[hi](http://x.org)");
    b.alignment = .center;
    var fx = try Fixture.init(&.{b});
    defer fx.deinit();
    win.render();
    try testing.expectEqual(@as(usize, 1), app.hits.items.len);
    const hit = app.hits.items[0];
    try testing.expectEqual(md.Align.center, hit.alignment);
    try testing.expectEqual(@as(?u32, null), win.textIndexAt(hit, 2, 10));
    try testing.expectEqual(@as(?u32, 0), win.textIndexAt(.{ .content = hit.content, .x = 0, .y = 0, .w = hit.w, .h = hit.h }, 2, 10));
    try testing.expect(win.textIndexAt(hit, hit.w / 2 + 1, 10) != null);
}

test "a kbd span is padded and set in the small mono font" {
    initText();
    const styles = [_]md.Styled{.{ .span = .{ 2, 4 }, .kind = .kbd }};
    const content: md.Inline = .{ .text = "a Ctrl b", .styles = &styles };
    const dwf = win.g_dwrite_factory.?;
    const lay = win.createLayout(win.vtable(win.IDWriteFactory_VTable, dwf), dwf, content, win.g_text_format.?, 2000).?;
    defer _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
    var rects: std.ArrayList(win.D2D1_RECT_F) = .empty;
    defer rects.deinit(testing.allocator);
    try win.rangeRects(lay, win.wideRange(content.text, styles[0].span), &rects);
    try testing.expectEqual(@as(usize, 1), rects.items.len);
    const width = rects.items[0].right - rects.items[0].left;
    try testing.expectApproxEqAbs(4 * 0.55 * md.kbd_font_px + 2 * win.kbd_pad, width, 2);
}

test "sub shrinks their text and sub drops below the baseline" {
    initText();
    const plain = win.layoutSize(.{ .text = "mmmmmmmm" }, 2000).width;
    const sub = win.layoutSize(.{ .text = "mmmmmmmm", .styles = &.{.{ .span = .{ 0, 8 }, .kind = .sub }} }, 2000).width;
    try testing.expectApproxEqAbs(plain * win.sub_scale, sub, 2);
    try testing.expect(win.baselineRaise(win.g_brush_text_sub, 12) == -3);
    try testing.expect(win.baselineRaise(win.g_brush_link_sub, 12) == -3);
    try testing.expect(win.baselineRaise(win.g_brush_text_sup, 12) == 6);
    try testing.expect(win.baselineRaise(null, 12) == 0);
}

test "mark and tt rectangles exist and a paragraph with every style draws" {
    const styles = [_]md.Styled{
        .{ .span = .{ 0, 4 }, .kind = .mark },
        .{ .span = .{ 5, 4 }, .kind = .tt },
        .{ .span = .{ 10, 3 }, .kind = .underline },
        .{ .span = .{ 14, 2 }, .kind = .tt },
        .{ .span = .{ 17, 3 }, .kind = .kbd },
    };
    const b: md.Block = .{ .kind = .paragraph, .content = .{ .text = "mark abbr ins tt kbd", .styles = &styles } };
    var fx = try Fixture.init(&.{b});
    defer fx.deinit();
    win.render();
    try testing.expect(app.content_height > 80);
    const g = gfxOf();
    const lay = win.createLayout(g.vt_dw, g.dwf, b.content, win.g_text_format.?, 800).?;
    defer _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
    var rects: std.ArrayList(win.D2D1_RECT_F) = .empty;
    defer rects.deinit(app.gpa);
    try win.rangeRects(lay, win.wideRange(b.content.text, styles[1].span), &rects);
    try testing.expectEqual(@as(usize, 1), rects.items.len);
    try testing.expect(hasStyle(b.content, .tt) and !hasStyle(b.content, .sub));
}

test "dt has no gap below it and dd is inset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var term = try paragraph(a, "[term](http://x.org)");
    term.role = .dt;
    var def = try paragraph(a, "[def](http://x.org)");
    def.frames = &.{.{ .kind = .dd }};
    const plain = try paragraph(a, "[plain](http://x.org)");
    var fx = try Fixture.init(&.{ term, def, plain, plain });
    defer fx.deinit();
    win.render();
    try testing.expectEqual(@as(usize, 4), app.hits.items.len);
    try testing.expectEqual(@as(usize, 1), app.hits.items[0].content.italic.len);
    try testing.expectEqual(@as(f32, 40 + md.dd_inset), app.hits.items[1].x);
    const term_step = app.block_y.items[1] - app.block_y.items[0];
    const plain_step = app.block_y.items[3] - app.block_y.items[2];
    try testing.expectApproxEqAbs(plain_step - 16, term_step, 0.5);
}

test "an img width scales a loaded picture and both attributes force its box" {
    app.images.init(testing.allocator, testing.io);
    app.images.reset("", false);
    defer app.images.clearAll();
    defer win.resetObjects();
    initText();
    try app.images.injectReady("wide.png", 400, 200);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try paragraph(arena.allocator(), "![w](wide.png)");
    var images = [_]md.Image{b.content.images[0]};
    images[0].width = 100;
    var content = b.content;
    content.images = &images;
    const narrow = win.layoutSize(content, 800);
    try testing.expectApproxEqAbs(@as(f32, 100), narrow.width, 1);
    try testing.expect(narrow.height >= 50 and narrow.height < 75);
    images[0].height = 30;
    try testing.expect(win.layoutSize(content, 800).height < narrow.height);
    images[0].width = 900;
    images[0].height = 0;
    try testing.expectApproxEqAbs(@as(f32, 300), win.layoutSize(content, 300).width, 1);
}

test "colspan and rowspan share track sizes and valign offsets the content" {
    var fx = try Fixture.init(&.{});
    defer fx.deinit();
    const g = gfxOf();
    var cells = [_]md.Inline{ .{ .text = "a header cell that is rather wide" }, .{}, .{ .text = "x" }, .{ .text = "y" }, .{ .text = "z" }, .{ .text = "w" } };
    const wide: md.Table = .{ .columns = 3, .cells = &cells, .ext = &.{ .spans = &.{ .{ 2, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 } } } };
    var span_w: f32 = 0;
    _ = tables.renderTable(g.vt_rt, g.vt_dw, g.rt, g.dwf, wide, 0, 0, 2000, false, &span_w);
    const natural = win.layoutSize(cells[0], 2000).widthIncludingTrailingWhitespace + tables.cell_pad_x * 2 + 1;
    try testing.expect(span_w >= natural);
    try testing.expect(span_w < natural + 2 * (tables.cell_pad_x * 2 + 8 + 1));

    var tall = [_]md.Inline{ .{ .text = "one two three four five six seven eight nine ten eleven twelve" }, .{ .text = "x" }, .{}, .{ .text = "y" } };
    const rowspan: md.Table = .{ .columns = 2, .cells = &tall, .ext = &.{ .spans = &.{ .{ 1, 2 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 } } } };
    const h = tables.renderTable(g.vt_rt, g.vt_dw, g.rt, g.dwf, rowspan, 0, 0, 200, false, null);
    try testing.expect(h > 2 * (tables.cell_min_text + tables.cell_pad_y * 2) + 1);

    try testing.expectEqual(@as(f32, 5), tables.valignOffset(.middle, 10));
    try testing.expectEqual(@as(f32, 10), tables.valignOffset(.bottom, 10));
    try testing.expectEqual(@as(f32, 0), tables.valignOffset(.top, 10));
    try testing.expectEqual(@as(f32, 5), tables.valignOffset(.none, 10));
    try testing.expectEqual(@as(f32, 0), tables.valignOffset(.bottom, -4));
}

fn detailsBlocks(a: std.mem.Allocator, frames: []const md.Frame) ![3]md.Block {
    var summary = try paragraph(a, "Summary");
    summary.role = .summary;
    summary.frames = frames;
    var body = try paragraph(a, "Body text");
    body.frames = frames;
    return .{ summary, body, try paragraph(a, "After") };
}

test "a closed details hides its body, a click opens it and a shrunk page pulls the scroll back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const blocks = try detailsBlocks(arena.allocator(), &.{.{ .kind = .details, .key = 7 }});
    var fx = try Fixture.init(&blocks);
    defer fx.deinit();
    win.render();
    const closed_height = app.content_height;
    try testing.expectEqual(app.block_y.items[1], app.block_y.items[2]);

    try testing.expect(app.mouseDown(50, 50));
    win.render();
    try testing.expect(app.content_height > closed_height);
    try testing.expect(app.block_y.items[2] - app.block_y.items[1] > 30);

    try testing.expect(app.mouseDown(50, 50));
    app.scroll_y = 900;
    win.render();
    try testing.expectEqual(@as(f32, 0), app.scroll_y);
    try testing.expectEqual(closed_height, app.content_height);
}

test "a details that is open by default shows its body and draws the triangle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const blocks = try detailsBlocks(arena.allocator(), &.{.{ .kind = .details, .key = 9, .default_open = true }});
    var fx = try Fixture.init(&blocks);
    defer fx.deinit();
    win.render();
    try testing.expect(app.block_y.items[2] - app.block_y.items[1] > 30);
    try testing.expect(g_disclosure[1] != null);
}

test "text beside a floated image is narrowed and the lines below it run full width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pic = try paragraph(a, "![r](wide.png)");
    const images = try a.dupe(md.Image, pic.content.images);
    images[0].width = 160;
    images[0].float = .right;
    pic.content.images = images;
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(a, "[");
    for (0..200) |_| try long.appendSlice(a, "word ");
    try long.appendSlice(a, "end](http://x.org)");
    const text = try paragraph(a, long.items);
    var fx = try Fixture.init(&.{ pic, text });
    defer fx.deinit();
    try app.images.injectReady("wide.png", 400, 200);
    win.render();
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    const head = app.hits.items[0];
    const tail = app.hits.items[1];
    try testing.expectApproxEqAbs(@as(f32, 820 - 160 - md.float_gap), head.w, 1);
    try testing.expectApproxEqAbs(@as(f32, 820), tail.w, 0.01);
    try testing.expectApproxEqAbs(head.y + head.h, tail.y, 0.01);
    try testing.expect(head.h >= 80);
}

fn floatImage(a: std.mem.Allocator, src: []const u8, side: @FieldType(md.Image, "float")) !md.Block {
    var b = try paragraph(a, src);
    const images = try a.dupe(md.Image, b.content.images);
    images[0].width = 160;
    images[0].float = side;
    b.content.images = images;
    return b;
}

fn longLink(a: std.mem.Allocator, words: usize) !md.Block {
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(a, "[");
    for (0..words) |_| try long.appendSlice(a, "word ");
    try long.appendSlice(a, "end](http://x.org)");
    return paragraph(a, long.items);
}

test "a float inside a paragraph with text takes room from the text and stays clickable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mixed = try floatImage(a, "[![r](wide.png \"tip\")](http://x.org) [some text after the picture](http://y.org)", .right);
    var fx = try Fixture.init(&.{mixed});
    defer fx.deinit();
    try app.images.injectReady("wide.png", 400, 200);
    win.render();
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    var piece: ?app.Hit = null;
    var text: ?app.Hit = null;
    for (app.hits.items) |h| {
        if (h.content.images.len > 0) piece = h else text = h;
    }
    try testing.expectApproxEqAbs(@as(f32, 40 + 820 - 160), piece.?.x, 2);
    try testing.expect(piece.?.content.images[0].float == .none);
    try testing.expectApproxEqAbs(@as(f32, 820 - 160 - md.float_gap), text.?.w, 1);
}

test "floats on both sides and blocks of every kind keep clear of them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try floatImage(a, "![l](wide.png)", .left);
    const right = try floatImage(a, "![r](wide.png)", .right);
    var item = try paragraph(a, "[item](http://x.org)");
    item.frames = &.{.{ .kind = .list, .ordered = false }};
    var quote = try paragraph(a, "[quote](http://x.org)");
    quote.frames = &.{.{ .kind = .quote }};
    var fx = try Fixture.init(&.{ left, right, item, quote });
    defer fx.deinit();
    try app.images.injectReady("wide.png", 400, 200);
    win.render();
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    const both = 2 * (160 + md.float_gap);
    try testing.expectApproxEqAbs(@as(f32, 40 + 160 + md.float_gap + md.list_inset), app.hits.items[0].x, 1);
    try testing.expectApproxEqAbs(@as(f32, 820 - both - md.list_inset), app.hits.items[0].w, 1);
    try testing.expectApproxEqAbs(@as(f32, 40 + 160 + md.float_gap + md.quote_inset), app.hits.items[1].x, 1);
}

test "a float taller than the text keeps the page long enough and a later float stacks beside the first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try floatImage(a, "![l](wide.png)", .left);
    const two = try floatImage(a, "![l](wide.png)", .left);
    const text = try longLink(a, 4);
    var fx = try Fixture.init(&.{ one, two, text });
    defer fx.deinit();
    try app.images.injectReady("wide.png", 400, 200);
    win.render();
    try testing.expectEqual(@as(usize, 1), app.hits.items.len);
    try testing.expectApproxEqAbs(@as(f32, 40 + 2 * (160 + md.float_gap)), app.hits.items[0].x, 1);
    try testing.expect(app.content_height >= 40 + 80 + 40);
}

test "an hr is 4px with 24px margins and a measure pass matches the drawn height" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rule: md.Block = .{ .kind = .hr };
    const after = try paragraph(a, "[after](http://x.org)");
    var fx = try Fixture.init(&.{ rule, after });
    defer fx.deinit();
    win.render();
    try testing.expectApproxEqAbs(md.hr_margin + md.hr_height + md.hr_margin, app.block_y.items[1] - app.block_y.items[0], 0.01);
    const g = gfxOf();
    const drawn = layoutBlocks(g, &.{ rule, after }, 40, 820, 40, true, false, null);
    const measured = layoutBlocks(g, &.{ rule, after }, 40, 820, 40, false, false, null);
    try testing.expectEqual(drawn, measured);
}

test "a cell with blocks draws them inside the cell and sizes the row to them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try paragraph(a, "[one](http://x.org)");
    const second = try paragraph(a, "[two](http://x.org)");
    var cells = [_]md.Inline{ .{}, .{ .text = "plain" } };
    const t: md.Table = .{
        .columns = 2,
        .cells = &cells,
        .header_row = false,
        .ext = &.{ .cell_blocks = &.{ &.{ first, second }, &.{} } },
    };
    var fx = try Fixture.init(&.{.{ .kind = .table, .table = t }});
    defer fx.deinit();
    win.render();
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    try testing.expectApproxEqAbs(@as(f32, 40 + tables.cell_pad_x), app.hits.items[0].x, 1);
    try testing.expect(app.hits.items[1].y > app.hits.items[0].y + 15);
    const g = gfxOf();
    const h = tables.renderTable(g.vt_rt, g.vt_dw, g.rt, g.dwf, t, 0, 0, 800, false, null);
    try testing.expect(h > 2 * 21 + 16 + 2 * tables.cell_pad_y);
}

test "an empty paragraph takes no height and break lines take one 24px line each without a gap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const after = try paragraph(a, "[after](http://x.org)");
    const empty: md.Block = .{ .kind = .paragraph, .role = .empty };
    const breaks: md.Block = .{ .kind = .paragraph, .role = .break_lines, .content = .{ .text = "\n\n" } };
    var fx = try Fixture.init(&.{ empty, breaks, after });
    defer fx.deinit();
    win.render();
    try testing.expectEqual(@as(f32, 40 + 16), app.block_y.items[1]);
    try testing.expectEqual(@as(f32, 40 + 16 + 48), app.block_y.items[2]);
    try testing.expectEqual(@as(usize, 1), app.hits.items.len);
}
