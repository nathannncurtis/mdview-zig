const std = @import("std");
const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const cs = @import("cellsystem.zig");
const NodeLabelLocation = @import("node_label_location.zig").NodeLabelLocation;
const Cell = cs.Cell;

const n_locations = std.enums.values(NodeLabelLocation).len;
const sides = [4]lg.PortSide{ .north, .east, .south, .west };

fn si(s: lg.PortSide) usize {
    return @backingInt(s);
}

// What the Java adapters read from the node's parent graph: spacings and node label padding through
// IndividualSpacings.getIndividualOrInherited, nodeSize.fixedGraphSize, and the layout direction.
pub const Env = struct {
    spacing: lg.Spacings,
    node_labels_padding: lg.Margin,
    fixed_graph_size: bool,
    horizontal_layout_mode: bool,

    pub fn ofGraph(g: *const lg.LGraph) Env {
        return .{
            .spacing = g.p.spacing,
            .node_labels_padding = g.p.node_labels_padding,
            .fixed_graph_size = g.p.node_size_fixed_graph_size,
            .horizontal_layout_mode = g.p.direction.isHorizontal(),
        };
    }
};

pub const PortContext = struct {
    port: *lg.LPort,
    port_position: lg.Vec,
};

// NodeContext
pub const NodeContext = struct {
    a: std.mem.Allocator,
    node: *lg.LNode,
    env: Env,
    node_size: lg.Vec,
    size_constraints: lg.SizeConstraint,
    size_options: lg.SizeOptions,
    port_constraints: lg.PortConstraints,
    node_label_placement: lg.NodeLabelPlacement,
    node_labels_padding: lg.Margin,
    node_label_spacing: f64,
    label_label_spacing: f64,
    label_cell_spacing: f64,
    port_port_spacing: f64,
    port_label_spacing_horizontal: f64,
    port_label_spacing_vertical: f64,
    surrounding_port_margins: lg.Margin,
    port_contexts: [5]std.ArrayList(*PortContext) = @splat(.empty),
    node_container: *Cell,
    node_container_middle_row: *Cell,
    inside_node_label_container: *Cell,
    inside_port_label_cells: [5]*Cell,
    outside_node_label_containers: [5]?*Cell = @splat(null),
    node_label_cells: [n_locations]?*Cell = @splat(null),

    pub fn init(a: std.mem.Allocator, node: *lg.LNode, env: Env) lg.Error!NodeContext {
        const p = &node.p;
        const symmetry = !p.node_size_options.asymmetrical;
        const node_container = try Cell.create(a, .{ .strip = .{ .container_mode = .vertical, .symmetrical = symmetry, .gap = 0 } });
        const middle_row = try Cell.create(a, .{ .strip = .{ .container_mode = .horizontal, .symmetrical = symmetry, .gap = 0 } });
        node_container.kind.strip.cells[1] = middle_row;
        return .{
            .a = a,
            .node = node,
            .env = env,
            .node_size = node.size,
            .size_constraints = p.node_size_constraints,
            .size_options = p.node_size_options,
            .port_constraints = p.port_constraints,
            .node_label_placement = p.node_labels_placement,
            .node_labels_padding = env.node_labels_padding,
            .node_label_spacing = env.spacing.label_node,
            .label_label_spacing = env.spacing.label_label,
            .label_cell_spacing = 2 * env.spacing.label_label,
            .port_port_spacing = env.spacing.port_port,
            .port_label_spacing_horizontal = env.spacing.label_port_horizontal,
            .port_label_spacing_vertical = env.spacing.label_port_vertical,
            .surrounding_port_margins = env.spacing.ports_surrounding,
            .node_container = node_container,
            .node_container_middle_row = middle_row,
            // SAFETY: both are assigned before any read
            .inside_node_label_container = undefined,
            // SAFETY: assigned before first use
            .inside_port_label_cells = undefined,
        };
    }

    fn portContexts(self: *NodeContext, side: lg.PortSide) []*PortContext {
        return self.port_contexts[si(side)].items;
    }

    fn insidePortLabelCell(self: *NodeContext, side: lg.PortSide) *Cell {
        return self.inside_port_label_cells[si(side)];
    }

    fn outsideNodeLabelContainer(self: *NodeContext, side: lg.PortSide) *Cell {
        return self.outside_node_label_containers[si(side)].?;
    }

    fn portAlignment(self: *const NodeContext, _: lg.PortSide) lg.PortAlignment {
        return self.node.p.port_alignment_default;
    }
};

