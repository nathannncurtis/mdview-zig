import sys

BLOCK = 64

LOOKUP = '''
pub fn lookup(key: []const u8) ?[]const u8 {
    if (key.len == 0 or key.len > max_name) return null;
    var buf: [max_name]u8 = undefined;
    var lo: usize = 0;
    var hi: usize = restarts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        var n: usize = 0;
        var pos: usize = restarts[mid] + 1;
        while (true) : (pos += 1) {
            buf[n] = names[pos] & 0x7f;
            n += 1;
            if (names[pos] & 0x80 != 0) break;
        }
        if (std.mem.order(u8, buf[0..n], key) == .gt) hi = mid else lo = mid;
    }
    var pos: usize = restarts[lo];
    var idx = lo * block;
    const end = @min(idx + block, count);
    while (idx < end) : (idx += 1) {
        var n: usize = names[pos];
        pos += 1;
        while (true) : (pos += 1) {
            buf[n] = names[pos] & 0x7f;
            n += 1;
            if (names[pos] & 0x80 != 0) break;
        }
        pos += 1;
        switch (std.mem.order(u8, buf[0..n], key)) {
            .eq => {
                const bit = idx * ref_bits;
                const at = bit / 8;
                const raw = @as(u32, refs[at]) | @as(u32, refs[at + 1]) << 8 | @as(u32, refs[at + 2]) << 16 | @as(u32, refs[at + 3]) << 24;
                const ref = (raw >> @intCast(bit % 8)) & ((1 << ref_bits) - 1);
                return values[ref & ((1 << off_bits) - 1) ..][0 .. ref >> off_bits];
            },
            .gt => return null,
            .lt => {},
        }
    }
    return null;
}
'''


def literal(data, width=100):
    parts = []
    for i in range(0, len(data), width):
        out = []
        for b in data[i:i + width]:
            ch = chr(b)
            if ch == '"' or ch == "\\":
                out.append("\\" + ch)
            elif 0x20 <= b < 0x7F:
                out.append(ch)
            else:
                out.append("\\x%02x" % b)
        parts.append('"' + "".join(out) + '"')
    return " ++\n    ".join(parts) if parts else '""'


def int_array(name, ctype, items):
    rows = []
    for i in range(0, len(items), 16):
        rows.append("    " + ", ".join(str(x) for x in items[i:i + 16]) + ",")
    return "const %s = [_]%s{\n%s\n};" % (name, ctype, "\n".join(rows))


def zig_escape(data):
    return "".join("\\u{%X}" % ord(ch) for ch in data.decode("utf-8"))


def source(entries, header, tests, block=BLOCK, share=True):
    """entries: {ascii name: utf-8 bytes}. Returns the Zig source of a packed table with lookup()."""
    names = sorted(entries, key=lambda n: n.encode("ascii"))
    stream = bytearray()
    restarts = []
    prev = ""
    for i, name in enumerate(names):
        raw = name.encode("ascii")
        if not all(0x20 < c < 0x7F for c in raw):
            raise SystemExit("unsupported name: " + name)
        if i % block == 0:
            restarts.append(len(stream))
            prefix = 0
        else:
            prefix = 0
            while prefix < min(len(name), len(prev)) and name[prefix] == prev[prefix]:
                prefix += 1
        suffix = bytearray(raw[prefix:])
        if not suffix:
            raise SystemExit("name is a prefix of its predecessor: " + name)
        suffix[-1] |= 0x80
        stream.append(prefix)
        stream += suffix
        prev = name

    blob = bytearray()
    placed = {}
    distinct = sorted(set(entries.values()), key=lambda v: (-len(v), v))
    for v in distinct:
        at = blob.find(v) if share else -1
        if at < 0:
            at = len(blob)
            blob += v
        placed[v] = at
    val_off = [placed[entries[n]] for n in names]
    val_len = [len(entries[n]) for n in names]
    off_bits = max(max(val_off).bit_length(), 1)
    len_bits = max(val_len).bit_length()
    ref_bits = off_bits + len_bits
    if len(stream) > 0xFFFF or ref_bits > 24:
        raise SystemExit("table too large for the packing")
    bits = 0
    for i, (o, n) in enumerate(zip(val_off, val_len)):
        bits |= (o | n << off_bits) << (i * ref_bits)
    refs = bits.to_bytes((len(names) * ref_bits + 7) // 8 + 3, "little")

    lines = [
        header,
        'const std = @import("std");',
        "",
        "const count = %d;" % len(names),
        "const block = %d;" % block,
        "const max_name = %d;" % max(len(n) for n in names),
        "",
        "const names = " + literal(bytes(stream)) + ";",
        "",
        int_array("restarts", "u16", restarts),
        "",
        "const off_bits = %d;" % off_bits,
        "const ref_bits = %d;" % ref_bits,
        "const refs = " + literal(refs) + ";",
        "",
        "const values = " + literal(bytes(blob)) + ";",
        LOOKUP.rstrip("\n"),
        "",
        tests,
        "",
        'test "every entry round-trips" {',
        "    const expected = [_][2][]const u8{",
    ]
    for n in names:
        lines.append('        .{ "%s", "%s" },' % (n, zig_escape(entries[n])))
    lines += [
        "    };",
        "    try std.testing.expectEqual(@as(usize, count), expected.len);",
        "    var probe: [max_name + 1]u8 = undefined;",
        "    for (expected) |e| {",
        "        try std.testing.expectEqualStrings(e[1], lookup(e[0]).?);",
        "        @memcpy(probe[0..e[0].len], e[0]);",
        "        probe[e[0].len] = '~';",
        "        if (e[0].len < max_name) try std.testing.expect(lookup(probe[0 .. e[0].len + 1]) == null);",
        "        if (e[0].len > 1) {",
        "            const shorter = e[0][0 .. e[0].len - 1];",
        "            var present = false;",
        "            for (expected) |o| present = present or std.mem.eql(u8, o[0], shorter);",
        "            if (!present) try std.testing.expect(lookup(shorter) == null);",
        "        }",
        "    }",
        "}",
        "",
    ]
    return "\n".join(lines), len(stream), len(blob), len(restarts), len(names)


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
