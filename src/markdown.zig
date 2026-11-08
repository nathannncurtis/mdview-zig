const std = @import("std");
const Allocator = std.mem.Allocator;
const inl = @import("inline.zig");
const highlight = @import("highlight.zig");
const blocks = @import("blocks.zig");
const yaml = @import("yaml.zig");
const links = @import("links.zig");
const html = @import("html.zig");

pub const Link = links.Link;
pub const Image = links.Image;

pub const Definition = blocks.Definition;

pub const BlockKind = enum { h1, h2, h3, h4, h5, h6, paragraph, code_block, hr, table, alert_title, error_box };

pub const code_scale: f32 = 0.85;
pub const code_radius: f32 = 6;
pub const code_pad_em: f32 = 0.4;
pub const code_bg: u24 = 0x656c76;
pub const code_bg_alpha: f32 = 0.2;
pub const hr_height: f32 = 4;
pub const hr_margin: f32 = 24;
pub const dd_inset: f32 = 16;
pub const float_gap: f32 = 20;
pub const details_marker_inset: f32 = 20;
pub const kbd_font_px: f32 = 11;

/// Byte offset and length within `Inline.text`.
pub const Span = [2]u32;

pub const StyleKind = enum { sub, kbd, underline, mark, tt };
pub const Styled = struct { span: Span, kind: StyleKind };
/// What a block is within its HTML element: a `summary` or `dt` line.
pub const Role = enum { none, summary, dt };
pub const Anchor = struct { name: []const u8, block: u32 };

pub const Inline = struct {
    text: []const u8 = "",
    bold: []const Span = &.{},
    italic: []const Span = &.{},
    code: []const Span = &.{},
    strike: []const Span = &.{},
    emoji: []const Span = &.{},
    links: []const Link = &.{},
    images: []const Image = &.{},
    sup: []const Span = &.{},
    styles: []const Styled = &.{},

    pub fn linkAt(self: Inline, byte: u32) ?Link {
        for (self.links) |l| if (byte >= l.start and byte < l.start + l.len) return l;
        return null;
    }

    pub fn imageAt(self: Inline, byte: u32) ?Image {
        for (self.images) |im| if (byte >= im.start and byte < im.start + im.len) return im;
        return null;
    }
};

pub const Align = enum { none, left, center, right };
pub const VAlign = enum { none, top, middle, bottom };

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
    /// Only HTML tables have these; kept behind a pointer so every `Table` copy stays small.
    ext: ?*const Extra = null,

    pub const Extra = struct {
        /// Parallel to `cells`: `{colspan, rowspan}` of the cell anchored there, `{0, 0}` where another cell covers it.
        spans: []const [2]u16 = &.{},
        /// Parallel to `cells`: the cell's own alignment, which wins over `aligns`.
        cell_aligns: []const Align = &.{},
        valigns: []const VAlign = &.{},
        /// Parallel to `cells`: the blocks of a cell that holds more than one run of text (Markdown blocks,
        /// lists, nested tables), empty for plain cells, which use `cells`.
        cell_blocks: []const []const Block = &.{},
    };

    pub fn spans(t: Table) []const [2]u16 {
        return if (t.ext) |e| e.spans else &.{};
    }

    pub fn cellBlocks(t: Table, row: usize, col: usize) []const Block {
        const e = t.ext orelse return &.{};
        return if (e.cell_blocks.len == 0) &.{} else e.cell_blocks[row * t.columns + col];
    }

    pub fn valignAt(t: Table, row: usize, col: usize) VAlign {
        const e = t.ext orelse return .none;
        return if (e.valigns.len == 0) .none else e.valigns[row * t.columns + col];
    }

    pub fn spanAt(t: Table, row: usize, col: usize) [2]u16 {
        const e = t.ext orelse return .{ 1, 1 };
        return if (e.spans.len == 0) .{ 1, 1 } else e.spans[row * t.columns + col];
    }

    pub fn alignAt(t: Table, row: usize, col: usize) Align {
        if (t.ext) |e| if (e.cell_aligns.len > 0 and e.cell_aligns[row * t.columns + col] != .none) return e.cell_aligns[row * t.columns + col];
        return if (col < t.aligns.len) t.aligns[col] else .none;
    }

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
pub const FrameKind = enum { quote, list, details, dd };

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
    /// `details`: stable across reloads, see `Details`.
    key: u64 = 0,
    default_open: bool = false,
};

