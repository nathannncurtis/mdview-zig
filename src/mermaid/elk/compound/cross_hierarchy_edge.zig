const std = @import("std");
const lg = @import("../lgraph.zig");

// CrossHierarchyEdge
pub const CrossHierarchyEdge = struct {
    edge: *lg.LEdge,
    graph: *lg.LGraph,
    type: lg.PortType,

    pub fn actualSource(c: CrossHierarchyEdge) *lg.LPort {
        const n = c.edge.source.?.owner.?;
        if (n.type == .external_port) return n.p.origin.port;
        return c.edge.source.?;
    }

    pub fn actualTarget(c: CrossHierarchyEdge) *lg.LPort {
        const n = c.edge.target.?.owner.?;
        if (n.type == .external_port) return n.p.origin.port;
        return c.edge.target.?;
    }
};

// InternalProperties.CROSS_HIERARCHY_MAP: original edge -> its segments. Java's HashMultimap order is identity
// hash order; insertion order is used here (nothing downstream depends on it).
pub const CrossHierarchyMap = struct {
    keys: std.ArrayList(*lg.LEdge) = .empty,
    values: std.ArrayList(std.ArrayList(CrossHierarchyEdge)) = .empty,

    pub fn put(m: *CrossHierarchyMap, a: std.mem.Allocator, key: *lg.LEdge, v: CrossHierarchyEdge) lg.Error!void {
        for (m.keys.items, 0..) |k, i| if (k == key) {
            try m.values.items[i].append(a, v);
            return;
        };
        try m.keys.append(a, key);
        var list: std.ArrayList(CrossHierarchyEdge) = .empty;
        try list.append(a, v);
        try m.values.append(a, list);
    }
};

fn hierarchyLevel(nested: *const lg.LGraph, top: *const lg.LGraph) i32 {
    var cur = nested;
    var level: i32 = 0;
    while (cur != top) {
        cur = cur.parent_node.?.graph.?;
        level += 1;
    }
    return level;
}

// CrossHierarchyEdgeComparator
pub fn compare(top: *const lg.LGraph, e1: CrossHierarchyEdge, e2: CrossHierarchyEdge) i32 {
    if (e1.type == .output and e2.type == .input) return -1;
    if (e1.type == .input and e2.type == .output) return 1;
    const l1 = hierarchyLevel(e1.graph, top);
    const l2 = hierarchyLevel(e2.graph, top);
    return if (e1.type == .output) l2 - l1 else l1 - l2;
}

// Collections.sort with the comparator (stable)
pub fn sortSegments(top: *const lg.LGraph, items: []CrossHierarchyEdge) void {
    std.mem.sort(CrossHierarchyEdge, items, top, struct {
        fn lt(t: *const lg.LGraph, a: CrossHierarchyEdge, b: CrossHierarchyEdge) bool {
            return compare(t, a, b) < 0;
        }
    }.lt);
}
