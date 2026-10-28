#!/usr/bin/env bash
# Tests for scripts/restore.sh, scripts/pull-backups.sh, scripts/deploy.sh and scripts/smoke.sh.
# Builds the goweb binary once, builds fixtures with it and the sqlite3 CLI, and
# uses fake SYSTEMCTL / HEALTH_CMD / NOTIFY_CMD scripts. Run: bash scripts/deploy.test.sh
# (ONLY='test_deploy_*' bash scripts/deploy.test.sh runs the tests whose names match the glob).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "deploy.test.sh: the sqlite3 CLI is required to build fixtures but was not found on PATH" >&2
  exit 2
fi

ROOT="$(mktemp -d)"
case "$ROOT" in /tmp/*|/var/*|/private/*) ;; *) echo "deploy.test.sh: unexpected temp dir $ROOT" >&2; exit 2 ;; esac
trap 'rm -rf "$ROOT"' EXIT
umask 077

echo "building goweb ..."
if ! (cd "$REPO_ROOT/web/api" && go build -o "$ROOT/goweb" ./cmd/goweb); then
  echo "deploy.test.sh: go build failed" >&2
  exit 2
fi
export GOWEB_BIN="$ROOT/goweb"
# 2026-10-28T00:00:00Z, so the fixture sets named 20261027T... are 1 day old.
NOW_EPOCH_FIXED=1793145600

PHOTO="11111111-1111-1111-1111-111111111111.jpg"

# make_data <dir> <email> <photo-or-empty>: a data dir with a migrated db, one user
# and (optionally) one note with a photo stored in storage/.
make_data() {
  local dir="$1" email="$2" photo="$3"
  mkdir -p "$dir/storage"
  printf 'correct-horse-battery\n' | DATA_DIR="$dir" "$GOWEB_BIN" user create "$email" >/dev/null || return 1
  if [ -n "$photo" ]; then
    sqlite3 "$dir/db/goweb.db" "INSERT INTO notes (id, user_id, title, photo, created_at, updated_at) SELECT 'n1', id, 't', '$photo', 1, 1 FROM users LIMIT 1;" || return 1
    printf 'img-%s' "$email" > "$dir/storage/$photo"
  fi
}

# Master fixtures, copied per test.
make_data "$ROOT/master-base" "backup@example.com" "$PHOTO" || { echo "fixture build failed" >&2; exit 2; }
make_data "$ROOT/master-live" "live@example.com" "$PHOTO" || { echo "fixture build failed" >&2; exit 2; }
MASTER_BACKUP="$(DATA_DIR="$ROOT/master-base" "$GOWEB_BIN" backup --keep 3)" || { echo "backup fixture failed" >&2; exit 2; }

PASSED=0
FAILED=0
SKIPPED=0
CUR_FAIL=""

# skip <reason>: mark the running test as skipped (counted, printed in the summary, not a failure).
skip() { echo "    SKIPPED: $*" >&2; : > "$T/.skipped"; }
fail() { echo "    $*" >&2; : > "$CUR_FAIL"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
assert_true() { local m="$1"; shift; "$@" >/dev/null 2>&1 || fail "$m: command failed: $*"; }
assert_false() { local m="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$m: command unexpectedly succeeded: $*"; fi; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3: '$2' not found in '$1'" ;; esac; }

# fake systemctl: records its arguments.
make_fakes() {
  cat > "$T/systemctl" <<'EOS'
#!/bin/sh
echo "$*" >> "$CALLS"
EOS
  chmod +x "$T/systemctl"
  cat > "$T/notify" <<'EOS'
#!/bin/sh
echo "$1" >> "$NOTIFIED"
EOS
  chmod +x "$T/notify"
  mkdir -p "$T/bin"
  cat > "$T/bin/cp" <<'EOS'
#!/bin/sh
# Fault injection: FAIL_CP_DST fails copies whose destination matches the glob;
# TRUNC_CP_DST truncates the copied file after a successful copy.
last=; for a in "$@"; do last=$a; done
case "$last" in ${FAIL_CP_DST:-__none__}) echo "fake cp: injected failure for $last" >&2; exit 1 ;; esac
case "$last" in ${SLOW_CP_DST:-__none__}) : > "$SLOW_MARKER"; sleep 2 ;; esac
/bin/cp "$@" || exit $?
case "$last" in ${TRUNC_CP_DST:-__none__}) head -c 100 "$last" > "$last.t" && /bin/mv "$last.t" "$last" ;; esac
EOS
  cat > "$T/bin/mv" <<'EOS'
#!/bin/sh
last=; for a in "$@"; do last=$a; done
case "$last" in ${FAIL_MV_DST:-__none__}) echo "fake mv: injected failure for $last" >&2; exit 1 ;; esac
exec /bin/mv "$@"
EOS
  chmod +x "$T/bin/cp" "$T/bin/mv"
  export CALLS="$T/calls" NOTIFIED="$T/notified"
  : > "$CALLS"; : > "$NOTIFIED"
  export SYSTEMCTL="$T/systemctl" SERVICE=goweb
  export HEALTH_TIMEOUT=2
  export NOTIFY_CMD='sh '"$T/notify"' "$1"'
}

# new_backup <name>: a copy of the master backup set at $T/backups/<name>.
new_backup() {
  mkdir -p "$T/backups"
  cp -R "$MASTER_BACKUP" "$T/backups/$1"
  echo "$T/backups/$1"
}

restore() { PATH="$T/bin:$PATH" bash "$SCRIPT_DIR/restore.sh" "$@" >"$T/out" 2>"$T/err"; }

# live_email prints the email stored in the live database.
live_email() { sqlite3 "$T/data/db/goweb.db" 'select email from users'; }
# healthy only while the original (live) data is in place.
LIVE_HEALTH='test "$(sqlite3 "$DATA_DIR/db/goweb.db" "select email from users")" = live@example.com'
setup_live() {
  make_fakes
  cp -R "$ROOT/master-live" "$T/data"
  export DATA_DIR="$T/data"
}

run_test() {
  local name="$1"
  T="$(mktemp -d "$ROOT/t.XXXXXX")"
  CUR_FAIL="$T/.failed"
  ( cd "$T" && "$name" )
  if [ -e "$CUR_FAIL" ]; then
    echo "FAIL $name"; FAILED=$((FAILED + 1))
  elif [ -e "$T/.skipped" ]; then
    echo "SKIP $name"; SKIPPED=$((SKIPPED + 1))
  else
    echo "PASS $name"; PASSED=$((PASSED + 1))
  fi
  rm -rf "$T"
}

# ---------------------------------------------------------------- restore tests

test_restore_drill_passes_on_good_backup() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b" --drill
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/out")" "DRILL OK $b" "stdout"
  assert_eq "$(cat "$CALLS")" "" "drill must not touch the service"
}

test_restore_drill_fails_on_corrupt_db() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z)"
  # Overwrite everything after the first page with garbage.
  local size; size="$(wc -c < "$b/goweb.db" | tr -d ' ')"
  head -c 4096 "$b/goweb.db" > "$T/head"
  head -c $((size - 4096)) /dev/zero | tr '\0' 'x' > "$T/junk"
  cat "$T/head" "$T/junk" > "$b/goweb.db"
  restore "$b" --drill
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_false "no DRILL OK line" grep -q "DRILL OK" "$T/out"
  assert_contains "$(cat "$T/err")" "integrity_check" "stderr shows the underlying failure"
}

test_restore_drill_fails_when_a_referenced_photo_is_missing() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z)"
  rm "$b/storage/$PHOTO"
  restore "$b" --drill
  local rc=$?
  assert_false "exit status must be nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "$PHOTO" "stderr names the missing photo"
  assert_false "no integrity wording for a photo problem" grep -q "integrity_check" "$T/err"
}

test_restore_non_drill_replaces_data_and_restarts_service() {
  make_fakes
  cp -R "$ROOT/master-live" "$T/data"
  export DATA_DIR="$T/data" HEALTH_CMD="true"
  echo stale > "$T/data/db/goweb.db-wal"
  echo stale > "$T/data/storage/only-in-live.jpg"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_eq "$?" "0" "exit status"
  assert_eq "$(sqlite3 "$T/data/db/goweb.db" 'select email from users')" "backup@example.com" "db replaced"
  assert_eq "$(cat "$T/data/storage/$PHOTO")" "img-backup@example.com" "photo replaced"
  assert_false "stale wal removed" test -e "$T/data/db/goweb.db-wal"
  assert_false "live-only file removed" test -e "$T/data/storage/only-in-live.jpg"
  assert_eq "$(cat "$CALLS")" "stop goweb
start goweb" "service calls"
  local pre; pre="$(ls -d "$T"/data/backups/pre-restore-* 2>/dev/null | head -1)"
  assert_true "pre-restore copy exists" test -n "$pre"
  assert_eq "$(sqlite3 "$pre/goweb.db" 'select email from users')" "live@example.com" "pre-restore db"
  assert_true "pre-restore storage exists" test -f "$pre/storage/only-in-live.jpg"
}

test_restore_rolls_back_when_health_check_fails() {
  setup_live
  export HEALTH_CMD="$LIVE_HEALTH"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(live_email)" "live@example.com" "db rolled back"
  assert_eq "$(cat "$T/data/storage/$PHOTO")" "img-live@example.com" "storage rolled back"
  assert_eq "$(cat "$CALLS")" "stop goweb
start goweb
stop goweb
start goweb" "service calls"
  assert_contains "$(cat "$T/err")" "rolled back to the previous data; service is healthy" "stderr"
  assert_contains "$(cat "$T/err")" "pre-restore-" "names the safety copy"
}

test_restore_does_not_claim_rollback_when_still_unhealthy() {
  setup_live
  export HEALTH_CMD="false"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(live_email)" "live@example.com" "db rolled back"
  assert_contains "$(cat "$T/err")" "RECOVERY INCOMPLETE" "stderr"
  assert_false "no false rollback claim" grep -q "service is healthy" "$T/err"
  assert_eq "$(tail -1 "$CALLS")" "start goweb" "service left started"
}

# #1: a failing cp while staging must abort before anything is touched.
test_restore_aborts_when_staging_copy_fails() {
  local pat
  for pat in "*/.restore-stage-*/goweb.db" "*/.restore-stage-*/storage*"; do
    setup_live
    export HEALTH_CMD="$LIVE_HEALTH" FAIL_CP_DST="$pat"
    local b; b="$(new_backup 20261027T120000Z)"
    restore "$b"
    assert_false "exit status must be nonzero ($pat)" test "$?" -eq 0
    assert_false "no 'ok' claim ($pat)" grep -q "restore: ok" "$T/out" "$T/err"
    assert_eq "$(live_email)" "live@example.com" "data intact ($pat)"
    assert_eq "$(cat "$CALLS")" "" "service untouched ($pat)"
    assert_eq "$(ls -A "$T/data" | grep -c restore-stage)" "0" "stage removed ($pat)"
    unset FAIL_CP_DST
  done
}

# #2: a corrupt copy must be caught before the swap.
test_restore_catches_corrupt_copy_before_swap() {
  setup_live
  export HEALTH_CMD="$LIVE_HEALTH" TRUNC_CP_DST="*/.restore-stage-*/goweb.db"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "integrity_check" "underlying problem shown"
  assert_eq "$(live_email)" "live@example.com" "data intact"
  assert_false "no 'ok' claim" grep -q "restore: ok" "$T/out" "$T/err"
}

# #3: failure of the safety copy still restarts the service and names the path.
test_restore_restarts_service_when_safety_copy_fails() {
  setup_live
  export HEALTH_CMD="$LIVE_HEALTH" FAIL_CP_DST="*/pre-restore-*"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(cat "$CALLS")" "stop goweb
start goweb" "service calls"
  assert_contains "$(cat "$T/err")" "pre-restore-" "names the safety copy"
  assert_eq "$(live_email)" "live@example.com" "data intact"
}

test_restore_rolls_back_when_swap_fails_midway() {
  setup_live
  export HEALTH_CMD="$LIVE_HEALTH" FAIL_MV_DST="*/data/storage"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(live_email)" "live@example.com" "db rolled back"
  assert_eq "$(cat "$T/data/storage/$PHOTO")" "img-live@example.com" "storage rolled back"
  assert_eq "$(tail -1 "$CALLS")" "start goweb" "service restarted"
  assert_contains "$(cat "$T/err")" "pre-restore-" "names the safety copy"
  assert_contains "$(cat "$T/err")" "rolled back to the previous data; service is healthy" "stderr"
}

