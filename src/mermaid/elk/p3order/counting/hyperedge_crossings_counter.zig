const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const cc = @import("crossings_counter.zig");

const Hyperedge = struct {
    edges: std.ArrayList(*lg.LEdge) = .empty,
    ports: std.ArrayList(*lg.LPort) = .empty,
    upper_left: i32 = 0,
    lower_left: i32 = 0,
    upper_right: i32 = 0,
    lower_right: i32 = 0,
    // stands in for the GWT identity hash, which is handed out in creation order here
    hash: i32,

    fn compareTo(_: void, self: *Hyperedge, other: *Hyperedge) lg.Error!i32 {
        if (self.upper_left < other.upper_left) return -1;
        if (self.upper_left > other.upper_left) return 1;
        if (self.upper_right < other.upper_right) return -1;
        if (self.upper_right > other.upper_right) return 1;
        return self.hash -% other.hash;
    }
};

const CornerType = enum { upper, lower };

const Corner = struct {
    hyperedge: *Hyperedge,
    position: i32,
    opposite_position: i32,
    type: CornerType,

    fn compareTo(_: void, self: Corner, other: Corner) lg.Error!i32 {
        if (self.position < other.position) return -1;
        if (self.position > other.position) return 1;
        if (self.opposite_position < other.opposite_position) return -1;
        if (self.opposite_position > other.opposite_position) return 1;
        if (self.hyperedge != other.hyperedge) return self.hyperedge.hash -% other.hyperedge.hash;
        if (self.type == .upper and other.type == .lower) return -1;
        if (self.type == .lower and other.type == .upper) return 1;
        return 0;
    }
};

