const std = @import("std");
const path_mod = @import("path.zig");

pub const Path = path_mod.Path;
pub const Mat = path_mod.Mat;
pub const Pt = path_mod.Pt;

const read = @import("read.zig");
const cff_mod = @import("cff.zig");
const math_mod = @import("math.zig");

pub const math = math_mod;

pub const Error = read.Error;
const u16At = read.u16At;
const i16At = read.i16At;
const u32At = read.u32At;

fn findTable(d: []const u8, dir: usize, tag: *const [4]u8) Error!?usize {
    const n = try u16At(d, dir + 4);
    for (0..n) |i| {
        const rec = dir + 12 + i * 16;
        if (rec + 16 > d.len) return error.Corrupt;
        if (!std.mem.eql(u8, d[rec..][0..4], tag)) continue;
        const off: usize = try u32At(d, rec + 8);
        if (off >= d.len) return error.Corrupt;
        return off;
    }
    return null;
}

fn needTable(d: []const u8, dir: usize, tag: *const [4]u8) Error!usize {
    return (try findTable(d, dir, tag)) orelse error.Corrupt;
}

pub fn faceCount(d: []const u8) u32 {
    if (d.len < 16 or !std.mem.eql(u8, d[0..4], "ttcf")) return 1;
    return @min(u32At(d, 8) catch 1, 256);
}

pub const oblique_skew = 0.25;

pub const Decoded = struct { cp: u32, len: usize };

pub fn decodeAt(text: []const u8, i: usize) Decoded {
    if (std.unicode.utf8ByteSequenceLength(text[i])) |n| {
        if (i + n <= text.len) {
            if (std.unicode.utf8Decode(text[i..][0..n])) |c| return .{ .cp = c, .len = n } else |_| {}
        }
    } else |_| {}
    return .{ .cp = 0xFFFD, .len = 1 };
}

pub fn isZeroWidth(cp: u32) bool {
    return cp < 0x20 or cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF;
}
const max_kern_lookups = 48;

