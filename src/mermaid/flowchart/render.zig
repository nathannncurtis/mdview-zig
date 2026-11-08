const std = @import("std");
const model = @import("../render/model.zig");
const dom = @import("../render/dom.zig");
const ce = @import("../render/cluster_extract.zig");
const clusters = @import("../render/clusters.zig");
const shape_util = @import("../render/shapes/util.zig");
const nodes_mod = @import("../render/nodes.zig");
const edges_mod = @import("../render/edges.zig");
const markers = @import("../render/markers.zig");
const dagre = @import("../dagre/layout.zig");
const Allocator = std.mem.Allocator;
const El = dom.El;
const NodeData = model.NodeData;
const EdgeData = model.EdgeData;
const Graph = ce.Graph;

pub const Error = anyerror;

fn clusterGet(ctx: *anyopaque, id: []const u8) ?edges_mod.ClusterEntry {
    const st: *ce.State = @ptrCast(@alignCast(ctx));
    const ent = st.cluster_db.get(id) orelse return null;
    return .{ .id = ent.id orelse return null, .node = ent.node orelse return null };
}

fn kidCount(g: *const Graph, v: []const u8) usize {
    return if (g.children(v)) |c| c.len else 0;
}

const Segment = struct { edge: *EdgeData, start: []const u8, end: []const u8 };

