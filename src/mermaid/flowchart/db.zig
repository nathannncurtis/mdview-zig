const std = @import("std");
const yaml = @import("yaml");
const html = @import("html");
const model = @import("../render/model.zig");
const Allocator = std.mem.Allocator;
const List = std.ArrayList;

pub const Error = error{ Semantic, OutOfMemory };

pub const FlowText = struct { text: []const u8, type: []const u8 = "text" };

pub const Vertex = struct {
    id: []const u8,
    label_type: []const u8 = "text",
    dom_id: []const u8,
    styles: List([]const u8) = .empty,
    classes: List([]const u8) = .empty,
    text: ?[]const u8 = null,
    type: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    link: ?[]const u8 = null,
    link_target: ?[]const u8 = null,
    have_callback: bool = false,
    icon: ?[]const u8 = null,
    form: ?[]const u8 = null,
    pos: ?u8 = null,
    img: ?[]const u8 = null,
    asset_width: ?f64 = null,
    asset_height: ?f64 = null,
    constraint: ?[]const u8 = null,
};

pub const Edge = struct {
    start: []const u8,
    end: []const u8,
    type: ?[]const u8 = null,
    text: []const u8 = "",
    label_type: []const u8 = "text",
    classes: List([]const u8) = .empty,
    is_user_defined_id: bool = false,
    interpolate: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    length: ?f64 = null,
    style: ?List([]const u8) = null,
    id: ?[]const u8 = null,
    animation: ?[]const u8 = null,
    animate: ?bool = null,
};

pub const Class = struct {
    id: []const u8,
    styles: List([]const u8) = .empty,
    text_styles: List([]const u8) = .empty,
};

pub const SubGraph = struct {
    classes: List([]const u8) = .empty,
    dir: ?[]const u8 = null,
    collapsed: bool = false,
    id: []const u8,
    label_type: []const u8,
    nodes: []const []const u8,
    title: []const u8,
};

pub const LinkInfo = struct {
    type: []const u8,
    stroke: []const u8,
    length: ?f64 = null,
    text: ?FlowText = null,
    id: ?[]const u8 = null,
};

pub const Pos = union(enum) { default, index: []const u8 };

pub const DocItem = union(enum) { name: []const u8, dir: []const u8 };

const dom_id_prefix = "flowchart-";

