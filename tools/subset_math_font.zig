const std = @import("std");
const ttf = @import("ttf");
const ranges = @import("math_ranges").ranges;
const files = @import("files.zig");
const sfnt = @import("sfnt_write.zig");

const Buf = sfnt.Buf;
const put16 = sfnt.put16;
const put32 = sfnt.put32;
const Font = ttf.Font;
const Dir = ttf.math.Dir;

const copyright = "Copyright 2001-2021 The STIX Fonts Project Authors (https://github.com/stipub/stixfonts). Subset of STIX Two Math, renamed under the SIL Open Font License 1.1.";

const Set = std.AutoArrayHashMapUnmanaged(u16, void);

fn encNum(b: *Buf, a: std.mem.Allocator, v: f64) !void {
    if (v != @round(v)) {
        try b.append(a, 255);
        try put32(b, a, @bitCast(@as(i32, @intFromFloat(@round(v * 65536)))));
        return;
    }
    const i: i32 = @intFromFloat(v);
    if (i >= -107 and i <= 107) {
        try b.append(a, @intCast(i + 139));
    } else if (i >= 108 and i <= 1131) {
        try b.append(a, @intCast(247 + ((i - 108) >> 8)));
        try b.append(a, @intCast((i - 108) & 255));
    } else if (i <= -108 and i >= -1131) {
        try b.append(a, @intCast(251 + ((-i - 108) >> 8)));
        try b.append(a, @intCast((-i - 108) & 255));
    } else {
        try b.append(a, 28);
        try put16(b, a, i);
    }
}

fn charString(a: std.mem.Allocator, f: *const Font, g: u16) ![]u8 {
    var path: ttf.Path = .{};
    try f.outline(a, g, .{}, &path);
    var b: Buf = .empty;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (path.segs.items) |s| switch (s) {
        .move => |p| {
            try encNum(&b, a, p.x - cx);
            try encNum(&b, a, p.y - cy);
            try b.append(a, 21);
            cx = p.x;
            cy = p.y;
        },
        .line => |p| {
            try encNum(&b, a, p.x - cx);
            try encNum(&b, a, p.y - cy);
            try b.append(a, 5);
            cx = p.x;
            cy = p.y;
        },
        .cubic => |c| {
            try encNum(&b, a, c[0].x - cx);
            try encNum(&b, a, c[0].y - cy);
            try encNum(&b, a, c[1].x - c[0].x);
            try encNum(&b, a, c[1].y - c[0].y);
            try encNum(&b, a, c[2].x - c[1].x);
            try encNum(&b, a, c[2].y - c[1].y);
            try b.append(a, 8);
            cx = c[2].x;
            cy = c[2].y;
        },
        .quad, .close => {},
    };
    try b.append(a, 14);
    return b.items;
}

fn index(a: std.mem.Allocator, objs: []const []const u8) ![]u8 {
    var b: Buf = .empty;
    try put16(&b, a, objs.len);
    if (objs.len == 0) return b.items;
    var total: usize = 1;
    for (objs) |o| total += o.len;
    const off_size: usize = if (total < 256) 1 else if (total < 65536) 2 else 3;
    try b.append(a, @intCast(off_size));
    var off: usize = 1;
    for (0..objs.len + 1) |i| {
        var t: [4]u8 = undefined;
        std.mem.writeInt(u32, &t, @intCast(off), .big);
        try b.appendSlice(a, t[4 - off_size ..]);
        if (i < objs.len) off += objs[i].len;
    }
    for (objs) |o| try b.appendSlice(a, o);
    return b.items;
}

fn cffTable(a: std.mem.Allocator, strings: []const []const u8) ![]u8 {
    const name = try index(a, &.{"mdviewmath"});
    const cs = try index(a, strings);
    const top_len = 2 + 1 + 2 + 17;
    const cs_off: i32 = @intCast(4 + name.len + top_len + 4);
    const priv_off: i32 = cs_off + @as(i32, @intCast(cs.len));
    var top: Buf = .empty;
    try top.append(a, 29);
    try put32(&top, a, @bitCast(cs_off));
    try top.append(a, 17);
    try top.append(a, 29);
    try put32(&top, a, 4);
    try top.append(a, 29);
    try put32(&top, a, @bitCast(priv_off));
    try top.append(a, 18);
    var out: Buf = .empty;
    try out.appendSlice(a, &.{ 1, 0, 4, 4 });
    try out.appendSlice(a, name);
    try out.appendSlice(a, try index(a, &.{top.items}));
    try out.appendSlice(a, &.{ 0, 0, 0, 0 });
    try out.appendSlice(a, cs);
    try out.appendSlice(a, &.{ 139, 20, 139, 21 });
    return out.items;
}

