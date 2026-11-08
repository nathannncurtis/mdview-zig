const std = @import("std");
const draw = @import("svg_draw.zig");
const xml = @import("svg_xml.zig");
const raster = @import("svg_raster.zig");
const sty = @import("svg_style.zig");
const font = @import("font");
const shape = @import("svg_shape.zig");
const indic = @import("svg_indic.zig");
const colr = @import("svg_colr.zig");
const image = @import("image.zig");

const Error = image.Error;

var user_io: ?std.Io = null;
var fallback_threaded: std.Io.Threaded = .init_single_threaded;

pub fn setIo(io: std.Io) void {
    user_io = io;
}

fn currentIo() std.Io {
    return user_io orelse fallback_threaded.io();
}

const Faces = struct {
    user: [4]?*const font.Font = .{ null, null, null, null },
    chain: *const font.Chain,

    fn glyphFor(f: *const Faces, cp: u32) font.Chain.Glyph {
        for (f.user) |u| if (u) |uf| {
            const g = uf.glyphIndex(cp);
            if (g != 0) return .{ .font = uf, .gid = g };
        };
        return f.chain.glyphFor(cp);
    }

    fn primary(f: *const Faces) *const font.Font {
        return f.user[0] orelse f.chain.primary;
    }
};

fn facesFor(r: *draw.Renderer, style: *const sty.Style) Faces {
    var out: Faces = .{ .chain = font.resolve(currentIo(), style.font_family, style.weight, style.italic) };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, style.font_family, ',');
    while (it.next()) |raw| {
        if (n >= out.user.len) break;
        const name = std.mem.trim(u8, raw, " \t\r\n\"'");
        if (name.len == 0) continue;
        if (r.userFace(name, style.weight, style.italic)) |uf| {
            out.user[n] = uf;
            n += 1;
        }
    }
    return out;
}

pub const ColorLayer = struct { path: raster.Path, color: [4]u8 };

pub const BitmapRun = struct { rgba: []u8, w: usize, h: usize, m: raster.Mat };

pub const Run = struct {
    style: sty.Style,
    path: raster.Path,
    layers: []const ColorLayer = &.{},
    bitmaps: []const BitmapRun = &.{},
};

const Glyph = struct {
    face: *const font.Font,
    gid: u16,
    size: f64,
    x: f64,
    y: f64,
    rot: f64,
    adv: f64,
    xs: f64 = 1,
    space: bool,
    run: u32,
    pidx: i32 = -1,
    ox: f64 = 0,
    oy: f64 = 0,
};

const PathLen = struct { pts: []const raster.Pt, cum: []const f64 };

const RunInfo = struct { style: sty.Style, first: usize, last: usize = 0 };

const Chunk = struct { first: usize, anchor: sty.Anchor, x0: f64 };

const List = struct { v: []const f64 = &.{}, start: usize = 0 };

