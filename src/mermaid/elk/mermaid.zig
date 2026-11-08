const std = @import("std");
const Allocator = std.mem.Allocator;
const eg = @import("elk_graph.zig");
const layered = @import("layered.zig");
const geo = @import("geometry.zig");
const lg = @import("lgraph.zig");

const P = geo.P;
const Rect = geo.Rect;

pub const Error = lg.Error || error{UnknownNode};

pub const Dir = enum { tb, td, bt, lr, rl };

// One node of Mermaid's LayoutData. `width`/`height` are the measured size of a leaf; for a group they
// are ignored. `label_w`/`label_h` are the measured group title (labelData).
pub const Node = struct {
    id: []const u8,
    parent_id: ?[]const u8 = null,
    is_group: bool = false,
    width: f64 = 0,
    height: f64 = 0,
    label_text: []const u8 = "",
    label_w: f64 = 0,
    label_h: f64 = 0,
    padding: f64 = 0,
    dir: ?Dir = null,
    paints_title: bool = true,
    skip_center_points: bool = false,
    intersect: ?geo.Intersect = null,
    outline: Outline = .none,
};

pub const Outline = enum { none, rect, diamond, circle };

pub const Edge = struct {
    id: []const u8,
    start: []const u8,
    end: []const u8,
    label_text: []const u8 = "",
    label_w: f64 = 0,
    label_h: f64 = 0,
    arrow_type_start: []const u8 = "none",
    arrow_type_end: []const u8 = "none",
};

pub const Config = struct {
    direction: Dir = .tb,
    straighten_edges: bool = true,
    orient_feedback_edges: bool = true,
};

pub const NodeOut = struct { x: f64, y: f64, width: f64, height: f64 };

pub const EdgeOut = struct {
    points: []const P,
    has_label_pos: bool,
    x: f64,
    y: f64,
};

pub const Result = struct {
    nodes: []NodeOut,
    edges: []EdgeOut,
};

const ports_surrounding = "[top=12,left=12,bottom=12,right=12]";
const subgraph_padding: f64 = 24;
const ports_surrounding_margin: f64 = 12;
const min_end_marker_segment_length: f64 = 8;

fn elkDirection(d: Dir) []const u8 {
    return switch (d) {
        .lr => "RIGHT",
        .rl => "LEFT",
        .tb, .td => "DOWN",
        .bt => "UP",
    };
}

fn markerPathOffset(name: []const u8) f64 {
    const Entry = struct { []const u8, f64 };
    const t1 = [_]Entry{ .{ "aggregation", 17.25 }, .{ "extension", 17.25 }, .{ "composition", 17.25 }, .{ "dependency", 6 }, .{ "lollipop", 13.5 }, .{ "arrow_point", 4 }, .{ "arrow_barb", 0 }, .{ "arrow_barb_neo", 5.5 } };
    const t2 = [_]Entry{ .{ "arrow_point", 4 }, .{ "arrow_cross", 12.5 }, .{ "arrow_circle", 12.5 } };
    var best: f64 = 0;
    for (t1) |e| if (std.mem.eql(u8, e[0], name)) {
        best = @max(best, e[1]);
    };
    for (t2) |e| if (std.mem.eql(u8, e[0], name)) {
        best = @max(best, e[1]);
    };
    return best;
}

const State = struct {
    a: Allocator,
    nodes: []const Node,
    index: std.StringHashMap(usize),
    parent: []?usize,
    children: []std.ArrayList(usize),
    elk: []?*eg.ElkNode,
    // working geometry
    x: []f64,
    y: []f64,
    w: []f64,
    h: []f64,
    pos_x: []f64,
    pos_y: []f64,
    origin: []?P,
    has_offset: []bool,
    // layout-time label and edge records
    edges: []const Edge,
    elk_edges: []*eg.ElkEdge,
    reversed: []bool,

    fn id(self: *const State, i: usize) []const u8 {
        return self.nodes[i].id;
    }

    fn lookup(self: *const State, name: []const u8) ?usize {
        return self.index.get(name);
    }

    fn isect(self: *const State, i: usize, tmp: *Rect) ?geo.Intersect {
        const n = self.nodes[i];
        if (n.intersect) |f| return f;
        if (n.outline == .none) return null;
        tmp.* = .{ .x = self.x[i], .y = self.y[i], .width = self.w[i], .height = self.h[i] };
        return .{ .ctx = tmp, .f = switch (n.outline) {
            .rect => rectIntersect,
            .diamond => diamondIntersect,
            .circle => circleIntersect,
            .none => unreachable,
        } };
    }

    fn groupTitleWidth(self: *const State, i: usize) f64 {
        const n = self.nodes[i];
        if (!n.paints_title) return 0;
        return n.label_w + n.padding;
    }

    fn bounds(self: *const State, i: usize) Rect {
        const n = self.nodes[i];
        const width = if (n.is_group) @max(self.w[i], self.groupTitleWidth(i)) else self.w[i];
        return .{ .x = self.pos_x[i] + self.w[i] / 2, .y = self.pos_y[i] + self.h[i] / 2, .width = width, .height = self.h[i] };
    }

    // findCommonAncestor over parentById; null stands for 'root'
    fn commonAncestor(self: *const State, id1: usize, id2: usize) ?usize {
        if (id1 == id2) return self.parent[id1];
        var cur: ?usize = id1;
        var visited: std.ArrayList(usize) = .empty;
        defer visited.deinit(self.a);
        while (cur) |c| {
            visited.append(self.a, c) catch return null;
            if (c == id2) return c;
            cur = self.parent[c];
        }
        cur = id2;
        while (cur) |c| {
            for (visited.items) |v| if (v == c) return c;
            cur = self.parent[c];
        }
        return null;
    }

    fn calcOffset(self: *const State, src: usize, dest: usize) P {
        const anc = self.commonAncestor(src, dest) orelse return .{ .x = 0, .y = 0 };
        if (self.origin[anc]) |o| return o;
        if (self.has_offset[anc]) return .{ .x = self.pos_x[anc], .y = self.pos_y[anc] };
        return .{ .x = 0, .y = 0 };
    }
};

