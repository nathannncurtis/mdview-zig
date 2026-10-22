const std = @import("std");
const Allocator = std.mem.Allocator;
const colors = @import("highlight_colors.zig");
const languages = @import("languages.zig");

pub const Kind = enum {
    keyword,
    string,
    number,
    comment,
    function,
    type,
    constant,
    operator,
    punctuation,
    property,
    tag,
    attribute,
    variable,
    diff_added,
    diff_removed,
    diff_heading,
    diff_changed,
    markup_heading,
    markup_list,
    link_url,
};

pub const Token = struct { start: u32, end: u32, kind: Kind };

pub const Lang = enum {
    c, cpp, csharp, go, rust, zig, java, kotlin, swift, python, ruby, php,
    javascript, typescript, json, yaml, toml, ini, bash, powershell, batch,
    sql, html, css, scss, markdown, diff, dockerfile, makefile, lua, dart,
};

pub const Style = struct { fg: ?u24 = null, bg: ?u24 = null, bold: bool = false, underline: bool = false };

/// GitHub dark theme style for a token kind. `bg` paints the whole line the token starts on.
pub fn style(kind: Kind) Style {
    return switch (kind) {
        .keyword, .operator => .{ .fg = colors.keyword },
        .string => .{ .fg = colors.string },
        .number, .constant, .property => .{ .fg = colors.constant },
        .comment => .{ .fg = colors.comment },
        .function, .type, .attribute => .{ .fg = colors.entity },
        .tag => .{ .fg = colors.entity_tag },
        .variable => .{ .fg = colors.variable },
        .punctuation => .{},
        .diff_added => .{ .fg = colors.markup_inserted_text, .bg = colors.markup_inserted_bg },
        .diff_removed => .{ .fg = colors.markup_deleted_text, .bg = colors.markup_deleted_bg },
        .diff_changed => .{ .fg = colors.markup_changed_text, .bg = colors.markup_changed_bg },
        .diff_heading => .{ .fg = colors.meta_diff_range, .bold = true },
        .markup_heading => .{ .fg = colors.markup_heading, .bold = true },
        .markup_list => .{ .fg = colors.markup_list },
        .link_url => .{ .fg = colors.constant_other_reference_link, .underline = true },
    };
}

const by_id = std.StaticStringMap(Lang).initComptime(.{
    .{ "c", .c },
    .{ "c++", .cpp },
    .{ "c#", .csharp },
    .{ "go", .go },
    .{ "rust", .rust },
    .{ "zig", .zig },
    .{ "java", .java },
    .{ "kotlin", .kotlin },
    .{ "swift", .swift },
    .{ "python", .python },
    .{ "ruby", .ruby },
    .{ "php", .php },
    .{ "javascript", .javascript },
    .{ "jsx", .javascript },
    .{ "typescript", .typescript },
    .{ "tsx", .typescript },
    .{ "json", .json },
    .{ "json with comments", .json },
    .{ "json5", .json },
    .{ "yaml", .yaml },
    .{ "toml", .toml },
    .{ "ini", .ini },
    .{ "properties", .ini },
    .{ "shell", .bash },
    .{ "shellsession", .bash },
    .{ "powershell", .powershell },
    .{ "batchfile", .batch },
    .{ "sql", .sql },
    .{ "plpgsql", .sql },
    .{ "tsql", .sql },
    .{ "html", .html },
    .{ "xml", .html },
    .{ "svg", .html },
    .{ "xslt", .html },
    .{ "xml property list", .html },
    .{ "css", .css },
    .{ "scss", .scss },
    .{ "less", .scss },
    .{ "markdown", .markdown },
    .{ "diff", .diff },
    .{ "dockerfile", .dockerfile },
    .{ "makefile", .makefile },
    .{ "lua", .lua },
    .{ "dart", .dart },
});

/// Resolves the first word of a fence info string the way Linguist resolves aliases.
pub fn resolve(info: []const u8) ?Lang {
    const word = std.mem.trimStart(u8, info, " \t{.");
    const end = std.mem.findAny(u8, word, " \t{,") orelse word.len;
    if (end == 0 or end > 40) return null;
    var buf: [40]u8 = undefined;
    const id = languages.lookup(std.ascii.lowerString(&buf, word[0..end])) orelse return null;
    return by_id.get(languages.name(id));
}

pub const List = std.ArrayList(Token);

/// Appends tokens for `code`, sorted by start and non-overlapping. Unknown languages append nothing.
pub fn tokens(gpa: Allocator, lang: []const u8, code: []const u8, out: *List) Allocator.Error!void {
    const l = resolve(lang) orelse return;
    try lexLang(.{ .gpa = gpa, .list = out }, l, code);
}

const Out = struct {
    gpa: Allocator,
    list: *List,
    base: u32 = 0,

    fn add(o: Out, s: usize, e: usize, k: Kind) Allocator.Error!void {
        if (e <= s) return;
        try o.list.append(o.gpa, .{ .start = o.base + @as(u32, @intCast(s)), .end = o.base + @as(u32, @intCast(e)), .kind = k });
    }

    fn at(o: Out, off: usize) Out {
        var r = o;
        r.base += @intCast(off);
        return r;
    }
};

fn lexLang(o: Out, l: Lang, s: []const u8) Allocator.Error!void {
    switch (l) {
        .c => try lex(o, &cfg_c, s),
        .cpp => try lex(o, &cfg_cpp, s),
        .csharp => try lex(o, &cfg_cs, s),
        .go => try lex(o, &cfg_go, s),
        .rust => try lex(o, &cfg_rust, s),
        .zig => try lex(o, &cfg_zig, s),
        .java => try lex(o, &cfg_java, s),
        .kotlin => try lex(o, &cfg_kotlin, s),
        .swift => try lex(o, &cfg_swift, s),
        .python => try lex(o, &cfg_python, s),
        .ruby => try lex(o, &cfg_ruby, s),
        .php => try lex(o, &cfg_php, s),
        .javascript => try lex(o, &cfg_js, s),
        .typescript => try lex(o, &cfg_ts, s),
        .json => try lex(o, &cfg_json, s),
        .toml => try lex(o, &cfg_toml, s),
        .bash => try lex(o, &cfg_bash, s),
        .powershell => try lex(o, &cfg_ps, s),
        .batch => try lex(o, &cfg_batch, s),
        .sql => try lex(o, &cfg_sql, s),
        .lua => try lex(o, &cfg_lua, s),
        .dart => try lex(o, &cfg_dart, s),
        .yaml => try lexYaml(o, s),
        .ini => try lexIni(o, s),
        .html => try lexHtml(o, s),
        .css => try lexCss(o, s, false),
        .scss => try lexCss(o, s, true),
        .markdown => try lexMarkdown(o, s),
        .diff => try lexDiff(o, s),
        .dockerfile => try lexDocker(o, s),
        .makefile => try lexMake(o, s),
    }
}

// ---------------------------------------------------------------- configs

const Delim = struct { open: []const u8, close: []const u8, esc: bool = true, bol: bool = false };
const At = enum { none, attr, variable };

const Cfg = struct {
    line_comments: []const []const u8 = &.{"//"},
    blocks: []const Delim = &.{.{ .open = "/*", .close = "*/" }},
    quotes: []const u8 = "\"'",
    raw_quotes: []const u8 = "",
    multi: []const Delim = &.{},
    esc: u8 = '\\',
    keywords: []const u8 = "",
    builtins: []const u8 = "",
    constants: []const u8 = "true false null",
    type_decl: []const u8 = "",
    fn_decl: []const u8 = "",
    dash_ops: []const u8 = "",
    fold: bool = false,
    caps: bool = true,
    ops: bool = true,
    dates: bool = false,
    hash_ws: bool = false,
    preproc: bool = false,
    sigil: u8 = 0,
    at: At = .none,
    key_kind: ?Kind = null,
    str_prefix: bool = false,
    rust: bool = false,
    cs: bool = false,
    zig: bool = false,
    regex: bool = false,
    symbols: bool = false,
    ps: bool = false,
    batch: bool = false,
    toml: bool = false,
    php: bool = false,
    paren_var: bool = false,
};

