const std = @import("std");
const builtin = @import("builtin");
pub const md = @import("markdown.zig");

// Platform-specific backend
pub const platform = switch (builtin.os.tag) {
    .windows => @import("win32.zig"),
    .linux => @import("linux.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("Unsupported platform"),
};

// Shared state
pub var scroll_y: f32 = 0;
pub var content_height: f32 = 800;
pub var window_height: f32 = 700;
pub var window_width: f32 = 900;
pub var blocks: []const md.Block = &.{};
pub var file_path: []const u8 = "";
pub var file_mtime: std.Io.Timestamp = .zero;
pub var allocator: std.mem.Allocator = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
pub var environ: *std.process.Environ.Map = undefined;
pub var log_file: ?std.Io.File = null;
var doc: ?md.Document = null;
var data_dir: ?[]const u8 = null;
var scroll_path: ?[]const u8 = null;

// ============================================================
// Logging
// ============================================================
pub fn initLog() void {
    const dir = data_dir orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const log_path = std.fmt.allocPrint(allocator, "{s}/mdview-zig.log", .{dir}) catch return;
    log_file = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
}

pub fn log(msg: []const u8) void {
    if (log_file) |f| {
        f.writeStreamingAll(io, msg) catch {};
        f.writeStreamingAll(io, "\n") catch {};
    }
}

pub fn logFmt(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [256]u8 = undefined;
        var w = f.writerStreaming(io, &buf);
        w.interface.print(fmt ++ "\n", args) catch {};
        w.interface.flush() catch {};
    }
}

fn getDataDir() ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = environ.get("LOCALAPPDATA") orelse return null;
        return std.fmt.allocPrint(allocator, "{s}\\mdview", .{appdata}) catch null;
    } else if (builtin.os.tag == .macos) {
        const home = environ.get("HOME") orelse return null;
        return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/mdview", .{home}) catch null;
    } else {
        // XDG
        if (environ.get("XDG_DATA_HOME")) |xdg| {
            return std.fmt.allocPrint(allocator, "{s}/mdview", .{xdg}) catch null;
        } else {
            const home = environ.get("HOME") orelse return null;
            return std.fmt.allocPrint(allocator, "{s}/.local/share/mdview", .{home}) catch null;
        }
    }
}

// ============================================================
// File operations
// ============================================================
pub fn loadFile() void {
    const stat = std.Io.Dir.cwd().statFile(io, file_path, .{}) catch |err| {
        logFmt("cannot open {s}: {t}", .{ file_path, err });
        return;
    };
    _ = reload(stat.mtime);
}

pub fn checkFileChanged() void {
    const stat = std.Io.Dir.cwd().statFile(io, file_path, .{}) catch return;
    if (stat.mtime.nanoseconds != file_mtime.nanoseconds) {
        log("file changed, reloading");
        if (reload(stat.mtime)) platform.invalidate();
    }
}

fn reload(mtime: std.Io.Timestamp) bool {
    const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .unlimited) catch |err| {
        logFmt("cannot read {s}: {t}", .{ file_path, err });
        return false;
    };
    defer gpa.free(text);
    const new_doc = md.parse(gpa, text) catch {
        logFmt("out of memory parsing {s}", .{file_path});
        return false;
    };
    if (doc) |*old| old.deinit();
    doc = new_doc;
    blocks = new_doc.blocks;
    file_mtime = mtime;
    logFmt("read {d} bytes, parsed {d} blocks", .{ text.len, blocks.len });
    return true;
}

// ============================================================
// Scroll persistence
// ============================================================
pub fn loadScrollPosition() f32 {
    const path = scroll_path orelse return 0;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return 0;
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
            if (std.mem.eql(u8, trimmed[0..eq], file_path)) {
                return std.fmt.parseFloat(f32, trimmed[eq + 1 ..]) catch 0;
            }
        }
    }
    return 0;
}

pub fn saveScrollPosition() void {
    const path = scroll_path orelse return;
    var entries: std.ArrayList(u8) = .empty;
    defer entries.deinit(gpa);
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited)) |data| {
        defer gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                if (std.mem.eql(u8, trimmed[0..eq], file_path)) continue;
            }
            entries.appendSlice(gpa, trimmed) catch return;
            entries.append(gpa, '\n') catch return;
        }
    } else |_| {}
    if (scroll_y > 1) {
        entries.print(gpa, "{s}={d:.0}\n", .{ file_path, scroll_y }) catch return;
    }
    std.Io.Dir.cwd().createDirPath(io, data_dir.?) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = entries.items }) catch {};
}

// ============================================================
// Entry points
// ============================================================
pub fn main(init: std.process.Init) !void {
    allocator = init.arena.allocator();
    gpa = init.gpa;
    io = init.io;
    environ = init.environ_map;
    if (builtin.os.tag == .windows) {
        platform.hinstance = std.os.windows.peb().ImageBaseAddress;
    }
    data_dir = getDataDir();
    if (data_dir) |dir| scroll_path = try std.fmt.allocPrint(allocator, "{s}/scroll.dat", .{dir});
    initLog();
    log("starting mdview-zig");

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--register")) {
        platform.registerFileAssociation();
        return;
    }
    if (args.len < 2) {
        log("no file argument");
        return;
    }

    file_path = args[1];
    logFmt("opening: {s}", .{file_path});

    loadFile();
    defer if (doc) |*d| d.deinit();

    scroll_y = loadScrollPosition();

    platform.run();
}
