#!/usr/bin/env bash
# Guards the repository layout: everything that belongs to the web platform lives under web/
# (web/scripts, web/deploy, web/docs, web/test/e2e, web/Makefile, web/dist), the repo root keeps only
# cross-platform files (README, CLAUDE, AGENTS, .github, .claude, ios, docs/superpowers) and no file
# refers to the old locations. Run: bash web/scripts/layout.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || exit 2

# The project name, read from the command directory so this test survives web/scripts/rename.sh.
NAME="$(ls web/api/cmd 2>/dev/null | head -1)"

# Host mode: the wrapper marker at the root (written by the external wrapper that turns the starter
# into an app) means the app was created inside a host repo that has its own ios/ and root
# CLAUDE.md. The starter-only checks (the ios/ placeholder, the starter's own root CLAUDE.md
# headings) are skipped then; every structural check stays on.
# MARKER is the wrapper's contract, NOT the project name: the wrapper writes this fixed file name
# whatever the project is called, so it must keep matching after web/scripts/rename.sh. It is built from
# two pieces so that rename.sh (which rewrites the project name in every tracked file) cannot
# change it.
MARKER=".lo""tus-origin"
# The starter is recognised by its shipped name and README title, also built from two pieces so that
# rename.sh leaves them alone (they must keep meaning "the unrenamed starter" in a renamed app).
# A renamed app has another name in web/api/cmd/ (and usually "# <Display Name>" as README title).
STARTER_NAME="a""pp"
STARTER_TITLE="# $STARTER_NAME"
HOST=0
[ -e "$MARKER" ] && HOST=1

pass=0; fail=0; skipped=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }
skip() { skipped=$((skipped+1)); echo "SKIPPED: $1"; }

# The marker is for apps created from the starter. The starter itself is recognised by BOTH its shipped
# project name (the directory in web/api/cmd/) and its README title; an app renamed with web/scripts/rename.sh
# has another cmd/ name, so it is accepted even if its README still says the starter title. In the starter
# the marker must not switch the starter-only checks off.
if [ "$HOST" -eq 1 ] && [ "$NAME" = "$STARTER_NAME" ] && [ "$(head -n 1 README.md 2>/dev/null | tr -d '\r')" = "$STARTER_TITLE" ]; then
  bad "$MARKER present in the starter itself; host mode is only for apps created from it"
  # Stop here: every later check (and every self-test copy, which inherits the marker) would only
  # repeat this failure.
  echo "layout.test.sh: $pass passed, $fail failed"; echo "SKIPPED: $skipped"
  exit 1
fi

# Compares a directory listing (dotfiles included) with the expected names as sorted sets.
# Sets, not `ls` order: renaming the app changes the order of the unit files.
sorted_set() { LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
check_set() { # <dir> <label> <want...>
  local dir="$1" label="$2"; shift 2
  local want have
  want="$(printf '%s\n' "$@" | sorted_set)"
  have="$(cd "$dir" 2>/dev/null && ls -A | sorted_set)"
  [ "$have" = "$want" ] && ok "$label holds exactly its expected files" || bad "$label is '$have', want '$want'"
}

# The repo root holds only the cross-platform entries. Starter only: a host repo owns its own root.
# Read from git (what is tracked), so ignored local files such as dist/ or .superpowers/ do not count.
if [ "$HOST" -eq 0 ]; then
  have_root="$(git ls-files | cut -d/ -f1 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
  want_root="$(printf '%s\n' .claude .gitattributes .github .gitignore AGENTS.md CLAUDE.md README.md docs ios web | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$have_root" = "$want_root" ] && ok "the repo root holds only README, CLAUDE, AGENTS, .github, .claude, ios, docs and web" || bad "repo root is '$have_root', want '$want_root'"
else
  ok "host mode ($MARKER): the host owns the repo root; root entries not checked"
fi
if [ "$HOST" -eq 0 ]; then
  for old in deploy scripts Makefile dist .env.example .nvmrc; do
    [ ! -e "$old" ] && ok "no root $old (it lives under web/)" || bad "root $old still exists"
  done
