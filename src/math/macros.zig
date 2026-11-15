const std = @import("std");
const lexer = @import("lexer.zig");
const tree = @import("tree.zig");

const Token = lexer.Token;

pub const Error = error{ Fail, OutOfMemory };

pub const Macro = struct {
    nargs: u8,
    default: ?[]const Token,
    body: []const Token,
    delims: ?[]const []const Token = null,
};

pub const UserFrame = struct { name: []const u8, edef: []const Token };

pub const UserEnv = struct {
    nargs: u8,
    default: ?[]const Token,
    begin: []const Token,
    end: []const Token,
};

pub const Def = union(enum) {
    macro: Macro,
    alias: Token,
};

pub const Shared = struct {
    a: std.mem.Allocator,
    caps: tree.Caps,
    known: *const fn ([]const u8) bool,
    defs: std.StringHashMapUnmanaged(Def) = .empty,
    builtin_cache: std.StringHashMapUnmanaged(Macro) = .empty,
    userenvs: std.StringHashMapUnmanaged(UserEnv) = .empty,
    colors: std.StringHashMapUnmanaged(tree.Color) = .empty,
    root_up: ?f32 = null,
    root_left: ?f32 = null,
    in_root: bool = false,
    user_frames: std.ArrayList(UserFrame) = .empty,
    userend_name: []const u8 = "",
    stack_hi: usize = 0,
    stack_lo: usize = std.math.maxInt(usize),
    macro_count: u32 = 0,
    emitted: usize = 0,
    nodes: u32 = 0,
    tag_seen: bool = false,
    in_eqn: bool = false,
    err: ?[]const u8 = null,

    pub fn fail(sh: *Shared, msg: []const u8) Error {
        if (sh.err == null) sh.err = msg;
        return error.Fail;
    }

    pub fn failFmt(sh: *Shared, comptime fmt: []const u8, args: anytype) Error {
        const m = std.fmt.allocPrint(sh.a, fmt, args) catch return error.OutOfMemory;
        return sh.fail(m);
    }

};

const Frame = struct { toks: []const Token, pos: usize };

pub const Builtin = struct { nargs: u8, default: ?[]const u8 = null, body: []const u8 };

