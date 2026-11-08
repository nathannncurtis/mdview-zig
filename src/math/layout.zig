const std = @import("std");
const font = @import("font");
const tree = @import("tree.zig");
const style_mod = @import("style.zig");

pub const Font = font.Font;
pub const Style = style_mod.Style;
pub const Node = tree.Node;
pub const Tree = tree.Tree;
const Class = tree.Class;
const Allocator = std.mem.Allocator;

pub const Glyph = struct { gid: u16, px: f32, face: *const Font };

pub const Placed = struct { x: f32, y: f32, box: Box };

pub const Kind = union(enum) {
    empty,
    glyph: Glyph,
    rule,
    group: []const Placed,
    color: struct { rgb: u32, child: *const Box },
};

pub const Box = struct {
    w: f32 = 0,
    h: f32 = 0,
    d: f32 = 0,
    ic: f32 = 0,
    accent_x: ?f32 = null,
    is_char: bool = false,
    kind: Kind = .empty,
};

pub const Options = struct {
    size: f32 = 16,
    display: bool = false,
    text_font: ?*const Font = null,
};

pub const max_depth = 100;
pub const max_nodes = 50_000;
pub const max_parts = 256;
pub const max_cells = 10_000;
pub const error_rgb: u32 = 0xCF222E;

pub const Error = error{ OutOfMemory, NoMathTable };

const Err = error{ OutOfMemory, TooComplex };

const Budget = struct { nodes: u32 = 0, depth: u32 = 0 };

const Ctx = struct {
    a: Allocator,
    f: *const Font,
    tf: *const Font,
    k: *const font.math.Constants,
    base: f32,
    style: Style,
    face: tree.Font = .default,
    budget: *Budget,

    fn size(c: Ctx) f32 {
        return c.base * c.style.scale(c.k.*);
    }

    fn with(c: Ctx, s: Style) Ctx {
        var n = c;
        n.style = s;
        return n;
    }

    fn u(c: Ctx, v: i16) f32 {
        return @as(f32, @floatFromInt(v)) * c.size() / @as(f32, @floatFromInt(c.f.upem));
    }

    fn axis(c: Ctx) f32 {
        return c.u(c.k.axis_height);
    }

    fn mu(c: Ctx) f32 {
        return c.size() / 18;
    }
};

const Builder = struct {
    a: Allocator,
    items: std.ArrayList(Placed) = .empty,
    w: f32 = 0,
    h: f32 = 0,
    d: f32 = 0,

    fn add(b: *Builder, x: f32, dy: f32, box: Box) Err!void {
        try b.items.append(b.a, .{ .x = x, .y = dy, .box = box });
        b.h = @max(b.h, box.h - dy);
        b.d = @max(b.d, box.d + dy);
        b.w = @max(b.w, x + box.w);
    }

    fn finish(b: *Builder) Box {
        return .{ .w = b.w, .h = b.h, .d = b.d, .kind = .{ .group = b.items.items } };
    }
};

fn styleFromCmd(cmd: tree.Style, cramped: bool) Style {
    const s: Style = switch (cmd) {
        .display => .d,
        .text => .t,
        .script => .s,
        .scriptscript => .ss,
    };
    return if (cramped) s.cramp() else s;
}

const spacing = [8][8]u8{
    .{ 0, 1, 6, 7, 0, 0, 0, 5 },
    .{ 1, 1, 0, 7, 0, 0, 0, 5 },
    .{ 6, 6, 0, 0, 6, 0, 0, 6 },
    .{ 7, 7, 0, 0, 7, 0, 0, 7 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 6, 7, 0, 0, 0, 5 },
    .{ 5, 5, 0, 5, 5, 5, 5, 5 },
    .{ 5, 1, 6, 7, 5, 0, 5, 5 },
};

pub fn spaceMu(prev: Class, cur: Class, script: bool) u8 {
    const code = spacing[@intFromEnum(prev)][@intFromEnum(cur)];
    if (code >= 4) return if (script) 0 else code - 4;
    return code;
}

const mu_amount = [_]f32{ 0, 3, 4, 5 };

const Alpha = enum { rm, it, bf, bfit, cal, bcal, frak, bfrak, bb, sf, sfbf, sfit, sfbfit, tt };

fn alphaOf(v: tree.Font, italic: bool) Alpha {
    return switch (v) {
        .default => if (italic) .it else .rm,
        .normal, .it => .it,
        .rm => .rm,
        .bf => .bf,
        .bfit => .bfit,
        .sf => .sf,
        .sfbf => .sfbf,
        .sfit => .sfit,
        .sfbfit => .sfbfit,
        .tt => .tt,
        .cal, .scr => .cal,
        .bfcal, .bfscr => .bcal,
        .frak => .frak,
        .bffrak => .bfrak,
        .bb => .bb,
        .bsym => if (italic) .bfit else .bf,
    };
}

fn digitBase(a: Alpha) ?u32 {
    return switch (a) {
        .bf, .bfit, .bcal, .bfrak => 0x1D7CE,
        .bb => 0x1D7D8,
        .sf, .sfit => 0x1D7E2,
        .sfbf, .sfbfit => 0x1D7EC,
        .tt => 0x1D7F6,
        else => null,
    };
}

fn latinBase(a: Alpha) ?[2]u32 {
    return switch (a) {
        .rm => null,
        .it => .{ 0x1D434, 0x1D44E },
        .bf => .{ 0x1D400, 0x1D41A },
        .bfit => .{ 0x1D468, 0x1D482 },
        .cal => .{ 0x1D49C, 0x1D4B6 },
        .bcal => .{ 0x1D4D0, 0x1D4EA },
        .frak => .{ 0x1D504, 0x1D51E },
        .bfrak => .{ 0x1D56C, 0x1D586 },
        .bb => .{ 0x1D538, 0x1D552 },
        .sf => .{ 0x1D5A0, 0x1D5BA },
        .sfbf => .{ 0x1D5D4, 0x1D5EE },
        .sfit => .{ 0x1D608, 0x1D622 },
        .sfbfit => .{ 0x1D63C, 0x1D656 },
        .tt => .{ 0x1D670, 0x1D68A },
    };
}

