const std = @import("std");
const font = @import("font");
const math = @import("math");
const files = @import("files");

const layout = math.layout;
const Node = math.tree.Node;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const A = struct {
    a: Allocator,

    fn p(s: A, v: Node) *const Node {
        const out = s.a.create(Node) catch @panic("oom");
        out.* = v;
        return out;
    }

    fn l(s: A, nodes: []const Node) []const Node {
        return s.a.dupe(Node, nodes) catch @panic("oom");
    }

    fn ch(_: A, cp: u21) Node {
        return .{ .atom = .{ .class = .ord, .cp = cp, .italic = true } };
    }

    fn sym(_: A, cp: u21, class: math.tree.Class) Node {
        return .{ .atom = .{ .class = class, .cp = cp } };
    }

    fn num(_: A, text: []const u8) Node {
        return .{ .number = text };
    }

    fn word(s: A, text: []const u8) []const Node {
        const out = s.a.alloc(Node, text.len) catch @panic("oom");
        for (text, 0..) |c, i| out[i] = if (c >= '0' and c <= '9') s.num(text[i .. i + 1]) else if (c == '+') s.sym('+', .bin) else if (c == '=') s.sym('=', .rel) else if (c == '-') s.sym(0x2212, .bin) else s.ch(c);
        return out;
    }

    fn cat(s: A, parts: []const []const Node) []const Node {
        var all: std.ArrayList(Node) = .empty;
        for (parts) |q| all.appendSlice(s.a, q) catch @panic("oom");
        return all.items;
    }

    fn one(s: A, v: Node) []const Node {
        return s.l(&.{v});
    }

    fn sup(s: A, base: Node, e: []const Node) Node {
        return .{ .supsub = .{ .base = s.p(base), .sup = e, .sub = null, .limits = .side } };
    }

    fn supsub(s: A, base: Node, lo: ?[]const Node, hi: ?[]const Node, lim: math.tree.Limits) Node {
        return .{ .supsub = .{ .base = s.p(base), .sup = hi, .sub = lo, .limits = lim } };
    }

    fn frac(_: A, a: []const Node, b: []const Node) Node {
        return .{ .frac = .{ .num = a, .den = b } };
    }

    fn sqrt(_: A, body: []const Node) Node {
        return .{ .sqrt = .{ .body = body } };
    }

    fn fenced(_: A, open: u21, close: u21, body: []const Node) Node {
        return .{ .fenced = .{ .open = open, .close = close, .body = body } };
    }

    fn op(s: A, cp: u21, lim: math.tree.Limits) Node {
        return .{ .op = .{ .body = s.l(&.{s.sym(cp, .op)}), .limits = lim, .large = true } };
    }
};

const Sample = struct { name: []const u8, display: bool, root: []const Node };

