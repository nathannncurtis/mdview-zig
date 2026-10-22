const std = @import("std");
const Allocator = std.mem.Allocator;
const inl = @import("inline.zig");
const highlight = @import("highlight.zig");

pub const BlockKind = enum { h1, h2, h3, paragraph, code_block, blockquote, hr, list_item, table, blank };

/// Byte offset and length within `Inline.text`.
pub const Span = [2]u32;

pub const Inline = struct {
    text: []const u8 = "",
    bold: []const Span = &.{},
    italic: []const Span = &.{},
    code: []const Span = &.{},
    strike: []const Span = &.{},
    emoji: []const Span = &.{},
};

pub const Align = enum { none, left, center, right };

pub const Table = struct {
    columns: usize = 0,
    aligns: []const Align = &.{},
    /// Row-major; row 0 is the header. Every row has exactly `columns` cells.
    cells: []const Inline = &.{},

    pub fn rows(t: Table) usize {
        return if (t.columns == 0) 0 else t.cells.len / t.columns;
    }

    pub fn cell(t: Table, row: usize, col: usize) Inline {
        return t.cells[row * t.columns + col];
    }
};

pub const Block = struct {
    kind: BlockKind,
    lang: []const u8 = "",
    tokens: []const highlight.Token = &.{},
    content: Inline = .{},
    table: Table = .{},
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
    var p: Parser = .{ .a = doc.arena.allocator(), .tmp = .init(gpa) };
    defer p.tmp.deinit();
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
    strike: Range,
    emoji: Range,
};

const RawBlock = struct {
    kind: BlockKind,
    lang: []const u8 = "",
    content: RawInline,
    columns: u32 = 0,
    aligns: Range = .{ .lo = 0, .hi = 0 },
    cells: Range = .{ .lo = 0, .hi = 0 },
};

const LineIterator = std.mem.SplitIterator(u8, .scalar);

