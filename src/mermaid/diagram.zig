const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const config = @import("config.zig");
const svg = @import("svg.zig");
const layout = @import("layout.zig");

/// The Mermaid release everything here is ported from.
pub const version = "12.2.0";

pub const Error = error{ Parse, Layout, Timeout, OutOfMemory };

pub const ClassDef = struct { id: []const u8, styles: []const []const u8 = &.{}, text_styles: []const []const u8 = &.{} };

pub const Acc = struct { title: ?[]const u8 = null, descr: ?[]const u8 = null };

/// Time limit for one diagram, checked by layout loops through `Ctx.tick`.
pub const Deadline = struct {
    clock: ?*const fn () i64 = null,
    start: i64 = 0,
    limit_ns: i64 = 0,
    ticks: u32 = 0,

    pub fn check(d: *Deadline) error{Timeout}!void {
        d.ticks +%= 1;
        const clock = d.clock orelse return;
        if (d.ticks & 63 != 1) return;
        if (clock() - d.start > d.limit_ns) return error.Timeout;
    }
};

pub const Ctx = struct {
    a: Allocator,
    cfg: *const config.Config,
    measurer: text.Measurer,
    deadline: *Deadline,
    svg_id: []const u8,
    version: []const u8 = version,
    title: ?[]const u8 = null,
    /// Lines the front matter occupied, for diagrams that report source positions.
    frontmatter_line_offset: usize = 0,
    /// The layout engine the config selects for this diagram.
    layout: layout.Choice = .{ .name = "dagre", .engine = .dagre },
    /// What goes under "Unable to render rich display" when a stage fails with `error.Parse`.
    err_msg: ?[]const u8 = null,

    pub fn tick(ctx: *Ctx) error{Timeout}!void {
        try ctx.deadline.check();
    }

    pub fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) error{ Parse, OutOfMemory } {
        ctx.err_msg = try std.fmt.allocPrint(ctx.a, fmt, args);
        return error.Parse;
    }
};

/// A diagram type: parse the text into a model, lay it out into geometry, emit the SVG.
pub const Def = struct {
    id: []const u8,
    parse: *const fn (ctx: *Ctx, source: []const u8) Error!*anyopaque,
    layout: *const fn (ctx: *Ctx, model: *anyopaque) Error!*anyopaque,
    emit: *const fn (ctx: *Ctx, model: *anyopaque, geometry: *anyopaque, w: *svg.SvgWriter) Error!void,
    /// The diagram's own stylesheet (its `styles.ts`), before scoping.
    styles: ?*const fn (ctx: *Ctx) Error![]const u8 = null,
    /// Parse the text with its `%%` comment lines still in, as diagrams that report source positions do.
    preserve_comments: bool = false,
    class_defs: ?*const fn (ctx: *Ctx, model: *anyopaque) Error![]const ClassDef = null,
    acc: ?*const fn (ctx: *Ctx, model: *anyopaque) Acc = null,
};