# A second TERM and a HUP while the recovery handler runs must not abort it.
test_restore_recovery_survives_repeated_signals() {
  setup_live
  export HEALTH_CMD="$LIVE_HEALTH" FAIL_MV_DST="*/data/storage"
  export SLOW_CP_DST="*/data/db/goweb.db" SLOW_MARKER="$T/slow-started"
  local b; b="$(new_backup 20261027T120000Z)"
  PATH="$T/bin:$PATH" bash "$SCRIPT_DIR/restore.sh" "$b" >"$T/out" 2>"$T/err" &
  local pid=$! i
  for i in $(seq 1 100); do [ -e "$SLOW_MARKER" ] && break; sleep 0.1; done
  assert_true "rollback reached the slow step" test -e "$SLOW_MARKER"
  kill -TERM "$pid" 2>/dev/null
  sleep 0.3
  kill -TERM "$pid" 2>/dev/null
  kill -HUP "$pid" 2>/dev/null
  wait "$pid"; local rc=$?
  assert_false "exit status must be nonzero" test "$rc" -eq 0
  assert_eq "$(live_email)" "live@example.com" "db restored"
  assert_eq "$(cat "$T/data/storage/$PHOTO")" "img-live@example.com" "storage restored"
  assert_eq "$(tail -1 "$CALLS")" "start goweb" "service started"
  assert_contains "$(cat "$T/err")" "pre-restore-" "names the safety copy"
  assert_contains "$(cat "$T/err")" "rolled back to the previous data; service is healthy" "completed"
}

test_restore_reports_when_rollback_copy_fails() {
  setup_live
  export HEALTH_CMD="false" FAIL_CP_DST="*/data/db/goweb.db"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(tail -1 "$CALLS")" "start goweb" "service restarted anyway"
  assert_contains "$(cat "$T/err")" "RECOVERY INCOMPLETE" "stderr"
  assert_contains "$(cat "$T/err")" "pre-restore-" "names the safety copy"
  assert_false "no false rollback claim" grep -q "service is healthy" "$T/err"
}

test_restore_refuses_empty_or_missing_backup_dir_argument() {
  make_fakes
  cp -R "$ROOT/master-live" "$T/data"
  export DATA_DIR="$T/data" HEALTH_CMD="true"
  restore ""
  assert_false "empty arg" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "backup-dir" "usage message"
  restore "$T/does-not-exist"
  assert_false "missing dir" test "$?" -eq 0
  mkdir "$T/empty"
  restore "$T/empty"
  assert_false "dir without goweb.db" test "$?" -eq 0
  restore
  assert_false "no args" test "$?" -eq 0
  assert_eq "$(cat "$CALLS")" "" "service untouched"
  assert_eq "$(sqlite3 "$T/data/db/goweb.db" 'select email from users')" "live@example.com" "data untouched"
}

# ------------------------------------------------------------------ pull tests

pull_env() {
  export REMOTE="" REMOTE_DIR="$T/remote" DEST="$T/dest" KEEP=30 STALE_DAYS=3
  export NOW_EPOCH="$NOW_EPOCH_FIXED" SQLITE3=sqlite3
  unset MIRROR_DIR
  mkdir -p "$T/remote"
}
pull() { bash "$SCRIPT_DIR/pull-backups.sh" >"$T/out" 2>"$T/err"; }
remote_set() { cp -R "$MASTER_BACKUP" "$T/remote/$1"; }

test_pull_rejects_corrupt_snapshot_into_failed() {
  make_fakes; pull_env
  remote_set 20261027T100000Z
  remote_set 20261027T110000Z
  local size; size="$(wc -c < "$T/remote/20261027T110000Z/goweb.db" | tr -d ' ')"
  head -c 4096 "$T/remote/20261027T110000Z/goweb.db" > "$T/head"
  head -c $((size - 4096)) /dev/zero | tr '\0' 'x' > "$T/junk"
  cat "$T/head" "$T/junk" > "$T/remote/20261027T110000Z/goweb.db"
  pull
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_true "good set kept" test -f "$T/dest/20261027T100000Z/goweb.db"
  assert_false "bad set not in dest" test -e "$T/dest/20261027T110000Z"
  assert_true "bad set quarantined" test -f "$T/dest/failed/20261027T110000Z/goweb.db"
  assert_contains "$(cat "$NOTIFIED")" "20261027T110000Z" "notified"
}

test_pull_alerts_when_newest_backup_is_stale() {
  make_fakes; pull_env
  remote_set 20261020T120000Z
  pull
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_true "set still pulled" test -f "$T/dest/20261020T120000Z/goweb.db"
  assert_contains "$(cat "$NOTIFIED")" "stale" "notified"
}

test_pull_ok_when_newest_backup_is_fresh() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  pull
  assert_eq "$?" "0" "exit status"
  assert_eq "$(cat "$NOTIFIED")" "" "no notification"
}

test_pull_alerts_when_there_is_no_backup_at_all() {
  make_fakes; pull_env
  pull
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$NOTIFIED")" "no backup" "notified"
}

test_pull_prunes_to_KEEP() {
  make_fakes; pull_env
  export KEEP=2
  remote_set 20261025T120000Z; remote_set 20261026T120000Z; remote_set 20261027T120000Z
  pull
  assert_eq "$?" "0" "exit status"
  assert_eq "$(ls "$T/dest" | grep -v '^failed$' | tr '\n' ' ')" "20261026T120000Z 20261027T120000Z " "dest contents"
}

test_pull_skips_partial_sets() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  cp -R "$MASTER_BACKUP" "$T/remote/20261027T130000Z.partial"
  pull
  assert_eq "$?" "0" "exit status"
  assert_eq "$(ls "$T/dest" | grep -v '^failed$' | tr '\n' ' ')" "20261027T120000Z " "dest contents"
}

# #5: interrupted/corrupt mirror copies are never treated as complete.
test_pull_mirror_cleans_leftovers_and_rejects_corrupt_copy() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  export MIRROR_DIR="$T/mirror"
  mkdir -p "$T/mirror/20261027T120000Z.pulling"
  echo junk > "$T/mirror/20261027T120000Z.pulling/goweb.db"
  mkdir -p "$T/mirror/keep-me.pulling-not"
  pull
  assert_eq "$?" "0" "exit status"
  assert_false "leftover gone" test -e "$T/mirror/20261027T120000Z.pulling"
  assert_true "set re-copied" test -f "$T/mirror/20261027T120000Z/storage/$PHOTO"
  assert_true "foreign entry untouched" test -d "$T/mirror/keep-me.pulling-not"
  # A corrupt mirror copy is not promoted: fake rsync that corrupts mirror writes.
  rm -rf "$T/mirror" "$T/dest"; mkdir "$T/mirror"
  cat > "$T/rsync-corrupt" <<'EOS'
#!/bin/sh
/usr/bin/rsync "$@" || exit $?
for last; do :; done
case "$last" in */mirror/*.pulling/) echo garbage > "${last}goweb.db" ;; esac
EOS
  chmod +x "$T/rsync-corrupt"
  RSYNC="$T/rsync-corrupt" pull
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_false "corrupt mirror copy not promoted" test -e "$T/mirror/20261027T120000Z"
  assert_contains "$(cat "$NOTIFIED")" "mirror" "notified"
}

# #6: overlapping runs.
# plant_lock <pid> <started-epoch>
plant_lock() {
  mkdir -p "$T/dest/.lock"
  echo "$1" > "$T/dest/.lock/pid"
  echo "$2" > "$T/dest/.lock/started"
}

test_pull_takes_over_lock_whose_pid_is_an_unrelated_live_process() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  sleep 30 & local pid=$!
  plant_lock "$pid" "$NOW_EPOCH_FIXED"
  pull
  local rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$rc" "0" "exit status"
  assert_contains "$(cat "$T/err")" "taking over stale lock" "message"
  assert_true "pulled" test -f "$T/dest/20261027T120000Z/goweb.db"
}

test_pull_takes_over_an_old_lock_even_if_the_pid_is_alive() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  sleep 30 & local pid=$!
  plant_lock "$pid" $((NOW_EPOCH_FIXED - 7 * 3600))
  pull
  local rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$rc" "0" "exit status"
  assert_contains "$(cat "$T/err")" "taking over stale lock" "message"
}

test_pull_exits_3_for_a_real_running_pull_but_still_alerts_when_stale() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  mkdir -p "$T/dest"
  cp -R "$MASTER_BACKUP" "$T/dest/20261020T120000Z"   # stale newest snapshot
  cat > "$T/slow-rsync" <<'EOS'
#!/bin/sh
/usr/bin/rsync "$@" || exit $?
sleep 4
EOS
  chmod +x "$T/slow-rsync"
  RSYNC="$T/slow-rsync" bash "$SCRIPT_DIR/pull-backups.sh" >"$T/out1" 2>"$T/err1" &
  local pid=$! i
  for i in $(seq 1 50); do [ -e "$T/dest/.lock/pid" ] && [ -d "$T/dest/20261027T120000Z.pulling" ] && break; sleep 0.1; done
  assert_true "first run holds the lock" test -d "$T/dest/.lock"
  pull
  local rc=$?
  assert_eq "$rc" "3" "exit status"
  assert_contains "$(cat "$T/err")" "already running" "message"
  assert_contains "$(cat "$NOTIFIED")" "stale" "stale alert not silenced by the lock"
  assert_true ".pulling untouched" test -d "$T/dest/20261027T120000Z.pulling"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

test_pull_takes_over_a_stale_lock_and_releases_its_own() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  mkdir -p "$T/dest/.lock"
  echo 999999 > "$T/dest/.lock/pid"
  pull
  assert_eq "$?" "0" "exit status"
  assert_false "lock released" test -e "$T/dest/.lock"
  assert_true "pulled" test -f "$T/dest/20261027T120000Z/goweb.db"
}

# #7: future-dated sets are invalid.
test_pull_quarantines_future_dated_sets_and_still_alerts_stale() {
  make_fakes; pull_env
  remote_set 20261020T120000Z
  remote_set 20991231T000000Z
  pull
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_true "future set quarantined" test -d "$T/dest/failed/20991231T000000Z"
  assert_false "future set not in dest" test -e "$T/dest/20991231T000000Z"
  assert_contains "$(cat "$NOTIFIED")" "stale" "stale alert not suppressed"
  assert_contains "$(cat "$NOTIFIED")" "20991231T000000Z" "future set reported"
}

test_pull_quarantines_future_dated_sets_already_held_locally() {
  make_fakes; pull_env
  mkdir -p "$T/dest"
  cp -R "$MASTER_BACKUP" "$T/dest/20991231T000000Z"
  KEEP=1 pull
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_true "moved to failed" test -d "$T/dest/failed/20991231T000000Z"
  assert_false "gone from dest" test -e "$T/dest/20991231T000000Z"
}

test_pull_works_with_each_installed_rsync() {
  local r found=0
  for r in /usr/bin/rsync /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
    [ -x "$r" ] || continue
    found=1
    make_fakes; pull_env
    rm -rf "$T/dest" "$T/remote"; mkdir -p "$T/remote"
    remote_set 20261027T120000Z
    RSYNC="$r" pull
    assert_eq "$?" "0" "exit status with $r"
    assert_true "pulled with $r" test -f "$T/dest/20261027T120000Z/storage/$PHOTO"
  done
  assert_eq "$found" "1" "at least one rsync found"
}

test_pull_mirrors_only_when_MIRROR_DIR_exists() {
  make_fakes; pull_env
  remote_set 20261027T120000Z
  export MIRROR_DIR="$T/mirror"
  pull
  assert_eq "$?" "0" "exit status (missing mirror)"
  assert_false "mirror dir must not be created" test -e "$T/mirror"
  mkdir "$T/mirror"
  pull
  assert_eq "$?" "0" "exit status (mirror present)"
  assert_true "mirrored" test -f "$T/mirror/20261027T120000Z/goweb.db"
  assert_true "mirrored storage" test -f "$T/mirror/20261027T120000Z/storage/$PHOTO"
  assert_eq "$(ls -A "$T/mirror" | tr '\n' ' ')" "20261027T120000Z " "mirror contents"
}

# ---------------------------------------------------------------- deploy tests
# A fake `ssh` runs the remote command locally with HOME set to a sandbox
# directory ($T/home) and fake systemctl/loginctl/curl first on PATH. A fake `go`
# writes a shell script standing in for the binary; a fake `rsync` copies into the
# sandbox. Nothing here contacts a real host.

make_fake_binary_script() {
  # make_fake_binary_script <path> <version> <schema>; schema NONE fakes an old
  # binary that has no schema-version subcommand.
  sed -e "s|@VERSION@|$2|g" -e "s|@SCHEMA@|$3|g" "$T/fakebin.tmpl" > "$1"
  chmod +x "$1"
}

setup_deploy() {
  export DCALLS="$T/dcalls"; : > "$DCALLS"
  export FAKE_REMOTE_HOME="$T/home"
  mkdir -p "$T/home/goweb/data/db" "$T/home/goweb/releases" "$T/rbin" "$T/lbin"
  : > "$T/home/goweb/data/db/goweb.db"
  cat > "$T/fakebin.tmpl" <<'EOT'
#!/bin/sh
case "$1" in
  schema-version)
    if [ "@SCHEMA@" = NONE ]; then echo "goweb: unknown command" >&2; exit 1; fi
    echo "@SCHEMA@" ;;
  __version) echo "@VERSION@" ;;
  backup)
    if [ -n "$FAKE_BACKUP_FAIL" ]; then echo "backup exploded" >&2; exit 1; fi
    if [ -n "$FAKE_BACKUP_EMPTY" ]; then exit 0; fi
    dd="${DATA_DIR:-$HOME/goweb/data}"
    d="$dd/backups/pre-$(date +%s)-$$"
    mkdir -p "$d" && echo "backup DATA_DIR=$dd" >> "$DCALLS" && echo "backup ARGS=$*" >> "$DCALLS" && echo "$d" ;;
esac
EOT
  printf 'APP_ENV=production\nSESSION_SECRET=do-not-print-me\nADDR=0.0.0.0:8080\n' > "$T/home/goweb/.env"

  cat > "$T/ssh" <<'EOS'
#!/bin/bash
# fake ssh: ssh [-o X]... [-i K] host command
echo "ssh $*" >> "$DCALLS"
while [ $# -gt 0 ]; do
  case "$1" in -o|-i) shift 2 ;; -*) shift ;; *) break ;; esac
done
host="$1"; shift
[ -n "$host" ] || exit 255
# FAKE_SSH_FAIL_END: a command ending in this text fails like a dropped connection (exit 255).
if [ -n "${FAKE_SSH_FAIL_END:-}" ]; then case "$*" in *"$FAKE_SSH_FAIL_END") exit 255 ;; esac; fi
cd "$FAKE_REMOTE_HOME" || exit 255
HOME="$FAKE_REMOTE_HOME" PATH="$FAKE_RBIN:$PATH" exec sh -c "$*"
EOS
  cat > "$T/rsync" <<'EOS'
#!/bin/bash
echo "rsync $*" >> "$DCALLS"
args=()
while [ $# -gt 0 ]; do
  case "$1" in -e) shift 2 ;; -*) shift ;; *) args+=("$1"); shift ;; esac
done
src="${args[0]}"; dst="${args[1]}"
case "$dst" in *:*) dst="$FAKE_REMOTE_HOME/${dst#*:}" ;; esac
cp -R "$src" "$dst" || exit 1
if [ -n "${FAKE_RSYNC_CORRUPT:-}" ] && [ -f "$dst" ]; then printf 'x' >> "$dst"; fi
EOS
  cat > "$T/rbin/systemctl" <<'EOS'
#!/bin/sh
echo "systemctl $*" >> "$DCALLS"
if [ -n "${FAKE_NO_UNIT:-}" ] && [ "$2" = cat ]; then echo "Failed to connect to bus: No medium found" >&2; exit 1; fi
# is-active answers for the unit in FAKE_EXPECT_UNIT (default goweb) only; any other unit is inactive.
if [ "$2" = is-active ]; then
  if [ "$3" != "${FAKE_EXPECT_UNIT:-goweb}" ]; then echo inactive; exit 3; fi
  echo "${FAKE_SERVICE_ACTIVE:-active}"; [ "${FAKE_SERVICE_ACTIVE:-active}" = active ]; exit
fi
if [ "$2" = is-enabled ]; then
  if [ -n "${FAKE_TIMER_BUS_ERROR:-}" ]; then echo "Failed to connect to bus: No medium found" >&2; exit 1; fi
  echo "${FAKE_TIMER_ENABLED:-enabled}"; [ "${FAKE_TIMER_ENABLED:-enabled}" = enabled ]; exit
fi
EOS
  cat > "$T/rbin/ss" <<'EOS'
#!/bin/sh
# fake ss -H -ltn: one LISTEN line per local address in FAKE_SS_LISTEN (newline separated)
echo "ss $*" >> "$DCALLS"
if [ -n "${FAKE_SS_MISSING:-}" ]; then echo "sh: 1: ss: not found" >&2; exit 127; fi
printf '%s\n' "${FAKE_SS_LISTEN:-}" | while IFS= read -r a; do
  [ -n "$a" ] || continue
  case " $* " in
    *" -H -ltnp "*) [ -n "${FAKE_SS_OWNED:-}" ] && u=' users:(("goweb",pid=1,fd=3))' || u="" ;;
    *) u="" ;;
  esac
  echo "LISTEN 0      4096   $a   0.0.0.0:*$u"
done
exit 0
EOS
  cat > "$T/rbin/loginctl" <<'EOS'
#!/bin/sh
echo "Linger=${FAKE_LINGER:-yes}"
EOS
  cat > "$T/rbin/curl" <<'EOS'
#!/bin/sh
echo "curl $*" >> "$DCALLS"
v="$("$HOME/goweb/current/goweb" __version 2>/dev/null)"
for bad in $FAKE_UNHEALTHY; do [ "$bad" = "$v" ] && exit 22; done
for f in $FAKE_FLAP; do
  if [ "$f" = "$v" ]; then
    if [ -e "$HOME/.flap-$v" ]; then exit 22; fi
    : > "$HOME/.flap-$v"
  fi
done
echo "{\"status\":\"ok\",\"version\":\"$v\",\"commit\":\"abc\"}"
EOS
  cat > "$T/lbin/go" <<'EOS'
#!/bin/bash
echo "go GOOS=${GOOS:-} GOARCH=${GOARCH:-} CGO_ENABLED=${CGO_ENABLED:-} PWD=$PWD $*" >> "$DCALLS"
case "$1" in vet|test) [ "${FAKE_GO_FAIL:-}" = "$1" ] && { echo "fake go $1: injected failure" >&2; exit 1; }; exit 0 ;; esac
out=""; ver=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -ldflags) ver="$(printf '%s' "$2" | sed -n 's/.*version\.Version=\([^ ]*\).*/\1/p')"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 0
sed -e "s|@VERSION@|$ver|g" -e "s|@SCHEMA@|${FAKE_NEW_SCHEMA:-0001_init.sql}|g" "$FAKEBIN_TMPL" > "$out"
chmod +x "$out"
EOS
  cat > "$T/lbin/pnpm" <<'EOS'
