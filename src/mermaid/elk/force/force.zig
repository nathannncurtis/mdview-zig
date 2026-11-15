const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("../util.zig");
const node_labels = @import("node_labels.zig");
const transferrer = @import("../graph/elk_graph_layout_transferrer.zig");
const Vec = lg.Vec;
const Allocator = std.mem.Allocator;

const Kind = enum { node, label, bend };

const Particle = struct {
    kind: Kind,
    pos: Vec = .{},
    size: Vec = .{},
    disp: Vec = .{},
    priority: i32 = 1,
    id: usize = 0,
    edge: ?*FEdge = null,
    inline_label: bool = false,
    node: ?*eg.ElkNode = null,
    label: ?*eg.ElkLabel = null,

    fn radius(p: *const Particle) f64 {
        return length(p.size) / 2;
    }
};

const FEdge = struct {
    source: *Particle,
    target: *Particle,
    bends: std.ArrayList(*Particle) = .empty,
    labels: std.ArrayList(*Particle) = .empty,
    priority: i32 = 1,
    repulsive_power: i32 = 0,
    spacing_edge_label: f64 = 5,
    origin: *eg.ElkEdge,

    // ElkMath.clipVector
    fn clipped(from: *const Particle, to: *const Particle) Vec {
        var v: Vec = .{ .x = to.pos.x - from.pos.x, .y = to.pos.y - from.pos.y };
        const wh = from.size.x / 2;
        const hh = from.size.y / 2;
        const absx = @abs(v.x);
        const absy = @abs(v.y);
        var xscale: f64 = 1;
        var yscale: f64 = 1;
        if (absx > wh) xscale = wh / absx;
        if (absy > hh) yscale = hh / absy;
        v.scale(util.javaMin(xscale, yscale));
        v.add(from.pos);
        return v;
    }

    fn sourcePoint(e: *const FEdge) Vec {
        return clipped(e.source, e.target);
    }

    fn targetPoint(e: *const FEdge) Vec {
        return clipped(e.target, e.source);
    }

    fn distributeBendpoints(e: *FEdge) void {
        const count = e.bends.items.len;
        if (count == 0) return;
        var incr: Vec = .{ .x = e.target.pos.x - e.source.pos.x, .y = e.target.pos.y - e.source.pos.y };
        incr.scale(1 / @as(f64, @floatFromInt(count + 1)));
        var pos = e.source.pos;
        for (e.bends.items) |b| {
            b.pos.x = pos.x + incr.x;
            b.pos.y = pos.y + incr.y;
            pos.add(incr);
        }
    }
};

const FGraph = struct {
    nodes: std.ArrayList(*Particle) = .empty,
    edges: std.ArrayList(*FEdge) = .empty,
    labels: std.ArrayList(*Particle) = .empty,
    bends: std.ArrayList(*Particle) = .empty,
    adjacency: []i32 = &.{},
    priority: i32 = 0,
    bb_up: Vec = .{},
    bb_low: Vec = .{},
};

const Cfg = struct {
    model: eg.ForceModel,
    iterations: i32,
    temperature: f64,
    repulsion: f64,
    interactive: bool,
    spacing: f64,
    aspect_ratio: f64,
    padding: lg.Margin,
    separate: bool,
};

const dist_zero_factor = 100.0;
const disp_bound_factor = 16.0;
const spacing_factor = 0.01;
const same_position_guard = 100000;

fn length(v: Vec) f64 {
    return @sqrt(v.x * v.x + v.y * v.y);
}

