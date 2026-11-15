const std = @import("std");

pub const Glyph = struct { cp: u32, adv: u16, x0: i16, y0: i16, x1: i16, y1: i16 };

pub const glyphs = [_]Glyph{
    .{ .cp = 0, .adv = 500, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    .{ .cp = 'x', .adv = 500, .x0 = 0, .y0 = 0, .x1 = 500, .y1 = 450 },
    .{ .cp = '2', .adv = 520, .x0 = 0, .y0 = 0, .x1 = 500, .y1 = 700 },
    .{ .cp = 'a', .adv = 480, .x0 = 0, .y0 = -200, .x1 = 480, .y1 = 600 },
    .{ .cp = 'b', .adv = 480, .x0 = 0, .y0 = 0, .x1 = 480, .y1 = 720 },
    .{ .cp = '(', .adv = 300, .x0 = 0, .y0 = -300, .x1 = 300, .y1 = 700 },
    .{ .cp = 0xE001, .adv = 360, .x0 = 0, .y0 = -600, .x1 = 360, .y1 = 1400 },
    .{ .cp = 0xE002, .adv = 360, .x0 = 0, .y0 = 0, .x1 = 360, .y1 = 600 },
    .{ .cp = 0xE003, .adv = 360, .x0 = 0, .y0 = 0, .x1 = 360, .y1 = 500 },
    .{ .cp = 0xE004, .adv = 360, .x0 = 0, .y0 = 0, .x1 = 360, .y1 = 600 },
    .{ .cp = '+', .adv = 600, .x0 = 50, .y0 = 50, .x1 = 550, .y1 = 550 },
    .{ .cp = 0x221A, .adv = 600, .x0 = 0, .y0 = -200, .x1 = 600, .y1 = 800 },
};

pub const g_x = 1;
pub const g_two = 2;
pub const g_paren = 5;

const Buf = std.ArrayList(u8);

fn p16(b: *Buf, a: std.mem.Allocator, v: anytype) !void {
    var t: [2]u8 = undefined;
    std.mem.writeInt(u16, &t, @bitCast(@as(i16, @intCast(v))), .big);
    try b.appendSlice(a, &t);
}

fn p32(b: *Buf, a: std.mem.Allocator, v: u32) !void {
    var t: [4]u8 = undefined;
    std.mem.writeInt(u32, &t, v, .big);
    try b.appendSlice(a, &t);
}

fn pad4(b: *Buf, a: std.mem.Allocator) !void {
    while (b.items.len % 4 != 0) try b.append(a, 0);
}

const constants = [_]i16{
    300,  110, 1500, 1400,
    0,    250, 450,  500,
    150,  400, 50,   360,
    300,  120, 250,  160,
    400,  40,  120,  300,
    110,  600, 400,  700,
    350,  600, 150,  300,
    100,  100, 100,  100,
    400,  650, 350,  600,
    100,  200, 80,   100,
    200,  300, 100,  150,
    70,   90,  150,  70,
    90,   100, 150,  60,
    80,   100, -300, 60,
};

pub fn build(a: std.mem.Allocator) ![]u8 {
    const n = glyphs.len;
    var glyf: Buf = .empty;
    var loca: Buf = .empty;
    for (glyphs) |g| {
        try p32(&loca, a, @intCast(glyf.items.len));
        if (g.x1 == g.x0 and g.y1 == g.y0) continue;
        try p16(&glyf, a, 1);
        try p16(&glyf, a, g.x0);
        try p16(&glyf, a, g.y0);
        try p16(&glyf, a, g.x1);
        try p16(&glyf, a, g.y1);
        try p16(&glyf, a, 3);
        try p16(&glyf, a, 0);
        try glyf.appendSlice(a, &.{ 1, 1, 1, 1 });
        for ([_]i32{ g.x0, g.x1 - g.x0, 0, g.x0 - g.x1 }) |d| try p16(&glyf, a, d);
        for ([_]i32{ g.y0, 0, g.y1 - g.y0, 0 }) |d| try p16(&glyf, a, d);
        try pad4(&glyf, a);
    }
    try p32(&loca, a, @intCast(glyf.items.len));

    var head: Buf = .empty;
    try head.appendNTimes(a, 0, 54);
    std.mem.writeInt(u16, head.items[18..20], 1000, .big);
    std.mem.writeInt(u16, head.items[50..52], 1, .big);

    var hhea: Buf = .empty;
    try hhea.appendNTimes(a, 0, 36);
    std.mem.writeInt(u16, hhea.items[4..6], 800, .big);
    std.mem.writeInt(u16, hhea.items[6..8], @bitCast(@as(i16, -200)), .big);
    std.mem.writeInt(u16, hhea.items[34..36], n, .big);

    var maxp: Buf = .empty;
    try maxp.appendNTimes(a, 0, 6);
    std.mem.writeInt(u16, maxp.items[4..6], n, .big);

    var hmtx: Buf = .empty;
    for (glyphs) |g| {
        try p16(&hmtx, a, g.adv);
        try p16(&hmtx, a, 0);
    }

    var cmap: Buf = .empty;
    try p16(&cmap, a, 0);
    try p16(&cmap, a, 1);
    try p16(&cmap, a, 3);
    try p16(&cmap, a, 10);
    try p32(&cmap, a, 12);
    try p16(&cmap, a, 12);
    try p16(&cmap, a, 0);
    try p32(&cmap, a, @intCast(16 + 12 * (n - 1)));
    try p32(&cmap, a, 0);
    try p32(&cmap, a, @intCast(n - 1));
    var order: [n - 1]usize = undefined;
    for (&order, 1..) |*o, i| o.* = i;
    std.mem.sort(usize, &order, {}, struct {
        fn lt(_: void, x: usize, y: usize) bool {
            return glyphs[x].cp < glyphs[y].cp;
        }
    }.lt);
    for (order) |i| {
        try p32(&cmap, a, glyphs[i].cp);
        try p32(&cmap, a, glyphs[i].cp);
        try p32(&cmap, a, @intCast(i));
    }

    var math: Buf = .empty;
    try p32(&math, a, 0x00010000);
    const consts_len = 8 + 51 * 4 + 2;
    const gi_off = 10 + consts_len;
    const ic_len = 4 + 4 + 4 + 2;
    const var_off = gi_off + 8 + ic_len;
    try p16(&math, a, 10);
    try p16(&math, a, gi_off);
    try p16(&math, a, var_off);
    try p16(&math, a, 70);
    try p16(&math, a, 50);
    try p16(&math, a, constants[2]);
    try p16(&math, a, constants[3]);
    var i: usize = 4;
    while (i < 55) : (i += 1) {
        try p16(&math, a, constants[i]);
        try p16(&math, a, 0);
    }
    try p16(&math, a, 60);
    for ([_]u16{ 8, 0, 0, 0 }) |v| try p16(&math, a, v);
    for ([_]u16{ 8, 1, 100, 0 }) |v| try p16(&math, a, v);
    for ([_]u16{ 1, 1, g_x }) |v| try p16(&math, a, v);
    for ([_]u16{ 50, 12, 0, 1, 0, 18 }) |v| try p16(&math, a, v);
    for ([_]u16{ 1, 1, g_paren }) |v| try p16(&math, a, v);
    for ([_]u16{ 12, 2, g_paren, 1000, g_paren + 1, 2000, 0, 0, 3 }) |v| try p16(&math, a, v);
    const parts = [_][5]u16{ .{ 7, 100, 100, 600, 0 }, .{ 8, 100, 100, 500, 1 }, .{ 9, 100, 100, 600, 0 } };
    for (parts) |p| for (p) |v| try p16(&math, a, v);

    const tables = [_]struct { tag: *const [4]u8, data: []const u8 }{
        .{ .tag = "MATH", .data = math.items },
        .{ .tag = "cmap", .data = cmap.items },
        .{ .tag = "glyf", .data = glyf.items },
        .{ .tag = "head", .data = head.items },
        .{ .tag = "hhea", .data = hhea.items },
        .{ .tag = "hmtx", .data = hmtx.items },
        .{ .tag = "loca", .data = loca.items },
        .{ .tag = "maxp", .data = maxp.items },
    };
    var out: Buf = .empty;
    try p32(&out, a, 0x00010000);
    try p16(&out, a, tables.len);
    try p16(&out, a, 0);
    try p16(&out, a, 0);
    try p16(&out, a, 0);
    var off: u32 = 12 + 16 * tables.len;
    for (tables) |t| {
        try out.appendSlice(a, t.tag);
        try p32(&out, a, 0);
        try p32(&out, a, off);
        try p32(&out, a, @intCast(t.data.len));
        off += @intCast((t.data.len + 3) / 4 * 4);
    }
    for (tables) |t| {
        try out.appendSlice(a, t.data);
        try pad4(&out, a);
    }
    return out.items;
}
