const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const graph_util = @import("../graph_util.zig");
const CrossMinType = @import("layer_sweep_crossing_minimizer.zig").CrossMinType;
const SweepCopy = @import("sweep_copy.zig").SweepCopy;
const LayerSweepTypeDecider = @import("layer_sweep_type_decider.zig").LayerSweepTypeDecider;
const ICrossingMinimizationHeuristic = @import("i_crossing_minimization_heuristic.zig").ICrossingMinimizationHeuristic;
const ISweepPortDistributor = @import("i_sweep_port_distributor.zig").ISweepPortDistributor;
const AllCrossingsCounter = @import("counting/all_crossings_counter.zig").AllCrossingsCounter;
const ForsterConstraintResolver = @import("forster_constraint_resolver.zig").ForsterConstraintResolver;
const BarycenterHeuristic = @import("barycenter_heuristic.zig").BarycenterHeuristic;
const AbstractBarycenterPortDistributor = @import("abstract_barycenter_port_distributor.zig").AbstractBarycenterPortDistributor;
const GreedyPortDistributor = @import("greedy_port_distributor.zig").GreedyPortDistributor;
const GreedySwitchHeuristic = @import("../intermediate/greedyswitch/greedy_switch_heuristic.zig").GreedySwitchHeuristic;

// IInitializable: the components that take part in the one traversal of the node order, in list order
const IInitializable = union(enum) {
    holder: *GraphInfoHolder,
    all_counter: *AllCrossingsCounter,
    decider: *LayerSweepTypeDecider,
    bary_dist: *AbstractBarycenterPortDistributor,
    greedy_dist: *GreedyPortDistributor,
    forster: *ForsterConstraintResolver,
    bary_heur: *BarycenterHeuristic,
    greedy_heur: *GreedySwitchHeuristic,

    fn atLayer(self: IInitializable, l: usize, order: [][]*lg.LNode) lg.Error!void {
        switch (self) {
            .decider => |x| try x.initAtLayerLevel(l, order),
            .bary_dist => |x| try x.initAtLayerLevel(l, order),
            .forster => |x| try x.initAtLayerLevel(l, order),
            .bary_heur => |x| if (order[l].len > 0) x.initAtLayerLevel(l, order),
            .greedy_heur => |x| if (order[l].len > 0) x.initAtLayerLevel(l, order),
            else => {},
        }
    }
    fn atNode(self: IInitializable, l: usize, n: usize, order: [][]*lg.LNode) lg.Error!void {
        switch (self) {
            .holder => |x| try x.initAtNodeLevel(l, n, order),
            .decider => |x| x.initAtNodeLevel(l, n, order),
            .bary_dist => |x| x.initAtNodeLevel(l, n, order),
            .greedy_dist => |x| x.initAtNodeLevel(l, n, order),
            .forster => |x| try x.initAtNodeLevel(l, n, order),
            else => {},
        }
    }
    fn atPort(self: IInitializable, l: usize, n: usize, p: usize, order: [][]*lg.LNode) void {
        switch (self) {
            .holder => |x| x.n_ports += 1,
            .all_counter => |x| x.initAtPortLevel(l, n, p, order),
            .bary_dist => |x| x.initAtPortLevel(l, n, p, order),
            .greedy_heur => |x| x.n_ports += 1,
            else => {},
        }
    }
    fn after(self: IInitializable) lg.Error!void {
        switch (self) {
            .holder => |x| {
                x.port_positions = try x.a.alloc(i32, @intCast(x.n_ports));
                @memset(x.port_positions, 0);
            },
            .all_counter => |x| try x.initAfterTraversal(),
            .bary_dist => |x| try x.initAfterTraversal(),
            .greedy_dist => |x| try x.initAfterTraversal(),
            .bary_heur => |x| x.initAfterTraversal(),
            .greedy_heur => |x| try x.initAfterTraversal(),
            else => {},
        }
    }

    fn init(list: []const IInitializable, order: [][]*lg.LNode) lg.Error!void {
        for (order, 0..) |layer, l| {
            for (list) |i| try i.atLayer(l, order);
            for (layer, 0..) |node, n| {
                for (list) |i| try i.atNode(l, n, order);
                for (0..node.ports.items.len) |p| {
                    for (list) |i| i.atPort(l, n, p, order);
                }
            }
        }
        for (list) |i| try i.after();
    }
};

