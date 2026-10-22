const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("yaml_scan.zig");
const yparse = @import("yaml_parse.zig");
const unicode = @import("unicode.zig");

pub const Scalar = struct { text: []const u8, falsy: bool = false };
pub const Value = union(enum) { scalar: Scalar, seq: []const Value, map: []const Pair };
pub const Pair = struct { key: []const u8, value: Value };
/// The whole text GitHub shows in its error box.
pub const Failure = struct { message: []const u8 };
pub const Result = union(enum) { ok: Value, err: Failure, other };

const Err = error{ Syntax, Alias, Disallowed, Generic, OutOfMemory };

const RawScalar = struct { value: []const u8, tag: ?[]const u8, quoted: bool };
const Node = union(enum) {
    scalar: RawScalar,
    seq: struct { tag: ?[]const u8, items: []const Node },
    map: struct { tag: ?[]const u8, items: []const Node },
    alias,
};

const Obj = union(enum) {
    null_,
    boolean: bool,
    int: []const u8,
    float: []const u8,
    str: []const u8,
    sym: []const u8,
    time: []const u8,
    seq: []const Obj,
    map: []const OPair,
};
const OPair = struct { key: Obj, value: Obj };

pub fn parse(a: Allocator, src: []const u8) Allocator.Error!Result {
    if (readerError(src)) |problem| {
        return .{ .err = .{ .message = try std.fmt.allocPrint(a, "Error in user YAML: (<unknown>): {s} at line 1 column 1", .{problem}) } };
    }
    var sc: scan.Scanner = .{ .a = a, .src = src };
    var ps: yparse.Parser = .{ .sc = &sc, .a = a };
    var c: Composer = .{ .a = a, .ps = &ps };
    var failure: ?[]const u8 = null;
    const root = c.document() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Yaml => blk: {
            failure = try syntaxMessage(a, sc.err);
            break :blk null;
        },
    };
    if (failure) |m| return .{ .err = .{ .message = m } };
    const node = root orelse return .other;

    var r: Reviver = .{ .a = a };
    const obj = r.revive(node) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Alias => return .{ .err = .{ .message = "Error in user YAML: Alias parsing is not enabled." } },
        error.Disallowed => return .{ .err = .{ .message = try std.fmt.allocPrint(a, "Error in user YAML: Tried to load unspecified class: {s}", .{r.class}) } },
        error.Generic, error.Syntax => return .{ .err = .{ .message = "Error in parsing user YAML" } },
    };
    if (obj != .map) return .other;
    return .{ .ok = try display(a, obj) };
}

fn syntaxMessage(a: Allocator, e: scan.ErrInfo) Allocator.Error![]const u8 {
    const ctx = e.context orelse "";
    return std.fmt.allocPrint(a, "Error in user YAML: (<unknown>): {s}{s}{s} at line {d} column {d}", .{
        e.problem, if (ctx.len > 0) " " else "", ctx, e.mark.line + 1, e.mark.column + 1,
    });
}

const Composer = struct {
    a: Allocator,
    ps: *yparse.Parser,

    fn document(c: *Composer) scan.Fail!?Node {
        var ev = try c.ps.next();
        if (ev.kind == .stream_start) ev = try c.ps.next();
        if (ev.kind != .document_start) return null;
        const root = try c.node(try c.ps.next());
        _ = try c.ps.next();
        return root;
    }

    fn node(c: *Composer, ev: yparse.Event) scan.Fail!Node {
        switch (ev.kind) {
            .alias => return .alias,
            .scalar => return .{ .scalar = .{ .value = ev.value, .tag = ev.tag, .quoted = ev.quoted_implicit } },
            .sequence_start => {
                var items: std.ArrayList(Node) = .empty;
                while (true) {
                    const n = try c.ps.next();
                    if (n.kind == .sequence_end) break;
                    try items.append(c.a, try c.node(n));
                }
                return .{ .seq = .{ .tag = ev.tag, .items = items.items } };
            },
            .mapping_start => {
                var items: std.ArrayList(Node) = .empty;
                while (true) {
                    const k = try c.ps.next();
                    if (k.kind == .mapping_end) break;
                    try items.append(c.a, try c.node(k));
                    try items.append(c.a, try c.node(try c.ps.next()));
                }
                return .{ .map = .{ .tag = ev.tag, .items = items.items } };
            },
            else => return .{ .scalar = .{ .value = "", .tag = null, .quoted = false } },
        }
    }
};

