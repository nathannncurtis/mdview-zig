const std = @import("std");
const testdata = @import("testdata");
const rt = @import("jison_runtime");
const flow = @import("flow_grammar");
const seq = @import("seq_grammar");
const flow_stub = @import("flow_stub");
const seq_stub = @import("seq_stub");

const Case = struct { input: []const u8, message: ?[]const u8 };

const Mode = enum { flow, sequence };

fn Actions(comptime G: type, comptime stub: type, comptime mode: Mode) type {
    return struct {
        const Self = @This();
        pub const Value = u8;
        pub const undefined_value: Value = 0;

        first_graph: bool = true,

        pub fn textValue(_: *Self, _: []const u16) rt.Error!Value {
            return 0;
        }

        // The flowchart rules the generator cannot translate, ported for the test: the shape data rules and the graph keyword.
        pub fn lexAction(self: *Self, lx: *rt.Lexer(G), rule: u16) rt.Error!?u16 {
            if (mode == .flow) switch (rule) {
                7 => {
                    try lx.pushState(G.cond.shapeData);
                    lx.yytext = &.{};
                    return G.tok.SHAPE_DATA;
                },
                10 => {
                    var out: std.ArrayList(u16) = .empty;
                    const a = lx.arena.allocator();
                    var i: usize = 0;
                    while (i < lx.yytext.len) : (i += 1) {
                        if (lx.yytext[i] == '\n') {
                            while (i + 1 < lx.yytext.len and rt.trim(lx.yytext[i + 1 .. i + 2]).len == 0) i += 1;
                            try out.appendSlice(a, &.{ '<', 'b', 'r', '/', '>' });
                        } else try out.append(a, lx.yytext[i]);
                    }
                    lx.yytext = out.items;
                    return G.tok.SHAPE_DATA;
                },
                35, 36, 37, 38 => {
                    if (self.first_graph) {
                        self.first_graph = false;
                        try lx.begin(G.cond.dir);
                    }
                    return G.tok.GRAPH;
                },
                else => {},
            };
            return stub.lexAction(self, lx, rule);
        }

        // Grammar semantics are ported by later work; the one action the parser itself depends on is the sequence start rule's return.
        pub fn reduce(_: *Self, ctx: anytype, _: []Value, _: *Value) rt.Error!bool {
            return mode == .sequence and ctx.prod == 3;
        }
    };
}

