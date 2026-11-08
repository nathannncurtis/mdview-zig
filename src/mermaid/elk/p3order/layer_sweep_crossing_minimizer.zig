const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const GraphInfoHolder = @import("graph_info_holder.zig").GraphInfoHolder;
const SweepCopy = @import("sweep_copy.zig").SweepCopy;
const cmu = @import("counting/cross_min_util.zig");

pub const CrossMinType = enum { barycenter, one_sided_greedy_switch, two_sided_greedy_switch };

// P3 crossing minimization (CrossingMinimizationStrategy.LAYER_SWEEP). With hierarchyHandling INCLUDE_CHILDREN the
// driver calls this once on the root graph and it sweeps through every nested graph.
pub fn process(g: *lg.LGraph) lg.Error!void {
    return run(g, .barycenter);
}

// IntermediateProcessorStrategy.TWO_SIDED_GREEDY_SWITCH (before P4, when GraphConfigurator.activateGreedySwitchFor)
pub fn processTwoSidedGreedySwitch(g: *lg.LGraph) lg.Error!void {
    return run(g, .two_sided_greedy_switch);
}

pub fn run(g: *lg.LGraph, cmt: CrossMinType) lg.Error!void {
    var empty_graph = true;
    for (g.layers.items) |layer| {
        if (layer.nodes.items.len != 0) empty_graph = false;
    }
    const single_node = g.layers.items.len == 1 and g.layers.items[0].nodes.items.len == 1;
    const hierarchical = g.p.hierarchy_handling == .include_children;
    if (empty_graph or (single_node and !hierarchical)) return;
    // SAFETY: processGraph assigns random before use
    var m: LayerSweepCrossingMinimizer = .{ .a = g.a, .cross_min_type = cmt, .random = undefined };
    try m.processGraph(g);
}

const Method = enum { compare_randomized, no_counter, with_counter };

