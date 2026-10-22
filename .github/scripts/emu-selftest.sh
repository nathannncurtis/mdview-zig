#!/usr/bin/env bash
# Asserts the -Dcpu=native copy built by isa-selftest.sh dies on the emulated Nehalem CPU.
here=$(cd "$(dirname "$0")" && pwd)
exe=mdview
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=mdview.exe ;; esac
native=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/native-build/bin/$exe

if [ ! -f "$native" ]; then echo "no -Dcpu=native build (runner CPU has no AVX); skipping the emulator self-test"; exit 0; fi
out=$(bash "$here/smoke.sh" --cpu "$native" 2>&1)
rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then echo "::error::the -Dcpu=native build ran on the emulated Nehalem CPU"; exit 1; fi
echo "self-test passed: the -Dcpu=native build fails on the emulated Nehalem CPU"
