const std = @import("std");
const lg = @import("../../lgraph.zig");
const util = @import("../../util.zig");
const spacings = @import("../../spacings.zig");
const NeighborhoodInformation = @import("neighborhood_information.zig").NeighborhoodInformation;

pub const VDirection = enum { down, up };
pub const HDirection = enum { right, left };

// BKAlignedLayout: one of the four candidate layouts (or the balanced one, which has no directions)
pub const BKAlignedLayout = struct {
    root: []*lg.LNode,
    block_size: []f64,
    align_: []*lg.LNode,
    inner_shift: []f64,
    sink: []*lg.LNode,
    shift: []f64,
    y: []?f64,
    vdir: ?VDirection,
    hdir: ?HDirection,
    su: []bool,
    od: []bool,
    layered_graph: *lg.LGraph,

    pub fn init(a: std.mem.Allocator, layered_graph: *lg.LGraph, node_count: usize, vdir: ?VDirection, hdir: ?HDirection) lg.Error!*BKAlignedLayout {
        const bal = try a.create(BKAlignedLayout);
        bal.* = .{
            .root = try a.alloc(*lg.LNode, node_count),
            .block_size = try a.alloc(f64, node_count),
            .align_ = try a.alloc(*lg.LNode, node_count),
            .inner_shift = try a.alloc(f64, node_count),
            .sink = try a.alloc(*lg.LNode, node_count),
            .shift = try a.alloc(f64, node_count),
            .y = try a.alloc(?f64, node_count),
            .vdir = vdir,
            .hdir = hdir,
            .su = try a.alloc(bool, node_count),
            .od = try a.alloc(bool, node_count),
            .layered_graph = layered_graph,
        };
        @memset(bal.y, null);
        @memset(bal.su, false);
        @memset(bal.od, true);
        @memset(bal.inner_shift, 0);
        @memset(bal.block_size, 0);
        @memset(bal.shift, 0);
        return bal;
    }

    fn ix(n: *const lg.LNode) usize {
        return @intCast(n.id);
    }

    pub fn layoutSize(bal: *const BKAlignedLayout) f64 {
        var min = std.math.inf(f64);
        var max = -std.math.inf(f64);
        for (bal.layered_graph.layers.items) |layer| {
            for (layer.nodes.items) |n| {
                const y_min = bal.y[ix(n)].?;
                const y_max = y_min + bal.block_size[ix(bal.root[ix(n)])];
                min = util.javaMin(min, y_min);
                max = util.javaMax(max, y_max);
            }
        }
        return max - min;
    }

    pub fn calculateDelta(bal: *const BKAlignedLayout, src: *const lg.LPort, tgt: *const lg.LPort) f64 {
        const sn = src.owner.?;
        const tn = tgt.owner.?;
        const src_pos = bal.y[ix(sn)].? + bal.inner_shift[ix(sn)] + src.pos.y + src.anchor.y;
        const tgt_pos = bal.y[ix(tn)].? + bal.inner_shift[ix(tn)] + tgt.pos.y + tgt.anchor.y;
        return tgt_pos - src_pos;
    }

    pub fn shiftBlock(bal: *BKAlignedLayout, root_node: *lg.LNode, delta: f64) void {
        var current = root_node;
        while (true) {
            bal.y[ix(current)] = bal.y[ix(current)].? + delta;
            current = bal.align_[ix(current)];
            if (current == root_node) break;
        }
    }

    pub fn checkSpaceAbove(bal: *const BKAlignedLayout, block_root: *lg.LNode, delta: f64, ni: *const NeighborhoodInformation) f64 {
        var available_space = delta;
        var current = block_root;
        while (true) {
            current = bal.align_[ix(current)];
            const min_y_current = bal.getMinY(current);
            if (upperNeighbor(current, ni)) |neighbor| {
                const max_y_neighbor = bal.getMaxY(neighbor);
                available_space = util.javaMin(available_space, min_y_current - (max_y_neighbor + spacings.getVerticalSpacing(current, neighbor)));
            }
            if (block_root == current) break;
        }
        return available_space;
    }

    pub fn checkSpaceBelow(bal: *const BKAlignedLayout, block_root: *lg.LNode, delta: f64, ni: *const NeighborhoodInformation) f64 {
        var available_space = delta;
        var current = block_root;
        while (true) {
            current = bal.align_[ix(current)];
            const max_y_current = bal.getMaxY(current);
            if (lowerNeighbor(current, ni)) |neighbor| {
                const min_y_neighbor = bal.getMinY(neighbor);
                available_space = util.javaMin(available_space, min_y_neighbor - (max_y_current + spacings.getVerticalSpacing(current, neighbor)));
            }
            if (block_root == current) break;
        }
        return available_space;
    }

    pub fn getMinY(bal: *const BKAlignedLayout, n: *const lg.LNode) f64 {
        const root_node = bal.root[ix(n)];
        return bal.y[ix(root_node)].? + bal.inner_shift[ix(n)] - n.margin.top;
    }

    pub fn getMaxY(bal: *const BKAlignedLayout, n: *const lg.LNode) f64 {
        const root_node = bal.root[ix(n)];
        return bal.y[ix(root_node)].? + bal.inner_shift[ix(n)] + n.size.y + n.margin.bottom;
    }

    fn lowerNeighbor(n: *const lg.LNode, ni: *const NeighborhoodInformation) ?*lg.LNode {
        const l = n.layer.?;
        const layer_index = ni.nodeIndex(n);
        if (layer_index + 1 < l.nodes.items.len) return l.nodes.items[layer_index + 1];
        return null;
    }

    fn upperNeighbor(n: *const lg.LNode, ni: *const NeighborhoodInformation) ?*lg.LNode {
        const l = n.layer.?;
        const layer_index = ni.nodeIndex(n);
        if (layer_index > 0) return l.nodes.items[layer_index - 1];
        return null;
    }
};