fn latinHole(cp: u32, a: Alpha) ?u32 {
    return switch (a) {
        .it => if (cp == 'h') 0x210E else null,
        .cal => switch (cp) {
            'B' => 0x212C,
            'E' => 0x2130,
            'F' => 0x2131,
            'H' => 0x210B,
            'I' => 0x2110,
            'L' => 0x2112,
            'M' => 0x2133,
            'R' => 0x211B,
            'e' => 0x212F,
            'g' => 0x210A,
            'o' => 0x2134,
            else => null,
        },
        .frak => switch (cp) {
            'C' => 0x212D,
            'H' => 0x210C,
            'I' => 0x2111,
            'R' => 0x211C,
            'Z' => 0x2128,
            else => null,
        },
        .bb => switch (cp) {
            'C' => 0x2102,
            'H' => 0x210D,
            'N' => 0x2115,
            'P' => 0x2119,
            'Q' => 0x211A,
            'R' => 0x211D,
            'Z' => 0x2124,
            else => null,
        },
        else => null,
    };
}

fn greekBase(a: Alpha) ?[2]u32 {
    return switch (a) {
        .it => .{ 0x1D6E2, 0x1D6FC },
        .bf => .{ 0x1D6A8, 0x1D6C2 },
        .bfit => .{ 0x1D71C, 0x1D736 },
        .sfbf => .{ 0x1D756, 0x1D770 },
        .sfbfit => .{ 0x1D790, 0x1D7AA },
        else => null,
    };
}

pub fn mapChar(cp: u32, v: tree.Font, italic: bool) u32 {
    const al = alphaOf(v, italic);
    if (cp >= '0' and cp <= '9') return if (digitBase(al)) |b| b + (cp - '0') else cp;
    const upper = cp >= 'A' and cp <= 'Z';
    const lower = cp >= 'a' and cp <= 'z';
    if (upper or lower) {
        const b = latinBase(al) orelse return cp;
        if (latinHole(cp, al)) |h| return h;
        return if (upper) b[0] + (cp - 'A') else b[1] + (cp - 'a');
    }
    if (cp >= 0x391 and cp <= 0x3A9) {
        const b = greekBase(al) orelse return cp;
        if (al == .it and v == .default) return cp;
        return b[0] + (cp - 0x391);
    }
    if (cp >= 0x3B1 and cp <= 0x3C9) {
        const b = greekBase(al) orelse return cp;
        return b[1] + (cp - 0x3B1);
    }
    return cp;
}

fn glyphBox(c: Ctx, gid: u16) Box {
    const px = c.size();
    const k = px / @as(f32, @floatFromInt(c.f.upem));
    var b: Box = .{ .w = @as(f32, @floatCast(c.f.advance(gid))) * k, .is_char = true, .kind = .{ .glyph = .{ .gid = gid, .px = px, .face = c.f } } };
    const bb = c.f.bbox(gid);
    b.h = @max(@as(f32, @floatFromInt(bb.y1)), 0) * k;
    b.d = @max(-@as(f32, @floatFromInt(bb.y0)), 0) * k;
    b.ic = @as(f32, @floatFromInt(c.f.italicCorrection(gid))) * k;
    b.accent_x = @as(f32, @floatFromInt(c.f.topAccent(gid))) * k;
    return b;
}

fn charBox(c: Ctx, cp: u32, v: tree.Font, italic: bool) Box {
    var gid = c.f.glyphFor(mapChar(cp, v, italic));
    if (gid == 0) gid = c.f.glyphFor(cp);
    return glyphBox(c, gid);
}

fn shifted(c: Ctx, b: Box, dy: f32) Err!Box {
    var bl: Builder = .{ .a = c.a };
    try bl.add(0, dy, b);
    var out = bl.finish();
    out.w = b.w;
    out.ic = b.ic;
    out.accent_x = b.accent_x;
    return out;
}

fn centerOnAxis(c: Ctx, b: Box) Err!Box {
    return shifted(c, b, (b.h - b.d) / 2 - c.axis());
}

fn rule(w: f32, h: f32) Box {
    return .{ .w = w, .h = h, .kind = .rule };
}

fn kern(w: f32) Box {
    return .{ .w = w };
}

fn variantSize(c: Ctx, advance: u16) f32 {
    return @as(f32, @floatFromInt(advance)) * c.base / @as(f32, @floatFromInt(c.f.upem));
}

fn assemble(c: Ctx, asm_: font.math.Assembly, vertical: bool, target: f32) Err!Box {
    const n = asm_.count;
    if (n == 0 or n > max_parts) return error.TooComplex;
    const k = c.base / @as(f32, @floatFromInt(c.f.upem));
    const o_min = @as(f32, @floatFromInt(c.f.math.?.min_connector_overlap)) * k;
    var n_ext: usize = 0;
    var sum_fixed: f32 = 0;
    var sum_ext: f32 = 0;
    for (0..n) |i| {
        const p = asm_.part(i) orelse return error.TooComplex;
        const adv = @as(f32, @floatFromInt(p.full_advance)) * k;
        if (p.extender) {
            n_ext += 1;
            sum_ext += adv;
        } else sum_fixed += adv;
    }
    var reps: usize = 1;
    if (n_ext > 0 and sum_ext > 0) {
        reps = 0;
        while (reps < max_parts) : (reps += 1) {
            const cnt = n - n_ext + n_ext * reps;
            if (cnt == 0) continue;
            const joints: f32 = @floatFromInt(cnt - 1);
            if (sum_fixed + sum_ext * @as(f32, @floatFromInt(reps)) - joints * o_min >= target) break;
        }
        if (reps == 0) reps = 1;
    }
    if (n - n_ext + n_ext * reps > max_parts) return error.TooComplex;

    var seq: std.ArrayList(font.math.Part) = .empty;
    for (0..n) |i| {
        const p = asm_.part(i) orelse return error.TooComplex;
        for (0..(if (p.extender) reps else 1)) |_| try seq.append(c.a, p);
    }
    var total: f32 = 0;
    var o_max: f32 = std.math.floatMax(f32);
    for (seq.items, 0..) |p, i| {
        total += @as(f32, @floatFromInt(p.full_advance)) * k;
        if (i + 1 < seq.items.len) {
            const lim = @min(p.end_connector, seq.items[i + 1].start_connector);
            o_max = @min(o_max, @as(f32, @floatFromInt(lim)) * k);
        }
    }
    const joints = seq.items.len -| 1;
    var ov: f32 = 0;
    if (joints > 0) ov = std.math.clamp((total - target) / @as(f32, @floatFromInt(joints)), o_min, @max(o_min, o_max));

    var bl: Builder = .{ .a = c.a };
    var cur: f32 = 0;
    for (seq.items) |p| {
        const g = glyphBox(c, p.gid);
        if (vertical) try bl.add(0, -(cur + g.d), g) else try bl.add(cur, 0, g);
        cur += @as(f32, @floatFromInt(p.full_advance)) * k - ov;
    }
    var out = bl.finish();
    if (vertical) {
        out.h = cur + ov;
        out.d = 0;
    } else out.w = cur + ov;
    return out;
}

