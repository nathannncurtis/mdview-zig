const std = @import("std");
const image = @import("image/image.zig");
const svg = @import("image/svg.zig");
const links = @import("links.zig");

pub const max_download: usize = 20 * 1024 * 1024;
pub const max_local: usize = 128 * 1024 * 1024;
pub const timeout_ms: i64 = 10_000;
const max_threads = 4;
const max_redirects = 3;

// SAFETY: set by init before the first image is requested
pub var gpa: std.mem.Allocator = undefined;
// SAFETY: set by init before the first image is requested
pub var io: std.Io = undefined;
/// Device pixels per layout unit, used to pick the size an SVG is rendered at.
pub var dpi_scale: f32 = 1;
pub var create_native: ?*const fn (rgba: []const u8, w: u32, h: u32) ?*anyopaque = null;
pub var free_native: ?*const fn (?*anyopaque) void = null;

pub const Size = struct { w: f32, h: f32 };
pub const Look = union(enum) { pending, picture: Size, missing };
pub const State = enum(u8) { queued, loading, ready, failed };

/// Decoded pixels plus the backend's bitmaps for them; the bitmaps are only touched on the UI thread.
const Picture = struct {
    img: image.Image,
    natives: []?*anyopaque,

    fn create(img: image.Image) std.mem.Allocator.Error!*Picture {
        const p = try gpa.create(Picture);
        errdefer gpa.destroy(p);
        p.* = .{ .img = img, .natives = try gpa.alloc(?*anyopaque, img.frames.len) };
        @memset(p.natives, null);
        return p;
    }

    fn dropNatives(p: *Picture) void {
        if (free_native) |f| for (p.natives) |n| if (n != null) f(n);
        @memset(p.natives, null);
    }

    fn destroy(p: *Picture) void {
        p.img.deinit(gpa);
        gpa.free(p.natives);
        gpa.destroy(p);
    }
};

const Entry = struct {
    key: []u8,
    state: std.atomic.Value(State) = .init(.queued),
    refs: std.atomic.Value(u32) = .init(1),
    started: i64 = 0,
    // Set by the loading thread before it publishes `.ready`.
    pic: ?*Picture = null,
    svg_bytes: ?[]u8 = null,
    size: Size = .{ .w = 0, .h = 0 },
    // SVG renders at the on-screen size arrive here and are adopted on the UI thread.
    incoming: std.atomic.Value(?*Picture) = .init(null),
    rendering: std.atomic.Value(bool) = .init(false),
    failed_size: std.atomic.Value(u64) = .init(0),
    t0: i64 = 0,

    fn retain(e: *Entry) void {
        _ = e.refs.fetchAdd(1, .monotonic);
    }

    fn release(e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        if (e.pic) |p| p.destroy();
        if (e.incoming.load(.acquire)) |p| p.destroy();
        if (e.svg_bytes) |b| gpa.free(b);
        gpa.free(e.key);
        gpa.destroy(e);
    }
};

var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
var pending: std.ArrayList(*Entry) = .empty;
var base_dir: []const u8 = "";
var active: std.atomic.Value(u32) = .init(0);
var generation: std.atomic.Value(u32) = .init(0);
var seen_generation: u32 = 0;
var wake: ?u32 = null;

pub fn init(allocator: std.mem.Allocator, io_: std.Io) void {
    gpa = allocator;
    io = io_;
}

pub fn now() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

pub const Source = union(enum) { file: []const u8, https: []const u8, unsupported };

/// Where a Markdown image source points: relative paths are taken from `dir`, the folder of the document.
pub fn resolve(a: std.mem.Allocator, dir: []const u8, target: []const u8) std.mem.Allocator.Error!Source {
    const t = std.mem.trim(u8, target, " \t\r\n");
    if (t.len == 0) return .unsupported;
    if (schemeEnd(t)) |end| {
        const scheme = t[0..end];
        if (std.ascii.eqlIgnoreCase(scheme, "https")) return .{ .https = t };
        if (!std.ascii.eqlIgnoreCase(scheme, "file")) return .unsupported;
        var p = t[end + 1 ..];
        if (std.mem.startsWith(u8, p, "//")) p = p[2..];
        if (p.len > 2 and p[0] == '/' and p[2] == ':') p = p[1..];
        return .{ .file = try links.percentDecode(a, stripQuery(p)) };
    }
    const decoded = try links.percentDecode(a, stripQuery(t));
    if (std.fs.path.isAbsolute(decoded) or dir.len == 0) return .{ .file = decoded };
    return .{ .file = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, decoded }) };
}

fn stripQuery(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfAny(u8, s, "?#") orelse s.len];
}

