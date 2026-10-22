const std = @import("std");
const md = @import("markdown.zig");
const links = @import("links.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const show_failures = 0;

const Example = struct { n: u32, section: []const u8, md: []const u8, html: []const u8 };

const Level = struct { kind: enum { quote, list, item }, id: u32 };

fn cr(out: *std.ArrayList(u8), a: Allocator) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
}

fn escape(out: *std.ArrayList(u8), a: Allocator, s: []const u8, breaks: bool) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\n' => if (breaks) try out.appendSlice(a, "<br />\n") else try out.append(a, c),
        else => try out.append(a, c),
    };
}

const Tag = enum { strong, em, del, code, a, img };

const Range = struct { start: u32, len: u32, tag: Tag, target: []const u8 = "", title: []const u8 = "" };

fn rangeLess(_: void, x: Range, y: Range) bool {
    if (x.start != y.start) return x.start < y.start;
    return x.len > y.len;
}

fn titleAttr(out: *std.ArrayList(u8), a: Allocator, title: []const u8) !void {
    if (title.len == 0) return;
    try out.appendSlice(a, " title=\"");
    try escape(out, a, title, false);
    try out.append(a, '"');
}

fn renderRanges(out: *std.ArrayList(u8), a: Allocator, text: []const u8, ranges: []const Range, lo: u32, hi: u32) !void {
    var pos = lo;
    var i: usize = 0;
    while (i < ranges.len) {
        const r = ranges[i];
        var j = i + 1;
        while (j < ranges.len and ranges[j].start < r.start + r.len) j += 1;
        try escape(out, a, text[pos..r.start], true);
        const inner = text[r.start..][0..r.len];
        const children = ranges[i + 1 .. j];
        switch (r.tag) {
            .strong, .em, .del => {
                const name = switch (r.tag) {
                    .strong => "strong",
                    .em => "em",
                    else => "del",
                };
                try out.print(a, "<{s}>", .{name});
                try renderRanges(out, a, text, children, r.start, r.start + r.len);
                try out.print(a, "</{s}>", .{name});
            },
            .code => {
                try out.appendSlice(a, "<code>");
                try escape(out, a, inner, false);
                try out.appendSlice(a, "</code>");
            },
            .a => {
                try out.appendSlice(a, "<a href=\"");
                try escape(out, a, try links.encodeUrl(a, r.target), false);
                try out.append(a, '"');
                try titleAttr(out, a, r.title);
                try out.append(a, '>');
                try renderRanges(out, a, text, children, r.start, r.start + r.len);
                try out.appendSlice(a, "</a>");
            },
            .img => {
                try out.appendSlice(a, "<img src=\"");
                try escape(out, a, try links.encodeUrl(a, r.target), false);
                try out.appendSlice(a, "\" alt=\"");
                try escape(out, a, inner, false);
                try out.append(a, '"');
                try titleAttr(out, a, r.title);
                try out.appendSlice(a, " />");
            },
        }
        pos = r.start + r.len;
        i = j;
    }
    try escape(out, a, text[pos..hi], true);
}

fn inlineHtml(out: *std.ArrayList(u8), a: Allocator, c: md.Inline) !void {
    var ranges: std.ArrayList(Range) = .empty;
    for (c.bold) |x| try ranges.append(a, .{ .start = x[0], .len = x[1], .tag = .strong });
    for (c.italic) |x| try ranges.append(a, .{ .start = x[0], .len = x[1], .tag = .em });
    for (c.strike) |x| try ranges.append(a, .{ .start = x[0], .len = x[1], .tag = .del });
    for (c.code) |x| try ranges.append(a, .{ .start = x[0], .len = x[1], .tag = .code });
    for (c.links) |l| try ranges.append(a, .{ .start = l.start, .len = l.len, .tag = .a, .target = l.target, .title = l.title });
    for (c.images) |l| try ranges.append(a, .{ .start = l.start, .len = l.len, .tag = .img, .target = l.target, .title = l.title });
    std.mem.sort(Range, ranges.items, {}, rangeLess);
    try renderRanges(out, a, c.text, ranges.items, 0, @intCast(c.text.len));
}

fn sameLevel(a: Level, b: Level) bool {
    return a.kind == b.kind and a.id == b.id;
}

fn closeLevel(out: *std.ArrayList(u8), a: Allocator, l: Level, ordered: bool) !void {
    switch (l.kind) {
        .quote => {
            try cr(out, a);
            try out.appendSlice(a, "</blockquote>\n");
        },
        .item => try out.appendSlice(a, "</li>\n"),
        .list => {
            try cr(out, a);
            try out.appendSlice(a, if (ordered) "</ol>\n" else "</ul>\n");
        },
    }
}

