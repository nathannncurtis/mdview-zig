const recursive = @import("../recursive_layout.zig");
const parity = @import("../test.zig");

test {
    _ = @import("mrtree.zig");
    _ = @import("fuzz.zig");
}

test "mrtree layout matches elkjs on the fixtures" {
    try parity.checkFixtures("mrtree", recursive.layout, 80);
}
