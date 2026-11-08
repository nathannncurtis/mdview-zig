const std = @import("std");
const draw = @import("svg_draw.zig");
const xml = @import("svg_xml.zig");
const raster = @import("svg_raster.zig");
const sty = @import("svg_style.zig");
const filt = @import("svg_filter.zig");

const Error = @import("image.zig").Error;
const Node = xml.Node;

const Rect = struct { x0: isize, y0: isize, x1: isize, y1: isize };

const Result = struct { name: ?[]const u8, img: filt.Img, rect: ?Rect = null };

fn srgbToLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

const Ctx = struct {
    r: *draw.Renderer,
    st: *const draw.State,
    layer: *draw.Layer,
    rx: usize,
    ry: usize,
    rw: usize,
    rh: usize,
    sx: f64,
    sy: f64,
    bb: ?draw.BBox,
    pu_bbox: bool,
    results: std.ArrayList(Result) = .empty,
    source: filt.Img,
    ux: f64 = 0,
    uy: f64 = 0,
    uw: f64 = 0,
    uh: f64 = 0,

    fn feImage(c: *Ctx, ch: *Node) Error!?filt.Img {
        const r = c.r;
        const gpa = r.gpa;
        const href = ch.href() orelse return null;
        var layer = try draw.Layer.init(gpa, c.rw, c.rh);
        defer layer.deinit(gpa);
        const saved_w = r.w;
        const saved_h = r.h;
        r.w = c.rw;
        r.h = c.rh;
        defer {
            r.w = saved_w;
            r.h = saved_h;
        }
        const lcx: sty.LenCtx = .{ .font_size = c.st.style.font_size, .vw = c.st.vw, .vh = c.st.vh };
        const x = sty.lenOr(ch.attr("x"), .x, lcx, c.ux);
        const y = sty.lenOr(ch.attr("y"), .y, lcx, c.uy);
        const w = sty.lenOr(ch.attr("width"), .x, lcx, c.uw);
        const h = sty.lenOr(ch.attr("height"), .y, lcx, c.uh);
        const base = raster.Mat.translate(-@as(f64, @floatFromInt(c.rx)), -@as(f64, @floatFromInt(c.ry))).mul(c.st.ctm);
        var s2: draw.State = .{ .ctm = base, .style = .{}, .vw = c.st.vw, .vh = c.st.vh, .target = &layer, .depth = c.st.depth + 1 };
        if (href.len > 1 and href[0] == '#') {
            const ref = r.lookupPublic(href[1..]) orelse return null;
            if (ch.attr("x") != null or ch.attr("y") != null) s2.ctm = base.mul(raster.Mat.translate(x, y));
            try r.drawNode(ref, &s2);
        } else {
            const n = try r.arena.create(Node);
            n.* = .{ .tag = "image" };
            try n.attrs.append(r.arena, .{ .name = "href", .value = href });
            try n.attrs.append(r.arena, .{ .name = "x", .value = try std.fmt.allocPrint(r.arena, "{d}", .{x}) });
            try n.attrs.append(r.arena, .{ .name = "y", .value = try std.fmt.allocPrint(r.arena, "{d}", .{y}) });
            try n.attrs.append(r.arena, .{ .name = "width", .value = try std.fmt.allocPrint(r.arena, "{d}", .{w}) });
            try n.attrs.append(r.arena, .{ .name = "height", .value = try std.fmt.allocPrint(r.arena, "{d}", .{h}) });
            if (ch.attr("preserveAspectRatio")) |p| try n.attrs.append(r.arena, .{ .name = "preserveAspectRatio", .value = p });
            try r.drawImage(n, &s2);
        }
        return try layerToImg(gpa, &layer);
    }

    fn inputRect(c: *Ctx, name_opt: ?[]const u8) ?Rect {
        if (name_opt) |nm| {
            var k = c.results.items.len;
            while (k > 0) {
                k -= 1;
                if (c.results.items[k].name) |rn| if (std.mem.eql(u8, rn, nm)) return c.results.items[k].rect;
            }
            return null;
        }
        if (c.results.items.len > 0) return c.results.items[c.results.items.len - 1].rect;
        return null;
    }

    fn input(c: *Ctx, name_opt: ?[]const u8) Error!filt.Img {
        const gpa = c.r.gpa;
        if (name_opt) |nm| {
            if (std.mem.eql(u8, nm, "SourceGraphic")) return c.source.clone(gpa);
            if (std.mem.eql(u8, nm, "SourceAlpha")) {
                var o = try c.source.clone(gpa);
                var i: usize = 0;
                while (i < o.px.len) : (i += 4) {
                    o.px[i] = 0;
                    o.px[i + 1] = 0;
                    o.px[i + 2] = 0;
                }
                return o;
            }
            var k = c.results.items.len;
            while (k > 0) {
                k -= 1;
                if (c.results.items[k].name) |rn| if (std.mem.eql(u8, rn, nm)) return c.results.items[k].img.clone(gpa);
            }
            if (std.mem.eql(u8, nm, "BackgroundImage") or std.mem.eql(u8, nm, "BackgroundAlpha") or std.mem.eql(u8, nm, "FillPaint") or std.mem.eql(u8, nm, "StrokePaint")) return filt.Img.init(gpa, c.rw, c.rh);
        }
        if (c.results.items.len > 0) return c.results.items[c.results.items.len - 1].img.clone(gpa);
        return c.source.clone(gpa);
    }

    fn pair(c: *Ctx, s: ?[]const u8, def: f64) [2]f64 {
        var v = [2]f64{ def, def };
        var sc: raster.NumScan = .{ .s = s orelse return v };
        if (sc.number()) |a| {
            v[0] = a;
            v[1] = a;
            if (sc.number()) |b| v[1] = b;
        }
        _ = c;
        return v;
    }

    fn px(c: *Ctx, v: f64, horizontal: bool) f64 {
        var u = v;
        if (c.pu_bbox) if (c.bb) |b| {
            u *= if (horizontal) b.w() else b.h();
        };
        return u * (if (horizontal) c.sx else c.sy);
    }

    fn clearOutside(c: *Ctx, img: *filt.Img, node: *Node, s: *const sty.Style) ?Rect {
        if (node.attr("x") == null and node.attr("y") == null and node.attr("width") == null and node.attr("height") == null) return null;
        const lc: sty.LenCtx = .{ .font_size = s.font_size, .vw = c.st.vw, .vh = c.st.vh };
        var x: f64 = -1e9;
        var y: f64 = -1e9;
        var w: f64 = 2e9;
        var h: f64 = 2e9;
        const f = struct {
            fn get(n: *Node, name: []const u8, axis: sty.Axis, cc: *Ctx, l: sty.LenCtx, def: f64) f64 {
                const len = sty.parseLen(n.attr(name) orelse return def) orelse return def;
                if (cc.pu_bbox) {
                    const b = cc.bb orelse return def;
                    const fr = if (len.unit == .pct) len.v / 100 else len.v;
                    return switch (axis) {
                        .x => if (name[0] == 'x') b.x0 + fr * b.w() else fr * b.w(),
                        else => if (name[0] == 'y') b.y0 + fr * b.h() else fr * b.h(),
                    };
                }
                return sty.resolveLen(len, axis, l);
            }
        }.get;
        x = f(node, "x", .x, c, lc, x);
        y = f(node, "y", .y, c, lc, y);
        w = f(node, "width", .x, c, lc, w);
        h = f(node, "height", .y, c, lc, h);
        var x0: f64 = std.math.inf(f64);
        var y0: f64 = std.math.inf(f64);
        var x1: f64 = -std.math.inf(f64);
        var y1: f64 = -std.math.inf(f64);
        for ([_]raster.Pt{ .{ .x = x, .y = y }, .{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h }, .{ .x = x, .y = y + h } }) |p| {
            const q = c.st.ctm.apply(p);
            x0 = @min(x0, q.x);
            y0 = @min(y0, q.y);
            x1 = @max(x1, q.x);
            y1 = @max(y1, q.y);
        }
        const ox: f64 = @floatFromInt(c.rx);
        const oy: f64 = @floatFromInt(c.ry);
        for (0..img.h) |row| {
            for (0..img.w) |col| {
                const cx = ox + @as(f64, @floatFromInt(col)) + 0.5;
                const cy = oy + @as(f64, @floatFromInt(row)) + 0.5;
                if (cx < x0 or cx >= x1 or cy < y0 or cy >= y1) {
                    const o = (row * img.w + col) * 4;
                    @memset(img.px[o..][0..4], 0);
                }
            }
        }
        return .{
            .x0 = @intFromFloat(std.math.clamp(@floor(x0) - ox, -1e7, 1e7)),
            .y0 = @intFromFloat(std.math.clamp(@floor(y0) - oy, -1e7, 1e7)),
            .x1 = @intFromFloat(std.math.clamp(@ceil(x1) - ox, -1e7, 1e7)),
            .y1 = @intFromFloat(std.math.clamp(@ceil(y1) - oy, -1e7, 1e7)),
        };
    }
};