fn stretch(c: Ctx, gid: u16, vertical: bool, target: f32) Err!Box {
    const vars = if (vertical) c.f.vertVariants(gid) else c.f.horizVariants(gid);
    var last: u16 = gid;
    var i: usize = 0;
    while (vars.get(i)) |v| : (i += 1) {
        last = v.gid;
        if (variantSize(c, v.advance) >= target) return glyphBox(c, v.gid);
    }
    if (c.f.assembly(gid, if (vertical) .vert else .horiz)) |a| return assemble(c, a, vertical, target);
    return glyphBox(c, last);
}

fn delimBox(c: Ctx, cp: ?u21, target: f32) Err!Box {
    const code = cp orelse return .{};
    const gid = c.f.glyphFor(code);
    if (gid == 0) return .{};
    return centerOnAxis(c, try stretch(c, gid, true, target));
}

fn horizGlyph(c: Ctx, cp: u21, target: f32) Err!Box {
    const gid = c.f.glyphFor(cp);
    if (gid == 0) return .{};
    return stretch(c, gid, false, target);
}

fn firstClass(body: []const Node) ?Class {
    if (body.len == 0) return .ord;
    return classOf(&body[0]);
}

fn classOf(n: *const Node) ?Class {
    return switch (n.*) {
        .atom => |a| a.class,
        .op => .op,
        .supsub => |s| classOf(s.base),
        .group => |g| g.class orelse .ord,
        .big => |b| b.class,
        .font => |x| firstClass(x.body),
        .color => |x| firstClass(x.body),
        .style => |x| firstClass(x.body),
        .size => |x| firstClass(x.body),
        .stack => |s| firstClass(s.base),
        .negate => |b| classOf(b),
        .xarrow => .rel,
        .space => null,
        else => .ord,
    };
}

fn layRow(c: Ctx, nodes: []const Node) Err!Box {
    if (nodes.len == 1) return layNode(c, &nodes[0]);
    var classes = try c.a.alloc(?Class, nodes.len);
    for (nodes, 0..) |*n, i| classes[i] = classOf(n);
    var prev: ?usize = null;
    for (0..nodes.len) |i| {
        const cl = classes[i] orelse continue;
        if (cl == .bin) {
            if (prev == null) classes[i] = .ord else switch (classes[prev.?].?) {
                .bin, .op, .rel, .open, .punct => classes[i] = .ord,
                else => {},
            }
        } else if (cl == .rel or cl == .close or cl == .punct) {
            if (prev) |p| if (classes[p].? == .bin) {
                classes[p] = .ord;
            };
        }
        prev = i;
    }
    if (prev) |p| if (classes[p].? == .bin) {
        classes[p] = .ord;
    };

    var bl: Builder = .{ .a = c.a };
    var x: f32 = 0;
    var last: ?Class = null;
    for (nodes, 0..) |*n, i| {
        const b = try layNode(c, n);
        if (classes[i]) |cl| {
            if (last) |l| x += mu_amount[spaceMu(l, cl, c.style.script())] * c.mu();
            last = cl;
        }
        try bl.add(x, 0, b);
        x += b.w;
    }
    var out = bl.finish();
    out.w = x;
    return out;
}

fn layLargeOp(c: Ctx, a: tree.Atom) Err!Box {
    var gid = c.f.glyphFor(a.cp);
    const vars = c.f.vertVariants(gid);
    if (c.style.display() and vars.count > 0) {
        const want = variantSize(c, @intCast(@max(c.k.display_operator_min_height, 0)));
        var i: usize = 0;
        while (vars.get(i)) |v| : (i += 1) {
            gid = v.gid;
            if (variantSize(c, v.advance) >= want) break;
        }
    }
    var b = glyphBox(c, gid);
    b.is_char = false;
    var out = try shifted(c, b, (b.h - b.d) / 2 - c.axis());
    out.ic = b.ic;
    return out;
}

fn layOp(c: Ctx, o: anytype) Err!Box {
    if (o.large and o.body.len == 1 and o.body[0] == .atom) return layLargeOp(c, o.body[0].atom);
    return layRow(c, o.body);
}

fn limits(c: Ctx, base: Box, up: ?Box, low: ?Box) Err!Box {
    const k = c.k;
    var w = base.w;
    if (up) |b| w = @max(w, b.w);
    if (low) |b| w = @max(w, b.w);
    const delta = base.ic;
    var bl: Builder = .{ .a = c.a };
    try bl.add((w - base.w) / 2, 0, base);
    if (up) |b| {
        const rise = @max(c.u(k.upper_limit_baseline_rise_min), base.h + c.u(k.upper_limit_gap_min) + b.d);
        try bl.add((w - b.w) / 2 + delta / 2, -rise, b);
    }
    if (low) |b| {
        const drop = @max(c.u(k.lower_limit_baseline_drop_min), base.d + c.u(k.lower_limit_gap_min) + b.h);
        try bl.add((w - b.w) / 2 - delta / 2, drop, b);
    }
    var out = bl.finish();
    out.w = w;
    return out;
}

