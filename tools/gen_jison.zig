const std = @import("std");
const files = @import("files.zig");
const rt = @import("jison_runtime");
const scanners = @import("jison_scanners.zig");
const Allocator = std.mem.Allocator;

const Tk = enum(u16) {
    eof = 3,
    pct_pct,
    lparen,
    rparen,
    star,
    quest,
    plus,
    alias,
    id,
    string,
    colon,
    semi,
    bar,
    prec,
    start,
    left,
    right,
    nonassoc,
    parse_param,
    options,
    lex_block,
    action,
    lbrace,
    arrow_action,
    rbrace,
    action_body,
    code,
    name,
    gt,
    comma,
    character_lit,
    start_cond,
    string_lit,
    any_group_regex,
    special_group,
    caret,
    dollar,
    lt,
    slash_bang,
    slash,
    escape_char,
    dot,
    start_inc,
    start_exc,
    range_regex,
    name_brace,
};

fn tk(t: Tk) u16 {
    return @backingInt(t);
}

const Token = struct { tk: Tk, text: []const u8 };

const Fail = error{ BadGrammar, OutOfMemory } || rt.regex.Error;

fn bad(comptime fmt: []const u8, args: anytype) Fail {
    std.log.err("gen-jison: " ++ fmt, args);
    return error.BadGrammar;
}

fn utf8(a: Allocator, s: []const u16) Allocator.Error![]const u8 {
    return rt.toUtf8(a, s);
}

fn collect(comptime G: type, a: Allocator, text: []const u8, actions: anytype) Fail![]Token {
    const input = try rt.toUtf16(a, text);
    var diag: rt.Diag = .{};
    var lx = rt.Lexer(G).init(a, input, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return bad("scanner table: {s}", .{@errorName(e)}),
    };
    defer lx.deinit();
    var out: std.ArrayList(Token) = .empty;
    while (true) {
        const t = lx.lex(actions) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return bad("{s}", .{diag.message}),
        };
        if (t == rt.eof_symbol or t == tk(.eof)) {
            try out.append(a, .{ .tk = .eof, .text = "" });
            break;
        }
        try out.append(a, .{ .tk = @fromBackingInt(@intCast(t)), .text = try utf8(a, lx.yytext) });
    }
    return out.items;
}

const BnfScan = struct {
    depth: usize = 0,
    ebnf: bool = false,

    pub fn lexAction(self: *BnfScan, lx: *rt.Lexer(scanners.BnfLex), rule: u16) rt.Error!?u16 {
        const C = scanners.BnfLex.cond;
        const n = lx.yytext.len;
        switch (rule) {
            0 => {
                try lx.pushState(C.code);
                return tk(.pct_pct);
            },
            1 => return tk(.lparen),
            2 => return tk(.rparen),
            3 => return tk(.star),
            4 => return tk(.quest),
            5 => return tk(.plus),
            6, 7, 8, 26, 27, 32 => return null,
            9 => {
                lx.yytext = lx.yytext[1 .. n - 1];
                return tk(.alias);
            },
            10 => return tk(.id),
            11, 12 => {
                lx.yytext = lx.yytext[1 .. n - 1];
                return tk(.string);
            },
            13 => return tk(.colon),
            14 => return tk(.semi),
            15 => return tk(.bar),
            16 => {
                try lx.pushState(if (self.ebnf) C.ebnf else C.bnf);
                return tk(.pct_pct);
            },
            17 => {
                self.ebnf = true;
                return null;
            },
            18 => return tk(.prec),
            19 => return tk(.start),
            20 => return tk(.left),
            21 => return tk(.right),
            22 => return tk(.nonassoc),
            23 => return tk(.parse_param),
            24 => return tk(.options),
            25 => return tk(.lex_block),
            28, 29 => {
                lx.yytext = lx.yytext[2 .. n - 2];
                return tk(.action);
            },
            30 => {
                self.depth = 0;
                try lx.pushState(C.action);
                return tk(.lbrace);
            },
            31 => {
                lx.yytext = lx.yytext[2..];
                return tk(.arrow_action);
            },
            33 => return tk(.eof),
            34, 35, 36, 37, 38, 39, 40 => return tk(.action_body),
            41 => {
                self.depth += 1;
                return tk(.lbrace);
            },
            42 => {
                if (self.depth == 0) try lx.begin(if (self.ebnf) C.ebnf else C.bnf) else self.depth -= 1;
                return tk(.rbrace);
            },
            43 => return tk(.code),
            else => unreachable,
        }
    }
};

const LexScan = struct {
    depth: usize = 0,
    options: std.ArrayList([]const u8) = .empty,
    a: Allocator,

    fn replaceAll(self: *LexScan, s: []const u16, from: []const u16, to: u16) Allocator.Error![]const u16 {
        var out: std.ArrayList(u16) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (std.mem.startsWith(u16, s[i..], from)) {
                try out.append(self.a, to);
                i += from.len;
            } else {
                try out.append(self.a, s[i]);
                i += 1;
            }
        }
        return out.items;
    }

    pub fn lexAction(self: *LexScan, lx: *rt.Lexer(scanners.LexLex), rule: u16) rt.Error!?u16 {
        const C = scanners.LexLex.cond;
        const n = lx.yytext.len;
        switch (rule) {
            0, 1, 2, 3, 4, 5, 6 => return tk(.action_body),
            7 => {
                self.depth += 1;
                return tk(.lbrace);
            },
            8 => {
                if (self.depth == 0) try lx.begin(C.trail) else self.depth -= 1;
                return tk(.rbrace);
            },
            9, 35 => return tk(.name),
            10 => {
                lx.popState();
                return tk(.gt);
            },
            11, 49 => return tk(.comma),
            12, 46 => return tk(.star),
            13, 14, 21, 25, 31, 32, 33, 34, 66 => return null,
            15 => {
                try lx.begin(C.indented);
                return null;
            },
            16 => {
                try lx.begin(C.code);
                return tk(.pct_pct);
            },
            17 => return tk(.character_lit),
            18 => {
                self.options.append(self.a, rt.toUtf8(self.a, lx.yytext) catch return error.OutOfMemory) catch return error.OutOfMemory;
                return null;
            },
            19, 20, 23, 24 => {
                try lx.begin(C.INITIAL);
                return null;
            },
            22 => return tk(.start_cond),
            26 => {
                try lx.begin(C.rules);
                return null;
            },
            27 => {
                self.depth = 0;
                try lx.begin(C.action);
                return tk(.lbrace);
            },
            28 => {
                try lx.begin(C.trail);
                lx.yytext = lx.yytext[2 .. n - 2];
                return tk(.action);
            },
            29 => {
                lx.yytext = lx.yytext[2 .. n - 2];
                return tk(.action);
            },
            30 => {
                try lx.begin(C.rules);
                return tk(.action);
            },
            36 => {
                lx.yytext = try self.replaceAll(lx.yytext, &.{ '\\', '"' }, '"');
                return tk(.string_lit);
            },
            37 => {
                lx.yytext = try self.replaceAll(lx.yytext, &.{ '\\', '\'' }, '\'');
                return tk(.string_lit);
            },
            38 => return tk(.bar),
            39 => return tk(.any_group_regex),
            40, 41, 42 => return tk(.special_group),
            43 => return tk(.lparen),
            44 => return tk(.rparen),
            45 => return tk(.plus),
            47 => return tk(.quest),
            48 => return tk(.caret),
            50, 56 => return tk(.dollar),
            51 => {
                try lx.begin(C.conditions);
                return tk(.lt);
            },
            52 => return tk(.slash_bang),
            53 => return tk(.slash),
            54 => return tk(.escape_char),
            55 => {
                lx.yytext = lx.yytext[1..];
                return tk(.escape_char);
            },
            57 => return tk(.dot),
            58 => {
                self.options.clearRetainingCapacity();
                try lx.begin(C.options);
                return null;
            },
            59 => {
                try lx.begin(C.start_condition);
                return tk(.start_inc);
            },
            60 => {
                try lx.begin(C.start_condition);
                return tk(.start_exc);
            },
            61 => {
                try lx.begin(C.rules);
                return tk(.pct_pct);
            },
            62 => return tk(.range_regex),
            63 => return tk(.name_brace),
            64 => return tk(.lbrace),
            65 => return tk(.rbrace),
            67 => return tk(.eof),
            68 => return tk(.code),
            else => unreachable,
        }
    }
};

