const std = @import("std");
const Allocator = std.mem.Allocator;
const entities = @import("entities.zig");
const emoji = @import("emoji.zig");
const unicode = @import("unicode.zig");

pub const Kind = enum { em, strong, strike, code, emoji, link, image };
pub const EventTag = enum { open, close, html, soft, hard };

/// `pos` is a byte offset into `Parsed.text`. `soft` and `hard` consume one byte of text
/// (a space and a newline); `html` consumes none and carries the tag source in `raw`.
pub const Event = struct {
    tag: EventTag,
    kind: Kind = .em,
    pos: u32,
    raw: []const u8 = "",
    url: []const u8 = "",
    title: []const u8 = "",
};

pub const Parsed = struct {
    text: []const u8,
    events: []const Event,
};

pub const LinkMatch = struct { end: usize, url: []const u8 = "", title: []const u8 = "" };
pub const AutolinkMatch = struct { end: usize, url: []const u8, text: []const u8 };

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// Called when a `]` closes an open `[` or `![`. `text_start` is the index after the opener,
    /// `close` the index of the `]`. Return the index just past the whole link and its
    /// destination, or null when it is not a link.
    link: *const fn (h: *const Hooks, a: Allocator, src: []const u8, text_start: usize, close: usize, image: bool) Allocator.Error!?LinkMatch = noLink,
    /// Called at every `<`. Return the autolink starting there, or null.
    autolink: *const fn (h: *const Hooks, a: Allocator, src: []const u8, lt: usize) Allocator.Error!?AutolinkMatch = noAutolink,
};

fn noLink(_: *const Hooks, _: Allocator, _: []const u8, _: usize, _: usize, _: bool) Allocator.Error!?LinkMatch {
    return null;
}

fn noAutolink(_: *const Hooks, _: Allocator, _: []const u8, _: usize) Allocator.Error!?AutolinkMatch {
    return null;
}

pub fn parse(a: Allocator, src: []const u8, hooks: *const Hooks) Allocator.Error!Parsed {
    var s: Scanner = .{ .a = a, .src = src, .hooks = hooks };
    try s.scan();
    try s.processEmphasis(none);
    return s.flatten();
}

const none: u32 = std.math.maxInt(u32);

const NodeTag = enum { text, open, close, html, soft, hard };

const Node = struct {
    tag: NodeTag,
    kind: Kind = .em,
    s: []const u8 = "",
    url: []const u8 = "",
    title: []const u8 = "",
    prev: u32 = none,
    next: u32 = none,
};

const Delim = struct {
    node: u32,
    ch: u8,
    orig: u32,
    count: u32,
    can_open: bool,
    can_close: bool,
    prev: u32,
    next: u32,
};

const Bracket = struct {
    node: u32,
    image: bool,
    text_start: usize,
    active: bool = true,
    prev_delim: u32,
};

