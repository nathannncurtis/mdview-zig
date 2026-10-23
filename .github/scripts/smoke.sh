#!/usr/bin/env bash
# Runs the built viewer on a fixture, checks it stays alive and logs a clean start.
# Usage: smoke.sh [--cpu] BINARY [FILE]. FILE "-" runs it with no argument, which makes it exit at once.
# --cpu runs it on an emulated Nehalem CPU (SSE4.2, no AVX): Intel SDE on Windows ($SDE_EXE), qemu-user on Linux.
set -o pipefail

wrap=()
if [ "$1" = --cpu ]; then
  shift
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) wrap=("$SDE_EXE" -nhm --) ;;
    Linux) wrap=(qemu-x86_64 -cpu Nehalem) ;;
    *) echo "::error::no CPU emulator for $(uname -s)"; exit 2 ;;
  esac
fi

bin=$1
file=${2:-testdata/smoke.md}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) log="$LOCALAPPDATA/mdview/mdview-zig.log"; backend='render target created'; windows=1 ;;
  Darwin) log="$HOME/Library/Application Support/mdview/mdview-zig.log"; backend='entering run loop'; windows= ;;
  *) log="${XDG_DATA_HOME:-$HOME/.local/share}/mdview/mdview-zig.log"; backend='X11 window created'; windows= ;;
esac

stop() {
  if [ -n "$windows" ]; then taskkill //F //T //PID "$(cat "/proc/$pid/winpid")" || echo "taskkill failed"
  else kill "$pid"; fi
  for _ in $(seq 20); do kill -0 "$pid" 2> /dev/null || return 0; sleep 0.5; done
  echo "::error::pid $pid did not stop"
  return 1
}

fail() {
  echo "::error::$1"
  echo "--- $log"
  cat "$log" 2> /dev/null
  if kill -0 "$pid" 2> /dev/null; then stop; fi
  exit 1
}

[ -n "$CI" ] && [ -f "$log" ] && : > "$log"
if [ "$file" = - ]; then "${wrap[@]}" "$bin" & else "${wrap[@]}" "$bin" "$file" & fi
pid=$!
echo "started $bin as pid $pid"
if [ ${#wrap[@]} -gt 0 ]; then
  for _ in $(seq 90); do
    kill -0 "$pid" 2> /dev/null || break
    grep -q "$backend" "$log" 2> /dev/null && break
    sleep 1
  done
fi
sleep 5

if ! kill -0 "$pid" 2> /dev/null; then
  wait "$pid"
  fail "$bin exited early with code $?"
fi
echo "pid $pid alive after 5 s"

grep -q '^opening: ' "$log" || fail "log has no 'opening:' line"
grep -Eq 'parsed [1-9][0-9]* blocks' "$log" || fail "log has no 'parsed N blocks' line with N > 0"
grep -q "$backend" "$log" || fail "log has no '$backend' line"
cat "$log"

stop || exit 1
echo "stopped pid $pid"
echo "smoke test passed: $bin"
