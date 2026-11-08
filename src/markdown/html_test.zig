const std = @import("std");
const testdata = @import("testdata");
const html = @import("html.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

const show_failures = 0;

fn parse(gpa: Allocator, input: []const u8, sanitize: bool) !html.Builder {
    var b = try html.Builder.init(gpa, .{ .sanitize = sanitize });
    errdefer b.deinit();
    try b.feedBlock(input);
    return b;
}

fn indent(out: *List, a: Allocator, depth: usize) !void {
    try out.appendSlice(a, "| ");
    for (0..depth) |_| try out.appendSlice(a, "  ");
}

fn attrLess(_: void, x: html.Attr, y: html.Attr) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn dump(b: *const html.Builder, a: Allocator, id: u32, depth: usize, out: *List) !void {
    const n = b.nodes.items[id];
    switch (n.kind) {
        .element => {
            try indent(out, a, depth);
            try out.print(a, "<{s}>\n", .{n.name});
            const sorted = try a.dupe(html.Attr, n.attrs);
            std.mem.sort(html.Attr, sorted, {}, attrLess);
            for (sorted) |at| {
                try indent(out, a, depth + 1);
                try out.print(a, "{s}=\"{s}\"\n", .{ at.name, at.value });
            }
            var c = n.first;
            while (c != html.nil) : (c = b.nodes.items[c].next) try dump(b, a, c, depth + 1, out);
        },
        .text => {
            try indent(out, a, depth);
            try out.print(a, "\"{s}\"\n", .{n.text});
        },
        .root, .comment => {},
    }
}

fn dumpBody(b: *const html.Builder, a: Allocator, depth: usize) ![]const u8 {
    var out: List = .empty;
    var c = b.nodes.items[0].first;
    while (c != html.nil) : (c = b.nodes.items[c].next) try dump(b, a, c, depth, &out);
    return out.items;
}

fn isVoidName(n: []const u8) bool {
    inline for (.{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |v| if (std.mem.eql(u8, n, v)) return true;
    return false;
}

fn escapeInto(out: *List, a: Allocator, s: []const u8, attr: bool) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => if (attr) try out.append(a, c) else try out.appendSlice(a, "&lt;"),
        '>' => if (attr) try out.append(a, c) else try out.appendSlice(a, "&gt;"),
        '"' => if (attr) try out.appendSlice(a, "&quot;") else try out.append(a, c),
        else => try out.append(a, c),
    };
}

fn percentEncode(out: *List, a: Allocator, s: []const u8) !void {
    for (s) |c| {
        if (c >= 0x80 or c == ' ') try out.print(a, "%{X:0>2}", .{c}) else try out.append(a, c);
    }
}

fn serialize(b: *const html.Builder, a: Allocator, id: u32, out: *List) !void {
    const n = b.nodes.items[id];
    switch (n.kind) {
        .root => {
            var c = n.first;
            while (c != html.nil) : (c = b.nodes.items[c].next) try serialize(b, a, c, out);
        },
        .text => if (!b.nodes.items[n.parent].hidden) try escapeInto(out, a, n.text, false),
        .comment => {},
        .element => {
            if (n.hidden) return;
            if (n.kept) {
                try out.print(a, "<{s}", .{n.name});
                for (n.attrs) |at| {
                    try out.print(a, " {s}=\"", .{at.name});
                    var enc: List = .empty;
                    if (std.mem.eql(u8, at.name, "href")) try percentEncode(&enc, a, at.value) else try enc.appendSlice(a, at.value);
                    try escapeInto(out, a, enc.items, true);
                    try out.append(a, '"');
                }
                try out.append(a, '>');
            }
            var c = n.first;
            while (c != html.nil) : (c = b.nodes.items[c].next) try serialize(b, a, c, out);
            if (n.kept and !isVoidName(n.name)) try out.print(a, "</{s}>", .{n.name});
        },
    }
}

fn render(gpa: Allocator, a: Allocator, input: []const u8) ![]const u8 {
    var b = try parse(gpa, input, true);
    defer b.deinit();
    var out: List = .empty;
    try serialize(&b, a, 0, &out);
    return out.items;
}

fn expectRender(input: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try render(testing.allocator, arena.allocator(), input);
    try testing.expectEqualStrings(want, got);
}

const TreeCase = struct { data: []const u8, context: []const u8, expected: []const u8 };

fn parseDat(a: Allocator, text: []const u8) ![]const TreeCase {
    var cases: std.ArrayList(TreeCase) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var section: enum { none, data, errors, fragment, document, other } = .none;
    var data: List = .empty;
    var context: []const u8 = "";
    var doc: List = .empty;
    var have = false;
    var scripting_on = false;
    while (true) {
        const line = if (lines.next()) |l| std.mem.trimEnd(u8, l, "\r") else null;
        const header = line == null or (line.?.len > 0 and line.?[0] == '#');
        if (header and have and (line == null or std.mem.eql(u8, line.?, "#data"))) {
            while (doc.items.len > 0 and doc.items[doc.items.len - 1] == '\n') _ = doc.pop();
            if (data.items.len > 0 and data.items[data.items.len - 1] == '\n') _ = data.pop();
            if (!scripting_on) try cases.append(a, .{ .data = data.items, .context = context, .expected = doc.items });
            data = .empty;
            doc = .empty;
            context = "";
            have = false;
            scripting_on = false;
        }
        const l = line orelse break;
        if (header) {
            if (std.mem.eql(u8, l, "#data")) {
                section = .data;
                have = true;
            } else if (std.mem.eql(u8, l, "#errors") or std.mem.eql(u8, l, "#new-errors")) {
                section = .errors;
            } else if (std.mem.eql(u8, l, "#document-fragment")) {
                section = .fragment;
            } else if (std.mem.eql(u8, l, "#document")) {
                section = .document;
            } else {
                if (std.mem.eql(u8, l, "#script-on")) scripting_on = true;
                section = .other;
            }
            continue;
        }
        switch (section) {
            .data => {
                try data.appendSlice(a, l);
                try data.append(a, '\n');
            },
            .fragment => context = l,
            .document => {
                try doc.appendSlice(a, l);
                try doc.append(a, '\n');
            },
            else => {},
        }
    }
    return cases.items;
}

fn containsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.ascii.findIgnoreCase(hay, n) != null) return true;
    return false;
}

