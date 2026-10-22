const std = @import("std");
const Allocator = std.mem.Allocator;
const inl = @import("inline.zig");
const highlight = @import("highlight.zig");
const blocks = @import("blocks.zig");
const yaml = @import("yaml.zig");

pub const Definition = blocks.Definition;

pub const BlockKind = enum { h1, h2, h3, h4, h5, h6, paragraph, code_block, hr, table, alert_title, error_box };

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
    /// Empty, or parallel to `cells`: a table drawn in that cell instead of its text (`columns == 0` for none).
    nested: []const Table = &.{},
    header_row: bool = true,
    /// First column cells are headers (front matter keys).
    header_col: bool = false,

    pub fn rows(t: Table) usize {
        return if (t.columns == 0) 0 else t.cells.len / t.columns;
    }

    pub fn cell(t: Table, row: usize, col: usize) Inline {
        return t.cells[row * t.columns + col];
    }

    /// GitHub shades every second row of the header and of the body groups.
    pub fn striped(t: Table, row: usize) bool {
        if (t.header_row and row == 0) return false;
        const index = if (t.header_row) row else row + 1;
        return index % 2 == 0;
    }

    pub fn nestedAt(t: Table, row: usize, col: usize) ?Table {
        if (t.nested.len == 0) return null;
        const n = t.nested[row * t.columns + col];
        return if (n.columns == 0) null else n;
    }
};

pub const Marker = enum { none, bullet, number, task_open, task_done };
pub const Alert = enum { none, note, tip, important, warning, caution };
pub const FrameKind = enum { quote, list };

pub const Mark = struct {
    kind: Marker = .none,
    number: u32 = 0,
    /// Number of list items around this one.
    depth: u8 = 0,
};

/// A list marker and the inset of the item content it sits in front of.
pub const Lead = struct { mark: Mark, inset: f32 };

pub fn markerLabel(buf: []u8, m: Mark) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.", .{m.number}) catch "";
}

/// One enclosing container of a block, outermost first. A `list` frame is one list item.
pub const Frame = struct {
    kind: FrameKind,
    alert: Alert = .none,
    /// The container continues into the next block, so a quote bar runs through the gap.
    open: bool = false,
    id: u32 = 0,
    /// Id of the list a `list` frame belongs to.
    group: u32 = 0,
    ordered: bool = false,
    start: u32 = 0,
    tight: bool = true,
};

pub const quote_inset: f32 = 20;
pub const list_inset: f32 = 32;
pub const quote_bar: f32 = 4;
/// A table inside a cell keeps its bottom margin.
pub const nested_table_margin: f32 = 16;

pub const Block = struct {
    kind: BlockKind,
    tokens: []const highlight.Token = &.{},
    content: Inline = .{},
    table: Table = .{},
    /// First word of a fenced code block's info string; picks the highlighter.
    lang: []const u8 = "",
    frames: []const Frame = &.{},
    /// List markers drawn in front of this block, outermost first.
    marks: []const Lead = &.{},
    /// Paragraph of a tight list item that is followed by more of that list: 4px gap instead of 16.
    compact: bool = false,

    pub fn insetBefore(b: Block, n: usize) f32 {
        var x: f32 = 0;
        for (b.frames[0..n]) |f| x += if (f.kind == .quote) quote_inset else list_inset;
        return x;
    }

    pub fn inset(b: Block) f32 {
        return b.insetBefore(b.frames.len);
    }

    /// Inside a plain blockquote, where text is drawn in the muted colour.
    pub fn muted(b: Block) bool {
        for (b.frames) |f| if (f.kind == .quote and f.alert == .none) return true;
        return false;
    }

    pub fn paragraphGap(b: Block) f32 {
        return if (b.compact) 4 else 16;
    }
};