fn cmapTable(a: std.mem.Allocator, cps: []const u32, gids: []const u16) ![]u8 {
    const Group = struct { start: u32, end: u32, gid: u32 };
    var groups: std.ArrayList(Group) = .empty;
    for (cps, gids) |cp, g| {
        if (groups.items.len > 0) {
            const last = &groups.items[groups.items.len - 1];
            if (last.end + 1 == cp and last.gid + (last.end - last.start) + 1 == g) {
                last.end = cp;
                continue;
            }
        }
        try groups.append(a, .{ .start = cp, .end = cp, .gid = g });
    }
    var b: Buf = .empty;
    try put16(&b, a, 0);
    try put16(&b, a, 1);
    try put16(&b, a, 3);
    try put16(&b, a, 10);
    try put32(&b, a, 12);
    try put16(&b, a, 12);
    try put16(&b, a, 0);
    try put32(&b, a, @intCast(16 + groups.items.len * 12));
    try put32(&b, a, 0);
    try put32(&b, a, @intCast(groups.items.len));
    for (groups.items) |g| {
        try put32(&b, a, g.start);
        try put32(&b, a, g.end);
        try put32(&b, a, g.gid);
    }
    return b.items;
}

fn coverageBytes(b: *Buf, a: std.mem.Allocator, gids: []const u16) !void {
    try put16(b, a, 1);
    try put16(b, a, gids.len);
    for (gids) |g| try put16(b, a, g);
}

fn valueTable(a: std.mem.Allocator, f: *const Font, table: usize, kept: []const u16) ![]u8 {
    const m = f.math.?;
    var gids: std.ArrayList(u16) = .empty;
    var vals: std.ArrayList(i16) = .empty;
    for (kept, 0..) |old, new| {
        const v = m.value(table, old) orelse continue;
        try gids.append(a, @intCast(new));
        try vals.append(a, v);
    }
    var b: Buf = .empty;
    try put16(&b, a, 4 + vals.items.len * 4);
    try put16(&b, a, vals.items.len);
    for (vals.items) |v| {
        try put16(&b, a, v);
        try put16(&b, a, 0);
    }
    try coverageBytes(&b, a, gids.items);
    return b.items;
}

