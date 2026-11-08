const std = @import("std");
const image = @import("image.zig");
const xml = @import("svg_xml.zig");
const css = @import("svg_css.zig");
const raster = @import("svg_raster.zig");
const sty = @import("svg_style.zig");
const text = @import("svg_text.zig");
const font = @import("font");
const anim = @import("svg_anim.zig");

const Mat = raster.Mat;
const Pt = raster.Pt;
const Node = xml.Node;
const Style = sty.Style;
const Error = image.Error;

const max_ops = 250_000;
const max_use_depth = 24;
const max_layer_depth = 12;
const max_layer_bytes: usize = 768 * 1024 * 1024;
const max_work: u64 = 2_000_000_000;

pub const ViewBox = struct { x: f64, y: f64, w: f64, h: f64 };

pub fn parseViewBox(s_opt: ?[]const u8) ?ViewBox {
    const s = s_opt orelse return null;
    var sc: raster.NumScan = .{ .s = s };
    const x = sc.number() orelse return null;
    const y = sc.number() orelse return null;
    const w = sc.number() orelse return null;
    const h = sc.number() orelse return null;
    if (!(w > 0 and h > 0)) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub const Par = struct { ax: f64 = 0.5, ay: f64 = 0.5, slice: bool = false, none: bool = false };

pub fn parsePar(s_opt: ?[]const u8) Par {
    var p: Par = .{};
    const s = s_opt orelse return p;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var tok = it.next() orelse return p;
    if (std.mem.eql(u8, tok, "defer")) tok = it.next() orelse return p;
    if (std.mem.eql(u8, tok, "none")) {
        p.none = true;
        return p;
    }
    if (tok.len == 8) {
        p.ax = if (std.mem.startsWith(u8, tok, "xMin")) 0 else if (std.mem.startsWith(u8, tok, "xMax")) 1 else 0.5;
        p.ay = if (std.mem.endsWith(u8, tok, "YMin")) 0 else if (std.mem.endsWith(u8, tok, "YMax")) 1 else 0.5;
    }
    if (it.next()) |m| p.slice = std.mem.eql(u8, m, "slice");
    return p;
}

pub fn viewBoxMat(vb: ViewBox, par: Par, w: f64, h: f64) Mat {
    const sx = w / vb.w;
    const sy = h / vb.h;
    if (par.none) return Mat.scale(sx, sy).mul(Mat.translate(-vb.x, -vb.y));
    const sc = if (par.slice) @max(sx, sy) else @min(sx, sy);
    return Mat.translate((w - vb.w * sc) * par.ax, (h - vb.h * sc) * par.ay).mul(Mat.scale(sc, sc)).mul(Mat.translate(-vb.x, -vb.y));
}

pub const Layer = struct {
    w: usize,
    h: usize,
    px: []u8,

    pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) Error!Layer {
        try image.checkDims(w, h);
        const px = try alloc.alloc(u8, w * h * 4);
        @memset(px, 0);
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(l: *Layer, alloc: std.mem.Allocator) void {
        alloc.free(l.px);
    }

    pub fn unpremultiply(l: *Layer) void {
        var i: usize = 0;
        while (i < l.px.len) : (i += 4) {
            const a = l.px[i + 3];
            if (a == 0 or a == 255) continue;
            for (0..3) |c| {
                const v = (@as(u32, l.px[i + c]) * 255 + a / 2) / a;
                l.px[i + c] = @intCast(@min(v, 255));
            }
        }
    }
};

pub const State = struct {
    ctm: Mat,
    style: Style,
    vw: f64,
    vh: f64,
    target: *Layer,
    clip: ?[]const u8 = null,
    depth: u32 = 0,
    is_root: bool = false,
    via_use: bool = false,
    ov_w: ?f64 = null,
    ov_h: ?f64 = null,
    text_boost: f32 = 0,
};

pub const BBox = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    pub fn w(b: BBox) f64 {
        return b.x1 - b.x0;
    }

    pub fn h(b: BBox) f64 {
        return b.y1 - b.y0;
    }

    pub fn unite(a: ?BBox, b: ?BBox) ?BBox {
        const x = a orelse return b;
        const y = b orelse return a;
        return .{ .x0 = @min(x.x0, y.x0), .y0 = @min(x.y0, y.y0), .x1 = @max(x.x1, y.x1), .y1 = @max(x.y1, y.y1) };
    }
};

pub const Stop = struct { off: f32, c: [4]f32 };

pub const Grad = struct {
    radial: bool,
    sweep: ?[2]f64 = null,
    p: [6]f64,
    stops: []const Stop,
    spread: u8,
    inv: Mat,
    opacity: f32,
};

const Tex = struct { px: []const u8, w: usize, h: usize, inv: Mat, repeat: bool, opacity: f32 };

pub const Src = union(enum) { solid: [4]f32, grad: Grad, tex: Tex };

fn solidSrc(c: sty.Color, opacity: f32) Src {
    const a = c.a * opacity;
    return .{ .solid = .{ c.r * a, c.g * a, c.b * a, a } };
}

fn spreadT(t: f64, spread: u8) f64 {
    return switch (spread) {
        1 => blk: {
            const u = @mod(t, 2.0);
            break :blk if (u > 1) 2 - u else u;
        },
        2 => t - @floor(t),
        else => std.math.clamp(t, 0, 1),
    };
}

fn gradColor(g: *const Grad, x: f64, y: f64) [4]f32 {
    const q = g.inv.apply(.{ .x = x, .y = y });
    var t: f64 = 0;
    if (g.sweep) |sw| {
        var delta = std.math.atan2(q.y - g.p[1], q.x - g.p[0]) - sw[0];
        delta = @mod(delta, 2 * std.math.pi);
        const span = sw[1] - sw[0];
        t = if (span != 0) delta / span else 0;
    } else if (!g.radial) {
        const dx = g.p[2] - g.p[0];
        const dy = g.p[3] - g.p[1];
        const dd = dx * dx + dy * dy;
        if (dd == 0) return .{ 0, 0, 0, 0 };
        t = ((q.x - g.p[0]) * dx + (q.y - g.p[1]) * dy) / dd;
    } else {
        const cx = g.p[0];
        const cy = g.p[1];
        const r = g.p[2];
        const fx = g.p[3];
        const fy = g.p[4];
        const fr = g.p[5];
        const cdx = cx - fx;
        const cdy = cy - fy;
        const dr = r - fr;
        const pdx = q.x - fx;
        const pdy = q.y - fy;
        const a = cdx * cdx + cdy * cdy - dr * dr;
        const b = pdx * cdx + pdy * cdy + fr * dr;
        const c = pdx * pdx + pdy * pdy - fr * fr;
        if (@abs(a) < 1e-12) {
            if (@abs(b) < 1e-12) return .{ 0, 0, 0, 0 };
            t = c / (2 * b);
        } else {
            const disc = b * b - a * c;
            if (disc < 0) return .{ 0, 0, 0, 0 };
            const sq = @sqrt(disc);
            const t1 = (b + sq) / a;
            const t2 = (b - sq) / a;
            const hi = @max(t1, t2);
            const lo = @min(t1, t2);
            if (fr + hi * dr >= 0) {
                t = hi;
            } else if (fr + lo * dr >= 0) {
                t = lo;
            } else return .{ 0, 0, 0, 0 };
        }
    }
    const u: f32 = @floatCast(spreadT(t, g.spread));
    var col: [4]f32 = undefined;
    const st = g.stops;
    if (u <= st[0].off) {
        col = st[0].c;
    } else if (u >= st[st.len - 1].off) {
        col = st[st.len - 1].c;
    } else {
        col = st[st.len - 1].c;
        for (1..st.len) |i| {
            if (u <= st[i].off) {
                const span = st[i].off - st[i - 1].off;
                const f = if (span > 0) (u - st[i - 1].off) / span else 1;
                for (0..4) |k| col[k] = st[i - 1].c[k] + (st[i].c[k] - st[i - 1].c[k]) * f;
                break;
            }
        }
    }
    const a = col[3] * g.opacity;
    return .{ col[0] * a, col[1] * a, col[2] * a, a };
}

fn texFetch(t: *const Tex, ix: isize, iy: isize) [4]f32 {
    const w: isize = @intCast(t.w);
    const h: isize = @intCast(t.h);
    const x: isize = if (t.repeat) @mod(ix, w) else std.math.clamp(ix, 0, w - 1);
    const y: isize = if (t.repeat) @mod(iy, h) else std.math.clamp(iy, 0, h - 1);
    const o = (@as(usize, @intCast(y)) * t.w + @as(usize, @intCast(x))) * 4;
    return .{ @floatFromInt(t.px[o]), @floatFromInt(t.px[o + 1]), @floatFromInt(t.px[o + 2]), @floatFromInt(t.px[o + 3]) };
}

fn texColor(t: *const Tex, x: f64, y: f64) [4]f32 {
    const q = t.inv.apply(.{ .x = x, .y = y });
    const u = q.x - 0.5;
    const v = q.y - 0.5;
    const fu = @floor(u);
    const fv = @floor(v);
    const ix: isize = @intFromFloat(std.math.clamp(fu, -1e9, 1e9));
    const iy: isize = @intFromFloat(std.math.clamp(fv, -1e9, 1e9));
    const tx: f32 = @floatCast(u - fu);
    const ty: f32 = @floatCast(v - fv);
    const c00 = texFetch(t, ix, iy);
    const c10 = texFetch(t, ix + 1, iy);
    const c01 = texFetch(t, ix, iy + 1);
    const c11 = texFetch(t, ix + 1, iy + 1);
    var out: [4]f32 = undefined;
    for (0..4) |k| {
        const top = c00[k] + (c10[k] - c00[k]) * tx;
        const bot = c01[k] + (c11[k] - c01[k]) * tx;
        out[k] = (top + (bot - top) * ty) / 255 * t.opacity;
    }
    return out;
}

fn paintCover(t: *Layer, cov: raster.Cover, src: Src, clip: ?[]const u8) void {
    for (0..cov.h) |row| {
        const y = cov.y0 + row;
        for (0..cov.w) |col| {
            const c = cov.data[row * cov.w + col];
            if (c == 0) continue;
            const x = cov.x0 + col;
            var m: f32 = @as(f32, @floatFromInt(c)) / 255;
            if (clip) |cp| {
                const cv = cp[y * t.w + x];
                if (cv == 0) continue;
                m *= @as(f32, @floatFromInt(cv)) / 255;
            }
            const color: [4]f32 = switch (src) {
                .solid => |s| s,
                .grad => |*g| gradColor(g, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5),
                .tex => |*tx| texColor(tx, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5),
            };
            const sa = color[3] * m;
            if (sa <= 0) continue;
            const o = (y * t.w + x) * 4;
            const inv = 1 - sa;
            for (0..3) |k| {
                const d: f32 = @floatFromInt(t.px[o + k]);
                t.px[o + k] = @intFromFloat(@min(255, color[k] * m * 255 + d * inv + 0.5));
            }
            const da: f32 = @floatFromInt(t.px[o + 3]);
            t.px[o + 3] = @intFromFloat(@min(255, sa * 255 + da * inv + 0.5));
        }
    }
}

