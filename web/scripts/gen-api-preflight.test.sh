#!/usr/bin/env bash
# gen-api.sh must fail fast with a clear message when go or pnpm is missing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A PATH made only of what the script needs before its preflight (dirname), so the result does not depend on
# what the machine keeps in /usr/bin (a CI runner has go there; a laptop may have pnpm there).
BASH_BIN="$(command -v bash)"
mkdir "$tmp/bin"; ln -s "$(command -v dirname)" "$tmp/bin/dirname"

# Case 1: go present, pnpm absent.
ln -s "$(command -v go)" "$tmp/bin/go"
set +e
out="$(PATH="$tmp/bin" "$BASH_BIN" "$here/gen-api.sh" 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected non-zero exit without pnpm"
echo "$out" | grep -q "corepack enable" || fail "message must mention corepack enable: $out"
echo "$out" | grep -q "Node 24" || fail "message must mention Node 24: $out"

# Case 2: go absent.
rm "$tmp/bin/go"
set +e
out="$(PATH="$tmp/bin" "$BASH_BIN" "$here/gen-api.sh" 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected non-zero exit without go"
echo "$out" | grep -qi "go is not installed\|'go' not found\|go not found" || fail "message must say go is missing: $out"

echo "PASS: gen-api.sh preflight messages"
