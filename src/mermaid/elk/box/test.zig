const std = @import("std");
const fixtures = @import("fixtures.zig");

test {
    _ = @import("box.zig");
    std.testing.refAllDecls(@import("fuzz.zig"));
}

test "box layout matches elkjs on the fixtures" {
    try fixtures.check("box-");
}
