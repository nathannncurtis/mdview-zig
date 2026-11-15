const std = @import("std");
const model = @import("model.zig");
const dom = @import("dom.zig");
const util = @import("shapes/util.zig");
const basic = @import("shapes/basic.zig");
const e1 = @import("shapes/ext1.zig");
const e2 = @import("shapes/ext2.zig");
const e3 = @import("shapes/ext3.zig");
const e4 = @import("shapes/ext4.zig");
const e5 = @import("shapes/ext5.zig");
const ic = @import("shapes/icon.zig");
const e6 = @import("shapes/ext6.zig");
const El = dom.El;

pub const Error = util.Error;
pub const Opts = util.Opts;
pub const Handler = util.Handler;

const Def = struct { names: []const []const u8, handler: Handler };

pub const defs = [_]Def{
    .{ .names = &.{ "rect", "proc", "process", "rectangle", "squareRect" }, .handler = basic.squareRect },
    .{ .names = &.{ "rounded", "event", "roundedRect" }, .handler = basic.roundedRect },
    .{ .names = &.{ "stadium", "terminal", "pill" }, .handler = basic.stadium },
    .{ .names = &.{ "fr-rect", "subprocess", "subproc", "framed-rectangle", "subroutine" }, .handler = basic.subroutine },
    .{ .names = &.{ "cyl", "db", "database", "cylinder" }, .handler = basic.cylinder },
    .{ .names = &.{ "circle", "circ" }, .handler = basic.circle },
    .{ .names = &.{ "diam", "decision", "diamond", "question" }, .handler = basic.question },
    .{ .names = &.{ "hex", "hexagon", "prepare" }, .handler = basic.hexagon },
    .{ .names = &.{ "lean-r", "lean-right", "in-out", "lean_right" }, .handler = basic.leanRight },
    .{ .names = &.{ "lean-l", "lean-left", "out-in", "lean_left" }, .handler = basic.leanLeft },
    .{ .names = &.{ "trap-b", "priority", "trapezoid-bottom", "trapezoid" }, .handler = basic.trapezoid },
    .{ .names = &.{ "trap-t", "manual", "trapezoid-top", "inv-trapezoid", "inv_trapezoid" }, .handler = basic.invTrapezoid },
    .{ .names = &.{ "dbl-circ", "double-circle", "doublecircle" }, .handler = basic.doubleCircle },
    .{ .names = &.{"text"}, .handler = basic.text },
    .{ .names = &.{ "sm-circ", "start", "small-circle", "stateStart" }, .handler = basic.stateStart },
    .{ .names = &.{ "fr-circ", "stop", "framed-circle", "stateEnd" }, .handler = basic.stateEnd },
    .{ .names = &.{ "fork", "join", "forkJoin" }, .handler = basic.forkJoin },
    .{ .names = &.{ "odd", "rect_left_inv_arrow" }, .handler = basic.rectLeftInvArrow },
    .{ .names = &.{"choice"}, .handler = basic.choice },
    .{ .names = &.{"note"}, .handler = basic.note },
    .{ .names = &.{"labelRect"}, .handler = basic.labelRect },
    .{ .names = &.{"anchor"}, .handler = basic.anchor },
    .{ .names = &.{ "hourglass", "collate" }, .handler = e1.hourglass },
    .{ .names = &.{ "tri", "extract", "triangle" }, .handler = e1.triangle },
    .{ .names = &.{ "flip-tri", "manual-file", "flipped-triangle" }, .handler = e1.flippedTriangle },
    .{ .names = &.{ "bolt", "com-link", "lightning-bolt" }, .handler = e1.lightningBolt },
    .{ .names = &.{ "delay", "half-rounded-rectangle" }, .handler = e1.halfRoundedRectangle },
    .{ .names = &.{ "win-pane", "internal-storage", "window-pane" }, .handler = e1.windowPane },
    .{ .names = &.{ "f-circ", "junction", "filled-circle" }, .handler = e1.filledCircle },
    .{ .names = &.{ "cross-circ", "summary", "crossed-circle" }, .handler = e1.crossedCircle },
    .{ .names = &.{ "sl-rect", "manual-input", "sloped-rectangle" }, .handler = e2.slopedRect },
    .{ .names = &.{ "notch-rect", "card", "notched-rectangle" }, .handler = e2.card },
    .{ .names = &.{ "notch-pent", "loop-limit", "notched-pentagon" }, .handler = e2.trapezoidalPentagon },
    .{ .names = &.{ "div-rect", "div-proc", "divided-rectangle", "divided-process" }, .handler = e2.dividedRect },
    .{ .names = &.{ "lin-rect", "lined-rectangle", "lined-process", "lin-proc", "shaded-process" }, .handler = e2.shadedProcess },
    .{ .names = &.{ "tag-rect", "tagged-rectangle", "tag-proc", "tagged-process" }, .handler = e2.taggedRect },
    .{ .names = &.{ "st-rect", "procs", "processes", "stacked-rectangle" }, .handler = e2.multiRect },
    .{ .names = &.{ "bow-rect", "stored-data", "bow-tie-rectangle" }, .handler = e2.bowTieRect },
    .{ .names = &.{ "curv-trap", "curved-trapezoid", "display" }, .handler = e2.curvedTrapezoid },
    .{ .names = &.{ "lin-cyl", "disk", "lined-cylinder" }, .handler = e3.linedCylinder },
    .{ .names = &.{ "h-cyl", "das", "horizontal-cylinder" }, .handler = e3.tiltedCylinder },
    .{ .names = &.{ "datastore", "data-store" }, .handler = e3.datastore },
    .{ .names = &.{"cloud"}, .handler = e3.cloud },
    .{ .names = &.{"bang"}, .handler = e3.bang },
    .{ .names = &.{ "doc", "document" }, .handler = e4.waveEdgedRectangle },
    .{ .names = &.{ "flag", "paper-tape" }, .handler = e4.waveRectangle },
    .{ .names = &.{ "lin-doc", "lined-document" }, .handler = e4.linedWaveEdgedRect },
    .{ .names = &.{ "docs", "documents", "st-doc", "stacked-document" }, .handler = e4.multiWaveEdgedRectangle },
    .{ .names = &.{ "tag-doc", "tagged-document" }, .handler = e4.taggedWaveEdgedRectangle },
    .{ .names = &.{ "brace", "comment", "brace-l" }, .handler = e5.curlyBraceLeft },
    .{ .names = &.{"brace-r"}, .handler = e5.curlyBraceRight },
    .{ .names = &.{"braces"}, .handler = e5.curlyBraces },
    .{ .names = &.{"iconSquare"}, .handler = ic.iconSquare },
    .{ .names = &.{"iconCircle"}, .handler = ic.iconCircle },
    .{ .names = &.{"icon"}, .handler = ic.icon },
    .{ .names = &.{"iconRounded"}, .handler = ic.iconRounded },
    .{ .names = &.{"imageSquare"}, .handler = ic.imageSquare },
    .{ .names = &.{ "folder", "directory" }, .handler = e6.folder },
    .{ .names = &.{"collapsedGroup"}, .handler = e6.collapsedGroup },
    .{ .names = &.{"bucket"}, .handler = e6.bucket },
    .{ .names = &.{"console"}, .handler = e6.consoleWindow },
    .{ .names = &.{"browser"}, .handler = e6.browser },
    .{ .names = &.{"person"}, .handler = e6.person },
};