fn clamp(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

fn defaultSide(rankdir: []const u8) []const u8 {
    if (std.mem.eql(u8, rankdir, "BT")) return "bottom";
    if (std.mem.eql(u8, rankdir, "LR")) return "right";
    if (std.mem.eql(u8, rankdir, "RL")) return "left";
    return "top";
}

fn selfLoopSide(g: *const Graph, node: *const NodeData, segs: []const Segment, original_start: []const u8, rankdir: []const u8) []const u8 {
    var seen: [6][]const u8 = undefined;
    var ns: usize = 0;
    for (segs) |s| {
        for ([2][]const u8{ s.start, s.end }) |id| {
            if (std.mem.eql(u8, id, original_start)) continue;
            var dup = false;
            for (seen[0..ns]) |x| if (std.mem.eql(u8, x, id)) {
                dup = true;
            };
            if (dup) continue;
            seen[ns] = id;
            ns += 1;
        }
    }
    var cnt: f64 = 0;
    var tx: f64 = 0;
    var ty: f64 = 0;
    for (seen[0..ns]) |id| {
        if (g.node(id)) |d| {
            tx += d.x;
            ty += d.y;
            cnt += 1;
        }
    }
    if (cnt == 0) {
        for (segs) |s| for (s.edge.points) |p| {
            tx += p.x;
            ty += p.y;
            cnt += 1;
        };
    }
    if (cnt == 0) return defaultSide(rankdir);
    const sx = tx / cnt;
    const sy = ty / cnt;
    const dx = sx - node.x;
    const dy = sy - node.y;
    if (@abs(dx) > @abs(dy)) return if (dx > 0) "right" else "left";
    if (@abs(dy) > 0) return if (dy > 0) "bottom" else "top";
    return defaultSide(rankdir);
}

fn selfLoopPoints(a: Allocator, node: *const NodeData, side: []const u8, y_offset: f64, label_width: f64) Allocator.Error![]model.Point {
    const x = node.x;
    const y = node.y - y_offset;
    const hw = node.width / 2;
    const hh = node.height / 2;
    const max_span = @max(36, @min(100, node.width * 0.8));
    const span = clamp(@max(label_width, node.width * 0.35), 36, max_span);
    const depth = clamp(@min(node.width, node.height) * 0.45, 24, 48);
    const p = try a.alloc(model.Point, 4);
    if (std.mem.eql(u8, side, "bottom")) {
        const b = y + hh;
        p[0] = .{ .x = x - span / 2, .y = b };
        p[1] = .{ .x = x - span / 2, .y = b + depth };
        p[2] = .{ .x = x + span / 2, .y = b + depth };
        p[3] = .{ .x = x + span / 2, .y = b };
    } else if (std.mem.eql(u8, side, "right")) {
        const r = x + hw;
        p[0] = .{ .x = r, .y = y - span / 2 };
        p[1] = .{ .x = r + depth, .y = y - span / 2 };
        p[2] = .{ .x = r + depth, .y = y + span / 2 };
        p[3] = .{ .x = r, .y = y + span / 2 };
    } else if (std.mem.eql(u8, side, "left")) {
        const l = x - hw;
        p[0] = .{ .x = l, .y = y - span / 2 };
        p[1] = .{ .x = l - depth, .y = y - span / 2 };
        p[2] = .{ .x = l - depth, .y = y + span / 2 };
        p[3] = .{ .x = l, .y = y + span / 2 };
    } else {
        const t = y - hh;
        p[0] = .{ .x = x - span / 2, .y = t };
        p[1] = .{ .x = x - span / 2, .y = t - depth };
        p[2] = .{ .x = x + span / 2, .y = t - depth };
        p[3] = .{ .x = x + span / 2, .y = t };
    }
    return p;
}

fn selfLoopLabelPos(points: []const model.Point, node: *const NodeData, side: []const u8, y_offset: f64, lw: f64, lh: f64) model.Point {
    const gap = 4.0;
    const x = node.x;
    const y = node.y - y_offset;
    var minx = points[0].x;
    var maxx = points[0].x;
    var miny = points[0].y;
    var maxy = points[0].y;
    for (points) |p| {
        minx = @min(minx, p.x);
        maxx = @max(maxx, p.x);
        miny = @min(miny, p.y);
        maxy = @max(maxy, p.y);
    }
    if (std.mem.eql(u8, side, "bottom")) return .{ .x = x, .y = maxy + lh / 2 + gap };
    if (std.mem.eql(u8, side, "right")) return .{ .x = maxx + lw / 2 + gap, .y = y };
    if (std.mem.eql(u8, side, "left")) return .{ .x = minx - lw / 2 - gap, .y = y };
    return .{ .x = x, .y = miny - lh / 2 - gap };
}

fn getEdgesToRender(a: Allocator, g: *const Graph, y_offset: f64) Error![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    var groups: std.ArrayList(std.ArrayList(Segment)) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        if (edge.self_loop_id) |sid| {
            var idx: ?usize = null;
            for (keys.items, 0..) |k, i| if (std.mem.eql(u8, k, sid)) {
                idx = i;
            };
            if (idx == null) {
                try keys.append(a, sid);
                try groups.append(a, .empty);
                idx = keys.items.len - 1;
            }
            try groups.items[idx.?].append(a, .{ .edge = edge, .start = e.v, .end = e.w });
        } else try out.append(a, .{ .edge = edge, .start = e.v, .end = e.w });
    }
    const rankdir = g.label.rankdir;
    for (groups.items) |*segs| {
        if (segs.items.len != 3) {
            try out.appendSlice(a, segs.items);
            continue;
        }
        std.mem.sort(Segment, segs.items, {}, struct {
            fn lt(_: void, x: Segment, y: Segment) bool {
                return x.edge.self_loop_order < y.edge.self_loop_order;
            }
        }.lt);
        const first = segs.items[0];
        const mid = segs.items[1];
        const last = segs.items[2];
        const orig = first.edge.original_edge orelse mid.edge.original_edge orelse last.edge.original_edge orelse mid.edge;
        const node = g.node(orig.start) orelse {
            try out.appendSlice(a, segs.items);
            continue;
        };
        const side = selfLoopSide(g, node, segs.items, orig.start, rankdir);
        const points = try selfLoopPoints(a, node, side, y_offset, mid.edge.width);
        const lp = selfLoopLabelPos(points, node, side, y_offset, mid.edge.width, mid.edge.height);
        const merged = try a.create(EdgeData);
        merged.* = mid.edge.*;
        merged.id = orig.id;
        merged.points = points;
        merged.start = orig.start;
        merged.end = orig.end;
        merged.x = lp.x;
        merged.y = lp.y;
        merged.arrow_type_start = orig.arrow_type_start;
        merged.arrow_type_end = orig.arrow_type_end;
        merged.start_label_left = orig.start_label_left;
        merged.start_label_right = orig.start_label_right;
        merged.end_label_left = orig.end_label_left;
        merged.end_label_right = orig.end_label_right;
        merged.from_cluster = first.edge.from_cluster orelse mid.edge.from_cluster orelse last.edge.from_cluster;
        merged.to_cluster = first.edge.to_cluster orelse mid.edge.to_cluster orelse last.edge.to_cluster;
        merged.self_loop_id = null;
        merged.original_edge = null;
        try out.append(a, .{ .edge = merged, .start = merged.start, .end = merged.end });
    }
    return out.items;
}

