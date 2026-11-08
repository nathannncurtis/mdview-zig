const std = @import("std");
const Allocator = std.mem.Allocator;

const allowed_tags = std.StaticStringMap(void).initComptime(.{
    .{"a"},       .{"abbr"},     .{"acronym"}, .{"address"}, .{"area"},     .{"article"}, .{"aside"},   .{"audio"},    .{"b"},       .{"bdi"},
    .{"bdo"},     .{"big"},      .{"blink"},   .{"blockquote"}, .{"body"},  .{"br"},      .{"button"},  .{"canvas"},   .{"caption"}, .{"center"},
    .{"cite"},    .{"code"},     .{"col"},     .{"colgroup"}, .{"content"}, .{"data"},    .{"datalist"}, .{"dd"},      .{"decorator"}, .{"del"},
    .{"details"}, .{"dfn"},      .{"dialog"},  .{"dir"},     .{"div"},      .{"dl"},      .{"dt"},      .{"element"},  .{"em"},      .{"fieldset"},
    .{"figcaption"}, .{"figure"}, .{"font"},   .{"footer"},  .{"form"},     .{"h1"},      .{"h2"},      .{"h3"},       .{"h4"},      .{"h5"},
    .{"h6"},      .{"head"},     .{"header"},  .{"hgroup"},  .{"hr"},       .{"html"},    .{"i"},       .{"img"},      .{"input"},   .{"ins"},
    .{"kbd"},     .{"label"},    .{"legend"},  .{"li"},      .{"main"},     .{"map"},     .{"mark"},    .{"marquee"},  .{"menu"},    .{"menuitem"},
    .{"meter"},   .{"nav"},      .{"nobr"},    .{"ol"},      .{"optgroup"}, .{"option"},  .{"output"},  .{"p"},        .{"picture"}, .{"pre"},
    .{"progress"}, .{"q"},       .{"rp"},      .{"rt"},      .{"ruby"},     .{"s"},       .{"samp"},    .{"section"},  .{"select"},  .{"shadow"},
    .{"small"},   .{"source"},   .{"spacer"},  .{"span"},    .{"strike"},   .{"strong"},  .{"sub"},     .{"summary"},  .{"sup"},     .{"table"},
    .{"tbody"},   .{"td"},       .{"tfoot"},   .{"th"},      .{"thead"},    .{"time"},    .{"tr"},      .{"track"},    .{"tt"},      .{"u"},
    .{"ul"},      .{"var"},      .{"video"},   .{"wbr"},     .{"svg"},      .{"g"},       .{"path"},    .{"circle"},   .{"rect"},    .{"line"},
    .{"polygon"}, .{"polyline"}, .{"ellipse"}, .{"text"},    .{"tspan"},    .{"defs"},    .{"title"},   .{"desc"},     .{"clippath"}, .{"mask"},
    .{"marker"},  .{"symbol"},   .{"lineargradient"}, .{"radialgradient"}, .{"stop"}, .{"pattern"}, .{"filter"},
});

// Elements whose content is dropped with them (DOMPurify's FORBID_CONTENTS) or that mermaid forbids.
const drop_with_content = std.StaticStringMap(void).initComptime(.{
    .{"script"}, .{"style"},   .{"noscript"}, .{"iframe"}, .{"noembed"}, .{"noframes"}, .{"xmp"},  .{"template"},
    .{"head"},   .{"plaintext"}, .{"title"},  .{"textarea"}, .{"math"},  .{"desc"},     .{"video"}, .{"audio"},
    .{"colgroup"}, .{"thead"},
});

const void_tags = std.StaticStringMap(void).initComptime(.{ .{"br"}, .{"hr"}, .{"img"}, .{"input"}, .{"wbr"}, .{"area"}, .{"col"}, .{"source"}, .{"track"} });

