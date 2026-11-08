const std = @import("std");
const Allocator = std.mem.Allocator;
const entities = @import("entities.zig");
const allow = @import("html_allow.zig");

pub const max_open = 512;
pub const max_attrs = 64;
pub const max_attr_value = 4096;
pub const max_name = 64;

pub const nil: u32 = std.math.maxInt(u32);
const marker: u32 = nil - 1;

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Token = union(enum) {
    start: Start,
    end: []const u8,
    text: []const u8,
    comment: []const u8,
    doctype,
};

pub const Start = struct { name: []const u8, attrs: []const Attr, self_closing: bool, raw: []const u8 };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\x0c' or c == '\r';
}

const c1 = [32]u21{
    0x20AC, 0x81,   0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D,   0x017D, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D,   0x017E, 0x0178,
};

/// Splits HTML into tokens. Character references decode only with a semicolon for names.
pub const Tokenizer = struct {
    src: []const u8,
    a: Allocator,
    pos: usize = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(a: Allocator, src: []const u8) Tokenizer {
        return .{ .src = src, .a = a };
    }

    fn markupAt(t: *const Tokenizer, i: usize) bool {
        const s = t.src;
        if (i + 1 >= s.len) return false;
        const c = s[i + 1];
        if (std.ascii.isAlphabetic(c) or c == '!' or c == '?') return true;
        return c == '/' and i + 2 < s.len;
    }

    pub fn next(t: *Tokenizer) Allocator.Error!?Token {
        while (t.pos < t.src.len) {
            if (t.src[t.pos] == '<' and t.markupAt(t.pos)) {
                if (t.buf.items.len > 0) return .{ .text = t.flush() };
                if (try t.markup()) |tok| return tok;
                continue;
            }
            try t.textRun();
        }
        if (t.buf.items.len > 0) return .{ .text = t.flush() };
        return null;
    }

    fn flush(t: *Tokenizer) []const u8 {
        const out = t.buf.items;
        t.buf = .empty;
        return out;
    }

    fn textRun(t: *Tokenizer) Allocator.Error!void {
        const s = t.src;
        var i = t.pos;
        while (i < s.len) {
            const c = s[i];
            if (c == '<') {
                if (t.markupAt(i)) break;
                try t.buf.append(t.a, '<');
                i += 1;
            } else if (c == '&') {
                i = try t.charRef(&t.buf, i);
            } else {
                var j = i + 1;
                while (j < s.len and s[j] != '<' and s[j] != '&') j += 1;
                try t.buf.appendSlice(t.a, s[i..j]);
                i = j;
            }
        }
        t.pos = i;
    }

    fn charRef(t: *Tokenizer, out: *std.ArrayList(u8), at: usize) Allocator.Error!usize {
        const s = t.src;
        var j = at + 1;
        if (j < s.len and s[j] == '#') {
            j += 1;
            const hex = j < s.len and (s[j] == 'x' or s[j] == 'X');
            if (hex) j += 1;
            const start = j;
            var v: u32 = 0;
            while (j < s.len) : (j += 1) {
                const d = std.fmt.charToDigit(s[j], if (hex) 16 else 10) catch break;
                if (v <= 0x10FFFF) v = v * (if (hex) @as(u32, 16) else 10) + d;
            }
            if (j == start) {
                try out.appendSlice(t.a, s[at..j]);
                return j;
            }
            if (j < s.len and s[j] == ';') j += 1;
            var cp: u21 = if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else @intCast(v);
            if (cp >= 0x80 and cp <= 0x9F) cp = c1[cp - 0x80];
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &enc) catch {
                try out.appendSlice(t.a, "\u{fffd}");
                return j;
            };
            try out.appendSlice(t.a, enc[0..n]);
            return j;
        }
        const start = j;
        while (j < s.len and j - start < 32 and std.ascii.isAlphanumeric(s[j])) j += 1;
        if (j == start or j >= s.len or s[j] != ';') {
            try out.append(t.a, '&');
            return at + 1;
        }
        if (entities.lookup(s[start..j])) |v| {
            try out.appendSlice(t.a, v);
            return j + 1;
        }
        try out.append(t.a, '&');
        return at + 1;
    }

    fn bogus(t: *Tokenizer, from: usize) Token {
        const s = t.src;
        const e = std.mem.indexOfScalarPos(u8, s, from, '>') orelse s.len;
        t.pos = @min(e + 1, s.len);
        return .{ .comment = s[from..e] };
    }

    fn markup(t: *Tokenizer) Allocator.Error!?Token {
        const s = t.src;
        const i = t.pos;
        const c = s[i + 1];
        if (c == '?') return t.bogus(i + 1);
        if (c == '!') return t.declaration(i + 2);
        if (c == '/') {
            if (s[i + 2] == '>') {
                t.pos = i + 3;
                return null;
            }
            if (!std.ascii.isAlphabetic(s[i + 2])) return t.bogus(i + 2);
            return try t.tag(i + 2, true);
        }
        return try t.tag(i + 1, false);
    }

    fn declaration(t: *Tokenizer, at: usize) Token {
        const s = t.src;
        if (std.mem.startsWith(u8, s[at..], "--")) {
            const body = at + 2;
            if (std.mem.startsWith(u8, s[body..], ">")) {
                t.pos = body + 1;
                return .{ .comment = "" };
            }
            if (std.mem.startsWith(u8, s[body..], "->")) {
                t.pos = body + 2;
                return .{ .comment = "" };
            }
            var j = body;
            while (j + 1 < s.len) : (j += 1) {
                if (s[j] == '-' and s[j + 1] == '-') {
                    if (j + 2 < s.len and s[j + 2] == '>') {
                        t.pos = j + 3;
                        return .{ .comment = s[body..j] };
                    }
                    if (j + 3 < s.len and s[j + 2] == '!' and s[j + 3] == '>') {
                        t.pos = j + 4;
                        return .{ .comment = s[body..j] };
                    }
                }
            }
            t.pos = s.len;
            var end = s.len;
            if (std.mem.endsWith(u8, s[body..], "--!")) end -= 3 else if (std.mem.endsWith(u8, s[body..], "--")) end -= 2 else if (std.mem.endsWith(u8, s[body..], "-")) end -= 1;
            return .{ .comment = s[body..end] };
        }
        if (at + 7 <= s.len and std.ascii.eqlIgnoreCase(s[at .. at + 7], "doctype")) {
            const e = std.mem.indexOfScalarPos(u8, s, at, '>') orelse s.len;
            t.pos = @min(e + 1, s.len);
            return .doctype;
        }
        return t.bogus(at);
    }

    fn lower(t: *Tokenizer, raw: []const u8) Allocator.Error![]const u8 {
        const n = @min(raw.len, max_name);
        const out = try t.a.alloc(u8, n);
        for (raw[0..n], out) |c, *o| o.* = std.ascii.toLower(c);
        return out;
    }

    fn tag(t: *Tokenizer, name_at: usize, closing: bool) Allocator.Error!Token {
        const s = t.src;
        const begin = name_at - @as(usize, if (closing) 2 else 1);
        var i = name_at;
        while (i < s.len and !isSpace(s[i]) and s[i] != '/' and s[i] != '>') i += 1;
        const name = try t.lower(s[name_at..i]);
        var attrs: std.ArrayList(Attr) = .empty;
        var self_closing = false;
        done: while (true) {
            while (i < s.len and isSpace(s[i])) i += 1;
            if (i >= s.len) break;
            switch (s[i]) {
                '>' => {
                    i += 1;
                    break :done;
                },
                '/' => {
                    i += 1;
                    if (i < s.len and s[i] == '>') {
                        self_closing = true;
                        i += 1;
                        break :done;
                    }
                    continue;
                },
                else => {},
            }
            const ns = i;
            i += 1;
            while (i < s.len and !isSpace(s[i]) and s[i] != '/' and s[i] != '>' and s[i] != '=') i += 1;
            const aname = try t.lower(s[ns..i]);
            var j = i;
            while (j < s.len and isSpace(s[j])) j += 1;
            var value: []const u8 = "";
            var complete = true;
            if (j < s.len and s[j] == '=') {
                j += 1;
                while (j < s.len and isSpace(s[j])) j += 1;
                var vb: std.ArrayList(u8) = .empty;
                if (j < s.len and (s[j] == '"' or s[j] == '\'')) {
                    const q = s[j];
                    j += 1;
                    while (j < s.len and s[j] != q) {
                        if (s[j] == '&') j = try t.charRef(&vb, j) else {
                            try vb.append(t.a, s[j]);
                            j += 1;
                        }
                    }
                    if (j >= s.len) complete = false else j += 1;
                } else {
                    while (j < s.len and !isSpace(s[j]) and s[j] != '>') {
                        if (s[j] == '&') j = try t.charRef(&vb, j) else {
                            try vb.append(t.a, s[j]);
                            j += 1;
                        }
                    }
                }
                value = vb.items;
                i = j;
            }
            if (!complete) {
                i = s.len;
                break;
            }
            if (attrs.items.len >= max_attrs or value.len > max_attr_value) continue;
            var dup = false;
            for (attrs.items) |x| if (std.mem.eql(u8, x.name, aname)) {
                dup = true;
            };
            if (!dup) try attrs.append(t.a, .{ .name = aname, .value = value });
        }
        t.pos = @min(i, s.len);
        if (closing) return .{ .end = name };
        return .{ .start = .{ .name = name, .attrs = attrs.items, .self_closing = self_closing, .raw = s[begin..t.pos] } };
    }
};

