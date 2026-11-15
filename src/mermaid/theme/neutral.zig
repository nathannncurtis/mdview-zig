// Generated from mermaid@12.2.0 packages/mermaid/src/themes by a one-off port; hand edits are fine.
const vars = @import("vars.zig");
const c = @import("color.zig");
const Vars = vars.Vars;
const V = vars.V;
const std = @import("std");

pub fn init(t: *Vars) vars.Err!void {
    try t.set("primaryColor", V{ .s = "#eee" });
    try t.set("contrast", V{ .s = "#707070" });
    try t.set("secondaryColor", try c.lighten(t, t.get("contrast"), 55));
    try t.set("background", V{ .s = "#ffffff" });
    try t.set("tertiaryColor", try c.adjust(t, t.get("primaryColor"), .{ .h = -160 }));
    try t.set("primaryBorderColor", try c.mkBorder(t, t.get("primaryColor"), t.get("darkMode")));
    try t.set("secondaryBorderColor", try c.mkBorder(t, t.get("secondaryColor"), t.get("darkMode")));
    try t.set("tertiaryBorderColor", try c.mkBorder(t, t.get("tertiaryColor"), t.get("darkMode")));
    try t.set("primaryTextColor", try c.invert(t, t.get("primaryColor")));
    try t.set("secondaryTextColor", try c.invert(t, t.get("secondaryColor")));
    try t.set("tertiaryTextColor", try c.invert(t, t.get("tertiaryColor")));
    try t.set("lineColor", try c.invert(t, t.get("background")));
    try t.set("textColor", try c.invert(t, t.get("background")));
    try t.set("mainBkg", V{ .s = "#eee" });
    try t.set("secondBkg", V{ .s = "calculated" });
    try t.set("lineColor", V{ .s = "#666" });
    try t.set("border1", V{ .s = "#999" });
    try t.set("border2", V{ .s = "calculated" });
    try t.set("note", V{ .s = "#ffa" });
    try t.set("text", V{ .s = "#333" });
    try t.set("critical", V{ .s = "#d42" });
    try t.set("done", V{ .s = "#bbb" });
    try t.set("arrowheadColor", V{ .s = "#333333" });
    try t.set("fontFamily", V{ .s = "\"trebuchet ms\", verdana, arial, sans-serif" });
    try t.set("fontSize", V{ .s = "16px" });
    try t.set("THEME_COLOR_LIMIT", V{ .n = 12 });
    try t.set("radius", V{ .n = 5 });
    try t.set("strokeWidth", V{ .n = 1 });
    try t.set("nodeBkg", V{ .s = "calculated" });
    try t.set("nodeBorder", V{ .s = "calculated" });
    try t.set("clusterBkg", V{ .s = "calculated" });
    try t.set("clusterBorder", V{ .s = "calculated" });
    try t.set("defaultLinkColor", V{ .s = "calculated" });
    try t.set("titleColor", V{ .s = "calculated" });
    try t.set("edgeLabelBackground", V{ .s = "white" });
    try t.set("actorBorder", V{ .s = "calculated" });
    try t.set("actorBkg", V{ .s = "calculated" });
    try t.set("actorTextColor", V{ .s = "calculated" });
    try t.set("actorLineColor", t.get("actorBorder"));
    try t.set("signalColor", V{ .s = "calculated" });
    try t.set("signalTextColor", V{ .s = "calculated" });
    try t.set("labelBoxBkgColor", V{ .s = "calculated" });
    try t.set("labelBoxBorderColor", V{ .s = "calculated" });
    try t.set("labelTextColor", V{ .s = "calculated" });
    try t.set("loopTextColor", V{ .s = "calculated" });
    try t.set("noteBorderColor", V{ .s = "calculated" });
    try t.set("noteBkgColor", V{ .s = "calculated" });
    try t.set("noteTextColor", V{ .s = "calculated" });
    try t.set("activationBorderColor", V{ .s = "#666" });
    try t.set("activationBkgColor", V{ .s = "#f4f4f4" });
    try t.set("sequenceNumberColor", V{ .s = "white" });
    try t.set("sectionBkgColor", V{ .s = "calculated" });
    try t.set("altSectionBkgColor", V{ .s = "white" });
    try t.set("sectionBkgColor2", V{ .s = "calculated" });
    try t.set("excludeBkgColor", V{ .s = "#eeeeee" });
    try t.set("taskBorderColor", V{ .s = "calculated" });
    try t.set("taskBkgColor", V{ .s = "calculated" });
    try t.set("taskTextLightColor", V{ .s = "white" });
    try t.set("taskTextColor", V{ .s = "calculated" });
    try t.set("taskTextDarkColor", V{ .s = "calculated" });
    try t.set("taskTextOutsideColor", V{ .s = "calculated" });
    try t.set("taskTextClickableColor", V{ .s = "#003163" });
    try t.set("activeTaskBorderColor", V{ .s = "calculated" });
    try t.set("activeTaskBkgColor", V{ .s = "calculated" });
    try t.set("gridColor", V{ .s = "calculated" });
    try t.set("doneTaskBkgColor", V{ .s = "calculated" });
    try t.set("doneTaskBorderColor", V{ .s = "calculated" });
    try t.set("critBkgColor", V{ .s = "calculated" });
    try t.set("critBorderColor", V{ .s = "calculated" });
    try t.set("todayLineColor", V{ .s = "calculated" });
    try t.set("vertLineColor", V{ .s = "calculated" });
    try t.set("personBorder", t.get("primaryBorderColor"));
    try t.set("personBkg", t.get("mainBkg"));
    try t.set("archEdgeColor", V{ .s = "calculated" });
    try t.set("archEdgeArrowColor", V{ .s = "calculated" });
    try t.set("archEdgeWidth", V{ .s = "3" });
    try t.set("archGroupBorderColor", t.get("primaryBorderColor"));
    try t.set("archGroupBorderWidth", V{ .s = "2px" });
    try t.set("noteFontWeight", V{ .s = "normal" });
    try t.set("fontWeight", V{ .s = "normal" });
    try t.set("rowOdd", blk_x0: {
        const x0 = blk_x1: {
            const x1 = t.get("rowOdd");
            if (x1.truthy()) break :blk_x1 x1;
            break :blk_x1 try c.lighten(t, t.get("mainBkg"), 75);
        };
        if (x0.truthy()) break :blk_x0 x0;
        break :blk_x0 V{ .s = "#ffffff" };
    });
    if (!t.get("rowEven").truthy()) try t.set("rowEven", V{ .s = "#f4f4f4" });
    try t.set("labelColor", V{ .s = "black" });
    try t.set("errorBkgColor", V{ .s = "#552222" });
    try t.set("errorTextColor", V{ .s = "#552222" });
    try t.set("useGradient", V{ .b = true });
    try t.set("gradientStart", t.get("primaryBorderColor"));
    try t.set("gradientStop", t.get("secondaryBorderColor"));
    try t.set("dropShadow", V{ .s = "drop-shadow( 1px 2px 2px rgba(185,185,185,1))" });
}

