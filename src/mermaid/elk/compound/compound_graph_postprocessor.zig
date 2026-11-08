const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");
const che = @import("cross_hierarchy_edge.zig");
const CrossHierarchyEdge = che.CrossHierarchyEdge;

// OrthogonalRoutingGenerator.TOLERANCE
const tolerance = 1e-3;

// CompoundGraphPostprocessor
pub fn process(g: *lg.LGraph, map: *const che.CrossHierarchyMap) lg.Error!void {
    const a = g.a;
    const add_unnecessary = g.p.unnecessary_bendpoints;
    var dummy_edges: std.ArrayList(*lg.LEdge) = .empty;
    for (map.keys.items, 0..) |orig, ki| {
        const segs = try a.dupe(CrossHierarchyEdge, map.values.items[ki].items);
        che.sortSegments(g, segs);
        const source_port = segs[0].actualSource();
        const target_port = segs[segs.len - 1].actualTarget();
        const reference_node = source_port.owner.?;
        const reference_graph = if (gu.isDescendant(target_port.owner.?, reference_node)) reference_node.nested_graph.? else reference_node.graph.?;

        // clearJunctionPoints
        var any_jp = false;
        for (segs) |s| if (s.edge.p.junction_points.items.len > 0) {
            any_jp = true;
        };
        orig.p.junction_points = .empty;
        orig.bend_points.clearRetainingCapacity();

        var last_point: ?lg.Vec = null;
        for (segs) |seg| {
            var offset: lg.Vec = .{};
            gu.changeCoordSystem(&offset, seg.graph, reference_graph);
            const le = seg.edge;
            const bends = try a.dupe(lg.Vec, le.bend_points.items);
            for (bends) |*b| b.add(offset);
            var sp = le.source.?.absoluteAnchor();
            var tp = le.target.?.absoluteAnchor();
            sp.add(offset);
            tp.add(offset);
            if (last_point) |lp| {
                const next = if (bends.len == 0) tp else bends[0];
                const x_diff = @abs(lp.x - next.x) > tolerance;
                const y_diff = @abs(lp.y - next.y) > tolerance;
                if ((!add_unnecessary and x_diff and y_diff) or (add_unnecessary and (x_diff or y_diff))) {
                    try orig.bend_points.append(a, sp);
                }
            }
            try orig.bend_points.appendSlice(a, bends);
            last_point = if (bends.len == 0) sp else bends[bends.len - 1];
            if (any_jp) {
                for (le.p.junction_points.items) |jp| {
                    var c = jp;
                    c.add(offset);
                    try orig.p.junction_points.append(a, c);
                }
            }
            if (seg.actualTarget() == target_port) {
                if (target_port.owner.?.graph.? != seg.graph) {
                    offset = .{};
                    gu.changeCoordSystem(&offset, target_port.owner.?.graph.?, reference_graph);
                }
                orig.p.target_offset = offset;
            }
            // copyLabelsBack
            var i: usize = 0;
            while (i < le.labels.items.len) {
                const label = le.labels.items[i];
                if (label.p.original_label_edge != orig) {
                    i += 1;
                    continue;
                }
                gu.changeCoordSystem(&label.pos, le.source.?.owner.?.graph.?, reference_graph);
                _ = le.labels.orderedRemove(i);
                try orig.labels.append(a, label);
            }
            if (std.mem.indexOfScalar(*lg.LEdge, dummy_edges.items, le) == null) try dummy_edges.append(a, le);
        }
        try orig.setSource(source_port);
        try orig.setTarget(target_port);
    }
    for (dummy_edges.items) |d| {
        try d.setSource(null);
        try d.setTarget(null);
    }
}
