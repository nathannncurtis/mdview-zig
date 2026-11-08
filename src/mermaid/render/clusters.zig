const std = @import("std");
const model = @import("model.zig");
const labels = @import("labels.zig");
const util = @import("shapes/util.zig");
const dom = @import("dom.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;
const NodeData = model.NodeData;

pub const Cluster = struct { el: *El, label_bbox: model.Box };

pub const Registry = struct {
    map: std.StringHashMapUnmanaged(Cluster) = .empty,

    pub fn get(self: *const Registry, id: []const u8) ?Cluster {
        return self.map.get(id);
    }
};

pub fn intersectRect(node: *const NodeData, p: model.Point) model.Point {
    const dx = p.x - node.x;
    const dy = p.y - node.y;
    var w = node.width / 2;
    var h = node.height / 2;
    var sx: f64 = 0;
    var sy: f64 = 0;
    if (@abs(dy) * w > @abs(dx) * h) {
        if (dy < 0) h = -h;
        sx = if (dy == 0) 0 else (h * dx) / dy;
        sy = h;
    } else {
        if (dx < 0) w = -w;
        sx = w;
        sy = if (dx == 0) 0 else (w * dy) / dx;
    }
    return .{ .x = node.x + sx, .y = node.y + sy };
}

fn rectCluster(ctx: *const model.Ctx, parent: *El, node: *NodeData) !Cluster {
    const a = ctx.a;
    const st = try util.styles2String(a, node);
    const g = try parent.insert("g");
    try g.setAttr("class", try std.fmt.allocPrint(a, "cluster {s}", .{node.css_classes}));
    if (node.dom_id) |d| try g.setAttr("id", d);
    try g.setAttr("data-look", node.look);

    const label_el = try g.insert("g");
    try label_el.setAttr("class", "cluster-label ");
    const text = node.label orelse "";
    const lbl = if (std.mem.eql(u8, node.label_type, "markdown")) blk: {
        break :blk try labels.createText(ctx, label_el, text, .{ .style = node.label_style, .is_node = true, .width = node.width, .center = false, .label_type = "markdown" });
    } else blk: {
        const l = try labels.createLabel(ctx, text, node.label_style, true, false);
        try label_el.append(l);
        break :blk l;
    };
    const bbox = lbl.box orelse model.Box{ .x = 0, .y = 0, .w = 0, .h = 0 };

    const padding = node.padding orelse 0;
    const width = if (node.width <= bbox.w + padding) bbox.w + padding else node.width;
    node.diff = if (node.width <= bbox.w + padding) (width - node.width) / 2 - padding else -padding;

    const height = node.height;
    const x = node.x - width / 2;
    const y = node.y - height / 2;

    const r = try g.insertFirst("rect");
    try r.setAttr("style", st.node);
    if (node.rx) |rx| _ = try r.attrNum("rx", rx);
    if (node.ry) |ry| _ = try r.attrNum("ry", ry);
    _ = try r.attrNum("x", x);
    _ = try r.attrNum("y", y);
    _ = try r.attrNum("width", width);
    _ = try r.attrNum("height", height);

    const top = ctx.cfg.sub_graph_title_margin.top;
    try label_el.setAttr("transform", try std.fmt.allocPrint(a, "translate({s}, {s})", .{
        try dom.fmtNum(a, node.x - bbox.w / 2),
        try dom.fmtNum(a, node.y - node.height / 2 + top + lbl.y_off),
    }));

    if (st.label.len > 0) for (lbl.kids.items) |k| if (std.mem.eql(u8, k.tag, "text")) try k.setAttr("style", st.label);

    const rb = r.bbox().?;
    node.width = rb.w;
    node.height = rb.h;
    node.offset_y = bbox.h - padding / 2;
    node.intersect = .rect;
    return .{ .el = g, .label_bbox = bbox };
}

pub fn insertCluster(ctx: *const model.Ctx, reg: *Registry, parent: *El, node: *NodeData) !Cluster {
    const c = try rectCluster(ctx, parent, node);
    try reg.map.put(ctx.a, node.id, c);
    return c;
}

pub fn positionCluster(a: Allocator, reg: *const Registry, node: *const NodeData) !void {
    const c = reg.get(node.id) orelse return;
    try c.el.setAttr("transform", try std.fmt.allocPrint(a, "translate({s}, {s})", .{ try dom.fmtNum(a, node.x), try dom.fmtNum(a, node.y) }));
}

test "cluster rect grows to fit its title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var dummy: u8 = 0;
    const fake = struct {
        fn w(_: *anyopaque, t: []const u8, _: model.FontSpec) f64 {
            return 10 * @as(f64, @floatFromInt(t.len));
        }
    };
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = fake.w }, .cfg = &cfg, .diagram_id = "t" };
    var reg: Registry = .{};
    const root = try El.create(ctx.a, "g");
    var n: NodeData = .{ .id = "sg", .label = "Long title here", .is_group = true, .padding = 8, .width = 50, .height = 40 };
    _ = try insertCluster(&ctx, &reg, root, &n);
    try std.testing.expectEqual(@as(f64, 15 * 10 + 8), n.width);
    try std.testing.expectEqual(@as(f64, 40), n.height);
}
