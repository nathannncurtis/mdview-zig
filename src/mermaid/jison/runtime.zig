const std = @import("std");
const Allocator = std.mem.Allocator;
pub const regex = @import("regex.zig");

pub const Error = error{ Syntax, Semantic, OutOfMemory };

pub const eof_symbol: u16 = 1;
pub const error_symbol: u16 = 2;
pub const no_default: u16 = 0xFFFF;

pub const ActionKind = enum(u3) { shift, reduce, accept, go };

pub fn packEntry(kind: ActionKind, sym: u16, arg: u16) u32 {
    return (@as(u32, @backingInt(kind)) << 29) | (@as(u32, sym) << 16) | arg;
}

pub const Entry = struct {
    kind: ActionKind,
    sym: u16,
    arg: u16,

    pub fn unpack(v: u32) Entry {
        return .{ .kind = @fromBackingInt(@intCast(v >> 29)), .sym = @intCast((v >> 16) & 0x1FFF), .arg = @intCast(v & 0xFFFF) };
    }
};

pub const Loc = struct { first_line: usize = 1, last_line: usize = 1, first_column: usize = 0, last_column: usize = 0 };

pub const Diag = struct {
    message: []const u8 = "",

    pub fn deinit(self: *Diag, gpa: Allocator) void {
        gpa.free(self.message);
        self.message = "";
    }

    pub fn setOwned(self: *Diag, gpa: Allocator, msg: []const u8) void {
        gpa.free(self.message);
        self.message = msg;
    }

    pub fn fail(self: *Diag, gpa: Allocator, comptime fmt: []const u8, args: anytype) Error {
        self.setOwned(gpa, std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory);
        return error.Semantic;
    }
};

pub fn appendUtf8(gpa: Allocator, out: *std.ArrayList(u8), s: []const u16) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var cp: u21 = s[i];
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < s.len and s[i + 1] >= 0xDC00 and s[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch {
            try out.appendSlice(gpa, "�");
            continue;
        };
        try out.appendSlice(gpa, buf[0..n]);
    }
}

pub fn toUtf8(gpa: Allocator, s: []const u16) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendUtf8(gpa, &out, s);
    return out.toOwnedSlice(gpa);
}

pub fn toUtf16(gpa: Allocator, s: []const u8) Allocator.Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const cp: u21 = if (i + len <= s.len) (std.unicode.utf8Decode(s[i..][0..len]) catch 0xFFFD) else 0xFFFD;
        i += if (i + len <= s.len) len else 1;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try out.append(gpa, @intCast(0xD800 + (v >> 10)));
            try out.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
        } else try out.append(gpa, @intCast(cp));
    }
    return out.toOwnedSlice(gpa);
}

fn lastTerminatorLoc(m: []const u16) ?struct { start: usize, len: usize } {
    var i = m.len;
    while (i > 0) {
        i -= 1;
        if (m[i] == '\n') {
            return .{ .start = if (i > 0 and m[i - 1] == '\r') i - 1 else i, .len = if (i > 0 and m[i - 1] == '\r') 2 else 1 };
        }
        if (m[i] == '\r') return .{ .start = i, .len = 1 };
    }
    return null;
}

fn countLines(m: []const u16) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < m.len) : (i += 1) {
        if (m[i] == '\r') {
            n += 1;
            if (i + 1 < m.len and m[i + 1] == '\n') i += 1;
        } else if (m[i] == '\n') n += 1;
    }
    return n;
}

