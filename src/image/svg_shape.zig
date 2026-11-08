const std = @import("std");
const font = @import("font");
const image = @import("image.zig");

const Font = font.Font;
const ReadError = error{Corrupt};

fn u16At(d: []const u8, off: usize) ReadError!u16 {
    if (off > d.len or d.len - off < 2) return error.Corrupt;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn i16At(d: []const u8, off: usize) ReadError!i16 {
    return @bitCast(try u16At(d, off));
}

fn u32At(d: []const u8, off: usize) ReadError!u32 {
    if (off > d.len or d.len - off < 4) return error.Corrupt;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

pub const Error = error{ OutOfMemory, TooLarge };

pub fn tableDir(f: *const Font) usize {
    const d = f.data;
    if (d.len < 16 or !std.mem.eql(u8, d[0..4], "ttcf")) return 0;
    const n = @min(u32At(d, 8) catch return 0, 256);
    for (0..n) |i| {
        const dir = u32At(d, 12 + i * 4) catch continue;
        const cnt = u16At(d, dir + 4) catch continue;
        for (0..cnt) |k| {
            const rec = dir + 12 + k * 16;
            if (rec + 16 > d.len) break;
            if (std.mem.eql(u8, d[rec..][0..4], "hmtx") and (u32At(d, rec + 8) catch 0) == f.hmtx) return dir;
        }
    }
    return 0;
}

pub fn findTable(f: *const Font, tag: *const [4]u8) ?usize {
    const d = f.data;
    const dir = tableDir(f);
    const n = u16At(d, dir + 4) catch return null;
    for (0..n) |i| {
        const rec = dir + 12 + i * 16;
        if (rec + 16 > d.len) return null;
        if (std.mem.eql(u8, d[rec..][0..4], tag)) {
            const off = u32At(d, rec + 8) catch return null;
            return if (off < d.len) off else null;
        }
    }
    return null;
}

// Joining

pub const Form = enum(u8) { none = 0, isol = 1, init = 2, medi = 4, fina = 8 };

const Join = enum { d, r, t, u };

fn inSet(cp: u32, comptime set: []const [2]u32) bool {
    for (set) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

fn joinOf(cp: u32) Join {
    const right = [_][2]u32{ .{ 0x622, 0x625 }, .{ 0x627, 0x627 }, .{ 0x629, 0x629 }, .{ 0x62F, 0x632 }, .{ 0x648, 0x648 }, .{ 0x671, 0x673 }, .{ 0x675, 0x677 }, .{ 0x688, 0x699 }, .{ 0x6C0, 0x6C0 }, .{ 0x6C3, 0x6CB }, .{ 0x6CD, 0x6CD }, .{ 0x6CF, 0x6CF }, .{ 0x6D2, 0x6D3 }, .{ 0x6D5, 0x6D5 }, .{ 0x6EE, 0x6EF }, .{ 0x759, 0x75B }, .{ 0x8AA, 0x8AC }, .{ 0x8B1, 0x8B2 } };
    const trans = [_][2]u32{ .{ 0x610, 0x61A }, .{ 0x64B, 0x65F }, .{ 0x670, 0x670 }, .{ 0x6D6, 0x6DC }, .{ 0x6DF, 0x6E4 }, .{ 0x6E7, 0x6E8 }, .{ 0x6EA, 0x6ED }, .{ 0x8D3, 0x8E1 }, .{ 0x8E3, 0x8FF }, .{ 0x200B, 0x200B } };
    if (inSet(cp, &trans)) return .t;
    if (inSet(cp, &right)) return .r;
    if (inSet(cp, &[_][2]u32{ .{ 0x620, 0x620 }, .{ 0x626, 0x626 }, .{ 0x628, 0x628 }, .{ 0x62A, 0x647 }, .{ 0x649, 0x64A }, .{ 0x66E, 0x66F }, .{ 0x678, 0x687 }, .{ 0x69A, 0x6BF }, .{ 0x6C1, 0x6C2 }, .{ 0x6CC, 0x6CC }, .{ 0x6CE, 0x6CE }, .{ 0x6D0, 0x6D1 }, .{ 0x6FA, 0x6FC }, .{ 0x6FF, 0x6FF }, .{ 0x750, 0x758 }, .{ 0x75C, 0x77F }, .{ 0x8A0, 0x8A9 }, .{ 0x8AF, 0x8B0 }, .{ 0x640, 0x640 } })) return .d;
    return .u;
}

pub fn isArabic(cp: u32) bool {
    return (cp >= 0x600 and cp <= 0x6FF) or (cp >= 0x750 and cp <= 0x77F) or (cp >= 0x8A0 and cp <= 0x8FF);
}

pub fn isRtl(cp: u32) bool {
    return isArabic(cp) or (cp >= 0x590 and cp <= 0x5FF) or (cp >= 0x700 and cp <= 0x7BF) or (cp >= 0xFB1D and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF);
}

pub fn arabicForms(cps: []const u32, out: []Form) void {
    for (cps, 0..) |cp, i| {
        const j = joinOf(cp);
        if (j == .u or j == .t) {
            out[i] = .none;
            continue;
        }
        var prev_d = false;
        var k = i;
        while (k > 0) {
            k -= 1;
            const pj = joinOf(cps[k]);
            if (pj == .t) continue;
            prev_d = pj == .d;
            break;
        }
        var next_c = false;
        k = i + 1;
        while (k < cps.len) : (k += 1) {
            const nj = joinOf(cps[k]);
            if (nj == .t) continue;
            next_c = nj == .d or nj == .r;
            break;
        }
        const cp_prev = prev_d;
        const cp_next = j == .d and next_c;
        out[i] = if (cp_prev and cp_next) .medi else if (cp_prev) .fina else if (cp_next) .init else .isol;
    }
}

// GSUB

pub const G = struct { gid: u16, form: u8 = 0, first: u32, last: u32 };

pub const Req = struct { index: u16, mask: u8 };

pub const Feat = struct { tag: *const [4]u8, mask: u8 };

pub const Gsub = struct {
    d: []const u8,
    scripts: usize,
    features: usize,
    lookups: usize,

    pub fn init(f: *const Font) ?Gsub {
        const base = findTable(f, "GSUB") orelse return null;
        const d = f.data;
        const s = u16At(d, base + 4) catch return null;
        const fe = u16At(d, base + 6) catch return null;
        const lk = u16At(d, base + 8) catch return null;
        return .{ .d = d, .scripts = base + s, .features = base + fe, .lookups = base + lk };
    }

    fn langSys(g: Gsub, script_tags: []const *const [4]u8) ?usize {
        const n = u16At(g.d, g.scripts) catch return null;
        const wanted = script_tags;
        for (wanted) |tag| {
            for (0..n) |i| {
                const rec = g.scripts + 2 + i * 6;
                if (rec + 6 > g.d.len) return null;
                if (!std.mem.eql(u8, g.d[rec..][0..4], tag)) continue;
                const so = g.scripts + (u16At(g.d, rec + 4) catch return null);
                const def = u16At(g.d, so) catch return null;
                if (def != 0) return so + def;
                const nl = u16At(g.d, so + 2) catch return null;
                if (nl > 0) return so + (u16At(g.d, so + 4 + 4) catch return null);
                return null;
            }
        }
        return null;
    }

    pub fn collect(g: Gsub, script_tags: []const *const [4]u8, feats: []const Feat, out: *std.ArrayList(Req), alloc: std.mem.Allocator) Error!void {
        const ls = g.langSys(script_tags) orelse return;
        const nf = u16At(g.d, ls + 4) catch return;
        const nfeat_total = u16At(g.d, g.features) catch return;
        var fi: usize = 0;
        while (fi <= nf) : (fi += 1) {
            const idx: usize = if (fi == nf) (u16At(g.d, ls + 2) catch break) else (u16At(g.d, ls + 6 + fi * 2) catch break);
            if (idx == 0xFFFF or idx >= nfeat_total) continue;
            const rec = g.features + 2 + idx * 6;
            if (rec + 6 > g.d.len) continue;
            const tag = g.d[rec..][0..4];
            var mask: ?u8 = null;
            for (feats) |ft| if (std.mem.eql(u8, tag, ft.tag)) {
                mask = ft.mask;
            };
            const m = mask orelse continue;
            const fo = g.features + (u16At(g.d, rec + 4) catch continue);
            const nl = u16At(g.d, fo + 2) catch continue;
            for (0..nl) |k| {
                const li = u16At(g.d, fo + 4 + k * 2) catch break;
                var found = false;
                for (out.items) |*r| if (r.index == li) {
                    r.mask |= m;
                    found = true;
                };
                if (!found and out.items.len < 64) try out.append(alloc, .{ .index = li, .mask = m });
            }
        }
        std.mem.sort(Req, out.items, {}, struct {
            fn lt(_: void, a: Req, b: Req) bool {
                return a.index < b.index;
            }
        }.lt);
    }

    fn coverage(g: Gsub, off: usize, gid: u16) ?usize {
        const fmt = u16At(g.d, off) catch return null;
        const n = u16At(g.d, off + 2) catch return null;
        if (fmt == 1) {
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const v = u16At(g.d, off + 4 + mid * 2) catch return null;
                if (v == gid) return mid;
                if (v < gid) lo = mid + 1 else hi = mid;
            }
            return null;
        }
        if (fmt == 2) {
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = off + 4 + mid * 6;
                const s = u16At(g.d, rec) catch return null;
                const e = u16At(g.d, rec + 2) catch return null;
                if (gid < s) {
                    hi = mid;
                } else if (gid > e) {
                    lo = mid + 1;
                } else return (u16At(g.d, rec + 4) catch return null) + (gid - s);
            }
        }
        return null;
    }

    fn lookupOffset(g: Gsub, idx: usize) ?usize {
        const n = u16At(g.d, g.lookups) catch return null;
        if (idx >= n) return null;
        return g.lookups + (u16At(g.d, g.lookups + 2 + idx * 2) catch return null);
    }

    pub fn apply(g: Gsub, alloc: std.mem.Allocator, glyphs: *std.ArrayList(G), reqs: []const Req) Error!void {
        for (reqs) |rq| {
            const lo = g.lookupOffset(rq.index) orelse continue;
            var i: usize = 0;
            var guard: usize = 0;
            while (i < glyphs.items.len) {
                guard += 1;
                if (guard > 100_000) return error.TooLarge;
                if (glyphs.items[i].form & rq.mask == 0 and rq.mask != 0xFF) {
                    i += 1;
                    continue;
                }
                const adv = try g.applyAt(alloc, glyphs, i, lo, 0);
                i += if (adv) |n| n else 1;
            }
        }
    }

    fn applyAt(g: Gsub, alloc: std.mem.Allocator, glyphs: *std.ArrayList(G), i: usize, lookup: usize, depth: u32) Error!?usize {
        if (depth > 4) return null;
        const d = g.d;
        var ty = u16At(d, lookup) catch return null;
        const nsub = u16At(d, lookup + 4) catch return null;
        var s: usize = 0;
        while (s < nsub) : (s += 1) {
            var st = lookup + (u16At(d, lookup + 6 + s * 2) catch return null);
            if (ty == 7) {
                if ((u16At(d, st) catch return null) != 1) return null;
                ty = u16At(d, st + 2) catch return null;
                st += u32At(d, st + 4) catch return null;
            }
            const fmt = u16At(d, st) catch continue;
            const gid = glyphs.items[i].gid;
            switch (ty) {
                1 => {
                    const cov = g.coverage(st + (u16At(d, st + 2) catch continue), gid) orelse continue;
                    if (fmt == 1) {
                        const delta = i16At(d, st + 4) catch continue;
                        glyphs.items[i].gid = @bitCast(@as(i16, @bitCast(gid)) +% delta);
                    } else {
                        glyphs.items[i].gid = u16At(d, st + 6 + cov * 2) catch continue;
                    }
                    return 1;
                },
                2 => {
                    const cov = g.coverage(st + (u16At(d, st + 2) catch continue), gid) orelse continue;
                    const seq = st + (u16At(d, st + 6 + cov * 2) catch continue);
                    const n = u16At(d, seq) catch continue;
                    if (n == 0 or n > 8) continue;
                    const base = glyphs.items[i];
                    glyphs.items[i].gid = u16At(d, seq + 2) catch continue;
                    for (1..n) |k| try glyphs.insert(alloc, i + k, .{ .gid = u16At(d, seq + 2 + k * 2) catch continue, .form = base.form, .first = base.first, .last = base.last });
                    return n;
                },
                3 => {
                    const cov = g.coverage(st + (u16At(d, st + 2) catch continue), gid) orelse continue;
                    const set = st + (u16At(d, st + 6 + cov * 2) catch continue);
                    const n = u16At(d, set) catch continue;
                    if (n == 0) continue;
                    glyphs.items[i].gid = u16At(d, set + 2) catch continue;
                    return 1;
                },
                4 => {
                    const cov = g.coverage(st + (u16At(d, st + 2) catch continue), gid) orelse continue;
                    const set = st + (u16At(d, st + 6 + cov * 2) catch continue);
                    const nl = u16At(d, set) catch continue;
                    for (0..nl) |k| {
                        const lg = set + (u16At(d, set + 2 + k * 2) catch continue);
                        const lig = u16At(d, lg) catch continue;
                        const cc = u16At(d, lg + 2) catch continue;
                        if (cc < 2 or i + cc > glyphs.items.len) continue;
                        var ok = true;
                        for (1..cc) |c| {
                            if ((u16At(d, lg + 4 + (c - 1) * 2) catch 0xFFFF) != glyphs.items[i + c].gid) {
                                ok = false;
                                break;
                            }
                        }
                        if (!ok) continue;
                        glyphs.items[i].gid = lig;
                        glyphs.items[i].last = glyphs.items[i + cc - 1].last;
                        for (1..cc) |_| _ = glyphs.orderedRemove(i + 1);
                        return 1;
                    }
                },
                5, 6 => {
                    if (fmt != 3) continue;
                    var p = st + 2;
                    var back: usize = 0;
                    var back_off: usize = 0;
                    if (ty == 6) {
                        back = u16At(d, p) catch continue;
                        back_off = p + 2;
                        p += 2 + back * 2;
                    }
                    const inc = u16At(d, p) catch continue;
                    var nrec5: usize = 0;
                    if (ty == 5) {
                        nrec5 = u16At(d, p + 2) catch continue;
                        p += 2;
                    }
                    const in_off = p + 2;
                    p += 2 + inc * 2;
                    var ahead: usize = 0;
                    var ahead_off: usize = 0;
                    if (ty == 6) {
                        ahead = u16At(d, p) catch continue;
                        ahead_off = p + 2;
                        p += 2 + ahead * 2;
                    }
                    const nrec = if (ty == 5) nrec5 else (u16At(d, p) catch continue);
                    const rec_off = if (ty == 5) p else p + 2;
                    if (inc == 0 or i + inc + ahead > glyphs.items.len or i < back) continue;
                    var ok = true;
                    for (0..back) |k| {
                        const co = st + (u16At(d, back_off + k * 2) catch 0);
                        if (g.coverage(co, glyphs.items[i - 1 - k].gid) == null) ok = false;
                    }
                    for (0..inc) |k| {
                        const co = st + (u16At(d, in_off + k * 2) catch 0);
                        if (g.coverage(co, glyphs.items[i + k].gid) == null) ok = false;
                    }
                    for (0..ahead) |k| {
                        const co = st + (u16At(d, ahead_off + k * 2) catch 0);
                        if (g.coverage(co, glyphs.items[i + inc + k].gid) == null) ok = false;
                    }
                    if (!ok) continue;
                    for (0..nrec) |k| {
                        const seq = u16At(d, rec_off + k * 4) catch continue;
                        const li = u16At(d, rec_off + k * 4 + 2) catch continue;
                        if (seq >= inc) continue;
                        const nested = g.lookupOffset(li) orelse continue;
                        _ = try g.applyAt(alloc, glyphs, i + seq, nested, depth + 1);
                    }
                    return inc;
                },
                else => {},
            }
        }
        return null;
    }
};

// Colour glyphs

pub const Layer = struct { gid: u16, color: ?[4]u8 };

pub fn colrLayers(f: *const Font, gid: u16, alloc: std.mem.Allocator, out: *std.ArrayList(Layer)) Error!bool {
    const d = f.data;
    const colr = findTable(f, "COLR") orelse return false;
    if ((u16At(d, colr) catch return false) != 0) return false;
    const nbase = u16At(d, colr + 2) catch return false;
    const base_off = colr + (u32At(d, colr + 4) catch return false);
    const layer_off = colr + (u32At(d, colr + 8) catch return false);
    const nlayers = u16At(d, colr + 12) catch return false;
    var lo: usize = 0;
    var hi: usize = nbase;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const rec = base_off + mid * 6;
        const g = u16At(d, rec) catch return false;
        if (g == gid) {
            const first = u16At(d, rec + 2) catch return false;
            const n = u16At(d, rec + 4) catch return false;
            if (@as(usize, first) + n > nlayers or n > 64) return false;
            const cpal = findTable(f, "CPAL");
            for (0..n) |k| {
                const lr = layer_off + (first + k) * 4;
                const lg = u16At(d, lr) catch return false;
                const pi = u16At(d, lr + 2) catch return false;
                var color: ?[4]u8 = null;
                if (pi != 0xFFFF) if (cpal) |cp| {
                    const ncol = u16At(d, cp + 2) catch 0;
                    const arr = cp + (u32At(d, cp + 8) catch 0);
                    const first_idx = u16At(d, cp + 12) catch 0;
                    if (pi < ncol) {
                        const co = arr + (@as(usize, first_idx) + pi) * 4;
                        if (co + 4 <= d.len) color = .{ d[co + 2], d[co + 1], d[co], d[co + 3] };
                    }
                };
                try out.append(alloc, .{ .gid = lg, .color = color });
            }
            return true;
        }
        if (g < gid) lo = mid + 1 else hi = mid;
    }
    return false;
}

