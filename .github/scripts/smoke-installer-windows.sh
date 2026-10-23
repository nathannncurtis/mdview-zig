#!/usr/bin/env bash
# Installs mdview-setup.exe per user, smoke-runs the installed exe, uninstalls.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
setup=$1
dir="$LOCALAPPDATA/Programs/mdview"

MSYS2_ARG_CONV_EXCL='*' "$setup" /VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /NORESTART '/MERGETASKS=!associate'
for _ in $(seq 60); do [ -f "$dir/unins000.exe" ] && break; sleep 1; done
[ -f "$dir/mdview.exe" ] || { echo "::error::installer did not place mdview.exe in $dir"; exit 1; }

bash "$here/smoke.sh" "$dir/mdview.exe"

MSYS2_ARG_CONV_EXCL='*' "$dir/unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
for _ in $(seq 60); do [ -f "$dir/mdview.exe" ] || break; sleep 1; done
[ ! -f "$dir/mdview.exe" ] || { echo "::error::uninstall left mdview.exe behind"; exit 1; }
echo "installed, smoke-tested and uninstalled"
