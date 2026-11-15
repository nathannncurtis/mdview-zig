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

    /// The part of `r` inside `o`, with zero size when they do not meet.
    pub fn clip(r: Rect, o: Rect) Rect {
        const x0 = @max(r.x, o.x);
        const y0 = @max(r.y, o.y);
        const x1 = @min(r.x + r.w, o.x + o.w);
        const y1 = @min(r.y + r.h, o.y + o.h);
        return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0), .h = @max(y1 - y0, 0) };
    }
};

/// The frame GitHub draws a diagram in is at least this tall.
pub const min_frame_h: f32 = 180;
/// The height of the block while its diagram renders, with the spinner in it.
pub const pending_h: f32 = 101;
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
pub const frame_icon: u24 = 0xf0f6fc;
pub const action_icon: u24 = 0x9198a1;
pub const icon_size: f32 = 16;

/// The expand and copy buttons at the top right of the block, outside the frame's own controls.
pub const action_size: f32 = 34;
pub const action_gap: f32 = 8;
pub const action_inset: f32 = 8;

pub const Button = enum { zoom_in, up, left, reset, right, down, zoom_out, expand, copy };

pub fn isAction(b: Button) bool {
    return b == .expand or b == .copy;
}

/// The Octicon a button shows.
pub fn iconName(b: Button) []const u8 {
    return if (b == .reset) "sync" else @tagName(b);
}

pub fn iconColor(b: Button, copied: bool) u24 {
    if (b == .copy and copied) return check_icon;
    return if (isAction(b)) action_icon else frame_icon;
}

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
        .expand, .copy => .{ 0, 0 },
    };
}

pub fn buttonRect(frame: Rect, b: Button) Rect {
    if (isAction(b)) {
        const copy_x = frame.x + frame.w - action_inset - action_size;
        const x = if (b == .copy) copy_x else copy_x - action_gap - action_size;
        return .{ .x = x, .y = frame.y + action_inset, .w = action_size, .h = action_size };
    }
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

/// The button under a point; `actions` is false in the dialog, whose frame has only the zoom and pan buttons.
pub fn buttonAt(frame: Rect, px: f32, py: f32, actions: bool) ?Button {
    for (std.enums.values(Button)) |b| {
        if (isAction(b) and !actions) continue;
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
        .expand, .copy => {},
    }
}

/// The dialog the expand button opens: at most 1152 wide, a tenth of the window down, holding a frame as tall as the inline one.
pub const modal_max_w: f32 = 1152;
pub const modal_inset: f32 = 33;
pub const modal_extra_h: f32 = 65;
pub const modal_bg: u24 = 0x0d1117;
pub const modal_border: u24 = 0x3d444d;
pub const modal_backdrop: u24 = 0x212830;
pub const modal_backdrop_alpha: f32 = 0.4;
pub const close_icon: u24 = 0x9198a1;

pub fn modalRect(win_w: f32, win_h: f32, frame_h: f32) Rect {
    const w = @min(modal_max_w, win_w);
    return .{ .x = (win_w - w) / 2, .y = win_h * 0.1, .w = w, .h = frame_h + modal_extra_h };
}

pub fn modalFrame(m: Rect, frame_h: f32) Rect {
    return .{ .x = m.x + modal_inset, .y = m.y + modal_inset, .w = m.w - 2 * modal_inset, .h = frame_h };
}

pub fn closeRect(m: Rect) Rect {
    return .{ .x = m.x + m.w - 33, .y = m.y + 1, .w = 32, .h = 34 };
}

/// The "Copied!" tooltip under the copy button: GitHub's `tooltipped-s` bubble.
pub const tip_bg: u24 = 0x3d444d;
pub const tip_text: u24 = 0xffffff;
pub const tip_font_px: f32 = 12;
pub const tip_pad_x: f32 = 8;
pub const tip_h: f32 = 27.5;
pub const tip_radius: f32 = 6;
pub const tip_top: f32 = 39;
pub const tip_fade_ms: f32 = 100;
pub const copy_feedback_ms: i64 = 2000;
pub const check_icon: u24 = 0x3fb950;

pub fn tipRect(button: Rect, text_w: f32) Rect {
    const w = text_w + 2 * tip_pad_x;
    return .{ .x = button.x + button.w / 2 - w / 2, .y = button.y + tip_top, .w = w, .h = tip_h };
}

/// The dialog's `fade-in` runs 0.3s ease-in-out; the tooltip's `tooltip-appear` 0.1s ease-in.
pub const dialog_fade_ms: f32 = 300;

/// The y of a CSS cubic-bezier(x1, y1, x2, y2) timing function at progress `t`.
pub fn ease(x1: f32, y1: f32, x2: f32, y2: f32, t: f32) f32 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..24) |_| {
        const mid = (lo + hi) / 2;
        if (bezier(x1, x2, mid) < t) lo = mid else hi = mid;
    }
    return bezier(y1, y2, (lo + hi) / 2);
}

