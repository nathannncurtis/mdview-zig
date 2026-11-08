// SelfLoopHolder, SelfHyperLoop, SelfLoopPort, SelfLoopEdge, SelfHyperLoopLabels, SelfLoopType.
// Props: self_loop_holder (nodes); direction, spacing.label_label (graph). Overwrites LPort.id.
const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const Allocator = std.mem.Allocator;

pub const side_count = 5;

pub fn ord(s: lg.PortSide) usize {
    return @backingInt(s);
}

pub const SelfLoopType = enum {
    one_side,
    two_sides_corner,
    two_sides_opposing,
    three_sides,
    four_sides,

    pub fn fromPortSides(sides: [side_count]bool) ?SelfLoopType {
        std.debug.assert(!sides[ord(.undefined)]);
        var n: usize = 0;
        for (sides) |b| n += @intFromBool(b);
        return switch (n) {
            1 => .one_side,
            2 => if ((sides[ord(.east)] and sides[ord(.west)]) or (sides[ord(.north)] and sides[ord(.south)])) .two_sides_opposing else .two_sides_corner,
            3 => .three_sides,
            4 => .four_sides,
            else => null,
        };
    }
};

pub const SelfLoopPort = struct {
    l_port: *lg.LPort,
    had_only_self_loops: bool,
    incoming_sl_edges: std.ArrayList(*SelfLoopEdge) = .empty,
    outgoing_sl_edges: std.ArrayList(*SelfLoopEdge) = .empty,
    is_hidden: bool = false,

    fn create(a: Allocator, l_port: *lg.LPort) Allocator.Error!*SelfLoopPort {
        var only = true;
        for ([2][]*lg.LEdge{ l_port.incoming.items, l_port.outgoing.items }) |list| {
            for (list) |e| if (!e.isSelfLoop()) {
                only = false;
            };
        }
        const p = try a.create(SelfLoopPort);
        p.* = .{ .l_port = l_port, .had_only_self_loops = only };
        return p;
    }

    pub fn slNetFlow(self: *const SelfLoopPort) i32 {
        return @as(i32, @intCast(self.incoming_sl_edges.items.len)) - @as(i32, @intCast(self.outgoing_sl_edges.items.len));
    }
};

pub const SelfLoopEdge = struct {
    l_edge: *lg.LEdge,
    sl_hyper_loop: ?*SelfHyperLoop = null,
    sl_source: *SelfLoopPort,
    sl_target: *SelfLoopPort,

    fn create(a: Allocator, l_edge: *lg.LEdge, src: *SelfLoopPort, tgt: *SelfLoopPort) Allocator.Error!*SelfLoopEdge {
        const e = try a.create(SelfLoopEdge);
        e.* = .{ .l_edge = l_edge, .sl_source = src, .sl_target = tgt };
        try src.outgoing_sl_edges.append(a, e);
        try tgt.incoming_sl_edges.append(a, e);
        return e;
    }
};

pub const Alignment = enum { center, left, right, top };

