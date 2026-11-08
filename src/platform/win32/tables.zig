const win = @import("win32.zig");
const app = @import("../../main.zig");
const md = app.md;
const html = @import("html.zig");
const table_layout = @import("../../markdown/table_layout.zig");

pub const cell_pad_x: f32 = 13;
pub const nested_margin: f32 = md.nested_table_margin;
pub const cell_pad_y: f32 = 6;
pub const cell_min_text: f32 = 21;

pub fn cellLayout(vt_dw: *const win.IDWriteFactory_VTable, dwf: *anyopaque, t: md.Table, row: usize, col: usize, width: f32) ?*anyopaque {
    const content = app.images.flow(t.cell(row, col));
    const lay = win.createLayout(vt_dw, dwf, content, win.g_text_format orelse return null, width) orelse return null;
    const vt = win.vtable(win.IDWriteTextLayout_VTable, lay);
    if ((row == 0 and t.header_row) or (col == 0 and t.header_col)) _ = vt.SetFontWeight(lay, 700, win.wideRange(content.text, .{ 0, @intCast(content.text.len) }));
    _ = vt.SetTextAlignment(lay, win.alignmentCode(t.alignAt(row, col)));
    return lay;
}

fn layoutHeight(lay: ?*anyopaque) f32 {
    const l = lay orelse return 0;
    // SAFETY: written by GetMetrics
    var m: win.DWRITE_TEXT_METRICS = undefined;
    _ = win.vtable(win.IDWriteTextLayout_VTable, l).GetMetrics(l, &m);
    return m.height;
}

pub fn valignOffset(v: md.VAlign, free: f32) f32 {
    return @max(switch (v) {
        .top => 0,
        .none, .middle => free / 2,
        .bottom => free,
    }, 0);
}