fn tagIs(tag: ?[]const u8, names: []const []const u8) bool {
    const t = tag orelse return false;
    for (names) |n| if (std.mem.eql(u8, t, n)) return true;
    return false;
}

const Reviver = struct {
    a: Allocator,
    class: []const u8 = "",

    fn disallow(r: *Reviver, class: []const u8) Err {
        r.class = class;
        return error.Disallowed;
    }

    fn rubyClass(r: *Reviver, tag: []const u8) ?[]const u8 {
        _ = r;
        const prefixes = [_][]const u8{ "!ruby/object:", "!ruby/struct:", "!ruby/hash:", "!ruby/array:", "!ruby/string:", "!ruby/exception:", "!ruby/class:" };
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, tag, p)) return tag[p.len..];
        }
        if (std.mem.startsWith(u8, tag, "!ruby/regexp")) return "Regexp";
        if (std.mem.startsWith(u8, tag, "!ruby/range")) return "Range";
        if (std.mem.startsWith(u8, tag, "!ruby/sym")) return "Symbol";
        if (std.mem.startsWith(u8, tag, "!ruby/object")) return "Object";
        if (std.mem.startsWith(u8, tag, "!ruby/struct")) return "Struct";
        if (std.mem.startsWith(u8, tag, "!ruby/hash")) return "Hash";
        if (std.mem.startsWith(u8, tag, "!ruby/array")) return "Array";
        if (std.mem.startsWith(u8, tag, "!ruby/class")) return "Class";
        if (std.mem.startsWith(u8, tag, "!ruby/module")) return "Module";
        return null;
    }

    fn revive(r: *Reviver, n: Node) Err!Obj {
        switch (n) {
            .alias => return error.Alias,
            .scalar => |s| return r.scalar(s),
            .seq => |s| {
                if (s.tag) |t| {
                    if (tagIs(t, &.{ "!omap", "tag:yaml.org,2002:omap" })) return error.Generic;
                    if (r.rubyClass(t)) |cls| return r.disallow(cls);
                }
                var out: std.ArrayList(Obj) = .empty;
                for (s.items) |it| try out.append(r.a, try r.revive(it));
                return .{ .seq = out.items };
            },
            .map => |m| {
                if (m.tag) |t| {
                    if (tagIs(t, &.{ "!set", "tag:yaml.org,2002:set" })) return r.disallow("Psych::Set");
                    if (r.rubyClass(t)) |cls| return r.disallow(cls);
                }
                var out: std.ArrayList(OPair) = .empty;
                var i: usize = 0;
                while (i < m.items.len) : (i += 2) {
                    const kn = m.items[i];
                    const vn = m.items[i + 1];
                    const key = try r.revive(kn);
                    const is_merge = key == .str and std.mem.eql(u8, key.str, "<<") and !(kn == .scalar and tagIs(kn.scalar.tag, &.{"tag:yaml.org,2002:str"}));
                    if (is_merge and (vn == .map or vn == .alias)) {
                        const val = try r.revive(vn);
                        if (val == .map) {
                            for (val.map) |p| try put(r.a, &out, p.key, p.value);
                            continue;
                        }
                        try put(r.a, &out, key, val);
                    } else if (is_merge and vn == .seq) {
                        const val = try r.revive(vn);
                        var merged: std.ArrayList(OPair) = .empty;
                        var ok = true;
                        var j = val.seq.len;
                        while (j > 0) {
                            j -= 1;
                            if (val.seq[j] != .map) {
                                ok = false;
                                break;
                            }
                            for (val.seq[j].map) |p| try put(r.a, &merged, p.key, p.value);
                        }
                        if (ok) {
                            for (merged.items) |p| try put(r.a, &out, p.key, p.value);
                        } else try put(r.a, &out, key, val);
                    } else {
                        const val = try r.revive(vn);
                        try put(r.a, &out, key, val);
                    }
                }
                return .{ .map = out.items };
            },
        }
    }

    fn scalar(r: *Reviver, s: RawScalar) Err!Obj {
        if (s.quoted) return .{ .str = s.value };
        const tag = s.tag orelse return r.tokenize(s.value);
        if (tagIs(tag, &.{ "!binary", "tag:yaml.org,2002:binary" })) return .{ .str = try decodeBase64(r.a, s.value) };
        if (tagIs(tag, &.{ "!str", "tag:yaml.org,2002:str" })) return .{ .str = s.value };
        if (std.mem.startsWith(u8, tag, "!ruby/sym")) return .{ .sym = s.value };
        if (r.rubyClass(tag)) |cls| return r.disallow(cls);
        if (tagIs(tag, &.{ "!float", "tag:yaml.org,2002:float" })) {
            const v = try r.tokenize(s.value);
            return switch (v) {
                .float => v,
                .int => |i| .{ .float = try std.fmt.allocPrint(r.a, "{s}.0", .{i}) },
                .str => |str| blk: {
                    const f = rubyFloat(str) orelse return error.Generic;
                    break :blk .{ .float = try formatFloat(r.a, f) };
                },
                else => error.Generic,
            };
        }
        return r.tokenize(s.value);
    }

    fn tokenize(r: *Reviver, string: []const u8) Err!Obj {
        if (string.len == 0) return .null_;
        if (startsLikeString(string) or std.mem.indexOfScalar(u8, string, '\n') != null) {
            if (string.len > 5) return .{ .str = string };
            const c0 = std.ascii.toLower(string[0]);
            if (std.mem.indexOfScalar(u8, "ytonf~", c0) == null) return .{ .str = string };
            if (std.mem.eql(u8, string, "~") or std.ascii.eqlIgnoreCase(string, "null")) return .null_;
            for ([_][]const u8{ "yes", "true", "on" }) |w| if (std.ascii.eqlIgnoreCase(string, w)) return .{ .boolean = true };
            for ([_][]const u8{ "no", "false", "off" }) |w| if (std.ascii.eqlIgnoreCase(string, w)) return .{ .boolean = false };
            return .{ .str = string };
        }
        if (matchTime(string)) {
            return (try parseTime(r.a, string)) orelse .{ .str = string };
        }
        if (matchDate(r.a, string)) |d| {
            return if (d) |text| .{ .time = text } else .{ .str = string };
        }
        if (std.ascii.eqlIgnoreCase(string, ".inf") or std.ascii.eqlIgnoreCase(string, "+.inf")) return .{ .float = "Infinity" };
        if (std.ascii.eqlIgnoreCase(string, "-.inf")) return .{ .float = "-Infinity" };
        if (std.ascii.eqlIgnoreCase(string, ".nan")) return .{ .float = "NaN" };
        if (string.len >= 2 and string[0] == ':') {
            const rest = string[1..];
            if ((rest[0] == '"' or rest[0] == '\'') and rest.len >= 2) {
                if (std.mem.lastIndexOfScalar(u8, rest[1..], rest[0])) |e| {
                    const inner = rest[1 .. 1 + e];
                    return .{ .sym = if (inner.len > 0 and inner[0] == ':') inner[1..] else inner };
                }
            }
            return .{ .sym = rest };
        }
        if (sexagesimal(string)) |kind| return r.sexagesimalValue(string, kind);
        if (matchFloat(string)) {
            if (isLoneDot(string)) return .{ .str = string };
            const cleaned = try cleanFloat(r.a, string);
            const f = std.fmt.parseFloat(f64, cleaned) catch return .{ .str = string };
            return .{ .float = try formatFloat(r.a, f) };
        }
        if (try parseInt(r.a, string)) |i| return .{ .int = i };
        return .{ .str = string };
    }

    fn sexagesimalValue(r: *Reviver, string: []const u8, kind: u8) Err!Obj {
        var parts = std.mem.splitScalar(u8, string, ':');
        var e: i64 = 0;
        if (kind == 'i') {
            var total: i64 = 0;
            while (parts.next()) |p| : (e += 1) {
                const n = rubyToI(p);
                const mult: i64 = std.math.pow(i64, 60, @intCast(@abs(e - 2)));
                total += n * mult;
            }
            return .{ .int = try std.fmt.allocPrint(r.a, "{d}", .{total}) };
        }
        var total: f64 = 0;
        while (parts.next()) |p| : (e += 1) {
            const n = rubyToF(p);
            const mult: f64 = @floatFromInt(std.math.pow(i64, 60, @intCast(@abs(e - 2))));
            total += n * mult;
        }
        return .{ .float = try formatFloat(r.a, total) };
    }
};

