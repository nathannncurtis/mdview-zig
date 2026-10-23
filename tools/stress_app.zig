const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = @import("files.zig");

const windows = builtin.os.tag == .windows;

const win = struct {
    const HWND = ?*anyopaque;
    const Enum = *const fn (HWND, isize) callconv(.c) i32;
    extern "user32" fn EnumWindows(cb: Enum, lparam: isize) callconv(.c) i32;
    extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, pid: *u32) callconv(.c) u32;
    extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.c) i32;
    extern "user32" fn IsIconic(hwnd: HWND) callconv(.c) i32;
    extern "user32" fn SetWindowPos(hwnd: HWND, after: HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.c) i32;
    extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(.c) i32;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, ms: u32) callconv(.c) u32;
    extern "kernel32" fn TerminateProcess(handle: *anyopaque, code: u32) callconv(.c) i32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.c) i32;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: [*:0]const u16) callconv(.c) i32;
    extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: i32, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *StartupInfo, pi: *ProcessInfo) callconv(.c) i32;

    const StartupInfo = extern struct {
        cb: u32, reserved: ?[*:0]u16 = null, desktop: ?[*:0]u16 = null, title: ?[*:0]u16 = null,
        x: u32 = 0, y: u32 = 0, x_size: u32 = 0, y_size: u32 = 0, x_chars: u32 = 0, y_chars: u32 = 0, fill: u32 = 0,
        flags: u32 = 0, show_window: u16 = 0, reserved2: u16 = 0, reserved3: ?*u8 = null,
        std_input: ?*anyopaque = null, std_output: ?*anyopaque = null, std_error: ?*anyopaque = null,
    };
    const ProcessInfo = extern struct { process: ?*anyopaque, thread: ?*anyopaque, pid: u32, tid: u32 };

    /// Starts the exe minimized without activating it; the process handle and pid come back.
    fn startMinimized(gpa: Allocator, exe: []const u8, file: []const u8, data_env: []const u8) !ProcessInfo {
        const cmd = try std.unicode.utf8ToUtf16LeAllocZ(gpa, try std.fmt.allocPrint(gpa, "\"{s}\" \"{s}\"", .{ exe, file }));
        const value = try std.unicode.utf8ToUtf16LeAllocZ(gpa, data_env);
        if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), value) == 0) return error.SetEnvironment;
        var si: StartupInfo = .{ .cb = @sizeOf(StartupInfo), .flags = 0x1, .show_window = 7 };
        // SAFETY: filled by CreateProcessW
        var pi: ProcessInfo = undefined;
        if (CreateProcessW(null, cmd, null, null, 0, 0, null, null, &si, &pi) == 0) return error.CreateProcess;
        _ = CloseHandle(pi.thread.?);
        return pi;
    }

    const wm_size = 0x0005;
    const wm_mousewheel = 0x020A;
    const swp_flags = 0x0004 | 0x0010;

    const Find = struct { pid: u32, found: HWND = null };

    fn visit(hwnd: HWND, lparam: isize) callconv(.c) i32 {
        const target: *Find = @ptrFromInt(@as(usize, @bitCast(lparam)));
        var pid: u32 = 0;
        _ = GetWindowThreadProcessId(hwnd, &pid);
        if (pid != target.pid or IsWindowVisible(hwnd) == 0) return 1;
        target.found = hwnd;
        return 0;
    }

    fn find(pid: u32) HWND {
        var f: Find = .{ .pid = pid };
        _ = EnumWindows(visit, @bitCast(@intFromPtr(&f)));
        return f.found;
    }
};

const Options = struct {
    exe: []const u8,
    stress_dir: []const u8,
    work_dir: []const u8,
    hold_seconds: u64 = 10,
    parallel: usize = 8,
    parse_timeout_seconds: u64 = 120,
    hammer_writes: usize = 200,
    hammer_seconds: u64 = 20,
    only: ?[]const u8 = null,
    interact: []const []const u8 = &.{},
    interact_max_bytes: usize = 16 << 20,
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    opts: Options,
    failures: usize = 0,
    started_ms: i64,

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.failures += 1;
        files.say(c.io, "FAIL " ++ fmt ++ "\n", args);
    }

    fn sleepMs(c: *Ctx, ms: i64) void {
        c.io.sleep(.fromMilliseconds(ms), .awake) catch return;
    }

    fn nowMs(c: *Ctx) i64 {
        return Io.Timestamp.now(c.io, .awake).toMilliseconds();
    }
};

