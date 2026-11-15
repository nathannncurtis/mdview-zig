const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const c = @import("common.zig");
const blocks = @import("blocks.zig");

const Allocator = std.mem.Allocator;
const ElkNode = eg.ElkNode;
const Block = blocks.Block;
const RectRow = blocks.RectRow;
const BlockStack = blocks.BlockStack;
const Rows = std.ArrayList(*RectRow);

fn inNewRow(n: *const ElkNode) bool {
    return n.opts.rp_in_new_row orelse false;
}

// p2packing.InitialPlacement.place
fn initialPlace(a: Allocator, rects: []const *ElkNode, bounding_width: f64, nn: f64, reeval: bool) Allocator.Error!*Rows {
    const rows = try a.create(Rows);
    rows.* = .empty;
    var row = try RectRow.create(a, 0, nn);
    var drawing_height: f64 = 0;
    try row.addBlock(try Block.create(a, 0, 0, row, nn));
    var current_width: f64 = 0;
    for (rects) |rect| {
        var block = row.lastBlock();
        const potential = current_width + rect.width + (if (row.children.items[0].children.items.len == 0) 0 else nn);
        if (potential > bounding_width or inNewRow(rect)) {
            current_width = 0;
            drawing_height += row.height + nn;
            try rows.append(a, row);
            row = try RectRow.create(a, drawing_height, nn);
            block = try Block.create(a, 0, row.y, row, nn);
            try row.addBlock(block);
            current_width = 0;
        }
        if (block.children.items.len == 0 or (!reeval and isSimilarHeight(block, rect))) {
            try block.addChild(rect);
        } else {
            const new_block = try Block.create(a, block.x + block.width + nn, row.y, row, nn);
            try row.addBlock(new_block);
            try new_block.addChild(rect);
        }
        current_width = rect.x + rect.width;
    }
    try rows.append(a, row);
    return rows;
}

fn placeRectInBlock(row: *RectRow, block: *Block, rect: *ElkNode, bounding_width: f64, nn: f64) Allocator.Error!bool {
    if (isSimilarHeight(block, rect)) {
        if (block.lastRowNewX() + rect.width + nn <= bounding_width and
            (block.lastRowY() - row.y + rect.height <= row.height or row.children.items.len == 1))
        {
            try block.addChild(rect);
            return true;
        } else if (block.x + rect.width <= bounding_width and
            (block.y + block.height + rect.height + nn <= row.height or row.children.items.len == 1))
        {
            try block.addChildInNewRow(rect);
            return true;
        }
    }
    return false;
}

fn isSimilarHeight(block: *const Block, rect: *const ElkNode) bool {
    if (rect.height >= block.smallest_rect_height and rect.height <= block.min_height) return true;
    return block.average_height * 0.5 <= rect.height and block.average_height * 1.5 >= rect.height;
}

const Pair = struct { changed: bool, compact_again: bool };

