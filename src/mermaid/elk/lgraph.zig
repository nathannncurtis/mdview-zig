const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{Unsupported};

pub const Vec = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn add(self: *Vec, o: Vec) void {
        self.x += o.x;
        self.y += o.y;
    }
    pub fn sub(self: *Vec, o: Vec) void {
        self.x -= o.x;
        self.y -= o.y;
    }
    pub fn scale(self: *Vec, s: f64) void {
        self.x *= s;
        self.y *= s;
    }
    pub fn dist(a: Vec, b: Vec) f64 {
        return std.math.hypot(a.x - b.x, a.y - b.y);
    }
};

pub const Margin = struct {
    top: f64 = 0,
    left: f64 = 0,
    bottom: f64 = 0,
    right: f64 = 0,
};

pub const Direction = enum {
    undefined,
    right,
    left,
    down,
    up,

    pub fn isHorizontal(d: Direction) bool {
        return d == .left or d == .right or d == .undefined;
    }
    pub fn isVertical(d: Direction) bool {
        return d == .up or d == .down;
    }
};

pub const PortSide = enum {
    undefined,
    north,
    east,
    south,
    west,

    pub fn right(s: PortSide) PortSide {
        return switch (s) {
            .north => .east,
            .east => .south,
            .south => .west,
            .west => .north,
            .undefined => .undefined,
        };
    }
    pub fn left(s: PortSide) PortSide {
        return switch (s) {
            .north => .west,
            .east => .north,
            .south => .east,
            .west => .south,
            .undefined => .undefined,
        };
    }
    pub fn opposed(s: PortSide) PortSide {
        return switch (s) {
            .north => .south,
            .east => .west,
            .south => .north,
            .west => .east,
            .undefined => .undefined,
        };
    }
    pub fn areAdjacent(s: PortSide, o: PortSide) bool {
        if (s == .undefined) return false;
        return s.left() == o or s.right() == o;
    }
    pub fn fromDirection(d: Direction) PortSide {
        return switch (d) {
            .up => .north,
            .right => .east,
            .down => .south,
            .left => .west,
            .undefined => .undefined,
        };
    }
    pub fn isVertical(s: PortSide) bool {
        return s == .north or s == .south;
    }
    pub fn isHorizontal(s: PortSide) bool {
        return s == .west or s == .east;
    }
};

pub const PortType = enum { undefined, input, output };

pub const PortConstraints = enum {
    undefined,
    free,
    fixed_side,
    fixed_order,
    fixed_ratio,
    fixed_pos,

    pub fn isPosFixed(p: PortConstraints) bool {
        return p == .fixed_pos or p == .fixed_ratio;
    }
    pub fn isRatioFixed(p: PortConstraints) bool {
        return p == .fixed_ratio;
    }
    pub fn isOrderFixed(p: PortConstraints) bool {
        return p == .fixed_order or p == .fixed_ratio or p == .fixed_pos;
    }
    pub fn isSideFixed(p: PortConstraints) bool {
        return p != .undefined and p != .free;
    }
};

