const std = @import("std");
const Allocator = std.mem.Allocator;
const env = @import("env.zig");

/// The sequence diagram's part of the flattened stylesheet (styles.js with stylis' scoping and minifying applied).
pub fn css(a: Allocator, id: []const u8, t: env.Theme, neo: bool) Allocator.Error![]const u8 {
    const drop = t.get("dropShadow") orelse "none";
    const sw = t.get("strokeWidth") orelse "1";
    const ab = t.str("actorBorder");
    const abk = t.str("actorBkg");
    const sig = t.str("signalColor");
    const lbb = t.str("labelBoxBorderColor");
    const nbc = t.str("noteBorderColor");
    const nbk = t.str("noteBkgColor");
    const lt = t.str("loopTextColor");
    const ab_ = t.str("activationBkgColor");
    const abo = t.str("activationBorderColor");
    const p = id;
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "#{s} .actor{{stroke:{s};fill:{s};stroke-width:{s};}}", .{ p, ab, abk, sw });
    try o.print(a, "#{s} rect.actor.outer-path[data-look=\"neo\"]{{filter:{s};}}", .{ p, drop });
    try o.print(a, "#{s} rect.note[data-look=\"neo\"]{{stroke:{s};fill:{s};filter:{s};}}", .{ p, nbc, nbk, drop });
    try o.print(a, "#{s} text.actor>tspan{{fill:{s};stroke:none;}}", .{ p, t.str("actorTextColor") });
    try o.print(a, "#{s} .actor-line{{stroke:{s};}}", .{ p, t.str("actorLineColor") });
    try o.print(a, "#{s} .innerArc{{stroke-width:1.5;stroke-dasharray:none;}}", .{p});
    try o.print(a, "#{s} .messageLine0{{stroke-width:1.5;stroke-dasharray:none;stroke:{s};}}", .{ p, sig });
    try o.print(a, "#{s} .messageLine1{{stroke-width:1.5;stroke-dasharray:2,2;stroke:{s};}}", .{ p, sig });
    try o.print(a, "#{s} [id$=\"-arrowhead\"] path{{fill:{s};stroke:{s};}}", .{ p, sig, sig });
    try o.print(a, "#{s} .sequenceNumber{{fill:{s};}}", .{ p, t.str("sequenceNumberColor") });
    try o.print(a, "#{s} [id$=\"-sequencenumber\"]{{fill:{s};}}", .{ p, sig });
    try o.print(a, "#{s} [id$=\"-crosshead\"] path{{fill:{s};stroke:{s};}}", .{ p, sig, sig });
    try o.print(a, "#{s} .messageText{{fill:{s};stroke:none;}}", .{ p, t.str("signalTextColor") });
    try o.print(a, "#{s} .labelBox{{stroke:{s};fill:{s};filter:{s};}}", .{ p, lbb, t.str("labelBoxBkgColor"), if (neo) drop else "none" });
    try o.print(a, "#{s} .labelText,#{s} .labelText>tspan{{fill:{s};stroke:none;}}", .{ p, p, t.str("labelTextColor") });
    try o.print(a, "#{s} .loopText,#{s} .loopText>tspan{{fill:{s};stroke:none;}}", .{ p, p, lt });
    try o.print(a, "#{s} .sectionTitle,#{s} .sectionTitle>tspan{{fill:{s};stroke:none;}}", .{ p, p, lt });
    try o.print(a, "#{s} .loopLine{{stroke-width:2px;stroke-dasharray:2,2;stroke:{s};fill:{s};}}", .{ p, lbb, lbb });
    try o.print(a, "#{s} .note{{stroke:{s};fill:{s};}}", .{ p, nbc, nbk });
    try o.print(a, "#{s} .noteText,#{s} .noteText>tspan{{fill:{s};stroke:none;}}", .{ p, p, t.str("noteTextColor") });
    for ([_][]const u8{ "0", "1", "2" }) |n| try o.print(a, "#{s} .activation{s}{{fill:{s};stroke:{s};}}", .{ p, n, ab_, abo });
    try o.print(a, "#{s} .actorPopupMenu{{position:absolute;}}", .{p});
    try o.print(a, "#{s} .actorPopupMenuPanel{{position:absolute;fill:{s};box-shadow:0px 8px 16px 0px rgba(0,0,0,0.2);filter:drop-shadow(3px 5px 2px rgb(0 0 0 / 0.4));}}", .{ p, abk });
    try o.print(a, "#{s} .actor-man circle,#{s} line{{fill:{s};stroke-width:2px;}}", .{ p, p, abk });
    try o.print(a, "#{s} g rect.rect{{filter:{s};stroke:{s};}}", .{ p, drop, t.str("nodeBorder") });
    return o.items;
}
