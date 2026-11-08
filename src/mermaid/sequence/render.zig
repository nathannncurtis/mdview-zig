const std = @import("std");
const Allocator = std.mem.Allocator;
const env = @import("env.zig");
const dbm = @import("db.zig");
const dom = @import("dom.zig");
const icons = @import("icons.zig");
const sanitize = @import("sanitize.zig");
const numfmt = env.numfmt;
const LT = dbm.LT;
const Node = dom.Node;
const Db = dbm.Db;
const Actor = dbm.Actor;
const Conf = env.Conf;

const ACTOR_TYPE_WIDTH: f64 = 36;
const ZWSP = "\u{200b}";
const MAX_SAFE: f64 = 9007199254740991;
const nan = std.math.nan(f64);

const Font = struct { family: []const u8, size: f64, weight: []const u8 };

const NoteModel = struct { width: f64 = 0, height: f64 = 0, startx: f64 = 0, stopx: f64 = 0, starty: f64 = 0, stopy: f64 = 0, message: []const u8 = "" };

const MsgModel = struct {
    valid: bool = false,
    width: f64 = 0,
    height: f64 = 0,
    startx: f64 = 0,
    stopx: f64 = 0,
    starty: f64 = 0,
    stopy: f64 = 0,
    message: []const u8 = "",
    type_: u8 = 0,
    wrap: bool = false,
    from_bounds: f64 = 0,
    to_bounds: f64 = 0,
    sequence_index: f64 = 1,
    sequence_visible: bool = false,
};

const Section = struct { y: f64, title: []const u8 };

const LoopModel = struct {
    startx: ?f64 = null,
    starty: f64 = 0,
    stopx: ?f64 = null,
    stopy: ?f64 = null,
    title: []const u8 = "",
    wrap: bool = false,
    height: f64 = 0,
    fill: ?[]const u8 = null,
    sections: std.ArrayList(Section) = .empty,
};

const Activation = struct { startx: f64, starty: f64, stopx: f64, stopy: ?f64 = null, actor: []const u8, anchored: ?*Node = null };

const LoopWidth = struct { from: f64, to: f64, width: f64 };

const TextObj = struct {
    x: f64 = 0,
    y: f64 = 0,
    text: []const u8 = "",
    fill: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    width: ?f64 = null,
    text_margin: f64 = 0,
    tspan: bool = true,
    valign: ?[]const u8 = null,
    class: ?[]const u8 = null,
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,
    font_weight: ?[]const u8 = null,
    dy: ?[]const u8 = null,
    dominant_baseline: ?[]const u8 = null,
    alignment_baseline: ?[]const u8 = null,
};

pub const Output = struct { svg: []const u8, width: f64, height: f64, view_box: [4]f64 };

fn px(a: Allocator, v: f64) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}px", .{try numfmt.js(a, v)});
}

fn jr(x: f64) f64 {
    return numfmt.round(x);
}

fn splitBreaks(a: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<' and i + 3 <= text.len and std.ascii.eqlIgnoreCase(text[i + 1 .. i + 3], "br")) {
            var j = i + 3;
            while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
            if (j < text.len and text[j] == '/') j += 1;
            if (j < text.len and text[j] == '>') {
                try out.append(a, text[start..i]);
                start = j + 1;
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    try out.append(a, text[start..]);
    return out.items;
}

fn findBreak(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (text[i] == '<' and i + 3 <= text.len and std.ascii.eqlIgnoreCase(text[i + 1 .. i + 3], "br")) {
            var j = i + 3;
            while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
            if (j < text.len and text[j] == '/') j += 1;
            if (j < text.len and text[j] == '>') return j + 1;
        }
    }
    return null;
}

