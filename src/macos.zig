// macOS backend — Cocoa + CoreText + CoreGraphics
// Stub — will be implemented
const app = @import("main.zig");

pub fn run() void {
    app.log("macos backend not yet implemented");
}

pub fn invalidate() void {}

pub fn registerFileAssociation() void {
    app.log("--register not supported on macos");
}
