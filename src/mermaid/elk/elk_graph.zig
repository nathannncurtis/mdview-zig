const std = @import("std");
const lg = @import("lgraph.zig");
const Allocator = std.mem.Allocator;
const Vec = lg.Vec;

// Layout options as set on an ELK graph element. null = not set (Java hasProperty false), so copying onto an
// LGraph element (copyProperties) only overrides what was given.
pub const Options = struct {
    algorithm: ?[]const u8 = null,
    direction: ?lg.Direction = null,
    hierarchy_handling: ?lg.HierarchyHandling = null,
    spacing_base_value: ?f64 = null,
    padding: ?lg.Margin = null,
    node_size_constraints: ?lg.SizeConstraint = null,
    node_size_options: ?lg.SizeOptions = null,
    node_size_minimum: ?Vec = null,
    node_size_fixed_graph_size: ?bool = null,
    node_labels_placement: ?lg.NodeLabelPlacement = null,
    node_labels_padding: ?lg.Margin = null,
    content_alignment: ?lg.ContentAlignment = null,
    edge_labels_inline: ?bool = null,
    edge_labels_placement: ?lg.EdgeLabelPlacement = null,
    port_constraints: ?lg.PortConstraints = null,
    port_side: ?lg.PortSide = null,
    port_index: ?i32 = null,
    port_border_offset: ?f64 = null,
    port_anchor: ?Vec = null,
    port_alignment_default: ?lg.PortAlignment = null,
    no_layout: ?bool = null,
    edge_routing: ?lg.EdgeRouting = null,
    edge_thickness: ?f64 = null,
    inside_self_loops_activate: ?bool = null,
    inside_self_loops_yo: ?bool = null,
    cycle_breaking: ?lg.CycleBreaking = null,
    layering: ?lg.Layering = null,
    node_placement: ?lg.NodePlacement = null,
    bk_fixed_alignment: ?lg.FixedAlignment = null,
    favor_straight_edges: ?bool = null,
    consider_model_order: ?lg.OrderingStrategy = null,
    force_node_model_order: ?bool = null,
    merge_edges: ?bool = null,
    merge_hierarchy_edges: ?bool = null,
    unnecessary_bendpoints: ?bool = null,
    self_loop_distribution: ?lg.SelfLoopDistribution = null,
    self_loop_ordering: ?lg.SelfLoopOrdering = null,
    thoroughness: ?i32 = null,
    random_seed: ?i32 = null,
    separate_connected_components: ?bool = null,
    aspect_ratio: ?f64 = null,
    feedback_edges: ?bool = null,
    layer_constraint: ?lg.LayerConstraint = null,
    priority_straightness: ?i32 = null,
    priority_direction: ?i32 = null,
    priority_shortness: ?i32 = null,
    hierarchical_sweepiness: ?f64 = null,
    greedy_switch: ?lg.GreedySwitchType = null,
    greedy_switch_hierarchical: ?lg.GreedySwitchType = null,
    greedy_switch_activation_threshold: ?i32 = null,
    allow_non_flow_ports_to_switch_sides: ?bool = null,
    spacing_edge_edge: ?f64 = null,
    spacing_edge_node: ?f64 = null,
    spacing_node_node: ?f64 = null,
    spacing_edge_edge_between_layers: ?f64 = null,
    spacing_edge_node_between_layers: ?f64 = null,
    spacing_node_node_between_layers: ?f64 = null,
    spacing_port_port: ?f64 = null,
    spacing_component_component: ?f64 = null,
    spacing_node_self_loop: ?f64 = null,
    spacing_label_label: ?f64 = null,
    spacing_label_port_horizontal: ?f64 = null,
    spacing_label_port_vertical: ?f64 = null,
    spacing_label_node: ?f64 = null,
    spacing_edge_label: ?f64 = null,
    spacing_ports_surrounding: ?lg.Margin = null,
    spacing_comment_comment: ?f64 = null,
    spacing_comment_node: ?f64 = null,
    // InternalProperties.MODEL_ORDER, set on ELK elements by the importer before copyProperties
    model_order: ?i32 = null,

    // MapPropertyHolder.copyProperties onto the layered property bag
    pub fn applyTo(o: *const Options, p: *lg.Props) void {
        inline for (comptime std.meta.fieldNames(Options)) |name| {
            if (@field(o, name)) |v| {
                if (comptime std.mem.startsWith(u8, name, "spacing_") and !std.mem.eql(u8, name, "spacing_base_value")) {
                    @field(p.spacing, name["spacing_".len..]) = v;
                } else if (comptime @hasField(lg.Props, name)) {
                    @field(p, name) = v;
                }
            }
        }
    }
};

