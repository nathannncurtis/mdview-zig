const std = @import("std");
const testdata = @import("testdata");
const Allocator = std.mem.Allocator;

pub const theme = @import("theme/theme.zig");
pub const config = @import("config.zig");
pub const detect = @import("detect.zig");
pub const preprocess = @import("preprocess.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const errors = @import("errors.zig");
pub const text = @import("text.zig");
pub const segment = @import("segment.zig");
pub const svg = @import("svg.zig");
pub const css = @import("css.zig");
pub const info = @import("info.zig");
pub const layout = @import("layout.zig");
pub const fuzz = @import("fuzz.zig");
pub const sequence = @import("sequence/sequence.zig");

/// The Mermaid release everything here is ported from.
pub const version = diagram.version;

const max_text_size_default: f64 = 50_000;
const max_text_message = "graph TB;a[Maximum text size in diagram exceeded];style a fill:#faa";

const diagram = @import("diagram.zig");
pub const Error = diagram.Error;
pub const ClassDef = diagram.ClassDef;
pub const Acc = diagram.Acc;
pub const Deadline = diagram.Deadline;
pub const Ctx = diagram.Ctx;
pub const Def = diagram.Def;

/// Diagram types that can be drawn. Each diagram lane adds its `def` here.
pub const registry = [_]Def{
    info.def,
    error_def,
};

fn errorParse(ctx: *Ctx, _: []const u8) Error!*anyopaque {
    return try ctx.a.create(u8);
}

fn errorLayout(_: *Ctx, model: *anyopaque) Error!*anyopaque {
    return model;
}

const error_paths = [_][]const u8{
    "m411.313,123.313c6.25-6.25 6.25-16.375 0-22.625s-16.375-6.25-22.625,0l-32,32-9.375,9.375-20.688-20.688c-12.484-12.5-32.766-12.5-45.25,0l-16,16c-1.261,1.261-2.304,2.648-3.31,4.051-21.739-8.561-45.324-13.426-70.065-13.426-105.867,0-192,86.133-192,192s86.133,192 192,192 192-86.133 192-192c0-24.741-4.864-48.327-13.426-70.065 1.402-1.007 2.79-2.049 4.051-3.31l16-16c12.5-12.492 12.5-32.758 0-45.25l-20.688-20.688 9.375-9.375 32.001-31.999zm-219.313,100.687c-52.938,0-96,43.063-96,96 0,8.836-7.164,16-16,16s-16-7.164-16-16c0-70.578 57.422-128 128-128 8.836,0 16,7.164 16,16s-7.164,16-16,16z",
    "m459.02,148.98c-6.25-6.25-16.375-6.25-22.625,0s-6.25,16.375 0,22.625l16,16c3.125,3.125 7.219,4.688 11.313,4.688 4.094,0 8.188-1.563 11.313-4.688 6.25-6.25 6.25-16.375 0-22.625l-16.001-16z",
    "m340.395,75.605c3.125,3.125 7.219,4.688 11.313,4.688 4.094,0 8.188-1.563 11.313-4.688 6.25-6.25 6.25-16.375 0-22.625l-16-16c-6.25-6.25-16.375-6.25-22.625,0s-6.25,16.375 0,22.625l15.999,16z",
    "m400,64c8.844,0 16-7.164 16-16v-32c0-8.836-7.156-16-16-16-8.844,0-16,7.164-16,16v32c0,8.836 7.156,16 16,16z",
    "m496,96.586h-32c-8.844,0-16,7.164-16,16 0,8.836 7.156,16 16,16h32c8.844,0 16-7.164 16-16 0-8.836-7.156-16-16-16z",
    "m436.98,75.605c3.125,3.125 7.219,4.688 11.313,4.688 4.094,0 8.188-1.563 11.313-4.688l32-32c6.25-6.25 6.25-16.375 0-22.625s-16.375-6.25-22.625,0l-32,32c-6.251,6.25-6.251,16.375-0.001,22.625z",
};

fn errorEmit(ctx: *Ctx, _: *anyopaque, _: *anyopaque, w: *svg.SvgWriter) Error!void {
    try w.start("g", &.{});
    try w.setViewBox(0, 0, 2412, 512);
    try w.configureSvgSize(100, 512, true);
    for (error_paths) |d| try w.leaf("path", &.{ .{ .name = "class", .value = "error-icon" }, .{ .name = "d", .value = d } });
    try w.textElement("text", &.{
        .{ .name = "class", .value = "error-text" },
        .{ .name = "x", .value = "1440" },
        .{ .name = "y", .value = "250" },
        .{ .name = "font-size", .value = "150px" },
        .{ .name = "style", .value = "text-anchor: middle;" },
    }, "Syntax error in text");
    const label = try std.fmt.allocPrint(w.a, "mermaid version {s}", .{ctx.version});
    try w.textElement("text", &.{
        .{ .name = "class", .value = "error-text" },
        .{ .name = "x", .value = "1250" },
        .{ .name = "y", .value = "400" },
        .{ .name = "font-size", .value = "100px" },
        .{ .name = "style", .value = "text-anchor: middle;" },
    }, label);
    try w.end();
}

const error_def: Def = .{ .id = "error", .parse = errorParse, .layout = errorLayout, .emit = errorEmit };

/// The options the frame on github.com gives `mermaid.initialize`.
pub const github_init = config.github_init;

pub const Opts = struct {
    /// The theme `mermaid.initialize` is given; GitHub uses dark in dark mode.
    theme: theme.Name = .dark,
    /// The `mermaid.initialize` options GitHub passes besides the theme.
    init_json: []const u8 = github_init,
    /// The id of the root `<svg>`; GitHub renders with "diagram".
    svg_id: []const u8 = "diagram",
    measurer: text.Measurer = text.stub,
    /// Monotonic nanoseconds; without it the time limit is not enforced.
    clock: ?*const fn () i64 = null,
    timeout_ms: u32 = 5000,
    /// Cap on what one diagram may allocate.
    memory_limit: usize = 256 * 1024 * 1024,
};

pub const Image = struct { bytes: []const u8, w: f32, h: f32 };

pub const Result = union(enum) {
    svg: Image,
    /// The exact text that goes under "Unable to render rich display".
    err: []const u8,
    /// The text is a diagram type that is not ported yet.
    unsupported: []const u8,
};

/// Frees what `render` returned.
pub fn free(gpa: Allocator, r: Result) void {
    switch (r) {
        .svg => |i| gpa.free(i.bytes),
        .err => |e| gpa.free(e),
        .unsupported => |u| gpa.free(u),
    }
}

const Capped = struct {
    child: Allocator,
    used: usize = 0,
    limit: usize,
    hit: bool = false,

    fn allocator(c: *Capped) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = freeFn } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (c.used + len > c.limit) {
            c.hit = true;
            return null;
        }
        const p = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        c.used += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and c.used + (new_len - memory.len) > c.limit) {
            c.hit = true;
            return false;
        }
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.used = c.used - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and c.used + (new_len - memory.len) > c.limit) {
            c.hit = true;
            return null;
        }
        const p = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.used = c.used - memory.len + new_len;
        return p;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ret_addr);
        c.used -|= memory.len;
    }
};

