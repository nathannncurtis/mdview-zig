const std = @import("std");
const mermaid = @import("mermaid.zig");

const seeds = [_][]const u8{
    "info",
    "info showInfo\ntitle x\naccTitle: y\naccDescr {z}\n",
    "---\ntitle: t\nconfig:\n  theme: forest\n  themeVariables:\n    primaryColor: '#ff0'\n---\ninfo",
    "%%{init: {\"theme\":\"base\",\"themeVariables\":{\"primaryColor\":\"#ff0000\"}}}%%\n%% c\ninfo",
    "flowchart TD\nA[<a href=\"x\">y</a>]-->B #35; style a fill:#fff;\n",
};

const insertable = "%{}[]\"'-:#\n ;";

fn renderAndFree(text: []const u8) !void {
    const r = try mermaid.render(std.testing.allocator, text, .{});
    mermaid.free(std.testing.allocator, r);
}

test "mutated input never crashes or leaks" {
    var prng = std.Random.DefaultPrng.init(0x6d6d6372);
    const rng = prng.random();
    var buf: [256]u8 = undefined;
    for (0..1500) |_| {
        const seed = seeds[rng.uintLessThan(usize, seeds.len)];
        var len = seed.len;
        @memcpy(buf[0..len], seed);
        for (0..rng.uintLessThan(usize, 6)) |_| {
            switch (rng.uintLessThan(u8, 3)) {
                0 => if (len > 0) {
                    buf[rng.uintLessThan(usize, len)] = rng.int(u8);
                },
                1 => if (len + 1 < buf.len) {
                    const at = rng.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = insertable[rng.uintLessThan(usize, insertable.len)];
                    len += 1;
                },
                else => if (len > 0) {
                    const at = rng.uintLessThan(usize, len);
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
            }
        }
        try renderAndFree(buf[0..len]);
    }
}

test "hostile input" {
    const deep = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(deep);
    @memset(deep, '[');
    for ([_][]const u8{ "%%{init: ", "---\nconfig: ", "info " }) |prefix| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, deep, "\ninfo" });
        defer std.testing.allocator.free(text);
        try renderAndFree(text);
    }
    const big = try std.testing.allocator.alloc(u8, 60_000);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try renderAndFree(big);
    try renderAndFree("info \xff\xfe\x80 \xf0\x9f");
}

fn lengthPrefixed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

const corpus = [_][]const u8{
    lengthPrefixed("info"),
    lengthPrefixed("info showInfo\ntitle x\naccTitle: y\naccDescr {z}\n"),
    lengthPrefixed("---\ntitle: t\nconfig:\n  theme: forest\n  themeVariables:\n    primaryColor: '#ff0'\n---\ninfo"),
    lengthPrefixed("%%{init: {\"theme\":\"base\",\"themeVariables\":{\"primaryColor\":\"#ff0000\"}}}%%\n%% c\ninfo"),
    lengthPrefixed("%%{init: {\"theme\": %%}%%\n\"forest\"}}%%\ninfo"),
    lengthPrefixed("---\na: &x [1, *x]\nb: !!int 0x1F\nc: *y\n---\ninfo"),
    lengthPrefixed("---\na:\n  b: 1\n c: 2\n---\ninfo"),
    lengthPrefixed("flowchart TD\nA[<a href=\"x\">y</a>]-->B #35; style a fill:#fff;\n"),
    lengthPrefixed("%%{init: {\"theme\":\"redux-color\",\"themeVariables\":{\"xyChart\":{\"titleColor\":\"#fff\"},\"primaryColor\":\"hsl(210, 50%, 40%)\"}}}%%\ninfo"),
    lengthPrefixed("info \xff\xfe\x80 \xf0\x9f\n"),
    lengthPrefixed("%%{init: [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["),
};

fn renderOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    try renderAndFree(buf[0..smith.slice(&buf)]);
}

test "fuzz mermaid.render" {
    try std.testing.fuzz({}, renderOne, .{ .corpus = &corpus });
}

