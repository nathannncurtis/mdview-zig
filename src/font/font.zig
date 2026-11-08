const std = @import("std");
const builtin = @import("builtin");
const ttf = @import("ttf.zig");
const resolver = @import("resolve.zig");

pub const Font = ttf.Font;
pub const Path = ttf.Path;
pub const Mat = ttf.Mat;
pub const Pt = ttf.Pt;
pub const Error = ttf.Error;
pub const resolve = resolver.resolve;
pub const Chain = resolver.Chain;

pub fn resolveFont(io: std.Io, families: []const u8, weight: u16, italic: bool) *const Font {
    return resolve(io, families, weight, italic).primary;
}
pub const bundled = resolver.bundled;
pub const mathFont = resolver.mathFont;
pub const embeddedMathFont = resolver.embeddedMathFont;
pub const math = ttf.math;

pub const Size = struct { w: f64, h: f64 };

pub fn measure(font: *const Font, utf8: []const u8, size: f64) Size {
    const m = font.measure(utf8, size);
    return .{ .w = m.w, .h = m.h };
}

const sample = "Validate order? Wait: AV Team / Ship Today (Type 2)";

test {
    _ = @import("cff.zig");
}

test "bundled font metrics" {
    const f = bundled(false, false);
    try std.testing.expectEqual(@as(u16, 2048), f.upem);
    try std.testing.expectEqual(@as(f64, 1366), f.advance(f.glyphIndex('A')));
    try std.testing.expect(f.kern(f.glyphIndex('A'), f.glyphIndex('V')) < 0);
    try std.testing.expectEqual(@as(u16, 0), f.glyphIndex(0x4E2D));
    try std.testing.expect(f.glyphIndex(0xE9) != 0);
    try std.testing.expect(f.glyphIndex(0x20AC) != 0);
    const b = bundled(true, false);
    try std.testing.expect(b.advance(b.glyphIndex('A')) == 1479);
}

test "bundled glyphs have outlines, composites included" {
    const a = std.testing.allocator;
    const f = bundled(false, false);
    for ([_]u32{ 'A', 'g', 0xE9, 0xC5, 0x20AC }) |cp| {
        var p: Path = .{};
        defer p.deinit(a);
        try f.outline(a, f.glyphIndex(cp), .{}, &p);
        try std.testing.expect(p.segs.items.len > 4);
    }
    var space: Path = .{};
    defer space.deinit(a);
    try f.outline(a, f.glyphIndex(' '), .{}, &space);
    try std.testing.expectEqual(@as(usize, 0), space.segs.items.len);
}

test "outlineAt scales, flips and slants" {
    const a = std.testing.allocator;
    const f = bundled(false, false);
    const g = f.glyphIndex('I');
    var p: Path = .{};
    defer p.deinit(a);
    try f.outlineAt(a, g, 16, 10, 20, &p);
    var min_y: f64 = 1e9;
    var max_y: f64 = -1e9;
    for (p.segs.items) |s| switch (s) {
        .move, .line => |q| {
            min_y = @min(min_y, q.y);
            max_y = @max(max_y, q.y);
        },
        else => {},
    };
    try std.testing.expectApproxEqAbs(@as(f64, 20), max_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 20 - 1409.0 / 2048.0 * 16), min_y, 0.1);
    const it = bundled(false, true);
    try std.testing.expect(it.oblique);
    var q: Path = .{};
    defer q.deinit(a);
    try it.outlineAt(a, g, 16, 10, 20, &q);
    var shift: f64 = 0;
    for (p.segs.items, q.segs.items) |sp, sq| switch (sp) {
        .move, .line => |pp| shift = @max(shift, switch (sq) {
            .move, .line => |qq| qq.x - pp.x,
            else => 0,
        }),
        else => {},
    };
    try std.testing.expectApproxEqAbs(0.25 * 1409.0 / 2048.0 * 16, shift, 0.1);
}

test "measure sums advances and applies kerning" {
    const f = bundled(false, false);
    const plain = f.width("AV", 16, false);
    const kerned = measure(f, "AV", 16);
    try std.testing.expectApproxEqAbs(@as(f64, (1366 + 1366) * 16.0 / 2048.0), plain, 1e-9);
    try std.testing.expect(kerned.w < plain);
    try std.testing.expectApproxEqAbs(f.lineHeight(16), kerned.h, 1e-9);
    try std.testing.expect(kerned.h > 16 and kerned.h < 20);
    try std.testing.expectEqual(@as(f64, 0), f.width("", 16, true));
    try std.testing.expect(f.width("\xff\xfe\xc3", 16, true) > 0);
}

