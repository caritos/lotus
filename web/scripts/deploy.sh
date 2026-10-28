#!/usr/bin/env bash
# Build the binary here, upload it to the server over SSH and switch to it, with a
# health check and an automatic rollback when that is safe.
#
#   deploy.sh <user@host> [--check]
#
# --check runs only the preflight (SSH login, linger, tools, server layout) and
# changes nothing.
#
# Server layout, relative to the deploy user's $HOME (base dir REMOTE_BASE, default app):
#   releases/<version>/app   the binary of each release
#   current                    symlink to the active release
#   data/                      the app's DATA_DIR (db/, logs/, storage/, backups/)
#   .env                       the server's runtime config; never uploaded, never printed
#   restore.sh                 copy of web/scripts/restore.sh, refreshed on every deploy
#
# Steps: preflight; resolve APP_ENV, DATA_DIR and the app port from the server's .env
# the way the service does (refusing unless APP_ENV=production); build (pnpm build,
# then a static linux/amd64 go build); take a deploy lock on the server
# (REMOTE_BASE/.deploy.lock, stale after 30 minutes; a second deploy fails fast);
# take a pre-deploy backup with the running release (a separate "predeploy" labeled
# set, 5 kept, which never prunes the daily sets); upload to
# releases/<version>.uploading, verify the sha256 on the server, rename into
# place; atomically repoint `current`; restart the unit; poll /healthz on the
# server's loopback until it reports the new version; prune old releases; run
# smoke.sh against PUBLIC_URL when it is set (with EXPECTED_BUILD_ID, so the page footers and
# /healthz must show the id this deploy built; see web/scripts/build-id.sh).
#
# If the new release is not healthy: when it carries no migration (the highest
# migration file is the same as in the previous release) `current` is switched
# back automatically. When it does carry a migration the binary is NOT rolled
# back (the previous binary may not work against the migrated schema); the exact
# restore commands are printed instead.
#
# Environment:
#   SSH, RSYNC        binaries to use, default ssh and rsync
#   SSH_KEY           optional identity file passed with -i
#   REMOTE_BASE       base directory on the server, default app (relative to $HOME)
#   SERVICE           systemd user unit, default app
#   HEALTH_PORT       port of the app on the server; default: the port in ADDR of the
#                     server's .env, else 8080
#   HEALTH_TIMEOUT    seconds to wait for health, default 20
#   HEALTH_RECHECK_DELAY  seconds before the second health probe that catches a flap, default 3
#
# DATA_DIR is resolved exactly like the service: a DATA_DIR in the server's .env
# (systemd lets EnvironmentFile override Environment=) wins, a relative value is
# relative to the unit's WorkingDirectory (REMOTE_BASE/data), otherwise REMOTE_BASE/data.
#   VERSION           release name, default `git describe --tags --always --dirty`
#   GOOS, GOARCH      default linux and amd64
#   SKIP_WEB_BUILD=1  do not run `pnpm build` (the embedded app must already exist); also
#                     skips the Node version check
#   SKIP_TESTS=1      skip the test gate only (the Node check below still runs). Otherwise, after the preflight and before anything
#                     changes on the server (not in --check), deploy runs `go vet ./...` and
#                     `go test -short ./...` in web/api and `pnpm test` and `pnpm typecheck`
#                     in web/, and stops on the first failure. The Go tests run WITHOUT -race on
#                     purpose: the gate must stay quick enough to run on every deploy; the full
#                     tier with -race is `make test` and CI
#   Dependencies      unless both SKIP_TESTS=1 and SKIP_WEB_BUILD=1, `pnpm install --frozen-lockfile`
#                     runs in web/ before the gate and the build (not in --check); a failure
#                     stops the deploy with nothing changed
#   Node check        unless SKIP_WEB_BUILD=1, the major version in web/.nvmrc (v24, 24, 24.1.0 and v24.18.0 all mean 24) must equal `node -v`'s major, or
#                     the deploy stops early. A non-numeric value such as lts/* prints "cannot
#                     compare" and skips the check. SKIP_TESTS does not skip it
#   REQUIRE_BACKUP_TIMER=1  refuse to deploy (nothing changed) when `${SERVICE}-backup.timer`
#                     is not enabled on the server, or when that cannot be determined (ssh or
#                     user-bus failure); without it either case only prints a warning.
#                     The preflight, and so --check, checks the timer either way
#   EMBED_INDEX       the built app's index.html, default web/api/internal/web/app/index.html
#   KEEP_OLD          releases kept besides the active and previous one, default 3
#   PUBLIC_URL        e.g. https://app.example.com; when set, smoke.sh runs at the end
#   EXPECT_PUBLIC_LISTENER=1  for servers behind a reverse proxy that reaches the app on the
#                     host's public address (a loopback-only listener then fails publicly
#                     with a 502 while local checks pass): refuse a loopback ADDR in the
#                     server's .env before anything changes, and after the restart require
#                     a public listener (0.0.0.0, * or [::]) on the app port. Default 0.
#   ALLOW_DEV_DEPLOY=1  deploy even though the server .env does not say APP_ENV=production
#                     (prints a warning); without it such a deploy stops with nothing changed
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SSH="${SSH:-ssh}"
RSYNC="${RSYNC:-rsync}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_BASE="${REMOTE_BASE:-app}"
SERVICE="${SERVICE:-app}"
HEALTH_PORT="${HEALTH_PORT:-}"
HEALTH_RECHECK_DELAY="${HEALTH_RECHECK_DELAY:-3}"
LOCK_STALE_SECONDS=1800
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-20}"
KEEP_OLD="${KEEP_OLD:-3}"
PUBLIC_URL="${PUBLIC_URL:-}"
EMBED_INDEX="${EMBED_INDEX:-$REPO_ROOT/web/api/internal/web/app/index.html}"

