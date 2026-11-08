const std = @import("std");
const font = @import("font");
const draw = @import("svg_draw.zig");
const raster = @import("svg_raster.zig");
const sty = @import("svg_style.zig");
const shape = @import("svg_shape.zig");

const Font = font.Font;
const Mat = raster.Mat;

pub const Error = @import("image.zig").Error;

pub const Rendered = struct { rgba: []u8, w: usize, h: usize, m: Mat };

fn u16At(d: []const u8, off: usize) Error!u16 {
    if (off > d.len or d.len - off < 2) return error.Corrupt;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn i16At(d: []const u8, off: usize) Error!i16 {
    return @bitCast(try u16At(d, off));
}

fn u32At(d: []const u8, off: usize) Error!u32 {
    if (off > d.len or d.len - off < 4) return error.Corrupt;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

fn u24At(d: []const u8, off: usize) Error!usize {
    if (off > d.len or d.len - off < 3) return error.Corrupt;
    return (@as(usize, d[off]) << 16) | (@as(usize, d[off + 1]) << 8) | d[off + 2];
}

fn f2(d: []const u8, off: usize) Error!f64 {
    return @as(f64, @floatFromInt(try i16At(d, off))) / 16384.0;
}

fn fixed(d: []const u8, off: usize) Error!f64 {
    return @as(f64, @floatFromInt(@as(i32, @bitCast(try u32At(d, off))))) / 65536.0;
}

const Ctx = struct {
    r: *draw.Renderer,
    f: *const Font,
    colr: usize,
    cpal: ?usize,
    base_list: usize,
    layer_list: usize,
    w: usize,
    h: usize,
    fg: [4]f32,
    budget: u32 = 4000,

    fn color(c: *Ctx, palette: u16, alpha: f64) [4]f32 {
        if (palette == 0xFFFF) return .{ c.fg[0], c.fg[1], c.fg[2], @floatCast(c.fg[3] * alpha) };
        const cp = c.cpal orelse return .{ 0, 0, 0, 0 };
        const d = c.f.data;
        const ncol = u16At(d, cp + 2) catch return .{ 0, 0, 0, 0 };
        const arr = cp + (u32At(d, cp + 8) catch return .{ 0, 0, 0, 0 });
        const first = u16At(d, cp + 12) catch return .{ 0, 0, 0, 0 };
        if (palette >= ncol) return .{ 0, 0, 0, 0 };
        const o = arr + (@as(usize, first) + palette) * 4;
        if (o + 4 > d.len) return .{ 0, 0, 0, 0 };
        return .{ @as(f32, @floatFromInt(d[o + 2])) / 255, @as(f32, @floatFromInt(d[o + 1])) / 255, @as(f32, @floatFromInt(d[o])) / 255, @as(f32, @floatFromInt(d[o + 3])) / 255 * @as(f32, @floatCast(alpha)) };
    }

    fn colorLine(c: *Ctx, off: usize) Error![]draw.Stop {
        const d = c.f.data;
        const n = @min(try u16At(d, off + 1), 64);
        const out = try c.r.arena.alloc(draw.Stop, n);
        for (0..n) |i| {
            const o = off + 3 + i * 6;
            const col = c.color(try u16At(d, o + 2), try f2(d, o + 4));
            out[i] = .{ .off = @floatCast(try f2(d, o)), .c = col };
        }
        std.mem.sort(draw.Stop, out, {}, struct {
            fn lt(_: void, a: draw.Stop, b: draw.Stop) bool {
                return a.off < b.off;
            }
        }.lt);
        return out;
    }

    fn spreadOf(d: []const u8, off: usize) u8 {
        return switch (d[off]) {
            1 => 2,
            2 => 1,
            else => 0,
        };
    }

    fn source(c: *Ctx, off: usize, ctm: Mat) Error!?draw.Src {
        const d = c.f.data;
        const fmt = d[off];
        const inv = ctm.inverse() orelse return null;
        switch (fmt) {
            2, 3 => return .{ .solid = premul(c.color(try u16At(d, off + 1), try f2(d, off + 3))) },
            4, 5 => {
                const cl = off + try u24At(d, off + 1);
                const x0: f64 = @floatFromInt(try i16At(d, off + 4));
                const y0: f64 = @floatFromInt(try i16At(d, off + 6));
                const x1: f64 = @floatFromInt(try i16At(d, off + 8));
                const y1: f64 = @floatFromInt(try i16At(d, off + 10));
                const x2: f64 = @floatFromInt(try i16At(d, off + 12));
                const y2: f64 = @floatFromInt(try i16At(d, off + 14));
                const dx = x2 - x0;
                const dy = y2 - y0;
                const len = @sqrt(dx * dx + dy * dy);
                var ex = x1;
                var ey = y1;
                if (len > 0) {
                    const px = -dy / len;
                    const py = dx / len;
                    const proj = (x1 - x0) * px + (y1 - y0) * py;
                    ex = x0 + px * proj;
                    ey = y0 + py * proj;
                }
                const stops = try c.colorLine(cl);
                if (stops.len == 0) return null;
                return .{ .grad = .{ .radial = false, .p = .{ x0, y0, ex, ey, 0, 0 }, .stops = stops, .spread = spreadOf(d, cl), .inv = inv, .opacity = 1 } };
            },
            6, 7 => {
                const cl = off + try u24At(d, off + 1);
                const x0: f64 = @floatFromInt(try i16At(d, off + 4));
                const y0: f64 = @floatFromInt(try i16At(d, off + 6));
                const r0: f64 = @floatFromInt(try u16At(d, off + 8));
                const x1: f64 = @floatFromInt(try i16At(d, off + 10));
                const y1: f64 = @floatFromInt(try i16At(d, off + 12));
                const r1: f64 = @floatFromInt(try u16At(d, off + 14));
                const stops = try c.colorLine(cl);
                if (stops.len == 0) return null;
                return .{ .grad = .{ .radial = true, .p = .{ x1, y1, r1, x0, y0, r0 }, .stops = stops, .spread = spreadOf(d, cl), .inv = inv, .opacity = 1 } };
            },
            8, 9 => {
                const cl = off + try u24At(d, off + 1);
                const cx: f64 = @floatFromInt(try i16At(d, off + 4));
                const cy: f64 = @floatFromInt(try i16At(d, off + 6));
                const a0 = (try f2(d, off + 8)) * std.math.pi;
                const a1 = (try f2(d, off + 10)) * std.math.pi;
                const stops = try c.colorLine(cl);
                if (stops.len == 0) return null;
                return .{ .grad = .{ .radial = false, .sweep = .{ a0, a1 }, .p = .{ cx, cy, 0, 0, 0, 0 }, .stops = stops, .spread = spreadOf(d, cl), .inv = inv, .opacity = 1 } };
            },
            else => return null,
        }
    }

    fn transformOf(c: *Ctx, off: usize) Error!?Mat {
        const d = c.f.data;
        const fmt = d[off];
        const pi = std.math.pi;
        switch (fmt) {
            12, 13 => {
                const t = off + try u24At(d, off + 4);
                return .{ .a = try fixed(d, t), .b = try fixed(d, t + 4), .c = try fixed(d, t + 8), .d = try fixed(d, t + 12), .e = try fixed(d, t + 16), .f = try fixed(d, t + 20) };
            },
            14, 15 => return Mat.translate(@floatFromInt(try i16At(d, off + 4)), @floatFromInt(try i16At(d, off + 6))),
            16, 17 => return Mat.scale(try f2(d, off + 4), try f2(d, off + 6)),
            18, 19 => {
                const sx = try f2(d, off + 4);
                const sy = try f2(d, off + 6);
                return around(Mat.scale(sx, sy), @floatFromInt(try i16At(d, off + 8)), @floatFromInt(try i16At(d, off + 10)));
            },
            20, 21 => {
                const s = try f2(d, off + 4);
                return Mat.scale(s, s);
            },
            22, 23 => {
                const s = try f2(d, off + 4);
                return around(Mat.scale(s, s), @floatFromInt(try i16At(d, off + 6)), @floatFromInt(try i16At(d, off + 8)));
            },
            24, 25 => return rotation((try f2(d, off + 4)) * pi),
            26, 27 => return around(rotation((try f2(d, off + 4)) * pi), @floatFromInt(try i16At(d, off + 6)), @floatFromInt(try i16At(d, off + 8))),
            28, 29 => return skew((try f2(d, off + 4)) * pi, (try f2(d, off + 6)) * pi),
            30, 31 => return around(skew((try f2(d, off + 4)) * pi, (try f2(d, off + 6)) * pi), @floatFromInt(try i16At(d, off + 8)), @floatFromInt(try i16At(d, off + 10))),
            else => return null,
        }
    }

    fn glyphPath(c: *Ctx, gid: u16) Error!raster.Path {
        var p: raster.Path = .{};
        const id: font.Mat = .{};
        if (c.f.outline(c.r.gpa, gid, id, &p)) |_| {} else |_| {}
        return p;
    }

    fn fillLeaf(c: *Ctx, st: *const draw.State, off: usize, outline_ctm: Mat, grad_ctm: Mat, path: *const raster.Path) Error!void {
        const d = c.f.data;
        if (off >= d.len) return;
        if (c.budget == 0) return;
        c.budget -= 1;
        if (try c.transformOf(off)) |m| {
            const child = off + try u24At(d, off + 1);
            return c.fillLeaf(st, child, outline_ctm, grad_ctm.mul(m), path);
        }
        const src = (try c.source(off, grad_ctm)) orelse return;
        var s2 = st.*;
        s2.ctm = outline_ctm;
        try c.r.fillPath(&s2, path, .nonzero, src);
    }

    fn paint(c: *Ctx, st: *const draw.State, off: usize, ctm: Mat, depth: u32) Error!void {
        const d = c.f.data;
        if (off >= d.len or depth > 12 or c.budget == 0) return;
        c.budget -= 1;
        const fmt = d[off];
        switch (fmt) {
            1 => {
                const n = d[off + 1];
                const first = try u32At(d, off + 2);
                for (0..n) |i| {
                    const lp = c.layer_list + 4 + (@as(usize, first) + i) * 4;
                    try c.paint(st, c.layer_list + try u32At(d, lp), ctm, depth + 1);
                }
            },
            2, 3, 4, 5, 6, 7, 8, 9 => {
                const src = (try c.source(off, ctm)) orelse return;
                var s2 = st.*;
                s2.ctm = Mat.identity;
                var p: raster.Path = .{};
                defer p.segs.deinit(c.r.gpa);
                try p.moveTo(c.r.gpa, 0, 0);
                try p.lineTo(c.r.gpa, @floatFromInt(c.w), 0);
                try p.lineTo(c.r.gpa, @floatFromInt(c.w), @floatFromInt(c.h));
                try p.lineTo(c.r.gpa, 0, @floatFromInt(c.h));
                try p.close(c.r.gpa);
                try c.r.fillPath(&s2, &p, .nonzero, src);
            },
            10 => {
                const child = off + try u24At(d, off + 1);
                const gid = try u16At(d, off + 4);
                var p = try c.glyphPath(gid);
                defer p.segs.deinit(c.r.gpa);
                try c.fillLeaf(st, child, ctm, ctm, &p);
            },
            11 => {
                const gid = try u16At(d, off + 1);
                const root = c.baseGlyph(gid) orelse return;
                try c.paint(st, root, ctm, depth + 1);
            },
            12...31 => {
                const m = (try c.transformOf(off)) orelse return;
                try c.paint(st, off + try u24At(d, off + 1), ctm.mul(m), depth + 1);
            },
            32 => try c.composite(st, off, ctm, depth),
            else => {},
        }
    }

    fn baseGlyph(c: *Ctx, gid: u16) ?usize {
        const d = c.f.data;
        const n = u32At(d, c.base_list) catch return null;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = c.base_list + 4 + mid * 6;
            const g = u16At(d, rec) catch return null;
            if (g == gid) return c.base_list + (u32At(d, rec + 2) catch return null);
            if (g < gid) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn composite(c: *Ctx, st: *const draw.State, off: usize, ctm: Mat, depth: u32) Error!void {
        const d = c.f.data;
        const src_p = off + try u24At(d, off + 1);
        const mode = d[off + 4];
        const back_p = off + try u24At(d, off + 5);
        var back = try draw.Layer.init(c.r.gpa, c.w, c.h);
        defer back.deinit(c.r.gpa);
        var srcl = try draw.Layer.init(c.r.gpa, c.w, c.h);
        defer srcl.deinit(c.r.gpa);
        var s1 = st.*;
        s1.target = &back;
        try c.paint(&s1, back_p, ctm, depth + 1);
        var s2 = st.*;
        s2.target = &srcl;
        try c.paint(&s2, src_p, ctm, depth + 1);
        combine(&back, &srcl, mode);
        draw.compositeLayer(st.target, &back, 1, &.{});
    }
};

fn premul(c: [4]f32) [4]f32 {
    return .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
}

fn around(m: Mat, cx: f64, cy: f64) Mat {
    return Mat.translate(cx, cy).mul(m).mul(Mat.translate(-cx, -cy));
}

fn rotation(a: f64) Mat {
    return .{ .a = @cos(a), .b = @sin(a), .c = -@sin(a), .d = @cos(a) };
}

fn skew(ax: f64, ay: f64) Mat {
    return .{ .c = -@tan(ax), .b = @tan(ay) };
}

fn combine(back: *draw.Layer, src: *const draw.Layer, mode: u8) void {
    const blend: ?sty.Blend = switch (mode) {
        13 => .screen,
        14 => .overlay,
        15 => .darken,
        16 => .lighten,
        17 => .color_dodge,
        18 => .color_burn,
        19 => .hard_light,
        20 => .soft_light,
        21 => .difference,
        22 => .exclusion,
        23 => .multiply,
        24 => .hue,
        25 => .saturation,
        26 => .color,
        27 => .luminosity,
        else => null,
    };
    if (blend) |b| {
        draw.blendLayer(back, src, 1, &.{}, b);
        return;
    }
    var i: usize = 0;
    while (i < back.px.len) : (i += 4) {
        const sa = @as(f32, @floatFromInt(src.px[i + 3])) / 255;
        const da = @as(f32, @floatFromInt(back.px[i + 3])) / 255;
        var fs: f32 = 1;
        var fd: f32 = 1 - sa;
        switch (mode) {
            0 => {
                fs = 0;
                fd = 0;
            },
            1 => fd = 0,
            2 => fs = 0,
            4 => {
                fs = 1 - da;
                fd = 1;
            },
            5 => {
                fs = da;
                fd = 0;
            },
            6 => {
                fs = 0;
                fd = sa;
            },
            7 => {
                fs = 1 - da;
                fd = 0;
            },
            8 => {
                fs = 0;
                fd = 1 - sa;
            },
            9 => {
                fs = da;
                fd = 1 - sa;
            },
            10 => {
                fs = 1 - da;
                fd = sa;
            },
            11 => {
                fs = 1 - da;
                fd = 1 - sa;
            },
            12 => fd = 1,
            else => {},
        }
        for (0..4) |k| {
            const s: f32 = @floatFromInt(src.px[i + k]);
            const dd: f32 = @floatFromInt(back.px[i + k]);
            back.px[i + k] = @intFromFloat(std.math.clamp(s * fs + dd * fd + 0.5, 0, 255));
        }
    }
}

pub fn render(r: *draw.Renderer, a: std.mem.Allocator, f: *const Font, gid: u16, s_px: f64, fg: [4]f32) Error!?Rendered {
    const colr = shape.findTable(f, "COLR") orelse return null;
    const d = f.data;
    if ((u16At(d, colr) catch return null) < 1) return null;
    const bl_off = u32At(d, colr + 14) catch return null;
    if (bl_off == 0) return null;
    var ctx: Ctx = .{
        .r = r,
        .f = f,
        .colr = colr,
        .cpal = shape.findTable(f, "CPAL"),
        .base_list = colr + bl_off,
        .layer_list = colr + (u32At(d, colr + 18) catch 0),
        .w = 0,
        .h = 0,
        .fg = fg,
    };
    const root = ctx.baseGlyph(gid) orelse return null;
    const upem: f64 = @floatFromInt(f.upem);
    const adv = f.advance(gid);
    const x0 = -0.1 * upem;
    const x1 = adv + 0.1 * upem;
    const ytop = @as(f64, @floatFromInt(f.ascent)) * 1.05;
    const ybot = @as(f64, @floatFromInt(f.descent)) * 1.05;
    const w: usize = @intFromFloat(std.math.clamp(@ceil((x1 - x0) * s_px), 1, 1024));
    const h: usize = @intFromFloat(std.math.clamp(@ceil((ytop - ybot) * s_px), 1, 1024));
    ctx.w = w;
    ctx.h = h;
    var layer = try draw.Layer.init(r.gpa, w, h);
    defer layer.deinit(r.gpa);
    const saved_w = r.w;
    const saved_h = r.h;
    r.w = w;
    r.h = h;
    defer {
        r.w = saved_w;
        r.h = saved_h;
    }
    const m = Mat{ .a = s_px, .d = -s_px, .e = -x0 * s_px, .f = ytop * s_px };
    var st: draw.State = .{ .ctm = m, .style = .{}, .vw = 1, .vh = 1, .target = &layer };
    try ctx.paint(&st, root, m, 0);
    const px = try a.dupe(u8, layer.px);
    return .{ .rgba = px, .w = w, .h = h, .m = .{ .a = 1 / s_px, .d = -1 / s_px, .e = x0, .f = ytop } };
}
