#!/usr/bin/env bash
# Restore a goweb backup set (as written by `goweb backup`), or rehearse it.
#
#   restore.sh <backup-dir> [--drill]
#
# --drill restores into a fresh scratch directory only (never touching DATA_DIR
# or the service), re-verifies the restored copy and prints "DRILL OK <dir>".
# Without it: verify the backup, stop the service, copy the current data to
# <DATA_DIR>/backups/pre-restore-<UTC timestamp>/, swap in the backup, start the
# service and poll the health check; on failure roll back and exit nonzero.
#
# A backup counts only after a drill has passed.
#
# Environment (all optional):
#   DATA_DIR        default $HOME/goweb/data
#   SERVICE         systemd unit name, default goweb
#   SYSTEMCTL       default "systemctl --user"
#   GOWEB_BIN       default `goweb` on PATH, else <script dir>/../goweb
#   PORT            default 8080 (used by the default HEALTH_URL)
#   HEALTH_URL      default http://127.0.0.1:$PORT/healthz
#   HEALTH_CMD      shell command that exits 0 when healthy (default: curl HEALTH_URL)
#   HEALTH_TIMEOUT  seconds to wait for health, default 20
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR="${DATA_DIR:-$HOME/goweb/data}"
SERVICE="${SERVICE:-goweb}"
SYSTEMCTL="${SYSTEMCTL:-systemctl --user}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${PORT:-8080}/healthz}"
HEALTH_CMD="${HEALTH_CMD:-curl -fsS --max-time 3 -o /dev/null \"$HEALTH_URL\"}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-20}"

die() { echo "restore: $*" >&2; exit 1; }

if [ -n "${GOWEB_BIN:-}" ]; then
  :
elif command -v goweb >/dev/null 2>&1; then
  GOWEB_BIN="$(command -v goweb)"
elif [ -x "$SCRIPT_DIR/../goweb" ]; then
  GOWEB_BIN="$SCRIPT_DIR/../goweb"
else
  die "cannot find the goweb binary (set GOWEB_BIN)"
fi
[ -x "$GOWEB_BIN" ] || die "GOWEB_BIN is not executable: $GOWEB_BIN"

# safe_rm_rf <path>: refuse to recursively delete anything dangerous.
safe_rm_rf() {
  local p="$1"
  case "$p" in
    ""|"/"|"$HOME"|"$HOME/") die "refusing to delete '$p'" ;;
    /*) ;;
    *) die "refusing to delete non-absolute path '$p'" ;;
  esac
  [ -z "${HOME:-}" ] || [ "$p" != "${HOME%/}" ] || die "refusing to delete '$p'"
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
[ -f "$BACKUP/goweb.db" ] || die "no goweb.db in $BACKUP"
BACKUP="$(cd "$BACKUP" && pwd)"

verify() {
  "$GOWEB_BIN" verify-backup "$1" >/dev/null
}

# install_data <backup-dir> <data-dir>: place the backup's db and storage into a data dir.
install_data() {
  local src="$1" dst="$2"
  mkdir -p "$dst/db"
  rm -f -- "$dst/db/goweb.db" "$dst/db/goweb.db-wal" "$dst/db/goweb.db-shm"
  cp -P "$src/goweb.db" "$dst/db/goweb.db"
  if [ -d "$dst/storage" ]; then safe_rm_rf "$dst/storage"; fi
  mkdir -p "$dst/storage"
  if [ -d "$src/storage" ]; then
    cp -RP "$src/storage/." "$dst/storage/"
  fi
  chmod 600 "$dst/db/goweb.db"
  chmod 700 "$dst/storage"
}

if [ "$DRILL" -eq 1 ]; then
  verify "$BACKUP" || die "backup failed verification (integrity/photos): $BACKUP"
  SCRATCH="$(mktemp -d)"
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || die "could not create scratch dir"
  trap 'safe_rm_rf "$SCRATCH"' EXIT
  install_data "$BACKUP" "$SCRATCH/data"
  # Round trip: open the restored database with the real binary, take a backup of
  # it and verify that (proves the db opens and storage matches its references).
  if ! RESTORED="$(APP_ENV=development DATA_DIR="$SCRATCH/data" "$GOWEB_BIN" backup --keep 1)"; then
    die "restored copy could not be opened and backed up"
  fi
  verify "$RESTORED" || die "restored copy failed verification (integrity/photos)"
  echo "DRILL OK $BACKUP"
  exit 0
fi

# ---- real restore ----
case "$DATA_DIR" in
  /*) ;;
  *) die "DATA_DIR must be an absolute path: '$DATA_DIR'" ;;
esac
[ "$DATA_DIR" != "/" ] || die "DATA_DIR must not be /"
[ "$DATA_DIR" != "$HOME" ] || die "DATA_DIR must not be \$HOME"

verify "$BACKUP" || die "refusing to restore: backup failed verification (integrity/photos): $BACKUP"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PRE="$DATA_DIR/backups/pre-restore-$STAMP"
[ ! -e "$PRE" ] || die "$PRE already exists"

svc() { $SYSTEMCTL "$@" "$SERVICE"; }

echo "restore: stopping $SERVICE" >&2
svc stop || die "could not stop $SERVICE"

mkdir -p "$PRE"
for f in goweb.db goweb.db-wal goweb.db-shm; do
  if [ -e "$DATA_DIR/db/$f" ]; then cp -P "$DATA_DIR/db/$f" "$PRE/$f"; fi
done
if [ -d "$DATA_DIR/storage" ]; then cp -RP "$DATA_DIR/storage" "$PRE/storage"; fi
echo "restore: current data copied to $PRE" >&2

rollback() {
  echo "restore: restoring previous data from $PRE" >&2
  svc stop || true
  rm -f -- "$DATA_DIR/db/goweb.db" "$DATA_DIR/db/goweb.db-wal" "$DATA_DIR/db/goweb.db-shm"
  for f in goweb.db goweb.db-wal goweb.db-shm; do
    if [ -e "$PRE/$f" ]; then cp -P "$PRE/$f" "$DATA_DIR/db/$f"; fi
  done
  if [ -d "$DATA_DIR/storage" ]; then safe_rm_rf "$DATA_DIR/storage"; fi
  if [ -d "$PRE/storage" ]; then cp -RP "$PRE/storage" "$DATA_DIR/storage"; else mkdir -p "$DATA_DIR/storage"; fi
  svc start || true
}

if ! install_data "$BACKUP" "$DATA_DIR"; then
  echo "restore: installing the backup failed" >&2
  rollback
  die "install failed; rolled back to the previous data"
fi

echo "restore: starting $SERVICE" >&2
if ! svc start; then
  rollback
  die "could not start $SERVICE after restore; rolled back to the previous data"
fi

healthy=0
deadline=$((SECONDS + HEALTH_TIMEOUT))
while :; do
  if bash -c "$HEALTH_CMD" >/dev/null 2>&1; then healthy=1; break; fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 1
done

if [ "$healthy" -ne 1 ]; then
  rollback
  die "health check failed after restore; rolled back to the previous data (copy kept at $PRE)"
fi
echo "restore: ok. Previous data kept at $PRE"
