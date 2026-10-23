#!/usr/bin/env bash
# Makes the old-CPU test image available: loads it from the cached tarball, else pulls and bakes it, then saves the tarball.
# Fails when neither works: a release without the older-CPU check must not ship.
set -euo pipefail

base=debian@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
image=mdview/old-cpu:1
tmp=${RUNNER_TEMP:-/tmp}
tar=$tmp/old-cpu-image.tar

if [ -f "$tar" ] && docker load -i "$tar" > /dev/null 2>&1 && docker image inspect "$image" > /dev/null 2>&1; then
  echo "using the cached image"
else
  for i in 1 2 3; do docker pull "$base" && break; echo "pull attempt $i failed"; sleep 10; done
  docker image inspect "$base" > /dev/null || { echo "::error::the Debian image could not be pulled and there is no cached copy, so the older-CPU check cannot run"; exit 1; }
  docker rm -f old-cpu-bake > /dev/null 2>&1 || true
  docker run --name old-cpu-bake "$base" bash -ec '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends qemu-user xvfb xauth libx11-6 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 fonts-dejavu-core > /dev/null
  '
  docker commit old-cpu-bake "$image" > /dev/null
  docker rm old-cpu-bake > /dev/null
  docker save -o "$tar" "$image"
fi