#!/bin/bash
# fake pnpm: records its arguments and directory; FAKE_PNPM_FAIL=<subcommand> fails that one.
echo "pnpm ARGS=$* PWD=$PWD" >> "$DCALLS"
[ "${FAKE_PNPM_FAIL:-}" = "$1" ] && { echo "fake pnpm $1: injected failure" >&2; exit 1; }
exit 0
EOS
  cat > "$T/lbin/node" <<'EOS'
#!/bin/sh
echo "v${FAKE_NODE_MAJOR:-24}.1.0"
EOS
  chmod +x "$T/ssh" "$T/rsync" "$T/rbin/"* "$T/lbin/go" "$T/lbin/pnpm" "$T/lbin/node"
  export FAKE_RBIN="$T/rbin" FAKEBIN_TMPL="$T/fakebin.tmpl"
  export SSH="$T/ssh" RSYNC="$T/rsync"
  export SKIP_WEB_BUILD=1 SKIP_TESTS=1 HEALTH_TIMEOUT=2 HEALTH_RECHECK_DELAY=0
  echo "<html>" > "$T/index.html"
  export EMBED_INDEX="$T/index.html"
  export PATH="$T/lbin:$PATH"
  unset ALLOW_DEV_DEPLOY FAKE_NO_UNIT FAKE_UNHEALTHY FAKE_LINGER FAKE_RSYNC_CORRUPT FAKE_NEW_SCHEMA PUBLIC_URL REMOTE_BASE FAKE_FLAP FAKE_BACKUP_FAIL FAKE_BACKUP_EMPTY HEALTH_PORT FAKE_SERVICE_ACTIVE FAKE_SS_LISTEN FAKE_SS_OWNED EXPECT_PUBLIC_LISTENER FAKE_TIMER_ENABLED FAKE_GO_FAIL FAKE_PNPM_FAIL FAKE_NODE_MAJOR REQUIRE_BACKUP_TIMER FAKE_SSH_FAIL_END FAKE_TIMER_BUS_ERROR FAKE_SS_MISSING FAKE_EXPECT_UNIT
}

# make_release <name> <schema> [active]
make_release() {
  mkdir -p "$T/home/goweb/releases/$1"
  make_fake_binary_script "$T/home/goweb/releases/$1/goweb" "$1" "$2"
  if [ "${3:-}" = active ]; then ln -sfn "releases/$1" "$T/home/goweb/current"; fi
}

deploy() { VERSION="${DEPLOY_VERSION:-v2}" bash "$SCRIPT_DIR/deploy.sh" "$@" >"$T/out" 2>"$T/err"; }
active_release() { readlink "$T/home/goweb/current" 2>/dev/null; }

test_deploy_aborts_when_linger_is_off() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_LINGER=no deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "loginctl enable-linger" "names the fix"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "service not touched" grep -q "^systemctl --user restart" "$DCALLS"
}

test_deploy_rolls_back_on_failed_health_check() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_UNHEALTHY="v2" deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "rolled back automatically" "stderr"
  assert_eq "$(active_release)" "releases/v1" "current back on v1"
  assert_eq "$(grep -c '^systemctl --user restart' "$DCALLS")" "2" "restarted twice"
}

test_deploy_does_not_roll_back_when_schema_version_changed_and_prints_restore_command() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_NEW_SCHEMA=0002_more.sql FAKE_UNHEALTHY="v2" deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(active_release)" "releases/v2" "binary not rolled back"
  assert_false "no rollback message" grep -q "rolled back automatically" "$T/err"
  assert_contains "$(cat "$T/err")" "previous binary may not work" "warning"
  assert_contains "$(cat "$T/err")" "restore.sh" "restore command"
  assert_contains "$(cat "$T/err")" "data/backups/" "names the pre-deploy backup"
  assert_eq "$(grep -c '^systemctl --user restart' "$DCALLS")" "1" "restarted once"
}

test_deploy_keeps_previous_release() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_eq "$(active_release)" "releases/v2" "current is v2"
  assert_true "v1 kept" test -x "$T/home/goweb/releases/v1/goweb"
  assert_true "v2 present" test -x "$T/home/goweb/releases/v2/goweb"
  assert_eq "$(grep -c '^backup DATA_DIR=' "$DCALLS")" "1" "pre-deploy backup ran once"
  assert_false "no uploading leftovers" test -e "$T/home/goweb/releases/v2.uploading"
  assert_contains "$(cat "$T/out")" "healthy" "progress"
}

test_deploy_aborts_on_checksum_mismatch_before_switching() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_RSYNC_CORRUPT=1 deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "checksum" "stderr"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "no release dir" test -e "$T/home/goweb/releases/v2"
  assert_false "no leftover" test -e "$T/home/goweb/releases/v2.uploading"
  assert_false "service not restarted" grep -q "^systemctl --user restart" "$DCALLS"
}

test_deploy_first_release_works_without_current() {
  setup_deploy
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_eq "$(active_release)" "releases/v2" "current is v2"
  assert_false "no backup on first deploy" grep -q '^backup DATA_DIR=' "$DCALLS"
  assert_contains "$(cat "$T/out")" "first deploy" "says so"
  assert_contains "$(grep '^go ' "$DCALLS")" "GOOS=linux GOARCH=amd64 CGO_ENABLED=0" "cross compile env"
  assert_contains "$(grep '^go ' "$DCALLS")" "version.Version=v2" "version injected"
  assert_contains "$(grep '^ssh ' "$DCALLS" | head -1)" "BatchMode=yes" "ssh options"
  assert_false ".env never uploaded" sh -c "grep '^rsync' \"\$DCALLS\" | grep -q \"\\.env\""
  assert_false "secret never printed" grep -q "do-not-print-me" "$T/out" "$T/err"
}

test_deploy_first_release_unhealthy_says_no_rollback_target() {
  setup_deploy
  FAKE_UNHEALTHY="v2" deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "no previous release" "stderr"
}

test_deploy_rejects_host_starting_with_a_dash() {
  setup_deploy
  deploy -oProxyCommand=evil
  assert_false "exit nonzero" test "$?" -eq 0
  deploy "-x@host"
  assert_false "exit nonzero (dash)" test "$?" -eq 0
  deploy ""
  assert_false "exit nonzero (empty)" test "$?" -eq 0
  assert_false "ssh never invoked" grep -q "^ssh" "$DCALLS"
}

test_deploy_rejects_host_with_slash_or_colon() {
  setup_deploy
  deploy "user@host/evil"
  assert_false "slash rejected" test "$?" -eq 0
  deploy "user@host:22"
  assert_false "colon rejected" test "$?" -eq 0
  deploy 'user@host;rm'
  assert_false "semicolon rejected" test "$?" -eq 0
  assert_false "ssh never invoked" grep -q "^ssh" "$DCALLS"
}

test_deploy_check_changes_nothing() {
  setup_deploy; make_release v1 0001_init.sql active
  local before; before="$(cd "$T/home" && find . | sort)"
  deploy deploy@host.example.com --check
  assert_eq "$?" "0" "exit status"
  assert_eq "$(cd "$T/home" && find . | sort)" "$before" "remote tree unchanged"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
  assert_false "no go build" grep -q "^go " "$DCALLS"
  assert_false "no restart" grep -q "^systemctl --user restart" "$DCALLS"
  assert_contains "$(cat "$T/out")" "preflight OK" "stdout"
}

test_deploy_refuses_a_port_already_in_use_by_another_service() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SERVICE_ACTIVE=inactive deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "8080" "names the port"
  assert_contains "$(cat "$T/err")" "ss -ltnp | grep :8080" "says how to find the owner"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
}

test_deploy_allows_the_port_when_our_own_service_is_active() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SS_OWNED=1 FAKE_SERVICE_ACTIVE=active deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_eq "$(active_release)" "releases/v2" "switched"
}

