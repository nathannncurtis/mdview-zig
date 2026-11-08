const std = @import("std");
const xml = @import("svg_xml.zig");
const raster = @import("svg_raster.zig");
const sty = @import("svg_style.zig");
const css = @import("svg_css.zig");

const Allocator = std.mem.Allocator;
const Node = xml.Node;
pub const Error = error{ OutOfMemory, TooLarge };

pub fn bezierAt(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    var lo: f64 = 0;
    var hi: f64 = 1;
    var t: f64 = x;
    for (0..40) |_| {
        const u = 1 - t;
        const bx = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t;
        if (@abs(bx - x) < 1e-7) break;
        if (bx < x) lo = t else hi = t;
        t = (lo + hi) / 2;
    }
    const u = 1 - t;
    return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t;
}

pub fn ease(tf: sty.Timing, p: f64) f64 {
    switch (tf) {
        .cubic => |c| return bezierAt(c[0], c[1], c[2], c[3], p),
        .steps => |s| {
            const n: f64 = @floatFromInt(s.n);
            var k = @floor(p * n);
            if (s.start) k += 1;
            return std.math.clamp(k / n, 0, 1);
        },
    }
}

const Tok = struct { num: bool, text: []const u8, v: f64 };

fn tokenize(arena: Allocator, s: []const u8) Error![]Tok {
    var out: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    var st: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const starts_num = std.ascii.isDigit(c) or ((c == '-' or c == '+' or c == '.') and i + 1 < s.len and (std.ascii.isDigit(s[i + 1]) or (s[i + 1] == '.' and i + 2 < s.len and std.ascii.isDigit(s[i + 2]))));
        if (starts_num) {
            if (i > st) try out.append(arena, .{ .num = false, .text = s[st..i], .v = 0 });
            var sc: raster.NumScan = .{ .s = s, .i = i };
            const v = sc.number() orelse {
                i += 1;
                continue;
            };
            try out.append(arena, .{ .num = true, .text = s[i..sc.i], .v = v });
            i = sc.i;
            st = i;
        } else i += 1;
    }
    if (st < s.len) try out.append(arena, .{ .num = false, .text = s[st..], .v = 0 });
    return out.items;
}

fn sameSkeleton(a: []const Tok, b: []const Tok) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.num != y.num) return false;
        if (!x.num and !std.mem.eql(u8, x.text, y.text)) return false;
    }
    return true;
}

fn isColorText(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " ");
    if (t.len == 0 or std.ascii.isDigit(t[0]) or t[0] == '-' or t[0] == '.') return false;
    return sty.parseColor(t) != null;
}

fn valueDistance(arena: Allocator, p: []const u8, q: []const u8) f64 {
    const tp = tokenize(arena, p) catch return 1;
    const tq = tokenize(arena, q) catch return 1;
    if (!sameSkeleton(tp, tq)) return 1;
    var sum: f64 = 0;
    for (tp, tq) |x, y| if (x.num) {
        sum += (x.v - y.v) * (x.v - y.v);
    };
    return @sqrt(sum);
}

pub fn lerpStr(arena: Allocator, a: []const u8, b: []const u8, t: f64) Error![]const u8 {
    if (isColorText(a) and isColorText(b)) {
        const ca = sty.parseColor(a).?;
        const cb = sty.parseColor(b).?;
        const f: f32 = @floatCast(t);
        const r = ca.r + (cb.r - ca.r) * f;
        const g = ca.g + (cb.g - ca.g) * f;
        const bl = ca.b + (cb.b - ca.b) * f;
        const al = ca.a + (cb.a - ca.a) * f;
        return std.fmt.allocPrint(arena, "rgba({d},{d},{d},{d})", .{ @round(r * 255), @round(g * 255), @round(bl * 255), al });
    }
    const ta = try tokenize(arena, a);
    const tb = try tokenize(arena, b);
    if (sameSkeleton(ta, tb)) {
        var out: std.ArrayList(u8) = .empty;
        for (ta, tb) |x, y| {
            if (x.num) {
                try out.print(arena, "{d}", .{x.v + (y.v - x.v) * t});
            } else try out.appendSlice(arena, x.text);
        }
        return out.items;
    }
    return if (t < 0.5) a else b;
}