const Inner = union(enum) { svg: Image, err: []const u8, unsupported: []const u8 };

/// Renders Mermaid source the way `mermaid.render` does after `initialize({ theme })`.
pub fn render(gpa: Allocator, source: []const u8, opts: Opts) Allocator.Error!Result {
    var capped: Capped = .{ .child = gpa, .limit = opts.memory_limit };
    var arena = std.heap.ArenaAllocator.init(capped.allocator());
    defer arena.deinit();
    const inner = renderInner(arena.allocator(), source, opts) catch |e| switch (e) {
        error.OutOfMemory => {
            if (!capped.hit) return error.OutOfMemory;
            return .{ .err = try gpa.dupe(u8, errors.too_large_message) };
        },
        error.Timeout => return .{ .err = try gpa.dupe(u8, errors.timeout_message) },
    };
    return switch (inner) {
        .svg => |i| .{ .svg = .{ .bytes = try gpa.dupe(u8, i.bytes), .w = i.w, .h = i.h } },
        .err => |m| .{ .err = try gpa.dupe(u8, m) },
        .unsupported => |u| .{ .unsupported = try gpa.dupe(u8, u) },
    };
}

fn findDef(id: []const u8) ?Def {
    for (registry) |d| if (std.mem.eql(u8, d.id, id)) return d;
    return null;
}

