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
    kind: Kind = .empty,
};

const GlyphKey = struct { face: usize, gid: u16 };

const GlyphMetrics = struct { adv: f32, x0: i16, y0: i16, x1: i16, y1: i16, ic: i16 };

pub const GlyphCache = struct {
    alloc: Allocator,
    map: std.AutoHashMapUnmanaged(GlyphKey, GlyphMetrics) = .empty,

    pub fn init(alloc: Allocator) GlyphCache {
        return .{ .alloc = alloc };
    }

    pub fn deinit(c: *GlyphCache) void {
        c.map.deinit(c.alloc);
    }

    fn get(c: *GlyphCache, face: *const Font, gid: u16) GlyphMetrics {
        const key: GlyphKey = .{ .face = @intFromPtr(face), .gid = gid };
        if (c.map.get(key)) |m| return m;
        const bb = face.bbox(gid);
        const m: GlyphMetrics = .{
            .adv = @floatCast(face.advance(gid)),
            .x0 = bb.x0,
            .y0 = bb.y0,
            .x1 = bb.x1,
            .y1 = bb.y1,
            .ic = face.italicCorrection(gid),
        };
        c.map.put(c.alloc, key, m) catch {};
        return m;
    }
};

pub const TextFonts = struct {
    regular: ?*const Font = null,
    bold: ?*const Font = null,
    italic: ?*const Font = null,
    bold_italic: ?*const Font = null,
};

pub fn resolveTextFonts(io: std.Io, families: []const u8) TextFonts {
    return .{
        .regular = font.resolve(io, families, 400, false),
        .bold = font.resolve(io, families, 700, false),
        .italic = font.resolve(io, families, 400, true),
        .bold_italic = font.resolve(io, families, 700, true),
    };
}