/// a + factor * b, number by number, when both have the same shape.
pub fn combine(arena: Allocator, a: []const u8, b: []const u8, factor: f64) Error!?[]const u8 {
    const ta = try tokenize(arena, a);
    const tb = try tokenize(arena, b);
    if (!sameSkeleton(ta, tb)) return null;
    var out: std.ArrayList(u8) = .empty;
    for (ta, tb) |x, y| {
        if (x.num) {
            try out.print(arena, "{d}", .{x.v + y.v * factor});
        } else try out.appendSlice(arena, x.text);
    }
    return out.items;
}

fn implicitFrom(arena: Allocator, name: []const u8, first: []const u8) Error!?[]const u8 {
    const defaults = [_][2][]const u8{ .{ "opacity", "1" }, .{ "fill-opacity", "1" }, .{ "stroke-opacity", "1" }, .{ "stroke-width", "1" }, .{ "stroke-dashoffset", "0" } };
    for (defaults) |d| if (std.mem.eql(u8, d[0], name)) return d[1];
    if (!std.mem.eql(u8, name, "transform")) return null;
    const toks = try tokenize(arena, first);
    var out: std.ArrayList(u8) = .empty;
    var one = false;
    for (toks) |t| {
        if (!t.num) {
            try out.appendSlice(arena, t.text);
            const open = std.mem.lastIndexOfScalar(u8, t.text, '(');
            if (open) |o| {
                var st = o;
                while (st > 0 and std.ascii.isAlphabetic(t.text[st - 1])) st -= 1;
                one = std.mem.startsWith(u8, t.text[st..o], "scale");
                if (std.mem.eql(u8, t.text[st..o], "matrix")) return null;
            }
        } else try out.appendSlice(arena, if (one) "1" else "0");
    }
    return out.items;
}

pub const CssResult = struct { name: []const u8, value: []const u8 };

pub fn cssProgress(a: sty.CssAnim, t_ms: f64) ?f64 {
    if (a.paused) return null;
    const elapsed = t_ms - a.delay_ms;
    var it: f64 = 0;
    var p: f64 = 0;
    if (elapsed < 0) {
        if (!a.backwards) return null;
    } else if (a.dur_ms <= 0) {
        if (!a.forwards) return null;
        p = 1;
        it = @max(0, @ceil(a.count) - 1);
    } else {
        const total = a.dur_ms * a.count;
        if (elapsed >= total) {
            if (!a.forwards) return null;
            const whole = @floor(a.count);
            const frac = a.count - whole;
            if (frac > 0) {
                it = whole;
                p = frac;
            } else {
                it = @max(0, whole - 1);
                p = 1;
            }
        } else {
            it = @floor(elapsed / a.dur_ms);
            p = (elapsed - it * a.dur_ms) / a.dur_ms;
        }
    }
    const odd = @mod(it, 2) == 1;
    const rev = a.reverse != (a.alternate and (if (a.reverse) !odd else odd));
    return if (rev) 1 - p else p;
}

fn lastDecl(decls: []const css.Decl, name: []const u8) ?[]const u8 {
    var i = decls.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, decls[i].name, name)) return decls[i].value;
    }
    return null;
}

