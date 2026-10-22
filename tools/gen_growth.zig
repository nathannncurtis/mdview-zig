const std = @import("std");
const Allocator = std.mem.Allocator;
const files = @import("files.zig");
const packed_table = @import("packed_table.zig");
const gen_unicode = @import("gen_unicode.zig");

const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_+-";

fn randomText(arena: Allocator, rng: std.Random, max_chars: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const chars = rng.intRangeAtMost(usize, 1, max_chars);
    for (0..chars) |_| {
        const cp: u21 = switch (rng.uintLessThan(u8, 4)) {
            0 => rng.intRangeAtMost(u21, 0x21, 0x7E),
            1 => rng.intRangeAtMost(u21, 0xA0, 0x7FF),
            2 => rng.intRangeAtMost(u21, 0x800, 0xD7FF),
            else => rng.intRangeAtMost(u21, 0x10000, 0x1FAFF),
        };
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}

fn synthetic(arena: Allocator, count: usize, max_value_chars: usize, seed: u64) ![]const packed_table.Entry {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var entries: std.ArrayList(packed_table.Entry) = .empty;
    while (entries.items.len < count) {
        const name = try arena.alloc(u8, rng.intRangeAtMost(usize, 1, 40));
        for (name) |*c| c.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
        if ((try seen.getOrPut(arena, name)).found_existing) continue;
        try entries.append(arena, .{ .name = name, .value = try randomText(arena, rng, max_value_chars) });
    }
    return entries.items;
}

fn expectMarkers(io: std.Io, text: []const u8, markers: []const []const u8) !void {
    for (markers) |m| if (std.mem.find(u8, text, m) == null) {
        files.say(io, "generated code is missing: {s}\n", .{m});
        return error.MissingMarker;
    };
}

fn writeTable(arena: Allocator, io: std.Io, dir: []const u8, name: []const u8, entries: []const packed_table.Entry, markers: []const []const u8) !void {
    const r = try packed_table.source(arena, entries, "//", "test \"smoke\" {}", packed_table.block_size);
    try expectMarkers(io, r.text, markers);
    try files.write(io, try std.fs.path.join(arena, &.{ dir, name }), r.text);
}

fn unicodeLine(arena: Allocator, cp: u32, name: []const u8, gc: []const u8, lower: ?u32) ![]const u8 {
    const low = if (lower) |l| try std.fmt.allocPrint(arena, "{X:0>4}", .{l}) else "";
    return std.fmt.allocPrint(arena, "{X:0>4};{s};{s};0;L;;;;;N;;;;{s};", .{ cp, name, gc, low });
}

const Line = struct { cp: u32, text: []const u8 };

fn lineLess(_: void, a: Line, b: Line) bool {
    return a.cp < b.cp;
}

fn writeUnicode(arena: Allocator, io: std.Io, dir: []const u8) !void {
    var lines: std.ArrayList(Line) = .empty;
    const fixed = [_]struct { cp: u32, name: []const u8, gc: []const u8, lower: ?u32 }{
        .{ .cp = 0x41, .name = "LATIN CAPITAL LETTER A", .gc = "Lu", .lower = 0x61 },
        .{ .cp = 0x61, .name = "LATIN SMALL LETTER A", .gc = "Ll", .lower = null },
        .{ .cp = 0x20, .name = "SPACE", .gc = "Zs", .lower = null },
        .{ .cp = 0x4E00, .name = "<CJK, First>", .gc = "Lo", .lower = null },
        .{ .cp = 0x9FFF, .name = "<CJK, Last>", .gc = "Lo", .lower = null },
    };
    for (fixed) |f| try lines.append(arena, .{ .cp = f.cp, .text = try unicodeLine(arena, f.cp, f.name, f.gc, f.lower) });
    for (0..700) |i| {
        const cp: u32 = @intCast(0x1000 + i);
        try lines.append(arena, .{ .cp = cp, .text = try unicodeLine(arena, cp, try std.fmt.allocPrint(arena, "LONG RUN {d}", .{i}), "Lu", @intCast(0x21000 + i)) });
    }
    for (0..600) |i| {
        const cp: u32 = @intCast(0x3000 + 2 * i);
        try lines.append(arena, .{ .cp = cp, .text = try unicodeLine(arena, cp, try std.fmt.allocPrint(arena, "ALTERNATING {d}", .{i}), "Lu", cp + 1) });
    }
    for (0..4) |i| {
        const cp: u32 = @intCast(0x10F000 + i);
        try lines.append(arena, .{ .cp = cp, .text = try unicodeLine(arena, cp, try std.fmt.allocPrint(arena, "FAR {d}", .{i}), "Lu", @intCast(0x20 + i)) });
    }
    std.mem.sort(Line, lines.items, {}, lineLess);
    var data: std.ArrayList(u8) = .empty;
    for (lines.items) |l| {
        try data.appendSlice(arena, l.text);
        try data.append(arena, '\n');
    }

    const special = "2000; 1D400 1D401 1D402 1D403 1D404; 2000; 2000; # five codepoints, two above the BMP\n";
    var folding: std.ArrayList(u8) = .empty;
    try folding.appendSlice(arena, "0041; C; 0061; # A\n");
    for (0..14000) |i| {
        try folding.print(arena, "{X}; F;", .{0x30000 + i});
        for (0..5) |k| try folding.print(arena, " {X}", .{0x1D400 + (i + k) % 90});
        try folding.appendSlice(arena, "; # synthetic\n");
    }

    const g = try gen_unicode.generate(arena, data.items, special, folding.items);
    try expectMarkers(io, g.text, &.{
        "pub const max_mapping_len = 5;",
        "const lower_len = [_]u16",
        "const lower_delta = [_]i32",
        "const fold_pool = [_]u21",
        "const fold_multi_at = [_]u32",
        "const fold_multi_len = [_]u8",
    });
    try files.write(io, try std.fs.path.join(arena, &.{ dir, "unicode_wide.zig" }), g.text);
}

pub fn main(init: std.process.Init) !void {
    const a = try files.args(init, 1, "gen-growth <out dir>");
    const arena = init.arena.allocator();
    const io = init.io;
    try writeTable(arena, io, a[0], "packed_four_times.zig", try synthetic(arena, 4 * 2125 + 4 * 1913, 8, 1), &.{"const Raw = u32;"});
    try writeTable(arena, io, a[0], "packed_u32_restarts.zig", try synthetic(arena, 12000, 4, 2), &.{"[_]u32{"});
    try writeTable(arena, io, a[0], "packed_u64_refs.zig", try synthetic(arena, 400, 300, 3), &.{"const Raw = u64;"});
    try writeUnicode(arena, io, a[0]);
}
