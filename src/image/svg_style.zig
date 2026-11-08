const std = @import("std");
const raster = @import("svg_raster.zig");

pub const Color = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };

const named = [_]struct { []const u8, u24 }{
    .{ "aliceblue", 0xf0f8ff },            .{ "antiquewhite", 0xfaebd7 },       .{ "aqua", 0x00ffff },              .{ "aquamarine", 0x7fffd4 },
    .{ "azure", 0xf0ffff },                .{ "beige", 0xf5f5dc },              .{ "bisque", 0xffe4c4 },            .{ "black", 0x000000 },
    .{ "blanchedalmond", 0xffebcd },       .{ "blue", 0x0000ff },               .{ "blueviolet", 0x8a2be2 },        .{ "brown", 0xa52a2a },
    .{ "burlywood", 0xdeb887 },            .{ "cadetblue", 0x5f9ea0 },          .{ "chartreuse", 0x7fff00 },        .{ "chocolate", 0xd2691e },
    .{ "coral", 0xff7f50 },                .{ "cornflowerblue", 0x6495ed },     .{ "cornsilk", 0xfff8dc },          .{ "crimson", 0xdc143c },
    .{ "cyan", 0x00ffff },                 .{ "darkblue", 0x00008b },           .{ "darkcyan", 0x008b8b },          .{ "darkgoldenrod", 0xb8860b },
    .{ "darkgray", 0xa9a9a9 },             .{ "darkgreen", 0x006400 },          .{ "darkgrey", 0xa9a9a9 },          .{ "darkkhaki", 0xbdb76b },
    .{ "darkmagenta", 0x8b008b },          .{ "darkolivegreen", 0x556b2f },     .{ "darkorange", 0xff8c00 },        .{ "darkorchid", 0x9932cc },
    .{ "darkred", 0x8b0000 },              .{ "darksalmon", 0xe9967a },         .{ "darkseagreen", 0x8fbc8f },      .{ "darkslateblue", 0x483d8b },
    .{ "darkslategray", 0x2f4f4f },        .{ "darkslategrey", 0x2f4f4f },      .{ "darkturquoise", 0x00ced1 },     .{ "darkviolet", 0x9400d3 },
    .{ "deeppink", 0xff1493 },             .{ "deepskyblue", 0x00bfff },        .{ "dimgray", 0x696969 },           .{ "dimgrey", 0x696969 },
    .{ "dodgerblue", 0x1e90ff },           .{ "firebrick", 0xb22222 },          .{ "floralwhite", 0xfffaf0 },       .{ "forestgreen", 0x228b22 },
    .{ "fuchsia", 0xff00ff },              .{ "gainsboro", 0xdcdcdc },          .{ "ghostwhite", 0xf8f8ff },        .{ "gold", 0xffd700 },
    .{ "goldenrod", 0xdaa520 },            .{ "gray", 0x808080 },               .{ "green", 0x008000 },             .{ "greenyellow", 0xadff2f },
    .{ "grey", 0x808080 },                 .{ "honeydew", 0xf0fff0 },           .{ "hotpink", 0xff69b4 },           .{ "indianred", 0xcd5c5c },
    .{ "indigo", 0x4b0082 },               .{ "ivory", 0xfffff0 },              .{ "khaki", 0xf0e68c },             .{ "lavender", 0xe6e6fa },
    .{ "lavenderblush", 0xfff0f5 },        .{ "lawngreen", 0x7cfc00 },          .{ "lemonchiffon", 0xfffacd },      .{ "lightblue", 0xadd8e6 },
    .{ "lightcoral", 0xf08080 },           .{ "lightcyan", 0xe0ffff },          .{ "lightgoldenrodyellow", 0xfafad2 }, .{ "lightgray", 0xd3d3d3 },
    .{ "lightgreen", 0x90ee90 },           .{ "lightgrey", 0xd3d3d3 },          .{ "lightpink", 0xffb6c1 },         .{ "lightsalmon", 0xffa07a },
    .{ "lightseagreen", 0x20b2aa },        .{ "lightskyblue", 0x87cefa },       .{ "lightslategray", 0x778899 },    .{ "lightslategrey", 0x778899 },
    .{ "lightsteelblue", 0xb0c4de },       .{ "lightyellow", 0xffffe0 },        .{ "lime", 0x00ff00 },              .{ "limegreen", 0x32cd32 },
    .{ "linen", 0xfaf0e6 },                .{ "magenta", 0xff00ff },            .{ "maroon", 0x800000 },            .{ "mediumaquamarine", 0x66cdaa },
    .{ "mediumblue", 0x0000cd },           .{ "mediumorchid", 0xba55d3 },       .{ "mediumpurple", 0x9370db },      .{ "mediumseagreen", 0x3cb371 },
    .{ "mediumslateblue", 0x7b68ee },      .{ "mediumspringgreen", 0x00fa9a },  .{ "mediumturquoise", 0x48d1cc },   .{ "mediumvioletred", 0xc71585 },
    .{ "midnightblue", 0x191970 },         .{ "mintcream", 0xf5fffa },          .{ "mistyrose", 0xffe4e1 },         .{ "moccasin", 0xffe4b5 },
    .{ "navajowhite", 0xffdead },          .{ "navy", 0x000080 },               .{ "oldlace", 0xfdf5e6 },           .{ "olive", 0x808000 },
    .{ "olivedrab", 0x6b8e23 },            .{ "orange", 0xffa500 },             .{ "orangered", 0xff4500 },         .{ "orchid", 0xda70d6 },
    .{ "palegoldenrod", 0xeee8aa },        .{ "palegreen", 0x98fb98 },          .{ "paleturquoise", 0xafeeee },     .{ "palevioletred", 0xdb7093 },
    .{ "papayawhip", 0xffefd5 },           .{ "peachpuff", 0xffdab9 },          .{ "peru", 0xcd853f },              .{ "pink", 0xffc0cb },
    .{ "plum", 0xdda0dd },                 .{ "powderblue", 0xb0e0e6 },         .{ "purple", 0x800080 },            .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xff0000 },                  .{ "rosybrown", 0xbc8f8f },          .{ "royalblue", 0x4169e1 },         .{ "saddlebrown", 0x8b4513 },
    .{ "salmon", 0xfa8072 },               .{ "sandybrown", 0xf4a460 },         .{ "seagreen", 0x2e8b57 },          .{ "seashell", 0xfff5ee },
    .{ "sienna", 0xa0522d },               .{ "silver", 0xc0c0c0 },             .{ "skyblue", 0x87ceeb },           .{ "slateblue", 0x6a5acd },
    .{ "slategray", 0x708090 },            .{ "slategrey", 0x708090 },          .{ "snow", 0xfffafa },              .{ "springgreen", 0x00ff7f },
    .{ "steelblue", 0x4682b4 },            .{ "tan", 0xd2b48c },                .{ "teal", 0x008080 },              .{ "thistle", 0xd8bfd8 },
    .{ "tomato", 0xff6347 },               .{ "turquoise", 0x40e0d0 },          .{ "violet", 0xee82ee },            .{ "wheat", 0xf5deb3 },
    .{ "white", 0xffffff },                .{ "whitesmoke", 0xf5f5f5 },         .{ "yellow", 0xffff00 },            .{ "yellowgreen", 0x9acd32 },
};

