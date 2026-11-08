const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml_stub");
const png = @import("png_stub");

pub const node_tolerance = 0.5;
pub const edge_tolerance = 1.0;
pub const view_box_tolerance = 1.0;
pub const channel_tolerance: u8 = 16;
pub const max_pixel_fraction = 0.01;
const page_background = [3]u8{ 13, 17, 23 };
const min_flow_cases = 150;
const min_sequence_cases = 80;
const min_error_cases = 100;

pub const Kind = enum { group, box, edge, text, label };

pub const Item = struct {
    kind: Kind,
    key: []const u8,
    id: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    pts: []const [2]f64 = &.{},
    text: []const u8 = "",
};

pub const Model = struct {
    view_box: [4]f64,
    items: []const Item,
};

const skipped = std.StaticStringMap(void).initComptime(.{
    .{ "defs", {} },    .{ "style", {} },  .{ "marker", {} },  .{ "linearGradient", {} }, .{ "radialGradient", {} },
    .{ "filter", {} },  .{ "clipPath", {} }, .{ "mask", {} }, .{ "pattern", {} },         .{ "title", {} },
    .{ "desc", {} },    .{ "symbol", {} },
});

fn number(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null;
}

fn numAttr(n: xml.Node, name: []const u8) f64 {
    return number(n.attr(name) orelse return 0) orelse 0;
}

const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(sc: *Scanner) void {
        while (sc.i < sc.s.len and (sc.s[sc.i] == ' ' or sc.s[sc.i] == ',' or sc.s[sc.i] == '\t' or sc.s[sc.i] == '\n' or sc.s[sc.i] == '\r')) sc.i += 1;
    }

    fn next(sc: *Scanner) ?f64 {
        sc.skipSep();
        const start = sc.i;
        if (sc.i < sc.s.len and (sc.s[sc.i] == '-' or sc.s[sc.i] == '+')) sc.i += 1;
        var dot = false;
        while (sc.i < sc.s.len) : (sc.i += 1) {
            const c = sc.s[sc.i];
            if (std.ascii.isDigit(c)) continue;
            if (c == '.' and !dot) {
                dot = true;
                continue;
            }
            if ((c == 'e' or c == 'E') and sc.i > start) {
                if (sc.i + 1 < sc.s.len and (sc.s[sc.i + 1] == '-' or sc.s[sc.i + 1] == '+')) sc.i += 1;
                continue;
            }
            break;
        }
        if (sc.i == start) return null;
        return std.fmt.parseFloat(f64, sc.s[start..sc.i]) catch null;
    }
};

fn translateOf(transform: ?[]const u8) [2]f64 {
    const t = transform orelse return .{ 0, 0 };
    if (std.mem.indexOf(u8, t, "translate(")) |i| {
        var sc: Scanner = .{ .s = t[i + "translate(".len ..] };
        const x = sc.next() orelse 0;
        return .{ x, sc.next() orelse 0 };
    }
    if (std.mem.indexOf(u8, t, "matrix(")) |i| {
        var sc: Scanner = .{ .s = t[i + "matrix(".len ..] };
        for (0..4) |_| _ = sc.next();
        const e = sc.next() orelse 0;
        return .{ e, sc.next() orelse 0 };
    }
    return .{ 0, 0 };
}

fn pairs(arena: Allocator, s: []const u8) Allocator.Error![]const [2]f64 {
    var out: std.ArrayList([2]f64) = .empty;
    var sc: Scanner = .{ .s = s };
    while (sc.next()) |x| {
        const y = sc.next() orelse break;
        try out.append(arena, .{ x, y });
    }
    return out.items;
}

