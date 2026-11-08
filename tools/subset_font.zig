const std = @import("std");
const ttf = @import("ttf");
const files = @import("files.zig");

const Buf = std.ArrayList(u8);

const ranges = [_][2]u32{
    .{ 0x20, 0x7E },     .{ 0xA0, 0xFF },     .{ 0x100, 0x17F },   .{ 0x192, 0x192 },   .{ 0x2C6, 0x2C6 },
    .{ 0x2DC, 0x2DC },   .{ 0x2013, 0x2015 }, .{ 0x2018, 0x201E }, .{ 0x2020, 0x2022 }, .{ 0x2026, 0x2026 },
    .{ 0x2030, 0x2030 }, .{ 0x2039, 0x203A }, .{ 0x20AC, 0x20AC }, .{ 0x2122, 0x2122 }, .{ 0x2190, 0x2194 },
    .{ 0x2212, 0x2212 }, .{ 0x221E, 0x221E }, .{ 0x2260, 0x2265 }, .{ 0x25CF, 0x25CF }, .{ 0xFFFD, 0xFFFD },
};

const max_kern_pairs = 10920;

fn put16(b: *Buf, a: std.mem.Allocator, v: anytype) !void {
    var t: [2]u8 = undefined;
    std.mem.writeInt(u16, &t, @truncate(@as(u32, @bitCast(@as(i32, @intCast(v))))), .big);
    try b.appendSlice(a, &t);
}

fn put32(b: *Buf, a: std.mem.Allocator, v: u32) !void {
    var t: [4]u8 = undefined;
    std.mem.writeInt(u32, &t, v, .big);
    try b.appendSlice(a, &t);
}

fn checksum(d: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < d.len) : (i += 4) {
        var w: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(w[0..@min(4, d.len - i)], d[i..][0..@min(4, d.len - i)]);
        sum +%= std.mem.readInt(u32, &w, .big);
    }
    return sum;
}

const Table = struct { tag: *const [4]u8, data: []const u8 };