// Full ELK option ids for the options above. Lookup by suffix follows LayoutMetaDataService.getOptionDataBySuffix.
pub const option_ids = [_]struct { []const u8, []const u8 }{
    .{ "org.eclipse.elk.algorithm", "algorithm" },
    .{ "org.eclipse.elk.direction", "direction" },
    .{ "org.eclipse.elk.hierarchyHandling", "hierarchy_handling" },
    .{ "org.eclipse.elk.layered.spacing.baseValue", "spacing_base_value" },
    .{ "org.eclipse.elk.padding", "padding" },
    .{ "org.eclipse.elk.nodeSize.constraints", "node_size_constraints" },
    .{ "org.eclipse.elk.nodeSize.options", "node_size_options" },
    .{ "org.eclipse.elk.nodeSize.minimum", "node_size_minimum" },
    .{ "org.eclipse.elk.nodeSize.fixedGraphSize", "node_size_fixed_graph_size" },
    .{ "org.eclipse.elk.nodeLabels.placement", "node_labels_placement" },
    .{ "org.eclipse.elk.nodeLabels.padding", "node_labels_padding" },
    .{ "org.eclipse.elk.contentAlignment", "content_alignment" },
    .{ "org.eclipse.elk.edgeLabels.inline", "edge_labels_inline" },
    .{ "org.eclipse.elk.edgeLabels.placement", "edge_labels_placement" },
    .{ "org.eclipse.elk.portConstraints", "port_constraints" },
    .{ "org.eclipse.elk.port.side", "port_side" },
    .{ "org.eclipse.elk.port.index", "port_index" },
    .{ "org.eclipse.elk.port.borderOffset", "port_border_offset" },
    .{ "org.eclipse.elk.port.anchor", "port_anchor" },
    .{ "org.eclipse.elk.portAlignment.default", "port_alignment_default" },
    .{ "org.eclipse.elk.noLayout", "no_layout" },
    .{ "org.eclipse.elk.edgeRouting", "edge_routing" },
    .{ "org.eclipse.elk.edge.thickness", "edge_thickness" },
    .{ "org.eclipse.elk.insideSelfLoops.activate", "inside_self_loops_activate" },
    .{ "org.eclipse.elk.insideSelfLoops.yo", "inside_self_loops_yo" },
    .{ "org.eclipse.elk.layered.cycleBreaking.strategy", "cycle_breaking" },
    .{ "org.eclipse.elk.layered.layering.strategy", "layering" },
    .{ "org.eclipse.elk.layered.nodePlacement.strategy", "node_placement" },
    .{ "org.eclipse.elk.layered.nodePlacement.bk.fixedAlignment", "bk_fixed_alignment" },
    .{ "org.eclipse.elk.layered.nodePlacement.favorStraightEdges", "favor_straight_edges" },
    .{ "org.eclipse.elk.layered.considerModelOrder.strategy", "consider_model_order" },
    .{ "org.eclipse.elk.layered.crossingMinimization.forceNodeModelOrder", "force_node_model_order" },
    .{ "org.eclipse.elk.layered.mergeEdges", "merge_edges" },
    .{ "org.eclipse.elk.layered.mergeHierarchyEdges", "merge_hierarchy_edges" },
    .{ "org.eclipse.elk.layered.unnecessaryBendpoints", "unnecessary_bendpoints" },
    .{ "org.eclipse.elk.layered.edgeRouting.selfLoopDistribution", "self_loop_distribution" },
    .{ "org.eclipse.elk.layered.edgeRouting.selfLoopOrdering", "self_loop_ordering" },
    .{ "org.eclipse.elk.layered.thoroughness", "thoroughness" },
    .{ "org.eclipse.elk.randomSeed", "random_seed" },
    .{ "org.eclipse.elk.separateConnectedComponents", "separate_connected_components" },
    .{ "org.eclipse.elk.aspectRatio", "aspect_ratio" },
    .{ "org.eclipse.elk.layered.feedbackEdges", "feedback_edges" },
    .{ "org.eclipse.elk.layered.layering.layerConstraint", "layer_constraint" },
    .{ "org.eclipse.elk.layered.priority.straightness", "priority_straightness" },
    .{ "org.eclipse.elk.layered.priority.direction", "priority_direction" },
    .{ "org.eclipse.elk.layered.priority.shortness", "priority_shortness" },
    .{ "org.eclipse.elk.layered.crossingMinimization.hierarchicalSweepiness", "hierarchical_sweepiness" },
    .{ "org.eclipse.elk.layered.crossingMinimization.greedySwitch.type", "greedy_switch" },
    .{ "org.eclipse.elk.layered.crossingMinimization.greedySwitchHierarchical.type", "greedy_switch_hierarchical" },
    .{ "org.eclipse.elk.layered.crossingMinimization.greedySwitch.activationThreshold", "greedy_switch_activation_threshold" },
    .{ "org.eclipse.elk.layered.allowNonFlowPortsToSwitchSides", "allow_non_flow_ports_to_switch_sides" },
    .{ "org.eclipse.elk.spacing.edgeEdge", "spacing_edge_edge" },
    .{ "org.eclipse.elk.spacing.edgeNode", "spacing_edge_node" },
    .{ "org.eclipse.elk.spacing.nodeNode", "spacing_node_node" },
    .{ "org.eclipse.elk.layered.spacing.edgeEdgeBetweenLayers", "spacing_edge_edge_between_layers" },
    .{ "org.eclipse.elk.layered.spacing.edgeNodeBetweenLayers", "spacing_edge_node_between_layers" },
    .{ "org.eclipse.elk.layered.spacing.nodeNodeBetweenLayers", "spacing_node_node_between_layers" },
    .{ "org.eclipse.elk.spacing.portPort", "spacing_port_port" },
    .{ "org.eclipse.elk.spacing.componentComponent", "spacing_component_component" },
    .{ "org.eclipse.elk.spacing.nodeSelfLoop", "spacing_node_self_loop" },
    .{ "org.eclipse.elk.spacing.labelLabel", "spacing_label_label" },
    .{ "org.eclipse.elk.spacing.labelPortHorizontal", "spacing_label_port_horizontal" },
    .{ "org.eclipse.elk.spacing.labelPortVertical", "spacing_label_port_vertical" },
    .{ "org.eclipse.elk.spacing.labelNode", "spacing_label_node" },
    .{ "org.eclipse.elk.spacing.edgeLabel", "spacing_edge_label" },
    .{ "org.eclipse.elk.spacing.portsSurrounding", "spacing_ports_surrounding" },
    .{ "org.eclipse.elk.spacing.commentComment", "spacing_comment_comment" },
    .{ "org.eclipse.elk.spacing.commentNode", "spacing_comment_node" },
};