/// Property values of every @keyframes animation in `anims` at `t_ms`, in application order.
pub fn cssAnimations(arena: Allocator, anims: []const sty.CssAnim, frames: []const css.Keyframes, underlying: []const css.Decl, node: *const Node, t_ms: f64, out: *std.ArrayList(CssResult)) Error!void {
    for (anims) |a| {
        if (a.name.len == 0) continue;
        const p0 = cssProgress(a, t_ms) orelse continue;
        var kf: ?css.Keyframes = null;
        for (frames) |k| if (std.mem.eql(u8, k.name, a.name)) {
            kf = k;
        };
        const k = kf orelse continue;
        var names: std.ArrayList([]const u8) = .empty;
        for (k.frames) |fr| for (fr.decls) |d| {
            if (std.mem.eql(u8, d.name, "animation-timing-function")) continue;
            var seen = false;
            for (names.items) |n| seen = seen or std.mem.eql(u8, n, d.name);
            if (!seen) try names.append(arena, d.name);
        };
        for (names.items) |nm| {
            var pts: std.ArrayList(struct { pct: f64, val: []const u8, tf: ?sty.Timing }) = .empty;
            for (k.frames) |fr| {
                const v = lastDecl(fr.decls, nm) orelse continue;
                const tfs = lastDecl(fr.decls, "animation-timing-function");
                try pts.append(arena, .{ .pct = fr.pct, .val = v, .tf = if (tfs) |x| sty.parseTiming(x) else null });
            }
            if (pts.items.len == 0) continue;
            const under = lastDecl(underlying, nm) orelse node.attr(nm) orelse try implicitFrom(arena, nm, pts.items[0].val);
            if (pts.items[0].pct > 0) {
                if (under) |u| try pts.insert(arena, 0, .{ .pct = 0, .val = u, .tf = null });
            }
            if (pts.items[pts.items.len - 1].pct < 100) {
                if (under) |u| try pts.append(arena, .{ .pct = 100, .val = u, .tf = null });
            }
            const x = p0 * 100;
            var val: []const u8 = pts.items[0].val;
            if (x >= pts.items[pts.items.len - 1].pct) {
                val = pts.items[pts.items.len - 1].val;
            } else if (x > pts.items[0].pct) {
                var i: usize = 0;
                while (i + 1 < pts.items.len and pts.items[i + 1].pct < x) i += 1;
                const lo = pts.items[i];
                const hi = pts.items[i + 1];
                const span = hi.pct - lo.pct;
                const local = if (span > 0) (x - lo.pct) / span else 1;
                val = try lerpStr(arena, lo.val, hi.val, ease(lo.tf orelse a.timing, local));
            }
            try out.append(arena, .{ .name = nm, .value = val });
        }
    }
}

// SMIL

