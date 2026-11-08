const std = @import("std");
const Allocator = std.mem.Allocator;
const rt = @import("../jison/runtime.zig");
const G = @import("seq_grammar");
const actions = @import("actions.zig");
const dbm = @import("db.zig");
const env = @import("env.zig");

const P = rt.Parser(G, actions.Actions);

pub const Failure = struct { message: []const u8 };

pub fn parse(a: Allocator, conf: *const env.Conf, source: []const u8, title: ?[]const u8, elements: ?*const std.StringHashMapUnmanaged([]const u8)) Allocator.Error!union(enum) { ok: *dbm.Db, err: Failure } {
    const db = try a.create(dbm.Db);
    db.* = .{ .a = a, .conf = conf, .wrap_enabled = conf.root_wrap, .title = if (title) |t| try @import("sanitize.zig").sanitizeText(a, t) else null };
    db.elements = elements;
    var act: actions.Actions = .{ .a = a, .db = db };
    const input = try rt.toUtf16(a, source);
    var diag: rt.Diag = .{};
    const outcome = P.parse(a, &act, input, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .{ .message = if (diag.message.len > 0) diag.message else @errorName(e) } },
    };
    _ = outcome;
    return .{ .ok = db };
}

test "parses a basic diagram" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conf: env.Conf = .{};
    const r = try parse(arena.allocator(), &conf, "sequenceDiagram\n    Alice->>John: Hello John, how are you?\n    John-->>Alice: Great!\n", null, null);
    const db = r.ok;
    try std.testing.expectEqual(@as(usize, 2), db.actors.count());
    try std.testing.expectEqual(@as(usize, 2), db.messages.items.len);
    try std.testing.expectEqualStrings("Hello John, how are you?", db.messages.items[0].message);
}
