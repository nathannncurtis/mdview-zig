const lg = @import("../lgraph.zig");
const BarycenterHeuristic = @import("barycenter_heuristic.zig").BarycenterHeuristic;
const GreedySwitchHeuristic = @import("../intermediate/greedyswitch/greedy_switch_heuristic.zig").GreedySwitchHeuristic;

// ICrossingMinimizationHeuristic
pub const ICrossingMinimizationHeuristic = union(enum) {
    barycenter: *BarycenterHeuristic,
    greedy: *GreedySwitchHeuristic,

    pub fn alwaysImproves(self: ICrossingMinimizationHeuristic) bool {
        return switch (self) {
            .barycenter => false,
            .greedy => |h| h.alwaysImproves(),
        };
    }
    pub fn isDeterministic(self: ICrossingMinimizationHeuristic) bool {
        return switch (self) {
            .barycenter => false,
            .greedy => true,
        };
    }
    pub fn setFirstLayerOrder(self: ICrossingMinimizationHeuristic, order: [][]*lg.LNode, forward: bool) lg.Error!bool {
        return switch (self) {
            inline else => |h| h.setFirstLayerOrder(order, forward),
        };
    }
    pub fn minimizeCrossings(self: ICrossingMinimizationHeuristic, order: [][]*lg.LNode, free: usize, forward: bool, is_first_sweep: bool) lg.Error!bool {
        return switch (self) {
            inline else => |h| h.minimizeCrossings(order, free, forward, is_first_sweep),
        };
    }
};
