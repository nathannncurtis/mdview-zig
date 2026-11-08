const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const frontmatter = @import("frontmatter.zig");
const numfmt = @import("numfmt.zig");
const config = @import("config.zig");
const detect = @import("detect.zig");
const errors = @import("errors.zig");

const Value = config.Value;

pub const Processed = struct {
    /// The text with comments removed (`code.cleaned`).
    code: []const u8,
    /// The text before the comment lines were removed.
    with_comments: []const u8,
    frontmatter_line_offset: usize,
    title: ?[]const u8,
    config: Value,
};

pub const Result = union(enum) {
    ok: Processed,
    err: []const u8,
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isHSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == 0x0b or c == 0x0c;
}

// `^([^\S\n\r]*)-{3}\s*[\n\r](.*?)[\n\r]\1-{3}\s*[\n\r]+` with the dotall flag.
const FrontMatter = struct { indent: []const u8, body: []const u8, end: usize };

fn matchFrontMatter(text: []const u8) ?FrontMatter {
    var p: usize = 0;
    while (p < text.len and isHSpace(text[p])) p += 1;
    const indent = text[0..p];
    if (!std.mem.startsWith(u8, text[p..], "---")) return null;
    p += 3;
    const run_end = p + detect.skipSpace(text[p..]);
    var open_ends: [64]usize = undefined;
    var n: usize = 0;
    var k = p;
    while (k < run_end) : (k += 1) {
        if ((text[k] == '\n' or text[k] == '\r') and n < open_ends.len) {
            open_ends[n] = k + 1;
            n += 1;
        }
    }
    while (n > 0) {
        n -= 1;
        const body_start = open_ends[n];
        var e = body_start;
        while (e < text.len) : (e += 1) {
            if (text[e] != '\n' and text[e] != '\r') continue;
            const rest = text[e + 1 ..];
            if (!std.mem.startsWith(u8, rest, indent) or !std.mem.startsWith(u8, rest[indent.len..], "---")) continue;
            const after = e + 1 + indent.len + 3;
            const ws_end = after + detect.skipSpace(text[after..]);
            var last_nl: ?usize = null;
            var q = after;
            while (q < ws_end) : (q += 1) if (text[q] == '\n' or text[q] == '\r') {
                last_nl = q;
            };
            if (last_nl) |nl| return .{ .indent = indent, .body = text[body_start..e], .end = nl + 1 };
        }
    }
    return null;
}

const Directive = struct { start: usize, end: usize, type_text: []const u8, word_arg: ?[]const u8, json_arg: ?[]const u8 };

fn matchDirectiveAt(text: []const u8, at: usize) ?Directive {
    if (!std.mem.startsWith(u8, text[at..], "%%{")) return null;
    var p = at + 3;
    p += detect.skipSpace(text[p..]);
    const w_start = p;
    while (p < text.len and isWord(text[p])) p += 1;
    if (p == w_start) return null;
    const word = text[w_start..p];
    var type_text = word;
    var q = p + detect.skipSpace(text[p..]);
    if (q < text.len and text[q] == ':') {
        p = q + 1;
    } else q = p;
    p += detect.skipSpace(text[p..]);
    var word_arg: ?[]const u8 = null;
    var json_arg: ?[]const u8 = null;
    const a_start = p;
    while (p < text.len and isWord(text[p])) p += 1;
    if (p > a_start) {
        word_arg = text[a_start..p];
    } else {
        var j = p;
        while (j < text.len) {
            if (std.mem.startsWith(u8, text[j..], "}%%")) break;
            if (text[j] == '\r') {
                if (j + 1 < text.len and text[j + 1] == '\n') j += 2 else break;
                continue;
            }
            j += 1;
        }
        json_arg = text[a_start..j];
        p = j;
    }
    p += detect.skipSpace(text[p..]);
    if (std.mem.startsWith(u8, text[p..], "}%%")) p += 3;
    type_text = word;
    return .{ .start = at, .end = p, .type_text = type_text, .word_arg = word_arg, .json_arg = json_arg };
}

fn nextDirective(text: []const u8, from: usize) ?Directive {
    var i = from;
    while (std.mem.indexOfPos(u8, text, i, "%%{")) |at| {
        if (matchDirectiveAt(text, at)) |d| return d;
        i = at + 1;
    }
    return null;
}

