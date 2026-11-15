// LinearSegmentsNodePlacer. With external ports the driver adds HIERARCHICAL_PORT_POSITION_PROCESSOR before phase 5.
const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const spacings = @import("../spacings.zig");

const Allocator = std.mem.Allocator;
const min_int: i32 = std.math.minInt(i32);

const Segment = struct {
    nodes: std.ArrayList(*lg.LNode) = .empty,
    id: i32 = 0,
    index_in_last_layer: i32 = -1,
    last_layer: i32 = -1,
    deflection: f64 = 0,
    weight: i32 = 0,
    ref_segment: ?*Segment = null,

    fn region(self: *Segment) *Segment {
        var seg = self;
        while (seg.ref_segment) |r| seg = r;
        return seg;
    }

    fn split(self: *Segment, a: Allocator, node: *lg.LNode, new_id: i32) Allocator.Error!*Segment {
        const node_index = std.mem.indexOfScalar(*lg.LNode, self.nodes.items, node).?;
        const ns = try a.create(Segment);
        ns.* = .{ .id = new_id };
        for (self.nodes.items[node_index..]) |moved| {
            moved.id = new_id;
            try ns.nodes.append(a, moved);
        }
        self.nodes.shrinkRetainingCapacity(node_index);
        return ns;
    }
};

const Prio = struct { input: i32, output: i32 };

const Placer = struct {
    a: Allocator,
    g: *lg.LGraph,
    segments: []*Segment = &.{},
    prios: std.AutoHashMapUnmanaged(*lg.LNode, Prio) = .empty,

    fn prio(self: *const Placer, n: *lg.LNode) Prio {
        return self.prios.get(n).?;
    }
};

pub fn process(g: *lg.LGraph) lg.Error!void {
    var p: Placer = .{ .a = g.a, .g = g };
    for (g.layers.items, 0..) |layer, i| layer.id = @intCast(i);
    try sortLinearSegments(&p);
    try createUnbalancedPlacement(&p);
    balancePlacement(&p);
    postProcess(&p);
}

fn sortLinearSegments(p: *Placer) lg.Error!void {
    const a = p.a;
    var segment_list: std.ArrayList(*Segment) = .empty;
    for (p.g.layers.items) |layer| for (layer.nodes.items) |node| {
        node.id = -1;
        var inprio: i32 = min_int;
        var outprio: i32 = min_int;
        for (node.ports.items) |port| {
            for (port.incoming.items) |edge| inprio = @max(inprio, edge.p.priority_straightness);
            for (port.outgoing.items) |edge| outprio = @max(outprio, edge.p.priority_straightness);
        }
        try p.prios.put(a, node, .{ .input = inprio, .output = outprio });
    };

    var next_id: i32 = 0;
    for (p.g.layers.items) |layer| for (layer.nodes.items) |node| {
        if (node.id < 0) {
            const seg = try a.create(Segment);
            seg.* = .{ .id = next_id };
            next_id += 1;
            _ = try fillSegment(a, node, seg);
            try segment_list.append(a, seg);
        }
    };

    var outgoing: std.ArrayList(std.ArrayList(*Segment)) = .empty;
    var incoming_count: std.ArrayList(i32) = .empty;
    for (segment_list.items) |_| {
        try outgoing.append(a, .empty);
        try incoming_count.append(a, 0);
    }
    try createDependencyGraphEdges(p, &segment_list, &outgoing, &incoming_count);

    var no_incoming: std.ArrayList(*Segment) = .empty;
    for (segment_list.items, 0..) |seg, i| {
        if (incoming_count.items[i] == 0) try no_incoming.append(a, seg);
    }
    const new_ranks = try a.alloc(i32, segment_list.items.len);
    @memset(new_ranks, 0);
    var next_rank: i32 = 0;
    var head: usize = 0;
    while (head < no_incoming.items.len) {
        const seg = no_incoming.items[head];
        head += 1;
        new_ranks[@intCast(seg.id)] = next_rank;
        next_rank += 1;
        const out = &outgoing.items[@intCast(seg.id)];
        for (out.items) |target| {
            const t: usize = @intCast(target.id);
            incoming_count.items[t] -= 1;
            if (incoming_count.items[t] == 0) try no_incoming.append(a, target);
        }
        out.clearRetainingCapacity();
    }

    p.segments = try a.alloc(*Segment, segment_list.items.len);
    for (segment_list.items, 0..) |ls, i| {
        const rank = new_ranks[i];
        p.segments[@intCast(rank)] = ls;
        ls.id = rank;
        for (ls.nodes.items) |node| node.id = rank;
    }
}