const c_s = "auto break case continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while const void char short int long float double signed unsigned bool _Bool _Alignas _Atomic _Noreturn";
const cfg_c: Cfg = .{
    .keywords = c_s,
    .constants = "true false NULL nullptr",
    .type_decl = "struct enum union",
    .preproc = true,
};
const cfg_cpp: Cfg = .{
    .keywords = c_s ++ " class namespace template typename public private protected virtual override final new delete this operator using try catch throw constexpr consteval constinit noexcept explicit friend mutable decltype static_cast dynamic_cast reinterpret_cast const_cast co_await co_return co_yield concept requires export import module typeid alignas alignof wchar_t char8_t char16_t char32_t and or not xor auto",
    .constants = "true false NULL nullptr",
    .type_decl = "struct enum union class namespace",
    .preproc = true,
};
const cfg_cs: Cfg = .{
    .keywords = "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new object operator out override params private protected public readonly record ref return sbyte sealed short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while async await yield get set init value where partial var dynamic nameof when with required",
    .type_decl = "class struct interface enum record namespace",
    .at = .attr,
    .preproc = true,
    .cs = true,
    .multi = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
};
const cfg_go: Cfg = .{
    .keywords = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any",
    .builtins = "append cap close complex copy delete imag len make new panic print println real recover",
    .constants = "true false nil iota",
    .fn_decl = "func",
    .type_decl = "type",
    .multi = &.{.{ .open = "`", .close = "`", .esc = false }},
};
const cfg_rust: Cfg = .{
    .keywords = "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while union i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str",
    .constants = "true false self Self",
    .fn_decl = "fn",
    .type_decl = "struct enum trait union type mod",
    .rust = true,
};
const cfg_zig: Cfg = .{
    .blocks = &.{},
    .keywords = "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while bool void noreturn type anyerror comptime_int comptime_float u8 i8 u16 i16 u32 i32 u64 i64 u128 i128 usize isize f16 f32 f64 f80 f128 c_int c_uint c_long c_char",
    .constants = "true false null undefined",
    .fn_decl = "fn",
    .at = .attr,
    .zig = true,
};
const cfg_java: Cfg = .{
    .keywords = "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield",
    .type_decl = "class interface enum record",
    .at = .attr,
    .multi = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
};
const cfg_kotlin: Cfg = .{
    .keywords = "as break class continue do else for fun if in interface is object package return super this throw try typealias val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where abstract annotation companion const crossinline data enum external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg",
    .fn_decl = "fun",
    .type_decl = "class interface object typealias",
    .at = .attr,
    .multi = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
};
const cfg_swift: Cfg = .{
    .keywords = "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as await is super self Self throws try async actor some any convenience dynamic final lazy mutating nonmutating optional override required weak unowned Int Int8 Int16 Int32 Int64 UInt Double Float Bool String Character",
    .constants = "true false nil",
    .fn_decl = "func",
    .type_decl = "class struct enum protocol extension actor typealias",
    .at = .attr,
    .multi = &.{.{ .open = "\"\"\"", .close = "\"\"\"" }},
};
const cfg_python: Cfg = .{
    .line_comments = &.{"#"},
    .blocks = &.{},
    .keywords = "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield",
    .builtins = "self cls print len range str int float bool list dict set tuple type isinstance issubclass open super enumerate zip map filter sorted sum min max abs any all repr id iter next input object bytes hasattr getattr setattr callable format round reversed vars dir Exception ValueError TypeError KeyError IndexError RuntimeError",
    .constants = "True False None",
    .fn_decl = "def",
    .type_decl = "class",
    .at = .attr,
    .str_prefix = true,
    .multi = &.{ .{ .open = "\"\"\"", .close = "\"\"\"" }, .{ .open = "'''", .close = "'''" } },
};
const cfg_ruby: Cfg = .{
    .line_comments = &.{"#"},
    .blocks = &.{.{ .open = "=begin", .close = "=end", .bol = true }},
    .keywords = "alias and begin BEGIN break case class def do else elsif end END ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private protected public puts",
    .builtins = "self",
    .constants = "true false nil",
    .fn_decl = "def",
    .type_decl = "class module",
    .at = .variable,
    .symbols = true,
    .regex = true,
};
const cfg_php: Cfg = .{
    .line_comments = &.{ "//", "#" },
    .quotes = "\"'`",
    .keywords = "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield int float bool string void mixed self parent",
    .constants = "true false null",
    .fn_decl = "function",
    .type_decl = "class interface trait enum namespace",
    .fold = true,
    .sigil = '$',
    .php = true,
};
const js_s = "async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static switch throw try typeof var void while with yield from as get set";
const cfg_js: Cfg = .{
    .keywords = js_s,
    .builtins = "this super console window document Math JSON Object Array Promise",
    .constants = "true false null undefined NaN Infinity",
    .fn_decl = "function",
    .type_decl = "class",
    .multi = &.{.{ .open = "`", .close = "`" }},
    .regex = true,
};
const cfg_ts: Cfg = .{
    .keywords = js_s ++ " abstract declare enum implements interface namespace module private protected public readonly type keyof infer is asserts satisfies override unique number string boolean any unknown never object symbol bigint",
    .builtins = "this super console window document Math JSON Object Array Promise",
    .constants = "true false null undefined NaN Infinity",
    .fn_decl = "function",
    .type_decl = "class interface enum type namespace",
    .at = .attr,
    .multi = &.{.{ .open = "`", .close = "`" }},
    .regex = true,
};
const cfg_json: Cfg = .{
    .quotes = "\"",
    .caps = false,
    .ops = false,
    .key_kind = .tag,
};
const cfg_toml: Cfg = .{
    .line_comments = &.{"#"},
    .blocks = &.{},
    .quotes = "\"",
    .raw_quotes = "'",
    .multi = &.{ .{ .open = "\"\"\"", .close = "\"\"\"" }, .{ .open = "'''", .close = "'''", .esc = false } },
    .constants = "true false inf nan",
    .caps = false,
    .ops = false,
    .dates = true,
    .toml = true,
};
const bash_kw = "if then else elif fi case esac for select while until do done in function time coproc";
const bash_bi = "echo cd export source alias unset exit return local declare printf eval exec trap pwd pushd popd";
const cfg_bash: Cfg = .{
    .line_comments = &.{"#"},
    .blocks = &.{},
    .quotes = "\"`",
    .raw_quotes = "'",
    .keywords = bash_kw,
    .builtins = bash_bi,
    .fn_decl = "function",
    .sigil = '$',
    .hash_ws = true,
    .caps = false,
};
const cfg_docker: Cfg = blk: {
    var c = cfg_bash;
    c.keywords = "as";
    c.fold = true;
    c.builtins = "";
    break :blk c;
};
const cfg_make_sh: Cfg = blk: {
    var c = cfg_bash;
    c.paren_var = true;
    break :blk c;
};
const cfg_ps: Cfg = .{
    .line_comments = &.{"#"},
    .blocks = &.{.{ .open = "<#", .close = "#>" }},
    .quotes = "\"",
    .raw_quotes = "'",
    .esc = '`',
    .multi = &.{ .{ .open = "@\"", .close = "\"@", .esc = false }, .{ .open = "@'", .close = "'@", .esc = false } },
    .keywords = "begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow",
    .constants = "",
    .fn_decl = "function filter",
    .type_decl = "class enum",
    .dash_ops = "eq ne gt ge lt le like notlike match notmatch contains notcontains in notin and or not xor is isnot as band bor bxor bnot shl shr replace split join f ieq ine igt ige ilt ile ilike imatch ceq cne clike cmatch",
    .fold = true,
    .caps = false,
    .sigil = '$',
    .ps = true,
};
const cfg_batch: Cfg = .{
    .line_comments = &.{ "::", "rem " },
    .blocks = &.{},
    .quotes = "\"",
    .esc = 0,
    .keywords = "echo set if else for in do goto call exit pushd popd cd chdir copy xcopy move del erase md mkdir rd rmdir ren rename type cls title start pause setlocal endlocal shift not exist defined errorlevel equ neq lss leq gtr geq nul",
    .constants = "",
    .fold = true,
    .caps = false,
    .ops = false,
    .batch = true,
};
const cfg_sql: Cfg = .{
    .line_comments = &.{"--"},
    .quotes = "\"'`",
    .esc = 0,
    .keywords = "add all alter and any as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not offset on or order outer primary references replace right rollback select set table then top transaction truncate union unique update using values view when where with returning over partition cascade grant revoke int integer bigint smallint tinyint decimal numeric float real double varchar char text date time timestamp datetime boolean bool blob serial uuid json jsonb",
    .constants = "true false null",
    .fold = true,
    .caps = false,
};
const cfg_lua: Cfg = .{
    .line_comments = &.{"--"},
    .blocks = &.{ .{ .open = "--[[", .close = "]]", .esc = false }, .{ .open = "--[=[", .close = "]=]", .esc = false }, .{ .open = "--[==[", .close = "]==]", .esc = false } },
    .multi = &.{ .{ .open = "[[", .close = "]]", .esc = false }, .{ .open = "[=[", .close = "]=]", .esc = false }, .{ .open = "[==[", .close = "]==]", .esc = false } },
    .keywords = "and break do else elseif end for function goto if in local not or repeat return then until while",
    .builtins = "self print pairs ipairs require tostring tonumber type setmetatable getmetatable assert error pcall xpcall select next rawget rawset string table math os io coroutine",
    .constants = "true false nil",
    .fn_decl = "function",
    .caps = false,
};
const cfg_dart: Cfg = .{
    .keywords = "abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield int double num bool String List Map Set",
    .type_decl = "class mixin enum extension typedef",
    .at = .attr,
    .multi = &.{ .{ .open = "\"\"\"", .close = "\"\"\"" }, .{ .open = "'''", .close = "'''" } },
};

// ---------------------------------------------------------------- helpers

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdent(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn eol(s: []const u8, i: usize) usize {
    return std.mem.findScalarPos(u8, s, i, '\n') orelse s.len;
}

fn has(list: []const u8, w: []const u8, fold: bool) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |x| {
        if (if (fold) std.ascii.eqlIgnoreCase(x, w) else std.mem.eql(u8, x, w)) return true;
    }
    return false;
}

fn numEnd(s: []const u8, i: usize, dates: bool) usize {
    const hex = s[i] == '0' and i + 1 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X');
    var j = i;
    while (j < s.len) : (j += 1) {
        const x = s[j];
        if (std.ascii.isAlphanumeric(x) or x == '_') continue;
        if (x == '.' and j + 1 < s.len and std.ascii.isDigit(s[j + 1])) continue;
        if ((x == '+' or x == '-') and !hex and j > i and (s[j - 1] == 'e' or s[j - 1] == 'E') and j + 1 < s.len and std.ascii.isDigit(s[j + 1])) continue;
        if (dates and (x == '-' or x == ':') and j > i and std.ascii.isDigit(s[j - 1]) and j + 1 < s.len and std.ascii.isDigit(s[j + 1])) continue;
        break;
    }
    return j;
}

fn quoteEnd(s: []const u8, i: usize, q: u8, esc: u8) usize {
    var j = i + 1;
    while (j < s.len and s[j] != q and s[j] != '\n') {
        if (esc != 0 and s[j] == esc and j + 1 < s.len) j += 1;
        j += 1;
    }
    if (j < s.len and s[j] == q) j += 1;
    return j;
}

const Line = struct { start: usize, end: usize };

fn nextLine(s: []const u8, pos: *usize) ?Line {
    if (pos.* >= s.len) return null;
    const st = pos.*;
    const e = eol(s, st);
    pos.* = e + 1;
    return .{ .start = st, .end = e };
}

fn numberLike(v: []const u8) bool {
    var digit = false;
    for (v) |x| {
        if (std.ascii.isDigit(x)) digit = true else if (std.mem.findScalar(u8, "._+-", x) == null) return false;
    }
    return digit;
}

fn valueKind(v: []const u8) Kind {
    if (v.len > 0 and (v[0] == '"' or v[0] == '\'')) return .string;
    if (numberLike(v)) return .number;
    for ([_][]const u8{ "true", "false", "null", "yes", "no", "on", "off", "~" }) |w| {
        if (std.ascii.eqlIgnoreCase(v, w)) return .constant;
    }
    return .string;
}

// ---------------------------------------------------------------- generic lexer