pub const Renderer = struct {
    a: Allocator,
    d: dom.Dom,
    conf: Conf,
    db: *Db,
    m: env.Measurer,
    theme: env.Theme,
    id: []const u8,
    root: *Node,

    data_startx: ?f64 = null,
    data_stopx: ?f64 = null,
    data_starty: ?f64 = null,
    data_stopy: ?f64 = null,
    vpos: f64 = 0,
    items: std.ArrayList(*LoopModel) = .empty,
    activations: std.ArrayList(*Activation) = .empty,
    boxes: std.ArrayList(*dbm.Box) = .empty,
    msg_models: std.ArrayList(MsgModel) = .empty,
    note_models: std.ArrayList(NoteModel) = .empty,
    model_idx: []?usize = &.{},
    actor_cnt: i64 = -1,
    br_last_index: usize = 0,
    life_lines: std.AutoHashMapUnmanaged(usize, *Node) = .empty,
    cur_line_y: f64 = 0,
    deadline: ?*env.Deadline = null,
    out_w: f64 = 0,
    out_h: f64 = 0,
    vb: [4]f64 = .{ 0, 0, 0, 0 },

    fn tick(r: *Renderer) error{Timeout}!void {
        if (r.deadline) |d| try d.check();
    }

    fn messageFont(r: *const Renderer) Font {
        return .{ .family = r.conf.message_font_family, .size = r.conf.message_font_size, .weight = r.conf.message_font_weight };
    }
    fn noteFont(r: *const Renderer) Font {
        return .{ .family = r.conf.note_font_family, .size = r.conf.note_font_size, .weight = r.conf.note_font_weight };
    }
    fn actorFont(r: *const Renderer) Font {
        return .{ .family = r.conf.actor_font_family, .size = r.conf.actor_font_size, .weight = r.conf.actor_font_weight };
    }

    fn measureLine(r: *const Renderer, text: []const u8, family: []const u8, f: Font) env.Dim {
        const sz = r.m.measure(text, .{ .family = family, .size = @floatCast(f.size), .weight = env.weightNumber(f.weight) });
        return .{ .w = sz.w, .h = sz.h };
    }

    const Dims = struct { w: f64 = 0, h: f64 = 0, lh: f64 = 0 };

    fn textDims(r: *Renderer, text: []const u8, f: Font) !Dims {
        if (text.len == 0) return .{};
        const lines = try splitBreaks(r.a, text);
        const fams = [2][]const u8{ "sans-serif", f.family };
        var dims: [2]Dims = .{ .{}, .{} };
        for (fams, 0..) |fam, k| {
            for (lines) |line| {
                const t = if (line.len == 0) ZWSP else line;
                const dm = r.measureLine(t, fam, f);
                dims[k].w = jr(@max(dims[k].w, dm.w));
                const ch = jr(dm.h);
                dims[k].h += ch;
                dims[k].lh = jr(@max(dims[k].lh, ch));
            }
        }
        const pick: usize = if (dims[0].h > dims[1].h and dims[0].w > dims[1].w and dims[0].lh > dims[1].lh) 0 else 1;
        return dims[pick];
    }

    fn textWidth(r: *Renderer, text: []const u8, f: Font) !f64 {
        return (try r.textDims(text, f)).w;
    }

    fn breakTest(r: *Renderer, label: []const u8) bool {
        if (r.br_last_index > label.len) {
            r.br_last_index = 0;
            return false;
        }
        if (findBreak(label, r.br_last_index)) |end| {
            r.br_last_index = end;
            return true;
        }
        r.br_last_index = 0;
        return false;
    }

    fn breakString(r: *Renderer, word: []const u8, max_width: f64, f: Font, hyph: *std.ArrayList([]const u8)) ![]const u8 {
        var cur: std.ArrayList(u8) = .empty;
        var view = std.unicode.Utf8View.initUnchecked(word);
        var it = view.iterator();
        const total = std.unicode.utf8CountCodepoints(word) catch word.len;
        var index: usize = 0;
        while (it.nextCodepointSlice()) |cp| : (index += 1) {
            try r.tick();
            const next = try std.mem.concat(r.a, u8, &.{ cur.items, cp });
            const w = try r.textWidth(next, f);
            if (w >= max_width) {
                const last = total == index + 1;
                try hyph.append(r.a, if (last) next else try std.mem.concat(r.a, u8, &.{ next, "-" }));
                cur = .empty;
            } else {
                cur = .empty;
                try cur.appendSlice(r.a, next);
            }
        }
        return cur.items;
    }

    fn wrapLabel(r: *Renderer, label: []const u8, max_width: f64, f: Font) ![]const u8 {
        if (label.len == 0) return label;
        if (r.breakTest(label)) return label;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, label, ' ');
        while (it.next()) |w| if (w.len > 0) try words.append(r.a, w);
        var done: std.ArrayList([]const u8) = .empty;
        var next_line: []const u8 = "";
        for (words.items, 0..) |word, index| {
            try r.tick();
            const word_len = try r.textWidth(try std.mem.concat(r.a, u8, &.{ word, " " }), f);
            const next_len = try r.textWidth(next_line, f);
            if (word_len > max_width) {
                var hyph: std.ArrayList([]const u8) = .empty;
                const rem = try r.breakString(word, max_width, f, &hyph);
                try done.append(r.a, next_line);
                try done.appendSlice(r.a, hyph.items);
                next_line = rem;
            } else if (next_len + word_len >= max_width) {
                try done.append(r.a, next_line);
                next_line = word;
            } else {
                next_line = if (next_line.len == 0) word else try std.mem.concat(r.a, u8, &.{ next_line, " ", word });
            }
            if (index + 1 == words.items.len) try done.append(r.a, next_line);
        }
        var out: std.ArrayList(u8) = .empty;
        var first = true;
        for (done.items) |l| {
            if (l.len == 0) continue;
            if (!first) try out.appendSlice(r.a, "<br/>");
            first = false;
            try out.appendSlice(r.a, l);
        }
        return out.items;
    }

    // ---- bounds ----

    fn updateVal(cur: *?f64, val: f64, comptime is_min: bool) void {
        if (cur.*) |c| cur.* = if (is_min) @min(val, c) else @max(val, c) else cur.* = val;
    }

    fn bumpVerticalPos(r: *Renderer, bump: f64) void {
        r.vpos += bump;
        r.data_stopy = if (r.data_stopy) |s| @max(s, r.vpos) else r.vpos;
    }

    fn updateBounds(r: *Renderer, startx: f64, starty: f64, stopx: f64, stopy: f64) void {
        var cnt: f64 = 0;
        const bm = r.conf.box_margin;
        const len: f64 = @floatFromInt(r.items.items.len);
        for (r.items.items) |item| {
            cnt += 1;
            const n = len - cnt + 1;
            item.starty = @min(item.starty, starty - n * bm);
            item.stopy = if (item.stopy) |s| @max(s, stopy + n * bm) else stopy + n * bm;
            updateVal(&r.data_startx, startx - n * bm, true);
            updateVal(&r.data_stopx, stopx + n * bm, false);
            updateVal(&item.startx, startx - n * bm, true);
            updateVal(&item.stopx, stopx + n * bm, false);
            updateVal(&r.data_starty, starty - n * bm, true);
            updateVal(&r.data_stopy, stopy + n * bm, false);
        }
        for (r.activations.items) |act| {
            cnt += 1;
            const n = len - cnt + 1;
            act.starty = @min(starty - n * bm, act.starty);
            act.stopy = if (act.stopy) |s| @max(s, stopy + n * bm) else stopy + n * bm;
            updateVal(&r.data_startx, startx - n * bm, true);
            updateVal(&r.data_stopx, stopx + n * bm, false);
        }
    }

    fn insert(r: *Renderer, startx: f64, starty: f64, stopx: f64, stopy: f64) void {
        const sx = @min(startx, stopx);
        const ex = @max(startx, stopx);
        const sy = @min(starty, stopy);
        const ey = @max(starty, stopy);
        updateVal(&r.data_startx, sx, true);
        updateVal(&r.data_starty, sy, true);
        updateVal(&r.data_stopx, ex, false);
        updateVal(&r.data_stopy, ey, false);
        r.updateBounds(sx, sy, ex, ey);
    }

    fn actorActivationCount(r: *const Renderer, actor: []const u8) usize {
        var n: usize = 0;
        for (r.activations.items) |x| if (std.mem.eql(u8, x.actor, actor)) {
            n += 1;
        };
        return n;
    }

    fn newActivation(r: *Renderer, from: []const u8) !void {
        const ar = r.db.actors.get(from) orelse return error.BadModel;
        const stacked: f64 = @floatFromInt(r.actorActivationCount(from));
        const x = ar.x + ar.width / 2 + ((stacked - 1) * r.conf.activation_width) / 2;
        const act = try r.a.create(Activation);
        act.* = .{ .startx = x, .starty = r.vpos + 2, .stopx = x + r.conf.activation_width, .actor = from, .anchored = try r.d.append(r.root, "g") };
        try r.activations.append(r.a, act);
    }

    fn endActivation(r: *Renderer, from: []const u8) !*Activation {
        if (r.activations.items.len == 0) return error.BadModel;
        var idx: ?usize = null;
        for (r.activations.items, 0..) |x, i| if (std.mem.eql(u8, x.actor, from)) {
            idx = i;
        };
        return r.activations.orderedRemove(idx orelse r.activations.items.len - 1);
    }

    fn activationBounds(r: *const Renderer, actor: []const u8) [2]f64 {
        const ao = r.db.actors.get(actor).?;
        var left = ao.x + ao.width / 2 - 1;
        var right = ao.x + ao.width / 2 + 1;
        for (r.activations.items) |x| if (std.mem.eql(u8, x.actor, actor)) {
            left = @min(left, x.startx);
            right = @max(right, x.stopx);
        };
        return .{ left, right };
    }

    fn newLoop(r: *Renderer, title: []const u8, wrap: bool, fill: ?[]const u8) !void {
        const l = try r.a.create(LoopModel);
        l.* = .{ .starty = r.vpos, .title = title, .wrap = wrap, .fill = fill };
        try r.items.append(r.a, l);
    }

    // ---- svg helpers ----

    fn drawRect(r: *Renderer, parent: *Node, rect: dbm.Rect, name: ?[]const u8) !*Node {
        const n = try r.d.append(parent, "rect");
        try r.d.attrNum(n, "x", rect.x);
        try r.d.attrNum(n, "y", rect.y);
        try r.d.attr(n, "fill", rect.fill);
        try r.d.attr(n, "stroke", rect.stroke);
        try r.d.attrNum(n, "width", rect.width);
        try r.d.attrNum(n, "height", rect.height);
        if (name) |nm| if (nm.len > 0) try r.d.attr(n, "name", nm);
        if (rect.rx != 0) try r.d.attrNum(n, "rx", rect.rx);
        if (rect.ry != 0) try r.d.attrNum(n, "ry", rect.ry);
        if (rect.class) |c| try r.d.attr(n, "class", c);
        return n;
    }

    fn textBBoxHeight(r: *const Renderer, line: []const u8, t: TextObj) f64 {
        const fam = if (t.font_family) |f| (if (env.familyValid(f)) f else r.theme.str("fontFamily")) else r.theme.str("fontFamily");
        const size = t.font_size orelse 16;
        const w = if (t.font_weight) |x| env.weightNumber(x) else 400;
        const sz = r.m.measure(line, .{ .family = fam, .size = @floatCast(size), .weight = w });
        return sz.h;
    }

    fn drawText(r: *Renderer, parent: *Node, t_in: *TextObj) ![]*Node {
        var prev_h: f64 = 0;
        var text_h: f64 = 0;
        const lines = try splitBreaks(r.a, t_in.text);
        var elems: std.ArrayList(*Node) = .empty;
        const t = t_in;
        if (t.anchor) |an| if (t.width) |w| {
            var known = true;
            if (std.mem.eql(u8, an, "left") or std.mem.eql(u8, an, "start")) {
                t.x = jr(t.x + t.text_margin);
                t.anchor = "start";
            } else if (std.mem.eql(u8, an, "middle") or std.mem.eql(u8, an, "center")) {
                t.x = jr(t.x + w / 2);
                t.anchor = "middle";
            } else if (std.mem.eql(u8, an, "right") or std.mem.eql(u8, an, "end")) {
                t.x = jr(t.x + w - t.text_margin);
                t.anchor = "end";
            } else known = false;
            if (known) {
                t.dominant_baseline = "middle";
                t.alignment_baseline = "middle";
            }
        };
        for (lines, 0..) |line, i| {
            try r.tick();
            var dy: f64 = 0;
            if (t.text_margin == 0) dy = @as(f64, @floatFromInt(i)) * (t.font_size orelse 0);
            var y = t.y;
            if (t.valign) |va| if (t.text_margin > 0) {
                if (std.mem.eql(u8, va, "top") or std.mem.eql(u8, va, "start")) {
                    y = jr(t.y + t.text_margin);
                } else if (std.mem.eql(u8, va, "middle") or std.mem.eql(u8, va, "center")) {
                    y = jr(t.y + (prev_h + text_h + t.text_margin) / 2);
                } else if (std.mem.eql(u8, va, "bottom") or std.mem.eql(u8, va, "end")) {
                    y = jr(t.y + (prev_h + text_h + 2 * t.text_margin) - t.text_margin);
                }
            };
            const te = try r.d.append(parent, "text");
            try r.d.attrNum(te, "x", t.x);
            try r.d.attrNum(te, "y", y);
            if (t.anchor) |an| {
                try r.d.attr(te, "text-anchor", an);
                if (t.dominant_baseline) |v| try r.d.attr(te, "dominant-baseline", v);
                if (t.alignment_baseline) |v| try r.d.attr(te, "alignment-baseline", v);
            }
            if (t.font_family) |f| try r.d.style(te, "font-family", f);
            if (t.font_size) |s| try r.d.style(te, "font-size", try px(r.a, s));
            if (t.font_weight) |w| try r.d.style(te, "font-weight", w);
            if (t.fill) |f| try r.d.attr(te, "fill", f);
            if (t.class) |c| try r.d.attr(te, "class", c);
            if (t.dy) |v| {
                try r.d.attr(te, "dy", v);
            } else if (dy != 0) try r.d.attrNum(te, "dy", dy);
            const txt = if (line.len == 0) ZWSP else line;
            if (t.tspan) {
                const sp = try r.d.append(te, "tspan");
                try r.d.attrNum(sp, "x", t.x);
                if (t.fill) |f| try r.d.attr(sp, "fill", f);
                r.d.text(sp, txt);
            } else r.d.text(te, txt);
            if (t.valign != null and t.text_margin > 0) {
                text_h += r.textBBoxHeight(txt, t.*);
                prev_h = text_h;
            }
            try elems.append(r.a, te);
        }
        return elems.items;
    }

    fn sumBBox(r: *const Renderer, elems: []*Node, t: TextObj) f64 {
        var sum: f64 = 0;
        for (elems) |e| {
            const txt = e.text orelse if (e.children.items.len > 0) (e.children.items[0].text orelse "") else "";
            sum += r.textBBoxHeight(txt, t);
        }
        return sum;
    }

    /// byTspan text used for actors and box titles.
    fn byTspan(r: *Renderer, g: *Node, content: []const u8, x: f64, y: f64, width: f64, height: f64, class: []const u8) !void {
        const lines = try splitBreaks(r.a, content);
        const fs = r.conf.actor_font_size;
        const n: f64 = @floatFromInt(lines.len);
        for (lines, 0..) |line, i| {
            const dy = @as(f64, @floatFromInt(i)) * fs - (fs * (n - 1)) / 2;
            const t = try r.d.append(g, "text");
            try r.d.attrNum(t, "x", x + width / 2);
            try r.d.attrNum(t, "y", y);
            try r.d.style(t, "text-anchor", "middle");
            try r.d.style(t, "font-size", try px(r.a, fs));
            try r.d.style(t, "font-weight", r.conf.actor_font_weight);
            try r.d.style(t, "font-family", r.conf.actor_font_family);
            const sp = try r.d.append(t, "tspan");
            try r.d.attrNum(sp, "x", x + width / 2);
            try r.d.attrNum(sp, "dy", dy);
            r.d.text(sp, line);
            try r.d.attrNum(t, "y", y + height / 2.0);
            try r.d.attr(t, "dominant-baseline", "central");
            try r.d.attr(t, "alignment-baseline", "central");
            try r.d.attr(t, "class", class);
        }
    }

    // ---- notes and messages ----

    fn drawNote(r: *Renderer, nm: *NoteModel, id: usize) !void {
        r.bumpVerticalPos(r.conf.box_margin);
        nm.height = r.conf.box_margin;
        nm.starty = r.vpos;
        var rect: dbm.Rect = .{ .fill = "#EDF2AE", .width = 100, .height = 100, .x = nm.startx, .y = nm.starty };
        rect.width = if (nm.width != 0) nm.width else r.conf.width;
        rect.class = "note";
        const g = try r.d.append(r.root, "g");
        try r.d.attr(g, "data-et", "note");
        try r.d.attr(g, "data-id", try std.fmt.allocPrint(r.a, "i{d}", .{id}));
        const re = try r.drawRectLook(g, rect, null);
        var t: TextObj = .{
            .x = nm.startx,
            .y = nm.starty,
            .width = rect.width,
            .dy = "1em",
            .text = nm.message,
            .class = "noteText",
            .font_family = r.conf.note_font_family,
            .font_size = r.conf.note_font_size,
            .font_weight = r.conf.note_font_weight,
            .anchor = r.conf.note_align,
            .text_margin = r.conf.note_margin,
            .valign = "center",
        };
        const elems = try r.drawText(g, &t);
        const th = jr(r.sumBBox(elems, t));
        try r.d.attrNum(re, "height", th + 2 * r.conf.note_margin);
        nm.height += th + 2 * r.conf.note_margin;
        r.bumpVerticalPos(th + 2 * r.conf.note_margin);
        nm.stopy = nm.starty + th + 2 * r.conf.note_margin;
        nm.stopx = nm.startx + rect.width;
        r.insert(nm.startx, nm.starty, nm.stopx, nm.stopy);
    }

    fn boundMessage(r: *Renderer, mm: *MsgModel) !f64 {
        r.bumpVerticalPos(10);
        const lines: f64 = @floatFromInt((try splitBreaks(r.a, mm.message)).len);
        const td = try r.textDims(mm.message, r.messageFont());
        const line_height = td.h / lines;
        mm.height += line_height;
        r.bumpVerticalPos(line_height);
        var line_start_y: f64 = 0;
        var total_offset = td.h - 10;
        const text_width = td.w;
        if (mm.startx == mm.stopx) {
            line_start_y = r.vpos + total_offset;
            if (!r.conf.right_angles) {
                total_offset += r.conf.box_margin;
                line_start_y = r.vpos + total_offset;
            }
            total_offset += 30;
            const dx = @max(text_width / 2, r.conf.width / 2);
            r.insert(mm.startx - dx, r.vpos - 10 + total_offset, mm.stopx + dx, r.vpos + 30 + total_offset);
        } else {
            total_offset += r.conf.box_margin;
            line_start_y = r.vpos + total_offset;
            r.insert(mm.startx, line_start_y - 10, mm.stopx, line_start_y);
        }
        r.bumpVerticalPos(total_offset);
        mm.height += total_offset;
        mm.stopy = mm.starty + mm.height;
        r.insert(mm.from_bounds, mm.starty, mm.to_bounds, mm.stopy);
        return line_start_y;
    }

    fn isReverse(t: u8) bool {
        return switch (t) {
            LT.SOLID_ARROW_TOP_REVERSE, LT.SOLID_ARROW_TOP_REVERSE_DOTTED, LT.SOLID_ARROW_BOTTOM_REVERSE, LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED, LT.STICK_ARROW_TOP_REVERSE, LT.STICK_ARROW_TOP_REVERSE_DOTTED, LT.STICK_ARROW_BOTTOM_REVERSE, LT.STICK_ARROW_BOTTOM_REVERSE_DOTTED => true,
            else => false,
        };
    }

    fn isBidi(t: u8) bool {
        return t == LT.BIDIRECTIONAL_SOLID or t == LT.BIDIRECTIONAL_DOTTED;
    }

    fn isDotted(t: u8) bool {
        return switch (t) {
            LT.DOTTED, LT.DOTTED_CROSS, LT.DOTTED_POINT, LT.DOTTED_OPEN, LT.BIDIRECTIONAL_DOTTED, LT.SOLID_TOP_DOTTED, LT.SOLID_BOTTOM_DOTTED, LT.STICK_TOP_DOTTED, LT.STICK_BOTTOM_DOTTED, LT.SOLID_ARROW_TOP_REVERSE_DOTTED, LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED, LT.STICK_ARROW_TOP_REVERSE_DOTTED, LT.STICK_ARROW_BOTTOM_REVERSE_DOTTED => true,
            else => false,
        };
    }

    fn isArrowType(t: u8) bool {
        return switch (t) {
            LT.SOLID_OPEN, LT.DOTTED_OPEN, LT.SOLID, LT.SOLID_TOP, LT.SOLID_BOTTOM, LT.STICK_TOP, LT.STICK_BOTTOM, LT.SOLID_TOP_DOTTED, LT.SOLID_BOTTOM_DOTTED, LT.STICK_TOP_DOTTED, LT.STICK_BOTTOM_DOTTED, LT.SOLID_ARROW_TOP_REVERSE, LT.SOLID_ARROW_BOTTOM_REVERSE, LT.STICK_ARROW_TOP_REVERSE, LT.STICK_ARROW_BOTTOM_REVERSE, LT.SOLID_ARROW_TOP_REVERSE_DOTTED, LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED, LT.STICK_ARROW_TOP_REVERSE_DOTTED, LT.STICK_ARROW_BOTTOM_REVERSE_DOTTED, LT.DOTTED, LT.SOLID_CROSS, LT.DOTTED_CROSS, LT.SOLID_POINT, LT.DOTTED_POINT, LT.BIDIRECTIONAL_SOLID, LT.BIDIRECTIONAL_DOTTED => true,
            else => false,
        };
    }

    fn hasCentral(c: u8) bool {
        return c == LT.CENTRAL_CONNECTION or c == LT.CENTRAL_CONNECTION_REVERSE or c == LT.CENTRAL_CONNECTION_DUAL;
    }

    fn drawCentral(r: *Renderer, msg: *const dbm.Message, mm: *const MsgModel) !void {
        const from = r.db.actors.get(msg.from.?).?;
        const to = r.db.actors.get(msg.to.?).?;
        var from_c = from.x + from.width / 2;
        var to_c = to.x + to.width / 2;
        const ltr = from_c <= to_c;
        const rev = isReverse(msg.type.?);
        const g = try r.d.append(r.root, "g");
        const off: f64 = 16.5;
        const circleOffset = struct {
            fn f(l: bool, rv: bool) f64 {
                const base: f64 = if (l) off else -off;
                return if (rv) -base else base;
            }
        }.f;
        if (mm.sequence_visible) {
            switch (msg.central) {
                LT.CENTRAL_CONNECTION => if (rev) {
                    to_c += circleOffset(ltr, true);
                },
                LT.CENTRAL_CONNECTION_REVERSE => if (!rev) {
                    from_c += circleOffset(ltr, false);
                },
                LT.CENTRAL_CONNECTION_DUAL => if (rev) {
                    to_c += circleOffset(ltr, true);
                } else {
                    from_c += circleOffset(ltr, false);
                },
                else => {},
            }
        }
        const line_y = r.cur_line_y;
        switch (msg.central) {
            LT.CENTRAL_CONNECTION => try r.circle(g, to_c, line_y),
            LT.CENTRAL_CONNECTION_REVERSE => try r.circle(g, from_c, line_y),
            LT.CENTRAL_CONNECTION_DUAL => {
                try r.circle(g, from_c, line_y);
                try r.circle(g, to_c, line_y);
            },
            else => {},
        }
    }

    fn circle(r: *Renderer, g: *Node, cx: f64, cy: f64) !void {
        const c = try r.d.append(g, "circle");
        try r.d.attrNum(c, "cx", cx);
        try r.d.attrNum(c, "cy", cy);
        try r.d.attr(c, "r", "5");
        try r.d.attr(c, "width", "10");
        try r.d.attr(c, "height", "10");
    }

    fn marker(r: *Renderer, comptime which: []const u8) ![]const u8 {
        return std.fmt.allocPrint(r.a, "url(#{s}-" ++ which ++ ")", .{r.id});
    }

    fn drawMessage(r: *Renderer, mm: *MsgModel, line_start_y: f64, msg: *const dbm.Message) !void {
        const startx = mm.startx;
        const stopx = mm.stopx;
        const type_ = mm.type_;
        const td = try r.textDims(mm.message, r.messageFont());
        var t: TextObj = .{
            .x = @min(startx, stopx),
            .y = mm.starty + 10,
            .width = @abs(stopx - startx),
            .class = "messageText",
            .dy = "1em",
            .text = mm.message,
            .font_family = r.conf.message_font_family,
            .font_size = r.conf.message_font_size,
            .font_weight = r.conf.message_font_weight,
            .anchor = r.conf.message_align,
            .valign = "center",
            .text_margin = r.conf.wrap_padding,
            .tspan = false,
        };
        _ = try r.drawText(r.root, &t);
        const text_width = td.w;
        r.cur_line_y = line_start_y;
        // SAFETY: assigned in both branches of the if below
        var line: *Node = undefined;
        const auto_on = mm.sequence_visible or r.conf.show_sequence_numbers;
        if (startx == stopx) {
            const rev = isReverse(msg.type.?);
            const bidi = isBidi(msg.type.?);
            const lsx = startx + (if (auto_on and (rev or bidi)) @as(f64, 10) else 0);
            line = try r.d.append(r.root, "path");
            if (r.conf.right_angles) {
                try r.d.attr(line, "d", try std.fmt.allocPrint(r.a, "M  {s},{s} H {s} V {s} H {s}", .{ try numfmt.js(r.a, lsx), try numfmt.js(r.a, line_start_y), try numfmt.js(r.a, startx + @max(r.conf.width / 2, text_width / 2)), try numfmt.js(r.a, line_start_y + 25), try numfmt.js(r.a, startx) }));
            } else {
                try r.d.attr(line, "d", try std.fmt.allocPrint(r.a, "M {s},{s} C {s},{s} {s},{s} {s},{s}", .{
                    try numfmt.js(r.a, lsx),
                    try numfmt.js(r.a, line_start_y),
                    try numfmt.js(r.a, lsx + 60),
                    try numfmt.js(r.a, line_start_y - 10),
                    try numfmt.js(r.a, startx + 60),
                    try numfmt.js(r.a, line_start_y + 30),
                    try numfmt.js(r.a, startx),
                    try numfmt.js(r.a, line_start_y + 20),
                }));
            }
            if (hasCentral(msg.central)) try r.drawCentral(msg, mm);
        } else {
            line = try r.d.append(r.root, "line");
            try r.d.attrNum(line, "x1", startx);
            try r.d.attrNum(line, "y1", line_start_y);
            try r.d.attrNum(line, "x2", stopx);
            try r.d.attrNum(line, "y2", line_start_y);
            if (hasCentral(msg.central)) try r.drawCentral(msg, mm);
        }
        if (isDotted(type_)) {
            try r.d.style(line, "stroke-dasharray", "3, 3");
            try r.d.attr(line, "class", "messageLine1");
        } else try r.d.attr(line, "class", "messageLine0");
        try r.d.attr(line, "data-et", "message");
        try r.d.attr(line, "data-id", try std.fmt.allocPrint(r.a, "i{d}", .{msg.id}));
        try r.d.attr(line, "data-from", msg.from.?);
        try r.d.attr(line, "data-to", msg.to.?);
        try r.d.attr(line, "stroke-width", "2");
        try r.d.attr(line, "stroke", "none");
        try r.d.style(line, "fill", "none");
        const sol_top = try r.marker("solidTopArrowHead");
        const sol_bot = try r.marker("solidBottomArrowHead");
        const stk_top = try r.marker("stickTopArrowHead");
        const stk_bot = try r.marker("stickBottomArrowHead");
        switch (type_) {
            LT.SOLID_TOP, LT.SOLID_TOP_DOTTED => try r.d.attr(line, "marker-end", sol_top),
            LT.SOLID_BOTTOM, LT.SOLID_BOTTOM_DOTTED => try r.d.attr(line, "marker-end", sol_bot),
            LT.STICK_TOP, LT.STICK_TOP_DOTTED => try r.d.attr(line, "marker-end", stk_top),
            LT.STICK_BOTTOM, LT.STICK_BOTTOM_DOTTED => try r.d.attr(line, "marker-end", stk_bot),
            LT.SOLID_ARROW_TOP_REVERSE, LT.SOLID_ARROW_TOP_REVERSE_DOTTED => try r.d.attr(line, "marker-start", sol_bot),
            LT.SOLID_ARROW_BOTTOM_REVERSE, LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED => try r.d.attr(line, "marker-start", sol_top),
            LT.STICK_ARROW_TOP_REVERSE, LT.STICK_ARROW_TOP_REVERSE_DOTTED => try r.d.attr(line, "marker-start", stk_bot),
            LT.STICK_ARROW_BOTTOM_REVERSE, LT.STICK_ARROW_BOTTOM_REVERSE_DOTTED => try r.d.attr(line, "marker-start", stk_top),
            LT.SOLID, LT.DOTTED => try r.d.attr(line, "marker-end", try r.marker("arrowhead")),
            LT.BIDIRECTIONAL_SOLID, LT.BIDIRECTIONAL_DOTTED => {
                try r.d.attr(line, "marker-start", try r.marker("arrowhead"));
                try r.d.attr(line, "marker-end", try r.marker("arrowhead"));
            },
            LT.SOLID_POINT, LT.DOTTED_POINT => try r.d.attr(line, "marker-end", try r.marker("filled-head")),
            LT.SOLID_CROSS, LT.DOTTED_CROSS => try r.d.attr(line, "marker-end", try r.marker("crosshead")),
            else => {},
        }
        if (auto_on) {
            const bidi = isBidi(type_);
            const rev = isReverse(type_);
            const radius: f64 = 6;
            const has_c = hasCentral(msg.central);
            const dual_or_rev = msg.central == LT.CENTRAL_CONNECTION_DUAL or msg.central == LT.CENTRAL_CONNECTION_REVERSE;
            var lsx = startx;
            var lstx = stopx;
            if (bidi) {
                if (startx < stopx) {
                    lsx = startx + radius * 2;
                } else {
                    lsx = startx - radius + (if (has_c) @as(f64, -5) else 0);
                    lsx += if (dual_or_rev) @as(f64, -7.5) else 0;
                }
                try r.d.attrNum(line, "x1", lsx);
            } else if (rev) {
                if (stopx > startx) {
                    lstx = stopx - 2 * radius;
                } else {
                    lstx = stopx - radius;
                    lsx += if (dual_or_rev) @as(f64, -7.5) else 0;
                }
                lstx += if (has_c) @as(f64, 15) else 0;
                try r.d.attrNum(line, "x2", lstx);
                try r.d.attrNum(line, "x1", lsx);
            } else {
                try r.d.attrNum(line, "x1", startx + radius);
            }
            var autox: f64 = 0;
            const ltr = startx <= stopx;
            if (startx == stopx) {
                autox = mm.from_bounds + 1;
            } else if (rev) {
                autox = if (ltr) mm.to_bounds - 1 else mm.from_bounds + 1;
            } else {
                autox = if (ltr) mm.from_bounds + 1 else mm.to_bounds - 1;
            }
            const idx_len = (try numfmt.js(r.a, mm.sequence_index)).len;
            const fsz: []const u8 = if (idx_len > 5) "7px" else if (idx_len > 3) "9px" else "12px";
            const l2 = try r.d.append(r.root, "line");
            try r.d.attrNum(l2, "x1", autox);
            try r.d.attrNum(l2, "y1", line_start_y);
            try r.d.attrNum(l2, "x2", autox);
            try r.d.attrNum(l2, "y2", line_start_y);
            try r.d.attr(l2, "stroke-width", "0");
            try r.d.attr(l2, "marker-start", try r.marker("sequencenumber"));
            const tx = try r.d.append(r.root, "text");
            try r.d.attrNum(tx, "x", autox);
            try r.d.attrNum(tx, "y", line_start_y + 4);
            try r.d.attr(tx, "font-family", "sans-serif");
            try r.d.attr(tx, "font-size", fsz);
            try r.d.attr(tx, "text-anchor", "middle");
            try r.d.attr(tx, "class", "sequenceNumber");
            r.d.text(tx, try numfmt.js(r.a, mm.sequence_index));
        }
    }

    // ---- actors ----

    fn calculateActorMargins(r: *Renderer, widths: *std.StringArrayHashMapUnmanaged(f64)) !f64 {
        var max_h: f64 = 0;
        var it = r.db.actors.iterator();
        while (it.next()) |kv| {
            const actor = kv.value_ptr.*;
            if (actor.wrap) actor.description = try r.wrapLabel(actor.description, r.conf.width - 2 * r.conf.wrap_padding, r.actorFont());
            const dims = try r.textDims(actor.description, r.actorFont());
            actor.width = if (actor.wrap) r.conf.width else @max(r.conf.width, dims.w + 2 * r.conf.wrap_padding);
            if (r.neo()) {
                actor.actor_text_height = dims.h;
                actor.height = @max(GLYPH_BAND + GLYPH_LABEL_GAP + dims.h + LABEL_LIFELINE_GAP, r.conf.height);
            } else {
                actor.height = if (actor.wrap) @max(dims.h, r.conf.height) else r.conf.height;
            }
            max_h = @max(max_h, actor.height);
        }
        var wit = widths.iterator();
        while (wit.next()) |kv| {
            const actor = r.db.actors.get(kv.key_ptr.*) orelse continue;
            const mw = kv.value_ptr.*;
            if (actor.next_actor) |na| if (r.db.actors.get(na)) |next| {
                const aw = mw + r.conf.actor_margin - actor.width / 2 - next.width / 2;
                actor.margin = @max(aw, r.conf.actor_margin);
                continue;
            };
            const aw = mw + r.conf.actor_margin - actor.width / 2;
            actor.margin = @max(aw, r.conf.actor_margin);
        }
        var max_box_h: f64 = 0;
        for (r.db.boxes.items) |box| {
            var total: f64 = 0;
            for (box.actor_keys.items) |k| {
                const ac = r.db.actors.get(k).?;
                total += ac.width + (ac.margin orelse 0);
            }
            total += r.conf.box_margin * 8;
            total -= 2 * r.conf.box_text_margin;
            if (box.wrap) box.name = try r.wrapLabel(box.name, total - 2 * r.conf.wrap_padding, r.messageFont());
            const bd = try r.textDims(box.name, r.messageFont());
            max_box_h = @max(bd.h, max_box_h);
            const min_w = @max(total, bd.w + 2 * r.conf.wrap_padding);
            box.margin = r.conf.box_text_margin;
            if (total < min_w) box.margin += (min_w - total) / 2;
        }
        for (r.db.boxes.items) |b| b.text_max_height = max_box_h;
        return @max(max_h, r.conf.height);
    }

    fn getMaxMessageWidthPerActor(r: *Renderer) !std.StringArrayHashMapUnmanaged(f64) {
        var out: std.StringArrayHashMapUnmanaged(f64) = .empty;
        for (r.db.messages.items) |msg| {
            try r.tick();
            const to = msg.to orelse continue;
            const from = msg.from orelse continue;
            const actor = r.db.actors.get(to) orelse continue;
            if (r.db.actors.get(from) == null) continue;
            if (msg.placement == dbm.PLACEMENT.LEFTOF and actor.prev_actor == null) continue;
            if (msg.placement == dbm.PLACEMENT.RIGHTOF and actor.next_actor == null) continue;
            const is_note = msg.placement != null;
            const is_message = !is_note;
            const font = if (is_note) r.noteFont() else r.messageFont();
            const wrapped = if (msg.wrap) try r.wrapLabel(msg.message, r.conf.width - 2 * r.conf.wrap_padding, font) else msg.message;
            const dims = try r.textDims(wrapped, font);
            const mw = dims.w + 2 * r.conf.wrap_padding;
            const next = actor.next_actor;
            const prev = actor.prev_actor;
            if (is_message and next != null and std.mem.eql(u8, from, next.?)) {
                try maxPut(r, &out, to, mw);
            } else if (is_message and prev != null and std.mem.eql(u8, from, prev.?)) {
                try maxPut(r, &out, from, mw);
            } else if (is_message and std.mem.eql(u8, from, to)) {
                try maxPut(r, &out, from, mw / 2);
                try maxPut(r, &out, to, mw / 2);
            } else if (msg.placement == dbm.PLACEMENT.RIGHTOF) {
                try maxPut(r, &out, from, mw);
            } else if (msg.placement == dbm.PLACEMENT.LEFTOF) {
                try maxPut(r, &out, prev.?, mw);
            } else if (msg.placement == dbm.PLACEMENT.OVER) {
                if (prev) |p| try maxPut(r, &out, p, mw / 2);
                if (next != null) try maxPut(r, &out, from, mw / 2);
            }
        }
        return out;
    }

    fn maxPut(r: *Renderer, m: *std.StringArrayHashMapUnmanaged(f64), k: []const u8, v: f64) !void {
        const g = try m.getOrPut(r.a, k);
        g.value_ptr.* = if (g.found_existing) @max(g.value_ptr.*, v) else @max(0, v);
    }

    fn addActorRenderingData(r: *Renderer, keys: []const []const u8, vpos: f64) !void {
        var prev_width: f64 = 0;
        var prev_margin: f64 = 0;
        var prev_box: ?*dbm.Box = null;
        var max_height: f64 = 0;
        for (keys) |k| {
            const actor = r.db.actors.get(k).?;
            const box = actor.box;
            if (prev_box != null and prev_box != box) {
                try r.boxes.append(r.a, prev_box.?);
                prev_margin += r.conf.box_margin + prev_box.?.margin;
            }
            if (box != null and box != prev_box) {
                box.?.x = prev_width + prev_margin;
                box.?.y = vpos;
                prev_margin += box.?.margin;
            }
            actor.width = @max(if (actor.width != 0) actor.width else r.conf.width, r.conf.width);
            actor.height = @max(if (actor.height != 0) actor.height else r.conf.height, r.conf.height);
            actor.margin = if (actor.margin) |m| (if (m != 0) m else r.conf.actor_margin) else r.conf.actor_margin;
            max_height = @max(max_height, actor.height);
            if (r.db.created.get(actor.name)) |ci| if (ci != 0) {
                prev_margin += actor.width / 2;
            };
            actor.x = prev_width + prev_margin;
            actor.starty = r.vpos;
            r.insert(actor.x, vpos, actor.x + actor.width, actor.height);
            prev_width += actor.width + prev_margin;
            if (actor.box) |b| b.width = prev_width + box.?.margin - b.x;
            prev_margin = actor.margin.?;
            prev_box = actor.box;
        }
        if (prev_box) |pb| try r.boxes.append(r.a, pb);
        r.bumpVerticalPos(max_height);
    }

    fn neo(r: *const Renderer) bool {
        return r.conf.look == .neo;
    }

    fn shadowUrl(r: *Renderer) ![]const u8 {
        return std.fmt.allocPrint(r.a, "url(#{s}-drop-shadow)", .{r.id});
    }

    const GLYPH_BAND: f64 = 44;
    const GLYPH_LABEL_GAP: f64 = 6;
    const LABEL_LIFELINE_GAP: f64 = 6;

    const Bands = struct { lifeline_y: f64, glyph_bottom_y: f64, label_center_y: f64 };

    /// The neo look's vertical band model (actorBands.ts); null for classic.
    fn bands(r: *const Renderer, actor: *const Actor, is_footer: bool, actor_y: f64) ?Bands {
        if (!r.neo()) return null;
        const th = actor.actor_text_height;
        if (is_footer) {
            const gb = actor_y + LABEL_LIFELINE_GAP + GLYPH_BAND;
            return .{ .lifeline_y = actor_y, .glyph_bottom_y = gb, .label_center_y = gb + GLYPH_LABEL_GAP + th / 2 };
        }
        const lifeline = actor_y + actor.height;
        return .{
            .lifeline_y = lifeline,
            .glyph_bottom_y = lifeline - LABEL_LIFELINE_GAP - th - GLYPH_LABEL_GAP,
            .label_center_y = lifeline - LABEL_LIFELINE_GAP - th / 2,
        };
    }

    /// svgDraw.drawRect: the common rect plus data-look under neo.
    fn drawRectLook(r: *Renderer, parent: *Node, rect: dbm.Rect, name: ?[]const u8) !*Node {
        const n = try r.drawRect(parent, rect, name);
        if (r.neo()) try r.d.attr(n, "data-look", "neo");
        return n;
    }

    fn lifeLine(r: *Renderer, parent: *Node, actor: *Actor, center: f64, y1: f64) !void {
        const ln = try r.d.append(parent, "line");
        try r.d.attr(ln, "id", try std.fmt.allocPrint(r.a, "actor{d}", .{r.actor_cnt}));
        try r.d.attrNum(ln, "x1", center);
        try r.d.attrNum(ln, "y1", y1);
        try r.d.attrNum(ln, "x2", center);
        try r.d.attr(ln, "y2", "2000");
        try r.d.attr(ln, "class", "actor-line 200");
        try r.d.attr(ln, "stroke-width", "0.5px");
        try r.d.attr(ln, "stroke", "#999");
        try r.d.attr(ln, "name", actor.name);
        try r.d.attr(ln, "data-et", "life-line");
        try r.d.attr(ln, "data-id", actor.name);
        try r.life_lines.put(r.a, @intCast(r.actor_cnt), ln);
    }

    fn startGroup(r: *Renderer, actor: *Actor, is_footer: bool, center: f64, centery: f64, with_links: bool) !struct { g: *Node, outer: *Node } {
        const outer = try r.d.append(r.root, "g");
        dom.Dom.lower(outer);
        var g = outer;
        if (!is_footer) {
            r.actor_cnt += 1;
            try r.lifeLine(outer, actor, center, centery);
            g = try r.d.append(outer, "g");
            actor.actor_cnt = @intCast(r.actor_cnt);
            if (with_links) try r.d.attrFmt(g, "id", "root-{d}", .{r.actor_cnt});
            if (r.neo()) try r.d.attr(g, "data-look", "neo");
        }
        return .{ .g = g, .outer = outer };
    }

    fn drawIcon(r: *Renderer, g: *Node, actor: *const Actor, ix: f64, iy: f64) !void {
        const icon = actor.prop_icon orelse return;
        const src = dbm.jsTrim(icon);
        // the SVG sanitizer drops <use>, so an embedded `@icon` never reaches the output
        if (src.len > 0 and src[0] == '@') return;
        const u = try r.d.append(g, "image");
        try r.d.attrNum(u, "x", ix);
        try r.d.attrNum(u, "y", iy);
        try r.d.attr(u, "xlink:href", sanitizeUrl(src));
    }

    fn baseRect(actor: *const Actor, actor_y: f64, is_footer: bool, a: Allocator, cls_out: *[]const u8) !dbm.Rect {
        var rect: dbm.Rect = .{ .fill = "#EDF2AE" };
        var cls: []const u8 = "actor";
        if (actor.prop_class) |c| cls = c else rect.fill = "#eaeaea";
        cls = try std.mem.concat(a, u8, &.{ cls, if (is_footer) " actor-bottom" else " actor-top" });
        rect.x = actor.x;
        rect.y = actor_y;
        rect.width = actor.width;
        rect.height = actor.height;
        rect.class = cls;
        cls_out.* = cls;
        return rect;
    }

    fn drawActor(r: *Renderer, actor: *Actor, is_footer: bool) !?f64 {
        const t = actor.type;
        if (std.mem.eql(u8, t, "participant")) return try r.drawParticipant(actor, is_footer, false);
        if (std.mem.eql(u8, t, "collections")) return try r.drawParticipant(actor, is_footer, true);
        if (std.mem.eql(u8, t, "queue")) return try r.drawQueue(actor, is_footer);
        if (std.mem.eql(u8, t, "database")) return try r.drawDatabase(actor, is_footer);
        if (std.mem.eql(u8, t, "control")) return try r.drawControl(actor, is_footer);
        if (std.mem.eql(u8, t, "entity")) return try r.drawEntity(actor, is_footer);
        if (std.mem.eql(u8, t, "boundary")) return try r.drawBoundary(actor, is_footer);
        if (std.mem.eql(u8, t, "actor")) return try r.drawActorMan(actor, is_footer);
        return null;
    }

    fn drawParticipant(r: *Renderer, actor: *Actor, is_footer: bool, stacked: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const grp = try r.startGroup(actor, is_footer, center, actor_y + actor.height, true);
        const g = grp.g;
        var cls: []const u8 = "";
        var rect = try baseRect(actor, actor_y, is_footer, r.a, &cls);
        if (!stacked) {
            rect.rx = if (r.neo()) 6 else 3;
            rect.ry = rect.rx;
        } else if (r.neo()) {
            rect.height = actor.height - 6;
        }
        const re = try r.drawRectLook(g, rect, actor.name);
        if (stacked) {
            var sh = rect;
            sh.x = rect.x - 6;
            sh.y = rect.y + 6;
            sh.class = "actor";
            _ = try r.drawRectLook(g, sh, actor.name);
            if (r.neo()) try r.d.attr(g, "filter", try r.shadowUrl());
        } else if (r.neo()) try r.d.attr(re, "filter", try r.shadowUrl());
        actor.rect_data = rect;
        try r.drawIcon(g, actor, rect.x + rect.width - 20, rect.y + 10);
        if (!is_footer) {
            try r.d.attr(g, "data-et", "participant");
            try r.d.attr(g, "data-type", if (stacked) "collections" else "participant");
            try r.d.attr(g, "data-id", actor.name);
        }
        if (stacked) {
            try r.byTspan(g, actor.description, rect.x - 6, rect.y + 6, rect.width, rect.height, "actor actor-box");
        } else {
            try r.byTspan(g, actor.description, rect.x, rect.y, rect.width, rect.height, "actor actor-box");
        }
        if (!r.neo()) actor.height = rect.height;
        return actor.height;
    }

    fn drawQueue(r: *Renderer, actor: *Actor, is_footer: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const grp = try r.startGroup(actor, is_footer, center, actor_y + actor.height, true);
        const g = grp.g;
        var cls: []const u8 = "";
        var rect = try baseRect(actor, actor_y, is_footer, r.a, &cls);
        try r.d.attr(g, "class", cls);
        const h = rect.height;
        const ry = h / 2;
        const rx = ry / (2.5 + h / 50);
        const cyl = try r.d.append(g, "g");
        const arc = try r.d.append(g, "g");
        const p1 = try r.d.append(cyl, "path");
        try r.d.attr(p1, "d", try std.fmt.allocPrint(r.a, "M {s},{s}\n    a {s},{s} 0 0 0 0,{s}\n    h {s}\n    a {s},{s} 0 0 0 0,-{s}\n    Z\n  ", .{ try js(r, rect.x), try js(r, rect.y + ry), try js(r, rx), try js(r, ry), try js(r, h), try js(r, rect.width - 2 * rx), try js(r, rx), try js(r, ry), try js(r, h) }));
        const p2 = try r.d.append(arc, "path");
        try r.d.attr(p2, "d", try std.fmt.allocPrint(r.a, "M {s},{s}\n      a {s},{s} 0 0 0 0,{s}", .{ try js(r, rect.x), try js(r, rect.y + ry), try js(r, rx), try js(r, ry), try js(r, h) }));
        try r.d.attr(cyl, "transform", try std.fmt.allocPrint(r.a, "translate({s}, {s})", .{ try js(r, rx), try js(r, -(h / 2)) }));
        try r.d.attr(arc, "transform", try std.fmt.allocPrint(r.a, "translate({s}, {s})", .{ try js(r, rect.width - rx), try js(r, -h / 2) }));
        rect.class = null;
        actor.rect_data = rect;
        if (r.neo()) try r.d.attr(cyl, "filter", try r.shadowUrl());
        try r.drawIcon(g, actor, rect.x + rect.width - 20, rect.y + 10);
        try r.byTspan(g, actor.description, rect.x, rect.y, rect.width, rect.height, "actor actor-box");
        if (!r.neo()) actor.height = h;
        if (!is_footer) {
            try r.d.attr(g, "data-et", "participant");
            try r.d.attr(g, "data-type", "queue");
            try r.d.attr(g, "data-id", actor.name);
        }
        return actor.height;
    }

    fn js(r: *Renderer, v: f64) ![]const u8 {
        return numfmt.js(r.a, v);
    }

    fn drawDatabase(r: *Renderer, actor: *Actor, is_footer: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const bd = r.bands(actor, is_footer, actor_y);
        const centery = if (bd) |b| b.lifeline_y else actor_y + actor.height + 2 * r.conf.box_text_margin;
        const grp = try r.startGroup(actor, is_footer, center, centery, true);
        const g = grp.g;
        var cls: []const u8 = "";
        var rect = try baseRect(actor, actor_y, is_footer, r.a, &cls);
        rect.class = null;
        const w = rect.width / 3;
        const rx = w / 2;
        const ry = rx / (2.5 + w / 50);
        const h = if (bd != null) GLYPH_BAND else rect.width / 3;
        const cylinder_y = if (bd) |b| b.glyph_bottom_y - h - ry else rect.y;
        const cyl = try r.d.append(g, "g");
        try r.d.attr(cyl, "class", cls);
        const p = try r.d.append(cyl, "path");
        try r.d.attr(p, "d", try std.fmt.allocPrint(r.a, "\n  M {s},{s}\n  a {s},{s} 0 0 0 {s},0\n  a {s},{s} 0 0 0 -{s},0\n  l 0,{s}\n  a {s},{s} 0 0 0 {s},0\n  l 0,-{s}\n", .{ try js(r, rect.x), try js(r, cylinder_y + ry), try js(r, rx), try js(r, ry), try js(r, w), try js(r, rx), try js(r, ry), try js(r, w), try js(r, h - 2 * ry), try js(r, rx), try js(r, ry), try js(r, w), try js(r, h - 2 * ry) }));
        if (r.neo()) try r.d.attr(cyl, "filter", try r.shadowUrl());
        try r.d.style(cyl, "stroke", r.theme.str("actorBorder"));
        try r.d.attr(cyl, "transform", try std.fmt.allocPrint(r.a, "translate({s}, {s})", .{ try js(r, w), try js(r, ry) }));
        actor.rect_data = rect;
        const text_y = if (bd) |b| b.label_center_y - rect.height / 2 else rect.y + 35;
        try r.byTspan(g, actor.description, rect.x, text_y, rect.width, rect.height, "actor actor-box");
        if (bd == null) actor.height = h + r.conf.label_box_height;
        if (!is_footer) {
            try r.d.attr(g, "data-et", "participant");
            try r.d.attr(g, "data-type", "database");
            try r.d.attr(g, "data-id", actor.name);
        }
        return actor.height;
    }

    fn manGroup(r: *Renderer, actor: *Actor, is_footer: bool, center: f64, centery: f64) !*Node {
        const line = try r.d.append(r.root, "g");
        dom.Dom.lower(line);
        if (!is_footer) {
            r.actor_cnt += 1;
            try r.lifeLine(line, actor, center, centery);
            actor.actor_cnt = @intCast(r.actor_cnt);
        }
        return line;
    }

    fn manElem(r: *Renderer, actor: *Actor, is_footer: bool, base: []const u8) !*Node {
        const e = try r.d.append(r.root, "g");
        try r.d.attr(e, "class", try std.fmt.allocPrint(r.a, "{s} {s}", .{ base, if (is_footer) "actor-bottom" else "actor-top" }));
        try r.d.attr(e, "name", actor.name);
        return e;
    }

    fn drawControl(r: *Renderer, actor: *Actor, is_footer: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const bd = r.bands(actor, is_footer, actor_y);
        const centery = if (bd) |b| b.lifeline_y else actor_y + 75;
        _ = try r.manGroup(actor, is_footer, center, centery);
        const e = try r.manElem(actor, is_footer, "actor-man");
        const cx = actor.x + actor.width / 2;
        const rad: f64 = 22;
        const cy = if (bd) |b| b.glyph_bottom_y - rad else actor_y + 32;
        const defs = try r.d.append(e, "defs");
        const mk = try r.d.append(defs, "marker");
        try r.d.attr(mk, "id", try std.fmt.allocPrint(r.a, "{s}-filled-head-control", .{r.id}));
        try r.d.attr(mk, "refX", "11");
        try r.d.attr(mk, "refY", "5.8");
        try r.d.attr(mk, "markerWidth", "20");
        try r.d.attr(mk, "markerHeight", "28");
        try r.d.attr(mk, "orient", "172.5");
        try r.d.attr(mk, "stroke-width", "1.2");
        const mp = try r.d.append(mk, "path");
        try r.d.attr(mp, "d", "M 14.4 5.6 L 7.2 10.4 L 8.8 5.6 L 7.2 0.8 Z");
        const c = try r.d.append(e, "circle");
        try r.d.attrNum(c, "cx", cx);
        try r.d.attrNum(c, "cy", cy);
        try r.d.attrNum(c, "r", rad);
        try r.d.attr(c, "filter", if (r.neo()) try r.shadowUrl() else "");
        const ln = try r.d.append(e, "line");
        try r.d.attr(ln, "marker-end", try std.fmt.allocPrint(r.a, "url(#{s}-filled-head-control)", .{r.id}));
        try r.d.attr(ln, "transform", try std.fmt.allocPrint(r.a, "translate({s}, {s})", .{ try numfmt.js(r.a, cx), try numfmt.js(r.a, cy - rad) }));
        try r.d.style(e, "stroke", r.theme.str("actorBorder"));
        try r.d.style(e, "fill", r.theme.str("actorBkg"));
        const rect_h = actor.height;
        if (bd == null) actor.height = 44 + 2 * r.conf.label_box_height;
        const text_y = if (bd) |b| b.label_center_y - rect_h / 2 else actor_y + rad + (if (!is_footer) @as(f64, 12) else 5);
        try r.byTspan(e, actor.description, actor.x, text_y, actor.width, rect_h, "actor actor-man");
        if (!is_footer) {
            try r.d.attr(e, "data-et", "participant");
            try r.d.attr(e, "data-type", "control");
            try r.d.attr(e, "data-id", actor.name);
        }
        return actor.height;
    }

    fn drawEntity(r: *Renderer, actor: *Actor, is_footer: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const bd = r.bands(actor, is_footer, actor_y);
        const centery = if (bd) |b| b.lifeline_y else actor_y + 75;
        const line = try r.d.append(r.root, "g");
        dom.Dom.lower(line);
        const e = try r.manElem(actor, is_footer, "actor");
        const cx = actor.x + actor.width / 2;
        const rad: f64 = 22;
        const cy = if (bd) |b| b.glyph_bottom_y - rad else actor_y + (if (!is_footer) @as(f64, 25) else 10);
        const c = try r.d.append(e, "circle");
        try r.d.attrNum(c, "cx", cx);
        try r.d.attrNum(c, "cy", cy);
        try r.d.attrNum(c, "r", rad);
        try r.d.attrNum(c, "width", actor.width);
        try r.d.attrNum(c, "height", actor.height);
        const ln = try r.d.append(e, "line");
        try r.d.attrNum(ln, "x1", cx - rad);
        try r.d.attrNum(ln, "x2", cx + rad);
        try r.d.attrNum(ln, "y1", cy + rad);
        try r.d.attrNum(ln, "y2", cy + rad);
        try r.d.attr(ln, "stroke-width", "2");
        if (r.neo()) try r.d.attr(e, "filter", try r.shadowUrl());
        const rect_h = actor.height;
        if (bd == null) actor.height = 44 + r.conf.label_box_height;
        if (!is_footer) {
            r.actor_cnt += 1;
            try r.lifeLine(line, actor, center, centery);
            actor.actor_cnt = @intCast(r.actor_cnt);
        }
        const text_y = if (bd) |b| b.label_center_y - rect_h / 2 else actor_y + (if (!is_footer) @as(f64, 30) else 15);
        try r.byTspan(e, actor.description, actor.x, text_y, actor.width, rect_h, "actor actor-man");
        if (bd == null) try r.d.attr(e, "transform", try std.fmt.allocPrint(r.a, "translate(0, {s})", .{try numfmt.js(r.a, if (is_footer) rad else rad / 2 - 5)}));
        if (!is_footer) {
            try r.d.attr(e, "data-et", "participant");
            try r.d.attr(e, "data-type", "entity");
            try r.d.attr(e, "data-id", actor.name);
        }
        return actor.height;
    }

    fn drawBoundary(r: *Renderer, actor: *Actor, is_footer: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const rad: f64 = 22;
        const bd = r.bands(actor, is_footer, actor_y);
        const centery = if (bd) |b| b.lifeline_y else actor_y + 80;
        const icy = if (bd) |b| b.glyph_bottom_y - rad else actor_y + 12;
        _ = try r.manGroup(actor, is_footer, center, centery);
        const e = try r.manElem(actor, is_footer, "actor-man");
        const cnt = r.actor_cnt;
        const t1 = try r.d.append(e, "line");
        try r.d.attr(t1, "id", try std.fmt.allocPrint(r.a, "actor-man-torso{d}", .{cnt}));
        try r.d.attrNum(t1, "x1", actor.x + actor.width / 2 - rad * 2.5);
        try r.d.attrNum(t1, "y1", icy);
        try r.d.attrNum(t1, "x2", actor.x + actor.width / 2 - 15);
        try r.d.attrNum(t1, "y2", icy);
        const t2 = try r.d.append(e, "line");
        try r.d.attr(t2, "id", try std.fmt.allocPrint(r.a, "actor-man-arms{d}", .{cnt}));
        try r.d.attrNum(t2, "x1", actor.x + actor.width / 2 - rad * 2.5);
        try r.d.attrNum(t2, "y1", icy - 10);
        try r.d.attrNum(t2, "x2", actor.x + actor.width / 2 - rad * 2.5);
        try r.d.attrNum(t2, "y2", icy + 10);
        const c = try r.d.append(e, "circle");
        try r.d.attrNum(c, "cx", actor.x + actor.width / 2);
        try r.d.attrNum(c, "cy", icy);
        try r.d.attrNum(c, "r", rad);
        if (r.neo()) try r.d.attr(e, "filter", try r.shadowUrl());
        try r.d.style(e, "stroke", r.theme.str("actorBorder"));
        const rect_h = actor.height;
        if (bd == null) actor.height = 44 + r.conf.label_box_height;
        const text_y = if (bd) |b| b.label_center_y - rect_h / 2 else actor_y + 15;
        try r.byTspan(e, actor.description, actor.x, text_y, actor.width, rect_h, "actor actor-man");
        if (bd == null) try r.d.attr(e, "transform", try std.fmt.allocPrint(r.a, "translate(0,{s})", .{try numfmt.js(r.a, rad / 2 + 10)}));
        if (!is_footer) {
            try r.d.attr(e, "data-et", "participant");
            try r.d.attr(e, "data-type", "boundary");
            try r.d.attr(e, "data-id", actor.name);
        }
        return actor.height;
    }

    fn drawActorMan(r: *Renderer, actor: *Actor, is_footer: bool) !f64 {
        const actor_y = if (is_footer) actor.stopy orelse 0 else actor.starty;
        const center = actor.x + actor.width / 2;
        const bd = r.bands(actor, is_footer, actor_y);
        const centery = if (bd) |b| b.lifeline_y else actor_y + 80;
        _ = try r.manGroup(actor, is_footer, center, centery);
        const e = try r.manElem(actor, is_footer, "actor-man");
        if (!is_footer) {
            try r.d.attr(e, "data-et", "participant");
            try r.d.attr(e, "data-type", "actor");
            try r.d.attr(e, "data-id", actor.name);
        }
        const cnt = r.actor_cnt;
        const half = ACTOR_TYPE_WIDTH / 2;
        const scale: f64 = if (bd != null) GLYPH_BAND / 65.0 else 1;
        const gy = struct {
            fn f(b: ?Bands, ay: f64, sc: f64, offset: f64) f64 {
                return if (b) |bb| bb.glyph_bottom_y - (60 - offset) * sc else ay + offset;
            }
        }.f;
        const l1 = try r.d.append(e, "line");
        try r.d.attr(l1, "id", try std.fmt.allocPrint(r.a, "actor-man-torso{d}", .{cnt}));
        try r.d.attrNum(l1, "x1", center);
        try r.d.attrNum(l1, "y1", gy(bd, actor_y, scale, 25));
        try r.d.attrNum(l1, "x2", center);
        try r.d.attrNum(l1, "y2", gy(bd, actor_y, scale, 45));
        const l2 = try r.d.append(e, "line");
        try r.d.attr(l2, "id", try std.fmt.allocPrint(r.a, "actor-man-arms{d}", .{cnt}));
        try r.d.attrNum(l2, "x1", center + (-half) * scale);
        try r.d.attrNum(l2, "y1", gy(bd, actor_y, scale, 33));
        try r.d.attrNum(l2, "x2", center + half * scale);
        try r.d.attrNum(l2, "y2", gy(bd, actor_y, scale, 33));
        const l3 = try r.d.append(e, "line");
        try r.d.attrNum(l3, "x1", center + (-half) * scale);
        try r.d.attrNum(l3, "y1", gy(bd, actor_y, scale, 60));
        try r.d.attrNum(l3, "x2", center);
        try r.d.attrNum(l3, "y2", gy(bd, actor_y, scale, 45));
        const l4 = try r.d.append(e, "line");
        try r.d.attrNum(l4, "x1", center);
        try r.d.attrNum(l4, "y1", gy(bd, actor_y, scale, 45));
        try r.d.attrNum(l4, "x2", center + (half - 2) * scale);
        try r.d.attrNum(l4, "y2", gy(bd, actor_y, scale, 60));
        const c = try r.d.append(e, "circle");
        try r.d.attrNum(c, "cx", actor.x + actor.width / 2);
        try r.d.attrNum(c, "cy", gy(bd, actor_y, scale, 10));
        try r.d.attrNum(c, "r", 15 * scale);
        try r.d.attrNum(c, "width", actor.width);
        try r.d.attrNum(c, "height", actor.height);
        if (bd == null) actor.height = 65;
        try r.d.style(e, "stroke", r.theme.str("actorBorder"));
        const text_y = if (bd) |b| b.label_center_y - actor.height / 2 else actor_y + 35;
        try r.byTspan(e, actor.description, actor.x, text_y, actor.width, actor.height, "actor actor-man");
        return actor.height;
    }

    fn drawActors(r: *Renderer, keys: []const []const u8, is_footer: bool) !void {
        if (!is_footer) {
            for (keys) |k| _ = try r.drawActor(r.db.actors.get(k).?, false);
        } else {
            var max_h: f64 = 0;
            r.bumpVerticalPos(r.conf.box_margin * 2);
            for (keys) |k| {
                const actor = r.db.actors.get(k).?;
                if (actor.stopy == null or actor.stopy.? == 0) actor.stopy = r.vpos;
                if (try r.drawActor(actor, true)) |h| max_h = @max(max_h, h);
            }
            r.bumpVerticalPos(max_h + r.conf.box_margin);
        }
    }

    // ---- loops, boxes, popups ----

    fn drawLoop(r: *Renderer, lm: *LoopModel, label: []const u8, msg_id: usize) !void {
        const c = &r.conf;
        const g = try r.d.append(r.root, "g");
        try r.d.attr(g, "data-et", "control-structure");
        try r.d.attr(g, "data-id", try std.fmt.allocPrint(r.a, "i{d}", .{msg_id}));
        const osx = lm.startx;
        const oex = lm.stopx;
        const sx = osx orelse nan;
        const ex = oex orelse nan;
        const sy = lm.starty;
        const oey = lm.stopy;
        const ey = oey orelse nan;
        _ = try r.loopLine(g, osx, sy, oex, sy);
        _ = try r.loopLine(g, oex, sy, oex, oey);
        _ = try r.loopLine(g, osx, oey, oex, oey);
        _ = try r.loopLine(g, osx, sy, osx, oey);
        for (lm.sections.items) |s| {
            const ln = try r.loopLine(g, osx, s.y, oex, s.y);
            try r.d.style(ln, "stroke-dasharray", "3, 3");
        }
        var t: TextObj = .{
            .text = label,
            .x = sx,
            .y = sy,
            .font_family = c.message_font_family,
            .font_size = c.message_font_size,
            .font_weight = c.message_font_weight,
            .anchor = "middle",
            .valign = "middle",
            .tspan = false,
            .width = @max(c.label_box_width, 50),
            .text_margin = c.box_text_margin,
            .class = "labelText",
        };
        const lbh = c.label_box_height;
        const lbh_neo = lbh + (if (r.neo()) @as(f64, 15) else 0);
        const hgt = if (lbh_neo != 0) lbh_neo else 20;
        const poly = try r.d.append(g, "polygon");
        const cut: f64 = 7;
        const w = t.width.?;
        try r.d.attr(poly, "points", try std.fmt.allocPrint(r.a, "{s},{s} {s},{s} {s},{s} {s},{s} {s},{s}", .{
            try optNum(r.a, osx),            try numfmt.js(r.a, t.y),
            try numfmt.js(r.a, t.x + w),     try numfmt.js(r.a, t.y),
            try numfmt.js(r.a, t.x + w),     try numfmt.js(r.a, t.y + hgt - cut),
            try numfmt.js(r.a, t.x + w - cut * 1.2), try numfmt.js(r.a, t.y + hgt),
            try optNum(r.a, osx),            try numfmt.js(r.a, t.y + hgt),
        }));
        try r.d.attr(poly, "class", "labelBox");
        t.y = t.y + hgt / 2;
        _ = try r.drawText(g, &t);
        var t2: TextObj = .{
            .text = lm.title,
            .x = sx + c.label_box_width / 2 + (ex - sx) / 2,
            .y = sy + c.box_margin + c.box_text_margin,
            .anchor = "middle",
            .valign = "middle",
            .text_margin = c.box_text_margin,
            .class = "loopText",
            .font_family = c.message_font_family,
            .font_size = c.message_font_size,
            .font_weight = c.message_font_weight,
        };
        _ = try r.drawText(g, &t2);
        for (lm.sections.items) |s| {
            if (s.title.len > 0) {
                t2.text = s.title;
                t2.x = sx + (ex - sx) / 2;
                t2.y = s.y + c.box_margin + c.box_text_margin;
                t2.class = "sectionTitle";
                t2.anchor = "middle";
                t2.valign = "middle";
                t2.tspan = false;
                _ = try r.drawText(g, &t2);
            }
        }
        lm.height = jr(ey - sy);
    }

    fn loopLine(r: *Renderer, g: *Node, x1: ?f64, y1: ?f64, x2: ?f64, y2: ?f64) !*Node {
        const ln = try r.d.append(g, "line");
        if (x1) |v| try r.d.attrNum(ln, "x1", v);
        if (y1) |v| try r.d.attrNum(ln, "y1", v);
        if (x2) |v| try r.d.attrNum(ln, "x2", v);
        if (y2) |v| try r.d.attrNum(ln, "y2", v);
        try r.d.attr(ln, "class", "loopLine");
        return ln;
    }

    fn drawBox(r: *Renderer, box: *dbm.Box) !void {
        const g = try r.d.append(r.root, "g");
        const bp = r.conf.box_margin * 2;
        const startx = box.x - bp;
        const starty = box.y - bp * 0.25;
        const stopx = startx + box.width + 2 * bp;
        const stopy = starty + box.height + bp * 0.75;
        const rr = try r.d.append(g, "rect");
        try r.d.attrNum(rr, "x", startx);
        try r.d.attrNum(rr, "y", starty);
        try r.d.attr(rr, "fill", box.fill);
        try r.d.attr(rr, "stroke", "rgb(0,0,0, 0.5)");
        try r.d.attrNum(rr, "width", stopx - startx);
        try r.d.attrNum(rr, "height", stopy - starty);
        try r.d.attr(rr, "class", "rect");
        dom.Dom.lower(rr);
        if (box.name.len > 0) {
            try r.byTspan(g, box.name, box.x, box.y + r.conf.box_text_margin + box.text_max_height / 2, box.width, 0, "text");
        }
        dom.Dom.lower(g);
    }

    fn drawPopup(r: *Renderer, actor: *Actor, min_w: f64) !?env.Dim {
        if (actor.links.items.len == 0) return null;
        const rd = actor.rect_data orelse return null;
        const g = try r.d.append(r.root, "g");
        try r.d.attr(g, "id", try std.fmt.allocPrint(r.a, "actor{d}_popup", .{actor.actor_cnt.?}));
        try r.d.attr(g, "class", "actorPopupMenu");
        try r.d.attr(g, "display", if (r.conf.force_menus) "block !important" else "none");
        const cls: []const u8 = if (rd.class) |c| try std.mem.concat(r.a, u8, &.{ "actorPopupMenuPanel ", c }) else "actorPopupMenuPanel";
        const menu_w = if (rd.width > min_w) rd.width else min_w;
        const re = try r.d.append(g, "rect");
        try r.d.attr(re, "class", cls);
        try r.d.attrNum(re, "x", rd.x);
        try r.d.attrNum(re, "y", rd.height);
        try r.d.attr(re, "fill", rd.fill);
        try r.d.attr(re, "stroke", rd.stroke);
        try r.d.attrNum(re, "width", menu_w);
        try r.d.attrNum(re, "height", rd.height);
        try r.d.attrNum(re, "rx", rd.rx);
        try r.d.attrNum(re, "ry", rd.ry);
        var link_y: f64 = 20;
        for (actor.links.items) |l| {
            const a_el = try r.d.append(g, "a");
            const href = sanitizeUrl(l.url);
            if (sanitize.uriAllowed(href)) try r.d.attr(a_el, "xlink:href", href);
            // the page frame forces target=_parent on every link
            try r.d.attr(a_el, "target", "_parent");
            const lines = try splitBreaks(r.a, l.label);
            const fs = r.conf.actor_font_size;
            const n: f64 = @floatFromInt(lines.len);
            for (lines, 0..) |line, i| {
                const dy = @as(f64, @floatFromInt(i)) * fs - (fs * (n - 1)) / 2;
                const t = try r.d.append(a_el, "text");
                try r.d.attrNum(t, "x", rd.x + 10);
                try r.d.attrNum(t, "y", rd.height + link_y);
                try r.d.style(t, "text-anchor", "start");
                try r.d.style(t, "font-size", try px(r.a, fs));
                try r.d.style(t, "font-weight", r.conf.actor_font_weight);
                try r.d.style(t, "font-family", r.conf.actor_font_family);
                const sp = try r.d.append(t, "tspan");
                try r.d.attrNum(sp, "x", rd.x + 10);
                try r.d.attrNum(sp, "dy", dy);
                r.d.text(sp, line);
                try r.d.attrNum(t, "y", rd.height + link_y + 20 / 2.0);
                try r.d.attr(t, "dominant-baseline", "central");
                try r.d.attr(t, "alignment-baseline", "central");
                try r.d.attr(t, "class", "actor");
            }
            link_y += 30;
        }
        try r.d.attrNum(re, "height", link_y);
        return .{ .w = menu_w, .h = rd.height + link_y };
    }

    fn popupWidth(r: *Renderer, actor: *const Actor) !f64 {
        var w: f64 = 0;
        for (actor.links.items) |l| {
            const d = try r.textDims(l.label, r.actorFont());
            const lw = d.w + 2 * r.conf.wrap_padding + 2 * r.conf.box_margin;
            if (w < lw) w = lw;
        }
        return w;
    }

    // ---- models ----

    fn buildNoteModel(r: *Renderer, msg: *const dbm.Message) !NoteModel {
        const from = r.db.actors.get(msg.from.?).?;
        const to = r.db.actors.get(msg.to.?).?;
        const c = &r.conf;
        const startx = from.x;
        const stopx = to.x;
        const should_wrap = msg.wrap and msg.message.len > 0;
        const nf = r.noteFont();
        var td = try r.textDims(if (should_wrap) try r.wrapLabel(msg.message, c.width, nf) else msg.message, nf);
        var nm: NoteModel = .{
            .width = if (should_wrap) c.width else @max(c.width, td.w + 2 * c.note_margin),
            .startx = from.x,
            .message = msg.message,
        };
        if (msg.placement == dbm.PLACEMENT.RIGHTOF) {
            nm.width = if (should_wrap) @max(c.width, td.w) else @max(from.width / 2 + to.width / 2, td.w + 2 * c.note_margin);
            nm.startx = startx + (from.width + c.actor_margin) / 2;
        } else if (msg.placement == dbm.PLACEMENT.LEFTOF) {
            nm.width = if (should_wrap) @max(c.width, td.w + 2 * c.note_margin) else @max(from.width / 2 + to.width / 2, td.w + 2 * c.note_margin);
            nm.startx = startx - nm.width + (from.width - c.actor_margin) / 2;
        } else if (std.mem.eql(u8, msg.to.?, msg.from.?)) {
            td = try r.textDims(if (should_wrap) try r.wrapLabel(msg.message, @max(c.width, from.width), nf) else msg.message, nf);
            nm.width = if (should_wrap) @max(c.width, from.width) else @max(@max(from.width, c.width), td.w + 2 * c.note_margin);
            nm.startx = startx + (from.width - nm.width) / 2;
        } else {
            nm.width = @abs(startx + from.width / 2 - (stopx + to.width / 2)) + c.actor_margin;
            nm.startx = if (startx < stopx) startx + from.width / 2 - c.actor_margin / 2 else stopx + to.width / 2 - c.actor_margin / 2;
        }
        if (should_wrap) nm.message = try r.wrapLabel(msg.message, nm.width - 2 * c.wrap_padding, nf);
        return nm;
    }

    fn centralOffset(msg: *const dbm.Message, to_right: bool) f64 {
        var off: f64 = 0;
        const rd = msg.central == LT.CENTRAL_CONNECTION_REVERSE or msg.central == LT.CENTRAL_CONNECTION_DUAL;
        if (rd) off += 4;
        if (rd and isBidi(msg.type.?)) off += if (to_right) @as(f64, 0) else -6;
        return off;
    }

    fn buildMessageModel(r: *Renderer, msg: *dbm.Message) !MsgModel {
        const t = msg.type orelse return .{};
        if (!isArrowType(t)) return .{};
        const fb = r.activationBounds(msg.from.?);
        const tb = r.activationBounds(msg.to.?);
        const from_left = fb[0];
        const from_right = fb[1];
        const to_left = tb[0];
        const to_right_b = tb[1];
        const to_right = from_left <= to_left;
        var startx = if (to_right) from_right else from_left;
        var stopx = if (to_right) to_left else to_right_b;
        if (r.neo()) {
            if (t != LT.SOLID_OPEN) stopx += if (to_right) @as(f64, -3) else 3;
            if (isBidi(t)) startx += if (to_right) @as(f64, 3) else -3;
        }
        startx += centralOffset(msg, to_right);
        const is_to_activation = @abs(to_left - to_right_b) > 2;
        const adj = struct {
            fn f(tr: bool, v: f64) f64 {
                return if (tr) -v else v;
            }
        }.f;
        if (std.mem.eql(u8, msg.from.?, msg.to.?)) {
            stopx = startx;
        } else {
            if (msg.activate and !is_to_activation) stopx += adj(to_right, r.conf.activation_width / 2 - 1);
            switch (t) {
                LT.SOLID_OPEN, LT.DOTTED_OPEN, LT.STICK_TOP, LT.STICK_BOTTOM, LT.STICK_TOP_DOTTED, LT.STICK_BOTTOM_DOTTED, LT.SOLID_ARROW_TOP_REVERSE_DOTTED, LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED, LT.STICK_ARROW_TOP_REVERSE, LT.STICK_ARROW_BOTTOM_REVERSE, LT.STICK_ARROW_TOP_REVERSE_DOTTED, LT.STICK_ARROW_BOTTOM_REVERSE_DOTTED, LT.SOLID_ARROW_TOP_REVERSE, LT.SOLID_ARROW_BOTTOM_REVERSE => {},
                else => stopx += adj(to_right, 3),
            }
            switch (t) {
                LT.BIDIRECTIONAL_SOLID, LT.BIDIRECTIONAL_DOTTED, LT.SOLID_ARROW_TOP_REVERSE_DOTTED, LT.SOLID_ARROW_BOTTOM_REVERSE_DOTTED, LT.SOLID_ARROW_TOP_REVERSE, LT.SOLID_ARROW_BOTTOM_REVERSE => startx -= adj(to_right, 3),
                else => {},
            }
        }
        const bw = @abs(startx - stopx);
        if (msg.wrap and msg.message.len > 0) {
            msg.message = try r.wrapLabel(msg.message, @max(bw + 2 * r.conf.wrap_padding, r.conf.width), r.messageFont());
        }
        const md = try r.textDims(msg.message, r.messageFont());
        return .{
            .valid = true,
            .width = @max(@max(if (msg.wrap) @as(f64, 0) else md.w + 2 * r.conf.wrap_padding, bw + 2 * r.conf.wrap_padding), r.conf.width),
            .startx = startx,
            .stopx = stopx,
            .message = msg.message,
            .type_ = t,
            .wrap = msg.wrap,
            .from_bounds = @min(@min(from_left, from_right), @min(to_left, to_right_b)),
            .to_bounds = @max(@max(from_left, from_right), @max(to_left, to_right_b)),
        };
    }


    fn calculateLoopBounds(r: *Renderer) !std.AutoHashMapUnmanaged(usize, *LoopWidth) {
        var loops: std.AutoHashMapUnmanaged(usize, *LoopWidth) = .empty;
        var stack: std.ArrayList(struct { id: usize, lw: *LoopWidth }) = .empty;
        const msgs = r.db.messages.items;
        r.model_idx = try r.a.alloc(?usize, msgs.len);
        for (msgs, 0..) |*msg, mi| {
            try r.tick();
            r.model_idx[mi] = null;
            const t = msg.type orelse 255;
            switch (t) {
                LT.LOOP_START, LT.ALT_START, LT.OPT_START, LT.PAR_START, LT.PAR_OVER_START, LT.CRITICAL_START, LT.BREAK_START => {
                    const lw = try r.a.create(LoopWidth);
                    lw.* = .{ .from = MAX_SAFE, .to = -MAX_SAFE, .width = 0 };
                    try stack.append(r.a, .{ .id = msg.id, .lw = lw });
                },
                LT.ALT_ELSE, LT.PAR_AND, LT.CRITICAL_OPTION => if (msg.message.len > 0) {
                    const cur = stack.items[stack.items.len - 1];
                    try loops.put(r.a, cur.id, cur.lw);
                    try loops.put(r.a, msg.id, cur.lw);
                },
                LT.LOOP_END, LT.ALT_END, LT.OPT_END, LT.PAR_END, LT.CRITICAL_END, LT.BREAK_END => {
                    const cur = stack.pop().?;
                    try loops.put(r.a, cur.id, cur.lw);
                },
                LT.ACTIVE_START => {
                    const ar = r.db.actors.get(msg.from.?) orelse return error.BadModel;
                    const stacked: f64 = @floatFromInt(r.actorActivationCount(msg.from.?));
                    const x = ar.x + ar.width / 2 + ((stacked - 1) * r.conf.activation_width) / 2;
                    const act = try r.a.create(Activation);
                    act.* = .{ .startx = x, .starty = 0, .stopx = x + r.conf.activation_width, .actor = msg.from.? };
                    try r.activations.append(r.a, act);
                },
                LT.ACTIVE_END => {
                    var idx: ?usize = null;
                    for (r.activations.items, 0..) |x, i| if (std.mem.eql(u8, x.actor, msg.from.?)) {
                        idx = i;
                    };
                    if (r.activations.items.len > 0) _ = r.activations.orderedRemove(idx orelse r.activations.items.len - 1);
                },
                else => {},
            }
            if (msg.placement != null) {
                const nm = try r.buildNoteModel(msg);
                try r.note_models.append(r.a, nm);
                r.model_idx[mi] = r.note_models.items.len - 1;
                for (stack.items) |stk| {
                    const cur = stk.lw;
                    cur.from = @min(cur.from, nm.startx);
                    cur.to = @max(cur.to, nm.startx + nm.width);
                    cur.width = @max(cur.width, @abs(cur.from - cur.to)) - r.conf.label_box_width;
                }
            } else {
                const mm = try r.buildMessageModel(msg);
                try r.msg_models.append(r.a, mm);
                r.model_idx[mi] = r.msg_models.items.len - 1;
                if (mm.valid and mm.startx != 0 and mm.stopx != 0 and stack.items.len > 0) {
                    for (stack.items) |stk| {
                        const cur = stk.lw;
                        if (mm.startx == mm.stopx) {
                            const from = r.db.actors.get(msg.from.?).?;
                            const to = r.db.actors.get(msg.to.?).?;
                            cur.from = @min(@min(from.x - mm.width / 2, from.x - from.width / 2), cur.from);
                            cur.to = @max(@max(to.x + mm.width / 2, to.x + from.width / 2), cur.to);
                            cur.width = @max(cur.width, @abs(cur.to - cur.from)) - r.conf.label_box_width;
                        } else {
                            cur.from = @min(mm.startx, cur.from);
                            cur.to = @max(mm.stopx, cur.to);
                            cur.width = @max(cur.width, mm.width) - r.conf.label_box_width;
                        }
                    }
                }
            }
        }
        r.activations.clearRetainingCapacity();
        return loops;
    }

    const LoopKind = enum { new_loop, section, rect };

    fn adjustLoop(r: *Renderer, lws: *const std.AutoHashMapUnmanaged(usize, *LoopWidth), msg: *dbm.Message, pre: f64, post: f64, kind: LoopKind) !void {
        r.bumpVerticalPos(pre);
        var adjust = post;
        if (msg.message.len > 0) if (lws.get(msg.id)) |lw| {
            const text = try std.mem.concat(r.a, u8, &.{ "[", msg.message, "]" });
            msg.message = try r.wrapLabel(text, lw.width - 2 * r.conf.wrap_padding, r.messageFont());
            msg.wrap = true;
            const td = try r.textDims(msg.message, r.messageFont());
            adjust = post + @max(td.h, r.conf.label_box_height);
        };
        switch (kind) {
            .new_loop => try r.newLoop(msg.message, msg.wrap, null),
            .section => {
                const l = r.items.pop().?;
                try l.sections.append(r.a, .{ .y = r.vpos, .title = msg.message });
                try r.items.append(r.a, l);
            },
            .rect => {
                var fill = msg.message;
                if (fill.len == 0) fill = r.conf.rect_bkg_color orelse r.theme.get("rectBkgColor") orelse r.theme.get("actorBkg") orelse "rgba(128, 128, 128, 0.5)";
                try r.newLoop("", false, fill);
            },
        }
        r.bumpVerticalPos(adjust);
    }

    fn adjustCreatedDestroyed(r: *Renderer, msg: *const dbm.Message, mm: *MsgModel, line_start_y: f64, index: usize) void {
        const wide = struct {
            fn f(a: *const Actor) bool {
                const t = a.type;
                return std.mem.eql(u8, t, "actor") or std.mem.eql(u8, t, "control") or std.mem.eql(u8, t, "entity") or std.mem.eql(u8, t, "database");
            }
        }.f;
        const from_a = r.db.actors.get(msg.from.?).?;
        const to_a = r.db.actors.get(msg.to.?).?;
        const nm = r.conf.note_margin;
        if (r.db.created.get(msg.to.?)) |ci| if (ci == index) {
            const actor = to_a;
            const adjustment: f64 = if (wide(actor)) ACTOR_TYPE_WIDTH / 2 + 3 else actor.width / 2 + 3;
            r.receiverAdj(actor, from_a, mm, adjustment, nm);
            actor.starty = line_start_y - actor.height / 2;
            r.bumpVerticalPos(actor.height / 2);
            return;
        };
        if (r.db.destroyed.get(msg.from.?)) |di| if (di == index) {
            const actor = from_a;
            if (r.conf.mirror_actors) {
                const adjustment: f64 = if (wide(actor)) ACTOR_TYPE_WIDTH / 2 else actor.width / 2;
                if (actor.x < to_a.x) {
                    r.insert(mm.startx - adjustment, mm.starty, mm.stopx, mm.stopy + actor.height / 2 + nm);
                    mm.startx += adjustment;
                } else {
                    r.insert(mm.stopx, mm.starty, mm.startx + adjustment, mm.stopy + actor.height / 2 + nm);
                    mm.startx -= adjustment;
                }
            }
            actor.stopy = line_start_y - actor.height / 2;
            r.bumpVerticalPos(actor.height / 2);
            return;
        };
        if (r.db.destroyed.get(msg.to.?)) |di| if (di == index) {
            const actor = to_a;
            if (r.conf.mirror_actors) {
                const adjustment: f64 = if (wide(actor)) ACTOR_TYPE_WIDTH / 2 + 3 else actor.width / 2 + 3;
                r.receiverAdj(actor, from_a, mm, adjustment, nm);
            }
            actor.stopy = line_start_y - actor.height / 2;
            r.bumpVerticalPos(actor.height / 2);
        };
    }

    fn receiverAdj(r: *Renderer, actor: *const Actor, from: *const Actor, mm: *MsgModel, adjustment: f64, nm: f64) void {
        if (actor.x < from.x) {
            r.insert(mm.stopx - adjustment, mm.starty, mm.startx, mm.stopy + actor.height / 2 + nm);
            mm.stopx += adjustment;
        } else {
            r.insert(mm.startx, mm.starty, mm.stopx + adjustment, mm.stopy + actor.height / 2 + nm);
            mm.stopx -= adjustment;
        }
    }

    fn activeEnd(r: *Renderer, from: []const u8, vpos_in: f64) !void {
        var vp = vpos_in;
        const act = try r.endActivation(from);
        if (act.starty + 18 > vp) {
            act.starty = vp - 6;
            vp += 12;
        }
        const n = r.actorActivationCount(from);
        var rect: dbm.Rect = .{ .fill = "#EDF2AE" };
        rect.x = act.startx;
        rect.y = act.starty;
        rect.class = try std.fmt.allocPrint(r.a, "activation{d}", .{n % 3});
        rect.width = act.stopx - act.startx;
        rect.height = vp - act.starty;
        _ = try r.drawRectLook(act.anchored orelse return error.BadModel, rect, null);
        r.insert(act.startx, vp - 10, act.stopx, vp);
    }

    const MsgDraw = struct { idx: usize, line_y: f64, mi: usize };

    pub fn draw(r: *Renderer) !void {
        const a = r.a;
        const c = &r.conf;
        var widths = try r.getMaxMessageWidthPerActor();
        c.height = try r.calculateActorMargins(&widths);
        const has_boxes = r.db.hasAtLeastOneBox();
        const has_titles = r.db.hasAtLeastOneBoxWithTitle();
        try r.defsSymbol("computer", "24", "24", icons.computer, false);
        try r.defsSymbol("database", null, null, icons.database, true);
        try r.defsSymbol("clock", "24", "24", icons.clock, false);
        if (has_boxes) {
            r.bumpVerticalPos(c.box_margin);
            if (has_titles) r.bumpVerticalPos(r.db.boxes.items[0].text_max_height);
        }
        var keys: std.ArrayList([]const u8) = .empty;
        for (r.db.actors.keys()) |k| {
            if (c.hide_unused_participants) {
                var used = false;
                for (r.db.messages.items) |m| {
                    if ((m.from != null and std.mem.eql(u8, m.from.?, k)) or (m.to != null and std.mem.eql(u8, m.to.?, k))) used = true;
                }
                if (!used) continue;
            }
            try keys.append(a, k);
        }
        try r.addActorRenderingData(keys.items, 0);
        var loop_widths = try r.calculateLoopBounds();
        try r.defsMarkers();
        if (r.neo()) try r.defsDropShadow();

        var seq_index: f64 = 1;
        var seq_step: f64 = 1;
        var to_draw: std.ArrayList(MsgDraw) = .empty;
        var backgrounds: std.ArrayList(*LoopModel) = .empty;
        const msgs = r.db.messages.items;
        for (msgs, 0..) |*msg, index| {
            try r.tick();
            const t = msg.type orelse 255;
            switch (t) {
                LT.NOTE => {
                    const nm = &r.note_models.items[r.model_idx[index].?];
                    try r.drawNote(nm, msg.id);
                },
                LT.ACTIVE_START, LT.CENTRAL_CONNECTION, LT.CENTRAL_CONNECTION_REVERSE => try r.newActivation(msg.from.?),
                LT.ACTIVE_END => try r.activeEnd(msg.from.?, r.vpos),
                LT.LOOP_START, LT.OPT_START, LT.ALT_START, LT.CRITICAL_START, LT.BREAK_START => try r.adjustLoop(&loop_widths, msg, c.box_margin, c.box_margin + c.box_text_margin, .new_loop),
                LT.PAR_START, LT.PAR_OVER_START => try r.adjustLoop(&loop_widths, msg, c.box_margin, c.box_margin + c.box_text_margin, .new_loop),
                LT.ALT_ELSE, LT.PAR_AND, LT.CRITICAL_OPTION => try r.adjustLoop(&loop_widths, msg, c.box_margin + c.box_text_margin, c.box_margin, .section),
                LT.RECT_START => try r.adjustLoop(&loop_widths, msg, c.box_margin, c.box_margin, .rect),
                LT.LOOP_END, LT.OPT_END, LT.ALT_END, LT.PAR_END, LT.CRITICAL_END, LT.BREAK_END => {
                    const lm = r.items.pop().?;
                    const label = switch (t) {
                        LT.LOOP_END => "loop",
                        LT.OPT_END => "opt",
                        LT.ALT_END => "alt",
                        LT.PAR_END => "par",
                        LT.CRITICAL_END => "critical",
                        else => "break",
                    };
                    try r.drawLoop(lm, label, msg.id);
                    r.bumpVerticalPos((lm.stopy orelse nan) - r.vpos);
                },
                LT.RECT_END => {
                    const lm = r.items.pop().?;
                    try backgrounds.append(a, lm);
                    r.bumpVerticalPos((lm.stopy orelse nan) - r.vpos);
                },
                LT.AUTONUMBER => {
                    if (msg.seq_start) |s| if (s != 0) {
                        seq_index = s;
                    };
                    if (msg.seq_step) |s| if (s != 0) {
                        seq_step = s;
                    };
                    r.db.sequence_numbers = msg.seq_visible;
                },
                else => {
                    const mm = &r.msg_models.items[r.model_idx[index].?];
                    mm.starty = r.vpos;
                    mm.sequence_index = seq_index;
                    mm.sequence_visible = r.db.sequence_numbers;
                    const lsy = try r.boundMessage(mm);
                    r.adjustCreatedDestroyed(msg, mm, lsy, index);
                    try to_draw.append(a, .{ .idx = index, .line_y = lsy, .mi = r.model_idx[index].? });
                },
            }
            if (isArrowType(t)) seq_index = jr((seq_index + seq_step) * 100) / 100;
        }

        try r.drawActors(keys.items, false);
        for (to_draw.items) |e| {
            try r.tick();
            try r.drawMessage(&r.msg_models.items[e.mi], e.line_y, &msgs[e.idx]);
        }
        if (c.mirror_actors) try r.drawActors(keys.items, true);
        for (backgrounds.items) |lm| {
            const rr = try r.d.append(r.root, "rect");
            try r.d.attrNum(rr, "x", lm.startx orelse nan);
            try r.d.attrNum(rr, "y", lm.starty);
            try r.d.attr(rr, "fill", lm.fill.?);
            try r.d.attrNum(rr, "width", (lm.stopx orelse nan) - (lm.startx orelse nan));
            try r.d.attrNum(rr, "height", (lm.stopy orelse nan) - lm.starty);
            try r.d.attr(rr, "class", "rect");
            dom.Dom.lower(rr);
        }
        for (keys.items) |k| {
            const actor = r.db.actors.get(k).?;
            const ln = if (actor.actor_cnt) |n| r.life_lines.get(n) else null;
            if (ln) |l| {
                if (!c.mirror_actors and actor.stopy != null and actor.stopy.? != 0) {
                    try r.d.attrNum(l, "y2", actor.stopy.? + actor.height / 2);
                } else if (c.mirror_actors) {
                    if (actor.stopy) |s| try r.d.attrNum(l, "y2", s);
                }
            }
        }
        for (r.boxes.items) |box| {
            box.height = r.vpos - box.y;
            r.insert(box.x, box.y, box.x + box.width, box.height);
            try r.drawBox(box);
        }
        if (has_boxes) r.bumpVerticalPos(c.box_margin);

        var max_pop_h: f64 = 0;
        var max_pop_w: f64 = 0;
        for (keys.items) |k| {
            const actor = r.db.actors.get(k).?;
            const min_w = try r.popupWidth(actor);
            if (try r.drawPopup(actor, min_w)) |dm| {
                if (dm.h > max_pop_h) max_pop_h = dm.h;
                if (dm.w + actor.x > max_pop_w) max_pop_w = dm.w + actor.x;
            }
        }
        const sx = r.data_startx orelse 0;
        const sy = r.data_starty orelse 0;
        const ex = r.data_stopx orelse 0;
        const ey = r.data_stopy orelse 0;
        var box_h = ey - sy;
        if (box_h < max_pop_h) box_h = max_pop_h;
        var height = box_h + 2 * c.diagram_margin_y;
        if (c.mirror_actors) height = height - c.box_margin + c.bottom_margin_adj;
        var box_w = ex - sx;
        if (box_w < max_pop_w) box_w = max_pop_w;
        const width = box_w + 2 * c.diagram_margin_x;
        const title = r.db.title;
        if (title) |tt| if (tt.len > 0) {
            const te = try r.d.append(r.root, "text");
            r.d.text(te, tt);
            try r.d.attrNum(te, "x", (ex - sx) / 2 - 2 * c.diagram_margin_x);
            try r.d.attr(te, "y", "-25");
        };
        r.out_w = width;
        r.out_h = height;
        const extra: f64 = if (title != null and title.?.len > 0) 40 else 0;
        const neo_extra: f64 = if (r.db.actors.count() > 0 and r.neo()) 30 else 0;
        r.vb = .{ sx - c.diagram_margin_x, -(c.diagram_margin_y + extra), width, height + extra + neo_extra };
    }

    fn defsSymbol(r: *Renderer, name: []const u8, w: ?[]const u8, h: ?[]const u8, path: []const u8, evenodd: bool) !void {
        const defs = try r.d.append(r.root, "defs");
        const sym = try r.d.append(defs, "symbol");
        try r.d.attr(sym, "id", try std.fmt.allocPrint(r.a, "{s}-{s}", .{ r.id, name }));
        if (evenodd) {
            try r.d.attr(sym, "fill-rule", "evenodd");
            try r.d.attr(sym, "clip-rule", "evenodd");
        }
        if (w) |x| try r.d.attr(sym, "width", x);
        if (h) |x| try r.d.attr(sym, "height", x);
        const p = try r.d.append(sym, "path");
        try r.d.attr(p, "transform", "scale(.5)");
        try r.d.attr(p, "d", path);
    }

    fn defsDropShadow(r: *Renderer) !void {
        const defs = try r.d.append(r.root, "defs");
        const f = try r.d.append(defs, "filter");
        try r.d.attr(f, "id", try std.fmt.allocPrint(r.a, "{s}-drop-shadow", .{r.id}));
        try r.d.attr(f, "height", "130%");
        try r.d.attr(f, "width", "130%");
        const sh = try r.d.append(f, "feDropShadow");
        try r.d.attr(sh, "dx", "4");
        try r.d.attr(sh, "dy", "4");
        try r.d.attr(sh, "stdDeviation", "0");
        try r.d.attr(sh, "flood-opacity", "0.06");
        try r.d.attr(sh, "flood-color", "#FFFFFF");
    }

    fn defsMarkers(r: *Renderer) !void {
        const M = struct { id: []const u8, attrs: []const [2][]const u8, path: []const u8, path_attrs: []const [2][]const u8 = &.{}, circle: bool = false, path_style: ?[2][]const u8 = null };
        const ms = [_]M{
            .{ .id = "arrowhead", .attrs = &.{ .{ "refX", "7.9" }, .{ "refY", "5" }, .{ "markerUnits", "userSpaceOnUse" }, .{ "markerWidth", "12" }, .{ "markerHeight", "12" }, .{ "orient", "auto-start-reverse" } }, .path = "M -1 0 L 10 5 L 0 10 z" },
            .{ .id = "crosshead", .attrs = &.{ .{ "markerWidth", "15" }, .{ "markerHeight", "8" }, .{ "orient", "auto" }, .{ "refX", "4" }, .{ "refY", "4.5" } }, .path = "M 1,2 L 6,7 M 6,2 L 1,7", .path_attrs = &.{ .{ "fill", "none" }, .{ "stroke", "#000000" }, .{ "stroke-width", "1pt" } }, .path_style = .{ "stroke-dasharray", "0, 0" } },
            .{ .id = "filled-head", .attrs = &.{ .{ "refX", "15.5" }, .{ "refY", "7" }, .{ "markerWidth", "20" }, .{ "markerHeight", "28" }, .{ "orient", "auto" } }, .path = "M 18,7 L9,13 L14,7 L9,1 Z" },
            .{ .id = "sequencenumber", .attrs = &.{ .{ "refX", "15" }, .{ "refY", "15" }, .{ "markerWidth", "60" }, .{ "markerHeight", "40" }, .{ "orient", "auto" } }, .path = "", .circle = true },
            .{ .id = "solidTopArrowHead", .attrs = &.{ .{ "refX", "7.9" }, .{ "refY", "7.25" }, .{ "markerUnits", "userSpaceOnUse" }, .{ "markerWidth", "12" }, .{ "markerHeight", "12" }, .{ "orient", "auto-start-reverse" } }, .path = "M 0 0 L 10 8 L 0 8 z" },
            .{ .id = "solidBottomArrowHead", .attrs = &.{ .{ "refX", "7.9" }, .{ "refY", "0.75" }, .{ "markerUnits", "userSpaceOnUse" }, .{ "markerWidth", "12" }, .{ "markerHeight", "12" }, .{ "orient", "auto-start-reverse" } }, .path = "M 0 0 L 10 0 L 0 8 z" },
            .{ .id = "stickTopArrowHead", .attrs = &.{ .{ "refX", "7.5" }, .{ "refY", "7" }, .{ "markerUnits", "userSpaceOnUse" }, .{ "markerWidth", "12" }, .{ "markerHeight", "12" }, .{ "orient", "auto-start-reverse" } }, .path = "M 0 0 L 7 7", .path_attrs = &.{ .{ "stroke", "black" }, .{ "stroke-width", "1.5" }, .{ "fill", "none" } } },
            .{ .id = "stickBottomArrowHead", .attrs = &.{ .{ "refX", "7.5" }, .{ "refY", "0" }, .{ "markerUnits", "userSpaceOnUse" }, .{ "markerWidth", "12" }, .{ "markerHeight", "12" }, .{ "orient", "auto-start-reverse" } }, .path = "M 0 7 L 7 0", .path_attrs = &.{ .{ "stroke", "black" }, .{ "stroke-width", "1.5" }, .{ "fill", "none" } } },
        };
        for (ms) |m| {
            const defs = try r.d.append(r.root, "defs");
            const mk = try r.d.append(defs, "marker");
            try r.d.attr(mk, "id", try std.fmt.allocPrint(r.a, "{s}-{s}", .{ r.id, m.id }));
            for (m.attrs) |x| try r.d.attr(mk, x[0], x[1]);
            if (m.circle) {
                const ci = try r.d.append(mk, "circle");
                try r.d.attr(ci, "cx", "15");
                try r.d.attr(ci, "cy", "15");
                try r.d.attr(ci, "r", "6");
            } else {
                const p = try r.d.append(mk, "path");
                if (m.path_attrs.len > 0 and std.mem.eql(u8, m.id, "crosshead")) {
                    try r.d.attr(p, "fill", "none");
                    try r.d.attr(p, "stroke", "#000000");
                    try r.d.style(p, "stroke-dasharray", "0, 0");
                    try r.d.attr(p, "stroke-width", "1pt");
                    try r.d.attr(p, "d", m.path);
                } else {
                    try r.d.attr(p, "d", m.path);
                    for (m.path_attrs) |x| try r.d.attr(p, x[0], x[1]);
                }
            }
        }
    }
};

pub fn sanitizeUrl(u: []const u8) []const u8 {
    const t = dbm.jsTrim(u);
    const bad = [_][]const u8{ "javascript:", "data:", "vbscript:" };
    for (bad) |b| if (std.ascii.startsWithIgnoreCase(t, b)) return "about:blank";
    return t;
}

fn isNum(f: f64) bool {
    return !std.math.isNan(f);
}

fn optNum(a: Allocator, v: ?f64) ![]const u8 {
    return if (v) |x| numfmt.js(a, x) else "undefined";
}
