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
// SAFETY: set in main before first use
pub var allocator: std.mem.Allocator = undefined;
// SAFETY: set in main before first use
pub var gpa: std.mem.Allocator = undefined;
// SAFETY: set in main before first use
pub var io: std.Io = undefined;
// SAFETY: set in main before first use
pub var environ: *std.process.Environ.Map = undefined;
pub var log_file: ?std.Io.File = null;
var doc: ?md.Document = null;
var data_dir: ?[]const u8 = null;
var scroll_path: ?[]const u8 = null;

const links = @import("links.zig");

pub const Font = enum { body, h1, h2, h3, h4, h5, h6 };

pub const Hit = struct {
    content: md.Inline,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    font: Font = .body,
    header: bool = false,
    alignment: md.Align = .none,
};

const Hover = struct { text: [*]const u8, start: u32 };

pub var hits: std.ArrayList(Hit) = .empty;
pub var block_y: std.ArrayList(f32) = .empty;
pub var hover: ?Hover = null;
pub var full_layout = false;
var pending_jump: ?[]const u8 = null;

pub fn beginFrame() void {
    hits.clearRetainingCapacity();
    block_y.clearRetainingCapacity();
}

pub fn noteBlock(y: f32) void {
    block_y.append(gpa, y) catch return;
}

pub fn noteHit(h: Hit) void {
    if (h.content.links.len > 0) hits.append(gpa, h) catch return;
}

pub fn isHover(content: md.Inline, l: md.Link) bool {
    const h = hover orelse return false;
    return h.text == content.text.ptr and h.start == l.start;
}

pub const LinkHit = struct { content: md.Inline, link: md.Link };

pub fn linkAt(px: f32, py: f32) ?LinkHit {
    const y = py + scroll_y;
    for (hits.items) |h| {
        if (px < h.x or px >= h.x + h.w or y < h.y or y >= h.y + h.h) continue;
        const index = platform.textIndexAt(h, px - h.x, y - h.y) orelse continue;
        if (h.content.linkAt(index)) |l| return .{ .content = h.content, .link = l };
    }
    return null;
}

pub fn pointerMoved(px: f32, py: f32) bool {
    const hit = linkAt(px, py);
    const now: ?Hover = if (hit) |h| .{ .text = h.content.text.ptr, .start = h.link.start } else null;
    const same = if (hover) |a| (if (now) |b| a.text == b.text and a.start == b.start else false) else now == null;
    hover = now;
    if (!same) platform.invalidate();
    return hit != null;
}

const Press = struct { text: [*]const u8, start: u32 };
var pressed: ?Press = null;

/// Remembers the link under a button press; true when the press is on a link.
pub fn mouseDown(px: f32, py: f32) bool {
    const hit = linkAt(px, py) orelse {
        pressed = null;
        return false;
    };
    pressed = .{ .text = hit.content.text.ptr, .start = hit.link.start };
    return true;
}

/// Follows the link when the button is released over the one it was pressed on.
pub fn mouseUp(px: f32, py: f32) bool {
    const down = pressed orelse return false;
    pressed = null;
    const hit = linkAt(px, py) orelse return false;
    if (hit.content.text.ptr != down.text or hit.link.start != down.start) return false;
    activate(hit.link.target);
    return true;
}

const Place = struct { path: []const u8, scroll: f32 };
var back_stack: std.ArrayList(Place) = .empty;
var forward_stack: std.ArrayList(Place) = .empty;

fn here() Place {
    return .{ .path = file_path, .scroll = scroll_y };
}

fn remember() void {
    back_stack.append(gpa, here()) catch return;
    forward_stack.clearRetainingCapacity();
}

fn visit(place: Place) bool {
    const stat = std.Io.Dir.cwd().statFile(io, place.path, .{}) catch return false;
    saveScrollPosition();
    const old_path = file_path;
    file_path = place.path;
    if (!reload(stat.mtime)) {
        file_path = old_path;
        return false;
    }
    scroll_y = place.scroll;
    platform.invalidate();
    return true;
}

pub fn goBack() void {
    const place = back_stack.pop() orelse return;
    const current = here();
    if (visit(place)) {
        forward_stack.append(gpa, current) catch return;
    } else {
        back_stack.append(gpa, place) catch return;
    }
}

pub fn goForward() void {
    const place = forward_stack.pop() orelse return;
    const current = here();
    if (visit(place)) {
        back_stack.append(gpa, current) catch return;
    } else {
        forward_stack.append(gpa, place) catch return;
    }
}

pub fn activate(target: []const u8) void {
    switch (links.classify(target)) {
        .blocked => logFmt("blocked link: {s}", .{target}),
        .external => |url| {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const encoded = links.encodeUrl(arena.allocator(), url) catch return;
            platform.openExternal(encoded);
        },
        .anchor => {
            remember();
            jump(target);
        },
        .file => |t| openMarkdown(t),
        .local => |t| openLocal(t),
    }
}

fn jump(target: []const u8) void {
    pending_jump = allocator.dupe(u8, target) catch return;
    full_layout = true;
    platform.invalidate();
}

pub fn afterRender() bool {
    const target = pending_jump orelse return false;
    pending_jump = null;
    full_layout = false;
    if (targetBlock(target)) |i| {
        if (i < block_y.items.len) {
            scroll_y = block_y.items[i] - 10;
            clampScroll();
        }
    }
    return true;
}

