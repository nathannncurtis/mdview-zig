// Stand-in for lane H1's html.Builder, on this branch only: a tokenizer for the WHATWG subset GitHub's
// sanitizer leaves, plus an open-element stack with the in-body implied end tags. Replace with H1's module.
const std = @import("std");
const Allocator = std.mem.Allocator;
const inl = @import("inline.zig");

pub const El = enum {
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    br,
    b,
    i,
    strong,
    em,
    a,
    pre,
    code,
    img,
    tt,
    div,
    ins,
    del,
    sup,
    sub,
    p,
    picture,
    ol,
    ul,
    table,
    thead,
    tbody,
    tfoot,
    blockquote,
    dl,
    dt,
    dd,
    kbd,
    q,
    samp,
    @"var",
    hr,
    ruby,
    rt,
    rp,
    li,
    tr,
    td,
    th,
    s,
    strike,
    summary,
    details,
    caption,
    figure,
    figcaption,
    abbr,
    bdo,
    cite,
    dfn,
    mark,
    small,
    source,
    span,
    time,
    wbr,

    pub fn isVoid(e: El) bool {
        return switch (e) {
            .br, .img, .hr, .wbr, .source => true,
            else => false,
        };
    }

    pub fn isHeading(e: El) bool {
        return @backingInt(e) <= @backingInt(El.h6);
    }

    /// Start tags that close an open `p`.
    pub fn closesP(e: El) bool {
        return switch (e) {
            .p, .div, .ul, .ol, .dl, .pre, .table, .blockquote, .hr, .details, .figure, .h1, .h2, .h3, .h4, .h5, .h6 => true,
            else => false,
        };
    }
};

pub const Attr = struct { name: []const u8, value: []const u8 };

const tagfilter = [_][]const u8{ "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext" };
const remove_contents = [_][]const u8{ "svg", "math", "noscript" };

const global_attrs = std.StaticStringMap(void).initComptime(.{
    .{"abbr"},   .{"align"}, .{"alt"},      .{"axis"},   .{"border"},  .{"colspan"}, .{"dir"},  .{"height"},  .{"hspace"}, .{"id"},
    .{"lang"},   .{"media"}, .{"name"},     .{"nowrap"}, .{"open"},    .{"rowspan"}, .{"span"}, .{"start"},   .{"title"},  .{"type"},
    .{"valign"}, .{"width"}, .{"datetime"}, .{"scope"},  .{"headers"}, .{"rel"},     .{"role"}, .{"summary"},
});

pub const Tag = struct {
    el: ?El,
    name: []const u8,
    attrs: []const Attr,
    closing: bool,
    self_closing: bool,
    raw: []const u8,

    /// The value of a sanitizer-allowed attribute.
    pub fn attr(t: Tag, name: []const u8) ?[]const u8 {
        const e = t.el orelse return null;
        const ok = global_attrs.has(name) or switch (e) {
            .a => std.mem.eql(u8, name, "href"),
            .img => std.mem.eql(u8, name, "src") or std.mem.eql(u8, name, "longdesc") or std.mem.eql(u8, name, "loading"),
            .source => std.mem.eql(u8, name, "srcset"),
            else => false,
        };
        if (!ok) return null;
        return attrOf(t.attrs, name);
    }
};

pub fn attrOf(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
    return null;
}

/// True for the schemes GitHub keeps: http and https (and mailto for links) or none at all (relative).
/// A single letter (a drive) and `file` are kept too, since this viewer shows local documents.
pub fn safeUrl(url: []const u8, mailto: bool) bool {
    const s = std.mem.trim(u8, url, " \t\r\n");
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '-' or s[i] == '.')) i += 1;
    if (i >= s.len or s[i] != ':' or i == 0) return true;
    const scheme = s[0..i];
    if (scheme.len == 1) return true;
    inline for (.{ "http", "https", "file" }) |ok| if (std.ascii.eqlIgnoreCase(scheme, ok)) return true;
    return mailto and std.ascii.eqlIgnoreCase(scheme, "mailto");
}