pub const EdgeRouting = enum { undefined, polyline, orthogonal, splines };
pub const HierarchyHandling = enum { inherit, separate_children, include_children };
pub const CycleBreaking = enum { greedy, depth_first, interactive, model_order, greedy_model_order };
pub const Layering = enum { network_simplex, longest_path, longest_path_source, coffman_graham, interactive, stretch_width, min_width, bf_model_order, df_model_order };
pub const NodePlacement = enum { simple, interactive, linear_segments, brandes_koepf, network_simplex };
pub const FixedAlignment = enum { none, leftdown, rightdown, leftup, rightup, balanced };
pub const OrderingStrategy = enum { none, nodes_and_edges, prefer_edges };
pub const LongEdgeOrderingStrategy = enum { dummy_node_over, dummy_node_under, equal };
pub const GreedySwitchType = enum { off, one_sided, two_sided };
pub const EdgeLabelPlacement = enum { center, head, tail };
pub const LabelSide = enum { unknown, above, below, inline_ };
pub const ContentAlignment = packed struct { h_left: bool = false, h_center: bool = false, h_right: bool = false, v_top: bool = false, v_center: bool = false, v_bottom: bool = false };
pub const SelfLoopDistribution = enum { equally, north, north_south };
pub const SelfLoopOrdering = enum { stacked, sequenced };
pub const PortAlignment = enum { distributed, justified, begin, center, end };
pub const EdgeConstraint = enum { none, incoming_only, outgoing_only };
pub const InLayerConstraint = enum { none, top, bottom };
pub const LayerConstraint = enum { none, first, first_separate, last, last_separate };
pub const HiddenNodeConnections = enum { none, first_separate, last_separate, both };
pub const Alignment = enum { automatic, left, right, top, bottom, center };
pub const EdgeLabelSideSelection = enum { always_up, always_down, direction_up, direction_down, smart_up, smart_down };

pub const NodeType = enum { normal, long_edge, external_port, north_south_port, label, breaking_point };

pub const GraphProperties = packed struct {
    comments: bool = false,
    external_ports: bool = false,
    hyperedges: bool = false,
    hypernodes: bool = false,
    non_free_ports: bool = false,
    north_south_ports: bool = false,
    self_loops: bool = false,
    center_labels: bool = false,
    end_labels: bool = false,
    partitions: bool = false,
};

pub const SizeConstraint = packed struct { ports: bool = false, port_labels: bool = false, node_labels: bool = false, minimum_size: bool = false };
pub const SizeOptions = packed struct { default_minimum_size: bool = false, minimum_size_accounts_for_padding: bool = false, compute_padding: bool = false, outside_node_labels_overhang: bool = false, ports_overhang: bool = false, uniform_port_spacing: bool = false, space_efficient_port_labels: bool = false, force_tabular_node_labels: bool = false, asymmetrical: bool = false };
pub const NodeLabelPlacement = packed struct { h_left: bool = false, h_center: bool = false, h_right: bool = false, v_top: bool = false, v_center: bool = false, v_bottom: bool = false, inside: bool = false, outside: bool = false, h_priority: bool = false };
pub const PortSides = packed struct { north: bool = false, east: bool = false, south: bool = false, west: bool = false };

pub const Spacings = struct {
    edge_edge: f64 = 10,
    edge_node: f64 = 10,
    node_node: f64 = 20,
    edge_edge_between_layers: f64 = 10,
    edge_node_between_layers: f64 = 10,
    node_node_between_layers: f64 = 20,
    port_port: f64 = 10,
    component_component: f64 = 20,
    node_self_loop: f64 = 10,
    label_label: f64 = 0,
    label_port_horizontal: f64 = 1,
    label_port_vertical: f64 = 1,
    label_node: f64 = 5,
    edge_label: f64 = 2,
    ports_surrounding: Margin = .{},
    comment_comment: f64 = 10,
    comment_node: f64 = 10,
};

