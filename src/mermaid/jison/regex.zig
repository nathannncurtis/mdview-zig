const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadPattern, OutOfMemory, StepLimit };

const Range = struct { lo: u16, hi: u16 };

const Class = struct {
    ranges: []const Range,
    negated: bool,

    fn has(self: Class, ch: u16) bool {
        for (self.ranges) |r| if (ch >= r.lo and ch <= r.hi) return true;
        return false;
    }
};

const Op = enum(u8) { char, any, class, begin, end, word_b, not_word_b, split, jmp, look, look_end, loop_enter, loop_check, match };

const Inst = struct { op: Op, a: u32 = 0, b: u32 = 0 };

const Assertion = enum { begin, end, word_b, not_word_b };

const Node = union(enum) {
    empty,
    char: u16,
    any,
    class: u32,
    assertion: Assertion,
    seq: []const Node,
    alt: []const Node,
    look: struct { negative: bool, body: *const Node },
    quant: struct { body: *const Node, min: u32, max: u32, greedy: bool },
};

const unbounded = std.math.maxInt(u32);
const max_insts = 200_000;
const max_repeat = 1000;

const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const space_ranges = [_]Range{
    .{ .lo = 9, .hi = 13 },          .{ .lo = 0x20, .hi = 0x20 },     .{ .lo = 0xA0, .hi = 0xA0 },     .{ .lo = 0x1680, .hi = 0x1680 },
    .{ .lo = 0x2000, .hi = 0x200A }, .{ .lo = 0x2028, .hi = 0x2029 }, .{ .lo = 0x202F, .hi = 0x202F }, .{ .lo = 0x205F, .hi = 0x205F },
    .{ .lo = 0x3000, .hi = 0x3000 }, .{ .lo = 0xFEFF, .hi = 0xFEFF },
};

fn isLineTerminator(c: u16) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

fn isWord(c: u16) bool {
    return c < 128 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '_');
}

// shortcut: simple case folding covers ASCII and Latin-1 only, extend if a grammar needs more
fn canon(c: u16) u16 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 32;
    return c;
}

fn otherCase(c: u16) u16 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (c >= 'A' and c <= 'Z') return c + 32;
    if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 32;
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 32;
    return c;
}

pub const Regex = struct {
    prog: []const Inst,
    classes: []const Class,
    loops: u32,
    ignore_case: bool,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    pub fn compile(gpa: Allocator, pattern: []const u8, ignore_case: bool) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var p = Parser{ .a = a, .src = try decode(a, pattern) };
        const root = try p.disjunction();
        if (p.pos != p.src.len) return error.BadPattern;
        var c = Compiler{ .a = a };
        try c.emit(root);
        try c.push(.{ .op = .match });
        return .{ .prog = c.prog.items, .classes = p.classes.items, .loops = c.loops, .ignore_case = ignore_case, .arena = arena };
    }
};

fn decode(a: Allocator, s: []const u8) Error![]u16 {
    var out: std.ArrayList(u16) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return error.BadPattern).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try out.append(a, @intCast(0xD800 + (v >> 10)));
            try out.append(a, @intCast(0xDC00 + (v & 0x3FF)));
        } else try out.append(a, @intCast(cp));
    }
    return out.items;
}

