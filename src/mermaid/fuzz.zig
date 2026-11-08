const std = @import("std");
const flowchart = @import("flowchart_lib.zig");

const max_input = 8192;

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var b: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(b[i * s.len ..][0..s.len], s);
        const out = b;
        return &out;
    }
}

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

const flow_corpus = [_][]const u8{
    seed("flowchart TD\n  A[Start] --> B{Is it?}\n  B -->|Yes| C[OK]\n  C --> D[Rethink]\n  D --> B\n  B ---->|No| E[End]\n"),
    seed("flowchart LR\n  subgraph one [Group]\n    direction TB\n    a --> b\n  end\n  subgraph two\n    c --> d\n  end\n  one --> two\n  b --> d\n"),
    seed("flowchart TB\n  A --> A\n  A -->|loop| A\n  subgraph S\n    B --> B\n  end\n  S --> S\n"),
    seed("graph TD;\n  A((c)) --> B(r) --> C([s]) --> D[[x]] --> E[(db)] --> F{{h}} --> G[/l/] --> H[\\b\\] --> I(((d)))\n"),
    seed("flowchart TD\n  classDef hot fill:#f96,stroke:#333\n  A:::hot --> B\n  style B fill:#bbf\n  linkStyle 0 stroke:#ff3\n  click A href \"https://example.com\" _blank\n"),
    seed("flowchart TD\n  A@{ shape: cyl, label: \"DB\" } --> B@{ icon: \"fa:bell\", form: square, label: \"x\" }\n  B --> C@{ img: \"a.png\", label: \"p\", pos: b }\n"),
    seed("flowchart TD\n  A[\"`**bold** *it*`\"] --> B[a<br/>b<script>x</script><b>y]\n"),
    seed("flowchart TD\n" ++ rep("  subgraph s\n", 100) ++ "  a\n" ++ rep("  end\n", 100)),
    seed("flowchart TD\n" ++ rep("  A --> B\n", 300)),
    seed("flowchart TD\n  A[" ++ rep("x", 3000) ++ "] --> B\n"),
    seed("flowchart TD\n  A --> B\n  A@{ shape: " ++ rep("(", 500)),
    seed(rep("flowchart TD\n  a --> b\n", 100) ++ rep("&#x41;<", 200)),
};

fn measureWidth(_: *anyopaque, text: []const u8, _: flowchart.model.FontSpec) f64 {
    return 8 * @as(f64, @floatFromInt(text.len));
}

fn flowOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: flowchart.model.Config = .{};
    var dummy: u8 = 0;
    const ctx: flowchart.model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = measureWidth }, .cfg = &cfg, .diagram_id = "diagram" };
    _ = try flowchart.flowchart.renderSource(&ctx, std.testing.allocator, input, .{});
}

test "fuzz flowchart.render" {
    try std.testing.fuzz({}, flowOne, .{ .corpus = &flow_corpus });
}