// p2packing.Compaction.compact
fn compact(a: Allocator, row_idx: usize, rows: *Rows, bounding_width: f64, nn: f64, reeval: bool) lg.Error!Pair {
    var something_changed = false;
    var compact_again = false;
    const next_row_index = row_idx + 1;
    const row = rows.items[row_idx];
    var current_stack: ?*BlockStack = null;
    var block_id: i64 = 0;
    // ELK steps back and retries blocks without a bound; some inputs never leave this loop
    var steps: usize = 0;
    while (block_id < @as(i64, @intCast(row.children.items.len))) : (block_id += 1) {
        steps += 1;
        if (steps > 100_000) {
            lg.setElkMessage("rectpacking compaction does not terminate");
            return error.ElkException;
        }
        const block = row.children.items[@intCast(block_id)];
        if (block.fixed) continue;
        if (block.children.items.len == 0) {
            row.removeBlock(block);
            block_id -= 1;
            something_changed = true;
            continue;
        }
        if (!block.position_fixed) {
            if (current_stack) |cs| cs.updateDimension();
            current_stack = try BlockStack.create(a, if (current_stack) |cs| cs.x + cs.width + nn else 0, row.y, nn);
            block.setLocation(current_stack.?.x + current_stack.?.width, row.y);
            try row.stacks.append(a, current_stack.?);
            try current_stack.?.addBlock(block);
            block.position_fixed = true;
        }
        var next_block = getNextBlock(rows, row, block_id, next_row_index);
        var was_from_next_row = false;
        if (next_block) |nb| was_from_next_row = nb.parent_row != row;
        if (next_block) |nb| {
            if (nb.children.items.len != 0 and !inNewRow(nb.children.items[0])) {
                try useRowWidth(block, bounding_width);
                something_changed = (try absorbBlocks(row, block, nb, bounding_width, nn)) or something_changed;
            } else {
                row.removeBlock(nb);
                break;
            }
            if (nb.children.items.len == 0) {
                if (rows.items.len > next_row_index) rows.items[next_row_index].removeBlock(nb);
                next_block = null;
                while (rows.items.len > next_row_index and rows.items[next_row_index].children.items.len == 0) {
                    _ = rows.orderedRemove(next_row_index);
                }
            }
            if (next_block == null) {
                block_id -= 1;
                continue;
            }
            if (!inNewRow(nb.children.items[0]) and
                try placeBelow(rows, row, block, nb, was_from_next_row, bounding_width, next_row_index, nn))
            {
                something_changed = true;
                continue;
            }
            if (was_from_next_row) {
                const old_row_height = row.height;
                const next_min_height = nb.min_height;
                if (!inNewRow(nb.children.items[0]) and
                    try placeBeside(rows, row, block, nb, bounding_width, next_row_index, nn, reeval))
                {
                    something_changed = true;
                    if (old_row_height < next_min_height) {
                        compact_again = true;
                        nb.parent_row = row;
                        break;
                    }
                    continue;
                } else if (try useRowHeight(row, block)) {
                    block.fixed = true;
                    something_changed = true;
                    continue;
                }
            } else if (try useRowHeight(row, block)) {
                block.fixed = true;
                something_changed = true;
                continue;
            }
            if (something_changed) continue;
        }
        if (try useRowHeight(row, block)) {
            block.fixed = true;
            something_changed = true;
            if (next_block) |nb| nb.position_fixed = false;
            continue;
        } else {
            block.stack.?.updateDimension();
        }
    }
    return .{ .changed = something_changed, .compact_again = compact_again };
}

fn getNextBlock(rows: *const Rows, row: *RectRow, block_id: i64, next_row_index: usize) ?*Block {
    if (block_id < @as(i64, @intCast(row.children.items.len)) - 1) return row.children.items[@intCast(block_id + 1)];
    if (next_row_index < rows.items.len and rows.items[next_row_index].children.items.len != 0) return rows.items[next_row_index].children.items[0];
    return null;
}

fn useRowHeight(row: *RectRow, block: *Block) Allocator.Error!bool {
    var changed = false;
    const stack = block.stack.?;
    const previous_width = stack.width;
    if (block.height < row.height) {
        const target_width = try stack.widthForFixedHeight(row.height);
        if (stack.width > target_width) {
            try stack.placeRectsIn(target_width);
            changed = previous_width != stack.width;
        }
    }
    return changed;
}

fn useRowWidth(block: *Block, bounding_width: f64) Allocator.Error!void {
    _ = try block.placeRectsIn(bounding_width - block.x);
    block.stack.?.updateDimension();
}

fn absorbBlocks(row: *RectRow, block: *Block, next_block: *Block, bounding_width: f64, nn: f64) Allocator.Error!bool {
    var changed = false;
    var rect = next_block.children.items[0];
    // every placed rect leaves the next block, so more rounds than rects means the block did not shrink
    var rounds = next_block.children.items.len + 1;
    while (rounds > 0 and try placeRectInBlock(row, block, rect, bounding_width, nn)) {
        rounds -= 1;
        changed = true;
        next_block.removeChild(rect);
        if (next_block.children.items.len == 0) break;
        rect = next_block.children.items[0];
    }
    if (next_block.children.items.len == 0) next_block.parent_row.removeBlock(next_block);
    if (changed) block.stack.?.updateDimension();
    return changed;
}