fn refreshPosition(l: *Particle) void {
    const e = l.edge.?;
    const src = e.source.pos;
    const tgt = e.target.pos;
    const pos = &l.pos;
    if (l.inline_label) {
        var s2t: Vec = .{ .x = tgt.x - src.x, .y = tgt.y - src.y };
        s2t.scale(0.5);
        var c = l.size;
        c.scale(0.5);
        pos.x = src.x + s2t.x - c.x;
        pos.y = src.y + s2t.y - c.y;
        return;
    }
    const spacing = e.spacing_edge_label;
    if (src.x >= tgt.x) {
        if (src.y >= tgt.y) {
            pos.x = tgt.x + ((src.x - tgt.x) / 2) + spacing;
            pos.y = tgt.y + ((src.y - tgt.y) / 2) - spacing - l.size.y;
        } else {
            pos.x = tgt.x + ((src.x - tgt.x) / 2) + spacing;
            pos.y = src.y + ((tgt.y - src.y) / 2) + spacing;
        }
    } else {
        if (src.y >= tgt.y) {
            pos.x = src.x + ((tgt.x - src.x) / 2) + spacing;
            pos.y = tgt.y + ((src.y - tgt.y) / 2) + spacing;
        } else {
            pos.x = src.x + ((tgt.x - src.x) / 2) + spacing;
            pos.y = src.y + ((tgt.y - src.y) / 2) - spacing - l.size.y;
        }
    }
}

fn wiggle(v: *Vec, random: *lg.JavaRandom, amount: f64) void {
    v.x += random.nextDouble() * amount - (amount / 2);
    v.y += random.nextDouble() * amount - (amount / 2);
}

fn avoidSamePosition(random: *lg.JavaRandom, u: *Particle, v: *Particle) void {
    const pu = &u.pos;
    const pv = &v.pos;
    var guard: usize = 0;
    while (pu.x - pv.x == 0 and pu.y - pv.y == 0 and guard < same_position_guard) : (guard += 1) {
        if (u.kind == .bend and v.kind == .bend) {
            const ue = u.edge.?;
            var ut = ue.targetPoint();
            ut.sub(ue.sourcePoint());
            var ulen = length(ut);
            pu.add(.{ .x = ut.x / ulen * 2, .y = -ut.y / ulen * 2 });
            const ve = v.edge.?;
            var vt = ve.targetPoint();
            vt.sub(ve.sourcePoint());
            ulen = length(vt);
            pu.add(.{ .x = (vt.x / ulen) * 2, .y = -(vt.y / ulen) * 2 });
        } else {
            wiggle(pu, random, 1);
            wiggle(pv, random, 1);
        }
    }
}