pub const Options = struct {
    size: f32 = 16,
    display: bool = false,
    text_fonts: TextFonts = .{},
    cache: ?*GlyphCache = null,
    dark: bool = true,
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
    text: TextFonts,
    cache: *GlyphCache,
    k: *const font.math.Constants,
    base: f32,
    style: Style,
    face: tree.Font = .default,
    dark: bool,
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

    fn unit(c: Ctx, face: *const Font) f32 {
        return c.size() / @as(f32, @floatFromInt(face.upem));
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


fn glyphBoxOn(c: Ctx, face: *const Font, gid: u16, with_ic: bool) Box {
    const m = c.cache.get(face, gid);
    const k = c.unit(face);
    return .{
        .w = m.adv * k,
        .h = @as(f32, @floatFromInt(m.y1)) * k,
        .d = -@as(f32, @floatFromInt(m.y0)) * k,
        .ic = if (with_ic) @as(f32, @floatFromInt(m.ic)) * k else 0,
        .kind = .{ .glyph = .{ .gid = gid, .px = c.size(), .face = face } },
    };
}

fn glyphBox(c: Ctx, gid: u16) Box {
    return glyphBoxOn(c, c.f, gid, false);
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
    out.h = b.h - dy;
    out.d = b.d + dy;
    out.ic = b.ic;
    return out;
}

fn rule(w: f32, h: f32) Box {
    return .{ .w = w, .h = h, .kind = .rule };
}

fn kern(w: f32) Box {
    return .{ .w = w };
}

fn xHeightUnits(f: *const Font) f32 {
    const d = f.data;
    const rd = std.mem.readInt;
    var face: u32 = 0;
    const faces: u32 = if (d.len >= 12 and std.mem.eql(u8, d[0..4], "ttcf")) @min(rd(u32, d[8..][0..4], .big), 256) else 1;
    while (face < faces) : (face += 1) {
        var dir: usize = 0;
        if (d.len >= 16 and std.mem.eql(u8, d[0..4], "ttcf")) {
            const at = 12 + @as(usize, face) * 4;
            if (at + 4 > d.len) break;
            dir = rd(u32, d[at..][0..4], .big);
        }
        if (dir + 12 > d.len) break;
        const n = rd(u16, d[dir + 4 ..][0..2], .big);
        var hmtx_ok = false;
        var os2: usize = 0;
        var os2_len: usize = 0;
        for (0..n) |i| {
            const rec = dir + 12 + i * 16;
            if (rec + 16 > d.len) break;
            const off: usize = rd(u32, d[rec + 8 ..][0..4], .big);
            if (std.mem.eql(u8, d[rec..][0..4], "hmtx") and off == f.hmtx) hmtx_ok = true;
            if (std.mem.eql(u8, d[rec..][0..4], "OS/2")) {
                os2 = off;
                os2_len = rd(u32, d[rec + 12 ..][0..4], .big);
            }
        }
        if (!hmtx_ok) continue;
        if (os2 != 0 and os2_len >= 88 and os2 + 88 <= d.len and rd(u16, d[os2..][0..2], .big) >= 2) {
            const v = rd(i16, d[os2 + 86 ..][0..2], .big);
            if (v > 0) return @floatFromInt(v);
        }
        break;
    }
    const gx = f.glyphFor('x');
    if (gx != 0) {
        const bb = f.bbox(gx);
        if (bb.y1 > 0) return @floatFromInt(bb.y1);
    }
    return @as(f32, @floatFromInt(f.upem)) / 2;
}

fn exOf(c: Ctx) f32 {
    return xHeightUnits(c.f) * c.size() / @as(f32, @floatFromInt(c.f.upem));
}

const Stretched = struct { box: Box, asc: f32, desc: f32 };

fn assemblyValid(a: font.math.Assembly, o_min: f32, k: f32) ?struct { ov_max: f32, ext_count: usize, ext_sum: f32, fixed_count: usize, fixed_sum: f32 } {
    var ov_max: f32 = std.math.floatMax(f32);
    var ext_count: usize = 0;
    var fixed_count: usize = 0;
    var ext_sum: f32 = 0;
    var fixed_sum: f32 = 0;
    for (0..a.count) |i| {
        const p = a.part(i) orelse return null;
        const adv = @as(f32, @floatFromInt(p.full_advance)) * k;
        if (p.extender) {
            ext_count += 1;
            ext_sum += adv;
        } else {
            fixed_count += 1;
            fixed_sum += adv;
        }
        if (p.extender or i != 0) ov_max = @min(ov_max, @as(f32, @floatFromInt(p.start_connector)) * k);
        if (p.extender or i + 1 != a.count) ov_max = @min(ov_max, @as(f32, @floatFromInt(p.end_connector)) * k);
    }
    if (ext_count == 0 or ov_max < o_min or ext_sum - o_min * @as(f32, @floatFromInt(ext_count)) <= 0) return null;
    return .{ .ov_max = ov_max, .ext_count = ext_count, .ext_sum = ext_sum, .fixed_count = fixed_count, .fixed_sum = fixed_sum };
}

fn assemble(c: Ctx, a: font.math.Assembly, vertical: bool, target: f32) Err!?Stretched {
    const k = c.unit(c.f);
    const o_min = @as(f32, @floatFromInt(c.f.math.?.min_connector_overlap)) * k;
    const v = assemblyValid(a, o_min, k) orelse return null;
    if (a.count > max_parts) return error.TooComplex;
    const ext_nonoverlap = v.ext_sum - o_min * @as(f32, @floatFromInt(v.ext_count));
    const need = (target - v.fixed_sum + o_min * (@as(f32, @floatFromInt(v.fixed_count)) - 1)) / ext_nonoverlap;
    var reps: usize = if (need > 0) @intFromFloat(@ceil(@min(need, 1000))) else 0;
    reps = @min(reps, (max_parts - v.fixed_count) / v.ext_count);
    const count = v.fixed_count + reps * v.ext_count;
    var ov = v.ov_max;
    if (count > 1) {
        const theo = (v.fixed_sum + @as(f32, @floatFromInt(reps)) * v.ext_sum - target) / @as(f32, @floatFromInt(count - 1));
        ov = @max(o_min, @min(ov, theo));
    }
    const total = v.fixed_sum + @as(f32, @floatFromInt(reps)) * v.ext_sum - ov * @as(f32, @floatFromInt(count -| 1));

    var seq: std.ArrayList(font.math.Part) = .empty;
    for (0..a.count) |i| {
        const p = a.part(i) orelse return null;
        for (0..(if (p.extender) reps else 1)) |_| try seq.append(c.a, p);
    }
    var bl: Builder = .{ .a = c.a };
    var pen: f32 = 0;
    var asc_max: f32 = 0;
    var desc_max: f32 = 0;
    var ink_w: f32 = 0;
    const n = seq.items.len;
    for (0..n) |step| {
        const p = if (vertical) seq.items[n - 1 - step] else seq.items[step];
        const g = glyphBoxOn(c, c.f, p.gid, false);
        const adv = @as(f32, @floatFromInt(p.full_advance)) * k;
        if (vertical) {
            try bl.add(0, -(total - pen - g.h), g);
        } else {
            try bl.add(pen, 0, g);
        }
        asc_max = @max(asc_max, g.h);
        desc_max = @max(desc_max, g.d);
        ink_w = @max(ink_w, g.w);
        pen += if (step + 1 == n) adv else adv - ov;
    }
    var out = bl.finish();
    if (vertical) {
        out.h = total;
        out.d = 0;
        out.w = ink_w;
        return .{ .box = out, .asc = total, .desc = 0 };
    }
    out.w = total;
    out.h = asc_max;
    out.d = desc_max;
    return .{ .box = out, .asc = asc_max, .desc = desc_max };
}

fn stretch(c: Ctx, gid: u16, vertical: bool, target: f32) Err!Stretched {
    const vars = if (vertical) c.f.vertVariants(gid) else c.f.horizVariants(gid);
    const k = c.unit(c.f);
    var cur = gid;
    var idx: usize = 0;
    while (true) {
        const m = c.cache.get(c.f, cur);
        const extent: i32 = if (vertical) @as(i32, m.y1) - m.y0 else @as(i32, m.x1) - m.x0;
        if (@as(f32, @floatFromInt(extent)) * k >= target) {
            const b = glyphBoxOn(c, c.f, cur, true);
            return .{ .box = b, .asc = b.h, .desc = b.d };
        }
        const v = vars.get(idx) orelse break;
        cur = v.gid;
        idx += 1;
    }
    if (c.f.assembly(gid, if (vertical) .vert else .horiz)) |a| {
        if (try assemble(c, a, vertical, target)) |s| return s;
    }
    const b = glyphBoxOn(c, c.f, cur, true);
    return .{ .box = b, .asc = b.h, .desc = b.d };
}

const big_sizes = [_]f32{ 1.2, 1.623, 2.047, 2.470 };

fn fenceBox(c: Ctx, cp: ?u21, t_asc: f32, t_desc: f32, min_override: ?f32, max_override: ?f32) Err!Box {
    const code = cp orelse return .{};
    const gid = c.f.glyphFor(code);
    if (gid == 0) return .{};
    const axis = c.axis();
    const half = @max(t_asc - axis, t_desc + axis);
    var asc = half + axis;
    var desc = half - axis;
    const target = asc + desc;
    const m = c.cache.get(c.f, gid);
    const unstretched = @as(f32, @floatFromInt(@as(i32, m.y1) - m.y0)) * c.unit(c.f);
    const min_size = @max(min_override orelse unstretched, 0);
    const max_size = if (max_override) |mx| @max(mx, min_size) else std.math.floatMax(f32);
    if (target <= 0) {
        asc = min_size / 2 + axis;
        desc = min_size - asc;
    } else if (target < min_size) {
        asc = @max(asc - axis, 0) * min_size / target + axis;
        desc = min_size - asc;
    } else if (max_size < target) {
        asc = @max(asc - axis, 0) * max_size / target + axis;
        desc = max_size - asc;
    }
    const st = try stretch(c, gid, true, asc + desc);
    return shifted(c, st.box, ((st.asc - st.desc) - (asc - desc)) / 2);
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
    const gid = c.f.glyphFor(a.cp);
    if (!c.style.display() or gid == 0) return charBox(c, a.cp, .rm, false);
    const min_h = c.u(c.k.display_operator_min_height);
    const st = try stretch(c, gid, true, min_h);
    return shifted(c, st.box, ((st.asc - st.desc) - 2 * c.axis()) / 2);
}

fn layOp(c: Ctx, o: anytype) Err!Box {
    if (o.large and o.body.len == 1 and o.body[0] == .atom) return layLargeOp(c, o.body[0].atom);
    return layRow(c, o.body);
}

const UnderOver = enum { limit, stretch, bar };

fn underOver(c: Ctx, base: Box, over: ?Box, under: ?Box, mode: UnderOver) Err!Box {
    const k = c.k;
    var w = base.w;
    if (over) |b| w = @max(w, b.w);
    if (under) |b| w = @max(w, b.w);
    var bl: Builder = .{ .a = c.a };
    try bl.add((w - base.w) / 2, 0, base);
    var asc = base.h;
    var desc = base.d;
    if (over) |b| {
        const up = switch (mode) {
            .limit => base.h + @max(b.d + c.u(k.upper_limit_gap_min), c.u(k.upper_limit_baseline_rise_min)),
            .stretch => base.h + @max(b.d + c.u(k.stretch_stack_gap_above_min), c.u(k.stretch_stack_top_shift_up)),
            .bar => base.h + c.u(k.overbar_vertical_gap) + b.d,
        };
        try bl.add((w - b.w) / 2, -up, b);
        asc = up + b.h + (if (mode == .bar) c.u(k.overbar_extra_ascender) else 0);
    }
    if (under) |b| {
        const down = switch (mode) {
            .limit => base.d + @max(b.h + c.u(k.lower_limit_gap_min), c.u(k.lower_limit_baseline_drop_min)),
            .stretch => base.d + @max(b.h + c.u(k.stretch_stack_gap_below_min), c.u(k.stretch_stack_bottom_shift_down)),
            .bar => base.d + c.u(k.underbar_vertical_gap) + b.h,
        };
        try bl.add((w - b.w) / 2, down, b);
        desc = down + b.d + (if (mode == .bar) c.u(k.underbar_extra_descender) else 0);
    }
    var out = bl.finish();
    out.w = w;
    out.h = @max(asc, 0);
    out.d = @max(desc, 0);
    return out;
}

fn scripts(c: Ctx, base: Box, sup: ?Box, sub: ?Box) Err!Box {
    const k = c.k;
    const ic = @min(base.w, base.ic);
    var sub_shift: f32 = 0;
    var sup_shift: f32 = 0;
    var asc_m: f32 = 0;
    var desc_m: f32 = 0;
    const shift_up = c.u(if (c.style.cramped()) k.superscript_shift_up_cramped else k.superscript_shift_up);
    if (sub) |s| {
        sub_shift = @max(c.u(k.subscript_shift_down), base.d + c.u(k.subscript_baseline_drop_min));
        desc_m = s.d;
    }
    if (sup) |s| {
        sup_shift = @max(shift_up, base.h - c.u(k.superscript_baseline_drop_max));
        asc_m = s.h;
    }
    if (sub != null and sup == null) {
        sub_shift = @max(sub_shift, sub.?.h - c.u(k.subscript_top_max));
    } else if (sup != null and sub == null) {
        sup_shift = @max(sup_shift, c.u(k.superscript_bottom_min) + sup.?.d);
    } else if (sub != null and sup != null) {
        const sb = sub.?;
        const sp = sup.?;
        var sub_s = @max(c.u(k.subscript_shift_down), base.d + c.u(k.subscript_baseline_drop_min));
        sub_s = @max(sub_s, sb.h - c.u(k.subscript_top_max));
        var sup_s = @max(shift_up, base.h - c.u(k.superscript_baseline_drop_max));
        sup_s = @max(sup_s, c.u(k.superscript_bottom_min) + sp.d);
        var gap = (sub_s - sb.h) + (sup_s - sp.d);
        const gap_min = c.u(k.sub_superscript_gap_min);
        if (gap < gap_min) {
            var delta = c.u(k.superscript_bottom_max_with_subscript) - (sup_s - sp.d);
            if (delta > 0) {
                delta = @min(delta, gap_min - gap);
                sup_s += delta;
                gap += delta;
            }
            if (gap < gap_min) sub_s += gap_min - gap;
        }
        sub_shift = @max(sub_shift, sub_s);
        sup_shift = @max(sup_shift, sup_s);
    }
    var bl: Builder = .{ .a = c.a };
    try bl.add(0, 0, base);
    var pair_w: f32 = 0;
    if (sub) |s| {
        try bl.add(@max(base.w - ic, 0), sub_shift, s);
        pair_w = @max(pair_w, s.w);
    }
    if (sup) |s| {
        try bl.add(base.w, -sup_shift, s);
        pair_w = @max(pair_w, s.w);
    }
    var out = bl.finish();
    out.w = base.w + c.u(k.space_after_script) + pair_w;
    out.h = @max(@max(base.h, asc_m + sup_shift), 0);
    out.d = @max(@max(base.d, desc_m + sub_shift), 0);
    return out;
}

fn laySupsub(c: Ctx, n: anytype) Err!Box {
    const x = try layNode(c, n.base);
    const sup: ?Box = if (n.sup) |s| try layRow(c.with(c.style.sup()), s) else null;
    const sub: ?Box = if (n.sub) |s| try layRow(c.with(c.style.sub()), s) else null;
    const on_limits = switch (n.limits) {
        .above => true,
        .display => c.style.display(),
        .side => false,
    };
    if (!on_limits) return scripts(c, x, sup, sub);
    const large = switch (n.base.*) {
        .op => |o| o.large,
        else => false,
    };
    return underOver(c, x, sup, sub, if (large) .limit else .bar);
}

fn layFrac(c0: Ctx, f: tree.Frac) Err!Box {
    const c = if (f.style) |s| c0.with(styleFromCmd(s, c0.style.cramped())) else c0;
    const k = c.k;
    const num = try layRow(c.with(c.style.num()), f.num);
    const den = try layRow(c.with(c.style.den()), f.den);
    const disp = c.style.display();
    const a = c.axis();
    const th: f32 = if (f.thickness) |r| r * c.size() else c.u(k.fraction_rule_thickness);
    var u: f32 = 0;
    var v: f32 = 0;
    if (th > 0) {
        const gn = c.u(if (disp) k.fraction_num_display_style_gap_min else k.fraction_numerator_gap_min);
        const gd = c.u(if (disp) k.fraction_denom_display_style_gap_min else k.fraction_denominator_gap_min);
        u = @max(c.u(if (disp) k.fraction_numerator_display_style_shift_up else k.fraction_numerator_shift_up), a + th / 2 + gn + num.d);
        v = @max(c.u(if (disp) k.fraction_denominator_display_style_shift_down else k.fraction_denominator_shift_down), th / 2 + gd + den.h - a);
    } else {
        u = c.u(if (disp) k.stack_top_display_style_shift_up else k.stack_top_shift_up);
        v = c.u(if (disp) k.stack_bottom_display_style_shift_down else k.stack_bottom_shift_down);
        const gmin = c.u(if (disp) k.stack_display_style_gap_min else k.stack_gap_min);
        const gap = v - den.h + u - num.d;
        if (gap < gmin) {
            const diff = gmin - gap;
            const delta = diff / 2;
            u += delta;
            v += diff - delta;
        }
    }
    const w = @max(num.w, den.w);
    var bl: Builder = .{ .a = c.a };
    try bl.add(1 + (w - num.w) / 2, -u, num);
    try bl.add(1 + (w - den.w) / 2, v, den);
    if (th > 0) try bl.add(1, -(a - th / 2), rule(w, th));
    var out = bl.finish();
    out.w = w + 2;
    out.h = @max(@max(u + num.h, -v + den.h), 0);
    out.d = @max(@max(-u + num.d, v + den.d), 0);
    if (f.open == null and f.close == null) return out;
    return fenceParts(c, f.open, f.close, &.{out}, &.{});
}

fn laySqrt(c: Ctx, n: anytype) Err!Box {
    const k = c.k;
    const base = try layRow(c.with(c.style.cramp()), n.body);
    const gap = c.u(if (c.style.display()) k.radical_display_style_vertical_gap else k.radical_vertical_gap);
    const th = c.u(k.radical_rule_thickness);
    const extra = c.u(k.radical_extra_ascender);
    const gid = c.f.glyphFor(0x221A);
    var surd: Stretched = .{ .box = .{}, .asc = 0, .desc = 0 };
    if (gid != 0) surd = try stretch(c, gid, true, base.h + base.d + gap + th);
    const surd_size = surd.asc + surd.desc;
    var idx: ?Box = null;
    var before: f32 = 0;
    var after: f32 = 0;
    if (n.index) |ix| {
        const b = try layRow(c.with(.ss), ix);
        idx = b;
        before = @max(c.u(k.radical_kern_before_degree), 0);
        after = @max(c.u(k.radical_kern_after_degree), -b.w);
    }
    const idx_w = if (idx) |b| b.w else 0;
    const raise = @as(f32, @floatFromInt(k.radical_degree_bottom_raise_percent)) / 100 * surd_size;
    var asc = base.h + gap + th + extra;
    var desc = @max(base.d, surd_size + extra - asc);
    if (idx) |b| {
        const new_asc = @max(asc, -desc + raise + b.d + b.h);
        const new_desc = @max(desc, desc - raise + b.d + b.h);
        asc = new_asc;
        desc = new_desc;
    }
    const x_surd = idx_w + before + after;
    var bl: Builder = .{ .a = c.a };
    if (idx) |b| try bl.add(before, -(-desc + raise + b.d), b);
    if (gid != 0) try bl.add(x_surd, -(gap + base.h - surd.asc), surd.box);
    const x_base = x_surd + surd.box.w;
    try bl.add(x_base, 0, base);
    if (th > 0) try bl.add(x_base, -(base.h + gap - th / 2), rule(base.w, th));
    var out = bl.finish();
    out.w = x_base + base.w;
    out.h = asc;
    out.d = desc;
    return out;
}

fn fenceParts(c: Ctx, open: ?u21, close: ?u21, parts: []const Box, seps: []const ?u21) Err!Box {
    var t_asc: f32 = 0;
    var t_desc: f32 = 0;
    for (parts) |p| {
        t_asc = @max(t_asc, p.h);
        t_desc = @max(t_desc, p.d);
    }
    var bl: Builder = .{ .a = c.a };
    var x: f32 = 0;
    const l = try fenceBox(c, open, t_asc, t_desc, null, null);
    try bl.add(x, 0, l);
    x += l.w;
    for (parts, 0..) |p, i| {
        try bl.add(x, 0, p);
        x += p.w;
        if (i < seps.len) {
            const m = try fenceBox(c, seps[i], t_asc, t_desc, null, null);
            try bl.add(x, 0, m);
            x += m.w;
        }
    }
    const r = try fenceBox(c, close, t_asc, t_desc, null, null);
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

fn scriptGlyph(c: Ctx, cp: u21, wide: bool, target: f32, over: bool) Err!?Box {
    const gid = c.f.glyphFor(cp);
    if (gid == 0) return null;
    const cs = c.with(if (over) c.style.sup() else c.style.sub());
    if (wide) return (try stretch(cs, gid, false, target)).box;
    return glyphBoxOn(cs, c.f, gid, false);
}

fn layAccent(c: Ctx, n: anytype) Err!Box {
    const base = try layRow(c, n.base);
    const over = try scriptGlyph(c, n.cp, n.wide, base.w, true);
    return underOver(c, base, over, null, .bar);
}

fn layLine(c: Ctx, n: anytype) Err!Box {
    const base = try layRow(c, n.body);
    const g = try scriptGlyph(c, 0x2015, true, base.w, n.over) orelse rule(base.w, c.u(if (n.over) c.k.overbar_rule_thickness else c.k.underbar_rule_thickness));
    return if (n.over) underOver(c, base, g, null, .bar) else underOver(c, base, null, g, .bar);
}

fn layStack(c: Ctx, s: anytype) Err!Box {
    var box = try layRow(c, s.base);
    if (s.over_cp != 0 or s.under_cp != 0) {
        const up: ?Box = if (s.over_cp != 0) try scriptGlyph(c, s.over_cp, true, box.w, true) else null;
        const low: ?Box = if (s.under_cp != 0) try scriptGlyph(c, s.under_cp, true, box.w, false) else null;
        box = try underOver(c, box, up, low, .bar);
    }
    if (s.over != null or s.under != null) {
        const up: ?Box = if (s.over) |o| try layRow(c.with(c.style.sup()), o) else null;
        const low: ?Box = if (s.under) |o| try layRow(c.with(c.style.sub()), o) else null;
        box = try underOver(c, box, up, low, .bar);
    }
    return box;
}

fn padLabel(c: Ctx, label: Box, shift_down: bool) Err!Box {
    const e = c.size();
    var bl: Builder = .{ .a = c.a };
    try bl.add(0.278 * e, if (shift_down) 0.2 * e else 0, label);
    var out = bl.finish();
    out.w = label.w + 0.833 * e;
    out.h = if (shift_down) label.h - 0.2 * e else label.h;
    out.d = @max(label.d, 0.25 * e);
    return out;
}

fn layXArrow(c: Ctx, x: anytype) Err!Box {
    const cs = c.with(c.style.sup());
    const up = try padLabel(cs, try layRow(cs, x.over), true);
    const low: ?Box = if (x.under) |o| try padLabel(c.with(c.style.sub()), try layRow(c.with(c.style.sub()), o), false) else null;
    var lw = up.w;
    if (low) |b| lw = @max(lw, b.w);
    const gid = c.f.glyphFor(x.cp);
    const arrow: Box = if (gid == 0) .{} else (try stretch(c, gid, false, lw)).box;
    return underOver(c, arrow, up, low, .stretch);
}

fn textFace(c: Ctx, v: tree.Font) *const Font {
    const bold = v == .bf or v == .bfit or v == .bsym or v == .sfbf or v == .sfbfit;
    const italic = v == .it or v == .bfit or v == .bsym or v == .sfit or v == .sfbfit;
    const pick = if (bold) (if (italic) c.text.bold_italic else c.text.bold) else (if (italic) c.text.italic else c.text.regular);
    return pick orelse font.bundled(bold, italic);
}

fn layText(c: Ctx, str: []const u8, v: tree.Font, color: ?u32) Err!Box {
    const face = textFace(c, v);
    var bl: Builder = .{ .a = c.a };
    var x: f32 = 0;
    var prev: u16 = 0;
    const s = c.unit(face);
    var it = (std.unicode.Utf8View.init(str) catch return .{}).iterator();
    while (it.nextCodepoint()) |cp| {
        const gid = face.glyphFor(cp);
        x += @as(f32, @floatCast(face.kern(prev, gid))) * s;
        const b = glyphBoxOn(c, face, gid, false);
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
    return .{ .w = b.w, .h = b.h, .d = b.d, .ic = b.ic, .kind = .{ .color = .{ .rgb = rgb, .child = child } } };
}

const Primer = struct { name: []const u8, dark: u32, light: u32 };

const primer = [_]Primer{
    .{ .name = "red", .dark = 0xF27D83, .light = 0xC50D28 },
    .{ .name = "blue", .dark = 0x4DA0FF, .light = 0x005FCC },
    .{ .name = "green", .dark = 0x41B445, .light = 0x2B6E3F },
    .{ .name = "orange", .dark = 0xED8326, .light = 0xA24610 },
    .{ .name = "yellow", .dark = 0xD3910D, .light = 0x805900 },
    .{ .name = "purple", .dark = 0xB687F7, .light = 0x783AE4 },
    .{ .name = "gray", .dark = 0x92A1B5, .light = 0x5C6570 },
};

const css_colors = [_]struct { name: []const u8, rgb: u32 }{
    .{ .name = "black", .rgb = 0x000000 },
    .{ .name = "white", .rgb = 0xFFFFFF },
    .{ .name = "cyan", .rgb = 0x00FFFF },
    .{ .name = "magenta", .rgb = 0xFF00FF },
    .{ .name = "pink", .rgb = 0xFFC0CB },
    .{ .name = "brown", .rgb = 0xA52A2A },
    .{ .name = "lime", .rgb = 0x00FF00 },
    .{ .name = "teal", .rgb = 0x008080 },
    .{ .name = "navy", .rgb = 0x000080 },
    .{ .name = "maroon", .rgb = 0x800000 },
    .{ .name = "olive", .rgb = 0x808000 },
    .{ .name = "silver", .rgb = 0xC0C0C0 },
    .{ .name = "aqua", .rgb = 0x00FFFF },
    .{ .name = "fuchsia", .rgb = 0xFF00FF },
    .{ .name = "gold", .rgb = 0xFFD700 },
    .{ .name = "violet", .rgb = 0xEE82EE },
    .{ .name = "indigo", .rgb = 0x4B0082 },
    .{ .name = "crimson", .rgb = 0xDC143C },
    .{ .name = "salmon", .rgb = 0xFA8072 },
    .{ .name = "tomato", .rgb = 0xFF6347 },
    .{ .name = "coral", .rgb = 0xFF7F50 },
    .{ .name = "turquoise", .rgb = 0x40E0D0 },
    .{ .name = "lightgray", .rgb = 0xD3D3D3 },
    .{ .name = "darkgray", .rgb = 0xA9A9A9 },
    .{ .name = "grey", .rgb = 0x808080 },
};

fn rgbOf(c: Ctx, col: tree.Color) u32 {
    if (col.rgb) |v| return v;
    for (primer) |p| if (std.mem.eql(u8, p.name, col.name)) return if (c.dark) p.dark else p.light;
    for (css_colors) |n| if (std.ascii.eqlIgnoreCase(n.name, col.name)) return n.rgb;
    return if (c.dark) 0xFFFFFF else 0x000000;
}

fn layArray(c: Ctx, arr: tree.Array) Err!Box {
    const nrows = arr.rows.len;
    var ncols: usize = 0;
    var cells: usize = 0;
    for (arr.rows) |r| {
        ncols = @max(ncols, r.cells.len);
        cells += r.cells.len;
    }
    if (cells > max_cells) return error.TooComplex;
    if (nrows == 0 or ncols == 0) return .{};
    const cell_style: tree.Style = if (arr.kind == .smallmatrix) .text else arr.cell_style;
    const cs = c.with(styleFromCmd(cell_style, false));
    const pad_v = exOf(cs) / 2;
    const pad_h = 0.4 * cs.size();
    const boxes = try c.a.alloc(Box, nrows * ncols);
    @memset(boxes, .{});
    const col_w = try c.a.alloc(f32, ncols);
    @memset(col_w, 0);
    const row_asc = try c.a.alloc(f32, nrows);
    const row_desc = try c.a.alloc(f32, nrows);
    for (arr.rows, 0..) |r, ri| {
        row_asc[ri] = 0;
        row_desc[ri] = 0;
        for (r.cells, 0..) |cell, ci| {
            const b = try layRow(cs, cell);
            boxes[ri * ncols + ci] = b;
            col_w[ci] = @max(col_w[ci], b.w);
            row_asc[ri] = @max(row_asc[ri], b.h);
            row_desc[ri] = @max(row_desc[ri], b.d);
        }
    }
    const col_x = try c.a.alloc(f32, ncols);
    var x: f32 = 0;
    for (0..ncols) |ci| {
        col_x[ci] = x;
        x += col_w[ci] + 2 * pad_h;
    }
    const row_base = try c.a.alloc(f32, nrows);
    var y: f32 = 0;
    for (0..nrows) |ri| {
        row_base[ri] = y + pad_v + row_asc[ri];
        y += 2 * pad_v + row_asc[ri] + row_desc[ri];
    }
    const top_above = y / 2 + c.axis();

    var bl: Builder = .{ .a = c.a };
    for (0..nrows) |ri| {
        for (0..ncols) |ci| {
            const b = boxes[ri * ncols + ci];
            try bl.add(col_x[ci] + pad_h + (col_w[ci] - b.w) / 2, row_base[ri] - top_above, b);
        }
    }
    var out = bl.finish();
    out.w = x;
    out.h = top_above;
    out.d = y - top_above;
    if (arr.open == null and arr.close == null) return out;
    return fenceParts(c, arr.open, arr.close, &.{out}, &.{});
}

fn layEnclose(c: Ctx, e: anytype) Err!Box {
    const body = try layRow(c, e.body);
    if (e.border and e.bg == null and e.border_color == null) return body;
    const pad = 0.3 * c.size();
    const t: f32 = if (e.border) 0.04 * c.size() else 0;
    const o = pad + t;
    const w = body.w + 2 * o;
    var bl: Builder = .{ .a = c.a };
    if (e.bg) |bg| try bl.add(0, body.d + o, try colorBox(c, rule(w, body.h + body.d + 2 * o), rgbOf(c, bg)));
    try bl.add(o, 0, body);
    if (e.border) {
        var fr: Builder = .{ .a = c.a };
        try fr.add(0, -(body.h + o - t), rule(w, t));
        try fr.add(0, body.d + o, rule(w, t));
        try fr.add(0, body.d + o, rule(t, body.h + body.d + 2 * o));
        try fr.add(w - t, body.d + o, rule(t, body.h + body.d + 2 * o));
        var frame = fr.finish();
        if (e.border_color) |bc| frame = try colorBox(c, frame, rgbOf(c, bc));
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
    const m = c.cache.get(c.f, gid);
    const cx = @as(f32, @floatFromInt(@as(i32, m.x0) + m.x1)) / 2 * c.unit(c.f);
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
            const sz = big_sizes[@min(@max(b.size, 1), 4) - 1] * c.size();
            return fenceBox(c, b.cp, 0, 0, sz, sz);
        },
        .accent => |a| return layAccent(c, a),
        .line => |l| return layLine(c, l),
        .stack => |s| return layStack(c, s),
        .xarrow => |x| return layXArrow(c, x),
        .text => |t| return layText(c, t.str, t.font, null),
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
        .color => |x| return colorBox(c, try layRow(c, x.body), rgbOf(c, x.color)),
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
        .undefined_cs => |s| return layText(c.with(.t), s, .rm, error_rgb),
        .parse_error => |s| return layText(c.with(.t), s, .rm, error_rgb),
    }
}

pub fn layoutNodes(alloc: Allocator, nodes: []const Node, f: *const Font, opts: Options) Error!Box {
    const math = if (f.math) |*m| m else return error.NoMathTable;
    var budget: Budget = .{};
    var local = GlyphCache.init(alloc);
    const c: Ctx = .{
        .a = alloc,
        .f = f,
        .text = opts.text_fonts,
        .cache = opts.cache orelse &local,
        .k = &math.constants,
        .base = opts.size,
        .style = if (opts.display) .d else .t,
        .dark = opts.dark,
        .budget = &budget,
    };
    return layRow(c, nodes) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooComplex => layText(c.with(.t), "Math too complex", .rm, error_rgb) catch error.OutOfMemory,
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

test "superscript shift is the largest bound, placed at the end of the base" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .supsub = .{ .base = &nx, .sup = &two_row, .sub = null, .limits = .side } }, false);
    const items = b.kind.group;
    try near(-360, items[1].y);
    try near(500, items[1].x);
    try near(904, b.w);
    try near(850, b.h);
    try near(0, b.d);
}

test "subscript shift is the largest of the three bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .supsub = .{ .base = &nx, .sup = null, .sub = &two_row, .limits = .side } }, false);
    try near(150, b.kind.group[1].y);
    try near(500, b.kind.group[1].x);
    try near(904, b.w);
    try near(150, b.d);
}