fn laySupsub(c: Ctx, n: anytype) Err!Box {
    const x = try layNode(c, n.base);
    const sup_style = c.style.sup();
    const sub_style = c.style.sub();
    const sup: ?Box = if (n.sup) |s| try layRow(c.with(sup_style), s) else null;
    const sub: ?Box = if (n.sub) |s| try layRow(c.with(sub_style), s) else null;
    const on_limits = switch (n.limits) {
        .above => true,
        .display => c.style.display(),
        .side => false,
    };
    if (on_limits) return limits(c, x, sup, sub);
    const k = c.k;
    var u: f32 = 0;
    var v: f32 = 0;
    if (!x.is_char) {
        if (sup != null) u = x.h - c.with(sup_style).u(k.superscript_baseline_drop_max);
        if (sub != null) v = x.d + c.with(sub_style).u(k.subscript_baseline_drop_min);
    }
    const after = c.u(k.space_after_script);
    var bl: Builder = .{ .a = c.a };
    try bl.add(0, 0, x);
    var w = x.w;
    const delta = x.ic;
    const shift_up = c.u(if (c.style.cramped()) k.superscript_shift_up_cramped else k.superscript_shift_up);
    if (sup != null and sub == null) {
        const s = sup.?;
        u = @max(u, @max(shift_up, s.d + c.u(k.superscript_bottom_min)));
        try bl.add(x.w + delta, -u, s);
        w = x.w + delta + s.w + after;
    } else if (sub != null and sup == null) {
        const s = sub.?;
        v = @max(v, @max(c.u(k.subscript_shift_down), s.h - c.u(k.subscript_top_max)));
        try bl.add(x.w, v, s);
        w = x.w + s.w + after;
    } else if (sub != null and sup != null) {
        const sp = sup.?;
        const sb = sub.?;
        u = @max(u, @max(shift_up, sp.d + c.u(k.superscript_bottom_min)));
        v = @max(v, c.u(k.subscript_shift_down));
        const gap = (u - sp.d) - (sb.h - v);
        const gap_min = c.u(k.sub_superscript_gap_min);
        if (gap < gap_min) {
            v += gap_min - gap;
            const psi = c.u(k.superscript_bottom_max_with_subscript) - (u - sp.d);
            if (psi > 0) {
                u += psi;
                v -= psi;
            }
        }
        try bl.add(x.w + delta, -u, sp);
        try bl.add(x.w, v, sb);
        w = x.w + @max(delta + sp.w, sb.w) + after;
    }
    var out = bl.finish();
    out.w = w;
    return out;
}

fn layFrac(c0: Ctx, f: tree.Frac) Err!Box {
    const c = if (f.style) |s| c0.with(styleFromCmd(s, c0.style.cramped())) else c0;
    const k = c.k;
    const num = try layRow(c.with(c.style.num()), f.num);
    const den = try layRow(c.with(c.style.den()), f.den);
    const disp = c.style.display();
    const a = c.axis();
    const th: f32 = if (f.thickness) |r| r * c.size() else c.u(k.fraction_rule_thickness);
    var u: f32 = c.u(if (th > 0)
        (if (disp) k.fraction_numerator_display_style_shift_up else k.fraction_numerator_shift_up)
    else
        (if (disp) k.stack_top_display_style_shift_up else k.stack_top_shift_up));
    var v: f32 = c.u(if (th > 0)
        (if (disp) k.fraction_denominator_display_style_shift_down else k.fraction_denominator_shift_down)
    else
        (if (disp) k.stack_bottom_display_style_shift_down else k.stack_bottom_shift_down));
    if (th > 0) {
        const gn = c.u(if (disp) k.fraction_num_display_style_gap_min else k.fraction_numerator_gap_min);
        const gd = c.u(if (disp) k.fraction_denom_display_style_gap_min else k.fraction_denominator_gap_min);
        u = @max(u, gn + a + th / 2 + num.d);
        v = @max(v, gd + den.h - (a - th / 2));
    } else {
        const gmin = c.u(if (disp) k.stack_display_style_gap_min else k.stack_gap_min);
        const gap = (u - num.d) - (den.h - v);
        if (gap < gmin) {
            const psi = (gmin - gap) / 2;
            u += psi;
            v += psi;
        }
    }
    const w = @max(num.w, den.w);
    var bl: Builder = .{ .a = c.a };
    try bl.add((w - num.w) / 2, -u, num);
    try bl.add((w - den.w) / 2, v, den);
    if (th > 0) try bl.add(0, -(a - th / 2), rule(w, th));
    var out = bl.finish();
    out.w = w;
    if (f.open == null and f.close == null) return out;
    return fenceParts(c, f.open, f.close, &.{out}, &.{});
}

fn laySqrt(c: Ctx, n: anytype) Err!Box {
    const k = c.k;
    const body = try layRow(c.with(c.style.cramp()), n.body);
    const gap = c.u(if (c.style.display()) k.radical_display_style_vertical_gap else k.radical_vertical_gap);
    const th = c.u(k.radical_rule_thickness);
    const need = body.h + body.d + gap + th;
    const gid = c.f.glyphFor(0x221A);
    const rad = if (gid == 0) Box{} else try stretch(c, gid, true, need);
    const hh = rad.h + rad.d;
    var clr = gap;
    if (hh > need) clr += (hh - need) / 2;
    const top = body.h + clr + th;
    const rad_up = top - rad.h;

    var bl: Builder = .{ .a = c.a };
    var x0: f32 = 0;
    if (n.index) |ix| {
        const deg = try layRow(c.with(.ss), ix);
        const before = @max(c.u(k.radical_kern_before_degree), 0);
        const after = c.u(k.radical_kern_after_degree);
        const bottom = rad_up - rad.d;
        const deg_up = bottom + @as(f32, @floatFromInt(k.radical_degree_bottom_raise_percent)) / 100 * hh + deg.d;
        x0 = @max(before + deg.w + after, 0);
        try bl.add(before, -deg_up, deg);
    }
    try bl.add(x0, -rad_up, rad);
    try bl.add(x0 + rad.w, 0, body);
    try bl.add(x0 + rad.w, -(top - th), rule(body.w, th));
    var out = bl.finish();
    out.h = @max(out.h, top + c.u(k.radical_extra_ascender));
    out.d = @max(body.d, rad.d - rad_up);
    out.w = x0 + rad.w + body.w;
    return out;
}

fn fenceParts(c: Ctx, open: ?u21, close: ?u21, parts: []const Box, seps: []const ?u21) Err!Box {
    var hh: f32 = 0;
    var dd: f32 = 0;
    for (parts) |p| {
        hh = @max(hh, p.h);
        dd = @max(dd, p.d);
    }
    const a = c.axis();
    const delta = @max(hh - a, dd + a);
    const target = @max(delta * 2 * 0.901, delta * 2 - 0.5 * c.base);
    var bl: Builder = .{ .a = c.a };
    var x: f32 = 0;
    const l = try delimBox(c, open, target);
    try bl.add(x, 0, l);
    x += l.w;
    for (parts, 0..) |p, i| {
        try bl.add(x, 0, p);
        x += p.w;
        if (i < seps.len) {
            const m = try delimBox(c, seps[i], target);
            try bl.add(x, 0, m);
            x += m.w;
        }
    }
    const r = try delimBox(c, close, target);
    try bl.add(x, 0, r);
    var out = bl.finish();
    out.w = x + r.w;
    return out;
}

