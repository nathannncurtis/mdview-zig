const std = @import("std");
const diagram = @import("../diagram.zig");
const vars_mod = @import("../theme/vars.zig");
const env = @import("env.zig");
const seq = @import("sequence.zig");

const ThemeCtx = struct {
    a: std.mem.Allocator,
    vars: *const vars_mod.Vars,

    fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const ThemeCtx = @ptrCast(@alignCast(ctx));
        return (self.vars.get(name).text(self.a) catch return null);
    }
};

fn unused() noreturn {
    unreachable;
}

fn parseStub(_: *diagram.Ctx, _: []const u8) diagram.Error!*anyopaque {
    unused();
}

fn layoutStub(_: *diagram.Ctx, _: *anyopaque) diagram.Error!*anyopaque {
    unused();
}

fn emitStub(_: *diagram.Ctx, _: *anyopaque, _: *anyopaque, _: *@import("../svg.zig").SvgWriter) diagram.Error!void {
    unused();
}

/// Renders the whole document; the sequence port builds its own root element.
fn whole(ctx: *diagram.Ctx, source: []const u8, base_css: []const u8) diagram.Error!diagram.Whole {
    const a = ctx.a;
    var conf: env.Conf = .{};
    try conf.applyJson(a, ctx.cfg.root);
    const tctx = try a.create(ThemeCtx);
    tctx.* = .{ .a = a, .vars = &ctx.cfg.vars };
    const res = try seq.render(a, source, .{
        .id = ctx.svg_id,
        .conf = conf,
        .theme = .{ .ctx = tctx, .getFn = ThemeCtx.get },
        .measurer = ctx.measurer,
        .title = ctx.title,
        .deadline = ctx.deadline,
        .base_css = base_css,
    });
    return switch (res) {
        .ok => |o| .{ .bytes = o.svg, .w = @floatCast(o.width), .h = @floatCast(o.height) },
        .err => |m| ctx.fail("{s}", .{m}),
    };
}

pub const def: diagram.Def = .{ .id = "sequence", .parse = parseStub, .layout = layoutStub, .emit = emitStub, .whole = whole };
