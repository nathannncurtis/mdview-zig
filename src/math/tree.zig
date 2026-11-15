const std = @import("std");

pub const Class = enum { ord, op, bin, rel, open, close, punct, inner };

pub const Font = enum { default, normal, rm, bf, it, bfit, sf, sfbf, sfit, sfbfit, tt, cal, bfcal, scr, bfscr, frak, bffrak, bb, bsym, oldstyle };

pub const Limits = enum { side, display, above };

pub const Style = enum { display, text, script, scriptscript };

pub const Align = enum { l, c, r };

pub const Color = struct {
    name: []const u8,
    rgb: ?u24,
};

pub const Atom = struct {
    class: Class,
    cp: u21,
    italic: bool = false,
    ams: bool = false,
};

pub const Group = struct {
    body: []const Node,
    class: ?Class = null,
};

pub const Op = struct {
    body: []const Node,
    limits: Limits,
    large: bool,
};

pub const SupSub = struct {
    base: *const Node,
    sup: ?[]const Node,
    sub: ?[]const Node,
    limits: Limits,
};

pub const Frac = struct {
    num: []const Node,
    den: []const Node,
    thickness: ?f32 = null,
    open: ?u21 = null,
    close: ?u21 = null,
    style: ?Style = null,
};

pub const Sqrt = struct {
    body: []const Node,
    index: ?[]const Node = null,
    up: f32 = 0,
    left: f32 = 0,
};

pub const Fenced = struct {
    open: ?u21,
    close: ?u21,
    body: []const Node,
};

pub const Big = struct {
    class: Class,
    size: u8,
    cp: ?u21,
};

pub const Accent = struct {
    base: []const Node,
    cp: u21,
    wide: bool,
};

pub const Line = struct {
    body: []const Node,
    over: bool,
};

pub const Stack = struct {
    base: []const Node,
    over: ?[]const Node = null,
    under: ?[]const Node = null,
    over_cp: u21 = 0,
    under_cp: u21 = 0,
    brace: bool = false,
};

pub const XArrow = struct {
    cp: u21,
    over: []const Node,
    under: ?[]const Node,
};

pub const Text = struct {
    str: []const u8,
    font: Font = .default,
};

pub const Styled = struct {
    font: Font,
    body: []const Node,
};

pub const Sized = struct {
    scale: f32,
    body: []const Node,
};

pub const Styled2 = struct {
    style: Style,
    body: []const Node,
};

pub const Colored = struct {
    color: Color,
    body: []const Node,
};

pub const Space = struct {
    width: f32,
    reset_script: bool = false,
};

pub const Phantom = struct {
    body: []const Node,
    visible: bool,
    w: bool,
    h: bool,
    d: bool,
};

pub const Rule = struct {
    w: f32,
    h: f32,
    d: f32,
    blank: bool = false,
    raise: f32 = 0,
};

pub const Notation = packed struct {
    box: bool = false,
    roundedbox: bool = false,
    circle: bool = false,
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,
    updiagonalstrike: bool = false,
    downdiagonalstrike: bool = false,
    verticalstrike: bool = false,
    horizontalstrike: bool = false,
    updiagonalarrow: bool = false,
    madruwb: bool = false,
    actuarial: bool = false,
    phasorangle: bool = false,
    longdiv: bool = false,
};

pub const Enclose = struct {
    body: []const Node,
    border: bool,
    bg: ?Color = null,
    border_color: ?Color = null,
    notation: Notation = .{},
    padding: f32 = 0,
    fg: ?Color = null,
    border_width: ?f32 = null,
};

pub const Link = struct {
    url: []const u8,
    body: []const Node,
};

pub const Shift = struct {
    dx: f32,
    dy: f32,
    body: []const Node,
};

pub const Lap = struct {
    left: bool,
    body: []const Node,
};

pub const Multiscripts = struct {
    base: []const Node,
    pre_sub: ?[]const Node = null,
    pre_sup: ?[]const Node = null,
    post_sub: ?[]const Node = null,
    post_sup: ?[]const Node = null,
};