fn layFenced(c: Ctx, n: anytype) Err!Box {
    var parts: std.ArrayList(Box) = .empty;
    var seps: std.ArrayList(?u21) = .empty;
    var start: usize = 0;
    for (n.body, 0..) |*m, i| {
        if (m.* == .middle) {
            try parts.append(c.a, try layRow(c, n.body[start..i]));
            try seps.append(c.a, m.middle);
            start = i + 1;
        }
    }
    try parts.append(c.a, try layRow(c, n.body[start..]));
    return fenceParts(c, n.open, n.close, parts.items, seps.items);
}

fn layAccent(c: Ctx, n: anytype) Err!Box {
    const k = c.k;
    const base = try layRow(c.with(c.style.cramp()), n.base);
    const gid = c.f.glyphFor(n.cp);
    const acc = if (n.wide) try stretch(c, gid, false, base.w) else glyphBox(c, gid);
    const skew = (base.accent_x orelse base.w / 2) - (acc.accent_x orelse acc.w / 2);
    const delta = @min(base.h, c.u(k.accent_base_height));
    var bl: Builder = .{ .a = c.a };
    try bl.add(0, 0, base);
    try bl.add(skew, -(base.h - delta), acc);
    var out = bl.finish();
    out.w = base.w;
    out.accent_x = base.accent_x;
    return out;
}

fn layLine(c: Ctx, n: anytype) Err!Box {
    const k = c.k;
    var bl: Builder = .{ .a = c.a };
    if (n.over) {
        const body = try layRow(c.with(c.style.cramp()), n.body);
        const th = c.u(k.overbar_rule_thickness);
        const gap = c.u(k.overbar_vertical_gap);
        try bl.add(0, 0, body);
        try bl.add(0, -(body.h + gap), rule(body.w, th));
        var out = bl.finish();
        out.w = body.w;
        out.h = body.h + gap + th + c.u(k.overbar_extra_ascender);
        return out;
    }
    const body = try layRow(c, n.body);
    const th = c.u(k.underbar_rule_thickness);
    const gap = c.u(k.underbar_vertical_gap);
    try bl.add(0, 0, body);
    try bl.add(0, body.d + gap + th, rule(body.w, th));
    var out = bl.finish();
    out.w = body.w;
    out.d = body.d + gap + th + c.u(k.underbar_extra_descender);
    return out;
}

fn layStack(c: Ctx, s: anytype) Err!Box {
    var box = try layRow(c, s.base);
    if (s.over_cp != 0 or s.under_cp != 0) {
        const up: ?Box = if (s.over_cp != 0) try horizGlyph(c, s.over_cp, box.w) else null;
        const low: ?Box = if (s.under_cp != 0) try horizGlyph(c, s.under_cp, box.w) else null;
        box = try limits(c, box, up, low);
    }
    if (s.over != null or s.under != null) {
        const up: ?Box = if (s.over) |o| try layRow(c.with(c.style.sup()), o) else null;
        const low: ?Box = if (s.under) |o| try layRow(c.with(c.style.sub()), o) else null;
        box = try limits(c, box, up, low);
    }
    return box;
}

fn layXArrow(c: Ctx, x: anytype) Err!Box {
    const up = try layRow(c.with(c.style.sup()), x.over);
    const low: ?Box = if (x.under) |o| try layRow(c.with(c.style.sub()), o) else null;
    var lw = up.w;
    if (low) |b| lw = @max(lw, b.w);
    const arrow = try centerOnAxis(c, try horizGlyph(c, x.cp, @max(lw + 1.2 * c.size(), 2.0 * c.size())));
    return limits(c, arrow, up, low);
}

fn layText(c: Ctx, str: []const u8, color: ?u32) Err!Box {
    const px = c.size();
    const s = px / @as(f32, @floatFromInt(c.tf.upem));
    var bl: Builder = .{ .a = c.a };
    var x: f32 = 0;
    var prev: u16 = 0;
    var it = (std.unicode.Utf8View.init(str) catch return .{}).iterator();
    while (it.nextCodepoint()) |cp| {
        const gid = c.tf.glyphFor(cp);
        x += @as(f32, @floatCast(c.tf.kern(prev, gid))) * s;
        var b: Box = .{ .w = @as(f32, @floatCast(c.tf.advance(gid))) * s, .kind = .{ .glyph = .{ .gid = gid, .px = px, .face = c.tf } } };
        const bb = c.tf.bbox(gid);
        b.h = @max(@as(f32, @floatFromInt(bb.y1)), 0) * s;
        b.d = @max(-@as(f32, @floatFromInt(bb.y0)), 0) * s;
        try bl.add(x, 0, b);
        x += b.w;
        prev = gid;
    }
    var out = bl.finish();
    out.w = x;
    if (color) |rgb| return colorBox(c, out, rgb);
    return out;
}

fn layNumber(c: Ctx, str: []const u8) Err!Box {
    var bl: Builder = .{ .a = c.a };
    var x: f32 = 0;
    var single: Box = .{};
    for (str) |ch| {
        const b = charBox(c, ch, c.face, false);
        try bl.add(x, 0, b);
        x += b.w;
        single = b;
    }
    if (str.len == 1) return single;
    var out = bl.finish();
    out.w = x;
    return out;
}

fn colorBox(c: Ctx, b: Box, rgb: u32) Err!Box {
    const child = try c.a.create(Box);
    child.* = b;
    return .{ .w = b.w, .h = b.h, .d = b.d, .ic = b.ic, .accent_x = b.accent_x, .kind = .{ .color = .{ .rgb = rgb, .child = child } } };
}

const named_colors = [_]struct { name: []const u8, rgb: u32 }{
    .{ .name = "black", .rgb = 0x000000 },
    .{ .name = "white", .rgb = 0xFFFFFF },
    .{ .name = "red", .rgb = 0xFF0000 },
    .{ .name = "green", .rgb = 0x00FF00 },
    .{ .name = "blue", .rgb = 0x0000FF },
    .{ .name = "cyan", .rgb = 0x00FFFF },
    .{ .name = "magenta", .rgb = 0xFF00FF },
    .{ .name = "yellow", .rgb = 0xFFFF00 },
    .{ .name = "gray", .rgb = 0x808080 },
    .{ .name = "orange", .rgb = 0xFFA500 },
    .{ .name = "purple", .rgb = 0x800080 },
    .{ .name = "brown", .rgb = 0xA52A2A },
    .{ .name = "pink", .rgb = 0xFFC0CB },
};