pub fn Lexer(comptime G: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        arena: std.heap.ArenaAllocator,
        diag: *Diag,
        rest: []const u16,
        matched: std.ArrayList(u16) = .empty,
        match: []const u16 = &.{},
        regexes: []const regex.Regex,
        matcher: regex.Matcher,
        cond_stack: std.ArrayList(u16) = .empty,
        yytext: []const u16 = &.{},
        yylineno: usize = 0,
        yylloc: Loc = .{},
        done: bool = false,

        const Shared = struct {
            var table: std.atomic.Value(?*const []const regex.Regex) = .init(null);

            fn get() (Allocator.Error || regex.Error)![]const regex.Regex {
                if (table.load(.acquire)) |t| return t.*;
                const pa = std.heap.page_allocator;
                var scratch = std.heap.ArenaAllocator.init(pa);
                defer scratch.deinit();
                const built = try pa.alloc(regex.Regex, G.lex_patterns.len);
                var made: usize = 0;
                errdefer {
                    for (built[0..made]) |*r| r.deinit();
                    pa.free(built);
                }
                for (G.lex_patterns, 0..) |p, k| {
                    const src = try std.fmt.allocPrint(scratch.allocator(), "^(?:{s})", .{p});
                    built[k] = try regex.Regex.compile(pa, src, G.lex_ignore_case);
                    made += 1;
                }
                const holder = try pa.create([]const regex.Regex);
                holder.* = built;
                if (table.cmpxchgStrong(null, holder, .acq_rel, .acquire)) |winner| {
                    for (built) |*r| r.deinit();
                    pa.free(built);
                    pa.destroy(holder);
                    return winner.?.*;
                }
                return built;
            }
        };

        pub fn init(gpa: Allocator, input: []const u16, diag: *Diag) (Allocator.Error || regex.Error)!Self {
            const regexes = try Shared.get();
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            var self: Self = .{ .gpa = gpa, .arena = arena, .diag = diag, .rest = input, .regexes = regexes, .matcher = regex.Matcher.init(gpa) };
            try self.cond_stack.append(gpa, @intCast(G.lex_conditions.len - 1));
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.matcher.deinit();
            self.matched.deinit(self.gpa);
            self.cond_stack.deinit(self.gpa);
            self.arena.deinit();
        }

        pub fn begin(self: *Self, cond: u16) Allocator.Error!void {
            try self.cond_stack.append(self.gpa, cond);
        }

        pub fn pushState(self: *Self, cond: u16) Allocator.Error!void {
            try self.begin(cond);
        }

        pub fn popState(self: *Self) void {
            if (self.cond_stack.items.len > 1) _ = self.cond_stack.pop();
        }

        pub fn topState(self: *const Self) u16 {
            return self.cond_stack.items[self.cond_stack.items.len - 1];
        }

        pub fn setYytext(self: *Self, s: []const u16) Allocator.Error!void {
            self.yytext = try self.arena.allocator().dupe(u16, s);
        }

        pub fn pastInput(self: *const Self, gpa: Allocator) Allocator.Error![]u16 {
            const past = self.matched.items[0 .. self.matched.items.len - self.match.len];
            var out: std.ArrayList(u16) = .empty;
            errdefer out.deinit(gpa);
            if (past.len > 20) try out.appendSlice(gpa, &.{ '.', '.', '.' });
            for (past[past.len -| 20..]) |c| if (c != '\n') try out.append(gpa, c);
            return out.toOwnedSlice(gpa);
        }

        pub fn upcomingInput(self: *const Self, gpa: Allocator) Allocator.Error![]u16 {
            var next_text: std.ArrayList(u16) = .empty;
            defer next_text.deinit(gpa);
            try next_text.appendSlice(gpa, self.match);
            if (next_text.items.len < 20) try next_text.appendSlice(gpa, self.rest[0..@min(20 - next_text.items.len, self.rest.len)]);
            const upcoming = next_text.items;
            var out: std.ArrayList(u16) = .empty;
            errdefer out.deinit(gpa);
            for (upcoming[0..@min(upcoming.len, 20)]) |c| if (c != '\n') try out.append(gpa, c);
            if (upcoming.len > 20) try out.appendSlice(gpa, &.{ 0x2E, 0x2E, 0x2E });
            return out.toOwnedSlice(gpa);
        }

        pub fn appendShowPosition(self: *const Self, out: *std.ArrayList(u8)) Allocator.Error!void {
            const pre = try self.pastInput(self.gpa);
            defer self.gpa.free(pre);
            const up = try self.upcomingInput(self.gpa);
            defer self.gpa.free(up);
            try appendUtf8(self.gpa, out, pre);
            try appendUtf8(self.gpa, out, up);
            try out.append(self.gpa, '\n');
            try out.appendNTimes(self.gpa, '-', pre.len);
            try out.append(self.gpa, '^');
        }

        fn lexicalError(self: *Self) Error {
            var msg: std.ArrayList(u8) = .empty;
            errdefer msg.deinit(self.gpa);
            msg.print(self.gpa, "Lexical error on line {d}. Unrecognized text.\n", .{self.yylineno + 1}) catch return error.OutOfMemory;
            self.appendShowPosition(&msg) catch return error.OutOfMemory;
            self.diag.setOwned(self.gpa, msg.toOwnedSlice(self.gpa) catch return error.OutOfMemory);
            return error.Syntax;
        }

        // jison's unput: puts text back in front of the input; match and matched lose one unit, not the text's length
        pub fn unput(self: *Self, ch: []const u16) Error!void {
            const a = self.arena.allocator();
            const old_lines = try splitLineLengths(a, self.match);
            const lines = try splitLineLengths(a, ch);
            const joined = try a.alloc(u16, ch.len + self.rest.len);
            @memcpy(joined[0..ch.len], ch);
            @memcpy(joined[ch.len..], self.rest);
            self.rest = joined;
            self.yytext = self.yytext[0..self.yytext.len -| ch.len];
            self.match = self.match[0..self.match.len -| 1];
            self.matched.shrinkRetainingCapacity(self.matched.items.len -| 1);
            self.yylineno -|= lines.len - 1;
            const idx = @as(isize, @intCast(old_lines.len)) - @as(isize, @intCast(lines.len));
            if (idx < 0) return self.diag.fail(self.gpa, "Cannot read properties of undefined (reading 'length')", .{});
            const base = if (lines.len == old_lines.len) self.yylloc.first_column else 0;
            self.yylloc = .{
                .first_line = self.yylloc.first_line,
                .last_line = self.yylineno + 1,
                .first_column = self.yylloc.first_column,
                .last_column = (base + old_lines[@intCast(idx)]) -| lines[0],
            };
        }

        pub fn less(self: *Self, n: usize) Error!void {
            try self.unput(self.match[@min(n, self.match.len)..]);
        }

        fn testMatch(self: *Self, len: usize, rule: u16, actions: anytype) Error!?u16 {
            const m = self.rest[0..len];
            const nl = countLines(m);
            self.yylineno += nl;
            const last_col = if (lastTerminatorLoc(m)) |t| blk: {
                var end = t.start + t.len;
                while (end < m.len and m[end] != '\n' and m[end] != '\r' and m[end] != 0x2028 and m[end] != 0x2029) end += 1;
                break :blk end - t.start - t.len;
            } else self.yylloc.last_column + len;
            self.yylloc = .{ .first_line = self.yylloc.last_line, .last_line = self.yylineno + 1, .first_column = self.yylloc.last_column, .last_column = last_col };
            self.yytext = m;
            self.match = m;
            self.rest = self.rest[len..];
            try self.matched.appendSlice(self.gpa, m);
            const token = try actions.lexAction(self, rule);
            if (self.done and self.rest.len > 0) self.done = false;
            return token;
        }

        fn next(self: *Self, actions: anytype) Error!?u16 {
            if (self.done) return eof_symbol;
            if (self.rest.len == 0) self.done = true;
            self.yytext = &.{};
            self.match = &.{};
            for (G.lex_conditions[self.topState()].rules) |rule| {
                const m = self.matcher.matchPrefix(&self.regexes[rule], self.rest) catch |e| switch (e) {
                    error.StepLimit => return self.diag.fail(self.gpa, "Lexer step limit exceeded", .{}),
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadPattern => unreachable,
                };
                if (m) |len| return self.testMatch(len, rule, actions);
            }
            if (self.rest.len == 0) return eof_symbol;
            return self.lexicalError();
        }

        pub fn lex(self: *Self, actions: anytype) Error!u16 {
            var idle: usize = 0;
            while (true) {
                const before = self.rest.len;
                if (try self.next(actions)) |t| return t;
                idle = if (self.rest.len == before) idle + 1 else 0;
                if (idle > 10_000) return self.diag.fail(self.gpa, "Maximum call stack size exceeded", .{});
            }
        }
    };
}