const Handle = struct { rhs: []const u8, action: ?[]const u8, prec: ?[]const u8 };
const Rule = struct { lhs: []const u8, handles: std.ArrayList(Handle) };
const Operator = struct { assoc: []const u8, tokens: []const []const u8 };

const LexRule = struct { conds: ?[]const []const u8, pattern: []const u8, action: []const u8 };
const Cond = struct { name: []const u8, rules: std.ArrayList(u16), inclusive: bool };

const Lex = struct {
    case_insensitive: bool,
    conds: []Cond,
    rules: []LexRule,
};

const Grammar = struct {
    start: ?[]const u8 = null,
    lex_text: ?[]const u8 = null,
    operators: []const Operator = &.{},
    rules: []Rule = &.{},
};

const Cursor = struct {
    toks: []const Token,
    pos: usize = 0,

    fn peek(self: *const Cursor) Tk {
        return self.toks[self.pos].tk;
    }

    fn take(self: *Cursor) Token {
        const t = self.toks[self.pos];
        if (t.tk != .eof) self.pos += 1;
        return t;
    }

    fn expect(self: *Cursor, want: Tk) Fail!Token {
        const t = self.take();
        if (t.tk != want) return bad("expected {s}, found {s} '{s}'", .{ @tagName(want), @tagName(t.tk), t.text });
        return t;
    }

    fn actionBody(self: *Cursor, a: Allocator) Fail![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var depth: usize = 0;
        while (true) {
            const t = self.take();
            switch (t.tk) {
                .action_body => try out.appendSlice(a, t.text),
                .lbrace => {
                    depth += 1;
                    try out.append(a, '{');
                },
                .rbrace => {
                    if (depth == 0) return out.items;
                    depth -= 1;
                    try out.append(a, '}');
                },
                else => return bad("unterminated action", .{}),
            }
        }
    }
};

fn parseGrammar(a: Allocator, text: []const u8) Fail!Grammar {
    var scan: BnfScan = .{};
    const toks = try collect(scanners.BnfLex, a, text, &scan);
    var c: Cursor = .{ .toks = toks };
    var g: Grammar = .{};
    var ops: std.ArrayList(Operator) = .empty;
    while (c.peek() != .pct_pct) {
        const t = c.take();
        switch (t.tk) {
            .start => g.start = (try c.expect(.id)).text,
            .lex_block => g.lex_text = t.text,
            .left, .right, .nonassoc => {
                var syms: std.ArrayList([]const u8) = .empty;
                while (c.peek() == .id or c.peek() == .string) try syms.append(a, c.take().text);
                try ops.append(a, .{ .assoc = @tagName(t.tk), .tokens = syms.items });
            },
            .parse_param, .options => {
                while (c.peek() == .id or c.peek() == .string) _ = c.take();
            },
            .action => {},
            else => return bad("unexpected {s} '{s}' in declarations", .{ @tagName(t.tk), t.text }),
        }
    }
    _ = c.take();
    g.operators = ops.items;
    var rules: std.ArrayList(Rule) = .empty;
    while (c.peek() == .id) {
        const lhs = c.take().text;
        _ = try c.expect(.colon);
        var handles: std.ArrayList(Handle) = .empty;
        while (true) {
            var rhs: std.ArrayList(u8) = .empty;
            var first = true;
            while (c.peek() == .id or c.peek() == .string) {
                if (!first) try rhs.append(a, ' ');
                first = false;
                try rhs.appendSlice(a, c.take().text);
                if (c.peek() == .alias) try rhs.print(a, "[{s}]", .{c.take().text});
            }
            var prec: ?[]const u8 = null;
            if (c.peek() == .prec) {
                _ = c.take();
                if (c.peek() != .id and c.peek() != .string) return bad("%prec needs a symbol", .{});
                prec = c.take().text;
            }
            var action: ?[]const u8 = null;
            switch (c.peek()) {
                .lbrace => {
                    _ = c.take();
                    action = try c.actionBody(a);
                },
                .action => action = c.take().text,
                .arrow_action => action = try std.fmt.allocPrint(a, "$$ ={s};", .{c.take().text}),
                else => {},
            }
            if (action != null and action.?.len == 0) action = null;
            try handles.append(a, .{ .rhs = rhs.items, .action = action, .prec = prec });
            if (c.peek() == .bar) {
                _ = c.take();
                continue;
            }
            break;
        }
        _ = try c.expect(.semi);
        var merged = false;
        for (rules.items) |*r| if (std.mem.eql(u8, r.lhs, lhs)) {
            try r.handles.appendSlice(a, handles.items);
            merged = true;
        };
        if (!merged) try rules.append(a, .{ .lhs = lhs, .handles = handles });
    }
    if (rules.items.len == 0) return bad("no productions", .{});
    g.rules = rules.items;
    return g;
}

fn prepareString(a: Allocator, raw: []const u8) Fail![]const u8 {
    var unescaped: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == '\\') {
            try unescaped.append(a, '\\');
            i += 2;
        } else {
            try unescaped.append(a, raw[i]);
            i += 1;
        }
    }
    var enc: std.ArrayList(u8) = .empty;
    for (unescaped.items) |ch| {
        if (std.mem.indexOfScalar(u8, ".*+?^${}()|[]/\\", ch) != null) try enc.append(a, '\\');
        try enc.append(a, ch);
    }
    var out: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < enc.items.len) {
        if (std.mem.startsWith(u8, enc.items[i..], "\\\\u") and i + 7 <= enc.items.len and allHex(enc.items[i + 3 ..][0..4])) {
            try out.appendSlice(a, "\\u");
            try out.appendSlice(a, enc.items[i + 3 ..][0..4]);
            i += 7;
        } else {
            try out.append(a, enc.items[i]);
            i += 1;
        }
    }
    return out.items;
}

