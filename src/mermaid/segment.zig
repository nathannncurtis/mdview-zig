const std = @import("std");
const testdata = @import("testdata");
const Allocator = std.mem.Allocator;
const data = @import("segment_data.zig");
const errors = @import("errors.zig");

// UAX #29 grapheme cluster and word boundaries, the rules `Intl.Segmenter` applies to scripts that need no dictionary.
// Dictionary segmentation (Thai, Lao, Khmer, Myanmar, and Han/Hiragana/Katakana words) is not done.

const Gp = data.GraphemeProp;
const Wp = data.WordProp;

fn lookup(table: anytype, cp: u32, default: anytype) @TypeOf(default) {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = table[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return r.v;
    }
    return default;
}

pub fn graphemeProp(cp: u32) Gp {
    return lookup(&data.grapheme, cp, Gp.other);
}

pub fn wordProp(cp: u32) Wp {
    return lookup(&data.word, cp, Wp.other);
}

pub fn incb(cp: u32) data.Incb {
    return lookup(&data.incb, cp, data.Incb.none);
}

pub fn isExtPict(cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = data.ext_pict.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = data.ext_pict[mid];
        if (cp < r[0]) hi = mid else if (cp > r[1]) lo = mid + 1 else return true;
    }
    return false;
}

/// `out[i]` is true when there is a boundary before `cps[i]`; `out[cps.len]` is the boundary after the last one.
pub fn graphemeBreaks(a: Allocator, cps: []const u32) Allocator.Error![]bool {
    const out = try a.alloc(bool, cps.len + 1);
    @memset(out, false);
    if (cps.len == 0) return out;
    out[0] = true;
    out[cps.len] = true;
    var ri_run: usize = 0;
    var pict: u8 = 0;
    var conj: u8 = 0;
    for (cps, 0..) |cur, i| {
        const cp = graphemeProp(cur);
        if (i > 0) {
            const pp = graphemeProp(cps[i - 1]);
            out[i] = brk: {
                if (pp == .cr and cp == .lf) break :brk false;
                if (pp == .cr or pp == .lf or pp == .control) break :brk true;
                if (cp == .cr or cp == .lf or cp == .control) break :brk true;
                if (pp == .l and (cp == .l or cp == .v or cp == .lv or cp == .lvt)) break :brk false;
                if ((pp == .lv or pp == .v) and (cp == .v or cp == .t)) break :brk false;
                if ((pp == .lvt or pp == .t) and cp == .t) break :brk false;
                if (cp == .extend or cp == .zwj or cp == .spacing_mark) break :brk false;
                if (pp == .prepend) break :brk false;
                if (conj == 2 and incb(cur) == .consonant) break :brk false;
                if (pict == 2 and isExtPict(cur)) break :brk false;
                if (pp == .regional_indicator and cp == .regional_indicator and ri_run % 2 == 1) break :brk false;
                break :brk true;
            };
        }
        ri_run = if (cp == .regional_indicator) ri_run + 1 else 0;
        pict = if (isExtPict(cur)) 1 else if (pict == 1 and cp == .extend) 1 else if (pict == 1 and cp == .zwj) 2 else 0;
        const ib = incb(cur);
        conj = if (ib == .consonant) 1 else if (conj >= 1 and ib == .linker) 2 else if (conj >= 1 and ib == .extend) conj else 0;
    }
    return out;
}

fn ignorable(p: Wp) bool {
    return p == .extend or p == .format or p == .zwj;
}

fn lineBreakLike(p: Wp) bool {
    return p == .newline or p == .cr or p == .lf;
}

fn ahLetter(p: Wp) bool {
    return p == .aletter or p == .hebrew_letter;
}

fn midNumLetQ(p: Wp) bool {
    return p == .mid_num_let or p == .single_quote;
}

/// Index of the character a position stands for once Extend, Format and ZWJ are ignored (WB4).
fn effective(props: []const Wp, at: usize) usize {
    var j = at;
    while (j > 0 and ignorable(props[j]) and !lineBreakLike(props[j - 1])) j -= 1;
    return j;
}

