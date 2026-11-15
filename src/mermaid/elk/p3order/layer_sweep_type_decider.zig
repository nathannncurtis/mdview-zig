const std = @import("std");
const lg = @import("../lgraph.zig");
const GraphInfoHolder = @import("graph_info_holder.zig").GraphInfoHolder;

const NodeInfo = struct {
    connected_edges: i32 = 0,
    hierarchical_influence: i32 = 0,
    random_influence: i32 = 0,

    fn transfer(self: *NodeInfo, o: *const NodeInfo) void {
        self.hierarchical_influence += o.hierarchical_influence;
        self.random_influence += o.random_influence;
        self.connected_edges += o.connected_edges;
    }
};

pub const LayerSweepTypeDecider = struct {
    a: std.mem.Allocator,
    node_info: [][]NodeInfo,
    graph_data: *GraphInfoHolder,

    pub fn create(a: std.mem.Allocator, graph_data: *GraphInfoHolder) lg.Error!*LayerSweepTypeDecider {
        const self = try a.create(LayerSweepTypeDecider);
        self.* = .{ .a = a, .graph_data = graph_data, .node_info = try a.alloc([]NodeInfo, graph_data.current_node_order.len) };
        return self;
    }

    pub fn useBottomUp(self: *LayerSweepTypeDecider) lg.Error!bool {
        const gd = self.graph_data;
        const boundary = gd.l_graph.p.hierarchical_sweepiness;
        if (boundary < -1 or !gd.has_parent or gd.parent.?.p.port_constraints.isOrderFixed() or self.fewerThanTwoInOutEdges()) {
            return true;
        }
        if (gd.crossMinDeterministic()) return false;
        var paths_to_random: i32 = 0;
        var paths_to_hierarchical: i32 = 0;
        var ns_port_dummies: std.ArrayList(*lg.LNode) = .empty;
        for (gd.current_node_order) |layer| {
            for (layer) |node| {
                if (node.type == .north_south_port) {
                    try ns_port_dummies.append(self.a, node);
                    continue;
                }
                const current = self.nodeInfoFor(node);
                if (node.type == .external_port) {
                    current.hierarchical_influence = 1;
                    if (node.p.origin == .port and node.p.origin.port.side == .east) {
                        paths_to_hierarchical += current.connected_edges;
                    }
                } else if (hasNoConnectedPorts(node, .west)) {
                    current.random_influence = 1;
                } else if (hasNoConnectedPorts(node, .east)) {
                    paths_to_random += current.connected_edges;
                }
                for (node.ports.items) |port| {
                    for (port.outgoing.items) |edge| {
                        paths_to_random += current.random_influence;
                        paths_to_hierarchical += current.hierarchical_influence;
                        self.transferInfoTo(current, edge.target.?.owner.?);
                    }
                }
                for ([_]lg.PortSide{ .north, .south }) |side| {
                    for (node.portSideView(side)) |port| {
                        if (port.p.port_dummy) |ns_dummy| {
                            paths_to_random += current.random_influence;
                            paths_to_hierarchical += current.hierarchical_influence;
                            self.transferInfoTo(current, ns_dummy);
                        }
                    }
                }
            }
            for (ns_port_dummies.items) |node| {
                const current = self.nodeInfoFor(node);
                for (node.ports.items) |port| {
                    for (port.outgoing.items) |edge| {
                        paths_to_random += current.random_influence;
                        paths_to_hierarchical += current.hierarchical_influence;
                        self.transferInfoTo(current, edge.target.?.owner.?);
                    }
                }
            }
            ns_port_dummies.clearRetainingCapacity();
        }
        const all_paths: f64 = @floatFromInt(paths_to_random + paths_to_hierarchical);
        const normalized = if (all_paths == 0) std.math.inf(f64) else @as(f64, @floatFromInt(paths_to_random - paths_to_hierarchical)) / all_paths;
        return normalized >= boundary;
    }

    fn transferInfoTo(self: *LayerSweepTypeDecider, current: *const NodeInfo, target: *lg.LNode) void {
        const t = self.nodeInfoFor(target);
        t.transfer(current);
        t.connected_edges += 1;
    }

    fn fewerThanTwoInOutEdges(self: *LayerSweepTypeDecider) bool {
        const parent = self.graph_data.parent.?;
        return parent.portSideView(.east).len < 2 and parent.portSideView(.west).len < 2;
    }

    fn hasNoConnectedPorts(node: *lg.LNode, side: lg.PortSide) bool {
        for (node.portSideView(side)) |p| {
            if (p.degree() > 0) return false;
        }
        return true;
    }

    fn nodeInfoFor(self: *LayerSweepTypeDecider, n: *const lg.LNode) *NodeInfo {
        return &self.node_info[@intCast(n.layer.?.id)][@intCast(n.id)];
    }

    pub fn initAtLayerLevel(self: *LayerSweepTypeDecider, l: usize, order: [][]*lg.LNode) lg.Error!void {
        if (order[l].len > 0) order[l][0].layer.?.id = @intCast(l);
        self.node_info[l] = try self.a.alloc(NodeInfo, order[l].len);
    }

    pub fn initAtNodeLevel(self: *LayerSweepTypeDecider, l: usize, n: usize, order: [][]*lg.LNode) void {
        order[l][n].id = @intCast(n);
        self.node_info[l][n] = .{};
    }
};
