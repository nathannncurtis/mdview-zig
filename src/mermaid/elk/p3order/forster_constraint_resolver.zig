const std = @import("std");
const lg = @import("../lgraph.zig");
const BarycenterState = @import("barycenter_heuristic.zig").BarycenterState;

const GroupList = std.ArrayList(*ConstraintGroup);

pub const ConstraintGroup = struct {
    resolver: *ForsterConstraintResolver,
    summed_weight: f64 = 0,
    degree: i32 = 0,
    nodes: []*lg.LNode,
    outgoing: ?GroupList = null,
    incoming: ?GroupList = null,
    incoming_count: i32 = 0,

    fn initSingle(r: *ForsterConstraintResolver, node: *lg.LNode) lg.Error!*ConstraintGroup {
        const g = try r.a.create(ConstraintGroup);
        const nodes = try r.a.alloc(*lg.LNode, 1);
        nodes[0] = node;
        g.* = .{ .resolver = r, .nodes = nodes };
        return g;
    }

    fn initMerged(r: *ForsterConstraintResolver, g1: *ConstraintGroup, g2: *ConstraintGroup) lg.Error!*ConstraintGroup {
        const a = r.a;
        const g = try a.create(ConstraintGroup);
        const nodes = try a.alloc(*lg.LNode, g1.nodes.len + g2.nodes.len);
        @memcpy(nodes[0..g1.nodes.len], g1.nodes);
        @memcpy(nodes[g1.nodes.len..], g2.nodes);
        g.* = .{ .resolver = r, .nodes = nodes };
        if (g1.outgoing) |o1| {
            var out: GroupList = .empty;
            try out.appendSlice(a, o1.items);
            removeFirst(&out, g2);
            if (g2.outgoing) |o2| {
                for (o2.items) |candidate| {
                    if (candidate == g1) continue;
                    if (contains(out.items, candidate)) {
                        candidate.incoming_count -= 1;
                    } else {
                        try out.append(a, candidate);
                    }
                }
            }
            g.outgoing = out;
        } else if (g2.outgoing) |o2| {
            var out: GroupList = .empty;
            try out.appendSlice(a, o2.items);
            removeFirst(&out, g1);
            g.outgoing = out;
        }
        g.summed_weight = g1.summed_weight + g2.summed_weight;
        g.degree = g1.degree + g2.degree;
        if (g.degree > 0) {
            g.setBarycenter(g.summed_weight / @as(f64, @floatFromInt(g.degree)));
        } else if (g1.getBarycenter() != null and g2.getBarycenter() != null) {
            g.setBarycenter((g1.getBarycenter().? + g2.getBarycenter().?) / 2);
        } else if (g1.getBarycenter() != null) {
            g.setBarycenter(g1.getBarycenter());
        } else if (g2.getBarycenter() != null) {
            g.setBarycenter(g2.getBarycenter());
        }
        return g;
    }

    fn setBarycenter(self: *ConstraintGroup, b: ?f64) void {
        for (self.nodes) |n| self.resolver.stateOf(n).barycenter = b;
    }
    fn getBarycenter(self: *const ConstraintGroup) ?f64 {
        return self.resolver.stateOf(self.nodes[0]).barycenter;
    }
    fn bary(self: *const ConstraintGroup) f64 {
        return self.getBarycenter() orelse 0;
    }
    fn outgoingList(self: *ConstraintGroup) *GroupList {
        if (self.outgoing == null) self.outgoing = .empty;
        return &self.outgoing.?;
    }
    fn hasOutgoing(self: *const ConstraintGroup) bool {
        return if (self.outgoing) |o| o.items.len > 0 else false;
    }
    fn incomingList(self: *ConstraintGroup) *GroupList {
        if (self.incoming == null) self.incoming = .empty;
        return &self.incoming.?;
    }
    fn hasIncoming(self: *const ConstraintGroup) bool {
        return if (self.incoming) |o| o.items.len > 0 else false;
    }
};

fn contains(items: []*ConstraintGroup, g: *ConstraintGroup) bool {
    for (items) |x| if (x == g) return true;
    return false;
}