pub fn kindInset(kind: FrameKind) f32 {
    return switch (kind) {
        .quote => quote_inset,
        .list => list_inset,
        .dd => dd_inset,
        .details => 0,
    };
}

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
    /// Horizontal placement of the lines, from `align` attributes on the enclosing HTML.
    alignment: Align = .none,
    role: Role = .none,

    pub fn insetBefore(b: Block, n: usize) f32 {
        var x: f32 = 0;
        for (b.frames[0..n]) |f| x += kindInset(f.kind);
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

/// Which `details` elements the reader has flipped, by `Frame.key`.
pub const DetailsState = std.AutoHashMapUnmanaged(u64, bool);

pub fn detailsOpen(f: Frame, state: *const DetailsState) bool {
    return state.get(f.key) orelse f.default_open;
}

/// A block inside a closed `details`; the summary of that element stays visible.
pub fn collapsed(b: Block, state: *const DetailsState) bool {
    var last: ?usize = null;
    for (b.frames, 0..) |f, i| if (f.kind == .details) {
        last = i;
    };
    for (b.frames, 0..) |f, i| {
        if (f.kind != .details or detailsOpen(f, state)) continue;
        if (b.role == .summary and last == i) continue;
        return true;
    }
    return false;
}

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []const Block = &.{},
    /// Link reference definitions (`[label]: dest "title"`) taken from the start of paragraphs, in
    /// source order, and removed from `blocks`. `label` is normalized: trimmed, whitespace collapsed,
    /// Unicode case folded.
    definitions: []const Definition = &.{},
    /// For each referenced footnote, in number order, the index in `blocks` of its first block.
    footnote_blocks: []const u32 = &.{},
    /// `a[name]`, `a[id]` and `[id]` targets, in source order; `block` is the block that follows.
    anchors: []const Anchor = &.{},

    pub fn anchorBlock(self: Document, name: []const u8) ?u32 {
        const bare = if (std.mem.startsWith(u8, name, "user-content-")) name["user-content-".len..] else name;
        for (self.anchors) |a| if (std.mem.eql(u8, a.name, name) or std.mem.eql(u8, a.name, bare)) return a.block;
        return null;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(gpa: Allocator, markdown: []const u8) Allocator.Error!Document {
    var doc: Document = .{ .arena = .init(gpa) };
    errdefer doc.arena.deinit();
    const a = doc.arena.allocator();

    // Footnote numbers follow the first reference, and a footnote body can add references,
    // so a first pass over the document settles the order and the back-reference counts.
    var seed: []const links.Note = &.{};
    if (std.mem.indexOf(u8, markdown, "[^") != null) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var first: Parser = .{ .a = scratch.allocator(), .work = scratch.allocator(), .tmp = .init(gpa), .refs = .init(scratch.allocator()), .hb = try html.Builder.init(gpa, .{}) };
        defer first.tmp.deinit();
        defer first.hb.deinit();
        try first.run(markdown, null);
        const copy = try a.alloc(links.Note, first.refs.order.items.len);
        for (copy, first.refs.order.items) |*c, n| c.* = .{ .label = try a.dupe(u8, n.label), .node = 0, .refs = n.refs };
        seed = copy;
    }

    var work: std.heap.ArenaAllocator = .init(gpa);
    defer work.deinit();
    var p: Parser = .{ .a = a, .work = work.allocator(), .tmp = .init(gpa), .refs = .init(work.allocator()), .seed = seed, .hb = try html.Builder.init(gpa, .{}) };
    defer p.tmp.deinit();
    defer p.hb.deinit();
    try p.run(markdown, &doc);
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
    links: Range,
    images: Range,
    sup: Range,
    styles: Range,
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
    alignment: Align = .none,
    role: Role = .none,
    header_row: bool = true,
    spans: Range = .{ .lo = 0, .hi = 0 },
    cell_aligns: Range = .{ .lo = 0, .hi = 0 },
    valigns: Range = .{ .lo = 0, .hi = 0 },
    cell_blocks: Range = .{ .lo = 0, .hi = 0 },
};

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
    /// Scratch space for the block tree and the raw blocks; freed once the document is built.
    work: Allocator,
    text: std.ArrayList(u8) = .empty,
    bold: std.ArrayList(Span) = .empty,
    italic: std.ArrayList(Span) = .empty,
    code: std.ArrayList(Span) = .empty,
    strike: std.ArrayList(Span) = .empty,
    emoji: std.ArrayList(Span) = .empty,
    links: std.ArrayList(Link) = .empty,
    images: std.ArrayList(Image) = .empty,
    sup: std.ArrayList(Span) = .empty,
    styles: std.ArrayList(Styled) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,
    spans: std.ArrayList([2]u16) = .empty,
    cell_aligns: std.ArrayList(Align) = .empty,
    valigns: std.ArrayList(VAlign) = .empty,
    hb: html.Builder,
    hf: ?Frag = null,
    /// The paragraph being parsed, when HTML tags inside it add spans to it.
    cur: ?*Frag = null,
    hs: std.ArrayList(HState) = .empty,
    /// Open HTML elements in event order, by node id.
    os: std.ArrayList(u32) = .empty,
    tb: ?*TableBuild = null,
    cell_blocks: std.ArrayList([]const RawBlock) = .empty,
    html_used: bool = false,
    html_ids: u32 = 0,
    ev_ctx: u32 = html.nil,
    run_ctx: u32 = html.nil,
    pre: u32 = 0,
    pic: bool = false,
    pic_src: ?[]const u8 = null,
    refs: links.Refs,
    seed: []const links.Note = &.{},
    backref: ?Backref = null,
    note_starts: std.ArrayList(u32) = .empty,
    tmp: std.heap.ArenaAllocator,
    blocks: std.ArrayList(RawBlock) = .empty,
    aligns: std.ArrayList(Align) = .empty,
    cells: std.ArrayList(RawInline) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    joined: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    leads: std.ArrayList(Lead) = .empty,

    const Backref = struct { number: u32, count: u32 };

    fn run(p: *Parser, markdown: []const u8, doc: ?*Document) Allocator.Error!void {
        const skip = try p.frontMatter(markdown);
        var tree_arena: std.heap.ArenaAllocator = .init(p.tmp.child_allocator);
        defer tree_arena.deinit();
        const tree = try blocks.build(tree_arena.allocator(), markdown[skip..]);
        for (tree.defs.items) |d| try p.refs.addDef(d.label, .{ .dest = d.dest, .title = d.title });
        for (tree.nodes.items, 0..) |n, i| if (n.kind == .footnote) try p.refs.addNote(n.label, @intCast(i));
        if (p.seed.len > 0) try p.refs.seed(p.seed);
        try p.walk(&tree, 0);
        try p.htmlFinish();
        try p.footnoteSection(&tree);
        if (doc) |d| {
            const defs = try p.a.alloc(Definition, tree.defs.items.len);
            for (defs, tree.defs.items) |*o, t| o.* = .{ .label = try p.a.dupe(u8, t.label), .dest = try p.a.dupe(u8, t.dest), .title = try p.a.dupe(u8, t.title) };
            d.definitions = defs;
            d.footnote_blocks = p.note_starts.items;
            d.anchors = p.anchors.items;
            tree_arena.deinit();
            tree_arena = .init(p.tmp.child_allocator);
            try p.finish(d);
        }
    }

    // Referenced footnotes follow the document after a rule, as the items of a numbered list.
    fn footnoteSection(p: *Parser, t: *const blocks.Tree) Allocator.Error!void {
        if (p.refs.order.items.len == 0) return;
        try p.emit(.{ .kind = .hr, .content = p.textFrom(p.textLen()) });
        const group: u32 = @intCast(t.nodes.items.len);
        var n: usize = 0;
        while (n < p.refs.order.items.len) : (n += 1) {
            const note = p.refs.order.items[n];
            const number: u32 = @intCast(n + 1);
            try p.frames.append(p.a, .{ .kind = .list, .id = group + number, .group = group, .ordered = true, .start = 1 });
            try p.leads.append(p.a, .{ .mark = .{ .kind = .number, .number = number }, .inset = p.frameInset(&.{}) });
            var consumed = false;
            try p.note_starts.append(p.a, @intCast(p.blocks.items.len));
            var c = t.nodes.items[note.node].first;
            while (c != blocks.none) : (c = t.nodes.items[c].next) {
                const last = t.nodes.items[c].next == blocks.none;
                if (last and t.nodes.items[c].kind == .paragraph) {
                    p.backref = .{ .number = number, .count = note.refs };
                    consumed = true;
                }
                try p.walk(t, c);
                if (p.backref != null) {
                    p.backref = null;
                    consumed = false;
                }
            }
            if (!consumed) {
                const r = p.textFrom(p.textLen());
                try p.backrefs(r.text.lo, number, note.refs);
                try p.emit(.{ .kind = .paragraph, .content = p.closeRange(r) });
            }
            if (p.leads.items.len > 0) try p.emit(.{ .kind = .paragraph, .content = try p.plain(" ") });
            _ = p.frames.pop();
        }
    }

    fn backrefs(p: *Parser, start: u32, number: u32, count: u32) Allocator.Error!void {
        for (1..count + 1) |nth| {
            if (nth > 1 or p.textLen() > start) try p.text.append(p.a, ' ');
            const arrow = if (nth == 1) "\u{21a9}" else try std.fmt.allocPrint(p.a, "\u{21a9}{d}", .{nth});
            if (nth > 1) try p.sup.append(p.a, .{ p.textLen() - start + 3, @intCast(arrow.len - 3) });
            try p.links.append(p.a, .{
                .start = p.textLen() - start,
                .len = @intCast(arrow.len),
                .target = try std.fmt.allocPrint(p.a, "#fnref-{d}-{d}", .{ number, nth }),
            });
            try p.text.appendSlice(p.a, arrow);
        }
    }

    fn emit(p: *Parser, raw: RawBlock) Allocator.Error!void {
        if (p.html_used) try p.ensureSummary(raw.role);
        var b = raw;
        if (p.html_used and b.alignment == .none) b.alignment = p.stackAlign();
        return p.emitAt(b, html.nil);
    }

    fn emitAt(p: *Parser, raw: RawBlock, last: u32) Allocator.Error!void {
        var b = raw;
        b.frames = try p.mergedFrames(last);
        b.marks = try p.a.dupe(Lead, p.leads.items);
        p.leads.clearRetainingCapacity();
        try p.sink().append(p.work, b);
    }

    fn plain(p: *Parser, s: []const u8) Allocator.Error!RawInline {
        const start = p.textLen();
        try p.text.appendSlice(p.a, s);
        return p.textFrom(start);
    }

    fn walk(p: *Parser, t: *const blocks.Tree, idx: u32) Allocator.Error!void {
        const node = t.nodes.items[idx];
        switch (node.kind) {
            .document, .item, .footnote, .html => {},
            else => try p.mdFlush(),
        }
        switch (node.kind) {
            .document, .item => {
                var c = node.first;
                while (c != blocks.none) : (c = t.nodes.items[c].next) try p.walk(t, c);
            },
            .list => {
                var c = node.first;
                var num = node.start;
                try p.mdOpen(if (node.ordered) .ol else .ul);
                while (c != blocks.none) : (c = t.nodes.items[c].next) {
                    const depth = p.listDepth(p.mdChain());
                    try p.frames.append(p.a, .{ .kind = .list, .id = c, .group = idx, .ordered = node.ordered, .start = node.start, .tight = node.tight });
                    try p.leads.append(p.a, .{
                        .mark = .{ .kind = if (node.ordered) .number else .bullet, .number = num, .depth = depth },
                        .inset = p.frameInset(p.mdChain()),
                    });
                    num +%= 1;
                    try p.mdOpen(.li);
                    try p.walk(t, c);
                    if (p.leads.items.len > 0) try p.emit(.{ .kind = .paragraph, .content = try p.plain(" ") });
                    try p.mdClose(.li);
                    _ = p.frames.pop();
                }
                try p.mdClose(if (node.ordered) .ol else .ul);
            },
            .quote => try p.quote(t, idx),
            .footnote => {},
            .paragraph => {
                p.noteTags(node.content.items);
                const opened = try p.leafOpen(.p);
                try p.paragraph(t, idx, node.content.items);
                try p.leafClose(.p, opened);
            },
            .heading => {
                const tag: html.MarkdownKind = @enumFromInt(@intFromEnum(html.MarkdownKind.h1) + node.level - 1);
                p.noteTags(node.content.items);
                const opened = try p.leafOpen(tag);
                try p.join(node.content.items);
                try p.emit(.{
                    .kind = @enumFromInt(@intFromEnum(BlockKind.h1) + node.level - 1),
                    .content = try p.parseInline(p.joined.items),
                });
                try p.leafClose(tag, opened);
            },
            .thematic => {
                _ = try p.leafOpen(.hr);
                try p.emit(.{ .kind = .hr, .content = p.textFrom(p.textLen()) });
            },
            .code => {
                const opened = try p.leafOpen(.pre);
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
                try p.leafClose(.pre, opened);
            },
            .html => try p.htmlBlock(node.content.items),
        }
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
        try p.mdOpen(.blockquote);
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
        try p.mdClose(.blockquote);
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
        try highlight.tokens(p.work, p.text.items[raw.lang.lo..raw.lang.hi], p.text.items[raw.content.text.lo..raw.content.text.hi], &list);
        return p.a.dupe(highlight.Token, list.items);
    }

    fn paragraph(p: *Parser, t: *const blocks.Tree, idx: u32, content: []const u8) Allocator.Error!void {
        const node = t.nodes.items[idx];
        const in_item = t.nodes.items[node.parent].kind == .item;
        const compact = in_item and t.nodes.items[t.nodes.items[node.parent].parent].tight;

        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
        while (it.next()) |l| try lines.append(p.work, std.mem.trimStart(u8, l, " \t"));

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
            try src.appendSlice(p.work, l);
            try src.append(p.work, '\n');
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
        var content = try p.parseInline(text);
        if (p.backref) |b| {
            p.backref = null;
            try p.backrefs(content.text.lo, b.number, b.count);
            content = p.closeRange(content);
        }
        try p.emit(.{ .kind = .paragraph, .content = content, .compact = compact });
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

        switch (try yaml.parse(p.work, body)) {
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
        try p.detailsKeys();
        const cells = try p.a.alloc(Inline, p.cells.items.len);
        for (cells, p.cells.items) |*c, raw| c.* = p.resolve(raw);
        doc.blocks = try p.build(p.blocks.items, cells);
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
                    .header_row = raw.header_row,
                    .ext = if (raw.spans.hi > raw.spans.lo) try p.tableExtra(raw, cells) else null,
                },
                .lang = p.text.items[raw.lang.lo..raw.lang.hi],
                .frames = raw.frames,
                .marks = raw.marks,
                .compact = raw.compact,
                .alignment = raw.alignment,
                .role = raw.role,
            };
        }
        return out;
    }

    fn tableExtra(p: *Parser, raw: RawBlock, cells: []const Inline) Allocator.Error!*const Table.Extra {
        const e = try p.a.create(Table.Extra);
        e.* = .{
            .spans = p.spans.items[raw.spans.lo..raw.spans.hi],
            .cell_aligns = p.cell_aligns.items[raw.cell_aligns.lo..raw.cell_aligns.hi],
            .valigns = p.valigns.items[raw.valigns.lo..raw.valigns.hi],
        };
        if (raw.cell_blocks.hi > raw.cell_blocks.lo) {
            const lists = p.cell_blocks.items[raw.cell_blocks.lo..raw.cell_blocks.hi];
            const out = try p.a.alloc([]const Block, lists.len);
            for (out, lists) |*o, l| o.* = if (l.len == 0) &.{} else try p.build(l, cells);
            e.cell_blocks = out;
        }
        return e;
    }

    fn resolve(p: *const Parser, r: RawInline) Inline {
        return .{
            .text = p.text.items[r.text.lo..r.text.hi],
            .bold = p.bold.items[r.bold.lo..r.bold.hi],
            .italic = p.italic.items[r.italic.lo..r.italic.hi],
            .code = p.code.items[r.code.lo..r.code.hi],
            .strike = p.strike.items[r.strike.lo..r.strike.hi],
            .emoji = p.emoji.items[r.emoji.lo..r.emoji.hi],
            .links = p.links.items[r.links.lo..r.links.hi],
            .images = p.images.items[r.images.lo..r.images.hi],
            .sup = p.sup.items[r.sup.lo..r.sup.hi],
            .styles = p.styles.items[r.styles.lo..r.styles.hi],
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
        const l: u32 = @intCast(p.links.items.len);
        const im: u32 = @intCast(p.images.items.len);
        const su: u32 = @intCast(p.sup.items.len);
        const sy: u32 = @intCast(p.styles.items.len);
        return .{
            .text = .{ .lo = start, .hi = p.textLen() },
            .bold = .{ .lo = b, .hi = b },
            .italic = .{ .lo = i, .hi = i },
            .code = .{ .lo = c, .hi = c },
            .strike = .{ .lo = st, .hi = st },
            .emoji = .{ .lo = em, .hi = em },
            .links = .{ .lo = l, .hi = l },
            .images = .{ .lo = im, .hi = im },
            .sup = .{ .lo = su, .hi = su },
            .styles = .{ .lo = sy, .hi = sy },
        };
    }

    fn tryTable(p: *Parser, header_line: []const u8, delim_line: []const u8, row_lines: []const []const u8) Allocator.Error!bool {
        const header = try splitRow(p.work, header_line);
        const delims = try splitRow(p.work, delim_line);
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
        for (row_lines) |row| try p.addRow(try splitRow(p.work, row), columns);

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
                try p.cells.append(p.work, p.textFrom(p.textLen()));
                continue;
            }
            p.scratch.clearRetainingCapacity();
            const raw = cells[col];
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == '|') i += 1;
                try p.scratch.append(p.a, raw[i]);
            }
            try p.cells.append(p.work, try p.parseInline(p.scratch.items));
        }
    }

    fn parseInline(p: *Parser, raw: []const u8) Allocator.Error!RawInline {
        _ = p.tmp.reset(.retain_capacity);
        const ta = p.tmp.allocator();
        const hooks: inl.Hooks = .{ .ctx = p, .link = linkHook, .autolink = autolinkHook, .bare = bareHook };
        const parsed = try inl.parseWithHeap(ta, p.tmp.child_allocator, raw, &hooks);
        var f: Frag = .init(ta);
        defer p.cur = null;
        if (p.html_used) {
            p.cur = &f;
            try p.hb.markdownText();
            try p.drain();
        }

        const Open = struct { kind: inl.Kind, pos: u32, url: []const u8, title: []const u8, alt: []const u8 };
        var stack: std.ArrayList(Open) = .empty;
        var copied: usize = 0;
        for (parsed.events) |ev| {
            if (!p.hidden()) try f.put(parsed.text[copied..ev.pos]);
            copied = ev.pos;
            const at: u32 = @intCast(f.text.items.len);
            switch (ev.tag) {
                .open => try stack.append(ta, .{ .kind = ev.kind, .pos = at, .url = ev.url, .title = ev.title, .alt = ev.raw }),
                .close => {
                    const open = stack.pop() orelse continue;
                    const span: Span = .{ open.pos, at - open.pos };
                    switch (open.kind) {
                        .em => try f.italic.append(ta, span),
                        .strong => try f.bold.append(ta, span),
                        .strike => try f.strike.append(ta, span),
                        .code => try f.code.append(ta, span),
                        .emoji => try f.emoji.append(ta, span),
                        .sup => try f.sup.append(ta, span),
                        .link => try f.links.append(ta, .{
                            .start = span[0],
                            .len = span[1],
                            .target = try p.a.dupe(u8, open.url),
                            .title = try p.a.dupe(u8, open.title),
                        }),
                        .image => try f.images.append(ta, .{
                            .start = span[0],
                            .len = span[1],
                            .target = try p.a.dupe(u8, open.url),
                            .title = try p.a.dupe(u8, open.title),
                            .alt = try p.a.dupe(u8, open.alt),
                        }),
                    }
                },
                .html => {
                    p.cur = &f;
                    try p.inlineHtml(ev.raw);
                },
                .soft, .hard => {},
            }
        }
        if (!p.hidden()) try f.put(parsed.text[copied..]);
        if (p.html_used) try p.closeOpenSpans(&f);
        return p.commit(&f);
    }

    // Elements still open at the end of the paragraph cover all of it, and go on covering the next one.
    fn closeOpenSpans(p: *Parser, f: *Frag) Allocator.Error!void {
        for (p.os.items[@min(p.cellOsBase(), p.os.items.len)..]) |id| {
            const n = p.hb.nodes.items[id];
            const el = elOf(n.name) orelse continue;
            if (!isInlineEl(el)) continue;
            const st = p.state(id);
            try p.spanFor(f, el, n.attrs, st.pos);
            st.pos = 0;
        }
    }

    fn mdChain(p: *Parser) []const html.Ancestor {
        if (!p.html_used) return &.{};
        p.ev_ctx = html.nil;
        p.run_ctx = html.nil;
        return p.hb.ancestors();
    }

    fn frag(p: *Parser) *Frag {
        if (p.cur) |c| return c;
        if (p.hf == null) p.hf = .init(p.work);
        return &p.hf.?;
    }

    fn nextHtmlId(p: *Parser) u32 {
        p.html_ids += 1;
        return html_id_base + p.html_ids;
    }

    fn htmlBlock(p: *Parser, content: []const u8) Allocator.Error!void {
        p.html_used = true;
        try p.hb.feedBlock(content);
        try p.drain();
    }

    fn inlineHtml(p: *Parser, raw: []const u8) Allocator.Error!void {
        p.html_used = true;
        try p.hb.feedInlineTag(raw);
        try p.drain();
    }

    // A paragraph that may hold a tag enters the HTML tree whole, so formatting left open reaches the next one.
    fn noteTags(p: *Parser, content: []const u8) void {
        if (p.html_used) return;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, content, i, '<')) |lt| : (i = lt + 1) {
            if (lt + 1 < content.len and (std.ascii.isAlphabetic(content[lt + 1]) or content[lt + 1] == '/' or content[lt + 1] == '!' or content[lt + 1] == '?')) {
                p.html_used = true;
                return;
            }
        }
    }

    fn hidden(p: *Parser) bool {
        return p.html_used and p.hb.hidden();
    }

    fn drain(p: *Parser) Allocator.Error!void {
        var i: usize = 0;
        while (i < p.hb.events.items.len) : (i += 1) try p.event(p.hb.events.items[i]);
        p.hb.clearEvents();
    }

    fn event(p: *Parser, ev: html.Event) Allocator.Error!void {
        const n = p.hb.nodes.items[ev.node];
        switch (ev.kind) {
            .text => try p.onText(ev.node, ev.text),
            .open => if (!n.markdown) try p.onOpen(ev.node),
            .close => if (!n.markdown) try p.onClose(ev.node),
        }
    }

    fn elOf(name: []const u8) ?El {
        return std.meta.stringToEnum(El, name);
    }

    fn state(p: *Parser, id: u32) *HState {
        return &p.hs.items[id];
    }

    fn ensureState(p: *Parser, id: u32) Allocator.Error!void {
        if (p.hs.items.len <= id) try p.hs.appendNTimes(p.work, .{}, id + 1 - p.hs.items.len);
    }

    fn cellStart(p: *Parser, chain: []const html.Ancestor) usize {
        const c = p.cellOf() orelse return 0;
        var start: usize = 0;
        for (chain, 0..) |a, k| if (a.node == c.node) {
            start = k + 1;
        };
        return start;
    }

    fn anc(p: *Parser) []const html.Ancestor {
        const ctx = if (p.run_ctx != html.nil) p.run_ctx else p.ev_ctx;
        return if (ctx == html.nil) p.hb.ancestors() else p.hb.ancestorsOf(ctx);
    }

    fn startRun(p: *Parser, was_empty: bool, ctx: u32) void {
        if (p.cur == null and was_empty and p.frag().any) p.run_ctx = ctx;
    }

    fn onText(p: *Parser, node: u32, s: []const u8) Allocator.Error!void {
        p.ev_ctx = node;
        const f = p.frag();
        const was_empty = !f.any;
        try f.htmlText(s, p.pre > 0);
        p.startRun(was_empty, node);
    }

    fn onOpen(p: *Parser, id: u32) Allocator.Error!void {
        const n = p.hb.nodes.items[id];
        const el = elOf(n.name) orelse return;
        try p.ensureState(id);
        p.state(id).* = .{ .md_depth = @intCast(p.frames.items.len) };
        p.ev_ctx = n.parent;
        try p.anchor(n.attrs);
        try p.os.append(p.work, id);
        if (el == .pre) p.pre += 1;
        if (isTablePart(el)) return p.tableOpen(el, id);
        const f = p.frag();
        if (el.isVoid()) return p.voidOpen(f, el, n);
        if (isBlockEl(el)) {
            if (p.cur == null) try p.htmlFlush();
            return p.blockEnter(el, id);
        }
        try f.flushSpace();
        p.state(id).pos = @intCast(f.text.items.len);
        try p.inlineOpen(f, el);
    }

    fn onClose(p: *Parser, id: u32) Allocator.Error!void {
        const n = p.hb.nodes.items[id];
        const el = elOf(n.name) orelse return;
        var i = p.os.items.len;
        while (i > 0) {
            i -= 1;
            if (p.os.items[i] == id) {
                _ = p.os.orderedRemove(i);
                break;
            }
        }
        p.ev_ctx = id;
        if (el == .pre) p.pre -|= 1;
        if (isTablePart(el)) return p.tableClose(el, id);
        if (el.isVoid()) return;
        const st = p.state(id).*;
        if (!isBlockEl(el)) return p.inlineClose(p.frag(), el, n.attrs, st.pos);
        if (p.cur != null) return;
        if (el == .summary) p.markSummary();
        try p.htmlFlush();
        switch (el) {
            .li => if (p.leads.items.len > 0) try p.emit(.{ .kind = .paragraph, .content = try p.plain(" ") }),
            .details => if (!st.seen) try p.synthSummary(id),
            else => {},
        }
        p.run_ctx = html.nil;
    }

    fn mdFlush(p: *Parser) Allocator.Error!void {
        if (!p.html_used) return;
        try p.htmlFlush();
        p.ev_ctx = html.nil;
        p.run_ctx = html.nil;
    }

    fn mdOpen(p: *Parser, kind: html.MarkdownKind) Allocator.Error!void {
        try p.hb.openMarkdown(kind);
        try p.drain();
        p.ev_ctx = html.nil;
        p.run_ctx = html.nil;
    }

    fn mdClose(p: *Parser, kind: html.MarkdownKind) Allocator.Error!void {
        try p.hb.closeMarkdown(kind);
        try p.drain();
        p.ev_ctx = html.nil;
        p.run_ctx = html.nil;
    }

    // Leaf blocks only enter the HTML tree once HTML has shown up, which keeps plain documents cheap.
    fn leafOpen(p: *Parser, kind: html.MarkdownKind) Allocator.Error!bool {
        if (!p.html_used) return false;
        try p.mdOpen(kind);
        return true;
    }

    fn leafClose(p: *Parser, kind: html.MarkdownKind, opened: bool) Allocator.Error!void {
        if (opened) try p.mdClose(kind);
    }

    const Kind = struct { kind: BlockKind = .paragraph, role: Role = .none, compact: bool = false };

    fn curKind(p: *Parser) Kind {
        const chain = p.anc();
        var i = chain.len;
        while (i > 0) {
            i -= 1;
            if (chain[i].markdown) continue;
            const el = elOf(chain[i].name) orelse continue;
            switch (el) {
                .h1, .h2, .h3, .h4, .h5, .h6 => return .{ .kind = @enumFromInt(@intFromEnum(BlockKind.h1) + @intFromEnum(el)) },
                .pre => return .{ .kind = .code_block },
                .summary => return .{ .role = .summary },
                .dt => return .{ .role = .dt },
                .li => return .{ .compact = true },
                .p, .div, .section, .ul, .ol, .dl, .dd, .blockquote, .details, .table, .td, .th => return .{},
                else => {},
            }
        }
        return .{};
    }

    fn htmlFlush(p: *Parser) Allocator.Error!void {
        if (p.cur != null) return;
        const f = p.frag();
        if (!f.any) {
            f.reset();
            p.run_ctx = html.nil;
            return;
        }
        const k = p.curKind();
        const base = @min(p.cellOsBase(), p.os.items.len);
        for (p.os.items[base..]) |id| {
            const n = p.hb.nodes.items[id];
            const el = elOf(n.name) orelse continue;
            if (!isInlineEl(el)) continue;
            const st = p.state(id);
            try p.spanFor(f, el, n.attrs, st.pos);
            st.pos = 0;
        }
        if (k.kind != .code_block) {
            const kept = std.mem.trimEnd(u8, f.text.items, "\n").len;
            if (kept > 0 and kept < f.text.items.len) f.truncate(@intCast(kept));
        }
        const raw = try p.commit(f);
        f.reset();
        try p.emit(.{ .kind = k.kind, .role = k.role, .content = raw, .compact = k.compact });
        p.run_ctx = html.nil;
    }

    fn blockEnter(p: *Parser, el: El, id: u32) Allocator.Error!void {
        const n = p.hb.nodes.items[id];
        const st = p.state(id);
        switch (el) {
            .blockquote, .details, .dd => st.id = p.nextHtmlId(),
            .ul, .ol => {
                st.id = p.nextHtmlId();
                st.ordered = el == .ol;
                st.pos = if (el == .ol) parseCount(attrOf(n.attrs, "start")) orelse 1 else 1;
                st.n = st.pos;
            },
            .li => {
                if (p.cur != null) return;
                const chain = p.anc();
                var parent: ?u32 = null;
                var i = chain.len;
                while (i > 0 and parent == null) {
                    i -= 1;
                    if (!chain[i].markdown and (std.mem.eql(u8, chain[i].name, "ul") or std.mem.eql(u8, chain[i].name, "ol"))) parent = chain[i].node;
                }
                const depth = p.listDepth(chain);
                const inset = p.frameInset(chain) + list_inset;
                const me = p.state(id);
                me.id = p.nextHtmlId();
                var num: u32 = 1;
                if (parent) |pn| {
                    const par = p.state(pn);
                    me.group = par.id;
                    me.ordered = par.ordered;
                    me.n = par.pos;
                    num = par.n;
                    par.n +%= 1;
                } else me.group = me.id;
                try p.leads.append(p.a, .{
                    .mark = .{ .kind = if (me.ordered) .number else .bullet, .number = num, .depth = depth },
                    .inset = inset,
                });
            },
            else => {},
        }
    }

    fn voidOpen(p: *Parser, f: *Frag, el: El, n: html.Node) Allocator.Error!void {
        switch (el) {
            .br => {
                const was_empty = !f.any;
                try f.putNl();
                p.startRun(was_empty, n.parent);
            },
            .img => {
                const was_empty = !f.any;
                try p.image(f, n);
                p.startRun(was_empty, n.parent);
            },
            .source => try p.pictureSource(n),
            .hr => if (p.cur == null) {
                try p.htmlFlush();
                try p.emit(.{ .kind = .hr, .content = p.textFrom(p.textLen()) });
            },
            else => {},
        }
    }

    fn inlineOpen(p: *Parser, f: *Frag, el: El) Allocator.Error!void {
        switch (el) {
            .q => try f.put("\u{201c}"),
            .rt => try f.put("("),
            .rp => f.suppress += 1,
            .picture => {
                p.pic = true;
                p.pic_src = null;
            },
            else => {},
        }
    }

    fn inlineClose(p: *Parser, f: *Frag, el: El, attrs: []const html.Attr, start: u32) Allocator.Error!void {
        switch (el) {
            .q => try f.put("\u{201d}"),
            .rt => try f.put(")"),
            .rp => f.suppress -|= 1,
            .picture => {
                p.pic = false;
                p.pic_src = null;
            },
            else => {},
        }
        try p.spanFor(f, el, attrs, start);
    }

    fn spanFor(p: *Parser, f: *Frag, el: El, attrs: []const html.Attr, start: u32) Allocator.Error!void {
        const end: u32 = @intCast(f.text.items.len);
        if (end <= start) return;
        const sp: Span = .{ start, end - start };
        switch (el) {
            .b, .strong => try f.bold.append(f.a, sp),
            .i, .em, .@"var" => try f.italic.append(f.a, sp),
            .code, .samp => try f.code.append(f.a, sp),
            .del, .s, .strike => try f.strike.append(f.a, sp),
            .sup => try f.sup.append(f.a, sp),
            .tt => try f.styles.append(f.a, .{ .span = sp, .kind = .tt }),
            .sub => try f.styles.append(f.a, .{ .span = sp, .kind = .sub }),
            .kbd => try f.styles.append(f.a, .{ .span = sp, .kind = .kbd }),
            .mark => try f.styles.append(f.a, .{ .span = sp, .kind = .mark }),
            .ins => try f.styles.append(f.a, .{ .span = sp, .kind = .underline }),
            .a => if (attrOf(attrs, "href")) |href| {
                const target = std.mem.trim(u8, href, " \t\r\n");
                if (target.len > 0) try f.links.append(f.a, .{
                    .start = sp[0],
                    .len = sp[1],
                    .target = try p.a.dupe(u8, target),
                    .title = try p.a.dupe(u8, attrOf(attrs, "title") orelse ""),
                });
            },
            else => {},
        }
    }

    // The sanitiser drops file: and drive-letter sources, which this viewer keeps, so the raw attribute is read.
    fn image(p: *Parser, f: *Frag, n: html.Node) Allocator.Error!void {
        const alt = attrOf(n.attrs, "alt") orelse "";
        const own = attrOf(n.raw_attrs, "src") orelse "";
        const src = std.mem.trim(u8, if (p.pic) (p.pic_src orelse own) else own, " \t\r\n");
        if (src.len == 0 or !safeUrl(src)) return f.put(alt);
        const side = attrOf(n.attrs, "align") orelse "";
        const w = parseDim(attrOf(n.attrs, "width"));
        const h = parseDim(attrOf(n.attrs, "height"));
        const start: u32 = @intCast(f.text.items.len);
        try f.put(inl.object_char);
        try f.images.append(f.a, .{
            .start = start,
            .len = inl.object_char.len,
            .target = try p.a.dupe(u8, src),
            .title = try p.a.dupe(u8, attrOf(n.attrs, "title") orelse ""),
            .alt = try p.a.dupe(u8, alt),
            .width = w.px,
            .width_pct = w.pct,
            .height = h.px,
            .float = if (std.ascii.eqlIgnoreCase(side, "left")) .left else if (std.ascii.eqlIgnoreCase(side, "right")) .right else .none,
        });
    }

    fn pictureSource(p: *Parser, n: html.Node) Allocator.Error!void {
        if (!p.pic or p.pic_src != null) return;
        if (attrOf(n.attrs, "media")) |m| {
            var buf: [96]u8 = undefined;
            var len: usize = 0;
            for (m) |c| if (c != ' ' and len < buf.len) {
                buf[len] = std.ascii.toLower(c);
                len += 1;
            };
            if (std.mem.indexOf(u8, buf[0..len], "prefers-color-scheme:dark") == null) return;
        }
        var it = std.mem.tokenizeAny(u8, attrOf(n.raw_attrs, "srcset") orelse return, " \t\r\n");
        const url = std.mem.trimEnd(u8, it.next() orelse return, ",");
        if (url.len == 0 or !safeUrl(url)) return;
        p.pic_src = try p.a.dupe(u8, url);
    }

    fn anchor(p: *Parser, attrs: []const html.Attr) Allocator.Error!void {
        for ([_][]const u8{ "id", "name" }) |key| {
            const v = attrOf(attrs, key) orelse continue;
            if (v.len == 0) continue;
            try p.anchors.append(p.a, .{ .name = try p.a.dupe(u8, v), .block = @intCast(p.blocks.items.len) });
        }
    }

    fn commit(p: *Parser, f: *const Frag) Allocator.Error!RawInline {
        const r = p.textFrom(p.textLen());
        try p.text.appendSlice(p.a, f.text.items);
        try p.bold.appendSlice(p.a, f.bold.items);
        try p.italic.appendSlice(p.a, f.italic.items);
        try p.code.appendSlice(p.a, f.code.items);
        try p.strike.appendSlice(p.a, f.strike.items);
        try p.emoji.appendSlice(p.a, f.emoji.items);
        try p.sup.appendSlice(p.a, f.sup.items);
        try p.styles.appendSlice(p.a, f.styles.items);
        try p.links.appendSlice(p.a, f.links.items);
        try p.images.appendSlice(p.a, f.images.items);
        return p.closeRange(r);
    }

    fn elementFrame(p: *Parser, a: html.Ancestor) ?Frame {
        if (a.markdown or a.node >= p.hs.items.len) return null;
        const st = p.hs.items[a.node];
        if (st.id == 0) return null;
        const el = elOf(a.name) orelse return null;
        return switch (el) {
            .details => .{ .kind = .details, .id = st.id, .default_open = attrOf(a.attrs, "open") != null },
            .blockquote => .{ .kind = .quote, .id = st.id },
            .dd => .{ .kind = .dd, .id = st.id },
            .li => .{ .kind = .list, .id = st.id, .group = st.group, .ordered = st.ordered, .start = st.n },
            else => null,
        };
    }

    fn frameInset(p: *Parser, chain: []const html.Ancestor) f32 {
        var x: f32 = 0;
        for (p.frames.items) |f| x += kindInset(f.kind);
        for (chain) |a| if (p.elementFrame(a)) |f| {
            x += kindInset(f.kind);
        };
        return x;
    }

    fn listDepth(p: *Parser, chain: []const html.Ancestor) u8 {
        var n: u8 = 0;
        for (p.frames.items) |f| n +|= @intFromBool(f.kind == .list);
        for (chain) |a| if (p.elementFrame(a)) |f| {
            n +|= @intFromBool(f.kind == .list);
        };
        return n;
    }

    /// The Markdown frames with the open HTML elements' frames woven in, outermost first; frames of the
    /// innermost table cell start fresh, and `last` (a node id or `html.nil`) ends the chain early.
    fn mergedFrames(p: *Parser, last: u32) Allocator.Error![]Frame {
        if (!p.html_used) return p.a.dupe(Frame, p.frames.items);
        const chain = p.anc();
        var ai = p.cellStart(chain);
        const md_from: usize = if (p.cellOf()) |c| c.md_base else 0;
        var out: std.ArrayList(Frame) = .empty;
        var stopped = false;
        for (md_from..p.frames.items.len + 1) |i| {
            while (!stopped and ai < chain.len) {
                const a = chain[ai];
                if (!a.markdown and a.node < p.hs.items.len and p.hs.items[a.node].md_depth > i) break;
                ai += 1;
                if (p.elementFrame(a)) |f| try out.append(p.a, f);
                if (a.node == last) stopped = true;
            }
            if (stopped) break;
            if (i < p.frames.items.len) try out.append(p.a, p.frames.items[i]);
        }
        return out.items;
    }

    fn stackAlign(p: *Parser) Align {
        const chain = p.anc();
        var i = chain.len;
        while (i > 0) {
            i -= 1;
            if (chain[i].markdown) continue;
            const el = elOf(chain[i].name) orelse continue;
            switch (el) {
                .p, .div, .section, .h1, .h2, .h3, .h4, .h5, .h6, .td, .th => {},
                else => continue,
            }
            const v = attrOf(chain[i].attrs, "align") orelse continue;
            if (std.ascii.eqlIgnoreCase(v, "center") or std.ascii.eqlIgnoreCase(v, "middle")) return .center;
            if (std.ascii.eqlIgnoreCase(v, "left")) return .left;
            if (std.ascii.eqlIgnoreCase(v, "right")) return .right;
        }
        return .none;
    }

    fn markSummary(p: *Parser) void {
        const chain = p.anc();
        var i = chain.len;
        while (i > 0) {
            i -= 1;
            if (!chain[i].markdown and std.mem.eql(u8, chain[i].name, "details")) {
                p.state(chain[i].node).seen = true;
                return;
            }
        }
    }

    fn ensureSummary(p: *Parser, role: Role) Allocator.Error!void {
        if (role == .summary or !p.html_used) return;
        var chain = p.anc();
        var k: usize = p.cellStart(chain);
        while (k < chain.len) : (k += 1) {
            const a = chain[k];
            if (a.markdown or !std.mem.eql(u8, a.name, "details") or a.node >= p.hs.items.len) continue;
            if (p.hs.items[a.node].seen or p.hs.items[a.node].id == 0) continue;
            try p.synthSummary(a.node);
            chain = p.anc();
            k = @min(k, chain.len);
        }
    }

    // A details element without a summary shows the browser's default label.
    fn synthSummary(p: *Parser, node: u32) Allocator.Error!void {
        p.state(node).seen = true;
        try p.emitAt(.{ .kind = .paragraph, .role = .summary, .content = try p.plain("Details") }, node);
    }

    fn detailsKeys(p: *Parser) Allocator.Error!void {
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        var keys: std.AutoHashMapUnmanaged(u32, u64) = .empty;
        try p.collectKeys(p.blocks.items, &seen, &keys);
        for (p.cell_blocks.items) |l| try p.collectKeys(l, &seen, &keys);
        if (keys.count() == 0) return;
        for (p.blocks.items) |b| for (b.frames) |*f| if (f.kind == .details) {
            f.key = keys.get(f.id) orelse 0;
        };
        for (p.cell_blocks.items) |l| for (l) |b| for (b.frames) |*f| if (f.kind == .details) {
            f.key = keys.get(f.id) orelse 0;
        };
    }

    fn collectKeys(p: *Parser, raws: []const RawBlock, seen: *std.StringHashMapUnmanaged(u32), keys: *std.AutoHashMapUnmanaged(u32, u64)) Allocator.Error!void {
        for (raws) |b| {
            if (b.role != .summary) continue;
            var i = b.frames.len;
            const at = while (i > 0) {
                i -= 1;
                if (b.frames[i].kind == .details) break i;
            } else continue;
            const text = p.text.items[b.content.text.lo..b.content.text.hi];
            const slot = try seen.getOrPut(p.work, text);
            slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 0;
            try keys.put(p.work, b.frames[at].id, std.hash.Wyhash.hash(slot.value_ptr.*, text));
        }
    }

    fn cellOf(p: *Parser) ?*CellBuild {
        var t = p.tb;
        while (t) |x| : (t = x.parent) if (x.cell) |*c| return c;
        return null;
    }

    fn cellOsBase(p: *Parser) usize {
        return if (p.cellOf()) |c| c.os_base else 0;
    }

    fn sink(p: *Parser) *std.ArrayList(RawBlock) {
        return if (p.cellOf()) |c| &c.blocks else &p.blocks;
    }

    fn tableDepth(p: *const Parser) u32 {
        var n: u32 = 0;
        var t = p.tb;
        while (t) |x| : (t = x.parent) n += 1;
        return n;
    }

    fn tableOpen(p: *Parser, el: El, id: u32) Allocator.Error!void {
        const n = p.hb.nodes.items[id];
        if (el == .table) {
            if (p.tb) |t| if (t.flat > 0 or p.tableDepth() >= max_table_nesting) {
                t.flat += 1;
                return;
            };
            if (p.cur == null) try p.htmlFlush();
            const t = try p.work.create(TableBuild);
            t.* = .{ .parent = p.tb };
            p.tb = t;
            return;
        }
        const t = p.tb orelse return;
        if (t.flat > 0) return;
        switch (el) {
            .tr => t.rows += 1,
            .td, .th => {
                try p.htmlFlush();
                const al = attrOf(n.attrs, "align") orelse "";
                const va = attrOf(n.attrs, "valign") orelse "";
                t.cell = .{
                    .node = id,
                    .md_base = p.frames.items.len,
                    .os_base = p.os.items.len,
                    .th = el == .th,
                    .colspan = clampCount(parseCount(attrOf(n.attrs, "colspan")), max_colspan),
                    .rowspan = clampCount(parseCount(attrOf(n.attrs, "rowspan")), max_rowspan),
                    .al = if (std.ascii.eqlIgnoreCase(al, "center")) .center else if (std.ascii.eqlIgnoreCase(al, "right")) .right else if (std.ascii.eqlIgnoreCase(al, "left")) .left else .none,
                    .va = if (std.ascii.eqlIgnoreCase(va, "top")) .top else if (std.ascii.eqlIgnoreCase(va, "bottom")) .bottom else if (std.ascii.eqlIgnoreCase(va, "middle")) .middle else .none,
                    .row = t.rows -| 1,
                };
            },
            else => {},
        }
    }

    fn tableClose(p: *Parser, el: El, id: u32) Allocator.Error!void {
        _ = id;
        const t = p.tb orelse return;
        switch (el) {
            .table => {
                if (t.flat > 0) {
                    t.flat -= 1;
                    return;
                }
                if (p.cur == null) try p.htmlFlush();
                p.tb = t.parent;
                try p.tableEnd(t);
            },
            .td, .th => if (t.flat == 0) try p.closeCell(t),
            else => {},
        }
    }

    fn closeCell(p: *Parser, t: *TableBuild) Allocator.Error!void {
        if (t.cell == null) return;
        try p.htmlFlush();
        const c = t.cell.?;
        t.cell = null;
        settle(c.blocks.items);
        var cell: TableCell = .{
            .raw = p.textFrom(p.textLen()),
            .blocks = &.{},
            .colspan = c.colspan,
            .rowspan = c.rowspan,
            .th = c.th,
            .al = c.al,
            .va = c.va,
            .row = c.row,
        };
        if (c.blocks.items.len == 1 and singleRun(c.blocks.items[0], c.al)) {
            cell.raw = c.blocks.items[0].content;
        } else if (c.blocks.items.len > 0) {
            cell.blocks = c.blocks.items;
        }
        try t.cells.append(p.work, cell);
    }

    // Tables and runs still open at the end of the document close as the browser closes them at EOF.
    fn htmlFinish(p: *Parser) Allocator.Error!void {
        if (!p.html_used) return;
        p.cur = null;
        try p.htmlFlush();
        while (p.tb) |t| {
            if (t.flat == 0) {
                try p.closeCell(t);
                p.tb = t.parent;
                try p.tableEnd(t);
            } else {
                t.flat -= 1;
            }
            try p.htmlFlush();
        }
        p.ev_ctx = html.nil;
        p.run_ctx = html.nil;
    }

    fn singleRun(b: RawBlock, al: Align) bool {
        return b.kind == .paragraph and b.frames.len == 0 and b.marks.len == 0 and b.role == .none and (b.alignment == .none or b.alignment == al);
    }

    fn tableEnd(p: *Parser, t: *TableBuild) Allocator.Error!void {
        if (t.cells.items.len == 0) return;
        const rows_all: u32 = t.rows;
        var occ: std.AutoHashMapUnmanaged(u64, void) = .empty;
        const Placed = struct { row: u32, col: u32, cs: u32, rs: u32 };
        const placed = try p.work.alloc(?Placed, t.cells.items.len);
        var columns: u32 = 0;
        var marked: u32 = 0;
        var cur_row: u32 = std.math.maxInt(u32);
        var cursor: u32 = 0;
        for (t.cells.items, placed) |c, *slot| {
            slot.* = null;
            if (c.row >= rows_all or marked >= max_table_slots) continue;
            if (c.row != cur_row) {
                cur_row = c.row;
                cursor = 0;
            }
            var col = cursor;
            while (col < max_colspan and occ.contains(slotKey(c.row, col))) col += 1;
            if (col >= max_colspan) continue;
            var cs: u32 = 1;
            while (cs < c.colspan and col + cs < max_colspan and !occ.contains(slotKey(c.row, col + cs))) cs += 1;
            var rs = @min(c.rowspan, rows_all - c.row);
            if (marked + cs * rs > max_table_slots) {
                cs = 1;
                rs = 1;
            }
            for (0..rs) |dr| for (0..cs) |dc| try occ.put(p.work, slotKey(c.row + @as(u32, @intCast(dr)), col + @as(u32, @intCast(dc))), {});
            marked += cs * rs;
            slot.* = .{ .row = c.row, .col = col, .cs = cs, .rs = rs };
            cursor = col + cs;
            columns = @max(columns, col + cs);
        }
        if (columns == 0) return;
        const rows: u32 = @max(1, @min(rows_all, max_table_slots / columns));

        const grid = try p.work.alloc(?u32, @as(usize, rows) * columns);
        @memset(grid, null);
        var header = true;
        for (placed, 0..) |pl, i| {
            const at = pl orelse continue;
            if (at.row >= rows) continue;
            grid[at.row * columns + at.col] = @intCast(i);
            if (at.row == 0 and !t.cells.items[i].th) header = false;
        }
        const aligns_lo: u32 = @intCast(p.aligns.items.len);
        for (0..columns) |_| try p.aligns.append(p.a, .none);
        const cells_lo: u32 = @intCast(p.cells.items.len);
        const spans_lo: u32 = @intCast(p.spans.items.len);
        const al_lo: u32 = @intCast(p.cell_aligns.items.len);
        const va_lo: u32 = @intCast(p.valigns.items.len);
        const cb_lo: u32 = @intCast(p.cell_blocks.items.len);
        for (0..rows) |r| for (0..columns) |c| {
            if (grid[r * columns + c]) |ci| {
                const cell = t.cells.items[ci];
                const at = placed[ci].?;
                try p.cells.append(p.work, cell.raw);
                try p.spans.append(p.a, .{ @intCast(@min(at.cs, std.math.maxInt(u16))), @intCast(@min(at.rs, std.math.maxInt(u16))) });
                try p.cell_aligns.append(p.a, cell.al);
                try p.valigns.append(p.a, cell.va);
                try p.cell_blocks.append(p.work, cell.blocks);
            } else {
                try p.cells.append(p.work, p.textFrom(p.textLen()));
                try p.spans.append(p.a, if (occ.contains(slotKey(@intCast(r), @intCast(c)))) .{ 0, 0 } else .{ 1, 1 });
                try p.cell_aligns.append(p.a, .none);
                try p.valigns.append(p.a, .none);
                try p.cell_blocks.append(p.work, &.{});
            }
        };
        try p.emit(.{
            .kind = .table,
            .content = p.textFrom(p.textLen()),
            .columns = columns,
            .aligns = .{ .lo = aligns_lo, .hi = @intCast(p.aligns.items.len) },
            .cells = .{ .lo = cells_lo, .hi = @intCast(p.cells.items.len) },
            .spans = .{ .lo = spans_lo, .hi = @intCast(p.spans.items.len) },
            .cell_aligns = .{ .lo = al_lo, .hi = @intCast(p.cell_aligns.items.len) },
            .valigns = .{ .lo = va_lo, .hi = @intCast(p.valigns.items.len) },
            .cell_blocks = .{ .lo = cb_lo, .hi = @intCast(p.cell_blocks.items.len) },
            .header_row = header,
        });
    }

    fn closeRange(p: *const Parser, open: RawInline) RawInline {
        var r = open;
        r.text.hi = p.textLen();
        r.bold.hi = @intCast(p.bold.items.len);
        r.italic.hi = @intCast(p.italic.items.len);
        r.code.hi = @intCast(p.code.items.len);
        r.strike.hi = @intCast(p.strike.items.len);
        r.emoji.hi = @intCast(p.emoji.items.len);
        r.links.hi = @intCast(p.links.items.len);
        r.images.hi = @intCast(p.images.items.len);
        r.sup.hi = @intCast(p.sup.items.len);
        r.styles.hi = @intCast(p.styles.items.len);
        return r;
    }
};

