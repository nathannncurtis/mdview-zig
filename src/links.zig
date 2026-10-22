const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const entities = @import("entities.zig");

pub const Link = struct {
    start: u32,
    len: u32,
    target: []const u8,
    title: []const u8 = "",
};

pub const Image = Link;

pub const Def = struct { dest: []const u8, title: []const u8 };

pub const Note = struct { label: []const u8, node: u32, refs: u32 = 0 };

/// Link reference definitions and footnotes, keyed by normalized label.
pub const Refs = struct {
    a: Allocator,
    defs: std.StringHashMapUnmanaged(Def) = .empty,
    notes: std.StringHashMapUnmanaged(u32) = .empty,
    order: std.ArrayList(Note) = .empty,
    key: std.ArrayList(u8) = .empty,
    frozen: bool = false,

    pub fn init(a: Allocator) Refs {
        return .{ .a = a };
    }

    pub fn addDef(r: *Refs, label: []const u8, def: Def) Allocator.Error!void {
        const slot = try r.defs.getOrPut(r.a, label);
        if (!slot.found_existing) slot.value_ptr.* = def;
    }

    pub fn lookup(r: *Refs, label: []const u8) ?Def {
        const k = normalizeLabel(&r.key, r.a, label) catch return null;
        return r.defs.get(k);
    }

    pub fn addNote(r: *Refs, label: []const u8, node: u32) Allocator.Error!void {
        const slot = try r.notes.getOrPut(r.a, label);
        if (!slot.found_existing) slot.value_ptr.* = node;
    }

    /// Fixes the numbering and back-reference counts found by an earlier pass over the same document.
    pub fn seed(r: *Refs, earlier: []const Note) Allocator.Error!void {
        for (earlier) |n| {
            const node = r.notes.get(n.label) orelse continue;
            try r.order.append(r.a, .{ .label = n.label, .node = node, .refs = n.refs });
        }
        r.frozen = true;
    }

    pub fn noteRef(r: *Refs, label: []const u8) Allocator.Error!?u32 {
        const k = normalizeLabel(&r.key, r.a, label) catch return null;
        const node = r.notes.get(k) orelse return null;
        for (r.order.items, 1..) |*n, number| {
            if (std.mem.eql(u8, n.label, k)) {
                if (!r.frozen) n.refs += 1;
                return @intCast(number);
            }
        }
        if (r.frozen) return null;
        try r.order.append(r.a, .{ .label = try r.a.dupe(u8, k), .node = node, .refs = 1 });
        return @intCast(r.order.items.len);
    }
};

fn isPunct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn appendCodepoints(list: *std.ArrayList(u8), a: Allocator, cps: []const u21) Allocator.Error!void {
    for (cps) |cp| {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        try list.appendSlice(a, buf[0..len]);
    }
}

fn foldInto(list: *std.ArrayList(u8), a: Allocator, cp: u21) Allocator.Error!void {
    var out: [unicode.max_mapping_len]u21 = undefined;
    try appendCodepoints(list, a, out[0..unicode.fold(cp, &out)]);
}

pub fn normalizeLabel(list: *std.ArrayList(u8), a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    list.clearRetainingCapacity();
    var pending_space = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (isSpace(c)) {
            pending_space = list.items.len > 0;
            i += 1;
            continue;
        }
        if (pending_space) try list.append(a, ' ');
        pending_space = false;
        if (c < 0x80) {
            try list.append(a, std.ascii.toLower(c));
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + n <= raw.len) {
            if (std.unicode.utf8Decode(raw[i..][0..n])) |cp| {
                try foldInto(list, a, cp);
                i += n;
                continue;
            } else |_| {}
        }
        try list.append(a, c);
        i += 1;
    }
    return list.items;
}

pub fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\\&") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isPunct(s[i + 1])) {
            try out.append(a, s[i + 1]);
            i += 2;
            continue;
        }
        if (c == '&') {
            if (entityAt(s, i)) |e| {
                try out.appendSlice(a, e.text());
                i = e.end;
                continue;
            }
        }
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

const Entity = struct {
    end: usize,
    buf: [4]u8,
    len: usize,
    name: ?[]const u8,

    fn text(e: *const Entity) []const u8 {
        return e.name orelse e.buf[0..e.len];
    }
};

