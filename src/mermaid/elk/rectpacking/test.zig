const std = @import("std");
const fixtures = @import("../box/fixtures.zig");

test {
    _ = @import("rectpacking.zig");
    std.testing.refAllDecls(@import("fuzz.zig"));
}

test "rectpacking layout matches elkjs on the fixtures" {
    try fixtures.check("rectpacking-");
}