const Scanner = struct {
    a: Allocator,
    src: []const u8,
    hooks: *const Hooks,
    nodes: std.ArrayList(Node) = .empty,
    head: u32 = none,
    tail: u32 = none,
    delims: std.ArrayList(Delim) = .empty,
    dhead: u32 = none,
    dtail: u32 = none,
    brackets: std.ArrayList(Bracket) = .empty,

    fn newNode(s: *Scanner, n: Node) Allocator.Error!u32 {
        try s.nodes.append(s.a, n);
        return @intCast(s.nodes.items.len - 1);
    }

    fn push(s: *Scanner, n: Node) Allocator.Error!u32 {
        const id = try s.newNode(n);
        const items = s.nodes.items;
        items[id].prev = s.tail;
        if (s.tail != none) items[s.tail].next = id else s.head = id;
        s.tail = id;
        return id;
    }

    fn insertAfter(s: *Scanner, at: u32, n: Node) Allocator.Error!void {
        const id = try s.newNode(n);
        const items = s.nodes.items;
        const nx = items[at].next;
        items[id].prev = at;
        items[id].next = nx;
        items[at].next = id;
        if (nx != none) items[nx].prev = id else s.tail = id;
    }

    fn insertBefore(s: *Scanner, at: u32, n: Node) Allocator.Error!void {
        const id = try s.newNode(n);
        const items = s.nodes.items;
        const pv = items[at].prev;
        items[id].next = at;
        items[id].prev = pv;
        items[at].prev = id;
        if (pv != none) items[pv].next = id else s.head = id;
    }

    fn unlink(s: *Scanner, id: u32) void {
        const items = s.nodes.items;
        const pv = items[id].prev;
        const nx = items[id].next;
        if (pv != none) items[pv].next = nx else s.head = nx;
        if (nx != none) items[nx].prev = pv else s.tail = pv;
    }

    fn text(s: *Scanner, str: []const u8) Allocator.Error!void {
        if (str.len > 0) _ = try s.push(.{ .tag = .text, .s = str });
    }

    fn scan(s: *Scanner) Allocator.Error!void {
        const src = s.src;
        var i: usize = 0;
        var run: usize = 0;
        while (i < src.len) {
            if (!isSpecial(src[i]) or (src[i] == '!' and !(i + 1 < src.len and src[i + 1] == '['))) {
                i += 1;
                continue;
            }
            try s.text(src[run..i]);
            i = try s.special(i);
            run = i;
        }
        try s.text(src[run..]);
    }

    fn special(s: *Scanner, i: usize) Allocator.Error!usize {
        const src = s.src;
        switch (src[i]) {
            '\\' => {
                if (i + 1 < src.len and src[i + 1] == '\n') {
                    var j = i + 2;
                    while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                    if (j < src.len) _ = try s.push(.{ .tag = .hard });
                    return j;
                }
                if (i + 1 < src.len and isAsciiPunct(src[i + 1])) {
                    try s.text(src[i + 1 .. i + 2]);
                    return i + 2;
                }
                try s.text("\\");
                return i + 1;
            },
            '\n' => {
                var spaces: usize = 0;
                while (spaces < i and src[i - 1 - spaces] == ' ') spaces += 1;
                if (spaces > 0 and s.tail != none and s.nodes.items[s.tail].tag == .text) {
                    const n = &s.nodes.items[s.tail];
                    n.s = n.s[0 .. n.s.len - @min(spaces, n.s.len)];
                }
                var j = i + 1;
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                if (j < src.len) _ = try s.push(.{ .tag = if (spaces >= 2) .hard else .soft });
                return j;
            },
            '`' => return s.codeSpan(i),
            '&' => {
                if (try s.entity(i)) |end| return end;
                try s.text("&");
                return i + 1;
            },
            '<' => {
                if (try s.hooks.autolink(s.hooks, s.a, src, i)) |m| {
                    _ = try s.push(.{ .tag = .open, .kind = .link, .url = m.url });
                    try s.text(m.text);
                    _ = try s.push(.{ .tag = .close, .kind = .link });
                    return m.end;
                }
                if (htmlEnd(src, i)) |end| {
                    _ = try s.push(.{ .tag = .html, .s = src[i..end] });
                    return end;
                }
                try s.text("<");
                return i + 1;
            },
            '*', '_', '~' => return s.delimRun(i),
            '[' => {
                const id = try s.push(.{ .tag = .text, .s = "[" });
                try s.brackets.append(s.a, .{ .node = id, .image = false, .text_start = i + 1, .prev_delim = s.dtail });
                return i + 1;
            },
            '!' => {
                const id = try s.push(.{ .tag = .text, .s = "![" });
                try s.brackets.append(s.a, .{ .node = id, .image = true, .text_start = i + 2, .prev_delim = s.dtail });
                return i + 2;
            },
            ']' => return s.closeBracket(i),
            ':' => return s.emojiAt(i),
            else => unreachable,
        }
    }

    fn entity(s: *Scanner, i: usize) Allocator.Error!?usize {
        const src = s.src;
        var j = i + 1;
        if (j < src.len and src[j] == '#') {
            j += 1;
            const hex = j < src.len and (src[j] == 'x' or src[j] == 'X');
            if (hex) j += 1;
            const start = j;
            var v: u32 = 0;
            const limit: usize = if (hex) 6 else 7;
            while (j < src.len and j - start < limit) : (j += 1) {
                const d = std.fmt.charToDigit(src[j], if (hex) 16 else 10) catch break;
                v = v * (if (hex) @as(u32, 16) else 10) + d;
            }
            if (j == start or j >= src.len or src[j] != ';') return null;
            const cp: u21 = if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else @intCast(v);
            const buf = try s.a.alloc(u8, 4);
            const n = std.unicode.utf8Encode(cp, buf) catch unreachable;
            try s.text(buf[0..n]);
            return j + 1;
        }
        const start = j;
        while (j < src.len and j - start < 32 and std.ascii.isAlphanumeric(src[j])) j += 1;
        if (j == start or j >= src.len or src[j] != ';') return null;
        const v = entities.lookup(src[start..j]) orelse return null;
        try s.text(v);
        return j + 1;
    }

    fn codeSpan(s: *Scanner, i: usize) Allocator.Error!usize {
        const src = s.src;
        var n: usize = 0;
        while (i + n < src.len and src[i + n] == '`') n += 1;
        var j = i + n;
        while (j < src.len) {
            if (src[j] != '`') {
                j += 1;
                continue;
            }
            var m: usize = 0;
            while (j + m < src.len and src[j + m] == '`') m += 1;
            if (m == n) {
                const buf = try s.a.dupe(u8, src[i + n .. j]);
                for (buf) |*ch| if (ch.* == '\n') {
                    ch.* = ' ';
                };
                var content: []const u8 = buf;
                if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and
                    std.mem.trim(u8, content, " ").len > 0) content = content[1 .. content.len - 1];
                _ = try s.push(.{ .tag = .open, .kind = .code });
                try s.text(content);
                _ = try s.push(.{ .tag = .close, .kind = .code });
                return j + m;
            }
            j += m;
        }
        try s.text(src[i .. i + n]);
        return i + n;
    }

    fn emojiAt(s: *Scanner, i: usize) Allocator.Error!usize {
        const src = s.src;
        var j = i + 1;
        while (j < src.len and j - i <= 40 and (std.ascii.isLower(src[j]) or std.ascii.isDigit(src[j]) or src[j] == '_' or src[j] == '+' or src[j] == '-')) j += 1;
        if (j > i + 1 and j < src.len and src[j] == ':') {
            if (emoji.lookup(src[i + 1 .. j])) |glyph| {
                _ = try s.push(.{ .tag = .open, .kind = .emoji });
                try s.text(glyph);
                _ = try s.push(.{ .tag = .close, .kind = .emoji });
                return j + 1;
            }
        }
        try s.text(":");
        return i + 1;
    }

    fn delimRun(s: *Scanner, i: usize) Allocator.Error!usize {
        const src = s.src;
        const ch = src[i];
        var n: usize = 1;
        while (i + n < src.len and src[i + n] == ch) n += 1;
        if (ch == '~' and n > 2) {
            try s.text(src[i .. i + n]);
            return i + n;
        }
        const before: u21 = if (i == 0) '\n' else prevCp(src, i);
        const after: u21 = if (i + n >= src.len) '\n' else nextCp(src, i + n);
        const ws_b = unicode.isWhitespace(before);
        const ws_a = unicode.isWhitespace(after);
        const p_b = unicode.isPunctuation(before);
        const p_a = unicode.isPunctuation(after);
        const left = !ws_a and (!p_a or ws_b or p_b);
        const right = !ws_b and (!p_b or ws_a or p_a);
        var can_open = left;
        var can_close = right;
        if (ch == '_') {
            can_open = left and (!right or p_b);
            can_close = right and (!left or p_a);
        }
        const id = try s.push(.{ .tag = .text, .s = src[i .. i + n] });
        if (can_open or can_close) {
            try s.delims.append(s.a, .{
                .node = id,
                .ch = ch,
                .orig = @intCast(n),
                .count = @intCast(n),
                .can_open = can_open,
                .can_close = can_close,
                .prev = s.dtail,
                .next = none,
            });
            const d: u32 = @intCast(s.delims.items.len - 1);
            if (s.dtail != none) s.delims.items[s.dtail].next = d else s.dhead = d;
            s.dtail = d;
        }
        return i + n;
    }

    fn removeDelim(s: *Scanner, d: u32) void {
        const items = s.delims.items;
        const pv = items[d].prev;
        const nx = items[d].next;
        if (pv != none) items[pv].next = nx else s.dhead = nx;
        if (nx != none) items[nx].prev = pv else s.dtail = pv;
    }

    fn closeBracket(s: *Scanner, i: usize) Allocator.Error!usize {
        if (s.brackets.items.len == 0) {
            try s.text("]");
            return i + 1;
        }
        const b = s.brackets.items[s.brackets.items.len - 1];
        if (!b.active) {
            _ = s.brackets.pop();
            try s.text("]");
            return i + 1;
        }
        const m = try s.hooks.link(s.hooks, s.a, s.src, b.text_start, i, b.image) orelse {
            _ = s.brackets.pop();
            try s.text("]");
            return i + 1;
        };
        try s.processEmphasis(b.prev_delim);
        const opener = &s.nodes.items[b.node];
        opener.tag = .open;
        opener.kind = if (b.image) .image else .link;
        opener.s = "";
        opener.url = m.url;
        opener.title = m.title;
        _ = try s.push(.{ .tag = .close, .kind = if (b.image) .image else .link });
        _ = s.brackets.pop();
        if (!b.image) for (s.brackets.items) |*o| {
            if (!o.image) o.active = false;
        };
        return m.end;
    }

    fn processEmphasis(s: *Scanner, bottom: u32) Allocator.Error!void {
        var floor: [18]u32 = @splat(bottom);
        const d = s.delims.items;
        var closer = if (bottom == none) s.dhead else d[bottom].next;
        while (closer != none) {
            const cl = d[closer];
            if (!cl.can_close) {
                closer = cl.next;
                continue;
            }
            const key = @as(usize, if (cl.ch == '*') 0 else if (cl.ch == '_') 1 else 2) * 6 + @as(usize, @intFromBool(cl.can_open)) * 3 + cl.orig % 3;
            var opener = cl.prev;
            var found = false;
            while (opener != none and opener != bottom and opener != floor[key]) {
                const op = d[opener];
                if (op.ch == cl.ch and op.can_open) {
                    if (cl.ch == '~') {
                        if (op.count == cl.count) {
                            found = true;
                            break;
                        }
                    } else {
                        const odd = (cl.can_open or op.can_close) and cl.orig % 3 != 0 and (op.orig + cl.orig) % 3 == 0;
                        if (!odd) {
                            found = true;
                            break;
                        }
                    }
                }
                opener = op.prev;
            }
            if (!found) {
                floor[key] = cl.prev;
                const nx = cl.next;
                if (!cl.can_open) s.removeDelim(closer);
                closer = nx;
                continue;
            }

            const use: u32 = if (cl.ch == '~') cl.count else if (cl.count >= 2 and d[opener].count >= 2) 2 else 1;
            const kind: Kind = if (cl.ch == '~') .strike else if (use == 2) .strong else .em;
            const on = d[opener].node;
            const cn = d[closer].node;
            {
                const items = s.nodes.items;
                items[on].s = items[on].s[0 .. items[on].s.len - use];
                items[cn].s = items[cn].s[use..];
            }
            d[opener].count -= use;
            d[closer].count -= use;
            try s.insertAfter(on, .{ .tag = .open, .kind = kind });
            try s.insertBefore(cn, .{ .tag = .close, .kind = kind });

            var x = d[closer].prev;
            while (x != opener) {
                const pv = d[x].prev;
                s.removeDelim(x);
                x = pv;
            }
            if (d[opener].count == 0) {
                s.unlink(on);
                s.removeDelim(opener);
            }
            if (d[closer].count == 0) {
                s.unlink(cn);
                const nx = d[closer].next;
                s.removeDelim(closer);
                closer = nx;
            }
        }
        while (s.dtail != bottom) s.removeDelim(s.dtail);
    }

    fn flatten(s: *Scanner) Allocator.Error!Parsed {
        var buf: std.ArrayList(u8) = .empty;
        var events: std.ArrayList(Event) = .empty;
        var id = s.head;
        var open_stack: std.ArrayList(struct { kind: Kind, skipped: bool }) = .empty;
        while (id != none) : (id = s.nodes.items[id].next) {
            const n = s.nodes.items[id];
            const pos: u32 = @intCast(buf.items.len);
            // GitHub renders strong directly inside strong as a single strong.
            if ((n.kind == .strong or n.kind == .em) and n.tag == .open) {
                const skip = n.kind == .strong and open_stack.items.len > 0 and open_stack.items[open_stack.items.len - 1].kind == .strong;
                try open_stack.append(s.a, .{ .kind = n.kind, .skipped = skip });
                if (skip) continue;
            } else if ((n.kind == .strong or n.kind == .em) and n.tag == .close) {
                if (open_stack.pop().?.skipped) continue;
            }
            switch (n.tag) {
                .text => try buf.appendSlice(s.a, n.s),
                .open => try events.append(s.a, .{ .tag = .open, .kind = n.kind, .pos = pos, .url = n.url, .title = n.title }),
                .close => try events.append(s.a, .{ .tag = .close, .kind = n.kind, .pos = pos }),
                .html => try events.append(s.a, .{ .tag = .html, .pos = pos, .raw = n.s }),
                .soft => {
                    try events.append(s.a, .{ .tag = .soft, .pos = pos });
                    try buf.append(s.a, ' ');
                },
                .hard => {
                    try events.append(s.a, .{ .tag = .hard, .pos = pos });
                    try buf.append(s.a, '\n');
                },
            }
        }
        return .{ .text = buf.items, .events = events.items };
    }
};

