const std = @import("std");
const aritab = @import("jpeg_arith_table.zig").table;
const zigzag = @import("jpeg.zig").zigzag;

pub const Arith = struct {
    data: []const u8,
    pos: usize,
    c: i64 = 0,
    a: i64 = 0,
    ct: i32 = -16,
    marker: bool = false,
    bad: bool = false,
    failed: bool = false,
    dc_stats: [4][64]u8 = @splat(@splat(0)),
    ac_stats: [4][256]u8 = @splat(@splat(0)),
    fixed: u8 = 113,

    pub fn init(data: []const u8, pos: usize) Arith {
        return .{ .data = data, .pos = pos };
    }

    pub fn resetCoder(self: *Arith) void {
        self.c = 0;
        self.a = 0;
        self.ct = -16;
    }

    fn nextByte(self: *Arith) u8 {
        if (self.marker) return 0;
        if (self.pos >= self.data.len) {
            self.bad = true;
            self.marker = true;
            return 0;
        }
        const d = self.data[self.pos];
        self.pos += 1;
        if (d != 0xFF) return d;
        while (self.pos < self.data.len and self.data[self.pos] == 0xFF) self.pos += 1;
        if (self.pos >= self.data.len) {
            self.bad = true;
            self.marker = true;
            return 0;
        }
        const code = self.data[self.pos];
        self.pos += 1;
        if (code == 0) return 0xFF;
        self.pos -= 2;
        self.marker = true;
        return 0;
    }

    pub fn restart(self: *Arith) bool {
        var p = self.pos;
        while (p + 1 < self.data.len) : (p += 1) {
            if (self.data[p] == 0xFF and self.data[p + 1] != 0 and self.data[p + 1] != 0xFF) break;
        }
        if (p + 1 >= self.data.len or self.data[p + 1] < 0xD0 or self.data[p + 1] > 0xD7) return false;
        self.pos = p + 2;
        self.marker = false;
        self.resetCoder();
        return true;
    }

    fn decode(self: *Arith, st: *u8) u32 {
        while (self.a < 0x8000) {
            self.ct -= 1;
            if (self.ct < 0) {
                const data = self.nextByte();
                self.c = (self.c << 8) | data;
                self.ct += 8;
                if (self.ct < 0) {
                    self.ct += 1;
                    if (self.ct == 0) self.a = 0x8000;
                }
            }
            self.a <<= 1;
        }
        var sv: u32 = st.*;
        const ent = aritab[sv & 0x7f];
        const nl: u32 = ent & 0xff;
        const nm: u32 = (ent >> 8) & 0xff;
        const qe: i64 = ent >> 16;
        var temp = self.a - qe;
        self.a = temp;
        temp <<= @intCast(self.ct);
        if (self.c >= temp) {
            self.c -= temp;
            if (self.a < qe) {
                self.a = qe;
                st.* = @intCast((sv & 0x80) ^ nm);
            } else {
                self.a = qe;
                st.* = @intCast((sv & 0x80) ^ nl);
                sv ^= 0x80;
            }
        } else if (self.a < 0x8000) {
            if (self.a < qe) {
                st.* = @intCast((sv & 0x80) ^ nl);
                sv ^= 0x80;
            } else {
                st.* = @intCast((sv & 0x80) ^ nm);
            }
        }
        return sv >> 7;
    }

    fn dcDiff(self: *Arith, tbl: usize, ctx: *usize, last: *i32, l: u5, u: u5) void {
        const stats = &self.dc_stats[tbl];
        var st: usize = ctx.*;
        if (self.decode(&stats[st]) == 0) {
            ctx.* = 0;
            return;
        }
        const sign = self.decode(&stats[st + 1]);
        st += 2 + sign;
        var m: u32 = self.decode(&stats[st]);
        if (m != 0) {
            st = 20;
            while (self.decode(&stats[st]) != 0) {
                m <<= 1;
                if (m == 0x8000) {
                    self.failed = true;
                    return;
                }
                st += 1;
            }
        }
        if (m < (@as(u32, 1) << l) >> 1) {
            ctx.* = 0;
        } else if (m > (@as(u32, 1) << u) >> 1) {
            ctx.* = 12 + sign * 4;
        } else {
            ctx.* = 4 + sign * 4;
        }
        var v: i32 = @intCast(m);
        st += 14;
        var mm = m;
        while (true) {
            mm >>= 1;
            if (mm == 0) break;
            if (self.decode(&stats[st]) != 0) v |= @intCast(mm);
        }
        v += 1;
        if (sign != 0) v = -v;
        last.* = (last.* + v) & 0xffff;
    }

    fn acCoefs(self: *Arith, co: []i16, tbl: usize, ss: usize, se: usize, kx: u8, al: u5) void {
        const stats = &self.ac_stats[tbl];
        var k = ss;
        while (k <= se) : (k += 1) {
            var st: usize = 3 * (k - 1);
            if (self.decode(&stats[st]) != 0) break;
            while (self.decode(&stats[st + 1]) == 0) {
                st += 3;
                k += 1;
                if (k > se) {
                    self.failed = true;
                    return;
                }
            }
            const sign = self.decode(&self.fixed);
            st += 2;
            var m: u32 = self.decode(&stats[st]);
            if (m != 0) {
                if (self.decode(&stats[st]) != 0) {
                    m <<= 1;
                    st = if (k <= kx) 189 else 217;
                    while (self.decode(&stats[st]) != 0) {
                        m <<= 1;
                        if (m == 0x8000) {
                            self.failed = true;
                            return;
                        }
                        st += 1;
                    }
                }
            }
            var v: i32 = @intCast(m);
            st += 14;
            var mm = m;
            while (true) {
                mm >>= 1;
                if (mm == 0) break;
                if (self.decode(&stats[st]) != 0) v |= @intCast(mm);
            }
            v += 1;
            if (sign != 0) v = -v;
            co[zigzag[k]] = @truncate(v << al);
        }
    }

    pub fn sequential(self: *Arith, co: []i16, dc_tbl: usize, ac_tbl: usize, ctx: *usize, last: *i32, l: u5, u: u5, kx: u8) void {
        if (self.failed) return;
        self.dcDiff(dc_tbl, ctx, last, l, u);
        if (self.failed) return;
        co[0] = @truncate(last.*);
        self.acCoefs(co, ac_tbl, 1, 63, kx, 0);
    }

    pub fn dcFirst(self: *Arith, co: []i16, tbl: usize, ctx: *usize, last: *i32, l: u5, u: u5, al: u5) void {
        if (self.failed) return;
        self.dcDiff(tbl, ctx, last, l, u);
        if (self.failed) return;
        co[0] = @truncate(last.* << al);
    }

    pub fn acFirst(self: *Arith, co: []i16, tbl: usize, ss: usize, se: usize, kx: u8, al: u5) void {
        if (self.failed) return;
        self.acCoefs(co, tbl, ss, se, kx, al);
    }

    pub fn dcRefine(self: *Arith, co: []i16, al: u5) void {
        if (self.decode(&self.fixed) != 0) co[0] |= @as(i16, 1) << @intCast(al);
    }

    pub fn acRefine(self: *Arith, co: []i16, tbl: usize, ss: usize, se: usize, al: u5) void {
        if (self.failed) return;
        const stats = &self.ac_stats[tbl];
        const p1: i16 = @as(i16, 1) << @intCast(al);
        const m1: i16 = -p1;
        var kex: usize = se;
        while (kex > 0) : (kex -= 1) {
            if (co[zigzag[kex]] != 0) break;
        }
        var k = ss;
        while (k <= se) : (k += 1) {
            var st: usize = 3 * (k - 1);
            if (k > kex) {
                if (self.decode(&stats[st]) != 0) break;
            }
            while (true) {
                const t = &co[zigzag[k]];
                if (t.* != 0) {
                    if (self.decode(&stats[st + 2]) != 0) {
                        t.* +%= if (t.* < 0) m1 else p1;
                    }
                    break;
                }
                if (self.decode(&stats[st + 1]) != 0) {
                    t.* = if (self.decode(&self.fixed) != 0) m1 else p1;
                    break;
                }
                st += 3;
                k += 1;
                if (k > se) {
                    self.failed = true;
                    return;
                }
            }
        }
    }
};
