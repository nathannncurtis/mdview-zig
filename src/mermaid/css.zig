const std = @import("std");
const Allocator = std.mem.Allocator;
const vars_mod = @import("theme/vars.zig");

// Mermaid compiles every stylesheet with stylis under `#<svg id>`; this does the same for the CSS mermaid writes.

fn isTight(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!+,/>@~;{}", c) != null;
}

// stylis keeps one space for a whitespace run unless a punctuation character sits on either side.
fn minify(a: Allocator, css: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < css.len) {
        const c = css[i];
        if (c == '"' or c == '\'') {
            const start = i;
            i += 1;
            while (i < css.len and css[i] != c) i += if (css[i] == '\\' and i + 1 < css.len) 2 else 1;
            i = @min(i + 1, css.len);
            try out.appendSlice(a, css[start..i]);
            continue;
        }
        if (c == '(' or c == '[') {
            const start = i;
            var depth: usize = 0;
            while (i < css.len) : (i += 1) {
                if (css[i] == '(' or css[i] == '[') depth += 1;
                if (css[i] == ')' or css[i] == ']') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
            try out.appendSlice(a, css[start..i]);
            continue;
        }
        if (c == '/' and i + 1 < css.len and css[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, css, i + 2, "*/") orelse css.len;
            i = @min(close + 2, css.len);
            continue;
        }
        if (c <= ' ') {
            var j = i;
            while (j < css.len and css[j] <= ' ') j += 1;
            if (out.items.len > 0 and j < css.len) {
                const prev = out.items[out.items.len - 1];
                const next = css[j];
                const comment_next = next == '/' and j + 1 < css.len and css[j + 1] == '*';
                if (!isTight(prev) and prev != ':' and !(isTight(next) and !comment_next)) try out.append(a, ' ');
            }
            i = j;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

const Parser = struct {
    a: Allocator,
    ns: []const u8,
    text: []const u8,
    pos: usize = 0,
    out: std.ArrayList(u8) = .empty,

    fn isRootDecl(decls: []const u8) bool {
        var it = std.mem.splitScalar(u8, decls, ';');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            const name = d[0..(std.mem.indexOfScalar(u8, d, ':') orelse d.len)];
            if (!(std.mem.eql(u8, name, "font-family") or std.mem.eql(u8, name, "font-size") or std.mem.eql(u8, name, "fill"))) return false;
        }
        return true;
    }

    fn readHead(p: *Parser) ?struct { head: []const u8, term: u8 } {
        const start = p.pos;
        var depth: usize = 0;
        while (p.pos < p.text.len) : (p.pos += 1) {
            const c = p.text[p.pos];
            if (c == '"' or c == '\'') {
                p.pos += 1;
                while (p.pos < p.text.len and p.text[p.pos] != c) p.pos += if (p.text[p.pos] == '\\') 2 else 1;
                continue;
            }
            if (c == '(' or c == '[') depth += 1;
            if ((c == ')' or c == ']') and depth > 0) depth -= 1;
            if (depth == 0 and (c == '{' or c == ';' or c == '}')) {
                const head = p.text[start..p.pos];
                p.pos += 1;
                return .{ .head = head, .term = c };
            }
        }
        if (start >= p.text.len) return null;
        const head = p.text[start..];
        p.pos = p.text.len;
        return .{ .head = head, .term = ';' };
    }

    fn splitSelectors(p: *Parser, head: []const u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var depth: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i < head.len) : (i += 1) {
            const c = head[i];
            if (c == '"' or c == '\'') {
                i += 1;
                while (i < head.len and head[i] != c) i += if (head[i] == '\\') 2 else 1;
                continue;
            }
            if (c == '(' or c == '[') depth += 1;
            if ((c == ')' or c == ']') and depth > 0) depth -= 1;
            if (c == ',' and depth == 0) {
                try list.append(p.a, head[start..i]);
                start = i + 1;
            }
        }
        try list.append(p.a, head[start..]);
        return list.items;
    }

    fn resolveSelectors(p: *Parser, head: []const u8, parents: []const []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try p.splitSelectors(head)) |sel| {
            for (parents) |parent| {
                if (std.mem.indexOfScalar(u8, sel, '&') != null) {
                    try out.append(p.a, try std.mem.replaceOwned(u8, p.a, sel, "&", parent));
                } else {
                    try out.append(p.a, try std.mem.concat(p.a, u8, &.{ parent, " ", sel }));
                }
            }
        }
        return out.items;
    }

    fn atName(head: []const u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, head, ' ') orelse head.len;
        return head[0..end];
    }

    fn skipBlock(p: *Parser) void {
        var depth: usize = 1;
        while (p.pos < p.text.len and depth > 0) : (p.pos += 1) {
            if (p.text[p.pos] == '{') depth += 1;
            if (p.text[p.pos] == '}') depth -= 1;
        }
    }

    fn emitRule(p: *Parser, selectors: []const []const u8, decls: []const u8, is_root: bool) Allocator.Error!void {
        if (decls.len == 0) return;
        var joined: std.ArrayList(u8) = .empty;
        var first = true;
        for (selectors) |sel| {
            const keep_bare = std.mem.eql(u8, sel, p.ns) and is_root;
            const namespaced = std.mem.startsWith(u8, sel, p.ns) and sel.len > p.ns.len and (sel[p.ns.len] == ' ' or sel[p.ns.len] == '>');
            if (!first) try joined.append(p.a, ',');
            first = false;
            if (keep_bare or namespaced) {
                try joined.appendSlice(p.a, sel);
            } else {
                try joined.appendSlice(p.a, p.ns);
                try joined.append(p.a, ' ');
                try joined.appendSlice(p.a, sel);
            }
        }
        try p.out.appendSlice(p.a, joined.items);
        try p.out.append(p.a, '{');
        try p.out.appendSlice(p.a, decls);
        try p.out.append(p.a, '}');
    }

    fn keyframes(p: *Parser) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.readHead()) |h| {
            if (h.term == '}') break;
            if (h.term != '{') continue;
            var inner: std.ArrayList(u8) = .empty;
            while (p.readHead()) |d| {
                const decl = std.mem.trim(u8, d.head, " ");
                if (decl.len > 0) {
                    try inner.appendSlice(p.a, decl);
                    try inner.append(p.a, ';');
                }
                if (d.term == '}') break;
            }
            if (inner.items.len > 0) try out.print(p.a, "{s}{{{s}}}", .{ std.mem.trim(u8, h.head, " "), inner.items });
        }
        return out.items;
    }

    fn block(p: *Parser, parents: []const []const u8, top: bool) Allocator.Error!void {
        var decls: std.ArrayList(u8) = .empty;
        var nested: std.ArrayList(u8) = .empty;
        const saved = p.out;
        p.out = .empty;
        while (p.readHead()) |h| {
            const head = std.mem.trim(u8, h.head, " ");
            if (h.term == '}') {
                if (head.len > 0 and std.mem.indexOfScalar(u8, head, ':') != null) {
                    try decls.appendSlice(p.a, head);
                    try decls.append(p.a, ';');
                }
                break;
            }
            if (h.term == ';') {
                if (head.len > 0 and head[0] != '@' and std.mem.indexOfScalar(u8, head, ':') != null) {
                    try decls.appendSlice(p.a, head);
                    try decls.append(p.a, ';');
                }
                continue;
            }
            if (head.len > 0 and head[0] == '@') {
                const name = atName(head);
                if (std.mem.endsWith(u8, name, "keyframes")) {
                    const body = try p.keyframes();
                    if (body.len > 0) try nested.print(p.a, "{s}{{{s}}}", .{ head, body });
                } else if (isNestedAt(name)) {
                    var inner: Parser = .{ .a = p.a, .ns = p.ns, .text = p.text, .pos = p.pos };
                    try inner.block(parents, false);
                    p.pos = inner.pos;
                    if (inner.out.items.len > 0) try nested.print(p.a, "{s}{{{s}}}", .{ head, inner.out.items });
                } else p.skipBlock();
                continue;
            }
            const sels = try p.resolveSelectors(head, parents);
            var inner: Parser = .{ .a = p.a, .ns = p.ns, .text = p.text, .pos = p.pos };
            try inner.block(sels, false);
            p.pos = inner.pos;
            try nested.appendSlice(p.a, inner.out.items);
        }
        if (decls.items.len > 0) try p.emitRule(parents, decls.items, top or isRootDecl(decls.items));
        try p.out.appendSlice(p.a, nested.items);
        const mine = p.out;
        p.out = saved;
        try p.out.appendSlice(p.a, mine.items);
    }

    fn isNestedAt(name: []const u8) bool {
        for ([_][]const u8{ "@media", "@supports", "@layer", "@scope", "@container", "@starting-style" }) |n| {
            if (std.mem.eql(u8, name, n)) return true;
        }
        return false;
    }
};