// Sets option `key` from its string form; unknown keys and unparsable values are ignored like elkjs does.
pub fn setOption(o: *Options, key: []const u8, value: []const u8) void {
    const idx = resolveOption(key) orelse return;
    inline for (option_ids, 0..) |e, i| {
        if (i == idx) {
            const T = @typeInfo(@TypeOf(@field(o, e[1]))).optional.child;
            if (parseValue(T, value)) |v| @field(o, e[1]) = v;
            return;
        }
    }
}

pub fn resolveOption(key: []const u8) ?usize {
    if (key.len == 0) return null;
    var found: ?usize = null;
    for (option_ids, 0..) |e, i| {
        const id = e[0];
        if (std.mem.endsWith(u8, id, key) and (key.len == id.len or id[id.len - key.len - 1] == '.')) {
            if (key.len == id.len) return i;
            if (found != null) return null;
            found = i;
        }
    }
    return found;
}

fn enumFromName(comptime E: type, s: []const u8) ?E {
    inline for (comptime std.meta.tags(E)) |t| {
        if (upperEql(@tagName(t), s)) return t;
    }
    return null;
}

fn upperEql(comptime name: []const u8, s: []const u8) bool {
    if (name.len != s.len) return false;
    for (name, s) |c, d| if (std.ascii.toUpper(c) != d) return false;
    return true;
}

fn setFromNames(comptime S: type, s: []const u8) ?S {
    var out: S = .{};
    var it = std.mem.tokenizeAny(u8, s, "[] \t\r\n,");
    while (it.next()) |comp| {
        var ok = false;
        inline for (comptime std.meta.fieldNames(S)) |name| {
            if (upperEql(name, comp)) {
                @field(out, name) = true;
                ok = true;
            }
        }
        if (!ok) return null;
    }
    return out;
}

fn trimDelims(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and std.mem.indexOfScalar(u8, "([{\"' \t\r\n", s[start]) != null) start += 1;
    var end = s.len;
    while (end > start and std.mem.indexOfScalar(u8, ")]}\"' \t\r\n", s[end - 1]) != null) end -= 1;
    return s[start..end];
}