fn allHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn endsWithEscape(s: []const u8) bool {
    const n = s.len;
    for ([_]u8{ 'r', 'f', 'n', 't', 'v', 's', 'b' }) |e| if (n >= 2 and s[n - 1] == e and s[n - 2] == '\\') return true;
    if (n >= 3 and s[n - 3] == '\\' and s[n - 2] == 'c' and std.ascii.isUpper(s[n - 1])) return true;
    if (n >= 4 and s[n - 4] == '\\' and s[n - 3] == 'x' and isUpperHex(s[n - 2]) and isUpperHex(s[n - 1])) return true;
    if (n >= 6 and s[n - 6] == '\\' and s[n - 5] == 'u' and allHex(s[n - 4 ..])) return true;
    var k: usize = 1;
    while (k <= 3 and k + 1 <= n) : (k += 1) {
        const digits = s[n - k ..];
        var octal = true;
        for (digits) |d| if (d < '0' or d > '7') {
            octal = false;
        };
        if (octal and s[n - k - 1] == '\\') return true;
    }
    return false;
}

fn isUpperHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'A' and c <= 'F');
}

const RegexParser = struct {
    a: Allocator,
    c: *Cursor,

    fn startsBase(self: *RegexParser) bool {
        return switch (self.c.peek()) {
            .lparen, .special_group, .slash, .slash_bang, .name_brace, .any_group_regex, .dot, .caret, .dollar, .string_lit, .character_lit, .escape_char => true,
            else => false,
        };
    }

    fn list(self: *RegexParser) Fail![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.a, try self.concat());
        while (self.c.peek() == .bar) {
            _ = self.c.take();
            try out.append(self.a, '|');
            try out.appendSlice(self.a, try self.concat());
        }
        return out.items;
    }

    fn concat(self: *RegexParser) Fail![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (self.startsBase()) try out.appendSlice(self.a, try self.base());
        return out.items;
    }

    fn base(self: *RegexParser) Fail![]const u8 {
        const a = self.a;
        const t = self.c.take();
        var out: std.ArrayList(u8) = .empty;
        switch (t.tk) {
            .lparen => {
                try out.append(a, '(');
                try out.appendSlice(a, try self.list());
                _ = try self.c.expect(.rparen);
                try out.append(a, ')');
            },
            .special_group => {
                try out.appendSlice(a, t.text);
                try out.appendSlice(a, try self.list());
                _ = try self.c.expect(.rparen);
                try out.append(a, ')');
            },
            .slash, .slash_bang => {
                try out.appendSlice(a, if (t.tk == .slash) "(?=" else "(?!");
                if (!self.startsBase()) return bad("lookahead needs an expression", .{});
                try out.appendSlice(a, try self.base());
                try out.append(a, ')');
            },
            .string_lit => try out.appendSlice(a, try prepareString(a, t.text[1 .. t.text.len - 1])),
            .name_brace, .any_group_regex, .character_lit, .escape_char, .dot, .caret, .dollar => try out.appendSlice(a, if (t.tk == .dot) "." else if (t.tk == .caret) "^" else if (t.tk == .dollar) "$" else t.text),
            else => return bad("unexpected {s} '{s}' in a pattern", .{ @tagName(t.tk), t.text }),
        }
        while (true) {
            switch (self.c.peek()) {
                .plus => try out.append(a, '+'),
                .star => try out.append(a, '*'),
                .quest => try out.append(a, '?'),
                .range_regex => try out.appendSlice(a, self.c.toks[self.c.pos].text),
                else => return out.items,
            }
            _ = self.c.take();
        }
    }

    fn regex(self: *RegexParser) Fail![]const u8 {
        var s = try self.list();
        if (s.len > 0 and (std.ascii.isAlphanumeric(s[s.len - 1]) or s[s.len - 1] == '_') and !endsWithEscape(s)) s = try std.fmt.allocPrint(self.a, "{s}\\b", .{s});
        return s;
    }
};

const StartDef = struct { name: []const u8, exclusive: bool, group: usize };
const Definitions = struct { macros: std.ArrayList([2][]const u8) = .empty, starts: std.ArrayList(StartDef) = .empty };

fn parseLex(a: Allocator, block: []const u8) Fail!Lex {
    var text = block;
    if (std.mem.startsWith(u8, text, "%lex")) text = text[4..];
    if (std.mem.endsWith(u8, text, "/lex")) text = text[0 .. text.len - 4];
    var scan: LexScan = .{ .a = a };
    const toks = try collect(scanners.LexLex, a, text, &scan);
    var c: Cursor = .{ .toks = toks };
    var rp: RegexParser = .{ .a = a, .c = &c };
    var defs: Definitions = .{};
    while (true) {
        const t = c.take();
        switch (t.tk) {
            .name => try defs.macros.append(a, .{ t.text, try rp.regex() }),
            .start_inc, .start_exc => {
                const group = c.pos;
                while (c.peek() == .start_cond) try defs.starts.append(a, .{ .name = c.take().text, .exclusive = t.tk == .start_exc, .group = group });
            },
            .action => {},
            .pct_pct => break,
            else => return bad("unexpected {s} '{s}' in lexer definitions", .{ @tagName(t.tk), t.text }),
        }
    }
    var rules: std.ArrayList(LexRule) = .empty;
    while (c.peek() != .pct_pct and c.peek() != .eof) {
        var conds: ?[]const []const u8 = null;
        if (c.peek() == .lt) {
            _ = c.take();
            var names: std.ArrayList([]const u8) = .empty;
            if (c.peek() == .star) {
                _ = c.take();
                try names.append(a, "*");
            } else {
                try names.append(a, (try c.expect(.name)).text);
                while (c.peek() == .comma) {
                    _ = c.take();
                    try names.append(a, (try c.expect(.name)).text);
                }
            }
            _ = try c.expect(.gt);
            conds = names.items;
        }
        const pattern = try rp.regex();
        const action = switch (c.peek()) {
            .lbrace => blk: {
                _ = c.take();
                break :blk try c.actionBody(a);
            },
            .action => c.take().text,
            else => return bad("rule '{s}' has no action", .{pattern}),
        };
        try rules.append(a, .{ .conds = conds, .pattern = pattern, .action = action });
    }
    var cs: std.ArrayList(Cond) = .empty;
    // jison's definitions rule is right recursive, so declaration groups reach the condition table in reverse order
    var k = defs.starts.items.len;
    while (k > 0) {
        var lo = k;
        while (lo > 0 and defs.starts.items[lo - 1].group == defs.starts.items[k - 1].group) lo -= 1;
        for (defs.starts.items[lo..k]) |s| {
            if (findCond(cs.items, s.name)) |existing| existing.inclusive = !s.exclusive else try cs.append(a, .{ .name = s.name, .rules = .empty, .inclusive = !s.exclusive });
        }
        k = lo;
    }
    try cs.append(a, .{ .name = "INITIAL", .rules = .empty, .inclusive = true });
    var case_insensitive = false;
    for (scan.options.items) |o| {
        if (std.mem.eql(u8, o, "case-insensitive")) case_insensitive = true else return bad("lexer option '{s}' is not supported", .{o});
    }
    for (rules.items) |r| for ([_][]const u8{ "this.unput", "this.more", "this.reject", "this.less", "this.input(" }) |needle| {
        if (std.mem.indexOf(u8, r.action, needle) != null) return bad("lexer action uses {s}, which the runtime does not provide: {s}", .{ needle, r.action });
    };
    const macros = try expandMacros(a, defs.macros.items);
    const finished = try a.alloc(LexRule, rules.items.len);
    for (rules.items, 0..) |r, i| {
        if (r.conds) |names| {
            for (names) |n| {
                if (std.mem.eql(u8, n, "*")) {
                    for (cs.items) |*cd| try cd.rules.append(a, @intCast(i));
                } else {
                    const cd = findCond(cs.items, n) orelse return bad("unknown start condition '{s}'", .{n});
                    try cd.rules.append(a, @intCast(i));
                }
            }
        } else for (cs.items) |*cd| if (cd.inclusive) try cd.rules.append(a, @intCast(i));
        var m = r.pattern;
        var mi = macros.len;
        while (mi > 0) : (mi -= 1) m = try replaceAllBytes(a, m, try std.fmt.allocPrint(a, "{{{s}}}", .{macros[mi - 1][0]}), try std.fmt.allocPrint(a, "({s})", .{macros[mi - 1][1]}));
        finished[i] = .{ .conds = r.conds, .pattern = m, .action = r.action };
    }
    return .{ .case_insensitive = case_insensitive, .conds = cs.items, .rules = finished };
}