fn isSpecial(c: u8) bool {
    return switch (c) {
        '\\', '`', '&', '<', '*', '_', '~', '[', ']', '!', '\n', ':' => true,
        else => false,
    };
}

pub fn isAsciiPunct(c: u8) bool {
    return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126);
}

fn prevCp(src: []const u8, i: usize) u21 {
    var j = i - 1;
    while (j > 0 and src[j] & 0xC0 == 0x80) j -= 1;
    return std.unicode.utf8Decode(src[j..i]) catch 0xFFFD;
}

fn nextCp(src: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(src[i]) catch return 0xFFFD;
    if (i + len > src.len) return 0xFFFD;
    return std.unicode.utf8Decode(src[i .. i + len]) catch 0xFFFD;
}

fn isHtmlSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn skipSpace(src: []const u8, i: usize) usize {
    var j = i;
    while (j < src.len and isHtmlSpace(src[j])) j += 1;
    return j;
}

/// End index of the raw inline HTML construct starting at the `<` at `i`.
fn htmlEnd(src: []const u8, i: usize) ?usize {
    var j = i + 1;
    if (j >= src.len) return null;
    const c = src[j];
    if (c == '/') {
        j += 1;
        if (j >= src.len or !std.ascii.isAlphabetic(src[j])) return null;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '-')) j += 1;
        j = skipSpace(src, j);
        return if (j < src.len and src[j] == '>') j + 1 else null;
    }
    if (std.ascii.isAlphabetic(c)) return openTagEnd(src, j);
    if (c == '?') {
        const e = std.mem.indexOfPos(u8, src, j + 1, "?>") orelse return null;
        return e + 2;
    }
    if (c != '!') return null;
    j += 1;
    if (std.mem.startsWith(u8, src[j..], "--")) {
        const body = j + 2;
        if (std.mem.startsWith(u8, src[body..], ">") or std.mem.startsWith(u8, src[body..], "->")) return null;
        const e = std.mem.indexOfPos(u8, src, body, "-->") orelse return null;
        const inner = src[body..e];
        if (inner.len > 0 and inner[inner.len - 1] == '-') return null;
        if (std.mem.indexOf(u8, inner, "--") != null) return null;
        return e + 3;
    }
    if (std.mem.startsWith(u8, src[j..], "[CDATA[")) {
        const e = std.mem.indexOfPos(u8, src, j + 7, "]]>") orelse return null;
        return e + 3;
    }
    if (j < src.len and std.ascii.isUpper(src[j])) {
        while (j < src.len and std.ascii.isUpper(src[j])) j += 1;
        if (j >= src.len or !isHtmlSpace(src[j])) return null;
        const e = std.mem.indexOfScalarPos(u8, src, j, '>') orelse return null;
        return e + 1;
    }
    return null;
}

