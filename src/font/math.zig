const std = @import("std");
const read = @import("read.zig");

const Error = read.Error;
const u16At = read.u16At;
const i16At = read.i16At;

pub const Constants = struct {
    script_percent_scale_down: i16,
    script_script_percent_scale_down: i16,
    delimited_sub_formula_min_height: i16,
    display_operator_min_height: i16,
    math_leading: i16,
    axis_height: i16,
    accent_base_height: i16,
    flattened_accent_base_height: i16,
    subscript_shift_down: i16,
    subscript_top_max: i16,
    subscript_baseline_drop_min: i16,
    superscript_shift_up: i16,
    superscript_shift_up_cramped: i16,
    superscript_bottom_min: i16,
    superscript_baseline_drop_max: i16,
    sub_superscript_gap_min: i16,
    superscript_bottom_max_with_subscript: i16,
    space_after_script: i16,
    upper_limit_gap_min: i16,
    upper_limit_baseline_rise_min: i16,
    lower_limit_gap_min: i16,
    lower_limit_baseline_drop_min: i16,
    stack_top_shift_up: i16,
    stack_top_display_style_shift_up: i16,
    stack_bottom_shift_down: i16,
    stack_bottom_display_style_shift_down: i16,
    stack_gap_min: i16,
    stack_display_style_gap_min: i16,
    stretch_stack_top_shift_up: i16,
    stretch_stack_bottom_shift_down: i16,
    stretch_stack_gap_above_min: i16,
    stretch_stack_gap_below_min: i16,
    fraction_numerator_shift_up: i16,
    fraction_numerator_display_style_shift_up: i16,
    fraction_denominator_shift_down: i16,
    fraction_denominator_display_style_shift_down: i16,
    fraction_numerator_gap_min: i16,
    fraction_num_display_style_gap_min: i16,
    fraction_rule_thickness: i16,
    fraction_denominator_gap_min: i16,
    fraction_denom_display_style_gap_min: i16,
    skewed_fraction_horizontal_gap: i16,
    skewed_fraction_vertical_gap: i16,
    overbar_vertical_gap: i16,
    overbar_rule_thickness: i16,
    overbar_extra_ascender: i16,
    underbar_vertical_gap: i16,
    underbar_rule_thickness: i16,
    underbar_extra_descender: i16,
    radical_vertical_gap: i16,
    radical_display_style_vertical_gap: i16,
    radical_rule_thickness: i16,
    radical_extra_ascender: i16,
    radical_kern_before_degree: i16,
    radical_kern_after_degree: i16,
    radical_degree_bottom_raise_percent: i16,

    fn parse(d: []const u8, at: usize) Error!Constants {
        var c = std.mem.zeroes(Constants);
        var p = at;
        inline for (comptime std.meta.fieldNames(Constants), 0..) |name, i| {
            @field(c, name) = try i16At(d, p);
            p += if (i < 4 or i == 55) 2 else 4;
        }
        return c;
    }
};

pub const Dir = enum { vert, horiz };

pub const Corner = enum { top_right, top_left, bottom_right, bottom_left };

pub const Kern = struct {
    data: []const u8,
    at: usize,
    count: usize,

    pub fn height(k: Kern, i: usize) ?i16 {
        if (i >= k.count) return null;
        return i16At(k.data, k.at + 2 + i * 4) catch null;
    }

    pub fn value(k: Kern, i: usize) ?i16 {
        if (i > k.count) return null;
        return i16At(k.data, k.at + 2 + k.count * 4 + i * 4) catch null;
    }

    pub fn atHeight(k: Kern, h: i16) i16 {
        var i: usize = 0;
        while (i < k.count) : (i += 1) {
            const ch = k.height(i) orelse break;
            if (h < ch) break;
        }
        return k.value(i) orelse 0;
    }
};

pub const Variant = struct { gid: u16, advance: u16 };

pub const Part = struct { gid: u16, start_connector: u16, end_connector: u16, full_advance: u16, extender: bool };

pub const Variants = struct {
    data: []const u8 = &.{},
    at: usize = 0,
    count: usize = 0,

    pub fn get(v: Variants, i: usize) ?Variant {
        if (i >= v.count) return null;
        const p = v.at + 4 + i * 4;
        return .{ .gid = u16At(v.data, p) catch return null, .advance = u16At(v.data, p + 2) catch return null };
    }
};

pub const Assembly = struct {
    data: []const u8,
    at: usize,
    count: usize,
    italics_correction: i16,

    pub fn part(a: Assembly, i: usize) ?Part {
        if (i >= a.count) return null;
        const p = a.at + 6 + i * 10;
        return .{
            .gid = u16At(a.data, p) catch return null,
            .start_connector = u16At(a.data, p + 2) catch return null,
            .end_connector = u16At(a.data, p + 4) catch return null,
            .full_advance = u16At(a.data, p + 6) catch return null,
            .extender = (u16At(a.data, p + 8) catch return null) & 1 != 0,
        };
    }
};