fn entityAt(s: []const u8, i: usize) ?Entity {
    const semi = std.mem.indexOfScalarPos(u8, s, i, ';') orelse return null;
    const body = s[i + 1 .. semi];
    if (body.len == 0 or body.len > 32) return null;
    if (body[0] == '#') {
        const hex = body.len > 1 and (body[1] == 'x' or body[1] == 'X');
        const digits = body[if (hex) 2 else 1..];
        if (digits.len == 0 or digits.len > 7) return null;
        const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
        var e: Entity = .{ .end = semi + 1, .buf = undefined, .len = 0, .name = null };
        const v: u21 = if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp < 0xE000)) 0xFFFD else cp;
        e.len = std.unicode.utf8Encode(v, &e.buf) catch return null;
        return e;
    }
    const name = entities.lookup(body) orelse return null;
    return .{ .end = semi + 1, .buf = undefined, .len = 0, .name = name };
}

const Dest = struct { raw: []const u8, end: usize };

fn parseDest(s: []const u8, i: usize) ?Dest {
    if (i >= s.len) return null;
    if (s[i] == '<') {
        var j = i + 1;
        while (j < s.len) : (j += 1) {
            switch (s[j]) {
                '\\' => if (j + 1 < s.len and isPunct(s[j + 1])) {
                    j += 1;
                },
                '\n', '<' => return null,
                '>' => return .{ .raw = s[i + 1 .. j], .end = j + 1 },
                else => {},
            }
        }
        return null;
    }
    var j = i;
    var depth: usize = 0;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (c == '\\' and j + 1 < s.len and isPunct(s[j + 1])) {
            j += 1;
        } else if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        } else if (c <= ' ' or c == 0x7F) break;
    }
    if (depth != 0) return null;
    return .{ .raw = s[i..j], .end = j };
}

fn parseTitle(s: []const u8, i: usize) ?Dest {
    if (i >= s.len) return null;
    const close: u8 = switch (s[i]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var j = i + 1;
    var line_has_text = true;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (c == '\\' and j + 1 < s.len and isPunct(s[j + 1])) {
            j += 1;
            line_has_text = true;
        } else if (c == close) {
            return .{ .raw = s[i + 1 .. j], .end = j + 1 };
        } else if (c == '(' and close == ')') {
            return null;
        } else if (c == '\n') {
            if (!line_has_text) return null;
            line_has_text = false;
        } else if (c != ' ' and c != '\t' and c != '\r') line_has_text = true;
    }
    return null;
}

fn skipWs(s: []const u8, i: usize) ?usize {
    var j = i;
    var nl: u8 = 0;
    while (j < s.len) : (j += 1) {
        switch (s[j]) {
            ' ', '\t', '\r' => {},
            '\n' => {
                nl += 1;
                if (nl > 1) return null;
            },
            else => break,
        }
    }
    return j;
}

pub const Resolved = struct { end: usize, dest: []const u8, title: []const u8 };

pub fn matchInline(a: Allocator, s: []const u8, i: usize) Allocator.Error!?Resolved {
    if (i >= s.len or s[i] != '(') return null;
    var j = skipWs(s, i + 1) orelse return null;
    var dest: []const u8 = "";
    if (j < s.len and s[j] != ')') {
        const d = parseDest(s, j) orelse return null;
        if (d.raw.len == 0 and s[j] != '<') return null;
        dest = d.raw;
        j = d.end;
    }
    var title: []const u8 = "";
    const after_dest = j;
    j = skipWs(s, j) orelse return null;
    if (j > after_dest and j < s.len and s[j] != ')') {
        const t = parseTitle(s, j) orelse return null;
        title = t.raw;
        j = skipWs(s, t.end) orelse return null;
    }
    if (j >= s.len or s[j] != ')') return null;
    return .{ .end = j + 1, .dest = try unescape(a, dest), .title = try unescape(a, title) };
}

const Label = struct { raw: []const u8, end: usize };

fn parseLabel(s: []const u8, i: usize) ?Label {
    if (i >= s.len or s[i] != '[') return null;
    var j = i + 1;
    var text = false;
    while (j < s.len) : (j += 1) {
        switch (s[j]) {
            '\\' => if (j + 1 < s.len and isPunct(s[j + 1])) {
                j += 1;
                text = true;
            } else {
                text = true;
            },
            '[' => return null,
            ']' => {
                if (!text or j - i - 1 > 999) return null;
                return .{ .raw = s[i + 1 .. j], .end = j + 1 };
            },
            ' ', '\t', '\n', '\r' => {},
            else => text = true,
        }
    }
    return null;
}