fn findCond(cs: []Cond, name: []const u8) ?*Cond {
    for (cs) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

fn replaceAllBytes(a: Allocator, s: []const u8, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], from)) {
            try out.appendSlice(a, to);
            i += from.len;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Grammar to productions, mirroring jison's buildProductions.

const Production = struct { lhs: u16, rhs: []const u16, precedence: u32, handle: Handle };

const Model = struct {
    names: std.ArrayList([]const u8) = .empty,
    is_nonterminal: std.ArrayList(bool) = .empty,
    prods: std.ArrayList(Production) = .empty,
    ops: std.StringHashMap(struct { precedence: u32, assoc: []const u8 }),
    ids: std.StringHashMap(u16),
    nonterminal_prods: std.ArrayList(std.ArrayList(u32)) = .empty,
    start: u16 = 0,

    fn count(self: *const Model) usize {
        return self.names.items.len;
    }
};

fn stripAlias(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '[')) |i| {
        if (std.mem.endsWith(u8, s, "]")) return a.dupe(u8, s[0..i]);
    }
    return s;
}

fn buildModel(a: Allocator, g: Grammar) Fail!Model {
    var m: Model = .{ .ops = .init(a), .ids = .init(a) };
    for (g.operators, 0..) |op, i| for (op.tokens) |t| try m.ops.put(t, .{ .precedence = @intCast(i + 1), .assoc = op.assoc });
    try m.names.appendSlice(a, &.{ "$accept", "$end" });
    try m.is_nonterminal.appendSlice(a, &.{ true, false });
    try m.nonterminal_prods.appendSlice(a, &.{ .empty, .empty });
    const addSymbol = struct {
        fn f(mm: *Model, aa: Allocator, s: []const u8) Fail!u16 {
            if (mm.ids.get(s)) |id| return id;
            const id: u16 = @intCast(mm.names.items.len);
            try mm.ids.put(s, id);
            try mm.names.append(aa, s);
            try mm.is_nonterminal.append(aa, false);
            try mm.nonterminal_prods.append(aa, .empty);
            return id;
        }
    }.f;
    _ = try addSymbol(&m, a, "error");
    var defined = std.StringHashMap(void).init(a);
    const Pending = struct { lhs: u16, names: []const []const u8, precedence: u32, handle: Handle };
    var pending: std.ArrayList(Pending) = .empty;
    for (g.rules) |rule| {
        const lhs = try addSymbol(&m, a, rule.lhs);
        m.is_nonterminal.items[lhs] = true;
        try defined.put(rule.lhs, {});
        for (rule.handles.items) |h| {
            var names: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, std.mem.trim(u8, h.rhs, " \t\r\n"), ' ');
            while (it.next()) |p| {
                if (p.len == 0) continue;
                // jison registers the aliased spelling when the production has an action or a %prec
                _ = try addSymbol(&m, a, if (h.action != null or h.prec != null) p else try stripAlias(a, p));
                try names.append(a, try stripAlias(a, p));
            }
            var prec: u32 = 0;
            if (h.prec) |pn| if (m.ops.get(pn)) |o| {
                prec = o.precedence;
            };
            if (prec == 0) {
                var i = names.items.len;
                while (i > 0) {
                    i -= 1;
                    if (!defined.contains(names.items[i])) if (m.ops.get(names.items[i])) |o| {
                        prec = o.precedence;
                    };
                }
            }
            try m.nonterminal_prods.items[lhs].append(a, @intCast(pending.items.len + 1));
            try pending.append(a, .{ .lhs = lhs, .names = names.items, .precedence = prec, .handle = h });
        }
    }
    for (pending.items) |p| {
        const rhs = try a.alloc(u16, p.names.len);
        for (p.names, 0..) |n, i| rhs[i] = m.ids.get(n) orelse return bad("symbol '{s}' is used in a production but never defined", .{n});
        try m.prods.append(a, .{ .lhs = p.lhs, .rhs = rhs, .precedence = p.precedence, .handle = p.handle });
    }
    if (g.start) |s| {
        m.start = m.ids.get(s) orelse return bad("start symbol '{s}' is not defined", .{s});
        if (!m.is_nonterminal.items[m.start]) return bad("start symbol '{s}' is not a nonterminal", .{s});
    } else m.start = m.prods.items[0].lhs;
    const accept: Production = .{ .lhs = 0, .rhs = try a.dupe(u16, &.{ m.start, 1 }), .precedence = 0, .handle = .{ .rhs = "", .action = null, .prec = null } };
    try m.prods.insert(a, 0, accept);
    try m.nonterminal_prods.items[0].append(a, 0);
    return m;
}

// ---------------------------------------------------------------------------
// LR(0) automaton, jison's "simple LALR" lookaheads, parse table.

const none = std.math.maxInt(u32);

const Item = struct { prod: u32, dot: u32 };

const State = struct {
    items: []const Item,
    reductions: []const u32,
    edges: []u32,
};

fn marked(m: *const Model, it: Item) ?u16 {
    const p = m.prods.items[it.prod];
    return if (it.dot < p.rhs.len) p.rhs[it.dot] else null;
}

fn itemKey(it: Item) u64 {
    return (@as(u64, it.prod) << 32) | it.dot;
}

const Closure = struct { items: []const Item, reductions: []const u32 };

fn closure(a: Allocator, m: *const Model, kernel: []const Item) Allocator.Error!Closure {
    var items: std.ArrayList(Item) = .empty;
    var reductions: std.ArrayList(u32) = .empty;
    var seen = std.AutoHashMap(u64, void).init(a);
    defer seen.deinit();
    const visited = try a.alloc(bool, m.count());
    defer a.free(visited);
    @memset(visited, false);
    for (kernel) |it| {
        try items.append(a, it);
        try seen.put(itemKey(it), {});
    }
    var lo: usize = 0;
    var hi: usize = items.items.len;
    while (lo < hi) {
        var queue: std.ArrayList(Item) = .empty;
        defer queue.deinit(a);
        for (lo..hi) |idx| {
            const sym = marked(m, items.items[idx]) orelse {
                try reductions.append(a, @intCast(idx));
                continue;
            };
            if (m.is_nonterminal.items[sym] and !visited[sym]) {
                for (m.nonterminal_prods.items[sym].items) |pid| {
                    const ni: Item = .{ .prod = pid, .dot = 0 };
                    if (!seen.contains(itemKey(ni))) try queue.append(a, ni);
                }
                visited[sym] = true;
            }
        }
        lo = items.items.len;
        for (queue.items) |it| {
            try items.append(a, it);
            try seen.put(itemKey(it), {});
        }
        hi = items.items.len;
    }
    return .{ .items = items.items, .reductions = reductions.items };
}

