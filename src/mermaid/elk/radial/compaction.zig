const std = @import("std");
const lg = @import("../lgraph.zig");
const eg = @import("../elk_graph.zig");
const util = @import("util.zig");
const Ctx = util.Ctx;
const List = util.List;
const Node = *eg.ElkNode;

// AbstractRadiusExtensionCompaction
const Base = struct {
    c: *Ctx,
    step: i32 = 1,
    spacing: f64,
    root: Node,
    sorter: ?util.Sorter,

    fn init(c: *Ctx, step: i32) Base {
        return .{ .c = c, .step = step, .spacing = c.spacing(), .root = c.root, .sorter = util.Sorter.of(c.graph) };
    }

    fn sort(b: *Base, nodes: []Node) lg.Error!void {
        if (b.sorter) |*s| try s.sort(b.c, nodes);
    }

    fn contractLayer(b: *Base, layer: []const Node, contracting: bool) void {
        for (layer) |node| {
            var x_pos = node.x + node.width / 2;
            var y_pos = node.y + node.height / 2;
            const parent_x = b.root.x + b.root.width / 2;
            const parent_y = b.root.y + b.root.height / 2;
            var x = x_pos - parent_x;
            var y = y_pos - parent_y;
            const length = @sqrt(x * x + y * y);
            const step: f64 = @floatFromInt(b.step);
            x *= step / length;
            y *= step / length;
            if (contracting) {
                x_pos -= x;
                y_pos -= y;
            } else {
                x_pos += x;
                y_pos += y;
            }
            node.x = x_pos - node.width / 2;
            node.y = y_pos - node.height / 2;
        }
    }

    fn moveNode(node: Node, root: Node, distance: f64) void {
        const root_x = root.x + root.width / 2;
        const root_y = root.y + root.height / 2;
        const dx = node.x + node.width / 2 - root_x;
        const dy = node.y + node.height / 2 - root_y;
        const length = @sqrt(dx * dx + dy * dy);
        node.x += dx / length * distance;
        node.y += dy / length * distance;
    }

    fn overlap(b: *const Base, n1: Node, n2: Node) bool {
        const s = b.spacing;
        const x1 = n1.x - s / 2;
        const x2 = n2.x - s / 2;
        const y1 = n1.y - s / 2;
        const y2 = n2.y - s / 2;
        const w1 = n1.width + s;
        const w2 = n2.width + s;
        const h1 = n1.height + s;
        const h2 = n2.height + s;
        if ((x1 < x2 + w2 and x2 < x1) and (y1 < y2 + h2 and y2 < y1)) return true;
        if ((x2 < x1 + w1 and x1 < x2) and (y2 < y1 + h1 and y1 < y2)) return true;
        if ((x1 < x2 + w2 and x2 < x1) and (y1 < y2 and y2 < y1 + h1)) return true;
        if ((x2 < x1 + w1 and x1 < x2) and (y1 < y2 + h2 and y2 < y1)) return true;
        return false;
    }

    fn overlapLayer(b: *const Base, nodes: []const Node) bool {
        if (nodes.len < 2) return false;
        var overlapping = false;
        for (nodes, 0..) |n, i| {
            overlapping = b.overlap(n, if (i < nodes.len - 1) nodes[i + 1] else nodes[0]) or overlapping;
        }
        return overlapping;
    }
};

// RadiusExtensionOverlapRemoval
pub fn removeOverlaps(c: *Ctx) lg.Error!void {
    var b = Base.init(c, 1);
    const succ = try util.successors(c, c.root);
    try extend(&b, succ.items);
}

fn extend(b: *Base, nodes: []const Node) lg.Error!void {
    if (nodes.len == 0) return;
    try b.c.enter();
    defer b.c.leave();
    const old = try b.c.a.alloc(lg.Vec, nodes.len);
    for (nodes, old) |n, *o| o.* = .{ .x = n.x, .y = n.y };
    while (b.overlapLayer(nodes)) {
        try b.c.tick();
        b.contractLayer(nodes, false);
    }
    const moved_x = nodes[0].x - old[0].x;
    const moved_y = nodes[0].y - old[0].y;
    const moved_distance = @sqrt(moved_x * moved_x + moved_y * moved_y);
    const next = try util.nextLevelNodeSet(b.c, nodes);
    for (next.items) |n| Base.moveNode(n, b.root, moved_distance);
    if (b.sorter != null) {
        const copy = try b.c.a.dupe(Node, next.items);
        try b.sort(copy);
    }
    try extend(b, next.items);
}

fn stepSize(c: *const Ctx) i32 {
    return c.graph.opts.radial_compaction_step_size orelse 1;
}

