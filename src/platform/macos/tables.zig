const app = @import("../../main.zig");
const mac = @import("macos.zig");
const table_layout = @import("../../markdown/table_layout.zig");
const md = app.md;
const c = @import("c");

const CGFloat = mac.CGFloat;
const cgRect = mac.cgRect;
const createFont = mac.createFont;
const createCellAttrStr = mac.createCellAttrStr;
const createRichAttrStr = mac.createRichAttrStr;
const text_color = mac.text_color;
const suggestSize = mac.suggestSize;
const measureAndDrawAttrStr = mac.measureAndDrawAttrStr;
const noteHit = mac.noteHit;
const cell_pad_x = mac.cell_pad_x;
const cell_pad_y = mac.cell_pad_y;
const stripe_color = mac.stripe_color;
const table_border_color = mac.table_border_color;

pub fn cellValign(t: md.Table, row: usize, col: usize) md.VAlign {
    return t.valignAt(row, col);
}

pub fn headerCell(t: md.Table, row: usize, col: usize) bool {
    return (row == 0 and t.header_row) or (col == 0 and t.header_col);
}

fn blocksWidth(blocks: []const md.Block, body_font: c.CTFontRef) f32 {
    var w: f32 = 0;
    for (blocks) |b| {
        if (b.content.text.len == 0) continue;
        const attr_str = createRichAttrStr(b.content, body_font, text_color, 100000.0) orelse continue;
        defer c.CFRelease(attr_str);
        w = @max(w, @as(f32, @floatCast(suggestSize(@ptrCast(attr_str), 100000.0).width)));
    }
    return w;
}

fn blocksHeight(blocks: []const md.Block, w: CGFloat) CGFloat {
    const space = c.CGColorSpaceCreateDeviceRGB() orelse return 0;
    defer c.CGColorSpaceRelease(space);
    const scratch = c.CGBitmapContextCreate(null, 1, 1, 8, 4, space, c.kCGImageAlphaPremultipliedLast) orelse return 0;
    defer c.CGContextRelease(scratch);
    const fonts = mac.makeFonts();
    defer mac.releaseFonts(fonts);
    const noted = app.hits.items.len;
    defer app.hits.shrinkRetainingCapacity(noted);
    return mac.blocksHeight(scratch, blocks, 0, w, fonts);
}

pub fn cellNaturalWidth(ctx: c.CGContextRef, t: md.Table, row: usize, col: usize, body_font: c.CTFontRef, header_font: c.CTFontRef) f32 {
    if (t.nestedAt(row, col)) |nt| {
        var nw: CGFloat = 0;
        _ = drawTable(ctx, nt, 0, 0, 100000.0, body_font, false, &nw);
        return @floatCast(nw);
    }
    var buf: [1]md.Block = undefined;
    const blocks = cellBlocks(t, row, col, &buf);
    if (blocks.len > 0) return blocksWidth(blocks, body_font);
    const attr_str = createCellAttrStr(t, row, col, body_font, header_font, 100000.0) orelse return 0;
    defer c.CFRelease(attr_str);
    return @floatCast(suggestSize(@ptrCast(attr_str), 100000.0).width);
}

pub fn cellTextHeight(ctx: c.CGContextRef, t: md.Table, row: usize, col: usize, w: CGFloat, body_font: c.CTFontRef, header_font: c.CTFontRef) CGFloat {
    if (t.nestedAt(row, col)) |nt| return drawTable(ctx, nt, 0, 0, w, body_font, false, null) + md.nested_table_margin;
    var buf: [1]md.Block = undefined;
    const blocks = cellBlocks(t, row, col, &buf);
    if (blocks.len > 0) return blocksHeight(blocks, w);
    const attr_str = createCellAttrStr(t, row, col, body_font, header_font, w) orelse return 0;
    defer c.CFRelease(attr_str);
    return suggestSize(@ptrCast(attr_str), w).height;
}

