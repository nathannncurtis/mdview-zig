#!/usr/bin/env python3
"""Runs gen_unicode.py on synthetic data past every width the real data stays under,
then compiles the output and runs its round-trip tests.

usage: test_gen_unicode.py [path-to-zig]
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def unicode_data_line(cp, name, gc, lower=None):
    return "%04X;%s;%s;0;L;;;;;N;;;;%s;" % (cp, name, gc, "%04X" % lower if lower is not None else "")


def write_inputs(directory):
    data = [
        unicode_data_line(0x41, "LATIN CAPITAL LETTER A", "Lu", 0x61),
        unicode_data_line(0x61, "LATIN SMALL LETTER A", "Ll"),
        unicode_data_line(0x20, "SPACE", "Zs"),
        unicode_data_line(0x4E00, "<CJK, First>", "Lo"),
        unicode_data_line(0x9FFF, "<CJK, Last>", "Lo"),
    ]
    for i in range(700):
        data.append(unicode_data_line(0x1000 + i, "LONG RUN %d" % i, "Lu", 0x21000 + i))
    for i in range(600):
        data.append(unicode_data_line(0x3000 + 2 * i, "ALTERNATING %d" % i, "Lu", 0x3001 + 2 * i))
    for i in range(4):
        data.append(unicode_data_line(0x10F000 + i, "FAR %d" % i, "Lu", 0x20 + i))
    data.sort(key=lambda line: int(line.split(";")[0], 16))
    with open(os.path.join(directory, "UnicodeData.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(data) + "\n")

    with open(os.path.join(directory, "SpecialCasing.txt"), "w", encoding="utf-8") as f:
        f.write("2000; 1D400 1D401 1D402 1D403 1D404; 2000; 2000; # five codepoints, two above the BMP\n")

    with open(os.path.join(directory, "CaseFolding.txt"), "w", encoding="utf-8") as f:
        f.write("0041; C; 0061; # A\n")
        for i in range(14000):
            seq = " ".join("%X" % (0x1D400 + (i + k) % 90) for k in range(5))
            f.write("%X; F; %s; # synthetic\n" % (0x30000 + i, seq))


def main():
    zig = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("ZIG", "zig")
    with tempfile.TemporaryDirectory() as tmp:
        write_inputs(tmp)
        out = os.path.join(tmp, "unicode.zig")
        subprocess.run([sys.executable, os.path.join(HERE, "gen_unicode.py"), os.path.join(tmp, "UnicodeData.txt"), out], check=True)
        text = open(out, encoding="utf-8").read()
        for expected in (
            "pub const max_mapping_len = 5;",
            "const lower_len = [_]u16",
            "const lower_delta = [_]i32",
            "const fold_pool = [_]u21",
            "const fold_multi_at = [_]u32",
            "const fold_multi_len = [_]u8",
        ):
            if expected not in text:
                sys.exit("generated code is missing: " + expected)
        subprocess.run([zig, "test", out], check=True)
    print("synthetic round trip passed")


main()