pub const Footnote = struct {
    /// Normalized like a definition label, without the `^`.
    label: []const u8,
    blocks: []const Block,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []const Block = &.{},
    /// Link reference definitions (`[label]: dest "title"`) taken from the start of paragraphs, in
    /// source order, and removed from `blocks`. `label` is normalized: trimmed, whitespace collapsed,
    /// Unicode case folded.
    definitions: []const Definition = &.{},
    /// Footnote definitions (`[^label]: ...`), each with all its blocks; not part of `blocks`.
    footnotes: []const Footnote = &.{},

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
    const skip = try p.frontMatter(markdown);
    const tree = try blocks.build(p.a, markdown[skip..]);
    try p.walk(&tree, 0);
    try p.finish(&doc);
    doc.definitions = tree.defs.items;
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
    content: RawInline,
    columns: u32 = 0,
    aligns: Range = .{ .lo = 0, .hi = 0 },
    cells: Range = .{ .lo = 0, .hi = 0 },
    ytable: ?Table = null,
    lang: Range = .{ .lo = 0, .hi = 0 },
    frames: []Frame = &.{},
    marks: []Lead = &.{},
    compact: bool = false,
};

const RawFootnote = struct { label: []const u8, lo: usize, hi: usize };

const alert_names = [_]struct { tag: []const u8, alert: Alert, label: []const u8 }{
    .{ .tag = "[!NOTE]", .alert = .note, .label = "Note" },
    .{ .tag = "[!TIP]", .alert = .tip, .label = "Tip" },
    .{ .tag = "[!IMPORTANT]", .alert = .important, .label = "Important" },
    .{ .tag = "[!WARNING]", .alert = .warning, .label = "Warning" },
    .{ .tag = "[!CAUTION]", .alert = .caution, .label = "Caution" },
};

fn sharesList(a: []const Frame, b: []const Frame) bool {
    for (a) |fa| {
        if (fa.kind != .list) continue;
        for (b) |fb| if (fb.kind == .list and fb.group == fa.group) return true;
    }
    return false;
}

