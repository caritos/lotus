#!/usr/bin/env bash
# Smoke check of a deployed site, run from your own machine against the PUBLIC URL
# (so the reverse proxy and TLS are covered, not just loopback).
#
#   smoke.sh <url> <expected-version>
#
# Checks: /healthz is JSON with status ok and the expected version; / is 200 HTML
# containing the app name; /privacy is 200 with real body text; /app/ is 200;
# /nope is 404; /static/style.css fetched over HTTP/1.0 with compression is
# byte-identical to the local file; unauthenticated GET /api/notes is 401.
# Redirects are NOT followed: a 301 to another host fails the check that sees it.
# Exit status: 0 all checks passed, 1 a check failed, 2 bad usage.
#
# Environment:
#   APP_NAME   text the home page must contain, default goweb
#   CSS_FILE   local stylesheet to compare, default <repo>/web/api/internal/web/static/style.css
#              (the check is skipped with a note when the file is absent)
#   CURL       curl binary, default curl
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-goweb}"
CSS_FILE="${CSS_FILE:-$REPO_ROOT/web/api/internal/web/static/style.css}"
CURL="${CURL:-curl}"

if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: smoke.sh <url> <expected-version>" >&2
  exit 2
fi
BASE="${1%/}"
EXPECTED="$2"
case "$BASE" in http://*|https://*) ;; *) echo "smoke: url must start with http:// or https://" >&2; exit 2 ;; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

fail() { FAILURES=$((FAILURES + 1)); echo "smoke FAIL: $*" >&2; }
pass() { echo "smoke ok: $*"; }

# fetch <path> [extra curl args...]: body in $TMP/body, status code in $STATUS.
fetch() {
  local path="$1"; shift
  : > "$TMP/body"
  STATUS="$("$CURL" -sS --max-time 15 --connect-timeout 5 -o "$TMP/body" -w '%{http_code}' "$@" "$BASE$path" 2>"$TMP/curl.err")" || STATUS="000"
  if [ "$STATUS" = "000" ]; then STATUS="000 ($(tr '\n' ' ' < "$TMP/curl.err"))"; fi
}

snippet() { head -c 200 "$TMP/body" | tr '\n' ' '; }

# /healthz
fetch /healthz
if [ "$STATUS" != "200" ]; then
  fail "/healthz: status $STATUS, want 200"
else
  body="$(cat "$TMP/body")"
  if ! printf '%s' "$body" | grep -Eq '"status" *: *"ok"'; then
    fail "/healthz: status is not ok: $(snippet)"
  elif ! printf '%s' "$body" | grep -Eq "\"version\" *: *\"$EXPECTED\""; then
    observed="$(printf '%s' "$body" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
    fail "/healthz: version is '$observed', want '$EXPECTED'"
  else
    pass "/healthz reports version $EXPECTED"
  fi
fi

# /
fetch /
if [ "$STATUS" != "200" ]; then
  fail "/: status $STATUS, want 200"
elif ! grep -qi '<html' "$TMP/body"; then
  fail "/: not HTML: $(snippet)"
elif ! grep -qi -- "$APP_NAME" "$TMP/body"; then
  fail "/: home page does not contain '$APP_NAME'"
else
  pass "/ is HTML and contains '$APP_NAME'"
fi

# /privacy: real text, not just markup
fetch /privacy
if [ "$STATUS" != "200" ]; then
  fail "/privacy: status $STATUS, want 200"
else
  words="$(sed -e 's/<[^>]*>/ /g' "$TMP/body" | wc -w | tr -d ' ')"
  if [ "$words" -lt 20 ]; then
    fail "/privacy: only $words words of body text, want at least 20"
  else
    pass "/privacy has body text ($words words)"
  fi
fi

# /app/
fetch /app/
if [ "$STATUS" != "200" ]; then fail "/app/: status $STATUS, want 200"; else pass "/app/ is 200"; fi

# /nope
fetch /nope
if [ "$STATUS" != "404" ]; then fail "/nope: status $STATUS, want 404"; else pass "/nope is 404"; fi

# Static CSS over HTTP/1.0 with compression (panel proxies speak HTTP/1.0).
if [ -f "$CSS_FILE" ]; then
  fetch /static/style.css --http1.0 --compressed
  if [ "$STATUS" != "200" ]; then
    fail "/static/style.css: status $STATUS, want 200"
  elif ! cmp -s "$TMP/body" "$CSS_FILE"; then
    fail "/static/style.css: served $(wc -c < "$TMP/body" | tr -d ' ') bytes, differs from local $(wc -c < "$CSS_FILE" | tr -d ' ') bytes"
  else
    pass "/static/style.css is byte-identical over HTTP/1.0"
  fi
else
  echo "smoke note: local CSS file '$CSS_FILE' not found; /static/style.css comparison skipped"
fi

# Default-deny API.
fetch /api/notes
if [ "$STATUS" != "401" ]; then fail "/api/notes (unauthenticated): status $STATUS, want 401"; else pass "/api/notes without credentials is 401"; fi

if [ "$FAILURES" -gt 0 ]; then
  echo "smoke: $FAILURES check(s) failed against $BASE" >&2
  exit 1
fi
echo "smoke OK: $BASE runs version $EXPECTED"