pub const VArrow = struct {
    cp: u21,
    left: []const Node,
    right: []const Node,
};

pub const MathChoice = struct {
    d: []const Node,
    t: []const Node,
    s: []const Node,
    ss: []const Node,
};

pub const Cell = []const Node;

pub const Row = struct {
    cells: []const Cell,
    hlines_before: u8 = 0,
    gap_after: f32 = 0,
};

pub const Col = struct {
    align_: Align,
    rules_before: u8 = 0,
};

pub const ArrayKind = enum {
    array,
    matrix,
    pmatrix,
    bmatrix,
    bbmatrix,
    vmatrix,
    vvmatrix,
    smallmatrix,
    subarray,
    cases,
    aligned,
    gathered,
    align_eq,
    gather,
    split,
    multline,
    eqnarray,
    eqalign,
    displaylines,
    cd,
};

pub const Array = struct {
    kind: ArrayKind,
    rows: []const Row,
    cols: []const Col,
    trailing_rules: u8 = 0,
    trailing_hlines: u8 = 0,
    open: ?u21 = null,
    close: ?u21 = null,
    cell_style: Style = .text,
    col_gap: [2]f32 = .{ 1, 1 },
    row_gap: f32 = 1.0 / 3.0,
    col_align: [2]Align = .{ .c, .c },
    cols_repeat: bool = false,
};

pub const Node = union(enum) {
    atom: Atom,
    number: []const u8,
    group: Group,
    op: Op,
    supsub: SupSub,
    frac: Frac,
    sqrt: Sqrt,
    fenced: Fenced,
    middle: ?u21,
    big: Big,
    accent: Accent,
    line: Line,
    stack: Stack,
    xarrow: XArrow,
    text: Text,
    font: Styled,
    size: Sized,
    style: Styled2,
    color: Colored,
    space: Space,
    phantom: Phantom,
    rule: Rule,
    enclose: Enclose,
    mathchoice: MathChoice,
    negate: *const Node,
    array: Array,
    shift: Shift,
    lap: Lap,
    vcenter: []const Node,
    nonscript,
    multiscripts: Multiscripts,
    varrow: VArrow,
    link: Link,
    undefined_cs: []const u8,
    parse_error: []const u8,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: []const Node,
    err: ?[]const u8,
    /// Deepest stack distance between nesting levels seen while parsing, in bytes.
    stack_span: usize = 0,

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
    }
};

pub const Caps = struct {
    max_source: usize = 64 * 1024,
    max_depth: u32 = 50,
    max_macros: u32 = 1000,
    max_buffer: usize = 5 * 1024,
    max_expansions: u32 = 10_000,
    max_tokens: usize = 100_000,
    max_nodes: u32 = 50_000,
    max_cells: u32 = 10_000,
};

pub fn dump(a: std.mem.Allocator, nodes: []const Node) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try dumpList(a, &out, nodes);
    return out.toOwnedSlice(a);
}

fn put(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.appendSlice(a, s);
}

fn putCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try put(a, out, "?");
        return;
    };
    try put(a, out, buf[0..n]);
}

fn dumpList(a: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Node) std.mem.Allocator.Error!void {
    for (nodes, 0..) |n, i| {
        if (i != 0) try put(a, out, " ");
        try dumpNode(a, out, n);
    }
}

fn dumpOpt(a: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, nodes: ?[]const Node) std.mem.Allocator.Error!void {
    const n = nodes orelse return;
    try put(a, out, " ");
    try put(a, out, tag);
    try put(a, out, "[");
    try dumpList(a, out, n);
    try put(a, out, "]");
}

fn dumpDelim(a: std.mem.Allocator, out: *std.ArrayList(u8), d: ?u21) !void {
    if (d) |c| try putCp(a, out, c) else try put(a, out, ".");
}

