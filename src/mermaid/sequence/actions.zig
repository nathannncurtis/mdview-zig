const std = @import("std");
const Allocator = std.mem.Allocator;
const rt = @import("../jison/runtime.zig");
const G = @import("seq_grammar");
const dbm = @import("db.zig");
const sanitizer = @import("sanitize.zig");
const Db = dbm.Db;
const Param = dbm.Param;
const Msg = dbm.Msg;
const LT = dbm.LT;

pub const Item = union(enum) { skip, param: *Param, list: *List };
pub const List = std.ArrayList(Item);

pub const Val = union(enum) {
    none,
    text: []const u16,
    item: Item,
    msg: Msg,
    sig: u8,
    str: []const u8,
};

fn isJsSpace16(c: u16) bool {
    return switch (c) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn trim16(s: []const u16) []const u16 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isJsSpace16(s[a])) a += 1;
    while (b > a and isJsSpace16(s[b - 1])) b -= 1;
    return s[a..b];
}

pub const Actions = struct {
    a: Allocator,
    db: *Db,

    pub const Value = Val;
    pub const undefined_value: Value = .none;

    pub fn textValue(self: *Actions, yytext: []const u16) rt.Error!Value {
        _ = self;
        return .{ .text = yytext };
    }

    fn utf8(self: *Actions, s: []const u16) rt.Error![]const u8 {
        return rt.toUtf8(self.a, s);
    }

    fn newParam(self: *Actions, p: Param) rt.Error!*Param {
        const x = try self.a.create(Param);
        x.* = p;
        return x;
    }

    fn newList(self: *Actions) rt.Error!*List {
        const l = try self.a.create(List);
        l.* = .empty;
        return l;
    }

    fn paramOf(v: Value) *Param {
        return v.item.param;
    }

    fn parseMessage(self: *Actions, v: Value) rt.Error!Msg {
        return dbm.parseMessage(self.a, try self.utf8(v.text));
    }

    fn setYytextTrim(self: *Actions, lx: anytype) rt.Error!void {
        _ = self;
        try lx.setYytext(trim16(lx.yytext));
    }

    pub fn lexAction(self: *Actions, lx: anytype, rule: u16) rt.Error!?u16 {
        switch (rule) {
            0 => return G.tok.NEWLINE,
            1, 2, 3, 4, 5 => return null,
            6 => return G.tok.NUM,
            7 => {
                try lx.begin(G.cond.CONFIG);
                return G.tok.CONFIG_START;
            },
            8 => return G.tok.CONFIG_CONTENT,
            9 => {
                lx.popState();
                try lx.begin(G.cond.ALIAS);
                return G.tok.CONFIG_END;
            },
            10 => {
                lx.popState();
                lx.popState();
                return G.tok.CONFIG_END;
            },
            11 => {
                try self.setYytextTrim(lx);
                return G.tok.ACTOR;
            },
            12 => {
                try self.setYytextTrim(lx);
                try lx.begin(G.cond.ALIAS);
                return G.tok.ACTOR;
            },
            13 => {
                try self.setYytextTrim(lx);
                lx.popState();
                return G.tok.ACTOR;
            },
            14 => {
                lx.popState();
                return G.tok.INVALID;
            },
            15 => {
                try self.setYytextTrim(lx);
                lx.popState();
                return G.tok.INVALID;
            },
            16 => {
                try lx.begin(G.cond.LINE);
                return G.tok.box;
            },
            17 => {
                try lx.begin(G.cond.ID);
                return G.tok.participant;
            },
            18 => {
                try lx.begin(G.cond.ID);
                return G.tok.participant_actor;
            },
            19 => return G.tok.create,
            20 => {
                try lx.begin(G.cond.ID);
                return G.tok.destroy;
            },
            21 => {
                lx.popState();
                lx.popState();
                try lx.begin(G.cond.LINE);
                return G.tok.AS;
            },
            22 => {
                lx.popState();
                lx.popState();
                return G.tok.NEWLINE;
            },
            23 => {
                try lx.begin(G.cond.LINE);
                return G.tok.loop;
            },
            24 => {
                try lx.begin(G.cond.LINE);
                return G.tok.rect;
            },
            25 => {
                try lx.begin(G.cond.LINE);
                return G.tok.opt;
            },
            26 => {
                try lx.begin(G.cond.LINE);
                return G.tok.alt;
            },
            27 => {
                try lx.begin(G.cond.LINE);
                return G.tok.@"else";
            },
            28 => {
                try lx.begin(G.cond.LINE);
                return G.tok.par;
            },
            29 => {
                try lx.begin(G.cond.LINE);
                return G.tok.par_over;
            },
            30 => {
                try lx.begin(G.cond.LINE);
                return G.tok.@"and";
            },
            31 => {
                try lx.begin(G.cond.LINE);
                return G.tok.critical;
            },
            32 => {
                try lx.begin(G.cond.LINE);
                return G.tok.option;
            },
            33 => {
                try lx.begin(G.cond.LINE);
                return G.tok.@"break";
            },
            34 => {
                lx.popState();
                return G.tok.restOfLine;
            },
            35 => return G.tok.end,
            36 => return G.tok.left_of,
            37 => return G.tok.right_of,
            38 => return G.tok.links,
            39 => return G.tok.link,
            40 => return G.tok.properties,
            41 => return G.tok.details,
            42 => return G.tok.over,
            43 => return G.tok.note,
            44 => {
                try lx.begin(G.cond.ID);
                return G.tok.activate;
            },
            45 => {
                try lx.begin(G.cond.ID);
                return G.tok.deactivate;
            },
            46 => return G.tok.title,
            47 => return G.tok.legacy_title,
            48 => {
                try lx.begin(G.cond.acc_title);
                return G.tok.acc_title;
            },
            49 => {
                lx.popState();
                return G.tok.acc_title_value;
            },
            50 => {
                try lx.begin(G.cond.acc_descr);
                return G.tok.acc_descr;
            },
            51 => {
                lx.popState();
                return G.tok.acc_descr_value;
            },
            52 => {
                try lx.begin(G.cond.acc_descr_multiline);
                return null;
            },
            53 => {
                lx.popState();
                return null;
            },
            54 => return G.tok.acc_descr_multiline_value,
            55 => return G.tok.SD,
            56 => return G.tok.autonumber,
            57 => return G.tok.off,
            58 => return G.tok.@",",
            59 => return G.tok.NEWLINE,
            60 => {
                try self.setYytextTrim(lx);
                return G.tok.ACTOR;
            },
            61 => return G.tok.SOLID_ARROW,
            62 => return G.tok.BIDIRECTIONAL_SOLID_ARROW,
            63 => return G.tok.DOTTED_ARROW,
            64 => return G.tok.BIDIRECTIONAL_DOTTED_ARROW,
            65 => return G.tok.SOLID_OPEN_ARROW,
            66 => return G.tok.DOTTED_OPEN_ARROW,
            67 => return G.tok.SOLID_CROSS,
            68 => return G.tok.DOTTED_CROSS,
            69 => return G.tok.SOLID_POINT,
            70 => return G.tok.DOTTED_POINT,
            71 => return G.tok.SOLID_ARROW_TOP_DOTTED,
            72 => return G.tok.SOLID_ARROW_BOTTOM_DOTTED,
            73 => return G.tok.STICK_ARROW_TOP_DOTTED,
            74 => return G.tok.STICK_ARROW_BOTTOM_DOTTED,
            75 => return G.tok.SOLID_ARROW_TOP_REVERSE_DOTTED,
            76 => return G.tok.SOLID_ARROW_BOTTOM_REVERSE_DOTTED,
            77 => return G.tok.STICK_ARROW_TOP_REVERSE_DOTTED,
            78 => return G.tok.STICK_ARROW_BOTTOM_REVERSE_DOTTED,
            79 => return G.tok.SOLID_ARROW_TOP,
            80 => return G.tok.SOLID_ARROW_BOTTOM,
            81 => return G.tok.STICK_ARROW_TOP,
            82 => return G.tok.STICK_ARROW_BOTTOM,
            83 => return G.tok.SOLID_ARROW_TOP_REVERSE,
            84 => return G.tok.SOLID_ARROW_BOTTOM_REVERSE,
            85 => return G.tok.STICK_ARROW_TOP_REVERSE,
            86 => return G.tok.STICK_ARROW_BOTTOM_REVERSE,
            87, 88 => return G.tok.TXT,
            89 => return G.tok.@"+",
            90 => return G.tok.@"-",
            91 => return G.tok.@"()",
            92 => return G.tok.NEWLINE,
            93 => return G.tok.INVALID,
            else => unreachable,
        }
    }

    fn push(self: *Actions, l: *List, it: Item) rt.Error!void {
        try l.append(self.a, it);
    }

    fn wrapList(self: *Actions, v: Value, start: Param, end: Param) rt.Error!Value {
        const src = v.item.list;
        const l = try self.newList();
        try self.push(l, .{ .param = try self.newParam(start) });
        try l.appendSlice(self.a, src.items);
        try self.push(l, .{ .param = try self.newParam(end) });
        return .{ .item = .{ .list = l } };
    }

    fn concat(self: *Actions, first: Value, mid: Param, tail: Value) rt.Error!Value {
        const l = try self.newList();
        try l.appendSlice(self.a, first.item.list.items);
        try self.push(l, .{ .param = try self.newParam(mid) });
        try self.push(l, tail.item);
        return .{ .item = .{ .list = l } };
    }

    fn actorOf(self: *Actions, v: Value) rt.Error![]const u8 {
        _ = self;
        return paramOf(v).actor.?;
    }

    fn list3(self: *Actions, items: []const Item) rt.Error!Value {
        const l = try self.newList();
        try l.appendSlice(self.a, items);
        return .{ .item = .{ .list = l } };
    }

    fn message(self: *Actions, from: []const u8, to: []const u8, sig: u8, msg: Msg, activate: bool, central: u8) rt.Error!Item {
        return .{ .param = try self.newParam(.{ .kind = .add_message, .from = from, .to = to, .signal_type = sig, .msg = msg, .activate = activate, .central = central }) };
    }

    fn signalParam(self: *Actions, kind: dbm.Kind, sig: u8, actor: []const u8) rt.Error!Item {
        return .{ .param = try self.newParam(.{ .kind = kind, .signal_type = sig, .actor = actor }) };
    }

    fn applyList(self: *Actions, ctx: anytype, l: *const List) rt.Error!void {
        for (l.items) |it| switch (it) {
            .skip => {},
            .param => |p| self.db.apply(p.*) catch |e| return self.fail(ctx, e),
            .list => |sub| try self.applyList(ctx, sub),
        };
    }

    fn fail(self: *Actions, ctx: anytype, e: dbm.Error) rt.Error {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        ctx.diag.setOwned(ctx.gpa, ctx.gpa.dupe(u8, self.db.err) catch return error.OutOfMemory);
        return error.Semantic;
    }

    pub fn reduce(self: *Actions, ctx: anytype, rhs: []const Value, out: *Value) rt.Error!bool {
        switch (ctx.prod) {
            0, 1, 2 => {},
            3 => {
                try self.applyList(ctx, rhs[1].item.list);
                out.* = rhs[1];
                return true;
            },
            4, 10 => out.* = .{ .item = .{ .list = try self.newList() } },
            5, 11 => {
                try self.push(rhs[0].item.list, rhs[1].item);
                out.* = rhs[0];
            },
            6, 12 => out.* = rhs[1],
            7, 13, 15, 18, 25, 26, 27, 28, 29, 43, 45, 47, 67 => out.* = rhs[0],
            8, 9, 14 => out.* = .{ .item = .{ .list = try self.newList() } },
            16 => {
                paramOf(rhs[1]).kind = .create_participant;
                out.* = rhs[1];
            },
            17 => {
                const bd = try dbm.parseBoxData(self.a, try self.utf8(rhs[1].text));
                out.* = try self.wrapList(rhs[2], .{ .kind = .box_start, .box = bd }, .{ .kind = .box_end });
            },
            19 => out.* = .{ .item = .{ .param = try self.newParam(.{ .kind = .sequence_index, .seq_start = try self.number(rhs[1]), .seq_step = try self.number(rhs[2]), .seq_visible = true, .signal_type = LT.AUTONUMBER }) } },
            20 => out.* = .{ .item = .{ .param = try self.newParam(.{ .kind = .sequence_index, .seq_start = try self.number(rhs[1]), .seq_step = 1, .seq_visible = true, .signal_type = LT.AUTONUMBER }) } },
            21 => out.* = .{ .item = .{ .param = try self.newParam(.{ .kind = .sequence_index, .seq_visible = false, .signal_type = LT.AUTONUMBER }) } },
            22 => out.* = .{ .item = .{ .param = try self.newParam(.{ .kind = .sequence_index, .seq_visible = true, .signal_type = LT.AUTONUMBER }) } },
            23 => out.* = .{ .item = try self.signalParam(.active_start, LT.ACTIVE_START, try self.actorOf(rhs[1])) },
            24 => out.* = .{ .item = try self.signalParam(.active_end, LT.ACTIVE_END, try self.actorOf(rhs[1])) },
            30 => {
                const t = try self.utf8(rhs[0].text);
                self.db.title = try self.sanitize(if (t.len > 6) t[6..] else "");
                out.* = .{ .item = .skip };
            },
            31 => {
                const t = try self.utf8(rhs[0].text);
                self.db.title = try self.sanitize(if (t.len > 7) t[7..] else "");
                out.* = .{ .item = .skip };
            },
            32 => {
                self.db.acc_title = dbm.jsTrim(try self.utf8(rhs[1].text));
                out.* = .{ .item = .skip };
            },
            33 => {
                self.db.acc_descr = dbm.jsTrim(try self.utf8(rhs[1].text));
                out.* = .{ .item = .skip };
            },
            34 => {
                self.db.acc_descr = dbm.jsTrim(try self.utf8(rhs[0].text));
                out.* = .{ .item = .skip };
            },
            35 => out.* = try self.wrapList(rhs[2], .{ .kind = .loop_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.LOOP_START }, .{ .kind = .loop_end, .signal_type = LT.LOOP_END }),
            36 => {
                const m = try self.parseMessage(rhs[1]);
                out.* = try self.wrapList(rhs[2], .{ .kind = .rect_start, .msg = m, .signal_type = LT.RECT_START }, .{ .kind = .rect_end, .signal_type = LT.RECT_END });
            },
            37 => out.* = try self.wrapList(rhs[2], .{ .kind = .opt_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.OPT_START }, .{ .kind = .opt_end, .signal_type = LT.OPT_END }),
            38 => out.* = try self.wrapList(rhs[2], .{ .kind = .alt_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.ALT_START }, .{ .kind = .alt_end, .signal_type = LT.ALT_END }),
            39 => out.* = try self.wrapList(rhs[2], .{ .kind = .par_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.PAR_START }, .{ .kind = .par_end, .signal_type = LT.PAR_END }),
            40 => out.* = try self.wrapList(rhs[2], .{ .kind = .par_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.PAR_OVER_START }, .{ .kind = .par_end, .signal_type = LT.PAR_END }),
            41 => out.* = try self.wrapList(rhs[2], .{ .kind = .critical_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.CRITICAL_START }, .{ .kind = .critical_end, .signal_type = LT.CRITICAL_END }),
            42 => out.* = try self.wrapList(rhs[2], .{ .kind = .break_start, .msg = try self.parseMessage(rhs[1]), .signal_type = LT.BREAK_START }, .{ .kind = .break_end, .signal_type = LT.BREAK_END }),
            44 => out.* = try self.concat(rhs[0], .{ .kind = .critical_option, .msg = try self.parseMessage(rhs[2]), .signal_type = LT.CRITICAL_OPTION }, rhs[3]),
            46 => out.* = try self.concat(rhs[0], .{ .kind = .par_and, .msg = try self.parseMessage(rhs[2]), .signal_type = LT.PAR_AND }, rhs[3]),
            48 => out.* = try self.concat(rhs[0], .{ .kind = .alt_else, .msg = try self.parseMessage(rhs[2]), .signal_type = LT.ALT_ELSE }, rhs[3]),
            49 => try self.participant(rhs[1], "participant", try self.parseMessage(rhs[3]), out),
            50 => try self.participant(rhs[1], "participant", null, out),
            51 => try self.participant(rhs[1], "actor", try self.parseMessage(rhs[3]), out),
            52 => try self.participant(rhs[1], "actor", null, out),
            53 => {
                paramOf(rhs[1]).kind = .destroy_participant;
                out.* = rhs[1];
            },
            54 => try self.participant(rhs[1], "participant", try self.parseMessage(rhs[3]), out),
            55 => try self.participant(rhs[1], "participant", null, out),
            56 => try self.participant(rhs[1], "actor", try self.parseMessage(rhs[3]), out),
            57 => try self.participant(rhs[1], "actor", null, out),
            58 => {
                const note: Param = .{ .kind = .add_note, .placement = rhs[1].sig, .actor = try self.actorOf(rhs[2]), .msg = rhs[3].msg };
                out.* = try self.list3(&.{ rhs[2].item, .{ .param = try self.newParam(note) } });
            },
            59 => {
                const pair: [2][]const u8 = switch (rhs[2].item) {
                    .param => |p| .{ p.actor.?, p.actor.? },
                    .list => |l| .{ l.items[0].param.actor.?, l.items[1].param.actor.? },
                    .skip => unreachable,
                };
                const note: Param = .{ .kind = .add_note, .placement = dbm.PLACEMENT.OVER, .pair = pair, .msg = rhs[3].msg };
                out.* = try self.list3(&.{ rhs[2].item, .{ .param = try self.newParam(note) } });
            },
            60 => out.* = try self.actorText(rhs, .add_links),
            61 => out.* = try self.actorText(rhs, .add_a_link),
            62 => out.* = try self.actorText(rhs, .add_properties),
            63 => out.* = try self.actorText(rhs, .add_details),
            64, 65 => {},
            66 => out.* = try self.list3(&.{ rhs[0].item, rhs[2].item }),
            68 => out.* = .{ .sig = dbm.PLACEMENT.LEFTOF },
            69 => out.* = .{ .sig = dbm.PLACEMENT.RIGHTOF },
            70 => {
                const from = try self.actorOf(rhs[0]);
                const to = try self.actorOf(rhs[3]);
                out.* = try self.list3(&.{
                    rhs[0].item,
                    rhs[3].item,
                    try self.message(from, to, rhs[1].sig, rhs[4].msg, true, 0),
                    try self.signalParam(.active_start, LT.ACTIVE_START, to),
                });
            },
            71 => {
                const from = try self.actorOf(rhs[0]);
                const to = try self.actorOf(rhs[3]);
                out.* = try self.list3(&.{
                    rhs[0].item,
                    rhs[3].item,
                    try self.message(from, to, rhs[1].sig, rhs[4].msg, false, 0),
                    try self.signalParam(.active_end, LT.ACTIVE_END, from),
                });
            },
            72 => {
                const from = try self.actorOf(rhs[0]);
                const to = try self.actorOf(rhs[3]);
                out.* = try self.list3(&.{
                    rhs[0].item,
                    rhs[3].item,
                    try self.message(from, to, rhs[1].sig, rhs[4].msg, true, LT.CENTRAL_CONNECTION),
                    try self.signalParam(.central_connection, LT.CENTRAL_CONNECTION, to),
                });
            },
            73 => {
                const from = try self.actorOf(rhs[0]);
                const to = try self.actorOf(rhs[3]);
                out.* = try self.list3(&.{
                    rhs[0].item,
                    rhs[3].item,
                    try self.message(from, to, rhs[2].sig, rhs[4].msg, false, LT.CENTRAL_CONNECTION_REVERSE),
                    try self.signalParam(.central_connection_reverse, LT.CENTRAL_CONNECTION_REVERSE, from),
                });
            },
            74 => {
                const from = try self.actorOf(rhs[0]);
                const to = try self.actorOf(rhs[4]);
                out.* = try self.list3(&.{
                    rhs[0].item,
                    rhs[4].item,
                    try self.message(from, to, rhs[2].sig, rhs[5].msg, true, LT.CENTRAL_CONNECTION_DUAL),
                    try self.signalParam(.central_connection, LT.CENTRAL_CONNECTION, to),
                    try self.signalParam(.central_connection_reverse, LT.CENTRAL_CONNECTION_REVERSE, from),
                });
            },
            75 => {
                const from = try self.actorOf(rhs[0]);
                const to = try self.actorOf(rhs[2]);
                out.* = try self.list3(&.{
                    rhs[0].item,
                    rhs[2].item,
                    try self.message(from, to, rhs[1].sig, rhs[3].msg, false, 0),
                });
            },
            76 => out.* = .{ .item = .{ .param = try self.newParam(.{ .kind = .add_participant, .actor = try self.utf8(rhs[0].text), .config = rhs[1].str }) } },
            77 => out.* = .{ .str = dbm.jsTrim(try self.utf8(rhs[1].text)) },
            78, 79 => out.* = .{ .item = .{ .param = try self.newParam(.{ .kind = .add_participant, .actor = try self.utf8(rhs[0].text) }) } },
            80...105 => out.* = .{ .sig = sigTypes[ctx.prod - 80] },
            106 => {
                const t = dbm.jsTrim(try self.utf8(rhs[0].text));
                out.* = .{ .msg = try dbm.parseMessage(self.a, if (t.len > 0) t[1..] else t) };
            },
            else => unreachable,
        }
        return false;
    }

    const sigTypes = [_]u8{
        LT.SOLID_OPEN,                          LT.DOTTED_OPEN,                       LT.SOLID,                           LT.SOLID_TOP,
        LT.SOLID_BOTTOM,                        LT.STICK_TOP,                         LT.STICK_BOTTOM,                    LT.SOLID_TOP_DOTTED,
        LT.SOLID_BOTTOM_DOTTED,                 LT.STICK_TOP_DOTTED,                  LT.STICK_BOTTOM_DOTTED,             LT.SOLID_ARROW_TOP_REVERSE,
        LT.SOLID_ARROW_BOTTOM_REVERSE,          LT.STICK_ARROW_TOP_REVERSE,           LT.STICK_ARROW_BOTTOM_REVERSE,      LT.SOLID_ARROW_TOP_REVERSE_DOTTED,
        LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED,   LT.STICK_ARROW_TOP_REVERSE_DOTTED,    LT.STICK_ARROW_BOTTOM_REVERSE_DOTTED, LT.BIDIRECTIONAL_SOLID,
        LT.DOTTED,                              LT.BIDIRECTIONAL_DOTTED,              LT.SOLID_CROSS,                     LT.DOTTED_CROSS,
        LT.SOLID_POINT,                         LT.DOTTED_POINT,
    };

    fn participant(self: *Actions, actor: Value, draw: []const u8, description: ?Msg, out: *Value) rt.Error!void {
        _ = self;
        const p = paramOf(actor);
        p.kind = .add_participant;
        p.draw = draw;
        if (description) |d| p.description = d;
        out.* = actor;
    }

    fn actorText(self: *Actions, rhs: []const Value, kind: dbm.Kind) rt.Error!Value {
        const p = try self.newParam(.{ .kind = kind, .actor = try self.actorOf(rhs[1]), .msg = rhs[2].msg });
        return self.list3(&.{ rhs[1].item, .{ .param = p } });
    }

    fn number(self: *Actions, v: Value) rt.Error!f64 {
        const s = try self.utf8(v.text);
        return std.fmt.parseFloat(f64, s) catch 0;
    }

    fn sanitize(self: *Actions, s: []const u8) rt.Error![]const u8 {
        return sanitizer.sanitizeText(self.a, s);
    }
};

test "production numbers match the grammar" {
    const expect = [_]struct { u16, u16, []const u8 }{
        .{ 3, 2, "start" },       .{ 17, 4, "statement" },  .{ 35, 4, "statement" }, .{ 44, 4, "option_sections" }, .{ 49, 5, "participant_statement" },
        .{ 58, 4, "note_statement" }, .{ 59, 4, "note_statement" }, .{ 70, 5, "signal" }, .{ 74, 6, "signal" }, .{ 75, 4, "signal" },
        .{ 76, 2, "actor_with_config" }, .{ 77, 3, "config_object" }, .{ 78, 1, "actor" }, .{ 79, 1, "actor" }, .{ 80, 1, "signaltype" },
        .{ 105, 1, "signaltype" }, .{ 106, 1, "text2" }, .{ 19, 4, "statement" }, .{ 53, 3, "participant_statement" },
    };
    for (expect) |e| {
        try std.testing.expectEqual(e[1], G.productions[e[0]].len);
        try std.testing.expectEqualStrings(e[2], G.symbol_names[G.productions[e[0]].lhs]);
    }
}