fn pathPoints(arena: Allocator, d: []const u8) Allocator.Error![]const [2]f64 {
    var out: std.ArrayList([2]f64) = .empty;
    var sc: Scanner = .{ .s = d };
    var cx: f64 = 0;
    var cy: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var cmd: u8 = 0;
    while (true) {
        sc.skipSep();
        if (sc.i >= sc.s.len) break;
        if (std.ascii.isAlphabetic(sc.s[sc.i])) {
            cmd = sc.s[sc.i];
            sc.i += 1;
            if (cmd == 'z' or cmd == 'Z') {
                cx = sx;
                cy = sy;
            }
            continue;
        }
        const rel = std.ascii.isLower(cmd);
        const ox = if (rel) cx else 0;
        const oy = if (rel) cy else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M', 'L', 'T' => {
                const x = sc.next() orelse break;
                const y = sc.next() orelse break;
                cx = ox + x;
                cy = oy + y;
                try out.append(arena, .{ cx, cy });
                if (std.ascii.toUpper(cmd) == 'M') {
                    sx = cx;
                    sy = cy;
                    cmd = if (rel) 'l' else 'L';
                }
            },
            'H' => {
                cx = ox + (sc.next() orelse break);
                try out.append(arena, .{ cx, cy });
            },
            'V' => {
                cy = oy + (sc.next() orelse break);
                try out.append(arena, .{ cx, cy });
            },
            'C', 'S', 'Q' => {
                const n: usize = if (std.ascii.toUpper(cmd) == 'C') 3 else 2;
                for (0..n) |_| {
                    const x = sc.next() orelse break;
                    const y = sc.next() orelse break;
                    try out.append(arena, .{ ox + x, oy + y });
                }
                cx = out.items[out.items.len - 1][0];
                cy = out.items[out.items.len - 1][1];
            },
            'A' => {
                for (0..5) |_| _ = sc.next();
                const x = sc.next() orelse break;
                const y = sc.next() orelse break;
                cx = ox + x;
                cy = oy + y;
                try out.append(arena, .{ cx, cy });
            },
            else => break,
        }
    }
    return out.items;
}

fn dataPoints(arena: Allocator, b64: []const u8) ?[]const [2]f64 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return null;
    const raw = arena.alloc(u8, size) catch return null;
    std.base64.standard.Decoder.decode(raw, b64) catch return null;
    const P = struct { x: f64, y: f64 };
    const parsed = std.json.parseFromSliceLeaky([]const P, arena, raw, .{ .ignore_unknown_fields = true }) catch return null;
    const out = arena.alloc([2]f64, parsed.len) catch return null;
    for (parsed, out) |p, *o| o.* = .{ p.x, p.y };
    return out;
}

fn bounds(pts: []const [2]f64) [4]f64 {
    if (pts.len == 0) return .{ 0, 0, 0, 0 };
    var lo = pts[0];
    var hi = pts[0];
    for (pts) |p| {
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    return .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] };
}

fn classKey(arena: Allocator, tag: []const u8, class: ?[]const u8) Allocator.Error![]const u8 {
    var toks: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, class orelse "", " \t\r\n");
    while (it.next()) |t| try toks.append(arena, t);
    std.mem.sort([]const u8, toks.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, tag);
    var prev: []const u8 = "";
    for (toks.items) |t| {
        if (std.mem.eql(u8, t, prev)) continue;
        prev = t;
        try out.append(arena, '.');
        try out.appendSlice(arena, t);
    }
    return out.items;
}

fn normalized(arena: Allocator, n: xml.Node) Allocator.Error![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    try n.textContent(arena, &raw);
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw.items, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, w);
    }
    return out.items;
}

fn isEdgeClass(class: ?[]const u8) bool {
    const c = class orelse return false;
    for ([_][]const u8{ "flowchart-link", "messageLine", "edge", "relation", "transition" }) |m| {
        if (std.mem.indexOf(u8, c, m) != null) return true;
    }
    return false;
}