fn numAttr(n: *const Node, name: []const u8, def: f32) f32 {
    const s = n.attr(name) orelse return def;
    var sc: raster.NumScan = .{ .s = s };
    return if (sc.number()) |v| @floatCast(v) else def;
}

fn floodColor(s: *const sty.Style, lin: bool) [4]f32 {
    var c = [4]f32{ s.flood_color.r, s.flood_color.g, s.flood_color.b, s.flood_color.a * s.flood_opacity };
    if (lin) for (0..3) |i| {
        c[i] = srgbToLinear(c[i]);
    };
    return c;
}

fn transferOf(r: *draw.Renderer, f: *const Node) Error!filt.Transfer {
    var t: filt.Transfer = .{};
    const ty = f.attr("type") orelse return t;
    if (std.mem.eql(u8, ty, "table") or std.mem.eql(u8, ty, "discrete")) {
        t.kind = if (ty[0] == 't') .table else .discrete;
        var list: std.ArrayList(f32) = .empty;
        var sc: raster.NumScan = .{ .s = f.attr("tableValues") orelse "" };
        while (sc.number()) |v| try list.append(r.arena, @floatCast(v));
        t.table = list.items;
    } else if (std.mem.eql(u8, ty, "linear")) {
        t.kind = .linear;
        t.slope = numAttr(f, "slope", 1);
        t.intercept = numAttr(f, "intercept", 0);
    } else if (std.mem.eql(u8, ty, "gamma")) {
        t.kind = .gamma;
        t.amplitude = numAttr(f, "amplitude", 1);
        t.exponent = numAttr(f, "exponent", 1);
        t.off = numAttr(f, "offset", 0);
    }
    return t;
}