pub const Renderer = struct {
    ctx: *const model.Ctx,
    st: ce.State,
    reg: clusters.Registry = .{},
    diagram_type: []const u8,
    id: []const u8,

    fn a(self: *const Renderer) Allocator {
        return self.ctx.a;
    }

    fn totalTitleMargin(self: *const Renderer) f64 {
        const m = self.ctx.cfg.sub_graph_title_margin;
        return m.top + m.bottom;
    }

    fn runDagre(self: *Renderer, g: *Graph) Error!void {
        const al = self.a();
        var dg = try dagre.newGraph(al, .{});
        dg.label.* = .{
            .ranksep = g.label.ranksep,
            .nodesep = g.label.nodesep,
            .marginx = g.label.marginx,
            .marginy = g.label.marginy,
            .rankdir = g.label.rankdir,
        };
        for (g.nodes()) |v| {
            const nd = g.node(v).?;
            try dg.setNode(v, try dagre.newNode(al, nd.width, nd.height));
        }
        for (g.nodes()) |v| {
            if (g.parent(v)) |p| try dg.setParent(v, p);
        }
        for (g.edges()) |e| {
            const ed = g.edgeLabel(e).?;
            const lp: u8 = if (ed.labelpos.len > 0) ed.labelpos[0] else 'r';
            try dg.setEdge(e, try dagre.newEdge(al, .{
                .minlen = ed.minlen,
                .width = ed.width,
                .height = ed.height,
                .labelpos = lp,
            }));
        }
        try dagre.layout(al, &dg, .{});
        for (g.nodes()) |v| {
            const nd = g.node(v).?;
            const out = dg.node(v).?;
            nd.x = out.x;
            nd.y = out.y;
            if (dg.children(v).?.len > 0) {
                nd.width = out.width;
                nd.height = out.height;
            }
        }
        for (g.edges()) |e| {
            const ed = g.edgeLabel(e).?;
            const out = dg.edgeLabel(e).?;
            const pts = try al.alloc(model.Point, out.points.items.len);
            for (out.points.items, 0..) |p, i| pts[i] = .{ .x = p.x, .y = p.y };
            ed.points = pts;
            if (out.x) |x| {
                ed.x = x;
                ed.y = out.y orelse 0;
            }
        }
    }

    const Rec = struct { el: *El, diff: f64 };

    fn recursiveRender(self: *Renderer, parent: *El, g: *Graph, parent_cluster: ?*NodeData) Error!Rec {
        const al = self.a();
        const dir = g.label.rankdir;
        const elem = try parent.insert("g");
        try elem.setAttr("class", "root");
        const clusters_g = try elem.insert("g");
        try clusters_g.setAttr("class", "clusters");
        const edge_paths = try elem.insert("g");
        try edge_paths.setAttr("class", "edgePaths");
        const edge_labels = try elem.insert("g");
        try edge_labels.setAttr("class", "edgeLabels");
        const nodes_g = try elem.insert("g");
        try nodes_g.setAttr("class", "nodes");

        for (try al.dupe([]const u8, g.nodes())) |v| {
            const node = g.node(v).?;
            if (parent_cluster) |pc| {
                const data = try al.create(NodeData);
                data.* = pc.cluster_data.?.*;
                data.intersect = null;
                try g.setNode(pc.id, data);
                if (g.parent(v) == null) try g.setParent(v, pc.id);
            }
            if (node.cluster_node) {
                const sg = ce.subGraphOf(node).?;
                const nl = try al.create(ce.GraphLabel);
                nl.* = sg.label.*;
                nl.ranksep = g.label.ranksep + 25;
                nl.nodesep = g.label.nodesep;
                sg.label = nl;
                const o = try self.recursiveRender(nodes_g, sg, g.node(v).?);
                if (o.el.bbox()) |b| {
                    node.width = b.w;
                    node.height = b.h;
                }
                node.diff = o.diff;
                node.el = o.el;
            } else if (kidCount(g, v) > 0) {
                const ent = try al.create(ce.ClusterEntry);
                ent.* = .{ .id = self.st.findNonClusterChild(node.id, g, null), .node = node };
                try self.st.cluster_db.put(al, node.id, ent);
            } else {
                const el = try nodes_mod.insertNode(self.ctx, nodes_g, node, .{ .dir = dir });
                if (el.bbox()) |b| {
                    node.width = b.w;
                    node.height = b.h;
                }
            }
        }

        for (g.edges()) |e| {
            const edge = g.edgeLabel(e).?;
            if (edge.self_loop_id) |sid| {
                if (edge.self_loop_order != 1) continue;
                const le = try al.create(EdgeData);
                le.* = edge.*;
                le.id = sid;
                if (edge.original_edge) |o| {
                    le.start_label_left = o.start_label_left orelse edge.start_label_left;
                    le.start_label_right = o.start_label_right orelse edge.start_label_right;
                    le.end_label_left = o.end_label_left orelse edge.end_label_left;
                    le.end_label_right = o.end_label_right orelse edge.end_label_right;
                }
                try edges_mod.insertEdgeLabel(self.ctx, edge_labels, le);
                edge.width = le.width;
                edge.height = le.height;
                edge.label_style = le.label_style;
                continue;
            }
            try edges_mod.insertEdgeLabel(self.ctx, edge_labels, edge);
        }

        try self.runDagre(g);

        const tm = self.totalTitleMargin();
        for (try ce.sortNodesByHierarchy(al, g)) |v| {
            const node = g.node(v) orelse continue;
            if (node.cluster_node) {
                node.y += tm;
                if (self.st.cluster_db.get(node.id)) |ent| ent.node = node;
                _ = try nodes_mod.positionNode(self.ctx, node);
            } else if (kidCount(g, v) > 0) {
                node.height += tm;
                _ = try clusters.insertCluster(self.ctx, &self.reg, clusters_g, node);
                if (self.st.cluster_db.get(node.id)) |ent| ent.node = node;
            } else {
                node.y += tm / 2;
                _ = try nodes_mod.positionNode(self.ctx, node);
            }
        }

        const off = tm / 2;
        for (try getEdgesToRender(al, g, off)) |seg| {
            for (seg.edge.points) |*p| p.y += off;
            const paths = try edges_mod.insertEdge(self.ctx, edge_paths, seg.edge, .{ .ctx = &self.st, .getFn = clusterGet }, self.diagram_type, g.node(seg.start).?, g.node(seg.end).?, self.id);
            try edges_mod.positionEdgeLabel(self.ctx, seg.edge, paths);
        }

        var diff: f64 = 0;
        for (g.nodes()) |v| {
            const n = g.node(v).?;
            if (n.is_group) diff = n.diff;
        }
        return .{ .el = elem, .diff = diff };
    }
};

