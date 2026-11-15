const std = @import("std");
const brotli = @import("svg_brotli.zig");
const flate = std.compress.flate;

pub const Error = error{ Invalid, TooBig, OutOfMemory };

const max_sfnt: usize = 48 << 20;

const known_tags = [63][4]u8{
    "cmap".*, "head".*, "hhea".*, "hmtx".*, "maxp".*, "name".*, "OS/2".*, "post".*, "cvt ".*, "fpgm".*,
    "glyf".*, "loca".*, "prep".*, "CFF ".*, "VORG".*, "EBDT".*, "EBLC".*, "gasp".*, "hdmx".*, "kern".*,
    "LTSH".*, "PCLT".*, "VDMX".*, "vhea".*, "vmtx".*, "BASE".*, "GDEF".*, "GPOS".*, "GSUB".*, "EBSC".*,
    "JSTF".*, "MATH".*, "CBDT".*, "CBLC".*, "COLR".*, "CPAL".*, "SVG ".*, "sbix".*, "acnt".*, "avar".*,
    "bdat".*, "bloc".*, "bsln".*, "cvar".*, "fdsc".*, "feat".*, "fmtx".*, "fvar".*, "gvar".*, "hsty".*,
    "just".*, "lcar".*, "mort".*, "morx".*, "opbd".*, "prop".*, "trak".*, "Zapf".*, "Silf".*, "Glat".*,
    "Gloc".*, "Feat".*, "Sill".*,
};

pub fn isWoff(b: []const u8) bool {
    return b.len >= 4 and (std.mem.eql(u8, b[0..4], "wOFF") or std.mem.eql(u8, b[0..4], "wOF2"));
}

pub fn toSfnt(alloc: std.mem.Allocator, b: []const u8) Error![]u8 {
    if (b.len < 4) return error.Invalid;
    if (std.mem.eql(u8, b[0..4], "wOFF")) return fromWoff(alloc, b);
    if (std.mem.eql(u8, b[0..4], "wOF2")) return fromWoff2(alloc, b);
    return error.Invalid;
}

fn be16(b: []const u8, o: usize) Error!u16 {
    if (o + 2 > b.len) return error.Invalid;
    return std.mem.readInt(u16, b[o..][0..2], .big);
}

fn be32(b: []const u8, o: usize) Error!u32 {
    if (o + 4 > b.len) return error.Invalid;
    return std.mem.readInt(u32, b[o..][0..4], .big);
}

const Table = struct { tag: [4]u8, data: []const u8 };

fn tagLess(_: void, a: Table, b: Table) bool {
    return std.mem.lessThan(u8, &a.tag, &b.tag);
}

fn checksum(d: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < d.len) : (i += 4) {
        var w = [4]u8{ 0, 0, 0, 0 };
        const n = @min(4, d.len - i);
        @memcpy(w[0..n], d[i..][0..n]);
        sum +%= std.mem.readInt(u32, &w, .big);
    }
    return sum;
}

fn assemble(alloc: std.mem.Allocator, flavor: u32, tabs: []Table) Error![]u8 {
    std.mem.sort(Table, tabs, {}, tagLess);
    const n = tabs.len;
    var size: usize = 12 + 16 * n;
    for (tabs) |t| size += (t.data.len + 3) & ~@as(usize, 3);
    if (size > max_sfnt) return error.TooBig;
    const out = try alloc.alloc(u8, size);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], flavor, .big);
    std.mem.writeInt(u16, out[4..6], @intCast(n), .big);
    var sel: u16 = 0;
    while ((@as(usize, 2) << @intCast(sel)) <= n) sel += 1;
    const search: u16 = @intCast((@as(usize, 1) << @intCast(sel)) * 16);
    std.mem.writeInt(u16, out[6..8], search, .big);
    std.mem.writeInt(u16, out[8..10], sel, .big);
    std.mem.writeInt(u16, out[10..12], @intCast(n * 16 - search), .big);
    var at: usize = 12 + 16 * n;
    for (tabs, 0..) |t, i| {
        const e = out[12 + i * 16 ..][0..16];
        @memcpy(e[0..4], &t.tag);
        std.mem.writeInt(u32, e[4..8], checksum(t.data), .big);
        std.mem.writeInt(u32, e[8..12], @intCast(at), .big);
        std.mem.writeInt(u32, e[12..16], @intCast(t.data.len), .big);
        @memcpy(out[at..][0..t.data.len], t.data);
        at += (t.data.len + 3) & ~@as(usize, 3);
    }
    return out;
}

