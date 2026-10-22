const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const files = @import("files.zig");

const tail = @embedFile("unicode_tail.zig.in");

const cat_names = [_][]const u8{ "letter", "mark", "number", "punctuation", "symbol", "space_separator", "other_separator", "other" };
const fnv_offset: u64 = 0xCBF29CE484222325;
const fnv_prime: u64 = 0x100000001B3;
const max_cp = 0x110000;

const Mapping = std.AutoHashMapUnmanaged(u32, []const u32);

const Run = struct { cp: u32, len: u32, stride: u32, delta: i64 };
const Multi = struct { cp: u32, seq: []const u32 };

pub const Stats = struct {
    category_ranges: usize,
    lower_runs: usize,
    lower_multi: usize,
    lower_pool: usize,
    fold_runs: usize,
    fold_multi: usize,
    fold_pool: usize,
};

pub const Generated = struct { text: []u8, stats: Stats };

fn catIndex(gc: []const u8) u8 {
    if (std.mem.eql(u8, gc, "Zs")) return 5;
    if (std.mem.eql(u8, gc, "Zl") or std.mem.eql(u8, gc, "Zp")) return 6;
    return switch (gc[0]) {
        'L' => 0,
        'M' => 1,
        'N' => 2,
        'P' => 3,
        'S' => 4,
        else => 7,
    };
}

fn hex(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 16);
}

fn hexSeq(arena: Allocator, s: []const u8) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| try out.append(arena, try hex(tok));
    return out.items;
}

fn dataLine(line: []const u8) []const u8 {
    const body = if (std.mem.findScalar(u8, line, '#')) |i| line[0..i] else line;
    return std.mem.trim(u8, body, " \t\r\n");
}

fn readUnicodeData(arena: Allocator, text: []const u8, lower: *Mapping) ![]u8 {
    const cats = try arena.alloc(u8, max_cp);
    @memset(cats, 7);
    var first: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields: [15][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, ';');
        while (it.next()) |f| : (n += 1) {
            if (n < fields.len) fields[n] = f;
        }
        if (n < 14) continue;
        const cp = try hex(fields[0]);
        const name = fields[1];
        const c = catIndex(fields[2]);
        if (std.mem.endsWith(u8, name, ", First>")) {
            first = cp;
            continue;
        }
        const lo = if (std.mem.endsWith(u8, name, ", Last>")) first else cp;
        @memset(cats[lo .. cp + 1], c);
        if (fields[13].len > 0) {
            const seq = try arena.alloc(u32, 1);
            seq[0] = try hex(fields[13]);
            try lower.put(arena, cp, seq);
        }
    }
    return cats;
}

fn readSpecialLower(arena: Allocator, text: []const u8, lower: *Mapping) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = dataLine(raw);
        if (line.len == 0) continue;
        var parts: [5][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, ';');
        while (it.next()) |p| : (n += 1) {
            if (n < parts.len) parts[n] = std.mem.trim(u8, p, " \t");
        }
        if (n < 5 or parts[4].len != 0) continue;
        try lower.put(arena, try hex(parts[0]), try hexSeq(arena, parts[1]));
    }
}

fn readFold(arena: Allocator, text: []const u8) !Mapping {
    var fold: Mapping = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = dataLine(raw);
        if (line.len == 0) continue;
        var parts: [3][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, ';');
        while (it.next()) |p| : (n += 1) {
            if (n < parts.len) parts[n] = std.mem.trim(u8, p, " \t");
        }
        if (n < 3) return error.BadCaseFolding;
        if (!std.mem.eql(u8, parts[1], "C") and !std.mem.eql(u8, parts[1], "F")) continue;
        try fold.put(arena, try hex(parts[0]), try hexSeq(arena, parts[2]));
    }
    return fold;
}

const Single = struct { cp: u32, to: u32 };

fn singleLess(_: void, a: Single, b: Single) bool {
    return a.cp < b.cp;
}