// Everything is stored as offsets while parsing, because the lists reallocate;
// slices are only built in finish().
const Parser = struct {
    a: Allocator,
    text: std.ArrayList(u8) = .empty,
    bold: std.ArrayList(Span) = .empty,
    italic: std.ArrayList(Span) = .empty,
    code: std.ArrayList(Span) = .empty,
    strike: std.ArrayList(Span) = .empty,
    emoji: std.ArrayList(Span) = .empty,
    tmp: std.heap.ArenaAllocator,
    blocks: std.ArrayList(RawBlock) = .empty,
    aligns: std.ArrayList(Align) = .empty,
    cells: std.ArrayList(RawInline) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    fn run(p: *Parser, markdown: []const u8) Allocator.Error!void {
        var in_code = false;
        var code_start: u32 = 0;
        var code_lang: []const u8 = "";
        var lines = std.mem.splitScalar(u8, markdown, '\n');

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (std.mem.startsWith(u8, line, "```")) {
                if (in_code) {
                    try p.addBlock(.code_block, p.textFrom(code_start));
                    p.blocks.items[p.blocks.items.len - 1].lang = code_lang;
                    in_code = false;
                } else {
                    in_code = true;
                    code_start = p.textLen();
                    const info = std.mem.trim(u8, line[3..], " \t");
                    code_lang = try p.a.dupe(u8, info[0 .. std.mem.findAny(u8, info, " \t") orelse info.len]);
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
            } else if (!try p.tryTable(line, &lines)) {
                try p.addInlineBlock(.paragraph, line);
            }
        }
    }

    fn highlightTokens(p: *Parser, raw: RawBlock) Allocator.Error![]const highlight.Token {
        if (raw.kind != .code_block or raw.lang.len == 0) return &.{};
        var list: highlight.List = .empty;
        try highlight.tokens(p.a, raw.lang, p.text.items[raw.content.text.lo..raw.content.text.hi], &list);
        return list.items;
    }

    fn finish(p: *Parser) Allocator.Error![]const Block {
        const cells = try p.a.alloc(Inline, p.cells.items.len);
        for (cells, p.cells.items) |*c, raw| c.* = p.resolve(raw);
        const out = try p.a.alloc(Block, p.blocks.items.len);
        for (out, p.blocks.items) |*b, raw| {
            b.* = .{
                .kind = raw.kind,
                .lang = raw.lang,
                .content = p.resolve(raw.content),
                .tokens = try p.highlightTokens(raw),
                .table = .{
                    .columns = raw.columns,
                    .aligns = p.aligns.items[raw.aligns.lo..raw.aligns.hi],
                    .cells = cells[raw.cells.lo..raw.cells.hi],
                },
            };
        }
        return out;
    }

    fn resolve(p: *const Parser, r: RawInline) Inline {
        return .{
            .text = p.text.items[r.text.lo..r.text.hi],
            .bold = p.bold.items[r.bold.lo..r.bold.hi],
            .italic = p.italic.items[r.italic.lo..r.italic.hi],
            .code = p.code.items[r.code.lo..r.code.hi],
            .strike = p.strike.items[r.strike.lo..r.strike.hi],
            .emoji = p.emoji.items[r.emoji.lo..r.emoji.hi],
        };
    }

    fn textLen(p: *const Parser) u32 {
        return @intCast(p.text.items.len);
    }

    fn textFrom(p: *const Parser, start: u32) RawInline {
        const b: u32 = @intCast(p.bold.items.len);
        const i: u32 = @intCast(p.italic.items.len);
        const c: u32 = @intCast(p.code.items.len);
        const st: u32 = @intCast(p.strike.items.len);
        const em: u32 = @intCast(p.emoji.items.len);
        return .{
            .text = .{ .lo = start, .hi = p.textLen() },
            .bold = .{ .lo = b, .hi = b },
            .italic = .{ .lo = i, .hi = i },
            .code = .{ .lo = c, .hi = c },
            .strike = .{ .lo = st, .hi = st },
            .emoji = .{ .lo = em, .hi = em },
        };
    }

    fn addBlock(p: *Parser, kind: BlockKind, content: RawInline) Allocator.Error!void {
        try p.blocks.append(p.a, .{ .kind = kind, .content = content });
    }

    fn addInlineBlock(p: *Parser, kind: BlockKind, raw: []const u8) Allocator.Error!void {
        try p.addBlock(kind, try p.parseInline(raw));
    }

    fn tryTable(p: *Parser, header_line: []const u8, lines: *LineIterator) Allocator.Error!bool {
        if (std.mem.indexOfScalar(u8, header_line, '|') == null) return false;
        const delim_line = std.mem.trimEnd(u8, lines.peek() orelse return false, "\r");
        if (std.mem.indexOfScalar(u8, delim_line, '|') == null) return false;

        const header = try splitRow(p.a, header_line);
        const delims = try splitRow(p.a, delim_line);
        if (header.len != delims.len) return false;
        const aligns_lo: u32 = @intCast(p.aligns.items.len);
        for (delims) |d| {
            const a = parseAlign(d) orelse {
                p.aligns.shrinkRetainingCapacity(aligns_lo);
                return false;
            };
            try p.aligns.append(p.a, a);
        }
        _ = lines.next();

        const columns: u32 = @intCast(header.len);
        const cells_lo: u32 = @intCast(p.cells.items.len);
        try p.addRow(header, columns);
        while (lines.peek()) |raw| {
            const row = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.trim(u8, row, " \t").len == 0 or std.mem.indexOfScalar(u8, row, '|') == null) break;
            _ = lines.next();
            try p.addRow(try splitRow(p.a, row), columns);
        }

        try p.blocks.append(p.a, .{
            .kind = .table,
            .content = p.textFrom(p.textLen()),
            .columns = columns,
            .aligns = .{ .lo = aligns_lo, .hi = @intCast(p.aligns.items.len) },
            .cells = .{ .lo = cells_lo, .hi = @intCast(p.cells.items.len) },
        });
        return true;
    }

    // GFM pads short rows with empty cells and ignores cells past the header's count.
    fn addRow(p: *Parser, cells: []const []const u8, columns: u32) Allocator.Error!void {
        for (0..columns) |col| {
            if (col >= cells.len) {
                try p.cells.append(p.a, p.textFrom(p.textLen()));
                continue;
            }
            p.scratch.clearRetainingCapacity();
            const raw = cells[col];
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == '|') i += 1;
                try p.scratch.append(p.a, raw[i]);
            }
            try p.cells.append(p.a, try p.parseInline(p.scratch.items));
        }
    }

    fn parseInline(p: *Parser, raw: []const u8) Allocator.Error!RawInline {
        _ = p.tmp.reset(.retain_capacity);
        const parsed = try inl.parse(p.tmp.allocator(), raw, &legacy_hooks);
        var r = p.textFrom(p.textLen());
        try p.text.appendSlice(p.a, parsed.text);

        const Open = struct { kind: inl.Kind, pos: u32 };
        var stack: std.ArrayList(Open) = .empty;
        for (parsed.events) |ev| switch (ev.tag) {
            .open => try stack.append(p.tmp.allocator(), .{ .kind = ev.kind, .pos = ev.pos }),
            .close => {
                const open = stack.pop() orelse continue;
                const span: Span = .{ open.pos, ev.pos - open.pos };
                switch (open.kind) {
                    .em => try p.italic.append(p.a, span),
                    .strong => try p.bold.append(p.a, span),
                    .strike => try p.strike.append(p.a, span),
                    .code => try p.code.append(p.a, span),
                    .emoji => try p.emoji.append(p.a, span),
                    .link, .image => {},
                }
            },
            .html, .soft, .hard => {},
        };

        r.text.hi = p.textLen();
        r.bold.hi = @intCast(p.bold.items.len);
        r.italic.hi = @intCast(p.italic.items.len);
        r.code.hi = @intCast(p.code.items.len);
        r.strike.hi = @intCast(p.strike.items.len);
        r.emoji.hi = @intCast(p.emoji.items.len);
        return r;
    }
};

