#!/usr/bin/env bash
# Pull goweb backup sets from the server to this machine (run from cron/launchd on
# another machine, usually a Mac). The server holds no credentials for this machine.
#
# For each completed remote set (<UTC timestamp>, never *.partial) not yet held
# locally: rsync it into DEST, run `PRAGMA integrity_check` on the pulled goweb.db
# with the sqlite3 CLI (this machine needs sqlite3 installed), move failures to
# DEST/failed/ and notify. Then prune DEST to the newest KEEP sets (retention:
# 30 snapshots by default, i.e. about a month of daily backups; DEST/failed/ is
# never pruned automatically), mirror to MIRROR_DIR if it exists, and notify when
# the newest verified local snapshot is older than STALE_DAYS or there is none.
#
# A set whose timestamp is more than 1 day in the future is invalid (it would hide
# staleness): it is quarantined in DEST/failed/ with a notification.
#
# Overlapping runs are prevented with a lock directory DEST/.lock (holding the
# owner's PID; a lock whose PID is dead is taken over).
#
# Exit status: 0 all good; 1 something failed or the newest backup is stale;
# 2 bad configuration; 3 another run holds the lock (no notification, so it is
# distinguishable from "stale").
#
# Environment:
#   REMOTE      user@host; empty means REMOTE_DIR is a local path (tests)
#   REMOTE_DIR  directory on the server holding the sets (e.g. goweb/data/backups)
#   DEST        default $HOME/Backups/goweb
#   SSH_KEY     optional identity file passed to ssh with -i
#   KEEP        snapshots to keep, default 30
#   MIRROR_DIR  optional second destination; used only if it already exists and is a
#               directory (never created); writes happen only inside it
#   NOTIFY_CMD  shell command run with the message as $1 (default: macOS
#               notification via osascript, else a line on stderr)
#   STALE_DAYS  default 3
#   RSYNC       default rsync (GNU 3.x and macOS openrsync both work)
#   SQLITE3     default sqlite3
#   NOW_EPOCH   override "now" (seconds since the epoch); for tests
set -uo pipefail
umask 077

REMOTE="${REMOTE:-}"
REMOTE_DIR="${REMOTE_DIR:-}"
DEST="${DEST:-$HOME/Backups/goweb}"
SSH_KEY="${SSH_KEY:-}"
KEEP="${KEEP:-30}"
MIRROR_DIR="${MIRROR_DIR:-}"
STALE_DAYS="${STALE_DAYS:-3}"
RSYNC="${RSYNC:-rsync}"
SQLITE3="${SQLITE3:-sqlite3}"

RC=0
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
PATTERN='^[0-9]{8}T[0-9]{6}Z$'

