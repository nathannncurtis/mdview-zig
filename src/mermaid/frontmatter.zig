const std = @import("std");
const testdata = @import("testdata");
const Allocator = std.mem.Allocator;
const json = std.json;
const yparse = @import("yaml");
const numfmt = @import("numfmt.zig");
const errors = @import("errors.zig");

const Parser = yparse.Parser;
const Scanner = @typeInfo(@FieldType(Parser, "sc")).pointer.child;
const Token = std.meta.Child(@FieldType(Scanner, "tokens").Slice);
const TokenKind = @FieldType(Token, "kind");

pub const Value = json.Value;

pub const Result = union(enum) { ok: Value, err: []const u8 };

// js-yaml with `schema: JSON_SCHEMA`, which is how mermaid reads front matter: plain scalars are typed as
// null, boolean, integer (decimal, 0x, 0o, 0b, underscores) or float (.inf, .nan); quoted and block scalars are strings.

fn isDec(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn resolveInt(d: []const u8) bool {
    const max = d.len;
    if (max == 0) return false;
    var i: usize = 0;
    var has = false;
    var ch: u8 = d[0];
    if (ch == '-' or ch == '+') {
        i += 1;
        ch = if (i < max) d[i] else 0;
    }
    if (ch == '0') {
        if (i + 1 == max) return true;
        i += 1;
        ch = d[i];
        if (ch == 'b' or ch == 'x' or ch == 'o') {
            const kind = ch;
            i += 1;
            while (i < max) : (i += 1) {
                ch = d[i];
                if (ch == '_') continue;
                const ok = switch (kind) {
                    'b' => ch == '0' or ch == '1',
                    'x' => std.ascii.isHex(ch),
                    else => ch >= '0' and ch <= '7',
                };
                if (!ok) return false;
                has = true;
            }
            return has and ch != '_';
        }
    }
    if (ch == '_') return false;
    while (i < max) : (i += 1) {
        ch = d[i];
        if (ch == '_') continue;
        if (!isDec(ch)) return false;
        has = true;
    }
    return has and ch != '_';
}

fn intValue(a: Allocator, d: []const u8) Allocator.Error!Value {
    var buf: std.ArrayList(u8) = .empty;
    for (d) |c| if (c != '_') try buf.append(a, c);
    var v = buf.items;
    var neg = false;
    if (v[0] == '-' or v[0] == '+') {
        neg = v[0] == '-';
        v = v[1..];
    }
    var base: u8 = 10;
    if (v.len > 1 and v[0] == '0') switch (v[1]) {
        'b' => {
            base = 2;
            v = v[2..];
        },
        'x' => {
            base = 16;
            v = v[2..];
        },
        'o' => {
            base = 8;
            v = v[2..];
        },
        else => {},
    };
    const n = std.fmt.parseInt(u64, v, base) catch {
        var f: f64 = 0;
        for (v) |c| f = f * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(std.fmt.charToDigit(c, base) catch 0));
        return .{ .float = if (neg) -f else f };
    };
    if (n > (1 << 53)) return .{ .float = if (neg) -@as(f64, @floatFromInt(n)) else @as(f64, @floatFromInt(n)) };
    const s: i64 = @intCast(n);
    return .{ .integer = if (neg) -s else s };
}

fn digitsAt(d: []const u8, i: usize, allow_underscore: bool) usize {
    var j = i;
    while (j < d.len and (isDec(d[j]) or (allow_underscore and d[j] == '_'))) j += 1;
    return j;
}

