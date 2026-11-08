const std = @import("std");
const builtin = @import("builtin");
const ttf = @import("ttf.zig");

pub const Font = ttf.Font;


const Entry = struct { name: []const u8, files: [4][]const u8 };

fn e(name: []const u8, r: []const u8, b: []const u8, i: []const u8, bi: []const u8) Entry {
    return .{ .name = name, .files = .{ r, b, i, bi } };
}

const windows_fonts = [_]Entry{
    e("arial", "arial.ttf", "arialbd.ttf", "ariali.ttf", "arialbi.ttf"),
    e("trebuchet ms", "trebuc.ttf", "trebucbd.ttf", "trebucit.ttf", "trebucbi.ttf"),
    e("verdana", "verdana.ttf", "verdanab.ttf", "verdanai.ttf", "verdanaz.ttf"),
    e("segoe ui", "segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf"),
    e("tahoma", "tahoma.ttf", "tahomabd.ttf", "", ""),
    e("times new roman", "times.ttf", "timesbd.ttf", "timesi.ttf", "timesbi.ttf"),
    e("georgia", "georgia.ttf", "georgiab.ttf", "georgiai.ttf", "georgiaz.ttf"),
    e("courier new", "cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf"),
    e("consolas", "consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf"),
    e("calibri", "calibri.ttf", "calibrib.ttf", "calibrii.ttf", "calibriz.ttf"),
    e("comic sans ms", "comic.ttf", "comicbd.ttf", "comici.ttf", "comicz.ttf"),
    e("impact", "impact.ttf", "", "", ""),
    e("segoe ui symbol", "seguisym.ttf", "", "", ""),
    e("segoe ui emoji", "seguiemj.ttf", "", "", ""),
    e("yu gothic ui", "YuGothR.ttc", "YuGothB.ttc", "", ""),
    e("microsoft yahei", "msyh.ttc", "msyhbd.ttc", "", ""),
    e("malgun gothic", "malgun.ttf", "malgunbd.ttf", "", ""),
};

const linux_fonts = [_]Entry{
    e("dejavu sans", "dejavusans.ttf", "dejavusans-bold.ttf", "dejavusans-oblique.ttf", "dejavusans-boldoblique.ttf"),
    e("noto sans", "notosans-regular.ttf", "notosans-bold.ttf", "notosans-italic.ttf", "notosans-bolditalic.ttf"),
    e("noto sans cjk", "notosanscjk-regular.ttc", "notosanscjk-bold.ttc", "", ""),
    e("noto sans symbols", "notosanssymbols-regular.ttf", "notosanssymbols-bold.ttf", "", ""),
    e("noto sans symbols2", "notosanssymbols2-regular.ttf", "", "", ""),
};

const mac_fonts = [_]Entry{
    e("helvetica", "Helvetica.ttc", "Helvetica.ttc", "Helvetica.ttc", "Helvetica.ttc"),
    e("arial", "Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf"),
    e("trebuchet ms", "Trebuchet MS.ttf", "Trebuchet MS Bold.ttf", "Trebuchet MS Italic.ttf", "Trebuchet MS Bold Italic.ttf"),
    e("verdana", "Verdana.ttf", "Verdana Bold.ttf", "Verdana Italic.ttf", "Verdana Bold Italic.ttf"),
    e("tahoma", "Tahoma.ttf", "Tahoma Bold.ttf", "", ""),
    e("times new roman", "Times New Roman.ttf", "Times New Roman Bold.ttf", "Times New Roman Italic.ttf", "Times New Roman Bold Italic.ttf"),
    e("times", "Times.ttc", "Times.ttc", "Times.ttc", "Times.ttc"),
    e("georgia", "Georgia.ttf", "Georgia Bold.ttf", "Georgia Italic.ttf", "Georgia Bold Italic.ttf"),
    e("courier new", "Courier New.ttf", "Courier New Bold.ttf", "Courier New Italic.ttf", "Courier New Bold Italic.ttf"),
    e("menlo", "Menlo.ttc", "Menlo.ttc", "Menlo.ttc", "Menlo.ttc"),
    e("comic sans ms", "Comic Sans MS.ttf", "Comic Sans MS Bold.ttf", "", ""),
    e("impact", "Impact.ttf", "", "", ""),
    e("helvetica neue", "HelveticaNeue.ttc", "HelveticaNeue.ttc", "HelveticaNeue.ttc", "HelveticaNeue.ttc"),
    e("hiragino sans", "ヒラギノ角ゴシック W3.ttc", "ヒラギノ角ゴシック W6.ttc", "", ""),
    e("pingfang sc", "PingFang.ttc", "PingFang.ttc", "", ""),
    e("apple sd gothic neo", "AppleSDGothicNeo.ttc", "AppleSDGothicNeo.ttc", "", ""),
    e("apple symbols", "Apple Symbols.ttf", "", "", ""),
};

