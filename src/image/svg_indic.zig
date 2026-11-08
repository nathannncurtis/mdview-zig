const std = @import("std");
const shape = @import("svg_shape.zig");

const G = shape.G;

pub const Script = struct { tags: [2]*const [4]u8, base: u32, pre: []const u32 };

const blocks = [_]Script{
    .{ .tags = .{ "dev2", "deva" }, .base = 0x0900, .pre = &.{0x3F} },
    .{ .tags = .{ "bng2", "beng" }, .base = 0x0980, .pre = &.{ 0x3F, 0x47, 0x48 } },
    .{ .tags = .{ "gur2", "guru" }, .base = 0x0A00, .pre = &.{0x3F} },
    .{ .tags = .{ "gjr2", "gujr" }, .base = 0x0A80, .pre = &.{0x3F} },
    .{ .tags = .{ "ory2", "orya" }, .base = 0x0B00, .pre = &.{0x47} },
    .{ .tags = .{ "tml2", "taml" }, .base = 0x0B80, .pre = &.{ 0x46, 0x47, 0x48 } },
    .{ .tags = .{ "tel2", "telu" }, .base = 0x0C00, .pre = &.{} },
    .{ .tags = .{ "knd2", "knda" }, .base = 0x0C80, .pre = &.{} },
    .{ .tags = .{ "mlm2", "mlym" }, .base = 0x0D00, .pre = &.{ 0x46, 0x47, 0x48 } },
};

pub fn scriptOf(cp: u32) ?Script {
    for (blocks) |b| if (cp >= b.base and cp < b.base + 0x80) return b;
    return null;
}

const Cat = enum { other, cons, vowel, halant, nukta, matra, mod, zwj, zwnj };

fn catOf(cp: u32, base: u32) Cat {
    if (cp == 0x200D) return .zwj;
    if (cp == 0x200C) return .zwnj;
    if (cp < base or cp >= base + 0x80) return .other;
    const o = cp - base;
    if ((o >= 0x15 and o <= 0x39) or (o >= 0x58 and o <= 0x5F) or (o >= 0x78 and o <= 0x7F)) return .cons;
    if ((o >= 0x04 and o <= 0x14) or o == 0x60 or o == 0x61) return .vowel;
    if (o == 0x4D) return .halant;
    if (o == 0x3C) return .nukta;
    if ((o >= 0x3E and o <= 0x4C) or (o >= 0x55 and o <= 0x57) or o == 0x62 or o == 0x63) return .matra;
    if (o <= 0x03 or (o >= 0x51 and o <= 0x54)) return .mod;
    return .other;
}

const Syl = struct { start: usize, end: usize, base: ?usize, reph: bool };

fn isPre(cp: u32, sc: Script) bool {
    if (cp < sc.base) return false;
    const o = cp - sc.base;
    for (sc.pre) |p| if (p == o) return true;
    return false;
}

fn syllables(alloc: std.mem.Allocator, cps: []const u32, sc: Script, out: *std.ArrayList(Syl)) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < cps.len) {
        const start = i;
        var base: ?usize = null;
        var reph = false;
        const c0 = catOf(cps[i], sc.base);
        if (c0 == .cons) {
            if (cps[i] - sc.base == 0x30 and i + 2 < cps.len and catOf(cps[i + 1], sc.base) == .halant and catOf(cps[i + 2], sc.base) == .cons) reph = true;
            while (i < cps.len and catOf(cps[i], sc.base) == .cons) {
                base = i;
                i += 1;
                while (i < cps.len and catOf(cps[i], sc.base) == .nukta) i += 1;
                if (i < cps.len and catOf(cps[i], sc.base) == .halant) {
                    i += 1;
                    if (i < cps.len and (catOf(cps[i], sc.base) == .zwj or catOf(cps[i], sc.base) == .zwnj)) i += 1;
                    if (i < cps.len and catOf(cps[i], sc.base) == .cons) continue;
                }
                break;
            }
        } else if (c0 == .vowel) {
            i += 1;
        } else {
            i += 1;
            try out.append(alloc, .{ .start = start, .end = i, .base = null, .reph = false });
            continue;
        }
        while (i < cps.len and (catOf(cps[i], sc.base) == .nukta or catOf(cps[i], sc.base) == .matra)) i += 1;
        while (i < cps.len and catOf(cps[i], sc.base) == .mod) i += 1;
        try out.append(alloc, .{ .start = start, .end = i, .base = base, .reph = reph });
    }
}

const basic = [_]struct { tag: *const [4]u8, mask: u8 }{
    .{ .tag = "locl", .mask = 0xFF },
    .{ .tag = "ccmp", .mask = 0xFF },
    .{ .tag = "nukt", .mask = 0xFF },
    .{ .tag = "akhn", .mask = 0xFF },
    .{ .tag = "rphf", .mask = 16 },
    .{ .tag = "rkrf", .mask = 0xFF },
    .{ .tag = "pref", .mask = 64 },
    .{ .tag = "blwf", .mask = 64 },
    .{ .tag = "abvf", .mask = 64 },
    .{ .tag = "half", .mask = 32 },
    .{ .tag = "pstf", .mask = 64 },
    .{ .tag = "vatu", .mask = 64 },
    .{ .tag = "cjct", .mask = 0xFF },
};

const tag_reph: u8 = 1;
const tag_pre: u8 = 2;
const tag_base: u8 = 4;

