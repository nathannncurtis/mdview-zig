const std = @import("std");
const font = @import("font");
const parser = @import("parser.zig");
const layout = @import("layout.zig");
const scene = @import("scene.zig");

const max_input = 4096;

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

const corpus = [_][]const u8{
    seed("x^2 + \\frac{a}{b}"),
    seed("\\sum_{i=1}^{n} i^2 = \\frac{n(n+1)(2n+1)}{6}"),
    seed("\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}"),
    seed("\\left( \\frac{a}{\\frac{b}{c}} \\middle| x \\right)"),
    seed("\\bigg( x \\Bigg]"),
    seed("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
    seed("\\begin{cases} x & x > 0 \\\\ -x & x \\le 0 \\end{cases}"),
    seed("\\begin{aligned} a &= b + c \\\\ d &= e \\end{aligned}"),
    seed("\\begin{array}{c|c} a & b \\\\ \\hline c & d \\end{array}"),
    seed("\\sqrt[3]{\\sqrt{x}} \\hat{x} \\widehat{xyz} \\overline{AB} \\underline{x}"),
    seed("\\overbrace{x+y+z}^{n} \\underbrace{abc}_{m} \\xrightarrow[g]{f} \\overset{a}{=}"),
    seed("\\text{if } x \\textbf{bold} \\mathbb{R} \\mathcal{L} \\mathfrak{g} \\boldsymbol{x}"),
    seed("\\color{red}{x} \\boxed{y} \\not= \\phantom{z} \\smash{w} \\rule{1em}{2pt}"),
    seed("\\sideset{_a^b}{_c^d}\\sum x \\raise2pt x \\llap{x}y \\vcenter{x}"),
    seed("\\begin{CD} A @>f>> B \\\\ @VVV @AAA \\\\ C @= D \\end{CD}"),
    seed("\\lim_{x \\to 0} \\frac{\\sin x}{x} \\operatorname{tr}(A)"),
    seed("{{{{{{{{{{x^{y^{z^{w}}}}}}}}}}}}"),
    seed("\\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e}"),
    seed("\\left(\\left(\\left(\\left(x\\right)\\right)\\right)\\right)"),
    seed("\\begin{matrix}\\begin{matrix}\\begin{matrix}x\\end{matrix}\\end{matrix}\\end{matrix}"),
    seed("\\mathchoice{a}{b}{c}{d}\\displaystyle\\sum_i x\\textstyle\\scriptstyle y"),
};

fn layoutOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var t = try parser.parse(std.testing.allocator, input, .{});
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = font.embeddedMathFont(std.testing.io);
    const box = try layout.layout(a, &t, f, .{ .size = 16, .display = smith.value(bool) });
    const svg = scene.toSvg(a, box, 0) catch |e| switch (e) {
        error.TooLarge => return,
        else => |x| return x,
    };
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
}

test "fuzz math.layout" {
    try std.testing.fuzz({}, layoutOne, .{ .corpus = &corpus });
}

test "seeds lay out and render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = font.embeddedMathFont(std.testing.io);
    for (corpus) |s| {
        var t = try parser.parse(std.testing.allocator, s[4..], .{});
        defer t.deinit();
        const box = try layout.layout(arena.allocator(), &t, f, .{ .size = 16, .display = true });
        try std.testing.expect(std.math.isFinite(box.w) and std.math.isFinite(box.h) and std.math.isFinite(box.d));
        _ = try scene.toSvg(arena.allocator(), box, 0);
    }
}