fn rgb8(v: u24) Color {
    return .{
        .r = @as(f32, @floatFromInt(v >> 16)) / 255,
        .g = @as(f32, @floatFromInt((v >> 8) & 255)) / 255,
        .b = @as(f32, @floatFromInt(v & 255)) / 255,
    };
}

fn hex(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

fn hue(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

pub fn parseColor(str: []const u8) ?Color {
    const s = std.mem.trim(u8, str, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') {
        const h = s[1..];
        var v: [8]u8 = undefined;
        if (h.len != 3 and h.len != 4 and h.len != 6 and h.len != 8) return null;
        for (h, 0..) |c, i| v[i] = hex(c) orelse return null;
        if (h.len <= 4) {
            return .{
                .r = @as(f32, @floatFromInt(v[0] * 17)) / 255,
                .g = @as(f32, @floatFromInt(v[1] * 17)) / 255,
                .b = @as(f32, @floatFromInt(v[2] * 17)) / 255,
                .a = if (h.len == 4) @as(f32, @floatFromInt(v[3] * 17)) / 255 else 1,
            };
        }
        return .{
            .r = @as(f32, @floatFromInt(v[0] * 16 + v[1])) / 255,
            .g = @as(f32, @floatFromInt(v[2] * 16 + v[3])) / 255,
            .b = @as(f32, @floatFromInt(v[4] * 16 + v[5])) / 255,
            .a = if (h.len == 8) @as(f32, @floatFromInt(v[6] * 16 + v[7])) / 255 else 1,
        };
    }
    if (s.len > 4 and s[s.len - 1] == ')') {
        const open = std.mem.indexOfScalar(u8, s, '(') orelse return null;
        const fname = std.mem.trim(u8, s[0..open], " ");
        const is_rgb = std.ascii.eqlIgnoreCase(fname, "rgb") or std.ascii.eqlIgnoreCase(fname, "rgba");
        const is_hsl = std.ascii.eqlIgnoreCase(fname, "hsl") or std.ascii.eqlIgnoreCase(fname, "hsla");
        if (!is_rgb and !is_hsl) return null;
        var vals: [4]f32 = .{ 0, 0, 0, 1 };
        var pct: [4]bool = .{ false, false, false, false };
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, s[open + 1 .. s.len - 1], ", /\t");
        while (it.next()) |tok| {
            if (n >= 4) return null;
            var t = tok;
            if (t.len > 0 and t[t.len - 1] == '%') {
                pct[n] = true;
                t = t[0 .. t.len - 1];
            }
            if (std.mem.endsWith(u8, t, "deg")) t = t[0 .. t.len - 3];
            vals[n] = std.fmt.parseFloat(f32, t) catch return null;
            n += 1;
        }
        if (n < 3) return null;
        if (pct[3]) vals[3] /= 100;
        const alpha = std.math.clamp(vals[3], 0, 1);
        if (is_rgb) {
            var c: Color = .{ .a = alpha };
            const out = [3]*f32{ &c.r, &c.g, &c.b };
            for (out, 0..) |o, i| o.* = std.math.clamp(if (pct[i]) vals[i] / 100 else vals[i] / 255, 0, 1);
            return c;
        }
        const h = @mod(vals[0], 360) / 360;
        const sat = std.math.clamp(vals[1] / 100, 0, 1);
        const l = std.math.clamp(vals[2] / 100, 0, 1);
        const q = if (l < 0.5) l * (1 + sat) else l + sat - l * sat;
        const p = 2 * l - q;
        return .{ .r = hue(p, q, h + 1.0 / 3.0), .g = hue(p, q, h), .b = hue(p, q, h - 1.0 / 3.0), .a = alpha };
    }
    if (std.ascii.eqlIgnoreCase(s, "transparent")) return .{ .a = 0 };
    var lower: [24]u8 = undefined;
    if (s.len > lower.len) return null;
    for (s, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    for (named) |nm| if (std.mem.eql(u8, nm[0], lower[0..s.len])) return rgb8(nm[1]);
    return null;
}

pub const Unit = enum { none, px, pt, pc, mm, cm, in, em, ex, pct };

pub const Len = struct { v: f64, unit: Unit };

pub fn parseLen(str: []const u8) ?Len {
    const s = std.mem.trim(u8, str, " \t\r\n");
    var sc: raster.NumScan = .{ .s = s };
    const v = sc.number() orelse return null;
    const rest = std.mem.trim(u8, s[sc.i..], " ");
    const unit: Unit = if (rest.len == 0) .none else if (std.mem.eql(u8, rest, "px")) .px else if (std.mem.eql(u8, rest, "pt")) .pt else if (std.mem.eql(u8, rest, "pc")) .pc else if (std.mem.eql(u8, rest, "mm")) .mm else if (std.mem.eql(u8, rest, "cm")) .cm else if (std.mem.eql(u8, rest, "in")) .in else if (std.mem.eql(u8, rest, "em")) .em else if (std.mem.eql(u8, rest, "ex")) .ex else if (std.mem.eql(u8, rest, "%")) .pct else return null;
    return .{ .v = v, .unit = unit };
}

pub const LenCtx = struct { font_size: f64 = 16, vw: f64 = 100, vh: f64 = 100 };

pub const Axis = enum { x, y, diag };

pub fn resolveLen(l: Len, axis: Axis, cx: LenCtx) f64 {
    return switch (l.unit) {
        .none, .px => l.v,
        .pt => l.v * 4.0 / 3.0,
        .pc => l.v * 16,
        .mm => l.v * 96 / 25.4,
        .cm => l.v * 96 / 2.54,
        .in => l.v * 96,
        .em => l.v * cx.font_size,
        .ex => l.v * cx.font_size * 0.5,
        .pct => l.v / 100 * switch (axis) {
            .x => cx.vw,
            .y => cx.vh,
            .diag => @sqrt((cx.vw * cx.vw + cx.vh * cx.vh) / 2),
        },
    };
}

pub fn lenOr(str: ?[]const u8, axis: Axis, cx: LenCtx, def: f64) f64 {
    const sv = str orelse return def;
    if (isMathFn(sv)) return if (calcValue(sv, axis, cx)) |r| r.n else def;
    const l = parseLen(sv) orelse return def;
    return resolveLen(l, axis, cx);
}

pub const Fallback = union(enum) { none, current, color: Color };

pub const Paint = union(enum) {
    none,
    current,
    color: Color,
    url: struct { id: []const u8, fb: ?Fallback },
};

pub fn parseUrlRef(s: []const u8) ?struct { id: []const u8, rest: []const u8 } {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "url(")) return null;
    const close = std.mem.indexOfScalar(u8, t, ')') orelse return null;
    var inner = std.mem.trim(u8, t[4..close], " \t\"'");
    if (inner.len == 0 or inner[0] != '#') return null;
    inner = inner[1..];
    return .{ .id = inner, .rest = std.mem.trim(u8, t[close + 1 ..], " \t\r\n") };
}

