const std = @import("std");

pub const Buf = std.ArrayList(u8);

pub const Table = struct { tag: *const [4]u8, data: []const u8 };

pub fn put16(b: *Buf, a: std.mem.Allocator, v: anytype) !void {
    var t: [2]u8 = undefined;
    std.mem.writeInt(u16, &t, @truncate(@as(u32, @bitCast(@as(i32, @intCast(v))))), .big);
    try b.appendSlice(a, &t);
}

pub fn put32(b: *Buf, a: std.mem.Allocator, v: u32) !void {
    var t: [4]u8 = undefined;
    std.mem.writeInt(u32, &t, v, .big);
    try b.appendSlice(a, &t);
}

pub fn checksum(d: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < d.len) : (i += 4) {
        var w: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(w[0..@min(4, d.len - i)], d[i..][0..@min(4, d.len - i)]);
        sum +%= std.mem.readInt(u32, &w, .big);
    }
    return sum;
}

pub fn tableAt(d: []const u8, tag: *const [4]u8) !usize {
    const n = std.mem.readInt(u16, d[4..6], .big);
    for (0..n) |i| {
        const rec = 12 + i * 16;
        if (std.mem.eql(u8, d[rec..][0..4], tag)) return std.mem.readInt(u32, d[rec + 8 ..][0..4], .big);
    }
    return error.MissingTable;
}

pub fn nameTable(a: std.mem.Allocator, family: []const u8, style: []const u8, copyright: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(a, "{s} {s}", .{ family, style });
    const ps = try std.fmt.allocPrint(a, "{s}-{s}", .{ family, style });
    const strings = [_]struct { id: u16, s: []const u8 }{
        .{ .id = 0, .s = copyright },
        .{ .id = 1, .s = family },
        .{ .id = 2, .s = style },
        .{ .id = 4, .s = full },
        .{ .id = 6, .s = ps },
        .{ .id = 13, .s = "Licensed under the SIL Open Font License, Version 1.1." },
        .{ .id = 14, .s = "https://openfontlicense.org" },
    };
    var head: Buf = .empty;
    var store: Buf = .empty;
    try put16(&head, a, 0);
    try put16(&head, a, strings.len);
    try put16(&head, a, 6 + strings.len * 12);
    for (strings) |e| {
        try put16(&head, a, 3);
        try put16(&head, a, 1);
        try put16(&head, a, 0x409);
        try put16(&head, a, e.id);
        try put16(&head, a, e.s.len * 2);
        try put16(&head, a, store.items.len);
        for (e.s) |c| try put16(&store, a, c);
    }
    try head.appendSlice(a, store.items);
    return head.items;
}

pub fn assemble(a: std.mem.Allocator, magic: u32, tables: []const Table) ![]u8 {
    var out: Buf = .empty;
    try put32(&out, a, magic);
    try put16(&out, a, tables.len);
    var es: u5 = 0;
    while ((@as(u32, 2) << es) <= tables.len) es += 1;
    const sr = (@as(u32, 1) << es) * 16;
    try put16(&out, a, sr);
    try put16(&out, a, es);
    try put16(&out, a, tables.len * 16 - sr);
    var off: usize = 12 + tables.len * 16;
    for (tables) |t| {
        try out.appendSlice(a, t.tag);
        try put32(&out, a, checksum(t.data));
        try put32(&out, a, @intCast(off));
        try put32(&out, a, @intCast(t.data.len));
        off += (t.data.len + 3) & ~@as(usize, 3);
    }
    var head_off: usize = 0;
    for (tables) |t| {
        if (std.mem.eql(u8, t.tag, "head")) head_off = out.items.len;
        try out.appendSlice(a, t.data);
        while (out.items.len % 4 != 0) try out.append(a, 0);
    }
    std.mem.writeInt(u32, out.items[head_off + 8 ..][0..4], 0xB1B0AFBA -% checksum(out.items), .big);
    return out.items;
}