const out_of_subset = [_][]const u8{
    "<html",    "<head",     "<body",    "<!doctype",  "<frame",   "<template", "<select",    "<svg",     "<math",    "<form",
    "<script",  "<style",    "<title",   "<textarea",  "<iframe",  "<plaintext", "<xmp",      "<noscript", "<noembed", "<noframes",
    "<isindex", "<menuitem", "<keygen",  "<option",    "<optgroup", "<input",   "<link",      "<meta",    "<base",    "<basefont",
    "<bgsound", "<command",  "<listing", "<image",     "<object",  "<applet",   "<marquee",   "<button",  "<param",   "<track",
    "<rb",      "<rtc",      "<dialog",  "<data",      "<hgroup",
};

fn inSubset(c: TreeCase) bool {
    if (c.context.len > 0 and !std.mem.eql(u8, c.context, "div") and !std.mem.eql(u8, c.context, "body")) return false;
    if (std.mem.indexOfAny(u8, c.data, "&\r\x00") != null) return false;
    if (c.data.len == 0 or std.ascii.isWhitespace(c.data[0])) return false;
    if (std.ascii.findIgnoreCase(c.data, "<p") != null and std.ascii.findIgnoreCase(c.data, "<table") != null) return false;
    if (std.mem.lastIndexOfScalar(u8, c.data, '<')) |lt| {
        if (std.mem.indexOfScalarPos(u8, c.data, lt, '>') == null) return false;
    }
    var words = std.mem.tokenizeAny(u8, c.data, " \t\n<>/=");
    while (words.next()) |w| if (w.len > html.max_name) return false;
    if (containsAny(c.data, &out_of_subset)) return false;
    if (std.mem.indexOfScalar(u8, c.data, '\n') != null and containsAny(c.data, &.{ "<a", "<b", "<i", "<u", "<font", "<em", "<strong", "<nobr", "<big", "<code", "<tt", "<small", "<strike", "<s>" })) return false;
    if (std.mem.indexOf(u8, c.expected, "<!--") != null or std.mem.indexOf(u8, c.expected, "<!DOCTYPE") != null) return false;
    return std.mem.indexOf(u8, c.expected, "xlink") == null;
}

