const std = @import("std");
const Allocator = std.mem.Allocator;

pub const dashes_message = "Diagrams beginning with --- are not valid. If you were trying to use a YAML front-matter, please ensure that you've correctly opened and closed the YAML front-matter with un-indented `---` blocks";
pub const timeout_message = "Diagram took too long to render";
pub const too_large_message = "Diagram is too large to render";

pub const Decoded = struct { cp: u21, len: usize };

/// One code point of possibly malformed UTF-8; a bad sequence is U+FFFD and consumes one byte.
pub fn decodeAt(s: []const u8, i: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + len > s.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// JS string length of UTF-8 text.
pub fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        n += if (d.cp > 0xffff) 2 else 1;
        i += d.len;
    }
    return n;
}

pub fn toUtf16(a: Allocator, s: []const u8) Allocator.Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (d.cp > 0xffff) {
            const v = d.cp - 0x10000;
            try out.append(a, @intCast(0xd800 + (v >> 10)));
            try out.append(a, @intCast(0xdc00 + (v & 0x3ff)));
        } else try out.append(a, @intCast(d.cp));
        i += d.len;
    }
    return out.items;
}

/// UTF-16 back to UTF-8; a lone surrogate becomes U+FFFD.
pub fn fromUtf16(a: Allocator, s: []const u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i < s.len) {
        var cp: u21 = s[i];
        if (cp >= 0xd800 and cp < 0xdc00 and i + 1 < s.len and s[i + 1] >= 0xdc00 and s[i + 1] < 0xe000) {
            cp = 0x10000 + ((cp - 0xd800) << 10) + (s[i + 1] - 0xdc00);
            i += 1;
        } else if (cp >= 0xd800 and cp < 0xe000) cp = 0xfffd;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        try out.appendSlice(a, buf[0..n]);
        i += 1;
    }
    return out.items;
}

fn stripNewlines(a: Allocator, s: []const u16) Allocator.Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    for (s) |c| if (c != '\n') try out.append(a, c);
    return out.items;
}

/// jison-lex `showPosition()`: up to 20 characters of past input, up to 20 of upcoming input, then a caret line.
/// `past` is the matched text before the current match, `match` the current match, `rest` the unread input.
pub fn showPosition(a: Allocator, past: []const u8, match: []const u8, rest: []const u8) Allocator.Error![]const u8 {
    const past16 = try toUtf16(a, past);
    const match16 = try toUtf16(a, match);
    const rest16 = try toUtf16(a, rest);

    var pre: std.ArrayList(u16) = .empty;
    if (past16.len > 20) for ("...") |c| try pre.append(a, c);
    const tail = past16[past16.len -| 20..];
    try pre.appendSlice(a, try stripNewlines(a, tail));

    var next: std.ArrayList(u16) = .empty;
    try next.appendSlice(a, match16);
    if (next.items.len < 20) try next.appendSlice(a, rest16[0..@min(rest16.len, 20 - next.items.len)]);
    var up: std.ArrayList(u16) = .empty;
    try up.appendSlice(a, next.items[0..@min(next.items.len, 20)]);
    if (next.items.len > 20) for ("...") |c| try up.append(a, c);

    const pre_text = try fromUtf16(a, pre.items);
    const up_text = try fromUtf16(a, try stripNewlines(a, up.items));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, pre_text);
    try out.appendSlice(a, up_text);
    try out.append(a, '\n');
    try out.appendNTimes(a, '-', pre.items.len);
    try out.append(a, '^');
    return out.items;
}

/// jison's `parseError` for a parse failure.
pub fn jisonParseError(a: Allocator, yylineno: usize, position: []const u8, expected: []const []const u8, got: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Parse error on line {d}:\n{s}\nExpecting ", .{ yylineno + 1, position });
    for (expected, 0..) |e, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, e);
    }
    try out.print(a, ", got '{s}'", .{got});
    return out.items;
}

/// jison-lex's lexer `parseError`.
pub fn jisonLexicalError(a: Allocator, yylineno: usize, position: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "Lexical error on line {d}. Unrecognized text.\n{s}", .{ yylineno + 1, position });
}

pub fn unknownDiagram(a: Allocator, cleaned_text: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(a, u8, &.{ "No diagram type detected matching given configuration for text: ", cleaned_text });
}

pub const Position = struct { line: ?usize = null, column: ?usize = null };

pub const LangiumError = struct { pos: Position, message: []const u8 };

/// MermaidParseError's message: lexer errors, then parser errors, joined by a space.
pub fn langiumFailed(a: Allocator, lexer: []const LangiumError, parser: []const LangiumError) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "Parsing failed: ");
    for (lexer, 0..) |e, i| {
        if (i > 0) try out.append(a, '\n');
        try out.appendSlice(a, "Lexer error on line ");
        try writePos(a, &out, e.pos);
        try out.appendSlice(a, e.message);
    }
    try out.append(a, ' ');
    for (parser, 0..) |e, i| {
        if (i > 0) try out.append(a, '\n');
        try out.appendSlice(a, "Parse error on line ");
        try writePos(a, &out, e.pos);
        try out.appendSlice(a, e.message);
    }
    return out.items;
}

fn writePos(a: Allocator, out: *std.ArrayList(u8), p: Position) Allocator.Error!void {
    if (p.line) |l| try out.print(a, "{d}", .{l}) else try out.append(a, '?');
    try out.appendSlice(a, ", column ");
    if (p.column) |c| try out.print(a, "{d}", .{c}) else try out.append(a, '?');
    try out.appendSlice(a, ": ");
}

test "showPosition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("abcdefghi\n---^", try showPosition(a, "abc", "def", "ghi"));
    try std.testing.expectEqualStrings("...01234567890123456789\n-----------------------^", try showPosition(a, "x0123456789012345678901234567890123456789", "", ""));
}

test "parse error text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = try jisonParseError(a, 0, "mindmap root((mind\n^", &.{ "'open_directive'", "'NEWLINE'" }, "ALPHA");
    try std.testing.expectEqualStrings("Parse error on line 1:\nmindmap root((mind\n^\nExpecting 'open_directive', 'NEWLINE', got 'ALPHA'", msg);
}

test "langium message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = try langiumFailed(a, &.{.{ .pos = .{ .line = 1, .column = 6 }, .message = "unexpected character: ->f<- at offset: 5, skipped 3 characters." }}, &.{});
    try std.testing.expectEqualStrings("Parsing failed: Lexer error on line 1, column 6: unexpected character: ->f<- at offset: 5, skipped 3 characters. ", msg);
}