pub const builtins = std.StaticStringMap(Builtin).initComptime(.{
    .{ "stackrel", Builtin{ .nargs = 2, .body = "\\mathrel{\\mathop{#2}\\limits^{#1}}" } },
    .{ "stackbin", Builtin{ .nargs = 2, .body = "\\mathbin{\\mathop{#2}\\limits^{#1}}" } },
    .{ "boxed", Builtin{ .nargs = 1, .body = "\\fbox{$\\displaystyle{#1}$}" } },
    .{ "mathstrut", Builtin{ .nargs = 0, .body = "\\vphantom{(}" } },
    .{ "bmod", Builtin{ .nargs = 0, .body = "\\mathrel{\\mathrm{mod}}" } },
    .{ "pmod", Builtin{ .nargs = 1, .body = "\\pod{\\mathrm{mod}\\kern 6mu #1}" } },
    .{ "mod", Builtin{ .nargs = 1, .body = "\\mathchoice{\\kern18mu}{\\kern12mu}{\\kern12mu}{\\kern12mu}\\mathrm{mod}\\,\\,#1" } },
    .{ "pod", Builtin{ .nargs = 1, .body = "\\mathchoice{\\kern18mu}{\\kern8mu}{\\kern8mu}{\\kern8mu}(#1)" } },
    .{ "bra", Builtin{ .nargs = 1, .body = "{\\langle {#1} \\vert}" } },
    .{ "ket", Builtin{ .nargs = 1, .body = "{\\vert {#1} \\rangle}" } },
    .{ "Bra", Builtin{ .nargs = 1, .body = "{\\left\\langle {#1} \\right\\vert}" } },
    .{ "Ket", Builtin{ .nargs = 1, .body = "{\\left\\vert {#1} \\right\\rangle}" } },
    .{ "ketbra", Builtin{ .nargs = 2, .body = "{\\vert {#1} \\rangle\\langle {#2} \\vert}" } },
    .{ "Ketbra", Builtin{ .nargs = 2, .body = "{\\left\\vert {#1} \\right\\rangle\\left\\langle {#2} \\right\\vert}" } },
    .{ "TeX", Builtin{ .nargs = 0, .body = "T\\kern-.14em\\lower.5ex{E}\\kern-.115em X" } },
    .{ "LaTeX", Builtin{ .nargs = 0, .body = "L\\kern-.325em\\raise.21em{\\scriptstyle{A}}\\kern-.17em\\TeX" } },
    .{ "pmb", Builtin{ .nargs = 1, .body = "\\rlap{#1}\\kern1px{#1}" } },
    .{ "skew", Builtin{ .nargs = 3, .body = "{{#2{#3\\mkern#1mu}\\mkern-#1mu}{}}" } },
    .{ "texttip", Builtin{ .nargs = 2, .body = "\\mathtip{#1}{\\text{#2}}" } },
    .{ "idotsint", Builtin{ .nargs = 0, .body = "\\int\\cdots\\int" } },
    .{ "longrightleftharpoons", Builtin{ .nargs = 0, .body = "\\stackrel{\\textstyle{-}\\!\\!{\\rightharpoonup}}{\\smash{{\\leftharpoondown}\\!\\!{-}}}" } },
    .{ "longRightleftharpoons", Builtin{ .nargs = 0, .body = "\\stackrel{\\textstyle{-}\\!\\!{\\rightharpoonup}}{\\smash{\\leftharpoondown}}" } },
    .{ "longLeftrightharpoons", Builtin{ .nargs = 0, .body = "\\stackrel{\\textstyle\\vphantom{{-}}{\\rightharpoonup}}{\\smash{{\\leftharpoondown}\\!\\!{-}}}" } },
    .{ "longleftrightarrows", Builtin{ .nargs = 0, .body = "\\stackrel{\\longrightarrow}{\\smash{\\longleftarrow}\\Rule{0px}{.25em}{0px}}" } },
    .{ "tripledash", Builtin{ .nargs = 0, .body = "\\vphantom{-}\\raise2mu{\\kern2mu\\tiny\\text{-}\\kern1mu\\text{-}\\kern1mu\\text{-}\\kern2mu}" } },
    .{ "iff", Builtin{ .nargs = 0, .body = "\\;\\Longleftrightarrow\\;" } },
    .{ "implies", Builtin{ .nargs = 0, .body = "\\;\\Longrightarrow\\;" } },
    .{ "impliedby", Builtin{ .nargs = 0, .body = "\\;\\Longleftarrow\\;" } },
    .{ "substack", Builtin{ .nargs = 1, .body = "\\begin{subarray}{c}#1\\end{subarray}" } },
    .{ "ne", Builtin{ .nargs = 0, .body = "\\not=" } },
    .{ "neq", Builtin{ .nargs = 0, .body = "\\not=" } },
    .{ "notin", Builtin{ .nargs = 0, .body = "\\not\\in" } },
    .{ "varliminf", Builtin{ .nargs = 0, .body = "\\mathop{\\underline{\\mathrm{lim}}}" } },
    .{ "varlimsup", Builtin{ .nargs = 0, .body = "\\mathop{\\overline{\\mathrm{lim}}}" } },
    .{ "varinjlim", Builtin{ .nargs = 0, .body = "\\mathop{\\underrightarrow{\\mathrm{lim}}}" } },
    .{ "varprojlim", Builtin{ .nargs = 0, .body = "\\mathop{\\underleftarrow{\\mathrm{lim}}}" } },
    .{ "dotsc", Builtin{ .nargs = 0, .body = "\\ldots" } },
    .{ "dotso", Builtin{ .nargs = 0, .body = "\\ldots" } },
    .{ "dotsb", Builtin{ .nargs = 0, .body = "\\cdots" } },
    .{ "dotsm", Builtin{ .nargs = 0, .body = "\\cdots" } },
    .{ "dotsi", Builtin{ .nargs = 0, .body = "\\cdots" } },
});

pub const DefKind = enum { newcommand, def, let, newenvironment };

