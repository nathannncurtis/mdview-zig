const std = @import("std");
const Allocator = std.mem.Allocator;
const frontmatter = @import("../frontmatter.zig");
const env = @import("env.zig");
const sanitize = @import("sanitize.zig");

pub const LT = struct {
    pub const SOLID: u8 = 0;
    pub const DOTTED: u8 = 1;
    pub const NOTE: u8 = 2;
    pub const SOLID_CROSS: u8 = 3;
    pub const DOTTED_CROSS: u8 = 4;
    pub const SOLID_OPEN: u8 = 5;
    pub const DOTTED_OPEN: u8 = 6;
    pub const LOOP_START: u8 = 10;
    pub const LOOP_END: u8 = 11;
    pub const ALT_START: u8 = 12;
    pub const ALT_ELSE: u8 = 13;
    pub const ALT_END: u8 = 14;
    pub const OPT_START: u8 = 15;
    pub const OPT_END: u8 = 16;
    pub const ACTIVE_START: u8 = 17;
    pub const ACTIVE_END: u8 = 18;
    pub const PAR_START: u8 = 19;
    pub const PAR_AND: u8 = 20;
    pub const PAR_END: u8 = 21;
    pub const RECT_START: u8 = 22;
    pub const RECT_END: u8 = 23;
    pub const SOLID_POINT: u8 = 24;
    pub const DOTTED_POINT: u8 = 25;
    pub const AUTONUMBER: u8 = 26;
    pub const CRITICAL_START: u8 = 27;
    pub const CRITICAL_OPTION: u8 = 28;
    pub const CRITICAL_END: u8 = 29;
    pub const BREAK_START: u8 = 30;
    pub const BREAK_END: u8 = 31;
    pub const PAR_OVER_START: u8 = 32;
    pub const BIDIRECTIONAL_SOLID: u8 = 33;
    pub const BIDIRECTIONAL_DOTTED: u8 = 34;
    pub const SOLID_TOP: u8 = 41;
    pub const SOLID_BOTTOM: u8 = 42;
    pub const STICK_TOP: u8 = 43;
    pub const STICK_BOTTOM: u8 = 44;
    pub const SOLID_ARROW_TOP_REVERSE: u8 = 45;
    pub const SOLID_ARROW_BOTTOM_REVERSE: u8 = 46;
    pub const STICK_ARROW_TOP_REVERSE: u8 = 47;
    pub const STICK_ARROW_BOTTOM_REVERSE: u8 = 48;
    pub const SOLID_TOP_DOTTED: u8 = 51;
    pub const SOLID_BOTTOM_DOTTED: u8 = 52;
    pub const STICK_TOP_DOTTED: u8 = 53;
    pub const STICK_BOTTOM_DOTTED: u8 = 54;
    pub const SOLID_ARROW_TOP_REVERSE_DOTTED: u8 = 55;
    pub const SOLID_ARROW_BOTTOM_REVERSE_DOTTED: u8 = 56;
    pub const STICK_ARROW_TOP_REVERSE_DOTTED: u8 = 57;
    pub const STICK_ARROW_BOTTOM_REVERSE_DOTTED: u8 = 58;
    pub const CENTRAL_CONNECTION: u8 = 59;
    pub const CENTRAL_CONNECTION_REVERSE: u8 = 60;
    pub const CENTRAL_CONNECTION_DUAL: u8 = 61;
};

pub const PLACEMENT = struct {
    pub const LEFTOF: u8 = 0;
    pub const RIGHTOF: u8 = 1;
    pub const OVER: u8 = 2;
};

pub const Msg = struct { text: []const u8, wrap: ?bool = null };

pub const Kind = enum {
    sequence_index,
    add_participant,
    create_participant,
    destroy_participant,
    active_start,
    central_connection,
    central_connection_reverse,
    active_end,
    add_note,
    add_links,
    add_a_link,
    add_properties,
    add_details,
    add_message,
    box_start,
    box_end,
    loop_start,
    loop_end,
    rect_start,
    rect_end,
    opt_start,
    opt_end,
    alt_start,
    alt_else,
    alt_end,
    par_start,
    par_and,
    par_end,
    critical_start,
    critical_option,
    critical_end,
    break_start,
    break_end,
};

pub const BoxData = struct { text: ?[]const u8, color: []const u8, wrap: ?bool };

