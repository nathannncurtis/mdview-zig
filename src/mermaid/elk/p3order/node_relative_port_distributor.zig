const lg = @import("../lgraph.zig");

// NodeRelativePortDistributor.calculatePortRanks
pub fn calculatePortRanks(port_ranks: []f64, node: *lg.LNode, rank_sum: f64, port_type: lg.PortType) f64 {
    switch (port_type) {
        .input => {
            var input_count: i32 = 0;
            var north_input_count: i32 = 0;
            for (node.ports.items) |port| {
                if (port.incoming.items.len != 0) {
                    input_count += 1;
                    if (port.side == .north) north_input_count += 1;
                }
            }
            const incr = 1.0 / @as(f64, @floatFromInt(input_count + 1));
            var north_pos = rank_sum + @as(f64, @floatFromInt(north_input_count)) * incr;
            var rest_pos = rank_sum + 1 - incr;
            for (node.ports.items) |port| {
                if (port.incoming.items.len == 0) continue;
                if (port.side == .north) {
                    port_ranks[@intCast(port.id)] = north_pos;
                    north_pos -= incr;
                } else {
                    port_ranks[@intCast(port.id)] = rest_pos;
                    rest_pos -= incr;
                }
            }
        },
        .output => {
            var output_count: i32 = 0;
            for (node.ports.items) |port| {
                if (port.outgoing.items.len != 0) output_count += 1;
            }
            const incr = 1.0 / @as(f64, @floatFromInt(output_count + 1));
            var pos = rank_sum + incr;
            for (node.ports.items) |port| {
                if (port.outgoing.items.len == 0) continue;
                port_ranks[@intCast(port.id)] = pos;
                pos += incr;
            }
        },
        .undefined => {},
    }
    return 1;
}