test_deploy_refuses_an_active_unit_when_the_listener_has_no_process_info() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SERVICE_ACTIVE=active deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "8080" "names the port"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
}

test_deploy_refuses_an_inactive_unit_even_when_the_listener_has_process_info() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SS_OWNED=1 FAKE_SERVICE_ACTIVE=inactive deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
}

test_deploy_check_also_refuses_a_busy_port() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SERVICE_ACTIVE=inactive deploy deploy@host.example.com --check
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "8080" "names the port"
}

test_deploy_with_EXPECT_PUBLIC_LISTENER_refuses_a_loopback_ADDR_in_the_server_env() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=production\nSESSION_SECRET=x\nADDR=127.0.0.1:8080\n' > "$T/home/goweb/.env"
  EXPECT_PUBLIC_LISTENER=1 deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "ADDR=0.0.0.0:8080" "names the fix"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
}

# ---- test gate and backup-timer preflight

# gate_deploy: a deploy with the test gate switched on (SKIP_TESTS=0) and a built web app.
test_deploy_runs_the_test_gate_before_anything_changes() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "go vet ran" grep -q "^go .* vet ./\.\.\.$" "$DCALLS"
  assert_true "go test -short ran" grep -q "^go .* test -short ./\.\.\.$" "$DCALLS"
  assert_true "pnpm test ran in web/" grep -q "^pnpm ARGS=test PWD=.*/web$" "$DCALLS"
  assert_true "pnpm typecheck ran" grep -q "^pnpm ARGS=typecheck PWD=.*/web$" "$DCALLS"
  local gate_line lock_line
  gate_line="$(grep -n '^pnpm ARGS=typecheck' "$DCALLS" | head -1 | cut -d: -f1)"
  lock_line="$(grep -n 'deploy.lock' "$DCALLS" | head -1 | cut -d: -f1)"
  assert_true "gate runs before the lock" test "$gate_line" -lt "$lock_line"
}

test_deploy_skips_the_test_gate_with_SKIP_TESTS() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_false "no go vet" grep -q "^go .* vet" "$DCALLS"
  assert_false "no go test" grep -q "^go .* test" "$DCALLS"
  assert_false "no pnpm" grep -q "^pnpm" "$DCALLS"
}

test_deploy_installs_frozen_dependencies_before_the_tests_and_the_build() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 SKIP_WEB_BUILD=0 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "install ran frozen in web/" grep -q "^pnpm ARGS=install --frozen-lockfile PWD=.*/web$" "$DCALLS"
  local i t c b
  i="$(grep -n '^pnpm ARGS=install' "$DCALLS" | head -1 | cut -d: -f1)"
  t="$(grep -n '^pnpm ARGS=test' "$DCALLS" | head -1 | cut -d: -f1)"
  c="$(grep -n '^pnpm ARGS=typecheck' "$DCALLS" | head -1 | cut -d: -f1)"
  b="$(grep -n '^pnpm ARGS=build' "$DCALLS" | head -1 | cut -d: -f1)"
  assert_true "install before pnpm test" test "${i:-99}" -lt "${t:-0}"
  assert_true "install before typecheck" test "${i:-99}" -lt "${c:-0}"
  assert_true "install before pnpm build" test "${i:-99}" -lt "${b:-0}"
  assert_eq "$(grep -c '^pnpm ARGS=install' "$DCALLS")" "1" "installed once"
}

test_deploy_stops_before_anything_changes_when_the_install_fails() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 SKIP_WEB_BUILD=0 FAKE_PNPM_FAIL=install deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "pnpm install --frozen-lockfile failed" "names the step"
  assert_contains "$(cat "$T/err")" "Nothing was changed" "says nothing changed"
  assert_false "no pnpm test" grep -q "^pnpm ARGS=test" "$DCALLS"
  assert_false "no pnpm build" grep -q "^pnpm ARGS=build" "$DCALLS"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
  assert_false "no lock taken" grep -q "deploy.lock" "$DCALLS"
}

test_deploy_still_installs_for_the_build_when_only_the_tests_are_skipped() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=1 SKIP_WEB_BUILD=0 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "install ran" grep -q "^pnpm ARGS=install --frozen-lockfile" "$DCALLS"
  assert_true "build ran" grep -q "^pnpm ARGS=build" "$DCALLS"
  assert_false "no tests" grep -q "^pnpm ARGS=test" "$DCALLS"
}

test_deploy_still_installs_for_the_tests_when_only_the_build_is_skipped() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 SKIP_WEB_BUILD=1 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "install ran" grep -q "^pnpm ARGS=install --frozen-lockfile" "$DCALLS"
  assert_true "tests ran" grep -q "^pnpm ARGS=test" "$DCALLS"
  assert_false "no build" grep -q "^pnpm ARGS=build" "$DCALLS"
}

test_deploy_does_not_install_when_both_the_tests_and_the_build_are_skipped() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=1 SKIP_WEB_BUILD=1 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_false "no pnpm at all" grep -q "^pnpm" "$DCALLS"
}

test_deploy_check_does_not_install() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 SKIP_WEB_BUILD=0 deploy deploy@host.example.com --check
  assert_eq "$?" "0" "exit status"
  assert_false "no pnpm" grep -q "^pnpm" "$DCALLS"
}

test_deploy_check_does_not_run_the_test_gate() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 deploy deploy@host.example.com --check
  assert_eq "$?" "0" "exit status"
  assert_false "no go vet" grep -q "^go .* vet" "$DCALLS"
  assert_false "no pnpm" grep -q "^pnpm" "$DCALLS"
}

# A failing gate changes nothing on the server.
gate_fails_and_changes_nothing() {
  assert_false "exit status must be nonzero" test "$1" -eq 0
  assert_contains "$(cat "$T/err")" "$2" "names the failing step"
  assert_contains "$(cat "$T/err")" "SKIP_TESTS=1" "names the override"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
  assert_false "service not touched" grep -q "^systemctl --user restart" "$DCALLS"
  assert_false "no lock taken" grep -q "deploy.lock" "$DCALLS"
}

test_deploy_stops_when_go_vet_fails() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 FAKE_GO_FAIL=vet deploy deploy@host.example.com
  gate_fails_and_changes_nothing "$?" "go vet"
}

test_deploy_stops_when_go_tests_fail() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 FAKE_GO_FAIL=test deploy deploy@host.example.com
  gate_fails_and_changes_nothing "$?" "go test"
}

test_deploy_stops_when_pnpm_tests_fail() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 FAKE_PNPM_FAIL=test deploy deploy@host.example.com
  gate_fails_and_changes_nothing "$?" "pnpm test"
}

test_deploy_stops_when_pnpm_typecheck_fails() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_TESTS=0 FAKE_PNPM_FAIL=typecheck deploy deploy@host.example.com
  gate_fails_and_changes_nothing "$?" "pnpm typecheck"
}

# The major the script reads from the real .nvmrc (web/.nvmrc, else the root one).
real_nvmrc_major() {
  local f="$REPO_ROOT/web/.nvmrc"
  [ -f "$f" ] || f="$REPO_ROOT/.nvmrc"
  tr -d 'v \r\n' < "$f" | cut -d. -f1
}

# deploy_with_nvmrc <.nvmrc content> [deploy args]: run a copy of the scripts in a throwaway repo
# whose root .nvmrc holds the given text (REPO_ROOT is derived from the script's location).
deploy_with_nvmrc() {
  local v="$1"; shift
  mkdir -p "$T/repo/scripts" "$T/repo/web/api"
  cp "$SCRIPT_DIR/deploy.sh" "$SCRIPT_DIR/smoke.sh" "$SCRIPT_DIR/restore.sh" "$SCRIPT_DIR/build-id.sh" "$T/repo/scripts/"
  printf '%s\n' "$v" > "$T/repo/.nvmrc"
  VERSION=v2 bash "$T/repo/scripts/deploy.sh" "$@" >"$T/out" 2>"$T/err"
}

test_deploy_fails_early_when_node_major_differs_from_nvmrc() {
  setup_deploy; make_release v1 0001_init.sql active
  local want other; want="$(real_nvmrc_major)"; other=$((want + 1))
  SKIP_WEB_BUILD=0 FAKE_NODE_MAJOR=$other deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "Node $want" "names the wanted major"
  assert_contains "$(cat "$T/err")" "v$other" "names the running version"
  assert_false "no pnpm build" grep -q "^pnpm" "$DCALLS"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
}

test_deploy_accepts_a_matching_node_major() {
  setup_deploy; make_release v1 0001_init.sql active
  SKIP_WEB_BUILD=0 FAKE_NODE_MAJOR="$(real_nvmrc_major)" deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_false "no node complaint" grep -q "Node" "$T/err"
}

test_deploy_compares_only_the_major_for_each_nvmrc_form() {
  local form
  for form in "v24" "24" "24.1.0" "v24.18.0"; do
    setup_deploy; make_release v1 0001_init.sql active
    SKIP_WEB_BUILD=0 FAKE_NODE_MAJOR=24 deploy_with_nvmrc "$form" deploy@host.example.com
    assert_eq "$?" "0" "'$form' matches node 24"
    assert_false "no node complaint for '$form'" grep -q "Node" "$T/err"
    rm -rf "$T/home/goweb/releases/v2"; ln -sfn releases/v1 "$T/home/goweb/current"
    SKIP_WEB_BUILD=0 FAKE_NODE_MAJOR=20 deploy_with_nvmrc "$form" deploy@host.example.com
    assert_false "'$form' rejects node 20" test "$?" -eq 0
    assert_contains "$(cat "$T/err")" "Node 24" "names the major for '$form'"
  done
}

test_deploy_skips_the_node_check_for_a_non_numeric_nvmrc() {
  local form
  for form in 'lts/*' 'node' '>=24'; do
    setup_deploy; make_release v1 0001_init.sql active
    SKIP_WEB_BUILD=0 FAKE_NODE_MAJOR=20 deploy_with_nvmrc "$form" deploy@host.example.com
    assert_eq "$?" "0" "'$form' does not fail the deploy"
    assert_contains "$(cat "$T/err")" "cannot compare .nvmrc value '$form' with the local Node; skipping the Node check" "explains the skip for '$form'"
  done
}

test_deploy_skips_the_node_check_when_the_web_build_is_skipped() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_NODE_MAJOR=20 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
}

test_deploy_warns_but_continues_when_the_backup_timer_is_not_enabled() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_TIMER_ENABLED=disabled deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/err")" "goweb-backup.timer" "names the unit"
  assert_contains "$(cat "$T/err")" "docs/deploy.md" "points at the install steps"
  assert_eq "$(active_release)" "releases/v2" "deployed"
}

test_deploy_is_quiet_when_the_backup_timer_is_enabled() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "asked about the timer" grep -q "^systemctl --user is-enabled goweb-backup.timer" "$DCALLS"
  assert_false "no warning" grep -q "backup.timer" "$T/err"
}

test_deploy_refuses_without_the_backup_timer_when_REQUIRE_BACKUP_TIMER() {
  setup_deploy; make_release v1 0001_init.sql active
  REQUIRE_BACKUP_TIMER=1 FAKE_TIMER_ENABLED=disabled deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "goweb-backup.timer" "names the unit"
  assert_contains "$(cat "$T/err")" "enable --now goweb-backup.timer" "names the fix"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "nothing uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "no rsync" grep -q "^rsync" "$DCALLS"
}

test_deploy_check_covers_the_backup_timer() {
  setup_deploy; make_release v1 0001_init.sql active
  REQUIRE_BACKUP_TIMER=1 FAKE_TIMER_ENABLED=disabled deploy deploy@host.example.com --check
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "goweb-backup.timer" "names the unit"
}

test_deploy_uses_SERVICE_for_the_timer_name() {
  setup_deploy; make_release v1 0001_init.sql active
  SERVICE=other REQUIRE_BACKUP_TIMER=1 FAKE_TIMER_ENABLED=disabled deploy deploy@host.example.com --check
  assert_contains "$(cat "$T/err")" "other-backup.timer" "names the unit"
}

test_deploy_refuses_when_the_backup_timer_state_cannot_be_determined_and_REQUIRE_BACKUP_TIMER() {
  local how
  for how in ssh bus; do
    setup_deploy; make_release v1 0001_init.sql active
    if [ "$how" = ssh ]; then export FAKE_SSH_FAIL_END="goweb-backup.timer'"; else export FAKE_TIMER_BUS_ERROR=1; fi
    REQUIRE_BACKUP_TIMER=1 deploy deploy@host.example.com
    assert_false "exit status must be nonzero ($how)" test "$?" -eq 0
    assert_contains "$(cat "$T/err")" "could not determine whether the backup timer is enabled (ssh or user bus failed)" "message ($how)"
    assert_false "does not claim the timer is disabled ($how)" grep -q "is not enabled" "$T/err"
    assert_eq "$(active_release)" "releases/v1" "current unchanged ($how)"
    assert_false "no rsync ($how)" grep -q "^rsync" "$DCALLS"
    unset FAKE_SSH_FAIL_END FAKE_TIMER_BUS_ERROR
  done
}