pub fn matchReference(a: Allocator, refs: *Refs, s: []const u8, open: usize, close: usize) Allocator.Error!?Resolved {
    const text = s[open + 1 .. close];
    var end = close + 1;
    var label = text;
    if (end < s.len and s[end] == '[') {
        if (end + 1 < s.len and s[end + 1] == ']') {
            end += 2;
        } else if (parseLabel(s, end)) |l| {
            label = l.raw;
            end = l.end;
        }
    }
    const def = refs.lookup(label) orelse return null;
    return .{ .end = end, .dest = try unescape(a, def.dest), .title = try unescape(a, def.title) };
}

pub fn findClose(s: []const u8, open: usize) ?usize {
    var depth: usize = 1;
    var i = open + 1;
    while (i < s.len) {
        switch (s[i]) {
            '\\' => i += 2,
            '`' => {
                var n: usize = 0;
                while (i + n < s.len and s[i + n] == '`') n += 1;
                var j = i + n;
                var found: ?usize = null;
                while (j < s.len) {
                    if (s[j] != '`') {
                        j += 1;
                        continue;
                    }
                    var m: usize = 0;
                    while (j + m < s.len and s[j + m] == '`') m += 1;
                    if (m == n) {
                        found = j + m;
                        break;
                    }
                    j += m;
                }
                i = found orelse i + n;
            },
            '<' => i = if (autolink(s, i)) |al| al.end else i + 1,
            '[' => {
                depth += 1;
                i += 1;
            },
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

pub fn hasLink(a: Allocator, refs: *Refs, s: []const u8) Allocator.Error!bool {
    var i: usize = 0;
    while (i < s.len) {
        switch (s[i]) {
            '\\' => i += 2,
            '`' => {
                var n: usize = 0;
                while (i + n < s.len and s[i + n] == '`') n += 1;
                i = if (std.mem.indexOfPos(u8, s, i + n, s[i..][0..n])) |e| e + n else i + n;
            },
            '<' => {
                if (autolink(s, i) != null) return true;
                i += 1;
            },
            '[' => {
                const close = findClose(s, i) orelse {
                    i += 1;
                    continue;
                };
                const is_image = i > 0 and s[i - 1] == '!';
                const m = (try matchInline(a, s, close + 1)) orelse try matchReference(a, refs, s, i, close);
                if (m != null and !is_image) return true;
                i += 1;
            },
            else => i += 1,
        }
    }
    return false;
}

pub const Auto = struct { end: usize, text: []const u8, target: []const u8, prefix_mailto: bool = false };

pub fn autolink(s: []const u8, i: usize) ?Auto {
    if (i >= s.len or s[i] != '<') return null;
    const close = std.mem.indexOfScalarPos(u8, s, i + 1, '>') orelse return null;
    const body = s[i + 1 .. close];
    if (body.len == 0) return null;
    for (body) |c| if (c <= ' ' or c == 0x7F or c == '<') return null;

    if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
        if (colon >= 2 and colon <= 32 and std.ascii.isAlphabetic(body[0])) {
            var ok = true;
            for (body[1..colon]) |c| if (!isAlnum(c) and c != '+' and c != '.' and c != '-') {
                ok = false;
            };
            if (ok) return .{ .end = close + 1, .text = body, .target = body };
        }
    }
    if (isAngleEmail(body)) return .{ .end = close + 1, .text = body, .target = body, .prefix_mailto = true };
    return null;
}

fn isAngleEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0) return false;
    for (s[0..at]) |c| {
        if (!isAlnum(c) and std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) == null) return false;
    }
    const domain = s[at + 1 ..];
    if (domain.len == 0) return false;
    var parts = std.mem.splitScalar(u8, domain, '.');
    while (parts.next()) |p| {
        if (p.len == 0 or p.len > 63 or p[0] == '-' or p[p.len - 1] == '-') return false;
        for (p) |c| if (!isAlnum(c) and c != '-') return false;
    }
    return true;
}

fn checkDomain(s: []const u8, allow_short: bool) usize {
    var i: usize = 1;
    var dots: usize = 0;
    var us1: usize = 0;
    var us2: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 2 < s.len) i += 1;
        const c = s[i];
        if (c == '_') {
            us2 += 1;
        } else if (c == '.') {
            us1 = us2;
            us2 = 0;
            dots += 1;
        } else if (!isAlnum(c) and c != '-') break;
    }
    if (us1 > 0 or us2 > 0) return 0;
    if (allow_short) return i;
    return if (dots > 0) i else 0;
}