fn schemeEnd(s: []const u8) ?usize {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return null;
    for (s, 0..) |ch, i| {
        if (ch == ':') return if (i >= 2) i else null;
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '.' and ch != '-') return null;
    }
    return null;
}

/// Scales down to `avail`, never up, keeping the aspect ratio.
pub fn fit(size: Size, avail: f32) Size {
    if (size.w <= 0 or size.h <= 0) return .{ .w = 0, .h = 0 };
    if (avail <= 0) return .{ .w = 0, .h = 0 };
    if (size.w <= avail) return size;
    return .{ .w = avail, .h = size.h * avail / size.w };
}

/// What an image takes up in a layout `avail` wide.
pub fn look(target: []const u8, avail: f32) Look {
    const e = get(target) orelse return .missing;
    return switch (e.state.load(.acquire)) {
        .queued, .loading => .pending,
        .failed => .missing,
        .ready => .{ .picture = fit(e.size, avail) },
    };
}

fn get(target: []const u8) ?*Entry {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = resolve(arena.allocator(), base_dir, target) catch return null;
    const key = switch (src) {
        .file, .https => |k| k,
        .unsupported => return null,
    };
    if (entries.get(key)) |e| return e;
    const e = gpa.create(Entry) catch return null;
    const owned = gpa.dupe(u8, key) catch {
        gpa.destroy(e);
        return null;
    };
    e.* = .{ .key = owned };
    entries.put(gpa, e.key, e) catch {
        e.release();
        return null;
    };
    pending.append(gpa, e) catch {
        _ = entries.remove(e.key);
        e.release();
        return null;
    };
    pump();
    return e;
}

fn pump() void {
    while (active.load(.monotonic) < max_threads and pending.items.len > 0) {
        const e = pending.orderedRemove(0);
        e.started = now();
        e.state.store(.loading, .release);
        e.retain();
        _ = active.fetchAdd(1, .monotonic);
        const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, work, .{e}) catch {
            _ = active.fetchSub(1, .monotonic);
            e.state.store(.failed, .release);
            e.release();
            continue;
        };
        t.detach();
    }
}

fn finish() void {
    _ = active.fetchSub(1, .monotonic);
    _ = generation.fetchAdd(1, .release);
}

fn work(e: *Entry) void {
    defer finish();
    defer e.release();
    if (loadInto(e)) {
        if (e.state.cmpxchgStrong(.loading, .ready, .release, .monotonic) == null) return;
    } else |_| {
        _ = e.state.cmpxchgStrong(.loading, .failed, .release, .monotonic);
        return;
    }
    // The UI gave up on this image (timeout) while it was loading.
    if (e.pic) |p| p.destroy();
    e.pic = null;
    if (e.svg_bytes) |b| gpa.free(b);
    e.svg_bytes = null;
}

fn loadInto(e: *Entry) !void {
    const bytes = if (std.ascii.startsWithIgnoreCase(e.key, "https://"))
        try fetch(e.key)
    else
        try std.Io.Dir.cwd().readFileAlloc(io, e.key, gpa, .limited(max_local));
    if (svg.isSvg(bytes)) {
        errdefer gpa.free(bytes);
        const s = try svg.intrinsicSize(bytes);
        e.size = .{ .w = s.w, .h = s.h };
        e.svg_bytes = bytes;
        return;
    }
    defer gpa.free(bytes);
    var img = try image.decode(gpa, bytes);
    errdefer img.deinit(gpa);
    e.size = .{ .w = @floatFromInt(img.width), .h = @floatFromInt(img.height) };
    e.pic = try Picture.create(img);
}

fn isRedirect(status: std.http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

/// HTTPS only, also across redirects.
fn fetch(url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var location_buf: [2048]u8 = undefined;
    var current = url;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops > max_redirects or !std.ascii.startsWithIgnoreCase(current, "https://")) return error.NotHttps;
        var req = try client.request(.GET, try std.Uri.parse(current), .{ .redirect_behavior = .unhandled });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [8192]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);
        if (isRedirect(resp.head.status)) {
            const loc = resp.head.location orelse return error.BadRedirect;
            if (loc.len > location_buf.len) return error.BadRedirect;
            @memcpy(location_buf[0..loc.len], loc);
            current = location_buf[0..loc.len];
            continue;
        }
        if (resp.head.status != .ok) return error.BadStatus;
        if (resp.head.content_length) |n| if (n > max_download) return error.TooLarge;
        var transfer: [4096]u8 = undefined;
        const body = resp.reader(&transfer);
        return body.allocRemaining(gpa, .limited(max_download));
    }
}

const Playback = struct { index: usize, remaining: u32 };

fn frameDelay(ms: u32) u32 {
    return if (ms <= 10) 100 else ms;
}

