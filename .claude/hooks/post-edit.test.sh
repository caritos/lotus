#!/usr/bin/env bash
# Tests for .claude/hooks/post-edit.sh with fake go/pnpm on PATH. Run: bash .claude/hooks/post-edit.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/post-edit.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PROJ="$ROOT/proj"
mkdir -p "$PROJ/web/api/internal/notes" "$PROJ/web/src/api" "$PROJ/docs" "$ROOT/bin"
touch "$PROJ/web/api/internal/notes/store.go" "$PROJ/web/api/internal/notes/x.gen.go" \
  "$PROJ/web/src/App.tsx" "$PROJ/web/src/api/schema.d.ts" "$PROJ/docs/a.md"

LOG="$ROOT/calls.log"
cat > "$ROOT/bin/go" <<EOS
#!/bin/sh
echo "go \$PWD \$*" >> "$LOG"
if [ -n "\${FAKE_GO_FAIL:-}" ]; then echo "FAKE FAILURE line"; exit 1; fi
exit 0
EOS
cat > "$ROOT/bin/pnpm" <<EOS
#!/bin/sh
echo "pnpm \$PWD \$*" >> "$LOG"
exit 0
EOS
chmod +x "$ROOT/bin/go" "$ROOT/bin/pnpm"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }

# run_hook <file_path-or-empty>: sets RC, OUT, CALLS
run_hook() {
  : > "$LOG"
  local json
  if [ -n "$1" ]; then json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$1\"}}"; else json='{"tool_name":"Edit","tool_input":{}}'; fi
  OUT="$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$PROJ" PATH="$ROOT/bin:$PATH" bash "$HOOK" 2>&1)"
  RC=$?
  CALLS="$(cat "$LOG")"
}

run_hook "$PROJ/web/api/internal/notes/store.go"
if [ $RC -eq 0 ] && echo "$CALLS" | grep -q "go .*/web/api vet ./internal/notes/..." && echo "$CALLS" | grep -q "go .*/web/api test -short ./internal/notes/..."; then
  ok "go edit runs vet and test for that package"; else bad "go edit: rc=$RC calls=[$CALLS] out=[$OUT]"; fi
[ -z "$OUT" ] && ok "success prints nothing" || bad "success output: $OUT"

run_hook "$PROJ/web/api/internal/notes/x.gen.go"
[ $RC -eq 0 ] && [ -z "$CALLS" ] && ok ".gen.go edit runs nothing" || bad ".gen.go: rc=$RC calls=[$CALLS]"

run_hook "$PROJ/docs/a.md"
[ $RC -eq 0 ] && [ -z "$CALLS" ] && ok "docs edit runs nothing" || bad "docs: rc=$RC calls=[$CALLS]"

run_hook "$PROJ/web/src/App.tsx"
if [ $RC -eq 0 ] && echo "$CALLS" | grep -q "pnpm .*/web exec tsc --noEmit"; then ok "web/src edit runs tsc"; else bad "tsc: rc=$RC calls=[$CALLS]"; fi

run_hook "$PROJ/web/src/api/schema.d.ts"
[ $RC -eq 0 ] && [ -z "$CALLS" ] && ok "schema.d.ts edit runs nothing" || bad "schema.d.ts: rc=$RC calls=[$CALLS]"

FAKE_GO_FAIL=1 run_hook "$PROJ/web/api/internal/notes/store.go"
if [ $RC -eq 2 ] && echo "$OUT" | grep -q "FAKE FAILURE"; then ok "failing go yields exit 2 with output"; else bad "failure: rc=$RC out=[$OUT]"; fi

run_hook ""
[ $RC -eq 0 ] && [ -z "$CALLS" ] && ok "missing file_path yields exit 0" || bad "missing path: rc=$RC calls=[$CALLS]"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
