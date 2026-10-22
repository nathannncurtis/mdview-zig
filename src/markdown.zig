const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BlockKind = enum { h1, h2, h3, paragraph, code_block, blockquote, hr, list_item, blank };

/// Byte offset and length within `Inline.text`.
pub const Span = [2]u32;

pub const Inline = struct {
    text: []const u8 = "",
    bold: []const Span = &.{},
    italic: []const Span = &.{},
    code: []const Span = &.{},
};

pub const Block = struct {
    kind: BlockKind,
    content: Inline = .{},
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []const Block = &.{},

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(gpa: Allocator, markdown: []const u8) Allocator.Error!Document {
    var doc: Document = .{ .arena = .init(gpa) };
    errdefer doc.arena.deinit();
    var p: Parser = .{ .a = doc.arena.allocator() };
    try p.run(markdown);
    doc.blocks = try p.finish();
    return doc;
}

const Range = struct { lo: u32, hi: u32 };

const RawInline = struct {
    text: Range,
    bold: Range,
    italic: Range,
    code: Range,
};

const RawBlock = struct {
    kind: BlockKind,
    content: RawInline,
};

// Everything is stored as offsets while parsing, because the lists reallocate;
// slices are only built in finish().
const Parser = struct {
    a: Allocator,
    text: std.ArrayList(u8) = .empty,
    bold: std.ArrayList(Span) = .empty,
    italic: std.ArrayList(Span) = .empty,
    code: std.ArrayList(Span) = .empty,
    blocks: std.ArrayList(RawBlock) = .empty,

    fn run(p: *Parser, markdown: []const u8) Allocator.Error!void {
        var in_code = false;
        var code_start: u32 = 0;
        var lines = std.mem.splitScalar(u8, markdown, '\n');

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (std.mem.startsWith(u8, line, "```")) {
                if (in_code) {
                    try p.addBlock(.code_block, p.textFrom(code_start));
                    in_code = false;
                } else {
                    in_code = true;
                    code_start = p.textLen();
                }
                continue;
            }

            if (in_code) {
                try p.text.appendSlice(p.a, line);
                try p.text.append(p.a, '\n');
                continue;
            }

            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "***") or std.mem.startsWith(u8, line, "___")) {
                try p.addBlock(.hr, p.textFrom(p.textLen()));
                continue;
            }

            if (std.mem.startsWith(u8, line, "### ")) {
                try p.addInlineBlock(.h3, line[4..]);
            } else if (std.mem.startsWith(u8, line, "## ")) {
                try p.addInlineBlock(.h2, line[3..]);
            } else if (std.mem.startsWith(u8, line, "# ")) {
                try p.addInlineBlock(.h1, line[2..]);
            } else if (std.mem.startsWith(u8, line, "> ")) {
                try p.addInlineBlock(.blockquote, line[2..]);
            } else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
                try p.addInlineBlock(.list_item, line[2..]);
            } else if (line.len > 2 and line[0] >= '0' and line[0] <= '9' and std.mem.indexOf(u8, line, ". ") != null) {
                const dot = std.mem.indexOf(u8, line, ". ").?;
                try p.addInlineBlock(.list_item, line[dot + 2 ..]);
            } else if (std.mem.startsWith(u8, line, "<")) {
                continue;
            } else {
                try p.addInlineBlock(.paragraph, line);
            }
        }
    }

    fn finish(p: *Parser) Allocator.Error![]const Block {
        const out = try p.a.alloc(Block, p.blocks.items.len);
        for (out, p.blocks.items) |*b, raw| {
            b.* = .{ .kind = raw.kind, .content = p.resolve(raw.content) };
        }
        return out;
    }

    fn resolve(p: *const Parser, r: RawInline) Inline {
        return .{
            .text = p.text.items[r.text.lo..r.text.hi],
            .bold = p.bold.items[r.bold.lo..r.bold.hi],
            .italic = p.italic.items[r.italic.lo..r.italic.hi],
            .code = p.code.items[r.code.lo..r.code.hi],
        };
    }

    fn textLen(p: *const Parser) u32 {
        return @intCast(p.text.items.len);
    }

    fn textFrom(p: *const Parser, start: u32) RawInline {
        const b: u32 = @intCast(p.bold.items.len);
        const i: u32 = @intCast(p.italic.items.len);
        const c: u32 = @intCast(p.code.items.len);
        return .{
            .text = .{ .lo = start, .hi = p.textLen() },
            .bold = .{ .lo = b, .hi = b },
            .italic = .{ .lo = i, .hi = i },
            .code = .{ .lo = c, .hi = c },
        };
    }

    fn addBlock(p: *Parser, kind: BlockKind, content: RawInline) Allocator.Error!void {
        try p.blocks.append(p.a, .{ .kind = kind, .content = content });
    }

    fn addInlineBlock(p: *Parser, kind: BlockKind, raw: []const u8) Allocator.Error!void {
        try p.addBlock(kind, try p.parseInline(raw));
    }

    fn parseInline(p: *Parser, raw: []const u8) Allocator.Error!RawInline {
        var r = p.textFrom(p.textLen());
        const start = r.text.lo;
        var i: usize = 0;
        while (i < raw.len) {
            if (i + 1 < raw.len and raw[i] == '*' and raw[i + 1] == '*') {
                if (std.mem.indexOf(u8, raw[i + 2 ..], "**")) |e| {
                    try p.bold.append(p.a, .{ p.textLen() - start, @intCast(e) });
                    try p.text.appendSlice(p.a, raw[i + 2 ..][0..e]);
                    i += e + 4;
                    continue;
                }
            }
            if (raw[i] == '*' and (i + 1 >= raw.len or raw[i + 1] != '*')) {
                if (std.mem.indexOfScalarPos(u8, raw, i + 1, '*')) |e| {
                    try p.italic.append(p.a, .{ p.textLen() - start, @intCast(e - i - 1) });
                    try p.text.appendSlice(p.a, raw[i + 1 .. e]);
                    i = e + 1;
                    continue;
                }
            }
            if (raw[i] == '`') {
                if (std.mem.indexOfScalarPos(u8, raw, i + 1, '`')) |e| {
                    try p.code.append(p.a, .{ p.textLen() - start, @intCast(e - i - 1) });
                    try p.text.appendSlice(p.a, raw[i + 1 .. e]);
                    i = e + 1;
                    continue;
                }
            }
            if (raw[i] == '!' and i + 1 < raw.len and raw[i + 1] == '[') {
                if (parseLinkOrImage(raw, i + 1)) |result| {
                    try p.text.appendSlice(p.a, result.text);
                    i = result.end;
                    continue;
                }
            }
            if (raw[i] == '[') {
                if (parseLinkOrImage(raw, i)) |result| {
                    try p.text.appendSlice(p.a, result.text);
                    i = result.end;
                    continue;
                }
            }
            try p.text.append(p.a, raw[i]);
            i += 1;
        }
        r.text.hi = p.textLen();
        r.bold.hi = @intCast(p.bold.items.len);
        r.italic.hi = @intCast(p.italic.items.len);
        r.code.hi = @intCast(p.code.items.len);
        return r;
    }
};

