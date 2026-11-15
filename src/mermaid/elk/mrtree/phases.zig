const std = @import("std");
const lg = @import("../lgraph.zig");
const t = @import("tree.zig");
const Allocator = std.mem.Allocator;
const TNode = t.TNode;
const TEdge = t.TEdge;
const TGraph = t.TGraph;

const max_level_len = 1 << 20;
const max_steps = 1 << 24;

// Duplicate children (parallel edges under BFS) make Java loop or overflow its stack; fail instead of hanging.
fn guard(next_len: usize, iter: usize, nodes: usize) lg.Error!void {
    if (next_len > max_level_len or iter > nodes + 2) return error.ElkException;
}

fn removeEdge(list: *std.ArrayList(*TEdge), e: *TEdge) void {
    lg.removeItem(TEdge, list, e);
}

// p1treeify.DFSTreeifyer
pub fn treeify(a: Allocator, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    const visited = try a.alloc(u8, g.nodes.items.len);
    @memset(visited, 0);
    var eliminated: std.ArrayList(*TEdge) = .empty;
    for (g.nodes.items, 0..) |n, i| n.id = @intCast(i);
    for (g.nodes.items) |n| {
        const id: usize = @intCast(n.id);
        if (visited[id] == 0) {
            switch (cfg.search_order) {
                .dfs => try dfs(a, visited, &eliminated, n),
                .bfs => try bfs(a, visited, &eliminated, n),
            }
            visited[id] = 2;
        }
    }
    for (eliminated.items) |e| {
        removeEdge(&e.source.outgoing, e);
        removeEdge(&e.target.incoming, e);
    }
    g.removable = eliminated;
}

fn dfs(a: Allocator, visited: []u8, eliminated: *std.ArrayList(*TEdge), n: *TNode) lg.Error!void {
    visited[@intCast(n.id)] = 1;
    for (n.outgoing.items) |e| {
        const tid: usize = @intCast(e.target.id);
        if (visited[tid] == 1) {
            try eliminated.append(a, e);
        } else if (visited[tid] == 2) {
            visited[tid] = 1;
        } else {
            try dfs(a, visited, eliminated, e.target);
        }
    }
}

fn bfs(a: Allocator, visited: []u8, eliminated: *std.ArrayList(*TEdge), start: *TNode) lg.Error!void {
    var queue: std.ArrayList(*TNode) = .empty;
    var head: usize = 0;
    try queue.append(a, start);
    while (true) {
        const n = queue.items[head];
        head += 1;
        visited[@intCast(n.id)] = 1;
        for (n.outgoing.items) |e| {
            const tid: usize = @intCast(e.target.id);
            if (visited[tid] == 1) {
                try eliminated.append(a, e);
            } else if (visited[tid] == 2) {
                visited[tid] = 1;
            } else {
                if (queue.items.len > max_level_len) return error.ElkException;
                try queue.append(a, e.target);
            }
        }
        if (head >= queue.items.len) break;
    }
}

// intermediate.Untreeifyer
pub fn untreeify(a: Allocator, g: *TGraph) lg.Error!void {
    for (g.removable.items) |e| {
        try e.source.outgoing.append(a, e);
        try e.target.incoming.append(a, e);
    }
}

// intermediate.RootProcessor
pub fn rootProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    var roots: std.ArrayList(*TNode) = .empty;
    for (g.nodes.items) |n| {
        if (n.incoming.items.len == 0) {
            n.root = true;
            try roots.append(a, n);
        }
    }
    switch (roots.items.len) {
        0 => {
            const root = try t.newNode(a, 0, "DUMMY_ROOT");
            root.root = true;
            try g.nodes.append(a, root);
        },
        1 => {},
        else => {
            const super = try t.newNode(a, 0, "SUPER_ROOT");
            for (roots.items) |r| {
                try t.addChild(a, g, super, r);
                r.root = false;
            }
            super.root = true;
            try g.nodes.append(a, super);
        },
    }
}