fn toHtml(a: Allocator, doc: md.Document) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(Level) = .empty;
    var ordered_stack: std.ArrayList(bool) = .empty;

    for (doc.blocks) |b| {
        var want: std.ArrayList(Level) = .empty;
        var want_ordered: std.ArrayList(md.Frame) = .empty;
        for (b.frames) |f| {
            switch (f.kind) {
                .quote => try want.append(a, .{ .kind = .quote, .id = f.id }),
                .list => {
                    try want.append(a, .{ .kind = .list, .id = f.group });
                    try want.append(a, .{ .kind = .item, .id = f.id });
                },
            }
            try want_ordered.append(a, f);
        }
        var common: usize = 0;
        while (common < stack.items.len and common < want.items.len and sameLevel(stack.items[common], want.items[common])) common += 1;
        while (stack.items.len > common) {
            const l = stack.pop().?;
            const o = ordered_stack.pop().?;
            try closeLevel(&out, a, l, o);
        }
        for (want.items[common..]) |l| {
            var fr: ?md.Frame = null;
            for (b.frames) |f| {
                if ((l.kind == .list and f.group == l.id and f.kind == .list) or (l.kind == .quote and f.id == l.id)) fr = f;
            }
            switch (l.kind) {
                .quote => {
                    try cr(&out, a);
                    try out.appendSlice(a, "<blockquote>\n");
                },
                .list => {
                    try cr(&out, a);
                    if (fr.?.ordered) {
                        if (fr.?.start == 1) try out.appendSlice(a, "<ol>\n") else try out.print(a, "<ol start=\"{d}\">\n", .{fr.?.start});
                    } else try out.appendSlice(a, "<ul>\n");
                },
                .item => try out.appendSlice(a, "<li>"),
            }
            try stack.append(a, l);
            try ordered_stack.append(a, fr != null and fr.?.ordered);
        }

        const tight = b.frames.len > 0 and b.frames[b.frames.len - 1].kind == .list and b.frames[b.frames.len - 1].tight;
        switch (b.kind) {
            .paragraph => {
                if (b.content.text.len == 0 or std.mem.eql(u8, b.content.text, " ")) continue;
                if (!tight) {
                    try cr(&out, a);
                    try out.appendSlice(a, "<p>");
                }
                switch (if (b.marks.len > 0) b.marks[b.marks.len - 1].mark.kind else md.Marker.none) {
                    .task_open => try out.appendSlice(a, "<input disabled=\"\" type=\"checkbox\"> "),
                    .task_done => try out.appendSlice(a, "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "),
                    else => {},
                }
                try inlineHtml(&out, a, b.content);
                if (!tight) try out.appendSlice(a, "</p>\n");
            },
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                const n = @intFromEnum(b.kind) - @intFromEnum(md.BlockKind.h1) + 1;
                try cr(&out, a);
                try out.print(a, "<h{d}>", .{n});
                try inlineHtml(&out, a, b.content);
                try out.print(a, "</h{d}>\n", .{n});
            },
            .hr => {
                try cr(&out, a);
                try out.appendSlice(a, "<hr />\n");
            },
            .code_block => {
                try cr(&out, a);
                if (b.lang.len > 0) {
                    try out.appendSlice(a, "<pre><code class=\"language-");
                    try escape(&out, a, b.lang, false);
                    try out.appendSlice(a, "\">");
                } else try out.appendSlice(a, "<pre><code>");
                try escape(&out, a, b.content.text, false);
                try out.appendSlice(a, "</code></pre>\n");
            },
            .table, .alert_title, .error_box => {},
        }
    }
    while (stack.items.len > 0) {
        const l = stack.pop().?;
        const o = ordered_stack.pop().?;
        try closeLevel(&out, a, l, o);
    }
    return out.items;
}

// The viewer renders soft breaks as spaces where the spec has a newline.
fn softBreaks(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (c == '\n' and i > 0 and s[i - 1] != '>' and i + 1 < s.len and s[i + 1] != '<') try out.append(a, ' ') else try out.append(a, c);
    }
    return out.items;
}

