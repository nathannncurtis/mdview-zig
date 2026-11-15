const std = @import("std");
const rt = @import("../jison/runtime.zig");
const G = @import("flow_grammar");
const actions = @import("actions.zig");
const db_mod = @import("db.zig");
const Allocator = std.mem.Allocator;

const P = rt.Parser(G, actions.Actions);

fn collapseBraceBreaks(gpa: Allocator, src: []const u8) Allocator.Error![]u8 {
    var o: std.ArrayList(u8) = .empty;
    errdefer o.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        try o.append(gpa, src[i]);
        if (src[i] == '}') {
            var j = i + 1;
            while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
            if (std.mem.lastIndexOfScalar(u8, src[i + 1 .. j], '\n')) |k| {
                try o.append(gpa, '\n');
                i += k + 2;
                continue;
            }
        }
        i += 1;
    }
    return o.toOwnedSlice(gpa);
}

/// Parses a flowchart definition into `db`; db's allocator holds everything the parse produces.
pub fn parse(gpa: Allocator, db: *db_mod.Db, src: []const u8, diag: *rt.Diag) (rt.Error || rt.regex.Error)!void {
    const cleaned = try collapseBraceBreaks(gpa, src);
    defer gpa.free(cleaned);
    const input = try rt.toUtf16(gpa, cleaned);
    defer gpa.free(input);
    var acts: actions.Actions = .{ .a = db.a, .db = db };
    _ = try P.parse(gpa, &acts, input, diag);
}