pub fn compositeLayer(dst: *Layer, src: *const Layer, opacity: f32, masks: []const []const u8) void {
    var i: usize = 0;
    while (i < src.px.len) : (i += 4) {
        const sa8 = src.px[i + 3];
        if (sa8 == 0) continue;
        var m = opacity;
        for (masks) |mk| m *= @as(f32, @floatFromInt(mk[i / 4])) / 255;
        if (m <= 0) continue;
        const sa = @as(f32, @floatFromInt(sa8)) / 255 * m;
        const inv = 1 - sa;
        for (0..3) |k| {
            const s: f32 = @floatFromInt(src.px[i + k]);
            const d: f32 = @floatFromInt(dst.px[i + k]);
            dst.px[i + k] = @intFromFloat(@min(255, s * m + d * inv + 0.5));
        }
        const da: f32 = @floatFromInt(dst.px[i + 3]);
        dst.px[i + 3] = @intFromFloat(@min(255, sa * 255 + da * inv + 0.5));
    }
}

fn textBoost(s: *const Style) f32 {
    const c: sty.Color = switch (s.fill) {
        .color => |col| col,
        .current => s.color,
        else => return 1,
    };
    const lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    return 1 + 0.45 * (1 - lum);
}

fn lumOf(c: [3]f32) f32 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

fn clipColor(c: [3]f32) [3]f32 {
    const l = lumOf(c);
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    var o = c;
    if (n < 0) for (&o) |*v| {
        v.* = l + (v.* - l) * l / (l - n);
    };
    if (x > 1) for (&o) |*v| {
        v.* = l + (v.* - l) * (1 - l) / (x - l);
    };
    return o;
}

fn setLum(c: [3]f32, l: f32) [3]f32 {
    const d = l - lumOf(c);
    return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
}

fn satOf(c: [3]f32) f32 {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
}

fn setSat(c: [3]f32, sat: f32) [3]f32 {
    var idx = [3]usize{ 0, 1, 2 };
    if (c[idx[0]] > c[idx[1]]) std.mem.swap(usize, &idx[0], &idx[1]);
    if (c[idx[1]] > c[idx[2]]) std.mem.swap(usize, &idx[1], &idx[2]);
    if (c[idx[0]] > c[idx[1]]) std.mem.swap(usize, &idx[0], &idx[1]);
    var o = [3]f32{ 0, 0, 0 };
    const mn = c[idx[0]];
    const md = c[idx[1]];
    const mx = c[idx[2]];
    if (mx > mn) {
        o[idx[1]] = (md - mn) * sat / (mx - mn);
        o[idx[2]] = sat;
    }
    return o;
}

fn blendFn(mode: sty.Blend, cb: f32, cs: f32) f32 {
    return switch (mode) {
        .multiply => cb * cs,
        .screen => cb + cs - cb * cs,
        .overlay => blendFn(.hard_light, cs, cb),
        .darken => @min(cb, cs),
        .lighten => @max(cb, cs),
        .color_dodge => if (cb == 0) 0 else if (cs >= 1) 1 else @min(1, cb / (1 - cs)),
        .color_burn => if (cb >= 1) 1 else if (cs <= 0) 0 else 1 - @min(1, (1 - cb) / cs),
        .hard_light => if (cs <= 0.5) cb * 2 * cs else blendFn(.screen, cb, 2 * cs - 1),
        .soft_light => blk: {
            if (cs <= 0.5) break :blk cb - (1 - 2 * cs) * cb * (1 - cb);
            const d = if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb);
            break :blk cb + (2 * cs - 1) * (d - cb);
        },
        .difference => @abs(cb - cs),
        .exclusion => cb + cs - 2 * cb * cs,
        else => cs,
    };
}

fn blendColor(mode: sty.Blend, cb: [3]f32, cs: [3]f32) [3]f32 {
    return switch (mode) {
        .hue => setLum(setSat(cs, satOf(cb)), lumOf(cb)),
        .saturation => setLum(setSat(cb, satOf(cs)), lumOf(cb)),
        .color => setLum(cs, lumOf(cb)),
        .luminosity => setLum(cb, lumOf(cs)),
        else => .{ blendFn(mode, cb[0], cs[0]), blendFn(mode, cb[1], cs[1]), blendFn(mode, cb[2], cs[2]) },
    };
}

pub fn blendLayer(dst: *Layer, src: *const Layer, opacity: f32, masks: []const []const u8, mode: sty.Blend) void {
    var i: usize = 0;
    while (i < src.px.len) : (i += 4) {
        const sa8 = src.px[i + 3];
        if (sa8 == 0) continue;
        var m = opacity;
        for (masks) |mk| m *= @as(f32, @floatFromInt(mk[i / 4])) / 255;
        if (m <= 0) continue;
        const sa = @as(f32, @floatFromInt(sa8)) / 255;
        const ba = @as(f32, @floatFromInt(dst.px[i + 3])) / 255;
        var cs: [3]f32 = .{ 0, 0, 0 };
        var cb: [3]f32 = .{ 0, 0, 0 };
        for (0..3) |k| {
            cs[k] = @as(f32, @floatFromInt(src.px[i + k])) / 255 / sa;
            if (ba > 0) cb[k] = @as(f32, @floatFromInt(dst.px[i + k])) / 255 / ba;
        }
        const bl = blendColor(mode, cb, cs);
        const a = sa * m;
        const ra = a + ba * (1 - a);
        for (0..3) |k| {
            const co = a * (1 - ba) * cs[k] + a * ba * std.math.clamp(bl[k], 0, 1) + (1 - a) * ba * cb[k];
            dst.px[i + k] = @intFromFloat(std.math.clamp(co * 255 + 0.5, 0, 255));
        }
        dst.px[i + 3] = @intFromFloat(std.math.clamp(ra * 255 + 0.5, 0, 255));
    }
}

fn mulPlane(dst: []u8, other: []const u8) void {
    for (dst, other) |*d, o| d.* = @intCast((@as(u32, d.*) * o + 127) / 255);
}

fn isPresentation(name: []const u8) bool {
    for (sty.presentation_attrs) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

fn isShape(tag: []const u8) bool {
    inline for (.{ "path", "rect", "circle", "ellipse", "line", "polyline", "polygon" }) |t| if (std.mem.eql(u8, tag, t)) return true;
    return false;
}

fn isGradient(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "linearGradient") or std.mem.eql(u8, tag, "radialGradient");
}

fn langOk(n: *const Node) bool {
    const l = n.attr("systemLanguage") orelse return true;
    var it = std.mem.tokenizeAny(u8, l, ", ");
    while (it.next()) |t| if (std.ascii.startsWithIgnoreCase(t, "en")) return true;
    return false;
}

threadlocal var current: ?*Renderer = null;

pub fn setCurrent(r: ?*Renderer) ?*Renderer {
    const prev = current;
    current = r;
    return prev;
}

/// SVG2 geometry properties set through CSS win over the attribute of the same name.
pub fn attrOf(n: *const Node, name: []const u8) ?[]const u8 {
    if (current) |r| if (r.geo.get(n)) |list| {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, list[i].name, name)) return list[i].value;
        }
    };
    return n.attr(name);
}

