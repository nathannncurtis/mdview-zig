//! A port of mhchemParser 4.2.1 (Copyright (c) 2015-2023 Martin Hensel, Apache License 2.0, see mhchem-LICENSE).
//! Turns `\ce{...}` and `\pu{...}` input into TeX, the way MathJax's mhchem extension does.
const std = @import("std");
const regex = @import("regex.zig");
const tbl = @import("mhchem_tables.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, Mhchem };

const Val = union(enum) { s: []const u8, arr: []const ?[]const u8 };

const Pv = union(enum) { s: []const u8, items: []const Item };

const Obj = struct {
    t: []const u8,
    kind: []const u8 = "",
    p1: ?Pv = null,
    p2: ?Pv = null,
    a: []const Item = &.{},
    b: []const Item = &.{},
    p: []const Item = &.{},
    o: []const Item = &.{},
    q: []const Item = &.{},
    d: []const Item = &.{},
    d_type: ?[]const u8 = null,
    r: []const u8 = "",
    rd: []const Item = &.{},
    rq: []const Item = &.{},
    color1: []const u8 = "",
    color2: []const Item = &.{},
    color: []const u8 = "",
};

const Item = union(enum) { s: []const u8, o: *const Obj };

const Out = union(enum) { none, one: Item, many: []const Item };

const Buffer = struct {
    a: ?[]const u8 = null,
    b: ?[]const u8 = null,
    p: ?[]const u8 = null,
    o: ?[]const u8 = null,
    q: ?[]const u8 = null,
    d: ?[]const u8 = null,
    rm: ?[]const u8 = null,
    text_: ?[]const u8 = null,
    r: ?[]const u8 = null,
    rdt: ?[]const u8 = null,
    rd: ?[]const u8 = null,
    rqt: ?[]const u8 = null,
    rq: ?[]const u8 = null,
    d_type: ?[]const u8 = null,
    sb: bool = false,
    begins_with_bond: bool = false,
    paren: i32 = 0,

    fn clear(buf: *Buffer) void {
        const paren = buf.paren;
        const bwb = buf.begins_with_bond;
        buf.* = .{};
        buf.paren = paren;
        buf.begins_with_bond = bwb;
    }
};

pub const Ctx = struct {
    a: Allocator,
    cache: std.StringHashMapUnmanaged(regex.Regex) = .empty,
    err: ?[]const u8 = null,
    depth: u32 = 0,

    fn fail(ctx: *Ctx, msg: []const u8) Error {
        if (ctx.err == null) ctx.err = msg;
        return error.Mhchem;
    }

    fn re(ctx: *Ctx, src: []const u8) Error!*const regex.Regex {
        if (ctx.cache.getPtr(src)) |r| return r;
        const compiled = regex.compile(ctx.a, src) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadRegex => return ctx.fail("mhchem bug P. Please report."),
        };
        try ctx.cache.put(ctx.a, src, compiled);
        return ctx.cache.getPtr(src).?;
    }

    /// Matches `src` at the start of `input`; the capture spans are relative to `input`.
    fn rx(ctx: *Ctx, src: []const u8, input: []const u8) Error!?regex.Result {
        const r = try ctx.re(src);
        return try regex.match(r, ctx.a, input);
    }

    fn cap(r: regex.Result, input: []const u8, k: usize) ?[]const u8 {
        const s = r.caps[2 * k] orelse return null;
        return input[s..r.caps[2 * k + 1].?];
    }
};

fn truthy(x: ?[]const u8) bool {
    return x != null and x.?.len > 0;
}

fn str(x: ?[]const u8) []const u8 {
    return x orelse "";
}

fn cat(ctx: *Ctx, x: ?[]const u8, y: []const u8) Error![]const u8 {
    return std.mem.concat(ctx.a, u8, &.{ str(x), y });
}

fn valStr(ctx: *Ctx, v: Val) Error![]const u8 {
    switch (v) {
        .s => |s| return s,
        .arr => |arr| {
            var out: std.ArrayList(u8) = .empty;
            for (arr, 0..) |e, i| {
                if (i > 0) try out.append(ctx.a, ',');
                try out.appendSlice(ctx.a, str(e));
            }
            return out.items;
        },
    }
}

fn mkObj(ctx: *Ctx, o: Obj) Error!Item {
    const p = try ctx.a.create(Obj);
    p.* = o;
    return .{ .o = p };
}

fn one(ctx: *Ctx, o: Obj) Error!Out {
    return .{ .one = try mkObj(ctx, o) };
}

const MatchRes = struct { v: Val, rem: []const u8 };

const Pat = union(enum) { s: []const u8, re: []const u8 };

const Fog = struct {
    beg_excl: Pat = .{ .s = "" },
    beg_incl: Pat = .{ .s = "" },
    end_incl: Pat = .{ .s = "" },
    end_excl: Pat = .{ .s = "" },
    beg2_excl: Pat = .{ .s = "" },
    beg2_incl: Pat = .{ .s = "" },
    end2_incl: Pat = .{ .s = "" },
    end2_excl: Pat = .{ .s = "" },
    combine: bool = false,
};

fn patMatch(ctx: *Ctx, input: []const u8, pat: Pat) Error!?[]const u8 {
    switch (pat) {
        .s => |s| return if (std.mem.startsWith(u8, input, s)) s else null,
        .re => |src| {
            const r = (try ctx.rx(src, input)) orelse return null;
            return input[0..r.caps[1].?];
        },
    }
}

fn patTruthy(p: Pat) bool {
    return switch (p) {
        .s => |s| s.len > 0,
        .re => true,
    };
}

fn findEnd(ctx: *Ctx, input: []const u8, from: usize, end_chars: Pat) Error!?struct { begin: usize, end: usize } {
    var braces: u32 = 0;
    var i = from;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        const m = try patMatch(ctx, input[i..], end_chars);
        if (m != null and braces == 0) return .{ .begin = i, .end = i + m.?.len };
        if (c == '{') {
            braces += 1;
        } else if (c == '}') {
            if (braces == 0) return ctx.fail("Extra close brace or missing open brace");
            braces -= 1;
        }
    }
    return null;
}

fn fog(ctx: *Ctx, input_in: []const u8, f: Fog) Error!?MatchRes {
    var input = input_in;
    var m = (try patMatch(ctx, input, f.beg_excl)) orelse return null;
    input = input[m.len..];
    m = (try patMatch(ctx, input, f.beg_incl)) orelse return null;
    const end_chars = if (patTruthy(f.end_incl)) f.end_incl else f.end_excl;
    const e = (try findEnd(ctx, input, m.len, end_chars)) orelse return null;
    const match1 = input[0..(if (patTruthy(f.end_incl)) e.end else e.begin)];
    if (!patTruthy(f.beg2_excl) and !patTruthy(f.beg2_incl)) return .{ .v = .{ .s = match1 }, .rem = input[e.end..] };
    const g2 = (try fog(ctx, input[e.end..], .{
        .beg_excl = f.beg2_excl,
        .beg_incl = f.beg2_incl,
        .end_incl = f.end2_incl,
        .end_excl = f.end2_excl,
    })) orelse return null;
    if (f.combine) {
        return .{ .v = .{ .s = try std.mem.concat(ctx.a, u8, &.{ match1, g2.v.s }) }, .rem = g2.rem };
    }
    const pair = try ctx.a.alloc(?[]const u8, 2);
    pair[0] = match1;
    pair[1] = g2.v.s;
    return .{ .v = .{ .arr = pair }, .rem = g2.rem };
}

fn cm(s: []const u8) Pat {
    return .{ .s = s };
}