pub const Bitmap = struct {
    img: image.Image,
    /// offset of the bitmap's left edge and bottom edge from the glyph origin, y up, in pixels at `ppem`
    left: f64,
    bottom: f64,
    ppem: f64,
};

fn pngAt(d: []const u8, off: usize, len: usize) ?[]const u8 {
    if (off > d.len or len > d.len - off or len < 8) return null;
    const s = d[off..][0..len];
    return if (std.mem.eql(u8, s[0..4], "\x89PNG")) s else null;
}

pub fn bitmapGlyph(f: *const Font, gid: u16, alloc: std.mem.Allocator) ?Bitmap {
    const d = f.data;
    if (findTable(f, "sbix")) |sb| {
        const ns = u32At(d, sb + 4) catch return null;
        if (ns == 0 or ns > 64) return null;
        var best: usize = 0;
        var best_ppem: u16 = 0;
        for (0..ns) |i| {
            const so = sb + (u32At(d, sb + 8 + i * 4) catch continue);
            const ppem = u16At(d, so) catch continue;
            if (ppem > best_ppem) {
                best_ppem = ppem;
                best = so;
            }
        }
        if (best_ppem == 0) return null;
        const o0 = best + (u32At(d, best + 4 + @as(usize, gid) * 4) catch return null);
        const o1 = best + (u32At(d, best + 8 + @as(usize, gid) * 4) catch return null);
        if (o1 <= o0 + 8 or o1 > d.len) return null;
        if (!std.mem.eql(u8, d[o0 + 4 ..][0..4], "png ")) return null;
        const png = d[o0 + 8 .. o1];
        const img = image.decode(alloc, png) catch return null;
        return .{ .img = img, .left = @floatFromInt(i16At(d, o0) catch 0), .bottom = @floatFromInt(i16At(d, o0 + 2) catch 0), .ppem = @floatFromInt(best_ppem) };
    }
    const cblc = findTable(f, "CBLC") orelse return null;
    const cbdt = findTable(f, "CBDT") orelse return null;
    const nsz = u32At(d, cblc + 4) catch return null;
    if (nsz == 0 or nsz > 32) return null;
    var best_i: usize = 0;
    var best_p: u8 = 0;
    for (0..nsz) |i| {
        const rec = cblc + 8 + i * 48;
        const ppem = if (rec + 46 < d.len) d[rec + 44] else 0;
        if (ppem > best_p) {
            best_p = ppem;
            best_i = i;
        }
    }
    const rec = cblc + 8 + best_i * 48;
    const arr = cblc + (u32At(d, rec) catch return null);
    const nsub = u32At(d, rec + 8) catch return null;
    for (0..nsub) |k| {
        const e = arr + k * 8;
        const first = u16At(d, e) catch continue;
        const last = u16At(d, e + 2) catch continue;
        if (gid < first or gid > last) continue;
        const sub = arr + (u32At(d, e + 4) catch return null);
        const ifmt = u16At(d, sub) catch return null;
        const imgfmt = u16At(d, sub + 2) catch return null;
        const data_off = u32At(d, sub + 4) catch return null;
        const idx = gid - first;
        const go: usize = if (ifmt == 1) (u32At(d, sub + 8 + @as(usize, idx) * 4) catch return null) else if (ifmt == 3) (u16At(d, sub + 8 + @as(usize, idx) * 2) catch return null) else return null;
        const ge: usize = if (ifmt == 1) (u32At(d, sub + 12 + @as(usize, idx) * 4) catch return null) else (u16At(d, sub + 10 + @as(usize, idx) * 2) catch return null);
        if (ge <= go) return null;
        const p = cbdt + data_off + go;
        var bx: f64 = 0;
        var by: f64 = 0;
        var h: f64 = 0;
        var hdr: usize = 0;
        if (imgfmt == 17) {
            if (p + 9 > d.len) return null;
            h = @floatFromInt(d[p]);
            bx = @floatFromInt(@as(i8, @bitCast(d[p + 2])));
            by = @floatFromInt(@as(i8, @bitCast(d[p + 3])));
            hdr = 5;
        } else if (imgfmt == 18) {
            if (p + 12 > d.len) return null;
            h = @floatFromInt(d[p]);
            bx = @floatFromInt(@as(i8, @bitCast(d[p + 2])));
            by = @floatFromInt(@as(i8, @bitCast(d[p + 3])));
            hdr = 8;
        } else return null;
        const len = u32At(d, p + hdr) catch return null;
        const png = pngAt(d, p + hdr + 4, len) orelse return null;
        const img = image.decode(alloc, png) catch return null;
        return .{ .img = img, .left = bx, .bottom = by - h, .ppem = @floatFromInt(best_p) };
    }
    return null;
}

test "joining forms" {
    const cps = [_]u32{ 0x0628, 0x0627, 0x0644, 0x0644, 0x0647 };
    var forms: [5]Form = @splat(.none);
    arabicForms(&cps, &forms);
    try std.testing.expectEqual(Form.init, forms[0]);
    try std.testing.expectEqual(Form.fina, forms[1]);
    try std.testing.expectEqual(Form.init, forms[2]);
    try std.testing.expectEqual(Form.medi, forms[3]);
    try std.testing.expectEqual(Form.fina, forms[4]);
}

test "bundled font has no colour tables" {
    const f = font.bundled(false, false);
    var layers: std.ArrayList(Layer) = .empty;
    defer layers.deinit(std.testing.allocator);
    try std.testing.expect(!(try colrLayers(f, 5, std.testing.allocator, &layers)));
    try std.testing.expect(findTable(f, "glyf") != null);
}
