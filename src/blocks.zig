const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

pub const none: u32 = std.math.maxInt(u32);

pub const Kind = enum { document, quote, list, item, footnote, paragraph, heading, code, thematic, html };

pub const Node = struct {
    kind: Kind,
    parent: u32 = none,
    first: u32 = none,
    last: u32 = none,
    next: u32 = none,
    open: bool = true,
    last_blank: bool = false,
    last_checked: bool = false,
    content: std.ArrayList(u8) = .empty,
    level: u8 = 0,
    fenced: bool = false,
    fence_char: u8 = 0,
    fence_len: usize = 0,
    fence_offset: usize = 0,
    html_type: u8 = 0,
    ordered: bool = false,
    delim: u8 = 0,
    bullet: u8 = 0,
    start: u32 = 0,
    tight: bool = true,
    padding: usize = 0,
    marker_offset: usize = 0,
    line: usize = 0,
    label: []const u8 = "",
};

pub const Definition = struct {
    label: []const u8,
    dest: []const u8 = "",
    title: []const u8 = "",
};

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    defs: std.ArrayList(Definition) = .empty,
};

pub fn build(a: Allocator, markdown: []const u8) Allocator.Error!Tree {
    var p: P = .{ .a = a };
    try p.nodes.append(a, .{ .kind = .document });
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw| {
        if (lines.peek() == null and raw.len == 0) break;
        try p.incorporate(std.mem.trimEnd(u8, raw, "\r"));
    }
    while (p.tip != none) try p.finalize(p.tip);
    return .{ .nodes = p.nodes, .defs = p.defs };
}