/// Same convention as `graphemeBreaks`, for word boundaries.
pub fn wordBreaks(a: Allocator, cps: []const u32) Allocator.Error![]bool {
    const n = cps.len;
    const out = try a.alloc(bool, n + 1);
    @memset(out, false);
    if (n == 0) return out;
    out[0] = true;
    out[n] = true;
    const props = try a.alloc(Wp, n);
    for (cps, props) |cp, *p| p.* = wordProp(cp);
    for (1..n) |i| {
        const pp = props[i - 1];
        const np = props[i];
        out[i] = brk: {
            if (pp == .cr and np == .lf) break :brk false;
            if (lineBreakLike(pp) or lineBreakLike(np)) break :brk true;
            if (pp == .zwj and isExtPict(cps[i])) break :brk false;
            if (pp == .wseg_space and np == .wseg_space) break :brk false;
            if (ignorable(np)) break :brk false;
            const j = effective(props, i - 1);
            const p1 = props[j];
            const p2: ?Wp = if (j > 0) props[effective(props, j - 1)] else null;
            const n1 = np;
            var m = i + 1;
            while (m < n and ignorable(props[m])) m += 1;
            const n2: ?Wp = if (m < n) props[m] else null;
            if (ahLetter(p1) and ahLetter(n1)) break :brk false;
            if (ahLetter(p1) and (n1 == .mid_letter or midNumLetQ(n1)) and n2 != null and ahLetter(n2.?)) break :brk false;
            if (p2 != null and ahLetter(p2.?) and (p1 == .mid_letter or midNumLetQ(p1)) and ahLetter(n1)) break :brk false;
            if (p1 == .hebrew_letter and n1 == .single_quote) break :brk false;
            if (p1 == .hebrew_letter and n1 == .double_quote and n2 != null and n2.? == .hebrew_letter) break :brk false;
            if (p2 != null and p2.? == .hebrew_letter and p1 == .double_quote and n1 == .hebrew_letter) break :brk false;
            if (p1 == .numeric and n1 == .numeric) break :brk false;
            if (ahLetter(p1) and n1 == .numeric) break :brk false;
            if (p1 == .numeric and ahLetter(n1)) break :brk false;
            if (p2 != null and p2.? == .numeric and (p1 == .mid_num or midNumLetQ(p1)) and n1 == .numeric) break :brk false;
            if (p1 == .numeric and (n1 == .mid_num or midNumLetQ(n1)) and n2 != null and n2.? == .numeric) break :brk false;
            if (p1 == .katakana and n1 == .katakana) break :brk false;
            if ((ahLetter(p1) or p1 == .numeric or p1 == .katakana or p1 == .extend_num_let) and n1 == .extend_num_let) break :brk false;
            if (p1 == .extend_num_let and (ahLetter(n1) or n1 == .numeric or n1 == .katakana)) break :brk false;
            if (p1 == .regional_indicator and n1 == .regional_indicator) {
                var count: usize = 0;
                var k = j;
                while (true) {
                    if (props[k] != .regional_indicator) break;
                    count += 1;
                    if (k == 0) break;
                    const prev = effective(props, k - 1);
                    if (prev == k) break;
                    k = prev;
                }
                if (count % 2 == 1) break :brk false;
            }
            break :brk true;
        };
    }
    return out;
}

const Decoded = struct { cps: []u32, offsets: []usize };

fn decode(a: Allocator, text: []const u8) Allocator.Error!Decoded {
    var cps: std.ArrayList(u32) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const d = errors.decodeAt(text, i);
        try cps.append(a, d.cp);
        try offsets.append(a, i);
        i += d.len;
    }
    try offsets.append(a, text.len);
    return .{ .cps = cps.items, .offsets = offsets.items };
}

fn split(a: Allocator, text: []const u8, breaks: []const bool, d: Decoded) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (1..d.cps.len + 1) |i| {
        if (breaks[i]) {
            try out.append(a, text[d.offsets[start]..d.offsets[i]]);
            start = i;
        }
    }
    return out.items;
}

/// `[...new Intl.Segmenter().segment(text)]`
pub fn graphemes(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    const d = try decode(a, text);
    return split(a, text, try graphemeBreaks(a, d.cps), d);
}

/// `[...new Intl.Segmenter(undefined, { granularity: 'word' }).segment(text)]` without the dictionary scripts.
pub fn words(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    const d = try decode(a, text);
    return split(a, text, try wordBreaks(a, d.cps), d);
}

const grapheme_vectors = testdata.file("mermaid/unicode/GraphemeBreakTest.txt");
const word_vectors = testdata.file("mermaid/unicode/WordBreakTest.txt");

const Outcome = struct { count: usize = 0, failure: ?[]const u8 = null };

fn runVectors(a: Allocator, vectors: []const u8, comptime breaksFn: fn (Allocator, []const u32) Allocator.Error![]bool) !Outcome {
    var out: Outcome = .{};
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cps: std.ArrayList(u32) = .empty;
        var expect: std.ArrayList(bool) = .empty;
        var toks = std.mem.tokenizeAny(u8, line, " \t\r");
        while (toks.next()) |t| {
            if (std.mem.eql(u8, t, "\xc3\xb7")) {
                try expect.append(a, true);
            } else if (std.mem.eql(u8, t, "\xc3\x97")) {
                try expect.append(a, false);
            } else try cps.append(a, try std.fmt.parseInt(u32, t, 16));
        }
        const got = try breaksFn(a, cps.items);
        try std.testing.expectEqual(expect.items.len, got.len);
        for (expect.items, got) |e, g| {
            if (e != g) {
                out.failure = line;
                return out;
            }
        }
        out.count += 1;
    }
    return out;
}

test "grapheme clusters equal Unicode's GraphemeBreakTest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runVectors(arena.allocator(), grapheme_vectors, graphemeBreaks);
    if (r.failure) |line| {
        std.debug.print("vector mismatch: {s}\n", .{line});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(r.count > 700);
}

test "word boundaries equal Unicode's WordBreakTest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runVectors(arena.allocator(), word_vectors, wordBreaks);
    if (r.failure) |line| {
        std.debug.print("vector mismatch: {s}\n", .{line});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(r.count > 1800);
}

test "segments of text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try graphemes(a, "e\u{301}x\u{1F468}\u{200D}\u{1F469}\u{1F1FA}\u{1F1F8}");
    try std.testing.expectEqual(@as(usize, 4), g.len);
    const w = try words(a, "don't stop 3.14  now");
    try std.testing.expectEqual(@as(usize, 7), w.len);
    try std.testing.expectEqualStrings("don't", w[0]);
    try std.testing.expectEqualStrings("3.14", w[4]);
    try std.testing.expectEqualStrings("  ", w[5]);
}
