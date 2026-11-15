const std = @import("std");
const eg = @import("../elk_graph.zig");
const util = @import("../box/util.zig");

const Allocator = std.mem.Allocator;
const ElkNode = eg.ElkNode;
const List = std.ArrayList;

fn removeFirst(comptime T: type, list: *List(*T), item: *T) void {
    for (list.items, 0..) |x, i| if (x == item) {
        _ = list.orderedRemove(i);
        return;
    };
}

fn contains(list: []const *ElkNode, item: *ElkNode) bool {
    for (list) |x| if (x == item) return true;
    return false;
}

const inf = std.math.inf(f64);

pub const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };

// util.BlockRow
pub const BlockRow = struct {
    a: Allocator,
    x: f64,
    y: f64,
    width: f64 = 0,
    height: f64 = 0,
    nn: f64,
    rects: List(*ElkNode) = .empty,

    pub fn create(a: Allocator, x: f64, y: f64, nn: f64) Allocator.Error!*BlockRow {
        const r = try a.create(BlockRow);
        r.* = .{ .a = a, .x = x, .y = y, .nn = nn };
        return r;
    }

    pub fn addRectangle(r: *BlockRow, rect: *ElkNode) Allocator.Error!void {
        const first = r.rects.items.len == 0;
        rect.x = r.x + r.width + (if (first) 0 else r.nn);
        rect.y = r.y;
        r.height = @max(r.height, rect.height);
        r.width += rect.width + (if (first) 0 else r.nn);
        try r.rects.append(r.a, rect);
    }

    pub fn removeRectangle(r: *BlockRow, rect: *ElkNode, update: bool) void {
        removeFirst(ElkNode, &r.rects, rect);
        if (update) r.updateRow();
    }

    pub fn updateRow(r: *BlockRow) void {
        var width: f64 = 0;
        var height: f64 = 0;
        for (r.rects.items) |rect| {
            rect.x = r.x + width;
            rect.y = r.y;
            width += rect.width + r.nn;
            height = @max(height, rect.height + r.nn);
        }
        r.width = width - r.nn;
        r.height = height - r.nn;
    }

    pub fn expand(r: *BlockRow, width_for_row: f64, additional_height_for_row: f64, index: usize) void {
        const additional_width_for_rect = (width_for_row - r.width) / @as(f64, @floatFromInt(r.rects.items.len));
        r.height += additional_height_for_row;
        r.width = width_for_row;
        for (r.rects.items, 0..) |rect, i| {
            const old_w = rect.width;
            const old_h = rect.height;
            rect.x += @as(f64, @floatFromInt(i)) * additional_width_for_rect;
            rect.y += @as(f64, @floatFromInt(index)) * additional_height_for_row;
            rect.width += additional_width_for_rect;
            rect.height = r.height;
            util.translateAligned(rect, .{ .x = rect.width, .y = rect.height }, .{ .x = old_w, .y = old_h });
        }
    }
};

