#!/usr/bin/env bash
# Uses the cached SDE tarball, else downloads it. Fails when neither works: a release without the older-CPU check must not ship.
set -euo pipefail

name=sde-external-9.58.0-2025-06-16-win
sum=ebb8b3b63fcb0b6c1f9721118ba4883703d2aed9e0db2defed4e44fba78d9ca9
tar=$RUNNER_TEMP/sde.tar.xz

valid() { [ -f "$tar" ] && echo "$sum  $tar" | sha256sum -c - > /dev/null 2>&1; }

if valid; then
  echo "using the cached SDE tarball"
else
  for i in 1 2 3; do
    curl -sSfL --max-time 300 -o "$tar" "https://downloadmirror.intel.com/859732/$name.tar.xz" && valid && break
    echo "SDE download attempt $i failed"
    sleep 10
  done
  valid || { echo "::error::SDE could not be downloaded and there is no cached copy, so the older-CPU check cannot run"; exit 1; }
fi

cd "$RUNNER_TEMP"
tar -xf sde.tar.xz
echo "SDE_EXE=$RUNNER_TEMP/$name/sde.exe" >> "$GITHUB_ENV"