fn mathTable(a: std.mem.Allocator, f: *const Font, kept: []const u16, remap: *const std.AutoHashMapUnmanaged(u16, u16), base: *const Set) ![]u8 {
    const m = f.math.?;
    var consts: Buf = .empty;
    try consts.appendSlice(a, f.data[m.constants_at..][0..214]);
    var p: usize = 8;
    while (p < 212) : (p += 4) @memset(consts.items[p + 2 ..][0..2], 0);

    var info: Buf = .empty;
    const ital = try valueTable(a, f, m.italics, kept);
    const acc = try valueTable(a, f, m.accents, kept);
    try put16(&info, a, 8);
    try put16(&info, a, 8 + ital.len);
    try put16(&info, a, 0);
    try put16(&info, a, 0);
    try info.appendSlice(a, ital);
    try info.appendSlice(a, acc);

    var vars: Buf = .empty;
    var lists: [2]std.ArrayList(u16) = .{ .empty, .empty };
    var cons: [2]Buf = .{ .empty, .empty };
    var rel: [2]std.ArrayList(usize) = .{ .empty, .empty };
    for ([_]Dir{ .vert, .horiz }, 0..) |dir, di| {
        for (kept, 0..) |old, new| {
            if (!base.contains(old)) continue;
            const v = f.math.?.variantsOf(old, dir);
            if (v.data.len == 0) continue;
            const asm_opt = f.math.?.assembly(old, dir);
            try lists[di].append(a, @intCast(new));
            try rel[di].append(a, cons[di].items.len);
            const cb = &cons[di];
            try put16(cb, a, if (asm_opt != null) 4 + v.count * 4 else 0);
            try put16(cb, a, v.count);
            for (0..v.count) |i| {
                const e = v.get(i).?;
                try put16(cb, a, remap.get(e.gid).?);
                try put16(cb, a, e.advance);
            }
            if (asm_opt) |as| {
                try put16(cb, a, as.italics_correction);
                try put16(cb, a, 0);
                try put16(cb, a, as.count);
                for (0..as.count) |i| {
                    const part = as.part(i).?;
                    try put16(cb, a, remap.get(part.gid).?);
                    try put16(cb, a, part.start_connector);
                    try put16(cb, a, part.end_connector);
                    try put16(cb, a, part.full_advance);
                    try put16(cb, a, @intFromBool(part.extender));
                }
            }
        }
    }
    const head_len = 10 + 2 * (lists[0].items.len + lists[1].items.len);
    const vcov_off = head_len;
    const hcov_off = vcov_off + 4 + 2 * lists[0].items.len;
    const cons_off = hcov_off + 4 + 2 * lists[1].items.len;
    try put16(&vars, a, m.min_connector_overlap);
    try put16(&vars, a, vcov_off);
    try put16(&vars, a, hcov_off);
    try put16(&vars, a, lists[0].items.len);
    try put16(&vars, a, lists[1].items.len);
    for ([_]usize{ 0, 1 }) |di| {
        const base_off = cons_off + if (di == 1) cons[0].items.len else 0;
        for (rel[di].items) |r| try put16(&vars, a, base_off + r);
    }
    try coverageBytes(&vars, a, lists[0].items);
    try coverageBytes(&vars, a, lists[1].items);
    try vars.appendSlice(a, cons[0].items);
    try vars.appendSlice(a, cons[1].items);
    if (vars.items.len > 65535) return error.VariantsTooLarge;

    var out: Buf = .empty;
    try put32(&out, a, 0x00010000);
    try put16(&out, a, 10);
    try put16(&out, a, 10 + consts.items.len);
    try put16(&out, a, 10 + consts.items.len + info.items.len);
    try out.appendSlice(a, consts.items);
    try out.appendSlice(a, info.items);
    try out.appendSlice(a, vars.items);
    return out.items;
}

fn build(a: std.mem.Allocator, src: []const u8) ![]u8 {
    const f = try Font.init(src, 0);
    const m = f.math orelse return error.NoMathTable;
    var cps: std.ArrayList(u32) = .empty;
    var base: Set = .empty;
    try base.put(a, 0, {});
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const g = f.glyphIndex(cp);
            if (g == 0) continue;
            try cps.append(a, cp);
            try base.put(a, g, {});
        }
    }
    var keep: Set = .empty;
    for (base.keys()) |g| try keep.put(a, g, {});
    for (base.keys()) |g| for ([_]Dir{ .vert, .horiz }) |dir| {
        const v = m.variantsOf(g, dir);
        for (0..v.count) |i| try keep.put(a, v.get(i).?.gid, {});
        if (m.assembly(g, dir)) |as| for (0..as.count) |i| try keep.put(a, as.part(i).?.gid, {});
    };
    const kept = try a.dupe(u16, keep.keys());
    std.mem.sort(u16, kept, {}, std.sort.asc(u16));
    var remap: std.AutoHashMapUnmanaged(u16, u16) = .empty;
    for (kept, 0..) |g, i| try remap.put(a, g, @intCast(i));
    const gids = try a.alloc(u16, cps.items.len);
    for (cps.items, 0..) |cp, i| gids[i] = remap.get(f.glyphIndex(cp)).?;

    const strings = try a.alloc([]const u8, kept.len);
    var hmtx: Buf = .empty;
    for (kept, 0..) |g, i| {
        strings[i] = try charString(a, &f, g);
        try put16(&hmtx, a, @as(u32, @intFromFloat(f.advance(g))));
        try put16(&hmtx, a, f.bbox(g).x0);
    }
    const head = try a.dupe(u8, src[(try sfnt.tableAt(src, "head"))..][0..54]);
    @memset(head[8..12], 0);
    const hhea = try a.dupe(u8, src[(try sfnt.tableAt(src, "hhea"))..][0..36]);
    std.mem.writeInt(u16, hhea[34..36], @intCast(kept.len), .big);
    var maxp: Buf = .empty;
    try put32(&maxp, a, 0x00005000);
    try put16(&maxp, a, kept.len);
    const tables = [_]sfnt.Table{
        .{ .tag = "CFF ", .data = try cffTable(a, strings) },
        .{ .tag = "MATH", .data = try mathTable(a, &f, kept, &remap, &base) },
        .{ .tag = "cmap", .data = try cmapTable(a, cps.items, gids) },
        .{ .tag = "head", .data = head },
        .{ .tag = "hhea", .data = hhea },
        .{ .tag = "hmtx", .data = hmtx.items },
        .{ .tag = "maxp", .data = maxp.items },
        .{ .tag = "name", .data = try sfnt.nameTable(a, "mdview Math", "Regular", copyright) },
    };
    return sfnt.assemble(a, 0x4F54544F, &tables);
}