fn removeDirectives(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (nextDirective(text, i)) |d| {
        try out.appendSlice(a, text[i..d.start]);
        i = if (d.end > d.start) d.end else d.start + 1;
    }
    try out.appendSlice(a, text[i..]);
    return out.items;
}

fn removeFrontMatter(text: []const u8) []const u8 {
    return if (matchFrontMatter(text)) |m| text[m.end..] else text;
}

// `/\s*%%.*\n/gm` replaced by a newline.
fn replaceAnyComments(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var copied: usize = 0;
    while (i < text.len) {
        const j = i + detect.skipSpace(text[i..]);
        if (std.mem.startsWith(u8, text[j..], "%%")) {
            var e = j + 2;
            while (e < text.len and text[e] != '\n' and text[e] != '\r') e += 1;
            if (e < text.len and text[e] == '\n') {
                try out.appendSlice(a, text[copied..i]);
                try out.append(a, '\n');
                i = e + 1;
                copied = i;
                continue;
            }
        }
        i = if (j > i) j else i + 1;
        if (j > i) i = j;
    }
    try out.appendSlice(a, text[copied..]);
    return out.items;
}

/// detectType's cleaning: front matter, directives and comments removed.
pub fn stripForDetection(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return replaceAnyComments(a, try removeDirectives(a, removeFrontMatter(text)));
}

// `/^\s*%%(?!{)[^\n]+\n?/gm` replaced by nothing, then trimStart.
fn cleanupComments(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var copied: usize = 0;
    while (i < text.len) {
        const at_line_start = i == 0 or text[i - 1] == '\n';
        if (at_line_start) {
            const j = i + detect.skipSpace(text[i..]);
            if (std.mem.startsWith(u8, text[j..], "%%") and !std.mem.startsWith(u8, text[j + 2 ..], "{")) {
                var e = j + 2;
                while (e < text.len and text[e] != '\n') e += 1;
                if (e > j + 2) {
                    try out.appendSlice(a, text[copied..i]);
                    if (e < text.len) e += 1;
                    i = e;
                    copied = e;
                    continue;
                }
            }
        }
        i += 1;
    }
    try out.appendSlice(a, text[copied..]);
    return detect.trimStart(out.items);
}

fn cleanupText(a: Allocator, code: []const u8) Allocator.Error![]const u8 {
    var norm: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        if (code[i] == '\r') {
            try norm.append(a, '\n');
            if (i + 1 < code.len and code[i + 1] == '\n') i += 1;
        } else try norm.append(a, code[i]);
    }
    const text = norm.items;
    var out: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < text.len) {
        if (text[i] == '<') {
            var j = i + 1;
            while (j < text.len and isWord(text[j])) j += 1;
            if (j > i + 1) {
                if (std.mem.indexOfScalarPos(u8, text, j, '>')) |gt| {
                    try out.appendSlice(a, text[i..j]);
                    try rewriteAttributes(a, &out, text[j..gt]);
                    try out.append(a, '>');
                    i = gt + 1;
                    continue;
                }
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

// attributes.replace(/="([^"]*)"/g, "='$1'")
fn rewriteAttributes(a: Allocator, out: *std.ArrayList(u8), attrs: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < attrs.len) {
        if (std.mem.startsWith(u8, attrs[i..], "=\"")) {
            if (std.mem.indexOfScalarPos(u8, attrs, i + 2, '"')) |close| {
                try out.appendSlice(a, "='");
                try out.appendSlice(a, attrs[i + 2 .. close]);
                try out.append(a, '\'');
                i = close + 1;
                continue;
            }
        }
        try out.append(a, attrs[i]);
        i += 1;
    }
}

fn dedent(a: Allocator, body: []const u8, indent: []const u8) Allocator.Error![]const u8 {
    if (indent.len == 0) return body;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, if (std.mem.startsWith(u8, l, indent)) l[indent.len..] else l);
    }
    return out.items;
}

