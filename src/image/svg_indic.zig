const std = @import("std");
const shape = @import("svg_shape.zig");
const font = @import("font");

const G = shape.G;

pub const Kind = enum { indic, khmer, myanmar, tibetan, balinese, javanese, sundanese, sinhala };

pub const Script = struct {
    tags: [2]*const [4]u8,
    kind: Kind,
    lo: u32,
    hi: u32,
    pre: []const u32,
    ra: u32 = 0,
    reph_len: u8 = 0,
    base_first: bool = false,
};

const Split = struct { cp: u32, parts: [3]u32, always: bool = false };

const splits = [_]Split{
    .{ .cp = 0x09CB, .parts = .{ 0x09C7, 0x09BE, 0 } },
    .{ .cp = 0x09CC, .parts = .{ 0x09C7, 0x09D7, 0 } },
    .{ .cp = 0x0B4B, .parts = .{ 0x0B47, 0x0B3E, 0 } },
    .{ .cp = 0x0B4C, .parts = .{ 0x0B47, 0x0B57, 0 } },
    .{ .cp = 0x0BCA, .parts = .{ 0x0BC6, 0x0BBE, 0 } },
    .{ .cp = 0x0BCB, .parts = .{ 0x0BC7, 0x0BBE, 0 } },
    .{ .cp = 0x0BCC, .parts = .{ 0x0BC6, 0x0BD7, 0 } },
    .{ .cp = 0x0C48, .parts = .{ 0x0C46, 0x0C56, 0 } },
    .{ .cp = 0x0CC0, .parts = .{ 0x0CBF, 0x0CD5, 0 } },
    .{ .cp = 0x0CC7, .parts = .{ 0x0CC6, 0x0CD5, 0 } },
    .{ .cp = 0x0CC8, .parts = .{ 0x0CC6, 0x0CD6, 0 } },
    .{ .cp = 0x0CCA, .parts = .{ 0x0CC6, 0x0CC2, 0 } },
    .{ .cp = 0x0CCB, .parts = .{ 0x0CC6, 0x0CC2, 0x0CD5 } },
    .{ .cp = 0x0D4A, .parts = .{ 0x0D46, 0x0D3E, 0 } },
    .{ .cp = 0x0D4B, .parts = .{ 0x0D47, 0x0D3E, 0 } },
    .{ .cp = 0x0D4C, .parts = .{ 0x0D46, 0x0D57, 0 } },
    .{ .cp = 0x0DDA, .parts = .{ 0x0DD9, 0x0DCA, 0 } },
    .{ .cp = 0x0DDC, .parts = .{ 0x0DD9, 0x0DCF, 0 } },
    .{ .cp = 0x0DDD, .parts = .{ 0x0DD9, 0x0DCF, 0x0DCA } },
    .{ .cp = 0x0DDE, .parts = .{ 0x0DD9, 0x0DDF, 0 } },
    .{ .cp = 0x17BE, .parts = .{ 0x17C1, 0x17BE, 0 }, .always = true },
    .{ .cp = 0x17BF, .parts = .{ 0x17C1, 0x17BF, 0 }, .always = true },
    .{ .cp = 0x17C0, .parts = .{ 0x17C1, 0x17C0, 0 }, .always = true },
    .{ .cp = 0x17C4, .parts = .{ 0x17C1, 0x17C4, 0 }, .always = true },
    .{ .cp = 0x17C5, .parts = .{ 0x17C1, 0x17C5, 0 }, .always = true },
    .{ .cp = 0x1B3B, .parts = .{ 0x1B3A, 0x1B35, 0 } },
    .{ .cp = 0x1B3D, .parts = .{ 0x1B3C, 0x1B35, 0 } },
    .{ .cp = 0x1B40, .parts = .{ 0x1B3E, 0x1B35, 0 } },
    .{ .cp = 0x1B41, .parts = .{ 0x1B3F, 0x1B35, 0 } },
    .{ .cp = 0x1B43, .parts = .{ 0x1B42, 0x1B35, 0 } },
    .{ .cp = 0x0F73, .parts = .{ 0x0F71, 0x0F72, 0 } },
    .{ .cp = 0x0F75, .parts = .{ 0x0F71, 0x0F74, 0 } },
    .{ .cp = 0x0F81, .parts = .{ 0x0F71, 0x0F80, 0 } },
};

