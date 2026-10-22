#!/usr/bin/env bash
# Fails when the binary uses instructions beyond the baseline CPU.
set -euo pipefail

bin=$1

if [ "$(uname -s)" = Darwin ]; then
  hdr=$(otool -hv "$bin")
  echo "$hdr"
  echo "$hdr" | grep -Eq 'ARM64[[:space:]]+ALL' || { echo "::error::$bin is not generic arm64"; exit 1; }
  echo "$bin: generic arm64"
  exit 0
fi

dump=$(command -v llvm-objdump || command -v objdump || true)
if [ -z "$dump" ] && [ -x "/c/Program Files/LLVM/bin/llvm-objdump.exe" ]; then dump="/c/Program Files/LLVM/bin/llvm-objdump.exe"; fi
[ -n "$dump" ] || { echo "::error::no objdump found"; exit 2; }
echo "disassembler: $dump"

asm=$(mktemp)
"$dump" -d --no-show-raw-insn -M intel "$bin" > "$asm"
sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//; s/^(lock|rep|repz|repnz|bnd|notrack)[[:space:]]+//' "$asm" > "$asm.ins"

total=$(grep -Ec '^[a-z][a-z0-9]*([[:space:]]|$)' "$asm.ins" || true)
[ "$total" -gt 1000 ] || { echo "::error::only $total instructions disassembled from $bin"; exit 2; }

ext='^(v[a-z0-9]+|andn|bextr|blsi|blsmsk|blsr|bzhi|mulx|pdep|pext|rorx|sarx|shlx|shrx|tzcnt|lzcnt)([[:space:]]|$)'
sys='^(verr|verw|vm(call|clear|launch|ptrld|ptrst|read|resume|write|xoff|xon))([[:space:]]|$)'
{ grep -E "$ext" "$asm.ins" | grep -Ev "$sys" || true; grep -Ei '\b[yz]mm[0-9]+' "$asm.ins" || true; } | sort -u > "$asm.bad"

n=$(wc -l < "$asm.bad")
if [ "$n" -gt 0 ]; then
  echo "::error::$bin uses $n distinct instruction forms beyond the baseline CPU"
  head -n 10 "$asm.bad"
  exit 1
fi
echo "$bin: $total instructions, none beyond the baseline"
