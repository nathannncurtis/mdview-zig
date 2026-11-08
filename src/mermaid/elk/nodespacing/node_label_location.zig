const std = @import("std");
const lg = @import("../lgraph.zig");
const cs = @import("cellsystem.zig");

const P = lg.NodeLabelPlacement;

// NodeLabelLocation; ordinal order matters (EnumMap iteration in LabelPlacer)
pub const NodeLabelLocation = enum {
    out_t_l,
    out_t_c,
    out_t_r,
    out_b_l,
    out_b_c,
    out_b_r,
    out_l_t,
    out_l_c,
    out_l_b,
    out_r_t,
    out_r_c,
    out_r_b,
    in_t_l,
    in_t_c,
    in_t_r,
    in_c_l,
    in_c_c,
    in_c_r,
    in_b_l,
    in_b_c,
    in_b_r,
    undefined,

    const Info = struct {
        h: cs.HorizontalLabelAlignment,
        v: cs.VerticalLabelAlignment,
        row: cs.ContainerArea,
        col: cs.ContainerArea,
        placements: []const P,
    };

    fn hp(p: P) P {
        var q = p;
        q.h_priority = true;
        return q;
    }

    fn info(self: NodeLabelLocation) Info {
        return switch (self) {
            .out_t_l => .{ .h = .left, .v = .bottom, .row = .begin, .col = .begin, .placements = &.{.{ .outside = true, .v_top = true, .h_left = true }} },
            .out_t_c => .{ .h = .center, .v = .bottom, .row = .begin, .col = .center, .placements = &.{ .{ .outside = true, .v_top = true, .h_center = true }, hp(.{ .outside = true, .v_top = true, .h_center = true }) } },
            .out_t_r => .{ .h = .right, .v = .bottom, .row = .begin, .col = .end, .placements = &.{.{ .outside = true, .v_top = true, .h_right = true }} },
            .out_b_l => .{ .h = .left, .v = .top, .row = .end, .col = .begin, .placements = &.{.{ .outside = true, .v_bottom = true, .h_left = true }} },
            .out_b_c => .{ .h = .center, .v = .top, .row = .end, .col = .center, .placements = &.{ .{ .outside = true, .v_bottom = true, .h_center = true }, hp(.{ .outside = true, .v_bottom = true, .h_center = true }) } },
            .out_b_r => .{ .h = .right, .v = .top, .row = .end, .col = .end, .placements = &.{.{ .outside = true, .v_bottom = true, .h_right = true }} },
            .out_l_t => .{ .h = .right, .v = .top, .row = .begin, .col = .begin, .placements = &.{hp(.{ .outside = true, .h_left = true, .v_top = true })} },
            .out_l_c => .{ .h = .right, .v = .center, .row = .center, .col = .begin, .placements = &.{ .{ .outside = true, .h_left = true, .v_center = true }, hp(.{ .outside = true, .h_left = true, .v_center = true }) } },
            .out_l_b => .{ .h = .right, .v = .bottom, .row = .end, .col = .begin, .placements = &.{hp(.{ .outside = true, .h_left = true, .v_bottom = true })} },
            .out_r_t => .{ .h = .left, .v = .top, .row = .begin, .col = .end, .placements = &.{hp(.{ .outside = true, .h_right = true, .v_top = true })} },
            .out_r_c => .{ .h = .left, .v = .center, .row = .center, .col = .end, .placements = &.{ .{ .outside = true, .h_right = true, .v_center = true }, hp(.{ .outside = true, .h_right = true, .v_center = true }) } },
            .out_r_b => .{ .h = .left, .v = .bottom, .row = .end, .col = .end, .placements = &.{hp(.{ .outside = true, .h_right = true, .v_bottom = true })} },
            .in_t_l => insideInfo(.left, .top, .begin, .begin, .{ .inside = true, .v_top = true, .h_left = true }),
            .in_t_c => insideInfo(.center, .top, .begin, .center, .{ .inside = true, .v_top = true, .h_center = true }),
            .in_t_r => insideInfo(.right, .top, .begin, .end, .{ .inside = true, .v_top = true, .h_right = true }),
            .in_c_l => insideInfo(.left, .center, .center, .begin, .{ .inside = true, .v_center = true, .h_left = true }),
            .in_c_c => insideInfo(.center, .center, .center, .center, .{ .inside = true, .v_center = true, .h_center = true }),
            .in_c_r => insideInfo(.right, .center, .center, .end, .{ .inside = true, .v_center = true, .h_right = true }),
            .in_b_l => insideInfo(.left, .bottom, .end, .begin, .{ .inside = true, .v_bottom = true, .h_left = true }),
            .in_b_c => insideInfo(.center, .bottom, .end, .center, .{ .inside = true, .v_bottom = true, .h_center = true }),
            .in_b_r => insideInfo(.right, .bottom, .end, .end, .{ .inside = true, .v_bottom = true, .h_right = true }),
            .undefined => unreachable,
        };
    }

    fn insideInfo(h: cs.HorizontalLabelAlignment, v: cs.VerticalLabelAlignment, row: cs.ContainerArea, col: cs.ContainerArea, comptime p: P) Info {
        return .{ .h = h, .v = v, .row = row, .col = col, .placements = &.{ p, comptime hp(p) } };
    }

    pub fn fromNodeLabelPlacement(placement: P) NodeLabelLocation {
        const want: u9 = @bitCast(placement);
        for (std.enums.values(NodeLabelLocation)) |loc| {
            if (loc == .undefined) break;
            for (loc.info().placements) |p| {
                if (@as(u9, @bitCast(p)) == want) return loc;
            }
        }
        return .undefined;
    }

    pub fn horizontalAlignment(self: NodeLabelLocation) cs.HorizontalLabelAlignment {
        return self.info().h;
    }
    pub fn verticalAlignment(self: NodeLabelLocation) cs.VerticalLabelAlignment {
        return self.info().v;
    }
    pub fn containerRow(self: NodeLabelLocation) cs.ContainerArea {
        return self.info().row;
    }
    pub fn containerColumn(self: NodeLabelLocation) cs.ContainerArea {
        return self.info().col;
    }

    pub fn isInsideLocation(self: NodeLabelLocation) bool {
        return @backingInt(self) >= @backingInt(NodeLabelLocation.in_t_l) and self != .undefined;
    }

    pub fn outsideSide(self: NodeLabelLocation) lg.PortSide {
        return switch (self) {
            .out_t_l, .out_t_c, .out_t_r => .north,
            .out_b_l, .out_b_c, .out_b_r => .south,
            .out_l_t, .out_l_c, .out_l_b => .west,
            .out_r_t, .out_r_c, .out_r_b => .east,
            else => .undefined,
        };
    }
};

test "transposed subgraph placement maps to IN_C_L" {
    try std.testing.expectEqual(NodeLabelLocation.in_t_c, NodeLabelLocation.fromNodeLabelPlacement(.{ .h_center = true, .v_top = true, .inside = true }));
    try std.testing.expectEqual(NodeLabelLocation.in_c_l, NodeLabelLocation.fromNodeLabelPlacement(.{ .inside = true, .h_priority = true, .v_center = true, .h_left = true }));
    try std.testing.expectEqual(NodeLabelLocation.undefined, NodeLabelLocation.fromNodeLabelPlacement(.{}));
}
