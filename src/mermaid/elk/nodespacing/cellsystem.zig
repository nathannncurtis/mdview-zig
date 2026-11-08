const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");

// ElkRectangle
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn unionWith(self: *Rect, other: Rect) void {
        var x1 = util.javaMin(self.x, other.x);
        var y1 = util.javaMin(self.y, other.y);
        var x2 = util.javaMax(self.x + self.width, other.x + other.width);
        var y2 = util.javaMax(self.y + self.height, other.y + other.height);
        if (x2 < x1) std.mem.swap(f64, &x1, &x2);
        if (y2 < y1) std.mem.swap(f64, &y1, &y2);
        self.* = .{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
    }
};

pub const ContainerArea = enum { begin, center, end };
pub const HorizontalLabelAlignment = enum { left, center, right };
pub const VerticalLabelAlignment = enum { top, center, bottom };
pub const Strip = enum { vertical, horizontal };

pub const AtomicCell = struct {
    minimum_content_area_size: lg.Vec = .{},
};

pub const LabelCell = struct {
    horizontal_layout_mode: bool = true,
    horizontal_alignment: HorizontalLabelAlignment = .center,
    vertical_alignment: VerticalLabelAlignment = .center,
    gap: f64,
    labels: std.ArrayList(*lg.LLabel) = .empty,
    minimum_content_area_size: lg.Vec = .{},
};

pub const StripContainerCell = struct {
    container_mode: Strip,
    symmetrical: bool,
    gap: f64,
    cells: [3]?*Cell = .{ null, null, null },
};

pub const GridContainerCell = struct {
    gap: f64,
    tabular: bool,
    symmetrical: bool,
    cells: [3][3]?*Cell = .{ .{ null, null, null }, .{ null, null, null }, .{ null, null, null } },
    center_cell_minimum_size: ?lg.Vec = null,
    only_center_cell_contributes_to_minimum_size: bool = false,
    center_cell_rect: Rect = .{},
};

// Cell and its subclasses AtomicCell, LabelCell, StripContainerCell and GridContainerCell
pub const Cell = struct {
    padding: lg.Margin = .{},
    rect: Rect = .{},
    contributes_to_minimum_width: bool = false,
    contributes_to_minimum_height: bool = false,
    kind: Kind,

    pub const Kind = union(enum) {
        atomic: AtomicCell,
        label: LabelCell,
        strip: StripContainerCell,
        grid: GridContainerCell,
    };

    pub fn create(a: std.mem.Allocator, kind: Kind) lg.Error!*Cell {
        const c = try a.create(Cell);
        c.* = .{ .kind = kind };
        return c;
    }

    pub fn getMinimumWidth(self: *const Cell) f64 {
        const p = self.padding;
        return switch (self.kind) {
            .atomic => |c| c.minimum_content_area_size.x + p.left + p.right,
            .label => |c| c.minimum_content_area_size.x + p.left + p.right,
            .strip => |*c| stripMinimumWidth(self, c),
            .grid => |*c| gridMinimumWidth(self, c),
        };
    }

    pub fn getMinimumHeight(self: *const Cell) f64 {
        const p = self.padding;
        return switch (self.kind) {
            .atomic => |c| c.minimum_content_area_size.y + p.top + p.bottom,
            .label => |c| c.minimum_content_area_size.y + p.top + p.bottom,
            .strip => |*c| stripMinimumHeight(self, c),
            .grid => |*c| gridMinimumHeight(self, c),
        };
    }

    pub fn layoutChildrenHorizontally(self: *Cell) void {
        switch (self.kind) {
            .strip => |*c| stripLayoutHorizontally(self, c),
            .grid => |*c| gridLayoutHorizontally(self, c),
            else => {},
        }
    }

    pub fn layoutChildrenVertically(self: *Cell) void {
        switch (self.kind) {
            .strip => |*c| stripLayoutVertically(self, c),
            .grid => |*c| gridLayoutVertically(self, c),
            else => {},
        }
    }

    fn isContainer(self: *const Cell) bool {
        return self.kind == .strip or self.kind == .grid;
    }

    // LabelCell.addLabel
    pub fn addLabel(self: *Cell, a: std.mem.Allocator, label: *lg.LLabel) lg.Error!void {
        const c = &self.kind.label;
        try c.labels.append(a, label);
        const label_size = label.size;
        if (c.horizontal_layout_mode) {
            c.minimum_content_area_size.x = util.javaMax(c.minimum_content_area_size.x, label_size.x);
            c.minimum_content_area_size.y += label_size.y;
            if (c.labels.items.len > 1) c.minimum_content_area_size.y += c.gap;
        } else {
            c.minimum_content_area_size.x += label_size.x;
            c.minimum_content_area_size.y = util.javaMax(c.minimum_content_area_size.y, label_size.y);
            if (c.labels.items.len > 1) c.minimum_content_area_size.x += c.gap;
        }
    }

    // LabelCell.applyLabelLayout
    pub fn applyLabelLayout(self: *Cell) void {
        const c = &self.kind.label;
        const cell_rect = self.rect;
        const cell_padding = self.padding;
        if (c.horizontal_layout_mode) {
            var y_pos = cell_rect.y;
            if (c.vertical_alignment == .center) {
                y_pos += (cell_rect.height - c.minimum_content_area_size.y) / 2;
            } else if (c.vertical_alignment == .bottom) {
                y_pos += cell_rect.height - c.minimum_content_area_size.y;
            }
            for (c.labels.items) |label| {
                const label_size = label.size;
                var label_pos: lg.Vec = .{};
                label_pos.y = y_pos;
                y_pos += label_size.y + c.gap;
                label_pos.x = switch (c.horizontal_alignment) {
                    .left => cell_rect.x + cell_padding.left,
                    .center => cell_rect.x + cell_padding.left + (cell_rect.width - label_size.x) / 2,
                    .right => cell_rect.x + cell_rect.width - cell_padding.right - label_size.x,
                };
                label.pos = label_pos;
            }
        } else {
            var x_pos = cell_rect.x;
            if (c.horizontal_alignment == .center) {
                x_pos += (cell_rect.width - c.minimum_content_area_size.x) / 2;
            } else if (c.horizontal_alignment == .right) {
                x_pos += cell_rect.width - c.minimum_content_area_size.x;
            }
            for (c.labels.items) |label| {
                const label_size = label.size;
                var label_pos: lg.Vec = .{};
                label_pos.x = x_pos;
                x_pos += label_size.x + c.gap;
                label_pos.y = switch (c.vertical_alignment) {
                    .top => cell_rect.y + cell_padding.top,
                    .center => cell_rect.y + cell_padding.top + (cell_rect.height - label_size.y) / 2,
                    .bottom => cell_rect.y + cell_rect.height - cell_padding.bottom - label_size.y,
                };
                label.pos = label_pos;
            }
        }
    }
};