pub const SelfHyperLoopLabels = struct {
    id: i32 = 0,
    l_labels: std.ArrayList(*lg.LLabel) = .empty,
    size: lg.Vec = .{},
    position: lg.Vec = .{},
    layout_direction: lg.Direction,
    label_label_spacing: f64,
    side: lg.PortSide = .undefined,
    alignment: Alignment = .center,
    alignment_reference_sl_port: ?*SelfLoopPort = null,

    fn addLLabels(self: *SelfHyperLoopLabels, a: Allocator, labels: []*lg.LLabel) Allocator.Error!void {
        for (labels) |l| {
            try self.l_labels.append(a, l);
            const s = l.size;
            if (self.layout_direction.isHorizontal()) {
                self.size.x = util.javaMax(self.size.x, s.x);
                self.size.y += s.y;
                if (self.l_labels.items.len > 1) self.size.y += self.label_label_spacing;
            } else {
                self.size.x += s.x;
                self.size.y = util.javaMax(self.size.y, s.y);
                if (self.l_labels.items.len > 1) self.size.x += self.label_label_spacing;
            }
        }
    }

    pub fn applyPlacement(self: *const SelfHyperLoopLabels, offset: lg.Vec) void {
        var x = self.position.x;
        var y = self.position.y;
        if (self.layout_direction.isHorizontal()) {
            for (self.l_labels.items) |l| {
                if (self.alignment == .left or self.side == .east) {
                    l.pos.x = x;
                } else if (self.alignment == .right or self.side == .west) {
                    l.pos.x = x + self.size.x - l.size.x;
                } else {
                    l.pos.x = x + (self.size.x - l.size.x) / 2;
                }
                l.pos.y = y;
                l.pos.add(offset);
                y += l.size.y + self.label_label_spacing;
            }
        } else {
            for (self.l_labels.items) |l| {
                l.pos.x = x;
                l.pos.y = if (self.side == .north) y + self.size.y - l.size.y else y;
                l.pos.add(offset);
                x += l.size.x + self.label_label_spacing;
            }
        }
    }
};

pub const SelfHyperLoop = struct {
    sl_holder: *SelfLoopHolder,
    sl_ports: std.ArrayList(*SelfLoopPort) = .empty,
    // a HashSet in ELK; elkjs (GWT) iterates identity-hashed sets in insertion order
    sl_edges: std.ArrayList(*SelfLoopEdge) = .empty,
    sl_labels: ?*SelfHyperLoopLabels = null,
    self_loop_type: ?SelfLoopType = null,
    ports_by_side: [side_count]std.ArrayList(*SelfLoopPort) = @splat(.empty),
    side_keys: std.ArrayList(lg.PortSide) = .empty,
    leftmost_port: ?*SelfLoopPort = null,
    rightmost_port: ?*SelfLoopPort = null,
    occupied_port_sides: [side_count]bool = @splat(false),
    routing_slot: [side_count]i32 = @splat(0),

    pub fn computePortsPerSide(self: *SelfHyperLoop, a: Allocator) Allocator.Error!void {
        var present: [side_count]bool = @splat(false);
        for (self.sl_ports.items) |p| {
            const s = p.l_port.side;
            if (!present[ord(s)]) {
                present[ord(s)] = true;
                try self.side_keys.append(a, s);
            }
            try self.ports_by_side[ord(s)].append(a, p);
        }
        self.self_loop_type = SelfLoopType.fromPortSides(present);
    }

    pub fn hasSide(self: *const SelfHyperLoop, s: lg.PortSide) bool {
        return self.ports_by_side[ord(s)].items.len > 0;
    }

    pub fn portsOnSide(self: *const SelfHyperLoop, s: lg.PortSide) []*SelfLoopPort {
        return self.ports_by_side[ord(s)].items;
    }

    fn addSelfLoopEdge(self: *SelfHyperLoop, a: Allocator, e: *SelfLoopEdge) Allocator.Error!void {
        for (self.sl_edges.items) |x| if (x == e) return;
        try self.sl_edges.append(a, e);
        e.sl_hyper_loop = self;
        if (std.mem.indexOfScalar(*SelfLoopPort, self.sl_ports.items, e.sl_source) == null) try self.sl_ports.append(a, e.sl_source);
        if (std.mem.indexOfScalar(*SelfLoopPort, self.sl_ports.items, e.sl_target) == null) try self.sl_ports.append(a, e.sl_target);
        const labels = e.l_edge.labels.items;
        if (labels.len > 0) {
            if (self.sl_labels == null) {
                const l_node = self.sl_holder.l_node;
                const g = l_node.graph.?;
                const sl = try a.create(SelfHyperLoopLabels);
                // shortcut: getIndividualOrInherited reads the graph value; node-level spacing overrides are not tracked
                sl.* = .{ .layout_direction = g.p.direction, .label_label_spacing = g.p.spacing.label_label };
                self.sl_labels = sl;
            }
            try self.sl_labels.?.addLLabels(a, labels);
        }
    }

    pub fn setRoutingSlot(self: *SelfHyperLoop, s: lg.PortSide, slot: i32) void {
        self.routing_slot[ord(s)] = slot;
        const c = &self.sl_holder.routing_slot_count[ord(s)];
        c.* = @max(c.*, slot + 1);
    }

    pub fn firstOccupiedSide(self: *const SelfHyperLoop) lg.PortSide {
        for (self.occupied_port_sides, 0..) |b, i| if (b) return @fromBackingInt(@intCast(i));
        unreachable;
    }
};