pub fn lookup(name: []const u8) ?Handler {
    inline for (defs) |d| {
        inline for (d.names) |n| if (std.mem.eql(u8, n, name)) return d.handler;
    }
    return null;
}

pub fn errorMessage(a: std.mem.Allocator, shape: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "No such shape: {s}. Please check your syntax.", .{shape});
}

pub fn insert(ctx: *const model.Ctx, parent: *El, node: *model.NodeData, opts: Opts) Error!*El {
    if (std.mem.eql(u8, node.shape, "rect")) {
        node.shape = if (node.rx != null and node.ry != null and node.rx.? != 0 and node.ry.? != 0) "roundedRect" else "squareRect";
    }
    const h = lookup(node.shape) orelse return error.NoSuchShape;
    var new_el: *El = parent;
    var el: *El = parent;
    if (node.link) |link| {
        new_el = try parent.insert("a");
        try new_el.setAttr("xlink:href", link);
        if (node.link_target) |t| try new_el.setAttr("target", t);
        el = try h(ctx, new_el, node, opts);
    } else {
        el = try h(ctx, parent, node, opts);
        new_el = el;
    }
    if (node.tooltip) |t| try el.setAttr("title", t);
    node.el = new_el;
    if (node.have_callback) {
        const cls = new_el.getAttr("class") orelse "";
        try new_el.setAttr("class", try std.fmt.allocPrint(ctx.a, "{s} clickable", .{cls}));
    }
    return new_el;
}

test {
    _ = basic;
    _ = @import("shapes_test.zig");
}
