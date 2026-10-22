const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) { scalar: []const u8, seq: []const Value, map: []const Pair };
pub const Pair = struct { key: []const u8, value: Value };
pub const Failure = struct { message: []const u8, line: usize, col: usize };
pub const Result = union(enum) { ok: Value, err: Failure };

const Fail = error{ Yaml, OutOfMemory };

const Line = struct { no: usize, indent: usize, text: []const u8, raw: []const u8, skip: bool };

const Split = struct { key: []const u8, rest: []const u8, rest_at: usize };

pub fn parse(a: Allocator, src: []const u8) Allocator.Error!Result {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var no: usize = 0;
    while (it.next()) |l0| {
        no += 1;
        const raw = std.mem.trimEnd(u8, l0, "\r");
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        const text = std.mem.trimEnd(u8, stripComment(raw[indent..]), " \t");
        try lines.append(a, .{ .no = no, .indent = indent, .text = text, .raw = raw, .skip = text.len == 0 });
    }
    var ps: Ps = .{ .a = a, .lines = lines.items };
    const v = ps.document() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Yaml => return .{ .err = ps.err },
    };
    return .{ .ok = v };
}

fn stripComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    for (s, 0..) |c, i| {
        const prev: u8 = if (i == 0) ' ' else s[i - 1];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if ((c == '"' or c == '\'') and std.mem.indexOfScalar(u8, " \t:[{,-", prev) != null) {
            quote = c;
        } else if (c == '#' and (prev == ' ' or prev == '\t')) {
            return s[0..i];
        }
    }
    return s;
}

fn isDash(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

fn closingQuote(s: []const u8, from: usize, q: u8) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (q == '"' and s[i] == '\\') {
            i += 1;
        } else if (s[i] == q) {
            if (q == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
                i += 1;
            } else return i;
        }
    }
    return null;
}

fn splitKey(text: []const u8) ?Split {
    if (text.len == 0 or text[0] == '[' or text[0] == '{' or isDash(text)) return null;
    var i: usize = 0;
    if (text[0] == '"' or text[0] == '\'') {
        const e = closingQuote(text, 1, text[0]) orelse return null;
        i = e + 1;
        while (i < text.len and text[i] == ' ') i += 1;
        if (i >= text.len or text[i] != ':') return null;
        if (i + 1 < text.len and text[i + 1] != ' ') return null;
        const rest = std.mem.trimStart(u8, text[i + 1 ..], " ");
        return .{ .key = text[0 .. e + 1], .rest = rest, .rest_at = text.len - rest.len };
    }
    while (i < text.len) : (i += 1) {
        if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\t')) {
            const rest = std.mem.trimStart(u8, text[i + 1 ..], " \t");
            return .{ .key = std.mem.trimEnd(u8, text[0..i], " \t"), .rest = rest, .rest_at = text.len - rest.len };
        }
    }
    return null;
}

fn scalarText(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
        var out: std.ArrayList(u8) = .empty;
        const body = s[1 .. s.len - 1];
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            if (s[0] == '\'' and c == '\'' and i + 1 < body.len and body[i + 1] == '\'') {
                try out.append(a, '\'');
                i += 1;
            } else if (s[0] == '"' and c == '\\' and i + 1 < body.len) {
                i += 1;
                try out.append(a, switch (body[i]) {
                    'n' => '\n',
                    't' => '\t',
                    else => body[i],
                });
            } else try out.append(a, c);
        }
        return out.items;
    }
    for ([_][]const u8{ "", "~", "null" }) |n| if (std.ascii.eqlIgnoreCase(s, n)) return "";
    for ([_][]const u8{ "true", "yes", "on" }) |n| if (std.ascii.eqlIgnoreCase(s, n)) return "true";
    for ([_][]const u8{ "false", "no", "off" }) |n| if (std.ascii.eqlIgnoreCase(s, n)) return "false";
    return s;
}

