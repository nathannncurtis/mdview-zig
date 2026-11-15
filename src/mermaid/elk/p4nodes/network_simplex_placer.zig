// NetworkSimplexPlacer. With external ports the driver adds HIERARCHICAL_PORT_POSITION_PROCESSOR before phase 5.
const std = @import("std");
const lg = @import("../lgraph.zig");
const spacings = @import("../spacings.zig");
const ns_mod = @import("../network_simplex.zig");

const Allocator = std.mem.Allocator;
const NNode = ns_mod.NNode;
const NEdge = ns_mod.NEdge;
const NGraph = ns_mod.NGraph;
const Path = std.ArrayList(*lg.LEdge);

const edge_weight_base = 4.0;
const small_edge_weight = 0.1;
const long_edge_vs_path_factor = 2.0;
const node_size_weight_static = 10000.0;
const node_size_weight_flexible = 1.0;
const epsilon = 0.00001;

const visited: i32 = -1;
const other_state: i32 = 0;
const junction: i32 = 2;

const Origin = union(enum) { none, node: *lg.LNode, port: *lg.LPort };

const NodeRep = struct {
    origin: *lg.LNode,
    head: *NNode,
    tail: *NNode,
    is_flexible: bool,
};

const EdgeRep = struct {
    left: *NEdge,
    right: *NEdge,

    fn notStraightBy(self: EdgeRep) i32 {
        return (self.left.target.layer - self.left.delta) - (self.right.target.layer - self.right.delta);
    }
    fn isStraight(self: EdgeRep) bool {
        return self.notStraightBy() == 0;
    }
};

const Placer = struct {
    a: Allocator,
    g: *lg.LGraph,
    ngraph: NGraph,
    origins: std.ArrayList(Origin) = .empty,
    node_reps: []NodeRep = &.{},
    edge_reps: []?EdgeRep = &.{},
    port_map: std.AutoHashMapUnmanaged(*lg.LPort, *NNode) = .empty,
    node_count: usize = 0,
    edge_count: usize = 0,
    node_state: []i32 = &.{},
    two_paths: std.ArrayList(Path) = .empty,
    crossing: []bool = &.{},
    flexible_where_space_permits_edges: std.ArrayList(*NEdge) = .empty,

    fn newNode(self: *Placer, origin: Origin) Allocator.Error!*NNode {
        const n = try self.ngraph.createNode(null);
        n.id = @intCast(self.origins.items.len);
        try self.origins.append(self.a, origin);
        return n;
    }

    fn newEdge(self: *Placer, origin: ?*lg.LEdge, source: *NNode, target: *NNode, weight: f64, delta: i32) Allocator.Error!*NEdge {
        return self.ngraph.createEdge(origin, source, target, weight, delta);
    }

    fn originOf(self: *const Placer, n: *const NNode) Origin {
        return self.origins.items[@intCast(n.id)];
    }
};

fn ceilInt(x: f64) i32 {
    return @intFromFloat(@ceil(x));
}

fn javaRound(x: f64) f64 {
    return @floor(x + 0.5);
}

fn fuzzyEquals(a: f64, b: f64, tolerance: f64) bool {
    return a == b or @abs(a - b) <= tolerance;
}

fn ix(n: *const lg.LNode) usize {
    return @intCast(n.id);
}