const Layout = struct {
    r: *draw.Renderer,
    a: std.mem.Allocator,
    glyphs: std.ArrayList(Glyph) = .empty,
    runs: std.ArrayList(RunInfo) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    pen_x: f64 = 0,
    pen_y: f64 = 0,
    ci: usize = 0,
    prev_space: bool = true,
    preserve: bool = false,
    xs: List = .{},
    ys: List = .{},
    dxs: List = .{},
    dys: List = .{},
    rots: List = .{},
    vw: f64,
    vh: f64,
    chunk_pending: bool = true,
    paths: std.ArrayList(PathLen) = .empty,
    cur_path: i32 = -1,

    fn parseList(l: *Layout, s_opt: ?[]const u8, axis: sty.Axis, c: sty.LenCtx) Error!List {
        const s = s_opt orelse return .{};
        var out: std.ArrayList(f64) = .empty;
        var it = std.mem.tokenizeAny(u8, s, ", \t\r\n");
        while (it.next()) |tok| {
            const len = sty.parseLen(tok) orelse break;
            try out.append(l.a, sty.resolveLen(len, axis, c));
            if (out.items.len > 100_000) break;
        }
        return .{ .v = out.items, .start = l.ci };
    }

    fn at(list: List, idx: usize) ?f64 {
        if (idx < list.start) return null;
        const k = idx - list.start;
        return if (k < list.v.len) list.v[k] else null;
    }

    fn baseline(r: *draw.Renderer, style: *const sty.Style) f64 {
        const size = style.font_size;
        var off: f64 = 0;
        const b = style.baseline;
        const f = facesFor(r, style).primary();
        const upem: f64 = @floatFromInt(f.upem);
        const asc: f64 = @floatFromInt(f.ascent);
        const desc: f64 = @floatFromInt(f.descent);
        if (std.mem.eql(u8, b, "middle")) {
            off = 0.273 * size;
        } else if (std.mem.eql(u8, b, "central")) {
            off = (asc + desc) / 2 / upem * size;
        } else if (std.mem.eql(u8, b, "hanging")) {
            off = 0.73 * size;
        } else if (std.mem.eql(u8, b, "text-before-edge") or std.mem.eql(u8, b, "text-top") or std.mem.eql(u8, b, "before-edge")) {
            off = asc / upem * size;
        } else if (std.mem.eql(u8, b, "text-after-edge") or std.mem.eql(u8, b, "text-bottom") or std.mem.eql(u8, b, "after-edge")) {
            off = desc / upem * size;
        } else if (std.mem.eql(u8, b, "mathematical")) off = 0.34 * size;
        const bs = style.baseline_shift;
        if (std.mem.eql(u8, bs, "sub")) {
            off += 0.2 * size;
        } else if (std.mem.eql(u8, bs, "super")) {
            off -= 0.4 * size;
        } else if (sty.parseLen(bs)) |l| {
            off -= if (l.unit == .pct) l.v / 100 * size else sty.resolveLen(l, .diag, .{ .font_size = size });
        }
        return off;
    }

    const Item = struct { cp: u32, idx: usize };

    fn isNeutral(cp: u32) bool {
        return cp < 0x30 or (cp >= 0x3A and cp <= 0x40) or (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0xBF) or (cp >= 0x2000 and cp <= 0x206F) or (cp >= 0x30 and cp <= 0x39);
    }

    fn feature(comptime tag: *const [4]u8, mask: u8) shape.Feat {
        return .{ .tag = tag, .mask = mask };
    }

    fn shapeRun(l: *Layout, face: *const font.Font, cps: []const u32, gids: []const u16, rtl: bool, ligatures: bool, out: *std.ArrayList(shape.G)) Error!void {
        const a = l.a;
        for (cps, gids, 0..) |_, gid, i| try out.append(a, .{ .gid = gid, .first = @intCast(i), .last = @intCast(i) });
        const gsub = shape.Gsub.init(face);
        var arabic = false;
        var script: ?indic.Script = null;
        for (cps) |cp| {
            arabic = arabic or shape.isArabic(cp);
            if (script == null) script = indic.scriptOf(cp);
        }
        var pos_tags: [2]*const [4]u8 = .{ "latn", "DFLT" };
        if (arabic) pos_tags = .{ "arab", "DFLT" };
        if (script) |sc| {
            pos_tags = sc.tags;
            try indic.run(a, gsub, sc, cps, out);
        } else if (gsub) |gs| {
            var reqs: std.ArrayList(shape.Req) = .empty;
            if (arabic) {
                const forms = try a.alloc(shape.Form, cps.len);
                shape.arabicForms(cps, forms);
                for (out.items, 0..) |*g, i| g.form = @intFromEnum(forms[i]);
                const feats = [_]shape.Feat{
                    feature("ccmp", 0xFF), feature("locl", 0xFF), feature("isol", 1), feature("init", 2), feature("medi", 4), feature("fina", 8),
                    feature("rlig", 0xFF), feature("calt", 0xFF), feature("liga", 0xFF), feature("clig", 0xFF),
                };
                try gs.collect(&.{ "arab", "DFLT", "latn" }, &feats, &reqs, a);
            } else {
                const feats = if (ligatures)
                    [_]shape.Feat{ feature("ccmp", 0xFF), feature("locl", 0xFF), feature("rlig", 0xFF), feature("liga", 0xFF), feature("clig", 0xFF), feature("calt", 0xFF) }
                else
                    [_]shape.Feat{ feature("ccmp", 0xFF), feature("locl", 0xFF), feature("rlig", 0xFF), feature("calt", 0xFF), feature("calt", 0xFF), feature("calt", 0xFF) };
                try gs.collect(&.{ "latn", "DFLT" }, &feats, &reqs, a);
            }
            if (reqs.items.len > 0) try gs.apply(a, out, reqs.items);
        }
        const gdef = shape.Gdef.init(face);
        if (shape.Gsub.initTag(face, "GPOS")) |gp| {
            var reqs: std.ArrayList(shape.Req) = .empty;
            const feats = [_]shape.Feat{ feature("dist", 0xFF), feature("curs", 0xFF), feature("mark", 0xFF), feature("abvm", 0xFF), feature("blwm", 0xFF), feature("mkmk", 0xFF) };
            try gp.collect(&.{ pos_tags[0], pos_tags[1], "DFLT", "latn" }, &feats, &reqs, a);
            if (reqs.items.len > 0) shape.markPositions(gp, gdef, face, out.items, reqs.items, rtl);
        }
        for (out.items) |*g| if (shape.isMark(gdef, face, g.gid)) {
            g.zero = true;
        };
        if (rtl) std.mem.reverse(shape.G, out.items);
    }

    fn addText(l: *Layout, str: []const u8, style: *const sty.Style) Error!void {
        const a = l.a;
        const run_idx: u32 = @intCast(l.runs.items.len);
        try l.runs.append(a, .{ .style = style.*, .first = l.glyphs.items.len });
        const chain = facesFor(l.r, style);
        var items: std.ArrayList(Item) = .empty;
        const view = std.unicode.Utf8View.init(str) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp0| {
            var cp: u32 = cp0;
            if (cp == '\n' or cp == '\r' or cp == '\t') cp = ' ';
            if (cp < 0x20 or cp == 0x7f or cp == 0x200B or cp == 0xFEFF) continue;
            if (cp == ' ' and !l.preserve) {
                if (l.prev_space) continue;
                l.prev_space = true;
            } else l.prev_space = false;
            if (items.items.len >= 100_000) return error.TooLarge;
            try items.append(a, .{ .cp = cp, .idx = l.ci });
            l.ci += 1;
        }
        var seg_start: usize = 0;
        var k: usize = 0;
        while (k <= items.items.len) : (k += 1) {
            const at_end = k == items.items.len;
            const breaks = !at_end and k > seg_start and l.hasPos(items.items[k].idx);
            if (at_end or breaks) {
                if (k > seg_start) try l.emitSegment(items.items[seg_start..k], style, chain, run_idx);
                seg_start = k;
            }
        }
        l.runs.items[run_idx].last = l.glyphs.items.len;
    }

    fn hasPos(l: *Layout, idx: usize) bool {
        return at(l.xs, idx) != null or at(l.ys, idx) != null or at(l.dxs, idx) != null or at(l.dys, idx) != null or at(l.rots, idx) != null or (l.rots.v.len > 0 and idx >= l.rots.start);
    }

    fn emitSegment(l: *Layout, items: []const Item, style: *const sty.Style, chain: Faces, run_idx: u32) Error!void {
        const a = l.a;
        const idx0 = items[0].idx;
        if (at(l.xs, idx0)) |x| {
            l.pen_x = x;
            l.chunk_pending = true;
        }
        if (at(l.ys, idx0)) |y| {
            l.pen_y = y;
            l.chunk_pending = true;
        }
        if (at(l.dxs, idx0)) |d| l.pen_x += d;
        if (at(l.dys, idx0)) |d| l.pen_y += d;
        if (l.chunk_pending) {
            try l.chunks.append(a, .{ .first = l.glyphs.items.len, .anchor = style.anchor, .x0 = l.pen_x });
            l.chunk_pending = false;
        }
        const rot = if (at(l.rots, idx0)) |rv| rv else if (l.rots.v.len > 0 and idx0 >= l.rots.start) l.rots.v[l.rots.v.len - 1] else 0;
        const cps = try a.alloc(u32, items.len);
        const faces = try a.alloc(*const font.Font, items.len);
        const gids = try a.alloc(u16, items.len);
        var n: usize = 0;
        for (items) |it| {
            const ignorable = it.cp == 0x200D or it.cp == 0x200C or (it.cp >= 0xFE00 and it.cp <= 0xFE0F);
            const joiner = ignorable or (it.cp >= 0x1F3FB and it.cp <= 0x1F3FF);
            if (joiner and n > 0) {
                const g = faces[n - 1].glyphIndex(it.cp);
                if (g != 0) {
                    cps[n] = it.cp;
                    faces[n] = faces[n - 1];
                    gids[n] = g;
                    n += 1;
                    continue;
                }
                if (ignorable) continue;
            }
            if (ignorable) continue;
            cps[n] = it.cp;
            const g = chain.glyphFor(it.cp);
            faces[n] = g.font;
            gids[n] = g.gid;
            n += 1;
        }
        if (n == 0) return;
        const ligs = style.letter_spacing == 0;
        var i: usize = 0;
        var prev_face: ?*const font.Font = null;
        var prev_gid: u16 = 0;
        while (i < n) {
            var j = i + 1;
            const rtl = shape.isRtl(cps[i]);
            while (j < n and faces[j] == faces[i]) {
                const nr = shape.isRtl(cps[j]);
                if (nr != rtl and !isNeutral(cps[j])) break;
                if (isNeutral(cps[j]) and rtl) {
                    var m = j;
                    while (m < n and isNeutral(cps[m])) m += 1;
                    if (!(m < n and shape.isRtl(cps[m]))) break;
                }
                j += 1;
            }
            var out: std.ArrayList(shape.G) = .empty;
            try l.shapeRun(faces[i], cps[i..j], gids[i..j], rtl, ligs, &out);
            const face = faces[i];
            const k = style.font_size / @as(f64, @floatFromInt(face.upem));
            for (out.items) |g| {
                if (l.glyphs.items.len > 200_000) return error.TooLarge;
                var kern: f64 = 0;
                if (prev_face == face) kern = face.kern(prev_gid, g.gid) * k;
                l.pen_x += kern;
                const cp0 = cps[i + g.first];
                const hidden = cp0 == 0x200D or cp0 == 0x200C or (cp0 >= 0xFE00 and cp0 <= 0xFE0F);
                const is_space = cp0 == ' ' or hidden;
                const adv = if (hidden or g.zero) 0 else face.advance(g.gid) * k + style.letter_spacing + (if (cp0 == ' ') style.word_spacing else 0);
                try l.glyphs.append(a, .{
                    .face = face,
                    .gid = g.gid,
                    .size = style.font_size,
                    .x = l.pen_x,
                    .y = l.pen_y + baseline(l.r, style),
                    .rot = rot * std.math.pi / 180.0,
                    .adv = adv,
                    .space = is_space,
                    .run = run_idx,
                    .pidx = l.cur_path,
                    .ox = @as(f64, @floatFromInt(g.dx)) * k,
                    .oy = @as(f64, @floatFromInt(g.dy)) * k,
                });
                l.pen_x += adv;
                prev_face = face;
                prev_gid = g.gid;
            }
            i = j;
        }
    }

    fn textPath(l: *Layout, node: *xml.Node, style: *const sty.Style) Error!void {
        const href = node.href() orelse return;
        if (href.len < 2 or href[0] != '#') return;
        const ref = l.r.lookupPublic(href[1..]) orelse return;
        if (!std.mem.eql(u8, ref.tag, "path")) return;
        const c: sty.LenCtx = .{ .font_size = style.font_size, .vw = l.vw, .vh = l.vh };
        var path: raster.Path = .{};
        defer path.segs.deinit(l.r.gpa);
        try l.r.shapePath(ref, c, &path);
        var polys: raster.Polys = .{};
        try raster.flatten(l.a, &path, raster.Mat.identity, 0.05, &polys);
        if (polys.subs.items.len == 0) return;
        const sub = polys.subs.items[0];
        const pts = polys.pts.items[sub.start..][0..sub.len];
        if (pts.len < 2) return;
        const cum = try l.a.alloc(f64, pts.len);
        cum[0] = 0;
        for (1..pts.len) |i| cum[i] = cum[i - 1] + std.math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
        const total = cum[pts.len - 1];
        var start: f64 = 0;
        if (sty.parseLen(node.attr("startOffset") orelse "0")) |len| start = if (len.unit == .pct) len.v / 100 * total else sty.resolveLen(len, .x, c);
        try l.paths.append(l.a, .{ .pts = pts, .cum = cum });
        const saved = .{ l.pen_x, l.pen_y, l.chunk_pending, l.xs, l.ys, l.dxs, l.dys };
        l.cur_path = @intCast(l.paths.items.len - 1);
        l.pen_x = start;
        l.pen_y = 0;
        l.chunk_pending = true;
        l.xs = .{};
        l.ys = .{};
        try l.process(node, style);
        l.cur_path = -1;
        l.pen_x = saved[0];
        l.pen_y = saved[1];
        l.chunk_pending = true;
        l.xs = saved[3];
        l.ys = saved[4];
        l.dxs = saved[5];
        l.dys = saved[6];
        _ = saved[2];
    }

    fn process(l: *Layout, node: *xml.Node, style: *const sty.Style) Error!void {
        const c: sty.LenCtx = .{ .font_size = style.font_size, .vw = l.vw, .vh = l.vh };
        const saved = .{ l.xs, l.ys, l.dxs, l.dys, l.rots, l.preserve };
        if (node.attr("x")) |_| l.xs = try l.parseList(node.attr("x"), .x, c);
        if (node.attr("y")) |_| l.ys = try l.parseList(node.attr("y"), .y, c);
        if (node.attr("dx")) |_| l.dxs = try l.parseList(node.attr("dx"), .x, c);
        if (node.attr("dy")) |_| l.dys = try l.parseList(node.attr("dy"), .y, c);
        if (node.attr("rotate")) |rs| {
            var out: std.ArrayList(f64) = .empty;
            var sc: raster.NumScan = .{ .s = rs };
            while (sc.number()) |v| try out.append(l.a, v);
            l.rots = .{ .v = out.items, .start = l.ci };
        }
        if (node.attr("xml:space")) |sp| l.preserve = std.mem.eql(u8, sp, "preserve");
        const g0 = l.glyphs.items.len;
        for (node.children.items) |ch| {
            if (ch.is_text) {
                try l.addText(ch.text, style);
            } else if (std.mem.eql(u8, ch.tag, "textPath")) {
                const cs = try l.r.computeStyle(ch, style, c);
                if (cs.display) try l.textPath(ch, &cs);
            } else if (std.mem.eql(u8, ch.tag, "tspan") or std.mem.eql(u8, ch.tag, "a")) {
                const cs = try l.r.computeStyle(ch, style, c);
                if (!cs.display) continue;
                try l.process(ch, &cs);
            }
        }
        if (node.attr("textLength")) |tls| {
            const g1 = l.glyphs.items.len;
            if (g1 > g0) if (sty.parseLen(tls)) |tl_len| {
                const x0 = l.glyphs.items[g0].x;
                const tl = sty.resolveLen(tl_len, .x, c);
                const natural = l.pen_x - x0;
                if (g1 > g0 and tl > 0 and natural > 0) {
                    const scale_glyphs = std.mem.eql(u8, node.attr("lengthAdjust") orelse "", "spacingAndGlyphs");
                    if (scale_glyphs) {
                        const sc = tl / natural;
                        for (l.glyphs.items[g0..g1]) |*g| {
                            g.x = x0 + (g.x - x0) * sc;
                            g.xs *= sc;
                            g.adv *= sc;
                        }
                    } else if (g1 - g0 > 1) {
                        const gap = (tl - natural) / @as(f64, @floatFromInt(g1 - g0 - 1));
                        for (l.glyphs.items[g0..g1], 0..) |*g, i| g.x += gap * @as(f64, @floatFromInt(i));
                        for (l.glyphs.items[g0 .. g1 - 1]) |*g| g.adv += gap;
                    }
                    l.pen_x = x0 + tl;
                }
            };
        }
        l.xs = saved[0];
        l.ys = saved[1];
        l.dxs = saved[2];
        l.dys = saved[3];
        l.rots = saved[4];
        l.preserve = saved[5];
    }
};