pub const Token = union(enum) {
    /// Decoded character data.
    text: []const u8,
    tag: Tag,
    /// A tag the tagfilter turns into visible text: its source.
    literal: []const u8,
};

const max_attrs = 64;
const max_value = 4096;

pub const Lexer = struct {
    src: []const u8,
    i: usize = 0,

    pub fn next(l: *Lexer, a: Allocator) Allocator.Error!?Token {
        while (l.i < l.src.len) {
            if (l.src[l.i] == '<' and l.i + 1 < l.src.len and markupStart(l.src[l.i + 1])) {
                if (try l.markup(a)) |tok| return tok;
                continue;
            }
            return .{ .text = try l.chars(a) };
        }
        return null;
    }

    fn markupStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '/' or c == '!' or c == '?';
    }

    fn chars(l: *Lexer, a: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var first = true;
        while (l.i < l.src.len) {
            const c = l.src[l.i];
            if (c == '<' and !first and l.i + 1 < l.src.len and markupStart(l.src[l.i + 1])) break;
            first = false;
            if (c == '&') {
                var buf: [4]u8 = undefined;
                if (inl.charRef(l.src, l.i, &buf)) |r| {
                    try out.appendSlice(a, r.text);
                    l.i = r.end;
                    continue;
                }
            }
            try out.append(a, c);
            l.i += 1;
        }
        return out.items;
    }

    fn skipPast(l: *Lexer, needle: []const u8) void {
        l.i = if (std.mem.indexOfPos(u8, l.src, l.i, needle)) |e| e + needle.len else l.src.len;
    }

    fn markup(l: *Lexer, a: Allocator) Allocator.Error!?Token {
        const src = l.src;
        const start = l.i;
        const c = src[start + 1];
        if (c == '!' or c == '?') {
            if (std.mem.startsWith(u8, src[start..], "<!--")) {
                l.i = start + 4;
                if (std.mem.startsWith(u8, src[l.i..], ">")) l.i += 1 else if (std.mem.startsWith(u8, src[l.i..], "->")) l.i += 2 else l.skipPast("-->");
            } else if (std.mem.startsWith(u8, src[start..], "<![CDATA[")) {
                l.i = start + 9;
                l.skipPast("]]>");
            } else {
                l.i = start + 2;
                l.skipPast(">");
            }
            return null;
        }
        var j = start + 1;
        const closing = c == '/';
        if (closing) j += 1;
        if (j >= src.len or !std.ascii.isAlphabetic(src[j])) {
            l.i = j;
            l.skipPast(">");
            return null;
        }
        const name_start = j;
        while (j < src.len and !isSpace(src[j]) and src[j] != '/' and src[j] != '>') j += 1;
        const name = try std.ascii.allocLowerString(a, src[name_start..j]);
        var attrs: std.ArrayList(Attr) = .empty;
        var self_closing = false;
        while (true) {
            while (j < src.len and (isSpace(src[j]) or src[j] == '/')) {
                self_closing = src[j] == '/';
                j += 1;
            }
            if (j >= src.len) {
                l.i = src.len;
                return null;
            }
            if (src[j] == '>') {
                j += 1;
                break;
            }
            self_closing = false;
            const an = j;
            j += 1;
            while (j < src.len and !isSpace(src[j]) and src[j] != '/' and src[j] != '>' and src[j] != '=') j += 1;
            const attr_name = try std.ascii.allocLowerString(a, src[an..j]);
            var k = j;
            while (k < src.len and isSpace(src[k])) k += 1;
            var value: []const u8 = "";
            if (k < src.len and src[k] == '=') {
                k += 1;
                while (k < src.len and isSpace(src[k])) k += 1;
                if (k >= src.len) {
                    l.i = src.len;
                    return null;
                }
                const quoted = src[k] == '"' or src[k] == '\'';
                const from = if (quoted) k + 1 else k;
                var to = from;
                if (quoted) {
                    to = std.mem.indexOfScalarPos(u8, src, from, src[k]) orelse {
                        l.i = src.len;
                        return null;
                    };
                    j = to + 1;
                } else {
                    while (to < src.len and !isSpace(src[to]) and src[to] != '>') to += 1;
                    j = to;
                }
                const raw = src[from..to];
                value = try decode(a, raw[0..@min(raw.len, max_value)]);
            }
            if (attrs.items.len < max_attrs and attrOf(attrs.items, attr_name) == null) try attrs.append(a, .{ .name = attr_name, .value = value });
        }
        l.i = j;
        const raw = src[start..j];
        for (tagfilter) |t| if (std.mem.eql(u8, name, t)) return .{ .literal = raw };
        return .{ .tag = .{
            .el = std.meta.stringToEnum(El, name),
            .name = name,
            .attrs = attrs.items,
            .closing = closing,
            .self_closing = self_closing,
            .raw = raw,
        } };
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn decode(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            var buf: [4]u8 = undefined;
            if (inl.charRef(raw, i, &buf)) |r| {
                try out.appendSlice(a, r.text);
                i = r.end;
                continue;
            }
        }
        try out.append(a, raw[i]);
        i += 1;
    }
    return out.items;
}

