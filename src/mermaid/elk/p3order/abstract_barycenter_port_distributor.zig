const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const node_relative = @import("node_relative_port_distributor.zig");
const layer_total = @import("layer_total_port_distributor.zig");

pub const Kind = enum { node_relative, layer_total };

// AbstractBarycenterPortDistributor with its two subclasses selected by `kind`; float fields are doubles as in elkjs
pub const AbstractBarycenterPortDistributor = struct {
    a: std.mem.Allocator,
    kind: Kind,
    port_ranks: []f64 = &.{},
    min_barycenter: f64 = 0,
    max_barycenter: f64 = 0,
    node_positions: [][]i32,
    port_barycenter: []f64 = &.{},
    in_layer_ports: std.ArrayList(*lg.LPort) = .empty,
    n_ports: i32 = 0,

    pub fn create(a: std.mem.Allocator, kind: Kind, num_layers: usize) lg.Error!*AbstractBarycenterPortDistributor {
        const self = try a.create(AbstractBarycenterPortDistributor);
        self.* = .{ .a = a, .kind = kind, .node_positions = try a.alloc([]i32, num_layers) };
        return self;
    }

    pub fn distributePortsWhileSweeping(self: *AbstractBarycenterPortDistributor, order: [][]*lg.LNode, current: usize, forward: bool) lg.Error!bool {
        self.updateNodePositions(order, current);
        const free_layer = order[current];
        const side: lg.PortSide = if (forward) .west else .east;
        const not_first = if (forward) current != 0 else current != order.len - 1;
        if (not_first) {
            const fixed_layer = order[if (forward) current - 1 else current + 1];
            self.calculatePortRanks(fixed_layer, portTypeFor(forward));
            for (free_layer) |node| try self.distributePorts(node, side);
            self.calculatePortRanks(free_layer, portTypeFor(!forward));
            for (fixed_layer) |node| {
                if (node.nested_graph == null) try self.distributePorts(node, side.opposed());
            }
        } else {
            for (free_layer) |node| try self.distributePorts(node, side);
        }
        return false;
    }

    pub fn calculatePortRanks(self: *AbstractBarycenterPortDistributor, layer: []*lg.LNode, port_type: lg.PortType) void {
        var consumed: f64 = 0;
        for (layer) |node| {
            consumed += switch (self.kind) {
                .node_relative => node_relative.calculatePortRanks(self.port_ranks, node, consumed, port_type),
                .layer_total => layer_total.calculatePortRanks(self.port_ranks, node, consumed, port_type),
            };
        }
    }

    fn distributePorts(self: *AbstractBarycenterPortDistributor, node: *lg.LNode, side: lg.PortSide) lg.Error!void {
        if (node.p.port_constraints.isOrderFixed()) return;
        try self.distributePortsOnSide(node, side);
        try self.distributePortsOnSide(node, .south);
        try self.distributePortsOnSide(node, .north);
        try util.javaSort(*lg.LPort, self.a, node.ports.items, self, cmpPorts);
    }

    fn distributePortsOnSide(self: *AbstractBarycenterPortDistributor, node: *lg.LNode, side: lg.PortSide) lg.Error!void {
        self.in_layer_ports.clearRetainingCapacity();
        try self.iteratePortsAndCollectInLayerPorts(node, side);
        if (self.in_layer_ports.items.len != 0) self.calculateInLayerPortsBarycenterValues(node);
    }

    fn iteratePortsAndCollectInLayerPorts(self: *AbstractBarycenterPortDistributor, node: *lg.LNode, side: lg.PortSide) lg.Error!void {
        self.min_barycenter = 0;
        self.max_barycenter = 0;
        const absurdly_large: f64 = @floatFromInt(2 * node.layer.?.nodes.items.len + 1);
        port_loop: for (node.ports.items) |port| {
            if (port.side != side) continue;
            const north_south = port.side == .north or port.side == .south;
            var sum: f64 = 0;
            if (north_south) {
                const dummy = port.p.port_dummy orelse continue;
                sum += self.dealWithNorthSouthPorts(absurdly_large, port, dummy);
            } else {
                for (port.outgoing.items) |edge| {
                    const connected = edge.target.?;
                    if (connected.owner.?.layer == node.layer) {
                        try self.in_layer_ports.append(self.a, port);
                        continue :port_loop;
                    } else {
                        sum += self.port_ranks[@intCast(connected.id)];
                    }
                }
                for (port.incoming.items) |edge| {
                    const connected = edge.source.?;
                    if (connected.owner.?.layer == node.layer) {
                        try self.in_layer_ports.append(self.a, port);
                        continue :port_loop;
                    } else {
                        sum -= self.port_ranks[@intCast(connected.id)];
                    }
                }
            }
            const pid: usize = @intCast(port.id);
            if (port.degree() > 0) {
                self.port_barycenter[pid] = sum / @as(f64, @floatFromInt(port.degree()));
                self.min_barycenter = util.javaMin(self.min_barycenter, self.port_barycenter[pid]);
                self.max_barycenter = util.javaMax(self.max_barycenter, self.port_barycenter[pid]);
            } else if (north_south) {
                self.port_barycenter[pid] = sum;
            }
        }
    }

    fn calculateInLayerPortsBarycenterValues(self: *AbstractBarycenterPortDistributor, node: *lg.LNode) void {
        const node_index_in_layer: f64 = @floatFromInt(self.positionOf(node) + 1);
        const layer_size: f64 = @floatFromInt(node.layer.?.nodes.items.len + 1);
        for (self.in_layer_ports.items) |port| {
            var sum: i32 = 0;
            var in_layer_connections: i32 = 0;
            for (port.incoming.items) |e| {
                if (e.source.?.owner.?.layer == node.layer) {
                    sum += self.positionOf(e.source.?.owner.?) + 1;
                    in_layer_connections += 1;
                }
            }
            for (port.outgoing.items) |e| {
                if (e.target.?.owner.?.layer == node.layer) {
                    sum += self.positionOf(e.target.?.owner.?) + 1;
                    in_layer_connections += 1;
                }
            }
            const barycenter = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(in_layer_connections));
            const pid: usize = @intCast(port.id);
            if (port.side == .east) {
                if (barycenter < node_index_in_layer) {
                    self.port_barycenter[pid] = self.min_barycenter - barycenter;
                } else {
                    self.port_barycenter[pid] = self.max_barycenter + (layer_size - barycenter);
                }
            } else if (port.side == .west) {
                if (barycenter < node_index_in_layer) {
                    self.port_barycenter[pid] = self.max_barycenter + barycenter;
                } else {
                    self.port_barycenter[pid] = self.min_barycenter - (layer_size - barycenter);
                }
            }
        }
    }

    fn dealWithNorthSouthPorts(self: *AbstractBarycenterPortDistributor, absurdly_large: f64, port: *lg.LPort, dummy: *lg.LNode) f64 {
        var input = false;
        var output = false;
        for (dummy.ports.items) |dp| {
            if (dp.p.origin == .port and dp.p.origin.port == port) {
                if (dp.outgoing.items.len != 0) {
                    output = true;
                } else if (dp.incoming.items.len != 0) {
                    input = true;
                }
            }
        }
        const pos: f64 = @floatFromInt(self.positionOf(dummy));
        if (input and input != output) {
            return if (port.side == .north) -pos else absurdly_large - pos;
        } else if (output and input != output) {
            return pos + 1.0;
        } else if (input and output) {
            return if (port.side == .north) 0.0 else absurdly_large / 2.0;
        }
        return 0;
    }

    fn positionOf(self: *const AbstractBarycenterPortDistributor, node: *const lg.LNode) i32 {
        return self.node_positions[@intCast(node.layer.?.id)][@intCast(node.id)];
    }

    fn updateNodePositions(self: *AbstractBarycenterPortDistributor, order: [][]*lg.LNode, current: usize) void {
        for (order[current], 0..) |node, i| {
            self.node_positions[@intCast(node.layer.?.id)][@intCast(node.id)] = @intCast(i);
        }
    }

    fn portTypeFor(forward: bool) lg.PortType {
        return if (forward) .output else .input;
    }

    fn cmpPorts(self: *AbstractBarycenterPortDistributor, p1: *lg.LPort, p2: *lg.LPort) lg.Error!i32 {
        if (p1.side != p2.side) return @as(i32, @backingInt(p1.side)) - @as(i32, @backingInt(p2.side));
        const b1 = self.port_barycenter[@intCast(p1.id)];
        const b2 = self.port_barycenter[@intCast(p2.id)];
        if (b1 == 0 and b2 == 0) return 0;
        if (b1 == 0) return -1;
        if (b2 == 0) return 1;
        return switch (util.doubleCompare(b1, b2)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    pub fn initAtLayerLevel(self: *AbstractBarycenterPortDistributor, l: usize, order: [][]*lg.LNode) lg.Error!void {
        self.node_positions[l] = try self.a.alloc(i32, order[l].len);
        @memset(self.node_positions[l], 0);
    }

    pub fn initAtNodeLevel(self: *AbstractBarycenterPortDistributor, l: usize, n: usize, order: [][]*lg.LNode) void {
        order[l][n].id = @intCast(n);
        self.node_positions[l][n] = @intCast(n);
    }

    pub fn initAtPortLevel(self: *AbstractBarycenterPortDistributor, l: usize, n: usize, p: usize, order: [][]*lg.LNode) void {
        order[l][n].ports.items[p].id = self.n_ports;
        self.n_ports += 1;
    }

    pub fn initAfterTraversal(self: *AbstractBarycenterPortDistributor) lg.Error!void {
        self.port_ranks = try self.a.alloc(f64, @intCast(self.n_ports));
        @memset(self.port_ranks, 0);
        self.port_barycenter = try self.a.alloc(f64, @intCast(self.n_ports));
        @memset(self.port_barycenter, 0);
    }
};