// ^(?:[-+]?[0-9][0-9_]*(?:\.[0-9_]*)?(?:[eE][-+]?[0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$
fn resolveFloat(d: []const u8) bool {
    if (d.len == 0 or d[d.len - 1] == '_') return false;
    for ([_][]const u8{ ".nan", ".NaN", ".NAN" }) |s| if (std.mem.eql(u8, d, s)) return true;
    var body = d;
    var signed = false;
    if (body[0] == '-' or body[0] == '+') {
        body = body[1..];
        signed = true;
    }
    for ([_][]const u8{ ".inf", ".Inf", ".INF" }) |s| if (std.mem.eql(u8, body, s)) return true;
    var i: usize = 0;
    if (body.len > 0 and isDec(body[0])) {
        i = digitsAt(body, 1, true);
        if (i < body.len and body[i] == '.') {
            i += 1;
            while (i < body.len and (isDec(body[i]) or body[i] == '_')) i += 1;
        }
    } else if (!signed and body.len > 1 and body[0] == '.' and isDec(body[1])) {
        i = digitsAt(body, 2, true);
    } else return false;
    if (i < body.len and (body[i] == 'e' or body[i] == 'E')) {
        i += 1;
        if (i < body.len and (body[i] == '-' or body[i] == '+')) i += 1;
        const st = i;
        i = digitsAt(body, i, false);
        if (i == st) return false;
    }
    return i == body.len;
}