fn rg(s: []const u8) Pat {
    return .{ .re = s };
}

const x_open = "^\\\\[a-zA-Z]+\\{";

fn fnPattern(ctx: *Ctx, name: []const u8, input: []const u8) Error!?MatchRes {
    const eq = std.mem.eql;
    if (eq(u8, name, "^{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("^{"), .end_excl = cm("}") });
    if (eq(u8, name, "^($...$)")) return fog(ctx, input, .{ .beg_excl = cm("^"), .beg_incl = cm("$"), .end_incl = cm("$") });
    if (eq(u8, name, "^\\x{}{}")) return fog(ctx, input, .{ .beg_excl = cm("^"), .beg_incl = rg(x_open), .end_incl = cm("}"), .beg2_incl = cm("{"), .end2_incl = cm("}"), .combine = true });
    if (eq(u8, name, "^\\x{}")) return fog(ctx, input, .{ .beg_excl = cm("^"), .beg_incl = rg(x_open), .end_incl = cm("}") });
    if (eq(u8, name, "_{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("_{"), .end_excl = cm("}") });
    if (eq(u8, name, "_($...$)")) return fog(ctx, input, .{ .beg_excl = cm("_"), .beg_incl = cm("$"), .end_incl = cm("$") });
    if (eq(u8, name, "_\\x{}{}")) return fog(ctx, input, .{ .beg_excl = cm("_"), .beg_incl = rg(x_open), .end_incl = cm("}"), .beg2_incl = cm("{"), .end2_incl = cm("}"), .combine = true });
    if (eq(u8, name, "_\\x{}")) return fog(ctx, input, .{ .beg_excl = cm("_"), .beg_incl = rg(x_open), .end_incl = cm("}") });
    if (eq(u8, name, "{...}")) return fog(ctx, input, .{ .beg_incl = cm("{"), .end_incl = cm("}") });
    if (eq(u8, name, "{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("{"), .end_excl = cm("}") });
    if (eq(u8, name, "$...$")) return fog(ctx, input, .{ .beg_incl = cm("$"), .end_incl = cm("$") });
    if (eq(u8, name, "${(...)}$__$(...)$")) {
        if (try fog(ctx, input, .{ .beg_excl = cm("${"), .end_excl = cm("}$") })) |r| return r;
        return fog(ctx, input, .{ .beg_excl = cm("$"), .end_excl = cm("$") });
    }
    if (eq(u8, name, "\\bond{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\bond{"), .end_excl = cm("}") });
    if (eq(u8, name, "[(...)]")) return fog(ctx, input, .{ .beg_excl = cm("["), .end_excl = cm("]") });
    if (eq(u8, name, "\\x{}{}")) return fog(ctx, input, .{ .beg_incl = rg(x_open), .end_incl = cm("}"), .beg2_incl = cm("{"), .end2_incl = cm("}"), .combine = true });
    if (eq(u8, name, "\\x{}")) return fog(ctx, input, .{ .beg_incl = rg(x_open), .end_incl = cm("}") });
    if (eq(u8, name, "\\frac{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\frac{"), .end_excl = cm("}"), .beg2_excl = cm("{"), .end2_excl = cm("}") });
    if (eq(u8, name, "\\overset{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\overset{"), .end_excl = cm("}"), .beg2_excl = cm("{"), .end2_excl = cm("}") });
    if (eq(u8, name, "\\underset{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\underset{"), .end_excl = cm("}"), .beg2_excl = cm("{"), .end2_excl = cm("}") });
    if (eq(u8, name, "\\underbrace{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\underbrace{"), .end_excl = cm("}_"), .beg2_excl = cm("{"), .end2_excl = cm("}") });
    if (eq(u8, name, "\\color{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\color{"), .end_excl = cm("}") });
    if (eq(u8, name, "\\color{(...)}{(...)}")) {
        if (try fog(ctx, input, .{ .beg_excl = cm("\\color{"), .end_excl = cm("}"), .beg2_excl = cm("{"), .end2_excl = cm("}") })) |r| return r;
        return fog(ctx, input, .{ .beg_excl = cm("\\color"), .beg_incl = cm("\\"), .end_excl = rg("^(?=\\{)"), .beg2_excl = cm("{"), .end2_excl = cm("}") });
    }
    if (eq(u8, name, "\\ce{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\ce{"), .end_excl = cm("}") });
    if (eq(u8, name, "\\pu{(...)}")) return fog(ctx, input, .{ .beg_excl = cm("\\pu{"), .end_excl = cm("}") });
    if (eq(u8, name, "(-)(9.,9)(e)(99)")) {
        const r = (try ctx.rx("^(\\+\\-|\\+\\/\\-|\\+|\\-|\\\\pm\\s?)?([0-9]+(?:[,.][0-9]+)?|[0-9]*(?:\\.[0-9]+))?(\\((?:[0-9]+(?:[,.][0-9]+)?|[0-9]*(?:\\.[0-9]+))\\))?(?:(?:([eE])|\\s*(\\*|x|\\\\times|\\u00D7)\\s*10\\^)([+\\-]?[0-9]+|\\{[+\\-]?[0-9]+\\}))?", input)) orelse return null;
        const end = r.caps[1].?;
        if (end == 0) return null;
        const groups = try ctx.a.alloc(?[]const u8, 6);
        for (groups, 0..) |*g, i| g.* = Ctx.cap(r, input, i + 1);
        return .{ .v = .{ .arr = groups }, .rem = input[end..] };
    }
    if (eq(u8, name, "state of aggregation $")) {
        if (try fog(ctx, input, .{ .beg_incl = rg("^\\([a-z]{1,3}(?=[\\),])"), .end_incl = cm(")") })) |a| {
            if (try ctx.rx("^($|[\\s,;\\)\\]\\}])", a.rem) != null) return a;
        }
        const r = (try ctx.rx("^(?:\\((?:\\\\ca\\s?)?\\$[amothc]\\$\\))", input)) orelse return null;
        const end = r.caps[1].?;
        return .{ .v = .{ .s = input[0..end] }, .rem = input[end..] };
    }
    if (eq(u8, name, "amount") or eq(u8, name, "amount2")) {
        if (try ctx.rx("^(?:(?:(?:\\([+\\-]?[0-9]+\\/[0-9]+\\)|[+\\-]?(?:[0-9]+|\\$[a-z]\\$|[a-z])\\/[0-9]+|[+\\-]?[0-9]+[.,][0-9]+|[+\\-]?\\.[0-9]+|[+\\-]?[0-9]+)(?:[a-z](?=\\s*[A-Z]))?)|[+\\-]?[a-z](?=\\s*[A-Z])|\\+(?!\\s))", input)) |r| {
            const end = r.caps[1].?;
            return .{ .v = .{ .s = input[0..end] }, .rem = input[end..] };
        }
        if (try fog(ctx, input, .{ .beg_incl = cm("$"), .end_incl = cm("$") })) |a| {
            const text = a.v.s;
            if (try ctx.rx("^\\$(?:\\(?[+\\-]?(?:[0-9]*[a-z]?[+\\-])?[0-9]*[a-z](?:[+\\-][0-9]*[a-z]?)?\\)?|\\+|-)\\$$", text)) |r| {
                const end = r.caps[1].?;
                return .{ .v = .{ .s = text[0..end] }, .rem = input[end..] };
            }
        }
        return null;
    }
    if (eq(u8, name, "formula$")) {
        if (try ctx.rx("^\\([a-z]+\\)$", input) != null) return null;
        const r = (try ctx.rx("^(?:[a-z]|(?:[0-9\\ \\+\\-\\,\\.\\(\\)]+[a-z])+[0-9\\ \\+\\-\\,\\.\\(\\)]*|(?:[a-z][0-9\\ \\+\\-\\,\\.\\(\\)]+)+[a-z]?)$", input)) orelse return null;
        const end = r.caps[1].?;
        return .{ .v = .{ .s = input[0..end] }, .rem = input[end..] };
    }
    return ctx.fail("mhchem bug P. Please report.");
}