fn expectedBody(c: TreeCase) ?[]const u8 {
    if (c.context.len > 0) return c.expected;
    const head = "| <html>\n|   <head>\n|   <body>";
    if (!std.mem.startsWith(u8, c.expected, head)) return null;
    const rest = c.expected[head.len..];
    return if (rest.len > 0 and rest[0] == '\n') rest[1..] else rest;
}

const Tally = struct { passed: usize = 0, failed: usize = 0, skipped: usize = 0 };

fn treeFile(gpa: Allocator, a: Allocator, name: []const u8, text: []const u8, tally: *Tally) !void {
    for (try parseDat(a, text)) |c| {
        if (!inSubset(c)) {
            tally.skipped += 1;
            continue;
        }
        const want = expectedBody(c) orelse {
            tally.skipped += 1;
            continue;
        };
        var b = try parse(gpa, c.data, false);
        defer b.deinit();
        const got = try dumpBody(&b, a, if (c.context.len > 0) 0 else 2);
        const trimmed = std.mem.trimEnd(u8, got, "\n");
        if (std.mem.eql(u8, trimmed, want)) {
            tally.passed += 1;
        } else {
            tally.failed += 1;
            if (show_failures > 0) std.debug.print("--- {s}\n{s}\n-- got\n{s}\n-- want\n{s}\n", .{ name, c.data, trimmed, want });
        }
    }
}

const tree_files = [_][]const u8{
    "tests1",       "tests2",         "tests3",   "tests5",   "tests6",     "tests7",   "tests9",           "tests14",
    "tests15",      "tests17",        "tests18",  "tests20",  "tests22",    "tests23",  "tests24",          "tests25",
    "adoption01",   "adoption02",     "blocks",   "tables01", "inbody01",   "tests_innerHTML_1", "tricky01", "void-in-phrasing",
    "main-element", "search-element", "ruby",     "webkit01", "webkit02",   "comments01",
};

test "html5lib tree construction subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tally: Tally = .{};
    inline for (tree_files) |f| try treeFile(testing.allocator, a, f, testdata.file("html5lib/tree/" ++ f ++ ".dat"), &tally);
    std.debug.print("\nhtml5lib tree: {d} passed, {d} failed, {d} outside the subset\n", .{ tally.passed, tally.failed, tally.skipped });
    try testing.expectEqual(@as(usize, 0), tally.failed);
    try testing.expect(tally.passed >= 100);
}

fn tokenCanon(a: Allocator, src: []const u8) ![]const u8 {
    var t = html.Tokenizer.init(a, src);
    var out: List = .empty;
    var text: List = .empty;
    while (try t.next()) |tok| {
        if (tok != .text and text.items.len > 0) {
            try out.print(a, "T {s}\n", .{text.items});
            text.clearRetainingCapacity();
        }
        switch (tok) {
            .text => |s| try text.appendSlice(a, s),
            .start => |s| {
                const sorted = try a.dupe(html.Attr, s.attrs);
                std.mem.sort(html.Attr, sorted, {}, attrLess);
                try out.print(a, "S {s}", .{s.name});
                for (sorted) |at| try out.print(a, " {s}={s}", .{ at.name, at.value });
                try out.print(a, "{s}\n", .{if (s.self_closing) " /" else ""});
            },
            .end => |n| try out.print(a, "E {s}\n", .{n}),
            .comment => |c| try out.print(a, "C {s}\n", .{c}),
            .doctype => try out.appendSlice(a, "D\n"),
        }
    }
    if (text.items.len > 0) try out.print(a, "T {s}\n", .{text.items});
    return out.items;
}

