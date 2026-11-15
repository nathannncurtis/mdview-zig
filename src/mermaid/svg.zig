const std = @import("std");
const Allocator = std.mem.Allocator;
const numfmt = @import("numfmt.zig");

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Size = struct { w: f32, h: f32 };

/// Builds the SVG the way mermaid's d3 code leaves the DOM: root attributes keep the order they were first set in,
/// and an element with no children is written self-closed.
pub const SvgWriter = struct {
    a: Allocator,
    root_attrs: std.ArrayList(Attr) = .empty,
    body: std.ArrayList(u8) = .empty,
    open: std.ArrayList([]const u8) = .empty,
    tag_open: bool = false,
    view_box: ?[4]f64 = null,
    max_width: ?f64 = null,
    fixed: ?Size = null,

    pub fn init(a: Allocator) SvgWriter {
        return .{ .a = a };
    }

    pub fn num(w: *SvgWriter, v: f64) Allocator.Error![]const u8 {
        return numfmt.js(w.a, v);
    }

    pub fn setRootAttr(w: *SvgWriter, name: []const u8, value: []const u8) Allocator.Error!void {
        for (w.root_attrs.items) |*at| if (std.mem.eql(u8, at.name, name)) {
            at.value = value;
            return;
        };
        try w.root_attrs.append(w.a, .{ .name = name, .value = value });
    }

    /// mermaid's `configureSvgSize`.
    pub fn configureSvgSize(w: *SvgWriter, height: f64, width: f64, use_max_width: bool) Allocator.Error!void {
        if (use_max_width) {
            try w.setRootAttr("width", "100%");
            try w.setRootAttr("style", try std.fmt.allocPrint(w.a, "max-width: {s}px;", .{try w.num(width)}));
            w.max_width = width;
            w.fixed = null;
        } else {
            try w.setRootAttr("height", try w.num(height));
            try w.setRootAttr("width", try w.num(width));
            w.fixed = .{ .w = @floatCast(width), .h = @floatCast(height) };
            w.max_width = null;
        }
    }

    pub fn setViewBox(w: *SvgWriter, x: f64, y: f64, width: f64, height: f64) Allocator.Error!void {
        w.view_box = .{ x, y, width, height };
        try w.setRootAttr("viewBox", try std.fmt.allocPrint(w.a, "{s} {s} {s} {s}", .{ try w.num(x), try w.num(y), try w.num(width), try w.num(height) }));
    }

    fn closeOpenTag(w: *SvgWriter) Allocator.Error!void {
        if (w.tag_open) {
            try w.body.append(w.a, '>');
            w.tag_open = false;
        }
    }

    pub fn start(w: *SvgWriter, tag: []const u8, attrs: []const Attr) Allocator.Error!void {
        try w.closeOpenTag();
        try w.body.append(w.a, '<');
        try w.body.appendSlice(w.a, tag);
        for (attrs) |at| try w.attr(at.name, at.value);
        try w.open.append(w.a, tag);
        w.tag_open = true;
    }

    /// Adds an attribute to the element just started.
    pub fn attr(w: *SvgWriter, name: []const u8, value: []const u8) Allocator.Error!void {
        try w.body.append(w.a, ' ');
        try w.body.appendSlice(w.a, name);
        try w.body.appendSlice(w.a, "=\"");
        try escapeInto(w.a, &w.body, value, true);
        try w.body.append(w.a, '"');
    }

    pub fn attrNum(w: *SvgWriter, name: []const u8, value: f64) Allocator.Error!void {
        try w.attr(name, try w.num(value));
    }

    pub fn end(w: *SvgWriter) Allocator.Error!void {
        const tag = w.open.pop().?;
        if (w.tag_open) {
            try w.body.appendSlice(w.a, "/>");
            w.tag_open = false;
        } else {
            try w.body.appendSlice(w.a, "</");
            try w.body.appendSlice(w.a, tag);
            try w.body.append(w.a, '>');
        }
    }

    pub fn text(w: *SvgWriter, content: []const u8) Allocator.Error!void {
        try w.closeOpenTag();
        try escapeInto(w.a, &w.body, content, false);
    }

    /// An element holding only text.
    pub fn textElement(w: *SvgWriter, tag: []const u8, attrs: []const Attr, content: []const u8) Allocator.Error!void {
        try w.start(tag, attrs);
        try w.text(content);
        try w.end();
    }

    pub fn leaf(w: *SvgWriter, tag: []const u8, attrs: []const Attr) Allocator.Error!void {
        try w.start(tag, attrs);
        try w.end();
    }

    /// The natural size a browser gives the finished image.
    pub fn size(w: *const SvgWriter) Size {
        if (w.max_width) |mw| {
            if (w.view_box) |vb| return .{ .w = @floatCast(mw), .h = @floatCast(mw * vb[3] / vb[2]) };
            // an inline SVG with no viewBox measures max-width by 150 in Chromium
            return .{ .w = @floatCast(mw), .h = 150 };
        }
        if (w.fixed) |f| return f;
        if (w.view_box) |vb| return .{ .w = @floatCast(vb[2]), .h = @floatCast(vb[3]) };
        return .{ .w = 300, .h = 150 };
    }

    pub fn finish(w: *SvgWriter) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(w.a, "<svg");
        for (w.root_attrs.items) |at| {
            try out.append(w.a, ' ');
            try out.appendSlice(w.a, at.name);
            try out.appendSlice(w.a, "=\"");
            try escapeInto(w.a, &out, at.value, true);
            try out.append(w.a, '"');
        }
        try out.append(w.a, '>');
        try out.appendSlice(w.a, w.body.items);
        try out.appendSlice(w.a, "</svg>");
        return out.items;
    }
};

pub fn escapeInto(a: Allocator, out: *std.ArrayList(u8), s: []const u8, in_attr: bool) Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => if (in_attr) try out.appendSlice(a, "&quot;") else try out.append(a, c),
        else => try out.append(a, c),
    };
}

/// d3's `selection.style(name, value)` serialisation for a list of properties.
pub fn styleAttr(a: Allocator, props: []const Attr) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (props, 0..) |p, i| {
        if (i > 0) try out.append(a, ' ');
        try out.print(a, "{s}: {s};", .{ p.name, p.value });
    }
    return out.items;
}

test "writer closes empty elements and escapes text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = SvgWriter.init(arena.allocator());
    try w.setRootAttr("id", "x");
    try w.configureSvgSize(100, 400, true);
    try w.leaf("g", &.{});
    try w.start("g", &.{});
    try w.textElement("text", &.{.{ .name = "x", .value = "1" }}, "a<b&c");
    try w.end();
    try std.testing.expectEqualStrings("<svg id=\"x\" width=\"100%\" style=\"max-width: 400px;\"><g/><g><text x=\"1\">a&lt;b&amp;c</text></g></svg>", try w.finish());
    try std.testing.expectEqual(@as(f32, 400), w.size().w);
}
