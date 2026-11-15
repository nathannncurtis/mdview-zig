const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

/// The frame GitHub draws a diagram in is at least this tall.
pub const min_frame_h: f32 = 180;
pub const button_size: f32 = 32;
pub const button_gap: f32 = 2.4;
pub const button_inset: f32 = 12;
pub const button_radius: f32 = 6;
pub const zoom_step: f32 = 0.1;
pub const zoom_min: f32 = 0.5;
pub const zoom_max: f32 = 8;
pub const pan_step: f32 = 100;

/// Colours of the Primer button GitHub uses for the controls.
pub const button_bg: u24 = 0x212830;
pub const button_border: u24 = 0x3d444d;
pub const button_icon: u24 = 0xf0f6fc;
pub const icon_size: f32 = 16;
pub const icon_stroke: f32 = 1.6;

pub const Button = enum { zoom_in, up, left, reset, right, down, zoom_out };

pub const State = struct {
    zoom: f32 = 1,
    x: f32 = 0,
    y: f32 = 0,
};

pub fn frameHeight(diagram_h: f32) f32 {
    return @max(diagram_h, min_frame_h);
}

/// Where the diagram is drawn: centred at the top of the frame, then scaled about its middle and moved by the pan offset.
pub fn placed(frame: Rect, w: f32, h: f32, st: State) Rect {
    const cx = frame.x + frame.w / 2 + st.x;
    const cy = frame.y + h / 2 + st.y;
    return .{ .x = cx - w * st.zoom / 2, .y = cy - h * st.zoom / 2, .w = w * st.zoom, .h = h * st.zoom };
}

fn cell(b: Button) [2]f32 {
    return switch (b) {
        .up => .{ 1, 0 },
        .zoom_in => .{ 2, 0 },
        .left => .{ 0, 1 },
        .reset => .{ 1, 1 },
        .right => .{ 2, 1 },
        .down => .{ 1, 2 },
        .zoom_out => .{ 2, 2 },
    };
}

pub fn buttonRect(frame: Rect, b: Button) Rect {
    const pitch = button_size + button_gap;
    const grid = 3 * button_size + 2 * button_gap;
    const c = cell(b);
    return .{
        .x = frame.x + frame.w - button_inset - grid + c[0] * pitch,
        .y = frame.y + frame.h - button_inset - grid + c[1] * pitch,
        .w = button_size,
        .h = button_size,
    };
}

pub fn buttonAt(frame: Rect, px: f32, py: f32) ?Button {
    for (std.enums.values(Button)) |b| {
        if (buttonRect(frame, b).contains(px, py)) return b;
    }
    return null;
}

pub fn press(st: *State, b: Button) void {
    switch (b) {
        .zoom_in => st.zoom = @min(st.zoom + zoom_step, zoom_max),
        .zoom_out => st.zoom = @max(st.zoom - zoom_step, zoom_min),
        .reset => st.* = .{},
        .up => st.y += pan_step,
        .down => st.y -= pan_step,
        .left => st.x += pan_step,
        .right => st.x -= pan_step,
    }
}

pub const Pt = [2]f32;
pub const Stroke = []const Pt;

const plus = [_]Stroke{ &.{ .{ 8, 3 }, .{ 8, 13 } }, &.{ .{ 3, 8 }, .{ 13, 8 } } };
const minus = [_]Stroke{&.{ .{ 3, 8 }, .{ 13, 8 } }};
const chev_up = [_]Stroke{&.{ .{ 3.5, 10.5 }, .{ 8, 6 }, .{ 12.5, 10.5 } }};
const chev_down = [_]Stroke{&.{ .{ 3.5, 5.5 }, .{ 8, 10 }, .{ 12.5, 5.5 } }};
const chev_left = [_]Stroke{&.{ .{ 10.5, 3.5 }, .{ 6, 8 }, .{ 10.5, 12.5 } }};
const chev_right = [_]Stroke{&.{ .{ 5.5, 3.5 }, .{ 10, 8 }, .{ 5.5, 12.5 } }};

const sync_radius = 4.8;
const sync_arc: [10]Pt = blk: {
    // SAFETY: every element is set by the loop below
    var arc: [10]Pt = undefined;
    for (&arc, 0..) |*p, i| {
        const a = std.math.degreesToRadians(20.0 + 30.0 * @as(f32, @floatFromInt(i)));
        p.* = .{ 8 + sync_radius * @cos(a), 8 + sync_radius * @sin(a) };
    }
    break :blk arc;
};
const sync_head: [3]Pt = blk: {
    const a = std.math.degreesToRadians(290.0);
    const tip = sync_arc[9];
    const t: Pt = .{ -@sin(a), @cos(a) };
    const n: Pt = .{ @cos(a), @sin(a) };
    break :blk .{
        .{ tip[0] - 2.5 * t[0] + 2.3 * n[0], tip[1] - 2.5 * t[1] + 2.3 * n[1] },
        tip,
        .{ tip[0] - 2.5 * t[0] - 2.3 * n[0], tip[1] - 2.5 * t[1] - 2.3 * n[1] },
    };
};
const sync = [_]Stroke{ &sync_arc, &sync_head };

