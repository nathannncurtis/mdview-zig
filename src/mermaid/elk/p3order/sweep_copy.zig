const std = @import("std");
const lg = @import("../lgraph.zig");

// SweepCopy; the north/south port dummy side fix-up in transferNodeAndPortOrdersToGraph is left out (no such dummies)
pub const SweepCopy = struct {
    node_order: [][]*lg.LNode,
    port_orders: [][][]*lg.LPort,

    pub fn fromOrder(a: std.mem.Allocator, order: [][]*lg.LNode) lg.Error!*SweepCopy {
        const self = try a.create(SweepCopy);
        const ports = try a.alloc([][]*lg.LPort, order.len);
        for (order, 0..) |layer, i| {
            ports[i] = try a.alloc([]*lg.LPort, layer.len);
            for (layer, 0..) |node, j| ports[i][j] = try a.dupe(*lg.LPort, node.ports.items);
        }
        self.* = .{ .node_order = try deepCopy(a, order), .port_orders = ports };
        return self;
    }

    pub fn copy(a: std.mem.Allocator, sc: *const SweepCopy) lg.Error!*SweepCopy {
        const self = try a.create(SweepCopy);
        self.* = .{ .node_order = try deepCopy(a, sc.node_order), .port_orders = sc.port_orders };
        return self;
    }

    fn deepCopy(a: std.mem.Allocator, order: [][]*lg.LNode) lg.Error![][]*lg.LNode {
        const out = try a.alloc([]*lg.LNode, order.len);
        for (order, 0..) |layer, i| out[i] = try a.dupe(*lg.LNode, layer);
        return out;
    }

    pub fn transferNodeAndPortOrdersToGraph(self: *const SweepCopy, g: *lg.LGraph, set_port_constraints: bool) lg.Error!void {
        for (g.layers.items, 0..) |layer, i| {
            const nodes = layer.nodes.items;
            for (0..nodes.len) |j| {
                const node = self.node_order[i][j];
                node.id = @intCast(j);
                nodes[j] = node;
                node.ports.clearRetainingCapacity();
                try node.ports.appendSlice(node.a, self.port_orders[i][j]);
                if (set_port_constraints and !node.p.port_constraints.isOrderFixed()) {
                    node.p.port_constraints = .fixed_order;
                }
            }
        }
    }
};