fi
if [ -d docs ]; then
  have_docs="$(ls -A docs | sorted_set)"
  { [ "$have_docs" = "superpowers" ] || [ "$have_docs" = "logo.jpg superpowers" ]; } \
    && ok "docs/ holds only superpowers/ (design history) and the starter's logo.jpg" \
    || bad "docs/ is '$have_docs', want 'superpowers' (optionally with logo.jpg)"
else
  ok "docs/ absent (only superpowers/ and logo.jpg may live there)"
fi

# web/scripts/ holds every script and its test. deploy-app.sh is the Mac-side wrapper that the
# external new-web-app skill generates next to deploy.sh; it is allowed, not required.
WS=(backup-pull.env.example build-id.sh build-id.test.sh clean-app.mjs clean-app.test.ts deploy.sh deploy.test.sh gen-api-preflight.test.sh gen-api.sh gen-api.test.sh install-backup-agent.sh layout.test.sh pull-backups.sh rename.sh rename.test.sh restore.sh smoke.sh)
if [ -f web/scripts/deploy-app.sh ]; then WS+=(deploy-app.sh); fi
check_set web/scripts "web/scripts/" "${WS[@]}"

# web/deploy/ holds exactly the files installed or copied to a server (no shell scripts).
check_set web/deploy "web/deploy/" .env.example "$NAME-backup.service" "$NAME-backup.timer" "$NAME.service" nginx.conf.example

# web/docs/ holds the web docs.
check_set web/docs "web/docs/" backups.md deploy.md https.md testing.md

# Every test script is named *.test.sh (or *.test.ts for Vitest).
badnames="$(ls web/scripts/ | grep -i 'test' | grep -v '\.test\.\(sh\|ts\)$')"
[ -z "$badnames" ] && ok "every test script in web/scripts/ ends in .test.sh or .test.ts" || bad "badly named test scripts: $badnames"

# Playwright lives under web/test/e2e/.
[ ! -e web/e2e ] && ok "web/e2e does not exist" || bad "web/e2e still exists"
[ -f web/test/e2e/playwright.config.ts ] && ok "web/test/e2e/playwright.config.ts exists" || bad "web/test/e2e/playwright.config.ts missing"
[ -f web/test/README.md ] && ok "web/test/README.md exists" || bad "web/test/README.md missing"

# ios/ is reserved at the repo root for the native app and stays tracked (git keeps no empty directories).
# Starter only: a host repo owns its own ios/.
if [ "$HOST" -eq 1 ]; then
  ok "host mode ($MARKER): ios/ placeholder checks skipped; ios/ and android/ are not scanned for stale paths"
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
git check-ignore -q "web/dist/$NAME" && ok ".gitignore ignores web/dist/$NAME" || bad ".gitignore does not ignore web/dist/$NAME"
[ -z "$(git ls-files "$NAME" "web/$NAME")" ] && ok "no tracked file named $NAME at the root or in web/" || bad "a file named $NAME is tracked at the root or in web/"
grep -E '^[[:space:]]*cd api && go build' web/Makefile | grep -q 'dist/' && ok "web/Makefile build target writes under dist/" || bad "web/Makefile build target does not mention dist/"