fn rgbOf(col: tree.Color) u32 {
    if (col.rgb) |v| return v;
    for (named_colors) |n| if (std.ascii.eqlIgnoreCase(n.name, col.name)) return n.rgb;
    return 0x000000;
}

fn rulesAt(a: tree.Array, ci: usize, n: usize) u8 {
    if (ci == n) return a.trailing_rules;
    return if (ci < a.cols.len) a.cols[ci].rules_before else 0;
}

fn layArray(c: Ctx, arr: tree.Array) Err!Box {
    const nrows = arr.rows.len;
    var ncols = arr.cols.len;
    var cells: usize = 0;
    for (arr.rows) |r| {
        ncols = @max(ncols, r.cells.len);
        cells += r.cells.len;
    }
    if (cells > max_cells) return error.TooComplex;
    if (nrows == 0 or ncols == 0) return .{};
    const cs = c.with(styleFromCmd(arr.cell_style, false));
    const em = cs.size();
    const boxes = try c.a.alloc(Box, nrows * ncols);
    @memset(boxes, .{});
    const col_w = try c.a.alloc(f32, ncols);
    @memset(col_w, 0);
    const row_h = try c.a.alloc(f32, nrows);
    const row_d = try c.a.alloc(f32, nrows);
    for (arr.rows, 0..) |r, ri| {
        row_h[ri] = 0.86 * em;
        row_d[ri] = 0.3 * em;
        for (r.cells, 0..) |cell, ci| {
            const b = try layRow(cs, cell);
            boxes[ri * ncols + ci] = b;
            col_w[ci] = @max(col_w[ci], b.w);
            row_h[ri] = @max(row_h[ri], b.h);
            row_d[ri] = @max(row_d[ri], b.d);
        }
    }
    const rule_w = 0.04 * em;
    const left_pad: f32 = if (rulesAt(arr, 0, ncols) > 0) rule_w + 0.1 * em else 0;
    const right_pad: f32 = if (arr.trailing_rules > 0) rule_w + 0.1 * em else 0;
    const col_x = try c.a.alloc(f32, ncols);
    var x: f32 = left_pad;
    for (0..ncols) |ci| {
        col_x[ci] = x;
        x += col_w[ci];
        if (ci + 1 < ncols) x += arr.col_gap[ci % 2] * em;
    }
    const total_w = x + right_pad;

    const row_y = try c.a.alloc(f32, nrows);
    const hl_y = try c.a.alloc(f32, nrows + 1);
    const hl_n = try c.a.alloc(u8, nrows + 1);
    @memset(hl_n, 0);
    var y: f32 = 0;
    for (0..nrows) |ri| {
        const nh = arr.rows[ri].hlines_before;
        hl_n[ri] = nh;
        hl_y[ri] = y;
        y += rule_w * @as(f32, @floatFromInt(nh));
        y += row_h[ri];
        row_y[ri] = y;
        y += row_d[ri];
        if (ri + 1 < nrows) y += (arr.row_gap + arr.rows[ri].gap_after) * em;
    }
    hl_n[nrows] = arr.trailing_hlines;
    hl_y[nrows] = y;
    y += rule_w * @as(f32, @floatFromInt(arr.trailing_hlines));
    const total_h = y;
    const top_above = total_h / 2 + c.axis();

    var bl: Builder = .{ .a = c.a };
    for (0..nrows) |ri| {
        for (0..ncols) |ci| {
            const b = boxes[ri * ncols + ci];
            const al: tree.Align = if (ci < arr.cols.len) arr.cols[ci].align_ else arr.col_align[ci % 2];
            const dx: f32 = switch (al) {
                .l => 0,
                .c => (col_w[ci] - b.w) / 2,
                .r => col_w[ci] - b.w,
            };
            try bl.add(col_x[ci] + dx, row_y[ri] - top_above, b);
        }
    }
    for (0..nrows + 1) |i| {
        var t: u8 = 0;
        while (t < hl_n[i]) : (t += 1) {
            try bl.add(0, hl_y[i] + @as(f32, @floatFromInt(t + 1)) * rule_w - top_above, rule(total_w, rule_w));
        }
    }
    for (0..ncols + 1) |ci| {
        if (rulesAt(arr, ci, ncols) == 0) continue;
        const vx = if (ci == 0) 0 else if (ci == ncols) total_w - rule_w else col_x[ci] - arr.col_gap[(ci - 1) % 2] * em / 2 - rule_w / 2;
        try bl.add(vx, total_h - top_above, rule(rule_w, total_h));
    }
    var out = bl.finish();
    out.w = total_w;
    out.h = top_above;
    out.d = total_h - top_above;
    if (arr.open == null and arr.close == null) return out;
    return fenceParts(c, arr.open, arr.close, &.{out}, &.{});
}

fn layEnclose(c: Ctx, e: anytype) Err!Box {
    const body = try layRow(c, e.body);
    const pad = 0.3 * c.size();
    const t: f32 = if (e.border) 0.04 * c.size() else 0;
    const o = pad + t;
    const w = body.w + 2 * o;
    var bl: Builder = .{ .a = c.a };
    if (e.bg) |bg| try bl.add(0, body.d + o, try colorBox(c, rule(w, body.h + body.d + 2 * o), rgbOf(bg)));
    try bl.add(o, 0, body);
    if (e.border) {
        var fr: Builder = .{ .a = c.a };
        try fr.add(0, -(body.h + o - t), rule(w, t));
        try fr.add(0, body.d + o, rule(w, t));
        try fr.add(0, body.d + o, rule(t, body.h + body.d + 2 * o));
        try fr.add(w - t, body.d + o, rule(t, body.h + body.d + 2 * o));
        var frame = fr.finish();
        if (e.border_color) |bc| frame = try colorBox(c, frame, rgbOf(bc));
        try bl.add(0, 0, frame);
    }
    var out = bl.finish();
    out.w = w;
    out.h = body.h + o;
    out.d = body.d + o;
    return out;
}

