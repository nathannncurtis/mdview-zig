const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const blocks = @import("blocks.zig");

const ElkNode = eg.ElkNode;

pub const default_aspect_ratio = 1.3;
pub const default_spacing = 15.0;
pub const default_padding: lg.Margin = .{ .top = 15, .left = 15, .bottom = 15, .right = 15 };

// util.DrawingDataDescriptor
pub const Descriptor = enum {
    whole_drawing,
    last_placed_right,
    last_placed_below,
    whole_drawing_right,
    whole_drawing_below,
};

// InternalProperties of the graph being laid out
pub const Internal = struct {
    target_width: f64 = 0,
    min_width: f64 = 0,
    min_height: f64 = 0,
    drawing_width: f64 = 0,
    drawing_height: f64 = 0,
    additional_height: f64 = 0,
    rows: ?*std.ArrayList(*blocks.RectRow) = null,
    min_row_increase: f64 = 0,
    max_row_increase: f64 = 0,
    min_row_decrease: f64 = 0,
    max_row_decrease: f64 = 0,
};

pub const Ctx = struct {
    node: *ElkNode,
    st: *Internal,

    pub fn aspectRatio(c: Ctx) f64 {
        return c.node.opts.aspect_ratio orelse default_aspect_ratio;
    }

    pub fn spacing(c: Ctx) f64 {
        return c.node.opts.spacing_node_node orelse default_spacing;
    }

    pub fn padding(c: Ctx) lg.Margin {
        return c.node.opts.padding orelse default_padding;
    }

    pub fn rowHeightReevaluation(c: Ctx) bool {
        return c.node.opts.rp_row_height_reevaluation orelse false;
    }
};

pub fn horizontal(p: lg.Margin) f64 {
    return p.left + p.right;
}

pub fn vertical(p: lg.Margin) f64 {
    return p.top + p.bottom;
}

// DrawingUtil.computeScaleMeasure
pub fn scaleMeasure(width: f64, height: f64, dar: f64) f64 {
    return @min(dar / width, 1.0 / height);
}

// util.DrawingData
pub const DrawingData = struct {
    scale_measure: f64 = 0,
    drawing_width: f64,
    drawing_height: f64,
    area: f64 = 0,
    aspect_ratio: f64 = 0,
    dar: f64,
    placement_option: Descriptor,
    next_x: f64 = 0,
    next_y: f64 = 0,

    pub fn init(dar: f64, width: f64, height: f64, option: Descriptor, next_x: f64, next_y: f64) DrawingData {
        var d: DrawingData = .{ .dar = dar, .drawing_width = width, .drawing_height = height, .placement_option = option, .next_x = next_x, .next_y = next_y };
        d.recalc();
        return d;
    }

    fn recalc(d: *DrawingData) void {
        if (d.drawing_width > 0 and d.drawing_height > 0) {
            d.area = d.drawing_width * d.drawing_height;
            d.aspect_ratio = d.drawing_width / d.drawing_height;
            d.scale_measure = scaleMeasure(d.drawing_width, d.drawing_height, d.dar);
        }
    }

    pub fn setDrawingWidth(d: *DrawingData, w: f64) void {
        d.drawing_width = w;
        d.recalc();
    }

    pub fn setDrawingHeight(d: *DrawingData, h: f64) void {
        d.drawing_height = h;
        d.recalc();
    }
};

// DrawingUtil.resetCoordinates
pub fn resetCoordinates(rects: []const *ElkNode) void {
    for (rects) |n| {
        n.x = 0;
        n.y = 0;
    }
}

// DrawingUtil.calculateDimensions(List<RectRow>, nodeNodeSpacing)
pub fn dimensionsOfRows(rows: []const *blocks.RectRow, nn: f64) lg.Vec {
    var max_width: f64 = 0;
    var new_height: f64 = 0;
    for (rows, 0..) |row, index| {
        max_width = @max(max_width, row.width);
        new_height += row.height + (if (index > 0) nn else 0);
    }
    return .{ .x = max_width, .y = new_height };
}

// DrawingUtil.calculateDimensions(List<ElkNode>)
pub fn dimensionsOfRects(rects: []const *ElkNode) lg.Vec {
    var max_width: f64 = 0;
    var max_height: f64 = 0;
    for (rects) |n| {
        max_width = @max(n.width + n.x, max_width);
        max_height = @max(n.height + n.y, max_height);
    }
    return .{ .x = max_width, .y = max_height };
}
