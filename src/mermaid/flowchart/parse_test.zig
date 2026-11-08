const std = @import("std");
const db_mod = @import("db.zig");
const model = @import("../render/model.zig");
const parse_mod = @import("parse.zig");
const rt = @import("../jison/runtime.zig");
const Db = db_mod.Db;
const t = std.testing;

fn parsed(arena: *std.heap.ArenaAllocator, cfg: *const model.Config, src: []const u8) !model.LayoutData {
    const db = try arena.allocator().create(Db);
    db.* = Db.init(arena.allocator(), cfg);
    var diag: rt.Diag = .{};
    defer diag.deinit(t.allocator);
    parse_mod.parse(t.allocator, db, src, &diag) catch |e| {
        std.debug.print("parse error {s}: {s}\n", .{ @errorName(e), diag.message });
        return e;
    };
    return db.getData();
}

test "parser: flowchart with shapes, links and subgraph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const d = try parsed(&arena, &cfg,
        \\flowchart LR
        \\  A[Start] -->|yes| B(Round) --> C{Dec}
        \\  subgraph one [Group]
        \\    direction TB
        \\    C -.-> D((Circ))
        \\  end
        \\  classDef hot fill:#f00,color:#fff
        \\  class A hot
        \\  linkStyle 0 stroke:#0f0
        \\  E@{ shape: cyl, label: "Store" }
        \\
    );
    try t.expectEqualStrings("LR", d.direction);
    try t.expectEqual(@as(usize, 6), d.nodes.len);
    try t.expectEqualStrings("one", d.nodes[0].id);
    try t.expectEqualStrings("TB", d.nodes[0].dir.?);
    try t.expectEqualStrings("Group", d.nodes[0].label.?);
    try t.expectEqualStrings("A", d.nodes[1].id);
    try t.expectEqualStrings("Start", d.nodes[1].label.?);
    try t.expectEqualStrings("yes", d.edges[0].label.?);
    try t.expectEqual(@as(usize, 3), d.edges.len);
    try t.expectEqualStrings("dotted", d.edges[2].pattern);
    try t.expectEqualStrings("stroke:#0f0", d.edges[0].style[0]);
    const e = d.nodes[5];
    try t.expectEqualStrings("E", e.id);
    try t.expectEqualStrings("cyl", e.shape);
    try t.expectEqualStrings("Store", e.label.?);
    try t.expectEqualStrings("one", d.nodes[4].parent_id.?);
}

test "parser: ampersand groups, markdown strings, edge ids, arrows" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const d = try parsed(&arena, &cfg,
        \\graph TD
        \\  A & B e1@--> C
        \\  C <-- txt --> D
        \\  D o--o E
        \\  F["`**bold** text`"] ~~~ G
        \\
    );
    try t.expectEqual(@as(usize, 5), d.edges.len);
    try t.expectEqualStrings("L_A_C_0", d.edges[0].id);
    try t.expectEqualStrings("e1", d.edges[1].id);
    try t.expectEqualStrings("double_arrow_point", d.edges[2].type);
    try t.expectEqualStrings("txt", d.edges[2].label.?);
    try t.expectEqualStrings("arrow_circle", d.edges[3].arrow_type_start);
    try t.expectEqualStrings("markdown", d.nodes[5].label_type);
    try t.expectEqualStrings("**bold** text", d.nodes[5].label.?);
    try t.expectEqualStrings("invisible", d.edges[4].thickness);
}

test "parser: syntax error text" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    var diag: rt.Diag = .{};
    defer diag.deinit(t.allocator);
    try t.expectError(error.Syntax, parse_mod.parse(t.allocator, &db, "graph TD\nA-->", &diag));
    try t.expect(std.mem.startsWith(u8, diag.message, "Parse error on line 2:"));
}
