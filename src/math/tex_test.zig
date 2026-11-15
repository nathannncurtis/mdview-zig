const std = @import("std");
const parser = @import("parser.zig");
const mhchem = @import("mhchem.zig");
const tree = @import("tree.zig");

test {
    _ = @import("lexer.zig");
    _ = @import("macros.zig");
    _ = @import("tables.zig");
    _ = @import("parser.zig");
    _ = @import("regex.zig");
    _ = @import("mhchem.zig");
}

const testdata = @import("testdata");

const reference = testdata.file("math/tex_errors.tsv");
const expected_trees = testdata.file("math/trees.tsv");
const commands = testdata.file("math/commands.tsv");

test "error strings match MathJax 3.2.2" {
    const a = std.testing.allocator;
    var bad: usize = 0;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, reference, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
        const src = line[0..tab];
        const want = line[tab + 1 ..];
        total += 1;
        var t = try parser.parse(a, src, .{});
        defer t.deinit();
        const got = t.err orelse "";
        if (!std.mem.eql(u8, got, want)) {
            bad += 1;
            std.debug.print("MISMATCH {s}\n  want: {s}\n  got:  {s}\n", .{ src, want, got });
        }
    }
    try std.testing.expect(total > 800);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "commands and environments are accepted exactly as MathJax accepts them" {
    const a = std.testing.allocator;
    var bad: usize = 0;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, commands, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab];
        const accepted = std.mem.eql(u8, line[tab + 1 ..], "accepted");
        const is_env = std.mem.startsWith(u8, name, "env:");
        const src = if (is_env) try std.fmt.allocPrint(a, "\\begin{{{s}}}", .{name[4..]}) else try std.fmt.allocPrint(a, "\\{s}", .{name});
        defer a.free(src);
        var t = try parser.parse(a, src, .{});
        defer t.deinit();
        total += 1;
        const rejected = if (is_env)
            t.err != null and std.mem.startsWith(u8, t.err.?, "Unknown environment")
        else
            t.root.len > 0 and t.root[0] == .undefined_cs;
        if (rejected == accepted) {
            bad += 1;
            std.debug.print("COMMAND {s}: MathJax {s}, parser {s}\n", .{ name, line[tab + 1 ..], if (rejected) "rejects" else "accepts" });
        }
    }
    try std.testing.expect(total > 900);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "mhchem output matches mhchemParser" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var bad: usize = 0;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, testdata.file("math/mhchem.tsv"), '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const t2 = std.mem.indexOfScalarPos(u8, line, t1 + 1, '\t') orelse continue;
        const kind = line[0..t1];
        const input = line[t1 + 1 .. t2];
        const want = line[t2 + 1 ..];
        total += 1;
        var err: ?[]const u8 = null;
        const tex = try mhchem.toTex(arena.allocator(), input, kind, &err);
        const got = if (tex) |x| x else try std.fmt.allocPrint(arena.allocator(), "!{s}", .{err orelse "?"});
        if (!std.mem.eql(u8, got, want)) {
            bad += 1;
            std.debug.print("MHCHEM {s} {s}\n  want: {s}\n  got:  {s}\n", .{ kind, input, want, got });
        }
    }
    try std.testing.expect(total > 350);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "links, styles, verbatim text and cases text" {
    var t = try parseOk("\\href{https://example.com/a}{x}");
    defer t.deinit();
    try std.testing.expectEqualStrings("https://example.com/a", t.root[0].link.url);
    var u = try parseOk("\\href{javascript:alert(1)}{x}");
    defer u.deinit();
    try std.testing.expect(u.root[0] != .link);
    var s = try parseOk("\\style{color: red; background-color: yellow; border: 1px solid blue}{x}");
    defer s.deinit();
    try std.testing.expect(s.root[0] == .enclose);
    try std.testing.expect(s.root[0].enclose.border);
    try std.testing.expectEqualStrings("yellow", s.root[0].enclose.bg.?.name);
    try std.testing.expect(s.root[0].enclose.body[0] == .color);
    var v = try parseOk("\\verb|a%b  c|");
    defer v.deinit();
    try std.testing.expectEqualStrings("a%b\u{a0}\u{a0}c", v.root[0].text.str);
    var c = try parseOk("\\cases{1 & x > 0 \\cr 0 & \\text{else}}");
    defer c.deinit();
    const arr = c.root[0].array;
    try std.testing.expectEqual(@as(usize, 2), arr.rows.len);
    try std.testing.expect(arr.rows[0].cells[1][0] == .style);
    try std.testing.expect(arr.rows[1].cells[1][0] == .text);
    var b = try parseOk("\\bbox[2pt, red, border:1px solid blue]{x}");
    defer b.deinit();
    try std.testing.expect(b.root[0].enclose.border);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), b.root[0].enclose.padding, 1e-6);
}

