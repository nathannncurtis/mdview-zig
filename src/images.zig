const std = @import("std");
const builtin = @import("builtin");
const image = @import("image/image.zig");
const svg = @import("image/svg.zig");
const links = @import("links.zig");
const scale = @import("scale.zig");
const md = @import("markdown.zig");

pub const max_download: usize = 20 * 1024 * 1024;
pub const max_local: usize = 128 * 1024 * 1024;
pub const timeout_ms: i64 = 10_000;
/// Larger pictures are shrunk when they load, so every bitmap stays under what a GPU texture holds.
pub const max_texture: u32 = 8192;
const max_threads = 4;
const max_redirects = 3;

// SAFETY: set by init before the first image is requested
pub var gpa: std.mem.Allocator = undefined;
// SAFETY: set by init before the first image is requested
pub var io: std.Io = undefined;
/// Device pixels per layout unit, used to pick the size pictures are shrunk or rendered at.
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
    fallback: ?[]u8 = null,
    state: std.atomic.Value(State) = .init(.queued),
    refs: std.atomic.Value(u32) = .init(1),
    started: i64 = 0,
    // Set by the loading thread before it publishes `.ready`.
    base: ?*Picture = null,
    svg_bytes: ?[]u8 = null,
    size: Size = .{ .w = 0, .h = 0 },
    // The picture at the on-screen size (an SVG render or a shrunk copy) arrives here and is adopted on the UI thread.
    pic: ?*Picture = null,
    incoming: std.atomic.Value(?*Picture) = .init(null),
    rendering: std.atomic.Value(bool) = .init(false),
    failed_size: std.atomic.Value(u64) = .init(0),
    t0: i64 = 0,

    fn retain(e: *Entry) void {
        _ = e.refs.fetchAdd(1, .monotonic);
    }

    fn release(e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        if (e.base) |p| p.destroy();
        if (e.pic) |p| p.destroy();
        if (e.incoming.load(.acquire)) |p| p.destroy();
        if (e.svg_bytes) |b| gpa.free(b);
        if (e.fallback) |f| gpa.free(f);
        gpa.free(e.key);
        gpa.destroy(e);
    }

    fn dropNatives(e: *Entry) void {
        if (e.base) |p| p.dropNatives();
        if (e.pic) |p| p.dropNatives();
    }
};

var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
var pending: std.ArrayList(*Entry) = .empty;
var base_dir: []const u8 = "";
var base_root: []const u8 = "";
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

pub const Source = union(enum) { file: struct { path: []const u8, fallback: ?[]const u8 = null }, https: []const u8, unsupported };

fn join(a: std.mem.Allocator, base: []const u8, rel: []const u8) std.mem.Allocator.Error![]const u8 {
    if (base.len == 0) return rel;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, rel });
}

fn isRootRelative(p: []const u8) bool {
    if (p.len == 0 or (p[0] != '/' and p[0] != '\\')) return false;
    return !(p.len > 1 and (p[1] == '/' or p[1] == '\\'));
}

/// Where a Markdown image source points. Relative paths are taken from `dir`, the folder of the document;
/// a leading `/` is taken from `root`, the repository the document is in, as GitHub does, with the path as written as the fallback.
pub fn resolve(a: std.mem.Allocator, dir: []const u8, root: []const u8, target: []const u8) std.mem.Allocator.Error!Source {
    const t = std.mem.trim(u8, target, " \t\r\n");
    if (t.len == 0) return .unsupported;
    if (schemeEnd(t)) |end| {
        const scheme = t[0..end];
        if (std.ascii.eqlIgnoreCase(scheme, "https")) return .{ .https = t };
        if (!std.ascii.eqlIgnoreCase(scheme, "file")) return .unsupported;
        var p = t[end + 1 ..];
        if (std.mem.startsWith(u8, p, "//")) p = p[2..];
        if (p.len > 2 and p[0] == '/' and p[2] == ':') p = p[1..];
        return .{ .file = .{ .path = try links.percentDecode(a, stripQuery(p)) } };
    }
    const decoded = try links.percentDecode(a, stripQuery(t));
    if (isRootRelative(decoded)) return .{ .file = .{ .path = try join(a, root, decoded[1..]), .fallback = decoded } };
    if (std.fs.path.isAbsolute(decoded)) return .{ .file = .{ .path = decoded } };
    return .{ .file = .{ .path = try join(a, dir, decoded) } };
}

