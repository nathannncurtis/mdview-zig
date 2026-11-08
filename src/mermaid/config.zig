const std = @import("std");
const testdata = @import("testdata");
const Allocator = std.mem.Allocator;
const json = std.json;
const theme = @import("theme/theme.zig");
const defaults = @import("config_defaults.zig");

/// The options the frame on github.com gives `mermaid.initialize`.
pub const github_init =
    \\{"secure":["secure","securityLevel","startOnLoad","maxTextSize"],"securityLevel":"antiscript","flowchart":{"diagramPadding":48},"gantt":{"useWidth":1200},"pie":{"useWidth":1200},"sequence":{"diagramMarginY":40}}
;

pub const Value = json.Value;
pub const ObjectMap = json.ObjectMap;
pub const Err = theme.vars.Err || error{BadConfig};

/// Keys that mermaid's defaultConfig carries as `undefined` or as functions, so `configKeys` lists them.
const extra_keys = [_][]const u8{
    "actorFont",
    "boundaryFont",
    "commentFill",
    "commentStroke",
    "commentTextColor",
    "componentFont",
    "component_dbFont",
    "component_queueFont",
    "containerFont",
    "container_dbFont",
    "container_queueFont",
    "cycleBreakingStrategy",
    "deterministicIDSeed",
    "external_componentFont",
    "external_component_dbFont",
    "external_component_queueFont",
    "external_containerFont",
    "external_container_dbFont",
    "external_container_queueFont",
    "external_personFont",
    "external_systemFont",
    "external_system_dbFont",
    "external_system_queueFont",
    "layeringStrategy",
    "markerFill",
    "messageFont",
    "nodeColors",
    "nodePlacementAlignment",
    "nodePlacementStrategy",
    "nonTerminalFill",
    "nonTerminalStroke",
    "nonTerminalTextColor",
    "noteFont",
    "personFont",
    "ruleNameColor",
    "specialFill",
    "specialStroke",
    "systemFont",
    "system_dbFont",
    "system_queueFont",
    "terminalFill",
    "terminalStroke",
    "terminalTextColor",
    "themeCSS",
    "themeVariables",
    "tickInterval",
};

const dictionary_keys = [_][]const u8{ "nodeColors", "filenameIcons", "extensionIcons" };

pub fn newObject(a: Allocator) Value {
    _ = a;
    return .{ .object = .empty };
}

fn isObjectLike(v: Value) bool {
    return v == .object or v == .array or v == .null;
}

fn numOf(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn includes(arr: json.Array, item: Value) bool {
    for (arr.items) |x| {
        const same = switch (item) {
            .null => x == .null,
            .bool => |b| x == .bool and x.bool == b,
            .string => |s| x == .string and std.mem.eql(u8, x.string, s),
            .integer, .float, .number_string => blk: {
                const n = numOf(item).?;
                const m = numOf(x) orelse break :blk false;
                break :blk n == m;
            },
            else => false,
        };
        if (same) return true;
    }
    return false;
}

/// mermaid's assignWithDepth, applied in place.
pub fn assignWithDepth(a: Allocator, dst: *Value, src: Value, depth: i32) Err!void {
    if (src == .array) {
        if (dst.* != .array) {
            for (src.array.items) |item| try assignWithDepth(a, dst, item, depth);
        } else for (src.array.items) |item| {
            if (!includes(dst.array, item)) try dst.array.append(item);
        }
        return;
    }
    if (dst.* == .null or depth <= 0) {
        if ((dst.* == .object or dst.* == .array) and src == .object) {
            if (dst.* == .object) {
                var it = src.object.iterator();
                while (it.next()) |kv| try dst.object.put(a, kv.key_ptr.*, kv.value_ptr.*);
            }
        } else dst.* = src;
        return;
    }
    if (src == .null or dst.* != .object or src != .object) return;
    var it = src.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const sv = kv.value_ptr.*;
        if (isObjectLike(sv)) {
            if (sv == .null) continue;
            if (!dst.object.contains(key)) {
                try dst.object.put(a, key, if (sv == .array) Value{ .array = json.Array.init(a) } else newObject(a));
            }
            const slot = dst.object.getPtr(key).?;
            if (isObjectLike(slot.*)) try assignWithDepth(a, slot, sv, depth - 1);
        } else {
            const existing = dst.object.getPtr(key);
            if (existing == null or !isObjectLike(existing.?.*)) try dst.object.put(a, key, sv);
        }
    }
}

