const std = @import("std");
const mermaid = @import("mermaid");
const cmp = @import("mermaid_compare");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

const Replay = struct {
    sizes: cmp.ReplayMeasurer,
    wrapped_height: f64 = 28.5,

    fn measure(ctx: ?*anyopaque, text: []const u8, _: mermaid.text.Font) mermaid.text.Size {
        const self: *const Replay = @ptrCast(@alignCast(ctx.?));
        const s = self.sizes.measure(text, "", 0, 0) catch return .{ .w = 8 * @as(f32, @floatFromInt(text.len)), .h = 18.4 };
        if (s.h > self.wrapped_height) return .{ .w = 4000, .h = 18.4 };
        return .{ .w = @floatCast(s.w), .h = 18.4 };
    }
};

fn styleOf(svg: []const u8) []const u8 {
    const s = std.mem.indexOf(u8, svg, "<style>") orelse return "";
    const e = std.mem.indexOfPos(u8, svg, s, "</style>") orelse return "";
    return svg[s..e];
}

fn sizesMatch(a: Allocator, ref: cmp.Model, cand: cmp.Model) Allocator.Error!?[]const u8 {
    var buckets: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (cand.items, 0..) |it, i| {
        if (it.kind != .box and it.kind != .label) continue;
        const gop = try buckets.getOrPut(a, it.key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, @intCast(i));
    }
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    for (ref.items) |it| {
        if (it.kind != .box and it.kind != .label) continue;
        const gop = try seen.getOrPut(a, it.key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const n = gop.value_ptr.*;
        gop.value_ptr.* += 1;
        const list = buckets.get(it.key);
        if (list == null or n >= list.?.items.len) return try std.fmt.allocPrint(a, "missing {s} #{d}", .{ it.key, n });
        const other = cand.items[list.?.items[n]];
        const dev = @max(@abs(it.w - other.w), @abs(it.h - other.h));
        if (dev > cmp.node_tolerance) return try std.fmt.allocPrint(a, "{s} #{d} ({s}) size off by {d:.2}: {d}x{d} vs {d}x{d}", .{ it.key, n, it.id, dev, it.w, it.h, other.w, other.h });
    }
    return null;
}

// Labels are drawn as text rather than foreignObject, so only groups, boxes and edges are compared.
fn withoutText(a: Allocator, m: cmp.Model) Allocator.Error!cmp.Model {
    var items: std.ArrayList(cmp.Item) = .empty;
    for (m.items) |it| if (it.kind != .label and it.kind != .text) try items.append(a, it);
    return .{ .view_box = m.view_box, .items = items.items };
}

fn isDagre(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "dagre") != null;
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const root = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(root);
    if (args.len < 3) {
        std.log.err("usage: mermaid-flow-render <cases dir> <refs dir> [out dir]", .{});
        return 2;
    }
    const cases_dir = args[1];
    const refs_dir = args[2];
    const out_dir: ?[]const u8 = if (args.len > 3) args[3] else null;
    const cwd = Dir.cwd();
    if (out_dir) |d| try cwd.createDirPath(io, d);
    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try cwd.openDir(io, cases_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.startsWith(u8, e.name, "flow-") or !std.mem.endsWith(u8, e.name, ".mmd")) continue;
            try names.append(root, try root.dupe(u8, e.name[0 .. e.name.len - 4]));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var css_ok: usize = 0;
    var sizes_ok: usize = 0;
    var dagre_total: usize = 0;
    var dagre_ok: usize = 0;
    var other_total: usize = 0;
    var other_ok: usize = 0;
    for (names.items) |name| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.mmd", .{ cases_dir, name }), a, .limited(1 << 22));
        const ref = try cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.svg", .{ refs_dir, name }), a, .limited(1 << 26));
        const side = cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.labels.json", .{ refs_dir, name }), a, .limited(1 << 24)) catch null;
        const ref_full = try cmp.extract(a, ref);
        const ref_model = try withoutText(a, ref_full);
        var replay: Replay = .{ .sizes = try cmp.ReplayMeasurer.init(a, ref_full, side) };
        const dagre = isDagre(src);
        if (dagre) dagre_total += 1 else other_total += 1;
        const tag: []const u8 = if (dagre) "dagre" else "default";
        const res = try mermaid.render(init.gpa, src, .{ .measurer = .{ .ctx = &replay, .measure_fn = Replay.measure } });
        defer mermaid.free(init.gpa, res);
        switch (res) {
            .svg => |img| {
                if (out_dir) |d| try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.svg", .{ d, name }), .data = img.bytes });
                const cand = try withoutText(a, try cmp.extract(a, img.bytes));
                const full = try cmp.compare(a, ref_model, cand);
                const style_same = std.mem.eql(u8, styleOf(ref), styleOf(img.bytes));
                const size_problem = try sizesMatch(a, ref_model, cand);
                if (style_same) css_ok += 1;
                if (size_problem == null) sizes_ok += 1;
                if (full.passed()) {
                    if (dagre) dagre_ok += 1 else other_ok += 1;
                } else std.log.info("FAIL {s} [{s}] items={d} bad={d} missing={d} extra={d} max={d:.2}: {s}", .{ name, tag, full.items, full.bad, full.missing, full.extra, full.max_dev, full.first });
                if (!style_same) {
                    const rs = styleOf(ref);
                    const cs = styleOf(img.bytes);
                    var at: usize = 0;
                    while (at < rs.len and at < cs.len and rs[at] == cs[at]) at += 1;
                    const from = at -| 60;
                    std.log.info("CSS {s} [{s}] differs at {d}: ref {s} | got {s}", .{ name, tag, at, rs[from..@min(rs.len, at + 80)], cs[from..@min(cs.len, at + 80)] });
                }
                if (size_problem) |p| std.log.info("SIZE {s} [{s}]: {s}", .{ name, tag, p });
            },
            .err => |m| std.log.info("ERROR {s} [{s}]: {s}", .{ name, tag, m }),
            .unsupported => |m| std.log.info("UNSUPPORTED {s} [{s}]: {s}", .{ name, tag, m }),
        }
    }
    std.log.info("flowchart parity over {d} cases: css {d}/{d}, sizes {d}/{d}, full layout dagre {d}/{d}, full layout default (ELK) {d}/{d}", .{
        names.items.len, css_ok,      names.items.len, sizes_ok,    names.items.len,
        dagre_ok,        dagre_total, other_ok,        other_total,
    });
    return if (css_ok == names.items.len and sizes_ok == names.items.len and dagre_ok == dagre_total) 0 else 1;
}