die() { echo "deploy: $*" >&2; exit 1; }
step() { echo "deploy: $*"; }

# ---------------------------------------------------------------- arguments
TARGET=""
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    *) if [ -z "$TARGET" ]; then TARGET="$arg"; else die "unexpected argument '$arg'"; fi ;;
  esac
done
[ -n "$TARGET" ] || die "usage: deploy.sh <user@host> [--check]"
case "$TARGET" in -*) die "invalid target '$TARGET': must not start with '-'" ;; esac
case "$TARGET" in *[!A-Za-z0-9._@-]*) die "invalid target '$TARGET': only letters, digits and . _ @ - are allowed (no ':' or '/')" ;; esac
HOST="${TARGET#*@}"
[ -n "$HOST" ] && [ "${HOST#-}" = "$HOST" ] || die "invalid host in '$TARGET'"

case "$REMOTE_BASE" in
  ""|/*|-*|.*|*..*|*/.*|*//*|*/) die "REMOTE_BASE must be a relative path without '..', no component starting with '.', not starting with '-' (got '$REMOTE_BASE')" ;;
esac
case "$REMOTE_BASE" in *[!A-Za-z0-9._/-]*) die "REMOTE_BASE has characters outside A-Za-z0-9._/-" ;; esac
case "$SERVICE" in ""|*[!A-Za-z0-9._@-]*) die "invalid SERVICE '$SERVICE'" ;; esac
case "$HEALTH_PORT" in *[!0-9]*) die "HEALTH_PORT must be a number" ;; esac
case "$HEALTH_RECHECK_DELAY" in ""|*[!0-9]*) die "HEALTH_RECHECK_DELAY must be a number" ;; esac
case "$HEALTH_TIMEOUT" in ""|*[!0-9]*) die "HEALTH_TIMEOUT must be a number" ;; esac
case "$KEEP_OLD" in ""|*[!0-9]*) die "KEEP_OLD must be a number" ;; esac
case "$SSH_KEY" in *\'*|*\"*) die "SSH_KEY must not contain quotes" ;; esac