pub const Outcome = union(enum) { accepted, returned };

pub fn Parser(comptime G: type, comptime A: type) type {
    return struct {
        const Self = @This();
        pub const Lex = Lexer(G);
        pub const Value = A.Value;

        pub const Reduction = struct {
            prod: u16,
            yytext: []const u16,
            yyleng: usize,
            yylineno: usize,
            diag: *Diag,
            gpa: Allocator,
        };

        fn row(state: u16) []const u32 {
            return G.entries[G.row_start[state]..G.row_start[state + 1]];
        }

        fn find(state: u16, sym: u16) ?Entry {
            const r = row(state);
            var lo: usize = 0;
            var hi: usize = r.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const e = Entry.unpack(r[mid]);
                if (e.sym == sym) return e;
                if (e.sym < sym) lo = mid + 1 else hi = mid;
            }
            return null;
        }

        fn tokenName(sym: u16) ?[]const u8 {
            if (sym >= 2 and sym < G.symbol_names.len and G.is_terminal[sym]) return G.symbol_names[sym];
            if (sym >= G.symbol_names.len and sym - G.symbol_names.len < G.extra_tokens.len) return G.extra_tokens[sym - G.symbol_names.len];
            return null;
        }

        fn syntaxError(gpa: Allocator, diag: *Diag, lx: *const Lex, state: u16, symbol: u16, yylineno: usize) Error {
            var msg: std.ArrayList(u8) = .empty;
            errdefer msg.deinit(gpa);
            build(gpa, &msg, lx, state, symbol, yylineno) catch return error.OutOfMemory;
            diag.setOwned(gpa, msg.toOwnedSlice(gpa) catch return error.OutOfMemory);
            return error.Syntax;
        }

        fn build(gpa: Allocator, msg: *std.ArrayList(u8), lx: *const Lex, state: u16, symbol: u16, yylineno: usize) Allocator.Error!void {
            try msg.print(gpa, "Parse error on line {d}:\n", .{yylineno + 1});
            try lx.appendShowPosition(msg);
            try msg.appendSlice(gpa, "\nExpecting ");
            var first = true;
            for (row(state)) |v| {
                const e = Entry.unpack(v);
                if (e.sym <= error_symbol or !G.is_terminal[e.sym]) continue;
                if (!first) try msg.appendSlice(gpa, ", ");
                first = false;
                try msg.print(gpa, "'{s}'", .{G.symbol_names[e.sym]});
            }
            try msg.appendSlice(gpa, ", got '");
            if (tokenName(symbol)) |n| try msg.appendSlice(gpa, n) else try msg.print(gpa, "{d}", .{symbol});
            try msg.append(gpa, '\'');
        }

        pub fn parse(gpa: Allocator, actions: *A, input: []const u16, diag: *Diag) (Error || regex.Error)!Outcome {
            var lx = try Lex.init(gpa, input, diag);
            defer lx.deinit();
            var states: std.ArrayList(u16) = .empty;
            defer states.deinit(gpa);
            var values: std.ArrayList(Value) = .empty;
            defer values.deinit(gpa);
            try states.append(gpa, 0);
            try values.append(gpa, A.undefined_value);
            var symbol: ?u16 = null;
            var yytext: []const u16 = &.{};
            var yyleng: usize = 0;
            var yylineno: usize = 0;
            while (true) {
                const state = states.items[states.items.len - 1];
                const action: Entry = if (G.defaults[state] != no_default) .{ .kind = .reduce, .sym = 0, .arg = G.defaults[state] } else blk: {
                    if (symbol == null) symbol = try lx.lex(actions);
                    break :blk find(state, symbol.?) orelse return syntaxError(gpa, diag, &lx, state, symbol.?, yylineno);
                };
                if (action.kind == .go) return syntaxError(gpa, diag, &lx, state, symbol.?, yylineno);
                switch (action.kind) {
                    .shift => {
                        try states.append(gpa, action.arg);
                        try values.append(gpa, try actions.textValue(lx.yytext));
                        symbol = null;
                        yyleng = lx.yytext.len;
                        yytext = lx.yytext;
                        yylineno = lx.yylineno;
                    },
                    .reduce => {
                        const len = G.productions[action.arg].len;
                        const rhs = values.items[values.items.len - len ..];
                        var out: Value = if (len > 0) rhs[0] else A.undefined_value;
                        const ctx: Reduction = .{ .prod = action.arg, .yytext = yytext, .yyleng = yyleng, .yylineno = yylineno, .diag = diag, .gpa = gpa };
                        if (try actions.reduce(ctx, rhs, &out)) return .returned;
                        states.shrinkRetainingCapacity(states.items.len - len);
                        values.shrinkRetainingCapacity(values.items.len - len);
                        const top = states.items[states.items.len - 1];
                        const g = find(top, G.productions[action.arg].lhs) orelse unreachable;
                        try states.append(gpa, g.arg);
                        try values.append(gpa, out);
                    },
                    .accept => return .accepted,
                    .go => unreachable,
                }
            }
        }
    };
}