const Parser = struct {
    a: Allocator,
    src: []const u16,
    pos: usize = 0,
    classes: std.ArrayList(Class) = .empty,

    fn peek(self: *Parser) ?u16 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn at(self: *Parser, off: usize) ?u16 {
        return if (self.pos + off < self.src.len) self.src[self.pos + off] else null;
    }

    fn eat(self: *Parser, c: u16) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn node(self: *Parser, n: Node) Error!*const Node {
        const p = try self.a.create(Node);
        p.* = n;
        return p;
    }

    fn disjunction(self: *Parser) Error!Node {
        var alts: std.ArrayList(Node) = .empty;
        try alts.append(self.a, try self.alternative());
        while (self.eat('|')) try alts.append(self.a, try self.alternative());
        if (alts.items.len == 1) return alts.items[0];
        return .{ .alt = alts.items };
    }

    fn alternative(self: *Parser) Error!Node {
        var terms: std.ArrayList(Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try terms.append(self.a, try self.term());
        }
        if (terms.items.len == 0) return .empty;
        if (terms.items.len == 1) return terms.items[0];
        return .{ .seq = terms.items };
    }

    fn addClass(self: *Parser, ranges: []const Range, negated: bool) Error!Node {
        try self.classes.append(self.a, .{ .ranges = ranges, .negated = negated });
        return .{ .class = @intCast(self.classes.items.len - 1) };
    }

    fn term(self: *Parser) Error!Node {
        const c = self.peek().?;
        const atom: Node = switch (c) {
            '^' => {
                self.pos += 1;
                return .{ .assertion = .begin };
            },
            '$' => {
                self.pos += 1;
                return .{ .assertion = .end };
            },
            '*', '+', '?' => return error.BadPattern,
            '.' => blk: {
                self.pos += 1;
                break :blk .any;
            },
            '[' => blk: {
                self.pos += 1;
                break :blk try self.classAtom();
            },
            '(' => blk: {
                self.pos += 1;
                break :blk try self.group();
            },
            '\\' => blk: {
                self.pos += 1;
                if (self.peek()) |e| {
                    if (e == 'b' or e == 'B') {
                        self.pos += 1;
                        return .{ .assertion = if (e == 'b') .word_b else .not_word_b };
                    }
                }
                break :blk try self.escape();
            },
            else => blk: {
                self.pos += 1;
                break :blk .{ .char = c };
            },
        };
        return self.quantifier(atom);
    }

    fn group(self: *Parser) Error!Node {
        var look: ?bool = null;
        if (self.peek() == '?') {
            switch (self.at(1) orelse return error.BadPattern) {
                ':' => self.pos += 2,
                '=' => {
                    self.pos += 2;
                    look = false;
                },
                '!' => {
                    self.pos += 2;
                    look = true;
                },
                else => return error.BadPattern,
            }
        }
        const inner = try self.disjunction();
        if (!self.eat(')')) return error.BadPattern;
        if (look) |negative| return .{ .look = .{ .negative = negative, .body = try self.node(inner) } };
        return inner;
    }

    fn number(self: *Parser) ?u32 {
        var n: u32 = 0;
        var digits: usize = 0;
        while (self.peek()) |c| : (self.pos += 1) {
            if (c < '0' or c > '9') break;
            n = std.math.mul(u32, n, 10) catch return null;
            n = std.math.add(u32, n, c - '0') catch return null;
            digits += 1;
        }
        return if (digits == 0) null else n;
    }

    fn quantifier(self: *Parser, atom: Node) Error!Node {
        var min: u32 = 0;
        var max: u32 = unbounded;
        switch (self.peek() orelse return atom) {
            '*' => self.pos += 1,
            '+' => {
                self.pos += 1;
                min = 1;
            },
            '?' => {
                self.pos += 1;
                max = 1;
            },
            '{' => {
                const save = self.pos;
                self.pos += 1;
                const lo = self.number() orelse {
                    self.pos = save;
                    return atom;
                };
                min = lo;
                max = lo;
                if (self.eat(',')) max = self.number() orelse unbounded;
                if (!self.eat('}')) {
                    self.pos = save;
                    return atom;
                }
                if (max < min) return error.BadPattern;
            },
            else => return atom,
        }
        const greedy = !self.eat('?');
        return .{ .quant = .{ .body = try self.node(atom), .min = min, .max = max, .greedy = greedy } };
    }

    fn hex(self: *Parser, digits: usize) ?u16 {
        if (self.pos + digits > self.src.len) return null;
        var v: u16 = 0;
        for (self.src[self.pos..][0..digits]) |c| {
            if (c > 127) return null;
            const d = std.fmt.charToDigit(@intCast(c), 16) catch return null;
            v = v * 16 + d;
        }
        self.pos += digits;
        return v;
    }

    const Escaped = union(enum) { char: u16, set: struct { ranges: []const Range, negated: bool } };

    fn escaped(self: *Parser) Error!Escaped {
        const c = self.peek() orelse return error.BadPattern;
        self.pos += 1;
        return switch (c) {
            'd' => .{ .set = .{ .ranges = &digit_ranges, .negated = false } },
            'D' => .{ .set = .{ .ranges = &digit_ranges, .negated = true } },
            's' => .{ .set = .{ .ranges = &space_ranges, .negated = false } },
            'S' => .{ .set = .{ .ranges = &space_ranges, .negated = true } },
            'w' => .{ .set = .{ .ranges = &word_ranges, .negated = false } },
            'W' => .{ .set = .{ .ranges = &word_ranges, .negated = true } },
            't' => .{ .char = 9 },
            'n' => .{ .char = 10 },
            'v' => .{ .char = 11 },
            'f' => .{ .char = 12 },
            'r' => .{ .char = 13 },
            'c' => blk: {
                if (self.peek()) |l| if (l < 128 and std.ascii.isAlphabetic(@intCast(l))) {
                    self.pos += 1;
                    break :blk .{ .char = l % 32 };
                };
                self.pos -= 1;
                break :blk .{ .char = '\\' };
            },
            'x' => .{ .char = self.hex(2) orelse 'x' },
            'u' => .{ .char = self.hex(4) orelse 'u' },
            '0'...'7' => blk: {
                var v: u16 = c - '0';
                var n: usize = 1;
                while (n < 3) : (n += 1) {
                    const d = self.peek() orelse break;
                    if (d < '0' or d > '7' or v * 8 + (d - '0') > 0o377) break;
                    v = v * 8 + (d - '0');
                    self.pos += 1;
                }
                break :blk .{ .char = v };
            },
            else => .{ .char = c },
        };
    }

    fn escape(self: *Parser) Error!Node {
        return switch (try self.escaped()) {
            .char => |c| .{ .char = c },
            .set => |s| self.addClass(s.ranges, s.negated),
        };
    }

    fn complement(self: *Parser, ranges: []const Range, out: *std.ArrayList(Range)) Error!void {
        const sorted = try self.a.dupe(Range, ranges);
        std.mem.sort(Range, sorted, {}, struct {
            fn lt(_: void, x: Range, y: Range) bool {
                return x.lo < y.lo;
            }
        }.lt);
        var next: u32 = 0;
        for (sorted) |r| {
            if (r.lo > next) try out.append(self.a, .{ .lo = @intCast(next), .hi = r.lo - 1 });
            next = @max(next, @as(u32, r.hi) + 1);
        }
        if (next <= 0xFFFF) try out.append(self.a, .{ .lo = @intCast(next), .hi = 0xFFFF });
    }

    fn classAtom(self: *Parser) Error!Node {
        const negated = self.eat('^');
        var ranges: std.ArrayList(Range) = .empty;
        while (true) {
            const c = self.peek() orelse return error.BadPattern;
            if (c == ']') {
                self.pos += 1;
                break;
            }
            const lo = try self.classItem();
            if (self.peek() == '-' and self.at(1) != null and self.at(1).? != ']') {
                const save = self.pos;
                self.pos += 1;
                const hi = try self.classItem();
                if (lo == .char and hi == .char) {
                    if (lo.char > hi.char) return error.BadPattern;
                    try ranges.append(self.a, .{ .lo = lo.char, .hi = hi.char });
                    continue;
                }
                self.pos = save;
            }
            try self.addItem(&ranges, lo);
        }
        return self.addClass(ranges.items, negated);
    }

    fn addItem(self: *Parser, ranges: *std.ArrayList(Range), item: Escaped) Error!void {
        switch (item) {
            .char => |ch| try ranges.append(self.a, .{ .lo = ch, .hi = ch }),
            .set => |s| if (s.negated) try self.complement(s.ranges, ranges) else try ranges.appendSlice(self.a, s.ranges),
        }
    }

    fn classItem(self: *Parser) Error!Escaped {
        const c = self.peek() orelse return error.BadPattern;
        self.pos += 1;
        if (c != '\\') return .{ .char = c };
        if (self.peek() == 'b') {
            self.pos += 1;
            return .{ .char = 8 };
        }
        return self.escaped();
    }
};

