#!/usr/bin/env bash
# Builds a -Dcpu=native copy and asserts isa-check.sh flags it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
exe=mdview
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=mdview.exe ;; esac

if ! grep -qw avx /proc/cpuinfo; then
  echo "runner CPU has no AVX; skipping the instruction check self-test"
  exit 0
fi

prefix=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/native-build
zig build -Doptimize=ReleaseFast -Dcpu=native --prefix "$prefix"

if bash "$here/isa-check.sh" "$prefix/bin/$exe"; then
  echo "::error::the instruction check did not flag the -Dcpu=native build"
  exit 1
fi
echo "self-test passed: the -Dcpu=native build is flagged"