fn fmtNum(a: Allocator, v: f64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v});
}

fn setOpts(o: *eg.Options, kv: []const [2][]const u8) void {
    for (kv) |p| eg.setOption(o, p[0], p[1]);
}

fn subgraphOptions(st: *const State, i: usize, o: *eg.Options) Allocator.Error!void {
    const n = st.nodes[i];
    if (n.paints_title) {
        eg.setOption(o, "nodeSize.constraints", "[MINIMUM_SIZE, NODE_LABELS]");
        eg.setOption(o, "nodeSize.minimum", try std.fmt.allocPrint(st.a, "({d}, 0)", .{st.groupTitleWidth(i)}));
    }
    setOpts(o, &.{
        .{ "spacing.baseValue", "24" },
        .{ "elk.layered.spacing.edgeNodeBetweenLayers", "30" },
        .{ "elk.spacing.edgeEdge", "20" },
        .{ "spacing.nodeNode", "50" },
        .{ "elk.padding", "[top=24,left=24,bottom=24,right=24]" },
        .{ "nodeLabels.placement", "[H_CENTER V_TOP, INSIDE]" },
        .{ "elk.layered.mergeEdges", "false" },
        .{ "elk.layered.nodePlacement.bk.fixedAlignment", "BALANCED" },
        .{ "elk.layered.nodePlacement.strategy", "BRANDES_KOEPF" },
        .{ "elk.layered.cycleBreaking.strategy", "DEPTH_FIRST" },
        .{ "elk.layered.nodePlacement.networkSimplex.nodeFlexibility", "PORT_POSITION" },
        .{ "elk.spacing.portsSurrounding", ports_surrounding },
    });
    if (n.dir) |d| {
        eg.setOption(o, "elk.algorithm", "elk.layered");
        eg.setOption(o, "elk.direction", elkDirection(d));
        eg.setOption(o, "elk.hierarchyHandling", "SEPARATE_CHILDREN");
    }
}

fn addVertices(st: *State, parent_elk: *eg.ElkNode, parent: ?usize) Error!void {
    for (st.nodes, 0..) |_, i| {
        if (st.parent[i] != parent) continue;
        const n = st.nodes[i];
        const child = try eg.createNode(st.a, parent_elk, n.id);
        st.elk[i] = child;
        if (n.is_group) {
            try addVertices(st, child, i);
        } else {
            child.width = n.width;
            child.height = n.height;
        }
    }
}

// subgraphFeedbackEdges.ts
fn findFeedbackEdges(st: *State, flags: []bool) Error!void {
    const a = st.a;
    const Item = struct { index: usize, from: usize, to: usize, collapsed: bool };
    const Level = struct { anc: ?usize, items: std.ArrayList(Item) };
    var levels: std.ArrayList(Level) = .empty;
    for (st.edges, 0..) |e, idx| {
        const s = st.lookup(e.start) orelse continue;
        const t = st.lookup(e.end) orelse continue;
        if (s == t) continue;
        const anc = st.commonAncestor(s, t);
        if (anc != null and (anc.? == s or anc.? == t)) continue;
        const from = childOnPath(st, s, anc);
        const to = childOnPath(st, t, anc);
        var lv: ?*Level = null;
        for (levels.items) |*l| if (l.anc == anc) {
            lv = l;
            break;
        };
        if (lv == null) {
            try levels.append(a, .{ .anc = anc, .items = .empty });
            lv = &levels.items[levels.items.len - 1];
        }
        try lv.?.items.append(a, .{ .index = idx, .from = from, .to = to, .collapsed = from != s or to != t });
    }
    for (levels.items) |lv| {
        var nodes: std.ArrayList(usize) = .empty;
        var in_deg = std.AutoHashMap(usize, usize).init(a);
        var succ = std.AutoHashMap(usize, std.ArrayList(Item)).init(a);
        for (lv.items.items) |e| {
            for ([2]usize{ e.from, e.to }) |nd| {
                if (!succ.contains(nd)) {
                    try succ.put(nd, .empty);
                    try nodes.append(a, nd);
                    try in_deg.put(nd, 0);
                }
            }
            try succ.getPtr(e.from).?.append(a, e);
            in_deg.getPtr(e.to).?.* += 1;
        }
        var roots: std.ArrayList(usize) = .empty;
        for (nodes.items) |nd| if (in_deg.get(nd).? == 0) try roots.append(a, nd);
        try roots.appendSlice(a, nodes.items);
        var state = std.AutoHashMap(usize, u8).init(a);
        const Frame = struct { node: usize, next: usize };
        for (roots.items) |root| {
            if (state.contains(root)) continue;
            try state.put(root, 1);
            var stack: std.ArrayList(Frame) = .empty;
            try stack.append(a, .{ .node = root, .next = 0 });
            while (stack.items.len > 0) {
                const fr = &stack.items[stack.items.len - 1];
                const out = succ.get(fr.node).?;
                if (fr.next >= out.items.len) {
                    try state.put(fr.node, 2);
                    _ = stack.pop();
                    continue;
                }
                const edge = out.items[fr.next];
                fr.next += 1;
                const seen = state.get(edge.to);
                if (seen != null and seen.? == 1) {
                    flags[edge.index] = edge.collapsed;
                } else if (seen == null) {
                    try state.put(edge.to, 1);
                    try stack.append(a, .{ .node = edge.to, .next = 0 });
                }
            }
        }
    }
}

fn childOnPath(st: *const State, id: usize, anc: ?usize) usize {
    var cur = id;
    while (st.parent[cur] != anc) cur = st.parent[cur].?;
    return cur;
}

fn setIncludeChildren(st: *State, i: usize, anc: ?usize) void {
    const e = st.elk[i].?;
    e.opts.hierarchy_handling = .include_children;
    if (anc == null or i != anc.?) {
        if (st.parent[i]) |p| setIncludeChildren(st, p, anc);
    }
}