test_deploy_warns_when_the_backup_timer_state_cannot_be_determined() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_TIMER_BUS_ERROR=1 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/err")" "could not determine whether the backup timer is enabled (ssh or user bus failed)" "warning"
  assert_false "does not claim the timer is disabled" grep -q "is not enabled" "$T/err"
  assert_eq "$(active_release)" "releases/v2" "deployed"
}

test_deploy_says_not_enabled_only_for_a_real_disabled_answer() {
  setup_deploy; make_release v1 0001_init.sql active
  REQUIRE_BACKUP_TIMER=1 FAKE_TIMER_ENABLED=disabled deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "is not enabled" "says not enabled"
  assert_false "not 'could not determine'" grep -q "could not determine" "$T/err"
}

test_deploy_gate_runs_in_web_api_without_the_callers_GOOS_and_GOARCH() {
  setup_deploy; make_release v1 0001_init.sql active
  GOOS=linux GOARCH=amd64 SKIP_TESTS=0 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  local vet test_line build
  vet="$(grep '^go .* vet ' "$DCALLS")"; test_line="$(grep '^go .* test ' "$DCALLS")"; build="$(grep '^go .* build ' "$DCALLS")"
  assert_contains "$vet" "GOOS= GOARCH= " "go vet runs without GOOS and GOARCH"
  assert_contains "$test_line" "GOOS= GOARCH= " "go test runs without GOOS and GOARCH"
  assert_contains "$vet" "/web/api vet" "go vet runs in web/api"
  assert_contains "$test_line" "/web/api test" "go test runs in web/api"
  assert_contains "$build" "GOOS=linux GOARCH=amd64" "the release build keeps its own target"
}

test_deploy_honors_SERVICE_in_the_port_owner_check() {
  setup_deploy; make_release v1 0001_init.sql active
  SERVICE=other FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SS_OWNED=1 deploy deploy@host.example.com
  assert_false "an unexpected unit is inactive, so the port is refused" test "$?" -eq 0
  assert_true "asked about the unit" grep -q "^systemctl --user is-active other" "$DCALLS"
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_EXPECT_UNIT=other SERVICE=other FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SS_OWNED=1 deploy deploy@host.example.com
  assert_eq "$?" "0" "the expected unit is active"
  assert_true "asked about the unit" grep -q "^systemctl --user is-active other" "$DCALLS"
}

test_deploy_says_ss_is_unavailable_after_start_when_ss_is_missing() {
  setup_deploy; make_release v1 0001_init.sql active
  EXPECT_PUBLIC_LISTENER=1 FAKE_SS_MISSING=1 deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "ss is not available on the server, so the public listener on port 8080 could not be checked" "message"
  assert_false "does not claim the port is closed" grep -q "nothing listens" "$T/err"
}

test_deploy_reports_an_ssh_failure_in_the_post_start_listener_check() {
  setup_deploy; make_release v1 0001_init.sql active
  EXPECT_PUBLIC_LISTENER=1 FAKE_SS_OWNED=1 FAKE_SS_LISTEN="0.0.0.0:8080" FAKE_SSH_FAIL_END="ss -H -ltn" deploy deploy@host.example.com
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "could not run ss on the server to check the public listener (ssh failed" "message"
  assert_false "does not claim the port is closed" grep -q "nothing listens" "$T/err"
}

test_deploy_health_port_comes_from_localhost_and_ipv6_loopback_addr_forms() {
  local addr
  for addr in "localhost:9191" "[::1]:9191"; do
    setup_deploy; make_release v1 0001_init.sql active
    printf 'APP_ENV=production\nADDR=%s\n' "$addr" > "$T/home/goweb/.env"
    deploy deploy@host.example.com
    assert_eq "$?" "0" "exit status for $addr"
    assert_contains "$(grep '^curl ' "$DCALLS" | head -1)" "http://127.0.0.1:9191/healthz" "port from $addr"
  done
}

test_deploy_ignores_the_listener_checks_by_default() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=production\nSESSION_SECRET=x\nADDR=127.0.0.1:8080\n' > "$T/home/goweb/.env"
  FAKE_SS_LISTEN="127.0.0.1:8080" FAKE_SS_OWNED=1 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
}

test_listener_forms_public_vs_loopback() {
  local form
  for form in "0.0.0.0:8080" "*:8080" "[::]:8080"; do
    setup_deploy; make_release v1 0001_init.sql active
    EXPECT_PUBLIC_LISTENER=1 FAKE_SS_OWNED=1 FAKE_SS_LISTEN="$form" deploy deploy@host.example.com
    assert_eq "$?" "0" "public form $form passes"
  done
  for form in "127.0.0.1:8080" "[::1]:8080"; do
    setup_deploy; make_release v1 0001_init.sql active
    EXPECT_PUBLIC_LISTENER=1 FAKE_SS_OWNED=1 FAKE_SS_LISTEN="$form" deploy deploy@host.example.com
    assert_false "loopback form $form fails" test "$?" -eq 0
    assert_contains "$(cat "$T/err")" "ADDR=0.0.0.0:" "names the fix for $form"
  done
}

test_deploy_check_fails_when_linger_off() {
  setup_deploy
  FAKE_LINGER=no deploy deploy@host.example.com --check
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "loginctl enable-linger" "names the fix"
}

test_deploy_refuses_to_redeploy_the_active_release() {
  setup_deploy; make_release v2 0001_init.sql active
  deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "active release" "stderr"
}

test_deploy_replaces_an_inactive_release_with_the_same_name() {
  setup_deploy; make_release v1 0001_init.sql active; make_release v2 0001_init.sql
  echo old > "$T/home/goweb/releases/v2/marker"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_false "old content gone" test -e "$T/home/goweb/releases/v2/marker"
  assert_eq "$(active_release)" "releases/v2" "current"
}

test_deploy_prunes_old_releases_but_keeps_active_and_previous() {
  setup_deploy
  local i
  for i in 1 2 3 4 5 6 7; do
    make_release "r$i" 0001_init.sql
    touch -t "20260101000$i" "$T/home/goweb/releases/r$i"
  done
  # previous (active) release is the OLDEST one, so only the retention rule saves it
  ln -sfn releases/r1 "$T/home/goweb/current"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "active kept" test -d "$T/home/goweb/releases/v2"
  assert_true "previous kept" test -d "$T/home/goweb/releases/r1"
  assert_true "r7 kept" test -d "$T/home/goweb/releases/r7"
  assert_true "r6 kept" test -d "$T/home/goweb/releases/r6"
  assert_true "r5 kept" test -d "$T/home/goweb/releases/r5"
  assert_false "r4 pruned" test -e "$T/home/goweb/releases/r4"
  assert_false "r3 pruned" test -e "$T/home/goweb/releases/r3"
  assert_false "r2 pruned" test -e "$T/home/goweb/releases/r2"
}

test_deploy_uses_atomic_mv_T_when_available() {
  setup_deploy; make_release v1 0001_init.sql active
  cat > "$T/rbin/mv" <<'EOS'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "mv (GNU coreutils) 9.4"; exit 0; fi
echo "mv $*" >> "$DCALLS"
if [ "$1" = "-T" ]; then shift; rm -f "$2"; fi
exec /bin/mv "$@"
EOS
  chmod +x "$T/rbin/mv"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$DCALLS")" "mv -T current.new current" "atomic rename used"
  assert_eq "$(active_release)" "releases/v2" "current"
}

test_deploy_rejects_unsafe_remote_base() {
  setup_deploy
  REMOTE_BASE="../etc" deploy deploy@host.example.com
  assert_false "dotdot rejected" test "$?" -eq 0
  REMOTE_BASE="/abs" deploy deploy@host.example.com
  assert_false "absolute rejected" test "$?" -eq 0
  REMOTE_BASE='a b' deploy deploy@host.example.com
  assert_false "space rejected" test "$?" -eq 0
}

# ---------------------------------------------------------------- smoke tests
# A tiny python3 HTTP/1.0 server driven by a JSON config file stands in for the site.

SMOKE_SERVER_PY="$ROOT/fake_site.py"
SMOKE_PID=""
cat > "$SMOKE_SERVER_PY" <<'EOS'
import http.server, json, sys
cfg = json.load(open(sys.argv[1]))
def footer():
    if cfg.get("no_footer"):
        return ""
    return '<footer class="site-footer"><span class="build-id">Build ' + cfg.get("footer_id", cfg.get("build_id", "20261027-abc1234")) + '</span></footer>'
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, ctype, body):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        p = self.path
        if cfg.get("redirect"):
            self.send_response(301)
            self.send_header("Location", cfg["redirect"])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if p == "/healthz":
            h = {"status": "ok", "version": cfg["version"], "commit": "abc"}
            if not cfg.get("no_build_id"):
                h["build_id"] = cfg.get("build_id", "20261027-abc1234")
            self.reply(200, "application/json", json.dumps(h))
        elif p == "/":
            self.reply(200, "text/html", "<html><body><h1>goweb</h1>" + footer() + "</body></html>")
        elif p == "/privacy":
            self.reply(200, "text/html", "<html><body><h1>Privacy</h1><p>" + "We keep your data private. " * 5 + "</p></body></html>")
        elif p == "/app/":
            self.reply(200, "text/html", "<html><div id=root></div>" + ("" if cfg.get("no_app_footer") else "<noscript>" + footer() + "</noscript>") + "</html>")
        elif p == "/static/style.css":
            self.reply(200, "text/css", cfg["css"])
        elif p == "/api/notes":
            self.reply(cfg.get("notes_status", 401), "application/json", "{}")
        else:
            self.reply(cfg.get("nope_status", 404), "text/html", "nope")
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOS

stop_smoke_server() { if [ -n "$SMOKE_PID" ]; then kill "$SMOKE_PID" 2>/dev/null; wait "$SMOKE_PID" 2>/dev/null; SMOKE_PID=""; fi; }
trap 'stop_smoke_server; rm -rf "$ROOT"' EXIT

# start_site <config-json>: sets SITE_URL.
start_site() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "deploy.test.sh: python3 is required for the smoke tests (fake HTTP server) but was not found" >&2
    fail "python3 missing"; return 1
  fi
  printf '%s' "$1" > "$T/site.json"
  rm -f "$T/site.port"
  python3 "$SMOKE_SERVER_PY" "$T/site.json" "$T/site.port" &
  SMOKE_PID=$!
  local i=0
  while [ ! -s "$T/site.port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$T/site.port" ] || { fail "fake site did not start"; return 1; }
  SITE_URL="http://127.0.0.1:$(cat "$T/site.port")"
}

smoke() { bash "$SCRIPT_DIR/smoke.sh" "$@" >"$T/out" 2>"$T/err"; }
smoke_css() { printf 'body{color:#123}\n' > "$T/style.css"; export CSS_FILE="$T/style.css"; }

test_smoke_passes_on_a_good_server() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_eq "$rc" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$T/out")" "smoke OK" "stdout"
}

test_smoke_fails_on_version_mismatch() {
  smoke_css
  start_site '{"version":"v8","css":"body{color:#123}\n"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "/healthz" "names the check"
  assert_contains "$(cat "$T/err")" "v8" "shows observed value"
}

test_smoke_fails_when_nope_is_not_404() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","nope_status":200}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "/nope" "names the check"
  assert_contains "$(cat "$T/err")" "200" "shows observed value"
}

test_smoke_fails_when_css_differs() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:red}\n"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "style.css" "names the check"
}

test_smoke_fails_on_unauthenticated_notes_not_401() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","notes_status":200}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "/api/notes" "names the check"
}

test_smoke_skips_css_when_local_file_is_absent() {
  export CSS_FILE="$T/does-not-exist.css"
  start_site '{"version":"v9","css":"x"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_eq "$rc" "0" "exit status"
  assert_contains "$(cat "$T/out")" "skipped" "says css was skipped"
}

test_smoke_fails_on_redirect_to_another_host() {
  smoke_css
  printf '#!/bin/sh\nexit 0\n' > "$T/fakecurl"; chmod +x "$T/fakecurl"
  # fake curl that reports a 301 for everything
  cat > "$T/fakecurl" <<'EOS'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && : > "$out"
printf '301'
EOS
  CURL="$T/fakecurl" smoke "https://app.example.com" v9
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "301" "shows observed status"
}

test_smoke_requires_arguments() {
  smoke
  assert_false "exit nonzero" test "$?" -eq 0
}

# ---------------------------------------------------------------- build id tests

test_smoke_reports_the_build_id_when_footer_and_healthz_agree() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","build_id":"20261027-abc1234"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_eq "$rc" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$T/out")" "build id 20261027-abc1234" "stdout names the id"
}

test_smoke_fails_when_footer_id_differs_from_healthz() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","build_id":"20261027-abc1234","footer_id":"20261026-def5678"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "20261026-def5678" "shows the footer id"
  assert_contains "$(cat "$T/err")" "20261027-abc1234" "shows the healthz id"
}

test_smoke_fails_when_the_footer_is_missing() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","no_footer":true}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "footer" "names the check"
}

test_smoke_fails_when_healthz_has_no_build_id() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","no_build_id":true}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "build_id" "names the field"
}

test_smoke_fails_on_a_malformed_build_id() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","build_id":"nonsense"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "nonsense" "shows the value"
}

