const std = @import("std");
const svg = @import("svg.zig");
const testdata = @import("testdata");
const font = @import("font");
const woff = @import("svg_woff.zig");
const brotli = @import("svg_brotli.zig");

const Fixture = struct { name: []const u8, w: u32, h: u32, mean: f64, bad: f64, t: u64 = 0 };

const fixtures = [_]Fixture{
    .{ .name = "shapes", .w = 120, .h = 80, .mean = 1.0, .bad = 0.5 },
    .{ .name = "paths", .w = 120, .h = 80, .mean = 1.0, .bad = 0.8 },
    .{ .name = "strokes", .w = 120, .h = 100, .mean = 1.5, .bad = 1.0 },
    .{ .name = "gradients", .w = 140, .h = 100, .mean = 1.0, .bad = 0.5 },
    .{ .name = "icons", .w = 96, .h = 48, .mean = 1.0, .bad = 0.5 },
    .{ .name = "badge", .w = 208, .h = 40, .mean = 5.0, .bad = 9.0 },
    .{ .name = "badge_logo", .w = 272, .h = 56, .mean = 3.0, .bad = 5.0 },
    .{ .name = "logo", .w = 128, .h = 128, .mean = 1.0, .bad = 0.5 },
    .{ .name = "css", .w = 100, .h = 60, .mean = 1.0, .bad = 0.5 },
    .{ .name = "filters", .w = 140, .h = 80, .mean = 1.0, .bad = 0.5 },
    .{ .name = "filters2", .w = 240, .h = 120, .mean = 4.0, .bad = 1.0 },
    .{ .name = "filters3", .w = 240, .h = 120, .mean = 2.5, .bad = 2.5 },
    .{ .name = "pattern_marker", .w = 140, .h = 80, .mean = 1.5, .bad = 0.8 },
    .{ .name = "text", .w = 320, .h = 232, .mean = 3.0, .bad = 3.5 },
    .{ .name = "clips", .w = 120, .h = 80, .mean = 1.0, .bad = 1.0 },
    .{ .name = "masks", .w = 120, .h = 60, .mean = 1.0, .bad = 1.0 },
    .{ .name = "viewports", .w = 120, .h = 70, .mean = 1.0, .bad = 1.0 },
    .{ .name = "viewbox_slice", .w = 100, .h = 100, .mean = 1.0, .bad = 1.0 },
    .{ .name = "css_selectors", .w = 120, .h = 60, .mean = 2.0, .bad = 2.5 },
    .{ .name = "units", .w = 120, .h = 60, .mean = 1.0, .bad = 1.0 },
    .{ .name = "dark", .w = 120, .h = 60, .mean = 1.0, .bad = 1.0 },
    .{ .name = "anim_smil", .w = 120, .h = 60, .mean = 1.0, .bad = 1.0, .t = 1200 },
    .{ .name = "anim_css", .w = 120, .h = 60, .mean = 2.0, .bad = 2.0, .t = 900 },
    .{ .name = "blend", .w = 120, .h = 60, .mean = 1.0, .bad = 1.0 },
    .{ .name = "cssfilters", .w = 120, .h = 60, .mean = 2.0, .bad = 2.0 },
    .{ .name = "tile", .w = 60, .h = 60, .mean = 1.0, .bad = 1.0 },
    .{ .name = "feimage", .w = 60, .h = 60, .mean = 1.0, .bad = 1.0 },
    .{ .name = "diffuse", .w = 60, .h = 60, .mean = 2.0, .bad = 2.0 },
    .{ .name = "specular", .w = 60, .h = 60, .mean = 2.0, .bad = 2.0 },
    .{ .name = "marks", .w = 220, .h = 100, .mean = 5.0, .bad = 10.0 },
    .{ .name = "indic", .w = 220, .h = 110, .mean = 5.5, .bad = 10.0 },
    .{ .name = "use_khmer", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_myanmar", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_tibetan", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_balinese", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_javanese", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_sundanese", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_sinhala", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_syriac", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "use_nko", .w = 280, .h = 44, .mean = 6.0, .bad = 12.0 },
    .{ .name = "nested", .w = 120, .h = 60, .mean = 1.0, .bad = 0.5 },
    .{ .name = "card", .w = 300, .h = 135, .mean = 1.0, .bad = 1.0 },
    .{ .name = "textpath", .w = 280, .h = 180, .mean = 3.5, .bad = 4.5 },
};

fn premul(c: u8, a: u8) i32 {
    return @intCast(@as(u32, c) * a / 255);
}

fn checkFixture(comptime f: Fixture) !void {
    const a = std.testing.allocator;
    const src = testdata.file("images/svg/" ++ f.name ++ ".svg");
    const ref = testdata.file("images/svg/" ++ f.name ++ ".rgba");
    try std.testing.expectEqual(@as(usize, f.w * f.h * 4), ref.len);
    var img = try svg.renderAt(a, src, f.w, f.h, f.t);
    defer img.deinit(a);
    try std.testing.expectEqual(f.w, img.width);
    try std.testing.expectEqual(f.h, img.height);
    try std.testing.expectEqual(@as(usize, 1), img.frames.len);
    const got = img.frames[0].rgba;
    var total: u64 = 0;
    var bad: u64 = 0;
    var i: usize = 0;
    while (i < ref.len) : (i += 4) {
        var worst: i32 = @intCast(@abs(@as(i32, ref[i + 3]) - got[i + 3]));
        var sum: i32 = worst;
        for (0..3) |k| {
            const d: i32 = @intCast(@abs(premul(ref[i + k], ref[i + 3]) - premul(got[i + k], got[i + 3])));
            sum += d;
            worst = @max(worst, d);
        }
        total += @intCast(sum);
        if (worst > 40) bad += 1;
    }
    const px: f64 = @floatFromInt(f.w * f.h);
    const mean = @as(f64, @floatFromInt(total)) / (px * 4);
    const bad_pct = @as(f64, @floatFromInt(bad)) * 100 / px;
    std.debug.print("{s}: mean {d:.3}, bad {d:.3}%\n", .{ f.name, mean, bad_pct });
    if (mean > f.mean or bad_pct > f.bad) {
        std.debug.print("{s}: mean {d:.3} (limit {d}), bad {d:.3}% (limit {d}%)\n", .{ f.name, mean, f.mean, bad_pct, f.bad });
        return error.TestUnexpectedResult;
    }
}

test "fixtures match browser reference renders" {
    var failed: usize = 0;
    inline for (fixtures) |f| {
        checkFixture(f) catch {
            failed += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "intrinsic sizes" {
    const s1 = try svg.intrinsicSize("<svg width='40' height='20'/>");
    try std.testing.expectEqual(@as(f32, 40), s1.w);
    try std.testing.expectEqual(@as(f32, 20), s1.h);
    const s2 = try svg.intrinsicSize("<svg viewBox='0 0 50 25'/>");
    try std.testing.expectEqual(@as(f32, 50), s2.w);
    try std.testing.expectEqual(@as(f32, 25), s2.h);
    const s3 = try svg.intrinsicSize("<svg width='100' viewBox='0 0 50 25'/>");
    try std.testing.expectEqual(@as(f32, 50), s3.h);
    const s4 = try svg.intrinsicSize("<svg xmlns='http://www.w3.org/2000/svg'/>");
    try std.testing.expectEqual(@as(f32, 300), s4.w);
    try std.testing.expectEqual(@as(f32, 150), s4.h);
    try std.testing.expectError(error.Corrupt, svg.intrinsicSize("<html/>"));
}

test "malformed and oversized input return errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Corrupt, svg.render(a, "<svg><g></svg", 8, 8));
    try std.testing.expectError(error.Corrupt, svg.render(a, "not xml", 8, 8));
    try std.testing.expectError(error.Corrupt, svg.render(a, "<div/>", 8, 8));
    try std.testing.expectError(error.TooLarge, svg.render(a, "<svg/>", 9000, 9000));
    try std.testing.expectError(error.Corrupt, svg.render(a, "<svg/>", 0, 5));
}

test "bad geometry renders without crashing" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "<svg viewBox='0 0 0 0'><rect width='1e999' height='5'/></svg>",
        "<svg><path d='M 1e308 1e308 L -1e308 5 A 1e300 1e300 0 1 1 3 3 z' stroke='red' stroke-width='1e300'/></svg>",
        "<svg><circle r='nan' cx='inf'/><rect width='-5' height='5'/><path d='MMMM10 10 L'/></svg>",
        "<svg><g transform='scale(0)'><rect width='5' height='5'/></g><g transform='matrix(1e300 0 0 1e300 0 0)'><rect width='5' height='5'/></g></svg>",
        "<svg><path d='M0 0 L100 0' stroke='#000' stroke-dasharray='0.0001' stroke-width='3'/></svg>",
        "<svg><path d='M0 0 L100 0' stroke='#000' stroke-dasharray='0 0'/></svg>",
        "<svg><linearGradient id='g'/><rect width='9' height='9' fill='url(#g)'/><rect width='9' height='9' fill='url(#nope) red'/></svg>",
    };
    for (cases) |c| {
        var img = svg.render(a, c, 16, 16) catch continue;
        img.deinit(a);
    }
}

test "reference cycles and use bombs are bounded" {
    const a = std.testing.allocator;
    const cycle = "<svg xmlns:x='http://www.w3.org/1999/xlink'><g id='a'><use href='#b'/></g><g id='b'><use href='#a'/><rect width='5' height='5'/></g><use href='#a'/>" ++
        "<linearGradient id='l1' href='#l2'/><linearGradient id='l2' href='#l1'/><rect width='5' height='5' fill='url(#l1)'/>" ++
        "<clipPath id='c1' clip-path='url(#c1)'><rect width='3' height='3'/></clipPath><rect width='9' height='9' clip-path='url(#c1)'/></svg>";
    var img = try svg.render(a, cycle, 16, 16);
    img.deinit(a);
    var bomb: std.ArrayList(u8) = .empty;
    defer bomb.deinit(a);
    try bomb.appendSlice(a, "<svg><defs><g id='g0'><rect width='1' height='1'/></g>");
    for (1..12) |i| {
        try bomb.print(a, "<g id='g{d}'>", .{i});
        for (0..10) |_| try bomb.print(a, "<use href='#g{d}'/>", .{i - 1});
        try bomb.appendSlice(a, "</g>");
    }
    try bomb.appendSlice(a, "</defs><use href='#g11'/></svg>");
    try std.testing.expectError(error.TooLarge, svg.render(a, bomb.items, 16, 16));
}

test "deep nesting and layers are bounded" {
    const a = std.testing.allocator;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(a);
    try deep.appendSlice(a, "<svg>");
    for (0..300) |_| try deep.appendSlice(a, "<g opacity='.9'>");
    try deep.appendSlice(a, "<rect width='9' height='9'/>");
    for (0..300) |_| try deep.appendSlice(a, "</g>");
    try deep.appendSlice(a, "</svg>");
    try std.testing.expectError(error.TooLarge, svg.render(a, deep.items, 16, 16));
    var ok: std.ArrayList(u8) = .empty;
    defer ok.deinit(a);
    try ok.appendSlice(a, "<svg>");
    for (0..100) |_| try ok.appendSlice(a, "<g opacity='.9'>");
    try ok.appendSlice(a, "<rect width='9' height='9'/>");
    for (0..100) |_| try ok.appendSlice(a, "</g>");
    try ok.appendSlice(a, "</svg>");
    var img = try svg.render(a, ok.items, 16, 16);
    img.deinit(a);
}

test "text and unsupported features do not break rendering" {
    const a = std.testing.allocator;
    const src = "<svg width='60' height='30'><text x='2' y='20' font-size='16'>Hi \u{1F600} \u{4e2d}</text><foreignObject width='5' height='5'/><animate attributeName='x'/><textPath/></svg>";
    var img = try svg.render(a, src, 60, 30);
    defer img.deinit(a);
    var any = false;
    for (img.frames[0].rgba) |b| any = any or b != 0;
    try std.testing.expect(any);
}

test "pathological dash array falls back to a solid stroke" {
    const a = std.testing.allocator;
    var img = try svg.render(a, "<svg width='20' height='10'><path d='M0 5H20' stroke='#f00' stroke-width='4' stroke-dasharray='0.0000001 0.0000001'/></svg>", 20, 10);
    defer img.deinit(a);
    try std.testing.expect(img.frames[0].rgba[(5 * 20 + 10) * 4 + 3] > 200);
}

test "crispEdges draws without partial coverage" {
    const a = std.testing.allocator;
    var img = try svg.render(a, "<svg width='10' height='4' shape-rendering='crispEdges'><rect x='1.3' y='0' width='4.6' height='4' fill='#000'/></svg>", 10, 4);
    defer img.deinit(a);
    var i: usize = 3;
    while (i < img.frames[0].rgba.len) : (i += 4) {
        const al = img.frames[0].rgba[i];
        try std.testing.expect(al == 0 or al == 255);
    }
}

test "alpha masks use coverage and luminance masks use brightness" {
    const a = std.testing.allocator;
    const alpha_svg = "<svg width='4' height='4'><mask id='m' mask-type='alpha' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4'><rect width='4' height='4' fill='#000' fill-opacity='.5'/></mask><rect width='4' height='4' fill='#f00' mask='url(#m)'/></svg>";
    var img = try svg.render(a, alpha_svg, 4, 4);
    defer img.deinit(a);
    try std.testing.expect(@abs(@as(i32, img.frames[0].rgba[3]) - 128) <= 2);
    var lum = try svg.render(a, "<svg width='4' height='4'><mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4'><rect width='4' height='4' fill='#000'/></mask><rect width='4' height='4' fill='#f00' mask='url(#m)'/></svg>", 4, 4);
    defer lum.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), lum.frames[0].rgba[3]);
}

