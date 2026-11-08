const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, BadRegex };

const Range = struct { lo: u21, hi: u21 };

const Set = struct { negate: bool, ranges: []const Range };

const Op = enum { char, any, set, split, jmp, save, bol, eol, look, look_end, match, repeat_set };

const Inst = struct {
    op: Op,
    x: u32 = 0,
    y: u32 = 0,
    c: u21 = 0,
    flag: bool = false,
};

/// A backtracking matcher for the JavaScript regular expressions mhchem uses (anchored at the start of the input).
pub const Regex = struct {
    insts: []const Inst,
    sets: []const Set,
    groups: usize,
};

const Ast = union(enum) {
    char: u21,
    any,
    set: u32,
    cat: []const Ast,
    alt: []const Ast,
    group: struct { idx: ?u32, inner: *const Ast },
    repeat: struct { inner: *const Ast, min: u32, max: ?u32 },
    bol,
    eol,
    look: struct { inner: *const Ast, neg: bool },
};

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,
    groups: u32 = 0,
    sets: std.ArrayList(Set) = .empty,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    fn alt(p: *Parser) Error!Ast {
        var branches: std.ArrayList(Ast) = .empty;
        try branches.append(p.a, try p.cat());
        while (p.peek() == '|') {
            p.i += 1;
            try branches.append(p.a, try p.cat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn cat(p: *Parser) Error!Ast {
        var items: std.ArrayList(Ast) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            var unit = try p.atom();
            unit = try p.quant(unit);
            try items.append(p.a, unit);
        }
        return .{ .cat = items.items };
    }

    fn box(p: *Parser, n: Ast) Error!*const Ast {
        const ptr = try p.a.create(Ast);
        ptr.* = n;
        return ptr;
    }

    fn quant(p: *Parser, base: Ast) Error!Ast {
        const c = p.peek() orelse return base;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (c) {
            '*' => p.i += 1,
            '+' => {
                min = 1;
                p.i += 1;
            },
            '?' => {
                max = 1;
                p.i += 1;
            },
            '{' => {
                p.i += 1;
                min = try p.number();
                max = min;
                if (p.peek() == ',') {
                    p.i += 1;
                    max = if (p.peek() == '}') null else try p.number();
                }
                if (p.peek() != '}') return error.BadRegex;
                p.i += 1;
            },
            else => return base,
        }
        if (p.peek() == '?') p.i += 1;
        return .{ .repeat = .{ .inner = try p.box(base), .min = min, .max = max } };
    }

    fn number(p: *Parser) Error!u32 {
        const start = p.i;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.i += 1;
        }
        return std.fmt.parseInt(u32, p.src[start..p.i], 10) catch error.BadRegex;
    }

    fn atom(p: *Parser) Error!Ast {
        const c = p.src[p.i];
        switch (c) {
            '(' => {
                p.i += 1;
                var idx: ?u32 = null;
                var look: ?bool = null;
                if (std.mem.startsWith(u8, p.src[p.i..], "?:")) {
                    p.i += 2;
                } else if (std.mem.startsWith(u8, p.src[p.i..], "?=")) {
                    p.i += 2;
                    look = false;
                } else if (std.mem.startsWith(u8, p.src[p.i..], "?!")) {
                    p.i += 2;
                    look = true;
                } else {
                    p.groups += 1;
                    idx = p.groups;
                }
                const inner = try p.alt();
                if (p.peek() != ')') return error.BadRegex;
                p.i += 1;
                if (look) |neg| return .{ .look = .{ .inner = try p.box(inner), .neg = neg } };
                return .{ .group = .{ .idx = idx, .inner = try p.box(inner) } };
            },
            '[' => return p.set(),
            '.' => {
                p.i += 1;
                return .any;
            },
            '^' => {
                p.i += 1;
                return .bol;
            },
            '$' => {
                p.i += 1;
                return .eol;
            },
            '\\' => {
                p.i += 1;
                const e = try p.escape(false);
                switch (e) {
                    .cp => |cp| return .{ .char = cp },
                    .ranges => |rs| {
                        try p.sets.append(p.a, .{ .negate = false, .ranges = rs });
                        return .{ .set = @intCast(p.sets.items.len - 1) };
                    },
                }
            },
            else => {
                const n = std.unicode.utf8ByteSequenceLength(c) catch return error.BadRegex;
                const cp = std.unicode.utf8Decode(p.src[p.i .. p.i + n]) catch return error.BadRegex;
                p.i += n;
                return .{ .char = cp };
            },
        }
    }

    const Esc = union(enum) { cp: u21, ranges: []const Range };

    const space_ranges = [_]Range{ .{ .lo = 9, .hi = 13 }, .{ .lo = 32, .hi = 32 }, .{ .lo = 0xa0, .hi = 0xa0 }, .{ .lo = 0x2028, .hi = 0x2029 }, .{ .lo = 0x2000, .hi = 0x200a }, .{ .lo = 0x3000, .hi = 0x3000 } };
    const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};

    fn escape(p: *Parser, in_set: bool) Error!Esc {
        _ = in_set;
        const c = p.peek() orelse return error.BadRegex;
        p.i += 1;
        switch (c) {
            's' => return .{ .ranges = &space_ranges },
            'd' => return .{ .ranges = &digit_ranges },
            'n' => return .{ .cp = '\n' },
            't' => return .{ .cp = '\t' },
            'r' => return .{ .cp = '\r' },
            'u' => {
                if (p.i + 4 > p.src.len) return error.BadRegex;
                const cp = std.fmt.parseInt(u21, p.src[p.i .. p.i + 4], 16) catch return error.BadRegex;
                p.i += 4;
                return .{ .cp = cp };
            },
            else => return .{ .cp = c },
        }
    }

    fn set(p: *Parser) Error!Ast {
        p.i += 1;
        var negate = false;
        if (p.peek() == '^') {
            negate = true;
            p.i += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        while (true) {
            const c = p.peek() orelse return error.BadRegex;
            if (c == ']') {
                p.i += 1;
                break;
            }
            var lo: u21 = undefined_cp;
            if (c == '\\') {
                p.i += 1;
                switch (try p.escape(true)) {
                    .cp => |cp| lo = cp,
                    .ranges => |rs| {
                        try ranges.appendSlice(p.a, rs);
                        continue;
                    },
                }
            } else {
                const n = std.unicode.utf8ByteSequenceLength(c) catch return error.BadRegex;
                lo = std.unicode.utf8Decode(p.src[p.i .. p.i + n]) catch return error.BadRegex;
                p.i += n;
            }
            var hi = lo;
            if (p.peek() == '-' and p.i + 1 < p.src.len and p.src[p.i + 1] != ']') {
                p.i += 1;
                const d = p.src[p.i];
                if (d == '\\') {
                    p.i += 1;
                    switch (try p.escape(true)) {
                        .cp => |cp| hi = cp,
                        .ranges => return error.BadRegex,
                    }
                } else {
                    const n = std.unicode.utf8ByteSequenceLength(d) catch return error.BadRegex;
                    hi = std.unicode.utf8Decode(p.src[p.i .. p.i + n]) catch return error.BadRegex;
                    p.i += n;
                }
            }
            try ranges.append(p.a, .{ .lo = lo, .hi = hi });
        }
        try p.sets.append(p.a, .{ .negate = negate, .ranges = ranges.items });
        return .{ .set = @intCast(p.sets.items.len - 1) };
    }
};