fn layNegate(c: Ctx, inner: *const Node) Err!Box {
    const body = try layNode(c, inner);
    var gid = c.f.glyphFor(0x338);
    if (gid == 0) gid = c.f.glyphFor('/');
    const g = glyphBox(c, gid);
    const bb = c.f.bbox(gid);
    const kk = c.size() / @as(f32, @floatFromInt(c.f.upem));
    const cx = @as(f32, @floatFromInt(@as(i32, bb.x0) + bb.x1)) / 2 * kk;
    var bl: Builder = .{ .a = c.a };
    try bl.add(0, 0, body);
    try bl.add(body.w / 2 - cx, 0, g);
    var out = bl.finish();
    out.w = body.w;
    return out;
}

fn layRuleNode(c: Ctx, r: anytype) Err!Box {
    const w = r.w * c.size();
    const bottom = (r.raise - r.d) * c.size();
    const top = (r.raise + r.h) * c.size();
    var bl: Builder = .{ .a = c.a };
    if (r.blank) {
        try bl.add(0, -bottom, .{ .w = w, .h = top - bottom });
    } else try bl.add(0, -bottom, rule(w, top - bottom));
    var out = bl.finish();
    out.w = w;
    return out;
}

fn layNode(c: Ctx, n: *const Node) Err!Box {
    c.budget.nodes += 1;
    if (c.budget.nodes > max_nodes or c.budget.depth >= max_depth) return error.TooComplex;
    c.budget.depth += 1;
    defer c.budget.depth -= 1;
    switch (n.*) {
        .atom => |a| {
            if (a.cp == 0) return .{};
            return charBox(c, a.cp, c.face, a.italic);
        },
        .number => |s| return layNumber(c, s),
        .group => |g| return layRow(c, g.body),
        .op => |o| return layOp(c, o),
        .supsub => |s| return laySupsub(c, s),
        .frac => |f| return layFrac(c, f),
        .sqrt => |s| return laySqrt(c, s),
        .fenced => |f| return layFenced(c, f),
        .middle => return .{},
        .big => |b| {
            const sizes = [_]f32{ 1.2, 1.8, 2.4, 3.0 };
            return delimBox(c, b.cp, sizes[@min(@max(b.size, 1), 4) - 1] * c.base);
        },
        .accent => |a| return layAccent(c, a),
        .line => |l| return layLine(c, l),
        .stack => |s| return layStack(c, s),
        .xarrow => |x| return layXArrow(c, x),
        .text => |t| return layText(c, t.str, null),
        .font => |f| {
            var cc = c;
            cc.face = f.font;
            return layRow(cc, f.body);
        },
        .size => |s| {
            var cc = c;
            cc.base = c.base * s.scale;
            return layRow(cc, s.body);
        },
        .style => |s| return layRow(c.with(styleFromCmd(s.style, c.style.cramped())), s.body),
        .color => |x| return colorBox(c, try layRow(c, x.body), rgbOf(x.color)),
        .space => |s| return kern(s.width * (if (s.reset_script) c.base else c.size())),
        .phantom => |p| {
            const b = try layRow(c, p.body);
            const dims: Box = .{ .w = if (p.w) b.w else 0, .h = if (p.h) b.h else 0, .d = if (p.d) b.d else 0 };
            if (!p.visible) return dims;
            var bl: Builder = .{ .a = c.a };
            try bl.add(0, 0, b);
            var out = bl.finish();
            out.w = dims.w;
            out.h = dims.h;
            out.d = dims.d;
            return out;
        },
        .rule => |r| return layRuleNode(c, r),
        .enclose => |e| return layEnclose(c, e),
        .mathchoice => |m| {
            const pick = switch (c.style.level()) {
                0 => if (c.style.display()) m.d else m.t,
                1 => m.s,
                else => m.ss,
            };
            return layRow(c, pick);
        },
        .negate => |b| return layNegate(c, b),
        .array => |a| return layArray(c, a),
        .undefined_cs => |s| return layText(c.with(.t), s, error_rgb),
        .parse_error => |s| return layText(c.with(.t), s, error_rgb),
    }
}

pub fn layoutNodes(alloc: Allocator, nodes: []const Node, f: *const Font, opts: Options) Error!Box {
    const math = if (f.math) |*m| m else return error.NoMathTable;
    var budget: Budget = .{};
    const c: Ctx = .{
        .a = alloc,
        .f = f,
        .tf = opts.text_font orelse font.bundled(false, false),
        .k = &math.constants,
        .base = opts.size,
        .style = if (opts.display) .d else .t,
        .budget = &budget,
    };
    return layRow(c, nodes) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooComplex => layText(c.with(.t), "Math too complex", error_rgb) catch error.OutOfMemory,
    };
}

pub fn layout(alloc: Allocator, t: *const Tree, f: *const Font, opts: Options) Error!Box {
    return layoutNodes(alloc, t.root, f, opts);
}

const testing = std.testing;
const testfont = @import("testfont.zig");

const nx: Node = .{ .atom = .{ .class = .ord, .cp = 'x', .italic = true } };
const n2: Node = .{ .number = "2" };
const na: Node = .{ .atom = .{ .class = .ord, .cp = 'a', .italic = true } };
const nb: Node = .{ .atom = .{ .class = .ord, .cp = 'b', .italic = true } };
const nplus: Node = .{ .atom = .{ .class = .bin, .cp = '+' } };
const two_row = [_]Node{n2};
const x_row = [_]Node{nx};

fn near(want: f32, got: f32) !void {
    try testing.expectApproxEqAbs(want, got, 0.01);
}

fn run(a: Allocator, f: *const Font, node: Node, display: bool) !Box {
    return layoutNodes(a, &.{node}, f, .{ .size = 1000, .display = display });
}

fn openTestFont(a: Allocator) !Font {
    return Font.init(try testfont.build(a), 0);
}

test "superscript uses SuperscriptShiftUp and the italic correction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .supsub = .{ .base = &nx, .sup = &two_row, .sub = null, .limits = .side } }, false);
    const items = b.kind.group;
    try near(-360, items[1].y);
    try near(600, items[1].x);
    try near(1004, b.w);
    try near(850, b.h);
    try near(0, b.d);
}

test "subscript shift is the largest of the three bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .supsub = .{ .base = &nx, .sup = null, .sub = &two_row, .limits = .side } }, false);
    try near(150, b.kind.group[1].y);
    try near(904, b.w);
    try near(150, b.d);
}

test "both scripts apply the gap rule and the bottom-max rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .supsub = .{ .base = &nx, .sup = &two_row, .sub = &two_row, .limits = .side } }, false);
    try near(-400, b.kind.group[1].y);
    try near(250, b.kind.group[2].y);
    try near(890, b.h);
    try near(250, b.d);
    try near(1004, b.w);
}