// util.Block
pub const Block = struct {
    a: Allocator,
    smallest_rect_width: f64 = inf,
    min_width: f64 = 0,
    width: f64 = 0,
    min_height: f64 = 0,
    smallest_rect_height: f64 = inf,
    average_height: f64 = 0,
    max_height: f64 = 0,
    height: f64 = 0,
    children: List(*ElkNode) = .empty,
    rows: List(*BlockRow) = .empty,
    x: f64,
    y: f64,
    parent_row: *RectRow,
    stack: ?*BlockStack = null,
    nn: f64,
    fixed: bool = false,
    position_fixed: bool = false,

    pub fn create(a: Allocator, x: f64, y: f64, parent_row: *RectRow, nn: f64) Allocator.Error!*Block {
        const b = try a.create(Block);
        b.* = .{ .a = a, .x = x, .y = y, .parent_row = parent_row, .nn = nn };
        return b;
    }

    pub fn addChild(b: *Block, rect: *ElkNode) Allocator.Error!void {
        if (b.rows.items.len == 0) try b.rows.append(b.a, try BlockRow.create(b.a, b.x, b.y, b.nn));
        try b.children.append(b.a, rect);
        try b.rows.items[b.rows.items.len - 1].addRectangle(rect);
        try b.adjustSizeAdd(rect);
    }

    pub fn addChildInNewRow(b: *Block, rect: *ElkNode) Allocator.Error!void {
        try b.children.append(b.a, rect);
        const last = b.lastRow();
        try b.rows.append(b.a, try BlockRow.create(b.a, b.x, last.y + last.height + b.nn, b.nn));
        try b.lastRow().addRectangle(rect);
        try b.adjustSizeAdd(rect);
    }

    pub fn removeChild(b: *Block, rect: *ElkNode) void {
        removeFirst(ElkNode, &b.children, rect);
        for (b.rows.items, 0..) |row, i| {
            if (contains(row.rects.items, rect)) {
                row.removeRectangle(rect, true);
                if (row.rects.items.len == 0) _ = b.rows.orderedRemove(i);
                break;
            }
        }
        b.adjustSizeAfterRemove();
    }

    pub fn setLocation(b: *Block, x: f64, y: f64) void {
        const dx = x - b.x;
        const dy = y - b.y;
        for (b.children.items) |rect| {
            rect.x += dx;
            rect.y += dy;
        }
        for (b.rows.items) |row| {
            row.x = row.x + x - b.x;
            row.y = row.y + y - b.y;
        }
        b.x = x;
        b.y = y;
    }

    pub fn lastRow(b: *const Block) *BlockRow {
        return b.rows.items[b.rows.items.len - 1];
    }

    fn adjustSizeAdd(b: *Block, rect: *ElkNode) Allocator.Error!void {
        const n = b.children.items.len;
        const width_of_last_row = b.lastRow().width;
        b.smallest_rect_width = @min(b.smallest_rect_width, rect.width);
        b.width = @max(b.width, width_of_last_row);
        b.min_width = @max(b.min_width, rect.width + (if (n == 1) 0 else b.nn));
        b.smallest_rect_height = @min(b.smallest_rect_height, rect.height);
        b.max_height += rect.height + (if (n == 1) 0 else b.nn);
        b.min_height = @max(b.min_height, rect.height);
        var total_height: f64 = if (b.rows.items.len > 0) @as(f64, @floatFromInt(b.rows.items.len - 1)) * b.nn else 0;
        for (b.rows.items) |row| total_height += row.height;
        b.height = total_height;
        const nf: f64 = @floatFromInt(n);
        b.average_height = b.max_height / nf - b.nn * ((nf - 1) / nf);
        b.parent_row.notifyAboutNodeChange();
    }

    pub fn widthForTargetHeight(b: *Block, height: f64) Allocator.Error!f64 {
        if (b.max_height <= height) return b.min_width;
        if (try b.fits(b.min_width, height, false)) return b.min_width;
        var upper = b.width;
        var lower = b.min_width;
        var viable = b.width;
        var new_width = (upper - lower) / 2 + lower;
        while (lower + 1 < upper) {
            if (try b.fits(new_width, height, false)) {
                viable = new_width;
                upper = new_width;
            } else {
                lower = new_width;
            }
            new_width = (upper - lower) / 2 + lower;
        }
        return viable;
    }

    pub fn heightForTargetWidth(b: *Block, width: f64) Allocator.Error!f64 {
        return (try b.placeBounds(width, false)).height;
    }

    fn placeBounds(b: *Block, width: f64, place_rects: bool) Allocator.Error!Bounds {
        var current_x: f64 = 0;
        var current_y = b.y;
        var current_width: f64 = 0;
        var current_height: f64 = 0;
        var max_height_in_row: f64 = 0;
        var width_in_row: f64 = 0;
        var row: usize = 0;
        if (place_rects) {
            b.rows.clearRetainingCapacity();
            try b.rows.append(b.a, try BlockRow.create(b.a, b.x, b.y, b.nn));
        }
        var index: usize = 0;
        for (b.children.items) |rect| {
            if (current_x + rect.width + (if (index > 0) b.nn else 0) > width and max_height_in_row > 0) {
                current_x = 0;
                current_y += max_height_in_row + b.nn;
                current_width = @max(current_width, width_in_row);
                current_height += max_height_in_row + b.nn;
                max_height_in_row = 0;
                width_in_row = 0;
                if (place_rects) {
                    row += 1;
                    try b.rows.append(b.a, try BlockRow.create(b.a, b.x, current_y, b.nn));
                }
                index = 0;
            }
            width_in_row += rect.width + (if (index > 0) b.nn else 0);
            max_height_in_row = @max(max_height_in_row, rect.height);
            if (place_rects) try b.rows.items[row].addRectangle(rect);
            current_x += rect.width + (if (index > 0) b.nn else 0);
            index += 1;
        }
        current_width = @max(current_width, width_in_row);
        current_height += max_height_in_row;
        if (place_rects) {
            b.width = current_width;
            b.height = current_height;
            b.parent_row.notifyAboutNodeChange();
        }
        return .{ .x = b.x, .y = b.y, .width = current_width, .height = current_height };
    }

    fn fits(b: *Block, width: f64, height: f64, place_rects: bool) Allocator.Error!bool {
        const bounds = try b.placeBounds(width, place_rects);
        return bounds.width <= width and bounds.height <= height;
    }

    pub fn placeRectsIn(b: *Block, width: f64) Allocator.Error!bool {
        const old_w = b.width;
        const old_h = b.height;
        const bounds = try b.placeBounds(width, true);
        return bounds.width != old_w or bounds.height != old_h;
    }

    fn adjustSizeAfterRemove(b: *Block) void {
        var new_width: f64 = 0;
        var new_height: f64 = 0;
        var write: usize = 0;
        for (b.rows.items, 0..) |row, index| {
            if (row.rects.items.len == 0) continue;
            new_width = @max(new_width, row.width);
            new_height += row.height + (if (index > 0) b.nn else 0);
        }
        for (b.rows.items) |row| {
            if (row.rects.items.len == 0) continue;
            b.rows.items[write] = row;
            write += 1;
        }
        b.rows.items.len = write;
        b.height = new_height;
        b.width = new_width;
        b.min_width = 0;
        b.min_height = 0;
        b.max_height = 0;
        b.smallest_rect_height = inf;
        b.smallest_rect_width = inf;
        for (b.children.items) |rect| {
            b.smallest_rect_width = @min(b.smallest_rect_width, rect.width);
            b.min_width = @max(b.min_width, rect.width);
            b.min_height = @max(b.min_height, rect.height);
            b.smallest_rect_height = @min(b.smallest_rect_height, rect.height);
            b.max_height += rect.height + b.nn;
        }
        const nf: f64 = @floatFromInt(b.children.items.len);
        b.average_height = b.max_height / nf - b.nn * ((nf - 1) / nf);
        b.parent_row.notifyAboutNodeChange();
    }

    pub fn expand(b: *Block, additional_width_per_block: f64, additional_height_for_block: f64) void {
        const width_for_row = b.width + additional_width_per_block;
        b.width += additional_width_per_block;
        b.height += additional_height_for_block;
        const additional_height_for_row = additional_height_for_block / @as(f64, @floatFromInt(b.rows.items.len));
        for (b.rows.items, 0..) |row, index| row.expand(width_for_row, additional_height_for_row, index);
    }

    pub fn lastRowNewX(b: *const Block) f64 {
        const r = b.lastRow();
        return r.x + r.width;
    }

    pub fn lastRowY(b: *const Block) f64 {
        return b.lastRow().y;
    }

    pub fn resetBlock(b: *Block) void {
        b.adjustSizeAfterRemove();
    }
};