fn parseClock(s_in: []const u8) ?f64 {
    var s = std.mem.trim(u8, s_in, " \t\r\n");
    if (s.len == 0) return null;
    var sign: f64 = 1;
    if (s[0] == '+' or s[0] == '-') {
        if (s[0] == '-') sign = -1;
        s = std.mem.trim(u8, s[1..], " ");
    }
    if (std.mem.indexOfScalar(u8, s, ':')) |_| {
        var it = std.mem.splitScalar(u8, s, ':');
        var parts: [3]f64 = .{ 0, 0, 0 };
        var n: usize = 0;
        while (it.next()) |p| {
            if (n >= 3) return null;
            parts[n] = std.fmt.parseFloat(f64, p) catch return null;
            n += 1;
        }
        const ms = if (n == 3) (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000 else (parts[0] * 60 + parts[1]) * 1000;
        return sign * ms;
    }
    const units = [_]struct { []const u8, f64 }{ .{ "ms", 1 }, .{ "min", 60000 }, .{ "h", 3600000 }, .{ "s", 1000 } };
    for (units) |u| if (std.mem.endsWith(u8, s, u[0])) {
        const n = std.fmt.parseFloat(f64, std.mem.trim(u8, s[0 .. s.len - u[0].len], " ")) catch return null;
        return sign * n * u[1];
    };
    const n = std.fmt.parseFloat(f64, s) catch return null;
    return sign * n * 1000;
}

const Kind = enum { animate, set, transform, motion };

const Anim = struct {
    node: *Node,
    target: *Node,
    kind: Kind,
    id: []const u8,
    begins: ?[]f64 = null,
    resolving: bool = false,
};

const Ctx = struct {
    arena: Allocator,
    anims: []Anim,
    ids: std.StringHashMapUnmanaged(*Node),
    t: f64,

    fn animById(c: *Ctx, id: []const u8) ?usize {
        for (c.anims, 0..) |a, i| if (a.id.len > 0 and std.mem.eql(u8, a.id, id)) return i;
        return null;
    }

    fn simpleDur(c: *Ctx, a: *const Anim) f64 {
        _ = c;
        const d = a.node.attr("dur") orelse return std.math.inf(f64);
        if (std.mem.eql(u8, std.mem.trim(u8, d, " "), "indefinite") or std.mem.eql(u8, std.mem.trim(u8, d, " "), "media")) return std.math.inf(f64);
        const v = parseClock(d) orelse return std.math.inf(f64);
        return if (v > 0) v else std.math.inf(f64);
    }

    fn activeDur(c: *Ctx, a: *const Anim, begin: f64) f64 {
        const dur = c.simpleDur(a);
        var total = dur;
        var rc: f64 = 1;
        if (a.node.attr("repeatCount")) |rcs| {
            const t = std.mem.trim(u8, rcs, " ");
            rc = if (std.mem.eql(u8, t, "indefinite")) std.math.inf(f64) else (std.fmt.parseFloat(f64, t) catch 1);
        }
        const has_rc = a.node.attr("repeatCount") != null;
        total = dur * rc;
        if (a.node.attr("repeatDur")) |rds| {
            const t = std.mem.trim(u8, rds, " ");
            if (std.mem.eql(u8, t, "indefinite")) {
                if (!has_rc) total = std.math.inf(f64);
            } else if (parseClock(t)) |rd| {
                total = if (has_rc) @min(total, rd) else rd;
            }
        }
        if (a.node.attr("end")) |es| {
            var it = std.mem.splitScalar(u8, es, ';');
            var best = std.math.inf(f64);
            while (it.next()) |tok| {
                const t = std.mem.trim(u8, tok, " ");
                if (parseClock(t)) |e| {
                    if (e > begin) best = @min(best, e - begin);
                } else if (std.mem.indexOf(u8, t, ".begin")) |_| {
                    if (c.syncTime(t, 0)) |e| if (e > begin) {
                        best = @min(best, e - begin);
                    };
                }
            }
            total = @min(total, best);
        }
        return total;
    }

    fn syncTime(c: *Ctx, tok: []const u8, depth: u32) ?f64 {
        if (depth > 6) return null;
        const dot = std.mem.indexOfScalar(u8, tok, '.') orelse return null;
        const id = std.mem.trim(u8, tok[0..dot], " ");
        const rest = tok[dot + 1 ..];
        const is_end = std.mem.startsWith(u8, rest, "end");
        if (!is_end and !std.mem.startsWith(u8, rest, "begin")) return null;
        var off: f64 = 0;
        const sign_at = std.mem.indexOfAny(u8, rest, "+-");
        if (sign_at) |sa| off = parseClock(rest[sa..]) orelse 0;
        const idx = c.animById(id) orelse return null;
        const bl = c.beginsOf(idx, depth + 1) orelse return null;
        if (bl.len == 0) return null;
        const b0 = bl[0];
        if (!is_end) return b0 + off;
        const e = c.activeDur(&c.anims[idx], b0);
        if (!std.math.isFinite(e)) return null;
        return b0 + e + off;
    }

    fn beginsOf(c: *Ctx, idx: usize, depth: u32) ?[]f64 {
        const a = &c.anims[idx];
        if (a.begins) |b| return b;
        if (a.resolving or depth > 6) return null;
        a.resolving = true;
        defer a.resolving = false;
        var list: std.ArrayList(f64) = .empty;
        const bs = a.node.attr("begin") orelse "0s";
        var it = std.mem.splitScalar(u8, bs, ';');
        while (it.next()) |tok0| {
            const tok = std.mem.trim(u8, tok0, " ");
            if (tok.len == 0 or std.mem.eql(u8, tok, "indefinite")) continue;
            if (parseClock(tok)) |v| {
                list.append(c.arena, v) catch return null;
            } else if (c.syncTime(tok, depth)) |v| {
                list.append(c.arena, v) catch return null;
            }
        }
        std.mem.sort(f64, list.items, {}, std.sort.asc(f64));
        a.begins = list.items;
        return list.items;
    }
};

const State = struct { frac: f64, iter: f64, ended: bool };

fn stateAt(c: *Ctx, idx: usize) ?State {
    const a = &c.anims[idx];
    const bl = c.beginsOf(idx, 0) orelse return null;
    var bi: ?usize = null;
    for (bl, 0..) |b, i| if (b <= c.t) {
        bi = i;
    };
    const k = bi orelse return null;
    const b = bl[k];
    const dur = c.simpleDur(a);
    var total = c.activeDur(a, b);
    if (k + 1 < bl.len) total = @min(total, bl[k + 1] - b);
    const lt_raw = c.t - b;
    const ended = lt_raw >= total;
    if (ended and !std.mem.eql(u8, a.node.attr("fill") orelse "remove", "freeze")) return null;
    const lt = if (ended) total else lt_raw;
    if (!std.math.isFinite(dur)) return .{ .frac = 0, .iter = 0, .ended = ended };
    var it = @floor(lt / dur);
    var frac = (lt - it * dur) / dur;
    if (ended and frac == 0 and lt > 0) {
        it -= 1;
        frac = 1;
    }
    return .{ .frac = std.math.clamp(frac, 0, 1), .iter = it, .ended = ended };
}

fn splitSemi(arena: Allocator, s: []const u8) Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " \t\r\n");
        if (t.len > 0) try out.append(arena, t);
    }
    return out.items;
}