fn placeBelow(rows: *Rows, row: *RectRow, block: *Block, next_block: *Block, was_from_next_row: bool, bounding_width: f64, next_row_index: usize, nn: f64) Allocator.Error!bool {
    var changed = false;
    const remaining_width = bounding_width - block.x;
    const current_min_height = block.y - row.y + try block.heightForTargetWidth(remaining_width);
    if (next_block.min_width + nn > remaining_width) return false;
    const next_min_height = try next_block.heightForTargetWidth(remaining_width);
    if (current_min_height + nn + next_min_height <= row.height) {
        _ = try block.placeRectsIn(bounding_width - block.x);
        block.fixed = true;
        _ = try next_block.placeRectsIn(bounding_width - block.x);
        next_block.setLocation(block.x, block.y + block.height + nn);
        next_block.position_fixed = true;
        try block.stack.?.addBlock(next_block);
        changed = true;
        if (was_from_next_row) {
            try row.addBlock(next_block);
            next_block.parent_row = row;
            if (rows.items.len > next_row_index) {
                rows.items[next_row_index].removeBlock(next_block);
                if (rows.items[next_row_index].children.items.len == 0) _ = rows.orderedRemove(next_row_index);
            }
        }
    }
    return changed;
}

fn placeBeside(rows: *Rows, row: *RectRow, block: *Block, next_block: *Block, bounding_width: f64, next_row_index: usize, nn: f64, reeval: bool) Allocator.Error!bool {
    var changed = false;
    const stack = block.stack.?;
    const current_min_width = try stack.widthForFixedHeight(row.y + row.height - stack.y);
    const should_reeval = next_block.min_height > row.height and reeval;
    var target_width_next = bounding_width - (stack.x + current_min_width - nn);
    const next_height = try next_block.heightForTargetWidth(target_width_next);
    if (should_reeval and next_height > next_block.min_height) return false;
    if (should_reeval) {
        var potential_width: f64 = 0;
        for (row.stacks.items) |s| potential_width += try s.widthForFixedHeight(next_block.min_height) + nn;
        target_width_next = bounding_width - potential_width;
    }
    if (target_width_next < next_block.min_width) return false;
    const last_row_optimization = next_row_index == rows.items.len - 1 and target_width_next >= rows.items[next_row_index].width;
    if (!should_reeval and next_height > row.height and !last_row_optimization) return false;
    if (last_row_optimization or should_reeval or next_height <= row.height) {
        if (last_row_optimization and next_height > row.height) {
            block.height = next_height;
            _ = try block.placeRectsIn(try block.widthForTargetHeight(next_height));
        } else {
            try stack.placeRectsIn(current_min_width);
            block.fixed = true;
        }
        _ = try next_block.placeRectsIn(bounding_width - (block.x + block.width));
        next_block.setLocation(stack.x + stack.width, row.y);
        try row.addBlock(next_block);
        if (rows.items.len > next_row_index) {
            rows.items[next_row_index].removeBlock(next_block);
            if (rows.items[next_row_index].children.items.len == 0) _ = rows.orderedRemove(next_row_index);
        }
        changed = true;
    }
    return changed;
}