pub const Param = struct {
    kind: Kind,
    actor: ?[]const u8 = null,
    pair: ?[2][]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    msg: ?Msg = null,
    signal_type: u8 = 0,
    activate: bool = false,
    central: u8 = 0,
    description: ?Msg = null,
    draw: ?[]const u8 = null,
    config: ?[]const u8 = null,
    placement: u8 = 0,
    box: ?BoxData = null,
    seq_start: ?f64 = null,
    seq_step: ?f64 = null,
    seq_visible: bool = false,
};

pub const Link = struct { label: []const u8, url: []const u8 };

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    fill: []const u8 = "#eaeaea",
    stroke: []const u8 = "#666",
    rx: f64 = 0,
    ry: f64 = 0,
    class: ?[]const u8 = null,
};

pub const Box = struct {
    name: []const u8,
    wrap: bool,
    fill: []const u8,
    actor_keys: std.ArrayList([]const u8) = .empty,
    margin: f64 = 0,
    text_max_height: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

pub const Actor = struct {
    box: ?*Box,
    name: []const u8,
    description: []const u8,
    wrap: bool,
    prev_actor: ?[]const u8,
    next_actor: ?[]const u8 = null,
    links: std.ArrayList(Link) = .empty,
    prop_class: ?[]const u8 = null,
    prop_icon: ?[]const u8 = null,
    actor_cnt: ?usize = null,
    rect_data: ?Rect = null,
    type: []const u8,
    x: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    margin: ?f64 = null,
    starty: f64 = 0,
    stopy: ?f64 = null,
    actor_text_height: f64 = 0,
};

pub const Message = struct {
    id: usize,
    from: ?[]const u8,
    to: ?[]const u8,
    message: []const u8,
    wrap: bool,
    type: ?u8 = null,
    activate: bool = false,
    placement: ?u8 = null,
    central: u8 = 0,
    seq_start: ?f64 = null,
    seq_step: ?f64 = null,
    seq_visible: bool = false,
    is_auto: bool = false,
};

pub const Error = error{ OutOfMemory, SequenceError };

pub const Db = struct {
    a: Allocator,
    conf: *const env.Conf,
    prev_actor: ?[]const u8 = null,
    actors: std.StringArrayHashMapUnmanaged(*Actor) = .empty,
    created: std.StringArrayHashMapUnmanaged(usize) = .empty,
    destroyed: std.StringArrayHashMapUnmanaged(usize) = .empty,
    boxes: std.ArrayList(*Box) = .empty,
    messages: std.ArrayList(Message) = .empty,
    sequence_numbers: bool = false,
    wrap_enabled: ?bool = null,
    current_box: ?*Box = null,
    last_created: ?[]const u8 = null,
    last_destroyed: ?[]const u8 = null,
    title: ?[]const u8 = null,
    acc_title: ?[]const u8 = null,
    acc_descr: ?[]const u8 = null,
    err: []const u8 = "",
    /// Page elements by id for `details`; a markdown diagram has none, so the statement does nothing there.
    elements: ?*const std.StringHashMapUnmanaged([]const u8) = null,

    pub fn fail(db: *Db, comptime fmt: []const u8, args: anytype) Error {
        db.err = std.fmt.allocPrint(db.a, fmt, args) catch return error.OutOfMemory;
        return error.SequenceError;
    }

    pub fn autoWrap(db: *const Db) bool {
        return db.wrap_enabled orelse db.conf.wrap;
    }

    pub fn addBox(db: *Db, data: BoxData) Error!void {
        const b = try db.a.create(Box);
        b.* = .{ .name = data.text orelse "", .wrap = data.wrap orelse db.autoWrap(), .fill = data.color };
        try db.boxes.append(db.a, b);
        db.current_box = b;
    }

    pub fn addActor(db: *Db, id: []const u8, name: []const u8, description_in: ?Msg, type_in: ?[]const u8, metadata: ?[]const u8) Error!void {
        var assigned_box = db.current_box;
        var description = description_in;
        var typ = type_in;
        var meta_type: ?[]const u8 = null;
        var meta_alias: ?[]const u8 = null;
        if (metadata) |m| {
            const src = if (std.mem.indexOfScalar(u8, m, '\n') == null)
                try std.fmt.allocPrint(db.a, "{{\n{s}\n}}", .{m})
            else
                try std.fmt.allocPrint(db.a, "{s}\n", .{m});
            switch (try frontmatter.load(db.a, src)) {
                .err => |msg| {
                    db.err = msg;
                    return error.SequenceError;
                },
                .ok => |v| if (v == .object) {
                    if (v.object.get("type")) |t| if (t == .string) {
                        meta_type = t.string;
                    };
                    if (v.object.get("alias")) |al| if (al == .string and al.string.len > 0) {
                        meta_alias = al.string;
                    };
                },
            }
        }
        if (meta_type) |t| typ = t;
        if (meta_alias) |al| {
            if (description == null or std.mem.eql(u8, description.?.text, name)) {
                description = .{ .text = al, .wrap = if (description) |d| d.wrap else null };
            }
        }

        if (db.actors.get(id)) |old| {
            if (db.current_box != null and old.box != null and db.current_box.? != old.box.?) {
                return db.fail("A same participant should only be defined in one Box: {s} can't be in '{s}' and in '{s}' at the same time.", .{ old.name, old.box.?.name, db.current_box.?.name });
            }
            assigned_box = old.box orelse db.current_box;
            old.box = assigned_box;
            if (std.mem.eql(u8, name, old.name) and description == null) return;
        }

        var desc_text: []const u8 = name;
        var desc_wrap: ?bool = null;
        if (description) |d| {
            desc_text = d.text;
            desc_wrap = d.wrap;
        } else {
            desc_text = name;
        }
        if (typ == null) {
            desc_text = name;
            desc_wrap = null;
        }

        const actor = try db.a.create(Actor);
        actor.* = .{
            .box = assigned_box,
            .name = name,
            .description = desc_text,
            .wrap = desc_wrap orelse db.autoWrap(),
            .prev_actor = db.prev_actor,
            .type = typ orelse "participant",
        };
        try db.actors.put(db.a, id, actor);
        if (db.prev_actor) |p| {
            if (db.actors.get(p)) |pa| pa.next_actor = id;
        }
        if (db.current_box) |b| try b.actor_keys.append(db.a, id);
        db.prev_actor = id;
    }

    fn activationCount(db: *const Db, part: []const u8) i32 {
        var count: i32 = 0;
        if (part.len == 0) return 0;
        for (db.messages.items) |m| {
            const from = m.from orelse continue;
            if (!std.mem.eql(u8, from, part)) continue;
            if (m.type == LT.ACTIVE_START) count += 1;
            if (m.type == LT.ACTIVE_END) count -= 1;
        }
        return count;
    }

    pub fn addSignal(db: *Db, from: ?[]const u8, to: ?[]const u8, message: ?Msg, message_type: u8, activate: bool, central: u8) Error!void {
        if (message_type == LT.ACTIVE_END) {
            if (db.activationCount(from orelse "") < 1) {
                return db.fail("Trying to inactivate an inactive participant ({s})", .{from orelse "undefined"});
            }
        }
        try db.messages.append(db.a, .{
            .id = db.messages.items.len,
            .from = from,
            .to = to,
            .message = if (message) |m| m.text else "",
            .wrap = if (message) |m| m.wrap orelse db.autoWrap() else db.autoWrap(),
            .type = message_type,
            .activate = activate,
            .central = central,
        });
    }

    pub fn hasAtLeastOneBox(db: *const Db) bool {
        return db.boxes.items.len > 0;
    }

    pub fn hasAtLeastOneBoxWithTitle(db: *const Db) bool {
        for (db.boxes.items) |b| if (b.name.len > 0) return true;
        return false;
    }

    fn addNote(db: *Db, p: Param, text: Msg) Error!void {
        const from, const to = if (p.pair) |pr| .{ pr[0], pr[1] } else .{ p.actor.?, p.actor.? };
        try db.messages.append(db.a, .{
            .id = db.messages.items.len,
            .from = from,
            .to = to,
            .message = text.text,
            .wrap = text.wrap orelse db.autoWrap(),
            .type = LT.NOTE,
            .placement = p.placement,
        });
    }

    fn getActor(db: *Db, id: []const u8) Error!*Actor {
        return db.actors.get(id) orelse db.fail("Cannot read properties of undefined", .{});
    }

    fn addLinks(db: *Db, id: []const u8, text: []const u8) Error!void {
        const actor = try db.getActor(id);
        const clean = try sanitize.sanitizeText(db.a, text);
        const t = try replaceAll(db.a, try replaceAll(db.a, clean, "&equals;", "="), "&amp;", "&");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, db.a, t, .{}) catch return;
        if (parsed != .object) return;
        var it = parsed.object.iterator();
        while (it.next()) |kv| {
            const url = switch (kv.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            try insertLink(db, actor, kv.key_ptr.*, url);
        }
    }

    fn insertLink(db: *Db, actor: *Actor, label: []const u8, url: []const u8) Error!void {
        for (actor.links.items) |*l| if (std.mem.eql(u8, l.label, label)) {
            l.url = url;
            return;
        };
        try actor.links.append(db.a, .{ .label = label, .url = url });
    }

    fn addALink(db: *Db, id: []const u8, text: []const u8) Error!void {
        const actor = try db.getActor(id);
        const clean = try sanitize.sanitizeText(db.a, text);
        const sep = std.mem.indexOfScalar(u8, clean, '@') orelse return;
        const t = try replaceAll(db.a, try replaceAll(db.a, clean, "&equals;", "="), "&amp;", "&");
        const label = jsTrim(t[0..@min(t.len, if (sep >= 1) sep - 1 else 0)]);
        const link = jsTrim(t[@min(t.len, sep + 1)..]);
        try db.insertLink(actor, label, link);
    }

    fn addProperties(db: *Db, id: []const u8, text: []const u8) Error!void {
        const actor = try db.getActor(id);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, db.a, text, .{}) catch return;
        if (parsed != .object) return;
        if (parsed.object.get("class")) |c| if (c == .string) {
            actor.prop_class = c.string;
        };
        if (parsed.object.get("icon")) |c| if (c == .string) {
            actor.prop_icon = c.string;
        };
    }

    fn addDetails(db: *Db, id: []const u8, element_id: []const u8) Error!void {
        const actor = try db.getActor(id);
        const html = (db.elements orelse return).get(element_id) orelse return;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, db.a, html, .{}) catch return;
        if (parsed != .object) return;
        if (parsed.object.get("properties")) |props| if (props == .object) {
            if (props.object.get("class")) |c| if (c == .string) {
                actor.prop_class = c.string;
            };
            if (props.object.get("icon")) |c| if (c == .string) {
                actor.prop_icon = c.string;
            };
        };
        if (parsed.object.get("links")) |links| if (links == .object) {
            var it = links.object.iterator();
            while (it.next()) |kv| if (kv.value_ptr.* == .string) try db.insertLink(actor, kv.key_ptr.*, kv.value_ptr.string);
        };
    }

    pub fn apply(db: *Db, p: Param) Error!void {
        switch (p.kind) {
            .sequence_index => try db.messages.append(db.a, .{
                .id = db.messages.items.len,
                .from = null,
                .to = null,
                .message = "",
                .wrap = false,
                .type = p.signal_type,
                .is_auto = true,
                .seq_start = p.seq_start,
                .seq_step = p.seq_step,
                .seq_visible = p.seq_visible,
            }),
            .add_participant => try db.addActor(p.actor.?, p.actor.?, p.description, p.draw, p.config),
            .create_participant => {
                if (db.actors.contains(p.actor.?)) {
                    return db.fail("It is not possible to have actors with the same id, even if one is destroyed before the next is created. Use 'AS' aliases to simulate the behavior", .{});
                }
                db.last_created = p.actor.?;
                try db.addActor(p.actor.?, p.actor.?, p.description, p.draw, p.config);
                try db.created.put(db.a, p.actor.?, db.messages.items.len);
            },
            .destroy_participant => {
                db.last_destroyed = p.actor.?;
                try db.destroyed.put(db.a, p.actor.?, db.messages.items.len);
            },
            .active_start, .central_connection, .central_connection_reverse, .active_end => try db.addSignal(p.actor, null, null, p.signal_type, false, 0),
            .add_note => try db.addNote(p, p.msg.?),
            .add_links => try db.addLinks(p.actor.?, p.msg.?.text),
            .add_a_link => try db.addALink(p.actor.?, p.msg.?.text),
            .add_properties => try db.addProperties(p.actor.?, p.msg.?.text),
            .add_details => try db.addDetails(p.actor.?, p.msg.?.text),
            .add_message => {
                if (db.last_created) |lc| {
                    if (!std.mem.eql(u8, p.to.?, lc)) {
                        return db.fail("The created participant {s} does not have an associated creating message after its declaration. Please check the sequence diagram.", .{db.actors.get(lc).?.name});
                    }
                    db.last_created = null;
                } else if (db.last_destroyed) |ld| {
                    if (!std.mem.eql(u8, p.to.?, ld) and !std.mem.eql(u8, p.from.?, ld)) {
                        return db.fail("The destroyed participant {s} does not have an associated destroying message after its declaration. Please check the sequence diagram.", .{ld});
                    }
                    db.last_destroyed = null;
                }
                try db.addSignal(p.from, p.to, p.msg, p.signal_type, p.activate, p.central);
            },
            .box_start => try db.addBox(p.box.?),
            .box_end => db.current_box = null,
            .loop_start, .rect_start, .opt_start, .alt_start, .alt_else, .par_start, .par_and, .critical_start, .critical_option, .break_start => try db.addSignal(null, null, p.msg, p.signal_type, false, 0),
            .loop_end, .rect_end, .opt_end, .alt_end, .par_end, .critical_end, .break_end => try db.addSignal(null, null, null, p.signal_type, false, 0),
        }
    }
};