fn configError(a: Allocator, e: config.Err) (Allocator.Error || error{Timeout})!Inner {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidColor => .{ .err = try std.fmt.allocPrint(a, "Unsupported color format: \"{s}\"", .{theme.color.bad_color}) },
        else => .{ .err = "Invalid configuration" },
    };
}

fn dashesDef(a: Allocator) Allocator.Error!Inner {
    return .{ .err = try a.dupe(u8, errors.dashes_message) };
}

fn userStyles(ctx: *Ctx, defs: []const ClassDef) Allocator.Error![]const u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    if (ctx.cfg.str("themeCSS")) |t| {
        try out.appendSlice(a, t);
        try out.append(a, '\n');
    }
    if (ctx.cfg.str("fontFamily")) |ff| try out.print(a, ":root {{ --mermaid-font-family: {s}; }}\n", .{ff});
    if (ctx.cfg.str("altFontFamily")) |ff| try out.print(a, ":root {{ --mermaid-alt-font-family: {s}; }}\n", .{ff});
    const html = ctx.cfg.htmlLabels();
    const html_elems = [_][]const u8{ "> *", "span" };
    const shape_elems = [_][]const u8{ "rect", "polygon", "ellipse", "circle", "path" };
    for (defs) |d| {
        if (d.styles.len > 0) {
            for (if (html) html_elems[0..] else shape_elems[0..]) |el| try important(a, &out, d.id, el, d.styles, false);
        }
        if (d.text_styles.len > 0) try important(a, &out, d.id, "tspan", d.text_styles, true);
    }
    return out.items;
}

fn important(a: Allocator, out: *std.ArrayList(u8), class: []const u8, element: []const u8, items: []const []const u8, text_fill: bool) Allocator.Error!void {
    var block: std.ArrayList(u8) = .empty;
    try block.appendSlice(a, "{ ");
    for (items, 0..) |s, i| {
        if (i > 0) try block.appendSlice(a, " !important; ");
        if (text_fill) {
            if (std.mem.indexOf(u8, s, "color")) |at| {
                try block.appendSlice(a, s[0..at]);
                try block.appendSlice(a, "fill");
                try block.appendSlice(a, s[at + 5 ..]);
                continue;
            }
        }
        try block.appendSlice(a, s);
    }
    try block.appendSlice(a, " !important; }");
    try out.print(a, ".{s} {s} {s}\n", .{ class, element, config.sanitizeCss(block.items) });
}