fn samples(s: A) []const Sample {
    var out: std.ArrayList(Sample) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList(Sample), a: Allocator, name: []const u8, display: bool, root: []const Node) void {
            list.append(a, .{ .name = name, .display = display, .root = root }) catch @panic("oom");
        }
    }.f;
    const x = s.ch('x');

    add(&out, s.a, "x2_frac", false, s.l(&.{ s.sup(x, s.one(s.num("2"))), s.sym('+', .bin), s.frac(s.one(s.ch('a')), s.one(s.ch('b'))) }));

    const quad_num = s.cat(&.{ s.word("-b"), s.one(s.sym(0xB1, .bin)), s.one(s.sqrt(s.cat(&.{ s.one(s.sup(s.ch('b'), s.one(s.num("2")))), s.word("-4ac") }))) });
    add(&out, s.a, "quadratic", true, s.cat(&.{ s.word("x="), s.one(s.frac(quad_num, s.word("2a"))) }));

    const n_plus = s.fenced('(', ')', s.word("n+1"));
    const two_n = s.fenced('(', ')', s.word("2n+1"));
    const sum_body = s.cat(&.{
        s.one(s.supsub(s.op(0x2211, .display), s.word("i=1"), s.one(s.ch('n')), .display)),
        s.one(s.sup(s.ch('i'), s.one(s.num("2")))),
        s.word("="),
        s.one(s.frac(s.cat(&.{ s.one(s.ch('n')), s.one(n_plus), s.one(two_n) }), s.one(s.num("6")))),
    });
    add(&out, s.a, "sum_display", true, sum_body);
    add(&out, s.a, "sum_inline", false, sum_body);

    add(&out, s.a, "integral", true, s.cat(&.{
        s.one(s.supsub(s.op(0x222B, .side), s.one(s.num("0")), s.one(s.sym(0x221E, .ord)), .side)),
        s.one(s.sup(s.ch('e'), s.cat(&.{ s.one(s.sym(0x2212, .bin)), s.one(s.sup(x, s.one(s.num("2")))) }))),
        s.one(s.ch('d')),
        s.one(x),
        s.word("="),
        s.one(s.frac(s.one(s.sqrt(s.one(s.ch(0x3C0)))), s.one(s.num("2")))),
    }));

    add(&out, s.a, "delimiters", true, s.l(&.{
        s.fenced('(', ')', s.one(s.frac(s.one(s.ch('a')), s.one(s.ch('b'))))),
        s.fenced('[', ']', s.one(s.frac(s.one(s.sup(x, s.one(s.num("2")))), s.one(s.sqrt(s.one(s.ch('y'))))))),
        s.fenced('{', '}', s.one(s.frac(s.one(s.frac(s.one(s.ch('a')), s.one(s.ch('b')))), s.one(s.frac(s.one(s.ch('c')), s.one(s.ch('d'))))))),
        s.fenced('|', '|', s.one(s.frac(s.one(s.frac(s.one(s.frac(s.one(s.num("1")), s.one(s.num("2")))), s.one(s.num("3")))), s.one(s.num("4"))))),
    }));

    const rows2 = s.a.alloc(math.tree.Row, 2) catch @panic("oom");
    const cells_top = s.a.alloc(math.tree.Cell, 2) catch @panic("oom");
    cells_top[0] = s.one(s.ch('a'));
    cells_top[1] = s.one(s.ch('b'));
    const cells_bot = s.a.alloc(math.tree.Cell, 2) catch @panic("oom");
    cells_bot[0] = s.one(s.ch('c'));
    cells_bot[1] = s.one(s.ch('d'));
    rows2[0] = .{ .cells = cells_top };
    rows2[1] = .{ .cells = cells_bot };
    const mat: Node = .{ .array = .{ .kind = .pmatrix, .rows = rows2, .cols = &.{}, .open = '(', .close = ')' } };
    add(&out, s.a, "matrix", true, s.cat(&.{ s.word("A="), s.one(mat) }));

    const tall = s.a.alloc(math.tree.Row, 6) catch @panic("oom");
    for (tall, 0..) |*r, i| {
        const cell = s.a.alloc(math.tree.Cell, 1) catch @panic("oom");
        cell[0] = s.one(s.ch(@intCast('a' + i)));
        r.* = .{ .cells = cell };
    }
    add(&out, s.a, "assembly", true, s.one(.{ .array = .{ .kind = .matrix, .rows = tall, .cols = &.{}, .open = '(', .close = '}' } }));

    add(&out, s.a, "accents", false, s.l(&.{
        .{ .accent = .{ .base = s.one(x), .cp = 0x2C6, .wide = false } },
        .{ .accent = .{ .base = s.one(s.ch('y')), .cp = 0xAF, .wide = false } },
        .{ .accent = .{ .base = s.one(s.ch('v')), .cp = 0x20D7, .wide = false } },
        .{ .accent = .{ .base = s.word("abc"), .cp = 0x302, .wide = true } },
        .{ .line = .{ .body = s.word("A+B"), .over = true } },
        .{ .supsub = .{ .base = s.p(.{ .stack = .{ .base = s.word("x+y+z"), .over_cp = 0x23DE, .brace = true } }), .sup = s.one(s.ch('n')), .sub = null, .limits = .above } },
    }));

    add(&out, s.a, "radicals", true, s.l(&.{
        s.sqrt(s.one(x)),
        .{ .sqrt = .{ .body = s.one(s.frac(s.one(s.ch('a')), s.one(s.ch('b')))), .index = s.one(s.num("3")) } },
        s.sqrt(s.one(s.frac(s.one(s.frac(s.one(s.num("1")), s.one(s.num("2")))), s.one(s.frac(s.one(s.num("3")), s.one(s.num("4"))))))),
    }));

    add(&out, s.a, "arrows_text", false, s.l(&.{
        .{ .xarrow = .{ .cp = 0x2192, .over = s.word("f"), .under = s.word("g") } },
        .{ .text = .{ .str = " is a map " } },
        s.sym(0x2260, .rel),
    }));
    return out.items;
}

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

