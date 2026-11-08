const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const fuzz = @import("fuzz.zig");

const Result = struct { span: usize = 0, ok: bool = false };

fn measure(src: []const u8, out: *Result) void {
    var t = parser.parse(std.heap.page_allocator, src, .{}) catch return;
    defer t.deinit();
    out.* = .{ .span = t.stack_span, .ok = true };
}

fn run(src: []const u8, stack_bytes: usize) !Result {
    var r: Result = .{};
    const th = try std.Thread.spawn(.{ .stack_size = stack_bytes }, measure, .{ src, &r });
    th.join();
    return r;
}

const release_budget = 400 * 1024;
const debug_budget = 6 * 1024 * 1024;

test "stack used at the nesting cap" {
    var worst: usize = 0;
    for (fuzz.deep_cases, 0..) |src, i| {
        const r = try run(src, 16 * 1024 * 1024);
        try std.testing.expect(r.ok);
        std.debug.print("deep case {d}: stack_span={d}\n", .{ i, r.span });
        worst = @max(worst, r.span);
    }
    try std.testing.expect(worst <= if (builtin.mode == .debug) debug_budget else release_budget);
}

test "nesting to the cap fits a 1 MiB stack" {
    if (builtin.mode == .debug) return error.SkipZigTest;
    for (fuzz.deep_cases) |src| {
        const r = try run(src, 1024 * 1024);
        try std.testing.expect(r.ok);
    }
}
