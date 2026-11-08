const std = @import("std");
const Allocator = std.mem.Allocator;
const sequence = @import("sequence.zig");
const preprocess = @import("../preprocess.zig");
const env = sequence.env;
const testdata = @import("testdata");

const measures_json = testdata.file("mermaid/sequence/measures.json");

const Replay = struct {
    map: std.StringHashMapUnmanaged(env.text.Size) = .empty,
    a: Allocator,
    misses: usize = 0,
    last_miss: []const u8 = "",

    fn load(a: Allocator) !Replay {
        var r: Replay = .{ .a = a };
        const rows = try std.json.parseFromSliceLeaky([]const Row, a, measures_json, .{});
        for (rows) |row| {
            const key = try std.fmt.allocPrint(a, "{s}|{s}|{s}|{s}", .{ row.k[0], row.k[1], row.k[2], row.k[3] });
            try r.map.put(a, key, .{ .w = @floatCast(row.w), .h = @floatCast(row.h) });
        }
        return r;
    }

    const Row = struct { k: [4][]const u8, w: f64, h: f64 };

    // The default family ends in ';', which Chrome rejects, so the browser measures in its default serif.
    fn measure(ctx: ?*anyopaque, text: []const u8, font: env.text.Font) env.text.Size {
        const r: *Replay = @ptrCast(@alignCast(ctx.?));
        const fam: []const u8 = if (std.mem.indexOfScalar(u8, font.family, ';') != null) "\"Times New Roman\"" else env.normFamily(r.a, font.family) catch font.family;
        const key = std.fmt.allocPrint(r.a, "{s}|{d}px|{d}|{s}", .{ fam, font.size, font.weight, text }) catch return .{ .w = 0, .h = 0 };
        if (r.map.get(key)) |d| return d;
        r.misses += 1;
        r.last_miss = key;
        return .{ .w = 0, .h = 17 };
    }

    fn measurer(r: *Replay) env.Measurer {
        return .{ .ctx = r, .measure_fn = measure };
    }
};

const themes_json = testdata.file("mermaid/sequence/themes.json");

const ThemeCtx = struct {
    vars: std.json.ObjectMap,

    fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const ThemeCtx = @ptrCast(@alignCast(ctx));
        const v = self.vars.get(name) orelse return null;
        return v.string;
    }
};

const Elem = struct {
    tag: []const u8,
    attrs: []const [2][]const u8,
    children: []const *Elem,
    text: []const u8,
};

const Xml = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn unescape(x: *Xml, v: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, v, '&') == null) return v;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < v.len) {
            if (v[i] == '&') {
                const subs = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&nbsp;", "\u{a0}" } };
                var hit = false;
                if (v[i + 1 ..].len > 1 and v[i + 1] == '#') {
                    if (std.mem.indexOfScalar(u8, v[i..], ';')) |semi| {
                        const num = v[i + 2 .. i + semi];
                        const cp = (if (num.len > 0 and (num[0] == 'x' or num[0] == 'X')) std.fmt.parseInt(u21, num[1..], 16) else std.fmt.parseInt(u21, num, 10)) catch 0xFFFD;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                        try out.appendSlice(x.a, buf[0..n]);
                        i += semi + 1;
                        continue;
                    }
                }
                for (subs) |sb| if (std.mem.startsWith(u8, v[i..], sb[0])) {
                    try out.appendSlice(x.a, sb[1]);
                    i += sb[0].len;
                    hit = true;
                    break;
                };
                if (hit) continue;
            }
            try out.append(x.a, v[i]);
            i += 1;
        }
        return out.items;
    }

    fn element(x: *Xml) !*Elem {
        std.debug.assert(x.s[x.i] == '<');
        x.i += 1;
        const ts = x.i;
        while (x.s[x.i] != ' ' and x.s[x.i] != '>' and x.s[x.i] != '/') x.i += 1;
        const tag = x.s[ts..x.i];
        var attrs: std.ArrayList([2][]const u8) = .empty;
        while (true) {
            while (x.s[x.i] == ' ') x.i += 1;
            if (x.s[x.i] == '>') break;
            if (x.s[x.i] == '/') {
                x.i += 2;
                const e = try x.a.create(Elem);
                e.* = .{ .tag = tag, .attrs = attrs.items, .children = &.{}, .text = "" };
                return e;
            }
            const ns = x.i;
            while (x.s[x.i] != '=') x.i += 1;
            const name = x.s[ns..x.i];
            x.i += 2;
            const vs = x.i;
            while (x.s[x.i] != '"') x.i += 1;
            try attrs.append(x.a, .{ name, try x.unescape(x.s[vs..x.i]) });
            x.i += 1;
        }
        x.i += 1;
        var kids: std.ArrayList(*Elem) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (x.s[x.i] == '<') {
                if (x.s[x.i + 1] == '/') {
                    while (x.s[x.i] != '>') x.i += 1;
                    x.i += 1;
                    break;
                }
                try kids.append(x.a, try x.element());
            } else {
                const st = x.i;
                while (x.s[x.i] != '<') x.i += 1;
                try text.appendSlice(x.a, try x.unescape(x.s[st..x.i]));
            }
        }
        const e = try x.a.create(Elem);
        e.* = .{ .tag = tag, .attrs = attrs.items, .children = kids.items, .text = text.items };
        return e;
    }
};

