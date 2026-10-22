const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mark = struct { index: usize = 0, line: usize = 0, column: usize = 0 };

pub const ScalarStyle = enum { plain, single, double, literal, folded };

pub const TokenKind = enum {
    stream_start,
    stream_end,
    version_directive,
    tag_directive,
    document_start,
    document_end,
    block_sequence_start,
    block_mapping_start,
    block_end,
    flow_sequence_start,
    flow_sequence_end,
    flow_mapping_start,
    flow_mapping_end,
    block_entry,
    flow_entry,
    key,
    value,
    alias,
    anchor,
    tag,
    scalar,
};

pub const Token = struct {
    kind: TokenKind,
    start: Mark = .{},
    end: Mark = .{},
    value: []const u8 = "",
    handle: []const u8 = "",
    style: ScalarStyle = .plain,
    major: u32 = 0,
    minor: u32 = 0,
};

pub const ErrInfo = struct {
    problem: []const u8 = "",
    context: ?[]const u8 = null,
    mark: Mark = .{},
};

pub const Fail = error{ Yaml, OutOfMemory };

const SimpleKey = struct { possible: bool = false, required: bool = false, token_number: usize = 0, mark: Mark = .{} };

pub const Scanner = struct {
    a: Allocator,
    src: []const u8,
    mark: Mark = .{},
    tokens: std.ArrayList(Token) = .empty,
    head: usize = 0,
    tokens_parsed: usize = 0,
    token_available: bool = false,
    stream_start_produced: bool = false,
    stream_end_produced: bool = false,
    indent: i64 = -1,
    indents: std.ArrayList(i64) = .empty,
    simple_key_allowed: bool = false,
    simple_keys: std.ArrayList(SimpleKey) = .empty,
    flow_level: usize = 0,
    err: ErrInfo = .{},

    pub fn fail(s: *Scanner, problem: []const u8, context: ?[]const u8, mark: Mark) Fail {
        s.err = .{ .problem = problem, .context = context, .mark = mark };
        return error.Yaml;
    }

    pub fn peekToken(s: *Scanner) Fail!*Token {
        if (!s.token_available) try s.fetchMoreTokens();
        return &s.tokens.items[s.head];
    }

    pub fn skipToken(s: *Scanner) void {
        s.token_available = false;
        s.tokens_parsed += 1;
        s.stream_end_produced = s.tokens.items[s.head].kind == .stream_end;
        s.head += 1;
    }

    fn ch(s: *const Scanner, off: usize) u8 {
        const i = s.mark.index + off;
        return if (i < s.src.len) s.src[i] else 0;
    }

    fn isZ(s: *const Scanner, off: usize) bool {
        return s.mark.index + off >= s.src.len;
    }

    fn isBlank(s: *const Scanner, off: usize) bool {
        const c = s.ch(off);
        return c == ' ' or c == '\t';
    }

    fn isBreak(s: *const Scanner, off: usize) bool {
        const c = s.ch(off);
        if (c == '\r' or c == '\n') return true;
        if (c == 0xC2 and s.ch(off + 1) == 0x85) return true;
        return c == 0xE2 and s.ch(off + 1) == 0x80 and (s.ch(off + 2) == 0xA8 or s.ch(off + 2) == 0xA9);
    }

    fn isBreakZ(s: *const Scanner, off: usize) bool {
        return s.isBreak(off) or s.isZ(off);
    }

    fn isBlankZ(s: *const Scanner, off: usize) bool {
        return s.isBlank(off) or s.isBreakZ(off);
    }

    fn isAlpha(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn isHex(c: u8) bool {
        return std.ascii.isHex(c);
    }

    fn width(c: u8) usize {
        if (c & 0x80 == 0) return 1;
        if (c & 0xE0 == 0xC0) return 2;
        if (c & 0xF0 == 0xE0) return 3;
        if (c & 0xF8 == 0xF0) return 4;
        return 1;
    }

    fn skip(s: *Scanner) void {
        s.mark.index += width(s.ch(0));
        s.mark.column += 1;
    }

    fn skipLine(s: *Scanner) void {
        if (s.ch(0) == '\r' and s.ch(1) == '\n') {
            s.mark.index += 2;
        } else if (s.isBreak(0)) {
            s.mark.index += width(s.ch(0));
        } else return;
        s.mark.column = 0;
        s.mark.line += 1;
    }

    fn read(s: *Scanner, buf: *std.ArrayList(u8)) Allocator.Error!void {
        const w = width(s.ch(0));
        try buf.appendSlice(s.a, s.src[s.mark.index..@min(s.mark.index + w, s.src.len)]);
        s.mark.index += w;
        s.mark.column += 1;
    }

    fn readLine(s: *Scanner, buf: *std.ArrayList(u8)) Allocator.Error!void {
        if (s.ch(0) == '\r' and s.ch(1) == '\n') {
            try buf.append(s.a, '\n');
            s.mark.index += 2;
        } else if (s.ch(0) == '\r' or s.ch(0) == '\n') {
            try buf.append(s.a, '\n');
            s.mark.index += 1;
        } else if (s.ch(0) == 0xC2 and s.ch(1) == 0x85) {
            try buf.append(s.a, '\n');
            s.mark.index += 2;
        } else if (s.isBreak(0)) {
            try buf.appendSlice(s.a, s.src[s.mark.index..][0..3]);
            s.mark.index += 3;
        } else return;
        s.mark.column = 0;
        s.mark.line += 1;
    }

    fn enqueue(s: *Scanner, t: Token) Allocator.Error!void {
        try s.tokens.append(s.a, t);
    }

    fn fetchMoreTokens(s: *Scanner) Fail!void {
        while (true) {
            var need_more = false;
            if (s.head == s.tokens.items.len) {
                need_more = true;
            } else {
                try s.staleSimpleKeys();
                for (s.simple_keys.items) |k| {
                    if (k.possible and k.token_number == s.tokens_parsed) {
                        need_more = true;
                        break;
                    }
                }
            }
            if (!need_more) break;
            try s.fetchNextToken();
        }
        s.token_available = true;
    }

    fn fetchNextToken(s: *Scanner) Fail!void {
        if (!s.stream_start_produced) return s.fetchStreamStart();
        try s.scanToNextToken();
        try s.staleSimpleKeys();
        try s.unrollIndent(@intCast(s.mark.column));
        if (s.isZ(0)) return s.fetchStreamEnd();
        const c = s.ch(0);
        if (s.mark.column == 0 and c == '%') return s.fetchDirective();
        if (s.mark.column == 0 and c == '-' and s.ch(1) == '-' and s.ch(2) == '-' and s.isBlankZ(3)) return s.fetchDocumentIndicator(.document_start);
        if (s.mark.column == 0 and c == '.' and s.ch(1) == '.' and s.ch(2) == '.' and s.isBlankZ(3)) return s.fetchDocumentIndicator(.document_end);
        if (c == '[') return s.fetchFlowCollectionStart(.flow_sequence_start);
        if (c == '{') return s.fetchFlowCollectionStart(.flow_mapping_start);
        if (c == ']') return s.fetchFlowCollectionEnd(.flow_sequence_end);
        if (c == '}') return s.fetchFlowCollectionEnd(.flow_mapping_end);
        if (c == ',') return s.fetchFlowEntry();
        if (c == '-' and s.isBlankZ(1)) return s.fetchBlockEntry();
        if (c == '?' and (s.flow_level > 0 or s.isBlankZ(1))) return s.fetchKey();
        if (c == ':' and (s.flow_level > 0 or s.isBlankZ(1))) return s.fetchValue();
        if (c == '*') return s.fetchAnchor(.alias);
        if (c == '&') return s.fetchAnchor(.anchor);
        if (c == '!') return s.fetchTag();
        if (c == '|' and s.flow_level == 0) return s.fetchBlockScalar(true);
        if (c == '>' and s.flow_level == 0) return s.fetchBlockScalar(false);
        if (c == '\'') return s.fetchFlowScalar(true);
        if (c == '"') return s.fetchFlowScalar(false);
        const indicator = s.isBlankZ(0) or std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", c) != null;
        if (!indicator or (c == '-' and !s.isBlank(1)) or (s.flow_level == 0 and (c == '?' or c == ':') and !s.isBlankZ(1))) {
            return s.fetchPlainScalar();
        }
        return s.fail("found character that cannot start any token", "while scanning for the next token", s.mark);
    }

    fn staleSimpleKeys(s: *Scanner) Fail!void {
        for (s.simple_keys.items) |*k| {
            if (k.possible and (k.mark.line < s.mark.line or k.mark.index + 1024 < s.mark.index)) {
                if (k.required) return s.fail("could not find expected ':'", "while scanning a simple key", k.mark);
                k.possible = false;
            }
        }
    }

    fn saveSimpleKey(s: *Scanner) Fail!void {
        const required = s.flow_level == 0 and s.indent == @as(i64, @intCast(s.mark.column));
        if (s.simple_key_allowed) {
            const key: SimpleKey = .{
                .possible = true,
                .required = required,
                .token_number = s.tokens_parsed + (s.tokens.items.len - s.head),
                .mark = s.mark,
            };
            try s.removeSimpleKey();
            s.simple_keys.items[s.simple_keys.items.len - 1] = key;
        }
    }

    fn removeSimpleKey(s: *Scanner) Fail!void {
        const k = &s.simple_keys.items[s.simple_keys.items.len - 1];
        if (k.possible and k.required) return s.fail("could not find expected ':'", "while scanning a simple key", k.mark);
        k.possible = false;
    }

    fn increaseFlowLevel(s: *Scanner) Allocator.Error!void {
        try s.simple_keys.append(s.a, .{});
        s.flow_level += 1;
    }

    fn decreaseFlowLevel(s: *Scanner) void {
        if (s.flow_level > 0) {
            s.flow_level -= 1;
            _ = s.simple_keys.pop();
        }
    }

    fn rollIndent(s: *Scanner, column: i64, number: ?usize, kind: TokenKind, mark: Mark) Allocator.Error!void {
        if (s.flow_level > 0) return;
        if (s.indent < column) {
            try s.indents.append(s.a, s.indent);
            s.indent = column;
            const t: Token = .{ .kind = kind, .start = mark, .end = mark };
            if (number) |n| {
                try s.tokens.insert(s.a, s.head + (n - s.tokens_parsed), t);
            } else try s.enqueue(t);
        }
    }

    fn unrollIndent(s: *Scanner, column: i64) Allocator.Error!void {
        if (s.flow_level > 0) return;
        while (s.indent > column) {
            try s.enqueue(.{ .kind = .block_end, .start = s.mark, .end = s.mark });
            s.indent = s.indents.pop().?;
        }
    }

    fn fetchStreamStart(s: *Scanner) Fail!void {
        s.indent = -1;
        try s.simple_keys.append(s.a, .{});
        s.simple_key_allowed = true;
        s.stream_start_produced = true;
        if (std.mem.startsWith(u8, s.src, "\xEF\xBB\xBF")) s.mark.index = 3;
        try s.enqueue(.{ .kind = .stream_start, .start = s.mark, .end = s.mark });
    }

    fn fetchStreamEnd(s: *Scanner) Fail!void {
        if (s.mark.column != 0) {
            s.mark.column = 0;
            s.mark.line += 1;
        }
        try s.unrollIndent(-1);
        try s.removeSimpleKey();
        s.simple_key_allowed = false;
        try s.enqueue(.{ .kind = .stream_end, .start = s.mark, .end = s.mark });
    }

    fn fetchDirective(s: *Scanner) Fail!void {
        try s.unrollIndent(-1);
        try s.removeSimpleKey();
        s.simple_key_allowed = false;
        try s.scanDirective();
    }

    fn fetchDocumentIndicator(s: *Scanner, kind: TokenKind) Fail!void {
        try s.unrollIndent(-1);
        try s.removeSimpleKey();
        s.simple_key_allowed = false;
        const start = s.mark;
        s.skip();
        s.skip();
        s.skip();
        try s.enqueue(.{ .kind = kind, .start = start, .end = s.mark });
    }

    fn fetchFlowCollectionStart(s: *Scanner, kind: TokenKind) Fail!void {
        try s.saveSimpleKey();
        try s.increaseFlowLevel();
        s.simple_key_allowed = true;
        const start = s.mark;
        s.skip();
        try s.enqueue(.{ .kind = kind, .start = start, .end = s.mark });
    }

    fn fetchFlowCollectionEnd(s: *Scanner, kind: TokenKind) Fail!void {
        try s.removeSimpleKey();
        s.decreaseFlowLevel();
        s.simple_key_allowed = false;
        const start = s.mark;
        s.skip();
        try s.enqueue(.{ .kind = kind, .start = start, .end = s.mark });
    }

    fn fetchFlowEntry(s: *Scanner) Fail!void {
        try s.removeSimpleKey();
        s.simple_key_allowed = true;
        const start = s.mark;
        s.skip();
        try s.enqueue(.{ .kind = .flow_entry, .start = start, .end = s.mark });
    }

    fn fetchBlockEntry(s: *Scanner) Fail!void {
        if (s.flow_level == 0) {
            if (!s.simple_key_allowed) return s.fail("block sequence entries are not allowed in this context", null, s.mark);
            try s.rollIndent(@intCast(s.mark.column), null, .block_sequence_start, s.mark);
        }
        try s.removeSimpleKey();
        s.simple_key_allowed = true;
        const start = s.mark;
        s.skip();
        try s.enqueue(.{ .kind = .block_entry, .start = start, .end = s.mark });
    }

    fn fetchKey(s: *Scanner) Fail!void {
        if (s.flow_level == 0) {
            if (!s.simple_key_allowed) return s.fail("mapping keys are not allowed in this context", null, s.mark);
            try s.rollIndent(@intCast(s.mark.column), null, .block_mapping_start, s.mark);
        }
        try s.removeSimpleKey();
        s.simple_key_allowed = s.flow_level == 0;
        const start = s.mark;
        s.skip();
        try s.enqueue(.{ .kind = .key, .start = start, .end = s.mark });
    }

    fn fetchValue(s: *Scanner) Fail!void {
        const k = &s.simple_keys.items[s.simple_keys.items.len - 1];
        if (k.possible) {
            const t: Token = .{ .kind = .key, .start = k.mark, .end = k.mark };
            try s.tokens.insert(s.a, s.head + (k.token_number - s.tokens_parsed), t);
            const km = k.mark;
            const tn = k.token_number;
            try s.rollIndent(@intCast(km.column), tn, .block_mapping_start, km);
            s.simple_keys.items[s.simple_keys.items.len - 1].possible = false;
            s.simple_key_allowed = false;
        } else {
            if (s.flow_level == 0) {
                if (!s.simple_key_allowed) return s.fail("mapping values are not allowed in this context", null, s.mark);
                try s.rollIndent(@intCast(s.mark.column), null, .block_mapping_start, s.mark);
            }
            s.simple_key_allowed = s.flow_level == 0;
        }
        const start = s.mark;
        s.skip();
        try s.enqueue(.{ .kind = .value, .start = start, .end = s.mark });
    }

    fn fetchAnchor(s: *Scanner, kind: TokenKind) Fail!void {
        try s.saveSimpleKey();
        s.simple_key_allowed = false;
        try s.enqueue(try s.scanAnchor(kind));
    }

    fn fetchTag(s: *Scanner) Fail!void {
        try s.saveSimpleKey();
        s.simple_key_allowed = false;
        try s.enqueue(try s.scanTag());
    }

    fn fetchBlockScalar(s: *Scanner, literal: bool) Fail!void {
        try s.removeSimpleKey();
        s.simple_key_allowed = true;
        try s.enqueue(try s.scanBlockScalar(literal));
    }

    fn fetchFlowScalar(s: *Scanner, single: bool) Fail!void {
        try s.saveSimpleKey();
        s.simple_key_allowed = false;
        try s.enqueue(try s.scanFlowScalar(single));
    }

    fn fetchPlainScalar(s: *Scanner) Fail!void {
        try s.saveSimpleKey();
        s.simple_key_allowed = false;
        try s.enqueue(try s.scanPlainScalar());
    }

    fn scanToNextToken(s: *Scanner) Fail!void {
        while (true) {
            if (s.mark.column == 0 and s.ch(0) == 0xEF and s.ch(1) == 0xBB and s.ch(2) == 0xBF) s.mark.index += 3;
            while (s.ch(0) == ' ' or ((s.flow_level > 0 or !s.simple_key_allowed) and s.ch(0) == '\t')) s.skip();
            if (s.ch(0) == '#') {
                while (!s.isBreakZ(0)) s.skip();
            }
            if (s.isBreak(0)) {
                s.skipLine();
                if (s.flow_level == 0) s.simple_key_allowed = true;
            } else break;
        }
    }

    fn scanDirective(s: *Scanner) Fail!void {
        const start = s.mark;
        s.skip();
        var name: std.ArrayList(u8) = .empty;
        while (isAlpha(s.ch(0))) try s.read(&name);
        if (name.items.len == 0) return s.fail("could not find expected directive name", "while scanning a directive", start);
        if (!s.isBlankZ(0)) return s.fail("found unexpected non-alphabetical character", "while scanning a directive", start);
        var tok: Token = undefined;
        if (std.mem.eql(u8, name.items, "YAML")) {
            while (s.isBlank(0)) s.skip();
            const major = try s.scanVersionNumber(start);
            if (s.ch(0) != '.') return s.fail("did not find expected digit or '.' character", "while scanning a %YAML directive", start);
            s.skip();
            const minor = try s.scanVersionNumber(start);
            tok = .{ .kind = .version_directive, .start = start, .end = s.mark, .major = major, .minor = minor };
        } else if (std.mem.eql(u8, name.items, "TAG")) {
            while (s.isBlank(0)) s.skip();
            const handle = try s.scanTagHandle(true, start);
            if (!s.isBlank(0)) return s.fail("did not find expected whitespace", "while scanning a %TAG directive", start);
            while (s.isBlank(0)) s.skip();
            const prefix = try s.scanTagUri(true, null, start);
            if (!s.isBlankZ(0)) return s.fail("did not find expected whitespace or line break", "while scanning a %TAG directive", start);
            tok = .{ .kind = .tag_directive, .start = start, .end = s.mark, .handle = handle, .value = prefix };
        } else {
            return s.fail("found unknown directive name", "while scanning a directive", start);
        }
        while (s.isBlank(0)) s.skip();
        if (s.ch(0) == '#') {
            while (!s.isBreakZ(0)) s.skip();
        }
        if (!s.isBreakZ(0)) return s.fail("did not find expected comment or line break", "while scanning a directive", start);
        if (s.isBreak(0)) s.skipLine();
        try s.enqueue(tok);
    }

    fn scanVersionNumber(s: *Scanner, start: Mark) Fail!u32 {
        var value: u32 = 0;
        var length: usize = 0;
        while (std.ascii.isDigit(s.ch(0))) {
            length += 1;
            if (length > 9) return s.fail("found extremely long version number", "while scanning a %YAML directive", start);
            value = value * 10 + (s.ch(0) - '0');
            s.skip();
        }
        if (length == 0) return s.fail("did not find expected version number", "while scanning a %YAML directive", start);
        return value;
    }

    fn scanAnchor(s: *Scanner, kind: TokenKind) Fail!Token {
        const start = s.mark;
        s.skip();
        var buf: std.ArrayList(u8) = .empty;
        while (isAlpha(s.ch(0))) try s.read(&buf);
        const end = s.mark;
        const c = s.ch(0);
        if (buf.items.len == 0 or !(s.isBlankZ(0) or std.mem.indexOfScalar(u8, "?:,]}%@`", c) != null)) {
            return s.fail("did not find expected alphabetic or numeric character", if (kind == .anchor) "while scanning an anchor" else "while scanning an alias", start);
        }
        return .{ .kind = kind, .start = start, .end = end, .value = buf.items };
    }

    fn scanTag(s: *Scanner) Fail!Token {
        const start = s.mark;
        var handle: []const u8 = "";
        var suffix: []const u8 = "";
        if (s.ch(1) == '<') {
            s.skip();
            s.skip();
            suffix = try s.scanTagUri(false, null, start);
            if (s.ch(0) != '>') return s.fail("did not find the expected '>'", "while scanning a tag", start);
            s.skip();
        } else {
            handle = try s.scanTagHandle(false, start);
            if (handle[0] == '!' and handle.len > 1 and handle[handle.len - 1] == '!') {
                suffix = try s.scanTagUri(false, null, start);
            } else {
                suffix = try s.scanTagUri(false, handle, start);
                handle = "!";
                if (suffix.len == 0) {
                    handle = "";
                    suffix = "!";
                }
            }
        }
        if (!s.isBlankZ(0)) {
            if (s.flow_level == 0 or s.ch(0) != ',') {
                return s.fail("did not find expected whitespace or line break", "while scanning a tag", start);
            }
        }
        return .{ .kind = .tag, .start = start, .end = s.mark, .handle = handle, .value = suffix };
    }

    fn scanTagHandle(s: *Scanner, directive: bool, start: Mark) Fail![]const u8 {
        if (s.ch(0) != '!') return s.fail("did not find expected '!'", if (directive) "while scanning a tag directive" else "while scanning a tag", start);
        var buf: std.ArrayList(u8) = .empty;
        try s.read(&buf);
        while (isAlpha(s.ch(0))) try s.read(&buf);
        if (s.ch(0) == '!') {
            try s.read(&buf);
        } else if (directive and !(buf.items.len == 1 and buf.items[0] == '!')) {
            return s.fail("did not find expected '!'", "while parsing a tag directive", start);
        }
        return buf.items;
    }

    fn scanTagUri(s: *Scanner, directive: bool, head: ?[]const u8, start: Mark) Fail![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var length: usize = if (head) |h| h.len else 0;
        if (length > 1) try buf.appendSlice(s.a, head.?[1..]);
        while (true) {
            const c = s.ch(0);
            if (isAlpha(c) or (c != 0 and std.mem.indexOfScalar(u8, ";/?:@&=+$,.!~*'()[]%", c) != null)) {
                if (c == '%') {
                    try s.scanUriEscapes(directive, start, &buf);
                } else try s.read(&buf);
                length += 1;
            } else break;
        }
        if (length == 0) return s.fail("did not find expected tag URI", if (directive) "while parsing a %TAG directive" else "while parsing a tag", start);
        return buf.items;
    }

    fn scanUriEscapes(s: *Scanner, directive: bool, start: Mark, buf: *std.ArrayList(u8)) Fail!void {
        const context: []const u8 = if (directive) "while parsing a %TAG directive" else "while parsing a tag";
        var w: usize = 0;
        var left: usize = 0;
        while (true) {
            if (!(s.ch(0) == '%' and std.ascii.isHex(s.ch(1)) and std.ascii.isHex(s.ch(2)))) {
                return s.fail("did not find URI escaped octet", context, start);
            }
            const octet = (hexVal(s.ch(1)) << 4) + hexVal(s.ch(2));
            if (w == 0) {
                w = if (octet & 0x80 == 0) 1 else if (octet & 0xE0 == 0xC0) 2 else if (octet & 0xF0 == 0xE0) 3 else if (octet & 0xF8 == 0xF0) 4 else 0;
                if (w == 0) return s.fail("found an incorrect leading UTF-8 octet", context, start);
                left = w;
            } else if (octet & 0xC0 != 0x80) {
                return s.fail("found an incorrect trailing UTF-8 octet", context, start);
            }
            try buf.append(s.a, octet);
            s.skip();
            s.skip();
            s.skip();
            left -= 1;
            if (left == 0) break;
        }
    }

    fn hexVal(c: u8) u8 {
        return if (c >= 'a') c - 'a' + 10 else if (c >= 'A') c - 'A' + 10 else c - '0';
    }

    fn scanBlockScalar(s: *Scanner, literal: bool) Fail!Token {
        const start = s.mark;
        s.skip();
        var chomping: i32 = 0;
        var increment: i64 = 0;
        var c = s.ch(0);
        if (c == '+' or c == '-') {
            chomping = if (c == '+') 1 else -1;
            s.skip();
            if (std.ascii.isDigit(s.ch(0))) {
                if (s.ch(0) == '0') return s.fail("found an indentation indicator equal to 0", "while scanning a block scalar", start);
                increment = s.ch(0) - '0';
                s.skip();
            }
        } else if (std.ascii.isDigit(c)) {
            if (c == '0') return s.fail("found an indentation indicator equal to 0", "while scanning a block scalar", start);
            increment = c - '0';
            s.skip();
            c = s.ch(0);
            if (c == '+' or c == '-') {
                chomping = if (c == '+') 1 else -1;
                s.skip();
            }
        }
        while (s.isBlank(0)) s.skip();
        if (s.ch(0) == '#') {
            while (!s.isBreakZ(0)) s.skip();
        }
        if (!s.isBreakZ(0)) return s.fail("did not find expected comment or line break", "while scanning a block scalar", start);
        if (s.isBreak(0)) s.skipLine();
        var end = s.mark;
        var indent: i64 = 0;
        if (increment > 0) indent = if (s.indent >= 0) s.indent + increment else increment;

        var string: std.ArrayList(u8) = .empty;
        var leading_break: std.ArrayList(u8) = .empty;
        var trailing_breaks: std.ArrayList(u8) = .empty;
        var leading_blank = false;
        try s.scanBlockScalarBreaks(&indent, &trailing_breaks, start, &end);

        while (@as(i64, @intCast(s.mark.column)) == indent and !s.isZ(0)) {
            const trailing_blank = s.isBlank(0);
            if (!literal and leading_break.items.len > 0 and leading_break.items[0] == '\n' and !leading_blank and !trailing_blank) {
                if (trailing_breaks.items.len == 0) try string.append(s.a, ' ');
                leading_break.clearRetainingCapacity();
            } else {
                try string.appendSlice(s.a, leading_break.items);
                leading_break.clearRetainingCapacity();
            }
            try string.appendSlice(s.a, trailing_breaks.items);
            trailing_breaks.clearRetainingCapacity();
            leading_blank = s.isBlank(0);
            while (!s.isBreakZ(0)) try s.read(&string);
            try s.readLine(&leading_break);
            try s.scanBlockScalarBreaks(&indent, &trailing_breaks, start, &end);
        }
        if (chomping != -1) try string.appendSlice(s.a, leading_break.items);
        if (chomping == 1) try string.appendSlice(s.a, trailing_breaks.items);
        return .{ .kind = .scalar, .start = start, .end = end, .value = string.items, .style = if (literal) .literal else .folded };
    }

    fn scanBlockScalarBreaks(s: *Scanner, indent: *i64, breaks: *std.ArrayList(u8), start: Mark, end: *Mark) Fail!void {
        var max_indent: i64 = 0;
        end.* = s.mark;
        while (true) {
            while ((indent.* == 0 or @as(i64, @intCast(s.mark.column)) < indent.*) and s.ch(0) == ' ') s.skip();
            if (@as(i64, @intCast(s.mark.column)) > max_indent) max_indent = @intCast(s.mark.column);
            if ((indent.* == 0 or @as(i64, @intCast(s.mark.column)) < indent.*) and s.ch(0) == '\t') {
                return s.fail("found a tab character where an indentation space is expected", "while scanning a block scalar", start);
            }
            if (!s.isBreak(0)) break;
            try s.readLine(breaks);
            end.* = s.mark;
        }
        if (indent.* == 0) {
            indent.* = max_indent;
            if (indent.* < s.indent + 1) indent.* = s.indent + 1;
            if (indent.* < 1) indent.* = 1;
        }
    }

    fn scanFlowScalar(s: *Scanner, single: bool) Fail!Token {
        const start = s.mark;
        s.skip();
        var string: std.ArrayList(u8) = .empty;
        var leading_break: std.ArrayList(u8) = .empty;
        var trailing_breaks: std.ArrayList(u8) = .empty;
        var whitespaces: std.ArrayList(u8) = .empty;
        const quote: u8 = if (single) '\'' else '"';
        while (true) {
            if (s.mark.column == 0 and ((s.ch(0) == '-' and s.ch(1) == '-' and s.ch(2) == '-') or (s.ch(0) == '.' and s.ch(1) == '.' and s.ch(2) == '.')) and s.isBlankZ(3)) {
                return s.fail("found unexpected document indicator", "while scanning a quoted scalar", start);
            }
            if (s.isZ(0)) return s.fail("found unexpected end of stream", "while scanning a quoted scalar", start);
            var leading_blanks = false;
            while (!s.isBlankZ(0)) {
                if (single and s.ch(0) == '\'' and s.ch(1) == '\'') {
                    try string.append(s.a, '\'');
                    s.skip();
                    s.skip();
                } else if (s.ch(0) == quote) {
                    break;
                } else if (!single and s.ch(0) == '\\' and s.isBreak(1)) {
                    s.skip();
                    s.skipLine();
                    leading_blanks = true;
                    break;
                } else if (!single and s.ch(0) == '\\') {
                    var code_length: usize = 0;
                    switch (s.ch(1)) {
                        '0' => try string.append(s.a, 0),
                        'a' => try string.append(s.a, 7),
                        'b' => try string.append(s.a, 8),
                        't', '\t' => try string.append(s.a, 9),
                        'n' => try string.append(s.a, 10),
                        'v' => try string.append(s.a, 11),
                        'f' => try string.append(s.a, 12),
                        'r' => try string.append(s.a, 13),
                        'e' => try string.append(s.a, 0x1B),
                        ' ' => try string.append(s.a, ' '),
                        '"' => try string.append(s.a, '"'),
                        '\'' => try string.append(s.a, '\''),
                        '\\' => try string.append(s.a, '\\'),
                        '/' => try string.append(s.a, '/'),
                        'N' => try string.appendSlice(s.a, "\xC2\x85"),
                        '_' => try string.appendSlice(s.a, "\xC2\xA0"),
                        'L' => try string.appendSlice(s.a, "\xE2\x80\xA8"),
                        'P' => try string.appendSlice(s.a, "\xE2\x80\xA9"),
                        'x' => code_length = 2,
                        'u' => code_length = 4,
                        'U' => code_length = 8,
                        else => return s.fail("found unknown escape character", "while parsing a quoted scalar", start),
                    }
                    s.skip();
                    s.skip();
                    if (code_length > 0) {
                        var value: u32 = 0;
                        for (0..code_length) |k| {
                            if (!std.ascii.isHex(s.ch(k))) return s.fail("did not find expected hexdecimal number", "while parsing a quoted scalar", start);
                            value = (value << 4) + hexVal(s.ch(k));
                        }
                        if ((value >= 0xD800 and value <= 0xDFFF) or value > 0x10FFFF) {
                            return s.fail("found invalid Unicode character escape code", "while parsing a quoted scalar", start);
                        }
                        var enc: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(@intCast(value), &enc) catch 0;
                        try string.appendSlice(s.a, enc[0..n]);
                        for (0..code_length) |_| s.skip();
                    }
                } else try s.read(&string);
            }
            if (s.ch(0) == quote) break;
            while (s.isBlank(0) or s.isBreak(0)) {
                if (s.isBlank(0)) {
                    if (!leading_blanks) try s.read(&whitespaces) else s.skip();
                } else {
                    if (!leading_blanks) {
                        whitespaces.clearRetainingCapacity();
                        try s.readLine(&leading_break);
                        leading_blanks = true;
                    } else try s.readLine(&trailing_breaks);
                }
            }
            if (leading_blanks) {
                if (leading_break.items.len > 0 and leading_break.items[0] == '\n') {
                    if (trailing_breaks.items.len == 0) {
                        try string.append(s.a, ' ');
                    } else {
                        try string.appendSlice(s.a, trailing_breaks.items);
                        trailing_breaks.clearRetainingCapacity();
                    }
                    leading_break.clearRetainingCapacity();
                } else {
                    try string.appendSlice(s.a, leading_break.items);
                    try string.appendSlice(s.a, trailing_breaks.items);
                    leading_break.clearRetainingCapacity();
                    trailing_breaks.clearRetainingCapacity();
                }
            } else {
                try string.appendSlice(s.a, whitespaces.items);
                whitespaces.clearRetainingCapacity();
            }
        }
        s.skip();
        return .{ .kind = .scalar, .start = start, .end = s.mark, .value = string.items, .style = if (single) .single else .double };
    }

    fn scanPlainScalar(s: *Scanner) Fail!Token {
        var string: std.ArrayList(u8) = .empty;
        var leading_break: std.ArrayList(u8) = .empty;
        var trailing_breaks: std.ArrayList(u8) = .empty;
        var whitespaces: std.ArrayList(u8) = .empty;
        var leading_blanks = false;
        const start = s.mark;
        var end = s.mark;
        const indent: i64 = s.indent + 1;
        while (true) {
            if (s.mark.column == 0 and ((s.ch(0) == '-' and s.ch(1) == '-' and s.ch(2) == '-') or (s.ch(0) == '.' and s.ch(1) == '.' and s.ch(2) == '.')) and s.isBlankZ(3)) break;
            if (s.ch(0) == '#') break;
            while (!s.isBlankZ(0)) {
                if (s.flow_level > 0 and s.ch(0) == ':' and std.mem.indexOfScalar(u8, ",?[]{}", s.ch(1)) != null and s.ch(1) != 0) {
                    return s.fail("found unexpected ':'", "while scanning a plain scalar", start);
                }
                if ((s.ch(0) == ':' and s.isBlankZ(1)) or (s.flow_level > 0 and std.mem.indexOfScalar(u8, ",[]{}", s.ch(0)) != null and s.ch(0) != 0)) break;
                if (leading_blanks or whitespaces.items.len > 0) {
                    if (leading_blanks) {
                        if (leading_break.items.len > 0 and leading_break.items[0] == '\n') {
                            if (trailing_breaks.items.len == 0) {
                                try string.append(s.a, ' ');
                            } else {
                                try string.appendSlice(s.a, trailing_breaks.items);
                                trailing_breaks.clearRetainingCapacity();
                            }
                            leading_break.clearRetainingCapacity();
                        } else {
                            try string.appendSlice(s.a, leading_break.items);
                            try string.appendSlice(s.a, trailing_breaks.items);
                            leading_break.clearRetainingCapacity();
                            trailing_breaks.clearRetainingCapacity();
                        }
                        leading_blanks = false;
                    } else {
                        try string.appendSlice(s.a, whitespaces.items);
                        whitespaces.clearRetainingCapacity();
                    }
                }
                try s.read(&string);
                end = s.mark;
            }
            if (!(s.isBlank(0) or s.isBreak(0))) break;
            while (s.isBlank(0) or s.isBreak(0)) {
                if (s.isBlank(0)) {
                    if (leading_blanks and @as(i64, @intCast(s.mark.column)) < indent and s.ch(0) == '\t') {
                        return s.fail("found a tab character that violates indentation", "while scanning a plain scalar", start);
                    }
                    if (!leading_blanks) try s.read(&whitespaces) else s.skip();
                } else {
                    if (!leading_blanks) {
                        whitespaces.clearRetainingCapacity();
                        try s.readLine(&leading_break);
                        leading_blanks = true;
                    } else try s.readLine(&trailing_breaks);
                }
            }
            if (s.flow_level == 0 and @as(i64, @intCast(s.mark.column)) < indent) break;
        }
        if (leading_blanks) s.simple_key_allowed = true;
        return .{ .kind = .scalar, .start = start, .end = end, .value = string.items, .style = .plain };
    }
};