const Lexer = struct {
    o: Out,
    c: *const Cfg,
    s: []const u8,
    i: usize = 0,
    bol: bool = true,
    last: u8 = 0,
    prev: []const u8 = "",

    fn skipTo(l: *Lexer, end: usize) void {
        l.i = end;
        l.last = l.s[end - 1];
    }

    fn put(l: *Lexer, start: usize, end: usize, k: Kind) Allocator.Error!void {
        try l.o.add(start, end, k);
        l.skipTo(end);
    }

    fn matchAt(l: *const Lexer, i: usize, needle: []const u8) bool {
        if (i + needle.len > l.s.len) return false;
        const got = l.s[i .. i + needle.len];
        return if (l.c.fold) std.ascii.eqlIgnoreCase(got, needle) else std.mem.eql(u8, got, needle);
    }

    fn multiEnd(l: *const Lexer, i: usize) ?usize {
        const s = l.s;
        for (l.c.multi) |d| {
            if (!l.matchAt(i, d.open)) continue;
            var j = i + d.open.len;
            while (j < s.len) {
                if (d.esc and l.c.esc != 0 and s[j] == l.c.esc and j + 1 < s.len) {
                    j += 2;
                    continue;
                }
                if (std.mem.startsWith(u8, s[j..], d.close)) return j + d.close.len;
                j += 1;
            }
            return s.len;
        }
        return null;
    }

    fn strKind(l: *const Lexer, e: usize) Kind {
        const k = l.c.key_kind orelse return .string;
        var p = e;
        while (p < l.s.len and isSpace(l.s[p])) p += 1;
        return if (p < l.s.len and l.s[p] == ':') k else .string;
    }

    fn run(l: *Lexer) Allocator.Error!void {
        const s = l.s;
        while (l.i < s.len) {
            const ch = s[l.i];
            if (ch == '\n') {
                l.bol = true;
                l.i += 1;
                continue;
            }
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                l.i += 1;
                continue;
            }
            const bol = l.bol;
            l.bol = false;
            const prev = l.prev;
            l.prev = "";
            try l.token(ch, bol, prev);
        }
    }

    fn token(l: *Lexer, ch: u8, bol: bool, prev: []const u8) Allocator.Error!void {
        const s = l.s;
        const c = l.c;
        const i = l.i;

        for (c.blocks) |d| {
            if ((!d.bol or bol) and l.matchAt(i, d.open)) {
                const close = std.mem.findPos(u8, s, i + d.open.len, d.close);
                return l.put(i, if (close) |p| p + d.close.len else s.len, .comment);
            }
        }
        for (c.line_comments) |lc| {
            if (!l.matchAt(i, lc)) continue;
            if (c.hash_ws and ch == '#' and i > 0 and !isSpace(s[i - 1])) break;
            if (c.php and ch == '#' and i + 1 < s.len and s[i + 1] == '[') break;
            return l.put(i, eol(s, i), .comment);
        }

        if (c.preproc and ch == '#' and bol) {
            var j = i + 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            const ws = j;
            while (j < s.len and isIdent(s[j])) j += 1;
            if (j > ws) {
                try l.o.add(i, j, .keyword);
                const dir = s[ws..j];
                l.skipTo(j);
                if (std.mem.eql(u8, dir, "include") or std.mem.eql(u8, dir, "import") or std.mem.eql(u8, dir, "include_next")) {
                    var k = j;
                    while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
                    if (k < s.len and s[k] == '<') {
                        if (std.mem.findScalarPos(u8, s, k, '>')) |e| {
                            if (e < eol(s, k)) try l.put(k, e + 1, .string);
                        }
                    }
                }
                return;
            }
        }

        if (c.rust and ch == '#') {
            var j = i + 1;
            if (j < s.len and s[j] == '!') j += 1;
            if (j < s.len and s[j] == '[') {
                var d: usize = 0;
                while (j < s.len) : (j += 1) {
                    if (s[j] == '[') d += 1 else if (s[j] == ']') {
                        d -= 1;
                        if (d == 0) {
                            j += 1;
                            break;
                        }
                    }
                }
                return l.put(i, j, .attribute);
            }
        }

        if (l.multiEnd(i)) |e| return l.put(i, e, l.strKind(e));

        if (c.zig and ch == '\\' and i + 1 < s.len and s[i + 1] == '\\') return l.put(i, eol(s, i), .string);

        if (c.cs and (ch == '$' or ch == '@')) {
            var j = i;
            var verbatim = false;
            while (j < s.len and (s[j] == '$' or s[j] == '@')) : (j += 1) {
                if (s[j] == '@') verbatim = true;
            }
            if (j < s.len and s[j] == '"') {
                if (!verbatim) return l.put(i, quoteEnd(s, j, '"', c.esc), .string);
                var k = j + 1;
                while (k < s.len) {
                    if (s[k] == '"') {
                        if (k + 1 < s.len and s[k + 1] == '"') {
                            k += 2;
                            continue;
                        }
                        k += 1;
                        break;
                    }
                    k += 1;
                }
                return l.put(i, k, .string);
            }
        }

        const raw = std.mem.findScalar(u8, c.raw_quotes, ch) != null;
        if (raw or std.mem.findScalar(u8, c.quotes, ch) != null) {
            if (c.rust and ch == '\'' and i + 1 < s.len and isIdentStart(s[i + 1]) and (i + 2 >= s.len or s[i + 2] != '\'')) {
                var j = i + 1;
                while (j < s.len and isIdent(s[j])) j += 1;
                return l.put(i, j, .variable);
            }
            const e = quoteEnd(s, i, ch, if (raw) 0 else c.esc);
            return l.put(i, e, l.strKind(e));
        }

        if (c.regex and ch == '/' and i + 1 < s.len and s[i + 1] != '/' and s[i + 1] != '*' and
            (l.last == 0 or std.mem.findScalar(u8, "(,=:[!&|?{};+-*%<>~^", l.last) != null))
        {
            var j = i + 1;
            var in_cls = false;
            var closed = false;
            while (j < s.len and s[j] != '\n') {
                const x = s[j];
                if (x == '\\') {
                    j += 2;
                    continue;
                }
                if (x == '[') in_cls = true else if (x == ']') in_cls = false else if (x == '/' and !in_cls) {
                    closed = true;
                    break;
                }
                j += 1;
            }
            if (closed) {
                j += 1;
                while (j < s.len and std.ascii.isAlphabetic(s[j])) j += 1;
                return l.put(i, j, .string);
            }
        }

        if (std.ascii.isDigit(ch) or (ch == '.' and i + 1 < s.len and std.ascii.isDigit(s[i + 1]))) {
            return l.put(i, numEnd(s, i, c.dates), .number);
        }

        if (c.sigil != 0 and ch == c.sigil) {
            var j = i + 1;
            if (j < s.len and s[j] == '{') {
                if (std.mem.findScalarPos(u8, s, j, '}')) |e| return l.put(i, e + 1, .variable);
            } else if (c.paren_var and j < s.len and s[j] == '(') {
                if (std.mem.findScalarPos(u8, s, j, ')')) |e| return l.put(i, e + 1, .variable);
            } else if (j < s.len and isIdentStart(s[j])) {
                while (j < s.len and isIdent(s[j])) j += 1;
                while (c.ps and j + 1 < s.len and s[j] == ':' and isIdent(s[j + 1])) {
                    j += 1;
                    while (j < s.len and isIdent(s[j])) j += 1;
                }
                return l.put(i, j, .variable);
            } else if (j < s.len and !c.php and (std.ascii.isDigit(s[j]) or std.mem.findScalar(u8, "?#@*!$-", s[j]) != null or (c.paren_var and std.mem.findScalar(u8, "<^%+", s[j]) != null))) {
                return l.put(i, j + 1, .variable);
            }
        }

        if (ch == '@' and c.at != .none) {
            var j = i + 1;
            if (c.at == .variable and j < s.len and s[j] == '@') j += 1;
            if (j < s.len and isIdentStart(s[j])) {
                while (j < s.len and (isIdent(s[j]) or (c.at == .attr and s[j] == '.' and j + 1 < s.len and isIdentStart(s[j + 1])))) j += 1;
                return l.put(i, j, if (c.at == .attr) .function else .variable);
            }
        }

        if (c.symbols and ch == ':' and i + 1 < s.len and isIdentStart(s[i + 1]) and (i == 0 or !(isIdent(s[i - 1]) or s[i - 1] == ':'))) {
            var j = i + 1;
            while (j < s.len and isIdent(s[j])) j += 1;
            return l.put(i, j, .constant);
        }

        if (c.batch) {
            if (ch == '%' and i + 1 < s.len) {
                var j = i + 1;
                if (s[j] == '%') j += 1;
                if (std.ascii.isDigit(s[j]) or s[j] == '~' or s[j] == '*') {
                    j += 1;
                    while (j < s.len and (isIdent(s[j]) or s[j] == '~')) j += 1;
                    return l.put(i, j, .variable);
                }
                const name = j;
                while (j < s.len and isIdent(s[j])) j += 1;
                if (j > name) {
                    if (s[i + 1] == '%') return l.put(i, j, .variable);
                    if (j < s.len and s[j] == '%') return l.put(i, j + 1, .variable);
                }
            }
            if (ch == ':' and bol and i + 1 < s.len and isIdentStart(s[i + 1])) {
                var j = i + 1;
                while (j < s.len and !isSpace(s[j])) j += 1;
                return l.put(i, j, .function);
            }
        }

        if (c.ps and ch == '-' and i + 1 < s.len and std.ascii.isAlphabetic(s[i + 1])) {
            var j = i + 1;
            while (j < s.len and std.ascii.isAlphabetic(s[j])) j += 1;
            if (has(c.dash_ops, s[i + 1 .. j], true)) return l.put(i, j, .operator);
        }

        if (c.toml and bol) {
            if (ch == '[') {
                var j = i + 1;
                while (j < s.len and s[j] != ']' and s[j] != '\n') j += 1;
                while (j < s.len and s[j] == ']') j += 1;
                return l.put(i, j, .function);
            }
            var j = i;
            while (j < s.len and (isIdent(s[j]) or s[j] == '-' or s[j] == '.')) j += 1;
            var p = j;
            while (p < s.len and (s[p] == ' ' or s[p] == '\t')) p += 1;
            if (j > i and p < s.len and s[p] == '=') return l.put(i, j, .property);
        }

        if (isIdentStart(ch)) return l.ident(prev);

        if (ch == ':' and i + 1 < s.len and s[i + 1] == '=') return l.put(i, i + 2, .operator);

        if (c.ops and std.mem.findScalar(u8, op_chars, ch) != null) {
            var j = i + 1;
            while (j < s.len and std.mem.findScalar(u8, op_chars, s[j]) != null) {
                if (s[j] == '/' and j + 1 < s.len and (s[j + 1] == '/' or s[j + 1] == '*')) break;
                j += 1;
            }
            return l.put(i, j, .operator);
        }

        if (std.mem.findScalar(u8, "{}()[];,.:", ch) != null) return l.put(i, i + 1, .punctuation);
        l.skipTo(i + 1);
    }

    fn ident(l: *Lexer, prev: []const u8) Allocator.Error!void {
        const s = l.s;
        const c = l.c;
        const i = l.i;
        var j = i + 1;
        while (j < s.len and isIdent(s[j])) j += 1;
        if (c.ps and std.ascii.isUpper(s[i])) {
            while (j + 1 < s.len and s[j] == '-' and std.ascii.isAlphabetic(s[j + 1])) {
                j += 1;
                while (j < s.len and isIdent(s[j])) j += 1;
            }
        }
        const word = s[i..j];

        if (c.str_prefix and word.len <= 2 and j < s.len and (s[j] == '"' or s[j] == '\'')) {
            var prefix = true;
            for (word) |x| {
                if (std.mem.findScalar(u8, "rRbBfFuU", x) == null) prefix = false;
            }
            if (prefix) {
                const e = l.multiEnd(j) orelse quoteEnd(s, j, s[j], c.esc);
                return l.put(i, e, .string);
            }
        }

        if (c.rust and j < s.len and (s[j] == '"' or s[j] == '#' or (s[j] == '\'' and std.mem.eql(u8, word, "b")))) {
            const raw_prefix = std.mem.eql(u8, word, "r") or std.mem.eql(u8, word, "br") or std.mem.eql(u8, word, "cr");
            if (raw_prefix or std.mem.eql(u8, word, "b") or std.mem.eql(u8, word, "c")) {
                var k = j;
                var h: usize = 0;
                while (k < s.len and s[k] == '#') {
                    h += 1;
                    k += 1;
                }
                if (k < s.len and s[k] == '"' and raw_prefix) {
                    var m = k + 1;
                    var e = s.len;
                    while (m < s.len) : (m += 1) {
                        if (s[m] != '"' or m + 1 + h > s.len) continue;
                        if (std.mem.allEqual(u8, s[m + 1 .. m + 1 + h], '#')) {
                            e = m + 1 + h;
                            break;
                        }
                    }
                    return l.put(i, e, .string);
                }
                if (h == 0 and k < s.len and (s[k] == '"' or s[k] == '\'')) return l.put(i, quoteEnd(s, k, s[k], c.esc), .string);
            }
        }

        if (c.rust and j + 1 < s.len and s[j] == '!' and (s[j + 1] == '(' or s[j + 1] == '[' or s[j + 1] == '{') and !has(c.keywords, word, false)) {
            return l.put(i, j + 1, .function);
        }

        if (has(c.keywords, word, c.fold)) {
            try l.o.add(i, j, .keyword);
            l.skipTo(j);
            if (has(c.fn_decl, word, c.fold) or has(c.type_decl, word, c.fold)) l.prev = word;
            return;
        }
        if (prev.len > 0 and has(c.fn_decl, prev, c.fold)) return l.put(i, j, .function);
        if (prev.len > 0 and has(c.type_decl, prev, c.fold)) return l.put(i, j, .type);
        if (has(c.builtins, word, c.fold) or has(c.constants, word, c.fold)) return l.put(i, j, .constant);

        var p = j;
        while (p < s.len and (s[p] == ' ' or s[p] == '\t')) p += 1;
        if ((p < s.len and s[p] == '(') or (c.ps and std.mem.findScalar(u8, word, '-') != null)) return l.put(i, j, .function);

        if (c.caps and word.len > 1 and isAllCaps(word)) return l.put(i, j, .constant);
        l.skipTo(j);
    }
};

