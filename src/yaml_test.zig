const std = @import("std");
const yaml = @import("yaml.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Case = struct { src: []const u8, want: []const u8 };

fn esc(w: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.appendSlice(a, "&amp;"),
        '<' => try w.appendSlice(a, "&lt;"),
        '>' => try w.appendSlice(a, "&gt;"),
        else => try w.append(a, c),
    };
}

fn truthy(v: yaml.Value) bool {
    return switch (v) {
        .scalar => |s| !s.falsy,
        else => true,
    };
}

fn cell(w: *std.ArrayList(u8), a: Allocator, tag: []const u8, v: yaml.Value) Allocator.Error!void {
    try w.print(a, "<{s}>", .{tag});
    try render(w, a, v, false);
    try w.print(a, "</{s}>", .{tag});
}

fn render(w: *std.ArrayList(u8), a: Allocator, v: yaml.Value, top: bool) Allocator.Error!void {
    switch (v) {
        .scalar => |s| try esc(w, a, s.text),
        .seq => |items| {
            try w.appendSlice(a, "<table><tbody>");
            var shown = false;
            for (items) |it| shown = shown or truthy(it);
            if (shown) {
                try w.appendSlice(a, "<tr>");
                for (items) |it| try cell(w, a, "td", it);
                try w.appendSlice(a, "</tr>");
            }
            try w.appendSlice(a, "</tbody></table>");
        },
        .map => |pairs| {
            if (top) {
                try w.appendSlice(a, "<table><tbody>");
                for (pairs) |p| {
                    try w.appendSlice(a, "<tr><th>");
                    try esc(w, a, p.key);
                    try w.appendSlice(a, "</th>");
                    try cell(w, a, "td", p.value);
                    try w.appendSlice(a, "</tr>");
                }
                try w.appendSlice(a, "</tbody></table>");
            } else if (pairs.len == 0) {
                try w.appendSlice(a, "<table><tbody></tbody></table>");
            } else {
                try w.appendSlice(a, "<table><thead><tr>");
                var shown = false;
                for (pairs) |p| {
                    try w.appendSlice(a, "<th>");
                    try esc(w, a, p.key);
                    try w.appendSlice(a, "</th>");
                    shown = shown or truthy(p.value);
                }
                try w.appendSlice(a, "</tr></thead><tbody>");
                if (shown) {
                    try w.appendSlice(a, "<tr>");
                    for (pairs) |p| try cell(w, a, "td", p.value);
                    try w.appendSlice(a, "</tr>");
                }
                try w.appendSlice(a, "</tbody></table>");
            }
        },
    }
}

fn squeeze(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] == 0xA0) {
            space = true;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\n' or c == '\t') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0 and out.items[out.items.len - 1] != '>' and c != '<') try out.append(a, ' ');
        space = false;
        try out.append(a, c);
    }
    return out.items;
}

test "front matter YAML matches GitHub's rendering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]const Case, a, @embedFile("yaml_cases.json"), .{});
    var failed: usize = 0;
    for (cases) |c| {
        const src = try std.fmt.allocPrint(a, "{s}\n", .{c.src});
        var out: std.ArrayList(u8) = .empty;
        switch (try yaml.parse(a, src)) {
            .ok => |v| try render(&out, a, v, true),
            .err => |e| try out.print(a, "ERR {s}", .{e.message}),
            .other => try out.appendSlice(a, "OTHER"),
        }
        const got = try squeeze(a, out.items);
        const want = try squeeze(a, c.want);
        if (!std.mem.eql(u8, got, want)) {
            failed += 1;
            std.debug.print("\nyaml case differs: {any}\n  want {s}\n  got  {s}\n", .{ c.src, want, got });
        }
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

test "a later duplicate key wins and keeps the first position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try yaml.parse(arena.allocator(), "a: 1\nb: 2\na: 3\n");
    const pairs = result.ok.map;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("a", pairs[0].key);
    try testing.expectEqualStrings("3", pairs[0].value.scalar.text);
}

test "nesting deeper than 1000 levels is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendNTimes(a, '[', 5000);
    try src.appendNTimes(a, ']', 5000);
    try src.append(a, '\n');
    try testing.expect((try yaml.parse(a, src.items)) == .err);
}