// ContainerCell helpers
fn minWidthOfCell(cell: ?*const Cell, respect_contribution_flag: bool) f64 {
    const c = cell orelse return 0;
    if (respect_contribution_flag and !c.contributes_to_minimum_width) return 0;
    if (c.kind == .atomic and c.kind.atomic.minimum_content_area_size.x == 0) return 0;
    return c.getMinimumWidth();
}

fn minHeightOfCell(cell: ?*const Cell, respect_contribution_flag: bool) f64 {
    const c = cell orelse return 0;
    if (respect_contribution_flag and !c.contributes_to_minimum_height) return 0;
    if (c.kind == .atomic and c.kind.atomic.minimum_content_area_size.y == 0) return 0;
    return c.getMinimumHeight();
}

fn applyHorizontalLayout(cell: ?*Cell, x: f64, width: f64) void {
    const c = cell orelse return;
    c.rect.x = x;
    c.rect.width = width;
}

fn applyVerticalLayout(cell: ?*Cell, y: f64, height: f64) void {
    const c = cell orelse return;
    c.rect.y = y;
    c.rect.height = height;
}

fn layoutContainerChildren(cells: []const ?*Cell, horizontally: bool) void {
    for (cells) |cell| {
        const c = cell orelse continue;
        if (!c.isContainer()) continue;
        if (horizontally) c.layoutChildrenHorizontally() else c.layoutChildrenVertically();
    }
}

// StripContainerCell
fn stripMaxContributing(c: *const StripContainerCell, width: bool) f64 {
    var m: ?f64 = null;
    for (c.cells) |cell| {
        const x = cell orelse continue;
        if (width and !x.contributes_to_minimum_width) continue;
        if (!width and !x.contributes_to_minimum_height) continue;
        const v = if (width) x.getMinimumWidth() else x.getMinimumHeight();
        m = if (m) |mm| util.javaMax(mm, v) else v;
    }
    return m orelse 0;
}

fn stripMinCellWidths(c: *const StripContainerCell, respect: bool) [3]f64 {
    var w = [3]f64{ minWidthOfCell(c.cells[0], respect), minWidthOfCell(c.cells[1], respect), minWidthOfCell(c.cells[2], respect) };
    if (c.symmetrical) {
        w[0] = util.javaMax(w[0], w[2]);
        w[2] = w[0];
    }
    return w;
}