fn parseDouble(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null;
}

// Spacing.parse (ElkPadding / ElkMargin)
fn parseMargin(s: []const u8) ?lg.Margin {
    var m: lg.Margin = .{};
    const body = trimDelims(s);
    if (body.len == 0) return m;
    var it = std.mem.splitAny(u8, body, ",;");
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return null;
        if (std.mem.indexOfScalarPos(u8, tok, eq + 1, '=') != null) return null;
        const key = std.mem.trim(u8, tok[0..eq], " \t\r\n");
        const v = parseDouble(tok[eq + 1 ..]) orelse return null;
        if (std.mem.eql(u8, key, "top")) m.top = v else if (std.mem.eql(u8, key, "left")) m.left = v else if (std.mem.eql(u8, key, "bottom")) m.bottom = v else if (std.mem.eql(u8, key, "right")) m.right = v;
    }
    return m;
}

// KVector.parse
fn parseVec(s: []const u8) ?Vec {
    const body = trimDelims(s);
    if (body.len == 0) return null;
    var it = std.mem.splitAny(u8, body, ",;\r\n");
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .x = parseDouble(xs) orelse return null, .y = parseDouble(ys) orelse return null };
}

pub fn parseValue(comptime T: type, s: []const u8) ?T {
    if (std.mem.eql(u8, s, "null")) return null;
    if (s.len == 0 and @typeInfo(T) != .@"struct") return null;
    if (T == []const u8) return s;
    if (T == f64) return parseDouble(s);
    if (T == i32) return std.fmt.parseInt(i32, s, 10) catch null;
    if (T == bool) {
        if (std.ascii.eqlIgnoreCase(s, "true")) return true;
        if (std.ascii.eqlIgnoreCase(s, "false")) return false;
        return null;
    }
    if (T == lg.Margin) return parseMargin(s);
    if (T == Vec) return parseVec(s);
    return switch (@typeInfo(T)) {
        .@"enum" => enumFromName(T, s),
        .@"struct" => setFromNames(T, s),
        else => @compileError("unsupported option type"),
    };
}

pub const Shape = union(enum) {
    node: *ElkNode,
    port: *ElkPort,

    // ElkGraphUtil.connectableShapeToNode
    pub fn toNode(s: Shape) *ElkNode {
        return switch (s) {
            .node => |n| n,
            .port => |p| p.parent,
        };
    }
    fn outgoing(s: Shape) *std.ArrayList(*ElkEdge) {
        return switch (s) {
            .node => |n| &n.outgoing_edges,
            .port => |p| &p.outgoing_edges,
        };
    }
    fn incoming(s: Shape) *std.ArrayList(*ElkEdge) {
        return switch (s) {
            .node => |n| &n.incoming_edges,
            .port => |p| &p.incoming_edges,
        };
    }
    pub fn eql(s: Shape, o: Shape) bool {
        return switch (s) {
            .node => |n| o == .node and o.node == n,
            .port => |p| o == .port and o.port == p,
        };
    }
};

pub const ElkLabel = struct {
    text: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    opts: Options = .{},
};

pub const ElkPort = struct {
    id: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    parent: *ElkNode,
    labels: std.ArrayList(*ElkLabel) = .empty,
    outgoing_edges: std.ArrayList(*ElkEdge) = .empty,
    incoming_edges: std.ArrayList(*ElkEdge) = .empty,
    opts: Options = .{},
};

pub const ElkEdgeSection = struct {
    start: Vec = .{},
    end: Vec = .{},
    bend_points: std.ArrayList(Vec) = .empty,
    incoming_shape: ?Shape = null,
    outgoing_shape: ?Shape = null,
};

pub const ElkEdge = struct {
    id: []const u8 = "",
    sources: std.ArrayList(Shape) = .empty,
    targets: std.ArrayList(Shape) = .empty,
    labels: std.ArrayList(*ElkLabel) = .empty,
    sections: std.ArrayList(*ElkEdgeSection) = .empty,
    // ElkEdge.getContainingNode
    container: ?*ElkNode = null,
    junction_points: std.ArrayList(Vec) = .empty,
    opts: Options = .{},

    pub fn isHyperedge(e: *const ElkEdge) bool {
        return e.sources.items.len + e.targets.items.len > 2;
    }
    pub fn isConnected(e: *const ElkEdge) bool {
        return e.sources.items.len > 0 and e.targets.items.len > 0;
    }
    // ElkEdge.isSelfloop: every incident shape belongs to the same node
    pub fn isSelfloop(e: *const ElkEdge) bool {
        if (!e.isConnected()) return false;
        const n = e.sources.items[0].toNode();
        for (e.sources.items) |s| if (s.toNode() != n) return false;
        for (e.targets.items) |s| if (s.toNode() != n) return false;
        return true;
    }
    pub fn sourceNode(e: *const ElkEdge) *ElkNode {
        return e.sources.items[0].toNode();
    }
    pub fn targetNode(e: *const ElkEdge) *ElkNode {
        return e.targets.items[0].toNode();
    }
};