notify() {
  echo "pull-backups: $1" >&2
  if [ -n "${NOTIFY_CMD:-}" ]; then
    bash -c "$NOTIFY_CMD" notify "$1" >/dev/null 2>&1 || true
  elif [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "goweb backup"' -e 'end run' "$1" >/dev/null 2>&1 || true
  fi
}

fail() { RC=1; notify "$1"; }

# safe_rm_rf <path>: only delete absolute paths that are not /, $HOME or empty.
safe_rm_rf() {
  case "$1" in
    ""|"/"|"$HOME"|"$HOME/") echo "pull-backups: refusing to delete '$1'" >&2; return 1 ;;
    /*) rm -rf -- "$1" ;;
    *) echo "pull-backups: refusing to delete non-absolute '$1'" >&2; return 1 ;;
  esac
}

# epoch_of <YYYYMMDDTHHMMSSZ>: seconds since the epoch (UTC), pure arithmetic so it
# works with BSD and GNU userlands.
epoch_of() {
  local s="$1"
  local y=$((10#${s:0:4})) m=$((10#${s:4:2})) d=$((10#${s:6:2}))
  local hh=$((10#${s:9:2})) mm=$((10#${s:11:2})) ss=$((10#${s:13:2}))
  # days from civil (Howard Hinnant)
  if [ "$m" -le 2 ]; then y=$((y - 1)); fi
  local era=$((y / 400)) yoe=$((y - (y / 400) * 400))
  local mp=$(((m + 9) % 12))
  local doy=$(((153 * mp + 2) / 5 + d - 1))
  local doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  local days=$((era * 146097 + doe - 719468))
  echo $((days * 86400 + hh * 3600 + mm * 60 + ss))
}

now_epoch() { echo "${NOW_EPOCH:-$(date +%s)}"; }

# is_future <name>: more than one day ahead of now.
is_future() { [ "$(epoch_of "$1")" -gt $(($(now_epoch) + 86400)) ]; }

# local_sets <dir>: completed set names in a directory, oldest first.
local_sets() {
  [ -d "$1" ] || return 0
  ls -1 "$1" 2>/dev/null | grep -E "$PATTERN" | sort || true
}

# prune_dir <dir>: keep only the newest KEEP sets.
prune_dir() {
  local dir="$1" n extra
  n="$(local_sets "$dir" | wc -l | tr -d ' ')"
  extra=$((n - KEEP))
  [ "$extra" -gt 0 ] || return 0
  local name
  for name in $(local_sets "$dir" | head -n "$extra"); do
    safe_rm_rf "$dir/$name"
  done
}

if [ -z "$REMOTE_DIR" ]; then
  echo "pull-backups: REMOTE_DIR is required" >&2
  exit 2
fi
case "$KEEP" in ''|*[!0-9]*|0) echo "pull-backups: KEEP must be a positive integer" >&2; exit 2 ;; esac
case "$STALE_DAYS" in ''|*[!0-9]*) echo "pull-backups: STALE_DAYS must be a non-negative integer" >&2; exit 2 ;; esac
case "$REMOTE_DIR" in *\'*|*\"*|*\$*|*\`*|*\\*) echo "pull-backups: unsafe characters in REMOTE_DIR" >&2; exit 2 ;; esac
case "$REMOTE" in -*) echo "pull-backups: invalid REMOTE" >&2; exit 2 ;; esac
case "$DEST" in /*) ;; *) echo "pull-backups: DEST must be an absolute path" >&2; exit 2 ;; esac
if ! command -v "$SQLITE3" >/dev/null 2>&1; then
  echo "pull-backups: the sqlite3 CLI is required to verify snapshots but was not found" >&2
  exit 2
fi

mkdir -p "$DEST/failed" || { echo "pull-backups: cannot create $DEST" >&2; exit 2; }
chmod 700 "$DEST" "$DEST/failed" 2>/dev/null || true

# Lock (mkdir is atomic). A lock whose PID is gone is stale and taken over.
LOCK="$DEST/.lock"
HAVE_LOCK=0
acquire_lock() {
  local tries=0 pid
  while ! mkdir "$LOCK" 2>/dev/null; do
    pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -z "$pid" ]; then sleep 1; pid="$(cat "$LOCK/pid" 2>/dev/null || true)"; fi  # owner may be mid-creation
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "pull-backups: another run is already running (pid $pid, lock $LOCK)" >&2
      exit 3
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 3 ]; then
      echo "pull-backups: cannot take the lock $LOCK" >&2
      exit 3
    fi
    rm -rf -- "$LOCK"
  done
  HAVE_LOCK=1
  echo "$$" > "$LOCK/pid"
}
release_lock() { if [ "$HAVE_LOCK" -eq 1 ]; then rm -rf -- "$LOCK"; fi; }
acquire_lock
trap release_lock EXIT
trap 'exit 130' INT TERM

# Leftovers from an interrupted earlier run (we hold the lock, so none is live).
for p in "$DEST"/*.pulling; do
  [ -e "$p" ] || continue
  safe_rm_rf "$p"
done

SSH_CMD=(ssh $SSH_OPTS)
if [ -n "$SSH_KEY" ]; then SSH_CMD+=(-i "$SSH_KEY"); fi

# List completed remote sets.
if [ -n "$REMOTE" ]; then
  REMOTE_LIST="$("${SSH_CMD[@]}" "$REMOTE" "ls -1 '$REMOTE_DIR'" 2>/dev/null)" || {
    fail "cannot list $REMOTE:$REMOTE_DIR (ssh failed)"
    REMOTE_LIST=""
  }
else
  REMOTE_LIST="$(ls -1 "$REMOTE_DIR" 2>/dev/null)" || {
    fail "cannot list $REMOTE_DIR"
    REMOTE_LIST=""
  }
fi

for name in $(printf '%s\n' "$REMOTE_LIST" | grep -E "$PATTERN" | sort); do
  if [ -e "$DEST/$name" ] || [ -e "$DEST/failed/$name" ]; then continue; fi
  tmp="$DEST/$name.pulling"
  if [ -n "$REMOTE" ]; then
    ssh_e="ssh $SSH_OPTS"
    if [ -n "$SSH_KEY" ]; then ssh_e="$ssh_e -i '$SSH_KEY'"; fi
    "$RSYNC" -a --timeout=60 -e "$ssh_e" "$REMOTE:$REMOTE_DIR/$name/" "$tmp/" >/dev/null 2>&1
  else
    "$RSYNC" -a --timeout=60 "$REMOTE_DIR/$name/" "$tmp/" >/dev/null 2>&1
  fi
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    safe_rm_rf "$tmp"
    fail "rsync of $name failed"
    continue
  fi
  if is_future "$name"; then
    mv "$tmp" "$DEST/failed/$name"
    fail "snapshot $name is dated more than a day in the future; moved to $DEST/failed/"
    continue
  fi
  result="$("$SQLITE3" -readonly "$tmp/goweb.db" 'PRAGMA integrity_check;' 2>&1)"
  if [ "$result" = "ok" ]; then
    mv "$tmp" "$DEST/$name"
    echo "pull-backups: pulled $name" >&2
  else
    mv "$tmp" "$DEST/failed/$name"
    fail "snapshot $name failed integrity_check and was moved to $DEST/failed/"
  fi
done

# Future-dated sets already held locally are invalid too.
for name in $(local_sets "$DEST"); do
  if is_future "$name"; then
    safe_rm_rf "$DEST/failed/$name"
    mv "$DEST/$name" "$DEST/failed/$name"
    fail "snapshot $name is dated more than a day in the future; moved to $DEST/failed/"
  fi
done

prune_dir "$DEST"

# Mirror (only if the directory already exists; everything stays inside it).
# Each set is copied to <name>.pulling, verified, then renamed, so an interrupted
# or corrupt copy is never mistaken for a complete one.
if [ -n "$MIRROR_DIR" ] && [ -d "$MIRROR_DIR" ]; then
  for p in "$MIRROR_DIR"/*.pulling; do
    [ -e "$p" ] || continue
    safe_rm_rf "$p"
  done
  for name in $(local_sets "$DEST"); do
    [ ! -e "$MIRROR_DIR/$name" ] || continue
    mtmp="$MIRROR_DIR/$name.pulling"
    if ! "$RSYNC" -a "$DEST/$name/" "$mtmp/" >/dev/null 2>&1; then
      safe_rm_rf "$mtmp"
      fail "mirror of $name to $MIRROR_DIR failed"
      continue
    fi
    mres="$("$SQLITE3" -readonly "$mtmp/goweb.db" 'PRAGMA integrity_check;' 2>&1)"
    if [ "$mres" = "ok" ]; then
      mv "$mtmp" "$MIRROR_DIR/$name" || fail "mirror of $name: rename failed"
    else
      safe_rm_rf "$mtmp"
      fail "mirror copy of $name failed integrity_check and was discarded"
    fi
  done
  prune_dir "$MIRROR_DIR"
fi

# Freshness.
newest="$(local_sets "$DEST" | tail -n 1)"
if [ -z "$newest" ]; then
  fail "no backup is held in $DEST"
else
  age=$(($(now_epoch) - $(epoch_of "$newest")))
  if [ "$age" -gt $((STALE_DAYS * 86400)) ]; then
    fail "newest backup $newest is stale (older than $STALE_DAYS days)"
  fi
fi

exit "$RC"
