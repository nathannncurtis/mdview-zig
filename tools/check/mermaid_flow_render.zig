const std = @import("std");
const lib = @import("mermaid_flowchart");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const model = lib.model;

const Entry = struct { text: []const u8, w: f64, h: f64 };

const Replay = struct {
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    fn width(ctx: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
        const self: *Replay = @ptrCast(@alignCast(ctx));
        if (self.map.get(text)) |e| {
            if (e.h > 24.5) return 4000;
            return e.w;
        }
        return 8 * @as(f64, @floatFromInt(text.len));
    }
};

fn labelText(a: Allocator, inner: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    var space = true;
    for (inner) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isWhitespace(c)) {
            if (!space) try out.append(a, ' ');
            space = true;
        } else {
            try out.append(a, c);
            space = false;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    const raw = out.items;
    const amp = try std.mem.replaceOwned(u8, a, raw, "&amp;", "&");
    const lt = try std.mem.replaceOwned(u8, a, amp, "&lt;", "<");
    return std.mem.replaceOwned(u8, a, lt, "&gt;", ">");
}

fn attrNum(tag: []const u8, name: []const u8) f64 {
    var key_buf: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, " {s}=\"", .{name}) catch return 0;
    const at = std.mem.indexOf(u8, tag, key) orelse return 0;
    const rest = tag[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return 0;
    return std.fmt.parseFloat(f64, rest[0..end]) catch 0;
}

fn buildReplay(a: Allocator, ref: []const u8, out: *Replay) Allocator.Error!void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, ref, pos, "<foreignObject")) |s| {
        const tag_end = std.mem.indexOfScalarPos(u8, ref, s, '>') orelse break;
        const close = std.mem.indexOfPos(u8, ref, tag_end, "</foreignObject>") orelse break;
        pos = close;
        const tag = ref[s..tag_end];
        const text = try labelText(a, ref[tag_end + 1 .. close]);
        if (text.len == 0) continue;
        try out.map.put(a, text, .{ .text = text, .w = attrNum(tag, "width"), .h = attrNum(tag, "height") });
    }
}

const Pre = struct { source: []const u8, layout: []const u8, look: []const u8 };

fn preprocess(a: Allocator, raw: []const u8) Allocator.Error!Pre {
    var layout: []const u8 = "elk";
    var look: []const u8 = "neo";
    var body = raw;
    if (std.mem.startsWith(u8, raw, "---\n")) {
        if (std.mem.indexOf(u8, raw[4..], "\n---")) |e| {
            const fm = raw[4 .. 4 + e];
            var it = std.mem.splitScalar(u8, fm, '\n');
            while (it.next()) |ln| {
                const t = std.mem.trim(u8, ln, " \t\r");
                if (std.mem.startsWith(u8, t, "layout:")) layout = try a.dupe(u8, std.mem.trim(u8, t["layout:".len..], " \t'\""));
                if (std.mem.startsWith(u8, t, "look:")) look = try a.dupe(u8, std.mem.trim(u8, t["look:".len..], " \t'\""));
            }
            var rest = raw[4 + e + 4 ..];
            if (rest.len > 0 and rest[0] == '\r') rest = rest[1..];
            if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];
            body = rest;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (std.mem.startsWith(u8, t, "%%")) {
            if (std.mem.indexOf(u8, t, "\"layout\"") != null or std.mem.indexOf(u8, t, "layout:") != null) {
                if (std.mem.indexOf(u8, t, "dagre") != null) layout = "dagre";
            }
            if (std.mem.indexOf(u8, t, "classic") != null) look = "classic";
            continue;
        }
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, ln);
    }
    try out.append(a, '\n');
    return .{ .source = out.items, .layout = layout, .look = look };
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const root = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(root);
    if (args.len < 4) {
        std.log.info("usage: mermaid-flow-render <cases dir> <refs dir> <out dir> [name prefix]\n", .{});
        return error.Usage;
    }
    const cases_dir = args[1];
    const refs_dir = args[2];
    const out_dir = args[3];
    const prefix: []const u8 = if (args.len > 4) args[4] else "flow-";
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try cwd.openDir(io, cases_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.startsWith(u8, e.name, prefix) or !std.mem.endsWith(u8, e.name, ".mmd")) continue;
            try names.append(root, try root.dupe(u8, e.name[0 .. e.name.len - 4]));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var rendered: usize = 0;
    var failed: usize = 0;
    var dagre_cases: usize = 0;
    for (names.items) |name| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.mmd", .{ cases_dir, name }), a, .limited(1 << 22));
        var replay: Replay = .{};
        if (cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.svg", .{ refs_dir, name }), a, .limited(1 << 26))) |ref| {
            try buildReplay(a, ref, &replay);
        } else |_| {}
        const pre = try preprocess(a, src);
        var cfg: model.Config = .{};
        cfg.diagram_padding = 48;
        cfg.layout = pre.layout;
        cfg.look = pre.look;
        const ctx: model.Ctx = .{ .a = a, .measurer = .{ .ctx = &replay, .widthFn = Replay.width }, .cfg = &cfg, .diagram_id = "diagram" };
        if (std.mem.eql(u8, pre.layout, "dagre")) dagre_cases += 1;
        const res = try lib.flowchart.renderSource(&ctx, init.gpa, pre.source, .{});
        switch (res) {
            .ok => |o| {
                try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.svg", .{ out_dir, name }), .data = o.svg });
                rendered += 1;
            },
            .err => |m| {
                try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.err", .{ out_dir, name }), .data = m });
                failed += 1;
            },
        }
        if (std.mem.eql(u8, pre.layout, "dagre")) std.log.info("dagre case: {s}\n", .{name});
    }
    std.log.info("rendered {d}, failed {d}, explicit dagre {d}\n", .{ rendered, failed, dagre_cases });
}
