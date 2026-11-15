const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const Vec = lg.Vec;
const Tri = model.Tri;

// BowyerWatsonTriangulation.triangulate: the Delaunay edges between `points` (indices into `points`), without the
// ones that touch the super triangle
pub fn triangulate(a: Allocator, points: []const Vec, out: *model.EdgeSet) Allocator.Error!void {
    const n: u32 = @intCast(points.len);
    var top_left: Vec = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
    var bottom_right: Vec = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
    for (points) |v| {
        top_left.x = util.javaMin(top_left.x, v.x);
        top_left.y = util.javaMin(top_left.y, v.y);
        bottom_right.x = util.javaMax(bottom_right.x, v.x);
        bottom_right.y = util.javaMax(bottom_right.y, v.y);
    }
    const size: Vec = .{ .x = bottom_right.x - top_left.x, .y = bottom_right.y - top_left.y };
    const wiggleroom = 50.0;
    const pts = try a.alloc(Vec, points.len + 3);
    @memcpy(pts[0..points.len], points);
    pts[n] = .{ .x = top_left.x - wiggleroom, .y = top_left.y - size.x - wiggleroom };
    pts[n + 1] = .{ .x = top_left.x - wiggleroom, .y = bottom_right.y + size.x + wiggleroom };
    pts[n + 2] = .{ .x = bottom_right.x + size.y / 2 + wiggleroom, .y = top_left.y + size.y / 2 };

    var tris: std.ArrayList(Tri) = .empty;
    try tris.append(a, Tri.init(pts, n, n + 1, n + 2));
    var invalid: std.ArrayList(usize) = .empty;
    var boundary: std.ArrayList(model.Edge) = .empty;
    var vertex: u32 = 0;
    while (vertex < n) : (vertex += 1) {
        invalid.clearRetainingCapacity();
        for (tris.items, 0..) |t, i| {
            if (t.inCircumcircle(pts, pts[vertex])) try invalid.append(a, i);
        }
        boundary.clearRetainingCapacity();
        for (invalid.items) |ti| {
            for (0..3) |k| {
                const e = tris.items[ti].edge(k);
                var on_boundary = true;
                for (invalid.items) |oi| {
                    if (oi != ti and tris.items[oi].containsEdge(e)) on_boundary = false;
                }
                if (on_boundary) try boundary.append(a, e);
            }
        }
        var kept: usize = 0;
        var next_invalid: usize = 0;
        for (tris.items, 0..) |t, i| {
            if (next_invalid < invalid.items.len and invalid.items[next_invalid] == i) {
                next_invalid += 1;
                continue;
            }
            tris.items[kept] = t;
            kept += 1;
        }
        tris.shrinkRetainingCapacity(kept);
        for (boundary.items) |e| {
            const t = Tri.init(pts, vertex, e.u, e.v);
            var dup = false;
            for (tris.items) |o| {
                if (o.eql(t)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try tris.append(a, t);
        }
    }

    const super = Tri.init(pts, n, n + 1, n + 2);
    for (tris.items) |t| {
        for (0..3) |k| {
            const e = t.edge(k);
            if (super.containsVertex(e.u) or super.containsVertex(e.v)) continue;
            try out.add(a, e);
        }
    }
}
