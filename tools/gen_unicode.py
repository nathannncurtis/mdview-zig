#!/usr/bin/env python3
"""Generates src/unicode.zig from the Unicode Character Database.

usage: gen_unicode.py <UnicodeData.txt> <out.zig>

SpecialCasing.txt and CaseFolding.txt are read from the same directory as UnicodeData.txt.
The output holds general categories, full lowercase and full case folding as packed sorted
ranges, plus a hash of every lookup result that the generated test recomputes.
"""
import os
import sys

CATS = ["letter", "mark", "number", "punctuation", "symbol", "space_separator", "other_separator", "other"]
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK = (1 << 64) - 1
MAX_CP = 0x110000


def cat_index(gc):
    if gc in ("Zs",):
        return 5
    if gc in ("Zl", "Zp"):
        return 6
    return {"L": 0, "M": 1, "N": 2, "P": 3, "S": 4}.get(gc[0], 7)


def read_unicode_data(path):
    cats = [7] * MAX_CP
    lower = {}
    first = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split(";")
            if len(fields) < 14:
                continue
            cp = int(fields[0], 16)
            name, gc = fields[1], fields[2]
            c = cat_index(gc)
            if name.endswith(", First>"):
                first = cp
                continue
            lo = first if name.endswith(", Last>") else cp
            for x in range(lo, cp + 1):
                cats[x] = c
            first = None
            if fields[13]:
                lower[cp] = [int(fields[13], 16)]
    return cats, lower


def read_special_lower(path, lower):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(";")]
            if len(parts) < 5 or parts[4] != "":
                continue
            cp = int(parts[0], 16)
            seq = [int(x, 16) for x in parts[1].split()]
            lower[cp] = seq


def read_fold(path):
    fold = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(";")]
            if parts[1] not in ("C", "F"):
                continue
            fold[int(parts[0], 16)] = [int(x, 16) for x in parts[2].split()]
    return fold


def runs(mapping):
    """Single-codepoint mappings as (start, len, stride, delta) runs; multi-codepoint ones separately."""
    single = sorted((cp, m[0]) for cp, m in mapping.items() if len(m) == 1 and m[0] != cp)
    multi = sorted((cp, m) for cp, m in mapping.items() if len(m) > 1)
    out = []
    i = 0
    while i < len(single):
        cp, to = single[i]
        delta = to - cp
        best = (1, 1)
        for stride in (1, 2):
            n = 1
            while (
                i + n < len(single)
                and single[i + n][0] == cp + n * stride
                and single[i + n][1] - single[i + n][0] == delta
            ):
                n += 1
            if n * 1 > best[0] and n > 1:
                best = (n, stride)
        n, stride = best
        out.append((cp, n, stride, delta))
        i += n
    return out, multi


def fnv(h, value):
    for b in value.to_bytes(4, "little"):
        h = ((h ^ b) * FNV_PRIME) & MASK
    return h


def category_hash(cats):
    h = FNV_OFFSET
    for c in cats:
        h = ((h ^ c) * FNV_PRIME) & MASK
    return h


def mapping_hash(mapping):
    h = FNV_OFFSET
    for cp in range(MAX_CP):
        m = mapping.get(cp, [cp])
        h = fnv(h, len(m))
        for x in m:
            h = fnv(h, x)
    return h


def fmt(values, per_line=16):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append("    " + ", ".join(str(v) for v in values[i : i + per_line]) + ",")
    return "\n".join(lines)


def uint_type(top):
    for bits in (8, 16, 32, 64):
        if top < (1 << bits):
            return "u%d" % bits


def int_type(low, high):
    for bits in (8, 16, 32, 64):
        if -(1 << (bits - 1)) <= low and high < (1 << (bits - 1)):
            return "i%d" % bits


def array(name, kind, values):
    return "const %s = [_]%s{\n%s\n};" % (name, kind, fmt(values))