fn pix(img: anytype, w: usize, x: usize, y: usize) [4]u8 {
    return img.frames[0].rgba[(y * w + x) * 4 ..][0..4].*;
}

fn near(a: u8, b: u8, tol: u8) bool {
    return @abs(@as(i32, a) - b) <= tol;
}

test "media queries match dark mode, supports and var and calc work" {
    const a = std.testing.allocator;
    var img = try svg.render(a, "<svg width='4' height='4'><style>rect{fill:#f00} @media (prefers-color-scheme: dark){rect{fill:#00f}} @media (prefers-color-scheme: light){rect{fill:#0f0}} @supports (-moz-appearance:auto){rect{fill:#ff0}}</style><rect width='4' height='4'/></svg>", 4, 4);
    defer img.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &pix(img, 4, 1, 1));
    var v = try svg.render(a, "<svg width='12' height='12'><style>svg{--c:#0f0;--w:calc(2 * 1px)} rect{fill:var(--c);stroke:var(--missing, #000);stroke-width:var(--w)}</style><rect x='2' y='2' width='8' height='8'/></svg>", 12, 12);
    defer v.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pix(v, 12, 5, 5));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &pix(v, 12, 2, 5));
    var c = try svg.render(a, "<svg width='10' height='2'><rect width='calc(100% - 4px)' height='2'/></svg>", 10, 2);
    defer c.deinit(a);
    try std.testing.expect(pix(c, 10, 5, 1)[3] == 255 and pix(c, 10, 7, 1)[3] == 0);
}

