#!/usr/bin/env bash
set -euo pipefail

version=0.14.1
case "$RUNNER_OS-$RUNNER_ARCH" in
  Windows-X64) name=zig-x86_64-windows-$version; ext=zip; sum=554f5378228923ffd558eac35e21af020c73789d87afeabf4bfd16f2e6feed2c ;;
  Linux-X64)   name=zig-x86_64-linux-$version;   ext=tar.xz; sum=24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c ;;
  macOS-ARM64) name=zig-aarch64-macos-$version;  ext=tar.xz; sum=39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa ;;
  *) echo "::error::no Zig build pinned for $RUNNER_OS-$RUNNER_ARCH"; exit 1 ;;
esac

cd "$RUNNER_TEMP"
curl -sSfL -o "zig.$ext" "https://ziglang.org/download/$version/$name.$ext"
echo "$sum  zig.$ext" | sha256sum -c -
if [ "$ext" = zip ]; then unzip -q "zig.$ext"; else tar -xf "zig.$ext"; fi
echo "$RUNNER_TEMP/$name" >> "$GITHUB_PATH"