fn renderInner(a: Allocator, source: []const u8, opts: Opts) (Allocator.Error || error{Timeout})!Inner {
    const pre = switch (try preprocessSafe(a, source)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const site = config.setupSite(a, opts.theme, opts.init_json) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = "Invalid configuration" },
    };
    const first = config.current(a, &site, null, null) catch |e| return configError(a, e);
    const scope_id = detect.detect(try preprocess.stripForDetection(a, pre.code), &first);
    const cfg = config.current(a, &site, if (scope_id) |s| config.diagramConfigKey(s) else null, pre.config) catch |e| return configError(a, e);

    var code = pre.code;
    var with_comments: ?[]const u8 = pre.with_comments;
    const limit = cfg.num("maxTextSize") orelse max_text_size_default;
    if (@as(f64, @floatFromInt(errors.utf16Len(code))) > limit) {
        code = max_text_message;
        with_comments = null;
    }

    const cleaned = try preprocess.stripForDetection(a, code);
    const id = detect.detect(cleaned, &cfg) orelse return .{ .err = try errors.unknownDiagram(a, cleaned) };
    if (std.mem.eql(u8, id, "---")) return dashesDef(a);

    const def = findDef(id) orelse return .{ .unsupported = id };

    var deadline: Deadline = .{ .clock = opts.clock, .limit_ns = @as(i64, opts.timeout_ms) * std.time.ns_per_ms };
    if (opts.clock) |c| deadline.start = c();
    var ctx: Ctx = .{ .a = a, .cfg = &cfg, .measurer = opts.measurer, .deadline = &deadline, .svg_id = opts.svg_id, .title = pre.title, .frontmatter_line_offset = pre.frontmatter_line_offset, .layout = layout.select(&cfg) };

    var parse_text = code;
    if (def.preserve_comments) if (with_comments) |wc| {
        if (@as(f64, @floatFromInt(errors.utf16Len(wc))) <= limit) parse_text = wc;
    };
    const encoded = try parserInput(a, parse_text);
    const model = def.parse(&ctx, encoded) catch |e| return stageError(&ctx, e);
    const geometry = def.layout(&ctx, model) catch |e| return stageError(&ctx, e);

    var w = svg.SvgWriter.init(a);
    try w.setRootAttr("id", opts.svg_id);
    try w.setRootAttr("width", "100%");
    try w.setRootAttr("xmlns", "http://www.w3.org/2000/svg");
    try w.setRootAttr("xmlns:xlink", "http://www.w3.org/1999/xlink");

    const acc: Acc = if (def.acc) |f| f(&ctx, model) else .{};
    if (acc.title) |t| try accNode(&w, "title", "chart-title-", opts.svg_id, t);
    if (acc.descr) |d| try accNode(&w, "desc", "chart-desc-", opts.svg_id, d);

    const defs = if (def.class_defs) |f| f(&ctx, model) catch |e| return stageError(&ctx, e) else &[_]ClassDef{};
    const diagram_css = if (def.styles) |f| f(&ctx) catch |e| return stageError(&ctx, e) else "";
    const selector = try std.fmt.allocPrint(a, "#{s}", .{opts.svg_id});
    const raw_css = try css.commonStyles(a, selector, &cfg.vars, diagram_css, try userStyles(&ctx, defs));
    try w.start("style", &.{});
    try w.text(try css.compile(a, selector, raw_css));
    try w.end();
    try w.leaf("g", &.{});

    def.emit(&ctx, model, geometry, &w) catch |e| return stageError(&ctx, e);

    try w.setRootAttr("role", "graphics-document document");
    try w.setRootAttr("aria-roledescription", id);
    if (acc.descr != null) try w.setRootAttr("aria-describedby", try std.fmt.allocPrint(a, "chart-desc-{s}", .{opts.svg_id}));
    if (acc.title != null) try w.setRootAttr("aria-labelledby", try std.fmt.allocPrint(a, "chart-title-{s}", .{opts.svg_id}));

    const bytes = try preprocess.decodeEntities(a, try w.finish());
    const sz = w.size();
    return .{ .svg = .{ .bytes = bytes, .w = sz.w, .h = sz.h } };
}

/// What every diagram's `parse` receives: entities encoded and a newline appended, as Mermaid's `Diagram.fromText` does.
pub fn parserInput(a: Allocator, src: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(a, u8, &.{ try preprocess.encodeEntities(a, src), "\n" });
}

fn accNode(w: *svg.SvgWriter, tag: []const u8, id_prefix: []const u8, svg_id: []const u8, content: []const u8) Allocator.Error!void {
    const id = try std.fmt.allocPrint(w.a, "{s}{s}", .{ id_prefix, svg_id });
    try w.textElement(tag, &.{.{ .name = "id", .value = id }}, content);
}

fn preprocessSafe(a: Allocator, source: []const u8) (Allocator.Error)!preprocess.Result {
    return preprocess.preprocess(a, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = "Invalid diagram configuration" },
    };
}