fn put(a: Allocator, out: *std.ArrayList(OPair), key: Obj, value: Obj) Allocator.Error!void {
    for (out.items) |*p| {
        if (objEql(p.key, key)) {
            p.value = value;
            return;
        }
    }
    try out.append(a, .{ .key = key, .value = value });
}

fn objEql(x: Obj, y: Obj) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null_ => true,
        .boolean => |b| b == y.boolean,
        .int => |s| std.mem.eql(u8, s, y.int),
        .float => |s| std.mem.eql(u8, s, y.float) and !std.mem.eql(u8, s, "NaN"),
        .str => |s| std.mem.eql(u8, s, y.str),
        .sym => |s| std.mem.eql(u8, s, y.sym),
        .time => |s| std.mem.eql(u8, s, y.time),
        .seq => |s| blk: {
            if (s.len != y.seq.len) break :blk false;
            for (s, y.seq) |p, q| if (!objEql(p, q)) break :blk false;
            break :blk true;
        },
        .map => |s| blk: {
            if (s.len != y.map.len) break :blk false;
            for (s, y.map) |p, q| if (!objEql(p.key, q.key) or !objEql(p.value, q.value)) break :blk false;
            break :blk true;
        },
    };
}

fn startsLikeString(s: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    const first = it.nextCodepoint() orelse return false;
    if (inStringClass(first)) return true;
    if (first != '.' and first != ':' and first != '-' and !(first >= '0' and first <= '9')) {
        const second = it.nextCodepoint() orelse return false;
        return inStringClass(second);
    }
    return false;
}