fn matchPattern(ctx: *Ctx, name: []const u8, input: []const u8) Error!?MatchRes {
    if (tbl.patterns.get(name)) |src| {
        const re = try ctx.re(src);
        const r = (try regex.match(re, ctx.a, input)) orelse return null;
        const end = r.caps[1].?;
        if (re.groups >= 2) {
            const groups = try ctx.a.alloc(?[]const u8, re.groups);
            for (groups, 0..) |*g, i| g.* = Ctx.cap(r, input, i + 1);
            return .{ .v = .{ .arr = groups }, .rem = input[end..] };
        }
        if (re.groups == 1) if (Ctx.cap(r, input, 1)) |g| {
            if (g.len > 0) return .{ .v = .{ .s = g }, .rem = input[end..] };
        };
        return .{ .v = .{ .s = input[0..end] }, .rem = input[end..] };
    }
    return fnPattern(ctx, name, input);
}

fn findMachine(name: []const u8) ?*const tbl.Machine {
    for (&tbl.machines) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn findState(m: *const tbl.Machine, name: []const u8) ?*const tbl.State {
    for (m.states) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn normalize(ctx: *Ctx, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\n') {
            try out.append(ctx.a, ' ');
            i += 1;
        } else if (std.mem.startsWith(u8, raw[i..], "\u{2212}") or std.mem.startsWith(u8, raw[i..], "\u{2013}") or
            std.mem.startsWith(u8, raw[i..], "\u{2014}") or std.mem.startsWith(u8, raw[i..], "\u{2010}"))
        {
            try out.append(ctx.a, '-');
            i += 3;
        } else if (std.mem.startsWith(u8, raw[i..], "\u{2026}")) {
            try out.appendSlice(ctx.a, "...");
            i += 3;
        } else {
            try out.append(ctx.a, raw[i]);
            i += 1;
        }
    }
    return out.items;
}

fn concat(ctx: *Ctx, list: *std.ArrayList(Item), o: Out) Error!void {
    switch (o) {
        .none => {},
        .one => |it| switch (it) {
            .s => |s| if (s.len > 0) try list.append(ctx.a, it),
            .o => try list.append(ctx.a, it),
        },
        .many => |xs| try list.appendSlice(ctx.a, xs),
    }
}

pub fn go(ctx: *Ctx, input_opt: ?[]const u8, machine: []const u8) Error![]const Item {
    const raw = input_opt orelse return &.{};
    if (raw.len == 0) return &.{};
    ctx.depth += 1;
    defer ctx.depth -= 1;
    if (ctx.depth > 40) return ctx.fail("mhchem expression is nested too deeply");
    var input = try normalize(ctx, raw);
    const mach = findMachine(machine) orelse return ctx.fail("mhchem bug A. Please report.");
    var state: []const u8 = "0";
    var buf: Buffer = .{};
    var output: std.ArrayList(Item) = .empty;
    var last: ?[]const u8 = null;
    var watchdog: i32 = 10;
    while (true) {
        if (last == null or !std.mem.eql(u8, last.?, input)) {
            watchdog = 10;
            last = input;
        } else watchdog -= 1;
        const trans = findState(mach, state) orelse findState(mach, "*") orelse return ctx.fail("mhchem bug U. Please report.");
        for (trans.list) |tr| {
            const matches = (try matchPattern(ctx, tr.pattern, input)) orelse continue;
            for (tr.acts) |act| {
                const o = try runAction(ctx, mach.name, act.name, &buf, matches.v, act.opt);
                try concat(ctx, &output, o);
            }
            if (tr.next.len > 0) state = tr.next;
            if (input.len > 0) {
                if (!tr.revisit) input = matches.rem;
                if (!tr.cont) break;
            } else return output.items;
        }
        if (watchdog <= 0) return ctx.fail("mhchem bug U. Please report.");
    }
}

fn optStr(o: tbl.Opt) []const u8 {
    return switch (o) {
        .str => |s| s,
        else => "",
    };
}

fn optInt(o: tbl.Opt) ?i64 {
    return switch (o) {
        .int => |i| i,
        else => null,
    };
}

fn optFlag(o: tbl.Opt) bool {
    return switch (o) {
        .flag => |f| f,
        else => false,
    };
}

fn runAction(ctx: *Ctx, machine: []const u8, name: []const u8, buf: *Buffer, m: Val, opt: tbl.Opt) Error!Out {
    if (try machineAction(ctx, machine, name, buf, m, opt)) |o| return o;
    return genericAction(ctx, name, buf, m, opt);
}

fn many(ctx: *Ctx, items: []const Item) Error!Out {
    _ = ctx;
    return .{ .many = items };
}

fn genericAction(ctx: *Ctx, name: []const u8, buf: *Buffer, m: Val, opt: tbl.Opt) Error!Out {
    const eq = std.mem.eql;
    if (eq(u8, name, "a=")) {
        buf.a = try cat(ctx, buf.a, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "b=")) {
        buf.b = try cat(ctx, buf.b, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "p=")) {
        buf.p = try cat(ctx, buf.p, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "o=")) {
        buf.o = try cat(ctx, buf.o, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "o=+p1")) {
        buf.o = try cat(ctx, buf.o, optStr(opt));
        return .none;
    }
    if (eq(u8, name, "q=")) {
        buf.q = try cat(ctx, buf.q, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "d=")) {
        buf.d = try cat(ctx, buf.d, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "rm=")) {
        buf.rm = try cat(ctx, buf.rm, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "text=")) {
        buf.text_ = try cat(ctx, buf.text_, try valStr(ctx, m));
        return .none;
    }
    if (eq(u8, name, "insert")) return one(ctx, .{ .t = optStr(opt) });
    if (eq(u8, name, "insert+p1")) return one(ctx, .{ .t = optStr(opt), .p1 = .{ .s = try valStr(ctx, m) } });
    if (eq(u8, name, "insert+p1+p2")) {
        const arr = if (m == .arr) m.arr else &[_]?[]const u8{};
        return one(ctx, .{ .t = optStr(opt), .p1 = .{ .s = if (arr.len > 0) str(arr[0]) else "" }, .p2 = .{ .s = if (arr.len > 1) str(arr[1]) else "" } });
    }
    if (eq(u8, name, "copy")) {
        switch (m) {
            .s => |s| return .{ .one = .{ .s = s } },
            .arr => |arr| {
                var out: std.ArrayList(Item) = .empty;
                for (arr) |e| if (e) |s| try out.append(ctx.a, .{ .s = s });
                return .{ .many = out.items };
            },
        }
    }
    if (eq(u8, name, "write")) return .{ .one = .{ .s = optStr(opt) } };
    if (eq(u8, name, "rm")) return one(ctx, .{ .t = "rm", .p1 = .{ .s = try valStr(ctx, m) } });
    if (eq(u8, name, "text")) return many(ctx, try go(ctx, try valStr(ctx, m), "text"));
    if (eq(u8, name, "tex-math")) return many(ctx, try go(ctx, try valStr(ctx, m), "tex-math"));
    if (eq(u8, name, "tex-math tight")) return many(ctx, try go(ctx, try valStr(ctx, m), "tex-math tight"));
    if (eq(u8, name, "bond")) {
        const k = optStr(opt);
        return one(ctx, .{ .t = "bond", .kind = if (k.len > 0) k else try valStr(ctx, m) });
    }
    if (eq(u8, name, "color0-output")) return one(ctx, .{ .t = "color0", .color = try valStr(ctx, m) });
    if (eq(u8, name, "ce")) return many(ctx, try go(ctx, try valStr(ctx, m), "ce"));
    if (eq(u8, name, "pu")) return many(ctx, try go(ctx, try valStr(ctx, m), "pu"));
    if (eq(u8, name, "9,9")) return many(ctx, try go(ctx, try valStr(ctx, m), "9,9"));
    if (eq(u8, name, "1/2")) {
        var ret: std.ArrayList(Item) = .empty;
        var text = try valStr(ctx, m);
        if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
            try ret.append(ctx.a, .{ .s = text[0..1] });
            text = text[1..];
        }
        const r = (try ctx.rx("^([0-9]+|\\$[a-z]\\$|[a-z])\\/([0-9]+)(\\$[a-z]\\$|[a-z])?$", text)) orelse return ctx.fail("mhchem bug A. Please report.");
        try ret.append(ctx.a, try mkObj(ctx, .{ .t = "frac", .p1 = .{ .s = try stripDollar(ctx, str(Ctx.cap(r, text, 1))) }, .p2 = .{ .s = str(Ctx.cap(r, text, 2)) } }));
        if (Ctx.cap(r, text, 3)) |n3| try ret.append(ctx.a, try mkObj(ctx, .{ .t = "tex-math", .p1 = .{ .s = try stripDollar(ctx, n3) } }));
        return .{ .many = ret.items };
    }
    return ctx.fail("mhchem bug A. Please report.");
}

