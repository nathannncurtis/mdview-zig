const std = @import("std");
const model = @import("model.zig");
const flowchart = @import("../flowchart/flowchart.zig");

const Entry = struct { []const u8, f64 };
const Node = struct { []const u8, f64, f64 };

fn width(ctx: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
    const table: *const []const Entry = @ptrCast(@alignCast(ctx));
    for (table.*) |e| if (std.mem.eql(u8, e[0], text)) return e[1];
    return 0;
}

fn translate(svg: []const u8, id: []const u8) !struct { f64, f64 } {
    const key = try std.fmt.allocPrint(std.testing.allocator, "id=\"diagram-flowchart-{s}-", .{id});
    defer std.testing.allocator.free(key);
    const at = std.mem.indexOf(u8, svg, key) orelse return error.NotFound;
    const tr = std.mem.indexOfPos(u8, svg, at, "translate(") orelse return error.NotFound;
    const comma = std.mem.indexOfScalarPos(u8, svg, tr, ',') orelse return error.NotFound;
    const close = std.mem.indexOfScalarPos(u8, svg, comma, ')') orelse return error.NotFound;
    return .{
        try std.fmt.parseFloat(f64, svg[tr + 10 .. comma]),
        try std.fmt.parseFloat(f64, std.mem.trim(u8, svg[comma + 1 .. close], " ")),
    };
}

fn check(src: []const u8, table: []const Entry, nodes: []const Node) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: model.Config = .{};
    cfg.diagram_padding = 48;
    cfg.look = "neo";
    var t = table;
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = @ptrCast(&t), .widthFn = width }, .cfg = &cfg, .diagram_id = "diagram" };
    const r = try flowchart.renderSource(&ctx, std.testing.allocator, src, .{});
    const svg = r.ok.svg;
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-look=\"neo\"") != null);
    for (nodes) |n| _ = try translate(svg, n[0]);
}

test "neo look n1" {
    const src =
        \\flowchart TD
        \\  A[Rect] --> B(Round)
        \\  B --> C([Stadium])
        \\  C --> D[[Subroutine]]
        \\  D --> E[(Database)]
        \\  E --> F((Circle))
        \\  F --> G(((Double)))
        \\  G --> H{Diamond}
        \\  H --> I{{Hexagon}}
        \\  I --> J[/Lean R/]
        \\  J --> K[\Lean L\]
        \\  K --> L[/Trap/]
        \\  L --> M[\Inv trap/]
        \\
        \\
    ;
    try check(src, &.{ .{ "Rect", 31.65625 }, .{ "Round", 43.65625 }, .{ "Stadium", 57.953125 }, .{ "Subroutine", 77.28125 }, .{ "Database", 65.5 }, .{ "Circle", 41.71875 }, .{ "Double", 49.5 }, .{ "Diamond", 62.3125 }, .{ "Hexagon", 60.984375 }, .{ "Lean R", 48.109375 }, .{ "Lean L", 46.90625 }, .{ "Trap", 31.078125 }, .{ "Inv trap", 55.734375 } }, &.{ .{ "A", 129, 36 }, .{ "B", 129, 127 }, .{ "C", 129, 218 }, .{ "D", 129, 300 }, .{ "E", 129, 402.07434844970703 }, .{ "F", 129, 526.2134742736816 }, .{ "G", 129, 661.7839317321777 }, .{ "H", 129, 844.2896118164062 }, .{ "I", 129, 1018.2896118164062 }, .{ "J", 129, 1124.7896118164062 }, .{ "K", 129, 1203.7896118164062 }, .{ "L", 129, 1282.7896118164062 }, .{ "M", 129, 1369.2896118164062 } });
}

test "neo look n2" {
    const src =
        \\flowchart LR
        \\  subgraph S [Group]
        \\    a[One] -->|label| b[Two]
        \\  end
        \\  b --> c[Three]
        \\  c -.-> d[Four]
        \\  d ==> e[Five]
        \\  e --x f[Six]
        \\  f --o g[Seven]
        \\  g <--> h[Eight]
        \\  a --> a
        \\
        \\
    ;
    try check(src, &.{ .{ "Group", 43.28125 }, .{ "label", 35.484375 }, .{ "One", 28.25 }, .{ "Two", 27.578125 }, .{ "Three", 41.703125 }, .{ "Four", 31.953125 }, .{ "Five", 29.53125 }, .{ "Six", 20.28125 }, .{ "Seven", 41.734375 }, .{ "Eight", 36.25 } }, &.{ .{ "a", 112, 99 }, .{ "b", 347.484375, 99 }, .{ "c", 573.484375, 99 }, .{ "d", 765.484375, 99 }, .{ "e", 957.484375, 99 }, .{ "f", 1149.484375, 99 }, .{ "g", 1341.484375, 99 }, .{ "h", 1533.484375, 99 } });
}

