const std = @import("std");
const Allocator = std.mem.Allocator;
const html = @import("html");
const allow = @import("purify_allow.zig");

/// DOMPurify's ALLOWED_URI_REGEXP applied to a value with whitespace and control characters removed.
pub fn uriAllowed(v_in: []const u8) bool {
    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    for (v_in) |c| {
        if (c <= 0x20 or c == 0x7f) continue;
        if (n == buf.len) break;
        buf[n] = c;
        n += 1;
    }
    const v = buf[0..n];
    const schemes = [_][]const u8{ "http:", "https:", "ftp:", "ftps:", "mailto:", "tel:", "callto:", "sms:", "cid:", "xmpp:", "matrix:" };
    for (schemes) |s| if (std.ascii.startsWithIgnoreCase(v, s)) return true;
    if (v.len == 0) return false;
    if (!std.ascii.isAlphabetic(v[0])) return true;
    var i: usize = 0;
    while (i < v.len and (std.ascii.isAlphabetic(v[i]) or v[i] == '+' or v[i] == '.' or v[i] == '-')) i += 1;
    return i == v.len or v[i] != ':';
}

fn isDataAttr(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "data-") or name.len == 5) return false;
    for (name[5..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c >= 0x80)) return false;
    return true;
}

fn isAriaAttr(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "aria-") or name.len == 5) return false;
    for (name[5..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// DOMPurify's `_isValidAttribute` with its default configuration.
fn attrValid(tag: []const u8, name: []const u8, value: []const u8) bool {
    if (isDataAttr(name) or isAriaAttr(name)) return true;
    if (!allow.attrs.has(name)) return false;
    if (allow.uri_safe_attrs.has(name)) return true;
    if (uriAllowed(value)) return true;
    if ((std.mem.eql(u8, name, "src") or std.mem.eql(u8, name, "xlink:href") or std.mem.eql(u8, name, "href")) and
        !std.mem.eql(u8, tag, "script") and std.mem.startsWith(u8, value, "data:") and allow.data_uri_tags.has(tag)) return true;
    return value.len == 0;
}

fn isVoid(n: []const u8) bool {
    const v = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
    for (v) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

fn escape(a: Allocator, out: *std.ArrayList(u8), s: []const u8, attr: bool) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => if (attr) try out.appendSlice(a, "&quot;") else try out.append(a, '"'),
            0xC2 => if (i + 1 < s.len and s[i + 1] == 0xA0) {
                try out.appendSlice(a, "&nbsp;");
                i += 1;
            } else try out.append(a, s[i]),
            else => try out.append(a, s[i]),
        }
    }
}

const Walker = struct {
    a: Allocator,
    b: *html.Builder,
    out: std.ArrayList(u8) = .empty,

    fn children(w: *Walker, id: u32) Allocator.Error!void {
        var c = w.b.nodes.items[id].first;
        while (c != html.nil) : (c = w.b.nodes.items[c].next) try w.visit(c);
    }

    fn visit(w: *Walker, id: u32) Allocator.Error!void {
        const n = w.b.nodes.items[id];
        switch (n.kind) {
            .root => try w.children(id),
            .comment => {},
            .text => try escape(w.a, &w.out, n.text, false),
            .element => try w.element(id, n),
        }
    }

    fn element(w: *Walker, id: u32, n: html.Node) Allocator.Error!void {
        const name = n.name;
        const forbidden = std.mem.eql(u8, name, "style") or !allow.tags.has(name);
        if (forbidden or std.mem.eql(u8, name, "script")) {
            if (allow.forbid_contents.has(name) or std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "script")) return;
            return w.children(id);
        }
        try w.out.append(w.a, '<');
        try w.out.appendSlice(w.a, name);
        var target: ?[]const u8 = null;
        for (n.attrs) |at| {
            const value = std.mem.trim(u8, at.value, " \t\r\n\x0c");
            if (std.mem.eql(u8, name, "a") and std.mem.eql(u8, at.name, "target")) {
                target = value;
                continue;
            }
            if (std.mem.indexOf(u8, value, "-->") != null or std.mem.indexOf(u8, value, "]>") != null) continue;
            if (std.mem.eql(u8, at.name, "attributename") and std.mem.indexOf(u8, value, "href") != null) continue;
            if (!attrValid(name, at.name, value)) continue;
            try w.out.append(w.a, ' ');
            try w.out.appendSlice(w.a, at.name);
            try w.out.appendSlice(w.a, "=\"");
            try escape(w.a, &w.out, value, true);
            try w.out.append(w.a, '"');
        }
        // mermaid's hook gives a sanitized <a> its target back, with rel=noopener for _blank
        if (target) |t| {
            try w.out.appendSlice(w.a, " target=\"");
            try escape(w.a, &w.out, t, true);
            try w.out.append(w.a, '"');
            if (std.mem.eql(u8, t, "_blank")) try w.out.appendSlice(w.a, " rel=\"noopener\"");
        }
        try w.out.append(w.a, '>');
        if (isVoid(name)) return;
        try w.children(id);
        try w.out.appendSlice(w.a, "</");
        try w.out.appendSlice(w.a, name);
        try w.out.append(w.a, '>');
    }
};

