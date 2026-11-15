const std = @import("std");
const xml = @import("svg_xml.zig");

pub const Decl = struct { name: []const u8, value: []const u8, important: bool };

const Test = union(enum) {
    tag: []const u8,
    class: []const u8,
    id: []const u8,
    has_attr: []const u8,
    attr_eq: struct { name: []const u8, value: []const u8 },
    attr_word: struct { name: []const u8, value: []const u8 },
    first_child,
    never,
};

const Compound = struct { tests: []const Test, combinator: u8 };

pub const Rule = struct {
    chain: []const Compound,
    decls: []const Decl,
    spec: u32,
    order: u32,
};

pub const Frame = struct { pct: f64, decls: []const Decl };

pub const Keyframes = struct { name: []const u8, frames: []const Frame };

pub const FontFace = struct { family: []const u8, src: []const u8, weight: u16, italic: bool };

pub const Env = struct { vw: f64 = 300, vh: f64 = 150 };

pub const max_rules = 1000;

pub fn parseDecls(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Decl)) std.mem.Allocator.Error!void {
    var start: usize = 0;
    var depth: u32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const c: u8 = if (i < text.len) text[i] else ';';
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(' => depth += 1,
            ')' => depth -|= 1,
            ';' => if (depth == 0) {
                try declPart(arena, text[start..i], out);
                start = i + 1;
            },
            else => {},
        }
    }
}

fn declPart(arena: std.mem.Allocator, part: []const u8, out: *std.ArrayList(Decl)) std.mem.Allocator.Error!void {
    const colon = std.mem.indexOfScalar(u8, part, ':') orelse return;
    const nm = std.mem.trim(u8, part[0..colon], " \t\r\n");
    var val = std.mem.trim(u8, part[colon + 1 ..], " \t\r\n");
    if (nm.len == 0 or val.len == 0) return;
    var important = false;
    if (std.mem.endsWith(u8, val, "!important")) {
        important = true;
        val = std.mem.trim(u8, val[0 .. val.len - "!important".len], " \t\r\n");
    }
    try out.append(arena, .{ .name = nm, .value = val, .important = important });
}

fn stripComments(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, text, "/*") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.items;
}

fn skipBlock(text: []const u8, start: usize) usize {
    var depth: u32 = 0;
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            if (depth <= 1) return i + 1;
            depth -= 1;
        }
    }
    return text.len;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

fn parseCompound(arena: std.mem.Allocator, s: []const u8, spec: *u32) std.mem.Allocator.Error![]const Test {
    var tests: std.ArrayList(Test) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '*') {
            i += 1;
        } else if (isIdent(c)) {
            const st = i;
            while (i < s.len and isIdent(s[i])) i += 1;
            try tests.append(arena, .{ .tag = s[st..i] });
            spec.* += 1;
        } else if (c == '.' or c == '#') {
            i += 1;
            const st = i;
            while (i < s.len and isIdent(s[i])) i += 1;
            try tests.append(arena, if (c == '.') .{ .class = s[st..i] } else .{ .id = s[st..i] });
            spec.* += if (c == '.') 100 else 10000;
        } else if (c == '[') {
            const end = std.mem.indexOfScalarPos(u8, s, i, ']') orelse {
                try tests.append(arena, .never);
                return tests.items;
            };
            const body = s[i + 1 .. end];
            i = end + 1;
            spec.* += 100;
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                const word = eq > 0 and body[eq - 1] == '~';
                const nm = std.mem.trim(u8, body[0 .. if (word) eq - 1 else eq], " ");
                const v = std.mem.trim(u8, body[eq + 1 ..], " \"'");
                try tests.append(arena, if (word) .{ .attr_word = .{ .name = nm, .value = v } } else .{ .attr_eq = .{ .name = nm, .value = v } });
            } else try tests.append(arena, .{ .has_attr = std.mem.trim(u8, body, " ") });
        } else if (c == ':') {
            const st = i + 1;
            i += 1;
            while (i < s.len and (isIdent(s[i]) or s[i] == ':')) i += 1;
            const nm = s[st..i];
            spec.* += 100;
            if (std.mem.eql(u8, nm, "first-child")) {
                try tests.append(arena, .first_child);
            } else if (std.mem.eql(u8, nm, "root")) {
                try tests.append(arena, .{ .tag = "svg" });
            } else try tests.append(arena, .never);
        } else {
            try tests.append(arena, .never);
            return tests.items;
        }
    }
    return tests.items;
}