// One flat bag for ELK options and the layered InternalProperties, with ELK's defaults. A processor that
// needs one more field adds it here and keeps the Java name in snake case.
pub const Props = struct {
    // options (LayeredOptions / CoreOptions)
    port_constraints: PortConstraints = .undefined,
    port_side: PortSide = .undefined,
    port_index: i32 = 0,
    port_border_offset: f64 = 0,
    port_anchor: ?Vec = null,
    direction: Direction = .undefined,
    edge_routing: EdgeRouting = .orthogonal,
    hierarchy_handling: HierarchyHandling = .inherit,
    no_layout: bool = false,
    spacing: Spacings = .{},
    padding: Margin = .{ .top = 12, .left = 12, .bottom = 12, .right = 12 },
    node_size_constraints: SizeConstraint = .{},
    node_size_options: SizeOptions = .{ .default_minimum_size = true },
    node_size_minimum: Vec = .{ .x = 0, .y = 0 },
    node_size_fixed_graph_size: bool = false,
    node_labels_placement: NodeLabelPlacement = .{},
    node_labels_padding: Margin = .{ .top = 5, .left = 5, .bottom = 5, .right = 5 },
    content_alignment: ContentAlignment = .{ .h_left = true, .v_top = true },
    port_alignment_default: PortAlignment = .distributed,
    edge_labels_placement: EdgeLabelPlacement = .center,
    edge_labels_inline: bool = false,
    edge_labels_side_selection: EdgeLabelSideSelection = .smart_down,
    edge_thickness: f64 = 1,
    inside_self_loops_activate: bool = false,
    inside_self_loops_yo: bool = false,
    cycle_breaking: CycleBreaking = .greedy,
    layering: Layering = .network_simplex,
    node_placement: NodePlacement = .brandes_koepf,
    bk_fixed_alignment: FixedAlignment = .none,
    bk_edge_straightening: bool = true,
    favor_straight_edges: ?bool = null,
    consider_model_order: OrderingStrategy = .none,
    force_node_model_order: bool = false,
    consider_model_order_port_model_order: bool = false,
    consider_model_order_long_edge_strategy: LongEdgeOrderingStrategy = .dummy_node_over,
    merge_edges: bool = false,
    merge_hierarchy_edges: bool = true,
    unnecessary_bendpoints: bool = false,
    self_loop_distribution: SelfLoopDistribution = .north,
    self_loop_ordering: SelfLoopOrdering = .stacked,
    thoroughness: i32 = 7,
    random_seed: i32 = 1,
    alignment: Alignment = .automatic,
    separate_connected_components: bool = true,
    aspect_ratio: f64 = 1.600000023841858,
    feedback_edges: bool = false,
    allow_non_flow_ports_to_switch_sides: bool = false,
    layer_constraint: LayerConstraint = .none,
    position_choice_constraint: i32 = -1,
    position_id: i32 = -1,
    layer_id: i32 = -1,
    layer_choice_constraint: i32 = -1,
    priority_straightness: i32 = 1,
    priority_direction: i32 = 0,
    priority_shortness: i32 = 0,
    hierarchical_sweepiness: f64 = 0.1,
    greedy_switch_hierarchical: GreedySwitchType = .off,
    greedy_switch: GreedySwitchType = .two_sided,
    greedy_switch_activation_threshold: i32 = 40,

    // internal properties (InternalProperties)
    compound_node: bool = false,
    inside_connections: bool = false,
    reversed: bool = false,
    cyclic: bool = false,
    max_edge_thickness: f64 = 0,
    label_side: LabelSide = .unknown,
    long_edge_source: ?*LPort = null,
    long_edge_target: ?*LPort = null,
    long_edge_target_node: ?*LNode = null,
    target_node_model_order: ?*std.AutoHashMapUnmanaged(*LNode, i32) = null,
    long_edge_has_label_dummies: bool = false,
    long_edge_before_label_dummy: bool = false,
    edge_constraint: EdgeConstraint = .none,
    in_layer_layout_unit: ?*LNode = null,
    in_layer_constraint: InLayerConstraint = .none,
    in_layer_successor_constraints: std.ArrayList(*LNode) = .empty,
    in_layer_successor_constraints_between_non_dummies: bool = false,
    port_dummy: ?*LNode = null,
    crossing_hint: i32 = 0,
    graph_properties: GraphProperties = .{},
    ext_port_side: PortSide = .undefined,
    ext_port_size: Vec = .{},
    ext_port_replaced_dummies: std.ArrayList(*LNode) = .empty,
    ext_port_replaced_dummy: ?*LNode = null,
    ext_port_connections: PortSides = .{},
    port_ratio_or_position: f64 = 0,
    barycenter_associates: std.ArrayList(*LNode) = .empty,
    input_collect: bool = false,
    output_collect: bool = false,
    target_offset: ?Vec = null,
    original_port_constraints: PortConstraints = .undefined,
    model_order: ?i32 = null,
    first_try_with_initial_order: bool = false,
    second_try_with_initial_order: bool = false,
    original_label_edge: ?*LEdge = null,
    end_label_edge: ?*LEdge = null,
    original_dummy_node_position: ?f64 = null,
    origin: Origin = .none,
    coordinate_system_origin: ?*LGraph = null,
    hidden_nodes: std.ArrayList(*LNode) = .empty,
    original_opposite_port: ?*LPort = null,
    represented_labels: std.ArrayList(*LLabel) = .empty,
    junction_points: std.ArrayList(Vec) = .empty,
    // InternalProperties.RANDOM: one java.util.Random per LGraph, seeded by GraphConfigurator
    random: ?*JavaRandom = null,
    separate_layer_connections: HiddenNodeConnections = .none,
    self_loop_holder: ?*anyopaque = null,
    // opaque slots for state a single processor family owns (self loops, label cells, ...)
    debug_id: []const u8 = "",
    slot_a: ?*anyopaque = null,
    slot_b: ?*anyopaque = null,
};