test_smoke_passes_with_a_matching_EXPECTED_BUILD_ID() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","build_id":"20261027-abc1234-dirty"}' || { stop_smoke_server; return; }
  EXPECTED_BUILD_ID=20261027-abc1234-dirty smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_eq "$rc" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$T/out")" "/app/ footer shows Build 20261027-abc1234-dirty" "checks /app/"
}

test_smoke_fails_when_EXPECTED_BUILD_ID_mismatches() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","build_id":"20261027-abc1234"}' || { stop_smoke_server; return; }
  EXPECTED_BUILD_ID=20261027-fffffff smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "20261027-fffffff" "shows the expected id"
  assert_contains "$(cat "$T/err")" "20261027-abc1234" "shows the observed id"
}

test_smoke_fails_when_EXPECTED_BUILD_ID_is_not_in_the_app_html() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","no_app_footer":true}' || { stop_smoke_server; return; }
  EXPECTED_BUILD_ID=20261027-abc1234 smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "/app/" "names the page"
}

test_smoke_compares_EXPECTED_BUILD_ID_literally() {
  smoke_css
  start_site '{"version":"v9","css":"body{color:#123}\n","build_id":"20261027-abc1234"}' || { stop_smoke_server; return; }
  EXPECTED_BUILD_ID='20261027-abc.234' smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "a regex-looking id must not match" test "$rc" -eq 0
}

# deploy_site <build-id-the-site-reports>: starts the fake site for a v2 deploy against it.
deploy_site() {
  smoke_css
  start_site '{"version":"v2","css":"body{color:#123}\n","build_id":"'"$1"'"}' || return 1
  export PUBLIC_URL="$SITE_URL"
}

test_deploy_passes_the_build_id_to_the_build_and_to_smoke() {
  setup_deploy; make_release v1 0001_init.sql active
  local id; id="$(bash "$REPO_ROOT/scripts/build-id.sh")"
  deploy_site "$id" || { stop_smoke_server; return; }
  deploy deploy@host.example.com
  local rc=$?
  stop_smoke_server
  assert_eq "$rc" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(grep '^go ' "$DCALLS")" "-X goweb/internal/version.BuildID=$id" "go build ldflags carry the id"
  assert_contains "$(cat "$T/out")" "build id $id" "progress output names the id"
  assert_contains "$(cat "$T/out")" "done: v2 ($id) is live" "success line names the id"
  assert_contains "$(cat "$T/out")" "smoke OK" "smoke ran"
  assert_contains "$(cat "$T/out")" "build id $id" "smoke checked the deployed id"
}

test_deploy_smoke_fails_when_the_site_serves_another_build_id() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy_site "19990101-0000000" || { stop_smoke_server; return; }
  deploy deploy@host.example.com
  local rc=$?
  stop_smoke_server
  assert_eq "$rc" "1" "exit status"
  assert_contains "$(cat "$T/err")" "19990101-0000000" "shows the observed id"
  assert_contains "$(cat "$T/err")" "smoke check FAILED" "says smoke failed"
}

# ---------------------------------------------------------------- review round 1 tests

LOCKDIR_REL="goweb/.deploy.lock"
hold_lock() { # hold_lock <age-seconds>
  mkdir -p "$T/home/$LOCKDIR_REL"
  echo "othertoken alice@otherbox $(( $(date +%s) - $1 ))" > "$T/home/$LOCKDIR_REL/owner"
}
tree_of_home() { (cd "$T/home" && find . | sort); }

test_deploy_second_deploy_aborts_while_lock_is_held() {
  setup_deploy; make_release v1 0001_init.sql active
  hold_lock 60
  local before; before="$(tree_of_home)"
  deploy deploy@host.example.com
  assert_eq "$?" "1" "exit status"
  assert_contains "$(cat "$T/err")" "another deploy" "message"
  assert_contains "$(cat "$T/err")" "alice@otherbox" "names the holder"
  assert_eq "$(tree_of_home)" "$before" "nothing changed on the server"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "no restart" grep -q "^systemctl --user restart" "$DCALLS"
  assert_true "other deployer's lock still there" test -d "$T/home/$LOCKDIR_REL"
}

test_deploy_takes_over_a_stale_lock_with_a_message() {
  setup_deploy; make_release v1 0001_init.sql active
  hold_lock 7200
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$T/err")$(cat "$T/out")" "stale" "message"
  assert_contains "$(cat "$T/err")$(cat "$T/out")" "alice@otherbox" "names the old holder"
  assert_eq "$(active_release)" "releases/v2" "current"
  assert_false "lock released" test -e "$T/home/$LOCKDIR_REL"
}

test_deploy_releases_the_lock_after_success() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_false "lock released" test -e "$T/home/$LOCKDIR_REL"
}

test_deploy_releases_the_lock_after_a_failed_health_check() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_UNHEALTHY=v2 deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_false "lock released" test -e "$T/home/$LOCKDIR_REL"
}

test_deploy_prune_keeps_a_fresh_uploading_dir_and_removes_an_old_one() {
  setup_deploy; make_release v1 0001_init.sql active
  mkdir "$T/home/goweb/releases/other.uploading" "$T/home/goweb/releases/ancient.uploading"
  touch -t 202001010000 "$T/home/goweb/releases/ancient.uploading"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_true "fresh upload of another deploy kept" test -d "$T/home/goweb/releases/other.uploading"
  assert_false "old leftover removed" test -e "$T/home/goweb/releases/ancient.uploading"
}

test_deploy_backs_up_the_data_dir_from_dotenv() {
  setup_deploy; make_release v1 0001_init.sql active
  mkdir -p "$T/custom/db"; : > "$T/custom/db/goweb.db"
  printf 'APP_ENV=production\nADDR=0.0.0.0:8080\nDATA_DIR=%s\n' "$T/custom" > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$DCALLS")" "backup DATA_DIR=$T/custom" "backup ran against the .env value"
  assert_true "backup landed in the custom dir" test -d "$T/custom/backups"
  assert_false "default dir untouched" test -e "$T/home/goweb/data/backups"
}

test_deploy_restore_command_names_the_resolved_data_dir() {
  setup_deploy; make_release v1 0001_init.sql active
  mkdir -p "$T/custom/db"; : > "$T/custom/db/goweb.db"
  printf 'APP_ENV=production\nADDR=0.0.0.0:8080\nDATA_DIR=%s\n' "$T/custom" > "$T/home/goweb/.env"
  FAKE_NEW_SCHEMA=0002_more.sql FAKE_UNHEALTHY=v2 deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "DATA_DIR=$T/custom" "restore command"
  assert_contains "$(cat "$T/err")" "GOWEB_BIN=" "restore command sets GOWEB_BIN"
}

test_deploy_uses_the_default_data_dir_without_dotenv_setting() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$DCALLS")" "backup DATA_DIR=$T/home/goweb/data" "default"
}

test_deploy_resolves_a_relative_data_dir_against_the_data_dir() {
  setup_deploy; make_release v1 0001_init.sql active
  mkdir -p "$T/home/goweb/data/alt/db"; : > "$T/home/goweb/data/alt/db/goweb.db"
  printf 'APP_ENV=production\nDATA_DIR=alt\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$DCALLS")" "backup DATA_DIR=$T/home/goweb/data/alt" "relative value"
}

test_deploy_aborts_when_resolved_data_dir_has_no_database() {
  setup_deploy; make_release v1 0001_init.sql active
  mkdir -p "$T/empty"
  printf 'APP_ENV=production\nDATA_DIR=%s\n' "$T/empty" > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "goweb.db" "message"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "no backup attempted" grep -q '^backup DATA_DIR=' "$DCALLS"
  assert_false "no release uploaded" test -e "$T/home/goweb/releases/v2"
  assert_false "lock released" test -e "$T/home/$LOCKDIR_REL"
}

test_deploy_rejects_quotes_and_carriage_returns_in_dotenv_keys_it_reads() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=production\nDATA_DIR="%s"\n' "$T/home/goweb/data" > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_false "quotes rejected" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "DATA_DIR" "names the key"
  printf 'APP_ENV=production\nADDR=0.0.0.0:8080\r\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_false "CR rejected" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "ADDR" "names the key"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
}

test_deploy_health_port_comes_from_dotenv_addr() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=production\nADDR=0.0.0.0:9191\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_contains "$(grep '^curl ' "$DCALLS" | head -1)" "http://127.0.0.1:9191/healthz" "port from ADDR"
}

test_deploy_health_port_defaults_to_8080_and_env_var_wins() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=production\nSESSION_SECRET=x\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status"
  assert_contains "$(grep '^curl ' "$DCALLS" | head -1)" "127.0.0.1:8080/healthz" "default"
  : > "$DCALLS"; make_release v3 0001_init.sql
  printf 'APP_ENV=production\nADDR=0.0.0.0:9191\n' > "$T/home/goweb/.env"
  HEALTH_PORT=7000 DEPLOY_VERSION=v4 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status 2"
  assert_contains "$(grep '^curl ' "$DCALLS" | head -1)" "127.0.0.1:7000/healthz" "HEALTH_PORT wins"
}

test_deploy_rejects_dot_and_dash_versions_and_bases() {
  setup_deploy
  local v
  for v in . .. -x .hidden a..b; do
    DEPLOY_VERSION="$v" deploy deploy@host.example.com
    assert_false "VERSION '$v' rejected" test "$?" -eq 0
  done
  for v in . .. -x .hidden a..b a/.b a//b; do
    REMOTE_BASE="$v" deploy deploy@host.example.com
    assert_false "REMOTE_BASE '$v' rejected" test "$?" -eq 0
  done
  assert_false "ssh never invoked" grep -q "^ssh" "$DCALLS"
}

test_deploy_does_not_roll_back_when_previous_binary_has_no_schema_version() {
  setup_deploy; make_release v1 NONE active
  FAKE_UNHEALTHY=v2 deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_eq "$(active_release)" "releases/v2" "binary not rolled back"
  assert_false "no rollback message" grep -q "rolled back automatically" "$T/err"
  assert_contains "$(cat "$T/err")" "restore.sh" "restore command"
}

test_deploy_aborts_when_the_predeploy_backup_fails() {
  setup_deploy; make_release v1 0001_init.sql active
  local before; before="$(tree_of_home)"
  FAKE_BACKUP_FAIL=1 deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "backup" "message"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_eq "$(tree_of_home)" "$before" "server tree unchanged"
  assert_false "no restart" grep -q "^systemctl --user restart" "$DCALLS"
}

test_deploy_aborts_when_the_predeploy_backup_prints_nothing() {
  setup_deploy; make_release v1 0001_init.sql active
  local before; before="$(tree_of_home)"
  FAKE_BACKUP_EMPTY=1 deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_eq "$(tree_of_home)" "$before" "server tree unchanged"
  assert_false "no restart" grep -q "^systemctl --user restart" "$DCALLS"
}

test_deploy_health_failure_hints_at_the_journal_and_resets_failed_state() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_UNHEALTHY=v2 deploy deploy@host.example.com
  assert_contains "$(cat "$T/err")" "journalctl --user -u goweb" "hint"
  assert_contains "$(cat "$T/err")" "migration" "mentions a running migration"
  assert_contains "$(grep '^systemctl' "$DCALLS" | tr '\n' ';')" "reset-failed goweb;systemctl --user restart goweb" "reset-failed before the rollback restart"
}

test_deploy_treats_a_health_flap_as_failure() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_FLAP=v2 deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "rolled back automatically" "rolled back"
  assert_eq "$(active_release)" "releases/v1" "current"
}

test_deploy_health_timeout_counts_real_seconds() {
  setup_deploy; make_release v1 0001_init.sql active
  local start end; start="$(date +%s)"
  HEALTH_TIMEOUT=3 FAKE_UNHEALTHY=v2 deploy deploy@host.example.com
  end="$(date +%s)"
  assert_true "waited at least the timeout" test $((end - start)) -ge 3
}

test_smoke_fails_on_a_real_redirect_to_another_host() {
  smoke_css
  start_site '{"version":"v9","css":"x","redirect":"http://other.example/"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" v9
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "301" "observed redirect status"
  assert_false "did not follow to the other host" grep -q "000" "$T/err"
}

test_smoke_compares_the_version_exactly_not_as_a_pattern() {
  smoke_css
  start_site '{"version":"v09","css":"body{color:#123}\n"}' || { stop_smoke_server; return; }
  smoke "$SITE_URL" 'v.9'
  local rc=$?
  stop_smoke_server
  assert_false "exit nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "v09" "observed"
}

test_restore_rejects_a_directory_as_GOWEB_BIN() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z)"
  GOWEB_BIN="$T" restore "$b" --drill
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "GOWEB_BIN" "names the variable"
}

test_restore_defaults_to_home_goweb_current_binary() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z)"
  mkdir -p "$T/h/goweb/current"; cp "$GOWEB_BIN" "$T/h/goweb/current/goweb"
  unset GOWEB_BIN
  HOME="$T/h" restore "$b" --drill
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$T/out")" "DRILL OK" "stdout"
}

