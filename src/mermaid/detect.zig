const std = @import("std");
const config_mod = @import("config.zig");
const preprocess = @import("preprocess.zig");

pub const Config = config_mod.Config;

pub const Detector = struct {
    id: []const u8,
    test_fn: *const fn (txt: []const u8, cfg: ?*const Config) bool,
};

/// JS `\s`: what `/^\s*/` skips.
pub fn skipSpace(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const n = spaceLen(s[i..]);
        if (n == 0) break;
        i += n;
    }
    return i;
}

fn spaceLen(s: []const u8) usize {
    switch (s[0]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => return 1,
        else => {},
    }
    if (s[0] < 0x80) return 0;
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (len > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[0..len]) catch return 0;
    return switch (cp) {
        0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => len,
        0x2000...0x200a => len,
        else => 0,
    };
}

pub fn trimStart(s: []const u8) []const u8 {
    return s[skipSpace(s)..];
}

pub fn trim(s: []const u8) []const u8 {
    var t = trimStart(s);
    while (t.len > 0) {
        var cut: usize = 0;
        var i = t.len;
        while (i > 0) {
            i -= 1;
            if (t[i] & 0xc0 == 0x80) continue;
            if (spaceLen(t[i..]) == t.len - i) {
                cut = t.len - i;
            }
            break;
        }
        if (cut == 0) break;
        t = t[0 .. t.len - cut];
    }
    return t;
}

fn after(txt: []const u8, word: []const u8) ?[]const u8 {
    const t = trimStart(txt);
    return if (std.mem.startsWith(u8, t, word)) t[word.len..] else null;
}

