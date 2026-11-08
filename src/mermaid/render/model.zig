const std = @import("std");
const dom = @import("dom.zig");
const Allocator = std.mem.Allocator;

pub const Point = struct { x: f64, y: f64 };
pub const Box = dom.Box;
pub const El = dom.El;

pub const FontSpec = struct {
    family: []const u8 = "\"trebuchet ms\", verdana, arial, sans-serif",
    size: f64 = 16,
    bold: bool = false,
    italic: bool = false,
};

// Stub of the core lane's Measurer (text.zig). Replace by an alias on rebase.
pub const Measurer = struct {
    ctx: *anyopaque,
    widthFn: *const fn (ctx: *anyopaque, text: []const u8, font: FontSpec) f64,
    metricsFn: ?*const fn (ctx: *anyopaque, font: FontSpec) [2]f64 = null,

    pub fn width(self: Measurer, text: []const u8, font: FontSpec) f64 {
        return self.widthFn(self.ctx, text, font);
    }

    // Chrome rounds SVG text ascent and descent to whole pixels; defaults are Trebuchet MS (1923 and 455 per 2048 em).
    pub fn ascentDescent(self: Measurer, font: FontSpec) [2]f64 {
        const raw = if (self.metricsFn) |f| f(self.ctx, font) else [2]f64{ 1923.0 / 2048.0 * font.size, 455.0 / 2048.0 * font.size };
        return .{ @floor(raw[0] + 0.5), @floor(raw[1] + 0.5) };
    }
};

pub const SubGraphTitleMargin = struct { top: f64 = 0, bottom: f64 = 0 };

// The slice of the Mermaid config the flowchart port reads (config.schema.yaml defaults @ 12.2.0).
pub const Config = struct {
    font_family: []const u8 = "\"trebuchet ms\", verdana, arial, sans-serif",
    font_size: f64 = 16,
    node_spacing: f64 = 50,
    rank_spacing: f64 = 50,
    curve: []const u8 = "basis",
    padding: f64 = 15,
    diagram_padding: f64 = 8,
    wrapping_width: f64 = 120,
    min_node_width: f64 = 120,
    title_top_margin: f64 = 25,
    use_max_width: bool = true,
    html_labels: bool = true,
    node_html_labels: bool = true,
    label_bold: bool = false,
    label_italic: bool = false,
    dark_theme: bool = true,
    node_border: []const u8 = "#ccc",
    cluster_bkg: []const u8 = "hsl(180, 1.5873015873%, 28.3529411765%)",
    cluster_border: []const u8 = "rgba(255, 255, 255, 0.25)",
    use_gradient: bool = true,
    gradient_start: []const u8 = "#cccccc",
    gradient_stop: []const u8 = "hsl(180, 0%, 18.3529411765%)",
    inherit_dir: bool = false,
    look: []const u8 = "neo",
    layout: []const u8 = "elk",
    sub_graph_title_margin: SubGraphTitleMargin = .{},
    max_edges: usize = 500,
    max_text_size: usize = 50000,
    security_level: []const u8 = "strict",
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
    config: Config = .{},
    title: ?[]const u8 = null,
};

test {
    _ = dom;
}

pub const Ctx = struct {
    a: Allocator,
    measurer: Measurer,
    cfg: *const Config,
    diagram_id: []const u8,
};
