const std = @import("std");
const db_mod = @import("db.zig");
const model = @import("../render/model.zig");
const Db = db_mod.Db;
const t = std.testing;

fn ft(s: []const u8) db_mod.FlowText {
    return .{ .text = s };
}

fn link(db: *Db, s: []const u8, e: []const u8) !void {
    try db.addLink(&.{s}, &.{e}, try db.destructLink("-->", null));
}

test "A-->B builds two nodes and one edge" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    try db.setDirection("TD");
    try db.addVertex("A", null, null, null, null, null, null);
    try db.addVertex("B", ft("bee"), "round", null, null, null, null);
    try link(&db, "A", "B");
    try link(&db, "A", "B");
    const d = try db.getData();
    try t.expectEqual(@as(usize, 2), d.nodes.len);
    try t.expectEqualStrings("squareRect", d.nodes[0].shape);
    try t.expectEqualStrings("roundedRect", d.nodes[1].shape);
    try t.expectEqualStrings("bee", d.nodes[1].label.?);
    try t.expectEqualStrings("default ", d.nodes[0].css_classes);
    try t.expectEqualStrings("TB", d.direction);
    try t.expectEqualStrings("L_A_B_0", d.edges[0].id);
    try t.expectEqualStrings("L_A_B_2", d.edges[1].id);
    try t.expectEqualStrings("arrow_point", d.edges[0].arrow_type_end);
    try t.expectEqualStrings("none", d.edges[0].arrow_type_start);
    try t.expectEqual(@as(f64, 1), d.edges[0].minlen);
    try t.expectEqualStrings("basis", d.edges[0].curve.?);
}

test "subgraph with direction, classDef, class, style, linkStyle" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    try db.addVertex("A", null, null, null, null, null, null);
    try db.addVertex("B", null, null, null, null, null, null);
    try link(&db, "A", "B");
    const sid = try db.addSubGraph(ft("one"), &.{ .{ .name = "A" }, .{ .name = "B" }, .{ .name = "A" }, .{ .dir = "LR" }, .{ .name = " " } }, ft("My Title"), false);
    try t.expectEqualStrings("one", sid);
    try db.addClass("hot", &.{ "fill:#f00", "color:#fff" });
    try db.setClass("A,one", "hot");
    try db.addVertex("B", null, null, &.{"stroke:#0f0"}, null, null, null);
    try db.updateLink(&.{.{ .index = "0" }}, &.{"stroke:#00f"});
    const d = try db.getData();
    try t.expectEqualStrings("one", d.nodes[0].id);
    try t.expect(d.nodes[0].is_group);
    try t.expectEqualStrings("LR", d.nodes[0].dir.?);
    try t.expectEqualStrings("My Title", d.nodes[0].label.?);
    try t.expectEqualStrings("one", d.nodes[1].parent_id.?);
    try t.expectEqualStrings("hot", d.nodes[1].css_classes[8..]);
    try t.expectEqual(@as(usize, 3), d.nodes[1].css_compiled_styles.len);
    try t.expectEqualStrings("fill:#f00", d.nodes[1].css_compiled_styles[0]);
    try t.expectEqualStrings("color:#fff", d.nodes[1].css_compiled_styles[1]);
    try t.expectEqualStrings("stroke:#00f", d.edges[0].style[0]);
    try t.expectEqualStrings("fill:none", d.edges[0].style[1]);
    try t.expectError(error.Semantic, db.updateLink(&.{.{ .index = "5" }}, &.{"x"}));
}

