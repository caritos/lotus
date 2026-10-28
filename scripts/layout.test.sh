#!/usr/bin/env bash
# Guards the repository layout: one scripts/ directory for every repo-level script and its test,
# deploy/ only for files installed on a server, Playwright under web/test/e2e/, and no stale
# references to the old locations. Run: bash scripts/layout.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO" || exit 2

# Host mode: .goweb-origin at the root (written by the wrapper that turns goweb into an app) means the app
# was created inside a host repo that has its own ios/ and root CLAUDE.md. The starter-only checks (the
# ios/ placeholder, goweb's own root CLAUDE.md headings) are skipped then; every structural check stays on.
# The marker name and the starter's README title are built from two pieces on purpose: scripts/rename.sh
# rewrites every "goweb" in the tree, and these two strings must keep meaning what the wrapper writes
# (.goweb-origin) and what the unrenamed starter says ("# goweb") in a renamed app too.
MARKER=".go""web-origin"
STARTER_TITLE="# go""web"
HOST=0
[ -e "$MARKER" ] && HOST=1

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }

# The marker is for apps created from the starter. If the root README still starts with "# goweb" this is
# the starter itself (or an unrenamed copy), and the marker must not switch its starter-only checks off.
if [ "$HOST" -eq 1 ] && [ "$(head -n 1 README.md 2>/dev/null)" = "$STARTER_TITLE" ]; then
  bad "$MARKER present in the starter itself; host mode is only for apps created from it"
  HOST=0
fi

# deploy/ holds no shell scripts.
sh_in_deploy="$(ls deploy/*.sh 2>/dev/null)"
[ -z "$sh_in_deploy" ] && ok "deploy/ contains no *.sh" || bad "deploy/ still has scripts: $sh_in_deploy"

# deploy/ holds exactly the files installed or copied to a server.
# Compared as sorted sets: renaming the app (goweb -> <name>) changes the `ls` order.
want="$(printf '%s\n' goweb-backup.service goweb-backup.timer goweb.service nginx.conf.example | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
have="$(cd deploy 2>/dev/null && ls | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
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
# Starter only: a host repo owns its own ios/.
if [ "$HOST" -eq 1 ]; then
  ok "host mode (.goweb-origin): ios/ placeholder checks skipped"
else
  [ -n "$(git ls-files ios)" ] && ok "ios/ is reserved at the repo root and tracked" || bad "ios/ has no tracked file"
  if [ -f ios/README.md ] || [ -f ios/Package.swift ]; then ok "ios/ has a README (placeholder) or a scaffolded Package.swift"; else bad "ios/ has neither README.md nor Package.swift"; fi
fi

# Migrations are checksummed over their exact bytes, so git must never rewrite their line endings.
attr="$(git check-attr text -- web/api/internal/db/migrations/0001_init.sql)"
case "$attr" in *": text: unset") ok "*.sql is -text (autocrlf cannot alter migration bytes)" ;; *) bad "*.sql is not marked -text in .gitattributes (got: $attr)" ;; esac

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
git check-ignore -q dist/goweb && ok ".gitignore ignores dist/goweb" || bad ".gitignore does not ignore dist/goweb"
[ -z "$(git ls-files goweb)" ] && ok "no tracked root file named goweb" || bad "a root file named goweb is tracked"
grep -E '^[[:space:]]*cd web/api && go build' Makefile | grep -q 'dist/' && ok "Makefile build target writes under dist/" || bad "Makefile build target does not mention dist/"