/// Which frame shows `elapsed` ms after the animation started, and how long until it changes.
fn playback(img: *const image.Image, elapsed: u64) Playback {
    var total: u64 = 0;
    for (img.frames) |f| total += frameDelay(f.delay_ms);
    if (img.frames.len < 2 or total == 0) return .{ .index = 0, .remaining = 0 };
    if (img.loop_count != 0 and elapsed >= total * img.loop_count) return .{ .index = img.frames.len - 1, .remaining = 0 };
    var t = elapsed % total;
    for (img.frames, 0..) |f, i| {
        const d = frameDelay(f.delay_ms);
        if (t < d) return .{ .index = i, .remaining = @intCast(d - t) };
        t -= d;
    }
    return .{ .index = 0, .remaining = 0 };
}

pub const Bitmap = struct { native: *anyopaque, w: u32, h: u32 };

/// The bitmap to draw for an image shown `box` big, or null while it is not ready. SVGs are re-rendered when `box` changes.
pub fn bitmap(target: []const u8, box: Size) ?Bitmap {
    const e = get(target) orelse return null;
    if (e.state.load(.acquire) != .ready) return null;
    if (e.svg_bytes != null) wantRender(e, box);
    const p = e.pic orelse return null;
    if (e.t0 == 0) e.t0 = now();
    const play = playback(&p.img, @intCast(@max(now() - e.t0, 0)));
    if (play.remaining > 0) wake = if (wake) |w| @min(w, play.remaining) else play.remaining;
    if (p.natives[play.index] == null) {
        const create = create_native orelse return null;
        p.natives[play.index] = create(p.img.frames[play.index].rgba, p.img.width, p.img.height);
    }
    return .{ .native = p.natives[play.index] orelse return null, .w = p.img.width, .h = p.img.height };
}

fn pixels(v: f32) u32 {
    return @intFromFloat(@max(1, @ceil(v * dpi_scale)));
}

fn wantRender(e: *Entry, box: Size) void {
    if (box.w <= 0 or box.h <= 0) return;
    const w = pixels(box.w);
    const h = pixels(box.h);
    if (e.pic) |p| if (p.img.width == w and p.img.height == h) return;
    const wanted = @as(u64, w) << 32 | h;
    if (e.failed_size.load(.monotonic) == wanted) return;
    if (e.rendering.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    e.retain();
    _ = active.fetchAdd(1, .monotonic);
    const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, renderWork, .{ e, w, h }) catch {
        _ = active.fetchSub(1, .monotonic);
        e.rendering.store(false, .release);
        e.release();
        return;
    };
    t.detach();
}

fn renderWork(e: *Entry, w: u32, h: u32) void {
    defer finish();
    defer e.release();
    defer e.rendering.store(false, .release);
    const bytes = e.svg_bytes orelse return;
    var img = svg.render(gpa, bytes, w, h) catch {
        e.failed_size.store(@as(u64, w) << 32 | h, .monotonic);
        return;
    };
    const p = Picture.create(img) catch {
        img.deinit(gpa);
        return;
    };
    if (e.incoming.swap(p, .acq_rel)) |old| old.destroy();
}

pub fn beginFrame() void {
    wake = null;
}

/// Milliseconds until something needs a redraw or a poll: the next animation frame, or soon while images are still loading.
pub fn timerDelay() ?u32 {
    if (wake) |w| return w;
    if (active.load(.monotonic) > 0 or pending.items.len > 0) return 40;
    return null;
}

/// Starts queued loads, adopts finished SVG renders and gives up on slow downloads. True when a redraw is due.
pub fn tick() bool {
    pump();
    const g = generation.load(.acquire);
    var changed = g != seen_generation;
    seen_generation = g;
    const t = now();
    var it = entries.valueIterator();
    while (it.next()) |slot| {
        const e = slot.*;
        if (e.incoming.swap(null, .acquire)) |np| {
            if (e.pic) |old| {
                old.dropNatives();
                old.destroy();
            }
            e.pic = np;
            changed = true;
        }
        if (e.state.load(.acquire) == .loading and t - e.started > timeout_ms) {
            if (e.state.cmpxchgStrong(.loading, .failed, .release, .monotonic) == null) changed = true;
        }
    }
    return changed or wake != null;
}

/// Starts a new document: local images are dropped so they load again, remote ones stay when `keep_remote`.
pub fn reset(dir: []const u8, keep_remote: bool) void {
    gpa.free(base_dir);
    base_dir = gpa.dupe(u8, dir) catch "";
    var drop: std.ArrayList(*Entry) = .empty;
    defer drop.deinit(gpa);
    var it = entries.valueIterator();
    while (it.next()) |slot| {
        const e = slot.*;
        const remote = std.ascii.startsWithIgnoreCase(e.key, "https://");
        if (keep_remote and remote and e.state.load(.acquire) != .failed) continue;
        drop.append(gpa, e) catch return;
    }
    for (drop.items) |e| {
        _ = entries.remove(e.key);
        if (std.mem.indexOfScalar(*Entry, pending.items, e)) |i| _ = pending.orderedRemove(i);
        if (e.state.load(.acquire) == .ready) if (e.pic) |p| p.dropNatives();
        e.release();
    }
}