pub fn trim(s: []const u16) []const u16 {
    var lo: usize = 0;
    var hi: usize = s.len;
    while (lo < hi and isJsSpace(s[lo])) lo += 1;
    while (hi > lo and isJsSpace(s[hi - 1])) hi -= 1;
    return s[lo..hi];
}

fn isJsSpace(c: u16) bool {
    return (c >= 9 and c <= 13) or c == 0x20 or c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F or c == 0x3000 or c == 0xFEFF;
}

fn splitLineLengths(a: Allocator, s: []const u16) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n' or s[i] == '\r') {
            try out.append(a, i - start);
            if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') i += 1;
            start = i + 1;
        }
        i += 1;
    }
    try out.append(a, s.len - start);
    return out.items;
}

const UnputG = struct {
    pub const lex_ignore_case = false;
    pub const lex_patterns = [_][]const u8{ "[}]", "[a-z]+", "ns\\b", "[}]", "\\s+", "u[a-z]", "$" };
    pub const lex_conditions = [_]struct { rules: []const u16 }{
        .{ .rules = &.{ 0, 1 } },
        .{ .rules = &.{ 2, 3, 4, 5, 6 } },
    };
};

const UnputActions = struct {
    pub fn lexAction(_: *UnputActions, lx: *Lexer(UnputG), rule: u16) Error!?u16 {
        switch (rule) {
            0 => {
                lx.popState();
                try lx.less(0);
                return null;
            },
            1 => return 4,
            2 => {
                try lx.begin(0);
                return 3;
            },
            3 => return 5,
            5 => {
                try lx.begin(0);
                try lx.unput(lx.yytext);
                return null;
            },
            6 => return 6,
            else => return null,
        }
    }
};