const undefined_cp: u21 = 0;

const Emitter = struct {
    a: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    sets: []const Set,

    fn emit(e: *Emitter, inst: Inst) Error!u32 {
        try e.insts.append(e.a, inst);
        return @intCast(e.insts.items.len - 1);
    }

    fn here(e: *const Emitter) u32 {
        return @intCast(e.insts.items.len);
    }

    fn node(e: *Emitter, n: Ast) Error!void {
        switch (n) {
            .char => |c| _ = try e.emit(.{ .op = .char, .c = c }),
            .any => _ = try e.emit(.{ .op = .any }),
            .set => |s| _ = try e.emit(.{ .op = .set, .x = s }),
            .bol => _ = try e.emit(.{ .op = .bol }),
            .eol => _ = try e.emit(.{ .op = .eol }),
            .cat => |items| for (items) |it| try e.node(it),
            .alt => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                for (branches, 0..) |b, i| {
                    if (i + 1 < branches.len) {
                        const split = try e.emit(.{ .op = .split });
                        e.insts.items[split].x = e.here();
                        try e.node(b);
                        try jumps.append(e.a, try e.emit(.{ .op = .jmp }));
                        e.insts.items[split].y = e.here();
                    } else try e.node(b);
                }
                for (jumps.items) |j| e.insts.items[j].x = e.here();
            },
            .group => |g| {
                if (g.idx) |k| {
                    _ = try e.emit(.{ .op = .save, .x = 2 * k });
                    try e.node(g.inner.*);
                    _ = try e.emit(.{ .op = .save, .x = 2 * k + 1 });
                } else try e.node(g.inner.*);
            },
            .look => |l| {
                const at = try e.emit(.{ .op = .look, .flag = l.neg });
                try e.node(l.inner.*);
                _ = try e.emit(.{ .op = .look_end });
                e.insts.items[at].x = e.here();
            },
            .repeat => |r| try e.repeat(r.inner.*, r.min, r.max),
        }
    }

    fn singleWidth(n: Ast) bool {
        return switch (n) {
            .char, .any, .set => true,
            else => false,
        };
    }

    fn repeat(e: *Emitter, inner: Ast, min: u32, max: ?u32) Error!void {
        if (singleWidth(inner)) {
            const at = try e.emit(.{ .op = .repeat_set, .x = min, .y = max orelse std.math.maxInt(u32) });
            _ = at;
            try e.node(inner);
            return;
        }
        var i: u32 = 0;
        while (i < min) : (i += 1) try e.node(inner);
        if (max) |m| {
            var splits: std.ArrayList(u32) = .empty;
            var k: u32 = min;
            while (k < m) : (k += 1) {
                const s = try e.emit(.{ .op = .split });
                e.insts.items[s].x = e.here();
                try splits.append(e.a, s);
                try e.node(inner);
            }
            for (splits.items) |s| e.insts.items[s].y = e.here();
        } else {
            const s = try e.emit(.{ .op = .split });
            e.insts.items[s].x = e.here();
            try e.node(inner);
            _ = try e.emit(.{ .op = .jmp, .x = s });
            e.insts.items[s].y = e.here();
        }
    }
};