B="$REMOTE_BASE"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
if [ -n "$SSH_KEY" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi
SSH_E="$SSH ${SSH_OPTS[*]}"
if [ -n "$SSH_KEY" ]; then SSH_E="$SSH -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -i '$SSH_KEY'"; fi

# rsh '<command>': run one command string on the server.
rsh() { "$SSH" "${SSH_OPTS[@]}" "$TARGET" "$1"; }

# Cleanup (best effort): release the server lock if we hold it, drop the temp dir.
TMP=""
HAVE_LOCK=0
LOCK_TOKEN="$$.$RANDOM"
release_lock() {
  [ "$HAVE_LOCK" -eq 1 ] || return 0
  HAVE_LOCK=0
  "$SSH" "${SSH_OPTS[@]}" "$TARGET" "cd '$B' && [ \"\$(cut -d' ' -f1 .deploy.lock/owner 2>/dev/null)\" = '$LOCK_TOKEN' ] && rm -rf .deploy.lock" >/dev/null 2>&1 || true
}
cleanup() {
  release_lock
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------------------------------------------------------------- preflight
sha_local() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

preflight() {
  step "preflight: local tools"
  command -v go >/dev/null 2>&1 || die "go is required but was not found"
  command -v "$RSYNC" >/dev/null 2>&1 || die "$RSYNC is required but was not found"
  command -v "$SSH" >/dev/null 2>&1 || die "$SSH is required but was not found"
  if [ "${SKIP_WEB_BUILD:-0}" != 1 ]; then
    command -v pnpm >/dev/null 2>&1 || die "pnpm is required to build the web app (or set SKIP_WEB_BUILD=1 if it is already built)"
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die "a sha256 tool (sha256sum or shasum) is required"
  fi

  step "preflight: ssh login to $TARGET"
  rsh 'whoami' >/dev/null 2>&1 || die "cannot log in to $TARGET with key authentication (BatchMode). Check the host, user and SSH key (SSH_KEY), and that the user has a real shell."

  step "preflight: linger"
  local linger
  linger="$(rsh 'loginctl show-user "$(id -un)" --property=Linger' 2>/dev/null || true)"
  if [ "$linger" != "Linger=yes" ]; then
    die "user services stop when the SSH session ends unless linger is on (got '${linger:-nothing}'). Fix it once on the server: loginctl enable-linger   (then check: loginctl show-user \$(id -un) --property=Linger). The deploy never enables it silently."
  fi

  step "preflight: server layout"
  rsh "test -d '$B/data' || exit 11; test -f '$B/.env' || exit 12; systemctl --user cat '$SERVICE' >/dev/null 2>&1 || exit 13; command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || exit 14; command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || exit 15" \
    && rc=0 || rc=$?
  case "$rc" in
    0) ;;
    11) die "missing \$HOME/$B/data on the server; see web/docs/deploy.md (prepare the server)" ;;
    12) die "missing \$HOME/$B/.env on the server (it is never uploaded); create it from web/deploy/.env.example, see web/docs/deploy.md" ;;
    13) die "systemd user unit '$SERVICE' is not installed on the server, or 'systemctl --user' cannot reach the user manager: install web/deploy/app.service (see web/docs/deploy.md). If it is installed, a non-interactive SSH session may lack XDG_RUNTIME_DIR for the user bus; check on the server with: loginctl show-user \$(id -un)   (Linger=yes, State=active or lingering) and: systemctl --user status   (it must not say 'Failed to connect to bus')" ;;
    14) die "neither curl nor wget is available on the server (needed for the health check)" ;;
    15) die "no sha256sum or shasum on the server" ;;
    *) die "server layout check failed (exit $rc)" ;;
  esac

  step "preflight: backup timer"
  # Three outcomes. Enabled: exit 0 AND the answer is enabled or enabled-runtime. Not enabled: exit 1 or
  # 4 with a systemd state word (disabled, masked, static, not-found for a unit that was never installed,
  # ...), older systemd's "Failed to get unit file state ...: No such file or directory" (exit 1, a missing
  # unit), or exit 0 with a state word that is not enabled (static, indirect, generated: nothing starts
  # the timer). Could not determine: ssh exit 255, a user-bus error or any other "Failed to ...", empty or
  # unrecognized output, any other exit.
  local tout trc tlast known tstate=""
  tout="$(rsh "systemctl --user is-enabled '$SERVICE-backup.timer'" 2>&1)" && trc=0 || trc=$?
  tlast="$(printf '%s\n' "$tout" | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '[:space:]')"
  # Explicit word list (no character ranges: they behave differently across locales and bash 3.2).
  case "$tlast" in
    enabled|enabled-runtime|static|indirect|generated|disabled|masked|masked-runtime|linked|linked-runtime|alias|transient|bad|not-found) known=1 ;;
    *) known=0 ;;
  esac
  case "$trc:$tlast" in
    0:enabled|0:enabled-runtime) trc=0 ;;
    0:*) if [ "$known" -eq 1 ]; then tstate="$tlast"; trc=1; else trc=255; fi ;;
    1:Failedtogetunitfilestate*Nosuchfileordirectory) tstate="not-found"; trc=1 ;;
    1:*|4:*) if [ "$known" -eq 1 ] && [ "$tlast" != enabled ] && [ "$tlast" != enabled-runtime ]; then tstate="$tlast"; trc=1; else trc=255; fi ;;
    *) trc=255 ;;
  esac
  [ -z "$tstate" ] || tstate=" (state: $tstate)"
  if [ "$trc" -eq 1 ]; then
    if [ "${REQUIRE_BACKUP_TIMER:-0}" = 1 ]; then
      die "the daily backup timer '$SERVICE-backup.timer' is not enabled (or not installed) on the server$tstate (REQUIRE_BACKUP_TIMER=1). Install the units from web/deploy/ if needed, then enable it with: systemctl --user enable --now $SERVICE-backup.timer   (install steps: web/docs/deploy.md, section 3). Nothing was changed."
    fi
    echo "deploy: WARNING: the daily backup timer '$SERVICE-backup.timer' is not enabled (or not installed) on the server$tstate, so no daily backups run. Install the units from web/deploy/ if needed, then enable it with: systemctl --user enable --now $SERVICE-backup.timer   (see web/docs/deploy.md, section 3). Set REQUIRE_BACKUP_TIMER=1 to refuse such a deploy." >&2
  elif [ "$trc" -ne 0 ]; then
    if [ "${REQUIRE_BACKUP_TIMER:-0}" = 1 ]; then
      die "could not determine whether the backup timer is enabled (ssh or user bus failed) (REQUIRE_BACKUP_TIMER=1). Check the connection and 'systemctl --user status' on the server, then deploy again. Nothing was changed."
    fi
    echo "deploy: WARNING: could not determine whether the backup timer is enabled (ssh or user bus failed), so daily backups are unverified. Set REQUIRE_BACKUP_TIMER=1 to refuse such a deploy." >&2
  fi
}