fn copyNode(a: Allocator, n: NodeData) Allocator.Error!*NodeData {
    const p = try a.create(NodeData);
    p.* = n;
    return p;
}

fn copyEdge(a: Allocator, e: EdgeData) Allocator.Error!*EdgeData {
    const p = try a.create(EdgeData);
    p.* = e;
    return p;
}

fn addEdges(self: *Renderer, g: *Graph, data: *const model.LayoutData) Error!void {
    const al = self.a();
    for (data.edges) |edge| {
        if (std.mem.eql(u8, edge.start, edge.end)) {
            const nid = edge.start;
            const s1 = try std.fmt.allocPrint(al, "{s}---{s}---1", .{ nid, nid });
            const s2 = try std.fmt.allocPrint(al, "{s}---{s}---2", .{ nid, nid });
            const node = g.node(nid).?;
            for ([2][]const u8{ s1, s2 }) |sid| {
                try g.setNode(sid, try copyNode(al, .{
                    .dom_id = sid,
                    .id = sid,
                    .parent_id = node.parent_id,
                    .label = "",
                    .padding = 0,
                    .shape = "labelRect",
                    .width = 10,
                    .height = 10,
                }));
                try g.setParent(sid, node.parent_id);
            }
            const orig = try copyEdge(al, edge);
            const e1 = try copyEdge(al, edge);
            const em = try copyEdge(al, edge);
            const e2 = try copyEdge(al, edge);
            e1.original_edge = orig;
            e1.self_loop_id = orig.id;
            e1.self_loop_order = 0;
            em.original_edge = orig;
            em.self_loop_id = orig.id;
            em.self_loop_order = 1;
            e2.original_edge = orig;
            e2.self_loop_id = orig.id;
            e2.self_loop_order = 2;
            e1.label = "";
            e1.arrow_type_end = "none";
            e1.end_label_left = "";
            e1.end_label_right = "";
            e1.start_label_left = "";
            e1.id = try std.fmt.allocPrint(al, "{s}-cyclic-special-1", .{nid});
            em.start_label_right = "";
            em.start_label_left = "";
            em.end_label_left = "";
            em.end_label_right = "";
            em.arrow_type_start = "none";
            em.arrow_type_end = "none";
            em.id = try std.fmt.allocPrint(al, "{s}-cyclic-special-mid", .{nid});
            e2.label = "";
            e2.start_label_right = "";
            e2.start_label_left = "";
            e2.arrow_type_start = "none";
            if (node.is_group) {
                e1.from_cluster = nid;
                e2.to_cluster = nid;
            }
            e2.id = try std.fmt.allocPrint(al, "{s}-cyclic-special-2", .{nid});
            const n0 = try std.fmt.allocPrint(al, "{s}-cyclic-special-0", .{nid});
            const n1 = try std.fmt.allocPrint(al, "{s}-cyclic-special-1", .{nid});
            const n2 = try std.fmt.allocPrint(al, "{s}-cyclic-special-2", .{nid});
            try g.setEdge(.{ .v = nid, .w = s1, .name = n0 }, e1);
            try g.setEdge(.{ .v = s1, .w = s2, .name = n1 }, em);
            try g.setEdge(.{ .v = s2, .w = nid, .name = n2 }, e2);
        } else {
            try g.setEdge(.{ .v = edge.start, .w = edge.end, .name = edge.id }, try copyEdge(al, edge));
        }
    }
}