# Stale references to the old locations, outside docs/superpowers (historical specs) and this
# file. The dated entries under "### Done" in goweb's log are history and exempt; everything else,
# including the rest of that file, is current-state text and covered. The log is in CLAUDE.md, or in
# web/CLAUDE.md when the app lives in a host repo (host mode only; both files are exempt for their own Done section).
SCRIPT_RE='(deploy|smoke|restore|pull-backups)\.sh'
stale_report() {
  {
    git grep -nE 'web/e2e' -- . ':!docs/superpowers' ':!scripts/layout.test.sh'
    git grep -nE "deploy/($SCRIPT_RE|test([^A-Za-z]|$)|\*\.sh)|(^|[^A-Za-z0-9_/])(cd|bash|sh) +\.?/?deploy( |/|\$)|(^|[^.])\./deploy|\.\./deploy( |/$|/\*|/($SCRIPT_RE)|\`|\$)" -- . ':!docs/superpowers' ':!scripts/layout.test.sh'
    # bare script name on a line that also names deploy/ (unless it is clearly about scripts/)
    git grep -nE "(^|[^A-Za-z0-9_/])deploy/" -- . ':!docs/superpowers' ':!scripts/layout.test.sh' |
      grep -E "$SCRIPT_RE" | grep -v 'scripts/'
  } 2>/dev/null | sort -u | awk -F: -v ranges="$DONE_RANGES" 'BEGIN { n = split(ranges, r, " ") }
      { for (i = 1; i <= n; i++) { split(r[i], x, ","); if ($1 == x[1] && $2 > x[2] && $2 < x[3]) next } print }'
}
# DONE_RANGES: "file,first,last" triples, one per goweb log: the lines strictly between its "### Done"
# heading and the next "### " heading (or the end of the file). In host mode both the host's root CLAUDE.md
# and goweb's moved web/CLAUDE.md may have a log; each file's own Done section is exempt, the rest of both
# stays checked.
DONE_RANGES=""
done_range() { # <file>: print "file,start,end" when the file has a Done section
  local f="$1" st en total
  st="$(grep -n '^### Done' "$f" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$st" ] || return 1
  total="$(wc -l < "$f" | tr -d ' ')"
  en="$(awk -v s="$st" 'NR>s && /^### / {print NR; exit}' "$f")"
  printf '%s,%s,%s' "$f" "$st" "${en:-$((total + 2))}"
}
if r="$(done_range CLAUDE.md)"; then DONE_RANGES="$r"; fi
if [ "$HOST" -eq 1 ] && r="$(done_range web/CLAUDE.md)"; then DONE_RANGES="$DONE_RANGES $r"; fi
if [ "$HOST" -eq 0 ]; then
  if grep -q '^### Done' CLAUDE.md 2>/dev/null && grep -q '^### Not yet verified' CLAUDE.md 2>/dev/null; then
    ok "CLAUDE.md has the Done section markers"
  else
    bad "CLAUDE.md lost its '### Done' / '### Not yet verified' headings"
  fi
elif [ -n "$DONE_RANGES" ]; then
  ok "host mode: Done sections exempt in:$(for x in $DONE_RANGES; do printf ' %s' "${x%%,*}"; done)"
else
  ok "host mode: no goweb log with a Done section found; nothing exempt"
