const std = @import("std");
const lexer = @import("lexer.zig");
const tree = @import("tree.zig");

const Class = tree.Class;
const Font = tree.Font;
const Style = tree.Style;

pub const Cmd = enum {
    sqrt,
    root,
    left,
    right,
    middle,
    begin,
    end,
    limits,
    nolimits,
    mathop,
    operatorname,
    hbox,
    fbox,
    color,
    textcolor,
    colorbox,
    fcolorbox,
    newcommand,
    def,
    let,
    not,
    dots,
    cdots,
    vdots,
    colon,
    overset,
    underset,
    overunderset,
    xrightarrow,
    xleftarrow,
    boldsymbol,
    phantom,
    vphantom,
    hphantom,
    smash,
    rule,
    rule_big,
    space_big,
    mathchoice,
    tag,
    label,
    nonumber,
    cr,
    cr_plain,
    newline,
    hline,
    ctlspace,
    ignore,
    raise,
    lower,
    moveleft,
    moveright,
    llap,
    rlap,
    vcenter,
    nonscript,
    strut,
    buildrel,
    framebox,
    hfill,
    hdashline,
    matrix_tex,
    pmatrix_tex,
    cases_tex,
    eqalign,
    displaylines,
    ref,
    eqref,
    mmltoken,
    uproot,
    leftroot,
    sideset,
    declareop,
    shoveleft,
    shoveright,
    newenvironment,
    cancel,
    bcancel,
    xcancel,
    cancelto,
    enclose,
    bbox,
    braket,
    set,
    braket_big,
    set_big,
    xarrowcp,
    newextarrow,
    html,
    require,
    unicode,
    verb,
    definecolor,
    toggle,
    mathtip,
    ce,
    pu,
    proof_cmd,
    cd_size,
    bbbk,
    iiiint,
};

pub const FracSpec = struct {
    style: ?Style = null,
    open: ?u21 = null,
    close: ?u21 = null,
    thin: bool = false,
    generic: bool = false,
    cont: bool = false,
};

pub const OverSpec = struct {
    open: ?u21 = null,
    close: ?u21 = null,
    atop: bool = false,
    above: bool = false,
    delims: bool = false,
};

pub const Spec = union(enum) {
    cmd: Cmd,
    mathfont: Font,
    setfont: Font,
    textfont: Font,
    setsize: f32,
    setstyle: Style,
    namedfn: []const u8,
    namedop: []const u8,
    accent: struct { cp: u21, wide: bool },
    over_under: struct { cp: u21, over: bool, brace: bool },
    spacer: f32,
    hskip,
    big: struct { class: Class, size: u8 },
    atom_class: Class,
    frac: FracSpec,
    over: OverSpec,
    xarrow: u21,
};

fn c(v: Cmd) Spec {
    return .{ .cmd = v };
}
fn mf(f: Font) Spec {
    return .{ .mathfont = f };
}
fn sf(f: Font) Spec {
    return .{ .setfont = f };
}
fn tf(f: Font) Spec {
    return .{ .textfont = f };
}
fn sz(v: f32) Spec {
    return .{ .setsize = v };
}
fn ss(v: Style) Spec {
    return .{ .setstyle = v };
}
fn nf(n: []const u8) Spec {
    return .{ .namedfn = n };
}
fn no(n: []const u8) Spec {
    return .{ .namedop = n };
}
fn ac(cp: u21, wide: bool) Spec {
    return .{ .accent = .{ .cp = cp, .wide = wide } };
}
fn ou(cp: u21, over: bool, brace: bool) Spec {
    return .{ .over_under = .{ .cp = cp, .over = over, .brace = brace } };
}
fn sp(w: f32) Spec {
    return .{ .spacer = w };
}
fn big(class: Class, size: u8) Spec {
    return .{ .big = .{ .class = class, .size = size } };
}
fn cl(k: Class) Spec {
    return .{ .atom_class = k };
}
fn fr(f: FracSpec) Spec {
    return .{ .frac = f };
}
fn xa(cp: u21) Spec {
    return .{ .xarrow = cp };
}
fn ov(o: OverSpec) Spec {
    return .{ .over = o };
}