fn runCorpus(comptime G: type, comptime stub: type, comptime mode: Mode, json: []const u8) !void {
    const gpa = std.testing.allocator;
    const A = Actions(G, stub, mode);
    const P = rt.Parser(G, A);
    var parsed = try std.json.parseFromSlice([]const Case, gpa, json, .{});
    defer parsed.deinit();
    var failures: usize = 0;
    for (parsed.value) |c| {
        const text = try std.fmt.allocPrint(gpa, "{s}\n", .{c.input});
        defer gpa.free(text);
        const input = try rt.toUtf16(gpa, text);
        defer gpa.free(input);
        var actions: A = .{};
        var diag: rt.Diag = .{};
        defer diag.deinit(gpa);
        const result = P.parse(gpa, &actions, input, &diag);
        if (result) |_| {
            if (c.message != null) {
                std.debug.print("accepted but mermaid rejects: {s}\n", .{c.input});
                failures += 1;
            }
        } else |err| {
            if (err != error.Syntax or c.message == null or !std.mem.eql(u8, diag.message, c.message.?)) {
                std.debug.print("input: {s}\nwant:  {?s}\ngot:   {s} {s}\n\n", .{ c.input, c.message, @errorName(err), diag.message });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "flowchart error strings match mermaid.parse" {
    try runCorpus(flow, flow_stub, .flow, testdata.file("mermaid/jison/errors_flow.json"));
}

test "sequence error strings match mermaid.parse" {
    try runCorpus(seq, seq_stub, .sequence, testdata.file("mermaid/jison/errors_sequence.json"));
}

fn everyArm(comptime G: type, comptime stub: type, comptime mode: Mode) !void {
    const gpa = std.testing.allocator;
    const A = Actions(G, stub, mode);
    const P = rt.Parser(G, A);
    var actions: A = .{};
    var diag: rt.Diag = .{};
    defer diag.deinit(gpa);
    var rhs = [_]u8{0};
    var out: u8 = 0;
    for (0..G.productions.len) |prod| {
        const ctx: P.Reduction = .{ .prod = @intCast(prod), .yytext = &.{}, .yyleng = 0, .yylineno = 0, .diag = &diag, .gpa = gpa };
        _ = stub.reduce(&actions, ctx, &rhs, &out) catch |e| try std.testing.expectEqual(error.Semantic, e);
    }
    var lx = try rt.Lexer(G).init(gpa, &.{}, &diag);
    defer lx.deinit();
    for (0..G.lex_patterns.len) |rule| {
        _ = stub.lexAction(&actions, &lx, @intCast(rule)) catch |e| try std.testing.expectEqual(error.Semantic, e);
    }
}

test "the generated stubs have an arm for every production and lexer rule" {
    try everyArm(flow, flow_stub, .flow);
    try everyArm(seq, seq_stub, .sequence);
}

fn parseText(comptime G: type, comptime stub: type, comptime mode: Mode, text: []const u8) !bool {
    const gpa = std.testing.allocator;
    const A = Actions(G, stub, mode);
    const P = rt.Parser(G, A);
    const input = try rt.toUtf16(gpa, text);
    defer gpa.free(input);
    var actions: A = .{};
    var diag: rt.Diag = .{};
    defer diag.deinit(gpa);
    _ = P.parse(gpa, &actions, input, &diag) catch |e| {
        try std.testing.expectEqual(error.Syntax, e);
        return false;
    };
    return true;
}

fn mutate(comptime G: type, comptime stub: type, comptime mode: Mode, json: []const u8, seed: u64) !void {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice([]const Case, gpa, json, .{});
    defer parsed.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const pieces = [_][]const u8{ "\n", " ", "\t", "-", ">", "[", "(", "\"", "{", "|", "\u{1F600}", "\xF0\x9F", "\xFF", "end", "--", "A", "%%", ":" };
    for (parsed.value) |c| {
        for (0..40) |_| {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(gpa);
            try text.appendSlice(gpa, c.input);
            for (0..1 + rnd.uintLessThan(usize, 4)) |_| {
                const at = rnd.uintLessThan(usize, text.items.len + 1);
                switch (rnd.uintLessThan(usize, 3)) {
                    0 => try text.insertSlice(gpa, at, pieces[rnd.uintLessThan(usize, pieces.len)]),
                    1 => if (at < text.items.len) {
                        const n = @min(1 + rnd.uintLessThan(usize, 6), text.items.len - at);
                        text.replaceRangeAssumeCapacity(at, n, &.{});
                    },
                    else => if (at < text.items.len) {
                        text.items[at] = pieces[rnd.uintLessThan(usize, pieces.len)][0];
                    },
                }
            }
            try text.append(gpa, '\n');
            _ = try parseText(G, stub, mode, text.items);
        }
    }
}

test "mutated inputs end in a syntax error or acceptance, never a crash or a leak" {
    try mutate(flow, flow_stub, .flow, testdata.file("mermaid/jison/errors_flow.json"), 1);
    try mutate(seq, seq_stub, .sequence, testdata.file("mermaid/jison/errors_sequence.json"), 2);
}

test "a long diagram parses" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "flowchart TD\n");
    for (0..5000) |i| try text.print(gpa, "N{d}[label {d}] --> N{d}\n", .{ i, i, i + 1 });
    try std.testing.expect(try parseText(flow, flow_stub, .flow, text.items));
}