fn trimTrailing(s: []const u8, end_in: usize) usize {
    var end = end_in;
    if (std.mem.indexOfScalar(u8, s[0..end], '<')) |lt| end = lt;
    while (end > 0) {
        const c = s[end - 1];
        if (std.mem.indexOfScalar(u8, "?!.,:*_~'\"", c) != null) {
            end -= 1;
        } else if (c == ';') {
            var k = end - 1;
            while (k > 0 and std.ascii.isAlphanumeric(s[k - 1])) k -= 1;
            if (k > 0 and s[k - 1] == '&' and k < end - 1) end = k - 1 else end -= 1;
        } else if (c == ')') {
            var open: usize = 0;
            var closed: usize = 0;
            for (s[0..end]) |ch| {
                if (ch == '(') open += 1;
                if (ch == ')') closed += 1;
            }
            if (closed <= open) break;
            end -= 1;
        } else break;
    }
    return end;
}

fn isLocalChar(c: u8) bool {
    return isAlnum(c) or c == '.' or c == '+' or c == '-' or c == '_';
}

fn emailEnd(s: []const u8) ?usize {
    var local: usize = 0;
    while (local < s.len and isLocalChar(s[local])) local += 1;
    if (local == 0 or local >= s.len or s[local] != '@') return null;
    var end = local + 1;
    var dots: usize = 0;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (isAlnum(c)) continue;
        if (c == '.' and end + 1 < s.len and isAlnum(s[end + 1])) {
            dots += 1;
        } else if (c != '-' and c != '_') break;
    }
    if (dots == 0 or (!std.ascii.isAlphabetic(s[end - 1]) and s[end - 1] != '.')) return null;
    return trimTrailing(s, end);
}

pub fn extendedAutolink(a: Allocator, s: []const u8, i: usize) Allocator.Error!?Auto {
    if (i >= s.len) return null;
    const url_boundary = i == 0 or isSpace(s[i - 1]) or std.mem.indexOfScalar(u8, "*_~(", s[i - 1]) != null;
    const rest = s[i..];
    if (!url_boundary) {
        if (isLocalChar(rest[0]) and !isLocalChar(s[i - 1])) return emailAt(s, i);
        return null;
    }
    const schemes = [_][]const u8{ "http://", "https://", "ftp://" };
    for (schemes) |sc| {
        if (rest.len > sc.len and std.ascii.startsWithIgnoreCase(rest, sc)) {
            const d = checkDomain(rest[sc.len - 1 ..], true);
            if (d == 0) return null;
            return urlRange(a, i, rest, sc.len - 1 + d, "");
        }
    }
    if (std.ascii.startsWithIgnoreCase(rest, "www.")) {
        const d = checkDomain(rest, false);
        if (d == 0) return null;
        return urlRange(a, i, rest, d, "http://");
    }
    const prefixes = [_][]const u8{ "mailto:", "xmpp:" };
    for (prefixes) |pre| {
        if (std.ascii.startsWithIgnoreCase(rest, pre)) {
            const e = emailEnd(rest[pre.len..]) orelse return null;
            var end = pre.len + e;
            if (pre.len == 5 and end < rest.len and rest[end] == '/') {
                var k = end + 1;
                while (k < rest.len and (isAlnum(rest[k]) or rest[k] == '@' or rest[k] == '.' or rest[k] == '/')) k += 1;
                end = trimTrailing(rest, k);
            }
            return .{ .end = i + end, .text = rest[0..end], .target = rest[0..end] };
        }
    }
    if (isLocalChar(rest[0]) and (i == 0 or !isLocalChar(s[i - 1]))) return emailAt(s, i);
    return null;
}

fn emailAt(s: []const u8, i: usize) ?Auto {
    const rest = s[i..];
    var j: usize = 0;
    while (j < rest.len and isLocalChar(rest[j])) j += 1;
    if (j >= rest.len or rest[j] != '@') return null;
    const e = emailEnd(rest) orelse return null;
    return .{ .end = i + e, .text = rest[0..e], .target = rest[0..e], .prefix_mailto = true };
}

