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

# The names this checkout ships with, read the way rename.sh reads them. NEW is the name the tests
# rename to; it must differ from the current one.
CUR_MODULE="$(sed -n 's/^module[[:space:]]*//p' "$REPO/web/api/go.mod" | head -1)"
CUR="$(ls "$REPO/web/api/cmd" | head -1)"
CUR_UP="$(printf '%s' "$CUR" | tr '[:lower:]' '[:upper:]')"
NEW=shop; [ "$CUR" = shop ] && NEW=store
NEW_UP="$(printf '%s' "$NEW" | tr '[:lower:]' '[:upper:]')"
NEW_MODULE="example.com/acme/$NEW"

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

expect_fail "bad module path (uppercase)" "module path" Example.com/x "$NEW"
expect_fail "bad module path (space)" "module path" "ex ample" "$NEW"
expect_fail "uppercase name" "name" "$NEW_MODULE" Shop
expect_fail "name with a hyphen" "name" "$NEW_MODULE" my-shop
expect_fail "name starting with a digit" "name" "$NEW_MODULE" 1shop
expect_fail "missing args" "usage" 
expect_fail "one arg" "usage" "$NEW_MODULE"

# Reserved words: names the repository uses as directories or variable targets are rejected for
# the new name, and nothing is touched.
RESERVED_LIST="$(sed -n 's/^RESERVED="\(.*\)"$/\1/p' "$REPO/scripts/rename.sh")"
[ -n "$RESERVED_LIST" ] && ok "rename.sh has a RESERVED list" || bad "no RESERVED list in rename.sh"
rw_bad=""
d="$ROOT/res-all"; cp -R "$BASE" "$d"
for w in $RESERVED_LIST; do
  out="$(cd "$d" && bash scripts/rename.sh "example.com/acme/$w" "$w" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] || ! echo "$out" | grep -q "reserved" || ! echo "$out" | grep -qF "'$w'" || [ -n "$(cd "$d" && git status --porcelain)" ]; then rw_bad="$rw_bad $w"; fi
done
rm -rf "$d"
[ -z "$rw_bad" ] && ok "every reserved word is rejected by name with the tree untouched" || bad "reserved words not rejected cleanly:$rw_bad"
# The list must not drift: every tool the scripts probe with `command -v` or the CI workflow runs
# is a word the context rules could corrupt ("command -v go", "web/api/go.mod"), so it is reserved.
drift=""
for w in $(cd "$REPO" && { git grep -ohE 'command -v [a-z0-9]+' -- scripts Makefile .github .claude ':!.claude/skills' | sed 's/command -v //'; git grep -ohE 'run: [a-z0-9]+' -- .github | sed 's/run: //'; } | sort -u); do
  [ "$w" = "$CUR" ] && continue
  case " $RESERVED_LIST " in *" $w "*) ;; *) drift="$drift $w" ;; esac
done
[ -z "$drift" ] && ok "every probed or invoked tool is in the RESERVED list" || bad "tools missing from RESERVED:$drift"
# Fixture words: $VAR/<word> targets in the shell tests (for example "$T/notify") are rewritten
# by the $VAR/ prefix rule when the name equals them.
fix=""
for w in $(cd "$REPO" && git grep -ohE '\$\{?[A-Za-z_]+\}?/[a-z][a-z0-9]*' -- 'scripts/*.test.sh' .claude/hooks | sed 's#.*/##' | sort -u); do
  [ "$w" = "$CUR" ] && continue
  case " $RESERVED_LIST " in *" $w "*) ;; *) fix="$fix $w" ;; esac
done
[ -z "$fix" ] && ok "every \$VAR/<word> fixture target is in the RESERVED list" || bad "fixture words missing from RESERVED:$fix"
# Every tracked directory name must be reserved (apart from the shipped name's own directories).
missing=""
for dn in $(cd "$REPO" && git ls-files | grep -v '^docs/superpowers/' | grep -v '^.claude/skills/' | sed 's#/[^/]*$##' | grep -v '^[^/]*$' | tr '/' '\n' | sort -u | grep -E '^[a-z][a-z0-9]*$'); do
  case "$dn" in app|superpowers) continue ;; esac
  case " $RESERVED_LIST " in *" $dn "*) ;; *) missing="$missing $dn" ;; esac
