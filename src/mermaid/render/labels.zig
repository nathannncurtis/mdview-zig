const std = @import("std");
const model = @import("model.zig");
const dom = @import("dom.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;

pub const TextOpts = struct {
    style: []const u8 = "",
    is_title: bool = false,
    classes: []const u8 = "",
    is_node: bool = true,
    width: ?f64 = null,
    add_svg_background: bool = false,
    label_type: []const u8 = "text",
    html: ?bool = null,
    center: bool = true,
    min_width: f64 = 0,
};

pub const Atom = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    sp: bool = false,
    brk: bool = false,
};

pub const Line = std.ArrayList(Atom);

pub fn decodeEntities(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, "\u{fb02}\u{b0}") == null and std.mem.indexOf(u8, s, "\u{b6}\u{df}") == null) return s;
    const s1 = try std.mem.replaceOwned(u8, a, s, "\u{fb02}\u{b0}\u{b0}", "&#");
    const s2 = try std.mem.replaceOwned(u8, a, s1, "\u{fb02}\u{b0}", "&");
    return std.mem.replaceOwned(u8, a, s2, "\u{b6}\u{df}", ";");
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn appendCp(a: Allocator, buf: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch return;
    try buf.appendSlice(a, tmp[0..n]);
}

const Builder = struct {
    a: Allocator,
    lines: std.ArrayList(Line) = .empty,
    cur: Line = .empty,
    buf: std.ArrayList(u8) = .empty,
    bold: u32 = 0,
    italic: u32 = 0,

    fn flush(self: *Builder, brk: bool) Allocator.Error!void {
        if (self.buf.items.len == 0) {
            if (brk and self.cur.items.len > 0) self.cur.items[self.cur.items.len - 1].brk = true;
            return;
        }
        try self.cur.append(self.a, .{
            .text = try self.a.dupe(u8, self.buf.items),
            .bold = self.bold > 0,
            .italic = self.italic > 0,
            .brk = brk,
        });
        self.buf.clearRetainingCapacity();
    }

    fn space(self: *Builder) Allocator.Error!void {
        try self.flush(false);
        if (self.cur.items.len > 0) self.cur.items[self.cur.items.len - 1].sp = true;
    }

    fn newline(self: *Builder) Allocator.Error!void {
        try self.flush(false);
        try self.lines.append(self.a, self.cur);
        self.cur = .empty;
    }

    fn finish(self: *Builder) Allocator.Error![]Line {
        try self.flush(false);
        try self.lines.append(self.a, self.cur);
        return self.lines.items;
    }
};

fn isCjk(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0xA4CF) or (cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF);
}

fn parseEntity(s: []const u8, i: *usize) ?u21 {
    const semi = std.mem.indexOfScalarPos(u8, s, i.*, ';') orelse return null;
    if (semi - i.* > 10 or semi == i.* + 1) return null;
    const name = s[i.* + 1 .. semi];
    var cp: ?u21 = null;
    if (name[0] == '#') {
        const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
        const v = std.fmt.parseInt(u21, if (hex) name[2..] else name[1..], if (hex) 16 else 10) catch return null;
        cp = v;
    } else if (eqi(name, "amp")) cp = '&' else if (eqi(name, "lt")) cp = '<' else if (eqi(name, "gt")) cp = '>' else if (eqi(name, "quot")) cp = '"' else if (eqi(name, "apos")) cp = '\'' else if (eqi(name, "nbsp")) cp = 0xA0;
    if (cp) |c| {
        i.* = semi + 1;
        return c;
    }
    return null;
}

