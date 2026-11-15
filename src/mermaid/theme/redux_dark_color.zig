// Generated from mermaid@12.2.0 packages/mermaid/src/themes by a one-off port; hand edits are fine.
const vars = @import("vars.zig");
const c = @import("color.zig");
const Vars = vars.Vars;
const V = vars.V;
const std = @import("std");

pub fn init(t: *Vars) vars.Err!void {
    try t.set("background", V{ .s = "#333" });
    try t.set("primaryColor", V{ .s = "#1f2020" });
    try t.set("secondaryColor", try c.lighten(t, t.get("primaryColor"), 16));
    try t.set("tertiaryColor", try c.adjust(t, t.get("primaryColor"), .{ .h = -160 }));
    try t.set("primaryBorderColor", try c.invert(t, t.get("background")));
    try t.set("secondaryBorderColor", try c.mkBorder(t, t.get("secondaryColor"), t.get("darkMode")));
    try t.set("tertiaryBorderColor", try c.mkBorder(t, t.get("tertiaryColor"), t.get("darkMode")));
    try t.set("primaryTextColor", try c.invert(t, t.get("primaryColor")));
    try t.set("secondaryTextColor", try c.invert(t, t.get("secondaryColor")));
    try t.set("tertiaryTextColor", try c.invert(t, t.get("tertiaryColor")));
    try t.set("mainBkg", V{ .s = "#111113" });
    try t.set("secondBkg", V{ .s = "calculated" });
    try t.set("mainContrastColor", V{ .s = "lightgrey" });
    try t.set("darkTextColor", try c.lighten(t, try c.invert(t, V{ .s = "#323D47" }), 10));
    try t.set("border1", V{ .s = "#ccc" });
    try t.set("border2", try c.rgba(t, 255, 255, 255, 0.25));
    try t.set("arrowheadColor", try c.invert(t, t.get("background")));
    try t.set("fontFamily", V{ .s = "\"Recursive Variable\", arial, sans-serif" });
    try t.set("fontSize", V{ .s = "14px" });
    try t.set("labelBackground", V{ .s = "#111113" });
    try t.set("textColor", V{ .s = "#ccc" });
    try t.set("THEME_COLOR_LIMIT", V{ .n = 12 });
    try t.set("radius", V{ .n = 12 });
    try t.set("strokeWidth", V{ .n = 2 });
    try t.set("noteBkgColor", blk_x0: {
        const x0 = t.get("noteBkgColor");
        if (x0 != .undef) break :blk_x0 x0;
        break :blk_x0 V{ .s = "#FEF9C3" };
    });
    try t.set("noteTextColor", blk_x1: {
        const x1 = t.get("noteTextColor");
        if (x1 != .undef) break :blk_x1 x1;
        break :blk_x1 V{ .s = "#28253D" };
    });
    try t.set("THEME_COLOR_LIMIT", V{ .n = 12 });
    try t.set("fontFamily", V{ .s = "\"Recursive Variable\", arial, sans-serif" });
    try t.set("fontSize", V{ .s = "14px" });
    try t.set("nodeBorder", V{ .s = "#FFFFFF" });
    try t.set("stateBorder", V{ .s = "#FFFFFF" });
    try t.set("useGradient", V{ .b = false });
    try t.set("gradientStart", V{ .s = "#0042eb" });
    try t.set("gradientStop", V{ .s = "#eb0042" });
    try t.set("dropShadow", V{ .s = "url(#drop-shadow)" });
    try t.set("nodeShadow", V{ .b = true });
    try t.set("archEdgeColor", V{ .s = "calculated" });
    try t.set("archEdgeArrowColor", V{ .s = "calculated" });
    try t.set("archEdgeWidth", V{ .s = "3" });
    try t.set("archGroupBorderColor", t.get("primaryBorderColor"));
    try t.set("archGroupBorderWidth", V{ .s = "2px" });
    try t.set("clusterBkg", V{ .s = "#1E1A2E" });
    try t.set("clusterBorder", V{ .s = "#BDBCCC" });
    try t.set("noteBorderColor", V{ .s = "#FACC15" });
    try t.set("noteFontWeight", V{ .n = 600 });
    try t.set("borderColorArray.0", V{ .s = "#E879F9" });
    try t.set("borderColorArray.1", V{ .s = "#2DD4BF" });
    try t.set("borderColorArray.2", V{ .s = "#FB923C" });
    try t.set("borderColorArray.3", V{ .s = "#22D3EE" });
    try t.set("borderColorArray.4", V{ .s = "#4ADE80" });
    try t.set("borderColorArray.5", V{ .s = "#A78BFA" });
    try t.set("borderColorArray.6", V{ .s = "#F87171" });
    try t.set("borderColorArray.7", V{ .s = "#FACC15" });
    try t.set("borderColorArray.8", V{ .s = "#818CF8" });
    try t.set("borderColorArray.9", V{ .s = "#A3E635 " });
    try t.set("borderColorArray.10", V{ .s = "#38BDF8" });
    try t.set("borderColorArray.11", V{ .s = "#FB7185" });
    try t.set("usecaseActorBorder", V{ .s = "#A78BFA" });
    try t.set("usecaseBorder", V{ .s = "#2DD4BF" });
    try t.set("usecaseBoundaryBorder", V{ .s = "#BDBCCC" });
    try t.set("usecaseIncludeLine", V{ .s = "#38BDF8" });
    try t.set("usecaseExtendLine", V{ .s = "#FB923C" });
    try t.set("filterColor", V{ .s = "#FFFFFF" });
}