const Lookup = union(enum) { named: []const u8, bundled };

const Pair = [2][]const u8;

const windows_alias = [_]Pair{
    .{ "sans-serif", "arial" },      .{ "helvetica", "arial" },       .{ "helvetica neue", "arial" },
    .{ "serif", "times new roman" }, .{ "times", "times new roman" }, .{ "monospace", "consolas" },
    .{ "courier", "courier new" },   .{ "cursive", "comic sans ms" }, .{ "fantasy", "impact" },
    .{ "system-ui", "segoe ui" },    .{ "ui-sans-serif", "segoe ui" },
};

const mac_alias = [_]Pair{
    .{ "sans-serif", "helvetica" }, .{ "helvetica neue", "helvetica" }, .{ "ui-sans-serif", "helvetica" },
    .{ "serif", "times" },          .{ "monospace", "menlo" },          .{ "courier", "courier new" },
    .{ "ui-monospace", "menlo" },   .{ "ui-serif", "times" },           .{ "system-ui", "helvetica" },
    .{ "cursive", "" },             .{ "fantasy", "" },
};

const linux_alias = [_]Pair{
    .{ "sans-serif", "" },      .{ "arial", "" },     .{ "helvetica", "" },
    .{ "helvetica neue", "" },  .{ "system-ui", "" }, .{ "ui-sans-serif", "" },
    .{ "liberation sans", "" },
};

fn alias(os: std.Target.Os.Tag, name: []const u8) Lookup {
    const map: []const Pair = switch (os) {
        .windows => &windows_alias,
        .macos => &mac_alias,
        else => &linux_alias,
    };
    for (map) |m| {
        if (!std.mem.eql(u8, m[0], name)) continue;
        return if (m[1].len == 0) .bundled else .{ .named = m[1] };
    }
    return .{ .named = name };
}

fn tables(os: std.Target.Os.Tag) [2][]const Entry {
    return switch (os) {
        .windows => .{ &windows_fonts, &.{} },
        .macos => .{ &mac_fonts, &.{} },
        else => .{ &linux_fonts, &windows_fonts },
    };
}

fn dirs(os: std.Target.Os.Tag) []const []const u8 {
    return switch (os) {
        .windows => &.{"C:\\Windows\\Fonts"},
        .macos => &.{ "/System/Library/Fonts/Supplemental", "/System/Library/Fonts", "/Library/Fonts" },
        else => &.{ "/usr/share/fonts", "/usr/local/share/fonts" },
    };
}

pub const Candidates = struct {
    buf: [3][160]u8 = @splat(@splat(0)),
    len: [3]usize = .{ 0, 0, 0 },
    n: usize = 0,

    pub fn get(c: *const Candidates, i: usize) []const u8 {
        return c.buf[i][0..c.len[i]];
    }

    fn add(c: *Candidates, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&c.buf[c.n], fmt, args) catch return;
        c.len[c.n] = s.len;
        c.n += 1;
    }
};

