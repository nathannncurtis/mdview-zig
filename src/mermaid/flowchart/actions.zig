const std = @import("std");
const rt = @import("../jison/runtime.zig");
const G = @import("flow_grammar");
const db_mod = @import("db.zig");
const Allocator = std.mem.Allocator;
const List = std.ArrayList;

pub const NodePair = struct { stmt: []const []const u8, nodes: []const []const u8 };

pub const Val = union(enum) {
    none,
    str: []const u8,
    text: db_mod.FlowText,
    list: []const []const u8,
    positions: []const db_mod.Pos,
    vs: NodePair,
    link: db_mod.LinkInfo,
    doc: *List(db_mod.DocItem),
    dir: []const u8,
};

pub const Actions = struct {
    pub const Value = Val;
    pub const undefined_value: Val = .none;

    a: Allocator,
    db: *db_mod.Db,

    pub fn textValue(self: *Actions, yytext: []const u16) Allocator.Error!Val {
        return .{ .str = try rt.toUtf8(self.a, yytext) };
    }

    pub fn lexAction(self: *Actions, lx: anytype, rule: u16) rt.Error!?u16 {
        return lexRule(self, lx, rule);
    }

    pub fn reduce(self: *Actions, ctx: anytype, rhs: []Val, out: *Val) rt.Error!bool {
        return reduceProd(self, ctx, rhs, out);
    }
};

fn isSpace16(c: u16) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => c >= 0x2000 and c <= 0x200A,
    };
}

fn replaceNewlines(a: Allocator, s: []const u16) Allocator.Error![]u16 {
    var o: List(u16) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            try o.appendSlice(a, &.{ '<', 'b', 'r', '/', '>' });
            i += 1;
            while (i < s.len and isSpace16(s[i])) i += 1;
        } else {
            try o.append(a, s[i]);
            i += 1;
        }
    }
    return o.items;
}