pub const Region = struct { fx: f64, fy: f64, fw: f64, fh: f64, x0: f64, y0: f64, x1: f64, y1: f64, bb: ?draw.BBox };

pub fn region(r: *draw.Renderer, fnode: *Node, st: *const draw.State, target: *Node) Error!?Region {
    const fu_bbox = !std.mem.eql(u8, fnode.attr("filterUnits") orelse "", "userSpaceOnUse");
    const pu_bbox = std.mem.eql(u8, fnode.attr("primitiveUnits") orelse "", "objectBoundingBox");
    var bb: ?draw.BBox = null;
    if (fu_bbox or pu_bbox) {
        bb = try r.bboxOfNode(target, st, raster.Mat.identity, false);
        if (bb == null or !(bb.?.w() > 0 and bb.?.h() > 0)) return null;
    }
    const lcx: sty.LenCtx = .{ .font_size = st.style.font_size, .vw = st.vw, .vh = st.vh };
    const fnum = struct {
        fn get(n: *Node, name: []const u8, axis: sty.Axis, bbu: bool, c: sty.LenCtx, def: f64) f64 {
            const l = sty.parseLen(n.attr(name) orelse return def) orelse return def;
            if (bbu) return if (l.unit == .pct) l.v / 100 else l.v;
            return sty.resolveLen(l, axis, c);
        }
    }.get;
    var fx = fnum(fnode, "x", .x, fu_bbox, lcx, if (fu_bbox) -0.1 else -0.1 * lcx.vw);
    var fy = fnum(fnode, "y", .y, fu_bbox, lcx, if (fu_bbox) -0.1 else -0.1 * lcx.vh);
    var fw = fnum(fnode, "width", .x, fu_bbox, lcx, if (fu_bbox) 1.2 else 1.2 * lcx.vw);
    var fh = fnum(fnode, "height", .y, fu_bbox, lcx, if (fu_bbox) 1.2 else 1.2 * lcx.vh);
    if (fu_bbox) {
        const b = bb.?;
        fx = b.x0 + fx * b.w();
        fy = b.y0 + fy * b.h();
        fw *= b.w();
        fh *= b.h();
    }
    if (!(fw > 0 and fh > 0)) return null;
    var x0: f64 = std.math.inf(f64);
    var y0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    var y1: f64 = -std.math.inf(f64);
    for ([_]raster.Pt{ .{ .x = fx, .y = fy }, .{ .x = fx + fw, .y = fy }, .{ .x = fx + fw, .y = fy + fh }, .{ .x = fx, .y = fy + fh } }) |p| {
        const q = st.ctm.apply(p);
        x0 = @min(x0, q.x);
        y0 = @min(y0, q.y);
        x1 = @max(x1, q.x);
        y1 = @max(y1, q.y);
    }
    return .{ .fx = fx, .fy = fy, .fw = fw, .fh = fh, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .bb = bb };
}