pub fn renderTable(vt_rt: *const win.ID2D1RT_VTable, vt_dw: *const win.IDWriteFactory_VTable, rt: *anyopaque, dwf: *anyopaque, t: md.Table, x: f32, y: f32, max_width: f32, draw: bool, out_width: ?*f32) f32 {
    const border = win.g_brush_table_border orelse return 0;
    if (out_width) |o| o.* = 0;
    const rows = t.rows();
    if (rows == 0) return 0;
    const cols = t.columns;
    const widths = app.gpa.alloc(f32, cols) catch return 0;
    defer app.gpa.free(widths);
    const heights = app.gpa.alloc(f32, rows) catch return 0;
    defer app.gpa.free(heights);
    const cells = app.gpa.alloc(f32, rows * cols * 2) catch return 0;
    defer app.gpa.free(cells);
    const layouts = app.gpa.alloc(?*anyopaque, rows * cols) catch return 0;
    defer app.gpa.free(layouts);
    @memset(layouts, null);
    defer for (layouts) |l| if (l) |lay| {
        _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
    };
    const sizes = cells[0 .. rows * cols];
    const content_h = cells[rows * cols ..];
    const g: win.Gfx = .{ .vt_rt = vt_rt, .vt_dw = vt_dw, .rt = rt, .dwf = dwf };

    for (0..rows) |row| {
        for (0..cols) |col| {
            const i = row * cols + col;
            sizes[i] = 0;
            if (table_layout.covered(t, row, col)) continue;
            var natural: f32 = 0;
            const blocks = t.cellBlocks(row, col);
            if (blocks.len > 0) {
                var m: html.Measure = .{};
                _ = html.layoutBlocks(g, blocks, 0, 100000, 0, false, false, &m);
                natural = m.width;
            } else if (t.nestedAt(row, col)) |nt| {
                _ = renderTable(vt_rt, vt_dw, rt, dwf, nt, 0, 0, 100000, false, &natural);
            } else if (cellLayout(vt_dw, dwf, t, row, col, 100000)) |lay| {
                defer _ = win.vtable(win.IDWriteTextLayout_VTable, lay).Release(lay);
                // SAFETY: written by GetMetrics
                var m: win.DWRITE_TEXT_METRICS = undefined;
                _ = win.vtable(win.IDWriteTextLayout_VTable, lay).GetMetrics(lay, &m);
                natural = m.widthIncludingTrailingWhitespace;
            }
            sizes[i] = natural + cell_pad_x * 2 + 1;
        }
    }
    table_layout.columnWidths(widths, sizes, t, max_width, cell_pad_x * 2 + 24);
    const table_w = table_layout.sum(widths, 0, cols);
    if (out_width) |o| o.* = table_w;

    for (0..rows) |row| {
        for (0..cols) |col| {
            const i = row * cols + col;
            sizes[i] = 0;
            content_h[i] = 0;
            if (table_layout.covered(t, row, col)) continue;
            const inner = table_layout.cellWidth(t, widths, row, col) - cell_pad_x * 2;
            const blocks = t.cellBlocks(row, col);
            if (blocks.len > 0) {
                var m: html.Measure = .{};
                content_h[i] = html.layoutBlocks(g, blocks, 0, inner, 0, false, false, &m) - m.trailing;
            } else if (t.nestedAt(row, col)) |nt| {
                content_h[i] = renderTable(vt_rt, vt_dw, rt, dwf, nt, 0, 0, inner, false, null) + nested_margin;
            } else {
                layouts[i] = cellLayout(vt_dw, dwf, t, row, col, inner);
                content_h[i] = layoutHeight(layouts[i]);
            }
            sizes[i] = @max(content_h[i], cell_min_text) + cell_pad_y * 2;
        }
    }
    table_layout.solve(heights, sizes, t, .row);

    const top = y;
    var row_y = top;
    for (0..rows) |row| {
        if (draw and md.Table.striped(t, row)) {
            vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + table_w, .bottom = row_y + heights[row] }, win.g_brush_stripe.?);
        }
        row_y += heights[row];
    }
    if (!draw) return row_y + 1 - y;

    row_y = top;
    for (0..rows) |row| {
        var cx = x;
        for (0..cols) |col| {
            const w = widths[col];
            defer cx += w;
            if (table_layout.covered(t, row, col)) continue;
            const i = row * cols + col;
            const cw = table_layout.cellWidth(t, widths, row, col);
            const ch = table_layout.cellHeight(t, heights, row, col);
            const span = t.spanAt(row, col);
            const ty = row_y + cell_pad_y + valignOffset(t.valignAt(row, col), ch - cell_pad_y * 2 - content_h[i]);
            const blocks = t.cellBlocks(row, col);
            if (blocks.len > 0) {
                _ = html.layoutBlocks(g, blocks, cx + cell_pad_x, cw - cell_pad_x * 2, ty, true, false, null);
            } else if (t.nestedAt(row, col)) |nt| {
                _ = renderTable(vt_rt, vt_dw, rt, dwf, nt, cx + cell_pad_x, ty, cw - cell_pad_x * 2, true, null);
            } else if (layouts[i]) |l| {
                const content = app.images.flow(t.cell(row, col));
                win.drawLayout(vt_rt, rt, l, cx + cell_pad_x, ty, win.g_brush_text.?, content);
                app.noteHit(.{
                    .content = content, .x = cx + cell_pad_x, .y = ty, .w = cw - cell_pad_x * 2,
                    .h = content_h[i], .header = (row == 0 and t.header_row) or (col == 0 and t.header_col), .alignment = t.alignAt(row, col),
                });
            }
            vt_rt.FillRectangle(rt, &.{ .left = cx, .top = row_y, .right = cx + cw, .bottom = row_y + 1 }, border);
            if (col == 0) vt_rt.FillRectangle(rt, &.{ .left = x, .top = row_y, .right = x + 1, .bottom = row_y + ch + 1 }, border);
            vt_rt.FillRectangle(rt, &.{ .left = cx + cw - 1, .top = row_y, .right = cx + cw, .bottom = row_y + ch + 1 }, border);
            if (row + span[1] >= rows) vt_rt.FillRectangle(rt, &.{ .left = cx, .top = row_y + ch, .right = cx + cw, .bottom = row_y + ch + 1 }, border);
        }
        row_y += heights[row];
    }
    return row_y + 1 - y;
}

