const std = @import("std");
const image = @import("image.zig");
const Error = image.Error;
const Image = image.Image;

// loop_count is total plays: a NETSCAPE2.0 count of n means n + 1 plays, none means one play.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Image {
    var c: image.Cursor = .{ .b = bytes, .pos = 6 };
    const sw = try c.le16();
    const sh = try c.le16();
    const flags = try c.byte();
    _ = try c.byte();
    _ = try c.byte();
    try image.checkDims(sw, sh);
    var global: ?[]const u8 = null;
    if (flags & 0x80 != 0) global = try c.take(@as(usize, 3) << @intCast((flags & 7) + 1));

    var list = image.FrameList.init(alloc);
    defer list.deinit();
    const canvas = try image.allocRgba(alloc, sw, sh);
    defer alloc.free(canvas);
    @memset(canvas, 0);
    var saved: ?[]u8 = null;
    defer if (saved) |s| alloc.free(s);

    var loops: u32 = 1;
    var delay: u32 = 0;
    var dispose: u8 = 0;
    var transparent: ?u8 = null;
    var prev_dispose: u8 = 0;
    var prev_rect: [4]usize = .{ 0, 0, 0, 0 };
    var index_buf: std.ArrayList(u8) = .empty;
    defer index_buf.deinit(alloc);
    const lzw = try alloc.create(Lzw);
    defer alloc.destroy(lzw);
    lzw.* = .{};

    outer: while (true) {
        const intro = c.byte() catch break;
        switch (intro) {
            0x3B => break,
            0x21 => {
                const label = c.byte() catch break;
                if (label == 0xF9) {
                    const sz = c.byte() catch break;
                    const blk = c.take(sz) catch break;
                    if (sz >= 4) {
                        dispose = (blk[0] >> 2) & 7;
                        delay = @as(u32, std.mem.readInt(u16, blk[1..3], .little)) * 10;
                        transparent = if (blk[0] & 1 != 0) blk[3] else null;
                    }
                    skipBlocks(&c) catch break;
                } else if (label == 0xFF) {
                    const sz = c.byte() catch break;
                    const blk = c.take(sz) catch break;
                    if (sz == 11 and std.mem.eql(u8, blk, "NETSCAPE2.0")) {
                        while (true) {
                            const n = c.byte() catch break :outer;
                            if (n == 0) break;
                            const d = c.take(n) catch break :outer;
                            if (n >= 3 and d[0] == 1) {
                                const cnt = std.mem.readInt(u16, d[1..3], .little);
                                loops = if (cnt == 0) 0 else @as(u32, cnt) + 1;
                            }
                        }
                    } else skipBlocks(&c) catch break;
                } else skipBlocks(&c) catch break;
            },
            0x2C => {
                const frame_ok = decodeFrame(alloc, &c, global, canvas, sw, sh, transparent, dispose, prev_dispose, &prev_rect, &saved, &index_buf, lzw);
                if (frame_ok) |complete| {
                    if (complete or list.list.items.len == 0) {
                        const copy = try alloc.dupe(u8, canvas);
                        errdefer alloc.free(copy);
                        try list.add(sw, sh, copy, delay);
                    }
                    if (!complete) break;
                } else |e| {
                    if (list.list.items.len == 0 or e == error.OutOfMemory or e == error.TooLarge) return e;
                    break;
                }
                prev_dispose = dispose;
                dispose = 0;
                delay = 0;
                transparent = null;
            },
            else => {
                if (list.list.items.len == 0) return error.Corrupt;
                break;
            },
        }
    }
    if (list.list.items.len == 0) return error.Corrupt;
    return list.finish(sw, sh, loops);
}

fn skipBlocks(c: *image.Cursor) Error!void {
    while (true) {
        const n = try c.byte();
        if (n == 0) return;
        _ = try c.take(n);
    }
}