fn createDependencyGraphEdges(
    p: *Placer,
    segment_list: *std.ArrayList(*Segment),
    outgoing: *std.ArrayList(std.ArrayList(*Segment)),
    incoming_count: *std.ArrayList(i32),
) lg.Error!void {
    const a = p.a;
    var next_id: i32 = @intCast(segment_list.items.len);
    var layer_index: i32 = 0;
    for (p.g.layers.items) |layer| {
        const nodes = layer.nodes.items;
        if (nodes.len == 0) continue;
        var index_in_layer: usize = 0;
        var previous: ?*lg.LNode = null;
        var current: ?*lg.LNode = nodes[0];
        while (current) |current_node| {
            var current_segment = segment_list.items[@intCast(current_node.id)];
            if (current_segment.index_in_last_layer >= 0) {
                var cycle_segment: ?*Segment = null;
                for (nodes[index_in_layer + 1 ..]) |cycle_node| {
                    const cs = segment_list.items[@intCast(cycle_node.id)];
                    if (cs.last_layer == current_segment.last_layer and cs.index_in_last_layer < current_segment.index_in_last_layer) {
                        cycle_segment = cs;
                        break;
                    }
                }
                if (cycle_segment != null) {
                    if (previous) |prev| {
                        incoming_count.items[@intCast(current_node.id)] -= 1;
                        lg.removeItem(Segment, &outgoing.items[@intCast(prev.id)], current_segment);
                    }
                    current_segment = try current_segment.split(a, current_node, next_id);
                    next_id += 1;
                    try segment_list.append(a, current_segment);
                    try outgoing.append(a, .empty);
                    if (previous) |prev| {
                        try outgoing.items[@intCast(prev.id)].append(a, current_segment);
                        try incoming_count.append(a, 1);
                    } else {
                        try incoming_count.append(a, 0);
                    }
                }
            }

            var next_node: ?*lg.LNode = null;
            if (index_in_layer + 1 < nodes.len) {
                const nn = nodes[index_in_layer + 1];
                next_node = nn;
                const next_segment = segment_list.items[@intCast(nn.id)];
                try outgoing.items[@intCast(current_node.id)].append(a, next_segment);
                incoming_count.items[@intCast(nn.id)] += 1;
            }

            current_segment.last_layer = layer_index;
            current_segment.index_in_last_layer = @intCast(index_in_layer);
            index_in_layer += 1;
            previous = current_node;
            current = next_node;
        }
        layer_index += 1;
    }
}

fn fillSegment(a: Allocator, node: *lg.LNode, segment: *Segment) Allocator.Error!bool {
    if (node.id >= 0) return false;
    node.id = segment.id;
    try segment.nodes.append(a, node);
    if (node.type == .long_edge or node.type == .north_south_port) {
        for (node.ports.items) |source_port| {
            for (source_port.outgoing.items) |edge| {
                const target_node = edge.target.?.owner.?;
                if (node.layer != target_node.layer) {
                    if (target_node.type == .long_edge or target_node.type == .north_south_port) {
                        if (try fillSegment(a, target_node, segment)) return true;
                    }
                }
            }
        }
    }
    return true;
}

fn createUnbalancedPlacement(p: *Placer) Allocator.Error!void {
    const a = p.a;
    const n_layers = p.g.layers.items.len;
    const node_count = try a.alloc(i32, n_layers);
    @memset(node_count, 0);
    const recent_node = try a.alloc(?*lg.LNode, n_layers);
    @memset(recent_node, null);
    for (p.segments) |segment| {
        var uppermost_place: f64 = 0.0;
        for (segment.nodes.items) |node| {
            const li: usize = @intCast(node.layer.?.id);
            node_count[li] += 1;
            var spacing = p.g.p.spacing.edge_edge;
            if (recent_node[li]) |recent| spacing = spacings.getVerticalSpacing(recent, node);
            uppermost_place = util.javaMax(uppermost_place, node.layer.?.size.y + spacing);
        }
        for (segment.nodes.items) |node| {
            node.pos.y = uppermost_place + node.margin.top;
            const layer = node.layer.?;
            layer.size.y = uppermost_place + node.margin.top + node.size.y + node.margin.bottom;
            recent_node[@intCast(layer.id)] = node;
        }
    }
}

