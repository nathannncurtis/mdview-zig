const std = @import("std");
const lg = @import("lgraph.zig");
const eg = @import("elk_graph.zig");
const layered = @import("layered.zig");
const stress = @import("stress/stress.zig");
const force = @import("force/force.zig");
const mrtree = @import("mrtree/mrtree.zig");
const spore = @import("spore/spore.zig");
const box = @import("box/box.zig");
const rectpacking = @import("rectpacking/rectpacking.zig");
const radial = @import("radial/radial.zig");

const Algo = enum { layered, stress, force, mrtree, sporeOverlap, box, rectpacking, radial };

fn algoOf(n: *const eg.ElkNode) ?Algo {
    const alg = n.opts.algorithm orelse return .layered;
    const prefixes = [_][]const u8{ "org.eclipse.elk.", "elk.", "" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, alg, p)) if (std.meta.stringToEnum(Algo, alg[p.len..])) |v| return v;
    }
    return null;
}

// RecursiveGraphLayoutEngine for graphs whose every node resolves to ELK Layered (LayoutAlgorithmResolver's
// default). Topdown layout, scale factors and inside self loops keep their off defaults and are left out.
pub fn layout(a: std.mem.Allocator, root: *eg.ElkNode) lg.Error!void {
    try layoutRecursively(a, root);
}

fn isLayered(n: *const eg.ElkNode) bool {
    return algoOf(n) == .layered;
}

fn layoutRecursively(a: std.mem.Allocator, node: *eg.ElkNode) lg.Error!void {
    if (node.opts.no_layout orelse false) return;
    if (node.children.items.len == 0) return;
    const algo = algoOf(node) orelse return error.Unsupported;
    if (algo != .layered) {
        for (node.children.items) |child| try layoutRecursively(a, child);
        return switch (algo) {
            .layered => unreachable,
            .stress => stress.layout(a, node),
            .force => force.layout(a, node),
            .mrtree => mrtree.layout(a, node),
            .sporeOverlap => spore.layout(a, node),
            .box => box.layout(a, node),
            .rectpacking => rectpacking.layout(a, node),
            .radial => radial.layout(a, node),
        };
    }
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