pub const LayerSweepCrossingMinimizer = struct {
    a: std.mem.Allocator,
    graph_info_holders: std.ArrayList(*GraphInfoHolder) = .empty,
    // a HashSet in ELK; only membership matters
    graphs_whose_node_order_changed: std.ArrayList(*GraphInfoHolder) = .empty,
    random: *lg.JavaRandom,
    random_seed: i64 = 0,
    cross_min_type: CrossMinType,

    fn processGraph(self: *LayerSweepCrossingMinimizer, g: *lg.LGraph) lg.Error!void {
        const to_sweep = try self.initialize(g);
        const parent = to_sweep[0];
        const method: Method = if (!parent.crossMinDeterministic()) .compare_randomized else if (parent.crossMinAlwaysImproves()) .no_counter else .with_counter;
        for (to_sweep) |gd| {
            if (gd.current_node_order.len > 0) {
                switch (method) {
                    .compare_randomized => try self.compareDifferentRandomizedLayouts(gd),
                    .no_counter => try self.minimizeCrossingsNoCounter(gd),
                    .with_counter => _ = try self.minimizeCrossingsWithCounter(gd),
                }
                if (gd.has_parent) setPortOrderOnParentGraph(gd);
            }
        }
        for (self.graph_info_holders.items) |gd| {
            if (gd.getBestSweep()) |best| try best.transferNodeAndPortOrdersToGraph(gd.l_graph, true);
        }
    }

    fn setPortOrderOnParentGraph(gd: *GraphInfoHolder) void {
        if (gd.has_external_ports) {
            // ELK dereferences a missing best sweep here and fails; keep the parent untouched instead
            const best = gd.getBestSweep() orelse return;
            sortPortsByDummyPositionsInLastLayer(best.node_order, gd.parent.?, true);
            sortPortsByDummyPositionsInLastLayer(best.node_order, gd.parent.?, false);
            gd.parent.?.p.port_constraints = .fixed_order;
        }
    }

    fn minimizeCrossingsNoCounter(self: *LayerSweepCrossingMinimizer, gd: *GraphInfoHolder) lg.Error!void {
        var forward = self.random.nextBoolean();
        var improved = true;
        while (improved) {
            improved = try gd.cross_minimizer.setFirstLayerOrder(gd.current_node_order, forward);
            if (try self.sweepReducingCrossings(gd, forward, false)) improved = true;
            forward = !forward;
        }
        try self.setCurrentlyBestNodeOrders();
    }

    // the CONSIDER_MODEL_ORDER_CROSSING_COUNTER_NODE_INFLUENCE branch is left out: Mermaid keeps its default 0
    fn compareDifferentRandomizedLayouts(self: *LayerSweepCrossingMinimizer, gd: *GraphInfoHolder) lg.Error!void {
        self.random.setSeed(self.random_seed);
        self.graphs_whose_node_order_changed.clearRetainingCapacity();
        var best_crossings: i32 = std.math.maxInt(i32);
        if (gd.l_graph.p.consider_model_order != .none) gd.l_graph.p.first_try_with_initial_order = true;
        const thoroughness = gd.l_graph.p.thoroughness;
        var i: i32 = 0;
        while (i < thoroughness) : (i += 1) {
            const crossings = try self.minimizeCrossingsWithCounter(gd);
            if (crossings < best_crossings) {
                best_crossings = crossings;
                try self.saveAllNodeOrdersOfChangedGraphs();
                if (best_crossings == 0) break;
            }
        }
    }

    fn minimizeCrossingsWithCounter(self: *LayerSweepCrossingMinimizer, gd: *GraphInfoHolder) lg.Error!i32 {
        const p = &gd.l_graph.p;
        var forward = self.random.nextBoolean();
        const initial = try self.countCurrentNumberOfCrossings(gd);
        if (initial == 0 and p.first_try_with_initial_order) return 0;
        if (!p.first_try_with_initial_order or p.consider_model_order == .none) {
            _ = try gd.cross_minimizer.setFirstLayerOrder(gd.current_node_order, forward);
        } else {
            forward = p.first_try_with_initial_order;
        }
        _ = try self.sweepReducingCrossings(gd, forward, true);
        p.first_try_with_initial_order = false;
        var crossings = try self.countCurrentNumberOfCrossings(gd);
        // SAFETY: assigned in the loop before it is read
        var old: i32 = undefined;
        while (true) {
            try self.setCurrentlyBestNodeOrders();
            if (crossings == 0) return 0;
            forward = !forward;
            old = crossings;
            _ = try self.sweepReducingCrossings(gd, forward, false);
            crossings = try self.countCurrentNumberOfCrossings(gd);
            if (!(old > crossings)) break;
        }
        return old;
    }

    fn countCurrentNumberOfCrossings(self: *LayerSweepCrossingMinimizer, current: *GraphInfoHolder) lg.Error!i32 {
        var total = try current.crossings_counter.countAllCrossings(current.current_node_order);
        if (@import("../layered.zig").trace) std.debug.print("CC {d}\n", .{total});
        for (current.child_graphs.items) |child_graph| {
            const child = self.graph_info_holders.items[@intCast(child_graph.id)];
            if (!child.dontSweepInto()) total +%= try self.countCurrentNumberOfCrossings(child);
        }
        return total;
    }

    fn sweepReducingCrossings(self: *LayerSweepCrossingMinimizer, gd: *GraphInfoHolder, forward: bool, first_sweep: bool) lg.Error!bool {
        const nodes = gd.current_node_order;
        const length = nodes.len;
        const first = if (forward) 0 else length - 1;
        var improved = try gd.port_distributor.distributePortsWhileSweeping(nodes, first, forward);
        if (try self.sweepInHierarchicalNodes(nodes[first], forward, first_sweep)) improved = true;
        const p = &gd.l_graph.p;
        const step: isize = if (forward) 1 else -1;
        var i: isize = if (forward) 1 else @as(isize, @intCast(length)) - 2;
        while (if (forward) i < length else i >= 0) : (i += step) {
            const li: usize = @intCast(i);
            if (try gd.cross_minimizer.minimizeCrossings(nodes, li, forward, first_sweep and !p.first_try_with_initial_order)) improved = true;
            if (try gd.port_distributor.distributePortsWhileSweeping(nodes, li, forward)) improved = true;
            if (try self.sweepInHierarchicalNodes(nodes[li], forward, first_sweep)) improved = true;
        }
        for (self.graphs_whose_node_order_changed.items) |x| {
            if (x == gd) break;
        } else try self.graphs_whose_node_order_changed.append(self.a, gd);
        return improved;
    }

    fn sweepInHierarchicalNodes(self: *LayerSweepCrossingMinimizer, layer: []*lg.LNode, forward: bool, first_sweep: bool) lg.Error!bool {
        var improved = false;
        for (layer) |node| {
            if (node.nested_graph) |nested| {
                if (!self.graph_info_holders.items[@intCast(nested.id)].dontSweepInto()) {
                    if (try self.sweepInHierarchicalNode(forward, node, first_sweep)) improved = true;
                }
            }
        }
        return improved;
    }

    fn sweepInHierarchicalNode(self: *LayerSweepCrossingMinimizer, forward: bool, node: *lg.LNode, first_sweep: bool) lg.Error!bool {
        const nested = self.graph_info_holders.items[@intCast(node.nested_graph.?.id)];
        const order = nested.current_node_order;
        const start = if (forward) 0 else order.len - 1;
        if (order[start][0].type == .external_port) {
            order[start] = try self.sortPortDummiesByPortPositions(node, order[start], if (forward) .west else .east);
        } else {
            _ = try nested.cross_minimizer.setFirstLayerOrder(order, forward);
        }
        const improved = try self.sweepReducingCrossings(nested, forward, first_sweep);
        sortPortsByDummyPositionsInLastLayer(nested.current_node_order, nested.parent.?, forward);
        return improved;
    }

    fn sortPortDummiesByPortPositions(self: *LayerSweepCrossingMinimizer, parent_node: *lg.LNode, layer: []*lg.LNode, side: lg.PortSide) lg.Error![]*lg.LNode {
        const ports = cmu.inNorthSouthEastWestOrder(parent_node, side);
        const sorted = try self.a.alloc(*lg.LNode, layer.len);
        var i: usize = 0;
        for (0..ports.len()) |k| {
            const port = ports.get(k);
            if (port.p.inside_connections) {
                if (i == sorted.len) break;
                sorted[i] = port.p.port_dummy.?;
                i += 1;
            }
        }
        // ELK throws when fewer hierarchical ports than dummies are found; keep the layer as it is
        if (i < layer.len) return layer;
        return sorted;
    }

    fn saveAllNodeOrdersOfChangedGraphs(self: *LayerSweepCrossingMinimizer) lg.Error!void {
        for (self.graphs_whose_node_order_changed.items) |gd| {
            gd.best = try SweepCopy.copy(self.a, gd.currently_best.?);
        }
    }

    fn setCurrentlyBestNodeOrders(self: *LayerSweepCrossingMinimizer) lg.Error!void {
        for (self.graphs_whose_node_order_changed.items) |gd| {
            gd.currently_best = try SweepCopy.fromOrder(self.a, gd.current_node_order);
        }
    }

    fn initialize(self: *LayerSweepCrossingMinimizer, root: *lg.LGraph) lg.Error![]*GraphInfoHolder {
        self.random = try util.graphRandom(root);
        self.random_seed = util.randNextLong(self.random);
        var to_sweep: std.ArrayList(*GraphInfoHolder) = .empty;
        var graphs: std.ArrayList(*lg.LGraph) = .empty;
        try graphs.append(self.a, root);
        var i: usize = 0;
        while (i < graphs.items.len) {
            const graph = graphs.items[i];
            graph.id = @intCast(i);
            i += 1;
            const gd = try GraphInfoHolder.create(self.a, graph, self.cross_min_type, self.graph_info_holders.items);
            try graphs.appendSlice(self.a, gd.child_graphs.items);
            try self.graph_info_holders.append(self.a, gd);
            if (gd.dontSweepInto()) try to_sweep.insert(self.a, 0, gd);
        }
        return to_sweep.items;
    }
};

fn sortPortsByDummyPositionsInLastLayer(order: [][]*lg.LNode, parent: *lg.LNode, on_right_most_layer: bool) void {
    const last_layer = order[if (on_right_most_layer) order.len - 1 else 0];
    var j: isize = if (on_right_most_layer) 0 else @as(isize, @intCast(last_layer.len)) - 1;
    if (last_layer[@intCast(j)].type != .external_port) return;
    const step: isize = if (on_right_most_layer) 1 else -1;
    for (parent.ports.items) |*slot| {
        const port = slot.*;
        const on_side = if (on_right_most_layer) port.side == .east else port.side == .west;
        if (on_side and port.p.inside_connections) {
            if (j < 0 or j >= last_layer.len) break;
            slot.* = last_layer[@intCast(j)].p.origin.port;
            j += step;
        }
    }
}