pub const Math = struct {
    data: []const u8,
    constants: Constants,
    constants_at: usize,
    italics: usize,
    accents: usize,
    extended: usize,
    kern_info: usize,
    variants: usize,
    min_connector_overlap: u16,

    pub fn parse(d: []const u8, at: usize) Error!Math {
        const consts = at + try u16At(d, at + 4);
        const info_off = try u16At(d, at + 6);
        const var_off = try u16At(d, at + 8);
        var m: Math = .{
            .data = d,
            .constants = try Constants.parse(d, consts),
            .constants_at = consts,
            .italics = 0,
            .accents = 0,
            .extended = 0,
            .kern_info = 0,
            .variants = 0,
            .min_connector_overlap = 0,
        };
        if (info_off != 0) {
            const info = at + info_off;
            const ic = try u16At(d, info);
            const ta = try u16At(d, info + 2);
            if (ic != 0) m.italics = info + ic;
            if (ta != 0) m.accents = info + ta;
            const es = try u16At(d, info + 4);
            const mk = try u16At(d, info + 6);
            if (es != 0) m.extended = info + es;
            if (mk != 0) m.kern_info = info + mk;
        }
        if (var_off != 0) {
            m.variants = at + var_off;
            m.min_connector_overlap = try u16At(d, m.variants);
        }
        return m;
    }

    pub fn value(m: Math, table: usize, g: u16) ?i16 {
        if (table == 0) return null;
        const d = m.data;
        const idx = (coverage(d, table + (u16At(d, table) catch return null), g) catch return null) orelse return null;
        const count = u16At(d, table + 2) catch return null;
        if (idx >= count) return null;
        return i16At(d, table + 4 + @as(usize, idx) * 4) catch null;
    }

    pub fn isExtended(m: Math, g: u16) bool {
        if (m.extended == 0) return false;
        const found = coverage(m.data, m.extended, g) catch return false;
        return found != null;
    }

    pub fn kernOf(m: Math, g: u16, corner: Corner) ?Kern {
        if (m.kern_info == 0) return null;
        const d = m.data;
        const idx = (coverage(d, m.kern_info + (u16At(d, m.kern_info) catch return null), g) catch return null) orelse return null;
        const n = u16At(d, m.kern_info + 2) catch return null;
        if (idx >= n) return null;
        const rec = m.kern_info + 4 + @as(usize, idx) * 8;
        const off = u16At(d, rec + @as(usize, @intFromEnum(corner)) * 2) catch return null;
        if (off == 0) return null;
        const at = m.kern_info + off;
        return .{ .data = d, .at = at, .count = u16At(d, at) catch return null };
    }

    pub fn italicCorrection(m: Math, g: u16) i16 {
        return m.value(m.italics, g) orelse 0;
    }

    pub fn topAccent(m: Math, g: u16) ?i16 {
        return m.value(m.accents, g);
    }

    fn construction(m: Math, g: u16, dir: Dir) ?usize {
        if (m.variants == 0) return null;
        const d = m.data;
        const v = m.variants;
        const cov_off = u16At(d, v + @as(usize, if (dir == .vert) 2 else 4)) catch return null;
        if (cov_off == 0) return null;
        const nv = u16At(d, v + 6) catch return null;
        const nh = u16At(d, v + 8) catch return null;
        const idx = (coverage(d, v + cov_off, g) catch return null) orelse return null;
        const base: usize = if (dir == .vert) 10 else 10 + @as(usize, nv) * 2;
        if (idx >= (if (dir == .vert) nv else nh)) return null;
        return v + (u16At(d, v + base + @as(usize, idx) * 2) catch return null);
    }

    pub fn variantsOf(m: Math, g: u16, dir: Dir) Variants {
        const c = m.construction(g, dir) orelse return .{};
        const n = u16At(m.data, c + 2) catch return .{};
        return .{ .data = m.data, .at = c, .count = n };
    }

    pub fn assembly(m: Math, g: u16, dir: Dir) ?Assembly {
        const c = m.construction(g, dir) orelse return null;
        const off = u16At(m.data, c) catch return null;
        if (off == 0) return null;
        const a = c + off;
        const n = u16At(m.data, a + 4) catch return null;
        return .{ .data = m.data, .at = a, .count = n, .italics_correction = i16At(m.data, a) catch return null };
    }
};

pub fn coverage(d: []const u8, cov: usize, g: u16) Error!?u16 {
    const fmt = try u16At(d, cov);
    const n = try u16At(d, cov + 2);
    var lo: usize = 0;
    var hi: usize = n;
    if (fmt == 1) {
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const v = try u16At(d, cov + 4 + mid * 2);
            if (v == g) return @intCast(mid);
            if (v < g) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    if (fmt != 2) return null;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const at = cov + 4 + mid * 6;
        if (g < try u16At(d, at)) {
            hi = mid;
        } else if (g > try u16At(d, at + 2)) {
            lo = mid + 1;
        } else return (try u16At(d, at + 4)) +% (g - try u16At(d, at));
    }
    return null;
}