# Stale references to the old locations, outside docs/superpowers (historical specs) and this
# file. The dated entries under "### Done" in the starter's log are history and exempt; everything else,
# including the rest of that file, is current-state text and covered. The log is in CLAUDE.md, or in
# web/CLAUDE.md when the app lives in a host repo (host mode only; both files are exempt for their own Done section).
# A path counts as old when it is written without the web/ (or any other directory) prefix in front of it.
NOPFX='(^|[^A-Za-z0-9_./-])'
# In host mode the repo also holds the host's own trees, which the starter does not own and must not police:
# ios/ (new-ios-app scripts say "./deploy.sh" in their usage comments) and android/. In the starter itself
# they are scanned like everything else.
# web/Makefile and web/package.json run inside web/, so they legitimately say scripts/ and dist/.
EXCL=(':!docs/superpowers' ':!.claude/skills' ':!web/scripts/layout.test.sh' ':!web/Makefile' ':!web/package.json')
if [ "$HOST" -eq 1 ]; then EXCL+=(':!ios' ':!android'); fi
stale_report() {
  {
    git grep -nE 'web/e2e' -- . "${EXCL[@]}"
    # scripts, deploy files, docs and the binary written without web/ in front of them
    git grep -nE "${NOPFX}scripts/(deploy|deploy-app|smoke|restore|pull-backups|install-backup-agent|gen-api|gen-api-preflight|rename|build-id|layout|backup-pull|clean-app)[.a-z-]*" -- . "${EXCL[@]}"
    git grep -nE "${NOPFX}deploy/(\\.env|nginx|[A-Za-z0-9_-]+\\.(service|timer))" -- . "${EXCL[@]}"
    git grep -nE "${NOPFX}dist/(app|$NAME)([^A-Za-z0-9_]|\$)|[ \`(=:]\\.(/deploy|/scripts/|/dist/)|(cd|bash|sh) +(deploy|scripts)( |/|\$)" -- . "${EXCL[@]}"
    git grep -nE "${NOPFX}docs/(deploy|https|backups|testing)\\.md" -- . "${EXCL[@]}"
    git grep -nE "${NOPFX}\\.env\\.example" -- . "${EXCL[@]}"
    # the binary now lives in dist/: a root binary reference such as `./<name> serve`
    git grep -nE "(^|[^A-Za-z0-9_./-])\\./$NAME(\$|[^A-Za-z0-9_/.-]|\\.([^A-Za-z]|\$))" -- README.md AGENTS.md CLAUDE.md 'web/docs/*.md' ':!docs/superpowers'
  } 2>/dev/null | sort -u | awk -F: -v ranges="$DONE_RANGES" 'BEGIN { n = split(ranges, r, " ") }
      { for (i = 1; i <= n; i++) { split(r[i], x, ","); if ($1 == x[1] && $2 > x[2] && $2 < x[3]) next } print }'
}
# DONE_RANGES: "file,first,last" triples, one per starter log: the lines strictly between its "### Done"
# heading and the next "## " or "### " heading (or the end of the file). In host mode both the host's root CLAUDE.md
# and the starter's moved web/CLAUDE.md may have a log; each file's own Done section is exempt, the rest of both
# stays checked.
DONE_RANGES=""
done_range() { # <file>: print "file,start,end" when the file has a Done section
  local f="$1" st en total
  st="$(grep -n '^### Done' "$f" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$st" ] || return 1
  total="$(wc -l < "$f" | tr -d ' ')"
  en="$(awk -v s="$st" 'NR>s && /^###? / {print NR; exit}' "$f")"
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
  ok "host mode: no starter log with a Done section found; nothing exempt"
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
  inner() { (cd "$WORK/c" && LAYOUT_TEST_INNER=1 bash web/scripts/layout.test.sh >/dev/null 2>&1); }
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
  expect_fail "scripts/deploy.sh without web/" README.md 'run scripts/deploy.sh now'
  expect_fail "scripts/rename.sh without web/" README.md 'run bash scripts/rename.sh x y'
  expect_fail "scripts/backup-pull.env.example without web/" README.md 'edit scripts/backup-pull.env.example'
  expect_pass "web/scripts/deploy.sh" README.md 'run web/scripts/deploy.sh now'
  expect_fail "deploy/ without web/" README.md 'see deploy/app.service'
  expect_fail "cd deploy" README.md 'cd deploy && ls'
  expect_fail "bash deploy" README.md 'bash deploy/x'
  expect_fail "./deploy" README.md 'run ./deploy/x'
  expect_fail "./scripts" README.md 'run ./scripts/x'
  expect_fail "dist/ without web/" README.md 'the binary is dist/app'
  expect_pass "web/dist/app" README.md 'the binary is web/dist/app'
  expect_pass "web/deploy/ path" README.md 'see web/deploy/app.service'
  expect_fail "root docs/deploy.md" README.md 'read docs/deploy.md first'
  expect_fail "root docs/testing.md" README.md 'see [t](docs/testing.md)'
  expect_pass "web/docs/deploy.md" README.md 'read web/docs/deploy.md first'
  expect_fail ".env.example without web/deploy/" README.md 'copy .env.example to the server'
  expect_pass "web/deploy/.env.example" README.md 'copy web/deploy/.env.example to the server'
  expect_pass "backup-pull.env.example in web/scripts" README.md 'edit web/scripts/backup-pull.env.example'
  # The skills under .claude/skills/ describe other trees (scripts say "./deploy.sh"): exempt like docs/superpowers.
  expect_pass "an old-style path inside .claude/skills/" .claude/skills/new-ios-app/SKILL.md 'run ./deploy.sh or scripts/deploy.sh or deploy/app.service or web/e2e/x'
  expect_fail "the same line in .claude/hooks (only skills are exempt)" .claude/hooks/post-edit.sh 'run scripts/deploy.sh'
  expect_fail "root binary ./$NAME in README" README.md "run ./$NAME serve"
  expect_fail "root binary ./$NAME at the end of a sentence" README.md "build it, then run ./$NAME."
  expect_fail "root binary ./$NAME. followed by a space" README.md "run ./$NAME. Then wait"
  expect_fail "backticked root binary" README.md 'run `./'"$NAME"'` now'
  expect_pass "./$NAME.db is a file name, not the binary" README.md "the file ./$NAME.db is created"
  expect_pass "web/dist/$NAME in README" README.md "run web/dist/$NAME serve"
  expect_fail "./dist/$NAME in README" README.md "run ./dist/$NAME serve"
  expect_fail "stale path in current-state text of CLAUDE.md" CLAUDE.md 'web/e2e/ holds Playwright'
  expect_pass "link from web/docs to web/deploy" README.md 'see [x](../deploy/nginx.conf.example)'
  expect_pass "a /home/deploy/ path" README.md "DIR=/home/deploy/$NAME/data/backups"
  expect_pass "a file named like node_modules_notes" web/src/node_modules_notes.md 'x'
  make_copy && mkdir -p "$WORK/c/web/node_modules" && echo x > "$WORK/c/web/node_modules/x" && git -C "$WORK/c" add -f web/node_modules/x
  inner && bad "guard did not flag a tracked node_modules file" || ok "guard flags a tracked node_modules file"
  # Each directory set must hold exactly the expected files: an extra and a missing one both fail, and the
  # failure must come from that set's own check, not from some other check.
  inner_out() { (cd "$WORK/c" && LAYOUT_TEST_INNER=1 bash web/scripts/layout.test.sh 2>&1); }
  expect_set_fail() { # <label> <expected FAIL prefix> <extra|missing> <path in the copy>
    make_copy || return 1
    if [ "$3" = extra ]; then mkdir -p "$(dirname "$WORK/c/$4")"; echo x > "$WORK/c/$4"; else rm -rf "$WORK/c/$4"; fi
    git -C "$WORK/c" add -A
    if out="$(inner_out)"; then bad "guard did not flag $1"; elif printf '%s\n' "$out" | grep -qF "FAIL - $2"; then ok "guard flags $1"; else bad "$1 failed for another reason"; fi
  }
  expect_set_fail "an extra file in web/deploy/" "web/deploy/ is" extra web/deploy/extra.txt
  expect_set_fail "a missing file in web/deploy/" "web/deploy/ is" missing web/deploy/nginx.conf.example
  expect_set_fail "a missing web/deploy/.env.example" "web/deploy/ is" missing web/deploy/.env.example
  expect_set_fail "an extra file in web/docs/" "web/docs/ is" extra web/docs/extra.md
  expect_set_fail "a missing file in web/docs/" "web/docs/ is" missing web/docs/testing.md
  expect_set_fail "an extra file in web/scripts/" "web/scripts/ is" extra web/scripts/extra.sh
  expect_set_fail "a missing file in web/scripts/" "web/scripts/ is" missing web/scripts/smoke.sh
  if [ "$HOST" -eq 0 ]; then
    expect_set_fail "a root deploy/" "root deploy still exists" extra deploy/app.service
    expect_set_fail "a root scripts/" "root scripts still exists" extra scripts/x.sh
    expect_set_fail "a root Makefile" "root Makefile still exists" extra Makefile
    expect_set_fail "a root .env.example" "root .env.example still exists" extra .env.example
    expect_set_fail "a stray root file" "repo root is" extra stray.txt
  fi
  expect_set_fail "an extra file in docs/" "docs/ is" extra docs/deploy.md
  make_copy && mkdir -p "$WORK/c/docs/superpowers" && echo x > "$WORK/c/docs/superpowers/y.md" && git -C "$WORK/c" add -A
  inner && ok "guard allows docs/superpowers/" || bad "guard flags docs/superpowers/"
  make_copy && mkdir -p "$WORK/c/docs" && echo x > "$WORK/c/docs/logo.jpg" && git -C "$WORK/c" add -A
  inner && ok "guard allows docs/logo.jpg (the starter's logo)" || bad "guard flags docs/logo.jpg"
  expect_set_fail "another image in docs/" "docs/ is" extra docs/banner.png
  make_copy && rm "$WORK/c/.gitattributes" && git -C "$WORK/c" add -A
  if out="$(inner_out)"; then bad "guard did not flag a missing .gitattributes"; elif printf '%s\n' "$out" | grep -q 'FAIL - \*.sql is not marked -text'; then ok "guard flags a missing .gitattributes"; else bad "missing .gitattributes failed for another reason"; fi
  # Host mode: the app lives inside a host repo (the wrapper writes the marker file, and moves the starter's
  # CLAUDE.md to web/CLAUDE.md when the host already has a root one). Starter-only checks are skipped,
  # the starter itself (no marker) stays fully guarded.
  #
  # These self-tests build their fixtures from the STARTER's own layout (ios/README.md, a root starter
  # CLAUDE.md), so they run in the starter only. An app created from the starter (the marker is present)
  # skips them with an explicit, counted SKIPPED line instead of running on a layout they do not fit.
  if [ "$HOST" -eq 1 ]; then
    skip "starter-only self-tests (host mode)"
  else
  must() { # <label> <command...>: a fixture step that cannot be applied fails the guard loudly
    local label="$1"; shift
    "$@" || { bad "self-test fixture could not be built: $label"; return 1; }
  }
  make_host() { # [with-origin] [host-log]: host-log gives the host's root CLAUDE.md its own Done log
    make_copy || return 1
    ( cd "$WORK/c" && git rm -qf --ignore-unmatch ios/README.md && mkdir -p ios && echo "// host app" > ios/App.swift \
      && { [ -e web/CLAUDE.md ] || git mv CLAUDE.md web/CLAUDE.md; } \
      && printf '# Host repo\n\nNo starter headings here.\n' > CLAUDE.md \
      && sed -i.bak '1s/.*/# Host app/' README.md && rm -f README.md.bak ) || return 1
    if [ "${2:-}" = host-log ]; then
      printf '\n### Done\n\n- host work\n\n### Not yet verified on device\n\n- host thing\n' >> "$WORK/c/CLAUDE.md"
    fi
    # In a wrapper-created app the marker is tracked and so already in the copy: drop it unless asked for.
    rm -f "$WORK/c/$MARKER"
    if [ "${1:-}" = with-origin ]; then echo 0123456789abcdef > "$WORK/c/$MARKER"; fi
    git -C "$WORK/c" add -A
    # Never run on a copy that is not host-shaped: check what the steps above were supposed to produce.
    [ ! -e "$WORK/c/ios/README.md" ] && [ -e "$WORK/c/ios/App.swift" ] \
      && grep -q '^### Done' "$WORK/c/web/CLAUDE.md" && grep -q '^# Host repo' "$WORK/c/CLAUDE.md" \
      && [ "$(head -n 1 "$WORK/c/README.md")" = "# Host app" ] || return 1
    if [ "${1:-}" = with-origin ]; then [ -e "$WORK/c/$MARKER" ] || return 1; else [ ! -e "$WORK/c/$MARKER" ] || return 1; fi
  }
  add_to_done() { # <file in the copy>: put an old path inside that file's first Done section
    awk '{print} /^### Done/ && !d {print "- old entry mentions web/e2e/ and scripts/deploy.sh"; d=1}' "$WORK/c/$1" > "$WORK/claude.new" && cp "$WORK/claude.new" "$WORK/c/$1" && git -C "$WORK/c" add -A
  }
  # Both logs: the host's own root log AND the starter's moved log at web/CLAUDE.md.
  if must "two logs" make_host with-origin host-log; then
    if out="$(inner_out)"; then ok "host layout with its own Done log in CLAUDE.md and the starter's in web/CLAUDE.md passes"; else bad "host with two logs fails: $(printf '%s\n' "$out" | grep -A3 FAIL)"; fi
  fi
  if must "done sections" make_host with-origin host-log && must "done sections" add_to_done CLAUDE.md && must "done sections" add_to_done web/CLAUDE.md; then
    if out="$(inner_out)"; then ok "host mode exempts the Done section of EACH log"; else bad "host mode flags a Done section: $(printf '%s\n' "$out" | grep -A3 FAIL)"; fi
  fi
  if must "stale outside done" make_host with-origin host-log && printf '%s\n' 'web/e2e/ holds Playwright' >> "$WORK/c/web/CLAUDE.md" && git -C "$WORK/c" add -A; then
    if out="$(inner_out)"; then bad "two-log host mode missed a stale path outside the Done sections"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "two-log host mode still flags a stale path outside the Done sections"; else bad "two-log stale path failed for another reason"; fi
  fi
  # A Done section ends at the next "## " or "### " heading: a stale path under "## Architecture" is not history.
  if must "heading after done" make_host with-origin host-log && printf '# Host repo\n\n### Done\n\n- host work\n\n## Architecture\n\nweb/e2e/ holds Playwright\n\n### Not yet verified on device\n\n- host thing\n' > "$WORK/c/CLAUDE.md" && git -C "$WORK/c" add -A; then
    if out="$(inner_out)"; then bad "a stale path under a ## heading after the Done section was exempt"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "a Done section ends at the next ## heading"; else bad "stale path after Done failed for another reason"; fi
  fi
  # The marker must not turn the starter itself into a host (an LF or a CRLF README title).
  for eol in '' '\r'; do
    if [ "$NAME" != "$STARTER_NAME" ]; then skip "marker in the starter (this copy is a renamed app, not the starter)"; break; fi
    if must "marker in the starter" make_copy && printf "%s${eol}\n" "$STARTER_TITLE" > "$WORK/c/README.md" && echo 0123456789abcdef > "$WORK/c/$MARKER"; then
      if out="$(inner_out)"; then bad "guard accepted the marker in the starter itself (README eol '${eol}')"; elif printf '%s\n' "$out" | grep -qF "FAIL - $MARKER present in the starter itself; host mode is only for apps created from it"; then ok "guard fails loudly on $MARKER in the starter itself (README eol '${eol}')"; else bad "marker in the starter failed for another reason (eol '${eol}')"; fi
    fi
  done
  if must "host with marker" make_host with-origin; then
    if out="$(inner_out)"; then ok "host layout with $MARKER passes (no ios README, host CLAUDE.md, the starter's log at web/CLAUDE.md)"; else bad "host layout with $MARKER fails: $(printf '%s\n' "$out" | grep FAIL)"; fi
  fi
  if must "host without marker" make_host; then
    if out="$(inner_out)"; then bad "host layout WITHOUT $MARKER passed (the starter itself must stay guarded)"
    elif printf '%s\n' "$out" | grep -q 'FAIL - ios/ has neither' && printf '%s\n' "$out" | grep -q "FAIL - CLAUDE.md lost its"; then ok "host layout without $MARKER fails on the ios/ and CLAUDE.md checks"
    else bad "host layout without $MARKER failed for the wrong reasons: $(printf '%s\n' "$out" | grep FAIL)"; fi
  fi
  if must "stale in web/CLAUDE.md" make_host with-origin && printf '%s\n' 'web/e2e/ holds Playwright' >> "$WORK/c/web/CLAUDE.md" && git -C "$WORK/c" add -A; then
    if out="$(inner_out)"; then bad "host mode missed a stale path in web/CLAUDE.md"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "host mode flags a stale path in web/CLAUDE.md outside the Done section"; else bad "stale path in web/CLAUDE.md failed for another reason"; fi
  fi
  if must "done in web/CLAUDE.md" make_host with-origin && must "done in web/CLAUDE.md" add_to_done web/CLAUDE.md; then
    if inner; then ok "host mode allows old paths inside the Done section of web/CLAUDE.md"; else bad "host mode flags the Done section of web/CLAUDE.md"; fi
  fi
  # A host-shaped APP, built the way the wrapper builds one, runs the FULL guard (self-tests included) and
  # passes: renamed to "hostapp", README title of its own, ios/ with a file but no README.md or Package.swift,
  # a host root CLAUDE.md with its own log, the starter's log already at web/CLAUDE.md, the marker tracked.
  # What a host scaffolded with the new-ios-app skill carries in ios/App/: usage comments such as
  # "./deploy.sh" that look like the old deploy/ layout to a repo-wide scan (excerpted from the real
  # deploy.sh and ship.sh templates, so this test does not depend on any other checkout).
  write_ios_template() { # <dir>
    mkdir -p "$1/ios/App" && cat > "$1/ios/App/deploy.sh" <<'EOT'
#!/usr/bin/env bash
# Usage: ./deploy.sh [--list] [device-name-substring]
#   ./deploy.sh                 # first connected iPhone/iPad
#   ./deploy.sh "16 Plus"       # first connected device whose name contains this
#   ./deploy.sh --list          # show devices and what would be picked, then exit
echo "Plug the phone in (or enable wireless debugging), unlock it, and run ./deploy.sh --list." >&2
EOT
    cat > "$1/ios/App/ship.sh" <<'EOT'
#!/usr/bin/env bash
# Usage: ./ship.sh [--check]   (build, bump, upload to TestFlight; ./ship.sh --check validates only)
EOT
  }
  make_app() { # [stale|stale-scripts|stale-web]: a committed host-shaped app in $WORK/c
    make_copy || return 1
    ( cd "$WORK/c" && git -c user.email=t@example.com -c user.name=t commit -qm base \
      && { ! grep -q "^module $STARTER_NAME\$" web/api/go.mod || bash web/scripts/rename.sh layout.invalid/selftest/host"app" host"app" >/dev/null 2>&1; } \
      && git rm -qf --ignore-unmatch ios/README.md && mkdir -p ios && echo "// host app" > ios/App.swift \
      && { [ -e web/CLAUDE.md ] || git mv CLAUDE.md web/CLAUDE.md; } \
      && printf '# Host\n\n### Done\n\n- host work\n\n### Not yet verified on device\n\n- host thing\n' > CLAUDE.md \
      && sed -i.bak '1s/.*/# Shop App/' README.md && rm -f README.md.bak \
      && echo 0123456789abcdef > "$MARKER" ) || return 1
    write_ios_template "$WORK/c" || return 1
    case "${1:-}" in
      stale) printf '\nweb/e2e/ holds Playwright\n' >> "$WORK/c/web/CLAUDE.md" ;;
      stale-scripts) printf '\n# run scripts/deploy.sh now\n' >> "$WORK/c/web/scripts/gen-api.sh" ;;
      stale-web) printf '\nrun scripts/deploy.sh now\n' >> "$WORK/c/web/test/README.md" ;;
    esac
    git -C "$WORK/c" add -A && git -C "$WORK/c" -c user.email=t@example.com -c user.name=t commit -qm app || return 1
    # Prove the fixture is the shape described above before trusting the result.
    [ ! -e "$WORK/c/ios/README.md" ] && [ ! -e "$WORK/c/ios/Package.swift" ] && [ -e "$WORK/c/ios/App.swift" ] \
      && grep -q '\./deploy\.sh' "$WORK/c/ios/App/deploy.sh" \
      && grep -q '^### Done' "$WORK/c/web/CLAUDE.md" && grep -q '^### Done' "$WORK/c/CLAUDE.md" \
      && [ "$(head -n 1 "$WORK/c/README.md")" = "# Shop App" ] && [ -n "$(git -C "$WORK/c" ls-files "$MARKER")" ] \
      && ! grep -q "^module $STARTER_NAME\$" "$WORK/c/web/api/go.mod" || return 1
  }
  if must "host-shaped app" make_app; then
    if out="$(cd "$WORK/c" && bash web/scripts/layout.test.sh 2>&1)"; then ok "the full guard passes in a host-shaped app (renamed, no ios README, two logs, tracked marker)"; else bad "the full guard fails in a host-shaped app: $(printf '%s\n' "$out" | grep -A3 FAIL | head -8)"; fi
  fi
  # A renamed app whose README still carries the starter title is not the starter: the marker is accepted.
  if must "renamed app with the starter title" make_app && sed -i.bak "1s/.*/$STARTER_TITLE/" "$WORK/c/README.md" && rm -f "$WORK/c/README.md.bak" && git -C "$WORK/c" add -A && git -C "$WORK/c" -c user.email=t@example.com -c user.name=t commit -qm title; then
    if out="$(cd "$WORK/c" && bash web/scripts/layout.test.sh 2>&1)"; then ok "a renamed app keeping the starter README title is accepted with the marker"; else bad "a renamed app with the starter title was refused: $(printf '%s\n' "$out" | grep FAIL | head -3)"; fi
  fi
  for mode in stale-scripts stale-web; do
    if must "host-shaped app with a stale path in ${mode#stale-}" make_app "$mode"; then
      if out="$(cd "$WORK/c" && bash web/scripts/layout.test.sh 2>&1)"; then bad "host mode skipped more than the host-owned trees: a stale path in ${mode#stale-}/ passed"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "host mode still flags a stale path in ${mode#stale-}/"; else bad "stale path in ${mode#stale-}/ failed for another reason"; fi
    fi
  done
  # The same ios/ content in the STARTER (no marker) is still scanned.
  if must "ios template in the starter" make_copy && write_ios_template "$WORK/c" && git -C "$WORK/c" add -A; then
    if out="$(inner_out)"; then bad "the starter ignored stale-looking text under ios/"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "the starter (no marker) still scans ios/"; else bad "ios text in the starter failed for another reason"; fi
  fi
  if must "host-shaped app with a stale path" make_app stale; then
    if out="$(cd "$WORK/c" && bash web/scripts/layout.test.sh 2>&1)"; then bad "the full guard passed a host-shaped app with a stale path outside the Done sections"; elif printf '%s\n' "$out" | grep -q 'FAIL - stale references'; then ok "the full guard still fails a host-shaped app with a stale path outside the Done sections"; else bad "host-shaped app with a stale path failed for another reason"; fi
  fi
  fi
  # an old path inside a dated Done entry of CLAUDE.md is history and allowed
  make_copy && awk '{print} /^### Done/ && !d {print "- old entry mentions web/e2e/ and scripts/deploy.sh"; d=1}' CLAUDE.md > "$WORK/claude.new" && cp "$WORK/claude.new" "$WORK/c/CLAUDE.md" && git -C "$WORK/c" add -A
  inner && ok "guard allows old paths inside the Done section of CLAUDE.md" || bad "guard flags the Done section of CLAUDE.md"
fi

echo "layout.test.sh: $pass passed, $fail failed"
echo "SKIPPED: $skipped"
[ "$fail" -eq 0 ]