fn numList(arena: Allocator, s: ?[]const u8) Error![]f64 {
    var out: std.ArrayList(f64) = .empty;
    var it = std.mem.tokenizeAny(u8, s orelse return out.items, "; \t\r\n,");
    while (it.next()) |p| try out.append(arena, std.fmt.parseFloat(f64, p) catch continue);
    return out.items;
}

fn isProperty(name: []const u8) bool {
    for (sty.presentation_attrs) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

fn getValue(arena: Allocator, n: *Node, name: []const u8) Error!?[]const u8 {
    if (n.attr("style")) |sa| {
        var decls: std.ArrayList(css.Decl) = .empty;
        try css.parseDecls(arena, sa, &decls);
        var i = decls.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, decls.items[i].name, name)) return decls.items[i].value;
        }
    }
    return n.attr(name) orelse if (std.mem.eql(u8, name, "href")) n.attr("xlink:href") else null;
}

fn setValue(arena: Allocator, n: *Node, name: []const u8, value: []const u8) Error!void {
    if (isProperty(name) and !std.mem.eql(u8, name, "transform")) {
        const old = n.attr("style") orelse "";
        const ns = try std.fmt.allocPrint(arena, "{s};{s}:{s}", .{ old, name, value });
        for (n.attrs.items) |*a| if (std.mem.eql(u8, a.name, "style")) {
            a.value = ns;
            return;
        };
        try n.attrs.append(arena, .{ .name = "style", .value = ns });
        return;
    }
    for (n.attrs.items) |*a| if (std.mem.eql(u8, a.name, name) or (std.mem.eql(u8, name, "href") and std.mem.eql(u8, a.name, "xlink:href"))) {
        a.value = value;
        return;
    };
    try n.attrs.append(arena, .{ .name = name, .value = value });
}

fn splineEase(arena: Allocator, n: *Node, seg: usize, p: f64) Error!f64 {
    const ks = try splitSemi(arena, n.attr("keySplines") orelse return p);
    if (seg >= ks.len) return p;
    const v = try numList(arena, ks[seg]);
    if (v.len != 4) return p;
    return bezierAt(v[0], v[1], v[2], v[3], p);
}