test "fraction shifts in text and display style" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const node: Node = .{ .frac = .{ .num = &two_row, .den = &two_row } };
    const t = try run(arena.allocator(), &f, node, false);
    try near(-400, t.kind.group[0].y);
    try near(380, t.kind.group[1].y);
    try near(-210, t.kind.group[2].y);
    try near(890, t.h);
    try near(380, t.d);
    try near(364, t.w);
    const d = try run(arena.allocator(), &f, node, true);
    try near(-650, d.kind.group[0].y);
    try near(690, d.kind.group[1].y);
    try near(1350, d.h);
    try near(690, d.d);
    try near(520, d.w);
}

test "radical clearance centres the sign on the radicand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .sqrt = .{ .body = &x_row } }, false);
    const items = b.kind.group;
    try near(-5, items[0].y);
    try near(-745, items[2].y);
    try near(885, b.h);
    try near(195, b.d);
    try near(1100, b.w);
}

test "spacing between atoms follows the TeX table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const mid = try layoutNodes(arena.allocator(), &.{ na, nplus, nb }, &f, .{ .size = 1000 });
    try near(480 + 600 + 480 + 2 * 4000.0 / 18.0, mid.w);
    const lead = try layoutNodes(arena.allocator(), &.{ nplus, na }, &f, .{ .size = 1000 });
    try near(600 + 480, lead.w);
    try testing.expectEqual(@as(u8, 2), spaceMu(.ord, .bin, false));
    try testing.expectEqual(@as(u8, 0), spaceMu(.ord, .bin, true));
    try testing.expectEqual(@as(u8, 3), spaceMu(.ord, .rel, false));
    try testing.expectEqual(@as(u8, 1), spaceMu(.ord, .op, true));
    try testing.expectEqual(@as(u8, 0), spaceMu(.open, .ord, false));
}

test "delimiters pick the smallest covering variant, then an assembly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try openTestFont(a);
    const small = try run(a, &f, .{ .fenced = .{ .open = '(', .close = '(', .body = &x_row } }, false);
    try near(750, small.kind.group[0].box.h);
    try near(250, small.kind.group[0].box.d);

    const mid_rule = [_]Node{.{ .rule = .{ .w = 0.1, .h = 1.0, .d = 0 } }};
    const mid = try run(a, &f, .{ .fenced = .{ .open = '(', .close = '(', .body = &mid_rule } }, false);
    try near(1250, mid.kind.group[0].box.h);
    try near(750, mid.kind.group[0].box.d);

    const tall_rule = [_]Node{.{ .rule = .{ .w = 0.1, .h = 2.0, .d = 0, .raise = -0.5 } }};
    const tall = try run(a, &f, .{ .fenced = .{ .open = '(', .close = '(', .body = &tall_rule } }, false);
    const asm_box = tall.kind.group[0].box;
    try near(1400, asm_box.h);
    try near(900, asm_box.d);
    try testing.expectEqual(@as(usize, 5), asm_box.kind.group[0].box.kind.group.len);
}

test "character mapping" {
    try testing.expectEqual(@as(u32, 0x211D), mapChar('R', .bb, false));
    try testing.expectEqual(@as(u32, 0x1D465), mapChar('x', .default, true));
    try testing.expectEqual(@as(u32, 'x'), mapChar('x', .default, false));
    try testing.expectEqual(@as(u32, 0x210E), mapChar('h', .default, true));
    try testing.expectEqual(@as(u32, 0x1D6FC), mapChar(0x3B1, .default, true));
    try testing.expectEqual(@as(u32, 0x391), mapChar(0x391, .default, false));
    try testing.expectEqual(@as(u32, 0x1D400), mapChar('A', .bf, false));
    try testing.expectEqual(@as(u32, 'x'), mapChar('x', .rm, true));
    try testing.expectEqual(@as(u32, 0x1D7D8), mapChar('0', .bb, false));
}

fn loadCambria(a: Allocator) !Font {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    return Font.fromTtc(testing.io, a, "C:\\Windows\\Fonts\\cambria.ttc", 1) catch error.SkipZigTest;
}

test "Cambria Math constants drive x^2 and a display fraction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try loadCambria(a);
    const k = f.math.?.constants;
    try testing.expectEqual(@as(i16, 750), k.superscript_shift_up);
    try testing.expectEqual(@as(i16, 585), k.axis_height);
    const size: f32 = @floatFromInt(f.upem);
    const opts: Options = .{ .size = size };
    const sup = try layoutNodes(a, &.{.{ .supsub = .{ .base = &nx, .sup = &two_row, .sub = null, .limits = .side } }}, &f, opts);
    try near(-750, sup.kind.group[1].y);
    const sub = try layoutNodes(a, &.{.{ .supsub = .{ .base = &nx, .sup = null, .sub = &two_row, .limits = .side } }}, &f, opts);
    try near(418, sub.kind.group[1].y);
    const fr = try layoutNodes(a, &.{.{ .frac = .{ .num = &two_row, .den = &two_row } }}, &f, .{ .size = size, .display = true });
    try near(-1550, fr.kind.group[0].y);
    try near(1370, fr.kind.group[1].y);
    try near(-(585 - 133.0 / 2.0), fr.kind.group[2].y);
}

test "embedded STIX Two Math lays out every construct without failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = font.embeddedMathFont(testing.io);
    const sum_body = [_]Node{.{ .atom = .{ .class = .op, .cp = 0x2211 } }};
    const sum: Node = .{ .op = .{ .body = &sum_body, .limits = .display, .large = true } };
    const idx = [_]Node{nx};
    const ss: Node = .{ .supsub = .{ .base = &sum, .sup = &two_row, .sub = &idx, .limits = .display } };
    const root = [_]Node{
        ss,
        .{ .frac = .{ .num = &two_row, .den = &x_row, .open = '(', .close = ')' } },
        .{ .sqrt = .{ .body = &x_row, .index = &two_row } },
        .{ .accent = .{ .base = &x_row, .cp = 0x2C6, .wide = true } },
        .{ .line = .{ .body = &x_row, .over = true } },
        .{ .negate = &nx },
    };
    const b = try layoutNodes(a, &root, f, .{ .size = 20, .display = true });
    try testing.expect(b.w > 20 and b.h > 10 and b.d > 0);
    const svg = try @import("scene.zig").toSvg(a, b, 0);
    try testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}