// InternalProperties.ORIGIN: the element of the source graph (or the LGraph element) this one was made from
pub const Origin = union(enum) {
    none,
    node: *LNode,
    port: *LPort,
    edge: *LEdge,
    label: *LLabel,
    graph: *LGraph,
    // index into the importer's table of source elements
    src: u32,
};

pub const LLabel = struct {
    a: Allocator,
    id: i32 = 0,
    pos: Vec = .{},
    size: Vec = .{},
    text: []const u8 = "",
    p: Props = .{},

    pub fn init(a: Allocator) Allocator.Error!*LLabel {
        const x = try a.create(LLabel);
        x.* = .{ .a = a };
        return x;
    }
};

pub const LPort = struct {
    a: Allocator,
    id: i32 = 0,
    pos: Vec = .{},
    size: Vec = .{},
    owner: ?*LNode = null,
    side: PortSide = .undefined,
    anchor: Vec = .{},
    explicitly_supplied_port_anchor: bool = false,
    margin: Margin = .{},
    labels: std.ArrayList(*LLabel) = .empty,
    incoming: std.ArrayList(*LEdge) = .empty,
    outgoing: std.ArrayList(*LEdge) = .empty,
    connected_to_external_nodes: bool = true,
    p: Props = .{},

    pub fn init(a: Allocator) Allocator.Error!*LPort {
        const x = try a.create(LPort);
        x.* = .{ .a = a };
        return x;
    }

    pub fn setNode(self: *LPort, node: ?*LNode) Allocator.Error!void {
        if (self.owner) |o| removeItem(LPort, &o.ports, self);
        self.owner = node;
        if (node) |o| try o.ports.append(self.a, self);
    }

    // LPort.setSide also invalidates the node's cached side indices
    pub fn setSide(self: *LPort, s: PortSide) void {
        self.side = s;
        if (self.owner) |o| o.port_sides_cached = false;
    }

    pub fn degree(self: *const LPort) usize {
        return self.incoming.items.len + self.outgoing.items.len;
    }
    pub fn netFlow(self: *const LPort) i64 {
        return @as(i64, @intCast(self.incoming.items.len)) - @as(i64, @intCast(self.outgoing.items.len));
    }
    pub fn absoluteAnchor(self: *const LPort) Vec {
        const n = self.owner.?;
        return .{ .x = n.pos.x + self.pos.x + self.anchor.x, .y = n.pos.y + self.pos.y + self.anchor.y };
    }
    pub fn index(self: *const LPort) ?usize {
        const o = self.owner orelse return null;
        for (o.ports.items, 0..) |q, i| if (q == self) return i;
        return null;
    }
};