pub const Element = struct {
    el: El,
    attrs: []const Attr = &.{},
    /// Free for the consumer: where the element started in its text run, and so on.
    pos: u32 = 0,
    id: u32 = 0,
    group: u32 = 0,
    md_depth: u32 = 0,
    n: u32 = 0,
    flag: bool = false,

    pub fn attr(e: Element, name: []const u8) ?[]const u8 {
        return attrOf(e.attrs, name);
    }
};

pub const Handler = struct {
    ctx: *anyopaque,
    /// Before the element is pushed.
    open: *const fn (ctx: *anyopaque, e: *Element) Allocator.Error!void,
    /// Before the element is popped.
    close: *const fn (ctx: *anyopaque, e: *Element) Allocator.Error!void,
};

pub const max_open = 512;

pub const Builder = struct {
    stack: std.ArrayList(Element) = .empty,
    skip: ?[]const u8 = null,
    skip_depth: u32 = 0,

    pub fn skipping(b: *const Builder) bool {
        return b.skip != null;
    }

    pub fn feed(b: *Builder, a: Allocator, h: Handler, tag: Tag) Allocator.Error!void {
        if (b.skip) |name| {
            if (std.mem.eql(u8, tag.name, name)) {
                if (tag.closing) b.skip_depth -= 1 else if (!tag.self_closing) b.skip_depth += 1;
                if (b.skip_depth == 0) b.skip = null;
            }
            return;
        }
        const el = tag.el orelse {
            if (!tag.closing and !tag.self_closing) {
                for (remove_contents) |n| if (std.mem.eql(u8, n, tag.name)) {
                    b.skip = n;
                    b.skip_depth = 1;
                };
            }
            return;
        };
        if (tag.closing) return b.end(a, h, el);
        return b.start(a, h, tag, el);
    }

    fn find(b: *const Builder, target: El, stops: []const El) ?usize {
        var i = b.stack.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.stack.items[i].el;
            if (e == target) return i;
            for (stops) |s| if (s == e) return null;
        }
        return null;
    }

    fn closeTo(b: *Builder, h: Handler, len: usize) Allocator.Error!void {
        while (b.stack.items.len > len) {
            try h.close(h.ctx, &b.stack.items[b.stack.items.len - 1]);
            _ = b.stack.pop();
        }
    }

    pub fn closeToDepth(b: *Builder, h: Handler, md_depth: u32) Allocator.Error!void {
        while (b.stack.items.len > 0 and b.stack.items[b.stack.items.len - 1].md_depth > md_depth) try b.closeTo(h, b.stack.items.len - 1);
    }

    pub fn closeP(b: *Builder, h: Handler) Allocator.Error!void {
        try b.closeOpen(h, .p, &table_stops);
    }

    pub fn finish(b: *Builder, h: Handler) Allocator.Error!void {
        try b.closeTo(h, 0);
        b.skip = null;
    }

    const table_stops = [_]El{ .table, .td, .th, .caption };

    fn closeOpen(b: *Builder, h: Handler, target: El, stops: []const El) Allocator.Error!void {
        if (b.find(target, stops)) |i| try b.closeTo(h, i);
    }

    fn start(b: *Builder, a: Allocator, h: Handler, tag: Tag, el: El) Allocator.Error!void {
        if (el.closesP()) try b.closeOpen(h, .p, &table_stops);
        switch (el) {
            .li => try b.closeOpen(h, .li, &.{ .ul, .ol, .table }),
            .dt, .dd => {
                try b.closeOpen(h, .dt, &.{ .dl, .table });
                try b.closeOpen(h, .dd, &.{ .dl, .table });
            },
            .tr => {
                try b.closeOpen(h, .td, &.{.table});
                try b.closeOpen(h, .th, &.{.table});
                try b.closeOpen(h, .tr, &.{.table});
            },
            .td, .th => {
                try b.closeOpen(h, .td, &.{ .tr, .table });
                try b.closeOpen(h, .th, &.{ .tr, .table });
            },
            .thead, .tbody, .tfoot => {
                for ([_]El{ .td, .th, .tr, .thead, .tbody, .tfoot }) |t| try b.closeOpen(h, t, &.{.table});
            },
            else => {},
        }
        if (el.isHeading() and b.stack.items.len > 0 and b.stack.items[b.stack.items.len - 1].el.isHeading()) try b.closeTo(h, b.stack.items.len - 1);
        var e: Element = .{ .el = el, .attrs = tag.attrs };
        if (el.isVoid()) {
            try h.open(h.ctx, &e);
            try h.close(h.ctx, &e);
            return;
        }
        if (b.stack.items.len >= max_open) return;
        try h.open(h.ctx, &e);
        try b.stack.append(a, e);
    }

    fn end(b: *Builder, a: Allocator, h: Handler, el: El) Allocator.Error!void {
        if (el == .br) return b.start(a, h, .{ .el = .br, .name = "br", .attrs = &.{}, .closing = false, .self_closing = false, .raw = "" }, .br);
        if (el.isVoid()) return;
        const stops: []const El = switch (el) {
            .li => &.{ .ul, .ol, .table },
            .table, .td, .th, .tr, .caption, .thead, .tbody, .tfoot => &.{},
            else => &table_stops,
        };
        if (b.find(el, stops)) |i| return b.closeTo(h, i);
        if (el == .p) {
            var e: Element = .{ .el = .p, .flag = true };
            try h.open(h.ctx, &e);
            try h.close(h.ctx, &e);
        }
    }
};