fn urlRange(a: Allocator, base: usize, rest: []const u8, domain_end: usize, prefix: []const u8) Allocator.Error!?Auto {
    var end = domain_end;
    while (end < rest.len and !isSpace(rest[end]) and rest[end] != '<') end += 1;
    end = trimTrailing(rest, end);
    if (end == 0) return null;
    const target = if (prefix.len == 0) rest[0..end] else try std.mem.concat(a, u8, &.{ prefix, rest[0..end] });
    return .{ .end = base + end, .text = rest[0..end], .target = target };
}

const href_safe = "-_.+!*'(),%#@?=;:/,+&$~";

pub fn encodeUrl(a: Allocator, url: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (url) |c| {
        if (isAlnum(c) or std.mem.indexOfScalar(u8, href_safe, c) != null) {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

pub const Action = union(enum) {
    external: []const u8,
    anchor: []const u8,
    file: []const u8,
    local: []const u8,
    blocked,
};

const openable_ext = [_][]const u8{
    "txt", "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "csv", "tsv", "json", "xml",
    "yaml", "yml", "log", "rtf", "docx", "xlsx", "pptx", "odt", "ods", "odp",
};

fn isMarkdownPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".md") or std.ascii.endsWithIgnoreCase(path, ".markdown");
}

fn isOpenableFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    for (openable_ext) |o| if (std.ascii.eqlIgnoreCase(ext[1..], o)) return true;
    return false;
}

fn stripQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfAny(u8, target, "?#") orelse target.len];
}

/// Decides what a click on `target` may do. Nothing it returns is ever run through a shell.
pub fn classify(target: []const u8) Action {
    if (target.len == 0 or target.len > 8192) return .blocked;
    for (target) |c| if (c < ' ' or c == 0x7F) return .blocked;
    if (target[0] == '#') return .{ .anchor = target[1..] };

    var scheme_end: ?usize = null;
    for (target, 0..) |c, k| {
        if (c == ':') {
            scheme_end = k;
            break;
        }
        if (!(isAlnum(c) or c == '+' or c == '-' or c == '.')) break;
    }
    if (scheme_end) |e| {
        const scheme = target[0..e];
        if (e == 0 or !std.ascii.isAlphabetic(target[0])) return .blocked;
        if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "mailto")) {
            return .{ .external = target };
        }
        if (std.ascii.eqlIgnoreCase(scheme, "file")) {
            const path = stripQuery(target[e + 1 ..]);
            if (isMarkdownPath(path)) return .{ .file = target };
            if (isOpenableFile(path)) return .{ .external = target };
        }
        return .blocked;
    }
    if (target[0] == '/' or target[0] == '\\') return .blocked;
    if (isMarkdownPath(stripQuery(target))) return .{ .file = target };
    if (isOpenableFile(stripQuery(target))) return .{ .local = target };
    return .blocked;
}

fn connectorPunctuation(cp: u21) bool {
    return cp == '_' or cp == 0x203F or cp == 0x2040 or cp == 0x2054 or cp == 0xFE33 or cp == 0xFE34 or
        (cp >= 0xFE4D and cp <= 0xFE4F) or cp == 0xFF3F;
}

/// GitHub's heading id: lowercase, keep letters, marks, numbers, `-` and `_`, spaces become hyphens.
pub fn slugInto(list: *std.ArrayList(u8), a: Allocator, text: []const u8) Allocator.Error!void {
    list.clearRetainingCapacity();
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    var prev_cased = false;
    while (it.nextCodepoint()) |cp| {
        defer prev_cased = unicode.isLetter(cp);
        if (cp == ' ') {
            try list.append(a, '-');
            continue;
        }
        var out: [unicode.max_mapping_len]u21 = undefined;
        var n = unicode.lower(cp, &out);
        if (cp == 0x3A3 and prev_cased and !unicode.isLetter(nextCodepoint(&it))) {
            out[0] = 0x3C2;
            n = 1;
        }
        for (out[0..n]) |x| {
            if (x == '-' or unicode.isLetter(x) or unicode.isMark(x) or unicode.isNumber(x) or connectorPunctuation(x)) {
                try appendCodepoints(list, a, &.{x});
            }
        }
    }
}

fn nextCodepoint(it: *std.unicode.Utf8Iterator) u21 {
    var copy = it.*;
    return copy.nextCodepoint() orelse 0;
}