pub const Db = struct {
    a: Allocator,
    cfg: *const model.Config,
    err_msg: ?[]const u8 = null,
    vertex_counter: usize = 0,
    diagram_id: []const u8 = "",
    vertices: std.StringArrayHashMapUnmanaged(*Vertex) = .empty,
    edges: List(*Edge) = .empty,
    default_interpolate: ?[]const u8 = null,
    default_style: ?[]const []const u8 = null,
    classes: std.StringArrayHashMapUnmanaged(*Class) = .empty,
    sub_graphs: List(*SubGraph) = .empty,
    sub_graph_lookup: std.StringHashMapUnmanaged(*SubGraph) = .empty,
    tooltips: std.StringHashMapUnmanaged([]const u8) = .empty,
    sub_count: usize = 0,
    first_graph_flag: bool = true,
    direction: ?[]const u8 = null,
    acc_title: ?[]const u8 = null,
    acc_descr: ?[]const u8 = null,
    diagram_title: ?[]const u8 = null,

    pub fn init(a: Allocator, cfg: *const model.Config) Db {
        return .{ .a = a, .cfg = cfg };
    }

    fn fail(self: *Db, comptime fmt: []const u8, args: anytype) Error {
        self.err_msg = try_print(self.a, fmt, args);
        return error.Semantic;
    }

    pub fn setDiagramId(self: *Db, id: []const u8) void {
        self.diagram_id = id;
    }

    pub fn sanitizeText(self: *Db, txt: []const u8) Allocator.Error![]const u8 {
        if (txt.len == 0) return txt;
        const lvl = self.cfg.security_level;
        const escape_first = !(eq(lvl, "loose") or eq(lvl, "antiscript") or eq(lvl, "strict") or eq(lvl, "sandbox")) and self.cfg.html_labels;
        if (escape_first) {
            var o: List(u8) = .empty;
            var i: usize = 0;
            while (i < txt.len) {
                if (brLen(txt[i..])) |n| {
                    try o.appendSlice(self.a, "<br/>");
                    i += n;
                    continue;
                }
                switch (txt[i]) {
                    '<' => try o.appendSlice(self.a, "&lt;"),
                    '>' => try o.appendSlice(self.a, "&gt;"),
                    '=' => try o.appendSlice(self.a, "&equals;"),
                    else => |c| try o.append(self.a, c),
                }
                i += 1;
            }
            return purify(self.a, o.items);
        }
        return purify(self.a, txt);
    }

    fn sanitizeNodeLabelType(t: ?[]const u8) []const u8 {
        const s = t orelse return "markdown";
        if (eq(s, "markdown") or eq(s, "string") or eq(s, "text")) return s;
        return "markdown";
    }

    fn metaTruthy(v: yaml.Value) bool {
        return switch (v) {
            .scalar => |s| !s.falsy and s.text.len > 0,
            else => true,
        };
    }

    fn metaGet(pairs: []const yaml.Pair, key: []const u8) ?yaml.Value {
        for (pairs) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
        return null;
    }

    fn metaStr(pairs: []const yaml.Pair, key: []const u8) ?[]const u8 {
        const v = metaGet(pairs, key) orelse return null;
        if (!metaTruthy(v)) return null;
        return switch (v) {
            .scalar => |s| s.text,
            else => null,
        };
    }

    fn metaNum(pairs: []const yaml.Pair, key: []const u8) ?f64 {
        const s = metaStr(pairs, key) orelse return null;
        return std.fmt.parseFloat(f64, s) catch null;
    }

    pub fn addVertex(
        self: *Db,
        id: []const u8,
        text_obj: ?FlowText,
        vtype: ?[]const u8,
        style: ?[]const []const u8,
        classes: ?[]const []const u8,
        dir: ?[]const u8,
        metadata: ?[]const u8,
    ) Error!void {
        if (std.mem.trim(u8, id, " \t\r\n").len == 0) return;
        var pairs: ?[]const yaml.Pair = null;
        if (metadata) |m| {
            const src = if (std.mem.indexOfScalar(u8, m, '\n') == null)
                try std.fmt.allocPrint(self.a, "{{\n{s}\n}}", .{m})
            else
                try std.fmt.allocPrint(self.a, "{s}\n", .{m});
            switch (try yaml.parse(self.a, src)) {
                .ok => |v| pairs = switch (v) {
                    .map => |mp| mp,
                    else => &.{},
                },
                .err => |f| return self.fail("{s}", .{f.message}),
                .other => pairs = &.{},
            }
        }

        if (pairs != null) if (self.sub_graph_lookup.get(id)) |sg| {
            if (metaGet(pairs.?, "view")) |v| switch (v) {
                .scalar => |sc| sg.collapsed = std.mem.eql(u8, sc.text, "collapsed"),
                else => {},
            };
            return;
        };

        for (self.edges.items) |e| {
            if (e.id != null and std.mem.eql(u8, e.id.?, id)) {
                if (pairs) |p| {
                    if (metaGet(p, "animate")) |v| switch (v) {
                        .scalar => |s| e.animate = std.mem.eql(u8, s.text, "true"),
                        else => {},
                    };
                    if (metaGet(p, "animation")) |v| switch (v) {
                        .scalar => |s| e.animation = s.text,
                        else => {},
                    };
                    if (metaGet(p, "curve")) |v| switch (v) {
                        .scalar => |s| e.interpolate = s.text,
                        else => {},
                    };
                }
                return;
            }
        }

        const gop = try self.vertices.getOrPut(self.a, id);
        if (!gop.found_existing) {
            const v = try self.a.create(Vertex);
            v.* = .{
                .id = id,
                .dom_id = try std.fmt.allocPrint(self.a, "{s}{s}-{d}", .{ dom_id_prefix, id, self.vertex_counter }),
            };
            gop.value_ptr.* = v;
        }
        const vertex = gop.value_ptr.*;
        self.vertex_counter += 1;

        if (text_obj) |t| {
            var txt = try self.sanitizeText(std.mem.trim(u8, t.text, " \t\r\n"));
            vertex.label_type = t.type;
            if (txt.len >= 2 and txt[0] == '"' and txt[txt.len - 1] == '"') txt = txt[1 .. txt.len - 1];
            vertex.text = txt;
        } else if (vertex.text == null) {
            vertex.text = id;
        }
        if (vtype) |t| vertex.type = t;
        if (style) |s| for (s) |x| try vertex.styles.append(self.a, x);
        if (classes) |c| for (c) |x| try vertex.classes.append(self.a, x);
        if (dir) |d| vertex.dir = d;

        if (pairs) |p| {
            if (metaStr(p, "shape")) |shape| {
                if (!std.mem.eql(u8, shape, try lower(self.a, shape)) or std.mem.indexOfScalar(u8, shape, '_') != null)
                    return self.fail("No such shape: {s}. Shape names should be lowercase.", .{shape});
                if (!isValidShape(shape)) return self.fail("No such shape: {s}.", .{shape});
                vertex.type = shape;
            }
            const label = metaStr(p, "label");
            if (label) |l| {
                vertex.text = l;
                vertex.label_type = sanitizeNodeLabelType(metaStr(p, "labelType"));
            }
            const label_blank = label == null or std.mem.trim(u8, label.?, " \t\r\n").len == 0;
            if (metaStr(p, "icon")) |ic| {
                vertex.icon = ic;
                if (label_blank and vertex.text != null and std.mem.eql(u8, vertex.text.?, id)) vertex.text = "";
            }
            if (metaStr(p, "form")) |f| vertex.form = f;
            if (metaStr(p, "pos")) |ps| vertex.pos = if (ps.len > 0) ps[0] else null;
            if (metaStr(p, "img")) |im| {
                vertex.img = im;
                if (label_blank and vertex.text != null and std.mem.eql(u8, vertex.text.?, id)) vertex.text = "";
            }
            if (metaStr(p, "constraint")) |c| vertex.constraint = c;
            if (metaNum(p, "w")) |w| vertex.asset_width = w;
            if (metaNum(p, "h")) |h| vertex.asset_height = h;
        }
    }

    fn addSingleLink(self: *Db, start: []const u8, end: []const u8, link: LinkInfo, id: ?[]const u8) Error!void {
        const edge = try self.a.create(Edge);
        edge.* = .{ .start = start, .end = end, .interpolate = self.default_interpolate };
        if (link.text) |t| {
            var txt = try self.sanitizeText(std.mem.trim(u8, t.text, " \t\r\n"));
            if (txt.len >= 2 and txt[0] == '"' and txt[txt.len - 1] == '"') txt = txt[1 .. txt.len - 1];
            edge.text = txt;
            edge.label_type = sanitizeNodeLabelType(t.type);
        }
        edge.type = link.type;
        edge.stroke = link.stroke;
        if (link.length) |l| edge.length = if (l > 10) 10 else l;
        var taken = false;
        if (id) |i| for (self.edges.items) |e| if (e.id != null and std.mem.eql(u8, e.id.?, i)) {
            taken = true;
        };
        if (id != null and id.?.len > 0 and !taken) {
            edge.id = id;
            edge.is_user_defined_id = true;
        } else {
            var existing: usize = 0;
            for (self.edges.items) |e| if (std.mem.eql(u8, e.start, start) and std.mem.eql(u8, e.end, end)) {
                existing += 1;
            };
            edge.id = try std.fmt.allocPrint(self.a, "L_{s}_{s}_{d}", .{ start, end, if (existing == 0) 0 else existing + 1 });
        }
        if (self.edges.items.len < self.cfg.max_edges) {
            try self.edges.append(self.a, edge);
        } else {
            return self.fail("Edge limit exceeded. {d} edges found, but the limit is {d}.\n\nInitialize mermaid with maxEdges set to a higher number to allow more edges.\nYou cannot set this config via configuration inside the diagram as it is a secure config.\nYou have to call mermaid.initialize.", .{ self.edges.items.len, self.cfg.max_edges });
        }
    }

    pub fn addLink(self: *Db, starts: []const []const u8, ends: []const []const u8, link: LinkInfo) Error!void {
        var id: ?[]const u8 = null;
        if (link.id) |i| id = try std.mem.replaceOwned(u8, self.a, i, "@", "");
        for (starts) |s| for (ends) |e| {
            const last_start = std.mem.eql(u8, s, starts[starts.len - 1]);
            const first_end = std.mem.eql(u8, e, ends[0]);
            try self.addSingleLink(s, e, link, if (last_start and first_end) id else null);
        };
    }

    fn edgeAt(self: *Db, pos: []const u8) ?*Edge {
        const n = std.fmt.parseInt(usize, pos, 10) catch return null;
        if (!std.mem.eql(u8, pos, std.fmt.allocPrint(self.a, "{d}", .{n}) catch return null)) return null;
        if (n >= self.edges.items.len) return null;
        return self.edges.items[n];
    }

    pub fn updateLinkInterpolate(self: *Db, positions: []const Pos, interpolate: []const u8) Error!void {
        for (positions) |p| switch (p) {
            .default => self.default_interpolate = interpolate,
            .index => |s| (self.edgeAt(s) orelse return self.fail("Cannot set properties of undefined (setting 'interpolate')", .{})).interpolate = interpolate,
        };
    }

    pub fn updateLink(self: *Db, positions: []const Pos, style: []const []const u8) Error!void {
        for (positions) |p| switch (p) {
            .default => self.default_style = style,
            .index => |s| {
                const e = self.edgeAt(s) orelse return self.fail("Cannot set properties of undefined (setting 'style')", .{});
                var l: List([]const u8) = .empty;
                try l.appendSlice(self.a, style);
                var has_fill = false;
                for (l.items) |x| if (std.mem.startsWith(u8, x, "fill")) {
                    has_fill = true;
                };
                if (l.items.len > 0 and !has_fill) try l.append(self.a, "fill:none");
                e.style = l;
            },
        };
    }

    pub fn addClass(self: *Db, ids: []const u8, styles_in: []const []const u8) Error!void {
        const joined = try std.mem.join(self.a, ",", styles_in);
        const a1 = try std.mem.replaceOwned(u8, self.a, joined, "\\,", "\u{a7}\u{a7}\u{a7}");
        const a2 = try std.mem.replaceOwned(u8, self.a, a1, ",", ";");
        const a3 = try std.mem.replaceOwned(u8, self.a, a2, "\u{a7}\u{a7}\u{a7}", ",");
        var it = std.mem.splitScalar(u8, ids, ',');
        while (it.next()) |id| {
            const gop = try self.classes.getOrPut(self.a, id);
            if (!gop.found_existing) {
                const c = try self.a.create(Class);
                c.* = .{ .id = id };
                gop.value_ptr.* = c;
            }
            const cls = gop.value_ptr.*;
            var sp = std.mem.splitScalar(u8, a3, ';');
            while (sp.next()) |s| {
                if (std.mem.indexOf(u8, s, "color") != null) {
                    const ns = if (std.mem.indexOf(u8, s, "fill")) |k|
                        try std.mem.concat(self.a, u8, &.{ s[0..k], "bgFill", s[k + 4 ..] })
                    else
                        s;
                    try cls.text_styles.append(self.a, ns);
                }
                try cls.styles.append(self.a, s);
            }
        }
    }

    pub fn setDirection(self: *Db, dir: []const u8) Allocator.Error!void {
        var d = std.mem.trim(u8, dir, " \t\r\n");
        const has = std.mem.indexOfScalar;
        if (has(u8, d, '<') != null) d = "RL";
        if (has(u8, d, '^') != null) d = "BT";
        if (has(u8, d, '>') != null) d = "LR";
        if (has(u8, d, 'v') != null) d = "TB";
        if (std.mem.eql(u8, d, "TD")) d = "TB";
        self.direction = d;
    }

    pub fn setClass(self: *Db, ids: []const u8, class_name: []const u8) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, ids, ',');
        while (it.next()) |id| {
            if (self.vertices.get(id)) |v| try v.classes.append(self.a, class_name);
            for (self.edges.items) |e| if (e.id != null and std.mem.eql(u8, e.id.?, id)) {
                try e.classes.append(self.a, class_name);
                break;
            };
            if (self.sub_graph_lookup.get(id)) |s| try s.classes.append(self.a, class_name);
        }
    }

    pub fn setTooltip(self: *Db, ids: []const u8, tooltip: []const u8) Allocator.Error!void {
        const t = try self.sanitizeText(tooltip);
        var it = std.mem.splitScalar(u8, ids, ',');
        while (it.next()) |id| try self.tooltips.put(self.a, id, t);
    }

    pub fn setClickEvent(self: *Db, ids: []const u8, function_name: ?[]const u8) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, ids, ',');
        while (it.next()) |id| {
            if (!eq(self.cfg.security_level, "loose") or function_name == null) continue;
            if (self.vertices.get(id)) |v| v.have_callback = true;
        }
        try self.setClass(ids, "clickable");
    }

    pub fn setLink(self: *Db, ids: []const u8, link_str: []const u8, target: ?[]const u8) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, ids, ',');
        while (it.next()) |id| {
            if (self.vertices.get(id)) |v| {
                v.link = self.formatUrl(link_str);
                v.link_target = target;
            }
        }
        try self.setClass(ids, "clickable");
    }

    fn formatUrl(self: *Db, link_str: []const u8) ?[]const u8 {
        const url = std.mem.trim(u8, link_str, " \t\r\n");
        if (url.len == 0) return null;
        if (eq(self.cfg.security_level, "loose")) return url;
        return sanitizeUrl(url);
    }

    pub fn getTooltip(self: *Db, id: []const u8) ?[]const u8 {
        return self.tooltips.get(id);
    }

    pub fn getDirection(self: *Db) ?[]const u8 {
        const d = self.direction orelse return null;
        return std.mem.trim(u8, d, " \t\r\n");
    }

    pub fn firstGraph(self: *Db) bool {
        if (self.first_graph_flag) {
            self.first_graph_flag = false;
            return true;
        }
        return false;
    }

    pub fn setAccTitle(self: *Db, t: []const u8) void {
        self.acc_title = t;
    }

    pub fn setAccDescription(self: *Db, t: []const u8) void {
        self.acc_descr = t;
    }

    pub fn setDiagramTitle(self: *Db, t: []const u8) Allocator.Error!void {
        self.diagram_title = try self.sanitizeText(t);
    }

    fn exists(self: *Db, id: []const u8) bool {
        for (self.sub_graphs.items) |sg| for (sg.nodes) |n| if (std.mem.eql(u8, n, id)) return true;
        return false;
    }

    pub fn addSubGraph(self: *Db, id_in: ?FlowText, list: []const DocItem, title_in: ?FlowText, title_is_id: bool) Error![]const u8 {
        const idt = id_in orelse return self.fail("Cannot read properties of undefined (reading 'text')", .{});
        var id: ?[]const u8 = std.mem.trim(u8, idt.text, " \t\r\n");
        var title: []const u8 = if (title_in) |t| t.text else "";
        if (title_is_id) {
            for (title) |c| if (std.ascii.isWhitespace(c)) {
                id = null;
                break;
            };
        }

        var names: List([]const u8) = .empty;
        var dir: ?[]const u8 = null;
        for (list) |item| switch (item) {
            .dir => |d| dir = d,
            .name => |n| {
                if (std.mem.trim(u8, n, " \t\r\n").len == 0) continue;
                var dup = false;
                for (names.items) |x| if (std.mem.eql(u8, x, n)) {
                    dup = true;
                };
                if (!dup) try names.append(self.a, n);
            },
        };

        const eff_dir: ?[]const u8 = dir orelse if (self.cfg.inherit_dir) (self.getDirection()) else null;
        const sid = id orelse try std.fmt.allocPrint(self.a, "subGraph{d}", .{self.sub_count});
        title = std.mem.trim(u8, try self.sanitizeText(title), " \t\r\n");
        self.sub_count += 1;

        var kept: List([]const u8) = .empty;
        for (names.items) |n| if (!self.exists(n) and !std.mem.eql(u8, n, sid)) try kept.append(self.a, n);

        const sg = try self.a.create(SubGraph);
        sg.* = .{
            .id = sid,
            .nodes = kept.items,
            .title = title,
            .dir = eff_dir,
            .label_type = sanitizeNodeLabelType(if (title_in) |t| t.type else null),
        };
        var existing: ?*SubGraph = null;
        for (self.sub_graphs.items) |x| if (std.mem.eql(u8, x.id, sid)) {
            existing = x;
            break;
        };
        if (existing) |ex| {
            ex.nodes = try std.mem.concat(self.a, []const u8, &.{ ex.nodes, sg.nodes });
        } else try self.sub_graphs.append(self.a, sg);
        try self.sub_graph_lookup.put(self.a, sid, existing orelse sg);
        return sid;
    }

    pub fn destructLink(self: *Db, str_in: []const u8, start_str: ?[]const u8) Allocator.Error!LinkInfo {
        _ = self;
        const info = destructEndLink(str_in);
        const ss = start_str orelse return info;
        if (ss.len == 0) return info;
        var st = destructStartLink(ss);
        if (!eq(st.stroke, info.stroke)) return .{ .type = "INVALID", .stroke = "INVALID" };
        if (eq(st.type, "arrow_open")) {
            st.type = info.type;
        } else {
            if (!eq(st.type, info.type)) return .{ .type = "INVALID", .stroke = "INVALID" };
            st.type = if (eq(st.type, "arrow_point")) "double_arrow_point" else if (eq(st.type, "arrow_cross")) "double_arrow_cross" else "double_arrow_circle";
        }
        st.length = info.length;
        return st;
    }

    fn getCompiledStyles(self: *Db, class_defs: []const []const u8) Allocator.Error![]const []const u8 {
        var out: List([]const u8) = .empty;
        for (class_defs) |c| {
            const cls = self.classes.get(c) orelse continue;
            for (cls.styles.items) |s| try out.append(self.a, std.mem.trim(u8, s, " \t\r\n"));
            for (cls.text_styles.items) |s| try out.append(self.a, std.mem.trim(u8, s, " \t\r\n"));
        }
        return out.items;
    }

    fn typeFromVertex(v: *const Vertex) []const u8 {
        if (v.img != null) return "imageSquare";
        if (v.icon != null) {
            const f = v.form orelse return "icon";
            if (eq(f, "circle")) return "iconCircle";
            if (eq(f, "square")) return "iconSquare";
            if (eq(f, "rounded")) return "iconRounded";
            return "icon";
        }
        const t = v.type orelse return "squareRect";
        if (eq(t, "square")) return "squareRect";
        if (eq(t, "round")) return "roundedRect";
        return t;
    }

    fn joinSpace(self: *Db, items: []const []const u8) Allocator.Error![]const u8 {
        return std.mem.join(self.a, " ", items);
    }

    fn walkDecl(self: *Db, id: []const u8, children_of: *const std.StringHashMapUnmanaged(List([]const u8)), idx: *std.StringHashMapUnmanaged(usize), next: *usize) Allocator.Error!void {
        try idx.put(self.a, id, next.*);
        next.* += 1;
        if (children_of.get(id)) |kids| for (kids.items) |k| try self.walkDecl(k, children_of, idx, next);
    }

    fn outermostCollapsed(self: *Db, id: []const u8, sg_parent: *const std.StringHashMapUnmanaged([]const u8)) ?[]const u8 {
        var result: ?[]const u8 = null;
        var cur: ?[]const u8 = id;
        var guard: usize = 0;
        while (cur) |c| : (guard += 1) {
            if (guard > self.sub_graphs.items.len + 1) break;
            if (self.sub_graph_lookup.get(c)) |sg| if (sg.collapsed) {
                result = c;
            };
            cur = sg_parent.get(c);
        }
        return result;
    }

    pub fn getData(self: *Db) Allocator.Error!model.LayoutData {
        const cfg = self.cfg;
        var nodes: List(model.NodeData) = .empty;
        var parent_db: std.StringHashMapUnmanaged([]const u8) = .empty;
        var sub_db: std.StringHashMapUnmanaged(void) = .empty;

        var i: usize = self.sub_graphs.items.len;
        while (i > 0) {
            i -= 1;
            const sg = self.sub_graphs.items[i];
            if (sg.nodes.len > 0) try sub_db.put(self.a, sg.id, {});
            for (sg.nodes) |n| try parent_db.put(self.a, n, sg.id);
        }

        var sg_parent: std.StringHashMapUnmanaged([]const u8) = .empty;
        var children_of: std.StringHashMapUnmanaged(List([]const u8)) = .empty;
        for (self.sub_graphs.items) |sg| for (sg.nodes) |c| {
            if (self.sub_graph_lookup.contains(c)) try sg_parent.put(self.a, c, sg.id);
        };
        for (self.sub_graphs.items) |sg| {
            const p = sg_parent.get(sg.id) orelse continue;
            const gop = try children_of.getOrPut(self.a, p);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.a, sg.id);
        }
        var decl_index: std.StringHashMapUnmanaged(usize) = .empty;
        var next_index: usize = 0;
        for (self.sub_graphs.items) |sg| if (!sg_parent.contains(sg.id)) try self.walkDecl(sg.id, &children_of, &decl_index, &next_index);

        var hidden: std.StringHashMapUnmanaged(void) = .empty;
        var anc_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (self.sub_graphs.items) |sg| {
            const ancestor = self.outermostCollapsed(sg.id, &sg_parent) orelse continue;
            if (!std.mem.eql(u8, sg.id, ancestor)) {
                try hidden.put(self.a, sg.id, {});
                try anc_map.put(self.a, sg.id, ancestor);
            }
            for (sg.nodes) |c| {
                if (std.mem.eql(u8, c, ancestor)) continue;
                try hidden.put(self.a, c, {});
                try anc_map.put(self.a, c, ancestor);
            }
        }

        i = self.sub_graphs.items.len;
        while (i > 0) {
            i -= 1;
            const sg = self.sub_graphs.items[i];
            if (hidden.contains(sg.id)) continue;
            const collapsed = sg.collapsed;
            try nodes.append(self.a, .{
                .id = sg.id,
                .label = sg.title,
                .label_type = sg.label_type,
                .parent_id = parent_db.get(sg.id),
                .padding = 8,
                .css_compiled_styles = try self.getCompiledStyles(sg.classes.items),
                .css_classes = try self.joinSpace(sg.classes.items),
                .shape = if (collapsed) "collapsedGroup" else "rect",
                .dir = sg.dir,
                .is_group = !collapsed,
                .look = cfg.look,
                .color_index = decl_index.get(sg.id),
            });
        }

        for (self.vertices.values()) |v| {
            if (hidden.contains(v.id)) continue;
            const parent_id = parent_db.get(v.id);
            const is_group = sub_db.contains(v.id);
            var existing: ?*model.NodeData = null;
            for (nodes.items) |*n| if (std.mem.eql(u8, n.id, v.id)) {
                existing = n;
                break;
            };
            if (existing) |n| {
                n.css_styles = v.styles.items;
                n.css_compiled_styles = try self.getCompiledStyles(v.classes.items);
                n.css_classes = try self.joinSpace(v.classes.items);
                continue;
            }
            var cls_list: List([]const u8) = .empty;
            try cls_list.appendSlice(self.a, &.{ "default", "node" });
            try cls_list.appendSlice(self.a, v.classes.items);
            try nodes.append(self.a, .{
                .id = v.id,
                .label = v.text,
                .label_type = v.label_type,
                .parent_id = parent_id,
                .padding = if (cfg.padding != 0) cfg.padding else 8,
                .css_styles = v.styles.items,
                .css_compiled_styles = try self.getCompiledStyles(cls_list.items),
                .css_classes = try std.mem.concat(self.a, u8, &.{ "default ", try self.joinSpace(v.classes.items) }),
                .dir = v.dir,
                .dom_id = v.dom_id,
                .look = cfg.look,
                .link = v.link,
                .link_target = if (v.link != null) "_parent" else v.link_target,
                .min_width = cfg.min_node_width,
                .tooltip = self.getTooltip(v.id),
                .icon = v.icon,
                .pos = v.pos,
                .img = v.img,
                .asset_width = v.asset_width,
                .asset_height = v.asset_height,
                .constraint = v.constraint,
                .have_callback = v.have_callback,
                .is_group = is_group,
                .shape = if (is_group) "rect" else typeFromVertex(v),
            });
        }

        var edges: List(model.EdgeData) = .empty;
        for (self.edges.items, 0..) |raw, index| {
            var arrow_start: []const u8 = "none";
            var arrow_end: []const u8 = "arrow_point";
            if (raw.type) |t| {
                if (eq(t, "arrow_point") or eq(t, "arrow_circle") or eq(t, "arrow_cross")) {
                    arrow_end = t;
                } else if (eq(t, "double_arrow_point") or eq(t, "double_arrow_circle") or eq(t, "double_arrow_cross")) {
                    arrow_start = t["double_".len..];
                    arrow_end = arrow_start;
                }
            }
            var styles: List([]const u8) = .empty;
            if (self.default_style) |ds| try styles.appendSlice(self.a, ds);
            if (raw.style) |s| try styles.appendSlice(self.a, s.items);
            const stroke = raw.stroke orelse "";
            const invisible = eq(stroke, "invisible");
            const hide_arrows = invisible or (raw.type != null and eq(raw.type.?, "arrow_open"));
            const start = anc_map.get(raw.start) orelse raw.start;
            const end = anc_map.get(raw.end) orelse raw.end;
            if (std.mem.eql(u8, start, end) and (anc_map.contains(raw.start) or anc_map.contains(raw.end))) continue;
            const id = raw.id orelse try std.fmt.allocPrint(self.a, "L_{s}_{s}_{d}", .{ start, end, index });
            try edges.append(self.a, .{
                .id = id,
                .is_user_defined_id = raw.is_user_defined_id,
                .start = start,
                .end = end,
                .type = raw.type orelse "normal",
                .label = raw.text,
                .label_type = raw.label_type,
                .labelpos = "c",
                .thickness = stroke,
                .minlen = raw.length orelse 1,
                .classes = if (invisible) "" else "edge-thickness-normal edge-pattern-solid flowchart-link",
                .arrow_type_start = if (hide_arrows) "none" else arrow_start,
                .arrow_type_end = if (hide_arrows) "none" else arrow_end,
                .arrowhead_style = "fill: #333",
                .css_compiled_styles = try self.getCompiledStyles(raw.classes.items),
                .label_style = styles.items,
                .style = styles.items,
                .pattern = stroke,
                .look = cfg.look,
                .animate = raw.animate orelse false,
                .animation = raw.animation,
                .curve = raw.interpolate orelse self.default_interpolate orelse cfg.curve,
            });
        }

        return .{
            .nodes = nodes.items,
            .edges = edges.items,
            .direction = self.getDirection() orelse "TB",
            .diagram_id = self.diagram_id,
            .config = cfg.*,
            .title = self.diagram_title,
        };
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn try_print(a: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch "out of memory";
}

