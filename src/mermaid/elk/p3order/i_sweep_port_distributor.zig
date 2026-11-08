const std = @import("std");
const lg = @import("../lgraph.zig");
const CrossMinType = @import("layer_sweep_crossing_minimizer.zig").CrossMinType;
const AbstractBarycenterPortDistributor = @import("abstract_barycenter_port_distributor.zig").AbstractBarycenterPortDistributor;
const GreedyPortDistributor = @import("greedy_port_distributor.zig").GreedyPortDistributor;

// ISweepPortDistributor
pub const ISweepPortDistributor = union(enum) {
    barycenter: *AbstractBarycenterPortDistributor,
    greedy: *GreedyPortDistributor,

    pub fn create(a: std.mem.Allocator, cmt: CrossMinType, r: *lg.JavaRandom, order: [][]*lg.LNode) lg.Error!ISweepPortDistributor {
        if (cmt == .two_sided_greedy_switch) return .{ .greedy = try GreedyPortDistributor.create(a) };
        const kind: @import("abstract_barycenter_port_distributor.zig").Kind = if (r.nextBoolean()) .node_relative else .layer_total;
        return .{ .barycenter = try AbstractBarycenterPortDistributor.create(a, kind, order.len) };
    }

    pub fn distributePortsWhileSweeping(self: ISweepPortDistributor, order: [][]*lg.LNode, free: usize, forward: bool) lg.Error!bool {
        return switch (self) {
            inline else => |d| d.distributePortsWhileSweeping(order, free, forward),
        };
    }
};