VERSION="${VERSION:-$(cd "$REPO_ROOT" && git describe --tags --always --dirty 2>/dev/null || echo dev)}"
case "$VERSION" in ""|.|..|-*|.*|*..*|*[!A-Za-z0-9._-]*) die "invalid VERSION '$VERSION' (letters, digits, . _ - only; no '..', not starting with '.' or '-')" ;; esac
COMMIT="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# YYYYMMDD-<short commit> (UTC date; "-dirty" for uncommitted changes), computed once: it goes
# into the binary's ldflags and is what smoke.sh must then find on the public site.
BUILD_ID="$(bash "$SCRIPT_DIR/build-id.sh" 2>/dev/null)" || BUILD_ID=""
case "$BUILD_ID" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-?*) ;; *) die "web/scripts/build-id.sh did not print a build id (got '$BUILD_ID')" ;; esac

preflight

# Resolve APP_ENV, DATA_DIR and ADDR from the server's .env the way the service sees
# them (the last assignment wins, as in systemd). Read-only, so it runs before the lock
# and also in --check.
IFS= read -r -d '' RESOLVE_SCRIPT <<'EOS' || true
cd '__B__' || exit 20
dv=; av=; ev=
CR=$(printf '\r'); Q=$(printf '\047')
while IFS= read -r l || [ -n "$l" ]; do
  case "$l" in
    DATA_DIR=*) k=DATA_DIR; v="${l#DATA_DIR=}" ;;
    ADDR=*) k=ADDR; v="${l#ADDR=}" ;;
    APP_ENV=*) k=APP_ENV; v="${l#APP_ENV=}" ;;
    *) continue ;;
  esac
  case "$v" in
    *'"'*|*"$Q"*|*"$CR"*|*' '*|*'$'*|*'`'*|*'\'*) echo "$k"; exit 21 ;;
  esac
  case "$k" in DATA_DIR) dv="$v" ;; ADDR) av="$v" ;; APP_ENV) ev="$v" ;; esac