fn inflate(alloc: std.mem.Allocator, src: []const u8, orig: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(src);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &window);
    const out = dec.reader.allocRemaining(alloc, .limited(orig + 1)) catch return error.Invalid;
    if (out.len != orig) return error.Invalid;
    return out;
}

fn fromWoff(alloc: std.mem.Allocator, b: []const u8) Error![]u8 {
    if (b.len < 44) return error.Invalid;
    const flavor = try be32(b, 4);
    const n = try be16(b, 12);
    if (n == 0) return error.Invalid;
    const tabs = try alloc.alloc(Table, n);
    var total: usize = 0;
    for (tabs, 0..) |*t, i| {
        const e = 44 + i * 20;
        if (e + 20 > b.len) return error.Invalid;
        const off = try be32(b, e + 4);
        const comp = try be32(b, e + 8);
        const orig = try be32(b, e + 12);
        if (@as(u64, off) + comp > b.len or comp > orig) return error.Invalid;
        total += orig;
        if (total > max_sfnt) return error.TooBig;
        const src = b[off..][0..comp];
        t.tag = b[e..][0..4].*;
        t.data = if (comp == orig) src else try inflate(alloc, src, orig);
    }
    return assemble(alloc, flavor, tabs);
}

fn base128(b: []const u8, pos: *usize) Error!u32 {
    var v: u32 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (pos.* >= b.len) return error.Invalid;
        const byte = b[pos.*];
        pos.* += 1;
        if (i == 0 and byte == 0x80) return error.Invalid;
        if (v > 0x01FFFFFF) return error.Invalid;
        v = (v << 7) | (byte & 0x7F);
        if (byte & 0x80 == 0) return v;
    }
    return error.Invalid;
}

const Entry = struct { tag: [4]u8, xform: bool, orig: u32, len: u32 };

fn eqTag(t: [4]u8, s: *const [4]u8) bool {
    return std.mem.eql(u8, &t, s);
}

fn fromWoff2(alloc: std.mem.Allocator, b: []const u8) Error![]u8 {
    if (b.len < 48) return error.Invalid;
    const flavor = try be32(b, 4);
    if (flavor == 0x74746366) return error.Invalid;
    const n = try be16(b, 12);
    if (n == 0) return error.Invalid;
    const comp_len = try be32(b, 20);
    var pos: usize = 48;
    const ents = try alloc.alloc(Entry, n);
    var total: usize = 0;
    for (ents) |*e| {
        if (pos >= b.len) return error.Invalid;
        const flags = b[pos];
        pos += 1;
        const idx = flags & 63;
        const version = flags >> 6;
        if (idx == 63) {
            if (pos + 4 > b.len) return error.Invalid;
            e.tag = b[pos..][0..4].*;
            pos += 4;
        } else {
            e.tag = known_tags[idx];
        }
        e.orig = try base128(b, &pos);
        const geo = eqTag(e.tag, "glyf") or eqTag(e.tag, "loca");
        e.xform = if (geo) version == 0 else version != 0;
        e.len = e.orig;
        if (e.xform) {
            e.len = try base128(b, &pos);
            if (eqTag(e.tag, "loca") and e.len != 0) return error.Invalid;
        }
        total += e.len;
        if (total > max_sfnt) return error.TooBig;
    }
    if (@as(u64, pos) + comp_len > b.len) return error.Invalid;
    const raw = brotli.decode(alloc, b[pos..][0..comp_len], total) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooBig => error.TooBig,
        else => error.Invalid,
    };
    if (raw.len < total) return error.Invalid;

    const tabs = try alloc.alloc(Table, n);
    var at: usize = 0;
    var glyf: ?Glyf = null;
    var hmtx_at: ?usize = null;
    var loca_at: ?usize = null;
    for (ents, 0..) |e, i| {
        const data = raw[at..][0..e.len];
        at += e.len;
        tabs[i] = .{ .tag = e.tag, .data = data };
        if (!e.xform) {
            if (e.len != e.orig) return error.Invalid;
            continue;
        }
        if (eqTag(e.tag, "glyf")) {
            const g = try reconstructGlyf(alloc, data);
            glyf = g;
            tabs[i].data = g.glyf;
        } else if (eqTag(e.tag, "loca")) {
            loca_at = i;
        } else if (eqTag(e.tag, "hmtx")) {
            hmtx_at = i;
        } else return error.Invalid;
    }
    if (loca_at) |i| tabs[i].data = (glyf orelse return error.Invalid).loca;
    if (hmtx_at) |i| {
        const g = glyf orelse return error.Invalid;
        var hhea: ?[]const u8 = null;
        for (tabs) |t| if (eqTag(t.tag, "hhea")) {
            hhea = t.data;
        };
        const nh = try be16(hhea orelse return error.Invalid, 34);
        tabs[i].data = try reconstructHmtx(alloc, tabs[i].data, nh, g.x_min);
    }
    return assemble(alloc, flavor, tabs);
}