test "shape metadata, edge ids, markdown, errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    try db.addVertex("A", null, null, null, null, null, "shape: cyl, label: \"Store\"");
    try db.addVertex("B", .{ .text = "`**bold**`", .type = "markdown" }, "square", null, null, null, null);
    var info = try db.destructLink("-->", null);
    info.id = "e1@";
    try db.addLink(&.{"A"}, &.{"B"}, info);
    try db.addVertex("e1", null, null, null, null, null, "animate: true, curve: linear");
    const d = try db.getData();
    try t.expectEqualStrings("cyl", d.nodes[0].shape);
    try t.expectEqualStrings("Store", d.nodes[0].label.?);
    try t.expectEqualStrings("markdown", d.nodes[1].label_type);
    try t.expectEqualStrings("e1", d.edges[0].id);
    try t.expect(d.edges[0].animate);
    try t.expectEqualStrings("linear", d.edges[0].curve.?);
    try t.expectError(error.Semantic, db.addVertex("C", null, null, null, null, null, "shape: nope"));
    try t.expectEqualStrings("No such shape: nope.", db.err_msg.?);
    try t.expectError(error.Semantic, db.addVertex("C", null, null, null, null, null, "shape: Cyl"));
}

test "maxEdges error text" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{ .max_edges = 2 };
    var db = Db.init(arena.allocator(), &cfg);
    try link(&db, "A", "B");
    try link(&db, "B", "C");
    try t.expectError(error.Semantic, link(&db, "C", "D"));
    try t.expect(std.mem.startsWith(u8, db.err_msg.?, "Edge limit exceeded. 2 edges found, but the limit is 2.\n\nInitialize mermaid"));
}

test "link destructuring and sanitizing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    const a = try db.destructLink("<-.->", null);
    try t.expectEqualStrings("double_arrow_point", a.type);
    try t.expectEqualStrings("dotted", a.stroke);
    const b = try db.destructLink("---->", null);
    try t.expectEqual(@as(f64, 3), b.length.?);
    const c = try db.destructLink("-->", "x--");
    try t.expectEqualStrings("INVALID", c.type);
    const d = try db.destructLink("-->", "--");
    try t.expectEqualStrings("arrow_point", d.type);
    try t.expectEqualStrings("a<b>x</b>y&amp;<br>z", try db.sanitizeText("a<b>x</b>y&amp;<br/>z<script>evil()</script>"));
    try t.expectEqualStrings("<b>open</b>", try db.sanitizeText("<b>open"));
}

test "collapsed subgraph becomes one node and boundary edges are redirected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    for ([_][]const u8{ "X", "A", "B" }) |n| try db.addVertex(n, null, null, null, null, null, null);
    try link(&db, "X", "A");
    try link(&db, "A", "B");
    _ = try db.addSubGraph(ft("s"), &.{ .{ .name = "A" }, .{ .name = "B" } }, ft("S"), false);
    try db.addVertex("s", null, null, null, null, null, "view: collapsed");
    const d = try db.getData();
    try t.expectEqual(@as(usize, 2), d.nodes.len);
    try t.expectEqualStrings("collapsedGroup", d.nodes[0].shape);
    try t.expect(!d.nodes[0].is_group);
    try t.expectEqual(@as(usize, 1), d.edges.len);
    try t.expectEqualStrings("s", d.edges[0].end);
    try t.expectEqualStrings("L_X_A_0", d.edges[0].id);
}

test "a repeated subgraph id merges into the first declaration" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    for ([_][]const u8{ "A", "B" }) |n| try db.addVertex(n, null, null, null, null, null, null);
    _ = try db.addSubGraph(ft("g"), &.{.{ .name = "A" }}, ft("G"), false);
    _ = try db.addSubGraph(ft("g"), &.{.{ .name = "B" }}, ft("G"), false);
    try t.expectEqual(@as(usize, 1), db.sub_graphs.items.len);
    try t.expectEqual(@as(usize, 2), db.sub_graphs.items[0].nodes.len);
}

test "node links always open in the parent frame" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    var db = Db.init(arena.allocator(), &cfg);
    try db.addVertex("A", null, null, null, null, null, null);
    try db.setLink("A", "https://example.com", "_blank");
    const d = try db.getData();
    try t.expectEqualStrings("_parent", d.nodes[0].link_target.?);
    try t.expectEqual(@as(f64, 120), d.nodes[0].min_width.?);
}