const html_id_base: u32 = 0x4000_0000;
const max_colspan = 1000;
const max_rowspan = 65534;
const max_table_slots = 1 << 16;
const max_table_nesting = 32;

const El = enum {
    h1, h2, h3, h4, h5, h6, br, b, i, strong, em, a, pre, code, img, tt, div, ins, del, sup, sub, p, picture, ol, ul, table,
    thead, tbody, tfoot, blockquote, dl, dt, dd, kbd, q, samp, @"var", hr, ruby, rt, rp, li, tr, td, th, s, strike, summary,
    details, mark, source, span, section,

    fn isVoid(e: El) bool {
        return switch (e) {
            .br, .img, .hr, .source => true,
            else => false,
        };
    }
};

fn isBlockEl(el: El) bool {
    return switch (el) {
        .h1, .h2, .h3, .h4, .h5, .h6, .p, .div, .section, .ul, .ol, .li, .dl, .dt, .dd, .blockquote, .pre, .details, .summary => true,
        else => false,
    };
}

fn isTablePart(el: El) bool {
    return switch (el) {
        .table, .thead, .tbody, .tfoot, .tr, .td, .th => true,
        else => false,
    };
}

fn isInlineEl(el: El) bool {
    return !isBlockEl(el) and !isTablePart(el) and !el.isVoid();
}