def emit_mapping(name, mapping):
    rs, multi = runs(mapping)
    pool = []
    multi_at = []
    for _, seq in multi:
        multi_at.append(len(pool))
        pool.extend(seq)
    deltas = [r[3] for r in rs] or [0]
    types = {
        "len": uint_type(max([r[1] for r in rs] or [0])),
        "stride": uint_type(max([r[2] for r in rs] or [0])),
        "delta": int_type(min(deltas), max(deltas)),
        "multi_len": uint_type(max([len(sq) for _, sq in multi] or [0])),
        "multi_at": uint_type(max(multi_at or [0])),
        "pool": "u16" if max(pool or [0]) < 0x10000 else "u21",
    }
    out = [
        array("%s_start_lo" % name, "u16", [r[0] & 0xFFFF for r in rs]),
        array("%s_start_hi" % name, "u8", [r[0] >> 16 for r in rs]),
        array("%s_len" % name, types["len"], [r[1] for r in rs]),
        array("%s_stride" % name, types["stride"], [r[2] for r in rs]),
        array("%s_delta" % name, types["delta"], [r[3] for r in rs]),
        array("%s_multi_lo" % name, "u16", [c & 0xFFFF for c, _ in multi]),
        array("%s_multi_hi" % name, "u8", [c >> 16 for c, _ in multi]),
        array("%s_multi_len" % name, types["multi_len"], [len(sq) for _, sq in multi]),
        array("%s_multi_at" % name, types["multi_at"], multi_at),
        array("%s_pool" % name, types["pool"], pool),
    ]
    longest = max([len(sq) for _, sq in multi] + [1])
    decl = "const %s_map: Mapping(%s, %s, %s, %s, %s, %s) = .{\n" % (
        name, types["len"], types["stride"], types["delta"], types["multi_len"], types["multi_at"], types["pool"])
    for field in ("start_lo", "start_hi", "len", "stride", "delta", "multi_lo", "multi_hi", "multi_len", "multi_at", "pool"):
        decl += "    .%s = &%s_%s,\n" % (field, name, field)
    decl += "};"
    out.append(decl)
    return "\n\n".join(out), len(rs), len(multi), len(pool), longest


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ucd, out_path = sys.argv[1], sys.argv[2]
    base = os.path.dirname(os.path.abspath(ucd))
    cats, lower = read_unicode_data(ucd)
    read_special_lower(os.path.join(base, "SpecialCasing.txt"), lower)
    fold = read_fold(os.path.join(base, "CaseFolding.txt"))

    keys = []
    prev = None
    for cp, c in enumerate(cats):
        if c != prev:
            keys.append((cp << 3) | c)
            prev = c
    low_part, lr, lm, lp, low_longest = emit_mapping("lower", lower)
    fold_part, fr, fm, fp, fold_longest = emit_mapping("fold", fold)

    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "unicode_tail.zig.in"), encoding="utf-8").read()
    head = "// Generated by tools/gen_unicode.py from the Unicode Character Database. Do not edit.\n\n"
    head += "const std = @import(\"std\");\n\n"
    head += "pub const Category = enum(u3) { %s };\n\n" % ", ".join(CATS)
    head += "const category_key_lo = [_]u16{\n%s\n};\n\n" % fmt([k & 0xFFFF for k in keys])
    head += "const category_key_hi = [_]u8{\n%s\n};\n\n" % fmt([k >> 16 for k in keys])
    head += "pub const max_mapping_len = %d;\n\n" % max(low_longest, fold_longest)
    head += low_part + "\n\n" + fold_part + "\n\n"
    head += "const category_hash: u64 = %d;\nconst lower_hash: u64 = %d;\nconst fold_hash: u64 = %d;\n\n" % (
        category_hash(cats), mapping_hash(lower), mapping_hash(fold))
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(head + src)
    print("category ranges: %d, lower runs: %d + %d multi (%d pool), fold runs: %d + %d multi (%d pool)" % (len(keys), lr, lm, lp, fr, fm, fp))


main()