pub const Output = struct { svg: []const u8, width: f64, height: f64 };

fn sig6(a: Allocator, v: f64) Allocator.Error![]const u8 {
    if (v == 0) return "0";
    const exp: i32 = @intFromFloat(@floor(std.math.log10(@abs(v))));
    const scale = std.math.pow(f64, 10, @floatFromInt(5 - exp));
    return std.fmt.allocPrint(a, "{d}", .{@round(v * scale) / scale});
}

fn addShadowFilters(a: Allocator, svg: *El, id: []const u8, cfg: *const model.Config) Error!void {
    const specs = [2][4][]const u8{
        .{ "drop-shadow", "130%", "4", "4" },
        .{ "drop-shadow-small", "150%", "2", "2" },
    };
    for (specs) |sp| {
        const defs = try svg.insert("defs");
        const f = try defs.insert("filter");
        try f.setAttr("id", try std.fmt.allocPrint(a, "{s}-{s}", .{ id, sp[0] }));
        try f.setAttr("height", sp[1]);
        try f.setAttr("width", sp[1]);
        const d = try f.insert("feDropShadow");
        try d.setAttr("dx", sp[2]);
        try d.setAttr("dy", sp[3]);
        try d.setAttr("stdDeviation", "0");
        try d.setAttr("flood-opacity", "0.06");
        try d.setAttr("flood-color", if (cfg.dark_theme) "#FFFFFF" else "#000000");
    }
    if (cfg.use_gradient) {
        const g = try svg.insert("linearGradient");
        try g.setAttr("id", try std.fmt.allocPrint(a, "{s}-gradient", .{id}));
        try g.setAttr("gradientUnits", "objectBoundingBox");
        try g.setAttr("x1", "0%");
        try g.setAttr("y1", "0%");
        try g.setAttr("x2", "100%");
        try g.setAttr("y2", "0%");
        const stops = [2][2][]const u8{ .{ "0%", cfg.gradient_start }, .{ "100%", cfg.gradient_stop } };
        for (stops) |sp| {
            const st = try g.insert("stop");
            try st.setAttr("offset", sp[0]);
            try st.setAttr("stop-color", sp[1]);
            try st.setAttr("stop-opacity", "1");
        }
    }
}

