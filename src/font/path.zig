const std = @import("std");

pub const Error = error{ OutOfMemory, TooLarge };

pub const Pt = struct { x: f64, y: f64 };

pub const Mat = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub fn mul(m: Mat, n: Mat) Mat {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }

    pub fn apply(m: Mat, p: Pt) Pt {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }
};

pub const Seg = union(enum) { move: Pt, line: Pt, quad: [2]Pt, cubic: [3]Pt, close };

pub const max_segs = 1_000_000;

pub const Path = struct {
    segs: std.ArrayList(Seg) = .empty,

    pub fn deinit(p: *Path, alloc: std.mem.Allocator) void {
        p.segs.deinit(alloc);
    }

    fn push(p: *Path, alloc: std.mem.Allocator, s: Seg) Error!void {
        if (p.segs.items.len >= max_segs) return error.TooLarge;
        try p.segs.append(alloc, s);
    }

    pub fn moveTo(p: *Path, alloc: std.mem.Allocator, x: f64, y: f64) Error!void {
        try p.push(alloc, .{ .move = .{ .x = x, .y = y } });
    }

    pub fn lineTo(p: *Path, alloc: std.mem.Allocator, x: f64, y: f64) Error!void {
        try p.push(alloc, .{ .line = .{ .x = x, .y = y } });
    }

    pub fn quadTo(p: *Path, alloc: std.mem.Allocator, x1: f64, y1: f64, x: f64, y: f64) Error!void {
        try p.push(alloc, .{ .quad = .{ .{ .x = x1, .y = y1 }, .{ .x = x, .y = y } } });
    }

    pub fn cubicTo(p: *Path, alloc: std.mem.Allocator, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) Error!void {
        try p.push(alloc, .{ .cubic = .{ .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 }, .{ .x = x, .y = y } } });
    }

    pub fn close(p: *Path, alloc: std.mem.Allocator) Error!void {
        try p.push(alloc, .close);
    }
};