fn bezier(p1: f32, p2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

pub fn easeInOut(t: f32) f32 {
    return ease(0.42, 0, 0.58, 1, t);
}

pub fn easeIn(t: f32) f32 {
    return ease(0.42, 0, 1, 1, t);
}

/// `box-shadow: 0 0 18px rgba(0, 0, 0, .4)` of the dialog as stacked translucent rings, outermost first.
pub const shadow_blur: f32 = 18;
pub const shadow_alpha: f32 = 0.4;
pub const shadow_rings = 9;

pub const Ring = struct { grow: f32, alpha: f32 };

fn shadowCoverage(d: f32) f32 {
    const sigma = shadow_blur / 2;
    return shadow_alpha * 0.5 * (1 - erf(d / (sigma * std.math.sqrt2)));
}

fn erf(x: f32) f32 {
    const t = 1 / (1 + 0.3275911 * @abs(x));
    const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-x * x);
    return if (x < 0) -y else y;
}

/// Ring `i` grows the dialog's rectangle by `grow` and fills it with `alpha`; painted in order they add up to the blur.
pub fn shadowRing(i: usize) Ring {
    const step = shadow_blur / shadow_rings;
    const grow = shadow_blur - step * @as(f32, @floatFromInt(i));
    const target = shadowCoverage(grow - step / 2);
    const outer = if (i == 0) 0 else shadowCoverage(grow - step / 2 + step);
    return .{ .grow = grow, .alpha = 1 - (1 - target) / (1 - outer) };
}

pub const Pt = [2]f32;
pub const spinner_segments = 24;
pub const spinner_arc_points = 9;
pub const spinner_stroke: f32 = 2;

/// The spinner is 16 wide, its ring a circle of radius 7 and its arc a quarter of it that turns once a second.
pub fn spinnerRing() [spinner_segments + 1]Pt {
    // SAFETY: every point is set by the loop below
    var out: [spinner_segments + 1]Pt = undefined;
    for (&out, 0..) |*p, i| {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / spinner_segments;
        p.* = .{ 8 + 7 * @cos(a), 8 + 7 * @sin(a) };
    }
    return out;
}

pub fn spinnerArc(turn: f32) [spinner_arc_points]Pt {
    // SAFETY: every point is set by the loop below
    var out: [spinner_arc_points]Pt = undefined;
    const start = std.math.tau * turn;
    for (&out, 0..) |*p, i| {
        const a = start - std.math.pi / 2.0 * @as(f32, @floatFromInt(i)) / (spinner_arc_points - 1);
        p.* = .{ 8 + 7 * @cos(a), 8 + 7 * @sin(a) };
    }
    return out;
}

/// Where the spinner sits in a block `w` wide: centred, 40 below the top.
pub fn spinnerAt(block: Rect) Pt {
    return .{ block.x + block.w / 2 - 8, block.y + 40 };
}

/// The padding of the error box, the gap under its title and its text offset: GitHub's `flash-error` box.
pub const error_top: f32 = 21;
pub const error_left: f32 = 17;
pub const error_title_gap: f32 = 16;
pub const error_bg: u24 = 0x0d1117;

/// The `font-family` GitHub sets on the error box; the backends draw text in the family this resolves to on their platform.
pub const github_font_stack = "\"Mona Sans VF\", -apple-system, BlinkMacSystemFont, \"Segoe UI\", \"Noto Sans Backtick Fix\", \"Noto Sans\", Helvetica, Arial, sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\"";

pub const docs_url = "https://docs.github.com/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams#creating-mermaid-diagrams";
pub const error_title = "Unable to render rich display";

pub const ErrorText = struct {
    body: []u8,
    link_start: u32,
    link_len: u32,
};