test "resolver falls back to the bundled font" {
    const io = std.testing.io;
    try std.testing.expect(resolveFont(io, "no-such-family-zz", 400, false) == bundled(false, false));
    try std.testing.expect(resolveFont(io, "'No Such', \"Other One\"", 700, false) == bundled(true, false));
    try std.testing.expect(resolveFont(io, "no-such-family-zz", 400, false) == bundled(false, false));
}

test "sans-serif resolves to a face with Arial metrics" {
    const f = resolveFont(std.testing.io, "sans-serif", 400, false);
    const ratio = f.advance(f.glyphIndex('A')) / @as(f64, @floatFromInt(f.upem));
    try std.testing.expectApproxEqAbs(@as(f64, 0.667), ratio, 0.002);
    const w = f.width(sample, 16, false);
    try std.testing.expectApproxEqAbs(@as(f64, 378.83), w, 0.1);
}

test "file names follow each platform's layout" {
    const win = resolver.fileNames(.windows, "trebuchet ms", true, false);
    try std.testing.expectEqualStrings("trebucbd.ttf", win.get(0));
    const mac = resolver.fileNames(.macos, "trebuchet ms", true, true);
    try std.testing.expectEqualStrings("Trebuchet MS Bold Italic.ttf", mac.get(0));
    const lin = resolver.fileNames(.linux, "trebuchet ms", false, false);
    try std.testing.expectEqualStrings("trebuc.ttf", lin.get(0));
    try std.testing.expectEqualStrings("trebuchet_ms.ttf", lin.get(1));
    try std.testing.expectEqual(@as(usize, 0), resolver.fileNames(.windows, "tahoma", false, true).n);
}

test "collections pick the face by family and style" {
    const a = std.testing.allocator;
    const one = @embedFile("sans_regular.ttf");
    const bold = @embedFile("sans_bold.ttf");
    const head = 12 + 8;
    const out = try a.alloc(u8, head + one.len + bold.len);
    defer a.free(out);
    @memcpy(out[0..4], "ttcf");
    std.mem.writeInt(u32, out[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, out[8..12], 2, .big);
    std.mem.writeInt(u32, out[12..16], head, .big);
    std.mem.writeInt(u32, out[16..20], head + one.len, .big);
    for ([_]struct { src: []const u8, at: usize }{ .{ .src = one, .at = head }, .{ .src = bold, .at = head + one.len } }) |part| {
        @memcpy(out[part.at..][0..part.src.len], part.src);
        const n = std.mem.readInt(u16, part.src[4..6], .big);
        for (0..n) |i| {
            const rec = part.at + 12 + i * 16 + 8;
            std.mem.writeInt(u32, out[rec..][0..4], std.mem.readInt(u32, out[rec..][0..4], .big) + @as(u32, @intCast(part.at)), .big);
        }
    }
    try std.testing.expectEqual(@as(u32, 2), ttf.faceCount(out));
    try std.testing.expectEqual(@as(?u32, 0), resolver.pickFace(out, "mdview sans", false, false));
    try std.testing.expectEqual(@as(?u32, 1), resolver.pickFace(out, "mdview sans", true, false));
    try std.testing.expectEqual(@as(?u32, null), resolver.pickFace(out, "mdview sans", false, true));
    try std.testing.expectEqual(@as(?u32, null), resolver.pickFace(out, "other", false, false));
    const f1 = try Font.init(out, 1);
    try std.testing.expectEqual(@as(f64, 1479), f1.advance(f1.glyphIndex('A')));
}

test "damaged fonts never crash the parser" {
    const a = std.testing.allocator;
    const src = @embedFile("sans_regular.ttf");
    const buf = try a.dupe(u8, src);
    defer a.free(buf);
    var prng = std.Random.DefaultPrng.init(0x464f4e54);
    const r = prng.random();
    for (0..300) |round| {
        @memcpy(buf, src);
        for (0..1 + round % 24) |_| buf[r.uintLessThan(usize, buf.len)] = r.int(u8);
        const cut = if (round % 5 == 0) r.uintLessThan(usize, buf.len) else buf.len;
        const f = Font.init(buf[0..cut], 0) catch continue;
        _ = f.width(sample, 16, true);
        for ([_]u32{ 'A', 'g', 0xE9, 0xC5 }) |cp| {
            var p: Path = .{};
            defer p.deinit(a);
            f.outline(a, f.glyphIndex(cp), .{}, &p) catch {};
        }
    }
}

test "installed fonts match DirectWrite advances on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const cases = [_]struct { families: []const u8, weight: u16, expect: f64 }{
        .{ .families = "\"trebuchet ms\", verdana, arial, sans-serif", .weight = 400, .expect = 381.1094 },
        .{ .families = "trebuchet ms", .weight = 700, .expect = 395.0703 },
        .{ .families = "sans-serif", .weight = 400, .expect = 378.8281 },
        .{ .families = "arial", .weight = 700, .expect = 398.2891 },
        .{ .families = "verdana", .weight = 400, .expect = 431.6250 },
    };
    for (cases) |c| {
        const f = resolveFont(io, c.families, c.weight, false);
        if (f == bundled(c.weight >= 600, false)) return error.SkipZigTest;
        try std.testing.expectApproxEqAbs(c.expect, f.width(sample, 16, false), 0.1);
        try std.testing.expect(f.width(sample, 16, true) < c.expect);
    }
    const arial = resolveFont(io, "arial", 400, false);
    try std.testing.expectEqual(@as(f64, -152), arial.kern(arial.glyphIndex('A'), arial.glyphIndex('V')));
    try std.testing.expectEqual(@as(f64, 18), arial.lineHeight(16));
}

