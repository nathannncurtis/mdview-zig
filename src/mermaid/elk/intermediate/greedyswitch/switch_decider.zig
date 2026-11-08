const std = @import("std");
const lg = @import("../../lgraph.zig");
const CrossingsCounter = @import("../../p3order/counting/crossings_counter.zig").CrossingsCounter;
const GraphInfoHolder = @import("../../p3order/graph_info_holder.zig").GraphInfoHolder;
const CrossingMatrixFiller = @import("crossing_matrix_filler.zig").CrossingMatrixFiller;
const NorthSouthEdgeNeighbouringNodeCrossingsCounter = @import("north_south_edge_neighbouring_node_crossings_counter.zig").NorthSouthEdgeNeighbouringNodeCrossingsCounter;

pub const CrossingCountSide = enum { west, east };

pub const SwitchDecider = struct {
    free_layer: []*lg.LNode,
    left_in_layer_counter: CrossingsCounter,
    right_in_layer_counter: CrossingsCounter,
    north_south_counter: NorthSouthEdgeNeighbouringNodeCrossingsCounter = .{},
    crossing_matrix_filler: CrossingMatrixFiller,
    graph_data: *GraphInfoHolder,
    parent_cross_counter: CrossingsCounter = undefined,
    count_crossings_caused_by_port_switch: bool = false,

    pub fn create(a: std.mem.Allocator, free_layer_index: usize, graph: [][]*lg.LNode, filler: CrossingMatrixFiller, port_positions: []i32, graph_data: *GraphInfoHolder, one_sided: bool) lg.Error!*SwitchDecider {
        const self = try a.create(SwitchDecider);
        const free_layer = graph[free_layer_index];
        self.* = .{
            .free_layer = free_layer,
            .left_in_layer_counter = CrossingsCounter.init(a, port_positions),
            .right_in_layer_counter = CrossingsCounter.init(a, port_positions),
            .crossing_matrix_filler = filler,
            .graph_data = graph_data,
        };
        _ = try self.left_in_layer_counter.initPortPositionsForInLayerCrossings(free_layer, .west);
        _ = try self.right_in_layer_counter.initPortPositionsForInLayerCrossings(free_layer, .east);
        self.north_south_counter = try NorthSouthEdgeNeighbouringNodeCrossingsCounter.init(a, free_layer);
        self.count_crossings_caused_by_port_switch = !one_sided and graph_data.has_parent and !graph_data.dontSweepInto() and free_layer[0].type == .external_port;
        if (self.count_crossings_caused_by_port_switch) try self.initParentCrossingsCounters(a, free_layer_index, graph.len);
        return self;
    }

    fn initParentCrossingsCounters(self: *SwitchDecider, a: std.mem.Allocator, free_layer_index: usize, length: usize) lg.Error!void {
        const parent_data = self.graph_data.parent_graph_data.?;
        const parent_order = parent_data.current_node_order;
        self.parent_cross_counter = CrossingsCounter.init(a, parent_data.port_positions);
        const pos: usize = @intCast(self.graph_data.parent.?.layer.?.id);
        const empty: []*lg.LNode = &.{};
        const left = if (pos > 0) parent_order[pos - 1] else empty;
        const middle = parent_order[pos];
        const right = if (pos < parent_order.len - 1) parent_order[pos + 1] else empty;
        if (free_layer_index == length - 1) {
            try self.parent_cross_counter.initForCountingBetween(middle, right);
        } else {
            try self.parent_cross_counter.initForCountingBetween(left, middle);
        }
    }

    pub fn notifyOfSwitch(self: *SwitchDecider, upper: *lg.LNode, lower: *lg.LNode) void {
        self.left_in_layer_counter.switchNodes(upper, lower, .west);
        self.right_in_layer_counter.switchNodes(upper, lower, .east);
        if (self.count_crossings_caused_by_port_switch) {
            self.parent_cross_counter.switchPorts(upper.p.origin.port, lower.p.origin.port);
        }
    }

    pub fn doesSwitchReduceCrossings(self: *SwitchDecider, upper_index: usize, lower_index: usize) lg.Error!bool {
        if (self.constraintsPreventSwitch(upper_index, lower_index)) return false;
        const upper = self.free_layer[upper_index];
        const lower = self.free_layer[lower_index];
        const left = try self.left_in_layer_counter.countInLayerCrossingsBetweenNodesInBothOrders(upper, lower, .west);
        const right = try self.right_in_layer_counter.countInLayerCrossingsBetweenNodesInBothOrders(upper, lower, .east);
        self.north_south_counter.countCrossings(upper, lower);
        var upper_lower = try self.crossing_matrix_filler.getCrossingMatrixEntry(upper, lower);
        upper_lower += left.first + right.first + self.north_south_counter.upper_lower_crossings;
        var lower_upper = try self.crossing_matrix_filler.getCrossingMatrixEntry(lower, upper);
        lower_upper += left.second + right.second + self.north_south_counter.lower_upper_crossings;
        if (self.count_crossings_caused_by_port_switch) {
            const n = try self.parent_cross_counter.countCrossingsBetweenPortsInBothOrders(upper.p.origin.port, lower.p.origin.port);
            upper_lower += n.first;
            lower_upper += n.second;
        }
        return upper_lower > lower_upper;
    }

    fn constraintsPreventSwitch(self: *SwitchDecider, upper_index: usize, lower_index: usize) bool {
        const upper = self.free_layer[upper_index];
        const lower = self.free_layer[lower_index];
        return haveSuccessorConstraints(upper, lower) or haveLayoutUnitConstraints(upper, lower) or
            (upper.type == .north_south_port and lower.type == .normal) or
            (lower.type == .north_south_port and upper.type == .normal);
    }

    fn haveSuccessorConstraints(upper: *lg.LNode, lower: *lg.LNode) bool {
        for (upper.p.in_layer_successor_constraints.items) |n| if (n == lower) return true;
        return false;
    }

    fn haveLayoutUnitConstraints(upper: *lg.LNode, lower: *lg.LNode) bool {
        const neither_long_edge = upper.type != .long_edge and lower.type != .long_edge;
        const upper_unit = upper.p.in_layer_layout_unit;
        const lower_unit = lower.p.in_layer_layout_unit;
        const different_units = upper_unit != lower_unit;
        var have_units = partOfMultiNodeLayoutUnit(upper, upper_unit) or partOfMultiNodeLayoutUnit(lower, lower_unit);
        const upper_north = hasEdgesOnSide(upper, .north);
        const lower_south = hasEdgesOnSide(lower, .south);
        have_units = have_units or hasEdgesOnSide(upper, .south) or hasEdgesOnSide(lower, .north);
        const constraint = (have_units and different_units) or upper_north or lower_south;
        return neither_long_edge and constraint;
    }

    fn hasEdgesOnSide(node: *lg.LNode, side: lg.PortSide) bool {
        for (node.portSideView(side)) |port| {
            if (port.p.port_dummy != null or port.degree() > 0) return true;
        }
        return false;
    }

    fn partOfMultiNodeLayoutUnit(node: *lg.LNode, unit: ?*lg.LNode) bool {
        return unit != null and unit.? != node;
    }
};
