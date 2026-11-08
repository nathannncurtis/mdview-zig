const std = @import("std");
const Allocator = std.mem.Allocator;

// Mermaid dark theme @ 12.2.0; integration fills these from theme variables.
pub const Palette = struct {
    font_family: []const u8 = "\"trebuchet ms\",verdana,arial,sans-serif",
    font_size: []const u8 = "16px",
    text_color: []const u8 = "#ccc",
    error_bkg: []const u8 = "#a44141",
    error_text: []const u8 = "#ddd",
    line_color: []const u8 = "lightgrey",
    stroke_width: []const u8 = "1",
    node_border: []const u8 = "#ccc",
    main_bkg: []const u8 = "#1f2020",
    node_text_color: []const u8 = "#ccc",
    arrowhead_color: []const u8 = "lightgrey",
    edge_label_background: []const u8 = "hsl(0, 0%, 34.4117647059%)",
    edge_label_bkg_fade: []const u8 = "rgba(87.75, 87.75, 87.75, 0.5)",
    cluster_bkg: []const u8 = "hsl(180, 1.5873015873%, 28.3529411765%)",
    cluster_border: []const u8 = "rgba(255, 255, 255, 0.25)",
    title_color: []const u8 = "#F9FFFE",
    tertiary_color: []const u8 = "hsl(20, 1.5873015873%, 12.3529411765%)",
    border2: []const u8 = "rgba(255, 255, 255, 0.25)",
    drop_shadow: []const u8 = "drop-shadow( 1px 2px 2px rgba(185,185,185,1))",
    use_gradient: bool = true,
};

pub const ClassDef = struct {
    id: []const u8,
    styles: []const []const u8 = &.{},
    text_styles: []const []const u8 = &.{},
};

const template =
    "#$id${font-family:$font_family$;font-size:$font_size$;fill:$text_color$;}" ++
    "@keyframes edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}" ++
    "#$id$ .edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear infinite;stroke-linecap:round;}" ++
    "#$id$ .edge-animation-fast{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}" ++
    "#$id$ .error-icon{fill:$error_bkg$;}#$id$ .error-text{fill:$error_text$;stroke:$error_text$;}" ++
    "#$id$ .edge-thickness-normal{stroke-width:$stroke_width$px;}#$id$ .edge-thickness-thick{stroke-width:3.5px;}" ++
    "#$id$ .edge-pattern-solid{stroke-dasharray:0;}#$id$ .edge-thickness-invisible{stroke-width:0;fill:none;}" ++
    "#$id$ .edge-pattern-dashed{stroke-dasharray:3;}#$id$ .edge-pattern-dotted{stroke-dasharray:2;}" ++
    "#$id$ .marker{fill:$line_color$;stroke:$line_color$;}#$id$ .marker.cross{stroke:$line_color$;}" ++
    "#$id$ svg{font-family:$font_family$;font-size:$font_size$;}#$id$ p{margin:0;}" ++
    "#$id$ .label{font-family:$font_family$;color:$node_text_color$;}" ++
    "#$id$ .cluster-label text{fill:$title_color$;}#$id$ .cluster-label span{color:$title_color$;}" ++
    "#$id$ .cluster-label span p{background-color:transparent;}" ++
    "#$id$ .label text,#$id$ span{fill:$node_text_color$;color:$node_text_color$;}" ++
    "#$id$ .node rect,#$id$ .node circle,#$id$ .node ellipse,#$id$ .node polygon,#$id$ .node path{fill:$main_bkg$;stroke:$node_border$;stroke-width:$stroke_width$px;}" ++
    "#$id$ .rough-node .label text,#$id$ .node .label text,#$id$ .image-shape .label,#$id$ .icon-shape .label{text-anchor:middle;}" ++
    "#$id$ .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}" ++
    "#$id$ .rough-node .label,#$id$ .node .label,#$id$ .image-shape .label,#$id$ .icon-shape .label{text-align:center;}" ++
    "#$id$ .node.clickable{cursor:pointer;}" ++
    "#$id$ .root .anchor path{fill:$line_color$!important;stroke-width:0;stroke:$line_color$;}" ++
    "#$id$ .arrowheadPath{fill:$arrowhead_color$;}" ++
    "#$id$ .edgePaths .path{stroke:$line_color$;stroke-width:$stroke_width$px;}" ++
    "#$id$ .flowchart-link{stroke:$line_color$;fill:none;}" ++
    "#$id$ .edgeLabel{background-color:$edge_label_background$;text-align:center;}" ++
    "#$id$ .edgeLabel p{background-color:$edge_label_background$;}" ++
    "#$id$ .edgeLabel rect{opacity:0.5;background-color:$edge_label_background$;fill:$edge_label_background$;}" ++
    "#$id$ .labelBkg{background-color:$edge_label_bkg_fade$;}" ++
    "#$id$ .cluster rect{fill:$cluster_bkg$;stroke:$cluster_border$;stroke-width:1px;}" ++
    "#$id$ .cluster text{fill:$title_color$;}#$id$ .cluster span{color:$title_color$;}" ++
    "#$id$ .node .collapsed-indicator{fill:$cluster_border$;stroke:none;opacity:0.6;}" ++
    "#$id$ .node .collapsed-separator{stroke:$cluster_border$;stroke-width:0.75px;}" ++
    "#$id$ div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:$font_family$;font-size:12px;background:$tertiary_color$;border:1px solid $border2$;border-radius:2px;pointer-events:none;z-index:100;}" ++
    "#$id$ .flowchartTitleText{text-anchor:middle;font-size:18px;fill:$text_color$;}" ++
    "#$id$ rect.text{fill:none;stroke-width:0;}" ++
    "#$id$ .icon-shape,#$id$ .image-shape{background-color:$edge_label_background$;text-align:center;}" ++
    "#$id$ .icon-shape p,#$id$ .image-shape p{background-color:$edge_label_background$;padding:2px;}" ++
    "#$id$ .icon-shape .label rect,#$id$ .image-shape .label rect{opacity:0.5;background-color:$edge_label_background$;fill:$edge_label_background$;}" ++
    "#$id$ .label-icon{display:inline-block;height:1em;overflow:visible;vertical-align:-0.125em;}" ++
    "#$id$ .node .label-icon path{fill:currentColor;stroke:revert;stroke-width:revert;}" ++
    "#$id$ .node .neo-node{stroke:$node_border$;}" ++
    "#$id$ [data-look=\"neo\"].node rect,#$id$ [data-look=\"neo\"].cluster rect,#$id$ [data-look=\"neo\"].node polygon{stroke:$neo_stroke$;filter:$neo_filter$;}" ++
    "#$id$ [data-look=\"neo\"].swimlane.cluster rect{filter:none;}" ++
    "#$id$ [data-look=\"neo\"].node path{stroke:$neo_stroke$;stroke-width:$stroke_width$px;}" ++
    "#$id$ [data-look=\"neo\"].node .outer-path{filter:$neo_filter$;}" ++
    "#$id$ [data-look=\"neo\"].node .neo-line path{stroke:$node_border$;filter:none;}" ++
    "#$id$ [data-look=\"neo\"].node circle{stroke:$neo_stroke$;filter:$neo_filter$;}" ++
    "#$id$ [data-look=\"neo\"].node circle .state-start{fill:#000000;}" ++
    "#$id$ [data-look=\"neo\"].icon-shape .icon{fill:$neo_stroke$;filter:$neo_filter$;}" ++
    "#$id$ [data-look=\"neo\"].icon-shape .icon-neo path{stroke:$neo_stroke$;filter:$neo_filter$;}" ++
    "#$id$ :root{--mermaid-font-family:$font_family$;}";

