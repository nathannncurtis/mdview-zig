const std = @import("std");
const Allocator = std.mem.Allocator;
const files = @import("files.zig");

const languages = [_][]const u8{
    "c",          "cpp",        "csharp",   "go",       "rust",   "zig",       "java",     "kotlin",
    "swift",      "python",     "ruby",     "php",      "javascript", "typescript", "json", "yaml",
    "toml",       "ini",        "bash",     "powershell", "batch", "sql",       "html",     "css",
    "scss",       "markdown",   "diff",     "dockerfile", "makefile", "lua",    "dart",
};

const Scale = struct {
    full: bool,

    fn pick(s: Scale, full: usize, small: usize) usize {
        return if (s.full) full else small;
    }
};

const Out = struct {
    a: Allocator,
    io: std.Io,
    dir: []const u8,
    buf: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn add(o: *Out, bytes: []const u8) !void {
        try o.buf.appendSlice(o.a, bytes);
    }

    fn print(o: *Out, comptime fmt: []const u8, args: anytype) !void {
        try o.buf.print(o.a, fmt, args);
    }

    fn repeat(o: *Out, bytes: []const u8, times: usize) !void {
        try o.buf.ensureUnusedCapacity(o.a, bytes.len * times);
        for (0..times) |_| o.buf.appendSliceAssumeCapacity(bytes);
    }

    fn fill(o: *Out, bytes: []const u8, size: usize) !void {
        try o.repeat(bytes, size / bytes.len + 1);
        o.buf.shrinkRetainingCapacity(@min(o.buf.items.len, size));
    }

    fn finish(o: *Out, name: []const u8) !void {
        const path = try std.fs.path.join(o.a, &.{ o.dir, name });
        defer o.a.free(path);
        try files.write(o.io, path, o.buf.items);
        files.say(o.io, "{s}: {d} bytes\n", .{ name, o.buf.items.len });
        o.buf.clearRetainingCapacity();
        o.count += 1;
    }
};

