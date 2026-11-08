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

fn table(os: std.Target.Os.Tag) []const Entry {
    return switch (os) {
        .macos => &mac_fonts,
        else => &windows_fonts,
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
    for (table(os)) |en| {
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
    }
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
const Request = struct { key: []const u8, font: *const Font };
const Indexed = struct { lower: []const u8, path: []const u8 };

var lock: std.Io.Mutex = .init;
var file_cache: std.ArrayList(FileEntry) = .empty;
var font_cache: std.ArrayList(FontEntry) = .empty;
var requests: std.ArrayList(Request) = .empty;
var linux_index: ?[]const Indexed = null;

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

fn buildIndex(io: std.Io) []const Indexed {
    var list: std.ArrayList(Indexed) = .empty;
    for (dirs(.linux)) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.walk(gpa) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |ent| {
            if (ent.kind != .file or ent.depth() > 6) continue;
            const lower = lowerDup(ent.basename) orelse continue;
            const full = std.fs.path.join(gpa, &.{ root, ent.path }) catch continue;
            list.append(gpa, .{ .lower = lower, .path = full }) catch continue;
        }
    }
    return list.items;
}

fn findLinux(io: std.Io, file: []const u8) ?[]const u8 {
    if (linux_index == null) linux_index = buildIndex(io);
    var lower: [160]u8 = undefined;
    if (file.len > lower.len) return null;
    for (file, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    for (linux_index.?) |ix| if (std.mem.eql(u8, ix.lower, lower[0..file.len])) return ix.path;
    return null;
}

fn loadNamed(io: std.Io, os: std.Target.Os.Tag, name: []const u8, bold: bool, italic: bool) ?*const Font {
    const st = styleFallback(os, name, bold, italic);
    const cands = fileNames(os, name, st.bold, st.italic);
    var pbuf: [512]u8 = undefined;
    for (0..cands.n) |ci| {
        const file = cands.get(ci);
        if (os == .windows or os == .macos) {
            for (dirs(os)) |d| {
                const sep = if (os == .windows) "\\" else "/";
                const p = std.fmt.bufPrint(&pbuf, "{s}{s}{s}", .{ d, sep, file }) catch continue;
                if (loadPath(io, p, name, st.bold, st.italic, st.oblique)) |f| return f;
            }
        } else if (findLinux(io, file)) |p| {
            if (loadPath(io, p, name, st.bold, st.italic, st.oblique)) |f| return f;
        }
    }
    return null;
}

fn loadPath(io: std.Io, path: []const u8, name: []const u8, bold: bool, italic: bool, oblique: bool) ?*const Font {
    const data = readFile(io, path) orelse return null;
    const face = if (ttf.faceCount(data) > 1 or std.mem.endsWith(u8, path, ".ttc")) pickFace(data, name, bold, italic) orelse return null else 0;
    return fontFrom(path, data, face, oblique);
}

fn resolveLocked(io: std.Io, families: []const u8, bold: bool, italic: bool) *const Font {
    var it = std.mem.splitScalar(u8, families, ',');
    while (it.next()) |raw| {
        var name_buf: [96]u8 = undefined;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'");
        if (trimmed.len == 0 or trimmed.len > name_buf.len) continue;
        const name = std.ascii.lowerString(&name_buf, trimmed);
        switch (alias(builtin.os.tag, name)) {
            .bundled => return bundled(bold, italic),
            .named => |n| if (loadNamed(io, builtin.os.tag, n, bold, italic)) |f| return f,
        }
    }
    return bundled(bold, italic);
}

pub fn resolve(io: std.Io, families: []const u8, weight: u16, italic: bool) *const Font {
    const bold = weight >= 600;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}{d}{s}", .{ @intFromBool(bold), @intFromBool(italic), families }) catch return resolveLocked(io, families, bold, italic);
    for (requests.items) |r| if (std.mem.eql(u8, r.key, key)) return r.font;
    const f = resolveLocked(io, families, bold, italic);
    const owned = gpa.dupe(u8, key) catch return f;
    requests.append(gpa, .{ .key = owned, .font = f }) catch return f;
    return f;
}