/// cmark-gfm's tagfilter: a `<` that opens one of the nine disallowed tags becomes `&lt;`.
pub fn tagfilter(a: Allocator, src: []const u8) Allocator.Error![]const u8 {
    var out: ?std.ArrayList(u8) = null;
    var last: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, src, i, '<')) |lt| {
        i = lt + 1;
        var j = lt + 1;
        if (j < src.len and src[j] == '/') j += 1;
        const ns = j;
        while (j < src.len and std.ascii.isAlphanumeric(src[j])) j += 1;
        if (j == ns or !allow.tagfiltered(src[ns..j])) continue;
        if (j < src.len and !isSpace(src[j]) and src[j] != '>' and !(src[j] == '/' and j + 1 < src.len and src[j + 1] == '>')) continue;
        if (out == null) out = .empty;
        try out.?.appendSlice(a, src[last..lt]);
        try out.?.appendSlice(a, "&lt;");
        last = lt + 1;
    }
    if (out) |*o| {
        try o.appendSlice(a, src[last..]);
        return o.items;
    }
    return src;
}

pub const Node = struct {
    kind: enum { root, element, text, comment } = .element,
    name: []const u8 = "",
    attrs: []const Attr = &.{},
    raw_attrs: []const Attr = &.{},
    text: []const u8 = "",
    text_cap: usize = 0,
    parent: u32 = nil,
    first: u32 = nil,
    last: u32 = nil,
    next: u32 = nil,
    kept: bool = true,
    hidden: bool = false,
    markdown: bool = false,
};

pub const Ancestor = struct { name: []const u8, attrs: []const Attr, node: u32, markdown: bool };

pub const Event = struct { kind: enum { open, close, text }, node: u32, text: []const u8 = "" };

pub const MarkdownKind = enum { p, h1, h2, h3, h4, h5, h6, ul, ol, li, pre, table, blockquote, hr };

pub const Options = struct { sanitize: bool = true };

const Mode = enum { body, table, caption, column_group, table_body, row, cell };

