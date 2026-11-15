const fixtures = @import("../test.zig");
const mrtree = @import("mrtree.zig");

test {
    _ = @import("mrtree.zig");
}

test "mrtree layout matches elkjs on the fixtures" {
    try fixtures.runFixtures("mrtree-", mrtree.layout, 80);
}