done
[ -z "$missing" ] && ok "every tracked directory name is in the RESERVED list" || bad "directory names missing from RESERVED:$missing"

# Names that pass the reserved-word pre-filter but already occur in the tree in a context the rules
# rewrite ("verify-backup", "web/api/openapi.yaml", "s.db.QueryRow", ...) are refused at run time:
# renaming to them could not be undone exactly. The tree must stay untouched.
d="$ROOT/res-run"; cp -R "$BASE" "$d"
rf_bad=""
for w in verify openapi live daily homebrew wireless logger time http s a e; do
  out="$(cd "$d" && bash scripts/rename.sh "example.com/acme/$w" "$w" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] || ! echo "$out" | grep -qF "'$w'" || ! echo "$out" | grep -q "already occurs" || [ -n "$(cd "$d" && git status --porcelain)" ]; then rf_bad="$rf_bad $w($rc)"; fi
done
rm -rf "$d"
[ -z "$rf_bad" ] && ok "names that already occur in rewritten contexts are refused with the tree untouched" || bad "not refused cleanly:$rf_bad"

# Name-only change (module path kept) and module-path-already-in-the-tree.
for mode in starter renamed; do
  X="$ROOT/res-name-$mode"; cp -R "$BASE" "$X"
  if [ "$mode" = renamed ]; then (cd "$X" && bash scripts/rename.sh "$NEW_MODULE" "$NEW" >/dev/null 2>&1 && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m r); curm="$NEW_MODULE"; curn="$NEW"; tgt=zebra; else curm="$CUR_MODULE"; curn="$CUR"; tgt="$NEW"; fi
  out="$(cd "$X" && bash scripts/rename.sh --check "$curm" "$tgt" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && ok "--check accepts a name-only change on the $mode" || bad "--check name-only on the $mode (rc=$rc): $out"
  out="$(cd "$X" && bash scripts/rename.sh "$curm" "$tgt" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && grep -qx "module $curm" "$X/web/api/go.mod" && [ -d "$X/web/api/cmd/$tgt" ]; then ok "name-only rename on the $mode keeps the module and moves cmd/"; else bad "name-only rename on the $mode (rc=$rc): $out"; fi
  (cd "$X" && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m n && bash scripts/rename.sh "$curm" "$curn" >/dev/null 2>&1; git add -A)
  back="$(cd "$X" && git diff --cached --stat HEAD~1 2>&1)"
  [ -z "$back" ] && ok "name-only $mode round trip is exact" || bad "name-only $mode round trip differs: $back"
  rm -rf "$X"
done
# A module path that already occurs in the tree (a dependency path, or the starter's own) is refused with a module message.
X="$ROOT/res-mod-in-tree"; cp -R "$BASE" "$X"
for m in golang.org/x/sys "$CUR_MODULE/internal"; do
  out="$(cd "$X" && bash scripts/rename.sh "$m" "$CUR" 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q "module path" && echo "$out" | grep -q "already occurs" && [ -z "$(cd "$X" && git status --porcelain)" ]; then ok "module path '$m' that already occurs in the tree is refused (tree untouched)"; else bad "module '$m' (rc=$rc): $out"; fi
done
rm -rf "$X"

# --check: every validation, no modification, no clean tree needed.
d="$ROOT/res-chk"; cp -R "$BASE" "$d"
chk() { (cd "$d" && bash scripts/rename.sh --check "$@" 2>&1); }
out="$(chk "$NEW_MODULE" "$NEW")"; rc=$?
[ $rc -eq 0 ] && [ -z "$(cd "$d" && git status --porcelain)" ] && ok "--check accepts a good name and changes nothing" || bad "--check good name (rc=$rc out=$out)"
out="$(chk "example.com/acme/web" web)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "reserved" && ok "--check rejects a reserved name" || bad "--check reserved (rc=$rc out=$out)"
out="$(chk "example.com/acme/verify" verify)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "already occurs" && ok "--check rejects a name that fails the run-time check" || bad "--check verify (rc=$rc out=$out)"
out="$(chk "Bad Module" "$NEW")"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "module path" && ok "--check rejects a bad module path" || bad "--check bad module (rc=$rc out=$out)"
out="$(chk "$NEW_MODULE" Shop)"; rc=$?
[ $rc -ne 0 ] && ok "--check rejects a bad name pattern" || bad "--check bad pattern (rc=$rc)"
echo x >> "$d/README-dirty.txt"; echo y >> "$d/README.md"; before="$(cd "$d" && git status --porcelain; cksum < README.md)"
out="$(chk "$NEW_MODULE" "$NEW")"; rc=$?
[ $rc -eq 0 ] && [ "$(cd "$d" && git status --porcelain; cksum < README.md)" = "$before" ] && ok "--check works on a dirty tree and leaves it as it was" || bad "--check on a dirty tree (rc=$rc out=$out)"
rm -rf "$d"

