const std = @import("std");
const lg = @import("lgraph.zig");
const eg = @import("elk_graph.zig");
const gu = @import("graph_util.zig");
const Importer = @import("graph/elk_graph_importer.zig").Importer;
const transferrer = @import("graph/elk_graph_layout_transferrer.zig");
const compound_pre = @import("compound/compound_graph_preprocessor.zig");
const compound_post = @import("compound/compound_graph_postprocessor.zig");
const components = @import("components/components_processor.zig");
const recursive = @import("recursive_layout.zig");

const p1 = @import("p1cycles/depth_first_cycle_breaker.zig");
const p2 = @import("p2layers/network_simplex_layerer.zig");
const p3 = @import("p3order/layer_sweep_crossing_minimizer.zig");
const p4 = @import("p4nodes/bk/bk_node_placer.zig");
const p5 = @import("p5edges/orthogonal_edge_router.zig");
const im = struct {
    const direction = @import("intermediate/graph_transformer.zig");
    const edge_and_layer_constraint_edge_reverser = @import("intermediate/edge_and_layer_constraint_edge_reverser.zig");
    const label_dummy_inserter = @import("intermediate/label_dummy_inserter.zig");
    const self_loop_preprocessor = @import("intermediate/self_loop_pre_processor.zig");
    const layer_constraint_preprocessor = @import("intermediate/layer_constraint_preprocessor.zig");
    const layer_constraint_postprocessor = @import("intermediate/layer_constraint_postprocessor.zig");
    const hierarchical_port_constraint_processor = @import("intermediate/hierarchical_port_constraint_processor.zig");
    const long_edge_splitter = @import("intermediate/long_edge_splitter.zig");
    const port_side_processor = @import("intermediate/port_side_processor.zig");
    const inverted_port_processor = @import("intermediate/inverted_port_processor.zig");
    const port_list_sorter = @import("intermediate/port_list_sorter.zig");
    const sort_by_input_order_of_model = @import("intermediate/sort_by_input_model_processor.zig");
    const self_loop_port_restorer = @import("intermediate/self_loop_port_restorer.zig");
    const in_layer_constraint_processor = @import("intermediate/in_layer_constraint_processor.zig");
    const label_and_node_size_processor = @import("intermediate/label_and_node_size_processor.zig");
    const innermost_node_margin_calculator = @import("intermediate/innermost_node_margin_calculator.zig");
    const self_loop_router = @import("intermediate/self_loop_router.zig");
    const label_dummy_switcher = @import("intermediate/label_dummy_switcher.zig");
    const label_side_selector = @import("intermediate/label_side_selector.zig");
    const hierarchical_port_dummy_size_processor = @import("intermediate/hierarchical_port_dummy_size_processor.zig");
    const layer_size_and_graph_height_calculator = @import("intermediate/layer_size_and_graph_height_calculator.zig");
    const hierarchical_port_position_processor = @import("intermediate/hierarchical_port_position_processor.zig");
    const hierarchical_port_orthogonal_edge_router = @import("intermediate/hierarchical_port_orthogonal_edge_router.zig");
    const long_edge_joiner = @import("intermediate/long_edge_joiner.zig");
    const self_loop_postprocessor = @import("intermediate/self_loop_post_processor.zig");
    const label_dummy_remover = @import("intermediate/label_dummy_remover.zig");
    const reversed_edge_restorer = @import("intermediate/reversed_edge_restorer.zig");
    const hierarchical_node_resizer = @import("intermediate/hierarchical_node_resizing_processor.zig");
};

// LayeredPhases, then IntermediateProcessorStrategy in its declaration order (the order AlgorithmAssembler sorts
// a slot by).
pub const Phase = enum { p1_cycle_breaking, p2_layering, p3_node_ordering, p4_node_placement, p5_edge_routing };