const Cur = struct {
    b: []const u8,
    p: usize = 0,

    fn take(c: *Cur, n: usize) Error![]const u8 {
        if (c.p + n > c.b.len) return error.Invalid;
        const s = c.b[c.p..][0..n];
        c.p += n;
        return s;
    }

    fn u8_(c: *Cur) Error!u8 {
        return (try c.take(1))[0];
    }

    fn u16_(c: *Cur) Error!u16 {
        return std.mem.readInt(u16, (try c.take(2))[0..2], .big);
    }

    fn i16_(c: *Cur) Error!i16 {
        return @bitCast(try c.u16_());
    }

    fn uc255(c: *Cur) Error!u16 {
        const code = try c.u8_();
        return switch (code) {
            253 => try c.u16_(),
            254 => @as(u16, try c.u8_()) + 506,
            255 => @as(u16, try c.u8_()) + 253,
            else => code,
        };
    }
};

const Glyf = struct { glyf: []const u8, loca: []const u8, x_min: []const i16 };

fn withSign(flag: u8, v: i32) i32 {
    return if (flag & 1 != 0) v else -v;
}

fn put16(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) Error!void {
    var t = [2]u8{ 0, 0 };
    std.mem.writeInt(u16, &t, v, .big);
    try out.appendSlice(alloc, &t);
}