// util.BlockStack
pub const BlockStack = struct {
    a: Allocator,
    blocks: List(*Block) = .empty,
    x: f64,
    y: f64,
    width: f64 = 0,
    height: f64 = 0,
    nn: f64,

    pub fn create(a: Allocator, x: f64, y: f64, nn: f64) Allocator.Error!*BlockStack {
        const s = try a.create(BlockStack);
        s.* = .{ .a = a, .x = x, .y = y, .nn = nn };
        return s;
    }

    pub fn addBlock(s: *BlockStack, block: *Block) Allocator.Error!void {
        block.stack = s;
        s.width = @max(s.width, block.width);
        s.height += block.height + (if (s.blocks.items.len == 0) 0 else s.nn);
        try s.blocks.append(s.a, block);
    }

    pub fn updateDimension(s: *BlockStack) void {
        var height: f64 = 0;
        var width: f64 = 0;
        for (s.blocks.items, 0..) |block, index| {
            width = @max(width, block.width);
            height += block.height + (if (index > 0) s.nn else 0);
        }
        s.height = height;
        s.width = width;
    }

    pub fn setLocation(s: *BlockStack, x: f64, y: f64) void {
        const dx = x - s.x;
        const dy = y - s.y;
        for (s.blocks.items) |block| block.setLocation(block.x + dx, block.y + dy);
        s.x = x;
        s.y = y;
    }

    fn minimumWidth(s: *const BlockStack) f64 {
        var min: f64 = 0;
        for (s.blocks.items) |block| min = @max(min, block.min_width);
        return min;
    }

    pub fn widthForFixedHeight(s: *BlockStack, height: f64) Allocator.Error!f64 {
        if (s.blocks.items.len == 1) return s.blocks.items[0].widthForTargetHeight(height);
        const min_width = s.minimumWidth();
        var upper = s.width;
        var lower = min_width;
        var viable = s.width;
        var new_width = (upper - lower) / 2 + lower;
        while (lower + 1 < upper) {
            var total_height: f64 = 0;
            for (s.blocks.items) |block| total_height += try block.heightForTargetWidth(new_width);
            if (total_height < height) {
                viable = new_width;
                upper = new_width;
            } else {
                lower = new_width;
            }
            new_width = (upper - lower) / 2 + lower;
        }
        return viable;
    }

    pub fn placeRectsIn(s: *BlockStack, target_width: f64) Allocator.Error!void {
        var current_y = s.y;
        var current_height: f64 = 0;
        var current_width: f64 = 0;
        for (s.blocks.items) |block| {
            block.setLocation(s.x, current_y);
            _ = try block.placeRectsIn(target_width);
            current_width = @max(current_width, block.width);
            current_y += block.height + s.nn;
            current_height = current_y;
        }
        s.width = current_width;
        s.height = current_height;
    }

    pub fn expand(s: *BlockStack, additional_width: f64, additional_height: f64) void {
        const per_block = additional_height / @as(f64, @floatFromInt(s.blocks.items.len));
        for (s.blocks.items, 0..) |block, index| {
            block.setLocation(block.x, block.y + @as(f64, @floatFromInt(index)) * per_block);
            block.expand(s.width - block.width + additional_width, per_block);
        }
    }
};