pub fn process(g: *lg.LGraph) lg.Error!void {
    var p: Placer = .{ .a = g.a, .g = g, .ngraph = NGraph.init(g.a) };
    try prepare(&p);
    try buildInitialAuxiliaryGraph(&p);
    try insertNorthSouthAuxiliaryEdges(&p);
    try insertInLayerEdgeAuxiliaryEdges(&p);
    const favor_straight_edges = g.p.favor_straight_edges orelse (g.p.edge_routing == .orthogonal);
    if (favor_straight_edges) try preferStraightEdges(&p);

    _ = try p.ngraph.makeConnected();

    const iter_limit: i32 = g.p.thoroughness *% @as(i32, @intCast(p.ngraph.nodes.items.len));
    var ns = ns_mod.NetworkSimplex.forGraph(&p.ngraph);
    ns.iteration_limit = iter_limit;
    ns.balance_layers = false;
    try ns.execute();

    if (p.flexible_where_space_permits_edges.items.len != 0) {
        try insertFlexibleWhereSpaceAuxiliaryEdges(&p);
        for (p.flexible_where_space_permits_edges.items) |edge| edge.weight = node_size_weight_flexible;
        var ns2 = ns_mod.NetworkSimplex.forGraph(&p.ngraph);
        ns2.iteration_limit = iter_limit;
        ns2.balance_layers = false;
        try ns2.execute();
    }

    if (favor_straight_edges) try postProcessTwoPaths(&p);

    applyPositions(&p);
}

fn prepare(p: *Placer) Allocator.Error!void {
    var node_idx: i32 = 0;
    var edge_idx: i32 = 0;
    for (p.g.layers.items) |l| {
        for (l.nodes.items) |lnode| {
            lnode.id = node_idx;
            node_idx += 1;
            for (lnode.ports.items) |port| for (port.outgoing.items) |e| {
                e.id = edge_idx;
                edge_idx += 1;
            };
            const anchor_must_be_integer = isFlexibleNode(lnode);
            for (lnode.ports.items) |port| {
                if (anchor_must_be_integer) {
                    const y = port.anchor.y;
                    if (y != @floor(y)) {
                        const offset = y - javaRound(y);
                        port.anchor.y -= offset;
                    }
                }
                const y = port.pos.y + port.anchor.y;
                if (y != @floor(y)) {
                    const offset = y - javaRound(y);
                    port.pos.y -= offset;
                }
            }
        }
    }
    p.node_count = @intCast(node_idx);
    p.edge_count = @intCast(edge_idx);
    p.node_reps = try p.a.alloc(NodeRep, p.node_count);
    p.edge_reps = try p.a.alloc(?EdgeRep, p.edge_count);
    @memset(p.edge_reps, null);
}

fn buildInitialAuxiliaryGraph(p: *Placer) Allocator.Error!void {
    for (p.g.layers.items) |l| try transformLayer(p, l);
    try transformEdges(p);
}

fn transformLayer(p: *Placer, layer: *lg.Layer) Allocator.Error!void {
    var last_rep: ?NodeRep = null;
    for (layer.nodes.items) |lnode| {
        const node_rep = if (isFlexibleNode(lnode)) try transformFixedOrderNode(p, lnode) else try transformFixedPosNode(p, lnode);
        p.node_reps[ix(lnode)] = node_rep;
        if (last_rep) |lr| {
            var spacing = lr.origin.margin.bottom + spacings.getVerticalSpacing(lr.origin, lnode) + lnode.margin.top;
            if (!lr.is_flexible) spacing += lr.origin.size.y;
            _ = try p.newEdge(null, lr.tail, node_rep.head, 0, ceilInt(spacing));
        }
        last_rep = node_rep;
    }
}

fn transformFixedPosNode(p: *Placer, lnode: *lg.LNode) Allocator.Error!NodeRep {
    const single = try p.newNode(.{ .node = lnode });
    for (lnode.ports.items) |port| {
        if (port.side == .east or port.side == .west) try p.port_map.put(p.a, port, single);
    }
    return .{ .origin = lnode, .head = single, .tail = single, .is_flexible = false };
}

