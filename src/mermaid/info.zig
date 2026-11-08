const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const svg = @import("svg.zig");
const core = @import("diagram.zig");

// The `info` diagram: a Langium grammar in mermaid (InfoGrammar), here a hand-written lexer and parser with
// Chevrotain's error behaviour, and the d3 renderer that prints the version.

const Kind = enum { info, show_info, newline, acc_descr, acc_title, title, eof };

const Token = struct { kind: Kind, start: usize, len: usize, line: usize, column: usize };

fn isHs(c: u16) bool {
    return c == ' ' or c == '\t';
}

fn isWordChar(c: u16) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn startsWith16(s: []const u16, at: usize, lit: []const u8) bool {
    if (at + lit.len > s.len) return false;
    for (lit, 0..) |c, i| if (s[at + i] != c) return false;
    return true;
}

fn skipHs(s: []const u16, at: usize) usize {
    var i = at;
    while (i < s.len and isHs(s[i])) i += 1;
    return i;
}

fn isSpace16(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c or c == 0xa0 or c == 0xfeff or c == 0x2028 or c == 0x2029 or (c >= 0x2000 and c <= 0x200a) or c == 0x1680 or c == 0x202f or c == 0x205f or c == 0x3000;
}

/// Up to the first `%%` on the line, else the end of the line.
fn restOfLine(s: []const u16, at: usize) usize {
    var i = at;
    while (i < s.len and s[i] != '\n' and s[i] != '\r') : (i += 1) {
        if (s[i] == '%' and i + 1 < s.len and s[i + 1] == '%') return i;
    }
    return i;
}

fn keyword(s: []const u16, at: usize, lit: []const u8) usize {
    if (!startsWith16(s, at, lit)) return 0;
    const end = at + lit.len;
    if (end < s.len and isWordChar(s[end])) return 0;
    return lit.len;
}

fn accDescr(s: []const u16, at: usize) usize {
    const p = skipHs(s, at);
    if (!startsWith16(s, p, "accDescr")) return 0;
    var q = p + "accDescr".len;
    const after_hs = skipHs(s, q);
    if (after_hs < s.len and s[after_hs] == ':') return restOfLine(s, after_hs + 1) - at;
    while (q < s.len and isSpace16(s[q])) q += 1;
    if (q < s.len and s[q] == '{') {
        var e = q + 1;
        while (e < s.len and s[e] != '}') e += 1;
        if (e < s.len) return e + 1 - at;
    }
    return 0;
}

fn accTitle(s: []const u16, at: usize) usize {
    const p = skipHs(s, at);
    if (!startsWith16(s, p, "accTitle")) return 0;
    const q = skipHs(s, p + "accTitle".len);
    if (q < s.len and s[q] == ':') return restOfLine(s, q + 1) - at;
    return 0;
}

fn titleToken(s: []const u16, at: usize) usize {
    const p = skipHs(s, at);
    if (!startsWith16(s, p, "title")) return 0;
    const q = p + "title".len;
    if (q < s.len and isHs(s[q])) return restOfLine(s, q + 1) - at;
    return q - at;
}

fn yamlToken(s: []const u16, at: usize) usize {
    if (!startsWith16(s, at, "---")) return 0;
    var p = skipHs(s, at + 3);
    if (p < s.len and s[p] == '\r') p += 1;
    if (p >= s.len or s[p] != '\n') return 0;
    p += 1;
    var i = p;
    while (i <= s.len) : (i += 1) {
        const line_start = i == p or (i > 0 and s[i - 1] == '\n');
        if (line_start and startsWith16(s, i, "---")) {
            const e = i + 3;
            if (e >= s.len) return e - at;
            if (s[e] == '\n') return e + 1 - at;
            if (s[e] == '\r' and e + 1 < s.len and s[e + 1] == '\n') return e + 2 - at;
            if (isSpace16(s[e])) return e - at;
        }
        if (i == s.len) break;
    }
    return 0;
}

fn directiveToken(s: []const u16, at: usize) usize {
    const p = skipHs(s, at);
    if (!startsWith16(s, p, "%%{")) return 0;
    var i = p + 3;
    while (i + 3 <= s.len) : (i += 1) {
        if (startsWith16(s, i, "}%%")) {
            const e = i + 3;
            if (e >= s.len) return e - at;
            if (s[e] == '\n') return e + 1 - at;
            if (s[e] == '\r' and e + 1 < s.len and s[e + 1] == '\n') return e + 2 - at;
            if (isSpace16(s[e])) return e - at;
        }
    }
    return 0;
}