test "both scripts: push the superscript up first, then the subscript down" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .supsub = .{ .base = &nx, .sup = &two_row, .sub = &two_row, .limits = .side } }, false);
    try near(250, b.kind.group[1].y);
    try near(-400, b.kind.group[2].y);
    try near(890, b.h);
    try near(250, b.d);
    try near(904, b.w);
}

test "fraction shifts in text and display style, with the 1px padding" {
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
    try near(366, t.w);
    const d = try run(arena.allocator(), &f, node, true);
    try near(-650, d.kind.group[0].y);
    try near(690, d.kind.group[1].y);
    try near(1350, d.h);
    try near(690, d.d);
    try near(522, d.w);
}

test "radical: surd top at the bar centre, box sizes from the MathML Core formulas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try openTestFont(arena.allocator());
    const b = try run(arena.allocator(), &f, .{ .sqrt = .{ .body = &x_row } }, false);
    const items = b.kind.group;
    try near(250, items[0].y);
    try near(600, items[1].x);
    try near(-520, items[2].y);
    try near(690, b.h);
    try near(390, b.d);
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

test "fences: minimum is the base glyph, then variants by ink height, then an assembly" {
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
    try near(1500, asm_box.h);
    try near(1000, asm_box.d);
    try testing.expectEqual(@as(usize, 5), asm_box.kind.group[0].box.kind.group.len);
    try near(-2500 + 600, asm_box.kind.group[0].box.kind.group[0].y);
}