/// y_cg is the top edge of the table in CG coordinates; returns the height used.
pub fn drawTable(ctx: c.CGContextRef, t: md.Table, x: CGFloat, y_cg: CGFloat, max_width: CGFloat, body_font: c.CTFontRef, draw: bool, out_width: ?*CGFloat) CGFloat {
    if (out_width) |o| o.* = 0;
    const nrows = t.rows();
    if (nrows == 0) return 0;
    const header_font = createFont("Helvetica Neue", c.CTFontGetSize(body_font), true, false);
    defer c.CFRelease(header_font);
    const widths = app.gpa.alloc(f32, t.columns) catch return 0;
    defer app.gpa.free(widths);
    const heights = app.gpa.alloc(f32, nrows) catch return 0;
    defer app.gpa.free(heights);
    const sizes = app.gpa.alloc(f32, nrows * t.columns) catch return 0;
    defer app.gpa.free(sizes);

    const pad_w: f32 = @floatCast(cell_pad_x * 2);
    const pad_h: f32 = @floatCast(cell_pad_y * 2);
    for (0..nrows) |row| for (0..t.columns) |col| {
        sizes[row * t.columns + col] = if (table_layout.covered(t, row, col)) 0 else cellNaturalWidth(ctx, t, row, col, body_font, header_font) + pad_w + 1;
    };
    table_layout.columnWidths(widths, sizes, t, @floatCast(max_width), pad_w + 24);
    const table_w: CGFloat = table_layout.sum(widths, 0, t.columns);
    if (out_width) |o| o.* = table_w;

    const min_h: f32 = @floatCast(c.CTFontGetSize(body_font) * 1.25 + cell_pad_y * 2);
    for (0..nrows) |row| for (0..t.columns) |col| {
        sizes[row * t.columns + col] = if (table_layout.covered(t, row, col)) 0 else @max(min_h, @as(f32, @floatCast(cellTextHeight(ctx, t, row, col, table_layout.cellWidth(t, widths, row, col) - pad_w, body_font, header_font))) + pad_h);
    };
    table_layout.solve(heights, sizes, t, .row);

    if (draw) {
        var row_top = y_cg;
        for (0..nrows) |row| {
            if (md.Table.striped(t, row)) {
                c.CGContextSetRGBFillColor(ctx, stripe_color.r, stripe_color.g, stripe_color.b, 1.0);
                c.CGContextFillRect(ctx, cgRect(x, row_top - heights[row], table_w, heights[row]));
            }
            var cx = x;
            for (0..t.columns) |col| {
                defer cx += widths[col];
                if (table_layout.covered(t, row, col)) continue;
                const cw: CGFloat = table_layout.cellWidth(t, widths, row, col);
                const ch: CGFloat = table_layout.cellHeight(t, heights, row, col);
                const inner_w = cw - cell_pad_x * 2;
                const inner_h = ch - cell_pad_y * 2;
                var buf: [1]md.Block = undefined;
                const blocks = cellBlocks(t, row, col, &buf);
                if (blocks.len > 0) {
                    const fonts = mac.makeFonts();
                    defer mac.releaseFonts(fonts);
                    const off = valignOffset(t, row, col, inner_h, blocksHeight(blocks, inner_w));
                    _ = mac.layoutBlocks(ctx, blocks, cx + cell_pad_x, inner_w, mac.g_height - (row_top - cell_pad_y - off), fonts, false);
                } else if (t.nestedAt(row, col)) |nt| {
                    _ = drawTable(ctx, nt, cx + cell_pad_x, row_top - cell_pad_y, inner_w, body_font, true, null);
                } else if (createCellAttrStr(t, row, col, body_font, header_font, inner_w)) |attr_str| {
                    defer c.CFRelease(attr_str);
                    const text_h = suggestSize(@ptrCast(attr_str), inner_w).height;
                    const off = valignOffset(t, row, col, inner_h, text_h);
                    const cell_h = measureAndDrawAttrStr(ctx, @ptrCast(attr_str), cx + cell_pad_x, row_top - cell_pad_y - off, inner_w);
                    noteHit(app.images.flow(t.cell(row, col)), cx + cell_pad_x, row_top - cell_pad_y - off, inner_w, cell_h, .body, headerCell(t, row, col), t.alignAt(row, col));
                }
                c.CGContextSetRGBFillColor(ctx, table_border_color.r, table_border_color.g, table_border_color.b, 1.0);
                c.CGContextFillRect(ctx, cgRect(cx, row_top - 1, cw, 1));
                c.CGContextFillRect(ctx, cgRect(cx, row_top - ch - 1, cw, 1));
                c.CGContextFillRect(ctx, cgRect(cx, row_top - ch - 1, 1, ch + 1));
                c.CGContextFillRect(ctx, cgRect(cx + cw - 1, row_top - ch - 1, 1, ch + 1));
            }
            row_top -= heights[row];
        }
    }
    return table_layout.sum(heights, 0, nrows) + 1;
}

fn valignOffset(t: md.Table, row: usize, col: usize, inner_h: CGFloat, content_h: CGFloat) CGFloat {
    return switch (cellValign(t, row, col)) {
        .none, .middle => @max((inner_h - content_h) / 2, 0),
        .bottom => @max(inner_h - content_h, 0),
        .top => 0,
    };
}

/// A plain cell with a floated image runs its own float bands like a one-paragraph block list.
fn cellBlocks(t: md.Table, row: usize, col: usize, buf: *[1]md.Block) []const md.Block {
    const blocks = t.cellBlocks(row, col);
    if (blocks.len > 0 or t.nestedAt(row, col) != null) return blocks;
    const content = t.cell(row, col);
    for (content.images) |im| if (im.float != .none) {
        buf[0] = .{ .kind = .paragraph, .content = content, .alignment = t.alignAt(row, col) };
        return buf[0..1];
    };
    return blocks;
}
