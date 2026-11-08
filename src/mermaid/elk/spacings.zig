const std = @import("std");
const lg = @import("lgraph.zig");
const eg = @import("elk_graph.zig");

// LayeredSpacings.withBaseValue(base).apply(lgraph): every spacing option not set on the graph becomes
// (default / nodeNode default) * base. `set` holds the options copied onto the graph from its ELK node.
pub fn withBaseValue(sp: *lg.Spacings, base: f64, set: *const eg.Options) void {
    const base_default: f64 = 20;
    if (@abs(base - base_default) <= 10e-5) return;
    const Entry = struct { []const u8, f64 };
    const entries = [_]Entry{
        .{ "node_node", 20 },
        .{ "component_component", 20 },
        .{ "edge_edge", 10 },
        .{ "edge_label", 2 },
        .{ "edge_node", 10 },
        .{ "label_label", 0 },
        .{ "label_node", 5 },
        .{ "label_port_horizontal", 1 },
        .{ "label_port_vertical", 1 },
        .{ "node_self_loop", 10 },
        .{ "port_port", 10 },
        .{ "edge_edge_between_layers", 10 },
        .{ "edge_node_between_layers", 10 },
        .{ "node_node_between_layers", 20 },
    };
    inline for (entries) |e| {
        if (@field(set, "spacing_" ++ e[0]) == null) @field(sp, e[0]) = (e[1] / base_default) * base;
    }
}

pub const Opt = enum {
    node_node,
    node_node_between_layers,
    edge_node,
    edge_node_between_layers,
    edge_edge,
    edge_edge_between_layers,
    label_node,
    port_port,
    label_port_vertical,
    label_port_horizontal,

    fn of(o: Opt, sp: *const lg.Spacings) f64 {
        return switch (o) {
            .node_node => sp.node_node,
            .node_node_between_layers => sp.node_node_between_layers,
            .edge_node => sp.edge_node,
            .edge_node_between_layers => sp.edge_node_between_layers,
            .edge_edge => sp.edge_edge,
            .edge_edge_between_layers => sp.edge_edge_between_layers,
            .label_node => sp.label_node,
            .port_port => sp.port_port,
            .label_port_vertical => sp.label_port_vertical,
            .label_port_horizontal => sp.label_port_horizontal,
        };
    }
};

const n_types = std.enums.values(lg.NodeType).len;
const Table = [n_types][n_types]?Opt;

const Tables = struct { vertical: Table, horizontal: Table };

// Spacings.precalculateNodeTypeSpacings
const tables: Tables = blk: {
    var t: Tables = .{
        .vertical = @splat(@splat(null)),
        .horizontal = @splat(@splat(null)),
    };
    const N = @intFromEnum(lg.NodeType.normal);
    const LE = @intFromEnum(lg.NodeType.long_edge);
    const NS = @intFromEnum(lg.NodeType.north_south_port);
    const EP = @intFromEnum(lg.NodeType.external_port);
    const LA = @intFromEnum(lg.NodeType.label);
    const BP = @intFromEnum(lg.NodeType.breaking_point);
    const Rule = struct { usize, usize, Opt, ?Opt };
    const rules = [_]Rule{
        .{ N, N, .node_node, .node_node_between_layers },
        .{ N, LE, .edge_node, .edge_node_between_layers },
        .{ N, NS, .edge_node, null },
        .{ N, EP, .edge_node, null },
        .{ N, LA, .node_node, .node_node_between_layers },
        .{ LE, LE, .edge_edge, .edge_edge_between_layers },
        .{ LE, NS, .edge_edge, null },
        .{ LE, EP, .edge_edge, null },
        .{ LE, LA, .edge_node, .edge_node_between_layers },
        .{ NS, NS, .edge_edge, null },
        .{ NS, EP, .edge_edge, null },
        .{ NS, LA, .label_node, null },
        .{ EP, EP, .port_port, null },
        .{ EP, LA, .label_port_vertical, .label_port_horizontal },
        .{ LA, LA, .edge_edge, .edge_edge },
        .{ BP, BP, .edge_edge, .edge_edge_between_layers },
        .{ BP, N, .edge_node, .edge_node_between_layers },
        .{ BP, LA, .edge_node, .edge_node_between_layers },
        .{ BP, LE, .edge_node, .edge_node_between_layers },
    };
    for (rules) |r| {
        t.vertical[r[0]][r[1]] = r[2];
        t.vertical[r[1]][r[0]] = r[2];
        if (r[3]) |h| {
            t.horizontal[r[0]][r[1]] = h;
            t.horizontal[r[1]][r[0]] = h;
        }
    }
    break :blk t;
};

// Spacings.getLocalSpacing(LNode, LNode): max of both nodes' graph values (spacing.individual is never set).
// An unmapped pair is a NullPointerException in Java; it never occurs for the node types layered creates.
fn localSpacing(n1: *const lg.LNode, n2: *const lg.LNode, t: *const Table) f64 {
    const o = t[@intFromEnum(n1.type)][@intFromEnum(n2.type)] orelse return 0;
    return @max(o.of(&n1.graph.?.p.spacing), o.of(&n2.graph.?.p.spacing));
}

pub fn getVerticalSpacing(n1: *const lg.LNode, n2: *const lg.LNode) f64 {
    return localSpacing(n1, n2, &tables.vertical);
}

pub fn getHorizontalSpacing(n1: *const lg.LNode, n2: *const lg.LNode) f64 {
    return localSpacing(n1, n2, &tables.horizontal);
}

pub fn getVerticalSpacingOfTypes(g: *const lg.LGraph, t1: lg.NodeType, t2: lg.NodeType) f64 {
    const o = tables.vertical[@intFromEnum(t1)][@intFromEnum(t2)] orelse return 0;
    return o.of(&g.p.spacing);
}

pub fn getHorizontalSpacingOfTypes(g: *const lg.LGraph, t1: lg.NodeType, t2: lg.NodeType) f64 {
    const o = tables.horizontal[@intFromEnum(t1)][@intFromEnum(t2)] orelse return 0;
    return o.of(&g.p.spacing);
}

test "base value scales unset spacings" {
    var sp: lg.Spacings = .{};
    const set: eg.Options = .{ .spacing_node_node = 50 };
    sp.node_node = 50;
    withBaseValue(&sp, 24, &set);
    try std.testing.expectEqual(@as(f64, 50), sp.node_node);
    try std.testing.expectEqual(@as(f64, 12), sp.edge_edge);
    try std.testing.expectEqual(@as(f64, 24), sp.node_node_between_layers);
    try std.testing.expectEqual(@as(f64, 0), sp.label_label);
}