fn expectedCanon(a: Allocator, output: std.json.Value) !?[]const u8 {
    var out: List = .empty;
    var text: List = .empty;
    for (output.array.items) |tok| {
        const items = tok.array.items;
        const kind = items[0].string;
        if (!std.mem.eql(u8, kind, "Character") and text.items.len > 0) {
            try out.print(a, "T {s}\n", .{text.items});
            text.clearRetainingCapacity();
        }
        if (std.mem.eql(u8, kind, "Character")) {
            try text.appendSlice(a, items[1].string);
        } else if (std.mem.eql(u8, kind, "StartTag")) {
            try out.print(a, "S {s}", .{items[1].string});
            var attrs: std.ArrayList(html.Attr) = .empty;
            var it = items[2].object.iterator();
            while (it.next()) |e| try attrs.append(a, .{ .name = e.key_ptr.*, .value = e.value_ptr.string });
            std.mem.sort(html.Attr, attrs.items, {}, attrLess);
            for (attrs.items) |at| try out.print(a, " {s}={s}", .{ at.name, at.value });
            const sc = items.len > 3 and items[3] == .bool and items[3].bool;
            try out.print(a, "{s}\n", .{if (sc) " /" else ""});
        } else if (std.mem.eql(u8, kind, "EndTag")) {
            try out.print(a, "E {s}\n", .{items[1].string});
        } else if (std.mem.eql(u8, kind, "Comment")) {
            try out.print(a, "C {s}\n", .{items[1].string});
        } else return null;
    }
    if (text.items.len > 0) try out.print(a, "T {s}\n", .{text.items});
    return out.items;
}

fn legacyEntity(s: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '&')) |p| {
        i = p + 1;
        if (i < s.len and s[i] == '#') continue;
        var j = i;
        while (j < s.len and std.ascii.isAlphanumeric(s[j])) j += 1;
        if (j > i and (j >= s.len or s[j] != ';')) return true;
    }
    return false;
}

fn tokenizerFile(a: Allocator, text: []const u8, tally: *Tally) !void {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    for (root.object.get("tests").?.array.items) |t| {
        const o = t.object;
        if (o.get("initialStates")) |st| {
            if (st.array.items.len != 1 or !std.mem.eql(u8, st.array.items[0].string, "Data state")) {
                tally.skipped += 1;
                continue;
            }
        }
        if (o.get("lastStartTag") != null or o.get("doubleEscaped") != null) {
            tally.skipped += 1;
            continue;
        }
        const input = o.get("input").?.string;
        if (std.mem.indexOfAny(u8, input, "\r\x00") != null or legacyEntity(input)) {
            tally.skipped += 1;
            continue;
        }
        var skip = false;
        if (o.get("errors")) |errs| for (errs.array.items) |e| {
            if (std.mem.eql(u8, e.object.get("code").?.string, "eof-in-tag")) skip = true;
        };
        const want = (try expectedCanon(a, o.get("output").?)) orelse {
            tally.skipped += 1;
            continue;
        };
        if (skip) {
            tally.skipped += 1;
            continue;
        }
        const got = try tokenCanon(a, input);
        if (std.mem.eql(u8, got, want)) tally.passed += 1 else {
            tally.failed += 1;
            if (show_failures > 0) std.debug.print("--- {s}\n{s}\n-- got\n{s}\n-- want\n{s}\n", .{ o.get("description").?.string, input, got, want });
        }
    }
}