const ranges = @import("math_ranges.zig").ranges;

test "embedded math font carries the MATH table" {
    const f = embeddedMathFont(std.testing.io);
    const m = f.math.?;
    try std.testing.expect(f.cff != null);
    try std.testing.expectEqual(@as(u16, 1000), f.upem);
    try std.testing.expectEqual(@as(i16, 70), m.constants.script_percent_scale_down);
    try std.testing.expectEqual(@as(i16, 55), m.constants.script_script_percent_scale_down);
    try std.testing.expectEqual(@as(i16, 258), m.constants.axis_height);
    try std.testing.expectEqual(@as(i16, 68), m.constants.fraction_rule_thickness);
    try std.testing.expectEqual(@as(i16, 360), m.constants.superscript_shift_up);
    try std.testing.expectEqual(@as(u16, 100), m.min_connector_overlap);
    const lp = f.glyphFor('(');
    try std.testing.expectEqual(Font.BBox{ .x0 = 45, .y0 = -196, .x1 = 327, .y1 = 736 }, f.bbox(lp));
    const v = f.vertVariants(lp);
    try std.testing.expectEqual(@as(usize, 13), v.count);
    try std.testing.expectEqual(@as(u16, 933), v.get(0).?.advance);
    try std.testing.expectEqual(@as(u16, 3821), v.get(12).?.advance);
    const asm_ = f.assembly(lp, .vert).?;
    try std.testing.expectEqual(@as(usize, 3), asm_.count);
    try std.testing.expect(asm_.part(1).?.extender);
    try std.testing.expectEqual(@as(u16, 1252), asm_.part(1).?.full_advance);
    const integral = f.glyphFor(0x222B);
    try std.testing.expectEqual(@as(i16, 230), f.italicCorrection(integral));
    try std.testing.expectEqual(@as(i16, 342), f.topAccent(integral));
    const arrow = f.glyphFor(0x2192);
    try std.testing.expectEqual(@as(usize, 1), f.horizVariants(arrow).count);
    try std.testing.expectEqual(Font.BBox{ .x0 = 71, .y0 = 58, .x1 = 876, .y1 = 459 }, f.bbox(arrow));
}