fn openTagEnd(src: []const u8, start: usize) ?usize {
    var j = start;
    while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '-')) j += 1;
    while (true) {
        const after_name = j;
        j = skipSpace(src, j);
        if (j >= src.len) return null;
        if (src[j] == '>') return j + 1;
        if (src[j] == '/') return if (j + 1 < src.len and src[j + 1] == '>') j + 2 else null;
        if (j == after_name) return null;
        if (!(std.ascii.isAlphabetic(src[j]) or src[j] == '_' or src[j] == ':')) return null;
        j += 1;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_' or src[j] == '.' or src[j] == ':' or src[j] == '-')) j += 1;
        var k = skipSpace(src, j);
        if (k < src.len and src[k] == '=') {
            k = skipSpace(src, k + 1);
            if (k >= src.len) return null;
            if (src[k] == '"' or src[k] == '\'') {
                const e = std.mem.indexOfScalarPos(u8, src, k + 1, src[k]) orelse return null;
                j = e + 1;
            } else {
                const vs = k;
                while (k < src.len and std.mem.indexOfScalar(u8, " \t\n\"'=<>`", src[k]) == null) k += 1;
                if (k == vs) return null;
                j = k;
            }
        }
    }
}

const testing = std.testing;
const cases = @import("spec_inline_cases.zig").cases;