fn lower(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    const o = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}

fn destructStartLink(str_in: []const u8) LinkInfo {
    var s = std.mem.trim(u8, str_in, " \t\r\n");
    var t: []const u8 = "arrow_open";
    if (s.len > 0) switch (s[0]) {
        '<' => {
            t = "arrow_point";
            s = s[1..];
        },
        'x' => {
            t = "arrow_cross";
            s = s[1..];
        },
        'o' => {
            t = "arrow_circle";
            s = s[1..];
        },
        else => {},
    };
    var stroke: []const u8 = "normal";
    if (std.mem.indexOfScalar(u8, s, '=') != null) stroke = "thick";
    if (std.mem.indexOfScalar(u8, s, '.') != null) stroke = "dotted";
    return .{ .type = t, .stroke = stroke };
}

fn destructEndLink(str_in: []const u8) LinkInfo {
    const s = std.mem.trim(u8, str_in, " \t\r\n");
    if (s.len == 0) return .{ .type = "arrow_open", .stroke = "normal", .length = -1 };
    var line = s[0 .. s.len - 1];
    var t: []const u8 = "arrow_open";
    switch (s[s.len - 1]) {
        'x' => {
            t = "arrow_cross";
            if (s[0] == 'x') {
                t = "double_arrow_cross";
                line = line[1..];
            }
        },
        '>' => {
            t = "arrow_point";
            if (s[0] == '<') {
                t = "double_arrow_point";
                line = line[1..];
            }
        },
        'o' => {
            t = "arrow_circle";
            if (s[0] == 'o') {
                t = "double_arrow_circle";
                line = line[1..];
            }
        },
        else => {},
    }
    var stroke: []const u8 = "normal";
    var length: f64 = @as(f64, @floatFromInt(line.len)) - 1;
    if (line.len > 0 and line[0] == '=') stroke = "thick";
    if (line.len > 0 and line[0] == '~') stroke = "invisible";
    const dots = std.mem.count(u8, line, ".");
    if (dots > 0) {
        stroke = "dotted";
        length = @floatFromInt(dots);
    }
    return .{ .type = t, .stroke = stroke, .length = length };
}

