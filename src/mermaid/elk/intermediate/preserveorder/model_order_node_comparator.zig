const std = @import("std");
const lg = @import("../../lgraph.zig");

// the biggerThan / smallerThan transitive bookkeeping shared by the model order comparators
pub fn Transitive(comptime T: type) type {
    return struct {
        const Self = @This();
        const Set = std.AutoHashMapUnmanaged(*T, void);
        const Map = std.AutoHashMapUnmanaged(*T, *Set);

        a: std.mem.Allocator,
        bigger_than: Map = .empty,
        smaller_than: Map = .empty,

        // returns the existing set, or null after registering a new empty one
        fn ensure(self: *Self, map: *Map, k: *T) lg.Error!?*Set {
            const gop = try map.getOrPut(self.a, k);
            if (gop.found_existing) return gop.value_ptr.*;
            const s = try self.a.create(Set);
            s.* = .empty;
            gop.value_ptr.* = s;
            return null;
        }

        // the four lookups at the top of compare(); the last one reads biggerThan, as ELK does
        pub fn check(self: *Self, n1: *T, n2: *T) lg.Error!i32 {
            if (try self.ensure(&self.bigger_than, n1)) |s| {
                if (s.contains(n2)) return 1;
            }
            if (try self.ensure(&self.bigger_than, n2)) |s| {
                if (s.contains(n1)) return -1;
            }
            if (try self.ensure(&self.smaller_than, n1)) |s| {
                if (s.contains(n2)) return -1;
            }
            if (try self.ensure(&self.smaller_than, n2)) |_| {
                if (self.bigger_than.get(n2).?.contains(n1)) return 1;
            }
            return 0;
        }

        // ModelOrderBarycenterHeuristic.compareBasedOnTansitiveDependencies: its last lookup reads smallerThan
        pub fn checkSmaller(self: *Self, n1: *T, n2: *T) lg.Error!i32 {
            if (try self.ensure(&self.bigger_than, n1)) |s| {
                if (s.contains(n2)) return 1;
            }
            if (try self.ensure(&self.bigger_than, n2)) |s| {
                if (s.contains(n1)) return -1;
            }
            if (try self.ensure(&self.smaller_than, n1)) |s| {
                if (s.contains(n2)) return -1;
            }
            if (try self.ensure(&self.smaller_than, n2)) |s| {
                if (s.contains(n1)) return 1;
            }
            return 0;
        }

        fn snapshot(self: *Self, s: *Set) lg.Error![]*T {
            const out = try self.a.alloc(*T, s.count());
            var it = s.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) out[i] = k.*;
            return out;
        }

        fn addAll(self: *Self, dst: *Set, src: []*T) lg.Error!void {
            for (src) |x| try dst.put(self.a, x, {});
        }

        pub fn update(self: *Self, bigger: *T, smaller: *T) lg.Error!void {
            const bnbt = self.bigger_than.get(bigger).?;
            const snbt = self.bigger_than.get(smaller).?;
            const bnst = self.smaller_than.get(bigger).?;
            const snst = self.smaller_than.get(smaller).?;
            try bnbt.put(self.a, smaller, {});
            try snst.put(self.a, bigger, {});
            for (try self.snapshot(snbt)) |very_small| {
                try bnbt.put(self.a, very_small, {});
                const st = self.smaller_than.get(very_small).?;
                try st.put(self.a, bigger, {});
                try self.addAll(st, try self.snapshot(bnst));
            }
            for (try self.snapshot(bnst)) |very_big| {
                try snst.put(self.a, very_big, {});
                const bt = self.bigger_than.get(very_big).?;
                try bt.put(self.a, smaller, {});
                try self.addAll(bt, try self.snapshot(snbt));
            }
        }
    };
}

pub fn longEdgeReturnValue(s: lg.LongEdgeOrderingStrategy) i32 {
    return switch (s) {
        .dummy_node_over => std.math.maxInt(i32),
        .dummy_node_under => -1,
        .equal => 0,
    };
}

fn intCompare(x: i32, y: i32) i32 {
    return if (x < y) -1 else if (x == y) 0 else 1;
}

pub const ModelOrderNodeComparator = struct {
    previous_layer: []*lg.LNode,
    ordering_strategy: lg.OrderingStrategy,
    t: Transitive(lg.LNode),
    long_edge_node_order: lg.LongEdgeOrderingStrategy,

    pub fn init(a: std.mem.Allocator, previous_layer: []*lg.LNode, strategy: lg.OrderingStrategy, long_edge: lg.LongEdgeOrderingStrategy) ModelOrderNodeComparator {
        return .{ .previous_layer = previous_layer, .ordering_strategy = strategy, .t = .{ .a = a }, .long_edge_node_order = long_edge };
    }

    fn incomingSourcePort(n: *lg.LNode) ?*lg.LPort {
        var found: ?*lg.LPort = null;
        for (n.ports.items) |p| {
            if (p.incoming.items.len != 0) {
                const src = p.incoming.items[0].source.?;
                if (src.owner.?.layer != n.layer) found = src;
            }
        }
        return found;
    }

    pub fn compare(self: *ModelOrderNodeComparator, n1: *lg.LNode, n2: *lg.LNode) lg.Error!i32 {
        const pre = try self.t.check(n1, n2);
        if (pre != 0) return pre;
        if (self.ordering_strategy == .prefer_edges or n1.p.model_order == null or n2.p.model_order == null) {
            const p1_source = incomingSourcePort(n1);
            const p2_source = incomingSourcePort(n2);
            if (p1_source != null and p2_source != null) {
                const p1_node = p1_source.?.owner.?;
                const p2_node = p2_source.?.owner.?;
                if (p1_node == p2_node) {
                    for (p1_node.ports.items) |port| {
                        if (port == p1_source.?) {
                            try self.t.update(n2, n1);
                            return -1;
                        } else if (port == p2_source.?) {
                            try self.t.update(n1, n2);
                            return 1;
                        }
                    }
                    return intCompare(self.modelOrderFromConnectedEdges(n1), self.modelOrderFromConnectedEdges(n2));
                }
                for (self.previous_layer) |previous| {
                    if (previous == p1_node) {
                        try self.t.update(n2, n1);
                        return -1;
                    } else if (previous == p2_node) {
                        try self.t.update(n1, n2);
                        return 1;
                    }
                }
            }
            if (n1.p.model_order == null or n2.p.model_order == null) {
                const mo1 = self.modelOrderFromConnectedEdges(n1);
                const mo2 = self.modelOrderFromConnectedEdges(n2);
                if (mo1 > mo2) try self.t.update(n1, n2) else try self.t.update(n2, n1);
                return intCompare(mo1, mo2);
            }
        }
        const mo1 = n1.p.model_order.?;
        const mo2 = n2.p.model_order.?;
        if (mo1 > mo2) try self.t.update(n1, n2) else try self.t.update(n2, n1);
        return intCompare(mo1, mo2);
    }

    fn modelOrderFromConnectedEdges(self: *const ModelOrderNodeComparator, n: *lg.LNode) i32 {
        for (n.ports.items) |p| {
            if (p.incoming.items.len != 0) return p.incoming.items[0].p.model_order orelse 0;
        }
        return longEdgeReturnValue(self.long_edge_node_order);
    }
};
