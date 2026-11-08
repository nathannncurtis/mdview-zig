const std = @import("std");
const model = @import("model.zig");
const dom = @import("dom.zig");
const shapes = @import("shapes.zig");

fn hello(_: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
    return if (std.mem.eql(u8, text, "Hello")) 37.21875 else 8 * @as(f64, @floatFromInt(text.len));
}

fn mk(arena: *std.heap.ArenaAllocator, cfg: *const model.Config) model.Ctx {
    var dummy: u8 = 0;
    return .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = hello }, .cfg = cfg, .diagram_id = "t" };
}

const Case = struct { []const u8, []const u8, f64, f64 };

// Sizes are mermaid 12.2.0 node bboxes in Chromium for "Hello" with padding 15 and the 120px minimum label width.
const classic = [_]Case{
    .{ "rect", "classic", 180, 54 },
    .{ "diam", "classic", 174, 174 },
    .{ "circle", "classic", 59.28583526611328, 59.28583526611328 },
    .{ "dbl-circ", "classic", 84.28583526611328, 84.28583526611328 },
    .{ "hex", "classic", 154.5, 39 },
    .{ "stadium", "classic", 144.72996520996094, 39 },
    .{ "cyl", "classic", 135, 77.94230651855469 },
    .{ "subroutine", "classic", 151, 39 },
    .{ "lean-r", "classic", 174, 39 },
    .{ "odd", "classic", 144.75, 39 },
    .{ "rect", "neo", 152, 48 },
    .{ "diam", "neo", 174, 174 },
    .{ "circle", "neo", 76.28583526611328, 76.28583526611328 },
    .{ "dbl-circ", "neo", 100.28583526611328, 100.28583526611328 },
    .{ "hex", "neo", 205.7142791748047, 94 },
    .{ "stadium", "neo", 171.975341796875, 48 },
    .{ "cyl", "neo", 144, 88.14869689941406 },
    .{ "subroutine", "neo", 164, 36 },
    .{ "lean-r", "neo", 189, 39 },
    .{ "odd", "neo", 174, 48 },
};

test "shape sizes match mermaid 12.2.0 in the classic and neo looks" {
    for (classic) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cfg: model.Config = .{};
        cfg.look = c[1];
        const ctx = mk(&arena, &cfg);
        const root = try dom.El.create(ctx.a, "g");
        var n: model.NodeData = .{ .id = "A", .label = "Hello", .padding = 15, .min_width = 120, .shape = c[0], .look = c[1] };
        _ = try shapes.insert(&ctx, root, &n, .{});
        std.testing.expectApproxEqAbs(c[2], n.width, 0.01) catch |e| {
            std.debug.print("{s} {s} width {d}\n", .{ c[0], c[1], n.width });
            return e;
        };
        std.testing.expectApproxEqAbs(c[3], n.height, 0.01) catch |e| {
            std.debug.print("{s} {s} height {d}\n", .{ c[0], c[1], n.height });
            return e;
        };
    }
}

test "unknown shape errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const ctx = mk(&arena, &cfg);
    const root = try dom.El.create(ctx.a, "g");
    var n: model.NodeData = .{ .id = "A", .label = "x", .shape = "nope" };
    try std.testing.expectError(error.NoSuchShape, shapes.insert(&ctx, root, &n, .{}));
}

test "every registered shape inserts with a finite size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const ctx = mk(&arena, &cfg);
    const root = try dom.El.create(ctx.a, "g");
    inline for (shapes.defs) |d| {
        inline for (d.names) |name| {
            var n: model.NodeData = .{ .id = "A", .label = "Hello world", .padding = 15, .shape = name };
            _ = try shapes.insert(&ctx, root, &n, .{});
            try std.testing.expect(std.math.isFinite(n.width) and std.math.isFinite(n.height));
            try std.testing.expect(n.width > 0 and n.height > 0);
        }
    }
}

test "collapsed group is the title box plus the separator and indicator rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const ctx = mk(&arena, &cfg);
    const root = try dom.El.create(ctx.a, "g");
    var n: model.NodeData = .{ .id = "s", .label = "Group", .padding = 8, .shape = "collapsedGroup" };
    _ = try shapes.insert(&ctx, root, &n, .{});
    try std.testing.expectEqual(@as(f64, 80), n.width);
    try std.testing.expectEqual(@as(f64, 68), n.height);
}
