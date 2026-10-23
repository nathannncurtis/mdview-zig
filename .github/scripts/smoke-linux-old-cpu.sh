#!/usr/bin/env bash
# Runs the smoke test on an emulated Nehalem CPU inside a Debian 13 userland, which is built for the baseline CPU
# (the runner's own userland needs AVX2, so it cannot run on an emulated Nehalem).
set -euo pipefail

image=debian@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
tmp=${RUNNER_TEMP:-/tmp}

docker run --rm -e CI=true -e RUNNER_TEMP="$tmp" -v "$PWD:$PWD" -v "$tmp:$tmp" -w "$PWD" "$image" bash -ec '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends qemu-user xvfb xauth libx11-6 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 fonts-dejavu-core > /dev/null
  xvfb-run -a bash -ec "bash .github/scripts/smoke.sh --cpu zig-out/bin/mdview; echo first run done; bash .github/scripts/emu-selftest.sh"
'