fn decodeFrame(
    alloc: std.mem.Allocator,
    c: *image.Cursor,
    global: ?[]const u8,
    canvas: []u8,
    sw: u32,
    sh: u32,
    transparent: ?u8,
    dispose: u8,
    prev_dispose: u8,
    prev_rect: *[4]usize,
    saved: *?[]u8,
    index_buf: *std.ArrayList(u8),
    lzw: *Lzw,
) Error!bool {
    const fx = try c.le16();
    const fy = try c.le16();
    const fw = try c.le16();
    const fh = try c.le16();
    const fl = try c.byte();
    var table = global;
    if (fl & 0x80 != 0) table = try c.take(@as(usize, 3) << @intCast((fl & 7) + 1));
    const interlaced = fl & 0x40 != 0;
    const min_code = try c.byte();
    if (min_code < 1 or min_code > 8) return error.Corrupt;

    if (prev_dispose == 2) {
        for (0..prev_rect[3]) |y| {
            if (prev_rect[1] + y >= sh) break;
            const x1 = @min(prev_rect[0] + prev_rect[2], sw);
            if (x1 <= prev_rect[0]) continue;
            @memset(canvas[((prev_rect[1] + y) * sw + prev_rect[0]) * 4 .. ((prev_rect[1] + y) * sw + x1) * 4], 0);
        }
    } else if (prev_dispose == 3) {
        if (saved.*) |s| @memcpy(canvas, s);
    }
    if (dispose == 3) {
        if (saved.* == null) saved.* = try alloc.alloc(u8, canvas.len);
        @memcpy(saved.*.?, canvas);
    }
    prev_rect.* = .{ fx, fy, fw, fh };

    const npix = @as(usize, fw) * fh;
    if (npix > image.max_pixels) return error.TooLarge;
    index_buf.clearRetainingCapacity();
    try index_buf.resize(alloc, npix);
    @memset(index_buf.items, 0);
    const got = try lzw.decode(c, min_code, index_buf.items);
    lzw.finish(c);
    if (got == 0 and npix > 0) return error.Corrupt;
    const limit: usize = if (lzw.truncated) got else npix;
    const rows_done: usize = if (fw == 0) fh else (limit + fw - 1) / fw;

    const tbl = table orelse return error.Corrupt;
    const ncol = tbl.len / 3;
    var row_src: usize = 0;
    const pass_start = [4]usize{ 0, 4, 2, 1 };
    const pass_step = [4]usize{ 8, 8, 4, 2 };
    var pass: usize = 0;
    var y: usize = 0;
    while (row_src < rows_done) : (row_src += 1) {
        var yy: usize = row_src;
        var row_pass: usize = 3;
        if (interlaced) {
            yy = y;
            row_pass = pass;
            y += pass_step[pass];
            while (y >= fh and pass < 3) {
                pass += 1;
                y = pass_start[pass];
            }
        }
        const first_row: i64 = @intCast(yy);
        var last_row: i64 = first_row;
        if (interlaced and lzw.truncated and row_pass < 3 and limit - row_src * fw >= fw) {
            const dup: i64 = if (row_pass == 0) 7 else if (row_pass == 1) 3 else 1;
            last_row = @min(first_row + dup, @as(i64, @intCast(fh)) - 1);
        }
        const src = index_buf.items[row_src * fw ..][0..@min(fw, limit - row_src * fw)];
        var ry = first_row;
        while (ry <= last_row) : (ry += 1) {
            const cy = fy + @as(usize, @intCast(ry));
            if (cy >= sh) break;
            for (src, 0..) |idx, x| {
                const cx = fx + x;
                if (cx >= sw) break;
                if (transparent != null and transparent.? == idx) continue;
                if (idx >= ncol) continue;
                const t = @as(usize, idx) * 3;
                canvas[(cy * sw + cx) * 4 ..][0..4].* = .{ tbl[t], tbl[t + 1], tbl[t + 2], 255 };
            }
        }
    }
    return !lzw.truncated;
}

const Lzw = struct {
    prefix: [4096]u16 = @splat(0),
    suffix: [4096]u8 = @splat(0),
    stack: [4097]u8 = @splat(0),
    block_left: usize = 0,
    ended: bool = false,
    truncated: bool = false,

    fn finish(self: *Lzw, c: *image.Cursor) void {
        if (self.ended) return;
        _ = c.take(self.block_left) catch return;
        skipBlocks(c) catch return;
    }

    // Returns the number of pixels written; a short stream is not an error here.
    fn decode(self: *Lzw, c: *image.Cursor, min_code: u8, out: []u8) Error!usize {
        const clear: u32 = @as(u32, 1) << @intCast(min_code);
        const eoi = clear + 1;
        var code_size: u5 = @intCast(min_code + 1);
        var next: u32 = eoi + 1;
        var prev: i32 = -1;
        var first: u8 = 0;
        var bits: u32 = 0;
        var nbits: u5 = 0;
        var pos: usize = 0;
        for (0..clear) |i| {
            self.prefix[i] = 0;
            self.suffix[i] = @intCast(i);
        }
        self.block_left = 0;
        self.ended = false;
        self.truncated = false;
        while (true) {
            while (nbits < code_size) {
                while (self.block_left == 0) {
                    const n = c.byte() catch {
                        self.ended = true;
                        self.truncated = true;
                        return pos;
                    };
                    if (n == 0) {
                        self.ended = true;
                        return pos;
                    }
                    self.block_left = n;
                }
                const b = c.byte() catch {
                    self.ended = true;
                    self.truncated = true;
                    return pos;
                };
                self.block_left -= 1;
                bits |= @as(u32, b) << nbits;
                nbits += 8;
            }
            const code = bits & ((@as(u32, 1) << code_size) - 1);
            bits >>= code_size;
            nbits -= code_size;
            if (code == clear) {
                code_size = @intCast(min_code + 1);
                next = eoi + 1;
                prev = -1;
                continue;
            }
            if (code == eoi) break;
            if (prev < 0) {
                if (code >= clear) return error.Corrupt;
                if (pos >= out.len) break;
                out[pos] = @intCast(code);
                pos += 1;
                prev = @intCast(code);
                first = @intCast(code);
                continue;
            }
            var sp: usize = 0;
            var cur = code;
            if (code >= next) {
                if (code > next) return error.Corrupt;
                self.stack[sp] = first;
                sp += 1;
                cur = @intCast(prev);
            }
            while (cur >= clear) {
                if (sp >= self.stack.len - 1) return error.Corrupt;
                self.stack[sp] = self.suffix[cur];
                sp += 1;
                cur = self.prefix[cur];
            }
            first = self.suffix[cur];
            self.stack[sp] = first;
            sp += 1;
            var k = sp;
            while (k > 0) {
                k -= 1;
                if (pos >= out.len) break;
                out[pos] = self.stack[k];
                pos += 1;
            }
            if (next < 4096) {
                self.prefix[next] = @intCast(prev);
                self.suffix[next] = first;
                next += 1;
                if (next == (@as(u32, 1) << code_size) and code_size < 12) code_size += 1;
            }
            prev = @intCast(code);
            if (pos >= out.len) break;
        }
        return pos;
    }
};