test "embedded math font renders every kept glyph and all variants" {
    const a = std.testing.allocator;
    const f = embeddedMathFont(std.testing.io);
    var glyphs: usize = 0;
    var constructions: usize = 0;
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const g = f.glyphFor(cp);
            if (g == 0) continue;
            glyphs += 1;
            var p: Path = .{};
            defer p.deinit(a);
            try f.outline(a, g, .{}, &p);
            for ([_]math.Dir{ .vert, .horiz }) |dir| {
                const vs = f.math.?.variantsOf(g, dir);
                for (0..vs.count) |i| {
                    const e = vs.get(i).?;
                    var q: Path = .{};
                    defer q.deinit(a);
                    try f.outline(a, e.gid, .{}, &q);
                    try std.testing.expect(q.segs.items.len > 2);
                    try std.testing.expect(e.advance > 0);
                }
                if (f.assembly(g, dir)) |as| {
                    constructions += 1;
                    for (0..as.count) |i| {
                        var q: Path = .{};
                        defer q.deinit(a);
                        try f.outline(a, as.part(i).?.gid, .{}, &q);
                        try std.testing.expect(q.segs.items.len > 2);
                    }
                }
            }
        }
    }
    try std.testing.expect(glyphs > 2500);
    try std.testing.expect(constructions > 20);
}

test "embedded math font has the alphabets, digits and symbols" {
    const f = embeddedMathFont(std.testing.io);
    const starts = [_]u32{ 0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D4D0, 0x1D504, 0x1D538, 0x1D56C, 0x1D5A0, 0x1D5D4, 0x1D608, 0x1D63C, 0x1D670 };
    for (starts) |s| {
        var present: usize = 0;
        for (0..52) |i| {
            if (f.glyphFor(s + @as(u32, @intCast(i))) != 0) present += 1;
        }
        try std.testing.expect(present >= 40);
    }
    for ([_]u32{ 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6 }) |s| {
        for (0..10) |i| try std.testing.expect(f.glyphFor(s + @as(u32, @intCast(i))) != 0);
    }
    for ([_]u32{ 0x210E, 0x211D, 0x2115, 0x2124, 0x211A, 0x2102, 0x210F }) |cp| try std.testing.expect(f.glyphFor(cp) != 0);
    for ("+-=<>()[]{}|/!,.:;?") |c| try std.testing.expect(f.glyphFor(c) != 0);
    const symbols = [_]u32{
        0x2211, 0x220F, 0x222B, 0x222E, 0x221E, 0x2202, 0x2207, 0x221A, 0xB1,   0xD7,   0xF7,   0x2264, 0x2265, 0x2260, 0x2248,
        0x2261, 0x2208, 0x2209, 0x2282, 0x2283, 0x222A, 0x2229, 0x2227, 0x2228, 0xAC,   0x2200, 0x2203, 0x2192, 0x2190, 0x21D2,
        0x21D4, 0x21A6, 0x22EF, 0x22EE, 0x22F1, 0x2225, 0x27E8, 0x27E9, 0x2308, 0x2309, 0x230A, 0x230B, 0x2016, 0x20D7, 0x302,
        0x303,  0x304,  0x307,  0x2A00, 0x2A01, 0x2A02, 0x22C3, 0x22C2,
    };
    for (symbols) |cp| try std.testing.expect(f.glyphFor(cp) != 0);
    for (0x3B1..0x3CA) |cp| try std.testing.expect(f.glyphFor(@intCast(cp)) != 0);
    for (0x1D6FC..0x1D735) |cp| try std.testing.expect(f.glyphFor(@intCast(cp)) != 0);
}

test "math font discovery finds a system font or the embedded one" {
    const io = std.testing.io;
    const f = mathFont(io, null);
    try std.testing.expect(f.math != null);
    try std.testing.expect(f.glyphFor(0x2211) != 0);
    const axis = @as(f64, @floatFromInt(f.math.?.constants.axis_height)) / @as(f64, @floatFromInt(f.upem));
    try std.testing.expect(axis > 0.2 and axis < 0.35);
    switch (builtin.os.tag) {
        .windows, .macos => try std.testing.expect(f != embeddedMathFont(io)),
        else => {},
    }
}