pub const ElkNode = struct {
    id: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    parent: ?*ElkNode = null,
    children: std.ArrayList(*ElkNode) = .empty,
    ports: std.ArrayList(*ElkPort) = .empty,
    labels: std.ArrayList(*ElkLabel) = .empty,
    // ElkNode.getContainedEdges, in containment order
    contained_edges: std.ArrayList(*ElkEdge) = .empty,
    // edges in the order they were declared on this node (the `edges` array of the JSON); output keeps them here
    declared_edges: std.ArrayList(*ElkEdge) = .empty,
    outgoing_edges: std.ArrayList(*ElkEdge) = .empty,
    incoming_edges: std.ArrayList(*ElkEdge) = .empty,
    opts: Options = .{},

    pub fn hierarchyHandling(n: *const ElkNode) lg.HierarchyHandling {
        return n.opts.hierarchy_handling orelse .inherit;
    }
};

// ElkGraphUtil.createNode
pub fn createNode(a: Allocator, parent: ?*ElkNode, id: []const u8) Allocator.Error!*ElkNode {
    const n = try a.create(ElkNode);
    n.* = .{ .id = id, .parent = parent };
    if (parent) |p| try p.children.append(a, n);
    return n;
}

pub fn createPort(a: Allocator, parent: *ElkNode, id: []const u8) Allocator.Error!*ElkPort {
    const p = try a.create(ElkPort);
    p.* = .{ .id = id, .parent = parent };
    try parent.ports.append(a, p);
    return p;
}

pub fn createLabel(a: Allocator, labels: *std.ArrayList(*ElkLabel), text: []const u8) Allocator.Error!*ElkLabel {
    const l = try a.create(ElkLabel);
    l.* = .{ .text = text };
    try labels.append(a, l);
    return l;
}

// ElkGraphUtil.createEdge: the edge is contained in `container` until updateContainment moves it
pub fn createEdge(a: Allocator, container: *ElkNode, id: []const u8) Allocator.Error!*ElkEdge {
    const e = try a.create(ElkEdge);
    e.* = .{ .id = id, .container = container };
    try container.contained_edges.append(a, e);
    try container.declared_edges.append(a, e);
    return e;
}

pub fn addSource(a: Allocator, e: *ElkEdge, s: Shape) Allocator.Error!void {
    try e.sources.append(a, s);
    try s.outgoing().append(a, e);
}

pub fn addTarget(a: Allocator, e: *ElkEdge, s: Shape) Allocator.Error!void {
    try e.targets.append(a, s);
    try s.incoming().append(a, e);
}

pub fn createEdgeSection(a: Allocator, e: *ElkEdge) Allocator.Error!*ElkEdgeSection {
    const s = try a.create(ElkEdgeSection);
    s.* = .{};
    try e.sections.append(a, s);
    return s;
}

// createEdge + one source + one target + updateContainment, the way the JSON importer builds an edge
pub fn connect(a: Allocator, declared_in: *ElkNode, id: []const u8, source: *ElkNode, target: *ElkNode) Allocator.Error!*ElkEdge {
    const e = try createEdge(a, declared_in, id);
    try addSource(a, e, .{ .node = source });
    try addTarget(a, e, .{ .node = target });
    try updateContainment(a, e);
    return e;
}

// ElkGraphUtil.isDescendant
pub fn isDescendant(child: *const ElkNode, ancestor: *const ElkNode) bool {
    var cur = child;
    while (cur.parent) |p| {
        cur = p;
        if (cur == ancestor) return true;
    }
    return false;
}