pub fn fileNames(os: std.Target.Os.Tag, name: []const u8, bold: bool, italic: bool) Candidates {
    var c: Candidates = .{};
    for (tables(os)) |tab| for (tab) |en| {
        if (!std.mem.eql(u8, en.name, name)) continue;
        const idx: usize = @intFromBool(bold) + 2 * @as(usize, @intFromBool(italic));
        const file = en.files[idx];
        if (file.len > 0) c.add("{s}", .{file});
        if (os != .windows and os != .macos and file.len > 0) {
            var under: [64]u8 = undefined;
            const n = @min(name.len, under.len);
            for (name[0..n], 0..) |ch, i| under[i] = if (ch == ' ') '_' else ch;
            const suffixes = [_][]const u8{ "", "_Bold", "_Italic", "_Bold_Italic" };
            const suffix = suffixes[idx];
            c.add("{s}{s}.ttf", .{ under[0..n], suffix });
        }
    };
    return c;
}

fn styleFallback(os: std.Target.Os.Tag, name: []const u8, bold: bool, italic: bool) struct { bold: bool, italic: bool, oblique: bool } {
    var b = bold;
    var i = italic;
    var obl = false;
    if (fileNames(os, name, b, i).n == 0 and i) {
        i = false;
        obl = true;
    }
    if (fileNames(os, name, b, i).n == 0 and b) b = false;
    return .{ .bold = b, .italic = i, .oblique = obl };
}

pub fn pickFace(data: []const u8, family: []const u8, bold: bool, italic: bool) ?u32 {
    const n = ttf.faceCount(data);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const f = Font.init(data, i) catch continue;
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        const fam_ok = blk: {
            if (f.nameAscii(1, &b1)) |s| if (std.mem.eql(u8, s, family)) break :blk true;
            if (f.nameAscii(16, &b2)) |s| if (std.mem.eql(u8, s, family)) break :blk true;
            break :blk false;
        };
        if (!fam_ok) continue;
        const sub = f.nameAscii(17, &b1) orelse f.nameAscii(2, &b1) orelse continue;
        const face_bold = std.mem.startsWith(u8, sub, "bold");
        const rest = if (face_bold) std.mem.trimStart(u8, sub["bold".len..], " ") else sub;
        const face_italic = std.mem.eql(u8, rest, "italic") or std.mem.eql(u8, rest, "oblique");
        if (!face_italic and rest.len != 0 and !std.mem.eql(u8, rest, "regular")) continue;
        if (face_bold == bold and face_italic == italic) return i;
    }
    return null;
}

const gpa = std.heap.smp_allocator;

const FileEntry = struct { path: []const u8, data: ?[]const u8 };
const FontEntry = struct { path: []const u8, face: u32, oblique: bool, font: *Font };
const Request = struct { families: []const u8, bold: bool, italic: bool, chain: *const Chain };
const Indexed = struct { lower: []const u8, path: []const u8 };

var lock: std.Io.Mutex = .init;
var file_cache: std.ArrayList(FileEntry) = .empty;
var font_cache: std.ArrayList(FontEntry) = .empty;
var requests: std.ArrayList(Request) = .empty;
var font_index: std.ArrayList(Indexed) = .empty;
var indexed_roots: std.ArrayList([]const u8) = .empty;
var math_cache: ?*const Font = null;
var math_searched = false;
var embedded_math: ?*const Font = null;

const bundled_regular: Font = comptimeInit(@embedFile("sans_regular.ttf"), false);
const bundled_bold: Font = comptimeInit(@embedFile("sans_bold.ttf"), false);
const bundled_italic: Font = comptimeInit(@embedFile("sans_regular.ttf"), true);
const bundled_bold_italic: Font = comptimeInit(@embedFile("sans_bold.ttf"), true);

fn comptimeInit(comptime data: []const u8, comptime oblique: bool) Font {
    @setEvalBranchQuota(1_000_000);
    var f = Font.init(data, 0) catch |err| @compileError(@errorName(err));
    f.oblique = oblique;
    return f;
}

pub fn bundled(bold: bool, italic: bool) *const Font {
    return if (bold) (if (italic) &bundled_bold_italic else &bundled_bold) else (if (italic) &bundled_italic else &bundled_regular);
}

fn readFile(io: std.Io, path: []const u8) ?[]const u8 {
    for (file_cache.items) |fe| if (std.mem.eql(u8, fe.path, path)) return fe.data;
    const owned = gpa.dupe(u8, path) catch return null;
    const data: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch null;
    file_cache.append(gpa, .{ .path = owned, .data = data }) catch return data;
    return data;
}