done < .env
case "$dv" in "") dd="$PWD/data" ;; /*) dd="$dv" ;; *) dd="$PWD/data/$dv" ;; esac
echo "DATA_DIR=$dd"
echo "ADDR=$av"
echo "APP_ENV=$ev"
EOS
RES="$(rsh "${RESOLVE_SCRIPT//__B__/$B}")" && rc=0 || rc=$?
case "$rc" in
  0) ;;
  21) die "the server .env line for $RES contains quotes, spaces, a carriage return or shell characters; systemd and this script would read it differently. Write KEY=value plainly, with no quotes. Nothing was changed." ;;
  *) die "cannot read the server .env (exit $rc)" ;;
esac
DD="$(printf '%s\n' "$RES" | sed -n 's/^DATA_DIR=//p')"
ADDR_V="$(printf '%s\n' "$RES" | sed -n 's/^ADDR=//p')"
APP_ENV_V="$(printf '%s\n' "$RES" | sed -n 's/^APP_ENV=//p')"
if [ "$APP_ENV_V" != production ]; then
  if [ -z "$APP_ENV_V" ]; then
    why="the server .env does not set APP_ENV, so the app would run in development mode (its default)"
  else
    why="the server .env sets APP_ENV=$APP_ENV_V"
  fi
  if [ "${ALLOW_DEV_DEPLOY:-0}" = 1 ]; then
    echo "deploy: WARNING: $why. Development mode signs sessions with a built-in key when SESSION_SECRET is empty and does not mark cookies Secure. Continuing only because ALLOW_DEV_DEPLOY=1 is set." >&2
  else
    die "$why. A server must run with APP_ENV=production (it then refuses to start without SESSION_SECRET and PUBLIC_ORIGIN). Fix ~/$B/.env, or set ALLOW_DEV_DEPLOY=1 locally to deploy a development server on purpose. Nothing was changed."
  fi
fi
case "$DD" in ""|*[!A-Za-z0-9._/-]*) die "the resolved DATA_DIR '$DD' is empty or has characters outside A-Za-z0-9._/-" ;; esac
if [ -z "$HEALTH_PORT" ]; then
  HEALTH_PORT="${ADDR_V##*:}"
  case "$HEALTH_PORT" in ""|*[!0-9]*) HEALTH_PORT=8080 ;; esac
fi
step "DATA_DIR on the server resolves to $DD; health port $HEALTH_PORT"

EXPECT_PUBLIC_LISTENER="${EXPECT_PUBLIC_LISTENER:-0}"
case "$EXPECT_PUBLIC_LISTENER" in 0|1) ;; *) die "EXPECT_PUBLIC_LISTENER must be 0 or 1" ;; esac

# listener_is_public <local-address-field of ss -H -ltn>: 0.0.0.0:P, *:P and [::]:P are
# public; 127.0.0.1:P, [::1]:P and anything else are not.
listener_is_public() {
  case "$1" in 0.0.0.0:*|\*:*|\[::\]:*) return 0 ;; *) return 1 ;; esac
}

# check_port_owner: refuse when something is already listening on the app port unless it
# is our own service: the unit must be active AND `ss -p` must show a process for that
# listener (ss -p lists only the caller's own processes, so a stranger's listener has no
# users:(...) field). Remaining limit: another process of the same user on that port, or a
# stranger's listener while our unit runs on a different port, cannot be told apart from
# a stale view of ours; the hint in the message says how to look.
check_port_owner() {
  local out lines
  out="$(rsh "ss -H -ltnp" 2>/dev/null)" || { echo "deploy: warning: ss is not available on the server, so the port $HEALTH_PORT owner check was skipped" >&2; return 0; }
  lines="$(printf '%s\n' "$out" | awk -v p=":$HEALTH_PORT" 'substr($4, length($4)-length(p)+1) == p')"
  [ -n "$lines" ] || return 0
  if [ "$(rsh "systemctl --user is-active '$SERVICE'" 2>/dev/null || true)" = active ] && printf '%s\n' "$lines" | grep -q 'users:'; then
    return 0
  fi
  die "port $HEALTH_PORT is already in use on the server and $SERVICE is not the active service listening on it. Find the owner with: ss -ltnp | grep :$HEALTH_PORT, or ps aux (on a shared host the owner may be another user, whose process ss -p does not show). Then pick a free port (ADDR in ~/$B/.env, or HEALTH_PORT) or stop the other listener. Nothing was changed."
}
check_port_owner

if [ "$EXPECT_PUBLIC_LISTENER" -eq 1 ]; then
  case "${ADDR_V%:*}" in
    127.0.0.1|::1|\[::1\]|localhost) die "EXPECT_PUBLIC_LISTENER=1 but the server .env has ADDR=$ADDR_V, which listens on loopback only. Set ADDR=0.0.0.0:$HEALTH_PORT in ~/$B/.env. Nothing was changed." ;;
  esac
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "${SKIP_WEB_BUILD:-0}" = 1 ] && [ ! -f "$EMBED_INDEX" ]; then
    die "the web app is not built ($EMBED_INDEX is missing); run pnpm build in web/"
  fi
  echo "deploy: preflight OK (nothing was changed)"
  exit 0
fi

# ---------------------------------------------------------------- test gate
# Nothing has changed on the server yet; refuse to ship code that does not pass its tests.
if [ "${SKIP_WEB_BUILD:-0}" != 1 ]; then
  NVMRC=""
  for f in "$REPO_ROOT/web/.nvmrc"; do
    if [ -f "$f" ]; then NVMRC="$f"; break; fi
  done
  if [ -n "$NVMRC" ]; then
    raw="$(tr -d ' \r\n' < "$NVMRC")"
    want="${raw#v}"; want="${want%%.*}"
    case "$want" in
      ""|*[!0-9]*)
        echo "deploy: cannot compare .nvmrc value '$raw' with the local Node; skipping the Node check" >&2 ;;
      *)
        have="$(node -v 2>/dev/null || true)"
        got="${have#v}"; got="${got%%.*}"
        [ -n "$got" ] || die "node is required to build the web app but 'node -v' printed nothing"
        [ "$got" = "$want" ] || die "Node $want is required (${NVMRC#"$REPO_ROOT"/}) but node -v says ${have:-nothing}. Switch with: nvm use. Nothing was changed." ;;
    esac
  fi
fi

# Dependencies: the gate and the build must run against node_modules that match pnpm-lock.yaml, not
# whatever an earlier checkout left behind. Skipped only when neither the gate nor the build runs.
if [ "${SKIP_TESTS:-0}" != 1 ] || [ "${SKIP_WEB_BUILD:-0}" != 1 ]; then
  command -v pnpm >/dev/null 2>&1 || die "pnpm is required to install the web dependencies (or set SKIP_TESTS=1 and SKIP_WEB_BUILD=1)"
  step "installing web dependencies (pnpm install --frozen-lockfile)"
  (cd "$REPO_ROOT/web" && pnpm install --frozen-lockfile) >&2 || die "pnpm install --frozen-lockfile failed (the lockfile and package.json disagree, or the registry is unreachable). Nothing was changed."
fi

if [ "${SKIP_TESTS:-0}" != 1 ]; then
  step "test gate: go vet, go test -short, pnpm test, pnpm typecheck (SKIP_TESTS=1 skips the tests)"
  # The caller's GOOS/GOARCH (say, linux exported on a Mac) must not reach the gate: the test
  # binaries have to run here. The release build below keeps its own target.
  (cd "$REPO_ROOT/web/api" && env -u GOOS -u GOARCH go vet ./...) >&2 || die "go vet failed; nothing was changed (SKIP_TESTS=1 skips the test gate)"
  (cd "$REPO_ROOT/web/api" && env -u GOOS -u GOARCH go test -short ./...) >&2 || die "go test failed; nothing was changed (SKIP_TESTS=1 skips the test gate)"
  (cd "$REPO_ROOT/web" && pnpm test) >&2 || die "pnpm test failed; nothing was changed (SKIP_TESTS=1 skips the test gate)"
  (cd "$REPO_ROOT/web" && pnpm typecheck) >&2 || die "pnpm typecheck failed; nothing was changed (SKIP_TESTS=1 skips the test gate)"
fi

# ---------------------------------------------------------------- build
TMP="$(mktemp -d)"

if [ "${SKIP_WEB_BUILD:-0}" != 1 ]; then
  step "building the web app (pnpm build)"
  (cd "$REPO_ROOT/web" && pnpm build) >&2 || die "pnpm build failed"
fi
[ -f "$EMBED_INDEX" ] || die "the web app is not built ($EMBED_INDEX is missing); run pnpm build in web/"

step "building app $VERSION ($COMMIT), build id $BUILD_ID, for ${GOOS:-linux}/${GOARCH:-amd64}"
(cd "$REPO_ROOT/web/api" && GOOS="${GOOS:-linux}" GOARCH="${GOARCH:-amd64}" CGO_ENABLED=0 go build \
  -ldflags "-s -w -X app/internal/version.Version=$VERSION -X app/internal/version.Commit=$COMMIT -X app/internal/version.BuildID=$BUILD_ID" \
  -o "$TMP/app" ./cmd/app) >&2 || die "go build failed"
LOCAL_SUM="$(sha_local "$TMP/app")"

# ---------------------------------------------------------------- lock
WHO="$(id -un 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')@$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
IFS= read -r -d '' LOCK_SCRIPT <<'EOS' || true
cd '__B__' || exit 20
now=$(date -u +%s)
write_owner() { echo "__TOKEN__ __WHO__ $now" > .deploy.lock/owner; }
if mkdir .deploy.lock 2>/dev/null; then write_owner; echo ACQUIRED; exit 0; fi
o=$(cat .deploy.lock/owner 2>/dev/null)
if [ -z "$o" ]; then sleep 1; o=$(cat .deploy.lock/owner 2>/dev/null); fi
ts=${o##* }; who=${o#* }; who=${who% *}; tok=${o%% *}
case "$ts" in ""|*[!0-9]*) ts=0 ;; esac
age=$((now - ts))
since=$(date -u -d "@$ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "epoch $ts")
if [ "$ts" -gt 0 ] && [ "$age" -le __STALE__ ]; then echo "HELD by $who since $since (${age}s ago)"; exit 10; fi
g=".deploy.lock.stale.$$"
if mv .deploy.lock "$g" 2>/dev/null; then
  if [ "$(cut -d' ' -f1 "$g/owner" 2>/dev/null)" != "$tok" ]; then
    mv "$g" .deploy.lock 2>/dev/null
    echo "HELD by another deploy that took the lock first"; exit 10
  fi
  rm -rf "$g"
else
  echo "HELD by another deploy that took the lock first"; exit 10
fi
if mkdir .deploy.lock 2>/dev/null; then write_owner; echo "STALE lock held by $who since $since (${age}s ago)"; echo ACQUIRED; exit 0; fi
echo "HELD by another deploy that took the lock first"; exit 10
EOS
acquire_lock() {
  local s="${LOCK_SCRIPT//__B__/$B}" out rc
  s="${s//__TOKEN__/$LOCK_TOKEN}"; s="${s//__WHO__/$WHO}"; s="${s//__STALE__/$LOCK_STALE_SECONDS}"
  out="$(rsh "$s")" && rc=0 || rc=$?
  case "$rc" in
    0) HAVE_LOCK=1
       case "$out" in *STALE*) step "took over a stale deploy lock: $(printf '%s' "$out" | sed -n 's/^STALE //p')" ;; esac ;;
    10) die "another deploy holds the lock on the server ($(printf '%s' "$out" | sed -n 's/^HELD //p')). Nothing was changed. If it died, the lock is taken over automatically after $((LOCK_STALE_SECONDS / 60)) minutes." ;;
    *) die "cannot take the deploy lock on the server (exit $rc)" ;;
  esac
}
step "taking the deploy lock"
acquire_lock

# ---------------------------------------------------------------- server state
ACTIVE="$(rsh "readlink '$B/current' 2>/dev/null || true")"
ACTIVE="${ACTIVE##*/}"
case "$ACTIVE" in *[!A-Za-z0-9._-]*) die "unexpected 'current' link target '$ACTIVE' on the server" ;; esac
if [ -n "$ACTIVE" ]; then
  step "active release on the server: $ACTIVE"