pub fn parsePaint(str: []const u8) ?Paint {
    const s = std.mem.trim(u8, str, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(s, "currentcolor")) return .current;
    if (parseUrlRef(s)) |u| {
        var fb: ?Fallback = null;
        if (u.rest.len > 0) {
            if (std.ascii.eqlIgnoreCase(u.rest, "none")) {
                fb = .none;
            } else if (std.ascii.eqlIgnoreCase(u.rest, "currentcolor")) {
                fb = .current;
            } else if (parseColor(u.rest)) |c| fb = .{ .color = c };
        }
        return .{ .url = .{ .id = u.id, .fb = fb } };
    }
    if (parseColor(s)) |c| return .{ .color = c };
    return null;
}

pub const Anchor = enum { start, middle, end };

pub const Var = struct { name: []const u8, value: []const u8 };

pub const Blend = enum { normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, hue, saturation, color, luminosity };

pub const Timing = union(enum) { cubic: [4]f64, steps: struct { n: u32, start: bool } };

pub const CssAnim = struct {
    name: []const u8 = "",
    dur_ms: f64 = 0,
    delay_ms: f64 = 0,
    count: f64 = 1,
    reverse: bool = false,
    alternate: bool = false,
    backwards: bool = false,
    forwards: bool = false,
    paused: bool = false,
    timing: Timing = .{ .cubic = .{ 0.25, 0.1, 0.25, 1 } },
};

pub const Style = struct {
    fill: Paint = .{ .color = .{} },
    fill_opacity: f32 = 1,
    fill_rule: raster.FillRule = .nonzero,
    clip_rule: raster.FillRule = .nonzero,
    stroke: Paint = .none,
    stroke_opacity: f32 = 1,
    stroke_width: f64 = 1,
    cap: raster.Cap = .butt,
    join: raster.Join = .miter,
    miter_limit: f64 = 4,
    dashes: []const f64 = &.{},
    dash_offset: f64 = 0,
    color: Color = .{},
    visible: bool = true,
    font_size: f64 = 16,
    weight: u16 = 400,
    italic: bool = false,
    font_family: []const u8 = "serif",
    text_align: u8 = 0,
    line_height: f64 = 0,
    anchor: Anchor = .start,
    letter_spacing: f64 = 0,
    word_spacing: f64 = 0,
    underline: bool = false,
    line_through: bool = false,
    stroke_first: bool = false,
    marker_start: []const u8 = "",
    marker_mid: []const u8 = "",
    marker_end: []const u8 = "",
    opacity: f32 = 1,
    display: bool = true,
    overflow_visible: bool = false,
    clip_path: []const u8 = "",
    mask: []const u8 = "",
    filter: []const u8 = "",
    stop_color: Color = .{},
    stop_opacity: f32 = 1,
    flood_color: Color = .{},
    flood_opacity: f32 = 1,
    lighting_color: Color = .{ .r = 1, .g = 1, .b = 1 },
    baseline: []const u8 = "",
    baseline_shift: []const u8 = "",
    transform: ?[]const u8 = null,
    linear_filters: bool = true,
    crisp: bool = false,
    anims: []const CssAnim = &.{},
    vars: []const Var = &.{},
    blend: Blend = .normal,
    isolate: bool = false,
    non_scaling: bool = false,
    transform_origin: []const u8 = "",
    transform_box: []const u8 = "",

    pub fn inherit(p: Style) Style {
        var s = p;
        const d: Style = .{};
        s.opacity = d.opacity;
        s.display = d.display;
        s.overflow_visible = d.overflow_visible;
        s.clip_path = d.clip_path;
        s.mask = d.mask;
        s.filter = d.filter;
        s.stop_color = d.stop_color;
        s.stop_opacity = d.stop_opacity;
        s.flood_color = d.flood_color;
        s.flood_opacity = d.flood_opacity;
        s.lighting_color = d.lighting_color;
        s.baseline = d.baseline;
        s.baseline_shift = d.baseline_shift;
        s.transform = null;
        s.anims = d.anims;
        s.blend = d.blend;
        s.isolate = d.isolate;
        s.non_scaling = d.non_scaling;
        s.transform_origin = d.transform_origin;
        s.transform_box = d.transform_box;
        return s;
    }
};

