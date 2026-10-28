#!/usr/bin/env bash
# Tests for scripts/rename.sh. Copies the repo (tracked and new files) into a temp dir,
# commits it there, renames it and checks the result builds and tests.
# Run: bash scripts/rename.test.sh   (RENAME_TEST_FULL=1 also runs scripts/deploy.test.sh in the copy)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }
skip() { echo "SKIP - $1"; }

# make_copy <dest>: a committed git repo holding the current files of $REPO.
make_copy() {
  local dest="$1"
  mkdir -p "$dest"
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$dest" || return 1
  (cd "$dest" && git init -q && git add -A && git -c gc.auto=0 -c maintenance.auto=false -c user.email=t@example.com -c user.name=t commit -q -m base) || return 1
}

BASE="$ROOT/base"
make_copy "$BASE" || { echo "rename.test.sh: cannot copy the repo" >&2; exit 2; }

# expect_fail <label> <expected stderr fragment> <args...>: run rename.sh in a fresh copy.
expect_fail() {
  local label="$1" frag="$2"; shift 2
  local d="$ROOT/case-$pass-$fail"
  cp -R "$BASE" "$d"
  local out rc
  out="$(cd "$d" && bash scripts/rename.sh "$@" 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -qF -- "$frag"; then ok "$label"; else bad "$label (rc=$rc out=$out)"; fi
  if [ -n "$(cd "$d" && git status --porcelain)" ]; then bad "$label left changes behind"; fi
}

expect_fail "bad module path (uppercase)" "module path" Example.com/x shop
expect_fail "bad module path (space)" "module path" "ex ample" shop
expect_fail "uppercase name" "name" example.com/acme/shop Shop
expect_fail "name with a hyphen" "name" example.com/acme/shop my-shop
expect_fail "name starting with a digit" "name" example.com/acme/shop 1shop
expect_fail "missing args" "usage" 
expect_fail "one arg" "usage" example.com/acme/shop

# dirty tree
D="$ROOT/dirty"; cp -R "$BASE" "$D"; echo x >> "$D/README-dirty.txt"
out="$(cd "$D" && bash scripts/rename.sh example.com/acme/shop shop 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "uncommitted"; then ok "dirty tree refused without --force"; else bad "dirty tree (rc=$rc out=$out)"; fi
if grep -q "module goweb" "$D/web/api/go.mod"; then ok "dirty tree refusal changed nothing"; else bad "dirty tree refusal modified go.mod"; fi

# outside a git work tree
N="$ROOT/nogit"; mkdir -p "$N/scripts"; cp "$REPO/scripts/rename.sh" "$N/scripts/" 2>/dev/null
out="$(cd "$N" && bash scripts/rename.sh example.com/acme/shop shop 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "git work tree"; then ok "refuses outside a git work tree"; else bad "no git (rc=$rc out=$out)"; fi

# no-op
D="$ROOT/noop"; cp -R "$BASE" "$D"
out="$(cd "$D" && bash scripts/rename.sh goweb goweb 2>&1)"; rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "nothing to do" && [ -z "$(cd "$D" && git status --porcelain)" ]; then ok "goweb goweb is a no-op"; else bad "no-op (rc=$rc out=$out)"; fi

# the real rename
R="$ROOT/renamed"; cp -R "$BASE" "$R"
out="$(cd "$R" && bash scripts/rename.sh example.com/acme/shop shop 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "rename exits 0" || { bad "rename exit $rc: $out"; }

left="$(cd "$R" && grep -rIl --exclude-dir=.git --exclude-dir=superpowers --exclude-dir=node_modules goweb . 2>/dev/null)"
[ -z "$left" ] && ok "no 'goweb' left outside docs/superpowers" || bad "goweb remains in: $left"
leftU="$(cd "$R" && grep -rIl --exclude-dir=.git --exclude-dir=superpowers --exclude-dir=node_modules GOWEB . 2>/dev/null)"
[ -z "$leftU" ] && ok "no 'GOWEB' left" || bad "GOWEB remains in: $leftU"
grep -qx "module example.com/acme/shop" "$R/web/api/go.mod" && ok "go.mod module path" || bad "go.mod: $(head -1 "$R/web/api/go.mod")"
[ -d "$R/web/api/cmd/shop" ] && [ ! -e "$R/web/api/cmd/goweb" ] && ok "cmd/shop exists" || bad "cmd dir"
[ -f "$R/deploy/shop.service" ] && [ -f "$R/deploy/shop-backup.service" ] && [ -f "$R/deploy/shop-backup.timer" ] && ok "unit files renamed" || bad "unit files"
grep -q "example.com/acme/shop/internal/version" "$R/Makefile" && ok "ldflags use the module path" || bad "Makefile ldflags"
for f in Makefile scripts/deploy.sh web/test/e2e/global-setup.ts; do
  grep -q "example.com/acme/shop/internal/version.BuildID" "$R/$f" && ok "build id ldflag renamed in $f" || bad "BuildID ldflag in $f"
done
[ -x "$R/scripts/build-id.sh" ] && printf '%s' "$(cd "$R" && BUILD_DATE=20261027 bash scripts/build-id.sh)" | grep -Eq '^20261027-([0-9a-f]{7}|unknown)(-dirty)?$' && ok "build-id.sh works in the renamed copy" || bad "build-id.sh in the renamed copy"
grep -q "SHOP_BIN" "$R/scripts/restore.sh" && ok "env var prefix renamed" || bad "SHOP_BIN missing"
[ -z "$(cd "$R" && git status --porcelain | grep -v '^R \|^RM\|^ M\|^M \|^A ')" ] || bad "unexpected status entries"

if command -v go >/dev/null 2>&1; then
  # The copy has no frontend build (it is gitignored), so the embed tests must skip
  # here even on a CI runner, where CI=true would turn the skip into a failure.
  if (cd "$R/web/api" && go build ./... && go vet ./... && env -u CI go test -short ./... ) >"$ROOT/go.log" 2>&1; then ok "go build, vet and test -short pass in the copy"; else bad "go checks in the copy: $(tail -20 "$ROOT/go.log")"; fi
else skip "go not on PATH"; fi

if command -v pnpm >/dev/null 2>&1; then
  if (cd "$R" && bash scripts/gen-api.test.sh) >"$ROOT/gen.log" 2>&1; then ok "gen-api.test.sh passes in the copy (generated files consistent)"; else bad "gen-api.test.sh in the copy: $(tail -20 "$ROOT/gen.log")"; fi
else skip "pnpm not on PATH: gen-api.test.sh not run in the copy"; fi

if [ "${RENAME_TEST_FULL:-}" = 1 ]; then
  if (cd "$R" && bash scripts/deploy.test.sh) >"$ROOT/deploy.log" 2>&1; then ok "scripts/deploy.test.sh passes in the copy"; else bad "scripts/deploy.test.sh in the copy: $(tail -20 "$ROOT/deploy.log")"; fi
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
