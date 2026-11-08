const std = @import("std");
const lg = @import("../../lgraph.zig");
const CrossMinType = @import("../../p3order/layer_sweep_crossing_minimizer.zig").CrossMinType;
const GraphInfoHolder = @import("../../p3order/graph_info_holder.zig").GraphInfoHolder;
const SwitchDecider = @import("switch_decider.zig").SwitchDecider;
const CrossingMatrixFiller = @import("crossing_matrix_filler.zig").CrossingMatrixFiller;

pub const GreedySwitchHeuristic = struct {
    a: std.mem.Allocator,
    greedy_switch_type: CrossMinType,
    current_node_order: [][]*lg.LNode = &.{},
    switch_decider: *SwitchDecider = undefined,
    port_positions: []i32 = &.{},
    graph_data: *GraphInfoHolder,
    n_ports: i32 = 0,

    pub fn create(a: std.mem.Allocator, greedy_type: CrossMinType, graph_data: *GraphInfoHolder) lg.Error!*GreedySwitchHeuristic {
        const self = try a.create(GreedySwitchHeuristic);
        self.* = .{ .a = a, .greedy_switch_type = greedy_type, .graph_data = graph_data };
        return self;
    }

    pub fn minimizeCrossings(self: *GreedySwitchHeuristic, order: [][]*lg.LNode, free: usize, forward: bool, is_first_sweep: bool) lg.Error!bool {
        _ = is_first_sweep;
        try self.setUp(order, free, forward);
        var improved = false;
        while (try self.sweepDownwardInLayer(free)) improved = true;
        return improved;
    }

    pub fn setFirstLayerOrder(self: *GreedySwitchHeuristic, order: [][]*lg.LNode, forward: bool) lg.Error!bool {
        const start = if (forward) 0 else order.len - 1;
        try self.setUp(order, start, forward);
        return self.sweepDownwardInLayer(start);
    }

    fn setUp(self: *GreedySwitchHeuristic, order: [][]*lg.LNode, free: usize, forward: bool) lg.Error!void {
        self.current_node_order = order;
        const filler = try CrossingMatrixFiller.init(self.a, self.greedy_switch_type, order, free, if (forward) .west else .east);
        self.switch_decider = try SwitchDecider.create(self.a, free, order, filler, self.port_positions, self.graph_data, self.greedy_switch_type == .one_sided_greedy_switch);
    }

    fn sweepDownwardInLayer(self: *GreedySwitchHeuristic, layer_index: usize) lg.Error!bool {
        var continue_switching = false;
        const len = self.current_node_order[layer_index].len;
        var upper: usize = 0;
        while (upper + 1 < len) : (upper += 1) {
            if (try self.switch_decider.doesSwitchReduceCrossings(upper, upper + 1)) {
                const layer = self.current_node_order[layer_index];
                self.switch_decider.notifyOfSwitch(layer[upper], layer[upper + 1]);
                const t = layer[upper + 1];
                layer[upper + 1] = layer[upper];
                layer[upper] = t;
                continue_switching = true;
            }
        }
        return continue_switching;
    }

    pub fn alwaysImproves(self: *const GreedySwitchHeuristic) bool {
        return self.greedy_switch_type != .one_sided_greedy_switch;
    }

    pub fn initAtLayerLevel(_: *GreedySwitchHeuristic, l: usize, order: [][]*lg.LNode) void {
        order[l][0].layer.?.id = @intCast(l);
    }

    pub fn initAfterTraversal(self: *GreedySwitchHeuristic) lg.Error!void {
        self.port_positions = try self.a.alloc(i32, @intCast(self.n_ports));
        @memset(self.port_positions, 0);
    }
};
