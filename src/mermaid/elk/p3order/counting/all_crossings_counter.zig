const std = @import("std");
const lg = @import("../../lgraph.zig");
const CrossingsCounter = @import("crossings_counter.zig").CrossingsCounter;
const HyperedgeCrossingsCounter = @import("hyperedge_crossings_counter.zig").HyperedgeCrossingsCounter;

// AllCrossingsCounter; north/south port dummies never occur, so countNorthSouthPortCrossingsInLayer is left out
pub const AllCrossingsCounter = struct {
    a: std.mem.Allocator,
    crossing_counter: CrossingsCounter,
    has_hyper_edges_east_of_index: []bool,
    hyperedge_crossings_counter: HyperedgeCrossingsCounter,
    n_ports: i32 = 0,

    pub fn create(a: std.mem.Allocator, graph: [][]*lg.LNode) lg.Error!*AllCrossingsCounter {
        const self = try a.create(AllCrossingsCounter);
        const hyper = try a.alloc(bool, graph.len);
        @memset(hyper, false);
        self.* = .{
            .a = a,
            .has_hyper_edges_east_of_index = hyper,
            // SAFETY: initialize sets both counters before any counting
            .crossing_counter = undefined,
            .hyperedge_crossings_counter = undefined,
        };
        return self;
    }

    pub fn countAllCrossings(self: *AllCrossingsCounter, order: [][]*lg.LNode) lg.Error!i32 {
        if (order.len == 0) return 0;
        var crossings = try self.crossing_counter.countInLayerCrossingsOnSide(order[0], .west);
        crossings +%= try self.crossing_counter.countInLayerCrossingsOnSide(order[order.len - 1], .east);
        for (0..order.len) |l| crossings +%= try self.countCrossingsAt(l, order);
        return crossings;
    }

    fn countCrossingsAt(self: *AllCrossingsCounter, l: usize, order: [][]*lg.LNode) lg.Error!i32 {
        var total: i32 = 0;
        const left = order[l];
        if (l < order.len - 1) {
            const right = order[l + 1];
            if (self.has_hyper_edges_east_of_index[l]) {
                total = try self.hyperedge_crossings_counter.countCrossings(left, right);
                total +%= try self.crossing_counter.countInLayerCrossingsOnSide(left, .east);
                total +%= try self.crossing_counter.countInLayerCrossingsOnSide(right, .west);
            } else {
                total = try self.crossing_counter.countCrossingsBetweenLayers(left, right);
            }
        }
        return total;
    }

    pub fn initAtPortLevel(self: *AllCrossingsCounter, l: usize, n: usize, p: usize, order: [][]*lg.LNode) void {
        const port = order[l][n].ports.items[p];
        port.id = self.n_ports;
        self.n_ports += 1;
        if (port.outgoing.items.len + port.incoming.items.len > 1) {
            if (port.side == .east) {
                self.has_hyper_edges_east_of_index[l] = true;
            } else if (port.side == .west and l > 0) {
                self.has_hyper_edges_east_of_index[l - 1] = true;
            }
        }
    }

    pub fn initAfterTraversal(self: *AllCrossingsCounter) lg.Error!void {
        const port_pos = try self.a.alloc(i32, @intCast(self.n_ports));
        @memset(port_pos, 0);
        self.hyperedge_crossings_counter = .{ .a = self.a, .port_pos = port_pos };
        self.crossing_counter = CrossingsCounter.init(self.a, port_pos);
    }
};