fn removeFirst(list: *GroupList, g: *ConstraintGroup) void {
    for (list.items, 0..) |x, i| if (x == g) {
        _ = list.orderedRemove(i);
        return;
    };
}

fn indexOf(items: []*ConstraintGroup, g: *ConstraintGroup) i64 {
    for (items, 0..) |x, i| if (x == g) return @intCast(i);
    return -1;
}

pub const ForsterConstraintResolver = struct {
    a: std.mem.Allocator,
    constraints_between_non_dummies: bool = false,
    // LinkedHashMultimap<LNode, LNode>
    layout_units: std.AutoHashMapUnmanaged(*lg.LNode, *std.ArrayList(*lg.LNode)) = .empty,
    barycenter_states: [][]BarycenterState,
    constraint_groups: [][]*ConstraintGroup,

    pub fn create(a: std.mem.Allocator, order: [][]*lg.LNode) lg.Error!*ForsterConstraintResolver {
        const self = try a.create(ForsterConstraintResolver);
        self.* = .{
            .a = a,
            .barycenter_states = try a.alloc([]BarycenterState, order.len),
            .constraint_groups = try a.alloc([]*ConstraintGroup, order.len),
        };
        if (order.len > 0 and order[0].len > 0) {
            self.constraints_between_non_dummies = order[0][0].graph.?.p.in_layer_successor_constraints_between_non_dummies;
        }
        return self;
    }

    pub fn initAtLayerLevel(self: *ForsterConstraintResolver, l: usize, order: [][]*lg.LNode) lg.Error!void {
        self.barycenter_states[l] = try self.a.alloc(BarycenterState, order[l].len);
        self.constraint_groups[l] = try self.a.alloc(*ConstraintGroup, order[l].len);
    }

    pub fn initAtNodeLevel(self: *ForsterConstraintResolver, l: usize, n: usize, order: [][]*lg.LNode) lg.Error!void {
        try self.initNode(order[l][n], true);
    }

    fn initNode(self: *ForsterConstraintResolver, node: *lg.LNode, full_init: bool) lg.Error!void {
        const li: usize = @intCast(node.layer.?.id);
        const ni: usize = @intCast(node.id);
        self.constraint_groups[li][ni] = try ConstraintGroup.initSingle(self, node);
        if (full_init) {
            self.barycenter_states[li][ni] = .{ .node = node };
            if (node.p.in_layer_layout_unit) |unit| {
                const gop = try self.layout_units.getOrPut(self.a, unit);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try self.a.create(std.ArrayList(*lg.LNode));
                    gop.value_ptr.*.* = .empty;
                }
                const vals = gop.value_ptr.*;
                for (vals.items) |v| {
                    if (v == node) break;
                } else try vals.append(self.a, node);
            }
        }
    }

    fn unitNodes(self: *ForsterConstraintResolver, node: *lg.LNode) []*lg.LNode {
        return if (self.layout_units.get(node)) |v| v.items else &.{};
    }

    pub fn processConstraints(self: *ForsterConstraintResolver, nodes: *std.ArrayList(*lg.LNode)) lg.Error!void {
        if (self.constraints_between_non_dummies) {
            try self.processConstraintsFor(nodes, true);
            for (nodes.items) |node| try self.initNode(node, false);
        }
        try self.processConstraintsFor(nodes, false);
    }

    fn processConstraintsFor(self: *ForsterConstraintResolver, nodes: *std.ArrayList(*lg.LNode), only_between_normal: bool) lg.Error!void {
        var groups: GroupList = .empty;
        for (nodes.items) |node| try groups.append(self.a, self.groupOf(node));
        try self.buildConstraintsGraph(groups.items, only_between_normal);
        while (try self.findViolatedConstraint(groups.items)) |v| {
            try self.handleViolatedConstraint(v.first, v.second, &groups);
        }
        nodes.clearRetainingCapacity();
        for (groups.items) |group| {
            for (group.nodes) |node| {
                try nodes.append(self.a, node);
                self.stateOf(node).barycenter = group.getBarycenter();
            }
        }
    }

    fn buildConstraintsGraph(self: *ForsterConstraintResolver, groups: []*ConstraintGroup, only_between_normal: bool) lg.Error!void {
        for (groups) |group| {
            group.outgoing = null;
            group.incoming_count = 0;
        }
        var last_non_dummy: ?*lg.LNode = null;
        for (groups) |group| {
            const node = group.nodes[0];
            if (only_between_normal and node.type != .normal) continue;
            for (node.p.in_layer_successor_constraints.items) |successor| {
                if (!only_between_normal or successor.type == .normal) {
                    try group.outgoingList().append(self.a, self.groupOf(successor));
                    self.groupOf(successor).incoming_count += 1;
                }
            }
            if (!only_between_normal and node.type == .normal) {
                if (last_non_dummy) |last| {
                    for (self.unitNodes(last)) |last_unit_node| {
                        for (self.unitNodes(node)) |current_unit_node| {
                            try self.groupOf(last_unit_node).outgoingList().append(self.a, self.groupOf(current_unit_node));
                            self.groupOf(current_unit_node).incoming_count += 1;
                        }
                    }
                }
                last_non_dummy = node;
            }
        }
    }

    const Violation = struct { first: *ConstraintGroup, second: *ConstraintGroup };

    fn findViolatedConstraint(self: *ForsterConstraintResolver, groups: []*ConstraintGroup) lg.Error!?Violation {
        var active: ?GroupList = null;
        for (groups) |group| {
            group.incoming = null;
            if (group.hasOutgoing() and group.incoming_count == 0) {
                if (active == null) active = .empty;
                try active.?.append(self.a, group);
            }
        }
        if (active) |*act| {
            while (act.items.len != 0) {
                const group = act.orderedRemove(0);
                if (group.hasIncoming()) {
                    for (group.incoming.?.items) |predecessor| {
                        // Double.floatValue does not narrow in elkjs (GWT), so this is a double comparison
                        if (predecessor.bary() == group.bary()) {
                            if (indexOf(groups, predecessor) > indexOf(groups, group)) return .{ .first = predecessor, .second = group };
                        } else if (predecessor.bary() > group.bary()) {
                            return .{ .first = predecessor, .second = group };
                        }
                    }
                }
                for (group.outgoingList().items) |successor| {
                    const inc = successor.incomingList();
                    try inc.insert(self.a, 0, group);
                    if (successor.incoming_count == inc.items.len) try act.append(self.a, successor);
                }
            }
        }
        return null;
    }

    fn handleViolatedConstraint(self: *ForsterConstraintResolver, first: *ConstraintGroup, second: *ConstraintGroup, groups: *GroupList) lg.Error!void {
        const merged = try ConstraintGroup.initMerged(self, first, second);
        var inserted = false;
        var i: usize = 0;
        while (i < groups.items.len) {
            const g = groups.items[i];
            if (g == first or g == second) {
                _ = groups.orderedRemove(i);
                continue;
            }
            if (!inserted and g.bary() > merged.bary()) {
                // ListIterator.previous() + add(): the current group is visited again after the insert
                try groups.insert(self.a, i, merged);
                inserted = true;
                i += 1;
                continue;
            }
            if (g.hasOutgoing()) {
                const out = &g.outgoing.?;
                const had_first = contains(out.items, first);
                removeFirst(out, first);
                const had_second = contains(out.items, second);
                removeFirst(out, second);
                if (had_first or had_second) {
                    try out.append(self.a, merged);
                    merged.incoming_count += 1;
                }
            }
            i += 1;
        }
        if (!inserted) try groups.append(self.a, merged);
    }

    fn groupOf(self: *ForsterConstraintResolver, node: *lg.LNode) *ConstraintGroup {
        return self.constraint_groups[@intCast(node.layer.?.id)][@intCast(node.id)];
    }

    pub fn stateOf(self: *ForsterConstraintResolver, node: *lg.LNode) *BarycenterState {
        return &self.barycenter_states[@intCast(node.layer.?.id)][@intCast(node.id)];
    }
};