fn inStringClass(cp: u21) bool {
    if (cp < 128) {
        const c: u8 = @intCast(cp);
        return std.ascii.isAlphabetic(c) or std.mem.indexOfScalar(u8, "_ \t\r\n\x0b\x0c!@#$%^&*(){}<>|/\\~;=", c) != null;
    }
    return unicode.isLetter(cp) or unicode.isWhitespace(cp);
}

fn rubyToI(s: []const u8) i64 {
    var v: i64 = 0;
    var neg = false;
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] == '_') continue;
        if (!std.ascii.isDigit(s[i])) break;
        v = v * 10 + (s[i] - '0');
    }
    return if (neg) -v else v;
}

fn rubyToF(s: []const u8) f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch 0;
}

fn sexagesimal(s: []const u8) ?u8 {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return null;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    var groups: usize = 0;
    while (i < s.len and s[i] == ':') {
        i += 1;
        const st = i;
        if (i < s.len and s[i] >= '0' and s[i] <= '5') i += 1;
        if (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == st or i - st > 2) return null;
        groups += 1;
    }
    if (groups < 1 or groups > 2) return null;
    if (i == s.len) return 'i';
    if (s[i] == '.') {
        i += 1;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
        if (i == s.len) return 'f';
    }
    return null;
}

fn matchFloat(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    if (i < s.len and std.ascii.isDigit(s[i])) {
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_' or s[i] == ',')) i += 1;
    }
    if (i >= s.len or s[i] != '.') return false;
    i += 1;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i >= s.len or (s[i] != '-' and s[i] != '+')) return false;
        i += 1;
        const st = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == st) return false;
    }
    return i == s.len;
}