fn brahmic(tags: [2]*const [4]u8, base: u32, pre: []const u32) Script {
    return .{ .tags = tags, .kind = .indic, .lo = base, .hi = base + 0x7F, .pre = pre, .ra = base + 0x30, .reph_len = 2 };
}

const blocks = [_]Script{
    brahmic(.{ "dev2", "deva" }, 0x0900, &.{0x093F}),
    brahmic(.{ "bng2", "beng" }, 0x0980, &.{ 0x09BF, 0x09C7, 0x09C8 }),
    brahmic(.{ "gur2", "guru" }, 0x0A00, &.{0x0A3F}),
    brahmic(.{ "gjr2", "gujr" }, 0x0A80, &.{0x0ABF}),
    brahmic(.{ "ory2", "orya" }, 0x0B00, &.{0x0B47}),
    brahmic(.{ "tml2", "taml" }, 0x0B80, &.{ 0x0BC6, 0x0BC7, 0x0BC8 }),
    brahmic(.{ "tel2", "telu" }, 0x0C00, &.{}),
    brahmic(.{ "knd2", "knda" }, 0x0C80, &.{}),
    brahmic(.{ "mlm2", "mlym" }, 0x0D00, &.{ 0x0D46, 0x0D47, 0x0D48 }),
    .{ .tags = .{ "sinh", "sinh" }, .kind = .sinhala, .lo = 0x0D80, .hi = 0x0DFF, .pre = &.{ 0x0DD9, 0x0DDA, 0x0DDB }, .ra = 0x0DBB, .reph_len = 3 },
    .{ .tags = .{ "khmr", "khmr" }, .kind = .khmer, .lo = 0x1780, .hi = 0x17FF, .pre = &.{ 0x17C1, 0x17C2, 0x17C3 }, .base_first = true },
    .{ .tags = .{ "mym2", "mymr" }, .kind = .myanmar, .lo = 0x1000, .hi = 0x109F, .pre = &.{0x1031}, .base_first = true },
    .{ .tags = .{ "mym2", "mymr" }, .kind = .myanmar, .lo = 0xA9E0, .hi = 0xA9FF, .pre = &.{0x1031}, .base_first = true },
    .{ .tags = .{ "tibt", "tibt" }, .kind = .tibetan, .lo = 0x0F00, .hi = 0x0FFF, .pre = &.{}, .base_first = true },
    .{ .tags = .{ "bali", "bali" }, .kind = .balinese, .lo = 0x1B00, .hi = 0x1B7F, .pre = &.{ 0x1B3E, 0x1B3F }, .base_first = true },
    .{ .tags = .{ "sund", "sund" }, .kind = .sundanese, .lo = 0x1B80, .hi = 0x1BBF, .pre = &.{}, .base_first = true },
    .{ .tags = .{ "java", "java" }, .kind = .javanese, .lo = 0xA980, .hi = 0xA9DF, .pre = &.{ 0xA9BA, 0xA9BB }, .base_first = true },
};

pub fn scriptOf(cp: u32) ?Script {
    for (blocks) |b| if (cp >= b.lo and cp <= b.hi) return b;
    return null;
}

const Cat = enum { other, cons, vowel, halant, nukta, matra, mod, zwj, zwnj };

fn within(cp: u32, lo: u32, hi: u32) bool {
    return cp >= lo and cp <= hi;
}