fn sanitizeUrl(url: []const u8) []const u8 {
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    for (url) |c| {
        if (c <= 32 or c == 127) continue;
        if (c == ':') break;
        if (n == buf.len) return url;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    if (n == url.len) return url;
    const scheme = buf[0..n];
    if (eq(scheme, "javascript") or eq(scheme, "data") or eq(scheme, "vbscript")) return "about:blank";
    return url;
}

pub fn isValidShape(s: []const u8) bool {
    for (valid_shapes) |v| if (std.mem.eql(u8, v, s)) return true;
    return false;
}

const valid_shapes = [_][]const u8{
    "state",           "choice",           "note",          "rectWithTitle",   "labelRect",           "iconSquare",   "iconCircle",
    "icon",            "iconRounded",      "imageSquare",   "anchor",          "kanbanItem",          "mindmapCircle", "defaultMindmapNode",
    "classBox",        "erBox",            "requirementBox", "rect",           "rounded",             "stadium",      "fr-rect",
    "cyl",             "datastore",        "circle",        "bang",            "cloud",               "diam",         "hex",
    "lean-r",          "lean-l",           "trap-b",        "trap-t",          "dbl-circ",            "text",         "notch-rect",
    "lin-rect",        "sm-circ",          "fr-circ",       "fork",            "hourglass",           "brace",        "brace-r",
    "braces",          "bolt",             "doc",           "delay",           "h-cyl",               "lin-cyl",      "curv-trap",
    "div-rect",        "tri",              "win-pane",      "f-circ",          "notch-pent",          "flip-tri",     "sl-rect",
    "docs",            "st-rect",          "bow-rect",      "cross-circ",      "tag-doc",             "tag-rect",     "flag",
    "odd",             "lin-doc",          "proc",          "process",         "rectangle",           "squareRect",   "event",
    "roundedRect",     "terminal",         "pill",          "subprocess",      "subproc",             "framed-rectangle", "subroutine",
    "db",              "database",         "cylinder",      "data-store",      "circ",                "decision",     "diamond",
    "question",        "hexagon",          "prepare",       "lean-right",      "in-out",              "lean_right",   "lean-left",
    "out-in",          "lean_left",        "priority",      "trapezoid-bottom", "trapezoid",          "manual",       "trapezoid-top",
    "inv-trapezoid",   "inv_trapezoid",    "double-circle", "doublecircle",    "card",                "notched-rectangle", "lined-rectangle",
    "lined-process",   "lin-proc",         "shaded-process", "start",          "small-circle",        "stateStart",   "stop",
    "framed-circle",   "stateEnd",         "join",          "forkJoin",        "collate",             "comment",      "brace-l",
    "com-link",        "lightning-bolt",   "document",      "half-rounded-rectangle", "das",          "horizontal-cylinder", "disk",
    "lined-cylinder",  "curved-trapezoid", "display",       "div-proc",        "divided-rectangle",   "divided-process", "extract",
    "triangle",        "internal-storage", "window-pane",   "junction",        "filled-circle",       "loop-limit",   "notched-pentagon",
    "manual-file",     "flipped-triangle", "manual-input",  "sloped-rectangle", "documents",          "st-doc",       "stacked-document",
    "procs",           "processes",        "stacked-rectangle", "stored-data", "bow-tie-rectangle",   "summary",      "crossed-circle",
    "tagged-document", "tagged-rectangle", "tag-proc",      "tagged-process",  "paper-tape",          "rect_left_inv_arrow", "lined-document",
};

fn brLen(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != '<' or std.ascii.toLower(s[1]) != 'b' or std.ascii.toLower(s[2]) != 'r') return null;
    var i: usize = 3;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i < s.len and s[i] == '/') i += 1;
    if (i < s.len and s[i] == '>') return i + 1;
    return null;
}