/// The message under GitHub's error title: lines with white space collapsed as HTML does, a blank line, then the docs link.
pub fn errorBody(gpa: Allocator, message: []const u8) Allocator.Error!ErrorText {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
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
    try out.appendSlice(gpa, "\nFor more information, see ");
    const link_start = out.items.len;
    try out.appendSlice(gpa, docs_url);
    return .{
        .body = try out.toOwnedSlice(gpa),
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
    try std.testing.expectEqual(Button.reset, buttonAt(frame, rs.x + 5, rs.y + 5, true).?);
    try std.testing.expectEqual(Button.zoom_out, buttonAt(frame, zo.x + 31, zo.y + 31, true).?);
    try std.testing.expect(buttonAt(frame, zo.x + 33, zo.y + 5, true) == null);
    try std.testing.expect(buttonAt(frame, 110, 60, true) == null);
    for (std.enums.values(Button)) |b| {
        const r = buttonRect(frame, b);
        try std.testing.expect(frame.contains(r.x, r.y) and frame.contains(r.x + r.w - 0.1, r.y + r.h - 0.1));
    }
}

test "expand and copy sit at the top right, 8 in from the edge and 8 apart, and only on the inline frame" {
    const frame: Rect = .{ .x = 370, .y = 1000, .w = 861, .h = 198 };
    const copy = buttonRect(frame, .copy);
    const expand = buttonRect(frame, .expand);
    try std.testing.expectEqual(@as(f32, 861 + 370 - 8 - 34), copy.x);
    try std.testing.expectEqual(@as(f32, 1008), copy.y);
    try std.testing.expectEqual(@as(f32, 777 + 370), expand.x);
    try std.testing.expectEqual(@as(f32, 819 + 370), copy.x);
    try std.testing.expectEqual(Button.copy, buttonAt(frame, copy.x + 3, copy.y + 3, true).?);
    try std.testing.expect(buttonAt(frame, copy.x + 3, copy.y + 3, false) == null);
}

test "zoom steps by a tenth within 0.5 to 8, pan by 100 the way GitHub's buttons do, reset clears both" {
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

test "the dialog matches GitHub's at 1280 by 900 with a 198 tall frame" {
    const m = modalRect(1280, 900, 198);
    try std.testing.expectEqual(@as(f32, 64), m.x);
    try std.testing.expectEqual(@as(f32, 90), m.y);
    try std.testing.expectEqual(@as(f32, 1152), m.w);
    try std.testing.expectEqual(@as(f32, 263), m.h);
    const f = modalFrame(m, 198);
    try std.testing.expectEqual(@as(f32, 33), f.x - m.x);
    try std.testing.expectEqual(@as(f32, 1086), f.w);
    const c = closeRect(m);
    try std.testing.expectEqual(@as(f32, 1119), c.x - m.x);
    try std.testing.expectEqual(@as(f32, 1), c.y - m.y);
}

test "clipping keeps the part of a rectangle inside another" {
    const r: Rect = .{ .x = -50, .y = 10, .w = 200, .h = 100 };
    const c = r.clip(.{ .x = 0, .y = 0, .w = 100, .h = 60 });
    try std.testing.expectEqual(@as(f32, 0), c.x);
    try std.testing.expectEqual(@as(f32, 100), c.w);
    try std.testing.expectEqual(@as(f32, 50), c.h);
    try std.testing.expectEqual(@as(f32, 0), r.clip(.{ .x = 500, .y = 0, .w = 10, .h = 10 }).w);
}

test "the spinner ring is closed and the arc starts at the right and ends at the top" {
    const ring = spinnerRing();
    try std.testing.expectApproxEqAbs(ring[0][0], ring[spinner_segments][0], 0.001);
    const arc = spinnerArc(0);
    try std.testing.expectApproxEqAbs(@as(f32, 15), arc[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), arc[0][1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), arc[spinner_arc_points - 1][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), arc[spinner_arc_points - 1][1], 0.001);
}

test "the error body collapses white space, leaves a blank line and ends in the docs link" {
    const e = try errorBody(std.testing.allocator, "Parse error on line 2:\n...a b\n----^\nExpecting 'A',   'B', got 'C'\n");
    defer std.testing.allocator.free(e.body);
    try std.testing.expectEqualStrings(
        "Parse error on line 2:\n...a b\n----^\nExpecting 'A', 'B', got 'C'\n\nFor more information, see " ++ docs_url,
        e.body,
    );
    try std.testing.expectEqualStrings(docs_url, e.body[e.link_start..][0..e.link_len]);
}

test "easing starts at 0, ends at 1 and ease-in-out is symmetric" {
    try std.testing.expectEqual(@as(f32, 0), easeInOut(0));
    try std.testing.expectEqual(@as(f32, 1), easeIn(1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOut(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), easeInOut(0.25) + easeInOut(0.75), 0.001);
    try std.testing.expect(easeIn(0.5) < 0.5);
}

test "the shadow rings add up to half the alpha at the edge and fade out to nothing" {
    var cover: f32 = 0;
    var last_alpha: f32 = 0;
    for (0..shadow_rings) |i| {
        const r = shadowRing(i);
        try std.testing.expect(r.alpha >= 0 and r.alpha < 0.2);
        try std.testing.expect(r.grow <= shadow_blur and r.grow > 0);
        last_alpha = r.alpha;
        cover = 1 - (1 - cover) * (1 - r.alpha);
        if (i > 0) try std.testing.expect(r.grow < shadowRing(i - 1).grow);
    }
    try std.testing.expect(last_alpha > 0);
    try std.testing.expectApproxEqAbs(shadow_alpha * 0.5, cover, 0.03);
}

test "the tooltip sits centred 39 below the top of the button" {
    const b: Rect = .{ .x = 1000, .y = 100, .w = 34, .h = 34 };
    const t = tipRect(b, 41.19);
    try std.testing.expectApproxEqAbs(@as(f32, 57.19), t.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1017) - t.w / 2, t.x, 0.01);
    try std.testing.expectEqual(@as(f32, 139), t.y);
    try std.testing.expectEqual(@as(f32, 27.5), t.h);
}