fn attrOf(attrs: []const html.Attr, name: []const u8) ?[]const u8 {
    for (attrs) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
    return null;
}

/// http, https and relative targets, plus the file and drive-letter ones this viewer keeps for local documents.
fn safeUrl(url: []const u8) bool {
    const s = std.mem.trim(u8, url, " \t\r\n");
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '-' or s[i] == '.')) i += 1;
    if (i >= s.len or s[i] != ':' or i == 0) return true;
    const scheme = s[0..i];
    if (scheme.len == 1) return true;
    inline for (.{ "http", "https", "file" }) |ok| if (std.ascii.eqlIgnoreCase(scheme, ok)) return true;
    return false;
}

fn parseCount(v: ?[]const u8) ?u32 {
    const s = std.mem.trim(u8, v orelse return null, " \t\r\n");
    var n: u32 = 0;
    var digits: usize = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) null else n;
}

const Dim = struct { px: f32 = 0, pct: f32 = 0 };

fn parseDim(v: ?[]const u8) Dim {
    const s = std.mem.trim(u8, v orelse return .{}, " \t\r\n");
    const n = parseCount(s) orelse return .{};
    const pct = std.mem.indexOfScalar(u8, s, '%') != null;
    const f: f32 = @floatFromInt(@min(n, 1 << 20));
    return if (pct) .{ .pct = f } else .{ .px = f };
}

