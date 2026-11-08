const std = @import("std");
const parser = @import("parser.zig");

const max_input = 8192;

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var b: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(b[i * s.len ..][0..s.len], s);
        const out = b;
        return &out;
    }
}

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

const corpus = [_][]const u8{
    seed("\\frac{a}{b}"),
    seed("\\text{if }x"),
    seed("\\sum_{i=1}^{n} i"),
    seed("\\left( x \\right)"),
    seed("\\sqrt[3]{x}"),
    seed("\\mathrm{d}x\\mathbb{R}\\mathcal{L}\\mathbf{v}\\hat{x}"),
    seed("\\operatorname{tr}(A)\\int_0^1 f\\prod_i x\\bar{x}\\dfrac{a}{b}\\lim_{x\\to 0} f"),
    seed("\\begin{cases} a & b \\\\ c & d \\end{cases}"),
    seed("\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}"),
    seed("\\begin{array}{c|cc} \\hline a & b & c \\\\ \\hline \\end{array}"),
    seed("\\begin{bmatrix} a & b \\end{bmatrix}\\begin{pmatrix} a \\end{pmatrix}\\begin{matrix} a \\end{matrix}"),
    seed("\\tilde{x}\\overline{x}\\boldsymbol{x}\\underbrace{x}_{n}\\vec{v}\\binom{n}{k}"),
    seed("\\begin{align} a &= b \\end{align}\\xrightarrow{f}\\begin{equation} a \\end{equation}"),
    seed("\\color{red}x\\textcolor{red}{x}\\mathsf{A}\\overset{a}{b}\\substack{a \\\\ b}"),
    seed("\\newcommand{\\R}{\\mathbb{R}}\\R"),
    seed("\\left( \\sum_{k=1}^n a_k b_k \\right)^2 \\leq \\left( \\sum_{k=1}^n a_k^2 \\right) \\left( \\sum_{k=1}^n b_k^2 \\right)"),
    seed("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
    seed("\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}"),
    seed(rep("{", 2000)),
    seed(rep("{", 2000) ++ rep("}", 2000)),
    seed(rep("\\frac{", 500)),
    seed(rep("\\frac{", 90) ++ "x" ++ rep("}{y}", 90)),
    seed(rep("\\left(", 500)),
    seed(rep("\\left(", 90) ++ "x" ++ rep("\\right)", 90)),
    seed(rep("\\begin{pmatrix}", 200)),
    seed(rep("\\begin{pmatrix}", 90) ++ "x" ++ rep("\\end{pmatrix}", 90)),
    seed(rep("x^{", 300) ++ "y"),
    seed(rep("\\sqrt[", 200)),
    seed(rep("\\bf ", 1000) ++ "x"),
    seed(rep("a\\over ", 100) ++ "b"),
    seed("\\def\\a{\\a\\a}\\a"),
    seed("\\newcommand{\\a}{\\a}\\a"),
    seed("\\newcommand{\\x}[9]{#1#2#3#4#5#6#7#8#9#9#9#9#9#9#9#9#9#9}\\x{\\x{1}{2}{3}{4}{5}{6}{7}{8}{9}}{2}{3}{4}{5}{6}{7}{8}{9}"),
    seed("\\def\\a#1{#1#1}\\def\\b#1{\\a{\\a{#1}}}\\def\\c#1{\\b{\\b{#1}}}\\c{\\c{x}}"),
    seed("\\let\\a\\a\\a\\def\\b{\\let\\b\\b}\\b\\b"),
    seed("\\def\\a#1#2#3#4#5#6#7#8#9{#9}\\a"),
    seed("\\newcommand{\\a}[2][x]{#1}\\a[\\a[\\a[y]]]{z}"),
    seed("\\begin{matrix}" ++ rep("a&", 500) ++ rep("\\\\", 500)),
    seed("\\begin{array}{c}" ++ rep("\\\\", 1000) ++ "\\end{array}"),
    seed("\\begin{matrix}" ++ rep("\\hline", 400) ++ "\\end{matrix}"),
    seed("\\begin{matrix}a\\\\[1em]" ++ rep("\\\\[-1pt]", 300)),
    seed("\\begin{align}\\begin{align}"),
    seed("\\left( \\middle| \\middle| \\right)"),
    seed("\\text{" ++ rep("$a$ ", 300)),
    seed("\\text{" ++ rep("\\(", 300)),
    seed("\\text{$\\text{$\\text{$}$}$}"),
    seed("\\hspace{" ++ rep("9", 100) ++ "em}\\kern" ++ rep("-", 50) ++ "1em"),
    seed("\\textcolor[rgb]{" ++ rep("1,", 300) ++ "}{x}\\color[gray]{" ++ rep("9", 200) ++ "}"),
    seed("\\frac\\frac\\frac\\frac\\frac\\frac\\frac"),
    seed("\\sqrt\\sqrt\\sqrt\\sqrt\\sqrt\\sqrt"),
    seed(rep("^", 1000)),
    seed(rep("_^", 1000)),
    seed(rep("'", 2000)),
    seed(rep("\\not", 500) ++ "="),
    seed(rep("\\limits", 300) ++ "\\sum" ++ rep("\\nolimits", 300)),
    seed(rep("\\mathop{\\mathop{", 60) ++ "x" ++ rep("}}", 60)),
    seed(rep("%", 2000)),
    seed(rep("\\", 2000)),
    seed(rep("#", 2000)),
    seed(rep("&", 2000)),
    seed(rep("$", 2000)),
    seed("\xff\xfe\xc0\xaf\xe0\x80\xaf\xf8\x88\x80\x80\x80 \xed\xa0\x80 \xf4\x90\x80\x80"),
    seed("\\frac{\xc3}{\xe2\x82} \\text{\xf0\x9f\x98} x_\xc3 \\\xff \\begin{\xff}"),
    seed("a\x00b\\\x00c{\x00}^\x00_\x00\\text{\x00}"),
    seed(rep("\x00", 512)),
    seed("\\begin{" ++ rep("m", 3000) ++ "}"),
    seed("\\" ++ rep("a", 3000)),
    seed("\\newcommand{\\" ++ rep("a", 3000) ++ "}{x}"),
};

fn parseOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var t = try parser.parse(std.testing.allocator, input, .{});
    defer t.deinit();
    const d = try parser.dump(std.testing.allocator, t.root);
    std.testing.allocator.free(d);
}

