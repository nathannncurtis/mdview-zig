#!/usr/bin/env bash
# Runs the smoke test on an emulated Nehalem CPU inside a Debian 13 userland, which is built for the baseline CPU
# (the runner's own userland needs AVX2, so it cannot run on an emulated Nehalem).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bash "$here/bake-old-cpu-image.sh"

image=mdview/old-cpu:1
tmp=${RUNNER_TEMP:-/tmp}

docker run --rm --init -e CI=true -e RUNNER_TEMP="$tmp" -v "$PWD:$PWD" -v "$tmp:$tmp" -w "$PWD" "$image" bash -ec '
  xvfb-run -a bash -ec "echo smoke; timeout -k 5 100 bash .github/scripts/smoke.sh --cpu zig-out/bin/mdview; echo selftest; timeout -k 5 120 bash .github/scripts/emu-selftest.sh"
'