fn clampCount(v: ?u32, max: u32) u32 {
    return std.math.clamp(v orelse 1, 1, max);
}

fn slotKey(row: u32, col: u32) u64 {
    return (@as(u64, row) << 32) | col;
}

const HState = struct {
    pos: u32 = 0,
    id: u32 = 0,
    group: u32 = 0,
    md_depth: u32 = 0,
    n: u32 = 0,
    ordered: bool = false,
    seen: bool = false,
};

const TableCell = struct { raw: RawInline, blocks: []const RawBlock, colspan: u32, rowspan: u32, th: bool, al: Align, va: VAlign, row: u32 };

const CellBuild = struct {
    blocks: std.ArrayList(RawBlock) = .empty,
    node: u32,
    md_base: usize,
    os_base: usize,
    th: bool,
    colspan: u32,
    rowspan: u32,
    al: Align,
    va: VAlign,
    row: u32,
};

const TableBuild = struct {
    parent: ?*TableBuild,
    flat: u32 = 0,
    rows: u32 = 0,
    cells: std.ArrayList(TableCell) = .empty,
    cell: ?CellBuild = null,
};

/// Text and spans of one run of inline content, offsets relative to its own text.
const Frag = struct {
    a: Allocator,
    text: std.ArrayList(u8) = .empty,
    bold: std.ArrayList(Span) = .empty,
    italic: std.ArrayList(Span) = .empty,
    code: std.ArrayList(Span) = .empty,
    strike: std.ArrayList(Span) = .empty,
    emoji: std.ArrayList(Span) = .empty,
    sup: std.ArrayList(Span) = .empty,
    styles: std.ArrayList(Styled) = .empty,
    links: std.ArrayList(Link) = .empty,
    images: std.ArrayList(Image) = .empty,
    space: bool = false,
    any: bool = false,
    suppress: u32 = 0,

    fn init(a: Allocator) Frag {
        return .{ .a = a };
    }

    fn reset(f: *Frag) void {
        f.text.clearRetainingCapacity();
        f.bold.clearRetainingCapacity();
        f.italic.clearRetainingCapacity();
        f.code.clearRetainingCapacity();
        f.strike.clearRetainingCapacity();
        f.emoji.clearRetainingCapacity();
        f.sup.clearRetainingCapacity();
        f.styles.clearRetainingCapacity();
        f.links.clearRetainingCapacity();
        f.images.clearRetainingCapacity();
        f.space = false;
        f.any = false;
    }

    fn flushSpace(f: *Frag) Allocator.Error!void {
        if (!f.space) return;
        f.space = false;
        const n = f.text.items.len;
        if (n > 0 and f.text.items[n - 1] != '\n') try f.text.append(f.a, ' ');
    }

    fn put(f: *Frag, s: []const u8) Allocator.Error!void {
        if (s.len == 0 or f.suppress > 0) return;
        try f.flushSpace();
        try f.text.appendSlice(f.a, s);
        f.any = true;
    }

    fn putNl(f: *Frag) Allocator.Error!void {
        if (f.suppress > 0) return;
        f.space = false;
        try f.text.append(f.a, '\n');
        f.any = true;
    }

    /// Character data from HTML: runs of white space collapse to one space, none at the edges.
    fn htmlText(f: *Frag, s: []const u8, pre: bool) Allocator.Error!void {
        if (f.suppress > 0) return;
        if (pre) return f.put(s);
        for (s) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
                f.space = true;
                continue;
            }
            try f.flushSpace();
            try f.text.append(f.a, c);
            f.any = true;
        }
    }

    fn truncate(f: *Frag, n: u32) void {
        f.text.shrinkRetainingCapacity(n);
        inline for (.{ &f.bold, &f.italic, &f.code, &f.strike, &f.emoji, &f.sup }) |list| {
            var w: usize = 0;
            for (list.items) |sp| {
                if (sp[0] >= n) continue;
                list.items[w] = .{ sp[0], @min(sp[1], n - sp[0]) };
                w += 1;
            }
            list.shrinkRetainingCapacity(w);
        }
        var w: usize = 0;
        for (f.styles.items) |st| {
            if (st.span[0] >= n) continue;
            f.styles.items[w] = .{ .span = .{ st.span[0], @min(st.span[1], n - st.span[0]) }, .kind = st.kind };
            w += 1;
        }
        f.styles.shrinkRetainingCapacity(w);
        for (f.links.items) |*l| l.len = @min(l.len, n -| l.start);
    }
};