const Ps = struct {
    a: Allocator,
    lines: []Line,
    i: usize = 0,
    err: Failure = undefined,

    fn fail(ps: *Ps, msg: []const u8, line: usize, col: usize) Fail {
        ps.err = .{ .message = msg, .line = line, .col = col };
        return error.Yaml;
    }

    fn peek(ps: *Ps) Fail!?*Line {
        while (ps.i < ps.lines.len and ps.lines[ps.i].skip) ps.i += 1;
        if (ps.i >= ps.lines.len) return null;
        const l = &ps.lines[ps.i];
        if (l.indent < l.raw.len and l.raw[l.indent] == '\t') {
            return ps.fail("found character that cannot start any token while scanning for the next token", l.no, l.indent + 1);
        }
        return l;
    }

    fn document(ps: *Ps) Fail!Value {
        const first = (try ps.peek()) orelse return .{ .map = &.{} };
        const v = try ps.block(first.indent);
        if ((try ps.peek()) != null) return ps.fail("did not find expected key while parsing a block mapping", first.no, first.indent + 1);
        return v;
    }

    fn block(ps: *Ps, indent: usize) Fail!Value {
        const l = (try ps.peek()).?;
        if (isDash(l.text)) return ps.seq(indent);
        if (splitKey(l.text) != null) return ps.map(indent);
        return ps.value(l.text, indent, l.no, l.indent + 1, l.no, l.indent + 1);
    }

    fn nested(ps: *Ps, parent_indent: usize, dash_ok: bool) Fail!Value {
        const n = (try ps.peek()) orelse return .{ .scalar = "" };
        if (n.indent > parent_indent or (dash_ok and n.indent == parent_indent and isDash(n.text))) return ps.block(n.indent);
        return .{ .scalar = "" };
    }

    fn map(ps: *Ps, indent: usize) Fail!Value {
        var pairs: std.ArrayList(Pair) = .empty;
        const first = ps.lines[ps.i];
        while (try ps.peek()) |l| {
            if (l.indent < indent) break;
            if (l.indent > indent or isDash(l.text)) return ps.fail("did not find expected key while parsing a block mapping", first.no, first.indent + 1);
            const sp = splitKey(l.text) orelse return ps.fail("could not find expected ':' while scanning a simple key", l.no, l.indent + 1);
            const key = try scalarText(ps.a, sp.key);
            const line_no = l.no;
            const col = l.indent + 1 + sp.rest_at;
            const rest = sp.rest;
            var v: Value = undefined;
            if (rest.len == 0) {
                ps.i += 1;
                v = try ps.nested(indent, true);
            } else {
                v = try ps.value(rest, indent, line_no, col, first.no, first.indent + 1);
            }
            try pairs.append(ps.a, .{ .key = key, .value = v });
        }
        return .{ .map = pairs.items };
    }

    fn seq(ps: *Ps, indent: usize) Fail!Value {
        var items: std.ArrayList(Value) = .empty;
        const first = ps.lines[ps.i];
        while (try ps.peek()) |l| {
            if (l.indent < indent) break;
            if (l.indent > indent) return ps.fail("did not find expected '-' indicator while parsing a block collection", first.no, first.indent + 1);
            if (!isDash(l.text)) {
                if (l.indent == indent) return ps.fail("did not find expected '-' indicator while parsing a block collection", first.no, first.indent + 1);
                break;
            }
            const after = std.mem.trimStart(u8, l.text[1..], " ");
            const offset = l.indent + (l.text.len - after.len);
            if (after.len == 0) {
                ps.i += 1;
                try items.append(ps.a, try ps.nested(indent, false));
            } else if (isDash(after) or splitKey(after) != null) {
                l.indent = offset;
                l.text = after;
                try items.append(ps.a, try ps.block(offset));
            } else {
                try items.append(ps.a, try ps.value(after, indent, l.no, offset + 1, first.no, first.indent + 1));
            }
        }
        return .{ .seq = items.items };
    }

    fn value(ps: *Ps, rest: []const u8, parent: usize, line_no: usize, col: usize, ctx_line: usize, ctx_col: usize) Fail!Value {
        if (rest[0] == '|' or rest[0] == '>') return ps.blockScalar(rest, parent);
        if (rest[0] == '[' or rest[0] == '{') return ps.flow(rest, line_no, col);
        if (rest[0] == '"' or rest[0] == '\'') return ps.quoted(rest, line_no, col, ctx_line, ctx_col);
        return ps.plain(rest, parent, line_no, col);
    }

    fn plain(ps: *Ps, rest: []const u8, parent: usize, line_no: usize, col: usize) Fail!Value {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(ps.a, rest);
        if (colonIn(rest)) |c| return ps.fail("mapping values are not allowed in this context", line_no, col + c);
        ps.i += 1;
        while (try ps.peek()) |n| {
            if (n.indent <= parent) break;
            if (colonIn(n.text)) |c| return ps.fail("mapping values are not allowed in this context", n.no, n.indent + 1 + c);
            try text.append(ps.a, ' ');
            try text.appendSlice(ps.a, n.text);
            ps.i += 1;
        }
        return .{ .scalar = try scalarText(ps.a, text.items) };
    }

    fn colonIn(s: []const u8) ?usize {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == ':' and (i + 1 == s.len or s[i + 1] == ' ')) return i;
        }
        return null;
    }

    fn blockScalar(ps: *Ps, header: []const u8, parent: usize) Fail!Value {
        const folded = header[0] == '>';
        ps.i += 1;
        var out: std.ArrayList(u8) = .empty;
        var block_indent: ?usize = null;
        var pending_blank: usize = 0;
        while (ps.i < ps.lines.len) : (ps.i += 1) {
            const l = ps.lines[ps.i];
            if (std.mem.trim(u8, l.raw, " \t").len == 0) {
                pending_blank += 1;
                continue;
            }
            if (l.indent <= parent) break;
            const bi = block_indent orelse l.indent;
            block_indent = bi;
            if (l.indent < bi) break;
            if (out.items.len > 0) {
                if (folded and pending_blank == 0) {
                    try out.append(ps.a, ' ');
                } else try out.appendNTimes(ps.a, '\n', if (folded) pending_blank else pending_blank + 1);
            }
            pending_blank = 0;
            try out.appendSlice(ps.a, l.raw[bi..]);
        }
        return .{ .scalar = out.items };
    }

    fn quoted(ps: *Ps, rest: []const u8, line_no: usize, col: usize, ctx_line: usize, ctx_col: usize) Fail!Value {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(ps.a, rest);
        const q = rest[0];
        var end = closingQuote(text.items, 1, q);
        ps.i += 1;
        while (end == null) {
            if (ps.i >= ps.lines.len) return ps.fail("found unexpected end of stream while scanning a quoted scalar", line_no, col);
            const n = ps.lines[ps.i];
            ps.i += 1;
            try text.append(ps.a, ' ');
            try text.appendSlice(ps.a, std.mem.trim(u8, n.raw, " \t"));
            end = closingQuote(text.items, 1, q);
        }
        const trailing = std.mem.trim(u8, stripComment(text.items[end.? + 1 ..]), " \t");
        if (trailing.len > 0) return ps.fail("did not find expected key while parsing a block mapping", ctx_line, ctx_col);
        return .{ .scalar = try scalarText(ps.a, text.items[0 .. end.? + 1]) };
    }

    fn flow(ps: *Ps, rest: []const u8, line_no: usize, col: usize) Fail!Value {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(ps.a, rest);
        ps.i += 1;
        while (depthOf(text.items) > 0) {
            const n = (try ps.peek()) orelse break;
            try text.append(ps.a, ' ');
            try text.appendSlice(ps.a, n.text);
            ps.i += 1;
        }
        var f: Flow = .{ .ps = ps, .s = text.items, .line = line_no, .col0 = col };
        return f.value();
    }
};

