const std = @import("std");
const lg = @import("../../lgraph.zig");
const BKAlignedLayout = @import("bk_aligned_layout.zig").BKAlignedLayout;
const NeighborhoodInformation = @import("neighborhood_information.zig").NeighborhoodInformation;

const threshold = std.math.floatMax(f64);

fn ix(n: *const lg.LNode) usize {
    return @intCast(n.id);
}

const Postprocessable = struct {
    free: *lg.LNode,
    is_root: bool,
    has_edges: bool = false,
    edge: ?*lg.LEdge = null,
};

// ThresholdStrategy with its two subclasses: SimpleThresholdStrategy for IMPROVE_STRAIGHTNESS (the default),
// NullThresholdStrategy otherwise.
pub const ThresholdStrategy = struct {
    a: std.mem.Allocator,
    simple: bool,
    bal: *BKAlignedLayout,
    ni: *const NeighborhoodInformation,
    block_finished: []bool = &.{},
    queue: std.ArrayList(*Postprocessable) = .empty,
    queue_head: usize = 0,
    stack: std.ArrayList(*Postprocessable) = .empty,

    pub fn init(self: *ThresholdStrategy, bal: *BKAlignedLayout, ni: *const NeighborhoodInformation) lg.Error!void {
        self.bal = bal;
        self.ni = ni;
        self.block_finished = try self.a.alloc(bool, ni.node_count);
        @memset(self.block_finished, false);
        self.queue.clearRetainingCapacity();
        self.queue_head = 0;
        self.stack.clearRetainingCapacity();
    }

    pub fn finishBlock(self: *ThresholdStrategy, n: *const lg.LNode) void {
        self.block_finished[ix(n)] = true;
    }

    pub fn calculateThreshold(self: *ThresholdStrategy, old_thresh: f64, block_root: *lg.LNode, current_node: *lg.LNode) lg.Error!f64 {
        const bal = self.bal;
        if (!self.simple) return if (bal.vdir == .up) std.math.inf(f64) else -std.math.inf(f64);
        const is_root = block_root == current_node;
        const is_last = bal.align_[ix(current_node)] == block_root;
        if (!(is_root or is_last)) return old_thresh;
        var t = old_thresh;
        if (is_root) t = try self.getBound(block_root, true);
        if (std.math.isInf(t) and is_last) t = try self.getBound(current_node, false);
        return t;
    }

    fn getOther(edge: *const lg.LEdge, n: *const lg.LNode) *lg.LNode {
        if (edge.source.?.owner.? == n) return edge.target.?.owner.?;
        return edge.source.?.owner.?;
    }

    fn pickEdge(self: *ThresholdStrategy, pp: *Postprocessable) *Postprocessable {
        const bal = self.bal;
        const incoming = if (pp.is_root) bal.hdir == .right else bal.hdir == .left;
        var has_edges = false;
        for (pp.free.ports.items) |port| {
            const edges = if (incoming) port.incoming.items else port.outgoing.items;
            for (edges) |e| {
                const root_id = ix(bal.root[ix(pp.free)]);
                const only_dummies = bal.od[root_id];
                if (!only_dummies and e.isInLayerEdge()) continue;
                if (bal.su[root_id]) continue;
                has_edges = true;
                if (self.block_finished[ix(bal.root[ix(getOther(e, pp.free))])]) {
                    pp.has_edges = true;
                    pp.edge = e;
                    return pp;
                }
            }
        }
        pp.has_edges = has_edges;
        pp.edge = null;
        return pp;
    }

    fn getBound(self: *ThresholdStrategy, block_node: *lg.LNode, is_root: bool) lg.Error!f64 {
        const bal = self.bal;
        const invalid = if (bal.vdir == .up) std.math.inf(f64) else -std.math.inf(f64);
        const pp = try self.a.create(Postprocessable);
        pp.* = .{ .free = block_node, .is_root = is_root };
        const pick = self.pickEdge(pp);
        if (pick.edge == null and pick.has_edges) {
            try self.queue.append(self.a, pick);
            return invalid;
        } else if (pick.edge) |edge| {
            const left = edge.source.?;
            const right = edge.target.?;
            const root_port = if (is_root) (if (bal.hdir == .right) right else left) else (if (bal.hdir == .left) right else left);
            const other_port = if (is_root) (if (bal.hdir == .right) left else right) else (if (bal.hdir == .left) left else right);
            const other_root = bal.root[ix(other_port.owner.?)];
            const result = bal.y[ix(other_root)].? + bal.inner_shift[ix(other_port.owner.?)] + other_port.pos.y + other_port.anchor.y -
                bal.inner_shift[ix(root_port.owner.?)] - root_port.pos.y - root_port.anchor.y;
            bal.su[ix(bal.root[ix(left.owner.?)])] = true;
            bal.su[ix(bal.root[ix(right.owner.?)])] = true;
            return result;
        }
        return invalid;
    }

    pub fn postProcess(self: *ThresholdStrategy) lg.Error!void {
        if (!self.simple) return;
        const bal = self.bal;
        while (self.queue_head < self.queue.items.len) {
            const pp = self.queue.items[self.queue_head];
            self.queue_head += 1;
            const pick = self.pickEdge(pp);
            const edge = pick.edge orelse continue;
            const only_dummies = bal.od[ix(bal.root[ix(pp.free)])];
            if (!only_dummies and edge.isInLayerEdge()) continue;
            if (!self.process(pp)) try self.stack.append(self.a, pp);
        }
        while (self.stack.pop()) |pp| _ = self.process(pp);
    }

    fn process(self: *ThresholdStrategy, pp: *const Postprocessable) bool {
        const bal = self.bal;
        const edge = pp.edge.?;
        const fix = if (edge.source.?.owner.? == pp.free) edge.target.? else edge.source.?;
        const block = if (edge.source.?.owner.? == pp.free) edge.source.? else edge.target.?;
        const delta = bal.calculateDelta(fix, block);
        if (delta > 0 and delta < threshold) {
            const available_space = bal.checkSpaceAbove(block.owner.?, delta, self.ni);
            bal.shiftBlock(block.owner.?, -available_space);
            return available_space > 0;
        } else if (delta < 0 and -delta < threshold) {
            const available_space = bal.checkSpaceBelow(block.owner.?, -delta, self.ni);
            bal.shiftBlock(block.owner.?, available_space);
            return available_space > 0;
        }
        return false;
    }
};