/// The nearest folder at or above `dir` that holds `.git` (a folder, or a file in a worktree); `dir` itself when there is none.
pub fn findRepoRoot(a: std.mem.Allocator, dir: []const u8) std.mem.Allocator.Error![]const u8 {
    var cur: []const u8 = dir;
    for (0..40) |_| {
        const probe = if (cur.len == 0) ".git" else try std.fmt.allocPrint(a, "{s}/.git", .{cur});
        if (std.Io.Dir.cwd().access(io, probe, .{})) |_| return cur else |_| {}
        cur = try parentOf(a, cur) orelse break;
    }
    return dir;
}

fn parentOf(a: std.mem.Allocator, cur: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (std.fs.path.isAbsolute(cur)) return std.fs.path.dirname(cur);
    if (cur.len == 0 or std.mem.eql(u8, cur, ".")) return "..";
    if (std.mem.eql(u8, std.fs.path.basename(cur), "..")) return try std.fmt.allocPrint(a, "{s}/..", .{cur});
    return std.fs.path.dirname(cur) orelse "";
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

/// The size an `<img>` with `width` and `height` attributes takes (zero means unset): one attribute scales the other by the
/// aspect ratio, both are used as given, and the result is capped to `avail` with its own aspect ratio. Upscaling is allowed.
pub fn requested(natural: Size, width: f32, height: f32, avail: f32) Size {
    if (natural.w <= 0 or natural.h <= 0 or avail <= 0) return .{ .w = 0, .h = 0 };
    var s = natural;
    if (width > 0 and height > 0) {
        s = .{ .w = width, .h = height };
    } else if (width > 0) {
        s = .{ .w = width, .h = natural.h * width / natural.w };
    } else if (height > 0) {
        s = .{ .w = natural.w * height / natural.h, .h = height };
    }
    return fit(s, avail);
}

const Status = enum { pending, ready, missing };

fn status(target: []const u8) struct { Status, ?*Entry } {
    const e = get(target) orelse return .{ .missing, null };
    return .{ switch (e.state.load(.acquire)) {
        .queued, .loading => .pending,
        .failed => .missing,
        .ready => .ready,
    }, e };
}

/// What an image takes up in a layout `avail` wide.
pub fn look(target: []const u8, avail: f32) Look {
    const s, const e = status(target);
    return switch (s) {
        .pending => .pending,
        .missing => .missing,
        .ready => .{ .picture = fit(e.?.size, avail) },
    };
}

fn get(target: []const u8) ?*Entry {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = resolve(arena.allocator(), base_dir, base_root, target) catch return null;
    const key, const fallback = switch (src) {
        .file => |f| .{ f.path, f.fallback },
        .https => |u| .{ u, null },
        .unsupported => return null,
    };
    if (entries.get(key)) |e| return e;
    const e = gpa.create(Entry) catch return null;
    const owned = gpa.dupe(u8, key) catch {
        gpa.destroy(e);
        return null;
    };
    e.* = .{ .key = owned };
    if (fallback) |f| e.fallback = gpa.dupe(u8, f) catch null;
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
    if (e.base) |p| p.destroy();
    e.base = null;
    if (e.svg_bytes) |b| gpa.free(b);
    e.svg_bytes = null;
}

fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_local));
}

fn loadInto(e: *Entry) !void {
    const bytes = if (std.ascii.startsWithIgnoreCase(e.key, "https://"))
        try fetchTimed(e.key, timeout_ms)
    else
        readFile(e.key) catch |err| blk: {
            const fb = e.fallback orelse return err;
            break :blk try readFile(fb);
        };
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
    if (img.width > max_texture or img.height > max_texture) {
        const small = try shrinkImage(&img, @min(img.width, max_texture), @min(img.height, max_texture));
        img.deinit(gpa);
        img = small;
    }
    e.size = .{ .w = @floatFromInt(img.width), .h = @floatFromInt(img.height) };
    e.base = try Picture.create(img);
}