fn blendOf(v: []const u8) Blend {
    const names = [_]struct { []const u8, Blend }{
        .{ "multiply", .multiply },       .{ "screen", .screen },         .{ "overlay", .overlay },       .{ "darken", .darken },
        .{ "lighten", .lighten },         .{ "color-dodge", .color_dodge }, .{ "color-burn", .color_burn }, .{ "hard-light", .hard_light },
        .{ "soft-light", .soft_light },   .{ "difference", .difference }, .{ "exclusion", .exclusion },   .{ "hue", .hue },
        .{ "saturation", .saturation },   .{ "color", .color },           .{ "luminosity", .luminosity },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], v)) return n[1];
    return .normal;
}

fn splitTop(arena: std.mem.Allocator, v: []const u8, sep: u8) std.mem.Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: u32 = 0;
    var st: usize = 0;
    for (v, 0..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        const is_sep = if (sep == ' ') (c == ' ' or c == '\t' or c == '\n') else c == sep;
        if (is_sep and depth == 0) {
            if (i > st) try out.append(arena, std.mem.trim(u8, v[st..i], " \t\r\n"));
            st = i + 1;
        }
    }
    if (st < v.len) try out.append(arena, std.mem.trim(u8, v[st..], " \t\r\n"));
    return out.items;
}

fn parseTime(t: []const u8) ?f64 {
    if (std.mem.endsWith(u8, t, "ms")) return std.fmt.parseFloat(f64, t[0 .. t.len - 2]) catch null;
    if (std.mem.endsWith(u8, t, "s")) return (std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch return null) * 1000;
    return null;
}

pub fn parseTiming(t: []const u8) ?Timing {
    const eq = std.mem.eql;
    if (eq(u8, t, "ease")) return .{ .cubic = .{ 0.25, 0.1, 0.25, 1 } };
    if (eq(u8, t, "linear")) return .{ .cubic = .{ 0, 0, 1, 1 } };
    if (eq(u8, t, "ease-in")) return .{ .cubic = .{ 0.42, 0, 1, 1 } };
    if (eq(u8, t, "ease-out")) return .{ .cubic = .{ 0, 0, 0.58, 1 } };
    if (eq(u8, t, "ease-in-out")) return .{ .cubic = .{ 0.42, 0, 0.58, 1 } };
    if (eq(u8, t, "step-start")) return .{ .steps = .{ .n = 1, .start = true } };
    if (eq(u8, t, "step-end")) return .{ .steps = .{ .n = 1, .start = false } };
    const open = std.mem.indexOfScalar(u8, t, '(') orelse return null;
    if (t[t.len - 1] != ')') return null;
    const args = t[open + 1 .. t.len - 1];
    var sc: raster.NumScan = .{ .s = args };
    if (std.mem.startsWith(u8, t, "cubic-bezier")) {
        var c: [4]f64 = .{ 0, 0, 0, 0 };
        for (&c) |*x| x.* = sc.number() orelse return null;
        return .{ .cubic = c };
    }
    if (std.mem.startsWith(u8, t, "steps")) {
        const n = sc.number() orelse return null;
        if (n < 1) return null;
        return .{ .steps = .{ .n = @intFromFloat(@min(n, 1000)), .start = std.mem.indexOf(u8, args, "start") != null } };
    }
    return null;
}