pub fn layout(a: Allocator, nodes: []const Node, edges: []const Edge, cfg: Config) Error!Result {
    const n = nodes.len;
    var st: State = .{
        .a = a,
        .nodes = nodes,
        .index = std.StringHashMap(usize).init(a),
        .parent = try a.alloc(?usize, n),
        .children = try a.alloc(std.ArrayList(usize), n),
        .elk = try a.alloc(?*eg.ElkNode, n),
        .x = try a.alloc(f64, n),
        .y = try a.alloc(f64, n),
        .w = try a.alloc(f64, n),
        .h = try a.alloc(f64, n),
        .pos_x = try a.alloc(f64, n),
        .pos_y = try a.alloc(f64, n),
        .origin = try a.alloc(?P, n),
        .has_offset = try a.alloc(bool, n),
        .edges = edges,
        .elk_edges = try a.alloc(*eg.ElkEdge, edges.len),
        .reversed = try a.alloc(bool, edges.len),
    };
    for (nodes, 0..) |nd, i| try st.index.put(nd.id, i);
    for (nodes, 0..) |nd, i| {
        st.parent[i] = if (nd.parent_id) |p| st.lookup(p) else null;
        st.children[i] = .empty;
        st.elk[i] = null;
        st.x[i] = 0;
        st.y[i] = 0;
        st.w[i] = 0;
        st.h[i] = 0;
        st.pos_x[i] = 0;
        st.pos_y[i] = 0;
        st.origin[i] = null;
        st.has_offset[i] = false;
    }
    for (nodes, 0..) |_, i| if (st.parent[i]) |p| try st.children[p].append(a, i);

    const root = try eg.createNode(a, null, "root");
    setOpts(&root.opts, &.{
        .{ "elk.hierarchyHandling", "INCLUDE_CHILDREN" },
        .{ "elk.algorithm", "elk.layered" },
        .{ "elk.layered.nodePlacement.strategy", "BRANDES_KOEPF" },
        .{ "elk.layered.nodePlacement.bk.fixedAlignment", "BALANCED" },
        .{ "elk.layered.mergeEdges", "false" },
        .{ "spacing.baseValue", "40" },
        .{ "elk.layered.crossingMinimization.forceNodeModelOrder", "false" },
        .{ "elk.layered.considerModelOrder.strategy", "NODES_AND_EDGES" },
        .{ "elk.layered.unnecessaryBendpoints", "true" },
        .{ "elk.layered.cycleBreaking.strategy", "DEPTH_FIRST" },
        .{ "elk.layered.layering.strategy", "NETWORK_SIMPLEX" },
        .{ "elk.layered.edgeRouting.selfLoopDistribution", "EQUALLY" },
        .{ "elk.layered.mergeHierarchyEdges", "true" },
        .{ "elk.spacing.portsSurrounding", ports_surrounding },
    });
    eg.setOption(&root.opts, "elk.direction", elkDirection(cfg.direction));

    try addVertices(&st, root, null);

    const flags = try a.alloc(bool, edges.len);
    @memset(flags, false);
    if (cfg.orient_feedback_edges) try findFeedbackEdges(&st, flags);

    for (edges, 0..) |e, k| {
        const s = st.lookup(e.start) orelse return error.UnknownNode;
        const t = st.lookup(e.end) orelse return error.UnknownNode;
        st.reversed[k] = flags[k];
        const from = if (flags[k]) t else s;
        const to = if (flags[k]) s else t;
        const ee = try eg.connect(a, root, e.id, st.elk[from].?, st.elk[to].?);
        const l = try eg.createLabel(a, &ee.labels, e.label_text);
        l.width = e.label_w;
        l.height = e.label_h;
        eg.setOption(&l.opts, "edgeLabels.inline", "true");
        eg.setOption(&l.opts, "edgeLabels.placement", "CENTER");
        st.elk_edges[k] = ee;
    }

    for (nodes, 0..) |nd, i| {
        if (!nd.is_group or st.children[i].items.len == 0) continue;
        const en = st.elk[i].?;
        const l = try eg.createLabel(a, &en.labels, nd.label_text);
        l.width = nd.label_w;
        l.height = nd.label_h;
        try subgraphOptions(&st, i, &en.opts);
    }
    for (edges) |e| {
        const s = st.lookup(e.start).?;
        const t = st.lookup(e.end).?;
        if (st.parent[s] != st.parent[t]) {
            const anc = st.commonAncestor(s, t);
            setIncludeChildren(&st, s, anc);
            setIncludeChildren(&st, t, anc);
        }
    }

    try layered.layout(a, root);

    try applyPositions(&st, root, 0, 0);
    try evenGroupFrames(&st, root, null);

    const res: Result = .{ .nodes = try a.alloc(NodeOut, n), .edges = try a.alloc(EdgeOut, edges.len) };
    try applyEdgeLayout(&st, cfg, res.edges);
    for (0..n) |i| res.nodes[i] = .{ .x = st.x[i], .y = st.y[i], .width = st.w[i], .height = st.h[i] };
    return res;
}

fn applyPositions(st: *State, parent_elk: *eg.ElkNode, rel_x: f64, rel_y: f64) Error!void {
    for (parent_elk.children.items) |c| {
        const i = st.lookup(c.id).?;
        st.pos_x[i] = c.x + rel_x;
        st.pos_y[i] = c.y + rel_y;
        st.has_offset[i] = true;
        st.x[i] = st.pos_x[i] + c.width / 2;
        st.y[i] = st.pos_y[i] + c.height / 2;
        st.w[i] = c.width;
        st.h[i] = c.height;
        if (st.nodes[i].is_group) try applyPositions(st, c, st.pos_x[i], st.pos_y[i]);
    }
}