pub fn run(alloc: std.mem.Allocator, gsub: ?shape.Gsub, sc: Script, cps: []const u32, out: *std.ArrayList(G)) shape.Error!void {
    var syls: std.ArrayList(Syl) = .empty;
    try syllables(alloc, cps, sc, &syls);
    const syl_of = try alloc.alloc(u32, cps.len);
    var ra_gids: std.ArrayList(u16) = .empty;
    for (syls.items, 0..) |sy, si| {
        for (sy.start..sy.end) |k| syl_of[k] = @intCast(si);
        const base = sy.base orelse continue;
        for (sy.start..sy.end) |k| {
            const g = &out.items[k];
            const cat = catOf(cps[k], sc.base);
            if (sy.reph and k < sy.start + 2) {
                g.form |= 16;
                g.tag |= tag_reph;
            } else if (k < base and (cat == .cons or cat == .halant or cat == .nukta)) {
                g.form |= 32;
            } else if (k > base and (cat == .cons or cat == .halant or cat == .nukta)) {
                g.form |= 64;
            }
            if (k == base) g.tag |= tag_base;
            if (cat == .matra and isPre(cps[k], sc)) g.tag |= tag_pre;
        }
        if (sy.reph) try ra_gids.append(alloc, out.items[sy.start].gid);
    }
    const gs = gsub orelse {
        reorder(out, syl_of, &.{});
        return;
    };
    for (basic) |f| {
        var reqs: std.ArrayList(shape.Req) = .empty;
        try gs.collect(&.{ sc.tags[0], sc.tags[1], "DFLT" }, &.{.{ .tag = f.tag, .mask = f.mask }}, &reqs, alloc);
        if (reqs.items.len > 0) try gs.apply(alloc, out, reqs.items);
    }
    reorder(out, syl_of, ra_gids.items);
    var reqs: std.ArrayList(shape.Req) = .empty;
    const rest = [_]shape.Feat{
        .{ .tag = "pres", .mask = 0xFF }, .{ .tag = "abvs", .mask = 0xFF }, .{ .tag = "blws", .mask = 0xFF }, .{ .tag = "psts", .mask = 0xFF },
        .{ .tag = "haln", .mask = 0xFF }, .{ .tag = "calt", .mask = 0xFF }, .{ .tag = "clig", .mask = 0xFF }, .{ .tag = "rlig", .mask = 0xFF },
    };
    try gs.collect(&.{ sc.tags[0], sc.tags[1], "DFLT" }, &rest, &reqs, alloc);
    if (reqs.items.len > 0) try gs.apply(alloc, out, reqs.items);
}

fn reorder(out: *std.ArrayList(G), syl_of: []const u32, ra_gids: []const u16) void {
    const items = out.items;
    var i: usize = 0;
    var ra_idx: usize = 0;
    while (i < items.len) {
        const sid = syl_of[@min(items[i].first, syl_of.len - 1)];
        var j = i + 1;
        while (j < items.len and syl_of[@min(items[j].first, syl_of.len - 1)] == sid) j += 1;
        const seg = items[i..j];
        var base_at: ?usize = null;
        var reph_count: usize = 0;
        for (seg, 0..) |g, k| {
            if (g.tag & tag_base != 0 and g.tag & tag_reph == 0) base_at = k;
            if (g.tag & tag_reph != 0) reph_count += 1;
        }
        if (reph_count > 0 and base_at != null) {
            const ra = if (ra_idx < ra_gids.len) ra_gids[ra_idx] else 0;
            ra_idx += 1;
            const formed = reph_count == 1 or seg[0].gid != ra;
            if (formed and seg[0].tag & tag_reph != 0) {
                var moved: usize = 0;
                while (moved < seg.len and seg[moved].tag & tag_reph != 0) moved += 1;
                const b = base_at.?;
                if (b >= moved) std.mem.rotate(G, seg[0 .. b + 1], moved);
            }
        } else if (reph_count > 0) ra_idx += 1;
        for (seg, 0..) |g, k| {
            if (g.tag & tag_pre != 0 and k > 0) {
                std.mem.rotate(G, seg[0 .. k + 1], k);
                break;
            }
        }
        i = j;
    }
}

test "syllable clustering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sc = scriptOf(0x0915).?;
    // ka + virama + ssa + i-matra, then ka
    const cps = [_]u32{ 0x0915, 0x094D, 0x0937, 0x093F, 0x0915 };
    var syls: std.ArrayList(Syl) = .empty;
    try syllables(arena.allocator(), &cps, sc, &syls);
    try std.testing.expectEqual(@as(usize, 2), syls.items.len);
    try std.testing.expectEqual(@as(usize, 4), syls.items[0].end);
    try std.testing.expectEqual(@as(?usize, 2), syls.items[0].base);
}

test "pre-base matra moves to the start of its syllable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sc = scriptOf(0x0915).?;
    const cps = [_]u32{ 0x0915, 0x093F };
    var out: std.ArrayList(G) = .empty;
    for (cps, 0..) |_, i| try out.append(a, .{ .gid = @intCast(i + 1), .first = @intCast(i), .last = @intCast(i) });
    try run(a, null, sc, &cps, &out);
    try std.testing.expectEqual(@as(u16, 2), out.items[0].gid);
    try std.testing.expectEqual(@as(u16, 1), out.items[1].gid);
}