const LinkResult = struct { text: []const u8, end: usize };

fn parseLinkOrImage(raw: []const u8, start: usize) ?LinkResult {
    if (start >= raw.len or raw[start] != '[') return null;
    var depth: i32 = 0;
    var j = start;
    while (j < raw.len) : (j += 1) {
        if (raw[j] == '[') depth += 1;
        if (raw[j] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (j >= raw.len) return null;
    const bracket_end = j;
    if (bracket_end + 1 >= raw.len or raw[bracket_end + 1] != '(') return null;
    var paren_depth: i32 = 0;
    var k = bracket_end + 1;
    while (k < raw.len) : (k += 1) {
        if (raw[k] == '(') paren_depth += 1;
        if (raw[k] == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) break;
        }
    }
    if (k >= raw.len) return null;
    return .{ .text = raw[start + 1 .. bracket_end], .end = k + 1 };
}

/// UTF-16 code unit count of `text[0..byte_offset]`, for APIs that index text in UTF-16.
pub fn utf16Offset(text: []const u8, byte_offset: u32) u32 {
    var cursor: Utf16Cursor = .{ .text = text };
    return cursor.at(byte_offset);
}

/// Maps increasing byte offsets to UTF-16 offsets in one pass over the text.
pub const Utf16Cursor = struct {
    text: []const u8,
    byte: usize = 0,
    unit: u32 = 0,

    pub fn at(self: *Utf16Cursor, byte_offset: usize) u32 {
        const end = @min(byte_offset, self.text.len);
        if (end < self.byte) self.* = .{ .text = self.text };
        while (self.byte < end) : (self.byte += 1) {
            const b = self.text[self.byte];
            if (b & 0xC0 != 0x80) self.unit += if (b >= 0xF0) 2 else 1;
        }
        return self.unit;
    }
};

// Syntax highlighting helpers (used by platform renderers)
pub const hl_keywords = [_][]const u8{
    "fn",       "const",    "var",      "return",   "if",       "else",
    "while",    "for",      "break",    "continue", "switch",   "pub",
    "struct",   "enum",     "union",    "defer",    "try",      "catch",
    "import",   "export",   "default",  "async",    "await",    "class",
    "function", "let",      "def",      "self",     "true",     "false",
    "null",     "undefined", "None",    "True",     "False",    "nil",
    "use",      "mod",      "impl",     "trait",    "type",     "match",
    "mut",      "ref",      "unsafe",   "move",     "static",   "extern",
    "crate",    "super",    "where",    "yield",    "from",     "with",
    "as",       "in",       "not",      "and",      "or",       "pass",
    "raise",    "except",   "finally",  "lambda",   "elif",     "del",
    "global",   "nonlocal", "assert",   "package",  "chan",     "go",
    "select",   "fallthrough", "range", "interface", "map",     "func",
    "void",     "int",      "float",    "double",   "char",     "bool",
    "string",   "println",  "printf",   "print",
};

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '@';
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

const testing = std.testing;

test "1500 paragraphs are all retained" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..1500) |n| try src.print(testing.allocator, "Paragraph {d}\n\n", .{n});

    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1500), doc.blocks.len);
    try testing.expectEqualStrings("Paragraph 0", doc.blocks[0].content.text);
    try testing.expectEqualStrings("Paragraph 1499", doc.blocks[1499].content.text);
}