pub const LEdge = struct {
    a: Allocator,
    id: i32 = 0,
    bend_points: std.ArrayList(Vec) = .empty,
    source: ?*LPort = null,
    target: ?*LPort = null,
    labels: std.ArrayList(*LLabel) = .empty,
    p: Props = .{},

    pub fn init(a: Allocator) Allocator.Error!*LEdge {
        const x = try a.create(LEdge);
        x.* = .{ .a = a };
        return x;
    }

    pub fn setSource(self: *LEdge, s: ?*LPort) Allocator.Error!void {
        if (self.source) |o| removeItem(LEdge, &o.outgoing, self);
        self.source = s;
        if (s) |o| try o.outgoing.append(self.a, self);
    }
    pub fn setTarget(self: *LEdge, t: ?*LPort) Allocator.Error!void {
        if (self.target) |o| removeItem(LEdge, &o.incoming, self);
        self.target = t;
        if (t) |o| try o.incoming.append(self.a, self);
    }
    pub fn setTargetAndInsertAtIndex(self: *LEdge, t: *LPort, idx: usize) Allocator.Error!void {
        if (self.target) |o| removeItem(LEdge, &o.incoming, self);
        self.target = t;
        try t.incoming.insert(self.a, idx, self);
    }
    pub fn isSelfLoop(self: *const LEdge) bool {
        return self.source.?.owner.? == self.target.?.owner.?;
    }
    pub fn isInLayerEdge(self: *const LEdge) bool {
        const sl = self.source.?.owner.?.layer;
        return !self.isSelfLoop() and sl != null and sl == self.target.?.owner.?.layer;
    }
    pub fn otherPort(self: *const LEdge, port: *const LPort) *LPort {
        return if (self.source.? == port) self.target.? else self.source.?;
    }
    pub fn otherNode(self: *const LEdge, node: *const LNode) *LNode {
        return if (self.source.?.owner.? == node) self.target.?.owner.? else self.source.?.owner.?;
    }
};

pub const Layer = struct {
    a: Allocator,
    id: i32 = 0,
    owner: *LGraph,
    size: Vec = .{},
    nodes: std.ArrayList(*LNode) = .empty,
    p: Props = .{},

    pub fn index(self: *const Layer) usize {
        for (self.owner.layers.items, 0..) |l, i| if (l == self) return i;
        unreachable;
    }
};

pub const LNode = struct {
    a: Allocator,
    id: i32 = 0,
    pos: Vec = .{},
    size: Vec = .{},
    graph: ?*LGraph = null,
    layer: ?*Layer = null,
    type: NodeType = .normal,
    ports: std.ArrayList(*LPort) = .empty,
    labels: std.ArrayList(*LLabel) = .empty,
    nested_graph: ?*LGraph = null,
    margin: Margin = .{},
    padding: Margin = .{},
    port_sides_cached: bool = false,
    p: Props = .{},

    pub fn init(a: Allocator, graph: ?*LGraph) Allocator.Error!*LNode {
        const x = try a.create(LNode);
        x.* = .{ .a = a, .graph = graph };
        return x;
    }

    pub fn setLayer(self: *LNode, l: ?*Layer) Allocator.Error!void {
        if (self.layer) |o| removeItem(LNode, &o.nodes, self);
        self.layer = l;
        if (l) |o| try o.nodes.append(self.a, self);
    }
    pub fn setLayerAt(self: *LNode, idx: usize, l: *Layer) Allocator.Error!void {
        if (self.layer) |o| removeItem(LNode, &o.nodes, self);
        self.layer = l;
        try l.nodes.insert(self.a, idx, self);
    }
    pub fn index(self: *const LNode) usize {
        if (self.layer) |l| {
            for (l.nodes.items, 0..) |n, i| if (n == self) return i;
        } else if (self.graph) |g| {
            for (g.layerless_nodes.items, 0..) |n, i| if (n == self) return i;
        }
        unreachable;
    }

    // ports on `side` as a view of `ports` (ELK keeps ports ordered by side); valid until `ports` changes
    pub fn portSideView(self: *LNode, side: PortSide) []*LPort {
        var first: usize = self.ports.items.len;
        var last: usize = 0;
        for (self.ports.items, 0..) |q, i| if (q.side == side) {
            if (i < first) first = i;
            last = i + 1;
        };
        if (first >= last) return self.ports.items[0..0];
        return self.ports.items[first..last];
    }

    pub fn portsOfSide(self: *const LNode, a: Allocator, side: PortSide) Allocator.Error![]*LPort {
        var out: std.ArrayList(*LPort) = .empty;
        for (self.ports.items) |q| if (q.side == side) try out.append(a, q);
        return out.items;
    }

    // LNode.borderToContentAreaCoordinates
    pub fn borderToContentAreaCoordinates(self: *LNode, horizontal: bool, vertical: bool) void {
        const pad = self.padding;
        if (horizontal) {
            self.pos.x -= pad.left;
            self.size.x -= pad.left + pad.right;
        }
        if (vertical) {
            self.pos.y -= pad.top;
            self.size.y -= pad.top + pad.bottom;
        }
    }
};

