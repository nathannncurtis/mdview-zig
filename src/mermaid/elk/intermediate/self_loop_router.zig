// SelfLoopRouter, orthogonal routing only. Props: self_loop_holder (nodes).
const lg = @import("../lgraph.zig");
const sl = @import("loops/self_loop_holder.zig");
const director = @import("loops/routing/routing_director.zig");
const label_placer = @import("loops/routing/label_placer.zig");
const slot_assigner = @import("loops/routing/routing_slot_assigner.zig");
const router = @import("loops/routing/orthogonal_self_loop_router.zig");

pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            if (node.type != .normal) continue;
            const h = sl.SelfLoopHolder.of(node) orelse continue;
            try director.determineLoopRoutes(h);
            try label_placer.placeLabels(h);
            try slot_assigner.assignRoutingSlots(h);
            try router.routeSelfLoops(h);
        }
    }
}