fn evenGroupFrames(st: *State, parent_elk: *eg.ElkNode, _: ?usize) Error!void {
    for (parent_elk.children.items) |c| {
        const gi = st.lookup(c.id).?;
        if (!st.nodes[gi].is_group) continue;
        try evenGroupFrames(st, c, gi);

        var min_x = std.math.inf(f64);
        var max_x = -std.math.inf(f64);
        var min_y = std.math.inf(f64);
        var max_y = -std.math.inf(f64);
        var any = false;
        for (c.children.items) |cc| {
            const ci = st.lookup(cc.id).?;
            if (!st.has_offset[ci] or st.w[ci] == 0 or st.h[ci] == 0) continue;
            any = true;
            min_x = @min(min_x, st.pos_x[ci]);
            max_x = @max(max_x, st.pos_x[ci] + st.w[ci]);
            min_y = @min(min_y, st.pos_y[ci]);
            max_y = @max(max_y, st.pos_y[ci] + st.h[ci]);
        }
        if (!any or !st.has_offset[gi]) continue;

        var desc = std.AutoHashMap(usize, void).init(st.a);
        try collectDescendants(st, c, &desc);
        for (st.elk_edges, 0..) |ee, k| {
            const s_i = st.lookup(ee.sources.items[0].toNode().id).?;
            const t_i = st.lookup(ee.targets.items[0].toNode().id).?;
            const internal = desc.contains(s_i) and desc.contains(t_i);
            const at_start = s_i == gi;
            const at_end = t_i == gi;
            if (!internal and !at_start and !at_end) continue;
            _ = k;
            const off = st.calcOffset(s_i, t_i);
            for (ee.sections.items) |sec| {
                if (internal) {
                    const pts = [_]P{ .{ .x = sec.start.x, .y = sec.start.y }, .{ .x = sec.end.x, .y = sec.end.y } };
                    for (sec.bend_points.items) |bp| {
                        min_x = @min(min_x, bp.x + off.x);
                        max_x = @max(max_x, bp.x + off.x);
                        min_y = @min(min_y, bp.y + off.y);
                        max_y = @max(max_y, bp.y + off.y);
                    }
                    for (pts) |p| {
                        min_x = @min(min_x, p.x + off.x);
                        max_x = @max(max_x, p.x + off.x);
                        min_y = @min(min_y, p.y + off.y);
                        max_y = @max(max_y, p.y + off.y);
                    }
                } else {
                    if (at_start) {
                        min_x = @min(min_x, sec.start.x + off.x);
                        max_x = @max(max_x, sec.start.x + off.x);
                        min_y = @min(min_y, sec.start.y + off.y);
                        max_y = @max(max_y, sec.start.y + off.y);
                    }
                    if (at_end) {
                        min_x = @min(min_x, sec.end.x + off.x);
                        max_x = @max(max_x, sec.end.x + off.x);
                        min_y = @min(min_y, sec.end.y + off.y);
                        max_y = @max(max_y, sec.end.y + off.y);
                    }
                }
            }
        }

        const o_x = st.pos_x[gi];
        const o_y = st.pos_y[gi];
        const left = @max(o_x, min_x - subgraph_padding);
        const right = @min(o_x + st.w[gi], max_x + subgraph_padding);
        const bottom = @min(o_y + st.h[gi], max_y + subgraph_padding);
        const top = o_y;
        const label_floor = st.groupTitleWidth(gi);
        var x = left;
        var width = right - left;
        if (width < label_floor) {
            x -= (label_floor - width) / 2;
            width = label_floor;
            const orig_right = o_x + st.w[gi];
            x = @max(o_x, @min(x, orig_right - width));
            width = @min(width, st.w[gi]);
        }
        const height = bottom - top;
        if (height <= 0 or width <= 0) continue;
        if (st.origin[gi] == null) st.origin[gi] = .{ .x = o_x, .y = o_y };
        st.pos_x[gi] = x;
        st.w[gi] = width;
        st.h[gi] = height;
        st.x[gi] = x + width / 2;
        st.y[gi] = top + height / 2;
    }
}

fn collectDescendants(st: *State, n: *eg.ElkNode, into: *std.AutoHashMap(usize, void)) Error!void {
    for (n.children.items) |c| {
        try into.put(st.lookup(c.id).?, {});
        try collectDescendants(st, c, into);
    }
}

fn dist(a: P, b: P) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

fn applyEdgeLayout(st: *State, cfg: Config, out: []EdgeOut) Error!void {
    const a = st.a;
    var aligned = std.AutoHashMap(usize, void).init(a);
    for (st.elk_edges, 0..) |ee, k| {
        _ = k;
        if (ee.sections.items.len == 0) continue;
        const s_i = st.lookup(ee.sources.items[0].toNode().id).?;
        const t_i = st.lookup(ee.targets.items[0].toNode().id).?;
        const off = st.calcOffset(s_i, t_i);
        const sec = ee.sections.items[0];
        if (!st.nodes[s_i].skip_center_points) try alignDegenerate(st, s_i, .{ .x = sec.start.x + off.x, .y = sec.start.y + off.y }, &aligned);
        if (!st.nodes[t_i].skip_center_points) try alignDegenerate(st, t_i, .{ .x = sec.end.x + off.x, .y = sec.end.y + off.y }, &aligned);
    }

    const pts_list = try a.alloc(std.ArrayList(P), st.edges.len);
    const label_c = try a.alloc(?P, st.edges.len);
    for (pts_list) |*p| p.* = .empty;
    @memset(label_c, null);

    for (st.edges, 0..) |e, k| {
        const ee = st.elk_edges[k];
        var start_i = st.lookup(ee.sources.items[0].toNode().id).?;
        var end_i = st.lookup(ee.targets.items[0].toNode().id).?;
        if (st.reversed[k]) std.mem.swap(usize, &start_i, &end_i);
        if (ee.sections.items.len == 0) {
            const from: P = .{ .x = st.pos_x[start_i] + st.w[start_i] / 2, .y = st.pos_y[start_i] + st.h[start_i] / 2 };
            const to: P = .{ .x = st.pos_x[end_i] + st.w[end_i] / 2, .y = st.pos_y[end_i] + st.h[end_i] / 2 };
            var tmp: std.ArrayList(P) = .empty;
            try tmp.appendSlice(a, &.{ from, to });
            pts_list[k] = try sanitize(st, tmp, start_i, end_i);
            const ps = pts_list[k].items;
            label_c[k] = .{ .x = (ps[0].x + ps[ps.len - 1].x) / 2, .y = (ps[0].y + ps[ps.len - 1].y) / 2 };
            continue;
        }
        const off = st.calcOffset(st.lookup(e.start).?, st.lookup(e.end).?);
        const sec = ee.sections.items[0];
        var points: std.ArrayList(P) = .empty;
        try points.append(a, .{ .x = sec.start.x + off.x, .y = sec.start.y + off.y });
        for (sec.bend_points.items) |bp| try points.append(a, .{ .x = bp.x + off.x, .y = bp.y + off.y });
        try points.append(a, .{ .x = sec.end.x + off.x, .y = sec.end.y + off.y });
        if (st.reversed[k]) std.mem.reverse(P, points.items);
        st.x[start_i] = st.pos_x[start_i] + st.w[start_i] / 2;
        st.y[start_i] = st.pos_y[start_i] + st.h[start_i] / 2;
        st.x[end_i] = st.pos_x[end_i] + st.w[end_i] / 2;
        st.y[end_i] = st.pos_y[end_i] + st.h[end_i] / 2;
        if (!st.nodes[start_i].skip_center_points) try points.insert(a, 0, .{ .x = st.x[start_i], .y = st.y[start_i] });
        if (!st.nodes[end_i].skip_center_points) try points.append(a, .{ .x = st.x[end_i], .y = st.y[end_i] });

        const clipped = try sanitize(st, points, start_i, end_i);
        const end_fixed = ensureEndMarker(clipped, st.bounds(end_i), markerPathOffset(e.arrow_type_end));
        pts_list[k] = ensureStartMarker(end_fixed, st.bounds(start_i), markerPathOffset(e.arrow_type_start));
        if (ee.labels.items.len > 0) {
            const l = ee.labels.items[0];
            label_c[k] = .{ .x = l.x + off.x + l.width / 2, .y = l.y + off.y + l.height / 2 };
        }
    }

    if (cfg.straighten_edges) try straightenEdgeTerminals(st, pts_list, label_c);
    separateOppositeLabels(st, label_c);

    for (st.edges, 0..) |_, k| {
        out[k] = .{
            .points = pts_list[k].items,
            .has_label_pos = label_c[k] != null,
            .x = if (label_c[k]) |p| p.x else 0,
            .y = if (label_c[k]) |p| p.y else 0,
        };
    }
}