fn multiLess(_: void, a: Multi, b: Multi) bool {
    return a.cp < b.cp;
}

fn runs(arena: Allocator, mapping: *const Mapping) !struct { []const Run, []const Multi } {
    var single: std.ArrayList(Single) = .empty;
    var multi: std.ArrayList(Multi) = .empty;
    var it = mapping.iterator();
    while (it.next()) |kv| {
        const m = kv.value_ptr.*;
        if (m.len == 1 and m[0] != kv.key_ptr.*) {
            try single.append(arena, .{ .cp = kv.key_ptr.*, .to = m[0] });
        } else if (m.len > 1) {
            try multi.append(arena, .{ .cp = kv.key_ptr.*, .seq = m });
        }
    }
    std.mem.sort(Single, single.items, {}, singleLess);
    std.mem.sort(Multi, multi.items, {}, multiLess);
    var out: std.ArrayList(Run) = .empty;
    const s = single.items;
    var i: usize = 0;
    while (i < s.len) {
        const cp = s[i].cp;
        const delta = @as(i64, s[i].to) - cp;
        var best_n: usize = 1;
        var best_stride: u32 = 1;
        for ([_]u32{ 1, 2 }) |stride| {
            var n: usize = 1;
            while (i + n < s.len and s[i + n].cp == cp + n * stride and @as(i64, s[i + n].to) - s[i + n].cp == delta) n += 1;
            if (n > best_n and n > 1) {
                best_n = n;
                best_stride = stride;
            }
        }
        try out.append(arena, .{ .cp = cp, .len = @intCast(best_n), .stride = best_stride, .delta = delta });
        i += best_n;
    }
    return .{ out.items, multi.items };
}

fn fnv(h: u64, value: u32) u64 {
    var out = h;
    for (std.mem.asBytes(&std.mem.nativeToLittle(u32, value))) |b| out = (out ^ b) *% fnv_prime;
    return out;
}

fn categoryHash(cats: []const u8) u64 {
    var h = fnv_offset;
    for (cats) |c| h = (h ^ c) *% fnv_prime;
    return h;
}

fn mappingHash(mapping: *const Mapping) u64 {
    var h = fnv_offset;
    var cp: u32 = 0;
    while (cp < max_cp) : (cp += 1) {
        if (mapping.get(cp)) |m| {
            h = fnv(h, @intCast(m.len));
            for (m) |x| h = fnv(h, x);
        } else {
            h = fnv(h, 1);
            h = fnv(h, cp);
        }
    }
    return h;
}

fn array(w: *Writer, name: []const u8, kind: []const u8, values: []const i64) Writer.Error!void {
    try w.print("const {s} = [_]{s}{{\n", .{ name, kind });
    var i: usize = 0;
    while (i < values.len) : (i += 16) {
        if (i > 0) try w.writeByte('\n');
        try w.writeAll("   ");
        for (values[i..@min(i + 16, values.len)], 0..) |v, k| {
            if (k > 0) try w.writeByte(',');
            try w.print(" {d}", .{v});
        }
        try w.writeByte(',');
    }
    try w.writeAll("\n};");
}

fn uintType(top: u64) []const u8 {
    inline for (.{ 8, 16, 32, 64 }) |bits| {
        if (bits == 64 or top < (@as(u64, 1) << bits)) return std.fmt.comptimePrint("u{d}", .{bits});
    }
    unreachable;
}

fn intType(low: i64, high: i64) []const u8 {
    inline for (.{ 8, 16, 32, 64 }) |bits| {
        if (bits == 64 or (-(@as(i64, 1) << (bits - 1)) <= low and high < (@as(i64, 1) << (bits - 1)))) return std.fmt.comptimePrint("i{d}", .{bits});
    }
    unreachable;
}

const MappingStats = struct { runs: usize, multi: usize, pool: usize, longest: usize };