pub fn replaceAll(a: Allocator, s: []const u8, needle: []const u8, with: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, needle) == null) return s;
    return std.mem.replaceOwned(u8, a, s, needle, with);
}

fn isJsSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

/// JS String.prototype.trim on UTF-8 text.
pub fn jsTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[start..][0..n]) catch break;
        if (!isJsSpace(cp)) break;
        start += n;
    }
    var end: usize = s.len;
    while (end > start) {
        var b = end - 1;
        while (b > start and (s[b] & 0xC0) == 0x80) b -= 1;
        const cp = std.unicode.utf8Decode(s[b..end]) catch break;
        if (!isJsSpace(cp)) break;
        end = b;
    }
    return s[start..end];
}

const Wrapped = struct { cleaned: []const u8, wrap: ?bool };

fn extractWrap(a: Allocator, text: []const u8) Allocator.Error!Wrapped {
    _ = a;
    const t = jsTrim(text);
    var rest = t;
    var wrap: ?bool = null;
    var s = t;
    if (s.len > 0 and s[0] == ':') s = s[1..];
    if (std.mem.startsWith(u8, s, "wrap:")) {
        wrap = true;
        rest = s["wrap:".len..];
    } else if (std.mem.startsWith(u8, s, "nowrap:")) {
        wrap = false;
        rest = s["nowrap:".len..];
    }
    return .{ .cleaned = jsTrim(rest), .wrap = wrap };
}