pub fn compile(a: Allocator, src: []const u8) Error!Regex {
    var p: Parser = .{ .a = a, .src = src };
    const ast = try p.alt();
    if (p.i != src.len) return error.BadRegex;
    var e: Emitter = .{ .a = a, .sets = p.sets.items };
    try e.node(ast);
    _ = try e.emit(.{ .op = .match });
    return .{ .insts = e.insts.items, .sets = p.sets.items, .groups = p.groups };
}

const Vm = struct {
    re: *const Regex,
    input: []const u8,
    caps: []?usize,
    steps: u32 = 0,

    const max_steps = 2_000_000;

    fn decode(v: *const Vm, pos: usize) ?struct { cp: u21, len: usize } {
        if (pos >= v.input.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(v.input[pos]) catch return .{ .cp = 0xfffd, .len = 1 };
        if (pos + n > v.input.len) return .{ .cp = 0xfffd, .len = 1 };
        const cp = std.unicode.utf8Decode(v.input[pos .. pos + n]) catch return .{ .cp = 0xfffd, .len = 1 };
        return .{ .cp = cp, .len = n };
    }

    fn inSet(v: *const Vm, s: u32, cp: u21) bool {
        const set = v.re.sets[s];
        var hit = false;
        for (set.ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) {
                hit = true;
                break;
            }
        }
        return hit != set.negate;
    }

    /// Width of one repetition of the single-character instruction at `pc` starting at `pos`, or null.
    fn step1(v: *const Vm, pc: u32, pos: usize) ?usize {
        const d = v.decode(pos) orelse return null;
        const inst = v.re.insts[pc];
        const ok = switch (inst.op) {
            .char => d.cp == inst.c,
            .any => d.cp != '\n' and d.cp != '\r' and d.cp != 0x2028 and d.cp != 0x2029,
            .set => v.inSet(inst.x, d.cp),
            else => false,
        };
        return if (ok) d.len else null;
    }

    fn run(v: *Vm, pc_in: u32, pos_in: usize) ?usize {
        var pc = pc_in;
        var pos = pos_in;
        while (true) {
            v.steps += 1;
            if (v.steps > max_steps) return null;
            const inst = v.re.insts[pc];
            switch (inst.op) {
                .char, .any, .set => {
                    const w = v.step1(pc, pos) orelse return null;
                    pos += w;
                    pc += 1;
                },
                .bol => {
                    if (pos != 0) return null;
                    pc += 1;
                },
                .eol => {
                    if (pos != v.input.len) return null;
                    pc += 1;
                },
                .jmp => pc = inst.x,
                .split => {
                    if (v.run(inst.x, pos)) |end| return end;
                    pc = inst.y;
                },
                .save => {
                    const old = v.caps[inst.x];
                    v.caps[inst.x] = pos;
                    if (v.run(pc + 1, pos)) |end| return end;
                    v.caps[inst.x] = old;
                    return null;
                },
                .repeat_set => {
                    const body = pc + 1;
                    var count: u32 = 0;
                    var p2 = pos;
                    while (count < inst.y) {
                        const w = v.step1(body, p2) orelse break;
                        p2 += w;
                        count += 1;
                    }
                    if (count < inst.x) return null;
                    // try the longest first, then back off one character at a time
                    var k = count;
                    var at = p2;
                    while (true) {
                        if (v.run(body + 1, at)) |end| return end;
                        if (k == inst.x) return null;
                        k -= 1;
                        at = backUp(v.input, at);
                    }
                },
                .look => {
                    const ok = v.run(pc + 1, pos) != null;
                    if (ok == inst.flag) return null;
                    pc = inst.x;
                },
                .look_end => return pos,
                .match => return pos,
            }
        }
    }

    fn backUp(input: []const u8, at: usize) usize {
        var i = at - 1;
        while (i > 0 and (input[i] & 0xc0) == 0x80) i -= 1;
        return i;
    }
};

