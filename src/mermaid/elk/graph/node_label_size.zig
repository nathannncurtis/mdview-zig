const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");

// The parts of NodeLabelAndSizeCalculator (alg.common nodespacing) the importer runs on ELK nodes: the inside
// node label grid of a node without ports.
// shortcut: ports, port labels, outside node labels and MINIMUM_SIZE_ACCOUNTS_FOR_PADDING are not modelled;
// Mermaid's ELK nodes never have explicit ports or outside labels. Port them from the cell system if that changes.

const default_min = 20.0; // ElkUtil.DEFAULT_MIN_WIDTH / DEFAULT_MIN_HEIGHT

const Grid = struct {
    // [row][column], BEGIN / CENTER / END
    w: [3][3]f64 = @splat(@splat(0)),
    h: [3][3]f64 = @splat(@splat(0)),
    used: [3][3]bool = @splat(@splat(false)),
    count: [3][3]usize = @splat(@splat(0)),
    padding: lg.Margin,
    gap: f64,

    // LabelCell.addLabel
    fn add(g: *Grid, row: usize, col: usize, l: *const eg.ElkLabel, cell_gap: f64, horizontal: bool) void {
        g.used[row][col] = true;
        g.count[row][col] += 1;
        if (horizontal) {
            g.w[row][col] = @max(g.w[row][col], l.width);
            g.h[row][col] += l.height;
            if (g.count[row][col] > 1) g.h[row][col] += cell_gap;
        } else {
            g.w[row][col] += l.width;
            g.h[row][col] = @max(g.h[row][col], l.height);
            if (g.count[row][col] > 1) g.w[row][col] += cell_gap;
        }
    }

    fn sumWithGaps(g: *const Grid, v: [3]f64) f64 {
        var sum: f64 = 0;
        var active: usize = 0;
        for (v) |x| if (x > 0) {
            sum += x;
            active += 1;
        };
        if (active > 1) sum += g.gap * @as(f64, @floatFromInt(active - 1));
        return sum;
    }

    // GridContainerCell.getMinimumWidth (symmetrical)
    fn minWidth(g: *const Grid, tabular: bool, symmetrical: bool) f64 {
        var width: f64 = 0;
        if (tabular) {
            var cols: [3]f64 = .{ 0, 0, 0 };
            for (0..3) |c| for (0..3) |r| {
                cols[c] = @max(cols[c], g.w[r][c]);
            };
            width = g.sumWithGaps(sym(cols, symmetrical));
        } else {
            for (0..3) |r| width = @max(width, g.sumWithGaps(sym(g.w[r], symmetrical)));
        }
        return if (width > 0) width + g.padding.left + g.padding.right else 0;
    }

    fn minHeight(g: *const Grid, symmetrical: bool) f64 {
        var rows: [3]f64 = .{ 0, 0, 0 };
        for (0..3) |r| for (0..3) |c| {
            rows[r] = @max(rows[r], g.h[r][c]);
        };
        const height = g.sumWithGaps(sym(rows, symmetrical));
        return if (height > 0) height + g.padding.top + g.padding.bottom else 0;
    }
};

fn sym(v: [3]f64, symmetrical: bool) [3]f64 {
    if (!symmetrical) return v;
    const m = @max(v[0], v[2]);
    return .{ m, v[1], m };
}

// NodeLabelLocation.fromNodeLabelPlacement for inside locations: row and column, or null
fn insideLocation(p: lg.NodeLabelPlacement) ?[2]usize {
    if (!p.inside or p.outside) return null;
    const hs = @as(u8, @intFromBool(p.h_left)) + @intFromBool(p.h_center) + @intFromBool(p.h_right);
    const vs = @as(u8, @intFromBool(p.v_top)) + @intFromBool(p.v_center) + @intFromBool(p.v_bottom);
    if (hs != 1 or vs != 1) return null;
    const row: usize = if (p.v_top) 0 else if (p.v_center) 1 else 2;
    const col: usize = if (p.h_left) 0 else if (p.h_center) 1 else 2;
    return .{ row, col };
}

// IndividualSpacings.getIndividualOrInherited over ElkGraphAdapters.adaptSingleNode: the parent's value
fn labelsPadding(n: *const eg.ElkNode) lg.Margin {
    const p = n.parent orelse return .{ .top = 5, .left = 5, .bottom = 5, .right = 5 };
    return p.opts.node_labels_padding orelse .{ .top = 5, .left = 5, .bottom = 5, .right = 5 };
}