fn transformFixedOrderNode(p: *Placer, lnode: *lg.LNode) Allocator.Error!NodeRep {
    const top_left = try p.newNode(.{ .node = lnode });
    const bottom_left = try p.newNode(.{ .node = lnode });
    const corners: NodeRep = .{ .origin = lnode, .head = top_left, .tail = bottom_left, .is_flexible = true };

    const min_height = lnode.size.y;
    const nf = lnode.nodeFlexibility();
    var size_weight: f64 = node_size_weight_static;
    if (nf.isFlexibleSize()) size_weight = node_size_weight_flexible;
    const node_size_edge = try p.newEdge(null, top_left, bottom_left, size_weight, ceilInt(min_height));
    if (nf == .node_size_where_space_permits) try p.flexible_where_space_permits_edges.append(p.a, node_size_edge);

    try transformPorts(p, lnode.portSideView(.west), true, corners);
    try transformPorts(p, lnode.portSideView(.east), false, corners);
    return corners;
}

fn transformPorts(p: *Placer, ports: []*lg.LPort, reversed: bool, corners: NodeRep) Allocator.Error!void {
    if (ports.len == 0) return;
    const sp = &corners.origin.graph.?.p.spacing;
    const port_spacing = sp.port_port;
    const port_surrounding = sp.ports_surrounding;

    var last_nnode = corners.head;
    var last_port: ?*lg.LPort = null;
    for (0..ports.len) |i| {
        const port = if (reversed) ports[ports.len - 1 - i] else ports[i];
        var spacing: f64 = 0;
        if (last_port) |lp| {
            spacing = port_spacing;
            spacing += lp.size.y;
        } else {
            spacing = port_surrounding.top;
        }
        const nnode = try p.newNode(.{ .port = port });
        try p.port_map.put(p.a, port, nnode);
        _ = try p.newEdge(null, last_nnode, nnode, 0, ceilInt(spacing));
        last_port = port;
        last_nnode = nnode;
    }
    _ = try p.newEdge(null, last_nnode, corners.tail, 0, ceilInt(port_surrounding.bottom + last_port.?.size.y));
}

fn transformEdges(p: *Placer) Allocator.Error!void {
    for (p.g.layers.items) |layer| for (layer.nodes.items) |node| {
        for (node.ports.items) |port| for (port.outgoing.items) |e| {
            if (isHandledEdge(e)) try transformEdge(p, e);
        };
    };
}

fn transformEdge(p: *Placer, ledge: *lg.LEdge) Allocator.Error!void {
    const dummy = try p.newNode(.none);
    const src_rep = p.node_reps[ix(ledge.source.?.owner.?)];
    const tgt_rep = p.node_reps[ix(ledge.target.?.owner.?)];
    const src_port = ledge.source.?;
    const tgt_port = ledge.target.?;
    var src_offset = src_port.anchor.y;
    var tgt_offset = tgt_port.anchor.y;
    if (!src_rep.is_flexible) src_offset += src_port.pos.y;
    if (!tgt_rep.is_flexible) tgt_offset += tgt_port.pos.y;
    const tgt_delta: i32 = @intFromFloat(@max(0, src_offset - tgt_offset));
    const src_delta: i32 = @intFromFloat(@max(0, tgt_offset - src_offset));
    const weight = edgeWeight(ledge);
    const left = try p.newEdge(ledge, dummy, p.port_map.get(src_port).?, weight, src_delta);
    const right = try p.newEdge(ledge, dummy, p.port_map.get(tgt_port).?, weight, tgt_delta);
    p.edge_reps[@intCast(ledge.id)] = .{ .left = left, .right = right };
}

fn insertInLayerEdgeAuxiliaryEdges(p: *Placer) Allocator.Error!void {
    for (p.g.layers.items) |l| for (l.nodes.items) |n| {
        if (n.type != .normal) continue;
        for (n.ports.items) |port| {
            for (port.incoming.items) |e| try insertInLayerEdge(p, e);
            for (port.outgoing.items) |e| try insertInLayerEdge(p, e);
        }
    };
}