const Walker = struct {
    arena: Allocator,
    items: std.ArrayList(Item) = .empty,

    fn walk(w: *Walker, n: xml.Node, ox: f64, oy: f64) Allocator.Error!void {
        if (n.tag.len == 0 or skipped.has(n.tag)) return;
        const class = n.attr("class");
        const id = n.attr("id") orelse "";
        const tag = n.tag;
        const key = try classKey(w.arena, tag, class);
        if (std.mem.eql(u8, tag, "g")) {
            const t = translateOf(n.attr("transform"));
            if (n.attr("transform") != null and class != null) {
                try w.items.append(w.arena, .{ .kind = .group, .key = key, .id = id, .x = ox + t[0], .y = oy + t[1] });
            }
            for (n.kids) |k| try w.walk(k, ox + t[0], oy + t[1]);
        } else if (std.mem.eql(u8, tag, "rect")) {
            if (n.attr("width") == null) return;
            try w.items.append(w.arena, .{ .kind = .box, .key = key, .id = id, .x = ox + numAttr(n, "x"), .y = oy + numAttr(n, "y"), .w = numAttr(n, "width"), .h = numAttr(n, "height") });
        } else if (std.mem.eql(u8, tag, "circle") or std.mem.eql(u8, tag, "ellipse")) {
            const rx = if (n.attr("r") != null) numAttr(n, "r") else numAttr(n, "rx");
            const ry = if (n.attr("r") != null) rx else numAttr(n, "ry");
            try w.items.append(w.arena, .{ .kind = .box, .key = key, .id = id, .x = ox + numAttr(n, "cx") - rx, .y = oy + numAttr(n, "cy") - ry, .w = rx * 2, .h = ry * 2 });
        } else if (std.mem.eql(u8, tag, "line")) {
            const pts = try w.arena.dupe([2]f64, &.{
                .{ ox + numAttr(n, "x1"), oy + numAttr(n, "y1") },
                .{ ox + numAttr(n, "x2"), oy + numAttr(n, "y2") },
            });
            try w.items.append(w.arena, .{ .kind = .edge, .key = key, .id = id, .pts = pts });
        } else if (std.mem.eql(u8, tag, "path") or std.mem.eql(u8, tag, "polygon") or std.mem.eql(u8, tag, "polyline")) {
            const raw = if (std.mem.eql(u8, tag, "path")) try pathPoints(w.arena, n.attr("d") orelse "") else try pairs(w.arena, n.attr("points") orelse "");
            const pts = try w.arena.dupe([2]f64, raw);
            for (pts) |*p| p.* = .{ p[0] + ox, p[1] + oy };
            if (n.attr("data-points")) |b64| {
                if (dataPoints(w.arena, b64)) |dp| {
                    try w.items.append(w.arena, .{ .kind = .edge, .key = key, .id = id, .pts = dp });
                    return;
                }
            }
            if (isEdgeClass(class) or std.mem.eql(u8, tag, "polyline")) {
                try w.items.append(w.arena, .{ .kind = .edge, .key = key, .id = id, .pts = pts });
            } else {
                const b = bounds(pts);
                try w.items.append(w.arena, .{ .kind = .box, .key = key, .id = id, .x = b[0], .y = b[1], .w = b[2], .h = b[3] });
            }
        } else if (std.mem.eql(u8, tag, "text")) {
            try w.items.append(w.arena, .{ .kind = .text, .key = key, .id = id, .x = ox + numAttr(n, "x"), .y = oy + numAttr(n, "y"), .text = try normalized(w.arena, n) });
        } else if (std.mem.eql(u8, tag, "foreignObject")) {
            try w.items.append(w.arena, .{ .kind = .label, .key = key, .id = id, .x = ox + numAttr(n, "x"), .y = oy + numAttr(n, "y"), .w = numAttr(n, "width"), .h = numAttr(n, "height"), .text = try normalized(w.arena, n) });
        } else {
            for (n.kids) |k| try w.walk(k, ox, oy);
        }
    }
};

pub const ExtractError = error{ BadSvg, OutOfMemory };

pub fn extract(arena: Allocator, svg: []const u8) ExtractError!Model {
    const root = xml.parse(arena, svg) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadSvg;
    if (!std.mem.eql(u8, root.tag, "svg")) return error.BadSvg;
    var vb: [4]f64 = .{ 0, 0, 0, 0 };
    var sc: Scanner = .{ .s = root.attr("viewBox") orelse return error.BadSvg };
    for (&vb) |*v| v.* = sc.next() orelse return error.BadSvg;
    var w: Walker = .{ .arena = arena };
    for (root.kids) |k| try w.walk(k, 0, 0);
    return .{ .view_box = vb, .items = w.items.items };
}

pub const Size = struct { w: f64, h: f64 };