fn alignDegenerate(st: *State, i: usize, anchor: P, aligned: *std.AutoHashMap(usize, void)) Error!void {
    const width = st.w[i];
    const height = st.h[i];
    const top = st.pos_y[i];
    const bottom = top + height;
    const tol = 0.5;
    const along_width = @abs(anchor.y - top) <= tol or @abs(anchor.y - bottom) <= tol;
    if ((if (along_width) width else height) >= 2 * ports_surrounding_margin) return;
    if (aligned.contains(i)) return;
    try aligned.put(i, {});
    const delta = if (along_width) anchor.x - (st.pos_x[i] + width / 2) else anchor.y - (st.pos_y[i] + height / 2);
    if (@abs(delta) < 0.01) return;
    if (along_width) {
        st.pos_x[i] += delta;
        st.x[i] = st.pos_x[i] + width / 2;
    } else {
        st.pos_y[i] += delta;
        st.y[i] = st.pos_y[i] + height / 2;
    }
}

fn approxEq(x: f64, y: f64) bool {
    return @abs(x - y) < 1e-6;
}

fn sanitize(st: *State, input: std.ArrayList(P), start_i: usize, end_i: usize) Error!std.ArrayList(P) {
    var ts: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var te = ts;
    const a = st.a;
    var prev: std.ArrayList(P) = .empty;
    try prev.appendSlice(a, input.items);
    const sb = st.bounds(start_i);
    const eb = st.bounds(end_i);
    const start_group = st.nodes[start_i].is_group;
    const end_group = st.nodes[end_i].is_group;
    const sc: P = .{ .x = st.x[start_i], .y = st.y[start_i] };
    const ec: P = .{ .x = st.x[end_i], .y = st.y[end_i] };

    const s_first = prev.items[0];
    const s_center_approx = approxEq(s_first.x, sc.x) and approxEq(s_first.y, sc.y);
    const s_cand = if (s_center_approx and prev.items.len > 1) prev.items[1] else s_first;
    const e_last = prev.items[prev.items.len - 1];
    const e_center_approx = approxEq(e_last.x, ec.x) and approxEq(e_last.y, ec.y);
    const e_cand = if (e_center_approx and prev.items.len > 1) prev.items[prev.items.len - 2] else e_last;

    var skip_start = start_group and geo.onBorder(sb, s_cand, 0.5);
    var skip_end = end_group and geo.onBorder(eb, e_cand, 0.5);
    if (skip_start and s_center_approx and prev.items.len > 0) _ = prev.orderedRemove(0);
    if (skip_end and e_center_approx and prev.items.len > 0) _ = prev.pop();

    if (start_group and !skip_start) skip_start = try clipGroup(a, &prev, sb, true);
    if (end_group and !skip_end) skip_end = try clipGroup(a, &prev, eb, false);

    if (skip_start or skip_end) {
        if (!skip_start) applyIntersection(&prev, st.isect(start_i, &ts), sb, true);
        if (!skip_end) applyIntersection(&prev, st.isect(end_i, &te), eb, false);
    }
    var clipped = if (skip_start or skip_end) prev else try cutter2(a, st, start_i, end_i, prev);
    var finite = true;
    for (clipped.items) |p| if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) {
        finite = false;
    };
    if (clipped.items.len < 2 or !finite) {
        var cleaned: std.ArrayList(P) = .empty;
        for (prev.items) |p| if (std.math.isFinite(p.x) and std.math.isFinite(p.y)) try cleaned.append(a, p);
        clipped = if (cleaned.items.len >= 2) cleaned else prev;
    }
    var out: std.ArrayList(P) = .empty;
    for (clipped.items, 0..) |p, i| {
        if (i == 0 or @abs(p.x - clipped.items[i - 1].x) > 1e-6 or @abs(p.y - clipped.items[i - 1].y) > 1e-6) try out.append(a, p);
    }
    return out;
}