fn stateKey(a: Allocator, items: []const Item) Allocator.Error![]const u8 {
    const ids = try a.alloc(u64, items.len);
    for (items, 0..) |it, i| ids[i] = itemKey(it);
    std.mem.sort(u64, ids, {}, std.sort.asc(u64));
    return std.mem.sliceAsBytes(ids);
}

fn canonicalCollection(a: Allocator, m: *const Model) Allocator.Error![]State {
    var states: std.ArrayList(State) = .empty;
    var index = std.StringHashMap(u32).init(a);
    const nsym = m.count();
    const first = try closure(a, m, &.{.{ .prod = 0, .dot = 0 }});
    try states.append(a, .{ .items = first.items, .reductions = first.reductions, .edges = try newEdges(a, nsym) });
    try index.put(try stateKey(a, first.items), 0);
    const done = try a.alloc(bool, nsym);
    var si: usize = 0;
    while (si < states.items.len) : (si += 1) {
        @memset(done, false);
        const items = states.items[si].items;
        for (items) |it| {
            const sym = marked(m, it) orelse continue;
            if (sym == 1 or done[sym]) continue;
            done[sym] = true;
            var kernel: std.ArrayList(Item) = .empty;
            for (items) |other| if (marked(m, other)) |s2| if (s2 == sym) try kernel.append(a, .{ .prod = other.prod, .dot = other.dot + 1 });
            const g = try closure(a, m, kernel.items);
            const key = try stateKey(a, g.items);
            const target = if (index.get(key)) |t| t else blk: {
                const t: u32 = @intCast(states.items.len);
                try states.append(a, .{ .items = g.items, .reductions = g.reductions, .edges = try newEdges(a, nsym) });
                try index.put(key, t);
                break :blk t;
            };
            states.items[si].edges[sym] = target;
        }
    }
    return states.items;
}

fn newEdges(a: Allocator, n: usize) Allocator.Error![]u32 {
    const e = try a.alloc(u32, n);
    @memset(e, none);
    return e;
}

const Bits = std.bit_set.DynamicBitSetUnmanaged;

const Elem = struct { nt: bool, v: u32 };

fn ngKey(state: usize, sym: u16) u64 {
    return (@as(u64, state) << 16) | sym;
}

fn lookaheads(a: Allocator, m: *const Model, states: []State) Allocator.Error![][]const Bits {
    const nsym = m.count();
    var nt_index = std.AutoHashMap(u64, u32).init(a);
    const NgProd = struct { lhs: u32, rhs: []const Elem };
    var prods: std.ArrayList(NgProd) = .empty;
    const goes = try a.alloc(std.StringHashMap(std.ArrayList(u32)), states.len);
    for (goes) |*g| g.* = .init(a);
    const getNt = struct {
        fn f(map: *std.AutoHashMap(u64, u32), s: usize, sym: u16) Allocator.Error!u32 {
            const gop = try map.getOrPut(ngKey(s, sym));
            if (!gop.found_existing) gop.value_ptr.* = map.count() - 1;
            return gop.value_ptr.*;
        }
    }.f;
    for (states, 0..) |st, si| {
        for (st.items) |it| {
            if (it.dot != 0) continue;
            const p = m.prods.items[it.prod];
            const lhs = try getNt(&nt_index, si, p.lhs);
            var elems: std.ArrayList(Elem) = .empty;
            var q = si;
            for (p.rhs) |sym| {
                if (m.is_nonterminal.items[sym]) try elems.append(a, .{ .nt = true, .v = try getNt(&nt_index, q, sym) }) else try elems.append(a, .{ .nt = false, .v = sym });
                const e = states[q].edges[sym];
                if (e != none) q = e;
            }
            try prods.append(a, .{ .lhs = lhs, .rhs = elems.items });
            const gop = try goes[q].getOrPut(std.mem.sliceAsBytes(p.rhs));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, lhs);
        }
    }
    const nnt = nt_index.count();
    const nullable = try a.alloc(bool, nnt);
    @memset(nullable, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (prods.items) |p| {
            if (nullable[p.lhs]) continue;
            var all = true;
            for (p.rhs) |e| if (!e.nt or !nullable[e.v]) {
                all = false;
            };
            if (all) {
                nullable[p.lhs] = true;
                changed = true;
            }
        }
    }
    const first = try a.alloc(Bits, nnt);
    const follow = try a.alloc(Bits, nnt);
    for (first) |*b| b.* = try Bits.initEmpty(a, nsym);
    for (follow) |*b| b.* = try Bits.initEmpty(a, nsym);
    changed = true;
    while (changed) {
        changed = false;
        for (prods.items) |p| {
            for (p.rhs) |e| {
                if (!e.nt) {
                    if (!first[p.lhs].isSet(e.v)) {
                        first[p.lhs].set(e.v);
                        changed = true;
                    }
                    break;
                }
                const before = first[p.lhs].count();
                first[p.lhs].setUnion(first[e.v]);
                if (first[p.lhs].count() != before) changed = true;
                if (!nullable[e.v]) break;
            }
        }
    }
    changed = true;
    while (changed) {
        changed = false;
        for (prods.items) |p| {
            for (p.rhs, 0..) |e, i| {
                if (!e.nt) continue;
                const before = follow[e.v].count();
                var all_nullable = true;
                for (p.rhs[i + 1 ..]) |r| {
                    if (!r.nt) {
                        follow[e.v].set(r.v);
                        all_nullable = false;
                        break;
                    }
                    follow[e.v].setUnion(first[r.v]);
                    if (!nullable[r.v]) {
                        all_nullable = false;
                        break;
                    }
                }
                if (all_nullable) follow[e.v].setUnion(follow[p.lhs]);
                if (follow[e.v].count() != before) changed = true;
            }
        }
    }
    const result = try a.alloc([]const Bits, states.len);
    for (states, 0..) |st, si| {
        const per = try a.alloc(Bits, st.reductions.len);
        for (st.reductions, 0..) |r, k| {
            per[k] = try Bits.initEmpty(a, nsym);
            const p = m.prods.items[st.items[r].prod];
            const list = goes[si].get(std.mem.sliceAsBytes(p.rhs)) orelse unreachable;
            for (list.items) |nt| per[k].setUnion(follow[nt]);
        }
        result[si] = per;
    }
    return result;
}

const Kind = enum(u8) { none, shift, reduce, accept, go };
const Slot = struct { kind: Kind = .none, arg: u32 = 0 };

const Tables = struct {
    rows: [][]Slot,
    defaults: []u32,
    conflicts: usize,
};

