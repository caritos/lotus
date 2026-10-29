#!/usr/bin/env bash
# Tests for web/scripts/sync-public.sh. Each case copies the script into a throwaway tree
# (the script finds web/ from its own location) and runs it there.
# Run: bash web/scripts/sync-public.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }

# new_tree <name>: a tree with web/scripts/sync-public.sh, web/public/{pages,static} and the embed target.
new_tree() {
  local d="$ROOT/$1"
  mkdir -p "$d/web/scripts" "$d/web/public/pages" "$d/web/public/static/fonts" "$d/web/api/internal/web/public"
  cp "$HERE/sync-public.sh" "$d/web/scripts/sync-public.sh" 2>/dev/null
  echo '<html>@@BUILD_ID@@</html>' > "$d/web/public/pages/index.html"
  echo 'body{}' > "$d/web/public/static/style.css"
  echo 'font' > "$d/web/public/static/fonts/a.woff2"
  : > "$d/web/api/internal/web/public/.gitkeep"
}
run() { OUT="$(cd "$ROOT" && bash "$1/web/scripts/sync-public.sh" 2>&1)"; RC=$?; }

# 1. copies pages and static, nested files included
d="$ROOT/copy"; new_tree copy; run "$d"; T="$d/web/api/internal/web/public"
if [ $RC -eq 0 ] && cmp -s "$d/web/public/pages/index.html" "$T/pages/index.html" \
  && cmp -s "$d/web/public/static/fonts/a.woff2" "$T/static/fonts/a.woff2"; then ok "copies pages and nested static files"; else bad "copy failed (rc=$RC): $OUT"; fi
[ -e "$T/.gitkeep" ] && ok "keeps .gitkeep" || bad ".gitkeep was removed"
printf '%s\n' "$OUT" | grep -q 'pages' && ok "prints what it copied" || bad "prints nothing about pages: $OUT"

# 2. removes stale files
d="$ROOT/stale"; new_tree stale; T="$d/web/api/internal/web/public"
mkdir -p "$T/pages" "$T/old"; echo x > "$T/pages/gone.html"; echo x > "$T/old/f.css"
run "$d"
if [ $RC -eq 0 ] && [ ! -e "$T/pages/gone.html" ] && [ ! -e "$T/old" ] && [ -e "$T/.gitkeep" ]; then ok "removes stale files"; else bad "stale files remain (rc=$RC): $(ls -R "$T")"; fi

# 3. idempotent
run "$d"; [ $RC -eq 0 ] && cmp -s "$d/web/public/static/style.css" "$T/static/style.css" && ok "second run is the same" || bad "second run failed: $OUT"

# 4. fails when a source dir is missing, and leaves the target alone
for missing in pages static; do
  d="$ROOT/no-$missing"; new_tree "no-$missing"; T="$d/web/api/internal/web/public"
  run "$d"; echo keep > "$T/keep.txt"
  rm -rf "$d/web/public/$missing"; run "$d"
  if [ $RC -ne 0 ] && printf '%s\n' "$OUT" | grep -q "web/public/$missing" && [ -e "$T/keep.txt" ]; then ok "fails and names web/public/$missing when it is missing"; else bad "missing $missing: rc=$RC out=$OUT"; fi
done

# 5. creates the target directory when absent
d="$ROOT/fresh"; new_tree fresh; rm -rf "$d/web/api/internal/web/public"; run "$d"
[ $RC -eq 0 ] && [ -e "$d/web/api/internal/web/public/pages/index.html" ] && ok "creates the target when absent" || bad "no target created: $OUT"

echo "sync-public.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
