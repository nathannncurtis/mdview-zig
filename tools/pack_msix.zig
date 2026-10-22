const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const files = @import("files.zig");

fn validVersion(v: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| : (parts += 1) {
        if (p.len == 0 or p.len > 5 or (p.len > 1 and p[0] == '0')) return false;
        const n = std.fmt.parseInt(u32, p, 10) catch return false;
        if (n > 65535) return false;
    }
    return parts == 3;
}

const Sdk = struct { name: []const u8, parsed: [3]u32 };

fn sdkNewer(_: void, a: Sdk, b: Sdk) bool {
    return std.mem.order(u32, &a.parsed, &b.parsed) == .gt;
}

fn sdkBin(arena: Allocator, io: std.Io, env: *std.process.Environ.Map) ![]const u8 {
    const pf = env.get("ProgramFiles(x86)") orelse "C:\\Program Files (x86)";
    const root = try std.fs.path.join(arena, &.{ pf, "Windows Kits", "10", "bin" });
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var found: std.ArrayList(Sdk) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "10.")) continue;
        var parsed: [3]u32 = .{ 0, 0, 0 };
        var parts = std.mem.splitScalar(u8, entry.name, '.');
        for (&parsed) |*p| p.* = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        try found.append(arena, .{ .name = try arena.dupe(u8, entry.name), .parsed = parsed });
    }
    std.mem.sort(Sdk, found.items, {}, sdkNewer);
    for (found.items) |sdk| {
        const bin = try std.fs.path.join(arena, &.{ root, sdk.name, "x64" });
        Dir.cwd().access(io, try std.fs.path.join(arena, &.{ bin, "makeappx.exe" }), .{}) catch continue;
        return bin;
    }
    return error.NoWindowsSdk;
}

fn exec(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("{s} failed\n", .{std.fs.path.basename(argv[0])});
        return error.ToolFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const a = try files.args(init, 4, "pack-msix <mdview.exe> <version> <output.msix> <work dir>");
    const arena = init.arena.allocator();
    const io = init.io;
    const exe, const output, const work = .{ a[0], a[2], a[3] };
    const version = std.mem.trimStart(u8, a[1], "v");
    if (!validVersion(version)) {
        std.debug.print("version must be three numeric parts up to 65535: {s}\n", .{version});
        return error.BadVersion;
    }
    const bin = try sdkBin(arena, io, init.environ_map);

    const layout = try std.fs.path.join(arena, &.{ work, "layout" });
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, layout);
    try cwd.copyFile(exe, cwd, try std.fs.path.join(arena, &.{ layout, std.fs.path.basename(exe) }), io, .{});

    const assets_out = try std.fs.path.join(arena, &.{ layout, "Assets" });
    try cwd.createDirPath(io, assets_out);
    var assets = try cwd.openDir(io, "msix/Assets", .{ .iterate = true });
    defer assets.close(io);
    var it = assets.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try assets.copyFile(entry.name, cwd, try std.fs.path.join(arena, &.{ assets_out, entry.name }), io, .{});
    }

    const manifest = try files.read(io, arena, "msix/AppxManifest.xml");
    if (std.mem.find(u8, manifest, "__VERSION__") == null) return error.ManifestHasNoVersion;
    const manifest_out = try std.fs.path.join(arena, &.{ layout, "AppxManifest.xml" });
    try files.write(io, manifest_out, try std.mem.replaceOwned(u8, arena, manifest, "__VERSION__", try std.fmt.allocPrint(arena, "{s}.0", .{version})));

    const makepri = try std.fs.path.join(arena, &.{ bin, "makepri.exe" });
    const makeappx = try std.fs.path.join(arena, &.{ bin, "makeappx.exe" });
    const config = try std.fs.path.join(arena, &.{ work, "priconfig.xml" });
    try exec(io, &.{ makepri, "createconfig", "/cf", config, "/dq", "en-US", "/o" });
    try exec(io, &.{ makepri, "new", "/pr", layout, "/cf", config, "/mn", manifest_out, "/of", try std.fs.path.join(arena, &.{ layout, "resources.pri" }), "/o" });
    if (std.fs.path.dirname(output)) |parent| try cwd.createDirPath(io, parent);
    try exec(io, &.{ makeappx, "pack", "/d", layout, "/p", output, "/o" });
}
