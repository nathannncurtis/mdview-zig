const std = @import("std");

pub const BlockKind = enum { h1, h2, h3, paragraph, code_block, blockquote, hr, list_item, blank };

pub const Block = struct {
    kind: BlockKind,
    text: []const u8,
    bold_ranges: [16][2]u32 = undefined,
    bold_count: u32 = 0,
    italic_ranges: [16][2]u32 = undefined,
    italic_count: u32 = 0,
    code_ranges: [16][2]u32 = undefined,
    code_count: u32 = 0,
};

pub const MAX_BLOCKS = 1024;
pub const TEXT_BUF_SIZE = 256 * 1024;

pub var blocks: [MAX_BLOCKS]Block = undefined;
pub var block_count: usize = 0;
pub var text_buf: [TEXT_BUF_SIZE]u8 = undefined;
pub var text_len: usize = 0;

pub fn parse(markdown: []const u8) void {
    block_count = 0;
    text_len = 0;

    var in_code = false;
    var code_start: usize = 0;
    var lines = std.mem.splitScalar(u8, markdown, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code) {
                const text = text_buf[code_start..text_len];
                addBlock(.code_block, text);
                in_code = false;
            } else {
                in_code = true;
                code_start = text_len;
            }
            continue;
        }

        if (in_code) {
            appendText(line);
            appendText("\n");
            continue;
        }

        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "***") or std.mem.startsWith(u8, line, "___")) {
            addBlock(.hr, "");
            continue;
        }

        if (std.mem.startsWith(u8, line, "### ")) {
            addInlineBlock(.h3, line[4..]);
        } else if (std.mem.startsWith(u8, line, "## ")) {
            addInlineBlock(.h2, line[3..]);
        } else if (std.mem.startsWith(u8, line, "# ")) {
            addInlineBlock(.h1, line[2..]);
        } else if (std.mem.startsWith(u8, line, "> ")) {
            addInlineBlock(.blockquote, line[2..]);
        } else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            addInlineBlock(.list_item, line[2..]);
        } else if (line.len > 2 and line[0] >= '0' and line[0] <= '9' and std.mem.indexOf(u8, line, ". ") != null) {
            const dot = std.mem.indexOf(u8, line, ". ").?;
            addInlineBlock(.list_item, line[dot + 2 ..]);
        } else if (std.mem.startsWith(u8, line, "<")) {
            continue;
        } else {
            addInlineBlock(.paragraph, line);
        }
    }
}

fn appendText(text: []const u8) void {
    if (text_len + text.len > text_buf.len) return;
    @memcpy(text_buf[text_len..][0..text.len], text);
    text_len += text.len;
}

fn addBlock(kind: BlockKind, text: []const u8) void {
    if (block_count >= blocks.len) return;
    blocks[block_count] = .{ .kind = kind, .text = text };
    block_count += 1;
}

fn addInlineBlock(kind: BlockKind, raw: []const u8) void {
    if (block_count >= blocks.len) return;
    const start = text_len;

    var block = Block{ .kind = kind, .text = undefined };
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 1 < raw.len and raw[i] == '*' and raw[i + 1] == '*') {
            const end = std.mem.indexOf(u8, raw[i + 2 ..], "**");
            if (end) |e| {
                const pos: u32 = @intCast(text_len - start);
                appendText(raw[i + 2 ..][0..e]);
                if (block.bold_count < block.bold_ranges.len) {
                    block.bold_ranges[block.bold_count] = .{ pos, @intCast(e) };
                    block.bold_count += 1;
                }
                i += e + 4;
                continue;
            }
        }
        if (raw[i] == '*' and (i + 1 >= raw.len or raw[i + 1] != '*')) {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '*');
            if (end) |e| {
                const pos: u32 = @intCast(text_len - start);
                appendText(raw[i + 1 .. e]);
                if (block.italic_count < block.italic_ranges.len) {
                    block.italic_ranges[block.italic_count] = .{ pos, @intCast(e - i - 1) };
                    block.italic_count += 1;
                }
                i = e + 1;
                continue;
            }
        }
        if (raw[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '`');
            if (end) |e| {
                const pos: u32 = @intCast(text_len - start);
                appendText(raw[i + 1 .. e]);
                if (block.code_count < block.code_ranges.len) {
                    block.code_ranges[block.code_count] = .{ pos, @intCast(e - i - 1) };
                    block.code_count += 1;
                }
                i = e + 1;
                continue;
            }
        }
        if (raw[i] == '!' and i + 1 < raw.len and raw[i + 1] == '[') {
            if (parseLinkOrImage(raw, i + 1)) |result| {
                if (result.text.len > 0) appendText(result.text);
                i = result.end;
                continue;
            }
        }
        if (raw[i] == '[') {
            if (parseLinkOrImage(raw, i)) |result| {
                if (result.text.len > 0) appendText(result.text);
                i = result.end;
                continue;
            }
        }
        appendByte(raw[i]);
        i += 1;
    }

    block.text = text_buf[start..text_len];
    blocks[block_count] = block;
    block_count += 1;
}

const LinkResult = struct { text: []const u8, end: usize };

fn parseLinkOrImage(raw: []const u8, start: usize) ?LinkResult {
    if (start >= raw.len or raw[start] != '[') return null;
    var depth: i32 = 0;
    var j = start;
    while (j < raw.len) : (j += 1) {
        if (raw[j] == '[') depth += 1;
        if (raw[j] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (j >= raw.len) return null;
    const bracket_end = j;
    if (bracket_end + 1 >= raw.len or raw[bracket_end + 1] != '(') return null;
    var paren_depth: i32 = 0;
    var k = bracket_end + 1;
    while (k < raw.len) : (k += 1) {
        if (raw[k] == '(') paren_depth += 1;
        if (raw[k] == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) break;
        }
    }
    if (k >= raw.len) return null;
    return .{ .text = raw[start + 1 .. bracket_end], .end = k + 1 };
}

fn appendByte(b: u8) void {
    if (text_len < text_buf.len) {
        text_buf[text_len] = b;
        text_len += 1;
    }
}

// Syntax highlighting helpers (used by platform renderers)
pub const hl_keywords = [_][]const u8{
    "fn",       "const",    "var",      "return",   "if",       "else",
    "while",    "for",      "break",    "continue", "switch",   "pub",
    "struct",   "enum",     "union",    "defer",    "try",      "catch",
    "import",   "export",   "default",  "async",    "await",    "class",
    "function", "let",      "def",      "self",     "true",     "false",
    "null",     "undefined", "None",    "True",     "False",    "nil",
    "use",      "mod",      "impl",     "trait",    "type",     "match",
    "mut",      "ref",      "unsafe",   "move",     "static",   "extern",
    "crate",    "super",    "where",    "yield",    "from",     "with",
    "as",       "in",       "not",      "and",      "or",       "pass",
    "raise",    "except",   "finally",  "lambda",   "elif",     "del",
    "global",   "nonlocal", "assert",   "package",  "chan",     "go",
    "select",   "fallthrough", "range", "interface", "map",     "func",
    "void",     "int",      "float",    "double",   "char",     "bool",
    "string",   "println",  "printf",   "print",
};

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '@';
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}
