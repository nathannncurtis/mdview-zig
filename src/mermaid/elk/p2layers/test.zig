const std = @import("std");

test {
    std.testing.refAllDecls(@import("longest_path_layerer.zig"));
    std.testing.refAllDecls(@import("longest_path_source_layerer.zig"));
    std.testing.refAllDecls(@import("coffman_graham_layerer.zig"));
    std.testing.refAllDecls(@import("min_width_layerer.zig"));
    std.testing.refAllDecls(@import("stretch_width_layerer.zig"));
    std.testing.refAllDecls(@import("interactive_layerer.zig"));
}