pub fn parseMessage(a: Allocator, str: []const u8) Allocator.Error!Msg {
    const w = try extractWrap(a, jsTrim(str));
    return .{ .text = w.cleaned, .wrap = w.wrap };
}

const named_colors = std.StaticStringMap(void).initComptime(.{
    .{"aliceblue"},   .{"antiquewhite"}, .{"aqua"},      .{"aquamarine"},       .{"azure"},          .{"beige"},         .{"bisque"},
    .{"black"},       .{"blanchedalmond"}, .{"blue"},    .{"blueviolet"},       .{"brown"},          .{"burlywood"},     .{"cadetblue"},
    .{"chartreuse"},  .{"chocolate"},    .{"coral"},     .{"cornflowerblue"},   .{"cornsilk"},       .{"crimson"},       .{"cyan"},
    .{"darkblue"},    .{"darkcyan"},     .{"darkgoldenrod"}, .{"darkgray"},     .{"darkgreen"},      .{"darkgrey"},      .{"darkkhaki"},
    .{"darkmagenta"}, .{"darkolivegreen"}, .{"darkorange"}, .{"darkorchid"},    .{"darkred"},        .{"darksalmon"},    .{"darkseagreen"},
    .{"darkslateblue"}, .{"darkslategray"}, .{"darkslategrey"}, .{"darkturquoise"}, .{"darkviolet"}, .{"deeppink"},      .{"deepskyblue"},
    .{"dimgray"},     .{"dimgrey"},      .{"dodgerblue"}, .{"firebrick"},       .{"floralwhite"},    .{"forestgreen"},   .{"fuchsia"},
    .{"gainsboro"},   .{"ghostwhite"},   .{"gold"},      .{"goldenrod"},        .{"gray"},           .{"green"},         .{"greenyellow"},
    .{"grey"},        .{"honeydew"},     .{"hotpink"},   .{"indianred"},        .{"indigo"},         .{"ivory"},         .{"khaki"},
    .{"lavender"},    .{"lavenderblush"}, .{"lawngreen"}, .{"lemonchiffon"},    .{"lightblue"},      .{"lightcoral"},    .{"lightcyan"},
    .{"lightgoldenrodyellow"}, .{"lightgray"}, .{"lightgreen"}, .{"lightgrey"}, .{"lightpink"},      .{"lightsalmon"},   .{"lightseagreen"},
    .{"lightskyblue"}, .{"lightslategray"}, .{"lightslategrey"}, .{"lightsteelblue"}, .{"lightyellow"}, .{"lime"},       .{"limegreen"},
    .{"linen"},       .{"magenta"},      .{"maroon"},    .{"mediumaquamarine"}, .{"mediumblue"},     .{"mediumorchid"},  .{"mediumpurple"},
    .{"mediumseagreen"}, .{"mediumslateblue"}, .{"mediumspringgreen"}, .{"mediumturquoise"}, .{"mediumvioletred"}, .{"midnightblue"}, .{"mintcream"},
    .{"mistyrose"},   .{"moccasin"},     .{"navajowhite"}, .{"navy"},           .{"oldlace"},        .{"olive"},         .{"olivedrab"},
    .{"orange"},      .{"orangered"},    .{"orchid"},    .{"palegoldenrod"},    .{"palegreen"},      .{"paleturquoise"}, .{"palevioletred"},
    .{"papayawhip"},  .{"peachpuff"},    .{"peru"},      .{"pink"},             .{"plum"},           .{"powderblue"},    .{"purple"},
    .{"rebeccapurple"}, .{"red"},        .{"rosybrown"}, .{"royalblue"},        .{"saddlebrown"},    .{"salmon"},        .{"sandybrown"},
    .{"seagreen"},    .{"seashell"},     .{"sienna"},    .{"silver"},           .{"skyblue"},        .{"slateblue"},     .{"slategray"},
    .{"slategrey"},   .{"snow"},         .{"springgreen"}, .{"steelblue"},      .{"tan"},            .{"teal"},          .{"thistle"},
    .{"tomato"},      .{"turquoise"},    .{"violet"},    .{"wheat"},            .{"white"},          .{"whitesmoke"},    .{"yellow"},
    .{"yellowgreen"}, .{"transparent"},  .{"currentcolor"},
});

