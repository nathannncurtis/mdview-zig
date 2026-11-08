const std = @import("std");
const md = @import("markdown.zig");

pub const Axis = enum { col, row };

fn trackOf(t: md.Table, axis: Axis, row: usize, col: usize) struct { start: usize, span: usize } {
    const s = t.spanAt(row, col);
    return switch (axis) {
        .col => .{ .start = col, .span = s[0] },
        .row => .{ .start = row, .span = s[1] },
    };
}

pub fn covered(t: md.Table, row: usize, col: usize) bool {
    const s = t.spanAt(row, col);
    return s[0] == 0 or s[1] == 0;
}

pub fn sum(extents: []const f32, start: usize, span: usize) f32 {
    var x: f32 = 0;
    for (extents[start..@min(extents.len, start + span)]) |e| x += e;
    return x;
}

/// A cell spanning several tracks only grows them when it exceeds their sum, each by the same amount.
pub fn solve(out: []f32, sizes: []const f32, t: md.Table, axis: Axis) void {
    @memset(out, 0);
    const rows = t.rows();
    var widest: usize = 1;
    for (0..rows) |r| for (0..t.columns) |c| {
        if (covered(t, r, c)) continue;
        const tr = trackOf(t, axis, r, c);
        widest = @max(widest, tr.span);
        if (tr.span == 1) out[tr.start] = @max(out[tr.start], sizes[r * t.columns + c]);
    };
    for (2..widest + 1) |len| {
        for (0..rows) |r| for (0..t.columns) |c| {
            if (covered(t, r, c)) continue;
            const tr = trackOf(t, axis, r, c);
            if (tr.span != len) continue;
            const have = sum(out, tr.start, len);
            const want = sizes[r * t.columns + c];
            if (want <= have) continue;
            const add = (want - have) / @as(f32, @floatFromInt(len));
            for (out[tr.start..@min(out.len, tr.start + len)]) |*e| e.* += add;
        };
    }
}

pub fn columnWidths(out: []f32, natural: []const f32, t: md.Table, available: f32, min_width: f32) void {
    solve(out, natural, t, .col);
    md.fitColumns(out, available, min_width);
}

pub fn cellWidth(t: md.Table, widths: []const f32, row: usize, col: usize) f32 {
    if (covered(t, row, col)) return 0;
    return sum(widths, col, t.spanAt(row, col)[0]);
}

pub fn cellHeight(t: md.Table, heights: []const f32, row: usize, col: usize) f32 {
    if (covered(t, row, col)) return 0;
    return sum(heights, row, t.spanAt(row, col)[1]);
}

const testing = std.testing;

fn testTable(columns: usize, extra: *const md.Table.Extra) md.Table {
    return .{ .columns = columns, .cells = &.{}, .ext = extra };
}

test "a spanning cell widens its columns only by what is missing" {
    var t = testTable(2, &.{ .spans = &.{ .{ 2, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 1 } } });
    var cells: [4]md.Inline = undefined;
    t.cells = &cells;
    var w: [2]f32 = undefined;
    solve(&w, &.{ 100, 0, 30, 40 }, t, .col);
    try testing.expectEqual(@as(f32, 45), w[0]);
    try testing.expectEqual(@as(f32, 55), w[1]);
    solve(&w, &.{ 60, 0, 30, 40 }, t, .col);
    try testing.expectEqual(@as(f32, 30), w[0]);
    try testing.expectEqual(@as(f32, 40), w[1]);
}

test "rowspan shares the height of the rows it covers" {
    var t = testTable(2, &.{ .spans = &.{ .{ 1, 2 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 } } });
    var cells: [4]md.Inline = undefined;
    t.cells = &cells;
    var h: [2]f32 = undefined;
    solve(&h, &.{ 90, 20, 0, 20 }, t, .row);
    try testing.expectApproxEqAbs(@as(f32, 90), h[0] + h[1], 0.001);
    try testing.expectEqual(@as(f32, 90), cellHeight(t, &h, 0, 0));
    try testing.expectEqual(@as(f32, 0), cellHeight(t, &h, 1, 0));
}

test "plain tables behave as before" {
    var cells: [4]md.Inline = undefined;
    const t: md.Table = .{ .columns = 2, .cells = &cells };
    var w: [2]f32 = undefined;
    columnWidths(&w, &.{ 50, 70, 80, 10 }, t, 1000, 10);
    try testing.expectEqual(@as(f32, 80), w[0]);
    try testing.expectEqual(@as(f32, 70), w[1]);
}