fn stripDollar(ctx: *Ctx, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (c != '$') try out.append(ctx.a, c);
    return out.items;
}

fn replaceAll(ctx: *Ctx, s: []const u8, from: []const []const u8, to: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        for (from) |f| {
            if (std.mem.startsWith(u8, s[i..], f)) {
                try out.appendSlice(ctx.a, to);
                i += f.len;
                continue :outer;
            }
        }
        try out.append(ctx.a, s[i]);
        i += 1;
    }
    return out.items;
}

fn eqName(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn matchOk(ctx: *Ctx, name: []const u8, input: []const u8) Error!?MatchRes {
    return matchPattern(ctx, name, input);
}

fn machineAction(ctx: *Ctx, machine: []const u8, name: []const u8, buf: *Buffer, m: Val, opt: tbl.Opt) Error!?Out {
    if (eqName(machine, "ce")) return ceAction(ctx, name, buf, m, opt);
    if (eqName(machine, "text") and eqName(name, "output")) {
        if (truthy(buf.text_)) {
            const o = try one(ctx, .{ .t = "text", .p1 = .{ .s = buf.text_.? } });
            buf.* = .{};
            return o;
        }
        return .none;
    }
    if (eqName(machine, "pq")) {
        if (eqName(name, "state of aggregation")) return try one(ctx, .{ .t = "state of aggregation subscript", .p1 = .{ .items = try go(ctx, try valStr(ctx, m), "o") } });
        if (eqName(name, "color-output")) return try one(ctx, .{ .t = "color", .color1 = str(m.arr[0]), .color2 = try go(ctx, m.arr[1], "pq") });
    }
    if (eqName(machine, "bd") and eqName(name, "color-output")) {
        return try one(ctx, .{ .t = "color", .color1 = str(m.arr[0]), .color2 = try go(ctx, m.arr[1], "bd") });
    }
    if (eqName(machine, "oxidation") and eqName(name, "roman-numeral")) return try one(ctx, .{ .t = "roman numeral", .p1 = .{ .s = str(buf.o) } });
    if (eqName(machine, "tex-math") or eqName(machine, "tex-math tight")) {
        if (eqName(name, "output")) {
            if (truthy(buf.o)) {
                const o = try one(ctx, .{ .t = "tex-math", .p1 = .{ .s = buf.o.? } });
                buf.* = .{};
                return o;
            }
            return .none;
        }
        if (eqName(machine, "tex-math tight") and eqName(name, "tight operator")) {
            buf.o = try std.mem.concat(ctx.a, u8, &.{ str(buf.o), "{", try valStr(ctx, m), "}" });
            return .none;
        }
    }
    if (eqName(machine, "9,9") and eqName(name, "comma")) return try one(ctx, .{ .t = "commaDecimal" });
    if (eqName(machine, "pu")) return puAction(ctx, name, buf, m, opt);
    if (eqName(machine, "pu-2")) return pu2Action(ctx, name, buf, m);
    if (eqName(machine, "pu-9,9")) return pu99Action(ctx, name, buf, m);
    return null;
}

fn ceOutput(ctx: *Ctx, buf: *Buffer, entity: ?i64) Error!Out {
    var result: Out = undefined_out;
    if (!truthy(buf.r)) {
        var ret: std.ArrayList(Item) = .empty;
        const none = !truthy(buf.a) and !truthy(buf.b) and !truthy(buf.p) and !truthy(buf.o) and !truthy(buf.q) and !truthy(buf.d) and entity == null;
        if (!none) {
            if (buf.sb) try ret.append(ctx.a, try mkObj(ctx, .{ .t = "entitySkip" }));
            if (!truthy(buf.o) and !truthy(buf.q) and !truthy(buf.d) and !truthy(buf.b) and !truthy(buf.p) and (entity == null or entity.? != 2)) {
                buf.o = buf.a;
                buf.a = null;
            } else if (!truthy(buf.o) and !truthy(buf.q) and !truthy(buf.d) and (truthy(buf.b) or truthy(buf.p))) {
                buf.o = buf.a;
                buf.d = buf.b;
                buf.q = buf.p;
                buf.a = null;
                buf.b = null;
                buf.p = null;
            } else {
                if (truthy(buf.o) and buf.d_type != null and eqName(buf.d_type.?, "kv") and (try matchPattern(ctx, "d-oxidation$", str(buf.d))) != null) {
                    buf.d_type = "oxidation";
                } else if (truthy(buf.o) and buf.d_type != null and eqName(buf.d_type.?, "kv") and !truthy(buf.q)) {
                    buf.d_type = null;
                }
            }
            const is_ox = buf.d_type != null and eqName(buf.d_type.?, "oxidation");
            try ret.append(ctx.a, try mkObj(ctx, .{
                .t = "chemfive",
                .a = try go(ctx, buf.a, "a"),
                .b = try go(ctx, buf.b, "bd"),
                .p = try go(ctx, buf.p, "pq"),
                .o = try go(ctx, buf.o, "o"),
                .q = try go(ctx, buf.q, "pq"),
                .d = try go(ctx, buf.d, if (is_ox) "oxidation" else "bd"),
                .d_type = buf.d_type,
            }));
        }
        result = .{ .many = ret.items };
    } else {
        const rd = try ceArrowPart(ctx, buf.rdt, buf.rd);
        const rq = try ceArrowPart(ctx, buf.rqt, buf.rq);
        result = try one(ctx, .{ .t = "arrow", .r = buf.r.?, .rd = rd, .rq = rq });
    }
    buf.clear();
    return result;
}

const undefined_out: Out = .none;

fn ceArrowPart(ctx: *Ctx, kind: ?[]const u8, text: ?[]const u8) Error![]const Item {
    if (kind != null and eqName(kind.?, "M")) return go(ctx, text, "tex-math");
    if (kind != null and eqName(kind.?, "T")) {
        const items = try ctx.a.alloc(Item, 1);
        items[0] = try mkObj(ctx, .{ .t = "text", .p1 = .{ .s = str(text) } });
        return items;
    }
    return go(ctx, text, "ce");
}

fn outItems(ctx: *Ctx, o: Out) Error![]Item {
    var list: std.ArrayList(Item) = .empty;
    switch (o) {
        .none => {},
        .one => |it| try list.append(ctx.a, it),
        .many => |xs| try list.appendSlice(ctx.a, xs),
    }
    return list.items;
}

fn ceAction(ctx: *Ctx, name: []const u8, buf: *Buffer, m: Val, opt: tbl.Opt) Error!?Out {
    if (eqName(name, "output")) return try ceOutput(ctx, buf, optInt(opt));
    if (eqName(name, "o after d")) {
        var ret: std.ArrayList(Item) = .empty;
        if (try matchOkRx(ctx, "^[1-9][0-9]*$", str(buf.d))) {
            const tmp = buf.d;
            buf.d = null;
            try ret.appendSlice(ctx.a, try outItems(ctx, try ceOutput(ctx, buf, null)));
            try ret.append(ctx.a, try mkObj(ctx, .{ .t = "tinySkip" }));
            buf.b = tmp;
        } else try ret.appendSlice(ctx.a, try outItems(ctx, try ceOutput(ctx, buf, null)));
        buf.o = try cat(ctx, buf.o, try valStr(ctx, m));
        return .{ .many = ret.items };
    }
    if (eqName(name, "d= kv")) {
        buf.d = try valStr(ctx, m);
        buf.d_type = "kv";
        return .none;
    }
    if (eqName(name, "charge or bond")) {
        if (buf.begins_with_bond) {
            var ret: std.ArrayList(Item) = .empty;
            try ret.appendSlice(ctx.a, try outItems(ctx, try ceOutput(ctx, buf, null)));
            try ret.append(ctx.a, try mkObj(ctx, .{ .t = "bond", .kind = "-" }));
            return .{ .many = ret.items };
        }
        buf.d = try valStr(ctx, m);
        return .none;
    }
    if (eqName(name, "- after o/d")) return try minusAfter(ctx, buf, m, optFlag(opt));
    if (eqName(name, "a to o")) {
        buf.o = buf.a;
        buf.a = null;
        return .none;
    }
    if (eqName(name, "sb=true")) {
        buf.sb = true;
        return .none;
    }
    if (eqName(name, "sb=false")) {
        buf.sb = false;
        return .none;
    }
    if (eqName(name, "beginsWithBond=true")) {
        buf.begins_with_bond = true;
        return .none;
    }
    if (eqName(name, "beginsWithBond=false")) {
        buf.begins_with_bond = false;
        return .none;
    }
    if (eqName(name, "parenthesisLevel++")) {
        buf.paren += 1;
        return .none;
    }
    if (eqName(name, "parenthesisLevel--")) {
        buf.paren -= 1;
        return .none;
    }
    if (eqName(name, "state of aggregation")) return try one(ctx, .{ .t = "state of aggregation", .p1 = .{ .items = try go(ctx, try valStr(ctx, m), "o") } });
    if (eqName(name, "comma")) {
        const text = try valStr(ctx, m);
        const a = std.mem.trimEnd(u8, text, " \t\r\n\x0b\x0c\xa0");
        const with_space = a.len != text.len;
        if (with_space and buf.paren == 0) return try one(ctx, .{ .t = "comma enumeration L", .p1 = .{ .s = a } });
        return try one(ctx, .{ .t = "comma enumeration M", .p1 = .{ .s = a } });
    }
    if (eqName(name, "oxidation-output")) {
        var ret: std.ArrayList(Item) = .empty;
        try ret.append(ctx.a, .{ .s = "{" });
        try ret.appendSlice(ctx.a, try go(ctx, try valStr(ctx, m), "oxidation"));
        try ret.append(ctx.a, .{ .s = "}" });
        return .{ .many = ret.items };
    }
    if (eqName(name, "frac-output")) return try one(ctx, .{ .t = "frac-ce", .p1 = .{ .items = try go(ctx, m.arr[0], "ce") }, .p2 = .{ .items = try go(ctx, m.arr[1], "ce") } });
    if (eqName(name, "overset-output")) return try one(ctx, .{ .t = "overset", .p1 = .{ .items = try go(ctx, m.arr[0], "ce") }, .p2 = .{ .items = try go(ctx, m.arr[1], "ce") } });
    if (eqName(name, "underset-output")) return try one(ctx, .{ .t = "underset", .p1 = .{ .items = try go(ctx, m.arr[0], "ce") }, .p2 = .{ .items = try go(ctx, m.arr[1], "ce") } });
    if (eqName(name, "underbrace-output")) return try one(ctx, .{ .t = "underbrace", .p1 = .{ .items = try go(ctx, m.arr[0], "ce") }, .p2 = .{ .items = try go(ctx, m.arr[1], "ce") } });
    if (eqName(name, "color-output")) return try one(ctx, .{ .t = "color", .color1 = str(m.arr[0]), .color2 = try go(ctx, m.arr[1], "ce") });
    if (eqName(name, "r=")) {
        buf.r = try valStr(ctx, m);
        return .none;
    }
    if (eqName(name, "rdt=")) {
        buf.rdt = try valStr(ctx, m);
        return .none;
    }
    if (eqName(name, "rd=")) {
        buf.rd = try valStr(ctx, m);
        return .none;
    }
    if (eqName(name, "rqt=")) {
        buf.rqt = try valStr(ctx, m);
        return .none;
    }
    if (eqName(name, "rq=")) {
        buf.rq = try valStr(ctx, m);
        return .none;
    }
    if (eqName(name, "operator")) {
        const k = optStr(opt);
        return try one(ctx, .{ .t = "operator", .kind = if (k.len > 0) k else try valStr(ctx, m) });
    }
    return null;
}

fn matchOkRx(ctx: *Ctx, src: []const u8, input: []const u8) Error!bool {
    return (try ctx.rx(src, input)) != null;
}

fn minusAfter(ctx: *Ctx, buf: *Buffer, m: Val, is_after_d: bool) Error!Out {
    const o = str(buf.o);
    var c1 = try matchPattern(ctx, "orbital", o);
    const c2 = try matchPattern(ctx, "one lowercase greek letter $", o);
    const c3 = try matchPattern(ctx, "one lowercase latin letter $", o);
    const c4 = try matchPattern(ctx, "$one lowercase latin letter$ $", o);
    const ms = try valStr(ctx, m);
    const hyphen_follows = eqName(ms, "-") and ((c1 != null and c1.?.rem.len == 0) or c2 != null or c3 != null or c4 != null);
    if (hyphen_follows and !truthy(buf.a) and !truthy(buf.b) and !truthy(buf.p) and !truthy(buf.d) and !truthy(buf.q) and c1 == null and c3 != null) {
        buf.o = try std.mem.concat(ctx.a, u8, &.{ "$", str(buf.o), "$" });
    }
    var ret: std.ArrayList(Item) = .empty;
    if (hyphen_follows) {
        try ret.appendSlice(ctx.a, try outItems(ctx, try ceOutput(ctx, buf, null)));
        try ret.append(ctx.a, try mkObj(ctx, .{ .t = "hyphen" }));
    } else {
        c1 = try matchPattern(ctx, "digits", str(buf.d));
        if (is_after_d and c1 != null and c1.?.rem.len == 0) {
            buf.d = try cat(ctx, buf.d, ms);
            try ret.appendSlice(ctx.a, try outItems(ctx, try ceOutput(ctx, buf, null)));
        } else {
            try ret.appendSlice(ctx.a, try outItems(ctx, try ceOutput(ctx, buf, null)));
            try ret.append(ctx.a, try mkObj(ctx, .{ .t = "bond", .kind = "-" }));
        }
    }
    return .{ .many = ret.items };
}

fn puAction(ctx: *Ctx, name: []const u8, buf: *Buffer, m: Val, opt: tbl.Opt) Error!?Out {
    if (eqName(name, "enumber")) {
        const arr = m.arr;
        var ret: std.ArrayList(Item) = .empty;
        const g0 = str(arr[0]);
        if (eqName(g0, "+-") or eqName(g0, "+/-")) {
            try ret.append(ctx.a, .{ .s = "\\pm " });
        } else if (g0.len > 0) try ret.append(ctx.a, .{ .s = g0 });
        if (truthy(arr[1])) {
            try ret.appendSlice(ctx.a, try go(ctx, arr[1], "pu-9,9"));
            if (truthy(arr[2])) {
                if (std.mem.indexOfAny(u8, arr[2].?, ",.") != null) {
                    try ret.appendSlice(ctx.a, try go(ctx, arr[2], "pu-9,9"));
                } else try ret.append(ctx.a, .{ .s = arr[2].? });
            }
            if (truthy(arr[3]) or truthy(arr[4])) {
                if ((truthy(arr[3]) and eqName(arr[3].?, "e")) or (truthy(arr[4]) and eqName(arr[4].?, "*"))) {
                    try ret.append(ctx.a, try mkObj(ctx, .{ .t = "cdot" }));
                } else try ret.append(ctx.a, try mkObj(ctx, .{ .t = "times" }));
            }
        }
        if (truthy(arr[5])) try ret.append(ctx.a, .{ .s = try std.mem.concat(ctx.a, u8, &.{ "10^{", arr[5].?, "}" }) });
        return .{ .many = ret.items };
    }
    if (eqName(name, "number^")) {
        const arr = m.arr;
        var ret: std.ArrayList(Item) = .empty;
        const g0 = str(arr[0]);
        if (eqName(g0, "+-") or eqName(g0, "+/-")) {
            try ret.append(ctx.a, .{ .s = "\\pm " });
        } else if (g0.len > 0) try ret.append(ctx.a, .{ .s = g0 });
        try ret.appendSlice(ctx.a, try go(ctx, arr[1], "pu-9,9"));
        try ret.append(ctx.a, .{ .s = try std.mem.concat(ctx.a, u8, &.{ "^{", str(arr[2]), "}" }) });
        return .{ .many = ret.items };
    }
    if (eqName(name, "operator")) {
        const k = optStr(opt);
        return try one(ctx, .{ .t = "operator", .kind = if (k.len > 0) k else try valStr(ctx, m) });
    }
    if (eqName(name, "space")) return try one(ctx, .{ .t = "pu-space-1" });
    if (eqName(name, "output")) return try puOutput(ctx, buf);
    return null;
}

fn puOutput(ctx: *Ctx, buf: *Buffer) Error!Out {
    const md = try matchPattern(ctx, "{(...)}", str(buf.d));
    if (md != null and md.?.rem.len == 0) buf.d = md.?.v.s;
    const mq = try matchPattern(ctx, "{(...)}", str(buf.q));
    if (mq != null and mq.?.rem.len == 0) buf.q = mq.?.v.s;
    if (truthy(buf.d)) {
        buf.d = try replaceAll(ctx, buf.d.?, &.{ "\u{b0}C", "^oC", "^{o}C" }, "{}^{\\circ}C");
        buf.d = try replaceAll(ctx, buf.d.?, &.{ "\u{b0}F", "^oF", "^{o}F" }, "{}^{\\circ}F");
    }
    var ret: std.ArrayList(Item) = .empty;
    if (truthy(buf.q)) {
        buf.q = try replaceAll(ctx, buf.q.?, &.{ "\u{b0}C", "^oC", "^{o}C" }, "{}^{\\circ}C");
        buf.q = try replaceAll(ctx, buf.q.?, &.{ "\u{b0}F", "^oF", "^{o}F" }, "{}^{\\circ}F");
        const bd = try go(ctx, buf.d, "pu");
        const bq = try go(ctx, buf.q, "pu");
        if (buf.o != null and eqName(buf.o.?, "//")) {
            buf.clear();
            buf.* = .{};
            return try one(ctx, .{ .t = "pu-frac", .p1 = .{ .items = bd }, .p2 = .{ .items = bq } });
        }
        try ret.appendSlice(ctx.a, bd);
        if (bd.len > 1 or bq.len > 1) {
            try ret.append(ctx.a, try mkObj(ctx, .{ .t = " / " }));
        } else try ret.append(ctx.a, try mkObj(ctx, .{ .t = "/" }));
        try ret.appendSlice(ctx.a, bq);
    } else {
        try ret.appendSlice(ctx.a, try go(ctx, buf.d, "pu-2"));
    }
    buf.* = .{};
    return .{ .many = ret.items };
}

fn pu2Action(ctx: *Ctx, name: []const u8, buf: *Buffer, m: Val) Error!?Out {
    if (eqName(name, "cdot")) return try one(ctx, .{ .t = "tight cdot" });
    if (eqName(name, "^(-1)")) {
        buf.rm = try std.mem.concat(ctx.a, u8, &.{ str(buf.rm), "^{", try valStr(ctx, m), "}" });
        return .none;
    }
    if (eqName(name, "space")) return try one(ctx, .{ .t = "pu-space-2" });
    if (eqName(name, "output")) {
        var out: Out = .{ .many = &.{} };
        if (truthy(buf.rm)) {
            const mrm = try matchPattern(ctx, "{(...)}", buf.rm.?);
            if (mrm != null and mrm.?.rem.len == 0) {
                out = .{ .many = try go(ctx, mrm.?.v.s, "pu") };
            } else out = try one(ctx, .{ .t = "rm", .p1 = .{ .s = buf.rm.? } });
        }
        buf.* = .{};
        return out;
    }
    return null;
}

fn pu99Action(ctx: *Ctx, name: []const u8, buf: *Buffer, m: Val) Error!?Out {
    _ = m;
    if (eqName(name, "comma")) return try one(ctx, .{ .t = "commaDecimal" });
    if (eqName(name, "output-0")) {
        var ret: std.ArrayList(Item) = .empty;
        const text = str(buf.text_);
        if (text.len > 4) {
            var a = text.len % 3;
            if (a == 0) a = 3;
            var i: isize = @as(isize, @intCast(text.len)) - 3;
            while (i > 0) : (i -= 3) {
                try ret.append(ctx.a, .{ .s = text[@intCast(i)..@min(text.len, @as(usize, @intCast(i)) + 3)] });
                try ret.append(ctx.a, try mkObj(ctx, .{ .t = "1000 separator" }));
            }
            try ret.append(ctx.a, .{ .s = text[0..a] });
            std.mem.reverse(Item, ret.items);
        } else try ret.append(ctx.a, .{ .s = text });
        buf.* = .{};
        return .{ .many = ret.items };
    }
    if (eqName(name, "output-o")) {
        var ret: std.ArrayList(Item) = .empty;
        const text = str(buf.text_);
        if (text.len > 4) {
            const a = text.len - 3;
            var i: usize = 0;
            while (i < a) : (i += 3) {
                try ret.append(ctx.a, .{ .s = text[i..@min(text.len, i + 3)] });
                try ret.append(ctx.a, try mkObj(ctx, .{ .t = "1000 separator" }));
            }
            try ret.append(ctx.a, .{ .s = text[i..] });
        } else try ret.append(ctx.a, .{ .s = text });
        buf.* = .{};
        return .{ .many = ret.items };
    }
    return null;
}

// ---- TeX output ----

fn texGo(ctx: *Ctx, items: []const Item, outer_braces: bool) Error![]const u8 {
    var res: std.ArrayList(u8) = .empty;
    var cee = false;
    for (items) |it| {
        switch (it) {
            .s => |s| try res.appendSlice(ctx.a, s),
            .o => |o| {
                try res.appendSlice(ctx.a, try texGo2(ctx, o));
                if (eqName(o.t, "1st-level escape")) cee = true;
            },
        }
    }
    if (outer_braces and !cee and res.items.len > 0) {
        return std.mem.concat(ctx.a, u8, &.{ "{", res.items, "}" });
    }
    return res.items;
}

fn inner(ctx: *Ctx, items: []const Item) Error![]const u8 {
    return texGo(ctx, items, false);
}

fn pvItems(v: ?Pv) []const Item {
    if (v) |p| switch (p) {
        .items => |i| return i,
        .s => {},
    };
    return &.{};
}

fn pvStr(v: ?Pv) []const u8 {
    if (v) |p| switch (p) {
        .s => |s| return s,
        .items => {},
    };
    return "";
}

fn signed(s: []const u8) bool {
    return s.len > 0 and (s[0] == '+' or s[0] == '-');
}

fn cc(ctx: *Ctx, parts: []const []const u8) Error![]const u8 {
    return std.mem.concat(ctx.a, u8, parts);
}

fn texGo2(ctx: *Ctx, buf: *const Obj) Error![]const u8 {
    const t = buf.t;
    if (eqName(t, "chemfive")) {
        var res: std.ArrayList(u8) = .empty;
        var ba = try inner(ctx, buf.a);
        const bb = try inner(ctx, buf.b);
        const bp = try inner(ctx, buf.p);
        var bo = try inner(ctx, buf.o);
        const bq = try inner(ctx, buf.q);
        const bd = try inner(ctx, buf.d);
        if (ba.len > 0) {
            if (signed(ba)) ba = try cc(ctx, &.{ "{", ba, "}" });
            try res.appendSlice(ctx.a, try cc(ctx, &.{ ba, "\\," }));
        }
        if (bb.len > 0 or bp.len > 0) {
            try res.appendSlice(ctx.a, "{\\vphantom{A}}");
            try res.appendSlice(ctx.a, try cc(ctx, &.{ "^{\\hphantom{", bb, "}}_{\\hphantom{", bp, "}}" }));
            try res.appendSlice(ctx.a, "\\mkern-1.5mu");
            try res.appendSlice(ctx.a, "{\\vphantom{A}}");
            try res.appendSlice(ctx.a, try cc(ctx, &.{ "^{\\smash[t]{\\vphantom{2}}\\llap{", bb, "}}" }));
            try res.appendSlice(ctx.a, try cc(ctx, &.{ "_{\\vphantom{2}\\llap{\\smash[t]{", bp, "}}}" }));
        }
        if (bo.len > 0) {
            if (signed(bo)) bo = try cc(ctx, &.{ "{", bo, "}" });
            try res.appendSlice(ctx.a, bo);
        }
        const dt = buf.d_type orelse "";
        if (eqName(dt, "kv")) {
            if (bd.len > 0 or bq.len > 0) try res.appendSlice(ctx.a, "{\\vphantom{A}}");
            if (bd.len > 0) try res.appendSlice(ctx.a, try cc(ctx, &.{ "^{", bd, "}" }));
            if (bq.len > 0) try res.appendSlice(ctx.a, try cc(ctx, &.{ "_{\\smash[t]{", bq, "}}" }));
        } else if (eqName(dt, "oxidation")) {
            if (bd.len > 0) {
                try res.appendSlice(ctx.a, "{\\vphantom{A}}");
                try res.appendSlice(ctx.a, try cc(ctx, &.{ "^{", bd, "}" }));
            }
            if (bq.len > 0) {
                try res.appendSlice(ctx.a, "{\\vphantom{A}}");
                try res.appendSlice(ctx.a, try cc(ctx, &.{ "_{\\smash[t]{", bq, "}}" }));
            }
        } else {
            if (bq.len > 0) {
                try res.appendSlice(ctx.a, "{\\vphantom{A}}");
                try res.appendSlice(ctx.a, try cc(ctx, &.{ "_{\\smash[t]{", bq, "}}" }));
            }
            if (bd.len > 0) {
                try res.appendSlice(ctx.a, "{\\vphantom{A}}");
                try res.appendSlice(ctx.a, try cc(ctx, &.{ "^{", bd, "}" }));
            }
        }
        return res.items;
    }
    if (eqName(t, "rm")) return cc(ctx, &.{ "\\mathrm{", pvStr(buf.p1), "}" });
    if (eqName(t, "text")) {
        const p1 = pvStr(buf.p1);
        if (std.mem.indexOfAny(u8, p1, "^_") != null) {
            var s = try replaceFirst(ctx, p1, " ", "~");
            s = try replaceFirst(ctx, s, "-", "\\text{-}");
            return cc(ctx, &.{ "\\mathrm{", s, "}" });
        }
        return cc(ctx, &.{ "\\text{", p1, "}" });
    }
    if (eqName(t, "roman numeral")) return cc(ctx, &.{ "\\mathrm{", pvStr(buf.p1), "}" });
    if (eqName(t, "state of aggregation")) return cc(ctx, &.{ "\\mskip2mu ", try inner(ctx, pvItems(buf.p1)) });
    if (eqName(t, "state of aggregation subscript")) return cc(ctx, &.{ "\\mskip1mu ", try inner(ctx, pvItems(buf.p1)) });
    if (eqName(t, "bond")) {
        return getBond(buf.kind) orelse {
            return ctx.fail(try cc(ctx, &.{ "mhchem Error. Unknown bond type (", buf.kind, ")" }));
        };
    }
    if (eqName(t, "frac")) {
        const c = try cc(ctx, &.{ "\\frac{", pvStr(buf.p1), "}{", pvStr(buf.p2), "}" });
        return cc(ctx, &.{ "\\mathchoice{\\textstyle", c, "}{", c, "}{", c, "}{", c, "}" });
    }
    if (eqName(t, "pu-frac")) {
        const d = try cc(ctx, &.{ "\\frac{", try inner(ctx, pvItems(buf.p1)), "}{", try inner(ctx, pvItems(buf.p2)), "}" });
        return cc(ctx, &.{ "\\mathchoice{\\textstyle", d, "}{", d, "}{", d, "}{", d, "}" });
    }
    if (eqName(t, "tex-math")) return cc(ctx, &.{ pvStr(buf.p1), " " });
    if (eqName(t, "frac-ce")) return cc(ctx, &.{ "\\frac{", try inner(ctx, pvItems(buf.p1)), "}{", try inner(ctx, pvItems(buf.p2)), "}" });
    if (eqName(t, "overset")) return cc(ctx, &.{ "\\overset{", try inner(ctx, pvItems(buf.p1)), "}{", try inner(ctx, pvItems(buf.p2)), "}" });
    if (eqName(t, "underset")) return cc(ctx, &.{ "\\underset{", try inner(ctx, pvItems(buf.p1)), "}{", try inner(ctx, pvItems(buf.p2)), "}" });
    if (eqName(t, "underbrace")) return cc(ctx, &.{ "\\underbrace{", try inner(ctx, pvItems(buf.p1)), "}_{", try inner(ctx, pvItems(buf.p2)), "}" });
    if (eqName(t, "color")) return cc(ctx, &.{ "{\\color{", buf.color1, "}{", try inner(ctx, buf.color2), "}}" });
    if (eqName(t, "color0")) return cc(ctx, &.{ "\\color{", buf.color, "}" });
    if (eqName(t, "arrow")) return texArrow(ctx, buf);
    if (eqName(t, "operator")) return getOperator(buf.kind) orelse ctx.fail("mhchem bug T. Please report.");
    if (eqName(t, "1st-level escape")) return cc(ctx, &.{ pvStr(buf.p1), " " });
    const simple = [_][2][]const u8{
        .{ "space", " " },
        .{ "tinySkip", "\\mkern2mu" },
        .{ "entitySkip", "~" },
        .{ "pu-space-1", "~" },
        .{ "pu-space-2", "\\mkern3mu " },
        .{ "1000 separator", "\\mkern2mu " },
        .{ "commaDecimal", "{,}" },
        .{ "hyphen", "\\text{-}" },
        .{ "addition compound", "\\,{\\cdot}\\," },
        .{ "electron dot", "\\mkern1mu \\bullet\\mkern1mu " },
        .{ "KV x", "{\\times}" },
        .{ "prime", "\\prime " },
        .{ "cdot", "\\cdot " },
        .{ "tight cdot", "\\mkern1mu{\\cdot}\\mkern1mu " },
        .{ "times", "\\times " },
        .{ "circa", "{\\sim}" },
        .{ "^", "uparrow" },
        .{ "v", "downarrow" },
        .{ "ellipsis", "\\ldots " },
        .{ "/", "/" },
        .{ " / ", "\\,/\\," },
    };
    for (simple) |s| if (eqName(t, s[0])) return s[1];
    if (eqName(t, "comma enumeration L")) return cc(ctx, &.{ "{", pvStr(buf.p1), "}\\mkern6mu " });
    if (eqName(t, "comma enumeration M")) return cc(ctx, &.{ "{", pvStr(buf.p1), "}\\mkern3mu " });
    if (eqName(t, "comma enumeration S")) return cc(ctx, &.{ "{", pvStr(buf.p1), "}\\mkern1mu " });
    return ctx.fail("mhchem bug T. Please report.");
}

fn replaceFirst(ctx: *Ctx, s: []const u8, from: []const u8, to: []const u8) Error![]const u8 {
    const at = std.mem.indexOf(u8, s, from) orelse return s;
    return cc(ctx, &.{ s[0..at], to, s[at + from.len ..] });
}

fn texArrow(ctx: *Ctx, buf: *const Obj) Error![]const u8 {
    const rd = try inner(ctx, buf.rd);
    const rq = try inner(ctx, buf.rq);
    const r = buf.r;
    const name = getArrow(r) orelse return ctx.fail("mhchem bug T. Please report.");
    var arrow: []const u8 = name;
    if (rd.len > 0 or rq.len > 0) {
        if (eqName(r, "<=>") or eqName(r, "<=>>") or eqName(r, "<<=>") or eqName(r, "<-->")) {
            arrow = try cc(ctx, &.{ "\\long", arrow });
            if (rd.len > 0) arrow = try cc(ctx, &.{ "\\overset{", rd, "}{", arrow, "}" });
            if (rq.len > 0) {
                if (eqName(r, "<-->")) {
                    arrow = try cc(ctx, &.{ "\\underset{\\lower2mu{", rq, "}}{", arrow, "}" });
                } else arrow = try cc(ctx, &.{ "\\underset{\\lower6mu{", rq, "}}{", arrow, "}" });
            }
            return cc(ctx, &.{ " {}\\mathrel{", arrow, "}{} " });
        }
        if (rq.len > 0) arrow = try cc(ctx, &.{ arrow, "[{", rq, "}]" });
        arrow = try cc(ctx, &.{ arrow, "{", rd, "}" });
        return cc(ctx, &.{ " {}\\mathrel{\\x", arrow, "}{} " });
    }
    return cc(ctx, &.{ " {}\\mathrel{\\long", arrow, "}{} " });
}

fn getArrow(a: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "->", "rightarrow" },
        .{ "\u{2192}", "rightarrow" },
        .{ "\u{27f6}", "rightarrow" },
        .{ "<-", "leftarrow" },
        .{ "<->", "leftrightarrow" },
        .{ "<-->", "leftrightarrows" },
        .{ "<=>", "rightleftharpoons" },
        .{ "\u{21cc}", "rightleftharpoons" },
        .{ "<=>>", "Rightleftharpoons" },
        .{ "<<=>", "Leftrightharpoons" },
    };
    for (map) |e| if (eqName(a, e[0])) return e[1];
    return null;
}

