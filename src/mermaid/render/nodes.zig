const std = @import("std");
const model = @import("model.zig");
const dom = @import("dom.zig");
const shapes = @import("shapes.zig");
const util = @import("shapes/util.zig");
const El = dom.El;

pub const Error = shapes.Error;

pub fn insertNode(ctx: *const model.Ctx, parent: *El, node: *model.NodeData, opts: shapes.Opts) Error!*El {
    return shapes.insert(ctx, parent, node, opts);
}

pub fn setNodeElem(el: *El, node: *model.NodeData) void {
    node.el = el;
}

pub fn clear() void {}

pub fn positionNode(ctx: *const model.Ctx, node: *model.NodeData) !f64 {
    const el = node.el.?;
    const diff = node.diff;
    if (node.cluster_node) {
        try el.setAttr("transform", try std.fmt.allocPrint(ctx.a, "translate({s}, {s})", .{
            try dom.fmtNum(ctx.a, node.x + diff - node.width / 2),
            try dom.fmtNum(ctx.a, node.y - node.height / 2 - 8),
        }));
    } else {
        try el.setAttr("transform", try util.translate(ctx.a, node.x, node.y));
    }
    return diff;
}