// Handles the tags DOMPurify keeps that change layout: br, b/strong, i/em; others are dropped, their text kept.
pub fn parseHtml(a: Allocator, s: []const u8) Allocator.Error![]Line {
    var b: Builder = .{ .a = a };
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '<') {
            if (std.mem.indexOfScalarPos(u8, s, i, '>')) |end| {
                var tag = std.mem.trim(u8, s[i + 1 .. end], " \t\r\n");
                const closing = tag.len > 0 and tag[0] == '/';
                if (closing) tag = std.mem.trimStart(u8, tag[1..], " ");
                var ne: usize = 0;
                while (ne < tag.len and (std.ascii.isAlphanumeric(tag[ne]))) ne += 1;
                const name = tag[0..ne];
                if (name.len > 0) {
                    if (eqi(name, "br")) {
                        try b.newline();
                    } else if (eqi(name, "b") or eqi(name, "strong")) {
                        try b.flush(false);
                        if (closing) b.bold -|= 1 else b.bold += 1;
                    } else if (eqi(name, "i") or eqi(name, "em")) {
                        try b.flush(false);
                        if (closing) b.italic -|= 1 else b.italic += 1;
                    } else if ((eqi(name, "script") or eqi(name, "style")) and !closing) {
                        var j = end + 1;
                        while (j < s.len) : (j += 1) {
                            if (s[j] == '<' and j + 1 < s.len and s[j + 1] == '/') break;
                        }
                        i = std.mem.indexOfScalarPos(u8, s, j, '>') orelse s.len - 1;
                        i += 1;
                        continue;
                    } else if (eqi(name, "p") or eqi(name, "div")) {
                        try b.flush(false);
                    }
                    i = end + 1;
                    continue;
                }
            }
            try b.buf.append(a, c);
            i += 1;
            continue;
        }
        if (c == '&') {
            if (parseEntity(s, &i)) |cp| {
                try appendCp(a, &b.buf, cp);
                continue;
            }
            try b.buf.append(a, c);
            i += 1;
            continue;
        }
        if (isWs(c)) {
            try b.space();
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(s.len, i + len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch 0xFFFD;
        try b.buf.appendSlice(a, s[i..end]);
        i = end;
        if (isCjk(cp)) {
            try b.flush(true);
        } else if (c == '-' and i < s.len and std.ascii.isAlphabetic(s[i])) {
            try b.flush(true);
        }
    }
    return b.finish();
}

fn closeDelim(s: []const u8, from: usize, delim: []const u8) ?usize {
    var i = from;
    while (i + delim.len <= s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], delim) and i > from) return i;
    }
    return null;
}

// Bold and italic only, as handle-markdown-text.ts keeps; other markdown stays literal.
pub fn markdownToHtml(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and std.ascii.isPunctuation(s[i + 1])) {
            try out.appendSlice(a, switch (s[i + 1]) {
                '<' => "&lt;",
                '&' => "&amp;",
                else => s[i + 1 .. i + 2],
            });
            i += 2;
            continue;
        }
        if (c == '*' or c == '_') {
            const dl: usize = if (i + 1 < s.len and s[i + 1] == c) 2 else 1;
            const delim = s[i .. i + dl];
            const prev_alnum = i > 0 and std.ascii.isAlphanumeric(s[i - 1]);
            const ok_open = i + dl < s.len and !isWs(s[i + dl]) and !(c == '_' and prev_alnum);
            if (ok_open) {
                if (closeDelim(s, i + dl, delim)) |e| {
                    if (!isWs(s[e - 1])) {
                        const inner = try markdownToHtml(a, s[i + dl .. e]);
                        try out.appendSlice(a, if (dl == 2) "<strong>" else "<em>");
                        try out.appendSlice(a, inner);
                        try out.appendSlice(a, if (dl == 2) "</strong>" else "</em>");
                        i = e + dl;
                        continue;
                    }
                }
            }
        }
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

fn plainBreaks(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == 'n') {
            try out.appendSlice(a, "<br/>");
            i += 2;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn runWidth(ctx: *const model.Ctx, text: []const u8, bold: bool, italic: bool) f64 {
    const f: model.FontSpec = .{ .family = ctx.cfg.font_family, .size = ctx.cfg.font_size, .bold = bold or ctx.cfg.label_bold, .italic = italic or ctx.cfg.label_italic };
    return ctx.measurer.width(text, f);
}

pub fn lineWidth(ctx: *const model.Ctx, atoms: []const Atom) f64 {
    var w: f64 = 0;
    var run: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < atoms.len) {
        run.clearRetainingCapacity();
        const bold = atoms[i].bold;
        const italic = atoms[i].italic;
        while (i < atoms.len and atoms[i].bold == bold and atoms[i].italic == italic) : (i += 1) {
            run.appendSlice(ctx.a, atoms[i].text) catch return w;
            if (atoms[i].sp and i + 1 < atoms.len) run.append(ctx.a, ' ') catch return w;
        }
        w += runWidth(ctx, run.items, bold, italic);
    }
    return w;
}