pub const Strategy = enum {
    direction_preprocessor,
    comment_preprocessor,
    edge_and_layer_constraint_edge_reverser,
    interactive_external_port_positioner,
    partition_preprocessor,
    label_dummy_inserter,
    self_loop_preprocessor,
    layer_constraint_preprocessor,
    partition_midprocessor,
    high_degree_node_layer_processor,
    node_promotion,
    layer_constraint_postprocessor,
    partition_postprocessor,
    hierarchical_port_constraint_processor,
    semi_interactive_crossmin_processor,
    breaking_point_inserter,
    long_edge_splitter,
    port_side_processor,
    inverted_port_processor,
    port_list_sorter,
    sort_by_input_order_of_model,
    north_south_port_preprocessor,
    breaking_point_processor,
    one_sided_greedy_switch,
    two_sided_greedy_switch,
    self_loop_port_restorer,
    single_edge_graph_wrapper,
    in_layer_constraint_processor,
    end_node_port_label_management_processor,
    label_and_node_size_processor,
    innermost_node_margin_calculator,
    self_loop_router,
    comment_node_margin_calculator,
    end_label_preprocessor,
    label_dummy_switcher,
    center_label_management_processor,
    label_side_selector,
    hyperedge_dummy_merger,
    hierarchical_port_dummy_size_processor,
    layer_size_and_graph_height_calculator,
    hierarchical_port_position_processor,
    constraints_postprocessor,
    comment_postprocessor,
    hypernode_processor,
    hierarchical_port_orthogonal_edge_router,
    long_edge_joiner,
    self_loop_postprocessor,
    breaking_point_remover,
    north_south_port_postprocessor,
    horizontal_compactor,
    label_dummy_remover,
    final_spline_bendpoints_calculator,
    end_label_sorter,
    reversed_edge_restorer,
    end_label_postprocessor,
    hierarchical_node_resizer,
    direction_postprocessor,
};

pub const Processor = union(enum) {
    phase: Phase,
    strategy: Strategy,

    // IHierarchyAwareLayoutProcessor: every LayerSweepCrossingMinimizer instance
    fn hierarchyAware(p: Processor) bool {
        return switch (p) {
            .phase => |ph| ph == .p3_node_ordering,
            .strategy => |s| s == .one_sided_greedy_switch or s == .two_sided_greedy_switch,
        };
    }
};

// LayoutProcessorConfiguration: one set per slot; slot i runs before phase i, slot 5 after the last phase
const Config = struct {
    slots: [6]std.EnumSet(Strategy) = @splat(.empty),

    fn before(c: *Config, ph: Phase, s: Strategy) void {
        c.slots[@backingInt(ph)].insert(s);
    }
    fn after(c: *Config, ph: Phase, s: Strategy) void {
        c.slots[@backingInt(ph) + 1].insert(s);
    }
};

fn phaseConfigurations(g: *const lg.LGraph, c: *Config) lg.Error!void {
    if (g.p.cycle_breaking != .depth_first or g.p.layering != .network_simplex or g.p.node_placement != .brandes_koepf or g.p.edge_routing != .orthogonal) {
        return error.Unsupported;
    }
    // DepthFirstCycleBreaker
    c.after(.p5_edge_routing, .reversed_edge_restorer);
    // NetworkSimplexLayerer
    c.before(.p1_cycle_breaking, .edge_and_layer_constraint_edge_reverser);
    c.before(.p2_layering, .layer_constraint_preprocessor);
    c.before(.p3_node_ordering, .layer_constraint_postprocessor);
    // LayerSweepCrossingMinimizer
    c.before(.p3_node_ordering, .long_edge_splitter);
    c.before(.p4_node_placement, .in_layer_constraint_processor);
    c.after(.p5_edge_routing, .long_edge_joiner);
    c.before(.p3_node_ordering, .port_list_sorter);
    // BKNodePlacer
    const gp = g.p.graph_properties;
    if (gp.external_ports) c.before(.p5_edge_routing, .hierarchical_port_position_processor);
    // OrthogonalEdgeRouter
    if (gp.hyperedges) {
        c.before(.p4_node_placement, .hyperedge_dummy_merger);
        c.before(.p3_node_ordering, .inverted_port_processor);
    }
    if (gp.non_free_ports or g.p.feedback_edges) {
        c.before(.p3_node_ordering, .inverted_port_processor);
        if (gp.north_south_ports) {
            c.before(.p3_node_ordering, .north_south_port_preprocessor);
            c.after(.p5_edge_routing, .north_south_port_postprocessor);
        }
    }
    if (gp.external_ports) {
        c.before(.p3_node_ordering, .hierarchical_port_constraint_processor);
        c.before(.p4_node_placement, .hierarchical_port_dummy_size_processor);
        c.after(.p5_edge_routing, .hierarchical_port_orthogonal_edge_router);
    }
    if (gp.self_loops) {
        c.before(.p1_cycle_breaking, .self_loop_preprocessor);
        c.after(.p5_edge_routing, .self_loop_postprocessor);
        c.before(.p4_node_placement, .self_loop_port_restorer);
        c.before(.p4_node_placement, .self_loop_router);
    }
    if (gp.hypernodes) c.after(.p5_edge_routing, .hypernode_processor);
    if (gp.center_labels) {
        c.before(.p2_layering, .label_dummy_inserter);
        c.before(.p4_node_placement, .label_dummy_switcher);
        c.before(.p4_node_placement, .label_side_selector);
        c.after(.p5_edge_routing, .label_dummy_remover);
    }
    if (gp.end_labels) {
        c.before(.p4_node_placement, .label_side_selector);
        c.before(.p4_node_placement, .end_label_preprocessor);
        c.after(.p5_edge_routing, .end_label_postprocessor);
    }
}