const op_chars = "+-*/%=<>!&|^~?";

fn isAllCaps(w: []const u8) bool {
    var letter = false;
    for (w) |x| {
        if (std.ascii.isUpper(x)) letter = true else if (!std.ascii.isDigit(x) and x != '_') return false;
    }
    return letter;
}

fn lex(o: Out, c: *const Cfg, s: []const u8) Allocator.Error!void {
    var l: Lexer = .{ .o = o, .c = c, .s = s };
    try l.run();
}

// ---------------------------------------------------------------- line-based formats

fn lexDiff(o: Out, s: []const u8) Allocator.Error!void {
    const headers = [_][]const u8{ "diff ", "index ", "new file", "deleted file", "old mode", "new mode", "similarity", "dissimilarity", "rename ", "copy ", "Binary files" };
    var pos: usize = 0;
    while (nextLine(s, &pos)) |ln| {
        const t = std.mem.trimEnd(u8, s[ln.start..ln.end], "\r");
        if (t.len == 0) continue;
        const k: ?Kind = if (std.mem.startsWith(u8, t, "@@")) .diff_heading else switch (t[0]) {
            '+' => .diff_added,
            '-' => .diff_removed,
            '!' => .diff_changed,
            '\\' => .comment,
            else => for (headers) |p| {
                if (std.mem.startsWith(u8, t, p)) break Kind.constant;
            } else null,
        };
        if (k) |kk| try o.add(ln.start, ln.start + t.len, kk);
    }
}

fn lexIni(o: Out, s: []const u8) Allocator.Error!void {
    var pos: usize = 0;
    while (nextLine(s, &pos)) |ln| {
        const t = s[ln.start..ln.end];
        var j: usize = 0;
        while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
        if (j >= t.len) continue;
        const b = ln.start;
        if (t[j] == ';' or t[j] == '#') {
            try o.add(b + j, ln.end, .comment);
        } else if (t[j] == '[') {
            const e = if (std.mem.findScalar(u8, t, ']')) |q| q + 1 else t.len;
            try o.add(b + j, b + e, .function);
        } else if (std.mem.findAnyPos(u8, t, j, "=:")) |q| {
            const key = std.mem.trimEnd(u8, t[j..q], " \t\r");
            try o.add(b + j, b + j + key.len, .property);
            try o.add(b + q, b + q + 1, .operator);
            const rest = t[q + 1 ..];
            const lead = rest.len - std.mem.trimStart(u8, rest, " \t").len;
            const v = std.mem.trim(u8, rest, " \t\r");
            try o.add(b + q + 1 + lead, b + q + 1 + lead + v.len, valueKind(v));
        }
    }
}

fn lexYaml(o: Out, s: []const u8) Allocator.Error!void {
    var pos: usize = 0;
    var block_parent: ?usize = null;
    while (nextLine(s, &pos)) |ln| {
        const t = s[ln.start..ln.end];
        const tr = std.mem.trimEnd(u8, t, "\r");
        const lead = tr.len - std.mem.trimStart(u8, tr, " \t").len;
        if (lead >= tr.len) continue;
        if (block_parent) |bp| {
            if (lead > bp) {
                try o.add(ln.start + lead, ln.start + tr.len, .string);
                continue;
            }
            block_parent = null;
        }
        if (tr[lead] == '#') {
            try o.add(ln.start + lead, ln.start + tr.len, .comment);
            continue;
        }
        if (std.mem.eql(u8, tr[lead..], "---") or std.mem.eql(u8, tr[lead..], "...")) {
            try o.add(ln.start + lead, ln.start + tr.len, .punctuation);
            continue;
        }
        var j = lead;
        while (j < tr.len and tr[j] == '-' and (j + 1 == tr.len or tr[j + 1] == ' ')) {
            try o.add(ln.start + j, ln.start + j + 1, .punctuation);
            j += 1;
            while (j < tr.len and tr[j] == ' ') j += 1;
        }
        if (j >= tr.len) continue;
        if (yamlKeyEnd(tr, j)) |k| {
            var ke = k;
            while (ke > j and tr[ke - 1] == ' ') ke -= 1;
            try o.add(ln.start + j, ln.start + ke, .tag);
            try o.add(ln.start + k, ln.start + k + 1, .punctuation);
            j = k + 1;
        }
        if (try yamlValue(o.at(ln.start), tr, j)) block_parent = lead;
    }
}

fn yamlKeyEnd(t: []const u8, j: usize) ?usize {
    var k = j;
    if (t[j] == '"' or t[j] == '\'') {
        k = quoteEnd(t, j, t[j], if (t[j] == '"') '\\' else 0);
        while (k < t.len and t[k] == ' ') k += 1;
        return if (k < t.len and t[k] == ':') k else null;
    }
    if (std.mem.findScalar(u8, "[{|>&*!%@,?", t[j]) != null) return null;
    while (k < t.len) : (k += 1) {
        if (t[k] == ':' and (k + 1 == t.len or t[k + 1] == ' ')) return k;
        if (t[k] == '#' and k > j and t[k - 1] == ' ') return null;
    }
    return null;
}

/// Returns true when the value opens a block scalar.
fn yamlValue(o: Out, t: []const u8, start: usize) Allocator.Error!bool {
    var j = start;
    while (j < t.len) {
        if (t[j] == ' ' or t[j] == '\t') {
            j += 1;
            continue;
        }
        switch (t[j]) {
            '#' => {
                try o.add(j, t.len, .comment);
                return false;
            },
            '|', '>' => {
                try o.add(j, j + 1, .operator);
                return true;
            },
            '&', '*', '!' => {
                var e = j + 1;
                while (e < t.len and t[e] != ' ') e += 1;
                try o.add(j, e, if (t[j] == '!') .type else .variable);
                j = e;
            },
            '"', '\'' => {
                const e = quoteEnd(t, j, t[j], if (t[j] == '"') '\\' else 0);
                try o.add(j, e, .string);
                j = e;
            },
            '[', '{' => {
                try lex(o.at(j), &cfg_json, t[j..]);
                return false;
            },
            else => {
                var e = j;
                while (e < t.len and !(t[e] == '#' and e > j and t[e - 1] == ' ')) e += 1;
                const v = std.mem.trimEnd(u8, t[j..e], " \t");
                try o.add(j, j + v.len, valueKind(v));
                j = e;
            },
        }
    }
    return false;
}

fn lexDocker(o: Out, s: []const u8) Allocator.Error!void {
    const instr = "from arg cmd copy add run entrypoint env expose label maintainer onbuild shell stopsignal user volume workdir healthcheck";
    var pos: usize = 0;
    var cont = false;
    while (nextLine(s, &pos)) |ln| {
        const t = s[ln.start..ln.end];
        var j: usize = 0;
        while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
        const was_cont = cont;
        cont = std.mem.endsWith(u8, std.mem.trimEnd(u8, t, " \t\r"), "\\");
        if (j >= t.len) continue;
        if (t[j] == '#') {
            try o.add(ln.start + j, ln.end, .comment);
            continue;
        }
        if (!was_cont) {
            var e = j;
            while (e < t.len and std.ascii.isAlphabetic(t[e])) e += 1;
            if (has(instr, t[j..e], true)) {
                try o.add(ln.start + j, ln.start + e, .keyword);
                j = e;
            }
        }
        try lex(o.at(ln.start + j), &cfg_docker, t[j..]);
    }
}

fn makeRest(o: Out, t: []const u8, from: usize) Allocator.Error!void {
    var j = from;
    while (j < t.len) {
        if (t[j] == '#') {
            try o.add(j, t.len, .comment);
            return;
        }
        if (t[j] == '$' and j + 1 < t.len) {
            const n = t[j + 1];
            if (n == '(' or n == '{') {
                const close: u8 = if (n == '(') ')' else '}';
                var d: usize = 0;
                var e = j + 1;
                while (e < t.len) : (e += 1) {
                    if (t[e] == n) d += 1 else if (t[e] == close) {
                        d -= 1;
                        if (d == 0) break;
                    }
                }
                e = @min(e + 1, t.len);
                try o.add(j, e, .variable);
                j = e;
                continue;
            }
            try o.add(j, j + 2, .variable);
            j += 2;
            continue;
        }
        j += 1;
    }
}