fn colorSupported(a: Allocator, c: []const u8) Allocator.Error!bool {
    const lower = try std.ascii.allocLowerString(a, c);
    if (named_colors.has(lower)) return true;
    const fns = [_][]const u8{ "rgba", "rgb", "hsla", "hsl" };
    for (fns) |f| if (std.mem.startsWith(u8, lower, f)) {
        var rest = lower[f.len..];
        while (rest.len > 0 and rest[0] == 32) rest = rest[1..];
        if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return false;
        for (rest[1 .. rest.len - 1]) |ch| switch (ch) {
            '0'...'9', '.', ',', '%', '/', ' ', '-', '+', 'd', 'e', 'g', 'r', 'a', 't', 'u', 'n', 'o' => {},
            else => return false,
        };
        return true;
    };
    return false;
}

pub fn parseBoxData(a: Allocator, str: []const u8) Allocator.Error!BoxData {
    var color: []const u8 = "";
    var title: []const u8 = "";
    const fnpre = [_][]const u8{ "rgba", "rgb", "hsla", "hsl" };
    var matched_fn = false;
    for (fnpre) |f| if (!matched_fn and std.ascii.startsWithIgnoreCase(str, f)) {
        var i = f.len;
        while (i < str.len and std.ascii.isWhitespace(str[i])) i += 1;
        if (i < str.len and str[i] == '(') {
            if (std.mem.lastIndexOfScalar(u8, str[i..], ')')) |close| {
                const end = i + close + 1;
                color = str[0..end];
                title = str[end..];
                matched_fn = true;
            }
        }
    };
    if (!matched_fn) {
        var i: usize = 0;
        while (i < str.len and (std.ascii.isAlphanumeric(str[i]) or str[i] == '_')) i += 1;
        color = str[0..i];
        title = str[i..];
    }
    var color_out: []const u8 = if (color.len > 0) jsTrim(color) else "transparent";
    var title_out: ?[]const u8 = if (title.len > 0) jsTrim(title) else null;
    if (!try colorSupported(a, color_out)) {
        color_out = "transparent";
        title_out = jsTrim(str);
    }
    const w = try extractWrap(a, title_out orelse "");
    const has_title = title_out != null and w.cleaned.len > 0;
    return .{ .text = if (has_title) try sanitize.sanitizeText(a, w.cleaned) else null, .color = color_out, .wrap = w.wrap };
}