fn isLoneDot(s: []const u8) bool {
    return std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "+.") or std.mem.eql(u8, s, "-.");
}

fn cleanFloat(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (c != ',' and c != '_') try out.append(a, c);
    var res: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        if (out.items[i] == '.' and (i + 1 == out.items.len or out.items[i + 1] == 'e' or out.items[i + 1] == 'E')) continue;
        try res.append(a, out.items[i]);
    }
    if (res.items.len > 0 and res.items[0] == '.') try res.insert(a, 0, '0');
    if (res.items.len > 1 and (res.items[0] == '-' or res.items[0] == '+') and res.items[1] == '.') try res.insert(a, 1, '0');
    return res.items;
}

fn rubyFloat(s: []const u8) ?f64 {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch null;
}

pub fn formatFloat(a: Allocator, f: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f < 0) "-Infinity" else "Infinity";
    if (f == 0) return if (std.math.signbit(f)) "-0.0" else "0.0";
    var buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&buf, "{e}", .{@abs(f)}) catch return "0.0";
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    const mant = sci[0..e_at];
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch 0;
    var digits: std.ArrayList(u8) = .empty;
    for (mant) |c| if (c != '.') try digits.append(a, c);
    var out: std.ArrayList(u8) = .empty;
    if (f < 0) try out.append(a, '-');
    if (exp >= -4 and exp < 16) {
        if (exp < 0) {
            try out.appendSlice(a, "0.");
            try out.appendNTimes(a, '0', @intCast(-exp - 1));
            try out.appendSlice(a, digits.items);
        } else {
            const int_len: usize = @intCast(exp + 1);
            if (digits.items.len <= int_len) {
                try out.appendSlice(a, digits.items);
                try out.appendNTimes(a, '0', int_len - digits.items.len);
                try out.appendSlice(a, ".0");
            } else {
                try out.appendSlice(a, digits.items[0..int_len]);
                try out.append(a, '.');
                try out.appendSlice(a, digits.items[int_len..]);
            }
        }
    } else {
        try out.append(a, digits.items[0]);
        try out.append(a, '.');
        if (digits.items.len > 1) try out.appendSlice(a, digits.items[1..]) else try out.append(a, '0');
        try out.print(a, "e{s}{d:0>2}", .{ if (exp < 0) "-" else "+", @abs(exp) });
    }
    return out.items;
}

fn parseInt(a: Allocator, s: []const u8) Allocator.Error!?[]const u8 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    const body = s[i..];
    if (body.len == 0) return null;
    var base: u8 = 10;
    var digits: []const u8 = body;
    var allowed: []const u8 = "0123456789,_";
    if (body.len > 2 and body[0] == '0' and body[1] == 'b') {
        base = 2;
        digits = body[2..];
        allowed = "01_,";
    } else if (body.len > 2 and body[0] == '0' and body[1] == 'x') {
        base = 16;
        digits = body[2..];
        allowed = "0123456789abcdefABCDEF_,";
    } else if (body.len > 1 and body[0] == '0') {
        base = 8;
        digits = body[1..];
        allowed = "01234567_,";
    } else {
        if (body[0] == '0' and body.len == 1) {
            return "0";
        }
        if (body[0] < '1' or body[0] > '9') return null;
        var k: usize = 1;
        while (k < body.len) : (k += 1) {
            if (std.ascii.isDigit(body[k])) continue;
            if ((body[k] == ',' or body[k] == '_') and k + 1 < body.len and std.ascii.isDigit(body[k + 1])) continue;
            return null;
        }
    }
    var clean: std.ArrayList(u8) = .empty;
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (std.mem.indexOfScalar(u8, allowed, c) == null) return null;
        if (c != ',' and c != '_') try clean.append(a, c);
    }
    if (clean.items.len == 0) return null;
    const value = std.fmt.parseInt(u128, clean.items, base) catch {
        // Beyond 128 bits only decimal digits are kept as written.
        if (base != 10) return null;
        const stripped = std.mem.trimStart(u8, clean.items, "0");
        return try std.fmt.allocPrint(a, "{s}{s}", .{ if (neg and stripped.len > 0) "-" else "", if (stripped.len == 0) "0" else stripped });
    };
    return try std.fmt.allocPrint(a, "{s}{d}", .{ if (neg and value != 0) "-" else "", value });
}

