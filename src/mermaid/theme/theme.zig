const std = @import("std");
const testdata = @import("testdata");
const Allocator = std.mem.Allocator;
pub const vars = @import("vars.zig");
pub const color = @import("color.zig");

const base = @import("base.zig");
const dark = @import("dark.zig");
const default_theme = @import("default.zig");
const forest = @import("forest.zig");
const neutral = @import("neutral.zig");
const neo = @import("neo.zig");
const neo_dark = @import("neo_dark.zig");
const redux = @import("redux.zig");
const redux_dark = @import("redux_dark.zig");
const redux_color = @import("redux_color.zig");
const redux_dark_color = @import("redux_dark_color.zig");

pub const Name = enum { base, dark, default, forest, neutral, neo, neo_dark, redux, redux_dark, redux_color, redux_dark_color };

/// Mermaid's `getThemeVariables(overrides)`; allocations go to `a`, which should be an arena.
pub fn compute(a: Allocator, name: Name, overrides: []const vars.Override) vars.Err!vars.Vars {
    var t: vars.Vars = .{ .a = a };
    switch (name) {
        .base => try vars.calculate(&t, base, overrides),
        .dark => try vars.calculate(&t, dark, overrides),
        .default => try vars.calculate(&t, default_theme, overrides),
        .forest => try vars.calculate(&t, forest, overrides),
        .neutral => try vars.calculate(&t, neutral, overrides),
        .neo => try vars.calculate(&t, neo, overrides),
        .neo_dark => try vars.calculate(&t, neo_dark, overrides),
        .redux => try vars.calculate(&t, redux, overrides),
        .redux_dark => try vars.calculate(&t, redux_dark, overrides),
        .redux_color => try vars.calculate(&t, redux_color, overrides),
        .redux_dark_color => try vars.calculate(&t, redux_dark_color, overrides),
    }
    return t;
}

const expected = testdata.file("mermaid/theme/vars_expected.json");

// Case 0 of each theme is listed in full; later cases list only what differs from it.
test "theme variables equal mermaid's computed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, expected, .{});
    var bases: [11]std.StringArrayHashMapUnmanaged([]const u8) = @splat(.empty);
    var compared: usize = 0;
    for (doc.array.items) |entry| {
        const name = std.meta.stringToEnum(Name, entry.object.get("theme").?.string).?;
        const case = entry.object.get("case").?.integer;
        var overrides: std.ArrayList(vars.Override) = .empty;
        if (entry.object.get("overrides").? == .object) try vars.flattenJson(a, &overrides, "", entry.object.get("overrides").?);
        const got = try compute(a, name, overrides.items);
        var want: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        const base_vars = &bases[@backingInt(name)];
        if (case == 0) {
            var it = entry.object.get("vars").?.object.iterator();
            while (it.next()) |kv| try want.put(a, kv.key_ptr.*, kv.value_ptr.string);
            base_vars.* = want;
        } else {
            var it = base_vars.iterator();
            while (it.next()) |kv| try want.put(a, kv.key_ptr.*, kv.value_ptr.*);
            var set = entry.object.get("set").?.object.iterator();
            while (set.next()) |kv| try want.put(a, kv.key_ptr.*, kv.value_ptr.string);
            for (entry.object.get("del").?.array.items) |k| _ = want.orderedRemove(k.string);
        }
        var want_it = want.iterator();
        while (want_it.next()) |kv| {
            const have = (try got.get(kv.key_ptr.*).text(a)) orelse {
                std.debug.print("{s} case {}: {s} missing\n", .{ @tagName(name), case, kv.key_ptr.* });
                return error.TestUnexpectedResult;
            };
            std.testing.expectEqualStrings(kv.value_ptr.*, have) catch |e| {
                std.debug.print("{s} case {}: {s}\n", .{ @tagName(name), case, kv.key_ptr.* });
                return e;
            };
        }
        for (got.map.keys(), got.map.values()) |k, v| {
            if (v != .undef and !want.contains(k)) {
                std.debug.print("{s} case {}: extra {s}\n", .{ @tagName(name), case, k });
                return error.TestUnexpectedResult;
            }
        }
        compared += want.count();
    }
    try std.testing.expect(compared > 10000);
}
