const std = @import("std");
const Allocator = std.mem.Allocator;
const numfmt = @import("../numfmt.zig");
const vars = @import("vars.zig");

pub const Err = vars.Err;
const V = vars.V;
const Vars = vars.Vars;

const keywords = std.StaticStringMap([]const u8).initComptime(.{
    .{ "aliceblue", "#f0f8ff" },         .{ "antiquewhite", "#faebd7" },         .{ "aqua", "#00ffff" },
    .{ "aquamarine", "#7fffd4" },        .{ "azure", "#f0ffff" },                .{ "beige", "#f5f5dc" },
    .{ "bisque", "#ffe4c4" },            .{ "black", "#000000" },                .{ "blanchedalmond", "#ffebcd" },
    .{ "blue", "#0000ff" },              .{ "blueviolet", "#8a2be2" },           .{ "brown", "#a52a2a" },
    .{ "burlywood", "#deb887" },         .{ "cadetblue", "#5f9ea0" },            .{ "chartreuse", "#7fff00" },
    .{ "chocolate", "#d2691e" },         .{ "coral", "#ff7f50" },                .{ "cornflowerblue", "#6495ed" },
    .{ "cornsilk", "#fff8dc" },          .{ "crimson", "#dc143c" },              .{ "cyanaqua", "#00ffff" },
    .{ "darkblue", "#00008b" },          .{ "darkcyan", "#008b8b" },             .{ "darkgoldenrod", "#b8860b" },
    .{ "darkgray", "#a9a9a9" },          .{ "darkgreen", "#006400" },            .{ "darkgrey", "#a9a9a9" },
    .{ "darkkhaki", "#bdb76b" },         .{ "darkmagenta", "#8b008b" },          .{ "darkolivegreen", "#556b2f" },
    .{ "darkorange", "#ff8c00" },        .{ "darkorchid", "#9932cc" },           .{ "darkred", "#8b0000" },
    .{ "darksalmon", "#e9967a" },        .{ "darkseagreen", "#8fbc8f" },         .{ "darkslateblue", "#483d8b" },
    .{ "darkslategray", "#2f4f4f" },     .{ "darkslategrey", "#2f4f4f" },        .{ "darkturquoise", "#00ced1" },
    .{ "darkviolet", "#9400d3" },        .{ "deeppink", "#ff1493" },             .{ "deepskyblue", "#00bfff" },
    .{ "dimgray", "#696969" },           .{ "dimgrey", "#696969" },              .{ "dodgerblue", "#1e90ff" },
    .{ "firebrick", "#b22222" },         .{ "floralwhite", "#fffaf0" },          .{ "forestgreen", "#228b22" },
    .{ "fuchsia", "#ff00ff" },           .{ "gainsboro", "#dcdcdc" },            .{ "ghostwhite", "#f8f8ff" },
    .{ "gold", "#ffd700" },              .{ "goldenrod", "#daa520" },            .{ "gray", "#808080" },
    .{ "green", "#008000" },             .{ "greenyellow", "#adff2f" },          .{ "grey", "#808080" },
    .{ "honeydew", "#f0fff0" },          .{ "hotpink", "#ff69b4" },              .{ "indianred", "#cd5c5c" },
    .{ "indigo", "#4b0082" },            .{ "ivory", "#fffff0" },                .{ "khaki", "#f0e68c" },
    .{ "lavender", "#e6e6fa" },          .{ "lavenderblush", "#fff0f5" },        .{ "lawngreen", "#7cfc00" },
    .{ "lemonchiffon", "#fffacd" },      .{ "lightblue", "#add8e6" },            .{ "lightcoral", "#f08080" },
    .{ "lightcyan", "#e0ffff" },         .{ "lightgoldenrodyellow", "#fafad2" }, .{ "lightgray", "#d3d3d3" },
    .{ "lightgreen", "#90ee90" },        .{ "lightgrey", "#d3d3d3" },            .{ "lightpink", "#ffb6c1" },
    .{ "lightsalmon", "#ffa07a" },       .{ "lightseagreen", "#20b2aa" },        .{ "lightskyblue", "#87cefa" },
    .{ "lightslategray", "#778899" },    .{ "lightslategrey", "#778899" },       .{ "lightsteelblue", "#b0c4de" },
    .{ "lightyellow", "#ffffe0" },       .{ "lime", "#00ff00" },                 .{ "limegreen", "#32cd32" },
    .{ "linen", "#faf0e6" },             .{ "magenta", "#ff00ff" },              .{ "maroon", "#800000" },
    .{ "mediumaquamarine", "#66cdaa" },  .{ "mediumblue", "#0000cd" },           .{ "mediumorchid", "#ba55d3" },
    .{ "mediumpurple", "#9370db" },      .{ "mediumseagreen", "#3cb371" },       .{ "mediumslateblue", "#7b68ee" },
    .{ "mediumspringgreen", "#00fa9a" }, .{ "mediumturquoise", "#48d1cc" },      .{ "mediumvioletred", "#c71585" },
    .{ "midnightblue", "#191970" },      .{ "mintcream", "#f5fffa" },            .{ "mistyrose", "#ffe4e1" },
    .{ "moccasin", "#ffe4b5" },          .{ "navajowhite", "#ffdead" },          .{ "navy", "#000080" },
    .{ "oldlace", "#fdf5e6" },           .{ "olive", "#808000" },                .{ "olivedrab", "#6b8e23" },
    .{ "orange", "#ffa500" },            .{ "orangered", "#ff4500" },            .{ "orchid", "#da70d6" },
    .{ "palegoldenrod", "#eee8aa" },     .{ "palegreen", "#98fb98" },            .{ "paleturquoise", "#afeeee" },
    .{ "palevioletred", "#db7093" },     .{ "papayawhip", "#ffefd5" },           .{ "peachpuff", "#ffdab9" },
    .{ "peru", "#cd853f" },              .{ "pink", "#ffc0cb" },                 .{ "plum", "#dda0dd" },
    .{ "powderblue", "#b0e0e6" },        .{ "purple", "#800080" },               .{ "rebeccapurple", "#663399" },
    .{ "red", "#ff0000" },               .{ "rosybrown", "#bc8f8f" },            .{ "royalblue", "#4169e1" },
    .{ "saddlebrown", "#8b4513" },       .{ "salmon", "#fa8072" },               .{ "sandybrown", "#f4a460" },
    .{ "seagreen", "#2e8b57" },          .{ "seashell", "#fff5ee" },             .{ "sienna", "#a0522d" },
    .{ "silver", "#c0c0c0" },            .{ "skyblue", "#87ceeb" },              .{ "slateblue", "#6a5acd" },
    .{ "slategray", "#708090" },         .{ "slategrey", "#708090" },            .{ "snow", "#fffafa" },
    .{ "springgreen", "#00ff7f" },       .{ "tan", "#d2b48c" },                  .{ "teal", "#008080" },
    .{ "thistle", "#d8bfd8" },           .{ "transparent", "#00000000" },        .{ "turquoise", "#40e0d0" },
    .{ "violet", "#ee82ee" },            .{ "wheat", "#f5deb3" },                .{ "white", "#ffffff" },
    .{ "whitesmoke", "#f5f5f5" },        .{ "yellow", "#ffff00" },               .{ "yellowgreen", "#9acd32" },
});

