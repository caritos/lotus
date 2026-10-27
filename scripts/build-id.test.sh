#!/usr/bin/env bash
# Tests for scripts/build-id.sh. Each case copies the script into a throwaway directory
# (the script finds its repo from its own location) and runs it there.
# Run: bash scripts/build-id.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }

FORMAT='^[0-9]{8}-([0-9a-f]{7}|unknown)(-dirty)?$'

# new_dir <name>: a directory holding scripts/build-id.sh (no repo yet).
new_dir() {
  local d="$ROOT/$1"
  mkdir -p "$d/scripts"
  cp "$HERE/build-id.sh" "$d/scripts/build-id.sh"
  echo "$d"
}

# init_repo <dir>: git repo with one commit of tracked.txt. Prints nothing.
init_repo() {
  (
    cd "$1" || exit 1
    git init -q
    echo one > tracked.txt
    git add tracked.txt scripts/build-id.sh
    git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m base
  )
}

# run_id <dir> [VAR=value ...]: stdout of the script (run from an unrelated cwd), status in $RC.
run_id() {
  local d="$1"; shift
  OUT="$(cd "$ROOT" && env -u BUILD_DATE -u SOURCE_DATE_EPOCH GIT_CEILING_DIRECTORIES="$ROOT" "$@" bash "$d/scripts/build-id.sh" 2>"$ROOT/stderr")"
  RC=$?
}

check() { # check <label> <condition-result>
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1 (rc=$RC out='$OUT')"; fi
}

short_of() { git -C "$1" rev-parse --short=7 HEAD; }

# clean repo
d="$(new_dir clean)"; init_repo "$d"
run_id "$d" BUILD_DATE=20261027
[ "$RC" = 0 ] && [ "$OUT" = "20261027-$(short_of "$d")" ]; check "clean repo prints DATE-shortcommit" $?
printf '%s' "$OUT" | grep -Eq "$FORMAT"; check "clean output matches the format" $?
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]; check "exactly one line" $?
[ ! -s "$ROOT/stderr" ]; check "clean run writes nothing to stderr" $?

# dirty tracked file
d="$(new_dir dirty)"; init_repo "$d"; echo two >> "$d/tracked.txt"
run_id "$d" BUILD_DATE=20261027
[ "$OUT" = "20261027-$(short_of "$d")-dirty" ]; check "modified tracked file appends -dirty" $?

# staged change counts too
d="$(new_dir staged)"; init_repo "$d"; echo two >> "$d/tracked.txt"; git -C "$d" add tracked.txt
run_id "$d" BUILD_DATE=20261027
[ "$OUT" = "20261027-$(short_of "$d")-dirty" ]; check "staged change appends -dirty" $?

# untracked only stays clean
d="$(new_dir untracked)"; init_repo "$d"; echo x > "$d/new-file.txt"
run_id "$d" BUILD_DATE=20261027
[ "$OUT" = "20261027-$(short_of "$d")" ]; check "untracked-only files stay clean" $?

# no git at all
d="$(new_dir nogit)"
run_id "$d" BUILD_DATE=20261027
[ "$RC" = 0 ] && [ "$OUT" = "20261027-unknown" ]; check "outside a git work tree uses unknown" $?

# repo without commits
d="$(new_dir nocommits)"; (cd "$d" && git init -q)
run_id "$d" BUILD_DATE=20261027
[ "$RC" = 0 ] && [ "$OUT" = "20261027-unknown" ]; check "repo with no commits uses unknown" $?

# BUILD_DATE override beats SOURCE_DATE_EPOCH
d="$(new_dir override)"; init_repo "$d"
run_id "$d" BUILD_DATE=20200102 SOURCE_DATE_EPOCH=0
[ "$OUT" = "20200102-$(short_of "$d")" ]; check "BUILD_DATE wins over SOURCE_DATE_EPOCH" $?

# SOURCE_DATE_EPOCH: 2026-10-27T23:59:59Z, still the 27th in UTC whatever the local zone is
run_id "$d" SOURCE_DATE_EPOCH=1793145599 TZ=Pacific/Kiritimati
[ "$OUT" = "20261027-$(short_of "$d")" ]; check "SOURCE_DATE_EPOCH is converted in UTC" $?
run_id "$d" SOURCE_DATE_EPOCH=1793145601 TZ=America/Los_Angeles
[ "$OUT" = "20261028-$(short_of "$d")" ]; check "SOURCE_DATE_EPOCH just after midnight UTC is the next day" $?

# default date is today's UTC date
run_id "$d"
[ "$OUT" = "$(date -u +%Y%m%d)-$(short_of "$d")" ]; check "default date is the UTC date" $?

# bad overrides never break the id
run_id "$d" BUILD_DATE=not-a-date SOURCE_DATE_EPOCH=junk
printf '%s' "$OUT" | grep -Eq "$FORMAT" && [ "$RC" = 0 ]; check "garbage overrides still give a well-formed id" $?

# works from any cwd and through a different invocation path
run_id "$d" BUILD_DATE=20261027
(cd / && BUILD_DATE=20261027 bash "$d/scripts/build-id.sh") | grep -Eq "$FORMAT"; check "runs from any directory" $?

# the real script in the real repo
OUT="$(bash "$HERE/build-id.sh")"; RC=$?
printf '%s' "$OUT" | grep -Eq "$FORMAT" && [ "$RC" = 0 ]; check "real repo output matches the format" $?

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