fn hasLabel(e: *const EdgeData) bool {
    return if (e.label) |l| l.len > 0 else false;
}

fn resolveDir(by_id: *const std.StringHashMapUnmanaged(*NodeData), node: *const NodeData, diagram_dir: []const u8) []const u8 {
    var cur: ?*const NodeData = node;
    var hops: usize = 0;
    while (cur) |c| : (hops += 1) {
        if (c.dir) |d| return d;
        const p = c.parent_id orelse break;
        if (hops > 64) break;
        cur = by_id.get(p);
    }
    return diagram_dir;
}

// shortcut: ELK is the 12.2.0 default layout; until src/mermaid/elk lands this runs dagre over the flat compound graph and paints the common path
fn renderFlat(r: *Renderer, root: *El, data: *model.LayoutData) Error!void {
    const al = r.a();
    const ctx = r.ctx;
    const g = try r.st.newGraph(data.direction);
    g.label.nodesep = ctx.cfg.node_spacing;
    g.label.ranksep = ctx.cfg.rank_spacing;
    const elem = try root.insert("g");
    try elem.setAttr("class", "root");
    const clusters_g = try elem.insert("g");
    try clusters_g.setAttr("class", "clusters");
    const edge_paths = try elem.insert("g");
    try edge_paths.setAttr("class", "edges edgePaths");
    const edge_labels = try elem.insert("g");
    try edge_labels.setAttr("class", "edgeLabels");
    const nodes_g = try elem.insert("g");
    try nodes_g.setAttr("class", "nodes");

    var by_id: std.StringHashMapUnmanaged(*NodeData) = .empty;
    for (data.nodes) |n0| {
        var n = n0;
        n.dom_id = try std.fmt.allocPrint(al, "{s}-{s}", .{ data.diagram_id, n0.dom_id orelse n0.id });
        const np = try copyNode(al, n);
        try by_id.put(al, np.id, np);
    }
    for (data.nodes) |n0| {
        const node = by_id.get(n0.id).?;
        if (node.is_group) {
            const h = try shape_util.labelHelper(ctx, nodes_g, node, null);
            node.label_bbox = .{ .x = 0, .y = 0, .w = if (node.label != null) h.w else 0, .h = if (node.label != null) h.h else 0 };
            h.shape.detach();
        } else {
            const el = try nodes_mod.insertNode(ctx, nodes_g, node, .{ .dir = resolveDir(&by_id, node, data.direction) });
            if (el.bbox()) |b| {
                node.width = b.w;
                node.height = b.h;
            }
        }
        try g.setNode(node.id, node);
    }
    for (data.nodes) |n0| {
        if (n0.parent_id) |p| try g.setParent(n0.id, p);
    }
    for (data.edges) |e0| {
        const edge = try copyEdge(al, e0);
        if (hasLabel(edge)) try edges_mod.insertEdgeLabel(ctx, edge_labels, edge);
        try g.setEdge(.{ .v = edge.start, .w = edge.end, .name = edge.id }, edge);
    }

    try r.runDagre(g);

    const tm = r.totalTitleMargin();
    for (try ce.sortNodesByHierarchy(al, g)) |v| {
        const node = g.node(v) orelse continue;
        if (node.is_group) {
            node.height += tm;
            _ = try clusters.insertCluster(ctx, &r.reg, clusters_g, node);
            if (r.st.cluster_db.get(node.id)) |ent| ent.node = node else {
                const ent = try al.create(ce.ClusterEntry);
                ent.* = .{ .id = r.st.findNonClusterChild(node.id, g, null), .node = node };
                try r.st.cluster_db.put(al, node.id, ent);
            }
        } else {
            node.y += tm / 2;
            _ = try nodes_mod.positionNode(ctx, node);
        }
    }
    const off = tm / 2;
    for (g.edges()) |e| {
        const edge = g.edgeLabel(e).?;
        for (edge.points) |*p| p.y += off;
        const sn = g.node(edge.start) orelse continue;
        const en = g.node(edge.end) orelse continue;
        const paths = try edges_mod.insertEdge(ctx, edge_paths, edge, .{ .ctx = &r.st, .getFn = clusterGet }, r.diagram_type, sn, en, r.id);
        if (hasLabel(edge)) try edges_mod.positionEdgeLabel(ctx, edge, paths);
    }
}