const Instance = struct {
    name: []const u8,
    log_path: []const u8,
    child: ?std.process.Child = null,
    handle: ?*anyopaque = null,
    launched_ms: i64,
    parsed_ms: ?i64 = null,
    window: win.HWND = null,
    pid: u32 = 0,
};

fn launch(c: *Ctx, name: []const u8, file: []const u8) !Instance {
    const dir = try std.fs.path.join(c.gpa, &.{ c.opts.work_dir, name });
    const data = try std.fs.path.join(c.gpa, &.{ dir, "data" });
    try Io.Dir.cwd().createDirPath(c.io, data);
    const log_path = try std.fs.path.join(c.gpa, &.{ data, "mdview", "mdview-zig.log" });

    if (windows) {
        const pi = try win.startMinimized(c.gpa, c.opts.exe, file, data);
        return .{ .name = name, .log_path = log_path, .handle = pi.process, .launched_ms = c.nowMs(), .pid = pi.pid };
    }

    var env = try c.environ.clone(c.gpa);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", data);

    const child = try std.process.spawn(c.io, .{
        .argv = &.{ c.opts.exe, file },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid: u32 = @intCast(child.id.?);
    return .{ .name = name, .log_path = log_path, .child = child, .launched_ms = c.nowMs(), .pid = pid };
}

fn readLog(c: *Ctx, inst: *const Instance) []u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, inst.log_path, c.gpa, .limited(16 << 20)) catch return &.{};
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn alive(c: *Ctx, inst: *Instance) bool {
    if (windows) return inst.handle != null and win.WaitForSingleObject(inst.handle.?, 0) == 258;
    if (inst.child == null or inst.child.?.id == null) return false;
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{inst.pid}) catch return false;
    const stat = Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(4096)) catch return false;
    defer c.gpa.free(stat);
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    return close + 2 < stat.len and stat[close + 2] != 'Z' and stat[close + 2] != 'X';
}

fn waitParsed(c: *Ctx, inst: *Instance, want: usize) bool {
    const deadline = c.nowMs() + @as(i64, @intCast(c.opts.parse_timeout_seconds)) * 1000;
    while (c.nowMs() < deadline) {
        const log = readLog(c, inst);
        defer if (log.len > 0) c.gpa.free(log);
        if (count(log, "parsed ") >= want) {
            if (inst.parsed_ms == null) inst.parsed_ms = c.nowMs() - inst.launched_ms;
            return true;
        }
        if (!alive(c, inst)) return false;
        c.sleepMs(100);
    }
    return false;
}

const fatal_markers = [_][]const u8{ "panic", "out of memory", "segmentation", "stack overflow" };

fn checkLog(c: *Ctx, inst: *Instance, what: []const u8) void {
    const log = readLog(c, inst);
    defer if (log.len > 0) c.gpa.free(log);
    for (fatal_markers) |m| {
        if (std.ascii.findIgnoreCase(log, m) != null) c.fail("{s} {s}: log contains '{s}'", .{ inst.name, what, m });
    }
}

fn stop(c: *Ctx, inst: *Instance) void {
    if (windows) {
        if (inst.handle) |h| {
            _ = win.TerminateProcess(h, 1);
            _ = win.CloseHandle(h);
            inst.handle = null;
        }
        return;
    }
    if (inst.child) |*ch| ch.kill(c.io);
}