fn catOf(cp: u32, sc: Script) Cat {
    if (cp == 0x200D) return .zwj;
    if (cp == 0x200C) return .zwnj;
    if (cp < sc.lo or cp > sc.hi) return .other;
    switch (sc.kind) {
        .indic => {
            const o = cp - sc.lo;
            if ((o >= 0x15 and o <= 0x39) or (o >= 0x58 and o <= 0x5F) or (o >= 0x78 and o <= 0x7F)) return .cons;
            if ((o >= 0x04 and o <= 0x14) or o == 0x60 or o == 0x61) return .vowel;
            if (o == 0x4D) return .halant;
            if (o == 0x3C) return .nukta;
            if ((o >= 0x3E and o <= 0x4C) or (o >= 0x55 and o <= 0x57) or o == 0x62 or o == 0x63) return .matra;
            if (o <= 0x03 or (o >= 0x51 and o <= 0x54)) return .mod;
        },
        .sinhala => {
            if (within(cp, 0x0D9A, 0x0DC6)) return .cons;
            if (within(cp, 0x0D85, 0x0D96)) return .vowel;
            if (cp == 0x0DCA) return .halant;
            if (within(cp, 0x0DCF, 0x0DDF) or within(cp, 0x0DF2, 0x0DF3)) return .matra;
            if (within(cp, 0x0D81, 0x0D83)) return .mod;
        },
        .khmer => {
            if (within(cp, 0x1780, 0x17A2)) return .cons;
            if (within(cp, 0x17A3, 0x17B3)) return .vowel;
            if (cp == 0x17D2) return .halant;
            if (within(cp, 0x17B4, 0x17C5)) return .matra;
            if (within(cp, 0x17C6, 0x17D1) or cp == 0x17D3 or cp == 0x17DD) return .mod;
        },
        .myanmar => {
            if (within(cp, 0x1000, 0x1020) or cp == 0x103F or within(cp, 0x1050, 0x1051) or within(cp, 0x105A, 0x105D) or cp == 0x1061 or within(cp, 0x1065, 0x1066) or within(cp, 0x106E, 0x1070) or within(cp, 0x1075, 0x1081) or cp == 0x108E) return .cons;
            if (within(cp, 0x1021, 0x102A) or within(cp, 0x1052, 0x1055)) return .vowel;
            if (cp == 0x1039) return .halant;
            if ((within(cp, 0x102B, 0x1035)) or within(cp, 0x103B, 0x103E) or within(cp, 0x1056, 0x1059) or within(cp, 0x1062, 0x1064) or within(cp, 0x1067, 0x106D) or within(cp, 0x1071, 0x1074) or within(cp, 0x1082, 0x108D)) return .matra;
            if (cp == 0x1036 or cp == 0x1037 or cp == 0x1038 or cp == 0x103A or cp == 0x108F or within(cp, 0x109A, 0x109D)) return .mod;
        },
        .tibetan => {
            if (within(cp, 0x0F40, 0x0F47) or within(cp, 0x0F49, 0x0F6C) or within(cp, 0x0F88, 0x0F8C)) return .cons;
            if (cp == 0x0F00) return .vowel;
            if (within(cp, 0x0F71, 0x0F7D) or within(cp, 0x0F80, 0x0F81) or within(cp, 0x0F90, 0x0FBC)) return .matra;
            if (cp == 0x0F7E or cp == 0x0F7F or within(cp, 0x0F82, 0x0F84) or cp == 0x0F35 or cp == 0x0F37 or cp == 0x0F39) return .mod;
        },
        .balinese => {
            if (within(cp, 0x1B13, 0x1B33)) return .cons;
            if (within(cp, 0x1B05, 0x1B12) or within(cp, 0x1B45, 0x1B4C)) return .vowel;
            if (cp == 0x1B44) return .halant;
            if (cp == 0x1B34) return .nukta;
            if (within(cp, 0x1B35, 0x1B43)) return .matra;
            if (within(cp, 0x1B00, 0x1B04)) return .mod;
        },
        .javanese => {
            if (within(cp, 0xA98F, 0xA9B2)) return .cons;
            if (within(cp, 0xA984, 0xA98E)) return .vowel;
            if (cp == 0xA9C0) return .halant;
            if (cp == 0xA9B3) return .nukta;
            if (within(cp, 0xA9B4, 0xA9BF)) return .matra;
            if (within(cp, 0xA980, 0xA983)) return .mod;
        },
        .sundanese => {
            if (within(cp, 0x1B8A, 0x1BA0) or within(cp, 0x1BAE, 0x1BAF)) return .cons;
            if (within(cp, 0x1B83, 0x1B89)) return .vowel;
            if (cp == 0x1BAA or cp == 0x1BAB) return .halant;
            if (within(cp, 0x1BA1, 0x1BA9)) return .matra;
            if (within(cp, 0x1B80, 0x1B82)) return .mod;
        },
    }
    return .other;
}

