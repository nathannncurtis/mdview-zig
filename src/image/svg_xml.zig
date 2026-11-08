const std = @import("std");

pub const Error = error{ Corrupt, TooLarge, OutOfMemory };

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    tag: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(*Node) = .empty,
    parent: ?*Node = null,
    text: []const u8 = "",
    is_text: bool = false,

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs.items) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    pub fn href(n: *const Node) ?[]const u8 {
        return n.attr("href") orelse n.attr("xlink:href");
    }
};

const max_depth = 200;
const max_nodes = 100_000;
const max_expansion = 1 << 20;
const max_entity_depth = 6;

const Parser = struct {
    arena: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    nodes: usize = 0,
    root_only: bool = false,
    expanded: usize = 0,
    entities: std.StringHashMapUnmanaged([]const u8) = .empty,
    svg_prefixes: std.ArrayList([]const u8) = .empty,

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len and isWs(p.s[p.i])) p.i += 1;
    }

    fn startsWith(p: *Parser, lit: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], lit);
    }

    fn skipPast(p: *Parser, lit: []const u8) Error!void {
        const at = std.mem.indexOfPos(u8, p.s, p.i, lit) orelse return error.Corrupt;
        p.i = at + lit.len;
    }

    fn isNameChar(c: u8) bool {
        return !(isWs(c) or c == '=' or c == '>' or c == '/' or c == '<' or c == '"' or c == '\'' or c == 0);
    }

    fn name(p: *Parser) Error![]const u8 {
        const st = p.i;
        while (p.i < p.s.len and isNameChar(p.s[p.i])) p.i += 1;
        if (p.i == st) return error.Corrupt;
        return p.s[st..p.i];
    }

    fn expand(p: *Parser, out: *std.ArrayList(u8), raw: []const u8, depth: u32) Error!void {
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c != '&') {
                try out.append(p.arena, c);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
                try out.append(p.arena, c);
                i += 1;
                continue;
            };
            const ent = raw[i + 1 .. semi];
            i = semi + 1;
            if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x' or ent[1] == 'X') std.fmt.parseInt(u21, ent[2..], 16) else std.fmt.parseInt(u21, ent[1..], 10)) catch continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                try out.appendSlice(p.arena, buf[0..n]);
            } else if (std.mem.eql(u8, ent, "amp")) {
                try out.append(p.arena, '&');
            } else if (std.mem.eql(u8, ent, "lt")) {
                try out.append(p.arena, '<');
            } else if (std.mem.eql(u8, ent, "gt")) {
                try out.append(p.arena, '>');
            } else if (std.mem.eql(u8, ent, "quot")) {
                try out.append(p.arena, '"');
            } else if (std.mem.eql(u8, ent, "apos")) {
                try out.append(p.arena, '\'');
            } else if (p.entities.get(ent)) |val| {
                if (depth >= max_entity_depth) return error.TooLarge;
                p.expanded += val.len;
                if (p.expanded > max_expansion) return error.TooLarge;
                try p.expand(out, val, depth + 1);
            }
        }
    }

    fn decode(p: *Parser, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        try p.expand(&out, raw, 0);
        return out.items;
    }

    fn doctype(p: *Parser) Error!void {
        p.i += "<!DOCTYPE".len;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '>') {
                p.i += 1;
                return;
            }
            if (c == '[') {
                p.i += 1;
                try p.internalSubset();
                continue;
            }
            if (c == '"' or c == '\'') {
                p.i += 1;
                try p.skipPast(&[_]u8{c});
                continue;
            }
            p.i += 1;
        }
        return error.Corrupt;
    }

    fn internalSubset(p: *Parser) Error!void {
        while (p.i < p.s.len) {
            p.skipWs();
            if (p.i >= p.s.len) break;
            if (p.s[p.i] == ']') {
                p.i += 1;
                return;
            }
            if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<!ENTITY")) {
                p.i += "<!ENTITY".len;
                p.skipWs();
                if (p.i < p.s.len and p.s[p.i] == '%') {
                    try p.skipPast(">");
                    continue;
                }
                const nm = try p.name();
                p.skipWs();
                if (p.i < p.s.len and (p.s[p.i] == '"' or p.s[p.i] == '\'')) {
                    const q = p.s[p.i];
                    p.i += 1;
                    const end = std.mem.indexOfScalarPos(u8, p.s, p.i, q) orelse return error.Corrupt;
                    try p.entities.put(p.arena, nm, p.s[p.i..end]);
                    p.i = end + 1;
                }
                try p.skipPast(">");
            } else if (p.s[p.i] == '<') {
                try p.skipPast(">");
            } else {
                p.i += 1;
            }
        }
        return error.Corrupt;
    }

    fn isSvgPrefix(p: *Parser, prefix: []const u8) bool {
        if (std.mem.eql(u8, prefix, "svg")) return true;
        for (p.svg_prefixes.items) |q| if (std.mem.eql(u8, q, prefix)) return true;
        return false;
    }

    fn newNode(p: *Parser, tag: []const u8) Error!*Node {
        p.nodes += 1;
        if (p.nodes > max_nodes) return error.TooLarge;
        const n = try p.arena.create(Node);
        n.* = .{ .tag = tag };
        return n;
    }

    fn addChild(p: *Parser, parent: *Node, child: *Node) Error!void {
        child.parent = parent;
        try parent.children.append(p.arena, child);
    }

    fn keepsWhitespace(tag: []const u8) bool {
        for ([_][]const u8{ "text", "tspan", "textPath", "tref", "style" }) |t| if (std.mem.eql(u8, tag, t)) return true;
        return false;
    }

    fn run(p: *Parser) Error!*Node {
        if (p.startsWith("\xEF\xBB\xBF")) p.i = 3;
        var root: ?*Node = null;
        var stack: std.ArrayList(*Node) = .empty;
        while (p.i < p.s.len) {
            if (p.s[p.i] != '<') {
                const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '<') orelse p.s.len;
                const raw = p.s[p.i..end];
                p.i = end;
                if (stack.items.len == 0) continue;
                const top = stack.items[stack.items.len - 1];
                if (!keepsWhitespace(top.tag) and std.mem.trim(u8, raw, " \t\r\n").len == 0) continue;
                const t = try p.newNode("");
                t.is_text = true;
                t.text = try p.decode(raw);
                try p.addChild(top, t);
                continue;
            }
            if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<![CDATA[")) {
                p.i += 9;
                const end = std.mem.indexOfPos(u8, p.s, p.i, "]]>") orelse return error.Corrupt;
                if (stack.items.len > 0) {
                    const t = try p.newNode("");
                    t.is_text = true;
                    t.text = p.s[p.i..end];
                    try p.addChild(stack.items[stack.items.len - 1], t);
                }
                p.i = end + 3;
            } else if (p.startsWith("<?")) {
                try p.skipPast("?>");
            } else if (p.startsWith("<!DOCTYPE")) {
                try p.doctype();
            } else if (p.startsWith("</")) {
                p.i += 2;
                _ = try p.name();
                p.skipWs();
                if (p.i >= p.s.len or p.s[p.i] != '>') return error.Corrupt;
                p.i += 1;
                if (stack.items.len == 0) return error.Corrupt;
                _ = stack.pop();
                if (stack.items.len == 0) break;
            } else {
                p.i += 1;
                var tag = try p.name();
                const node = try p.newNode(tag);
                var self_close = false;
                while (true) {
                    p.skipWs();
                    if (p.i >= p.s.len) return error.Corrupt;
                    const c = p.s[p.i];
                    if (c == '>') {
                        p.i += 1;
                        break;
                    }
                    if (c == '/') {
                        if (p.i + 1 >= p.s.len or p.s[p.i + 1] != '>') return error.Corrupt;
                        p.i += 2;
                        self_close = true;
                        break;
                    }
                    const an = try p.name();
                    p.skipWs();
                    if (p.i >= p.s.len or p.s[p.i] != '=') return error.Corrupt;
                    p.i += 1;
                    p.skipWs();
                    if (p.i >= p.s.len or (p.s[p.i] != '"' and p.s[p.i] != '\'')) return error.Corrupt;
                    const q = p.s[p.i];
                    p.i += 1;
                    const end = std.mem.indexOfScalarPos(u8, p.s, p.i, q) orelse return error.Corrupt;
                    const val = try p.decode(p.s[p.i..end]);
                    p.i = end + 1;
                    if (std.mem.startsWith(u8, an, "xmlns:") and std.mem.eql(u8, val, "http://www.w3.org/2000/svg")) try p.svg_prefixes.append(p.arena, an[6..]);
                    try node.attrs.append(p.arena, .{ .name = an, .value = val });
                }
                if (std.mem.indexOfScalar(u8, tag, ':')) |c| {
                    if (p.isSvgPrefix(tag[0..c])) tag = tag[c + 1 ..];
                }
                node.tag = tag;
                if (stack.items.len == 0) {
                    if (root != null) return error.Corrupt;
                    root = node;
                    if (p.root_only) return node;
                } else {
                    try p.addChild(stack.items[stack.items.len - 1], node);
                }
                if (!self_close) {
                    if (stack.items.len >= max_depth) return error.TooLarge;
                    try stack.append(p.arena, node);
                } else if (stack.items.len == 0) break;
            }
        }
        if (stack.items.len != 0) return error.Corrupt;
        return root orelse error.Corrupt;
    }
};

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!*Node {
    var p: Parser = .{ .arena = arena, .s = bytes };
    return p.run();
}