fn floatValue(a: Allocator, d: []const u8) Allocator.Error!Value {
    var buf: std.ArrayList(u8) = .empty;
    for (d) |c| if (c != '_') try buf.append(a, std.ascii.toLower(c));
    var v = buf.items;
    var neg = false;
    if (v[0] == '-' or v[0] == '+') {
        neg = v[0] == '-';
        v = v[1..];
    }
    if (std.mem.eql(u8, v, ".inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
    if (std.mem.eql(u8, v, ".nan")) return .{ .float = std.math.nan(f64) };
    var norm: std.ArrayList(u8) = .empty;
    if (v[0] == '.') try norm.append(a, '0');
    for (v, 0..) |c, i| {
        try norm.append(a, c);
        if (c == '.' and (i + 1 == v.len or v[i + 1] == 'e')) try norm.append(a, '0');
    }
    const f = std.fmt.parseFloat(f64, norm.items) catch 0;
    return .{ .float = if (neg) -f else f };
}

fn resolvePlain(a: Allocator, t: []const u8) Allocator.Error!Value {
    if (t.len == 0 or std.mem.eql(u8, t, "~") or std.mem.eql(u8, t, "null") or std.mem.eql(u8, t, "Null") or std.mem.eql(u8, t, "NULL")) return .null;
    for ([_][]const u8{ "true", "True", "TRUE" }) |s| if (std.mem.eql(u8, t, s)) return .{ .bool = true };
    for ([_][]const u8{ "false", "False", "FALSE" }) |s| if (std.mem.eql(u8, t, s)) return .{ .bool = false };
    if (resolveInt(t)) return intValue(a, t);
    if (resolveFloat(t)) return floatValue(a, t);
    return .{ .string = t };
}

fn explicitTag(a: Allocator, tag: []const u8, text: []const u8) Allocator.Error!Value {
    const prefix = "tag:yaml.org,2002:";
    if (!std.mem.startsWith(u8, tag, prefix)) return .{ .string = text };
    const name = tag[prefix.len..];
    if (std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float")) {
        const v = try resolvePlain(a, text);
        return switch (v) {
            .string => .{ .string = text },
            else => v,
        };
    }
    return .{ .string = text };
}

fn keyString(a: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try numfmt.js(a, f),
        .string => |s| s,
        .array, .object, .number_string => "[object Object]",
    };
}

const Failure = struct { reason: []const u8, index: usize };

const Composer = struct {
    a: Allocator,
    sc: *Scanner,
    ps: *yparse.Parser,
    anchors: std.StringHashMapUnmanaged(Value) = .empty,
    scalar_ord: usize = 0,
    alias_ord: usize = 0,
    last_ord: usize = 0,
    failure: ?Failure = null,

    const Err = error{ Yaml, Semantic, OutOfMemory };

    fn nthToken(c: *const Composer, kind: TokenKind, n: usize) ?Token {
        var seen: usize = 0;
        for (c.sc.tokens.items) |t| if (t.kind == kind) {
            if (seen == n) return t;
            seen += 1;
        };
        return null;
    }

    fn fail(c: *Composer, reason: []const u8, index: usize) Err {
        c.failure = .{ .reason = reason, .index = index };
        return error.Semantic;
    }

    /// False when the stream holds more than one document.
    fn document(c: *Composer, root: *Value) Err!bool {
        var ev = try c.ps.next();
        if (ev.kind == .stream_start) ev = try c.ps.next();
        if (ev.kind != .document_start) return true;
        root.* = try c.node(try c.ps.next());
        _ = try c.ps.next();
        const after = try c.ps.next();
        return after.kind != .document_start;
    }

    fn node(c: *Composer, ev: yparse.Event) Err!Value {
        const a = c.a;
        switch (ev.kind) {
            .alias => {
                const ord = c.alias_ord;
                c.alias_ord += 1;
                const name = ev.anchor orelse "";
                if (c.anchors.get(name)) |v| return v;
                const at = if (c.nthToken(.alias, ord)) |t| t.end.index else 0;
                return c.fail(try std.fmt.allocPrint(a, "unidentified alias \"{s}\"", .{name}), at);
            },
            .scalar => {
                const synthetic = ev.style == .plain and ev.value.len == 0 and ev.tag == null;
                if (!synthetic) {
                    c.last_ord = c.scalar_ord;
                    c.scalar_ord += 1;
                }
                const v: Value = if (ev.tag) |t| try explicitTag(a, t, ev.value) else if (ev.style == .plain) try resolvePlain(a, ev.value) else .{ .string = ev.value };
                if (ev.anchor) |name| try c.anchors.put(a, name, v);
                return v;
            },
            .sequence_start => {
                var arr = json.Array.init(a);
                while (true) {
                    const n = try c.ps.next();
                    if (n.kind == .sequence_end) break;
                    try arr.append(try c.node(n));
                }
                const v: Value = .{ .array = arr };
                if (ev.anchor) |name| try c.anchors.put(a, name, v);
                return v;
            },
            .mapping_start => {
                var obj: json.ObjectMap = .empty;
                while (true) {
                    const k = try c.ps.next();
                    if (k.kind == .mapping_end) break;
                    const key_value = try c.node(k);
                    const key_ord: ?usize = if (k.kind == .scalar and !(k.style == .plain and k.value.len == 0 and k.tag == null)) c.last_ord else null;
                    const key = try keyString(a, key_value);
                    if (obj.contains(key)) {
                        const at = if (key_ord) |o| (if (c.nthToken(.scalar, o)) |t| t.start.index else 0) else 0;
                        return c.fail("duplicated mapping key", at);
                    }
                    const value = try c.node(try c.ps.next());
                    try obj.put(a, key, value);
                }
                const v: Value = .{ .object = obj };
                if (ev.anchor) |name| try c.anchors.put(a, name, v);
                return v;
            },
            else => return .null,
        }
    }
};

const LineCol = struct { line: usize, col: usize };

fn lineCol(src: []const u8, index: usize) LineCol {
    var line: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < index and i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            start = i + 1;
        } else if (src[i] == '\r') {
            if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
            line += 1;
            start = i + 1;
        }
    }
    return .{ .line = line, .col = errors.utf16Len(src[start..@min(index, src.len)]) };
}

const Line = struct { str: []const u8, pos: usize };

fn snippetLine(a: Allocator, buffer: []const u8, line_start: usize, line_end: usize, position: isize, max_len: usize) Allocator.Error!Line {
    var head: []const u8 = "";
    var tail: []const u8 = "";
    const half: isize = @as(isize, @intCast(max_len / 2)) - 1;
    var start: isize = @intCast(line_start);
    var end: isize = @intCast(line_end);
    if (position - start > half) {
        head = " ... ";
        start = position - half + @as(isize, @intCast(head.len));
    }
    if (end - position > half) {
        tail = " ...";
        end = position + half - @as(isize, @intCast(tail.len));
    }
    const s: usize = @intCast(@max(start, 0));
    const e: usize = @intCast(@max(@min(end, @as(isize, @intCast(buffer.len))), @as(isize, @intCast(s))));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, head);
    for (buffer[s..e]) |c| if (c == '\t') try out.appendSlice(a, "\u{2192}") else try out.append(a, c);
    try out.appendSlice(a, tail);
    return .{ .str = out.items, .pos = @intCast(position - start + @as(isize, @intCast(head.len))) };
}