pub fn updateColors(t: *Vars) vars.Err!void {
    if (!t.get("primaryTextColor").truthy()) try t.set("primaryTextColor", if ((t.get("darkMode")).truthy()) V{ .s = "#eee" } else V{ .s = "#FFFFFF" });
    if (!t.get("secondaryColor").truthy()) try t.set("secondaryColor", try c.adjust(t, t.get("primaryColor"), .{ .h = -120 }));
    if (!t.get("tertiaryColor").truthy()) try t.set("tertiaryColor", try c.adjust(t, t.get("primaryColor"), .{ .h = 180, .l = 5 }));
    if (!t.get("primaryBorderColor").truthy()) try t.set("primaryBorderColor", try c.mkBorder(t, t.get("primaryColor"), t.get("darkMode")));
    if (!t.get("secondaryBorderColor").truthy()) try t.set("secondaryBorderColor", try c.mkBorder(t, t.get("secondaryColor"), t.get("darkMode")));
    if (!t.get("tertiaryBorderColor").truthy()) try t.set("tertiaryBorderColor", try c.mkBorder(t, t.get("tertiaryColor"), t.get("darkMode")));
    if (!t.get("noteBorderColor").truthy()) try t.set("noteBorderColor", try c.mkBorder(t, t.get("noteBkgColor"), t.get("darkMode")));
    if (!t.get("noteBkgColor").truthy()) try t.set("noteBkgColor", V{ .s = "#fff5ad" });
    if (!t.get("noteTextColor").truthy()) try t.set("noteTextColor", V{ .s = "#FFFFFF" });
    if (!t.get("secondaryTextColor").truthy()) try t.set("secondaryTextColor", try c.invert(t, t.get("secondaryColor")));
    if (!t.get("tertiaryTextColor").truthy()) try t.set("tertiaryTextColor", try c.invert(t, t.get("tertiaryColor")));
    if (!t.get("lineColor").truthy()) try t.set("lineColor", try c.invert(t, t.get("background")));
    if (!t.get("arrowheadColor").truthy()) try t.set("arrowheadColor", try c.invert(t, t.get("background")));
    if (!t.get("textColor").truthy()) try t.set("textColor", t.get("primaryTextColor"));
    if (!t.get("border2").truthy()) try t.set("border2", t.get("tertiaryBorderColor"));
    if (!t.get("nodeBkg").truthy()) try t.set("nodeBkg", t.get("primaryColor"));
    if (!t.get("mainBkg").truthy()) try t.set("mainBkg", t.get("primaryColor"));
    try t.set("secondBkg", if ((V{ .b = (t.get("secondBkg")).eql(V{ .s = "calculated" }) }).truthy()) try c.lighten(t, t.get("mainBkg"), 16) else t.get("secondBkg"));
    if (!t.get("nodeBorder").truthy()) try t.set("nodeBorder", t.get("border1"));
    if (!t.get("clusterBkg").truthy()) try t.set("clusterBkg", t.get("tertiaryColor"));
    if (!t.get("clusterBorder").truthy()) try t.set("clusterBorder", t.get("tertiaryBorderColor"));
    if (!t.get("defaultLinkColor").truthy()) try t.set("defaultLinkColor", t.get("lineColor"));
    if (!t.get("titleColor").truthy()) try t.set("titleColor", t.get("tertiaryTextColor"));
    if (!t.get("edgeLabelBackground").truthy()) try t.set("edgeLabelBackground", if ((t.get("darkMode")).truthy()) try c.darken(t, t.get("secondaryColor"), 30) else t.get("secondaryColor"));
    if (!t.get("nodeTextColor").truthy()) try t.set("nodeTextColor", t.get("primaryTextColor"));
    if (!t.get("flowContainerStroke").truthy()) try t.set("flowContainerStroke", t.get("secondaryBorderColor"));
    try t.set("actorBorder", V{ .s = "#FFFFFF" });
    try t.set("signalColor", V{ .s = "#FFFFFF" });
    try t.set("labelBoxBorderColor", V{ .s = "#BDBCCC" });
    if (!t.get("actorBorder").truthy()) try t.set("actorBorder", t.get("primaryBorderColor"));
    if (!t.get("actorBkg").truthy()) try t.set("actorBkg", t.get("mainBkg"));
    if (!t.get("actorTextColor").truthy()) try t.set("actorTextColor", t.get("primaryTextColor"));
    if (!t.get("actorLineColor").truthy()) try t.set("actorLineColor", t.get("actorBorder"));
    if (!t.get("labelBoxBkgColor").truthy()) try t.set("labelBoxBkgColor", t.get("actorBkg"));
    if (!t.get("signalColor").truthy()) try t.set("signalColor", t.get("textColor"));
    if (!t.get("signalTextColor").truthy()) try t.set("signalTextColor", t.get("textColor"));
    if (!t.get("labelBoxBorderColor").truthy()) try t.set("labelBoxBorderColor", t.get("actorBorder"));
    if (!t.get("labelTextColor").truthy()) try t.set("labelTextColor", t.get("actorTextColor"));
    if (!t.get("loopTextColor").truthy()) try t.set("loopTextColor", t.get("actorTextColor"));
    if (!t.get("activationBorderColor").truthy()) try t.set("activationBorderColor", try c.darken(t, t.get("secondaryColor"), 10));
    if (!t.get("activationBkgColor").truthy()) try t.set("activationBkgColor", t.get("secondaryColor"));
    if (!t.get("sequenceNumberColor").truthy()) try t.set("sequenceNumberColor", try c.invert(t, t.get("lineColor")));
    if (!t.get("rectBkgColor").truthy()) try t.set("rectBkgColor", t.get("tertiaryColor"));
    try t.set("rootLabelColor", V{ .s = "#FFFFFF" });
    if (!t.get("excludeBkgColor").truthy()) try t.set("excludeBkgColor", V{ .s = "#eeeeee" });
    if (!t.get("taskBorderColor").truthy()) try t.set("taskBorderColor", t.get("primaryBorderColor"));
    if (!t.get("taskBkgColor").truthy()) try t.set("taskBkgColor", t.get("primaryColor"));
    if (!t.get("activeTaskBorderColor").truthy()) try t.set("activeTaskBorderColor", t.get("primaryColor"));
    if (!t.get("activeTaskBkgColor").truthy()) try t.set("activeTaskBkgColor", try c.lighten(t, t.get("primaryColor"), 23));
    if (!t.get("gridColor").truthy()) try t.set("gridColor", V{ .s = "lightgrey" });
    if (!t.get("doneTaskBkgColor").truthy()) try t.set("doneTaskBkgColor", t.get("secondBkg"));
    if (!t.get("doneTaskBorderColor").truthy()) try t.set("doneTaskBorderColor", V{ .s = "grey" });
    if (!t.get("critBorderColor").truthy()) try t.set("critBorderColor", V{ .s = "#ff8888" });
    if (!t.get("critBkgColor").truthy()) try t.set("critBkgColor", V{ .s = "red" });
    if (!t.get("todayLineColor").truthy()) try t.set("todayLineColor", V{ .s = "red" });
    if (!t.get("taskTextColor").truthy()) try t.set("taskTextColor", t.get("textColor"));
    if (!t.get("vertLineColor").truthy()) try t.set("vertLineColor", t.get("primaryBorderColor"));
    if (!t.get("taskTextOutsideColor").truthy()) try t.set("taskTextOutsideColor", t.get("textColor"));
    if (!t.get("taskTextLightColor").truthy()) try t.set("taskTextLightColor", t.get("textColor"));
    if (!t.get("taskTextColor").truthy()) try t.set("taskTextColor", t.get("primaryTextColor"));
    if (!t.get("taskTextDarkColor").truthy()) try t.set("taskTextDarkColor", t.get("textColor"));
    if (!t.get("taskTextClickableColor").truthy()) try t.set("taskTextClickableColor", V{ .s = "#003163" });
    try t.set("archEdgeColor", t.get("lineColor"));
    try t.set("archEdgeArrowColor", t.get("lineColor"));
    if (!t.get("personBorder").truthy()) try t.set("personBorder", t.get("primaryBorderColor"));
    if (!t.get("personBkg").truthy()) try t.set("personBkg", t.get("mainBkg"));
    if (!t.get("transitionColor").truthy()) try t.set("transitionColor", t.get("lineColor"));
    if (!t.get("transitionLabelColor").truthy()) try t.set("transitionLabelColor", t.get("textColor"));
    try t.set("stateLabelColor", blk_x2: {
        const x2 = blk_x3: {
            const x3 = t.get("stateLabelColor");
            if (x3.truthy()) break :blk_x3 x3;
            break :blk_x3 t.get("stateBkg");
        };
        if (x2.truthy()) break :blk_x2 x2;
        break :blk_x2 t.get("primaryTextColor");
    });
    if (!t.get("stateEdgeLabelBackground").truthy()) try t.set("stateEdgeLabelBackground", V{ .s = "#16141F" });
    if (!t.get("stateBkg").truthy()) try t.set("stateBkg", t.get("mainBkg"));
    if (!t.get("labelBackgroundColor").truthy()) try t.set("labelBackgroundColor", t.get("stateBkg"));
    if (!t.get("compositeBackground").truthy()) try t.set("compositeBackground", V{ .s = "#16141F" });
    if (!t.get("altBackground").truthy()) try t.set("altBackground", V{ .s = "#16141F" });
    if (!t.get("compositeTitleBackground").truthy()) try t.set("compositeTitleBackground", V{ .s = "#16141F" });
    if (!t.get("compositeBorder").truthy()) try t.set("compositeBorder", t.get("nodeBorder"));
    try t.set("innerEndBackground", t.get("nodeBorder"));
    if (!t.get("errorBkgColor").truthy()) try t.set("errorBkgColor", t.get("tertiaryColor"));
    if (!t.get("errorTextColor").truthy()) try t.set("errorTextColor", t.get("tertiaryTextColor"));
    if (!t.get("transitionColor").truthy()) try t.set("transitionColor", t.get("lineColor"));
    try t.set("specialStateColor", t.get("lineColor"));
    if (!t.get("cScale0").truthy()) try t.set("cScale0", V{ .s = "#f4a8ff" });
    if (!t.get("cScale1").truthy()) try t.set("cScale1", V{ .s = "#46ecd5" });
    if (!t.get("cScale2").truthy()) try t.set("cScale2", V{ .s = "#ffb86a" });
    if (!t.get("cScale3").truthy()) try t.set("cScale3", V{ .s = "#dab2ff" });
    if (!t.get("cScale4").truthy()) try t.set("cScale4", V{ .s = "#7bf1a8" });
    if (!t.get("cScale5").truthy()) try t.set("cScale5", V{ .s = "#c4b4ff" });
    if (!t.get("cScale6").truthy()) try t.set("cScale6", V{ .s = "#ffa2a2" });
    if (!t.get("cScale7").truthy()) try t.set("cScale7", V{ .s = "#ffdf20" });
    if (!t.get("cScale8").truthy()) try t.set("cScale8", V{ .s = "#a3b3ff" });
    if (!t.get("cScale9").truthy()) try t.set("cScale9", V{ .s = "#bbf451" });
    if (!t.get("cScale10").truthy()) try t.set("cScale10", V{ .s = "#74d4ff" });
    if (!t.get("cScale11").truthy()) try t.set("cScale11", V{ .s = "#ffa1ad" });
    if (!t.get("sectionBkgColor").truthy()) try t.set("sectionBkgColor", t.get("cScale0"));
    if (!t.get("sectionBkgColor2").truthy()) try t.set("sectionBkgColor2", t.get("cScale1"));
    if (!t.get("altSectionBkgColor").truthy()) try t.set("altSectionBkgColor", t.get("background"));
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            {
                const key = try t.key("cScaleInv", i);
                if (!t.get(key).truthy()) try t.set(key, try c.invert(t, t.get(try t.key("cScale", i))));
            }
        }
    }
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            if ((t.get("darkMode")).truthy()) {
                {
                    const key = try t.key("cScalePeer", i);
                    if (!t.get(key).truthy()) try t.set(key, try c.lighten(t, t.get(try t.key("cScale", i)), 10));
                }
            } else {
                {
                    const key = try t.key("cScalePeer", i);
                    if (!t.get(key).truthy()) try t.set(key, try c.darken(t, t.get(try t.key("cScale", i)), 10));
                }
            }
        }
    }
    if (!t.get("scaleLabelColor").truthy()) try t.set("scaleLabelColor", t.get("labelTextColor"));
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            try t.set(try t.key("cScaleLabel", i), try c.darken(t, t.get(try t.key("cScale", i)), 75));
        }
    }
    const multiplier: f64 = (if ((t.get("darkMode")).truthy()) -4 else -1);
    {
        var i: f64 = 0;
        while (i < 5) : (i += 1) {
            {
                const key = try t.key("surface", i);
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get("mainBkg"), .{ .h = 180, .s = -15, .l = (multiplier * (5 + (i * 3))) }));
            }
            {
                const key = try t.key("surfacePeer", i);
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get("mainBkg"), .{ .h = 180, .s = -15, .l = (multiplier * (8 + (i * 3))) }));
            }
        }
    }
    if (!t.get("classText").truthy()) try t.set("classText", t.get("textColor"));
    const journeyFills = [_][]const u8{ "#701a75", "#134e4a", "#7c2d12", "#581c87", "#14532d", "#4c1d95", "#7f1d1d", "#713f12" };
    for (journeyFills, 0..) |fill_item, i_idx| {
        const fill: V = V{ .s = fill_item };
        const i: f64 = @floatFromInt(i_idx);
        {
            const key = try t.key("fillType", i);
            if (!t.get(key).truthy()) try t.set(key, fill);
        }
    }
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            {
                const key = try t.key("pie", (i + 1));
                if (!t.get(key).truthy()) try t.set(key, t.get(try t.key("cScale", i)));
            }
        }
    }
    if (!t.get("pieTitleTextSize").truthy()) try t.set("pieTitleTextSize", V{ .s = "25px" });
    if (!t.get("pieTitleTextColor").truthy()) try t.set("pieTitleTextColor", t.get("taskTextDarkColor"));
    if (!t.get("pieSectionTextSize").truthy()) try t.set("pieSectionTextSize", V{ .s = "17px" });
    if (!t.get("pieSectionTextColor").truthy()) try t.set("pieSectionTextColor", V{ .s = "#28253D" });
    if (!t.get("pieLegendTextSize").truthy()) try t.set("pieLegendTextSize", V{ .s = "17px" });
    if (!t.get("pieLegendTextColor").truthy()) try t.set("pieLegendTextColor", t.get("taskTextDarkColor"));
    if (!t.get("pieStrokeColor").truthy()) try t.set("pieStrokeColor", V{ .s = "black" });
    if (!t.get("pieStrokeWidth").truthy()) try t.set("pieStrokeWidth", V{ .s = "2px" });
    if (!t.get("pieOuterStrokeWidth").truthy()) try t.set("pieOuterStrokeWidth", V{ .s = "2px" });
    if (!t.get("pieOuterStrokeColor").truthy()) try t.set("pieOuterStrokeColor", V{ .s = "black" });
    if (!t.get("pieOpacity").truthy()) try t.set("pieOpacity", V{ .s = "0.7" });
    {
        var i: f64 = 0;
        while (i < 8) : (i += 1) {
            try t.set(try t.key("venn", (i + 1)), blk_x4: {
                const x4 = t.get(try t.key("venn", (i + 1)));
                if (x4 != .undef) break :blk_x4 x4;
                break :blk_x4 t.get(try t.key("borderColorArray.", @rem(i, t.len("borderColorArray"))));
            });
        }
    }
    try t.set("vennTitleTextColor", blk_x5: {
        const x5 = t.get("vennTitleTextColor");
        if (x5 != .undef) break :blk_x5 x5;
        break :blk_x5 t.get("titleColor");
    });
    try t.set("vennSetTextColor", blk_x6: {
        const x6 = t.get("vennSetTextColor");
        if (x6 != .undef) break :blk_x6 x6;
        break :blk_x6 t.get("textColor");
    });
    if (!t.get("quadrant1Fill").truthy()) try t.set("quadrant1Fill", t.get("primaryColor"));
    if (!t.get("quadrant2Fill").truthy()) try t.set("quadrant2Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 5, .g = 5, .b = 5 }));
    if (!t.get("quadrant3Fill").truthy()) try t.set("quadrant3Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 10, .g = 10, .b = 10 }));
    if (!t.get("quadrant4Fill").truthy()) try t.set("quadrant4Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 15, .g = 15, .b = 15 }));
    if (!t.get("quadrant1TextFill").truthy()) try t.set("quadrant1TextFill", t.get("primaryTextColor"));
    if (!t.get("quadrant2TextFill").truthy()) try t.set("quadrant2TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -5, .g = -5, .b = -5 }));
    if (!t.get("quadrant3TextFill").truthy()) try t.set("quadrant3TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -10, .g = -10, .b = -10 }));
    if (!t.get("quadrant4TextFill").truthy()) try t.set("quadrant4TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -15, .g = -15, .b = -15 }));
    try t.set("quadrantPointFill", if ((blk_x7: {
        const x7 = t.get("quadrantPointFill");
        if (x7.truthy()) break :blk_x7 x7;
        break :blk_x7 V{ .b = try c.isDark(t.get("quadrant1Fill")) };
    }).truthy()) try c.lighten(t, t.get("quadrant1Fill"), std.math.nan(f64)) else try c.darken(t, t.get("quadrant1Fill"), std.math.nan(f64)));
    if (!t.get("quadrantPointTextFill").truthy()) try t.set("quadrantPointTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantXAxisTextFill").truthy()) try t.set("quadrantXAxisTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantYAxisTextFill").truthy()) try t.set("quadrantYAxisTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantInternalBorderStrokeFill").truthy()) try t.set("quadrantInternalBorderStrokeFill", t.get("primaryBorderColor"));
    if (!t.get("quadrantExternalBorderStrokeFill").truthy()) try t.set("quadrantExternalBorderStrokeFill", t.get("primaryBorderColor"));
    if (!t.get("quadrantTitleFill").truthy()) try t.set("quadrantTitleFill", t.get("primaryTextColor"));
    try t.set("xyChart.backgroundColor", blk_x8: {
        const x8 = t.get("xyChart.backgroundColor");
        if (x8.truthy()) break :blk_x8 x8;
        break :blk_x8 t.get("background");
    });
    try t.set("xyChart.titleColor", blk_x9: {
        const x9 = t.get("xyChart.titleColor");
        if (x9.truthy()) break :blk_x9 x9;
        break :blk_x9 t.get("primaryTextColor");
    });
    try t.set("xyChart.legendTextColor", blk_x10: {
        const x10 = t.get("xyChart.legendTextColor");
        if (x10.truthy()) break :blk_x10 x10;
        break :blk_x10 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisTitleColor", blk_x11: {
        const x11 = t.get("xyChart.xAxisTitleColor");
        if (x11.truthy()) break :blk_x11 x11;
        break :blk_x11 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisLabelColor", blk_x12: {
        const x12 = t.get("xyChart.xAxisLabelColor");
        if (x12.truthy()) break :blk_x12 x12;
        break :blk_x12 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisTickColor", blk_x13: {
        const x13 = t.get("xyChart.xAxisTickColor");
        if (x13.truthy()) break :blk_x13 x13;
        break :blk_x13 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisLineColor", blk_x14: {
        const x14 = t.get("xyChart.xAxisLineColor");
        if (x14.truthy()) break :blk_x14 x14;
        break :blk_x14 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisTitleColor", blk_x15: {
        const x15 = t.get("xyChart.yAxisTitleColor");
        if (x15.truthy()) break :blk_x15 x15;
        break :blk_x15 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisLabelColor", blk_x16: {
        const x16 = t.get("xyChart.yAxisLabelColor");
        if (x16.truthy()) break :blk_x16 x16;
        break :blk_x16 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisTickColor", blk_x17: {
        const x17 = t.get("xyChart.yAxisTickColor");
        if (x17.truthy()) break :blk_x17 x17;
        break :blk_x17 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisLineColor", blk_x18: {
        const x18 = t.get("xyChart.yAxisLineColor");
        if (x18.truthy()) break :blk_x18 x18;
        break :blk_x18 t.get("primaryTextColor");
    });
    try t.set("xyChart.plotColorPalette", blk_x19: {
        const x19 = t.get("xyChart.plotColorPalette");
        if (x19.truthy()) break :blk_x19 x19;
        break :blk_x19 V{ .s = "#FFF4DD,#FFD8B1,#FFA07A,#ECEFF1,#D6DBDF,#C3E0A8,#FFB6A4,#FFD74D,#738FA7,#FFFFF0" };
    });
    if (!t.get("requirementBackground").truthy()) try t.set("requirementBackground", t.get("primaryColor"));
    if (!t.get("requirementBorderColor").truthy()) try t.set("requirementBorderColor", t.get("primaryBorderColor"));
    if (!t.get("requirementBorderSize").truthy()) try t.set("requirementBorderSize", V{ .s = "1" });
    if (!t.get("requirementTextColor").truthy()) try t.set("requirementTextColor", t.get("primaryTextColor"));
    if (!t.get("relationColor").truthy()) try t.set("relationColor", t.get("lineColor"));
    if (!t.get("relationLabelBackground").truthy()) try t.set("relationLabelBackground", if ((t.get("darkMode")).truthy()) try c.darken(t, t.get("secondaryColor"), 30) else t.get("secondaryColor"));
    if (!t.get("relationLabelColor").truthy()) try t.set("relationLabelColor", t.get("actorTextColor"));
    try t.set("requirementEdgeLabelBackground", V{ .s = "#16141F" });
    if (!t.get("git0").truthy()) try t.set("git0", t.get("primaryColor"));
    if (!t.get("git1").truthy()) try t.set("git1", t.get("secondaryColor"));
    if (!t.get("git2").truthy()) try t.set("git2", t.get("tertiaryColor"));
    if (!t.get("git3").truthy()) try t.set("git3", try c.adjust(t, t.get("primaryColor"), .{ .h = -30 }));
    if (!t.get("git4").truthy()) try t.set("git4", try c.adjust(t, t.get("primaryColor"), .{ .h = -60 }));
    if (!t.get("git5").truthy()) try t.set("git5", try c.adjust(t, t.get("primaryColor"), .{ .h = -90 }));
    if (!t.get("git6").truthy()) try t.set("git6", try c.adjust(t, t.get("primaryColor"), .{ .h = 60 }));
    if (!t.get("git7").truthy()) try t.set("git7", try c.adjust(t, t.get("primaryColor"), .{ .h = 120 }));
    if ((t.get("darkMode")).truthy()) {
        try t.set("git0", try c.lighten(t, t.get("git0"), 25));
        try t.set("git1", try c.lighten(t, t.get("git1"), 25));
        try t.set("git2", try c.lighten(t, t.get("git2"), 25));
        try t.set("git3", try c.lighten(t, t.get("git3"), 25));
        try t.set("git4", try c.lighten(t, t.get("git4"), 25));
        try t.set("git5", try c.lighten(t, t.get("git5"), 25));
        try t.set("git6", try c.lighten(t, t.get("git6"), 25));
        try t.set("git7", try c.lighten(t, t.get("git7"), 25));
    } else {
        try t.set("git0", try c.darken(t, t.get("git0"), 25));
        try t.set("git1", try c.darken(t, t.get("git1"), 25));
        try t.set("git2", try c.darken(t, t.get("git2"), 25));
        try t.set("git3", try c.darken(t, t.get("git3"), 25));
        try t.set("git4", try c.darken(t, t.get("git4"), 25));
        try t.set("git5", try c.darken(t, t.get("git5"), 25));
        try t.set("git6", try c.darken(t, t.get("git6"), 25));
        try t.set("git7", try c.darken(t, t.get("git7"), 25));
    }
    if (!t.get("gitInv0").truthy()) try t.set("gitInv0", try c.invert(t, t.get("git0")));
    if (!t.get("gitInv1").truthy()) try t.set("gitInv1", try c.invert(t, t.get("git1")));
    if (!t.get("gitInv2").truthy()) try t.set("gitInv2", try c.invert(t, t.get("git2")));
    if (!t.get("gitInv3").truthy()) try t.set("gitInv3", try c.invert(t, t.get("git3")));
    if (!t.get("gitInv4").truthy()) try t.set("gitInv4", try c.invert(t, t.get("git4")));
    if (!t.get("gitInv5").truthy()) try t.set("gitInv5", try c.invert(t, t.get("git5")));
    if (!t.get("gitInv6").truthy()) try t.set("gitInv6", try c.invert(t, t.get("git6")));
    if (!t.get("gitInv7").truthy()) try t.set("gitInv7", try c.invert(t, t.get("git7")));
    if (!t.get("branchLabelColor").truthy()) try t.set("branchLabelColor", if ((t.get("darkMode")).truthy()) V{ .s = "black" } else t.get("labelTextColor"));
    if (!t.get("gitBranchLabel0").truthy()) try t.set("gitBranchLabel0", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel1").truthy()) try t.set("gitBranchLabel1", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel2").truthy()) try t.set("gitBranchLabel2", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel3").truthy()) try t.set("gitBranchLabel3", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel4").truthy()) try t.set("gitBranchLabel4", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel5").truthy()) try t.set("gitBranchLabel5", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel6").truthy()) try t.set("gitBranchLabel6", t.get("branchLabelColor"));
    if (!t.get("gitBranchLabel7").truthy()) try t.set("gitBranchLabel7", t.get("branchLabelColor"));
    if (!t.get("tagLabelColor").truthy()) try t.set("tagLabelColor", t.get("primaryTextColor"));
    if (!t.get("tagLabelBackground").truthy()) try t.set("tagLabelBackground", t.get("primaryColor"));
    try t.set("tagLabelBorder", blk_x20: {
        const x20 = t.get("tagBorder");
        if (x20.truthy()) break :blk_x20 x20;
        break :blk_x20 t.get("primaryBorderColor");
    });
    if (!t.get("tagLabelFontSize").truthy()) try t.set("tagLabelFontSize", V{ .s = "10px" });
    if (!t.get("commitLabelColor").truthy()) try t.set("commitLabelColor", t.get("secondaryTextColor"));
    if (!t.get("commitLabelBackground").truthy()) try t.set("commitLabelBackground", t.get("secondaryColor"));
    if (!t.get("commitLabelFontSize").truthy()) try t.set("commitLabelFontSize", V{ .s = "10px" });
    try t.set("commitLineColor", blk_x21: {
        const x21 = t.get("commitLineColor");
        if (x21 != .undef) break :blk_x21 x21;
        break :blk_x21 V{ .s = "#BDBCCC" };
    });
    try t.set("fontWeight", V{ .n = 600 });
    try t.set("erEdgeLabelBackground", V{ .s = "#16141F" });
    if (!t.get("attributeBackgroundColorOdd").truthy()) try t.set("attributeBackgroundColorOdd", V{ .s = "#ffffff" });
    if (!t.get("attributeBackgroundColorEven").truthy()) try t.set("attributeBackgroundColorEven", V{ .s = "#f2f2f2" });
}