fn wrapLine(ctx: *const model.Ctx, a: Allocator, atoms: []const Atom, width: f64, out: *std.ArrayList(Line)) Allocator.Error!void {
    var cur: Line = .empty;
    var i: usize = 0;
    while (i < atoms.len) {
        var j = i;
        while (j + 1 < atoms.len and !atoms[j].sp and !atoms[j].brk) j += 1;
        const chunk = atoms[i .. j + 1];
        i = j + 1;
        if (cur.items.len == 0) {
            try cur.appendSlice(a, chunk);
            continue;
        }
        const start = cur.items.len;
        try cur.appendSlice(a, chunk);
        if (lineWidth(ctx, cur.items) > width) {
            var first: Line = .empty;
            try first.appendSlice(a, cur.items[0..start]);
            first.items[start - 1].sp = false;
            try out.append(a, first);
            var next: Line = .empty;
            try next.appendSlice(a, chunk);
            cur = next;
        }
    }
    if (cur.items.len > 0) try out.append(a, cur);
}

pub const Laid = struct { lines: []Line, w: f64, h: f64 };

pub fn layout(ctx: *const model.Ctx, a: Allocator, html: []const u8, width: f64) Allocator.Error!Laid {
    const raw = try parseHtml(a, html);
    const lh = ctx.cfg.font_size * 1.5;
    var any = false;
    for (raw) |l| if (l.items.len > 0) {
        any = true;
    };
    if (!any) return .{ .lines = &.{}, .w = 0, .h = 0 };
    var natural: f64 = 0;
    for (raw) |l| natural = @max(natural, lineWidth(ctx, l.items));
    var lines: std.ArrayList(Line) = .empty;
    var w = natural;
    if (natural >= width) {
        for (raw) |l| {
            if (l.items.len == 0) try lines.append(a, l) else try wrapLine(ctx, a, l.items, width, &lines);
        }
        w = width;
        for (lines.items) |l| w = @max(w, lineWidth(ctx, l.items));
    } else {
        try lines.appendSlice(a, raw);
    }
    return .{ .lines = lines.items, .w = w, .h = lh * @as(f64, @floatFromInt(lines.items.len)) };
}

fn dropProps(a: Allocator, style: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, style, ';');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "stroke:") or std.mem.startsWith(u8, t, "stroke-width:") or std.mem.startsWith(u8, t, "fill:")) continue;
        if (out.items.len > 0) try out.append(a, ';');
        if (std.mem.startsWith(u8, t, "color:")) {
            try out.appendSlice(a, "fill:");
            try out.appendSlice(a, t["color:".len..]);
        } else try out.appendSlice(a, t);
    }
    return out.items;
}

fn cssValue(style: []const u8, prop: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, style, ';');
    var found: ?[]const u8 = null;
    while (it.next()) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, part[0..colon], " "), prop)) continue;
        var v = std.mem.trim(u8, part[colon + 1 ..], " ");
        if (std.mem.endsWith(u8, v, "!important")) v = std.mem.trim(u8, v[0 .. v.len - "!important".len], " ");
        found = v;
    }
    return found;
}

fn styledCfg(base: *const model.Config, style: []const u8) model.Config {
    var c = base.*;
    if (cssValue(style, "font-size")) |v| {
        if (std.mem.endsWith(u8, v, "px")) c.font_size = std.fmt.parseFloat(f64, v[0 .. v.len - 2]) catch c.font_size;
    }
    if (cssValue(style, "font-family")) |v| c.font_family = v;
    if (cssValue(style, "font-weight")) |v| {
        if (std.mem.eql(u8, v, "bold") or std.mem.eql(u8, v, "bolder")) c.label_bold = true else if (std.fmt.parseInt(u32, v, 10) catch 0 >= 600) c.label_bold = true;
    }
    if (cssValue(style, "font-style")) |v| {
        if (std.mem.eql(u8, v, "italic") or std.mem.eql(u8, v, "oblique")) c.label_italic = true;
    }
    return c;
}

fn mergeWords(a: Allocator, atoms: []const Atom) Allocator.Error![]Atom {
    var out: std.ArrayList(Atom) = .empty;
    for (atoms) |at| {
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (!last.sp and last.bold == at.bold and last.italic == at.italic) {
                last.text = try std.mem.concat(a, u8, &.{ last.text, at.text });
                last.sp = at.sp;
                continue;
            }
        }
        try out.append(a, at);
    }
    return out.items;
}