test "html5lib tokenizer subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tally: Tally = .{};
    inline for (.{ "test1", "test2", "test4", "numericEntities" }) |f| try tokenizerFile(a, testdata.file("html5lib/tokenizer/" ++ f ++ ".test"), &tally);
    std.debug.print("\nhtml5lib tokenizer: {d} passed, {d} failed, {d} outside the subset\n", .{ tally.passed, tally.failed, tally.skipped });
    try testing.expectEqual(@as(usize, 0), tally.failed);
    try testing.expect(tally.passed >= 100);
}

const github_differs = [_]u32{ 118, 120, 143, 144, 652 };
const SpecCase = struct { n: u32, section: []const u8, md: []const u8, html: []const u8, github: []const u8 };

fn normalizeGithub(a: Allocator, s: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, "user-content-", "");
}

test "GitHub expectations for the HTML spec examples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]const SpecCase, a, testdata.file("spec/spec_html.json"), .{});
    var same: usize = 0;
    var failed: std.ArrayList(u32) = .empty;
    for (cases) |c| {
        const got = try render(testing.allocator, a, c.html);
        const want = try normalizeGithub(a, c.github);
        if (std.mem.eql(u8, got, want)) same += 1 else {
            try failed.append(a, c.n);
            if (show_failures > 1) std.debug.print("--- {d}\n{s}\n-- got\n{s}\n-- want\n{s}\n", .{ c.n, c.html, got, want });
        }
    }
    std.debug.print("\nspec html vs github: {d}/{d}\nfailing: {any}\n", .{ same, cases.len, failed.items });
    try testing.expectEqualSlices(u32, &github_differs, failed.items);
}

test "tagfilter shows the nine tags as text" {
    try expectRender("<script>alert(1)</script>", "&lt;script&gt;alert(1)&lt;/script&gt;");
    try expectRender("<STYLE type=x>p{}</style>", "&lt;STYLE type=x&gt;p{}&lt;/style&gt;");
    try expectRender("<xmp>a</xmp><title>t</title><textarea>q</textarea>", "&lt;xmp&gt;a&lt;/xmp&gt;&lt;title&gt;t&lt;/title&gt;&lt;textarea&gt;q&lt;/textarea&gt;");
    try expectRender("<iframe src=x></iframe><noembed>n</noembed><noframes>f</noframes><plaintext>p", "&lt;iframe src=x&gt;&lt;/iframe&gt;&lt;noembed&gt;n&lt;/noembed&gt;&lt;noframes&gt;f&lt;/noframes&gt;&lt;plaintext&gt;p");
    try expectRender("<scripts>x</scripts>", "x");
}

test "comments, doctype and processing instructions vanish" {
    try expectRender("<!-- c -->text", "text");
    try expectRender("a<!---->b<!--->c<!DOCTYPE html>d<?php x ?>e<![CDATA[y]]>z", "abcdez");
}

test "elements outside the allowlist lose their tags and keep their content" {
    try expectRender("<center>x</center>", "x");
    try expectRender("<font color=red>f</font><u>u</u><nav>n</nav>", "fun");
    try expectRender("<p>a<figure>b</figure>c</p>", "<p>a</p>bc<p></p>");
    try expectRender("<video src=a>v</video><button>b</button><input value=x>", "vb");
}

test "svg content is removed" {
    try expectRender("a<svg viewBox='0 0 1 1'><circle/><text>t</text></svg>b", "ab");
}

test "protocols" {
    try expectRender("<a href=\"javascript:alert(1)\">x</a>", "x");
    try expectRender("<a href=\" javascript:1\">x</a>", "x");
    try expectRender("<a href=\"ja&#118;ascript:1\">x</a>", "x");
    try expectRender("<a href=\"https://x.dev/a?b=c:d\">x</a>", "<a href=\"https://x.dev/a?b=c:d\">x</a>");
    try expectRender("<a href=\"rel/p#h\">x</a><a href=\"mailto:a@b.c\">m</a>", "<a href=\"rel/p#h\">x</a><a href=\"mailto:a@b.c\">m</a>");
    try expectRender("<a href=\"tel:1\">x</a>", "x");
    try expectRender("<img src=\"data:image/png;base64,AA\" width=10>", "<img width=\"10\">");
    try expectRender("<img src=\"file:///etc/x\">", "<img>");
    try expectRender("<img src=\"http://x/a.png\" alt=\"a\">", "<img src=\"http://x/a.png\" alt=\"a\">");
    try expectRender("<blockquote cite=\"ftp://x\">q</blockquote>", "<blockquote>q</blockquote>");
}

