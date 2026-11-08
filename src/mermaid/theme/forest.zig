// Generated from mermaid@12.2.0 packages/mermaid/src/themes by a one-off port; hand edits are fine.
const vars = @import("vars.zig");
const c = @import("color.zig");
const Vars = vars.Vars;
const V = vars.V;
const std = @import("std");

pub fn init(t: *Vars) vars.Err!void {
    try t.set("background", V{ .s = "#f4f4f4" });
    try t.set("primaryColor", V{ .s = "#cde498" });
    try t.set("secondaryColor", V{ .s = "#cdffb2" });
    try t.set("background", V{ .s = "white" });
    try t.set("mainBkg", V{ .s = "#cde498" });
    try t.set("secondBkg", V{ .s = "#cdffb2" });
    try t.set("lineColor", V{ .s = "green" });
    try t.set("border1", V{ .s = "#13540c" });
    try t.set("border2", V{ .s = "#6eaa49" });
    try t.set("arrowheadColor", V{ .s = "green" });
    try t.set("fontFamily", V{ .s = "\"trebuchet ms\", verdana, arial, sans-serif" });
    try t.set("fontSize", V{ .s = "16px" });
    try t.set("tertiaryColor", try c.lighten(t, V{ .s = "#cde498" }, 10));
    try t.set("primaryBorderColor", try c.mkBorder(t, t.get("primaryColor"), t.get("darkMode")));
    try t.set("secondaryBorderColor", try c.mkBorder(t, t.get("secondaryColor"), t.get("darkMode")));
    try t.set("tertiaryBorderColor", try c.mkBorder(t, t.get("tertiaryColor"), t.get("darkMode")));
    try t.set("primaryTextColor", try c.invert(t, t.get("primaryColor")));
    try t.set("secondaryTextColor", try c.invert(t, t.get("secondaryColor")));
    try t.set("tertiaryTextColor", try c.invert(t, t.get("primaryColor")));
    try t.set("lineColor", try c.invert(t, t.get("background")));
    try t.set("textColor", try c.invert(t, t.get("background")));
    try t.set("THEME_COLOR_LIMIT", V{ .n = 12 });
    try t.set("radius", V{ .n = 5 });
    try t.set("strokeWidth", V{ .n = 1 });
    try t.set("nodeBkg", V{ .s = "calculated" });
    try t.set("nodeBorder", V{ .s = "calculated" });
    try t.set("clusterBkg", V{ .s = "calculated" });
    try t.set("clusterBorder", V{ .s = "calculated" });
    try t.set("defaultLinkColor", V{ .s = "calculated" });
    try t.set("titleColor", V{ .s = "#333" });
    try t.set("edgeLabelBackground", V{ .s = "#e8e8e8" });
    try t.set("actorBorder", V{ .s = "calculated" });
    try t.set("actorBkg", V{ .s = "calculated" });
    try t.set("actorTextColor", V{ .s = "black" });
    try t.set("actorLineColor", V{ .s = "calculated" });
    try t.set("signalColor", V{ .s = "#333" });
    try t.set("signalTextColor", V{ .s = "#333" });
    try t.set("labelBoxBkgColor", V{ .s = "calculated" });
    try t.set("labelBoxBorderColor", V{ .s = "#326932" });
    try t.set("labelTextColor", V{ .s = "calculated" });
    try t.set("loopTextColor", V{ .s = "calculated" });
    try t.set("noteBorderColor", V{ .s = "calculated" });
    try t.set("noteBkgColor", V{ .s = "#fff5ad" });
    try t.set("noteTextColor", V{ .s = "calculated" });
    try t.set("activationBorderColor", V{ .s = "#666" });
    try t.set("activationBkgColor", V{ .s = "#f4f4f4" });
    try t.set("sequenceNumberColor", V{ .s = "white" });
    try t.set("sectionBkgColor", V{ .s = "#6eaa49" });
    try t.set("altSectionBkgColor", V{ .s = "white" });
    try t.set("sectionBkgColor2", V{ .s = "#6eaa49" });
    try t.set("excludeBkgColor", V{ .s = "#eeeeee" });
    try t.set("taskBorderColor", V{ .s = "calculated" });
    try t.set("taskBkgColor", V{ .s = "#487e3a" });
    try t.set("taskTextLightColor", V{ .s = "white" });
    try t.set("taskTextColor", V{ .s = "calculated" });
    try t.set("taskTextDarkColor", V{ .s = "black" });
    try t.set("taskTextOutsideColor", V{ .s = "calculated" });
    try t.set("taskTextClickableColor", V{ .s = "#003163" });
    try t.set("activeTaskBorderColor", V{ .s = "calculated" });
    try t.set("activeTaskBkgColor", V{ .s = "calculated" });
    try t.set("gridColor", V{ .s = "lightgrey" });
    try t.set("doneTaskBkgColor", V{ .s = "lightgrey" });
    try t.set("doneTaskBorderColor", V{ .s = "grey" });
    try t.set("critBorderColor", V{ .s = "#ff8888" });
    try t.set("critBkgColor", V{ .s = "red" });
    try t.set("todayLineColor", V{ .s = "red" });
    try t.set("vertLineColor", V{ .s = "#00BFFF" });
    try t.set("personBorder", t.get("primaryBorderColor"));
    try t.set("personBkg", t.get("mainBkg"));
    try t.set("archEdgeColor", V{ .s = "calculated" });
    try t.set("archEdgeArrowColor", V{ .s = "calculated" });
    try t.set("archEdgeWidth", V{ .s = "3" });
    try t.set("archGroupBorderColor", t.get("primaryBorderColor"));
    try t.set("archGroupBorderWidth", V{ .s = "2px" });
    try t.set("noteFontWeight", V{ .s = "normal" });
    try t.set("fontWeight", V{ .s = "normal" });
    try t.set("labelColor", V{ .s = "black" });
    try t.set("errorBkgColor", V{ .s = "#552222" });
    try t.set("errorTextColor", V{ .s = "#552222" });
    try t.set("useGradient", V{ .b = true });
    try t.set("gradientStart", t.get("primaryBorderColor"));
    try t.set("gradientStop", t.get("secondaryBorderColor"));
    try t.set("dropShadow", V{ .s = "drop-shadow( 1px 2px 2px rgba(185,185,185,0.5))" });
}

