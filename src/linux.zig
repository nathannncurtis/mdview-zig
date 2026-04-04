// Linux backend — X11 + Cairo + Pango
// Stub — will be implemented
const app = @import("main.zig");

pub fn run() void {
    app.log("linux backend not yet implemented");
}

pub fn invalidate() void {}

pub fn registerFileAssociation() void {
    app.log("--register not supported on linux");
}