fi
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
  expect_pass "a /home/deploy/ path" README.md 'DIR=/home/deploy/goweb/data/backups'
  expect_pass "a file named like node_modules_notes" docs/node_modules_notes.md 'x'
  make_copy && mkdir -p "$WORK/c/web/node_modules" && echo x > "$WORK/c/web/node_modules/x" && git -C "$WORK/c" add -f web/node_modules/x
  inner && bad "guard did not flag a tracked node_modules file" || ok "guard flags a tracked node_modules file"
  # deploy/ must hold exactly the expected files: an extra and a missing one both fail
  # The failure must come from the deploy/ check itself ("deploy/ is ..."), not from some other check.
  inner_out() { (cd "$WORK/c" && LAYOUT_TEST_INNER=1 bash scripts/layout.test.sh 2>&1); }
  make_copy && echo x > "$WORK/c/deploy/extra.txt" && git -C "$WORK/c" add -A
  if out="$(inner_out)"; then bad "guard did not flag an extra file in deploy/"; elif printf '%s\n' "$out" | grep -q 'FAIL - deploy/ is'; then ok "guard flags an extra file in deploy/"; else bad "extra file in deploy/ failed for another reason"; fi
  make_copy && rm "$WORK/c/deploy/nginx.conf.example" && git -C "$WORK/c" add -A
  if out="$(inner_out)"; then bad "guard did not flag a missing file in deploy/"; elif printf '%s\n' "$out" | grep -q 'FAIL - deploy/ is'; then ok "guard flags a missing file in deploy/"; else bad "missing file in deploy/ failed for another reason"; fi
  make_copy && rm "$WORK/c/.gitattributes" && git -C "$WORK/c" add -A
  if out="$(inner_out)"; then bad "guard did not flag a missing .gitattributes"; elif printf '%s\n' "$out" | grep -q 'FAIL - \*.sql is not marked -text'; then ok "guard flags a missing .gitattributes"; else bad "missing .gitattributes failed for another reason"; fi
  # Host mode: the app lives inside a host repo (the wrapper writes .goweb-origin, and moves goweb's
  # CLAUDE.md to web/CLAUDE.md when the host already has a root one). Starter-only checks are skipped,
  # goweb itself (no .goweb-origin) stays fully guarded.
  make_host() { # [with-origin] [host-log]: host-log gives the host's root CLAUDE.md its own Done log
    make_copy || return 1
    ( cd "$WORK/c" && git rm -qf ios/README.md && mkdir -p ios && echo "// host app" > ios/App.swift \
      && git mv CLAUDE.md web/CLAUDE.md && printf '# Host repo\n\nNo goweb headings here.\n' > CLAUDE.md \
      && sed -i.bak '1s/.*/# Host app/' README.md && rm -f README.md.bak ) || return 1
    if [ "${2:-}" = host-log ]; then
      printf '\n### Done\n\n- host work\n\n### Not yet verified on device\n\n- host thing\n' >> "$WORK/c/CLAUDE.md"
    fi
    if [ "${1:-}" = with-origin ]; then echo 0123456789abcdef > "$WORK/c/$MARKER"; fi
    git -C "$WORK/c" add -A
  }
  add_to_done() { # <file in the copy>: put an old path inside that file's first Done section
    awk '{print} /^### Done/ && !d {print "- old entry mentions web/e2e/ and deploy/deploy.sh"; d=1}' "$WORK/c/$1" > "$WORK/claude.new" && cp "$WORK/claude.new" "$WORK/c/$1" && git -C "$WORK/c" add -A
  }
  # Both logs: the host's own root log AND goweb's moved log at web/CLAUDE.md.
  make_host with-origin host-log
  if out="$(inner_out)"; then ok "host layout with its own Done log in CLAUDE.md and goweb's in web/CLAUDE.md passes"; else bad "host with two logs fails: $(printf '%s\n' "$out" | grep -A3 FAIL)"; fi
  make_host with-origin host-log && add_to_done CLAUDE.md && add_to_done web/CLAUDE.md
  if out="$(inner_out)"; then ok "host mode exempts the Done section of EACH log"; else bad "host mode flags a Done section: $(printf '%s\n' "$out" | grep -A3 FAIL)"; fi
  make_host with-origin host-log && printf '%s\n' 'web/e2e/ holds Playwright' >> "$WORK/c/web/CLAUDE.md" && git -C "$WORK/c" add -A
  if out="$(inner_out)"; then bad "two-log host mode missed a stale path outside the Done sections"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "two-log host mode still flags a stale path outside the Done sections"; else bad "two-log stale path failed for another reason"; fi
  # The marker must not turn goweb itself into a host.
  make_copy && printf '%s\n' "$STARTER_TITLE" > "$WORK/c/README.md" && echo 0123456789abcdef > "$WORK/c/$MARKER"
  if out="$(inner_out)"; then bad "guard accepted the marker in the starter itself"; elif printf '%s\n' "$out" | grep -qF "FAIL - $MARKER present in the starter itself; host mode is only for apps created from it"; then ok "guard fails loudly on .goweb-origin in the starter itself"; else bad "marker in the starter failed for another reason"; fi
  make_host with-origin
  if out="$(inner_out)"; then ok "host layout with .goweb-origin passes (no ios README, host CLAUDE.md, goweb's at web/CLAUDE.md)"; else bad "host layout with .goweb-origin fails: $(printf '%s\n' "$out" | grep FAIL)"; fi
  make_host
  if out="$(inner_out)"; then bad "host layout WITHOUT .goweb-origin passed (goweb itself must stay guarded)"
  elif printf '%s\n' "$out" | grep -q 'FAIL - ios/ has neither' && printf '%s\n' "$out" | grep -q "FAIL - CLAUDE.md lost its"; then ok "host layout without .goweb-origin fails on the ios/ and CLAUDE.md checks"
  else bad "host layout without .goweb-origin failed for the wrong reasons: $(printf '%s\n' "$out" | grep FAIL)"; fi
  make_host with-origin && printf '%s\n' 'web/e2e/ holds Playwright' >> "$WORK/c/web/CLAUDE.md" && git -C "$WORK/c" add -A
  if out="$(inner_out)"; then bad "host mode missed a stale path in web/CLAUDE.md"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "host mode flags a stale path in web/CLAUDE.md outside the Done section"; else bad "stale path in web/CLAUDE.md failed for another reason"; fi
  make_host with-origin
  awk '{print} /^### Done/ && !d {print "- old entry mentions web/e2e/ and deploy/deploy.sh"; d=1}' "$WORK/c/web/CLAUDE.md" > "$WORK/claude.new" && cp "$WORK/claude.new" "$WORK/c/web/CLAUDE.md" && git -C "$WORK/c" add -A
  inner && ok "host mode allows old paths inside the Done section of web/CLAUDE.md" || bad "host mode flags the Done section of web/CLAUDE.md"
  # an old path inside a dated Done entry of CLAUDE.md is history and allowed
  make_copy && awk '{print} /^### Done/ && !d {print "- old entry mentions web/e2e/ and deploy/deploy.sh"; d=1}' CLAUDE.md > "$WORK/claude.new" && cp "$WORK/claude.new" "$WORK/c/CLAUDE.md" && git -C "$WORK/c" add -A
  inner && ok "guard allows old paths inside the Done section of CLAUDE.md" || bad "guard flags the Done section of CLAUDE.md"
fi

echo "layout.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