pub fn updateColors(t: *Vars) vars.Err!void {
    try t.set("actorBorder", try c.darken(t, t.get("mainBkg"), 20));
    try t.set("actorBkg", t.get("mainBkg"));
    try t.set("labelBoxBkgColor", t.get("actorBkg"));
    try t.set("labelTextColor", t.get("actorTextColor"));
    try t.set("loopTextColor", t.get("actorTextColor"));
    try t.set("noteBorderColor", t.get("border2"));
    try t.set("noteTextColor", t.get("actorTextColor"));
    try t.set("actorLineColor", t.get("actorBorder"));
    if (!t.get("rectBkgColor").truthy()) try t.set("rectBkgColor", t.get("tertiaryColor"));
    if (!t.get("cScale0").truthy()) try t.set("cScale0", t.get("primaryColor"));
    if (!t.get("cScale1").truthy()) try t.set("cScale1", t.get("secondaryColor"));
    if (!t.get("cScale2").truthy()) try t.set("cScale2", t.get("tertiaryColor"));
    if (!t.get("cScale3").truthy()) try t.set("cScale3", try c.adjust(t, t.get("primaryColor"), .{ .h = 30 }));
    if (!t.get("cScale4").truthy()) try t.set("cScale4", try c.adjust(t, t.get("primaryColor"), .{ .h = 60 }));
    if (!t.get("cScale5").truthy()) try t.set("cScale5", try c.adjust(t, t.get("primaryColor"), .{ .h = 90 }));
    if (!t.get("cScale6").truthy()) try t.set("cScale6", try c.adjust(t, t.get("primaryColor"), .{ .h = 120 }));
    if (!t.get("cScale7").truthy()) try t.set("cScale7", try c.adjust(t, t.get("primaryColor"), .{ .h = 150 }));
    if (!t.get("cScale8").truthy()) try t.set("cScale8", try c.adjust(t, t.get("primaryColor"), .{ .h = 210 }));
    if (!t.get("cScale9").truthy()) try t.set("cScale9", try c.adjust(t, t.get("primaryColor"), .{ .h = 270 }));
    if (!t.get("cScale10").truthy()) try t.set("cScale10", try c.adjust(t, t.get("primaryColor"), .{ .h = 300 }));
    if (!t.get("cScale11").truthy()) try t.set("cScale11", try c.adjust(t, t.get("primaryColor"), .{ .h = 330 }));
    {
        const key = try t.key("cScalePeer", 1);
        if (!t.get(key).truthy()) try t.set(key, try c.darken(t, t.get("secondaryColor"), 45));
    }
    {
        const key = try t.key("cScalePeer", 2);
        if (!t.get(key).truthy()) try t.set(key, try c.darken(t, t.get("tertiaryColor"), 40));
    }
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            try t.set(try t.key("cScale", i), try c.darken(t, t.get(try t.key("cScale", i)), 10));
            {
                const key = try t.key("cScalePeer", i);
                if (!t.get(key).truthy()) try t.set(key, try c.darken(t, t.get(try t.key("cScale", i)), 25));
            }
        }
    }
    {
        var i: f64 = 0;
        while (i < (try t.get("THEME_COLOR_LIMIT").num())) : (i += 1) {
            {
                const key = try t.key("cScaleInv", i);
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get(try t.key("cScale", i)), .{ .h = 180 }));
            }
        }
    }
    try t.set("scaleLabelColor", if ((blk_x0: {
        const x0 = V{ .b = !(t.get("scaleLabelColor")).eql(V{ .s = "calculated" }) };
        if (!x0.truthy()) break :blk_x0 x0;
        break :blk_x0 t.get("scaleLabelColor");
    }).truthy()) t.get("scaleLabelColor") else t.get("labelTextColor"));
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
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get("mainBkg"), .{ .h = 30, .s = -30, .l = -(5 + (i * 5)) }));
            }
            {
                const key = try t.key("surfacePeer", i);
                if (!t.get(key).truthy()) try t.set(key, try c.adjust(t, t.get("mainBkg"), .{ .h = 30, .s = -30, .l = -(8 + (i * 5)) }));
            }
        }
    }
    try t.set("nodeBkg", t.get("mainBkg"));
    try t.set("nodeBorder", t.get("border1"));
    try t.set("clusterBkg", t.get("secondBkg"));
    try t.set("clusterBorder", t.get("border2"));
    try t.set("defaultLinkColor", t.get("lineColor"));
    if (!t.get("flowContainerStroke").truthy()) try t.set("flowContainerStroke", t.get("secondaryBorderColor"));
    try t.set("taskBorderColor", t.get("border1"));
    try t.set("taskTextColor", t.get("taskTextLightColor"));
    try t.set("taskTextOutsideColor", t.get("taskTextDarkColor"));
    try t.set("activeTaskBorderColor", t.get("taskBorderColor"));
    try t.set("activeTaskBkgColor", t.get("mainBkg"));
    try t.set("archEdgeColor", t.get("lineColor"));
    try t.set("archEdgeArrowColor", t.get("lineColor"));
    try t.set("rowOdd", blk_x1: {
        const x1 = blk_x2: {
            const x2 = t.get("rowOdd");
            if (x2.truthy()) break :blk_x2 x2;
            break :blk_x2 try c.lighten(t, t.get("mainBkg"), 75);
        };
        if (x1.truthy()) break :blk_x1 x1;
        break :blk_x1 V{ .s = "#ffffff" };
    });
    if (!t.get("rowEven").truthy()) try t.set("rowEven", try c.lighten(t, t.get("mainBkg"), 20));
    if (!t.get("transitionColor").truthy()) try t.set("transitionColor", t.get("lineColor"));
    if (!t.get("transitionLabelColor").truthy()) try t.set("transitionLabelColor", t.get("textColor"));
    try t.set("stateLabelColor", blk_x3: {
        const x3 = blk_x4: {
            const x4 = t.get("stateLabelColor");
            if (x4.truthy()) break :blk_x4 x4;
            break :blk_x4 t.get("stateBkg");
        };
        if (x3.truthy()) break :blk_x3 x3;
        break :blk_x3 t.get("primaryTextColor");
    });
    if (!t.get("stateBkg").truthy()) try t.set("stateBkg", t.get("mainBkg"));
    if (!t.get("labelBackgroundColor").truthy()) try t.set("labelBackgroundColor", t.get("stateBkg"));
    try t.set("compositeBackground", blk_x5: {
        const x5 = blk_x6: {
            const x6 = t.get("compositeBackground");
            if (x6.truthy()) break :blk_x6 x6;
            break :blk_x6 t.get("background");
        };
        if (x5.truthy()) break :blk_x5 x5;
        break :blk_x5 t.get("tertiaryColor");
    });
    if (!t.get("altBackground").truthy()) try t.set("altBackground", V{ .s = "#f0f0f0" });
    if (!t.get("compositeTitleBackground").truthy()) try t.set("compositeTitleBackground", t.get("mainBkg"));
    if (!t.get("compositeBorder").truthy()) try t.set("compositeBorder", t.get("nodeBorder"));
    try t.set("innerEndBackground", t.get("primaryBorderColor"));
    try t.set("specialStateColor", t.get("lineColor"));
    if (!t.get("errorBkgColor").truthy()) try t.set("errorBkgColor", t.get("tertiaryColor"));
    if (!t.get("errorTextColor").truthy()) try t.set("errorTextColor", t.get("tertiaryTextColor"));
    if (!t.get("transitionColor").truthy()) try t.set("transitionColor", t.get("lineColor"));
    try t.set("classText", t.get("primaryTextColor"));
    try t.set("fillType0", t.get("primaryColor"));
    try t.set("fillType1", t.get("secondaryColor"));
    try t.set("fillType2", try c.adjust(t, t.get("primaryColor"), .{ .h = 64 }));
    try t.set("fillType3", try c.adjust(t, t.get("secondaryColor"), .{ .h = 64 }));
    try t.set("fillType4", try c.adjust(t, t.get("primaryColor"), .{ .h = -64 }));
    try t.set("fillType5", try c.adjust(t, t.get("secondaryColor"), .{ .h = -64 }));
    try t.set("fillType6", try c.adjust(t, t.get("primaryColor"), .{ .h = 128 }));
    try t.set("fillType7", try c.adjust(t, t.get("secondaryColor"), .{ .h = 128 }));
    if (!t.get("pie1").truthy()) try t.set("pie1", t.get("primaryColor"));
    if (!t.get("pie2").truthy()) try t.set("pie2", t.get("secondaryColor"));
    if (!t.get("pie3").truthy()) try t.set("pie3", t.get("tertiaryColor"));
    if (!t.get("pie4").truthy()) try t.set("pie4", try c.adjust(t, t.get("primaryColor"), .{ .l = -30 }));
    if (!t.get("pie5").truthy()) try t.set("pie5", try c.adjust(t, t.get("secondaryColor"), .{ .l = -30 }));
    if (!t.get("pie6").truthy()) try t.set("pie6", try c.adjust(t, t.get("tertiaryColor"), .{ .h = 40, .l = -40 }));
    if (!t.get("pie7").truthy()) try t.set("pie7", try c.adjust(t, t.get("primaryColor"), .{ .h = 60, .l = -10 }));
    if (!t.get("pie8").truthy()) try t.set("pie8", try c.adjust(t, t.get("primaryColor"), .{ .h = -60, .l = -10 }));
    if (!t.get("pie9").truthy()) try t.set("pie9", try c.adjust(t, t.get("primaryColor"), .{ .h = 120, .l = 0 }));
    if (!t.get("pie10").truthy()) try t.set("pie10", try c.adjust(t, t.get("primaryColor"), .{ .h = 60, .l = -50 }));
    if (!t.get("pie11").truthy()) try t.set("pie11", try c.adjust(t, t.get("primaryColor"), .{ .h = -60, .l = -50 }));
    if (!t.get("pie12").truthy()) try t.set("pie12", try c.adjust(t, t.get("primaryColor"), .{ .h = 120, .l = -50 }));
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
    try t.set("venn1", blk_x7: {
        const x7 = t.get("venn1");
        if (x7 != .undef) break :blk_x7 x7;
        break :blk_x7 try c.adjust(t, t.get("primaryColor"), .{ .l = -30 });
    });
    try t.set("venn2", blk_x8: {
        const x8 = t.get("venn2");
        if (x8 != .undef) break :blk_x8 x8;
        break :blk_x8 try c.adjust(t, t.get("secondaryColor"), .{ .l = -30 });
    });
    try t.set("venn3", blk_x9: {
        const x9 = t.get("venn3");
        if (x9 != .undef) break :blk_x9 x9;
        break :blk_x9 try c.adjust(t, t.get("tertiaryColor"), .{ .l = -30 });
    });
    try t.set("venn4", blk_x10: {
        const x10 = t.get("venn4");
        if (x10 != .undef) break :blk_x10 x10;
        break :blk_x10 try c.adjust(t, t.get("primaryColor"), .{ .h = 60, .l = -30 });
    });
    try t.set("venn5", blk_x11: {
        const x11 = t.get("venn5");
        if (x11 != .undef) break :blk_x11 x11;
        break :blk_x11 try c.adjust(t, t.get("primaryColor"), .{ .h = -60, .l = -30 });
    });
    try t.set("venn6", blk_x12: {
        const x12 = t.get("venn6");
        if (x12 != .undef) break :blk_x12 x12;
        break :blk_x12 try c.adjust(t, t.get("secondaryColor"), .{ .h = 60, .l = -30 });
    });
    try t.set("venn7", blk_x13: {
        const x13 = t.get("venn7");
        if (x13 != .undef) break :blk_x13 x13;
        break :blk_x13 try c.adjust(t, t.get("primaryColor"), .{ .h = 120, .l = -30 });
    });
    try t.set("venn8", blk_x14: {
        const x14 = t.get("venn8");
        if (x14 != .undef) break :blk_x14 x14;
        break :blk_x14 try c.adjust(t, t.get("secondaryColor"), .{ .h = 120, .l = -30 });
    });
    try t.set("vennTitleTextColor", blk_x15: {
        const x15 = t.get("vennTitleTextColor");
        if (x15 != .undef) break :blk_x15 x15;
        break :blk_x15 t.get("titleColor");
    });
    try t.set("vennSetTextColor", blk_x16: {
        const x16 = t.get("vennSetTextColor");
        if (x16 != .undef) break :blk_x16 x16;
        break :blk_x16 t.get("textColor");
    });
    try t.set("cynefin.domainFontSize", blk_x17: {
        const x17 = t.get("cynefin.domainFontSize");
        if (x17.truthy()) break :blk_x17 x17;
        break :blk_x17 V{ .n = 16 };
    });
    try t.set("cynefin.itemFontSize", blk_x18: {
        const x18 = t.get("cynefin.itemFontSize");
        if (x18.truthy()) break :blk_x18 x18;
        break :blk_x18 V{ .n = 12 };
    });
    try t.set("cynefin.boundaryColor", blk_x19: {
        const x19 = t.get("cynefin.boundaryColor");
        if (x19.truthy()) break :blk_x19 x19;
        break :blk_x19 t.get("lineColor");
    });
    try t.set("cynefin.boundaryWidth", blk_x20: {
        const x20 = t.get("cynefin.boundaryWidth");
        if (x20.truthy()) break :blk_x20 x20;
        break :blk_x20 V{ .n = 2 };
    });
    try t.set("cynefin.cliffColor", blk_x21: {
        const x21 = t.get("cynefin.cliffColor");
        if (x21.truthy()) break :blk_x21 x21;
        break :blk_x21 V{ .s = "#8B4513" };
    });
    try t.set("cynefin.cliffWidth", blk_x22: {
        const x22 = t.get("cynefin.cliffWidth");
        if (x22.truthy()) break :blk_x22 x22;
        break :blk_x22 V{ .n = 4 };
    });
    try t.set("cynefin.arrowColor", blk_x23: {
        const x23 = t.get("cynefin.arrowColor");
        if (x23.truthy()) break :blk_x23 x23;
        break :blk_x23 t.get("lineColor");
    });
    try t.set("cynefin.arrowWidth", blk_x24: {
        const x24 = t.get("cynefin.arrowWidth");
        if (x24.truthy()) break :blk_x24 x24;
        break :blk_x24 V{ .n = 2 };
    });
    try t.set("cynefin.complexBg", blk_x25: {
        const x25 = t.get("cynefin.complexBg");
        if (x25.truthy()) break :blk_x25 x25;
        break :blk_x25 V{ .s = "#C8E6C9" };
    });
    try t.set("cynefin.complicatedBg", blk_x26: {
        const x26 = t.get("cynefin.complicatedBg");
        if (x26.truthy()) break :blk_x26 x26;
        break :blk_x26 V{ .s = "#DCEDC8" };
    });
    try t.set("cynefin.chaoticBg", blk_x27: {
        const x27 = t.get("cynefin.chaoticBg");
        if (x27.truthy()) break :blk_x27 x27;
        break :blk_x27 V{ .s = "#FFE0B2" };
    });
    try t.set("cynefin.clearBg", blk_x28: {
        const x28 = t.get("cynefin.clearBg");
        if (x28.truthy()) break :blk_x28 x28;
        break :blk_x28 V{ .s = "#FFF9C4" };
    });
    try t.set("cynefin.confusionBg", blk_x29: {
        const x29 = t.get("cynefin.confusionBg");
        if (x29.truthy()) break :blk_x29 x29;
        break :blk_x29 V{ .s = "#D7CCC8" };
    });
    try t.set("cynefin.textColor", blk_x30: {
        const x30 = t.get("cynefin.textColor");
        if (x30.truthy()) break :blk_x30 x30;
        break :blk_x30 t.get("textColor");
    });
    try t.set("cynefin.labelColor", blk_x31: {
        const x31 = t.get("cynefin.labelColor");
        if (x31.truthy()) break :blk_x31 x31;
        break :blk_x31 t.get("primaryTextColor");
    });
    if (!t.get("quadrant1Fill").truthy()) try t.set("quadrant1Fill", t.get("primaryColor"));
    if (!t.get("quadrant2Fill").truthy()) try t.set("quadrant2Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 5, .g = 5, .b = 5 }));
    if (!t.get("quadrant3Fill").truthy()) try t.set("quadrant3Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 10, .g = 10, .b = 10 }));
    if (!t.get("quadrant4Fill").truthy()) try t.set("quadrant4Fill", try c.adjust(t, t.get("primaryColor"), .{ .r = 15, .g = 15, .b = 15 }));
    if (!t.get("quadrant1TextFill").truthy()) try t.set("quadrant1TextFill", t.get("primaryTextColor"));
    if (!t.get("quadrant2TextFill").truthy()) try t.set("quadrant2TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -5, .g = -5, .b = -5 }));
    if (!t.get("quadrant3TextFill").truthy()) try t.set("quadrant3TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -10, .g = -10, .b = -10 }));
    if (!t.get("quadrant4TextFill").truthy()) try t.set("quadrant4TextFill", try c.adjust(t, t.get("primaryTextColor"), .{ .r = -15, .g = -15, .b = -15 }));
    try t.set("quadrantPointFill", if ((blk_x32: {
        const x32 = t.get("quadrantPointFill");
        if (x32.truthy()) break :blk_x32 x32;
        break :blk_x32 V{ .b = try c.isDark(t.get("quadrant1Fill")) };
    }).truthy()) try c.lighten(t, t.get("quadrant1Fill"), std.math.nan(f64)) else try c.darken(t, t.get("quadrant1Fill"), std.math.nan(f64)));
    if (!t.get("quadrantPointTextFill").truthy()) try t.set("quadrantPointTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantXAxisTextFill").truthy()) try t.set("quadrantXAxisTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantYAxisTextFill").truthy()) try t.set("quadrantYAxisTextFill", t.get("primaryTextColor"));
    if (!t.get("quadrantInternalBorderStrokeFill").truthy()) try t.set("quadrantInternalBorderStrokeFill", t.get("primaryBorderColor"));
    if (!t.get("quadrantExternalBorderStrokeFill").truthy()) try t.set("quadrantExternalBorderStrokeFill", t.get("primaryBorderColor"));
    if (!t.get("quadrantTitleFill").truthy()) try t.set("quadrantTitleFill", t.get("primaryTextColor"));
    try t.set("packet.startByteColor", t.get("primaryTextColor"));
    try t.set("packet.endByteColor", t.get("primaryTextColor"));
    try t.set("packet.labelColor", t.get("primaryTextColor"));
    try t.set("packet.titleColor", t.get("primaryTextColor"));
    try t.set("packet.blockStrokeColor", t.get("primaryTextColor"));
    try t.set("packet.blockFillColor", t.get("mainBkg"));
    try t.set("radar.axisColor", blk_x33: {
        const x33 = t.get("radar.axisColor");
        if (x33.truthy()) break :blk_x33 x33;
        break :blk_x33 t.get("lineColor");
    });
    try t.set("radar.axisStrokeWidth", blk_x34: {
        const x34 = t.get("radar.axisStrokeWidth");
        if (x34.truthy()) break :blk_x34 x34;
        break :blk_x34 V{ .n = 2 };
    });
    try t.set("radar.axisLabelFontSize", blk_x35: {
        const x35 = t.get("radar.axisLabelFontSize");
        if (x35.truthy()) break :blk_x35 x35;
        break :blk_x35 V{ .n = 12 };
    });
    try t.set("radar.curveOpacity", blk_x36: {
        const x36 = t.get("radar.curveOpacity");
        if (x36.truthy()) break :blk_x36 x36;
        break :blk_x36 V{ .n = 0.5 };
    });
    try t.set("radar.curveStrokeWidth", blk_x37: {
        const x37 = t.get("radar.curveStrokeWidth");
        if (x37.truthy()) break :blk_x37 x37;
        break :blk_x37 V{ .n = 2 };
    });
    try t.set("radar.graticuleColor", blk_x38: {
        const x38 = t.get("radar.graticuleColor");
        if (x38.truthy()) break :blk_x38 x38;
        break :blk_x38 V{ .s = "#DEDEDE" };
    });
    try t.set("radar.graticuleStrokeWidth", blk_x39: {
        const x39 = t.get("radar.graticuleStrokeWidth");
        if (x39.truthy()) break :blk_x39 x39;
        break :blk_x39 V{ .n = 1 };
    });
    try t.set("radar.graticuleOpacity", blk_x40: {
        const x40 = t.get("radar.graticuleOpacity");
        if (x40.truthy()) break :blk_x40 x40;
        break :blk_x40 V{ .n = 0.3 };
    });
    try t.set("radar.legendBoxSize", blk_x41: {
        const x41 = t.get("radar.legendBoxSize");
        if (x41.truthy()) break :blk_x41 x41;
        break :blk_x41 V{ .n = 12 };
    });
    try t.set("radar.legendFontSize", blk_x42: {
        const x42 = t.get("radar.legendFontSize");
        if (x42.truthy()) break :blk_x42 x42;
        break :blk_x42 V{ .n = 12 };
    });
    if (!t.get("wardleyEvolutionColor").truthy()) try t.set("wardleyEvolutionColor", V{ .s = "#dc3545" });
    try t.set("wardley.backgroundColor", blk_x43: {
        const x43 = t.get("wardley.backgroundColor");
        if (x43.truthy()) break :blk_x43 x43;
        break :blk_x43 t.get("background");
    });
    try t.set("wardley.axisColor", blk_x44: {
        const x44 = t.get("wardley.axisColor");
        if (x44.truthy()) break :blk_x44 x44;
        break :blk_x44 t.get("lineColor");
    });
    try t.set("wardley.axisTextColor", blk_x45: {
        const x45 = t.get("wardley.axisTextColor");
        if (x45.truthy()) break :blk_x45 x45;
        break :blk_x45 t.get("primaryTextColor");
    });
    try t.set("wardley.gridColor", blk_x46: {
        const x46 = t.get("wardley.gridColor");
        if (x46.truthy()) break :blk_x46 x46;
        break :blk_x46 t.get("gridColor");
    });
    try t.set("wardley.componentFill", blk_x47: {
        const x47 = t.get("wardley.componentFill");
        if (x47.truthy()) break :blk_x47 x47;
        break :blk_x47 t.get("background");
    });
    try t.set("wardley.componentStroke", blk_x48: {
        const x48 = t.get("wardley.componentStroke");
        if (x48.truthy()) break :blk_x48 x48;
        break :blk_x48 t.get("lineColor");
    });
    try t.set("wardley.componentLabelColor", blk_x49: {
        const x49 = t.get("wardley.componentLabelColor");
        if (x49.truthy()) break :blk_x49 x49;
        break :blk_x49 t.get("primaryTextColor");
    });
    try t.set("wardley.linkStroke", blk_x50: {
        const x50 = t.get("wardley.linkStroke");
        if (x50.truthy()) break :blk_x50 x50;
        break :blk_x50 t.get("lineColor");
    });
    try t.set("wardley.evolutionStroke", blk_x51: {
        const x51 = t.get("wardley.evolutionStroke");
        if (x51.truthy()) break :blk_x51 x51;
        break :blk_x51 t.get("wardleyEvolutionColor");
    });
    try t.set("wardley.annotationStroke", blk_x52: {
        const x52 = t.get("wardley.annotationStroke");
        if (x52.truthy()) break :blk_x52 x52;
        break :blk_x52 t.get("lineColor");
    });
    try t.set("wardley.annotationTextColor", blk_x53: {
        const x53 = t.get("wardley.annotationTextColor");
        if (x53.truthy()) break :blk_x53 x53;
        break :blk_x53 t.get("primaryTextColor");
    });
    try t.set("wardley.annotationFill", blk_x54: {
        const x54 = t.get("wardley.annotationFill");
        if (x54.truthy()) break :blk_x54 x54;
        break :blk_x54 t.get("background");
    });
    try t.set("xyChart.backgroundColor", blk_x55: {
        const x55 = t.get("xyChart.backgroundColor");
        if (x55.truthy()) break :blk_x55 x55;
        break :blk_x55 t.get("background");
    });
    try t.set("xyChart.titleColor", blk_x56: {
        const x56 = t.get("xyChart.titleColor");
        if (x56.truthy()) break :blk_x56 x56;
        break :blk_x56 t.get("primaryTextColor");
    });
    try t.set("xyChart.dataLabelColor", blk_x57: {
        const x57 = t.get("xyChart.dataLabelColor");
        if (x57.truthy()) break :blk_x57 x57;
        break :blk_x57 t.get("primaryTextColor");
    });
    try t.set("xyChart.legendTextColor", blk_x58: {
        const x58 = t.get("xyChart.legendTextColor");
        if (x58.truthy()) break :blk_x58 x58;
        break :blk_x58 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisTitleColor", blk_x59: {
        const x59 = t.get("xyChart.xAxisTitleColor");
        if (x59.truthy()) break :blk_x59 x59;
        break :blk_x59 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisLabelColor", blk_x60: {
        const x60 = t.get("xyChart.xAxisLabelColor");
        if (x60.truthy()) break :blk_x60 x60;
        break :blk_x60 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisTickColor", blk_x61: {
        const x61 = t.get("xyChart.xAxisTickColor");
        if (x61.truthy()) break :blk_x61 x61;
        break :blk_x61 t.get("primaryTextColor");
    });
    try t.set("xyChart.xAxisLineColor", blk_x62: {
        const x62 = t.get("xyChart.xAxisLineColor");
        if (x62.truthy()) break :blk_x62 x62;
        break :blk_x62 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisTitleColor", blk_x63: {
        const x63 = t.get("xyChart.yAxisTitleColor");
        if (x63.truthy()) break :blk_x63 x63;
        break :blk_x63 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisLabelColor", blk_x64: {
        const x64 = t.get("xyChart.yAxisLabelColor");
        if (x64.truthy()) break :blk_x64 x64;
        break :blk_x64 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisTickColor", blk_x65: {
        const x65 = t.get("xyChart.yAxisTickColor");
        if (x65.truthy()) break :blk_x65 x65;
        break :blk_x65 t.get("primaryTextColor");
    });
    try t.set("xyChart.yAxisLineColor", blk_x66: {
        const x66 = t.get("xyChart.yAxisLineColor");
        if (x66.truthy()) break :blk_x66 x66;
        break :blk_x66 t.get("primaryTextColor");
    });
    try t.set("xyChart.plotColorPalette", blk_x67: {
        const x67 = t.get("xyChart.plotColorPalette");
        if (x67.truthy()) break :blk_x67 x67;
        break :blk_x67 V{ .s = "#CDE498,#FF6B6B,#A0D2DB,#D7BDE2,#F0F0F0,#FFC3A0,#7FD8BE,#FF9A8B,#FAF3E0,#FFF176" };
    });
    if (!t.get("requirementBackground").truthy()) try t.set("requirementBackground", t.get("primaryColor"));
    if (!t.get("requirementBorderColor").truthy()) try t.set("requirementBorderColor", t.get("primaryBorderColor"));
    if (!t.get("requirementBorderSize").truthy()) try t.set("requirementBorderSize", V{ .s = "1" });
    if (!t.get("requirementTextColor").truthy()) try t.set("requirementTextColor", t.get("primaryTextColor"));
    if (!t.get("relationColor").truthy()) try t.set("relationColor", t.get("lineColor"));
    if (!t.get("relationLabelBackground").truthy()) try t.set("relationLabelBackground", t.get("edgeLabelBackground"));
    if (!t.get("relationLabelColor").truthy()) try t.set("relationLabelColor", t.get("actorTextColor"));
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
    if (!t.get("gitBranchLabel0").truthy()) try t.set("gitBranchLabel0", try c.invert(t, t.get("labelTextColor")));
    if (!t.get("gitBranchLabel1").truthy()) try t.set("gitBranchLabel1", t.get("labelTextColor"));
    if (!t.get("gitBranchLabel2").truthy()) try t.set("gitBranchLabel2", t.get("labelTextColor"));
    if (!t.get("gitBranchLabel3").truthy()) try t.set("gitBranchLabel3", try c.invert(t, t.get("labelTextColor")));
    if (!t.get("gitBranchLabel4").truthy()) try t.set("gitBranchLabel4", t.get("labelTextColor"));
    if (!t.get("gitBranchLabel5").truthy()) try t.set("gitBranchLabel5", t.get("labelTextColor"));
    if (!t.get("gitBranchLabel6").truthy()) try t.set("gitBranchLabel6", t.get("labelTextColor"));
    if (!t.get("gitBranchLabel7").truthy()) try t.set("gitBranchLabel7", t.get("labelTextColor"));
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