pub const specs = std.StaticStringMap(Spec).initComptime(.{
    .{ "frac", fr(.{}) },
    .{ "dfrac", fr(.{ .style = .display }) },
    .{ "tfrac", fr(.{ .style = .text }) },
    .{ "binom", fr(.{ .open = '(', .close = ')', .thin = true }) },
    .{ "dbinom", fr(.{ .open = '(', .close = ')', .thin = true, .style = .display }) },
    .{ "tbinom", fr(.{ .open = '(', .close = ')', .thin = true, .style = .text }) },
    .{ "genfrac", fr(.{ .generic = true }) },
    .{ "cfrac", fr(.{ .cont = true }) },
    .{ "over", ov(.{}) },
    .{ "atop", ov(.{ .atop = true }) },
    .{ "choose", ov(.{ .open = '(', .close = ')', .atop = true }) },
    .{ "brace", ov(.{ .open = '{', .close = '}', .atop = true }) },
    .{ "brack", ov(.{ .open = '[', .close = ']', .atop = true }) },
    .{ "above", ov(.{ .above = true }) },
    .{ "overwithdelims", ov(.{ .delims = true }) },
    .{ "atopwithdelims", ov(.{ .delims = true, .atop = true }) },
    .{ "abovewithdelims", ov(.{ .delims = true, .above = true }) },
    .{ "sqrt", c(.sqrt) },
    .{ "root", c(.root) },
    .{ "left", c(.left) },
    .{ "right", c(.right) },
    .{ "middle", c(.middle) },
    .{ "begin", c(.begin) },
    .{ "end", c(.end) },
    .{ "limits", c(.limits) },
    .{ "nolimits", c(.nolimits) },
    .{ "mathop", c(.mathop) },
    .{ "operatorname", c(.operatorname) },
    .{ "hbox", c(.hbox) },
    .{ "mbox", c(.hbox) },
    .{ "fbox", c(.fbox) },
    .{ "color", c(.color) },
    .{ "textcolor", c(.textcolor) },
    .{ "colorbox", c(.colorbox) },
    .{ "fcolorbox", c(.fcolorbox) },
    .{ "newcommand", c(.newcommand) },
    .{ "renewcommand", c(.newcommand) },
    .{ "def", c(.def) },
    .{ "let", c(.let) },
    .{ "not", c(.not) },
    .{ "dots", c(.dots) },
    .{ "cdots", c(.cdots) },
    .{ "vdots", c(.vdots) },
    .{ "colon", c(.colon) },
    .{ "overset", c(.overset) },
    .{ "underset", c(.underset) },
    .{ "overunderset", c(.overunderset) },
    .{ "xrightarrow", c(.xrightarrow) },
    .{ "xleftarrow", c(.xleftarrow) },
    .{ "boldsymbol", c(.boldsymbol) },
    .{ "phantom", c(.phantom) },
    .{ "vphantom", c(.vphantom) },
    .{ "hphantom", c(.hphantom) },
    .{ "smash", c(.smash) },
    .{ "rule", c(.rule) },
    .{ "Rule", c(.rule_big) },
    .{ "Space", c(.space_big) },
    .{ "mathchoice", c(.mathchoice) },
    .{ "tag", c(.tag) },
    .{ "label", c(.label) },
    .{ "nonumber", c(.nonumber) },
    .{ "notag", c(.nonumber) },
    .{ "\\", c(.cr) },
    .{ "cr", c(.cr_plain) },
    .{ "newline", c(.newline) },
    .{ "hline", c(.hline) },
    .{ " ", c(.ctlspace) },
    .{ "space", c(.ctlspace) },
    .{ "nobreakspace", c(.ctlspace) },
    .{ "/", c(.ignore) },
    .{ "-", c(.ignore) },
    .{ "allowbreak", c(.ignore) },
    .{ "nobreak", c(.ignore) },
    .{ "raise", c(.raise) },
    .{ "lower", c(.lower) },
    .{ "moveleft", c(.moveleft) },
    .{ "moveright", c(.moveright) },
    .{ "llap", c(.llap) },
    .{ "rlap", c(.rlap) },
    .{ "vcenter", c(.vcenter) },
    .{ "nonscript", c(.nonscript) },
    .{ "strut", c(.strut) },
    .{ "buildrel", c(.buildrel) },
    .{ "framebox", c(.framebox) },
    .{ "hdashline", c(.hdashline) },
    .{ "ref", c(.ref) },
    .{ "eqref", c(.eqref) },
    .{ "uproot", c(.uproot) },
    .{ "leftroot", c(.leftroot) },
    .{ "sideset", c(.sideset) },
    .{ "shoveleft", c(.shoveleft) },
    .{ "shoveright", c(.shoveright) },
    .{ "newenvironment", c(.newenvironment) },
    .{ "cancel", c(.cancel) },
    .{ "bcancel", c(.bcancel) },
    .{ "xcancel", c(.xcancel) },
    .{ "cancelto", c(.cancelto) },
    .{ "enclose", c(.enclose) },
    .{ "bbox", c(.bbox) },
    .{ "require", c(.require) },
    .{ "unicode", c(.unicode) },
    .{ "verb", c(.verb) },
    .{ "definecolor", c(.definecolor) },
    .{ "toggle", c(.toggle) },
    .{ "mathtip", c(.mathtip) },
    .{ "ce", c(.ce) },
    .{ "pu", c(.pu) },
    .{ "iiiint", c(.iiiint) },
    .{ "hfill", c(.hfill) },
    .{ "hfil", c(.hfill) },
    .{ "hfilll", c(.hfill) },
    .{ "matrix", c(.matrix_tex) },
    .{ "array", c(.matrix_tex) },
    .{ "pmatrix", c(.pmatrix_tex) },
    .{ "cases", c(.cases_tex) },
    .{ "eqalign", c(.eqalign) },
    .{ "eqalignno", c(.eqalign) },
    .{ "leqalignno", c(.eqalign) },
    .{ "displaylines", c(.displaylines) },
    .{ "mmlToken", c(.mmltoken) },
    .{ "DeclareMathOperator", c(.declareop) },
    .{ "renewenvironment", c(.newenvironment) },
    .{ "braket", c(.braket) },
    .{ "set", c(.set) },
    .{ "Braket", c(.braket_big) },
    .{ "Set", c(.set_big) },
    .{ "xtwoheadrightarrow", xa(0x21a0) },
    .{ "xtwoheadleftarrow", xa(0x219e) },
    .{ "xmapsto", xa(0x21a6) },
    .{ "xlongequal", xa(0x3d) },
    .{ "xtofrom", xa(0x21c4) },
    .{ "Newextarrow", c(.newextarrow) },
    .{ "xleftrightarrow", xa(0x2194) },
    .{ "xrightleftharpoons", xa(0x21cc) },
    .{ "xRightleftharpoons", xa(0x21cc) },
    .{ "xLeftrightharpoons", xa(0x21cc) },
    .{ "xarrowcp", c(.xarrowcp) },
    .{ "href", c(.html) },
    .{ "class", c(.html) },
    .{ "style", c(.html) },
    .{ "cssId", c(.html) },
    .{ "AxiomC", c(.proof_cmd) },
    .{ "AXC", c(.proof_cmd) },
    .{ "Axiom", c(.proof_cmd) },
    .{ "UnaryInfC", c(.proof_cmd) },
    .{ "UIC", c(.proof_cmd) },
    .{ "UnaryInf", c(.proof_cmd) },
    .{ "BinaryInfC", c(.proof_cmd) },
    .{ "BIC", c(.proof_cmd) },
    .{ "BinaryInf", c(.proof_cmd) },
    .{ "TrinaryInfC", c(.proof_cmd) },
    .{ "TIC", c(.proof_cmd) },
    .{ "TrinaryInf", c(.proof_cmd) },
    .{ "QuaternaryInfC", c(.proof_cmd) },
    .{ "QuaternaryInf", c(.proof_cmd) },
    .{ "QuinaryInfC", c(.proof_cmd) },
    .{ "QuinaryInf", c(.proof_cmd) },
    .{ "RightLabel", c(.proof_cmd) },
    .{ "RL", c(.proof_cmd) },
    .{ "LeftLabel", c(.proof_cmd) },
    .{ "LL", c(.proof_cmd) },
    .{ "noLine", c(.proof_cmd) },
    .{ "singleLine", c(.proof_cmd) },
    .{ "solidLine", c(.proof_cmd) },
    .{ "dashedLine", c(.proof_cmd) },
    .{ "alwaysNoLine", c(.proof_cmd) },
    .{ "alwaysSingleLine", c(.proof_cmd) },
    .{ "alwaysSolidLine", c(.proof_cmd) },
    .{ "alwaysDashedLine", c(.proof_cmd) },
    .{ "rootAtTop", c(.proof_cmd) },
    .{ "alwaysRootAtTop", c(.proof_cmd) },
    .{ "rootAtBottom", c(.proof_cmd) },
    .{ "alwaysRootAtBottom", c(.proof_cmd) },
    .{ "fCenter", c(.proof_cmd) },
    .{ "minCDarrowwidth", c(.cd_size) },
    .{ "minCDarrowheight", c(.cd_size) },
    .{ "Bbbk", c(.bbbk) },
    .{ "oldstyle", sf(.oldstyle) },
    .{ "symrm", mf(.rm) },
    .{ "symup", mf(.rm) },
    .{ "symnormal", mf(.normal) },
    .{ "symbf", mf(.bf) },
    .{ "symbfup", mf(.bf) },
    .{ "symit", mf(.it) },
    .{ "symbfit", mf(.bfit) },
    .{ "symbb", mf(.bb) },
    .{ "symfrak", mf(.frak) },
    .{ "symbffrak", mf(.bffrak) },
    .{ "symscr", mf(.scr) },
    .{ "symbfscr", mf(.bfscr) },
    .{ "symsf", mf(.sf) },
    .{ "symsfup", mf(.sf) },
    .{ "symbfsf", mf(.sfbf) },
    .{ "symbfsfup", mf(.sfbf) },
    .{ "symsfit", mf(.sfit) },
    .{ "symbfsfit", mf(.sfbfit) },
    .{ "symtt", mf(.tt) },
    .{ "symcal", mf(.cal) },
    .{ "symbfcal", mf(.bfcal) },
    .{ "displaystyle", ss(.display) },
    .{ "textstyle", ss(.text) },
    .{ "scriptstyle", ss(.script) },
    .{ "scriptscriptstyle", ss(.scriptscript) },
    .{ "rm", sf(.rm) },
    .{ "mit", sf(.it) },
    .{ "it", sf(.it) },
    .{ "bf", sf(.bf) },
    .{ "sf", sf(.sf) },
    .{ "tt", sf(.tt) },
    .{ "cal", sf(.cal) },
    .{ "scr", sf(.scr) },
    .{ "frak", sf(.frak) },
    .{ "bbFont", sf(.bb) },
    .{ "mathrm", mf(.rm) },
    .{ "mathup", mf(.rm) },
    .{ "mathnormal", mf(.normal) },
    .{ "mathbf", mf(.bf) },
    .{ "mathbfup", mf(.bf) },
    .{ "mathit", mf(.it) },
    .{ "mathbfit", mf(.bfit) },
    .{ "mathbb", mf(.bb) },
    .{ "Bbb", mf(.bb) },
    .{ "mathfrak", mf(.frak) },
    .{ "mathbffrak", mf(.bffrak) },
    .{ "mathscr", mf(.scr) },
    .{ "mathbfscr", mf(.bfscr) },
    .{ "mathsf", mf(.sf) },
    .{ "mathsfup", mf(.sf) },
    .{ "mathbfsf", mf(.sfbf) },
    .{ "mathbfsfup", mf(.sfbf) },
    .{ "mathsfit", mf(.sfit) },
    .{ "mathbfsfit", mf(.sfbfit) },
    .{ "mathtt", mf(.tt) },
    .{ "mathcal", mf(.cal) },
    .{ "mathbfcal", mf(.bfcal) },
    .{ "text", tf(.default) },
    .{ "textnormal", tf(.default) },
    .{ "textrm", tf(.rm) },
    .{ "textup", tf(.rm) },
    .{ "textit", tf(.it) },
    .{ "textbf", tf(.bf) },
    .{ "textsf", tf(.sf) },
    .{ "texttt", tf(.tt) },
    .{ "tiny", sz(0.5) },
    .{ "Tiny", sz(0.6) },
    .{ "scriptsize", sz(0.7) },
    .{ "small", sz(0.85) },
    .{ "normalsize", sz(1.0) },
    .{ "large", sz(1.2) },
    .{ "Large", sz(1.44) },
    .{ "LARGE", sz(1.73) },
    .{ "huge", sz(2.07) },
    .{ "Huge", sz(2.49) },
    .{ "arcsin", nf("arcsin") },
    .{ "arccos", nf("arccos") },
    .{ "arctan", nf("arctan") },
    .{ "arg", nf("arg") },
    .{ "cos", nf("cos") },
    .{ "cosh", nf("cosh") },
    .{ "cot", nf("cot") },
    .{ "coth", nf("coth") },
    .{ "csc", nf("csc") },
    .{ "deg", nf("deg") },
    .{ "dim", nf("dim") },
    .{ "exp", nf("exp") },
    .{ "hom", nf("hom") },
    .{ "ker", nf("ker") },
    .{ "lg", nf("lg") },
    .{ "ln", nf("ln") },
    .{ "log", nf("log") },
    .{ "sec", nf("sec") },
    .{ "sin", nf("sin") },
    .{ "sinh", nf("sinh") },
    .{ "tan", nf("tan") },
    .{ "tanh", nf("tanh") },
    .{ "det", no("det") },
    .{ "gcd", no("gcd") },
    .{ "inf", no("inf") },
    .{ "lim", no("lim") },
    .{ "liminf", no("lim inf") },
    .{ "limsup", no("lim sup") },
    .{ "max", no("max") },
    .{ "min", no("min") },
    .{ "Pr", no("Pr") },
    .{ "sup", no("sup") },
    .{ "injlim", no("inj lim") },
    .{ "projlim", no("proj lim") },
    .{ "acute", ac(0xb4, false) },
    .{ "grave", ac(0x60, false) },
    .{ "ddot", ac(0xa8, false) },
    .{ "tilde", ac(0x7e, false) },
    .{ "bar", ac(0xaf, false) },
    .{ "breve", ac(0x2d8, false) },
    .{ "check", ac(0x2c7, false) },
    .{ "hat", ac(0x5e, false) },
    .{ "vec", ac(0x2192, false) },
    .{ "dot", ac(0x2d9, false) },
    .{ "widetilde", ac(0x7e, true) },
    .{ "widehat", ac(0x5e, true) },
    .{ "mathring", ac(0x2da, false) },
    .{ "dddot", ac(0x20db, false) },
    .{ "ddddot", ac(0x20dc, false) },
    .{ "overline", ou(0x2015, true, false) },
    .{ "underline", ou(0x2015, false, false) },
    .{ "overbrace", ou(0x23de, true, true) },
    .{ "underbrace", ou(0x23df, false, true) },
    .{ "overparen", ou(0x23dc, true, false) },
    .{ "underparen", ou(0x23dd, false, false) },
    .{ "overrightarrow", ou(0x2192, true, false) },
    .{ "underrightarrow", ou(0x2192, false, false) },
    .{ "overleftarrow", ou(0x2190, true, false) },
    .{ "underleftarrow", ou(0x2190, false, false) },
    .{ "overleftrightarrow", ou(0x2194, true, false) },
    .{ "underleftrightarrow", ou(0x2194, false, false) },
    .{ ",", sp(3.0 / 18.0) },
    .{ ":", sp(4.0 / 18.0) },
    .{ ">", sp(4.0 / 18.0) },
    .{ ";", sp(5.0 / 18.0) },
    .{ "!", sp(-3.0 / 18.0) },
    .{ "thinspace", sp(3.0 / 18.0) },
    .{ "negthinspace", sp(-3.0 / 18.0) },
    .{ "negmedspace", sp(-4.0 / 18.0) },
    .{ "negthickspace", sp(-5.0 / 18.0) },
    .{ "enspace", sp(0.5) },
    .{ "quad", sp(1) },
    .{ "qquad", sp(2) },
    .{ "hskip", .hskip },
    .{ "hspace", .hskip },
    .{ "kern", .hskip },
    .{ "mskip", .hskip },
    .{ "mspace", .hskip },
    .{ "mkern", .hskip },
    .{ "big", big(.ord, 1) },
    .{ "Big", big(.ord, 2) },
    .{ "bigg", big(.ord, 3) },
    .{ "Bigg", big(.ord, 4) },
    .{ "bigl", big(.open, 1) },
    .{ "Bigl", big(.open, 2) },
    .{ "biggl", big(.open, 3) },
    .{ "Biggl", big(.open, 4) },
    .{ "bigr", big(.close, 1) },
    .{ "Bigr", big(.close, 2) },
    .{ "biggr", big(.close, 3) },
    .{ "Biggr", big(.close, 4) },
    .{ "bigm", big(.rel, 1) },
    .{ "Bigm", big(.rel, 2) },
    .{ "biggm", big(.rel, 3) },
    .{ "Biggm", big(.rel, 4) },
    .{ "mathord", cl(.ord) },
    .{ "mathbin", cl(.bin) },
    .{ "mathrel", cl(.rel) },
    .{ "mathopen", cl(.open) },
    .{ "mathclose", cl(.close) },
    .{ "mathpunct", cl(.punct) },
    .{ "mathinner", cl(.inner) },
});