pub const Result = struct {
    /// caps[2k], caps[2k+1] bound group k (0 is the whole match).
    caps: []const ?usize,
};

/// Matches `re` at the start of `input`.
pub fn match(re: *const Regex, a: Allocator, input: []const u8) Allocator.Error!?Result {
    const caps = try a.alloc(?usize, 2 * (re.groups + 1));
    @memset(caps, null);
    var vm: Vm = .{ .re = re, .input = input, .caps = caps };
    const end = vm.run(0, 0) orelse return null;
    caps[0] = 0;
    caps[1] = end;
    return .{ .caps = caps };
}

fn expectMatch(src: []const u8, input: []const u8, want_end: ?usize) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), src);
    const r = try match(&re, arena.allocator(), input);
    if (want_end) |w| {
        try std.testing.expectEqual(w, r.?.caps[1].?);
    } else try std.testing.expect(r == null);
}

test "regex basics" {
    try expectMatch("^[0-9]+", "123abc", 3);
    try expectMatch("^[+\\-]?(?:[0-9]+(?:[,.][0-9]+)?|[0-9]*(?:\\.[0-9]+))", "-12.5x", 5);
    try expectMatch("^\\s(?=[A-Z\\\\$])", " A", 1);
    try expectMatch("^\\s(?=[A-Z\\\\$])", " a", null);
    try expectMatch("^(?:\\(v\\)|v)(?=$|[\\s,;])", "v,", 1);
    try expectMatch("^\\.\\.\\.(?=$|[^.])", "....", null);
    try expectMatch("^[a-z]{1,3}", "abcde", 3);
    try expectMatch("^(?:[a-zA-Z\\u03B1-\\u03C9]|(?:\\\\x(?!y)))+", "ab\u{3b1}", 4);
    try expectMatch("^$", "", 0);
    try expectMatch("^.", "", null);
}

test "regex groups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), "^(\\+|-)?([0-9]+)(e)?");
    const r = (try match(&re, arena.allocator(), "-12x")).?;
    try std.testing.expectEqual(@as(?usize, 0), r.caps[2]);
    try std.testing.expectEqual(@as(?usize, 1), r.caps[3]);
    try std.testing.expectEqual(@as(?usize, 1), r.caps[4]);
    try std.testing.expectEqual(@as(?usize, 3), r.caps[5]);
    try std.testing.expectEqual(@as(?usize, null), r.caps[6]);
}