fn buildTable(a: Allocator, m: *const Model, states: []State, look: []const []const Bits) Fail!Tables {
    const nsym = m.count();
    const rows = try a.alloc([]Slot, states.len);
    const defaults = try a.alloc(u32, states.len);
    var conflicts: usize = 0;
    for (states, 0..) |st, si| {
        const slots = try a.alloc(Slot, nsym);
        @memset(slots, .{});
        rows[si] = slots;
        for (st.edges, 0..) |e, sym| {
            if (e == none) continue;
            slots[sym] = .{ .kind = if (m.is_nonterminal.items[sym]) .go else .shift, .arg = e };
        }
        for (st.items) |it| if (marked(m, it)) |s| if (s == 1) {
            slots[1] = .{ .kind = .accept };
        };
        for (st.reductions, 0..) |r, k| {
            const prod_id = st.items[r].prod;
            const p = m.prods.items[prod_id];
            var it = look[si][k].iterator(.{});
            while (it.next()) |t| {
                const existing = slots[t];
                if (existing.kind == .none) {
                    slots[t] = .{ .kind = .reduce, .arg = prod_id };
                    continue;
                }
                const op = m.ops.get(m.names.items[t]);
                var by_default = false;
                if (existing.kind == .reduce) {
                    by_default = existing.arg != prod_id;
                } else if (p.precedence == 0 or op == null) {
                    by_default = true;
                } else if (p.precedence < op.?.precedence) {
                    // keep the shift
                } else if (p.precedence == op.?.precedence) {
                    const assoc = op.?.assoc;
                    if (std.mem.eql(u8, assoc, "left")) {
                        slots[t] = .{ .kind = .reduce, .arg = prod_id };
                    } else if (std.mem.eql(u8, assoc, "nonassoc")) {
                        return bad("%nonassoc conflict in state {d} is not supported", .{si});
                    }
                } else slots[t] = .{ .kind = .reduce, .arg = prod_id };
                if (by_default) {
                    conflicts += 1;
                    std.log.warn("gen-jison: conflict in state {d} on '{s}'", .{ si, m.names.items[t] });
                }
            }
        }
        var count: usize = 0;
        var last: Slot = .{};
        for (slots) |s| if (s.kind != .none) {
            count += 1;
            last = s;
        };
        defaults[si] = if (count == 1 and last.kind == .reduce) last.arg else none;
    }
    return .{ .rows = rows, .defaults = defaults, .conflicts = conflicts };
}

// ---------------------------------------------------------------------------
// Output.

const Built = struct {
    model: Model,
    tables: Tables,
    lex: ?Lex,
    extra_tokens: []const []const u8,
};

fn jsonKind(k: Kind) u8 {
    return switch (k) {
        .go => 0,
        .shift => 1,
        .reduce => 2,
        .accept => 3,
        .none => unreachable,
    };
}