fn stageError(ctx: *Ctx, e: Error) (Allocator.Error || error{Timeout})!Inner {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => error.Timeout,
        error.Parse, error.Layout => .{ .err = ctx.err_msg orelse "Diagram could not be rendered" },
    };
}

fn fakeClock() i64 {
    return 1_000_000_000_000;
}

test {
    _ = theme;
    _ = config;
    _ = detect;
    _ = preprocess;
    _ = frontmatter;
    _ = errors;
    _ = text;
    _ = segment;
    _ = svg;
    _ = css;
    _ = info;
    _ = layout;
    _ = diagram;
    _ = fuzz;
    _ = sequence;
}

test "info renders with the version and theme styles" {
    const r = try render(std.testing.allocator, "info", .{});
    defer free(std.testing.allocator, r);
    try std.testing.expect(r == .svg);
    try std.testing.expect(std.mem.indexOf(u8, r.svg.bytes, ">v12.2.0</text>") != null);
    try std.testing.expectEqual(@as(f32, 400), r.svg.w);
}

test "parse errors, unknown types and unsupported types" {
    const bad = try render(std.testing.allocator, "info foo", .{});
    defer free(std.testing.allocator, bad);
    try std.testing.expectEqualStrings("Parsing failed: Lexer error on line 1, column 6: unexpected character: ->f<- at offset: 5, skipped 3 characters. ", bad.err);
    const unknown = try render(std.testing.allocator, "foo", .{});
    defer free(std.testing.allocator, unknown);
    try std.testing.expectEqualStrings("No diagram type detected matching given configuration for text: foo", unknown.err);
    const flow = try render(std.testing.allocator, "flowchart TD\nA-->B", .{});
    defer free(std.testing.allocator, flow);
    try std.testing.expectEqualStrings("flowchart-v2", flow.unsupported);
    const dashes = try render(std.testing.allocator, "---\nfoo", .{});
    defer free(std.testing.allocator, dashes);
    try std.testing.expectEqualStrings(errors.dashes_message, dashes.err);
}

test "memory limit and deadline" {
    const small = try render(std.testing.allocator, "info", .{ .memory_limit = 1024 });
    defer free(std.testing.allocator, small);
    try std.testing.expectEqualStrings(errors.too_large_message, small.err);
    var d: Deadline = .{ .clock = fakeClock, .start = 0, .limit_ns = 1 };
    try std.testing.expectError(error.Timeout, d.check());
}

