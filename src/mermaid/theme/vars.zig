const std = @import("std");
const Allocator = std.mem.Allocator;
const numfmt = @import("../numfmt.zig");
const json = std.json;

pub const Err = error{ OutOfMemory, InvalidColor, ChannelConflict, NotNumber };

pub const V = union(enum) {
    undef,
    s: []const u8,
    n: f64,
    b: bool,

    pub fn truthy(v: V) bool {
        return switch (v) {
            .undef => false,
            .s => |s| s.len > 0,
            .n => |n| n != 0 and !std.math.isNan(n),
            .b => |b| b,
        };
    }

    pub fn eql(a: V, b: V) bool {
        return switch (a) {
            .undef => b == .undef,
            .s => |s| b == .s and std.mem.eql(u8, s, b.s),
            .n => |n| b == .n and n == b.n,
            .b => |x| b == .b and x == b.b,
        };
    }

    pub fn num(v: V) Err!f64 {
        return switch (v) {
            .n => |n| n,
            else => error.NotNumber,
        };
    }

    pub fn text(v: V, a: Allocator) Allocator.Error!?[]const u8 {
        return switch (v) {
            .undef => null,
            .s => |s| s,
            .n => |n| try numfmt.js(a, n),
            .b => |b| if (b) "true" else "false",
        };
    }
};

pub const Override = struct { key: []const u8, value: V };

/// Theme variables by name; nested objects use dotted keys.
pub const Vars = struct {
    a: Allocator,
    map: std.StringArrayHashMapUnmanaged(V) = .empty,

    pub fn get(t: *const Vars, name: []const u8) V {
        return t.map.get(name) orelse .undef;
    }

    pub fn set(t: *Vars, name: []const u8, v: V) Err!void {
        try t.map.put(t.a, name, v);
    }

    pub fn key(t: *Vars, prefix: []const u8, n: f64) Err![]const u8 {
        return std.mem.concat(t.a, u8, &.{ prefix, try numfmt.js(t.a, n) });
    }

    /// Number of entries `name.0`, `name.1`, ... (a JS array theme variable).
    pub fn len(t: *const Vars, name: []const u8) f64 {
        var n: f64 = 0;
        for (t.map.keys()) |k| {
            if (k.len > name.len + 1 and k[name.len] == '.' and std.mem.startsWith(u8, k, name)) {
                var digits = true;
                for (k[name.len + 1 ..]) |c| if (c < '0' or c > '9') {
                    digits = false;
                };
                if (digits) n += 1;
            }
        }
        return n;
    }

    pub fn str(t: *const Vars, name: []const u8) ?[]const u8 {
        return switch (t.get(name)) {
            .s => |s| s,
            else => null,
        };
    }
};

/// The overrides are applied before and again after the derived values, as every theme's `calculate` does.
pub fn calculate(t: *Vars, comptime theme: type, overrides: []const Override) Err!void {
    try theme.init(t);
    if (@hasDecl(theme, "resets_calculated")) {
        for (t.map.values()) |*v| if (v.* == .s and std.mem.eql(u8, v.s, "calculated")) {
            v.* = .undef;
        };
    }
    try applyOverrides(t, overrides);
    try theme.updateColors(t);
    try applyOverrides(t, overrides);
}

fn applyOverrides(t: *Vars, overrides: []const Override) Err!void {
    for (overrides) |o| try t.set(o.key, o.value);
}

/// Turns a JSON object of theme variables into overrides with dotted keys; a nested object merges with the computed
/// one, as `applyOverride` does in mermaid's themes.
pub fn flattenJson(a: Allocator, out: *std.ArrayList(Override), prefix: []const u8, obj: json.Value) Err!void {
    if (obj != .object) return;
    var it = obj.object.iterator();
    while (it.next()) |kv| {
        const key = if (prefix.len == 0) kv.key_ptr.* else try std.mem.concat(a, u8, &.{ prefix, ".", kv.key_ptr.* });
        switch (kv.value_ptr.*) {
            .string => |s| try out.append(a, .{ .key = key, .value = .{ .s = s } }),
            .bool => |b| try out.append(a, .{ .key = key, .value = .{ .b = b } }),
            .integer => |n| try out.append(a, .{ .key = key, .value = .{ .n = @floatFromInt(n) } }),
            .float => |n| try out.append(a, .{ .key = key, .value = .{ .n = n } }),
            .number_string => |s| try out.append(a, .{ .key = key, .value = .{ .n = std.fmt.parseFloat(f64, s) catch std.math.nan(f64) } }),
            .object => try flattenJson(a, out, key, kv.value_ptr.*),
            else => {},
        }
    }
}