const Raster = struct {
    a: Allocator,
    w: usize,
    h: usize,
    scale: f32,
    rgb: []f32,
    edges: std.ArrayList(Edge) = .empty,

    fn flatten(r: *Raster, path: font.Path) !void {
        r.edges.clearRetainingCapacity();
        var start: font.Pt = .{ .x = 0, .y = 0 };
        var cur: font.Pt = .{ .x = 0, .y = 0 };
        var open = false;
        for (path.segs.items) |seg| switch (seg) {
            .move => |p| {
                if (open) try r.line(cur, start);
                start = p;
                cur = p;
                open = true;
            },
            .line => |p| {
                try r.line(cur, p);
                cur = p;
            },
            .quad => |q| {
                const n = 10;
                var prev = cur;
                for (1..n + 1) |i| {
                    const t: f64 = @as(f64, @floatFromInt(i)) / n;
                    const u = 1 - t;
                    const p: font.Pt = .{
                        .x = u * u * cur.x + 2 * u * t * q[0].x + t * t * q[1].x,
                        .y = u * u * cur.y + 2 * u * t * q[0].y + t * t * q[1].y,
                    };
                    try r.line(prev, p);
                    prev = p;
                }
                cur = q[1];
            },
            .cubic => |q| {
                const n = 14;
                var prev = cur;
                for (1..n + 1) |i| {
                    const t: f64 = @as(f64, @floatFromInt(i)) / n;
                    const u = 1 - t;
                    const p: font.Pt = .{
                        .x = u * u * u * cur.x + 3 * u * u * t * q[0].x + 3 * u * t * t * q[1].x + t * t * t * q[2].x,
                        .y = u * u * u * cur.y + 3 * u * u * t * q[0].y + 3 * u * t * t * q[1].y + t * t * t * q[2].y,
                    };
                    try r.line(prev, p);
                    prev = p;
                }
                cur = q[2];
            },
            .close => {
                try r.line(cur, start);
                cur = start;
                open = false;
            },
        };
        if (open) try r.line(cur, start);
    }

    fn line(r: *Raster, p: font.Pt, q: font.Pt) !void {
        try r.edges.append(r.a, .{ .x0 = @floatCast(p.x), .y0 = @floatCast(p.y), .x1 = @floatCast(q.x), .y1 = @floatCast(q.y) });
    }

    fn fill(r: *Raster, colour: u32) !void {
        const ss = 4;
        var ymin: f32 = std.math.floatMax(f32);
        var ymax: f32 = -std.math.floatMax(f32);
        for (r.edges.items) |e| {
            ymin = @min(ymin, @min(e.y0, e.y1));
            ymax = @max(ymax, @max(e.y0, e.y1));
        }
        if (r.edges.items.len == 0) return;
        const y_start: usize = @intFromFloat(@max(@floor(ymin), 0));
        const y_end: usize = @min(@as(usize, @intFromFloat(@max(@ceil(ymax), 0))) + 1, r.h);
        const cov = try r.a.alloc(f32, r.w);
        defer r.a.free(cov);
        const Cross = struct { x: f32, dir: i32 };
        var xs: std.ArrayList(Cross) = .empty;
        defer xs.deinit(r.a);
        const col = [3]f32{
            @floatFromInt((colour >> 16) & 255),
            @floatFromInt((colour >> 8) & 255),
            @floatFromInt(colour & 255),
        };
        for (y_start..y_end) |y| {
            @memset(cov, 0);
            for (0..ss) |sub| {
                const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sub)) + 0.5) / ss;
                xs.clearRetainingCapacity();
                for (r.edges.items) |e| {
                    if ((e.y0 <= sy and sy < e.y1) or (e.y1 <= sy and sy < e.y0)) {
                        const t = (sy - e.y0) / (e.y1 - e.y0);
                        try xs.append(r.a, .{ .x = e.x0 + t * (e.x1 - e.x0), .dir = if (e.y1 > e.y0) 1 else -1 });
                    }
                }
                std.mem.sort(Cross, xs.items, {}, struct {
                    fn lt(_: void, a: Cross, b: Cross) bool {
                        return a.x < b.x;
                    }
                }.lt);
                var wind: i32 = 0;
                for (xs.items, 0..) |c, i| {
                    wind += c.dir;
                    if (wind == 0 or i + 1 >= xs.items.len) continue;
                    const xa = @max(c.x, 0);
                    const xb = @min(xs.items[i + 1].x, @as(f32, @floatFromInt(r.w)));
                    if (xb <= xa) continue;
                    var px: usize = @intFromFloat(@floor(xa));
                    while (@as(f32, @floatFromInt(px)) < xb and px < r.w) : (px += 1) {
                        const lo = @max(xa, @as(f32, @floatFromInt(px)));
                        const hi = @min(xb, @as(f32, @floatFromInt(px + 1)));
                        if (hi > lo) cov[px] += (hi - lo) / ss;
                    }
                }
            }
            for (0..r.w) |x| {
                const al = @min(cov[x], 1);
                if (al <= 0) continue;
                for (0..3) |k| {
                    const i = (y * r.w + x) * 3 + k;
                    r.rgb[i] = r.rgb[i] * (1 - al) + col[k] * al;
                }
            }
        }
    }

    fn rect(r: *Raster, x: f32, y: f32, w: f32, h: f32, colour: u32) !void {
        r.edges.clearRetainingCapacity();
        const x1 = x + w;
        const y1 = y + h;
        try r.edges.append(r.a, .{ .x0 = x, .y0 = y, .x1 = x1, .y1 = y });
        try r.edges.append(r.a, .{ .x0 = x1, .y0 = y, .x1 = x1, .y1 = y1 });
        try r.edges.append(r.a, .{ .x0 = x1, .y0 = y1, .x1 = x, .y1 = y1 });
        try r.edges.append(r.a, .{ .x0 = x, .y0 = y1, .x1 = x, .y1 = y });
        try r.fill(colour);
    }

    fn draw(r: *Raster, b: layout.Box, x: f32, y: f32, colour: u32) !void {
        const s = r.scale;
        switch (b.kind) {
            .empty => {},
            .rule => try r.rect(x * s, (y - b.h) * s, b.w * s, (b.h + b.d) * s, colour),
            .glyph => |g| {
                var path: font.Path = .{};
                defer path.deinit(r.a);
                const k: f64 = @as(f64, g.px) * s / @as(f64, @floatFromInt(g.face.upem));
                try g.face.outline(r.a, g.gid, .{ .a = k, .d = -k, .e = @as(f64, x) * s, .f = @as(f64, y) * s }, &path);
                try r.flatten(path);
                try r.fill(colour);
            },
            .group => |items| for (items) |p| try r.draw(p.box, x + p.x, y + p.y, colour),
            .color => |c| try r.draw(c.child.*, x, y, c.rgb),
        }
    }
};