const legacy_hooks: inl.Hooks = .{ .link = legacyLink };

fn legacyLink(_: *const inl.Hooks, _: Allocator, src: []const u8, _: usize, close: usize, _: bool) Allocator.Error!?inl.LinkMatch {
    if (close + 1 >= src.len or src[close + 1] != '(') return null;
    var depth: i32 = 0;
    var k = close + 1;
    while (k < src.len) : (k += 1) {
        if (src[k] == '(') depth += 1;
        if (src[k] == ')') {
            depth -= 1;
            if (depth == 0) return .{ .end = k + 1 };
        }
    }
    return null;
}

fn splitRow(a: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and !(s.len > 1 and s[s.len - 2] == '\\')) s = s[0 .. s.len - 1];

    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == '|') {
            try cells.append(a, std.mem.trim(u8, s[start..i], " \t"));
            start = i + 1;
        }
    }
    try cells.append(a, std.mem.trim(u8, s[@min(start, s.len)..], " \t"));
    return cells.items;
}

fn parseAlign(cell: []const u8) ?Align {
    if (cell.len == 0) return null;
    const left = cell[0] == ':';
    const right = cell[cell.len - 1] == ':';
    var dashes = cell;
    if (left) dashes = dashes[1..];
    if (right and dashes.len > 0) dashes = dashes[0 .. dashes.len - 1];
    if (dashes.len == 0) return null;
    for (dashes) |ch| if (ch != '-') return null;
    if (left and right) return .center;
    if (left) return .left;
    if (right) return .right;
    return .none;
}

