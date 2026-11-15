const std = @import("std");
const lg = @import("../../lgraph.zig");
const CrossMinType = @import("../../p3order/layer_sweep_crossing_minimizer.zig").CrossMinType;
const CrossingCountSide = @import("switch_decider.zig").CrossingCountSide;
const BetweenLayerEdgeTwoNodeCrossingsCounter = @import("between_layer_edge_two_node_crossings_counter.zig").BetweenLayerEdgeTwoNodeCrossingsCounter;

pub const CrossingMatrixFiller = struct {
    is_filled: [][]bool,
    crossing_matrix: [][]i32,
    counter: *BetweenLayerEdgeTwoNodeCrossingsCounter,
    direction: CrossingCountSide,
    one_sided: bool,

    pub fn init(a: std.mem.Allocator, cmt: CrossMinType, graph: [][]*lg.LNode, free_layer_index: usize, direction: CrossingCountSide) lg.Error!CrossingMatrixFiller {
        const n = graph[free_layer_index].len;
        const filled = try a.alloc([]bool, n);
        const matrix = try a.alloc([]i32, n);
        for (0..n) |i| {
            filled[i] = try a.alloc(bool, n);
            @memset(filled[i], false);
            matrix[i] = try a.alloc(i32, n);
            @memset(matrix[i], 0);
        }
        return .{
            .is_filled = filled,
            .crossing_matrix = matrix,
            .counter = try BetweenLayerEdgeTwoNodeCrossingsCounter.create(a, graph, free_layer_index),
            .direction = direction,
            .one_sided = cmt == .one_sided_greedy_switch,
        };
    }

    pub fn getCrossingMatrixEntry(self: *CrossingMatrixFiller, upper: *lg.LNode, lower: *lg.LNode) lg.Error!i32 {
        const u: usize = @intCast(upper.id);
        const l: usize = @intCast(lower.id);
        if (!self.is_filled[u][l]) {
            if (self.one_sided) {
                switch (self.direction) {
                    .east => try self.counter.countEasternEdgeCrossings(upper, lower),
                    .west => try self.counter.countWesternEdgeCrossings(upper, lower),
                }
            } else {
                try self.counter.countBothSideCrossings(upper, lower);
            }
            self.crossing_matrix[u][l] = self.counter.upper_lower_crossings;
            self.crossing_matrix[l][u] = self.counter.lower_upper_crossings;
            self.is_filled[u][l] = true;
            self.is_filled[l][u] = true;
        }
        return self.crossing_matrix[u][l];
    }
};
