const builtin = @import("builtin");

test {
    switch (builtin.os.tag) {
        .windows => _ = @import("platform/win32/win32.zig"),
        .linux => _ = @import("platform/linux/linux.zig"),
        else => {},
    }
}