fn isSpaceOrTab(c: ?u8) bool {
    return c == ' ' or c == '\t';
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

const P = struct {
    a: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    defs: std.ArrayList(Definition) = .empty,
    tip: u32 = 0,
    oldtip: u32 = 0,
    last_matched: u32 = 0,
    all_closed: bool = true,
    line: []const u8 = "",
    line_no: usize = 0,
    offset: usize = 0,
    column: usize = 0,
    nns: usize = 0,
    nns_col: usize = 0,
    indent: usize = 0,
    indented: bool = false,
    blank: bool = false,
    partial_tab: bool = false,

    fn n(p: *P, i: u32) *Node {
        return &p.nodes.items[i];
    }

    fn peek(p: *const P, i: usize) ?u8 {
        return if (i < p.line.len) p.line[i] else null;
    }

    fn findNextNonspace(p: *P) void {
        var i = p.offset;
        var cols = p.column;
        while (i < p.line.len) {
            const c = p.line[i];
            if (c == ' ') {
                i += 1;
                cols += 1;
            } else if (c == '\t') {
                i += 1;
                cols += 4 - (cols % 4);
            } else break;
        }
        p.blank = i >= p.line.len;
        p.nns = i;
        p.nns_col = cols;
        p.indent = cols - p.column;
        p.indented = p.indent >= 4;
    }

    fn advanceNextNonspace(p: *P) void {
        p.offset = p.nns;
        p.column = p.nns_col;
        p.partial_tab = false;
    }

    fn advanceOffset(p: *P, count_in: usize, columns: bool) void {
        var count = count_in;
        while (count > 0 and p.offset < p.line.len) {
            if (p.line[p.offset] == '\t') {
                const to_tab = 4 - (p.column % 4);
                if (columns) {
                    p.partial_tab = to_tab > count;
                    const adv = @min(to_tab, count);
                    p.column += adv;
                    if (!p.partial_tab) p.offset += 1;
                    count -= adv;
                } else {
                    p.partial_tab = false;
                    p.column += to_tab;
                    p.offset += 1;
                    count -= 1;
                }
            } else {
                p.partial_tab = false;
                p.offset += 1;
                p.column += 1;
                count -= 1;
            }
        }
    }

    fn canContain(p: *P, parent: u32, kind: Kind) bool {
        return switch (p.n(parent).kind) {
            .document, .quote, .item, .footnote => kind != .item,
            .list => kind == .item,
            else => false,
        };
    }

    fn addChild(p: *P, kind: Kind) Allocator.Error!u32 {
        while (!p.canContain(p.tip, kind)) try p.finalize(p.tip);
        const idx: u32 = @intCast(p.nodes.items.len);
        try p.nodes.append(p.a, .{ .kind = kind, .parent = p.tip, .line = p.line_no });
        const parent = p.n(p.tip);
        if (parent.last != none) p.nodes.items[parent.last].next = idx else parent.first = idx;
        p.nodes.items[p.tip].last = idx;
        p.tip = idx;
        return idx;
    }

    fn unlink(p: *P, idx: u32) void {
        const parent = p.nodes.items[idx].parent;
        var prev: u32 = none;
        var cur = p.n(parent).first;
        while (cur != idx) : (cur = p.n(cur).next) prev = cur;
        const nxt = p.n(idx).next;
        if (prev == none) p.n(parent).first = nxt else p.n(prev).next = nxt;
        if (p.n(parent).last == idx) p.n(parent).last = prev;
    }

    fn addLine(p: *P) Allocator.Error!void {
        const t = p.n(p.tip);
        if (p.partial_tab) {
            p.offset += 1;
            const to_tab = 4 - (p.column % 4);
            try t.content.appendNTimes(p.a, ' ', to_tab);
        }
        try t.content.appendSlice(p.a, p.line[@min(p.offset, p.line.len)..]);
        try t.content.append(p.a, '\n');
    }

    fn closeUnmatched(p: *P) Allocator.Error!void {
        if (p.all_closed) return;
        while (p.oldtip != p.last_matched) {
            const parent = p.n(p.oldtip).parent;
            try p.finalize(p.oldtip);
            p.oldtip = parent;
        }
        p.all_closed = true;
    }

    fn endsWithBlankLine(p: *P, start: u32) bool {
        var b = start;
        while (b != none) {
            if (p.n(b).last_blank) return true;
            const k = p.n(b).kind;
            if (!p.n(b).last_checked and (k == .list or k == .item)) {
                p.n(b).last_checked = true;
                b = p.n(b).last;
            } else {
                p.n(b).last_checked = true;
                break;
            }
        }
        return false;
    }

    fn finalize(p: *P, idx: u32) Allocator.Error!void {
        const node = p.n(idx);
        node.open = false;
        p.tip = node.parent;
        switch (node.kind) {
            .paragraph => try p.takeDefinitions(idx),
            .code => {
                const c = &node.content;
                if (node.fenced) {
                    const nl = std.mem.indexOfScalar(u8, c.items, '\n') orelse c.items.len;
                    const info = std.mem.trim(u8, c.items[0..nl], " \t");
                    const info_copy = try p.a.dupe(u8, info);
                    const rest = if (nl < c.items.len) c.items[nl + 1 ..] else c.items[0..0];
                    const body = try p.a.dupe(u8, rest);
                    c.clearRetainingCapacity();
                    try c.appendSlice(p.a, info_copy);
                    try c.append(p.a, 0);
                    try c.appendSlice(p.a, body);
                } else {
                    var end = c.items.len;
                    while (end > 0) {
                        var s = end - 1;
                        if (c.items[s] != '\n') break;
                        while (s > 0 and c.items[s - 1] == ' ') s -= 1;
                        if (s > 0 and c.items[s - 1] == '\n') {
                            end = s;
                        } else if (s == 0) {
                            end = 0;
                        } else break;
                    }
                    c.shrinkRetainingCapacity(end);
                    if (end > 0 and c.items[end - 1] != '\n') try c.append(p.a, '\n');
                }
            },
            .list => {
                node.tight = true;
                var item = node.first;
                while (item != none) : (item = p.n(item).next) {
                    if (p.endsWithBlankLine(item) and p.n(item).next != none) {
                        p.n(idx).tight = false;
                        break;
                    }
                    var sub = p.n(item).first;
                    while (sub != none) : (sub = p.n(sub).next) {
                        if (p.endsWithBlankLine(sub) and (p.n(item).next != none or p.n(sub).next != none)) {
                            p.n(idx).tight = false;
                            break;
                        }
                    }
                    if (!p.n(idx).tight) break;
                }
            },
            else => {},
        }
    }

    fn takeDefinitions(p: *P, idx: u32) Allocator.Error!void {
        var content = p.n(idx).content.items;
        var consumed: usize = 0;
        while (consumed < content.len and content[consumed] == '[') {
            const used = try p.parseDefinition(content[consumed..]) orelse break;
            consumed += used;
        }
        if (consumed == 0) return;
        content = content[consumed..];
        const node = p.n(idx);
        std.mem.copyForwards(u8, node.content.items[0..content.len], content);
        node.content.shrinkRetainingCapacity(content.len);
        if (std.mem.trim(u8, content, " \t\r\n").len == 0 and node.open == false) p.unlink(idx);
    }

    fn parseDefinition(p: *P, s: []const u8) Allocator.Error!?usize {
        var i: usize = 1;
        const label_start = i;
        while (i < s.len and s[i] != ']') : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len) i += 1 else if (s[i] == '[') return null;
        }
        if (i >= s.len or i - label_start > 999) return null;
        const raw_label = s[label_start..i];
        if (std.mem.trim(u8, raw_label, " \t\r\n").len == 0) return null;
        i += 1;
        if (i >= s.len or s[i] != ':') return null;
        i += 1;
        const label = try normalizeLabel(p.a, raw_label);

        if (raw_label[0] == '^') return null;

        i = skipWs(s, i, true);
        // SAFETY: assigned in both destination branches before use
        var dest: []const u8 = undefined;
        if (i < s.len and s[i] == '<') {
            const st = i + 1;
            var j = st;
            while (j < s.len and s[j] != '>') : (j += 1) {
                if (s[j] == '\n' or s[j] == '<') return null;
                if (s[j] == '\\' and j + 1 < s.len) j += 1;
            }
            if (j >= s.len) return null;
            dest = s[st..j];
            i = j + 1;
        } else {
            const st = i;
            var depth: i32 = 0;
            while (i < s.len and s[i] > ' ' and s[i] != 0x7f) : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len and s[i + 1] > ' ') {
                    i += 1;
                } else if (s[i] == '(') {
                    depth += 1;
                } else if (s[i] == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            if (i == st or depth != 0) return null;
            dest = s[st..i];
        }

        const after_dest = i;
        const eol_after_dest = lineEnd(s, after_dest);
        var title: []const u8 = "";
        var end: ?usize = null;
        const j = skipWs(s, i, true);
        if (j < s.len and j > i and (s[j] == '"' or s[j] == '\'' or s[j] == '(')) {
            const close: u8 = if (s[j] == '(') ')' else s[j];
            var k = j + 1;
            while (k < s.len and s[k] != close) : (k += 1) {
                if (s[k] == '\\' and k + 1 < s.len) k += 1;
                if (s[k] == '\n' and k + 1 < s.len and isBlankLine(s[k + 1 ..])) break;
                if (s[k] == '(' and close == ')') break;
            }
            if (k < s.len and s[k] == close) {
                if (lineEnd(s, k + 1)) |e| {
                    title = s[j + 1 .. k];
                    end = e;
                }
            }
        }
        if (end == null) end = eol_after_dest;
        const e = end orelse return null;
        try p.defs.append(p.a, .{
            .label = label,
            .dest = try p.a.dupe(u8, dest),
            .title = try p.a.dupe(u8, title),
        });
        return e;
    }

    fn incorporate(p: *P, ln: []const u8) Allocator.Error!void {
        p.line = ln;
        p.line_no += 1;
        p.offset = 0;
        p.column = 0;
        p.blank = false;
        p.partial_tab = false;
        var all_matched = true;
        var container: u32 = 0;
        p.oldtip = p.tip;

        while (p.n(container).last != none and p.n(p.n(container).last).open) {
            container = p.n(container).last;
            p.findNextNonspace();
            switch (try p.cont(container)) {
                0 => {},
                1 => all_matched = false,
                else => return,
            }
            if (!all_matched) {
                container = p.n(container).parent;
                break;
            }
        }

        p.all_closed = container == p.oldtip;
        p.last_matched = container;
        var matched_leaf = p.n(container).kind != .paragraph and acceptsLines(p.n(container).kind);

        while (!matched_leaf) {
            p.findNextNonspace();
            if (!p.indented and !maybeSpecial(p.line[@min(p.nns, p.line.len)..])) {
                p.advanceNextNonspace();
                break;
            }
            const r = try p.starts(container);
            if (r == 0) {
                p.advanceNextNonspace();
                break;
            }
            container = p.tip;
            if (r == 2) matched_leaf = true;
        }

        if (!p.all_closed and !p.blank and p.n(p.tip).kind == .paragraph) {
            try p.addLine();
            return;
        }
        try p.closeUnmatched();
        if (p.blank and p.n(container).last != none) p.n(p.n(container).last).last_blank = true;
        const k = p.n(container).kind;
        const lastline_blank = p.blank and !(k == .quote or (k == .code and p.n(container).fenced) or
            (k == .item and p.n(container).first == none and p.n(container).line == p.line_no));
        var cur = container;
        while (cur != none) : (cur = p.n(cur).parent) p.n(cur).last_blank = lastline_blank;

        if (acceptsLines(k)) {
            try p.addLine();
            if (k == .html and p.n(container).html_type >= 1 and p.n(container).html_type <= 5 and
                htmlEnds(p.n(container).html_type, p.line[@min(p.offset, p.line.len)..]))
            {
                try p.finalize(container);
            }
        } else if (p.offset < p.line.len and !p.blank) {
            _ = try p.addChild(.paragraph);
            p.advanceNextNonspace();
            try p.addLine();
        }
    }

    fn cont(p: *P, c: u32) Allocator.Error!u8 {
        const node = p.n(c);
        switch (node.kind) {
            .document, .list => return 0,
            .quote => {
                if (!p.indented and p.peek(p.nns) == '>') {
                    p.advanceNextNonspace();
                    p.advanceOffset(1, false);
                    if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
                    return 0;
                }
                return 1;
            },
            .item => {
                if (p.blank) {
                    if (node.first == none) return 1;
                    p.advanceNextNonspace();
                } else if (p.indent >= node.marker_offset + node.padding) {
                    p.advanceOffset(node.marker_offset + node.padding, true);
                } else return 1;
                return 0;
            },
            .footnote => {
                if (p.blank) {
                    if (node.first == none) return 1;
                    p.advanceNextNonspace();
                } else if (p.indent >= 4) {
                    p.advanceOffset(4, true);
                } else return 1;
                return 0;
            },
            .heading, .thematic => return 1,
            .code => {
                if (node.fenced) {
                    if (p.indent <= 3 and p.peek(p.nns) == node.fence_char) {
                        const rest = p.line[p.nns..];
                        var m: usize = 0;
                        while (m < rest.len and rest[m] == node.fence_char) m += 1;
                        if (m >= node.fence_len and std.mem.trim(u8, rest[m..], " \t").len == 0) {
                            try p.finalize(c);
                            return 2;
                        }
                    }
                    var i = node.fence_offset;
                    while (i > 0 and isSpaceOrTab(p.peek(p.offset))) : (i -= 1) p.advanceOffset(1, true);
                } else {
                    if (p.indent >= 4) p.advanceOffset(4, true) else if (p.blank) p.advanceNextNonspace() else return 1;
                }
                return 0;
            },
            .html => return if (p.blank and (node.html_type == 6 or node.html_type == 7)) 1 else 0,
            .paragraph => return if (p.blank) 1 else 0,
        }
    }

    fn starts(p: *P, container: u32) Allocator.Error!u8 {
        const rest = p.line[p.nns..];
        if (!p.indented and rest.len > 0 and rest[0] == '>') {
            p.advanceNextNonspace();
            p.advanceOffset(1, false);
            if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
            try p.closeUnmatched();
            _ = try p.addChild(.quote);
            return 1;
        }
        if (!p.indented and rest.len > 0 and rest[0] == '#') {
            var m: usize = 0;
            while (m < rest.len and rest[m] == '#') m += 1;
            if (m <= 6 and (m == rest.len or rest[m] == ' ' or rest[m] == '\t')) {
                p.advanceNextNonspace();
                p.advanceOffset(m, false);
                try p.closeUnmatched();
                const h = try p.addChild(.heading);
                p.n(h).level = @intCast(m);
                var body = std.mem.trim(u8, p.line[@min(p.offset, p.line.len)..], " \t");
                var e = body.len;
                while (e > 0 and body[e - 1] == '#') e -= 1;
                if (e == 0) {
                    body = "";
                } else if (e < body.len and (body[e - 1] == ' ' or body[e - 1] == '\t')) {
                    body = std.mem.trimEnd(u8, body[0..e], " \t");
                }
                try p.n(h).content.appendSlice(p.a, body);
                p.advanceOffset(p.line.len - p.offset, false);
                return 2;
            }
        }
        if (!p.indented and rest.len >= 3 and (rest[0] == '`' or rest[0] == '~')) {
            var m: usize = 0;
            while (m < rest.len and rest[m] == rest[0]) m += 1;
            if (m >= 3 and (rest[0] == '~' or std.mem.indexOfScalar(u8, rest[m..], '`') == null)) {
                try p.closeUnmatched();
                const cb = try p.addChild(.code);
                const node = p.n(cb);
                node.fenced = true;
                node.fence_char = rest[0];
                node.fence_len = m;
                node.fence_offset = p.indent;
                p.advanceNextNonspace();
                p.advanceOffset(m, false);
                return 2;
            }
        }
        if (!p.indented and rest.len > 0 and rest[0] == '<') {
            const t = htmlStart(rest, p.n(container).kind == .paragraph);
            if (t != 0) {
                try p.closeUnmatched();
                const h = try p.addChild(.html);
                p.n(h).html_type = t;
                return 2;
            }
        }
        if (!p.indented and p.n(container).kind == .paragraph and rest.len > 0 and (rest[0] == '=' or rest[0] == '-')) {
            var m: usize = 0;
            while (m < rest.len and rest[m] == rest[0]) m += 1;
            if (std.mem.trim(u8, rest[m..], " \t").len == 0) {
                try p.closeUnmatched();
                try p.takeDefinitions(container);
                if (p.n(container).content.items.len > 0) {
                    const par = p.n(container);
                    par.kind = .heading;
                    par.level = if (rest[0] == '=') 1 else 2;
                    par.open = false;
                    while (par.content.items.len > 0 and par.content.items[par.content.items.len - 1] == '\n')
                        par.content.shrinkRetainingCapacity(par.content.items.len - 1);
                    p.tip = par.parent;
                    p.advanceOffset(p.line.len - p.offset, false);
                    return 2;
                }
            }
        }
        if (!p.indented and isThematic(rest)) {
            try p.closeUnmatched();
            _ = try p.addChild(.thematic);
            p.n(p.tip).open = false;
            p.tip = p.n(p.tip).parent;
            p.advanceOffset(p.line.len - p.offset, false);
            return 2;
        }
        if (!p.indented and p.n(container).kind != .paragraph and try p.footnoteStart(rest)) return 1;
        if (!p.indented or p.n(container).kind == .list) {
            if (try p.listStart(container)) return 1;
        }
        if (p.indented and p.n(p.tip).kind != .paragraph and !p.blank) {
            p.advanceOffset(4, true);
            try p.closeUnmatched();
            _ = try p.addChild(.code);
            return 2;
        }
        return 0;
    }

    fn footnoteStart(p: *P, rest: []const u8) Allocator.Error!bool {
        if (rest.len < 5 or rest[0] != '[' or rest[1] != '^') return false;
        var i: usize = 2;
        while (i < rest.len and rest[i] != ']' and rest[i] != ' ' and rest[i] != '\t') i += 1;
        if (i == 2 or i + 1 >= rest.len or rest[i] != ']' or rest[i + 1] != ':') return false;
        const label = try normalizeLabel(p.a, rest[2..i]);
        p.advanceNextNonspace();
        p.advanceOffset(i + 2, false);
        if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
        try p.closeUnmatched();
        const f = try p.addChild(.footnote);
        p.n(f).label = label;
        return true;
    }

    fn listStart(p: *P, container: u32) Allocator.Error!bool {
        if (p.indent >= 4) return false;
        const rest = p.line[p.nns..];
        if (rest.len == 0) return false;
        var mlen: usize = 0;
        var ordered = false;
        var delim: u8 = 0;
        var bullet: u8 = 0;
        var start: u32 = 0;
        if (rest[0] == '*' or rest[0] == '+' or rest[0] == '-') {
            mlen = 1;
            bullet = rest[0];
        } else {
            var d: usize = 0;
            while (d < rest.len and d < 9 and std.ascii.isDigit(rest[d])) d += 1;
            if (d == 0 or d >= rest.len or (rest[d] != '.' and rest[d] != ')')) return false;
            start = std.fmt.parseInt(u32, rest[0..d], 10) catch return false;
            if (p.n(container).kind == .paragraph and start != 1) return false;
            ordered = true;
            delim = rest[d];
            mlen = d + 1;
        }
        if (mlen < rest.len and rest[mlen] != ' ' and rest[mlen] != '\t') return false;
        const marker_blank = std.mem.trim(u8, rest[mlen..], " \t").len == 0;
        if (p.n(container).kind == .paragraph and marker_blank) return false;

        const marker_offset = p.indent;
        p.advanceNextNonspace();
        p.advanceOffset(mlen, true);
        const sp_col = p.column;
        const sp_off = p.offset;
        while (true) {
            p.advanceOffset(1, true);
            if (!(p.column - sp_col < 5 and isSpaceOrTab(p.peek(p.offset)))) break;
        }
        const blank_item = p.peek(p.offset) == null;
        const after = p.column - sp_col;
        // SAFETY: assigned in both branches below
        var padding: usize = undefined;
        if (after >= 5 or after < 1 or blank_item) {
            padding = mlen + 1;
            p.column = sp_col;
            p.offset = sp_off;
            if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
        } else padding = mlen + after;

        try p.closeUnmatched();
        const tipn = p.n(p.tip);
        const need_list = tipn.kind != .list or tipn.ordered != ordered or tipn.delim != delim or tipn.bullet != bullet;
        if (need_list) {
            const l = try p.addChild(.list);
            const ln = p.n(l);
            ln.ordered = ordered;
            ln.delim = delim;
            ln.bullet = bullet;
            ln.start = start;
        }
        const it = try p.addChild(.item);
        const inode = p.n(it);
        inode.padding = padding;
        inode.marker_offset = marker_offset;
        inode.ordered = ordered;
        inode.start = start;
        return true;
    }
};

