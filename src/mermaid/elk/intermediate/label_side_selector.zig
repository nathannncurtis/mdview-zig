// LabelSideSelector, SMART_DOWN (ELK default). Props: label_side, origin, represented_labels, long_edge_source/target,
// edge_labels_inline, edge_thickness, spacing.edge_label.
const std = @import("std");
const lg = @import("../lgraph.zig");
const gu = @import("../graph_util.zig");

// shortcut: smartForRegularNode only assigns sides to TAIL/HEAD end labels, which Mermaid never produces, so it is
// left out; port it with EndLabelPreprocessor if end labels ever become reachable
pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    const default_side: lg.LabelSide = .below;
    var queue: std.ArrayList(*lg.LNode) = .empty;
    for (g.layers.items) |layer| {
        var top_group = true;
        var label_dummies_in_queue: usize = 0;
        for (layer.nodes.items) |node| {
            switch (node.type) {
                .label => {
                    label_dummies_in_queue += 1;
                    try queue.append(a, node);
                },
                .long_edge => try queue.append(a, node),
                else => {
                    if (queue.items.len > 0) {
                        try smartForConsecutiveDummyNodeRun(a, &queue, label_dummies_in_queue, top_group, false, default_side);
                    }
                    top_group = false;
                    label_dummies_in_queue = 0;
                },
            }
        }
        if (queue.items.len > 0) {
            try smartForConsecutiveDummyNodeRun(a, &queue, label_dummies_in_queue, top_group, true, default_side);
        }
    }
}

fn smartForConsecutiveDummyNodeRun(a: std.mem.Allocator, dummies: *std.ArrayList(*lg.LNode), label_dummy_count: usize, top_group: bool, bottom_group: bool, default_side: lg.LabelSide) lg.Error!void {
    const items = dummies.items;
    const first = items[0];
    const last = items[items.len - 1];
    if (top_group and (!bottom_group or items.len > 1) and label_dummy_count == 1 and first.type == .label) {
        applyLabelSide(first, .above);
    } else if (bottom_group and (!top_group or items.len > 1) and label_dummy_count == 1 and last.type == .label) {
        applyLabelSide(last, .below);
    } else if (items.len == 2) {
        applyLabelSide(items[0], .above);
        applyLabelSide(items[1], .below);
    } else {
        try applyForDummyNodeRunWithSimpleLoops(a, items, default_side);
    }
    dummies.clearRetainingCapacity();
}

fn applyForDummyNodeRunWithSimpleLoops(a: std.mem.Allocator, dummies: []*lg.LNode, default_side: lg.LabelSide) lg.Error!void {
    var run: std.ArrayList(*lg.LNode) = .empty;
    var prev_source: ?*lg.LNode = null;
    var prev_target: ?*lg.LNode = null;
    for (dummies) |current| {
        const cur_source = longEdgeEndNode(current, true);
        const cur_target = longEdgeEndNode(current, false);
        if (prev_source != cur_source or prev_target != cur_target) {
            applyLabelSidesToLabelDummyRun(&run, default_side);
            prev_source = cur_source;
            prev_target = cur_target;
        }
        try run.append(a, current);
    }
    applyLabelSidesToLabelDummyRun(&run, default_side);
}

fn longEdgeEndNode(dummy: *const lg.LNode, source: bool) ?*lg.LNode {
    const port = if (source) dummy.p.long_edge_source else dummy.p.long_edge_target;
    return if (port) |p| p.owner else null;
}

fn applyLabelSidesToLabelDummyRun(run: *std.ArrayList(*lg.LNode), default_side: lg.LabelSide) void {
    if (run.items.len == 0) return;
    if (run.items.len == 2) {
        applyLabelSide(run.items[0], .above);
        applyLabelSide(run.items[1], .below);
    } else {
        for (run.items) |d| applyLabelSide(d, default_side);
    }
    run.clearRetainingCapacity();
}

fn applyLabelSide(dummy: *lg.LNode, side: lg.LabelSide) void {
    if (dummy.type != .label) return;
    const effective: lg.LabelSide = if (gu.isInlineEdgeLabel(dummy)) .inline_ else side;
    dummy.p.label_side = effective;
    if (effective == .below) return;
    const thickness = dummy.p.origin.edge.p.edge_thickness;
    var port_pos: f64 = 0;
    if (effective == .above) {
        port_pos = dummy.size.y - @ceil(thickness / 2);
    } else if (effective == .inline_) {
        const edge_label = dummy.graph.?.p.spacing.edge_label;
        port_pos = @ceil(dummy.size.y - edge_label - thickness) / 2.0;
        dummy.size.y -= edge_label;
        dummy.size.y -= thickness;
    }
    for (dummy.ports.items) |p| p.pos.y = port_pos;
}