fn decodeBase64(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var clean: std.ArrayList(u8) = .empty;
    for (s) |c| if (!std.ascii.isWhitespace(c)) try clean.append(a, c);
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(clean.items) catch return "";
    const out = try a.alloc(u8, size);
    dec.decode(out, clean.items) catch return "";
    return out;
}

// ---- timestamps ----

fn digitsAt(s: []const u8, i: usize, min: usize, max: usize) ?usize {
    var n: usize = 0;
    while (i + n < s.len and n < max and std.ascii.isDigit(s[i + n])) n += 1;
    return if (n >= min) n else null;
}

fn matchTime(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    if (digitsAt(s, i, 4, 4) == null) return false;
    i += 4;
    if (i >= s.len or s[i] != '-') return false;
    i += 1;
    const m = digitsAt(s, i, 1, 2) orelse return false;
    i += m;
    if (i >= s.len or s[i] != '-') return false;
    i += 1;
    const d = digitsAt(s, i, 1, 2) orelse return false;
    i += d;
    if (i < s.len and (s[i] == 'T' or s[i] == 't')) {
        i += 1;
    } else {
        const st = i;
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i == st) return false;
    }
    const h = digitsAt(s, i, 1, 2) orelse return false;
    i += h;
    if (i >= s.len or s[i] != ':') return false;
    i += 1;
    if (digitsAt(s, i, 2, 2) == null) return false;
    i += 2;
    if (i >= s.len or s[i] != ':') return false;
    i += 1;
    if (digitsAt(s, i, 2, 2) == null) return false;
    i += 2;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i == s.len) return true;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i < s.len and s[i] == 'Z') {
        i += 1;
    } else if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        i += 1;
        const oh = digitsAt(s, i, 1, 2) orelse return false;
        i += oh;
        if (i < s.len and s[i] == ':') i += 1;
        if (digitsAt(s, i, 2, 2)) |_| i += 2;
    } else return false;
    return i == s.len;
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn nthSunday(year: i64, month: i64, n: i64) i64 {
    const first = daysFromCivil(year, month, 1);
    const wd = @mod(first + 4, 7);
    const first_sun = first + @mod(7 - wd, 7);
    return first_sun + (n - 1) * 7;
}

fn lastSunday(year: i64, month: i64) i64 {
    const next_first = daysFromCivil(if (month == 12) year + 1 else year, if (month == 12) 1 else month + 1, 1);
    const wd = @mod(next_first - 1 + 4, 7);
    return next_first - 1 - wd;
}

fn pacificOffset(epoch: i64) i64 {
    const days = @divFloor(epoch, 86400);
    const year = civilFromDays(days).y;
    if (year < 1987) return -8 * 3600;
    // SAFETY: start and end are assigned in both branches below
    var start: i64 = undefined;
    // SAFETY: assigned in both branches below
    var end: i64 = undefined;
    if (year >= 2007) {
        start = nthSunday(year, 3, 2) * 86400 + 10 * 3600;
        end = nthSunday(year, 11, 1) * 86400 + 9 * 3600;
    } else {
        start = nthSunday(year, 4, 1) * 86400 + 10 * 3600;
        end = lastSunday(year, 10) * 86400 + 9 * 3600;
    }
    return if (epoch >= start and epoch < end) -7 * 3600 else -8 * 3600;
}

fn formatTime(a: Allocator, epoch_local: i64, suffix: []const u8) Allocator.Error![]const u8 {
    const days = @divFloor(epoch_local, 86400);
    const secs = @mod(epoch_local, 86400);
    const c = civilFromDays(days);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        @as(u64, @intCast(c.y)), @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)), @as(u64, @intCast(@divFloor(secs, 3600))), @as(u64, @intCast(@divFloor(@mod(secs, 3600), 60))), @as(u64, @intCast(@mod(secs, 60))), suffix,
    });
}