// NodeLabelAndSizeCalculator.process(graph, node, applyStuff, ignoreInsidePortLabels). Port labels are never
// present here, so the port label cells, port margins and port label placement steps are left out.
pub fn process(a: std.mem.Allocator, node: *lg.LNode, env: Env, apply_stuff: bool) lg.Error!lg.Vec {
    var nc = try NodeContext.init(a, node, env);
    try createPortContexts(&nc);

    try createNodeLabelCells(&nc);
    try createInsidePortLabelCells(&nc);

    setupMinimumClientAreaSize(&nc);
    setupNodePaddingForPortsWithOffset(&nc);

    calculateHorizontalPortPlacementSize(&nc);
    calculateVerticalPortPlacementSize(&nc);

    configureCellSystemSizeContributions(&nc);

    setNodeWidth(&nc);
    placeHorizontalPorts(&nc);

    updateVerticalInsidePortLabelCellPadding(&nc);
    setNodeHeight(&nc);

    if (!apply_stuff) return nc.node_size;

    offsetSouthernPortsByNodeSize(&nc);
    placeVerticalPorts(&nc);

    placeLabels(&nc);
    setNodePadding(&nc);
    applyStuff(&nc);
    return nc.node_size;
}

// PortContextCreator: contexts per side, north/east by ascending and south/west by descending port index
fn createPortContexts(nc: *NodeContext) lg.Error!void {
    for (nc.node.ports.items) |port| {
        if (port.side == .undefined) continue;
        const pc = try nc.a.create(PortContext);
        pc.* = .{ .port = port, .port_position = port.pos };
        try nc.port_contexts[si(port.side)].append(nc.a, pc);
    }
    std.mem.reverse(*PortContext, nc.port_contexts[si(.south)].items);
    std.mem.reverse(*PortContext, nc.port_contexts[si(.west)].items);
}

// NodeLabelCellCreator.createNodeLabelCells(nodeContext, false, horizontalLayoutMode)
fn createNodeLabelCells(nc: *NodeContext) lg.Error!void {
    const a = nc.a;
    const symmetry = !nc.size_options.asymmetrical;
    const tabular = nc.size_options.force_tabular_node_labels;
    nc.inside_node_label_container = try Cell.create(a, .{ .grid = .{ .tabular = tabular, .symmetrical = symmetry, .gap = nc.label_cell_spacing } });
    nc.inside_node_label_container.padding = nc.node_labels_padding;
    nc.node_container_middle_row.kind.strip.cells[1] = nc.inside_node_label_container;

    const north = try Cell.create(a, .{ .strip = .{ .container_mode = .horizontal, .symmetrical = symmetry, .gap = nc.label_cell_spacing } });
    north.padding.bottom = nc.node_label_spacing;
    nc.outside_node_label_containers[si(.north)] = north;
    const south = try Cell.create(a, .{ .strip = .{ .container_mode = .horizontal, .symmetrical = symmetry, .gap = nc.label_cell_spacing } });
    south.padding.top = nc.node_label_spacing;
    nc.outside_node_label_containers[si(.south)] = south;
    const west = try Cell.create(a, .{ .strip = .{ .container_mode = .vertical, .symmetrical = symmetry, .gap = nc.label_cell_spacing } });
    west.padding.right = nc.node_label_spacing;
    nc.outside_node_label_containers[si(.west)] = west;
    const east = try Cell.create(a, .{ .strip = .{ .container_mode = .vertical, .symmetrical = symmetry, .gap = nc.label_cell_spacing } });
    east.padding.left = nc.node_label_spacing;
    nc.outside_node_label_containers[si(.east)] = east;

    // labels never carry their own nodeLabels.placement in Mermaid's graphs, so the node's applies
    for (nc.node.labels.items) |label| {
        const location = NodeLabelLocation.fromNodeLabelPlacement(nc.node_label_placement);
        if (location == .undefined) continue;
        const cell = try retrieveNodeLabelCell(nc, location);
        try cell.addLabel(a, label);
    }
}