fn acceptsLines(k: Kind) bool {
    return k == .paragraph or k == .code or k == .html;
}

fn maybeSpecial(s: []const u8) bool {
    if (s.len == 0) return false;
    return switch (s[0]) {
        '#', '`', '~', '*', '+', '_', '=', '<', '>', '-', '[' => true,
        '0'...'9' => true,
        else => false,
    };
}

fn isThematic(s: []const u8) bool {
    if (s.len == 0 or (s[0] != '*' and s[0] != '-' and s[0] != '_')) return false;
    var count: usize = 0;
    for (s) |c| {
        if (c == s[0]) count += 1 else if (c != ' ' and c != '\t') return false;
    }
    return count >= 3;
}

fn isBlankLine(s: []const u8) bool {
    const e = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return std.mem.trim(u8, s[0..e], " \t\r").len == 0;
}

fn skipWs(s: []const u8, from: usize, one_newline: bool) usize {
    var i = from;
    var nl = false;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n') {
            if (!one_newline or nl) break;
            nl = true;
        } else if (s[i] != ' ' and s[i] != '\t') break;
    }
    return i;
}

/// Index just past the line holding `from` when only blanks follow on it.
fn lineEnd(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i >= s.len) return s.len;
    if (s[i] == '\n') return i + 1;
    return null;
}