fn insertInLayerEdge(p: *Placer, in_layer_edge: *lg.LEdge) Allocator.Error!void {
    if (!in_layer_edge.isInLayerEdge()) return;
    const src_is_dummy = in_layer_edge.source.?.owner.?.type != .normal;
    const the_port = if (src_is_dummy) in_layer_edge.target.? else in_layer_edge.source.?;
    const dummy_node = in_layer_edge.otherPort(the_port).owner.?;
    const port_rep = p.port_map.get(the_port).?;
    const dummy_rep = p.node_reps[ix(dummy_node)].head;
    var src: *NNode = undefined;
    var tgt: *NNode = undefined;
    if (the_port.owner.?.index() < dummy_node.index()) {
        src = port_rep;
        tgt = dummy_rep;
    } else {
        src = dummy_rep;
        tgt = port_rep;
    }
    _ = try p.newEdge(null, src, tgt, edge_weight_base, 0);
}

fn insertNorthSouthAuxiliaryEdges(p: *Placer) Allocator.Error!void {
    for (p.g.layers.items) |l| for (l.nodes.items) |n| {
        for (n.portSideView(.south)) |sp| {
            if (sp.p.port_dummy) |other| {
                _ = try p.newEdge(null, p.node_reps[ix(n)].tail, p.node_reps[ix(other)].head, small_edge_weight, 0);
            }
        }
        for (n.portSideView(.north)) |sp| {
            if (sp.p.port_dummy) |other| {
                _ = try p.newEdge(null, p.node_reps[ix(other)].tail, p.node_reps[ix(n)].head, small_edge_weight, 0);
            }
        }
    };
}

fn insertFlexibleWhereSpaceAuxiliaryEdges(p: *Placer) Allocator.Error!void {
    var min_layer: i32 = std.math.maxInt(i32);
    var max_layer: i32 = std.math.minInt(i32);
    for (p.ngraph.nodes.items) |n| {
        min_layer = @min(min_layer, n.layer);
        max_layer = @max(max_layer, n.layer);
    }
    const used_layers = max_layer - min_layer;
    const global_source = try p.newNode(.none);
    const global_sink = try p.newNode(.none);
    _ = try p.newEdge(null, global_source, global_sink, node_size_weight_static * 2, used_layers);
    for (p.node_reps) |nr| {
        if (nr.origin.type != .normal) continue;
        if (nr.origin.ports.items.len <= 1) continue;
        _ = try p.newEdge(null, global_source, nr.tail, 0, nr.tail.layer - min_layer);
        _ = try p.newEdge(null, nr.head, global_sink, 0, used_layers - nr.head.layer);
    }
}

fn applyPositions(p: *Placer) void {
    for (p.g.layers.items) |l| for (l.nodes.items) |lnode| {
        const node_rep = p.node_reps[ix(lnode)];
        const min_y: f64 = @floatFromInt(node_rep.head.layer);
        const max_y: f64 = @floatFromInt(node_rep.tail.layer);
        lnode.pos.y = min_y;
        const size_delta = (max_y - min_y) - lnode.size.y;
        const flexible_node = isFlexibleNode(lnode);
        const nf = lnode.nodeFlexibility();
        if (flexible_node and nf.isFlexibleSizeWhereSpacePermits()) lnode.size.y += size_delta;
        if (flexible_node and nf.isFlexiblePorts()) {
            for (lnode.ports.items) |port| {
                if (port.side == .east or port.side == .west) {
                    const nnode = p.port_map.get(port).?;
                    port.pos.y = @as(f64, @floatFromInt(nnode.layer)) - min_y;
                }
            }
            for (lnode.labels.items) |label| adjustLabelPosition(lnode, label, size_delta);
            if (nf.isFlexibleSizeWhereSpacePermits()) {
                for (lnode.portSideView(.south)) |port| port.pos.y += size_delta;
            }
        }
    };
}

fn adjustLabelPosition(node: *lg.LNode, label: *lg.LLabel, size_delta: f64) void {
    const placement = node.p.node_labels_placement;
    if (placement.v_bottom) {
        label.pos.y += size_delta;
    } else if (placement.v_center) {
        label.pos.y += size_delta / 2.0;
    }
}