// p2packing.RowFillingAndCompaction
pub const RowFilling = struct {
    decrease_min: f64 = std.math.inf(f64),
    decrease_max: f64 = 0,
    increase_min: f64 = std.math.inf(f64),
    increase_max: f64 = 0,

    fn start(self: *RowFilling, a: Allocator, ctx: c.Ctx, aspect_ratio: f64, nn: f64, padding: lg.Margin) lg.Error!c.DrawingData {
        const target_width = ctx.st.target_width;
        const min_width = ctx.st.min_width;
        const min_height = ctx.st.min_height;
        c.resetCoordinates(ctx.node.children.items);
        const rows = try initialPlace(a, ctx.node.children.items, target_width, nn, ctx.rowHeightReevaluation());
        var row_idx: i64 = 0;
        // ELK repeats a row for as long as compaction asks for it, which does not end for some target widths
        var repeats: usize = 0;
        const max_repeats = 64 * (ctx.node.children.items.len + 1) * (ctx.node.children.items.len + 1);
        while (row_idx < @as(i64, @intCast(rows.items.len))) : (row_idx += 1) {
            const idx: usize = @intCast(row_idx);
            const current_row = rows.items[idx];
            if (idx != 0) {
                const prev = rows.items[idx - 1];
                current_row.setY(prev.y + prev.height + nn);
            }
            const result = try compact(a, idx, rows, target_width, nn, ctx.rowHeightReevaluation());
            if (result.compact_again) {
                repeats += 1;
                if (repeats > max_repeats) {
                    lg.setElkMessage("rectpacking row compaction does not terminate");
                    return error.ElkException;
                }
                for (current_row.children.items) |block| {
                    block.fixed = false;
                    block.position_fixed = false;
                    block.resetBlock();
                }
                current_row.resetStacks();
                current_row.width = target_width;
                row_idx -= 1;
            } else {
                adjustWidthAndHeight(current_row, nn);
                if (idx + 1 < rows.items.len) {
                    const next_first = rows.items[idx + 1].firstBlock();
                    self.increase_max = @max(current_row.width + nn + next_first.width - target_width, self.decrease_max);
                    self.increase_min = @min(current_row.width + nn + next_first.width - target_width, self.decrease_min);
                    const stacks = current_row.stacks.items;
                    if (stacks.len != 0) {
                        const w = stacks[stacks.len - 1].width + (if (stacks.len <= 1) 0 else nn);
                        self.decrease_max = @max(self.decrease_max, w);
                        self.decrease_min = @min(self.decrease_max, w);
                    }
                }
                if (rows.items.len == 1) {
                    const stacks = current_row.stacks.items;
                    if (stacks.len == 0) return error.ElkException;
                    const last_stack = stacks[stacks.len - 1];
                    const last_block = last_stack.blocks.items[last_stack.blocks.items.len - 1];
                    for (last_block.rows.items) |block_row| {
                        self.decrease_max = @max(self.decrease_max, last_block.width - block_row.width);
                        self.decrease_min = @min(self.decrease_min, last_block.width - block_row.width);
                        self.increase_max = @max(self.increase_max, block_row.width + nn);
                        self.increase_min = @min(self.increase_min, block_row.width + nn);
                    }
                }
            }
        }
        const size = c.dimensionsOfRows(rows.items, nn);
        const total_width = @max(size.x, min_width - c.horizontal(padding));
        const height = @max(size.y, min_height - c.vertical(padding));
        const additional_height = height - size.y;
        ctx.st.additional_height = additional_height;
        ctx.st.rows = rows;
        return c.DrawingData.init(aspect_ratio, total_width, size.y + additional_height, .whole_drawing, 0, 0);
    }
};

fn adjustWidthAndHeight(row: *RectRow, nn: f64) void {
    var max_height: f64 = 0;
    var max_width: f64 = 0;
    for (row.stacks.items, 0..) |stack, index| {
        stack.updateDimension();
        max_height = @max(max_height, stack.height);
        max_width += stack.width + (if (index > 0) nn else 0);
    }
    row.height = max_height;
    row.width = max_width;
}

fn copyRowWidthChangeValues(st: *c.Internal, rf: *const RowFilling) void {
    st.min_row_increase = rf.increase_min;
    st.max_row_increase = rf.increase_max;
    st.min_row_decrease = rf.decrease_min;
    st.max_row_decrease = rf.decrease_max;
}