pub const Extra = struct { cp: u21, class: Class, italic: bool = false, ams: bool = false };

fn ex(cp: u21, class: Class, italic: bool, ams: bool) Extra {
    return .{ .cp = cp, .class = class, .italic = italic, .ams = ams };
}

/// Names MathJax defines that KaTeX's symbol file spells differently or leaves to macros.
pub const extras = std.StaticStringMap(Extra).initComptime(.{
    .{ "imath", ex(0x131, .ord, true, false) },
    .{ "jmath", ex(0x237, .ord, true, false) },
    .{ "varGamma", ex(0x393, .ord, true, false) },
    .{ "varDelta", ex(0x394, .ord, true, false) },
    .{ "varTheta", ex(0x398, .ord, true, false) },
    .{ "varLambda", ex(0x39b, .ord, true, false) },
    .{ "varXi", ex(0x39e, .ord, true, false) },
    .{ "varPi", ex(0x3a0, .ord, true, false) },
    .{ "varSigma", ex(0x3a3, .ord, true, false) },
    .{ "varUpsilon", ex(0x3a5, .ord, true, false) },
    .{ "varPhi", ex(0x3a6, .ord, true, false) },
    .{ "varPsi", ex(0x3a8, .ord, true, false) },
    .{ "varOmega", ex(0x3a9, .ord, true, false) },
    .{ "nleqslant", ex(0x2a87, .rel, false, true) },
    .{ "ngeqslant", ex(0x2a88, .rel, false, true) },
    .{ "nleqq", ex(0x2270, .rel, false, true) },
    .{ "ngeqq", ex(0x2271, .rel, false, true) },
    .{ "lvertneqq", ex(0x2268, .rel, false, true) },
    .{ "gvertneqq", ex(0x2269, .rel, false, true) },
    .{ "nshortmid", ex(0x2224, .rel, false, true) },
    .{ "nshortparallel", ex(0x2226, .rel, false, true) },
    .{ "nsubseteqq", ex(0x2288, .rel, false, true) },
    .{ "nsupseteqq", ex(0x2289, .rel, false, true) },
    .{ "varsubsetneq", ex(0x228a, .rel, false, true) },
    .{ "varsupsetneq", ex(0x228b, .rel, false, true) },
    .{ "varsubsetneqq", ex(0x2acb, .rel, false, true) },
    .{ "varsupsetneqq", ex(0x2acc, .rel, false, true) },
    .{ "ulcorner", ex(0x231c, .open, false, true) },
    .{ "urcorner", ex(0x231d, .close, false, true) },
    .{ "llcorner", ex(0x231e, .open, false, true) },
    .{ "lrcorner", ex(0x231f, .close, false, true) },
    .{ "arrowvert", ex(0x23d0, .ord, false, false) },
    .{ "Arrowvert", ex(0x2016, .ord, false, false) },
    .{ "bracevert", ex(0x23aa, .ord, false, false) },
    .{ "divsymbol", ex(0xf7, .bin, false, false) },
    .{ "notChar", ex(0x29f8, .rel, false, false) },
});