const sequence_corpus = [_][]const u8{
    lengthPrefixed("participant A as Alice\nA->>+B: hi\nB-->>-A: yo\n"),
    lengthPrefixed("autonumber 5 2\nloop every\nA->>B: x\nalt a\nB->>A: y\nelse b\nNote over A,B: n\nend\nend\n"),
    lengthPrefixed("box Aqua G\nparticipant A@{ \"type\": \"database\" }\nactor B\nend\ncreate participant C\nA->>C: made\ndestroy C\nA-xC: bye\n"),
    lengthPrefixed("A()->>()B: c\nA<<->>B: bi\nA/|-B: r\nlink A: L @ https://x.test\ntitle t <b>x</b>\n"),
    lengthPrefixed("rect rgb(1,2,3)\npar p\nA->>A: s\nand q\nB->>B: t\nend\nend\ncritical c\nA->>B: z\noption o\nB->>A: w\nend\n"),
    lengthPrefixed("participant A@{\ntype: queue\nalias: Q\n}\nNote right of A: a<br/>b\nactivate A\ndeactivate A\n"),
};

fn sequenceOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    try mermaid.sequence.fuzz.renderInput(std.testing.allocator, buf[0..smith.slice(&buf)]);
}

test "fuzz mermaid.sequence" {
    try std.testing.fuzz({}, sequenceOne, .{ .corpus = &sequence_corpus });
}

const flow_max_input = 8192;

fn flowRep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var b: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(b[i * s.len ..][0..s.len], s);
        const out = b;
        return &out;
    }
}

fn flowSeed(comptime bytes: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

const flow_corpus = [_][]const u8{
    flowSeed("flowchart TD\n  A[Start] --> B{Is it?}\n  B -->|Yes| C[OK]\n  C --> D[Rethink]\n  D --> B\n  B ---->|No| E[End]\n"),
    flowSeed("flowchart LR\n  subgraph one [Group]\n    direction TB\n    a --> b\n  end\n  subgraph two\n    c --> d\n  end\n  one --> two\n  b --> d\n"),
    flowSeed("flowchart TB\n  A --> A\n  A -->|loop| A\n  subgraph S\n    B --> B\n  end\n  S --> S\n"),
    flowSeed("graph TD;\n  A((c)) --> B(r) --> C([s]) --> D[[x]] --> E[(db)] --> F{{h}} --> G[/l/] --> H[\\b\\] --> I(((d)))\n"),
    flowSeed("flowchart TD\n  classDef hot fill:#f96,stroke:#333\n  A:::hot --> B\n  style B fill:#bbf\n  linkStyle 0 stroke:#ff3\n  click A href \"https://example.com\" _blank\n"),
    flowSeed("flowchart TD\n  A@{ shape: cyl, label: \"DB\" } --> B@{ icon: \"fa:bell\", form: square, label: \"x\" }\n  B --> C@{ img: \"a.png\", label: \"p\", pos: b }\n"),
    flowSeed("flowchart TD\n  A[\"`**bold** *it*`\"] --> B[a<br/>b<script>x</script><b>y]\n"),
    flowSeed("flowchart TD\n" ++ flowRep("  subgraph s\n", 100) ++ "  a\n" ++ flowRep("  end\n", 100)),
    flowSeed("flowchart TD\n" ++ flowRep("  A --> B\n", 300)),
    flowSeed("flowchart TD\n  A[" ++ flowRep("x", 3000) ++ "] --> B\n"),
    flowSeed("flowchart TD\n  A --> B\n  A@{ shape: " ++ flowRep("(", 500)),
    flowSeed(flowRep("flowchart TD\n  a --> b\n", 100) ++ flowRep("&#x41;<", 200)),
};

fn flowOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [flow_max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const r = try mermaid.render(std.testing.allocator, input, .{});
    mermaid.free(std.testing.allocator, r);
}

test "fuzz flowchart.render" {
    try std.testing.fuzz({}, flowOne, .{ .corpus = &flow_corpus });
}
