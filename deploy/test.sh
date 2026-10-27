#!/usr/bin/env bash
# Tests for deploy/restore.sh and deploy/pull-backups.sh.
# Builds the goweb binary once, builds fixtures with it and the sqlite3 CLI, and
# uses fake SYSTEMCTL / HEALTH_CMD / NOTIFY_CMD scripts. Run: bash deploy/test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "test.sh: the sqlite3 CLI is required to build fixtures but was not found on PATH" >&2
  exit 2
fi

ROOT="$(mktemp -d)"
case "$ROOT" in /tmp/*|/var/*|/private/*) ;; *) echo "test.sh: unexpected temp dir $ROOT" >&2; exit 2 ;; esac
trap 'rm -rf "$ROOT"' EXIT
umask 077

echo "building goweb ..."
if ! (cd "$REPO_ROOT/web/api" && go build -o "$ROOT/goweb" ./cmd/goweb); then
  echo "test.sh: go build failed" >&2
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
CUR_FAIL=""

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
  test_pull_mirrors_only_when_MIRROR_DIR_exists
do
  run_test "$t"
done

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