fn edgeWeight(edge: *const lg.LEdge) f64 {
    const priority: i32 = @max(1, edge.p.priority_straightness);
    const type_weight = edgeTypeWeight(edge.source.?.owner.?.type, edge.target.?.owner.?.type);
    return @as(f64, @floatFromInt(priority)) * type_weight;
}

fn edgeTypeWeight(t1: lg.NodeType, t2: lg.NodeType) f64 {
    if (t1 == .normal and t2 == .normal) return 1 * edge_weight_base;
    if (t1 == .normal or t2 == .normal) return 2 * edge_weight_base;
    return 8 * edge_weight_base;
}

fn isHandledEdge(edge: *const lg.LEdge) bool {
    return !edge.isSelfLoop() and !edge.isInLayerEdge();
}

fn isFlexibleNode(lnode: *const lg.LNode) bool {
    if (lnode.type != .normal) return false;
    if (lnode.ports.items.len <= 1) return false;
    if (lnode.p.port_constraints.isPosFixed()) return false;
    const nf = lnode.nodeFlexibility();
    if (nf == .none) return false;
    if (!nf.isFlexibleSizeWhereSpacePermits()) {
        const port_spacing = lnode.graph.?.p.spacing.port_port;
        const additional = lnode.p.spacing.ports_surrounding;
        var west: f64 = 0;
        var east: f64 = 0;
        for (lnode.ports.items) |port| {
            if (port.side == .west) west += 1;
            if (port.side == .east) east += 1;
        }
        const required_west_height = additional.top + additional.bottom + (west - 1) * port_spacing;
        if (required_west_height > lnode.size.y) return false;
        const required_east_height = additional.top + additional.bottom + (east - 1) * port_spacing;
        if (required_east_height > lnode.size.y) return false;
    }
    return true;
}

fn pathContainsLongEdgeDummy(path: Path) bool {
    if (path.items.len == 0) return false;
    if (path.items[0].source.?.owner.?.type == .long_edge) return true;
    for (path.items) |e| if (e.target.?.owner.?.type == .long_edge) return true;
    return false;
}

fn pathContainsFlexibleSizeWhereSpacePermits(path: Path) bool {
    if (path.items.len == 0) return false;
    if (path.items[0].source.?.owner.?.nodeFlexibility().isFlexibleSizeWhereSpacePermits()) return true;
    for (path.items) |e| if (e.target.?.owner.?.nodeFlexibility().isFlexibleSizeWhereSpacePermits()) return true;
    return false;
}

fn orderTwoPath(path: *Path) void {
    const first = path.items[0];
    const second = path.items[1];
    if (first.target.?.owner.? != second.source.?.owner.?) {
        path.items[0] = second;
        path.items[1] = first;
    }
}

fn preferStraightEdges(p: *Placer) Allocator.Error!void {
    const a = p.a;
    p.node_state = try a.alloc(i32, p.node_count);
    for (p.g.layers.items) |l| for (l.nodes.items) |n| {
        p.node_state[ix(n)] = nodeState(n);
    };
    try markEdgeCrossings(p);
    const identified = try identifyPaths(p);
    for (identified) |*path| {
        if (path.items.len <= 1) continue;
        if (path.items.len == 2) {
            orderTwoPath(path);
            if (!isFlexibleNode(path.items[0].target.?.owner.?)) try p.two_paths.append(a, path.*);
            continue;
        }
        if (pathContainsLongEdgeDummy(path.*) or pathContainsFlexibleSizeWhereSpacePermits(path.*)) continue;

        var last: ?*lg.LEdge = null;
        for (path.items, 0..) |cur, i| {
            const cur_rep = p.edge_reps[@intCast(cur.id)].?;
            var weight: f64 = undefined;
            if (last == null or i + 1 == path.items.len) {
                weight = edgeTypeWeight(.normal, .long_edge);
            } else {
                weight = edgeTypeWeight(.long_edge, .long_edge);
            }
            weight *= long_edge_vs_path_factor;
            const old_left = cur_rep.left.weight;
            cur_rep.left.weight = @max(old_left, old_left + (weight - old_left));
            const old_right = cur_rep.right.weight;
            cur_rep.right.weight = @max(old_right, old_right + (weight - old_right));
            last = cur;
        }
    }
}

