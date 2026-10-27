#!/usr/bin/env bash
# Print the build id, one line: YYYYMMDD-<7-char git commit>, for example 20261027-37434d8.
#
#   scripts/build-id.sh
#
# The date is the UTC build date. The commit is `git rev-parse --short=7 HEAD`, with
# "-dirty" appended when tracked files have uncommitted changes (untracked files do not
# count). Outside a git work tree, or in a repo with no commits, the commit part is
# "unknown". The script never fails: it always prints a well-formed id and exit status 0.
#
# Environment:
#   BUILD_DATE          YYYYMMDD, overrides the date (used by tests)
#   SOURCE_DATE_EPOCH   Unix seconds; the date is taken from it (reproducible builds)
#
# The build (Makefile, deploy/deploy.sh, web/e2e/global-setup.ts) passes this id to the
# binary with -ldflags; nothing else may hard-code it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || root="."

# epoch_to_date <seconds>: the UTC date, trying GNU `date -d @N` then BSD `date -r N`.
epoch_to_date() {
  local out
  out="$(date -u -d "@$1" +%Y%m%d 2>/dev/null)" || out=""
  case "$out" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) echo "$out"; return 0 ;; esac
  out="$(date -u -r "$1" +%Y%m%d 2>/dev/null)" || out=""
  case "$out" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) echo "$out"; return 0 ;; esac
  return 1
}

is_date() { case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
is_number() { case "$1" in ""|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

day=""
if is_date "${BUILD_DATE:-}"; then
  day="$BUILD_DATE"
elif is_number "${SOURCE_DATE_EPOCH:-}"; then
  day="$(epoch_to_date "$SOURCE_DATE_EPOCH")" || day=""
fi
if [ -z "$day" ]; then
  day="$(date -u +%Y%m%d 2>/dev/null)" || day=""
  is_date "$day" || day="00000000"
fi

commit="$(git -C "$root" rev-parse --short=7 HEAD 2>/dev/null)" || commit=""
case "$commit" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) commit="unknown" ;;
esac

suffix=""
if [ "$commit" != "unknown" ]; then
  changes="$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" || changes=""
  [ -z "$changes" ] || suffix="-dirty"
fi

echo "$day-$commit$suffix"