test "Cambria Math MATH table on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const f = mathFont(std.testing.io, null);
    try std.testing.expectEqual(@as(u16, 2048), f.upem);
    try std.testing.expectEqual(@as(u16, 7614), f.num_glyphs);
    const m = f.math.?;
    try std.testing.expectEqual(@as(i16, 73), m.constants.script_percent_scale_down);
    try std.testing.expectEqual(@as(i16, 60), m.constants.script_script_percent_scale_down);
    try std.testing.expectEqual(@as(i16, 585), m.constants.axis_height);
    try std.testing.expectEqual(@as(i16, 133), m.constants.fraction_rule_thickness);
    try std.testing.expectEqual(@as(u16, 200), m.min_connector_overlap);
    const lp = f.glyphFor('(');
    try std.testing.expectEqual(Font.BBox{ .x0 = 180, .y0 = -452, .x1 = 812, .y1 = 1445 }, f.bbox(lp));
    const v = f.vertVariants(lp);
    try std.testing.expectEqual(@as(usize, 8), v.count);
    try std.testing.expectEqual(@as(u16, 4666), v.get(0).?.gid);
    try std.testing.expectEqual(@as(u16, 8881), v.get(7).?.advance);
    const asm_ = f.assembly(lp, .vert).?;
    try std.testing.expectEqual(@as(usize, 3), asm_.count);
    try std.testing.expectEqual(@as(u16, 1736), asm_.part(1).?.gid);
    try std.testing.expect(asm_.part(1).?.extender);
    try std.testing.expectEqual(@as(i16, 415), f.italicCorrection(f.glyphFor(0x222B)));
    try std.testing.expectEqual(@as(usize, 1), f.horizVariants(f.glyphFor(0x2192)).count);
}

test "damaged math fonts never crash the parser" {
    const a = std.testing.allocator;
    const src = embeddedMathFont(std.testing.io).data;
    const buf = try a.dupe(u8, src);
    defer a.free(buf);
    var prng = std.Random.DefaultPrng.init(0x4d415448);
    const r = prng.random();
    for (0..200) |round| {
        @memcpy(buf, src);
        for (0..1 + round % 40) |_| buf[r.uintLessThan(usize, buf.len)] = r.int(u8);
        const cut = if (round % 7 == 0) r.uintLessThan(usize, buf.len) else buf.len;
        const f = Font.init(buf[0..cut], 0) catch continue;
        for ([_]u32{ '(', 0x222B, 0x2192, 0x1D465, 0x302 }) |cp| {
            const g = f.glyphFor(cp);
            var p: Path = .{};
            defer p.deinit(a);
            f.outline(a, g, .{}, &p) catch {};
            _ = f.bbox(g);
            _ = f.italicCorrection(g);
            _ = f.topAccent(g);
            for ([_]math.Dir{ .vert, .horiz }) |dir| {
                const v = f.vertVariants(g);
                for (0..@min(v.count, 40)) |i| _ = v.get(i);
                if (f.assembly(g, dir)) |as| {
                    for (0..@min(as.count, 40)) |i| _ = as.part(i);
                }
            }
        }
    }
}

test "a Mermaid-style label with CJK and symbols falls back per character" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const chain = resolve(io, "\"trebuchet ms\", verdana, arial, sans-serif", 400, false);
    for ([_]u32{ 0x2192, 0x2605, 0x4E2D, 0x6587, 0xD55C }) |cp| {
        const g = chain.glyphFor(cp);
        try std.testing.expect(g.gid != 0);
        try std.testing.expect(cp == 0x2192 or g.font != chain.primary);
        var p: Path = .{};
        defer p.deinit(a);
        try g.font.outline(a, g.gid, .{}, &p);
        try std.testing.expect(p.segs.items.len > 2);
    }
    const em = chain.advancePx(0x4E2D, 16);
    try std.testing.expect(em > 14 and em < 18);
    const ascii = chain.measure("Start  done", 16);
    const mixed = chain.measure("Start \u{2192} \u{4E2D}\u{6587} \u{D55C} \u{2605} done", 16);
    try std.testing.expect(mixed.w > ascii.w + 3 * em);
    try std.testing.expect(mixed.h >= ascii.h);
    var p: Path = .{};
    defer p.deinit(a);
    try chain.outlineAt(a, 0x4E2D, 16, 0, 16, &p);
    try std.testing.expect(p.segs.items.len > 2);
}