fn lexMake(o: Out, s: []const u8) Allocator.Error!void {
    const directives = "include -include sinclude ifeq ifneq ifdef ifndef else endif define endef export unexport override vpath undefine";
    var pos: usize = 0;
    while (nextLine(s, &pos)) |ln| {
        const t = s[ln.start..ln.end];
        const lo = o.at(ln.start);
        if (t.len == 0) continue;
        if (t[0] == '\t') {
            try lex(lo, &cfg_make_sh, t);
            continue;
        }
        var j: usize = 0;
        while (j < t.len and t[j] == ' ') j += 1;
        if (j >= t.len) continue;
        if (t[j] == '#') {
            try lo.add(j, t.len, .comment);
            continue;
        }
        var we = j;
        while (we < t.len and (std.ascii.isAlphabetic(t[we]) or t[we] == '-' or t[we] == '_')) we += 1;
        if (has(directives, t[j..we], false)) {
            try lo.add(j, we, .keyword);
            try makeRest(lo, t, we);
            continue;
        }
        var colon: ?usize = null;
        var eq: ?usize = null;
        var k = j;
        while (k < t.len) : (k += 1) {
            if (t[k] == '#') break;
            if (t[k] == '$' and k + 1 < t.len and (t[k + 1] == '(' or t[k + 1] == '{')) {
                const open = t[k + 1];
                const close: u8 = if (open == '(') ')' else '}';
                var d: usize = 0;
                k += 1;
                while (k < t.len) : (k += 1) {
                    if (t[k] == open) d += 1 else if (t[k] == close) {
                        d -= 1;
                        if (d == 0) break;
                    }
                }
                continue;
            }
            if (t[k] == '=' and eq == null) eq = k;
            if (t[k] == ':' and colon == null and !(k + 1 < t.len and t[k + 1] == '=')) colon = k;
        }
        if (eq) |q| if (colon == null or q < colon.?) {
            var ne = q;
            while (ne > j and std.mem.findScalar(u8, ":?+!", t[ne - 1]) != null) ne -= 1;
            const name = std.mem.trimEnd(u8, t[j..ne], " \t");
            try lo.add(j, j + name.len, .variable);
            try lo.add(ne, q + 1, .operator);
            try makeRest(lo, t, q + 1);
            continue;
        };
        if (colon) |q| {
            const name = std.mem.trimEnd(u8, t[j..q], " \t");
            try lo.add(j, j + name.len, .function);
            try lo.add(q, q + 1, .punctuation);
            try makeRest(lo, t, q + 1);
            continue;
        }
        try makeRest(lo, t, j);
    }
}

// ---------------------------------------------------------------- markup

fn lexHtml(o: Out, s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            var e = i + 1;
            while (e < s.len and e - i < 10 and (std.ascii.isAlphanumeric(s[e]) or s[e] == '#')) e += 1;
            if (e < s.len and s[e] == ';' and e > i + 1) {
                try o.add(i, e + 1, .constant);
                i = e + 1;
                continue;
            }
        }
        if (s[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "<!--")) {
            const e = if (std.mem.findPos(u8, s, i + 4, "-->")) |p| p + 3 else s.len;
            try o.add(i, e, .comment);
            i = e;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "<![CDATA[")) {
            const e = if (std.mem.findPos(u8, s, i + 9, "]]>")) |p| p + 3 else s.len;
            try o.add(i, e, .string);
            i = e;
            continue;
        }
        if (i + 1 < s.len and (s[i + 1] == '!' or s[i + 1] == '?')) {
            const e = if (std.mem.findScalarPos(u8, s, i, '>')) |p| p + 1 else s.len;
            try o.add(i, e, .constant);
            i = e;
            continue;
        }
        var j = i + 1;
        const closing = j < s.len and s[j] == '/';
        if (closing) j += 1;
        const ns = j;
        while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or std.mem.findScalar(u8, "-_:.", s[j]) != null)) j += 1;
        if (j == ns) {
            i += 1;
            continue;
        }
        try o.add(i, ns, .punctuation);
        try o.add(ns, j, .tag);
        const name = s[ns..j];
        var self_closed = false;
        var after_eq = false;
        while (j < s.len) {
            const x = s[j];
            if (isSpace(x)) {
                j += 1;
                continue;
            }
            if (x == '>') {
                try o.add(j, j + 1, .punctuation);
                j += 1;
                break;
            }
            if (x == '/' and j + 1 < s.len and s[j + 1] == '>') {
                try o.add(j, j + 2, .punctuation);
                self_closed = true;
                j += 2;
                break;
            }
            if (x == '<') break;
            if (x == '=') {
                try o.add(j, j + 1, .punctuation);
                after_eq = true;
                j += 1;
                continue;
            }
            if (x == '"' or x == '\'') {
                const e = if (std.mem.findScalarPos(u8, s, j + 1, x)) |p| p + 1 else s.len;
                try o.add(j, e, .string);
                j = e;
                after_eq = false;
                continue;
            }
            var k = j;
            while (k < s.len and !isSpace(s[k]) and std.mem.findScalar(u8, "=>/\"'<", s[k]) == null) k += 1;
            if (k == j) {
                j += 1;
                continue;
            }
            try o.add(j, k, if (after_eq) .string else .attribute);
            after_eq = false;
            j = k;
        }
        i = j;
        const embedded: ?Lang = if (closing or self_closed) null else if (std.ascii.eqlIgnoreCase(name, "script")) .javascript else if (std.ascii.eqlIgnoreCase(name, "style")) .css else null;
        if (embedded) |lang| {
            var e = i;
            while (std.mem.findPos(u8, s, e, "</")) |p| {
                if (p + 2 + name.len <= s.len and std.ascii.eqlIgnoreCase(s[p + 2 .. p + 2 + name.len], name)) {
                    e = p;
                    break;
                }
                e = p + 2;
            } else e = s.len;
            try lexLang(o.at(i), lang, s[i..e]);
            i = e;
        }
    }
}

fn lexCss(o: Out, s: []const u8, scss: bool) Allocator.Error!void {
    var i: usize = 0;
    var depth: usize = 0;
    var par: usize = 0;
    var in_value = false;
    while (i < s.len) {
        const ch = s[i];
        if (isSpace(ch)) {
            i += 1;
            continue;
        }
        if (ch == '/' and i + 1 < s.len and s[i + 1] == '*') {
            const e = if (std.mem.findPos(u8, s, i + 2, "*/")) |p| p + 2 else s.len;
            try o.add(i, e, .comment);
            i = e;
            continue;
        }
        if (scss and par == 0 and ch == '/' and i + 1 < s.len and s[i + 1] == '/') {
            const e = eol(s, i);
            try o.add(i, e, .comment);
            i = e;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            const e = quoteEnd(s, i, ch, '\\');
            try o.add(i, e, .string);
            i = e;
            continue;
        }
        if (ch == '{' or ch == '}' or ch == ';' or ch == '(' or ch == ')' or ch == ',' or ch == '>' or ch == '&' or ch == '*') {
            if (ch == '{') depth += 1;
            if (ch == '}' and depth > 0) depth -= 1;
            if (ch == '(') par += 1;
            if (ch == ')' and par > 0) par -= 1;
            if (ch == '{' or ch == '}' or ch == ';') in_value = false;
            try o.add(i, i + 1, .punctuation);
            i += 1;
            continue;
        }
        if (ch == '@' or (scss and ch == '$') or ch == '!') {
            var e = i + 1;
            while (e < s.len and (isIdent(s[e]) or s[e] == '-')) e += 1;
            try o.add(i, e, if (ch == '$') .variable else .keyword);
            i = e;
            continue;
        }
        if (ch == '[' and !in_value) {
            const e = if (std.mem.findScalarPos(u8, s, i, ']')) |p| p + 1 else s.len;
            try o.add(i, e, .attribute);
            i = e;
            continue;
        }
        if (std.ascii.isDigit(ch) or (std.mem.findScalar(u8, ".+-", ch) != null and in_value and i + 1 < s.len and (std.ascii.isDigit(s[i + 1]) or (s[i + 1] == '.' and i + 2 < s.len and std.ascii.isDigit(s[i + 2]))))) {
            var e = i + 1;
            while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.')) e += 1;
            while (e < s.len and (std.ascii.isAlphabetic(s[e]) or s[e] == '%')) e += 1;
            try o.add(i, e, .number);
            i = e;
            continue;
        }
        if (ch == '#' or ch == '.' or ch == ':') {
            var e = i + 1;
            if (ch == ':' and e < s.len and s[e] == ':') e += 1;
            const ns = e;
            while (e < s.len and (isIdent(s[e]) or s[e] == '-')) e += 1;
            if (e > ns) {
                try o.add(i, e, if (ch == '#' and in_value) .constant else .function);
                i = e;
                continue;
            }
        }
        if (isIdentStart(ch) or (ch == '-' and i + 1 < s.len and (isIdentStart(s[i + 1]) or s[i + 1] == '-'))) {
            var e = i + 1;
            while (e < s.len and (isIdent(s[e]) or s[e] == '-')) e += 1;
            const word = s[i..e];
            var p = e;
            while (p < s.len and (s[p] == ' ' or s[p] == '\t')) p += 1;
            if (in_value or par > 0) {
                const k: Kind = if (std.mem.startsWith(u8, word, "--")) .variable else if (e < s.len and s[e] == '(') .function else .constant;
                try o.add(i, e, k);
            } else if (depth > 0 and p < s.len and s[p] == ':' and cssIsDecl(s, p)) {
                try o.add(i, e, .property);
                try o.add(p, p + 1, .punctuation);
                in_value = true;
                i = p + 1;
                continue;
            } else {
                try o.add(i, e, .tag);
            }
            i = e;
            continue;
        }
        i += 1;
    }
}

fn cssIsDecl(s: []const u8, colon: usize) bool {
    const p = std.mem.findAnyPos(u8, s, colon, ";{}") orelse return true;
    return s[p] != '{';
}

fn backtickRun(t: []const u8, k: usize) usize {
    var n: usize = 0;
    while (k + n < t.len and t[k + n] == '`') n += 1;
    return n;
}

fn isMdPunct(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

fn isEmailChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '+' or c == '-';
}

fn bareUrlEnd(t: []const u8, k: usize) usize {
    var e = k;
    while (e < t.len and !isSpace(t[e]) and t[e] != '<' and t[e] != '>') e += 1;
    while (e > k and std.mem.findScalar(u8, ".,;:!?'\"*_~", t[e - 1]) != null) e -= 1;
    return e;
}

fn emailEnd(t: []const u8, k: usize) ?usize {
    var e = k;
    while (e < t.len and isEmailChar(t[e])) e += 1;
    if (e == k or e >= t.len or t[e] != '@') return null;
    var d = e + 1;
    var dots: usize = 0;
    while (d < t.len and (std.ascii.isAlphanumeric(t[d]) or t[d] == '-' or (t[d] == '.' and d + 1 < t.len and std.ascii.isAlphanumeric(t[d + 1])))) : (d += 1) {
        if (t[d] == '.') dots += 1;
    }
    return if (dots > 0 and d > e + 1) d else null;
}

const Run = struct { ch: u8, pos: usize, len: usize };

fn mdTitle(o: Out, t: []const u8, from: usize, to: usize) Allocator.Error!void {
    var k = from;
    while (k < to and t[k] == ' ') k += 1;
    if (k >= to) return;
    const open = t[k];
    const close: u8 = if (open == '(') ')' else open;
    if (open != '"' and open != '\'' and open != '(') return;
    const e = std.mem.findScalarPos(u8, t[0..to], k + 1, close) orelse return;
    try o.add(k, k + 1, .string);
    try o.add(k + 1, e, .string);
    try o.add(e, e + 1, .string);
}

