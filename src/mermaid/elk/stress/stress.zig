const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const nls = @import("../graph/node_label_size.zig");
const force = @import("../force/force.zig");
const fg = @import("fgraph.zig");
const Majorization = @import("majorization.zig").Majorization;

// StressLayoutProvider.layout. Without `interactive` the node positions start from the force layout, which also
// runs the node micro layout.
pub fn layout(a: std.mem.Allocator, node: *eg.ElkNode) lg.Error!void {
    if (!(node.opts.interactive orelse false)) {
        try force.layout(a, node);
    } else if (!(node.opts.omit_node_micro_layout orelse false)) {
        for (node.children.items) |c| {
            const size = nls.minimumNodeSize(c);
            c.width = size.x;
            c.height = size.y;
        }
    }
    var graph = try fg.importGraph(a, node);
    const comps = try fg.split(a, &graph);
    for (comps) |comp| {
        if (comp.nodes.items.len <= 1) continue;
        var m = try Majorization.init(a, comp);
        m.execute();
        for (comp.labels.items) |l| l.refreshPosition();
    }
    const result = try fg.recombine(a, comps);
    try fg.applyLayout(a, result);
}
