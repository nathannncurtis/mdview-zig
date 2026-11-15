const std = @import("std");

test {
    std.testing.refAllDecls(@import("../elk_graph.zig"));
    std.testing.refAllDecls(@import("../elk_json.zig"));
    std.testing.refAllDecls(@import("node_label_size.zig"));
    std.testing.refAllDecls(@import("elk_graph_importer.zig").Importer);
    std.testing.refAllDecls(@import("elk_graph_layout_transferrer.zig"));
    std.testing.refAllDecls(@import("../compound/compound_graph_preprocessor.zig"));
    std.testing.refAllDecls(@import("../compound/compound_graph_postprocessor.zig"));
    std.testing.refAllDecls(@import("../compound/cross_hierarchy_edge.zig"));
    std.testing.refAllDecls(@import("../intermediate/hierarchical_node_resizing_processor.zig"));
    std.testing.refAllDecls(@import("../intermediate/hierarchical_port_constraint_processor.zig"));
    std.testing.refAllDecls(@import("../components/components_processor.zig"));
    std.testing.refAllDecls(@import("../recursive_layout.zig"));
    std.testing.refAllDecls(@import("../layered.zig"));
}