fn nameTable(a: std.mem.Allocator, family: []const u8, style: []const u8) ![]u8 {
    const copyright = "Digitized data copyright (c) 2010 Google Corporation. Copyright (c) 2012 Red Hat, Inc. Subset of Liberation Sans 2.1.5, renamed under the SIL Open Font License 1.1.";
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

fn cmapTable(a: std.mem.Allocator, cps: []const u32, gids: []const u16) ![]u8 {
    const Seg = struct { start: u32, end: u32, first: usize };
    var segs: std.ArrayList(Seg) = .empty;
    for (cps, 0..) |cp, i| {
        if (segs.items.len > 0 and segs.items[segs.items.len - 1].end + 1 == cp) {
            segs.items[segs.items.len - 1].end = cp;
        } else try segs.append(a, .{ .start = cp, .end = cp, .first = i });
    }
    try segs.append(a, .{ .start = 0xFFFF, .end = 0xFFFF, .first = 0 });
    const n = segs.items.len;
    var b: Buf = .empty;
    try put16(&b, a, 0);
    try put16(&b, a, 1);
    try put16(&b, a, 3);
    try put16(&b, a, 1);
    try put32(&b, a, 12);
    var glyph_count: usize = 0;
    for (segs.items[0 .. n - 1]) |s| glyph_count += s.end - s.start + 1;
    try put16(&b, a, 4);
    try put16(&b, a, 16 + n * 8 + glyph_count * 2);
    try put16(&b, a, 0);
    try put16(&b, a, n * 2);
    var es: u16 = 0;
    while ((@as(u32, 2) << @intCast(es + 1)) <= n) es += 1;
    const sr = @as(u32, 2) << @intCast(es);
    try put16(&b, a, sr);
    try put16(&b, a, es);
    try put16(&b, a, n * 2 - sr);
    for (segs.items) |s| try put16(&b, a, s.end);
    try put16(&b, a, 0);
    for (segs.items) |s| try put16(&b, a, s.start);
    for (0..n) |i| try put16(&b, a, if (i == n - 1) @as(u32, 1) else 0);
    var gpos: usize = 0;
    for (segs.items, 0..) |s, i| {
        if (i == n - 1) {
            try put16(&b, a, 0);
            continue;
        }
        try put16(&b, a, (n - i) * 2 + gpos * 2);
        gpos += s.end - s.start + 1;
    }
    for (segs.items[0 .. n - 1]) |s| {
        for (0..s.end - s.start + 1) |k| try put16(&b, a, gids[s.first + k]);
    }
    return b.items;
}

fn closure(a: std.mem.Allocator, f: *const ttf.Font, set: *std.AutoArrayHashMapUnmanaged(u16, void)) !void {
    var i: usize = 0;
    while (i < set.count()) : (i += 1) {
        const g = set.keys()[i];
        const d = try f.glyphBytes(g);
        if (d.len < 10 or std.mem.readInt(i16, d[0..2], .big) >= 0) continue;
        var p: usize = 10;
        while (p + 4 <= d.len) {
            const flags = std.mem.readInt(u16, d[p..][0..2], .big);
            try set.put(a, std.mem.readInt(u16, d[p + 2 ..][0..2], .big), {});
            p += 4 + (if (flags & 1 != 0) @as(usize, 4) else 2);
            p += if (flags & 8 != 0) @as(usize, 2) else if (flags & 0x40 != 0) 4 else if (flags & 0x80 != 0) 8 else 0;
            if (flags & 0x20 == 0) break;
        }
    }
}

fn build(a: std.mem.Allocator, src: []const u8, family: []const u8, style: []const u8) ![]u8 {
    const f = try ttf.Font.init(src, 0);
    var cps: std.ArrayList(u32) = .empty;
    var set: std.AutoArrayHashMapUnmanaged(u16, void) = .empty;
    try set.put(a, 0, {});
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const g = f.glyphIndex(cp);
            if (g == 0) continue;
            try cps.append(a, cp);
            try set.put(a, g, {});
        }
    }
    try closure(a, &f, &set);
    const old = try a.dupe(u16, set.keys());
    std.mem.sort(u16, old, {}, std.sort.asc(u16));
    const n = old.len;
    var remap: std.AutoHashMapUnmanaged(u16, u16) = .empty;
    for (old, 0..) |g, i| try remap.put(a, g, @intCast(i));
    const gids = try a.alloc(u16, cps.items.len);
    for (cps.items, 0..) |cp, i| gids[i] = remap.get(f.glyphIndex(cp)).?;

    var glyf: Buf = .empty;
    var loca: Buf = .empty;
    var hmtx: Buf = .empty;
    for (old) |g| {
        try put32(&loca, a, @intCast(glyf.items.len));
        const d = try a.dupe(u8, try f.glyphBytes(g));
        if (d.len >= 10 and std.mem.readInt(i16, d[0..2], .big) < 0) {
            var p: usize = 10;
            while (true) {
                const flags = std.mem.readInt(u16, d[p..][0..2], .big);
                std.mem.writeInt(u16, d[p + 2 ..][0..2], remap.get(std.mem.readInt(u16, d[p + 2 ..][0..2], .big)).?, .big);
                p += 4 + (if (flags & 1 != 0) @as(usize, 4) else 2);
                p += if (flags & 8 != 0) @as(usize, 2) else if (flags & 0x40 != 0) 4 else if (flags & 0x80 != 0) 8 else 0;
                if (flags & 0x20 == 0) break;
            }
        }
        try glyf.appendSlice(a, d);
        while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
        try put16(&hmtx, a, @as(u32, @intFromFloat(f.advance(g))));
        try put16(&hmtx, a, f.leftBearing(g));
    }
    try put32(&loca, a, @intCast(glyf.items.len));

    var pairs: Buf = .empty;
    var npairs: usize = 0;
    for (old, 0..) |l, li| {
        for (old, 0..) |r, ri| {
            const k: i32 = @intFromFloat(f.kern(l, r));
            if (k == 0) continue;
            try put16(&pairs, a, li);
            try put16(&pairs, a, ri);
            try put16(&pairs, a, k);
            npairs += 1;
        }
    }
    if (npairs > max_kern_pairs) return error.TooManyKernPairs;
    var kern: Buf = .empty;
    try put16(&kern, a, 0);
    try put16(&kern, a, 1);
    try put16(&kern, a, 0);
    try put16(&kern, a, 14 + npairs * 6);
    try put16(&kern, a, 1);
    try put16(&kern, a, npairs);
    var es: u16 = 0;
    while ((@as(u32, 1) << @intCast(es + 1)) <= npairs) es += 1;
    const sr = (@as(u32, 1) << @intCast(es)) * 6;
    try put16(&kern, a, sr);
    try put16(&kern, a, es);
    try put16(&kern, a, npairs * 6 - sr);
    try kern.appendSlice(a, pairs.items);

    const head = try a.dupe(u8, src[(try tableAt(src, "head"))..][0..54]);
    @memset(head[8..12], 0);
    std.mem.writeInt(i16, head[50..52], 1, .big);
    const hhea = try a.dupe(u8, src[(try tableAt(src, "hhea"))..][0..36]);
    std.mem.writeInt(u16, hhea[34..36], @intCast(n), .big);
    const maxp = try a.dupe(u8, src[(try tableAt(src, "maxp"))..][0..32]);
    std.mem.writeInt(u16, maxp[4..6], @intCast(n), .big);

    const tables = [_]Table{
        .{ .tag = "cmap", .data = try cmapTable(a, cps.items, gids) },
        .{ .tag = "glyf", .data = glyf.items },
        .{ .tag = "head", .data = head },
        .{ .tag = "hhea", .data = hhea },
        .{ .tag = "hmtx", .data = hmtx.items },
        .{ .tag = "kern", .data = kern.items },
        .{ .tag = "loca", .data = loca.items },
        .{ .tag = "maxp", .data = maxp },
        .{ .tag = "name", .data = try nameTable(a, family, style) },
    };
    var out: Buf = .empty;
    try put32(&out, a, 0x00010000);
    try put16(&out, a, tables.len);
    try put16(&out, a, 128);
    try put16(&out, a, 3);
    try put16(&out, a, tables.len * 16 - 128);
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