const Kind = enum { all, rgb, hsl };
const Channel = enum { r, g, b, h, s, l, a };

// Port of khroma's Channels: the getters convert lazily and the setters pin the colour model.
const Chan = struct {
    r: ?f64 = null,
    g: ?f64 = null,
    b: ?f64 = null,
    h: ?f64 = null,
    s: ?f64 = null,
    l: ?f64 = null,
    a: f64 = 1,
    kind: Kind = .all,
    changed: bool = false,
    color: ?[]const u8 = null,

    fn ensureHsl(c: *Chan) void {
        if (c.h == null) c.h = rgb2hsl(c, .h);
        if (c.s == null) c.s = rgb2hsl(c, .s);
        if (c.l == null) c.l = rgb2hsl(c, .l);
    }

    fn ensureRgb(c: *Chan) void {
        if (c.r == null) c.r = hsl2rgb(c, .r);
        if (c.g == null) c.g = hsl2rgb(c, .g);
        if (c.b == null) c.b = hsl2rgb(c, .b);
    }

    fn get(c: *Chan, ch: Channel) f64 {
        switch (ch) {
            .r, .g, .b => {
                const cur = switch (ch) {
                    .r => c.r,
                    .g => c.g,
                    else => c.b,
                };
                if (c.kind != .hsl) if (cur) |v| return v;
                c.ensureHsl();
                return hsl2rgb(c, ch);
            },
            .h, .s, .l => {
                const cur = switch (ch) {
                    .h => c.h,
                    .s => c.s,
                    else => c.l,
                };
                if (c.kind != .rgb) if (cur) |v| return v;
                c.ensureRgb();
                return rgb2hsl(c, ch);
            },
            .a => return c.a,
        }
    }

    fn set(c: *Chan, ch: Channel, v: f64) Err!void {
        if (ch != .a) {
            const want: Kind = switch (ch) {
                .r, .g, .b => .rgb,
                else => .hsl,
            };
            if (c.kind != .all and c.kind != want) return error.ChannelConflict;
            c.kind = want;
        }
        c.changed = true;
        switch (ch) {
            .r => c.r = v,
            .g => c.g = v,
            .b => c.b = v,
            .h => c.h = v,
            .s => c.s = v,
            .l => c.l = v,
            .a => c.a = v,
        }
    }
};

