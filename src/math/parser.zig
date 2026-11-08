const std = @import("std");
const lexer = @import("lexer.zig");
const macros = @import("macros.zig");
const symbols = @import("symbols.zig");
const tables = @import("tables.zig");
const denied = @import("denied.zig");
const mhchem = @import("mhchem.zig");
pub const tree = @import("tree.zig");

pub const Node = tree.Node;
pub const Tree = tree.Tree;
pub const Caps = tree.Caps;
pub const dump = tree.dump;

const Token = lexer.Token;
const Class = tree.Class;
const Font = tree.Font;
const Style = tree.Style;
const Limits = tree.Limits;
const Allocator = std.mem.Allocator;
const Error = macros.Error;
const Shared = macros.Shared;
const Spec = tables.Spec;

const Stop = enum { eof, close, right, middle, end, amp, cr, at };
const Ctx = enum { top, group, arg, left, env, eqn };
const Seq = struct { nodes: []const Node, stop: Stop };

const CdArrow = struct { c: u8, a: []const Token, b: []const Token };

const MarkerKind = union(enum) { font: Font, size: f32, style: Style, color: tree.Color };

const Marker = struct {
    start: usize,
    kind: MarkerKind,
};

const Over = struct {
    idx: usize,
    thickness: ?f32,
    open: ?u21,
    close: ?u21,
};

const Pending = enum { none, dots, not };

const State = struct {
    ctx: Ctx,
    list: std.ArrayList(Node) = .empty,
    markers: std.ArrayList(Marker) = .empty,
    over: ?Over = null,
    pending: Pending = .none,
    prime_at: ?usize = null,

    fn floor(st: *const State) usize {
        var f: usize = if (st.over) |o| o.idx else 0;
        if (st.markers.items.len > 0) f = @max(f, st.markers.items[st.markers.items.len - 1].start);
        return f;
    }
};