pub fn percentDecode(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len + 0 and i + 2 <= s.len - 1 + 0) {
            if (std.fmt.parseInt(u8, s[i + 1 ..][0..2], 16)) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

const testing = std.testing;

test "classify allows only safe targets" {
    try testing.expect(classify("https://a.b/c").external.len > 0);
    try testing.expect(classify("HTTP://a.b") == .external);
    try testing.expect(classify("mailto:a@b.c") == .external);
    try testing.expectEqualStrings("intro", classify("#intro").anchor);
    try testing.expectEqualStrings("docs/a.md#x", classify("docs/a.md#x").file);
    try testing.expect(classify("file:///home/me/notes.md?x#y") == .file);
    try testing.expect(classify("file:///home/me/archive.xyz") == .blocked);
    try testing.expect(classify("docs/readme.txt") == .local);
    try testing.expect(classify("docs/setup.exe") == .blocked);
    try testing.expect(classify("../run.bat?x") == .blocked);
    try testing.expect(classify("img/a.PNG#x") == .local);
    try testing.expect(classify("javascript:alert(1)") == .blocked);
    try testing.expect(classify("JaVaScRiPt:alert(1)") == .blocked);
    try testing.expect(classify("data:text/html,x") == .blocked);
    try testing.expect(classify("vbscript:x") == .blocked);
    try testing.expect(classify("file:///c:/tools/run.exe") == .blocked);
    try testing.expect(classify("file:///c:/tools/run.BAT") == .blocked);
    try testing.expect(classify("file:///home/me/notes.md") == .file);
    try testing.expect(classify("file:///home/me/doc.pdf") == .external);
    try testing.expect(classify("C:/Windows/system32/cmd.exe") == .blocked);
    try testing.expect(classify("/etc/passwd") == .blocked);
    try testing.expect(classify("run.exe") == .blocked);
    try testing.expect(classify("") == .blocked);
    try testing.expect(classify("https://a.b/\x01") == .blocked);
}

test "heading slugs follow GitHub" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try slugInto(&list, testing.allocator, "Hello, World! It's 2nd_try - ok");
    try testing.expectEqualStrings("hello-world-its-2nd_try---ok", list.items);
    try slugInto(&list, testing.allocator, "Caf\u{c9} \u{1f600} Br\u{fc}cke");
    try testing.expectEqualStrings("caf\u{e9}--br\u{fc}cke", list.items);
    try slugInto(&list, testing.allocator, "\u{391}\u{3A3} \u{130} \u{4E2D}\u{6587} a\u{203F}b \u{2014} ~x");
    try testing.expectEqualStrings("\u{3B1}\u{3C2}-i\u{307}-\u{4E2D}\u{6587}-a\u{203F}b--x", list.items);
}

test "label normalisation folds case and whitespace" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try testing.expectEqualStrings("foo bar", try normalizeLabel(&list, testing.allocator, "  Foo \n\t BAR "));
    try testing.expectEqualStrings("ss", try normalizeLabel(&list, testing.allocator, "\u{1e9e}"));
    try testing.expectEqualStrings("\u{442}\u{43e}\u{43b}", try normalizeLabel(&list, testing.allocator, "\u{422}\u{41e}\u{41b}"));
}

test "extended autolinks trim trailing punctuation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t1 = "www.commonmark.org/a.b.";
    try testing.expectEqualStrings("www.commonmark.org/a.b", t1[0 .. (try extendedAutolink(a, t1, 0)).?.end]);
    const t2 = "http://x.org/a_(b))";
    try testing.expectEqualStrings("http://x.org/a_(b)", t2[0 .. (try extendedAutolink(a, t2, 0)).?.end]);
    const t3 = "www.a.org/q?a=1&amp;";
    try testing.expectEqualStrings("www.a.org/q?a=1", t3[0 .. (try extendedAutolink(a, t3, 0)).?.end]);
    try testing.expect((try extendedAutolink(a, "www.a_b.org", 0)) == null);
    try testing.expect((try extendedAutolink(a, "xwww.a.org", 1)) == null);
    const t4 = "(www.a.org)";
    try testing.expectEqualStrings("www.a.org", t4[1 .. (try extendedAutolink(a, t4, 1)).?.end]);
}

test "percent encoding and decoding" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a%20b/%C3%A4?x=1&y=2#f", try encodeUrl(a, "a b/\u{e4}?x=1&y=2#f"));
    try testing.expectEqualStrings("h\u{e9}llo", try percentDecode(a, "h%C3%A9llo"));
    try testing.expectEqualStrings("100%", try percentDecode(a, "100%"));
}