fn fitsWidth(ctx: *const model.Ctx, a: Allocator, atoms: []const Atom, width: f64) Allocator.Error!bool {
    if (std.math.isInf(width)) return true;
    const c = try a.dupe(Atom, atoms);
    for (c[0 .. c.len -| 1]) |*x| x.sp = true;
    return lineWidth(ctx, c) <= width;
}

fn firstFit(ctx: *const model.Ctx, a: Allocator, word: Atom, width: f64) Allocator.Error!usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < word.text.len) {
        const n = std.unicode.utf8ByteSequenceLength(word.text[i]) catch 1;
        const end = @min(word.text.len, i + n);
        var probe = word;
        probe.text = word.text[0..end];
        probe.sp = false;
        if (!try fitsWidth(ctx, a, &.{probe}, width)) break;
        used = end;
        i = end;
    }
    if (used == 0) {
        const n = std.unicode.utf8ByteSequenceLength(word.text[0]) catch 1;
        used = @min(word.text.len, n);
    }
    return used;
}

// splitLineToFitWidth: a line fits when its advance is at most `width`; a word wider than a line is cut by character.
fn svgWrap(ctx: *const model.Ctx, a: Allocator, raw: []const Line, width: f64) Allocator.Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    for (raw) |ln| {
        if (ln.items.len == 0) {
            try out.append(a, .empty);
            continue;
        }
        const words = try mergeWords(a, ln.items);
        if (try fitsWidth(ctx, a, words, width)) {
            var l: Line = .empty;
            try l.appendSlice(a, words);
            try out.append(a, l);
            continue;
        }
        var cur: Line = .empty;
        var i: usize = 0;
        while (i < words.len) {
            try cur.append(a, words[i]);
            if (try fitsWidth(ctx, a, cur.items, width)) {
                i += 1;
                continue;
            }
            _ = cur.pop();
            if (cur.items.len > 0) {
                try out.append(a, cur);
                cur = .empty;
                continue;
            }
            const k = try firstFit(ctx, a, words[i], width);
            var head = words[i];
            head.text = words[i].text[0..k];
            head.sp = false;
            var l: Line = .empty;
            try l.append(a, head);
            try out.append(a, l);
            if (k < words[i].text.len) words[i].text = words[i].text[k..] else i += 1;
        }
        if (cur.items.len > 0) try out.append(a, cur);
    }
    for (out.items) |*l| {
        if (l.items.len > 1) for (l.items[0 .. l.items.len - 1]) |*w| {
            w.sp = true;
        };
    }
    return out.items;
}

fn rectStyle(a: Allocator, style: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, style, ';');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "stroke:") or std.mem.startsWith(u8, t, "stroke-width:") or std.mem.startsWith(u8, t, "fill:")) continue;
        if (out.items.len > 0) try out.append(a, ';');
        if (std.mem.startsWith(u8, t, "background:")) {
            try out.appendSlice(a, "fill:");
            try out.appendSlice(a, t["background:".len..]);
        } else try out.appendSlice(a, t);
    }
    return out.items;
}