pub const Parser = struct {
    sh: *Shared,
    a: Allocator,
    ex: macros.Expander,
    depth: u32 = 0,
    hlines: u8 = 0,
    row_gap: ?f32 = null,
    end_name: []const u8 = "",
    env_name: []const u8 = "",
    in_cd: bool = false,
    cd_arrow: ?CdArrow = null,
    cd_minw: f32 = 2.75,
    cd_minh: f32 = 1.75,

    fn fail(p: *Parser, msg: []const u8) Error {
        return p.sh.fail(msg);
    }

    fn failFmt(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        return p.sh.failFmt(fmt, args);
    }

    fn enter(p: *Parser) Error!void {
        const fa = @frameAddress();
        p.sh.stack_hi = @max(p.sh.stack_hi, fa);
        p.sh.stack_lo = @min(p.sh.stack_lo, fa);
        p.depth += 1;
        if (p.depth > p.sh.caps.max_depth) return p.fail("Math expression is nested too deeply");
    }

    fn leave(p: *Parser) void {
        p.depth -= 1;
    }

    fn alloc(p: *Parser, n: Node) Error!*const Node {
        const ptr = try p.a.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn emptyGroup() Node {
        return .{ .group = .{ .body = &.{} } };
    }

    fn add(p: *Parser, st: *State, n: Node) Error!void {
        p.sh.nodes += 1;
        if (p.sh.nodes > p.sh.caps.max_nodes) return p.fail("Math expression is too large");
        var node = n;
        const pending = st.pending;
        st.pending = .none;
        switch (pending) {
            .none => {},
            .dots => if (st.list.items.len > 0) {
                const c = coreClass(node);
                if (c != null and (c.? == .bin or c.? == .rel)) st.list.items[st.list.items.len - 1].atom.cp = 0x22ef;
            },
            .not => node = try p.negate(node),
        }
        try st.list.append(p.a, node);
    }

    fn negate(p: *Parser, n: Node) Error!Node {
        if (n == .atom) {
            if (tables.notRemap(n.atom.cp)) |to| {
                var a = n.atom;
                a.cp = to;
                return .{ .atom = a };
            }
        }
        return .{ .negate = try p.alloc(n) };
    }

    fn subParse(p: *Parser, toks: []const Token) Error![]const Node {
        try p.enter();
        defer p.leave();
        var sub: Parser = .{ .sh = p.sh, .a = p.a, .ex = try macros.Expander.init(p.sh, toks), .depth = p.depth };
        const r = try sub.seq(.top);
        if (r.stop != .eof) return sub.stopError(r.stop);
        return r.nodes;
    }

    fn stopError(p: *Parser, stop: Stop) Error {
        return switch (stop) {
            .close => p.fail("Extra close brace or missing open brace"),
            .right => p.fail("Missing \\left or extra \\right"),
            .middle => p.fail("Extra \\middle"),
            .end => p.failFmt("Missing \\begin{{{s}}} or extra \\end{{{s}}}", .{ p.end_name, p.end_name }),
            .amp => p.fail("Misplaced &"),
            .eof, .cr, .at => p.fail("Missing close brace"),
        };
    }

    fn seq(p: *Parser, ctx: Ctx) Error!Seq {
        var st: State = .{ .ctx = ctx };
        var stop: Stop = .eof;
        while (true) {
            const t = try p.ex.next();
            if (try p.token(&st, t)) |s| {
                stop = s;
                break;
            }
        }
        return .{ .nodes = try p.finish(&st), .stop = stop };
    }

    fn finish(p: *Parser, st: *State) Error![]const Node {
        if (st.over) |ov| {
            const split = ov.idx;
            var num: std.ArrayList(Node) = .empty;
            try num.appendSlice(p.a, st.list.items[0..split]);
            var den: std.ArrayList(Node) = .empty;
            try den.appendSlice(p.a, st.list.items[split..]);
            var nm: std.ArrayList(Marker) = .empty;
            var dm: std.ArrayList(Marker) = .empty;
            for (st.markers.items) |m| if (m.start < split) {
                try dm.append(p.a, .{ .start = 0, .kind = m.kind });
            };
            for (st.markers.items) |m| {
                if (m.start < split) {
                    try nm.append(p.a, m);
                } else try dm.append(p.a, .{ .start = m.start - split, .kind = m.kind });
            }
            const frac: tree.Frac = .{
                .num = try p.applyMarkers(&num, &nm),
                .den = try p.applyMarkers(&den, &dm),
                .thickness = ov.thickness,
                .open = ov.open,
                .close = ov.close,
            };
            const out = try p.a.alloc(Node, 1);
            out[0] = .{ .frac = frac };
            return out;
        }
        return p.applyMarkers(&st.list, &st.markers);
    }

    fn applyMarkers(p: *Parser, list: *std.ArrayList(Node), markers: *std.ArrayList(Marker)) Error![]const Node {
        while (markers.pop()) |m| {
            const start = @min(m.start, list.items.len);
            const body = try p.a.dupe(Node, list.items[start..]);
            list.shrinkRetainingCapacity(start);
            const node: Node = switch (m.kind) {
                .font => |f| .{ .font = .{ .font = f, .body = body } },
                .size => |s| .{ .size = .{ .scale = s, .body = body } },
                .style => |s| .{ .style = .{ .style = s, .body = body } },
                .color => |c| .{ .color = .{ .color = c, .body = body } },
            };
            try list.append(p.a, node);
        }
        return list.items;
    }

    fn marker(p: *Parser, st: *State, kind: MarkerKind) Error!void {
        try st.markers.append(p.a, .{ .start = st.list.items.len, .kind = kind });
    }

    /// Handles one token; returns a stop reason when the list ends.
    fn token(p: *Parser, st: *State, t: Token) Error!?Stop {
        switch (t.kind) {
            .eof => return .eof,
            .space => {},
            .close => return .close,
            .amp => {
                if (st.ctx == .env) return .amp;
                return p.fail("Misplaced &");
            },
            .hash => return p.fail("You can't use 'macro parameter character #' in math mode"),
            .tilde => try p.add(st, .{ .space = .{ .width = 0.25 } }),
            .dollar => try p.add(st, .{ .atom = .{ .class = .ord, .cp = '$' } }),
            .open => {
                try p.enter();
                defer p.leave();
                const r = try p.seq(.group);
                switch (r.stop) {
                    .close => {},
                    .eof => return p.fail("Extra open brace or missing close brace"),
                    else => |s| return p.stopError(s),
                }
                try p.add(st, .{ .group = .{ .body = r.nodes } });
            },
            .sup => try p.script(st, true),
            .sub => try p.script(st, false),
            .char => {
                if (st.ctx == .env and p.in_cd and t.cp == '@') {
                    if (try p.cdArrowStart()) |stop| return stop;
                }
                try p.char(st, t);
            },
            .cs => return p.cs(st, t),
        }
        return null;
    }

    fn atomFor(cp: u21, text: []const u8) Node {
        if (symbols.lookupMath(text) orelse symbols.lookupMathCp(cp)) |e| {
            const out_cp: u21 = if (cp == '|') 0x7c else if (cp == 0xb7) 0xb7 else e.cp;
            return .{ .atom = .{ .class = e.class, .cp = out_cp, .italic = e.italic, .ams = e.ams } };
        }
        const letter = (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= 0xc0 and tables.isLetter(cp));
        return .{ .atom = .{ .class = .ord, .cp = cp, .italic = letter } };
    }

    fn char(p: *Parser, st: *State, t: Token) Error!void {
        const cp = t.cp;
        if (cp == '\'' or cp == 0x2019) return p.prime(st);
        if ((cp >= '0' and cp <= '9') or cp == '.') {
            if (try p.number(st, t)) return;
        }
        try p.add(st, atomFor(cp, t.text));
    }

    fn number(p: *Parser, st: *State, first: Token) Error!bool {
        var buf: std.ArrayList(u8) = .empty;
        var t = first;
        var seen_dot = false;
        if (first.cp == '.') {
            const n = try p.ex.next();
            p.ex.unread(n);
            if (!(n.kind == .char and n.cp >= '0' and n.cp <= '9')) return false;
        }
        while (true) {
            if (t.kind == .char and t.cp >= '0' and t.cp <= '9') {
                try buf.append(p.a, @intCast(t.cp));
            } else if (t.kind == .char and t.cp == '.' and !seen_dot) {
                seen_dot = true;
                try buf.append(p.a, '.');
            } else {
                if (t.kind != .eof) p.ex.unread(t);
                break;
            }
            t = try p.ex.next();
        }
        try p.add(st, .{ .number = buf.items });
        return true;
    }

    fn prime(p: *Parser, st: *State) Error!void {
        var count: usize = 1;
        while (true) {
            const n = try p.ex.next();
            if (n.kind == .space) continue;
            if (n.kind == .char and (n.cp == '\'' or n.cp == 0x2019)) {
                count += 1;
                continue;
            }
            if (n.kind != .eof) p.ex.unread(n);
            break;
        }
        var base = try p.takeBase(st);
        if (base == .supsub and base.supsub.sup != null) return p.fail("Prime causes double exponent: use braces to clarify");
        const glyphs = [_]u21{ 0x2032, 0x2033, 0x2034, 0x2057 };
        const items = try p.a.alloc(Node, if (count <= glyphs.len) 1 else count);
        if (count <= glyphs.len) {
            items[0] = .{ .atom = .{ .class = .ord, .cp = glyphs[count - 1] } };
        } else for (items) |*it| {
            it.* = .{ .atom = .{ .class = .ord, .cp = 0x2032 } };
        }
        if (base == .supsub) {
            var ss = base.supsub;
            ss.sup = items;
            base = .{ .supsub = ss };
        } else {
            const inner = try p.alloc(base);
            base = .{ .supsub = .{ .base = inner, .sup = items, .sub = null, .limits = limitsOf(inner.*) } };
        }
        try p.add(st, base);
        st.prime_at = st.list.items.len - 1;
    }

    fn takeBase(p: *Parser, st: *State) Error!Node {
        _ = p;
        st.pending = .none;
        if (st.list.items.len <= st.floor()) return emptyGroup();
        return st.list.pop().?;
    }

    fn limitsOf(base: Node) Limits {
        return switch (base) {
            .op => |o| o.limits,
            .stack => |s| if (s.brace) .above else .side,
            else => .side,
        };
    }

    fn script(p: *Parser, st: *State, is_sup: bool) Error!void {
        const base = try p.takeBase(st);
        const merge_primes = st.prime_at != null and st.prime_at.? == st.list.items.len;
        st.prime_at = null;
        var ss: tree.SupSub = if (base == .supsub) base.supsub else .{
            .base = try p.alloc(base),
            .sup = null,
            .sub = null,
            .limits = limitsOf(base),
        };
        if (base == .supsub) {
            if (is_sup and ss.sup != null and !merge_primes) return p.fail("Double exponent: use braces to clarify");
            if (!is_sup and ss.sub != null) return p.fail("Double subscripts: use braces to clarify");
        }
        const sarg = try p.scriptArg(is_sup);
        if (is_sup) {
            if (merge_primes and ss.sup != null) {
                const joined = try p.a.alloc(Node, ss.sup.?.len + sarg.len);
                @memcpy(joined[0..ss.sup.?.len], ss.sup.?);
                @memcpy(joined[ss.sup.?.len..], sarg);
                ss.sup = joined;
            } else ss.sup = sarg;
        } else ss.sub = sarg;
        try p.add(st, .{ .supsub = ss });
    }

    fn scriptArg(p: *Parser, is_sup: bool) Error![]const Node {
        p.ex.skipSpaces();
        const t = try p.ex.next();
        switch (t.kind) {
            .eof => return p.fail("Missing superscript or subscript argument"),
            .close => return p.fail("Extra close brace or missing open brace"),
            .amp => return p.fail(if (is_sup) "Missing open brace for superscript" else "Missing open brace for subscript"),
            .sup => return p.fail(if (is_sup) "Double exponent: use braces to clarify" else "Missing superscript or subscript argument"),
            .sub => return p.fail(if (is_sup) "Missing superscript or subscript argument" else "Double subscripts: use braces to clarify"),
            .open => {
                try p.enter();
                defer p.leave();
                const r = try p.seq(.group);
                switch (r.stop) {
                    .close => {},
                    .eof => return p.fail("Extra open brace or missing close brace"),
                    else => |s| return p.stopError(s),
                }
                return r.nodes;
            },
            else => {
                if (t.kind == .cs and tables.endsList(t.name())) {
                    return p.fail(if (is_sup) "Missing open brace for superscript" else "Missing open brace for subscript");
                }
                if (t.kind == .char and t.cp >= '0' and t.cp <= '9') {
                    const buf = try p.a.alloc(u8, 1);
                    buf[0] = @intCast(t.cp);
                    const out = try p.a.alloc(Node, 1);
                    out[0] = .{ .number = buf };
                    return out;
                }
                return p.unit(t);
            },
        }
    }

    /// Parses exactly one token (and what it consumes) into nodes.
    fn unit(p: *Parser, t: Token) Error![]const Node {
        var st: State = .{ .ctx = .arg };
        if (try p.token(&st, t)) |s| return p.stopError(s);
        return p.finish(&st);
    }

    fn lex(p: *Parser, s: []const u8) Error![]const Token {
        return lexer.tokenize(p.a, s, p.sh.caps.max_tokens) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooManyTokens => p.fail("MathJax internal buffer size exceeded; is there a recursive macro call?"),
        };
    }

    fn argToks(p: *Parser, cmd: []const u8) Error![]const Token {
        return p.ex.readArg(cmd);
    }

    fn arg(p: *Parser, cmd: []const u8) Error![]const Node {
        const toks = try p.ex.readArg(cmd);
        return p.subParse(toks);
    }

    fn optArg(p: *Parser, cmd: []const u8) Error!?[]const Node {
        const toks = (try p.ex.readBrackets(cmd)) orelse return null;
        return try p.subParse(toks);
    }

    fn rawText(p: *Parser, cmd: []const u8) Error![]const u8 {
        return macros.textOf(p.a, try p.ex.readArg(cmd));
    }

    fn delimiterIn(p: *Parser, t: Token, cmd: []const u8) Error!?u21 {
        if (tables.delimiter(t)) |d| return d.cp;
        return p.failFmt("Missing or unrecognized delimiter for {s}", .{cmd});
    }

    fn readDelimiter(p: *Parser, cmd: []const u8, brace_ok: bool) Error!?u21 {
        p.ex.skipSpaces();
        var t = try p.ex.next();
        if (t.kind == .open and brace_ok) {
            p.ex.unread(t);
            const toks = try p.ex.readArg(cmd);
            const s = std.mem.trim(u8, try macros.textOf(p.a, toks), " ");
            const sub = try p.lex(s);
            if (sub.len != 1) return p.failFmt("Missing or unrecognized delimiter for {s}", .{cmd});
            t = sub[0];
        }
        return p.delimiterIn(t, cmd);
    }

    fn dimen(p: *Parser, cmd: []const u8) Error!f32 {
        p.ex.skipSpaces();
        const first = try p.ex.next();
        if (first.kind == .open) {
            p.ex.unread(first);
            const s = try p.rawText(cmd);
            if (tables.matchDimen(s, false)) |r| return r.value;
            return p.failFmt("Missing dimension or its units for {s}", .{cmd});
        }
        var buf: std.ArrayList(u8) = .empty;
        var t = first;
        var digits = false;
        var letters: u8 = 0;
        while (true) {
            if (t.kind == .space and digits and letters == 0) {
                p.ex.skipSpaces();
                t = try p.ex.next();
            }
            if (t.kind != .char or t.cp >= 128) break;
            const ch: u8 = @intCast(t.cp);
            if (letters == 0 and (ch == '+' or ch == '-') and buf.items.len == 0) {
                try buf.append(p.a, ch);
            } else if (letters == 0 and (std.ascii.isDigit(ch) or ch == '.' or ch == ',')) {
                digits = digits or std.ascii.isDigit(ch);
                try buf.append(p.a, ch);
            } else if (digits and std.ascii.isAlphabetic(ch)) {
                try buf.append(p.a, ch);
                letters += 1;
                if (letters == 2) {
                    t = lexer.eof;
                    break;
                }
            } else break;
            t = try p.ex.next();
        }
        if (t.kind != .eof) p.ex.unread(t);
        const r = tables.matchDimen(buf.items, true) orelse return p.failFmt("Missing dimension or its units for {s}", .{cmd});
        if (p.ex.peekRaw()) |n| if (n.kind == .space) {
            _ = p.ex.raw();
        };
        return r.value;
    }

    fn cs(p: *Parser, st: *State, t: Token) Error!?Stop {
        const name = t.name();
        if (std.mem.eql(u8, name, "@userend")) {
            p.end_name = p.sh.userend_name;
            return .end;
        }
        if (denied.names.has(name)) {
            try p.add(st, .{ .undefined_cs = t.text });
            return null;
        }
        if (tables.specs.get(name)) |sp| return p.spec(st, t, sp);
        var buf: [96]u8 = undefined;
        if (name.len < buf.len - 1) {
            buf[0] = '\\';
            @memcpy(buf[1 .. 1 + name.len], name);
            if (symbols.lookupMath(buf[0 .. 1 + name.len])) |e| {
                try p.symbol(st, e, name);
                return null;
            }
        }
        if (tables.extras.get(name)) |e| {
            try p.add(st, .{ .atom = .{ .class = e.class, .cp = e.cp, .italic = e.italic, .ams = e.ams } });
            return null;
        }
        const full = try std.fmt.allocPrint(p.a, "\\{s}", .{name});
        try p.add(st, .{ .undefined_cs = full });
        return null;
    }

    fn symbol(p: *Parser, st: *State, entry: symbols.Entry, name: []const u8) Error!void {
        var e = entry;
        if (tables.mathjax_cp.get(name)) |cp| e.cp = cp;
        if (e.class == .op) {
            const body = try p.a.alloc(Node, 1);
            body[0] = .{ .atom = .{ .class = .op, .cp = e.cp } };
            const side = tables.sideLimits(name);
            try p.add(st, .{ .op = .{ .body = body, .limits = if (side) .side else .display, .large = !std.mem.eql(u8, name, "smallint") } });
            return;
        }
        try p.add(st, .{ .atom = .{ .class = e.class, .cp = e.cp, .italic = e.italic, .ams = e.ams } });
    }

    fn spec(p: *Parser, st: *State, t: Token, s: Spec) Error!?Stop {
        const cmd = t.text;
        switch (s) {
            .mathfont => |f| try p.add(st, .{ .font = .{ .font = f, .body = try p.arg(cmd) } }),
            .setfont => |f| try p.marker(st, .{ .font = f }),
            .textfont => |f| try p.textCmd(st, cmd, f, false),
            .setsize => |v| try p.marker(st, .{ .size = v }),
            .setstyle => |v| try p.marker(st, .{ .style = v }),
            .namedfn => |n| try p.add(st, try p.named(n, .side, false)),
            .namedop => |n| try p.add(st, try p.named(n, .display, false)),
            .accent => |a| try p.add(st, .{ .accent = .{ .base = try p.arg(cmd), .cp = a.cp, .wide = a.wide } }),
            .over_under => |o| {
                const base = try p.arg(cmd);
                if (o.cp == 0x2015) {
                    try p.add(st, .{ .line = .{ .body = base, .over = o.over } });
                } else {
                    var stack: tree.Stack = .{ .base = base, .brace = o.brace };
                    if (o.over) stack.over_cp = o.cp else stack.under_cp = o.cp;
                    try p.add(st, .{ .stack = stack });
                }
            },
            .spacer => |w| try p.add(st, .{ .space = .{ .width = w, .reset_script = true } }),
            .hskip => try p.add(st, .{ .space = .{ .width = try p.dimen(cmd) } }),
            .big => |b| {
                const d = try p.readDelimiter(cmd, true);
                try p.add(st, .{ .big = .{ .class = b.class, .size = b.size, .cp = d } });
            },
            .atom_class => |c| {
                const body = try p.arg(cmd);
                try p.add(st, .{ .group = .{ .body = body, .class = c } });
            },
            .frac => |f| try p.fracCmd(st, cmd, f),
            .over => |o| return p.overCmd(st, t, o),
            .xarrow => |cp| try p.xarrow(st, cmd, cp),
            .cmd => |c| return p.command(st, t, c),
        }
        return null;
    }

    fn named(p: *Parser, name: []const u8, limits: Limits, large: bool) Error!Node {
        var body: std.ArrayList(Node) = .empty;
        const view = std.unicode.Utf8View.initUnchecked(name);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == ' ') {
                try body.append(p.a, .{ .space = .{ .width = 1.0 / 6.0 } });
            } else try body.append(p.a, .{ .atom = .{ .class = .ord, .cp = cp } });
        }
        return .{ .op = .{ .body = body.items, .limits = limits, .large = large } };
    }

    fn fracCmd(p: *Parser, st: *State, cmd: []const u8, f: tables.FracSpec) Error!void {
        var frac: tree.Frac = .{ .num = &.{}, .den = &.{}, .style = f.style, .open = f.open, .close = f.close };
        if (f.thin) frac.thickness = 0;
        if (f.generic) {
            p.ex.skipSpaces();
            frac.open = try p.delimArg(cmd);
            frac.close = try p.delimArg(cmd);
            const thick = std.mem.trim(u8, try p.rawText(cmd), " ");
            if (thick.len > 0) {
                if (tables.matchDimen(thick, false)) |r| frac.thickness = r.value;
            }
            const style = std.mem.trim(u8, try p.rawText(cmd), " ");
            if (style.len > 0) {
                const n = std.fmt.parseInt(u8, style, 10) catch 9;
                frac.style = switch (n) {
                    0 => Style.display,
                    1 => .text,
                    2 => .script,
                    3 => .scriptscript,
                    else => return p.failFmt("Bad math style for {s}", .{cmd}),
                };
            }
            if (frac.open == null and frac.close == null) frac.open = null;
        }
        if (f.cont) {
            const lr = std.mem.trim(u8, try p.optRaw(cmd), " ");
            if (lr.len > 0 and !std.mem.eql(u8, lr, "l") and !std.mem.eql(u8, lr, "r")) {
                return p.failFmt("Illegal alignment specified in {s}", .{cmd});
            }
            frac.num = try p.styled(try p.arg(cmd), .text);
            frac.den = try p.styled(try p.arg(cmd), .text);
        } else {
            frac.num = try p.arg(cmd);
            frac.den = try p.arg(cmd);
        }
        try p.add(st, .{ .frac = frac });
    }

    fn styled(p: *Parser, body: []const Node, style: Style) Error![]const Node {
        const out = try p.a.alloc(Node, 1);
        out[0] = .{ .style = .{ .style = style, .body = body } };
        return out;
    }

    fn optRaw(p: *Parser, cmd: []const u8) Error![]const u8 {
        const toks = (try p.ex.readBrackets(cmd)) orelse return "";
        return macros.textOf(p.a, toks);
    }

    fn delimArg(p: *Parser, cmd: []const u8) Error!?u21 {
        const s = std.mem.trim(u8, try p.rawText(cmd), " ");
        if (s.len == 0) return null;
        const toks = try p.lex(s);
        if (toks.len == 1) if (tables.delimiter(toks[0])) |d| return d.cp;
        return p.failFmt("Missing or unrecognized delimiter for {s}", .{cmd});
    }

    fn overCmd(p: *Parser, st: *State, t: Token, o: tables.OverSpec) Error!?Stop {
        if (st.over != null) return p.failFmt("Ambiguous use of {s}", .{t.text});
        var ov: Over = .{ .idx = st.list.items.len, .thickness = null, .open = o.open, .close = o.close };
        if (o.delims and o.open == null) {
            ov.open = try p.readDelimiter(t.text, false);
            ov.close = try p.readDelimiter(t.text, false);
        }
        if (o.above) ov.thickness = try p.dimen(t.text) else if (o.atop or o.open != null) ov.thickness = 0;
        st.over = ov;
        return null;
    }

    fn textCmd(p: *Parser, st: *State, cmd: []const u8, font: Font, box: bool) Error!void {
        const raw = try p.rawText(cmd);
        const nodes = try p.internalMath(raw, font);
        if (box) {
            try p.add(st, .{ .style = .{ .style = .text, .body = nodes } });
        } else for (nodes) |n| try p.add(st, n);
    }

    noinline fn internalMath(p: *Parser, raw: []const u8, font: Font) Error![]const Node {
        var out: std.ArrayList(Node) = .empty;
        const Match = enum { none, dollar, paren };
        var match: Match = .none;
        var braces: u32 = 0;
        var k: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            i += 1;
            if (c == '$') {
                if (match == .dollar and braces == 0) {
                    try p.mathChunk(&out, raw[k .. i - 1]);
                    match = .none;
                    k = i;
                } else if (match == .none) {
                    if (k < i - 1) try p.textChunk(&out, raw[k .. i - 1], font);
                    match = .dollar;
                    k = i;
                }
            } else if (c == '{' and match != .none) {
                braces += 1;
            } else if (c == '}') {
                if (match != .none and braces > 0) braces -= 1;
            } else if (c == '\\' and i < raw.len) {
                const d = raw[i];
                i += 1;
                if (d == '(' and match == .none) {
                    if (k < i - 2) try p.textChunk(&out, raw[k .. i - 2], font);
                    match = .paren;
                    k = i;
                } else if (d == ')' and match == .paren and braces == 0) {
                    try p.mathChunk(&out, raw[k .. i - 2]);
                    match = .none;
                    k = i;
                }
            }
        }
        if (match != .none) return p.fail("Math not terminated in text box");
        if (k < raw.len) try p.textChunk(&out, raw[k..], font);
        if (out.items.len > 1) {
            const one = try p.a.alloc(Node, 1);
            one[0] = .{ .group = .{ .body = out.items } };
            return one;
        }
        return out.items;
    }

    fn mathChunk(p: *Parser, out: *std.ArrayList(Node), src: []const u8) Error!void {
        const toks = try p.lex(src);
        try out.append(p.a, .{ .group = .{ .body = try p.subParse(toks) } });
    }

    fn textChunk(p: *Parser, out: *std.ArrayList(Node), src: []const u8, font: Font) Error!void {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            if (src[i] == '\\' and i + 1 < src.len and std.mem.indexOfScalar(u8, "${}\\", src[i + 1]) != null) i += 1;
            try buf.append(p.a, src[i]);
        }
        var s = buf.items;
        const nbsp = "\u{a0}";
        var lead: usize = 0;
        while (lead < s.len and std.ascii.isWhitespace(s[lead])) lead += 1;
        var tail: usize = s.len;
        while (tail > lead and std.ascii.isWhitespace(s[tail - 1])) tail -= 1;
        var final: std.ArrayList(u8) = .empty;
        if (lead > 0) try final.appendSlice(p.a, nbsp);
        var prev_space = false;
        for (s[lead..tail]) |ch| {
            if (std.ascii.isWhitespace(ch)) {
                if (!prev_space) try final.append(p.a, ' ');
                prev_space = true;
            } else {
                prev_space = false;
                try final.append(p.a, ch);
            }
        }
        if (tail < s.len or (lead == s.len and lead > 0)) {
            if (lead != s.len) try final.appendSlice(p.a, nbsp);
        }
        s = final.items;
        try out.append(p.a, .{ .text = .{ .str = s, .font = font } });
    }

    fn command(p: *Parser, st: *State, t: Token, c: tables.Cmd) Error!?Stop {
        const cmd = t.text;
        switch (c) {
            .sqrt => try p.sqrt(st, cmd),
            .root => {
                const toks = try p.upTo(cmd, "of");
                p.sh.root_up = null;
                p.sh.root_left = null;
                const saved_root = p.sh.in_root;
                p.sh.in_root = true;
                const index = p.subParse(toks) catch |e| {
                    p.sh.in_root = saved_root;
                    return e;
                };
                p.sh.in_root = saved_root;
                const body = try p.arg(cmd);
                try p.add(st, .{ .sqrt = p.sqrtIndex(index, body) });
            },
            .left => try p.fenced(st),
            .right, .middle => return if (c == .right) .right else .middle,
            .begin => try p.begin(st),
            .end => {
                p.end_name = try p.readEndName(cmd);
                const frames = &p.sh.user_frames;
                if (frames.items.len > 0 and std.mem.eql(u8, frames.items[frames.items.len - 1].name, p.end_name)) {
                    const frame = frames.pop().?;
                    p.sh.userend_name = frame.name;
                    const tail = try p.a.alloc(Token, frame.edef.len + 1);
                    @memcpy(tail[0..frame.edef.len], frame.edef);
                    tail[frame.edef.len] = .{ .kind = .cs, .text = "\\@userend" };
                    try p.ex.pushFront(tail);
                    return null;
                }
                return .end;
            },
            .limits, .nolimits => try p.setLimits(st, cmd, c == .limits),
            .mathop => {
                const body = try p.arg(cmd);
                try p.add(st, .{ .op = .{ .body = body, .limits = .display, .large = false } });
            },
            .operatorname => try p.operatorName(st, cmd),
            .hbox => try p.textCmd(st, cmd, .default, true),
            .fbox => {
                const body = try p.internalMath(try p.rawText(cmd), .default);
                try p.add(st, .{ .enclose = .{ .body = body, .border = true } });
            },
            .color => {
                const model = try p.optRaw(cmd);
                const spec_text = try p.rawText(cmd);
                try p.marker(st, .{ .color = try p.colorFrom(model, spec_text) });
            },
            .textcolor => {
                const model = try p.optRaw(cmd);
                const spec_text = try p.rawText(cmd);
                const color = try p.colorFrom(model, spec_text);
                try p.add(st, .{ .color = .{ .color = color, .body = try p.arg(cmd) } });
            },
            .colorbox => {
                const color = try p.colorFrom("", try p.rawText(cmd));
                const body = try p.internalMath(try p.rawText(cmd), .default);
                try p.add(st, .{ .enclose = .{ .body = body, .border = false, .bg = color } });
            },
            .fcolorbox => {
                const border = try p.colorFrom("", try p.rawText(cmd));
                const color = try p.colorFrom("", try p.rawText(cmd));
                const body = try p.internalMath(try p.rawText(cmd), .default);
                try p.add(st, .{ .enclose = .{ .body = body, .border = true, .bg = color, .border_color = border } });
            },
            .newcommand => try p.ex.define(.newcommand, cmd),
            .raise, .lower, .moveleft, .moveright => {
                const h = try p.dimen(cmd);
                const body = try p.nextBox(cmd);
                const sh: tree.Shift = switch (c) {
                    .raise => .{ .dx = 0, .dy = h, .body = body },
                    .lower => .{ .dx = 0, .dy = -h, .body = body },
                    .moveleft => .{ .dx = -h, .dy = 0, .body = body },
                    else => .{ .dx = h, .dy = 0, .body = body },
                };
                try p.add(st, .{ .shift = sh });
            },
            .llap, .rlap => try p.add(st, .{ .lap = .{ .left = c == .llap, .body = try p.arg(cmd) } }),
            .vcenter => try p.add(st, .{ .vcenter = try p.arg(cmd) }),
            .nonscript => try p.add(st, .nonscript),
            .strut => try p.add(st, .{ .rule = .{ .w = 0, .h = 0.86, .d = 0.3, .blank = true } }),
            .buildrel => {
                const top = try p.subParse(try p.upTo(cmd, "over"));
                const bot = try p.arg(cmd);
                const inner = try p.box1(.{ .stack = .{ .base = bot, .over = top } });
                try p.add(st, .{ .group = .{ .body = inner, .class = .rel } });
            },
            .framebox => {
                _ = try p.ex.readBrackets(cmd);
                _ = try p.ex.readBrackets(cmd);
                const body = try p.internalMath(try p.rawText(cmd), .default);
                try p.add(st, .{ .enclose = .{ .body = body, .border = true, .notation = .{ .box = true } } });
            },
            .hfill => {
                if (st.ctx != .env) return p.failFmt("Unsupported use of {s}", .{cmd});
            },
            .matrix_tex, .pmatrix_tex, .cases_tex, .eqalign, .displaylines => try p.plainArray(st, cmd, c),
            .ref, .eqref => {
                _ = try p.rawText(cmd);
                try p.add(st, .{ .text = .{ .str = if (c == .ref) "???" else "(???)" } });
            },
            .mmltoken => try p.mmlToken(st, cmd),
            .uproot, .leftroot => try p.rootShift(cmd, c == .uproot),
            .sideset => try p.sideSet(st, cmd),
            .declareop => try p.declareOp(cmd),
            .shoveleft, .shoveright => {
                if (st.ctx != .env or !std.mem.startsWith(u8, p.env_name, "multline")) {
                    return p.failFmt("{s} only allowed in {s} environment", .{ cmd, "multline" });
                }
                if (st.list.items.len != 0) return p.failFmt("{s} must come at the beginning of the line", .{cmd});
            },
            .newenvironment => try p.ex.define(.newenvironment, cmd),
            .cancel, .bcancel, .xcancel => {
                _ = try p.ex.readBrackets(cmd);
                const body = try p.arg(cmd);
                const n: tree.Notation = .{ .updiagonalstrike = c != .bcancel, .downdiagonalstrike = c != .cancel };
                try p.add(st, .{ .enclose = .{ .body = body, .border = false, .notation = n } });
            },
            .cancelto => {
                _ = try p.ex.readBrackets(cmd);
                const value = try p.arg(cmd);
                const body = try p.arg(cmd);
                const base = try p.alloc(.{ .enclose = .{ .body = body, .border = false, .notation = .{ .updiagonalstrike = true, .updiagonalarrow = true } } });
                try p.add(st, .{ .supsub = .{ .base = base, .sup = value, .sub = null, .limits = .side } });
            },
            .enclose => try p.encloseCmd(st, cmd),
            .bbox => try p.bboxCmd(st, cmd),
            .braket, .set, .braket_big, .set_big => try p.braketCmd(st, cmd, c == .set or c == .set_big, c == .braket_big or c == .set_big),
            .xarrowcp => {
                const s = std.mem.trim(u8, try p.rawText(cmd), " ");
                try p.xarrow(st, cmd, std.fmt.parseInt(u21, s, 10) catch 0x2192);
            },
            .newextarrow => try p.newExtArrow(cmd),
            .html => {
                const first = try p.rawText(cmd);
                const body = try p.arg(cmd);
                const name = t.name();
                if (std.mem.eql(u8, name, "href")) {
                    const url = std.mem.trim(u8, first, " ");
                    if (std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://")) {
                        try p.add(st, .{ .link = .{ .url = url, .body = body } });
                        return null;
                    }
                } else if (std.mem.eql(u8, name, "style")) {
                    try p.add(st, try p.assemble(try p.parseCss(first), body, 0));
                    return null;
                }
                if (body.len == 1) {
                    try p.add(st, body[0]);
                } else try p.add(st, .{ .group = .{ .body = body } });
            },
            .require => {
                const name = std.mem.trim(u8, try p.rawText(cmd), " ");
                const blocked = [_][]const u8{ "base", "all-packages", "autoload", "configmacros", "tagformat", "setoptions", "texhtml" };
                for (blocked) |b| if (std.mem.eql(u8, b, name)) {
                    return p.failFmt("Extension \"[tex]/{s}\" is not allowed to be loaded", .{name});
                };
            },
            .unicode => try p.unicodeCmd(st, cmd),
            .verb => try p.verbCmd(st, cmd),
            .definecolor => {
                const name = try p.rawText(cmd);
                const model = try p.rawText(cmd);
                const def = try p.rawText(cmd);
                const color = try p.colorFrom(model, def);
                try p.sh.colors.put(p.a, name, color);
            },
            .toggle => {
                var chosen: ?[]const Node = null;
                while (true) {
                    const toks = try p.ex.readArg(cmd);
                    if (toks.len == 1 and toks[0].isCs("endtoggle")) break;
                    const nodes = try p.subParse(toks);
                    if (chosen == null) chosen = nodes;
                }
                try p.add(st, .{ .group = .{ .body = chosen orelse &.{} } });
            },
            .mathtip => {
                const shown = try p.arg(cmd);
                _ = try p.arg(cmd);
                try p.add(st, .{ .group = .{ .body = shown } });
            },
            .ce, .pu => try p.chemCmd(cmd, c == .pu),
            .proof_cmd => {
                if (tables.proofCmd(t.name())) |pc| if (pc == .fcenter) return null;
                return p.fail("Proof commands only allowed in prooftree environment.");
            },
            .cd_size => {
                const v = try p.dimen(cmd);
                if (std.mem.eql(u8, t.name(), "minCDarrowwidth")) p.cd_minw = v else p.cd_minh = v;
            },
            .bbbk => {
                const k = try p.box1(.{ .atom = .{ .class = .ord, .cp = 'k', .italic = true } });
                try p.add(st, .{ .font = .{ .font = .bb, .body = k } });
            },
            .iiiint => {
                const body = try p.box1(.{ .atom = .{ .class = .op, .cp = 0x2a0c } });
                try p.add(st, .{ .op = .{ .body = body, .limits = .side, .large = true } });
            },
            .def => try p.ex.define(.def, cmd),
            .let => try p.ex.define(.let, cmd),
            .not => st.pending = .not,
            .dots => {
                try p.add(st, .{ .atom = .{ .class = .inner, .cp = 0x2026 } });
                st.pending = .dots;
            },
            .cdots => try p.add(st, .{ .atom = .{ .class = .inner, .cp = 0x22ef } }),
            .vdots => try p.add(st, .{ .atom = .{ .class = .ord, .cp = 0x22ee } }),
            .colon => try p.add(st, .{ .atom = .{ .class = .punct, .cp = ':' } }),
            .overset, .underset => {
                const note = try p.arg(cmd);
                const base = try p.arg(cmd);
                var stack: tree.Stack = .{ .base = base };
                if (c == .overset) stack.over = note else stack.under = note;
                try p.add(st, .{ .stack = stack });
            },
            .overunderset => {
                const over = try p.arg(cmd);
                const under = try p.arg(cmd);
                const base = try p.arg(cmd);
                try p.add(st, .{ .stack = .{ .base = base, .over = over, .under = under } });
            },
            .xrightarrow, .xleftarrow => {
                const under = try p.optArg(cmd);
                const over = try p.arg(cmd);
                try p.add(st, .{ .xarrow = .{ .cp = if (c == .xrightarrow) 0x2192 else 0x2190, .over = over, .under = under } });
            },
            .boldsymbol => try p.add(st, .{ .font = .{ .font = .bsym, .body = try p.arg(cmd) } }),
            .phantom, .vphantom, .hphantom => {
                const body = try p.arg(cmd);
                try p.add(st, .{ .phantom = .{
                    .body = body,
                    .visible = false,
                    .w = c != .vphantom,
                    .h = c != .hphantom,
                    .d = c != .hphantom,
                } });
            },
            .smash => {
                const opt = std.mem.trim(u8, try p.optRaw(cmd), " ");
                const body = try p.arg(cmd);
                const only_b = std.mem.eql(u8, opt, "b");
                const only_t = std.mem.eql(u8, opt, "t");
                try p.add(st, .{ .phantom = .{ .body = body, .visible = true, .w = true, .h = only_b, .d = only_t } });
            },
            .rule => {
                const raise = if (try p.ex.readBrackets(cmd)) |toks| blk: {
                    const s = try macros.textOf(p.a, toks);
                    const r = tables.matchDimen(s, false) orelse return p.failFmt("Missing dimension or its units for {s}", .{cmd});
                    break :blk r.value;
                } else 0;
                const w = try p.dimen(cmd);
                const h = try p.dimen(cmd);
                try p.add(st, .{ .rule = .{ .w = w, .h = h, .d = 0, .raise = raise } });
            },
            .rule_big, .space_big => {
                const w = try p.dimen(cmd);
                const h = try p.dimen(cmd);
                const d = try p.dimen(cmd);
                try p.add(st, .{ .rule = .{ .w = w, .h = h, .d = d, .blank = c == .space_big } });
            },
            .mathchoice => {
                const d = try p.arg(cmd);
                const tx = try p.arg(cmd);
                const s = try p.arg(cmd);
                const ss = try p.arg(cmd);
                try p.add(st, .{ .mathchoice = .{ .d = d, .t = tx, .s = s, .ss = ss } });
            },
            .tag => {
                p.ex.skipSpaces();
                if (p.ex.peekRaw()) |n| if (n.isChar('*')) {
                    _ = p.ex.raw();
                };
                _ = try p.rawText(cmd);
                if (p.sh.tag_seen) return p.fail("Multiple \\tag");
                p.sh.tag_seen = true;
            },
            .label => _ = try p.rawText(cmd),
            .nonumber => {},
            .cr, .cr_plain, .newline => {
                if (st.ctx == .env) {
                    p.row_gap = if (c == .cr) try p.crGap() else null;
                    p.sh.tag_seen = false;
                    return .cr;
                }
                if (c == .cr_plain) return p.failFmt("Misplaced {s}", .{cmd});
                if (c == .cr) _ = try p.crGap();
            },
            .hline, .hdashline => {
                if (st.ctx != .env or st.list.items.len != 0) return p.failFmt("Misplaced {s}", .{cmd});
                p.hlines +|= 1;
            },
            .ctlspace => try p.add(st, .{ .space = .{ .width = 0.25 } }),
            .ignore => {},
        }
        return null;
    }

    fn readEndName(p: *Parser, cmd: []const u8) Error![]const u8 {
        const name = std.mem.trim(u8, try p.rawText(cmd), " ");
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return p.failFmt("Invalid environment name '{s}'", .{name});
        if (tables.envs.get(name) == null and !p.sh.userenvs.contains(name)) return p.failFmt("Unknown environment '{s}'", .{name});
        return name;
    }

    fn nextBox(p: *Parser, cmd: []const u8) Error![]const Node {
        p.ex.skipSpaces();
        const t = try p.ex.next();
        switch (t.kind) {
            .eof, .close, .amp => return p.failFmt("Missing box for {s}", .{cmd}),
            .open => {
                try p.enter();
                defer p.leave();
                const r = try p.seq(.group);
                switch (r.stop) {
                    .close => {},
                    .eof => return p.fail("Extra open brace or missing close brace"),
                    else => |s| return p.stopError(s),
                }
                return r.nodes;
            },
            else => return p.unit(t),
        }
    }

    fn box1(p: *Parser, n: Node) Error![]const Node {
        const out = try p.a.alloc(Node, 1);
        out[0] = n;
        return out;
    }

    fn xarrow(p: *Parser, st: *State, cmd: []const u8, cp: u21) Error!void {
        const under = try p.optArg(cmd);
        const over = try p.arg(cmd);
        try p.add(st, .{ .xarrow = .{ .cp = cp, .over = over, .under = under } });
    }

    fn rootShift(p: *Parser, cmd: []const u8, up: bool) Error!void {
        if (!p.sh.in_root) return p.failFmt("{s} can appear only within a root", .{cmd});
        const slot = if (up) &p.sh.root_up else &p.sh.root_left;
        if (slot.* != null) return p.failFmt("Multiple use of {s}", .{cmd});
        const raw = try p.rawText(cmd);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            var j = i;
            if (raw[j] == '-') j += 1;
            const d0 = j;
            while (j < raw.len and std.ascii.isDigit(raw[j])) j += 1;
            if (j > d0) {
                const n = std.fmt.parseInt(i32, raw[i..j], 10) catch break;
                slot.* = @as(f32, @floatFromInt(n)) / 15.0;
                return;
            }
        }
        return p.failFmt("The argument to {s} must be an integer", .{cmd});
    }

    fn sqrtIndex(p: *Parser, index: ?[]const Node, body: []const Node) tree.Sqrt {
        const out: tree.Sqrt = .{ .body = body, .index = index, .up = p.sh.root_up orelse 0, .left = p.sh.root_left orelse 0 };
        p.sh.root_up = null;
        p.sh.root_left = null;
        return out;
    }

    noinline fn plainArray(p: *Parser, st: *State, cmd: []const u8, c: tables.Cmd) Error!void {
        var arr: tree.Array = .{ .kind = .matrix, .rows = &.{}, .cols = &.{} };
        switch (c) {
            .pmatrix_tex => {
                arr.kind = .pmatrix;
                arr.open = '(';
                arr.close = ')';
            },
            .cases_tex => {
                arr.kind = .cases;
                arr.open = '{';
                arr.col_align = .{ .l, .l };
                arr.row_gap = 0.1;
            },
            .eqalign => {
                arr.kind = .eqalign;
                arr.cell_style = .display;
                arr.col_align = .{ .r, .l };
                arr.col_gap = .{ 5.0 / 18.0, 5.0 / 18.0 };
                arr.row_gap = 0.5;
            },
            .displaylines => {
                arr.kind = .displaylines;
                arr.cell_style = .display;
                arr.row_gap = 0.5;
            },
            else => {},
        }
        var rows: std.ArrayList(tree.Row) = .empty;
        var trailing: u8 = 0;
        p.ex.skipSpaces();
        const t = try p.ex.next();
        switch (t.kind) {
            .eof => return p.failFmt("Missing argument for {s}", .{cmd}),
            .open => {
                try p.enter();
                defer p.leave();
                if (c == .cases_tex) {
                    try p.casesBody(&rows);
                } else try p.tableBody(null, &rows, &trailing);
            },
            else => {
                const cell = try p.unit(t);
                const cells = try p.a.alloc(tree.Cell, 1);
                cells[0] = cell;
                try rows.append(p.a, .{ .cells = cells });
            },
        }
        arr.rows = rows.items;
        arr.trailing_hlines = trailing;
        try p.add(st, .{ .array = arr });
    }

    noinline fn tableBody(p: *Parser, name: ?[]const u8, rows: *std.ArrayList(tree.Row), trailing: *u8) Error!void {
        const saved_h = p.hlines;
        defer p.hlines = saved_h;
        var cells: std.ArrayList(tree.Cell) = .empty;
        var cell_total: usize = 0;
        var row_hlines: u8 = 0;
        while (true) {
            p.hlines = 0;
            p.row_gap = null;
            const r = try p.seq(.env);
            if (cells.items.len == 0) row_hlines = p.hlines;
            switch (r.stop) {
                .amp => try p.addCell(&cells, r.nodes, &cell_total),
                .cr => {
                    try p.addCell(&cells, r.nodes, &cell_total);
                    try rows.append(p.a, .{ .cells = try p.a.dupe(tree.Cell, cells.items), .hlines_before = row_hlines, .gap_after = p.row_gap orelse 0 });
                    cells.clearRetainingCapacity();
                },
                .end, .close => {
                    const by_end = r.stop == .end;
                    if (name) |n| {
                        if (!by_end) return p.stopError(.close);
                        if (!std.mem.eql(u8, p.end_name, n)) return p.failFmt("\\begin{{{s}}} ended with \\end{{{s}}}", .{ n, p.end_name });
                    } else if (by_end) return p.stopError(.end);
                    if (r.nodes.len > 0 or cells.items.len > 0) {
                        try p.addCell(&cells, r.nodes, &cell_total);
                        try rows.append(p.a, .{ .cells = try p.a.dupe(tree.Cell, cells.items), .hlines_before = row_hlines });
                    } else trailing.* = row_hlines;
                    return;
                },
                .eof => {
                    if (name) |n| return p.failFmt("Missing \\end{{{s}}}", .{n});
                    return p.fail("Missing close brace");
                },
                else => |s| return p.stopError(s),
            }
        }
    }

    fn upToChar(p: *Parser, cmd: []const u8, ch: u21) Error![]const Token {
        var out: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        p.ex.skipSpaces();
        while (p.ex.raw()) |t| {
            switch (t.kind) {
                .open => depth += 1,
                .close => {
                    if (depth == 0) return p.failFmt("Extra close brace while looking for {u}", .{ch});
                    depth -= 1;
                },
                else => {},
            }
            if (depth == 0 and t.isChar(ch)) return out.items;
            try out.append(p.a, t);
        }
        return p.failFmt("Could not find {u} for {s}", .{ ch, cmd });
    }

    fn cdArrowStart(p: *Parser) Error!?Stop {
        const n = p.ex.peekRaw() orelse return null;
        if (n.kind != .char or std.mem.indexOfScalar(u8, "><VA.|=", if (n.cp < 128) @as(u8, @intCast(n.cp)) else 0) == null) return null;
        _ = p.ex.raw();
        const ch: u8 = @intCast(n.cp);
        var arrow: CdArrow = .{ .c = ch, .a = &.{}, .b = &.{} };
        if (ch == '>' or ch == '<' or ch == 'V' or ch == 'A') {
            arrow.a = try p.upToChar("", ch);
            arrow.b = try p.upToChar("", ch);
        }
        p.cd_arrow = arrow;
        return .at;
    }

    fn cdArrowNode(p: *Parser, arrow: CdArrow) Error!?Node {
        const minw = p.cd_minw;
        switch (arrow.c) {
            '.' => return null,
            '|' => return .{ .varrow = .{ .cp = 0x2225, .left = &.{}, .right = &.{} } },
            '=' => return .{ .xarrow = .{ .cp = '=', .over = try p.box1(.{ .space = .{ .width = minw } }), .under = null } },
            '>', '<' => {
                const over: []const Node = if (arrow.a.len == 0) try p.box1(.{ .space = .{ .width = minw } }) else try p.subParse(arrow.a);
                const under: ?[]const Node = if (arrow.b.len == 0) null else try p.subParse(arrow.b);
                return .{ .xarrow = .{ .cp = if (arrow.c == '>') 0x2192 else 0x2190, .over = over, .under = under } };
            },
            else => return .{ .varrow = .{
                .cp = if (arrow.c == 'V') 0x2193 else 0x2191,
                .left = try p.subParse(arrow.a),
                .right = try p.subParse(arrow.b),
            } },
        }
    }

    noinline fn cdBody(p: *Parser, rows: *std.ArrayList(tree.Row), trailing: *u8) Error!void {
        var cells: std.ArrayList(tree.Cell) = .empty;
        var cell_total: usize = 0;
        while (true) {
            p.hlines = 0;
            p.row_gap = null;
            const r = try p.seq(.env);
            switch (r.stop) {
                .amp => try p.addCell(&cells, r.nodes, &cell_total),
                .cr => {
                    try p.addCell(&cells, r.nodes, &cell_total);
                    try rows.append(p.a, .{ .cells = try p.a.dupe(tree.Cell, cells.items), .gap_after = p.row_gap orelse 0 });
                    cells.clearRetainingCapacity();
                },
                .at => {
                    if (r.nodes.len > 0) try p.addCell(&cells, r.nodes, &cell_total);
                    const arrow_row = rows.items.len % 2 == 1;
                    var pad = (cells.items.len + @as(usize, if (arrow_row) 0 else 1)) % 2;
                    while (pad > 0) : (pad -= 1) try p.addCell(&cells, &.{}, &cell_total);
                    const node = try p.cdArrowNode(p.cd_arrow.?);
                    const cell: []const Node = if (node) |nd| try p.box1(nd) else &.{};
                    try p.addCell(&cells, cell, &cell_total);
                },
                .end => {
                    if (!std.mem.eql(u8, p.end_name, "CD")) return p.failFmt("\\begin{{CD}} ended with \\end{{{s}}}", .{p.end_name});
                    if (r.nodes.len > 0 or cells.items.len > 0) {
                        try p.addCell(&cells, r.nodes, &cell_total);
                        try rows.append(p.a, .{ .cells = try p.a.dupe(tree.Cell, cells.items) });
                    }
                    trailing.* = 0;
                    return;
                },
                .eof => return p.fail("Missing \\end{CD}"),
                else => |s| return p.stopError(s),
            }
        }
    }

    fn paddedContent(p: *Parser, raw: []const u8) Error!Node {
        const text = std.mem.trim(u8, raw, " ");
        if (text.len == 0) return emptyGroup();
        const inner = try p.internalMath(text, .default);
        const pad: Node = .{ .space = .{ .width = 0.2155 } };
        const body = try p.a.alloc(Node, inner.len + 2);
        body[0] = pad;
        @memcpy(body[1 .. 1 + inner.len], inner);
        body[body.len - 1] = pad;
        return .{ .style = .{ .style = .text, .body = body } };
    }

    fn fcenterLine(p: *Parser, cmd: []const u8) Error!Node {
        p.ex.skipSpaces();
        const d = try p.ex.next();
        if (d.kind != .dollar) return p.failFmt("Use of {s} does not match it's definition.", .{cmd});
        var toks: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        var found = false;
        while (p.ex.raw()) |t| {
            switch (t.kind) {
                .open => depth += 1,
                .close => {
                    if (depth == 0) return p.fail("Extra close brace while looking for $");
                    depth -= 1;
                },
                else => {},
            }
            if (depth == 0 and t.kind == .dollar) {
                found = true;
                break;
            }
            try toks.append(p.a, t);
        }
        if (!found) return p.failFmt("Could not find $ for {s}", .{cmd});
        var split: ?usize = null;
        depth = 0;
        for (toks.items, 0..) |t, i| {
            if (t.kind == .open) depth += 1;
            if (t.kind == .close and depth > 0) depth -= 1;
            if (depth == 0 and t.isCs("fCenter")) {
                split = i;
                break;
            }
        }
        const at = split orelse return p.failFmt("Missing \\fCenter in {s}.", .{cmd});
        const prem = try p.subParse(toks.items[0..at]);
        const conc = try p.subParse(toks.items[at + 1 ..]);
        var body: std.ArrayList(Node) = .empty;
        try body.appendSlice(p.a, prem);
        try body.append(p.a, .{ .space = .{ .width = 0.2155 } });
        try body.append(p.a, .{ .atom = .{ .class = .rel, .cp = 0x22a2 } });
        try body.append(p.a, .{ .space = .{ .width = 0.2155 } });
        try body.appendSlice(p.a, conc);
        return .{ .group = .{ .body = body.items } };
    }

    noinline fn proofBody(p: *Parser) Error!Node {
        var stack: std.ArrayList(Node) = .empty;
        var prefix: std.ArrayList(Node) = .empty;
        var left: ?Node = null;
        var right: ?Node = null;
        var line: tables.ProofLine = .solid;
        var cur: tables.ProofLine = .solid;
        var root_top = false;
        while (true) {
            const t = try p.ex.next();
            if (t.kind == .eof) return p.fail("Missing \\end{prooftree}");
            if (t.kind == .space) continue;
            if (t.kind == .cs and t.isCs("end")) {
                const name = try p.readEndName(t.text);
                if (std.mem.eql(u8, name, "prooftree")) break;
                p.end_name = name;
                return p.stopError(.end);
            }
            const pc = if (t.kind == .cs) tables.proofCmd(t.name()) else null;
            if (pc == null) {
                var st: State = .{ .ctx = .arg };
                if (try p.token(&st, t)) |s| return p.stopError(s);
                try prefix.appendSlice(p.a, try p.finish(&st));
                continue;
            }
            const cmd = t.text;
            switch (pc.?) {
                .axiom => try stack.append(p.a, try p.paddedContent(try p.rawText(cmd))),
                .axiom_f => try stack.append(p.a, try p.fcenterLine(cmd)),
                .inference, .inference_f => {
                    const n: usize = switch (pc.?) {
                        .inference => |k| k,
                        .inference_f => |k| k,
                        else => 0,
                    };
                    if (stack.items.len < n) return p.fail("Proof tree badly specified.");
                    const prem = try p.a.dupe(Node, stack.items[stack.items.len - n ..]);
                    stack.shrinkRetainingCapacity(stack.items.len - n);
                    const empty_axiom = n == 1 and prem[0] == .group and prem[0].group.body.len == 0;
                    const conclusion = if (pc.? == .inference) try p.paddedContent(try p.rawText(cmd)) else try p.fcenterLine(cmd);
                    const style = cur;
                    cur = line;
                    var above: std.ArrayList(Node) = .empty;
                    if (!empty_axiom) for (prem, 0..) |pn, i| {
                        if (i > 0) try above.append(p.a, .{ .space = .{ .width = 0.8 } });
                        try above.append(p.a, pn);
                    };
                    const concl = try p.box1(conclusion);
                    const frac: tree.Frac = .{
                        .num = if (root_top) concl else above.items,
                        .den = if (root_top) above.items else concl,
                        .thickness = if (style == .none) 0 else null,
                    };
                    var pieces: std.ArrayList(Node) = .empty;
                    if (left) |l| {
                        try pieces.append(p.a, l);
                        try pieces.append(p.a, .{ .space = .{ .width = 0.25 } });
                    }
                    try pieces.append(p.a, .{ .frac = frac });
                    if (right) |r| {
                        try pieces.append(p.a, .{ .space = .{ .width = 0.25 } });
                        try pieces.append(p.a, r);
                    }
                    left = null;
                    right = null;
                    try stack.append(p.a, .{ .group = .{ .body = pieces.items } });
                },
                .label_left, .label_right => {
                    const nodes = try p.internalMath(try p.rawText(cmd), .default);
                    const label: Node = .{ .group = .{ .body = nodes } };
                    if (pc.? == .label_left) left = label else right = label;
                },
                .line => |l| {
                    cur = l.style;
                    if (l.always) line = l.style;
                },
                .root_top => |v| root_top = v,
                .fcenter => {},
            }
        }
        try prefix.appendSlice(p.a, stack.items);
        return .{ .group = .{ .body = prefix.items } };
    }

    noinline fn userEnv(p: *Parser, name: []const u8, ue: macros.UserEnv) Error!Node {
        const begin_cs = "\\begin";
        const args = try p.a.alloc([]const Token, ue.nargs);
        var first: usize = 0;
        if (ue.nargs > 0) if (ue.default) |d| {
            args[0] = (try p.ex.readBrackets(begin_cs)) orelse d;
            first = 1;
        };
        for (first..ue.nargs) |i| args[i] = try p.ex.readArg(begin_cs);
        const bdef = if (ue.nargs == 0) ue.begin else try p.ex.substitute(.{ .nargs = ue.nargs, .default = null, .body = ue.begin }, args);
        const edef = if (ue.nargs == 0) ue.end else try p.ex.substitute(.{ .nargs = 0, .default = null, .body = ue.end }, &.{});
        try p.sh.user_frames.append(p.a, .{ .name = name, .edef = edef });
        try p.ex.pushFront(bdef);
        const r = try p.seq(.eqn);
        switch (r.stop) {
            .end => if (!std.mem.eql(u8, p.end_name, name)) {
                return p.failFmt("\\begin{{{s}}} ended with \\end{{{s}}}", .{ name, p.end_name });
            },
            .eof => return p.failFmt("Missing \\end{{{s}}}", .{name}),
            else => |s| return p.stopError(s),
        }
        return .{ .group = .{ .body = r.nodes } };
    }

    noinline fn bboxCmd(p: *Parser, st: *State, cmd: []const u8) Error!void {
        const opts = try p.optRaw(cmd);
        const body = try p.arg(cmd);
        var pad: ?f32 = null;
        var background: ?[]const u8 = null;
        var css: ?[]const u8 = null;
        var parts = std.mem.splitScalar(u8, opts, ',');
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " ");
            if (part.len == 0) continue;
            if (padding(part)) |v| {
                if (pad != null) return p.failFmt("{s} specified twice in {s}", .{ "Padding", cmd });
                pad = v;
            } else if (looksLikeColor(part)) {
                if (background != null) return p.failFmt("{s} specified twice in {s}", .{ "Background", cmd });
                background = part;
            } else if (looksLikeStyle(part)) {
                if (css != null) return p.failFmt("{s} specified twice in {s}", .{ "Style", cmd });
                css = part;
            } else return p.failFmt("\"{s}\" doesn't look like a color, a padding dimension, or a style", .{part});
        }
        var props: CssProps = if (css) |c| try p.parseCss(c) else .{};
        if (background) |bg| props.bg = try p.colorFrom("", bg);
        try p.add(st, try p.assemble(props, body, pad orelse 0));
    }

    const CssProps = struct {
        fg: ?tree.Color = null,
        bg: ?tree.Color = null,
        border: bool = false,
        border_color: ?tree.Color = null,
        border_width: ?f32 = null,
    };

    /// The part of a CSS declaration list that can be drawn: color, background, border.
    noinline fn parseCss(p: *Parser, css: []const u8) Error!CssProps {
        var props: CssProps = .{};
        var decls = std.mem.splitScalar(u8, css, ';');
        while (decls.next()) |d| {
            const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            const key = std.mem.trim(u8, d[0..colon], " ");
            const val = std.mem.trim(u8, d[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(key, "color")) {
                props.fg = tables.namedColor(val);
            } else if (std.ascii.eqlIgnoreCase(key, "background") or std.ascii.eqlIgnoreCase(key, "background-color")) {
                var it = std.mem.tokenizeScalar(u8, val, ' ');
                if (it.next()) |first| props.bg = tables.namedColor(first);
            } else if (std.ascii.eqlIgnoreCase(key, "border-color")) {
                props.border_color = tables.namedColor(val);
            } else if (std.ascii.eqlIgnoreCase(key, "border")) {
                var it = std.mem.tokenizeScalar(u8, val, ' ');
                props.border = true;
                while (it.next()) |tok| {
                    if (std.ascii.eqlIgnoreCase(tok, "none") or std.ascii.eqlIgnoreCase(tok, "hidden")) {
                        props.border = false;
                    } else if (tables.matchDimen(tok, false)) |dim| {
                        props.border_width = dim.value;
                    } else if (isBorderStyle(tok)) {
                        continue;
                    } else props.border_color = tables.namedColor(tok);
                }
            }
        }
        _ = p;
        return props;
    }

    fn isBorderStyle(s: []const u8) bool {
        const styles = [_][]const u8{ "solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset" };
        for (styles) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
        return false;
    }

    noinline fn assemble(p: *Parser, props: CssProps, body: []const Node, pad: f32) Error!Node {
        const inner: []const Node = if (props.fg) |c| try p.box1(.{ .color = .{ .color = c, .body = body } }) else body;
        if (props.bg == null and !props.border and pad == 0) return .{ .group = .{ .body = inner } };
        return .{ .enclose = .{
            .body = inner,
            .border = props.border,
            .bg = props.bg,
            .border_color = props.border_color,
            .border_width = props.border_width,
            .padding = pad,
        } };
    }

    fn casesText(p: *Parser) Error![]const Node {
        var toks: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        while (p.ex.raw()) |t| {
            if (depth == 0) {
                if (t.kind == .amp) return p.fail("Extra alignment tab in \\cases text");
                if (t.kind == .close or (t.kind == .cs and (t.isCs("cr") or t.isCs("\\")))) {
                    p.ex.unread(t);
                    break;
                }
            }
            switch (t.kind) {
                .open => depth += 1,
                .close => depth -= 1,
                else => {},
            }
            try toks.append(p.a, t);
        }
        var start: usize = 0;
        while (start < toks.items.len and toks.items[start].kind == .space) start += 1;
        const rest = toks.items[start..];
        if (rest.len >= 3 and rest[0].isCs("text") and onlyOneGroup(rest[1..])) return p.subParse(rest);
        const text = std.mem.trim(u8, try macros.textOf(p.a, toks.items), " ");
        return p.box1(.{ .style = .{ .style = .text, .body = try p.internalMath(text, .default) } });
    }

    fn onlyOneGroup(toks: []const Token) bool {
        var i: usize = 0;
        while (i < toks.len and toks[i].kind == .space) i += 1;
        if (i >= toks.len or toks[i].kind != .open) return false;
        var depth: u32 = 0;
        while (i < toks.len) : (i += 1) {
            switch (toks[i].kind) {
                .open => depth += 1,
                .close => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        i += 1;
        while (i < toks.len and toks[i].kind == .space) i += 1;
        return i >= toks.len;
    }

    noinline fn casesBody(p: *Parser, rows: *std.ArrayList(tree.Row)) Error!void {
        var cell_total: usize = 0;
        while (true) {
            p.hlines = 0;
            p.row_gap = null;
            const first = try p.seq(.env);
            var cells: std.ArrayList(tree.Cell) = .empty;
            try p.addCell(&cells, first.nodes, &cell_total);
            var gap: f32 = 0;
            var done_all = false;
            switch (first.stop) {
                .cr => gap = p.row_gap orelse 0,
                .close => done_all = true,
                .amp => {
                    try p.addCell(&cells, try p.casesText(), &cell_total);
                    const t = p.ex.raw() orelse return p.fail("Missing close brace");
                    if (t.kind == .close) {
                        done_all = true;
                    } else if (t.isCs("\\")) gap = (try p.crGap()) orelse 0;
                },
                .eof => return p.fail("Missing close brace"),
                else => |s| return p.stopError(s),
            }
            if (!done_all or first.nodes.len > 0 or cells.items.len > 1) {
                try rows.append(p.a, .{ .cells = try p.a.dupe(tree.Cell, cells.items), .gap_after = gap });
            }
            if (done_all) return;
        }
    }

    fn padding(s: []const u8) ?f32 {
        const units = [_][]const u8{ "pt", "em", "ex", "mu", "px", "in", "cm", "mm" };
        for (units) |u| {
            if (!std.mem.endsWith(u8, s, u)) continue;
            const num = s[0 .. s.len - u.len];
            if (num.len == 0) return null;
            var dots: usize = 0;
            var digits: usize = 0;
            for (num) |ch| {
                if (ch == '.') dots += 1 else if (std.ascii.isDigit(ch)) digits += 1 else return null;
            }
            if (dots > 1 or digits == 0) return null;
            const d = tables.matchDimen(s, false) orelse return null;
            return d.value;
        }
        return null;
    }

    fn looksLikeColor(s: []const u8) bool {
        if (s.len > 0 and s[0] == '#') {
            if (s.len != 4 and s.len != 7) return false;
            for (s[1..]) |ch| if (!std.ascii.isHex(ch)) return false;
            return true;
        }
        for (s) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
        return s.len > 0;
    }

    fn looksLikeStyle(s: []const u8) bool {
        var i: usize = 0;
        while (i < s.len and (std.ascii.isAlphabetic(s[i]) or s[i] == '-')) i += 1;
        return i > 0 and i < s.len and s[i] == ':';
    }

    noinline fn encloseCmd(p: *Parser, st: *State, cmd: []const u8) Error!void {
        const raw = try p.rawText(cmd);
        _ = try p.ex.readBrackets(cmd);
        const body = try p.arg(cmd);
        var n: tree.Notation = .{};
        var words = std.mem.tokenizeAny(u8, raw, ", ");
        while (words.next()) |w| {
            inline for (@typeInfo(tree.Notation).@"struct".field_names) |f| {
                if (std.mem.eql(u8, f, w)) @field(n, f) = true;
            }
        }
        try p.add(st, .{ .enclose = .{ .body = body, .border = n.box, .notation = n } });
    }

    noinline fn braketCmd(p: *Parser, st: *State, cmd: []const u8, is_set: bool, stretchy: bool) Error!void {
        p.ex.skipSpaces();
        const first = try p.ex.next();
        if (first.kind == .eof) return p.failFmt("Missing argument for {s}", .{cmd});
        var toks: []const Token = &.{};
        if (first.kind == .open) {
            p.ex.unread(first);
            toks = try p.ex.readArg(cmd);
        } else {
            const single = try p.a.alloc(Token, 1);
            single[0] = first;
            toks = single;
        }
        var body: std.ArrayList(Node) = .empty;
        var seg_start: usize = 0;
        var depth: u32 = 0;
        var bars: u32 = 0;
        const barmax: u32 = if (is_set) 1 else std.math.maxInt(u32);
        var i: usize = 0;
        while (i <= toks.len) : (i += 1) {
            const at_end = i == toks.len;
            if (!at_end) {
                switch (toks[i].kind) {
                    .open => depth += 1,
                    .close => if (depth > 0) {
                        depth -= 1;
                    },
                    else => {},
                }
            }
            const is_bar = !at_end and depth == 0 and toks[i].isChar('|') and bars < barmax;
            if (!at_end and !is_bar) continue;
            try body.appendSlice(p.a, try p.subParse(toks[seg_start..i]));
            if (at_end) break;
            bars += 1;
            var cp: u21 = '|';
            var j = i + 1;
            while (j < toks.len and toks[j].kind == .space) j += 1;
            if (j < toks.len and toks[j].isChar('|')) {
                cp = 0x2225;
                i = j;
            }
            if (stretchy) {
                try body.append(p.a, .{ .middle = cp });
            } else try body.append(p.a, .{ .atom = .{ .class = .ord, .cp = cp } });
            seg_start = i + 1;
        }
        const open: u21 = if (is_set) '{' else 0x27e8;
        const close: u21 = if (is_set) '}' else 0x27e9;
        if (stretchy) {
            try p.add(st, .{ .fenced = .{ .open = open, .close = close, .body = body.items } });
        } else {
            var all: std.ArrayList(Node) = .empty;
            try all.append(p.a, .{ .atom = .{ .class = .open, .cp = open } });
            try all.appendSlice(p.a, body.items);
            try all.append(p.a, .{ .atom = .{ .class = .close, .cp = close } });
            try p.add(st, .{ .group = .{ .body = all.items, .class = .inner } });
        }
    }

    noinline fn mmlToken(p: *Parser, st: *State, cmd: []const u8) Error!void {
        const kind = try p.rawText(cmd);
        var attr = std.mem.trimStart(u8, try p.optRaw(cmd), " ");
        const text = try p.rawText(cmd);
        const kinds = [_][]const u8{ "mi", "mn", "mo", "mtext", "ms" };
        var known = false;
        for (kinds) |k| known = known or std.mem.eql(u8, k, kind);
        if (!known) return p.failFmt("{s} is not a token element", .{kind});
        while (attr.len > 0) {
            var i: usize = 0;
            while (i < attr.len and std.ascii.isAlphabetic(attr[i])) i += 1;
            const key = attr[0..i];
            var j = i;
            while (j < attr.len and attr[j] == ' ') j += 1;
            if (key.len == 0 or j >= attr.len or attr[j] != '=') return p.failFmt("Invalid MathML attribute: {s}", .{attr});
            j += 1;
            while (j < attr.len and attr[j] == ' ') j += 1;
            if (j < attr.len and (attr[j] == '\'' or attr[j] == '"')) {
                const q = attr[j];
                const e = std.mem.indexOfScalarPos(u8, attr, j + 1, q) orelse return p.failFmt("Invalid MathML attribute: {s}", .{attr});
                j = e + 1;
            } else while (j < attr.len and attr[j] != ' ' and attr[j] != ',') j += 1;
            if (!tables.mmlAttrAllowed(kind, key)) return p.failFmt("{s} is not a recognized attribute for {s}", .{ key, kind });
            while (j < attr.len and attr[j] == ' ') j += 1;
            if (j < attr.len and attr[j] == ',') j += 1;
            while (j < attr.len and attr[j] == ' ') j += 1;
            attr = attr[j..];
        }
        const view = std.unicode.Utf8View.init(text) catch return p.fail("Invalid MathML attribute: invalid text");
        var it = view.iterator();
        var cps: std.ArrayList(u21) = .empty;
        while (it.nextCodepoint()) |cp| try cps.append(p.a, cp);
        if (std.mem.eql(u8, kind, "mn")) return p.add(st, .{ .number = text });
        if (std.mem.eql(u8, kind, "mtext")) return p.add(st, .{ .text = .{ .str = text } });
        if (std.mem.eql(u8, kind, "ms")) return p.add(st, .{ .text = .{ .str = try std.fmt.allocPrint(p.a, "\"{s}\"", .{text}) } });
        if (cps.items.len == 1) return p.add(st, atomFor(cps.items[0], text));
        var body: std.ArrayList(Node) = .empty;
        for (cps.items) |cp| try body.append(p.a, .{ .atom = .{ .class = .ord, .cp = cp } });
        try p.add(st, .{ .group = .{ .body = body.items } });
    }

    noinline fn unicodeCmd(p: *Parser, st: *State, cmd: []const u8) Error!void {
        if (try p.ex.readBrackets(cmd)) |hd| {
            const s = try macros.textOf(p.a, hd);
            var compact: std.ArrayList(u8) = .empty;
            for (s) |ch| if (ch != ' ') try compact.append(p.a, ch);
            if (std.mem.indexOfScalar(u8, compact.items, ',') != null) _ = try p.ex.readBrackets(cmd);
        }
        var n = std.mem.trim(u8, try p.rawText(cmd), " ");
        if (std.mem.startsWith(u8, n, "0x")) n = n[1..];
        const hex = n.len > 1 and n[0] == 'x';
        const digits = if (hex) n[1..] else n;
        var ok = digits.len > 0;
        for (digits) |ch| ok = ok and (if (hex) std.ascii.isHex(ch) else std.ascii.isDigit(ch));
        if (!ok) return p.fail("Argument to \\unicode must be a number");
        const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch 0xfffd;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch blk: {
            break :blk std.unicode.utf8Encode(0xfffd, &buf) catch 0;
        };
        try p.add(st, .{ .text = .{ .str = try p.a.dupe(u8, buf[0..len]) } });
    }

    noinline fn verbCmd(p: *Parser, st: *State, cmd: []const u8) Error!void {
        p.ex.skipSpaces();
        const d = p.ex.raw() orelse return p.failFmt("Missing argument for {s}", .{cmd});
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const t = p.ex.raw() orelse return p.failFmt("Can't find closing delimiter for {s}", .{cmd});
            if (t.kind == d.kind and std.mem.eql(u8, t.text, d.text)) break;
            if (t.kind == .space or (t.kind == .char and t.cp == ' ')) {
                try out.appendSlice(p.a, "\u{a0}");
            } else try out.appendSlice(p.a, t.text);
        }
        try p.add(st, .{ .text = .{ .str = out.items, .font = .tt } });
    }

    noinline fn newExtArrow(p: *Parser, cmd: []const u8) Error!void {
        const cs_raw = try p.rawText(cmd);
        const space = try p.rawText(cmd);
        const chr = try p.rawText(cmd);
        var valid = cs_raw.len >= 2 and cs_raw[0] == '\\';
        if (valid) {
            const rest = cs_raw[1..];
            var letters = true;
            for (rest) |ch| letters = letters and std.ascii.isAlphabetic(ch);
            const single = (std.unicode.utf8ByteSequenceLength(rest[0]) catch 0) == rest.len;
            valid = letters or single;
        }
        if (!valid) return p.failFmt("First argument to {s} must be a control sequence name", .{cmd});
        const comma = std.mem.indexOfScalar(u8, space, ',');
        var two = comma != null and comma.? > 0 and comma.? + 1 < space.len;
        if (two) for (space, 0..) |ch, i| {
            if (i != comma.? and !std.ascii.isDigit(ch)) two = false;
        };
        if (!two) return p.failFmt("Second argument to {s} must be two integers separated by a comma", .{cmd});
        var cp: u32 = 0;
        var cok = chr.len > 0;
        if (std.ascii.startsWithIgnoreCase(chr, "0x") and chr.len > 2) {
            cp = std.fmt.parseInt(u32, chr[2..], 16) catch blk: {
                cok = false;
                break :blk 0;
            };
        } else {
            for (chr) |ch| cok = cok and std.ascii.isDigit(ch);
            if (cok) cp = std.fmt.parseInt(u32, chr, 10) catch blk: {
                cok = false;
                break :blk 0;
            };
        }
        if (!cok) return p.failFmt("Third argument to {s} must be a unicode character number", .{cmd});
        const body = try std.fmt.allocPrint(p.a, "\\xarrowcp{{{d}}}", .{cp});
        try p.sh.defs.put(p.a, cs_raw[1..], .{ .macro = .{ .nargs = 0, .default = null, .body = try p.lex(body) } });
    }

    noinline fn declareOp(p: *Parser, cmd: []const u8) Error!void {
        p.ex.skipSpaces();
        var star = false;
        if (p.ex.peekRaw()) |n| if (n.isChar('*')) {
            _ = p.ex.raw();
            star = true;
        };
        var name = std.mem.trim(u8, try p.rawText(cmd), " ");
        if (name.len > 0 and name[0] == '\\') name = name[1..];
        const op = try p.rawText(cmd);
        const body = try std.fmt.allocPrint(p.a, "\\operatorname{s}{{{s}}}", .{ if (star) "*" else "", op });
        try p.sh.defs.put(p.a, name, .{ .macro = .{ .nargs = 0, .default = null, .body = try p.lex(body) } });
    }

    noinline fn sideSet(p: *Parser, st: *State, cmd: []const u8) Error!void {
        const pre = try p.arg(cmd);
        const post = try p.arg(cmd);
        const base = try p.arg(cmd);
        var ms: tree.Multiscripts = .{ .base = base };
        if (scriptsOnly(pre)) |s| {
            ms.pre_sub = s.sub;
            ms.pre_sup = s.sup;
        }
        if (scriptsOnly(post)) |s| {
            ms.post_sub = s.sub;
            ms.post_sup = s.sup;
        }
        const out = try p.box1(.{ .multiscripts = ms });
        try p.add(st, .{ .group = .{ .body = out, .class = .op } });
    }

    fn scriptsOnly(nodes: []const Node) ?tree.SupSub {
        if (nodes.len != 1 or nodes[0] != .supsub) return null;
        const b = nodes[0].supsub.base.*;
        if (b != .group or b.group.body.len != 0) return null;
        return nodes[0].supsub;
    }

    noinline fn chemCmd(p: *Parser, cmd: []const u8, is_pu: bool) Error!void {
        const raw = try p.rawText(cmd);
        if (raw.len > 4096) return p.fail("mhchem expression is too large");
        var err: ?[]const u8 = null;
        const tex = (try mhchem.toTex(p.a, raw, if (is_pu) "pu" else "ce", &err)) orelse return p.fail(err orelse "mhchem bug U. Please report.");
        try p.ex.pushFront(try p.lex(tex));
    }

    fn crGap(p: *Parser) Error!?f32 {
        if (p.ex.peekRaw()) |n| if (n.isChar('*')) {
            _ = p.ex.raw();
        };
        const toks = (try p.ex.readBrackets("\\\\")) orelse return null;
        const s = try macros.textOf(p.a, toks);
        const r = tables.matchDimen(s, false) orelse return p.fail("Bracket argument to \\\\ must be a dimension");
        return r.value;
    }

    fn upTo(p: *Parser, cmd: []const u8, stop_name: []const u8) Error![]const Token {
        var out: std.ArrayList(Token) = .empty;
        var depth: u32 = 0;
        p.ex.skipSpaces();
        while (p.ex.raw()) |t| {
            switch (t.kind) {
                .open => depth += 1,
                .close => {
                    if (depth == 0) return p.failFmt("Extra close brace while looking for \\{s}", .{stop_name});
                    depth -= 1;
                },
                else => {},
            }
            if (depth == 0 and t.isCs(stop_name)) return out.items;
            try out.append(p.a, t);
        }
        return p.failFmt("Could not find \\{s} for {s}", .{ stop_name, cmd });
    }

    fn sqrt(p: *Parser, st: *State, cmd: []const u8) Error!void {
        p.sh.root_up = null;
        p.sh.root_left = null;
        const saved_root = p.sh.in_root;
        p.sh.in_root = true;
        const index = p.optArg(cmd) catch |e| {
            p.sh.in_root = saved_root;
            return e;
        };
        p.sh.in_root = saved_root;
        p.ex.skipSpaces();
        const first = p.ex.peekRaw() orelse return p.failFmt("Missing argument for {s}", .{cmd});
        if (first.isCs("frac")) {
            _ = p.ex.raw();
            const n = try p.ex.readArg("\\frac");
            const d = try p.ex.readArg("\\frac");
            const body = try p.a.alloc(Node, 1);
            body[0] = .{ .frac = .{ .num = try p.subParse(n), .den = try p.subParse(d) } };
            try p.add(st, .{ .sqrt = p.sqrtIndex(index, body) });
            return;
        }
        try p.add(st, .{ .sqrt = p.sqrtIndex(index, try p.arg(cmd)) });
    }

    fn fenced(p: *Parser, st: *State) Error!void {
        const open = try p.readDelimiter("\\left", false);
        try p.enter();
        defer p.leave();
        var body: std.ArrayList(Node) = .empty;
        var close: ?u21 = null;
        while (true) {
            const r = try p.seq(.left);
            try body.appendSlice(p.a, r.nodes);
            switch (r.stop) {
                .middle => {
                    const d = try p.readDelimiter("\\middle", false);
                    try body.append(p.a, .{ .middle = d });
                },
                .right => {
                    close = try p.readDelimiter("\\right", false);
                    break;
                },
                .eof => return p.fail("Extra \\left or missing \\right"),
                else => |s| return p.stopError(s),
            }
        }
        try p.add(st, .{ .fenced = .{ .open = open, .close = close, .body = body.items } });
    }

    fn setLimits(p: *Parser, st: *State, cmd: []const u8, above: bool) Error!void {
        if (st.list.items.len <= st.floor()) return p.failFmt("{s} is allowed only on operators", .{cmd});
        const last = &st.list.items[st.list.items.len - 1];
        const mode: Limits = if (above) .above else .side;
        switch (last.*) {
            .op => |*o| o.limits = mode,
            .supsub => |*s| {
                if (s.base.* != .op) return p.failFmt("{s} is allowed only on operators", .{cmd});
                var op = s.base.op;
                op.limits = mode;
                s.base = try p.alloc(.{ .op = op });
                s.limits = mode;
            },
            .stack => |*s| if (!s.brace) return p.failFmt("{s} is allowed only on operators", .{cmd}),
            else => return p.failFmt("{s} is allowed only on operators", .{cmd}),
        }
    }

    fn operatorName(p: *Parser, st: *State, cmd: []const u8) Error!void {
        p.ex.skipSpaces();
        var star = false;
        if (p.ex.peekRaw()) |n| if (n.isChar('*')) {
            _ = p.ex.raw();
            star = true;
        };
        const nodes = try p.arg(cmd);
        const fixed = try p.a.dupe(Node, nodes);
        for (fixed) |*n| {
            if (n.* == .atom and n.atom.class == .bin) {
                if (n.atom.cp == 0x2212) n.* = .{ .atom = .{ .class = .ord, .cp = '-' } };
                if (n.atom.cp == 0x2217) n.* = .{ .atom = .{ .class = .ord, .cp = '*' } };
            }
        }
        const body = try p.a.alloc(Node, 1);
        body[0] = .{ .font = .{ .font = .rm, .body = fixed } };
        try p.add(st, .{ .op = .{ .body = body, .limits = if (star) .display else .side, .large = false } });
    }

    fn colorFrom(p: *Parser, model_raw: []const u8, spec_raw: []const u8) Error!tree.Color {
        const model = std.mem.trim(u8, model_raw, " ");
        const spec_t = std.mem.trim(u8, spec_raw, " ");
        if (model.len == 0 or std.mem.eql(u8, model, "named")) {
            if (p.sh.colors.get(spec_t)) |c| return c;
            return tables.namedColor(spec_t);
        }
        var vals: [3]f64 = undefined;
        var n: usize = 0;
        const is_gray = std.mem.eql(u8, model, "gray");
        const is_rgb = std.mem.eql(u8, model, "rgb");
        const is_big = std.mem.eql(u8, model, "RGB");
        if (!is_gray and !is_rgb and !is_big) return p.failFmt("Color model '{s}' not defined", .{model});
        var parts = std.mem.splitScalar(u8, spec_t, ',');
        while (parts.next()) |part| {
            if (n == 3) {
                n += 1;
                break;
            }
            const s = std.mem.trim(u8, part, " ");
            if (is_big) {
                const v = std.fmt.parseInt(u32, s, 10) catch return p.fail("Invalid number");
                if (v > 255) return p.fail("Color values for the RGB model must be between 0 and 255");
                vals[n] = @floatFromInt(v);
            } else {
                if (s.len == 0 or !tables.isDecimal(s)) return p.fail("Invalid decimal number");
                const v = std.fmt.parseFloat(f64, s) catch return p.fail("Invalid decimal number");
                if (v < 0 or v > 1) return p.failFmt("Color values for the {s} model must be between 0 and 1", .{model});
                vals[n] = v * 255;
            }
            n += 1;
        }
        if (is_gray) {
            if (n != 1) return p.fail("Invalid decimal number");
            vals[1] = vals[0];
            vals[2] = vals[0];
        } else if (n != 3) return p.failFmt("Color values for the {s} model require 3 numbers", .{model});
        const r: u24 = @intFromFloat(@floor(vals[0]));
        const g: u24 = @intFromFloat(@floor(vals[1]));
        const b: u24 = @intFromFloat(@floor(vals[2]));
        const rgb = (r << 16) | (g << 8) | b;
        return .{ .name = try std.fmt.allocPrint(p.a, "#{x:0>6}", .{rgb}), .rgb = rgb };
    }

    fn begin(p: *Parser, st: *State) Error!void {
        const cmd = "\\begin";
        const name = std.mem.trim(u8, try p.rawText(cmd), " ");
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return p.failFmt("Invalid environment name '{s}'", .{name});
        p.sh.macro_count += 1;
        if (p.sh.macro_count > p.sh.caps.max_macros) {
            return p.fail("MathJax maximum substitution count exceeded; is there a recursive latex environment?");
        }
        if (p.sh.userenvs.get(name)) |ue| {
            try p.enter();
            defer p.leave();
            try p.add(st, try p.userEnv(name, ue));
            return;
        }
        const env = tables.envs.get(name) orelse return p.failFmt("Unknown environment '{s}'", .{name});
        const eqn_env = env.eqn;
        if (eqn_env) {
            if (p.sh.in_eqn) return p.fail("Erroneous nesting of equation structures");
            p.sh.in_eqn = true;
        }
        defer if (eqn_env) {
            p.sh.in_eqn = false;
        };
        try p.enter();
        defer p.leave();
        const node = try p.environment(name, env);
        try p.add(st, node);
    }

    fn environment(p: *Parser, name: []const u8, env: tables.EnvSpec) Error!Node {
        const full = try std.fmt.allocPrint(p.a, "\\begin{{{s}}}", .{name});
        const begin_cs = "\\begin";
        var arr: tree.Array = .{
            .kind = env.kind,
            .rows = &.{},
            .cols = &.{},
            .open = env.open,
            .close = env.close,
            .cell_style = env.style,
            .col_gap = env.col_gap,
            .row_gap = env.row_gap,
            .col_align = env.align_,
            .cols_repeat = env.repeat,
        };
        var cols: std.ArrayList(tree.Col) = .empty;
        var at_n: usize = 0;
        switch (env.arg) {
            .none => {},
            .bracket_cols => {
                _ = try p.ex.readBrackets(begin_cs);
                try p.colSpec(begin_cs, &cols, &arr);
            },
            .cols => try p.colSpec(begin_cs, &cols, &arr),
            .bracket => _ = try p.ex.readBrackets(begin_cs),
            .number => {
                if (env.bracket_first) _ = try p.ex.readBrackets(begin_cs);
                const s = std.mem.trim(u8, try p.rawText(begin_cs), " ");
                const bad = s.len == 0 or !std.ascii.isDigit(s[0]) or blk: {
                    for (s) |c| if (!std.ascii.isDigit(c)) break :blk true;
                    break :blk false;
                };
                if (bad) return p.failFmt("Argument to {s} must me a positive integer", .{full});
                at_n = std.fmt.parseInt(usize, s, 10) catch return p.failFmt("Argument to {s} must me a positive integer", .{full});
            },
        }
        if (env.plain) return p.plainEnv(name);
        if (env.proof) return p.proofBody();

        const saved_env = p.env_name;
        const saved_cd = p.in_cd;
        p.env_name = name;
        p.in_cd = env.kind == .cd;
        defer {
            p.env_name = saved_env;
            p.in_cd = saved_cd;
        }
        var rows: std.ArrayList(tree.Row) = .empty;
        var trailing: u8 = 0;
        if (env.kind == .cd) {
            try p.cdBody(&rows, &trailing);
        } else try p.tableBody(name, &rows, &trailing);
        arr.rows = rows.items;
        arr.trailing_hlines = trailing;
        if (env.kind == .multline) for (rows.items) |row| if (row.cells.len > 1) {
            return p.fail("The rows within the multline environment must have exactly one column");
        };
        if (env.pairs_check) for (rows.items) |row| if (row.cells.len > at_n * 2) {
            return p.failFmt("Extra & in row of {s}", .{name});
        };
        for (env.fixed) |al| try cols.append(p.a, .{ .align_ = al });
        if (cols.items.len > 0) arr.cols = cols.items;
        return .{ .array = arr };
    }

    fn addCell(p: *Parser, cells: *std.ArrayList(tree.Cell), nodes: []const Node, total: *usize) Error!void {
        total.* += 1;
        if (total.* > p.sh.caps.max_cells) return p.fail("Math expression is too large");
        try cells.append(p.a, nodes);
    }

    fn plainEnv(p: *Parser, name: []const u8) Error!Node {
        const r = try p.seq(.eqn);
        switch (r.stop) {
            .end => if (!std.mem.eql(u8, p.end_name, name)) {
                return p.failFmt("\\begin{{{s}}} ended with \\end{{{s}}}", .{ name, p.end_name });
            },
            .eof => return p.failFmt("Missing \\end{{{s}}}", .{name}),
            else => |s| return p.stopError(s),
        }
        return .{ .group = .{ .body = r.nodes } };
    }

    fn colSpec(p: *Parser, full: []const u8, cols: *std.ArrayList(tree.Col), arr: *tree.Array) Error!void {
        const raw = try p.rawText(full);
        var rules: u8 = 0;
        for (raw) |c| switch (c) {
            'c', 'l', 'r' => {
                try cols.append(p.a, .{ .align_ = switch (c) {
                    'l' => .l,
                    'r' => .r,
                    else => .c,
                }, .rules_before = rules });
                rules = 0;
            },
            '|', ':' => rules = 1,
            else => {},
        };
        arr.trailing_rules = rules;
    }
};

fn coreClass(n: Node) ?Class {
    return switch (n) {
        .atom => |a| a.class,
        .supsub => |s| coreClass(s.base.*),
        .group => |g| g.class,
        .op => .op,
        .font => |f| if (f.body.len > 0) coreClass(f.body[0]) else null,
        .color => |f| if (f.body.len > 0) coreClass(f.body[0]) else null,
        else => null,
    };
}

fn isKnown(name: []const u8) bool {
    if (denied.names.has(name)) return false;
    if (tables.specs.has(name)) return true;
    var buf: [96]u8 = undefined;
    if (name.len >= buf.len - 1) return false;
    buf[0] = '\\';
    @memcpy(buf[1 .. 1 + name.len], name);
    return symbols.lookupMath(buf[0 .. 1 + name.len]) != null or tables.extras.has(name);
}

/// Parses TeX math; a TeX error becomes a single `.parse_error` node (MathJax's message).
pub fn parse(alloc: Allocator, src: []const u8, caps: Caps) !Tree {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    var sh: Shared = .{ .a = a, .caps = caps, .known = isKnown };
    const root = parseInto(&sh, src) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Fail => blk: {
            const out = try a.alloc(Node, 1);
            out[0] = .{ .parse_error = sh.err orelse "Math parse error" };
            break :blk @as([]const Node, out);
        },
    };
    var err: ?[]const u8 = null;
    if (root.len == 1 and root[0] == .parse_error) err = root[0].parse_error;
    const span = if (sh.stack_hi >= sh.stack_lo) sh.stack_hi - sh.stack_lo else 0;
    return .{ .arena = arena, .root = root, .err = err, .stack_span = span };
}

fn parseInto(sh: *Shared, src: []const u8) Error![]const Node {
    if (src.len > sh.caps.max_source) return sh.fail("Math expression is too large");
    const trimmed = std.mem.trim(u8, src, " \t\n\r\x0b\x0c");
    const toks = lexer.tokenize(sh.a, trimmed, sh.caps.max_tokens) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyTokens => return sh.fail("MathJax internal buffer size exceeded; is there a recursive macro call?"),
    };
    var p: Parser = .{ .sh = sh, .a = sh.a, .ex = try macros.Expander.init(sh, toks) };
    const r = try p.seq(.top);
    if (r.stop != .eof) return p.stopError(r.stop);
    return r.nodes;
}

