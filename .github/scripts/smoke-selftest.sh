#!/usr/bin/env bash
# Asserts the smoke test reports failure for a binary that exits at once (no file argument).
here=$(cd "$(dirname "$0")" && pwd)
out=$(bash "$here/smoke.sh" "$1" - 2>&1)
rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then echo "::error::the smoke test passed a run that should have failed"; exit 1; fi
echo "$out" | grep -q 'exited early' || { echo "::error::the smoke test failed for the wrong reason"; exit 1; }
echo "self-test passed: the smoke test fails when the app dies"