const Model = struct {
    cfg: *const Cfg,
    random: *lg.JavaRandom,
    graph: *FGraph,
    disp_bound: f64 = 0,
    temperature: f64 = 0,
    threshold: f64 = 0,
    k: f64 = 0,

    fn connection(m: *const Model, p1: *const Particle, p2: *const Particle) i32 {
        if (p1.kind == .node and p2.kind == .node) {
            const n = m.graph.nodes.items.len;
            return m.graph.adjacency[p1.id * n + p2.id] + m.graph.adjacency[p2.id * n + p1.id];
        }
        if (p1.kind == .bend and p2.kind == .bend and p1.edge.? == p2.edge.?) return p2.edge.?.priority;
        return 0;
    }

    fn initialize(m: *Model, a: Allocator) !void {
        const g = m.graph;
        const n = g.nodes.items.len;
        g.adjacency = try a.alloc(i32, n * n);
        @memset(g.adjacency, 0);
        for (g.edges.items) |e| g.adjacency[e.source.id * n + e.target.id] += e.priority;
        m.disp_bound = util.javaMax(@as(f64, @floatFromInt(n)) * disp_bound_factor + @as(f64, @floatFromInt(g.edges.items.len)), disp_bound_factor * disp_bound_factor);
        if (!m.cfg.interactive) {
            const pos_scale: f64 = @floatFromInt(n);
            for (g.nodes.items) |node| {
                node.pos.x = m.random.nextDouble() * pos_scale;
                node.pos.y = m.random.nextDouble() * pos_scale;
            }
        }
        for (g.edges.items) |e| {
            if (e.repulsive_power > 0) {
                var i: i32 = 0;
                while (i < e.repulsive_power) : (i += 1) {
                    const b = try a.create(Particle);
                    b.* = .{ .kind = .bend, .edge = e };
                    try e.bends.append(a, b);
                    try g.bends.append(a, b);
                }
                e.distributeBendpoints();
            }
        }
        if (m.cfg.model == .fruchterman_reingold) {
            m.temperature = m.cfg.temperature;
            m.threshold = m.temperature / @as(f64, @floatFromInt(m.cfg.iterations));
            var total_w: f64 = 0;
            var total_h: f64 = 0;
            for (g.nodes.items) |v| {
                total_w += v.size.x;
                total_h += v.size.y;
            }
            const area = total_w * total_h;
            const c = m.cfg.spacing * spacing_factor;
            m.k = @sqrt(area / @as(f64, @floatFromInt(2 * n))) * c;
        }
    }

    fn moreIterations(m: *const Model, count: i32) bool {
        return switch (m.cfg.model) {
            .eades => count < m.cfg.iterations,
            .fruchterman_reingold => m.temperature > 0,
        };
    }

    fn iterationDone(m: *Model) void {
        for (m.graph.edges.items) |e| {
            for (e.labels.items) |l| refreshPosition(l);
            e.distributeBendpoints();
        }
        if (m.cfg.model == .fruchterman_reingold) m.temperature -= m.threshold;
    }

    fn calcDisplacement(m: *Model, forcer: *Particle, forcee: *Particle) Vec {
        avoidSamePosition(m.random, forcer, forcee);
        var disp: Vec = .{ .x = forcee.pos.x - forcer.pos.x, .y = forcee.pos.y - forcer.pos.y };
        const len = length(disp);
        const d = util.javaMax(0, len - forcer.radius() - forcee.radius());
        const conn = m.connection(forcer, forcee);
        const prio: f64 = @floatFromInt(forcer.priority);
        const connf: f64 = @floatFromInt(conn);
        switch (m.cfg.model) {
            .eades => {
                const force = if (conn > 0)
                    -eadesAttractive(d, m.cfg.spacing) * connf
                else
                    eadesRepulsive(d, m.cfg.repulsion) * prio;
                disp.scale(force / len);
            },
            .fruchterman_reingold => {
                var force = frRepulsive(d, m.k) * prio;
                if (conn > 0) force -= frAttractive(d, m.k) * connf;
                disp.scale(force * m.temperature / len);
            },
        }
        return disp;
    }

    fn layout(m: *Model, a: Allocator) !void {
        try m.initialize(a);
        const g = m.graph;
        var all: std.ArrayList(*Particle) = .empty;
        try all.appendSlice(a, g.nodes.items);
        try all.appendSlice(a, g.labels.items);
        try all.appendSlice(a, g.bends.items);
        var iterations: i32 = 0;
        while (m.moreIterations(iterations)) {
            m.iterationDone();
            for (all.items) |v| {
                for (all.items) |u| {
                    if (u != v) v.disp.add(m.calcDisplacement(u, v));
                }
            }
            for (all.items) |v| {
                const b = m.disp_bound;
                if (v.disp.x < -b) v.disp.x = -b else if (v.disp.x > b) v.disp.x = b;
                if (v.disp.y < -b) v.disp.y = -b else if (v.disp.y > b) v.disp.y = b;
                v.pos.add(v.disp);
                v.disp = .{};
            }
            iterations += 1;
        }
    }
};

fn eadesRepulsive(d: f64, r: f64) f64 {
    return if (d > 0) r / (d * d) else r * dist_zero_factor;
}

fn eadesAttractive(d: f64, s: f64) f64 {
    return if (d > 0) util.fdlibmLog(d / s) else -dist_zero_factor;
}

fn frRepulsive(d: f64, k: f64) f64 {
    return if (d > 0) k * k / d else k * k * dist_zero_factor;
}

fn frAttractive(d: f64, k: f64) f64 {
    return d * d / k;
}