fn parserOf(h: *const inl.Hooks) *Parser {
    return @ptrCast(@alignCast(h.ctx.?));
}

fn linkHook(h: *const inl.Hooks, a: Allocator, src: []const u8, text_start: usize, close: usize, image: bool) Allocator.Error!?inl.LinkMatch {
    const p = parserOf(h);
    const open = text_start - 1;
    if (!image and text_start < close and src[text_start] == '^') {
        if (try p.refs.noteRef(src[text_start + 1 .. close])) |number| {
            return .{
                .end = close + 1,
                .url = try std.fmt.allocPrint(a, "#fn-{d}", .{number}),
                .replace = try std.fmt.allocPrint(a, "{d}", .{number}),
                .sup = true,
            };
        }
    }
    const found = (try links.matchInline(a, src, close + 1)) orelse
        (try links.matchReference(a, &p.refs, src, open, close)) orelse return null;
    return .{ .end = found.end, .url = found.dest, .title = found.title };
}

fn autolinkHook(_: *const inl.Hooks, a: Allocator, src: []const u8, lt: usize) Allocator.Error!?inl.AutolinkMatch {
    const al = links.autolink(src, lt) orelse return null;
    const url = if (al.prefix_mailto) try std.mem.concat(a, u8, &.{ "mailto:", al.target }) else al.target;
    return .{ .end = al.end, .url = url, .text = al.text };
}

fn bareHook(_: *const inl.Hooks, a: Allocator, src: []const u8, at: usize) Allocator.Error!?inl.AutolinkMatch {
    const al = (try links.extendedAutolink(a, src, at)) orelse return null;
    const url = if (al.prefix_mailto) try std.mem.concat(a, u8, &.{ "mailto:", al.target }) else al.target;
    return .{ .end = al.end, .url = url, .text = src[at..al.end] };
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

/// Byte offset of the character at UTF-16 code unit `unit`, for APIs that report UTF-16 indexes.
pub fn byteFromUtf16(text: []const u8, unit: u32) u32 {
    var byte: usize = 0;
    var units: u32 = 0;
    while (byte < text.len and units < unit) {
        const n = std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
        units += if (n == 4) 2 else 1;
        byte += n;
    }
    return @intCast(@min(byte, text.len));
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
    _ = @import("images.zig");
    _ = @import("scale.zig");
    _ = @import("html.zig");
    _ = @import("table_layout.zig");
    _ = highlight;
    _ = links;
    _ = @import("unicode_test.zig");
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
    try testing.expectEqual(@as(u32, 7), byteFromUtf16(text, 4));
    try testing.expectEqual(@as(u32, 3), byteFromUtf16(text, 2));
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

test "footnotes stay out of the document until referenced and keep every block" {
    const body = "[^1]: first\n\n    second\n\n    ```\n    code\n    ```\n\nafter\n";
    var plain = try parse(testing.allocator, "text\n\n" ++ body);
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 2), plain.blocks.len);

    var doc = try parse(testing.allocator, "text[^1]\n\n" ++ body);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 7), doc.blocks.len);
    try testing.expectEqualStrings("after", doc.blocks[1].content.text);
    try testing.expectEqual(BlockKind.hr, doc.blocks[2].kind);
    try testing.expectEqualStrings("first", doc.blocks[3].content.text);
    try testing.expectEqualStrings("second", doc.blocks[4].content.text);
    try testing.expectEqual(BlockKind.code_block, doc.blocks[5].kind);
    try testing.expectEqualStrings("\u{21a9}", doc.blocks[6].content.text);
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

test "footnotes are numbered by first reference and get back-references" {
    const src =
        \\Text[^b] and more[^a] and again[^b].
        \\
        \\[^a]: First note.
        \\[^b]: Second note
        \\  continued.
        \\[^unused]: never shown
        \\
        \\[^missing] stays text.
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 5), doc.blocks.len);
    const body = doc.blocks[0].content;
    try testing.expectEqualStrings("Text1 and more2 and again1.", body.text);
    try testing.expectEqual(@as(usize, 3), body.links.len);
    try testing.expectEqual(@as(usize, 3), body.sup.len);
    try testing.expectEqualSlices(u32, &.{ 4, 1 }, &body.sup[0]);
    try testing.expectEqualStrings("#fn-1", body.links[0].target);
    try testing.expectEqualStrings("#fn-2", body.links[1].target);
    try testing.expectEqualStrings("[^missing] stays text.", doc.blocks[1].content.text);
    try testing.expectEqual(BlockKind.hr, doc.blocks[2].kind);
    try testing.expectEqualStrings("Second note continued. \u{21a9} \u{21a9}2", doc.blocks[3].content.text);
    try testing.expectEqual(@as(u32, 1), doc.blocks[3].marks[0].mark.number);
    try testing.expectEqualStrings("#fnref-1-2", doc.blocks[3].content.links[1].target);
}

test "footnote bodies can reference other footnotes and hold lists and code" {
    var doc = try parse(testing.allocator, "A[^1]\n\n[^1]: See[^2].\n\n        code in note\n\n[^2]: - one\n    - two\n");
    defer doc.deinit();
    var found_code = false;
    var items: usize = 0;
    for (doc.blocks) |b| {
        if (b.kind == .code_block and std.mem.indexOf(u8, b.content.text, "code in note") != null) found_code = true;
        for (b.marks) |m| if (m.mark.kind == .bullet) {
            items += 1;
        };
    }
    try testing.expect(found_code);
    try testing.expectEqual(@as(usize, 2), items);
    try testing.expectEqualStrings("See2.", doc.blocks[2].content.text);
}

test "links keep their range, target and title on the inline" {
    var doc = try parse(testing.allocator, "see [the *docs*](<a b> \"T\") and <https://x.org/a> or www.x.org/a.");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqualStrings("see the docs and https://x.org/a or www.x.org/a.", c.text);
    try testing.expectEqual(@as(usize, 3), c.links.len);
    try testing.expectEqualStrings("a b", c.links[0].target);
    try testing.expectEqualStrings("T", c.links[0].title);
    try testing.expectEqualStrings("the docs", c.text[c.links[0].start..][0..c.links[0].len]);
    try testing.expectEqualStrings("https://x.org/a", c.links[1].target);
    try testing.expectEqualStrings("http://www.x.org/a", c.links[2].target);
    try testing.expectEqualStrings("www.x.org/a", c.text[c.links[2].start..][0..c.links[2].len]);
    try testing.expect(c.linkAt(c.links[0].start) != null);
    try testing.expect(c.linkAt(0) == null);
}

test "images keep alt text and source" {
    var doc = try parse(testing.allocator, "![alt *x*](pic.png \"t\") [![i](p.png)](/u)");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqualStrings("\u{fffc} \u{fffc}", c.text);
    try testing.expectEqual(@as(usize, 2), c.images.len);
    try testing.expectEqualStrings("pic.png", c.images[0].target);
    try testing.expectEqualStrings("t", c.images[0].title);
    try testing.expectEqualStrings("alt x", c.images[0].alt);
    try testing.expectEqualStrings("i", c.images[1].alt);
    try testing.expect(c.imageAt(c.images[0].start) != null);
    try testing.expect(c.linkAt(c.images[1].start) != null);
    try testing.expectEqual(@as(usize, 1), c.links.len);
    try testing.expectEqualStrings("/u", c.links[0].target);
}

test "reference images in all three forms resolve their definition" {
    var doc = try parse(testing.allocator, "![one][a] ![two][] ![three] ![four][nope]\n\n[a]: a.png \"A\"\n[two]: two.png\n[three]: three.png\n");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqual(@as(usize, 3), c.images.len);
    try testing.expectEqualStrings("a.png", c.images[0].target);
    try testing.expectEqualStrings("A", c.images[0].title);
    try testing.expectEqualStrings("two.png", c.images[1].target);
    try testing.expectEqualStrings("three.png", c.images[2].target);
    try testing.expectEqualStrings("three", c.images[2].alt);
    try testing.expect(std.mem.endsWith(u8, c.text, " ![four][nope]"));
}

test "an image is one object in the text and nested markup only feeds its alt" {
    var doc = try parse(testing.allocator, "a ![x *y* [z](u) ![n](m.png)](p.png) b");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqualStrings("a \u{fffc} b", c.text);
    try testing.expectEqual(@as(usize, 0), c.italic.len);
    try testing.expectEqual(@as(usize, 0), c.links.len);
    try testing.expectEqual(@as(usize, 1), c.images.len);
    try testing.expectEqualStrings("x y z n", c.images[0].alt);
}

