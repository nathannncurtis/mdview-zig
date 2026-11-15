// LongestPathLayerer. Writes LNode.id, layers.
const lg = @import("../lgraph.zig");

const State = struct {
    g: *lg.LGraph,
    heights: []i32,

    fn visit(self: *State, node: *lg.LNode) lg.Error!i32 {
        const height = self.heights[@intCast(node.id)];
        if (height >= 0) return height;
        var max_height: i32 = 1;
        for (node.ports.items) |port| {
            for (port.outgoing.items) |edge| {
                const target = edge.target.?.owner.?;
                if (node != target) {
                    const target_height = try self.visit(target);
                    max_height = @max(max_height, target_height + 1);
                }
            }
        }
        try self.putNode(node, max_height);
        return max_height;
    }

    fn putNode(self: *State, node: *lg.LNode, height: i32) lg.Error!void {
        const h: usize = @intCast(height);
        const layers = &self.g.layers;
        var i = layers.items.len;
        while (i < h) : (i += 1) try layers.insert(self.g.a, 0, try self.g.newLayer());
        try node.setLayer(layers.items[layers.items.len - h]);
        self.heights[@intCast(node.id)] = height;
    }
};

pub fn process(g: *lg.LGraph) lg.Error!void {
    const nodes = g.layerless_nodes.items;
    var st: State = .{ .g = g, .heights = try g.a.alloc(i32, nodes.len) };
    for (nodes, 0..) |node, i| {
        node.id = @intCast(i);
        st.heights[i] = -1;
    }
    for (nodes) |node| _ = try st.visit(node);
    g.layerless_nodes.clearRetainingCapacity();
}