const test_hooks: Hooks = .{ .link = testLink, .autolink = testAutolink };

fn testLink(_: *const Hooks, _: Allocator, src: []const u8, _: usize, close: usize, image: bool) Allocator.Error!?LinkMatch {
    if (image or close + 1 >= src.len or src[close + 1] != '(') return null;
    var j = skipSpace(src, close + 2);
    const ds = j;
    var depth: usize = 0;
    if (j < src.len and src[j] == '<') {
        j = (std.mem.indexOfScalarPos(u8, src, j, '>') orelse return null) + 1;
    } else {
        while (j < src.len and !isHtmlSpace(src[j])) : (j += 1) {
            if (src[j] == '\\') {
                j += 1;
                continue;
            }
            if (src[j] == '(') depth += 1;
            if (src[j] == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
    }
    var url = src[ds..j];
    if (url.len >= 2 and url[0] == '<') url = url[1 .. url.len - 1];
    j = skipSpace(src, j);
    var title: []const u8 = "";
    if (j < src.len and (src[j] == '"' or src[j] == '\'')) {
        const e = std.mem.indexOfScalarPos(u8, src, j + 1, src[j]) orelse return null;
        title = src[j + 1 .. e];
        j = skipSpace(src, e + 1);
    }
    if (j >= src.len or src[j] != ')') return null;
    return .{ .end = j + 1, .url = url, .title = title };
}

fn testAutolink(_: *const Hooks, a: Allocator, src: []const u8, lt: usize) Allocator.Error!?AutolinkMatch {
    const e = std.mem.indexOfScalarPos(u8, src, lt, '>') orelse return null;
    const body = src[lt + 1 .. e];
    if (body.len == 0 or std.mem.indexOfAny(u8, body, " \t\n<") != null) return null;
    if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
        if (colon >= 2 and colon <= 32 and std.ascii.isAlphabetic(body[0])) return .{ .end = e + 1, .url = body, .text = body };
    }
    if (std.mem.indexOfScalar(u8, body, '@') != null and std.mem.indexOfScalar(u8, body, '\\') == null) {
        return .{ .end = e + 1, .url = try std.fmt.allocPrint(a, "mailto:{s}", .{body}), .text = body };
    }
    return null;
}

fn escapeInto(a: Allocator, out: *std.ArrayList(u8), str: []const u8) !void {
    for (str) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

fn toHtml(a: Allocator, p: Parsed) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (p.events) |ev| {
        try escapeInto(a, &out, p.text[cursor..ev.pos]);
        cursor = ev.pos;
        switch (ev.tag) {
            .html => try out.appendSlice(a, ev.raw),
            .soft => {
                try out.append(a, '\n');
                cursor += 1;
            },
            .hard => {
                try out.appendSlice(a, "<br />\n");
                cursor += 1;
            },
            .open => switch (ev.kind) {
                .em => try out.appendSlice(a, "<em>"),
                .strong => try out.appendSlice(a, "<strong>"),
                .strike => try out.appendSlice(a, "<del>"),
                .code => try out.appendSlice(a, "<code>"),
                .link => {
                    try out.appendSlice(a, "<a href=\"");
                    try escapeInto(a, &out, ev.url);
                    try out.append(a, '"');
                    if (ev.title.len > 0) {
                        try out.appendSlice(a, " title=\"");
                        try escapeInto(a, &out, ev.title);
                        try out.append(a, '"');
                    }
                    try out.append(a, '>');
                },
                .emoji, .image => {},
            },
            .close => switch (ev.kind) {
                .em => try out.appendSlice(a, "</em>"),
                .strong => try out.appendSlice(a, "</strong>"),
                .strike => try out.appendSlice(a, "</del>"),
                .code => try out.appendSlice(a, "</code>"),
                .link => try out.appendSlice(a, "</a>"),
                .emoji, .image => {},
            },
        }
    }
    try escapeInto(a, &out, p.text[cursor..]);
    return out.items;
}

/// Single-paragraph examples only: the expected output must be one `<p>`.
fn paragraphInput(a: Allocator, c: anytype) !?[]const u8 {
    if (!std.mem.startsWith(u8, c.html, "<p>") or !std.mem.endsWith(u8, c.html, "</p>\n")) return null;
    if (std.mem.indexOf(u8, c.html[3 .. c.html.len - 5], "<p>") != null) return null;
    if (std.mem.indexOf(u8, c.md, "\n\n") != null) return null;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, c.md, " \t\n"), '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, std.mem.trimStart(u8, l, " \t"));
    }
    return out.items;
}

