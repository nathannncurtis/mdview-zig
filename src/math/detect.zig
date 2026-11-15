const std = @import("std");
const Allocator = std.mem.Allocator;

/// A run of the paragraph's text after Markdown inline parsing. `scan` is false inside emphasis, links and images, where GitHub finds no math.
pub const Seg = struct { start: u32, end: u32, code: bool = false, scan: bool = true };

/// Math found in the text: `start..end` is replaced by the formula, `src` is the TeX, `display` is `$$...$$` set in the line.
pub const Found = struct { start: u32, end: u32, src: []const u8, display: bool };

fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn openerAllowed(t: []const u8, i: usize) bool {
    return i == 0 or space(t[i - 1]) or t[i - 1] == '(';
}

fn closerAllowed(t: []const u8, close: usize, len: usize) bool {
    const after = close + len;
    return after >= t.len or !word(t[after]);
}

/// One `$...$` or `$$...$$` in `t` at or after `from`. A `$` just after a closer is no opener, except at `from` when `fresh`.
fn nextPlain(t: []const u8, from: usize, fresh: bool) ?struct { open: usize, close: usize, len: usize } {
    var i = from;
    while (i < t.len) : (i += 1) {
        if (t[i] != '$' or !(openerAllowed(t, i) or (fresh and i == from))) continue;
        const len: usize = if (i + 1 < t.len and t[i + 1] == '$') 2 else 1;
        const body = i + len;
        if (body >= t.len or space(t[body])) continue;
        const close = std.mem.indexOfScalarPos(u8, t, body, '$') orelse continue;
        if (close == body or space(t[close - 1])) continue;
        if (len == 2 and !(close + 1 < t.len and t[close + 1] == '$')) continue;
        if (!closerAllowed(t, close, len)) continue;
        return .{ .open = i, .close = close, .len = len };
    }
    return null;
}

/// The math in `text`, sorted by position. A text run holds plain math only inside itself; `$` + code span + `$` is the backtick form.
pub fn inlineSpans(a: Allocator, text: []const u8, segs: []const Seg) Allocator.Error![]Found {
    var out: std.ArrayList(Found) = .empty;
    var carry: ?u32 = null;
    for (segs, 0..) |s, i| {
        if (s.code or !s.scan or s.end <= s.start) continue;
        const t = text[s.start..s.end];
        var at: usize = 0;
        var fresh = false;
        if (carry) |r| {
            at = r - s.start;
            fresh = true;
            carry = null;
        }
        while (nextPlain(t, at, fresh)) |m| {
            fresh = false;
            try out.append(a, .{ .start = s.start + @as(u32, @intCast(m.open)), .end = s.start + @as(u32, @intCast(m.close + m.len)), .src = t[m.open + m.len .. m.close], .display = m.len == 2 });
            at = m.close + m.len;
        }
        if (i + 2 >= segs.len or t[t.len - 1] != '$') continue;
        const code = segs[i + 1];
        const after = segs[i + 2];
        if (!code.code or code.end <= code.start or code.start != s.end) continue;
        if (after.code or !after.scan or after.start != code.end or after.end <= after.start or text[after.start] != '$') continue;
        const open_at = s.end - 1;
        if (out.items.len > 0 and out.items[out.items.len - 1].end > open_at) continue;
        if (open_at > s.start and !(openerAllowed(t, t.len - 1) or t[t.len - 2] == '$')) continue;
        const next = after.start + 1;
        if (next < after.end and word(text[next])) continue;
        try out.append(a, .{ .start = open_at, .end = next, .src = text[code.start..code.end], .display = false });
        carry = next;
    }
    return out.toOwnedSlice(a);
}

/// The TeX of a paragraph that is exactly `$$...$$` (also over several lines), or null.
pub fn displayBlock(para: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, para, " \t\r\n");
    if (t.len < 5 or !std.mem.startsWith(u8, t, "$$") or !std.mem.endsWith(u8, t, "$$")) return null;
    const body = std.mem.trim(u8, t[2 .. t.len - 2], " \t\r\n");
    if (body.len == 0 or std.mem.indexOf(u8, body, "$$") != null) return null;
    return body;
}