fn animValue(c: *Ctx, a: *const Anim, st: State, base: ?[]const u8) Error!?[]const u8 {
    const arena = c.arena;
    const n = a.node;
    if (a.kind == .set) return n.attr("to");
    var vals: []const []const u8 = &.{};
    if (n.attr("values")) |vs| {
        vals = try splitSemi(arena, vs);
    } else {
        const from = n.attr("from");
        const to = n.attr("to");
        const by = n.attr("by");
        if (to) |t| {
            const f = from orelse base orelse return t;
            vals = try arena.dupe([]const u8, &.{ f, t });
        } else if (by) |b| {
            const f = from orelse base orelse "0";
            const t = (try combine(arena, f, b, 1)) orelse return null;
            vals = try arena.dupe([]const u8, &.{ f, t });
        } else return null;
    }
    if (vals.len == 0) return null;
    const mode = n.attr("calcMode") orelse "linear";
    var result: []const u8 = vals[0];
    if (vals.len > 1) {
        var kt = try numList(arena, n.attr("keyTimes"));
        const discrete = std.mem.eql(u8, mode, "discrete");
        if (std.mem.eql(u8, mode, "paced") and vals.len > 1) {
            const tmp = try arena.alloc(f64, vals.len);
            tmp[0] = 0;
            var total: f64 = 0;
            for (1..vals.len) |i| {
                total += valueDistance(arena, vals[i - 1], vals[i]);
                tmp[i] = total;
            }
            if (total > 0) {
                for (tmp) |*x| x.* /= total;
                kt = tmp;
            } else kt = &.{};
        }
        if (kt.len != vals.len or kt[0] != 0) {
            const tmp = try arena.alloc(f64, vals.len);
            for (tmp, 0..) |*x, i| {
                const d: f64 = @floatFromInt(if (discrete) vals.len else vals.len - 1);
                x.* = @as(f64, @floatFromInt(i)) / d;
            }
            kt = tmp;
        }
        const f = st.frac;
        if (discrete) {
            var i: usize = 0;
            while (i + 1 < vals.len and kt[i + 1] <= f) i += 1;
            result = vals[i];
        } else if (f >= kt[kt.len - 1]) {
            result = vals[vals.len - 1];
        } else {
            var i: usize = 0;
            while (i + 2 < vals.len and kt[i + 1] <= f) i += 1;
            const span = kt[i + 1] - kt[i];
            var local = if (span > 0) (f - kt[i]) / span else 1;
            if (std.mem.eql(u8, mode, "spline")) local = try splineEase(arena, n, i, local);
            result = try lerpStr(arena, vals[i], vals[i + 1], local);
        }
    }
    if (std.mem.eql(u8, n.attr("accumulate") orelse "none", "sum") and st.iter > 0) {
        if (try combine(arena, result, vals[vals.len - 1], st.iter)) |acc| result = acc;
    }
    if (std.mem.eql(u8, n.attr("additive") orelse "replace", "sum")) {
        if (base) |b| if (try combine(arena, b, result, 1)) |sum| {
            result = sum;
        };
    }
    return result;
}

fn transformString(c: *Ctx, a: *const Anim, st: State) Error!?[]const u8 {
    const arena = c.arena;
    const n = a.node;
    const ty = n.attr("type") orelse "translate";
    var raw: []const []const u8 = &.{};
    if (n.attr("values")) |vs| {
        raw = try splitSemi(arena, vs);
    } else {
        const to = n.attr("to") orelse {
            const by = n.attr("by") orelse return null;
            raw = try arena.dupe([]const u8, &.{ if (std.mem.eql(u8, ty, "scale")) "1" else "0", by });
            return try transformFrom(c, a, st, ty, raw);
        };
        raw = try arena.dupe([]const u8, &.{ n.attr("from") orelse (if (std.mem.eql(u8, ty, "scale")) "1" else "0"), to });
    }
    return try transformFrom(c, a, st, ty, raw);
}

fn transformFrom(c: *Ctx, a: *const Anim, st: State, ty: []const u8, raw: []const []const u8) Error!?[]const u8 {
    const arena = c.arena;
    if (raw.len == 0) return null;
    const strs = try arena.alloc([]const u8, raw.len);
    for (raw, 0..) |r, i| {
        var norm: std.ArrayList(u8) = .empty;
        for (r) |ch| try norm.append(arena, if (ch == ',') ' ' else ch);
        strs[i] = try std.fmt.allocPrint(arena, "{s}({s})", .{ ty, norm.items });
    }
    const fake = Anim{ .node = a.node, .target = a.target, .kind = .animate, .id = "" };
    var vals_attr: std.ArrayList(u8) = .empty;
    for (strs, 0..) |sv, i| {
        if (i > 0) try vals_attr.append(arena, ';');
        try vals_attr.appendSlice(arena, sv);
    }
    const tmp = try arena.create(Node);
    tmp.* = .{ .tag = "animate" };
    try tmp.attrs.append(arena, .{ .name = "values", .value = vals_attr.items });
    for ([_][]const u8{ "keyTimes", "calcMode", "keySplines" }) |nm| if (a.node.attr(nm)) |v| try tmp.attrs.append(arena, .{ .name = nm, .value = v });
    var f2 = fake;
    f2.node = tmp;
    return try animValue(c, &f2, st, null);
}

