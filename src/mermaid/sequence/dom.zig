const std = @import("std");
const Allocator = std.mem.Allocator;
const numfmt = @import("env.zig").numfmt;
const env = @import("env.zig");

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    tag: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    styles: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(*Node) = .empty,
    text: ?[]const u8 = null,
    parent: ?*Node = null,
};

pub const Dom = struct {
    a: Allocator,

    pub fn create(d: Dom, parent: ?*Node, tag: []const u8) Allocator.Error!*Node {
        const n = try d.a.create(Node);
        n.* = .{ .tag = tag, .parent = parent };
        if (parent) |p| try p.children.append(d.a, n);
        return n;
    }

    pub fn append(d: Dom, parent: *Node, tag: []const u8) Allocator.Error!*Node {
        return d.create(parent, tag);
    }

    pub fn attr(d: Dom, n: *Node, name: []const u8, value_in: []const u8) Allocator.Error!void {
        const value = std.mem.trim(u8, value_in, " \t\r\n");
        for (n.attrs.items) |*x| if (std.mem.eql(u8, x.name, name)) {
            x.value = value;
            return;
        };
        try n.attrs.append(d.a, .{ .name = name, .value = value });
    }

    pub fn attrNum(d: Dom, n: *Node, name: []const u8, v: f64) Allocator.Error!void {
        try d.attr(n, name, try numfmt.js(d.a, v));
    }

    pub fn attrFmt(d: Dom, n: *Node, name: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try d.attr(n, name, try std.fmt.allocPrint(d.a, fmt, args));
    }

    pub fn style(d: Dom, n: *Node, name: []const u8, value_in: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, name, "font-family") and !env.familyValid(value_in)) return;
        var value = value_in;
        if (std.mem.eql(u8, name, "font-family")) value = try env.normFamily(d.a, value_in);
        if (std.mem.eql(u8, name, "stroke") or std.mem.eql(u8, name, "fill")) value = try cssColor(d.a, value);
        for (n.styles.items) |*x| if (std.mem.eql(u8, x.name, name)) {
            x.value = value;
            return;
        };
        try n.styles.append(d.a, .{ .name = name, .value = value });
    }

    pub fn text(d: Dom, n: *Node, s: []const u8) void {
        _ = d;
        n.text = s;
    }

    pub fn lower(n: *Node) void {
        const p = n.parent orelse return;
        const i = std.mem.indexOfScalar(*Node, p.children.items, n).?;
        _ = p.children.orderedRemove(i);
        p.children.insertAssumeCapacity(0, n);
    }

    pub fn serialize(d: Dom, out: *std.ArrayList(u8), n: *const Node) Allocator.Error!void {
        try out.append(d.a, '<');
        try out.appendSlice(d.a, n.tag);
        for (n.attrs.items) |x| {
            try out.append(d.a, ' ');
            try out.appendSlice(d.a, x.name);
            try out.appendSlice(d.a, "=\"");
            try escape(d.a, out, x.value, true);
            try out.append(d.a, '"');
        }
        if (n.styles.items.len > 0) {
            try out.appendSlice(d.a, " style=\"");
            for (n.styles.items, 0..) |x, i| {
                if (i > 0) try out.append(d.a, ' ');
                try out.appendSlice(d.a, x.name);
                try out.appendSlice(d.a, ": ");
                try escape(d.a, out, x.value, true);
                try out.append(d.a, ';');
            }
            try out.append(d.a, '"');
        }
        try out.append(d.a, '>');
        if (n.text) |t| try escape(d.a, out, t, false);
        for (n.children.items) |c| try d.serialize(out, c);
        try out.appendSlice(d.a, "</");
        try out.appendSlice(d.a, n.tag);
        try out.append(d.a, '>');
    }
};

pub fn escape(a: Allocator, out: *std.ArrayList(u8), s: []const u8, in_attr: bool) Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => if (in_attr) try out.appendSlice(a, "&quot;") else try out.append(a, c),
        else => try out.append(a, c),
    };
}

fn parseNums(s: []const u8, out: *[4]f64) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < 4) {
        while (i < s.len and (s[i] == ' ' or s[i] == ',' or s[i] == '/')) i += 1;
        const st = i;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.' or s[i] == '-')) i += 1;
        if (i == st) break;
        out[n] = std.fmt.parseFloat(f64, s[st..i]) catch 0;
        n += 1;
        while (i < s.len and s[i] != ',' and s[i] != ' ' and s[i] != '/') i += 1;
    }
    return n;
}

fn hue(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

/// Chrome's serialisation of a specified colour: #rgb, hsl() and fractional rgb() become rgb(r, g, b).
pub fn cssColor(a: Allocator, v: []const u8) Allocator.Error![]const u8 {
    if (v.len > 0 and v[0] == '#' and (v.len == 4 or v.len == 7)) {
        const h = std.fmt.parseInt(u24, v[1..], 16) catch return v;
        if (v.len == 4) return std.fmt.allocPrint(a, "rgb({d}, {d}, {d})", .{ (h >> 8) * 17, ((h >> 4) & 15) * 17, (h & 15) * 17 });
        return std.fmt.allocPrint(a, "rgb({d}, {d}, {d})", .{ h >> 16, (h >> 8) & 255, h & 255 });
    }
    var nums: [4]f64 = .{ 0, 0, 0, 0 };
    if (std.mem.startsWith(u8, v, "hsl(")) {
        if (parseNums(v[4..], &nums) < 3) return v;
        const h = @mod(nums[0], 360) / 360;
        const s = nums[1] / 100;
        const l = nums[2] / 100;
        const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
        const p = 2 * l - q;
        return std.fmt.allocPrint(a, "rgb({d}, {d}, {d})", .{ chan(hue(p, q, h + 1.0 / 3.0)), chan(hue(p, q, h)), chan(hue(p, q, h - 1.0 / 3.0)) });
    }
    if (std.mem.startsWith(u8, v, "rgb(")) {
        if (parseNums(v[4..], &nums) < 3) return v;
        return std.fmt.allocPrint(a, "rgb({d}, {d}, {d})", .{ @as(u8, @intFromFloat(@min(255, @max(0, @round(nums[0]))))), @as(u8, @intFromFloat(@min(255, @max(0, @round(nums[1]))))), @as(u8, @intFromFloat(@min(255, @max(0, @round(nums[2]))))) });
    }
    return v;
}

fn chan(x: f64) u8 {
    return @intFromFloat(@min(255, @max(0, @round(x * 255))));
}