fn holdPhase(c: *Ctx, names: []const []const u8) !void {
    var start: usize = 0;
    while (start < names.len) : (start += c.opts.parallel) {
        const batch = names[start..@min(start + c.opts.parallel, names.len)];
        var insts = try c.gpa.alloc(Instance, batch.len);
        defer c.gpa.free(insts);
        var launched: usize = 0;
        defer for (insts[0..launched]) |*i| stop(c, i);
        for (batch, 0..) |name, k| {
            const file = try std.fs.path.join(c.gpa, &.{ c.opts.stress_dir, name });
            insts[k] = launch(c, name, file) catch |err| {
                c.fail("{s}: cannot start: {t}", .{ name, err });
                continue;
            };
            launched = k + 1;
        }
        for (insts[0..launched]) |*i| {
            if (!waitParsed(c, i, 1)) c.fail("{s}: no 'parsed N blocks' in the log within {d} s (alive: {})", .{ i.name, c.opts.parse_timeout_seconds, alive(c, i) });
        }
        c.sleepMs(@intCast(c.opts.hold_seconds * 1000));
        for (insts[0..launched]) |*i| {
            const ok = alive(c, i);
            if (windows) {
                i.window = win.find(i.pid);
                if (i.window == null) c.fail("{s}: no window", .{i.name}) else if (win.IsIconic(i.window) == 0) c.fail("{s}: window is not minimized", .{i.name});
            }
            if (!ok) c.fail("{s}: exited within {d} s", .{ i.name, c.opts.hold_seconds });
            checkLog(c, i, "hold");
            files.say(c.io, "held  {s:<36} parse {d:>6} ms  {s}\n", .{ i.name, i.parsed_ms orelse 0, if (ok) "alive" else "DEAD" });
        }
    }
}

fn expectAlive(c: *Ctx, inst: *Instance, phase: []const u8) bool {
    const ok = alive(c, inst);
    if (!ok) c.fail("{s}: not alive after {s}", .{ inst.name, phase });
    checkLog(c, inst, phase);
    files.say(c.io, "  {s:<14} {s}\n", .{ phase, if (ok) "ok" else "DEAD" });
    return ok;
}

fn xdo(c: *Ctx, args: []const []const u8) ?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(c.gpa, "xdotool") catch return null;
    argv.appendSlice(c.gpa, args) catch return null;
    const r = std.process.run(c.gpa, c.io, .{ .argv = argv.items, .environ_map = c.environ }) catch return null;
    c.gpa.free(r.stderr);
    return r.stdout;
}

fn findWindow(c: *Ctx, inst: *Instance) ?[]const u8 {
    const deadline = c.nowMs() + 20_000;
    while (c.nowMs() < deadline) {
        if (windows) {
            inst.window = win.find(inst.pid);
            if (inst.window != null) return "";
        } else {
            var pid_buf: [16]u8 = undefined;
            const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{inst.pid}) catch return null;
            if (xdo(c, &.{ "search", "--onlyvisible", "--pid", pid })) |out| {
                const line = std.mem.trim(u8, out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len], " \r");
                if (line.len > 0) return line;
            }
        }
        c.sleepMs(250);
    }
    return null;
}

fn resizeTo(c: *Ctx, inst: *Instance, id: []const u8, w: i32, h: i32) void {
    if (windows) {
        _ = win.SetWindowPos(inst.window, null, 20, 20, w, h, win.swp_flags);
        const lp: isize = @as(isize, h) << 16 | @as(isize, w & 0xFFFF);
        _ = win.PostMessageW(inst.window, win.wm_size, 0, lp);
    } else {
        var wb: [16]u8 = undefined;
        var hb: [16]u8 = undefined;
        const ws = std.fmt.bufPrint(&wb, "{d}", .{w}) catch return;
        const hs = std.fmt.bufPrint(&hb, "{d}", .{h}) catch return;
        if (xdo(c, &.{ "windowsize", id, ws, hs })) |o| c.gpa.free(o);
    }
}

fn resizePhase(c: *Ctx, inst: *Instance, id: []const u8) void {
    const sizes = [_][2]i32{ .{ 1200, 800 }, .{ 320, 240 }, .{ 1800, 1000 }, .{ 640, 480 }, .{ 100, 100 }, .{ 900, 700 }, .{ 1, 1 }, .{ 2000, 600 } };
    for (0..80) |i| {
        const s = sizes[i % sizes.len];
        resizeTo(c, inst, id, s[0], s[1]);
        c.sleepMs(15);
    }
    if (windows) {
        for ([_]isize{ 0, 1, 0xFFFF, 0x7FFF7FFF, 0x00010001 }) |lp| _ = win.PostMessageW(inst.window, win.wm_size, 0, lp);
    }
    resizeTo(c, inst, id, 1000, 700);
}