/// Mermaid's sanitizeText on GitHub's settings: DOMPurify's default allow lists with `style` forbidden, on the html tree
/// builder's HTML5 parse, serialised as HTML.
pub fn sanitizeText(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "<&>") == null) return text;
    var b = try html.Builder.init(a, .{ .sanitize = false });
    defer b.deinit();
    try b.feedBlock(text);
    var w: Walker = .{ .a = a, .b = &b };
    try w.visit(0);
    return w.out.items;
}

test "sanitize matches DOMPurify on the cases that matter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "plain text", "plain text" },
        .{ "a & b", "a &amp; b" },
        .{ "1 < 2", "1 &lt; 2" },
        .{ "<b>bold</b> <script>alert(1)</script>x", "<b>bold</b> x" },
        .{ "<img src=x onerror=alert(1)>", "<img src=\"x\">" },
        .{ "<a href=\"javascript:alert(1)\">l</a>", "<a>l</a>" },
        .{ "<a href=\"https://x.test/?a=1&b=2\">l</a>", "<a href=\"https://x.test/?a=1&amp;b=2\">l</a>" },
        .{ "x<br/>y", "x<br>y" },
        .{ "<style>p{}</style>k", "k" },
        .{ "<div class=\"x\" onclick=\"y\">d</div>", "<div class=\"x\">d</div>" },
        .{ "<svg><circle/></svg>", "<svg><circle></circle></svg>" },
        .{ "<span style=\"color:red\">red</span>", "<span style=\"color:red\">red</span>" },
        .{ "&lt;c&gt; &copy;", "&lt;c&gt; \u{a9}" },
        .{ "<unknown>kept</unknown>", "kept" },
        .{ "<b>open", "<b>open</b>" },
        .{ "<a href=\"https://x.test\" target=\"_blank\">l</a>", "<a href=\"https://x.test\" target=\"_blank\" rel=\"noopener\">l</a>" },
        .{ "<p>one<p>two", "<p>one</p><p>two</p>" },
        .{ "<b>x</i></b>", "<b>x</b>" },
        .{ "<div data-x=\"1\" aria-label=\"y\" foo=\"z\">d</div>", "<div data-x=\"1\" aria-label=\"y\">d</div>" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try sanitizeText(a, c[0]));
    try std.testing.expect(uriAllowed("https://a.test"));
    try std.testing.expect(uriAllowed("/rel"));
    try std.testing.expect(uriAllowed("mailto:a@b.test"));
    try std.testing.expect(!uriAllowed("javascript:alert(1)"));
    try std.testing.expect(!uriAllowed("about:blank"));
    try std.testing.expect(!uriAllowed("java\tscript:alert(1)"));
}