// intermediate.FanProcessor. The Java code keys fan and descendants by string ids that are built per level and
// compared by reference, so a node reachable from two parents (BFS treeifying) shares or steals ids exactly as there.
const Id = struct { s: []const u8 };

pub fn fanProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    const root = try t.getRoot(g);
    const empty: *const Id = &.{ .s = "" };
    var ids = std.AutoHashMap(*TNode, *const Id).init(a);
    for (g.nodes.items) |n| try ids.put(n, empty);
    var fan_map = std.StringHashMap(i32).init(a);
    var desc_map = std.StringHashMap(i32).init(a);
    var level: std.ArrayList(*TNode) = .empty;
    try level.append(a, root);
    var iter: usize = 0;
    while (level.items.len > 0) : (iter += 1) {
        var next: std.ArrayList(*TNode) = .empty;
        const digits = std.fmt.count("{d}", .{level.items.len});
        var last: *const Id = empty;
        var p_id: ?*const Id = null;
        var index: usize = 0;
        for (level.items) |n| {
            const cur = ids.get(n).?;
            if (p_id != cur) {
                p_id = cur;
                index = 0;
            }
            const id = try a.create(Id);
            id.* = .{ .s = try std.fmt.allocPrint(a, "{s}{d:0>[2]}", .{ p_id.?.s, index, digits }) };
            index += 1;
            last = id;
            try ids.put(n, id);
            for (n.outgoing.items) |e| {
                try next.append(a, e.target);
                try ids.put(e.target, id);
            }
        }
        var loc = std.StringHashMap(i32).init(a);
        var i: usize = 0;
        while (i + digits < last.s.len) : (i += 1) {
            for (level.items) |n| {
                const id = ids.get(n).?.s;
                if (id.len < i + 1) return error.ElkException;
                const r = try loc.getOrPut(id[0 .. i + 1]);
                r.value_ptr.* = if (r.found_existing) r.value_ptr.* + 1 else 1;
            }
        }
        var it = loc.iterator();
        while (it.next()) |en| {
            const d = try desc_map.getOrPut(en.key_ptr.*);
            d.value_ptr.* = en.value_ptr.* + (if (d.found_existing) d.value_ptr.* else 0);
            const f = try fan_map.getOrPut(en.key_ptr.*);
            if (!f.found_existing or f.value_ptr.* < en.value_ptr.*) f.value_ptr.* = en.value_ptr.*;
        }
        try guard(next.items.len, iter, g.nodes.items.len);
        level = next;
    }
    for (g.nodes.items) |n| {
        const key = ids.get(n).?.s;
        n.fan = fan_map.get(key) orelse 0;
        n.descendants = 1 + (desc_map.get(key) orelse 0);
    }
}

// intermediate.LevelProcessor. The map is keyed by TNode.id, which the SUPER_ROOT shares with the first node.
pub fn levelProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    const map = try a.alloc(?i32, g.nodes.items.len + 1);
    @memset(map, null);
    var cur: std.ArrayList(*TNode) = .empty;
    for (g.nodes.items) |n| if (n.root) try cur.append(a, n);
    var level: i32 = 0;
    var iter: usize = 0;
    while (cur.items.len > 0) : (level += 1) {
        var next: std.ArrayList(*TNode) = .empty;
        for (cur.items) |n| {
            map[@intCast(n.id)] = level;
            for (n.outgoing.items) |e| try next.append(a, e.target);
        }
        try guard(next.items.len, iter, g.nodes.items.len);
        iter += 1;
        cur = next;
    }
    for (g.nodes.items) |n| n.level = map[@intCast(n.id)] orelse 0;
}