const Compiler = struct {
    a: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    loops: u32 = 0,

    fn push(self: *Compiler, i: Inst) Error!void {
        if (self.prog.items.len >= max_insts) return error.BadPattern;
        try self.prog.append(self.a, i);
    }

    fn here(self: *Compiler) u32 {
        return @intCast(self.prog.items.len);
    }

    fn emit(self: *Compiler, n: Node) Error!void {
        switch (n) {
            .empty => {},
            .char => |c| try self.push(.{ .op = .char, .a = c }),
            .any => try self.push(.{ .op = .any }),
            .class => |i| try self.push(.{ .op = .class, .a = i }),
            .assertion => |k| try self.push(.{ .op = switch (k) {
                .begin => .begin,
                .end => .end,
                .word_b => .word_b,
                .not_word_b => .not_word_b,
            } }),
            .seq => |items| for (items) |item| try self.emit(item),
            .alt => |items| {
                var jumps: std.ArrayList(u32) = .empty;
                for (items, 0..) |item, k| {
                    if (k + 1 < items.len) {
                        const split = self.here();
                        try self.push(.{ .op = .split });
                        try self.emit(item);
                        try jumps.append(self.a, self.here());
                        try self.push(.{ .op = .jmp });
                        self.prog.items[split] = .{ .op = .split, .a = split + 1, .b = self.here() };
                    } else try self.emit(item);
                }
                for (jumps.items) |j| self.prog.items[j].a = self.here();
            },
            .look => |l| {
                const at = self.here();
                try self.push(.{ .op = .look });
                try self.emit(l.body.*);
                try self.push(.{ .op = .look_end });
                self.prog.items[at] = .{ .op = .look, .a = @intFromBool(l.negative), .b = self.here() };
            },
            .quant => |q| {
                if (q.min > max_repeat or (q.max != unbounded and q.max > max_repeat)) return error.BadPattern;
                for (0..q.min) |_| try self.emit(q.body.*);
                if (q.max == unbounded) {
                    const l1 = self.here();
                    try self.push(.{ .op = .split });
                    const reg = self.loops;
                    self.loops += 1;
                    try self.push(.{ .op = .loop_enter, .a = reg });
                    try self.emit(q.body.*);
                    try self.push(.{ .op = .loop_check, .a = reg });
                    try self.push(.{ .op = .jmp, .a = l1 });
                    self.setSplit(l1, q.greedy);
                } else {
                    var splits: std.ArrayList(u32) = .empty;
                    for (0..q.max - q.min) |_| {
                        try splits.append(self.a, self.here());
                        try self.push(.{ .op = .split });
                        try self.emit(q.body.*);
                    }
                    for (splits.items) |s| self.setSplit(s, q.greedy);
                }
            },
        }
    }

    fn setSplit(self: *Compiler, at: u32, greedy: bool) void {
        const body = at + 1;
        const exit = self.here();
        self.prog.items[at] = .{ .op = .split, .a = if (greedy) body else exit, .b = if (greedy) exit else body };
    }
};