const testing = std.testing;

/// Layout tests use this to get a loaded image of a known size without a decoder.
pub fn injectReady(key: []const u8, w: f32, h: f32) !void {
    const e = try gpa.create(Entry);
    e.* = .{ .key = try gpa.dupe(u8, key), .size = .{ .w = w, .h = h } };
    const pw: u32 = @intFromFloat(w);
    const ph: u32 = @intFromFloat(h);
    const rgba = try gpa.alloc(u8, @as(usize, pw) * ph * 4);
    @memset(rgba, 255);
    const frames = try gpa.alloc(image.Frame, 1);
    frames[0] = .{ .rgba = rgba, .delay_ms = 0 };
    e.pic = try Picture.create(.{ .width = pw, .height = ph, .frames = frames, .loop_count = 0 });
    e.state.store(.ready, .release);
    try entries.put(gpa, e.key, e);
}

/// Frees what tests left behind once their loads have ended.
pub fn clearAll() void {
    reset("", false);
    while (active.load(.monotonic) > 0) std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
    entries.deinit(gpa);
    pending.deinit(gpa);
    entries = .empty;
    pending = .empty;
}

fn expectFile(dir: []const u8, target: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try resolve(arena.allocator(), dir, target);
    try testing.expectEqualStrings(want, src.file);
}

test "relative paths are taken from the document folder" {
    try expectFile("/docs", "pics/a.png", "/docs/pics/a.png");
    try expectFile("/docs", "pics/a%20b.png?raw=1#x", "/docs/pics/a b.png");
    try expectFile("", "a.png", "a.png");
    try expectFile("/docs", "/abs/a.png", "/abs/a.png");
}

test "file urls and other schemes" {
    try expectFile("/docs", "file:///abs/a.png", "/abs/a.png");
    try expectFile("/docs", "file:///C:/pics/a.png", "C:/pics/a.png");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("HTTPS://x.org/a.png", (try resolve(a, "/docs", "HTTPS://x.org/a.png")).https);
    try testing.expect((try resolve(a, "/docs", "http://x.org/a.png")) == .unsupported);
    try testing.expect((try resolve(a, "/docs", "data:image/png;base64,AAAA")) == .unsupported);
    try testing.expect((try resolve(a, "/docs", "")) == .unsupported);
}

test "images scale down to the width and never up" {
    const big = fit(.{ .w = 800, .h = 400 }, 400);
    try testing.expectEqual(@as(f32, 400), big.w);
    try testing.expectEqual(@as(f32, 200), big.h);
    const small = fit(.{ .w = 100, .h = 50 }, 400);
    try testing.expectEqual(@as(f32, 100), small.w);
    try testing.expectEqual(@as(f32, 50), small.h);
    try testing.expectEqual(@as(f32, 0), fit(.{ .w = 0, .h = 5 }, 400).w);
}

test "animation frames follow their delays and loop count" {
    var frames = [_]image.Frame{ .{ .rgba = &.{}, .delay_ms = 100 }, .{ .rgba = &.{}, .delay_ms = 200 } };
    var img: image.Image = .{ .width = 1, .height = 1, .frames = &frames, .loop_count = 0 };
    try testing.expectEqual(@as(usize, 0), playback(&img, 0).index);
    try testing.expectEqual(@as(u32, 50), playback(&img, 50).remaining);
    try testing.expectEqual(@as(usize, 1), playback(&img, 100).index);
    try testing.expectEqual(@as(usize, 0), playback(&img, 300).index);
    try testing.expectEqual(@as(usize, 1), playback(&img, 450).index);
    img.loop_count = 2;
    try testing.expectEqual(@as(usize, 1), playback(&img, 600).index);
    try testing.expectEqual(@as(u32, 0), playback(&img, 600).remaining);
    frames[0].delay_ms = 0;
    try testing.expectEqual(@as(u32, 100), playback(&img, 0).remaining);
}

test "a missing local file ends as missing and an http one never loads" {
    init(testing.allocator, testing.io);
    reset("/no/such/dir", false);
    defer clearAll();
    try testing.expect(look("nothing.png", 100) != .missing);
    try testing.expect(look("http://x.org/a.png", 100) == .missing);
    const deadline = now() + 5000;
    while (now() < deadline) {
        _ = tick();
        if (look("nothing.png", 100) == .missing) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
    }
    try testing.expect(look("nothing.png", 100) == .missing);
}