fn retrieveNodeLabelCell(nc: *NodeContext, location: NodeLabelLocation) lg.Error!*Cell {
    if (nc.node_label_cells[@backingInt(location)]) |c| return c;
    const cell = try Cell.create(nc.a, .{ .label = .{
        .gap = nc.label_label_spacing,
        .horizontal_layout_mode = nc.env.horizontal_layout_mode,
        .horizontal_alignment = location.horizontalAlignment(),
        .vertical_alignment = location.verticalAlignment(),
    } });
    nc.node_label_cells[@backingInt(location)] = cell;
    if (location.isInsideLocation()) {
        nc.inside_node_label_container.kind.grid.cells[@backingInt(location.containerRow())][@backingInt(location.containerColumn())] = cell;
    } else {
        const outside_side = location.outsideSide();
        const container = nc.outsideNodeLabelContainer(outside_side);
        switch (outside_side) {
            .north, .south => {
                cell.contributes_to_minimum_height = true;
                container.kind.strip.cells[@backingInt(location.containerColumn())] = cell;
            },
            .west, .east => {
                cell.contributes_to_minimum_width = true;
                container.kind.strip.cells[@backingInt(location.containerRow())] = cell;
            },
            .undefined => {},
        }
    }
    return cell;
}

// InsidePortLabelCellCreator (port labels placement is OUTSIDE, so no width is reserved for inside labels)
fn createInsidePortLabelCells(nc: *NodeContext) lg.Error!void {
    const a = nc.a;
    for (sides) |s| nc.inside_port_label_cells[si(s)] = try Cell.create(a, .{ .atomic = .{} });
    nc.node_container.kind.strip.cells[0] = nc.insidePortLabelCell(.north);
    nc.node_container.kind.strip.cells[2] = nc.insidePortLabelCell(.south);
    nc.node_container_middle_row.kind.strip.cells[0] = nc.insidePortLabelCell(.west);
    nc.node_container_middle_row.kind.strip.cells[2] = nc.insidePortLabelCell(.east);

    const m = nc.surrounding_port_margins;
    const north = &nc.insidePortLabelCell(.north).padding;
    if (nc.port_label_spacing_vertical >= 0) north.top = nc.port_label_spacing_vertical;
    north.left = m.left;
    north.right = m.right;
    const south = &nc.insidePortLabelCell(.south).padding;
    if (nc.port_label_spacing_vertical >= 0) south.bottom = nc.port_label_spacing_vertical;
    south.left = m.left;
    south.right = m.right;
    for ([2]lg.PortSide{ .east, .west }) |s| {
        const pad = &nc.insidePortLabelCell(s).padding;
        pad.top = m.top;
        pad.bottom = m.bottom;
    }
}

// NodeLabelAndSizeUtilities
fn setupMinimumClientAreaSize(nc: *NodeContext) void {
    if (getMinimumClientAreaSize(nc)) |min_size| nc.inside_node_label_container.kind.grid.center_cell_minimum_size = min_size;
}

fn setupNodePaddingForPortsWithOffset(nc: *NodeContext) void {
    const pad = &nc.node_container.padding;
    for (sides) |s| {
        for (nc.portContexts(s)) |pc| {
            const offset = pc.port.p.port_border_offset;
            if (offset < 0) {
                switch (pc.port.side) {
                    .north => pad.top = util.javaMax(pad.top, -offset),
                    .south => pad.bottom = util.javaMax(pad.bottom, -offset),
                    .east => pad.right = util.javaMax(pad.right, -offset),
                    .west => pad.left = util.javaMax(pad.left, -offset),
                    .undefined => {},
                }
            }
        }
    }
}