# A server .env that would run the app in development mode (built-in session key,
# no Secure cookies) is refused unless the operator opts in with ALLOW_DEV_DEPLOY=1.
test_deploy_refuses_a_development_dotenv_and_changes_nothing() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=development\nADDR=0.0.0.0:8080\n' > "$T/home/goweb/.env"
  local before; before="$(tree_of_home)"
  deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "APP_ENV" "names the key"
  assert_contains "$(cat "$T/err")" "production" "names the required value"
  assert_contains "$(cat "$T/err")" "ALLOW_DEV_DEPLOY=1" "names the override"
  assert_contains "$(cat "$T/err")" "Nothing was changed" "says nothing changed"
  assert_eq "$(tree_of_home)" "$before" "server tree unchanged"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
  assert_false "no build" grep -q "^go " "$DCALLS"
  assert_false "no upload" grep -q "^rsync" "$DCALLS"
  assert_false "no restart" grep -q "^systemctl --user restart" "$DCALLS"
}

test_deploy_refuses_a_dotenv_without_APP_ENV() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'SESSION_SECRET=x\nADDR=0.0.0.0:8080\n# APP_ENV=production\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "APP_ENV" "names the key"
  assert_contains "$(cat "$T/err")" "development" "explains the default"
  assert_eq "$(active_release)" "releases/v1" "current unchanged"
}

test_deploy_check_refuses_a_development_dotenv() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=development\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com --check
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "APP_ENV" "names the key"
  assert_false "no preflight OK" grep -q "preflight OK" "$T/out"
}

test_deploy_accepts_a_production_dotenv() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'ADDR=0.0.0.0:8080\nAPP_ENV=development\nAPP_ENV=production\n' > "$T/home/goweb/.env"
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_eq "$(active_release)" "releases/v2" "current is v2"
  assert_false "no dev warning" grep -q "ALLOW_DEV_DEPLOY" "$T/err"
}

test_deploy_allows_a_development_dotenv_with_ALLOW_DEV_DEPLOY() {
  setup_deploy; make_release v1 0001_init.sql active
  printf 'APP_ENV=development\nADDR=0.0.0.0:8080\n' > "$T/home/goweb/.env"
  ALLOW_DEV_DEPLOY=1 deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_eq "$(active_release)" "releases/v2" "current is v2"
  assert_contains "$(cat "$T/err")" "WARNING" "loud warning"
  assert_contains "$(cat "$T/err")" "development" "says which mode"
}

# Pre-deploy backups are a labeled set with their own retention, so deploys never
# push the daily sets out.
test_deploy_takes_a_labeled_predeploy_backup_with_its_own_retention() {
  setup_deploy; make_release v1 0001_init.sql active
  deploy deploy@host.example.com
  assert_eq "$?" "0" "exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$DCALLS")" "backup ARGS=backup --label predeploy --keep 5" "labeled backup"
  assert_contains "$(cat "$T/out")" "5 newest pre-deploy sets" "progress names the retention"
}

test_restore_accepts_a_labeled_set() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z-predeploy)"
  restore "$b" --drill
  assert_eq "$?" "0" "drill exit status ($(cat "$T/err"))"
  assert_contains "$(cat "$T/out")" "DRILL OK $b" "drill stdout"
  cp -R "$ROOT/master-live" "$T/data"
  export DATA_DIR="$T/data" HEALTH_CMD="true"
  restore "$b"
  assert_eq "$?" "0" "restore exit status ($(cat "$T/err"))"
  assert_eq "$(live_email)" "backup@example.com" "db replaced from the labeled set"
}

test_pull_ignores_labeled_sets_for_copy_keep_and_staleness() {
  make_fakes; pull_env
  export KEEP=2
  remote_set 20261019T120000Z; remote_set 20261020T120000Z
  remote_set 20261027T120000Z-predeploy
  remote_set 20261027T130000Z-other
  pull
  assert_false "stale daily set still alerts (a fresh labeled set does not count)" test "$?" -eq 0
  assert_contains "$(cat "$NOTIFIED")" "stale" "notified"
  assert_eq "$(ls "$T/dest" | grep -v '^failed$' | tr '\n' ' ')" "20261019T120000Z 20261020T120000Z " "only daily sets pulled; labeled sets not counted toward KEEP"
  assert_false "labeled set not pulled" test -e "$T/dest/20261027T120000Z-predeploy"
  assert_false "labeled set not quarantined" test -e "$T/dest/failed/20261027T120000Z-predeploy"
}

test_deploy_missing_unit_hint_mentions_the_user_bus() {
  setup_deploy; make_release v1 0001_init.sql active
  FAKE_NO_UNIT=1 deploy deploy@host.example.com --check
  assert_false "exit nonzero" test "$?" -eq 0
  assert_contains "$(cat "$T/err")" "not installed" "says the unit is missing"
  assert_contains "$(cat "$T/err")" "XDG_RUNTIME_DIR" "mentions the user bus"
  assert_contains "$(cat "$T/err")" "loginctl show-user" "how to check linger and the session"
  assert_contains "$(cat "$T/err")" "systemctl --user status" "how to check the user manager"
}

# ------------------------------------------------------------ backup agent tests

# agent_env: fake launchctl (stateful: bootstrap loads, bootout unloads, list checks), a fake
# HOME-like LAUNCHAGENTS_DIR and an env file. Never touches the real launchd.
agent_env() {
  mkdir -p "$T/agents" "$T/home" "$T/bin"
  cat > "$T/launchctl" <<'EOS'
#!/bin/sh
echo "$*" >> "$LC_CALLS"
# FAKE_BOOT_POLLS=N: after a bootout the job still counts as loaded for N `list` polls (bootout is
# asynchronous on a real Mac). FAKE_BOOTSTRAP_FAILS=N: the first N bootstraps fail with an I/O error.
case "$1" in
  bootstrap)
    n="$(cat "$LC_STATE.bs" 2>/dev/null || echo 0)"
    if [ "$n" -lt "${FAKE_BOOTSTRAP_FAILS:-0}" ]; then
      echo $((n + 1)) > "$LC_STATE.bs"
      echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
    fi
    : > "$LC_STATE" ;;
  bootout)
    echo "${FAKE_BOOT_POLLS:-0}" > "$LC_STATE.polls"
    [ -e "$LC_STATE" ] && { rm -f "$LC_STATE"; exit 0; }; exit 113 ;;
  list)
    p="$(cat "$LC_STATE.polls" 2>/dev/null || echo 0)"
    if [ "$p" -gt 0 ]; then echo $((p - 1)) > "$LC_STATE.polls"; exit 0; fi
    [ -z "${FAKE_LIST_FAIL:-}" ] && [ -e "$LC_STATE" ] ;;
esac
EOS
  chmod +x "$T/launchctl"
  export LC_CALLS="$T/lc_calls" LC_STATE="$T/lc_state"
  : > "$LC_CALLS"
  export LAUNCHCTL="$T/launchctl" LAUNCHAGENTS_DIR="$T/agents" HOME="$T/home"
  export ENV_FILE="$T/backup-pull.env"
  printf 'REMOTE=deploy@host.example.com\nREMOTE_DIR=goweb/data/backups\n' > "$ENV_FILE"
}
agent() { bash "$SCRIPT_DIR/install-backup-agent.sh" "$@" >"$T/out" 2>"$T/err"; }
AGENT_PLIST() { echo "$T/agents/com.goweb.backup-pull.plist"; }

test_agent_install_writes_a_plist_that_loads_the_env_file() {
  agent_env
  agent
  assert_eq "$?" "0" "exit status"
  local p; p="$(AGENT_PLIST)"
  assert_true "plist written" test -f "$p"
  local c; c="$(cat "$p")"
  assert_contains "$c" "<string>com.goweb.backup-pull</string>" "label"
  assert_contains "$c" "$ENV_FILE" "env file path in the command"
  assert_contains "$c" "$SCRIPT_DIR/pull-backups.sh" "pull script path"
  assert_contains "$c" "<key>Hour</key><integer>3</integer>" "hour"
  assert_contains "$c" "<key>Minute</key><integer>30</integer>" "minute"
  assert_contains "$c" "$T/home/Library/Logs/goweb/backup-pull.log" "log path"
  assert_contains "$(cat "$LC_CALLS")" "bootstrap" "bootstrapped"
}

test_agent_install_is_idempotent() {
  agent_env
  agent; agent
  assert_eq "$?" "0" "second run exit status"
  assert_eq "$(ls "$T/agents" | wc -l | tr -d ' ')" "1" "exactly one plist"
  assert_eq "$(grep -c '^bootstrap' "$LC_CALLS")" "2" "bootstrapped twice"
  # Asserted on content, not on call indexes: the last bootstrap comes after the last bootout.
  local last_out last_bs
  last_out="$(grep -n '^bootout ' "$LC_CALLS" | tail -1 | cut -d: -f1)"
  last_bs="$(grep -n '^bootstrap ' "$LC_CALLS" | tail -1 | cut -d: -f1)"
  assert_true "old agent booted out" test -n "$last_out"
  assert_true "the second bootstrap follows a bootout" test "${last_bs:-0}" -gt "${last_out:-99999}"
  assert_contains "$(cat "$LC_CALLS")" "bootout gui/$(id -u)/com.goweb.backup-pull" "bootout names the job"
}

test_agent_reinstall_waits_for_bootout_and_retries_an_io_error() {
  agent_env
  agent
  : > "$LC_CALLS"
  FAKE_BOOT_POLLS=2 FAKE_BOOTSTRAP_FAILS=1 agent
  assert_eq "$?" "0" "exit status: $(cat "$T/err")"
  assert_eq "$(grep -c '^bootstrap ' "$LC_CALLS")" "2" "bootstrap retried once"
  # two polls that still see the job, one that sees it gone, all before the first bootstrap, plus the final verify
  local first_bs polls_before
  first_bs="$(grep -n '^bootstrap ' "$LC_CALLS" | head -1 | cut -d: -f1)"
  polls_before="$(head -n "$first_bs" "$LC_CALLS" | grep -c '^list ')"
  assert_true "polled until the job was gone ($polls_before polls)" test "$polls_before" -ge 3
  assert_true "agent is loaded at the end" test -e "$LC_STATE"
}

test_agent_install_gives_up_after_three_bootstrap_io_errors() {
  agent_env
  FAKE_BOOTSTRAP_FAILS=3 agent
  assert_eq "$?" "1" "exit status"
  assert_eq "$(grep -c '^bootstrap ' "$LC_CALLS")" "3" "three attempts"
  assert_contains "$(cat "$T/err")" "launchctl bootstrap failed" "message"
}

test_agent_install_fails_without_REMOTE_or_REMOTE_DIR() {
  agent_env
  printf 'REMOTE=deploy@host.example.com\n' > "$ENV_FILE"
  agent
  assert_eq "$?" "2" "missing REMOTE_DIR"
  printf 'REMOTE_DIR=x\n' > "$ENV_FILE"
  agent
  assert_eq "$?" "2" "missing REMOTE"
  rm -f "$ENV_FILE"
  agent
  assert_eq "$?" "2" "missing env file"
  assert_contains "$(cat "$T/err")" "backup-pull.env.example" "points at the example file"
  assert_eq "$(ls "$T/agents" | wc -l | tr -d ' ')" "0" "nothing written"
  assert_eq "$(cat "$LC_CALLS")" "" "launchctl untouched"
}

test_agent_install_verifies_with_launchctl_list() {
  agent_env
  FAKE_LIST_FAIL=1 agent
  assert_eq "$?" "1" "exit status"
  assert_contains "$(cat "$T/err")" "$T/home/Library/Logs/goweb/backup-pull.log" "message names the log path"
}

test_agent_uninstall_removes_plist_and_boots_out() {
  agent_env
  agent
  agent --uninstall
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/out")" "removed" "says removed"
  assert_false "plist removed" test -e "$(AGENT_PLIST)"
  assert_false "agent unloaded" test -e "$LC_STATE"
  agent --uninstall
  assert_eq "$?" "0" "uninstall twice is fine"
  assert_contains "$(cat "$T/out")" "nothing installed" "second uninstall says so"
  assert_false "no false removed claim" grep -q "removed" "$T/out"
}

test_agent_uninstall_with_nothing_installed_says_so() {
  agent_env
  agent --uninstall
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/out")" "nothing installed" "message"
  assert_false "no removed claim" grep -q "removed" "$T/out"
}

test_agent_dry_run_install_changes_nothing() {
  agent_env
  agent --dry-run
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/out")" "would write $(AGENT_PLIST)" "names the plist"
  assert_contains "$(cat "$T/out")" "would load" "says it would load"
  assert_false "no plist" test -e "$(AGENT_PLIST)"
  assert_false "no log dir" test -e "$T/home/Library/Logs"
  assert_eq "$(cat "$LC_CALLS")" "" "launchctl untouched"
  printf 'REMOTE=x\n' > "$ENV_FILE"
  agent --dry-run
  assert_eq "$?" "2" "dry run still validates the settings"
}