fn samePath(a: std.mem.Allocator, f: *const Font, fg: u16, g: *const Font, gg: u16) !void {
    var p1: ttf.Path = .{};
    var p2: ttf.Path = .{};
    try f.outline(a, fg, .{}, &p1);
    try g.outline(a, gg, .{}, &p2);
    if (p1.segs.items.len != p2.segs.items.len) return error.OutlineMismatch;
    for (p1.segs.items, p2.segs.items) |s1, s2| if (!std.meta.eql(s1, s2)) return error.OutlineMismatch;
    if (f.advance(fg) != g.advance(gg)) return error.AdvanceMismatch;
}

fn verify(a: std.mem.Allocator, src: []const u8, out: []const u8) !void {
    const f = try Font.init(src, 0);
    const g = try Font.init(out, 0);
    if (!std.meta.eql(f.math.?.constants, g.math.?.constants)) return error.ConstantsMismatch;
    if (f.math.?.min_connector_overlap != g.math.?.min_connector_overlap) return error.ConstantsMismatch;
    var checked: usize = 0;
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const fa = f.glyphIndex(cp);
            if (fa == 0) continue;
            const ga = g.glyphIndex(cp);
            if (ga == 0) return error.MissingGlyph;
            try samePath(a, &f, fa, &g, ga);
            if (f.italicCorrection(fa) != g.italicCorrection(ga) or f.topAccent(fa) != g.topAccent(ga)) return error.InfoMismatch;
            for ([_]Dir{ .vert, .horiz }) |dir| {
                const v1 = f.math.?.variantsOf(fa, dir);
                const v2 = g.math.?.variantsOf(ga, dir);
                if (v1.count != v2.count) return error.VariantMismatch;
                for (0..v1.count) |i| {
                    const e1 = v1.get(i).?;
                    const e2 = v2.get(i).?;
                    if (e1.advance != e2.advance) return error.VariantMismatch;
                    try samePath(a, &f, e1.gid, &g, e2.gid);
                }
                const a1 = f.math.?.assembly(fa, dir);
                const a2 = g.math.?.assembly(ga, dir);
                if ((a1 == null) != (a2 == null)) return error.AssemblyMismatch;
                if (a1) |x| {
                    const y = a2.?;
                    if (x.count != y.count or x.italics_correction != y.italics_correction) return error.AssemblyMismatch;
                    for (0..x.count) |i| {
                        const p1 = x.part(i).?;
                        const p2 = y.part(i).?;
                        if (p1.start_connector != p2.start_connector or p1.end_connector != p2.end_connector or p1.full_advance != p2.full_advance or p1.extender != p2.extender) return error.AssemblyMismatch;
                        try samePath(a, &f, p1.gid, &g, p2.gid);
                    }
                }
            }
            checked += 1;
        }
    }
    if (checked < 1000) return error.TooFewGlyphs;
}

fn deflate(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(a, 1 << 16);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    const c = try a.create(std.compress.flate.Compress);
    c.* = try std.compress.flate.Compress.init(&out.writer, window, .raw, .best);
    try c.writer.writeAll(raw);
    try c.finish();
    return out.written();
}

pub fn main(init: std.process.Init) !void {
    const args = try files.args(init, 2, "subset-math-font <in.otf> <out.z>");
    const arena = init.arena.allocator();
    const src = try files.read(init.io, arena, args[0]);
    const raw = try build(arena, src);
    try verify(arena, src, raw);
    const z = try deflate(arena, raw);
    try files.write(init.io, args[1], z);
    files.say(init.io, "wrote {s}: {d} bytes deflated from {d}\n", .{ args[1], z.len, raw.len });
}