const allowed_tags = [_][]const u8{
    "a",   "abbr",     "acronym", "address", "article", "aside",  "b",      "bdi",    "bdo",   "big",  "blockquote", "br",     "button",
    "caption", "center", "cite",  "code",    "col",     "colgroup", "dd",   "del",    "details", "dfn", "dir",        "div",    "dl",
    "dt",  "em",       "figcaption", "figure", "font",  "footer", "h1",     "h2",     "h3",    "h4",   "h5",         "h6",     "header",
    "hr",  "i",        "img",     "ins",     "kbd",     "label",  "legend", "li",     "main",  "mark", "nav",        "ol",     "p",
    "pre", "q",        "rp",      "rt",      "ruby",    "s",      "samp",   "section", "small", "span", "strike",     "strong", "sub",
    "summary", "sup",  "table",   "tbody",   "td",      "tfoot",  "th",     "thead",  "time",  "tr",   "tt",         "u",      "ul",
    "var", "wbr",
};

const void_tags = [_][]const u8{ "br", "hr", "img", "wbr", "col" };
const drop_content_tags = [_][]const u8{ "script", "style", "iframe", "noscript", "noembed", "noframes", "xmp", "plaintext", "title", "textarea", "template" };
const allowed_attrs = [_][]const u8{ "href", "src", "alt", "class", "id", "style", "title", "target", "rel", "color", "width", "height", "align", "name", "dir", "lang", "colspan", "rowspan" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}