fn isGeometryName(name: []const u8) bool {
    inline for (.{ "x", "y", "width", "height", "r", "rx", "ry", "cx", "cy", "d" }) |g| if (std.mem.eql(u8, name, g)) return true;
    return false;
}

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ids: std.StringHashMapUnmanaged(*Node) = .empty,
    rules: std.ArrayList(css.Rule) = .empty,
    frames: std.ArrayList(css.Keyframes) = .empty,
    faces: std.ArrayList(css.FontFace) = .empty,
    loaded: std.ArrayList(?*const font.Font) = .empty,
    ras: raster.Raster,
    pa: raster.Polys = .{},
    pb: raster.Polys = .{},
    pc: raster.Polys = .{},
    w: usize = 0,
    h: usize = 0,
    ops: usize = 0,
    // SAFETY: only use_stack[0..use_len] is ever read
    use_stack: [max_use_depth]*Node = undefined,
    use_len: usize = 0,
    work: u64 = 0,
    layer_bytes: usize = 0,
    clip_mode: bool = false,
    layer_depth: u32 = 0,
    nest: u32 = 0,
    renderNested: ?*const fn (std.mem.Allocator, []const u8, u32, u32, u32, f64) Error!image.Image = null,
    time_ms: f64 = 0,
    geo: std.AutoHashMapUnmanaged(*const Node, []const sty.Var) = .empty,
    root_vw: f64 = 100,
    root_vh: f64 = 100,

    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) Renderer {
        return .{ .gpa = gpa, .arena = arena, .ras = raster.Raster.init(gpa) };
    }

    pub fn deinit(r: *Renderer) void {
        r.ras.deinit();
        r.pa.deinit(r.gpa);
        r.pb.deinit(r.gpa);
        r.pc.deinit(r.gpa);
    }

    pub fn collect(r: *Renderer, node: *Node) Error!void {
        if (node.is_text) return;
        if (node.attr("id")) |id| {
            const gop = try r.ids.getOrPut(r.arena, id);
            if (!gop.found_existing) gop.value_ptr.* = node;
        }
        if (std.mem.eql(u8, node.tag, "style")) {
            const ty = node.attr("type") orelse "text/css";
            if (ty.len == 0 or std.mem.eql(u8, ty, "text/css")) {
                for (node.children.items) |c| if (c.is_text) try css.parseStylesheet(r.arena, c.text, &r.rules, &r.frames, &r.faces, .{ .vw = @floatFromInt(r.w), .vh = @floatFromInt(r.h) });
            }
        }
        for (node.children.items) |c| try r.collect(c);
    }

    pub fn charge(r: *Renderer, px: u64) Error!void {
        r.work += px;
        if (r.work > max_work) return error.TooLarge;
    }

    pub fn userFace(r: *Renderer, name: []const u8, weight: u16, italic: bool) ?*const font.Font {
        var best: ?usize = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (r.faces.items, 0..) |f, i| {
            if (!std.ascii.eqlIgnoreCase(f.family, name)) continue;
            const diff: u32 = @abs(@as(i32, f.weight) - weight);
            const score = diff + (if (f.italic != italic) @as(u32, 1000) else 0);
            if (score < best_score) {
                best_score = score;
                best = i;
            }
        }
        const i = best orelse return null;
        while (r.loaded.items.len <= i) r.loaded.append(r.arena, null) catch return null;
        if (r.loaded.items[i]) |f| return f;
        const bytes = (decodeDataUri(r.arena, r.faces.items[i].src) catch return null) orelse return null;
        const f = r.arena.create(font.Font) catch return null;
        f.* = font.Font.init(bytes, 0) catch return null;
        r.loaded.items[i] = f;
        return f;
    }

    pub fn lookup(r: *Renderer, id: []const u8) ?*Node {
        if (id.len == 0) return null;
        return r.ids.get(id);
    }

    fn refNode(r: *Renderer, href: ?[]const u8) ?*Node {
        const h = std.mem.trim(u8, href orelse return null, " \t\r\n");
        if (h.len < 2 or h[0] != '#') return null;
        return r.lookup(h[1..]);
    }

    pub fn computeStyle(r: *Renderer, node: *const Node, parent: *const Style, lc: sty.LenCtx) Error!Style {
        var s = parent.inherit();
        var decls: std.ArrayList(css.Decl) = .empty;
        defer decls.deinit(r.gpa);
        var important: std.ArrayList(css.Decl) = .empty;
        defer important.deinit(r.gpa);
        for (node.attrs.items) |a| if (isPresentation(a.name)) try decls.append(r.gpa, .{ .name = a.name, .value = a.value, .important = false });
        for (r.rules.items) |rule| {
            if (!css.matches(rule, node)) continue;
            for (rule.decls) |d| try (if (d.important) important else decls).append(r.gpa, d);
        }
        if (node.attr("style")) |sa| {
            var parsed: std.ArrayList(css.Decl) = .empty;
            defer parsed.deinit(r.gpa);
            try css.parseDecls(r.gpa, sa, &parsed);
            for (parsed.items) |d| try (if (d.important) important else decls).append(r.gpa, d);
        }
        try decls.appendSlice(r.gpa, important.items);
        var vars: std.ArrayList(sty.Var) = .empty;
        var have_vars = false;
        for (decls.items) |d| {
            if (!std.mem.startsWith(u8, d.name, "--")) continue;
            if (!have_vars) {
                try vars.appendSlice(r.arena, s.vars);
                have_vars = true;
            }
            const val = (try sty.resolveValue(r.arena, d.value, vars.items, lc, 0)) orelse continue;
            try vars.append(r.arena, .{ .name = d.name, .value = val });
        }
        if (have_vars) s.vars = vars.items;
        var geo: std.ArrayList(sty.Var) = .empty;
        for (decls.items) |d| {
            if (!isGeometryName(d.name)) continue;
            var val = (try sty.resolveValue(r.arena, d.value, s.vars, lc, 0)) orelse continue;
            if (std.mem.eql(u8, d.name, "d")) {
                if (std.mem.eql(u8, val, "none")) continue;
                if (std.mem.startsWith(u8, val, "path(")) {
                    const open = std.mem.indexOfAny(u8, val, "\"'") orelse continue;
                    const close = std.mem.lastIndexOfAny(u8, val, "\"'") orelse continue;
                    if (close <= open) continue;
                    val = val[open + 1 .. close];
                }
            }
            try geo.append(r.arena, .{ .name = d.name, .value = val });
        }
        if (geo.items.len > 0) try r.geo.put(r.arena, node, geo.items);
        for ([_]bool{ true, false }) |font_pass| {
            for (decls.items) |d| {
                if (std.mem.startsWith(u8, d.name, "--")) continue;
                const is_font = std.mem.eql(u8, d.name, "font-size") or std.mem.eql(u8, d.name, "font");
                if (is_font != font_pass) continue;
                const val = (try sty.resolveValue(r.arena, d.value, s.vars, .{ .font_size = s.font_size, .vw = lc.vw, .vh = lc.vh }, 0)) orelse continue;
                try sty.apply(r.arena, &s, d.name, val, lc);
            }
        }
        if (s.anims.len > 0) {
            var res: std.ArrayList(anim.CssResult) = .empty;
            try anim.cssAnimations(r.arena, s.anims, r.frames.items, decls.items, node, r.time_ms, &res);
            for (res.items) |d| {
                const val = (try sty.resolveValue(r.arena, d.value, s.vars, lc, 0)) orelse continue;
                try sty.apply(r.arena, &s, d.name, val, lc);
            }
        }
        return s;
    }

    pub fn styleOfNode(r: *Renderer, node: *const Node) Error!Style {
        var chain: [220]*const Node = undefined;
        var n: usize = 0;
        var p: ?*const Node = node;
        while (p) |q| : (p = q.parent) {
            if (n >= chain.len) return error.TooLarge;
            chain[n] = q;
            n += 1;
        }
        var s: Style = .{};
        const base: sty.LenCtx = .{ .vw = r.root_vw, .vh = r.root_vh };
        while (n > 0) {
            n -= 1;
            s = try r.computeStyle(chain[n], &s, .{ .font_size = s.font_size, .vw = base.vw, .vh = base.vh });
        }
        return s;
    }

    fn lcOf(st: *const State) sty.LenCtx {
        return .{ .font_size = st.style.font_size, .vw = st.vw, .vh = st.vh };
    }

    fn lenA(n: *const Node, name: []const u8, axis: sty.Axis, c: sty.LenCtx, def: f64) f64 {
        return sty.lenOr(attrOf(n, name), axis, c, def);
    }

    pub fn drawNode(r: *Renderer, node: *Node, parent: *const State) Error!void {
        if (node.is_text) return;
        r.ops += 1;
        if (r.ops > max_ops) return error.TooLarge;
        const tag = node.tag;
        const is_vp = std.mem.eql(u8, tag, "svg") or std.mem.eql(u8, tag, "symbol");
        if (!(isShape(tag) or is_vp or r.isContainer(tag) or std.mem.eql(u8, tag, "use") or std.mem.eql(u8, tag, "image") or std.mem.eql(u8, tag, "text") or std.mem.eql(u8, tag, "foreignObject"))) return;
        if (std.mem.eql(u8, tag, "symbol") and !parent.via_use) return;
        if (!langOk(node)) return;
        var st = parent.*;
        st.is_root = false;
        st.style = try r.computeStyle(node, &parent.style, lcOf(parent));
        if (!st.style.display) return;
        if (!is_vp) {
            st.ov_w = null;
            st.ov_h = null;
        }
        st.via_use = false;
        const ta = st.style.transform orelse node.attr("transform");
        if (ta) |t| {
            if (sty.parseTransform(t)) |m| {
                if (try r.transformOrigin(node, &st)) |o| {
                    st.ctm = st.ctm.mul(Mat.translate(o.x, o.y)).mul(m).mul(Mat.translate(-o.x, -o.y));
                } else st.ctm = st.ctm.mul(m);
            }
        }
        if (!(@abs(st.ctm.det()) > 1e-12) or !std.math.isFinite(st.ctm.det())) return;
        try r.drawWithEffects(node, &st);
    }

    fn transformOrigin(r: *Renderer, node: *Node, st: *const State) Error!?Pt {
        const s = &st.style;
        const fill_box = std.mem.eql(u8, s.transform_box, "fill-box") or std.mem.eql(u8, s.transform_box, "stroke-box");
        var spec = s.transform_origin;
        if (spec.len == 0) {
            if (!fill_box) return null;
            spec = "50% 50%";
        }
        var bx: BBox = .{ .x0 = 0, .y0 = 0, .x1 = st.vw, .y1 = st.vh };
        if (fill_box) bx = (try r.bboxContent(node, s, st.vw, st.vh, Mat.identity, 0)) orelse return null;
        var toks: [3][]const u8 = .{ "50%", "50%", "0" };
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, spec, " \t,");
        while (it.next()) |t| {
            if (n >= 3) break;
            toks[n] = t;
            n += 1;
        }
        if (n == 1 and (std.mem.eql(u8, toks[0], "top") or std.mem.eql(u8, toks[0], "bottom"))) {
            toks[1] = toks[0];
            toks[0] = "center";
        }
        if (n >= 2 and (std.mem.eql(u8, toks[0], "top") or std.mem.eql(u8, toks[0], "bottom")) or (n >= 2 and (std.mem.eql(u8, toks[1], "left") or std.mem.eql(u8, toks[1], "right")))) std.mem.swap([]const u8, &toks[0], &toks[1]);
        const c: sty.LenCtx = .{ .font_size = s.font_size, .vw = bx.w(), .vh = bx.h() };
        const coord = struct {
            fn f(tok: []const u8, lo: f64, size: f64, cx: sty.LenCtx, axis: sty.Axis) f64 {
                if (std.mem.eql(u8, tok, "left") or std.mem.eql(u8, tok, "top")) return lo;
                if (std.mem.eql(u8, tok, "right") or std.mem.eql(u8, tok, "bottom")) return lo + size;
                if (std.mem.eql(u8, tok, "center")) return lo + size / 2;
                return lo + sty.lenOr(tok, axis, cx, 0);
            }
        }.f;
        return .{ .x = coord(toks[0], bx.x0, bx.w(), c, .x), .y = coord(toks[1], bx.y0, bx.h(), c, .y) };
    }

    fn isContainer(_: *Renderer, tag: []const u8) bool {
        inline for (.{ "g", "a", "switch" }) |t| if (std.mem.eql(u8, tag, t)) return true;
        return false;
    }

    fn findTag(r: *Renderer, id: []const u8, tag: []const u8) ?*Node {
        const n = r.lookup(id) orelse return null;
        return if (std.mem.eql(u8, n.tag, tag)) n else null;
    }

    pub fn drawWithEffects(r: *Renderer, node: *Node, st: *State) Error!void {
        const s = &st.style;
        const clip_node = r.findTag(s.clip_path, "clipPath");
        if (r.clip_mode) {
            if (clip_node) |cn| {
                const plane = try r.clipPlane(cn, st, node);
                defer r.gpa.free(plane);
                if (st.clip) |pc| mulPlane(plane, pc);
                st.clip = plane;
                return r.drawContent(node, st);
            }
            return r.drawContent(node, st);
        }
        const mask_node = r.findTag(s.mask, "mask");
        const has_filter = r.hasFilter(s.filter);
        const layered = s.blend != .normal or s.isolate;
        if (s.opacity >= 1 and mask_node == null and !has_filter and !layered) {
            if (clip_node) |cn| {
                const plane = try r.clipPlane(cn, st, node);
                defer r.gpa.free(plane);
                if (st.clip) |pc| mulPlane(plane, pc);
                st.clip = plane;
                return r.drawContent(node, st);
            }
            return r.drawContent(node, st);
        }
        var ox: i64 = 0;
        var oy: i64 = 0;
        var bw: usize = st.target.w;
        var bh: usize = st.target.h;
        if (has_filter) if (try r.filterBounds(st, node)) |fb| {
            const nx0 = @min(0, fb[0]);
            const ny0 = @min(0, fb[1]);
            const nx1 = @max(@as(i64, @intCast(st.target.w)), fb[2]);
            const ny1 = @max(@as(i64, @intCast(st.target.h)), fb[3]);
            const px_total: u64 = @as(u64, @intCast(nx1 - nx0)) * @as(u64, @intCast(ny1 - ny0));
            if (px_total <= image.max_pixels) {
                ox = nx0;
                oy = ny0;
                bw = @intCast(nx1 - nx0);
                bh = @intCast(ny1 - ny0);
            }
        };
        const need = bw * bh * 4;
        if (r.layer_depth >= max_layer_depth or r.layer_bytes + need > max_layer_bytes) return r.drawContent(node, st);
        r.layer_depth += 1;
        r.layer_bytes += need;
        defer {
            r.layer_depth -= 1;
            r.layer_bytes -= need;
        }
        try r.charge(@as(u64, bw) * bh * 2);
        var layer = try Layer.init(r.gpa, bw, bh);
        defer layer.deinit(r.gpa);
        var inner = st.*;
        inner.target = &layer;
        inner.clip = null;
        const shifted = Mat.translate(@floatFromInt(-ox), @floatFromInt(-oy)).mul(st.ctm);
        const saved_w = r.w;
        const saved_h = r.h;
        if (ox != 0 or oy != 0 or bw != st.target.w or bh != st.target.h) {
            inner.ctm = shifted;
            r.w = bw;
            r.h = bh;
        }
        defer {
            r.w = saved_w;
            r.h = saved_h;
        }
        try r.drawContent(node, &inner);
        if (has_filter) {
            var fst = st.*;
            fst.ctm = inner.ctm;
            try r.applyFilterList(&layer, &fst, node);
        }
        r.w = saved_w;
        r.h = saved_h;
        if (bw != st.target.w or bh != st.target.h) {
            var vis = try Layer.init(r.gpa, st.target.w, st.target.h);
            for (0..st.target.h) |row| {
                const sy: i64 = @as(i64, @intCast(row)) - oy;
                if (sy < 0 or sy >= bh) continue;
                const sx0: i64 = -ox;
                const n = st.target.w;
                @memcpy(vis.px[row * st.target.w * 4 ..][0 .. n * 4], layer.px[(@as(usize, @intCast(sy)) * bw + @as(usize, @intCast(sx0))) * 4 ..][0 .. n * 4]);
            }
            layer.deinit(r.gpa);
            layer = vis;
        }
        var masks: [3][]const u8 = undefined;
        var n: usize = 0;
        if (st.clip) |c| {
            masks[n] = c;
            n += 1;
        }
        var own_clip: ?[]u8 = null;
        defer if (own_clip) |c| r.gpa.free(c);
        if (clip_node) |cn| {
            own_clip = try r.clipPlane(cn, st, node);
            masks[n] = own_clip.?;
            n += 1;
        }
        var own_mask: ?[]u8 = null;
        defer if (own_mask) |c| r.gpa.free(c);
        if (mask_node) |mn| {
            own_mask = try r.maskPlane(mn, st, node);
            masks[n] = own_mask.?;
            n += 1;
        }
        if (s.blend != .normal) {
            blendLayer(st.target, &layer, s.opacity, masks[0..n], s.blend);
        } else compositeLayer(st.target, &layer, s.opacity, masks[0..n]);
    }

    fn filterBounds(r: *Renderer, st: *const State, node: *Node) Error!?[4]i64 {
        var depth: u32 = 0;
        var start: usize = 0;
        const v = st.style.filter;
        var i: usize = 0;
        while (i <= v.len) : (i += 1) {
            const c: u8 = if (i < v.len) v[i] else ' ';
            if (c == '(') depth += 1;
            if (c == ')' and depth > 0) depth -= 1;
            if (std.ascii.isWhitespace(c) and depth == 0) {
                const tok = v[start..i];
                start = i + 1;
                if (sty.parseUrlRef(tok)) |u| if (r.findTag(u.id, "filter")) |fnode| {
                    const reg = (try @import("svg_filter_apply.zig").region(r, fnode, st, node)) orelse return null;
                    return .{
                        @intFromFloat(std.math.clamp(@floor(reg.x0), -1e7, 1e7)),
                        @intFromFloat(std.math.clamp(@floor(reg.y0), -1e7, 1e7)),
                        @intFromFloat(std.math.clamp(@ceil(reg.x1), -1e7, 1e7)),
                        @intFromFloat(std.math.clamp(@ceil(reg.y1), -1e7, 1e7)),
                    };
                };
            }
        }
        return null;
    }

    fn hasFilter(r: *Renderer, v: []const u8) bool {
        if (v.len == 0) return false;
        var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
        while (it.next()) |_| return true;
        _ = r;
        return false;
    }

    fn applyFilterList(r: *Renderer, layer: *Layer, st: *const State, node: *Node) Error!void {
        var depth: u32 = 0;
        var start: usize = 0;
        const v = st.style.filter;
        var i: usize = 0;
        while (i <= v.len) : (i += 1) {
            const c: u8 = if (i < v.len) v[i] else ' ';
            if (c == '(') depth += 1;
            if (c == ')' and depth > 0) depth -= 1;
            if (std.ascii.isWhitespace(c) and depth == 0) {
                const tok = v[start..i];
                start = i + 1;
                if (tok.len == 0) continue;
                if (sty.parseUrlRef(tok)) |u| {
                    if (r.findTag(u.id, "filter")) |fnode| try r.applyFilter(fnode, layer, st, node);
                } else if (std.mem.indexOfScalar(u8, tok, '(')) |open| {
                    if (tok[tok.len - 1] == ')') try @import("svg_filter_apply.zig").applyFunction(r, layer, st, tok[0..open], tok[open + 1 .. tok.len - 1]);
                }
            }
        }
    }

    fn drawChildren(r: *Renderer, node: *Node, st: *const State) Error!void {
        for (node.children.items) |c| try r.drawNode(c, st);
    }

    fn drawContent(r: *Renderer, node: *Node, st: *State) Error!void {
        const tag = node.tag;
        if (isShape(tag)) return r.drawShape(node, st);
        if (std.mem.eql(u8, tag, "g") or std.mem.eql(u8, tag, "a")) return r.drawChildren(node, st);
        if (std.mem.eql(u8, tag, "switch")) {
            for (node.children.items) |c| {
                if (c.is_text or !langOk(c)) continue;
                if (c.attr("requiredExtensions")) |re| if (std.mem.indexOf(u8, re, "xhtml") == null) continue;
                return r.drawNode(c, st);
            }
            return;
        }
        if (std.mem.eql(u8, tag, "svg") or std.mem.eql(u8, tag, "symbol")) return r.drawViewport(node, st);
        if (std.mem.eql(u8, tag, "use")) return r.drawUse(node, st);
        if (std.mem.eql(u8, tag, "image")) return r.drawImage(node, st);
        if (std.mem.eql(u8, tag, "text")) return r.drawText(node, st);
        if (std.mem.eql(u8, tag, "foreignObject")) return r.drawForeign(node, st);
    }

    fn drawViewport(r: *Renderer, node: *Node, st: *State) Error!void {
        if (st.is_root) {
            st.is_root = false;
            return r.drawChildren(node, st);
        }
        const c = lcOf(st);
        const is_sym = std.mem.eql(u8, node.tag, "symbol");
        const x = if (is_sym) 0 else lenA(node, "x", .x, c, 0);
        const y = if (is_sym) 0 else lenA(node, "y", .y, c, 0);
        const w = st.ov_w orelse lenA(node, "width", .x, c, st.vw);
        const h = st.ov_h orelse lenA(node, "height", .y, c, st.vh);
        if (!(w > 0 and h > 0)) return;
        var s2 = st.*;
        s2.ov_w = null;
        s2.ov_h = null;
        s2.ctm = st.ctm.mul(Mat.translate(x, y));
        var vw = w;
        var vh = h;
        if (parseViewBox(node.attr("viewBox"))) |vb| {
            s2.ctm = s2.ctm.mul(viewBoxMat(vb, parsePar(node.attr("preserveAspectRatio")), w, h));
            vw = vb.w;
            vh = vb.h;
        }
        s2.vw = vw;
        s2.vh = vh;
        var plane: ?[]u8 = null;
        defer if (plane) |p| r.gpa.free(p);
        if (!st.style.overflow_visible) {
            plane = try r.rectPlane(st.ctm, x, y, w, h);
            if (st.clip) |pc| mulPlane(plane.?, pc);
            s2.clip = plane;
        }
        try r.drawChildren(node, &s2);
    }

    fn drawUse(r: *Renderer, node: *Node, st: *State) Error!void {
        const ref = r.refNode(node.href()) orelse return;
        if (st.depth >= max_use_depth or r.use_len >= max_use_depth) return;
        for (r.use_stack[0..r.use_len]) |active| if (active == ref) return;
        r.use_stack[r.use_len] = ref;
        r.use_len += 1;
        defer r.use_len -= 1;
        const c = lcOf(st);
        var s2 = st.*;
        s2.depth += 1;
        s2.ctm = st.ctm.mul(Mat.translate(lenA(node, "x", .x, c, 0), lenA(node, "y", .y, c, 0)));
        s2.via_use = true;
        s2.ov_w = null;
        s2.ov_h = null;
        if (sty.parseLen(attrOf(node, "width") orelse "")) |l| s2.ov_w = sty.resolveLen(l, .x, c);
        if (sty.parseLen(attrOf(node, "height") orelse "")) |l| s2.ov_h = sty.resolveLen(l, .y, c);
        if (std.mem.eql(u8, ref.tag, "symbol") or std.mem.eql(u8, ref.tag, "svg")) {
            if (s2.ov_w == null) s2.ov_w = if (std.mem.eql(u8, ref.tag, "svg")) null else st.vw;
            if (s2.ov_h == null) s2.ov_h = if (std.mem.eql(u8, ref.tag, "svg")) null else st.vh;
        }
        try r.drawNode(ref, &s2);
    }

    fn rectPlane(r: *Renderer, m: Mat, x: f64, y: f64, w: f64, h: f64) Error![]u8 {
        try r.charge(@as(u64, r.w) * r.h);
        const plane = try r.gpa.alloc(u8, r.w * r.h);
        @memset(plane, 0);
        errdefer r.gpa.free(plane);
        r.pa.clear();
        try r.pa.pts.appendSlice(r.gpa, &.{ m.apply(.{ .x = x, .y = y }), m.apply(.{ .x = x + w, .y = y }), m.apply(.{ .x = x + w, .y = y + h }), m.apply(.{ .x = x, .y = y + h }) });
        try r.pa.subs.append(r.gpa, .{ .start = 0, .len = 4, .closed = true });
        try r.copyCover(&r.pa, .nonzero, plane);
        return plane;
    }

    fn copyCover(r: *Renderer, polys: *const raster.Polys, rule: raster.FillRule, plane: []u8) Error!void {
        const cov = (try r.ras.fill(polys, rule, r.w, r.h)) orelse return;
        for (0..cov.h) |row| {
            @memcpy(plane[(cov.y0 + row) * r.w + cov.x0 ..][0..cov.w], cov.data[row * cov.w ..][0..cov.w]);
        }
    }

    pub fn shapePath(r: *Renderer, node: *const Node, c: sty.LenCtx, path: *raster.Path) Error!void {
        const a = r.gpa;
        const tag = node.tag;
        if (std.mem.eql(u8, tag, "path")) {
            try raster.parsePathData(a, attrOf(node, "d") orelse return, path);
        } else if (std.mem.eql(u8, tag, "rect")) {
            const x = lenA(node, "x", .x, c, 0);
            const y = lenA(node, "y", .y, c, 0);
            const w = lenA(node, "width", .x, c, 0);
            const h = lenA(node, "height", .y, c, 0);
            if (!(w > 0 and h > 0)) return;
            var rx = lenA(node, "rx", .x, c, -1);
            var ry = lenA(node, "ry", .y, c, -1);
            if (rx < 0 and ry < 0) {
                rx = 0;
                ry = 0;
            } else if (rx < 0) {
                rx = ry;
            } else if (ry < 0) ry = rx;
            rx = @min(rx, w / 2);
            ry = @min(ry, h / 2);
            if (rx <= 0 or ry <= 0) {
                try path.moveTo(a, x, y);
                try path.lineTo(a, x + w, y);
                try path.lineTo(a, x + w, y + h);
                try path.lineTo(a, x, y + h);
                try path.close(a);
            } else {
                try path.moveTo(a, x + rx, y);
                try path.lineTo(a, x + w - rx, y);
                try path.arcTo(a, rx, ry, 0, false, true, x + w, y + ry);
                try path.lineTo(a, x + w, y + h - ry);
                try path.arcTo(a, rx, ry, 0, false, true, x + w - rx, y + h);
                try path.lineTo(a, x + rx, y + h);
                try path.arcTo(a, rx, ry, 0, false, true, x, y + h - ry);
                try path.lineTo(a, x, y + ry);
                try path.arcTo(a, rx, ry, 0, false, true, x + rx, y);
                try path.close(a);
            }
        } else if (std.mem.eql(u8, tag, "circle") or std.mem.eql(u8, tag, "ellipse")) {
            const cx = lenA(node, "cx", .x, c, 0);
            const cy = lenA(node, "cy", .y, c, 0);
            const is_circle = tag[1] == 'i';
            const rx0 = if (is_circle) lenA(node, "r", .diag, c, 0) else lenA(node, "rx", .x, c, -1);
            const ry0 = if (is_circle) rx0 else lenA(node, "ry", .y, c, -1);
            const rx = if (rx0 < 0) ry0 else rx0;
            const ry = if (ry0 < 0) rx0 else ry0;
            if (!(rx > 0 and ry > 0)) return;
            try path.moveTo(a, cx + rx, cy);
            try path.arcTo(a, rx, ry, 0, false, true, cx, cy + ry);
            try path.arcTo(a, rx, ry, 0, false, true, cx - rx, cy);
            try path.arcTo(a, rx, ry, 0, false, true, cx, cy - ry);
            try path.arcTo(a, rx, ry, 0, false, true, cx + rx, cy);
            try path.close(a);
        } else if (std.mem.eql(u8, tag, "line")) {
            try path.moveTo(a, lenA(node, "x1", .x, c, 0), lenA(node, "y1", .y, c, 0));
            try path.lineTo(a, lenA(node, "x2", .x, c, 0), lenA(node, "y2", .y, c, 0));
        } else {
            var sc: raster.NumScan = .{ .s = node.attr("points") orelse return };
            var first = true;
            while (true) {
                const x = sc.number() orelse break;
                const y = sc.number() orelse break;
                if (first) {
                    try path.moveTo(a, x, y);
                    first = false;
                } else try path.lineTo(a, x, y);
            }
            if (!first and std.mem.eql(u8, tag, "polygon")) try path.close(a);
        }
    }

    fn pathBBox(r: *Renderer, path: *const raster.Path, m: Mat) Error!?BBox {
        r.pc.clear();
        try raster.flatten(r.gpa, path, m, 0.05, &r.pc);
        var bb: ?BBox = null;
        for (r.pc.pts.items) |p| {
            if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) continue;
            bb = BBox.unite(bb, .{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y });
        }
        return bb;
    }

    fn fillSrc(r: *Renderer, st: *const State, polys: *const raster.Polys, rule: raster.FillRule, src: Src) Error!void {
        const cov = (try r.ras.fill(polys, rule, st.target.w, st.target.h)) orelse return;
        try r.charge(@as(u64, cov.w) * cov.h * (if (src == .solid) @as(u64, 1) else 6));
        if (st.text_boost > 1) {
            var lut: [256]u8 = undefined;
            for (&lut, 0..) |*o, i| o.* = @intFromFloat(std.math.pow(f32, @as(f32, @floatFromInt(i)) / 255, 1 / st.text_boost) * 255 + 0.5);
            for (cov.data) |*d| d.* = lut[d.*];
        }
        if (st.style.crisp) for (cov.data) |*d| {
            d.* = if (d.* >= 128) 255 else 0;
        };
        paintCover(st.target, cov, src, st.clip);
    }

    pub fn fillPath(r: *Renderer, st: *const State, path: *const raster.Path, rule: raster.FillRule, src: Src) Error!void {
        r.pa.clear();
        try raster.flatten(r.gpa, path, st.ctm, 0.1, &r.pa);
        try r.fillSrc(st, &r.pa, rule, src);
    }

    fn strokePath(r: *Renderer, st: *const State, path: *const raster.Path, src: Src) Error!void {
        const s = &st.style;
        if (!(s.stroke_width > 0)) return;
        if (s.non_scaling) {
            r.pb.clear();
            try raster.flatten(r.gpa, path, st.ctm, 0.1, &r.pb);
            r.pa.clear();
            try raster.stroke(r.gpa, &r.pb, .{
                .width = s.stroke_width,
                .cap = s.cap,
                .join = s.join,
                .miter_limit = s.miter_limit,
                .dashes = s.dashes,
                .dash_offset = s.dash_offset,
            }, 0.1, &r.pa);
            try r.fillSrc(st, &r.pa, .nonzero, src);
            return;
        }
        const scale = @max(st.ctm.meanScale(), 1e-6);
        const tol = 0.1 / scale;
        r.pb.clear();
        try raster.flatten(r.gpa, path, Mat.identity, tol, &r.pb);
        r.pa.clear();
        var dash_sum: f64 = 0;
        for (s.dashes) |d| dash_sum += d;
        try raster.stroke(r.gpa, &r.pb, .{
            .width = s.stroke_width,
            .cap = s.cap,
            .join = s.join,
            .miter_limit = s.miter_limit,
            .dashes = if (dash_sum * scale < 0.2) &.{} else s.dashes,
            .dash_offset = s.dash_offset,
        }, tol, &r.pa);
        r.pa.transform(st.ctm);
        try r.fillSrc(st, &r.pa, .nonzero, src);
    }

    pub fn paintShape(r: *Renderer, st: *const State, path: *const raster.Path, bbox: ?BBox) Error!void {
        const s = &st.style;
        if (r.clip_mode) {
            try r.fillPath(st, path, s.clip_rule, .{ .solid = .{ 1, 1, 1, 1 } });
            return;
        }
        var order = [2]bool{ true, false };
        if (s.stroke_first) order = .{ false, true };
        for (order) |is_fill| {
            if (is_fill) {
                if (try r.resolvePaint(s.fill, st, bbox, s.fill_opacity)) |src| try r.fillPath(st, path, s.fill_rule, src);
            } else {
                if (try r.resolvePaint(s.stroke, st, bbox, s.stroke_opacity)) |src| try r.strokePath(st, path, src);
            }
        }
    }

    fn drawShape(r: *Renderer, node: *Node, st: *State) Error!void {
        if (!st.style.visible) return;
        var path: raster.Path = .{};
        defer path.segs.deinit(r.gpa);
        try r.shapePath(node, lcOf(st), &path);
        if (path.segs.items.len == 0) return;
        const bbox = raster.bounds(&path);
        const bb: ?BBox = if (bbox) |b| .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 } else null;
        try r.paintShape(st, &path, bb);
        if (r.clip_mode) return;
        const s = &st.style;
        const tag = node.tag;
        if ((s.marker_start.len > 0 or s.marker_mid.len > 0 or s.marker_end.len > 0) and !std.mem.eql(u8, tag, "rect") and !std.mem.eql(u8, tag, "circle") and !std.mem.eql(u8, tag, "ellipse")) {
            try r.drawMarkers(st, &path);
        }
    }

    const Vert = struct { p: Pt, din: ?Pt = null, dout: ?Pt = null };

    fn dirOf(a: Pt, b: Pt) ?Pt {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        if (dx == 0 and dy == 0) return null;
        return .{ .x = dx, .y = dy };
    }

    fn firstDir(pts: []const Pt) ?Pt {
        var i: usize = 1;
        while (i < pts.len) : (i += 1) if (dirOf(pts[0], pts[i])) |d| return d;
        return null;
    }

    fn collectVerts(r: *Renderer, path: *const raster.Path, out: *std.ArrayList(Vert)) Error!void {
        var cur: Pt = .{ .x = 0, .y = 0 };
        var start: Pt = cur;
        var sub: usize = 0;
        for (path.segs.items) |sg| {
            switch (sg) {
                .move => |p| {
                    cur = p;
                    start = p;
                    sub = out.items.len;
                    try out.append(r.gpa, .{ .p = p });
                },
                .line => |p| {
                    const d = dirOf(cur, p);
                    if (out.items.len > 0) out.items[out.items.len - 1].dout = d;
                    try out.append(r.gpa, .{ .p = p, .din = d });
                    cur = p;
                },
                .cubic => |c| {
                    const d0 = firstDir(&.{ cur, c[0], c[1], c[2] });
                    const rev = firstDir(&.{ c[2], c[1], c[0], cur });
                    if (out.items.len > 0) out.items[out.items.len - 1].dout = d0;
                    try out.append(r.gpa, .{ .p = c[2], .din = if (rev) |v| Pt{ .x = -v.x, .y = -v.y } else null });
                    cur = c[2];
                },
                .close => {
                    if (out.items.len == 0) continue;
                    const d = dirOf(cur, start);
                    if (d != null) {
                        out.items[out.items.len - 1].dout = d;
                        try out.append(r.gpa, .{ .p = start, .din = d });
                    }
                    const last = &out.items[out.items.len - 1];
                    last.dout = out.items[sub].dout;
                    out.items[sub].din = last.din;
                    cur = start;
                },
            }
        }
    }

    fn drawMarkers(r: *Renderer, st: *const State, path: *const raster.Path) Error!void {
        var verts: std.ArrayList(Vert) = .empty;
        defer verts.deinit(r.gpa);
        try r.collectVerts(path, &verts);
        const s = &st.style;
        const n = verts.items.len;
        for (verts.items, 0..) |v, i| {
            const id = if (i == 0) s.marker_start else if (i == n - 1) s.marker_end else s.marker_mid;
            if (id.len > 0) try r.drawMarker(st, id, v, i == 0);
        }
    }

    fn drawMarker(r: *Renderer, st: *const State, id: []const u8, v: Vert, is_start: bool) Error!void {
        const mk = r.findTag(id, "marker") orelse return;
        r.ops += 1;
        if (r.ops > max_ops or st.depth >= max_use_depth) return;
        const ms = try r.styleOfNode(mk);
        const c: sty.LenCtx = .{ .font_size = ms.font_size, .vw = st.vw, .vh = st.vh };
        const mw = lenA(mk, "markerWidth", .x, c, 3);
        const mh = lenA(mk, "markerHeight", .y, c, 3);
        if (!(mw > 0 and mh > 0)) return;
        const rx = lenA(mk, "refX", .x, c, 0);
        const ry = lenA(mk, "refY", .y, c, 0);
        var ang: f64 = 0;
        const orient = mk.attr("orient") orelse "0";
        if (std.mem.eql(u8, orient, "auto") or std.mem.eql(u8, orient, "auto-start-reverse")) {
            const din = v.din orelse v.dout;
            const dout = v.dout orelse v.din;
            if (din != null and dout != null) {
                const a1 = std.math.atan2(din.?.y, din.?.x);
                const a2 = std.math.atan2(dout.?.y, dout.?.x);
                ang = std.math.atan2(@sin(a1) + @sin(a2), @cos(a1) + @cos(a2));
                if (@abs(@sin(a1) + @sin(a2)) < 1e-12 and @abs(@cos(a1) + @cos(a2)) < 1e-12) ang = a1;
            }
            if (is_start and std.mem.eql(u8, orient, "auto-start-reverse")) ang += std.math.pi;
        } else {
            var sc: raster.NumScan = .{ .s = orient };
            ang = (sc.number() orelse 0) * std.math.pi / 180.0;
        }
        const units_user = std.mem.eql(u8, mk.attr("markerUnits") orelse "", "userSpaceOnUse");
        const sw = if (units_user) 1 else st.style.stroke_width;
        var vbm = Mat.identity;
        var vw = mw;
        var vh = mh;
        if (parseViewBox(mk.attr("viewBox"))) |vb| {
            vbm = viewBoxMat(vb, parsePar(mk.attr("preserveAspectRatio")), mw, mh);
            vw = vb.w;
            vh = vb.h;
        }
        const refp = vbm.apply(.{ .x = rx, .y = ry });
        const rot: Mat = .{ .a = @cos(ang), .b = @sin(ang), .c = -@sin(ang), .d = @cos(ang) };
        const vp = st.ctm.mul(Mat.translate(v.p.x, v.p.y)).mul(rot).mul(Mat.scale(sw, sw)).mul(Mat.translate(-refp.x, -refp.y));
        var s2 = st.*;
        s2.ctm = vp.mul(vbm);
        s2.style = ms;
        s2.vw = vw;
        s2.vh = vh;
        s2.depth += 1;
        var plane: ?[]u8 = null;
        defer if (plane) |p| r.gpa.free(p);
        if (!ms.overflow_visible) {
            plane = try r.rectPlane(vp, 0, 0, mw, mh);
            if (st.clip) |pc| mulPlane(plane.?, pc);
            s2.clip = plane;
        }
        try r.drawChildren(mk, &s2);
    }

    fn chainAttr(r: *Renderer, n: *Node, name: []const u8) ?[]const u8 {
        var cur: ?*Node = n;
        var i: u32 = 0;
        while (cur) |c| : (i += 1) {
            if (i > 10) return null;
            if (c.attr(name)) |v| return v;
            cur = r.refNode(c.href());
        }
        return null;
    }

    fn chainChildren(r: *Renderer, n: *Node, tag: []const u8) ?*Node {
        var cur: ?*Node = n;
        var i: u32 = 0;
        while (cur) |c| : (i += 1) {
            if (i > 10) return null;
            for (c.children.items) |ch| if (!ch.is_text and (tag.len == 0 or std.mem.eql(u8, ch.tag, tag))) return c;
            cur = r.refNode(c.href());
        }
        return null;
    }

    fn unitLen(str: ?[]const u8, axis: sty.Axis, bbox_units: bool, c: sty.LenCtx, def: f64) f64 {
        const l = sty.parseLen(str orelse return def) orelse return def;
        if (bbox_units) return if (l.unit == .pct) l.v / 100 else sty.resolveLen(l, axis, .{});
        return sty.resolveLen(l, axis, c);
    }

    pub fn resolvePaint(r: *Renderer, paint: sty.Paint, st: *const State, bbox: ?BBox, opacity: f32) Error!?Src {
        switch (paint) {
            .none => return null,
            .current => return solidSrc(st.style.color, opacity),
            .color => |c| return solidSrc(c, opacity),
            .url => |u| {
                if (r.lookup(u.id)) |n| {
                    if (isGradient(n.tag)) return r.gradientSrc(n, st, bbox, opacity);
                    if (std.mem.eql(u8, n.tag, "pattern")) return r.patternSrc(n, st, bbox, opacity);
                }
                if (u.fb) |fb| switch (fb) {
                    .none => return null,
                    .current => return solidSrc(st.style.color, opacity),
                    .color => |c| return solidSrc(c, opacity),
                };
                return null;
            },
        }
    }

    fn gradientSrc(r: *Renderer, n: *Node, st: *const State, bbox: ?BBox, opacity: f32) Error!?Src {
        const radial = std.mem.eql(u8, n.tag, "radialGradient");
        const bbu = !std.mem.eql(u8, r.chainAttr(n, "gradientUnits") orelse "", "userSpaceOnUse");
        var m = st.ctm;
        const c = lcOf(st);
        if (bbu) {
            const b = bbox orelse return null;
            if (!(b.w() > 0 and b.h() > 0)) return null;
            m = m.mul(.{ .a = b.w(), .d = b.h(), .e = b.x0, .f = b.y0 });
        }
        if (r.chainAttr(n, "gradientTransform")) |t| {
            if (sty.parseTransform(t)) |gm| m = m.mul(gm);
        }
        const inv = m.inverse() orelse return null;
        var p: [6]f64 = undefined;
        if (!radial) {
            p[0] = unitLen(r.chainAttr(n, "x1"), .x, bbu, c, 0);
            p[1] = unitLen(r.chainAttr(n, "y1"), .y, bbu, c, 0);
            p[2] = unitLen(r.chainAttr(n, "x2"), .x, bbu, c, if (bbu) 1 else c.vw);
            p[3] = unitLen(r.chainAttr(n, "y2"), .y, bbu, c, 0);
        } else {
            p[0] = unitLen(r.chainAttr(n, "cx"), .x, bbu, c, if (bbu) 0.5 else c.vw / 2);
            p[1] = unitLen(r.chainAttr(n, "cy"), .y, bbu, c, if (bbu) 0.5 else c.vh / 2);
            p[2] = unitLen(r.chainAttr(n, "r"), .diag, bbu, c, if (bbu) 0.5 else sty.resolveLen(.{ .v = 50, .unit = .pct }, .diag, c));
            p[3] = unitLen(r.chainAttr(n, "fx"), .x, bbu, c, p[0]);
            p[4] = unitLen(r.chainAttr(n, "fy"), .y, bbu, c, p[1]);
            p[5] = unitLen(r.chainAttr(n, "fr"), .diag, bbu, c, 0);
            if (p[2] < 0) return null;
            const fdx = p[3] - p[0];
            const fdy = p[4] - p[1];
            const fd = @sqrt(fdx * fdx + fdy * fdy);
            if (fd > p[2] * 0.999 and fd > 0) {
                const k = p[2] * 0.999 / fd;
                p[3] = p[0] + fdx * k;
                p[4] = p[1] + fdy * k;
            }
        }
        const stops_owner = r.chainChildren(n, "stop") orelse return null;
        const gs = try r.styleOfNode(stops_owner);
        var stops: std.ArrayList(Stop) = .empty;
        var last: f32 = 0;
        for (stops_owner.children.items) |ch| {
            if (ch.is_text or !std.mem.eql(u8, ch.tag, "stop")) continue;
            const ss = try r.computeStyle(ch, &gs, .{ .vw = st.vw, .vh = st.vh });
            var off: f32 = 0;
            if (sty.parseLen(ch.attr("offset") orelse "0")) |l| off = @floatCast(if (l.unit == .pct) l.v / 100 else l.v);
            off = std.math.clamp(off, 0, 1);
            off = @max(off, last);
            last = off;
            const col = ss.stop_color;
            try stops.append(r.arena, .{ .off = off, .c = .{ col.r, col.g, col.b, col.a * ss.stop_opacity } });
            if (stops.items.len >= 512) break;
        }
        if (stops.items.len == 0) return null;
        if (stops.items.len == 1) {
            const c0 = stops.items[0].c;
            return solidSrc(.{ .r = c0[0], .g = c0[1], .b = c0[2], .a = c0[3] }, opacity);
        }
        const sp = r.chainAttr(n, "spreadMethod") orelse "pad";
        return .{ .grad = .{
            .radial = radial,
            .p = p,
            .stops = stops.items,
            .spread = if (std.mem.eql(u8, sp, "reflect")) 1 else if (std.mem.eql(u8, sp, "repeat")) 2 else 0,
            .inv = inv,
            .opacity = opacity,
        } };
    }

    fn patternSrc(r: *Renderer, n: *Node, st: *const State, bbox: ?BBox, opacity: f32) Error!?Src {
        if (st.depth >= 4) return null;
        const c = lcOf(st);
        const bbu = !std.mem.eql(u8, r.chainAttr(n, "patternUnits") orelse "", "userSpaceOnUse");
        const cbb = std.mem.eql(u8, r.chainAttr(n, "patternContentUnits") orelse "", "objectBoundingBox");
        var px = unitLen(r.chainAttr(n, "x"), .x, bbu, c, 0);
        var py = unitLen(r.chainAttr(n, "y"), .y, bbu, c, 0);
        var pw = unitLen(r.chainAttr(n, "width"), .x, bbu, c, 0);
        var ph = unitLen(r.chainAttr(n, "height"), .y, bbu, c, 0);
        if (bbu or cbb) {
            const b = bbox orelse return null;
            if (!(b.w() > 0 and b.h() > 0)) return null;
            if (bbu) {
                px = b.x0 + px * b.w();
                py = b.y0 + py * b.h();
                pw *= b.w();
                ph *= b.h();
            }
        }
        if (!(pw > 0 and ph > 0)) return null;
        var pm = st.ctm;
        if (r.chainAttr(n, "patternTransform")) |t| {
            if (sty.parseTransform(t)) |m| pm = pm.mul(m);
        }
        const sx = @max(std.math.hypot(pm.a, pm.b), 1e-6);
        const sy = @max(std.math.hypot(pm.c, pm.d), 1e-6);
        const tw: usize = @intFromFloat(std.math.clamp(@ceil(pw * sx), 1, 2048));
        const th: usize = @intFromFloat(std.math.clamp(@ceil(ph * sy), 1, 2048));
        var content = Mat.scale(@as(f64, @floatFromInt(tw)) / pw, @as(f64, @floatFromInt(th)) / ph);
        if (parseViewBox(r.chainAttr(n, "viewBox"))) |vb| {
            content = content.mul(viewBoxMat(vb, parsePar(r.chainAttr(n, "preserveAspectRatio")), pw, ph));
        } else if (cbb) {
            const b = bbox.?;
            content = content.mul(Mat.scale(b.w(), b.h()));
        }
        const owner = r.chainChildren(n, "") orelse return null;
        var tile = try Layer.init(r.gpa, tw, th);
        defer tile.deinit(r.gpa);
        const saved_w = r.w;
        const saved_h = r.h;
        r.w = tw;
        r.h = th;
        defer {
            r.w = saved_w;
            r.h = saved_h;
        }
        const ps = try r.styleOfNode(owner);
        var ts: State = .{ .ctm = content, .style = ps, .vw = pw, .vh = ph, .target = &tile, .depth = st.depth + 1 };
        const saved_clip = r.clip_mode;
        r.clip_mode = false;
        defer r.clip_mode = saved_clip;
        try r.drawChildren(owner, &ts);
        const pixels = try r.arena.alloc(u8, tile.px.len);
        @memcpy(pixels, tile.px);
        const to_tile = Mat.scale(@as(f64, @floatFromInt(tw)) / pw, @as(f64, @floatFromInt(th)) / ph).mul(Mat.translate(-px, -py));
        const inv = (pm.inverse() orelse return null);
        return .{ .tex = .{ .px = pixels, .w = tw, .h = th, .inv = to_tile.mul(inv), .repeat = true, .opacity = opacity } };
    }

    fn clipPlane(r: *Renderer, cn: *Node, st: *const State, target: *Node) Error![]u8 {
        try r.charge(@as(u64, r.w) * r.h * 3);
        var layer = try Layer.init(r.gpa, r.w, r.h);
        defer layer.deinit(r.gpa);
        const plane = try r.gpa.alloc(u8, r.w * r.h);
        errdefer r.gpa.free(plane);
        @memset(plane, 0);
        if (st.depth >= max_use_depth or r.layer_depth >= max_layer_depth) return plane;
        r.layer_depth += 1;
        defer r.layer_depth -= 1;
        var cs: State = st.*;
        cs.target = &layer;
        cs.clip = null;
        cs.is_root = false;
        cs.via_use = false;
        cs.depth += 1;
        cs.style = try r.styleOfNode(cn);
        if (std.mem.eql(u8, cn.attr("clipPathUnits") orelse "", "objectBoundingBox")) {
            const bb = (try r.bboxOfNode(target, st, Mat.identity, false)) orelse return plane;
            cs.ctm = cs.ctm.mul(.{ .a = bb.w(), .d = bb.h(), .e = bb.x0, .f = bb.y0 });
        }
        if (cn.attr("transform")) |t| {
            if (sty.parseTransform(t)) |m| cs.ctm = cs.ctm.mul(m);
        }
        const saved = r.clip_mode;
        r.clip_mode = true;
        defer r.clip_mode = saved;
        for (cn.children.items) |ch| {
            if (ch.is_text) continue;
            const t = ch.tag;
            if (isShape(t) or std.mem.eql(u8, t, "text") or std.mem.eql(u8, t, "use")) try r.drawNode(ch, &cs);
        }
        var i: usize = 0;
        while (i < plane.len) : (i += 1) plane[i] = layer.px[i * 4 + 3];
        const own = r.findTag(cs.style.clip_path, "clipPath");
        if (own) |on| {
            if (on != cn) {
                const p2 = try r.clipPlane(on, st, target);
                defer r.gpa.free(p2);
                mulPlane(plane, p2);
            }
        }
        return plane;
    }

    fn maskPlane(r: *Renderer, mn: *Node, st: *const State, target: *Node) Error![]u8 {
        try r.charge(@as(u64, r.w) * r.h * 6);
        const plane = try r.gpa.alloc(u8, r.w * r.h);
        errdefer r.gpa.free(plane);
        @memset(plane, 0);
        if (st.depth >= max_use_depth) return plane;
        const c = lcOf(st);
        const bbu = !std.mem.eql(u8, mn.attr("maskUnits") orelse "", "userSpaceOnUse");
        const cbb = std.mem.eql(u8, mn.attr("maskContentUnits") orelse "", "objectBoundingBox");
        var bb: ?BBox = null;
        if (bbu or cbb) {
            bb = (try r.bboxOfNode(target, st, Mat.identity, false)) orelse return plane;
            if (!(bb.?.w() > 0 and bb.?.h() > 0)) return plane;
        }
        var x = unitLen(mn.attr("x"), .x, bbu, c, if (bbu) -0.1 else -0.1 * c.vw);
        var y = unitLen(mn.attr("y"), .y, bbu, c, if (bbu) -0.1 else -0.1 * c.vh);
        var w = unitLen(mn.attr("width"), .x, bbu, c, if (bbu) 1.2 else 1.2 * c.vw);
        var h = unitLen(mn.attr("height"), .y, bbu, c, if (bbu) 1.2 else 1.2 * c.vh);
        if (bbu) {
            const b = bb.?;
            x = b.x0 + x * b.w();
            y = b.y0 + y * b.h();
            w *= b.w();
            h *= b.h();
        }
        if (!(w > 0 and h > 0)) return plane;
        var layer = try Layer.init(r.gpa, r.w, r.h);
        defer layer.deinit(r.gpa);
        var ms: State = st.*;
        ms.target = &layer;
        ms.clip = null;
        ms.is_root = false;
        ms.via_use = false;
        ms.depth += 1;
        ms.style = try r.styleOfNode(mn);
        if (cbb) {
            const b = bb.?;
            ms.ctm = ms.ctm.mul(.{ .a = b.w(), .d = b.h(), .e = b.x0, .f = b.y0 });
        }
        const saved = r.clip_mode;
        r.clip_mode = false;
        defer r.clip_mode = saved;
        if (r.layer_depth >= max_layer_depth) return plane;
        r.layer_depth += 1;
        defer r.layer_depth -= 1;
        try r.drawChildren(mn, &ms);
        const alpha_mask = std.mem.eql(u8, mn.attr("mask-type") orelse "", "alpha") or (if (mn.attr("style")) |sa| std.mem.indexOf(u8, sa, "alpha") != null and std.mem.indexOf(u8, sa, "mask-type") != null else false);
        const lin = std.mem.eql(u8, mn.attr("color-interpolation") orelse "", "linearRGB");
        var i: usize = 0;
        while (i < plane.len) : (i += 1) {
            const o = i * 4;
            var rr: f32 = @floatFromInt(layer.px[o]);
            var gg: f32 = @floatFromInt(layer.px[o + 1]);
            var bb2: f32 = @floatFromInt(layer.px[o + 2]);
            if (lin and layer.px[o + 3] > 0) {
                const a: f32 = @floatFromInt(layer.px[o + 3]);
                rr = lum(rr / a) * a;
                gg = lum(gg / a) * a;
                bb2 = lum(bb2 / a) * a;
            }
            plane[i] = if (alpha_mask) layer.px[o + 3] else @intFromFloat(std.math.clamp(0.2125 * rr + 0.7154 * gg + 0.0721 * bb2 + 0.5, 0, 255));
        }
        const region = try r.rectPlane(st.ctm, x, y, w, h);
        defer r.gpa.free(region);
        mulPlane(plane, region);
        return plane;
    }

    fn lum(c: f32) f32 {
        return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }

    pub fn bboxOfNode(r: *Renderer, node: *Node, st: *const State, m: Mat, apply_transform: bool) Error!?BBox {
        _ = apply_transform;
        return r.bboxContent(node, &st.style, st.vw, st.vh, m, 0);
    }

    fn bboxChild(r: *Renderer, ch: *Node, ps: *const Style, vw: f64, vh: f64, m: Mat, depth: u32) Error!?BBox {
        if (ch.is_text) return null;
        const t = ch.tag;
        if (!(isShape(t) or r.isContainer(t) or std.mem.eql(u8, t, "use") or std.mem.eql(u8, t, "text") or std.mem.eql(u8, t, "image") or std.mem.eql(u8, t, "svg"))) return null;
        const s = try r.computeStyle(ch, ps, .{ .font_size = ps.font_size, .vw = vw, .vh = vh });
        if (!s.display) return null;
        var m2 = m;
        if (s.transform orelse ch.attr("transform")) |ta| {
            if (sty.parseTransform(ta)) |tm| m2 = m.mul(tm);
        }
        return r.bboxContent(ch, &s, vw, vh, m2, depth);
    }

    pub fn bboxContent(r: *Renderer, node: *Node, s: *const Style, vw: f64, vh: f64, m: Mat, depth: u32) Error!?BBox {
        if (depth > 20) return null;
        r.ops += 1;
        if (r.ops > max_ops) return error.TooLarge;
        const tag = node.tag;
        const c: sty.LenCtx = .{ .font_size = s.font_size, .vw = vw, .vh = vh };
        if (isShape(tag)) {
            var path: raster.Path = .{};
            defer path.segs.deinit(r.gpa);
            try r.shapePath(node, c, &path);
            return r.pathBBox(&path, m);
        }
        if (r.isContainer(tag) or std.mem.eql(u8, tag, "svg")) {
            var bb: ?BBox = null;
            for (node.children.items) |ch| bb = BBox.unite(bb, try r.bboxChild(ch, s, vw, vh, m, depth + 1));
            return bb;
        }
        if (std.mem.eql(u8, tag, "use")) {
            const ref = r.refNode(node.href()) orelse return null;
            const m2 = m.mul(Mat.translate(lenA(node, "x", .x, c, 0), lenA(node, "y", .y, c, 0)));
            return r.bboxChild(ref, s, vw, vh, m2, depth + 1);
        }
        if (std.mem.eql(u8, tag, "image")) {
            const w = lenA(node, "width", .x, c, 0);
            const h = lenA(node, "height", .y, c, 0);
            const x = lenA(node, "x", .x, c, 0);
            const y = lenA(node, "y", .y, c, 0);
            if (!(w > 0 and h > 0)) return null;
            var bb: ?BBox = null;
            for ([_]Pt{ .{ .x = x, .y = y }, .{ .x = x + w, .y = y + h } }) |p| {
                const q = m.apply(p);
                bb = BBox.unite(bb, .{ .x0 = q.x, .y0 = q.y, .x1 = q.x, .y1 = q.y });
            }
            return bb;
        }
        if (std.mem.eql(u8, tag, "text")) {
            var ta = std.heap.ArenaAllocator.init(r.gpa);
            defer ta.deinit();
            const runs = try text.layout(r, ta.allocator(), node, s, c, null);
            var bb: ?BBox = null;
            for (runs) |run| {
                if (try r.pathBBox(&run.path, m)) |b| bb = BBox.unite(bb, b);
            }
            return bb;
        }
        return null;
    }

    fn drawText(r: *Renderer, node: *Node, st: *State) Error!void {
        var ta = std.heap.ArenaAllocator.init(r.gpa);
        defer ta.deinit();
        const runs = try text.layout(r, ta.allocator(), node, &st.style, lcOf(st), st.ctm);
        var bb: ?BBox = null;
        for (runs) |run| {
            if (try r.pathBBox(&run.path, Mat.identity)) |b| bb = BBox.unite(bb, b);
        }
        try r.paintRuns(st, runs, bb);
    }

    fn drawForeign(r: *Renderer, node: *Node, st: *State) Error!void {
        if (r.clip_mode) return;
        const c = lcOf(st);
        const x = lenA(node, "x", .x, c, 0);
        const y = lenA(node, "y", .y, c, 0);
        const w = lenA(node, "width", .x, c, 0);
        const h = lenA(node, "height", .y, c, 0);
        if (!(w > 0 and h > 0)) return;
        var s2 = st.*;
        s2.ctm = st.ctm.mul(Mat.translate(x, y));
        var plane: ?[]u8 = null;
        defer if (plane) |p| r.gpa.free(p);
        plane = try r.rectPlane(st.ctm, x, y, w, h);
        if (st.clip) |pc| mulPlane(plane.?, pc);
        s2.clip = plane;
        var ta = std.heap.ArenaAllocator.init(r.gpa);
        defer ta.deinit();
        const runs = try text.layoutHtml(r, ta.allocator(), node, &st.style, c, w);
        try r.paintRuns(&s2, runs, null);
    }

    fn paintRuns(r: *Renderer, st: *State, runs: []const text.Run, bb: ?BBox) Error!void {
        for (runs) |*run| {
            if (run.path.segs.items.len == 0 and run.layers.len == 0 and run.bitmaps.len == 0) continue;
            var rs = st.*;
            rs.style = run.style;
            rs.style.crisp = false;
            if (!rs.style.visible) continue;
            rs.text_boost = textBoost(&rs.style);
            try r.paintShape(&rs, &run.path, bb);
            for (run.layers) |*ly| {
                if (r.clip_mode) break;
                const col: sty.Color = .{ .r = @as(f32, @floatFromInt(ly.color[0])) / 255, .g = @as(f32, @floatFromInt(ly.color[1])) / 255, .b = @as(f32, @floatFromInt(ly.color[2])) / 255, .a = @as(f32, @floatFromInt(ly.color[3])) / 255 };
                try r.fillPath(&rs, &ly.path, .nonzero, solidSrc(col, rs.style.fill_opacity));
            }
            if (!r.clip_mode) for (run.bitmaps) |*bm| {
                const full = rs.ctm.mul(bm.m);
                const inv = full.inverse() orelse continue;
                const wf: f64 = @floatFromInt(bm.w);
                const hf: f64 = @floatFromInt(bm.h);
                r.pa.clear();
                try r.pa.pts.appendSlice(r.gpa, &.{ full.apply(.{ .x = 0, .y = 0 }), full.apply(.{ .x = wf, .y = 0 }), full.apply(.{ .x = wf, .y = hf }), full.apply(.{ .x = 0, .y = hf }) });
                try r.pa.subs.append(r.gpa, .{ .start = 0, .len = 4, .closed = true });
                try r.fillSrc(&rs, &r.pa, .nonzero, .{ .tex = .{ .px = bm.rgba, .w = bm.w, .h = bm.h, .inv = inv, .repeat = false, .opacity = rs.style.fill_opacity } });
            };
        }
    }

    pub fn drawImage(r: *Renderer, node: *Node, st: *State) Error!void {
        if (!st.style.visible or r.clip_mode) return;
        const href = node.href() orelse return;
        const bytes = (try decodeDataUri(r.gpa, href)) orelse return;
        defer r.gpa.free(bytes);
        const c = lcOf(st);
        var x = lenA(node, "x", .x, c, 0);
        var y = lenA(node, "y", .y, c, 0);
        var w = lenA(node, "width", .x, c, 0);
        var h = lenA(node, "height", .y, c, 0);
        var iw: usize = 0;
        var ih: usize = 0;
        var owned_img: ?image.Image = null;
        defer if (owned_img) |*im| im.deinit(r.gpa);
        const par = parsePar(node.attr("preserveAspectRatio"));
        if (xml.isSvg(bytes)) {
            const sz = (@import("svg.zig").intrinsicSize(bytes)) catch return;
            const nw: f64 = sz.w;
            const nh: f64 = sz.h;
            if (!(w > 0)) w = if (h > 0) h * nw / nh else nw;
            if (!(h > 0)) h = w * nh / nw;
            const k = st.ctm.meanScale() * @min(w / nw, h / nh);
            iw = @intFromFloat(std.math.clamp(@ceil(nw * k), 1, 4096));
            ih = @intFromFloat(std.math.clamp(@ceil(nh * k), 1, 4096));
            const f = r.renderNested orelse return;
            if (r.nest >= 2) return;
            owned_img = f(r.gpa, bytes, @intCast(iw), @intCast(ih), r.nest + 1, r.time_ms) catch return;
        } else {
            owned_img = image.decode(r.gpa, bytes) catch return;
            iw = owned_img.?.width;
            ih = owned_img.?.height;
            const nw: f64 = @floatFromInt(iw);
            const nh: f64 = @floatFromInt(ih);
            if (!(w > 0)) w = if (h > 0) h * nw / nh else nw;
            if (!(h > 0)) h = w * nh / nw;
        }
        if (!(w > 0 and h > 0) or iw == 0 or ih == 0 or owned_img.?.frames.len == 0) return;
        const pix = owned_img.?.frames[0].rgba;
        const premul = try r.gpa.alloc(u8, pix.len);
        defer r.gpa.free(premul);
        var i: usize = 0;
        while (i < pix.len) : (i += 4) {
            const a = pix[i + 3];
            for (0..3) |k| premul[i + k] = @intCast((@as(u32, pix[i + k]) * a + 127) / 255);
            premul[i + 3] = a;
        }
        const vbm = viewBoxMat(.{ .x = 0, .y = 0, .w = @floatFromInt(iw), .h = @floatFromInt(ih) }, par, w, h);
        const full = st.ctm.mul(Mat.translate(x, y)).mul(vbm);
        const inv = full.inverse() orelse return;
        x += 0;
        y += 0;
        const p0 = vbm.apply(.{ .x = 0, .y = 0 });
        const p1 = vbm.apply(.{ .x = @floatFromInt(iw), .y = @floatFromInt(ih) });
        const rx0 = @max(0, @min(p0.x, p1.x));
        const ry0 = @max(0, @min(p0.y, p1.y));
        const rx1 = @min(w, @max(p0.x, p1.x));
        const ry1 = @min(h, @max(p0.y, p1.y));
        if (!(rx1 > rx0 and ry1 > ry0)) return;
        const m = st.ctm.mul(Mat.translate(x, y));
        r.pa.clear();
        try r.pa.pts.appendSlice(r.gpa, &.{ m.apply(.{ .x = rx0, .y = ry0 }), m.apply(.{ .x = rx1, .y = ry0 }), m.apply(.{ .x = rx1, .y = ry1 }), m.apply(.{ .x = rx0, .y = ry1 }) });
        try r.pa.subs.append(r.gpa, .{ .start = 0, .len = 4, .closed = true });
        try r.fillSrc(st, &r.pa, .nonzero, .{ .tex = .{ .px = premul, .w = iw, .h = ih, .inv = inv, .repeat = false, .opacity = 1 } });
    }

    pub fn applyFilter(r: *Renderer, fnode: *Node, layer: *Layer, st: *const State, target: *Node) Error!void {
        const filter = @import("svg_filter_apply.zig");
        try filter.apply(r, fnode, layer, st, target);
    }

    pub fn lookupPublic(r: *Renderer, id: []const u8) ?*Node {
        return r.lookup(id);
    }
};

pub fn decodeDataUri(alloc: std.mem.Allocator, href: []const u8) Error!?[]u8 {
    const h = std.mem.trim(u8, href, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(h, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, h, ',') orelse return null;
    const meta = h[5..comma];
    const data = h[comma + 1 ..];
    if (data.len > 48 * 1024 * 1024) return error.TooLarge;
    if (std.ascii.findIgnoreCase(meta, ";base64") != null) {
        const dec = std.base64.standard.decoderWithIgnore(" \r\n\t");
        const out = try alloc.alloc(u8, data.len);
        errdefer alloc.free(out);
        const n = dec.decode(out, data) catch return null;
        return try alloc.realloc(out, n);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '%' and i + 2 < data.len + 0 and i + 2 <= data.len - 1) {
            if (std.fmt.parseInt(u8, data[i + 1 .. i + 3], 16)) |b| {
                try out.append(alloc, b);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(alloc, data[i]);
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}