const Frame = struct { pc: u32, sp: u32, undo: bool };

pub const Matcher = struct {
    gpa: Allocator,
    frames: std.ArrayList(Frame) = .empty,
    regs: std.ArrayList(u32) = .empty,
    steps: usize = 0,

    pub const step_limit: usize = 50_000_000;

    pub fn init(gpa: Allocator) Matcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Matcher) void {
        self.frames.deinit(self.gpa);
        self.regs.deinit(self.gpa);
    }

    pub fn matchPrefix(self: *Matcher, re: *const Regex, input: []const u16) Error!?usize {
        self.steps = 0;
        self.frames.clearRetainingCapacity();
        try self.regs.resize(self.gpa, re.loops);
        return self.run(re, input, 0, 0);
    }

    fn classOk(re: *const Regex, cls: Class, ch: u16) bool {
        var hit = cls.has(ch);
        if (!hit and re.ignore_case) {
            const o = otherCase(ch);
            hit = o != ch and cls.has(o);
        }
        return hit != cls.negated;
    }

    fn run(self: *Matcher, re: *const Regex, input: []const u16, start_pc: u32, start_sp: u32) Error!?usize {
        const base = self.frames.items.len;
        var pc = start_pc;
        var sp = start_sp;
        while (true) {
            self.steps += 1;
            if (self.steps > step_limit) return error.StepLimit;
            const inst = re.prog[pc];
            var ok = true;
            switch (inst.op) {
                .char => {
                    ok = sp < input.len and (input[sp] == inst.a or (re.ignore_case and canon(input[sp]) == canon(@intCast(inst.a))));
                    if (ok) {
                        sp += 1;
                        pc += 1;
                    }
                },
                .any => {
                    ok = sp < input.len and !isLineTerminator(input[sp]);
                    if (ok) {
                        sp += 1;
                        pc += 1;
                    }
                },
                .class => {
                    ok = sp < input.len and classOk(re, re.classes[inst.a], input[sp]);
                    if (ok) {
                        sp += 1;
                        pc += 1;
                    }
                },
                .begin => {
                    ok = sp == 0;
                    pc += 1;
                },
                .end => {
                    ok = sp == input.len;
                    pc += 1;
                },
                .word_b, .not_word_b => {
                    const before = sp > 0 and isWord(input[sp - 1]);
                    const after = sp < input.len and isWord(input[sp]);
                    ok = (before != after) == (inst.op == .word_b);
                    pc += 1;
                },
                .split => {
                    try self.frames.append(self.gpa, .{ .pc = inst.b, .sp = sp, .undo = false });
                    pc = inst.a;
                },
                .jmp => pc = inst.a,
                .look => {
                    const matched = (try self.run(re, input, pc + 1, sp)) != null;
                    ok = matched != (inst.a == 1);
                    pc = inst.b;
                },
                .look_end => {
                    self.frames.shrinkRetainingCapacity(base);
                    return sp;
                },
                .loop_enter => {
                    try self.frames.append(self.gpa, .{ .pc = inst.a, .sp = self.regs.items[inst.a], .undo = true });
                    self.regs.items[inst.a] = sp;
                    pc += 1;
                },
                .loop_check => {
                    ok = self.regs.items[inst.a] != sp;
                    pc += 1;
                },
                .match => {
                    self.frames.shrinkRetainingCapacity(base);
                    return sp;
                },
            }
            if (ok) continue;
            while (true) {
                if (self.frames.items.len == base) return null;
                const f = self.frames.pop().?;
                if (f.undo) {
                    self.regs.items[f.pc] = f.sp;
                    continue;
                }
                pc = f.pc;
                sp = f.sp;
                break;
            }
        }
    }
};