fn nodeState(node: *const lg.LNode) i32 {
    var inco: usize = 0;
    var ouco: usize = 0;
    for (node.ports.items) |port| {
        for (port.incoming.items) |e| if (!e.isSelfLoop()) {
            inco += 1;
        };
        for (port.outgoing.items) |e| if (!e.isSelfLoop()) {
            ouco += 1;
        };
        if (inco > 1 or ouco > 1) return junction;
    }
    if (inco + ouco == 1) return junction;
    return other_state;
}

fn identifyPaths(p: *Placer) Allocator.Error![]Path {
    var paths: std.ArrayList(Path) = .empty;
    for (p.g.layers.items) |l| for (l.nodes.items) |n| {
        if (p.node_state[ix(n)] != junction) continue;
        for (n.ports.items) |port| {
            for (port.incoming.items) |e| try identifyFrom(p, &paths, e, n);
            for (port.outgoing.items) |e| try identifyFrom(p, &paths, e, n);
        }
    };
    return paths.items;
}

fn identifyFrom(p: *Placer, paths: *std.ArrayList(Path), e: *lg.LEdge, junction_node: *lg.LNode) Allocator.Error!void {
    if (!isHandledEdge(e)) return;
    var path: Path = .empty;
    try follow(p, e, junction_node, &path);
    if (path.items.len > 1) try paths.append(p.a, path);
}

fn follow(p: *Placer, start_edge: *lg.LEdge, start: *lg.LNode, path: *Path) Allocator.Error!void {
    var edge = start_edge;
    var current = start;
    while (true) {
        const other = edge.otherNode(current);
        try path.append(p.a, edge);
        const st = p.node_state[ix(other)];
        if (st == visited or st == junction or p.crossing[@intCast(edge.id)]) return;
        p.node_state[ix(other)] = visited;
        var next: ?*lg.LEdge = null;
        scan: for (other.ports.items) |port| {
            for (port.incoming.items) |incident| {
                if (!isHandledEdge(incident) or incident == edge) continue;
                next = incident;
                break :scan;
            }
            for (port.outgoing.items) |incident| {
                if (!isHandledEdge(incident) or incident == edge) continue;
                next = incident;
                break :scan;
            }
        }
        const n = next orelse return;
        current = other;
        edge = n;
    }
}

fn markEdgeCrossings(p: *Placer) Allocator.Error!void {
    p.crossing = try p.a.alloc(bool, p.edge_count);
    @memset(p.crossing, false);
    const layers = p.g.layers.items;
    if (layers.len < 2) return;
    for (0..layers.len - 1) |i| try markCrossingEdges(p, layers[i], layers[i + 1]);
}

fn markCrossingEdges(p: *Placer, left: *lg.Layer, right: *lg.Layer) Allocator.Error!void {
    var open_edges: std.ArrayList(*lg.LEdge) = .empty;
    for (left.nodes.items) |node| {
        for (node.portSideView(.east)) |port| {
            for (port.outgoing.items) |edge| {
                if (edge.isInLayerEdge() or edge.isSelfLoop() or edge.target.?.owner.?.layer != right) continue;
                try open_edges.append(p.a, edge);
            }
        }
    }

    var ni = right.nodes.items.len;
    while (ni > 0) {
        ni -= 1;
        const node = right.nodes.items[ni];
        for (node.portSideView(.west)) |port| {
            for (port.incoming.items) |edge| {
                if (edge.isInLayerEdge() or edge.isSelfLoop() or edge.source.?.owner.?.layer != left) continue;
                if (open_edges.items.len == 0) continue;
                // ListIterator cursor: previous() returns items[cursor - 1]
                var cursor = open_edges.items.len;
                cursor -= 1;
                var last_ret = cursor;
                var last = open_edges.items[last_ret];
                while (last != edge and cursor > 0) {
                    p.crossing[@intCast(last.id)] = true;
                    p.crossing[@intCast(edge.id)] = true;
                    cursor -= 1;
                    last_ret = cursor;
                    last = open_edges.items[last_ret];
                }
                if (cursor > 0) _ = open_edges.orderedRemove(last_ret);
            }
        }
    }
}