/// `assignWithDepth({}, v)` with the default depth.
pub fn copy(a: Allocator, v: Value) Err!Value {
    var out = newObject(a);
    try assignWithDepth(a, &out, v, 2);
    return out;
}

/// lodash `merge` for plain JSON data.
pub fn mergeDeep(a: Allocator, dst: *Value, src: Value) Err!void {
    switch (src) {
        .object => |so| {
            if (dst.* != .object) dst.* = newObject(a);
            var it = so.iterator();
            while (it.next()) |kv| {
                if (dst.object.getPtr(kv.key_ptr.*)) |slot| {
                    if ((kv.value_ptr.* == .object and slot.* == .object) or (kv.value_ptr.* == .array and slot.* == .array)) {
                        try mergeDeep(a, slot, kv.value_ptr.*);
                    } else if (kv.value_ptr.* == .object or kv.value_ptr.* == .array) {
                        var fresh: Value = if (kv.value_ptr.* == .object) newObject(a) else .{ .array = json.Array.init(a) };
                        try mergeDeep(a, &fresh, kv.value_ptr.*);
                        slot.* = fresh;
                    } else slot.* = kv.value_ptr.*;
                } else if (kv.value_ptr.* == .object or kv.value_ptr.* == .array) {
                    var fresh: Value = if (kv.value_ptr.* == .object) newObject(a) else .{ .array = json.Array.init(a) };
                    try mergeDeep(a, &fresh, kv.value_ptr.*);
                    try dst.object.put(a, kv.key_ptr.*, fresh);
                } else try dst.object.put(a, kv.key_ptr.*, kv.value_ptr.*);
            }
        },
        .array => |sa| {
            if (dst.* != .array) dst.* = .{ .array = json.Array.init(a) };
            for (sa.items, 0..) |item, i| {
                if (i < dst.array.items.len) {
                    if (item == .object or item == .array) try mergeDeep(a, &dst.array.items[i], item) else dst.array.items[i] = item;
                } else try dst.array.append(item);
            }
        },
        else => dst.* = src,
    }
}

fn parseDefaults(a: Allocator) Err!Value {
    return json.parseFromSliceLeaky(Value, a, defaults.json, .{}) catch |e| if (e == error.OutOfMemory) error.OutOfMemory else error.BadConfig;
}

pub fn defaultTree(a: Allocator) Err!Value {
    var root = try parseDefaults(a);
    const obj = &root.object;

    var elk = newObject(a);
    const elk_entries = [_]struct { []const u8, Value }{
        .{ "mergeEdges", .{ .bool = false } },
        .{ "straightenEdges", .{ .bool = true } },
        .{ "lineHops", .{ .bool = true } },
        .{ "preset", .{ .string = "default" } },
        .{ "layeringLayerBound", .{ .integer = 4 } },
        .{ "forceNodeModelOrder", .{ .bool = false } },
        .{ "considerModelOrder", .{ .string = "NODES_AND_EDGES" } },
        .{ "keepEntryNodeOnTop", .{ .bool = false } },
        .{ "orientFeedbackEdges", .{ .bool = true } },
    };
    for (elk_entries) |kv| try elk.object.put(a, kv[0], kv[1]);
    try obj.put(a, "elk", elk);

    var class = newObject(a);
    if (obj.get("class")) |old| for ([_][]const u8{ "theme", "look", "layout" }) |k| {
        if (old.object.get(k)) |v| try class.object.put(a, k, v);
    };
    try class.object.put(a, "hideEmptyMembersBox", .{ .bool = false });
    try class.object.put(a, "hierarchicalNamespaces", .{ .bool = true });
    try obj.put(a, "class", class);

    var flow = (try parseDefaults(a)).object.get("flowchart").?;
    try flow.object.put(a, "inheritDir", .{ .bool = false });
    try obj.getPtr("c4").?.object.put(a, "flowchart", flow);
    try obj.getPtr("pie").?.object.put(a, "useWidth", .{ .integer = 984 });
    try obj.put(a, "railroad", newObject(a));

    var treemap = newObject(a);
    const tm = [_]struct { []const u8, Value }{
        .{ "useMaxWidth", .{ .bool = true } },
        .{ "padding", .{ .integer = 10 } },
        .{ "diagramPadding", .{ .integer = 8 } },
        .{ "showValues", .{ .bool = true } },
        .{ "nodeWidth", .{ .integer = 100 } },
        .{ "nodeHeight", .{ .integer = 40 } },
        .{ "borderWidth", .{ .integer = 1 } },
        .{ "valueFontSize", .{ .integer = 12 } },
        .{ "labelFontSize", .{ .integer = 14 } },
        .{ "valueFormat", .{ .string = "," } },
    };
    for (tm) |kv| try treemap.object.put(a, kv[0], kv[1]);
    try obj.put(a, "treemap", treemap);
    return root;
}