# dirty tree
D="$ROOT/dirty"; cp -R "$BASE" "$D"; echo x >> "$D/README-dirty.txt"
out="$(cd "$D" && bash scripts/rename.sh "$NEW_MODULE" "$NEW" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "uncommitted"; then ok "dirty tree refused without --force"; else bad "dirty tree (rc=$rc out=$out)"; fi
if grep -qx "module $CUR_MODULE" "$D/web/api/go.mod"; then ok "dirty tree refusal changed nothing"; else bad "dirty tree refusal modified go.mod"; fi

# outside a git work tree
N="$ROOT/nogit"; mkdir -p "$N/scripts"; cp "$REPO/scripts/rename.sh" "$N/scripts/" 2>/dev/null
out="$(cd "$N" && bash scripts/rename.sh "$NEW_MODULE" "$NEW" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "git work tree"; then ok "refuses outside a git work tree"; else bad "no git (rc=$rc out=$out)"; fi

# no-op: the current module path and name
D="$ROOT/noop"; cp -R "$BASE" "$D"
out="$(cd "$D" && bash scripts/rename.sh "$CUR_MODULE" "$CUR" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "nothing to do" && [ -z "$(cd "$D" && git status --porcelain)" ]; then ok "renaming to the current names is a no-op"; else bad "no-op (rc=$rc out=$out)"; fi

# name_tokens <dir> <name>: lines where <name> still appears in a project-name context. The generic
# word (prose, internal/app, internal/web/app, the /app/ mount, APP_ENV) is NOT such a context.
name_tokens() {
  local n="$2" N; N="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
  (cd "$1" && git grep -nE "(^|[^A-Za-z0-9_])${n}(_session|\.db|\.service|-backup|-pull|-e2e|-web|-development-only)|${n}/(internal|cmd|tests)([^A-Za-z0-9_]|$)|(cmd|dist|current|~|HOME|%h|config|Logs|backups)/${n}([^A-Za-z0-9_/]|$)|(^|[^A-Za-z0-9_])com\\.${n}\\.|users:\\(\\(\"${n}\"|(^|[^A-Za-z0-9])${N}_(BIN|AUTH_PANIC_CHILD)" -- . ':!docs/superpowers' ':!.claude/skills' ':!scripts/rename.sh' ':!scripts/rename.test.sh')
}

# Module-path-only change (same name): used to die in git mv onto itself after rewriting files.
for mode in starter renamed; do
  X="$ROOT/res-mod-$mode"; cp -R "$BASE" "$X"
  if [ "$mode" = renamed ]; then (cd "$X" && bash scripts/rename.sh "$NEW_MODULE" "$NEW" >/dev/null 2>&1 && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m r); cur="$NEW"; else cur="$CUR"; fi
  out="$(cd "$X" && bash scripts/rename.sh "github.com/other/$cur" "$cur" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && grep -qx "module github.com/other/$cur" "$X/web/api/go.mod" && [ -d "$X/web/api/cmd/$cur" ] && (cd "$X/web/api" && go build ./... >/dev/null 2>&1); then ok "module-path-only rename on the $mode (name $cur) works and builds"; else bad "module-path-only rename on the $mode (rc=$rc): $out"; fi
  rm -rf "$X"
done