fn postProcessTwoPaths(p: *Placer) Allocator.Error!void {
    var stack: std.ArrayList(Path) = .empty;
    for (p.two_paths.items) |path| {
        if (improveTwoPath(p, path, true)) try stack.append(p.a, path);
    }
    while (stack.pop()) |path| _ = improveTwoPath(p, path, false);
}

fn length(edge: *const NEdge) i32 {
    const dist: i32 = @intCast(@abs(edge.source.layer - edge.target.layer));
    return dist - edge.delta;
}

fn improveTwoPath(p: *Placer, path: Path, probe: bool) bool {
    const left_edge = p.edge_reps[@intCast(path.items[0].id)].?;
    const right_edge = p.edge_reps[@intCast(path.items[1].id)].?;
    if (left_edge.isStraight() and right_edge.isStraight()) return false;

    const center_node = switch (p.originOf(left_edge.right.target)) {
        .node => |n| n,
        else => return false,
    };
    const n_node = p.node_reps[ix(center_node)];

    const node_index = center_node.index();
    const layer_nodes = center_node.layer.?.nodes.items;
    var above_dist = std.math.inf(f64);
    if (node_index > 0) {
        const above = layer_nodes[node_index - 1];
        const above_rep = p.node_reps[ix(above)];
        const spacing = @ceil(spacings.getVerticalSpacing(above, center_node));
        above_dist = (@as(f64, @floatFromInt(n_node.head.layer)) - center_node.margin.top) -
            (@as(f64, @floatFromInt(above_rep.head.layer)) + above.size.y + above.margin.bottom) - spacing;
    }
    var below_dist = std.math.inf(f64);
    if (node_index < layer_nodes.len - 1) {
        const below = layer_nodes[node_index + 1];
        const below_rep = p.node_reps[ix(below)];
        const spacing = @ceil(spacings.getVerticalSpacing(below, center_node));
        below_dist = (@as(f64, @floatFromInt(below_rep.head.layer)) - below.margin.top) -
            (@as(f64, @floatFromInt(n_node.head.layer)) + center_node.size.y + center_node.margin.bottom) - spacing;
    }

    if (probe and fuzzyEquals(above_dist, below_dist, epsilon)) return true;

    const a: i32 = length(left_edge.left);
    const b: i32 = -length(left_edge.right);
    const c: i32 = -length(right_edge.left);
    const d: i32 = length(right_edge.right);

    const case_d = left_edge.notStraightBy() > 0 and right_edge.notStraightBy() < 0;
    const case_c = left_edge.notStraightBy() < 0 and right_edge.notStraightBy() > 0;
    const case_b = left_edge.left.target.layer + left_edge.right.delta < right_edge.right.target.layer + right_edge.left.delta;
    const case_a = left_edge.left.target.layer + left_edge.right.delta > right_edge.right.target.layer + right_edge.left.delta;

    var move: i32 = 0;
    if (!case_d and !case_c) {
        if (case_a) {
            if (above_dist + @as(f64, @floatFromInt(c)) > 0) {
                move = c;
            } else if (below_dist - @as(f64, @floatFromInt(a)) > 0) {
                move = a;
            }
        } else if (case_b) {
            if (above_dist + @as(f64, @floatFromInt(b)) > 0) {
                move = b;
            } else if (below_dist - @as(f64, @floatFromInt(d)) > 0) {
                move = d;
            }
        }
    }

    n_node.head.layer += move;
    if (n_node.is_flexible) n_node.tail.layer += move;
    return false;
}