fn isHierarchicalLayout(g: *const lg.LGraph) bool {
    return g.p.hierarchy_handling == .include_children;
}

// GraphConfigurator.activateGreedySwitchFor (semi-interactive and interactive crossing minimization are never set)
fn activateGreedySwitchFor(g: *const lg.LGraph) bool {
    if (isHierarchicalLayout(g)) return g.parent_node == null and g.p.greedy_switch_hierarchical != .off;
    const threshold = g.p.greedy_switch_activation_threshold;
    const size: i64 = @intCast(g.layerless_nodes.items.len);
    return g.p.greedy_switch != .off and (threshold == 0 or threshold > size);
}

// GraphConfigurator.getPhaseIndependentLayoutProcessorConfiguration
fn phaseIndependentConfiguration(g: *const lg.LGraph, c: *Config) void {
    c.before(.p4_node_placement, .innermost_node_margin_calculator);
    c.before(.p4_node_placement, .label_and_node_size_processor);
    c.before(.p5_edge_routing, .layer_size_and_graph_height_calculator);
    c.after(.p5_edge_routing, .end_label_sorter);
    if (isHierarchicalLayout(g)) c.after(.p5_edge_routing, .hierarchical_node_resizer);
    if (g.p.feedback_edges) c.before(.p1_cycle_breaking, .port_side_processor) else c.before(.p3_node_ordering, .port_side_processor);
    switch (g.p.direction) {
        .left, .down, .up => {
            c.before(.p1_cycle_breaking, .direction_preprocessor);
            c.after(.p5_edge_routing, .direction_postprocessor);
        },
        else => {},
    }
    if (g.p.graph_properties.comments) {
        c.before(.p1_cycle_breaking, .comment_preprocessor);
        c.before(.p4_node_placement, .comment_node_margin_calculator);
        c.after(.p5_edge_routing, .comment_postprocessor);
    }
    if (g.p.graph_properties.partitions) {
        c.before(.p1_cycle_breaking, .partition_preprocessor);
        c.before(.p2_layering, .partition_midprocessor);
        c.before(.p3_node_ordering, .partition_postprocessor);
    }
    if (activateGreedySwitchFor(g)) {
        const t = if (isHierarchicalLayout(g)) g.p.greedy_switch_hierarchical else g.p.greedy_switch;
        c.before(.p4_node_placement, if (t == .one_sided) .one_sided_greedy_switch else .two_sided_greedy_switch);
    }
    if (g.p.consider_model_order != .none) c.before(.p3_node_ordering, .sort_by_input_order_of_model);
}

// AlgorithmAssembler.build: per phase its slot (sorted by strategy order, no duplicates), then the phase; then the
// slot after the last phase
pub fn buildProcessors(g: *const lg.LGraph) lg.Error![]Processor {
    var c: Config = .{};
    try phaseConfigurations(g, &c);
    phaseIndependentConfiguration(g, &c);
    var out: std.ArrayList(Processor) = .empty;
    for (0..6) |i| {
        var it = c.slots[i].iterator();
        while (it.next()) |s| try out.append(g.a, .{ .strategy = s });
        if (i < 5) try out.append(g.a, .{ .phase = @fromBackingInt(@intCast(i)) });
    }
    return out.items;
}

fn copyPortConstraints(g: *lg.LGraph) void {
    for (g.layerless_nodes.items) |n| copyPortConstraintsOf(n);
    for (g.layers.items) |l| for (l.nodes.items) |n| copyPortConstraintsOf(n);
}