fn parseTime(a: Allocator, s: []const u8) Allocator.Error!?Obj {
    var i: usize = 0;
    var neg_year = false;
    if (s[i] == '-') {
        neg_year = true;
        i += 1;
    }
    const year = std.fmt.parseInt(i64, s[i .. i + 4], 10) catch return null;
    i += 5;
    const mn = digitsAt(s, i, 1, 2).?;
    const month = std.fmt.parseInt(i64, s[i .. i + mn], 10) catch return null;
    i += mn + 1;
    const dn = digitsAt(s, i, 1, 2).?;
    const day = std.fmt.parseInt(i64, s[i .. i + dn], 10) catch return null;
    i += dn;
    while (i < s.len and (s[i] == 'T' or s[i] == 't' or std.ascii.isWhitespace(s[i]))) i += 1;
    const hn = digitsAt(s, i, 1, 2).?;
    const hour = std.fmt.parseInt(i64, s[i .. i + hn], 10) catch return null;
    i += hn + 1;
    const minute = std.fmt.parseInt(i64, s[i .. i + 2], 10) catch return null;
    i += 3;
    const second = std.fmt.parseInt(i64, s[i .. i + 2], 10) catch return null;
    i += 2;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 24 or minute > 59 or second > 60) return null;
    if (hour == 24 and (minute != 0 or second != 0)) return null;
    const y = if (neg_year) -year else year;
    const epoch = daysFromCivil(y, month, day) * 86400 + hour * 3600 + minute * 60 + second;
    if (i >= s.len) {
        const off = pacificOffset(epoch);
        const label = try std.fmt.allocPrint(a, "{s}{d:0>2}{d:0>2}", .{ if (off < 0) "-" else "+", @divFloor(@abs(off), 3600), @divFloor(@mod(@abs(off), 3600), 60) });
        return .{ .time = try formatTime(a, epoch + off, label) };
    }
    if (s[i] == 'Z') return .{ .time = try formatTime(a, epoch, "UTC") };
    const sign: i64 = if (s[i] == '-') -1 else 1;
    i += 1;
    const oh = digitsAt(s, i, 1, 2).?;
    const off_h = std.fmt.parseInt(i64, s[i .. i + oh], 10) catch 0;
    i += oh;
    if (i < s.len and s[i] == ':') i += 1;
    const off_m: i64 = if (digitsAt(s, i, 2, 2) != null) (std.fmt.parseInt(i64, s[i .. i + 2], 10) catch 0) else 0;
    const label = try std.fmt.allocPrint(a, "{s}{d:0>2}{d:0>2}", .{ if (sign < 0) "-" else "+", @as(u64, @intCast(@abs(off_h))), @as(u64, @intCast(@abs(off_m))) });
    return .{ .time = try formatTime(a, epoch, label) };
}

/// null: not a date-shaped string; .some(null): date-shaped but invalid.
fn matchDate(a: Allocator, s: []const u8) ??[]const u8 {
    if (s.len < 8 or digitsAt(s, 0, 4, 4) == null or s[4] != '-') return null;
    var i: usize = 5;
    const mn = digitsAt(s, i, 1, 2) orelse return null;
    var month = std.fmt.parseInt(u32, s[i .. i + mn], 10) catch return null;
    if (mn == 2 and !(s[i] == '0' or (s[i] == '1' and s[i + 1] <= '2'))) {
        month = std.fmt.parseInt(u32, s[i .. i + 1], 10) catch return null;
        if (i + 1 >= s.len or s[i + 1] != '-') return null;
        i += 1;
    } else i += mn;
    if (i >= s.len or s[i] != '-') return null;
    i += 1;
    const dn = digitsAt(s, i, 1, 2) orelse return null;
    var day = std.fmt.parseInt(u32, s[i .. i + dn], 10) catch return null;
    if (dn == 2 and !(s[i] == '0' or s[i] == '1' or s[i] == '2' or (s[i] == '3' and s[i + 1] <= '1'))) {
        day = std.fmt.parseInt(u32, s[i .. i + 1], 10) catch return null;
        i += 1;
    } else i += dn;
    if (i != s.len) return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    if (month < 1 or month > 12) return @as(?[]const u8, null);
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    const dim = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > dim[month - 1]) return @as(?[]const u8, null);
    const out = std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), month, day }) catch return @as(?[]const u8, null);
    return @as(?[]const u8, out);
}