fn offsetSouthernPortsByNodeSize(nc: *NodeContext) void {
    const node_height = nc.node_size.y;
    for (nc.portContexts(.south)) |pc| pc.port_position.y += node_height;
}

fn setNodePadding(nc: *NodeContext) void {
    if (!nc.size_options.compute_padding) return;
    const node_rect = nc.node_container.rect;
    const client_area = nc.inside_node_label_container.kind.grid.center_cell_rect;
    nc.node.padding = .{
        .left = client_area.x - node_rect.x,
        .top = client_area.y - node_rect.y,
        .right = (node_rect.x + node_rect.width) - (client_area.x + client_area.width),
        .bottom = (node_rect.y + node_rect.height) - (client_area.y + client_area.height),
    };
}

fn applyStuff(nc: *NodeContext) void {
    nc.node.size = nc.node_size;
    for (sides) |s| {
        for (nc.portContexts(s)) |pc| pc.port.pos = pc.port_position;
    }
}

fn getMinimumClientAreaSize(nc: *const NodeContext) ?lg.Vec {
    if (nc.size_constraints.minimum_size and nc.size_options.minimum_size_accounts_for_padding) return getMinimumNodeOrClientAreaSize(nc);
    return null;
}

fn getMinimumNodeSize(nc: *const NodeContext) ?lg.Vec {
    if (nc.size_constraints.minimum_size and !nc.size_options.minimum_size_accounts_for_padding) return getMinimumNodeOrClientAreaSize(nc);
    return null;
}

fn getMinimumNodeOrClientAreaSize(nc: *const NodeContext) lg.Vec {
    var min_size = nc.node.p.node_size_minimum;
    if (nc.size_options.default_minimum_size) {
        if (min_size.x <= 0) min_size.x = 20;
        if (min_size.y <= 0) min_size.y = 20;
    }
    return min_size;
}

fn areSizeConstraintsFixed(nc: *const NodeContext) bool {
    const c = nc.size_constraints;
    return @as(u4, @bitCast(c)) == 0 or @as(u4, @bitCast(c)) == @as(u4, @bitCast(lg.SizeConstraint{ .port_labels = true }));
}

// Horizontal/VerticalPortPlacementSizeCalculator; FIXED_RATIO ports never occur and take the free path
fn calculateHorizontalPortPlacementSize(nc: *NodeContext) void {
    for ([2]lg.PortSide{ .north, .south }) |s| {
        const cell = nc.insidePortLabelCell(s);
        if (nc.port_constraints == .fixed_pos) {
            var rightmost_port_border: f64 = 0.0;
            for (nc.portContexts(s)) |pc| rightmost_port_border = util.javaMax(rightmost_port_border, pc.port_position.x + pc.port.size.x);
            cell.padding.left = 0;
            cell.kind.atomic.minimum_content_area_size.x = rightmost_port_border;
            continue;
        }
        const pcs = nc.portContexts(s);
        if (pcs.len == 0) {
            cell.padding.left = 0;
            cell.padding.right = 0;
            continue;
        }
        cell.padding.left = nc.surrounding_port_margins.left;
        cell.padding.right = nc.surrounding_port_margins.right;
        var width: f64 = 0;
        for (pcs, 0..) |pc, i| {
            width += pc.port.size.x;
            if (i + 1 < pcs.len) width += nc.port_port_spacing;
        }
        if (nc.portAlignment(s) == .distributed) width += 2 * nc.port_port_spacing;
        cell.kind.atomic.minimum_content_area_size.x = width;
    }
}

