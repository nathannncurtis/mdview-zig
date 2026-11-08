const lg = @import("../lgraph.zig");
const util = @import("../util.zig");

// PortListSorter; portSortingStrategy stays INPUT_ORDER for Mermaid, so the PORT_DEGREE re-sort is left out
pub fn process(g: *lg.LGraph) lg.Error!void {
    for (g.layers.items) |layer| {
        for (layer.nodes.items) |node| {
            const pc = node.p.port_constraints;
            const ports = node.ports.items;
            if (pc.isOrderFixed()) {
                try util.javaSort(*lg.LPort, g.a, ports, {}, cmpCombined);
            } else if (pc.isSideFixed()) {
                try util.javaSort(*lg.LPort, g.a, ports, {}, cmpPortSide);
                reverseWestAndSouthSide(ports);
            }
            node.port_sides_cached = true;
        }
    }
}

fn reverseWestAndSouthSide(ports: []*lg.LPort) void {
    if (ports.len <= 1) return;
    const s = findPortSideRange(ports, .south);
    reverse(ports, s.low, s.high);
    const w = findPortSideRange(ports, .west);
    reverse(ports, w.low, w.high);
}

const Range = struct { low: usize, high: usize };

fn findPortSideRange(ports: []*lg.LPort, side: lg.PortSide) Range {
    if (ports.len == 0) return .{ .low = 0, .high = 0 };
    var current = ports[0].side;
    var low: usize = 0;
    const lb = @backingInt(side);
    const hb = @backingInt(side) + 1;
    while (low < ports.len - 1 and @backingInt(current) < lb) {
        low += 1;
        current = ports[low].side;
    }
    var high = low;
    while (high < ports.len - 1 and @backingInt(current) < hb) {
        high += 1;
        // ELK reads ports[lowIdx] here, not ports[highIdx]
        current = ports[low].side;
    }
    return .{ .low = low, .high = high };
}

fn reverse(ports: []*lg.LPort, low: usize, high: usize) void {
    if (high <= low + 2) return;
    const n = (high - low) / 2;
    for (0..n) |i| {
        const tmp = ports[low + i];
        ports[low + i] = ports[high - i - 1];
        ports[high - i - 1] = tmp;
    }
}

fn sideDiff(p1: *lg.LPort, p2: *lg.LPort) i32 {
    return @as(i32, @backingInt(p1.side)) - @as(i32, @backingInt(p2.side));
}

pub fn cmpPortSide(_: void, p1: *lg.LPort, p2: *lg.LPort) lg.Error!i32 {
    return sideDiff(p1, p2);
}

fn dcmp(x: f64, y: f64) i32 {
    return switch (util.doubleCompare(x, y)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn cmpFixedOrderAndFixedPos(_: void, p1: *lg.LPort, p2: *lg.LPort) lg.Error!i32 {
    const pc = p1.owner.?.p.port_constraints;
    if (sideDiff(p1, p2) != 0 or !pc.isOrderFixed()) return 0;
    if (pc == .fixed_order) {
        const d = p1.p.port_index - p2.p.port_index;
        if (d != 0) return d;
    }
    return switch (p1.side) {
        .north => dcmp(p1.pos.x, p2.pos.x),
        .east => dcmp(p1.pos.y, p2.pos.y),
        .south => dcmp(p2.pos.x, p1.pos.x),
        .west => dcmp(p2.pos.y, p1.pos.y),
        .undefined => 0,
    };
}

pub fn cmpCombined(_: void, p1: *lg.LPort, p2: *lg.LPort) lg.Error!i32 {
    const s = sideDiff(p1, p2);
    if (s != 0) return s;
    return cmpFixedOrderAndFixedPos({}, p1, p2);
}