fn clipGroup(a: Allocator, points: *std.ArrayList(P), b: Rect, start: bool) Error!bool {
    const len: isize = @intCast(points.items.len);
    const step: isize = if (start) 1 else -1;
    var index: isize = if (start) 0 else len - 1;
    const terminal = index;
    while (index >= 0 and index < len and !geo.outsideNode(b, points.items[@intCast(index)])) index += step;
    if (index == terminal or index < 0 or index >= len) return false;
    const outside = points.items[@intCast(index)];
    const inside = points.items[@intCast(index - step)];
    const dx = outside.x - inside.x;
    const dy = outside.y - inside.y;
    const tx = if (dx == 0) std.math.inf(f64) else (b.x + (std.math.sign(dx) * b.width) / 2 - inside.x) / dx;
    const ty = if (dy == 0) std.math.inf(f64) else (b.y + (std.math.sign(dy) * b.height) / 2 - inside.y) / dy;
    const t = @min(tx, ty);
    const crossing = P{ .x = inside.x + t * dx, .y = inside.y + t * dy };
    const idx: usize = @intCast(index);
    var next: std.ArrayList(P) = .empty;
    if (start) {
        try next.append(a, crossing);
        try next.appendSlice(a, points.items[idx..]);
    } else {
        try next.appendSlice(a, points.items[0 .. idx + 1]);
        try next.append(a, crossing);
    }
    points.* = next;
    return true;
}

fn applyIntersection(points: *std.ArrayList(P), node: ?geo.Intersect, b: Rect, start: bool) void {
    var found: ?usize = null;
    if (start) {
        for (points.items, 0..) |p, i| if (geo.outsideNode(b, p)) {
            found = i;
            break;
        };
    } else {
        var i: usize = points.items.len;
        while (i > 0) {
            i -= 1;
            if (geo.outsideNode(b, points.items[i])) {
                found = i;
                break;
            }
        }
    }
    const idx = found orelse return;
    const center = if (start) points.items[0] else points.items[points.items.len - 1];
    const inter = geo.computeNodeIntersection(node, b, points.items[idx], center);
    geo.replaceEndpoint(points, if (start) .start else .end, inter);
}

fn cutter2(a: Allocator, st: *State, start_i: usize, end_i: usize, original: std.ArrayList(P)) Error!std.ArrayList(P) {
    var ts: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var te = ts;
    var points: std.ArrayList(P) = .empty;
    try points.appendSlice(a, original.items);
    if (points.items.len == 0) return points;
    const sb = st.bounds(start_i);
    const eb = st.bounds(end_i);
    const start_center = points.items[0];
    const end_center = points.items[points.items.len - 1];

    var first_out: ?usize = null;
    for (points.items, 0..) |p, i| if (first_out == null and geo.outsideNode(sb, p)) {
        first_out = i;
    };
    if (first_out) |fo| {
        const inter = attachAlongDeparture(st, start_i, sb, points.items, fo, 1) orelse
            geo.computeNodeIntersection(st.isect(start_i, &ts), sb, points.items[fo], start_center);
        geo.replaceEndpoint(&points, .start, inter);
    }

    var out_pt: ?P = null;
    var out_idx: usize = 0;
    var i: usize = points.items.len;
    while (i > 0) {
        i -= 1;
        if (geo.outsideNode(eb, points.items[i])) {
            out_pt = points.items[i];
            out_idx = i;
            break;
        }
    }
    if (out_pt == null and points.items.len > 1) {
        out_pt = points.items[points.items.len - 2];
        out_idx = points.items.len - 2;
    }
    if (out_pt) |op| {
        const inter = attachAlongDeparture(st, end_i, eb, points.items, out_idx, -1) orelse
            geo.computeNodeIntersection(st.isect(end_i, &te), eb, op, end_center);
        geo.replaceEndpoint(&points, .end, inter);
    }
    if (points.items.len > 1) {
        const last = points.items[points.items.len - 1];
        const second = points.items[points.items.len - 2];
        if (@sqrt((last.x - second.x) * (last.x - second.x) + (last.y - second.y) * (last.y - second.y)) < 2) _ = points.pop();
    }
    return points;
}

fn attachAlongDeparture(st: *State, node_i: usize, b: Rect, points: []const P, port_index: usize, step: i2) ?P {
    var tn: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (st.nodes[node_i].is_group) return null;
    const next_idx: isize = @as(isize, @intCast(port_index)) + step;
    if (next_idx < 0 or next_idx >= @as(isize, @intCast(points.len))) return null;
    return geo.outlineAttachPoint(st.isect(node_i, &tn), b, points[port_index], points[@intCast(next_idx)]);
}

fn ensureEndMarker(points: std.ArrayList(P), b: Rect, marker_offset: f64) std.ArrayList(P) {
    if (marker_offset <= 0 or points.items.len < 3) return points;
    const end = points.items[points.items.len - 1];
    const entry = points.items[points.items.len - 2];
    if (dist(entry, end) >= @max(min_end_marker_segment_length, marker_offset * 2)) return points;
    if (!geo.onBorder(b, entry, 1)) return points;
    var out = points;
    out.items[out.items.len - 2] = end;
    out.items.len -= 1;
    return out;
}

fn ensureStartMarker(points: std.ArrayList(P), b: Rect, marker_offset: f64) std.ArrayList(P) {
    if (marker_offset <= 0 or points.items.len < 3) return points;
    const start = points.items[0];
    const exit = points.items[1];
    if (dist(start, exit) >= @max(min_end_marker_segment_length, marker_offset * 2)) return points;
    if (!geo.onBorder(b, exit, 1)) return points;
    var out = points;
    _ = out.orderedRemove(1);
    return out;
}

// straightenEdgeTerminals
const jog_eps: f64 = 0.01;
const terminal_jog_max: f64 = 16;
const terminal_run_max: f64 = 30;

const Axis = enum { h, v, none };

fn axisOf(p: P, q: P) Axis {
    const dx = @abs(q.x - p.x);
    const dy = @abs(q.y - p.y);
    if (dx > jog_eps and dy <= jog_eps) return .h;
    if (dy > jog_eps and dx <= jog_eps) return .v;
    return .none;
}

const Run = struct { old_a: P, old_b: P, new_a: P, new_b: P };

