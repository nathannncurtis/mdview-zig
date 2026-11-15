const std = @import("std");
const lg = @import("../../lgraph.zig");
const Transitive = @import("model_order_node_comparator.zig").Transitive;

fn intCompare(x: i32, y: i32) i32 {
    return if (x < y) -1 else if (x == y) 0 else 1;
}

pub const ModelOrderPortComparator = struct {
    target_node_model_order: ?*std.AutoHashMapUnmanaged(*lg.LNode, i32),
    port_model_order: bool,
    previous_layer: []*lg.LNode,
    strategy: lg.OrderingStrategy,
    t: Transitive(lg.LPort),

    pub fn init(a: std.mem.Allocator, previous_layer: []*lg.LNode, strategy: lg.OrderingStrategy, target_node_model_order: ?*std.AutoHashMapUnmanaged(*lg.LNode, i32), port_model_order: bool) ModelOrderPortComparator {
        return .{ .target_node_model_order = target_node_model_order, .port_model_order = port_model_order, .previous_layer = previous_layer, .strategy = strategy, .t = .{ .a = a } };
    }

    pub fn compare(self: *ModelOrderPortComparator, original_p1: *lg.LPort, original_p2: *lg.LPort) lg.Error!i32 {
        var p1 = original_p1;
        var p2 = original_p2;
        if (self.port_model_order and p1.side == .west and p2.side == .west) {
            p1 = original_p2;
            p2 = original_p1;
        }
        const pre = try self.t.check(p1, p2);
        if (pre != 0) return pre;
        if (p1.side != p2.side) {
            const result = intCompare(@backingInt(p1.side), @backingInt(p2.side));
            if (result == -1) try self.t.update(p2, p1) else try self.t.update(p1, p2);
            return result;
        }
        if (p1.incoming.items.len != 0 and p2.incoming.items.len != 0) {
            if (self.port_model_order) {
                if (try self.portModelOrderResult(p1, p2)) |r| return r;
            }
            const p1_node = p1.incoming.items[0].source.?.owner.?;
            const p2_node = p2.incoming.items[0].source.?.owner.?;
            if (p1_node == p2_node) {
                const mo1 = p1.incoming.items[0].p.model_order orelse 0;
                const mo2 = p2.incoming.items[0].p.model_order orelse 0;
                if (mo1 > mo2) try self.t.update(p1, p2) else try self.t.update(p2, p1);
                return intCompare(mo1, mo2);
            }
            for (self.previous_layer) |previous| {
                if (previous == p1_node) {
                    try self.t.update(p1, p2);
                    return 1;
                } else if (previous == p2_node) {
                    try self.t.update(p2, p1);
                    return -1;
                }
            }
        }
        if (p1.outgoing.items.len != 0 and p2.outgoing.items.len != 0) {
            const p1_target = p1.p.long_edge_target_node;
            const p2_target = p2.p.long_edge_target_node;
            if (self.strategy == .prefer_nodes and p1_target != null and p2_target != null and
                p1_target.?.p.model_order != null and p2_target.?.p.model_order != null)
            {
                const mo1 = p1_target.?.p.model_order.?;
                const mo2 = p2_target.?.p.model_order.?;
                if (mo1 > mo2) try self.t.update(p1, p2) else try self.t.update(p2, p1);
                return intCompare(mo1, mo2);
            }
            if (self.port_model_order) {
                if (try self.portModelOrderResult(p1, p2)) |r| return r;
            }
            var p1_order: i32 = 0;
            var p2_order: i32 = 0;
            if (p1.outgoing.items[0].p.model_order) |mo| p1_order = mo;
            // ELK reads p1's edge for p2 here
            if (p2.outgoing.items[0].p.model_order != null) p2_order = p1.outgoing.items[0].p.model_order orelse 0;
            if (p1_target != null and p1_target == p2_target) {
                const r1 = p1.outgoing.items[0].p.reversed;
                const r2 = p2.outgoing.items[0].p.reversed;
                if (r1 and !r2) {
                    try self.t.update(p1, p2);
                    return 1;
                } else if (!r1 and r2) {
                    try self.t.update(p2, p1);
                    return -1;
                }
                if (p1_order > p2_order) try self.t.update(p1, p2) else try self.t.update(p2, p1);
                return intCompare(p1_order, p2_order);
            }
            if (self.target_node_model_order) |m| {
                if (p1_target) |t1| {
                    if (m.get(t1)) |v| p1_order = v;
                }
                if (p2_target) |t2| {
                    if (m.get(t2)) |v| p2_order = v;
                }
            }
            if (p1_order > p2_order) try self.t.update(p1, p2) else try self.t.update(p2, p1);
            return intCompare(p1_order, p2_order);
        }
        if (p1.incoming.items.len != 0 and p2.outgoing.items.len != 0) {
            try self.t.update(p1, p2);
            return 1;
        } else if (p1.outgoing.items.len != 0 and p2.incoming.items.len != 0) {
            try self.t.update(p2, p1);
            return -1;
        } else if (p1.p.model_order != null and p2.p.model_order != null) {
            const mo1 = p1.p.model_order.?;
            const mo2 = p2.p.model_order.?;
            if (mo1 > mo2) try self.t.update(p1, p2) else try self.t.update(p2, p1);
            return intCompare(mo1, mo2);
        } else {
            try self.t.update(p2, p1);
            return -1;
        }
    }

    fn portModelOrderResult(self: *ModelOrderPortComparator, p1: *lg.LPort, p2: *lg.LPort) lg.Error!?i32 {
        const result = checkPortModelOrder(p1, p2);
        if (result == 0) return null;
        if (result == -1) try self.t.update(p2, p1) else if (result == 1) try self.t.update(p1, p2);
        return result;
    }

    pub fn checkPortModelOrder(p1: *lg.LPort, p2: *lg.LPort) i32 {
        if (p1.p.model_order != null and p2.p.model_order != null) return intCompare(p1.p.model_order.?, p2.p.model_order.?);
        return 0;
    }
};