fn isHierarchical(e: *const eg.ElkEdge) bool {
    var common: ?*eg.ElkNode = null;
    var first = true;
    for ([_][]const eg.Shape{ e.sources.items, e.targets.items }) |list| {
        for (list) |sh| {
            const parent = sh.toNode().parent;
            if (first) {
                common = parent;
                first = false;
            } else if (common != parent) return true;
        }
    }
    return false;
}

fn importGraph(a: Allocator, parent: *eg.ElkNode) !FGraph {
    var g: FGraph = .{};
    var map = std.AutoHashMap(*eg.ElkNode, *Particle).init(a);
    for (parent.children.items, 0..) |kn, index| {
        const p = try a.create(Particle);
        p.* = .{ .kind = .node, .node = kn, .id = index, .priority = kn.opts.priority orelse 1 };
        p.pos = .{ .x = kn.x + kn.width / 2, .y = kn.y + kn.height / 2 };
        p.size = .{ .x = util.javaMax(kn.width, 1), .y = util.javaMax(kn.height, 1) };
        try g.nodes.append(a, p);
        try map.put(kn, p);
    }
    for (parent.children.items) |kn| {
        var edges: std.ArrayList(*eg.ElkEdge) = .empty;
        try edges.appendSlice(a, kn.outgoing_edges.items);
        for (kn.ports.items) |port| try edges.appendSlice(a, port.outgoing_edges.items);
        for (edges.items) |ke| {
            if (ke.isHyperedge()) {
                lg.setElkMessage("Graph must not contain hyperedges.");
                return error.ElkException;
            }
            if (ke.sources.items.len == 0 or ke.targets.items.len == 0) return error.ElkException;
            const tnode = ke.targets.items[0].toNode();
            if (isHierarchical(ke) or kn == tnode) continue;
            const fe = try a.create(FEdge);
            fe.* = .{
                .source = map.get(kn) orelse return error.ElkException,
                .target = map.get(tnode) orelse return error.ElkException,
                .origin = ke,
                .priority = ke.opts.priority orelse 1,
                .repulsive_power = ke.opts.force_repulsive_power orelse 0,
                .spacing_edge_label = ke.opts.spacing_edge_label orelse 5,
            };
            try g.edges.append(a, fe);
            for (ke.labels.items) |kl| {
                const fl = try a.create(Particle);
                fl.* = .{
                    .kind = .label,
                    .edge = fe,
                    .label = kl,
                    .priority = kl.opts.priority orelse 1,
                    .inline_label = kl.opts.edge_labels_inline orelse false,
                    .size = .{ .x = util.javaMax(kl.width, 1), .y = util.javaMax(kl.height, 1) },
                };
                try fe.labels.append(a, fl);
                refreshPosition(fl);
                try g.labels.append(a, fl);
            }
        }
    }
    return g;
}

fn dfs(a: Allocator, node: *Particle, last: ?*Particle, comp_in: ?*FGraph, visited: []bool, incidence: []std.ArrayList(*FEdge)) Allocator.Error!?*FGraph {
    if (visited[node.id]) return null;
    visited[node.id] = true;
    const comp = comp_in orelse blk: {
        const c = try a.create(FGraph);
        c.* = .{};
        break :blk c;
    };
    try comp.nodes.append(a, node);
    for (incidence[node.id].items) |edge| {
        if (edge.target == last or edge.source == last) continue;
        if (edge.source != node) _ = try dfs(a, edge.source, node, comp, visited, incidence);
        if (edge.target != node) _ = try dfs(a, edge.target, node, comp, visited, incidence);
        try comp.edges.append(a, edge);
        try comp.labels.appendSlice(a, edge.labels.items);
    }
    return comp;
}