test "SMIL animations follow their timeline" {
    const a = std.testing.allocator;
    const src = "<svg width='10' height='2'><rect width='0' height='2' fill='#000'><animate attributeName='width' from='0' to='10' dur='10s' fill='freeze'/></rect></svg>";
    try std.testing.expect(svg.isAnimated(src));
    try std.testing.expect(!svg.isAnimated("<svg width='10' height='2'><rect width='4' height='2'/></svg>"));
    var t0 = try svg.render(a, src, 10, 2);
    defer t0.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), pix(t0, 10, 2, 1)[3]);
    var t5 = try svg.renderAt(a, src, 10, 2, 5000);
    defer t5.deinit(a);
    try std.testing.expect(pix(t5, 10, 2, 1)[3] == 255 and pix(t5, 10, 7, 1)[3] == 0);
    var t20 = try svg.renderAt(a, src, 10, 2, 20000);
    defer t20.deinit(a);
    try std.testing.expectEqual(@as(u8, 255), pix(t20, 10, 9, 1)[3]);
    const tf = "<svg width='10' height='4'><rect width='4' height='4'><animateTransform attributeName='transform' type='translate' values='0 0;6 0;6 0' keyTimes='0;0.5;1' dur='2s' repeatCount='indefinite'/></rect></svg>";
    var m = try svg.renderAt(a, tf, 10, 4, 3000);
    defer m.deinit(a);
    try std.testing.expect(pix(m, 10, 8, 1)[3] == 255 and pix(m, 10, 2, 1)[3] == 0);
}