fn appendText(o: *List(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '&' => try o.appendSlice(a, "&amp;"),
        '<' => try o.appendSlice(a, "&lt;"),
        '>' => try o.appendSlice(a, "&gt;"),
        0xC2 => if (i + 1 < s.len and s[i + 1] == 0xA0) {
            try o.appendSlice(a, "&nbsp;");
            i += 1;
        } else try o.append(a, s[i]),
        else => |c| try o.append(a, c),
    };
}

fn appendAttr(o: *List(u8), a: Allocator, at: html.Attr) Allocator.Error!void {
    if (!inList(&allowed_attrs, at.name)) return;
    const url_attr = eq(at.name, "href") or eq(at.name, "src");
    const val = std.mem.trim(u8, at.value, " \t\r\n");
    if (url_attr and !eq(sanitizeUrl(val), val)) return;
    try o.append(a, ' ');
    try o.appendSlice(a, at.name);
    try o.appendSlice(a, "=\"");
    for (at.value) |c| switch (c) {
        '&' => try o.appendSlice(a, "&amp;"),
        '"' => try o.appendSlice(a, "&quot;"),
        else => try o.append(a, c),
    };
    try o.append(a, '"');
}

fn closeTo(o: *List(u8), a: Allocator, stack: *List([]const u8), name: []const u8) Allocator.Error!void {
    var k = stack.items.len;
    while (k > 0) {
        k -= 1;
        if (!eq(stack.items[k], name)) continue;
        while (stack.items.len > k) {
            const t = stack.pop().?;
            try o.appendSlice(a, "</");
            try o.appendSlice(a, t);
            try o.append(a, '>');
        }
        return;
    }
}