fn normalizeLabel(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            pending_space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (pending_space) try out.append(a, ' ');
        pending_space = false;
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const cp = if (i + len <= raw.len) std.unicode.utf8Decode(raw[i..][0..len]) catch null else null;
        if (cp == null) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        var buf: [3]u21 = undefined;
        for (buf[0..unicode.fold(cp.?, &buf)]) |f| {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(f, &enc) catch continue;
            try out.appendSlice(a, enc[0..n]);
        }
        i += len;
    }
    return out.items;
}

const block_tags = [_][]const u8{
    "address",  "article", "aside",    "base",     "basefont", "blockquote", "body",     "caption",
    "center",   "col",     "colgroup", "dd",       "details",  "dialog",     "dir",      "div",
    "dl",       "dt",      "fieldset", "figcaption", "figure", "footer",     "form",     "frame",
    "frameset", "h1",      "h2",       "h3",       "h4",       "h5",         "h6",       "head",
    "header",   "hr",      "html",     "iframe",   "legend",   "li",         "link",     "main",
    "menu",     "menuitem", "nav",     "noframes", "ol",       "optgroup",   "option",   "p",
    "param",    "section", "source",   "summary",  "table",    "tbody",      "td",       "tfoot",
    "th",       "thead",   "title",    "tr",       "track",    "ul",
};

fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn htmlStart(s: []const u8, in_paragraph: bool) u8 {
    for ([_][]const u8{ "script", "pre", "style", "textarea" }) |name| {
        if (s.len > name.len and s[1 + 0] != '/' and startsWithNoCase(s[1..], name)) {
            const after = if (s.len > 1 + name.len) s[1 + name.len] else '\n';
            if (after == ' ' or after == '\t' or after == '>' or after == '\n') return 1;
        }
    }
    if (std.mem.startsWith(u8, s, "<!--")) return 2;
    if (std.mem.startsWith(u8, s, "<?")) return 3;
    if (std.mem.startsWith(u8, s, "<![CDATA[")) return 5;
    if (s.len > 2 and s[1] == '!' and isAlpha(s[2])) return 4;

    var i: usize = 1;
    if (i < s.len and s[i] == '/') i += 1;
    const name_start = i;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    if (i > name_start) {
        const name = s[name_start..i];
        for (block_tags) |bt| {
            if (std.ascii.eqlIgnoreCase(name, bt)) {
                if (i >= s.len or s[i] == ' ' or s[i] == '\t' or s[i] == '>' or std.mem.startsWith(u8, s[i..], "/>")) return 6;
            }
        }
    }
    if (!in_paragraph and completeTagLine(s)) return 7;
    return 0;
}