fn motionString(c: *Ctx, a: *const Anim, st: State) Error!?[]const u8 {
    const arena = c.arena;
    const n = a.node;
    var path_d: ?[]const u8 = n.attr("path");
    if (path_d == null) for (n.children.items) |ch| {
        if (!ch.is_text and std.mem.eql(u8, ch.tag, "mpath")) {
            const h = ch.attr("href") orelse ch.attr("xlink:href") orelse continue;
            if (h.len > 1 and h[0] == '#') if (c.ids.get(h[1..])) |pn| {
                path_d = pn.attr("d");
            };
        }
    };
    var x: f64 = 0;
    var y: f64 = 0;
    var ang: f64 = 0;
    var have_ang = false;
    var frac = st.frac;
    const kp = try numList(arena, n.attr("keyPoints"));
    const kt = try numList(arena, n.attr("keyTimes"));
    if (kp.len > 1 and kp.len == kt.len) {
        var i: usize = 0;
        while (i + 2 < kt.len and kt[i + 1] <= frac) i += 1;
        const span = kt[i + 1] - kt[i];
        const loc = if (span > 0) std.math.clamp((frac - kt[i]) / span, 0, 1) else 1;
        frac = kp[i] + (kp[i + 1] - kp[i]) * loc;
    }
    if (path_d) |d| {
        var path: raster.Path = .{};
        try raster.parsePathData(arena, d, &path);
        var polys: raster.Polys = .{};
        try raster.flatten(arena, &path, raster.Mat.identity, 0.05, &polys);
        if (polys.subs.items.len == 0) return null;
        const sub = polys.subs.items[0];
        const pts = polys.pts.items[sub.start..][0..sub.len];
        var total: f64 = 0;
        for (1..pts.len) |i| total += std.math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
        const want = frac * total;
        var acc: f64 = 0;
        x = pts[0].x;
        y = pts[0].y;
        for (1..pts.len) |i| {
            const l = std.math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
            if (acc + l >= want or i == pts.len - 1) {
                const f = if (l > 0) std.math.clamp((want - acc) / l, 0, 1) else 0;
                x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f;
                y = pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f;
                if (l > 0) {
                    ang = std.math.atan2(pts[i].y - pts[i - 1].y, pts[i].x - pts[i - 1].x) * 180 / std.math.pi;
                    have_ang = true;
                }
                break;
            }
            acc += l;
        }
    } else {
        const tmp = try arena.create(Node);
        tmp.* = .{ .tag = "animate" };
        for ([_][]const u8{ "values", "from", "to", "by", "keyTimes", "keySplines" }) |nm| if (n.attr(nm)) |v| try tmp.attrs.append(arena, .{ .name = nm, .value = v });
        try tmp.attrs.append(arena, .{ .name = "calcMode", .value = n.attr("calcMode") orelse "paced" });
        var f2 = a.*;
        f2.node = tmp;
        const v = (try animValue(c, &f2, .{ .frac = frac, .iter = 0, .ended = st.ended }, null)) orelse return null;
        const nums = try numList(arena, v);
        if (nums.len < 2) return null;
        x = nums[0];
        y = nums[1];
    }
    const rot = n.attr("rotate") orelse "0";
    var rot_deg: f64 = 0;
    if (std.mem.eql(u8, rot, "auto")) {
        rot_deg = if (have_ang) ang else 0;
    } else if (std.mem.eql(u8, rot, "auto-reverse")) {
        rot_deg = if (have_ang) ang + 180 else 0;
    } else rot_deg = std.fmt.parseFloat(f64, rot) catch 0;
    return try std.fmt.allocPrint(arena, "translate({d} {d}) rotate({d})", .{ x, y, rot_deg });
}

fn collect(arena: Allocator, n: *Node, list: *std.ArrayList(Anim), ids: *std.StringHashMapUnmanaged(*Node)) Error!void {
    if (n.is_text) return;
    if (n.attr("id")) |id| {
        const g = try ids.getOrPut(arena, id);
        if (!g.found_existing) g.value_ptr.* = n;
    }
    const t = n.tag;
    const kind: ?Kind = if (std.mem.eql(u8, t, "animate") or std.mem.eql(u8, t, "animateColor")) .animate else if (std.mem.eql(u8, t, "set")) .set else if (std.mem.eql(u8, t, "animateTransform")) .transform else if (std.mem.eql(u8, t, "animateMotion")) .motion else null;
    if (kind) |k| {
        if (list.items.len < 2000) try list.append(arena, .{ .node = n, .target = n.parent orelse n, .kind = k, .id = n.attr("id") orelse "" });
    }
    for (n.children.items) |c| try collect(arena, c, list, ids);
}

