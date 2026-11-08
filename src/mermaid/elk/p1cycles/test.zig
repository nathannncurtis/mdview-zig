const std = @import("std");

test {
    std.testing.refAllDecls(@import("depth_first_cycle_breaker.zig"));
    std.testing.refAllDecls(@import("../p2layers/network_simplex_layerer.zig"));
    std.testing.refAllDecls(@import("../network_simplex.zig"));
    std.testing.refAllDecls(@import("../intermediate/edge_and_layer_constraint_edge_reverser.zig"));
    std.testing.refAllDecls(@import("../intermediate/layer_constraint_preprocessor.zig"));
    std.testing.refAllDecls(@import("../intermediate/layer_constraint_postprocessor.zig"));
    std.testing.refAllDecls(@import("../intermediate/reversed_edge_restorer.zig"));
    std.testing.refAllDecls(@import("../intermediate/long_edge_splitter.zig"));
    std.testing.refAllDecls(@import("../intermediate/long_edge_joiner.zig"));
    std.testing.refAllDecls(@import("../intermediate/label_dummy_inserter.zig"));
    std.testing.refAllDecls(@import("../intermediate/label_dummy_switcher.zig"));
    std.testing.refAllDecls(@import("../intermediate/label_dummy_remover.zig"));
    std.testing.refAllDecls(@import("../intermediate/label_side_selector.zig"));
}

test {
    std.testing.refAllDecls(@import("../intermediate/self_loop_pre_processor.zig"));
    std.testing.refAllDecls(@import("../intermediate/self_loop_port_restorer.zig"));
    std.testing.refAllDecls(@import("../intermediate/self_loop_router.zig"));
    std.testing.refAllDecls(@import("../intermediate/self_loop_post_processor.zig"));
}

test {
    std.testing.refAllDecls(@import("greedy_cycle_breaker.zig"));
    std.testing.refAllDecls(@import("interactive_cycle_breaker.zig"));
    std.testing.refAllDecls(@import("model_order_cycle_breaker.zig"));
    std.testing.refAllDecls(@import("../intermediate/interactive_external_port_positioner.zig"));
}