# The skills under .claude/skills/ are not part of the starter's own text: rename.sh neither rewrites
# them nor counts what they say when it checks a name. Put project-name contexts into one, then
# rename (and rename to a name that occurs only there) and check it came out byte for byte.
SK="$ROOT/res-sk"; cp -R "$BASE" "$SK"
mkdir -p "$SK/.claude/skills/demo"
printf 'cmd/%s dist/%s %s.service com.%s.backup-pull dist/zzonlyskill\n' "$CUR" "$CUR" "$CUR" "$CUR" > "$SK/.claude/skills/demo/SKILL.md"
(cd "$SK" && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m skill)
sk_before="$(cksum < "$SK/.claude/skills/demo/SKILL.md")"
out="$(cd "$SK" && bash scripts/rename.sh --check example.com/acme/zzonlyskill zzonlyskill 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "--check ignores a name that occurs only under .claude/skills" || bad "--check counted .claude/skills (rc=$rc out=$out)"
out="$(cd "$SK" && bash scripts/rename.sh "$NEW_MODULE" "$NEW" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$sk_before" = "$(cksum < "$SK/.claude/skills/demo/SKILL.md")" ] && [ -z "$(cd "$SK" && git status --porcelain -- .claude/skills)" ] && ok "rename leaves .claude/skills untouched" || bad "rename touched .claude/skills (rc=$rc out=$out)"
# the same text anywhere else IS rewritten (the exemption is only for the skills)
SK2="$ROOT/res-sk2"; cp -R "$BASE" "$SK2"
printf 'cmd/%s dist/%s\n' "$CUR" "$CUR" > "$SK2/docs/zz-note.md"
(cd "$SK2" && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m note && bash scripts/rename.sh "$NEW_MODULE" "$NEW" >/dev/null 2>&1)
grep -q "dist/$NEW" "$SK2/docs/zz-note.md" && ok "the same contexts outside .claude/skills are still rewritten" || bad "docs/ line not rewritten"
rm -rf "$SK" "$SK2"

# The real rename. The shipped name "app" is also a package, a directory, a URL prefix and an
# environment variable prefix, so only the project-name contexts may change.
R="$ROOT/renamed"; cp -R "$BASE" "$R"
out="$(cd "$R" && bash scripts/rename.sh "$NEW_MODULE" "$NEW" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "rename exits 0" || { bad "rename exit $rc: $out"; }
echo "$out" | grep -q "Next steps" && ok "prints the next steps" || bad "no next steps in: $out"

left="$(name_tokens "$R" "$CUR")"
[ -z "$left" ] && ok "no project-name token '$CUR' left (module path, cmd, dist, units, cookie, db, ldflags, env)" || bad "$CUR tokens remain: $left"
grep -qx "module $NEW_MODULE" "$R/web/api/go.mod" && ok "go.mod module path" || bad "go.mod: $(head -1 "$R/web/api/go.mod")"
[ -d "$R/web/api/cmd/$NEW" ] && [ ! -e "$R/web/api/cmd/$CUR" ] && ok "cmd/$NEW exists" || bad "cmd dir"
[ -f "$R/deploy/$NEW.service" ] && [ -f "$R/deploy/$NEW-backup.service" ] && [ -f "$R/deploy/$NEW-backup.timer" ] && [ ! -e "$R/deploy/$CUR.service" ] && ok "unit files renamed" || bad "unit files"
grep -q "$NEW_MODULE/internal/version" "$R/Makefile" && ok "ldflags use the module path" || bad "Makefile ldflags"
for f in Makefile scripts/deploy.sh web/test/e2e/global-setup.ts; do
  grep -q "$NEW_MODULE/internal/version.BuildID" "$R/$f" && ok "build id ldflag renamed in $f" || bad "BuildID ldflag in $f"
done
grep -q "dist/$NEW" "$R/Makefile" && grep -q "dist/$NEW" "$R/README.md" && ok "binary path dist/$NEW in Makefile and README" || bad "dist/$NEW missing"
[ -z "$(cd "$R" && git grep -n "dist/$CUR")" ] && ok "old binary path dist/$CUR gone" || bad "dist/$CUR remains"
grep -q "${NEW}_session" "$R/web/api/internal/auth/middleware.go" && grep -q "\"$NEW.db\"" "$R/web/api/internal/backup/backup.go" && ok "cookie and database names renamed" || bad "cookie or db name"
grep -q "${NEW_UP}_BIN" "$R/scripts/restore.sh" && ! grep -q "${CUR_UP}_BIN" "$R/scripts/restore.sh" && ok "env var ${NEW_UP}_BIN renamed" || bad "${NEW_UP}_BIN missing"
grep -q "com.$NEW.backup-pull" "$R/scripts/install-backup-agent.sh" && grep -q "Logs/$NEW/" "$R/scripts/install-backup-agent.sh" && grep -q ".config/$NEW/" "$R/scripts/backup-pull.env.example" && grep -q "users:((\"$NEW\"" "$R/scripts/deploy.test.sh" && ok "launchd label, log dir, env file path and ss process name renamed" || bad "launchd/ss contexts"
grep -q "<title>$NEW - " "$R/web/api/internal/web/pages/index.html" && grep -q "<h1>$NEW</h1>" "$R/web/api/internal/web/pages/index.html" && ok "page title and h1 carry the new name" || bad "index.html title/h1"