fn calculateVerticalPortPlacementSize(nc: *NodeContext) void {
    for ([2]lg.PortSide{ .east, .west }) |s| {
        const cell = nc.insidePortLabelCell(s);
        if (nc.port_constraints == .fixed_pos) {
            var bottommost_port_border: f64 = 0.0;
            for (nc.portContexts(s)) |pc| bottommost_port_border = util.javaMax(bottommost_port_border, pc.port_position.y + pc.port.size.y);
            cell.padding.top = 0;
            cell.kind.atomic.minimum_content_area_size.y = bottommost_port_border;
            continue;
        }
        const pcs = nc.portContexts(s);
        if (pcs.len == 0) {
            cell.padding.top = 0;
            cell.padding.bottom = 0;
            continue;
        }
        cell.padding.top = nc.surrounding_port_margins.top;
        cell.padding.bottom = nc.surrounding_port_margins.bottom;
        var height: f64 = 0;
        for (pcs, 0..) |pc, i| {
            height += pc.port.size.y;
            if (i + 1 < pcs.len) height += nc.port_port_spacing;
        }
        if (nc.portAlignment(s) == .distributed) height += 2 * nc.port_port_spacing;
        cell.kind.atomic.minimum_content_area_size.y = height;
    }
}

// CellSystemConfigurator
fn configureCellSystemSizeContributions(nc: *NodeContext) void {
    const c = nc.size_constraints;
    if (@as(u4, @bitCast(c)) == 0) return;
    if (c.ports) {
        nc.insidePortLabelCell(.north).contributes_to_minimum_width = true;
        nc.insidePortLabelCell(.south).contributes_to_minimum_width = true;
        const free_port_placement = nc.port_constraints != .fixed_ratio and nc.port_constraints != .fixed_pos;
        nc.insidePortLabelCell(.east).contributes_to_minimum_height = free_port_placement;
        nc.insidePortLabelCell(.west).contributes_to_minimum_height = free_port_placement;
        nc.node_container_middle_row.contributes_to_minimum_height = free_port_placement;
        if (c.port_labels) {
            nc.insidePortLabelCell(.north).contributes_to_minimum_height = true;
            nc.insidePortLabelCell(.south).contributes_to_minimum_height = true;
            nc.insidePortLabelCell(.east).contributes_to_minimum_width = true;
            nc.insidePortLabelCell(.west).contributes_to_minimum_width = true;
            nc.node_container_middle_row.contributes_to_minimum_width = true;
        }
    }
    if (c.node_labels) {
        nc.inside_node_label_container.contributes_to_minimum_height = true;
        nc.inside_node_label_container.contributes_to_minimum_width = true;
        nc.node_container_middle_row.contributes_to_minimum_height = true;
        nc.node_container_middle_row.contributes_to_minimum_width = true;
        const overhang = nc.size_options.outside_node_labels_overhang;
        for (std.enums.values(NodeLabelLocation)) |location| {
            const label_cell = nc.node_label_cells[@backingInt(location)] orelse continue;
            if (location.isInsideLocation()) {
                label_cell.contributes_to_minimum_height = true;
                label_cell.contributes_to_minimum_width = true;
            } else {
                label_cell.contributes_to_minimum_height = !overhang;
                label_cell.contributes_to_minimum_width = !overhang;
            }
        }
    }
    if (c.minimum_size and nc.size_options.minimum_size_accounts_for_padding) {
        nc.node_container_middle_row.contributes_to_minimum_height = true;
        if (!nc.inside_node_label_container.contributes_to_minimum_height) {
            nc.inside_node_label_container.contributes_to_minimum_height = true;
            nc.inside_node_label_container.contributes_to_minimum_width = true;
            nc.inside_node_label_container.kind.grid.only_center_cell_contributes_to_minimum_size = true;
        }
    }
}

fn updateVerticalInsidePortLabelCellPadding(nc: *NodeContext) void {
    if (nc.port_constraints == .fixed_ratio or nc.port_constraints == .fixed_pos) return;
    const top_border_offset = nc.node_container.padding.top + nc.insidePortLabelCell(.north).getMinimumHeight() + nc.label_cell_spacing;
    const bottom_border_offset = nc.node_container.padding.bottom + nc.insidePortLabelCell(.south).getMinimumHeight() + nc.label_cell_spacing;
    const east_cell = nc.insidePortLabelCell(.east);
    const west_cell = nc.insidePortLabelCell(.west);
    var top_padding = util.javaMax(0, east_cell.padding.top - top_border_offset);
    top_padding = util.javaMax(top_padding, west_cell.padding.top - top_border_offset);
    var bottom_padding = util.javaMax(0, east_cell.padding.bottom - bottom_border_offset);
    bottom_padding = util.javaMax(bottom_padding, west_cell.padding.bottom - bottom_border_offset);
    east_cell.padding.top = top_padding;
    west_cell.padding.top = top_padding;
    east_cell.padding.bottom = bottom_padding;
    west_cell.padding.bottom = bottom_padding;
}