pub fn layout(r: *draw.Renderer, a: std.mem.Allocator, node: *xml.Node, style: *const sty.Style, c: sty.LenCtx, snap: ?raster.Mat) Error![]Run {
    var l: Layout = .{ .r = r, .a = a, .vw = c.vw, .vh = c.vh };
    try l.process(node, style);
    return finish(&l, a, snap);
}

fn finish(l: *Layout, a: std.mem.Allocator, snap: ?raster.Mat) Error![]Run {
    if (!l.preserve and l.glyphs.items.len > 0 and l.glyphs.items[l.glyphs.items.len - 1].space) {
        const g = l.glyphs.pop().?;
        l.pen_x -= g.adv;
        for (l.runs.items) |*ri| ri.last = @min(ri.last, l.glyphs.items.len);
    }
    for (l.chunks.items, 0..) |ch, i| {
        const last = if (i + 1 < l.chunks.items.len) l.chunks.items[i + 1].first else l.glyphs.items.len;
        if (last <= ch.first) continue;
        const g = l.glyphs.items[last - 1];
        const width = g.x + g.adv - ch.x0;
        const delta: f64 = switch (ch.anchor) {
            .start => 0,
            .middle => -width / 2,
            .end => -width,
        };
        if (delta != 0) for (l.glyphs.items[ch.first..last]) |*gl| {
            gl.x += delta;
        };
    }
    const out = try a.alloc(Run, l.runs.items.len);
    for (l.runs.items, 0..) |ri, i| {
        out[i] = .{ .style = ri.style, .path = .{} };
        const p = &out[i].path;
        if (ri.last <= ri.first) continue;
        var x_min = std.math.inf(f64);
        var x_max = -std.math.inf(f64);
        var base_y: f64 = 0;
        var layers: std.ArrayList(ColorLayer) = .empty;
        var bitmaps: std.ArrayList(BitmapRun) = .empty;
        for (l.glyphs.items[ri.first..ri.last]) |g| {
            const k = g.size / @as(f64, @floatFromInt(g.face.upem));
            const skew: f64 = if (g.face.oblique) 0.25 * k else 0;
            var origin: raster.Mat = raster.Mat.identity;
            if (g.pidx >= 0) {
                const pl = l.paths.items[@intCast(g.pidx)];
                const dist = g.x + g.adv / 2;
                const total = pl.cum[pl.cum.len - 1];
                if (dist < 0 or dist > total) continue;
                var seg: usize = 1;
                while (seg < pl.cum.len - 1 and pl.cum[seg] < dist) seg += 1;
                const p0 = pl.pts[seg - 1];
                const p1 = pl.pts[seg];
                const sl = pl.cum[seg] - pl.cum[seg - 1];
                const t = if (sl > 0) (dist - pl.cum[seg - 1]) / sl else 0;
                const ang = std.math.atan2(p1.y - p0.y, p1.x - p0.x) + g.rot;
                const ca = @cos(ang);
                const sa = @sin(ang);
                origin = raster.Mat.translate(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t).mul(.{ .a = ca, .b = sa, .c = -sa, .d = ca }).mul(raster.Mat.translate(-g.adv / 2, g.y));
                x_min = @min(x_min, p0.x);
                x_max = @max(x_max, p0.x);
                base_y = p0.y;
            } else {
                var gy = g.y;
                if (snap) |sm| if (sm.b == 0 and sm.c == 0 and sm.d != 0) {
                    gy = (@round(sm.d * g.y + sm.f) - sm.f) / sm.d;
                };
                const cs = @cos(g.rot);
                const sn = @sin(g.rot);
                origin = raster.Mat.translate(g.x + g.ox, gy - g.oy).mul(.{ .a = cs, .b = sn, .c = -sn, .d = cs });
                x_min = @min(x_min, g.x);
                x_max = @max(x_max, g.x + g.adv);
                base_y = g.y;
            }
            if (g.space) continue;
            const gm = origin.mul(.{ .a = k * g.xs, .c = skew * g.xs, .d = -k });
            const fm: font.Mat = .{ .a = gm.a, .b = gm.b, .c = gm.c, .d = gm.d, .e = gm.e, .f = gm.f };
            if (snap) |sm| {
                const dev = @sqrt(@abs(sm.a * sm.d - sm.b * sm.c));
                const fg: [4]f32 = switch (ri.style.fill) {
                    .color => |col| .{ col.r, col.g, col.b, col.a },
                    .current => .{ ri.style.color.r, ri.style.color.g, ri.style.color.b, ri.style.color.a },
                    else => .{ 0, 0, 0, 1 },
                };
                const rendered = colr.render(l.r, a, g.face, g.gid, k * dev, fg) catch null;
                if (rendered) |rd| {
                    try bitmaps.append(a, .{ .rgba = rd.rgba, .w = rd.w, .h = rd.h, .m = gm.mul(rd.m) });
                    continue;
                }
            }
            var cl: std.ArrayList(shape.Layer) = .empty;
            if (try shape.colrLayers(g.face, g.gid, a, &cl)) {
                for (cl.items) |ly| {
                    if (ly.color) |col| {
                        var lp: raster.Path = .{};
                        if (g.face.outline(a, ly.gid, fm, &lp)) |_| {} else |_| {}
                        try layers.append(a, .{ .path = lp, .color = col });
                    } else if (g.face.outline(a, ly.gid, fm, p)) |_| {} else |_| {}
                }
                continue;
            }
            if (shape.bitmapGlyph(g.face, g.gid, a)) |bm| {
                if (bm.img.frames.len > 0) {
                    const iw: f64 = @floatFromInt(bm.img.width);
                    const ih: f64 = @floatFromInt(bm.img.height);
                    const sc = g.size / bm.ppem;
                    const px = try a.alloc(u8, bm.img.frames[0].rgba.len);
                    var q: usize = 0;
                    while (q < px.len) : (q += 4) {
                        const al = bm.img.frames[0].rgba[q + 3];
                        for (0..3) |ch2| px[q + ch2] = @intCast((@as(u32, bm.img.frames[0].rgba[q + ch2]) * al + 127) / 255);
                        px[q + 3] = al;
                    }
                    const local: raster.Mat = .{ .a = sc, .d = sc, .e = sc * bm.left, .f = -sc * (bm.bottom + ih) };
                    _ = iw;
                    try bitmaps.append(a, .{ .rgba = px, .w = bm.img.width, .h = bm.img.height, .m = origin.mul(local) });
                    continue;
                }
            }
            if (g.face.outline(a, g.gid, fm, p)) |_| {} else |_| {}
        }
        out[i].layers = layers.items;
        out[i].bitmaps = bitmaps.items;
        const st = ri.style;
        if (x_min < x_max) {
            if (st.underline) try rect(a, p, x_min, base_y + st.font_size * 0.0635, x_max - x_min, @max(1, st.font_size * 0.05));
            if (st.line_through) try rect(a, p, x_min, base_y - st.font_size * 0.3, x_max - x_min, @max(1, st.font_size * 0.05));
        }
    }
    return out;
}