/// Code points where MathJax's table differs from KaTeX's; GitHub draws MathJax's.
pub const mathjax_cp = std.StaticStringMap(u21).initComptime(.{
    .{ "backslash", 0x2216 },
    .{ "vert", 0x7c },
    .{ "lvert", 0x7c },
    .{ "rvert", 0x7c },
    .{ "|", 0x2016 },
    .{ "Vert", 0x2016 },
    .{ "lVert", 0x2016 },
    .{ "rVert", 0x2016 },
    .{ "blacktriangle", 0x25b4 },
    .{ "blacktriangledown", 0x25be },
    .{ "blacktriangleleft", 0x25c2 },
    .{ "blacktriangleright", 0x25b8 },
    .{ "square", 0x25fb },
    .{ "Box", 0x25fb },
    .{ "blacksquare", 0x25fc },
    .{ "ncong", 0x2247 },
});

pub const ProofLine = enum { solid, none, dashed };

pub const ProofCmd = union(enum) {
    axiom,
    axiom_f,
    inference: u8,
    inference_f: u8,
    label_right,
    label_left,
    line: struct { style: ProofLine, always: bool },
    root_top: bool,
    fcenter,
};

pub fn proofCmd(name: []const u8) ?ProofCmd {
    const map = std.StaticStringMap(ProofCmd).initComptime(.{
        .{ "AxiomC", ProofCmd.axiom },
        .{ "AXC", ProofCmd.axiom },
        .{ "Axiom", ProofCmd.axiom_f },
        .{ "UnaryInfC", ProofCmd{ .inference = 1 } },
        .{ "UIC", ProofCmd{ .inference = 1 } },
        .{ "BinaryInfC", ProofCmd{ .inference = 2 } },
        .{ "BIC", ProofCmd{ .inference = 2 } },
        .{ "TrinaryInfC", ProofCmd{ .inference = 3 } },
        .{ "TIC", ProofCmd{ .inference = 3 } },
        .{ "QuaternaryInfC", ProofCmd{ .inference = 4 } },
        .{ "QuinaryInfC", ProofCmd{ .inference = 5 } },
        .{ "UnaryInf", ProofCmd{ .inference_f = 1 } },
        .{ "BinaryInf", ProofCmd{ .inference_f = 2 } },
        .{ "TrinaryInf", ProofCmd{ .inference_f = 3 } },
        .{ "QuaternaryInf", ProofCmd{ .inference_f = 4 } },
        .{ "QuinaryInf", ProofCmd{ .inference_f = 5 } },
        .{ "RightLabel", ProofCmd.label_right },
        .{ "RL", ProofCmd.label_right },
        .{ "LeftLabel", ProofCmd.label_left },
        .{ "LL", ProofCmd.label_left },
        .{ "noLine", ProofCmd{ .line = .{ .style = .none, .always = false } } },
        .{ "singleLine", ProofCmd{ .line = .{ .style = .solid, .always = false } } },
        .{ "solidLine", ProofCmd{ .line = .{ .style = .solid, .always = false } } },
        .{ "dashedLine", ProofCmd{ .line = .{ .style = .dashed, .always = false } } },
        .{ "alwaysNoLine", ProofCmd{ .line = .{ .style = .none, .always = true } } },
        .{ "alwaysSingleLine", ProofCmd{ .line = .{ .style = .solid, .always = true } } },
        .{ "alwaysSolidLine", ProofCmd{ .line = .{ .style = .solid, .always = true } } },
        .{ "alwaysDashedLine", ProofCmd{ .line = .{ .style = .dashed, .always = true } } },
        .{ "rootAtTop", ProofCmd{ .root_top = true } },
        .{ "alwaysRootAtTop", ProofCmd{ .root_top = true } },
        .{ "rootAtBottom", ProofCmd{ .root_top = false } },
        .{ "alwaysRootAtBottom", ProofCmd{ .root_top = false } },
        .{ "fCenter", ProofCmd.fcenter },
    });
    return map.get(name);
}