fn padStart(a: Allocator, n: usize, width: usize) Allocator.Error![]const u8 {
    const digits = try std.fmt.allocPrint(a, "{d}", .{n});
    if (digits.len >= width) return digits;
    const out = try a.alloc(u8, width);
    @memset(out[0 .. width - digits.len], ' ');
    @memcpy(out[width - digits.len ..], digits);
    return out;
}

/// js-yaml's `makeSnippet` with its default options (indent 1, 3 lines before, 2 after, 79 columns).
fn makeSnippet(a: Allocator, buffer: []const u8, position: usize, mark_line: usize) Allocator.Error![]const u8 {
    var starts: std.ArrayList(usize) = .empty;
    var ends: std.ArrayList(usize) = .empty;
    try starts.append(a, 0);
    var found: ?usize = null;
    var i: usize = 0;
    while (i < buffer.len) : (i += 1) {
        const c = buffer[i];
        if (c != '\n' and c != '\r' and c != 0) continue;
        const at = i;
        if (c == '\r' and i + 1 < buffer.len and buffer[i + 1] == '\n') i += 1;
        try ends.append(a, at);
        try starts.append(a, i + 1);
        if (position <= at and found == null) found = starts.items.len - 2;
    }
    const cur = found orelse starts.items.len - 1;
    const end_of = struct {
        fn f(e: []const usize, buf: []const u8, k: usize) usize {
            return if (k < e.len) e[k] else buf.len;
        }
    }.f;
    const no_len = (try std.fmt.allocPrint(a, "{d}", .{@min(mark_line + 2, ends.items.len)})).len;
    const max_line = 79 - (1 + no_len + 3);
    var result: std.ArrayList(u8) = .empty;

    var before: std.ArrayList([]const u8) = .empty;
    var k: usize = 1;
    while (k <= 3) : (k += 1) {
        if (cur < k) break;
        const rel: isize = @as(isize, @intCast(position)) - @as(isize, @intCast(starts.items[cur] - starts.items[cur - k]));
        const l = try snippetLine(a, buffer, starts.items[cur - k], end_of(ends.items, buffer, cur - k), rel, max_line);
        try before.append(a, try std.fmt.allocPrint(a, " {s} | {s}\n", .{ try padStart(a, mark_line - k + 1, no_len), l.str }));
    }
    var b = before.items.len;
    while (b > 0) {
        b -= 1;
        try result.appendSlice(a, before.items[b]);
    }

    const l = try snippetLine(a, buffer, starts.items[cur], end_of(ends.items, buffer, cur), @intCast(position), max_line);
    try result.print(a, " {s} | {s}\n", .{ try padStart(a, mark_line + 1, no_len), l.str });
    try result.appendNTimes(a, '-', 1 + no_len + 3 + l.pos);
    try result.appendSlice(a, "^\n");

    k = 1;
    while (k <= 2) : (k += 1) {
        if (cur + k >= ends.items.len) break;
        const rel: isize = @as(isize, @intCast(position)) - (@as(isize, @intCast(starts.items[cur])) - @as(isize, @intCast(starts.items[cur + k])));
        const al = try snippetLine(a, buffer, starts.items[cur + k], end_of(ends.items, buffer, cur + k), rel, max_line);
        try result.print(a, " {s} | {s}\n", .{ try padStart(a, mark_line + k + 1, no_len), al.str });
    }
    if (result.items.len > 0 and result.items[result.items.len - 1] == '\n') _ = result.pop();
    return result.items;
}