fn settle(raw: []RawBlock) void {
    for (raw, 0..) |*b, i| {
        const next: ?*const RawBlock = if (i + 1 < raw.len) &raw[i + 1] else null;
        if (b.compact) b.compact = if (next) |n| sharesList(b.frames, n.frames) else false;
        for (b.frames, 0..) |*f, j| {
            f.open = if (next) |n| j < n.frames.len and n.frames[j].id == f.id else false;
        }
    }
}

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
    joined: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    leads: std.ArrayList(Lead) = .empty,
    fn_blocks: std.ArrayList(RawBlock) = .empty,
    footnotes: std.ArrayList(RawFootnote) = .empty,

    fn emit(p: *Parser, raw: RawBlock) Allocator.Error!void {
        var b = raw;
        b.frames = try p.a.dupe(Frame, p.frames.items);
        b.marks = try p.a.dupe(Lead, p.leads.items);
        p.leads.clearRetainingCapacity();
        try p.blocks.append(p.a, b);
    }

    fn plain(p: *Parser, s: []const u8) Allocator.Error!RawInline {
        const start = p.textLen();
        try p.text.appendSlice(p.a, s);
        return p.textFrom(start);
    }

    fn frameInset(p: *const Parser) f32 {
        var x: f32 = 0;
        for (p.frames.items) |f| x += if (f.kind == .quote) quote_inset else list_inset;
        return x;
    }

    fn listDepth(p: *const Parser) u8 {
        var n: u8 = 0;
        for (p.frames.items) |f| n +|= @intFromBool(f.kind == .list);
        return n;
    }

    fn walk(p: *Parser, t: *const blocks.Tree, idx: u32) Allocator.Error!void {
        const node = t.nodes.items[idx];
        switch (node.kind) {
            .document, .item => {
                var c = node.first;
                while (c != blocks.none) : (c = t.nodes.items[c].next) try p.walk(t, c);
            },
            .list => {
                var c = node.first;
                var num = node.start;
                while (c != blocks.none) : (c = t.nodes.items[c].next) {
                    const depth = p.listDepth();
                    try p.frames.append(p.a, .{ .kind = .list, .id = c, .group = idx, .ordered = node.ordered, .start = node.start, .tight = node.tight });
                    try p.leads.append(p.a, .{
                        .mark = .{ .kind = if (node.ordered) .number else .bullet, .number = num, .depth = depth },
                        .inset = p.frameInset(),
                    });
                    num +%= 1;
                    try p.walk(t, c);
                    if (p.leads.items.len > 0) try p.emit(.{ .kind = .paragraph, .content = try p.plain(" ") });
                    _ = p.frames.pop();
                }
            },
            .quote => try p.quote(t, idx),
            .footnote => try p.footnote(t, idx),
            .paragraph => try p.paragraph(t, idx, node.content.items),
            .heading => {
                try p.join(node.content.items);
                try p.emit(.{
                    .kind = @enumFromInt(@intFromEnum(BlockKind.h1) + node.level - 1),
                    .content = try p.parseInline(p.joined.items),
                });
            },
            .thematic => try p.emit(.{ .kind = .hr, .content = p.textFrom(p.textLen()) }),
            .code => {
                const start = p.textLen();
                var body = node.content.items;
                var info: []const u8 = "";
                if (node.fenced) {
                    const z = std.mem.indexOfScalar(u8, body, 0) orelse 0;
                    info = body[0..z];
                    body = body[@min(z + 1, body.len)..];
                }
                try p.text.appendSlice(p.a, body);
                const content = p.textFrom(start);
                const word = info[0 .. std.mem.indexOfAny(u8, info, " \t") orelse info.len];
                const lang_start = p.textLen();
                try p.text.appendSlice(p.a, word);
                try p.emit(.{ .kind = .code_block, .content = content, .lang = .{ .lo = lang_start, .hi = p.textLen() } });
            },
            .html => {},
        }
    }

    fn footnote(p: *Parser, t: *const blocks.Tree, idx: u32) Allocator.Error!void {
        const node = t.nodes.items[idx];
        const saved_frames = p.frames;
        const saved_leads = p.leads;
        p.frames = .empty;
        p.leads = .empty;
        const start = p.blocks.items.len;
        var c = node.first;
        while (c != blocks.none) : (c = t.nodes.items[c].next) try p.walk(t, c);
        if (p.leads.items.len > 0) try p.emit(.{ .kind = .paragraph, .content = try p.plain(" ") });
        const lo = p.fn_blocks.items.len;
        try p.fn_blocks.appendSlice(p.a, p.blocks.items[start..]);
        p.blocks.shrinkRetainingCapacity(start);
        try p.footnotes.append(p.a, .{ .label = node.label, .lo = lo, .hi = p.fn_blocks.items.len });
        p.frames = saved_frames;
        p.leads = saved_leads;
    }

    fn quote(p: *Parser, t: *const blocks.Tree, idx: u32) Allocator.Error!void {
        const node = t.nodes.items[idx];
        var alert: Alert = .none;
        var label: []const u8 = "";
        var rest: []const u8 = "";
        const first = node.first;
        if (first != blocks.none and t.nodes.items[first].kind == .paragraph) {
            const content = t.nodes.items[first].content.items;
            const nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
            const line = std.mem.trim(u8, content[0..nl], " \t");
            for (alert_names) |an| {
                if (std.ascii.eqlIgnoreCase(line, an.tag)) {
                    alert = an.alert;
                    label = an.label;
                    rest = content[@min(nl + 1, content.len)..];
                }
            }
        }
        try p.frames.append(p.a, .{ .kind = .quote, .id = idx, .alert = alert });
        var c = first;
        if (alert != .none) {
            try p.emit(.{ .kind = .alert_title, .content = try p.plain(label) });
            if (std.mem.trim(u8, rest, " \t\r\n").len > 0) try p.paragraph(t, c, rest);
            c = t.nodes.items[c].next;
        }
        const before = p.blocks.items.len;
        while (c != blocks.none) : (c = t.nodes.items[c].next) try p.walk(t, c);
        if (p.blocks.items.len == before and alert == .none) try p.emit(.{ .kind = .paragraph, .content = try p.plain("") });
        _ = p.frames.pop();
    }

    // The inline parser turns the line ends into soft and hard breaks.
    fn join(p: *Parser, content: []const u8) Allocator.Error!void {
        p.joined.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimStart(u8, raw, " \t");
            if (lines.peek() == null) {
                try p.joined.appendSlice(p.a, std.mem.trimEnd(u8, line, " \t"));
            } else {
                try p.joined.appendSlice(p.a, line);
                try p.joined.append(p.a, '\n');
            }
        }
    }

    fn highlightTokens(p: *Parser, raw: RawBlock) Allocator.Error![]const highlight.Token {
        if (raw.kind != .code_block or raw.lang.hi == raw.lang.lo) return &.{};
        var list: highlight.List = .empty;
        try highlight.tokens(p.a, p.text.items[raw.lang.lo..raw.lang.hi], p.text.items[raw.content.text.lo..raw.content.text.hi], &list);
        return list.items;
    }

    fn paragraph(p: *Parser, t: *const blocks.Tree, idx: u32, content: []const u8) Allocator.Error!void {
        const node = t.nodes.items[idx];
        const in_item = t.nodes.items[node.parent].kind == .item;
        const compact = in_item and t.nodes.items[t.nodes.items[node.parent].parent].tight;

        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
        while (it.next()) |l| try lines.append(p.a, std.mem.trimStart(u8, l, " \t"));

        var i: usize = 1;
        while (i < lines.items.len) : (i += 1) {
            if (std.mem.indexOfScalar(u8, lines.items[i - 1], '|') == null) continue;
            if (std.mem.indexOfScalar(u8, lines.items[i], '|') == null) continue;
            if (try p.tryTable(lines.items[i - 1], lines.items[i], lines.items[i + 1 ..])) {
                if (i > 1) try p.paragraphLines(lines.items[0 .. i - 1], compact, in_item);
                return;
            }
        }
        try p.paragraphLines(lines.items, compact, in_item);
    }

    fn paragraphLines(p: *Parser, lines: []const []const u8, compact: bool, in_item: bool) Allocator.Error!void {
        var src: std.ArrayList(u8) = .empty;
        for (lines) |l| {
            try src.appendSlice(p.a, l);
            try src.append(p.a, '\n');
        }
        try p.join(src.items);
        var text: []const u8 = p.joined.items;
        if (in_item and p.leads.items.len > 0 and text.len >= 4 and text[0] == '[' and text[2] == ']' and
            (text[1] == ' ' or text[1] == 'x' or text[1] == 'X') and (text[3] == ' ' or text[3] == '\n'))
        {
            const body = std.mem.trimStart(u8, text[3..], " \n");
            if (body.len > 0) {
                p.leads.items[p.leads.items.len - 1].mark.kind = if (text[1] == ' ') .task_open else .task_done;
                text = body;
            }
        }
        try p.emit(.{ .kind = .paragraph, .content = try p.parseInline(text), .compact = compact });
    }

    fn cellInline(p: *Parser, v: yaml.Value) Allocator.Error!Inline {
        return switch (v) {
            .scalar => |s| .{ .text = try p.a.dupe(u8, s.text) },
            else => .{},
        };
    }

    // GitHub draws a row of values only when at least one is neither nil nor false.
    fn truthy(v: yaml.Value) bool {
        return switch (v) {
            .scalar => |s| !s.falsy,
            else => true,
        };
    }

    const NestedCells = struct { cells: std.ArrayList(Inline) = .empty, kids: std.ArrayList(Table) = .empty, any: bool = false };

    fn addCell(p: *Parser, out: *NestedCells, text: ?[]const u8, v: yaml.Value) Allocator.Error!void {
        if (text) |t| {
            try out.cells.append(p.a, .{ .text = try p.a.dupe(u8, t) });
            try out.kids.append(p.a, .{});
            return;
        }
        try out.cells.append(p.a, try p.cellInline(v));
        const k = try p.yamlTable(v, false);
        out.any = out.any or k.columns > 0;
        try out.kids.append(p.a, k);
    }

    fn finishTable(p: *Parser, t_in: Table, out: *NestedCells) Allocator.Error!Table {
        var t = t_in;
        const aligns = try p.a.alloc(Align, t.columns);
        @memset(aligns, .none);
        t.aligns = aligns;
        t.cells = out.cells.items;
        if (out.any) t.nested = out.kids.items;
        return t;
    }

    fn yamlTable(p: *Parser, v: yaml.Value, top: bool) Allocator.Error!Table {
        var out: NestedCells = .{};
        switch (v) {
            .scalar => return .{},
            .seq => |items| {
                if (items.len == 0) return .{ .columns = 1, .header_row = false };
                var shown = false;
                for (items) |it| shown = shown or truthy(it);
                if (shown) {
                    for (items) |it| try p.addCell(&out, null, it);
                }
                return p.finishTable(.{ .columns = items.len, .header_row = false }, &out);
            },
            .map => |pairs| {
                if (top) {
                    for (pairs) |pr| {
                        try p.addCell(&out, pr.key, pr.value);
                        try p.addCell(&out, null, pr.value);
                    }
                    return p.finishTable(.{ .columns = 2, .header_row = false, .header_col = true }, &out);
                }
                if (pairs.len == 0) return .{ .columns = 1, .header_row = false };
                var shown = false;
                for (pairs) |pr| {
                    try p.addCell(&out, pr.key, pr.value);
                    shown = shown or truthy(pr.value);
                }
                if (shown) {
                    for (pairs) |pr| try p.addCell(&out, null, pr.value);
                } else {
                    out.any = false;
                }
                return p.finishTable(.{ .columns = pairs.len }, &out);
            },
        }
    }

    fn frontMatter(p: *Parser, md: []const u8) Allocator.Error!usize {
        var lines = std.mem.splitScalar(u8, md, '\n');
        const first = lines.next() orelse return 0;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, " \t\r"), "---")) return 0;
        const body_start = @min(first.len + 1, md.len);
        var pos = body_start;
        var body_end: ?usize = null;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (std.mem.eql(u8, line, "---")) {
                body_end = pos;
                pos += raw.len + 1;
                break;
            }
            pos += raw.len + 1;
        }
        const end = body_end orelse return 0;
        const consumed = @min(pos, md.len);
        const body = md[body_start..end];
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return 0;

        switch (try yaml.parse(p.a, body)) {
            .other => return 0,
            .ok => |v| try p.emit(.{ .kind = .table, .content = p.textFrom(p.textLen()), .ytable = try p.yamlTable(v, true) }),
            .err => |e| {
                try p.emit(.{ .kind = .error_box, .content = try p.plain(e.message) });
                const start = p.textLen();
                try p.text.appendSlice(p.a, "---\n");
                try p.text.appendSlice(p.a, body);
                if (body[body.len - 1] != '\n') try p.text.append(p.a, '\n');
                try p.text.appendSlice(p.a, "---\n");
                const content = p.textFrom(start);
                const lang_start = p.textLen();
                try p.text.appendSlice(p.a, "yaml");
                try p.emit(.{ .kind = .code_block, .content = content, .lang = .{ .lo = lang_start, .hi = p.textLen() } });
            },
        }
        return consumed;
    }

    fn finish(p: *Parser, doc: *Document) Allocator.Error!void {
        settle(p.blocks.items);
        for (p.footnotes.items) |f| settle(p.fn_blocks.items[f.lo..f.hi]);
        const cells = try p.a.alloc(Inline, p.cells.items.len);
        for (cells, p.cells.items) |*c, raw| c.* = p.resolve(raw);
        doc.blocks = try p.build(p.blocks.items, cells);
        const notes = try p.a.alloc(Footnote, p.footnotes.items.len);
        for (notes, p.footnotes.items) |*n, f| n.* = .{ .label = f.label, .blocks = try p.build(p.fn_blocks.items[f.lo..f.hi], cells) };
        doc.footnotes = notes;
    }

    fn build(p: *Parser, raws: []const RawBlock, cells: []const Inline) Allocator.Error![]const Block {
        const out = try p.a.alloc(Block, raws.len);
        for (out, raws) |*b, raw| {
            b.* = .{
                .kind = raw.kind,
                .content = p.resolve(raw.content),
                .tokens = try p.highlightTokens(raw),
                .table = raw.ytable orelse .{
                    .columns = raw.columns,
                    .aligns = p.aligns.items[raw.aligns.lo..raw.aligns.hi],
                    .cells = cells[raw.cells.lo..raw.cells.hi],
                },
                .lang = p.text.items[raw.lang.lo..raw.lang.hi],
                .frames = raw.frames,
                .marks = raw.marks,
                .compact = raw.compact,
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


    fn tryTable(p: *Parser, header_line: []const u8, delim_line: []const u8, row_lines: []const []const u8) Allocator.Error!bool {
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

        const columns: u32 = @intCast(header.len);
        const cells_lo: u32 = @intCast(p.cells.items.len);
        try p.addRow(header, columns);
        for (row_lines) |row| try p.addRow(try splitRow(p.a, row), columns);

        try p.emit(.{
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
    _ = @import("spec_test.zig");
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
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    for (doc.blocks) |b| try testing.expectEqual(BlockKind.paragraph, b.kind);
    try testing.expectEqualStrings("a | b c | d", doc.blocks[0].content.text);
    try testing.expectEqualStrings("| x | y | |---|", doc.blocks[1].content.text);
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

test "headings h1 to h6 with closing hashes" {
    var doc = try parse(testing.allocator, "# a #\n###### f ##\n#### d\n");
    defer doc.deinit();
    try testing.expectEqual(BlockKind.h1, doc.blocks[0].kind);
    try testing.expectEqualStrings("a", doc.blocks[0].content.text);
    try testing.expectEqual(BlockKind.h6, doc.blocks[1].kind);
    try testing.expectEqual(BlockKind.h4, doc.blocks[2].kind);
}

test "soft breaks become spaces and hard breaks newlines" {
    var doc = try parse(testing.allocator, "a\nb  \nc\\\nd\n");
    defer doc.deinit();
    try testing.expectEqualStrings("a b\nc\nd", doc.blocks[0].content.text);
}

test "ordered lists keep their numbers and nest" {
    var doc = try parse(testing.allocator, "3) a\n4) b\n   - c\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(Marker.number, doc.blocks[0].marks[0].mark.kind);
    try testing.expectEqual(@as(u32, 3), doc.blocks[0].marks[0].mark.number);
    try testing.expectEqual(@as(u32, 4), doc.blocks[1].marks[0].mark.number);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("3.", markerLabel(&buf, doc.blocks[0].marks[0].mark));
    try testing.expectEqual(Marker.bullet, doc.blocks[2].marks[0].mark.kind);
    try testing.expectEqual(@as(u8, 1), doc.blocks[2].marks[0].mark.depth);
    try testing.expectEqual(@as(f32, 64), doc.blocks[2].inset());
    try testing.expect(doc.blocks[0].compact);
}

test "task list items replace the bullet" {
    var doc = try parse(testing.allocator, "- [ ] open\n- [x] done\n- [x]\n");
    defer doc.deinit();
    try testing.expectEqual(Marker.task_open, doc.blocks[0].marks[0].mark.kind);
    try testing.expectEqualStrings("open", doc.blocks[0].content.text);
    try testing.expectEqual(Marker.task_done, doc.blocks[1].marks[0].mark.kind);
    try testing.expectEqual(Marker.bullet, doc.blocks[2].marks[0].mark.kind);
}

test "blockquote holds blocks and nests" {
    var doc = try parse(testing.allocator, "> # t\n>> inner\nlazy\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].frames.len);
    try testing.expectEqual(@as(usize, 2), doc.blocks[1].frames.len);
    try testing.expectEqualStrings("inner lazy", doc.blocks[1].content.text);
    try testing.expect(doc.blocks[0].frames[0].open);
    try testing.expect(doc.blocks[0].muted());
}

test "github alerts" {
    var doc = try parse(testing.allocator, "> [!WARNING]\n> careful\n\n> [!tip]\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(BlockKind.alert_title, doc.blocks[0].kind);
    try testing.expectEqualStrings("Warning", doc.blocks[0].content.text);
    try testing.expectEqual(Alert.warning, doc.blocks[0].frames[0].alert);
    try testing.expectEqualStrings("careful", doc.blocks[1].content.text);
    try testing.expectEqual(Alert.tip, doc.blocks[2].frames[0].alert);
    try testing.expect(!doc.blocks[1].muted());
}

test "code blocks keep the info string word" {
    var doc = try parse(testing.allocator, "```zig title=x\nconst a = 1;\n```\n\n~~~\nplain\n~~~\n\n    indented\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqualStrings("zig", doc.blocks[0].lang);
    try testing.expectEqualStrings("const a = 1;\n", doc.blocks[0].content.text);
    try testing.expectEqualStrings("", doc.blocks[1].lang);
    try testing.expectEqualStrings("indented\n", doc.blocks[2].content.text);
}

test "front matter becomes a table" {
    var doc = try parse(testing.allocator, "---\ntitle: \"Hi\"\ntags: a\n---\n\n# H\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    const t = doc.blocks[0].table;
    try testing.expectEqual(@as(usize, 2), t.columns);
    try testing.expectEqualStrings("title", t.cell(0, 0).text);
    try testing.expectEqualStrings("Hi", t.cell(0, 1).text);
    try testing.expectEqual(BlockKind.h1, doc.blocks[1].kind);
}

test "definitions are collected and removed from the output" {
    var doc = try parse(testing.allocator, "[Foo  Bar]: <http://x> 'T'\n\n[^n]: a note\ntext\n\n[x]: /y\n\nafter\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expectEqual(@as(usize, 2), doc.definitions.len);
    try testing.expectEqualStrings("foo bar", doc.definitions[0].label);
    try testing.expectEqualStrings("http://x", doc.definitions[0].dest);
    try testing.expectEqualStrings("T", doc.definitions[0].title);
    try testing.expectEqualStrings("/y", doc.definitions[1].dest);
    try testing.expectEqual(@as(usize, 1), doc.footnotes.len);
    try testing.expectEqualStrings("n", doc.footnotes[0].label);
    try testing.expectEqualStrings("a note text", doc.footnotes[0].blocks[0].content.text);
}

test "tables work inside lists and quotes" {
    var doc = try parse(testing.allocator, "> a | b\n> --- | ---\n> 1 | 2\n");
    defer doc.deinit();
    try testing.expectEqual(BlockKind.table, doc.blocks[0].kind);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].frames.len);
}

test "alert icons build at comptime" {
    const alerts = @import("alerts.zig");
    for ([_]Alert{ .note, .tip, .important, .warning, .caution }) |a| try testing.expect(alerts.icon(a).len > 0);
}

test "definition labels use full Unicode case folding" {
    var doc = try parse(testing.allocator, "[Stra\u{DF}e]: /a\n\n[\u{3A3}]: /b\n\n[ẞ]: /c\n");
    defer doc.deinit();
    try testing.expectEqualStrings("strasse", doc.definitions[0].label);
    try testing.expectEqualStrings("\u{3C3}", doc.definitions[1].label);
    try testing.expectEqualStrings("ss", doc.definitions[2].label);
}

test "footnotes keep every block and stay out of the document" {
    var doc = try parse(testing.allocator, "text\n\n[^1]: first\n\n    second\n\n    ```\n    code\n    ```\n\nafter\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(@as(usize, 1), doc.footnotes.len);
    const f = doc.footnotes[0];
    try testing.expectEqualStrings("1", f.label);
    try testing.expectEqual(@as(usize, 3), f.blocks.len);
    try testing.expectEqualStrings("second", f.blocks[1].content.text);
    try testing.expectEqual(BlockKind.code_block, f.blocks[2].kind);
}

test "nested list markers on one line and empty quotes" {
    var doc = try parse(testing.allocator, "- - foo\n\n>\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].marks.len);
    try testing.expectEqual(@as(f32, 32), doc.blocks[0].marks[0].inset);
    try testing.expectEqual(@as(f32, 64), doc.blocks[0].marks[1].inset);
    try testing.expectEqual(@as(usize, 1), doc.blocks[1].frames.len);
    try testing.expectEqualStrings("", doc.blocks[1].content.text);
}

test "a line break inside a code span is a space" {
    var doc = try parse(testing.allocator, "`code  \nspan` and\nnext  \nline\n");
    defer doc.deinit();
    try testing.expectEqualStrings("code   span and next\nline", doc.blocks[0].content.text);
}

test "nested front matter becomes nested tables" {
    var doc = try parse(testing.allocator, "---\ntitle: T\nlist:\n  - a\n  - b\nmap:\n  k: v\n  n: null\n---\n\nbody\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    const t = doc.blocks[0].table;
    try testing.expect(t.header_col and !t.header_row);
    try testing.expectEqual(@as(usize, 2), t.columns);
    try testing.expectEqual(@as(usize, 3), t.rows());
    try testing.expectEqualStrings("list", t.cell(1, 0).text);
    const list = t.nestedAt(1, 1).?;
    try testing.expect(!list.header_row);
    try testing.expectEqual(@as(usize, 2), list.columns);
    try testing.expectEqualStrings("b", list.cell(0, 1).text);
    const map = t.nestedAt(2, 1).?;
    try testing.expect(map.header_row);
    try testing.expectEqualStrings("k", map.cell(0, 0).text);
    try testing.expectEqualStrings("v", map.cell(1, 0).text);
    try testing.expectEqualStrings("", map.cell(1, 1).text);
}

test "invalid front matter shows GitHub's error box and the yaml" {
    var doc = try parse(testing.allocator, "---\na: [1, 2\n---\n\nbody\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(BlockKind.error_box, doc.blocks[0].kind);
    try testing.expectEqualStrings("Error in user YAML: (<unknown>): did not find expected ',' or ']' while parsing a flow sequence at line 1 column 4", doc.blocks[0].content.text);
    try testing.expectEqualStrings("yaml", doc.blocks[1].lang);
    try testing.expectEqualStrings("---\na: [1, 2\n---\n", doc.blocks[1].content.text);
}

test "yaml is built" {
    _ = @import("yaml.zig");
    _ = @import("yaml_test.zig");
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

test "front matter ends at the first --- line only" {
    var doc = try parse(testing.allocator, "---\na: 1\n...\nb: 2\n---\n\nbody\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].table.rows());
    try testing.expectEqualStrings("body", doc.blocks[1].content.text);
}

test "aliases are not enabled in front matter" {
    var doc = try parse(testing.allocator, "---\na: &x 1\nb: *x\n---\n\nbody\n");
    defer doc.deinit();
    try testing.expectEqual(BlockKind.error_box, doc.blocks[0].kind);
    try testing.expectEqualStrings("Error in user YAML: Alias parsing is not enabled.", doc.blocks[0].content.text);
    try testing.expectEqualStrings("---\na: &x 1\nb: *x\n---\n", doc.blocks[1].content.text);
}

test "front matter that is not a mapping is ordinary markdown" {
    var doc = try parse(testing.allocator, "---\n[a, b]\n---\n\nbody\n");
    defer doc.deinit();
    try testing.expectEqual(BlockKind.hr, doc.blocks[0].kind);
    try testing.expectEqual(BlockKind.h2, doc.blocks[1].kind);
}

test "an empty front matter mapping draws no rows" {
    var doc = try parse(testing.allocator, "---\n{}\n---\n\nbody\n");
    defer doc.deinit();
    try testing.expectEqual(BlockKind.table, doc.blocks[0].kind);
    try testing.expectEqual(@as(usize, 0), doc.blocks[0].table.rows());
}

test "tables stripe every second row of a group" {
    const t: Table = .{ .columns = 1 };
    try testing.expect(!t.striped(0) and !t.striped(1) and t.striped(2) and t.striped(4));
    const kv: Table = .{ .columns = 2, .header_row = false, .header_col = true };
    try testing.expect(!kv.striped(0) and kv.striped(1) and !kv.striped(2) and kv.striped(3));
}

test "a map whose values are all nil or false has no value row" {
    var doc = try parse(testing.allocator, "---\na: {x: ~, y: false}\nb: {x: 0}\nc: [~]\nd: []\n---\n");
    defer doc.deinit();
    const t = doc.blocks[0].table;
    try testing.expectEqual(@as(usize, 1), t.nestedAt(0, 1).?.rows());
    try testing.expectEqual(@as(usize, 2), t.nestedAt(1, 1).?.rows());
    try testing.expectEqual(@as(usize, 0), t.nestedAt(2, 1).?.rows());
    try testing.expectEqual(@as(usize, 0), t.nestedAt(3, 1).?.rows());
}
