const std = @import("std");
const box_fuzz = @import("../box/fuzz.zig");
const recursive = @import("../recursive_layout.zig");

pub const corpus = box_fuzz.corpus;

pub fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: box_fuzz.Reader = .{ .bytes = input };
    const root = try box_fuzz.randomGraph(a, &r, "rectpacking");
    const o = &root.opts;
    o.rp_width_approximation_strategy = if (r.next() % 4 == 0) .target_width else .greedy;
    o.rp_target_width = if (r.next() % 2 == 0) null else 1 + @as(f64, @floatFromInt(r.next())) * 2;
    o.rp_optimization_goal = switch (r.next() % 4) {
        0 => .aspect_ratio_driven,
        1 => .area_driven,
        else => null,
    };
    o.rp_last_place_shift = if (r.next() % 4 == 0) false else null;
    o.rp_packing_strategy = switch (r.next() % 4) {
        0 => .simple,
        1 => .none,
        else => null,
    };
    o.rp_row_height_reevaluation = if (r.next() % 4 == 0) true else null;
    o.rp_compaction_iterations = if (r.next() % 3 == 0) 1 + @as(i32, r.next() % 3) else null;
    o.rp_white_space_elimination = switch (r.next() % 4) {
        0 => .equal_between_structures,
        1 => .to_aspect_ratio,
        else => null,
    };
    o.rp_trybox = if (r.next() % 4 == 0) true else null;
    recursive.layout(a, root) catch return;
    try box_fuzz.checkFinite(root);
}