fn fontFrom(path: []const u8, data: []const u8, face: u32, oblique: bool) ?*const Font {
    for (font_cache.items) |fe| {
        if (fe.face == face and fe.oblique == oblique and std.mem.eql(u8, fe.path, path)) return fe.font;
    }
    const f = gpa.create(Font) catch return null;
    f.* = Font.init(data, face) catch {
        gpa.destroy(f);
        return null;
    };
    f.oblique = oblique;
    const owned = gpa.dupe(u8, path) catch return f;
    font_cache.append(gpa, .{ .path = owned, .face = face, .oblique = oblique, .font = f }) catch return f;
    return f;
}

fn lowerDup(s: []const u8) ?[]u8 {
    const out = gpa.alloc(u8, s.len) catch return null;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn indexRoot(io: std.Io, root: []const u8) void {
    for (indexed_roots.items) |r| if (std.mem.eql(u8, r, root)) return;
    const owned = gpa.dupe(u8, root) catch return;
    indexed_roots.append(gpa, owned) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |ent| {
        if (ent.kind != .file or ent.depth() > 6) continue;
        const lower = lowerDup(ent.basename) orelse continue;
        const full = std.fs.path.join(gpa, &.{ root, ent.path }) catch continue;
        font_index.append(gpa, .{ .lower = lower, .path = full }) catch continue;
    }
}

fn findLinux(io: std.Io, file: []const u8) ?[]const u8 {
    for (dirs(.linux)) |root| indexRoot(io, root);
    return findIndexed(file);
}

fn findIndexed(file: []const u8) ?[]const u8 {
    var lower: [160]u8 = undefined;
    if (file.len > lower.len) return null;
    for (file, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    for (font_index.items) |ix| if (std.mem.eql(u8, ix.lower, lower[0..file.len])) return ix.path;
    return null;
}

fn loadNamed(io: std.Io, os: std.Target.Os.Tag, name: []const u8, bold: bool, italic: bool, lenient: bool) ?*const Font {
    const st = styleFallback(os, name, bold, italic);
    const cands = fileNames(os, name, st.bold, st.italic);
    var pbuf: [512]u8 = undefined;
    for (0..cands.n) |ci| {
        const file = cands.get(ci);
        if (os == .windows or os == .macos) {
            for (dirs(os)) |d| {
                const sep = if (os == .windows) "\\" else "/";
                const p = std.fmt.bufPrint(&pbuf, "{s}{s}{s}", .{ d, sep, file }) catch continue;
                if (loadPath(io, p, name, st.bold, st.italic, st.oblique, lenient)) |f| return f;
            }
        } else if (findLinux(io, file)) |p| {
            if (loadPath(io, p, name, st.bold, st.italic, st.oblique, lenient)) |f| return f;
        }
    }
    return null;
}

fn loadPath(io: std.Io, path: []const u8, name: []const u8, bold: bool, italic: bool, oblique: bool, lenient: bool) ?*const Font {
    const data = readFile(io, path) orelse return null;
    const is_ttc = ttf.faceCount(data) > 1 or std.mem.endsWith(u8, path, ".ttc");
    const face = if (is_ttc) pickFace(data, name, bold, italic) orelse (if (lenient) 0 else return null) else 0;
    return fontFrom(path, data, face, oblique);
}

const Group = enum { text, symbol, cjk, hangul };

fn groupOf(cp: u32) Group {
    if ((cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0x1100 and cp <= 0x11FF) or (cp >= 0x3130 and cp <= 0x318F)) return .hangul;
    if ((cp >= 0x2E80 and cp <= 0x30FF) or (cp >= 0x31F0 and cp <= 0x31FF) or (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF) or
        (cp >= 0x20000 and cp <= 0x2FFFF)) return .cjk;
    if ((cp >= 0x2190 and cp <= 0x2BFF) or (cp >= 0x1F000 and cp <= 0x1FFFF)) return .symbol;
    return .text;
}

fn fallbackNames(os: std.Target.Os.Tag, g: Group) []const []const u8 {
    return switch (os) {
        .windows => switch (g) {
            .text => &.{"segoe ui"},
            .symbol => &.{ "segoe ui symbol", "segoe ui emoji", "segoe ui" },
            .cjk => &.{ "yu gothic ui", "microsoft yahei", "malgun gothic", "segoe ui" },
            .hangul => &.{ "malgun gothic", "microsoft yahei", "yu gothic ui", "segoe ui" },
        },
        .macos => switch (g) {
            .text => &.{"helvetica neue"},
            .symbol => &.{ "apple symbols", "helvetica neue" },
            .cjk => &.{ "hiragino sans", "pingfang sc", "apple sd gothic neo", "helvetica neue" },
            .hangul => &.{ "apple sd gothic neo", "pingfang sc", "hiragino sans", "helvetica neue" },
        },
        else => switch (g) {
            .text => &.{ "noto sans", "dejavu sans" },
            .symbol => &.{ "noto sans symbols", "noto sans symbols2", "dejavu sans", "noto sans" },
            .cjk, .hangul => &.{ "noto sans cjk", "dejavu sans", "noto sans" },
        },
    };
}

pub const Chain = struct {
    io: std.Io,
    bold: bool,
    italic: bool,
    faces: []const *const Font,
    primary: *const Font,

    pub const Glyph = struct { font: *const Font, gid: u16 };

    pub fn glyphFor(c: *const Chain, cp: u32) Glyph {
        for (c.faces) |f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .font = f, .gid = g };
        }
        return c.fallback(cp);
    }

    fn fallback(c: *const Chain, cp: u32) Glyph {
        lock.lockUncancelable(c.io);
        defer lock.unlock(c.io);
        for (fallbackNames(builtin.os.tag, groupOf(cp))) |name| {
            const f = loadNamed(c.io, builtin.os.tag, name, c.bold, c.italic, true) orelse continue;
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .font = f, .gid = g };
        }
        const last = bundled(c.bold, c.italic);
        const g = last.glyphIndex(cp);
        if (g != 0) return .{ .font = last, .gid = g };
        return .{ .font = c.primary, .gid = 0 };
    }

    pub fn measure(c: *const Chain, text: []const u8, size: f64) struct { w: f64, h: f64 } {
        var w: f64 = 0;
        var h: f64 = c.primary.lineHeight(size);
        var prev: ?Glyph = null;
        var i: usize = 0;
        while (i < text.len) {
            const d = ttf.decodeAt(text, i);
            i += d.len;
            if (ttf.isZeroWidth(d.cp)) continue;
            const g = c.glyphFor(d.cp);
            const scale = size / @as(f64, @floatFromInt(g.font.upem));
            w += g.font.advance(g.gid) * scale;
            if (prev) |p| {
                if (p.font == g.font) w += g.font.kern(p.gid, g.gid) * scale;
            }
            h = @max(h, g.font.lineHeight(size));
            prev = g;
        }
        return .{ .w = w, .h = h };
    }

    pub fn outlineAt(c: *const Chain, alloc: std.mem.Allocator, cp: u32, size: f64, x: f64, y: f64, path: anytype) ttf.Error!void {
        const g = c.glyphFor(cp);
        try g.font.outlineAt(alloc, g.gid, size, x, y, path);
    }

    pub fn advancePx(c: *const Chain, cp: u32, size: f64) f64 {
        const g = c.glyphFor(cp);
        return g.font.advance(g.gid) * size / @as(f64, @floatFromInt(g.font.upem));
    }
};

