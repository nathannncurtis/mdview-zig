const font = @import("font");

pub const Style = enum(u3) {
    d = 0,
    dc = 1,
    t = 2,
    tc = 3,
    s = 4,
    sc = 5,
    ss = 6,
    ssc = 7,

    pub fn cramped(s: Style) bool {
        return @intFromEnum(s) & 1 == 1;
    }

    pub fn cramp(s: Style) Style {
        return @enumFromInt(@intFromEnum(s) | 1);
    }

    pub fn uncramp(s: Style) Style {
        return @enumFromInt(@intFromEnum(s) & 6);
    }

    pub fn display(s: Style) bool {
        return @intFromEnum(s) < 2;
    }

    pub fn level(s: Style) u2 {
        return switch (@intFromEnum(s) >> 1) {
            0, 1 => 0,
            2 => 1,
            else => 2,
        };
    }

    pub fn script(s: Style) bool {
        return @intFromEnum(s) >= 4;
    }

    pub fn sup(s: Style) Style {
        const base: u3 = switch (s.level()) {
            0 => 4,
            else => 6,
        };
        return @enumFromInt(base | (@intFromEnum(s) & 1));
    }

    pub fn sub(s: Style) Style {
        return s.sup().cramp();
    }

    pub fn num(s: Style) Style {
        return switch (s.uncramp()) {
            .d => .t,
            .t => .s,
            else => .ss,
        };
    }

    pub fn den(s: Style) Style {
        return s.num().cramp();
    }

    pub fn text(s: Style) Style {
        return if (s.script()) s else (if (s.cramped()) Style.tc else Style.t);
    }

    pub fn scale(s: Style, c: font.math.Constants) f32 {
        return switch (s.level()) {
            0 => 1,
            1 => @as(f32, @floatFromInt(c.script_percent_scale_down)) / 100,
            else => @as(f32, @floatFromInt(c.script_script_percent_scale_down)) / 100,
        };
    }
};

const testing = @import("std").testing;

test "style transitions" {
    try testing.expectEqual(Style.s, Style.d.sup());
    try testing.expectEqual(Style.sc, Style.dc.sup());
    try testing.expectEqual(Style.ss, Style.s.sup());
    try testing.expectEqual(Style.sc, Style.t.sub());
    try testing.expectEqual(Style.t, Style.d.num());
    try testing.expectEqual(Style.tc, Style.d.den());
    try testing.expectEqual(Style.sc, Style.t.den());
    try testing.expectEqual(Style.ssc, Style.s.den());
    try testing.expectEqual(Style.ssc, Style.ss.sub());
}