test "CSS keyframes run their full timeline" {
    const a = std.testing.allocator;
    const src = "<svg width='4' height='4'><style>@keyframes k{from{opacity:0}to{opacity:1}} rect{animation:k 2s linear forwards}</style><rect width='4' height='4' fill='#000'/></svg>";
    try std.testing.expect(svg.isAnimated(src));
    var mid = try svg.renderAt(a, src, 4, 4, 1000);
    defer mid.deinit(a);
    try std.testing.expect(near(pix(mid, 4, 1, 1)[3], 128, 3));
    var end = try svg.renderAt(a, src, 4, 4, 5000);
    defer end.deinit(a);
    try std.testing.expectEqual(@as(u8, 255), pix(end, 4, 1, 1)[3]);
    var start = try svg.render(a, src, 4, 4);
    defer start.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), pix(start, 4, 1, 1)[3]);
}

test "blend modes, non-scaling strokes and CSS filter functions" {
    const a = std.testing.allocator;
    var b = try svg.render(a, "<svg width='2' height='2'><rect width='2' height='2' fill='#ff8000'/><rect width='2' height='2' fill='#80ff80' style='mix-blend-mode:multiply'/></svg>", 2, 2);
    defer b.deinit(a);
    const p = pix(b, 2, 0, 0);
    try std.testing.expect(near(p[0], 128, 3) and near(p[1], 128, 3) and near(p[2], 0, 3) and p[3] == 255);
    var n = try svg.render(a, "<svg width='20' height='6'><g transform='scale(10 10)'><path d='M0.2 0.3 H1.8' stroke='#000' stroke-width='1' vector-effect='non-scaling-stroke'/></g></svg>", 20, 6);
    defer n.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), pix(n, 20, 10, 0)[3]);
    try std.testing.expect(near(pix(n, 20, 10, 2)[3], 128, 4));
    var f = try svg.render(a, "<svg width='2' height='2'><rect width='2' height='2' fill='#000' style='filter:invert(1)'/></svg>", 2, 2);
    defer f.deinit(a);
    const q = pix(f, 2, 0, 0);
    try std.testing.expect(near(q[0], 255, 2) and near(q[1], 255, 2) and near(q[3], 255, 1));
}

