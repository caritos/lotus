#!/usr/bin/env bash
# Guards the repository layout: one scripts/ directory for every repo-level script and its test,
# deploy/ only for files installed on a server, Playwright under web/test/e2e/, and no stale
# references to the old locations. Run: bash scripts/layout.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO" || exit 2

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }

# deploy/ holds no shell scripts.
sh_in_deploy="$(ls deploy/*.sh 2>/dev/null)"
[ -z "$sh_in_deploy" ] && ok "deploy/ contains no *.sh" || bad "deploy/ still has scripts: $sh_in_deploy"

# deploy/ holds exactly the files installed or copied to a server.
want="goweb-backup.service goweb-backup.timer goweb.service nginx.conf.example"
have="$(cd deploy 2>/dev/null && ls | tr '\n' ' ' | sed 's/ $//')"
[ "$have" = "$want" ] && ok "deploy/ holds only server files" || bad "deploy/ is '$have', want '$want'"

# The repo-level scripts live in scripts/.
missing=""
for f in deploy.sh smoke.sh restore.sh pull-backups.sh deploy.test.sh build-id.sh rename.sh; do
  [ -f "scripts/$f" ] || missing="$missing $f"
done
[ -z "$missing" ] && ok "scripts/ holds the deploy, smoke, restore, pull-backups scripts and their test" || bad "missing from scripts/:$missing"

# Every test script is named *.test.sh (any script whose name says "test" must end in .test.sh).
badnames="$(ls scripts/ | grep -i 'test' | grep -v '\.test\.sh$')"
[ -z "$badnames" ] && ok "every test script in scripts/ ends in .test.sh" || bad "badly named test scripts: $badnames"

# Playwright lives under web/test/e2e/.
[ ! -e web/e2e ] && ok "web/e2e does not exist" || bad "web/e2e still exists"
[ -f web/test/e2e/playwright.config.ts ] && ok "web/test/e2e/playwright.config.ts exists" || bad "web/test/e2e/playwright.config.ts missing"
[ -f web/test/README.md ] && ok "web/test/README.md exists" || bad "web/test/README.md missing"

# node_modules is ignored at any depth and never tracked.
ign=1
for p in web/node_modules/x node_modules/x web/test/e2e/node_modules/x; do git check-ignore -q "$p" || ign=0; done
[ "$ign" -eq 1 ] && ok "node_modules/ is ignored at any depth" || bad ".gitignore does not ignore node_modules at any depth"
[ "$(git ls-files | grep -c node_modules)" -eq 0 ] && ok "no tracked node_modules files" || bad "node_modules files are tracked"

# No stale references to the old paths anywhere tracked (historical specs and this file excepted).
stale="$(git grep -nE 'web/e2e|deploy/(deploy|smoke|restore|pull-backups|test)\.sh|deploy/test\b' -- . ':!docs/superpowers' ':!scripts/layout.test.sh' 2>/dev/null)"
[ -z "$stale" ] && ok "no stale references to the old paths" || bad "stale references:"$'\n'"$stale"

echo "layout.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