fn describe(a: Allocator, src: []const u8, reason: []const u8, index: usize) Allocator.Error![]const u8 {
    const lc = lineCol(src, index);
    return std.fmt.allocPrint(a, "{s} ({d}:{d})\n\n{s}", .{ reason, lc.line + 1, lc.col + 1, try makeSnippet(a, src, index, lc.line) });
}

/// Maps the libyaml-style error of the scanner to the reason js-yaml gives for the same mistake.
fn explainYaml(a: Allocator, src: []const u8, sc: *const Scanner) Allocator.Error![]const u8 {
    const e = sc.err;
    const here: usize = if (sc.head < sc.tokens.items.len) sc.tokens.items[sc.head].start.index else e.mark.index;
    const p = e.problem;
    if (std.mem.eql(u8, p, "mapping values are not allowed in this context")) return describe(a, src, "bad indentation of a mapping entry", e.mark.index);
    if (std.mem.eql(u8, p, "did not find expected key")) return describe(a, src, "bad indentation of a mapping entry", here);
    if (std.mem.startsWith(u8, p, "found unexpected end of stream") and e.context != null and std.mem.indexOf(u8, e.context.?, "quoted scalar") != null) {
        const kind = if (e.mark.index < src.len and src[e.mark.index] == '"') "double" else "single";
        return describe(a, src, try std.fmt.allocPrint(a, "unexpected end of the stream within a {s} quoted scalar", .{kind}), src.len);
    }
    if (std.mem.startsWith(u8, p, "did not find expected ',' or ") or std.mem.eql(u8, p, "did not find expected node content")) {
        const at_end = sc.head >= sc.tokens.items.len or sc.tokens.items[sc.head].kind == .stream_end or sc.tokens.items[sc.head].kind == .block_end;
        if (at_end) return describe(a, src, "unexpected end of the stream within a flow collection", src.len);
    }
    if (std.mem.eql(u8, p, "did not find expected '-' indicator") or std.mem.eql(u8, p, "did not find expected <document start>")) {
        return describe(a, src, "end of the stream or a document separator is expected", here);
    }
    if (std.mem.eql(u8, p, "found character that cannot start any token") and e.mark.index < src.len and src[e.mark.index] == '\t') {
        return describe(a, src, "tab characters must not be used in indentation", e.mark.index);
    }
    return describe(a, src, p, e.mark.index);
}

/// `yaml.load(text, { schema: yaml.JSON_SCHEMA })`; the error text is js-yaml's `message`.
pub fn load(a: Allocator, text: []const u8) Allocator.Error!Result {
    var src = text;
    if (std.mem.startsWith(u8, src, "\xef\xbb\xbf")) src = src[3..];
    if (src.len > 0 and src[src.len - 1] != '\n' and src[src.len - 1] != '\r') src = try std.mem.concat(a, u8, &.{ src, "\n" });
    var sc: Scanner = .{ .a = a, .src = src };
    var ps: yparse.Parser = .{ .sc = &sc, .a = a };
    var c: Composer = .{ .a = a, .sc = &sc, .ps = &ps };
    var root: Value = .null;
    const single = c.document(&root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Semantic => {
            const f = c.failure.?;
            return .{ .err = try describe(a, src, f.reason, f.index) };
        },
        error.Yaml => return .{ .err = try explainYaml(a, src, &sc) },
    };
    if (!single) return .{ .err = "expected a single document in the stream, but found more" };
    return .{ .ok = root };
}

fn expectLoad(src: []const u8, want_err: ?[]const u8) !Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const r = try load(a, src);
    if (want_err) |w| {
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings(w, r.err);
        return .null;
    }
    try std.testing.expect(r == .ok);
    return r.ok;
}