fn expectMatch(pattern: []const u8, icase: bool, text: []const u8, want: ?usize) !void {
    const gpa = std.testing.allocator;
    var re = try Regex.compile(gpa, pattern, icase);
    defer re.deinit();
    var m = Matcher.init(gpa);
    defer m.deinit();
    var buf: [256]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&buf, text);
    try std.testing.expectEqual(want, try m.matchPrefix(&re, buf[0..n]));
}

test "literals, classes, alternation" {
    try expectMatch("abc", false, "abcd", 3);
    try expectMatch("abc", false, "abd", null);
    try expectMatch("abc", true, "ABC", 3);
    try expectMatch("[a-c]+", false, "abcabcx", 6);
    try expectMatch("[^a-c]+", false, "xyzabc", 3);
    try expectMatch("a|ab|abc", false, "abc", 1);
    try expectMatch("(?:a|ab)c", false, "abc", 3);
    try expectMatch("", false, "abc", 0);
    try expectMatch("(?:)", false, "abc", 0);
    try expectMatch("\\s*x", false, " \t\nx", 4);
    try expectMatch("[\\w-]+", false, "ab-c d", 4);
    try expectMatch("[\\u0041-\\u0043]+", false, "ABCD", 3);
}

test "quantifiers, greedy and lazy" {
    try expectMatch("a*", false, "aaa", 3);
    try expectMatch("a*?", false, "aaa", 0);
    try expectMatch("a+?b", false, "aaab", 4);
    try expectMatch("a{2}", false, "aaa", 2);
    try expectMatch("a{2,}", false, "aaaa", 4);
    try expectMatch("a{1,2}", false, "aaa", 2);
    try expectMatch("a{", false, "a{", 2);
    try expectMatch("(a|b)*c", false, "ababc", 5);
    try expectMatch("(?:a*)*b", false, "aaab", 4);
    try expectMatch("(.|\\n|\\r)*?\\*\\/", false, "x\ny*/z", 5);
}