test "neo look n3" {
    const src =
        \\flowchart TD
        \\  A@{ shape: doc, label: "Doc" } --> B@{ shape: cloud, label: "Cloud" }
        \\  B --> C@{ shape: tri, label: "Tri" }
        \\  C --> D@{ shape: lin-cyl, label: "Lined" }
        \\  D --> E@{ shape: h-cyl, label: "Tilted" }
        \\  E --> F@{ shape: card, label: "Card" }
        \\  F --> G@{ shape: bow-rect, label: "Bow" }
        \\  G --> H@{ shape: win-pane, label: "Pane" }
        \\  H --> I@{ shape: st-rect, label: "Multi" }
        \\  I --> J@{ shape: brace, label: "Brace" }
        \\  J --> K@{ shape: div-rect, label: "Div" }
        \\  K --> L@{ shape: tag-rect, label: "Tag" }
        \\  L --> M@{ shape: curv-trap, label: "Curved" }
        \\  M --> N@{ shape: flip-tri, label: "Flip" }
        \\  N --> O@{ shape: odd, label: "Odd" }
        \\
        \\
    ;
    try check(src, &.{ .{ "Doc", 26.328125 }, .{ "Cloud", 40.53125 }, .{ "Tri", 18.3125 }, .{ "Lined", 39.046875 }, .{ "Tilted", 41.890625 }, .{ "Card", 33.109375 }, .{ "Bow", 29.546875 }, .{ "Pane", 34.046875 }, .{ "Multi", 35.71875 }, .{ "Brace", 40.328125 }, .{ "Div", 22.21875 }, .{ "Tag", 23.734375 }, .{ "Curved", 50.015625 }, .{ "Flip", 26.59375 }, .{ "Odd", 28.609375 } }, &.{ .{ "A", 106.99383544921875, 47.9957389831543 }, .{ "B", 106.99383544921875, 175.9355812072754 }, .{ "C", 106.99383544921875, 354.8796844482422 }, .{ "D", 106.99383544921875, 538.4573059082031 }, .{ "E", 106.99383544921875, 653.0349273681641 }, .{ "F", 106.99383544921875, 747.0349273681641 }, .{ "G", 106.99383544921875, 841.0349273681641 }, .{ "H", 106.99383544921875, 928.0349273681641 }, .{ "I", 106.99383544921875, 1031.034927368164 }, .{ "J", 106.99383544921875, 1128.034927368164 }, .{ "K", 106.99383544921875, 1215.034927368164 }, .{ "L", 106.99383544921875, 1303.034927368164 }, .{ "M", 106.99383544921875, 1391.034927368164 }, .{ "N", 106.99383544921875, 1542.034927368164 }, .{ "O", 106.99383544921875, 1693.034927368164 } });
}

test "neo edges use margin markers and a dash prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: model.Config = .{};
    cfg.look = "neo";
    var table: []const Entry = &.{};
    const ctx: model.Ctx = .{ .a = arena.allocator(), .measurer = .{ .ctx = @ptrCast(&table), .widthFn = width }, .cfg = &cfg, .diagram_id = "diagram" };
    const r = try flowchart.renderSource(&ctx, std.testing.allocator, "flowchart LR\n  A --> B\n  B -.-> C\n  C --x D\n  D --o E\n", .{});
    const svg = r.ok.svg;
    try std.testing.expect(std.mem.indexOf(u8, svg, "marker-end=\"url(#diagram_flowchart-v2-pointEnd-margin)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "marker-end=\"url(#diagram_flowchart-v2-crossEnd-margin)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "marker-end=\"url(#diagram_flowchart-v2-circleEnd-margin)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "style=\"stroke-dasharray: 0 0 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, " 2 2 2 2 ") != null);
}
