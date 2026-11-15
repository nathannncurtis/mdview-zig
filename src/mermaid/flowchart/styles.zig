const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../diagram.zig");
const vars_mod = @import("../theme/vars.zig");
const color = @import("../theme/color.zig");

fn text(a: Allocator, t: *const vars_mod.Vars, name: []const u8) Allocator.Error![]const u8 {
    return (try t.get(name).text(a)) orelse "undefined";
}

/// The flowchart's own rules (`flowchart/styles.ts`), written before the common rules and the user's classDefs.
pub fn css(ctx: *core.Ctx) core.Error![]const u8 {
    const a = ctx.a;
    const t = &ctx.cfg.vars;
    const sw_v = t.get("strokeWidth");
    const stroke_width = if (sw_v == .undef) "1" else try text(a, t, "strokeWidth");
    var scratch: vars_mod.Vars = .{ .a = a };
    const faded = color.fade(&scratch, t.get("edgeLabelBackground"), 0.5) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Layout;
    return std.fmt.allocPrint(a,
        \\.label {{
        \\    font-family: {[ff]s};
        \\    color: {[nt]s};
        \\  }}
        \\  .cluster-label text {{
        \\    fill: {[title]s};
        \\  }}
        \\  .cluster-label span {{
        \\    color: {[title]s};
        \\  }}
        \\  .cluster-label span p {{
        \\    background-color: transparent;
        \\  }}
        \\  .label text,span {{
        \\    fill: {[nt]s};
        \\    color: {[nt]s};
        \\  }}
        \\  .node rect,
        \\  .node circle,
        \\  .node ellipse,
        \\  .node polygon,
        \\  .node path {{
        \\    fill: {[main]s};
        \\    stroke: {[border]s};
        \\    stroke-width: {[sw]s}px;
        \\  }}
        \\  .rough-node .label text, .node .label text, .image-shape .label, .icon-shape .label {{
        \\    text-anchor: middle;
        \\  }}
        \\  .node .katex path {{
        \\    fill: #000;
        \\    stroke: #000;
        \\    stroke-width: 1px;
        \\  }}
        \\  .rough-node .label, .node .label, .image-shape .label, .icon-shape .label {{
        \\    text-align: center;
        \\  }}
        \\  .node.clickable {{
        \\    cursor: pointer;
        \\  }}
        \\  .root .anchor path {{
        \\    fill: {[line]s} !important;
        \\    stroke-width: 0;
        \\    stroke: {[line]s};
        \\  }}
        \\  .arrowheadPath {{
        \\    fill: {[arrow]s};
        \\  }}
        \\  .edgePaths .path {{
        \\    stroke: {[line]s};
        \\    stroke-width: {[sw]s}px;
        \\  }}
        \\  .flowchart-link {{
        \\    stroke: {[line]s};
        \\    fill: none;
        \\  }}
        \\  .edgeLabel {{
        \\    background-color: {[elb]s};
        \\    text-align: center;
        \\  }}
        \\  .edgeLabel p {{
        \\    background-color: {[elb]s};
        \\  }}
        \\  .edgeLabel rect {{
        \\    opacity: 0.5;
        \\    background-color: {[elb]s};
        \\    fill: {[elb]s};
        \\  }}
        \\  .labelBkg {{
        \\    background-color: {[fade]s};
        \\  }}
        \\  .cluster rect {{
        \\    fill: {[cbkg]s};
        \\    stroke: {[cborder]s};
        \\    stroke-width: 1px;
        \\  }}
        \\  .cluster text {{
        \\    fill: {[title]s};
        \\  }}
        \\  .cluster span {{
        \\    color: {[title]s};
        \\  }}
        \\  .node .collapsed-indicator {{
        \\    fill: {[cborder]s};
        \\    stroke: none;
        \\    opacity: 0.6;
        \\  }}
        \\  .node .collapsed-separator {{
        \\    stroke: {[cborder]s};
        \\    stroke-width: 0.75px;
        \\  }}
        \\  div.mermaidTooltip {{
        \\    position: absolute;
        \\    text-align: center;
        \\    max-width: 200px;
        \\    padding: 2px;
        \\    font-family: {[ff]s};
        \\    font-size: 12px;
        \\    background: {[tertiary]s};
        \\    border: 1px solid {[border2]s};
        \\    border-radius: 2px;
        \\    pointer-events: none;
        \\    z-index: 100;
        \\  }}
        \\  .flowchartTitleText {{
        \\    text-anchor: middle;
        \\    font-size: 18px;
        \\    fill: {[tc]s};
        \\  }}
        \\  rect.text {{
        \\    fill: none;
        \\    stroke-width: 0;
        \\  }}
        \\  .icon-shape, .image-shape {{
        \\    background-color: {[elb]s};
        \\    text-align: center;
        \\  }}
        \\  .icon-shape p, .image-shape p {{
        \\    background-color: {[elb]s};
        \\    padding: 2px;
        \\  }}
        \\  .icon-shape .label rect, .image-shape .label rect {{
        \\    opacity: 0.5;
        \\    background-color: {[elb]s};
        \\    fill: {[elb]s};
        \\  }}
        \\  .label-icon {{
        \\    display: inline-block;
        \\    height: 1em;
        \\    overflow: visible;
        \\    vertical-align: -0.125em;
        \\  }}
        \\  .node .label-icon path {{
        \\    fill: currentColor;
        \\    stroke: revert;
        \\    stroke-width: revert;
        \\  }}
        \\
    , .{
        .ff = try text(a, t, "fontFamily"),
        .nt = try text(a, t, "nodeTextColor"),
        .title = try text(a, t, "titleColor"),
        .main = try text(a, t, "mainBkg"),
        .border = try text(a, t, "nodeBorder"),
        .sw = stroke_width,
        .line = try text(a, t, "lineColor"),
        .arrow = try text(a, t, "arrowheadColor"),
        .elb = try text(a, t, "edgeLabelBackground"),
        .fade = (try faded.text(a)) orelse "undefined",
        .cbkg = try text(a, t, "clusterBkg"),
        .cborder = try text(a, t, "clusterBorder"),
        .tertiary = try text(a, t, "tertiaryColor"),
        .border2 = try text(a, t, "border2"),
        .tc = try text(a, t, "textColor"),
    });
}