pub const Font = struct {
    data: []const u8,
    upem: u16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    num_glyphs: u16,
    num_hmetrics: u16,
    long_loca: bool,
    loca: usize,
    glyf: usize,
    hmtx: usize,
    cmap: usize,
    cmap_format: u16,
    name: usize,
    kern_table: usize,
    gpos_lookups: usize,
    kern_lookups: [max_kern_lookups]u16,
    kern_count: usize,
    cff: ?cff_mod.Cff = null,
    math: ?math_mod.Math = null,
    oblique: bool = false,

    pub fn init(d: []const u8, face: u32) Error!Font {
        var dir: usize = 0;
        if (d.len < 12) return error.Corrupt;
        if (std.mem.eql(u8, d[0..4], "ttcf")) {
            if (face >= try u32At(d, 8)) return error.Corrupt;
            dir = try u32At(d, 12 + @as(usize, face) * 4);
        } else if (face != 0) {
            return error.Corrupt;
        } else if (!std.mem.eql(u8, d[0..4], &.{ 0, 1, 0, 0 }) and !std.mem.eql(u8, d[0..4], "true") and !std.mem.eql(u8, d[0..4], "OTTO")) {
            return error.Corrupt;
        }
        const head = try needTable(d, dir, "head");
        const hhea = try needTable(d, dir, "hhea");
        const maxp = try needTable(d, dir, "maxp");
        const cmap_t = try needTable(d, dir, "cmap");
        const upem = try u16At(d, head + 18);
        if (upem < 16 or upem > 16384) return error.Corrupt;
        var f: Font = .{
            .data = d,
            .upem = upem,
            .ascent = try i16At(d, hhea + 4),
            .descent = try i16At(d, hhea + 6),
            .line_gap = try i16At(d, hhea + 8),
            .num_glyphs = try u16At(d, maxp + 4),
            .num_hmetrics = try u16At(d, hhea + 34),
            .long_loca = try i16At(d, head + 50) != 0,
            .loca = (try findTable(d, dir, "loca")) orelse 0,
            .glyf = (try findTable(d, dir, "glyf")) orelse 0,
            .hmtx = try needTable(d, dir, "hmtx"),
            .cmap = 0,
            .cmap_format = 0,
            .name = (try findTable(d, dir, "name")) orelse 0,
            .kern_table = (try findTable(d, dir, "kern")) orelse 0,
            .gpos_lookups = 0,
            .kern_lookups = @splat(0),
            .kern_count = 0,
        };
        if (f.num_hmetrics == 0) return error.Corrupt;
        try f.pickCmap(cmap_t);
        if (try findTable(d, dir, "CFF ")) |c| {
            f.cff = try cff_mod.Cff.init(d, c);
        } else if (f.glyf == 0 or f.loca == 0) return error.Unsupported;
        if (try findTable(d, dir, "MATH")) |mt| f.math = math_mod.Math.parse(d, mt) catch null;
        if (try findTable(d, dir, "GPOS")) |gpos| f.findKernLookups(gpos) catch {
            f.kern_count = 0;
        };
        return f;
    }

    fn pickCmap(f: *Font, cmap_t: usize) Error!void {
        const d = f.data;
        const ntab = try u16At(d, cmap_t + 2);
        var rank: u8 = 0;
        for (0..ntab) |i| {
            const rec = cmap_t + 4 + i * 8;
            const pid = try u16At(d, rec);
            const eid = try u16At(d, rec + 2);
            const off = cmap_t + try u32At(d, rec + 4);
            const fmt = u16At(d, off) catch continue;
            const r: u8 = switch (fmt) {
                12 => if (pid == 3 and eid == 10) 4 else if (pid == 0) 3 else 0,
                4 => if (pid == 3 and eid == 1) 2 else if (pid == 0) 1 else 0,
                else => 0,
            };
            if (r > rank) {
                rank = r;
                f.cmap = off;
                f.cmap_format = fmt;
            }
        }
        if (rank == 0) return error.Unsupported;
    }

    fn findKernLookups(f: *Font, gpos: usize) Error!void {
        const d = f.data;
        const fl = gpos + try u16At(d, gpos + 6);
        f.gpos_lookups = gpos + try u16At(d, gpos + 8);
        const nf = try u16At(d, fl);
        for (0..nf) |i| {
            const rec = fl + 2 + i * 6;
            if (rec + 6 > d.len) return error.Corrupt;
            if (!std.mem.eql(u8, d[rec..][0..4], "kern")) continue;
            const ft = fl + try u16At(d, rec + 4);
            const nl = try u16At(d, ft + 2);
            for (0..nl) |k| {
                const idx = try u16At(d, ft + 4 + k * 2);
                if (std.mem.indexOfScalar(u16, f.kern_lookups[0..f.kern_count], idx) != null) continue;
                if (f.kern_count == max_kern_lookups) break;
                f.kern_lookups[f.kern_count] = idx;
                f.kern_count += 1;
            }
        }
        std.mem.sort(u16, f.kern_lookups[0..f.kern_count], {}, std.sort.asc(u16));
    }

    pub fn glyphFor(f: *const Font, cp: u32) u16 {
        return f.glyphIndex(cp);
    }

    pub const BBox = struct { x0: i16 = 0, y0: i16 = 0, x1: i16 = 0, y1: i16 = 0 };

    const BoxSink = struct {
        x0: f64 = std.math.inf(f64),
        y0: f64 = std.math.inf(f64),
        x1: f64 = -std.math.inf(f64),
        y1: f64 = -std.math.inf(f64),

        fn add(s: *BoxSink, x: f64, y: f64) void {
            s.x0 = @min(s.x0, x);
            s.y0 = @min(s.y0, y);
            s.x1 = @max(s.x1, x);
            s.y1 = @max(s.y1, y);
        }

        pub fn moveTo(s: *BoxSink, _: std.mem.Allocator, x: f64, y: f64) Error!void {
            s.add(x, y);
        }

        pub fn lineTo(s: *BoxSink, _: std.mem.Allocator, x: f64, y: f64) Error!void {
            s.add(x, y);
        }

        pub fn quadTo(s: *BoxSink, _: std.mem.Allocator, x1: f64, y1: f64, x: f64, y: f64) Error!void {
            s.add(x1, y1);
            s.add(x, y);
        }

        pub fn cubicTo(s: *BoxSink, _: std.mem.Allocator, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) Error!void {
            s.add(x1, y1);
            s.add(x2, y2);
            s.add(x, y);
        }

        pub fn close(_: *BoxSink, _: std.mem.Allocator) Error!void {}
    };

    pub fn bbox(f: *const Font, g: u16) BBox {
        if (f.cff == null) {
            const b = f.glyphBytes(g) catch return .{};
            if (b.len < 10) return .{};
            return .{ .x0 = i16At(b, 2) catch 0, .y0 = i16At(b, 4) catch 0, .x1 = i16At(b, 6) catch 0, .y1 = i16At(b, 8) catch 0 };
        }
        var s: BoxSink = .{};
        f.outline(std.heap.smp_allocator, g, .{}, &s) catch return .{};
        if (s.x1 < s.x0) return .{};
        return .{ .x0 = @intFromFloat(@floor(s.x0)), .y0 = @intFromFloat(@floor(s.y0)), .x1 = @intFromFloat(@ceil(s.x1)), .y1 = @intFromFloat(@ceil(s.y1)) };
    }

    pub fn italicCorrection(f: *const Font, g: u16) i16 {
        return if (f.math) |m| m.italicCorrection(g) else 0;
    }

    pub fn topAccent(f: *const Font, g: u16) i16 {
        if (f.math) |m| if (m.topAccent(g)) |v| return v;
        return @intFromFloat(f.advance(g) / 2);
    }

    pub fn isExtendedShape(f: *const Font, g: u16) bool {
        return if (f.math) |m| m.isExtended(g) else false;
    }

    pub fn mathKern(f: *const Font, g: u16, corner: math_mod.Corner) ?math_mod.Kern {
        return if (f.math) |m| m.kernOf(g, corner) else null;
    }

    pub fn vertVariants(f: *const Font, g: u16) math_mod.Variants {
        return if (f.math) |m| m.variantsOf(g, .vert) else .{};
    }

    pub fn horizVariants(f: *const Font, g: u16) math_mod.Variants {
        return if (f.math) |m| m.variantsOf(g, .horiz) else .{};
    }

    pub fn assembly(f: *const Font, g: u16, dir: math_mod.Dir) ?math_mod.Assembly {
        return if (f.math) |m| m.assembly(g, dir) else null;
    }

    pub fn open(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Font {
        return fromTtc(io, alloc, path, 0);
    }

    pub fn fromTtc(io: std.Io, alloc: std.mem.Allocator, path: []const u8, index: u32) !Font {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 << 20));
        errdefer alloc.free(data);
        return init(data, index);
    }

    pub fn glyphIndex(f: *const Font, cp: u32) u16 {
        return (switch (f.cmap_format) {
            4 => f.cmap4(cp),
            12 => f.cmap12(cp),
            else => 0,
        }) catch 0;
    }

    fn cmap4(f: *const Font, cp: u32) Error!u16 {
        if (cp > 0xFFFF) return 0;
        const d = f.data;
        const segx2: usize = try u16At(d, f.cmap + 6);
        const n = segx2 / 2;
        const ends = f.cmap + 14;
        const starts = ends + segx2 + 2;
        const deltas = starts + segx2;
        const ranges = deltas + segx2;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (cp > try u16At(d, ends + mid * 2)) lo = mid + 1 else hi = mid;
        }
        if (lo == n) return 0;
        const start = try u16At(d, starts + lo * 2);
        if (cp < start) return 0;
        const delta = try u16At(d, deltas + lo * 2);
        const ro = try u16At(d, ranges + lo * 2);
        if (ro == 0) return @truncate(cp +% delta);
        const g = try u16At(d, ranges + lo * 2 + ro + (cp - start) * 2);
        return if (g == 0) 0 else g +% delta;
    }

    fn cmap12(f: *const Font, cp: u32) Error!u16 {
        const d = f.data;
        const n = try u32At(d, f.cmap + 12);
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (cp > try u32At(d, f.cmap + 16 + mid * 12 + 4)) lo = mid + 1 else hi = mid;
        }
        if (lo == n) return 0;
        const rec = f.cmap + 16 + lo * 12;
        const start = try u32At(d, rec);
        if (cp < start) return 0;
        const g = (try u32At(d, rec + 8)) +% (cp - start);
        return if (g < f.num_glyphs) @intCast(g) else 0;
    }

    pub fn advance(f: *const Font, g: u16) f64 {
        const idx: usize = @min(g, f.num_hmetrics - 1);
        return @floatFromInt(u16At(f.data, f.hmtx + idx * 4) catch 0);
    }

    pub fn leftBearing(f: *const Font, g: u16) i16 {
        if (g < f.num_hmetrics) return i16At(f.data, f.hmtx + @as(usize, g) * 4 + 2) catch 0;
        return i16At(f.data, f.hmtx + @as(usize, f.num_hmetrics) * 4 + (@as(usize, g) - f.num_hmetrics) * 2) catch 0;
    }

    pub fn glyphBytes(f: *const Font, g: u16) Error![]const u8 {
        if (g >= f.num_glyphs) return error.Corrupt;
        const a = f.glyf + try f.locaAt(g);
        const b = f.glyf + try f.locaAt(@as(usize, g) + 1);
        if (b < a or b > f.data.len) return error.Corrupt;
        return f.data[a..b];
    }

    pub fn kern(f: *const Font, left: u16, right: u16) f64 {
        if (left == 0 or right == 0) return 0;
        if (f.kern_count > 0) {
            var total: i32 = 0;
            for (f.kern_lookups[0..f.kern_count]) |idx| total += f.lookupKern(idx, left, right);
            return @floatFromInt(total);
        }
        return @floatFromInt(f.legacyKern(left, right));
    }

    fn lookupKern(f: *const Font, idx: u16, l: u16, r: u16) i32 {
        const d = f.data;
        const ll = f.gpos_lookups;
        const count = u16At(d, ll) catch return 0;
        if (idx >= count) return 0;
        const lk = ll + (u16At(d, ll + 2 + @as(usize, idx) * 2) catch return 0);
        const ltype = u16At(d, lk) catch return 0;
        const nsub = u16At(d, lk + 4) catch return 0;
        for (0..nsub) |i| {
            var st = lk + (u16At(d, lk + 6 + i * 2) catch return 0);
            var t = ltype;
            if (t == 9) {
                t = u16At(d, st + 2) catch return 0;
                st += u32At(d, st + 4) catch return 0;
            }
            if (t != 2) continue;
            if (f.pairPos(st, l, r) catch null) |v| return v;
        }
        return 0;
    }

    fn pairPos(f: *const Font, s: usize, l: u16, r: u16) Error!?i32 {
        const d = f.data;
        const fmt = try u16At(d, s);
        const ci = (try coverageIndex(d, s + try u16At(d, s + 2), l)) orelse return null;
        const vf1 = try u16At(d, s + 4);
        const vf2 = try u16At(d, s + 6);
        const size1 = 2 * @as(usize, @popCount(vf1));
        const rec = size1 + 2 * @as(usize, @popCount(vf2));
        const xoff: ?usize = if (vf1 & 4 != 0) 2 * @as(usize, @popCount(vf1 & 3)) else null;
        if (fmt == 1) {
            if (ci >= try u16At(d, s + 8)) return null;
            const ps = s + try u16At(d, s + 10 + @as(usize, ci) * 2);
            const n = try u16At(d, ps);
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const at = ps + 2 + mid * (rec + 2);
                const second = try u16At(d, at);
                if (second == r) return if (xoff) |o| try i16At(d, at + 2 + o) else 0;
                if (second < r) lo = mid + 1 else hi = mid;
            }
            return null;
        }
        if (fmt != 2) return null;
        const c1n = try u16At(d, s + 12);
        const c2n = try u16At(d, s + 14);
        const c1 = try classOf(d, s + try u16At(d, s + 8), l);
        const c2 = try classOf(d, s + try u16At(d, s + 10), r);
        if (c1 >= c1n or c2 >= c2n) return 0;
        const at = s + 16 + (@as(usize, c1) * c2n + c2) * rec;
        return if (xoff) |o| try i16At(d, at + o) else 0;
    }

    fn legacyKern(f: *const Font, l: u16, r: u16) i32 {
        if (f.kern_table == 0) return 0;
        const d = f.data;
        const k = f.kern_table;
        if ((u16At(d, k) catch return 0) != 0) return 0;
        const nt = u16At(d, k + 2) catch return 0;
        var p = k + 4;
        var total: i32 = 0;
        for (0..nt) |_| {
            const len = u16At(d, p + 2) catch return total;
            const cov = u16At(d, p + 4) catch return total;
            if (len < 14) return total;
            if (cov >> 8 == 0 and cov & 1 != 0) total += kernSubtable(d, p, l, r);
            p += len;
        }
        return total;
    }

    pub fn lineHeight(f: *const Font, size: f64) f64 {
        const s = size / @as(f64, @floatFromInt(f.upem));
        return @round(@as(f64, @floatFromInt(f.ascent)) * s) - @round(@as(f64, @floatFromInt(f.descent)) * s) + @round(@as(f64, @floatFromInt(f.line_gap)) * s);
    }

    pub fn measure(f: *const Font, text: []const u8, size: f64) struct { w: f64, h: f64 } {
        return .{ .w = f.width(text, size, true), .h = f.lineHeight(size) };
    }

    pub fn width(f: *const Font, text: []const u8, size: f64, kerning: bool) f64 {
        var units: f64 = 0;
        var prev: u16 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const d = decodeAt(text, i);
            i += d.len;
            if (isZeroWidth(d.cp)) continue;
            const g = f.glyphIndex(d.cp);
            units += f.advance(g);
            if (kerning) units += f.kern(prev, g);
            prev = g;
        }
        return units * size / @as(f64, @floatFromInt(f.upem));
    }

    pub fn nameAscii(f: *const Font, id: u16, buf: []u8) ?[]const u8 {
        if (f.name == 0) return null;
        const d = f.data;
        const n = u16At(d, f.name + 2) catch return null;
        const store = f.name + (u16At(d, f.name + 4) catch return null);
        var best: ?[]const u8 = null;
        for (0..n) |i| {
            const rec = f.name + 6 + i * 12;
            const pid = u16At(d, rec) catch return best;
            if (pid != 3 and pid != 1) continue;
            if ((u16At(d, rec + 6) catch return best) != id) continue;
            const len = u16At(d, rec + 8) catch return best;
            const off = store + (u16At(d, rec + 10) catch return best);
            if (off > d.len or d.len - off < len) continue;
            const raw = d[off..][0..len];
            var o: usize = 0;
            if (pid == 3) {
                var k: usize = 0;
                while (k + 1 < raw.len and o < buf.len) : (k += 2) {
                    buf[o] = if (raw[k] == 0 and raw[k + 1] < 0x80) std.ascii.toLower(raw[k + 1]) else '?';
                    o += 1;
                }
                return buf[0..o];
            }
            for (raw) |c| {
                if (o == buf.len) break;
                buf[o] = if (c < 0x80) std.ascii.toLower(c) else '?';
                o += 1;
            }
            best = buf[0..o];
        }
        return best;
    }

    fn locaAt(f: *const Font, idx: usize) Error!usize {
        if (f.long_loca) return try u32At(f.data, f.loca + idx * 4);
        return @as(usize, try u16At(f.data, f.loca + idx * 2)) * 2;
    }

    pub fn outline(f: *const Font, alloc: std.mem.Allocator, g: u16, m: Mat, path: anytype) Error!void {
        if (f.cff) |c| return c.outline(alloc, g, m, path);
        var budget: u32 = 128;
        try f.outlineInner(alloc, g, m, path, 0, &budget);
    }

    pub fn outlineAt(f: *const Font, alloc: std.mem.Allocator, g: u16, size: f64, x: f64, y: f64, path: anytype) Error!void {
        const s = size / @as(f64, @floatFromInt(f.upem));
        const m: Mat = .{ .a = s, .d = -s, .c = if (f.oblique) oblique_skew * s else 0, .e = x, .f = y };
        try f.outline(alloc, g, m, path);
    }

    const Point = struct { x: f64, y: f64, on: bool };

    fn outlineInner(f: *const Font, alloc: std.mem.Allocator, g: u16, m: Mat, path: anytype, depth: u32, budget: *u32) Error!void {
        if (depth > 6 or budget.* == 0) return error.Corrupt;
        budget.* -= 1;
        if (g >= f.num_glyphs) return error.Corrupt;
        const d = f.data;
        const start = f.glyf + try f.locaAt(g);
        const end = f.glyf + try f.locaAt(@as(usize, g) + 1);
        if (end <= start) return;
        if (end > d.len) return error.Corrupt;
        const nc = try i16At(d, start);
        if (nc < 0) return f.composite(alloc, start + 10, m, path, depth, budget);
        try f.simple(alloc, start + 10, @intCast(nc), m, path);
    }

    fn composite(f: *const Font, alloc: std.mem.Allocator, first: usize, m: Mat, path: anytype, depth: u32, budget: *u32) Error!void {
        const d = f.data;
        var p = first;
        while (true) {
            const flags = try u16At(d, p);
            const gi = try u16At(d, p + 2);
            p += 4;
            var dx: f64 = 0;
            var dy: f64 = 0;
            if (flags & 1 != 0) {
                if (flags & 2 != 0) {
                    dx = @floatFromInt(try i16At(d, p));
                    dy = @floatFromInt(try i16At(d, p + 2));
                }
                p += 4;
            } else {
                if (p + 2 > d.len) return error.Corrupt;
                if (flags & 2 != 0) {
                    dx = @floatFromInt(@as(i8, @bitCast(d[p])));
                    dy = @floatFromInt(@as(i8, @bitCast(d[p + 1])));
                }
                p += 2;
            }
            var t: [4]f64 = .{ 1, 0, 0, 1 };
            const nvals: usize = if (flags & 0x8 != 0) 1 else if (flags & 0x40 != 0) 2 else if (flags & 0x80 != 0) 4 else 0;
            for (0..nvals) |i| t[i] = @as(f64, @floatFromInt(try i16At(d, p + i * 2))) / 16384.0;
            if (nvals == 1) t[3] = t[0];
            if (nvals == 2) {
                t[3] = t[1];
                t[1] = 0;
            }
            p += nvals * 2;
            const local: Mat = .{ .a = t[0], .b = t[1], .c = t[2], .d = t[3], .e = dx, .f = dy };
            try f.outlineInner(alloc, gi, m.mul(local), path, depth + 1, budget);
            if (flags & 0x20 == 0) break;
        }
    }

    fn simple(f: *const Font, alloc: std.mem.Allocator, first: usize, n: usize, m: Mat, path: anytype) Error!void {
        if (n == 0) return;
        const d = f.data;
        const end_pts = first;
        const npts: usize = @as(usize, try u16At(d, end_pts + (n - 1) * 2)) + 1;
        var p = end_pts + n * 2;
        p += 2 + try u16At(d, p);
        const flags = try alloc.alloc(u8, npts);
        defer alloc.free(flags);
        const pts = try alloc.alloc(Point, npts);
        defer alloc.free(pts);
        var i: usize = 0;
        while (i < npts) {
            if (p >= d.len) return error.Corrupt;
            const fl = d[p];
            p += 1;
            flags[i] = fl;
            i += 1;
            if (fl & 8 == 0) continue;
            if (p >= d.len) return error.Corrupt;
            var rep = d[p];
            p += 1;
            while (rep > 0 and i < npts) : (rep -= 1) {
                flags[i] = fl;
                i += 1;
            }
        }
        var v: i32 = 0;
        for (0..npts) |k| {
            const fl = flags[k];
            if (fl & 2 != 0) {
                if (p >= d.len) return error.Corrupt;
                v += if (fl & 16 != 0) d[p] else -@as(i32, d[p]);
                p += 1;
            } else if (fl & 16 == 0) {
                v += try i16At(d, p);
                p += 2;
            }
            pts[k] = .{ .x = @floatFromInt(v), .y = 0, .on = fl & 1 != 0 };
        }
        v = 0;
        for (0..npts) |k| {
            const fl = flags[k];
            if (fl & 4 != 0) {
                if (p >= d.len) return error.Corrupt;
                v += if (fl & 32 != 0) d[p] else -@as(i32, d[p]);
                p += 1;
            } else if (fl & 32 == 0) {
                v += try i16At(d, p);
                p += 2;
            }
            pts[k].y = @floatFromInt(v);
        }
        var s: usize = 0;
        for (0..n) |ci| {
            const last: usize = try u16At(d, end_pts + ci * 2);
            if (last < s or last >= npts) return error.Corrupt;
            try contour(alloc, pts[s .. last + 1], m, path);
            s = last + 1;
        }
    }

    fn contour(alloc: std.mem.Allocator, pts: []const Point, m: Mat, path: anytype) Error!void {
        const n = pts.len;
        if (n < 2) return;
        const first_on = pts[0].on;
        const last_on = pts[n - 1].on;
        const begin: Pt = if (first_on) tp(m, pts[0]) else if (last_on) tp(m, pts[n - 1]) else midPt(m, pts[0], pts[n - 1]);
        const skip: usize = if (first_on) 1 else 0;
        const count: usize = if (first_on or last_on) n - 1 else n;
        try path.moveTo(alloc, begin.x, begin.y);
        var ctrl: ?Pt = null;
        for (0..count) |k| {
            const q = pts[skip + k];
            const qp = tp(m, q);
            if (q.on) {
                if (ctrl) |c| {
                    try path.quadTo(alloc, c.x, c.y, qp.x, qp.y);
                    ctrl = null;
                } else try path.lineTo(alloc, qp.x, qp.y);
                continue;
            }
            if (ctrl) |c| try path.quadTo(alloc, c.x, c.y, (c.x + qp.x) / 2, (c.y + qp.y) / 2);
            ctrl = qp;
        }
        if (ctrl) |c| try path.quadTo(alloc, c.x, c.y, begin.x, begin.y);
        try path.close(alloc);
    }

    fn tp(m: Mat, q: Point) Pt {
        return m.apply(.{ .x = q.x, .y = q.y });
    }

    fn midPt(m: Mat, a: Point, b: Point) Pt {
        return m.apply(.{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 });
    }
};

fn kernSubtable(d: []const u8, p: usize, l: u16, r: u16) i32 {
    const n = u16At(d, p + 6) catch return 0;
    const key = (@as(u32, l) << 16) | r;
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const at = p + 14 + mid * 6;
        const k = u32At(d, at) catch return 0;
        if (k == key) return i16At(d, at + 4) catch 0;
        if (k < key) lo = mid + 1 else hi = mid;
    }
    return 0;
}

const coverageIndex = math_mod.coverage;

fn classOf(d: []const u8, cd: usize, g: u16) Error!u16 {
    const fmt = try u16At(d, cd);
    if (fmt == 1) {
        const start = try u16At(d, cd + 2);
        const n = try u16At(d, cd + 4);
        if (g < start or g - start >= n) return 0;
        return try u16At(d, cd + 6 + @as(usize, g - start) * 2);
    }
    if (fmt != 2) return 0;
    const n = try u16At(d, cd + 2);
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const at = cd + 4 + mid * 6;
        if (g < try u16At(d, at)) {
            hi = mid;
        } else if (g > try u16At(d, at + 2)) {
            lo = mid + 1;
        } else return try u16At(d, at + 4);
    }
    return 0;
}