test "tile, image, lighting and displacement primitives render" {
    const a = std.testing.allocator;
    const src = "<svg width='24' height='24'><defs><rect id='r' width='4' height='4' fill='#f00'/>" ++
        "<filter id='t' x='0' y='0' width='1' height='1'><feFlood flood-color='#00f' x='0' y='0' width='4' height='4'/><feTile/></filter>" ++
        "<filter id='i' x='0' y='0' width='1' height='1'><feImage href='#r'/></filter>" ++
        "<filter id='l' x='0' y='0' width='1' height='1'><feSpecularLighting surfaceScale='4' specularConstant='1' specularExponent='10' lighting-color='#fff'><fePointLight x='8' y='8' z='20'/></feSpecularLighting></filter></defs>" ++
        "<rect width='12' height='12' filter='url(#t)'/><rect x='12' width='12' height='12' filter='url(#i)'/><circle cx='12' cy='18' r='5' filter='url(#l)'/></svg>";
    var img = try svg.render(a, src, 24, 24);
    defer img.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &pix(img, 24, 9, 9));
}

test "CSS geometry properties override attributes" {
    const a = std.testing.allocator;
    var r = try svg.render(a, "<svg width='10' height='4'><style>rect{width:calc(100% - 4px);height:4px;x:2px}</style><rect width='1' height='1'/></svg>", 10, 4);
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), pix(r, 10, 1, 1)[3]);
    try std.testing.expectEqual(@as(u8, 255), pix(r, 10, 5, 1)[3]);
    try std.testing.expectEqual(@as(u8, 0), pix(r, 10, 9, 1)[3]);
    var c = try svg.render(a, "<svg width='10' height='10'><style>circle{cx:5px;cy:5px;r:4px} path{d:path(\"M0 0H3V3H0z\")}</style><circle/><path d='M9 9h1v1z'/></svg>", 10, 10);
    defer c.deinit(a);
    try std.testing.expectEqual(@as(u8, 255), pix(c, 10, 5, 5)[3]);
    try std.testing.expectEqual(@as(u8, 255), pix(c, 10, 1, 1)[3]);
    try std.testing.expectEqual(@as(u8, 0), pix(c, 10, 9, 9)[3]);
}

