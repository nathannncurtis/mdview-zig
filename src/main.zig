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
pub var markdown_text: []const u8 = "";
pub var file_path: []const u8 = "";
pub var file_mtime: i128 = 0;
pub var allocator: std.mem.Allocator = undefined;
pub var log_file: ?std.fs.File = null;

// ============================================================
// Logging
// ============================================================
pub fn initLog() void {
    const data_dir = getDataDir() orelse return;
    std.fs.cwd().makePath(data_dir) catch {};
    var buf: [512]u8 = undefined;
    const log_path = std.fmt.bufPrint(&buf, "{s}/mdview-zig.log", .{data_dir}) catch return;
    log_file = std.fs.cwd().createFile(log_path, .{ .truncate = true }) catch null;
}

pub fn log(msg: []const u8) void {
    if (log_file) |f| {
        f.writer().writeAll(msg) catch {};
        f.writer().writeAll("\n") catch {};
    }
}

pub fn logFmt(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        f.writer().print(fmt ++ "\n", args) catch {};
    }
}

fn getDataDir() ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch return null;
        return std.fmt.allocPrint(allocator, "{s}\\mdview", .{appdata}) catch null;
    } else if (builtin.os.tag == .macos) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/mdview", .{home}) catch null;
    } else {
        // XDG
        if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg| {
            return std.fmt.allocPrint(allocator, "{s}/mdview", .{xdg}) catch null;
        } else |_| {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
            return std.fmt.allocPrint(allocator, "{s}/.local/share/mdview", .{home}) catch null;
        }
    }
}

// ============================================================
// File operations
// ============================================================
pub fn loadFile() void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    file_mtime = stat.mtime;
    markdown_text = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
    md.parse(markdown_text);
}

pub fn checkFileChanged() void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    if (stat.mtime != file_mtime) {
        log("file changed, reloading");
        file_mtime = stat.mtime;
        markdown_text = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
        md.parse(markdown_text);
        platform.invalidate();
    }
}

// ============================================================
// Scroll persistence
// ============================================================
fn scrollDataPath() ?[]const u8 {
    const dir = getDataDir() orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/scroll.dat", .{dir}) catch null;
}

pub fn loadScrollPosition() f32 {
    const path = scrollDataPath() orelse return 0;
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
            if (std.mem.eql(u8, trimmed[0..eq], file_path)) {
                return std.fmt.parseFloat(f32, trimmed[eq + 1 ..]) catch 0;
            }
        }
    }
    return 0;
}

pub fn saveScrollPosition() void {
    const path = scrollDataPath() orelse return;
    var entries = std.ArrayList(u8).init(allocator);
    if (std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024)) |data| {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                if (std.mem.eql(u8, trimmed[0..eq], file_path)) continue;
            }
            entries.appendSlice(trimmed) catch continue;
            entries.append('\n') catch continue;
        }
    } else |_| {}
    if (scroll_y > 1) {
        entries.writer().print("{s}={d:.0}\n", .{ file_path, scroll_y }) catch {};
    }
    const dir = getDataDir() orelse return;
    std.fs.cwd().makePath(dir) catch {};
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(entries.items) catch {};
}

// ============================================================
// Entry points
// ============================================================
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    allocator = arena.allocator();
    initLog();
    log("starting mdview-zig");

    const args = try std.process.argsAlloc(allocator);
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
    logFmt("read {d} bytes, parsed {d} blocks", .{ markdown_text.len, md.block_count });

    scroll_y = loadScrollPosition();

    platform.run();
}

// Windows entry point
pub export fn wWinMain(hInstance: ?*anyopaque, _: ?*anyopaque, _: ?[*:0]const u16, _: i32) callconv(.C) i32 {
    if (builtin.os.tag == .windows) {
        platform.hinstance = hInstance;
    }
    main() catch return 1;
    return 0;
}
