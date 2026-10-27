#!/usr/bin/env bash
# Fails if regenerating the API code changes (or fails to produce) a generated file,
# i.e. the committed generated code is stale relative to web/api/openapi.yaml.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
files=(
  "web/api/internal/apigen/models.gen.go"
  "web/src/api/schema.d.ts"
  "web/pnpm-lock.yaml"
)
before="$(mktemp)"; after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

sum() {
  for f in "${files[@]}"; do
    if [ ! -f "$root/$f" ]; then echo "MISSING $f"; else echo "$(shasum -a 256 "$root/$f" | cut -d' ' -f1)  $f"; fi
  done
}

sum >"$before"
bash "$here/gen-api.sh" >/dev/null
sum >"$after"

if grep -q '^MISSING' "$after"; then
  echo "FAIL: generated file missing:" >&2; grep '^MISSING' "$after" >&2; exit 1
fi
if ! diff -u "$before" "$after" >&2; then
  echo "FAIL: generated API code is stale; run 'make api' and commit" >&2; exit 1
fi
echo "PASS: generated API code is up to date"