const allowed_attrs = std.StaticStringMap(void).initComptime(.{
    .{"accept"},  .{"align"},   .{"alt"},     .{"autocomplete"}, .{"bgcolor"}, .{"border"},  .{"cellpadding"}, .{"cellspacing"}, .{"checked"}, .{"class"},
    .{"clear"},   .{"color"},   .{"cols"},    .{"colspan"},      .{"dir"},     .{"disabled"}, .{"face"},        .{"for"},         .{"headers"}, .{"height"},
    .{"hidden"},  .{"high"},    .{"href"},    .{"hreflang"},     .{"id"},      .{"lang"},     .{"low"},         .{"max"},         .{"maxlength"}, .{"media"},
    .{"method"},  .{"min"},     .{"name"},    .{"nowrap"},       .{"open"},    .{"rel"},      .{"rev"},         .{"role"},        .{"rows"},    .{"rowspan"},
    .{"size"},    .{"span"},    .{"spellcheck"}, .{"src"},       .{"start"},   .{"style"},    .{"summary"},     .{"tabindex"},    .{"title"},   .{"type"},
    .{"usemap"},  .{"valign"},  .{"value"},   .{"width"},        .{"xmlns"},   .{"cx"},       .{"cy"},          .{"r"},           .{"x"},       .{"y"},
    .{"d"},       .{"fill"},    .{"stroke"},  .{"viewbox"},      .{"points"},  .{"x1"},       .{"x2"},          .{"y1"},          .{"y2"},      .{"transform"},
});

const uri_attrs = std.StaticStringMap(void).initComptime(.{ .{"href"}, .{"src"}, .{"xlink:href"}, .{"action"} });

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

fn decodeEntity(s: []const u8, i: usize, out: *std.ArrayList(u8), a: Allocator) Allocator.Error!usize {
    const rest = s[i..];
    const semi = std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 12)], ';') orelse return 0;
    const name = rest[1..semi];
    const table = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" },  .{ "lt", "<" },      .{ "gt", ">" },       .{ "quot", "\"" }, .{ "apos", "'" }, .{ "nbsp", "\u{a0}" },
        .{ "copy", "\u{a9}" }, .{ "reg", "\u{ae}" }, .{ "hellip", "\u{2026}" }, .{ "mdash", "\u{2014}" }, .{ "ndash", "\u{2013}" }, .{ "hearts", "\u{2665}" },
    };
    for (table) |t| if (std.mem.eql(u8, name, t[0])) {
        try out.appendSlice(a, t[1]);
        return semi + 1;
    };
    if (name.len > 1 and name[0] == '#') {
        const cp = (if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) else std.fmt.parseInt(u21, name[1..], 10)) catch return 0;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return 0;
        try out.appendSlice(a, buf[0..n]);
        return semi + 1;
    }
    return 0;
}

fn decode(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const n = try decodeEntity(s, i, &out, a);
            if (n > 0) {
                i += n;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

fn escapeText(a: Allocator, out: *std.ArrayList(u8), s: []const u8, attr: bool) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => if (!attr) try out.appendSlice(a, "&lt;") else try out.append(a, '<'),
            '>' => if (!attr) try out.appendSlice(a, "&gt;") else try out.append(a, '>'),
            '"' => if (attr) try out.appendSlice(a, "&quot;") else try out.append(a, '"'),
            0xC2 => if (i + 1 < s.len and s[i + 1] == 0xA0) {
                try out.appendSlice(a, "&nbsp;");
                i += 1;
            } else try out.append(a, s[i]),
            else => try out.append(a, s[i]),
        }
    }
}

const Open = struct { name: []const u8, kept: bool };