pub const ReplayMeasurer = struct {
    sizes: std.StringHashMapUnmanaged(Size) = .empty,
    conflicts: usize = 0,

    pub fn init(arena: Allocator, model: Model) Allocator.Error!ReplayMeasurer {
        var r: ReplayMeasurer = .{};
        for (model.items) |it| {
            if (it.kind != .label) continue;
            const gop = try r.sizes.getOrPut(arena, it.text);
            if (gop.found_existing) {
                if (gop.value_ptr.w != it.w or gop.value_ptr.h != it.h) r.conflicts += 1;
            } else gop.value_ptr.* = .{ .w = it.w, .h = it.h };
        }
        return r;
    }

    pub fn measure(r: *const ReplayMeasurer, text: []const u8, family: []const u8, size: f64, weight: u16) error{UnknownLabel}!Size {
        _ = .{ family, size, weight };
        return r.sizes.get(text) orelse error.UnknownLabel;
    }
};

pub const CaseResult = struct {
    items: usize = 0,
    bad: usize = 0,
    missing: usize = 0,
    extra: usize = 0,
    view_box_ok: bool = true,
    max_dev: f64 = 0,
    first: []const u8 = "",

    pub fn passed(r: CaseResult) bool {
        return r.bad == 0 and r.missing == 0 and r.extra == 0 and r.view_box_ok;
    }
};

fn deviation(a: Item, b: Item) f64 {
    var d: f64 = 0;
    if (a.kind == .edge) {
        if (a.pts.len != b.pts.len) return std.math.inf(f64);
        for (a.pts, b.pts) |p, q| d = @max(d, @max(@abs(p[0] - q[0]), @abs(p[1] - q[1])));
        return d;
    }
    d = @max(@abs(a.x - b.x), @abs(a.y - b.y));
    return @max(d, @max(@abs(a.w - b.w), @abs(a.h - b.h)));
}

pub fn compare(arena: Allocator, ref: Model, cand: Model) Allocator.Error!CaseResult {
    var r: CaseResult = .{ .items = ref.items.len };
    for (ref.view_box, cand.view_box) |a, b| {
        if (@abs(a - b) > view_box_tolerance) r.view_box_ok = false;
    }
    if (!r.view_box_ok) r.first = try std.fmt.allocPrint(arena, "viewBox {d} {d} {d} {d} vs {d} {d} {d} {d}", .{ ref.view_box[0], ref.view_box[1], ref.view_box[2], ref.view_box[3], cand.view_box[0], cand.view_box[1], cand.view_box[2], cand.view_box[3] });
    var buckets: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (cand.items, 0..) |it, i| {
        const gop = try buckets.getOrPut(arena, it.key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(i));
    }
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    var matched: usize = 0;
    for (ref.items) |it| {
        const gop = try seen.getOrPut(arena, it.key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const n = gop.value_ptr.*;
        gop.value_ptr.* += 1;
        const list = buckets.get(it.key);
        if (list == null or n >= list.?.items.len) {
            r.missing += 1;
            if (r.first.len == 0) r.first = try std.fmt.allocPrint(arena, "missing {s} #{d}", .{ it.key, n });
            continue;
        }
        matched += 1;
        const other = cand.items[list.?.items[n]];
        const dev = deviation(it, other);
        const tol: f64 = if (it.kind == .edge) edge_tolerance else node_tolerance;
        if (dev > tol) {
            r.bad += 1;
            r.max_dev = @max(r.max_dev, dev);
            if (r.first.len == 0) r.first = try std.fmt.allocPrint(arena, "{s} #{d} ({s}) off by {d:.2}", .{ it.key, n, it.id, dev });
        }
    }
    r.extra = cand.items.len - matched;
    if (r.extra > 0 and r.first.len == 0) r.first = try std.fmt.allocPrint(arena, "{d} extra elements", .{r.extra});
    return r;
}

pub const PixelResult = struct {
    same_size: bool,
    differing: usize,
    total: usize,
    max_channel: u8,

    pub fn fraction(r: PixelResult) f64 {
        if (r.total == 0) return 0;
        return @as(f64, @floatFromInt(r.differing)) / @as(f64, @floatFromInt(r.total));
    }

    pub fn passed(r: PixelResult) bool {
        return r.same_size and r.fraction() <= max_pixel_fraction;
    }
};

fn over(px: *const [4]u8, c: usize) u8 {
    const a: u32 = px[3];
    return @intCast((@as(u32, px[c]) * a + @as(u32, page_background[c]) * (255 - a) + 127) / 255);
}

pub fn comparePixels(ref: png.Image, cand: png.Image) PixelResult {
    if (ref.width != cand.width or ref.height != cand.height) {
        return .{ .same_size = false, .differing = 0, .total = @as(usize, ref.width) * ref.height, .max_channel = 0 };
    }
    var r: PixelResult = .{ .same_size = true, .differing = 0, .total = @as(usize, ref.width) * ref.height, .max_channel = 0 };
    var i: usize = 0;
    while (i < r.total) : (i += 1) {
        const a = ref.rgba[i * 4 ..][0..4];
        const b = cand.rgba[i * 4 ..][0..4];
        var worst: u8 = 0;
        for (0..3) |c| {
            const x = over(a, c);
            const y = over(b, c);
            worst = @max(worst, if (x > y) x - y else y - x);
        }
        r.max_channel = @max(r.max_channel, worst);
        if (worst > channel_tolerance) r.differing += 1;
    }
    return r;
}

pub const ErrorCase = struct { name: []const u8, source: []const u8, message: []const u8 };

pub const ErrorsFileError = error{ BadFormat, OutOfMemory };

pub fn parseErrors(arena: Allocator, text: []const u8) ErrorsFileError![]const ErrorCase {
    var out: std.ArrayList(ErrorCase) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        if (!std.mem.startsWith(u8, text[pos..], "#### ")) return error.BadFormat;
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return error.BadFormat;
        const name = text[pos + 5 .. nl];
        const src_start = nl + 1;
        const sep = if (std.mem.startsWith(u8, text[src_start..], "#---\n")) src_start else (std.mem.indexOfPos(u8, text, src_start, "\n#---\n") orelse return error.BadFormat) + 1;
        const msg_start = sep + "#---\n".len;
        const next = std.mem.indexOfPos(u8, text, msg_start, "\n#### ");
        const msg_end = next orelse (if (text.len > msg_start and text[text.len - 1] == '\n') text.len - 1 else text.len);
        try out.append(arena, .{ .name = name, .source = text[src_start..sep], .message = text[msg_start..@max(msg_start, msg_end)] });
        pos = if (next) |nx| nx + 1 else text.len;
    }
    return out.items;
}

