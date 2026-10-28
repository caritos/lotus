#!/bin/bash
# Run every tests/*.test.sh. Each file defines test_* functions; each runs in its own subshell.
# A file that fails to source, or defines no test_* functions, counts as a failure.
# Usage: run.sh [--fast]   (--fast skips files named *.full.test.sh)
export PATH="/usr/bin:/bin:/opt/homebrew/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAST=0
case "${1:-}" in
  "") ;;
  --fast) FAST=1 ;;
  *) echo "usage: run.sh [--fast]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: run.sh [--fast]" >&2; exit 2; }

pass=0; fail=0
for f in "$HERE"/*.test.sh; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  case "$f" in *.full.test.sh) [ "$FAST" = 1 ] && { echo "skip $name"; continue; } ;; esac
  # Discovery: stderr is kept so source errors are visible.
  loaderr="$(mktemp "${TMPDIR:-/tmp}/run-load.XXXXXX")"
  fns="$(bash -c 'set -e; source "$1"; source "$2"; declare -F | awk "{print \$3}" | grep "^test_"' _ "$HERE/lib.sh" "$f" 2>"$loaderr")" && lrc=0 || lrc=$?
  if [ $lrc -ne 0 ] && [ -z "$fns" ]; then
    fail=$((fail+1)); echo "FAIL $name: could not load (no test_ functions found or source error)" >&2
    sed 's/^/    /' "$loaderr" >&2; rm -f "$loaderr"; continue
  fi
  if [ -s "$loaderr" ]; then echo "WARN $name: load stderr:" >&2; sed 's/^/    /' "$loaderr" >&2; fi
  rm -f "$loaderr"
  for fn in $fns; do
    out="$(bash -c 'set -e; source "$1"; source "$2"; "$3"' _ "$HERE/lib.sh" "$f" "$fn" 2>&1)" && rc=0 || rc=$?
    if [ $rc -eq 0 ]; then
      pass=$((pass+1)); echo "PASS $name: $fn"
    else
      fail=$((fail+1)); echo "FAIL $name: $fn"; echo "$out" | sed 's/^/    /'
    fi
  done
done
echo "---"; echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