/// stylis `serialize(compile(ns{css}))` with mermaid's namespacing middleware.
pub fn compile(a: Allocator, ns: []const u8, css: []const u8) Allocator.Error![]const u8 {
    const text = try minify(a, css);
    var p: Parser = .{ .a = a, .ns = ns, .text = text };
    try p.block(&.{ns}, true);
    return p.out.items;
}

fn fmtV(a: Allocator, v: vars_mod.V) Allocator.Error![]const u8 {
    return (try v.text(a)) orelse "undefined";
}

/// mermaid's `getStyles` template: the rules shared by every diagram around the diagram's own CSS.
pub fn commonStyles(a: Allocator, svg_selector: []const u8, vars: *const vars_mod.Vars, diagram_css: []const u8, user_css: []const u8) Allocator.Error![]const u8 {
    const font_family = try fmtV(a, vars.get("fontFamily"));
    const font_size = try fmtV(a, vars.get("fontSize"));
    const text_color = try fmtV(a, vars.get("textColor"));
    const err_bkg = try fmtV(a, vars.get("errorBkgColor"));
    const err_text = try fmtV(a, vars.get("errorTextColor"));
    const line_color = try fmtV(a, vars.get("lineColor"));
    const node_border = try fmtV(a, vars.get("nodeBorder"));
    const sw = vars.get("strokeWidth");
    const stroke_width = if (sw == .undef) "1" else try fmtV(a, sw);
    const gradient = try std.fmt.allocPrint(a, "url({s}-gradient)", .{svg_selector});
    const stroke = if (vars.get("useGradient").truthy()) gradient else node_border;
    const drop = vars.get("dropShadow");
    const filter = if (drop.truthy()) blk: {
        const raw = (try drop.text(a)).?;
        const repl = try std.fmt.allocPrint(a, "url({s}-drop-shadow)", .{svg_selector});
        break :blk try std.mem.replaceOwned(u8, a, raw, "url(#drop-shadow)", repl);
    } else "none";

    return std.fmt.allocPrint(a,
        \\& {{
        \\    font-family: {[font_family]s};
        \\    font-size: {[font_size]s};
        \\    fill: {[text_color]s}
        \\  }}
        \\  @keyframes edge-animation-frame {{
        \\    from {{
        \\      stroke-dashoffset: 0;
        \\    }}
        \\  }}
        \\  @keyframes dash {{
        \\    to {{
        \\      stroke-dashoffset: 0;
        \\    }}
        \\  }}
        \\  & .edge-animation-slow {{
        \\    stroke-dasharray: 9,5 !important;
        \\    stroke-dashoffset: 900;
        \\    animation: dash 50s linear infinite;
        \\    stroke-linecap: round;
        \\  }}
        \\  & .edge-animation-fast {{
        \\    stroke-dasharray: 9,5 !important;
        \\    stroke-dashoffset: 900;
        \\    animation: dash 20s linear infinite;
        \\    stroke-linecap: round;
        \\  }}
        \\  /* Classes common for multiple diagrams */
        \\
        \\  & .error-icon {{
        \\    fill: {[err_bkg]s};
        \\  }}
        \\  & .error-text {{
        \\    fill: {[err_text]s};
        \\    stroke: {[err_text]s};
        \\  }}
        \\
        \\  & .edge-thickness-normal {{
        \\    stroke-width: {[stroke_width]s}px;
        \\  }}
        \\  & .edge-thickness-thick {{
        \\    stroke-width: 3.5px
        \\  }}
        \\  & .edge-pattern-solid {{
        \\    stroke-dasharray: 0;
        \\  }}
        \\  & .edge-thickness-invisible {{
        \\    stroke-width: 0;
        \\    fill: none;
        \\  }}
        \\  & .edge-pattern-dashed{{
        \\    stroke-dasharray: 3;
        \\  }}
        \\  .edge-pattern-dotted {{
        \\    stroke-dasharray: 2;
        \\  }}
        \\
        \\  & .marker {{
        \\    fill: {[line_color]s};
        \\    stroke: {[line_color]s};
        \\  }}
        \\  & .marker.cross {{
        \\    stroke: {[line_color]s};
        \\  }}
        \\
        \\  & svg {{
        \\    font-family: {[font_family]s};
        \\    font-size: {[font_size]s};
        \\  }}
        \\   & p {{
        \\    margin: 0
        \\   }}
        \\
        \\  {[diagram_css]s}
        \\  .node .neo-node {{
        \\    stroke: {[node_border]s};
        \\  }}
        \\
        \\  [data-look="neo"].node rect, [data-look="neo"].cluster rect, [data-look="neo"].node polygon {{
        \\    stroke: {[stroke]s};
        \\    filter: {[filter]s};
        \\  }}
        \\  [data-look="neo"].swimlane.cluster rect {{
        \\    filter: none;
        \\  }}
        \\
        \\
        \\  [data-look="neo"].node path {{
        \\    stroke: {[stroke]s};
        \\    stroke-width: {[stroke_width]s}px;
        \\  }}
        \\
        \\  [data-look="neo"].node .outer-path {{
        \\    filter: {[filter]s};
        \\  }}
        \\
        \\  [data-look="neo"].node .neo-line path {{
        \\    stroke: {[node_border]s};
        \\    filter: none;
        \\  }}
        \\
        \\  [data-look="neo"].node circle{{
        \\    stroke: {[stroke]s};
        \\    filter: {[filter]s};
        \\  }}
        \\
        \\  [data-look="neo"].node circle .state-start{{
        \\    fill: #000000;
        \\  }}
        \\
        \\  [data-look="neo"].icon-shape .icon {{
        \\    fill: {[stroke]s};
        \\    filter: {[filter]s};
        \\  }}
        \\
        \\    [data-look="neo"].icon-shape .icon-neo path {{
        \\    stroke: {[stroke]s};
        \\    filter: {[filter]s};
        \\  }}
        \\
        \\  {[user_css]s}
        \\
    , .{
        .font_family = font_family,
        .font_size = font_size,
        .text_color = text_color,
        .err_bkg = err_bkg,
        .err_text = err_text,
        .stroke_width = stroke_width,
        .line_color = line_color,
        .diagram_css = diagram_css,
        .node_border = node_border,
        .stroke = stroke,
        .filter = filter,
        .user_css = user_css,
    });
}

test "stylis-style scoping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try compile(a, "#x", "& { font-size: 16px; fill: #ccc } .a, .b > .c { stroke: red !important; margin: 0 } @keyframes k { from { a: 0; } } /* c */ & p { margin: 0 }");
    try std.testing.expectEqualStrings("#x{font-size:16px;fill:#ccc;}#x .a,#x .b>.c{stroke:red!important;margin:0;}@keyframes k{from{a:0;}}#x p{margin:0;}", got);
}