else
  step "first deploy: no active release on the server, so there is no rollback target"
fi
[ "$ACTIVE" != "$VERSION" ] || die "$VERSION is already the active release; bump the version (commit, tag, or set VERSION) and deploy again"


# Load the server's .env for the backup command without printing it.
LOAD_ENV='while IFS= read -r l || [ -n "$l" ]; do case "$l" in ""|"#"*) continue ;; esac; k="${l%%=*}"; v="${l#*=}"; case "$k" in *[!A-Za-z0-9_]*|"") continue ;; esac; export "$k=$v"; done < .env'

BACKUP_DIR=""
if [ -n "$ACTIVE" ]; then
  rsh "test -d '$DD' && test -f '$DD/db/app.db'" || die "the resolved DATA_DIR $DD is not a directory containing db/app.db. Check DATA_DIR in the server .env: the service would not be serving this data. Nothing was changed."
  step "taking a pre-deploy backup with $ACTIVE into $DD/backups (a <timestamp>-predeploy set; the 5 newest pre-deploy sets are kept, daily sets are not touched)"
  BACKUP_DIR="$(rsh "cd '$B' && $LOAD_ENV; export DATA_DIR='$DD'; out=\$(./current/app backup --label predeploy --keep 5) || exit 1; d=\$(printf '%s\n' \"\$out\" | tail -n 1); [ -n \"\$d\" ] && [ -d \"\$d\" ] || exit 2; printf '%s\n' \"\$d\"")" \
    || die "pre-deploy backup failed; nothing was changed"
  [ -n "$BACKUP_DIR" ] || die "pre-deploy backup printed no directory; nothing was changed"
  step "backup written to $BACKUP_DIR"
