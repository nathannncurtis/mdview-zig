#!/usr/bin/env bash
set -euo pipefail

name=sde-external-9.58.0-2025-06-16-win
cd "$RUNNER_TEMP"
curl -sSfL -o sde.tar.xz "https://downloadmirror.intel.com/859732/$name.tar.xz"
echo "ebb8b3b63fcb0b6c1f9721118ba4883703d2aed9e0db2defed4e44fba78d9ca9  sde.tar.xz" | sha256sum -c -
tar -xf sde.tar.xz
echo "SDE_EXE=$RUNNER_TEMP/$name/sde.exe" >> "$GITHUB_ENV"