// The htmlLabels:false path (createText.ts createFormattedText). The returned group's box is the text bbox with its top at y=0;
// y_off is where Chrome puts that top relative to the first baseline origin (bbox.y in Mermaid's frame).
fn svgText(ctx0: *const model.Ctx, ctx: *const model.Ctx, parent: *El, text: []const u8, opts: TextOpts) !*El {
    const a = ctx.a;
    const markdown = std.mem.eql(u8, opts.label_type, "markdown");
    const html = if (markdown) try markdownToHtml(a, text) else try plainBreaks(a, text);
    const width = opts.width orelse ctx0.cfg.wrapping_width;
    const raw = try parseHtml(a, html);
    const lines = try svgWrap(ctx0, a, raw, width);

    const g = try parent.insert("g");
    const size = ctx.cfg.font_size;
    const ad = ctx.measurer.ascentDescent(.{ .family = ctx.cfg.font_family, .size = size, .bold = ctx.cfg.label_bold, .italic = ctx.cfg.label_italic });
    const lh = 1.1 * size;
    var first: ?usize = null;
    var last: usize = 0;
    var w: f64 = 0;
    for (lines, 0..) |l, i| {
        if (l.items.len == 0) continue;
        if (first == null) first = i;
        last = i;
        w = @max(w, lineWidth(ctx, l.items));
    }
    const fi = first orelse {
        g.box = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return g;
    };
    const fiv: f64 = @floatFromInt(fi);
    const liv: f64 = @floatFromInt(last);
    g.y_off = dom.r32((1.0 + 1.1 * fiv) * size - ad[0]);
    const h = dom.r32((liv - fiv) * lh + ad[0] + ad[1]);
    w = dom.r32(w);
    const x0: f64 = if (opts.is_node) 0 else -w / 2;
    const tx: f64 = if (!opts.center) 0 else if (opts.is_node) w / 2 else 0;
    const pad: f64 = if (opts.add_svg_background) 2 else 0;
    const widen = if (opts.min_width > w) opts.min_width - w else 0;
    g.box = .{ .x = x0 - widen / 2 - pad, .y = -pad, .w = w + widen + 2 * pad, .h = h + 2 * pad };

    if (opts.add_svg_background) {
        const r = try g.insert("rect");
        try r.setAttr("class", "background");
        _ = try r.attrNum("x", x0 - pad);
        _ = try r.attrNum("y", -pad);
        _ = try r.attrNum("width", w + 2 * pad);
        _ = try r.attrNum("height", h + 2 * pad);
        try r.setAttr("style", if (opts.is_node) "stroke: none" else try rectStyle(a, opts.style));
    }
    const t = try g.insert("text");
    t.box = .{ .x = x0, .y = 0, .w = w, .h = h };
    if (opts.center) try t.setAttr("text-anchor", "middle");
    const style = try dropProps(a, opts.style);
    if (style.len > 0) try t.setAttr("style", style);
    for (lines, 0..) |l, i| {
        if (l.items.len == 0) continue;
        const ts = try t.insert("tspan");
        try ts.setAttr("class", if (opts.is_title) "text-outer-tspan title-row" else "text-outer-tspan row");
        _ = try ts.attrNum("x", tx);
        _ = try ts.attrNum("y", ad[0] + (@as(f64, @floatFromInt(i)) - fiv) * lh);
        for (l.items, 0..) |at, ai| {
            const inner = try ts.insert("tspan");
            try inner.setAttr("class", "text-inner-tspan");
            try inner.setAttr("font-style", if (at.italic) "italic" else "normal");
            try inner.setAttr("font-weight", if (at.bold) "bold" else "normal");
            try inner.setText(if (ai > 0) try std.fmt.allocPrint(a, " {s}", .{at.text}) else at.text);
        }
    }
    return g;
}