fi

# ---------------------------------------------------------------- upload
step "uploading to releases/$VERSION.uploading"
rsh "mkdir -p '$B/releases' && rm -rf '$B/releases/$VERSION.uploading' && mkdir '$B/releases/$VERSION.uploading'" || die "cannot create the upload directory"
"$RSYNC" -a --timeout=60 -e "$SSH_E" "$TMP/app" "$TARGET:$B/releases/$VERSION.uploading/app" >/dev/null || die "upload failed; nothing was changed"
"$RSYNC" -a --timeout=60 -e "$SSH_E" "$SCRIPT_DIR/restore.sh" "$TARGET:$B/restore.sh" >/dev/null || die "upload of restore.sh failed; nothing was changed"

REMOTE_SUM="$(rsh "f='$B/releases/$VERSION.uploading/app'; if command -v sha256sum >/dev/null 2>&1; then sha256sum \"\$f\"; else shasum -a 256 \"\$f\"; fi | cut -d' ' -f1")" || REMOTE_SUM=""
if [ "$REMOTE_SUM" != "$LOCAL_SUM" ]; then
  rsh "rm -rf '$B/releases/$VERSION.uploading'" || true
  die "checksum mismatch after upload (local $LOCAL_SUM, server ${REMOTE_SUM:-unreadable}); aborted before switching, nothing changed"
fi
step "checksum verified"
rsh "cd '$B/releases' && chmod 755 '$VERSION.uploading/app' && rm -rf '$VERSION' && mv '$VERSION.uploading' '$VERSION'" || die "cannot move the upload into place"

# Schema versions decide whether an automatic rollback is safe.
NEW_SCHEMA="$(rsh "'$B/releases/$VERSION/app' schema-version" 2>/dev/null)" || die "the uploaded binary does not run on the server (schema-version failed); nothing was switched"
PREV_SCHEMA=""
if [ -n "$ACTIVE" ]; then
  PREV_SCHEMA="$(rsh "'$B/releases/$ACTIVE/app' schema-version" 2>/dev/null || echo unknown)"
  [ -n "$PREV_SCHEMA" ] || PREV_SCHEMA=unknown
fi

# ---------------------------------------------------------------- switch
# switch_to <release>: repoint `current` atomically (rename over the link) where
# the server's mv supports -T, otherwise fall back to ln -sfn.
switch_to() {
  rsh "cd '$B' && ln -sfn 'releases/$1' current.new && if mv --version 2>/dev/null | grep -q GNU; then mv -T current.new current; else echo 'deploy: note: mv -T is not available on the server; using ln -sfn (not atomic)' >&2; ln -sfn 'releases/$1' current; rm -f current.new; fi"
}

# wait_healthy <version>: poll the app on the server's loopback until it reports
# status ok and exactly this version, for up to HEALTH_TIMEOUT real seconds (measured
# with the clock, not by counting probes); a second probe after HEALTH_RECHECK_DELAY
# seconds catches a service that comes up and falls over again.
IFS= read -r -d '' HEALTH_SCRIPT <<'EOS' || true
start=$(date +%s)
probe() {
  url="http://127.0.0.1:__PORT__/healthz"
  if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 2 "$url" 2>/dev/null; else wget -qO- -T 2 "$url" 2>/dev/null; fi
}
healthy() {
  b="$(probe)" || return 1
  printf '%s' "$b" | grep -Eq '"status" *: *"ok"' || return 1
  v="$(printf '%s' "$b" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
  [ "$v" = '__VER__' ]
}
while :; do
  if healthy; then
    sleep __RECHECK__
    if healthy; then exit 0; fi
    exit 2
  fi
  now=$(date +%s)
  if [ $((now - start)) -ge __TO__ ]; then exit 1; fi
  sleep 1
done
EOS
wait_healthy() {
  local s="${HEALTH_SCRIPT//__PORT__/$HEALTH_PORT}"
  s="${s//__VER__/$1}"; s="${s//__TO__/$HEALTH_TIMEOUT}"; s="${s//__RECHECK__/$HEALTH_RECHECK_DELAY}"
  rsh "$s"
}

step "switching current to $VERSION"
switch_to "$VERSION" || die "cannot switch the current link"
step "restarting $SERVICE"
rsh "systemctl --user restart '$SERVICE'" || echo "deploy: warning: systemctl restart reported an error" >&2