const Extra = struct { id: []const u8, neo_stroke: []const u8, neo_filter: []const u8 };

fn value(p: Palette, x: Extra, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "id")) return x.id;
    if (std.mem.eql(u8, key, "neo_stroke")) return x.neo_stroke;
    if (std.mem.eql(u8, key, "neo_filter")) return x.neo_filter;
    inline for (comptime std.meta.fieldNames(Palette)) |name| {
        if (@TypeOf(@field(p, name)) == []const u8 and std.mem.eql(u8, key, name)) return @field(p, name);
    }
    return "";
}

fn importantRule(out: *std.ArrayList(u8), a: Allocator, id: []const u8, cls: []const u8, el: []const u8, rules: []const []const u8, text: bool) Allocator.Error!void {
    try out.appendSlice(a, "#");
    try out.appendSlice(a, id);
    try out.appendSlice(a, " .");
    try out.appendSlice(a, cls);
    if (!std.mem.eql(u8, el, "> *") or true) {
        try out.appendSlice(a, if (std.mem.eql(u8, el, "> *")) ">*" else " ");
        if (!std.mem.eql(u8, el, "> *")) try out.appendSlice(a, el);
    }
    try out.append(a, '{');
    for (rules) |r| {
        const colon = std.mem.indexOfScalar(u8, r, ':') orelse continue;
        const k = std.mem.trim(u8, r[0..colon], " ");
        const v = std.mem.trim(u8, r[colon + 1 ..], " ");
        try out.appendSlice(a, if (text and std.mem.eql(u8, k, "color")) "fill" else k);
        try out.append(a, ':');
        try out.appendSlice(a, v);
        try out.appendSlice(a, " !important;");
    }
    try out.append(a, '}');
}

pub fn build(a: Allocator, p: Palette, id: []const u8, class_defs: []const ClassDef) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const x: Extra = .{
        .id = id,
        .neo_stroke = if (p.use_gradient) try std.fmt.allocPrint(a, "url({s}-gradient)", .{id}) else p.node_border,
        .neo_filter = if (p.drop_shadow.len == 0) "none" else try std.mem.replaceOwned(u8, a, p.drop_shadow, "url(#drop-shadow)", try std.fmt.allocPrint(a, "url({s}-drop-shadow)", .{id})),
    };
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$') {
            const end = std.mem.indexOfScalarPos(u8, template, i + 1, '$') orelse break;
            try out.appendSlice(a, value(p, x, template[i + 1 .. end]));
            i = end + 1;
        } else {
            try out.append(a, template[i]);
            i += 1;
        }
    }
    for (class_defs) |cd| {
        if (cd.styles.len > 0) {
            try importantRule(&out, a, id, cd.id, "> *", cd.styles, false);
            try importantRule(&out, a, id, cd.id, "span", cd.styles, false);
        }
        if (cd.text_styles.len > 0) try importantRule(&out, a, id, cd.id, "tspan", cd.text_styles, true);
    }
    return out.items;
}

test "build substitutes the id and palette" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const css = try build(arena.allocator(), .{}, "my-svg", &.{.{ .id = "hot", .styles = &.{"fill:#f00"} }});
    try std.testing.expect(std.mem.startsWith(u8, css, "#my-svg{font-family:\"trebuchet ms\""));
    try std.testing.expect(std.mem.indexOf(u8, css, "#my-svg .hot>*{fill:#f00 !important;}") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, css, '$') == null);
}