fn split(a: Allocator, graph: *FGraph, cfg: *const Cfg) Allocator.Error![]*FGraph {
    var out: std.ArrayList(*FGraph) = .empty;
    if (!cfg.separate) {
        try out.append(a, graph);
        return out.items;
    }
    const n = graph.nodes.items.len;
    const visited = try a.alloc(bool, n);
    @memset(visited, false);
    const incidence = try a.alloc(std.ArrayList(*FEdge), n);
    for (incidence) |*l| l.* = .empty;
    for (graph.edges.items) |e| {
        try incidence[e.source.id].append(a, e);
        try incidence[e.target.id].append(a, e);
    }
    for (graph.nodes.items) |node| {
        if (try dfs(a, node, null, null, visited, incidence)) |comp| try out.append(a, comp);
    }
    if (out.items.len > 1) {
        for (out.items) |comp| for (comp.nodes.items, 0..) |node, id| {
            node.id = id;
        };
    }
    return out.items;
}

fn compareComponents(_: void, g1: *FGraph, g2: *FGraph) lg.Error!i32 {
    const prio = g2.priority - g1.priority;
    if (prio == 0) {
        const a1 = (g1.bb_low.x - g1.bb_up.x) * (g1.bb_low.y - g1.bb_up.y);
        const a2 = (g2.bb_low.x - g2.bb_up.x) * (g2.bb_low.y - g2.bb_up.y);
        return switch (util.doubleCompare(a1, a2)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    return prio;
}

fn moveGraph(a: Allocator, dest: *FGraph, src: *FGraph, offsetx: f64, offsety: f64) Allocator.Error!void {
    const off: Vec = .{ .x = offsetx - src.bb_up.x, .y = offsety - src.bb_up.y };
    for (src.nodes.items) |n| {
        n.pos.add(off);
        try dest.nodes.append(a, n);
    }
    for (src.edges.items) |e| {
        for (e.bends.items) |b| b.pos.add(off);
        try dest.edges.append(a, e);
    }
    for (src.labels.items) |l| {
        l.pos.add(off);
        try dest.labels.append(a, l);
    }
}

fn recombine(a: Allocator, comps: []*FGraph, cfg: *const Cfg) !*FGraph {
    if (comps.len == 1) return comps[0];
    const result = try a.create(FGraph);
    result.* = .{};
    if (comps.len == 0) return result;
    for (comps) |g| {
        var priority: i32 = 0;
        var minx: f64 = 2147483647;
        var miny: f64 = 2147483647;
        var maxx: f64 = -2147483648;
        var maxy: f64 = -2147483648;
        for (g.nodes.items) |n| {
            priority += n.priority;
            minx = util.javaMin(minx, n.pos.x - n.size.x / 2);
            miny = util.javaMin(miny, n.pos.y - n.size.y / 2);
            maxx = util.javaMax(maxx, n.pos.x + n.size.x / 2);
            maxy = util.javaMax(maxy, n.pos.y + n.size.y / 2);
        }
        g.priority = priority;
        g.bb_up = .{ .x = minx, .y = miny };
        g.bb_low = .{ .x = maxx, .y = maxy };
    }
    try util.javaSort(*FGraph, a, comps, {}, compareComponents);
    var max_row_width: f64 = 0;
    var total_area: f64 = 0;
    for (comps) |g| {
        const sx = g.bb_low.x - g.bb_up.x;
        const sy = g.bb_low.y - g.bb_up.y;
        max_row_width = util.javaMax(max_row_width, sx);
        total_area += sx * sy;
    }
    max_row_width = util.javaMax(max_row_width, @as(f64, @as(f32, @floatCast(@sqrt(total_area)))) * cfg.aspect_ratio);
    const spacing = cfg.spacing;
    var xpos: f64 = 0;
    var ypos: f64 = 0;
    var highest: f64 = 0;
    for (comps) |g| {
        const sx = g.bb_low.x - g.bb_up.x;
        const sy = g.bb_low.y - g.bb_up.y;
        if (xpos + sx > max_row_width) {
            xpos = 0;
            ypos += highest + spacing;
            highest = 0;
        }
        try moveGraph(a, result, g, xpos, ypos);
        highest = util.javaMax(highest, sy);
        xpos += sx + spacing;
    }
    return result;
}

fn applyLayout(a: Allocator, kgraph: *eg.ElkNode, fgraph: *FGraph, cfg: *const Cfg) !void {
    var min_x: f64 = 2147483647;
    var min_y: f64 = 2147483647;
    var max_x: f64 = -2147483648;
    var max_y: f64 = -2147483648;
    for ([_][]const *Particle{ fgraph.nodes.items, fgraph.bends.items }) |list| {
        for (list) |p| {
            min_x = util.javaMin(min_x, p.pos.x - p.size.x / 2);
            min_y = util.javaMin(min_y, p.pos.y - p.size.y / 2);
            max_x = util.javaMax(max_x, p.pos.x + p.size.x / 2);
            max_y = util.javaMax(max_y, p.pos.y + p.size.y / 2);
        }
    }
    const pad = cfg.padding;
    const off: Vec = .{ .x = pad.left - min_x, .y = pad.top - min_y };
    for (fgraph.nodes.items) |fn_| {
        const kn = fn_.node.?;
        kn.x = fn_.pos.x + off.x - kn.width / 2;
        kn.y = fn_.pos.y + off.y - kn.height / 2;
    }
    for (fgraph.edges.items) |fe| {
        const ke = fe.origin;
        const sec = blk: {
            if (ke.sections.items.len == 0) break :blk try eg.createEdgeSection(a, ke);
            const s = ke.sections.items[0];
            s.bend_points.clearRetainingCapacity();
            s.start = .{};
            s.end = .{};
            ke.sections.shrinkRetainingCapacity(1);
            break :blk s;
        };
        var start = fe.sourcePoint();
        start.add(off);
        sec.start = start;
        for (fe.bends.items) |b| try sec.bend_points.append(a, .{ .x = b.pos.x + off.x, .y = b.pos.y + off.y });
        var end = fe.targetPoint();
        end.add(off);
        sec.end = end;
    }
    for (fgraph.labels.items) |fl| {
        const kl = fl.label.?;
        kl.x = fl.pos.x + off.x;
        kl.y = fl.pos.y + off.y;
    }
    const width = (max_x - min_x) + pad.left + pad.right;
    const height = (max_y - min_y) + pad.top + pad.bottom;
    if (!(kgraph.opts.node_size_fixed_graph_size orelse false)) {
        transferrer.resizeElkNode(kgraph, width, height, false, true);
    }
}

pub fn layout(a: Allocator, node: *eg.ElkNode) lg.Error!void {
    const o = &node.opts;
    const cfg: Cfg = .{
        .model = o.force_model orelse .fruchterman_reingold,
        .iterations = o.force_iterations orelse 300,
        .temperature = o.force_temperature orelse 0.001,
        .repulsion = o.force_repulsion orelse 5.0,
        .interactive = o.interactive orelse false,
        .spacing = o.spacing_node_node orelse 80,
        .aspect_ratio = o.aspect_ratio orelse 1.600000023841858,
        .padding = o.padding orelse .{ .top = 50, .left = 50, .bottom = 50, .right = 50 },
        .separate = o.separate_connected_components orelse true,
    };
    if (!(o.omit_node_micro_layout orelse false)) node_labels.microLayout(node);
    var fgraph = try importGraph(a, node);
    const seed = o.random_seed orelse 1;
    // seed 0 is an unseeded java.util.Random in ELK; it runs as a fixed seed here
    var random = lg.JavaRandom.init(seed);
    const comps = try split(a, &fgraph, &cfg);
    for (comps) |comp| {
        var model: Model = .{ .cfg = &cfg, .random = &random, .graph = comp };
        try model.layout(a);
    }
    const result = try recombine(a, comps, &cfg);
    try applyLayout(a, node, result, &cfg);
}