fn depthOf(s: []const u8) i32 {
    var d: i32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '"', '\'' => i = closingQuote(s, i + 1, s[i]) orelse return d,
            '[', '{' => d += 1,
            ']', '}' => {
                d -= 1;
                if (d == 0) return 0;
            },
            else => {},
        }
    }
    return d;
}

const Flow = struct {
    ps: *Ps,
    s: []const u8,
    pos: usize = 0,
    line: usize,
    col0: usize,

    fn skip(f: *Flow) void {
        while (f.pos < f.s.len and (f.s[f.pos] == ' ' or f.s[f.pos] == '\t')) f.pos += 1;
    }

    fn value(f: *Flow) Fail!Value {
        f.skip();
        if (f.pos >= f.s.len) return .{ .scalar = "" };
        switch (f.s[f.pos]) {
            '[' => return f.seq(),
            '{' => return f.map(),
            '"', '\'' => {
                const q = f.s[f.pos];
                const e = closingQuote(f.s, f.pos + 1, q) orelse return f.ps.fail("found unexpected end of stream while scanning a quoted scalar", f.line, f.col0 + f.pos);
                const v = try scalarText(f.ps.a, f.s[f.pos .. e + 1]);
                f.pos = e + 1;
                return .{ .scalar = v };
            },
            else => {
                const start = f.pos;
                while (f.pos < f.s.len and std.mem.indexOfScalar(u8, ",]}", f.s[f.pos]) == null) f.pos += 1;
                return .{ .scalar = try scalarText(f.ps.a, f.s[start..f.pos]) };
            },
        }
    }

    fn seq(f: *Flow) Fail!Value {
        const start = f.pos;
        f.pos += 1;
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            f.skip();
            if (f.pos < f.s.len and f.s[f.pos] == ']') {
                f.pos += 1;
                return .{ .seq = items.items };
            }
            if (f.pos >= f.s.len) return f.ps.fail("did not find expected ',' or ']' while parsing a flow sequence", f.line, f.col0 + start);
            try items.append(f.ps.a, try f.value());
            f.skip();
            if (f.pos < f.s.len and f.s[f.pos] == ',') {
                f.pos += 1;
            } else if (f.pos >= f.s.len or f.s[f.pos] != ']') {
                return f.ps.fail("did not find expected ',' or ']' while parsing a flow sequence", f.line, f.col0 + start);
            }
        }
    }

    fn map(f: *Flow) Fail!Value {
        const start = f.pos;
        f.pos += 1;
        var pairs: std.ArrayList(Pair) = .empty;
        while (true) {
            f.skip();
            if (f.pos < f.s.len and f.s[f.pos] == '}') {
                f.pos += 1;
                return .{ .map = pairs.items };
            }
            if (f.pos >= f.s.len) return f.ps.fail("did not find expected ',' or '}' while parsing a flow mapping", f.line, f.col0 + start);
            const ks = f.pos;
            var key: []const u8 = undefined;
            if (f.s[ks] == '"' or f.s[ks] == '\'') {
                const kv = try f.value();
                key = kv.scalar;
            } else {
                while (f.pos < f.s.len and std.mem.indexOfScalar(u8, ":,}", f.s[f.pos]) == null) f.pos += 1;
                key = try scalarText(f.ps.a, f.s[ks..f.pos]);
            }
            f.skip();
            var v: Value = .{ .scalar = "" };
            if (f.pos < f.s.len and f.s[f.pos] == ':') {
                f.pos += 1;
                v = try f.value();
            }
            try pairs.append(f.ps.a, .{ .key = key, .value = v });
            f.skip();
            if (f.pos < f.s.len and f.s[f.pos] == ',') {
                f.pos += 1;
            } else if (f.pos >= f.s.len or f.s[f.pos] != '}') {
                return f.ps.fail("did not find expected ',' or '}' while parsing a flow mapping", f.line, f.col0 + start);
            }
        }
    }
};

