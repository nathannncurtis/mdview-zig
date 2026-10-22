#!/usr/bin/env bash
set -euo pipefail

version=0.17.0
case "$RUNNER_OS-$RUNNER_ARCH" in
  Windows-X64) name=zig-x86_64-windows-$version; ext=zip; sum=b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428 ;;
  Linux-X64)   name=zig-x86_64-linux-$version;   ext=tar.xz; sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
  macOS-ARM64) name=zig-aarch64-macos-$version;  ext=tar.xz; sum=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
  *) echo "::error::no Zig build pinned for $RUNNER_OS-$RUNNER_ARCH"; exit 1 ;;
esac

cd "$RUNNER_TEMP"
curl -sSfL -o "zig.$ext" "https://ziglang.org/download/$version/$name.$ext"
echo "$sum  zig.$ext" | sha256sum -c -
if [ "$ext" = zip ]; then unzip -q "zig.$ext"; else tar -xf "zig.$ext"; fi
echo "$RUNNER_TEMP/$name" >> "$GITHUB_PATH"