fn copyPortConstraintsOf(n: *lg.LNode) void {
    n.p.original_port_constraints = n.p.port_constraints;
    if (n.nested_graph) |ng| copyPortConstraints(ng);
}

// GraphConfigurator.configureGraphProperties (Spacings is computed on demand by spacings.zig)
fn configureGraphProperties(g: *lg.LGraph) lg.Error!void {
    if (g.p.spacing.edge_edge < 2.0) g.p.spacing.edge_edge = 2.0;
    if (g.p.direction == .undefined) g.p.direction = gu.getDirection(g);
    const r = try g.a.create(lg.JavaRandom);
    r.* = lg.JavaRandom.init(g.p.random_seed);
    g.p.random = r;
    if (g.p.favor_straight_edges == null) g.p.favor_straight_edges = g.p.edge_routing == .orthogonal;
    copyPortConstraints(g);
}

// GraphConfigurator.prepareGraphForLayout
pub fn prepareGraphForLayout(g: *lg.LGraph) lg.Error![]Processor {
    try configureGraphProperties(g);
    return buildProcessors(g);
}

fn endLabelPreprocessor(g: *lg.LGraph) void {
    // with only CENTER labels EndLabelPreprocessor places nothing; its one visible effect is numbering ports
    for (g.layers.items) |l| for (l.nodes.items) |n| {
        for (n.ports.items, 0..) |port, i| port.id = @intCast(i);
    };
}

fn runProcessor(p: Processor, g: *lg.LGraph) lg.Error!void {
    switch (p) {
        .phase => |ph| switch (ph) {
            .p1_cycle_breaking => try p1.process(g),
            .p2_layering => try p2.process(g),
            .p3_node_ordering => try p3.process(g),
            .p4_node_placement => try p4.process(g),
            .p5_edge_routing => try p5.process(g),
        },
        .strategy => |s| switch (s) {
            .direction_preprocessor => try im.direction.DirectionPreprocessor.process(g),
            .direction_postprocessor => try im.direction.DirectionPostprocessor.process(g),
            .edge_and_layer_constraint_edge_reverser => try im.edge_and_layer_constraint_edge_reverser.process(g),
            .label_dummy_inserter => try im.label_dummy_inserter.process(g),
            .self_loop_preprocessor => try im.self_loop_preprocessor.process(g),
            .layer_constraint_preprocessor => try im.layer_constraint_preprocessor.process(g),
            .layer_constraint_postprocessor => try im.layer_constraint_postprocessor.process(g),
            .hierarchical_port_constraint_processor => try im.hierarchical_port_constraint_processor.process(g),
            .long_edge_splitter => try im.long_edge_splitter.process(g),
            .port_side_processor => try im.port_side_processor.process(g),
            .inverted_port_processor => try im.inverted_port_processor.process(g),
            .port_list_sorter => try im.port_list_sorter.process(g),
            .sort_by_input_order_of_model => try im.sort_by_input_order_of_model.process(g),
            .one_sided_greedy_switch => try p3.run(g, .one_sided_greedy_switch),
            .two_sided_greedy_switch => try p3.processTwoSidedGreedySwitch(g),
            .self_loop_port_restorer => try im.self_loop_port_restorer.process(g),
            .in_layer_constraint_processor => try im.in_layer_constraint_processor.process(g),
            .label_and_node_size_processor => try im.label_and_node_size_processor.process(g),
            .innermost_node_margin_calculator => try im.innermost_node_margin_calculator.process(g),
            .self_loop_router => try im.self_loop_router.process(g),
            .label_dummy_switcher => try im.label_dummy_switcher.process(g),
            .label_side_selector => try im.label_side_selector.process(g),
            .hierarchical_port_dummy_size_processor => try im.hierarchical_port_dummy_size_processor.process(g),
            .layer_size_and_graph_height_calculator => try im.layer_size_and_graph_height_calculator.process(g),
            .hierarchical_port_position_processor => try im.hierarchical_port_position_processor.process(g),
            .hierarchical_port_orthogonal_edge_router => try im.hierarchical_port_orthogonal_edge_router.process(g),
            .long_edge_joiner => try im.long_edge_joiner.process(g),
            .self_loop_postprocessor => try im.self_loop_postprocessor.process(g),
            .label_dummy_remover => try im.label_dummy_remover.process(g),
            .reversed_edge_restorer => try im.reversed_edge_restorer.process(g),
            .hierarchical_node_resizer => try im.hierarchical_node_resizer.process(g),
            .end_label_preprocessor => endLabelPreprocessor(g),
            // they act on HEAD / TAIL labels only, which Mermaid's layout-elk never hands to ELK
            .end_label_sorter, .end_label_postprocessor => {},
            else => return error.Unsupported,
        },
    }
}

