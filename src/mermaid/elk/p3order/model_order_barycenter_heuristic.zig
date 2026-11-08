const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const Transitive = @import("../intermediate/preserveorder/model_order_node_comparator.zig").Transitive;
const BarycenterHeuristic = @import("barycenter_heuristic.zig").BarycenterHeuristic;

// ModelOrderBarycenterHeuristic: what it adds to BarycenterHeuristic (its comparator and insertion sort). The
// BarycenterHeuristic that GraphInfoHolder builds under crossingMinimization.forceNodeModelOrder holds one.
pub const ModelOrderBarycenterHeuristic = struct {
    h: *BarycenterHeuristic,
    t: Transitive(lg.LNode),

    pub fn create(a: std.mem.Allocator, h: *BarycenterHeuristic) lg.Error!*ModelOrderBarycenterHeuristic {
        const self = try a.create(ModelOrderBarycenterHeuristic);
        self.* = .{ .h = h, .t = .{ .a = a } };
        return self;
    }

    fn compare(self: *ModelOrderBarycenterHeuristic, n1: *lg.LNode, n2: *lg.LNode) lg.Error!i32 {
        const transitive = try self.t.checkSmaller(n1, n2);
        if (transitive != 0) return transitive;
        if (n1.p.model_order != null and n2.p.model_order != null) {
            const mo1 = n1.p.model_order.?;
            const mo2 = n2.p.model_order.?;
            const value: i32 = if (mo1 < mo2) -1 else if (mo1 == mo2) 0 else 1;
            if (value < 0) {
                try self.t.update(n1, n2);
            } else if (value > 0) {
                try self.t.update(n2, n1);
            }
            return value;
        }
        return self.compareBasedOnBarycenter(n1, n2);
    }

    fn compareBasedOnBarycenter(self: *ModelOrderBarycenterHeuristic, n1: *lg.LNode, n2: *lg.LNode) lg.Error!i32 {
        const b1 = self.h.stateOf(n1).barycenter;
        const b2 = self.h.stateOf(n2).barycenter;
        if (b1 != null and b2 != null) {
            const value: i32 = switch (util.doubleCompare(b1.?, b2.?)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            if (value < 0) {
                try self.t.update(n1, n2);
            } else if (value > 0) {
                try self.t.update(n2, n1);
            }
            return value;
        } else if (b1 != null) {
            try self.t.update(n1, n2);
            return -1;
        } else if (b2 != null) {
            try self.t.update(n2, n1);
            return 1;
        }
        return 0;
    }

    pub fn insertionSort(self: *ModelOrderBarycenterHeuristic, layer: []*lg.LNode) lg.Error!void {
        var i: usize = 1;
        while (i < layer.len) : (i += 1) {
            const temp = layer[i];
            var j = i;
            while (j > 0 and (try self.compare(layer[j - 1], temp)) > 0) {
                layer[j] = layer[j - 1];
                j -= 1;
            }
            layer[j] = temp;
        }
        self.t = .{ .a = self.t.a };
    }
};