// RadialCompaction
const RadialState = struct {
    b: Base,
    last_radius: f64 = 0,

    fn radius(s: *const RadialState, node: Node) f64 {
        const vx = node.x - s.b.root.x;
        const vy = node.y - s.b.root.y;
        return @sqrt(vx * vx + vy * vy);
    }

    fn overlapping(s: *RadialState, nodes: []const Node) lg.Error!bool {
        if (s.b.overlapLayer(nodes)) return true;
        for (nodes) |node| {
            const parent = util.treeParent(node) orelse return error.ElkException;
            if (s.b.overlap(node, parent)) return true;
            if (s.radius(node) - s.b.spacing <= s.last_radius) return true;
        }
        return false;
    }

    fn contract(s: *RadialState, nodes: []Node) lg.Error!void {
        if (nodes.len == 0) return;
        try s.b.c.enter();
        defer s.b.c.leave();
        var is_overlapping = try s.overlapping(nodes);
        var was_contracted = false;
        while (!is_overlapping) {
            try s.b.c.tick();
            s.b.contractLayer(nodes, true);
            was_contracted = true;
            is_overlapping = try s.overlapping(nodes);
        }
        if (was_contracted) s.b.contractLayer(nodes, false);
        const next = try util.nextLevelNodes(s.b.c, nodes);
        try s.b.sort(next.items);
        s.last_radius = s.radius(nodes[0]);
        try s.contract(next.items);
    }
};

pub fn radialCompaction(c: *Ctx) lg.Error!void {
    var s: RadialState = .{ .b = Base.init(c, stepSize(c)) };
    const first = try util.successors(c, c.root);
    try s.b.sort(first.items);
    try s.contract(first.items);
}

// AnnulusWedgeCompaction
const Contours = std.AutoHashMapUnmanaged(Node, List);

const WedgeState = struct {
    b: Base,
    left: Contours = .empty,
    right: Contours = .empty,

    fn put(s: *WedgeState, m: *Contours, key: Node, v: Node) lg.Error!void {
        const gop = try m.getOrPut(s.b.c.a, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(s.b.c.a, v);
    }

    fn constructContour(s: *WedgeState, nodes: []const Node) lg.Error!void {
        const c = s.b.c;
        for (nodes) |node| {
            try s.put(&s.left, node, node);
            try s.put(&s.right, node, node);
            var succ = try util.successors(c, node);
            if (succ.items.len == 0) continue;
            try s.b.sort(succ.items);
            try s.put(&s.left, node, succ.items[0]);
            try s.put(&s.right, node, succ.items[succ.items.len - 1]);
            var levels: usize = 0;
            while (true) {
                levels += 1;
                try c.bound(levels);
                const next = try util.nextLevelNodes(c, succ.items);
                if (next.items.len == 0) break;
                succ = next;
                try s.b.sort(succ.items);
                try s.put(&s.left, node, succ.items[0]);
                try s.put(&s.right, node, succ.items[succ.items.len - 1]);
            }
        }
    }

    fn contourOverlap(s: *const WedgeState, neighbour: Node, node: Node, use_left: bool) bool {
        const contour = (if (use_left) s.left else s.right).get(neighbour) orelse return false;
        for (contour.items) |cn| if (s.b.overlap(node, cn)) return true;
        return false;
    }

    fn overlapping(s: *WedgeState, predecessors: []const Node, left_parent: Node, right_parent: Node, layer: []Node) lg.Error!bool {
        try s.b.sort(layer);
        if (s.contourOverlap(left_parent, layer[0], false)) return true;
        if (s.contourOverlap(right_parent, layer[layer.len - 1], true)) return true;
        if (s.b.overlapLayer(layer)) return true;
        for (layer) |sorted| for (predecessors) |p| if (s.b.overlap(sorted, p)) return true;
        return false;
    }

    fn contractWedge(s: *WedgeState, predecessors: []const Node, radial_predecessor: Node, radial_successor: Node, current: []Node) lg.Error!void {
        try s.b.c.enter();
        defer s.b.c.leave();
        var is_overlapping = try s.overlapping(predecessors, radial_predecessor, radial_successor, current);
        var was_contracted = false;
        while (!is_overlapping) {
            try s.b.c.tick();
            s.b.contractLayer(current, true);
            was_contracted = true;
            is_overlapping = try s.overlapping(predecessors, radial_predecessor, radial_successor, current);
        }
        if (was_contracted) s.b.contractLayer(current, false);
        const next = try util.nextLevelNodes(s.b.c, current);
        if (next.items.len == 0) return;
        try s.b.sort(next.items);
        try s.contractWedge(current, radial_predecessor, radial_successor, next.items);
    }
};

pub fn wedgeCompaction(c: *Ctx) lg.Error!void {
    var s: WedgeState = .{ .b = Base.init(c, stepSize(c)) };
    const succ = try util.successors(c, c.root);
    try s.b.sort(succ.items);
    try s.constructContour(succ.items);
    var root_list = [_]Node{c.root};
    const n = succ.items.len;
    for (0..2) |_| {
        for (0..n) |i| {
            var node_as_list = [_]Node{succ.items[i]};
            const right_parent = if (i < n - 1) succ.items[i + 1] else succ.items[0];
            const left_parent = if (i == 0) succ.items[n - 1] else succ.items[i - 1];
            try s.contractWedge(&root_list, left_parent, right_parent, &node_as_list);
        }
    }
}
