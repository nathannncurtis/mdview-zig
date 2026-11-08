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
/// A floated image: following text blocks sit beside it (width includes the gap) until `bottom`.
const Band = struct { side: Side, width: f32, bottom: f32 };

fn blockStyleOf(block: *const md.Block) win.BlockStyle {
    return .{ .alignment = block.alignment, .dt = block.role == .dt };
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

/// The side of a paragraph that holds nothing but floated images.
fn floatSide(block: *const md.Block) ?Side {
    if (block.kind != .paragraph or block.content.images.len == 0) return null;
    var covered: usize = 0;
    var side: ?Side = null;
    for (block.content.images) |im| {
        const s: Side = switch (im.float) {
            .none => return null,
            .left => .left,
            .right => .right,
        };
        if (side != null and side.? != s) return null;
        side = s;
        covered += im.len;
    }
    var visible: usize = 0;
    for (block.content.text) |c| visible += @intFromBool(c != ' ' and c != '\n');
    return if (covered == visible) side else null;
}

fn flowsAround(kind: md.BlockKind) bool {
    return switch (kind) {
        .paragraph, .h1, .h2, .h3, .h4, .h5, .h6 => true,
        else => false,
    };
}

/// Lays `blocks` out `w0` wide from (`x0`, `y_start`) and returns the height, drawing as it goes when `draw` is set.
/// The page itself is the top level, which also records where each block starts for anchor jumps.
pub fn layoutBlocks(g: win.Gfx, blocks: []const md.Block, x0: f32, w0: f32, y_start: f32, draw: bool, top_level: bool) f32 {
    const vt_rt = g.vt_rt;
    const rt = g.rt;
    var y = y_start;
    var band: ?Band = null;
    for (blocks) |*block| {
        if (top_level) app.noteBlock(y);
        if (hidden(block)) continue;
        if (band) |b| if (y >= b.bottom) {
            band = null;
        };
        const inset = block.inset();
        var x = x0 + inset;
        var w = @max(w0 - inset, 60);
        if (floatSide(block)) |side| {
            const size = imagesSize(g, block, w);
            if (draw) _ = win.textBlock(g, true, block.content, win.g_text_format.?, x, y, w, win.g_brush_text.?, .{ .alignment = if (side == .right) .right else .left });
            const prior = if (band) |b| b.bottom else 0;
            band = .{ .side = side, .width = size.w + md.float_gap, .bottom = @max(prior, y + size.h) };
            continue;
        }
        if (band) |b| {
            if (flowsAround(block.kind)) {
                if (b.side == .left) x += b.width;
                w = @max(w - b.width, 60);
            } else {
                y = @max(y, b.bottom);
                band = null;
            }
        }
        const top = y;
        var gap: f32 = 0;
        const text_brush = if (block.muted()) win.g_brush_quote.? else win.g_brush_text.?;
        const style = blockStyleOf(block);
        if (draw) for (block.marks) |l| win.drawMarker(vt_rt, g.vt_dw, rt, g.dwf, l.mark, x0 + l.inset, y);

        switch (block.kind) {
            .h1 => {
                y += 24;
                y += win.textBlock(g, draw, block.content, win.g_text_format_h1.?, x, y, w, win.g_brush_heading.?, style);
                y += 8;
                if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 1 }, win.g_brush_hr.?);
                y += 1;
                gap = 16;
            },
            .h2 => {
                y += 20;
                y += win.textBlock(g, draw, block.content, win.g_text_format_h2.?, x, y, w, win.g_brush_heading.?, style);
                y += 6;
                if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 1 }, win.g_brush_hr.?);
                y += 1;
                gap = 16;
            },
            .h3 => {
                y += 16;
                y += win.textBlock(g, draw, block.content, win.g_text_format_h3.?, x, y, w, win.g_brush_heading.?, style);
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
                y += win.textBlock(g, draw, block.content, fmt.?, x, y, w, brush, style);
                gap = 16;
            },
            .paragraph => if (block.role == .summary) {
                gap = summaryBlock(g, draw, block, x, &y, w, text_brush);
            } else {
                y += bandedParagraph(g, draw, block, x, y, w, text_brush, style, band, x0 + inset, @max(w0 - inset, 60));
                gap = if (block.role == .dt) 0 else block.paragraphGap();
            },
            .alert_title => {
                const alert = block.frames[block.frames.len - 1].alert;
                y += 8;
                if (draw) win.drawAlertIcon(vt_rt, rt, alert, x, y);
                _ = win.textBlock(g, draw, block.content, win.g_text_format_h4.?, x + 24, y - 2, w - 24, win.g_alert_fg[@intFromEnum(alert) - 1].?, .{});
                y += 16;
                gap = 16;
            },
            .error_box => {
                y += win.renderErrorBox(vt_rt, g.vt_dw, rt, g.dwf, block.content, x, y, w, draw);
                gap = 16;
            },
            .code_block => {
                y += win.renderCodeBlock(vt_rt, g.vt_dw, rt, g.dwf, block.content.text, block.tokens, x, y, w, draw);
                gap = 16;
            },
            .table => {
                y += tables.renderTable(vt_rt, g.vt_dw, rt, g.dwf, block.table, x, y, w, draw, null);
                gap = 16;
            },
            .hr => {
                y += 12;
                if (draw) vt_rt.FillRectangle(rt, &.{ .left = x, .top = y, .right = x + w, .bottom = y + 2 }, win.g_brush_hr.?);
                y += 2;
                gap = 14;
            },
        }

        if (draw) for (block.frames, 0..) |f, i| {
            if (f.kind != .quote) continue;
            if (f.alert != .none and !f.open) y += 8;
            const brush = if (f.alert == .none) win.g_brush_bar.? else win.g_alert_border[@intFromEnum(f.alert) - 1].?;
            const bar_x = x0 + block.insetBefore(i);
            vt_rt.FillRectangle(rt, &.{ .left = bar_x, .top = top, .right = bar_x + md.quote_bar, .bottom = y + if (f.open) gap else 0 }, brush);
        };
        y += gap;
    }
    if (band) |b| y = @max(y, b.bottom);
    return y - y_start;
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
    return if (open) 4 else 16;
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