test_agent_dry_run_uninstall_changes_nothing() {
  agent_env
  agent
  : > "$LC_CALLS"
  agent --dry-run --uninstall
  assert_eq "$?" "0" "exit status"
  assert_contains "$(cat "$T/out")" "would unload and remove" "message"
  assert_true "plist kept" test -f "$(AGENT_PLIST)"
  assert_true "still loaded" test -e "$LC_STATE"
  assert_false "no bootout" grep -q '^bootout' "$LC_CALLS"
  agent --uninstall
  agent --uninstall --dry-run
  assert_contains "$(cat "$T/out")" "nothing installed" "dry run with nothing installed"
}

test_agent_passes_a_MIRROR_DIR_with_a_space_intact() {
  agent_env
  printf 'MIRROR_DIR="/tmp/x y"\n' >> "$ENV_FILE"
  cat > "$T/fake-pull.sh" <<'EOS'
#!/bin/sh
printf '%s' "$MIRROR_DIR" > "$PULL_RECORD"
EOS
  chmod +x "$T/fake-pull.sh"
  PULL_SCRIPT="$T/fake-pull.sh" agent
  assert_eq "$?" "0" "install exit status"
  # rebuild the plist's command line from its <string> entries and run it
  local args=() line
  while IFS= read -r line; do args+=("$line"); done < <(sed -n 's|^ *<string>\(.*\)</string>$|\1|p' "$(AGENT_PLIST)" | sed -n '2,7p')
  assert_eq "${#args[@]}" "6" "six command-line entries"
  assert_eq "${args[0]:-}" "/bin/bash" "runs through bash"
  PULL_RECORD="$T/recorded" "${args[@]}" >/dev/null 2>&1
  assert_eq "$(cat "$T/recorded" 2>/dev/null)" "/tmp/x y" "MIRROR_DIR reached the pull script intact"
}

test_agent_install_rejects_an_env_file_that_does_not_source_cleanly() {
  agent_env
  printf 'REMOTE=deploy@host.example.com\nREMOTE_DIR=x\nMIRROR_DIR=/tmp/x y\n' > "$ENV_FILE"
  agent
  assert_eq "$?" "2" "unquoted value with a space"
  assert_contains "$(cat "$T/err")" "$ENV_FILE" "names the file"
  assert_contains "$(cat "$T/err")" "quoted" "says to quote values with spaces"
  printf 'REMOTE=deploy@host.example.com\nREMOTE_DIR=x\nif then fi (\n' > "$ENV_FILE"
  agent
  assert_eq "$?" "2" "plain syntax error"
  assert_contains "$(cat "$T/err")" "$ENV_FILE" "names the file"
  assert_eq "$(ls "$T/agents" | wc -l | tr -d ' ')" "0" "no plist written"
  assert_eq "$(cat "$LC_CALLS")" "" "launchctl untouched"
}

test_agent_plist_is_valid() {
  command -v plutil >/dev/null 2>&1 || { skip "plutil is not installed"; return; }
  agent_env
  printf 'MIRROR_DIR="/tmp/a & <b> y"\n' >> "$ENV_FILE"
  agent
  assert_true "plutil -lint" plutil -lint "$(AGENT_PLIST)"
}

for t in \
  test_restore_drill_passes_on_good_backup \
  test_restore_drill_fails_on_corrupt_db \
  test_restore_drill_fails_when_a_referenced_photo_is_missing \
  test_restore_non_drill_replaces_data_and_restarts_service \
  test_restore_rolls_back_when_health_check_fails \
  test_restore_refuses_empty_or_missing_backup_dir_argument \
  test_restore_does_not_claim_rollback_when_still_unhealthy \
  test_restore_aborts_when_staging_copy_fails \
  test_restore_catches_corrupt_copy_before_swap \
  test_restore_restarts_service_when_safety_copy_fails \
  test_restore_rolls_back_when_swap_fails_midway \
  test_restore_recovery_survives_repeated_signals \
  test_restore_reports_when_rollback_copy_fails \
  test_pull_rejects_corrupt_snapshot_into_failed \
  test_pull_alerts_when_newest_backup_is_stale \
  test_pull_ok_when_newest_backup_is_fresh \
  test_pull_alerts_when_there_is_no_backup_at_all \
  test_pull_prunes_to_KEEP \
  test_pull_skips_partial_sets \
  test_pull_mirror_cleans_leftovers_and_rejects_corrupt_copy \
  test_pull_takes_over_lock_whose_pid_is_an_unrelated_live_process \
  test_pull_takes_over_an_old_lock_even_if_the_pid_is_alive \
  test_pull_exits_3_for_a_real_running_pull_but_still_alerts_when_stale \
  test_pull_takes_over_a_stale_lock_and_releases_its_own \
  test_pull_quarantines_future_dated_sets_and_still_alerts_stale \
  test_pull_quarantines_future_dated_sets_already_held_locally \
  test_pull_works_with_each_installed_rsync \
  test_pull_mirrors_only_when_MIRROR_DIR_exists \
  test_deploy_aborts_when_linger_is_off \
  test_deploy_rolls_back_on_failed_health_check \
  test_deploy_does_not_roll_back_when_schema_version_changed_and_prints_restore_command \
  test_deploy_keeps_previous_release \
  test_deploy_aborts_on_checksum_mismatch_before_switching \
  test_deploy_first_release_works_without_current \
  test_deploy_first_release_unhealthy_says_no_rollback_target \
  test_deploy_rejects_host_starting_with_a_dash \
  test_deploy_rejects_host_with_slash_or_colon \
  test_deploy_check_changes_nothing \
  test_deploy_check_fails_when_linger_off \
  test_deploy_refuses_to_redeploy_the_active_release \
  test_deploy_replaces_an_inactive_release_with_the_same_name \
  test_deploy_prunes_old_releases_but_keeps_active_and_previous \
  test_deploy_uses_atomic_mv_T_when_available \
  test_deploy_rejects_unsafe_remote_base \
  test_smoke_passes_on_a_good_server \
  test_smoke_fails_on_version_mismatch \
  test_smoke_fails_when_nope_is_not_404 \
  test_smoke_fails_when_css_differs \
  test_smoke_fails_on_unauthenticated_notes_not_401 \
  test_smoke_skips_css_when_local_file_is_absent \
  test_smoke_fails_on_redirect_to_another_host \
  test_smoke_requires_arguments \
  test_deploy_second_deploy_aborts_while_lock_is_held \
  test_deploy_takes_over_a_stale_lock_with_a_message \
  test_deploy_releases_the_lock_after_success \
  test_deploy_releases_the_lock_after_a_failed_health_check \
  test_deploy_prune_keeps_a_fresh_uploading_dir_and_removes_an_old_one \
  test_deploy_backs_up_the_data_dir_from_dotenv \
  test_deploy_restore_command_names_the_resolved_data_dir \
  test_deploy_uses_the_default_data_dir_without_dotenv_setting \
  test_deploy_resolves_a_relative_data_dir_against_the_data_dir \
  test_deploy_aborts_when_resolved_data_dir_has_no_database \
  test_deploy_rejects_quotes_and_carriage_returns_in_dotenv_keys_it_reads \
  test_deploy_health_port_comes_from_dotenv_addr \
  test_deploy_health_port_defaults_to_8080_and_env_var_wins \
  test_deploy_rejects_dot_and_dash_versions_and_bases \
  test_deploy_does_not_roll_back_when_previous_binary_has_no_schema_version \
  test_deploy_aborts_when_the_predeploy_backup_fails \
  test_deploy_aborts_when_the_predeploy_backup_prints_nothing \
  test_deploy_health_failure_hints_at_the_journal_and_resets_failed_state \
  test_deploy_treats_a_health_flap_as_failure \
  test_deploy_health_timeout_counts_real_seconds \
  test_smoke_fails_on_a_real_redirect_to_another_host \
  test_smoke_compares_the_version_exactly_not_as_a_pattern \
  test_restore_rejects_a_directory_as_GOWEB_BIN \
  test_restore_defaults_to_home_goweb_current_binary \
  test_deploy_refuses_a_development_dotenv_and_changes_nothing \
  test_deploy_refuses_a_dotenv_without_APP_ENV \
  test_deploy_check_refuses_a_development_dotenv \
  test_deploy_accepts_a_production_dotenv \
  test_deploy_allows_a_development_dotenv_with_ALLOW_DEV_DEPLOY \
  test_deploy_takes_a_labeled_predeploy_backup_with_its_own_retention \
  test_restore_accepts_a_labeled_set \
  test_pull_ignores_labeled_sets_for_copy_keep_and_staleness \
  test_deploy_missing_unit_hint_mentions_the_user_bus \
  test_smoke_reports_the_build_id_when_footer_and_healthz_agree \
  test_smoke_fails_when_footer_id_differs_from_healthz \
  test_smoke_fails_when_the_footer_is_missing \
  test_smoke_fails_when_healthz_has_no_build_id \
  test_smoke_fails_on_a_malformed_build_id \
  test_smoke_passes_with_a_matching_EXPECTED_BUILD_ID \
  test_smoke_fails_when_EXPECTED_BUILD_ID_mismatches \
  test_smoke_fails_when_EXPECTED_BUILD_ID_is_not_in_the_app_html \
  test_smoke_compares_EXPECTED_BUILD_ID_literally \
  test_deploy_passes_the_build_id_to_the_build_and_to_smoke \
  test_deploy_smoke_fails_when_the_site_serves_another_build_id \
  test_deploy_refuses_a_port_already_in_use_by_another_service \
  test_deploy_allows_the_port_when_our_own_service_is_active \
  test_deploy_refuses_an_active_unit_when_the_listener_has_no_process_info \
  test_deploy_refuses_an_inactive_unit_even_when_the_listener_has_process_info \
  test_deploy_check_also_refuses_a_busy_port \
  test_deploy_with_EXPECT_PUBLIC_LISTENER_refuses_a_loopback_ADDR_in_the_server_env \
  test_deploy_ignores_the_listener_checks_by_default \
  test_listener_forms_public_vs_loopback \
  test_agent_install_writes_a_plist_that_loads_the_env_file \
  test_agent_install_is_idempotent \
  test_agent_install_fails_without_REMOTE_or_REMOTE_DIR \
  test_agent_install_verifies_with_launchctl_list \
  test_agent_uninstall_removes_plist_and_boots_out \
  test_agent_reinstall_waits_for_bootout_and_retries_an_io_error \
  test_agent_install_gives_up_after_three_bootstrap_io_errors \
  test_agent_uninstall_with_nothing_installed_says_so \
  test_agent_dry_run_install_changes_nothing \
  test_agent_dry_run_uninstall_changes_nothing \
  test_agent_passes_a_MIRROR_DIR_with_a_space_intact \
  test_agent_plist_is_valid \
  test_agent_install_rejects_an_env_file_that_does_not_source_cleanly \
  test_deploy_runs_the_test_gate_before_anything_changes \
  test_deploy_skips_the_test_gate_with_SKIP_TESTS \
  test_deploy_check_does_not_run_the_test_gate \
  test_deploy_installs_frozen_dependencies_before_the_tests_and_the_build \
  test_deploy_stops_before_anything_changes_when_the_install_fails \
  test_deploy_still_installs_for_the_build_when_only_the_tests_are_skipped \
  test_deploy_still_installs_for_the_tests_when_only_the_build_is_skipped \
  test_deploy_does_not_install_when_both_the_tests_and_the_build_are_skipped \
  test_deploy_check_does_not_install \
  test_deploy_stops_when_go_vet_fails \
  test_deploy_stops_when_go_tests_fail \
  test_deploy_stops_when_pnpm_tests_fail \
  test_deploy_stops_when_pnpm_typecheck_fails \
  test_deploy_fails_early_when_node_major_differs_from_nvmrc \
  test_deploy_accepts_a_matching_node_major \
  test_deploy_compares_only_the_major_for_each_nvmrc_form \
  test_deploy_skips_the_node_check_for_a_non_numeric_nvmrc \
  test_deploy_refuses_when_the_backup_timer_state_cannot_be_determined_and_REQUIRE_BACKUP_TIMER \
  test_deploy_warns_when_the_backup_timer_state_cannot_be_determined \
  test_deploy_says_not_enabled_only_for_a_real_disabled_answer \
  test_deploy_gate_runs_in_web_api_without_the_callers_GOOS_and_GOARCH \
  test_deploy_honors_SERVICE_in_the_port_owner_check \
  test_deploy_says_ss_is_unavailable_after_start_when_ss_is_missing \
  test_deploy_reports_an_ssh_failure_in_the_post_start_listener_check \
  test_deploy_health_port_comes_from_localhost_and_ipv6_loopback_addr_forms \
  test_deploy_skips_the_node_check_when_the_web_build_is_skipped \
  test_deploy_warns_but_continues_when_the_backup_timer_is_not_enabled \
  test_deploy_is_quiet_when_the_backup_timer_is_enabled \
  test_deploy_refuses_without_the_backup_timer_when_REQUIRE_BACKUP_TIMER \
  test_deploy_check_covers_the_backup_timer \
  test_deploy_uses_SERVICE_for_the_timer_name
do
  # ONLY='glob' runs a subset, e.g. ONLY='test_deploy_*' bash scripts/deploy.test.sh
  case "$t" in ${ONLY:-*}) run_test "$t" ;; esac
done

echo "$PASSED passed, $FAILED failed"
echo "SKIPPED: $SKIPPED"
[ "$FAILED" -eq 0 ]
