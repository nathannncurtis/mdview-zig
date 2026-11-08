// LabelDummySwitcher, MEDIAN_LAYER strategy (ELK's default; Mermaid sets no other). Props: Layer.id (written),
// represented_labels, long_edge_before_label_dummy (written on long edge dummies).
const std = @import("std");
const lg = @import("../lgraph.zig");

const LabelDummyInfo = struct {
    label_dummy: *lg.LNode,
    left_long_edge_dummies: []*lg.LNode,
    right_long_edge_dummies: []*lg.LNode,
    leftmost_layer_id: i32,
    rightmost_layer_id: i32,

    fn init(a: std.mem.Allocator, label_dummy: *lg.LNode) lg.Error!LabelDummyInfo {
        var left: std.ArrayList(*lg.LNode) = .empty;
        var source = label_dummy;
        while (true) {
            source = firstIncoming(source).source.?.owner.?;
            if (source.type != .long_edge) break;
            try left.append(a, source);
        }
        std.mem.reverse(*lg.LNode, left.items);

        var right: std.ArrayList(*lg.LNode) = .empty;
        var target = label_dummy;
        while (true) {
            target = firstOutgoing(target).target.?.owner.?;
            if (target.type != .long_edge) break;
            try right.append(a, target);
        }

        const own = label_dummy.layer.?.id;
        return .{
            .label_dummy = label_dummy,
            .left_long_edge_dummies = left.items,
            .right_long_edge_dummies = right.items,
            .leftmost_layer_id = if (left.items.len == 0) own else left.items[0].layer.?.id,
            .rightmost_layer_id = if (right.items.len == 0) own else right.items[right.items.len - 1].layer.?.id,
        };
    }

    fn totalDummyCount(self: *const LabelDummyInfo) i32 {
        return self.rightmost_layer_id - self.leftmost_layer_id + 1;
    }

    fn ithDummyNode(self: *const LabelDummyInfo, i: usize) *lg.LNode {
        const nl = self.left_long_edge_dummies.len;
        if (i < nl) return self.left_long_edge_dummies[i];
        if (i == nl) return self.label_dummy;
        return self.right_long_edge_dummies[i - nl - 1];
    }
};

fn firstIncoming(n: *lg.LNode) *lg.LEdge {
    for (n.ports.items) |p| if (p.incoming.items.len > 0) return p.incoming.items[0];
    unreachable;
}

fn firstOutgoing(n: *lg.LNode) *lg.LEdge {
    for (n.ports.items) |p| if (p.outgoing.items.len > 0) return p.outgoing.items[0];
    unreachable;
}

fn firstInputPort(n: *lg.LNode) *lg.LPort {
    for (n.ports.items) |p| if (p.incoming.items.len > 0) return p;
    unreachable;
}

fn firstOutputPort(n: *lg.LNode) *lg.LPort {
    for (n.ports.items) |p| if (p.outgoing.items.len > 0) return p;
    unreachable;
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    const a = g.a;
    for (g.layers.items, 0..) |layer, i| layer.id = @intCast(i);

    var infos: std.ArrayList(LabelDummyInfo) = .empty;
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type == .label) try infos.append(a, try LabelDummyInfo.init(a, node));
        }
    }

    for (infos.items) |*info| {
        const lower_median = @divTrunc(info.totalDummyCount() - 1, 2);
        try assignLayer(info, info.leftmost_layer_id + lower_median);
        updateLongEdgeSourceLabelDummyInfo(info);
    }
}

fn assignLayer(info: *const LabelDummyInfo, target_layer_index: i32) lg.Error!void {
    const current = info.leftmost_layer_id + @as(i32, @intCast(info.left_long_edge_dummies.len));
    if (target_layer_index != current) {
        try swapNodes(info.label_dummy, info.ithDummyNode(@intCast(target_layer_index - info.leftmost_layer_id)));
    }
}

fn swapNodes(label_dummy: *lg.LNode, long_edge_dummy: *lg.LNode) lg.Error!void {
    const a = label_dummy.a;
    const layer1 = label_dummy.layer.?;
    const layer2 = long_edge_dummy.layer.?;
    const pos1 = label_dummy.index();
    const pos2 = long_edge_dummy.index();

    const input1 = firstInputPort(label_dummy);
    const output1 = firstOutputPort(label_dummy);
    const input2 = firstInputPort(long_edge_dummy);
    const output2 = firstOutputPort(long_edge_dummy);

    const incoming1 = try a.dupe(*lg.LEdge, input1.incoming.items);
    const outgoing1 = try a.dupe(*lg.LEdge, output1.outgoing.items);
    const incoming2 = try a.dupe(*lg.LEdge, input2.incoming.items);
    const outgoing2 = try a.dupe(*lg.LEdge, output2.outgoing.items);

    try label_dummy.setLayerAt(pos2, layer2);
    for (incoming2) |e| try e.setTarget(input1);
    for (outgoing2) |e| try e.setSource(output1);

    try long_edge_dummy.setLayerAt(pos1, layer1);
    for (incoming1) |e| try e.setTarget(input2);
    for (outgoing1) |e| try e.setSource(output2);
}

fn updateLongEdgeSourceLabelDummyInfo(info: *const LabelDummyInfo) void {
    var long_edge_dummy = firstIncoming(info.label_dummy).source.?.owner.?;
    while (long_edge_dummy.type == .long_edge) {
        long_edge_dummy.p.long_edge_before_label_dummy = true;
        long_edge_dummy = firstIncoming(long_edge_dummy).source.?.owner.?;
    }
}