fn reconstructGlyf(alloc: std.mem.Allocator, src: []const u8) Error!Glyf {
    if (src.len < 36) return error.Invalid;
    const opt = try be16(src, 2);
    const ng = try be16(src, 4);
    const index_format = try be16(src, 6);
    var sizes = [7]usize{ 0, 0, 0, 0, 0, 0, 0 };
    var total: usize = 36;
    for (&sizes, 0..) |*s, i| {
        s.* = try be32(src, 8 + i * 4);
        total += s.*;
        if (total > src.len) return error.Invalid;
    }
    var cur: [7]Cur = @splat(.{ .b = &.{} });
    var o: usize = 36;
    for (&cur, 0..) |*c, i| {
        c.* = .{ .b = src[o..][0..sizes[i]] };
        o += sizes[i];
    }
    var ncont = cur[0];
    var npts = cur[1];
    var flagc = cur[2];
    var glyphc = cur[3];
    var compc = cur[4];
    var bboxc = cur[5];
    var instc = cur[6];
    const overlap: []const u8 = if (opt & 1 != 0) src[o..] else &.{};
    const bm_len = ((@as(usize, ng) + 31) / 32) * 4;
    const bbox_bits = try bboxc.take(bm_len);

    var glyf: std.ArrayList(u8) = .empty;
    var loca: std.ArrayList(u8) = .empty;
    const x_min = try alloc.alloc(i16, ng);
    @memset(x_min, 0);
    const align_to: usize = if (index_format == 0) 2 else 4;
    var xs: std.ArrayList(i32) = .empty;
    var ys: std.ArrayList(i32) = .empty;
    var on: std.ArrayList(bool) = .empty;
    var ends: std.ArrayList(u16) = .empty;

    var g: usize = 0;
    while (g <= ng) : (g += 1) {
        if (index_format == 0) try put16(&loca, alloc, @intCast(glyf.items.len / 2)) else {
            var t = [4]u8{ 0, 0, 0, 0 };
            std.mem.writeInt(u32, &t, @intCast(glyf.items.len), .big);
            try loca.appendSlice(alloc, &t);
        }
        if (g == ng) break;
        if (glyf.items.len > max_sfnt) return error.TooBig;
        const nc = try ncont.i16_();
        if (nc == 0) continue;
        const has_bbox = bbox_bits[g >> 3] & (@as(u8, 0x80) >> @intCast(g & 7)) != 0;
        var bb = [4]i16{ 0, 0, 0, 0 };
        if (nc > 0) {
            xs.clearRetainingCapacity();
            ys.clearRetainingCapacity();
            on.clearRetainingCapacity();
            ends.clearRetainingCapacity();
            var pts: usize = 0;
            var c: i16 = 0;
            while (c < nc) : (c += 1) {
                const np = try npts.uc255();
                if (np == 0) return error.Invalid;
                pts += np;
                if (pts > 0xFFFF) return error.Invalid;
                try ends.append(alloc, @intCast(pts - 1));
            }
            const flags = try flagc.take(pts);
            var x: i32 = 0;
            var y: i32 = 0;
            for (flags) |f| {
                const k = f & 0x7F;
                const nb: usize = if (k < 10) 1 else if (k < 20) 1 else if (k < 84) 1 else if (k < 120) 2 else if (k < 124) 3 else 4;
                const d = try glyphc.take(nb);
                var dx: i32 = 0;
                var dy: i32 = 0;
                if (k < 10) {
                    dy = withSign(k, ((@as(i32, k) & 14) << 7) + d[0]);
                } else if (k < 20) {
                    dx = withSign(k, (((@as(i32, k) - 10) & 14) << 7) + d[0]);
                } else if (k < 84) {
                    const b0: i32 = @as(i32, k) - 20;
                    const b1: i32 = d[0];
                    dx = withSign(k, 1 + (b0 & 0x30) + (b1 >> 4));
                    dy = withSign(k >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f));
                } else if (k < 120) {
                    const b0: i32 = @as(i32, k) - 84;
                    dx = withSign(k, 1 + (@divTrunc(b0, 12) << 8) + d[0]);
                    dy = withSign(k >> 1, 1 + ((@rem(b0, 12) >> 2) << 8) + d[1]);
                } else if (k < 124) {
                    const b2: i32 = d[1];
                    dx = withSign(k, (@as(i32, d[0]) << 4) + (b2 >> 4));
                    dy = withSign(k >> 1, ((b2 & 0x0f) << 8) + d[2]);
                } else {
                    dx = withSign(k, (@as(i32, d[0]) << 8) + d[1]);
                    dy = withSign(k >> 1, (@as(i32, d[2]) << 8) + d[3]);
                }
                x += dx;
                y += dy;
                try xs.append(alloc, x);
                try ys.append(alloc, y);
                try on.append(alloc, f >> 7 == 0);
            }
            const ilen = try glyphc.uc255();
            const instr = try instc.take(ilen);
            if (has_bbox) {
                for (&bb) |*v| v.* = try bboxc.i16_();
            } else {
                var lo_x: i32 = std.math.maxInt(i32);
                var lo_y: i32 = std.math.maxInt(i32);
                var hi_x: i32 = std.math.minInt(i32);
                var hi_y: i32 = std.math.minInt(i32);
                for (xs.items, ys.items) |px, py| {
                    lo_x = @min(lo_x, px);
                    hi_x = @max(hi_x, px);
                    lo_y = @min(lo_y, py);
                    hi_y = @max(hi_y, py);
                }
                bb = .{ clamp16(lo_x), clamp16(lo_y), clamp16(hi_x), clamp16(hi_y) };
            }
            try put16(&glyf, alloc, @bitCast(nc));
            for (bb) |v| try put16(&glyf, alloc, @bitCast(v));
            for (ends.items) |e| try put16(&glyf, alloc, e);
            try put16(&glyf, alloc, ilen);
            try glyf.appendSlice(alloc, instr);
            const ov = overlap.len > (g >> 3) and overlap[g >> 3] & (@as(u8, 0x80) >> @intCast(g & 7)) != 0;
            var px: i32 = 0;
            var py: i32 = 0;
            for (xs.items, ys.items, on.items, 0..) |cx, cy, oc, i| {
                var f: u8 = if (oc) 1 else 0;
                if (i == 0 and ov) f |= 0x40;
                const dx = cx - px;
                const dy = cy - py;
                if (dx == 0) f |= 0x10 else if (@abs(dx) < 256) f |= 0x02 | (if (dx > 0) @as(u8, 0x10) else 0);
                if (dy == 0) f |= 0x20 else if (@abs(dy) < 256) f |= 0x04 | (if (dy > 0) @as(u8, 0x20) else 0);
                try glyf.append(alloc, f);
                px = cx;
                py = cy;
            }
            px = 0;
            for (xs.items) |cx| {
                const dx = cx - px;
                px = cx;
                if (dx == 0) continue;
                if (@abs(dx) < 256) try glyf.append(alloc, @intCast(@abs(dx))) else try put16(&glyf, alloc, @bitCast(@as(i16, @intCast(dx))));
            }
            py = 0;
            for (ys.items) |cy| {
                const dy = cy - py;
                py = cy;
                if (dy == 0) continue;
                if (@abs(dy) < 256) try glyf.append(alloc, @intCast(@abs(dy))) else try put16(&glyf, alloc, @bitCast(@as(i16, @intCast(dy))));
            }
        } else {
            const start = compc.p;
            var have_instr = false;
            while (true) {
                const f = try compc.u16_();
                _ = try compc.u16_();
                _ = try compc.take(if (f & 1 != 0) 4 else 2);
                if (f & 0x0008 != 0) _ = try compc.take(2) else if (f & 0x0040 != 0) _ = try compc.take(4) else if (f & 0x0080 != 0) _ = try compc.take(8);
                if (f & 0x0100 != 0) have_instr = true;
                if (f & 0x0020 == 0) break;
            }
            if (!has_bbox) return error.Invalid;
            for (&bb) |*v| v.* = try bboxc.i16_();
            try put16(&glyf, alloc, 0xFFFF);
            for (bb) |v| try put16(&glyf, alloc, @bitCast(v));
            try glyf.appendSlice(alloc, compc.b[start..compc.p]);
            if (have_instr) {
                const ilen = try glyphc.uc255();
                try put16(&glyf, alloc, ilen);
                try glyf.appendSlice(alloc, try instc.take(ilen));
            }
        }
        x_min[g] = bb[0];
        while (glyf.items.len % align_to != 0) try glyf.append(alloc, 0);
    }
    return .{ .glyf = glyf.items, .loca = loca.items, .x_min = x_min };
}

fn clamp16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn reconstructHmtx(alloc: std.mem.Allocator, src: []const u8, num_h: u16, x_min: []const i16) Error![]const u8 {
    if (src.len < 1) return error.Invalid;
    const flags = src[0];
    var c = Cur{ .b = src, .p = 1 };
    const ng = x_min.len;
    if (num_h == 0 or num_h > ng) return error.Invalid;
    const adv = try c.take(@as(usize, num_h) * 2);
    const lsb1: []const u8 = if (flags & 1 == 0) try c.take(@as(usize, num_h) * 2) else &.{};
    const lsb2: []const u8 = if (flags & 2 == 0) try c.take((ng - num_h) * 2) else &.{};
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < ng) : (i += 1) {
        if (i < num_h) try out.appendSlice(alloc, adv[i * 2 ..][0..2]);
        if (i < num_h) {
            if (flags & 1 == 0) try out.appendSlice(alloc, lsb1[i * 2 ..][0..2]) else try put16(&out, alloc, @bitCast(x_min[i]));
        } else {
            if (flags & 2 == 0) try out.appendSlice(alloc, lsb2[(i - num_h) * 2 ..][0..2]) else try put16(&out, alloc, @bitCast(x_min[i]));
        }
    }
    return out.items;
}