/// Mermaid's sanitizeText on GitHub's settings: DOMPurify with the default allow lists, `style` forbidden, serialised as HTML.
pub fn sanitizeText(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "<&>") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(Open) = .empty;
    var i: usize = 0;
    var txt_start: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            i += 1;
            continue;
        }
        const tag_start = i;
        if (std.mem.startsWith(u8, text[i..], "<!--")) {
            try flushText(a, &out, text[txt_start..i]);
            const e = std.mem.indexOf(u8, text[i + 4 ..], "-->");
            i = if (e) |x| i + 4 + x + 3 else text.len;
            txt_start = i;
            continue;
        }
        const closing = i + 1 < text.len and text[i + 1] == '/';
        var j = i + 1 + @as(usize, @intFromBool(closing));
        const ns = j;
        if (j >= text.len or !std.ascii.isAlphabetic(text[j])) {
            i += 1;
            continue;
        }
        while (j < text.len and !std.ascii.isWhitespace(text[j]) and text[j] != '>' and text[j] != '/') j += 1;
        const name = try std.ascii.allocLowerString(a, text[ns..j]);
        try flushText(a, &out, text[txt_start..tag_start]);
        // attributes
        const AttrPair = struct { name: []const u8, value: []const u8 };
        var attrs: std.ArrayList(AttrPair) = .empty;
        var self_closing = false;
        while (j < text.len and text[j] != '>') {
            if (std.ascii.isWhitespace(text[j])) {
                j += 1;
                continue;
            }
            if (text[j] == '/') {
                self_closing = true;
                j += 1;
                continue;
            }
            self_closing = false;
            const as = j;
            while (j < text.len and !std.ascii.isWhitespace(text[j]) and text[j] != '=' and text[j] != '>' and text[j] != '/') j += 1;
            const an = try std.ascii.allocLowerString(a, text[as..j]);
            while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
            var val: []const u8 = "";
            if (j < text.len and text[j] == '=') {
                j += 1;
                while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
                if (j < text.len and (text[j] == '"' or text[j] == '\'')) {
                    const q = text[j];
                    j += 1;
                    const vs = j;
                    while (j < text.len and text[j] != q) j += 1;
                    val = text[vs..j];
                    if (j < text.len) j += 1;
                } else {
                    const vs = j;
                    while (j < text.len and !std.ascii.isWhitespace(text[j]) and text[j] != '>') j += 1;
                    val = text[vs..j];
                }
            }
            try attrs.append(a, .{ .name = an, .value = try decode(a, val) });
        }
        if (j < text.len) j += 1;
        i = j;
        txt_start = j;
        const allowed = allowed_tags.has(name) and !std.mem.eql(u8, name, "style");
        if (closing) {
            var k = stack.items.len;
            while (k > 0) {
                k -= 1;
                if (std.mem.eql(u8, stack.items[k].name, name)) {
                    while (stack.items.len > k) {
                        const o = stack.pop().?;
                        if (o.kept) try out.print(a, "</{s}>", .{o.name});
                    }
                    break;
                }
            }
            continue;
        }
        if (drop_with_content.has(name) or std.mem.eql(u8, name, "style")) {
            if (!void_tags.has(name) and !self_closing) {
                const close = try std.fmt.allocPrint(a, "</{s}", .{name});
                const low = try std.ascii.allocLowerString(a, text[i..]);
                if (std.mem.indexOf(u8, low, close)) |e| {
                    const gt = std.mem.indexOfScalar(u8, text[i + e ..], '>');
                    i = if (gt) |g| i + e + g + 1 else text.len;
                } else i = text.len;
                txt_start = i;
            }
            continue;
        }
        if (!allowed) {
            if (!void_tags.has(name)) try stack.append(a, .{ .name = name, .kept = false });
            continue;
        }
        try out.append(a, '<');
        try out.appendSlice(a, name);
        for (attrs.items) |at| {
            const ok_name = allowed_attrs.has(at.name) or std.mem.startsWith(u8, at.name, "data-") or std.mem.startsWith(u8, at.name, "aria-");
            if (!ok_name) continue;
            if (uri_attrs.has(at.name) and !uriAllowed(at.value)) continue;
            try out.append(a, ' ');
            try out.appendSlice(a, at.name);
            try out.appendSlice(a, "=\"");
            try escapeText(a, &out, at.value, true);
            try out.append(a, '"');
        }
        try out.append(a, '>');
        if (!void_tags.has(name)) try stack.append(a, .{ .name = name, .kept = true });
    }
    try flushText(a, &out, text[txt_start..]);
    while (stack.pop()) |o| if (o.kept) try out.print(a, "</{s}>", .{o.name});
    return out.items;
}

fn flushText(a: Allocator, out: *std.ArrayList(u8), t: []const u8) Allocator.Error!void {
    if (t.len == 0) return;
    try escapeText(a, out, try decode(a, t), false);
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
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try sanitizeText(a, c[0]));
    try std.testing.expect(uriAllowed("https://a.test"));
    try std.testing.expect(uriAllowed("/rel"));
    try std.testing.expect(uriAllowed("mailto:a@b.test"));
    try std.testing.expect(!uriAllowed("javascript:alert(1)"));
    try std.testing.expect(!uriAllowed("about:blank"));
    try std.testing.expect(!uriAllowed("java\tscript:alert(1)"));
}
