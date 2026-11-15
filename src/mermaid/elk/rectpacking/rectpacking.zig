const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");

pub fn layout(a: std.mem.Allocator, node: *eg.ElkNode) lg.Error!void {
    _ = a;
    _ = node;
    return error.Unsupported;
}