pub fn parseRootTag(arena: std.mem.Allocator, bytes: []const u8) Error!*Node {
    var p: Parser = .{ .arena = arena, .s = bytes, .root_only = true };
    return p.run();
}

pub fn isSvg(bytes: []const u8) bool {
    var i: usize = 0;
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) i = 3;
    while (i < bytes.len) {
        while (i < bytes.len and Parser.isWs(bytes[i])) i += 1;
        const rest = bytes[i..];
        if (std.mem.startsWith(u8, rest, "<?")) {
            i = (std.mem.indexOfPos(u8, bytes, i, "?>") orelse return false) + 2;
        } else if (std.mem.startsWith(u8, rest, "<!--")) {
            i = (std.mem.indexOfPos(u8, bytes, i, "-->") orelse return false) + 3;
        } else if (std.mem.startsWith(u8, rest, "<!DOCTYPE") or std.mem.startsWith(u8, rest, "<!doctype")) {
            var depth: u32 = 0;
            i += 2;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] == '[') depth += 1;
                if (bytes[i] == ']' and depth > 0) depth -= 1;
                if (bytes[i] == '>' and depth == 0) break;
            }
            i += 1;
        } else if (rest.len > 0 and rest[0] == '<') {
            var j: usize = 1;
            while (j < rest.len and Parser.isNameChar(rest[j])) j += 1;
            const nm = rest[1..j];
            if (std.mem.eql(u8, nm, "svg")) return true;
            if (std.mem.indexOfScalar(u8, nm, ':')) |c| return std.mem.eql(u8, nm[c + 1 ..], "svg");
            return false;
        } else return false;
    }
    return false;
}

