const recursive = @import("../recursive_layout.zig");
const parity = @import("../test.zig");

test {
    _ = @import("stress.zig");
    _ = @import("fuzz.zig");
}

test "stress layout matches elkjs on the fixtures" {
    try parity.checkFixtures("stress", recursive.layout, 80);
}
