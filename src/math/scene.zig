const std = @import("std");
const font = @import("font");
const layout = @import("layout.zig");

pub const max_paths = 20_000;

pub const Error = error{ OutOfMemory, TooLarge };

const Out = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    paths: u32 = 0,

    fn print(o: *Out, comptime fmt: []const u8, args: anytype) Error!void {
        const s = std.fmt.allocPrint(o.a, fmt, args) catch return error.OutOfMemory;
        defer o.a.free(s);
        try o.buf.appendSlice(o.a, s);
    }
};

fn emit(o: *Out, b: layout.Box, x: f32, y: f32) Error!void {
    switch (b.kind) {
        .empty => {},
        .rule => try o.print("<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>", .{ x, y - b.h, b.w, b.h + b.d }),
        .glyph => |g| try glyphPath(o, g, x, y),
        .group => |items| for (items) |p| try emit(o, p.box, x + p.x, y + p.y),
        .color => |c| {
            try o.print("<g fill=\"#{x:0>6}\">", .{c.rgb & 0xFFFFFF});
            try emit(o, c.child.*, x, y);
            try o.buf.appendSlice(o.a, "</g>");
        },
    }
}

fn glyphPath(o: *Out, g: layout.Glyph, x: f32, y: f32) Error!void {
    o.paths += 1;
    if (o.paths > max_paths) return error.TooLarge;
    var path: font.Path = .{};
    defer path.deinit(o.a);
    g.face.outlineAt(o.a, g.gid, g.px, x, y, &path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (path.segs.items.len == 0) return;
    try o.buf.appendSlice(o.a, "<path d=\"");
    for (path.segs.items) |seg| switch (seg) {
        .move => |p| try o.print("M{d:.2} {d:.2}", .{ p.x, p.y }),
        .line => |p| try o.print("L{d:.2} {d:.2}", .{ p.x, p.y }),
        .quad => |q| try o.print("Q{d:.2} {d:.2} {d:.2} {d:.2}", .{ q[0].x, q[0].y, q[1].x, q[1].y }),
        .cubic => |q| try o.print("C{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}", .{ q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y }),
        .close => try o.buf.append(o.a, 'Z'),
    };
    try o.buf.appendSlice(o.a, "\"/>");
}

pub fn toSvg(alloc: std.mem.Allocator, box: layout.Box, colour: u32) Error![]u8 {
    var o: Out = .{ .a = alloc };
    errdefer o.buf.deinit(alloc);
    const w = @max(box.w, 1);
    const h = @max(box.h + box.d, 1);
    try o.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.2}\" height=\"{d:.2}\" viewBox=\"0 0 {d:.2} {d:.2}\"><g fill=\"#{x:0>6}\">", .{ w, h, w, h, colour & 0xFFFFFF });
    try emit(&o, box, 0, box.h);
    try o.buf.appendSlice(alloc, "</g></svg>");
    return o.buf.toOwnedSlice(alloc);
}

test "toSvg writes a path per glyph and the box size" {
    const testfont = @import("testfont.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try font.Font.init(try testfont.build(a), 0);
    const node: layout.Node = .{ .atom = .{ .class = .ord, .cp = 'x' } };
    const box = try layout.layoutNodes(a, &.{node}, &f, .{ .size = 100 });
    const svg = try toSvg(a, box, 0x112233);
    try std.testing.expect(std.mem.indexOf(u8, svg, "width=\"50.00\" height=\"45.00\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "fill=\"#112233\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path d=\"M0.00 45.00L50.00 45.00L50.00 0.00L0.00 0.00Z\"/>") != null);
}