# The generic word "app" must survive: package app, the composition-root directory, the embed
# directory, the /app/ URL mount, APP_ENV and the shared log file name.
[ -f "$R/web/api/internal/app/app.go" ] && [ -d "$R/web/api/internal/apptest" ] && ok "internal/app and internal/apptest untouched" || bad "internal/app moved"
[ -f "$R/web/api/internal/web/app/.gitkeep" ] && ok "internal/web/app (embed directory) untouched" || bad "embed directory moved"
grep -q "^package app$" "$R/web/api/internal/app/app.go" && grep -q "\"$NEW_MODULE/internal/app\"" "$R/web/api/cmd/$NEW/main.go" && ok "package app and its import path" || bad "package app"
grep -q 'HasPrefix(p, "/app/")' "$R/web/api/internal/web/web.go" && grep -q "go:embed .*all:app" "$R/web/api/internal/web/web.go" && ok "/app/ mount and go:embed all:app untouched" || bad "/app/ mount or embed pattern"
grep -q 'APP_ENV' "$R/web/api/internal/config/config.go" && [ -z "$(cd "$R" && git grep -n "${NEW_UP}_ENV" -- . ':!scripts/rename.test.sh')" ] && ok "APP_ENV is not renamed" || bad "APP_ENV was renamed"
grep -q '"logs", "app.log"' "$R/web/api/internal/config/config.go" && ok "shared app.log name untouched" || bad "app.log"
grep -q 'internal/web/app' "$R/.gitignore" && ok ".gitignore embed path untouched" || bad ".gitignore embed path"
[ -x "$R/scripts/build-id.sh" ] && printf '%s' "$(cd "$R" && BUILD_DATE=20261027 bash scripts/build-id.sh)" | grep -Eq '^20261027-([0-9a-f]{7}|unknown)(-dirty)?$' && ok "build-id.sh works in the renamed copy" || bad "build-id.sh in the renamed copy"
[ -z "$(cd "$R" && git status --porcelain | grep -v '^R \|^RM\|^ M\|^M \|^A ')" ] || bad "unexpected status entries"

# The "generic name" warnings must not turn false: no line that calls things generic may name the new name.
gen="$(cd "$R" && git grep -n -i 'generic' -- README.md CLAUDE.md docs ':!docs/superpowers' | grep -E "(^|[^A-Za-z0-9_])$NEW([^A-Za-z0-9_]|$)"; grep -n -i 'default name is generic' "$R/docs/deploy.md")"
[ -z "$gen" ] && ok "no renamed doc still calls its own name generic" || bad "a doc calls the new name generic: $gen"

# Renaming back must restore the starter byte for byte: the contexts are symmetric and nothing
# else is touched. This also proves a rename from a non-generic name works.
RT="$ROOT/roundtrip"; cp -R "$R" "$RT"
(cd "$RT" && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m renamed && bash scripts/rename.sh "$CUR_MODULE" "$CUR" >/dev/null 2>&1; git add -A)
rootc="$(cd "$RT" && git rev-list --max-parents=0 HEAD | head -1)"
back="$(cd "$RT" && git diff --cached --stat "$rootc" 2>&1)"
[ -z "$back" ] && ok "renaming $NEW back to $CUR restores the starter exactly" || bad "round trip differs: $back"