test "fuzz math.parse" {
    try std.testing.fuzz({}, parseOne, .{ .corpus = &corpus });
}

test "seeds parse within the caps" {
    for (corpus) |s| {
        var t = try parser.parse(std.testing.allocator, s[4..], .{});
        t.deinit();
    }
}

pub const deep_cases = [_][]const u8{
    rep("{", 99) ++ "x" ++ rep("}", 99),
    rep("\\frac{", 99) ++ "x" ++ rep("}{y}", 99),
    rep("x^{", 99) ++ "y" ++ rep("}", 99),
    rep("\\left(", 99) ++ "x" ++ rep("\\right)", 99),
    rep("\\begin{pmatrix}", 99) ++ "x" ++ rep("\\end{pmatrix}", 99),
    rep("\\sqrt[3]{", 99) ++ "x" ++ rep("}", 99),
    rep("\\mathbf{", 99) ++ "x" ++ rep("}", 99),
    rep("\\text{$", 40) ++ "x" ++ rep("$}", 40),
    rep("\\textcolor{red}{", 99) ++ "x" ++ rep("}", 99),
    rep("\\overbrace{", 99) ++ "x" ++ rep("}^{y}", 99),
    rep("\\{", 2000) ++ rep("{", 2000),
};

const past_braces = rep("{", 1000) ++ "x" ++ rep("}", 1000);
const past_frac = rep("\\frac{", 500);

test "past the nesting cap is an error, not a crash" {
    var t = try parser.parse(std.testing.allocator, past_braces, .{});
    defer t.deinit();
    try std.testing.expect(t.err != null);
    var u = try parser.parse(std.testing.allocator, past_frac, .{});
    defer u.deinit();
    try std.testing.expect(u.err != null);
}