test "parse basic with entities and cdata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY c "red">]><svg a="&c;&#65;"><!-- x --><text>a &amp; <![CDATA[<b>]]></text></svg>
    );
    try std.testing.expectEqualStrings("svg", root.tag);
    try std.testing.expectEqualStrings("redA", root.attr("a").?);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqualStrings("a & ", root.children.items[0].children.items[0].text);
    try std.testing.expectEqualStrings("<b>", root.children.items[0].children.items[1].text);
}

test "billion laughs is bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.TooLarge, parse(arena.allocator(),
        \\<!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"><!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;"><!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;"><!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;"><!ENTITY g "&f;&f;&f;&f;&f;&f;&f;&f;&f;&f;">]><svg x="&g;&g;&g;"/>
    ));
}

test "malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Corrupt, parse(arena.allocator(), "<svg><g></svg>x"));
    try std.testing.expectError(error.Corrupt, parse(arena.allocator(), "<svg a=1/>"));
    try std.testing.expectError(error.Corrupt, parse(arena.allocator(), ""));
}

test "sniff" {
    try std.testing.expect(isSvg("\xEF\xBB\xBF <?xml version='1.0'?>\n<!-- c --><!DOCTYPE svg [ <!ENTITY a \"b\"> ]>\n<svg/>"));
    try std.testing.expect(isSvg("<svg:svg xmlns:svg='x'/>"));
    try std.testing.expect(!isSvg("<html><svg/></html>"));
    try std.testing.expect(!isSvg("PNG"));
}