fn lexRule(self: *Actions, lx: anytype, rule: u16) rt.Error!?u16 {
    switch (rule) {
        0 => {
            // pattern: accTitle\s*:\s*
            // this.begin("acc_title");return 'acc_title';
            try lx.begin(G.cond.acc_title);
            return G.tok.acc_title;
        },
        1 => {
            // pattern: (?!\n||)*[^\n]*
            // this.popState(); return "acc_title_value";
            lx.popState();
            return G.tok.acc_title_value;
        },
        2 => {
            // pattern: accDescr\s*:\s*
            // this.begin("acc_descr");return 'acc_descr';
            try lx.begin(G.cond.acc_descr);
            return G.tok.acc_descr;
        },
        3 => {
            // pattern: (?!\n||)*[^\n]*
            // this.popState(); return "acc_descr_value";
            lx.popState();
            return G.tok.acc_descr_value;
        },
        4 => {
            // pattern: accDescr\s*\{\s*
            // this.begin("acc_descr_multiline");
            try lx.begin(G.cond.acc_descr_multiline);
            return null;
        },
        5 => {
            // pattern: [\}]
            // this.popState();
            lx.popState();
            return null;
        },
        6 => {
            // pattern: [^\}]*
            // return "acc_descr_multiline_value";
            return G.tok.acc_descr_multiline_value;
        },
        7 => {
            // pattern: @\{
            // // console.log('=> shapeData', yytext);
            // this.pushState("shapeData"); yytext=""; return 'SHAPE_DATA'
            try lx.begin(G.cond.shapeData);
            try lx.setYytext(&.{});
            return G.tok.SHAPE_DATA;
        },
        8 => {
            // pattern: ["]
            // // console.log('=> shapeDataStr', yytext);
            // this.pushState("shapeDataStr");
            // return 'SHAPE_DATA';
            try lx.begin(G.cond.shapeDataStr);
            return G.tok.SHAPE_DATA;
        },
        9 => {
            // pattern: ["]
            // // console.log('shapeData <==', yytext);
            // this.popState(); return 'SHAPE_DATA'
            lx.popState();
            return G.tok.SHAPE_DATA;
        },
        10 => {
            // pattern: [^\"]+
            // // console.log('shapeData', yytext);
            // const re = /\n\s*/g;
            // yytext = yytext.replace(re,"<br/>");
            // return 'SHAPE_DATA'
            try lx.setYytext(try replaceNewlines(lx.arena.allocator(), lx.yytext));
            return G.tok.SHAPE_DATA;
        },
        11 => {
            // pattern: [^}^"]+
            // // console.log('shapeData', yytext);
            // return 'SHAPE_DATA';
            return G.tok.SHAPE_DATA;
        },
        12 => {
            // pattern: \}
            // // console.log('<== root', yytext)
            // this.popState();
            lx.popState();
            return null;
        },
        13 => {
            // pattern: call[\s]+
            // this.begin("callbackname");
            try lx.begin(G.cond.callbackname);
            return null;
        },
        14 => {
            // pattern: \([\s]*\)
            // this.popState();
            lx.popState();
            return null;
        },
        15 => {
            // pattern: \(
            // this.popState(); this.begin("callbackargs");
            lx.popState();
            try lx.begin(G.cond.callbackargs);
            return null;
        },
        16 => {
            // pattern: [^(]*
            // return 'CALLBACKNAME';
            return G.tok.CALLBACKNAME;
        },
        17 => {
            // pattern: \)
            // this.popState();
            lx.popState();
            return null;
        },
        18 => {
            // pattern: [^)]*
            // return 'CALLBACKARGS';
            return G.tok.CALLBACKARGS;
        },
        19 => {
            // pattern: [^`"]+
            // return "MD_STR";
            return G.tok.MD_STR;
        },
        20 => {
            // pattern: [`]["]
            // this.popState();
            lx.popState();
            return null;
        },
        21 => {
            // pattern: ["][`]
            // this.begin("md_string");
            try lx.begin(G.cond.md_string);
            return null;
        },
        22 => {
            // pattern: [^"]+
            // return "STR";
            return G.tok.STR;
        },
        23 => {
            // pattern: ["]
            // this.popState();
            lx.popState();
            return null;
        },
        24 => {
            // pattern: ["]
            // this.pushState("string");
            try lx.begin(G.cond.string);
            return null;
        },
        25 => {
            // pattern: style\b
            // return 'STYLE';
            return G.tok.STYLE;
        },
        26 => {
            // pattern: default\b
            // return 'DEFAULT';
            return G.tok.DEFAULT;
        },
        27 => {
            // pattern: linkStyle\b
            // return 'LINKSTYLE';
            return G.tok.LINKSTYLE;
        },
        28 => {
            // pattern: interpolate\b
            // return 'INTERPOLATE';
            return G.tok.INTERPOLATE;
        },
        29 => {
            // pattern: classDef\b
            // return 'CLASSDEF';
            return G.tok.CLASSDEF;
        },
        30 => {
            // pattern: class\b
            // return 'CLASS';
            return G.tok.CLASS;
        },
        31 => {
            // pattern: href[\s]
            // return 'HREF';
            return G.tok.HREF;
        },
        32 => {
            // pattern: click[\s]+
            // this.begin("click");
            try lx.begin(G.cond.click);
            return null;
        },
        33 => {
            // pattern: [\s\n]
            // this.popState();
            lx.popState();
            return null;
        },
        34 => {
            // pattern: [^\s\n]*
            // return 'CLICK';
            return G.tok.CLICK;
        },
        35 => {
            // pattern: flowchart-elk\b
            // if(yy.lex.firstGraph()){this.begin("dir");}  return 'GRAPH';
            if (self.db.firstGraph()) try lx.begin(G.cond.dir);
            return G.tok.GRAPH;
        },
        36 => {
            // pattern: swimlane-beta\b
            // if(yy.lex.firstGraph()){this.begin("dir");}  return 'GRAPH';
            if (self.db.firstGraph()) try lx.begin(G.cond.dir);
            return G.tok.GRAPH;
        },
        37 => {
            // pattern: graph\b
            // if(yy.lex.firstGraph()){this.begin("dir");}  return 'GRAPH';
            if (self.db.firstGraph()) try lx.begin(G.cond.dir);
            return G.tok.GRAPH;
        },
        38 => {
            // pattern: flowchart\b
            // if(yy.lex.firstGraph()){this.begin("dir");}  return 'GRAPH';
            if (self.db.firstGraph()) try lx.begin(G.cond.dir);
            return G.tok.GRAPH;
        },
        39 => {
            // pattern: subgraph\b
            // return 'subgraph';
            return G.tok.subgraph;
        },
        40 => {
            // pattern: end\b\s*
            // return 'end';
            return G.tok.end;
        },
        41 => {
            // pattern: _self\b
            // return 'LINK_TARGET';
            return G.tok.LINK_TARGET;
        },
        42 => {
            // pattern: _blank\b
            // return 'LINK_TARGET';
            return G.tok.LINK_TARGET;
        },
        43 => {
            // pattern: _parent\b
            // return 'LINK_TARGET';
            return G.tok.LINK_TARGET;
        },
        44 => {
            // pattern: _top\b
            // return 'LINK_TARGET';
            return G.tok.LINK_TARGET;
        },
        45 => {
            // pattern: (\r?\n)*\s*\n
            // this.popState();  return 'NODIR';
            lx.popState();
            return G.tok.NODIR;
        },
        46 => {
            // pattern: \s*LR\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        47 => {
            // pattern: \s*RL\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        48 => {
            // pattern: \s*TB\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        49 => {
            // pattern: \s*BT\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        50 => {
            // pattern: \s*TD\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        51 => {
            // pattern: \s*BR\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        52 => {
            // pattern: \s*<
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        53 => {
            // pattern: \s*>
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        54 => {
            // pattern: \s*\^
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        55 => {
            // pattern: \s*v\b
            // this.popState();  return 'DIR';
            lx.popState();
            return G.tok.DIR;
        },
        56 => {
            // pattern: .*direction\s+TB[^\n]*
            // return 'direction_tb';
            return G.tok.direction_tb;
        },
        57 => {
            // pattern: .*direction\s+BT[^\n]*
            // return 'direction_bt';
            return G.tok.direction_bt;
        },
        58 => {
            // pattern: .*direction\s+RL[^\n]*
            // return 'direction_rl';
            return G.tok.direction_rl;
        },
        59 => {
            // pattern: .*direction\s+LR[^\n]*
            // return 'direction_lr';
            return G.tok.direction_lr;
        },
        60 => {
            // pattern: .*direction\s+TD[^\n]*
            // return 'direction_td';
            return G.tok.direction_td;
        },
        61 => {
            // pattern: [^\s\"]+@(?=[^\{\"])
            // return 'LINK_ID';
            return G.tok.LINK_ID;
        },
        62 => {
            // pattern: [0-9]+
            // return 'NUM';
            return G.tok.NUM;
        },
        63 => {
            // pattern: #
            // return 'BRKT';
            return G.tok.BRKT;
        },
        64 => {
            // pattern: :::
            // return 'STYLE_SEPARATOR';
            return G.tok.STYLE_SEPARATOR;
        },
        65 => {
            // pattern: :
            // return 'COLON';
            return G.tok.COLON;
        },
        66 => {
            // pattern: &
            // return 'AMP';
            return G.tok.AMP;
        },
        67 => {
            // pattern: ;
            // return 'SEMI';
            return G.tok.SEMI;
        },
        68 => {
            // pattern: ,
            // return 'COMMA';
            return G.tok.COMMA;
        },
        69 => {
            // pattern: \*
            // return 'MULT';
            return G.tok.MULT;
        },
        70 => {
            // pattern: \s*[xo<]?--+[-xo>]\s*
            // this.popState(); return 'LINK';
            lx.popState();
            return G.tok.LINK;
        },
        71 => {
            // pattern: \s*[xo<]?--\s*
            // this.pushState("edgeText"); return 'START_LINK';
            try lx.begin(G.cond.edgeText);
            return G.tok.START_LINK;
        },
        72 => {
            // pattern: [^-]|-(?!-)+
            // return 'EDGE_TEXT';
            return G.tok.EDGE_TEXT;
        },
        73 => {
            // pattern: \s*[xo<]?==+[=xo>]\s*
            // this.popState(); return 'LINK';
            lx.popState();
            return G.tok.LINK;
        },
        74 => {
            // pattern: \s*[xo<]?==\s*
            // this.pushState("thickEdgeText"); return 'START_LINK';
            try lx.begin(G.cond.thickEdgeText);
            return G.tok.START_LINK;
        },
        75 => {
            // pattern: [^=]|=(?!)
            // return 'EDGE_TEXT';
            return G.tok.EDGE_TEXT;
        },
        76 => {
            // pattern: \s*[xo<]?-?\.+-[xo>]?\s*
            // this.popState(); return 'LINK';
            lx.popState();
            return G.tok.LINK;
        },
        77 => {
            // pattern: \s*[xo<]?-\.\s*
            // this.pushState("dottedEdgeText"); return 'START_LINK';
            try lx.begin(G.cond.dottedEdgeText);
            return G.tok.START_LINK;
        },
        78 => {
            // pattern: [^\.]|\.(?!)
            // return 'EDGE_TEXT';
            return G.tok.EDGE_TEXT;
        },
        79 => {
            // pattern: \s*~~[\~]+\s*
            // return 'LINK';
            return G.tok.LINK;
        },
        80 => {
            // pattern: [-/\)][\)]
            // this.popState(); return '-)';
            lx.popState();
            return G.tok.@"-)";
        },
        81 => {
            // pattern: [^\(\)\[\]\{\}]|!\)+
            // return "TEXT"
            return G.tok.TEXT;
        },
        82 => {
            // pattern: \(-
            // this.pushState("ellipseText"); return '(-';
            try lx.begin(G.cond.ellipseText);
            return G.tok.@"(-";
        },
        83 => {
            // pattern: \]\)
            // this.popState(); return 'STADIUMEND';
            lx.popState();
            return G.tok.STADIUMEND;
        },
        84 => {
            // pattern: \(\[
            // this.pushState("text"); return 'STADIUMSTART';
            try lx.begin(G.cond.text);
            return G.tok.STADIUMSTART;
        },
        85 => {
            // pattern: \]\]
            // this.popState(); return 'SUBROUTINEEND';
            lx.popState();
            return G.tok.SUBROUTINEEND;
        },
        86 => {
            // pattern: \[\[
            // this.pushState("text"); return 'SUBROUTINESTART';
            try lx.begin(G.cond.text);
            return G.tok.SUBROUTINESTART;
        },
        87 => {
            // pattern: \[\|
            // return 'VERTEX_WITH_PROPS_START';
            return G.tok.VERTEX_WITH_PROPS_START;
        },
        88 => {
            // pattern: >
            // this.pushState("text"); return 'TAGEND';
            try lx.begin(G.cond.text);
            return G.tok.TAGEND;
        },
        89 => {
            // pattern: \)\]
            // this.popState(); return 'CYLINDEREND';
            lx.popState();
            return G.tok.CYLINDEREND;
        },
        90 => {
            // pattern: \[\(
            // this.pushState("text") ;return 'CYLINDERSTART';
            try lx.begin(G.cond.text);
            return G.tok.CYLINDERSTART;
        },
        91 => {
            // pattern: \)\)\)
            // this.popState(); return 'DOUBLECIRCLEEND';
            lx.popState();
            return G.tok.DOUBLECIRCLEEND;
        },
        92 => {
            // pattern: \(\(\(
            // this.pushState("text"); return 'DOUBLECIRCLESTART';
            try lx.begin(G.cond.text);
            return G.tok.DOUBLECIRCLESTART;
        },
        93 => {
            // pattern: [\\(?=\])][\]]
            // this.popState(); return 'TRAPEND';
            lx.popState();
            return G.tok.TRAPEND;
        },
        94 => {
            // pattern: \/(?=\])\]
            // this.popState(); return 'INVTRAPEND';
            lx.popState();
            return G.tok.INVTRAPEND;
        },
        95 => {
            // pattern: \/(?!\])|\\(?!\])|[^\\\[\]\(\)\{\}\/]+
            // return 'TEXT';
            return G.tok.TEXT;
        },
        96 => {
            // pattern: \[\/
            // this.pushState("trapText"); return 'TRAPSTART';
            try lx.begin(G.cond.trapText);
            return G.tok.TRAPSTART;
        },
        97 => {
            // pattern: \[\\
            // this.pushState("trapText"); return 'INVTRAPSTART';
            try lx.begin(G.cond.trapText);
            return G.tok.INVTRAPSTART;
        },
        98 => {
            // pattern: <
            // return 'TAGSTART';
            return G.tok.TAGSTART;
        },
        99 => {
            // pattern: >
            // return 'TAGEND';
            return G.tok.TAGEND;
        },
        100 => {
            // pattern: \^
            // return 'UP';
            return G.tok.UP;
        },
        101 => {
            // pattern: \\\|
            // return 'SEP';
            return G.tok.SEP;
        },
        102 => {
            // pattern: v\b
            // return 'DOWN';
            return G.tok.DOWN;
        },
        103 => {
            // pattern: \*
            // return 'MULT';
            return G.tok.MULT;
        },
        104 => {
            // pattern: #
            // return 'BRKT';
            return G.tok.BRKT;
        },
        105 => {
            // pattern: &
            // return 'AMP';
            return G.tok.AMP;
        },
        106 => {
            // pattern: ([A-Za-z0-9!"\#$%&'*+\.`?\\_\/]|-(?=[^\>\-\.])|(?!))+
            // return 'NODE_STRING';
            return G.tok.NODE_STRING;
        },
        107 => {
            // pattern: -
            // return 'MINUS'
            return G.tok.MINUS;
        },
        108 => {
            // pattern: [\u00AA\u00B5\u00BA\u00C0-\u00D6\u00D8-\u00F6]|[\u00F8-\u02C1\u02C6-\u02D1\u02E0-\u02E4\u02EC\u02EE\u0370-\u0374\u0376\u0377]|[\u037A-\u037D\u0386\u0388-\u038A\u038C\u038E-\u03A1\u03A3-\u03F5]|[\u03F7-\u0481\u048A-\u0527\u0531-\u0556\u0559\u0561-\u0587\u05D0-\u05EA]|[\u05F0-\u05F2\u0620-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06E5\u06E6\u06EE]|[\u06EF\u06FA-\u06FC\u06FF\u0710\u0712-\u072F\u074D-\u07A5\u07B1\u07CA-\u07EA]|[\u07F4\u07F5\u07FA\u0800-\u0815\u081A\u0824\u0828\u0840-\u0858\u08A0]|[\u08A2-\u08AC\u0904-\u0939\u093D\u0950\u0958-\u0961\u0971-\u0977]|[\u0979-\u097F\u0985-\u098C\u098F\u0990\u0993-\u09A8\u09AA-\u09B0\u09B2]|[\u09B6-\u09B9\u09BD\u09CE\u09DC\u09DD\u09DF-\u09E1\u09F0\u09F1\u0A05-\u0A0A]|[\u0A0F\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32\u0A33\u0A35\u0A36\u0A38\u0A39]|[\u0A59-\u0A5C\u0A5E\u0A72-\u0A74\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8]|[\u0AAA-\u0AB0\u0AB2\u0AB3\u0AB5-\u0AB9\u0ABD\u0AD0\u0AE0\u0AE1\u0B05-\u0B0C]|[\u0B0F\u0B10\u0B13-\u0B28\u0B2A-\u0B30\u0B32\u0B33\u0B35-\u0B39\u0B3D\u0B5C]|[\u0B5D\u0B5F-\u0B61\u0B71\u0B83\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99]|[\u0B9A\u0B9C\u0B9E\u0B9F\u0BA3\u0BA4\u0BA8-\u0BAA\u0BAE-\u0BB9\u0BD0]|[\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C33\u0C35-\u0C39\u0C3D]|[\u0C58\u0C59\u0C60\u0C61\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8\u0CAA-\u0CB3]|[\u0CB5-\u0CB9\u0CBD\u0CDE\u0CE0\u0CE1\u0CF1\u0CF2\u0D05-\u0D0C\u0D0E-\u0D10]|[\u0D12-\u0D3A\u0D3D\u0D4E\u0D60\u0D61\u0D7A-\u0D7F\u0D85-\u0D96\u0D9A-\u0DB1]|[\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u0E01-\u0E30\u0E32\u0E33\u0E40-\u0E46\u0E81]|[\u0E82\u0E84\u0E87\u0E88\u0E8A\u0E8D\u0E94-\u0E97\u0E99-\u0E9F\u0EA1-\u0EA3]|[\u0EA5\u0EA7\u0EAA\u0EAB\u0EAD-\u0EB0\u0EB2\u0EB3\u0EBD\u0EC0-\u0EC4\u0EC6]|[\u0EDC-\u0EDF\u0F00\u0F40-\u0F47\u0F49-\u0F6C\u0F88-\u0F8C\u1000-\u102A]|[\u103F\u1050-\u1055\u105A-\u105D\u1061\u1065\u1066\u106E-\u1070\u1075-\u1081]|[\u108E\u10A0-\u10C5\u10C7\u10CD\u10D0-\u10FA\u10FC-\u1248\u124A-\u124D]|[\u1250-\u1256\u1258\u125A-\u125D\u1260-\u1288\u128A-\u128D\u1290-\u12B0]|[\u12B2-\u12B5\u12B8-\u12BE\u12C0\u12C2-\u12C5\u12C8-\u12D6\u12D8-\u1310]|[\u1312-\u1315\u1318-\u135A\u1380-\u138F\u13A0-\u13F4\u1401-\u166C]|[\u166F-\u167F\u1681-\u169A\u16A0-\u16EA\u1700-\u170C\u170E-\u1711]|[\u1720-\u1731\u1740-\u1751\u1760-\u176C\u176E-\u1770\u1780-\u17B3\u17D7]|[\u17DC\u1820-\u1877\u1880-\u18A8\u18AA\u18B0-\u18F5\u1900-\u191C]|[\u1950-\u196D\u1970-\u1974\u1980-\u19AB\u19C1-\u19C7\u1A00-\u1A16]|[\u1A20-\u1A54\u1AA7\u1B05-\u1B33\u1B45-\u1B4B\u1B83-\u1BA0\u1BAE\u1BAF]|[\u1BBA-\u1BE5\u1C00-\u1C23\u1C4D-\u1C4F\u1C5A-\u1C7D\u1CE9-\u1CEC]|[\u1CEE-\u1CF1\u1CF5\u1CF6\u1D00-\u1DBF\u1E00-\u1F15\u1F18-\u1F1D]|[\u1F20-\u1F45\u1F48-\u1F4D\u1F50-\u1F57\u1F59\u1F5B\u1F5D\u1F5F-\u1F7D]|[\u1F80-\u1FB4\u1FB6-\u1FBC\u1FBE\u1FC2-\u1FC4\u1FC6-\u1FCC\u1FD0-\u1FD3]|[\u1FD6-\u1FDB\u1FE0-\u1FEC\u1FF2-\u1FF4\u1FF6-\u1FFC\u2071\u207F]|[\u2090-\u209C\u2102\u2107\u210A-\u2113\u2115\u2119-\u211D\u2124\u2126\u2128]|[\u212A-\u212D\u212F-\u2139\u213C-\u213F\u2145-\u2149\u214E\u2183\u2184]|[\u2C00-\u2C2E\u2C30-\u2C5E\u2C60-\u2CE4\u2CEB-\u2CEE\u2CF2\u2CF3]|[\u2D00-\u2D25\u2D27\u2D2D\u2D30-\u2D67\u2D6F\u2D80-\u2D96\u2DA0-\u2DA6]|[\u2DA8-\u2DAE\u2DB0-\u2DB6\u2DB8-\u2DBE\u2DC0-\u2DC6\u2DC8-\u2DCE]|[\u2DD0-\u2DD6\u2DD8-\u2DDE\u2E2F\u3005\u3006\u3031-\u3035\u303B\u303C]|[\u3041-\u3096\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF\u3105-\u312D]|[\u3131-\u318E\u31A0-\u31BA\u31F0-\u31FF\u3400-\u4DB5\u4E00-\u9FCC]|[\uA000-\uA48C\uA4D0-\uA4FD\uA500-\uA60C\uA610-\uA61F\uA62A\uA62B]|[\uA640-\uA66E\uA67F-\uA697\uA6A0-\uA6E5\uA717-\uA71F\uA722-\uA788]|[\uA78B-\uA78E\uA790-\uA793\uA7A0-\uA7AA\uA7F8-\uA801\uA803-\uA805]|[\uA807-\uA80A\uA80C-\uA822\uA840-\uA873\uA882-\uA8B3\uA8F2-\uA8F7\uA8FB]|[\uA90A-\uA925\uA930-\uA946\uA960-\uA97C\uA984-\uA9B2\uA9CF\uAA00-\uAA28]|[\uAA40-\uAA42\uAA44-\uAA4B\uAA60-\uAA76\uAA7A\uAA80-\uAAAF\uAAB1\uAAB5]|[\uAAB6\uAAB9-\uAABD\uAAC0\uAAC2\uAADB-\uAADD\uAAE0-\uAAEA\uAAF2-\uAAF4]|[\uAB01-\uAB06\uAB09-\uAB0E\uAB11-\uAB16\uAB20-\uAB26\uAB28-\uAB2E]|[\uABC0-\uABE2\uAC00-\uD7A3\uD7B0-\uD7C6\uD7CB-\uD7FB\uF900-\uFA6D]|[\uFA70-\uFAD9\uFB00-\uFB06\uFB13-\uFB17\uFB1D\uFB1F-\uFB28\uFB2A-\uFB36]|[\uFB38-\uFB3C\uFB3E\uFB40\uFB41\uFB43\uFB44\uFB46-\uFBB1\uFBD3-\uFD3D]|[\uFD50-\uFD8F\uFD92-\uFDC7\uFDF0-\uFDFB\uFE70-\uFE74\uFE76-\uFEFC]|[\uFF21-\uFF3A\uFF41-\uFF5A\uFF66-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF]|[\uFFD2-\uFFD7\uFFDA-\uFFDC]
            // return 'UNICODE_TEXT';
            return G.tok.UNICODE_TEXT;
        },
        109 => {
            // pattern: \|
            // this.popState(); return 'PIPE';
            lx.popState();
            return G.tok.PIPE;
        },
        110 => {
            // pattern: \|
            // this.pushState("text"); return 'PIPE';
            try lx.begin(G.cond.text);
            return G.tok.PIPE;
        },
        111 => {
            // pattern: \)
            // this.popState(); return 'PE';
            lx.popState();
            return G.tok.PE;
        },
        112 => {
            // pattern: \(
            // this.pushState("text"); return 'PS';
            try lx.begin(G.cond.text);
            return G.tok.PS;
        },
        113 => {
            // pattern: \]
            // this.popState(); return 'SQE';
            lx.popState();
            return G.tok.SQE;
        },
        114 => {
            // pattern: \[
            // this.pushState("text"); return 'SQS';
            try lx.begin(G.cond.text);
            return G.tok.SQS;
        },
        115 => {
            // pattern: (\})
            // this.popState(); return 'DIAMOND_STOP'
            lx.popState();
            return G.tok.DIAMOND_STOP;
        },
        116 => {
            // pattern: \{
            // this.pushState("text"); return 'DIAMOND_START'
            try lx.begin(G.cond.text);
            return G.tok.DIAMOND_START;
        },
        117 => {
            // pattern: [^\[\]\(\)\{\}\|\"]+
            // return "TEXT";
            return G.tok.TEXT;
        },
        118 => {
            // pattern: "
            // return 'QUOTE';
            return G.tok.QUOTE;
        },
        119 => {
            // pattern: (\r?\n)+
            // return 'NEWLINE';
            return G.tok.NEWLINE;
        },
        120 => {
            // pattern: [^\S\n\r]+
            // return 'SPACE';
            return G.tok.SPACE;
        },
        121 => {
            // pattern: $
            // return 'EOF';
            return G.tok.EOF;
        },
        else => unreachable,
    }
}


fn concat(a: Allocator, x: []const u8, y: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(a, u8, &.{ x, y });
}

fn appendStr(a: Allocator, l: []const []const u8, s: []const u8) Allocator.Error![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ l, &.{s} });
}

fn single(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    const o = try a.alloc([]const u8, 1);
    o[0] = s;
    return o;
}

fn last(l: []const []const u8) []const u8 {
    return l[l.len - 1];
}

fn textOf(s: []const u8, t: []const u8) Val {
    return .{ .text = .{ .text = s, .type = t } };
}

fn docPush(a: Allocator, doc: *List(db_mod.DocItem), line: Val) Allocator.Error!void {
    switch (line) {
        .list => |l| for (l) |n| try doc.append(a, .{ .name = n }),
        .str => |s| try doc.append(a, .{ .name = s }),
        .dir => |d| try doc.append(a, .{ .dir = d }),
        else => {},
    }
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn reduceProd(self: *Actions, ctx: anytype, rhs: []Val, out: *Val) rt.Error!bool {
    reduceInner(self, ctx.prod, rhs, out) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Semantic => return ctx.diag.fail(ctx.gpa, "{s}", .{self.db.err_msg orelse "semantic error"}),
    };
    return false;
}

const VertexKind = struct { text: usize, ty: []const u8 };

fn vertexKind(prod: u16) VertexKind {
    return switch (prod) {
        56 => .{ .text = 2, .ty = "square" },
        57 => .{ .text = 2, .ty = "doublecircle" },
        58 => .{ .text = 3, .ty = "circle" },
        59 => .{ .text = 2, .ty = "ellipse" },
        60 => .{ .text = 2, .ty = "stadium" },
        61 => .{ .text = 2, .ty = "subroutine" },
        62 => .{ .text = 6, .ty = "rect" },
        63 => .{ .text = 2, .ty = "cylinder" },
        64 => .{ .text = 2, .ty = "round" },
        65 => .{ .text = 2, .ty = "diamond" },
        66 => .{ .text = 3, .ty = "hexagon" },
        67 => .{ .text = 2, .ty = "odd" },
        68 => .{ .text = 2, .ty = "trapezoid" },
        69 => .{ .text = 2, .ty = "inv_trapezoid" },
        70 => .{ .text = 2, .ty = "lean_right" },
        else => .{ .text = 2, .ty = "lean_left" },
    };
}

fn reduceInner(self: *Actions, prod: u16, rhs: []Val, out: *Val) db_mod.Error!void {
    const a = self.a;
    const db = self.db;
    switch (prod) {
        2 => {
            const l = try a.create(List(db_mod.DocItem));
            l.* = .empty;
            out.* = .{ .doc = l };
        },
        3 => {
            try docPush(a, rhs[0].doc, rhs[1]);
            out.* = rhs[0];
        },
        11 => {
            try db.setDirection("TB");
            out.* = .{ .str = "TB" };
        },
        12 => {
            try db.setDirection(rhs[1].str);
            out.* = rhs[1];
        },
        27 => out.* = .{ .list = rhs[0].vs.nodes },
        28, 29, 30, 31, 32 => out.* = .{ .list = &.{} },
        33 => out.* = .{ .str = try db.addSubGraph(rhs[2].text, rhs[7].doc.items, rhs[4].text, false) },
        34 => out.* = .{ .str = try db.addSubGraph(rhs[2].text, rhs[4].doc.items, rhs[2].text, true) },
        35 => out.* = .{ .str = try db.addSubGraph(null, rhs[2].doc.items, null, false) },
        37, 38 => {
            const t = trimmed(rhs[1].str);
            if (prod == 37) db.setAccTitle(t) else db.setAccDescription(t);
            out.* = .{ .str = t };
        },
        39 => {
            const t = trimmed(rhs[0].str);
            db.setAccDescription(t);
            out.* = .{ .str = t };
        },
        43 => out.* = .{ .str = try concat(a, rhs[0].str, rhs[1].str) },
        45, 46, 47 => {
            const node = rhs[2].list;
            if (prod == 45) try db.addVertex(last(node), null, null, null, null, null, rhs[3].str);
            try db.addLink(rhs[0].vs.stmt, node, rhs[1].link);
            out.* = .{ .vs = .{ .stmt = node, .nodes = try std.mem.concat(a, []const u8, &.{ node, rhs[0].vs.nodes }) } };
        },
        48, 50 => out.* = .{ .vs = .{ .stmt = rhs[0].list, .nodes = rhs[0].list } },
        49 => {
            try db.addVertex(last(rhs[0].list), null, null, null, null, null, rhs[1].str);
            out.* = .{ .vs = .{ .stmt = rhs[0].list, .nodes = rhs[0].list } };
        },
        51 => out.* = .{ .list = try single(a, rhs[0].str) },
        52 => {
            try db.addVertex(last(rhs[0].list), null, null, null, null, null, rhs[1].str);
            out.* = .{ .list = try appendStr(a, rhs[0].list, rhs[5].str) };
        },
        53 => out.* = .{ .list = try appendStr(a, rhs[0].list, rhs[4].str) },
        55 => {
            try db.setClass(rhs[0].str, rhs[2].str);
            out.* = rhs[0];
        },
        56...71 => {
            const vk = vertexKind(prod);
            try db.addVertex(rhs[0].str, rhs[vk.text].text, vk.ty, null, null, null, null);
            out.* = rhs[0];
        },
        72 => {
            try db.addVertex(rhs[0].str, null, null, null, null, null, null);
            out.* = rhs[0];
        },
        73, 75 => {
            var l = rhs[0].link;
            l.text = rhs[1].text;
            out.* = .{ .link = l };
        },
        74 => {
            var l = rhs[0].link;
            l.text = .{ .text = rhs[1].str };
            out.* = .{ .link = l };
        },
        77, 78 => {
            const o: usize = if (prod == 78) 1 else 0;
            var l = try db.destructLink(rhs[o + 2].str, rhs[o].str);
            l.text = rhs[o + 1].text;
            if (prod == 78) l.id = rhs[0].str;
            out.* = .{ .link = l };
        },
        79, 86 => out.* = textOf(rhs[0].str, "text"),
        80, 87 => out.* = textOf(try concat(a, rhs[0].text.text, rhs[1].str), rhs[0].text.type),
        81, 88 => out.* = textOf(rhs[0].str, "string"),
        82, 89 => out.* = textOf(rhs[0].str, "markdown"),
        83, 84 => {
            const o: usize = prod - 83;
            var l = try db.destructLink(rhs[o].str, null);
            if (prod == 84) l.id = rhs[0].str;
            out.* = .{ .link = l };
        },
        85 => out.* = rhs[1],
        101, 103 => out.* = textOf(rhs[0].str, "text"),
        102 => out.* = textOf(try concat(a, rhs[0].text.text, rhs[1].str), rhs[0].text.type),
        104 => out.* = textOf(rhs[0].str, "markdown"),
        105 => try db.addClass(rhs[2].str, rhs[4].list),
        106 => try db.setClass(rhs[2].str, rhs[4].str),
        107, 109, 115 => try db.setClickEvent(rhs[0].str, rhs[1].str),
        108, 110, 116 => {
            try db.setClickEvent(rhs[0].str, rhs[1].str);
            try db.setTooltip(rhs[0].str, rhs[rhs.len - 1].str);
        },
        111 => try db.setLink(rhs[0].str, rhs[2].str, null),
        117 => try db.setLink(rhs[0].str, rhs[1].str, null),
        112 => {
            try db.setLink(rhs[0].str, rhs[2].str, null);
            try db.setTooltip(rhs[0].str, rhs[4].str);
        },
        113 => try db.setLink(rhs[0].str, rhs[2].str, rhs[4].str),
        114 => {
            try db.setLink(rhs[0].str, rhs[2].str, rhs[6].str);
            try db.setTooltip(rhs[0].str, rhs[4].str);
        },
        118 => {
            try db.setLink(rhs[0].str, rhs[1].str, null);
            try db.setTooltip(rhs[0].str, rhs[3].str);
        },
        119 => try db.setLink(rhs[0].str, rhs[1].str, rhs[3].str),
        120 => {
            try db.setLink(rhs[0].str, rhs[1].str, rhs[5].str);
            try db.setTooltip(rhs[0].str, rhs[3].str);
        },
        121 => try db.addVertex(rhs[2].str, null, null, rhs[4].list, null, null, null),
        122, 123 => try db.updateLink(try positions(a, rhs[2], prod == 122), rhs[4].list),
        124, 125 => {
            const p = try positions(a, rhs[2], prod == 124);
            try db.updateLinkInterpolate(p, rhs[6].str);
            try db.updateLink(p, rhs[8].list);
        },
        126, 127 => try db.updateLinkInterpolate(try positions(a, rhs[2], prod == 126), rhs[6].str),
        128 => {
            const p = try a.alloc(db_mod.Pos, 1);
            p[0] = .{ .index = rhs[0].str };
            out.* = .{ .positions = p };
        },
        129 => out.* = .{ .positions = try std.mem.concat(a, db_mod.Pos, &.{ rhs[0].positions, &.{db_mod.Pos{ .index = rhs[2].str }} }) },
        130 => out.* = .{ .list = try single(a, rhs[0].str) },
        131 => out.* = .{ .list = try appendStr(a, rhs[0].list, rhs[2].str) },
        133, 182, 184 => out.* = .{ .str = try concat(a, rhs[0].str, rhs[1].str) },
        185 => out.* = .{ .dir = "TB" },
        186 => out.* = .{ .dir = "BT" },
        187 => out.* = .{ .dir = "RL" },
        188 => out.* = .{ .dir = "LR" },
        189 => out.* = .{ .dir = "TD" },
        else => {},
    }
}

fn positions(a: Allocator, v: Val, is_default: bool) Allocator.Error![]const db_mod.Pos {
    if (!is_default) return v.positions;
    const p = try a.alloc(db_mod.Pos, 1);
    p[0] = .default;
    return p;
}