pub const Expander = struct {
    sh: *Shared,
    frames: std.ArrayList(Frame) = .empty,
    la: ?Token = null,

    pub fn init(sh: *Shared, toks: []const Token) !Expander {
        var ex: Expander = .{ .sh = sh };
        try ex.frames.append(sh.a, .{ .toks = toks, .pos = 0 });
        return ex;
    }

    pub fn raw(ex: *Expander) ?Token {
        if (ex.la) |t| {
            ex.la = null;
            return t;
        }
        while (ex.frames.items.len > 0) {
            const f = &ex.frames.items[ex.frames.items.len - 1];
            if (f.pos < f.toks.len) {
                f.pos += 1;
                return f.toks[f.pos - 1];
            }
            _ = ex.frames.pop();
        }
        return null;
    }

    pub fn pushFront(ex: *Expander, toks: []const Token) Error!void {
        if (ex.la) |t| {
            ex.la = null;
            const joined = try ex.sh.a.alloc(Token, toks.len + 1);
            @memcpy(joined[0..toks.len], toks);
            joined[toks.len] = t;
            return ex.push(joined);
        }
        return ex.push(toks);
    }

    pub fn unread(ex: *Expander, t: Token) void {
        ex.la = t;
    }

    pub fn peekRaw(ex: *Expander) ?Token {
        const t = ex.raw() orelse return null;
        ex.la = t;
        return t;
    }

    pub fn skipSpaces(ex: *Expander) void {
        while (ex.raw()) |t| {
            if (t.kind != .space) {
                ex.la = t;
                return;
            }
        }
    }

    fn push(ex: *Expander, toks: []const Token) Error!void {
        if (toks.len == 0) return;
        const sh = ex.sh;
        sh.emitted += toks.len;
        if (sh.emitted > sh.caps.max_tokens) return sh.fail(buffer_msg);
        while (ex.frames.items.len > 0) {
            const f = ex.frames.items[ex.frames.items.len - 1];
            if (f.pos < f.toks.len) break;
            _ = ex.frames.pop();
        }
        try ex.frames.append(sh.a, .{ .toks = toks, .pos = 0 });
    }

    /// Next token with user and built-in macros expanded.
    pub fn next(ex: *Expander) Error!Token {
        const sh = ex.sh;
        while (true) {
            const t = ex.raw() orelse return lexer.eof;
            if (t.kind != .cs) return t;
            const name = t.name();
            if (sh.defs.get(name)) |d| switch (d) {
                .macro => |m| try ex.run(t, m),
                .alias => |alias| return alias,
            } else if (builtins.get(name)) |b| {
                try ex.run(t, try ex.builtinMacro(name, b));
            } else return t;
        }
    }

    pub fn peek(ex: *Expander) Error!Token {
        const t = try ex.next();
        if (t.kind != .eof) ex.la = t;
        return t;
    }

    fn builtinMacro(ex: *Expander, name: []const u8, b: Builtin) Error!Macro {
        const sh = ex.sh;
        if (sh.builtin_cache.get(name)) |m| return m;
        const m: Macro = .{
            .nargs = b.nargs,
            .default = if (b.default) |d| try lex(sh, d) else null,
            .body = try lex(sh, b.body),
        };
        try sh.builtin_cache.put(sh.a, name, m);
        return m;
    }

    fn run(ex: *Expander, t: Token, m: Macro) Error!void {
        const sh = ex.sh;
        sh.macro_count += 1;
        if (sh.macro_count > sh.caps.max_macros) {
            return sh.fail("MathJax maximum macro substitution count exceeded; is here a recursive macro call?");
        }
        if (m.nargs == 0) return ex.push(m.body);
        const args = try sh.a.alloc([]const Token, m.nargs);
        var first: usize = 0;
        if (m.nargs > 0) if (m.default) |d| {
            args[0] = (try ex.readBrackets(t.text)) orelse d;
            first = 1;
        };
        if (m.delims) |d| {
            if (m.nargs > 0) {
                ex.skipSpaces();
                if (d[0].len > 0 and !try ex.matchPrefix(d[0])) return sh.failFmt("Use of {s} doesn't match its definition", .{t.text});
                for (0..m.nargs) |i| args[i] = if (d[i + 1].len == 0) try ex.readArg(t.text) else try ex.readDelimited(t.text, d[i + 1]);
                return ex.push(try ex.substitute(m, args));
            }
        }
        for (first..m.nargs) |i| args[i] = try ex.readArg(t.text);
        try ex.push(try ex.substitute(m, args));
    }

    /// MathJax strips the outer characters whenever the argument is nothing but brace groups.
    fn onlyGroups(arg: []const Token) bool {
        var depth: u32 = 0;
        for (arg) |t| {
            switch (t.kind) {
                .open => depth += 1,
                .close => depth -|= 1,
                else => if (depth == 0) return false,
            }
        }
        return true;
    }

    fn sameTok(a: Token, b: Token) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .cs => std.mem.eql(u8, a.text, b.text),
            else => a.cp == b.cp,
        };
    }

    fn matchPrefix(ex: *Expander, want: []const Token) Error!bool {
        for (want) |w| {
            const t = ex.raw() orelse return false;
            if (!sameTok(t, w)) return false;
        }
        return true;
    }

    /// Reads tokens up to the delimiter at brace depth 0; a lone braced group loses its braces.
    fn readDelimited(ex: *Expander, name: []const u8, delim: []const Token) Error![]const Token {
        const sh = ex.sh;
        var buf: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        while (ex.raw()) |t| {
            try buf.append(sh.a, t);
            switch (t.kind) {
                .open => depth += 1,
                .close => {
                    if (depth == 0) return sh.failFmt("Runaway argument for {s}?", .{name});
                    depth -= 1;
                },
                else => {},
            }
            if (depth != 0 or buf.items.len < delim.len) continue;
            const tail = buf.items[buf.items.len - delim.len ..];
            var same = true;
            for (tail, delim) |x, y| same = same and sameTok(x, y);
            if (!same) continue;
            var arg = buf.items[0 .. buf.items.len - delim.len];
            if (arg.len >= 2 and arg[0].kind == .open and onlyGroups(arg)) arg = arg[1 .. arg.len - 1];
            return arg;
        }
        return sh.failFmt("Runaway argument for {s}?", .{name});
    }

    pub fn substitute(ex: *Expander, m: Macro, args: []const []const Token) Error![]const Token {
        const sh = ex.sh;
        var out: std.ArrayList(Token) = .empty;
        var chars: usize = 0;
        var i: usize = 0;
        while (i < m.body.len) : (i += 1) {
            const t = m.body[i];
            if (t.kind != .hash) {
                chars += t.text.len;
                try out.append(sh.a, t);
                continue;
            }
            i += 1;
            const n = if (i < m.body.len) m.body[i] else lexer.eof;
            if (n.kind == .hash) {
                chars += 1;
                try out.append(sh.a, n);
            } else if (n.kind == .char and n.cp >= '1' and n.cp <= '9' and n.cp - '0' <= args.len) {
                for (args[n.cp - '1']) |at| chars += at.text.len;
                try out.appendSlice(sh.a, args[n.cp - '1']);
            } else return sh.fail("Illegal macro parameter reference");
            if (chars > sh.caps.max_buffer) return sh.fail(buffer_msg);
        }
        if (chars > sh.caps.max_buffer) return sh.fail(buffer_msg);
        return out.items;
    }

    /// One undelimited argument as raw tokens, without the outer braces.
    pub fn readArg(ex: *Expander, cmd: []const u8) Error![]const Token {
        const sh = ex.sh;
        ex.skipSpaces();
        const t = ex.raw() orelse return sh.failFmt("Missing argument for {s}", .{cmd});
        switch (t.kind) {
            .close => return sh.fail("Extra close brace or missing open brace"),
            .open => {
                if (ex.la == null and ex.frames.items.len > 0) {
                    const f = &ex.frames.items[ex.frames.items.len - 1];
                    var depth: u32 = 1;
                    var i = f.pos;
                    while (i < f.toks.len) : (i += 1) {
                        switch (f.toks[i].kind) {
                            .open => depth += 1,
                            .close => {
                                depth -= 1;
                                if (depth == 0) {
                                    const inner = f.toks[f.pos..i];
                                    f.pos = i + 1;
                                    return inner;
                                }
                            },
                            else => {},
                        }
                    }
                }
                var out: std.ArrayList(Token) = .empty;
                var depth: u32 = 1;
                while (ex.raw()) |x| {
                    switch (x.kind) {
                        .open => depth += 1,
                        .close => {
                            depth -= 1;
                            if (depth == 0) return out.items;
                        },
                        else => {},
                    }
                    try out.append(sh.a, x);
                }
                return sh.fail("Missing close brace");
            },
            else => {
                const one = try sh.a.alloc(Token, 1);
                one[0] = t;
                return one;
            },
        }
    }

    /// `[...]` optional argument; null when the next token is not `[`.
    pub fn readBrackets(ex: *Expander, cmd: []const u8) Error!?[]const Token {
        const sh = ex.sh;
        ex.skipSpaces();
        const t = ex.raw() orelse return null;
        if (!t.isChar('[')) {
            ex.la = t;
            return null;
        }
        var out: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        while (ex.raw()) |x| {
            switch (x.kind) {
                .open => depth += 1,
                .close => {
                    if (depth == 0) return sh.fail("Extra close brace while looking for ']'");
                    depth -= 1;
                },
                .char => if (x.cp == ']' and depth == 0) return out.items,
                else => {},
            }
            try out.append(sh.a, x);
        }
        return sh.failFmt("Could not find closing ']' for argument to {s}", .{cmd});
    }

    pub fn define(ex: *Expander, kind: DefKind, cmd: []const u8) Error!void {
        const sh = ex.sh;
        switch (kind) {
            .newcommand => {
                const name_toks = try ex.readArg(cmd);
                const name = csName(sh, name_toks) orelse return sh.failFmt("Illegal control sequence name for {s}", .{cmd});
                var nargs: u8 = 0;
                if (try ex.readBrackets(cmd)) |n| {
                    const s = std.mem.trim(u8, try textOf(sh.a, n), " ");
                    nargs = std.fmt.parseInt(u8, s, 10) catch return sh.failFmt("Illegal number of parameters specified in {s}", .{cmd});
                    for (s) |c| if (!std.ascii.isDigit(c)) return sh.failFmt("Illegal number of parameters specified in {s}", .{cmd});
                }
                const opt = try ex.readBrackets(cmd);
                const body = try ex.readArg(cmd);
                try sh.defs.put(sh.a, name, .{ .macro = .{ .nargs = nargs, .default = opt, .body = body } });
            },
            .def => {
                const name = try ex.csNameToken(cmd);
                var n: u8 = 0;
                var delims: std.ArrayList([]const Token) = .empty;
                var cur: std.ArrayList(Token) = .empty;
                ex.skipSpaces();
                var any = false;
                while (true) {
                    const t = ex.raw() orelse return sh.failFmt("Missing replacement string for definition of {s}", .{cmd});
                    if (t.kind == .open) {
                        ex.la = t;
                        break;
                    }
                    if (t.kind != .hash) {
                        try cur.append(sh.a, t);
                        any = true;
                        continue;
                    }
                    const d = ex.raw() orelse return sh.failFmt("Missing replacement string for definition of {s}", .{cmd});
                    if (!(d.kind == .char and d.cp >= '1' and d.cp <= '9')) return sh.failFmt("Illegal use of # in template for \\{s}", .{name});
                    try delims.append(sh.a, cur.items);
                    cur = .empty;
                    n += 1;
                    if (d.cp - '0' != n) return sh.failFmt("Parameters for \\{s} must be numbered sequentially", .{name});
                }
                try delims.append(sh.a, cur.items);
                const body = try ex.readArg(cmd);
                try sh.defs.put(sh.a, name, .{ .macro = .{ .nargs = n, .default = null, .body = body, .delims = if (any) delims.items else null } });
            },
            .newenvironment => {
                const name = std.mem.trim(u8, try textOf(sh.a, try ex.readArg(cmd)), " ");
                var nargs: u8 = 0;
                if (try ex.readBrackets(cmd)) |n| {
                    const s = std.mem.trim(u8, try textOf(sh.a, n), " ");
                    nargs = std.fmt.parseInt(u8, s, 10) catch return sh.failFmt("Illegal number of parameters specified in {s}", .{cmd});
                    for (s) |c| if (!std.ascii.isDigit(c)) return sh.failFmt("Illegal number of parameters specified in {s}", .{cmd});
                }
                const opt = try ex.readBrackets(cmd);
                const bdef = try ex.readArg(cmd);
                const edef = try ex.readArg(cmd);
                try sh.userenvs.put(sh.a, name, .{ .nargs = nargs, .default = opt, .begin = bdef, .end = edef });
            },
            .let => {
                const name = try ex.csNameToken(cmd);
                ex.skipSpaces();
                var t = ex.raw() orelse return;
                if (t.isChar('=')) {
                    ex.skipSpaces();
                    t = ex.raw() orelse return;
                }
                if (t.kind != .cs) {
                    try sh.defs.put(sh.a, name, .{ .alias = t });
                    return;
                }
                const target = t.name();
                if (sh.defs.get(target)) |d| {
                    try sh.defs.put(sh.a, name, d);
                } else if (builtins.get(target)) |b| {
                    try sh.defs.put(sh.a, name, .{ .macro = try ex.builtinMacro(target, b) });
                } else if (sh.known(target)) {
                    try sh.defs.put(sh.a, name, .{ .alias = t });
                }
            },
        }
    }

    fn csNameToken(ex: *Expander, cmd: []const u8) Error![]const u8 {
        ex.skipSpaces();
        const t = ex.raw() orelse return ex.sh.failFmt("{s} must be followed by a control sequence", .{cmd});
        if (t.kind != .cs) return ex.sh.failFmt("{s} must be followed by a control sequence", .{cmd});
        return t.name();
    }
};