// Link and autolink destinations (escapes, entities, percent-encoding) belong to the links lane;
// the stand-in link hooks here do not process them.
const known_failures = [_]u32{ 316, 318, 328, 356 };

test "spec examples (inline subset)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ran: usize = 0;
    var passed: usize = 0;
    var failed: std.ArrayList(u32) = .empty;
    defer failed.deinit(testing.allocator);
    for (cases) |c| {
        const input = (try paragraphInput(arena.allocator(), c)) orelse continue;
        ran += 1;
        const parsed = try parse(arena.allocator(), input, &test_hooks);
        const got = try toHtml(arena.allocator(), parsed);
        const want = c.html["<p>".len .. c.html.len - "</p>\n".len];
        if (std.mem.eql(u8, got, want)) {
            passed += 1;
        } else {
            try failed.append(testing.allocator, c.number);
            std.debug.print("\nexample {d} ({s})\n  md:   {any}\n  want: {s}\n  got:  {s}\n", .{ c.number, c.section, std.zig.fmtString(c.md), want, got });
        }
    }
    std.debug.print("\ninline spec examples: {d}/{d} pass ({d} in sections, {d} not single-paragraph)\n", .{ passed, ran, cases.len, cases.len - ran });
    for (failed.items) |n| try testing.expect(std.mem.indexOfScalar(u32, &known_failures, n) != null);
}

