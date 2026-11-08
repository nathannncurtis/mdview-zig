const lg = @import("../lgraph.zig");
const util = @import("../util.zig");
const Rect = @import("cellsystem.zig").Rect;

// NodeMarginCalculator.processNode with excludeEdgeHeadTailLabels(), the only configuration layered uses
pub fn processNode(node: *lg.LNode) void {
    var bounding_box: Rect = .{ .x = node.pos.x, .y = node.pos.y, .width = node.size.x, .height = node.size.y };
    for (node.labels.items) |label| {
        bounding_box.unionWith(.{ .x = label.pos.x + node.pos.x, .y = label.pos.y + node.pos.y, .width = label.size.x, .height = label.size.y });
    }
    for (node.ports.items) |port| {
        const port_x = port.pos.x + node.pos.x;
        const port_y = port.pos.y + node.pos.y;
        bounding_box.unionWith(.{ .x = port_x, .y = port_y, .width = port.size.x, .height = port.size.y });
        for (port.labels.items) |label| {
            bounding_box.unionWith(.{ .x = label.pos.x + port_x, .y = label.pos.y + port_y, .width = label.size.x, .height = label.size.y });
        }
    }
    node.margin = .{
        .top = util.javaMax(0, node.pos.y - bounding_box.y),
        .bottom = util.javaMax(0, bounding_box.y + bounding_box.height - (node.pos.y + node.size.y)),
        .left = util.javaMax(0, node.pos.x - bounding_box.x),
        .right = util.javaMax(0, bounding_box.x + bounding_box.width - (node.pos.x + node.size.x)),
    };
}