fn parseSelector(arena: std.mem.Allocator, sel: []const u8, spec: *u32) std.mem.Allocator.Error![]const Compound {
    var chain: std.ArrayList(Compound) = .empty;
    var i: usize = 0;
    var comb: u8 = ' ';
    const s = std.mem.trim(u8, sel, " \t\r\n");
    while (i < s.len) {
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i < s.len and (s[i] == '>' or s[i] == '+' or s[i] == '~')) {
            comb = s[i];
            i += 1;
            continue;
        }
        const st = i;
        var depth: u32 = 0;
        while (i < s.len and (depth > 0 or !(std.ascii.isWhitespace(s[i]) or s[i] == '>' or s[i] == '+' or s[i] == '~'))) : (i += 1) {
            if (s[i] == '[') depth += 1;
            if (s[i] == ']' and depth > 0) depth -= 1;
        }
        if (i == st) break;
        const tests = try parseCompound(arena, s[st..i], spec);
        try chain.append(arena, .{ .tests = tests, .combinator = comb });
        comb = ' ';
    }
    return chain.items;
}

fn frameLess(_: void, a: Frame, b: Frame) bool {
    return a.pct < b.pct;
}

fn parseKeyframes(arena: std.mem.Allocator, header: []const u8, body: []const u8, out: *std.ArrayList(Keyframes)) std.mem.Allocator.Error!void {
    const sp = std.mem.indexOfAny(u8, header, " \t\r\n") orelse return;
    const name = std.mem.trim(u8, header[sp..], " \t\r\n\"'");
    var frames: std.ArrayList(Frame) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        const brace = std.mem.indexOfScalarPos(u8, body, i, '{') orelse break;
        const close = std.mem.indexOfScalarPos(u8, body, brace, '}') orelse body.len;
        var decls: std.ArrayList(Decl) = .empty;
        try parseDecls(arena, body[brace + 1 .. @min(close, body.len)], &decls);
        var it = std.mem.splitScalar(u8, body[i..brace], ',');
        while (it.next()) |sel| {
            const t = std.mem.trim(u8, sel, " \t\r\n");
            const v: f64 = if (std.mem.eql(u8, t, "from")) 0 else if (std.mem.eql(u8, t, "to")) 100 else if (std.mem.endsWith(u8, t, "%")) (std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch -1) else -1;
            if (v >= 0 and v <= 100 and frames.items.len < 200) try frames.append(arena, .{ .pct = v, .decls = decls.items });
        }
        i = @min(close + 1, body.len);
    }
    if (frames.items.len == 0) return;
    std.mem.sort(Frame, frames.items, {}, frameLess);
    try out.append(arena, .{ .name = name, .frames = frames.items });
}

fn parseFontFace(arena: std.mem.Allocator, body: []const u8, out: *std.ArrayList(FontFace)) std.mem.Allocator.Error!void {
    var decls: std.ArrayList(Decl) = .empty;
    try parseDecls(arena, body, &decls);
    var family: ?[]const u8 = null;
    var src: ?[]const u8 = null;
    var weight: u16 = 400;
    var italic = false;
    for (decls.items) |d| {
        if (std.mem.eql(u8, d.name, "font-family")) {
            family = std.mem.trim(u8, d.value, " \t\r\n\"'");
        } else if (std.mem.eql(u8, d.name, "src")) {
            const open = std.mem.indexOf(u8, d.value, "url(") orelse continue;
            const close = std.mem.indexOfScalarPos(u8, d.value, open, ')') orelse continue;
            src = std.mem.trim(u8, d.value[open + 4 .. close], " \t\r\n\"'");
        } else if (std.mem.eql(u8, d.name, "font-weight")) {
            weight = if (std.mem.eql(u8, d.value, "bold")) 700 else std.fmt.parseInt(u16, std.mem.sliceTo(d.value, ' '), 10) catch 400;
        } else if (std.mem.eql(u8, d.name, "font-style")) {
            italic = std.mem.startsWith(u8, d.value, "italic") or std.mem.startsWith(u8, d.value, "oblique");
        }
    }
    if (family != null and src != null and out.items.len < 32) try out.append(arena, .{ .family = family.?, .src = src.?, .weight = weight, .italic = italic });
}

