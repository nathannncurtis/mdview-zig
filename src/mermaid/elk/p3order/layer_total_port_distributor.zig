const lg = @import("../lgraph.zig");

// LayerTotalPortDistributor.calculatePortRanks
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
            var north_pos = rank_sum + @as(f64, @floatFromInt(north_input_count));
            var rest_pos = rank_sum + @as(f64, @floatFromInt(input_count));
            for (node.ports.items) |port| {
                if (port.incoming.items.len == 0) continue;
                if (port.side == .north) {
                    port_ranks[@intCast(port.id)] = north_pos;
                    north_pos -= 1;
                } else {
                    port_ranks[@intCast(port.id)] = rest_pos;
                    rest_pos -= 1;
                }
            }
            return @floatFromInt(input_count);
        },
        .output => {
            var pos: i32 = 0;
            for (node.ports.items) |port| {
                if (port.outgoing.items.len == 0) continue;
                pos += 1;
                port_ranks[@intCast(port.id)] = rank_sum + @as(f64, @floatFromInt(pos));
            }
            return @floatFromInt(pos);
        },
        .undefined => return 0,
    }
}