// ---- display ----

// Whitespace runs collapse as in HTML; control characters become U+FFFD.
fn collapse(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (space) try out.append(a, ' ');
        space = false;
        const w = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const cp: u21 = if (i + w <= s.len) (std.unicode.utf8Decode(s[i..][0..w]) catch c) else c;
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) {
            try out.appendSlice(a, "\xEF\xBF\xBD");
        } else try out.appendSlice(a, s[i..@min(i + w, s.len)]);
        i += w;
    }
    return out.items;
}

fn validChar(cp: u21) bool {
    return cp == 0x9 or cp == 0xA or cp == 0xD or (cp >= 0x20 and cp <= 0x7E) or cp == 0x85 or
        (cp >= 0xA0 and cp <= 0xD7FF) or (cp >= 0xE000 and cp <= 0xFFFD) or (cp >= 0x10000 and cp <= 0x10FFFF);
}

fn readerError(src: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < src.len) {
        const w = std.unicode.utf8ByteSequenceLength(src[i]) catch return "invalid leading UTF-8 octet";
        if (i + w > src.len) return "incomplete UTF-8 octet sequence";
        const cp = std.unicode.utf8Decode(src[i..][0..w]) catch return "invalid trailing UTF-8 octet";
        if (!validChar(cp)) return "control characters are not allowed";
        i += w;
    }
    return null;
}

fn toS(a: Allocator, o: Obj) Allocator.Error![]const u8 {
    return switch (o) {
        .null_ => "",
        .boolean => |b| if (b) "true" else "false",
        .int, .float, .str, .sym, .time => |s| s,
        .seq, .map => inspect(a, o),
    };
}

fn inspect(a: Allocator, o: Obj) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (o) {
        .null_ => try out.appendSlice(a, "nil"),
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int, .float => |s| try out.appendSlice(a, s),
        .time => |s| try out.appendSlice(a, s),
        .sym => |s| {
            try out.append(a, ':');
            try out.appendSlice(a, s);
        },
        .str => |s| {
            try out.append(a, '"');
            for (s) |c| switch (c) {
                '"' => try out.appendSlice(a, "\\\""),
                '\\' => try out.appendSlice(a, "\\\\"),
                '\n' => try out.appendSlice(a, "\\n"),
                '\t' => try out.appendSlice(a, "\\t"),
                '\r' => try out.appendSlice(a, "\\r"),
                else => try out.append(a, c),
            };
            try out.append(a, '"');
        },
        .seq => |items| {
            try out.append(a, '[');
            for (items, 0..) |it, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try inspect(a, it));
            }
            try out.append(a, ']');
        },
        .map => |pairs| {
            try out.append(a, '{');
            for (pairs, 0..) |p, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try inspect(a, p.key));
                try out.appendSlice(a, " => ");
                try out.appendSlice(a, try inspect(a, p.value));
            }
            try out.append(a, '}');
        },
    }
    return out.items;
}

fn display(a: Allocator, o: Obj) Allocator.Error!Value {
    switch (o) {
        .seq => |items| {
            const out = try a.alloc(Value, items.len);
            for (items, out) |it, *v| v.* = try display(a, it);
            return .{ .seq = out };
        },
        .map => |pairs| {
            const out = try a.alloc(Pair, pairs.len);
            for (pairs, out) |p, *q| q.* = .{ .key = try collapse(a, try toS(a, p.key)), .value = try display(a, p.value) };
            return .{ .map = out };
        },
        else => return .{ .scalar = .{ .text = try collapse(a, try toS(a, o)), .falsy = o == .null_ or (o == .boolean and !o.boolean) } },
    }
}