test "text larger than 256 KiB is retained" {
    const line_len = 1000;
    const lines = 400;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "```\n");
    for (0..lines) |_| {
        try src.appendNTimes(testing.allocator, 'x', line_len);
        try src.append(testing.allocator, '\n');
    }
    try src.appendSlice(testing.allocator, "```\nafter the code block\n");

    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(BlockKind.code_block, doc.blocks[0].kind);
    try testing.expectEqual(@as(usize, lines * (line_len + 1)), doc.blocks[0].content.text.len);
    try testing.expect(doc.blocks[0].content.text.len > 256 * 1024);
    try testing.expectEqualStrings("after the code block", doc.blocks[1].content.text);
}

test "more than 16 bold spans in one block" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..40) |n| try src.print(testing.allocator, "**b{d}** ", .{n});

    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    const content = doc.blocks[0].content;
    try testing.expectEqual(@as(usize, 40), content.bold.len);
    const last = content.bold[39];
    try testing.expectEqualStrings("b39", content.text[last[0]..][0..last[1]]);
}

test "reparse frees the previous document" {
    var doc = try parse(testing.allocator, "# one\n\ntwo *three*\n");
    doc.deinit();
    doc = try parse(testing.allocator, "four `five`\n");
    defer doc.deinit();
    try testing.expectEqualStrings("four five", doc.blocks[0].content.text);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].content.code.len);
}

test "utf16 offsets count surrogate pairs" {
    const text = "aé😀b";
    try testing.expectEqual(@as(u32, 1), utf16Offset(text, 1));
    try testing.expectEqual(@as(u32, 2), utf16Offset(text, 3));
    try testing.expectEqual(@as(u32, 4), utf16Offset(text, 7));
    var cursor: Utf16Cursor = .{ .text = text };
    try testing.expectEqual(@as(u32, 4), cursor.at(7));
    try testing.expectEqual(@as(u32, 1), cursor.at(1));
}