fn buildChain(io: std.Io, families: []const u8, bold: bool, italic: bool) *const Chain {
    var faces: [16]*const Font = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, families, ',');
    while (it.next()) |raw| {
        var name_buf: [96]u8 = undefined;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'");
        if (trimmed.len == 0 or trimmed.len > name_buf.len) continue;
        const name = std.ascii.lowerString(&name_buf, trimmed);
        const f = switch (alias(builtin.os.tag, name)) {
            .bundled => bundled(bold, italic),
            .named => |nm| loadNamed(io, builtin.os.tag, nm, bold, italic, false) orelse continue,
        };
        if (std.mem.indexOfScalar(*const Font, faces[0..n], f) != null) continue;
        if (n == faces.len) break;
        faces[n] = f;
        n += 1;
    }
    if (n == 0) {
        faces[0] = bundled(bold, italic);
        n = 1;
    }
    const owned = gpa.dupe(*const Font, faces[0..n]) catch @panic("out of memory");
    const c = gpa.create(Chain) catch @panic("out of memory");
    c.* = .{ .io = io, .bold = bold, .italic = italic, .faces = owned, .primary = owned[0] };
    return c;
}

pub fn resolve(io: std.Io, families: []const u8, weight: u16, italic: bool) *const Chain {
    const bold = weight >= 600;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    for (requests.items) |r| {
        if (r.bold == bold and r.italic == italic and std.mem.eql(u8, r.families, families)) return r.chain;
    }
    const c = buildChain(io, families, bold, italic);
    const owned = gpa.dupe(u8, families) catch return c;
    requests.append(gpa, .{ .families = owned, .bold = bold, .italic = italic, .chain = c }) catch return c;
    return c;
}