test "scalars are typed like js-yaml's JSON schema" {
    const v = try expectLoad("a: 0x1F\nb: 017\nc: \"12\"\nd: .inf\ne: true\nf: ~\ng: 1_000\nh: 1e3\ni: yes\nj: '0o17'\nk: 0o17\nl: 5.\n", null);
    const o = v.object;
    try std.testing.expectEqual(@as(i64, 31), o.get("a").?.integer);
    try std.testing.expectEqual(@as(i64, 17), o.get("b").?.integer);
    try std.testing.expectEqualStrings("12", o.get("c").?.string);
    try std.testing.expect(std.math.isInf(o.get("d").?.float));
    try std.testing.expect(o.get("e").?.bool);
    try std.testing.expect(o.get("f").? == .null);
    try std.testing.expectEqual(@as(i64, 1000), o.get("g").?.integer);
    try std.testing.expectEqual(@as(f64, 1000), o.get("h").?.float);
    try std.testing.expectEqualStrings("yes", o.get("i").?.string);
    try std.testing.expectEqualStrings("0o17", o.get("j").?.string);
    try std.testing.expectEqual(@as(i64, 15), o.get("k").?.integer);
    try std.testing.expectEqual(@as(f64, 5), o.get("l").?.float);
}

test "errors read like js-yaml's" {
    _ = try expectLoad("a:\n  b: 1\n c: 2", "bad indentation of a mapping entry (3:2)\n\n 1 | a:\n 2 |   b: 1\n 3 |  c: 2\n------^");
    _ = try expectLoad("a: 1\na: 2", "duplicated mapping key (2:1)\n\n 1 | a: 1\n 2 | a: 2\n-----^");
    _ = try expectLoad("a: \"unterminated", "unexpected end of the stream within a double quoted scalar (2:1)\n\n 1 | a: \"unterminated\n 2 | \n-----^");
    _ = try expectLoad("a: 'unterminated", "unexpected end of the stream within a single quoted scalar (2:1)\n\n 1 | a: 'unterminated\n 2 | \n-----^");
    _ = try expectLoad("a: 1\n  b: 2", "bad indentation of a mapping entry (2:4)\n\n 1 | a: 1\n 2 |   b: 2\n--------^");
    _ = try expectLoad("a: b: c", "bad indentation of a mapping entry (1:5)\n\n 1 | a: b: c\n---------^");
    _ = try expectLoad("a: [1, 2", "unexpected end of the stream within a flow collection (2:1)\n\n 1 | a: [1, 2\n 2 | \n-----^");
    _ = try expectLoad("a:\n\tb: 1", "tab characters must not be used in indentation (2:1)\n\n 1 | a:\n 2 | \u{2192}b: 1\n-----^");
    _ = try expectLoad("- a\nb: 1", "end of the stream or a document separator is expected (2:1)\n\n 1 | - a\n 2 | b: 1\n-----^");
    _ = try expectLoad("a: *x", "unidentified alias \"x\" (1:6)\n\n 1 | a: *x\n----------^");
}

const scalar_corpus = testdata.file("mermaid/preprocess/yaml_scalars.json");

test "scalar typing equals js-yaml's on the captured corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try json.parseFromSliceLeaky(Value, a, scalar_corpus, .{});
    for (doc.array.items) |item| {
        const src = item.object.get("src").?.string;
        const r = try load(a, src);
        try std.testing.expect(r == .ok);
        const v = r.ok.object.get("v").?;
        const want_type = item.object.get("type").?.string;
        const want = item.object.get("value").?.string;
        const got_type: []const u8 = switch (v) {
            .null => "null",
            .bool => "boolean",
            .integer, .float => "number",
            .string => "string",
            else => "other",
        };
        std.testing.expectEqualStrings(want_type, got_type) catch |e| {
            std.debug.print("type of {s}\n", .{src});
            return e;
        };
        const text: []const u8 = switch (v) {
            .null => "null",
            .bool => |b| if (b) "true" else "false",
            .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
            .float => |f| try numfmt.js(a, f),
            .string => |s| s,
            else => "",
        };
        std.testing.expectEqualStrings(want, text) catch |e| {
            std.debug.print("value of {s}\n", .{src});
            return e;
        };
    }
}