const testing = std.testing;

fn lexAll(a: Allocator, src: []const u8) ![]const Token {
    var l: Lexer = .{ .src = src };
    var out: std.ArrayList(Token) = .empty;
    while (try l.next(a)) |t| try out.append(a, t);
    return out.items;
}

test "lexer drops comments and decodes entities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "a<!-- x -->b &amp; &#65;<IMG SRC=x.png alt='q\"'/>");
    try testing.expectEqualStrings("a", toks[0].text);
    try testing.expectEqualStrings("b & A", toks[1].text);
    try testing.expectEqual(El.img, toks[2].tag.el.?);
    try testing.expectEqualStrings("x.png", toks[2].tag.attr("src").?);
    try testing.expect(toks[2].tag.self_closing);
}

test "tagfilter names stay visible and unknown tags carry no element" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "<script>x</script><center>");
    try testing.expectEqualStrings("<script>", toks[0].literal);
    try testing.expect(toks[3].tag.el == null);
}

test "url schemes follow GitHub" {
    try testing.expect(safeUrl("https://a.b", false));
    try testing.expect(safeUrl("img/a.png", false));
    try testing.expect(!safeUrl("javascript:alert(1)", true));
    try testing.expect(!safeUrl("data:text/html,x", false));
    try testing.expect(!safeUrl("mailto:a@b.c", false));
    try testing.expect(safeUrl("mailto:a@b.c", true));
}