pub fn updateColors(t: *Vars) vars.Err!void {
    try t.set("secondBkg", try c.lighten(t, t.get("contrast"), 55));
    try t.set("border2", t.get("contrast"));
    try t.set("actorBorder", try c.lighten(t, t.get("border1"), 23));
    try t.set("actorBkg", t.get("mainBkg"));
    try t.set("actorTextColor", t.get("text"));
    try t.set("actorLineColor", t.get("actorBorder"));
    if (!t.get("rectBkgColor").truthy()) try t.set("rectBkgColor", t.get("tertiaryColor"));
    try t.set("signalColor", t.get("text"));
    try t.set("signalTextColor", t.get("text"));
    try t.set("labelBoxBkgColor", t.get("actorBkg"));
    try t.set("labelBoxBorderColor", t.get("actorBorder"));
    try t.set("labelTextColor", t.get("text"));
    try t.set("loopTextColor", t.get("text"));
    try t.set("noteBorderColor", V{ .s = "#999" });
    try t.set("noteBkgColor", V{ .s = "#666" });
    try t.set("noteTextColor", V{ .s = "#fff" });
    if (!t.get("cScale0").truthy()) try t.set("cScale0", V{ .s = "#555" });
    if (!t.get("cScale1").truthy()) try t.set("cScale1", V{ .s = "#F4F4F4" });
    if (!t.get("cScale2").truthy()) try t.set("cScale2", V{ .s = "#555" });
    if (!t.get("cScale3").truthy()) try t.set("cScale3", V{ .s = "#BBB" });
    if (!t.get("cScale4").truthy()) try t.set("cScale4", V{ .s = "#777" });
    if (!t.get("cScale5").truthy()) try t.set("cScale5", V{ .s = "#999" });
    if (!t.get("cScale6").truthy()) try t.set("cScale6", V{ .s = "#DDD" });
    if (!t.get("cScale7").truthy()) try t.set("cScale7", V{ .s = "#FFF" });
    if (!t.get("cScale8").truthy()) try t.set("cScale8", V{ .s = "#DDD" });
    if (!t.get("cScale9").truthy()) try t.set("cScale9", V{ .s = "#BBB" });
    if (!t.get("cScale10").truthy()) try t.set("cScale10", V{ .s = "#999" });
    if (!t.get("cScale11").truthy()) try t.set("cScale11", V{ .s = "#777" });
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
    if (!t.get("scaleLabelColor").truthy()) try t.set("scaleLabelColor", if ((t.get("darkMode")).truthy()) V{ .s = "black" } else t.get("labelTextColor"));
    if (!t.get("cScaleLabel0").truthy()) try t.set("cScaleLabel0", t.get("cScale1"));
    if (!t.get("cScaleLabel2").truthy()) try t.set("cScaleLabel2", t.get("cScale1"));
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            {
                const key = try t.key("cScaleLabel", i);
                if (!t.get(key).truthy()) try t.set(key, t.get("scaleLabelColor"));
            }
        }
    }
    {
        var i: f64 = 0;
        while (i < 5) : (i += 1) {
            {
                const key = try t.key("surface", i);
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get("mainBkg"), .{ .l = -(5 + (i * 5)) }));
            }
            {
                const key = try t.key("surfacePeer", i);
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get("mainBkg"), .{ .l = -(8 + (i * 5)) }));
            }
        }
    }
    try t.set("nodeBkg", t.get("mainBkg"));
    try t.set("nodeBorder", t.get("border1"));
    try t.set("clusterBkg", t.get("secondBkg"));
    try t.set("clusterBorder", t.get("border2"));
    try t.set("defaultLinkColor", t.get("lineColor"));
    try t.set("titleColor", t.get("text"));
    if (!t.get("flowContainerStroke").truthy()) try t.set("flowContainerStroke", t.get("secondaryBorderColor"));
    try t.set("sectionBkgColor", try c.lighten(t, t.get("contrast"), 30));
    try t.set("sectionBkgColor2", try c.lighten(t, t.get("contrast"), 30));
    try t.set("taskBorderColor", try c.darken(t, t.get("contrast"), 10));
    try t.set("taskBkgColor", t.get("contrast"));
    try t.set("taskTextColor", t.get("taskTextLightColor"));
    try t.set("taskTextDarkColor", t.get("text"));
    try t.set("taskTextOutsideColor", t.get("taskTextDarkColor"));
    try t.set("activeTaskBorderColor", t.get("taskBorderColor"));
    try t.set("activeTaskBkgColor", t.get("mainBkg"));
    try t.set("gridColor", try c.lighten(t, t.get("border1"), 30));
    try t.set("doneTaskBkgColor", t.get("done"));
    try t.set("doneTaskBorderColor", t.get("lineColor"));
    try t.set("critBkgColor", t.get("critical"));
    try t.set("critBorderColor", try c.darken(t, t.get("critBkgColor"), 10));
    try t.set("todayLineColor", t.get("critBkgColor"));
    try t.set("vertLineColor", t.get("critBkgColor"));
    try t.set("archEdgeColor", t.get("lineColor"));
    try t.set("archEdgeArrowColor", t.get("lineColor"));
    if (!t.get("transitionColor").truthy()) try t.set("transitionColor", V{ .s = "#000" });
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
    if (!t.get("stateBkg").truthy()) try t.set("stateBkg", t.get("mainBkg"));
    if (!t.get("labelBackgroundColor").truthy()) try t.set("labelBackgroundColor", t.get("stateBkg"));
    try t.set("compositeBackground", blk_x4: {
        const x4 = blk_x5: {
            const x5 = t.get("compositeBackground");
            if (x5.truthy()) break :blk_x5 x5;
            break :blk_x5 t.get("background");
        };
        if (x4.truthy()) break :blk_x4 x4;
        break :blk_x4 t.get("tertiaryColor");
    });
    if (!t.get("altBackground").truthy()) try t.set("altBackground", V{ .s = "#f4f4f4" });
    if (!t.get("compositeTitleBackground").truthy()) try t.set("compositeTitleBackground", t.get("mainBkg"));
    if (!t.get("stateBorder").truthy()) try t.set("stateBorder", V{ .s = "#000" });
    try t.set("innerEndBackground", t.get("primaryBorderColor"));
    try t.set("specialStateColor", V{ .s = "#222" });
    if (!t.get("errorBkgColor").truthy()) try t.set("errorBkgColor", t.get("tertiaryColor"));
    if (!t.get("errorTextColor").truthy()) try t.set("errorTextColor", t.get("tertiaryTextColor"));
    try t.set("classText", t.get("primaryTextColor"));
    try t.set("fillType0", t.get("primaryColor"));
    try t.set("fillType1", t.get("secondaryColor"));
    try t.set("fillType2", try c.adjust(t, t.get("primaryColor"), .{ .h = 64 }));
    try t.set("fillType3", try c.adjust(t, t.get("secondaryColor"), .{ .h = 64 }));
    try t.set("fillType4", try c.adjust(t, t.get("primaryColor"), .{ .h = -64 }));
    try t.set("fillType5", try c.adjust(t, t.get("secondaryColor"), .{ .h = -64 }));
    try t.set("fillType6", try c.adjust(t, t.get("primaryColor"), .{ .h = 128 }));
    try t.set("fillType7", try c.adjust(t, t.get("secondaryColor"), .{ .h = 128 }));
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            try t.set(try t.key("pie", i), t.get(try t.key("cScale", i)));
        }
    }
    try t.set("pie12", t.get("pie0"));
    if (!t.get("pieTitleTextSize").truthy()) try t.set("pieTitleTextSize", V{ .s = "25px" });
    if (!t.get("pieTitleTextColor").truthy()) try t.set("pieTitleTextColor", t.get("taskTextDarkColor"));
    if (!t.get("pieSectionTextSize").truthy()) try t.set("pieSectionTextSize", V{ .s = "17px" });
    if (!t.get("pieSectionTextColor").truthy()) try t.set("pieSectionTextColor", t.get("textColor"));
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
            try t.set(try t.key("venn", (i + 1)), blk_x6: {
                const x6 = t.get(try t.key("venn", (i + 1)));
                if (x6 != .undef) break :blk_x6 x6;
                break :blk_x6 t.get(try t.key("cScale", i));
            });
        }
    }
    try t.set("vennTitleTextColor", blk_x7: {
        const x7 = t.get("vennTitleTextColor");
        if (x7 != .undef) break :blk_x7 x7;
        break :blk_x7 t.get("titleColor");
    });
    try t.set("vennSetTextColor", blk_x8: {
        const x8 = t.get("vennSetTextColor");
        if (x8 != .undef) break :blk_x8 x8;
        break :blk_x8 t.get("textColor");
    });
    try t.set("cynefin.domainFontSize", blk_x9: {
        const x9 = t.get("cynefin.domainFontSize");
        if (x9.truthy()) break :blk_x9 x9;
        break :blk_x9 V{ .n = 16 };
    });
    try t.set("cynefin.itemFontSize", blk_x10: {
        const x10 = t.get("cynefin.itemFontSize");
        if (x10.truthy()) break :blk_x10 x10;
        break :blk_x10 V{ .n = 12 };
    });
    try t.set("cynefin.boundaryColor", blk_x11: {
        const x11 = t.get("cynefin.boundaryColor");
        if (x11.truthy()) break :blk_x11 x11;
        break :blk_x11 t.get("lineColor");
    });
    try t.set("cynefin.boundaryWidth", blk_x12: {
        const x12 = t.get("cynefin.boundaryWidth");
        if (x12.truthy()) break :blk_x12 x12;
        break :blk_x12 V{ .n = 2 };
    });
    try t.set("cynefin.cliffColor", blk_x13: {
        const x13 = t.get("cynefin.cliffColor");
        if (x13.truthy()) break :blk_x13 x13;
        break :blk_x13 V{ .s = "#8B0000" };
    });
    try t.set("cynefin.cliffWidth", blk_x14: {
        const x14 = t.get("cynefin.cliffWidth");
        if (x14.truthy()) break :blk_x14 x14;
        break :blk_x14 V{ .n = 4 };
    });
    try t.set("cynefin.arrowColor", blk_x15: {
        const x15 = t.get("cynefin.arrowColor");
        if (x15.truthy()) break :blk_x15 x15;
        break :blk_x15 t.get("lineColor");
    });
    try t.set("cynefin.arrowWidth", blk_x16: {
        const x16 = t.get("cynefin.arrowWidth");
        if (x16.truthy()) break :blk_x16 x16;
        break :blk_x16 V{ .n = 2 };
    });
    try t.set("cynefin.complexBg", blk_x17: {
        const x17 = t.get("cynefin.complexBg");
        if (x17.truthy()) break :blk_x17 x17;
        break :blk_x17 V{ .s = "#E8F5E9" };
    });
    try t.set("cynefin.complicatedBg", blk_x18: {
        const x18 = t.get("cynefin.complicatedBg");
        if (x18.truthy()) break :blk_x18 x18;
        break :blk_x18 V{ .s = "#E3F2FD" };
    });
    try t.set("cynefin.chaoticBg", blk_x19: {
        const x19 = t.get("cynefin.chaoticBg");
        if (x19.truthy()) break :blk_x19 x19;
        break :blk_x19 V{ .s = "#FBE9E7" };
    });
    try t.set("cynefin.clearBg", blk_x20: {
        const x20 = t.get("cynefin.clearBg");
        if (x20.truthy()) break :blk_x20 x20;
        break :blk_x20 V{ .s = "#FFF8E1" };
    });
    try t.set("cynefin.confusionBg", blk_x21: {
        const x21 = t.get("cynefin.confusionBg");
        if (x21.truthy()) break :blk_x21 x21;
        break :blk_x21 V{ .s = "#F3E5F5" };
    });
    try t.set("cynefin.textColor", blk_x22: {
        const x22 = t.get("cynefin.textColor");
        if (x22.truthy()) break :blk_x22 x22;
        break :blk_x22 t.get("textColor");
    });
    try t.set("cynefin.labelColor", blk_x23: {
        const x23 = t.get("cynefin.labelColor");
        if (x23.truthy()) break :blk_x23 x23;
        break :blk_x23 t.get("primaryTextColor");
    });
    if (!t.get("quadrant1Fill").truthy()) try t.set("quadrant1Fill", t.get("primaryColor"));
    if (!t.get("quadrant2Fill").truthy()) try t.set("quadrant2Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 5, .g = 5, .b = 5 }));
    if (!t.get("quadrant3Fill").truthy()) try t.set("quadrant3Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 10, .g = 10, .b = 10 }));
    if (!t.get("quadrant4Fill").truthy()) try t.set("quadrant4Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 15, .g = 15, .b = 15 }));
    if (!t.get("quadrant1TextFill").truthy()) try t.set("quadrant1TextFill", t.get("primaryTextColor"));
    if (!t.get("quadrant2TextFill").truthy()) try t.set("quadrant2TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -5, .g = -5, .b = -5 }));
    if (!t.get("quadrant3TextFill").truthy()) try t.set("quadrant3TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -10, .g = -10, .b = -10 }));
    if (!t.get("quadrant4TextFill").truthy()) try t.set("quadrant4TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -15, .g = -15, .b = -15 }));
    try t.set("quadrantPointFill", if ((blk_x24: {
        const x24 = t.get("quadrantPointFill");
        if (x24.truthy()) break :blk_x24 x24;
        break :blk_x24 V{ .b = try c.isDark(t.get("quadrant1Fill")) };
    }).truthy()) try c.lighten(t, t.get("quadrant1Fill"), std.math.nan(f64)) else try c.darken(t, t.get("quadrant1Fill"), std.math.nan(f64)));
    if (!t.get("quadrantPointTextFill").truthy()) try t.set("quadrantPointTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantXAxisTextFill").truthy()) try t.set("quadrantXAxisTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantYAxisTextFill").truthy()) try t.set("quadrantYAxisTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantInternalBorderStrokeFill").truthy()) try t.set("quadrantInternalBorderStrokeFill", t.get("primaryBorderColor"));
    if (!t.get("quadrantExternalBorderStrokeFill").truthy()) try t.set("quadrantExternalBorderStrokeFill", t.get("primaryBorderColor"));
    if (!t.get("quadrantTitleFill").truthy()) try t.set("quadrantTitleFill", t.get("primaryTextColor"));
    try t.set("xyChart.backgroundColor", blk_x25: {
        const x25 = t.get("xyChart.backgroundColor");
        if (x25.truthy()) break :blk_x25 x25;
        break :blk_x25 t.get("background");
    });
    try t.set("xyChart.titleColor", blk_x26: {
        const x26 = t.get("xyChart.titleColor");
        if (x26.truthy()) break :blk_x26 x26;
        break :blk_x26 t.get("primaryTextColor");
    });
    try t.set("xyChart.dataLabelColor", blk_x27: {
        const x27 = t.get("xyChart.dataLabelColor");
        if (x27.truthy()) break :blk_x27 x27;
        break :blk_x27 t.get("primaryTextColor");
    });
    try t.set("xyChart.legendTextColor", blk_x28: {
        const x28 = t.get("xyChart.legendTextColor");
        if (x28.truthy()) break :blk_x28 x28;
        break :blk_x28 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisTitleColor", blk_x29: {
        const x29 = t.get("xyChart.xAxisTitleColor");
        if (x29.truthy()) break :blk_x29 x29;
        break :blk_x29 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisLabelColor", blk_x30: {
        const x30 = t.get("xyChart.xAxisLabelColor");
        if (x30.truthy()) break :blk_x30 x30;
        break :blk_x30 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisTickColor", blk_x31: {
        const x31 = t.get("xyChart.xAxisTickColor");
        if (x31.truthy()) break :blk_x31 x31;
        break :blk_x31 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisLineColor", blk_x32: {
        const x32 = t.get("xyChart.xAxisLineColor");
        if (x32.truthy()) break :blk_x32 x32;
        break :blk_x32 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisTitleColor", blk_x33: {
        const x33 = t.get("xyChart.yAxisTitleColor");
        if (x33.truthy()) break :blk_x33 x33;
        break :blk_x33 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisLabelColor", blk_x34: {
        const x34 = t.get("xyChart.yAxisLabelColor");
        if (x34.truthy()) break :blk_x34 x34;
        break :blk_x34 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisTickColor", blk_x35: {
        const x35 = t.get("xyChart.yAxisTickColor");
        if (x35.truthy()) break :blk_x35 x35;
        break :blk_x35 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisLineColor", blk_x36: {
        const x36 = t.get("xyChart.yAxisLineColor");
        if (x36.truthy()) break :blk_x36 x36;
        break :blk_x36 t.get("primaryTextColor");
    });
    try t.set("xyChart.plotColorPalette", blk_x37: {
        const x37 = t.get("xyChart.plotColorPalette");
        if (x37.truthy()) break :blk_x37 x37;
        break :blk_x37 V{ .s = "#EEE,#6BB8E4,#8ACB88,#C7ACD6,#E8DCC2,#FFB2A8,#FFF380,#7E8D91,#FFD8B1,#FAF3E0" };
    });
    try t.set("radar.axisColor", blk_x38: {
        const x38 = t.get("radar.axisColor");
        if (x38.truthy()) break :blk_x38 x38;
        break :blk_x38 t.get("lineColor");
    });
    try t.set("radar.axisStrokeWidth", blk_x39: {
        const x39 = t.get("radar.axisStrokeWidth");
        if (x39.truthy()) break :blk_x39 x39;
        break :blk_x39 V{ .n = 2 };
    });
    try t.set("radar.axisLabelFontSize", blk_x40: {
        const x40 = t.get("radar.axisLabelFontSize");
        if (x40.truthy()) break :blk_x40 x40;
        break :blk_x40 V{ .n = 12 };
    });
    try t.set("radar.curveOpacity", blk_x41: {
        const x41 = t.get("radar.curveOpacity");
        if (x41.truthy()) break :blk_x41 x41;
        break :blk_x41 V{ .n = 0.5 };
    });
    try t.set("radar.curveStrokeWidth", blk_x42: {
        const x42 = t.get("radar.curveStrokeWidth");
        if (x42.truthy()) break :blk_x42 x42;
        break :blk_x42 V{ .n = 2 };
    });
    try t.set("radar.graticuleColor", blk_x43: {
        const x43 = t.get("radar.graticuleColor");
        if (x43.truthy()) break :blk_x43 x43;
        break :blk_x43 V{ .s = "#DEDEDE" };
    });
    try t.set("radar.graticuleStrokeWidth", blk_x44: {
        const x44 = t.get("radar.graticuleStrokeWidth");
        if (x44.truthy()) break :blk_x44 x44;
        break :blk_x44 V{ .n = 1 };
    });
    try t.set("radar.graticuleOpacity", blk_x45: {
        const x45 = t.get("radar.graticuleOpacity");
        if (x45.truthy()) break :blk_x45 x45;
        break :blk_x45 V{ .n = 0.3 };
    });
    try t.set("radar.legendBoxSize", blk_x46: {
        const x46 = t.get("radar.legendBoxSize");
        if (x46.truthy()) break :blk_x46 x46;
        break :blk_x46 V{ .n = 12 };
    });
    try t.set("radar.legendFontSize", blk_x47: {
        const x47 = t.get("radar.legendFontSize");
        if (x47.truthy()) break :blk_x47 x47;
        break :blk_x47 V{ .n = 12 };
    });
    if (!t.get("wardleyEvolutionColor").truthy()) try t.set("wardleyEvolutionColor", V{ .s = "#dc3545" });
    try t.set("wardley.backgroundColor", blk_x48: {
        const x48 = t.get("wardley.backgroundColor");
        if (x48.truthy()) break :blk_x48 x48;
        break :blk_x48 t.get("background");
    });
    try t.set("wardley.axisColor", blk_x49: {
        const x49 = t.get("wardley.axisColor");
        if (x49.truthy()) break :blk_x49 x49;
        break :blk_x49 t.get("lineColor");
    });
    try t.set("wardley.axisTextColor", blk_x50: {
        const x50 = t.get("wardley.axisTextColor");
        if (x50.truthy()) break :blk_x50 x50;
        break :blk_x50 t.get("primaryTextColor");
    });
    try t.set("wardley.gridColor", blk_x51: {
        const x51 = t.get("wardley.gridColor");
        if (x51.truthy()) break :blk_x51 x51;
        break :blk_x51 t.get("gridColor");
    });
    try t.set("wardley.componentFill", blk_x52: {
        const x52 = t.get("wardley.componentFill");
        if (x52.truthy()) break :blk_x52 x52;
        break :blk_x52 t.get("background");
    });
    try t.set("wardley.componentStroke", blk_x53: {
        const x53 = t.get("wardley.componentStroke");
        if (x53.truthy()) break :blk_x53 x53;
        break :blk_x53 t.get("lineColor");
    });
    try t.set("wardley.componentLabelColor", blk_x54: {
        const x54 = t.get("wardley.componentLabelColor");
        if (x54.truthy()) break :blk_x54 x54;
        break :blk_x54 t.get("primaryTextColor");
    });
    try t.set("wardley.linkStroke", blk_x55: {
        const x55 = t.get("wardley.linkStroke");
        if (x55.truthy()) break :blk_x55 x55;
        break :blk_x55 t.get("lineColor");
    });
    try t.set("wardley.evolutionStroke", blk_x56: {
        const x56 = t.get("wardley.evolutionStroke");
        if (x56.truthy()) break :blk_x56 x56;
        break :blk_x56 t.get("wardleyEvolutionColor");
    });
    try t.set("wardley.annotationStroke", blk_x57: {
        const x57 = t.get("wardley.annotationStroke");
        if (x57.truthy()) break :blk_x57 x57;
        break :blk_x57 t.get("lineColor");
    });
    try t.set("wardley.annotationTextColor", blk_x58: {
        const x58 = t.get("wardley.annotationTextColor");
        if (x58.truthy()) break :blk_x58 x58;
        break :blk_x58 t.get("primaryTextColor");
    });
    try t.set("wardley.annotationFill", blk_x59: {
        const x59 = t.get("wardley.annotationFill");
        if (x59.truthy()) break :blk_x59 x59;
        break :blk_x59 t.get("background");
    });
    if (!t.get("requirementBackground").truthy()) try t.set("requirementBackground", t.get("primaryColor"));
    if (!t.get("requirementBorderColor").truthy()) try t.set("requirementBorderColor", t.get("primaryBorderColor"));
    if (!t.get("requirementBorderSize").truthy()) try t.set("requirementBorderSize", V{ .s = "1" });
    if (!t.get("requirementTextColor").truthy()) try t.set("requirementTextColor", t.get("primaryTextColor"));
    if (!t.get("relationColor").truthy()) try t.set("relationColor", t.get("lineColor"));
    if (!t.get("relationLabelBackground").truthy()) try t.set("relationLabelBackground", t.get("edgeLabelBackground"));
    if (!t.get("relationLabelColor").truthy()) try t.set("relationLabelColor", t.get("actorTextColor"));
    try t.set("git0", blk_x60: {
        const x60 = try c.darken(t, t.get("pie1"), 25);
        if (x60.truthy()) break :blk_x60 x60;
        break :blk_x60 t.get("primaryColor");
    });
    try t.set("git1", blk_x61: {
        const x61 = t.get("pie2");
        if (x61.truthy()) break :blk_x61 x61;
        break :blk_x61 t.get("secondaryColor");
    });
    try t.set("git2", blk_x62: {
        const x62 = t.get("pie3");
        if (x62.truthy()) break :blk_x62 x62;
        break :blk_x62 t.get("tertiaryColor");
    });
    try t.set("git3", blk_x63: {
        const x63 = t.get("pie4");
        if (x63.truthy()) break :blk_x63 x63;
        break :blk_x63 try c.adjust(t, t.get("primaryColor"), .{ .h = -30 });
    });
    try t.set("git4", blk_x64: {
        const x64 = t.get("pie5");
        if (x64.truthy()) break :blk_x64 x64;
        break :blk_x64 try c.adjust(t, t.get("primaryColor"), .{ .h = -60 });
    });
    try t.set("git5", blk_x65: {
        const x65 = t.get("pie6");
        if (x65.truthy()) break :blk_x65 x65;
        break :blk_x65 try c.adjust(t, t.get("primaryColor"), .{ .h = -90 });
    });
    try t.set("git6", blk_x66: {
        const x66 = t.get("pie7");
        if (x66.truthy()) break :blk_x66 x66;
        break :blk_x66 try c.adjust(t, t.get("primaryColor"), .{ .h = 60 });
    });
    try t.set("git7", blk_x67: {
        const x67 = t.get("pie8");
        if (x67.truthy()) break :blk_x67 x67;
        break :blk_x67 try c.adjust(t, t.get("primaryColor"), .{ .h = 120 });
    });
    if (!t.get("gitInv0").truthy()) try t.set("gitInv0", try c.invert(t, t.get("git0")));
    if (!t.get("gitInv1").truthy()) try t.set("gitInv1", try c.invert(t, t.get("git1")));
    if (!t.get("gitInv2").truthy()) try t.set("gitInv2", try c.invert(t, t.get("git2")));
    if (!t.get("gitInv3").truthy()) try t.set("gitInv3", try c.invert(t, t.get("git3")));
    if (!t.get("gitInv4").truthy()) try t.set("gitInv4", try c.invert(t, t.get("git4")));
    if (!t.get("gitInv5").truthy()) try t.set("gitInv5", try c.invert(t, t.get("git5")));
    if (!t.get("gitInv6").truthy()) try t.set("gitInv6", try c.invert(t, t.get("git6")));
    if (!t.get("gitInv7").truthy()) try t.set("gitInv7", try c.invert(t, t.get("git7")));
    if (!t.get("branchLabelColor").truthy()) try t.set("branchLabelColor", t.get("labelTextColor"));
    try t.set("gitBranchLabel0", t.get("branchLabelColor"));
    try t.set("gitBranchLabel1", V{ .s = "white" });
    try t.set("gitBranchLabel2", t.get("branchLabelColor"));
    try t.set("gitBranchLabel3", V{ .s = "white" });
    try t.set("gitBranchLabel4", t.get("branchLabelColor"));
    try t.set("gitBranchLabel5", t.get("branchLabelColor"));
    try t.set("gitBranchLabel6", t.get("branchLabelColor"));
    try t.set("gitBranchLabel7", t.get("branchLabelColor"));
    if (!t.get("tagLabelColor").truthy()) try t.set("tagLabelColor", t.get("primaryTextColor"));
    if (!t.get("tagLabelBackground").truthy()) try t.set("tagLabelBackground", t.get("primaryColor"));
    try t.set("tagLabelBorder", blk_x68: {
        const x68 = t.get("tagBorder");
        if (x68.truthy()) break :blk_x68 x68;
        break :blk_x68 t.get("primaryBorderColor");
    });
    if (!t.get("tagLabelFontSize").truthy()) try t.set("tagLabelFontSize", V{ .s = "10px" });
    if (!t.get("commitLabelColor").truthy()) try t.set("commitLabelColor", t.get("secondaryTextColor"));
    if (!t.get("commitLabelBackground").truthy()) try t.set("commitLabelBackground", t.get("secondaryColor"));
    if (!t.get("commitLabelFontSize").truthy()) try t.set("commitLabelFontSize", V{ .s = "10px" });
    if (!t.get("emUiFill").truthy()) try t.set("emUiFill", V{ .s = "white" });
    if (!t.get("emUiStroke").truthy()) try t.set("emUiStroke", V{ .s = "#dbdada" });
    if (!t.get("emProcessorFill").truthy()) try t.set("emProcessorFill", V{ .s = "#edb3f6" });
    if (!t.get("emProcessorStroke").truthy()) try t.set("emProcessorStroke", V{ .s = "#b88cbf" });
    if (!t.get("emReadModelFill").truthy()) try t.set("emReadModelFill", V{ .s = "#d3f1a2" });
    if (!t.get("emReadModelStroke").truthy()) try t.set("emReadModelStroke", V{ .s = "#a3b732" });
    if (!t.get("emCommandFill").truthy()) try t.set("emCommandFill", V{ .s = "#bcd6fe" });
    if (!t.get("emCommandStroke").truthy()) try t.set("emCommandStroke", V{ .s = "#679ac3" });
    if (!t.get("emEventFill").truthy()) try t.set("emEventFill", V{ .s = "#ffb778" });
    if (!t.get("emEventStroke").truthy()) try t.set("emEventStroke", V{ .s = "#c19a0f" });
    if (!t.get("emSwimlaneBackgroundOdd").truthy()) try t.set("emSwimlaneBackgroundOdd", V{ .s = "rgb(250,250,250)" });
    if (!t.get("emSwimlaneBackgroundStroke").truthy()) try t.set("emSwimlaneBackgroundStroke", V{ .s = "rgb(240,240,240)" });
    if (!t.get("emArrowhead").truthy()) try t.set("emArrowhead", t.get("lineColor"));
    if (!t.get("emRelationStroke").truthy()) try t.set("emRelationStroke", t.get("lineColor"));
    if (!t.get("attributeBackgroundColorOdd").truthy()) try t.set("attributeBackgroundColorOdd", V{ .s = "#ffffff" });
    if (!t.get("attributeBackgroundColorEven").truthy()) try t.set("attributeBackgroundColorEven", V{ .s = "#f2f2f2" });
}