// Font Awesome is not loaded in GitHub's frame: the <i> Mermaid emits is 0px wide and draws nothing.
fn stripFa(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, ":fa-") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 'f' and i + 1 < s.len and s[i + 1] == 'a') {
            var j = i + 2;
            if (j < s.len and std.mem.indexOfScalar(u8, "bklrs", s[j]) != null) j += 1;
            if (std.mem.startsWith(u8, s[j..], ":fa-")) {
                var k = j + 4;
                const st = k;
                while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_' or s[k] == '-')) k += 1;
                if (k > st) {
                    i = k;
                    continue;
                }
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

pub fn createText(ctx0: *const model.Ctx, parent: *El, text0: []const u8, opts: TextOpts) !*El {
    const text = try stripFa(ctx0.a, text0);
    var cfg2 = styledCfg(ctx0.cfg, opts.style);
    var ctx1 = ctx0.*;
    ctx1.cfg = &cfg2;
    const ctx: *const model.Ctx = &ctx1;
    if (!(opts.html orelse ctx0.cfg.html_labels)) return svgText(ctx0, ctx, parent, text, opts);
    const a = ctx.a;
    const markdown = std.mem.eql(u8, opts.label_type, "markdown");
    const html = if (markdown) try markdownToHtml(a, text) else try plainBreaks(a, text);
    const width = opts.width orelse ctx.cfg.wrapping_width;
    var laid = try layout(ctx, a, html, width);
    if (laid.w != width and laid.w < opts.min_width) laid.w = opts.min_width;

    const g = try parent.insert("g");
    const label_class = if (opts.is_node) "nodeLabel" else "edgeLabel";
    const cls = if (opts.classes.len > 0) try std.fmt.allocPrint(a, "{s} {s}", .{ label_class, opts.classes }) else label_class;
    try g.setAttr("class", cls);
    g.box = .{ .x = 0, .y = 0, .w = laid.w, .h = laid.h };
    if (laid.lines.len == 0) return g;

    if (opts.add_svg_background) {
        const r = try g.insert("rect");
        try r.setAttr("class", "labelBkg");
        _ = try r.attrNum("width", laid.w);
        _ = try r.attrNum("height", laid.h);
        try r.setAttr("style", "stroke: none");
    }
    const t = try g.insert("text");
    try t.setAttr("text-anchor", "middle");
    const style = try dropProps(a, opts.style);
    if (style.len > 0) try t.setAttr("style", style);
    const lh = ctx.cfg.font_size * 1.5;
    for (laid.lines, 0..) |line, li| {
        if (line.items.len == 0) continue;
        const ts = try t.insert("tspan");
        try ts.setAttr("class", if (opts.is_title) "text-outer-tspan title-row" else "text-outer-tspan row");
        _ = try ts.attrNum("x", laid.w / 2);
        _ = try ts.attrNum("y", @as(f64, @floatFromInt(li)) * lh + lh / 2 + 0.359 * ctx.cfg.font_size);
        for (line.items, 0..) |at, ai| {
            const inner = try ts.insert("tspan");
            try inner.setAttr("class", "text-inner-tspan");
            if (at.bold) try inner.setAttr("font-weight", "bold");
            if (at.italic) try inner.setAttr("font-style", "italic");
            const last = ai + 1 == line.items.len;
            try inner.setText(if (at.sp and !last) try std.fmt.allocPrint(a, "{s} ", .{at.text}) else at.text);
        }
    }
    return g;
}

pub fn createLabel(ctx: *const model.Ctx, text: []const u8, style: []const u8, is_node: bool, is_edge_label: bool) !*El {
    _ = is_edge_label;
    const holder = try El.create(ctx.a, "g");
    const g = try createText(ctx, holder, text, .{
        .style = style,
        .is_node = is_node,
        .center = !is_node,
        .width = std.math.inf(f64),
        .label_type = "text",
    });
    g.detach();
    return g;
}

const fake = struct {
    fn w(_: *anyopaque, text: []const u8, _: model.FontSpec) f64 {
        return 8 * @as(f64, @floatFromInt(text.len));
    }
};

fn testCtx(arena: *std.heap.ArenaAllocator, cfg: *const model.Config) model.Ctx {
    var dummy: u8 = 0;
    return .{ .a = arena.allocator(), .measurer = .{ .ctx = &dummy, .widthFn = fake.w }, .cfg = cfg, .diagram_id = "t" };
}

test "single line label is 8px per char by 24px" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const ctx = testCtx(&arena, &cfg);
    const root = try El.create(ctx.a, "g");
    const g = try createText(&ctx, root, "Hello", .{});
    try std.testing.expectEqual(@as(f64, 40), g.box.?.w);
    try std.testing.expectEqual(@as(f64, 24), g.box.?.h);
}

test "br and long text wrap at 200" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: model.Config = .{};
    cfg.wrapping_width = 200;
    const ctx = testCtx(&arena, &cfg);
    const root = try El.create(ctx.a, "g");
    const g = try createText(&ctx, root, "a<br/>b", .{});
    try std.testing.expectEqual(@as(f64, 48), g.box.?.h);
    const long = try createText(&ctx, root, "aaaa bbbb cccc dddd eeee ffff", .{});
    try std.testing.expectEqual(@as(f64, 200), long.box.?.w);
    try std.testing.expectEqual(@as(f64, 48), long.box.?.h);
    const md = try createText(&ctx, root, "**bold** x", .{ .label_type = "markdown" });
    try std.testing.expectEqual(@as(f64, 48), md.box.?.w);
}

test "createLabel never wraps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: model.Config = .{};
    const ctx = testCtx(&arena, &cfg);
    const l = try createLabel(&ctx, "aaaa bbbb cccc dddd eeee ffff gggg", "", false, true);
    try std.testing.expectEqual(@as(f64, 24), l.box.?.h);
}
