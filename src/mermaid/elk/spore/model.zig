const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const Allocator = std.mem.Allocator;
const Vec = lg.Vec;

pub const fuzziness = 0.0001;

// com.google.common.math.DoubleMath.fuzzyCompare
pub fn fuzzyCompare(a: f64, b: f64, tolerance: f64) i32 {
    if (a == b or @abs(a - b) <= tolerance or (std.math.isNan(a) and std.math.isNan(b))) return 0;
    if (a < b) return -1;
    if (a > b) return 1;
    return if (std.math.isNan(a)) 1 else -1;
}

pub fn distance(a: Vec, b: Vec) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn center(r: Rect) Vec {
        return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    }
};

// org.eclipse.elk.alg.common.spore.Node
pub const Node = struct {
    orig: Vec,
    vertex: Vec,
    rect: Rect,

    pub fn translate(n: *Node, v: Vec) void {
        n.vertex.add(v);
        n.rect.x += v.x;
        n.rect.y += v.y;
    }

    pub fn setCenterPosition(n: *Node, p: Vec) void {
        var d = p;
        d.sub(n.vertex);
        n.translate(d);
    }
};

// Utils.overlap
pub fn overlap(r1: Rect, r2: Rect) f64 {
    const horizontal_overlap = util.javaMin(@abs(r1.x - (r2.x + r2.w)), @abs(r1.x + r1.w - r2.x));
    const vertical_overlap = util.javaMin(@abs(r1.y - (r2.y + r2.h)), @abs(r1.y + r1.h - r2.y));
    const hcd = @abs((r1.x + r1.w / 2.0) - (r2.x + r2.w / 2.0));
    if (hcd > r1.w / 2.0 + r2.w / 2.0) return 1.0;
    const vcd = @abs((r1.y + r1.h / 2.0) - (r2.y + r2.h / 2.0));
    if (vcd > r1.h / 2.0 + r2.h / 2.0) return 1.0;
    if (hcd == 0.0 and vcd == 0.0) return 0;
    if (hcd == 0.0) return vertical_overlap / vcd + 1;
    if (vcd == 0.0) return horizontal_overlap / hcd + 1;
    return util.javaMin(horizontal_overlap / hcd, vertical_overlap / vcd) + 1;
}

// ElkMath.shortestDistance(ElkRectangle, ElkRectangle)
pub fn shortestDistance(r1: Rect, r2: Rect) f64 {
    const eps = 0.00001;
    const right = r2.x - (r1.x + r1.w);
    const left = r1.x - (r2.x + r2.w);
    const top = r1.y - (r2.y + r2.h);
    const bottom = r2.y - (r1.y + r1.h);
    const horz = util.javaMax(left, right);
    const vert = util.javaMax(top, bottom);
    if ((fuzzyCompare(horz, 0, eps) >= 0) != (fuzzyCompare(vert, 0, eps) >= 0)) return util.javaMax(vert, horz);
    if (fuzzyCompare(horz, 0, eps) > 0) return @sqrt(vert * vert + horz * horz);
    return -@sqrt(vert * vert + horz * horz);
}

// TEdge over node indices; equality ignores direction
pub const Edge = struct { u: u32, v: u32 };

// KVector.hashCode as elkjs compiles it: Double.hashCode is the int-truncated value and sums are not wrapped
fn roundInt(x: f64) i32 {
    if (std.math.isNan(x)) return 0;
    return @intFromFloat(std.math.clamp(x, -2147483648.0, 2147483647.0));
}

pub fn vertexHash(v: Vec) f64 {
    const reversed: i32 = @bitCast(@bitReverse(@as(u32, @bitCast(roundInt(v.y)))));
    return @as(f64, @floatFromInt(roundInt(v.x))) + @as(f64, @floatFromInt(reversed));
}

// Where a java.util.HashMap as elkjs runs it (a JS Map keyed by hash code) iterates a new entry: behind the last
// entry with the same hash code, else at the end
pub fn insertAt(hashes: []const f64, h: f64) usize {
    var i = hashes.len;
    while (i > 0) : (i -= 1) {
        if (hashes[i - 1] == h) return i;
    }
    return hashes.len;
}

// A java.util.HashSet<TEdge> in the order elkjs iterates it
pub const EdgeSet = struct {
    list: std.ArrayList(Edge) = .empty,
    hashes: std.ArrayList(f64) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn key(e: Edge) u64 {
        return (@as(u64, @min(e.u, e.v)) << 32) | @max(e.u, e.v);
    }

    pub fn add(s: *EdgeSet, a: Allocator, e: Edge, pts: []const Vec) Allocator.Error!void {
        const r = try s.seen.getOrPut(a, key(e));
        if (r.found_existing) return;
        const h = vertexHash(pts[e.u]) + vertexHash(pts[e.v]);
        const at = insertAt(s.hashes.items, h);
        try s.list.insert(a, at, e);
        try s.hashes.insert(a, at, h);
    }
};

// TTriangle over point indices
pub const Tri = struct {
    v: [3]u32,
    cc: Vec,
    hash: f64,

    pub fn init(pts: []const Vec, a: u32, b: u32, c: u32) Tri {
        const pa = pts[a];
        const pb = pts[b];
        const pc = pts[c];
        const abx = pb.x - pa.x;
        const aby = pb.y - pa.y;
        const acx = pc.x - pa.x;
        const acy = pc.y - pa.y;
        const bcx = pc.x - pb.x;
        const bcy = pc.y - pb.y;
        const e = abx * (pa.x + pb.x) + aby * (pa.y + pb.y);
        const f = acx * (pa.x + pc.x) + acy * (pa.y + pc.y);
        const g = 2 * (abx * bcy - aby * bcx);
        return .{ .v = .{ a, b, c }, .hash = vertexHash(pa) + vertexHash(pb) + vertexHash(pc), .cc = .{ .x = (acy * e - aby * f) / g, .y = (abx * f - acx * e) / g } };
    }

    pub fn edge(t: Tri, i: usize) Edge {
        return .{ .u = t.v[i], .v = t.v[(i + 1) % 3] };
    }

    pub fn containsVertex(t: Tri, x: u32) bool {
        return t.v[0] == x or t.v[1] == x or t.v[2] == x;
    }

    pub fn containsEdge(t: Tri, e: Edge) bool {
        for (0..3) |i| {
            const o = t.edge(i);
            if ((o.u == e.u and o.v == e.v) or (o.u == e.v and o.v == e.u)) return true;
        }
        return false;
    }

    pub fn inCircumcircle(t: Tri, pts: []const Vec, p: Vec) bool {
        return fuzzyCompare(distance(t.cc, p), distance(t.cc, pts[t.v[0]]), fuzziness) < 0;
    }

    pub fn eql(t: Tri, o: Tri) bool {
        return t.containsVertex(o.v[0]) and t.containsVertex(o.v[1]) and t.containsVertex(o.v[2]);
    }
};