/// `String(v)` for a truthy front matter value, null for a falsy one.
fn jsString(a: Allocator, v: Value) Allocator.Error!?[]const u8 {
    return switch (v) {
        .string => |t| if (t.len > 0) t else null,
        .integer => |n| if (n != 0) try std.fmt.allocPrint(a, "{d}", .{n}) else null,
        .float => |x| if (x != 0 and !std.math.isNan(x)) try numfmt.js(a, x) else null,
        .bool => |t| if (t) "true" else null,
        .array, .object => "[object Object]",
        else => null,
    };
}

const Front = struct { text: []const u8, title: ?[]const u8, config: Value, err: ?[]const u8 = null };

fn processFrontmatter(a: Allocator, code: []const u8) Allocator.Error!Front {
    const m = matchFrontMatter(code) orelse return .{ .text = code, .title = null, .config = config.newObject(a) };
    const body = try dedent(a, m.body, m.indent);
    var cfg = config.newObject(a);
    var title: ?[]const u8 = null;
    var display_mode: ?[]const u8 = null;
    switch (try frontmatter.load(a, body)) {
        .err => |message| return .{ .text = code[m.end..], .title = null, .config = cfg, .err = message },
        .ok => |v| if (v == .object) {
            if (v.object.get("displayMode")) |d| display_mode = try jsString(a, d);
            if (v.object.get("title")) |t| title = try jsString(a, t);
            if (v.object.get("config")) |c| if (c == .object) {
                cfg = c;
            };
        },
    }
    if (display_mode) |dm| {
        var gantt = if (cfg.object.get("gantt")) |g| (if (g == .object) g else config.newObject(a)) else config.newObject(a);
        try gantt.object.put(a, "displayMode", .{ .string = dm });
        try cfg.object.put(a, "gantt", gantt);
    }
    return .{ .text = code[m.end..], .title = title, .config = cfg };
}

const Kind = enum { init, wrap };

fn typeMatches(token: []const u8, comptime kind: Kind) bool {
    switch (kind) {
        .wrap => return std.mem.indexOf(u8, token, "wrap") != null,
        .init => return std.mem.endsWith(u8, token, "init") or std.mem.endsWith(u8, token, "initialize"),
    }
}

const Found = union(enum) { none, one: Directive, many: []const Directive, bad };

fn collectDirectives(a: Allocator, text: []const u8, comptime kind: Kind) Allocator.Error!Found {
    var list: std.ArrayList(Directive) = .empty;
    var i: usize = 0;
    while (nextDirective(text, i)) |d| {
        i = if (d.end > d.start) d.end else d.start + 1;
        if (typeMatches(d.type_text, kind)) try list.append(a, d);
    }
    if (list.items.len == 0) return .none;
    if (list.items.len == 1) return .{ .one = list.items[0] };
    return .{ .many = list.items };
}

// detectDirective's `commentWithoutDirectives` replace: `%%` followed by `}%%`, then `.*\n`. `.` stops at a carriage return
// and at U+2028 and U+2029, so the line has to end in a plain line feed for the match to hold.
fn dropEmptyDirectiveComments(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var copied: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "%%}%%")) |at| {
        var e = at + 2;
        const end: ?usize = while (e < text.len) : (e += 1) {
            const c = text[e];
            if (c == '\n') break e + 1;
            if (c == '\r') break null;
            if (c == 0xe2 and e + 2 < text.len and text[e + 1] == 0x80 and (text[e + 2] == 0xa8 or text[e + 2] == 0xa9)) break null;
        } else null;
        if (end) |stop| {
            try out.appendSlice(a, text[copied..at]);
            copied = stop;
            i = stop;
        } else i = at + 1;
    }
    try out.appendSlice(a, text[copied..]);
    return out.items;
}

fn quoteSwap(a: Allocator, text: []const u8) Allocator.Error![]u8 {
    const out = try a.dupe(u8, text);
    for (out) |*c| if (c.* == '\'') {
        c.* = '"';
    };
    return out;
}

const max_nesting = 64;

fn nestingTooDeep(s: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
        } else if (c == '"') in_string = true else if (c == '{' or c == '[') {
            depth += 1;
            if (depth > max_nesting) return true;
        } else if (c == '}' or c == ']') depth -|= 1;
    }
    return false;
}