test "extended autolinks work inside emphasis and not inside links" {
    var doc = try parse(testing.allocator, "**see www.a.org/x** and *me@b.org* and [www.c.org](/d)");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqual(@as(usize, 3), c.links.len);
    try testing.expectEqualStrings("http://www.a.org/x", c.links[0].target);
    try testing.expectEqualStrings("mailto:me@b.org", c.links[1].target);
    try testing.expectEqualStrings("/d", c.links[2].target);
    try testing.expectEqual(@as(usize, 1), c.bold.len);
    try testing.expectEqual(@as(usize, 1), c.italic.len);
}

test "entities and escapes in destinations and titles" {
    var doc = try parse(testing.allocator, "[a](/f&ouml;&#38;o\\) \"t&amp;\\\"x\")");
    defer doc.deinit();
    const l = doc.blocks[0].content.links[0];
    try testing.expectEqualStrings("/f\u{f6}&o)", l.target);
    try testing.expectEqualStrings("t&\"x", l.title);
}

test "reference links use definitions inside containers" {
    var doc = try parse(testing.allocator, "> [ref]: /u \"t\"\n\n- [foo]: /v\n\n[a][ref] and [foo]\n");
    defer doc.deinit();
    const c = doc.blocks[doc.blocks.len - 1].content;
    try testing.expectEqual(@as(usize, 2), c.links.len);
    try testing.expectEqualStrings("/u", c.links[0].target);
    try testing.expectEqualStrings("/v", c.links[1].target);
}

test "back-arrows follow a footnote that ends in a list, code or quote on their own line" {
    const src = "A[^1] B[^2] C[^3]\n\n[^1]: Intro\n\n    - one\n    - two\n\n[^2]: Text\n\n    ```\n    code\n    ```\n\n[^3]: Quote\n\n    > quoted\n";
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    var arrows: usize = 0;
    for (doc.blocks, 0..) |b, i| {
        if (b.kind != .paragraph or !std.mem.eql(u8, b.content.text, "\u{21a9}")) continue;
        arrows += 1;
        try testing.expectEqual(@as(usize, 1), b.frames.len);
        try testing.expect(doc.blocks[i - 1].frames.len >= 1);
    }
    try testing.expectEqual(@as(usize, 3), arrows);
}

test "quotes and lists nested past the depth cap stay readable as text" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..500) |_| try src.appendSlice(testing.allocator, "> ");
    try src.appendSlice(testing.allocator, "deep text\n");
    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    const last = doc.blocks[doc.blocks.len - 1];
    try testing.expectEqual(@as(usize, blocks.max_depth), last.frames.len);
    try testing.expect(std.mem.endsWith(u8, last.content.text, "deep text"));

    src.clearRetainingCapacity();
    for (0..500) |_| try src.appendSlice(testing.allocator, "- ");
    try src.appendSlice(testing.allocator, "deep item\n");
    var items = try parse(testing.allocator, src.items);
    defer items.deinit();
    try testing.expectEqual(@as(usize, blocks.max_depth), items.blocks[items.blocks.len - 1].frames.len);
    try testing.expect(std.mem.endsWith(u8, items.blocks[items.blocks.len - 1].content.text, "deep item"));
}

test "a link destination nested more than 32 parentheses deep is not a link" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "[a](");
    try src.appendNTimes(testing.allocator, '(', 40);
    try src.appendNTimes(testing.allocator, ')', 40);
    try src.appendSlice(testing.allocator, ")\n");
    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.blocks[0].content.links.len);
}

test "many distinct footnotes are numbered in reference order" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..3000) |n| try src.print(testing.allocator, "ref[^n{d}]\n\n", .{3000 - n});
    for (1..3001) |n| try src.print(testing.allocator, "[^n{d}]: note {d}\n\n", .{ n, n });
    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3000), doc.footnote_blocks.len);
    try testing.expectEqualStrings("1", doc.blocks[0].content.text[3..]);
}

test "unclosed HTML constructs do not rescan the paragraph" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "a ");
    for (0..20000) |_| try src.appendSlice(testing.allocator, "<?x <![CDATA[ <!A <!-- a ");
    var doc = try parse(testing.allocator, src.items);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
}

fn parseTest(src: []const u8) !Document {
    return parse(testing.allocator, src);
}

fn hasStyle(c: Inline, kind: StyleKind, text: []const u8) bool {
    for (c.styles) |s| if (s.kind == kind and std.mem.eql(u8, c.text[s.span[0] .. s.span[0] + s.span[1]], text)) return true;
    return false;
}

test "html: centred header block from a real README" {
    var doc = try parseTest(
        \\<p align="center">
        \\  <a href="https://example.dev"><img src="logo.png" width="200" alt="Logo"></a>
        \\  <br>
        \\  <a href="https://ci.example.dev"><img src="badge.svg" alt="ci"></a>
        \\  <a href="https://example.dev/b"><img src="b2.svg"></a>
        \\</p>
        \\
        \\<!-- a comment -->
        \\
        \\# Title
        \\
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    const b = doc.blocks[0];
    try testing.expectEqual(Align.center, b.alignment);
    try testing.expectEqualStrings("\u{fffc}\n\u{fffc} \u{fffc}", b.content.text);
    try testing.expectEqual(@as(usize, 3), b.content.images.len);
    try testing.expectEqual(@as(f32, 200), b.content.images[0].width);
    try testing.expectEqual(@as(usize, 3), b.content.links.len);
    try testing.expectEqualStrings("https://example.dev", b.content.links[0].target);
    try testing.expectEqual(b.content.images[0].start, b.content.links[0].start);
    try testing.expectEqual(BlockKind.h1, doc.blocks[1].kind);
    try testing.expectEqual(Align.none, doc.blocks[1].alignment);
}

test "html: div centres Markdown inside it, p does not" {
    var doc = try parseTest("<div align=\"center\">\n\nHello **x**\n\n</div>\n\nAfter\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(Align.center, doc.blocks[0].alignment);
    try testing.expectEqualStrings("Hello x", doc.blocks[0].content.text);
    try testing.expectEqual(Align.none, doc.blocks[1].alignment);

    var p = try parseTest("<p align=\"center\">\n\nText\n");
    defer p.deinit();
    try testing.expectEqual(Align.none, p.blocks[0].alignment);
}

test "html: heading align and anchors" {
    var doc = try parseTest("<h2 align=\"right\" id=\"x\">Y</h2>\n\n<a name=\"top\"></a>\n\ntext\n\n<span id=\"s\">z</span>\n");
    defer doc.deinit();
    try testing.expectEqual(BlockKind.h2, doc.blocks[0].kind);
    try testing.expectEqual(Align.right, doc.blocks[0].alignment);
    try testing.expectEqual(@as(?u32, 0), doc.anchorBlock("x"));
    try testing.expectEqual(@as(?u32, 1), doc.anchorBlock("top"));
    try testing.expectEqual(@as(?u32, 1), doc.anchorBlock("user-content-top"));
    try testing.expect(doc.anchorBlock("s") != null);
    try testing.expect(doc.anchorBlock("nope") == null);
}

test "html: inline tags map onto spans" {
    var doc = try parseTest("H<sub>2</sub>O <kbd>Ctrl</kbd> <ins>u</ins> <q>hi</q> <mark>m</mark> <b>b</b><del>d</del> <tt>t</tt>\n");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqualStrings("H2O Ctrl u \u{201c}hi\u{201d} m bd t", c.text);
    try testing.expect(hasStyle(c, .sub, "2"));
    try testing.expect(hasStyle(c, .kbd, "Ctrl"));
    try testing.expect(hasStyle(c, .underline, "u"));
    try testing.expect(hasStyle(c, .mark, "m"));
    try testing.expect(hasStyle(c, .tt, "t"));
    try testing.expectEqual(@as(usize, 1), c.bold.len);
    try testing.expectEqual(@as(usize, 1), c.strike.len);
}

test "html: tags GitHub strips leave their text" {
    var doc = try parseTest("a <abbr title=\"t\">b</abbr> <small>c</small> <cite>d</cite> <wbr>e\n");
    defer doc.deinit();
    try testing.expectEqualStrings("a b c d e", doc.blocks[0].content.text);
    try testing.expectEqual(@as(usize, 0), doc.blocks[0].content.styles.len);
    try testing.expectEqual(@as(usize, 0), doc.blocks[0].content.italic.len);
}

test "html: Markdown stays live inside inline tags" {
    var doc = try parseTest("press <kbd>**Ctrl**</kbd>\n");
    defer doc.deinit();
    try testing.expectEqualStrings("press Ctrl", doc.blocks[0].content.text);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].content.bold.len);
    try testing.expect(hasStyle(doc.blocks[0].content, .kbd, "Ctrl"));
}

test "html: formatting reopens after a Markdown paragraph break" {
    var doc = try parseTest("<b>one\n\ntwo</b> three\n\nfour\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(@as(usize, 1), doc.blocks[0].content.bold.len);
    try testing.expectEqualStrings("two three", doc.blocks[1].content.text);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, &doc.blocks[1].content.bold[0]);
    try testing.expectEqual(@as(usize, 0), doc.blocks[2].content.bold.len);

    var arks = try parseTest("<b><b><b><b>x\n\ny\n");
    defer arks.deinit();
    try testing.expectEqual(@as(usize, 4), arks.blocks[0].content.bold.len);
    try testing.expectEqual(@as(usize, 3), arks.blocks[1].content.bold.len);
}

test "html: tagfilter names show as text, unknown tags and comments vanish" {
    var doc = try parseTest("a <script>x</script> b <center>c</center> <!-- no --> d <svg>e</svg>\n");
    defer doc.deinit();
    try testing.expectEqualStrings("a <script>x</script> b c  d ", doc.blocks[0].content.text);

    var blk = try parseTest("<center>text</center>\n\n<script>\nalert(1)\n</script>\n");
    defer blk.deinit();
    try testing.expectEqual(@as(usize, 1), blk.blocks.len);
    try testing.expectEqualStrings("text <script> alert(1) </script>", blk.blocks[0].content.text);

    var rm = try parseTest("<svg>\n<circle/>\n</svg>\n\nafter\n");
    defer rm.deinit();
    try testing.expectEqual(@as(usize, 1), rm.blocks.len);
}

test "html: comments follow CommonMark 0.31" {
    var doc = try parseTest("a <!--> b <!---> c <!-- d -- e --> f\n");
    defer doc.deinit();
    try testing.expectEqualStrings("a  b  c  f", doc.blocks[0].content.text);
}