test "filters see content past the image edge" {
    const a = std.testing.allocator;
    var img = try svg.render(a, "<svg width='10' height='10'><filter id='f' filterUnits='userSpaceOnUse' x='-20' y='-20' width='60' height='60'><feOffset dx='10' dy='0'/></filter><rect x='-8' y='2' width='6' height='4' fill='#000' filter='url(#f)'/></svg>", 10, 10);
    defer img.deinit(a);
    try std.testing.expectEqual(@as(u8, 255), pix(img, 10, 5, 3)[3]);
    try std.testing.expectEqual(@as(u8, 0), pix(img, 10, 0, 3)[3]);
}

test "paced animation spends time by distance" {
    const a = std.testing.allocator;
    const src = "<svg width='12' height='2'><rect width='0' height='2'><animate attributeName='width' values='0;10;12' dur='10s' calcMode='paced'/></rect></svg>";
    var img = try svg.renderAt(a, src, 12, 2, 5000);
    defer img.deinit(a);
    try std.testing.expectEqual(@as(u8, 255), pix(img, 12, 5, 1)[3]);
    try std.testing.expectEqual(@as(u8, 0), pix(img, 12, 7, 1)[3]);
}

test "event based begins stay idle in an image" {
    const a = std.testing.allocator;
    var img = try svg.renderAt(a, "<svg width='4' height='2'><rect width='0' height='2'><animate attributeName='width' to='4' dur='1s' begin='click' fill='freeze'/></rect></svg>", 4, 2, 5000);
    defer img.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), pix(img, 4, 1, 1)[3]);
}

fn expectBrotli(comptime br: []const u8, comptime raw: []const u8) !void {
    const a = std.testing.allocator;
    const got = try brotli.decode(a, testdata.file("images/svg/woff/" ++ br), 1 << 20);
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, testdata.file("images/svg/woff/" ++ raw), got);
}

test "brotli decodes dictionary text, stored blocks and font data" {
    try expectBrotli("text.br", "text.txt");
    try expectBrotli("rand.br", "rand.bin");
    try expectBrotli("noto_q5.br", "noto.ttf");
    try expectBrotli("noto_q11.br", "noto.ttf");
    try expectBrotli("noto_q9.br", "noto.ttf");
}

test "brotli rejects truncated and oversized streams" {
    const a = std.testing.allocator;
    const src = testdata.file("images/svg/woff/noto_q11.br");
    try std.testing.expectError(error.Invalid, brotli.decode(a, src[0 .. src.len / 2], 1 << 20));
    try std.testing.expectError(error.TooBig, brotli.decode(a, src, 1000));
}

fn expectSameFont(comptime name: []const u8) !void {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sfnt = try woff.toSfnt(arena.allocator(), testdata.file("images/svg/woff/" ++ name));
    const want = try font.Font.init(testdata.file("images/svg/woff/noto.ttf"), 0);
    const got = try font.Font.init(sfnt, 0);
    try std.testing.expectEqual(want.num_glyphs, got.num_glyphs);
    var checked: usize = 0;
    var gid: u16 = 0;
    while (gid < want.num_glyphs) : (gid += 1) {
        try std.testing.expectEqual(want.advance(gid), got.advance(gid));
        var pw: font.Path = .{};
        defer pw.deinit(a);
        var pg: font.Path = .{};
        defer pg.deinit(a);
        try want.outline(a, gid, .{}, &pw);
        try got.outline(a, gid, .{}, &pg);
        try std.testing.expectEqual(pw.segs.items.len, pg.segs.items.len);
        for (pw.segs.items, pg.segs.items) |x, y| try std.testing.expect(std.meta.eql(x, y));
        checked += pw.segs.items.len;
    }
    try std.testing.expect(checked > 100);
    try std.testing.expectEqual(want.glyphIndex('A'), got.glyphIndex('A'));
}

test "WOFF and WOFF2 fonts convert to the same glyphs as the TrueType original" {
    try expectSameFont("noto.woff");
    try expectSameFont("noto.woff2");
    try expectSameFont("noto_hmtx.woff2");
}

test "WOFF input is bounded" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const w2 = testdata.file("images/svg/woff/noto.woff2");
    try std.testing.expectError(error.Invalid, woff.toSfnt(arena.allocator(), w2[0 .. w2.len / 2]));
    try std.testing.expectError(error.Invalid, woff.toSfnt(arena.allocator(), "wOF2"));
    try std.testing.expectError(error.Invalid, woff.toSfnt(arena.allocator(), "wOFF\x00\x01\x00\x00"));
}
