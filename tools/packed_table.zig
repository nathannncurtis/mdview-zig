const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const block_size = 64;

const lookup_source = @embedFile("packed_lookup.zig.in");
const round_trip_source = @embedFile("packed_round_trip.zig.in");

pub const Entry = struct { name: []const u8, value: []const u8 };

pub const Result = struct {
    text: []u8,
    names_len: usize,
    values_len: usize,
    count: usize,
};

pub fn literal(w: *Writer, data: []const u8) Writer.Error!void {
    if (data.len == 0) return w.writeAll("\"\"");
    var i: usize = 0;
    while (i < data.len) : (i += 100) {
        if (i > 0) try w.writeAll(" ++\n    ");
        try w.writeByte('"');
        for (data[i..@min(i + 100, data.len)]) |b| try escapeByte(w, b);
        try w.writeByte('"');
    }
}

pub fn escapeByte(w: *Writer, b: u8) Writer.Error!void {
    if (b == '"' or b == '\\') {
        try w.writeByte('\\');
        try w.writeByte(b);
    } else if (b >= 0x20 and b < 0x7F) {
        try w.writeByte(b);
    } else {
        try w.print("\\x{x:0>2}", .{b});
    }
}

pub fn intArray(w: *Writer, name: []const u8, ctype: []const u8, items: []const usize) Writer.Error!void {
    try w.print("const {s} = [_]{s}{{\n", .{ name, ctype });
    var i: usize = 0;
    while (i < items.len) : (i += 16) {
        try w.writeAll("   ");
        for (items[i..@min(i + 16, items.len)], 0..) |x, k| {
            if (k > 0) try w.writeByte(',');
            try w.print(" {d}", .{x});
        }
        try w.writeAll(",\n");
    }
    try w.writeAll("};");
}

pub fn bitLength(x: usize) usize {
    return @bitSizeOf(usize) - @clz(x);
}

fn nameLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn valueBefore(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len > b.len;
    return std.mem.order(u8, a, b) == .lt;
}

pub const Error = error{ UnsupportedName, NameIsPrefix, WideReferences, DuplicateName } || Allocator.Error || Writer.Error;

pub fn source(gpa: Allocator, input: []const Entry, header: []const u8, tests: []const u8, block: usize) Error!Result {
    const entries = try gpa.dupe(Entry, input);
    defer gpa.free(entries);
    std.mem.sort(Entry, entries, {}, nameLess);
    for (entries[1..], 0..) |e, i| if (std.mem.eql(u8, e.name, entries[i].name)) return error.DuplicateName;

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    var restarts: std.ArrayList(usize) = .empty;
    defer restarts.deinit(gpa);
    var max_name: usize = 0;
    var prev: []const u8 = "";
    for (entries, 0..) |e, i| {
        for (e.name) |c| if (c <= 0x20 or c >= 0x7F) return error.UnsupportedName;
        max_name = @max(max_name, e.name.len);
        var prefix: usize = 0;
        if (i % block == 0) {
            try restarts.append(gpa, stream.items.len);
        } else {
            while (prefix < @min(e.name.len, prev.len) and e.name[prefix] == prev[prefix]) prefix += 1;
        }
        if (prefix == e.name.len) return error.NameIsPrefix;
        try stream.append(gpa, @intCast(prefix));
        try stream.appendSlice(gpa, e.name[prefix..]);
        stream.items[stream.items.len - 1] |= 0x80;
        prev = e.name;
    }

    var distinct: std.ArrayList([]const u8) = .empty;
    defer distinct.deinit(gpa);
    {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for (entries) |e| if (!(try seen.getOrPut(gpa, e.value)).found_existing) try distinct.append(gpa, e.value);
    }
    std.mem.sort([]const u8, distinct.items, {}, valueBefore);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    var placed: std.StringHashMapUnmanaged(usize) = .empty;
    defer placed.deinit(gpa);
    for (distinct.items) |v| {
        const at = std.mem.find(u8, blob.items, v) orelse blk: {
            const end = blob.items.len;
            try blob.appendSlice(gpa, v);
            break :blk end;
        };
        try placed.put(gpa, v, at);
    }

    var max_off: usize = 0;
    var max_len: usize = 0;
    for (entries) |e| {
        max_off = @max(max_off, placed.get(e.value).?);
        max_len = @max(max_len, e.value.len);
    }
    const off_bits: usize = @max(bitLength(max_off), 1);
    const ref_bits: usize = off_bits + bitLength(max_len);
    if (ref_bits > 57) return error.WideReferences;
    const raw_type: []const u8, const raw_bytes: usize = if (ref_bits <= 25) .{ "u32", 4 } else .{ "u64", 8 };
    const restart_type = if (stream.items.len <= 0xFFFF) "u16" else "u32";

    const refs = try gpa.alloc(u8, (entries.len * ref_bits + 7) / 8 + raw_bytes - 1);
    defer gpa.free(refs);
    @memset(refs, 0);
    for (entries, 0..) |e, i| {
        const ref: u64 = placed.get(e.value).? | @as(u64, e.value.len) << @intCast(off_bits);
        var bit: usize = 0;
        while (bit < ref_bits) : (bit += 1) {
            if (ref >> @intCast(bit) & 1 == 1) {
                const pos = i * ref_bits + bit;
                refs[pos / 8] |= @as(u8, 1) << @intCast(pos % 8);
            }
        }
    }

    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{s}\nconst std = @import(\"std\");\n\n", .{header});
    try w.print("const count = {d};\nconst block = {d};\nconst max_name = {d};\n\n", .{ entries.len, block, max_name });
    try w.writeAll("const names = ");
    try literal(w, stream.items);
    try w.writeAll(";\n\n");
    try intArray(w, "restarts", restart_type, restarts.items);
    try w.print("\n\nconst off_bits = {d};\nconst ref_bits = {d};\nconst Raw = {s};\nconst refs = ", .{ off_bits, ref_bits, raw_type });
    try literal(w, refs);
    try w.writeAll(";\n\nconst values = ");
    try literal(w, blob.items);
    try w.print(";\n\n{s}\n\n{s}\n\n", .{ std.mem.trimEnd(u8, lookup_source, "\n"), tests });

    try w.writeAll("test \"every entry round-trips\" {\n    const expected = [_][2][]const u8{\n");
    for (entries) |e| {
        try w.print("        .{{ \"{s}\", \"", .{e.name});
        const view = std.unicode.Utf8View.initUnchecked(e.value);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try w.print("\\u{{{X}}}", .{cp});
        try w.writeAll("\" },\n");
    }
    try w.writeAll(round_trip_source);
    return .{ .text = try aw.toOwnedSlice(), .names_len = stream.items.len, .values_len = blob.items.len, .count = entries.len };
}