pub const ArgKind = enum { none, cols, bracket_cols, bracket, number };

pub const EnvSpec = struct {
    kind: tree.ArrayKind,
    open: ?u21 = null,
    close: ?u21 = null,
    style: Style = .text,
    col_gap: [2]f32 = .{ 1, 1 },
    row_gap: f32 = 4.0 / 12.0,
    align_: [2]tree.Align = .{ .c, .c },
    repeat: bool = true,
    arg: ArgKind = .none,
    bracket_first: bool = false,
    eqn: bool = false,
    plain: bool = false,
    proof: bool = false,
    fixed: []const tree.Align = &.{},
    pairs_check: bool = false,
};

const align_rl: EnvSpec = .{ .kind = .align_eq, .style = .display, .col_gap = .{ 0, 2 }, .row_gap = 0.25, .align_ = .{ .r, .l }, .eqn = true };
const gather_env: EnvSpec = .{ .kind = .gather, .style = .display, .row_gap = 0.25, .eqn = true };
const alignat_env: EnvSpec = .{ .kind = .align_eq, .style = .display, .col_gap = .{ 0, 0 }, .row_gap = 0.25, .align_ = .{ .r, .l }, .eqn = true, .arg = .number };
const multline_env: EnvSpec = .{ .kind = .multline, .style = .display, .row_gap = 0.5, .eqn = true };
const eqnarray_env: EnvSpec = .{ .kind = .eqnarray, .style = .display, .col_gap = .{ 0, 5.0 / 18.0 }, .row_gap = 0.25, .fixed = &.{ .r, .c, .l }, .eqn = true };
const xalignat_env: EnvSpec = .{ .kind = .align_eq, .style = .display, .col_gap = .{ 0, 0 }, .row_gap = 0.25, .align_ = .{ .r, .l }, .eqn = true, .arg = .number, .pairs_check = true };
const flalign_env: EnvSpec = .{ .kind = .align_eq, .style = .display, .col_gap = .{ 0, 0 }, .row_gap = 0.25, .align_ = .{ .r, .l }, .eqn = true };
const equation_env: EnvSpec = .{ .kind = .matrix, .plain = true, .eqn = true };