fn animDefaultAt(list: *std.ArrayList(CssAnim), arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!*CssAnim {
    while (list.items.len <= i) try list.append(arena, .{});
    return &list.items[i];
}

fn applyAnimation(arena: std.mem.Allocator, s: *Style, name: []const u8, v: []const u8) std.mem.Allocator.Error!void {
    const eq = std.mem.eql;
    var list: std.ArrayList(CssAnim) = .empty;
    try list.appendSlice(arena, s.anims);
    const parts = try splitTop(arena, v, ',');
    if (eq(u8, name, "animation")) {
        list.clearRetainingCapacity();
        for (parts, 0..) |part, idx| {
            if (idx >= 8) break;
            const a = try animDefaultAt(&list, arena, idx);
            a.* = .{};
            var times: u32 = 0;
            for (try splitTop(arena, part, ' ')) |tok| {
                if (parseTime(tok)) |tm| {
                    if (times == 0) a.dur_ms = tm else a.delay_ms = tm;
                    times += 1;
                } else if (eq(u8, tok, "infinite")) {
                    a.count = std.math.inf(f64);
                } else if (std.fmt.parseFloat(f64, tok)) |n| {
                    a.count = n;
                } else |_| if (parseTiming(tok)) |tf| {
                    a.timing = tf;
                } else if (eq(u8, tok, "reverse") or eq(u8, tok, "alternate-reverse")) {
                    a.reverse = true;
                    a.alternate = tok[0] == 'a';
                } else if (eq(u8, tok, "alternate")) {
                    a.alternate = true;
                } else if (eq(u8, tok, "forwards")) {
                    a.forwards = true;
                } else if (eq(u8, tok, "backwards")) {
                    a.backwards = true;
                } else if (eq(u8, tok, "both")) {
                    a.forwards = true;
                    a.backwards = true;
                } else if (eq(u8, tok, "paused")) {
                    a.paused = true;
                } else if (eq(u8, tok, "normal") or eq(u8, tok, "running")) {
                    // defaults
                } else if (eq(u8, tok, "none")) {
                    a.name = "";
                } else a.name = tok;
            }
        }
        s.anims = list.items;
        return;
    }
    if (eq(u8, name, "animation-name")) {
        const old = list.items.len;
        _ = old;
        var renamed: std.ArrayList(CssAnim) = .empty;
        for (parts, 0..) |p, idx| {
            if (idx >= 8) break;
            var a: CssAnim = if (idx < list.items.len) list.items[idx] else .{};
            a.name = if (eq(u8, p, "none")) "" else p;
            try renamed.append(arena, a);
        }
        s.anims = renamed.items;
        return;
    }
    for (parts, 0..) |p, idx| {
        if (idx >= 8) break;
        const a = try animDefaultAt(&list, arena, idx);
        if (eq(u8, name, "animation-duration")) {
            a.dur_ms = parseTime(p) orelse 0;
        } else if (eq(u8, name, "animation-delay")) {
            a.delay_ms = parseTime(p) orelse 0;
        } else if (eq(u8, name, "animation-iteration-count")) {
            a.count = if (eq(u8, p, "infinite")) std.math.inf(f64) else (std.fmt.parseFloat(f64, p) catch 1);
        } else if (eq(u8, name, "animation-direction")) {
            a.reverse = std.mem.startsWith(u8, p, "reverse") or std.mem.endsWith(u8, p, "reverse");
            a.alternate = std.mem.startsWith(u8, p, "alternate");
            if (eq(u8, p, "reverse")) a.alternate = false;
            if (eq(u8, p, "alternate-reverse")) {
                a.alternate = true;
                a.reverse = true;
            }
        } else if (eq(u8, name, "animation-fill-mode")) {
            a.forwards = eq(u8, p, "forwards") or eq(u8, p, "both");
            a.backwards = eq(u8, p, "backwards") or eq(u8, p, "both");
        } else if (eq(u8, name, "animation-play-state")) {
            a.paused = eq(u8, p, "paused");
        } else if (eq(u8, name, "animation-timing-function")) {
            a.timing = parseTiming(p) orelse a.timing;
        }
    }
    s.anims = list.items;
}

/// Evaluates calc(), min(), max() and clamp() into a plain length or number.
const Calc = struct {
    s: []const u8,
    i: usize = 0,
    lc: LenCtx,
    axis: Axis,
    dim: bool = false,

    fn ws(c: *Calc) void {
        while (c.i < c.s.len and std.ascii.isWhitespace(c.s[c.i])) c.i += 1;
    }

    fn expr(c: *Calc) ?f64 {
        var v = c.term() orelse return null;
        while (true) {
            c.ws();
            if (c.i >= c.s.len) return v;
            const op = c.s[c.i];
            if (op != '+' and op != '-') return v;
            c.i += 1;
            const r = c.term() orelse return null;
            v = if (op == '+') v + r else v - r;
        }
    }

    fn term(c: *Calc) ?f64 {
        var v = c.factor() orelse return null;
        while (true) {
            c.ws();
            if (c.i >= c.s.len) return v;
            const op = c.s[c.i];
            if (op != '*' and op != '/') return v;
            c.i += 1;
            const r = c.factor() orelse return null;
            if (op == '*') {
                v *= r;
            } else {
                if (r == 0) return null;
                v /= r;
            }
        }
    }

    fn args(c: *Calc, out: *[8]f64) ?usize {
        var n: usize = 0;
        while (n < 8) {
            out[n] = c.expr() orelse return null;
            n += 1;
            c.ws();
            if (c.i < c.s.len and c.s[c.i] == ',') {
                c.i += 1;
                continue;
            }
            break;
        }
        c.ws();
        if (c.i >= c.s.len or c.s[c.i] != ')') return null;
        c.i += 1;
        return n;
    }

    fn factor(c: *Calc) ?f64 {
        c.ws();
        if (c.i >= c.s.len) return null;
        const ch = c.s[c.i];
        if (ch == '(') {
            c.i += 1;
            const v = c.expr() orelse return null;
            c.ws();
            if (c.i >= c.s.len or c.s[c.i] != ')') return null;
            c.i += 1;
            return v;
        }
        if (ch == '-' or ch == '+') {
            c.i += 1;
            const v = c.factor() orelse return null;
            return if (ch == '-') -v else v;
        }
        if (std.ascii.isAlphabetic(ch)) {
            const st = c.i;
            while (c.i < c.s.len and (std.ascii.isAlphabetic(c.s[c.i]) or c.s[c.i] == '-')) c.i += 1;
            const fname = c.s[st..c.i];
            c.ws();
            if (c.i >= c.s.len or c.s[c.i] != '(') return null;
            c.i += 1;
            if (std.mem.eql(u8, fname, "calc")) {
                const v = c.expr() orelse return null;
                c.ws();
                if (c.i >= c.s.len or c.s[c.i] != ')') return null;
                c.i += 1;
                return v;
            }
            var a: [8]f64 = @splat(0);
            const n = c.args(&a) orelse return null;
            if (std.mem.eql(u8, fname, "min")) {
                var m = a[0];
                for (a[1..n]) |x| m = @min(m, x);
                return m;
            }
            if (std.mem.eql(u8, fname, "max")) {
                var m = a[0];
                for (a[1..n]) |x| m = @max(m, x);
                return m;
            }
            if (std.mem.eql(u8, fname, "clamp") and n == 3) return @max(a[0], @min(a[1], a[2]));
            return null;
        }
        const nst = c.i;
        var sc: raster.NumScan = .{ .s = c.s, .i = c.i };
        const n = sc.number() orelse return null;
        c.i = sc.i;
        const ust = c.i;
        while (c.i < c.s.len and (std.ascii.isAlphabetic(c.s[c.i]) or c.s[c.i] == '%')) c.i += 1;
        if (c.i == ust) return n;
        const l = parseLen(c.s[nst..c.i]) orelse return null;
        c.dim = true;
        return resolveLen(l, c.axis, c.lc);
    }
};

pub fn isMathFn(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " ");
    return std.mem.startsWith(u8, t, "calc(") or std.mem.startsWith(u8, t, "min(") or std.mem.startsWith(u8, t, "max(") or std.mem.startsWith(u8, t, "clamp(");
}

pub fn calcValue(v: []const u8, axis: Axis, lc: LenCtx) ?struct { n: f64, dim: bool } {
    var c: Calc = .{ .s = std.mem.trim(u8, v, " \t\r\n"), .lc = lc, .axis = axis };
    const n = c.expr() orelse return null;
    c.ws();
    if (c.i != c.s.len or !std.math.isFinite(n)) return null;
    return .{ .n = n, .dim = c.dim };
}