fn chunk(w: *Writer, kind: *const [4]u8, data: []const u8) !void {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

fn encodePng(arena: Allocator, w_px: usize, h_px: usize, rgb: []const u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h_px) |y| {
        try raw.append(arena, 0);
        try raw.appendSlice(arena, rgb[y * w_px * 3 ..][0 .. w_px * 3]);
    }
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var drain = try Writer.Allocating.initCapacity(arena, 4096);
    var compress = try std.compress.flate.Compress.init(&drain.writer, &window, .zlib, .default);
    try compress.writer.writeAll(raw.items);
    try compress.finish();
    var png: Writer.Allocating = .init(arena);
    const w = &png.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w_px), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h_px), .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", drain.written());
    try chunk(w, "IEND", "");
    return png.written();
}

fn dumpConstants(io: std.Io, c: font.math.Constants, upem: f32) void {
    inline for (@typeInfo(font.math.Constants).@"struct".field_names) |name| {
        files.say(io, "{s} = {d}\n", .{ name, @field(c, name) });
    }
    files.say(io, "upem = {d}\n", .{upem});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    if (all.len < 4) {
        files.say(init.io, "usage: math-dump <font file, - for the system math font, embedded for the bundled one> <face index> <out dir> [sample names...] [--constants]\n", .{});
        return error.Usage;
    }
    const face = try std.fmt.parseInt(u32, all[2], 10);
    const mfont: *const font.Font = if (std.mem.eql(u8, all[1], "-")) font.mathFont(init.io, null) else if (std.mem.eql(u8, all[1], "embedded")) font.embeddedMathFont(init.io) else blk: {
        const f = try arena.create(font.Font);
        f.* = try font.Font.fromTtc(init.io, arena, all[1], face);
        break :blk f;
    };
    try std.Io.Dir.cwd().createDirPath(init.io, all[3]);
    var want_constants = false;
    var names: std.ArrayList([]const u8) = .empty;
    for (all[4..]) |a| {
        if (std.mem.eql(u8, a, "--constants")) want_constants = true else try names.append(arena, a);
    }
    if (want_constants) dumpConstants(init.io, mfont.math.?.constants, @floatFromInt(mfont.upem));

    const list = samples(.{ .a = arena });
    for (list) |smp| {
        if (names.items.len > 0) {
            var hit = false;
            for (names.items) |nm| hit = hit or std.mem.eql(u8, nm, smp.name);
            if (!hit) continue;
        }
        const size: f32 = 32;
        const box = try layout.layoutNodes(arena, smp.root, mfont, .{ .size = size, .display = smp.display });
        const pad: f32 = 12;
        const scale: f32 = 3;
        const w_px: usize = @intFromFloat(@ceil((box.w + 2 * pad) * scale));
        const h_px: usize = @intFromFloat(@ceil((box.h + box.d + 2 * pad) * scale));
        const rgb = try arena.alloc(f32, w_px * h_px * 3);
        @memset(rgb, 255);
        var r: Raster = .{ .a = arena, .w = w_px, .h = h_px, .scale = scale, .rgb = rgb };
        try r.draw(box, pad, pad + box.h, 0x000000);
        const bytes = try arena.alloc(u8, rgb.len);
        for (rgb, 0..) |v, i| bytes[i] = @intFromFloat(@round(std.math.clamp(v, 0, 255)));
        const png = try encodePng(arena, w_px, h_px, bytes);
        const png_path = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ all[3], smp.name });
        try files.write(init.io, png_path, png);
        const svg = try math.scene.toSvg(arena, box, 0x000000);
        try files.write(init.io, try std.fmt.allocPrint(arena, "{s}/{s}.svg", .{ all[3], smp.name }), svg);
        files.say(init.io, "{s}: w={d:.2} h={d:.2} d={d:.2} -> {s}\n", .{ smp.name, box.w, box.h, box.d, png_path });
    }
}
