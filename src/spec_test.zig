const std = @import("std");
const md = @import("markdown.zig");
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
                try escape(&out, a, b.content.text, true);
                if (!tight) try out.appendSlice(a, "</p>\n");
            },
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                const n = @intFromEnum(b.kind) - @intFromEnum(md.BlockKind.h1) + 1;
                try cr(&out, a);
                try out.print(a, "<h{d}>", .{n});
                try escape(&out, a, b.content.text, true);
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
