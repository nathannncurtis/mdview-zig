const std = @import("std");

const files = .{
    @import("layer_sweep_crossing_minimizer.zig"),
    @import("graph_info_holder.zig"),
    @import("layer_sweep_type_decider.zig"),
    @import("barycenter_heuristic.zig"),
    @import("forster_constraint_resolver.zig"),
    @import("sweep_copy.zig"),
    @import("abstract_barycenter_port_distributor.zig"),
    @import("node_relative_port_distributor.zig"),
    @import("layer_total_port_distributor.zig"),
    @import("greedy_port_distributor.zig"),
    @import("i_crossing_minimization_heuristic.zig"),
    @import("i_sweep_port_distributor.zig"),
    @import("counting/all_crossings_counter.zig"),
    @import("counting/crossings_counter.zig"),
    @import("counting/hyperedge_crossings_counter.zig"),
    @import("counting/binary_indexed_tree.zig"),
    @import("counting/cross_min_util.zig"),
    @import("../intermediate/port_side_processor.zig"),
    @import("../intermediate/port_list_sorter.zig"),
    @import("../intermediate/inverted_port_processor.zig"),
    @import("../intermediate/sort_by_input_model_processor.zig"),
    @import("../intermediate/in_layer_constraint_processor.zig"),
    @import("../intermediate/preserveorder/model_order_node_comparator.zig"),
    @import("../intermediate/preserveorder/model_order_port_comparator.zig"),
    @import("../intermediate/greedyswitch/greedy_switch_heuristic.zig"),
    @import("../intermediate/greedyswitch/switch_decider.zig"),
    @import("../intermediate/greedyswitch/crossing_matrix_filler.zig"),
    @import("../intermediate/greedyswitch/between_layer_edge_two_node_crossings_counter.zig"),
    @import("../intermediate/greedyswitch/north_south_edge_neighbouring_node_crossings_counter.zig"),
};

test {
    inline for (files) |f| refAll(f);
}

fn refAll(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |d| {
        const v = @field(T, d);
        if (@TypeOf(v) == type) {
            switch (@typeInfo(v)) {
                .@"struct", .@"union" => refAll(v),
                else => {},
            }
        } else {
            _ = &@field(T, d);
        }
    }
}