const Io = std.Io;

const Out = struct {
    io: Io,
    fn print(o: Out, comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        var w = Io.File.stdout().writerStreaming(o.io, &buf);
        w.interface.print(fmt, args) catch return;
        w.interface.flush() catch return;
    }
};

const Ctx = struct {
    arena: Allocator,
    io: Io,
    out: Out,
    data: []const u8,
    verbose: bool,

    fn read(c: Ctx, comptime fmt: []const u8, args: anytype) ![]u8 {
        const path = try std.fmt.allocPrint(c.arena, "{s}/" ++ fmt, .{c.data} ++ args);
        return Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .unlimited);
    }

    fn caseNames(c: Ctx) ![]const []const u8 {
        const dir_path = try std.fmt.allocPrint(c.arena, "{s}/cases", .{c.data});
        var dir = try Io.Dir.cwd().openDir(c.io, dir_path, .{ .iterate = true });
        defer dir.close(c.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(c.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".mmd")) continue;
            try names.append(c.arena, try c.arena.dupe(u8, e.name[0 .. e.name.len - 4]));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return names.items;
    }

    fn model(c: Ctx, dir: []const u8, name: []const u8) !Model {
        const path = try std.fmt.allocPrint(c.arena, "{s}/{s}.svg", .{ dir, name });
        return extract(c.arena, try Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .unlimited));
    }
};