test "tables: padding is 0.5ex by 0.4em, rows and columns touch, centred on the axis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try openTestFont(a);
    const cells = [_]tree.Cell{ &x_row, &two_row };
    const rows = [_]tree.Row{.{ .cells = &cells }};
    const b = try run(a, &f, .{ .array = .{ .kind = .matrix, .rows = &rows, .cols = &.{} } }, false);
    const items = b.kind.group;
    try near(400, items[0].x);
    try near(100, items[0].y);
    try near(1700, items[1].x);
    try near(2620, b.w);
    try near(825, b.h);
    try near(325, b.d);
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

test "named colours follow GitHub's Primer remap" {
    var budget: Budget = .{};
    var cache = GlyphCache.init(testing.allocator);
    defer cache.deinit();
    const f = font.embeddedMathFont(testing.io);
    var c: Ctx = .{ .a = testing.allocator, .f = f, .text = .{}, .cache = &cache, .k = &f.math.?.constants, .base = 16, .style = .t, .dark = true, .budget = &budget };
    try testing.expectEqual(@as(u32, 0xF27D83), rgbOf(c, .{ .name = "red", .rgb = null }));
    try testing.expectEqual(@as(u32, 0x00FFFF), rgbOf(c, .{ .name = "cyan", .rgb = null }));
    try testing.expectEqual(@as(u32, 0x112233), rgbOf(c, .{ .name = "red", .rgb = 0x112233 }));
    c.dark = false;
    try testing.expectEqual(@as(u32, 0xC50D28), rgbOf(c, .{ .name = "red", .rgb = null }));
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
    try near(956, xHeightUnits(&f));
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
        .{ .text = .{ .str = "ab", .font = .bfit } },
    };
    var cache = GlyphCache.init(testing.allocator);
    defer cache.deinit();
    const b = try layoutNodes(a, &root, f, .{ .size = 20, .display = true, .cache = &cache });
    try testing.expect(b.w > 20 and b.h > 10 and b.d > 0);
    try testing.expect(cache.map.count() > 5);
    const svg = try @import("scene.zig").toSvg(a, b, 0);
    try testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}
