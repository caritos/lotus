#!/usr/bin/env bash
# Smoke check of a deployed site, run from your own machine against the PUBLIC URL
# (so the reverse proxy and TLS are covered, not just loopback).
#
#   smoke.sh <url> <expected-version>
#
# Checks: /healthz is JSON with status ok, the expected version and a well-formed build_id
# (YYYYMMDD-<short commit>); / is 200 HTML whose <title> or first <h1> contains the app name as a
# whole word (case-insensitive) and a "Build <id>"
# footer whose id equals the /healthz build_id; /privacy is 200 with real body text; /app/ is 200;
# /nope is 404; /static/style.css fetched over HTTP/1.0 with compression is
# byte-identical to the local file; unauthenticated GET /api/notes is 401.
# Redirects are NOT followed: a 301 to another host fails the check that sees it.
# When EXPECTED_BUILD_ID is set, the /healthz build_id must equal it and the text
# "Build <id>" must appear in the / and /app/ HTML (curl shows it; the React footer is
# rendered from it).
# Exit status: 0 all checks passed, 1 a check failed, 2 bad usage.
#
# Environment:
#   APP_NAME   name that the home page's <title> or first <h1> must contain as a whole word,
#              default app (the display name; scripts/rename.sh sets the project name there)
#   CSS_FILE   local stylesheet to compare, default <repo>/web/api/internal/web/static/style.css
#              (the check is skipped with a note when the file is absent)
#   CURL       curl binary, default curl
#   EXPECTED_BUILD_ID   the build id that was just deployed (deploy.sh sets it)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-app}"
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
EXPECTED_BUILD_ID="${EXPECTED_BUILD_ID:-}"
HEALTH_BUILD_ID=""
BUILD_ID_RE='^[0-9]{8}-[0-9a-z]+(-dirty)?$'

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

# name_in_heading <html file>: true when APP_NAME occurs, case-insensitively and as a WHOLE WORD,
# in the page's <title> or in its first <h1>. A match inside another word (application, mapp), in
# a link or in body text does not count. Sets PAGE_TITLE and PAGE_H1 for the failure message.
# (Explicit character classes: \b is not portable in grep -E.)
# Removes every <!-- ... --> (shortest match, so "--" inside a comment is fine; an unterminated
# comment drops the rest, as browsers do) from the one-line input.
STRIP_COMMENTS='{ s = $0; out = ""; while ((i = index(s, "<!--")) > 0) { out = out substr(s, 1, i - 1); s = substr(s, i + 4); j = index(s, "-->"); if (j == 0) { s = ""; break } s = substr(s, j + 3) } print out s }'
# Known limits (documented, not fixed): an inline SVG <title> that comes before the page <title> is
# taken as the title, and a name split by markup (for example app<b></b>) is not a whole word.
heading_text() { # <html file> <tag, as a bracket-class pattern>: text of the first such tag, tags stripped
  tr '\n\r' '  ' < "$1" | awk "$STRIP_COMMENTS" | grep -oE "<$2[[:space:]>].*" | head -n 1 |
    sed -E "s#</$2>.*##; s#^<$2[^>]*>##; s#<[^>]*># #g"
}
name_in_heading() {
  local esc re
  PAGE_TITLE="$(heading_text "$1" "[Tt][Ii][Tt][Ll][Ee]")"; PAGE_H1="$(heading_text "$1" "[Hh]1")"
  esc="$(printf '%s' "$APP_NAME" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  re="(^|[^A-Za-z0-9_])${esc}([^A-Za-z0-9_]|\$)"
  printf '%s\n' "$PAGE_TITLE" | grep -Eiq -- "$re" || printf '%s\n' "$PAGE_H1" | grep -Eiq -- "$re"
}

# /healthz
fetch /healthz
if [ "$STATUS" != "200" ]; then
  fail "/healthz: status $STATUS, want 200"
else
  body="$(cat "$TMP/body")"
  if ! printf '%s' "$body" | grep -Eq '"status" *: *"ok"'; then
    fail "/healthz: status is not ok: $(snippet)"
  else
    observed="$(printf '%s' "$body" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
    if [ "$observed" != "$EXPECTED" ]; then
      fail "/healthz: version is '$observed', want '$EXPECTED'"
    else
      pass "/healthz reports version $EXPECTED"
    fi
    HEALTH_BUILD_ID="$(printf '%s' "$body" | sed -n 's/.*"build_id" *: *"\([^"]*\)".*/\1/p')"
    if [ -z "$HEALTH_BUILD_ID" ]; then
      fail "/healthz: no build_id field: $(snippet)"
    elif ! printf '%s\n' "$HEALTH_BUILD_ID" | grep -Eq "$BUILD_ID_RE"; then
      fail "/healthz: build_id '$HEALTH_BUILD_ID' is not YYYYMMDD-<short commit>"
      HEALTH_BUILD_ID=""
    elif [ -n "$EXPECTED_BUILD_ID" ] && [ "$HEALTH_BUILD_ID" != "$EXPECTED_BUILD_ID" ]; then
      fail "/healthz: build_id is '$HEALTH_BUILD_ID', want '$EXPECTED_BUILD_ID'"
    else
      pass "/healthz reports build id $HEALTH_BUILD_ID"
    fi
  fi
fi

# /
fetch /
if [ "$STATUS" != "200" ]; then
  fail "/: status $STATUS, want 200"
elif ! grep -qi '<html' "$TMP/body"; then
  fail "/: not HTML: $(snippet)"
elif ! name_in_heading "$TMP/body"; then
  fail "/: neither the <title> nor the first <h1> contains '$APP_NAME' as a whole word (found: title '$PAGE_TITLE', h1 '$PAGE_H1')"
else
  pass "/ is HTML and its title or first <h1> contains '$APP_NAME' as a whole word"
fi

# The footer of / shows "Build <id>"; it must be the id /healthz reports (and the deployed one).
if [ "$STATUS" = "200" ]; then
  footer_id="$(grep -o 'Build [0-9][0-9a-z-]*' "$TMP/body" | head -n 1 | sed 's/^Build //')"
  if [ -z "$footer_id" ]; then
    fail "/: no 'Build <id>' footer in the page: $(snippet)"
  elif ! printf '%s\n' "$footer_id" | grep -Eq "$BUILD_ID_RE"; then
    fail "/: footer build id '$footer_id' is not YYYYMMDD-<short commit>"
  elif [ -n "$HEALTH_BUILD_ID" ] && [ "$footer_id" != "$HEALTH_BUILD_ID" ]; then
    fail "/: footer shows build id '$footer_id' but /healthz reports '$HEALTH_BUILD_ID'"
  elif [ -n "$EXPECTED_BUILD_ID" ] && [ "$footer_id" != "$EXPECTED_BUILD_ID" ]; then
    fail "/: footer shows build id '$footer_id', want '$EXPECTED_BUILD_ID'"
  else
    pass "/ footer shows Build $footer_id"
  fi
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
if [ "$STATUS" != "200" ]; then
  fail "/app/: status $STATUS, want 200"
else
  pass "/app/ is 200"
  if [ -n "$EXPECTED_BUILD_ID" ]; then
    if grep -qF -- "Build $EXPECTED_BUILD_ID" "$TMP/body"; then
      pass "/app/ footer shows Build $EXPECTED_BUILD_ID"
    else
      fail "/app/: 'Build $EXPECTED_BUILD_ID' not found in the page: $(snippet)"
    fi
  fi
fi

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