fn expectHtml(want: []const u8, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try toHtml(arena.allocator(), try parse(arena.allocator(), input, &test_hooks));
    try testing.expectEqualStrings(want, got);
}

test "strikethrough takes one or two tildes of equal length" {
    try expectHtml("<del>foo</del>", "~foo~");
    try expectHtml("<del>foo</del>", "~~foo~~");
    try expectHtml("~~foo~", "~~foo~");
    try expectHtml("This will ~~~not~~~ strike.", "This will ~~~not~~~ strike.");
    try expectHtml("a <del>b <em>c</em></del> d", "a ~~b *c*~~ d");
    try expectHtml("a ~ b ~", "a ~ b ~");
}

test "emoji shortcodes" {
    try expectHtml("\u{1F389} party", ":tada: party");
    try expectHtml(":nosuchemoji: x", ":nosuchemoji: x");
    try expectHtml("<em>\u{1F44D}</em>", "*:+1:*");
    try expectHtml("<code>:tada:</code>", "`:tada:`");
    try expectHtml("12:30:45", "12:30:45");
}

test "soft and hard breaks" {
    try expectHtml("a\nb", "a\nb");
    try expectHtml("a<br />\nb", "a  \nb");
    try expectHtml("a<br />\nb", "a\\\nb");
    try expectHtml("a", "a  \n");
}

test "raw html is kept out of the text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "press <kbd>Ctrl</kbd> and *go*", &test_hooks);
    try testing.expectEqualStrings("press Ctrl and go", p.text);
}