fn inSet(comptime names: []const []const u8, n: []const u8) bool {
    inline for (names) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

fn isSpecial(n: []const u8) bool {
    return inSet(&.{
        "address",  "applet",   "area",     "article", "aside",    "base",     "basefont", "bgsound",  "blockquote", "body",
        "br",       "button",   "caption",  "center",  "col",      "colgroup", "dd",       "details",  "dir",        "div",
        "dl",       "dt",       "embed",    "fieldset", "figcaption", "figure", "footer",   "form",     "frame",      "frameset",
        "h1",       "h2",       "h3",       "h4",      "h5",       "h6",       "head",     "header",   "hgroup",     "hr",
        "html",     "iframe",   "img",      "input",   "keygen",   "li",       "link",     "listing",  "main",       "marquee",
        "menu",     "meta",     "nav",      "noembed", "noframes", "noscript", "object",   "ol",       "p",          "param",
        "plaintext", "pre",     "script",   "search",  "section",  "select",   "source",   "style",    "summary",    "table",
        "tbody",    "td",       "template", "textarea", "tfoot",   "th",       "thead",    "title",    "tr",         "track",
        "ul",       "wbr",      "xmp",
    }, n);
}

fn isFormatting(n: []const u8) bool {
    return inSet(&.{ "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u" }, n);
}

fn isVoid(n: []const u8) bool {
    return inSet(&.{ "area", "br", "embed", "img", "keygen", "wbr", "input", "param", "source", "track", "hr", "col", "base", "basefont", "bgsound", "link", "meta", "frame" }, n);
}

fn isScopeBase(n: []const u8) bool {
    return inSet(&.{ "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template" }, n);
}

fn isHeading(n: []const u8) bool {
    return n.len == 2 and n[0] == 'h' and n[1] >= '1' and n[1] <= '6';
}

fn closesP(n: []const u8) bool {
    return inSet(&.{
        "address", "article", "aside",  "blockquote", "center", "details", "dialog", "dir",  "div",    "dl",
        "fieldset", "figcaption", "figure", "footer", "header", "hgroup",  "main",   "menu", "nav",    "ol",
        "p",      "search", "section", "summary", "ul",
    }, n);
}

fn impliedEnd(n: []const u8) bool {
    return inSet(&.{ "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc" }, n);
}

const Scope = enum { default, list_item, button, table };

pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    opts: Options,
    nodes: std.ArrayList(Node) = .empty,
    stack: std.ArrayList(u32) = .empty,
    afe: std.ArrayList(u32) = .empty,
    events: std.ArrayList(Event) = .empty,
    mode: Mode = .body,
    foster: bool = false,
    skip_lf: bool = false,
    failed: bool = false,
    anc_buf: []Ancestor = &.{},

    pub fn init(gpa: Allocator, opts: Options) Allocator.Error!Builder {
        var b: Builder = .{ .arena = std.heap.ArenaAllocator.init(gpa), .opts = opts };
        try b.nodes.append(b.arena.allocator(), .{ .kind = .root });
        b.anc_buf = try b.arena.allocator().alloc(Ancestor, max_open + 2);
        return b;
    }

    pub fn deinit(b: *Builder) void {
        b.arena.deinit();
    }

    fn a(b: *Builder) Allocator {
        return b.arena.allocator();
    }

    pub fn clearEvents(b: *Builder) void {
        b.events.clearRetainingCapacity();
    }

    /// Tokenizes an HTML fragment (a raw HTML block) and applies it to the tree.
    pub fn feedBlock(b: *Builder, bytes: []const u8) Allocator.Error!void {
        const src = if (b.opts.sanitize) try tagfilter(b.a(), bytes) else bytes;
        var t = Tokenizer.init(b.a(), src);
        while (try t.next()) |tok| try b.token(tok);
        if (b.failed) return error.OutOfMemory;
    }

    pub fn feedInlineTag(b: *Builder, bytes: []const u8) Allocator.Error!void {
        return b.feedBlock(bytes);
    }

    pub fn openMarkdown(b: *Builder, kind: MarkdownKind) Allocator.Error!void {
        const first = b.nodes.items.len;
        try b.processStart(@tagName(kind), &.{}, "");
        b.skip_lf = false;
        for (b.nodes.items[first..]) |*n| {
            if (n.kind == .element and std.mem.eql(u8, n.name, @tagName(kind))) {
                n.markdown = true;
                n.kept = true;
                break;
            }
        }
        if (b.failed) return error.OutOfMemory;
    }

    pub fn closeMarkdown(b: *Builder, kind: MarkdownKind) Allocator.Error!void {
        if (kind == .hr) return;
        try b.processEnd(@tagName(kind));
        if (b.failed) return error.OutOfMemory;
    }

    /// Call before Markdown text goes into the current element: formatting elements left open by earlier HTML reopen here.
    pub fn markdownText(b: *Builder) Allocator.Error!void {
        if (!b.hidden()) try b.reconstruct();
    }

    pub fn hidden(b: *Builder) bool {
        const cur = b.current();
        return cur != nil and b.nodes.items[cur].hidden;
    }

    pub fn ancestors(b: *Builder) []const Ancestor {
        const loc = b.place(b.current());
        return b.ancestorsOf(loc.parent);
    }

    pub fn ancestorsOf(b: *Builder, from: u32) []const Ancestor {
        var n: usize = 0;
        var id = from;
        while (id != nil and n < b.anc_buf.len) : (id = b.nodes.items[id].parent) {
            const nd = &b.nodes.items[id];
            if (nd.kind != .element or !nd.kept) continue;
            b.anc_buf[n] = .{ .name = nd.name, .attrs = nd.attrs, .node = id, .markdown = nd.markdown };
            n += 1;
        }
        std.mem.reverse(Ancestor, b.anc_buf[0..n]);
        return b.anc_buf[0..n];
    }

    fn token(b: *Builder, tok: Token) Allocator.Error!void {
        switch (tok) {
            .text => |s| try b.processText(s),
            .start => |s| try b.processStart(s.name, s.attrs, s.raw),
            .end => |n| try b.processEnd(n),
            .comment, .doctype => {},
        }
    }

    fn node(b: *Builder, id: u32) *Node {
        return &b.nodes.items[id];
    }

    fn current(b: *Builder) u32 {
        return if (b.stack.items.len == 0) nil else b.stack.items[b.stack.items.len - 1];
    }

    fn curName(b: *Builder) []const u8 {
        const c = b.current();
        return if (c == nil) "" else b.node(c).name;
    }

    const Loc = struct { parent: u32, before: u32 };

    fn place(b: *Builder, target: u32) Loc {
        if (target == nil) return .{ .parent = 0, .before = nil };
        const name = b.node(target).name;
        if (!(b.foster and inSet(&.{ "table", "tbody", "tfoot", "thead", "tr" }, name))) return .{ .parent = target, .before = nil };
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const id = b.stack.items[i];
            if (!std.mem.eql(u8, b.node(id).name, "table")) continue;
            const p = b.node(id).parent;
            if (p != nil) return .{ .parent = p, .before = id };
            return .{ .parent = if (i > 0) b.stack.items[i - 1] else 0, .before = nil };
        }
        return .{ .parent = if (b.stack.items.len > 0) b.stack.items[0] else 0, .before = nil };
    }

    fn link(b: *Builder, loc: Loc, id: u32) void {
        const p = b.node(loc.parent);
        b.node(id).parent = loc.parent;
        b.node(id).next = loc.before;
        if (loc.before == nil) {
            if (p.last != nil) b.node(p.last).next = id else p.first = id;
            p.last = id;
            return;
        }
        var prev: u32 = nil;
        var c = p.first;
        while (c != loc.before) : (c = b.node(c).next) prev = c;
        if (prev == nil) p.first = id else b.node(prev).next = id;
    }

    fn unlink(b: *Builder, id: u32) void {
        const pid = b.node(id).parent;
        if (pid == nil) return;
        const p = b.node(pid);
        var prev: u32 = nil;
        var c = p.first;
        while (c != id) : (c = b.node(c).next) prev = c;
        if (prev == nil) p.first = b.node(id).next else b.node(prev).next = b.node(id).next;
        if (p.last == id) p.last = prev;
        b.node(id).parent = nil;
        b.node(id).next = nil;
    }

    fn newElement(b: *Builder, name: []const u8, raw: []const Attr, md: bool, parent_hidden: bool) Allocator.Error!u32 {
        var n: Node = .{ .name = name, .raw_attrs = raw, .attrs = raw, .markdown = md };
        if (b.opts.sanitize and !md) {
            n.kept = allow.elementAllowed(name);
            n.hidden = parent_hidden or allow.removeContents(name);
            if (n.kept) {
                var kept: std.ArrayList(Attr) = .empty;
                for (raw) |at| {
                    if (!allow.attrAllowed(name, at.name)) continue;
                    if (!allow.schemeAllowed(allow.protocols(name, at.name), if (std.mem.eql(u8, at.name, "srcset")) allow.firstSrcset(at.value) else at.value)) continue;
                    try kept.append(b.a(), at);
                }
                n.attrs = kept.items;
                if (std.mem.eql(u8, name, "a") and !hasAnchorAttr(kept.items)) n.kept = false;
            }
        } else n.hidden = parent_hidden;
        try b.nodes.append(b.a(), n);
        return @intCast(b.nodes.items.len - 1);
    }

    fn insertElement(b: *Builder, name: []const u8, raw: []const Attr) Allocator.Error!u32 {
        const loc = b.place(b.current());
        const id = try b.newElement(name, raw, false, b.node(loc.parent).hidden);
        b.link(loc, id);
        try b.stack.append(b.a(), id);
        if (b.node(id).kept and !b.node(id).hidden) try b.events.append(b.a(), .{ .kind = .open, .node = id });
        return id;
    }

    fn insertVoid(b: *Builder, name: []const u8, raw: []const Attr) Allocator.Error!void {
        _ = try b.insertElement(name, raw);
        b.popOne();
    }

    fn popOne(b: *Builder) void {
        const id = b.stack.pop().?;
        const n = b.node(id);
        if (n.kept and !n.hidden) b.events.append(b.a(), .{ .kind = .close, .node = id }) catch {
            b.failed = true;
        };
    }

    fn insertText(b: *Builder, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        const loc = b.place(b.current());
        const p = b.node(loc.parent);
        if (p.hidden) return;
        var prev: u32 = if (loc.before == nil) p.last else nil;
        if (loc.before != nil) {
            var c = p.first;
            while (c != nil and c != loc.before) : (c = b.node(c).next) prev = c;
        }
        if (prev != nil and b.node(prev).kind == .text) {
            const t = b.node(prev);
            const need = t.text.len + s.len;
            if (need > t.text_cap) {
                const grown = try b.a().alloc(u8, need * 2);
                @memcpy(grown[0..t.text.len], t.text);
                t.text = grown[0..t.text.len];
                t.text_cap = grown.len;
            }
            const buf = @constCast(t.text.ptr)[0..need];
            @memcpy(buf[t.text.len..], s);
            t.text = buf;
        } else {
            try b.nodes.append(b.a(), .{ .kind = .text, .text = try b.a().dupe(u8, s) });
            b.link(loc, @intCast(b.nodes.items.len - 1));
        }
        try b.events.append(b.a(), .{ .kind = .text, .node = loc.parent, .text = s });
    }

    fn inStack(b: *Builder, id: u32) ?usize {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            if (b.stack.items[i] == id) return i;
        }
        return null;
    }

    fn hasInScope(b: *Builder, name: []const u8, scope: Scope) bool {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const n = b.node(b.stack.items[i]).name;
            if (std.mem.eql(u8, n, name)) return true;
            switch (scope) {
                .table => if (std.mem.eql(u8, n, "table") or std.mem.eql(u8, n, "html") or std.mem.eql(u8, n, "template")) return false,
                else => {
                    if (isScopeBase(n)) return false;
                    if (scope == .button and std.mem.eql(u8, n, "button")) return false;
                    if (scope == .list_item and (std.mem.eql(u8, n, "ol") or std.mem.eql(u8, n, "ul"))) return false;
                },
            }
        }
        return false;
    }

    fn headingInScope(b: *Builder) bool {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const n = b.node(b.stack.items[i]).name;
            if (isHeading(n)) return true;
            if (isScopeBase(n)) return false;
        }
        return false;
    }

    fn nodeInScope(b: *Builder, id: u32) bool {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const x = b.stack.items[i];
            if (x == id) return true;
            if (isScopeBase(b.node(x).name)) return false;
        }
        return false;
    }

    fn impliedExcept(b: *Builder, except: []const u8) void {
        while (b.stack.items.len > 0) {
            const n = b.curName();
            if (!impliedEnd(n) or std.mem.eql(u8, n, except)) return;
            b.popOne();
        }
    }

    fn popUntil(b: *Builder, name: []const u8) void {
        while (b.stack.items.len > 0) {
            const n = b.curName();
            b.popOne();
            if (std.mem.eql(u8, n, name)) return;
        }
    }

    fn popUntilHeading(b: *Builder) void {
        while (b.stack.items.len > 0) {
            const n = b.curName();
            b.popOne();
            if (isHeading(n)) return;
        }
    }

    fn closeP(b: *Builder) void {
        if (!b.hasInScope("p", .button)) return;
        b.impliedExcept("p");
        b.popUntil("p");
    }

    fn afeIndex(b: *Builder, id: u32) ?usize {
        for (b.afe.items, 0..) |x, i| if (x == id) return i;
        return null;
    }

    fn sameAttrs(x: []const Attr, y: []const Attr) bool {
        if (x.len != y.len) return false;
        for (x) |p| {
            var found = false;
            for (y) |q| if (std.mem.eql(u8, p.name, q.name) and std.mem.eql(u8, p.value, q.value)) {
                found = true;
            };
            if (!found) return false;
        }
        return true;
    }

    fn pushAfe(b: *Builder, id: u32) Allocator.Error!void {
        var count: usize = 0;
        var earliest: usize = 0;
        var i = b.afe.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.afe.items[i];
            if (e == marker) break;
            if (std.mem.eql(u8, b.node(e).name, b.node(id).name) and sameAttrs(b.node(e).raw_attrs, b.node(id).raw_attrs)) {
                count += 1;
                earliest = i;
            }
        }
        if (count >= 3) _ = b.afe.orderedRemove(earliest);
        try b.afe.append(b.a(), id);
    }

    fn clearAfe(b: *Builder) void {
        while (b.afe.items.len > 0) {
            if (b.afe.pop().? == marker) return;
        }
    }

    fn clone(b: *Builder, id: u32) Allocator.Error!u32 {
        const src = b.node(id);
        return b.insertElement(src.name, src.raw_attrs);
    }

    fn reconstruct(b: *Builder) Allocator.Error!void {
        if (b.afe.items.len == 0) return;
        var i = b.afe.items.len - 1;
        const last = b.afe.items[i];
        if (last == marker or b.inStack(last) != null) return;
        while (i > 0) {
            const prev = b.afe.items[i - 1];
            if (prev == marker or b.inStack(prev) != null) break;
            i -= 1;
        }
        while (i < b.afe.items.len) : (i += 1) b.afe.items[i] = try b.clone(b.afe.items[i]);
    }

    fn adoption(b: *Builder, subject: []const u8) Allocator.Error!bool {
        const cur = b.current();
        if (cur != nil and std.mem.eql(u8, b.node(cur).name, subject) and b.afeIndex(cur) == null) {
            b.popOne();
            return true;
        }
        var outer: usize = 0;
        while (outer < 8) : (outer += 1) {
            var fe: u32 = nil;
            var fe_afe: usize = 0;
            var i = b.afe.items.len;
            while (i > 0) {
                i -= 1;
                const e = b.afe.items[i];
                if (e == marker) break;
                if (std.mem.eql(u8, b.node(e).name, subject)) {
                    fe = e;
                    fe_afe = i;
                    break;
                }
            }
            if (fe == nil) return outer > 0;
            const fe_idx = b.inStack(fe) orelse {
                _ = b.afe.orderedRemove(fe_afe);
                return true;
            };
            if (!b.nodeInScope(fe)) return true;
            var furthest_idx: ?usize = null;
            var k = fe_idx + 1;
            while (k < b.stack.items.len) : (k += 1) {
                if (isSpecial(b.node(b.stack.items[k]).name)) {
                    furthest_idx = k;
                    break;
                }
            }
            const fi = furthest_idx orelse {
                while (b.stack.items.len > fe_idx) b.popOne();
                _ = b.afe.orderedRemove(fe_afe);
                return true;
            };
            const furthest = b.stack.items[fi];
            const common: u32 = if (fe_idx > 0) b.stack.items[fe_idx - 1] else 0;
            var bookmark = fe_afe;
            var last_node = furthest;
            var node_idx = fi;
            var counter: usize = 0;
            while (true) {
                counter += 1;
                node_idx -= 1;
                const nd = b.stack.items[node_idx];
                if (nd == fe) break;
                if (counter > 3) if (b.afeIndex(nd)) |x| {
                    _ = b.afe.orderedRemove(x);
                    if (x < bookmark) bookmark -= 1;
                };
                const ai = b.afeIndex(nd) orelse {
                    _ = b.stack.orderedRemove(node_idx);
                    continue;
                };
                const created = try b.newElement(b.node(nd).name, b.node(nd).raw_attrs, false, b.node(nd).hidden);
                b.afe.items[ai] = created;
                b.stack.items[node_idx] = created;
                if (last_node == furthest) bookmark = ai + 1;
                b.unlink(last_node);
                b.link(.{ .parent = created, .before = nil }, last_node);
                last_node = created;
            }
            b.unlink(last_node);
            const tabular = inSet(&.{ "table", "tbody", "tfoot", "thead", "tr" }, b.node(common).name);
            const was = b.foster;
            b.foster = tabular;
            b.link(b.place(common), last_node);
            b.foster = was;
            const fresh = try b.newElement(b.node(fe).name, b.node(fe).raw_attrs, false, b.node(fe).hidden);
            var c = b.node(furthest).first;
            while (c != nil) {
                const nx = b.node(c).next;
                b.unlink(c);
                b.link(.{ .parent = fresh, .before = nil }, c);
                c = nx;
            }
            b.link(.{ .parent = furthest, .before = nil }, fresh);
            const old = b.afeIndex(fe).?;
            _ = b.afe.orderedRemove(old);
            if (old < bookmark) bookmark -= 1;
            try b.afe.insert(b.a(), @min(bookmark, b.afe.items.len), fresh);
            const fe_pos = b.inStack(fe).?;
            _ = b.stack.orderedRemove(fe_pos);
            const fur_pos = b.inStack(furthest).?;
            try b.stack.insert(b.a(), fur_pos + 1, fresh);
            if (b.node(fe).kept and !b.node(fe).hidden) try b.events.append(b.a(), .{ .kind = .close, .node = fe });
            if (b.node(fresh).kept and !b.node(fresh).hidden) try b.events.append(b.a(), .{ .kind = .open, .node = fresh });
        }
        return true;
    }

    fn clearTo(b: *Builder, names: []const []const u8) void {
        while (b.stack.items.len > 0) {
            const n = b.curName();
            for (names) |x| if (std.mem.eql(u8, x, n)) return;
            b.popOne();
        }
    }

    fn resetMode(b: *Builder) void {
        var i = b.stack.items.len;
        b.mode = .body;
        while (i > 0) {
            i -= 1;
            const n = b.node(b.stack.items[i]).name;
            if (inSet(&.{ "td", "th" }, n)) return b.setMode(.cell);
            if (std.mem.eql(u8, n, "tr")) return b.setMode(.row);
            if (inSet(&.{ "tbody", "thead", "tfoot" }, n)) return b.setMode(.table_body);
            if (std.mem.eql(u8, n, "caption")) return b.setMode(.caption);
            if (std.mem.eql(u8, n, "colgroup")) return b.setMode(.column_group);
            if (std.mem.eql(u8, n, "table")) return b.setMode(.table);
        }
    }

    fn setMode(b: *Builder, m: Mode) void {
        b.mode = m;
    }

    fn processText(b: *Builder, s0: []const u8) Allocator.Error!void {
        var s = s0;
        if (b.skip_lf) {
            b.skip_lf = false;
            if (s.len > 0 and s[0] == '\n') s = s[1..];
        }
        if (s.len == 0) return;
        const tabular = inSet(&.{ "table", "tbody", "tfoot", "thead", "tr" }, b.curName());
        const whitespace = std.mem.indexOfNone(u8, s, " \t\n\x0c\r") == null;
        if (b.mode == .table or b.mode == .table_body or b.mode == .row) {
            if (tabular and !whitespace) {
                b.foster = true;
                defer b.foster = false;
                try b.reconstruct();
                return b.insertText(s);
            }
            if (tabular) return b.insertText(s);
        } else if (b.mode == .column_group) {
            if (whitespace) return b.insertText(s);
            if (!std.mem.eql(u8, b.curName(), "colgroup")) return;
            b.popOne();
            b.mode = .table;
            return b.processText(s);
        }
        if (!whitespace) try b.reconstruct();
        try b.insertText(s);
    }

    fn processStart(b: *Builder, name0: []const u8, attrs: []const Attr, raw: []const u8) Allocator.Error!void {
        b.skip_lf = false;
        if (b.stack.items.len >= max_open and !isVoid(name0)) {
            if (raw.len > 0) try b.insertText(raw);
            return;
        }
        switch (b.mode) {
            .body => try b.bodyStart(name0, attrs),
            .table => try b.tableStart(name0, attrs),
            .caption => {
                if (inSet(&.{ "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr" }, name0)) {
                    if (!b.hasInScope("caption", .table)) return;
                    b.closeCaption();
                    return b.processStart(name0, attrs, raw);
                }
                try b.bodyStart(name0, attrs);
            },
            .column_group => {
                if (std.mem.eql(u8, name0, "html")) return;
                if (std.mem.eql(u8, name0, "col")) return b.insertVoid("col", attrs);
                if (!std.mem.eql(u8, b.curName(), "colgroup")) return;
                b.popOne();
                b.mode = .table;
                try b.processStart(name0, attrs, raw);
            },
            .table_body => {
                if (std.mem.eql(u8, name0, "tr")) {
                    b.clearTo(&.{ "tbody", "tfoot", "thead" });
                    _ = try b.insertElement("tr", attrs);
                    b.mode = .row;
                } else if (inSet(&.{ "th", "td" }, name0)) {
                    b.clearTo(&.{ "tbody", "tfoot", "thead" });
                    _ = try b.insertElement("tr", &.{});
                    b.mode = .row;
                    try b.processStart(name0, attrs, raw);
                } else if (inSet(&.{ "caption", "col", "colgroup", "tbody", "tfoot", "thead" }, name0)) {
                    if (!(b.hasInScope("tbody", .table) or b.hasInScope("thead", .table) or b.hasInScope("tfoot", .table))) return;
                    b.clearTo(&.{ "tbody", "tfoot", "thead" });
                    b.popOne();
                    b.mode = .table;
                    try b.processStart(name0, attrs, raw);
                } else try b.tableStart(name0, attrs);
            },
            .row => {
                if (inSet(&.{ "th", "td" }, name0)) {
                    b.clearTo(&.{"tr"});
                    _ = try b.insertElement(name0, attrs);
                    b.mode = .cell;
                    try b.afe.append(b.a(), marker);
                } else if (inSet(&.{ "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr" }, name0)) {
                    if (!b.hasInScope("tr", .table)) return;
                    b.clearTo(&.{"tr"});
                    b.popOne();
                    b.mode = .table_body;
                    try b.processStart(name0, attrs, raw);
                } else try b.tableStart(name0, attrs);
            },
            .cell => {
                if (inSet(&.{ "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr" }, name0)) {
                    if (!(b.hasInScope("td", .table) or b.hasInScope("th", .table))) return;
                    b.closeCell();
                    return b.processStart(name0, attrs, raw);
                }
                try b.bodyStart(name0, attrs);
            },
        }
    }

    fn closeCaption(b: *Builder) void {
        b.impliedExcept("");
        b.popUntil("caption");
        b.clearAfe();
        b.mode = .table;
    }

    fn closeCell(b: *Builder) void {
        b.impliedExcept("");
        while (b.stack.items.len > 0) {
            const n = b.curName();
            b.popOne();
            if (std.mem.eql(u8, n, "td") or std.mem.eql(u8, n, "th")) break;
        }
        b.clearAfe();
        b.mode = .row;
    }

    fn tableStart(b: *Builder, name: []const u8, attrs: []const Attr) Allocator.Error!void {
        if (std.mem.eql(u8, name, "caption")) {
            b.clearTo(&.{"table"});
            try b.afe.append(b.a(), marker);
            _ = try b.insertElement(name, attrs);
            b.mode = .caption;
        } else if (std.mem.eql(u8, name, "colgroup")) {
            b.clearTo(&.{"table"});
            _ = try b.insertElement(name, attrs);
            b.mode = .column_group;
        } else if (std.mem.eql(u8, name, "col")) {
            b.clearTo(&.{"table"});
            _ = try b.insertElement("colgroup", &.{});
            b.mode = .column_group;
            try b.processStart(name, attrs, "");
        } else if (inSet(&.{ "tbody", "tfoot", "thead" }, name)) {
            b.clearTo(&.{"table"});
            _ = try b.insertElement(name, attrs);
            b.mode = .table_body;
        } else if (inSet(&.{ "td", "th", "tr" }, name)) {
            b.clearTo(&.{"table"});
            _ = try b.insertElement("tbody", &.{});
            b.mode = .table_body;
            try b.processStart(name, attrs, "");
        } else if (std.mem.eql(u8, name, "table")) {
            if (!b.hasInScope("table", .table)) return;
            b.popUntil("table");
            b.resetMode();
            try b.processStart(name, attrs, "");
        } else {
            b.foster = true;
            defer b.foster = false;
            try b.bodyStart(name, attrs);
        }
    }

    fn bodyStart(b: *Builder, name0: []const u8, attrs: []const Attr) Allocator.Error!void {
        const name = if (std.mem.eql(u8, name0, "image")) "img" else name0;
        if (inSet(&.{ "html", "body", "head", "frameset", "frame", "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr" }, name)) return;
        if (std.mem.eql(u8, name, "a")) {
            var i = b.afe.items.len;
            while (i > 0) {
                i -= 1;
                const e = b.afe.items[i];
                if (e == marker) break;
                if (std.mem.eql(u8, b.node(e).name, "a")) {
                    _ = try b.adoption("a");
                    if (b.afeIndex(e)) |x| _ = b.afe.orderedRemove(x);
                    if (b.inStack(e)) |x| _ = b.stack.orderedRemove(x);
                    break;
                }
            }
            try b.reconstruct();
            try b.pushAfe(try b.insertElement(name, attrs));
        } else if (isFormatting(name)) {
            try b.reconstruct();
            if (std.mem.eql(u8, name, "nobr") and b.hasInScope("nobr", .default)) {
                _ = try b.adoption("nobr");
                try b.reconstruct();
            }
            try b.pushAfe(try b.insertElement(name, attrs));
        } else if (closesP(name)) {
            b.closeP();
            _ = try b.insertElement(name, attrs);
        } else if (isHeading(name)) {
            b.closeP();
            if (isHeading(b.curName())) b.popOne();
            _ = try b.insertElement(name, attrs);
        } else if (std.mem.eql(u8, name, "pre") or std.mem.eql(u8, name, "listing")) {
            b.closeP();
            _ = try b.insertElement(name, attrs);
            b.skip_lf = true;
        } else if (std.mem.eql(u8, name, "li")) {
            try b.listItem(&.{"li"});
            _ = try b.insertElement(name, attrs);
        } else if (std.mem.eql(u8, name, "dd") or std.mem.eql(u8, name, "dt")) {
            try b.listItem(&.{ "dd", "dt" });
            _ = try b.insertElement(name, attrs);
        } else if (std.mem.eql(u8, name, "form")) {
            b.closeP();
            _ = try b.insertElement(name, attrs);
        } else if (std.mem.eql(u8, name, "button")) {
            if (b.hasInScope("button", .default)) {
                b.impliedExcept("");
                b.popUntil("button");
            }
            try b.reconstruct();
            _ = try b.insertElement(name, attrs);
        } else if (std.mem.eql(u8, name, "table")) {
            b.closeP();
            _ = try b.insertElement(name, attrs);
            b.mode = .table;
        } else if (inSet(&.{ "area", "br", "embed", "img", "keygen", "wbr", "input" }, name)) {
            try b.reconstruct();
            try b.insertVoid(name, attrs);
        } else if (inSet(&.{ "param", "source", "track", "base", "basefont", "bgsound", "link", "meta" }, name)) {
            try b.insertVoid(name, attrs);
        } else if (std.mem.eql(u8, name, "hr")) {
            b.closeP();
            try b.insertVoid(name, attrs);
        } else if (inSet(&.{ "applet", "marquee", "object" }, name)) {
            try b.reconstruct();
            _ = try b.insertElement(name, attrs);
            try b.afe.append(b.a(), marker);
        } else if (inSet(&.{ "optgroup", "option" }, name)) {
            if (std.mem.eql(u8, b.curName(), "option")) b.popOne();
            try b.reconstruct();
            _ = try b.insertElement(name, attrs);
        } else if (inSet(&.{ "rb", "rtc", "rp", "rt" }, name)) {
            if (b.hasInScope("ruby", .default)) b.impliedExcept(if (name.len == 2) "rtc" else "");
            _ = try b.insertElement(name, attrs);
        } else {
            try b.reconstruct();
            _ = try b.insertElement(name, attrs);
        }
    }

    fn listItem(b: *Builder, names: []const []const u8) Allocator.Error!void {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const n = b.node(b.stack.items[i]).name;
            var hit = false;
            for (names) |x| if (std.mem.eql(u8, x, n)) {
                hit = true;
            };
            if (hit) {
                b.impliedExcept(n);
                b.popUntil(n);
                break;
            }
            if (isSpecial(n) and !inSet(&.{ "address", "div", "p" }, n)) break;
        }
        b.closeP();
    }

    fn processEnd(b: *Builder, name0: []const u8) Allocator.Error!void {
        b.skip_lf = false;
        switch (b.mode) {
            .body => try b.bodyEnd(name0),
            .table => try b.tableEnd(name0),
            .caption => {
                if (std.mem.eql(u8, name0, "caption")) {
                    if (!b.hasInScope("caption", .table)) return;
                    return b.closeCaption();
                }
                if (std.mem.eql(u8, name0, "table")) {
                    if (!b.hasInScope("caption", .table)) return;
                    b.closeCaption();
                    return b.processEnd(name0);
                }
                if (inSet(&.{ "body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr" }, name0)) return;
                try b.bodyEnd(name0);
            },
            .column_group => {
                if (std.mem.eql(u8, name0, "colgroup")) {
                    if (std.mem.eql(u8, b.curName(), "colgroup")) {
                        b.popOne();
                        b.mode = .table;
                    }
                    return;
                }
                if (std.mem.eql(u8, name0, "col")) return;
                if (!std.mem.eql(u8, b.curName(), "colgroup")) return;
                b.popOne();
                b.mode = .table;
                try b.processEnd(name0);
            },
            .table_body => {
                if (inSet(&.{ "tbody", "tfoot", "thead" }, name0)) {
                    if (!b.hasInScope(name0, .table)) return;
                    b.clearTo(&.{ "tbody", "tfoot", "thead" });
                    b.popOne();
                    b.mode = .table;
                } else if (std.mem.eql(u8, name0, "table")) {
                    if (!(b.hasInScope("tbody", .table) or b.hasInScope("thead", .table) or b.hasInScope("tfoot", .table))) return;
                    b.clearTo(&.{ "tbody", "tfoot", "thead" });
                    b.popOne();
                    b.mode = .table;
                    try b.processEnd(name0);
                } else if (inSet(&.{ "body", "caption", "col", "colgroup", "html", "td", "th", "tr" }, name0)) {
                    return;
                } else try b.tableEnd(name0);
            },
            .row => {
                if (std.mem.eql(u8, name0, "tr")) {
                    if (!b.hasInScope("tr", .table)) return;
                    b.clearTo(&.{"tr"});
                    b.popOne();
                    b.mode = .table_body;
                } else if (std.mem.eql(u8, name0, "table")) {
                    if (!b.hasInScope("tr", .table)) return;
                    b.clearTo(&.{"tr"});
                    b.popOne();
                    b.mode = .table_body;
                    try b.processEnd(name0);
                } else if (inSet(&.{ "tbody", "tfoot", "thead" }, name0)) {
                    if (!b.hasInScope(name0, .table) or !b.hasInScope("tr", .table)) return;
                    b.clearTo(&.{"tr"});
                    b.popOne();
                    b.mode = .table_body;
                    try b.processEnd(name0);
                } else if (inSet(&.{ "body", "caption", "col", "colgroup", "html", "td", "th" }, name0)) {
                    return;
                } else try b.tableEnd(name0);
            },
            .cell => {
                if (std.mem.eql(u8, name0, "td") or std.mem.eql(u8, name0, "th")) {
                    if (!b.hasInScope(name0, .table)) return;
                    b.impliedExcept("");
                    b.popUntil(name0);
                    b.clearAfe();
                    b.mode = .row;
                } else if (inSet(&.{ "table", "tbody", "tfoot", "thead", "tr" }, name0)) {
                    if (!b.hasInScope(name0, .table)) return;
                    b.closeCell();
                    try b.processEnd(name0);
                } else if (inSet(&.{ "body", "caption", "col", "colgroup", "html" }, name0)) {
                    return;
                } else try b.bodyEnd(name0);
            },
        }
    }

    fn tableEnd(b: *Builder, name: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, name, "table")) {
            if (!b.hasInScope("table", .table)) return;
            b.popUntil("table");
            b.resetMode();
        } else if (inSet(&.{ "body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr" }, name)) {
            return;
        } else {
            b.foster = true;
            defer b.foster = false;
            try b.bodyEnd(name);
        }
    }

    fn bodyEnd(b: *Builder, name: []const u8) Allocator.Error!void {
        if (inSet(&.{ "body", "html" }, name)) return;
        if (std.mem.eql(u8, name, "p")) {
            if (!b.hasInScope("p", .button)) _ = try b.insertElement("p", &.{});
            b.closeP();
        } else if (std.mem.eql(u8, name, "li")) {
            if (!b.hasInScope("li", .list_item)) return;
            b.impliedExcept("li");
            b.popUntil("li");
        } else if (std.mem.eql(u8, name, "dd") or std.mem.eql(u8, name, "dt")) {
            if (!b.hasInScope(name, .default)) return;
            b.impliedExcept(name);
            b.popUntil(name);
        } else if (isHeading(name)) {
            if (!b.headingInScope()) return;
            b.impliedExcept("");
            b.popUntilHeading();
        } else if (std.mem.eql(u8, name, "br")) {
            try b.bodyStart("br", &.{});
        } else if (isFormatting(name)) {
            if (!try b.adoption(name)) try b.anyOtherEnd(name);
        } else if (inSet(&.{ "applet", "marquee", "object" }, name)) {
            if (!b.hasInScope(name, .default)) return;
            b.impliedExcept("");
            b.popUntil(name);
            b.clearAfe();
        } else if (closesP(name) or inSet(&.{ "button", "form", "listing", "pre" }, name)) {
            if (!b.hasInScope(name, .default)) return;
            b.impliedExcept("");
            b.popUntil(name);
        } else try b.anyOtherEnd(name);
    }

    fn anyOtherEnd(b: *Builder, name: []const u8) Allocator.Error!void {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const n = b.node(b.stack.items[i]).name;
            if (std.mem.eql(u8, n, name)) {
                b.impliedExcept(name);
                while (b.stack.items.len > i) b.popOne();
                return;
            }
            if (isSpecial(n)) return;
        }
    }
};

fn hasAnchorAttr(attrs: []const Attr) bool {
    for (attrs) |at| {
        if (std.mem.eql(u8, at.name, "href") or std.mem.eql(u8, at.name, "name") or std.mem.eql(u8, at.name, "id")) return true;
    }
    return false;
}
