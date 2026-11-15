const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const calc = @import("../nodespacing/node_label_and_size_calculator.zig");
const margins = @import("../nodespacing/node_margin_calculator.zig");
const util = @import("util.zig");

// NodeMicroLayout.forGraph(graph).execute(): label and node sizes, then node margins. Ports are not modelled
// (see graph/node_label_size.zig); the importer rejects nothing here because Mermaid ELK nodes never have ports.
pub fn run(c: *util.Ctx) lg.Error!void {
    const g = c.graph;
    var sp: lg.Props = .{};
    g.opts.applyTo(&sp);
    const horizontal = if (g.opts.direction) |d| d == .undefined or d.isHorizontal() else true;
    const env: calc.Env = .{
        .spacing = sp.spacing,
        .node_labels_padding = g.opts.node_labels_padding orelse .{ .top = 5, .left = 5, .bottom = 5, .right = 5 },
        .fixed_graph_size = g.opts.node_size_fixed_graph_size orelse false,
        .horizontal_layout_mode = horizontal,
    };
    for (g.children.items) |child| {
        const ln = try lg.LNode.init(c.a, null);
        child.opts.applyTo(&ln.p);
        ln.size = .{ .x = child.width, .y = child.height };
        for (child.labels.items) |l| {
            const ll = try lg.LLabel.init(c.a);
            ll.text = l.text;
            l.opts.applyTo(&ll.p);
            ll.size = .{ .x = l.width, .y = l.height };
            ll.pos = .{ .x = l.x, .y = l.y };
            try ln.labels.append(c.a, ll);
        }
        _ = try calc.process(c.a, ln, env, true);
        child.width = ln.size.x;
        child.height = ln.size.y;
        for (child.labels.items, ln.labels.items) |l, ll| {
            l.x = ll.pos.x;
            l.y = ll.pos.y;
        }
        margins.processNode(ln);
        try c.margins.put(c.a, child, ln.margin);
    }
}