fn labelLabel(n: *const eg.ElkNode) f64 {
    const p = n.parent orelse return 0;
    return p.opts.spacing_label_label orelse 0;
}

fn buildGrid(n: *const eg.ElkNode, horizontal: bool) Grid {
    const ll = labelLabel(n);
    var g: Grid = .{ .padding = labelsPadding(n), .gap = 2 * ll };
    const node_placement = n.opts.node_labels_placement orelse lg.NodeLabelPlacement{};
    for (n.labels.items) |l| {
        const loc = insideLocation(l.opts.node_labels_placement orelse node_placement) orelse continue;
        g.add(loc[0], loc[1], l, ll, horizontal);
    }
    return g;
}

// NodeLabelAndSizeCalculator.computeInsideNodeLabelPadding(graph, node, Direction.RIGHT)
pub fn insideNodeLabelPadding(n: *const eg.ElkNode) lg.Margin {
    const g = buildGrid(n, true);
    var pad: lg.Margin = .{};
    for (0..3) |c| if (g.used[0][c]) {
        pad.top = @max(pad.top, g.h[0][c]);
    };
    for (0..3) |c| if (g.used[2][c]) {
        pad.bottom = @max(pad.bottom, g.h[2][c]);
    };
    for (0..3) |r| if (g.used[r][0]) {
        pad.left = @max(pad.left, g.w[r][0]);
    };
    for (0..3) |r| if (g.used[r][2]) {
        pad.right = @max(pad.right, g.w[r][2]);
    };
    if (pad.top > 0) pad.top += g.padding.top + g.gap;
    if (pad.bottom > 0) pad.bottom += g.padding.bottom + g.gap;
    if (pad.left > 0) pad.left += g.padding.left + g.gap;
    if (pad.right > 0) pad.right += g.padding.right + g.gap;
    return pad;
}

// NodeLabelAndSizeCalculator.process(parentAdapter, nodeAdapter, false, true): the node size it computes
pub fn minimumNodeSize(n: *const eg.ElkNode) lg.Vec {
    const sc = n.opts.node_size_constraints orelse lg.SizeConstraint{};
    const so = n.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true };
    if (!sc.ports and !sc.port_labels and !sc.node_labels and !sc.minimum_size) return .{ .x = n.width, .y = n.height };
    var horizontal = true;
    if (n.parent) |p| if (p.opts.direction) |d| {
        horizontal = d == .undefined or d.isHorizontal();
    };
    const symmetrical = !so.asymmetrical;
    var width: f64 = 0;
    var height: f64 = 0;
    if (sc.node_labels) {
        const g = buildGrid(n, horizontal);
        width = g.minWidth(so.force_tabular_node_labels, symmetrical);
        height = g.minHeight(symmetrical);
    }
    if (sc.minimum_size and !so.minimum_size_accounts_for_padding) {
        var min = n.opts.node_size_minimum orelse lg.Vec{};
        if (so.default_minimum_size) {
            if (min.x <= 0) min.x = default_min;
            if (min.y <= 0) min.y = default_min;
        }
        width = @max(width, min.x);
        height = @max(height, min.y);
    }
    const fixed_graph_size = if (n.parent) |p| p.opts.node_size_fixed_graph_size orelse false else false;
    if (fixed_graph_size) return .{ .x = @max(n.width, width), .y = @max(n.height, height) };
    return .{ .x = width, .y = height };
}

test "inside top label padding and minimum size" {
    var parent: eg.ElkNode = .{ .id = "root" };
    var lbl: eg.ElkLabel = .{ .text = "A", .width = 9.4375, .height = 22 };
    var n: eg.ElkNode = .{ .id = "A", .parent = &parent };
    var buf: [1]*eg.ElkLabel = undefined;
    n.labels = .initBuffer(&buf);
    n.labels.appendAssumeCapacity(&lbl);
    n.opts.node_labels_placement = .{ .h_center = true, .v_top = true, .inside = true };
    n.opts.node_size_constraints = .{ .minimum_size = true, .node_labels = true };
    n.opts.node_size_minimum = .{ .x = 17.4375, .y = 0 };
    const pad = insideNodeLabelPadding(&n);
    try std.testing.expectEqual(@as(f64, 27), pad.top);
    try std.testing.expectEqual(@as(f64, 0), pad.left);
    const min = minimumNodeSize(&n);
    try std.testing.expectEqual(@as(f64, 19.4375), min.x);
    try std.testing.expectEqual(@as(f64, 54), min.y);
}