fn checkCmd(c: Ctx) !u8 {
    const names = try c.caseNames();
    var flow: usize = 0;
    var seq: usize = 0;
    var problems: usize = 0;
    for (names) |name| {
        if (std.mem.startsWith(u8, name, "flow-")) flow += 1;
        if (std.mem.startsWith(u8, name, "seq-")) seq += 1;
        const m = c.model(try std.fmt.allocPrint(c.arena, "{s}/refs", .{c.data}), name) catch |e| {
            c.out.print("{s}: reference svg: {s}\n", .{ name, @errorName(e) });
            problems += 1;
            continue;
        };
        const bytes = c.read("refs/{s}.png", .{name}) catch |e| {
            c.out.print("{s}: reference png: {s}\n", .{ name, @errorName(e) });
            problems += 1;
            continue;
        };
        const img = png.decode(c.arena, bytes) catch |e| {
            c.out.print("{s}: reference png decode: {s}\n", .{ name, @errorName(e) });
            problems += 1;
            continue;
        };
        if (@abs(@as(f64, @floatFromInt(img.width)) - m.view_box[2]) > 1.5 or @abs(@as(f64, @floatFromInt(img.height)) - m.view_box[3]) > 1.5) {
            c.out.print("{s}: png {d}x{d} does not match viewBox {d}x{d}\n", .{ name, img.width, img.height, m.view_box[2], m.view_box[3] });
            problems += 1;
        }
    }
    const errors = parseErrors(c.arena, try c.read("errors.txt", .{})) catch |e| {
        c.out.print("errors.txt: {s}\n", .{@errorName(e)});
        return 1;
    };
    for (errors) |e| {
        if (e.message.len == 0) {
            c.out.print("errors.txt: {s} has an empty message\n", .{e.name});
            problems += 1;
        }
    }
    c.out.print("flowchart cases {d} (min {d}), sequence cases {d} (min {d}), error cases {d} (min {d}), problems {d}\n", .{ flow, min_flow_cases, seq, min_sequence_cases, errors.len, min_error_cases, problems });
    return if (problems == 0 and flow >= min_flow_cases and seq >= min_sequence_cases and errors.len >= min_error_cases) 0 else 1;
}

fn layoutCmd(c: Ctx, cand_dir: []const u8) !u8 {
    const names = try c.caseNames();
    const refs = try std.fmt.allocPrint(c.arena, "{s}/refs", .{c.data});
    var pass: usize = 0;
    var missing: usize = 0;
    var items: usize = 0;
    var bad_items: usize = 0;
    for (names) |name| {
        const ref = try c.model(refs, name);
        const cand = c.model(cand_dir, name) catch |e| {
            missing += 1;
            if (c.verbose) c.out.print("SKIP {s}: candidate svg: {s}\n", .{ name, @errorName(e) });
            continue;
        };
        const r = try compare(c.arena, ref, cand);
        items += r.items;
        bad_items += r.bad + r.missing;
        if (r.passed()) {
            pass += 1;
            if (c.verbose) c.out.print("PASS {s} items={d}\n", .{ name, r.items });
        } else c.out.print("FAIL {s} items={d} bad={d} missing={d} extra={d} max={d:.2}: {s}\n", .{ name, r.items, r.bad, r.missing, r.extra, r.max_dev, r.first });
    }
    c.out.print("layout parity: {d}/{d} cases pass, {d} without candidate, elements off: {d}/{d}\n", .{ pass, names.len - missing, missing, bad_items, items });
    return if (pass == names.len) 0 else 1;
}

fn pixelsCmd(c: Ctx, cand_dir: []const u8) !u8 {
    const names = try c.caseNames();
    var pass: usize = 0;
    var missing: usize = 0;
    for (names) |name| {
        const cand_path = try std.fmt.allocPrint(c.arena, "{s}/{s}.png", .{ cand_dir, name });
        const cand_bytes = Io.Dir.cwd().readFileAlloc(c.io, cand_path, c.arena, .unlimited) catch {
            missing += 1;
            if (c.verbose) c.out.print("SKIP {s}: no candidate png\n", .{name});
            continue;
        };
        const ref = try png.decode(c.arena, try c.read("refs/{s}.png", .{name}));
        const cand = try png.decode(c.arena, cand_bytes);
        const r = comparePixels(ref, cand);
        if (r.passed()) {
            pass += 1;
            if (c.verbose) c.out.print("PASS {s} differing={d:.3}%\n", .{ name, r.fraction() * 100 });
        } else if (!r.same_size) {
            c.out.print("FAIL {s}: size {d}x{d} vs {d}x{d}\n", .{ name, ref.width, ref.height, cand.width, cand.height });
        } else c.out.print("FAIL {s}: {d:.3}% of pixels differ (max channel {d})\n", .{ name, r.fraction() * 100, r.max_channel });
    }
    c.out.print("pixel parity: {d}/{d} cases pass, {d} without candidate\n", .{ pass, names.len - missing, missing });
    return if (pass == names.len) 0 else 1;
}