fn keyify(set: *std.StringHashMapUnmanaged(void), a: Allocator, v: Value) Allocator.Error!void {
    var it = v.object.iterator();
    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .array => {},
            .object => {
                try set.put(a, kv.key_ptr.*, {});
                try keyify(set, a, kv.value_ptr.*);
            },
            else => try set.put(a, kv.key_ptr.*, {}),
        }
    }
}

/// The set of key names mermaid accepts in a directive (`configKeys`).
pub fn configKeys(a: Allocator, tree: Value, default_theme: theme.vars.Vars) Err!std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    try keyify(&set, a, tree);
    for (extra_keys) |k| try set.put(a, k, {});
    for (default_theme.map.keys()) |dotted| {
        var parts = std.mem.splitScalar(u8, dotted, '.');
        while (parts.next()) |p| try set.put(a, p, {});
    }
    return set;
}

fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

fn removeKey(v: *Value, key: []const u8) void {
    _ = v.object.orderedRemove(key);
}

fn unbalancedCss(s: []const u8) bool {
    var open: usize = 0;
    var close: usize = 0;
    for (s) |c| {
        if (open < close) return true;
        if (c == '{') open += 1 else if (c == '}') close += 1;
    }
    return open != close;
}

pub fn sanitizeCss(s: []const u8) []const u8 {
    return if (unbalancedCss(s)) "{ /* ERROR: Unbalanced CSS */ }" else s;
}

fn themeValueAllowed(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, " \"#%(),.;", c) != null)) return false;
    }
    return true;
}