pub const envs = std.StaticStringMap(EnvSpec).initComptime(.{
    .{ "array", EnvSpec{ .kind = .array, .arg = .bracket_cols, .repeat = false } },
    .{ "matrix", EnvSpec{ .kind = .matrix } },
    .{ "pmatrix", EnvSpec{ .kind = .pmatrix, .open = '(', .close = ')' } },
    .{ "bmatrix", EnvSpec{ .kind = .bmatrix, .open = '[', .close = ']' } },
    .{ "Bmatrix", EnvSpec{ .kind = .bbmatrix, .open = '{', .close = '}' } },
    .{ "vmatrix", EnvSpec{ .kind = .vmatrix, .open = '|', .close = '|' } },
    .{ "Vmatrix", EnvSpec{ .kind = .vvmatrix, .open = 0x2016, .close = 0x2016 } },
    .{ "smallmatrix", EnvSpec{ .kind = .smallmatrix, .style = .script, .col_gap = .{ 1.0 / 3.0, 1.0 / 3.0 }, .row_gap = 0.2 } },
    .{ "subarray", EnvSpec{ .kind = .subarray, .style = .script, .col_gap = .{ 0, 0 }, .row_gap = 0.1, .arg = .cols, .repeat = false } },
    .{ "cases", EnvSpec{ .kind = .cases, .open = '{', .row_gap = 0.2, .align_ = .{ .l, .l } } },
    .{ "aligned", EnvSpec{ .kind = .aligned, .style = .display, .col_gap = .{ 0, 2 }, .row_gap = 0.5, .align_ = .{ .r, .l }, .arg = .bracket } },
    .{ "gathered", EnvSpec{ .kind = .gathered, .style = .display, .row_gap = 0.5, .arg = .bracket } },
    .{ "split", EnvSpec{ .kind = .split, .style = .display, .col_gap = .{ 0, 0 }, .row_gap = 0.25, .align_ = .{ .r, .l } } },
    .{ "align", align_rl },
    .{ "align*", align_rl },
    .{ "gather", gather_env },
    .{ "gather*", gather_env },
    .{ "multline", multline_env },
    .{ "multline*", multline_env },
    .{ "alignat", alignat_env },
    .{ "alignat*", alignat_env },
    .{ "alignedat", EnvSpec{ .kind = .aligned, .style = .display, .col_gap = .{ 0, 0 }, .row_gap = 0.25, .align_ = .{ .r, .l }, .arg = .number, .bracket_first = true } },
    .{ "eqnarray", eqnarray_env },
    .{ "eqnarray*", eqnarray_env },
    .{ "xalignat", xalignat_env },
    .{ "xalignat*", xalignat_env },
    .{ "xxalignat", xalignat_env },
    .{ "flalign", flalign_env },
    .{ "flalign*", flalign_env },
    .{ "CD", EnvSpec{ .kind = .cd, .style = .display, .col_gap = .{ 0.5, 0.5 }, .row_gap = 0.5 } },
    .{ "prooftree", EnvSpec{ .kind = .matrix, .proof = true } },
    .{ "equation", equation_env },
    .{ "equation*", equation_env },
});

pub const Delim = struct { cp: ?u21 };

const delim_names = std.StaticStringMap(u21).initComptime(.{
    .{ "\\", '\\' },
    .{ "lmoustache", 0x23b0 },
    .{ "rmoustache", 0x23b1 },
    .{ "lgroup", 0x27ee },
    .{ "rgroup", 0x27ef },
    .{ "arrowvert", 0x23d0 },
    .{ "Arrowvert", 0x2016 },
    .{ "bracevert", 0x23aa },
    .{ "Vert", 0x2016 },
    .{ "|", 0x2016 },
    .{ "vert", '|' },
    .{ "uparrow", 0x2191 },
    .{ "downarrow", 0x2193 },
    .{ "updownarrow", 0x2195 },
    .{ "Uparrow", 0x21d1 },
    .{ "Downarrow", 0x21d3 },
    .{ "Updownarrow", 0x21d5 },
    .{ "backslash", '\\' },
    .{ "rangle", 0x27e9 },
    .{ "langle", 0x27e8 },
    .{ "rbrace", '}' },
    .{ "lbrace", '{' },
    .{ "}", '}' },
    .{ "{", '{' },
    .{ "rceil", 0x2309 },
    .{ "lceil", 0x2308 },
    .{ "rfloor", 0x230b },
    .{ "lfloor", 0x230a },
    .{ "lbrack", '[' },
    .{ "rbrack", ']' },
    .{ "lt", 0x27e8 },
    .{ "gt", 0x27e9 },
    .{ "lvert", '|' },
    .{ "rvert", '|' },
    .{ "lVert", 0x2016 },
    .{ "rVert", 0x2016 },
    .{ "ulcorner", 0x231c },
    .{ "urcorner", 0x231d },
    .{ "llcorner", 0x231e },
    .{ "lrcorner", 0x231f },
});