fn scrollPhase(c: *Ctx, inst: *Instance, id: []const u8) void {
    if (windows) {
        const down: usize = @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16;
        const up: usize = @as(usize, @as(u16, 120)) << 16;
        for (0..600) |_| {
            _ = win.PostMessageW(inst.window, win.wm_mousewheel, down, 0x00200020);
            c.sleepMs(4);
        }
        for (0..100) |_| {
            _ = win.PostMessageW(inst.window, win.wm_mousewheel, up, 0x00200020);
            c.sleepMs(4);
        }
    } else {
        if (xdo(c, &.{ "mousemove", "--window", id, "200", "200" })) |o| c.gpa.free(o);
        if (xdo(c, &.{ "click", "--repeat", "600", "--delay", "4", "5" })) |o| c.gpa.free(o);
        if (xdo(c, &.{ "click", "--repeat", "100", "--delay", "4", "4" })) |o| c.gpa.free(o);
    }
}

fn hammerPhase(c: *Ctx, inst: *Instance, doc: []const u8, base: []const u8) void {
    const before = parsedCount(c, inst);
    const delay_ms: i64 = @intCast(c.opts.hammer_seconds * 1000 / c.opts.hammer_writes);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(c.gpa);
    for (0..c.opts.hammer_writes) |i| {
        buf.clearRetainingCapacity();
        const keep = if (i % 2 == 0) base.len else base.len / 2;
        buf.appendSlice(c.gpa, base[0..keep]) catch return;
        buf.print(c.gpa, "\n\nrewrite {d} *emphasis* `code` [link](http://x)\n", .{i}) catch return;
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = doc, .data = buf.items }) catch |err| {
            c.fail("{s}: rewrite {d}: {t}", .{ inst.name, i, err });
            return;
        };
        c.sleepMs(delay_ms);
    }
    c.sleepMs(2500);
    const after = parsedCount(c, inst);
    if (after <= before) c.fail("{s}: no reload after {d} rewrites", .{ inst.name, c.opts.hammer_writes });
    files.say(c.io, "  reloads        {d}\n", .{after - before});
}

fn parsedCount(c: *Ctx, inst: *const Instance) usize {
    const log = readLog(c, inst);
    defer if (log.len > 0) c.gpa.free(log);
    return count(log, "parsed ");
}

fn recreatePhase(c: *Ctx, inst: *Instance, doc: []const u8, base: []const u8) void {
    const dir = Io.Dir.cwd();
    const tmp = std.fmt.allocPrint(c.gpa, "{s}.tmp", .{doc}) catch return;
    defer c.gpa.free(tmp);
    for (0..5) |round| {
        dir.deleteFile(c.io, doc) catch |err| c.fail("{s}: delete: {t}", .{ inst.name, err });
        c.sleepMs(1500);
        if (!alive(c, inst)) return;
        dir.writeFile(c.io, .{ .sub_path = doc, .data = base[0 .. base.len / (round + 1)] }) catch |err| c.fail("{s}: recreate: {t}", .{ inst.name, err });
        c.sleepMs(1500);
        dir.writeFile(c.io, .{ .sub_path = tmp, .data = base[0 .. base.len / (round + 2)] }) catch |err| c.fail("{s}: write temp: {t}", .{ inst.name, err });
        dir.rename(tmp, dir, doc, c.io) catch |err| c.fail("{s}: rename over: {t}", .{ inst.name, err });
        c.sleepMs(1500);
    }
    dir.deleteFile(c.io, doc) catch |err| c.fail("{s}: final delete: {t}", .{ inst.name, err });
    c.sleepMs(1500);
    dir.writeFile(c.io, .{ .sub_path = doc, .data = "" }) catch |err| c.fail("{s}: empty recreate: {t}", .{ inst.name, err });
    c.sleepMs(1500);
    dir.writeFile(c.io, .{ .sub_path = doc, .data = base }) catch |err| c.fail("{s}: restore: {t}", .{ inst.name, err });
    c.sleepMs(1500);
}