fn numAt(s: []const u8, i: usize) ?struct { v: f64, end: usize } {
    var j = i;
    if (j < s.len and s[j] == '-') j += 1;
    const ds = j;
    while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
    if (j == ds) return null;
    const v = std.fmt.parseFloat(f64, s[i..j]) catch return null;
    return .{ .v = v, .end = j };
}

fn close(a: []const u8, b: []const u8, tol: f64) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (numAt(a, i)) |na| if (numAt(b, j)) |nb| {
            if (@abs(na.v - nb.v) > tol) return false;
            i = na.end;
            j = nb.end;
            continue;
        };
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
    return i == a.len and j == b.len;
}

const Stats = struct { elements: usize = 0, bad: usize = 0, worst: f64 = 0 };

fn compare(a: Allocator, mine: *const Elem, ref: *const Elem, path: []const u8, st: *Stats, report: *std.ArrayList(u8)) !void {
    st.elements += 1;
    const here = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, ref.tag });
    if (!std.mem.eql(u8, mine.tag, ref.tag)) {
        st.bad += 1;
        try report.print(a, "  {s}: tag {s} vs ref {s}\n", .{ here, mine.tag, ref.tag });
        return;
    }
    if (std.mem.eql(u8, ref.tag, "style")) return;
    var ok = true;
    if (mine.attrs.len != ref.attrs.len) {
        ok = false;
        try report.print(a, "  {s}: attribute count {d} vs ref {d}\n", .{ here, mine.attrs.len, ref.attrs.len });
        for (mine.attrs) |x| try report.print(a, "     mine {s}=\"{s}\"\n", .{ x[0], x[1] });
        for (ref.attrs) |x| try report.print(a, "     ref  {s}=\"{s}\"\n", .{ x[0], x[1] });
    } else for (mine.attrs, ref.attrs) |x, y| {
        const same_value = if (std.mem.eql(u8, x[0], "id")) sameId(x[1], y[1]) else close(x[1], y[1], 0.5);
        if (!std.mem.eql(u8, x[0], y[0]) or !same_value) {
            ok = false;
            try report.print(a, "  {s}: {s}=\"{s}\" vs ref {s}=\"{s}\"\n", .{ here, x[0], x[1], y[0], y[1] });
        }
    }
    if (!std.mem.eql(u8, mine.text, ref.text)) {
        ok = false;
        try report.print(a, "  {s}: text \"{s}\" vs ref \"{s}\"\n", .{ here, mine.text, ref.text });
    }
    if (!ok) st.bad += 1;
    if (mine.children.len != ref.children.len) {
        st.bad += 1;
        try report.print(a, "  {s}: {d} children vs ref {d}\n", .{ here, mine.children.len, ref.children.len });
        return;
    }
    for (mine.children, ref.children) |m, r| try compare(a, m, r, here, st, report);
}

// The reference run kept one actor counter across many diagrams in a page; a frame renders one, so ids are compared without their numbers.
fn sameId(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
        while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
    return true;
}

fn readFile(a: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .unlimited);
}

fn confFor(a: Allocator, src: []const u8) !env.Conf {
    var conf: env.Conf = .{};
    if (std.mem.indexOf(u8, src, "%%{init:")) |s| {
        const e = std.mem.indexOf(u8, src[s..], "}%%").?;
        const json = src[s + "%%{init:".len .. s + e];
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        try conf.applyJson(a, v);
    }
    return conf;
}

fn bodyOf(src: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, src, "sequenceDiagram").?;
    var out = src[i..];
    if (std.mem.indexOf(u8, src[0..i], "%%{init:")) |_| {}
    out = out[0..];
    return out;
}

const FrontMatter = struct { title: ?[]const u8 = null, theme: ?[]const u8 = null, look: ?[]const u8 = null };

fn frontMatter(src: []const u8) FrontMatter {
    var fm: FrontMatter = .{};
    if (!std.mem.startsWith(u8, src, "---\n")) return fm;
    const end = std.mem.indexOf(u8, src[4..], "\n---") orelse return fm;
    var it = std.mem.splitScalar(u8, src[4 .. 4 + end], '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, t, "title: ")) fm.title = t[7..];
        if (std.mem.startsWith(u8, t, "theme: ")) fm.theme = t[7..];
        if (std.mem.startsWith(u8, t, "look: ")) fm.look = t[6..];
    }
    return fm;
}