// intermediate.NeighborsProcessor
pub fn neighborsProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    var root: ?*TNode = null;
    for (g.nodes.items) |n| if (n.root) {
        root = n;
        break;
    };
    const r = root orelse return;
    var cur = try r.childrenCopy(a);
    var iter: usize = 0;
    while (cur.items.len > 0) {
        var next: std.ArrayList(*TNode) = .empty;
        var ln: ?*TNode = null;
        for (cur.items) |cn| {
            for (cn.outgoing.items) |e| try next.append(a, e.target);
            if (ln) |l| {
                l.right_neighbor = cn;
                cn.left_neighbor = l;
                if (cn.getParent() == l.getParent()) {
                    l.right_sibling = cn;
                    cn.left_sibling = l;
                }
            }
            ln = cn;
        }
        try guard(next.items.len, iter, g.nodes.items.len);
        iter += 1;
        cur = next;
    }
}

// intermediate.LevelHeightProcessor
pub fn levelHeightProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    var root: ?*TNode = null;
    for (g.nodes.items) |n| if (n.root) {
        root = n;
        break;
    };
    const r = root orelse return;
    var cur: std.ArrayList(*TNode) = .empty;
    try cur.append(a, r);
    const horizontal = t.isHorizontal(g.direction);
    var iter: usize = 0;
    while (cur.items.len > 0) {
        var next: std.ArrayList(*TNode) = .empty;
        var height: f64 = 0;
        for (cur.items) |cn| {
            for (cn.outgoing.items) |e| try next.append(a, e.target);
            const s = if (horizontal) cn.size.x else cn.size.y;
            if (height < s) height = s;
        }
        for (cur.items) |cn| cn.level_height = height;
        try guard(next.items.len, iter, g.nodes.items.len);
        iter += 1;
        cur = next;
    }
}

// p2order.NodeOrderer
pub fn orderNodes(a: Allocator, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    const root = try t.getRoot(g);
    switch (cfg.weighting) {
        .model_order => {},
        .fan, .descendants => {
            var level: std.ArrayList(*TNode) = .empty;
            try level.append(a, root);
            try orderLevelFanDescendants(a, &level, cfg.weighting == .descendants);
        },
        .constraint => {
            var level: std.ArrayList(*TNode) = .empty;
            try level.append(a, root);
            try orderLevelConstraint(a, &level);
        },
    }
}

fn weight(n: *const TNode, by_descendants: bool) i32 {
    return if (by_descendants) n.descendants else n.fan;
}

const Weights = struct {
    descendants: bool,
    fn less(self: Weights, x: *TNode, y: *TNode) bool {
        return weight(x, self.descendants) < weight(y, self.descendants);
    }
};

fn positionAscending(_: void, x: *TNode, y: *TNode) bool {
    return x.position < y.position;
}

fn positionDescending(_: void, x: *TNode, y: *TNode) bool {
    return x.position > y.position;
}

fn sortOutgoing(a: Allocator, parent: *TNode, children: []const *TNode) Allocator.Error!void {
    var sorted: std.ArrayList(*TEdge) = .empty;
    for (children) |c| for (parent.outgoing.items) |e| {
        if (e.target == c) try sorted.append(a, e);
    };
    parent.outgoing.clearRetainingCapacity();
    try parent.outgoing.appendSlice(a, sorted.items);
}

// The leaf list of the Java code stays empty whenever there are inner nodes (ascending sort puts zeros first), so
// only the all-leaves case assigns positions directly.
fn orderLevelFanDescendants(a: Allocator, level: *std.ArrayList(*TNode), by_descendants: bool) lg.Error!void {
    std.mem.sort(*TNode, level.items, Weights{ .descendants = by_descendants }, Weights.less);
    var first_occ = level.items.len;
    while (first_occ > 0 and weight(level.items[first_occ - 1], by_descendants) == 0) first_occ -= 1;
    var pos: i32 = 0;
    if (first_occ == 0) {
        for (level.items) |n| {
            n.position = pos;
            pos += 1;
        }
        return;
    }
    const inners = try a.dupe(*TNode, level.items[0..first_occ]);
    for (inners) |p| {
        p.position = pos;
        pos += 1;
        var children = try p.childrenCopy(a);
        try orderLevelFanDescendants(a, &children, by_descendants);
        std.mem.sort(*TNode, children.items, {}, positionDescending);
        try sortOutgoing(a, p, children.items);
    }
}

