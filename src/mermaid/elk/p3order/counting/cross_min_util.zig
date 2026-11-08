const lg = @import("../../lgraph.zig");

// a port side view walked forwards or backwards (Guava Lists.reverse over LNode.getPortSideView)
pub const PortSeq = struct {
    items: []*lg.LPort,
    reversed: bool = false,

    pub fn len(self: PortSeq) usize {
        return self.items.len;
    }
    pub fn get(self: PortSeq, i: usize) *lg.LPort {
        return if (self.reversed) self.items[self.items.len - 1 - i] else self.items[i];
    }
    pub fn set(self: PortSeq, i: usize, p: *lg.LPort) void {
        if (self.reversed) self.items[self.items.len - 1 - i] = p else self.items[i] = p;
    }
};

// CrossMinUtil.inNorthSouthEastWestOrder
pub fn inNorthSouthEastWestOrder(node: *lg.LNode, side: lg.PortSide) PortSeq {
    return switch (side) {
        .east, .north => .{ .items = node.portSideView(side) },
        .south, .west => .{ .items = node.portSideView(side), .reversed = true },
        .undefined => .{ .items = node.ports.items[0..0] },
    };
}