const buffer_msg = "MathJax internal buffer size exceeded; is there a recursive macro call?";

fn csName(sh: *Shared, toks: []const Token) ?[]const u8 {
    const s = std.mem.trim(u8, textOf(sh.a, toks) catch return null, " ");
    const n = if (s.len > 0 and s[0] == '\\') s[1..] else s;
    if (n.len == 0) return null;
    var all_letters = true;
    for (n) |c| if (!std.ascii.isAlphabetic(c)) {
        all_letters = false;
    };
    if (all_letters) return n;
    const len = std.unicode.utf8ByteSequenceLength(n[0]) catch return null;
    return if (len == n.len) n else null;
}

pub fn textOf(a: std.mem.Allocator, toks: []const Token) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (toks) |t| try out.appendSlice(a, t.text);
    return out.items;
}

fn lex(sh: *Shared, src: []const u8) Error![]const Token {
    return lexer.tokenize(sh.a, src, sh.caps.max_tokens) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyTokens => sh.fail(buffer_msg),
    };
}

fn isKnownNever(_: []const u8) bool {
    return false;
}

test "user macro expansion and limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var sh: Shared = .{ .a = arena.allocator(), .caps = .{}, .known = isKnownNever };
    const toks = try lexer.tokenize(sh.a, "\\newcommand{\\a}[2]{#2+#1}\\a{x}{y}z", 1000);
    var ex = try Expander.init(&sh, toks);
    var t = try ex.next();
    try std.testing.expect(t.isCs("newcommand"));
    try ex.define(.newcommand, t.text);
    var got: std.ArrayList(u8) = .empty;
    while (true) {
        t = try ex.next();
        if (t.kind == .eof) break;
        try got.appendSlice(sh.a, t.text);
    }
    try std.testing.expectEqualStrings("y+xz", got.items);

    var sh2: Shared = .{ .a = arena.allocator(), .caps = .{}, .known = isKnownNever };
    const loop = try lexer.tokenize(sh2.a, "\\def\\a{\\a\\a}\\a", 1000);
    var ex2 = try Expander.init(&sh2, loop);
    const d = try ex2.next();
    try ex2.define(.def, d.text);
    try std.testing.expectError(error.Fail, ex2.next());
    try std.testing.expectEqualStrings("MathJax maximum macro substitution count exceeded; is here a recursive macro call?", sh2.err.?);
}