// ElkLayered.layout
fn layoutComponent(g: *lg.LGraph, procs: []const Processor) lg.Error!void {
    for (procs) |p| try runProcessor(p, g);
    for (g.layers.items) |layer| {
        try g.layerless_nodes.appendSlice(g.a, layer.nodes.items);
        layer.nodes.clearRetainingCapacity();
    }
    for (g.layerless_nodes.items) |n| n.layer = null;
    g.layers.clearRetainingCapacity();
}

// ElkLayered.doLayout
pub fn doLayout(g: *lg.LGraph) lg.Error!void {
    const procs = try prepareGraphForLayout(g);
    const comps = try components.split(g);
    // the components copy the graph's properties, so they share its processor list
    for (comps) |comp| try layoutComponent(comp, procs);
    try components.combine(comps, g);
    if (!g.p.node_size_fixed_graph_size) im.hierarchical_node_resizer.resizeGraph(g);
}

// ElkLayered.doCompoundLayout
pub fn doCompoundLayout(g: *lg.LGraph) lg.Error!void {
    const map = try compound_pre.process(g);
    try hierarchicalLayout(g);
    try compound_post.process(g, map);
}

fn collectAllGraphsBottomUp(root: *lg.LGraph) lg.Error![]*lg.LGraph {
    const a = root.a;
    // ArrayDeque.push adds at the head; the result is iterated head first
    var collected: std.ArrayList(*lg.LGraph) = .empty;
    var stack: std.ArrayList(*lg.LGraph) = .empty;
    try collected.append(a, root);
    try stack.append(a, root);
    while (stack.pop()) |next| {
        for (next.layerless_nodes.items) |n| {
            if (n.nested_graph) |ng| {
                try collected.append(a, ng);
                try stack.append(a, ng);
            }
        }
    }
    std.mem.reverse(*lg.LGraph, collected.items);
    return collected.items;
}

// ElkLayered.hierarchicalLayout: every graph runs its processors in lock step; a hierarchy-aware processor runs
// once, on the root, and is skipped by the nested graphs.
fn hierarchicalLayout(root: *lg.LGraph) lg.Error!void {
    const graphs = try collectAllGraphsBottomUp(root);
    for (graphs) |g| {
        g.p.greedy_switch_hierarchical = root.p.greedy_switch_hierarchical;
    }
    const a = root.a;
    const lists = try a.alloc([]Processor, graphs.len);
    const pos = try a.alloc(usize, graphs.len);
    for (graphs, 0..) |g, i| {
        lists[i] = try prepareGraphForLayout(g);
        pos[i] = 0;
    }
    const ri = graphs.len - 1;
    while (pos[ri] < lists[ri].len) {
        for (graphs, 0..) |g, i| {
            while (pos[i] < lists[i].len) {
                const p = lists[i][pos[i]];
                pos[i] += 1;
                if (!p.hierarchyAware()) {
                    try runProcessor(p, g);
                } else if (g.parent_node == null) {
                    try runProcessor(p, g);
                    break;
                } else {
                    break;
                }
            }
        }
    }
}

// LayeredLayoutProvider.layout on one ELK node
pub fn layoutNode(a: std.mem.Allocator, elkgraph: *eg.ElkNode) lg.Error!void {
    var imp: Importer = .{ .a = a };
    const g = try imp.importGraph(elkgraph);
    if (elkgraph.hierarchyHandling() == .include_children) {
        try doCompoundLayout(g);
    } else {
        try doLayout(g);
    }
    try transferrer.applyLayout(&imp, g);
}

// elkjs layout(graph): lays out `root` in place (positions relative to the parent, edge sections relative to
// the edge's containing node)
pub fn layout(a: std.mem.Allocator, root: *eg.ElkNode) lg.Error!void {
    try recursive.layout(a, root);
}