fn errorsCmd(c: Ctx, cand_file: []const u8) !u8 {
    const refs = try parseErrors(c.arena, try c.read("errors.txt", .{}));
    const cand = try parseErrors(c.arena, try Io.Dir.cwd().readFileAlloc(c.io, cand_file, c.arena, .unlimited));
    var by_name: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (cand) |e| try by_name.put(c.arena, e.name, e.message);
    var pass: usize = 0;
    for (refs) |e| {
        const got = by_name.get(e.name) orelse {
            c.out.print("FAIL {s}: no candidate message\n", .{e.name});
            continue;
        };
        if (std.mem.eql(u8, got, e.message)) {
            pass += 1;
            if (c.verbose) c.out.print("PASS {s}\n", .{e.name});
        } else c.out.print("FAIL {s}\n--- expected\n{s}\n--- got\n{s}\n", .{ e.name, e.message, got });
    }
    c.out.print("error parity: {d}/{d} messages identical\n", .{ pass, refs.len });
    return if (pass == refs.len) 0 else 1;
}

fn labelsCmd(c: Ctx, name: []const u8) !u8 {
    const m = try c.model(try std.fmt.allocPrint(c.arena, "{s}/refs", .{c.data}), name);
    for (m.items) |it| {
        if (it.kind == .label) c.out.print("{d}\t{d}\t{s}\n", .{ it.w, it.h, it.text });
    }
    return 0;
}

fn selfCmd(c: Ctx) !u8 {
    const refs = try std.fmt.allocPrint(c.arena, "{s}/refs", .{c.data});
    const a = try layoutCmd(c, refs);
    const b = try pixelsCmd(c, refs);
    return a | b;
}

const usage =
    \\usage: mermaid-compare [-v] [--data <dir>] <command> [argument]
    \\  check               corpus counts, reference files, PNG sizes, errors.txt
    \\  layout <svg dir>    layout parity: <svg dir>/<case>.svg against refs/<case>.svg
    \\  pixels <png dir>    pixel parity: <png dir>/<case>.png against refs/<case>.png
    \\  errors <file>       error parity: file in errors.txt format against errors.txt
    \\  labels <case>       foreignObject label sizes of a reference, for the replay measurer
    \\  self                run layout and pixels with the references as candidates
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    var c: Ctx = .{ .arena = arena, .io = init.io, .out = .{ .io = init.io }, .data = "testdata/mermaid", .verbose = false };
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < all.len) : (i += 1) {
        if (std.mem.eql(u8, all[i], "-v")) {
            c.verbose = true;
        } else if (std.mem.eql(u8, all[i], "--data") and i + 1 < all.len) {
            i += 1;
            c.data = all[i];
        } else try rest.append(arena, all[i]);
    }
    const args = rest.items;
    if (args.len == 0) {
        c.out.print("{s}", .{usage});
        return 2;
    }
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "check") and args.len == 1) return checkCmd(c);
    if (std.mem.eql(u8, cmd, "self") and args.len == 1) return selfCmd(c);
    if (args.len == 2) {
        if (std.mem.eql(u8, cmd, "layout")) return layoutCmd(c, args[1]);
        if (std.mem.eql(u8, cmd, "pixels")) return pixelsCmd(c, args[1]);
        if (std.mem.eql(u8, cmd, "errors")) return errorsCmd(c, args[1]);
        if (std.mem.eql(u8, cmd, "labels")) return labelsCmd(c, args[1]);
    }
    c.out.print("{s}", .{usage});
    return 2;
}

const sample_svg =
    \\<svg viewBox="-36 -36 100 80" xmlns="http://www.w3.org/2000/svg"><g class="root"><g class="edgePaths">
    \\<path d="M10,10L10,40" class="flowchart-link" data-points="W3sieCI6MTAsInkiOjEwfSx7IngiOjEwLCJ5Ijo0MH1d"/></g>
    \\<g class="node default" transform="translate(10, 10)"><rect class="basic label-container" x="-20" y="-10" width="40" height="20"/>
    \\<g class="label" transform="translate(-5, -6)"><foreignObject width="12" height="12"><div xmlns="http://www.w3.org/1999/xhtml"><span><p>Hi  there</p></span></div></foreignObject></g></g></g></svg>
;

fn moved(arena: Allocator, dx: f64) ![]const u8 {
    return std.fmt.allocPrint(arena, "translate({d}, 10)", .{10 + dx});
}