const testing = std.testing;

fn one(text: []const u8) !?Found {
    const segs = [_]Seg{.{ .start = 0, .end = @intCast(text.len) }};
    const got = try inlineSpans(testing.allocator, text, &segs);
    defer testing.allocator.free(got);
    if (got.len == 0) return null;
    try testing.expectEqual(@as(usize, 1), got.len);
    return got[0];
}

fn expectMath(text: []const u8, src: []const u8) !void {
    const m = (try one(text)) orelse return error.TestExpectedMath;
    try testing.expectEqualStrings(src, m.src);
}

fn expectNone(text: []const u8) !void {
    const segs = [_]Seg{.{ .start = 0, .end = @intCast(text.len) }};
    const got = try inlineSpans(testing.allocator, text, &segs);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "inline dollars" {
    try expectMath("Inline $x^2$ here", "x^2");
    try expectNone("Costs $5 and $10 each.");
    try expectMath("Costs $5 and then x$ y $z.", "5 and then x");
}

test "the opener is preceded by the start, space or an open parenthesis" {
    for ([_][]const u8{ "a$x$", "5$x$", "\"$x$\"", "-$x$", "[$x$", "{$x$", "'$x$", ",$x$", "/$x$", "=$x$" }) |t| try expectNone(t);
    try expectMath("$x$", "x");
    try expectMath("a ($x$)", "x");
    try expectMath("a\t$x$", "x");
}

test "the closer is followed by the end, space, punctuation or a dollar" {
    for ([_][]const u8{ "$x$,", "$x$:", "$x$-", "$x$(", "($x$)", "$x$.", "$x$!", "$x$;", "$x$?", "$x$'s", "$x$\"", "$x$]", "$x$/", "$x$+", "$x$=" }) |t| try expectMath(t, "x");
    try expectMath("$x$$", "x");
    for ([_][]const u8{ "$x$y", "$x$5", "$x$_" }) |t| try expectNone(t);
}

test "no space just inside either delimiter" {
    for ([_][]const u8{ "$ x $", "$x $", "$ x$", "$ $" }) |t| try expectNone(t);
}

test "double dollars inside a line are display-style math" {
    const m = (try one("Text $$y = mx + b$$ there")) orelse return error.TestExpectedMath;
    try testing.expect(m.display);
    try testing.expectEqualStrings("y = mx + b", m.src);
    for ([_][]const u8{ "text $$ a $$ text", "$$$$", "$$ $$", "$$x$", "$$a$b$$ c" }) |t| try expectNone(t);
}

test "content never holds a dollar, so an escaped dollar breaks the match" {
    for ([_][]const u8{ "$a$b$ c", "$$5$", "$a$b$" }) |t| try expectNone(t);
}

test "a dollar after a match is not an opener" {
    const text = "$x$$y$";
    const segs = [_]Seg{.{ .start = 0, .end = text.len }};
    const got = try inlineSpans(testing.allocator, text, &segs);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("x", got[0].src);
    const t2 = "a $x$$$y$$";
    const s2 = [_]Seg{.{ .start = 0, .end = t2.len }};
    const g2 = try inlineSpans(testing.allocator, t2, &s2);
    defer testing.allocator.free(g2);
    try testing.expectEqual(@as(usize, 1), g2.len);
    const t3 = "a $a$-$b$";
    const s3 = [_]Seg{.{ .start = 0, .end = t3.len }};
    const g3 = try inlineSpans(testing.allocator, t3, &s3);
    defer testing.allocator.free(g3);
    try testing.expectEqual(@as(usize, 1), g3.len);
}

test "backslash escapes were resolved before detection" {
    try expectMath("$x$", "x");
    try expectNone("$$5$");
    try expectMath("$a{b}$", "a{b}");
    try expectMath("$x_y$", "x_y");
    try expectMath("$a_*b$", "a_*b");
}

test "emphasis splits the text so a formula cannot cross it" {
    const text = "$a_1 emph b$";
    const segs = [_]Seg{ .{ .start = 0, .end = 5 }, .{ .start = 5, .end = 9, .scan = false }, .{ .start = 9, .end = text.len } };
    const got = try inlineSpans(testing.allocator, text, &segs);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "no math inside emphasis or links, but inside strong" {
    const text = "$a$";
    const blocked = [_]Seg{.{ .start = 0, .end = 3, .scan = false }};
    const none = try inlineSpans(testing.allocator, text, &blocked);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    const open = [_]Seg{.{ .start = 0, .end = 3 }};
    const some = try inlineSpans(testing.allocator, text, &open);
    defer testing.allocator.free(some);
    try testing.expectEqual(@as(usize, 1), some.len);
}

fn backtick(text: []const u8, segs: []const Seg) ![]Found {
    return inlineSpans(testing.allocator, text, segs);
}

test "the backtick form takes the code text verbatim" {
    // "a $" + code "a_b*c*" + "$ b"
    const text = "a $a_b*c*$ b";
    const segs = [_]Seg{ .{ .start = 0, .end = 3 }, .{ .start = 3, .end = 9, .code = true }, .{ .start = 9, .end = text.len } };
    const got = try backtick(text, &segs);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("a_b*c*", got[0].src);
    try testing.expectEqual(@as(u32, 2), got[0].start);
    try testing.expectEqual(@as(u32, 10), got[0].end);
    try testing.expect(!got[0].display);
}

test "the backtick form follows the adjacency rules" {
    {
        const text = "$x$y";
        const segs = [_]Seg{ .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 2, .code = true }, .{ .start = 2, .end = 4 } };
        const got = try backtick(text, &segs);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    {
        const text = "y$x$";
        const segs = [_]Seg{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 3, .code = true }, .{ .start = 3, .end = 4 } };
        const got = try backtick(text, &segs);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    {
        const text = "($x$)";
        const segs = [_]Seg{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 3, .code = true }, .{ .start = 3, .end = 5 } };
        const got = try backtick(text, &segs);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualStrings("x", got[0].src);
    }
    {
        const text = "$x y$";
        const segs = [_]Seg{ .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 2, .code = true }, .{ .start = 2, .end = 5 } };
        const got = try backtick(text, &segs);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
}

test "the backtick form after a dollar, and a plain formula after it" {
    {
        // "a $$" + code "x" + "$$"
        const text = "a $$x$$";
        const segs = [_]Seg{ .{ .start = 0, .end = 4 }, .{ .start = 4, .end = 5, .code = true }, .{ .start = 5, .end = 7 } };
        const got = try backtick(text, &segs);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(@as(u32, 3), got[0].start);
        try testing.expectEqual(@as(u32, 6), got[0].end);
    }
    {
        // "a $" + code "x" + "$$y$"
        const text = "a $x$$y$";
        const segs = [_]Seg{ .{ .start = 0, .end = 3 }, .{ .start = 3, .end = 4, .code = true }, .{ .start = 4, .end = 8 } };
        const got = try backtick(text, &segs);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqualStrings("x", got[0].src);
        try testing.expectEqualStrings("y", got[1].src);
    }
}

test "a paragraph that is exactly double dollars is display math" {
    try testing.expectEqualStrings("x", displayBlock("$$x$$").?);
    try testing.expectEqualStrings("x", displayBlock("$$\nx\n$$").?);
    try testing.expectEqualStrings("x", displayBlock("$$ x $$").?);
    try testing.expectEqualStrings("x\ny", displayBlock("$$\nx\ny\n$$\n").?);
    try testing.expect(displayBlock("$$x$$ trailing") == null);
    try testing.expect(displayBlock("lead $$x$$") == null);
    try testing.expect(displayBlock("$$$$") == null);
    try testing.expect(displayBlock("$$ $$") == null);
    try testing.expect(displayBlock("$$a$$b$$c$$") == null);
    try testing.expect(displayBlock("$x$") == null);
}
