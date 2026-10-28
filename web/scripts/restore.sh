#!/usr/bin/env bash
# Restore a backup set (as written by `app backup`), or rehearse it.
#
#   restore.sh <backup-dir> [--drill]
#
# --drill restores into a fresh scratch directory only (never touching DATA_DIR
# or the service), re-verifies the restored copy and prints "DRILL OK <dir>".
# Without it: verify the backup, stage a copy of it next to DATA_DIR and verify
# the staged copy, stop the service, copy the current data to
# <DATA_DIR>/backups/pre-restore-<UTC timestamp>/, swap the staged files in
# (same-filesystem renames), start the service and poll the health check. Any
# failure after the stop (including set -e exits) triggers the EXIT handler: it
# rolls back from the pre-restore copy if the swap had begun, always restarts the
# service, re-checks health, and prints the pre-restore path plus anything that
# could not be restored. Exit status is nonzero unless the restore succeeded.
#
# A backup counts only after a drill has passed.
#
# Environment (all optional):
#   DATA_DIR        default $HOME/app/data
#   SERVICE         systemd unit name, default app
#   SYSTEMCTL       default "systemctl --user"
#   APP_BIN         must be the executable FILE. Default: $HOME/app/current/app if it
#                   exists, else `app` on PATH, else <script dir>/../dist/app
#   PORT            default 8080 (used by the default HEALTH_URL)
#   HEALTH_URL      default http://127.0.0.1:$PORT/healthz
#   HEALTH_CMD      shell command that exits 0 when healthy (default: curl HEALTH_URL)
#   HEALTH_TIMEOUT  seconds to wait for health, default 20
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR="${DATA_DIR:-$HOME/app/data}"
SERVICE="${SERVICE:-app}"
SYSTEMCTL="${SYSTEMCTL:-systemctl --user}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${PORT:-8080}/healthz}"
HEALTH_CMD="${HEALTH_CMD:-curl -fsS --max-time 3 -o /dev/null \"$HEALTH_URL\"}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-20}"

die() { echo "restore: $*" >&2; exit 1; }

if [ -n "${APP_BIN:-}" ]; then
  :
elif [ -f "$HOME/app/current/app" ] && [ -x "$HOME/app/current/app" ]; then
  APP_BIN="$HOME/app/current/app"
elif command -v app >/dev/null 2>&1; then
  APP_BIN="$(command -v app)"
elif [ -f "$SCRIPT_DIR/../dist/app" ] && [ -x "$SCRIPT_DIR/../dist/app" ]; then
  APP_BIN="$SCRIPT_DIR/../dist/app"
else
  die "cannot find the binary: set APP_BIN to the path of the executable file (for example \$HOME/app/current/app)"
fi
if [ ! -f "$APP_BIN" ] || [ ! -x "$APP_BIN" ]; then
  die "APP_BIN must be an executable file, not a directory or missing path: $APP_BIN"
fi