fn directiveArgs(a: Allocator, d: Directive) Allocator.Error!?Value {
    if (d.word_arg) |w| return .{ .string = std.mem.trim(u8, w, " \t\r\n") };
    if (d.json_arg) |j| {
        const t = detect.trim(j);
        if (t.len == 0) return .null;
        if (nestingTooDeep(t)) return null;
        return json.parseFromSliceLeaky(Value, a, t, .{}) catch null;
    }
    return .null;
}

fn typeIsWrap(f: Found) bool {
    return switch (f) {
        .one => |d| typeMatches(d.type_text, .wrap),
        .many => |ds| blk: {
            for (ds) |d| if (typeMatches(d.type_text, .wrap)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

const Directives = struct { text: []const u8, config: Value, err: ?[]const u8 = null };

fn diagramKey(id: []const u8) []const u8 {
    return if (std.mem.eql(u8, id, "flowchart-v2")) "flowchart" else id;
}

fn processDirectives(a: Allocator, keys: *const std.StringHashMapUnmanaged(void), code: []const u8) config.Err!Directives {
    const stripped = try removeDirectives(a, code);
    const text = try quoteSwap(a, try dropEmptyDirectiveComments(a, detect.trim(code)));
    var init_cfg = config.newObject(a);
    var bad = false;
    var args_list: std.ArrayList(Value) = .empty;
    const inits = try collectDirectives(a, text, .init);
    switch (inits) {
        .none => {},
        .bad => bad = true,
        .one => |d| {
            const args = try directiveArgs(a, d);
            if (args) |v| {
                if (v == .object) init_cfg = v;
            } else bad = true;
        },
        .many => |ds| for (ds) |d| {
            const args = try directiveArgs(a, d);
            if (args) |v| try args_list.append(a, v) else bad = true;
        },
    }
    if (bad) init_cfg = config.newObject(a);
    const has_init = !bad and init_cfg.object.count() > 0;
    if (has_init or args_list.items.len > 0) {
        const cleaned = try stripForDetection(a, code);
        const id = detect.detect(cleaned, null) orelse return .{ .text = stripped, .config = init_cfg, .err = try errors.unknownDiagram(a, cleaned) };
        _ = id;
    }
    if (args_list.items.len > 0 and !bad) {
        var arr: json.Array = json.Array.init(a);
        for (args_list.items) |v| try arr.append(v);
        var as_value: Value = .{ .array = arr };
        try config.sanitizeDirective(a, keys, &as_value);
        try config.assignWithDepth(a, &init_cfg, as_value, 2);
    }

    if (init_cfg.object.get("config")) |c| {
        if (detect.detect(try stripForDetection(a, code), null)) |id| try init_cfg.object.put(a, diagramKey(id), c);
        _ = init_cfg.object.orderedRemove("config");
    }

    const wraps = try collectDirectives(a, text, .wrap);
    switch (wraps) {
        .many => |ds| {
            var any = false;
            for (ds) |d| if (typeMatches(d.type_text, .wrap)) {
                any = true;
            };
            try init_cfg.object.put(a, "wrap", .{ .bool = any });
        },
        else => if (typeIsWrap(wraps)) try init_cfg.object.put(a, "wrap", .{ .bool = true }),
    }
    return .{ .text = stripped, .config = init_cfg };
}

pub fn preprocess(a: Allocator, source: []const u8) config.Err!Result {
    const keys = try config.configKeys(a, try config.defaultTree(a), try @import("theme/theme.zig").compute(a, .default, &.{}));
    const cleaned = try cleanupText(a, source);
    const fm = try processFrontmatter(a, cleaned);
    if (fm.err) |message| return .{ .err = message };
    const dir = try processDirectives(a, &keys, fm.text);
    if (dir.err) |message| return .{ .err = message };
    var merged = config.newObject(a);
    try config.mergeDeep(a, &merged, fm.config);
    try config.mergeDeep(a, &merged, dir.config);
    const removed = cleaned.len - @min(cleaned.len, fm.text.len);
    const offset = std.mem.count(u8, cleaned[0..removed], "\n");
    return .{ .ok = .{
        .code = try cleanupComments(a, dir.text),
        .with_comments = dir.text,
        .frontmatter_line_offset = offset,
        .title = fm.title,
        .config = merged,
    } };
}

fn run(src: []const u8, a: Allocator) !Processed {
    return switch (try preprocess(a, src)) {
        .ok => |p| p,
        .err => error.TestUnexpectedResult,
    };
}

test "front matter, directives and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try run("---\ntitle: Hello\nconfig:\n  theme: forest\n---\n%% note\n%%{init: {\"theme\":\"neutral\"}}%%\ninfo\n", a);
    try std.testing.expectEqualStrings("info\n", p.code);
    try std.testing.expectEqualStrings("Hello", p.title.?);
    try std.testing.expectEqualStrings("neutral", p.config.object.get("theme").?.string);
    const q = try run("%%{init: {'theme':'dark'}}%%\ngraph TD\nA-->B", a);
    try std.testing.expectEqualStrings("dark", q.config.object.get("theme").?.string);
    try std.testing.expectEqualStrings("graph TD\nA-->B", q.code);
}

test "bad directive json is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try run("%%{init: {\"theme\":\"forest\", }}%%\ninfo", a);
    try std.testing.expectEqual(@as(u32, 0), p.config.object.count());
}

test "html attribute quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try run("graph TD\nA[<a href=\"x\">y</a>]", a);
    try std.testing.expectEqualStrings("graph TD\nA[<a href='x'>y</a>]", p.code);
}

fn lineEnd(text: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
}

// `/<keyword>.*:\S*#.*;/g` replaced by the match without its last character.
fn dropTrailingSemicolon(a: Allocator, text: []const u8, keyword: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const hit = std.mem.indexOfPos(u8, text, i, keyword) orelse break;
        const end = lineEnd(text, hit);
        const line = text[hit + keyword.len .. end];
        var cut: ?usize = null;
        if (std.mem.lastIndexOfScalar(u8, line, ';')) |semi| {
            var c: usize = 0;
            while (c < semi) : (c += 1) {
                if (line[c] != ':') continue;
                var h = c + 1;
                while (h < semi and line[h] != '#' and !std.ascii.isWhitespace(line[h])) h += 1;
                if (h < semi and line[h] == '#') {
                    cut = hit + keyword.len + semi;
                    break;
                }
            }
        }
        if (cut) |at| {
            try out.appendSlice(a, text[i..at]);
            i = at + 1;
        } else {
            try out.appendSlice(a, text[i .. hit + keyword.len]);
            i = hit + keyword.len;
        }
    }
    try out.appendSlice(a, text[i..]);
    return out.items;
}

/// utils.encodeEntities: protects `#35;` style entities from the diagram grammars.
pub fn encodeEntities(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const t1 = try dropTrailingSemicolon(a, text, "style");
    const t2 = try dropTrailingSemicolon(a, t1, "classDef");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t2.len) {
        if (t2[i] == '#') {
            var j = i + 1;
            while (j < t2.len and isWord(t2[j])) j += 1;
            if (j > i + 1 and j < t2.len and t2[j] == ';') {
                const inner = t2[i + 1 .. j];
                var digits = inner;
                if (digits[0] == '+') digits = digits[1..];
                var is_int = digits.len > 0;
                for (digits) |c| if (!std.ascii.isDigit(c)) {
                    is_int = false;
                };
                try out.appendSlice(a, if (is_int) "\u{fb02}\u{b0}\u{b0}" else "\u{fb02}\u{b0}");
                try out.appendSlice(a, inner);
                try out.appendSlice(a, "\u{b6}\u{df}");
                i = j + 1;
                continue;
            }
        }
        try out.append(a, t2[i]);
        i += 1;
    }
    return out.items;
}

/// utils.decodeEntities, applied to the finished SVG.
pub fn decodeEntities(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const s1 = try std.mem.replaceOwned(u8, a, text, "\u{fb02}\u{b0}\u{b0}", "&#");
    const s2 = try std.mem.replaceOwned(u8, a, s1, "\u{fb02}\u{b0}", "&");
    return std.mem.replaceOwned(u8, a, s2, "\u{b6}\u{df}", ";");
}

test "entities round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = try encodeEntities(a, "A[a #35; b #quot; c]");
    try std.testing.expect(std.mem.indexOf(u8, enc, "#35;") == null);
    try std.testing.expectEqualStrings("A[a &#35; b &quot; c]", try decodeEntities(a, enc));
    try std.testing.expectEqualStrings("style a fill:#faa", try encodeEntities(a, "style a fill:#faa;"));
}
