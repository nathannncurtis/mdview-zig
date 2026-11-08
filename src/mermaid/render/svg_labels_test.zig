const std = @import("std");
const model = @import("model.zig");
const flowchart = @import("../flowchart/flowchart.zig");

const table = [_]struct { []const u8, f64 }{
    .{ "Hello", 37.6328125 },
    .{ "Two words here", 113.0078125 },
    .{ "edge lab", 61.3515625 },
    .{ "Line one", 62.2109375 },
    .{ "Line two", 62.2109375 },
    .{ "x", 10 },
};

fn width(_: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
    for (table) |e| if (std.mem.eql(u8, e[0], text)) return e[1];
    return 0;
}

fn render(arena: *std.heap.ArenaAllocator, src: []const u8) ![]const u8 {
    const cfg = try arena.allocator().create(model.Config);
    cfg.* = .{};
    cfg.diagram_padding = 48;
    cfg.html_labels = false;
    cfg.node_html_labels = false;
    var dummy: u8 = 0;
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = width }, .cfg = cfg, .diagram_id = "diagram" };
    const r = try flowchart.renderSource(&ctx, std.testing.allocator, src, .{});
    return r.ok.svg;
}

fn after(svg: []const u8, marker: []const u8, attr: []const u8) !f64 {
    const at = std.mem.indexOf(u8, svg, marker) orelse return error.NotFound;
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{s}=\"", .{attr});
    const k = std.mem.indexOfPos(u8, svg, at, key) orelse return error.NotFound;
    const end = std.mem.indexOfScalarPos(u8, svg, k + key.len, '"') orelse return error.NotFound;
    return std.fmt.parseFloat(f64, svg[k + key.len .. end]);
}

// Expected numbers come from mermaid 12.2.0 rendered in Chromium with {"htmlLabels": false}.
test "svg labels size nodes from the text bbox: text bbox plus the 120px minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const svg = try render(&arena, "flowchart TD\n  A[Hello] -->|edge lab| B[Two words here]\n\n");
    try std.testing.expectApproxEqAbs(@as(f64, 152), try after(svg, "id=\"diagram-flowchart-A-0\"", "width"), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 43), try after(svg, "id=\"diagram-flowchart-A-0\"", "height"), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 152), try after(svg, "id=\"diagram-flowchart-B-1\"", "width"), 1e-6);
}

test "svg labels with br use 1.1em line pitch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const svg = try render(&arena, "flowchart TD\n  A[Line one<br/>Line two] --> B[x]\n\n");
    try std.testing.expectApproxEqAbs(@as(f64, 152), try after(svg, "id=\"diagram-flowchart-A-0\"", "width"), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 60.6), try after(svg, "id=\"diagram-flowchart-A-0\"", "height"), 1e-4);
}