fn commentToken(s: []const u16, at: usize) usize {
    const p = skipHs(s, at);
    if (!startsWith16(s, p, "%%")) return 0;
    var e = p + 2;
    while (e < s.len and s[e] != '\n' and s[e] != '\r') e += 1;
    return e - at;
}

fn newlineToken(s: []const u16, at: usize) usize {
    if (at < s.len and s[at] == '\n') return 1;
    if (at + 1 < s.len and s[at] == '\r' and s[at + 1] == '\n') return 2;
    return 0;
}

const Matched = struct { kind: ?Kind, len: usize };

fn matchAt(s: []const u16, at: usize) Matched {
    if (keyword(s, at, "info") > 0) return .{ .kind = .info, .len = 4 };
    if (keyword(s, at, "showInfo") > 0) return .{ .kind = .show_info, .len = 8 };
    const nl = newlineToken(s, at);
    if (nl > 0) return .{ .kind = .newline, .len = nl };
    const ad = accDescr(s, at);
    if (ad > 0) return .{ .kind = .acc_descr, .len = ad };
    const at_ = accTitle(s, at);
    if (at_ > 0) return .{ .kind = .acc_title, .len = at_ };
    const ti = titleToken(s, at);
    if (ti > 0) return .{ .kind = .title, .len = ti };
    var hidden: usize = 0;
    while (at + hidden < s.len and isHs(s[at + hidden])) hidden += 1;
    if (hidden > 0) return .{ .kind = null, .len = hidden };
    const y = yamlToken(s, at);
    if (y > 0) return .{ .kind = null, .len = y };
    const d = directiveToken(s, at);
    if (d > 0) return .{ .kind = null, .len = d };
    const c = commentToken(s, at);
    if (c > 0) return .{ .kind = null, .len = c };
    return .{ .kind = null, .len = 0 };
}

const Pos = struct { line: usize, column: usize };

const LineIndex = struct {
    starts: std.ArrayList(usize) = .empty,

    fn build(a: Allocator, s: []const u16) Allocator.Error!LineIndex {
        var li: LineIndex = .{};
        try li.starts.append(a, 0);
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\n') {
                try li.starts.append(a, i + 1);
            } else if (s[i] == '\r') {
                if (i + 1 < s.len and s[i + 1] == '\n') i += 1;
                try li.starts.append(a, i + 1);
            }
        }
        return li;
    }

    fn pos(li: *const LineIndex, offset: usize) Pos {
        var lo: usize = 0;
        var hi = li.starts.items.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (li.starts.items[mid] <= offset) lo = mid else hi = mid;
        }
        return .{ .line = lo + 1, .column = offset - li.starts.items[lo] + 1 };
    }
};

pub const Parsed = struct {};

fn tokenImage(a: Allocator, s: []const u16, t: Token) Allocator.Error![]const u8 {
    return errors.fromUtf16(a, s[t.start .. t.start + t.len]);
}