fn straightenFront(a: Allocator, pts: []const P) Allocator.Error!?struct { points: []P, run: Run } {
    if (pts.len < 5) return null;
    const p0 = pts[0];
    const p1 = pts[1];
    const p2 = pts[2];
    const p3 = pts[3];
    const axis = axisOf(p0, p1);
    if (axis == .none or axisOf(p2, p3) != axis) return null;
    if (axisOf(p1, p2) != (if (axis == .h) Axis.v else Axis.h)) return null;
    if (dist(p0, p1) > terminal_run_max) return null;
    const jog = if (axis == .h) @abs(p2.y - p1.y) else @abs(p2.x - p1.x);
    if (jog < jog_eps or jog > terminal_jog_max) return null;
    const forward = if (axis == .h) std.math.sign(p1.x - p0.x) == std.math.sign(p3.x - p2.x) else std.math.sign(p1.y - p0.y) == std.math.sign(p3.y - p2.y);
    if (!forward) return null;
    var last: usize = 3;
    while (last + 1 < pts.len and axisOf(pts[last], pts[last + 1]) == axis) last += 1;
    if (last == pts.len - 1) return null;
    const moved = try a.dupe(P, pts);
    var i: usize = 2;
    while (i <= last) : (i += 1) moved[i] = if (axis == .h) .{ .x = pts[i].x, .y = p0.y } else .{ .x = p0.x, .y = pts[i].y };
    const run: Run = .{ .old_a = pts[2], .old_b = pts[last], .new_a = moved[2], .new_b = moved[last] };
    var out: std.ArrayList(P) = .empty;
    try out.append(a, moved[0]);
    try out.appendSlice(a, moved[3..]);
    return .{ .points = out.items, .run = run };
}

fn paramOnSegment(p: P, q: P, r: P) f64 {
    const abx = r.x - q.x;
    const aby = r.y - q.y;
    const len_sq = abx * abx + aby * aby;
    if (len_sq == 0) return 0;
    return @max(0, @min(1, ((p.x - q.x) * abx + (p.y - q.y) * aby) / len_sq));
}

fn pointAt(q: P, r: P, t: f64) P {
    return .{ .x = q.x + t * (r.x - q.x), .y = q.y + t * (r.y - q.y) };
}

fn projectLabel(label: P, runs: []const Run) ?P {
    var best: ?struct { d: f64, p: P } = null;
    for (runs) |r| {
        const t = paramOnSegment(label, r.old_a, r.old_b);
        const op = pointAt(r.old_a, r.old_b, t);
        const dx = op.x - label.x;
        const dy = op.y - label.y;
        const d = dx * dx + dy * dy;
        if (best == null or d < best.?.d) best = .{ .d = d, .p = pointAt(r.new_a, r.new_b, t) };
    }
    return if (best) |b| b.p else null;
}

