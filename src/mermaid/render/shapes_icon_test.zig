const std = @import("std");
const model = @import("model.zig");
const shapes = @import("shapes.zig");
const dom = @import("dom.zig");

const widths = [_]struct { []const u8, f64 }{
    .{ "x", 8.015625 },
    .{ "Notifications", 91.21875 },
    .{ "plain icon", 69.984375 },
    .{ "pic", 21.40625 },
    .{ "top label", 64.15625 },
};

fn measure(_: ?*anyopaque, text: []const u8, _: model.Font) f64 {
    for (widths) |e| if (std.mem.eql(u8, e[0], text)) return e[1];
    return 0;
}

fn natural(_: []const u8) model.ImageProbe {
    return .{ .size = .{ .w = 40, .h = 20 } };
}

fn failing(_: []const u8) model.ImageProbe {
    return .failed;
}

fn size(arena: *std.heap.ArenaAllocator, node: model.NodeData) ![2]f64 {
    const cfg = model.testConfig(arena.allocator());
    var dummy: u8 = 0;
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = model.widthMeasurer(&dummy, measure), .cfg = &cfg, .diagram_id = "t", .image_probe = natural };
    const root = try dom.El.create(ctx.a, "g");
    var n = node;
    n.padding = 15;
    n.min_width = 120;
    _ = try shapes.insert(&ctx, root, &n, .{});
    return .{ n.width, n.height };
}

fn expectSize(node: model.NodeData, w: f64, h: f64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try size(&arena, node);
    try std.testing.expectApproxEqAbs(w, s[0], 0.1);
    try std.testing.expectApproxEqAbs(h, s[1], 0.1);
}

test "icon shapes match mermaid node sizes" {
    try expectSize(.{ .id = "A", .shape = "iconSquare", .icon = "fa:bell", .label = "x", .pos = 'b' }, 63, 99);
    try expectSize(.{ .id = "A", .shape = "iconCircle", .icon = "fa:bell", .label = "Notifications", .pos = 't' }, 107.93993377685547, 143.8822479248047);
    try expectSize(.{ .id = "A", .shape = "iconRounded", .icon = "fa:bell", .label = "x" }, 63, 99);
    try expectSize(.{ .id = "A", .shape = "icon", .icon = "fa:bell", .label = "plain icon" }, 73.984375, 84);
    try expectSize(.{ .id = "A", .shape = "iconSquare", .icon = "fa:bell" }, 63, 63);
    try expectSize(.{ .id = "A", .shape = "iconSquare", .icon = "fa:bell", .label = "x", .asset_height = 80 }, 95, 131);
}

test "image shapes match mermaid node sizes" {
    const u = "data:x";
    try expectSize(.{ .id = "A", .shape = "imageSquare", .img = u, .label = "pic", .pos = 'b', .asset_width = 100, .asset_height = 60 }, 120, 96);
    try expectSize(.{ .id = "A", .shape = "imageSquare", .img = u, .label = "pic", .asset_width = 100, .asset_height = 60, .constraint = "on" }, 120, 96);
    try expectSize(.{ .id = "A", .shape = "imageSquare", .img = u, .label = "pic" }, 120, 56);
    try expectSize(.{ .id = "A", .shape = "imageSquare", .img = u, .label = "top label", .pos = 't', .asset_height = 90, .constraint = "on" }, 180, 126);
    try expectSize(.{ .id = "A", .shape = "imageSquare", .img = u }, 40, 20);
    try expectSize(.{ .id = "A", .shape = "imageSquare", .img = u, .label = "pic", .constraint = "on" }, 120, 96);
}

test "an image shape fails when the probe fails or is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = model.testConfig(arena.allocator());
    var dummy: u8 = 0;
    const probes = [_]?*const fn ([]const u8) model.ImageProbe{ failing, null };
    for (probes) |p| {
        const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = model.widthMeasurer(&dummy, measure), .cfg = &cfg, .diagram_id = "t", .image_probe = p };
        const root = try dom.El.create(ctx.a, "g");
        var n: model.NodeData = .{ .id = "A", .shape = "imageSquare", .img = "x.png" };
        try std.testing.expectError(error.ImageDecode, shapes.insert(&ctx, root, &n, .{}));
    }
}
