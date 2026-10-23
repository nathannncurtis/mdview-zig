const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");

const worker_stack = 1 << 20;
const seconds_per_file = 30;
const bytes_per_input_byte = 400;
const bytes_base = 64 << 20;

const Tracking = struct {
    backing: Allocator,
    current: usize = 0,
    peak: usize = 0,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(t: *Tracking) Allocator {
        return .{ .ptr = t, .vtable = &vtable };
    }

    fn grow(t: *Tracking, by: usize) void {
        t.current += by;
        t.peak = @max(t.peak, t.current);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const t: *Tracking = @ptrCast(@alignCast(ctx));
        const p = t.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        t.grow(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const t: *Tracking = @ptrCast(@alignCast(ctx));
        if (!t.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        t.current -= memory.len;
        t.grow(new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const t: *Tracking = @ptrCast(@alignCast(ctx));
        const p = t.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        t.current -= memory.len;
        t.grow(new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const t: *Tracking = @ptrCast(@alignCast(ctx));
        t.backing.rawFree(memory, alignment, ret_addr);
        t.current -= memory.len;
    }
};

const Job = struct {
    input: []const u8,
    tracking: Tracking,
    blocks: usize = 0,
    failed: ?anyerror = null,
};

fn work(job: *Job) void {
    var doc = markdown.parse(job.tracking.allocator(), job.input) catch |err| {
        job.failed = err;
        return;
    };
    job.blocks = doc.blocks.len;
    doc.deinit();
}

var deadline_ms: std.atomic.Value(i64) = .init(std.math.maxInt(i64));
var current_name: [256]u8 = undefined;
var current_len: std.atomic.Value(usize) = .init(0);

fn watchdog(io: std.Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch return;
        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now > deadline_ms.load(.acquire)) {
            std.debug.print("HANG: {s} exceeded {d} s\n", .{ current_name[0..current_len.load(.acquire)], seconds_per_file });
            std.process.exit(2);
        }
    }
}

fn limitBytes(size: usize) usize {
    return size * bytes_per_input_byte + bytes_base;
}

test "stress files parse within time and memory limits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    const dir_path = env.get("MDVIEW_STRESS_DIR") orelse return error.SkipZigTest;

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try std.testing.expect(names.items.len > 0);

    const dog = try std.Thread.spawn(.{}, watchdog, .{io});
    dog.detach();

    const only = env.get("MDVIEW_STRESS_ONLY");
    var slowest_ms: i64 = 0;
    var failures: usize = 0;
    std.debug.print("\n{s:<36} {s:>10} {s:>8} {s:>10} {s:>7}\n", .{ "file", "bytes", "ms", "peak MiB", "blocks" });
    for (names.items) |name| {
        if (only) |o| if (std.mem.find(u8, name, o) == null) continue;
        const input = try dir.readFileAlloc(io, name, gpa, .unlimited);
        defer gpa.free(input);

        @memcpy(current_name[0..name.len], name);
        current_len.store(name.len, .release);
        var job: Job = .{ .input = input, .tracking = .{ .backing = std.heap.smp_allocator } };
        const start = std.Io.Timestamp.now(io, .awake);
        deadline_ms.store(start.toMilliseconds() + seconds_per_file * std.time.ms_per_s, .release);
        const thread = try std.Thread.spawn(.{ .stack_size = worker_stack }, work, .{&job});
        thread.join();
        deadline_ms.store(std.math.maxInt(i64), .release);
        const ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        slowest_ms = @max(slowest_ms, ms);

        std.debug.print("{s:<36} {d:>10} {d:>8} {d:>10.1} {d:>7}\n", .{
            name, input.len, ms, @as(f64, @floatFromInt(job.tracking.peak)) / (1 << 20), job.blocks,
        });
        if (job.failed) |err| {
            std.debug.print("  FAIL {s}: {t}\n", .{ name, err });
            failures += 1;
        }
        if (job.tracking.peak > limitBytes(input.len)) {
            std.debug.print("  FAIL {s}: peak {d} bytes exceeds {d}\n", .{ name, job.tracking.peak, limitBytes(input.len) });
            failures += 1;
        }
    }
    std.debug.print("slowest file: {d} ms\n", .{slowest_ms});
    try std.testing.expectEqual(@as(usize, 0), failures);
}