const parity_cases = [_]struct { name: []const u8, source: []const u8, svg: []const u8 }{
    .{ .name = "01-info", .source = testdata.file("mermaid/info/01-info.mmd"), .svg = testdata.file("mermaid/info/01-info.svg") },
    .{ .name = "02-forest", .source = testdata.file("mermaid/info/02-forest.mmd"), .svg = testdata.file("mermaid/info/02-forest.svg") },
    .{ .name = "03-neutral", .source = testdata.file("mermaid/info/03-neutral.mmd"), .svg = testdata.file("mermaid/info/03-neutral.svg") },
    .{ .name = "04-base", .source = testdata.file("mermaid/info/04-base.mmd"), .svg = testdata.file("mermaid/info/04-base.svg") },
    .{ .name = "05-font", .source = testdata.file("mermaid/info/05-font.mmd"), .svg = testdata.file("mermaid/info/05-font.svg") },
    .{ .name = "06-themecss", .source = testdata.file("mermaid/info/06-themecss.mmd"), .svg = testdata.file("mermaid/info/06-themecss.svg") },
    .{ .name = "07-default", .source = testdata.file("mermaid/info/07-default.mmd"), .svg = testdata.file("mermaid/info/07-default.svg") },
    .{ .name = "08-textcolor", .source = testdata.file("mermaid/info/08-textcolor.mmd"), .svg = testdata.file("mermaid/info/08-textcolor.svg") },
    .{ .name = "09-error", .source = testdata.file("mermaid/info/09-error.mmd"), .svg = testdata.file("mermaid/info/09-error.svg") },
    .{ .name = "10-neo", .source = testdata.file("mermaid/info/10-neo.mmd"), .svg = testdata.file("mermaid/info/10-neo.svg") },
    .{ .name = "11-neodark", .source = testdata.file("mermaid/info/11-neodark.mmd"), .svg = testdata.file("mermaid/info/11-neodark.svg") },
    .{ .name = "12-redux", .source = testdata.file("mermaid/info/12-redux.mmd"), .svg = testdata.file("mermaid/info/12-redux.svg") },
    .{ .name = "13-reduxdarkcolor", .source = testdata.file("mermaid/info/13-reduxdarkcolor.mmd"), .svg = testdata.file("mermaid/info/13-reduxdarkcolor.svg") },
    .{ .name = "14-classic", .source = testdata.file("mermaid/info/14-classic.mmd"), .svg = testdata.file("mermaid/info/14-classic.svg") },
    .{ .name = "15-handdrawn", .source = testdata.file("mermaid/info/15-handdrawn.mmd"), .svg = testdata.file("mermaid/info/15-handdrawn.svg") },
    .{ .name = "16-infoconfig", .source = testdata.file("mermaid/info/16-infoconfig.mmd"), .svg = testdata.file("mermaid/info/16-infoconfig.svg") },
    .{ .name = "17-bogustheme", .source = testdata.file("mermaid/info/17-bogustheme.mmd"), .svg = testdata.file("mermaid/info/17-bogustheme.svg") },
    .{ .name = "18-nullbase", .source = testdata.file("mermaid/info/18-nullbase.mmd"), .svg = testdata.file("mermaid/info/18-nullbase.svg") },
    .{ .name = "19-comment-in-directive", .source = testdata.file("mermaid/info/19-comment-in-directive.mmd"), .svg = testdata.file("mermaid/info/19-comment-in-directive.svg") },
    .{ .name = "20-comment-leading", .source = testdata.file("mermaid/info/20-comment-leading.mmd"), .svg = testdata.file("mermaid/info/20-comment-leading.svg") },
    .{ .name = "21-comment-tail", .source = testdata.file("mermaid/info/21-comment-tail.mmd"), .svg = testdata.file("mermaid/info/21-comment-tail.svg") },
};

test "info SVG equals what Mermaid 12.2.0 renders under GitHub's configuration" {
    for (parity_cases) |c| {
        const r = try render(std.testing.allocator, c.source, .{});
        defer free(std.testing.allocator, r);
        try std.testing.expect(r == .svg);
        std.testing.expectEqualStrings(c.svg, r.svg.bytes) catch |e| {
            std.debug.print("case {s}\n", .{c.name});
            return e;
        };
    }
}

const error_corpus = testdata.file("mermaid/preprocess/errors.json");

test "error text equals mermaid's for the same inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), error_corpus, .{});
    for (doc.array.items) |item| {
        const src = item.object.get("src").?.string;
        const r = try render(std.testing.allocator, src, .{});
        defer free(std.testing.allocator, r);
        if (item.object.get("ok").?.bool) {
            std.testing.expect(r == .svg) catch |e| {
                std.debug.print("expected an image for {s}\n", .{src});
                return e;
            };
        } else {
            std.testing.expect(r == .err) catch |e| {
                std.debug.print("expected an error for {s}\n", .{src});
                return e;
            };
            std.testing.expectEqualStrings(item.object.get("message").?.string, r.err) catch |e| {
                std.debug.print("for {s}\n", .{src});
                return e;
            };
        }
    }
}

test "the error diagram draws mermaid's bomb" {
    const r = try render(std.testing.allocator, "error", .{});
    defer free(std.testing.allocator, r);
    try std.testing.expect(r == .svg);
    try std.testing.expect(std.mem.indexOf(u8, r.svg.bytes, "Syntax error in text") != null);
    try std.testing.expectEqual(@as(f32, 512), r.svg.w);
}

test "the parser input ends with a newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("graph TD\nA-->B\n", try parserInput(arena.allocator(), "graph TD\nA-->B"));
    try std.testing.expectEqualStrings("a\n\n", try parserInput(arena.allocator(), "a\n"));
}