pub fn apply(r: *draw.Renderer, fnode: *Node, layer: *draw.Layer, st: *const draw.State, target: *Node) Error!void {
    const gpa = r.gpa;
    const pu_bbox = std.mem.eql(u8, fnode.attr("primitiveUnits") orelse "", "objectBoundingBox");
    const reg = (try region(r, fnode, st, target)) orelse {
        @memset(layer.px, 0);
        return;
    };
    const bb = reg.bb;
    const fx = reg.fx;
    const fy = reg.fy;
    const fw = reg.fw;
    const fh = reg.fh;
    const lcx: sty.LenCtx = .{ .font_size = st.style.font_size, .vw = st.vw, .vh = st.vh };
    const lw: f64 = @floatFromInt(layer.w);
    const lh: f64 = @floatFromInt(layer.h);
    const ix0 = @max(@floor(reg.x0), 0);
    const iy0 = @max(@floor(reg.y0), 0);
    const ix1 = @min(@ceil(reg.x1), lw);
    const iy1 = @min(@ceil(reg.y1), lh);
    if (!(ix0 < ix1 and iy0 < iy1)) {
        @memset(layer.px, 0);
        return;
    }
    const rx: usize = @intFromFloat(ix0);
    const ry: usize = @intFromFloat(iy0);
    const rw: usize = @as(usize, @intFromFloat(ix1)) - rx;
    const rh: usize = @as(usize, @intFromFloat(iy1)) - ry;
    try r.charge(@as(u64, rw) * rh * 40);

    var source = try filt.Img.init(gpa, rw, rh);
    for (0..rh) |row| {
        for (0..rw) |col| {
            const o = ((ry + row) * layer.w + rx + col) * 4;
            const d = (row * rw + col) * 4;
            for (0..4) |k| source.px[d + k] = @as(f32, @floatFromInt(layer.px[o + k])) / 255;
        }
    }
    var c: Ctx = .{
        .ux = fx,
        .uy = fy,
        .uw = fw,
        .uh = fh,
        .r = r,
        .st = st,
        .layer = layer,
        .rx = rx,
        .ry = ry,
        .rw = rw,
        .rh = rh,
        .sx = std.math.hypot(st.ctm.a, st.ctm.b),
        .sy = std.math.hypot(st.ctm.c, st.ctm.d),
        .bb = bb,
        .pu_bbox = pu_bbox,
        .source = source,
    };
    defer {
        for (c.results.items) |res| res.img.deinit(gpa);
        c.results.deinit(gpa);
        c.source.deinit(gpa);
    }
    const fstyle = try r.styleOfNode(fnode);
    var count: usize = 0;
    for (fnode.children.items) |ch| {
        if (ch.is_text or !std.mem.startsWith(u8, ch.tag, "fe")) continue;
        count += 1;
        if (count > 40) break;
        const s = try r.computeStyle(ch, &fstyle, lcx);
        const lin = s.linear_filters;
        const tag = ch.tag;
        // SAFETY: every branch below assigns out before it is used
        var out: filt.Img = undefined;
        if (std.mem.eql(u8, tag, "feGaussianBlur")) {
            out = try c.input(ch.attr("in"));
            filt.setSpace(&out, lin);
            const sd = c.pair(ch.attr("stdDeviation"), 0);
            try filt.blur(gpa, &out, @floatCast(c.px(sd[0], true)), @floatCast(c.px(sd[1], false)));
        } else if (std.mem.eql(u8, tag, "feOffset")) {
            var in = try c.input(ch.attr("in"));
            defer in.deinit(gpa);
            filt.setSpace(&in, lin);
            const dx = c.px(numAttr(ch, "dx", 0), true);
            const dy = c.px(numAttr(ch, "dy", 0), false);
            out = try filt.offset(gpa, in, @intFromFloat(std.math.clamp(@round(dx), -1e6, 1e6)), @intFromFloat(std.math.clamp(@round(dy), -1e6, 1e6)));
        } else if (std.mem.eql(u8, tag, "feFlood")) {
            out = try filt.Img.init(gpa, rw, rh);
            filt.flood(&out, floodColor(&s, lin));
        } else if (std.mem.eql(u8, tag, "feBlend") or std.mem.eql(u8, tag, "feComposite")) {
            var a = try c.input(ch.attr("in"));
            defer a.deinit(gpa);
            var b = try c.input(ch.attr("in2"));
            defer b.deinit(gpa);
            filt.setSpace(&a, lin);
            filt.setSpace(&b, lin);
            out = try filt.Img.init(gpa, rw, rh);
            if (tag[2] == 'B') {
                const m = ch.attr("mode") orelse "normal";
                const mode: filt.BlendMode = if (std.mem.eql(u8, m, "multiply")) .multiply else if (std.mem.eql(u8, m, "screen")) .screen else if (std.mem.eql(u8, m, "darken")) .darken else if (std.mem.eql(u8, m, "lighten")) .lighten else .normal;
                filt.blend(&out, a, b, mode);
            } else {
                const o = ch.attr("operator") orelse "over";
                const op: filt.CompOp = if (std.mem.eql(u8, o, "in")) .in else if (std.mem.eql(u8, o, "out")) .out else if (std.mem.eql(u8, o, "atop")) .atop else if (std.mem.eql(u8, o, "xor")) .xor else if (std.mem.eql(u8, o, "arithmetic")) .arithmetic else .over;
                filt.composite(&out, a, b, op, .{ numAttr(ch, "k1", 0), numAttr(ch, "k2", 0), numAttr(ch, "k3", 0), numAttr(ch, "k4", 0) });
            }
        } else if (std.mem.eql(u8, tag, "feMerge")) {
            out = try filt.Img.init(gpa, rw, rh);
            out.linear = lin;
            for (ch.children.items) |mn| {
                if (mn.is_text or !std.mem.eql(u8, mn.tag, "feMergeNode")) continue;
                var a = try c.input(mn.attr("in"));
                defer a.deinit(gpa);
                filt.setSpace(&a, lin);
                var tmp = try filt.Img.init(gpa, rw, rh);
                defer tmp.deinit(gpa);
                filt.composite(&tmp, a, out, .over, .{ 0, 0, 0, 0 });
                @memcpy(out.px, tmp.px);
            }
        } else if (std.mem.eql(u8, tag, "feColorMatrix")) {
            out = try c.input(ch.attr("in"));
            filt.setSpace(&out, lin);
            const ty = ch.attr("type") orelse "matrix";
            var m: [20]f32 = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
            if (std.mem.eql(u8, ty, "saturate")) {
                const sv = numAttr(ch, "values", 1);
                m = .{
                    0.213 + 0.787 * sv, 0.715 - 0.715 * sv, 0.072 - 0.072 * sv, 0, 0,
                    0.213 - 0.213 * sv, 0.715 + 0.285 * sv, 0.072 - 0.072 * sv, 0, 0,
                    0.213 - 0.213 * sv, 0.715 - 0.715 * sv, 0.072 + 0.928 * sv, 0, 0,
                    0,                  0,                  0,                  1, 0,
                };
            } else if (std.mem.eql(u8, ty, "hueRotate")) {
                const a = numAttr(ch, "values", 0) * std.math.pi / 180.0;
                const cs = @cos(a);
                const sn = @sin(a);
                m = .{
                    0.213 + cs * 0.787 - sn * 0.213, 0.715 - cs * 0.715 - sn * 0.715, 0.072 - cs * 0.072 + sn * 0.928, 0, 0,
                    0.213 - cs * 0.213 + sn * 0.143, 0.715 + cs * 0.285 + sn * 0.140, 0.072 - cs * 0.072 - sn * 0.283, 0, 0,
                    0.213 - cs * 0.213 - sn * 0.787, 0.715 - cs * 0.715 + sn * 0.715, 0.072 + cs * 0.928 + sn * 0.072, 0, 0,
                    0,                               0,                               0,                               1, 0,
                };
            } else if (std.mem.eql(u8, ty, "luminanceToAlpha")) {
                m = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0 };
            } else {
                var sc: raster.NumScan = .{ .s = ch.attr("values") orelse "" };
                var vals: [20]f32 = undefined;
                var n: usize = 0;
                while (n < 20) : (n += 1) vals[n] = @floatCast(sc.number() orelse break);
                if (n == 20) m = vals;
            }
            filt.colorMatrix(&out, m);
        } else if (std.mem.eql(u8, tag, "feComponentTransfer")) {
            out = try c.input(ch.attr("in"));
            filt.setSpace(&out, lin);
            var f: [4]filt.Transfer = .{ .{}, .{}, .{}, .{} };
            for (ch.children.items) |fc| {
                if (fc.is_text) continue;
                const idx: usize = if (std.mem.eql(u8, fc.tag, "feFuncR")) 0 else if (std.mem.eql(u8, fc.tag, "feFuncG")) 1 else if (std.mem.eql(u8, fc.tag, "feFuncB")) 2 else if (std.mem.eql(u8, fc.tag, "feFuncA")) 3 else continue;
                f[idx] = try transferOf(r, fc);
            }
            filt.componentTransfer(&out, f);
        } else if (std.mem.eql(u8, tag, "feDropShadow")) {
            var in = try c.input(ch.attr("in"));
            defer in.deinit(gpa);
            filt.setSpace(&in, lin);
            var sh = try filt.offset(gpa, in, @intFromFloat(std.math.clamp(@round(c.px(numAttr(ch, "dx", 2), true)), -1e6, 1e6)), @intFromFloat(std.math.clamp(@round(c.px(numAttr(ch, "dy", 2), false)), -1e6, 1e6)));
            defer sh.deinit(gpa);
            const sd = c.pair(ch.attr("stdDeviation"), 2);
            try filt.blur(gpa, &sh, @floatCast(c.px(sd[0], true)), @floatCast(c.px(sd[1], false)));
            var flood = try filt.Img.init(gpa, rw, rh);
            defer flood.deinit(gpa);
            filt.flood(&flood, floodColor(&s, lin));
            var colored = try filt.Img.init(gpa, rw, rh);
            defer colored.deinit(gpa);
            filt.composite(&colored, flood, sh, .in, .{ 0, 0, 0, 0 });
            out = try filt.Img.init(gpa, rw, rh);
            filt.composite(&out, in, colored, .over, .{ 0, 0, 0, 0 });
        } else if (std.mem.eql(u8, tag, "feTurbulence")) {
            out = try filt.Img.init(gpa, rw, rh);
            const bf = c.pair(ch.attr("baseFrequency"), 0);
            const inv = st.ctm.inverse() orelse raster.Mat.identity;
            const oct: u32 = @intFromFloat(std.math.clamp(numAttr(ch, "numOctaves", 1), 0, 10));
            if (bf[0] >= 0 and bf[1] >= 0) filt.turbulence(&out, @floatFromInt(rx), @floatFromInt(ry), inv, .{
                .fx = bf[0],
                .fy = bf[1],
                .octaves = oct,
                .seed = @intFromFloat(@round(std.math.clamp(numAttr(ch, "seed", 0), -1e9, 1e9))),
                .fractal = std.mem.eql(u8, ch.attr("type") orelse "turbulence", "fractalNoise"),
            });
        } else if (std.mem.eql(u8, tag, "feMorphology")) {
            out = try c.input(ch.attr("in"));
            filt.setSpace(&out, lin);
            const rr = c.pair(ch.attr("radius"), 0);
            try filt.morphology(gpa, &out, c.px(rr[0], true), c.px(rr[1], false), std.mem.eql(u8, ch.attr("operator") orelse "erode", "dilate"));
        } else if (std.mem.eql(u8, tag, "feTile")) {
            var in = try c.input(ch.attr("in"));
            defer in.deinit(gpa);
            const rc = c.inputRect(ch.attr("in")) orelse Rect{ .x0 = 0, .y0 = 0, .x1 = @intCast(rw), .y1 = @intCast(rh) };
            const tw = @max(1, rc.x1 - rc.x0);
            const th = @max(1, rc.y1 - rc.y0);
            out = try filt.Img.init(gpa, rw, rh);
            out.linear = in.linear;
            const iw: isize = @intCast(rw);
            const ih: isize = @intCast(rh);
            for (0..rh) |row| {
                for (0..rw) |col| {
                    const sx = rc.x0 + @mod(@as(isize, @intCast(col)) - rc.x0, tw);
                    const sy = rc.y0 + @mod(@as(isize, @intCast(row)) - rc.y0, th);
                    if (sx < 0 or sy < 0 or sx >= iw or sy >= ih) continue;
                    @memcpy(out.px[(row * rw + col) * 4 ..][0..4], in.px[(@as(usize, @intCast(sy)) * rw + @as(usize, @intCast(sx))) * 4 ..][0..4]);
                }
            }
        } else if (std.mem.eql(u8, tag, "feImage")) {
            out = try filt.Img.init(gpa, rw, rh);
            if (try c.feImage(ch)) |img| {
                out.deinit(gpa);
                out = img;
                filt.setSpace(&out, lin);
            }
        } else if (std.mem.eql(u8, tag, "feDiffuseLighting") or std.mem.eql(u8, tag, "feSpecularLighting")) {
            var in = try c.input(ch.attr("in"));
            defer in.deinit(gpa);
            const specular = tag[2] == 'S';
            var light: ?filt.Light = null;
            const scl = (c.sx + c.sy) / 2;
            for (ch.children.items) |lt| {
                if (lt.is_text) continue;
                const ox: f64 = @floatFromInt(rx);
                const oy: f64 = @floatFromInt(ry);
                if (std.mem.eql(u8, lt.tag, "feDistantLight")) {
                    light = .{ .distant = .{ .az = numAttr(lt, "azimuth", 0), .el = numAttr(lt, "elevation", 0) } };
                } else if (std.mem.eql(u8, lt.tag, "fePointLight") or std.mem.eql(u8, lt.tag, "feSpotLight")) {
                    const p = st.ctm.apply(.{ .x = numAttr(lt, "x", 0), .y = numAttr(lt, "y", 0) });
                    const pos = [3]f64{ p.x - ox, p.y - oy, numAttr(lt, "z", 0) * scl };
                    if (lt.tag[2] == 'P') {
                        light = .{ .point = pos };
                    } else {
                        const q = st.ctm.apply(.{ .x = numAttr(lt, "pointsAtX", 0), .y = numAttr(lt, "pointsAtY", 0) });
                        const cone: ?f64 = if (lt.attr("limitingConeAngle")) |_| @cos(@abs(numAttr(lt, "limitingConeAngle", 0)) * std.math.pi / 180.0) else null;
                        light = .{ .spot = .{ .pos = pos, .at = .{ q.x - ox, q.y - oy, numAttr(lt, "pointsAtZ", 0) * scl }, .exp = numAttr(lt, "specularExponent", 1), .cone = cone } };
                    }
                }
            }
            out = try filt.Img.init(gpa, rw, rh);
            if (light) |lg| {
                var lcol = [3]f32{ s.lighting_color.r, s.lighting_color.g, s.lighting_color.b };
                if (lin) for (&lcol) |*cc| {
                    cc.* = srgbToLinear(cc.*);
                };
                const lit = try filt.lighting(gpa, in, .{
                    .light = lg,
                    .color = lcol,
                    .scale = numAttr(ch, "surfaceScale", 1),
                    .k = numAttr(ch, if (specular) "specularConstant" else "diffuseConstant", 1),
                    .exponent = std.math.clamp(numAttr(ch, "specularExponent", 1), 1, 128),
                    .specular = specular,
                });
                out.deinit(gpa);
                out = lit;
            }
        } else if (std.mem.eql(u8, tag, "feDisplacementMap")) {
            var a = try c.input(ch.attr("in"));
            defer a.deinit(gpa);
            var m = try c.input(ch.attr("in2"));
            defer m.deinit(gpa);
            filt.setSpace(&a, lin);
            filt.setSpace(&m, lin);
            const ch_idx = struct {
                fn f(n: *Node, name: []const u8) usize {
                    const v = n.attr(name) orelse return 3;
                    return if (std.mem.eql(u8, v, "R")) 0 else if (std.mem.eql(u8, v, "G")) 1 else if (std.mem.eql(u8, v, "B")) 2 else 3;
                }
            }.f;
            const sc = numAttr(ch, "scale", 0);
            out = try filt.displacement(gpa, a, m, c.px(sc, true), c.px(sc, false), ch_idx(ch, "xChannelSelector"), ch_idx(ch, "yChannelSelector"));
        } else if (std.mem.eql(u8, tag, "feConvolveMatrix")) {
            out = try c.input(ch.attr("in"));
            filt.setSpace(&out, lin);
            const pr = c.pair(ch.attr("order"), 3);
            const ox: usize = @intFromFloat(std.math.clamp(pr[0], 1, 16));
            const oy: usize = @intFromFloat(std.math.clamp(pr[1], 1, 16));
            const kernel = try r.arena.alloc(f32, ox * oy);
            var sc: raster.NumScan = .{ .s = ch.attr("kernelMatrix") orelse "" };
            var n: usize = 0;
            while (n < kernel.len) : (n += 1) kernel[n] = @floatCast(sc.number() orelse break);
            if (n == kernel.len) {
                var div: f32 = 0;
                for (kernel) |kv| div += kv;
                div = numAttr(ch, "divisor", if (div == 0) 1 else div);
                if (div == 0) div = 1;
                const em = ch.attr("edgeMode") orelse "duplicate";
                const conv = try filt.convolve(gpa, out, .{
                    .order_x = ox,
                    .order_y = oy,
                    .kernel = kernel,
                    .divisor = div,
                    .bias = numAttr(ch, "bias", 0),
                    .target_x = @min(@as(usize, @intFromFloat(std.math.clamp(numAttr(ch, "targetX", @floatFromInt(ox / 2)), 0, 15))), ox - 1),
                    .target_y = @min(@as(usize, @intFromFloat(std.math.clamp(numAttr(ch, "targetY", @floatFromInt(oy / 2)), 0, 15))), oy - 1),
                    .edge = if (std.mem.eql(u8, em, "wrap")) .wrap else if (std.mem.eql(u8, em, "none")) .none else .duplicate,
                    .preserve_alpha = std.mem.eql(u8, ch.attr("preserveAlpha") orelse "false", "true"),
                });
                out.deinit(gpa);
                out = conv;
            }
        } else {
            out = try filt.Img.init(gpa, rw, rh);
        }
        out.linear = if (std.mem.eql(u8, tag, "feGaussianBlur") or std.mem.eql(u8, tag, "feColorMatrix") or std.mem.eql(u8, tag, "feComponentTransfer")) lin else lin;
        const sub = c.clearOutside(&out, ch, &s);
        try c.results.append(gpa, .{ .name = ch.attr("result"), .img = out, .rect = sub });
    }
    @memset(layer.px, 0);
    if (c.results.items.len == 0) return;
    const last = &c.results.items[c.results.items.len - 1].img;
    filt.setSpace(last, false);
    for (0..rh) |row| {
        for (0..rw) |col| {
            const d = ((ry + row) * layer.w + rx + col) * 4;
            const s = (row * rw + col) * 4;
            for (0..4) |k| layer.px[d + k] = @intFromFloat(std.math.clamp(last.px[s + k] * 255 + 0.5, 0, 255));
        }
    }
}

