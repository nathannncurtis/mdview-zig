const std = @import("std");
const tables = @import("brotli/tables.zig");

const dictionary = @embedFile("brotli/dictionary.bin");

pub const Error = error{ Invalid, TooBig, OutOfMemory };

const dict_size_bits = [25]u8{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };
const dict_offsets = [25]u32{ 0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040, 93696, 100864, 104704, 106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016 };

const insert_base = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
const insert_extra = [24]u8{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
const copy_base = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
const copy_extra = [24]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
const block_base = [26]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
const block_extra = [26]u8{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };

const cell_insert = [11]u8{ 0, 0, 0, 0, 1, 1, 0, 2, 1, 2, 2 };
const cell_copy = [11]u8{ 0, 1, 0, 1, 0, 1, 2, 0, 2, 1, 2 };

const cl_order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const cl_len = [16]u8{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
const cl_val = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };

const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    fn bit(self: *Bits) Error!u32 {
        if (self.pos >= self.data.len * 8) return error.Invalid;
        const v = (self.data[self.pos >> 3] >> @as(u3, @intCast(self.pos & 7))) & 1;
        self.pos += 1;
        return v;
    }

    fn read(self: *Bits, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (self.pos + n > self.data.len * 8) return error.Invalid;
        var v: u64 = 0;
        var got: u6 = 0;
        while (got < n) {
            const off: u6 = @intCast(self.pos & 7);
            const take: u6 = @min(8 - off, n - got);
            const byte: u64 = self.data[self.pos >> 3];
            const part = (byte >> @as(u3, @intCast(off))) & ((@as(u64, 1) << @as(u6, @intCast(take))) - 1);
            v |= part << got;
            got += take;
            self.pos += take;
        }
        return @intCast(v);
    }

    fn peek4(self: *const Bits) u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < 4) : (i += 1) {
            const p = self.pos + i;
            if (p >= self.data.len * 8) break;
            v |= @as(u32, (self.data[p >> 3] >> @as(u3, @intCast(p & 7))) & 1) << i;
        }
        return v;
    }

    fn align8(self: *Bits) Error!void {
        const rem = self.pos & 7;
        if (rem == 0) return;
        const v = try self.read(@intCast(8 - rem));
        if (v != 0) return error.Invalid;
    }
};

const Huff = struct {
    count: [16]u16 = @as([16]u16, @splat(0)),
    sym: []u16 = &.{},
    single: ?u16 = null,

    fn decode(h: *const Huff, br: *Bits) Error!u16 {
        if (h.single) |s| return s;
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var len: usize = 1;
        while (len < 16) : (len += 1) {
            code |= @intCast(try br.bit());
            const c: i32 = h.count[len];
            if (code - c < first) return h.sym[@intCast(index + (code - first))];
            index += c;
            first += c;
            first <<= 1;
            code <<= 1;
        }
        return error.Invalid;
    }
};

fn build(arena: std.mem.Allocator, lengths: []const u8) Error!Huff {
    var h = Huff{};
    var nonzero: usize = 0;
    var last: u16 = 0;
    for (lengths, 0..) |l, i| {
        if (l == 0) continue;
        h.count[l] += 1;
        nonzero += 1;
        last = @intCast(i);
    }
    if (nonzero == 0) return error.Invalid;
    if (nonzero == 1) {
        h.single = last;
        return h;
    }
    var offs: [17]u16 = @splat(0);
    var len: usize = 1;
    while (len < 16) : (len += 1) offs[len + 1] = offs[len] + h.count[len];
    h.sym = try arena.alloc(u16, nonzero);
    for (lengths, 0..) |l, i| {
        if (l == 0) continue;
        h.sym[offs[l]] = @intCast(i);
        offs[l] += 1;
    }
    return h;
}

fn bitWidth(v: u32) u6 {
    return @intCast(32 - @clz(v));
}