// Expected values come from jison-lex 0.3.4 running the same rules.
test "unput and less behave as in jison-lex" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { input: []const u8, tokens: []const u16, message: []const u8 }{
        .{ .input = "ns} ?", .tokens = &.{ 3, 5 }, .message = "Lexical error on line 1. Unrecognized text.\nns} ?\n----^" },
        .{ .input = "ns}\n }\n?", .tokens = &.{ 3, 5, 5 }, .message = "Lexical error on line 3. Unrecognized text.\nns} }?\n-----^" },
        .{ .input = "ns ab}\n\n  ??", .tokens = &.{3}, .message = "Lexical error on line 1. Unrecognized text.\nns ab}  ??\n--^" },
        .{ .input = "ux}\n? ", .tokens = &.{ 4, 5 }, .message = "Lexical error on line 2. Unrecognized text.\nuux}? \n----^" },
        .{ .input = "ns\n}", .tokens = &.{3}, .message = "Lexical error on line 1. Unrecognized text.\nns}\n--^" },
    };
    for (cases) |c| {
        const input = try toUtf16(gpa, c.input);
        defer gpa.free(input);
        var diag: Diag = .{};
        defer diag.deinit(gpa);
        var lx = try Lexer(UnputG).init(gpa, input, &diag);
        defer lx.deinit();
        var actions: UnputActions = .{};
        var got: std.ArrayList(u16) = .empty;
        defer got.deinit(gpa);
        while (true) {
            const t = lx.lex(&actions) catch |e| {
                try std.testing.expectEqual(error.Syntax, e);
                break;
            };
            try got.append(gpa, t);
            try std.testing.expect(got.items.len < 20);
        }
        try std.testing.expectEqualSlices(u16, c.tokens, got.items);
        try std.testing.expectEqualStrings(c.message, diag.message);
    }
}
