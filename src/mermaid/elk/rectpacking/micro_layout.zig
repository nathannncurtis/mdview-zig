const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const nls = @import("../graph/node_label_size.zig");

const ElkNode = eg.ElkNode;

// NodeMicroLayout.forGraph(graph).execute(): size and inside label placement of every child.
// shortcut: ports, outside node labels and MINIMUM_SIZE_ACCOUNTS_FOR_PADDING are not modelled (see
// graph/node_label_size.zig); Mermaid's ELK nodes never have them.
pub fn run(graph: *const ElkNode) void {
    const horizontal_mode = if (graph.opts.direction) |d| d == .undefined or d.isHorizontal() else true;
    for (graph.children.items) |n| {
        const size = nls.minimumNodeSize(n);
        n.width = size.x;
        n.height = size.y;
        placeLabels(n, horizontal_mode, nls.computedNodeSize(n));
    }
}

const Cell = struct { w: f64 = 0, h: f64 = 0, count: usize = 0, next: f64 = 0, started: bool = false };

// NodeLabelLocation.fromNodeLabelPlacement for inside locations: row and column
fn insideLocation(p: lg.NodeLabelPlacement) ?[2]usize {
    if (!p.inside or p.outside) return null;
    const hs = @as(u8, @intFromBool(p.h_left)) + @intFromBool(p.h_center) + @intFromBool(p.h_right);
    const vs = @as(u8, @intFromBool(p.v_top)) + @intFromBool(p.v_center) + @intFromBool(p.v_bottom);
    if (hs != 1 or vs != 1) return null;
    const row: usize = if (p.v_top) 0 else if (p.v_center) 1 else 2;
    const col: usize = if (p.h_left) 0 else if (p.h_center) 1 else 2;
    return .{ row, col };
}

fn sym(v: [3]f64, symmetrical: bool) [3]f64 {
    if (!symmetrical) return v;
    const m = @max(v[0], v[2]);
    return .{ m, v[1], m };
}

fn placeLabels(n: *ElkNode, horizontal_mode: bool, box_size: lg.Vec) void {
    const parent = n.parent;
    const pad = (if (parent) |p| p.opts.node_labels_padding else null) orelse lg.Margin{ .top = 5, .left = 5, .bottom = 5, .right = 5 };
    const ll = (if (parent) |p| p.opts.spacing_label_label else null) orelse 0;
    const gap = 2 * ll;
    const so = n.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true };
    const symmetrical = !so.asymmetrical;
    const node_placement = n.opts.node_labels_placement orelse lg.NodeLabelPlacement{};

    var cells: [3][3]Cell = @splat(@splat(.{}));
    var any = false;
    for (n.labels.items) |l| {
        const loc = insideLocation(l.opts.node_labels_placement orelse node_placement) orelse continue;
        any = true;
        const cell = &cells[loc[0]][loc[1]];
        cell.count += 1;
        if (horizontal_mode) {
            cell.w = @max(cell.w, l.width);
            cell.h += l.height;
            if (cell.count > 1) cell.h += ll;
        } else {
            cell.w += l.width;
            cell.h = @max(cell.h, l.height);
            if (cell.count > 1) cell.w += ll;
        }
    }
    if (!any) return;

    var col_w: [3]f64 = .{ 0, 0, 0 };
    const tabular = so.force_tabular_node_labels;
    for (0..3) |col| {
        if (tabular) {
            for (0..3) |row| col_w[col] = @max(col_w[col], cells[row][col].w);
        } else {
            col_w[col] = cells[2][col].w;
        }
    }
    col_w = sym(col_w, symmetrical);
    const x0 = pad.left;
    const x2 = box_size.x - pad.right - col_w[2];
    const w0 = col_w[0];
    const w2 = col_w[2];
    var free_w = box_size.x - pad.left - pad.right;
    if (col_w[0] > 0) {
        col_w[0] += gap;
        free_w -= col_w[0];
    }
    if (col_w[2] > 0) {
        col_w[2] += gap;
        free_w -= col_w[2];
    }
    col_w[1] = @max(col_w[1], free_w);
    const x1 = pad.left + col_w[0] - (col_w[1] - free_w) / 2;
    const xs = [3]f64{ x0, x1, x2 };
    const ws = [3]f64{ w0, col_w[1], w2 };

    var row_h: [3]f64 = .{ 0, 0, 0 };
    for (0..3) |row| for (0..3) |col| {
        row_h[row] = @max(row_h[row], cells[row][col].h);
    };
    row_h = sym(row_h, symmetrical);
    const y0 = pad.top;
    const y2 = box_size.y - pad.bottom - row_h[2];
    const h0 = row_h[0];
    const h2 = row_h[2];
    var free_h = box_size.y - pad.top - pad.bottom;
    if (row_h[0] > 0) {
        row_h[0] += gap;
        free_h -= row_h[0];
    }
    if (row_h[2] > 0) {
        row_h[2] += gap;
        free_h -= row_h[2];
    }
    row_h[1] = @max(row_h[1], free_h);
    const y1 = pad.top + row_h[0] - (row_h[1] - free_h) / 2;
    const ys = [3]f64{ y0, y1, y2 };
    const hs = [3]f64{ h0, row_h[1], h2 };

    for (n.labels.items) |l| {
        const loc = insideLocation(l.opts.node_labels_placement orelse node_placement) orelse continue;
        const cell = &cells[loc[0]][loc[1]];
        const cx = xs[loc[1]];
        const cwid = ws[loc[1]];
        const cy = ys[loc[0]];
        const chei = hs[loc[0]];
        if (horizontal_mode) {
            if (!cell.started) {
                cell.started = true;
                cell.next = cy;
                if (loc[0] == 1) {
                    cell.next += (chei - cell.h) / 2;
                } else if (loc[0] == 2) {
                    cell.next += chei - cell.h;
                }
            }
            l.y = cell.next;
            cell.next += l.height + ll;
            l.x = switch (loc[1]) {
                0 => cx,
                1 => cx + (cwid - l.width) / 2,
                else => cx + cwid - l.width,
            };
        } else {
            if (!cell.started) {
                cell.started = true;
                cell.next = cx;
                if (loc[1] == 1) {
                    cell.next += (cwid - cell.w) / 2;
                } else if (loc[1] == 2) {
                    cell.next += cwid - cell.w;
                }
            }
            l.x = cell.next;
            cell.next += l.width + ll;
            l.y = switch (loc[0]) {
                0 => cy,
                1 => cy + (chei - l.height) / 2,
                else => cy + chei - l.height,
            };
        }
    }
}