fn sideOf(o: P, p: P, q: P) f64 {
    return (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
}

fn segmentsCross(a1: P, a2: P, b1: P, b2: P) bool {
    const d1 = sideOf(b1, b2, a1);
    const d2 = sideOf(b1, b2, a2);
    const d3 = sideOf(a1, a2, b1);
    const d4 = sideOf(a1, a2, b2);
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

fn crossingCount(x: []const P, y: []const P) usize {
    var n: usize = 0;
    if (x.len < 2 or y.len < 2) return 0;
    for (0..x.len - 1) |i| for (0..y.len - 1) |j| {
        if (segmentsCross(x[i], x[i + 1], y[j], y[j + 1])) n += 1;
    };
    return n;
}

const Box = struct { x1: f64, y1: f64, x2: f64, y2: f64 };

fn segmentHitsBox(p: P, q: P, box: Box) bool {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const pq = [4][2]f64{ .{ -dx, p.x - box.x1 }, .{ dx, box.x2 - p.x }, .{ -dy, p.y - box.y1 }, .{ dy, box.y2 - p.y } };
    for (pq) |e| {
        if (e[0] == 0) {
            if (e[1] < 0) return false;
        } else if (e[0] < 0) {
            t0 = @max(t0, e[1] / e[0]);
        } else {
            t1 = @min(t1, e[1] / e[0]);
        }
    }
    return t0 < t1;
}

fn labelBox(c: P, w: f64, h: f64) Box {
    return .{ .x1 = c.x - w / 2, .y1 = c.y - h / 2, .x2 = c.x + w / 2, .y2 = c.y + h / 2 };
}

fn covers(route: []const P, box: ?Box) bool {
    const b = box orelse return false;
    if (route.len < 2) return false;
    for (0..route.len - 1) |i| if (segmentHitsBox(route[i], route[i + 1], b)) return true;
    return false;
}

fn straightenEdgeTerminals(st: *State, routes: []std.ArrayList(P), label_c: []?P) Error!void {
    const a = st.a;
    const n = routes.len;
    const boxes = try a.alloc(?Box, n);
    for (0..n) |i| {
        const e = st.edges[i];
        boxes[i] = if (label_c[i] == null or e.label_text.len == 0 or e.label_w == 0 or e.label_h == 0) null else labelBox(label_c[i].?, e.label_w, e.label_h);
    }
    for (0..n) |index| {
        const original = routes[index].items;
        if (original.len < 5) continue;
        var pts: []const P = original;
        var runs: std.ArrayList(Run) = .empty;
        var changed = false;
        if (try straightenFront(a, pts)) |f| {
            pts = f.points;
            try runs.append(a, f.run);
            changed = true;
        }
        const rev = try a.dupe(P, pts);
        std.mem.reverse(P, rev);
        if (try straightenFront(a, rev)) |b| {
            const back = b.points;
            std.mem.reverse(P, back);
            pts = back;
            try runs.append(a, b.run);
            changed = true;
        }
        if (!changed) continue;
        const candidate = pts;
        const e = st.edges[index];
        var cand_box = boxes[index];
        if (boxes[index] != null) {
            if (projectLabel(label_c[index].?, runs.items)) |moved| cand_box = labelBox(moved, e.label_w, e.label_h);
        }
        var before: usize = 0;
        var after: usize = 0;
        var covered_before: usize = 0;
        var covered_after: usize = 0;
        for (0..n) |other| {
            const route = routes[other].items;
            if (other == index or route.len < 2) continue;
            before += crossingCount(original, route);
            after += crossingCount(candidate, route);
            covered_before += @as(usize, @intFromBool(covers(route, boxes[index]))) + @intFromBool(covers(original, boxes[other]));
            covered_after += @as(usize, @intFromBool(covers(route, cand_box))) + @intFromBool(covers(candidate, boxes[other]));
        }
        if (after > before or covered_after > covered_before) continue;
        routes[index] = .empty;
        try routes[index].appendSlice(a, candidate);
        boxes[index] = cand_box;
        if (label_c[index]) |lc| {
            if (projectLabel(lc, runs.items)) |p| label_c[index] = p;
        }
    }
}

fn separateOppositeLabels(st: *State, label_c: []?P) void {
    const n = st.edges.len;
    var done = st.a.alloc(bool, n) catch return;
    @memset(done, false);
    for (0..n) |i| {
        if (done[i]) continue;
        const ei = st.edges[i];
        if (label_c[i] == null or ei.label_text.len == 0 or ei.label_w == 0) continue;
        var bucket = [2]usize{ 0, 0 };
        var cnt: usize = 0;
        for (0..n) |j| {
            const ej = st.edges[j];
            if (label_c[j] == null or ej.label_text.len == 0 or ej.label_w == 0) continue;
            if (sameKey(ei, ej)) {
                if (cnt < 2) bucket[cnt] = j;
                cnt += 1;
                done[j] = true;
            }
        }
        if (cnt != 2) continue;
        const ia = bucket[0];
        const ib = bucket[1];
        const ea = st.edges[ia];
        const eb = st.edges[ib];
        var pa = label_c[ia].?;
        var pb = label_c[ib].?;
        if (@abs(pa.y - pb.y) > @max(ea.label_h, eb.label_h)) continue;
        const required = ea.label_w / 2 + eb.label_w / 2 + 4;
        const current = pb.x - pa.x;
        const deficit = required - @abs(current);
        if (deficit <= 0) continue;
        const sgn: f64 = if (current == 0 or std.math.isNan(current)) 1 else std.math.sign(current);
        pa.x -= (sgn * deficit) / 2;
        pb.x += (sgn * deficit) / 2;
        label_c[ia] = pa;
        label_c[ib] = pb;
    }
}

fn sameKey(x: Edge, y: Edge) bool {
    const same = std.mem.eql(u8, x.start, y.start) and std.mem.eql(u8, x.end, y.end);
    const swapped = std.mem.eql(u8, x.start, y.end) and std.mem.eql(u8, x.end, y.start);
    return same or swapped;
}

// intersect.rect: where the line from the centre to `p` leaves the box
fn rectIntersect(ctx: *anyopaque, p: P) ?P {
    const r: *Rect = @ptrCast(@alignCast(ctx));
    const dx = p.x - r.x;
    const dy = p.y - r.y;
    var w = r.width / 2;
    var h = r.height / 2;
    var sx: f64 = 0;
    var sy: f64 = 0;
    if (@abs(dy) * w > @abs(dx) * h) {
        if (dy < 0) h = -h;
        sx = if (dy == 0) 0 else (h * dx) / dy;
        sy = h;
    } else {
        if (dx < 0) w = -w;
        sx = w;
        sy = if (dx == 0) 0 else (w * dy) / dx;
    }
    return .{ .x = r.x + sx, .y = r.y + sy };
}

fn lineIntersect(p1: P, p2: P, q1: P, q2: P) ?P {
    const a1 = p2.y - p1.y;
    const b1 = p1.x - p2.x;
    const c1 = p2.x * p1.y - p1.x * p2.y;
    const r3 = a1 * q1.x + b1 * q1.y + c1;
    const r4 = a1 * q2.x + b1 * q2.y + c1;
    if (r3 != 0 and r4 != 0 and r3 * r4 > 0) return null;
    const a2 = q2.y - q1.y;
    const b2 = q1.x - q2.x;
    const c2 = q2.x * q1.y - q1.x * q2.y;
    const r1 = a2 * p1.x + b2 * p1.y + c2;
    const r2 = a2 * p2.x + b2 * p2.y + c2;
    if (r1 != 0 and r2 != 0 and r1 * r2 > 0) return null;
    const denom = a1 * b2 - a2 * b1;
    if (denom == 0) return null;
    const offset = @abs(denom / 2);
    var num = b1 * c2 - b2 * c1;
    const x = if (num < 0) (num - offset) / denom else (num + offset) / denom;
    num = a2 * c1 - a1 * c2;
    const y = if (num < 0) (num - offset) / denom else (num + offset) / denom;
    return .{ .x = x, .y = y };
}

// intersect.polygon over the four corners of a diamond
fn diamondIntersect(ctx: *anyopaque, p: P) ?P {
    const r: *Rect = @ptrCast(@alignCast(ctx));
    const hw = r.width / 2;
    const hh = r.height / 2;
    const c = P{ .x = r.x, .y = r.y };
    const pts = [4]P{ .{ .x = r.x, .y = r.y + hh }, .{ .x = r.x + hw, .y = r.y }, .{ .x = r.x, .y = r.y - hh }, .{ .x = r.x - hw, .y = r.y } };
    var best: ?P = null;
    var best_d: f64 = 0;
    for (0..4) |i| {
        if (lineIntersect(c, p, pts[i], pts[(i + 1) % 4])) |q| {
            const d = std.math.hypot(q.x - p.x, q.y - p.y);
            if (best == null or d < best_d) {
                best = q;
                best_d = d;
            }
        }
    }
    return best orelse c;
}

// intersect.circle
fn circleIntersect(ctx: *anyopaque, p: P) ?P {
    const r: *Rect = @ptrCast(@alignCast(ctx));
    const rx = r.width / 2;
    const px = r.x - p.x;
    const py = r.y - p.y;
    const det = @sqrt(rx * rx * py * py + rx * rx * px * px);
    var dx = @abs((rx * rx * px) / det);
    if (p.x < r.x) dx = -dx;
    var dy = @abs((rx * rx * py) / det);
    if (p.y < r.y) dy = -dy;
    return .{ .x = r.x + dx, .y = r.y + dy };
}