fn readPrefix(arena: std.mem.Allocator, br: *Bits, alphabet: u32) Error!Huff {
    const hskip = try br.read(2);
    const lengths = try arena.alloc(u8, alphabet);
    @memset(lengths, 0);
    if (hskip == 1) {
        const nsym = (try br.read(2)) + 1;
        const width = bitWidth(alphabet - 1);
        var syms = [4]u32{ 0, 0, 0, 0 };
        var i: usize = 0;
        while (i < nsym) : (i += 1) {
            const s = try br.read(width);
            if (s >= alphabet) return error.Invalid;
            var j: usize = 0;
            while (j < i) : (j += 1) if (syms[j] == s) return error.Invalid;
            syms[i] = s;
        }
        switch (nsym) {
            1 => lengths[syms[0]] = 1,
            2 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 1;
            },
            3 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 2;
                lengths[syms[2]] = 2;
            },
            else => {
                if ((try br.read(1)) == 0) {
                    for (syms) |s| lengths[s] = 2;
                } else {
                    lengths[syms[0]] = 1;
                    lengths[syms[1]] = 2;
                    lengths[syms[2]] = 3;
                    lengths[syms[3]] = 3;
                }
            },
        }
        return build(arena, lengths);
    }
    var cl: [18]u8 = @splat(0);
    var space: i32 = 32;
    var num: u32 = 0;
    var i: usize = hskip;
    while (i < 18) : (i += 1) {
        const ix = br.peek4();
        const l = cl_len[ix];
        if (br.pos + l > br.data.len * 8) return error.Invalid;
        br.pos += l;
        const v = cl_val[ix];
        cl[cl_order[i]] = v;
        if (v != 0) {
            space -= @as(i32, 32) >> @as(u5, @intCast(v));
            num += 1;
            if (space <= 0) break;
        }
    }
    if (num != 1 and space != 0) return error.Invalid;
    const clh = try build(arena, &cl);
    var prev: u8 = 8;
    var rep: u32 = 0;
    var rep_len: u8 = 0;
    var sym: u32 = 0;
    var sp: i32 = 32768;
    while (sym < alphabet and sp > 0) {
        const code = try clh.decode(br);
        if (code < 16) {
            rep = 0;
            lengths[sym] = @intCast(code);
            sym += 1;
            if (code != 0) {
                prev = @intCast(code);
                sp -= @as(i32, 32768) >> @as(u5, @intCast(code));
            }
        } else {
            const extra: u6 = if (code == 16) 2 else 3;
            const new_len: u8 = if (code == 16) prev else 0;
            if (rep_len != new_len) {
                rep = 0;
                rep_len = new_len;
            }
            const old = rep;
            if (rep > 0) {
                rep -= 2;
                rep <<= @intCast(extra);
            }
            rep += (try br.read(extra)) + 3;
            const delta = rep - old;
            if (sym + delta > alphabet) return error.Invalid;
            @memset(lengths[sym .. sym + delta], new_len);
            sym += delta;
            if (new_len != 0) sp -= @as(i32, @intCast(delta)) * (@as(i32, 32768) >> @as(u5, @intCast(new_len)));
        }
    }
    if (sp != 0) return error.Invalid;
    return build(arena, lengths);
}

fn varLen(br: *Bits) Error!u32 {
    if ((try br.bit()) == 0) return 0;
    const n: u6 = @intCast(try br.read(3));
    if (n == 0) return 1;
    return (@as(u32, 1) << @intCast(n)) + (try br.read(n));
}

fn contextMap(arena: std.mem.Allocator, br: *Bits, size: usize, ntrees: u32) Error![]u8 {
    const map = try arena.alloc(u8, size);
    @memset(map, 0);
    if (ntrees < 2) return map;
    const use_rle = (try br.bit()) == 1;
    const max_rle: u32 = if (use_rle) (try br.read(4)) + 1 else 0;
    const h = try readPrefix(arena, br, ntrees + max_rle);
    var i: usize = 0;
    while (i < size) {
        const code = try h.decode(br);
        if (code == 0) {
            i += 1;
        } else if (code <= max_rle) {
            const reps = (try br.read(@intCast(code))) + (@as(u32, 1) << @intCast(code));
            if (i + reps > size) return error.Invalid;
            i += reps;
        } else {
            map[i] = @intCast(code - max_rle);
            i += 1;
        }
    }
    if ((try br.bit()) == 1) {
        var mtf: [256]u8 = undefined; // SAFETY: filled with identity on the next line
        for (&mtf, 0..) |*m, k| m.* = @intCast(k);
        for (map) |*m| {
            const idx = m.*;
            const v = mtf[idx];
            var k: usize = idx;
            while (k > 0) : (k -= 1) mtf[k] = mtf[k - 1];
            mtf[0] = v;
            m.* = v;
        }
    }
    return map;
}