fn mdInline(o: Out, t: []const u8, from: usize) Allocator.Error!void {
    var stack: [16]Run = undefined;
    var sp: usize = 0;
    var k = from;
    while (k < t.len) {
        const ch = t[k];
        if (ch == '\\') {
            if (k + 1 < t.len and isMdPunct(t[k + 1])) {
                try o.add(k, k + 2, .constant);
                k += 2;
            } else k += 1;
        } else if (ch == '`') {
            const n = backtickRun(t, k);
            var q = k + n;
            var close: ?usize = null;
            while (q < t.len) {
                if (t[q] != '`') {
                    q += 1;
                    continue;
                }
                const m = backtickRun(t, q);
                if (m == n) {
                    close = q;
                    break;
                }
                q += m;
            }
            if (close) |c| {
                try o.add(k, k + n, .string);
                try o.add(k + n, c, .constant);
                try o.add(c, c + n, .string);
                k = c + n;
            } else k += n;
        } else if (ch == '*' or ch == '_' or ch == '~') {
            var n: usize = 1;
            while (k + n < t.len and t[k + n] == ch) n += 1;
            if (ch == '~' and n != 2) {
                k += n;
                continue;
            }
            const prev: u8 = if (k > 0) t[k - 1] else ' ';
            const next: u8 = if (k + n < t.len) t[k + n] else ' ';
            var can_open = next != ' ';
            var can_close = prev != ' ';
            if (ch == '_') {
                can_open = can_open and !std.ascii.isAlphanumeric(prev);
                can_close = can_close and !std.ascii.isAlphanumeric(next);
            }
            var matched = false;
            if (can_close) {
                var s = sp;
                while (s > 0) {
                    s -= 1;
                    if (stack[s].ch == ch) {
                        try o.add(stack[s].pos, stack[s].pos + stack[s].len, .string);
                        try o.add(k, k + n, .string);
                        sp = s;
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched and can_open and sp < stack.len) {
                stack[sp] = .{ .ch = ch, .pos = k, .len = n };
                sp += 1;
            }
            k += n;
        } else if (ch == '[' or (ch == '!' and k + 1 < t.len and t[k + 1] == '[')) {
            const open = if (ch == '!') k + 1 else k;
            const close = std.mem.findScalarPos(u8, t, open + 1, ']') orelse {
                k += 1;
                continue;
            };
            try o.add(k, open + 1, .string);
            if (open + 1 < close and t[open + 1] == '^') {
                try o.add(open + 1, open + 2, .string);
                try o.add(open + 2, close, .function);
            } else try mdInline(o, t[0..close], open + 1);
            try o.add(close, close + 1, .string);
            k = close + 1;
            if (k < t.len and t[k] == '(') {
                if (std.mem.findScalarPos(u8, t, k, ')')) |q| {
                    try o.add(k, k + 1, .string);
                    var u = k + 1;
                    while (u < q and t[u] == ' ') u += 1;
                    var ue = u;
                    while (ue < q and t[ue] != ' ') ue += 1;
                    try o.add(u, ue, .link_url);
                    try mdTitle(o, t, ue, q);
                    try o.add(q, q + 1, .string);
                    k = q + 1;
                }
            } else if (k < t.len and t[k] == '[') {
                if (std.mem.findScalarPos(u8, t, k, ']')) |q| {
                    try o.add(k, k + 1, .string);
                    try o.add(k + 1, q, .function);
                    try o.add(q, q + 1, .string);
                    k = q + 1;
                }
            }
        } else if (ch == '<') {
            if (std.mem.startsWith(u8, t[k..], "<!--")) {
                const e = if (std.mem.findPos(u8, t, k + 4, "-->")) |p| p + 3 else t.len;
                try o.add(k, e, .comment);
                k = e;
                continue;
            }
            const e = std.mem.findScalarPos(u8, t, k, '>');
            if (e != null and e.? > k + 1 and std.ascii.isAlphabetic(t[k + 1]) and std.mem.findScalar(u8, t[k + 1 .. e.?], ':') != null and std.mem.findScalar(u8, t[k + 1 .. e.?], ' ') == null) {
                try o.add(k, k + 1, .string);
                try o.add(k + 1, e.?, .link_url);
                try o.add(e.?, e.? + 1, .string);
                k = e.? + 1;
                continue;
            }
            var j = k + 1;
            if (j < t.len and t[j] == '/') j += 1;
            const ns = j;
            while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '-' or t[j] == ':')) j += 1;
            if (j > ns and std.ascii.isAlphabetic(t[ns])) {
                try o.add(ns, j, .tag);
                k = j;
            } else k += 1;
        } else if (ch == '&') {
            var e = k + 1;
            while (e < t.len and e - k < 10 and (std.ascii.isAlphanumeric(t[e]) or t[e] == '#')) e += 1;
            if (e < t.len and t[e] == ';' and e > k + 1) {
                try o.add(k, e + 1, .constant);
                k = e + 1;
            } else k += 1;
        } else if (std.ascii.isAlphanumeric(ch) and (k == 0 or !isEmailChar(t[k - 1]))) {
            if ((std.mem.startsWith(u8, t[k..], "http://") or std.mem.startsWith(u8, t[k..], "https://"))) {
                const e = bareUrlEnd(t, k);
                try o.add(k, e, .link_url);
                k = e;
            } else if (emailEnd(t, k)) |e| {
                try o.add(k, e, .link_url);
                k = e;
            } else {
                while (k < t.len and std.ascii.isAlphanumeric(t[k])) k += 1;
            }
        } else k += 1;
    }
}

fn sortSegment(o: Out, from: usize) void {
    const items = o.list.items;
    var i = from + 1;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        var j = i;
        while (j > from and items[j - 1].start > x.start) : (j -= 1) items[j] = items[j - 1];
        items[j] = x;
    }
}

fn fillGaps(o: Out, from_idx: usize, start: usize, end: usize, kind: Kind) Allocator.Error!void {
    sortSegment(o, from_idx);
    var p = start;
    const last = o.list.items.len;
    var i = from_idx;
    while (i < last) : (i += 1) {
        const tk = o.list.items[i];
        const ts: usize = tk.start - o.base;
        if (ts > p) try o.add(p, ts, kind);
        p = @max(p, tk.end - o.base);
    }
    if (end > p) try o.add(p, end, kind);
    sortSegment(o, from_idx);
}

fn mdDefinition(o: Out, t: []const u8, k: usize) Allocator.Error!bool {
    const close = std.mem.findScalarPos(u8, t, k, ']') orelse return false;
    if (close <= k + 1 or close + 1 >= t.len or t[close + 1] != ':') return false;
    try o.add(k, k + 1, .string);
    if (t[k + 1] == '^') {
        try o.add(k + 1, k + 2, .string);
        try o.add(k + 2, close, .function);
    } else try o.add(k + 1, close, .function);
    try o.add(close, close + 1, .string);
    if (t[k + 1] == '^') return true;
    var u = close + 2;
    while (u < t.len and t[u] == ' ') u += 1;
    var ue = u;
    if (u < t.len and t[u] == '<') {
        const gt = std.mem.findScalarPos(u8, t, u, '>') orelse t.len - 1;
        try o.add(u, u + 1, .string);
        try o.add(u + 1, gt, .link_url);
        try o.add(gt, gt + 1, .string);
        ue = gt + 1;
    } else {
        while (ue < t.len and t[ue] != ' ') ue += 1;
        try o.add(u, ue, .link_url);
    }
    try mdTitle(o, t, ue, t.len);
    return true;
}

fn onlyChars(t: []const u8, set: []const u8) bool {
    for (t) |x| {
        if (std.mem.findScalar(u8, set, x) == null) return false;
    }
    return true;
}