pub fn hasSmil(n: *const Node) bool {
    if (n.is_text) return false;
    const t = n.tag;
    if (std.mem.eql(u8, t, "animate") or std.mem.eql(u8, t, "set") or std.mem.eql(u8, t, "animateTransform") or std.mem.eql(u8, t, "animateMotion") or std.mem.eql(u8, t, "animateColor")) return true;
    for (n.children.items) |c| if (hasSmil(c)) return true;
    return false;
}

pub fn hasCssAnimation(n: *const Node) bool {
    if (n.is_text) return false;
    if (std.mem.eql(u8, n.tag, "style")) {
        for (n.children.items) |c| if (c.is_text and std.mem.indexOf(u8, c.text, "@keyframes") != null or c.is_text and std.mem.indexOf(u8, c.text, "@-webkit-keyframes") != null) return true;
    }
    if (n.attr("style")) |s| if (std.mem.indexOf(u8, s, "animation") != null) return true;
    for (n.children.items) |c| if (hasCssAnimation(c)) return true;
    return false;
}

pub fn applySmil(arena: Allocator, root: *Node, t_ms: f64) Error!void {
    var list: std.ArrayList(Anim) = .empty;
    var ids: std.StringHashMapUnmanaged(*Node) = .empty;
    try collect(arena, root, &list, &ids);
    if (list.items.len == 0) return;
    for (list.items) |*a| {
        const h = a.node.attr("href") orelse a.node.attr("xlink:href");
        if (h) |hv| if (hv.len > 1 and hv[0] == '#') if (ids.get(hv[1..])) |tn| {
            a.target = tn;
        };
    }
    var c: Ctx = .{ .arena = arena, .anims = list.items, .ids = ids, .t = t_ms };
    for (list.items, 0..) |*a, idx| {
        const st = stateAt(&c, idx) orelse continue;
        switch (a.kind) {
            .animate, .set => {
                const name = a.node.attr("attributeName") orelse continue;
                const base = try getValue(arena, a.target, name);
                const v = (try animValue(&c, a, st, base)) orelse continue;
                try setValue(arena, a.target, name, v);
            },
            .transform => {
                const base = a.target.attr("transform");
                const v = (try transformString(&c, a, st)) orelse continue;
                const sum = std.mem.eql(u8, a.node.attr("additive") orelse "replace", "sum");
                const out = if (sum and base != null) try std.fmt.allocPrint(arena, "{s} {s}", .{ base.?, v }) else v;
                try setValue(arena, a.target, "transform", out);
            },
            .motion => {
                const v = (try motionString(&c, a, st)) orelse continue;
                const base = a.target.attr("transform");
                const out = if (base) |b| try std.fmt.allocPrint(arena, "{s} {s}", .{ b, v }) else v;
                try setValue(arena, a.target, "transform", out);
            },
        }
    }
}

test "lerp and combine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("15px", try lerpStr(a, "10px", "20px", 0.5));
    try std.testing.expectEqualStrings("rgba(128,0,128,1)", try lerpStr(a, "#f00", "#00f", 0.5));
    try std.testing.expectEqualStrings("M5 5L15 15", try lerpStr(a, "M0 0L10 10", "M10 10L20 20", 0.5));
    try std.testing.expectEqualStrings("a", try lerpStr(a, "a", "b", 0.2));
    try std.testing.expectEqualStrings("12", (try combine(a, "10", "1", 2)).?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), ease(.{ .cubic = .{ 0, 0, 1, 1 } }, 0.5), 1e-3);
}

test "smil timing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try xml.parse(a, "<svg><rect id='r' width='10' opacity='0'><animate attributeName='width' from='10' to='20' begin='1s' dur='2s' fill='freeze'/><set attributeName='opacity' to='1' begin='1s'/></rect></svg>");
    try applySmil(a, doc, 2000);
    const rect = doc.children.items[0];
    try std.testing.expectEqualStrings("15", rect.attr("width").?);
    try applySmil(a, doc, 10000);
    try std.testing.expectEqualStrings("20", rect.attr("width").?);
    try std.testing.expect(hasSmil(doc));
}
