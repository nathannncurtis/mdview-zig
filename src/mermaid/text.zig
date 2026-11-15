const std = @import("std");
const Allocator = std.mem.Allocator;
const segment = @import("segment.zig");

pub const default_family = "\"trebuchet ms\", verdana, arial, sans-serif";

pub const Font = struct {
    family: []const u8 = default_family,
    size: f32 = 16,
    weight: u16 = 400,
    italic: bool = false,
};

pub const Size = struct { w: f32, h: f32 };

/// Text measurement for layout. The fonts lane supplies the real implementation; `stub` stands in until then.
pub const Measurer = struct {
    ctx: ?*anyopaque = null,
    measure_fn: *const fn (ctx: ?*anyopaque, text: []const u8, font: Font) Size,

    pub fn measure(m: Measurer, text: []const u8, font: Font) Size {
        return m.measure_fn(m.ctx, text, font);
    }
};

fn stubMeasure(_: ?*anyopaque, text: []const u8, font: Font) Size {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    return .{ .w = @as(f32, @floatFromInt(n)) * font.size * 0.5, .h = font.size * 1.15 };
}

pub const stub: Measurer = .{ .measure_fn = stubMeasure };

pub const WordKind = enum { normal, strong, em };
pub const Word = struct { content: []const u8, kind: WordKind = .normal };
pub const MarkdownLine = []const Word;

pub const CheckFit = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, line: MarkdownLine) bool,

    fn call(c: CheckFit, line: MarkdownLine) bool {
        return c.f(c.ctx, line);
    }
};

/// Characters as `Intl.Segmenter` grapheme clusters.
pub fn splitTextToChars(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    return segment.graphemes(a, text);
}

/// Word segments as `Intl.Segmenter` with word granularity (UAX #29, no dictionary scripts).
pub fn splitLineToWords(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    return segment.words(a, text);
}

fn join(a: Allocator, chars: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(a, u8, chars);
}

/// splitText.ts `splitWordToFitWidth`: the longest prefix that fits and the rest.
pub fn splitWordToFitWidth(a: Allocator, check: CheckFit, word: Word) Allocator.Error![2]Word {
    const chars = try splitTextToChars(a, word.content);
    var used: usize = 0;
    while (used < chars.len) {
        const candidate = try join(a, chars[0 .. used + 1]);
        if (!check.call(&.{.{ .content = candidate, .kind = word.kind }})) break;
        used += 1;
    }
    if (used == 0 and chars.len > 0) used = 1;
    return .{
        .{ .content = try join(a, chars[0..used]), .kind = word.kind },
        .{ .content = try join(a, chars[used..]), .kind = word.kind },
    };
}

/// splitText.ts `splitLineToFitWidth`: breaks one line of words into lines that satisfy `check`.
pub fn splitLineToFitWidth(a: Allocator, line: MarkdownLine, check: CheckFit) (Allocator.Error || error{NewlineInLine})!MarkdownLines {
    for (line) |w| if (std.mem.indexOfScalar(u8, w.content, '\n') != null) return error.NewlineInLine;
    var stack: std.ArrayList(Word) = .empty;
    var k = line.len;
    while (k > 0) {
        k -= 1;
        try stack.append(a, line[k]);
    }
    var lines: std.ArrayList(MarkdownLine) = .empty;
    var new_line: std.ArrayList(Word) = .empty;
    while (true) {
        if (stack.items.len == 0) {
            if (new_line.items.len > 0) try lines.append(a, new_line.items);
            return lines.items;
        }
        var joiner = false;
        if (std.mem.eql(u8, stack.items[stack.items.len - 1].content, " ")) {
            joiner = true;
            _ = stack.pop();
        }
        const next = stack.pop() orelse Word{ .content = " " };
        var with_next: std.ArrayList(Word) = .empty;
        try with_next.appendSlice(a, new_line.items);
        if (joiner) try with_next.append(a, .{ .content = " " });
        try with_next.append(a, next);
        if (check.call(with_next.items)) {
            new_line = with_next;
            continue;
        }
        if (new_line.items.len > 0) {
            try lines.append(a, new_line.items);
            try stack.append(a, next);
        } else if (next.content.len > 0) {
            const parts = try splitWordToFitWidth(a, check, next);
            const single = try a.alloc(Word, 1);
            single[0] = parts[0];
            try lines.append(a, single);
            if (parts[1].content.len > 0) try stack.append(a, parts[1]);
        }
        new_line = .empty;
    }
}