fn emitMapping(arena: Allocator, w: *Writer, name: []const u8, mapping: *const Mapping) !MappingStats {
    const rs, const multi = try runs(arena, mapping);
    var pool: std.ArrayList(i64) = .empty;
    var multi_at: std.ArrayList(i64) = .empty;
    for (multi) |m| {
        try multi_at.append(arena, @intCast(pool.items.len));
        for (m.seq) |x| try pool.append(arena, x);
    }
    var max_len: u64 = 0;
    var max_stride: u64 = 0;
    var min_delta: i64 = 0;
    var max_delta: i64 = 0;
    for (rs, 0..) |r, i| {
        max_len = @max(max_len, r.len);
        max_stride = @max(max_stride, r.stride);
        if (i == 0) {
            min_delta = r.delta;
            max_delta = r.delta;
        }
        min_delta = @min(min_delta, r.delta);
        max_delta = @max(max_delta, r.delta);
    }
    var max_multi_len: u64 = 0;
    var longest: usize = 1;
    for (multi) |m| {
        max_multi_len = @max(max_multi_len, m.seq.len);
        longest = @max(longest, m.seq.len);
    }
    var max_multi_at: u64 = 0;
    var max_pool: u64 = 0;
    for (multi_at.items) |x| max_multi_at = @max(max_multi_at, @as(u64, @intCast(x)));
    for (pool.items) |x| max_pool = @max(max_pool, @as(u64, @intCast(x)));
    const len_t = uintType(max_len);
    const stride_t = uintType(max_stride);
    const delta_t = intType(min_delta, max_delta);
    const multi_len_t = uintType(max_multi_len);
    const multi_at_t = uintType(max_multi_at);
    const pool_t = if (max_pool < 0x10000) "u16" else "u21";

    var start_lo: std.ArrayList(i64) = .empty;
    var start_hi: std.ArrayList(i64) = .empty;
    var lens: std.ArrayList(i64) = .empty;
    var strides: std.ArrayList(i64) = .empty;
    var deltas: std.ArrayList(i64) = .empty;
    for (rs) |r| {
        try start_lo.append(arena, r.cp & 0xFFFF);
        try start_hi.append(arena, r.cp >> 16);
        try lens.append(arena, r.len);
        try strides.append(arena, r.stride);
        try deltas.append(arena, r.delta);
    }
    var multi_lo: std.ArrayList(i64) = .empty;
    var multi_hi: std.ArrayList(i64) = .empty;
    var multi_lens: std.ArrayList(i64) = .empty;
    for (multi) |m| {
        try multi_lo.append(arena, m.cp & 0xFFFF);
        try multi_hi.append(arena, m.cp >> 16);
        try multi_lens.append(arena, @intCast(m.seq.len));
    }

    const Part = struct { suffix: []const u8, kind: []const u8, values: []const i64 };
    const parts = [_]Part{
        .{ .suffix = "start_lo", .kind = "u16", .values = start_lo.items },
        .{ .suffix = "start_hi", .kind = "u8", .values = start_hi.items },
        .{ .suffix = "len", .kind = len_t, .values = lens.items },
        .{ .suffix = "stride", .kind = stride_t, .values = strides.items },
        .{ .suffix = "delta", .kind = delta_t, .values = if (rs.len == 0) &[_]i64{} else deltas.items },
        .{ .suffix = "multi_lo", .kind = "u16", .values = multi_lo.items },
        .{ .suffix = "multi_hi", .kind = "u8", .values = multi_hi.items },
        .{ .suffix = "multi_len", .kind = multi_len_t, .values = multi_lens.items },
        .{ .suffix = "multi_at", .kind = multi_at_t, .values = multi_at.items },
        .{ .suffix = "pool", .kind = pool_t, .values = pool.items },
    };
    for (parts) |p| {
        const full = try std.fmt.allocPrint(arena, "{s}_{s}", .{ name, p.suffix });
        try array(w, full, p.kind, p.values);
        try w.writeAll("\n\n");
    }
    try w.print("const {s}_map: Mapping({s}, {s}, {s}, {s}, {s}, {s}) = .{{\n", .{ name, len_t, stride_t, delta_t, multi_len_t, multi_at_t, pool_t });
    for (parts) |p| try w.print("    .{s} = &{s}_{s},\n", .{ p.suffix, name, p.suffix });
    try w.writeAll("};");
    return .{ .runs = rs.len, .multi = multi.len, .pool = pool.items.len, .longest = longest };
}