pub const HyperedgeCrossingsCounter = struct {
    a: std.mem.Allocator,
    port_pos: []i32,

    pub fn countCrossings(self: *HyperedgeCrossingsCounter, left_layer: []*lg.LNode, right_layer: []*lg.LNode) lg.Error!i32 {
        const a = self.a;
        const pp = self.port_pos;
        var source_count: i32 = 0;
        for (left_layer) |node| {
            for (node.ports.items) |port| {
                var port_edges: i32 = 0;
                for (port.outgoing.items) |edge| {
                    if (node.layer != edge.target.?.owner.?.layer) port_edges += 1;
                }
                if (port_edges > 0) {
                    pp[cc.idx(port.id)] = source_count;
                    source_count += 1;
                }
            }
        }
        var target_count: i32 = 0;
        for (right_layer) |node| {
            var north_input_ports: i32 = 0;
            for (node.ports.items) |port| {
                if (port.side == .north) {
                    for (port.incoming.items) |edge| {
                        if (node.layer != edge.source.?.owner.?.layer) {
                            north_input_ports += 1;
                            break;
                        }
                    }
                } else break;
            }
            var other_input_ports: i32 = 0;
            var k = node.ports.items.len;
            while (k > 0) {
                k -= 1;
                const port = node.ports.items[k];
                var port_edges: i32 = 0;
                for (port.incoming.items) |edge| {
                    if (node.layer != edge.source.?.owner.?.layer) port_edges += 1;
                }
                if (port_edges > 0) {
                    if (port.side == .north) {
                        pp[cc.idx(port.id)] = target_count;
                        target_count += 1;
                    } else {
                        pp[cc.idx(port.id)] = target_count + north_input_ports + other_input_ports;
                        other_input_ports += 1;
                    }
                }
            }
            target_count += other_input_ports;
        }

        var port2he: std.AutoHashMapUnmanaged(*lg.LPort, *Hyperedge) = .empty;
        var set: std.ArrayList(*Hyperedge) = .empty;
        var next_hash: i32 = 0;
        for (left_layer) |node| {
            for (node.ports.items) |source_port| {
                for (source_port.outgoing.items) |edge| {
                    const target_port = edge.target.?;
                    if (node.layer == target_port.owner.?.layer) continue;
                    const source_he = port2he.get(source_port);
                    const target_he = port2he.get(target_port);
                    if (source_he == null and target_he == null) {
                        const he = try a.create(Hyperedge);
                        he.* = .{ .hash = next_hash };
                        next_hash += 1;
                        try set.append(a, he);
                        try he.edges.append(a, edge);
                        try he.ports.append(a, source_port);
                        try port2he.put(a, source_port, he);
                        try he.ports.append(a, target_port);
                        try port2he.put(a, target_port, he);
                    } else if (source_he == null) {
                        try target_he.?.edges.append(a, edge);
                        try target_he.?.ports.append(a, source_port);
                        try port2he.put(a, source_port, target_he.?);
                    } else if (target_he == null) {
                        try source_he.?.edges.append(a, edge);
                        try source_he.?.ports.append(a, target_port);
                        try port2he.put(a, target_port, source_he.?);
                    } else if (source_he == target_he) {
                        try source_he.?.edges.append(a, edge);
                    } else {
                        const s = source_he.?;
                        const t = target_he.?;
                        try s.edges.append(a, edge);
                        for (t.ports.items) |p| try port2he.put(a, p, s);
                        try s.edges.appendSlice(a, t.edges.items);
                        try s.ports.appendSlice(a, t.ports.items);
                        lg.removeItem(Hyperedge, &set, t);
                    }
                }
            }
        }

        const hyperedges = set.items;
        const left_ref = left_layer[0].layer;
        const right_ref = right_layer[0].layer;
        for (hyperedges) |he| {
            he.upper_left = source_count;
            he.upper_right = target_count;
            for (he.ports.items) |port| {
                const pos = pp[cc.idx(port.id)];
                if (port.owner.?.layer == left_ref) {
                    if (pos < he.upper_left) he.upper_left = pos;
                    if (pos > he.lower_left) he.lower_left = pos;
                } else if (port.owner.?.layer == right_ref) {
                    if (pos < he.upper_right) he.upper_right = pos;
                    if (pos > he.lower_right) he.lower_right = pos;
                }
            }
        }
        try util.javaSort(*Hyperedge, a, hyperedges, {}, Hyperedge.compareTo);

        const south_sequence = try a.alloc(i32, hyperedges.len);
        const compress_deltas = try a.alloc(i32, @intCast(target_count + 1));
        @memset(compress_deltas, 0);
        for (hyperedges, 0..) |he, i| {
            south_sequence[i] = he.upper_right;
            compress_deltas[cc.idx(south_sequence[i])] = 1;
        }
        var delta: i32 = 0;
        for (compress_deltas) |*d| {
            if (d.* == 1) d.* = delta else delta -= 1;
        }
        var q: i32 = 0;
        for (south_sequence) |*s| {
            s.* += compress_deltas[cc.idx(s.*)];
            q = @max(q, s.* + 1);
        }
        var first_index: i32 = 1;
        while (first_index < q) first_index *= 2;
        const tree_size = 2 * first_index - 1;
        first_index -= 1;
        const tree = try a.alloc(i32, @intCast(tree_size));
        @memset(tree, 0);
        var crossings: i32 = 0;
        for (south_sequence) |s| {
            var index = s + first_index;
            tree[cc.idx(index)] += 1;
            while (index > 0) {
                if (@rem(index, 2) > 0) crossings += tree[cc.idx(index + 1)];
                index = @divTrunc(index - 1, 2);
                tree[cc.idx(index)] += 1;
            }
        }

        crossings += try countCorners(a, hyperedges, true);
        crossings += try countCorners(a, hyperedges, false);
        return crossings;
    }
};

fn countCorners(a: std.mem.Allocator, hyperedges: []*Hyperedge, left: bool) lg.Error!i32 {
    const corners = try a.alloc(Corner, hyperedges.len * 2);
    for (hyperedges, 0..) |he, i| {
        const upper = if (left) he.upper_left else he.upper_right;
        const lower = if (left) he.lower_left else he.lower_right;
        corners[2 * i] = .{ .hyperedge = he, .position = upper, .opposite_position = lower, .type = .upper };
        corners[2 * i + 1] = .{ .hyperedge = he, .position = lower, .opposite_position = upper, .type = .lower };
    }
    try util.javaSort(Corner, a, corners, {}, Corner.compareTo);
    var open: i32 = 0;
    var crossings: i32 = 0;
    for (corners) |c| switch (c.type) {
        .upper => open += 1,
        .lower => {
            open -= 1;
            crossings += open;
        },
    };
    return crossings;
}