fn lengthPx(v: []const u8, env: Env) ?f64 {
    var i: usize = 0;
    while (i < v.len and (std.ascii.isDigit(v[i]) or v[i] == '.' or v[i] == '-' or v[i] == '+')) i += 1;
    const n = std.fmt.parseFloat(f64, v[0..i]) catch return null;
    const unit = v[i..];
    _ = env;
    if (unit.len == 0 or std.mem.eql(u8, unit, "px")) return n;
    if (std.mem.eql(u8, unit, "em") or std.mem.eql(u8, unit, "rem")) return n * 16;
    if (std.mem.eql(u8, unit, "pt")) return n * 4.0 / 3.0;
    if (std.mem.eql(u8, unit, "in")) return n * 96;
    if (std.mem.eql(u8, unit, "cm")) return n * 96 / 2.54;
    if (std.mem.eql(u8, unit, "mm")) return n * 96 / 25.4;
    return null;
}

fn cmpOp(a: f64, op: []const u8, b: f64) bool {
    if (std.mem.eql(u8, op, ">=")) return a >= b;
    if (std.mem.eql(u8, op, "<=")) return a <= b;
    if (std.mem.eql(u8, op, ">")) return a > b;
    if (std.mem.eql(u8, op, "<")) return a < b;
    return a == b;
}

fn dppx(v: []const u8) ?f64 {
    const dpi = std.mem.endsWith(u8, v, "dpi");
    const n = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, v, "dppxi")) catch return null;
    return if (dpi) n / 96 else n;
}

fn featureHolds(feat: []const u8, env: Env) bool {
    const f = std.mem.trim(u8, feat, " \t\r\n");
    if (f.len > 0 and f[0] == '(') return mediaMatchesOne(f[1 .. f.len - @intFromBool(f[f.len - 1] == ')')], env);
    if (std.mem.indexOfAny(u8, f, "<>=")) |op_at| {
        const op_end = blk: {
            var e = op_at;
            while (e < f.len and (f[e] == '<' or f[e] == '>' or f[e] == '=')) e += 1;
            break :blk e;
        };
        const lhs = std.mem.trim(u8, f[0..op_at], " ");
        const op = f[op_at..op_end];
        const rhs = std.mem.trim(u8, f[op_end..], " ");
        const dim: f64 = if (std.mem.eql(u8, lhs, "width") or std.mem.eql(u8, rhs, "width")) env.vw else if (std.mem.eql(u8, lhs, "height") or std.mem.eql(u8, rhs, "height")) env.vh else return false;
        if (std.mem.eql(u8, lhs, "width") or std.mem.eql(u8, lhs, "height")) return cmpOp(dim, op, lengthPx(rhs, env) orelse return false);
        return cmpOp(lengthPx(lhs, env) orelse return false, op, dim);
    }
    const colon = std.mem.indexOfScalar(u8, f, ':');
    const name = std.mem.trim(u8, if (colon) |c| f[0..c] else f, " ");
    const val = if (colon) |c| std.mem.trim(u8, f[c + 1 ..], " ") else "";
    const eq = std.mem.eql;
    if (eq(u8, name, "prefers-color-scheme")) return val.len == 0 or eq(u8, val, "dark");
    if (eq(u8, name, "prefers-reduced-motion") or eq(u8, name, "prefers-contrast") or eq(u8, name, "prefers-reduced-transparency") or eq(u8, name, "prefers-reduced-data")) return val.len == 0 or eq(u8, val, "no-preference");
    if (eq(u8, name, "forced-colors") or eq(u8, name, "inverted-colors") or eq(u8, name, "scripting")) return eq(u8, val, "none");
    if (eq(u8, name, "hover") or eq(u8, name, "any-hover")) return val.len == 0 or eq(u8, val, "hover");
    if (eq(u8, name, "pointer") or eq(u8, name, "any-pointer")) return val.len == 0 or eq(u8, val, "fine");
    if (eq(u8, name, "color") or eq(u8, name, "min-color")) return true;
    if (eq(u8, name, "orientation")) return eq(u8, val, if (env.vh >= env.vw) "portrait" else "landscape");
    if (eq(u8, name, "min-resolution") or eq(u8, name, "-webkit-min-device-pixel-ratio")) return (dppx(val) orelse return false) <= 1;
    if (eq(u8, name, "max-resolution") or eq(u8, name, "-webkit-max-device-pixel-ratio")) return (dppx(val) orelse return false) >= 1;
    if (eq(u8, name, "resolution") or eq(u8, name, "-webkit-device-pixel-ratio")) return (dppx(val) orelse return false) == 1;
    const dims = [_]struct { []const u8, f64, i8 }{
        .{ "width", env.vw, 0 },     .{ "min-width", env.vw, 1 },   .{ "max-width", env.vw, -1 },
        .{ "height", env.vh, 0 },    .{ "min-height", env.vh, 1 },  .{ "max-height", env.vh, -1 },
        .{ "device-width", env.vw, 0 }, .{ "min-device-width", env.vw, 1 }, .{ "max-device-width", env.vw, -1 },
        .{ "device-height", env.vh, 0 }, .{ "min-device-height", env.vh, 1 }, .{ "max-device-height", env.vh, -1 },
    };
    for (dims) |d| if (eq(u8, name, d[0])) {
        const px = lengthPx(val, env) orelse return false;
        return if (d[2] == 0) d[1] == px else if (d[2] > 0) d[1] >= px else d[1] <= px;
    };
    if (eq(u8, name, "aspect-ratio") or eq(u8, name, "min-aspect-ratio") or eq(u8, name, "max-aspect-ratio")) {
        const sl = std.mem.indexOfScalar(u8, val, '/');
        const num = std.fmt.parseFloat(f64, std.mem.trim(u8, if (sl) |k| val[0..k] else val, " ")) catch return false;
        const den = if (sl) |k| (std.fmt.parseFloat(f64, std.mem.trim(u8, val[k + 1 ..], " ")) catch return false) else 1;
        if (den == 0) return false;
        const ar = env.vw / env.vh;
        return if (name[0] == 'm' and name[1] == 'i') ar >= num / den else if (name[0] == 'm') ar <= num / den else ar == num / den;
    }
    return false;
}

