const std = @import("std");
const Allocator = std.mem.Allocator;
const files = @import("files.zig");

const model = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";

fn git(arena: Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const r = try std.process.run(arena, io, .{ .argv = argv });
    switch (r.term) {
        .exited => |code| if (code == 0) return r.stdout,
        else => {},
    }
    std.debug.print("{s}", .{r.stderr});
    return error.GitFailed;
}

const Version = [3]u32;

fn parseTag(tag: []const u8) ?Version {
    if (tag.len < 2 or tag[0] != 'v') return null;
    var out: Version = undefined;
    var it = std.mem.splitScalar(u8, tag[1..], '.');
    for (&out) |*part| part.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return out;
}

fn tagLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u32, &parseTag(a).?, &parseTag(b).?) == .lt;
}

fn isPaperwork(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "docs/") or std.mem.startsWith(u8, path, "tests/") or
        std.mem.startsWith(u8, path, ".github/") or std.mem.endsWith(u8, path, ".md");
}

fn changes(arena: Allocator, io: std.Io, tag: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    var listed = std.mem.tokenizeAny(u8, try git(arena, io, &.{ "git", "tag", "--list", "v*" }), " \r\n");
    while (listed.next()) |t| if (parseTag(t) != null) try tags.append(arena, t);
    std.mem.sort([]const u8, tags.items, {}, tagLess);
    const at = for (tags.items, 0..) |t, i| {
        if (std.mem.eql(u8, t, tag)) break i;
    } else null;
    const range = if (at != null and at.? > 0)
        try std.fmt.allocPrint(arena, "{s}..{s}", .{ tags.items[at.? - 1], tag })
    else
        tag;

    var out: std.ArrayList([]const u8) = .empty;
    const log = try git(arena, io, &.{ "git", "log", "--no-merges", "--format=\x1e%s", "--name-only", range });
    var blocks = std.mem.splitScalar(u8, log, 0x1e);
    _ = blocks.next();
    while (blocks.next()) |block| {
        var subject: ?[]const u8 = null;
        var any_file = false;
        var all_paperwork = true;
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (subject == null) {
                subject = line;
                continue;
            }
            any_file = true;
            if (!isPaperwork(line)) all_paperwork = false;
        }
        const s = subject orelse continue;
        if (!(any_file and all_paperwork)) try out.append(arena, s);
    }
    return out.items;
}

fn summarise(arena: Allocator, io: std.Io, env: *std.process.Environ.Map, list: []const []const u8) ![]const u8 {
    var prompt: std.Io.Writer.Allocating = .init(arena);
    try prompt.writer.writeAll("Write release notes for mdview, a native Markdown viewer for Windows, Linux and macOS, from these commit " ++
        "subjects. Group them under short headings for the areas that changed (Rendering, Windows, Linux, macOS, " ++
        "Packaging), skipping areas with no changes. One short plain bullet per change, describing what changed for " ++
        "someone using mdview. No names, no attribution, no introduction, no closing line.\n\n");
    for (list, 0..) |c, i| {
        if (i > 0) try prompt.writer.writeByte('\n');
        try prompt.writer.print("- {s}", .{c});
    }
    const payload = try std.json.Stringify.valueAlloc(arena, .{
        .messages = &[_]struct { role: []const u8, content: []const u8 }{.{ .role = "user", .content = prompt.written() }},
        .max_tokens = 1024,
    }, .{});
    const url = try std.fmt.allocPrint(arena, "https://api.cloudflare.com/client/v4/accounts/{s}/ai/run/{s}", .{
        env.get("CLOUDFLARE_ACCOUNT_ID") orelse return error.MissingAccount,
        model,
    });
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{env.get("CLOUDFLARE_API_TOKEN") orelse return error.MissingToken});

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .authorization = .{ .override = bearer }, .content_type = .{ .override = "application/json" } },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.HttpStatus;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body.written(), .{});
    const result = parsed.object.get("result") orelse return "";
    if (result != .object) return "";
    const response = result.object.get("response") orelse return "";
    return if (response == .string) response.string else "";
}

pub fn main(init: std.process.Init) !void {
    const a = try files.args(init, 2, "release-notes <tag> <out.md>");
    const arena = init.arena.allocator();
    try files.write(init.io, a[1], "");
    const list = try changes(arena, init.io, a[0]);
    if (list.len == 0) return;
    const text = summarise(arena, init.io, init.environ_map, list) catch |e| {
        std.debug.print("::warning::Release notes not written: {s}\n", .{@errorName(e)});
        return;
    };
    const stripped = try std.mem.replaceOwned(u8, arena, text, "@", "");
    try files.write(init.io, a[1], std.mem.trim(u8, stripped, " \t\r\n"));
}
