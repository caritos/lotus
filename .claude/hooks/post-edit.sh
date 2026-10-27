#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit. Reads the hook JSON on stdin and checks what was edited:
#   web/api/**/*.go          -> go vet + go test -short for that package (run from web/api)
#   web/src/** web/e2e/**    -> pnpm exec tsc --noEmit (run from web/)
# Everything else (generated files, docs, lockfiles, the embed dir) is ignored.
# Success prints nothing and exits 0. Failure prints the last 40 lines to stderr and exits 2.
set -u

input="$(cat)"

# Extract tool_input.file_path without jq.
file=""
if command -v python3 >/dev/null 2>&1; then
  file="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("file_path") or "")
except Exception:
    pass
' 2>/dev/null)"
else
  file="$(printf '%s' "$input" | tr '\n' ' ' | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
[ -n "$file" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

case "$file" in
  /*) abs="$file" ;;
  *) abs="$root/$file" ;;
esac
rel="${abs#"$root"/}"

TO=""
if command -v timeout >/dev/null 2>&1; then TO="timeout 300"
elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout 300"; fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

fail() {
  echo "post-edit hook: $1 failed for $rel" >&2
  tail -n 40 "$out" >&2
  exit 2
}

case "$rel" in
  web/api/internal/web/app/*) exit 0 ;;
  *.gen.go) exit 0 ;;
  web/api/*.go)
    command -v go >/dev/null 2>&1 || exit 0
    sub="${rel#web/api/}"
    dir="$(dirname "$sub")"
    if [ "$dir" = "." ]; then pkg="./..."; else pkg="./$dir/..."; fi
    cd "$root/web/api" 2>/dev/null || exit 0
    $TO go vet "$pkg" >"$out" 2>&1 || fail "go vet $pkg"
    $TO go test -short "$pkg" >"$out" 2>&1 || fail "go test -short $pkg"
    ;;
  web/src/api/schema.d.ts) exit 0 ;;
  web/src/*|web/e2e/*)
    case "$rel" in *.ts|*.tsx) ;; *) exit 0 ;; esac
    if ! command -v pnpm >/dev/null 2>&1; then
      echo "post-edit hook: pnpm not on PATH, skipping tsc for $rel (use Node 24 with corepack)" >&2
      exit 0
    fi
    cd "$root/web" 2>/dev/null || exit 0
    $TO pnpm exec tsc --noEmit >"$out" 2>&1 || fail "pnpm exec tsc --noEmit"
    ;;
  *) exit 0 ;;
esac
exit 0
