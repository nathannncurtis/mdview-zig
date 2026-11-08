const std = @import("std");
const Allocator = std.mem.Allocator;
pub const env = @import("env.zig");
const parse_mod = @import("parse.zig");
const render_mod = @import("render.zig");
const dom = @import("dom.zig");
const styles = @import("styles.zig");
const numfmt = env.numfmt;

pub const Options = struct {
    id: []const u8 = "diagram",
    conf: env.Conf = .{},
    theme: env.Theme,
    measurer: env.Measurer,
    /// Front matter title, applied before the source is parsed.
    title: ?[]const u8 = null,
    deadline: ?*env.Deadline = null,
    /// Page elements by id, read by `details`.
    elements: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    /// The common stylesheet that precedes this diagram's rules (supplied by core).
    base_css: []const u8 = "",
};

pub const Output = render_mod.Output;
pub const fuzz = @import("fuzz_test.zig");

pub const Result = union(enum) {
    ok: Output,
    err: []const u8,
};

/// Port of the sequence diagram's db, parser and renderer; the source starts at `sequenceDiagram`.
pub fn render(a: Allocator, source: []const u8, o: Options) Allocator.Error!Result {
    var conf = o.conf;
    if (conf.font_family.len > 0) {
        conf.actor_font_family = conf.font_family;
        conf.note_font_family = conf.font_family;
        conf.message_font_family = conf.font_family;
    }
    if (conf.font_size != 0) {
        conf.actor_font_size = conf.font_size;
        conf.note_font_size = conf.font_size;
        conf.message_font_size = conf.font_size;
    }
    if (conf.font_weight) |w| {
        conf.actor_font_weight = w;
        conf.note_font_weight = w;
        conf.message_font_weight = w;
    }
    if (conf.root_wrap) |w| if (w) {
        conf.wrap = true;
    };
    const conf_ptr = try a.create(env.Conf);
    conf_ptr.* = conf;
    const parsed = try parse_mod.parse(a, conf_ptr, source, o.title, o.elements);
    const db = switch (parsed) {
        .ok => |d| d,
        .err => |f| return .{ .err = f.message },
    };
    const d: dom.Dom = .{ .a = a };
    const root = try d.create(null, "svg");
    const style = try d.append(root, "style");
    d.text(style, try std.mem.concat(a, u8, &.{ o.base_css, try styles.css(a, o.id, o.theme, conf.look == .neo) }));
    _ = try d.append(root, "g");
    var r: render_mod.Renderer = .{ .a = a, .d = d, .conf = conf, .db = db, .m = o.measurer, .theme = o.theme, .id = o.id, .root = root, .deadline = o.deadline };
    r.draw() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return .{ .err = "Diagram took too long to render" },
        error.BadModel => return .{ .err = "Cannot read properties of undefined (reading 'x')" },
    };
    try d.attr(root, "id", o.id);
    try d.attr(root, "width", "100%");
    try d.attr(root, "xmlns", "http://www.w3.org/2000/svg");
    if (conf.use_max_width) {
        try d.attr(root, "style", try std.fmt.allocPrint(a, "max-width: {s}px;", .{try numfmt.js(a, r.out_w)}));
    } else {
        try d.attrNum(root, "height", r.out_h);
        try d.attrNum(root, "width", r.out_w);
    }
    try d.attr(root, "viewBox", try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ try numfmt.js(a, r.vb[0]), try numfmt.js(a, r.vb[1]), try numfmt.js(a, r.vb[2]), try numfmt.js(a, r.vb[3]) }));
    try d.attr(root, "role", "graphics-document document");
    try d.attr(root, "aria-roledescription", "sequence");
    var out: std.ArrayList(u8) = .empty;
    try d.serialize(&out, root);
    return .{ .ok = .{ .svg = out.items, .width = r.out_w, .height = r.out_h, .view_box = r.vb } };
}

test {
    _ = @import("parse.zig");
    _ = @import("sanitize.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("parity_test.zig");
    _ = @import("actions.zig");
}
