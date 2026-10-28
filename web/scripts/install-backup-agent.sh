#!/usr/bin/env bash
# Install (or remove) the macOS launchd agent that runs web/scripts/pull-backups.sh daily at 03:30.
#
#   web/scripts/install-backup-agent.sh               install or replace the agent
#   web/scripts/install-backup-agent.sh --uninstall   unload and remove it ("nothing installed" when
#                                                 there is nothing to remove)
#   add --dry-run to either to print what would be written, loaded or removed and change nothing
#   (the settings are still validated).
#
# Reinstalling unloads the old job, waits (up to about 5 s) until launchd reports it gone, then
# bootstraps, retrying up to 3 times on launchd's transient "Input/output error".
#
# Settings come from ENV_FILE (default $HOME/.config/app/backup-pull.env; copy
# web/scripts/backup-pull.env.example there). It must define REMOTE and REMOTE_DIR and may define
# DEST, MIRROR_DIR, KEEP, SSH_KEY, STALE_DAYS (see pull-backups.sh). The agent sources the file
# at run time, so later edits apply without reinstalling.
#
# Environment overrides (tests): ENV_FILE, LAUNCHAGENTS_DIR (default $HOME/Library/LaunchAgents),
# LAUNCHCTL (default launchctl), PULL_SCRIPT (default pull-backups.sh next to this script).
# Output goes to $HOME/Library/Logs/app/backup-pull.log.
# Exit status: 0 ok; 1 install or verify failure; 2 bad configuration.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.app.backup-pull"
ENV_FILE="${ENV_FILE:-$HOME/.config/app/backup-pull.env}"
LAUNCHAGENTS_DIR="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
PULL_SCRIPT="${PULL_SCRIPT:-$HERE/pull-backups.sh}"
LOG_DIR="$HOME/Library/Logs/app"
LOG="$LOG_DIR/backup-pull.log"
PLIST="$LAUNCHAGENTS_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

die() { echo "install-backup-agent: $2" >&2; exit "$1"; }

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

UNINSTALL=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --dry-run) DRY=1 ;;
    *) die 2 "usage: $0 [--uninstall] [--dry-run]" ;;
  esac
done

# wait_unloaded: bootout is asynchronous, so poll (0.2 s steps, about 5 s) until launchd no longer lists the job.
wait_unloaded() {
  local i=0
  while "$LAUNCHCTL" list "$LABEL" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 25 ]; then echo "install-backup-agent: warning: $LABEL still listed after 5 s; continuing" >&2; return 0; fi
    sleep 0.2
  done
}

if [ "$UNINSTALL" -eq 1 ]; then
  installed=0
  if [ -e "$PLIST" ] || "$LAUNCHCTL" list "$LABEL" >/dev/null 2>&1; then installed=1; fi
  if [ "$installed" -eq 0 ]; then
    echo "install-backup-agent: nothing installed ($LABEL)"
    exit 0
  fi
  if [ "$DRY" -eq 1 ]; then
    echo "install-backup-agent: would unload and remove $LABEL ($PLIST)"
    exit 0
  fi
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "install-backup-agent: removed $LABEL"
  exit 0
fi

echo "install-backup-agent: label $LABEL, settings $ENV_FILE, log $LOG" >&2

# Validate everything before writing anything.
[ -f "$ENV_FILE" ] || die 2 "settings file $ENV_FILE not found; copy $HERE/backup-pull.env.example there and edit it"
[ -f "$PULL_SCRIPT" ] || die 2 "$PULL_SCRIPT not found"
bad_env="$ENV_FILE could not be read as shell settings; values containing spaces must be quoted"
bash -n "$ENV_FILE" >/dev/null 2>&1 || die 2 "$bad_env"
# A separate bash process, not a subshell: newer bash versions ignore `set -e` inside a command substitution
# that sits on the left of `||`, which would let `KEY=a b` (a command named b) pass as a clean file.
missing="$(bash -c 'set -e; set -a; . "$1" >/dev/null 2>&1
  m=""; [ -n "${REMOTE:-}" ] || m="$m REMOTE"; [ -n "${REMOTE_DIR:-}" ] || m="$m REMOTE_DIR"; echo "$m"' _ "$ENV_FILE")" \
  || die 2 "$bad_env"
[ -z "$missing" ] || die 2 "$ENV_FILE must define:$missing"

if [ "$DRY" -eq 1 ]; then
  echo "install-backup-agent: would write $PLIST (daily 03:30, runs $PULL_SCRIPT with settings $ENV_FILE, log $LOG)"
  echo "install-backup-agent: would load $LABEL: launchctl bootout, wait until it is gone, launchctl bootstrap $DOMAIN"
  exit 0
fi

mkdir -p "$LAUNCHAGENTS_DIR" "$LOG_DIR" || die 1 "cannot create $LAUNCHAGENTS_DIR or $LOG_DIR"

# The command is bash -c '<script>' name ENV_FILE PULL_SCRIPT, so no path is ever re-parsed by a shell.
cat > "$PLIST" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>set -a; . "\$1"; set +a; exec "\$2"</string>
    <string>app-backup-pull</string>
    <string>$(xml "$ENV_FILE")</string>
    <string>$(xml "$PULL_SCRIPT")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key>
  <string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$LOG")</string>
</dict>
</plist>
EOP

# Replace, never duplicate: unload any old copy first (fails harmlessly when none is loaded).
"$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
wait_unloaded
attempt=0
while :; do
  attempt=$((attempt + 1))
  bs_out="$("$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>&1)" && break
  bs_rc=$?
  [ -z "$bs_out" ] || echo "$bs_out" >&2
  case "$bs_out" in *"Input/output error"*) ;; *) [ "$bs_rc" -eq 5 ] || die 1 "launchctl bootstrap failed for $PLIST; see $LOG" ;; esac
  [ "$attempt" -lt 3 ] || die 1 "launchctl bootstrap failed for $PLIST after $attempt attempts (I/O error); see $LOG"
  sleep 0.5
done
"$LAUNCHCTL" list "$LABEL" >/dev/null 2>&1 || die 1 "agent $LABEL is not loaded after install; see $LOG"

echo "install-backup-agent: installed $LABEL (daily 03:30, settings $ENV_FILE, log $LOG)"