# safe_rm_rf <path>: refuse (return 1) to recursively delete anything dangerous.
safe_rm_rf() {
  local p="$1"
  case "$p" in
    ""|"/") echo "restore: refusing to delete '$p'" >&2; return 1 ;;
    /*) ;;
    *) echo "restore: refusing to delete non-absolute path '$p'" >&2; return 1 ;;
  esac
  if [ -n "${HOME:-}" ] && [ "${p%/}" = "${HOME%/}" ]; then
    echo "restore: refusing to delete \$HOME" >&2; return 1
  fi
  rm -rf -- "$p"
}

usage() { echo "usage: restore.sh <backup-dir> [--drill]" >&2; exit 2; }

BACKUP=""
DRILL=0
for arg in "$@"; do
  case "$arg" in
    --drill) DRILL=1 ;;
    -*) usage ;;
    *) [ -z "$BACKUP" ] || usage; BACKUP="$arg" ;;
  esac
done
[ -n "$BACKUP" ] || { echo "restore: missing <backup-dir> argument" >&2; usage; }
[ -d "$BACKUP" ] || die "backup dir does not exist: $BACKUP"
[ -f "$BACKUP/app.db" ] || die "no app.db in $BACKUP"
BACKUP="$(cd "$BACKUP" && pwd)"

# verify <backup-set-dir>: run verify-backup; on failure print its real output.
verify() {
  local out
  if out="$("$APP_BIN" verify-backup "$1" 2>&1)"; then return 0; fi
  echo "restore: verification of $1 failed:" >&2
  echo "$out" | sed 's/^/  /' >&2
  return 1
}

# copy_set <backup-set-dir> <dest-set-dir>: copy app.db and storage/ (new dest).
# Every step is checked explicitly: callers use this in `if`/`||` contexts, where
# set -e does not apply.
copy_set() {
  local src="$1" dst="$2"
  mkdir -p "$dst/storage" || return 1
  cp -P "$src/app.db" "$dst/app.db" || return 1
  if [ -d "$src/storage" ]; then
    cp -RP "$src/storage/." "$dst/storage/" || return 1
  fi
  chmod 600 "$dst/app.db" || return 1
  chmod 700 "$dst" "$dst/storage" || return 1
}

CLEANUP=()
SCRATCH=""
STAGE=""
PRE=""
STOPPED=0      # service stop was attempted: the EXIT handler must restart it
STARTED=0      # service start succeeded at least once after the stop
SWAP_BEGAN=0   # live files may differ from the pre-restore copy
OK=0
PROBLEMS=()

svc() { $SYSTEMCTL "$@" "$SERVICE"; }

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while :; do
    if bash -c "$HEALTH_CMD" >/dev/null 2>&1; then return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

# rollback: put the pre-restore copy back. Continues past individual errors and
# records them in PROBLEMS. Runs with errexit off.
rollback() {
  echo "restore: restoring previous data from $PRE" >&2
  if [ "$STARTED" -eq 1 ]; then svc stop || PROBLEMS+=("could not stop $SERVICE before rollback"); fi
  local f
  for f in app.db app.db-wal app.db-shm; do
    rm -f -- "$DATA_DIR/db/$f" || PROBLEMS+=("could not remove db/$f")
  done
  mkdir -p "$DATA_DIR/db" || PROBLEMS+=("could not create db dir")
  for f in app.db app.db-wal app.db-shm; do
    if [ -e "$PRE/$f" ]; then
      cp -P "$PRE/$f" "$DATA_DIR/db/$f" || PROBLEMS+=("could not restore db/$f from $PRE")
    fi
  done
  if [ -e "$DATA_DIR/storage" ]; then
    safe_rm_rf "$DATA_DIR/storage" || PROBLEMS+=("could not remove restored storage/")
  fi
  if [ -d "$PRE/storage" ]; then
    cp -RP "$PRE/storage" "$DATA_DIR/storage" || PROBLEMS+=("could not restore storage/ from $PRE")
  else
    mkdir -p "$DATA_DIR/storage" || PROBLEMS+=("could not recreate storage/")
  fi
}

on_exit() {
  local rc=$?
  # Ignore further signals so a second Ctrl-C, TERM or HUP cannot abort recovery.
  trap '' INT TERM HUP
  trap - EXIT
  set +e
  if [ "$STOPPED" -eq 1 ] && [ "$OK" -ne 1 ]; then
    [ "$rc" -ne 0 ] || rc=1
    local rolled=0
    if [ "$SWAP_BEGAN" -eq 1 ]; then rollback; rolled=1; fi
    if svc start; then
      if ! wait_healthy; then PROBLEMS+=("health check still failing after restarting $SERVICE"); fi
    else
      PROBLEMS+=("could not start $SERVICE")
    fi
    echo "restore: FAILED. The previous data is copied at: $PRE" >&2
    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
      echo "restore: RECOVERY INCOMPLETE. Manual action needed:" >&2
      local p; for p in "${PROBLEMS[@]}"; do echo "  - $p" >&2; done
    elif [ "$rolled" -eq 1 ]; then
      echo "restore: rolled back to the previous data; service is healthy" >&2
    else
      echo "restore: nothing was changed; service restarted and is healthy" >&2
    fi
  fi
  local d
  for d in ${CLEANUP[@]+"${CLEANUP[@]}"}; do safe_rm_rf "$d" || true; done
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ "$DRILL" -eq 1 ]; then
  verify "$BACKUP" || die "backup failed verification: $BACKUP"
  SCRATCH="$(mktemp -d)"
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || die "could not create scratch dir"
  CLEANUP+=("$SCRATCH")
  mkdir -p "$SCRATCH/data/db" "$SCRATCH/set" || die "could not prepare scratch dir"
  copy_set "$BACKUP" "$SCRATCH/set" || die "could not copy the backup into the scratch dir"
  mv "$SCRATCH/set/app.db" "$SCRATCH/data/db/app.db" || die "scratch install failed"
  mv "$SCRATCH/set/storage" "$SCRATCH/data/storage" || die "scratch install failed"
  # Round trip: open the restored database with the real binary, take a backup of
  # it and verify that (proves the db opens and storage matches its references).
  RESTORED="$(APP_ENV=development DATA_DIR="$SCRATCH/data" "$APP_BIN" backup --keep 1)" ||
    die "restored copy could not be opened and backed up"
  verify "$RESTORED" || die "restored copy failed verification"
  echo "DRILL OK $BACKUP"
  OK=1
  exit 0
fi

# ---- real restore ----
# One line so a wrong default (another app's directory or service) is visible before anything changes.
echo "restore: DATA_DIR=$DATA_DIR SERVICE=$SERVICE APP_BIN=$APP_BIN" >&2
case "$DATA_DIR" in
  /*) ;;
  *) die "DATA_DIR must be an absolute path: '$DATA_DIR'" ;;
esac
[ "$DATA_DIR" != "/" ] || die "DATA_DIR must not be /"
[ "${DATA_DIR%/}" != "${HOME%/}" ] || die "DATA_DIR must not be \$HOME"

verify "$BACKUP" || die "refusing to restore: backup failed verification: $BACKUP"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PRE="$DATA_DIR/backups/pre-restore-$STAMP"
[ ! -e "$PRE" ] || die "$PRE already exists"
STAGE="$DATA_DIR/.restore-stage-$STAMP"
[ ! -e "$STAGE" ] || die "$STAGE already exists"

# Stage a copy on the same filesystem as the live data and verify THAT copy, so a
# bad copy (disk full, truncation) is caught before the service is touched.
mkdir -p "$DATA_DIR" || die "cannot create $DATA_DIR"
CLEANUP+=("$STAGE")
copy_set "$BACKUP" "$STAGE" || die "could not stage the backup in $STAGE"
verify "$STAGE" || die "staged copy failed verification; nothing was changed"

echo "restore: stopping $SERVICE" >&2
STOPPED=1
svc stop || die "could not stop $SERVICE"

mkdir -p "$PRE" || die "cannot create $PRE"
for f in app.db app.db-wal app.db-shm; do
  if [ -e "$DATA_DIR/db/$f" ]; then
    cp -P "$DATA_DIR/db/$f" "$PRE/$f" || die "could not copy db/$f to $PRE"
  fi
done
if [ -d "$DATA_DIR/storage" ]; then
  cp -RP "$DATA_DIR/storage" "$PRE/storage" || die "could not copy storage/ to $PRE"
fi
echo "restore: current data copied to $PRE" >&2

# Swap (renames within one filesystem). From here the live files may be changed.
SWAP_BEGAN=1
mkdir -p "$DATA_DIR/db" || die "cannot create $DATA_DIR/db"
for f in app.db app.db-wal app.db-shm; do
  rm -f -- "$DATA_DIR/db/$f" || die "could not remove db/$f"
done
mv "$STAGE/app.db" "$DATA_DIR/db/app.db" || die "could not install the database"
if [ -e "$DATA_DIR/storage" ]; then
  safe_rm_rf "$DATA_DIR/storage" || die "could not remove the old storage/"
fi
mv "$STAGE/storage" "$DATA_DIR/storage" || die "could not install storage/"

echo "restore: starting $SERVICE" >&2
svc start || die "could not start $SERVICE after restore"
STARTED=1
wait_healthy || die "health check failed after restore"

OK=1
echo "restore: ok. Previous data kept at $PRE"