# The renamed tree must pass its own suites, for names that sort before and after "nginx" (the
# deploy/ listing) and one that contains "app". RENAME_TEST_FULL=1 also runs all of deploy.test.sh.
for W in acme zebra application; do
  X="$ROOT/ren-$W"; cp -R "$BASE" "$X"
  out="$(cd "$X" && bash scripts/rename.sh "example.com/acme/$W" "$W" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && ok "rename to $W" || bad "rename to $W: $out"
  if (cd "$X" && bash scripts/layout.test.sh) >"$ROOT/layout-$W.log" 2>&1; then ok "layout.test.sh passes after renaming to $W"; else bad "layout.test.sh after renaming to $W: $(grep FAIL "$ROOT/layout-$W.log" | head -5)"; fi
  if [ "${RENAME_TEST_FULL:-}" = 1 ]; then only=""; else only='test_smoke_*'; fi
  if (cd "$X" && ONLY="$only" bash scripts/deploy.test.sh) >"$ROOT/deploy-$W.log" 2>&1; then ok "deploy.test.sh ${only:-(all)} passes after renaming to $W"; else bad "deploy.test.sh after renaming to $W: $(grep FAIL "$ROOT/deploy-$W.log" | head -5)"; fi
  if (cd "$X/web/api" && env -u CI go test -short ./... ) >"$ROOT/go-$W.log" 2>&1; then ok "go test -short passes after renaming to $W"; else bad "go test after renaming to $W: $(tail -8 "$ROOT/go-$W.log")"; fi
  # and back, byte for byte
  (cd "$X" && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m renamed && bash scripts/rename.sh "$CUR_MODULE" "$CUR" >/dev/null 2>&1; git add -A)
  back="$(cd "$X" && git diff --cached --stat "$(git rev-list --max-parents=0 HEAD | head -1)" 2>&1)"
  [ -z "$back" ] && ok "$W -> $CUR round trip is exact" || bad "$W round trip differs: $back"
  rm -rf "$X"
done

# A name that contains "app" (the README example) builds too.
MY=myapp; [ "$CUR" = myapp ] && MY=yourapp
M="$ROOT/$MY"; cp -R "$BASE" "$M"
out="$(cd "$M" && bash scripts/rename.sh "github.com/you/$MY" "$MY" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ -d "$M/web/api/cmd/$MY" ] && [ -f "$M/web/api/internal/app/app.go" ] && ok "rename to $MY" || bad "rename to $MY (rc=$rc): $out"
if command -v go >/dev/null 2>&1; then
  if (cd "$M/web/api" && go build ./... ) >"$ROOT/go-my.log" 2>&1; then ok "$MY copy builds"; else bad "$MY copy build: $(tail -10 "$ROOT/go-my.log")"; fi
fi

if command -v go >/dev/null 2>&1; then
  # The copy has no frontend build (it is gitignored), so the embed tests must skip
  # here even on a CI runner, where CI=true would turn the skip into a failure.
  if (cd "$R/web/api" && go build ./... && go vet ./... && env -u CI go test -short ./... ) >"$ROOT/go.log" 2>&1; then ok "go build, vet and test -short pass in the copy"; else bad "go checks in the copy: $(tail -20 "$ROOT/go.log")"; fi
else skip "go not on PATH"; fi

if command -v pnpm >/dev/null 2>&1; then
  if (cd "$R" && bash scripts/gen-api.test.sh) >"$ROOT/gen.log" 2>&1; then ok "gen-api.test.sh passes in the copy (generated files consistent)"; else bad "gen-api.test.sh in the copy: $(tail -20 "$ROOT/gen.log")"; fi
else skip "pnpm not on PATH: gen-api.test.sh not run in the copy"; fi

# The layout guard must pass in a renamed app too (renaming changes the sort order of deploy/).
if (cd "$R" && bash scripts/layout.test.sh) >"$ROOT/layout.log" 2>&1; then ok "layout.test.sh passes in the renamed copy"; else bad "layout.test.sh in the copy: $(grep FAIL "$ROOT/layout.log" | head -5)"; fi

if [ "${RENAME_TEST_FULL:-}" = 1 ]; then
  if (cd "$R" && bash scripts/deploy.test.sh) >"$ROOT/deploy.log" 2>&1; then ok "scripts/deploy.test.sh passes in the copy"; else bad "scripts/deploy.test.sh in the copy: $(tail -20 "$ROOT/deploy.log")"; fi
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