fn clamp(ch: Channel, v: f64) f64 {
    return switch (ch) {
        .r, .g, .b => if (v >= 255) 255 else if (v < 0) 0 else v,
        .h => @rem(v, 360),
        .s, .l => if (v >= 100) 100 else if (v < 0) 0 else v,
        .a => if (v >= 1) 1 else if (v < 0) 0 else v,
    };
}

fn hue2rgb(p: f64, q: f64, t0: f64) f64 {
    var t = t0;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn hsl2rgb(c: *const Chan, ch: Channel) f64 {
    const h0 = c.h orelse std.math.nan(f64);
    const s0 = c.s orelse std.math.nan(f64);
    const l0 = c.l orelse std.math.nan(f64);
    if (s0 == 0 or std.math.isNan(s0)) return l0 * 2.55;
    const h = h0 / 360;
    const s = s0 / 100;
    const l = l0 / 100;
    const q = if (l < 0.5) l * (1 + s) else (l + s) - (l * s);
    const p = 2 * l - q;
    return switch (ch) {
        .r => hue2rgb(p, q, h + 1.0 / 3.0) * 255,
        .g => hue2rgb(p, q, h) * 255,
        else => hue2rgb(p, q, h - 1.0 / 3.0) * 255,
    };
}

fn rgb2hsl(c: *const Chan, ch: Channel) f64 {
    const r = (c.r orelse 0) / 255;
    const g = (c.g orelse 0) / 255;
    const b = (c.b orelse 0) / 255;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const l = (max + min) / 2;
    if (ch == .l) return l * 100;
    if (max == min) return 0;
    const d = max - min;
    const s = if (l > 0.5) d / (2 - max - min) else d / (max + min);
    if (ch == .s) return s * 100;
    if (max == r) return ((g - b) / d + (if (g < b) @as(f64, 6) else 0)) * 60;
    if (max == g) return ((b - r) / d + 2) * 60;
    return ((r - g) / d + 4) * 60;
}

fn round10(x: f64) f64 {
    return numfmt.round(x * 10000000000) / 10000000000;
}

fn hexChannel(dec: u32, bits: u5, shift_units: i32, mask: u32) u32 {
    const sh: u5 = @intCast(@as(i32, bits) * shift_units);
    return (dec >> sh) & mask;
}

fn parseHex(color: []const u8) ?Chan {
    if (color.len < 4 or color[0] != '#') return null;
    const hex = color[1..];
    for (hex) |c| if (!std.ascii.isHex(c)) return null;
    if (!(hex.len == 3 or hex.len == 4 or hex.len == 6 or hex.len == 8)) return null;
    const dec = std.fmt.parseInt(u32, hex, 16) catch return null;
    const has_alpha = hex.len % 4 == 0;
    const full = hex.len > 4;
    const mult: f64 = if (full) 1 else 17;
    const bits: u5 = if (full) 8 else 4;
    const offset: i32 = if (has_alpha) 0 else -1;
    const mask: u32 = if (full) 255 else 15;
    return .{
        .r = @as(f64, @floatFromInt(hexChannel(dec, bits, offset + 3, mask))) * mult,
        .g = @as(f64, @floatFromInt(hexChannel(dec, bits, offset + 2, mask))) * mult,
        .b = @as(f64, @floatFromInt(hexChannel(dec, bits, offset + 1, mask))) * mult,
        .a = if (has_alpha) @as(f64, @floatFromInt(dec & mask)) * mult / 255 else 1,
        .color = color,
    };
}

const Scan = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(p: *Scan) void {
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
    }

    fn eat(p: *Scan, c: u8) bool {
        if (p.i < p.s.len and p.s[p.i] == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn digits(p: *Scan) usize {
        const st = p.i;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        return p.i - st;
    }

    fn number(p: *Scan, exp_sign: bool) ?[]const u8 {
        const st = p.i;
        _ = p.eat('-');
        if (p.digits() > 0) {
            const save = p.i;
            if (p.eat('.') and p.digits() == 0) p.i = save;
        } else {
            if (!p.eat('.') or p.digits() == 0) return null;
        }
        const save = p.i;
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            p.i += 1;
            if (exp_sign) _ = p.eat('-');
            if (p.digits() == 0) p.i = save;
        }
        return p.s[st..p.i];
    }

    // `\s*?(?:,|\s)\s*?`, or with a slash `\s*?(?:,|\/)\s*?`
    fn separator(p: *Scan, slash: bool) bool {
        const st = p.i;
        p.ws();
        const moved = p.i > st;
        if (p.eat(',') or (slash and p.eat('/'))) {
            p.ws();
            return true;
        }
        return !slash and moved;
    }

    fn alpha(p: *Scan, exp_sign: bool) f64 {
        const save = p.i;
        if (p.separator(true)) {
            _ = p.eat('+');
            if (p.number(exp_sign)) |n| {
                const v = parseF(n);
                return clamp(.a, if (p.eat('%')) v / 100 else v);
            }
        }
        p.i = save;
        return 1;
    }
};

fn parseF(s: []const u8) f64 {
    return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
}

fn parseRgb(color: []const u8) ?Chan {
    if (!std.ascii.startsWithIgnoreCase(color, "rgb")) return null;
    var p: Scan = .{ .s = color, .i = 3 };
    _ = p.eat('a') or p.eat('A');
    if (!p.eat('(')) return null;
    p.ws();
    var vals: [3]f64 = undefined;
    for (&vals, 0..) |*slot, k| {
        const n = p.number(false) orelse return null;
        const v = parseF(n);
        slot.* = clamp(.r, if (p.eat('%')) v * 2.55 else v);
        if (k < 2 and !p.separator(false)) return null;
    }
    const alpha = p.alpha(false);
    p.ws();
    if (!p.eat(')') or p.i != p.s.len) return null;
    return .{ .r = vals[0], .g = vals[1], .b = vals[2], .a = alpha, .color = color };
}

fn hueDeg(txt: []const u8) f64 {
    const grad = "grad";
    if (std.ascii.endsWithIgnoreCase(txt, grad)) return clamp(.h, parseF(txt[0 .. txt.len - grad.len]) * 0.9);
    if (std.ascii.endsWithIgnoreCase(txt, "rad")) return clamp(.h, parseF(txt[0 .. txt.len - 3]) * 180 / std.math.pi);
    if (std.ascii.endsWithIgnoreCase(txt, "turn")) return clamp(.h, parseF(txt[0 .. txt.len - 4]) * 360);
    if (std.ascii.endsWithIgnoreCase(txt, "deg")) return clamp(.h, parseF(txt[0 .. txt.len - 3]));
    return clamp(.h, parseF(txt));
}

fn parseHsl(color: []const u8) ?Chan {
    if (!std.ascii.startsWithIgnoreCase(color, "hsl")) return null;
    var p: Scan = .{ .s = color, .i = 3 };
    _ = p.eat('a') or p.eat('A');
    if (!p.eat('(')) return null;
    p.ws();
    const hue_start = p.i;
    _ = p.number(true) orelse return null;
    for ([_][]const u8{ "deg", "grad", "rad", "turn" }) |u| {
        if (std.ascii.startsWithIgnoreCase(color[p.i..], u)) {
            p.i += u.len;
            break;
        }
    }
    const hue_text = color[hue_start..p.i];
    if (!p.separator(false)) return null;
    const s_text = p.number(true) orelse return null;
    if (!p.eat('%') or !p.separator(false)) return null;
    const l_text = p.number(true) orelse return null;
    if (!p.eat('%')) return null;
    const alpha = p.alpha(true);
    p.ws();
    if (!p.eat(')') or p.i != p.s.len) return null;
    return .{
        .h = hueDeg(hue_text),
        .s = clamp(.s, parseF(s_text)),
        .l = clamp(.l, parseF(l_text)),
        .a = alpha,
        .color = color,
    };
}

/// The text of the last colour that failed to parse, for mermaid's `Unsupported color format` message.
pub threadlocal var bad_color: []const u8 = "";

fn parse(color: []const u8) Err!Chan {
    if (parseHex(color)) |c| return c;
    if (parseRgb(color)) |c| return c;
    if (parseHsl(color)) |c| return c;
    var lower_buf: [32]u8 = undefined;
    if (color.len <= lower_buf.len) {
        if (keywords.get(std.ascii.lowerString(&lower_buf, color))) |hex| return parseHex(hex).?;
    }
    bad_color = color;
    return error.InvalidColor;
}

fn r10(a: Allocator, x: f64) Allocator.Error![]const u8 {
    return numfmt.js(a, round10(x));
}

fn stringify(a: Allocator, c: *Chan) Err![]const u8 {
    if (!c.changed) if (c.color) |col| if (col.len > 0) return col;
    var out: std.ArrayList(u8) = .empty;
    if (c.kind == .hsl or c.r == null) {
        const h = try r10(a, c.get(.h));
        const s = try r10(a, c.get(.s));
        const l = try r10(a, c.get(.l));
        if (c.a < 1) {
            try out.print(a, "hsla({s}, {s}%, {s}%, {s})", .{ h, s, l, try numfmt.js(a, c.a) });
        } else {
            try out.print(a, "hsl({s}, {s}%, {s}%)", .{ h, s, l });
        }
        return out.items;
    }
    const whole = c.get(.r) == @trunc(c.get(.r)) and c.get(.g) == @trunc(c.get(.g)) and c.get(.b) == @trunc(c.get(.b));
    if (c.a < 1 or !whole) {
        const r = try r10(a, c.get(.r));
        const g = try r10(a, c.get(.g));
        const b = try r10(a, c.get(.b));
        if (c.a < 1) {
            try out.print(a, "rgba({s}, {s}, {s}, {s})", .{ r, g, b, try r10(a, c.a) });
        } else {
            try out.print(a, "rgb({s}, {s}, {s})", .{ r, g, b });
        }
        return out.items;
    }
    try out.print(a, "#{x:0>2}{x:0>2}{x:0>2}", .{
        @as(u32, @intFromFloat(numfmt.round(c.get(.r)))),
        @as(u32, @intFromFloat(numfmt.round(c.get(.g)))),
        @as(u32, @intFromFloat(numfmt.round(c.get(.b)))),
    });
    return out.items;
}

fn adjustChannel(a: Allocator, color: []const u8, ch: Channel, amount: f64) Err![]const u8 {
    var c = try parse(color);
    const cur = c.get(ch);
    const next = clamp(ch, cur + amount);
    if (cur != next) try c.set(ch, next);
    return stringify(a, &c);
}

pub const Adjust = struct { r: ?f64 = null, g: ?f64 = null, b: ?f64 = null, h: ?f64 = null, s: ?f64 = null, l: ?f64 = null, a: ?f64 = null };

fn text(v: V) Err![]const u8 {
    return switch (v) {
        .s => |s| s,
        else => error.InvalidColor,
    };
}

pub fn lighten(t: *Vars, color: V, amount: f64) Err!V {
    return .{ .s = try adjustChannel(t.a, try text(color), .l, amount) };
}

pub fn darken(t: *Vars, color: V, amount: f64) Err!V {
    return .{ .s = try adjustChannel(t.a, try text(color), .l, -amount) };
}

pub fn adjust(t: *Vars, color: V, d: Adjust) Err!V {
    const col = try text(color);
    var cur = try parse(col);
    var out = try parse(col);
    inline for (.{ .r, .g, .b, .h, .s, .l, .a }) |name| {
        if (@field(d, @tagName(name))) |amt| if (amt != 0 and !std.math.isNan(amt)) {
            try out.set(name, clamp(name, cur.get(name) + amt));
        };
    }
    return .{ .s = try stringify(t.a, &out) };
}

pub fn invert(t: *Vars, color: V) Err!V {
    const col = try text(color);
    var inv = try parse(col);
    try inv.set(.r, 255 - inv.get(.r));
    try inv.set(.g, 255 - inv.get(.g));
    try inv.set(.b, 255 - inv.get(.b));
    var orig = try parse(col);
    const alpha_delta = inv.get(.a) - orig.get(.a);
    // khroma's mix at weight 100
    const w1c: f64 = if (alpha_delta == -1) 1 else (1 + alpha_delta) / (1 + alpha_delta);
    const w1 = (w1c + 1) / 2;
    const w2 = 1 - w1;
    return rgbaValue(
        t,
        inv.get(.r) * w1 + orig.get(.r) * w2,
        inv.get(.g) * w1 + orig.get(.g) * w2,
        inv.get(.b) * w1 + orig.get(.b) * w2,
        inv.get(.a) + orig.get(.a) * 0,
    );
}

fn rgbaValue(t: *Vars, r: f64, g: f64, b: f64, a: f64) Err!V {
    var c: Chan = .{ .r = clamp(.r, r), .g = clamp(.g, g), .b = clamp(.b, b), .a = clamp(.a, a) };
    return .{ .s = try stringify(t.a, &c) };
}

pub fn rgba(t: *Vars, r: f64, g: f64, b: f64, a: f64) Err!V {
    return rgbaValue(t, r, g, b, a);
}

fn toLinear(c: f64) f64 {
    const n = c / 255;
    return if (c > 0.03928) std.math.pow(f64, (n + 0.055) / 1.055, 2.4) else n / 12.92;
}

pub fn isDark(color: V) Err!bool {
    var c = try parse(try text(color));
    const lum = round10(0.2126 * toLinear(c.get(.r)) + 0.7152 * toLinear(c.get(.g)) + 0.0722 * toLinear(c.get(.b)));
    return !(lum >= 0.5);
}

pub fn mkBorder(t: *Vars, col: V, dark_mode: V) Err!V {
    return adjust(t, col, .{ .s = -40, .l = if (dark_mode.truthy()) 10 else -10 });
}