fn mediaMatchesOne(q_in: []const u8, env: Env) bool {
    var buf: [400]u8 = undefined;
    const q0 = std.mem.trim(u8, q_in, " \t\r\n");
    if (q0.len == 0) return true;
    if (q0.len > buf.len) return false;
    const q = std.ascii.lowerString(&buf, q0);
    var negate = false;
    var ok = true;
    var i: usize = 0;
    var any_or = false;
    var or_result = false;
    while (i < q.len) {
        while (i < q.len and std.ascii.isWhitespace(q[i])) i += 1;
        if (i >= q.len) break;
        if (q[i] == '(') {
            var depth: u32 = 0;
            const st = i;
            while (i < q.len) : (i += 1) {
                if (q[i] == '(') depth += 1;
                if (q[i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
            const holds = featureHolds(q[st + 1 .. i - 1], env);
            if (any_or) or_result = or_result or holds else ok = ok and holds;
            continue;
        }
        const st = i;
        while (i < q.len and !std.ascii.isWhitespace(q[i]) and q[i] != '(') i += 1;
        const w = q[st..i];
        if (std.mem.eql(u8, w, "not")) {
            negate = true;
        } else if (std.mem.eql(u8, w, "or")) {
            any_or = true;
            or_result = ok;
            ok = true;
        } else if (std.mem.eql(u8, w, "screen") or std.mem.eql(u8, w, "all")) {
            // media types that match
        } else if (std.mem.eql(u8, w, "and") or std.mem.eql(u8, w, "only")) {
            // connectives
        } else ok = false;
    }
    const r = if (any_or) (or_result or ok) else ok;
    return if (negate) !r else r;
}

pub fn mediaMatches(q: []const u8, env: Env) bool {
    var it = std.mem.splitScalar(u8, q, ',');
    var any = false;
    while (it.next()) |one| {
        any = true;
        if (mediaMatchesOne(one, env)) return true;
    }
    return !any;
}

fn supportsHolds(cond_in: []const u8, depth: u32) bool {
    const c = std.mem.trim(u8, cond_in, " \t\r\n");
    if (depth > 6 or c.len == 0) return false;
    if (std.mem.startsWith(u8, c, "not ") or std.mem.startsWith(u8, c, "not(")) return !supportsHolds(c[3..], depth + 1);
    var level: u32 = 0;
    var i: usize = 0;
    while (i < c.len) : (i += 1) {
        if (c[i] == '(') level += 1;
        if (c[i] == ')') level -|= 1;
        if (level == 0 and i + 4 < c.len and std.mem.startsWith(u8, c[i..], " and ")) return supportsHolds(c[0..i], depth + 1) and supportsHolds(c[i + 5 ..], depth + 1);
        if (level == 0 and i + 3 < c.len and std.mem.startsWith(u8, c[i..], " or ")) return supportsHolds(c[0..i], depth + 1) or supportsHolds(c[i + 4 ..], depth + 1);
    }
    if (std.mem.startsWith(u8, c, "selector(")) return true;
    if (c[0] != '(' or c[c.len - 1] != ')') return true;
    const inner = std.mem.trim(u8, c[1 .. c.len - 1], " ");
    if (inner.len > 0 and (inner[0] == '(' or std.mem.startsWith(u8, inner, "not "))) return supportsHolds(inner, depth + 1);
    const name = std.mem.trim(u8, inner[0 .. std.mem.indexOfScalar(u8, inner, ':') orelse inner.len], " ");
    if (std.mem.startsWith(u8, name, "-moz-") or std.mem.startsWith(u8, name, "-ms-") or std.mem.startsWith(u8, name, "-o-")) return false;
    return true;
}

pub fn parseStylesheet(arena: std.mem.Allocator, raw: []const u8, rules: *std.ArrayList(Rule), frames: *std.ArrayList(Keyframes), faces: *std.ArrayList(FontFace), env: Env) std.mem.Allocator.Error!void {
    return parseSheet(arena, raw, rules, frames, faces, env, 0);
}

fn parseSheet(arena: std.mem.Allocator, raw: []const u8, rules: *std.ArrayList(Rule), frames: *std.ArrayList(Keyframes), faces: *std.ArrayList(FontFace), env: Env, depth: u32) std.mem.Allocator.Error!void {
    const text = try stripComments(arena, raw);
    var i: usize = 0;
    while (i < text.len and rules.items.len < max_rules) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;
        if (text[i] == '@') {
            const semi = std.mem.indexOfScalarPos(u8, text, i, ';') orelse text.len;
            const brace = std.mem.indexOfScalarPos(u8, text, i, '{') orelse text.len;
            if (brace < semi and brace < text.len) {
                const header = std.mem.trim(u8, text[i..brace], " \t\r\n");
                const end = skipBlock(text, brace);
                const body = text[brace + 1 .. @max(brace + 1, end - 1)];
                if (std.mem.startsWith(u8, header, "@keyframes") or std.mem.startsWith(u8, header, "@-webkit-keyframes")) {
                    try parseKeyframes(arena, header, body, frames);
                } else if (std.mem.startsWith(u8, header, "@font-face")) {
                    try parseFontFace(arena, body, faces);
                } else if (depth < 4) {
                    if (std.mem.startsWith(u8, header, "@media")) {
                        if (mediaMatches(header[6..], env)) try parseSheet(arena, body, rules, frames, faces, env, depth + 1);
                    } else if (std.mem.startsWith(u8, header, "@supports")) {
                        if (supportsHolds(header[9..], 0)) try parseSheet(arena, body, rules, frames, faces, env, depth + 1);
                    } else if (std.mem.startsWith(u8, header, "@layer")) {
                        try parseSheet(arena, body, rules, frames, faces, env, depth + 1);
                    }
                }
                i = end;
            } else i = if (semi < brace) semi + 1 else text.len;
            continue;
        }
        const brace = std.mem.indexOfScalarPos(u8, text, i, '{') orelse break;
        const close = std.mem.indexOfScalarPos(u8, text, brace, '}') orelse text.len;
        const sels = text[i..brace];
        var decls: std.ArrayList(Decl) = .empty;
        try parseDecls(arena, text[brace + 1 .. @min(close, text.len)], &decls);
        i = @min(close + 1, text.len);
        var it = std.mem.splitScalar(u8, sels, ',');
        while (it.next()) |sel| {
            if (rules.items.len >= max_rules) break;
            var spec: u32 = 0;
            const chain = try parseSelector(arena, sel, &spec);
            if (chain.len == 0) continue;
            try rules.append(arena, .{ .chain = chain, .decls = decls.items, .spec = spec, .order = @intCast(rules.items.len) });
        }
    }
}

fn testHolds(t: Test, n: *const xml.Node) bool {
    switch (t) {
        .tag => |tg| return std.mem.eql(u8, tg, n.tag),
        .class => |c| {
            const v = n.attr("class") orelse return false;
            var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
            while (it.next()) |w| if (std.mem.eql(u8, w, c)) return true;
            return false;
        },
        .id => |id| return if (n.attr("id")) |v| std.mem.eql(u8, v, id) else false,
        .has_attr => |a| return n.attr(a) != null,
        .attr_eq => |a| return if (n.attr(a.name)) |v| std.mem.eql(u8, v, a.value) else false,
        .attr_word => |a| {
            const v = n.attr(a.name) orelse return false;
            var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
            while (it.next()) |w| if (std.mem.eql(u8, w, a.value)) return true;
            return false;
        },
        .first_child => {
            const p = n.parent orelse return true;
            for (p.children.items) |c| if (!c.is_text) return c == n;
            return false;
        },
        .never => return false,
    }
}

fn compoundMatches(c: Compound, n: *const xml.Node) bool {
    for (c.tests) |t| if (!testHolds(t, n)) return false;
    return true;
}

fn chainMatches(chain: []const Compound, n: *const xml.Node) bool {
    const last = chain[chain.len - 1];
    if (!compoundMatches(last, n)) return false;
    if (chain.len == 1) return true;
    const rest = chain[0 .. chain.len - 1];
    switch (last.combinator) {
        '>' => {
            const p = n.parent orelse return false;
            return chainMatches(rest, p);
        },
        '+', '~' => {
            const p = n.parent orelse return false;
            var prev: ?*xml.Node = null;
            for (p.children.items) |c| {
                if (c == n) break;
                if (!c.is_text) {
                    if (last.combinator == '~' and chainMatches(rest, c)) return true;
                    prev = c;
                }
            }
            return if (last.combinator == '+') (if (prev) |pv| chainMatches(rest, pv) else false) else false;
        },
        else => {
            var p = n.parent;
            while (p) |q| : (p = q.parent) if (chainMatches(rest, q)) return true;
            return false;
        },
    }
}

pub fn matches(r: Rule, n: *const xml.Node) bool {
    return chainMatches(r.chain, n);
}

test "stylesheet matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try xml.parse(a, "<svg><g class='a b'><rect id='r' class='x'/></g></svg>");
    var rules: std.ArrayList(Rule) = .empty;
    var frames: std.ArrayList(Keyframes) = .empty;
    var faces: std.ArrayList(FontFace) = .empty;
    try parseStylesheet(a, "@keyframes pop { from { opacity: 0 } 50% { opacity: .5 } to { opacity: 1; fill: red } } /*c*/ @font-face { font-family: T; src: url(data:font/ttf;base64,AAEAAA==) format(truetype); font-weight: bold } @media print { rect { fill: blue } } g.a > rect, svg #r.x { fill: red; stroke : green !important } .zz{fill:blue} a:hover{fill:blue} @media (prefers-color-scheme: dark) { .q1 { fill: red } } @media (prefers-color-scheme: light) { .q2 { fill: red } } @supports (-moz-appearance: auto) { .q3 { fill: red } }", &rules, &frames, &faces, .{});
    try std.testing.expectEqual(@as(usize, 1), faces.items.len);
    try std.testing.expectEqual(@as(u16, 700), faces.items[0].weight);
    try std.testing.expectEqual(@as(usize, 1), frames.items.len);
    try std.testing.expectEqualStrings("pop", frames.items[0].name);
    try std.testing.expectEqual(@as(usize, 3), frames.items[0].frames.len);
    try std.testing.expectEqual(@as(usize, 2), frames.items[0].frames[2].decls.len);
    try std.testing.expect(mediaMatches("screen and (min-width: 100px) and (max-width: 400px)", .{}));
    try std.testing.expect(!mediaMatches("print", .{}));
    try std.testing.expect(mediaMatches("not (prefers-color-scheme: light)", .{}));
    try std.testing.expect(mediaMatches("(width >= 200px)", .{}));
    const rect = root.children.items[0].children.items[0];
    try std.testing.expectEqual(@as(usize, 5), rules.items.len);
    try std.testing.expect(matches(rules.items[0], rect));
    try std.testing.expect(matches(rules.items[1], rect));
    try std.testing.expect(!matches(rules.items[2], rect));
    try std.testing.expect(!matches(rules.items[3], rect));
    try std.testing.expectEqualStrings("red", rules.items[0].decls[0].value);
    try std.testing.expect(rules.items[0].decls[1].important);
}
