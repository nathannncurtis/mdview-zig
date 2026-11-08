const std = @import("std");

pub const P = struct { x: f64, y: f64 };

pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Intersect = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque, P) ?P,

    fn call(self: Intersect, p: P) ?P {
        return self.f(self.ctx, p);
    }
};

pub const eps: f64 = 1;
pub const push_out: f64 = 10;

pub fn onBorder(b: Rect, p: P, tol: f64) bool {
    const half_w = b.width / 2;
    const half_h = b.height / 2;
    const left = b.x - half_w;
    const right = b.x + half_w;
    const top = b.y - half_h;
    const bottom = b.y + half_h;
    const on_left = @abs(p.x - left) <= tol and p.y >= top - tol and p.y <= bottom + tol;
    const on_right = @abs(p.x - right) <= tol and p.y >= top - tol and p.y <= bottom + tol;
    const on_top = @abs(p.y - top) <= tol and p.x >= left - tol and p.x <= right + tol;
    const on_bottom = @abs(p.y - bottom) <= tol and p.x >= left - tol and p.x <= right + tol;
    return on_left or on_right or on_top or on_bottom;
}

pub fn intersection(node: Rect, outside: P, inside: P) P {
    const x = node.x;
    const y = node.y;
    const dx = @abs(x - inside.x);
    const w = node.width / 2;
    var r = if (inside.x < outside.x) w - dx else w + dx;
    const h = node.height / 2;
    const q_total = @abs(outside.y - inside.y);
    const r_total = @abs(outside.x - inside.x);
    if (@abs(y - outside.y) * w > @abs(x - outside.x) * h) {
        const q = if (inside.y < outside.y) outside.y - h - y else y - h - outside.y;
        r = (r_total * q) / q_total;
        var res = P{
            .x = if (inside.x < outside.x) inside.x + r else inside.x - r_total + r,
            .y = if (inside.y < outside.y) inside.y + q_total - q else inside.y - q_total + q,
        };
        if (r_total == 0) res.x = outside.x;
        if (q_total == 0) res.y = outside.y;
        return res;
    }
    r = if (inside.x < outside.x) outside.x - w - x else x - w - outside.x;
    const q = (q_total * r) / r_total;
    var xx = if (inside.x < outside.x) inside.x + r_total - r else inside.x - r_total + r;
    var yy = if (inside.y < outside.y) inside.y + q else inside.y - q;
    if (r_total == 0) xx = outside.x;
    if (q_total == 0) yy = outside.y;
    return .{ .x = xx, .y = yy };
}

pub fn outsideNode(node: Rect, p: P) bool {
    const dx = @abs(p.x - node.x);
    const dy = @abs(p.y - node.y);
    return dx >= node.width / 2 or dy >= node.height / 2;
}

fn ensureTrulyOutside(b: Rect, p: P) P {
    const dx = @abs(p.x - b.x);
    const dy = @abs(p.y - b.y);
    const w = b.width / 2;
    const h = b.height / 2;
    if (@abs(dx - w) < eps or @abs(dy - h) < eps) {
        const dir_x = p.x - b.x;
        const dir_y = p.y - b.y;
        const len = @sqrt(dir_x * dir_x + dir_y * dir_y);
        if (len > 0) return .{ .x = b.x + (dir_x / len) * (len + push_out), .y = b.y + (dir_y / len) * (len + push_out) };
    }
    return p;
}

fn makeInsidePoint(b: Rect, outside: P, center: P) P {
    const is_vertical = @abs(outside.x - b.x) < eps;
    const is_horizontal = @abs(outside.y - b.y) < eps;
    return .{
        .x = if (is_vertical) outside.x else if (outside.x < b.x) b.x - b.width / 4 else b.x + b.width / 4,
        .y = if (is_horizontal) outside.y else center.y,
    };
}

fn tryNodeIntersect(node: ?Intersect, b: Rect, outside: P) ?P {
    const f = node orelse return null;
    const res = f.call(outside) orelse return null;
    const wrong_side = (outside.x < b.x and res.x > b.x) or (outside.x > b.x and res.x < b.x);
    if (wrong_side) return null;
    if (std.math.hypot(outside.x - res.x, outside.y - res.y) <= eps) return null;
    return res;
}

pub fn computeNodeIntersection(node: ?Intersect, b: Rect, outside: P, center: P) P {
    const o2 = ensureTrulyOutside(b, outside);
    if (tryNodeIntersect(node, b, o2)) |p| return p;
    return intersection(b, o2, makeInsidePoint(b, o2, center));
}

fn insideOutline(node: Intersect, centre: P, probe: P) bool {
    const crossing = node.call(probe) orelse return false;
    const probe_dist = std.math.hypot(probe.x - centre.x, probe.y - centre.y);
    const outline_dist = std.math.hypot(crossing.x - centre.x, crossing.y - centre.y);
    return probe_dist <= outline_dist + 1e-9;
}

pub fn outlineAttachPoint(node: ?Intersect, b: Rect, port: P, next: P) ?P {
    const nd = node orelse return null;
    const dx = next.x - port.x;
    const dy = next.y - port.y;
    if (dx == 0 and dy == 0) return null;
    if (@abs(dx) > 1e-6 and @abs(dy) > 1e-6) return null;
    const centre = P{ .x = b.x, .y = b.y };
    const horizontal = @abs(dx) > @abs(dy);
    var inner: f64 = if (horizontal) centre.x else centre.y;
    var outer: f64 = if (horizontal) port.x else port.y;
    if (!insideOutline(nd, centre, along(horizontal, port, inner))) return null;
    if (insideOutline(nd, centre, along(horizontal, port, outer))) return port;
    var step: usize = 0;
    while (step < 20) : (step += 1) {
        const mid = (inner + outer) / 2;
        if (insideOutline(nd, centre, along(horizontal, port, mid))) inner = mid else outer = mid;
    }
    return along(horizontal, port, inner);
}

fn along(horizontal: bool, port: P, t: f64) P {
    return if (horizontal) .{ .x = t, .y = port.y } else .{ .x = port.x, .y = t };
}

pub const Which = enum { start, end };

pub fn replaceEndpoint(points: *std.ArrayList(P), which: Which, value: ?P) void {
    const v = value orelse return;
    if (points.items.len == 0) return;
    const tol = 0.1;
    if (which == .start) {
        if (@abs(points.items[0].x - v.x) < tol and @abs(points.items[0].y - v.y) < tol) {
            _ = points.orderedRemove(0);
        } else points.items[0] = v;
    } else {
        const last = points.items.len - 1;
        if (@abs(points.items[last].x - v.x) < tol and @abs(points.items[last].y - v.y) < tol) {
            _ = points.pop();
        } else points.items[last] = v;
    }
}