/// DOMPurify as Mermaid's sanitizeText uses it: tokenised with the viewer's HTML tokenizer, disallowed tags and
/// attributes dropped, script-like elements removed with their content, open tags closed at the end.
pub fn purify(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "<&>") == null) return s;
    var tk = html.Tokenizer.init(a, s);
    var o: List(u8) = .empty;
    var stack: List([]const u8) = .empty;
    var skip: ?[]const u8 = null;
    while (try tk.next()) |tok| switch (tok) {
        .text => |t| if (skip == null) try appendText(&o, a, t),
        .comment, .doctype => {},
        .end => |name| {
            if (skip) |su| {
                if (eq(su, name)) skip = null;
                continue;
            }
            if (inList(&allowed_tags, name)) try closeTo(&o, a, &stack, name);
        },
        .start => |st| {
            if (skip != null) continue;
            if (inList(&drop_content_tags, st.name)) {
                if (!st.self_closing) skip = st.name;
                continue;
            }
            if (!inList(&allowed_tags, st.name)) continue;
            try o.append(a, '<');
            try o.appendSlice(a, st.name);
            for (st.attrs) |at| try appendAttr(&o, a, at);
            try o.append(a, '>');
            if (!inList(&void_tags, st.name)) try stack.append(a, st.name);
        },
    };
    while (stack.pop()) |t| {
        try o.appendSlice(a, "</");
        try o.appendSlice(a, t);
        try o.append(a, '>');
    }
    return o.items;
}

test "purify drops script, event handlers and javascript urls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hi ", try purify(a, "hi <script>alert(1)</script>"));
    try std.testing.expectEqualStrings("<img src=\"x\">", try purify(a, "<img src=\"x\" onerror=\"alert(1)\">"));
    try std.testing.expectEqualStrings("<b>a</b><i>b</i>", try purify(a, "<b>a</b><i>b</i>"));
    try std.testing.expectEqualStrings("<b>open</b>", try purify(a, "<b>open"));
    try std.testing.expectEqualStrings("<a>x</a>", try purify(a, "<a href=\"javascript:alert(1)\">x</a>"));
    try std.testing.expectEqualStrings("a &amp; b &lt; c", try purify(a, "a &amp; b &lt; c"));
}