/// The icon of a button as strokes in a 16 by 16 box.
pub fn glyph(b: Button) []const Stroke {
    return switch (b) {
        .zoom_in => &plus,
        .zoom_out => &minus,
        .up => &chev_up,
        .down => &chev_down,
        .left => &chev_left,
        .right => &chev_right,
        .reset => &sync,
    };
}

pub const docs_url = "https://docs.github.com/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams#creating-mermaid-diagrams";
pub const error_title = "Unable to render rich display";

pub const ErrorText = struct {
    text: []u8,
    title_len: u32,
    link_start: u32,
    link_len: u32,
};

/// What GitHub shows in its error box: the title, then the message with white space collapsed as HTML does, then the docs link.
pub fn errorText(gpa: Allocator, message: []const u8) Allocator.Error!ErrorText {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, error_title);
    try out.appendSlice(gpa, "\n\n");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, message, "\n"), '\n');
    while (lines.next()) |raw| {
        var words = std.mem.tokenizeAny(u8, raw, " \t\r");
        var first = true;
        while (words.next()) |w| {
            if (!first) try out.append(gpa, ' ');
            try out.appendSlice(gpa, w);
            first = false;
        }
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "For more information, see ");
    const link_start = out.items.len;
    try out.appendSlice(gpa, docs_url);
    return .{
        .text = try out.toOwnedSlice(gpa),
        .title_len = error_title.len,
        .link_start = @intCast(link_start),
        .link_len = docs_url.len,
    };
}

test "buttons sit in a 3 by 3 grid at the bottom right and hit test by cell" {
    const frame: Rect = .{ .x = 100, .y = 50, .w = 600, .h = 200 };
    const zi = buttonRect(frame, .zoom_in);
    const zo = buttonRect(frame, .zoom_out);
    const rs = buttonRect(frame, .reset);
    try std.testing.expectApproxEqAbs(@as(f32, 700 - 12 - 32), zi.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 250 - 12 - 3 * 32 - 2 * 2.4), zi.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 700 - 12 - 32), zo.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 250 - 12 - 32), zo.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 700 - 12 - 32 - 34.4), rs.x, 0.01);
    try std.testing.expectEqual(Button.reset, buttonAt(frame, rs.x + 5, rs.y + 5).?);
    try std.testing.expectEqual(Button.zoom_out, buttonAt(frame, zo.x + 31, zo.y + 31).?);
    try std.testing.expect(buttonAt(frame, zo.x + 33, zo.y + 5) == null);
    try std.testing.expect(buttonAt(frame, 110, 60) == null);
    for (std.enums.values(Button)) |b| {
        const r = buttonRect(frame, b);
        try std.testing.expect(frame.contains(r.x, r.y) and frame.contains(r.x + r.w - 0.1, r.y + r.h - 0.1));
    }
}

test "zoom steps by a tenth within 0.5 to 8, pan by 100, reset clears both" {
    var st: State = .{};
    for (0..100) |_| press(&st, .zoom_in);
    try std.testing.expectEqual(zoom_max, st.zoom);
    for (0..100) |_| press(&st, .zoom_out);
    try std.testing.expectEqual(zoom_min, st.zoom);
    press(&st, .up);
    press(&st, .left);
    press(&st, .left);
    try std.testing.expectEqual(@as(f32, 100), st.y);
    try std.testing.expectEqual(@as(f32, 200), st.x);
    press(&st, .down);
    press(&st, .right);
    try std.testing.expectEqual(@as(f32, 0), st.y);
    try std.testing.expectEqual(@as(f32, 100), st.x);
    press(&st, .reset);
    try std.testing.expectEqual(@as(f32, 1), st.zoom);
    try std.testing.expectEqual(@as(f32, 0), st.x);
}

test "the diagram is centred, scaled about its middle and panned" {
    const frame: Rect = .{ .x = 10, .y = 20, .w = 400, .h = 180 };
    const r = placed(frame, 200, 100, .{});
    try std.testing.expectEqual(@as(f32, 110), r.x);
    try std.testing.expectEqual(@as(f32, 20), r.y);
    const z = placed(frame, 200, 100, .{ .zoom = 2, .x = 5, .y = -5 });
    try std.testing.expectEqual(@as(f32, 400), z.w);
    try std.testing.expectEqual(@as(f32, 15), z.x);
    try std.testing.expectEqual(@as(f32, -35), z.y);
    try std.testing.expectEqual(@as(f32, 180), frameHeight(40));
    try std.testing.expectEqual(@as(f32, 300), frameHeight(300));
}

test "the error text collapses white space and ends in the docs link" {
    const e = try errorText(std.testing.allocator, "Parse error on line 2:\n...a b\n----^\nExpecting 'A',   'B', got 'C'\n");
    defer std.testing.allocator.free(e.text);
    try std.testing.expectEqualStrings(
        "Unable to render rich display\n\nParse error on line 2:\n...a b\n----^\nExpecting 'A', 'B', got 'C'\nFor more information, see " ++ docs_url,
        e.text,
    );
    try std.testing.expectEqualStrings(error_title, e.text[0..e.title_len]);
    try std.testing.expectEqualStrings(docs_url, e.text[e.link_start..][0..e.link_len]);
}