// ElkGraphUtil.findLowestCommonAncestor
pub fn findLowestCommonAncestor(n1: *ElkNode, n2: *ElkNode) ?*ElkNode {
    var buf1: [256]*ElkNode = undefined;
    var buf2: [256]*ElkNode = undefined;
    const c1 = ancestors(n1, &buf1);
    const c2 = ancestors(n2, &buf2);
    var i = c1.len;
    var j = c2.len;
    var common: ?*ElkNode = null;
    while (i > 0 and j > 0) {
        i -= 1;
        j -= 1;
        if (c1[i] == c2[j]) common = c1[i] else break;
    }
    return common;
}

fn ancestors(n: *ElkNode, buf: []*ElkNode) []*ElkNode {
    var k: usize = 0;
    var cur: ?*ElkNode = n;
    while (cur) |c| : (cur = c.parent) {
        if (k == buf.len) break;
        buf[k] = c;
        k += 1;
    }
    return buf[0..k];
}

// ElkGraphUtil.findBestEdgeContainment
pub fn findBestEdgeContainment(e: *const ElkEdge) ?*ElkNode {
    const total = e.sources.items.len + e.targets.items.len;
    if (total == 0) return null;
    if (total == 1) {
        return if (e.sources.items.len == 0) e.targets.items[0].toNode().parent else e.sources.items[0].toNode().parent;
    }
    if (e.sources.items.len == 1 and e.targets.items.len == 1) {
        const s = e.sources.items[0].toNode();
        const t = e.targets.items[0].toNode();
        if (s.parent == t.parent) return s.parent;
        if (s == t.parent) return s;
        if (t == s.parent) return t;
    }
    var common = e.sources.items[0].toNode();
    var first = true;
    for ([_][]const Shape{ e.sources.items, e.targets.items }) |list| {
        for (list) |sh| {
            if (first) {
                first = false;
                continue;
            }
            const n = sh.toNode();
            if (n != common and !isDescendant(n, common)) {
                if (n.parent == common.parent) {
                    common = n.parent orelse return null;
                } else {
                    common = findLowestCommonAncestor(common, n) orelse return null;
                }
            }
        }
    }
    return common;
}

// ElkGraphUtil.updateContainment (EMF moves the edge to the end of the new container's list)
pub fn updateContainment(a: Allocator, e: *ElkEdge) Allocator.Error!void {
    const nc = findBestEdgeContainment(e);
    if (nc == e.container) return;
    if (e.container) |old| lg.removeItem(ElkEdge, &old.contained_edges, e);
    e.container = nc;
    if (nc) |c| try c.contained_edges.append(a, e);
}

// ElkUtil.toAbsolute: from the coordinate system of `parent` (its top left corner) to the root's
pub fn toAbsolute(p: *Vec, parent: ?*const ElkNode) void {
    var cur = parent;
    while (cur) |n| : (cur = n.parent) {
        p.x += n.x;
        p.y += n.y;
    }
}

// ElkUtil.toRelative
pub fn toRelative(p: *Vec, parent: ?*const ElkNode) void {
    var cur = parent;
    while (cur) |n| : (cur = n.parent) {
        p.x -= n.x;
        p.y -= n.y;
    }
}

test "option suffix resolution and parsing" {
    var o: Options = .{};
    setOption(&o, "spacing.baseValue", "40");
    setOption(&o, "elk.padding", "[top=24,left=24,bottom=24,right=24]");
    setOption(&o, "nodeSize.minimum", "(64.5, 0)");
    setOption(&o, "nodeSize.constraints", "[MINIMUM_SIZE, NODE_LABELS]");
    setOption(&o, "nodeLabels.placement", "[H_CENTER V_TOP, INSIDE]");
    setOption(&o, "elk.direction", "DOWN");
    setOption(&o, "elk.layered.mergeEdges", "false");
    setOption(&o, "elk.layered.layering.coffmanGraham.layerBound", "4");
    setOption(&o, "elk.direction", "down");
    try std.testing.expectEqual(@as(?f64, 40), o.spacing_base_value);
    try std.testing.expectEqual(@as(f64, 24), o.padding.?.left);
    try std.testing.expectEqual(@as(f64, 64.5), o.node_size_minimum.?.x);
    try std.testing.expect(o.node_size_constraints.?.minimum_size and o.node_size_constraints.?.node_labels);
    try std.testing.expect(o.node_labels_placement.?.h_center and o.node_labels_placement.?.inside);
    try std.testing.expectEqual(lg.Direction.down, o.direction.?);
    try std.testing.expectEqual(false, o.merge_edges.?);
    var p: lg.Props = .{};
    o.applyTo(&p);
    try std.testing.expectEqual(@as(f64, 24), p.padding.top);
}