/// A copy of `src` with every frame shrunk to fit inside `w` x `h`, keeping the aspect ratio.
fn shrinkImage(src: *const image.Image, w: u32, h: u32) !image.Image {
    const ratio = @min(@as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(src.width)), @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(src.height)));
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(src.width)) * ratio)));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(src.height)) * ratio)));
    return shrinkTo(src, @min(dw, src.width), @min(dh, src.height));
}

fn shrinkTo(src: *const image.Image, dw: u32, dh: u32) !image.Image {
    const frames = try gpa.alloc(image.Frame, src.frames.len);
    var done: usize = 0;
    errdefer {
        for (frames[0..done]) |f| gpa.free(f.rgba);
        gpa.free(frames);
    }
    for (src.frames, frames) |f, *out| {
        out.* = .{ .rgba = try scale.shrink(gpa, f.rgba, src.width, src.height, dw, dh), .delay_ms = f.delay_ms };
        done += 1;
    }
    return .{ .width = dw, .height = dh, .frames = frames, .loop_count = src.loop_count };
}

fn isRedirect(status_: std.http.Status) bool {
    return switch (status_) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

/// HTTPS only, also across redirects.
fn fetch(url: []const u8) anyerror![]u8 {
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

const Raced = union(enum) { body: anyerror![]u8, timeout: void };

fn pause(io_: std.Io, ms: i64) void {
    std.Io.sleep(io_, .fromMilliseconds(ms), .awake) catch return;
}

/// Runs `fetch` against a timer; when the timer wins the fetch is cancelled, which ends its blocked connect or read.
fn fetchTimed(url: []const u8, ms: i64) anyerror![]u8 {
    var buf: [2]Raced = undefined;
    var race = std.Io.Select(Raced).init(io, &buf);
    race.concurrent(.body, fetch, .{url}) catch return error.NoConcurrency;
    race.concurrent(.timeout, pause, .{ io, ms }) catch {
        drain(&race);
        return error.NoConcurrency;
    };
    const first = race.await() catch {
        drain(&race);
        return error.Canceled;
    };
    switch (first) {
        .body => |r| {
            race.cancelDiscard();
            return r;
        },
        .timeout => {
            drain(&race);
            return error.Timeout;
        },
    }
}

fn drain(race: *std.Io.Select(Raced)) void {
    while (race.cancel()) |left| switch (left) {
        .body => |r| if (r) |bytes| gpa.free(bytes) else |_| {},
        .timeout => {},
    };
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

/// The bitmap to draw for an image shown `box` big, or null while it is not ready. Pictures shown smaller than they are
/// get a copy shrunk to the on-screen size, and SVGs are rendered at it, again whenever `box` changes.
pub fn bitmap(target: []const u8, box: Size) ?Bitmap {
    const e = get(target) orelse return null;
    if (e.state.load(.acquire) != .ready) return null;
    wantSized(e, box);
    const p = e.pic orelse e.base orelse return null;
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

fn wantSized(e: *Entry, box: Size) void {
    if (box.w <= 0 or box.h <= 0) return;
    var w = pixels(box.w);
    var h = pixels(box.h);
    if (e.base) |b| {
        w = @min(w, b.img.width);
        h = @min(h, b.img.height);
        if (w == b.img.width and h == b.img.height) {
            if (e.pic) |old| {
                old.dropNatives();
                old.destroy();
                e.pic = null;
            }
            return;
        }
    }
    if (e.pic) |p| if (p.img.width == w and p.img.height == h) return;
    const wanted = @as(u64, w) << 32 | h;
    if (e.failed_size.load(.monotonic) == wanted) return;
    if (e.rendering.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    e.retain();
    _ = active.fetchAdd(1, .monotonic);
    const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, sizedWork, .{ e, w, h }) catch {
        _ = active.fetchSub(1, .monotonic);
        e.rendering.store(false, .release);
        e.release();
        return;
    };
    t.detach();
}

fn sizedWork(e: *Entry, w: u32, h: u32) void {
    defer finish();
    defer e.release();
    defer e.rendering.store(false, .release);
    var img = (if (e.base) |b| shrinkTo(&b.img, w, h) else if (e.svg_bytes) |bytes| svg.render(gpa, bytes, w, h) else return) catch {
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
    for (retired.items) |f| f.destroy();
    retired.clearRetainingCapacity();
}

/// Milliseconds until something needs a redraw or a poll: the next animation frame, or soon while images are still loading.
pub fn timerDelay() ?u32 {
    if (wake) |w| return w;
    if (active.load(.monotonic) > 0 or pending.items.len > 0) return 40;
    return null;
}

/// Starts queued loads, adopts finished sized pictures and gives up on slow downloads. True when a redraw is due.
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
    gpa.free(base_root);
    base_dir = gpa.dupe(u8, dir) catch "";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = findRepoRoot(arena.allocator(), dir) catch dir;
    base_root = gpa.dupe(u8, root) catch "";
    dropFlows();
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
        if (e.state.load(.acquire) == .ready) e.dropNatives();
        e.release();
    }
}

const FlowKey = struct { ptr: usize, len: usize };

/// A copy of an inline in which each image that cannot load is followed by its alt text, so the alt text flows with the line.
const Flow = struct {
    arena: std.heap.ArenaAllocator,
    missing: []bool,
    content: md.Inline,

    fn destroy(f: *Flow) void {
        var arena = f.arena;
        gpa.destroy(f);
        arena.deinit();
    }
};

var flows: std.AutoHashMapUnmanaged(FlowKey, *Flow) = .empty;
var retired: std.ArrayList(*Flow) = .empty;

fn dropFlows() void {
    var it = flows.valueIterator();
    while (it.next()) |f| f.*.destroy();
    flows.clearRetainingCapacity();
    for (retired.items) |f| f.destroy();
    retired.clearRetainingCapacity();
}

fn showsAlt(im: md.Image) bool {
    return im.alt.len > 0 and status(im.target)[0] == .missing;
}

/// `c` with the alt text of its missing images laid into the text. Offsets of every span are moved to match, so the result is used
/// for layout, hit testing and hover in place of `c`. Content without missing images comes back unchanged.
pub fn flow(c: md.Inline) md.Inline {
    if (c.images.len == 0) return c;
    var any = false;
    for (c.images) |im| any = any or showsAlt(im);
    if (!any) {
        if (flows.fetchRemove(.{ .ptr = @intFromPtr(c.text.ptr), .len = c.text.len })) |old| retired.append(gpa, old.value) catch old.value.destroy();
        return c;
    }
    const key: FlowKey = .{ .ptr = @intFromPtr(c.text.ptr), .len = c.text.len };
    if (flows.get(key)) |f| {
        var same = f.missing.len == c.images.len;
        if (same) for (c.images, f.missing) |im, was| {
            same = same and showsAlt(im) == was;
        };
        if (same) return f.content;
        _ = flows.remove(key);
        retired.append(gpa, f) catch f.destroy();
    }
    const f = buildFlow(c) catch return c;
    flows.put(gpa, key, f) catch {
        f.destroy();
        return c;
    };
    return f.content;
}

fn buildFlow(c: md.Inline) !*Flow {
    const f = try gpa.create(Flow);
    f.arena = .init(gpa);
    errdefer f.destroy();
    const a = f.arena.allocator();
    f.missing = try a.alloc(bool, c.images.len);
    const order = try a.alloc(usize, c.images.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, c.images, struct {
        fn less(images: []const md.Image, x: usize, y: usize) bool {
            return images[x].start < images[y].start;
        }
    }.less);
    var text: std.ArrayList(u8) = .empty;
    var ends: std.ArrayList([2]u32) = .empty;
    var pos: usize = 0;
    for (c.images, f.missing) |im, *m| m.* = showsAlt(im);
    for (order) |i| {
        const im = c.images[i];
        if (!f.missing[i] or im.start < pos) continue;
        const end = im.start + im.len;
        try text.appendSlice(a, c.text[pos..end]);
        try text.appendSlice(a, im.alt);
        try ends.append(a, .{ @intCast(end), @intCast(im.alt.len) });
        pos = end;
    }
    try text.appendSlice(a, c.text[pos..]);
    const map = struct {
        fn at(list: []const [2]u32, p: u32) u32 {
            var out = p;
            for (list) |e| {
                if (e[0] <= p) out += e[1] else break;
            }
            return out;
        }
    }.at;
    var out: md.Inline = .{ .text = text.items };
    inline for (.{ "bold", "italic", "code", "strike", "emoji", "sup" }) |name| {
        const src = @field(c, name);
        const moved = try a.alloc(md.Span, src.len);
        for (src, moved) |s, *m| {
            const start = map(ends.items, s[0]);
            m.* = .{ start, map(ends.items, s[0] + s[1]) - start };
        }
        @field(out, name) = moved;
    }
    const moved_links = try a.alloc(md.Link, c.links.len);
    for (c.links, moved_links) |l, *m| {
        const start = map(ends.items, l.start);
        m.* = l;
        m.start = start;
        m.len = map(ends.items, l.start + l.len) - start;
    }
    out.links = moved_links;
    const moved_images = try a.alloc(md.Image, c.images.len);
    for (c.images, moved_images) |im, *m| {
        m.* = im;
        m.start = map(ends.items, im.start);
    }
    out.images = moved_images;
    f.content = out;
    return f;
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
    e.base = try Picture.create(.{ .width = pw, .height = ph, .frames = frames, .loop_count = 0 });
    e.state.store(.ready, .release);
    try entries.put(gpa, e.key, e);
}

/// Frees what tests left behind once their loads have ended.
pub fn clearAll() void {
    reset("", false);
    while (active.load(.monotonic) > 0) std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
    beginFrame();
    entries.deinit(gpa);
    pending.deinit(gpa);
    flows.deinit(gpa);
    retired.deinit(gpa);
    entries = .empty;
    pending = .empty;
    flows = .empty;
    retired = .empty;
    gpa.free(base_dir);
    gpa.free(base_root);
    base_dir = "";
    base_root = "";
}

fn expectFile(dir: []const u8, root: []const u8, target: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try resolve(arena.allocator(), dir, root, target);
    try testing.expectEqualStrings(want, src.file.path);
}

test "relative paths are taken from the document folder" {
    try expectFile("/docs", "/docs", "pics/a.png", "/docs/pics/a.png");
    try expectFile("/docs", "/docs", "pics/a%20b.png?raw=1#x", "/docs/pics/a b.png");
    try expectFile("", "", "a.png", "a.png");
    try expectFile("/docs/sub", "/docs", "../a.png", "/docs/sub/../a.png");
}

test "a leading slash is taken from the repository root and falls back to the path as written" {
    try expectFile("/repo/docs", "/repo", "/img/a.png", "/repo/img/a.png");
    try expectFile("docs", "", "/img/a.png", "img/a.png");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try resolve(arena.allocator(), "/repo/docs", "/repo", "/img/a.png");
    try testing.expectEqualStrings("/img/a.png", src.file.fallback.?);
    try expectFile("/docs", "/docs", "//host/share/a.png", "//host/share/a.png");
    try expectFile("/docs", "/docs", "C:/pics/a.png", if (builtin.os.tag == .windows) "C:/pics/a.png" else "/docs/C:/pics/a.png");
}

test "file urls and other schemes" {
    try expectFile("/docs", "/docs", "file:///abs/a.png", "/abs/a.png");
    try expectFile("/docs", "/docs", "file:///C:/pics/a.png", "C:/pics/a.png");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("HTTPS://x.org/a.png", (try resolve(a, "/docs", "/docs", "HTTPS://x.org/a.png")).https);
    try testing.expect((try resolve(a, "/docs", "/docs", "http://x.org/a.png")) == .unsupported);
    try testing.expect((try resolve(a, "/docs", "/docs", "data:image/png;base64,AAAA")) == .unsupported);
    try testing.expect((try resolve(a, "/docs", "/docs", "")) == .unsupported);
}

test "the repository root is the nearest folder with .git, a folder or a file" {
    init(testing.allocator, testing.io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git", .data = "gitdir: x" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &buf);
    const base = buf[0..base_len];
    const inside = try std.fmt.allocPrint(a, "{s}/repo/a/b", .{base});
    const root = try findRepoRoot(a, inside);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/repo", .{base}), root);
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

test "requested sizes follow the CSS rules for width and height attributes" {
    const nat: Size = .{ .w = 200, .h = 100 };
    const w_only = requested(nat, 400, 0, 1000);
    try testing.expectEqual(@as(f32, 400), w_only.w);
    try testing.expectEqual(@as(f32, 200), w_only.h);
    const h_only = requested(nat, 0, 50, 1000);
    try testing.expectEqual(@as(f32, 100), h_only.w);
    try testing.expectEqual(@as(f32, 50), h_only.h);
    const both = requested(nat, 30, 90, 1000);
    try testing.expectEqual(@as(f32, 30), both.w);
    try testing.expectEqual(@as(f32, 90), both.h);
    const capped = requested(nat, 400, 0, 100);
    try testing.expectEqual(@as(f32, 100), capped.w);
    try testing.expectEqual(@as(f32, 50), capped.h);
    const capped_both = requested(nat, 400, 100, 200);
    try testing.expectEqual(@as(f32, 200), capped_both.w);
    try testing.expectEqual(@as(f32, 50), capped_both.h);
    const unset = requested(nat, 0, 0, 1000);
    try testing.expectEqual(@as(f32, 200), unset.w);
    try testing.expectEqual(@as(f32, 0), requested(.{ .w = 0, .h = 0 }, 10, 10, 100).w);
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

fn waitMissing(target: []const u8) !void {
    const deadline = now() + 5000;
    while (now() < deadline) {
        _ = tick();
        if (look(target, 400) == .missing) return;
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch break;
    }
    return error.Timeout;
}

test "a missing local file ends as missing and an http one never loads" {
    init(testing.allocator, testing.io);
    reset("no-such-dir", false);
    defer clearAll();
    try testing.expect(look("nothing.png", 100) != .missing);
    try testing.expect(look("http://x.org/a.png", 100) == .missing);
    try waitMissing("nothing.png");
}

test "a download that never answers is cancelled when the timer ends" {
    init(testing.allocator, testing.io);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/x.png", .{server.socket.address.getPort()});
    const start = now();
    try testing.expectError(error.Timeout, fetchTimed(url, 1500));
    try testing.expect(now() - start < 6000);
}

test "a missing image shows its alt text in the flow, with every span moved to match" {
    init(testing.allocator, testing.io);
    reset("no-such-dir", false);
    defer clearAll();
    var doc = try md.parse(testing.allocator, "a **b ![alt one](gone.png)** [![two](gone.png) c](/u) d");
    defer doc.deinit();
    const c = doc.blocks[0].content;
    try testing.expectEqual(c.text.ptr, flow(c).text.ptr);
    try testing.expectEqualStrings(c.text, flow(c).text);
    try waitMissing("gone.png");
    const f = flow(c);
    try testing.expectEqualStrings("a b \u{fffc}alt one \u{fffc}two c d", f.text);
    try testing.expectEqual(@as(usize, 1), f.bold.len);
    try testing.expectEqualStrings("b \u{fffc}alt one", f.text[f.bold[0][0]..][0..f.bold[0][1]]);
    try testing.expectEqualStrings("\u{fffc}two c", f.text[f.links[0].start..][0..f.links[0].len]);
    try testing.expectEqual(@as(u32, 3), f.images[0].len);
    try testing.expect(f.imageAt(f.images[1].start) != null);
    try testing.expect(f.linkAt(f.images[1].start) != null);
    try testing.expectEqual(f.text.ptr, flow(c).text.ptr);
}