pub fn delimiter(t: lexer.Token) ?Delim {
    switch (t.kind) {
        .cs => {
            const cp = delim_names.get(t.name()) orelse return null;
            return .{ .cp = cp };
        },
        .char => return switch (t.cp) {
            '(', ')', '[', ']', '/', '|' => .{ .cp = t.cp },
            '<' => .{ .cp = 0x27e8 },
            '>' => .{ .cp = 0x27e9 },
            '.' => .{ .cp = null },
            else => null,
        },
        else => return null,
    }
}

const not_pairs = [_][2]u21{
    .{ 0x2190, 0x219a }, .{ 0x2192, 0x219b }, .{ 0x2194, 0x21ae }, .{ 0x21d0, 0x21cd }, .{ 0x21d2, 0x21cf },
    .{ 0x21d4, 0x21ce }, .{ 0x2208, 0x2209 }, .{ 0x220b, 0x220c }, .{ 0x2223, 0x2224 }, .{ 0x2225, 0x2226 },
    .{ 0x223c, 0x2241 }, .{ 0x7e, 0x2241 },   .{ 0x2243, 0x2244 }, .{ 0x2245, 0x2247 }, .{ 0x2248, 0x2249 },
    .{ 0x224d, 0x226d }, .{ 0x3d, 0x2260 },   .{ 0x2261, 0x2262 }, .{ 0x3c, 0x226e },   .{ 0x3e, 0x226f },
    .{ 0x2264, 0x2270 }, .{ 0x2265, 0x2271 }, .{ 0x2272, 0x2274 }, .{ 0x2273, 0x2275 }, .{ 0x2276, 0x2278 },
    .{ 0x2277, 0x2279 }, .{ 0x227a, 0x2280 }, .{ 0x227b, 0x2281 }, .{ 0x2282, 0x2284 }, .{ 0x2283, 0x2285 },
    .{ 0x2286, 0x2288 }, .{ 0x2287, 0x2289 }, .{ 0x22a2, 0x22ac }, .{ 0x22a8, 0x22ad }, .{ 0x22a9, 0x22ae },
    .{ 0x22ab, 0x22af }, .{ 0x227c, 0x22e0 }, .{ 0x227d, 0x22e1 }, .{ 0x2291, 0x22e2 }, .{ 0x2292, 0x22e3 },
    .{ 0x22b2, 0x22ea }, .{ 0x22b3, 0x22eb }, .{ 0x22b4, 0x22ec }, .{ 0x22b5, 0x22ed }, .{ 0x2203, 0x2204 },
};

pub fn endsList(name: []const u8) bool {
    const s = specs.get(name) orelse return false;
    return switch (s) {
        .over => true,
        .cmd => |k| k == .cr or k == .cr_plain or k == .newline,
        else => false,
    };
}

pub fn notRemap(cp: u21) ?u21 {
    for (not_pairs) |p| if (p[0] == cp) return p[1];
    return null;
}

pub fn isLetter(cp: u21) bool {
    return (cp >= 0xc0 and cp <= 0x24f and cp != 0xd7 and cp != 0xf7) or (cp >= 0x370 and cp <= 0x3ff) or (cp >= 0x400 and cp <= 0x4ff);
}

pub fn sideLimits(name: []const u8) bool {
    const side = [_][]const u8{ "int", "iint", "iiint", "oint", "oiint", "oiiint", "smallint" };
    for (side) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

pub fn isDecimal(s: []const u8) bool {
    var dots: usize = 0;
    var digits: usize = 0;
    for (s) |ch| {
        if (ch == '.') {
            dots += 1;
        } else if (std.ascii.isDigit(ch)) {
            digits += 1;
        } else return false;
    }
    return dots <= 1 and digits > 0;
}

pub const Dim = struct { value: f32, len: usize };

const units = std.StaticStringMap(f32).initComptime(.{
    .{ "em", 1.0 },
    .{ "ex", 0.431 },
    .{ "pt", 0.1 },
    .{ "pc", 1.2 },
    .{ "px", 1.0 / 16.0 },
    .{ "in", 6.0 },
    .{ "cm", 6.0 / 2.54 },
    .{ "mm", 6.0 / 25.4 },
    .{ "mu", 1.0 / 18.0 },
});

/// MathJax's dimension syntax: a signed decimal, optional space, a unit. Without `prefix_only` nothing may follow.
pub fn matchDimen(s: []const u8, prefix_only: bool) ?Dim {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    const start = i;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    var digits: usize = 0;
    var seen_sep = false;
    while (i < s.len) : (i += 1) {
        if (std.ascii.isDigit(s[i])) {
            digits += 1;
        } else if ((s[i] == '.' or s[i] == ',') and !seen_sep) {
            seen_sep = true;
        } else break;
    }
    if (digits == 0) return null;
    var num_buf: [64]u8 = undefined;
    const raw = s[start..i];
    if (raw.len > num_buf.len) return null;
    @memcpy(num_buf[0..raw.len], raw);
    std.mem.replaceScalar(u8, num_buf[0..raw.len], ',', '.');
    var text = num_buf[0..raw.len];
    if (text.len > 0 and text[text.len - 1] == '.') text = text[0 .. text.len - 1];
    const v = std.fmt.parseFloat(f32, text) catch return null;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i + 2 > s.len) return null;
    const unit = units.get(s[i .. i + 2]) orelse return null;
    i += 2;
    if (prefix_only) {
        if (i < s.len and s[i] == ' ') i += 1;
    } else {
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i != s.len) return null;
    }
    return .{ .value = v * unit, .len = i };
}