fn orderLevelConstraint(a: Allocator, level: *std.ArrayList(*TNode)) lg.Error!void {
    const n: i32 = @intCast(level.items.len);
    var undefined_nodes: std.ArrayList(*TNode) = .empty;
    var in_bound: std.ArrayList(*TNode) = .empty;
    var out_of_bound: std.ArrayList(*TNode) = .empty;
    for (level.items) |x| if (x.position_constraint < 0) try undefined_nodes.append(a, x);
    for (level.items) |x| if (x.position_constraint < n and x.position_constraint >= 0) try in_bound.append(a, x);
    for (level.items) |x| if (x.position_constraint >= n) try out_of_bound.append(a, x);
    const sorted = try a.alloc(?*TNode, level.items.len);
    @memset(sorted, null);
    var i: usize = 0;
    while (i < in_bound.items.len) {
        const cur = in_bound.items[i];
        const tp = cur.position_constraint;
        if (tp >= 0 and tp < @as(i32, @intCast(in_bound.items.len)) and sorted[@intCast(tp)] == null) {
            sorted[@intCast(tp)] = cur;
            _ = in_bound.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    i = 0;
    while (i < in_bound.items.len) {
        const cur = in_bound.items[i];
        const tp = cur.position_constraint;
        var j: i32 = 0;
        while (true) : (j += 1) {
            var nt = tp + j;
            if (nt < @as(i32, @intCast(sorted.len)) and nt >= 0 and sorted[@intCast(nt)] == null) {
                sorted[@intCast(nt)] = cur;
                _ = in_bound.orderedRemove(i);
                break;
            }
            nt = tp - j;
            if (nt < @as(i32, @intCast(sorted.len)) and nt >= 0 and sorted[@intCast(nt)] == null) {
                sorted[@intCast(nt)] = cur;
                _ = in_bound.orderedRemove(i);
                break;
            }
        }
    }
    std.mem.sort(*TNode, out_of_bound.items, {}, struct {
        fn less(_: void, x: *TNode, y: *TNode) bool {
            return x.position_constraint > y.position_constraint;
        }
    }.less);
    var k = sorted.len;
    while (k > 0) {
        k -= 1;
        if (sorted[k] == null and out_of_bound.items.len > 0) {
            sorted[k] = out_of_bound.orderedRemove(0);
        }
    }
    for (sorted) |*slot| {
        if (slot.* == null and undefined_nodes.items.len > 0) slot.* = undefined_nodes.orderedRemove(0);
    }
    for (sorted, 0..) |slot, idx| (slot orelse return error.ElkException).position = @intCast(idx);
    var inners: std.ArrayList(*TNode) = .empty;
    for (level.items) |x| if (x.fan != 0) try inners.append(a, x);
    for (inners.items) |p| {
        var children = try p.childrenCopy(a);
        try orderLevelConstraint(a, &children);
        std.mem.sort(*TNode, children.items, {}, positionAscending);
        try sortOutgoing(a, p, children.items);
    }
}

// p3place.NodePlacer
pub fn placeNodes(a: Allocator, g: *TGraph, cfg: *const t.Config) lg.Error!void {
    var p: Placer = .{ .a = a, .spacing = cfg.spacing_node_node, .direction = g.direction, .max_depth = g.nodes.items.len + 2 };
    if (p.direction == .undefined) {
        p.direction = .down;
        g.direction = .down;
    }
    const root = try t.getRoot(g);
    try p.firstWalk(root, 0);
    try p.secondWalk(root, 0 - root.level_height / 2, 0, 0);
}

const Placer = struct {
    a: Allocator,
    spacing: f64,
    direction: lg.Direction,
    max_depth: usize,
    steps: usize = 0,

    fn tick(self: *Placer) lg.Error!void {
        self.steps += 1;
        if (self.steps > max_steps) return error.ElkException;
    }

    fn firstWalk(self: *Placer, cn: *TNode, depth: usize) lg.Error!void {
        if (depth > self.max_depth) return error.ElkException;
        cn.modifier = 0;
        const ls = cn.left_sibling;
        if (cn.isLeaf()) {
            if (ls) |l| {
                cn.prelim = l.prelim + self.spacing + self.meanNodeWidth(l, cn);
            } else {
                cn.prelim = 0;
            }
        } else {
            for (cn.outgoing.items) |e| try self.firstWalk(e.target, depth + 1);
            const lm = cn.firstChild().?;
            const rm = cn.lastChild().?;
            const mid_point = (rm.prelim + lm.prelim) / 2;
            if (ls) |l| {
                cn.prelim = l.prelim + self.spacing + self.meanNodeWidth(l, cn);
                cn.modifier = cn.prelim - mid_point;
                try self.apportion(cn);
            } else {
                cn.prelim = mid_point;
            }
        }
    }

    fn apportion(self: *Placer, cn: *TNode) lg.Error!void {
        var leftmost: ?*TNode = cn.firstChild();
        var neighbor: ?*TNode = if (leftmost) |l| l.left_neighbor else null;
        var compare_depth: i32 = 1;
        while (leftmost != null and neighbor != null) {
            try self.tick();
            var left_mod_sum: f64 = 0;
            var right_mod_sum: f64 = 0;
            var anc_left = leftmost.?;
            var anc_neigh = neighbor.?;
            var i: i32 = 0;
            while (i < compare_depth) : (i += 1) {
                anc_left = anc_left.getParent() orelse return error.ElkException;
                anc_neigh = anc_neigh.getParent() orelse return error.ElkException;
                right_mod_sum += anc_left.modifier;
                left_mod_sum += anc_neigh.modifier;
            }
            const pr_n = neighbor.?.prelim;
            const pr_l = leftmost.?.prelim;
            const mean = self.meanNodeWidth(leftmost.?, neighbor.?);
            var move_distance = pr_n + left_mod_sum + self.spacing + mean - pr_l - right_mod_sum;
            if (0 < move_distance) {
                var left_sibling: ?*TNode = cn;
                var left_siblings: i32 = 0;
                while (left_sibling != null and left_sibling != anc_neigh) {
                    try self.tick();
                    left_siblings += 1;
                    left_sibling = left_sibling.?.left_sibling;
                }
                if (left_sibling != null) {
                    const portion = move_distance / @as(f64, @floatFromInt(left_siblings));
                    left_sibling = cn;
                    while (left_sibling != anc_neigh) {
                        try self.tick();
                        const ls = left_sibling.?;
                        ls.prelim += move_distance;
                        ls.modifier += move_distance;
                        move_distance -= portion;
                        left_sibling = ls.left_sibling;
                    }
                } else {
                    return;
                }
            }
            compare_depth += 1;
            if (leftmost.?.isLeaf()) {
                const kids = try cn.childrenCopy(self.a);
                leftmost = try t.getLeftMost(self.a, kids.items, compare_depth);
            } else {
                leftmost = leftmost.?.firstChild();
            }
            neighbor = if (leftmost) |l| l.left_neighbor else null;
        }
    }

    fn meanNodeWidth(self: *const Placer, left: ?*TNode, right: ?*TNode) f64 {
        var w: f64 = 0;
        const vertical = t.isVertical(self.direction);
        if (left) |l| w += (if (vertical) l.size.x else l.size.y) / 2;
        if (right) |r| w += (if (vertical) r.size.x else r.size.y) / 2;
        return w;
    }

    fn secondWalk(self: *Placer, node: ?*TNode, y_coor: f64, modsum: f64, depth: usize) lg.Error!void {
        const n = node orelse return;
        if (depth > self.max_depth) return error.ElkException;
        const x_temp = n.prelim + modsum;
        const y_temp = y_coor + n.level_height / 2;
        n.xcoor = @intFromFloat(@floor(x_temp + 0.5));
        n.ycoor = @intFromFloat(@floor(y_temp + 0.5));
        if (!n.isLeaf()) {
            try self.secondWalk(n.firstChild(), y_coor + n.level_height + self.spacing, modsum + n.modifier, depth + 1);
        }
        if (n.right_sibling) |rs| try self.secondWalk(rs, y_coor, modsum, depth + 1);
    }
};

// intermediate.DirectionProcessor
pub fn directionProcessor(g: *TGraph) void {
    const d = g.direction;
    if (d == .down) return;
    for (g.nodes.items) |n| {
        var x = n.xcoor;
        var y = n.ycoor;
        switch (d) {
            .up => y *= -1,
            .right => {
                const tmp = x;
                x = y;
                y = tmp;
            },
            .left => {
                const tmp = x;
                x = -y;
                y = tmp;
            },
            else => {},
        }
        n.xcoor = x;
        n.ycoor = y;
    }
}

// intermediate.NodePositionProcessor
pub fn nodePositionProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    var root: ?*TNode = null;
    for (g.nodes.items) |n| if (n.root) {
        root = n;
        break;
    };
    const r = root orelse return error.ElkException;
    r.pos = .{ .x = @floatFromInt(r.xcoor), .y = @floatFromInt(r.ycoor) };
    var cur = try r.childrenCopy(a);
    var iter: usize = 0;
    while (cur.items.len > 0) {
        var next: std.ArrayList(*TNode) = .empty;
        for (cur.items) |n| {
            for (n.outgoing.items) |e| try next.append(a, e.target);
            n.pos = .{ .x = @floatFromInt(n.xcoor), .y = @floatFromInt(n.ycoor) };
        }
        try guard(next.items.len, iter, g.nodes.items.len);
        iter += 1;
        cur = next;
    }
    for (g.nodes.items) |n| {
        n.pos.x -= n.size.x / 2;
        n.pos.y -= n.size.y / 2;
    }
}

// intermediate.LevelCoordinatesProcessor
pub fn levelCoordinatesProcessor(a: Allocator, g: *TGraph) lg.Error!void {
    const Pair = struct { first: f64, second: f64 };
    var levels: std.ArrayList(Pair) = .empty;
    const horizontal = t.isHorizontal(g.direction);
    for (g.nodes.items) |n| {
        const lv: usize = @intCast(n.level);
        while (lv + 1 > levels.items.len) try levels.append(a, .{ .first = std.math.floatMax(f64), .second = -std.math.floatMax(f64) });
        const p = &levels.items[lv];
        const lo = if (horizontal) n.pos.x else n.pos.y;
        const hi = if (horizontal) n.pos.x + n.size.x else n.pos.y + n.size.y;
        if (lo < p.first) p.first = lo;
        if (hi > p.second) p.second = hi;
    }
    for (g.nodes.items) |n| {
        const p = levels.items[@intCast(n.level)];
        n.level_min = p.first;
        n.level_max = p.second;
    }
}

// intermediate.GraphBoundsProcessor
pub fn graphBoundsProcessor(g: *TGraph) lg.Error!void {
    if (g.nodes.items.len == 0) return error.ElkException;
    var xmin = std.math.inf(f64);
    var ymin = std.math.inf(f64);
    var xmax = -std.math.inf(f64);
    var ymax = -std.math.inf(f64);
    for (g.nodes.items) |n| {
        xmin = @min(xmin, n.pos.x);
        ymin = @min(ymin, n.pos.y);
        xmax = @max(xmax, n.pos.x + n.size.x);
        ymax = @max(ymax, n.pos.y + n.size.y);
    }
    g.xmin = xmin;
    g.ymin = ymin;
    g.xmax = xmax;
    g.ymax = ymax;
}