// util.RectRow
pub const RectRow = struct {
    a: Allocator,
    height: f64 = 0,
    width: f64 = 0,
    y: f64,
    nn: f64,
    children: List(*Block) = .empty,
    stacks: List(*BlockStack) = .empty,

    pub fn create(a: Allocator, y: f64, nn: f64) Allocator.Error!*RectRow {
        const r = try a.create(RectRow);
        r.* = .{ .a = a, .y = y, .nn = nn };
        return r;
    }

    pub fn notifyAboutNodeChange(r: *RectRow) void {
        var total_stack_width: f64 = 0;
        var new_max_height = -inf;
        for (r.children.items, 0..) |child, index| {
            total_stack_width += child.width + (if (index > 0) r.nn else 0);
            new_max_height = @max(new_max_height, child.height);
        }
        r.width = total_stack_width;
        r.height = new_max_height;
    }

    pub fn expand(r: *RectRow, width: f64, additional_height: f64) void {
        const additional_width = width - r.width;
        const per_stack = additional_width / @as(f64, @floatFromInt(r.stacks.items.len));
        for (r.stacks.items, 0..) |stack, index| {
            const additional_height_for_stack = r.height - stack.height + additional_height;
            stack.setLocation(stack.x + @as(f64, @floatFromInt(index)) * per_stack, stack.y);
            stack.expand(per_stack, additional_height_for_stack);
        }
    }

    pub fn firstBlock(r: *const RectRow) *Block {
        return r.children.items[0];
    }

    pub fn lastBlock(r: *const RectRow) *Block {
        return r.children.items[r.children.items.len - 1];
    }

    pub fn addBlock(r: *RectRow, block: *Block) Allocator.Error!void {
        r.height = @max(r.height, block.height);
        r.width += block.width + (if (r.children.items.len == 0) 0 else r.nn);
        try r.children.append(r.a, block);
    }

    pub fn removeBlock(r: *RectRow, block: *Block) void {
        removeFirst(Block, &r.children, block);
        r.width -= block.width + (if (r.children.items.len == 0) 0 else r.nn);
        var new_max_height = std.math.floatTrueMin(f64);
        for (r.children.items) |child| new_max_height = @max(new_max_height, child.height);
        r.height = new_max_height;
    }

    pub fn setY(r: *RectRow, y: f64) void {
        const change = y - r.y;
        for (r.stacks.items) |stack| stack.setLocation(stack.x, stack.y + change);
        r.y = y;
    }

    pub fn resetStacks(r: *RectRow) void {
        r.stacks = .empty;
    }
};