fn jsonString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        8 => try out.appendSlice(a, "\\b"),
        12 => try out.appendSlice(a, "\\f"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...7, 11, 14...31 => try out.print(a, "\\u{x:0>4}", .{c}),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

fn writeJson(a: Allocator, b: *const Built) Allocator.Error![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const m = &b.model;
    try o.appendSlice(a, "{\"symbols\":[");
    for (m.names.items, 0..) |n, i| {
        if (i > 0) try o.append(a, ',');
        try jsonString(a, &o, n);
    }
    try o.appendSlice(a, "]\n,\"terminals\":[");
    var first = true;
    for (m.names.items, 0..) |_, i| {
        if (i < 2 or m.is_nonterminal.items[i]) continue;
        if (!first) try o.append(a, ',');
        first = false;
        try o.print(a, "{d}", .{i});
    }
    try o.appendSlice(a, "]\n,\"productions\":[");
    for (m.prods.items, 0..) |p, i| {
        if (i > 0) try o.append(a, ',');
        try o.print(a, "[{d},{d}]", .{ p.lhs, if (i == 0) 0 else p.rhs.len });
    }
    try o.appendSlice(a, "]\n,\"table\":[\n");
    for (b.tables.rows, 0..) |row, si| {
        if (si > 0) try o.append(a, ',');
        try o.append(a, '[');
        var any = false;
        for (row, 0..) |s, sym| {
            if (s.kind == .none) continue;
            if (any) try o.append(a, ',');
            any = true;
            try o.print(a, "[{d},{d},{d}]", .{ sym, jsonKind(s.kind), s.arg });
        }
        try o.appendSlice(a, "]\n");
    }
    try o.appendSlice(a, "]\n,\"defaults\":[");
    first = true;
    for (b.tables.defaults, 0..) |d, si| {
        if (d == none) continue;
        if (!first) try o.append(a, ',');
        first = false;
        try o.print(a, "[{d},{d}]", .{ si, d });
    }
    try o.appendSlice(a, "]\n");
    if (b.lex) |lx| {
        try o.print(a, ",\"lexer\":{{\"flags\":\"{s}\",\"patterns\":[\n", .{if (lx.case_insensitive) "i" else ""});
        for (lx.rules, 0..) |r, i| {
            if (i > 0) try o.append(a, ',');
            try jsonString(a, &o, r.pattern);
            try o.append(a, '\n');
        }
        try o.appendSlice(a, "],\"conditions\":[");
        for (lx.conds, 0..) |c, i| {
            if (i > 0) try o.append(a, ',');
            try o.append(a, '[');
            try jsonString(a, &o, c.name);
            try o.appendSlice(a, ",[");
            for (c.rules.items, 0..) |r, k| {
                if (k > 0) try o.append(a, ',');
                try o.print(a, "{d}", .{r});
            }
            try o.print(a, "],{d}]", .{@intFromBool(c.inclusive)});
        }
        try o.appendSlice(a, "]}");
    }
    try o.appendSlice(a, "}\n");
    return o.items;
}

const zig_keywords = [_][]const u8{
    "addrspace", "align",  "allowzero",   "and",       "anyframe", "anytype",     "asm",      "async",    "await",       "break",     "callconv", "catch",
    "comptime",  "const",  "continue",    "defer",     "else",     "enum",        "errdefer", "error",    "export",      "extern",    "fn",       "for",
    "if",        "inline", "linksection", "noalias",   "noinline", "nosuspend",   "opaque",   "or",       "orelse",      "packed",    "pub",      "resume",
    "return",    "struct", "suspend",     "switch",    "test",     "threadlocal", "try",      "union",    "unreachable", "var",       "volatile", "while",
    "true",      "false",  "null",        "undefined", "bool",     "void",        "type",     "noreturn", "anyerror",    "anyopaque", "usize",    "isize",
};

fn isPlainIdent(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    for (zig_keywords) |k| if (std.mem.eql(u8, k, s)) return false;
    if (s.len > 1 and (s[0] == 'u' or s[0] == 'i' or s[0] == 'f') and std.ascii.isDigit(s[1])) return false;
    return !std.mem.eql(u8, s, "_");
}

fn zigString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...31, 127 => try out.print(a, "\\x{x:0>2}", .{c}),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

fn zigIdent(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    if (isPlainIdent(s)) {
        try out.appendSlice(a, s);
        return;
    }
    try out.append(a, '@');
    try zigString(a, out, s);
}

fn commentLines(a: Allocator, out: *std.ArrayList(u8), indent: []const u8, text: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    while (it.next()) |line| {
        try out.appendSlice(a, indent);
        try out.appendSlice(a, "//");
        const t = std.mem.trimEnd(u8, line, " \t\r");
        if (t.len > 0) {
            try out.append(a, ' ');
            try out.appendSlice(a, std.mem.trimStart(u8, t, " \t"));
        }
        try out.append(a, '\n');
    }
}

fn writeZig(a: Allocator, b: *const Built, source_name: []const u8) Allocator.Error![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const m = &b.model;
    try o.print(a, "// Generated by tools/gen_jison.zig from {s}. Do not edit.\n\n", .{source_name});
    try o.appendSlice(a, "pub const symbol_names = [_][]const u8{\n");
    for (m.names.items) |n| {
        try o.appendSlice(a, "    ");
        try zigString(a, &o, n);
        try o.appendSlice(a, ",\n");
    }
    try o.appendSlice(a, "};\n\npub const is_terminal = [_]bool{");
    for (m.names.items, 0..) |_, i| {
        if (i % 24 == 0) try o.appendSlice(a, "\n   ");
        try o.print(a, " {s},", .{if (i >= 2 and !m.is_nonterminal.items[i]) "true" else "false"});
    }
    try o.appendSlice(a, "\n};\n\npub const productions = [_]struct { lhs: u16, len: u16 }{");
    for (m.prods.items, 0..) |p, i| {
        if (i % 6 == 0) try o.appendSlice(a, "\n   ");
        try o.print(a, " .{{ .lhs = {d}, .len = {d} }},", .{ p.lhs, p.rhs.len });
    }
    try o.appendSlice(a, "\n};\n\npub const defaults = [_]u16{");
    for (b.tables.defaults, 0..) |d, i| {
        if (i % 16 == 0) try o.appendSlice(a, "\n   ");
        if (d == none) try o.appendSlice(a, " 0xFFFF,") else try o.print(a, " {d},", .{d});
    }
    try o.appendSlice(a, "\n};\n\npub const row_start = [_]u32{");
    var entries: std.ArrayList(u32) = .empty;
    var total: u32 = 0;
    var rowno: usize = 0;
    for (b.tables.rows) |row| {
        if (rowno % 16 == 0) try o.appendSlice(a, "\n   ");
        rowno += 1;
        try o.print(a, " {d},", .{total});
        for (row, 0..) |s, sym| {
            if (s.kind == .none) continue;
            const kind: u32 = switch (s.kind) {
                .shift => 0,
                .reduce => 1,
                .accept => 2,
                .go => 3,
                .none => unreachable,
            };
            try entries.append(a, (kind << 29) | (@as(u32, @intCast(sym)) << 16) | s.arg);
            total += 1;
        }
    }
    try o.print(a, " {d},\n}};\n\npub const entries = [_]u32{{", .{total});
    for (entries.items, 0..) |e, i| {
        if (i % 8 == 0) try o.appendSlice(a, "\n   ");
        try o.print(a, " 0x{x:0>8},", .{e});
    }
    try o.appendSlice(a, "\n};\n\npub const extra_tokens = [_][]const u8{");
    for (b.extra_tokens) |n| {
        try o.appendSlice(a, "\n    ");
        try zigString(a, &o, n);
        try o.append(a, ',');
    }
    try o.appendSlice(a, "\n};\n\npub const tok = struct {\n");
    for (m.names.items, 0..) |n, i| {
        if (i < 2 or m.is_nonterminal.items[i]) continue;
        try o.appendSlice(a, "    pub const ");
        try zigIdent(a, &o, n);
        try o.print(a, ": u16 = {d};\n", .{i});
    }
    for (b.extra_tokens, 0..) |n, i| {
        try o.appendSlice(a, "    pub const ");
        try zigIdent(a, &o, n);
        try o.print(a, ": u16 = {d};\n", .{m.count() + i});
    }
    try o.appendSlice(a, "};\n");
    if (b.lex) |lx| {
        try o.print(a, "\npub const lex_ignore_case = {s};\n\npub const lex_patterns = [_][]const u8{{\n", .{if (lx.case_insensitive) "true" else "false"});
        for (lx.rules) |r| {
            try o.appendSlice(a, "    ");
            try zigString(a, &o, r.pattern);
            try o.appendSlice(a, ",\n");
        }
        try o.appendSlice(a, "};\n\npub const lex_conditions = [_]struct { name: []const u8, rules: []const u16, inclusive: bool }{\n");
        for (lx.conds) |c| {
            try o.appendSlice(a, "    .{ .name = ");
            try zigString(a, &o, c.name);
            try o.appendSlice(a, ", .rules = &.{");
            for (c.rules.items, 0..) |r, k| try o.print(a, "{s}{d}", .{ if (k > 0) ", " else " ", r });
            try o.print(a, " }}, .inclusive = {s} }},\n", .{if (c.inclusive) "true" else "false"});
        }
        try o.appendSlice(a, "};\n\npub const cond = struct {\n");
        for (lx.conds, 0..) |c, i| {
            try o.appendSlice(a, "    pub const ");
            try zigIdent(a, &o, c.name);
            try o.print(a, ": u16 = {d};\n", .{i});
        }
        try o.appendSlice(a, "};\n");
    }
    return o.items;
}

const Statement = union(enum) { begin: []const u8, pop, ret: []const u8, clear_text, trim_text };

fn translateLexAction(a: Allocator, action: []const u8) Allocator.Error!?[]const Statement {
    var clean: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < action.len) {
        if (std.mem.startsWith(u8, action[i..], "//")) {
            while (i < action.len and action[i] != '\n') i += 1;
        } else if (std.mem.startsWith(u8, action[i..], "/*")) {
            const e = std.mem.indexOf(u8, action[i + 2 ..], "*/") orelse return null;
            i += e + 4;
        } else {
            try clean.append(a, action[i]);
            i += 1;
        }
    }
    var out: std.ArrayList(Statement) = .empty;
    var it = std.mem.splitScalar(u8, clean.items, ';');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r\n{}");
        if (s.len == 0) continue;
        if (std.mem.startsWith(u8, s, "return ")) {
            const v = std.mem.trim(u8, s[7..], " \t");
            if (v.len < 3 or v[0] != v[v.len - 1] or (v[0] != '\'' and v[0] != '"')) return null;
            try out.append(a, .{ .ret = v[1 .. v.len - 1] });
            continue;
        }
        if (std.mem.eql(u8, s, "yytext=\"\"") or std.mem.eql(u8, s, "yytext = \"\"") or std.mem.eql(u8, s, "yytext = ''")) {
            try out.append(a, .clear_text);
            continue;
        }
        if (std.mem.eql(u8, s, "yytext = yytext.trim()") or std.mem.eql(u8, s, "yytext=yytext.trim()")) {
            try out.append(a, .trim_text);
            continue;
        }
        if (std.mem.eql(u8, s, "this.popState()")) {
            try out.append(a, .pop);
            continue;
        }
        for ([_][]const u8{ "this.begin(", "this.pushState(" }) |prefix| {
            if (std.mem.startsWith(u8, s, prefix) and std.mem.endsWith(u8, s, ")")) {
                const v = std.mem.trim(u8, s[prefix.len .. s.len - 1], " \t");
                if (v.len < 3 or v[0] != v[v.len - 1] or (v[0] != '\'' and v[0] != '"')) return null;
                try out.append(a, .{ .begin = v[1 .. v.len - 1] });
                break;
            }
        } else return null;
    }
    return out.items;
}

fn collectExtraTokens(a: Allocator, m: *const Model, lex: ?Lex) Allocator.Error![]const []const u8 {
    var extra: std.ArrayList([]const u8) = .empty;
    const lx = lex orelse return extra.items;
    for (lx.rules) |r| {
        const stmts = (try translateLexAction(a, r.action)) orelse continue;
        for (stmts) |st| switch (st) {
            .ret => |name| {
                if (m.ids.contains(name)) continue;
                var found = false;
                for (extra.items) |e| if (std.mem.eql(u8, e, name)) {
                    found = true;
                };
                if (!found) try extra.append(a, name);
            },
            else => {},
        };
    }
    return extra.items;
}