fn findClose(v: []const u8, open: usize) ?usize {
    var depth: u32 = 0;
    var i = open;
    while (i < v.len) : (i += 1) {
        if (v[i] == '(') depth += 1;
        if (v[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn lookupVar(vars: []const Var, name: []const u8) ?[]const u8 {
    var i = vars.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, vars[i].name, name)) return vars[i].value;
    }
    return null;
}

/// Substitutes var() and evaluates calc(), min(), max() and clamp() inside a declaration value. Null means the declaration is invalid.
pub fn resolveValue(arena: std.mem.Allocator, v_in: []const u8, vars: []const Var, lc: LenCtx, depth: u32) std.mem.Allocator.Error!?[]const u8 {
    if (depth > 8) return null;
    var v = v_in;
    while (std.mem.indexOf(u8, v, "var(")) |at| {
        const open = at + 3;
        const close = findClose(v, open) orelse return null;
        const inner = v[open + 1 .. close];
        const comma = std.mem.indexOfScalar(u8, inner, ',');
        const nm = std.mem.trim(u8, if (comma) |c| inner[0..c] else inner, " ");
        const repl: []const u8 = if (lookupVar(vars, nm)) |val| val else if (comma) |c| std.mem.trim(u8, inner[c + 1 ..], " ") else return null;
        const resolved = (try resolveValue(arena, repl, vars, lc, depth + 1)) orelse return null;
        v = try std.mem.concat(arena, u8, &.{ v[0..at], resolved, v[close + 1 ..] });
    }
    var from: usize = 0;
    while (from < v.len) {
        var best: ?usize = null;
        for ([_][]const u8{ "calc(", "min(", "max(", "clamp(" }) |fname| {
            var pos = from;
            while (std.mem.indexOfPos(u8, v, pos, fname)) |p| {
                if (p == 0 or !(std.ascii.isAlphanumeric(v[p - 1]) or v[p - 1] == '-')) {
                    if (best == null or p < best.?) best = p;
                    break;
                }
                pos = p + 1;
            }
        }
        const at = best orelse break;
        const open = std.mem.indexOfScalarPos(u8, v, at, '(').?;
        const close = findClose(v, open) orelse return null;
        const r = calcValue(v[at .. close + 1], .diag, lc) orelse return null;
        const text = try std.fmt.allocPrint(arena, "{d}{s}", .{ r.n, if (r.dim) "px" else "" });
        v = try std.mem.concat(arena, u8, &.{ v[0..at], text, v[close + 1 ..] });
        from = at + text.len;
    }
    return v;
}

fn opacityVal(v: []const u8) ?f32 {
    const t = std.mem.trim(u8, v, " ");
    if (t.len > 0 and t[t.len - 1] == '%') return @floatCast(std.math.clamp((std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch return null) / 100, 0, 1));
    return @floatCast(std.math.clamp(std.fmt.parseFloat(f64, t) catch return null, 0, 1));
}

fn colorOrCurrent(v: []const u8, cur: Color) ?Color {
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " "), "currentcolor")) return cur;
    return parseColor(v);
}

fn ruleVal(v: []const u8) ?raster.FillRule {
    const t = std.mem.trim(u8, v, " ");
    if (std.mem.eql(u8, t, "evenodd")) return .evenodd;
    if (std.mem.eql(u8, t, "nonzero")) return .nonzero;
    return null;
}

fn urlOrNone(v: []const u8) []const u8 {
    return if (parseUrlRef(v)) |u| u.id else "";
}