test "extract reads viewBox, node translate, shape size, edge points and labels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try extract(arena.allocator(), sample_svg);
    try std.testing.expectEqual(@as(f64, 100), m.view_box[2]);
    var groups: usize = 0;
    var edge_pts: usize = 0;
    for (m.items) |it| {
        if (it.kind == .group and std.mem.eql(u8, it.key, "g.default.node")) {
            groups += 1;
            try std.testing.expectEqual(@as(f64, 10), it.x);
        }
        if (it.kind == .edge) edge_pts = it.pts.len;
        if (it.kind == .box) try std.testing.expectEqual(@as(f64, 40), it.w);
    }
    try std.testing.expectEqual(@as(usize, 1), groups);
    try std.testing.expectEqual(@as(usize, 2), edge_pts);
    const r = try ReplayMeasurer.init(arena.allocator(), m);
    const s = try r.measure("Hi there", "", 16, 400);
    try std.testing.expectEqual(@as(f64, 12), s.w);
    try std.testing.expectError(error.UnknownLabel, r.measure("nope", "", 16, 400));
}

test "compare passes identical models and flags a node moved beyond tolerance" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ref = try extract(a, sample_svg);
    try std.testing.expect((try compare(a, ref, ref)).passed());
    const near = try std.mem.replaceOwned(u8, a, sample_svg, "translate(10, 10)", try moved(a, 0.4));
    try std.testing.expect((try compare(a, ref, try extract(a, near))).passed());
    const far = try std.mem.replaceOwned(u8, a, sample_svg, "translate(10, 10)", try moved(a, 0.6));
    const r = try compare(a, ref, try extract(a, far));
    try std.testing.expect(!r.passed());
    try std.testing.expectEqual(@as(usize, 4), r.bad);
}

test "compare flags edge points beyond one pixel and missing elements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ref = try extract(a, sample_svg);
    const no_points = try std.mem.replaceOwned(u8, a, sample_svg, " data-points=\"W3sieCI6MTAsInkiOjEwfSx7IngiOjEwLCJ5Ijo0MH1d\"", "");
    try std.testing.expect((try compare(a, ref, try extract(a, no_points))).passed());
    const bent = try std.mem.replaceOwned(u8, a, no_points, "d=\"M10,10L10,40\"", "d=\"M10,10L12,40\"");
    try std.testing.expect(!(try compare(a, ref, try extract(a, bent))).passed());
    const gone = try std.mem.replaceOwned(u8, a, sample_svg, "<rect class=\"basic label-container\" x=\"-20\" y=\"-10\" width=\"40\" height=\"20\"/>", "");
    try std.testing.expectEqual(@as(usize, 1), (try compare(a, ref, try extract(a, gone))).missing);
}

test "pixel comparison respects tolerance and the cap" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try a.alloc(u8, 100 * 100 * 4);
    @memset(base, 255);
    const other = try a.dupe(u8, base);
    other[0] = 255 - channel_tolerance;
    const ref: png.Image = .{ .width = 100, .height = 100, .rgba = base };
    try std.testing.expect(comparePixels(ref, .{ .width = 100, .height = 100, .rgba = other }).passed());
    for (0..200) |i| other[i * 4] = 0;
    try std.testing.expect(!comparePixels(ref, .{ .width = 100, .height = 100, .rgba = other }).passed());
    try std.testing.expect(!comparePixels(ref, .{ .width = 99, .height = 100, .rgba = other[0 .. 99 * 100 * 4] }).passed());
}

test "errors file round trip keeps exact bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = "#### one\nflowchart TD\n  A[x\n#---\nParse error on line 3:\n----^\nExpecting 'SQE'\n#### two\n#---\nNo diagram type detected matching given configuration for text: \n#### three\n  \n\n#---\nlast\n";
    const cases = try parseErrors(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqualStrings("flowchart TD\n  A[x\n", cases[0].source);
    try std.testing.expectEqualStrings("Parse error on line 3:\n----^\nExpecting 'SQE'", cases[0].message);
    try std.testing.expectEqualStrings("", cases[1].source);
    try std.testing.expectEqualStrings("No diagram type detected matching given configuration for text: ", cases[1].message);
    try std.testing.expectEqualStrings("  \n\n", cases[2].source);
    try std.testing.expectEqualStrings("last", cases[2].message);
}