test "assertions and lookahead" {
    try expectMatch("a(?=b)", false, "ab", 1);
    try expectMatch("a(?=b)", false, "ac", null);
    try expectMatch("a(?!b)", false, "ac", 1);
    try expectMatch("a(?!b)", false, "ab", null);
    try expectMatch("(?!\\n||)*[^\\n]*", false, "ab\nc", 2);
    try expectMatch("(?=a)*b", false, "b", 1);
    try expectMatch("graph\\b", false, "graphx", null);
    try expectMatch("graph\\b", false, "graph x", 5);
    try expectMatch("$", false, "", 0);
    try expectMatch("$", false, "a", null);
    try expectMatch("^a", false, "a", 1);
    try expectMatch("((?!\\n)\\s)+", false, "  \n", 2);
}

test "dot, line terminators and surrogates" {
    try expectMatch(".*", false, "ab\ncd", 2);
    try expectMatch(".", false, "\u{1F600}", 1);
    try expectMatch("..", false, "\u{1F600}", 2);
    try expectMatch("[^x]+", false, "a\u{1F600}b", 4);
}

test "long input does not recurse" {
    const gpa = std.testing.allocator;
    var re = try Regex.compile(gpa, "(?:[a-z]|-(?=x))+", false);
    defer re.deinit();
    var m = Matcher.init(gpa);
    defer m.deinit();
    const input = try gpa.alloc(u16, 200_000);
    defer gpa.free(input);
    @memset(input, 'a');
    try std.testing.expectEqual(@as(?usize, input.len), try m.matchPrefix(&re, input));
}

test "bad patterns" {
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "(a", false));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "a)", false));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "*a", false));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "[z-a]", false));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "[a", false));
}

const Cases = struct { texts: []const []const u8, cases: []const []const []const u8 };

// Expected values come from JavaScript's RegExp: the FNV-1a fold of the match length at every offset of every text.
test "match lengths agree with JavaScript at every offset" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Cases, gpa, @embedFile("testdata/regex_cases.json"), .{});
    defer parsed.deinit();
    var texts: std.ArrayList([]u16) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    for (parsed.value.texts) |t| {
        const buf = try gpa.alloc(u16, t.len);
        const n = try std.unicode.utf8ToUtf16Le(buf, t);
        try texts.append(gpa, try gpa.realloc(buf, n));
    }
    var m = Matcher.init(gpa);
    defer m.deinit();
    for (parsed.value.cases) |c| {
        const src = try std.fmt.allocPrint(gpa, "^(?:{s})", .{c[2]});
        defer gpa.free(src);
        var re = try Regex.compile(gpa, src, c[0].len > 0);
        defer re.deinit();
        var total: u32 = 0;
        for (texts.items) |t| {
            var h: u32 = 0x811c9dc5;
            for (0..t.len + 1) |o| {
                const v: u32 = if (try m.matchPrefix(&re, t[o..])) |len| @intCast(len + 1) else 0;
                h = (h ^ v) *% 16777619;
            }
            total = total *% 31 +% h;
        }
        const want = try std.fmt.parseInt(u32, c[1], 16);
        std.testing.expectEqual(want, total) catch |e| {
            std.debug.print("pattern {s} (flags '{s}')\n", .{ c[2], c[0] });
            return e;
        };
    }
}