pub fn apply(arena: std.mem.Allocator, s: *Style, name: []const u8, value: []const u8, lc_in: LenCtx) std.mem.Allocator.Error!void {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.eql(u8, v, "inherit")) return;
    var lc = lc_in;
    lc.font_size = s.font_size;
    const eq = std.mem.eql;
    if (eq(u8, name, "fill")) {
        if (parsePaint(v)) |p| s.fill = p;
    } else if (eq(u8, name, "stroke")) {
        if (parsePaint(v)) |p| s.stroke = p;
    } else if (eq(u8, name, "fill-opacity")) {
        if (opacityVal(v)) |o| s.fill_opacity = o;
    } else if (eq(u8, name, "stroke-opacity")) {
        if (opacityVal(v)) |o| s.stroke_opacity = o;
    } else if (eq(u8, name, "opacity")) {
        if (opacityVal(v)) |o| s.opacity = o;
    } else if (eq(u8, name, "fill-rule")) {
        if (ruleVal(v)) |r| s.fill_rule = r;
    } else if (eq(u8, name, "clip-rule")) {
        if (ruleVal(v)) |r| s.clip_rule = r;
    } else if (eq(u8, name, "stroke-width")) {
        if (parseLen(v)) |l| s.stroke_width = resolveLen(l, .diag, lc);
    } else if (eq(u8, name, "stroke-linecap")) {
        if (eq(u8, v, "butt")) s.cap = .butt else if (eq(u8, v, "round")) s.cap = .round else if (eq(u8, v, "square")) s.cap = .square;
    } else if (eq(u8, name, "stroke-linejoin")) {
        if (eq(u8, v, "miter") or eq(u8, v, "miter-clip") or eq(u8, v, "arcs")) s.join = .miter else if (eq(u8, v, "round")) s.join = .round else if (eq(u8, v, "bevel")) s.join = .bevel;
    } else if (eq(u8, name, "stroke-miterlimit")) {
        if (std.fmt.parseFloat(f64, v)) |m| {
            if (m >= 1) s.miter_limit = m;
        } else |_| {}
    } else if (eq(u8, name, "stroke-dasharray")) {
        if (eq(u8, v, "none")) {
            s.dashes = &.{};
            return;
        }
        var list: std.ArrayList(f64) = .empty;
        var it = std.mem.tokenizeAny(u8, v, ", \t\r\n");
        var ok = true;
        while (it.next()) |tok| {
            const l = parseLen(tok) orelse {
                ok = false;
                break;
            };
            const d = resolveLen(l, .diag, lc);
            if (d < 0) ok = false;
            if (list.items.len < 64) try list.append(arena, d);
        }
        if (ok and list.items.len > 0) {
            if (list.items.len % 2 == 1) {
                const n = list.items.len;
                for (0..n) |i| if (list.items.len < 64) try list.append(arena, list.items[i]);
            }
            s.dashes = list.items;
        } else s.dashes = &.{};
    } else if (eq(u8, name, "stroke-dashoffset")) {
        if (parseLen(v)) |l| s.dash_offset = resolveLen(l, .diag, lc);
    } else if (eq(u8, name, "color")) {
        if (parseColor(v)) |c| s.color = c;
    } else if (eq(u8, name, "visibility")) {
        s.visible = !(eq(u8, v, "hidden") or eq(u8, v, "collapse"));
    } else if (eq(u8, name, "display")) {
        s.display = !eq(u8, v, "none");
    } else if (eq(u8, name, "overflow")) {
        s.overflow_visible = eq(u8, v, "visible") or eq(u8, v, "auto");
    } else if (eq(u8, name, "font-size")) {
        if (parseLen(v)) |l| {
            s.font_size = if (l.unit == .pct) l.v / 100 * s.font_size else resolveLen(l, .diag, lc);
        } else if (eq(u8, v, "smaller")) {
            s.font_size /= 1.2;
        } else if (eq(u8, v, "larger")) {
            s.font_size *= 1.2;
        } else if (eq(u8, v, "small")) {
            s.font_size = 13;
        } else if (eq(u8, v, "large")) {
            s.font_size = 18;
        } else if (eq(u8, v, "x-large")) {
            s.font_size = 24;
        } else if (eq(u8, v, "x-small")) {
            s.font_size = 10;
        } else if (eq(u8, v, "medium")) s.font_size = 16;
    } else if (eq(u8, name, "font-weight")) {
        if (eq(u8, v, "bold")) {
            s.weight = 700;
        } else if (eq(u8, v, "bolder")) {
            s.weight = if (s.weight < 400) 400 else if (s.weight < 600) 700 else 900;
        } else if (eq(u8, v, "normal")) {
            s.weight = 400;
        } else if (eq(u8, v, "lighter")) {
            s.weight = if (s.weight > 700) 700 else if (s.weight > 500) 400 else 100;
        } else if (std.fmt.parseInt(u16, v, 10)) |w| s.weight = std.math.clamp(w, 1, 1000) else |_| {}
    } else if (eq(u8, name, "font-family")) {
        s.font_family = v;
    } else if (eq(u8, name, "font-style")) {
        s.italic = eq(u8, v, "italic") or std.mem.startsWith(u8, v, "oblique");
    } else if (eq(u8, name, "font")) {
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        while (it.next()) |tok| {
            if (eq(u8, tok, "italic") or eq(u8, tok, "oblique")) s.italic = true;
            if (eq(u8, tok, "bold")) s.weight = 700;
            if (std.fmt.parseInt(u16, tok, 10)) |w| {
                if (w >= 100) s.weight = std.math.clamp(w, 1, 1000);
            } else |_| {}
            if (parseLen(std.mem.sliceTo(tok, '/'))) |l| {
                if (l.unit != .none) {
                    s.font_size = resolveLen(l, .diag, lc);
                    if (std.mem.indexOf(u8, v, tok)) |at| s.font_family = std.mem.trim(u8, v[at + tok.len ..], " ");
                    break;
                }
            }
        }
    } else if (eq(u8, name, "text-align")) {
        s.text_align = if (eq(u8, v, "center")) 1 else if (eq(u8, v, "right") or eq(u8, v, "end")) 2 else 0;
    } else if (eq(u8, name, "line-height")) {
        if (eq(u8, v, "normal")) {
            s.line_height = 0;
        } else if (parseLen(v)) |l| {
            s.line_height = if (l.unit == .none) -l.v else if (l.unit == .pct) -l.v / 100 else resolveLen(l, .diag, lc);
        }
    } else if (eq(u8, name, "text-anchor")) {
        if (eq(u8, v, "middle")) s.anchor = .middle else if (eq(u8, v, "end")) s.anchor = .end else if (eq(u8, v, "start")) s.anchor = .start;
    } else if (eq(u8, name, "letter-spacing")) {
        s.letter_spacing = if (parseLen(v)) |l| resolveLen(l, .diag, lc) else 0;
    } else if (eq(u8, name, "word-spacing")) {
        s.word_spacing = if (parseLen(v)) |l| resolveLen(l, .diag, lc) else 0;
    } else if (eq(u8, name, "text-decoration") or eq(u8, name, "text-decoration-line")) {
        s.underline = std.mem.indexOf(u8, v, "underline") != null;
        s.line_through = std.mem.indexOf(u8, v, "line-through") != null;
    } else if (eq(u8, name, "paint-order")) {
        s.stroke_first = std.mem.startsWith(u8, v, "stroke");
    } else if (eq(u8, name, "marker-start")) {
        s.marker_start = urlOrNone(v);
    } else if (eq(u8, name, "marker-mid")) {
        s.marker_mid = urlOrNone(v);
    } else if (eq(u8, name, "marker-end")) {
        s.marker_end = urlOrNone(v);
    } else if (eq(u8, name, "marker")) {
        s.marker_start = urlOrNone(v);
        s.marker_mid = s.marker_start;
        s.marker_end = s.marker_start;
    } else if (eq(u8, name, "clip-path")) {
        s.clip_path = urlOrNone(v);
    } else if (eq(u8, name, "mask")) {
        s.mask = urlOrNone(v);
    } else if (eq(u8, name, "filter")) {
        s.filter = if (eq(u8, v, "none")) "" else v;
    } else if (eq(u8, name, "stop-color")) {
        if (colorOrCurrent(v, s.color)) |c| s.stop_color = c;
    } else if (eq(u8, name, "stop-opacity")) {
        if (opacityVal(v)) |o| s.stop_opacity = o;
    } else if (eq(u8, name, "lighting-color")) {
        if (colorOrCurrent(v, s.color)) |c| s.lighting_color = c;
    } else if (eq(u8, name, "flood-color")) {
        if (colorOrCurrent(v, s.color)) |c| s.flood_color = c;
    } else if (eq(u8, name, "flood-opacity")) {
        if (opacityVal(v)) |o| s.flood_opacity = o;
    } else if (eq(u8, name, "dominant-baseline") or eq(u8, name, "alignment-baseline")) {
        s.baseline = v;
    } else if (eq(u8, name, "baseline-shift")) {
        s.baseline_shift = v;
    } else if (eq(u8, name, "transform")) {
        s.transform = v;
    } else if (eq(u8, name, "shape-rendering")) {
        s.crisp = eq(u8, v, "crispEdges") or eq(u8, v, "optimizeSpeed");
    } else if (eq(u8, name, "mix-blend-mode")) {
        s.blend = blendOf(v);
    } else if (eq(u8, name, "isolation")) {
        s.isolate = eq(u8, v, "isolate");
    } else if (eq(u8, name, "vector-effect")) {
        s.non_scaling = std.mem.indexOf(u8, v, "non-scaling-stroke") != null;
    } else if (eq(u8, name, "transform-origin")) {
        s.transform_origin = v;
    } else if (eq(u8, name, "transform-box")) {
        s.transform_box = v;
    } else if (std.mem.startsWith(u8, name, "animation")) {
        try applyAnimation(arena, s, name, v);
    } else if (eq(u8, name, "color-interpolation-filters")) {
        s.linear_filters = !eq(u8, v, "sRGB");
    }
}