/// Shrinks natural column widths to fit `available`: columns narrower than an even
/// share keep their width, wider ones split what is left in proportion.
pub fn fitColumns(widths: []f32, available: f32, min_width: f32) void {
    var total: f32 = 0;
    for (widths) |w| total += w;
    if (widths.len == 0 or total <= available) return;
    const fair = available / @as(f32, @floatFromInt(widths.len));
    var narrow: f32 = 0;
    for (widths) |w| {
        if (w <= fair) narrow += w;
    }
    const scale = (available - narrow) / (total - narrow);
    for (widths) |*w| {
        if (w.* > fair) w.* = @max(min_width, w.* * scale);
    }
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

const testing = std.testing;

test {
    _ = inl;
    _ = highlight;
}

test "fence info string keeps its first word as the block language" {
    var doc = try parse(testing.allocator, "```Rust title=x\nfn\n```\n```\nplain\n```\n");
    defer doc.deinit();
    try testing.expectEqualStrings("Rust", doc.blocks[0].lang);
    try testing.expectEqualStrings("", doc.blocks[1].lang);
}

test "code block tokens are computed once at parse time" {
    var doc = try parse(testing.allocator, "```zig\nconst x = 1;\n```\n```nope\nconst x = 1;\n```\n```\nplain\n```\n");
    defer doc.deinit();
    try testing.expect(doc.blocks[0].tokens.len > 0);
    try testing.expectEqual(highlight.Kind.keyword, doc.blocks[0].tokens[0].kind);
    try testing.expectEqual(@as(usize, 0), doc.blocks[1].tokens.len);
    try testing.expectEqual(@as(usize, 0), doc.blocks[2].tokens.len);
}

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

test "table with alignment, escaped pipes and ragged rows" {
    const src =
        \\| Left | Center | Right | None |
        \\|:-----|:------:|------:|------|
        \\| a \| b | **c** | `d` |
        \\| 1 | 2 | 3 | 4 | 5 |
        \\
        \\after
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(BlockKind.table, doc.blocks[0].kind);

    const t = doc.blocks[0].table;
    try testing.expectEqual(@as(usize, 4), t.columns);
    try testing.expectEqualSlices(Align, &.{ .left, .center, .right, .none }, t.aligns);
    try testing.expectEqual(@as(usize, 3), t.rows());
    try testing.expectEqualStrings("Center", t.cell(0, 1).text);
    try testing.expectEqualStrings("a | b", t.cell(1, 0).text);
    try testing.expectEqualStrings("c", t.cell(1, 1).text);
    try testing.expectEqual(@as(usize, 1), t.cell(1, 1).bold.len);
    try testing.expectEqualStrings("d", t.cell(1, 2).text);
    try testing.expectEqual(@as(usize, 1), t.cell(1, 2).code.len);
    try testing.expectEqualStrings("", t.cell(1, 3).text);
    try testing.expectEqualStrings("4", t.cell(2, 3).text);
    try testing.expectEqualStrings("after", doc.blocks[1].content.text);
}

test "table without outer pipes" {
    var doc = try parse(testing.allocator, "a | *b*\n--- | :---\n1 | 2\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const t = doc.blocks[0].table;
    try testing.expectEqual(@as(usize, 2), t.columns);
    try testing.expectEqual(@as(usize, 2), t.rows());
    try testing.expectEqualSlices(Align, &.{ .none, .left }, t.aligns);
    try testing.expectEqual(@as(usize, 1), t.cell(0, 1).italic.len);
    try testing.expectEqualStrings("2", t.cell(1, 1).text);
}

test "pipe lines without a delimiter row stay paragraphs" {
    var doc = try parse(testing.allocator, "a | b\nc | d\n\n| x | y |\n|---|\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 4), doc.blocks.len);
    for (doc.blocks) |b| try testing.expectEqual(BlockKind.paragraph, b.kind);
    try testing.expectEqualStrings("a | b", doc.blocks[0].content.text);
    try testing.expectEqualStrings("| x | y |", doc.blocks[2].content.text);
    try testing.expectEqualStrings("|---|", doc.blocks[3].content.text);
}

test "fitColumns keeps narrow columns and shrinks wide ones" {
    var widths = [_]f32{ 50, 400, 600 };
    fitColumns(&widths, 550, 40);
    try testing.expectEqual(@as(f32, 50), widths[0]);
    try testing.expectApproxEqAbs(@as(f32, 500), widths[1] + widths[2], 0.01);
    try testing.expect(widths[2] > widths[1]);

    var fits = [_]f32{ 10, 20 };
    fitColumns(&fits, 100, 40);
    try testing.expectEqual(@as(f32, 20), fits[1]);
}

test "inline spans: nested emphasis, strikethrough, emoji, entities, escapes" {
    var doc = try parse(testing.allocator, "x ***both*** ~~gone~~ :tada: &amp; \\*lit\\* `a*b`\n");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqualStrings("x both gone \u{1F389} & *lit* a*b", c.text);
    try testing.expectEqual(@as(usize, 1), c.bold.len);
    try testing.expectEqual(@as(usize, 1), c.italic.len);
    try testing.expectEqual(Span{ 2, 4 }, c.bold[0]);
    try testing.expectEqual(Span{ 2, 4 }, c.italic[0]);
    try testing.expectEqualStrings("gone", c.text[c.strike[0][0]..][0..c.strike[0][1]]);
    try testing.expectEqualStrings("\u{1F389}", c.text[c.emoji[0][0]..][0..c.emoji[0][1]]);
    try testing.expectEqualStrings("a*b", c.text[c.code[0][0]..][0..c.code[0][1]]);
}
