const std = @import("std");
const dom = @import("dom.zig");
const Allocator = std.mem.Allocator;
const text = @import("../text.zig");
const core_config = @import("../config.zig");
const layout_mod = @import("../layout.zig");

pub const Point = struct { x: f64, y: f64 };
pub const Box = dom.Box;
pub const El = dom.El;

pub const Measurer = text.Measurer;
pub const Font = text.Font;

pub fn font(cfg: *const Config, bold: bool, italic: bool) text.Font {
    return .{ .family = cfg.font_family, .size = @floatCast(cfg.font_size), .weight = if (bold or cfg.label_bold) 700 else 400, .italic = italic or cfg.label_italic };
}

// shortcut: the measurer reports only a line height, so ascent takes Trebuchet's 1923:455 share of it; upgrade when Measurer exposes metrics
pub fn ascentDescent(m: Measurer, f: text.Font) [2]f64 {
    const h: f64 = m.measure("", f).h;
    return .{ @floor(h * 1923.0 / 2378.0 + 0.5), @floor(h * 455.0 / 2378.0 + 0.5) };
}

pub const WidthFn = *const fn (?*anyopaque, []const u8, text.Font) f64;

/// A measurer for tests that takes widths from `f` and heights from the font size.
pub fn widthMeasurer(ctx: ?*anyopaque, comptime f: WidthFn) Measurer {
    const S = struct {
        fn measure(c: ?*anyopaque, t: []const u8, fnt: text.Font) text.Size {
            return .{ .w = @floatCast(f(c, t, fnt)), .h = fnt.size * 1.15 };
        }
    };
    return .{ .ctx = ctx, .measure_fn = S.measure };
}

pub fn testConfig(a: Allocator) Config {
    const site = core_config.setupSite(a, .dark, core_config.github_init) catch @panic("site");
    const c = core_config.current(a, &site, "flowchart", null) catch @panic("config");
    return Config.fromCore(&c);
}

pub const SubGraphTitleMargin = struct { top: f64 = 0, bottom: f64 = 0 };

fn pxSize(s: ?[]const u8) ?f64 {
    const t = s orelse return null;
    return std.fmt.parseFloat(f64, std.mem.trimEnd(u8, t, "px")) catch null;
}

fn isDarkTheme(name: []const u8) bool {
    return std.mem.eql(u8, name, "dark") or std.mem.endsWith(u8, name, "-dark") or std.mem.indexOf(u8, name, "-dark-") != null;
}

pub const Config = struct {
    font_family: []const u8,
    font_size: f64,
    node_spacing: f64,
    rank_spacing: f64,
    curve: []const u8,
    padding: f64,
    diagram_padding: f64,
    wrapping_width: f64,
    min_node_width: f64,
    title_top_margin: f64,
    use_max_width: bool,
    html_labels: bool,
    node_html_labels: bool,
    label_bold: bool = false,
    label_italic: bool = false,
    dark_theme: bool,
    node_border: []const u8,
    cluster_bkg: []const u8,
    cluster_border: []const u8,
    use_gradient: bool,
    gradient_start: []const u8,
    gradient_stop: []const u8,
    inherit_dir: bool,
    look: []const u8,
    sub_graph_title_margin: SubGraphTitleMargin,
    max_edges: usize,
    max_text_size: usize,
    security_level: []const u8,

    /// The values the flowchart code reads, taken from the config Mermaid's core resolved for this diagram.
    pub fn fromCore(c: *const core_config.Config) Config {
        const v = &c.vars;
        // drawn through ELK, node labels follow only the top-level htmlLabels (the references keep them HTML under flowchart.htmlLabels false); edge labels follow flowchart.htmlLabels
        const node_html = if (std.mem.eql(u8, c.str("layout") orelse "", "dagre")) c.htmlLabels() else if (c.get("htmlLabels")) |hv| (hv == .null or core_config.evaluate(hv)) else true;
        return .{
            .font_family = v.str("fontFamily") orelse c.str("fontFamily") orelse text.default_family,
            .font_size = pxSize(v.str("fontSize")) orelse c.num("fontSize") orelse 16,
            .node_spacing = c.num("flowchart.nodeSpacing") orelse 50,
            .rank_spacing = c.num("flowchart.rankSpacing") orelse 50,
            .curve = c.str("flowchart.curve") orelse "basis",
            .padding = c.num("flowchart.padding") orelse 15,
            .diagram_padding = c.num("flowchart.diagramPadding") orelse 8,
            .wrapping_width = c.num("flowchart.wrappingWidth") orelse 120,
            .min_node_width = c.num("flowchart.minNodeWidth") orelse 120,
            .title_top_margin = c.num("flowchart.titleTopMargin") orelse 25,
            .use_max_width = c.boolean("flowchart.useMaxWidth") orelse true,
            .html_labels = c.htmlLabels(),
            .node_html_labels = node_html,
            .dark_theme = v.get("darkMode").truthy() or isDarkTheme(c.str("theme") orelse ""),
            .node_border = v.str("nodeBorder") orelse "",
            .cluster_bkg = v.str("clusterBkg") orelse "",
            .cluster_border = v.str("clusterBorder") orelse "",
            .use_gradient = v.get("useGradient").truthy(),
            .gradient_start = v.str("gradientStart") orelse "",
            .gradient_stop = v.str("gradientStop") orelse "",
            .inherit_dir = c.boolean("flowchart.inheritDir") orelse false,
            .look = c.str("look") orelse "neo",
            .sub_graph_title_margin = .{
                .top = c.num("flowchart.subGraphTitleMargin.top") orelse 0,
                .bottom = c.num("flowchart.subGraphTitleMargin.bottom") orelse 0,
            },
            .max_edges = @intFromFloat(@max(0, c.num("maxEdges") orelse 500)),
            .max_text_size = @intFromFloat(@max(0, c.num("maxTextSize") orelse 50000)),
            .security_level = c.str("securityLevel") orelse "strict",
        };
    }
};