fn afterNoCase(txt: []const u8, word: []const u8) ?[]const u8 {
    const t = trimStart(txt);
    return if (std.ascii.startsWithIgnoreCase(t, word)) t[word.len..] else null;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn starts(comptime word: []const u8) *const fn ([]const u8, ?*const Config) bool {
    return struct {
        fn f(txt: []const u8, _: ?*const Config) bool {
            return after(txt, word) != null;
        }
    }.f;
}

fn startsNoCase(comptime word: []const u8) *const fn ([]const u8, ?*const Config) bool {
    return struct {
        fn f(txt: []const u8, _: ?*const Config) bool {
            return afterNoCase(txt, word) != null;
        }
    }.f;
}

fn c4(txt: []const u8, _: ?*const Config) bool {
    // The upstream regex has no group around the alternation, so every name but the first matches anywhere.
    if (after(txt, "C4Context") != null) return true;
    for ([_][]const u8{ "C4Container", "C4Component", "C4Dynamic", "C4Deployment" }) |w| {
        if (std.mem.indexOf(u8, txt, w) != null) return true;
    }
    return false;
}

fn flowchartV2(txt: []const u8, _: ?*const Config) bool {
    return after(txt, "graph") != null or after(txt, "flowchart") != null;
}

fn wordEnd(rest: []const u8) bool {
    return rest.len == 0 or !isWord(rest[0]);
}

fn swimlane(txt: []const u8, _: ?*const Config) bool {
    return if (after(txt, "swimlane-beta")) |r| wordEnd(r) else false;
}

fn agentflow(txt: []const u8, _: ?*const Config) bool {
    return if (after(txt, "agentflow-beta")) |r| wordEnd(r) else false;
}

fn usecase(txt: []const u8, _: ?*const Config) bool {
    const r = after(txt, "usecase-beta") orelse return false;
    return r.len == 0 or spaceLen(r) > 0;
}

fn ishikawa(txt: []const u8, _: ?*const Config) bool {
    return if (afterNoCase(txt, "ishikawa")) |r| wordEnd(r) else false;
}

fn cynefin(txt: []const u8, _: ?*const Config) bool {
    const r = after(txt, "cynefin-beta") orelse return false;
    return r.len == 0 or r[0] == ':' or spaceLen(r) > 0;
}

fn errorText(txt: []const u8, _: ?*const Config) bool {
    return std.ascii.eqlIgnoreCase(trim(txt), "error");
}

fn dashes(txt: []const u8, _: ?*const Config) bool {
    return std.mem.startsWith(u8, trimStart(txt), "---");
}

/// Mermaid 12.2.0 `addDiagrams()` order: the two built-ins, the large-feature set, then the lazy list.
pub const detectors = [_]Detector{
    .{ .id = "error", .test_fn = errorText },
    .{ .id = "---", .test_fn = dashes },
    .{ .id = "flowchart-elk", .test_fn = starts("flowchart-elk") },
    .{ .id = "mindmap", .test_fn = starts("mindmap") },
    .{ .id = "architecture", .test_fn = starts("architecture") },
    .{ .id = "agentflow", .test_fn = agentflow },
    .{ .id = "c4", .test_fn = c4 },
    .{ .id = "kanban", .test_fn = starts("kanban") },
    .{ .id = "classDiagram", .test_fn = starts("classDiagram") },
    .{ .id = "er", .test_fn = starts("erDiagram") },
    .{ .id = "gantt", .test_fn = starts("gantt") },
    .{ .id = "info", .test_fn = starts("info") },
    .{ .id = "pie", .test_fn = starts("pie") },
    .{ .id = "requirement", .test_fn = starts("requirement") },
    .{ .id = "sequence", .test_fn = starts("sequenceDiagram") },
    .{ .id = "swimlane", .test_fn = swimlane },
    .{ .id = "flowchart-v2", .test_fn = flowchartV2 },
    .{ .id = "timeline", .test_fn = starts("timeline") },
    .{ .id = "gitGraph", .test_fn = starts("gitGraph") },
    .{ .id = "stateDiagram", .test_fn = starts("stateDiagram") },
    .{ .id = "journey", .test_fn = starts("journey") },
    .{ .id = "quadrantChart", .test_fn = starts("quadrantChart") },
    .{ .id = "sankey", .test_fn = starts("sankey") },
    .{ .id = "packet", .test_fn = starts("packet") },
    .{ .id = "xychart", .test_fn = starts("xychart") },
    .{ .id = "block", .test_fn = starts("block") },
    .{ .id = "eventmodeling", .test_fn = starts("eventmodeling") },
    .{ .id = "treeView", .test_fn = starts("treeView-beta") },
    .{ .id = "radar", .test_fn = starts("radar-beta") },
    .{ .id = "ishikawa", .test_fn = ishikawa },
    .{ .id = "treemap", .test_fn = starts("treemap") },
    .{ .id = "railroad", .test_fn = startsNoCase("railroad-beta") },
    .{ .id = "railroadEbnf", .test_fn = startsNoCase("railroad-ebnf-beta") },
    .{ .id = "railroadAbnf", .test_fn = startsNoCase("railroad-abnf-beta") },
    .{ .id = "railroadPeg", .test_fn = startsNoCase("railroad-peg-beta") },
    .{ .id = "venn", .test_fn = starts("venn-beta") },
    .{ .id = "wardley", .test_fn = startsNoCase("wardley-beta") },
    .{ .id = "cynefin", .test_fn = cynefin },
    .{ .id = "usecase", .test_fn = usecase },
};

/// `text` is what the detectors see: front matter, directives and comments already removed.
pub fn detect(text: []const u8, cfg: ?*const Config) ?[]const u8 {
    for (detectors) |d| if (d.test_fn(text, cfg)) return d.id;
    return null;
}

/// detectType: strips front matter, directives and comments before running the detectors.
pub fn detectType(a: std.mem.Allocator, text: []const u8, cfg: ?*const Config) std.mem.Allocator.Error!?[]const u8 {
    return detect(try preprocess.stripForDetection(a, text), cfg);
}

fn expectDetect(want: ?[]const u8, text: []const u8) !void {
    const got = detect(text, null);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(w, got.?);
    } else try std.testing.expectEqual(@as(?[]const u8, null), got);
}

test "detectors follow mermaid's order" {
    try expectDetect("info", "info");
    try expectDetect("info", "  \n info\nshowInfo");
    try expectDetect("flowchart-v2", "flowchart TD\nA-->B");
    try expectDetect("flowchart-v2", "graph TD\nA-->B");
    try expectDetect("sequence", "sequenceDiagram\nA->>B: hi");
    try expectDetect("classDiagram", "classDiagram-v2");
    try expectDetect("classDiagram", "classDiagram");
    try expectDetect("stateDiagram", "stateDiagram-v2");
    try expectDetect("stateDiagram", "stateDiagram");
    try expectDetect("agentflow", "agentflow-beta");
    try expectDetect(null, "agentflow-betax");
    try expectDetect("usecase", "usecase-beta\nA");
    try expectDetect(null, "usecase-betax");
    try expectDetect("c4", "graph TD\nA[C4Dynamic]");
    try expectDetect("c4", "C4Context");
    try expectDetect("block", "block-beta");
    try expectDetect("requirement", "requirementDiagram");
    try expectDetect("xychart", "xychart-beta");
    try expectDetect("er", "erDiagram");
    try expectDetect("ishikawa", "Ishikawa-beta x");
    try expectDetect(null, "ishikawax");
    try expectDetect("cynefin", "cynefin-beta:x");
    try expectDetect(null, "cynefin-betax");
    try expectDetect("error", " ERROR ");
    try expectDetect("---", "---\nfoo");
    try expectDetect(null, "INFO");
    try expectDetect(null, "");
    try expectDetect(null, "xinfo");
}