fn getBond(a: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "-", "{-}" },
        .{ "1", "{-}" },
        .{ "=", "{=}" },
        .{ "2", "{=}" },
        .{ "#", "{\\equiv}" },
        .{ "3", "{\\equiv}" },
        .{ "~", "{\\tripledash}" },
        .{ "~-", "{\\rlap{\\lower.1em{-}}\\raise.1em{\\tripledash}}" },
        .{ "~=", "{\\rlap{\\lower.2em{-}}\\rlap{\\raise.2em{\\tripledash}}-}" },
        .{ "~--", "{\\rlap{\\lower.2em{-}}\\rlap{\\raise.2em{\\tripledash}}-}" },
        .{ "-~-", "{\\rlap{\\lower.2em{-}}\\rlap{\\raise.2em{-}}\\tripledash}" },
        .{ "...", "{{\\cdot}{\\cdot}{\\cdot}}" },
        .{ "....", "{{\\cdot}{\\cdot}{\\cdot}{\\cdot}}" },
        .{ "->", "{\\rightarrow}" },
        .{ "<-", "{\\leftarrow}" },
        .{ "<", "{<}" },
        .{ ">", "{>}" },
    };
    for (map) |e| if (eqName(a, e[0])) return e[1];
    return null;
}

fn getOperator(a: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "+", " {}+{} " },
        .{ "-", " {}-{} " },
        .{ "=", " {}={} " },
        .{ "<", " {}<{} " },
        .{ ">", " {}>{} " },
        .{ "<<", " {}\\ll{} " },
        .{ ">>", " {}\\gg{} " },
        .{ "\\pm", " {}\\pm{} " },
        .{ "\\approx", " {}\\approx{} " },
        .{ "$\\approx$", " {}\\approx{} " },
        .{ "v", " \\downarrow{} " },
        .{ "(v)", " \\downarrow{} " },
        .{ "^", " \\uparrow{} " },
        .{ "(^)", " \\uparrow{} " },
    };
    for (map) |e| if (eqName(a, e[0])) return e[1];
    return null;
}

/// TeX for `\ce{input}` (`machine` "ce") or `\pu{input}` ("pu"); on failure `err` holds the message.
pub fn toTex(a: Allocator, input: []const u8, machine: []const u8, err: *?[]const u8) Allocator.Error!?[]const u8 {
    var ctx: Ctx = .{ .a = a };
    const items = go(&ctx, input, machine) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Mhchem => {
            err.* = ctx.err;
            return null;
        },
    };
    const tex = texGo(&ctx, items, !eqName(machine, "tex")) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Mhchem => {
            err.* = ctx.err;
            return null;
        },
    };
    return tex;
}