pub const SelfLoopHolder = struct {
    a: Allocator,
    l_node: *lg.LNode,
    sl_hyper_loops: std.ArrayList(*SelfHyperLoop) = .empty,
    sl_ports: std.ArrayList(*SelfLoopPort) = .empty,
    ports_hidden: bool = false,
    routing_slot_count: [side_count]i32 = @splat(0),

    pub fn of(n: *const lg.LNode) ?*SelfLoopHolder {
        const p = n.p.self_loop_holder orelse return null;
        return @ptrCast(@alignCast(p));
    }

    pub fn install(l_node: *lg.LNode) Allocator.Error!*SelfLoopHolder {
        const a = l_node.a;
        const h = try a.create(SelfLoopHolder);
        h.* = .{ .a = a, .l_node = l_node };
        l_node.p.self_loop_holder = h;
        try h.initialize();
        return h;
    }

    pub fn needsSelfLoopProcessing(n: *const lg.LNode) bool {
        if (n.type != .normal) return false;
        for (n.ports.items) |p| {
            for (p.outgoing.items) |e| if (e.isSelfLoop()) return true;
        }
        return false;
    }

    fn initialize(self: *SelfLoopHolder) Allocator.Error!void {
        const a = self.a;
        for (self.l_node.ports.items) |p| {
            for (p.outgoing.items) |e| {
                if (e.isSelfLoop()) {
                    const src = try self.portFor(e.source.?);
                    const tgt = try self.portFor(e.target.?);
                    _ = try SelfLoopEdge.create(a, e, src, tgt);
                }
            }
        }
        for (self.sl_ports.items) |p| p.l_port.id = 0;
        for (self.sl_ports.items) |p| {
            if (p.l_port.id == 0) try self.sl_hyper_loops.append(a, try self.initializeHyperLoop(p));
        }
    }

    fn portFor(self: *SelfLoopHolder, l_port: *lg.LPort) Allocator.Error!*SelfLoopPort {
        for (self.sl_ports.items) |p| if (p.l_port == l_port) return p;
        const p = try SelfLoopPort.create(self.a, l_port);
        try self.sl_ports.append(self.a, p);
        return p;
    }

    pub fn portOf(self: *const SelfLoopHolder, l_port: *const lg.LPort) ?*SelfLoopPort {
        for (self.sl_ports.items) |p| if (p.l_port == l_port) return p;
        return null;
    }

    fn initializeHyperLoop(self: *SelfLoopHolder, start: *SelfLoopPort) Allocator.Error!*SelfHyperLoop {
        const a = self.a;
        const loop = try a.create(SelfHyperLoop);
        loop.* = .{ .sl_holder = self };
        var queue: std.ArrayList(*SelfLoopPort) = .empty;
        var head: usize = 0;
        try queue.append(a, start);
        while (head < queue.items.len) {
            const cur = queue.items[head];
            head += 1;
            cur.l_port.id = 1;
            for (cur.outgoing_sl_edges.items) |e| {
                try loop.addSelfLoopEdge(a, e);
                if (e.sl_target.l_port.id == 0) try queue.append(a, e.sl_target);
            }
            for (cur.incoming_sl_edges.items) |e| {
                try loop.addSelfLoopEdge(a, e);
                if (e.sl_source.l_port.id == 0) try queue.append(a, e.sl_source);
            }
        }
        return loop;
    }
};