fn completeTagLine(s: []const u8) bool {
    var i: usize = 1;
    const closing = i < s.len and s[i] == '/';
    if (closing) i += 1;
    if (i >= s.len or !isAlpha(s[i])) return false;
    const ns = i;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    const name = s[ns..i];
    for ([_][]const u8{ "script", "style", "pre", "textarea" }) |bad| if (std.ascii.eqlIgnoreCase(name, bad)) return false;
    if (closing) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len or s[i] != '>') return false;
        i += 1;
    } else {
        while (true) {
            const ws = i;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
            if (i >= s.len) return false;
            if (s[i] == '>') {
                i += 1;
                break;
            }
            if (s[i] == '/') {
                if (i + 1 < s.len and s[i + 1] == '>') {
                    i += 2;
                    break;
                }
                return false;
            }
            if (i == ws) return false;
            if (!(isAlpha(s[i]) or s[i] == '_' or s[i] == ':')) return false;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == ':' or s[i] == '.' or s[i] == '-')) i += 1;
            var j = i;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            if (j < s.len and s[j] == '=') {
                j += 1;
                while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
                if (j >= s.len) return false;
                if (s[j] == '"' or s[j] == '\'') {
                    const q = s[j];
                    const e = std.mem.indexOfScalarPos(u8, s, j + 1, q) orelse return false;
                    i = e + 1;
                } else {
                    const vs = j;
                    while (j < s.len and std.mem.indexOfScalar(u8, " \t\"'=<>`", s[j]) == null) j += 1;
                    if (j == vs) return false;
                    i = j;
                }
            }
        }
    }
    return std.mem.trim(u8, s[i..], " \t").len == 0;
}

fn htmlEnds(t: u8, s: []const u8) bool {
    switch (t) {
        1 => {
            for ([_][]const u8{ "</script>", "</pre>", "</style>", "</textarea>" }) |e| {
                var i: usize = 0;
                while (i + e.len <= s.len) : (i += 1) if (std.ascii.eqlIgnoreCase(s[i .. i + e.len], e)) return true;
            }
            return false;
        },
        2 => return std.mem.indexOf(u8, s, "-->") != null,
        3 => return std.mem.indexOf(u8, s, "?>") != null,
        4 => return std.mem.indexOfScalar(u8, s, '>') != null,
        5 => return std.mem.indexOf(u8, s, "]]>") != null,
        else => return false,
    }
}