pub const MarkdownLines = []const MarkdownLine;

pub const Line = struct { text: []const u8, w: f32 };

pub const Label = struct {
    lines: []const Line,
    w: f32,
    h: f32,
};

pub const line_height_factor: f32 = 1.5;

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " ");
}

/// The box Chrome gives an HTML label (`display: table-cell; white-space: nowrap; line-height: 1.5; max-width`),
/// and the lines it breaks into once it reaches `max_width` and switches to `break-spaces`.
pub fn htmlLabel(a: Allocator, m: Measurer, text: []const u8, font: Font, max_width: f32) Allocator.Error!Label {
    var natural: f32 = 0;
    var src_lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        try src_lines.append(a, l);
        natural = @max(natural, m.measure(l, font).w);
    }
    var lines: std.ArrayList(Line) = .empty;
    const wrap = natural >= max_width;
    if (!wrap) {
        for (src_lines.items) |l| try lines.append(a, .{ .text = l, .w = m.measure(l, font).w });
    } else {
        for (src_lines.items) |l| {
            var cur: std.ArrayList(u8) = .empty;
            var cur_w: f32 = 0;
            var pos: usize = 0;
            while (pos < l.len) {
                var end = pos;
                while (end < l.len and l[end] != ' ') end += 1;
                while (end < l.len and l[end] == ' ') end += 1;
                const atom = l[pos..end];
                const atom_w = m.measure(atom, font).w;
                if (cur.items.len > 0 and cur_w + atom_w > max_width) {
                    const shown = trimSpaces(cur.items);
                    try lines.append(a, .{ .text = shown, .w = m.measure(shown, font).w });
                    cur = .empty;
                    cur_w = 0;
                }
                try cur.appendSlice(a, atom);
                cur_w += atom_w;
                pos = end;
            }
            const shown = trimSpaces(cur.items);
            try lines.append(a, .{ .text = shown, .w = m.measure(shown, font).w });
        }
    }
    const n: f32 = @floatFromInt(lines.items.len);
    return .{ .lines = lines.items, .w = if (wrap) max_width else natural, .h = n * font.size * line_height_factor };
}

const TestCtx = struct {
    limit: f32,
    fn fits(ctx: *anyopaque, line: MarkdownLine) bool {
        const self: *TestCtx = @ptrCast(@alignCast(ctx));
        var n: usize = 0;
        for (line) |w| n += w.content.len;
        return @as(f32, @floatFromInt(n)) <= self.limit;
    }
};

test "splitLineToFitWidth wraps at spaces and splits long words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: TestCtx = .{ .limit = 10 };
    const check: CheckFit = .{ .ctx = &ctx, .f = TestCtx.fits };
    const words = try splitLineToWords(a, "hello big world");
    var ws: std.ArrayList(Word) = .empty;
    for (words) |w| try ws.append(a, .{ .content = w });
    const lines = try splitLineToFitWidth(a, ws.items, check);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hello", lines[0][0].content);
    try std.testing.expectEqualStrings("world", lines[1][0].content);
    const long = try splitLineToFitWidth(a, &.{.{ .content = "abcdefghijklmnop" }}, check);
    try std.testing.expectEqual(@as(usize, 2), long.len);
    try std.testing.expectEqualStrings("abcdefghij", long[0][0].content);
    try std.testing.expectEqualStrings("klmnop", long[1][0].content);
}

test "html label width and wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const short = try htmlLabel(a, stub, "Start", .{}, 200);
    try std.testing.expectEqual(@as(f32, 40), short.w);
    try std.testing.expectEqual(@as(f32, 24), short.h);
    const long = try htmlLabel(a, stub, "The quick brown fox jumps over the lazy dog again and again", .{}, 200);
    try std.testing.expectEqual(@as(f32, 200), long.w);
    try std.testing.expect(long.lines.len > 1);
    try std.testing.expectEqual(@as(f32, 24) * @as(f32, @floatFromInt(long.lines.len)), long.h);
}

test "graphemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chars = try splitTextToChars(arena.allocator(), "e\u{301}x\u{1F468}\u{200D}\u{1F469}");
    try std.testing.expectEqual(@as(usize, 3), chars.len);
}