fn runSet(a: Allocator, replay: *Replay, theme: []const u8, manifest_path: []const u8, refs_dir: []const u8) !void {
    const themes = try std.json.parseFromSliceLeaky(std.json.Value, a, themes_json, .{});
    var skipped: usize = 0;
    const manifest = try readFile(a, manifest_path);
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    var report: std.ArrayList(u8) = .empty;
    var total: Stats = .{};
    var cases: usize = 0;
    var failed: usize = 0;
    while (lines.next()) |name_raw| {
        const name = std.mem.trim(u8, name_raw, " \r");
        if (name.len == 0) continue;
        cases += 1;
        const src = try readFile(a, try std.fmt.allocPrint(a, "testdata/mermaid/sequence/cases/{s}.mmd", .{name}));
        const ref_svg = try readFile(a, try std.fmt.allocPrint(a, "testdata/mermaid/sequence/{s}/{s}.svg", .{ refs_dir, name }));
        var xr: Xml = .{ .a = a, .s = ref_svg };
        const ref = try xr.element();
        stripA11y(a, ref);
        keepRootAttrs(a, ref);
        var conf = try confFor(a, src);
        const fm = frontMatter(src);
        if (fm.look) |l| conf.look = if (std.mem.eql(u8, l, "neo")) .neo else .classic;
        const tv = themes.object.get(fm.theme orelse theme) orelse {
            skipped += 1;
            cases -= 1;
            continue;
        };
        const tctx: ThemeCtx = .{ .vars = tv.object };
        replay.misses = 0;
        const res = try sequence.render(a, try preprocess.encodeEntities(a, bodyOf(src)), .{ .id = "diagram", .conf = conf, .theme = .{ .ctx = &tctx, .getFn = ThemeCtx.get }, .measurer = replay.measurer(), .title = fm.title });
        var st: Stats = .{};
        var local: std.ArrayList(u8) = .empty;
        switch (res) {
            .err => |m| {
                st.bad += 1;
                try local.print(a, "  render error: {s}\n", .{m});
            },
            .ok => |o| {
                var xm: Xml = .{ .a = a, .s = try preprocess.decodeEntities(a, o.svg) };
                const mine = try xm.element();
                keepRootAttrs(a, mine);
                try compare(a, mine, ref, "", &st, &local);
                var ref_css: []const u8 = "";
                for (ref.children) |c| if (std.mem.eql(u8, c.tag, "style")) {
                    ref_css = c.text;
                };
                for (mine.children) |c| if (std.mem.eql(u8, c.tag, "style")) {
                    if (std.mem.indexOf(u8, ref_css, c.text) == null) {
                        st.bad += 1;
                        try local.print(a, "  sequence css not found in reference style\n", .{});
                    }
                };
            },
        }
        if (replay.misses > 0) try local.print(a, "  {d} measurements missing, last: {s}\n", .{ replay.misses, replay.last_miss });
        total.elements += st.elements;
        total.bad += st.bad;
        if (st.bad > 0) {
            failed += 1;
            try report.print(a, "{s}: {d} of {d} elements differ\n{s}", .{ name, st.bad, st.elements, local.items });
        }
    }
    std.debug.print("\nsequence parity {s}: {d} of {d} cases match, {d} of {d} elements differ, {d} skipped (theme not ported)\n", .{ theme, cases - failed, cases, total.bad, total.elements, skipped });
    if (failed > 0) {
        const limit = @min(report.items.len, 20000);
        std.debug.print("{s}\n", .{report.items[0..limit]});
        return error.ParityMismatch;
    }
}

test "sequence parity with mermaid 11.16.1 on the replayed measurements" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var replay = try Replay.load(a);
    try runSet(a, &replay, "dark", "testdata/mermaid/sequence/manifest.txt", "refs");
    for ([_][]const u8{ "default", "forest", "neutral" }) |t| {
        try runSet(a, &replay, t, "testdata/mermaid/sequence/themes_manifest.txt", try std.fmt.allocPrint(a, "refs_{s}", .{t}));
    }
}

// Root attributes other than the size belong to core and the page frame.
fn keepRootAttrs(a: Allocator, root: *Elem) void {
    var attrs: std.ArrayList([2][]const u8) = .empty;
    for (root.attrs) |x| if (std.mem.eql(u8, x[0], "viewBox") or std.mem.eql(u8, x[0], "style")) attrs.append(a, x) catch return;
    root.attrs = attrs.items;
}

fn stripA11y(a: Allocator, ref: *Elem) void {
    var attrs: std.ArrayList([2][]const u8) = .empty;
    for (ref.attrs) |x| if (!std.mem.startsWith(u8, x[0], "aria-describedby") and !std.mem.startsWith(u8, x[0], "aria-labelledby")) attrs.append(a, x) catch return;
    ref.attrs = attrs.items;
    var kids: std.ArrayList(*Elem) = .empty;
    for (ref.children) |c| if (!std.mem.eql(u8, c.tag, "title") and !std.mem.eql(u8, c.tag, "desc")) kids.append(a, c) catch return;
    ref.children = kids.items;
}