test "html: unsafe urls are dropped" {
    var doc = try parseTest("<a href=\"javascript:alert(1)\">x</a> <img src=\"data:image/png;base64,AAAA\" alt=\"fallback\">\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.blocks[0].content.links.len);
    try testing.expectEqual(@as(usize, 0), doc.blocks[0].content.images.len);
    try testing.expectEqualStrings("x fallback", doc.blocks[0].content.text);
}

test "html: picture resolves to a plain image" {
    var doc = try parseTest(
        \\<picture>
        \\  <source media="(prefers-color-scheme: light)" srcset="light.png">
        \\  <source media="(prefers-color-scheme: dark)" srcset="dark.png 2x, dark@3.png 3x">
        \\  <img alt="logo" src="fallback.png" align="right" width="64" height="32" title="tip">
        \\</picture>
        \\
    );
    defer doc.deinit();
    const im = doc.blocks[0].content.images[0];
    try testing.expectEqualStrings("dark.png", im.target);
    try testing.expectEqualStrings("logo", im.alt);
    try testing.expectEqualStrings("tip", im.title);
    try testing.expectEqual(links.Float.right, im.float);
    try testing.expectEqual(@as(f32, 64), im.width);
    try testing.expectEqual(@as(f32, 32), im.height);

    var plain = try parseTest("<picture><img alt=\"a\" src=\"only.png\"></picture>\n");
    defer plain.deinit();
    try testing.expectEqualStrings("only.png", plain.blocks[0].content.images[0].target);
}

test "html: image sizes keep px and percent apart" {
    var doc = try parseTest("<img src=\"a.png\" width=\"50%\"> <img src=\"b.png\" width=\"120px\" height=\"40\"> <img src=\"file:///c:/x.png\">\n");
    defer doc.deinit();
    const ims = doc.blocks[0].content.images;
    try testing.expectEqual(@as(f32, 50), ims[0].width_pct);
    try testing.expectEqual(@as(f32, 0), ims[0].width);
    try testing.expectEqual(@as(f32, 200), ims[0].requestedWidth(400));
    try testing.expectEqual(@as(f32, 120), ims[1].requestedWidth(400));
    try testing.expectEqual(@as(f32, 40), ims[1].height);
    try testing.expectEqualStrings("file:///c:/x.png", ims[2].target);
}

test "html: lists, quotes and definition lists become frames" {
    var doc = try parseTest("<ul>\n<li>one</li>\n<li>two\n</ul>\n\n<blockquote>\nquoted\n</blockquote>\n\n<dl>\n<dt>Term</dt>\n<dd>Meaning</dd>\n</dl>\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 5), doc.blocks.len);
    try testing.expectEqualStrings("one", doc.blocks[0].content.text);
    try testing.expectEqual(FrameKind.list, doc.blocks[0].frames[0].kind);
    try testing.expectEqual(Marker.bullet, doc.blocks[0].marks[0].mark.kind);
    try testing.expectEqual(doc.blocks[0].frames[0].group, doc.blocks[1].frames[0].group);
    try testing.expect(doc.blocks[0].frames[0].id != doc.blocks[1].frames[0].id);
    try testing.expectEqual(FrameKind.quote, doc.blocks[2].frames[0].kind);
    try testing.expect(doc.blocks[2].muted());
    try testing.expectEqual(Role.dt, doc.blocks[3].role);
    try testing.expectEqual(FrameKind.dd, doc.blocks[4].frames[0].kind);
    try testing.expectEqual(dd_inset, doc.blocks[4].inset());

    var ol = try parseTest("<ol start=\"3\"><li>a</li><li>b</li></ol>\n");
    defer ol.deinit();
    try testing.expectEqual(@as(u32, 3), ol.blocks[0].marks[0].mark.number);
    try testing.expectEqual(@as(u32, 4), ol.blocks[1].marks[0].mark.number);
}

test "html: details frames, summary and default label" {
    const src = "<details>\n<summary>More</summary>\n\n- a\n\n</details>\n\n<details open>\n\ninner\n\n</details>\n";
    var doc = try parseTest(src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 4), doc.blocks.len);
    try testing.expectEqual(Role.summary, doc.blocks[0].role);
    try testing.expectEqualStrings("More", doc.blocks[0].content.text);
    try testing.expectEqual(FrameKind.details, doc.blocks[0].frames[0].kind);
    try testing.expectEqual(FrameKind.list, doc.blocks[1].frames[1].kind);
    try testing.expect(!doc.blocks[0].frames[0].default_open);
    try testing.expectEqual(Role.summary, doc.blocks[2].role);
    try testing.expectEqualStrings("Details", doc.blocks[2].content.text);
    try testing.expect(doc.blocks[2].frames[0].default_open);

    var state: DetailsState = .empty;
    defer state.deinit(testing.allocator);
    try testing.expect(!collapsed(doc.blocks[0], &state));
    try testing.expect(collapsed(doc.blocks[1], &state));
    try testing.expect(!collapsed(doc.blocks[3], &state));
    try state.put(testing.allocator, doc.blocks[0].frames[0].key, true);
    try testing.expect(!collapsed(doc.blocks[1], &state));
}

test "html: details keys survive a reload and edits elsewhere" {
    var a = try parseTest("<details><summary>One</summary>\n\nx\n\n</details>\n\n<details><summary>One</summary>\n\ny\n\n</details>\n");
    defer a.deinit();
    var b = try parseTest("New paragraph\n\n<details><summary>One</summary>\n\nx\n\n</details>\n\n<details><summary>One</summary>\n\ny\n\n</details>\n");
    defer b.deinit();
    const ka1 = a.blocks[0].frames[0].key;
    const ka2 = a.blocks[2].frames[0].key;
    try testing.expect(ka1 != 0 and ka1 != ka2);
    try testing.expectEqual(ka1, a.blocks[1].frames[0].key);
    try testing.expectEqual(ka1, b.blocks[1].frames[0].key);
    try testing.expectEqual(ka2, b.blocks[3].frames[0].key);
}

test "html: spec examples" {
    var d1 = try parseTest("<div>\n*hello*\n         <foo><a>\n");
    defer d1.deinit();
    try testing.expectEqualStrings("*hello*", d1.blocks[0].content.text);

    var d2 = try parseTest("<DIV CLASS=\"foo\">\n\n*Markdown*\n\n</DIV>\n");
    defer d2.deinit();
    try testing.expectEqual(@as(usize, 1), d2.blocks.len);
    try testing.expectEqualStrings("Markdown", d2.blocks[0].content.text);
    try testing.expectEqual(@as(usize, 1), d2.blocks[0].content.italic.len);

    var d3 = try parseTest("<a  /><b2\ndata=\"foo\" >\n\nFoo <responsive-image src=\"foo.jpg\" />\n\nfoo <!-- this is a\ncomment - with hyphen -->\n\nfoo <![CDATA[>&<]]>\n");
    defer d3.deinit();
    try testing.expectEqualStrings("", d3.blocks[0].content.text);
    try testing.expectEqualStrings("Foo ", d3.blocks[1].content.text);
    try testing.expectEqualStrings("foo ", d3.blocks[2].content.text);
    try testing.expectEqualStrings("foo &<]]>", d3.blocks[3].content.text);

    var d4 = try parseTest("<pre language=\"haskell\"><code>\nimport Text.HTML.TagSoup\n\nmain :: IO ()\n</code></pre>\nokay\n");
    defer d4.deinit();
    try testing.expectEqual(BlockKind.code_block, d4.blocks[0].kind);
    try testing.expectEqualStrings("\nimport Text.HTML.TagSoup\n\nmain :: IO ()\n", d4.blocks[0].content.text);
}

test "html: a lone br is a spacer" {
    var doc = try parseTest("<br>\n\n</p>\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expectEqualStrings("\n", doc.blocks[0].content.text);
}

test "html: tables with spans" {
    var doc = try parseTest(
        \\<table>
        \\<caption>Cap</caption>
        \\<tr><th colspan="2">Head</th></tr>
        \\<tr><td align="right">a</td><td rowspan="2">b</td></tr>
        \\<tr><td>c</td></tr>
        \\</table>
        \\
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqualStrings("Cap", doc.blocks[0].content.text);
    const t = doc.blocks[1].table;
    try testing.expectEqual(@as(usize, 2), t.columns);
    try testing.expectEqual(@as(usize, 3), t.rows());
    try testing.expect(t.header_row);
    try testing.expectEqualSlices([2]u16, &.{ .{ 2, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 1 }, .{ 0, 0 } }, t.spans());
    try testing.expectEqualStrings("Head", t.cell(0, 0).text);
    try testing.expectEqualStrings("c", t.cell(2, 0).text);
    try testing.expectEqual(Align.right, t.alignAt(1, 0));
}

test "html: span limits are the browser's" {
    var doc = try parseTest("<table><tr><td colspan=\"5000\">x</td><td>y</td></tr><tr><td rowspan=\"70000\">a</td></tr></table>\n");
    defer doc.deinit();
    const t = doc.blocks[0].table;
    try testing.expectEqual(@as(usize, 1000), t.columns);
    try testing.expectEqual(@as(u16, 1000), t.spanAt(0, 0)[0]);
    try testing.expectEqual(@as(u16, 1), t.spanAt(1, 0)[1]);
}

test "html: tables01 cases that use allowed tags" {
    var a = try parseTest("<table><td>a\n");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.blocks.len);
    try testing.expectEqual(@as(usize, 1), a.blocks[0].table.columns);
    try testing.expectEqualStrings("a", a.blocks[0].table.cell(0, 0).text);

    var th = try parseTest("<table><th>\n");
    defer th.deinit();
    try testing.expect(th.blocks[0].table.header_row);

    var after = try parseTest("<table></table><p>foo\n");
    defer after.deinit();
    try testing.expectEqual(@as(usize, 1), after.blocks.len);
    try testing.expectEqualStrings("foo", after.blocks[0].content.text);

    var stray = try parseTest("<table><colgroup></html>foo\n");
    defer stray.deinit();
    try testing.expectEqualStrings("foo", stray.blocks[0].content.text);

    var ends = try parseTest("<table></body></caption></col></colgroup></html></tbody></td></tfoot></th></thead></tr><td>\n");
    defer ends.deinit();
    try testing.expectEqual(@as(usize, 1), ends.blocks.len);
    try testing.expectEqual(@as(usize, 1), ends.blocks[0].table.columns);
}

test "html: text between table rows is fostered before the table" {
    var doc = try parseTest("<table><tr><td>a</td></tr>x<tr><td>b</td></tr></table>\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqualStrings("x", doc.blocks[0].content.text);
    try testing.expectEqual(@as(usize, 2), doc.blocks[1].table.rows());

    var el = try parseTest("<table><div>in</div><tr><td>a</td></tr></table>\n");
    defer el.deinit();
    try testing.expectEqualStrings("in", el.blocks[0].content.text);
    try testing.expectEqual(BlockKind.table, el.blocks[1].kind);

    var again = try parseTest("<table><tr><td>a</td></tr><table><tr><td>b</td></tr></table>\n");
    defer again.deinit();
    try testing.expectEqual(@as(usize, 2), again.blocks.len);
    try testing.expectEqual(BlockKind.table, again.blocks[1].kind);
}

test "html: Markdown blocks inside a cell belong to it" {
    var doc = try parseTest("<table><tr><td>\n\n- a\n- b\n\ntext\n\n</td></tr></table>\n\nafter\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    const t = doc.blocks[0].table;
    const cell = t.cellBlocks(0, 0);
    try testing.expectEqual(@as(usize, 3), cell.len);
    try testing.expectEqualStrings("a", cell[0].content.text);
    try testing.expectEqual(FrameKind.list, cell[0].frames[0].kind);
    try testing.expectEqualStrings("text", cell[2].content.text);
    try testing.expectEqual(@as(usize, 0), cell[2].frames.len);
    try testing.expectEqualStrings("after", doc.blocks[1].content.text);
}

test "html: tables nest" {
    var doc = try parseTest("<table><tr><td>a<table><tr><td>b</td><td>c</td></tr></table></td></tr></table>\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const cell = doc.blocks[0].table.cellBlocks(0, 0);
    try testing.expectEqual(@as(usize, 2), cell.len);
    try testing.expectEqualStrings("a", cell[0].content.text);
    try testing.expectEqual(BlockKind.table, cell[1].kind);
    try testing.expectEqual(@as(usize, 2), cell[1].table.columns);
    try testing.expectEqualStrings("c", cell[1].table.cell(0, 1).text);
}

test "html: unclosed elements and deep nesting are bounded" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..2000) |_| try src.appendSlice(testing.allocator, "<div>");
    try src.appendSlice(testing.allocator, "deep\n");
    var doc = try parseTest(src.items);
    defer doc.deinit();
    try testing.expect(std.mem.endsWith(u8, doc.blocks[0].content.text, "deep"));

    var tables: std.ArrayList(u8) = .empty;
    defer tables.deinit(testing.allocator);
    for (0..100) |_| try tables.appendSlice(testing.allocator, "<table><tr><td>");
    try tables.appendSlice(testing.allocator, "deep\n");
    var nested = try parseTest(tables.items);
    defer nested.deinit();
    try testing.expectEqual(BlockKind.table, nested.blocks[0].kind);
}