fn parseText(a: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const s = try errors.toUtf16(a, text);
    const li = try LineIndex.build(a, s);
    var tokens: std.ArrayList(Token) = .empty;
    var lex_errors: std.ArrayList(errors.LangiumError) = .empty;
    var off: usize = 0;
    while (off < s.len) {
        const m = matchAt(s, off);
        if (m.len > 0) {
            if (m.kind) |k| {
                const p = li.pos(off);
                try tokens.append(a, .{ .kind = k, .start = off, .len = m.len, .line = p.line, .column = p.column });
            }
            off += m.len;
            continue;
        }
        const start = off;
        var skipped: usize = 0;
        while (off < s.len and (skipped == 0 or matchAt(s, off).len == 0)) {
            skipped += 1;
            off += 1;
        }
        const p = li.pos(start);
        const ch = try errors.fromUtf16(a, s[start .. start + 1]);
        try lex_errors.append(a, .{
            .pos = .{ .line = p.line, .column = p.column },
            .message = try std.fmt.allocPrint(a, "unexpected character: ->{s}<- at offset: {d}, skipped {d} characters.", .{ ch, start, skipped }),
        });
    }
    try tokens.append(a, .{ .kind = .eof, .start = s.len, .len = 0, .line = 0, .column = 0 });

    var parse_errors: std.ArrayList(errors.LangiumError) = .empty;
    var i: usize = 0;
    const toks = tokens.items;
    while (toks[i].kind == .newline) i += 1;
    if (toks[i].kind == .info) {
        i += 1;
    } else {
        try parse_errors.append(a, .{
            .pos = tokenPos(toks[i]),
            .message = try std.fmt.allocPrint(a, "Expecting token of type 'info' but found `{s}`.", .{try tokenImage(a, s, toks[i])}),
        });
    }
    while (toks[i].kind == .newline) i += 1;
    if (toks[i].kind == .show_info) {
        i += 1;
        while (toks[i].kind == .newline) i += 1;
    }
    var bad_eol = false;
    while (toks[i].kind == .acc_descr or toks[i].kind == .acc_title or toks[i].kind == .title) {
        i += 1;
        if (toks[i].kind == .newline) {
            while (toks[i].kind == .newline) i += 1;
        } else if (toks[i].kind != .eof) {
            bad_eol = true;
            try parse_errors.append(a, .{
                .pos = tokenPos(toks[i]),
                .message = try std.fmt.allocPrint(a, "Expecting: one of these possible Token sequences:\n  1. [NEWLINE]\n  2. [EOF]\nbut found: '{s}'", .{try tokenImage(a, s, toks[i])}),
            });
            break;
        }
    }
    if (toks[i].kind != .eof and !bad_eol) {
        try parse_errors.append(a, .{
            .pos = tokenPos(toks[i]),
            .message = try std.fmt.allocPrint(a, "Expecting end of file but found `{s}`.", .{try tokenImage(a, s, toks[i])}),
        });
    }
    if (lex_errors.items.len == 0 and parse_errors.items.len == 0) return null;
    return try errors.langiumFailed(a, lex_errors.items, parse_errors.items);
}

fn tokenPos(t: Token) errors.Position {
    return if (t.kind == .eof) .{} else .{ .line = t.line, .column = t.column };
}

fn parse(ctx: *core.Ctx, source: []const u8) core.Error!*anyopaque {
    if (try parseText(ctx.a, source)) |message| {
        ctx.err_msg = message;
        return error.Parse;
    }
    const model = try ctx.a.create(Parsed);
    model.* = .{};
    return model;
}

fn layout(_: *core.Ctx, model: *anyopaque) core.Error!*anyopaque {
    return model;
}

fn emit(ctx: *core.Ctx, _: *anyopaque, _: *anyopaque, w: *svg.SvgWriter) core.Error!void {
    try w.configureSvgSize(100, 400, true);
    try w.start("g", &.{});
    const label = try std.fmt.allocPrint(w.a, "v{s}", .{ctx.version});
    try w.textElement("text", &.{
        .{ .name = "x", .value = "100" },
        .{ .name = "y", .value = "40" },
        .{ .name = "class", .value = "version" },
        .{ .name = "font-size", .value = "32" },
        .{ .name = "style", .value = "text-anchor: middle;" },
    }, label);
    try w.end();
}

pub const def: core.Def = .{ .id = "info", .parse = parse, .layout = layout, .emit = emit };

fn expectParse(src: []const u8, want: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try parseText(arena.allocator(), src);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(w, got.?);
    } else try std.testing.expectEqual(@as(?[]const u8, null), got);
}

test "info grammar accepts and rejects like mermaid" {
    try expectParse("info\n", null);
    try expectParse("info showInfo\n", null);
    try expectParse("\n\ninfo\ntitle abc\n", null);
    try expectParse("info\naccDescr {\n x\n}\n", null);
    try expectParse("info foo\n", "Parsing failed: Lexer error on line 1, column 6: unexpected character: ->f<- at offset: 5, skipped 3 characters. ");
    try expectParse("infox\n", "Parsing failed: Lexer error on line 1, column 1: unexpected character: ->i<- at offset: 0, skipped 5 characters. Parse error on line ?, column ?: Expecting token of type 'info' but found ``.");
    try expectParse("info\ninfo\n", "Parsing failed:  Parse error on line 2, column 1: Expecting end of file but found `info`.");
    try expectParse("info\ntitles\n", "Parsing failed: Lexer error on line 2, column 6: unexpected character: ->s<- at offset: 10, skipped 1 characters. ");
}