// p2packing.Compactor
pub fn compactor(a: Allocator, ctx: c.Ctx) lg.Error!void {
    const aspect_ratio = ctx.aspectRatio();
    const nn = ctx.spacing();
    const padding = ctx.padding();
    var second: RowFilling = .{};
    var drawing = try second.start(a, ctx, aspect_ratio, nn, padding);
    copyRowWidthChangeValues(ctx.st, &second);
    var iterations = ctx.node.opts.rp_compaction_iterations orelse 1;
    while (iterations > 1) : (iterations -= 1) {
        const clone = try cloneGraph(a, ctx);
        const old_sm = drawing.scale_measure;
        configureSecondIteration(ctx, clone, drawing);
        second = .{};
        const new_drawing = try second.start(a, clone, aspect_ratio, nn, padding);
        const new_sm = new_drawing.scale_measure;
        if (new_sm >= old_sm and new_sm == new_sm) {
            for (clone.node.children.items, ctx.node.children.items) |from, to| {
                to.width = from.width;
                to.height = from.height;
                to.x = from.x;
                to.y = from.y;
            }
            copyRowWidthChangeValues(ctx.st, &second);
            drawing.setDrawingWidth(new_drawing.drawing_width);
            drawing.setDrawingHeight(new_drawing.drawing_height);
        }
    }
    ctx.st.drawing_height = drawing.drawing_height;
    ctx.st.drawing_width = drawing.drawing_width;
}

fn configureSecondIteration(ctx: c.Ctx, clone: c.Ctx, drawing: c.DrawingData) void {
    const padding = ctx.padding();
    const aspect_ratio = ctx.aspectRatio();
    const st = ctx.st;
    const ratio = (drawing.drawing_width + c.horizontal(padding)) / (drawing.drawing_height + c.vertical(padding));
    if (ctx.node.children.items.len > 1 and st.min_row_increase != std.math.inf(f64) and ratio < aspect_ratio) {
        clone.st.target_width = st.target_width + st.min_row_increase;
    } else if (ctx.node.children.items.len > 1 and st.min_row_decrease != std.math.inf(f64) and ratio > aspect_ratio) {
        clone.st.target_width = @max(st.min_width, clone.st.target_width - st.min_row_decrease);
    }
}

fn cloneGraph(a: Allocator, ctx: c.Ctx) Allocator.Error!c.Ctx {
    const node = try a.create(ElkNode);
    node.* = .{ .opts = ctx.node.opts };
    for (ctx.node.children.items) |child| {
        const nc = try eg.createNode(a, node, child.id);
        nc.width = child.width;
        nc.height = child.height;
        nc.x = child.x;
        nc.y = child.y;
        nc.opts = child.opts;
    }
    const st = try a.create(c.Internal);
    st.* = ctx.st.*;
    return .{ .node = node, .st = st };
}

fn finishPlacement(ctx: c.Ctx, size: lg.Vec, padding: lg.Margin) void {
    const width = @max(size.x, ctx.st.min_width - c.horizontal(padding));
    const height = @max(size.y, ctx.st.min_height - c.vertical(padding));
    const additional_height = height - size.y;
    ctx.st.additional_height = additional_height;
    ctx.st.drawing_width = width;
    ctx.st.drawing_height = height + additional_height;
}

// p2packing.SimplePlacement
pub fn simple(a: Allocator, ctx: c.Ctx) lg.Error!void {
    const nn = ctx.spacing();
    const padding = ctx.padding();
    const rects = ctx.node.children.items;
    c.resetCoordinates(rects);
    const rows = try initialPlace(a, rects, ctx.st.target_width, nn, ctx.rowHeightReevaluation());
    for (rows.items) |row| {
        for (row.children.items) |block| {
            const stack = try BlockStack.create(a, block.x, block.y, nn);
            try stack.addBlock(block);
            try row.stacks.append(a, stack);
        }
    }
    finishPlacement(ctx, c.dimensionsOfRows(rows.items, nn), padding);
    ctx.st.rows = rows;
}

// p2packing.NoPlacement
pub fn none(ctx: c.Ctx) void {
    finishPlacement(ctx, c.dimensionsOfRects(ctx.node.children.items), ctx.padding());
}
