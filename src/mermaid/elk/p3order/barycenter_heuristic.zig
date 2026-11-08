const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const ForsterConstraintResolver = @import("forster_constraint_resolver.zig").ForsterConstraintResolver;
const AbstractBarycenterPortDistributor = @import("abstract_barycenter_port_distributor.zig").AbstractBarycenterPortDistributor;

pub const BarycenterState = struct {
    node: *lg.LNode,
    summed_weight: f64 = 0,
    degree: i32 = 0,
    barycenter: ?f64 = null,
    visited: bool = false,
};

// RANDOM_AMOUNT = 0.07f and RANDOM_AMOUNT / 2 as the float literals elkjs emits in double precision
const random_amount: f64 = @as(f32, 0.07);
const half_random_amount: f64 = @as(f32, 0.035);

// BarycenterHeuristic. ModelOrderBarycenterHeuristic is only built when crossingMinimization.forceNodeModelOrder is
// true, which Mermaid never sets, so it is not ported.
pub const BarycenterHeuristic = struct {
    a: std.mem.Allocator,
    port_ranks: []f64 = &.{},
    random: *lg.JavaRandom,
    constraint_resolver: *ForsterConstraintResolver,
    barycenter_state: [][]BarycenterState = &.{},
    port_distributor: *AbstractBarycenterPortDistributor,

    pub fn create(a: std.mem.Allocator, resolver: *ForsterConstraintResolver, random: *lg.JavaRandom, distributor: *AbstractBarycenterPortDistributor) lg.Error!*BarycenterHeuristic {
        const self = try a.create(BarycenterHeuristic);
        self.* = .{ .a = a, .random = random, .constraint_resolver = resolver, .port_distributor = distributor };
        return self;
    }

    pub fn minimizeCrossingsInLayer(self: *BarycenterHeuristic, layer: *std.ArrayList(*lg.LNode), pre_ordered: bool, randomize: bool, forward: bool) lg.Error!void {
        if (randomize) {
            self.randomizeBarycenters(layer.items);
        } else {
            self.calculateBarycenters(layer.items, forward);
            self.fillInUnknownBarycenters(layer.items, pre_ordered);
        }
        if (layer.items.len > 1) {
            try util.javaSort(*lg.LNode, self.a, layer.items, self, barycenterStateComparator);
            try self.constraint_resolver.processConstraints(layer);
        }
    }

    fn randomizeBarycenters(self: *BarycenterHeuristic, nodes: []*lg.LNode) void {
        for (nodes) |node| {
            const s = self.stateOf(node);
            s.barycenter = self.random.nextDouble();
            s.summed_weight = s.barycenter.?;
            s.degree = 1;
        }
    }

    fn fillInUnknownBarycenters(self: *BarycenterHeuristic, nodes: []*lg.LNode, pre_ordered: bool) void {
        if (pre_ordered) {
            var last_value: f64 = -1;
            for (nodes, 0..) |node, i| {
                var value = self.stateOf(node).barycenter;
                if (value == null) {
                    var next_value = last_value + 1;
                    for (nodes[i + 1 ..]) |next| {
                        if (self.stateOf(next).barycenter) |x| {
                            next_value = x;
                            break;
                        }
                    }
                    value = (last_value + next_value) / 2;
                    const s = self.stateOf(node);
                    s.barycenter = value;
                    s.summed_weight = value.?;
                    s.degree = 1;
                }
                last_value = value.?;
            }
        } else {
            var max_bary: f64 = 0;
            for (nodes) |node| {
                if (self.stateOf(node).barycenter) |b| max_bary = util.javaMax(max_bary, b);
            }
            max_bary += 2;
            for (nodes) |node| {
                const s = self.stateOf(node);
                if (s.barycenter == null) {
                    const value = util.randNextFloat(self.random) * max_bary - 1;
                    s.barycenter = value;
                    s.summed_weight = value;
                    s.degree = 1;
                }
            }
        }
    }

    fn calculateBarycenters(self: *BarycenterHeuristic, nodes: []*lg.LNode, forward: bool) void {
        for (nodes) |node| self.stateOf(node).visited = false;
        for (nodes) |node| self.calculateBarycenter(node, forward);
    }

    fn calculateBarycenter(self: *BarycenterHeuristic, node: *lg.LNode, forward: bool) void {
        const s = self.stateOf(node);
        if (s.visited) return;
        s.visited = true;
        s.degree = 0;
        s.summed_weight = 0;
        s.barycenter = null;
        for (node.ports.items) |free_port| {
            const edges = if (forward) free_port.incoming.items else free_port.outgoing.items;
            for (edges) |edge| {
                const fixed_port = if (forward) edge.source.? else edge.target.?;
                const fixed_node = fixed_port.owner.?;
                if (fixed_node.layer == node.layer) {
                    if (fixed_node != node) {
                        self.calculateBarycenter(fixed_node, forward);
                        s.degree += self.stateOf(fixed_node).degree;
                        s.summed_weight += self.stateOf(fixed_node).summed_weight;
                    }
                } else {
                    s.summed_weight += self.port_ranks[@intCast(fixed_port.id)];
                    s.degree += 1;
                }
            }
        }
        for (node.p.barycenter_associates.items) |associate| {
            if (node.layer == associate.layer) {
                self.calculateBarycenter(associate, forward);
                s.degree += self.stateOf(associate).degree;
                s.summed_weight += self.stateOf(associate).summed_weight;
            }
        }
        if (s.degree > 0) {
            s.summed_weight += util.randNextFloat(self.random) * random_amount - half_random_amount;
            s.barycenter = s.summed_weight / @as(f64, @floatFromInt(s.degree));
        }
    }

    fn stateOf(self: *BarycenterHeuristic, node: *lg.LNode) *BarycenterState {
        return &self.barycenter_state[@intCast(node.layer.?.id)][@intCast(node.id)];
    }

    fn barycenterStateComparator(self: *BarycenterHeuristic, n1: *lg.LNode, n2: *lg.LNode) lg.Error!i32 {
        const b1 = self.stateOf(n1).barycenter;
        const b2 = self.stateOf(n2).barycenter;
        if (b1 != null and b2 != null) {
            return switch (util.doubleCompare(b1.?, b2.?)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        } else if (b1 != null) {
            return -1;
        } else if (b2 != null) {
            return 1;
        }
        return 0;
    }

    pub fn minimizeCrossings(self: *BarycenterHeuristic, order: [][]*lg.LNode, free: usize, forward: bool, is_first_sweep: bool) lg.Error!bool {
        if (free != startIndex(forward, order.len)) {
            const fixed_layer = order[if (forward) free - 1 else free + 1];
            self.port_distributor.calculatePortRanks(fixed_layer, if (forward) .output else .input);
        }
        const first = order[free][0];
        const pre_ordered = !is_first_sweep or first.type == .external_port;
        var nodes: std.ArrayList(*lg.LNode) = .empty;
        try nodes.appendSlice(self.a, order[free]);
        try self.minimizeCrossingsInLayer(&nodes, pre_ordered, false, forward);
        for (nodes.items, 0..) |n, i| order[free][i] = n;
        return false;
    }

    pub fn setFirstLayerOrder(self: *BarycenterHeuristic, order: [][]*lg.LNode, forward: bool) lg.Error!bool {
        const start = startIndex(forward, order.len);
        var nodes: std.ArrayList(*lg.LNode) = .empty;
        try nodes.appendSlice(self.a, order[start]);
        try self.minimizeCrossingsInLayer(&nodes, false, true, forward);
        for (nodes.items, 0..) |n, i| order[start][i] = n;
        return false;
    }

    fn startIndex(forward: bool, len: usize) usize {
        return if (forward or len == 0) 0 else len - 1;
    }

    pub fn initAfterTraversal(self: *BarycenterHeuristic) void {
        self.barycenter_state = self.constraint_resolver.barycenter_states;
        self.port_ranks = self.port_distributor.port_ranks;
    }

    pub fn initAtLayerLevel(_: *BarycenterHeuristic, l: usize, order: [][]*lg.LNode) void {
        order[l][0].layer.?.id = @intCast(l);
    }
};