test "the chain ends at the bundled font and then notdef" {
    const io = std.testing.io;
    const chain = resolve(io, "arial", 400, false);
    const g = chain.glyphFor(0xFFFF);
    try std.testing.expectEqual(@as(u16, 0), g.gid);
    try std.testing.expect(g.font == chain.primary);
    try std.testing.expect(chain.measure("a\u{FFFF}b", 16).w > 0);
    const unknown = resolve(io, "no-such-family-zz", 400, false);
    try std.testing.expectEqual(@as(usize, 1), unknown.faces.len);
    try std.testing.expect(unknown.primary == bundled(false, false));
    const latin = unknown.glyphFor('A');
    try std.testing.expect(latin.font == unknown.primary and latin.gid != 0);
}

test "math kern info and extended shapes are exposed" {
    const f = embeddedMathFont(std.testing.io);
    var kerned: usize = 0;
    var extended: usize = 0;
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const g = f.glyphFor(cp);
            if (g == 0) continue;
            if (f.isExtendedShape(g)) extended += 1;
            for ([_]math.Corner{ .top_right, .top_left, .bottom_right, .bottom_left }) |corner| {
                const k = f.mathKern(g, corner) orelse continue;
                kerned += 1;
                _ = k.atHeight(0);
                try std.testing.expect(k.value(k.count) != null);
            }
        }
    }
    try std.testing.expect(kerned > 50);
    try std.testing.expect(extended > 0);
}

test "family lists parse the way Chrome parses font-family" {
    const p = resolver.parseFamilies("\"trebuchet ms\", verdana, arial, sans-serif").?;
    try std.testing.expectEqual(@as(usize, 4), p.n);
    try std.testing.expectEqualStrings("trebuchet ms", p.name(0));
    try std.testing.expectEqualStrings("sans-serif", p.name(3));
    try std.testing.expect(p.quoted[0] and !p.quoted[1]);

    const q = resolver.parseFamilies("Segoe  UI   Symbol , 'Noto Sans' ,-apple-system").?;
    try std.testing.expectEqual(@as(usize, 3), q.n);
    try std.testing.expectEqualStrings("segoe ui symbol", q.name(0));
    try std.testing.expectEqualStrings("noto sans", q.name(1));
    try std.testing.expectEqualStrings("-apple-system", q.name(2));

    const esc = resolver.parseFamilies("\"A\\\"B\", Foo\\20 Bar").?;
    try std.testing.expectEqualStrings("a\"b", esc.name(0));
    try std.testing.expectEqualStrings("foo bar", esc.name(1));

    try std.testing.expect(resolver.parseFamilies("inherit") != null);
    try std.testing.expect(resolver.parseFamilies("'unterminated") != null);

    const invalid = [_][]const u8{
        "\"trebuchet ms\", verdana, arial, sans-serif;",
        "",
        "   ",
        "a,,b",
        "a,",
        ",a",
        "1abc",
        "Foo \"bar\"",
        "Foo!important",
        "a b;",
        "'broken\nstring'",
        "inherit, serif",
        "Foo(bar)",
        "a.b",
        "-1x",
    };
    for (invalid) |s| try std.testing.expect(resolver.parseFamilies(s) == null);
}

test "an invalid family list measures in the default serif" {
    const io = std.testing.io;
    const mermaid_default = "\"trebuchet ms\", verdana, arial, sans-serif;";
    const bad = resolve(io, mermaid_default, 400, false);
    const good = resolve(io, "\"trebuchet ms\", verdana, arial, sans-serif", 400, false);
    try std.testing.expect(bad != good);
    try std.testing.expect(bad.primary != good.primary);
    switch (builtin.os.tag) {
        .windows, .macos => {
            const serif = resolveFont(io, if (builtin.os.tag == .windows) "times new roman" else "times", 400, false);
            try std.testing.expect(bad.primary == serif);
            const ratio = serif.advance(serif.glyphIndex('A')) / @as(f64, @floatFromInt(serif.upem));
            try std.testing.expectApproxEqAbs(@as(f64, 0.722), ratio, 0.003);
        },
        else => try std.testing.expect(bad.primary != bundled(false, false)),
    }
    const same = resolve(io, "\"trebuchet ms\", verdana, arial, sans-serif;", 400, false);
    try std.testing.expect(same == bad);
    const bold = resolve(io, mermaid_default, 700, false);
    try std.testing.expect(bold.primary != good.primary);
    try std.testing.expect(bad.measure("Hello world", 16).w != good.measure("Hello world", 16).w);
}