fn layerToImg(gpa: std.mem.Allocator, layer: *const draw.Layer) Error!filt.Img {
    var img = try filt.Img.init(gpa, layer.w, layer.h);
    for (layer.px, 0..) |b, i| img.px[i] = @as(f32, @floatFromInt(b)) / 255;
    return img;
}

fn imgToLayer(img: *const filt.Img, layer: *draw.Layer) void {
    for (img.px, 0..) |v, i| layer.px[i] = @intFromFloat(std.math.clamp(v * 255 + 0.5, 0, 255));
}

fn splitSp(arena: std.mem.Allocator, v: []const u8) Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: u32 = 0;
    var st: usize = 0;
    for (v, 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')' and depth > 0) depth -= 1;
        if ((ch == ' ' or ch == ',') and depth == 0) {
            if (i > st) try out.append(arena, v[st..i]);
            st = i + 1;
        }
    }
    if (st < v.len) try out.append(arena, v[st..]);
    return out.items;
}

fn amountOf(args: []const u8) f32 {
    const t = std.mem.trim(u8, args, " ");
    if (t.len == 0) return 1;
    if (t[t.len - 1] == '%') return (std.fmt.parseFloat(f32, t[0 .. t.len - 1]) catch return 1) / 100;
    return std.fmt.parseFloat(f32, t) catch 1;
}