pub const presentation_attrs = [_][]const u8{
    "fill",                "stroke",             "fill-opacity",    "stroke-opacity",   "opacity",         "fill-rule",
    "clip-rule",           "stroke-width",       "stroke-linecap",  "stroke-linejoin",  "stroke-miterlimit", "stroke-dasharray",
    "stroke-dashoffset",   "color",              "visibility",      "display",          "overflow",        "font-size",
    "font-weight",         "font-style",         "font-family",     "text-anchor",      "letter-spacing",  "word-spacing",
    "text-decoration",     "paint-order",        "marker-start",    "marker-mid",       "marker-end",      "clip-path",
    "mask",                "filter",             "stop-color",      "stop-opacity",     "flood-color",     "flood-opacity", "lighting-color",
    "dominant-baseline",   "alignment-baseline", "baseline-shift",  "color-interpolation-filters", "font", "shape-rendering", "mix-blend-mode", "isolation", "vector-effect", "transform-origin", "transform-box",
};

pub fn parseTransform(s: []const u8) ?raster.Mat {
    var m = raster.Mat.identity;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (std.ascii.isWhitespace(s[i]) or s[i] == ',')) i += 1;
        if (i >= s.len) break;
        const st = i;
        while (i < s.len and (std.ascii.isAlphabetic(s[i]))) i += 1;
        const fname = s[st..i];
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len or s[i] != '(' or fname.len == 0) return null;
        const close = std.mem.indexOfScalarPos(u8, s, i, ')') orelse return null;
        var args: [6]f64 = undefined;
        var n: usize = 0;
        var sc: raster.NumScan = .{ .s = s[i + 1 .. close] };
        while (sc.number()) |v| {
            if (n >= 6) return null;
            args[n] = v;
            n += 1;
            while (sc.i < sc.s.len and std.ascii.isAlphabetic(sc.s[sc.i])) sc.i += 1;
        }
        i = close + 1;
        const eq = std.mem.eql;
        const t: raster.Mat = if (eq(u8, fname, "matrix") and n == 6)
            .{ .a = args[0], .b = args[1], .c = args[2], .d = args[3], .e = args[4], .f = args[5] }
        else if (eq(u8, fname, "translate") and (n == 1 or n == 2))
            raster.Mat.translate(args[0], if (n == 2) args[1] else 0)
        else if (eq(u8, fname, "translateX") and n == 1)
            raster.Mat.translate(args[0], 0)
        else if (eq(u8, fname, "translateY") and n == 1)
            raster.Mat.translate(0, args[0])
        else if (eq(u8, fname, "scale") and (n == 1 or n == 2))
            raster.Mat.scale(args[0], if (n == 2) args[1] else args[0])
        else if (eq(u8, fname, "rotate") and (n == 1 or n == 3)) blk: {
            const a = args[0] * std.math.pi / 180.0;
            const r: raster.Mat = .{ .a = @cos(a), .b = @sin(a), .c = -@sin(a), .d = @cos(a) };
            if (n == 3) break :blk raster.Mat.translate(args[1], args[2]).mul(r).mul(raster.Mat.translate(-args[1], -args[2]));
            break :blk r;
        } else if (eq(u8, fname, "skewX") and n == 1)
            .{ .c = @tan(args[0] * std.math.pi / 180.0) }
        else if (eq(u8, fname, "skewY") and n == 1)
            .{ .b = @tan(args[0] * std.math.pi / 180.0) }
        else
            return null;
        m = m.mul(t);
    }
    return m;
}

test "colors" {
    try std.testing.expectEqual(@as(f32, 1), parseColor("#f00").?.r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), parseColor("rgba(0,0,0,.5)").?.a, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), parseColor("hsl(0 100% 50%)").?.r, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), parseColor("Transparent").?.a);
    try std.testing.expect(parseColor("notacolor") == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0x66) / 255, parseColor("rebeccapurple").?.r, 1e-6);
}

test "lengths and transforms" {
    const l = parseLen("1in").?;
    try std.testing.expectEqual(@as(f64, 96), resolveLen(l, .x, .{}));
    try std.testing.expectEqual(@as(f64, 50), resolveLen(parseLen("50%").?, .x, .{ .vw = 100 }));
    const m = parseTransform("translate(10 20) rotate(90) scale(2)").?;
    const p = m.apply(.{ .x = 1, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 10), p.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 22), p.y, 1e-9);
    try std.testing.expect(parseTransform("bogus(1)") == null);
}