fn clampScroll() void {
    const max_scroll = content_height - window_height + 40;
    if (max_scroll > 0 and scroll_y > max_scroll) scroll_y = max_scroll;
    if (scroll_y < 0) scroll_y = 0;
}

fn targetBlock(target: []const u8) ?usize {
    const name = target[1..];
    const d = doc orelse return null;
    if (std.mem.startsWith(u8, name, "fn-")) {
        const n = std.fmt.parseInt(u32, name[3..], 10) catch return null;
        if (n == 0 or n > d.footnote_blocks.len) return null;
        return d.footnote_blocks[n - 1];
    }
    if (std.mem.startsWith(u8, name, "fnref-")) {
        var parts = std.mem.splitScalar(u8, name[6..], '-');
        const n = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        const nth = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        return nthReference(n, nth);
    }
    return headingBlock(name);
}

fn nthReference(number: u32, nth: u32) ?usize {
    var want: [24]u8 = undefined;
    const target = std.fmt.bufPrint(&want, "#fn-{d}", .{number}) catch return null;
    var seen: u32 = 0;
    for (blocks, 0..) |b, i| {
        var found = countLinks(b.content, target);
        for (b.table.cells) |c| found += countLinks(c, target);
        if (found > 0 and seen + found >= nth) return i;
        seen += found;
    }
    return null;
}

fn countLinks(c: md.Inline, target: []const u8) u32 {
    var n: u32 = 0;
    for (c.links) |l| if (std.mem.eql(u8, l.target, target)) {
        n += 1;
    };
    return n;
}

fn headingBlock(anchor: []const u8) ?usize {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const want = std.ascii.allocLowerString(a, links.percentDecode(a, anchor) catch return null) catch return null;
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    var slug: std.ArrayList(u8) = .empty;
    for (blocks, 0..) |b, i| {
        if (@intFromEnum(b.kind) < @intFromEnum(md.BlockKind.h1) or @intFromEnum(b.kind) > @intFromEnum(md.BlockKind.h6)) continue;
        links.slugInto(&slug, a, b.content.text) catch return null;
        const base = a.dupe(u8, slug.items) catch return null;
        const slot = seen.getOrPut(a, base) catch return null;
        if (!slot.found_existing) slot.value_ptr.* = 0 else slot.value_ptr.* += 1;
        const id = if (slot.value_ptr.* == 0) base else std.fmt.allocPrint(a, "{s}-{d}", .{ base, slot.value_ptr.* }) catch return null;
        if (std.mem.eql(u8, id, want)) return i;
    }
    return null;
}

fn openLocal(target: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bare = target[0 .. std.mem.indexOfAny(u8, target, "?#") orelse target.len];
    const decoded = links.percentDecode(a, bare) catch return;
    const joined = if (std.fs.path.dirname(file_path)) |dir| std.fmt.allocPrint(a, "{s}/{s}", .{ dir, decoded }) catch return else decoded;
    const slashed = a.dupe(u8, joined) catch return;
    std.mem.replaceScalar(u8, slashed, '\\', '/');
    const prefix: []const u8 = if (slashed.len > 0 and slashed[0] == '/') "file://" else "file:///";
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, slashed }) catch return;
    const encoded = links.encodeUrl(a, url) catch return;
    platform.openExternal(encoded);
}

fn openMarkdown(target: []const u8) void {
    var path = target;
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path, '#')) |h| {
        fragment = path[h..];
        path = path[0..h];
    }
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var resolved = links.percentDecode(arena.allocator(), path) catch return;
    if (std.ascii.startsWithIgnoreCase(resolved, "file:")) {
        resolved = resolved[5..];
        if (std.mem.startsWith(u8, resolved, "//")) resolved = resolved[2..];
        if (builtin.os.tag == .windows and resolved.len > 2 and resolved[0] == '/' and resolved[2] == ':') resolved = resolved[1..];
    } else if (std.fs.path.dirname(file_path)) |dir| {
        resolved = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ dir, resolved }) catch return;
    }
    const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| {
        logFmt("cannot open {s}: {t}", .{ resolved, err });
        return;
    };
    const new_path = allocator.dupe(u8, resolved) catch return;
    saveScrollPosition();
    const old_path = file_path;
    const old_scroll = scroll_y;
    file_path = new_path;
    if (!reload(stat.mtime)) {
        file_path = old_path;
        return;
    }
    back_stack.append(gpa, .{ .path = old_path, .scroll = old_scroll }) catch |err| logFmt("history: {t}", .{err});
    forward_stack.clearRetainingCapacity();
    scroll_y = 0;
    if (fragment.len > 0) jump(fragment) else platform.invalidate();
}


// ============================================================
// Logging
// ============================================================
pub fn initLog() void {
    const dir = data_dir orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    const log_path = std.fmt.allocPrint(allocator, "{s}/mdview-zig.log", .{dir}) catch return;
    log_file = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
}

pub fn log(msg: []const u8) void {
    if (log_file) |f| {
        f.writeStreamingAll(io, msg) catch return;
        f.writeStreamingAll(io, "\n") catch return;
    }
}

pub fn logFmt(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [256]u8 = undefined;
        var w = f.writerStreaming(io, &buf);
        w.interface.print(fmt ++ "\n", args) catch return;
        w.interface.flush() catch return;
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
    hits.clearRetainingCapacity();
    hover = null;
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
    std.Io.Dir.cwd().createDirPath(io, data_dir.?) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = entries.items }) catch return;
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