pub fn applyFunction(r: *draw.Renderer, layer: *draw.Layer, st: *const draw.State, name: []const u8, args: []const u8) Error!void {
    const gpa = r.gpa;
    try r.charge(@as(u64, layer.w) * layer.h * 20);
    var img = try layerToImg(gpa, layer);
    defer img.deinit(gpa);
    const eq = std.mem.eql;
    const scale = st.ctm.meanScale();
    const lcx: sty.LenCtx = .{ .font_size = st.style.font_size, .vw = st.vw, .vh = st.vh };
    var m: [20]f32 = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    var use_matrix = true;
    const a = amountOf(args);
    if (eq(u8, name, "blur")) {
        use_matrix = false;
        const sd: f32 = @floatCast(sty.lenOr(args, .diag, lcx, 0) * scale);
        try filt.blur(gpa, &img, sd, sd);
    } else if (eq(u8, name, "drop-shadow")) {
        use_matrix = false;
        const toks = try splitSp(r.arena, args);
        var lens: [3]f64 = .{ 0, 0, 0 };
        var n: usize = 0;
        var color = st.style.color;
        for (toks) |t| {
            if (std.ascii.eqlIgnoreCase(t, "currentcolor")) {
                color = st.style.color;
            } else if (sty.parseLen(t) != null and n < 3) {
                lens[n] = sty.lenOr(t, .diag, lcx, 0);
                n += 1;
            } else if (sty.parseColor(t)) |cc| color = cc;
        }
        var sh = try filt.offset(gpa, img, @intFromFloat(std.math.clamp(@round(lens[0] * scale), -1e6, 1e6)), @intFromFloat(std.math.clamp(@round(lens[1] * scale), -1e6, 1e6)));
        defer sh.deinit(gpa);
        try filt.blur(gpa, &sh, @floatCast(lens[2] * scale), @floatCast(lens[2] * scale));
        var flood = try filt.Img.init(gpa, layer.w, layer.h);
        defer flood.deinit(gpa);
        filt.flood(&flood, .{ color.r, color.g, color.b, color.a });
        var colored = try filt.Img.init(gpa, layer.w, layer.h);
        defer colored.deinit(gpa);
        filt.composite(&colored, flood, sh, .in, .{ 0, 0, 0, 0 });
        var res = try filt.Img.init(gpa, layer.w, layer.h);
        defer res.deinit(gpa);
        filt.composite(&res, img, colored, .over, .{ 0, 0, 0, 0 });
        @memcpy(img.px, res.px);
    } else if (eq(u8, name, "grayscale")) {
        const s = 1 - std.math.clamp(a, 0, 1);
        m = .{ 0.2126 + 0.7874 * s, 0.7152 - 0.7152 * s, 0.0722 - 0.0722 * s, 0, 0, 0.2126 - 0.2126 * s, 0.7152 + 0.2848 * s, 0.0722 - 0.0722 * s, 0, 0, 0.2126 - 0.2126 * s, 0.7152 - 0.7152 * s, 0.0722 + 0.9278 * s, 0, 0, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "sepia")) {
        const s = 1 - std.math.clamp(a, 0, 1);
        m = .{ 0.393 + 0.607 * s, 0.769 - 0.769 * s, 0.189 - 0.189 * s, 0, 0, 0.349 - 0.349 * s, 0.686 + 0.314 * s, 0.168 - 0.168 * s, 0, 0, 0.272 - 0.272 * s, 0.534 - 0.534 * s, 0.131 + 0.869 * s, 0, 0, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "saturate")) {
        m = .{ 0.213 + 0.787 * a, 0.715 - 0.715 * a, 0.072 - 0.072 * a, 0, 0, 0.213 - 0.213 * a, 0.715 + 0.285 * a, 0.072 - 0.072 * a, 0, 0, 0.213 - 0.213 * a, 0.715 - 0.715 * a, 0.072 + 0.928 * a, 0, 0, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "hue-rotate")) {
        const t = std.mem.trim(u8, args, " ");
        var deg: f32 = std.fmt.parseFloat(f32, std.mem.trimEnd(u8, t, "degradturn")) catch 0;
        if (std.mem.endsWith(u8, t, "turn")) deg *= 360 else if (std.mem.endsWith(u8, t, "rad")) deg *= 180.0 / std.math.pi else if (std.mem.endsWith(u8, t, "grad")) deg *= 0.9;
        const rad = deg * std.math.pi / 180.0;
        const cs = @cos(rad);
        const sn = @sin(rad);
        m = .{ 0.213 + cs * 0.787 - sn * 0.213, 0.715 - cs * 0.715 - sn * 0.715, 0.072 - cs * 0.072 + sn * 0.928, 0, 0, 0.213 - cs * 0.213 + sn * 0.143, 0.715 + cs * 0.285 + sn * 0.140, 0.072 - cs * 0.072 - sn * 0.283, 0, 0, 0.213 - cs * 0.213 - sn * 0.787, 0.715 - cs * 0.715 + sn * 0.715, 0.072 + cs * 0.928 + sn * 0.072, 0, 0, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "brightness")) {
        m = .{ a, 0, 0, 0, 0, 0, a, 0, 0, 0, 0, 0, a, 0, 0, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "contrast")) {
        const o = 0.5 - 0.5 * a;
        m = .{ a, 0, 0, 0, o, 0, a, 0, 0, o, 0, 0, a, 0, o, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "invert")) {
        const k = std.math.clamp(a, 0, 1);
        m = .{ 1 - 2 * k, 0, 0, 0, k, 0, 1 - 2 * k, 0, 0, k, 0, 0, 1 - 2 * k, 0, k, 0, 0, 0, 1, 0 };
    } else if (eq(u8, name, "opacity")) {
        m = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, std.math.clamp(a, 0, 1), 0 };
    } else return;
    if (use_matrix) filt.colorMatrix(&img, m);
    imgToLayer(&img, layer);
}