fn tableAt(d: []const u8, tag: *const [4]u8) !usize {
    const n = std.mem.readInt(u16, d[4..6], .big);
    for (0..n) |i| {
        const rec = 12 + i * 16;
        if (std.mem.eql(u8, d[rec..][0..4], tag)) return std.mem.readInt(u32, d[rec + 8 ..][0..4], .big);
    }
    return error.MissingTable;
}

fn verify(a: std.mem.Allocator, src: []const u8, out: []const u8) !void {
    const f = try ttf.Font.init(src, 0);
    const g = try ttf.Font.init(out, 0);
    var checked: usize = 0;
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const fa = f.glyphIndex(cp);
            if (fa == 0) continue;
            const ga = g.glyphIndex(cp);
            if (ga == 0 or f.advance(fa) != g.advance(ga)) return error.AdvanceMismatch;
            var p1: ttf.Path = .{};
            var p2: ttf.Path = .{};
            try f.outline(a, fa, .{}, &p1);
            try g.outline(a, ga, .{}, &p2);
            if (p1.segs.items.len != p2.segs.items.len) return error.OutlineMismatch;
            for (p1.segs.items, p2.segs.items) |s1, s2| if (!std.meta.eql(s1, s2)) return error.OutlineMismatch;
            for (ranges) |r2| {
                var cp2 = r2[0];
                while (cp2 <= r2[1]) : (cp2 += 1) {
                    const fb = f.glyphIndex(cp2);
                    if (fb == 0) continue;
                    if (f.kern(fa, fb) != g.kern(ga, g.glyphIndex(cp2))) return error.KernMismatch;
                }
            }
            checked += 1;
        }
    }
    if (checked < 200) return error.TooFewGlyphs;
}

pub fn main(init: std.process.Init) !void {
    const args = try files.args(init, 4, "subset-font <in.ttf> <out.ttf> <family> <style>");
    const arena = init.arena.allocator();
    const src = try files.read(init.io, arena, args[0]);
    const out = try build(arena, src, args[2], args[3]);
    try verify(arena, src, out);
    try files.write(init.io, args[1], out);
    files.say(init.io, "wrote {s}: {d} bytes\n", .{ args[1], out.len });
}
