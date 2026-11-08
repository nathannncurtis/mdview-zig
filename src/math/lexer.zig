const std = @import("std");

pub const Kind = enum { cs, char, open, close, sup, sub, amp, hash, tilde, dollar, space, eof };

pub const Token = struct {
    kind: Kind,
    /// Source text of the token; for `.cs` it starts with the backslash.
    text: []const u8 = "",
    cp: u21 = 0,

    pub fn name(t: Token) []const u8 {
        return t.text[1..];
    }

    pub fn isCs(t: Token, n: []const u8) bool {
        return t.kind == .cs and std.mem.eql(u8, t.text[1..], n);
    }

    pub fn isChar(t: Token, c: u21) bool {
        return t.kind == .char and t.cp == c;
    }
};

pub const eof: Token = .{ .kind = .eof };

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn decode(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + n > s.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Tokenizes `src`; stops with `error.TooManyTokens` past `max_tokens`.
pub fn tokenize(a: std.mem.Allocator, src: []const u8, max_tokens: usize) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        if (out.items.len >= max_tokens) return error.TooManyTokens;
        const c = src[i];
        const start = i;
        if (isSpace(c)) {
            while (i < src.len and isSpace(src[i])) i += 1;
            try out.append(a, .{ .kind = .space, .text = " ", .cp = ' ' });
            continue;
        }
        switch (c) {
            '%' => {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            },
            '{' => try out.append(a, .{ .kind = .open, .text = src[i .. i + 1], .cp = '{' }),
            '}' => try out.append(a, .{ .kind = .close, .text = src[i .. i + 1], .cp = '}' }),
            '^' => try out.append(a, .{ .kind = .sup, .text = src[i .. i + 1], .cp = '^' }),
            '_' => try out.append(a, .{ .kind = .sub, .text = src[i .. i + 1], .cp = '_' }),
            '&' => try out.append(a, .{ .kind = .amp, .text = src[i .. i + 1], .cp = '&' }),
            '#' => try out.append(a, .{ .kind = .hash, .text = src[i .. i + 1], .cp = '#' }),
            '~' => try out.append(a, .{ .kind = .tilde, .text = src[i .. i + 1], .cp = '~' }),
            '$' => try out.append(a, .{ .kind = .dollar, .text = src[i .. i + 1], .cp = '$' }),
            '\\' => {
                i += 1;
                if (i >= src.len) {
                    try out.append(a, .{ .kind = .cs, .text = "\\ " });
                    continue;
                }
                if (isLetter(src[i])) {
                    while (i < src.len and isLetter(src[i])) i += 1;
                    if (std.mem.eql(u8, src[start..i], "\\verb")) {
                        try out.append(a, .{ .kind = .cs, .text = src[start..i] });
                        i = try verbLiteral(a, &out, src, i);
                        continue;
                    }
                } else {
                    i += decode(src, i).len;
                }
                try out.append(a, .{ .kind = .cs, .text = src[start..i] });
                continue;
            },
            else => {
                const d = decode(src, i);
                i += d.len;
                try out.append(a, .{ .kind = .char, .text = src[start..i], .cp = d.cp });
                continue;
            },
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// After \verb: the delimited text is literal, so `%` and runs of spaces survive.
fn verbLiteral(a: std.mem.Allocator, out: *std.ArrayList(Token), src: []const u8, from: usize) !usize {
    var i = from;
    while (i < src.len and isSpace(src[i])) i += 1;
    if (i >= src.len) return from;
    const d = decode(src, i);
    const delim = src[i .. i + d.len];
    const close = std.mem.indexOfPos(u8, src, i + d.len, delim) orelse return from;
    var j = i;
    while (j < close + d.len) {
        const c = decode(src, j);
        try out.append(a, .{ .kind = .char, .text = src[j .. j + c.len], .cp = c.cp });
        j += c.len;
    }
    return j;
}

test "tokens" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "\\frac{a}{b} % c\n x^2\\\\", 100);
    defer a.free(t);
    const kinds = [_]Kind{ .cs, .open, .char, .close, .open, .char, .close, .space, .space, .char, .sup, .char, .cs };
    try std.testing.expectEqual(kinds.len, t.len);
    for (kinds, t) |k, tok| try std.testing.expectEqual(k, tok.kind);
    try std.testing.expectEqualStrings("\\\\", t[12].text);
}

test "invalid utf8 and limits" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "\xff\xc3\\", 100);
    defer a.free(t);
    try std.testing.expectEqual(@as(usize, 3), t.len);
    try std.testing.expectEqual(@as(u21, 0xfffd), t[0].cp);
    try std.testing.expectError(error.TooManyTokens, tokenize(a, "aaaa", 3));
}