const dvips = std.StaticStringMap(u24).initComptime(.{
    .{ "Apricot", 0xfbb982 },
    .{ "Aquamarine", 0x00b5be },
    .{ "Bittersweet", 0xc04f17 },
    .{ "Black", 0x221e1f },
    .{ "Blue", 0x2d2f92 },
    .{ "BlueGreen", 0x00b3b8 },
    .{ "BlueViolet", 0x473992 },
    .{ "BrickRed", 0xb6321c },
    .{ "Brown", 0x792500 },
    .{ "BurntOrange", 0xf7921d },
    .{ "CadetBlue", 0x74729a },
    .{ "CarnationPink", 0xf282b4 },
    .{ "Cerulean", 0x00a2e3 },
    .{ "CornflowerBlue", 0x41b0e4 },
    .{ "Cyan", 0x00aeef },
    .{ "Dandelion", 0xfdbc42 },
    .{ "DarkOrchid", 0xa4538a },
    .{ "Emerald", 0x00a99d },
    .{ "ForestGreen", 0x009b55 },
    .{ "Fuchsia", 0x8c368c },
    .{ "Goldenrod", 0xffdf42 },
    .{ "Gray", 0x949698 },
    .{ "Green", 0x00a64f },
    .{ "GreenYellow", 0xdfe674 },
    .{ "JungleGreen", 0x00a99a },
    .{ "Lavender", 0xf49ec4 },
    .{ "LimeGreen", 0x8dc73e },
    .{ "Magenta", 0xec008c },
    .{ "Mahogany", 0xa9341f },
    .{ "Maroon", 0xaf3235 },
    .{ "Melon", 0xf89e7b },
    .{ "MidnightBlue", 0x006795 },
    .{ "Mulberry", 0xa93c93 },
    .{ "NavyBlue", 0x006eb8 },
    .{ "OliveGreen", 0x3c8031 },
    .{ "Orange", 0xf58137 },
    .{ "OrangeRed", 0xed135a },
    .{ "Orchid", 0xaf72b0 },
    .{ "Peach", 0xf7965a },
    .{ "Periwinkle", 0x7977b8 },
    .{ "PineGreen", 0x008b72 },
    .{ "Plum", 0x92268f },
    .{ "ProcessBlue", 0x00b0f0 },
    .{ "Purple", 0x99479b },
    .{ "RawSienna", 0x974006 },
    .{ "Red", 0xed1b23 },
    .{ "RedOrange", 0xf26035 },
    .{ "RedViolet", 0xa1246b },
    .{ "Rhodamine", 0xef559f },
    .{ "RoyalBlue", 0x0071bc },
    .{ "RoyalPurple", 0x613f99 },
    .{ "RubineRed", 0xed017d },
    .{ "Salmon", 0xf69289 },
    .{ "SeaGreen", 0x3fbc9d },
    .{ "Sepia", 0x671800 },
    .{ "SkyBlue", 0x46c5dd },
    .{ "SpringGreen", 0xc6dc67 },
    .{ "Tan", 0xda9d76 },
    .{ "TealBlue", 0x00aeb3 },
    .{ "Thistle", 0xd883b7 },
    .{ "Turquoise", 0x00b4ce },
    .{ "Violet", 0x58429b },
    .{ "VioletRed", 0xef58a0 },
    .{ "White", 0xffffff },
    .{ "WildStrawberry", 0xee2967 },
    .{ "Yellow", 0xfff200 },
    .{ "YellowGreen", 0x98cc70 },
    .{ "YellowOrange", 0xfaa21a },
});

const css_basic = std.StaticStringMap(u24).initComptime(.{
    .{ "black", 0x000000 },
    .{ "silver", 0xc0c0c0 },
    .{ "gray", 0x808080 },
    .{ "white", 0xffffff },
    .{ "maroon", 0x800000 },
    .{ "red", 0xff0000 },
    .{ "purple", 0x800080 },
    .{ "fuchsia", 0xff00ff },
    .{ "green", 0x008000 },
    .{ "lime", 0x00ff00 },
    .{ "olive", 0x808000 },
    .{ "yellow", 0xffff00 },
    .{ "navy", 0x000080 },
    .{ "blue", 0x0000ff },
    .{ "teal", 0x008080 },
    .{ "aqua", 0x00ffff },
    .{ "orange", 0xffa500 },
});

pub fn namedColor(name: []const u8) tree.Color {
    if (dvips.get(name)) |rgb| return .{ .name = name, .rgb = rgb };
    if (css_basic.get(name)) |rgb| return .{ .name = name, .rgb = rgb };
    if (name.len > 0 and name[0] == '#') {
        const hex = name[1..];
        if (hex.len == 3 or hex.len == 6) {
            if (std.fmt.parseInt(u24, hex, 16)) |v| {
                if (hex.len == 6) return .{ .name = name, .rgb = v };
                const r: u24 = (v >> 8) & 0xf;
                const g: u24 = (v >> 4) & 0xf;
                const b: u24 = v & 0xf;
                return .{ .name = name, .rgb = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17) };
            } else |_| {}
        }
    }
    return .{ .name = name, .rgb = null };
}

test "dimensions" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), matchDimen("1.5em", false).?.value, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0 / 18.0), matchDimen("-3mu", false).?.value, 1e-6);
    try std.testing.expect(matchDimen("1foo", false) == null);
    try std.testing.expectEqual(@as(usize, 3), matchDimen("1emx", true).?.len);
}

pub fn mmlAttrAllowed(kind: []const u8, key: []const u8) bool {
    const common = [_][]const u8{ "mathvariant", "mathsize", "mathbackground", "mathcolor", "dir", "fontfamily", "fontsize", "fontweight", "fontstyle", "color", "background", "id", "class", "href", "style" };
    for (common) |cc| if (std.mem.eql(u8, cc, key)) return true;
    const mo = [_][]const u8{ "form", "fence", "separator", "lspace", "rspace", "stretchy", "symmetric", "maxsize", "minsize", "largeop", "movablelimits", "accent", "linebreak", "lineleading", "linebreakstyle", "linebreakmultchar", "indentalign", "indentshift", "indenttarget", "indentalignfirst", "indentshiftfirst", "indentalignlast", "indentshiftlast" };
    if (std.mem.eql(u8, kind, "mo")) for (mo) |cc| if (std.mem.eql(u8, cc, key)) return true;
    if (std.mem.eql(u8, kind, "ms")) return std.mem.eql(u8, key, "lquote") or std.mem.eql(u8, key, "rquote");
    return false;
}
