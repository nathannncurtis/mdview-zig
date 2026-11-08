const std = @import("std");
const sequence = @import("sequence.zig");
const env = sequence.env;

fn measure(ctx: ?*anyopaque, text: []const u8, font: env.text.Font) env.text.Size {
    _ = ctx;
    return .{ .w = @as(f32, @floatFromInt(text.len)) * font.size * 0.5, .h = font.size * 1.15 };
}

fn themeGet(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
    _ = ctx;
    _ = name;
    return "#ccc";
}

var dummy: u8 = 0;

fn renderOnce(gpa: std.mem.Allocator, source: []const u8, deadline: ?*env.Deadline) !sequence.Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const res = try sequence.render(arena.allocator(), source, .{
        .theme = .{ .ctx = &dummy, .getFn = themeGet },
        .measurer = .{ .ctx = &dummy, .measure_fn = measure },
        .deadline = deadline,
    });
    switch (res) {
        .ok => |o| {
            try std.testing.expect(std.mem.startsWith(u8, o.svg, "<svg"));
            try std.testing.expect(std.mem.endsWith(u8, o.svg, "</svg>"));
            return .{ .ok = .{ .svg = "", .width = o.width, .height = o.height, .view_box = o.view_box } };
        },
        .err => return .{ .err = "" },
    }
}

const seeds = [_][]const u8{
    "sequenceDiagram\n    participant A as Alice\n    A->>+B: hi\n    B-->>-A: yo\n",
    "sequenceDiagram\n    autonumber\n    loop every\n        A->>B: x\n        alt a\n            B->>A: y\n        else b\n            Note over A,B: n\n        end\n    end\n",
    "sequenceDiagram\n    box Aqua G\n    participant A@{ \"type\": \"database\" }\n    actor B\n    end\n    create participant C\n    A->>C: made\n    destroy C\n    A-xC: bye\n",
    "sequenceDiagram\n    A()->>()B: c\n    A<<->>B: bi\n    A/|-B: r\n    link A: L @ https://x.test\n    title t <b>x</b>\n",
    "sequenceDiagram\n    rect rgb(1,2,3)\n    par p\n        A->>A: s\n    and q\n        B->>B: t\n    end\n    end\n    critical c\n        A->>B: z\n    option o\n        B->>A: w\n    end\n",
};

const insertable = "@{}[]()\"'-:+#\n ;,<>/|\\";

test "mutated input never crashes or leaks" {
    var prng = std.Random.DefaultPrng.init(0x73657131);
    const rng = prng.random();
    var buf: [512]u8 = undefined;
    for (0..600) |_| {
        const seed = seeds[rng.uintLessThan(usize, seeds.len)];
        var len = seed.len;
        @memcpy(buf[0..len], seed);
        for (0..rng.uintLessThan(usize, 8)) |_| {
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
        _ = try renderOnce(std.testing.allocator, buf[0..len], null);
    }
}

test "hostile input" {
    const gpa = std.testing.allocator;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "sequenceDiagram\n");
    for (0..400) |i| try big.print(gpa, "    P{d}->>P{d}: m{d}\n", .{ i % 7, (i + 1) % 7, i });
    _ = try renderOnce(gpa, big.items, null);

    big.clearRetainingCapacity();
    try big.appendSlice(gpa, "sequenceDiagram\n");
    for (0..120) |_| try big.appendSlice(gpa, "loop x\n");
    try big.appendSlice(gpa, "A->>B: y\n");
    for (0..120) |_| try big.appendSlice(gpa, "end\n");
    _ = try renderOnce(gpa, big.items, null);

    big.clearRetainingCapacity();
    try big.appendSlice(gpa, "sequenceDiagram\n    A->>B: wrap: ");
    try big.appendNTimes(gpa, 'w', 20_000);
    try big.append(gpa, '\n');
    _ = try renderOnce(gpa, big.items, null);

    _ = try renderOnce(gpa, "sequenceDiagram\n    A->>B: \xff\xfe\x80 \xf0\x9f\n", null);
    big.clearRetainingCapacity();
    try big.appendSlice(gpa, "sequenceDiagram\n    participant A@{ \"type\": \"");
    try big.appendNTimes(gpa, 'x', 5000);
    try big.appendSlice(gpa, "\" }\n");
    _ = try renderOnce(gpa, big.items, null);
}

var fake_now: i64 = 0;

fn fakeClock() i64 {
    fake_now += 1_000_000_000;
    return fake_now;
}

test "an expired deadline stops layout" {
    var d: env.Deadline = .{ .clock = fakeClock, .start = 0, .limit_ns = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try sequence.render(arena.allocator(), seeds[0], .{
        .theme = .{ .ctx = &dummy, .getFn = themeGet },
        .measurer = .{ .ctx = &dummy, .measure_fn = measure },
        .deadline = &d,
    });
    try std.testing.expectEqualStrings("Diagram took too long to render", res.err);
}

fn renderErr(src: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const res = try sequence.render(arena, src, .{
        .theme = .{ .ctx = &dummy, .getFn = themeGet },
        .measurer = .{ .ctx = &dummy, .measure_fn = measure },
    });
    return switch (res) {
        .err => |m| m,
        .ok => "",
    };
}

test "diagram errors carry mermaid's messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Trying to inactivate an inactive participant (A)", try renderErr("sequenceDiagram\n    deactivate A\n", a));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading 'x')", try renderErr("sequenceDiagram\n    activate Z\n    A->>B: x\n    deactivate Z\n", a));
    try std.testing.expectEqualStrings("A same participant should only be defined in one Box: A can't be in 'one' and in 'two' at the same time.", try renderErr("sequenceDiagram\n    box one\n    participant A\n    end\n    box two\n    participant A\n    end\n", a));
    try std.testing.expect(std.mem.startsWith(u8, try renderErr("sequenceDiagram\n    loop x\n    A->>B: y\n", a), "Parse error on line"));
    try std.testing.expectEqualStrings("It is not possible to have actors with the same id, even if one is destroyed before the next is created. Use 'AS' aliases to simulate the behavior", try renderErr("sequenceDiagram\n    participant A\n    create participant A\n    A->>A: x\n", a));
}

test "details reads a page element when one exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var els: std.StringHashMapUnmanaged([]const u8) = .empty;
    try els.put(a, "info", "{\"properties\": {\"class\": \"extra\"}, \"links\": {\"Docs\": \"https://x.test\"}}");
    const res = try sequence.render(a, "sequenceDiagram\n    participant A\n    details A: info\n    A->>A: x\n", .{
        .theme = .{ .ctx = &dummy, .getFn = themeGet },
        .measurer = .{ .ctx = &dummy, .measure_fn = measure },
        .elements = &els,
    });
    const svg = res.ok.svg;
    try std.testing.expect(std.mem.indexOf(u8, svg, "class=\"extra actor-top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "xlink:href=\"https://x.test\"") != null);
}

/// One fuzz input through the whole sequence pipeline; the `fuzz sequence` target in src/fuzz.zig calls this.
pub fn renderInput(gpa: std.mem.Allocator, input: []const u8) !void {
    _ = try renderOnce(gpa, input, null);
}
