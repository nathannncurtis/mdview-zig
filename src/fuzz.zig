const std = @import("std");
const markdown = @import("markdown.zig");

const max_input = 8192;

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var b: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(b[i * s.len ..][0..s.len], s);
        const out = b;
        return &out;
    }
}

fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, bytes.len));
        const out = len ++ bytes.*;
        return &out;
    }
}

const corpus = [_][]const u8{
    seed("# Title\n\nSome *emphasis*, **strong**, `code` and a [link](http://x).\n"),
    seed(rep("> ", 400) ++ "deep quote\n"),
    seed("- a\n" ++ rep("  - a\n", 200)),
    seed("1. a\n" ++ rep("   1. a\n", 200)),
    seed("```zig\nconst x = 1;\n"),
    seed("~~~\n```\n~~~~\n````\n"),
    seed(rep("*", 2000)),
    seed(rep("_", 2000)),
    seed(rep("**_", 500) ++ "x" ++ rep("_**", 500)),
    seed(rep("[", 1000) ++ rep("](", 100)),
    seed(rep("[a](", 300)),
    seed(rep("|", 2000)),
    seed("| a | b |\n|---|:-:|\n| 1 | 2 | 3 |\n| \\| |\n"),
    seed("|a|\n|-|\n" ++ rep("|\\|", 500)),
    seed(rep("`", 1000)),
    seed("\xff\xfe\xc0\xaf\xe0\x80\xaf\xf8\x88\x80\x80\x80 \xed\xa0\x80 \xf4\x90\x80\x80"),
    seed("caf\xc3 \xe2\x82 \xf0\x9f\x98 *\xc3*\n"),
    seed("line one\r\nline two\r\n\r\n- item\r\n\r\n```\r\ncode\r\n```\r\n"),
    seed("a\rb\rc\r\r# h\r"),
    seed("a\x00b\x00*\x00*\x00\n\x00\n```\x00\n"),
    seed(rep("\x00", 512)),
    seed("---\n***\n___\n- - -\n* * *\n"),
    seed(rep("# ", 100) ++ "\n" ++ rep("#", 300) ++ "\n"),
    seed(rep("\n", 3000)),
    seed(rep(" ", 4000) ++ "x\n"),
    seed("> - a\n>   > 1. b\n>   >    - [ ] c\n>   > \x60\x60\x60\n>   > code\n- > - > - > x\n"),
    seed("---\na: &x [1, *x]\nb: !!str &y !<tag:yaml.org,2002:int> 5\nc: *y\n? [k]\n: v\n---\ntext\n"),
    seed("---\na: &a1 *a1\n%TAG ! tag:x,2000:\nk: !e!t \"unterminated\n"),
    seed("---\n" ++ rep("- ", 300) ++ "x"),
    seed("Text[^1] and [^2] and [^1]\n\n[^1]: note\n    more [^2]\n\n[^2]: [^1]\n"),
    seed("[a][b] [b][] [b] ![i][b]\n\n[b]: <u> \"t\"\n[c]: u\n[B]: dup\n"),
    seed(rep("[a][a]", 300) ++ "\n\n[a]: ["),
    seed("- | a | b |\n  |---|---|\n  | 1 | 2 |\n  - | x |\n    |---|\n    | | a | b | |\n"),
    seed("> [!NOTE]\n> text\n> [!WARNING]\n> - [!TIP]\n\n[!CAUTION]\n> [!IMPORTANT]\n"),
    seed("> [!NOTE" ++ rep("> ", 200) ++ "[!TIP]\n"),
    seed("&amp; &#0; &#x110000; &#xD800; &#99999999999; &bogus; &"),
    seed("\xe2\x82*a* \xf0\x9f\x98_b_ \x80**c** \xc3\xa9**d**"),
    seed(":smile: :+1: :nope: ::: :a"),
};

fn parseOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var doc = try markdown.parse(std.testing.allocator, input);
    doc.deinit();
}

test "fuzz markdown.parse" {
    try std.testing.fuzz({}, parseOne, .{ .corpus = &corpus });
}
