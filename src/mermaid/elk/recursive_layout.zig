const std = @import("std");
const lg = @import("lgraph.zig");
const eg = @import("elk_graph.zig");
const layered = @import("layered.zig");

// RecursiveGraphLayoutEngine for graphs whose every node resolves to ELK Layered (LayoutAlgorithmResolver's
// default). Topdown layout, scale factors and inside self loops keep their off defaults and are left out.
pub fn layout(a: std.mem.Allocator, root: *eg.ElkNode) lg.Error!void {
    try layoutRecursively(a, root);
}

fn isLayered(n: *const eg.ElkNode) bool {
    const alg = n.opts.algorithm orelse return true;
    return std.mem.endsWith(u8, "org.eclipse.elk.layered", alg);
}

fn layoutRecursively(a: std.mem.Allocator, node: *eg.ElkNode) lg.Error!void {
    if (node.opts.no_layout orelse false) return;
    if (node.children.items.len == 0) return;
    if (!isLayered(node)) return error.Unsupported;
    evaluateHierarchyHandlingInheritance(node);
    if (node.hierarchyHandling() == .include_children) {
        var queue: std.ArrayList(*eg.ElkNode) = .empty;
        var head: usize = 0;
        try queue.appendSlice(a, node.children.items);
        while (head < queue.items.len) {
            const child = queue.items[head];
            head += 1;
            evaluateHierarchyHandlingInheritance(child);
            if (child.hierarchyHandling() == .separate_children or !isLayered(child)) {
                try layoutRecursively(a, child);
                child.opts.hierarchy_handling = .separate_children;
            } else {
                try queue.appendSlice(a, child.children.items);
            }
        }
    } else {
        for (node.children.items) |child| try layoutRecursively(a, child);
    }
    try layered.layoutNode(a, node);
}

fn evaluateHierarchyHandlingInheritance(n: *eg.ElkNode) void {
    if (n.hierarchyHandling() != .inherit) return;
    n.opts.hierarchy_handling = if (n.parent) |p| p.hierarchyHandling() else .separate_children;
}