fn expectMsg(src: []const u8, line: usize, col: usize, msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), src);
    try std.testing.expectEqualStrings(msg, r.err.message);
    try std.testing.expectEqual(line, r.err.line);
    try std.testing.expectEqual(col, r.err.col);
}

test "valid document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "a: 1\nb:\n  - x\n  - y: z\nc: [1, 2]\nd: >\n  folded\n  text\n");
    const m = r.ok.map;
    try std.testing.expectEqual(@as(usize, 4), m.len);
    try std.testing.expectEqualStrings("1", m[0].value.scalar);
    try std.testing.expectEqual(@as(usize, 2), m[1].value.seq.len);
    try std.testing.expectEqualStrings("z", m[1].value.seq[1].map[0].value.scalar);
    try std.testing.expectEqual(@as(usize, 2), m[2].value.seq.len);
    try std.testing.expectEqualStrings("folded text", m[3].value.scalar);
}

test "libyaml style errors" {
    try expectMsg("a: { b: 1\nc: 2\n", 1, 4, "did not find expected ',' or '}' while parsing a flow mapping");
    try expectMsg("a: [1, 2\n", 1, 4, "did not find expected ',' or ']' while parsing a flow sequence");
    try expectMsg("a: b: c\n", 1, 5, "mapping values are not allowed in this context");
    try expectMsg("a: 1\n\tb: 2\n", 2, 1, "found character that cannot start any token while scanning for the next token");
    try expectMsg("a: 1\nnope\n", 2, 1, "could not find expected ':' while scanning a simple key");
}