fn imagesSize(g: win.Gfx, block: *const md.Block, w: f32) Extent {
    const lay = win.createLayout(g.vt_dw, g.dwf, app.images.flow(block.content), win.g_text_format.?, w) orelse return .{ .w = 0, .h = 0 };
    defer _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
    // SAFETY: written by GetMetrics
    var m: win.DWRITE_TEXT_METRICS = undefined;
    _ = win.vtable(win.IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
    return .{ .w = @min(@ceil(m.width), w), .h = m.height };
}

var g_slices: ?std.heap.ArenaAllocator = null;

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
    if (g_slices == null) g_slices = .init(app.gpa);
    const a = g_slices.?.allocator();
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

/// A paragraph beside a float stays narrow only down to the float's bottom; the rest of it runs at full width.
fn bandedParagraph(g: win.Gfx, draw: bool, block: *const md.Block, x: f32, y: f32, w: f32, brush: *anyopaque, style: win.BlockStyle, band: ?Band, full_x: f32, full_w: f32) f32 {
    const b = band orelse return win.textBlock(g, draw, block.content, win.g_text_format.?, x, y, w, brush, style);
    const content = app.images.flow(block.content);
    const at = lineSplit(g, content, w, b.bottom - y) orelse return win.textBlock(g, draw, content, win.g_text_format.?, x, y, w, brush, style);
    var tail_lo = at;
    while (tail_lo < content.text.len and (content.text[tail_lo] == ' ' or content.text[tail_lo] == '\n')) tail_lo += 1;
    const head = sliceInline(content, 0, at) catch return win.textBlock(g, draw, content, win.g_text_format.?, x, y, w, brush, style);
    const tail = sliceInline(content, tail_lo, @intCast(content.text.len)) catch return win.textBlock(g, draw, content, win.g_text_format.?, x, y, w, brush, style);
    const head_h = win.textBlock(g, draw, head, win.g_text_format.?, x, y, w, brush, style);
    return head_h + win.textBlock(g, draw, tail, win.g_text_format.?, full_x, y + head_h, full_w, brush, style);
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
        .small, .abbr, .sub => {},
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
    std.debug.print("float hits {d} side {any} content_h {d}\n", .{ app.hits.items.len, floatSide(&.{ .kind = .paragraph, .content = pic.content }), app.content_height });
    try testing.expectEqual(@as(usize, 2), app.hits.items.len);
    const head = app.hits.items[0];
    const tail = app.hits.items[1];
    try testing.expectApproxEqAbs(@as(f32, 820 - 160 - md.float_gap), head.w, 1);
    try testing.expectApproxEqAbs(@as(f32, 820), tail.w, 0.01);
    try testing.expectApproxEqAbs(head.y + head.h, tail.y, 0.01);
    try testing.expect(head.h >= 80);
}