pub const LGraph = struct {
    a: Allocator,
    id: i32 = 0,
    size: Vec = .{},
    padding: Margin = .{},
    offset: Vec = .{},
    layerless_nodes: std.ArrayList(*LNode) = .empty,
    layers: std.ArrayList(*Layer) = .empty,
    parent_node: ?*LNode = null,
    p: Props = .{},

    pub fn init(a: Allocator) Allocator.Error!*LGraph {
        const x = try a.create(LGraph);
        x.* = .{ .a = a };
        return x;
    }

    pub fn actualSize(self: *const LGraph) Vec {
        return .{ .x = self.size.x + self.padding.left + self.padding.right, .y = self.size.y + self.padding.top + self.padding.bottom };
    }

    pub fn newLayer(self: *LGraph) Allocator.Error!*Layer {
        const l = try self.a.create(Layer);
        l.* = .{ .a = self.a, .owner = self };
        return l;
    }
};

pub fn removeItem(comptime T: type, list: *std.ArrayList(*T), item: *T) void {
    for (list.items, 0..) |x, i| if (x == item) {
        _ = list.orderedRemove(i);
        return;
    };
}

// java.util.Random, bit for bit
pub const JavaRandom = struct {
    seed: u64,

    const mult: u64 = 0x5DEECE66D;
    const mask: u64 = (1 << 48) - 1;

    pub fn init(seed: i64) JavaRandom {
        return .{ .seed = (@as(u64, @bitCast(seed)) ^ mult) & mask };
    }
    fn next(self: *JavaRandom, bits: u6) i32 {
        self.seed = (self.seed *% mult +% 0xB) & mask;
        const v: u64 = self.seed >> @intCast(48 - @as(u7, bits));
        return @bitCast(@as(u32, @truncate(v)));
    }
    pub fn nextInt(self: *JavaRandom) i32 {
        return self.next(32);
    }
    pub fn nextIntBound(self: *JavaRandom, bound: i32) i32 {
        var r = self.next(31);
        const m = bound - 1;
        if ((bound & m) == 0) {
            return @truncate((@as(i64, bound) * @as(i64, r)) >> 31);
        }
        var u = r;
        while (true) {
            r = @mod(u, bound);
            if (@as(i64, u) - r + m <= std.math.maxInt(i32)) break;
            u = self.next(31);
        }
        return r;
    }
    pub fn nextBoolean(self: *JavaRandom) bool {
        return self.next(1) != 0;
    }
    pub fn nextDouble(self: *JavaRandom) f64 {
        const hi: i64 = @as(i64, self.next(26)) << 27;
        const lo: i64 = self.next(27);
        return @as(f64, @floatFromInt(hi + lo)) * (1.0 / @as(f64, @floatFromInt(@as(i64, 1) << 53)));
    }
};
