const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    tag: []const u8 = "",
    text: []const u8 = "",
    attrs: []const Attr = &.{},
    kids: []const Node = &.{},

    pub fn attr(n: Node, name: []const u8) ?[]const u8 {
        for (n.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    pub fn textContent(n: Node, arena: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        if (n.tag.len == 0) return out.appendSlice(arena, n.text);
        for (n.kids) |k| try k.textContent(arena, out);
    }
};

pub const Error = error{ BadXml, OutOfMemory };

const max_depth = 256;

pub fn parse(arena: Allocator, src: []const u8) Error!Node {
    var p: Parser = .{ .arena = arena, .src = src };
    while (true) {
        p.skipSpace();
        if (p.eat("<?")) {
            try p.skipPast("?>");
        } else if (p.eat("<!--")) {
            try p.skipPast("-->");
        } else if (p.eat("<!")) {
            try p.skipPast(">");
        } else break;
    }
    return p.element(0);
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,

    fn eat(p: *Parser, s: []const u8) bool {
        if (!std.mem.startsWith(u8, p.src[p.pos..], s)) return false;
        p.pos += s.len;
        return true;
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    fn skipPast(p: *Parser, s: []const u8) Error!void {
        const i = std.mem.indexOf(u8, p.src[p.pos..], s) orelse return error.BadXml;
        p.pos += i + s.len;
    }

    fn name(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) switch (p.src[p.pos]) {
            ' ', '\t', '\r', '\n', '=', '>', '/' => break,
            else => {},
        };
        if (p.pos == start) return error.BadXml;
        return p.src[start..p.pos];
    }

    fn element(p: *Parser, depth: usize) Error!Node {
        if (depth > max_depth or !p.eat("<")) return error.BadXml;
        const tag = try p.name();
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            p.skipSpace();
            if (p.pos >= p.src.len) return error.BadXml;
            if (p.eat("/>")) return .{ .tag = tag, .attrs = attrs.items };
            if (p.eat(">")) break;
            const an = try p.name();
            p.skipSpace();
            var value: []const u8 = "";
            if (p.eat("=")) {
                p.skipSpace();
                if (p.pos >= p.src.len) return error.BadXml;
                const q = p.src[p.pos];
                if (q != '"' and q != '\'') return error.BadXml;
                p.pos += 1;
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, q) orelse return error.BadXml;
                value = try decode(p.arena, p.src[p.pos..end]);
                p.pos = end + 1;
            }
            try attrs.append(p.arena, .{ .name = an, .value = value });
        }
        var kids: std.ArrayList(Node) = .empty;
        while (true) {
            if (p.pos >= p.src.len) return error.BadXml;
            if (p.eat("</")) {
                const close = try p.name();
                if (!std.mem.eql(u8, close, tag)) return error.BadXml;
                try p.skipPast(">");
                return .{ .tag = tag, .attrs = attrs.items, .kids = kids.items };
            } else if (p.eat("<!--")) {
                try p.skipPast("-->");
            } else if (p.eat("<![CDATA[")) {
                const i = std.mem.indexOf(u8, p.src[p.pos..], "]]>") orelse return error.BadXml;
                try kids.append(p.arena, .{ .text = p.src[p.pos..][0..i] });
                p.pos += i + 3;
            } else if (p.eat("<?")) {
                try p.skipPast("?>");
            } else if (p.src[p.pos] == '<') {
                try kids.append(p.arena, try p.element(depth + 1));
            } else {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '<') orelse return error.BadXml;
                try kids.append(p.arena, .{ .text = try decode(p.arena, p.src[p.pos..end]) });
                p.pos = end;
            }
        }
    }
};

fn decode(arena: Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, s, i, ';') orelse return error.BadXml;
        const ent = s[i + 1 .. semi];
        i = semi + 1;
        if (std.mem.eql(u8, ent, "amp")) {
            try out.append(arena, '&');
        } else if (std.mem.eql(u8, ent, "lt")) {
            try out.append(arena, '<');
        } else if (std.mem.eql(u8, ent, "gt")) {
            try out.append(arena, '>');
        } else if (std.mem.eql(u8, ent, "quot")) {
            try out.append(arena, '"');
        } else if (std.mem.eql(u8, ent, "apos")) {
            try out.append(arena, '\'');
        } else if (ent.len > 1 and ent[0] == '#') {
            const hex = ent[1] == 'x';
            const cp = std.fmt.parseInt(u21, ent[if (hex) 2 else 1..], if (hex) 16 else 10) catch return error.BadXml;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadXml;
            try out.appendSlice(arena, buf[0..n]);
        } else return error.BadXml;
    }
    return out.items;
}

test "parse elements, attributes, entities and text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try parse(a, "<?xml version=\"1.0\"?><svg a='1' b=\"x&amp;y\"><g/><!-- c --><text>a &lt; b<![CDATA[ & c]]></text></svg>");
    try std.testing.expectEqualStrings("svg", root.tag);
    try std.testing.expectEqualStrings("x&y", root.attr("b").?);
    try std.testing.expectEqual(@as(usize, 2), root.kids.len);
    var text: std.ArrayList(u8) = .empty;
    try root.kids[1].textContent(a, &text);
    try std.testing.expectEqualStrings("a < b & c", text.items);
    try std.testing.expectError(error.BadXml, parse(a, "<a><b></a>"));
}