test "trees of the common constructs" {
    const a = std.testing.allocator;
    var bad: usize = 0;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, expected_trees, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        total += 1;
        var t = try parser.parse(a, line[0..tab], .{});
        defer t.deinit();
        const got = try parser.dump(a, t.root);
        defer a.free(got);
        if (!std.mem.eql(u8, got, line[tab + 1 ..])) {
            bad += 1;
            std.debug.print("TREE {s}\n  want: {s}\n  got:  {s}\n", .{ line[0..tab], line[tab + 1 ..], got });
        }
    }
    try std.testing.expect(total >= 80);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

fn parseOk(src: []const u8) !tree.Tree {
    const t = try parser.parse(std.testing.allocator, src, .{});
    return t;
}

test "array layout fields" {
    var t = try parseOk("\\begin{array}{c|cc} \\hline a & b & c \\\\[2pt] \\hline \\hline d \\\\ \\hline \\end{array}");
    defer t.deinit();
    try std.testing.expect(t.err == null);
    const arr = t.root[0].array;
    try std.testing.expectEqual(@as(usize, 3), arr.cols.len);
    try std.testing.expectEqual(@as(u8, 0), arr.cols[0].rules_before);
    try std.testing.expectEqual(@as(u8, 1), arr.cols[1].rules_before);
    try std.testing.expectEqual(@as(usize, 2), arr.rows.len);
    try std.testing.expectEqual(@as(u8, 1), arr.rows[0].hlines_before);
    try std.testing.expectEqual(@as(u8, 2), arr.rows[1].hlines_before);
    try std.testing.expectEqual(@as(u8, 1), arr.trailing_hlines);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), arr.rows[0].gap_after, 1e-6);
    try std.testing.expectEqual(@as(usize, 3), arr.rows[0].cells.len);
}

test "undefined commands become red-name nodes and parsing continues" {
    var t = try parseOk("a \\foo b \\baz{c}");
    defer t.deinit();
    try std.testing.expect(t.err == null);
    try std.testing.expectEqualStrings("\\foo", t.root[1].undefined_cs);
    try std.testing.expectEqualStrings("\\baz", t.root[3].undefined_cs);
    try std.testing.expectEqual(@as(usize, 5), t.root.len);
}

test "macros do not carry across expressions" {
    var a = try parseOk("\\newcommand{\\z}{x}\\z");
    defer a.deinit();
    try std.testing.expect(a.root[0] == .atom);
    var b = try parseOk("\\z");
    defer b.deinit();
    try std.testing.expectEqualStrings("\\z", b.root[0].undefined_cs);
}

test "caps give the error box" {
    const big = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    var t = try parser.parse(std.testing.allocator, big, .{});
    defer t.deinit();
    try std.testing.expect(t.err != null);

    var u = try parser.parse(std.testing.allocator, "a b c d e f", .{ .max_nodes = 3 });
    defer u.deinit();
    try std.testing.expect(u.err != null);

    var v = try parser.parse(std.testing.allocator, "\\begin{matrix}a&b&c\\\\d&e&f\\end{matrix}", .{ .max_cells = 4 });
    defer v.deinit();
    try std.testing.expect(v.err != null);
}

test "source is never assumed to be valid UTF-8" {
    var t = try parseOk("\xff\xfe a \xc3 \\text{\xe2\x82}");
    defer t.deinit();
}