fn stripTag(s: []const u8, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, s, i, ';')) |e| {
                if (e - i < 10) {
                    i = e + 1;
                    continue;
                }
            }
        }
        if (s[i] == '<') {
            inline for (.{ "<em>", "</em>", "<strong>", "</strong>", "<a ", "</a>", "<img ", "<code>", "</code>" }) |tag| {
                if (std.mem.startsWith(u8, s[i..], tag)) {
                    const in_pre = out.items.len >= 5 and std.mem.endsWith(u8, out.items, "<pre>");
                    const closes_pre = std.mem.startsWith(u8, s[i..], "</code></pre>");
                    if (!(std.mem.eql(u8, tag, "<code>") and in_pre) and !(std.mem.eql(u8, tag, "</code>") and closes_pre)) {
                        i = (std.mem.indexOfScalarPos(u8, s, i, '>') orelse s.len - 1) + 1;
                        break;
                    }
                }
            } else {
                try out.append(a, s[i]);
                i += 1;
            }
            continue;
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

test "spec examples for the block sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky([]const Example, a, @embedFile("spec_examples.json"), .{});
    var pass: usize = 0;
    var loose_pass: usize = 0;
    var failed: std.ArrayList(u32) = .empty;
    for (parsed) |ex| {
        var doc = try md.parse(testing.allocator, ex.md);
        defer doc.deinit();
        const got = try softBreaks(a, try toHtml(a, doc));
        const want_html = try softBreaks(a, ex.html);
        if (std.mem.eql(u8, got, want_html)) {
            pass += 1;
            loose_pass += 1;
            continue;
        }
        const g = try softBreaks(a, try stripTag(got, a));
        const w = try softBreaks(a, try stripTag(want_html, a));
        if (std.mem.eql(u8, g, w)) {
            loose_pass += 1;
        } else {
            try failed.append(a, ex.n);
            if (failed.items.len <= show_failures) std.debug.print("--- {d} {s}\n{s}\n-- got\n{s}\n-- want\n{s}\n", .{ ex.n, ex.section, ex.md, got, ex.html });
        }
    }
    std.debug.print("\nspec: {d}/{d} exact, {d}/{d} ignoring inline markup\nfailing: {any}\n", .{ pass, parsed.len, loose_pass, parsed.len, failed.items });
    try testing.expect(pass >= 227 and loose_pass >= 239);
}

const link_floor = 144;

// Examples where GitHub's renderer (checked with its markdown API) differs from the spec text:
// it removes raw HTML it does not allow, and the autolink extension links bare URLs and emails.
const github_html = [_]struct { n: u32, html: []const u8 }{
    .{ .n = 170, .html = "<p>[foo]: (baz)</p>\n<p>[foo]</p>\n" },
    .{ .n = 500, .html = "<p>[link]()</p>\n" },
    .{ .n = 532, .html = "<p>[foo </p>\n" },
    .{ .n = 544, .html = "<p>[foo </p>\n" },
    .{ .n = 616, .html = "<p>&lt; <a href=\"http://foo.bar\">http://foo.bar</a> &gt;</p>\n" },
    .{ .n = 619, .html = "<p><a href=\"http://example.com\">http://example.com</a></p>\n" },
    .{ .n = 620, .html = "<p><a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a></p>\n" },
};

fn oneLine(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    std.mem.replaceScalar(u8, out, '\n', ' ');
    return out;
}

test "spec examples for links, definitions and autolinks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var passed: u32 = 0;
    var total: u32 = 0;
    var failed: std.ArrayList(u32) = .empty;
    var rest: []const u8 = @embedFile("spec_links.txt");
    while (std.mem.indexOf(u8, rest, "@@EX ")) |ex| {
        const head_end = std.mem.indexOfScalar(u8, rest[ex..], '\n').? + ex;
        var head = std.mem.tokenizeScalar(u8, rest[ex + 5 .. head_end], ' ');
        const number = try std.fmt.parseInt(u32, head.next().?, 10);
        const mid = std.mem.indexOfPos(u8, rest, head_end, "@@HTML\n").?;
        const end = std.mem.indexOfPos(u8, rest, mid, "@@END\n").?;
        const markdown = rest[head_end + 1 .. mid];
        const expected = rest[mid + 7 .. end];
        rest = rest[end + 5 ..];

        var doc = try md.parse(testing.allocator, markdown);
        defer doc.deinit();
        const got = try oneLine(a, try toHtml(a, doc));
        var want = expected;
        for (github_html) |g| if (g.n == number) {
            want = g.html;
        };
        total += 1;
        if (std.mem.eql(u8, got, try oneLine(a, want))) passed += 1 else {
            try failed.append(a, number);
            if (show_failures > 1) std.debug.print("--- {d}\n{s}-- got\n{s}-- want\n{s}", .{ number, markdown, got, expected });
        }
    }
    if (show_failures > 0) std.debug.print("\nlink spec: {d}/{d}\nfailing: {any}\n", .{ passed, total, failed.items });
    try testing.expect(passed >= link_floor);
}
