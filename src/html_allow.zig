const std = @import("std");

// From GitHub's Markdown API output, which differs from html-pipeline's DEFAULT_CONFIG (no figure, small, abbr, caption...; section kept).
const element_names = [_][]const u8{
    "h1",    "h2",     "h3",    "h4",     "h5",      "h6",      "br",       "b",
    "i",     "strong", "em",    "a",      "pre",     "code",    "img",      "tt",
    "div",   "ins",    "del",   "sup",    "sub",     "p",       "picture",  "ol",
    "ul",    "table",  "thead", "tbody",  "tfoot",   "tr",      "td",       "th",
    "blockquote", "dl", "dt",   "dd",     "kbd",     "q",       "samp",     "var",
    "hr",    "ruby",   "rt",    "rp",     "li",      "s",       "strike",   "summary",
    "details", "mark", "source", "span",  "section",
};

const elements = blk: {
    var kv: [element_names.len]struct { []const u8 } = undefined;
    for (element_names, 0..) |n, i| kv[i] = .{n};
    break :blk std.StaticStringMap(void).initComptime(kv);
};

const global_attr_names = [_][]const u8{
    "abbr",      "accept",   "accept-charset", "accesskey", "action",   "align",    "alt",     "axis",
    "char",      "charoff",  "charset",        "checked",   "clear",    "cols",     "colspan", "compact",
    "coords",    "datetime", "dir",            "disabled",  "enctype",  "for",      "frame",   "headers",
    "height",    "hreflang", "hspace",         "id",        "ismap",    "label",    "lang",    "maxlength",
    "media",     "method",   "multiple",       "name",      "nohref",   "noshade",  "nowrap",  "open",
    "prompt",    "readonly", "rev",            "rows",      "rowspan",  "rules",    "scope",   "selected",
    "shape",     "size",     "span",           "start",     "summary",  "tabindex", "title",   "type",
    "usemap",    "valign",   "value",          "width",     "itemprop",
};

const global_attrs = blk: {
    var kv: [global_attr_names.len]struct { []const u8 } = undefined;
    for (global_attr_names, 0..) |n, i| kv[i] = .{n};
    break :blk std.StaticStringMap(void).initComptime(kv);
};

pub fn elementAllowed(name: []const u8) bool {
    return elements.has(name);
}

fn aria(attr: []const u8) bool {
    return std.mem.eql(u8, attr, "aria-describedby") or std.mem.eql(u8, attr, "aria-label") or std.mem.eql(u8, attr, "aria-labelledby");
}

pub fn attrAllowed(element: []const u8, attr: []const u8) bool {
    if (global_attrs.has(attr)) return true;
    const e = element;
    const eq = std.mem.eql;
    if (aria(attr)) return eq(u8, e, "a") or eq(u8, e, "img") or eq(u8, e, "ol") or eq(u8, e, "ul") or
        eq(u8, e, "dl") or eq(u8, e, "summary") or eq(u8, e, "table");
    if (eq(u8, attr, "href")) return eq(u8, e, "a");
    if (eq(u8, attr, "src") or eq(u8, attr, "longdesc")) return eq(u8, e, "img");
    if (eq(u8, attr, "srcset")) return eq(u8, e, "source");
    if (eq(u8, attr, "cite")) return eq(u8, e, "blockquote") or eq(u8, e, "del") or eq(u8, e, "ins") or eq(u8, e, "q");
    if (eq(u8, attr, "itemscope") or eq(u8, attr, "itemtype")) return eq(u8, e, "div");
    return false;
}

pub const Protocols = enum { none, link, media };

pub fn protocols(element: []const u8, attr: []const u8) Protocols {
    const eq = std.mem.eql;
    if (eq(u8, element, "a") and eq(u8, attr, "href")) return .link;
    if (eq(u8, element, "img") and (eq(u8, attr, "src") or eq(u8, attr, "longdesc"))) return .media;
    if (eq(u8, element, "source") and eq(u8, attr, "srcset")) return .media;
    if (eq(u8, attr, "cite")) return .media;
    return .none;
}

pub fn schemeAllowed(kind: Protocols, url: []const u8) bool {
    if (kind == .none) return true;
    var i: usize = 0;
    while (i < url.len and (url[i] <= ' ')) i += 1;
    const s = url[i..];
    var colon: ?usize = null;
    for (s, 0..) |c, k| {
        if (c == ':') {
            colon = k;
            break;
        }
        if (c == '/' or c == '?' or c == '#') break;
    }
    const k = colon orelse return true;
    const scheme = s[0..k];
    if (scheme.len == 0) return false;
    inline for (.{ "http", "https" }) |ok| if (std.ascii.eqlIgnoreCase(scheme, ok)) return true;
    return kind == .link and std.ascii.eqlIgnoreCase(scheme, "mailto");
}

pub fn firstSrcset(value: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse value.len;
    const cand = std.mem.trim(u8, value[0..comma], " \t\n\r\x0c");
    const sp = std.mem.indexOfAny(u8, cand, " \t\n\r\x0c") orelse cand.len;
    return cand[0..sp];
}

const tagfilter_names = [_][]const u8{ "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext" };

pub fn tagfiltered(name: []const u8) bool {
    for (tagfilter_names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

pub fn removeContents(name: []const u8) bool {
    return std.mem.eql(u8, name, "svg");
}

test "allowlist" {
    try std.testing.expect(elementAllowed("details"));
    try std.testing.expect(!elementAllowed("center"));
    try std.testing.expect(!elementAllowed("figure"));
    try std.testing.expect(attrAllowed("img", "src"));
    try std.testing.expect(!attrAllowed("a", "rel"));
    try std.testing.expect(!attrAllowed("p", "style"));
    try std.testing.expect(!attrAllowed("div", "aria-label"));
    try std.testing.expect(attrAllowed("a", "aria-label"));
}

test "protocols" {
    try std.testing.expect(schemeAllowed(.link, "mailto:a@b.c"));
    try std.testing.expect(schemeAllowed(.link, "rel/path?x=a:b"));
    try std.testing.expect(schemeAllowed(.link, "#frag:x"));
    try std.testing.expect(schemeAllowed(.link, "HTTPS://x"));
    try std.testing.expect(!schemeAllowed(.link, "javascript:alert(1)"));
    try std.testing.expect(!schemeAllowed(.link, " \tjavascript:1"));
    try std.testing.expect(!schemeAllowed(.link, "tel:1"));
    try std.testing.expect(!schemeAllowed(.link, "data:text/html,x"));
    try std.testing.expect(!schemeAllowed(.media, "mailto:a@b.c"));
    try std.testing.expect(!schemeAllowed(.media, "ftp://x"));
    try std.testing.expect(!schemeAllowed(.media, "file:///etc"));
    try std.testing.expect(schemeAllowed(.media, "https://x/a.png"));
    try std.testing.expectEqualStrings("a.png", firstSrcset(" a.png 2x, b.png"));
}