test "attributes are filtered per element" {
    try expectRender("<h1 align=center style=\"color:red\" class=x>z</h1>", "<h1 align=\"center\">z</h1>");
    try expectRender("<div id=a onclick=x() class=c>d</div>", "<div id=\"a\">d</div>");
    try expectRender("<details open><summary>s</summary>t</details>", "<details open=\"\"><summary>s</summary>t</details>");
    try expectRender("<a name=x>t</a>", "<a name=\"x\">t</a>");
    try expectRender("<a title=t>t</a>", "t");
    try expectRender("<span role=button aria-hidden=true rel=me aria-label=x>s</span>", "<span>s</span>");
    try expectRender("<a href=# aria-label=x>s</a>", "<a href=\"#\" aria-label=\"x\">s</a>");
    try expectRender("<img src=a.png WIDTH=10 height=\"5\" ALIGN=left loading=lazy>", "<img src=\"a.png\" width=\"10\" height=\"5\" align=\"left\">");
    try expectRender("<td colspan=2>x</td>", "x");
    try expectRender("<p title=a title=b>x</p>", "<p title=\"a\">x</p>");
}

test "picture keeps its sources" {
    try expectRender(
        "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"a.png 2x, b.png\"><img src=c.png></picture>",
        "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"a.png 2x, b.png\"><img src=\"c.png\"></picture>",
    );
}

test "tables get a body and foster-parent stray content" {
    try expectRender("<table><tr><td>x</td></tr></table>", "<table><tbody><tr><td>x</td></tr></tbody></table>");
    try expectRender("<table>a<tr><td>x</td></tr></table>", "a<table><tbody><tr><td>x</td></tr></tbody></table>");
    try expectRender("<table><tr><td>a<td>b<tr><td>c</table>", "<table><tbody><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></tbody></table>");
}

test "implied end tags and block structure" {
    try expectRender("<ul><li>a<li>b</ul>", "<ul><li>a</li><li>b</li></ul>");
    try expectRender("<dl><dt>t<dd>d<dt>u</dl>", "<dl><dt>t</dt><dd>d</dd><dt>u</dt></dl>");
    try expectRender("<p>a<div>b</div>", "<p>a</p><div>b</div>");
    try expectRender("<div>x</span>y</div>", "<div>xy</div>");
    try expectRender("<br></br>", "<br><br>");
    try expectRender("<hr/>a<br/>b", "<hr>a<br>b");
    try expectRender("<div/>x", "<div>x</div>");
}

test "formatting elements reopen across blocks" {
    try expectRender("<b>1<p>2</b>3</p>", "<b>1</b><p><b>2</b>3</p>");
    try expectRender("<p><b>x</p><p>y</p>", "<p><b>x</b></p><p><b>y</b></p>");
    try expectRender("<b><i>x</b>y</i>z", "<b><i>x</i></b><i>y</i>z");
}

test "character references" {
    try expectRender("a &amp; b &lt; c &#65;&#x42; &copy; &copy &nope; &#0;", "a &amp; b &lt; c AB \u{a9} &amp;copy &amp;nope; \u{fffd}");
}

fn names(a: Allocator, b: *html.Builder) ![]const u8 {
    var out: List = .empty;
    for (b.ancestors()) |x| try out.print(a, "{s}{s} ", .{ x.name, if (x.markdown) "*" else "" });
    return std.mem.trimEnd(u8, out.items, " ");
}