const Category = struct {
    ntypes: u32 = 1,
    types: Huff = .{},
    counts: Huff = .{},
    ring: [2]u32 = .{ 1, 0 },
    kind: u32 = 0,
    remaining: u32 = 1 << 30,

    fn init(c: *Category, arena: std.mem.Allocator, br: *Bits) Error!void {
        c.ntypes = (try varLen(br)) + 1;
        if (c.ntypes >= 2) {
            c.types = try readPrefix(arena, br, c.ntypes + 2);
            c.counts = try readPrefix(arena, br, 26);
            c.remaining = try c.readCount(br);
        }
    }

    fn readCount(c: *Category, br: *Bits) Error!u32 {
        const code = try c.counts.decode(br);
        return block_base[code] + try br.read(@intCast(block_extra[code]));
    }

    fn step(c: *Category, br: *Bits) Error!void {
        if (c.remaining != 0) {
            c.remaining -= 1;
            return;
        }
        const code = try c.types.decode(br);
        var t: u32 = switch (code) {
            0 => c.ring[0],
            1 => c.ring[1] + 1,
            else => code - 2,
        };
        if (t >= c.ntypes) t -= c.ntypes;
        c.ring[0] = c.ring[1];
        c.ring[1] = t;
        c.kind = t;
        c.remaining = (try c.readCount(br)) - 1;
    }
};

const Cmd = struct { insert_bits: u8, copy_bits: u8, insert_off: u32, copy_off: u32, implicit: bool };

fn command(sym: u32) Cmd {
    const cell = sym >> 6;
    const ins = (cell_insert[cell] << 3) | ((sym >> 3) & 7);
    const cop = (cell_copy[cell] << 3) | (sym & 7);
    return .{ .insert_bits = insert_extra[ins], .copy_bits = copy_extra[cop], .insert_off = insert_base[ins], .copy_off = copy_base[cop], .implicit = sym < 128 };
}

fn upper(p: []u8) usize {
    if (p[0] < 0xC0) {
        if (p[0] >= 'a' and p[0] <= 'z') p[0] ^= 32;
        return 1;
    }
    if (p[0] < 0xE0) {
        if (p.len > 1) p[1] ^= 32;
        return 2;
    }
    if (p.len > 2) p[2] ^= 5;
    return 3;
}

fn transformWord(out: *std.ArrayList(u8), alloc: std.mem.Allocator, word: []const u8, idx: usize) Error!void {
    const t = tables.transforms[idx * 3 ..][0..3];
    const pre = tables.prefix_suffix[tables.prefix_suffix_map[t[0]]..];
    const suf = tables.prefix_suffix[tables.prefix_suffix_map[t[2]]..];
    try out.appendSlice(alloc, pre[1..][0..pre[0]]);
    var w = word;
    const kind = t[1];
    if (kind <= 9) {
        w = w[0 .. w.len -| kind];
    } else if (kind >= 12 and kind <= 20) {
        const skip = kind - 11;
        if (skip > w.len) w = w[w.len..] else w = w[skip..];
    }
    const start = out.items.len;
    try out.appendSlice(alloc, w);
    if (kind == 10) {
        if (w.len > 0) _ = upper(out.items[start..]);
    } else if (kind == 11) {
        var p = start;
        while (p < out.items.len) p += upper(out.items[p..]);
    }
    try out.appendSlice(alloc, suf[1..][0..suf[0]]);
}