pub const Style = []const u8;

pub const NodeData = struct {
    id: []const u8,
    label: ?[]const u8 = null,
    label_type: []const u8 = "text",
    dom_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    shape: []const u8 = "rect",
    css_styles: []const []const u8 = &.{},
    css_compiled_styles: []const []const u8 = &.{},
    css_classes: []const u8 = "",
    label_style: []const u8 = "",
    dir: ?[]const u8 = null,
    explicit_dir: bool = false,
    min_width: ?f64 = null,
    wrapping_width: ?f64 = null,
    color_index: ?usize = null,
    is_group: bool = false,
    padding: ?f64 = null,
    width: f64 = 0,
    height: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    rx: ?f64 = null,
    ry: ?f64 = null,
    link: ?[]const u8 = null,
    link_target: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    have_callback: bool = false,
    look: []const u8 = "neo",
    icon: ?[]const u8 = null,
    img: ?[]const u8 = null,
    pos: ?u8 = null,
    asset_width: ?f64 = null,
    asset_height: ?f64 = null,
    image_aspect_ratio: ?f64 = null,
    constraint: ?[]const u8 = null,
    // @{ ... } extras copied from flowDb props the shapes read
    form: ?[]const u8 = null,
    // dagre wrapper state
    cluster_node: bool = false,
    diff: f64 = 0,
    offset_y: f64 = 0,
    label_bbox: ?Box = null,
    is_dummy: bool = false,
    is_edge_label: bool = false,
    edge_start: ?[]const u8 = null,
    edge_end: ?[]const u8 = null,
    // shapes write the intersect shape here; see render/intersect.zig
    intersect: ?Intersect = null,
    cluster_data: ?*NodeData = null,
    // sub-layout owned by a cluster node (mermaid-graphlib extraction)
    sub_graph: ?*anyopaque = null,
    // the node's svg group, set by nodes.insertNode
    el: ?*El = null,
};

pub const Intersect = union(enum) {
    rect,
    circle: f64,
    ellipse: struct { rx: f64, ry: f64 },
    polygon: struct { points: []const Point, adjust: Point = .{ .x = 0, .y = 0 } },
    custom: *const fn (node: *const NodeData, p: Point) Point,
};

pub const EdgeData = struct {
    id: []const u8,
    start: []const u8,
    end: []const u8,
    label: ?[]const u8 = null,
    label_type: []const u8 = "text",
    labelpos: []const u8 = "c",
    classes: []const u8 = "",
    style: []const []const u8 = &.{},
    label_style: []const []const u8 = &.{},
    css_compiled_styles: []const []const u8 = &.{},
    arrow_type_start: []const u8 = "none",
    arrow_type_end: []const u8 = "none",
    arrowhead_style: []const u8 = "",
    type: []const u8 = "normal",
    thickness: []const u8 = "normal",
    pattern: []const u8 = "solid",
    minlen: f64 = 1,
    curve: ?[]const u8 = null,
    default_interpolate: ?[]const u8 = null,
    interpolate: ?[]const u8 = null,
    animate: bool = false,
    animation: ?[]const u8 = null,
    is_user_defined_id: bool = false,
    look: []const u8 = "neo",
    start_label_left: ?[]const u8 = null,
    start_label_right: ?[]const u8 = null,
    end_label_left: ?[]const u8 = null,
    end_label_right: ?[]const u8 = null,
    // layout output / wrapper state
    points: []Point = &.{},
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    from_cluster: ?[]const u8 = null,
    to_cluster: ?[]const u8 = null,
    self_loop_id: ?[]const u8 = null,
    self_loop_order: u8 = 0,
    original_edge: ?*EdgeData = null,
    el_label: ?*El = null,
    el_path_label: ?*El = null,
    el_start_label: ?*El = null,
    el_end_label: ?*El = null,
};

pub const LayoutData = struct {
    nodes: []NodeData,
    edges: []EdgeData,
    direction: []const u8 = "TB",
    diagram_id: []const u8 = "mermaid-svg",
    diagram_type: []const u8 = "flowchart-v2",
    config: Config,
    title: ?[]const u8 = null,
};

test {
    _ = dom;
}

/// What the host knows about an image a diagram names; `pending` is a load still under way (size unknown for now).
pub const ImageProbe = union(enum) { size: struct { w: f32, h: f32 }, pending, failed };

pub const Ctx = struct {
    a: Allocator,
    measurer: Measurer,
    cfg: *const Config,
    diagram_id: []const u8,
    image_probe: ?*const fn (href: []const u8) ImageProbe = null,
    /// The engine the diagram's `layout` setting names; anything but dagre takes the flat path.
    layout: layout_mod.Engine = .dagre,
};
