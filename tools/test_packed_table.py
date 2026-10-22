import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import packed_table

ZIG = os.environ.get("ZIG") or shutil.which("zig")
ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789_+-"


def random_text(rng, max_chars):
    chars = []
    for _ in range(rng.randint(1, max_chars)):
        cp = rng.choice([rng.randint(0x21, 0x7E), rng.randint(0xA0, 0x7FF), rng.randint(0x800, 0xD7FF), rng.randint(0x10000, 0x1FAFF)])
        chars.append(chr(cp))
    return "".join(chars).encode("utf-8")


def synthetic(count, max_value_chars, seed):
    rng = random.Random(seed)
    entries = {}
    while len(entries) < count:
        name = "".join(rng.choice(ALPHABET) for _ in range(rng.randint(1, 40)))
        entries[name] = random_text(rng, max_value_chars)
    return entries


@unittest.skipUnless(ZIG, "zig not found; set ZIG")
class GrowthTest(unittest.TestCase):
    def run_zig(self, entries, expect):
        text, names_len, values_len, _, _ = packed_table.source(entries, "//", 'test "smoke" {}')
        for marker in expect:
            self.assertIn(marker, text)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "table.zig")
            packed_table.write(path, text)
            result = subprocess.run([ZIG, "test", path], capture_output=True, text=True, cwd=tmp)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])

    def test_four_times_current_size(self):
        self.run_zig(synthetic(4 * 2125 + 4 * 1913, 8, 1), ["const Raw = u32;"])

    def test_names_stream_over_64k_uses_u32_restarts(self):
        self.run_zig(synthetic(12000, 4, 2), ["[_]u32{"])

    def test_wide_references_use_u64_reads(self):
        self.run_zig(synthetic(600, 700, 3), ["const Raw = u64;"])


if __name__ == "__main__":
    unittest.main()