step "waiting for /healthz to report $VERSION (up to ${HEALTH_TIMEOUT}s)"
if ! wait_healthy "$VERSION"; then
  echo "deploy: the new release did not become healthy (or became unhealthy again within ${HEALTH_RECHECK_DELAY}s)" >&2
  echo "deploy: look at: journalctl --user -u $SERVICE  (a migration may still be running or may have failed; read the log before you restore anything)" >&2
  if [ -z "$ACTIVE" ]; then
    echo "deploy: no previous release exists, so there is nothing to roll back to. Look at the service log: journalctl --user -u $SERVICE, and \$HOME/$B/data/logs/." >&2
    exit 1
  fi
  if [ "$NEW_SCHEMA" = "$PREV_SCHEMA" ]; then
    echo "deploy: no migration in this release (schema $NEW_SCHEMA); switching back to $ACTIVE" >&2
    switch_to "$ACTIVE" || die "rollback failed: cannot switch current back to $ACTIVE"
    rsh "systemctl --user reset-failed '$SERVICE'" >/dev/null 2>&1 || true
    rsh "systemctl --user restart '$SERVICE'" || true
    if wait_healthy "$ACTIVE"; then
      echo "deploy: rolled back automatically to $ACTIVE and it is healthy; $VERSION is left in releases/ for inspection" >&2
    else
      echo "deploy: rolled back automatically to $ACTIVE but it is NOT healthy either; investigate the server now" >&2
    fi
    exit 1
  fi
  echo "deploy: this release carries a migration (schema $PREV_SCHEMA -> $NEW_SCHEMA), so the binary was NOT rolled back: the previous binary may not work against the migrated schema." >&2
  echo "deploy: to go back, restore the pre-deploy backup with the previous release. On the server:" >&2
  echo "  cd \$HOME/$B && ln -sfn releases/$ACTIVE current && DATA_DIR=$DD APP_BIN=\$HOME/$B/releases/$ACTIVE/app SERVICE=$SERVICE PORT=$HEALTH_PORT bash restore.sh $BACKUP_DIR" >&2
  echo "deploy: (run restore.sh --drill first if you want to rehearse; see web/docs/backups.md)" >&2
  exit 1
fi
step "healthy: $VERSION is serving"

if [ "$EXPECT_PUBLIC_LISTENER" -eq 1 ]; then
  public=0
  sout="$(rsh "ss -H -ltn" 2>&1)" && src=0 || src=$?
  if [ "$src" -ne 0 ]; then
    if [ "$src" -eq 255 ]; then
      echo "deploy: $VERSION is healthy on loopback, but could not run ss on the server to check the public listener (exit 255: the ssh connection failed, or an old ss without -H rejected the option). Check the connection and run: ss -ltn | grep :$HEALTH_PORT   The release was not rolled back." >&2
    else
      echo "deploy: $VERSION is healthy on loopback, but ss is not available on the server, so the public listener on port $HEALTH_PORT could not be checked (ss exit $src). Install ss (iproute2) or check by hand; the proxy needs a listener on 0.0.0.0:$HEALTH_PORT. The release was not rolled back." >&2
    fi
    exit 1
  fi
  while read -r addr; do
    if listener_is_public "$addr"; then public=1; fi
  done < <(printf '%s\n' "$sout" | awk '{print $4}' | grep ":$HEALTH_PORT\$" || true)
  if [ "$public" -ne 1 ]; then
    echo "deploy: $VERSION is healthy on loopback but nothing listens on a public address on port $HEALTH_PORT, so the reverse proxy cannot reach it (it would answer 502). Set ADDR=0.0.0.0:$HEALTH_PORT in ~/$B/.env and restart $SERVICE. The release was not rolled back: the previous one has the same .env." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- retention
step "pruning old releases (keeping the active, the previous and $KEEP_OLD more)"
rsh "cd '$B/releases' && n=0 && for r in \$(ls -1t); do
  case \"\$r\" in *[!A-Za-z0-9._-]*|'') continue ;; esac
  [ -d \"\$r\" ] || continue
  case \"\$r\" in *.uploading) if [ -n \"\$(find \"\$r\" -maxdepth 0 -mmin +30 2>/dev/null)\" ]; then rm -rf -- \"\$r\"; fi; continue ;; esac
  if [ \"\$r\" = '$VERSION' ] || [ \"\$r\" = '$ACTIVE' ]; then continue; fi
  n=\$((n + 1))
  if [ \"\$n\" -gt $KEEP_OLD ]; then rm -rf -- \"\$r\"; fi
done" || echo "deploy: warning: pruning failed (the deploy itself succeeded)" >&2

# ---------------------------------------------------------------- smoke
if [ -n "$PUBLIC_URL" ]; then
  step "smoke check against $PUBLIC_URL"
  if ! EXPECTED_BUILD_ID="$BUILD_ID" bash "$SCRIPT_DIR/smoke.sh" "$PUBLIC_URL" "$VERSION"; then
    echo "deploy: the public smoke check FAILED. The release is live and was not rolled back; check the proxy, TLS and PUBLIC_ORIGIN settings." >&2
    exit 1
  fi
else
  step "note: PUBLIC_URL is not set, so the public smoke check was skipped"
fi
step "done: $VERSION ($BUILD_ID) is live"