pub fn generate(arena: Allocator, ucd: []const u8, special: []const u8, folding: []const u8) !Generated {
    var lower: Mapping = .empty;
    const cats = try readUnicodeData(arena, ucd, &lower);
    try readSpecialLower(arena, special, &lower);
    const fold = try readFold(arena, folding);

    var keys_lo: std.ArrayList(i64) = .empty;
    var keys_hi: std.ArrayList(i64) = .empty;
    var prev: i32 = -1;
    for (cats, 0..) |c, cp| {
        if (c != prev) {
            const key = cp << 3 | c;
            try keys_lo.append(arena, @intCast(key & 0xFFFF));
            try keys_hi.append(arena, @intCast(key >> 16));
            prev = c;
        }
    }

    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("// Generated by tools/gen_unicode.zig from the Unicode Character Database. Do not edit.\n\n");
    try w.writeAll("const std = @import(\"std\");\n\n");
    try w.writeAll("pub const Category = enum(u3) { ");
    for (cat_names, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(n);
    }
    try w.writeAll(" };\n\n");
    try array(w, "category_key_lo", "u16", keys_lo.items);
    try w.writeAll("\n\n");
    try array(w, "category_key_hi", "u8", keys_hi.items);
    try w.writeAll("\n\n");
    var low_buf: Writer.Allocating = .init(arena);
    const low = try emitMapping(arena, &low_buf.writer, "lower", &lower);
    var fold_buf: Writer.Allocating = .init(arena);
    const fld = try emitMapping(arena, &fold_buf.writer, "fold", &fold);
    try w.print("pub const max_mapping_len = {d};\n\n", .{@max(low.longest, fld.longest)});
    try w.print("{s}\n\n{s}\n\n", .{ low_buf.written(), fold_buf.written() });
    try w.print("const category_hash: u64 = {d};\nconst lower_hash: u64 = {d};\nconst fold_hash: u64 = {d};\n\n", .{
        categoryHash(cats), mappingHash(&lower), mappingHash(&fold),
    });
    const body = if (std.mem.indexOfScalar(u8, tail, '\r') != null) try std.mem.replaceOwned(u8, arena, tail, "\r\n", "\n") else tail;
    try w.writeAll(body);
    return .{ .text = aw.written(), .stats = .{
        .category_ranges = keys_lo.items.len,
        .lower_runs = low.runs,
        .lower_multi = low.multi,
        .lower_pool = low.pool,
        .fold_runs = fld.runs,
        .fold_multi = fld.multi,
        .fold_pool = fld.pool,
    } };
}

pub fn main(init: std.process.Init) !void {
    const a = try files.args(init, 2, "gen-unicode <UnicodeData.txt> <out.zig>");
    const arena = init.arena.allocator();
    const base = std.fs.path.dirname(a[0]) orelse ".";
    const ucd = try files.read(init.io, arena, a[0]);
    const special = try files.read(init.io, arena, try std.fs.path.join(arena, &.{ base, "SpecialCasing.txt" }));
    const folding = try files.read(init.io, arena, try std.fs.path.join(arena, &.{ base, "CaseFolding.txt" }));
    const g = try generate(arena, ucd, special, folding);
    try files.write(init.io, a[1], g.text);
    const s = g.stats;
    files.say(init.io, "category ranges: {d}, lower runs: {d} + {d} multi ({d} pool), fold runs: {d} + {d} multi ({d} pool)\n", .{
        s.category_ranges, s.lower_runs, s.lower_multi, s.lower_pool, s.fold_runs, s.fold_multi, s.fold_pool,
    });
}