const Mode = enum { forw_pendulum, backw_pendulum, rubber };

const threshold_factor = 20.0;
const pendulum_iters_initial = 4;
const final_iters_initial = 3;

fn balancePlacement(p: *Placer) void {
    const deflection_dampening = p.g.p.linear_segments_deflection_dampening;
    const thoroughness = p.g.p.thoroughness;
    var pendulum_iters: i32 = pendulum_iters_initial;
    var final_iters: i32 = final_iters_initial;
    const threshold = threshold_factor / @as(f64, @floatFromInt(thoroughness));
    const int_max: f64 = @floatFromInt(std.math.maxInt(i32));

    var ready = false;
    var mode: Mode = .forw_pendulum;
    var last_total_deflection = int_max;
    while (true) {
        const incoming = mode != .backw_pendulum;
        const outgoing = mode != .forw_pendulum;
        var total_deflection: f64 = 0;
        for (p.segments) |segment| {
            segment.ref_segment = null;
            calcDeflection(p, segment, incoming, outgoing, deflection_dampening);
            total_deflection += @abs(segment.deflection);
        }
        while (mergeRegions(p)) {}
        for (p.segments) |segment| {
            const deflection = segment.region().deflection;
            if (deflection != 0) {
                for (segment.nodes.items) |node| node.pos.y += deflection;
            }
        }
        if (mode == .forw_pendulum or mode == .backw_pendulum) {
            pendulum_iters -= 1;
            if (pendulum_iters <= 0 and (total_deflection < last_total_deflection or -pendulum_iters > thoroughness)) {
                mode = .rubber;
                last_total_deflection = int_max;
            } else if (mode == .forw_pendulum) {
                mode = .backw_pendulum;
                last_total_deflection = total_deflection;
            } else {
                mode = .forw_pendulum;
                last_total_deflection = total_deflection;
            }
        } else {
            ready = total_deflection >= last_total_deflection or last_total_deflection - total_deflection < threshold;
            last_total_deflection = total_deflection;
            if (ready) final_iters -= 1;
        }
        if (ready and final_iters <= 0) break;
    }
}

fn calcDeflection(p: *Placer, segment: *Segment, incoming: bool, outgoing: bool, deflection_dampening: f64) void {
    var segment_deflection: f64 = 0;
    var node_weight_sum: i32 = 0;
    for (segment.nodes.items) |node| {
        var node_deflection: f64 = 0;
        var edge_weight_sum: i32 = 0;
        const pr = p.prio(node);
        const input_prio = if (incoming) pr.input else min_int;
        const output_prio = if (outgoing) pr.output else min_int;
        const min_prio = @max(input_prio, output_prio);
        for (node.ports.items) |port| {
            const portpos = node.pos.y + port.pos.y + port.anchor.y;
            if (outgoing) {
                for (port.outgoing.items) |edge| {
                    const other_port = edge.target.?;
                    const other_node = other_port.owner.?;
                    if (segment != p.segments[@intCast(other_node.id)]) {
                        const op = p.prio(other_node);
                        const other_prio = @max(op.input, op.output);
                        const pri = edge.p.priority_straightness;
                        if (pri >= min_prio and pri >= other_prio) {
                            node_deflection += other_node.pos.y + other_port.pos.y + other_port.anchor.y - portpos;
                            edge_weight_sum += 1;
                        }
                    }
                }
            }
            if (incoming) {
                for (port.incoming.items) |edge| {
                    const other_port = edge.source.?;
                    const other_node = other_port.owner.?;
                    if (segment != p.segments[@intCast(other_node.id)]) {
                        const op = p.prio(other_node);
                        const other_prio = @max(op.input, op.output);
                        const pri = edge.p.priority_straightness;
                        if (pri >= min_prio and pri >= other_prio) {
                            node_deflection += other_node.pos.y + other_port.pos.y + other_port.anchor.y - portpos;
                            edge_weight_sum += 1;
                        }
                    }
                }
            }
        }
        if (edge_weight_sum > 0) {
            segment_deflection += node_deflection / @as(f64, @floatFromInt(edge_weight_sum));
            node_weight_sum += 1;
        }
    }
    if (node_weight_sum > 0) {
        segment.deflection = deflection_dampening * segment_deflection / @as(f64, @floatFromInt(node_weight_sum));
        segment.weight = node_weight_sum;
    } else {
        segment.deflection = 0;
        segment.weight = 0;
    }
}