fn lexMarkdown(o: Out, s: []const u8) Allocator.Error!void {
    var pos: usize = 0;
    var fence: ?struct { ch: u8, n: usize, lang: ?Lang, body: usize } = null;
    var prev_blank = true;
    var prev_para = false;
    var prev_code = false;
    while (nextLine(s, &pos)) |ln| {
        const t = std.mem.trimEnd(u8, s[ln.start..ln.end], "\r");
        const lo = o.at(ln.start);
        var j: usize = 0;
        while (j < t.len and j < 3 and t[j] == ' ') j += 1;
        const rest = t[j..];
        const fch: u8 = if (rest.len > 0) rest[0] else 0;
        var n: usize = 0;
        if (fch == '`' or fch == '~') {
            while (n < rest.len and rest[n] == fch) n += 1;
        }
        if (fence) |f| {
            if (n >= f.n and fch == f.ch and std.mem.trim(u8, rest[n..], " \t").len == 0) {
                if (f.lang) |lang| try lexLang(o.at(f.body), lang, s[f.body..ln.start]);
                try lo.add(j, j + n, .string);
                fence = null;
            }
            continue;
        }
        const was_blank = prev_blank;
        const was_para = prev_para;
        const was_code = prev_code;
        prev_blank = std.mem.trim(u8, t, " \t").len == 0;
        prev_para = false;
        prev_code = false;
        if (prev_blank) continue;
        if (n >= 3) {
            try lo.add(j, j + n, .string);
            const info = std.mem.trimStart(u8, rest[n..], " \t");
            const info_start = t.len - info.len;
            const info_end = std.mem.findAny(u8, info, " \t{") orelse info.len;
            try lo.add(info_start, info_start + info_end, .function);
            fence = .{ .ch = fch, .n = n, .lang = resolve(info), .body = @min(ln.end + 1, s.len) };
            continue;
        }
        if ((std.mem.startsWith(u8, t, "    ") or t[0] == '\t') and (was_blank or was_code) and !was_para) {
            const ci = std.mem.findNone(u8, t, " \t") orelse 0;
            try lo.add(ci, t.len, .constant);
            prev_code = true;
            continue;
        }
        if (rest[0] == '#') {
            var h: usize = 0;
            while (h < rest.len and rest[h] == '#') h += 1;
            if (h <= 6 and (h == rest.len or rest[h] == ' ')) {
                try lo.add(j, t.len, .markup_heading);
                continue;
            }
        }
        const body = std.mem.trim(u8, rest, " \t");
        if (was_para and (onlyChars(body, "=") or (body.len >= 2 and onlyChars(body, "-")))) {
            try lo.add(j, j + body.len, .markup_heading);
            continue;
        }
        if (body.len >= 3 and std.mem.findScalar(u8, "*-_", body[0]) != null and onlyChars(body, &[_]u8{ body[0], ' ' }) and std.mem.count(u8, body, &[_]u8{body[0]}) >= 3) {
            try lo.add(j, j + body.len, .markup_heading);
            continue;
        }

        const n0 = o.list.items.len;
        var k: usize = 0;
        var quote_start: ?usize = null;
        var structural = false;
        while (true) {
            while (k < t.len and t[k] == ' ') k += 1;
            if (k < t.len and t[k] == '>') {
                if (quote_start == null) quote_start = k;
                k += 1;
                structural = true;
            } else break;
        }
        if (k + 1 < t.len and std.mem.findScalar(u8, "-*+", t[k]) != null and t[k + 1] == ' ') {
            try lo.add(k, k + 1, .variable);
            k += 1;
            structural = true;
        } else {
            var d = k;
            while (d < t.len and std.ascii.isDigit(t[d])) d += 1;
            if (d > k and d + 1 < t.len and (t[d] == '.' or t[d] == ')') and t[d + 1] == ' ') {
                try lo.add(k, d, .string);
                try lo.add(d, d + 1, .variable);
                k = d + 1;
                structural = true;
            }
        }
        while (k < t.len and t[k] == ' ') k += 1;
        if (structural and (std.mem.startsWith(u8, t[k..], "[ ]") or std.mem.startsWith(u8, t[k..], "[x]") or std.mem.startsWith(u8, t[k..], "[X]"))) {
            try lo.add(k, k + 3, .keyword);
            k += 3;
        }
        if (t[k..].len > 0 and t[k] == '|') {
            structural = true;
            for (t[k..], k..) |x, q| {
                if (x == '|') try lo.add(q, q + 1, .markup_list);
            }
        }
        if (!structural and k < t.len and t[k] == '[' and try mdDefinition(lo, t, k)) {
            sortSegment(lo, n0);
            continue;
        }
        try mdInline(lo, t, k);
        sortSegment(lo, n0);
        if (quote_start) |qs| try fillGaps(lo, n0, qs, t.len, .tag);
        prev_para = !structural;
    }
    if (fence) |f| {
        if (f.lang) |lang| try lexLang(o.at(f.body), lang, s[f.body..]);
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test {
    _ = languages;
}

fn expectTok(lang: []const u8, code: []const u8, text: []const u8, kind: Kind) !void {
    var list: List = .empty;
    defer list.deinit(testing.allocator);
    try tokens(testing.allocator, lang, code, &list);
    var prev_end: u32 = 0;
    var found = false;
    for (list.items) |t| {
        try testing.expect(t.start >= prev_end and t.end > t.start and t.end <= code.len);
        prev_end = t.end;
        if (t.kind == kind and std.mem.eql(u8, code[t.start..t.end], text)) found = true;
    }
    if (!found) {
        std.debug.print("{s}: no {s} token {s}\n", .{ lang, @tagName(kind), text });
        return error.TestExpectedEqual;
    }
}

test "aliases resolve case-insensitively" {
    const cases = [_]struct { []const u8, Lang }{
        .{ "js", .javascript },   .{ "JavaScript", .javascript }, .{ "jsx", .javascript },
        .{ "ts", .typescript },   .{ "tsx", .typescript },        .{ "TypeScript", .typescript },
        .{ "py", .python },       .{ "python", .python },         .{ "sh", .bash },
        .{ "Bash", .bash },       .{ "shell", .bash },            .{ "zsh", .bash },
        .{ "console", .bash },    .{ "yml", .yaml },              .{ "c++", .cpp },
        .{ "cpp", .cpp },         .{ "cs", .csharp },             .{ "csharp", .csharp },
        .{ "rs", .rust },         .{ "golang", .go },             .{ "go", .go },
        .{ "ps1", .powershell },  .{ "bat", .batch },             .{ "md", .markdown },
        .{ "xml", .html },        .{ "svg", .html },              .{ "kt", .kotlin },
        .{ "rb", .ruby },         .{ "make", .makefile },         .{ "js {highlight}", .javascript },
    };
    for (cases) |cs| try testing.expectEqual(cs[1], resolve(cs[0]).?);
}

test "unknown or empty language produces no tokens" {
    for ([_][]const u8{ "", "nosuchlang", "text", "haskell", "   " }) |l| {
        var list: List = .empty;
        defer list.deinit(testing.allocator);
        try tokens(testing.allocator, l, "int x = 1; // c\n", &list);
        try testing.expectEqual(@as(usize, 0), list.items.len);
    }
}

test "c" {
    const code = "#include <stdio.h>\nint main(void) { /* x */ return 0x1F; } // end\nchar *s = \"hi\\n\";";
    try expectTok("c", code, "#include", .keyword);
    try expectTok("c", code, "<stdio.h>", .string);
    try expectTok("c", code, "int", .keyword);
    try expectTok("c", code, "main", .function);
    try expectTok("c", code, "/* x */", .comment);
    try expectTok("c", code, "0x1F", .number);
    try expectTok("c", code, "// end", .comment);
    try expectTok("c", code, "\"hi\\n\"", .string);
    try expectTok("c", code, "{", .punctuation);
}

test "cpp" {
    const code = "template <typename T> class Foo : public Bar { std::vector<int> v; };";
    try expectTok("cpp", code, "template", .keyword);
    try expectTok("cpp", code, "Foo", .type);
    try expectTok("cpp", code, "public", .keyword);
}

test "csharp" {
    const code = "[Serializable]\npublic class Foo { string s = @\"a\"\"b\"; var x = $\"{n}\"; }";
    try expectTok("cs", code, "class", .keyword);
    try expectTok("cs", code, "Foo", .type);
    try expectTok("cs", code, "@\"a\"\"b\"", .string);
    try expectTok("cs", code, "$\"{n}\"", .string);
}

test "go" {
    const code = "func main() {\n\tx := `raw\nstring`\n\tfmt.Println(len(x), nil)\n}";
    try expectTok("go", code, "func", .keyword);
    try expectTok("go", code, "main", .function);
    try expectTok("go", code, ":=", .operator);
    try expectTok("go", code, "`raw\nstring`", .string);
    try expectTok("go", code, "len", .constant);
    try expectTok("go", code, "nil", .constant);
}

test "rust" {
    const code = "#[derive(Debug)]\nfn f<'a>(x: &'a str) -> u8 { println!(\"hi\"); let r = r#\"raw \"q\"\"#; 'c' }";
    try expectTok("rust", code, "#[derive(Debug)]", .attribute);
    try expectTok("rust", code, "fn", .keyword);
    try expectTok("rust", code, "f", .function);
    try expectTok("rust", code, "'a", .variable);
    try expectTok("rust", code, "println!", .function);
    try expectTok("rust", code, "r#\"raw \"q\"\"#", .string);
    try expectTok("rust", code, "'c'", .string);
    try expectTok("rust", code, "u8", .keyword);
}

test "zig" {
    const code = "const x = @import(\"std\");\nconst s =\n    \\\\line one\n;\npub fn main() !void {}";
    try expectTok("zig", code, "const", .keyword);
    try expectTok("zig", code, "@import", .function);
    try expectTok("zig", code, "\\\\line one", .string);
    try expectTok("zig", code, "main", .function);
}

test "java" {
    const code = "@Override\npublic class A { String s = \"\"\"\nblock\"\"\"; int n = 10L; }";
    try expectTok("java", code, "@Override", .function);
    try expectTok("java", code, "class", .keyword);
    try expectTok("java", code, "A", .type);
    try expectTok("java", code, "\"\"\"\nblock\"\"\"", .string);
    try expectTok("java", code, "10L", .number);
}

test "kotlin" {
    const code = "fun main() { val s = \"a\" /* c */ }";
    try expectTok("kotlin", code, "fun", .keyword);
    try expectTok("kotlin", code, "main", .function);
    try expectTok("kotlin", code, "val", .keyword);
    try expectTok("kotlin", code, "/* c */", .comment);
}

test "swift" {
    const code = "struct P { var x: Int = 3 }\nfunc go() -> Bool { return nil }";
    try expectTok("swift", code, "struct", .keyword);
    try expectTok("swift", code, "P", .type);
    try expectTok("swift", code, "go", .function);
    try expectTok("swift", code, "nil", .constant);
}

test "python" {
    const code = "@dec\ndef f(x):\n    # note\n    return f\"{x}\" + \"\"\"doc\n\"\"\" + str(None) + 1.5e3";
    try expectTok("python", code, "@dec", .function);
    try expectTok("python", code, "def", .keyword);
    try expectTok("python", code, "f", .function);
    try expectTok("python", code, "# note", .comment);
    try expectTok("python", code, "f\"{x}\"", .string);
    try expectTok("python", code, "\"\"\"doc\n\"\"\"", .string);
    try expectTok("python", code, "str", .constant);
    try expectTok("python", code, "None", .constant);
    try expectTok("python", code, "1.5e3", .number);
}

test "ruby" {
    const code = "class Foo\n  def bar(x) = @a + :sym\n=begin\nblock\n=end\n  puts 'hi' # c\nend";
    try expectTok("ruby", code, "class", .keyword);
    try expectTok("ruby", code, "Foo", .type);
    try expectTok("ruby", code, "bar", .function);
    try expectTok("ruby", code, "@a", .variable);
    try expectTok("ruby", code, ":sym", .constant);
    try expectTok("ruby", code, "=begin\nblock\n=end", .comment);
    try expectTok("ruby", code, "'hi'", .string);
    try expectTok("ruby", code, "# c", .comment);
}

test "php" {
    const code = "<?php\nfunction f($a) { return $a . \"x\"; } # c\n#[Attr]\nTRUE;";
    try expectTok("php", code, "function", .keyword);
    try expectTok("php", code, "f", .function);
    try expectTok("php", code, "$a", .variable);
    try expectTok("php", code, "# c", .comment);
    try expectTok("php", code, "TRUE", .constant);
}

test "javascript" {
    const code = "const re = /ab+c/gi;\nfunction f(a) { return a / 2 + `t${a}`; } // c\nclass K {}";
    try expectTok("js", code, "const", .keyword);
    try expectTok("js", code, "/ab+c/gi", .string);
    try expectTok("js", code, "f", .function);
    try expectTok("js", code, "`t${a}`", .string);
    try expectTok("js", code, "// c", .comment);
    try expectTok("js", code, "K", .type);
}

test "typescript" {
    const code = "interface A { x: number }\n@Component()\nlet y: string = 'q';";
    try expectTok("ts", code, "interface", .keyword);
    try expectTok("ts", code, "A", .type);
    try expectTok("ts", code, "number", .keyword);
    try expectTok("ts", code, "@Component", .function);
    try expectTok("ts", code, "'q'", .string);
}

test "json" {
    const code = "{\"a\": [1, -2.5e3, true, null], \"b\": \"x\"}";
    try expectTok("json", code, "\"a\"", .tag);
    try expectTok("json", code, "1", .number);
    try expectTok("json", code, "2.5e3", .number);
    try expectTok("json", code, "true", .constant);
    try expectTok("json", code, "null", .constant);
    try expectTok("json", code, "\"x\"", .string);
}

test "yaml" {
    const code = "# c\nname: demo\nlist:\n  - a: 1\n  - \"q\"\nflag: true\ntext: |\n  body\nref: &x [1, 2]";
    try expectTok("yaml", code, "# c", .comment);
    try expectTok("yaml", code, "name", .tag);
    try expectTok("yaml", code, "demo", .string);
    try expectTok("yaml", code, "1", .number);
    try expectTok("yaml", code, "\"q\"", .string);
    try expectTok("yaml", code, "true", .constant);
    try expectTok("yaml", code, "body", .string);
    try expectTok("yaml", code, "&x", .variable);
}

test "toml" {
    const code = "# c\n[server]\nhost = \"a\"\nport = 8080\non = true\nd = 1979-05-27\nm = '''\nraw'''";
    try expectTok("toml", code, "# c", .comment);
    try expectTok("toml", code, "[server]", .function);
    try expectTok("toml", code, "\"a\"", .string);
    try expectTok("toml", code, "8080", .number);
    try expectTok("toml", code, "true", .constant);
    try expectTok("toml", code, "1979-05-27", .number);
    try expectTok("toml", code, "'''\nraw'''", .string);
}

test "ini" {
    const code = "; c\n[core]\nname = bob\nn = 3\nok = yes";
    try expectTok("ini", code, "; c", .comment);
    try expectTok("ini", code, "[core]", .function);
    try expectTok("ini", code, "name", .property);
    try expectTok("ini", code, "bob", .string);
    try expectTok("ini", code, "3", .number);
    try expectTok("ini", code, "yes", .constant);
}

test "bash" {
    const code = "#!/bin/sh\nif [ -f \"$HOME/x\" ]; then echo 'a' ${B} $1; fi # c\nfoo() { :; }";
    try expectTok("bash", code, "#!/bin/sh", .comment);
    try expectTok("bash", code, "if", .keyword);
    try expectTok("bash", code, "\"$HOME/x\"", .string);
    try expectTok("bash", code, "echo", .constant);
    try expectTok("bash", code, "'a'", .string);
    try expectTok("bash", code, "${B}", .variable);
    try expectTok("bash", code, "$1", .variable);
    try expectTok("bash", code, "# c", .comment);
    try expectTok("bash", code, "foo", .function);
}

test "powershell" {
    const code = "<# c #>\nfunction Get-X { param($a) if ($a -eq 1) { Write-Host \"hi\" } }\n$env:PATH\n@'\nraw\n'@";
    try expectTok("powershell", code, "<# c #>", .comment);
    try expectTok("powershell", code, "function", .keyword);
    try expectTok("powershell", code, "Get-X", .function);
    try expectTok("powershell", code, "$a", .variable);
    try expectTok("powershell", code, "-eq", .operator);
    try expectTok("powershell", code, "Write-Host", .function);
    try expectTok("powershell", code, "$env:PATH", .variable);
    try expectTok("powershell", code, "@'\nraw\n'@", .string);
}

test "batch" {
    const code = "@echo off\nREM note\n:: c\nset X=%1\necho %X% \"a\"\ngoto :end\n:end";
    try expectTok("bat", code, "echo", .keyword);
    try expectTok("bat", code, "REM note", .comment);
    try expectTok("bat", code, ":: c", .comment);
    try expectTok("bat", code, "%1", .variable);
    try expectTok("bat", code, "%X%", .variable);
    try expectTok("bat", code, "\"a\"", .string);
    try expectTok("bat", code, ":end", .function);
}

test "sql" {
    const code = "-- c\nSELECT count(*), 'a' FROM t WHERE x >= 10 AND y IS NULL;";
    try expectTok("sql", code, "-- c", .comment);
    try expectTok("sql", code, "SELECT", .keyword);
    try expectTok("sql", code, "count", .function);
    try expectTok("sql", code, "'a'", .string);
    try expectTok("sql", code, "10", .number);
    try expectTok("sql", code, "NULL", .constant);
}

test "html" {
    const code = "<!DOCTYPE html>\n<!-- c -->\n<a href=\"x\" disabled>t &amp; u</a>\n<script>let a = 1;</script><style>p { color: red; }</style>";
    try expectTok("html", code, "<!DOCTYPE html>", .constant);
    try expectTok("html", code, "<!-- c -->", .comment);
    try expectTok("html", code, "a", .tag);
    try expectTok("html", code, "href", .attribute);
    try expectTok("html", code, "\"x\"", .string);
    try expectTok("html", code, "disabled", .attribute);
    try expectTok("html", code, "&amp;", .constant);
    try expectTok("html", code, "let", .keyword);
    try expectTok("html", code, "color", .property);
}

test "css" {
    const code = "/* c */\n@media (min-width: 10px) { a.b > #c:hover { color: #fff; margin: -2px 1.5em; background: url(x) !important; } }";
    try expectTok("css", code, "/* c */", .comment);
    try expectTok("css", code, "@media", .keyword);
    try expectTok("css", code, "a", .tag);
    try expectTok("css", code, ".b", .function);
    try expectTok("css", code, "#c", .function);
    try expectTok("css", code, "color", .property);
    try expectTok("css", code, "#fff", .constant);
    try expectTok("css", code, "-2px", .number);
    try expectTok("css", code, "1.5em", .number);
    try expectTok("css", code, "url", .function);
    try expectTok("css", code, "!important", .keyword);
}

test "scss" {
    const code = "$c: red; // note\n.a { &:hover { color: $c; } .b { margin: 0; } }";
    try expectTok("scss", code, "$c", .variable);
    try expectTok("scss", code, "// note", .comment);
    try expectTok("scss", code, "color", .property);
    try expectTok("scss", code, ":hover", .function);
}

test "markdown matches GitHub's token classes" {
    const code = "# H *em*\n> quote **b**\n> - item\n- a\n1. one\n- [ ] task\n`code` ``co`de`` x\n[a](http://b \"T\") ![i](u) <http://auto> <b>\ntext[^1] and [t][ref] and [coll]\n[ref]: <http://d> 'T'\nbare https://e.com/x. mail a@b.co ~~s~~ \\* &amp; <!-- c -->\n```js\nlet x = 1;\n```\n";
    try expectTok("md", code, "# H *em*", .markup_heading);
    try expectTok("md", code, "> quote ", .tag);
    try expectTok("md", code, "-", .variable);
    try expectTok("md", code, "1", .string);
    try expectTok("md", code, ".", .variable);
    try expectTok("md", code, "[ ]", .keyword);
    try expectTok("md", code, "code", .constant);
    try expectTok("md", code, "co`de", .constant);
    try expectTok("md", code, "**", .string);
    try expectTok("md", code, "http://b", .link_url);
    try expectTok("md", code, "T", .string);
    try expectTok("md", code, "![", .string);
    try expectTok("md", code, "http://auto", .link_url);
    try expectTok("md", code, "b", .tag);
    try expectTok("md", code, "1", .function);
    try expectTok("md", code, "ref", .function);
    try expectTok("md", code, "http://d", .link_url);
    try expectTok("md", code, "https://e.com/x", .link_url);
    try expectTok("md", code, "a@b.co", .link_url);
    try expectTok("md", code, "~~", .string);
    try expectTok("md", code, "\\*", .constant);
    try expectTok("md", code, "&amp;", .constant);
    try expectTok("md", code, "<!-- c -->", .comment);
    try expectTok("md", code, "```", .string);
    try expectTok("md", code, "js", .function);
    try expectTok("md", code, "let", .keyword);
}

test "markdown nested emphasis, setext headings, rules, tables and indented code" {
    const code = "**bold *nested em* end**\n\nTitle\n=====\n\nSub\n---\n\n***\n\n| a | b |\n\n    indented\n";
    try expectTok("md", code, "**", .string);
    try expectTok("md", code, "*", .string);
    try expectTok("md", code, "=====", .markup_heading);
    try expectTok("md", code, "---", .markup_heading);
    try expectTok("md", code, "***", .markup_heading);
    try expectTok("md", code, "|", .markup_list);
    try expectTok("md", code, "indented", .constant);
    var list: List = .empty;
    defer list.deinit(testing.allocator);
    try tokens(testing.allocator, "md", "a * b and snake_case_name and *open", &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "diff" {
    const code = "diff --git a b\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@ fn\n-old\n+new\n! chg\n ctx";
    try expectTok("diff", code, "diff --git a b", .constant);
    try expectTok("diff", code, "index 1..2 100644", .constant);
    try expectTok("diff", code, "--- a/f", .diff_removed);
    try expectTok("diff", code, "+++ b/f", .diff_added);
    try expectTok("diff", code, "@@ -1 +1 @@ fn", .diff_heading);
    try expectTok("diff", code, "-old", .diff_removed);
    try expectTok("diff", code, "+new", .diff_added);
    try expectTok("diff", code, "! chg", .diff_changed);
}

test "styles carry line backgrounds and font styling" {
    try testing.expect(style(.diff_added).bg != null and style(.diff_removed).bg != null and style(.diff_changed).bg != null);
    try testing.expect(style(.markup_heading).bold and style(.diff_heading).bold);
    try testing.expect(style(.link_url).underline);
    try testing.expect(style(.keyword).bg == null and style(.punctuation).fg == null);
}

test "dockerfile" {
    const code = "# c\nFROM alpine AS b\nRUN apk add x \\\n  && echo $HOME\nENV A=\"1\"";
    try expectTok("dockerfile", code, "# c", .comment);
    try expectTok("dockerfile", code, "FROM", .keyword);
    try expectTok("dockerfile", code, "AS", .keyword);
    try expectTok("dockerfile", code, "RUN", .keyword);
    try expectTok("dockerfile", code, "$HOME", .variable);
    try expectTok("dockerfile", code, "\"1\"", .string);
}

test "makefile" {
    const code = "# c\nCC := gcc\n.PHONY: all\nall: main.o\n\t$(CC) -o $@ $<\nifeq ($(X),1)\nendif";
    try expectTok("makefile", code, "# c", .comment);
    try expectTok("makefile", code, "CC", .variable);
    try expectTok("makefile", code, ".PHONY", .function);
    try expectTok("makefile", code, "all", .function);
    try expectTok("makefile", code, "$(CC)", .variable);
    try expectTok("makefile", code, "$@", .variable);
    try expectTok("makefile", code, "ifeq", .keyword);
}

test "lua" {
    const code = "--[[ block ]]\nlocal s = [[long\nstr]] -- c\nfunction f(a) return a ~= nil end";
    try expectTok("lua", code, "--[[ block ]]", .comment);
    try expectTok("lua", code, "local", .keyword);
    try expectTok("lua", code, "[[long\nstr]]", .string);
    try expectTok("lua", code, "-- c", .comment);
    try expectTok("lua", code, "f", .function);
    try expectTok("lua", code, "nil", .constant);
}

test "dart" {
    const code = "@override\nclass A extends B { final String s = '''x'''; }";
    try expectTok("dart", code, "@override", .function);
    try expectTok("dart", code, "class", .keyword);
    try expectTok("dart", code, "A", .type);
    try expectTok("dart", code, "'''x'''", .string);
}