const realistic =
    \\## Section {d}
    \\
    \\Some *emphasis*, **strong**, ~~strike~~, `inline code` and a [link](https://example.com/{d}) with
    \\an image ![alt](pic{d}.png) and a footnote.[^{d}] Entities &amp; &#x1F600; and :smile: too.
    \\
    \\> quoted text with `code`
    \\> - nested item
    \\
    \\1. one
    \\2. two
    \\   - [ ] task
    \\   - [x] done
    \\
    \\| a | b | c |
    \\|---|:-:|--:|
    \\| 1 | `2` | 3 |
    \\
    \\```zig
    \\const x: u32 = {d};
    \\```
    \\
    \\[^{d}]: the note
    \\
;

fn realisticDoc(o: *Out, bytes: usize) !void {
    var i: usize = 0;
    while (o.buf.items.len < bytes) : (i += 1) try o.print(realistic, .{ i, i, i, i, i, i });
}

const code_samples = [_][]const u8{
    "int main(void) { /* \" ' \\ */ return 0; } // x\n#define A(x) \"%s\" x '\\\n",
    "def f(x):\n    '''doc \"\"\" ` $( << # {{ [[ (* <!--\n    return f\"{x}\" + r'\\'\n",
    "<div class=\"a\"><!-- c --><script>var s = `${1}`; /* \" */</script><style>a{b:c;/*}</style>\n",
    "SELECT 'a''b', \"c\", `d`, /* e */ -- f\nFROM t WHERE x = $$ y $$;\n",
    "echo \"$(date) `x` $((1+1))\" <<EOF\nx\nEOF\n# c ${a:-b} 'q\n",
    "-- c\n--[==[ long ]==]\nlocal s = [[a\nb]] .. \"x\\\"\"\n",
    "---\na: &x [1, *x]\nb: |\n  text\n? c\n: - d\n",
    "{\"a\": [1, 2.5e10, \"\\u00e9\\\"\", null, {\"b\": true}]}\n",
    "FROM x AS y\nRUN a && \\\n  b # c\nCMD [\"a\", 'b']\nall: dep\n\t@echo $(VAR) $$x\n",
    "@@ -1,2 +1,2 @@\n-old\n+new\n context\n\\ No newline\n",
};

const openers = "a /* \" ' ''' \"\"\" ` $( << #{ {{ [[ (* <!-- /// --[[ =begin <<-EOS r#\" @\" ${ \n";

fn codeFile(o: *Out, lang: []const u8, size: usize, index: usize) !void {
    try o.print("# {s}\n\n```{s}\n", .{ lang, lang });
    const body_end = o.buf.items.len + size;
    var i = index;
    while (o.buf.items.len < body_end) : (i += 1) {
        try o.add(code_samples[i % code_samples.len]);
        try o.add(openers);
    }
    if (index % 2 == 1) {
        try o.add("\n");
        const long = size / 2;
        try o.repeat("x", long);
    }
    try o.add("\n```\n");
}

fn nest(o: *Out, open: []const u8, text: []const u8, close: []const u8, depth: usize) !void {
    try o.repeat(open, depth);
    try o.add(text);
    try o.repeat(close, depth);
    try o.add("\n");
}

fn deepList(o: *Out, depth: usize) !void {
    for (0..depth) |level| {
        try o.repeat(" ", level * 2);
        try o.add("- item\n");
    }
}

fn deepOrdered(o: *Out, depth: usize) !void {
    for (0..depth) |level| {
        try o.repeat(" ", level * 3);
        try o.add("1. item\n");
    }
}

fn deepQuoteList(o: *Out, depth: usize) !void {
    for (0..depth) |_| try o.add("> - ");
    try o.add("x\n");
}

fn table(o: *Out, rows: usize, cols: usize) !void {
    for (0..cols) |c| try o.print("| h{d} ", .{c});
    try o.add("|\n");
    for (0..cols) |_| try o.add("|---");
    try o.add("|\n");
    for (0..rows) |r| {
        for (0..cols) |c| try o.print("| `{d}` *{d}* ", .{ r, c });
        try o.add("|\n");
    }
}

fn aliasBomb(o: *Out, levels: usize) !void {
    try o.add("---\na: &a0 [x, x, x, x, x, x, x, x, x]\n");
    for (1..levels) |i| {
        try o.print("a{d}: &a{d} [", .{ i, i });
        for (0..9) |k| try o.print("{s}*a{d}", .{ if (k == 0) "" else ", ", i - 1 });
        try o.add("]\n");
    }
    try o.print("bomb: *a{d}\n---\n\ntext\n", .{levels - 1});
}

fn pathological(o: *Out, comptime name: []const u8, unit: []const u8, size: usize) !void {
    try o.fill(unit, size);
    try o.add("\n");
    try o.finish("path_" ++ name ++ ".md");
}

fn ramp(o: *Out, tick: u8, upto: usize) !void {
    for (1..upto) |i| {
        try o.repeat(&.{tick}, i);
        try o.add("x ");
    }
    try o.add("\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or args.len > 3) {
        files.say(io, "usage: gen-stress <outdir> [small]\n", .{});
        return error.Usage;
    }
    const scale: Scale = .{ .full = !(args.len == 3 and std.mem.eql(u8, args[2], "small")) };
    try std.Io.Dir.cwd().createDirPath(io, args[1]);
    var o: Out = .{ .a = arena, .io = io, .dir = args[1] };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();

    try realisticDoc(&o, scale.pick(50 << 20, 2 << 20));
    try o.finish("big_document.md");

    for (0..scale.pick(100_000, 10_000)) |i| try o.print("Paragraph {d} with *emphasis* and `code`.\n\n", .{i});
    try o.finish("paragraphs.md");

    try o.fill("abcdefghij", scale.pick(5 << 20, 256 << 10));
    try o.finish("line_no_spaces.md");
    try o.fill("a*b_c`d[e]f(g)h<i>j!k|l~m\\n&o:p", scale.pick(5 << 20, 256 << 10));
    try o.finish("line_punctuation.md");
    try o.fill("word ", scale.pick(5 << 20, 256 << 10));
    try o.finish("line_words.md");

    try nest(&o, "> ", "deep\n", "", scale.pick(10_000, 10_000));
    try o.finish("nest_quote_inline.md");
    try deepQuoteList(&o, scale.pick(10_000, 10_000));
    try o.finish("nest_quote_list.md");
    try nest(&o, "- ", "x", "", 10_000);
    try o.finish("nest_list.md");
    try nest(&o, "1. ", "x", "", 10_000);
    try o.finish("nest_ordered.md");
    try nest(&o, "[^a]: ", "x", "", 10_000);
    try o.finish("nest_footnote.md");
    try deepList(&o, scale.pick(2_000, 600));
    try o.finish("nest_list_indent.md");
    try deepOrdered(&o, scale.pick(2_000, 600));
    try o.finish("nest_ordered_indent.md");
    try nest(&o, "*a ", "x", "* ", scale.pick(10_000, 10_000));
    try o.finish("nest_emphasis_star.md");
    try nest(&o, "_a ", "x", "_ ", scale.pick(10_000, 10_000));
    try o.finish("nest_emphasis_underscore.md");
    try nest(&o, "**a ", "x", "** ", scale.pick(10_000, 10_000));
    try o.finish("nest_strong.md");
    try nest(&o, "[", "x", "]", scale.pick(10_000, 10_000));
    try o.finish("nest_brackets.md");
    try nest(&o, "[", "x", "](y)", scale.pick(10_000, 10_000));
    try o.finish("nest_links.md");
    try nest(&o, "![", "x", "](y)", scale.pick(10_000, 10_000));
    try o.finish("nest_images.md");
    try nest(&o, "(", "x", ")", scale.pick(10_000, 10_000));
    try o.finish("nest_parens.md");
    try nest(&o, "~~a ", "x", "~~ ", scale.pick(10_000, 10_000));
    try o.finish("nest_strike.md");

    try table(&o, scale.pick(10_000, 2_000), 5);
    try o.finish("table_rows.md");
    try table(&o, 20, 500);
    try o.finish("table_columns.md");
    try table(&o, scale.pick(1_000, 200), 500);
    try o.finish("table_rows_columns.md");

    const notes = scale.pick(100_000, 10_000);
    for (0..notes) |i| try o.print("Ref[^{d}] and [^{d}] and [r{d}].\n\n", .{ i, notes - i, i });
    for (0..notes) |i| try o.print("[^{d}]: note {d} [^{d}]\n\n[r{d}]: /u{d} \"t\"\n\n", .{ i, i, (i + 1) % notes, i, i });
    try o.finish("footnotes_references.md");

    try o.add("---\n");
    for (0..scale.pick(400_000, 20_000)) |i| try o.print("key{d}: value {d} with some text\n", .{ i, i });
    try o.add("---\n\ntext\n");
    try o.finish("frontmatter_huge.md");
    try o.add("---\n");
    try o.repeat("[", scale.pick(10_000, 10_000));
    try o.repeat("]", scale.pick(10_000, 10_000));
    try o.add("\n---\n\ntext\n");
    try o.finish("yaml_flow_deep.md");
    try o.add("---\n");
    try o.repeat("{a: ", scale.pick(10_000, 10_000));
    try o.add("x");
    try o.repeat("}", scale.pick(10_000, 10_000));
    try o.add("\n---\n\ntext\n");
    try o.finish("yaml_map_deep.md");
    try o.add("---\n");
    for (0..scale.pick(3_000, 1_000)) |level| {
        try o.repeat(" ", level);
        try o.add("k:\n");
    }
    try o.add("---\n\ntext\n");
    try o.finish("yaml_block_deep.md");
    try o.add("---\n");
    try o.repeat("- ", scale.pick(10_000, 10_000));
    try o.add("x\n---\n\ntext\n");
    try o.finish("yaml_seq_deep.md");
    try aliasBomb(&o, 12);
    try o.finish("yaml_alias_bomb.md");
    try o.add("---\na: &a [*a, *a]\nb: &b {x: *b, y: *b}\nc: *c\n---\n\ntext\n");
    try o.finish("yaml_alias_cycle.md");

    for (languages, 0..) |lang, i| {
        try codeFile(&o, lang, scale.pick(1 << 20, 64 << 10), i);
        const name = try std.fmt.allocPrint(arena, "code_{s}.md", .{lang});
        try o.finish(name);
    }

    const garbage = try arena.alloc(u8, scale.pick(1 << 20, 100 << 10));
    rng.bytes(garbage);
    try o.add(garbage);
    try o.finish("binary_garbage.md");
    for (garbage) |*b| b.* = if (b.* % 7 == 0) 0 else if (b.* % 5 == 0) 0x80 | (b.* & 0x3f) else b.* & 0x7f;
    try o.add(garbage);
    try o.finish("nul_and_continuation_bytes.md");
    try o.repeat("\x00", scale.pick(1 << 20, 100 << 10));
    try o.finish("nul_only.md");
    try o.repeat("# h \xff\xfe *\xc3* `\xe2\x82` [\xf0\x9f](\x98) \xed\xa0\x80 \xc0\xaf\n", scale.pick(50_000, 5_000));
    try o.finish("invalid_utf8.md");
    try o.repeat("\xf0\x9f\x98", scale.pick(300_000, 30_000));
    try o.finish("truncated_emoji.md");

    var lines: usize = 0;
    while (lines < scale.pick(200_000, 20_000)) : (lines += 1) {
        try o.print("line {d} *a*", .{lines});
        try o.add(switch (rng.uintLessThan(u8, 4)) {
            0 => "\r\n",
            1 => "\n",
            2 => "\r",
            else => "\r\r\n\n",
        });
    }
    try o.finish("line_endings_mixed.md");
    try o.repeat("- a\r\n  - b\r- c\n\r\n", scale.pick(50_000, 5_000));
    try o.finish("line_endings_lists.md");

    try o.finish("empty.md");
    try o.add("\xef\xbb\xbf");
    try o.finish("bom_only.md");
    try o.add("\xef\xbb\xbf\xef\xbb\xbf\xef\xbb\xbf---\n---\n");
    try o.finish("bom_repeated.md");

    try o.repeat("\xf0\x9f\x98\x80\xe2\x9d\xa4\xef\xb8\x8f\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 ", scale.pick(200_000, 20_000));
    try o.finish("emoji_flood.md");
    try o.repeat(":smile: :+1: :nope: :: :a ", scale.pick(200_000, 20_000));
    try o.finish("emoji_shortcodes.md");
    try o.repeat("&amp; &#0; &#x110000; &#xD800; &#99999999999; &bogus; &copy &#x1F600; &", scale.pick(200_000, 20_000));
    try o.finish("entity_flood.md");

    const unit = scale.pick(1 << 20, 200 << 10);
    try pathological(&o, "emphasis_mix", "*a**b***c", unit);
    try pathological(&o, "emphasis_open", "*a ", unit);
    try pathological(&o, "emphasis_underscore", "_a__b___c", unit);
    try pathological(&o, "emphasis_close", "a* ", unit);
    try pathological(&o, "brackets_open", "[a", unit);
    try pathological(&o, "brackets_empty", "[]", unit);
    try pathological(&o, "links_open", "[a](", unit);
    try pathological(&o, "links_space_paren", "[ (](", unit);
    try pathological(&o, "links_ref", "[a][", unit);
    try pathological(&o, "images_open", "![a", unit);
    try pathological(&o, "links_unmatched", "[a](<b", unit);
    try pathological(&o, "angle", "<a ", unit);
    try pathological(&o, "angle_comment", "<!--", unit);
    try pathological(&o, "angle_attr", "<a href=\"", unit);
    try pathological(&o, "autolink", "<http://x", unit);
    try pathological(&o, "www", "www.a", unit);
    try pathological(&o, "escapes", "\\", unit);
    try pathological(&o, "strike", "~~a", unit);
    try pathological(&o, "footnote_refs", "[^a]", unit);
    try pathological(&o, "footnote_open", "[^", unit);
    try pathological(&o, "hr", "* * *\n", unit);
    try pathological(&o, "html_blocks", "<div>\n", unit);
    try pathological(&o, "setext", "a\n===\n", unit);
    try pathological(&o, "fence_open", "```\n", unit);
    try pathological(&o, "fence_tilde", "~~~\n", unit);
    try pathological(&o, "pipes", "|", unit);
    try pathological(&o, "table_rows", "|a|b|\n|-|-|\n", unit);
    try pathological(&o, "indent", "    ", unit);
    try pathological(&o, "newlines", "\n", unit);
    try pathological(&o, "alerts", "> [!NOTE]\n> a\n\n", unit);
    try pathological(&o, "task", "- [ ] a\n", unit);
    try ramp(&o, '`', scale.pick(1_400, 600));
    try o.finish("path_backtick_ramp.md");
    try ramp(&o, '~', scale.pick(1_400, 600));
    try o.finish("path_tilde_ramp.md");
    try ramp(&o, '*', scale.pick(1_400, 600));
    try o.finish("path_star_ramp.md");
    try ramp(&o, '[', scale.pick(1_400, 600));
    try o.finish("path_bracket_ramp.md");

    files.say(io, "{d} files in {s}\n", .{ o.count, args[1] });
}
