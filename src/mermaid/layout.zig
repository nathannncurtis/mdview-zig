const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

/// The layout engines Mermaid 12.2.0 registers in the full build (`registerDefaultLayoutLoaders`).
pub const Engine = enum { dagre, swimlane, cose_bilkent, elk };

pub const Choice = struct {
    /// The name `layout` is registered under.
    name: []const u8,
    engine: Engine,
    /// The ELK algorithm for the `elk` family, as the loader passes it on.
    algorithm: ?[]const u8 = null,
};

/// Flips to true when the ELK port in `src/mermaid/elk` is wired in; until then ELK choices are drawn by dagre.
pub const elk_ported = false;

const registered = [_]Choice{
    .{ .name = "dagre", .engine = .dagre },
    .{ .name = "swimlane", .engine = .swimlane },
    .{ .name = "cose-bilkent", .engine = .cose_bilkent },
    .{ .name = "elk", .engine = .elk, .algorithm = "elk.layered" },
    .{ .name = "elk.stress", .engine = .elk, .algorithm = "elk.stress" },
    .{ .name = "elk.force", .engine = .elk, .algorithm = "elk.force" },
    .{ .name = "elk.mrtree", .engine = .elk, .algorithm = "elk.mrtree" },
    .{ .name = "elk.sporeOverlap", .engine = .elk, .algorithm = "elk.sporeOverlap" },
    .{ .name = "elk.box", .engine = .elk, .algorithm = "elk.box" },
    .{ .name = "elk.rectpacking", .engine = .elk, .algorithm = "elk.rectpacking" },
};

const last_resort: Choice = registered[0];

pub fn registeredLayout(name: []const u8) ?Choice {
    for (registered) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// `getRegisteredLayoutAlgorithm(config.layout)`: the layout the config names, or dagre when nothing is registered under it.
/// The config's `layout` already holds the diagram type's own default (flowchart and state: elk, swimlane: swimlane).
pub fn select(cfg: *const config.Config) Choice {
    const name = cfg.str("layout") orelse "";
    return registeredLayout(name) orelse last_resort;
}

/// The engine that draws a choice: ELK falls back to dagre while the ELK port is not wired in.
pub fn engineFor(c: Choice) Engine {
    return if (c.engine == .elk and !elk_ported) .dagre else c.engine;
}

fn layoutFor(a: Allocator, scope: ?[]const u8, directive: ?[]const u8) !Choice {
    const site = try config.setupSite(a, .dark, config.github_init);
    var dir: ?config.Value = null;
    if (directive) |d| dir = try std.json.parseFromSliceLeaky(config.Value, a, d, .{});
    const cfg = try config.current(a, &site, scope, dir);
    return select(&cfg);
}

test "the layout follows the diagram type's default and the layout setting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("elk", (try layoutFor(a, "flowchart", null)).name);
    try std.testing.expectEqualStrings("elk", (try layoutFor(a, "state", null)).name);
    try std.testing.expectEqualStrings("swimlane", (try layoutFor(a, "swimlane", null)).name);
    try std.testing.expectEqualStrings("dagre", (try layoutFor(a, "flowchart", "{\"layout\":\"dagre\"}")).name);
    const stress = try layoutFor(a, "flowchart", "{\"layout\":\"elk.stress\"}");
    try std.testing.expectEqual(Engine.elk, stress.engine);
    try std.testing.expectEqualStrings("elk.stress", stress.algorithm.?);
    try std.testing.expectEqualStrings("elk.layered", (try layoutFor(a, "flowchart", null)).algorithm.?);
}

test "an unregistered layout falls back to dagre and ELK waits for the port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bogus = try layoutFor(a, "flowchart", "{\"layout\":\"nope\"}");
    try std.testing.expectEqual(Engine.dagre, bogus.engine);
    const elk = try layoutFor(a, "flowchart", null);
    try std.testing.expectEqual(if (elk_ported) Engine.elk else Engine.dagre, engineFor(elk));
}