const overlap_detect = 0.0001;

fn mergeRegions(p: *Placer) bool {
    var changed = false;
    const threshold = overlap_detect * p.g.p.spacing.node_node;
    for (p.g.layers.items) |layer| {
        const nodes = layer.nodes.items;
        if (nodes.len == 0) continue;
        var node1 = nodes[0];
        var region1 = p.segments[@intCast(node1.id)].region();
        for (nodes[1..]) |node2| {
            const region2 = p.segments[@intCast(node2.id)].region();
            if (region1 != region2) {
                const spacing = spacings.getVerticalSpacing(node1, node2);
                const node1_extent = node1.pos.y + node1.size.y + node1.margin.bottom + region1.deflection + spacing;
                const node2_extent = node2.pos.y - node2.margin.top + region2.deflection;
                if (node1_extent > node2_extent + threshold) {
                    const w1: f64 = @floatFromInt(region1.weight);
                    const w2: f64 = @floatFromInt(region2.weight);
                    const weight_sum = region1.weight + region2.weight;
                    region2.deflection = (w2 * region2.deflection + w1 * region1.deflection) / @as(f64, @floatFromInt(weight_sum));
                    region2.weight = weight_sum;
                    region1.ref_segment = region2;
                    changed = true;
                }
            }
            node1 = node2;
            region1 = region2;
        }
    }
    return changed;
}

fn postProcess(p: *Placer) void {
    const int_max: f64 = @floatFromInt(std.math.maxInt(i32));
    for (p.segments) |segment| {
        var min_room_above = int_max;
        var min_room_below = int_max;
        for (segment.nodes.items) |node| {
            const layer_nodes = node.layer.?.nodes.items;
            const index = node.index();
            var room_above: f64 = undefined;
            if (index > 0) {
                const neighbor = layer_nodes[index - 1];
                const spacing = spacings.getVerticalSpacing(node, neighbor);
                room_above = node.pos.y - node.margin.top - (neighbor.pos.y + neighbor.size.y + neighbor.margin.bottom + spacing);
            } else {
                room_above = node.pos.y - node.margin.top;
            }
            min_room_above = util.javaMin(room_above, min_room_above);
            var room_below: f64 = undefined;
            if (index < layer_nodes.len - 1) {
                const neighbor = layer_nodes[index + 1];
                const spacing = spacings.getVerticalSpacing(node, neighbor);
                room_below = neighbor.pos.y - neighbor.margin.top - (node.pos.y + node.size.y + node.margin.bottom + spacing);
            } else {
                room_below = 2 * node.pos.y;
            }
            min_room_below = util.javaMin(room_below, min_room_below);
        }

        var min_displacement = int_max;
        var found_place = false;
        const first_node = segment.nodes.items[0];
        for (first_node.ports.items) |target| {
            const pos = first_node.pos.y + target.pos.y + target.anchor.y;
            for (target.incoming.items) |edge| {
                const source = edge.source.?;
                const d = source.owner.?.pos.y + source.pos.y + source.anchor.y - pos;
                if (@abs(d) < @abs(min_displacement) and @abs(d) < (if (d < 0) min_room_above else min_room_below)) {
                    min_displacement = d;
                    found_place = true;
                }
            }
        }
        const last_node = segment.nodes.items[segment.nodes.items.len - 1];
        for (last_node.ports.items) |source| {
            const pos = last_node.pos.y + source.pos.y + source.anchor.y;
            for (source.outgoing.items) |edge| {
                const target = edge.target.?;
                const d = target.owner.?.pos.y + target.pos.y + target.anchor.y - pos;
                if (@abs(d) < @abs(min_displacement) and @abs(d) < (if (d < 0) min_room_above else min_room_below)) {
                    min_displacement = d;
                    found_place = true;
                }
            }
        }
        if (found_place and min_displacement != 0) {
            for (segment.nodes.items) |node| node.pos.y += min_displacement;
        }
    }
}