fn stripMinCellHeights(c: *const StripContainerCell, respect: bool) [3]f64 {
    var h = [3]f64{ minHeightOfCell(c.cells[0], respect), minHeightOfCell(c.cells[1], respect), minHeightOfCell(c.cells[2], respect) };
    if (c.symmetrical) {
        h[0] = util.javaMax(h[0], h[2]);
        h[2] = h[0];
    }
    return h;
}

fn sumActive(values: [3]f64, gap: f64) f64 {
    var sum: f64 = 0;
    var active: usize = 0;
    for (values) |v| {
        if (v > 0) {
            sum += v;
            active += 1;
        }
    }
    if (active > 1) sum += gap * @as(f64, @floatFromInt(active - 1));
    return sum;
}

fn stripMinimumWidth(self: *const Cell, c: *const StripContainerCell) f64 {
    const width = if (c.container_mode == .vertical) stripMaxContributing(c, true) else sumActive(stripMinCellWidths(c, true), c.gap);
    return if (width > 0) width + self.padding.left + self.padding.right else 0;
}

fn stripMinimumHeight(self: *const Cell, c: *const StripContainerCell) f64 {
    const height = if (c.container_mode == .vertical) sumActive(stripMinCellHeights(c, true), c.gap) else stripMaxContributing(c, false);
    return if (height > 0) height + self.padding.top + self.padding.bottom else 0;
}

fn stripLayoutHorizontally(self: *Cell, c: *StripContainerCell) void {
    const r = self.rect;
    const p = self.padding;
    if (c.container_mode == .vertical) {
        const x_pos = r.x + p.left;
        const width = r.width - p.left - p.right;
        for (c.cells) |cell| applyHorizontalLayout(cell, x_pos, width);
    } else {
        var w = stripMinCellWidths(c, false);
        applyHorizontalLayout(c.cells[0], r.x + p.left, w[0]);
        applyHorizontalLayout(c.cells[2], r.x + r.width - p.right - w[2], w[2]);
        var free = r.width - p.left - p.right;
        if (w[0] > 0) {
            free -= w[0] + c.gap;
            w[0] += c.gap;
        }
        if (w[2] > 0) free -= w[2] + c.gap;
        w[1] = util.javaMax(w[1], free);
        applyHorizontalLayout(c.cells[1], r.x + p.left + w[0] - (w[1] - free) / 2, w[1]);
    }
    layoutContainerChildren(&c.cells, true);
}

fn stripLayoutVertically(self: *Cell, c: *StripContainerCell) void {
    const r = self.rect;
    const p = self.padding;
    if (c.container_mode == .vertical) {
        var h = stripMinCellHeights(c, false);
        applyVerticalLayout(c.cells[0], r.y + p.top, h[0]);
        applyVerticalLayout(c.cells[2], r.y + r.height - p.bottom - h[2], h[2]);
        const content_area_height = r.height - p.top - p.bottom;
        var free = content_area_height;
        if (h[0] > 0) {
            h[0] += c.gap;
            free -= h[0];
        }
        if (h[2] > 0) free -= h[2] + c.gap;
        h[1] = util.javaMax(h[1], free);
        applyVerticalLayout(c.cells[1], r.y + p.top + h[0] - (h[1] - free) / 2, h[1]);
    } else {
        const y_pos = r.y + p.top;
        const height = r.height - p.top - p.bottom;
        for (c.cells) |cell| applyVerticalLayout(cell, y_pos, height);
    }
    layoutContainerChildren(&c.cells, false);
}

// GridContainerCell
fn gridMinWidthOfColumn(c: *const GridContainerCell, column: usize, row: ?usize, respect: bool) f64 {
    var max_min_width: f64 = 0;
    if (row) |ri| {
        max_min_width = minWidthOfCell(c.cells[ri][column], respect);
    } else {
        for (0..3) |ri| max_min_width = util.javaMax(max_min_width, minWidthOfCell(c.cells[ri][column], respect));
    }
    if (column == 1) {
        if (c.center_cell_minimum_size) |m| max_min_width = util.javaMax(max_min_width, m.x);
    }
    return max_min_width;
}

fn gridMinColumnWidths(c: *const GridContainerCell, row: ?usize, respect: bool) [3]f64 {
    var w = [3]f64{ gridMinWidthOfColumn(c, 0, row, respect), gridMinWidthOfColumn(c, 1, row, respect), gridMinWidthOfColumn(c, 2, row, respect) };
    if (c.symmetrical) {
        w[0] = util.javaMax(w[0], w[2]);
        w[2] = w[0];
    }
    return w;
}