fn rect(a: std.mem.Allocator, p: *raster.Path, x: f64, y: f64, w: f64, h: f64) Error!void {
    try p.moveTo(a, x, y);
    try p.lineTo(a, x + w, y);
    try p.lineTo(a, x + w, y + h);
    try p.lineTo(a, x, y + h);
    try p.close(a);
}

const HTok = struct { text: []const u8, style: sty.Style, w: f64 };

const Html = struct {
    l: *Layout,
    a: std.mem.Allocator,
    width: f64,
    y: f64 = 0,
    pending: f64 = 0,
    first: bool = true,
    cur: std.ArrayList(HTok) = .empty,
    cur_w: f64 = 0,
    indent: f64 = 0,
    need_space: bool = false,
    forced: bool = false,

    fn measure(h: *Html, style: *const sty.Style, text: []const u8) f64 {
        const chain = facesFor(h.l.r, style);
        var w: f64 = 0;
        var prev: ?*const font.Font = null;
        var prev_gid: u16 = 0;
        const view = std.unicode.Utf8View.init(text) catch return 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const g = chain.glyphFor(cp);
            const k = style.font_size / @as(f64, @floatFromInt(g.font.upem));
            if (prev == g.font) w += g.font.kern(prev_gid, g.gid) * k;
            w += g.font.advance(g.gid) * k + style.letter_spacing;
            prev = g.font;
            prev_gid = g.gid;
        }
        return w;
    }

    fn flush(h: *Html) Error!void {
        if (h.cur.items.len == 0) {
            if (h.forced) {
                h.y += 16 * 1.15;
                h.forced = false;
            }
            return;
        }
        h.forced = false;
        if (h.first) h.pending = 0;
        h.first = false;
        h.y += h.pending;
        h.pending = 0;
        var asc: f64 = 0;
        var desc: f64 = 0;
        var line_h: f64 = 0;
        for (h.cur.items) |tk| {
            const f = facesFor(h.l.r, &tk.style).primary();
            const k = tk.style.font_size / @as(f64, @floatFromInt(f.upem));
            const as_ = @as(f64, @floatFromInt(f.ascent)) * k;
            const de = -@as(f64, @floatFromInt(f.descent)) * k;
            const gap = @as(f64, @floatFromInt(f.line_gap)) * k;
            asc = @max(asc, as_);
            desc = @max(desc, de);
            const lh = if (tk.style.line_height == 0) as_ + de + gap else if (tk.style.line_height < 0) -tk.style.line_height * tk.style.font_size else tk.style.line_height;
            line_h = @max(line_h, lh);
        }
        const baseline = h.y + (line_h - (asc + desc)) / 2 + asc;
        var total: f64 = 0;
        for (h.cur.items) |tk| total += tk.w;
        const last = &h.cur.items[h.cur.items.len - 1];
        if (last.text.len > 0 and last.text[last.text.len - 1] == ' ') total -= h.measure(&last.style, " ");
        const avail = h.width - h.indent;
        const al = h.cur.items[0].style.text_align;
        var x = h.indent + (if (al == 1) (avail - total) / 2 else if (al == 2) avail - total else 0);
        for (h.cur.items) |tk| {
            h.l.pen_x = x;
            h.l.pen_y = baseline;
            h.l.chunk_pending = true;
            h.l.prev_space = false;
            h.l.preserve = true;
            var st = tk.style;
            st.anchor = .start;
            try h.l.addText(tk.text, &st);
            x += tk.w;
        }
        h.y += line_h;
        h.cur.clearRetainingCapacity();
        h.cur_w = 0;
    }

    fn word(h: *Html, w: []const u8, style: *const sty.Style) Error!void {
        var text_s = w;
        if (h.need_space and h.cur.items.len > 0) text_s = try std.mem.concat(h.a, u8, &.{ " ", w });
        var wd = h.measure(style, text_s);
        const avail = h.width - h.indent;
        if (h.cur.items.len > 0 and h.cur_w + wd > avail + 0.01) {
            try h.flush();
            text_s = w;
            wd = h.measure(style, text_s);
        }
        try h.cur.append(h.a, .{ .text = text_s, .style = style.*, .w = wd });
        h.cur_w += wd;
        h.need_space = false;
    }

    fn adjust(tag: []const u8, s: *sty.Style) void {
        const eq = std.mem.eql;
        if (eq(u8, tag, "b") or eq(u8, tag, "strong") or (tag.len == 2 and tag[0] == 'h' and std.ascii.isDigit(tag[1]))) s.weight = @max(s.weight, 700);
        if (eq(u8, tag, "i") or eq(u8, tag, "em") or eq(u8, tag, "cite") or eq(u8, tag, "var") or eq(u8, tag, "dfn")) s.italic = true;
        if (eq(u8, tag, "u") or eq(u8, tag, "a")) s.underline = true;
        if (eq(u8, tag, "s") or eq(u8, tag, "strike") or eq(u8, tag, "del")) s.line_through = true;
        if (eq(u8, tag, "code") or eq(u8, tag, "kbd") or eq(u8, tag, "samp") or eq(u8, tag, "tt") or eq(u8, tag, "pre")) s.font_family = "monospace";
        if (eq(u8, tag, "small")) s.font_size *= 0.8333;
        if (eq(u8, tag, "big")) s.font_size *= 1.2;
        if (eq(u8, tag, "a")) s.color = .{ .r = 0, .g = 0, .b = 0.933 };
        if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') {
            const scale = [_]f64{ 2, 1.5, 1.17, 1, 0.83, 0.67 };
            s.font_size *= scale[tag[1] - '1'];
        }
    }

    fn blockMargin(tag: []const u8, size: f64) f64 {
        const eq = std.mem.eql;
        if (eq(u8, tag, "p") or eq(u8, tag, "ul") or eq(u8, tag, "ol") or eq(u8, tag, "blockquote") or eq(u8, tag, "pre")) return size;
        if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') {
            const m = [_]f64{ 0.67, 0.83, 1, 1.33, 1.67, 2.33 };
            return m[tag[1] - '1'] * size;
        }
        return 0;
    }

    fn isBlock(tag: []const u8) bool {
        const names = [_][]const u8{ "div", "p", "ul", "ol", "li", "section", "article", "header", "footer", "nav", "main", "aside", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "body", "center" };
        for (names) |n| if (std.mem.eql(u8, n, tag)) return true;
        return false;
    }

    fn walk(h: *Html, node: *xml.Node, parent: *const sty.Style, depth: u32) Error!void {
        if (depth > 40) return;
        for (node.children.items) |ch| {
            if (ch.is_text) {
                var it = std.mem.tokenizeAny(u8, ch.text, " \t\r\n");
                if (ch.text.len > 0 and std.ascii.isWhitespace(ch.text[0])) h.need_space = true;
                while (it.next()) |w| try h.word(w, parent);
                if (ch.text.len > 0 and std.ascii.isWhitespace(ch.text[ch.text.len - 1])) h.need_space = true;
                continue;
            }
            const tag = ch.tag;
            if (std.mem.eql(u8, tag, "style") or std.mem.eql(u8, tag, "script")) continue;
            if (std.mem.eql(u8, tag, "br")) {
                h.forced = h.cur.items.len == 0;
                try h.flush();
                continue;
            }
            const lc: sty.LenCtx = .{ .font_size = parent.font_size, .vw = h.l.vw, .vh = h.l.vh };
            var cs = try h.l.r.computeStyle(ch, parent, lc);
            if (!cs.display) continue;
            adjust(tag, &cs);
            cs.fill = .current;
            cs.stroke = .none;
            const block = isBlock(tag);
            const saved_indent = h.indent;
            if (block) {
                try h.flush();
                h.pending = @max(h.pending, blockMargin(tag, cs.font_size));
                if (std.mem.eql(u8, tag, "ul") or std.mem.eql(u8, tag, "ol") or std.mem.eql(u8, tag, "blockquote")) h.indent += 40;
                if (std.mem.eql(u8, tag, "li")) try h.word("\u{2022}", &cs);
            }
            try h.walk(ch, &cs, depth + 1);
            if (block) {
                try h.flush();
                h.pending = @max(h.pending, blockMargin(tag, cs.font_size));
                h.indent = saved_indent;
            }
        }
    }
};

pub fn layoutHtml(r: *draw.Renderer, a: std.mem.Allocator, node: *xml.Node, style: *const sty.Style, c: sty.LenCtx, width: f64) Error![]Run {
    var l: Layout = .{ .r = r, .a = a, .vw = c.vw, .vh = c.vh };
    var h: Html = .{ .l = &l, .a = a, .width = width };
    var base = style.*;
    base.fill = .current;
    base.stroke = .none;
    try h.walk(node, &base, 0);
    try h.flush();
    return finish(&l, a, null);
}