// NodeSizeCalculator
fn setNodeWidth(nc: *NodeContext) void {
    // SAFETY: set on every path before it is read
    var width: f64 = undefined;
    if (areSizeConstraintsFixed(nc)) {
        width = nc.node_size.x;
    } else {
        width = nc.node_container.getMinimumWidth();
        if (nc.size_constraints.node_labels and !nc.size_options.outside_node_labels_overhang) {
            width = util.javaMax(width, nc.outsideNodeLabelContainer(.north).getMinimumWidth());
            width = util.javaMax(width, nc.outsideNodeLabelContainer(.south).getMinimumWidth());
        }
        if (getMinimumNodeSize(nc)) |min_node_size| width = util.javaMax(width, min_node_size.x);
    }
    nc.node_size.x = if (nc.env.fixed_graph_size) util.javaMax(nc.node_size.x, width) else width;
    nc.node_container.rect.x = 0;
    nc.node_container.rect.width = width;
    nc.node_container.layoutChildrenHorizontally();
}

fn setNodeHeight(nc: *NodeContext) void {
    // SAFETY: set on every path before it is read
    var height: f64 = undefined;
    if (areSizeConstraintsFixed(nc)) {
        height = nc.node_size.y;
    } else {
        height = nc.node_container.getMinimumHeight();
        if (nc.size_constraints.node_labels and !nc.size_options.outside_node_labels_overhang) {
            height = util.javaMax(height, nc.outsideNodeLabelContainer(.east).getMinimumHeight());
            height = util.javaMax(height, nc.outsideNodeLabelContainer(.west).getMinimumHeight());
        }
        if (getMinimumNodeSize(nc)) |min_node_size| height = util.javaMax(height, min_node_size.y);
        if (nc.size_constraints.ports and (nc.port_constraints == .fixed_ratio or nc.port_constraints == .fixed_pos)) {
            height = util.javaMax(height, nc.insidePortLabelCell(.east).getMinimumHeight());
            height = util.javaMax(height, nc.insidePortLabelCell(.west).getMinimumHeight());
        }
    }
    nc.node_size.y = if (nc.env.fixed_graph_size) util.javaMax(nc.node_size.y, height) else height;
    nc.node_container.rect.y = 0;
    nc.node_container.rect.height = height;
    nc.node_container.layoutChildrenVertically();
}

// PortPlacementCalculator
fn placeHorizontalPorts(nc: *NodeContext) void {
    for ([2]lg.PortSide{ .north, .south }) |s| {
        if (nc.port_constraints == .fixed_pos) {
            for (nc.portContexts(s)) |pc| pc.port_position.y = horizontalPortYCoordinate(pc);
        } else {
            placeFreePorts(nc, s, true);
        }
    }
}

fn placeVerticalPorts(nc: *NodeContext) void {
    for ([2]lg.PortSide{ .east, .west }) |s| {
        if (nc.port_constraints == .fixed_pos) {
            const node_width = nc.node_size.x;
            for (nc.portContexts(s)) |pc| pc.port_position.x = verticalPortXCoordinate(pc, node_width);
        } else {
            placeFreePorts(nc, s, false);
        }
    }
}