fn gridMinHeightOfRow(c: *const GridContainerCell, row: usize, respect: bool) f64 {
    var max_min_height: f64 = 0;
    for (0..3) |col| max_min_height = util.javaMax(max_min_height, minHeightOfCell(c.cells[row][col], respect));
    if (row == 1) {
        if (c.center_cell_minimum_size) |m| max_min_height = util.javaMax(max_min_height, m.y);
    }
    return max_min_height;
}

fn gridMinRowHeights(c: *const GridContainerCell, respect: bool) [3]f64 {
    var h = [3]f64{ gridMinHeightOfRow(c, 0, respect), gridMinHeightOfRow(c, 1, respect), gridMinHeightOfRow(c, 2, respect) };
    if (c.symmetrical) {
        h[0] = util.javaMax(h[0], h[2]);
        h[2] = h[0];
    }
    return h;
}

fn gridMinimumWidth(self: *const Cell, c: *const GridContainerCell) f64 {
    var width: f64 = 0;
    if (c.only_center_cell_contributes_to_minimum_size) {
        if (c.center_cell_minimum_size) |m| {
            width = m.x;
        } else if (c.cells[1][1]) |cc| {
            width = cc.getMinimumWidth();
        }
    } else if (c.tabular) {
        width = sumActive(gridMinColumnWidths(c, null, true), c.gap);
    } else {
        for (0..3) |area| width = util.javaMax(width, sumActive(gridMinColumnWidths(c, area, true), c.gap));
    }
    return if (width > 0) width + self.padding.left + self.padding.right else 0;
}

fn gridMinimumHeight(self: *const Cell, c: *const GridContainerCell) f64 {
    var height: f64 = 0;
    if (c.only_center_cell_contributes_to_minimum_size) {
        if (c.center_cell_minimum_size) |m| {
            height = m.y;
        } else if (c.cells[1][1]) |cc| {
            height = cc.getMinimumHeight();
        }
    } else {
        height = sumActive(gridMinRowHeights(c, true), c.gap);
    }
    return if (height > 0) height + self.padding.top + self.padding.bottom else 0;
}

fn gridLayoutHorizontally(self: *Cell, c: *GridContainerCell) void {
    if (c.tabular) {
        const col_widths = gridMinColumnWidths(c, null, false);
        for (0..3) |row| gridApplyWidthsToRow(self, c, row, col_widths);
    } else {
        for (0..3) |row| gridApplyWidthsToRow(self, c, row, gridMinColumnWidths(c, row, false));
    }
}

fn gridApplyWidthsToRow(self: *Cell, c: *GridContainerCell, row: usize, widths: [3]f64) void {
    var w = widths;
    const r = self.rect;
    const p = self.padding;
    gridApplyWidthToColumn(c, 0, r.x + p.left, w);
    gridApplyWidthToColumn(c, 2, r.x + r.width - p.right - w[2], w);
    var free = r.width - p.left - p.right;
    if (w[0] > 0) {
        w[0] += c.gap;
        free -= w[0];
    }
    if (w[2] > 0) {
        w[2] += c.gap;
        free -= w[2];
    }
    const center_width = util.javaMax(0, free);
    w[1] = util.javaMax(w[1], free);
    gridApplyWidthToColumn(c, 1, r.x + p.left + w[0] - (w[1] - free) / 2, w);
    if (row == 1) {
        c.center_cell_rect.width = center_width;
        c.center_cell_rect.x = r.x + p.left + (center_width - free) / 2;
    }
}

fn gridApplyWidthToColumn(c: *GridContainerCell, column: usize, x: f64, widths: [3]f64) void {
    for (0..3) |row| applyHorizontalLayout(c.cells[row][column], x, widths[column]);
}

fn gridApplyHeightToRow(c: *GridContainerCell, row: usize, y: f64, heights: [3]f64) void {
    for (0..3) |col| applyVerticalLayout(c.cells[row][col], y, heights[row]);
}

fn gridLayoutVertically(self: *Cell, c: *GridContainerCell) void {
    const r = self.rect;
    const p = self.padding;
    var h = gridMinRowHeights(c, false);
    gridApplyHeightToRow(c, 0, r.y + p.top, h);
    gridApplyHeightToRow(c, 2, r.y + r.height - p.bottom - h[2], h);
    var free = r.height - p.top - p.bottom;
    if (h[0] > 0) {
        h[0] += c.gap;
        free -= h[0];
    }
    if (h[2] > 0) {
        h[2] += c.gap;
        free -= h[2];
    }
    c.center_cell_rect.height = util.javaMax(0, free);
    c.center_cell_rect.y = r.y + p.top + (c.center_cell_rect.height - free) / 2;
    h[1] = util.javaMax(h[1], free);
    gridApplyHeightToRow(c, 1, r.y + p.top + h[0] - (h[1] - free) / 2, h);
}
