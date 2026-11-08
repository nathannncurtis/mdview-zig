const std = @import("std");
const blocks = @import("blocks.zig");
const inline_parser = @import("inline.zig");
const html = @import("html.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

const show_failures = 0;

const Case = struct { n: u32, section: []const u8, md: []const u8, html: []const u8, github: []const u8 };

fn escape(out: *List, a: Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

fn stripLeading(a: Allocator, s: []const u8) ![]const u8 {
    var out: List = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s, " \t\n"), '\n');
    while (lines.next()) |l| {
        if (out.items.len > 0) try out.append(a, '\n');
        try out.appendSlice(a, std.mem.trimStart(u8, l, " \t"));
    }
    return out.items;
}

const Ctx = struct { a: Allocator, t: *const blocks.Tree, filter: bool, out: List = .empty };

fn raw(c: *Ctx, s: []const u8) ![]const u8 {
    return if (c.filter) html.tagfilter(c.a, s) else s;
}

fn inlineHtml(c: *Ctx, src: []const u8) !void {
    const parsed = try inline_parser.parse(c.a, try stripLeading(c.a, src), &.{});
    const text = parsed.text;
    var pos: usize = 0;
    for (parsed.events) |e| {
        try escape(&c.out, c.a, text[pos..e.pos]);
        pos = e.pos;
        switch (e.tag) {
            .html => try c.out.appendSlice(c.a, try raw(c, e.raw)),
            .soft => {
                try c.out.append(c.a, '\n');
                pos += 1;
            },
            .hard => {
                try c.out.appendSlice(c.a, "<br />\n");
                pos += 1;
            },
            .open, .close => {
                const name = switch (e.kind) {
                    .em => "em",
                    .strong => "strong",
                    .code => "code",
                    .strike => "del",
                    else => "span",
                };
                try c.out.print(c.a, "<{s}{s}>", .{ if (e.tag == .close) "/" else "", name });
            },
        }
    }
    try escape(&c.out, c.a, text[pos..]);
}

fn cr(c: *Ctx) !void {
    if (c.out.items.len > 0 and c.out.items[c.out.items.len - 1] != '\n') try c.out.append(c.a, '\n');
}

fn renderNode(c: *Ctx, idx: u32, tight: bool) Allocator.Error!void {
    const n = c.t.nodes.items[idx];
    const a = c.a;
    switch (n.kind) {
        .document => try renderChildren(c, n, false),
        .paragraph => {
            if (!tight) try c.out.appendSlice(a, "<p>");
            try inlineHtml(c, n.content.items);
            if (!tight) try c.out.appendSlice(a, "</p>\n");
        },
        .heading => {
            try c.out.print(a, "<h{d}>", .{n.level});
            try inlineHtml(c, n.content.items);
            try c.out.print(a, "</h{d}>\n", .{n.level});
        },
        .thematic => try c.out.appendSlice(a, "<hr />\n"),
        .code => {
            var body = n.content.items;
            if (n.fenced) body = body[@min((std.mem.indexOfScalar(u8, body, 0) orelse 0) + 1, body.len)..];
            try c.out.appendSlice(a, "<pre><code>");
            try escape(&c.out, a, body);
            try c.out.appendSlice(a, "</code></pre>\n");
        },
        .html => try c.out.appendSlice(a, try raw(c, n.content.items)),
        .quote => {
            try c.out.appendSlice(a, "<blockquote>\n");
            try renderChildren(c, n, false);
            try c.out.appendSlice(a, "</blockquote>\n");
        },
        .list => {
            try c.out.appendSlice(a, if (n.ordered) "<ol>\n" else "<ul>\n");
            var k = n.first;
            while (k != blocks.none) : (k = c.t.nodes.items[k].next) try renderNode(c, k, n.tight);
            try c.out.appendSlice(a, if (n.ordered) "</ol>\n" else "</ul>\n");
        },
        .item => {
            try c.out.appendSlice(a, "<li>");
            const first = if (n.first == blocks.none) blocks.Kind.paragraph else c.t.nodes.items[n.first].kind;
            if (!tight or first != .paragraph) try c.out.append(a, '\n');
            try renderChildren(c, n, tight);
            if (!tight or (n.last != blocks.none and c.t.nodes.items[n.last].kind != .paragraph)) try cr(c);
            try c.out.appendSlice(a, "</li>\n");
        },
        .footnote => {},
    }
}

fn renderChildren(c: *Ctx, n: blocks.Node, tight: bool) Allocator.Error!void {
    var k = n.first;
    while (k != blocks.none) : (k = c.t.nodes.items[k].next) try renderNode(c, k, tight);
}

fn render(a: Allocator, markdown: []const u8, filter: bool) ![]const u8 {
    const tree = try blocks.build(a, markdown);
    var c: Ctx = .{ .a = a, .t = &tree, .filter = filter };
    try renderNode(&c, 0, false);
    return c.out.items;
}

test "spec examples for HTML blocks, raw HTML and the tagfilter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]const Case, a, @embedFile("spec_html.json"), .{});
    var failed: std.ArrayList(u32) = .empty;
    for (cases) |c| {
        const got = try render(a, c.md, std.mem.startsWith(u8, c.section, "Disallowed"));
        if (!std.mem.eql(u8, got, c.html)) {
            try failed.append(a, c.n);
            if (show_failures > 0) std.debug.print("--- {d}\n{s}\n-- got\n{s}\n-- want\n{s}\n", .{ c.n, c.md, got, c.html });
        }
    }
    std.debug.print("\nspec html boundaries: {d}/{d}\nfailing: {any}\n", .{ cases.len - failed.items.len, cases.len, failed.items });
    try testing.expectEqualSlices(u32, &.{}, failed.items);
}