fn dictionaryValueAllowed(key: []const u8, s: []const u8) bool {
    if (std.mem.eql(u8, key, "nodeColors")) {
        if (s.len == 0) return false;
        if (s[0] == '#') {
            if (s.len < 4 or s.len > 9) return false;
            for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
            return true;
        }
        if (std.ascii.startsWithIgnoreCase(s, "rgb(") or std.ascii.startsWithIgnoreCase(s, "hsl(")) {
            if (s[s.len - 1] != ')') return false;
            for (s[4 .. s.len - 1]) |c| if (!(std.ascii.isDigit(c) or std.ascii.isWhitespace(c) or c == '%' or c == ',' or c == '.')) return false;
            return true;
        }
        for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
        return true;
    }
    if (s.len == 0) return false;
    var colon_at: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == ':') {
            if (colon_at != null or i == 0 or i == s.len - 1) return false;
            colon_at = i;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn isDictionaryKey(key: []const u8) bool {
    for (dictionary_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// mermaid's sanitizeDirective: drops unknown, secret-ish and null keys and cleans CSS and theme values.
pub fn sanitizeDirective(a: Allocator, keys: *const std.StringHashMapUnmanaged(void), args: *Value) Err!void {
    switch (args.*) {
        .array => |*arr| {
            for (arr.items) |*item| try sanitizeDirective(a, keys, item);
            return;
        },
        .object => {},
        else => return,
    }
    var doomed: std.ArrayList([]const u8) = .empty;
    for (args.object.keys(), args.object.values()) |key, *val| {
        if (startsWithAny(key, &.{"__"}) or std.mem.indexOf(u8, key, "proto") != null or std.mem.indexOf(u8, key, "constr") != null or !keys.contains(key) or val.* == .null) {
            try doomed.append(a, key);
            continue;
        }
        if (val.* == .object or val.* == .array) {
            if (isDictionaryKey(key)) {
                if (val.* == .object) {
                    var bad: std.ArrayList([]const u8) = .empty;
                    for (val.object.keys(), val.object.values()) |dk, dv| {
                        if (std.mem.startsWith(u8, dk, "__") or std.mem.indexOf(u8, dk, "proto") != null or std.mem.indexOf(u8, dk, "constr") != null or dv != .string or !dictionaryValueAllowed(key, dv.string)) try bad.append(a, dk);
                    }
                    for (bad.items) |dk| removeKey(val, dk);
                }
            } else try sanitizeDirective(a, keys, val);
            continue;
        }
        if (val.* == .string) {
            for ([_][]const u8{ "themeCSS", "fontFamily", "altFontFamily" }) |css_key| {
                if (std.mem.indexOf(u8, key, css_key) != null) val.* = .{ .string = sanitizeCss(val.string) };
            }
        }
    }
    for (doomed.items) |k| removeKey(args, k);
    if (args.object.getPtr("themeVariables")) |tv| if (tv.* == .object) {
        for (tv.object.values()) |*v| {
            if (v.* == .string and !themeValueAllowed(v.string)) v.* = .{ .string = "" };
        }
    };
}

/// mermaid's `sanitize` for the secure keys, double underscore keys and markup in values.
pub fn sanitizeSecure(a: Allocator, secure: []const []const u8, options: *Value) Allocator.Error!void {
    if (options.* != .object) return;
    for (secure) |k| _ = options.object.orderedRemove(k);
    _ = options.object.orderedRemove("secure");
    var doomed: std.ArrayList([]const u8) = .empty;
    for (options.object.keys(), options.object.values()) |key, *val| {
        if (std.mem.startsWith(u8, key, "__")) {
            try doomed.append(a, key);
            continue;
        }
        if (val.* == .string) {
            const s = val.string;
            if (std.mem.indexOfAny(u8, s, "<>") != null or std.mem.indexOf(u8, s, "url(data:") != null) try doomed.append(a, key);
        } else if (val.* == .object) try sanitizeSecure(a, secure, val);
    }
    for (doomed.items) |k| _ = options.object.orderedRemove(k);
}

pub fn evaluate(v: ?Value) bool {
    const val = v orelse return true;
    switch (val) {
        .bool => |b| if (!b) return false,
        .null => return false,
        .string => |s| {
            const t = std.mem.trim(u8, s, " \t\r\n");
            for ([_][]const u8{ "false", "null", "0" }) |w| if (std.ascii.eqlIgnoreCase(t, w)) return false;
        },
        .integer => |i| if (i == 0) return false,
        else => {},
    }
    return true;
}

pub const Config = struct {
    root: Value,
    vars: theme.vars.Vars,

    pub fn get(c: *const Config, path: []const u8) ?Value {
        var cur = c.root;
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |p| {
            if (cur != .object) return null;
            cur = cur.object.get(p) orelse return null;
        }
        return cur;
    }

    pub fn str(c: *const Config, path: []const u8) ?[]const u8 {
        const v = c.get(path) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn num(c: *const Config, path: []const u8) ?f64 {
        return numOf(c.get(path) orelse return null);
    }

    pub fn boolean(c: *const Config, path: []const u8) ?bool {
        const v = c.get(path) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    pub fn htmlLabels(c: *const Config) bool {
        return evaluate(if (c.get("htmlLabels")) |v| (if (v == .null) c.get("flowchart.htmlLabels") else v) else c.get("flowchart.htmlLabels"));
    }
};

pub fn themeName(name: []const u8) ?theme.Name {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return std.meta.stringToEnum(theme.Name, buf[0..name.len]);
}

/// The name mermaid knows a theme by.
pub fn themeKey(a: Allocator, name: theme.Name) Allocator.Error![]const u8 {
    const out = try a.dupe(u8, @tagName(name));
    for (out) |*c| if (c.* == '_') {
        c.* = '-';
    };
    return out;
}

/// `getDiagramConfigKey`: the config section a diagram type reads.
pub fn diagramConfigKey(id: []const u8) []const u8 {
    const aliases = [_][2][]const u8{
        .{ "flowchart-v2", "flowchart" },
        .{ "flowchart-elk", "flowchart" },
        .{ "classDiagram", "class" },
        .{ "stateDiagram", "state" },
        .{ "xychart", "xyChart" },
        .{ "railroadAbnf", "railroad" },
        .{ "railroadEbnf", "railroad" },
        .{ "railroadPeg", "railroad" },
    };
    for (aliases) |al| if (std.mem.eql(u8, id, al[0])) return al[1];
    return id;
}

pub fn flattenOverrides(a: Allocator, out: *std.ArrayList(theme.vars.Override), obj: Value) Err!void {
    try theme.vars.flattenJson(a, out, "", obj);
}

fn applyThemeVariables(a: Allocator, vars: *theme.vars.Vars, tv: Value) Err!void {
    var list: std.ArrayList(theme.vars.Override) = .empty;
    try flattenOverrides(a, &list, tv);
    for (list.items) |o| try vars.set(o.key, o.value);
}

/// What `mermaid.initialize(options)` leaves behind: the site config, the options as given, and the theme variables.
pub const Site = struct {
    root: Value,
    delta: Value,
    defaults: Value,
    init_vars: []const theme.vars.Override,
    vars: theme.vars.Vars,
    keys: std.StringHashMapUnmanaged(void),
    secure: []const []const u8,
};

/// `initialize` with the options in `init_json`; `site_theme` is written in as the `theme` option.
pub fn setupSite(a: Allocator, site_theme: theme.Name, init_json: []const u8) Err!Site {
    var options = json.parseFromSliceLeaky(Value, a, init_json, .{}) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadConfig;
    if (options != .object) options = newObject(a);
    try options.object.put(a, "theme", .{ .string = try themeKey(a, site_theme) });

    var init_vars: std.ArrayList(theme.vars.Override) = .empty;
    if (options.object.get("themeVariables")) |tv| try flattenOverrides(a, &init_vars, tv);
    const defaults_tree = try defaultTree(a);
    var root = try copy(a, defaults_tree);
    try assignWithDepth(a, &root, options, 2);
    const delta = try copy(a, options);
    const vars = try theme.compute(a, site_theme, init_vars.items);

    var secure: std.ArrayList([]const u8) = .empty;
    if (root.object.get("secure")) |s| if (s == .array) for (s.array.items) |item| if (item == .string) try secure.append(a, item.string);
    return .{
        .root = root,
        .delta = delta,
        .defaults = defaults_tree,
        .init_vars = init_vars.items,
        .vars = vars,
        .keys = try configKeys(a, defaults_tree, try theme.compute(a, .default, &.{})),
        .secure = secure.items,
    };
}

const appearance_keys = [_][]const u8{ "theme", "look", "layout" };

fn usableAppearance(key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "theme")) return std.mem.eql(u8, value, "null") or themeName(value) != null;
    if (std.mem.eql(u8, key, "look")) return std.mem.eql(u8, value, "classic") or std.mem.eql(u8, value, "handDrawn") or std.mem.eql(u8, value, "neo");
    return true;
}

fn readAppearance(layer: Value, scope: []const u8, key: []const u8) ?[]const u8 {
    if (layer != .object) return null;
    if (layer.object.get(scope)) |section| if (section == .object) if (section.object.get(key)) |v| {
        if (v == .string and usableAppearance(key, v.string)) return v.string;
    };
    if (layer.object.get(key)) |v| if (v == .string and usableAppearance(key, v.string)) return v.string;
    return null;
}

/// `updateCurrentConfig` for the config `render` sees: the site config, then the directive, with the diagram type's
/// own `theme`, `look` and `layout` defaults resolved when a type is in scope.
pub fn current(a: Allocator, site: *const Site, scope: ?[]const u8, directive: ?Value) Err!Config {
    var cfg = try copy(a, site.root);
    var sum = newObject(a);
    var d: Value = newObject(a);
    if (directive) |dv| {
        d = try copy(a, dv);
        try sanitizeDirective(a, &site.keys, &d);
        if (d.object.get("fontFamily")) |ff| if (ff != .null) {
            const has = if (d.object.get("themeVariables")) |tv| (tv == .object and tv.object.contains("fontFamily")) else false;
            if (!has) {
                var tv = if (d.object.get("themeVariables")) |t| t else newObject(a);
                if (tv != .object) tv = newObject(a);
                try tv.object.put(a, "fontFamily", ff);
                try d.object.put(a, "themeVariables", tv);
            }
        };
        try sanitizeSecure(a, site.secure, &d);
        try assignWithDepth(a, &sum, d, 2);
    }
    try assignWithDepth(a, &cfg, sum, 2);

    if (scope) |s| {
        const layers = [_]Value{ sum, d, site.delta, site.defaults };
        for (appearance_keys) |key| {
            for (layers) |layer| {
                const v = readAppearance(layer, s, key) orelse continue;
                try cfg.object.put(a, key, .{ .string = v });
                if (cfg.object.getPtr(s)) |section| if (section.* == .object and section.object.contains(key)) {
                    try section.object.put(a, key, .{ .string = v });
                };
                break;
            }
        }
    }

    var vars = site.vars;
    const site_theme = if (site.root.object.get("theme")) |t| (if (t == .string) t.string else "") else "";
    const cur_theme = if (cfg.object.get("theme")) |t| (if (t == .string) t.string else "") else "";
    const sum_theme = if (sum.object.get("theme")) |t| (t == .string and t.string.len > 0) else false;
    const overridden = sum_theme or !std.mem.eql(u8, cur_theme, site_theme);
    if (overridden and themeName(cur_theme) != null) {
        var list: std.ArrayList(theme.vars.Override) = .empty;
        try list.appendSlice(a, site.init_vars);
        if (sum.object.get("themeVariables")) |tv| try flattenOverrides(a, &list, tv);
        vars = try theme.compute(a, themeName(cur_theme).?, list.items);
    } else if (sum.object.get("themeVariables")) |tv| {
        vars = .{ .a = a, .map = try site.vars.map.clone(a) };
        try applyThemeVariables(a, &vars, tv);
    }

    _ = cfg.object.orderedRemove("themeVariables");
    return .{ .root = cfg, .vars = vars };
}

const expected_defaults = testdata.file("mermaid/config/config_defaults.json");
const expected_keys = testdata.file("mermaid/config/config_keys.json");

fn deepEqual(want: Value, have: Value) bool {
    if (numOf(want)) |w| return if (numOf(have)) |h| w == h else false;
    switch (want) {
        .null => return have == .null,
        .bool => |b| return have == .bool and have.bool == b,
        .string => |s| return have == .string and std.mem.eql(u8, s, have.string),
        .array => |arr| {
            if (have != .array or have.array.items.len != arr.items.len) return false;
            for (arr.items, have.array.items) |x, y| if (!deepEqual(x, y)) return false;
            return true;
        },
        .object => |o| {
            if (have != .object or have.object.count() != o.count()) return false;
            var it = o.iterator();
            while (it.next()) |kv| {
                const hv = have.object.get(kv.key_ptr.*) orelse return false;
                if (!deepEqual(kv.value_ptr.*, hv)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn firstDifference(path: []const u8, want: Value, have: Value, a: Allocator) ?[]const u8 {
    if (want == .object and have == .object) {
        var it = want.object.iterator();
        while (it.next()) |kv| {
            const sub = std.mem.concat(a, u8, &.{ path, ".", kv.key_ptr.* }) catch return path;
            const hv = have.object.get(kv.key_ptr.*) orelse return sub;
            if (firstDifference(sub, kv.value_ptr.*, hv, a)) |d| return d;
        }
        var it2 = have.object.iterator();
        while (it2.next()) |kv| {
            if (!want.object.contains(kv.key_ptr.*)) return std.mem.concat(a, u8, &.{ path, ".", kv.key_ptr.*, " (extra)" }) catch path;
        }
        return null;
    }
    return if (deepEqual(want, have)) null else path;
}

test "default config equals mermaid's defaultConfig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try json.parseFromSliceLeaky(Value, a, expected_defaults, .{});
    const have = try defaultTree(a);
    if (firstDifference("", want, have, a)) |d| {
        std.debug.print("config differs at {s}\n", .{d});
        return error.TestUnexpectedResult;
    }
}

test "directive keys equal mermaid's configKeys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try json.parseFromSliceLeaky([]const []const u8, a, expected_keys, .{});
    const keys = try configKeys(a, try defaultTree(a), try theme.compute(a, .default, &.{}));
    for (want) |k| {
        if (!keys.contains(k)) {
            std.debug.print("missing key {s}\n", .{k});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(want.len, keys.count());
}

test "assignWithDepth keeps objects and replaces scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dst = try json.parseFromSliceLeaky(Value, a, "{\"foo\":{\"bar\":\"bar\"},\"bar\":\"foo\"}", .{});
    const src = try json.parseFromSliceLeaky(Value, a, "{\"foo\":\"foo\",\"bar\":\"bar\",\"deep\":{\"x\":{\"y\":{\"z\":1}}}}", .{});
    try assignWithDepth(a, &dst, src, 2);
    try std.testing.expectEqualStrings("bar", dst.object.get("foo").?.object.get("bar").?.string);
    try std.testing.expectEqualStrings("bar", dst.object.get("bar").?.string);
    try std.testing.expectEqual(@as(i64, 1), dst.object.get("deep").?.object.get("x").?.object.get("y").?.object.get("z").?.integer);
}
