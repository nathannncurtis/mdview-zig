const std = @import("std");
const mermaid = @import("mermaid.zig");

const max_input = 1024;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

pub const corpus = [_][]const u8{
    seed("\x05\x00\x01\x02\x03\x04\x03\x00\x01\x01\x02\x02\x03\x03\x04\x00\x04"),
    seed("\x08\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x01\x01\x02\x02\x03\x03\x04\x04\x05\x05\x06\x06\x07\x07\x00"),
    seed("\x0c\x05\x01\x00\x03\x01\x00\x02\x01\x00\x05\x01\x00\x20\x00\x01\x01\x02\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x00\x0b"),
    seed("\x14\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x28\x00\x13\x13\x01\x01"),
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(self: *Reader) u8 {
        if (self.bytes.len == 0) return 0;
        const b = self.bytes[self.pos % self.bytes.len];
        self.pos += 1;
        return b;
    }
};

fn isAncestor(parents: []const ?usize, anc: usize, node: usize) bool {
    var cur = parents[node];
    while (cur) |c| {
        if (c == anc) return true;
        cur = parents[c];
    }
    return false;
}

pub fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Reader = .{ .bytes = input };

    const n: usize = 1 + r.next() % 24;
    const parents = try a.alloc(?usize, n);
    const nodes = try a.alloc(mermaid.Node, n);
    const is_group = try a.alloc(bool, n);
    for (0..n) |i| is_group[i] = i + 1 < n and r.next() % 5 == 0;
    for (0..n) |i| {
        parents[i] = null;
        if (i > 0 and r.next() % 3 != 0) {
            const cand = r.next() % i;
            var g = cand;
            while (!is_group[g]) {
                if (g == 0) break;
                g -= 1;
            }
            if (is_group[g]) parents[i] = g;
        }
        const dir_byte = r.next();
        nodes[i] = .{
            .id = try std.fmt.allocPrint(a, "n{d}", .{i}),
            .parent_id = if (parents[i]) |p| try std.fmt.allocPrint(a, "n{d}", .{p}) else null,
            .is_group = is_group[i],
            .width = 10 + @as(f64, @floatFromInt(r.next())),
            .height = 10 + @as(f64, @floatFromInt(r.next() % 120)),
            .label_text = if (is_group[i]) "g" else "",
            .label_w = if (is_group[i]) 5 + @as(f64, @floatFromInt(r.next() % 90)) else 0,
            .label_h = if (is_group[i]) 22 else 0,
            .padding = 8,
            .dir = if (is_group[i] and dir_byte % 3 == 0) switch (dir_byte / 3 % 4) {
                0 => .tb,
                1 => .lr,
                2 => .bt,
                else => .rl,
            } else null,
        };
    }

    const m: usize = r.next() % 40;
    var edges: std.ArrayList(mermaid.Edge) = .empty;
    for (0..m) |k| {
        const s: usize = r.next() % n;
        const t: usize = r.next() % n;
        if (isAncestor(parents, s, t) or isAncestor(parents, t, s)) continue;
        const lab = r.next();
        try edges.append(a, .{
            .id = try std.fmt.allocPrint(a, "e{d}", .{k}),
            .start = nodes[s].id,
            .end = nodes[t].id,
            .label_text = if (lab % 2 == 1) "l" else "",
            .label_w = if (lab % 2 == 1) @floatFromInt(lab % 60) else 0,
            .label_h = if (lab % 2 == 1) 24 else 0,
            .arrow_type_end = "arrow_point",
        });
    }

    const cfg: mermaid.Config = .{ .direction = switch (r.next() % 5) {
        0 => .tb,
        1 => .td,
        2 => .bt,
        3 => .lr,
        else => .rl,
    } };
    const res = mermaid.layout(a, nodes, edges.items, cfg) catch return;
    for (res.nodes) |nd| {
        try std.testing.expect(std.math.isFinite(nd.x) and std.math.isFinite(nd.y));
    }
    for (res.edges) |ed| for (ed.points) |p| {
        try std.testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
    };
}