fn ctxId(mode: u32, p1: u8, p2: u8) usize {
    const lut = tables.context_lut[mode << 9 ..][0..512];
    return lut[p1] | lut[256 + @as(usize, p2)];
}

pub fn decode(alloc: std.mem.Allocator, input: []const u8, max_out: usize) Error![]u8 {
    var br = Bits{ .data = input };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var wbits: u6 = 16;
    if ((try br.bit()) == 1) {
        const n = try br.read(3);
        if (n != 0) {
            wbits = @intCast(17 + n);
        } else {
            const m = try br.read(3);
            if (m == 1) return error.Invalid;
            wbits = if (m == 0) 17 else @intCast(8 + m);
        }
    }
    const window: usize = (@as(usize, 1) << @intCast(wbits)) - 16;
    var ring = [4]usize{ 16, 15, 11, 4 };
    var ring_n: usize = 0;

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const last = (try br.bit()) == 1;
        if (last and (try br.bit()) == 1) break;
        const nib_code = try br.read(2);
        if (nib_code == 3) {
            if ((try br.bit()) != 0) return error.Invalid;
            const nbytes = try br.read(2);
            var skip: usize = 0;
            if (nbytes > 0) skip = @as(usize, try br.read(@intCast(nbytes * 8))) + 1;
            try br.align8();
            const at = br.pos >> 3;
            if (at + skip > input.len) return error.Invalid;
            br.pos += skip * 8;
            if (last) break;
            continue;
        }
        const nibbles: u6 = @intCast(nib_code + 4);
        const mlen: usize = @as(usize, try br.read(nibbles * 4)) + 1;
        if (out.items.len + mlen > max_out) return error.TooBig;
        if (!last and (try br.bit()) == 1) {
            try br.align8();
            const at = br.pos >> 3;
            if (at + mlen > input.len) return error.Invalid;
            try out.appendSlice(alloc, input[at..][0..mlen]);
            br.pos += mlen * 8;
            continue;
        }

        var cat: [3]Category = .{ .{}, .{}, .{} };
        for (&cat) |*c| try c.init(arena, &br);
        const postfix: u6 = @intCast(try br.read(2));
        const ndirect: u32 = (try br.read(4)) << @intCast(postfix);
        const modes = try arena.alloc(u8, cat[0].ntypes);
        for (modes) |*m| m.* = @intCast(try br.read(2));
        const ntrees_l = (try varLen(&br)) + 1;
        const cmap_l = try contextMap(arena, &br, @as(usize, cat[0].ntypes) * 64, ntrees_l);
        const ntrees_d = (try varLen(&br)) + 1;
        const cmap_d = try contextMap(arena, &br, @as(usize, cat[2].ntypes) * 4, ntrees_d);
        const lit_trees = try arena.alloc(Huff, ntrees_l);
        for (lit_trees) |*h| h.* = try readPrefix(arena, &br, 256);
        const cmd_trees = try arena.alloc(Huff, cat[1].ntypes);
        for (cmd_trees) |*h| h.* = try readPrefix(arena, &br, 704);
        const dist_alpha: u32 = 16 + ndirect + (@as(u32, 48) << @intCast(postfix));
        const dist_trees = try arena.alloc(Huff, ntrees_d);
        for (dist_trees) |*h| h.* = try readPrefix(arena, &br, dist_alpha);

        var remaining: usize = mlen;
        while (remaining > 0) {
            try cat[1].step(&br);
            const cmd_sym = try cmd_trees[cat[1].kind].decode(&br);
            const cmd = command(cmd_sym);
            const ins_len: usize = cmd.insert_off + try br.read(@intCast(cmd.insert_bits));
            var copy_len: usize = cmd.copy_off + try br.read(@intCast(cmd.copy_bits));
            if (ins_len > remaining) return error.Invalid;
            var k: usize = 0;
            while (k < ins_len) : (k += 1) {
                try cat[0].step(&br);
                const n = out.items.len;
                const p1: u8 = if (n >= 1) out.items[n - 1] else 0;
                const p2: u8 = if (n >= 2) out.items[n - 2] else 0;
                const cx = ctxId(modes[cat[0].kind], p1, p2);
                const tree = cmap_l[@as(usize, cat[0].kind) * 64 + cx];
                const b = try lit_trees[tree].decode(&br);
                try out.append(alloc, @intCast(b));
            }
            remaining -= ins_len;
            if (remaining == 0) break;

            var dcode: u32 = 0;
            if (!cmd.implicit) {
                try cat[2].step(&br);
                const dctx: usize = if (copy_len > 4) 3 else copy_len - 2;
                const tree = cmap_d[@as(usize, cat[2].kind) * 4 + dctx];
                dcode = try dist_trees[tree].decode(&br);
            }
            var dist: usize = 0;
            if (dcode < 16) {
                const at = struct {
                    fn get(r: [4]usize, n: usize, back: usize) i64 {
                        return @intCast(r[(n + 3 - back) & 3]);
                    }
                };
                const d: i64 = switch (dcode) {
                    0 => at.get(ring, ring_n, 0),
                    1 => at.get(ring, ring_n, 1),
                    2 => at.get(ring, ring_n, 2),
                    3 => at.get(ring, ring_n, 3),
                    4 => at.get(ring, ring_n, 0) - 1,
                    5 => at.get(ring, ring_n, 0) + 1,
                    6 => at.get(ring, ring_n, 0) - 2,
                    7 => at.get(ring, ring_n, 0) + 2,
                    8 => at.get(ring, ring_n, 0) - 3,
                    9 => at.get(ring, ring_n, 0) + 3,
                    10 => at.get(ring, ring_n, 1) - 1,
                    11 => at.get(ring, ring_n, 1) + 1,
                    12 => at.get(ring, ring_n, 1) - 2,
                    13 => at.get(ring, ring_n, 1) + 2,
                    14 => at.get(ring, ring_n, 1) - 3,
                    else => at.get(ring, ring_n, 1) + 3,
                };
                if (d <= 0) return error.Invalid;
                dist = @intCast(d);
            } else if (dcode < 16 + ndirect) {
                dist = dcode - 15;
            } else {
                const v = dcode - ndirect - 16;
                const nb: u6 = @intCast(1 + (v >> @intCast(postfix + 1)));
                const hcode = v >> @intCast(postfix);
                const lcode = v & ((@as(u32, 1) << @intCast(postfix)) - 1);
                const offset: u64 = ((@as(u64, 2) + (hcode & 1)) << @intCast(nb)) - 4;
                const extra = try br.read(nb);
                dist = @intCast(((offset + extra) << @intCast(postfix)) + lcode + ndirect + 1);
            }

            const max_dist = @min(window, out.items.len);
            if (dist <= max_dist) {
                if (dcode != 0) {
                    ring[ring_n & 3] = dist;
                    ring_n += 1;
                }
                const n_copy = copy_len;
                if (n_copy > remaining) return error.Invalid;
                if (out.items.len + n_copy > max_out) return error.TooBig;
                try out.ensureUnusedCapacity(alloc, copy_len);
                var s = out.items.len - dist;
                while (copy_len > 0) : (copy_len -= 1) {
                    out.appendAssumeCapacity(out.items[s]);
                    s += 1;
                }
                remaining -= n_copy;
            } else {
                if (copy_len < 4 or copy_len > 24) return error.Invalid;
                const word_id = dist - max_dist - 1;
                const shift: u5 = @intCast(dict_size_bits[copy_len]);
                const widx = word_id & ((@as(usize, 1) << shift) - 1);
                const tidx = word_id >> shift;
                if (tidx >= 121) return error.Invalid;
                const off = dict_offsets[copy_len] + widx * copy_len;
                const before = out.items.len;
                try transformWord(&out, alloc, dictionary[off..][0..copy_len], tidx);
                const added = out.items.len - before;
                if (added > remaining) return error.Invalid;
                if (out.items.len > max_out) return error.TooBig;
                remaining -= added;
            }
        }
        if (last) break;
    }
    return out.toOwnedSlice(alloc);
}