pub const GraphInfoHolder = struct {
    a: std.mem.Allocator,
    l_graph: *lg.LGraph,
    current_node_order: [][]*lg.LNode,
    currently_best: ?*SweepCopy = null,
    best: ?*SweepCopy = null,
    port_positions: []i32 = &.{},
    use_bottom_up: bool = false,
    child_graphs: std.ArrayList(*lg.LGraph) = .empty,
    has_external_ports: bool,
    has_parent: bool,
    parent_graph_data: ?*GraphInfoHolder,
    parent: ?*lg.LNode,
    layer_sweep_type_decider: *LayerSweepTypeDecider,
    cross_minimizer: ICrossingMinimizationHeuristic,
    port_distributor: ISweepPortDistributor,
    crossings_counter: *AllCrossingsCounter,
    n_ports: i32 = 0,

    pub fn create(a: std.mem.Allocator, graph: *lg.LGraph, cmt: CrossMinType, graphs: []*GraphInfoHolder) lg.Error!*GraphInfoHolder {
        const self = try a.create(GraphInfoHolder);
        const parent = graph.parent_node;
        self.* = .{
            .a = a,
            .l_graph = graph,
            .current_node_order = try graph_util.toNodeArray(graph),
            .parent = parent,
            .has_parent = parent != null,
            .parent_graph_data = if (parent) |p| graphs[@intCast(p.graph.?.id)] else null,
            .has_external_ports = graph.p.graph_properties.external_ports,
            // SAFETY: create assigns the first four below; cross_minimizer is assigned before the sweeps run
            .layer_sweep_type_decider = undefined,
            // SAFETY: assigned before first use
            .cross_minimizer = undefined,
            // SAFETY: assigned before first use
            .port_distributor = undefined,
            // SAFETY: assigned before first use
            .crossings_counter = undefined,
        };
        const order = self.current_node_order;
        self.crossings_counter = try AllCrossingsCounter.create(a, order);
        const random = try util.graphRandom(graph);
        self.port_distributor = try ISweepPortDistributor.create(a, cmt, random, order);
        self.layer_sweep_type_decider = try LayerSweepTypeDecider.create(a, self);
        var list: std.ArrayList(IInitializable) = .empty;
        try list.append(a, .{ .holder = self });
        try list.append(a, .{ .all_counter = self.crossings_counter });
        try list.append(a, .{ .decider = self.layer_sweep_type_decider });
        try list.append(a, switch (self.port_distributor) {
            .barycenter => |d| IInitializable{ .bary_dist = d },
            .greedy => |d| IInitializable{ .greedy_dist = d },
        });
        if (cmt == .barycenter) {
            // forceNodeModelOrder (ModelOrderBarycenterHeuristic) is never set by Mermaid
            const resolver = try ForsterConstraintResolver.create(a, order);
            try list.append(a, .{ .forster = resolver });
            const h = try BarycenterHeuristic.create(a, resolver, random, self.port_distributor.barycenter);
            self.cross_minimizer = .{ .barycenter = h };
            try list.append(a, .{ .bary_heur = h });
        } else {
            const h = try GreedySwitchHeuristic.create(a, cmt, self);
            self.cross_minimizer = .{ .greedy = h };
            try list.append(a, .{ .greedy_heur = h });
        }
        try IInitializable.init(list.items, order);
        self.use_bottom_up = try self.layer_sweep_type_decider.useBottomUp();
        return self;
    }

    pub fn dontSweepInto(self: *const GraphInfoHolder) bool {
        return self.use_bottom_up;
    }

    pub fn getBestSweep(self: *const GraphInfoHolder) ?*SweepCopy {
        return if (self.cross_minimizer.isDeterministic()) self.currently_best else self.best;
    }

    pub fn crossMinDeterministic(self: *const GraphInfoHolder) bool {
        return self.cross_minimizer.isDeterministic();
    }

    pub fn crossMinAlwaysImproves(self: *const GraphInfoHolder) bool {
        return self.cross_minimizer.alwaysImproves();
    }

    fn initAtNodeLevel(self: *GraphInfoHolder, l: usize, n: usize, order: [][]*lg.LNode) lg.Error!void {
        if (order[l][n].nested_graph) |nested| try self.child_graphs.append(self.a, nested);
    }
};