pub fn render(ctx: *const model.Ctx, data: *model.LayoutData, css: []const u8) Error!Output {
    const al = ctx.a;
    const cfg = ctx.cfg;
    const svg = try El.create(al, "svg");
    try svg.setAttr("id", data.diagram_id);
    try svg.setAttr("width", "100%");
    try svg.setAttr("xmlns", "http://www.w3.org/2000/svg");
    try svg.setAttr("xmlns:xlink", "http://www.w3.org/1999/xlink");
    const style_el = try svg.insert("style");
    try style_el.setText(css);
    const root = try svg.insert("g");

    var r: Renderer = .{
        .ctx = ctx,
        .st = try ce.State.init(al),
        .diagram_type = data.diagram_type,
        .id = data.diagram_id,
    };
    edges_mod.clear();
    nodes_mod.clear();
    try markers.insertMarkers(al, root, &.{ "point", "circle", "cross" }, data.diagram_type, data.diagram_id);

    if (std.mem.eql(u8, cfg.layout, "dagre")) {
        const g = try r.st.newGraph(data.direction);
        g.label.nodesep = cfg.node_spacing;
        g.label.ranksep = cfg.rank_spacing;
        for (data.nodes) |n0| {
            var n = n0;
            n.dom_id = try std.fmt.allocPrint(al, "{s}-{s}", .{ data.diagram_id, n0.dom_id orelse n0.id });
            try g.setNode(n.id, try copyNode(al, n));
            if (n.parent_id) |p| try g.setParent(n.id, p);
        }
        try addEdges(&r, g, data);
        try r.st.adjustClustersAndEdges(g);
        _ = try r.recursiveRender(root, g, null);
    } else try renderFlat(&r, root, data);

    try addShadowFilters(al, svg, data.diagram_id, cfg);
    const pad = cfg.diagram_padding;
    if (data.title) |title| {
        if (svg.bbox()) |b| {
            const t = try svg.insert("text");
            try t.setText(title);
            try t.setAttr("text-anchor", "middle");
            _ = try t.attrNum("x", b.x + b.w / 2);
            _ = try t.attrNum("y", -cfg.title_top_margin);
            try t.setAttr("class", "flowchartTitleText");
        }
    }
    const b = svg.bbox() orelse dom.Box{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const w = b.w + pad * 2;
    const h = b.h + pad * 2;
    try svg.setAttr("class", "flowchart");
    if (cfg.use_max_width) {
        try svg.setAttr("style", try std.fmt.allocPrint(al, "max-width: {s}px;", .{try sig6(al, w)}));
    } else {
        _ = try svg.attrNum("width", w);
    }
    try svg.setAttr("viewBox", try std.fmt.allocPrint(al, "{s} {s} {s} {s}", .{
        try dom.fmtNum(al, b.x - pad), try dom.fmtNum(al, b.y - pad), try dom.fmtNum(al, w), try dom.fmtNum(al, h),
    }));
    try svg.setAttr("role", "graphics-document document");
    try svg.setAttr("aria-roledescription", data.diagram_type);
    _ = try svg.attrNum("height", h);
    try svg.setAttr("preserveAspectRatio", "xMinYMin");

    var out: std.ArrayList(u8) = .empty;
    try dom.serialize(&out, al, svg);
    return .{ .svg = out.items, .width = w, .height = h };
}
