#!/usr/bin/env bash
# Runs the built viewer on a fixture, checks it stays alive and logs a clean start.
# Usage: smoke.sh BINARY [FILE]. FILE "-" runs it with no argument, which makes it exit at once.
set -o pipefail

bin=$1
file=${2:-testdata/smoke.md}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) log="$LOCALAPPDATA/mdview/mdview-zig.log"; backend='render target created'; windows=1 ;;
  Darwin) log="$HOME/Library/Application Support/mdview/mdview-zig.log"; backend='entering run loop'; windows= ;;
  *) log="${XDG_DATA_HOME:-$HOME/.local/share}/mdview/mdview-zig.log"; backend='X11 window created'; windows= ;;
esac

stop() {
  if [ -n "$windows" ]; then taskkill //F //PID "$(cat "/proc/$pid/winpid")" > /dev/null 2>&1
  else kill "$pid" 2> /dev/null; fi
  wait "$pid" 2> /dev/null
}

fail() {
  echo "::error::$1"
  echo "--- $log"
  cat "$log" 2> /dev/null
  if kill -0 "$pid" 2> /dev/null; then stop; fi
  exit 1
}

if [ "$file" = - ]; then "$bin" & else "$bin" "$file" & fi
pid=$!
echo "started $bin as pid $pid"
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

stop
echo "stopped pid $pid"
echo "smoke test passed: $bin"