fn interactPhase(c: *Ctx, name: []const u8) !void {
    files.say(c.io, "interact {s}\n", .{name});
    const live_dir = try std.fs.path.join(c.gpa, &.{ c.opts.work_dir, try std.fmt.allocPrint(c.gpa, "{s}-live", .{name}) });
    try Io.Dir.cwd().createDirPath(c.io, live_dir);
    const doc = try std.fs.path.join(c.gpa, &.{ live_dir, "doc.md" });
    const source = try std.fs.path.join(c.gpa, &.{ c.opts.stress_dir, name });
    const whole = try Io.Dir.cwd().readFileAlloc(c.io, source, c.gpa, .unlimited);
    const base = whole[0..@min(whole.len, c.opts.interact_max_bytes)];
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = doc, .data = base });

    var inst = try launch(c, try std.fmt.allocPrint(c.gpa, "{s}-live", .{name}), doc);
    defer stop(c, &inst);
    if (!waitParsed(c, &inst, 1)) {
        c.fail("{s}: no 'parsed N blocks' in the log", .{name});
        return;
    }
    const id = findWindow(c, &inst) orelse {
        c.fail("{s}: no window for pid {d}", .{ name, inst.pid });
        return;
    };
    resizePhase(c, &inst, id);
    if (!expectAlive(c, &inst, "resize")) return;
    scrollPhase(c, &inst, id);
    if (!expectAlive(c, &inst, "scroll")) return;
    hammerPhase(c, &inst, doc, base[0..@min(base.len, 512 << 10)]);
    if (!expectAlive(c, &inst, "rewrite x200")) return;
    recreatePhase(c, &inst, doc, base[0..@min(base.len, 512 << 10)]);
    if (!expectAlive(c, &inst, "delete/recreate")) return;
    resizePhase(c, &inst, id);
    scrollPhase(c, &inst, id);
    _ = expectAlive(c, &inst, "final");
}

fn crashEvents(c: *Ctx) void {
    if (!windows) return;
    const elapsed = c.nowMs() - c.started_ms + 60_000;
    const query = std.fmt.allocPrint(c.gpa, "/q:*[System[(EventID=1000 or EventID=1001) and TimeCreated[timediff(@SystemTime) <= {d}]]]", .{elapsed}) catch return;
    const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ "wevtutil", "qe", "Application", query, "/f:text", "/c:100" } }) catch |err| {
        files.say(c.io, "event log not read: {t}\n", .{err});
        return;
    };
    if (std.ascii.findIgnoreCase(r.stdout, "mdview") != null) {
        c.fail("the Application event log has a crash entry naming mdview", .{});
    } else files.say(c.io, "event log: no mdview crash entries in the last {d} s\n", .{@divTrunc(elapsed, 1000)});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        files.say(init.io, "usage: stress-app <mdview exe> <stress dir> <work dir> [--hold S] [--parallel N] [--only TEXT] [--interact a.md,b.md] [--hammer-writes N] [--hammer-seconds S]\n", .{});
        return error.Usage;
    }
    var opts: Options = .{ .exe = args[1], .stress_dir = args[2], .work_dir = args[3] };
    var i: usize = 4;
    while (i + 1 < args.len) : (i += 2) {
        const key = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--hold")) opts.hold_seconds = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "--parallel")) opts.parallel = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, key, "--only")) opts.only = value;
        if (std.mem.eql(u8, key, "--hammer-writes")) opts.hammer_writes = try std.fmt.parseInt(usize, value, 10);
        if (std.mem.eql(u8, key, "--hammer-seconds")) opts.hammer_seconds = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "--parse-timeout")) opts.parse_timeout_seconds = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "--interact")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |n| try list.append(arena, n);
            opts.interact = list.items;
        }
    }

    var c: Ctx = .{ .gpa = arena, .io = init.io, .environ = init.environ_map, .opts = opts, .started_ms = Io.Timestamp.now(init.io, .awake).toMilliseconds() };
    try Io.Dir.cwd().createDirPath(c.io, opts.work_dir);

    var dir = try Io.Dir.cwd().openDir(c.io, opts.stress_dir, .{ .iterate = true });
    defer dir.close(c.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (opts.only) |o| if (std.mem.find(u8, entry.name, o) == null) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    try holdPhase(&c, names.items);
    for (opts.interact) |name| try interactPhase(&c, name);
    crashEvents(&c);

    if (c.failures > 0) {
        files.say(c.io, "{d} failures\n", .{c.failures});
        std.process.exit(1);
    }
    files.say(c.io, "all {d} files held {d} s and {d} interaction runs passed\n", .{ names.items.len, opts.hold_seconds, opts.interact.len });
}