test "builder: Markdown blocks inside HTML containers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try html.Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.feedBlock("<div align=\"center\">");
    try b.openMarkdown(.p);
    try testing.expectEqualStrings("div p*", try names(a, &b));
    try testing.expectEqualStrings("center", b.ancestors()[0].attrs[0].value);
    try b.closeMarkdown(.p);
    try b.openMarkdown(.ul);
    try b.openMarkdown(.li);
    try testing.expectEqualStrings("div ul* li*", try names(a, &b));
    try b.closeMarkdown(.li);
    try b.closeMarkdown(.ul);
    try b.feedBlock("</div>");
    try testing.expectEqualStrings("", try names(a, &b));
}

test "builder: a Markdown paragraph closes an open HTML paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = try html.Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.feedBlock("<p align=\"center\">");
    try b.openMarkdown(.p);
    try testing.expectEqualStrings("p*", try names(arena.allocator(), &b));
}

test "builder: formatting left open by HTML reopens in Markdown text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = try html.Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.feedBlock("<p><b>x</p>");
    try b.openMarkdown(.p);
    try testing.expectEqualStrings("p*", try names(arena.allocator(), &b));
    try b.markdownText();
    try testing.expectEqualStrings("p* b", try names(arena.allocator(), &b));
}

test "builder: inline tags and hidden content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = try html.Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.openMarkdown(.p);
    try b.feedInlineTag("<kbd>");
    try testing.expectEqualStrings("p* kbd", try names(arena.allocator(), &b));
    try b.feedInlineTag("</kbd>");
    try testing.expectEqualStrings("p*", try names(arena.allocator(), &b));
    try testing.expect(!b.hidden());
    try b.feedInlineTag("<svg>");
    try testing.expect(b.hidden());
    try b.feedInlineTag("</svg>");
    try testing.expect(!b.hidden());
}

test "builder: events" {
    var b = try html.Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.feedBlock("<div><center><b>x</b></center></div>");
    var got: List = .empty;
    defer got.deinit(testing.allocator);
    for (b.events.items) |e| {
        const tag: u8 = switch (e.kind) {
            .open => 'o',
            .close => 'c',
            .text => 't',
        };
        try got.append(testing.allocator, tag);
    }
    try testing.expectEqualStrings("ootcc", got.items);
}

fn repeat(a: Allocator, s: []const u8, n: usize) ![]const u8 {
    var out: List = .empty;
    for (0..n) |_| try out.appendSlice(a, s);
    return out.items;
}

test "caps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try parse(testing.allocator, try repeat(a, "<div>", 700), true);
    defer b.deinit();
    try testing.expect(b.stack.items.len <= html.max_open);
    try testing.expect(b.ancestors().len <= html.max_open);

    var attrs: List = .empty;
    try attrs.appendSlice(a, "<p");
    for (0..100) |i| try attrs.print(a, " a{d}=x", .{i});
    try attrs.append(a, '>');
    var t = html.Tokenizer.init(a, attrs.items);
    try testing.expectEqual(@as(usize, html.max_attrs), (try t.next()).?.start.attrs.len);

    const long = try std.fmt.allocPrint(a, "<p title=\"{s}\" lang=en>", .{try repeat(a, "x", 5000)});
    var t2 = html.Tokenizer.init(a, long);
    const tok = (try t2.next()).?.start;
    try testing.expectEqual(@as(usize, 1), tok.attrs.len);
    try testing.expectEqualStrings("lang", tok.attrs[0].name);
}

test "unterminated constructs stay linear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "<a ", "<!-- ", "<a b=\"", "<", "</", "&#", "<![CDATA[", "<?x ", "&amp", "<b><div>", "<table><b>" }) |unit| {
        const input = try std.mem.concat(a, u8, &.{ try repeat(a, unit, 20000), "tail" });
        var b = try parse(testing.allocator, input, true);
        b.deinit();
    }
}
