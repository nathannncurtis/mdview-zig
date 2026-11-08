const std = @import("std");
const Allocator = std.mem.Allocator;
pub const numfmt = @import("../numfmt.zig");

pub const text = @import("../text.zig");
pub const Measurer = text.Measurer;
pub const Deadline = @import("../diagram.zig").Deadline;

pub const Dim = struct { w: f64, h: f64 };

pub const Theme = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, name: []const u8) ?[]const u8,

    pub fn get(t: Theme, name: []const u8) ?[]const u8 {
        return t.getFn(t.ctx, name);
    }

    pub fn str(t: Theme, name: []const u8) []const u8 {
        return t.get(name) orelse "";
    }
};

pub const Look = enum { neo, classic };

pub const Conf = struct {
    look: Look = .neo,
    hide_unused_participants: bool = false,
    activation_width: f64 = 10,
    diagram_margin_x: f64 = 50,
    diagram_margin_y: f64 = 40,
    actor_margin: f64 = 50,
    width: f64 = 150,
    height: f64 = 65,
    box_margin: f64 = 10,
    box_text_margin: f64 = 5,
    note_margin: f64 = 10,
    message_margin: f64 = 35,
    message_align: []const u8 = "center",
    mirror_actors: bool = true,
    force_menus: bool = false,
    bottom_margin_adj: f64 = 1,
    right_angles: bool = false,
    show_sequence_numbers: bool = false,
    actor_font_size: f64 = 14,
    actor_font_family: []const u8 = "\"Open Sans\", sans-serif",
    actor_font_weight: []const u8 = "400",
    note_font_size: f64 = 14,
    note_font_family: []const u8 = "\"trebuchet ms\", verdana, arial, sans-serif",
    note_font_weight: []const u8 = "400",
    note_align: []const u8 = "center",
    message_font_size: f64 = 16,
    message_font_family: []const u8 = "\"trebuchet ms\", verdana, arial, sans-serif",
    message_font_weight: []const u8 = "400",
    wrap: bool = false,
    wrap_padding: f64 = 10,
    label_box_width: f64 = 50,
    label_box_height: f64 = 20,
    use_max_width: bool = true,

    font_family: []const u8 = "\"trebuchet ms\", verdana, arial, sans-serif;",
    font_size: f64 = 16,
    font_weight: ?[]const u8 = null,
    root_wrap: ?bool = null,
    rect_bkg_color: ?[]const u8 = null,

    /// Applies an init-directive style JSON object (`{"sequence": {...}, "fontFamily": ...}`).
    pub fn applyJson(c: *Conf, a: Allocator, v: std.json.Value) Allocator.Error!void {
        if (v != .object) return;
        var it = v.object.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (std.mem.eql(u8, k, "sequence")) {
                if (val == .object) try c.applySequence(a, val.object);
            } else if (std.mem.eql(u8, k, "look")) {
                if (val == .string) c.look = if (std.mem.eql(u8, val.string, "neo")) .neo else .classic;
            } else if (std.mem.eql(u8, k, "fontFamily")) {
                if (val == .string) c.font_family = try a.dupe(u8, val.string);
            } else if (std.mem.eql(u8, k, "fontSize")) {
                if (jsonNum(val)) |n| c.font_size = n;
            } else if (std.mem.eql(u8, k, "fontWeight")) {
                c.font_weight = try jsonText(a, val);
            } else if (std.mem.eql(u8, k, "wrap")) {
                if (val == .bool) c.root_wrap = val.bool;
            } else if (std.mem.eql(u8, k, "themeVariables")) {
                if (val == .object) if (val.object.get("rectBkgColor")) |r| if (r == .string) {
                    c.rect_bkg_color = try a.dupe(u8, r.string);
                };
            }
        }
    }

    fn applySequence(c: *Conf, a: Allocator, o: std.json.ObjectMap) Allocator.Error!void {
        const fields = [_]struct { []const u8, []const u8 }{
            .{ "activationWidth", "activation_width" },
            .{ "diagramMarginX", "diagram_margin_x" },
            .{ "diagramMarginY", "diagram_margin_y" },
            .{ "actorMargin", "actor_margin" },
            .{ "width", "width" },
            .{ "height", "height" },
            .{ "boxMargin", "box_margin" },
            .{ "boxTextMargin", "box_text_margin" },
            .{ "noteMargin", "note_margin" },
            .{ "messageMargin", "message_margin" },
            .{ "bottomMarginAdj", "bottom_margin_adj" },
            .{ "actorFontSize", "actor_font_size" },
            .{ "noteFontSize", "note_font_size" },
            .{ "messageFontSize", "message_font_size" },
            .{ "wrapPadding", "wrap_padding" },
            .{ "labelBoxWidth", "label_box_width" },
            .{ "labelBoxHeight", "label_box_height" },
        };
        inline for (fields) |f| if (o.get(f[0])) |v| if (jsonNum(v)) |n| {
            @field(c, f[1]) = n;
        };
        const bools = [_]struct { []const u8, []const u8 }{
            .{ "hideUnusedParticipants", "hide_unused_participants" },
            .{ "mirrorActors", "mirror_actors" },
            .{ "forceMenus", "force_menus" },
            .{ "rightAngles", "right_angles" },
            .{ "showSequenceNumbers", "show_sequence_numbers" },
            .{ "wrap", "wrap" },
            .{ "useMaxWidth", "use_max_width" },
        };
        inline for (bools) |f| if (o.get(f[0])) |v| if (v == .bool) {
            @field(c, f[1]) = v.bool;
        };
        const strs = [_]struct { []const u8, []const u8 }{
            .{ "messageAlign", "message_align" },
            .{ "noteAlign", "note_align" },
            .{ "actorFontFamily", "actor_font_family" },
            .{ "noteFontFamily", "note_font_family" },
            .{ "messageFontFamily", "message_font_family" },
        };
        inline for (strs) |f| if (o.get(f[0])) |v| if (v == .string) {
            @field(c, f[1]) = try a.dupe(u8, v.string);
        };
        const weights = [_]struct { []const u8, []const u8 }{
            .{ "actorFontWeight", "actor_font_weight" },
            .{ "noteFontWeight", "note_font_weight" },
            .{ "messageFontWeight", "message_font_weight" },
        };
        inline for (weights) |f| if (o.get(f[0])) |v| if (try jsonText(a, v)) |t| {
            @field(c, f[1]) = t;
        };
    }
};

fn jsonNum(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn jsonText(a: Allocator, v: std.json.Value) Allocator.Error!?[]const u8 {
    return switch (v) {
        .string => |s| try a.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try numfmt.js(a, f),
        else => null,
    };
}

pub fn weightNumber(w: []const u8) u16 {
    if (std.fmt.parseInt(u16, w, 10)) |n| return n else |_| {}
    if (std.mem.eql(u8, w, "bold")) return 700;
    return 400;
}

/// Chrome drops a font-family declaration that does not parse; a trailing ';' (the default config value) does that.
pub fn familyValid(f: []const u8) bool {
    return std.mem.indexOfScalar(u8, f, ';') == null;
}

/// Chrome serialises a font-family list with multi-word names quoted.
pub fn normFamily(a: Allocator, f: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, f, ',');
    var first = true;
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (!first) try out.appendSlice(a, ", ");
        first = false;
        const quoted = p.len > 0 and (p[0] == '"' or p[0] == 39);
        if (!quoted and std.mem.indexOfScalar(u8, p, ' ') != null) {
            try out.append(a, '"');
            try out.appendSlice(a, p);
            try out.append(a, '"');
        } else try out.appendSlice(a, p);
    }
    return out.items;
}
