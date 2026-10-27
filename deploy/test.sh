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

restore() { bash "$SCRIPT_DIR/restore.sh" "$@" >"$T/out" 2>"$T/err"; }

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
  assert_contains "$(cat "$T/err")" "integrity" "stderr explains the failure"
}

test_restore_drill_fails_when_a_referenced_photo_is_missing() {
  make_fakes
  local b; b="$(new_backup 20261027T120000Z)"
  rm "$b/storage/$PHOTO"
  restore "$b" --drill
  local rc=$?
  assert_false "exit status must be nonzero" test "$rc" -eq 0
  assert_contains "$(cat "$T/err")" "$PHOTO" "stderr names the missing photo"
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
  make_fakes
  cp -R "$ROOT/master-live" "$T/data"
  export DATA_DIR="$T/data" HEALTH_CMD="false"
  local b; b="$(new_backup 20261027T120000Z)"
  restore "$b"
  assert_false "exit status must be nonzero" test "$?" -eq 0
  assert_eq "$(sqlite3 "$T/data/db/goweb.db" 'select email from users')" "live@example.com" "db rolled back"
  assert_eq "$(cat "$T/data/storage/$PHOTO")" "img-live@example.com" "storage rolled back"
  assert_eq "$(cat "$CALLS")" "stop goweb
start goweb
stop goweb
start goweb" "service calls"
  assert_contains "$(cat "$T/err")" "rolled back" "stderr says rolled back"
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
  test_pull_rejects_corrupt_snapshot_into_failed \
  test_pull_alerts_when_newest_backup_is_stale \
  test_pull_ok_when_newest_backup_is_fresh \
  test_pull_alerts_when_there_is_no_backup_at_all \
  test_pull_prunes_to_KEEP \
  test_pull_skips_partial_sets \
  test_pull_works_with_each_installed_rsync \
  test_pull_mirrors_only_when_MIRROR_DIR_exists
do
  run_test "$t"
done

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