const Syl = struct { start: usize, end: usize, base: ?usize, reph: bool };

fn isPre(cp: u32, sc: Script) bool {
    return std.mem.indexOfScalar(u32, sc.pre, cp) != null;
}

fn syllables(alloc: std.mem.Allocator, cps: []const u32, sc: Script, out: *std.ArrayList(Syl)) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < cps.len) {
        const start = i;
        var base: ?usize = null;
        var reph = false;
        const c0 = catOf(cps[i], sc);
        if (c0 == .cons) {
            if (sc.reph_len > 0 and cps[i] == sc.ra and i + sc.reph_len < cps.len and catOf(cps[i + 1], sc) == .halant and (sc.reph_len == 2 or cps[i + 2] == 0x200D) and catOf(cps[i + sc.reph_len], sc) == .cons) reph = true;
            while (i < cps.len and catOf(cps[i], sc) == .cons) {
                if (base == null or !sc.base_first) base = i;
                i += 1;
                while (i < cps.len and catOf(cps[i], sc) == .nukta) i += 1;
                if (i < cps.len and catOf(cps[i], sc) == .halant) {
                    i += 1;
                    if (i < cps.len and (catOf(cps[i], sc) == .zwj or catOf(cps[i], sc) == .zwnj)) i += 1;
                    if (i < cps.len and catOf(cps[i], sc) == .cons) continue;
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
        while (i < cps.len) {
            const c = catOf(cps[i], sc);
            if (c != .nukta and c != .matra and c != .mod and !(c == .halant and (i + 1 >= cps.len or catOf(cps[i + 1], sc) != .cons))) break;
            i += 1;
        }
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
    .{ .tag = "init", .mask = 128 },
};

const tag_reph: u8 = 1;
const tag_pre: u8 = 2;
const tag_base: u8 = 4;

const Split2 = struct { cps: []const u32, origin: []const u32 };

fn decompose(alloc: std.mem.Allocator, face: ?*const font.Font, cps_in: []const u32, out: *std.ArrayList(G)) shape.Error!Split2 {
    var any = false;
    for (cps_in) |cp| for (splits) |sp| if (sp.cp == cp) {
        any = true;
    };
    var origin: std.ArrayList(u32) = .empty;
    if (!any) {
        for (0..cps_in.len) |i| try origin.append(alloc, @intCast(i));
        return .{ .cps = cps_in, .origin = origin.items };
    }
    var cps: std.ArrayList(u32) = .empty;
    var glyphs: std.ArrayList(G) = .empty;
    for (cps_in, out.items, 0..) |cp, g, oi| {
        var done = false;
        for (splits) |sp| {
            if (sp.cp != cp) continue;
            const f = face orelse break;
            if (!sp.always and g.gid != 0) break;
            var ok = true;
            for (sp.parts) |q| if (q != 0 and f.glyphIndex(q) == 0) {
                ok = false;
            };
            if (!ok) break;
            for (sp.parts) |q| {
                if (q == 0) continue;
                var ng = g;
                ng.gid = f.glyphIndex(q);
                try glyphs.append(alloc, ng);
                try cps.append(alloc, q);
                try origin.append(alloc, @intCast(oi));
            }
            done = true;
            break;
        }
        if (!done) {
            try glyphs.append(alloc, g);
            try cps.append(alloc, cp);
            try origin.append(alloc, @intCast(oi));
        }
    }
    out.* = glyphs;
    return .{ .cps = cps.items, .origin = origin.items };
}

pub fn run(alloc: std.mem.Allocator, face: ?*const font.Font, gsub: ?shape.Gsub, sc: Script, cps_in: []const u32, out: *std.ArrayList(G)) shape.Error!void {
    const dec = try decompose(alloc, face, cps_in, out);
    const cps = dec.cps;
    var syls: std.ArrayList(Syl) = .empty;
    try syllables(alloc, cps, sc, &syls);
    const syl_of = try alloc.alloc(u32, cps_in.len);
    @memset(syl_of, 0);
    var ra_gids: std.ArrayList(u16) = .empty;
    for (syls.items, 0..) |sy, si| {
        for (sy.start..sy.end) |k| syl_of[dec.origin[k]] = @intCast(si);
        if (sy.start == 0 or cps[sy.start - 1] == 0x20 or cps[sy.start - 1] == 0xA0) {
            for (sy.start..sy.end) |k| out.items[k].form |= 128;
        }
        const base = sy.base orelse continue;
        for (sy.start..sy.end) |k| {
            const g = &out.items[k];
            const cat = catOf(cps[k], sc);
            if (sy.reph and k < sy.start + sc.reph_len) {
                g.form |= 16;
                g.tag |= tag_reph;
            } else if (k < base and (cat == .cons or cat == .halant or cat == .nukta)) {
                g.form |= 32;
            } else if (k > base and (cat == .cons or cat == .halant or cat == .nukta)) {
                g.form |= 64;
            }
            if (k == base) g.tag |= tag_base;
            if (cat == .matra and isPre(cps[k], sc)) g.tag |= tag_pre;
            if (sc.kind == .khmer and cat == .halant and k > base and k + 1 < sy.end and cps[k + 1] == 0x179A) g.tag |= tag_pre;
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
        .{ .tag = "haln", .mask = 0xFF }, .{ .tag = "rclt", .mask = 0xFF }, .{ .tag = "calt", .mask = 0xFF }, .{ .tag = "clig", .mask = 0xFF },
        .{ .tag = "rlig", .mask = 0xFF }, .{ .tag = "liga", .mask = 0xFF },
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
        for (0..seg.len) |k| {
            if (seg[k].tag & tag_pre != 0 and k > 0) std.mem.rotate(G, seg[0 .. k + 1], k);
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
    try run(a, null, null, sc, &cps, &out);
    try std.testing.expectEqual(@as(u16, 2), out.items[0].gid);
    try std.testing.expectEqual(@as(u16, 1), out.items[1].gid);
}

test "Khmer and Myanmar clusters keep the first consonant as base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kh = scriptOf(0x1780).?;
    const khmer = [_]u32{ 0x1780, 0x17D2, 0x179A, 0x17C1, 0x1781 };
    var syls: std.ArrayList(Syl) = .empty;
    try syllables(a, &khmer, kh, &syls);
    try std.testing.expectEqual(@as(usize, 2), syls.items.len);
    try std.testing.expectEqual(@as(usize, 4), syls.items[0].end);
    try std.testing.expectEqual(@as(?usize, 0), syls.items[0].base);
    const my = scriptOf(0x1019).?;
    const burmese = [_]u32{ 0x1019, 0x103C, 0x1014, 0x103A };
    var s2: std.ArrayList(Syl) = .empty;
    try syllables(a, &burmese, my, &s2);
    try std.testing.expectEqual(@as(usize, 2), s2.items.len);
    try std.testing.expectEqual(@as(usize, 2), s2.items[0].end);
}

test "Khmer pre-base vowel and coeng ro move to the front" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kh = scriptOf(0x1780).?;
    const cps = [_]u32{ 0x1780, 0x17D2, 0x179A, 0x17C1 };
    var out: std.ArrayList(G) = .empty;
    for (cps, 0..) |_, i| try out.append(a, .{ .gid = @intCast(i + 1), .first = @intCast(i), .last = @intCast(i) });
    try run(a, null, null, kh, &cps, &out);
    try std.testing.expectEqual(@as(u16, 4), out.items[0].gid);
    try std.testing.expectEqual(@as(u16, 2), out.items[1].gid);
    try std.testing.expectEqual(@as(u16, 1), out.items[2].gid);
}
