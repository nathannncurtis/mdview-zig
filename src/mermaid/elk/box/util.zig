const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");

pub const default_min = 20.0; // ElkUtil.DEFAULT_MIN_WIDTH / DEFAULT_MIN_HEIGHT

// Math.max / Math.min propagate NaN, @max / @min drop it
pub fn jmax(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    return @max(a, b);
}

pub fn jmin(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    return @min(a, b);
}

fn doubleBits(x: f64) i64 {
    if (std.math.isNan(x)) return 0x7ff8000000000000;
    return @bitCast(x);
}

// Double.compare
pub fn javaCompare(a: f64, b: f64) i32 {
    if (a < b) return -1;
    if (a > b) return 1;
    const x = doubleBits(a);
    const y = doubleBits(b);
    return if (x == y) 0 else if (x < y) -1 else 1;
}

// ElkUtil.effectiveMinSizeConstraintFor
pub fn effectiveMinSize(node: *const eg.ElkNode) lg.Vec {
    const sc = node.opts.node_size_constraints orelse lg.SizeConstraint{};
    if (!sc.minimum_size) return .{};
    const so = node.opts.node_size_options orelse lg.SizeOptions{ .default_minimum_size = true };
    var min = node.opts.node_size_minimum orelse lg.Vec{};
    if (so.default_minimum_size) {
        if (min.x <= 0) min.x = default_min;
        if (min.y <= 0) min.y = default_min;
    }
    return min;
}

fn noConstraints(sc: lg.SizeConstraint) bool {
    return !sc.ports and !sc.port_labels and !sc.node_labels and !sc.minimum_size;
}

// ElkUtil.resizeNode(node)
// shortcut: ports are not modelled (no PORTS size contribution, no port moves); ELK graphs from Mermaid have none
pub fn resizeNodeAuto(node: *eg.ElkNode) void {
    const sc = node.opts.node_size_constraints orelse lg.SizeConstraint{};
    if (noConstraints(sc)) return;
    resizeNode(node, 0, 0, true);
}

// ElkUtil.resizeNode(node, newWidth, newHeight, movePorts, moveLabels), movePorts being the shortcut above
pub fn resizeNode(node: *eg.ElkNode, new_width: f64, new_height: f64, move_labels: bool) void {
    const old_w = node.width;
    const old_h = node.height;
    var new_size = effectiveMinSize(node);
    new_size.x = jmax(new_size.x, new_width);
    new_size.y = jmax(new_size.y, new_height);
    const width_diff = new_size.x - old_w;
    const height_diff = new_size.y - old_h;
    node.width = new_size.x;
    node.height = new_size.y;
    if (move_labels) for (node.labels.items) |label| {
        const midx = label.x + label.width / 2;
        const midy = label.y + label.height / 2;
        const width_percent = midx / old_w;
        const height_percent = midy / old_h;
        if (width_percent + height_percent >= 1) {
            if (width_percent - height_percent > 0 and midy >= 0) {
                label.x += width_diff;
                label.y += height_diff * height_percent;
            } else if (width_percent - height_percent < 0 and midx >= 0) {
                label.x += width_diff * width_percent;
                label.y += height_diff;
            }
        }
    };
    node.opts.node_size_constraints = .{};
}

fn translateEdge(e: *eg.ElkEdge, dx: f64, dy: f64) void {
    for (e.sections.items) |s| {
        s.start.x += dx;
        s.start.y += dy;
        for (s.bend_points.items) |*p| {
            p.x += dx;
            p.y += dy;
        }
        s.end.x += dx;
        s.end.y += dy;
    }
    for (e.labels.items) |l| {
        l.x += dx;
        l.y += dy;
    }
    for (e.junction_points.items) |*p| {
        p.x += dx;
        p.y += dy;
    }
}

// ElkUtil.translate(parent, xoffset, yoffset)
pub fn translateContent(parent: *eg.ElkNode, dx: f64, dy: f64) void {
    for (parent.children.items) |c| {
        c.x += dx;
        c.y += dy;
    }
    for (parent.contained_edges.items) |e| translateEdge(e, dx, dy);
}

// ElkUtil.translate(parent, newSize, oldSize): content alignment of the children after the node grew
pub fn translateAligned(parent: *eg.ElkNode, new_size: lg.Vec, old_size: lg.Vec) void {
    const ca = parent.opts.content_alignment orelse lg.ContentAlignment{ .h_left = true, .v_top = true };
    var tx: f64 = 0;
    var ty: f64 = 0;
    if (new_size.x > old_size.x) {
        if (ca.h_center) {
            tx = (new_size.x - old_size.x) / 2;
        } else if (ca.h_right) {
            tx = new_size.x - old_size.x;
        }
    }
    if (new_size.y > old_size.y) {
        if (ca.v_center) {
            ty = (new_size.y - old_size.y) / 2;
        } else if (ca.v_bottom) {
            ty = new_size.y - old_size.y;
        }
    }
    translateContent(parent, tx, ty);
}