fn dumpNode(a: std.mem.Allocator, out: *std.ArrayList(u8), n: Node) std.mem.Allocator.Error!void {
    switch (n) {
        .atom => |x| {
            try putCp(a, out, x.cp);
            if (x.class != .ord) {
                try put(a, out, ":");
                try put(a, out, @tagName(x.class));
            }
        },
        .number => |s| try put(a, out, s),
        .group => |g| {
            try put(a, out, "(");
            if (g.class) |c| {
                try put(a, out, @tagName(c));
                try put(a, out, " ");
            }
            try dumpList(a, out, g.body);
            try put(a, out, ")");
        },
        .op => |o| {
            try put(a, out, "(op:");
            try put(a, out, @tagName(o.limits));
            if (o.large) try put(a, out, ":large");
            try put(a, out, " ");
            try dumpList(a, out, o.body);
            try put(a, out, ")");
        },
        .supsub => |s| {
            try put(a, out, "(ss ");
            try dumpNode(a, out, s.base.*);
            try dumpOpt(a, out, "^", s.sup);
            try dumpOpt(a, out, "_", s.sub);
            if (s.limits != .side) {
                try put(a, out, " ");
                try put(a, out, @tagName(s.limits));
            }
            try put(a, out, ")");
        },
        .frac => |f| {
            try put(a, out, "(frac");
            if (f.thickness) |t| try out.print(a, ":{d}", .{t});
            if (f.style) |s| {
                try put(a, out, ":");
                try put(a, out, @tagName(s));
            }
            if (f.open != null or f.close != null) {
                try put(a, out, ":");
                try dumpDelim(a, out, f.open);
                try dumpDelim(a, out, f.close);
            }
            try put(a, out, " [");
            try dumpList(a, out, f.num);
            try put(a, out, "] [");
            try dumpList(a, out, f.den);
            try put(a, out, "])");
        },
        .sqrt => |s| {
            try put(a, out, "(sqrt");
            try dumpOpt(a, out, "n", s.index);
            try put(a, out, " ");
            try dumpList(a, out, s.body);
            try put(a, out, ")");
        },
        .fenced => |f| {
            try put(a, out, "(fenced ");
            try dumpDelim(a, out, f.open);
            try dumpDelim(a, out, f.close);
            try put(a, out, " ");
            try dumpList(a, out, f.body);
            try put(a, out, ")");
        },
        .middle => |d| {
            try put(a, out, "(mid ");
            try dumpDelim(a, out, d);
            try put(a, out, ")");
        },
        .big => |b| {
            try out.print(a, "(big{d}:{s} ", .{ b.size, @tagName(b.class) });
            try dumpDelim(a, out, b.cp);
            try put(a, out, ")");
        },
        .accent => |x| {
            try put(a, out, "(accent ");
            try putCp(a, out, x.cp);
            if (x.wide) try put(a, out, ":wide");
            try put(a, out, " ");
            try dumpList(a, out, x.base);
            try put(a, out, ")");
        },
        .line => |l| {
            try put(a, out, if (l.over) "(overline " else "(underline ");
            try dumpList(a, out, l.body);
            try put(a, out, ")");
        },
        .stack => |s| {
            try put(a, out, "(stack");
            if (s.brace) try put(a, out, ":brace");
            if (s.over_cp != 0) {
                try put(a, out, " ^");
                try putCp(a, out, s.over_cp);
            }
            if (s.under_cp != 0) {
                try put(a, out, " _");
                try putCp(a, out, s.under_cp);
            }
            try dumpOpt(a, out, "^", s.over);
            try dumpOpt(a, out, "_", s.under);
            try put(a, out, " ");
            try dumpList(a, out, s.base);
            try put(a, out, ")");
        },
        .xarrow => |x| {
            try put(a, out, "(xarrow ");
            try putCp(a, out, x.cp);
            try dumpOpt(a, out, "^", x.over);
            try dumpOpt(a, out, "_", x.under);
            try put(a, out, ")");
        },
        .text => |t| {
            try put(a, out, "(text");
            if (t.font != .default) {
                try put(a, out, ":");
                try put(a, out, @tagName(t.font));
            }
            try put(a, out, " \"");
            try put(a, out, t.str);
            try put(a, out, "\")");
        },
        .font => |f| try dumpWrap(a, out, @tagName(f.font), f.body),
        .size => |f| {
            try out.print(a, "(size:{d} ", .{f.scale});
            try dumpList(a, out, f.body);
            try put(a, out, ")");
        },
        .style => |f| try dumpWrap(a, out, @tagName(f.style), f.body),
        .color => |f| {
            try out.print(a, "(color:{s} ", .{f.color.name});
            try dumpList(a, out, f.body);
            try put(a, out, ")");
        },
        .space => |s| try out.print(a, "(sp {d})", .{s.width}),
        .phantom => |p| {
            try out.print(a, "(phantom{s}{s}{s}{s} ", .{
                if (p.visible) ":vis" else "",
                if (p.w) ":w" else "",
                if (p.h) ":h" else "",
                if (p.d) ":d" else "",
            });
            try dumpList(a, out, p.body);
            try put(a, out, ")");
        },
        .rule => |r| try out.print(a, "(rule {d} {d} {d})", .{ r.w, r.h, r.d }),
        .enclose => |e| {
            try put(a, out, if (e.border) "(box" else "(bg");
            if (e.bg) |c| try out.print(a, ":{s}", .{c.name});
            try put(a, out, " ");
            try dumpList(a, out, e.body);
            try put(a, out, ")");
        },
        .shift => |x| {
            try out.print(a, "(shift {d} {d} ", .{ x.dx, x.dy });
            try dumpList(a, out, x.body);
            try put(a, out, ")");
        },
        .lap => |x| try dumpWrap(a, out, if (x.left) "llap" else "rlap", x.body),
        .vcenter => |x| try dumpWrap(a, out, "vcenter", x),
        .nonscript => try put(a, out, "(nonscript)"),
        .link => |l| {
            try out.print(a, "(link:{s} ", .{l.url});
            try dumpList(a, out, l.body);
            try put(a, out, ")");
        },
        .multiscripts => |m| {
            try put(a, out, "(multiscripts");
            try dumpOpt(a, out, "<_", m.pre_sub);
            try dumpOpt(a, out, "<^", m.pre_sup);
            try dumpOpt(a, out, ">_", m.post_sub);
            try dumpOpt(a, out, ">^", m.post_sup);
            try put(a, out, " ");
            try dumpList(a, out, m.base);
            try put(a, out, ")");
        },
        .varrow => |v| {
            try put(a, out, "(varrow ");
            try putCp(a, out, v.cp);
            try dumpOpt(a, out, "<", v.left);
            try dumpOpt(a, out, ">", v.right);
            try put(a, out, ")");
        },
        .mathchoice => |m| {
            try put(a, out, "(choice [");
            try dumpList(a, out, m.d);
            try put(a, out, "] [");
            try dumpList(a, out, m.t);
            try put(a, out, "] [");
            try dumpList(a, out, m.s);
            try put(a, out, "] [");
            try dumpList(a, out, m.ss);
            try put(a, out, "])");
        },
        .negate => |b| {
            try put(a, out, "(not ");
            try dumpNode(a, out, b.*);
            try put(a, out, ")");
        },
        .array => |arr| {
            try put(a, out, "(");
            try put(a, out, @tagName(arr.kind));
            if (arr.open != null or arr.close != null) {
                try put(a, out, ":");
                try dumpDelim(a, out, arr.open);
                try dumpDelim(a, out, arr.close);
            }
            for (arr.rows) |row| {
                try put(a, out, " |");
                for (row.cells, 0..) |cell, i| {
                    if (i != 0) try put(a, out, " &");
                    try put(a, out, " ");
                    try dumpList(a, out, cell);
                }
            }
            try put(a, out, ")");
        },
        .undefined_cs => |s| {
            try put(a, out, "(undef ");
            try put(a, out, s);
            try put(a, out, ")");
        },
        .parse_error => |s| {
            try put(a, out, "(error \"");
            try put(a, out, s);
            try put(a, out, "\")");
        },
    }
}

fn dumpWrap(a: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, body: []const Node) std.mem.Allocator.Error!void {
    try put(a, out, "(");
    try put(a, out, tag);
    try put(a, out, " ");
    try dumpList(a, out, body);
    try put(a, out, ")");
}