const math_blob = @embedFile("stix_math.z");

const linux_math_files = [_][]const u8{
    "latinmodern-math.otf",
    "stixtwomath-regular.otf",
    "stixtwomath-regular.ttf",
    "texgyrepagella-math.otf",
    "texgyretermes-math.otf",
    "texgyrebonum-math.otf",
    "texgyreschola-math.otf",
    "texgyredejavu-math.otf",
    "notosansmath-regular.ttf",
    "dejavumathtexgyre.ttf",
    "xits-math.otf",
    "xitsmath-regular.otf",
    "libertinusmath-regular.otf",
};

fn inflateMath(io: std.Io) ?*const Font {
    _ = io;
    var reader = std.Io.Reader.fixed(math_blob);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&reader, .raw, &window);
    const data = dec.reader.allocRemaining(gpa, .limited(16 << 20)) catch return null;
    const f = gpa.create(Font) catch return null;
    f.* = Font.init(data, 0) catch return null;
    return f;
}

pub fn embeddedMathFont(io: std.Io) *const Font {
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    if (embedded_math == null) embedded_math = inflateMath(io);
    return embedded_math orelse @panic("embedded math font is damaged");
}

fn systemMath(io: std.Io, home: ?[]const u8) ?*const Font {
    switch (builtin.os.tag) {
        .windows => {
            const p = "C:\\Windows\\Fonts\\cambria.ttc";
            const data = readFile(io, p) orelse return null;
            const face = pickFace(data, "cambria math", false, false) orelse return null;
            const f = fontFrom(p, data, face, false) orelse return null;
            return if (f.math != null) f else null;
        },
        .macos => {
            for (dirs(.macos)) |root| indexRoot(io, root);
            if (home) |h| {
                var buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}/Library/Fonts", .{h})) |root| indexRoot(io, root) else |_| {}
            }
            for ([_][]const u8{ "stixtwomath.otf", "stixtwomath-regular.otf", "latinmodern-math.otf" }) |name| {
                const p = findIndexed(name) orelse continue;
                const data = readFile(io, p) orelse continue;
                const f = fontFrom(p, data, 0, false) orelse continue;
                if (f.math != null) return f;
            }
            return null;
        },
        else => {
            if (home) |h| {
                var buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}/.local/share/fonts", .{h})) |root| indexRoot(io, root) else |_| {}
                if (std.fmt.bufPrint(&buf, "{s}/.fonts", .{h})) |root| indexRoot(io, root) else |_| {}
            }
            for ([_][]const u8{ "/usr/share/texmf/fonts", "/usr/share/texlive/texmf-dist/fonts" }) |root| indexRoot(io, root);
            for (linux_math_files) |name| {
                const p = findLinux(io, name) orelse continue;
                const data = readFile(io, p) orelse continue;
                const f = fontFrom(p, data, 0, false) orelse continue;
                if (f.math != null) return f;
            }
            return null;
        },
    }
}

pub fn mathFont(io: std.Io, home: ?[]const u8) *const Font {
    {
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (!math_searched) {
            math_searched = true;
            math_cache = systemMath(io, home);
        }
        if (math_cache) |f| return f;
    }
    return embeddedMathFont(io);
}
