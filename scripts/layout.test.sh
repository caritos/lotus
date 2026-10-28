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
want="app-backup.service app-backup.timer app.service nginx.conf.example"
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

# ios/ is reserved at the repo root for the native app and stays tracked (git keeps no empty directories).
[ -n "$(git ls-files ios)" ] && ok "ios/ is reserved at the repo root and tracked" || bad "ios/ has no tracked file"
[ -f ios/README.md ] || [ -f ios/Package.swift ] && ok "ios/ has a README (placeholder) or a scaffolded Package.swift" || bad "ios/ has neither README.md nor Package.swift"

# Build outputs and node_modules are ignored at any depth; nothing tracked is ignored.
ign=1
for p in web/node_modules/x node_modules/x web/test/e2e/node_modules/x \
         web/test/e2e/test-results/x web/test/e2e/playwright-report/x; do
  git check-ignore -q "$p" || { ign=0; echo "  not ignored: $p"; }
done
[ "$ign" -eq 1 ] && ok "node_modules/ and the e2e outputs are ignored" || bad ".gitignore misses node_modules or the e2e output directories"
nm="$(git ls-files | grep -E '(^|/)node_modules(/|$)')"
[ -z "$nm" ] && ok "no tracked node_modules directory" || bad "node_modules tracked: $nm"
tracked_ignored="$(git ls-files -ci --exclude-standard)"
[ -z "$tracked_ignored" ] && ok "no tracked file is ignored" || bad "tracked but ignored: $tracked_ignored"

# The compiled binary goes to dist/ (ignored); nothing named like the binary is tracked at the root.
git check-ignore -q dist/app && ok ".gitignore ignores dist/app" || bad ".gitignore does not ignore dist/app"
[ -z "$(git ls-files app)" ] && ok "no tracked root file named app" || bad "a root file named app is tracked"
grep -E '^[[:space:]]*cd web/api && go build' Makefile | grep -q 'dist/' && ok "Makefile build target writes under dist/" || bad "Makefile build target does not mention dist/"

# Stale references to the old locations, outside docs/superpowers (historical specs) and this
# file. The dated entries under "### Done" in CLAUDE.md are history and exempt; everything else,
# including the rest of CLAUDE.md, is current-state text and covered.
SCRIPT_RE='(deploy|smoke|restore|pull-backups)\.sh'
stale_report() {
  {
    git grep -nE 'web/e2e' -- . ':!docs/superpowers' ':!scripts/layout.test.sh'
    git grep -nE "deploy/($SCRIPT_RE|test([^A-Za-z]|$)|\*\.sh)|(^|[^A-Za-z0-9_/])(cd|bash|sh) +\.?/?deploy( |/|\$)|(^|[^.])\./deploy|\.\./deploy( |/$|/\*|/($SCRIPT_RE)|\`|\$)" -- . ':!docs/superpowers' ':!scripts/layout.test.sh'
    # bare script name on a line that also names deploy/ (unless it is clearly about scripts/)
    git grep -nE "(^|[^A-Za-z0-9_/])deploy/" -- . ':!docs/superpowers' ':!scripts/layout.test.sh' |
      grep -E "$SCRIPT_RE" | grep -v 'scripts/'
  } 2>/dev/null | sort -u | awk -F: -v s="$done_start" -v e="$done_end" '!($1=="CLAUDE.md" && $2>s && $2<e)'
}
done_start="$(grep -n '^### Done' CLAUDE.md | head -1 | cut -d: -f1)"
done_end="$(grep -n '^### Not yet verified' CLAUDE.md | head -1 | cut -d: -f1)"
[ -n "$done_start" ] && [ -n "$done_end" ] && ok "CLAUDE.md has the Done section markers" || { bad "CLAUDE.md lost its '### Done' / '### Not yet verified' headings"; done_start=0; done_end=0; }
stale="$(stale_report)"
[ -z "$stale" ] && ok "no stale references to the old paths" || bad "stale references:"$'\n'"$stale"

# The guard must itself fail on each stale pattern. Runs this test in a throwaway copy of the
# tracked files with one line injected (never the real tree); skipped inside that copy.
if [ -z "${LAYOUT_TEST_INNER:-}" ]; then
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  make_copy() {
    rm -rf "$WORK/c"; mkdir -p "$WORK/c"
    git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$WORK/c" || return 1
    (cd "$WORK/c" && git init -q && git add -A) || return 1
  }
  inner() { (cd "$WORK/c" && LAYOUT_TEST_INNER=1 bash scripts/layout.test.sh >/dev/null 2>&1); }
  expect_fail() { # <label> <file> <line>
    make_copy && printf '%s\n' "$3" >> "$WORK/c/$2" && git -C "$WORK/c" add -A
    if inner; then bad "guard did not flag: $1"; else ok "guard flags: $1"; fi
  }
  expect_pass() {
    make_copy && printf '%s\n' "$3" >> "$WORK/c/$2" && git -C "$WORK/c" add -A
    if inner; then ok "guard allows: $1"; else bad "guard wrongly flags: $1"; fi
  }
  make_copy && { inner && ok "guard passes on an untouched copy" || bad "guard fails on an untouched copy"; }
  expect_fail "web/e2e path" README.md 'see web/e2e/foo.spec.ts'
  expect_fail "deploy/deploy.sh" README.md 'run deploy/deploy.sh now'
  expect_fail "deploy/test.sh" README.md 'run deploy/test.sh now'
  expect_fail "deploy/*.sh glob" README.md 'shellcheck deploy/*.sh'
  expect_fail "cd deploy" README.md 'cd deploy && ls'
  expect_fail "bash deploy/" README.md 'bash deploy/x'
  expect_fail "./deploy" README.md 'run ./deploy/x'
  expect_fail "../deploy/smoke.sh" README.md 'source ../deploy/smoke.sh'
  expect_fail "../deploy/*.sh" README.md 'ls ../deploy/*.sh'
  expect_fail "bare script names beside deploy/" README.md '- `deploy/`: units, `deploy.sh`, `smoke.sh`, NGINX example'
  expect_fail "stale path in current-state text of CLAUDE.md" CLAUDE.md 'web/e2e/ holds Playwright'
  expect_pass "scripts/ path beside deploy/" README.md '- `deploy/` units; `scripts/deploy.sh` and `scripts/smoke.sh`'
  expect_pass "link to a file in deploy/" README.md 'see [x](../deploy/nginx.conf.example)'
  expect_pass "a /home/deploy/ path" README.md 'DIR=/home/deploy/app/data/backups'
  expect_pass "a file named like node_modules_notes" docs/node_modules_notes.md 'x'
  make_copy && mkdir -p "$WORK/c/web/node_modules" && echo x > "$WORK/c/web/node_modules/x" && git -C "$WORK/c" add -f web/node_modules/x
  inner && bad "guard did not flag a tracked node_modules file" || ok "guard flags a tracked node_modules file"
  # an old path inside a dated Done entry of CLAUDE.md is history and allowed
  make_copy && awk '{print} /^### Done/ && !d {print "- old entry mentions web/e2e/ and deploy/deploy.sh"; d=1}' CLAUDE.md > "$WORK/claude.new" && cp "$WORK/claude.new" "$WORK/c/CLAUDE.md" && git -C "$WORK/c" add -A
  inner && ok "guard allows old paths inside the Done section of CLAUDE.md" || bad "guard flags the Done section of CLAUDE.md"
fi

echo "layout.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