// placeHorizontalFreePorts / placeVerticalFreePorts
fn placeFreePorts(nc: *NodeContext, side: lg.PortSide, horizontal: bool) void {
    const pcs = nc.portContexts(side);
    if (pcs.len == 0) return;
    const cell = nc.insidePortLabelCell(side);
    const r = cell.rect;
    const pad = cell.padding;
    var port_alignment = nc.portAlignment(side);
    const available_space = if (horizontal) r.width - pad.left - pad.right else r.height - pad.top - pad.bottom;
    const min_content = cell.kind.atomic.minimum_content_area_size;
    var calculated = if (horizontal) min_content.x else min_content.y;
    var current_pos = if (horizontal) r.x + pad.left else r.y + pad.top;
    var space_between_ports = nc.port_port_spacing;
    const n: f64 = @floatFromInt(pcs.len);
    if ((port_alignment == .distributed or port_alignment == .justified) and pcs.len == 1) {
        calculated = modifiedPortPlacementSize(nc, port_alignment, calculated);
        port_alignment = .center;
    }
    if (available_space < calculated and !nc.size_options.ports_overhang) {
        if (port_alignment == .distributed) {
            space_between_ports += (available_space - calculated) / (n + 1);
            current_pos += space_between_ports;
        } else {
            space_between_ports += (available_space - calculated) / (n - 1);
        }
    } else {
        if (available_space < calculated) {
            calculated = modifiedPortPlacementSize(nc, port_alignment, calculated);
            port_alignment = .center;
        }
        switch (port_alignment) {
            .begin => {},
            .center => current_pos += (available_space - calculated) / 2,
            .end => current_pos += available_space - calculated,
            .distributed => {
                const additional = (available_space - calculated) / (n + 1);
                space_between_ports += util.javaMax(0, additional);
                current_pos += space_between_ports;
            },
            .justified => {
                const additional = (available_space - calculated) / (n - 1);
                space_between_ports += util.javaMax(0, additional);
            },
        }
    }
    const node_width = nc.node_size.x;
    for (pcs) |pc| {
        if (horizontal) {
            pc.port_position.x = current_pos;
            pc.port_position.y = horizontalPortYCoordinate(pc);
            current_pos += pc.port.size.x + space_between_ports;
        } else {
            pc.port_position.x = verticalPortXCoordinate(pc, node_width);
            pc.port_position.y = current_pos;
            current_pos += pc.port.size.y + space_between_ports;
        }
    }
}

// a port without PORT_BORDER_OFFSET has the default 0, which gives the same coordinates
fn horizontalPortYCoordinate(pc: *const PortContext) f64 {
    const port = pc.port;
    return if (port.side == .north) -port.size.y - port.p.port_border_offset else port.p.port_border_offset;
}

fn verticalPortXCoordinate(pc: *const PortContext, node_width: f64) f64 {
    const port = pc.port;
    return if (port.side == .west) -port.size.x - port.p.port_border_offset else node_width + port.p.port_border_offset;
}

fn modifiedPortPlacementSize(nc: *const NodeContext, old: lg.PortAlignment, current: f64) f64 {
    return if (old == .distributed) current - 2 * nc.port_port_spacing else current;
}

// LabelPlacer (node labels only)
fn placeLabels(nc: *NodeContext) void {
    const overhang = nc.size_options.outside_node_labels_overhang;
    for ([2]lg.PortSide{ .north, .south }) |s| {
        const container = nc.outsideNodeLabelContainer(s);
        const node_size = nc.node_size;
        const r = &container.rect;
        r.width = container.getMinimumWidth();
        r.height = container.getMinimumHeight();
        r.width = util.javaMax(r.width, node_size.x);
        if (r.width > node_size.x and !overhang) r.width = node_size.x;
        r.x = -(r.width - node_size.x) / 2;
        r.y = if (s == .north) -r.height else node_size.y;
        container.layoutChildrenHorizontally();
        container.layoutChildrenVertically();
    }
    for ([2]lg.PortSide{ .east, .west }) |s| {
        const container = nc.outsideNodeLabelContainer(s);
        const node_size = nc.node_size;
        const r = &container.rect;
        r.width = container.getMinimumWidth();
        r.height = container.getMinimumHeight();
        r.height = util.javaMax(r.height, node_size.y);
        if (r.height > node_size.y and !overhang) r.height = node_size.y;
        r.y = -(r.height - node_size.y) / 2;
        r.x = if (s == .west) -r.width else node_size.x;
        container.layoutChildrenHorizontally();
        container.layoutChildrenVertically();
    }
    for (nc.node_label_cells) |cell| {
        if (cell) |c| c.applyLabelLayout();
    }
}
