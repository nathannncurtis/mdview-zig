const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const nls = @import("../graph/node_label_size.zig");

// NodeMicroLayout for the children of a force graph: node size from the size constraints (nodes whose own layout
// already ran have fixed constraints) and inside node label placement (LabelPlacer over the 3x3 label cells).
// shortcut: ports and outside node labels are not modelled, like in graph/node_label_size.zig.
pub fn microLayout(parent: *const eg.ElkNode) void {
    for (parent.children.items) |c| {
        const sc = c.opts.node_size_constraints orelse lg.SizeConstraint{};
        if (sc.ports or sc.node_labels or sc.minimum_size) {
            const m = nls.minimumNodeSize(c);
            c.width = m.x;
            c.height = m.y;
        }
        placeLabels(c);
    }
}

fn colWidths(g: *const nls.Grid, symmetrical: bool) [3]f64 {
    var cols: [3]f64 = .{ 0, 0, 0 };
    for (0..3) |c| for (0..3) |r| {
        cols[c] = @max(cols[c], g.w[r][c]);
    };
    if (symmetrical) {
        const m = @max(cols[0], cols[2]);
        cols[0] = m;
        cols[2] = m;
    }
    return cols;
}

fn rowHeights(g: *const nls.Grid, symmetrical: bool) [3]f64 {
    var rows: [3]f64 = .{ 0, 0, 0 };
    for (0..3) |r| for (0..3) |c| {
        rows[r] = @max(rows[r], g.h[r][c]);
    };
    if (symmetrical) {
        const m = @max(rows[0], rows[2]);
        rows[0] = m;
        rows[2] = m;
    }
    return rows;
}

// start of a group of size `len` aligned begin / center / end inside [lo, hi]
fn align3(idx: usize, lo: f64, hi: f64, len: f64) f64 {
    return switch (idx) {
        0 => lo,
        1 => lo + (hi - lo - len) / 2,
        else => hi - len,
    };
}

fn placeLabels(n: *eg.ElkNode) void {
    var horizontal = true;
    if (n.parent) |p| if (p.opts.direction) |d| {
        horizontal = d == .undefined or d.isHorizontal();
    };
    const so = n.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true };
    const symmetrical = !so.asymmetrical;
    const g = nls.buildGrid(n, horizontal);
    const ll = nls.labelLabel(n);
    const cols = colWidths(&g, symmetrical);
    const rows = rowHeights(&g, symmetrical);
    const left = g.padding.left;
    const right = n.width - g.padding.right;
    const top = g.padding.top;
    const bottom = n.height - g.padding.bottom;
    const col_lo = [3]f64{ left, left + cols[0] + (if (cols[0] > 0) g.gap else 0), right - cols[2] };
    const col_hi = [3]f64{ left + cols[0], right - cols[2] - (if (cols[2] > 0) g.gap else 0), right };
    const row_lo = [3]f64{ top, top + rows[0] + (if (rows[0] > 0) g.gap else 0), bottom - rows[2] };
    const row_hi = [3]f64{ top + rows[0], bottom - rows[2] - (if (rows[2] > 0) g.gap else 0), bottom };
    const node_placement = n.opts.node_labels_placement orelse lg.NodeLabelPlacement{};
    var cursor: [3][3]f64 = @splat(@splat(0));
    for (n.labels.items) |l| {
        const loc = nls.insideLocation(l.opts.node_labels_placement orelse node_placement) orelse continue;
        const r = loc[0];
        const c = loc[1];
        if (horizontal) {
            const start = align3(r, row_lo[r], row_hi[r], g.h[r][c]);
            l.x = align3(c, col_lo[c], col_hi[c], l.width);
            l.y = start + cursor[r][c];
            cursor[r][c] += l.height + ll;
        } else {
            const start = align3(c, col_lo[c], col_hi[c], g.w[r][c]);
            l.x = start + cursor[r][c];
            l.y = align3(r, row_lo[r], row_hi[r], l.height);
            cursor[r][c] += l.width + ll;
        }
    }
}