fn writeStub(a: Allocator, b: *const Built, source_name: []const u8) Allocator.Error![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const m = &b.model;
    try o.print(a, "// Generated by tools/gen_jison.zig from {s}. Copy the arms into the diagram's actions file, point the two imports at runtime.zig and the generated grammar, and port the unported ones by hand.\n", .{source_name});
    try o.appendSlice(a, "const rt = @import(\"jison_runtime\");\nconst G = @import(\"grammar\");\n\n");
    if (b.lex) |lx| {
        try o.appendSlice(a, "pub fn lexAction(self: anytype, lx: anytype, rule: u16) rt.Error!?u16 {\n    _ = self;\n    switch (rule) {\n");
        for (lx.rules, 0..) |r, i| {
            try o.print(a, "        {d} => {{\n", .{i});
            try o.appendSlice(a, "            // pattern: ");
            try o.appendSlice(a, r.pattern);
            try o.append(a, '\n');
            try commentLines(a, &o, "            ", r.action);
            if (try translateLexAction(a, r.action)) |stmts| {
                var returned = false;
                for (stmts) |st| switch (st) {
                    .begin => |c| {
                        try o.appendSlice(a, "            try lx.begin(G.cond.");
                        try zigIdent(a, &o, c);
                        try o.appendSlice(a, ");\n");
                    },
                    .pop => try o.appendSlice(a, "            lx.popState();\n"),
                    .clear_text => try o.appendSlice(a, "            lx.yytext = &.{};\n"),
                    .trim_text => try o.appendSlice(a, "            lx.yytext = rt.trim(lx.yytext);\n"),
                    .ret => |t| {
                        try o.appendSlice(a, "            return G.tok.");
                        try zigIdent(a, &o, t);
                        try o.appendSlice(a, ";\n");
                        returned = true;
                    },
                };
                if (!returned) try o.appendSlice(a, "            return null;\n");
            } else {
                try o.print(a, "            return lx.diag.fail(lx.gpa, \"lexer rule {d} is not ported\", .{{}});\n", .{i});
            }
            try o.appendSlice(a, "        },\n");
        }
        try o.appendSlice(a, "        else => unreachable,\n    }\n}\n\n");
    }
    try o.appendSlice(a, "pub fn reduce(self: anytype, ctx: anytype, rhs: anytype, out: anytype) rt.Error!bool {\n    _ = self;\n    _ = rhs;\n    _ = out;\n    switch (ctx.prod) {\n        0 => {},\n");
    for (m.prods.items[1..], 1..) |p, i| {
        try o.print(a, "        {d} => {{\n", .{i});
        try o.print(a, "            // {s}:", .{m.names.items[p.lhs]});
        if (p.handle.rhs.len > 0) {
            try o.append(a, ' ');
            try o.appendSlice(a, p.handle.rhs);
        }
        try o.append(a, '\n');
        if (p.handle.action) |act| {
            try commentLines(a, &o, "            ", act);
            try o.print(a, "            return ctx.diag.fail(ctx.gpa, \"production {d} is not ported\", .{{}});\n", .{i});
        }
        try o.appendSlice(a, "        },\n");
    }
    try o.appendSlice(a, "        else => unreachable,\n    }\n    return false;\n}\n");
    return o.items;
}

fn build(a: Allocator, text: []const u8) Fail!Built {
    const g = try parseGrammar(a, text);
    var model = try buildModel(a, g);
    const lex: ?Lex = if (g.lex_text) |t| try parseLex(a, t) else null;
    const states = try canonicalCollection(a, &model);
    const look = try lookaheads(a, &model, states);
    const tables = try buildTable(a, &model, states, look);
    for (model.prods.items) |p| for (p.rhs) |s| if (s == 2) return bad("error recovery rules are not supported", .{});
    return .{ .model = model, .tables = tables, .lex = lex, .extra_tokens = try collectExtraTokens(a, &model, lex) };
}

fn firstDifference(want: []const u8, got: []const u8) struct { line: usize, want: []const u8, got: []const u8 } {
    var wi = std.mem.splitScalar(u8, want, '\n');
    var gi = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const w = wi.next();
        const g = gi.next();
        if (w == null and g == null) return .{ .line = 0, .want = "", .got = "" };
        if (w == null or g == null or !std.mem.eql(u8, std.mem.trimEnd(u8, w.?, "\r"), std.mem.trimEnd(u8, g.?, "\r"))) return .{ .line = line, .want = w orelse "<end>", .got = g orelse "<end>" };
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "check")) {
        const built = try build(a, try files.read(init.io, a, argv[2]));
        const got = try writeJson(a, &built);
        const want = try files.read(init.io, a, argv[3]);
        const d = firstDifference(want, got);
        if (d.line != 0) {
            var col: usize = 0;
            while (col < d.want.len and col < d.got.len and d.want[col] == d.got[col]) col += 1;
            const from = col -| 60;
            files.say(init.io, "tables differ from jison at line {d} column {d}\n  jison: {s}\n  ours:  {s}\n", .{ d.line, col, d.want[from..@min(d.want.len, col + 120)], d.got[from..@min(d.got.len, col + 120)] });
            return error.TablesDiffer;
        }
        files.say(init.io, "tables identical to jison: {d} symbols, {d} productions, {d} states\n", .{ built.model.count(), built.model.prods.items.len, built.tables.rows.len });
        return;
    }
    if (argv.len < 3) {
        files.say(init.io, "usage: gen-jison <grammar.jison> <out.zig> [stub=<stub.zig>] [json=<tables.json>]\n       gen-jison check <grammar.jison> <jison-tables.json>\n", .{});
        return error.Usage;
    }
    const built = try build(a, try files.read(init.io, a, argv[1]));
    const source_name = std.fs.path.basename(argv[1]);
    try files.write(init.io, argv[2], try writeZig(a, &built, source_name));
    for (argv[3..]) |extra| {
        if (std.mem.startsWith(u8, extra, "stub=")) try files.write(init.io, extra[5..], try writeStub(a, &built, source_name));
        if (std.mem.startsWith(u8, extra, "json=")) try files.write(init.io, extra[5..], try writeJson(a, &built));
    }
    files.say(init.io, "{s}: {d} symbols, {d} productions, {d} states, {d} conflicts\n", .{ source_name, built.model.count(), built.model.prods.items.len, built.tables.rows.len, built.tables.conflicts });
}

fn expandMacros(a: Allocator, list: []const [2][]const u8) Allocator.Error![]const [2][]const u8 {
    const macros = try a.dupe([2][]const u8, list);
    var again = true;
    while (again) {
        again = false;
        var i = macros.len;
        while (i > 0) : (i -= 1) {
            for (macros, 0..) |other, k| {
                if (k == i - 1) continue;
                const next = try replaceAllBytes(a, macros[i - 1][1], try std.fmt.allocPrint(a, "{{{s}}}", .{other[0]}), try std.fmt.allocPrint(a, "({s})", .{other[1]}));
                if (!std.mem.eql(u8, next, macros[i - 1][1])) {
                    macros[i - 1][1] = next;
                    again = true;
                }
            }
        }
    }
    return macros;
}
