#!/bin/bash
# Fast tier: scripts/scaffold.sh against a small fixture repo standing in for the starter.
# Sourced by run.sh (lib.sh already loaded). Each test runs in its own subshell under `set -e`.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCAFFOLD="$SKILL_DIR/scripts/scaffold.sh"
T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nwa-scaffold.XXXXXX")"
trap 'rm -rf "$T_ROOT"' EXIT
export FAKE_LOG="$T_ROOT/fake.log"

# The wrapper marker file name is a fixed contract with the starter's layout guard (two pieces on purpose).
MARK=".lo""tus-origin"

# make_lotus <dir>: a git repo with the few files the wrapper touches, shaped like the renamed starter
# (shipped name `app`). rename.sh is a tiny stand-in with the same CLI as the real one: --check, a clean
# tree, and, like the real rule 8, EVERY bare word `app` in an HTML page that has a title or brand link
# becomes the new name, plus dist/app in text files. Prose elsewhere stays.
make_lotus() {
  local d="$1"
  mkdir -p "$d/web/scripts" "$d/web/deploy" "$d/web/public/pages" "$d/ios" "$d/docs/superpowers" "$d/.claude/skills/new-web-app/scripts"
  cat > "$d/web/scripts/rename.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
CHECK=0; A=(); for a in "$@"; do case "$a" in --check) CHECK=1 ;; --force|--regen) ;; *) A+=("$a") ;; esac; done
[ "${#A[@]}" -eq 2 ] || exit 2
FLAG=""; [ "$CHECK" = 1 ] && FLAG="--check "; echo "rename ${FLAG}${A[*]}" >> "${FAKE_LOG:-/dev/null}"
case "${A[1]}" in verify|web) echo "rename: the name '${A[1]}' is reserved: pick another name" >&2; exit 1 ;; esac
[ "$CHECK" = 0 ] || { echo "rename: --check: would be accepted"; exit 0; }
cd "$(dirname "$0")/../.."
[ -z "$(git status --porcelain)" ] || { echo "rename: dirty tree" >&2; exit 1; }
for f in $(git ls-files); do
  case "$f" in docs/superpowers/*|.claude/skills/*) continue ;; esac
  case "$f" in
    *.html) grep -q '<title>\|class="brand"' "$f" && perl -pi -e "s{(?<![A-Za-z0-9_./-])app(?![A-Za-z0-9_-])}{${A[1]}}g" "$f" ;;
    *) perl -pi -e "s{dist/app}{dist/${A[1]}}g" "$f" ;;
  esac
done
EOS
  cat > "$d/web/scripts/deploy.sh" <<'EOS'
#!/usr/bin/env bash
{ echo "PUBLIC_URL=${PUBLIC_URL:-}"; echo "EXPECT_PUBLIC_LISTENER=${EXPECT_PUBLIC_LISTENER:-}"
  echo "REQUIRE_BACKUP_TIMER=${REQUIRE_BACKUP_TIMER:-}"; echo "APP_NAME=${APP_NAME:-}"; echo "ARGS=$*"; } > "${DEPLOY_ENV_LOG:?}"
EOS
  cat > "$d/web/scripts/backup-pull.env.example" <<'EOS'
REMOTE=deploy@host.example.com
REMOTE_DIR=app/data/backups
#DEST=$HOME/Backups/app
#KEEP=30
#MIRROR_DIR="/path/to/second drive/backups/app"
EOS
  cat > "$d/web/deploy/.env.example" <<'EOS'
APP_ENV=production
PUBLIC_ORIGIN=
# ADDR is the listen address
ADDR=127.0.0.1:8080
TRUSTED_PROXY=127.0.0.1/32
EOS
  printf 'node_modules/\n*.log\n' > "$d/.gitignore"
  printf '<p align="center"><img src="docs/logo.jpg" alt="logo" width="360"></p>\n\nA starter. The app serves /app/. Binary: dist/app\n' > "$d/README.md"
  printf 'jpegbytes' > "$d/docs/logo.jpg"
  printf '# app CLAUDE\nbinary dist/app\n' > "$d/CLAUDE.md"
  printf '# app AGENTS\n' > "$d/AGENTS.md"
  printf '# ios\nreserved\n' > "$d/ios/README.md"
  mkdir -p "$d/ios/Caritos/Sources"; printf '// swift-tools-version: 5.9\n' > "$d/ios/Caritos/Package.swift"; printf 'x\n' > "$d/ios/Caritos/Sources/a.swift"
  printf 'history\n' > "$d/docs/superpowers/plan.md"
  printf 'skill text with caritos.com and DreamHost\n' > "$d/.claude/skills/new-web-app/SKILL.md"
  printf '#!/bin/bash\n' > "$d/.claude/skills/new-web-app/scripts/scaffold.sh"
  printf '<!doctype html>\n<title>app</title>\n<div id="root"></div>\n' > "$d/web/index.html"
  local p t h
  for p in index faq privacy terms support; do
    case "$p" in index) t='app - simple notes with photos'; h='<h1>app</h1>' ;; faq) t='FAQ - app'; h='<h2>What is app?</h2>' ;; *) t="$p - app"; h="<h1>$p</h1>" ;; esac
    cat > "$d/web/public/pages/$p.html" <<EOS
<title>$t</title>
<a class="brand" href="/">app</a>
$h
<p>This is the example notes app. <a class="button" href="/app/">Open the app</a></p>
<p>Email <a href="mailto:support@example.com">support@example.com</a>.</p>
<p class="note">Replace support@example.com with your real support address.</p>
<p>The name in the header is a placeholder. Replace this footer with your own.</p>
EOS
  done
  printf 'test-fast:\n\t@test ! -f FAIL_TEST_FAST\n\ntest-scripts:\n\tbash scripts/deploy.test.sh\n\tbash scripts/rename.test.sh\n\tbash scripts/build-id.test.sh\n' > "$d/web/Makefile"
  printf '#!/bin/bash\n# rename self-test\n' > "$d/web/scripts/rename.test.sh"
  printf '#!/bin/bash\nWS=(deploy.sh layout.test.sh rename.sh rename.test.sh restore.sh)\n' > "$d/web/scripts/layout.test.sh"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fixture
}

# new_env: sets GW (fixture lotus) and TARGET (empty repo dir); exports LOTUS_DIR.
new_env() {
  rm -rf "$T_ROOT/gw" "$T_ROOT/target"; : > "$FAKE_LOG"
  GW="$T_ROOT/gw"; TARGET="$T_ROOT/target"
  make_lotus "$GW"; mkdir -p "$TARGET"
  export LOTUS_DIR="$GW"
}

run_scaffold() { bash "$SCAFFOLD" "$@" 2>&1; }

# snapshot <dir>: every path with a content hash, to prove a refusal changed nothing.
snapshot() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null; find . | sort); }

test_rejects_bad_slug() {
  new_env
  local s rc
  for s in Bad 1x a-b "" "a b"; do
    rc=0; run_scaffold "$TARGET" "$s" "Name" "desc" >/dev/null || rc=$?
    assert_eq 2 "$rc" "slug [$s]"
  done
  [ -z "$(ls -A "$TARGET")" ]
}

test_rejects_forbidden_characters_in_text() {
  new_env
  local bad rc
  for bad in 'a|b' 'a%b' 'a\b' 'a"b' $'a\nb'; do
    rc=0; run_scaffold "$TARGET" shop "$bad" "desc" >/dev/null || rc=$?
    assert_eq 2 "$rc" "name [$bad]"
    rc=0; run_scaffold "$TARGET" shop "Shop" "$bad" >/dev/null || rc=$?
    assert_eq 2 "$rc" "description [$bad]"
  done
  [ -z "$(ls -A "$TARGET")" ]
}

test_rejects_bad_port() {
  new_env
  local p rc
  for p in 0 80 1023 65536 abc 8e3 ""; do
    rc=0; run_scaffold "$TARGET" shop "Shop" "desc" --port "$p" >/dev/null || rc=$?
    assert_eq 2 "$rc" "port [$p]"
  done
  rc=0; run_scaffold "$TARGET" shop "Shop" "desc" --port >/dev/null || rc=$?
  assert_eq 2 "$rc" "--port without a value"
  [ -z "$(ls -A "$TARGET")" ]
}

test_refuses_when_lotus_is_missing() {
  new_env
  local rc=0 out
  out="$(LOTUS_DIR="$T_ROOT/nope" run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 1 "$rc"; assert_contains "$out" "starter"
  mkdir "$T_ROOT/plain"; rc=0
  LOTUS_DIR="$T_ROOT/plain" run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null || rc=$?
  assert_eq 1 "$rc" "not a git repo"
  [ -z "$(ls -A "$TARGET")" ]
}

test_refuses_a_dirty_lotus_unless_allow_dirty() {
  new_env
  echo "dirty" >> "$GW/README.md"
  local rc=0 out
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 1 "$rc"; assert_contains "$out" "uncommitted"
  [ -z "$(ls -A "$TARGET")" ]
  run_scaffold "$TARGET" shop "Shop" "desc" --allow-dirty >/dev/null
  # only HEAD is used: the uncommitted line is not in the copy
  ! grep -q '^dirty$' "$TARGET/README.md"
}

test_refuses_when_a_target_file_exists_and_changes_nothing() {
  new_env
  mkdir -p "$TARGET/web"; echo "mine" > "$TARGET/web/index.html"; echo "x" > "$TARGET/web/package.json"
  git -C "$TARGET" init -q
  local before after rc=0 out head
  before="$(snapshot "$TARGET" | grep -v '\.git/')"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "web/index.html"
  after="$(snapshot "$TARGET" | grep -v '\.git/')"
  assert_eq "$before" "$after"
}

test_does_not_commit_in_the_target() {
  new_env
  git -C "$TARGET" init -q
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  # still no commit, files only
  ! git -C "$TARGET" rev-parse -q --verify HEAD >/dev/null
  [ -f "$TARGET/web/scripts/deploy.sh" ]
}

test_appends_only_missing_gitignore_lines() {
  new_env
  printf '.DS_Store\nnode_modules/' > "$TARGET/.gitignore"   # no trailing newline
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  assert_eq $'.DS_Store\nnode_modules/\n*.log' "$(cat "$TARGET/.gitignore")"
}

test_root_claude_md_gets_a_pointer_and_the_starters_goes_to_web() {
  new_env
  printf '# Mine\nkeep this\n' > "$TARGET/CLAUDE.md"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  assert_contains "$(cat "$TARGET/CLAUDE.md")" "keep this"
  assert_contains "$(cat "$TARGET/CLAUDE.md")" "web/CLAUDE.md"
  assert_eq 1 "$(grep -c 'web/CLAUDE.md' "$TARGET/CLAUDE.md")"
  assert_contains "$(cat "$TARGET/web/CLAUDE.md")" "dist/shop"
  # without an existing root file, the starter's lands at the root and no web/CLAUDE.md exists
  rm -rf "$TARGET"; mkdir "$TARGET"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  [ -f "$TARGET/CLAUDE.md" ]; [ ! -e "$TARGET/web/CLAUDE.md" ]
}

test_skips_existing_readme_and_agents_and_says_so() {
  new_env
  echo "my readme" > "$TARGET/README.md"; echo "my agents" > "$TARGET/AGENTS.md"
  local out
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")"
  assert_eq "my readme" "$(cat "$TARGET/README.md")"
  assert_eq "my agents" "$(cat "$TARGET/AGENTS.md")"
  assert_contains "$out" "skipped README.md"
  assert_contains "$out" "skipped AGENTS.md"
}

test_writes_the_origin_marker_with_the_commit_hash() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  assert_eq "$(git -C "$GW" rev-parse HEAD)" "$(tr -d '[:space:]' < "$TARGET/$MARK")"
}

test_display_name_is_html_escaped_in_pages() {
  new_env
  run_scaffold "$TARGET" shop "Tom's & <Notes>" "Notes for <Tom> & co" >/dev/null
  local p f
  for p in index faq privacy terms support; do
    f="$TARGET/web/public/pages/$p.html"
    assert_contains "$(cat "$f")" "Tom&#39;s &amp; &lt;Notes&gt;" "$p"
    ! grep -q "<Notes>" "$f"
  done
  assert_contains "$(cat "$TARGET/web/public/pages/index.html")" "<title>Tom&#39;s &amp; &lt;Notes&gt; - Notes for &lt;Tom&gt; &amp; co</title>"
  assert_contains "$(cat "$TARGET/web/index.html")" "<title>Tom&#39;s &amp; &lt;Notes&gt;</title>"
  assert_eq "# Tom&#39;s &amp; &lt;Notes&gt;" "$(sed -n 1p "$TARGET/README.md")"
  # the slug is not the visible brand any more, the slug stays in the Go-facing text
  ! grep -q 'class="brand" href="/">shop<' "$TARGET/web/public/pages/index.html"
}

test_footer_and_support_address_use_caritos() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local f="$TARGET/web/public/pages/support.html"
  assert_contains "$(cat "$f")" "support@caritos.com"
  ! grep -q "example.com" "$f"
  ! grep -q "placeholder name" "$f"
  assert_contains "$(cat "$f")" "Shop - contact support@caritos.com"
  ! grep -q "Replace support@" "$f"
}

test_port_flag_sets_ADDR_and_without_it_the_placeholder_is_invalid() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" --port 8123 >/dev/null
  assert_eq "ADDR=0.0.0.0:8123" "$(grep '^ADDR=' "$TARGET/web/deploy/.env.example")"
  rm -rf "$TARGET"; mkdir "$TARGET"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local a; a="$(grep '^ADDR=' "$TARGET/web/deploy/.env.example")"
  assert_contains "$a" "0.0.0.0:"
  case "${a##*:}" in *[!0-9]*) ;; *) echo "placeholder port is numeric: $a" >&2; return 1 ;; esac
}

test_applies_the_hosting_defaults() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" --port 8123 >/dev/null
  assert_eq "PUBLIC_ORIGIN=https://shop.caritos.com" "$(grep '^PUBLIC_ORIGIN=' "$TARGET/web/deploy/.env.example")"
  local b="$TARGET/web/scripts/backup-pull.env.example"
  assert_eq 'MIRROR_DIR="/Volumes/Treasure Chest/backups/shop"' "$(grep '^MIRROR_DIR=' "$b")"
  assert_eq 'REMOTE_DIR=shop/data/backups' "$(grep '^REMOTE_DIR=' "$b")"
  assert_eq 'DEST=$HOME/Backups/shop' "$(grep '^DEST=' "$b")"
  assert_eq "#KEEP=30" "$(grep 'KEEP' "$b")"
  grep -qxF "rename github.com/caritos/shop shop" "$FAKE_LOG"
}

test_hosting_specifics_stay_out_of_the_starter() {
  new_env
  local before after
  before="$(snapshot "$GW")"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  after="$(snapshot "$GW")"
  assert_eq "$before" "$after"
  [ -z "$(git -C "$GW" status --porcelain)" ]
  ! grep -rq "caritos.com\|Treasure Chest" "$GW" --exclude-dir=.git --exclude-dir=skills
}

test_no_starter_name_or_token_is_left_in_written_files() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local left old="lo""tus"
  left="$(grep -rli "$old" "$TARGET" | grep -v "$MARK\$" || true)"
  assert_eq "" "$left"
  left="$(grep -rl '@@WRAP_' "$TARGET" || true)"
  assert_eq "" "$left" "no unreplaced token"
}

test_the_skills_directory_is_not_copied_into_the_app() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  [ ! -e "$TARGET/.claude/skills" ]
  [ -f "$GW/.claude/skills/new-web-app/SKILL.md" ]   # still in the starter
  ! grep -rq "caritos.com" "$TARGET/.claude" 2>/dev/null
}

test_the_rename_self_test_is_not_copied_into_the_app() {
  new_env
  [ -f "$GW/web/scripts/rename.test.sh" ]
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  [ ! -e "$TARGET/web/scripts/rename.test.sh" ]
  ! grep -rq "rename.test.sh" "$TARGET/web/Makefile" "$TARGET/web/scripts/layout.test.sh"
  grep -q "bash scripts/build-id.test.sh" "$TARGET/web/Makefile"   # neighbours survive
  grep -q "rename.sh restore.sh" "$TARGET/web/scripts/layout.test.sh"
}

test_the_starters_logo_is_not_copied_into_the_app() {
  new_env
  [ -f "$GW/docs/logo.jpg" ]
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  [ ! -e "$TARGET/docs/logo.jpg" ]
  ! grep -q "logo.jpg" "$TARGET/README.md"
  assert_eq "# Shop" "$(sed -n 1p "$TARGET/README.md")"
  assert_contains "$(cat "$TARGET/README.md")" "The app serves /app/. Binary: dist/shop" "rest of the README survives"
}

test_prose_with_the_word_app_survives_and_display_spots_get_the_name() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local pg="$TARGET/web/public/pages" f
  for f in index faq privacy terms support; do
    assert_contains "$(cat "$pg/$f.html")" "This is the example notes app." "$f prose"
    assert_contains "$(cat "$pg/$f.html")" 'href="/app/">Open the app</a>' "$f link"
    assert_contains "$(cat "$pg/$f.html")" '<a class="brand" href="/">Shop</a>' "$f brand"
  done
  assert_contains "$(cat "$pg/index.html")" "<h1>Shop</h1>"
  assert_contains "$(cat "$pg/faq.html")" "<h2>What is Shop?</h2>"
  assert_contains "$(sed -n 1p "$pg/index.html")" "<title>Shop - desc</title>"
  assert_contains "$(sed -n 1p "$pg/support.html")" "<title>support - Shop</title>"
  assert_contains "$(cat "$TARGET/README.md")" "The app serves /app/. Binary: dist/shop"
}

test_slug_refused_by_the_starters_rename_check_exits_2_and_touches_nothing() {
  new_env
  local rc=0 out before
  echo keep > "$TARGET/mine.txt"; before="$(snapshot "$TARGET")"
  out="$(run_scaffold "$TARGET" verify "Shop" "desc")" || rc=$?
  assert_eq 2 "$rc"
  assert_contains "$out" "reserved"
  assert_contains "$out" "verify"
  assert_eq "$before" "$(snapshot "$TARGET")"
  grep -q 'rename --check github.com/caritos/verify verify' "$FAKE_LOG"
}

test_slug_equal_to_the_starter_name_app_works() {
  new_env
  run_scaffold "$TARGET" app "Shop" "desc" >/dev/null
  grep -qxF "rename github.com/caritos/app app" "$FAKE_LOG"
  assert_contains "$(cat "$TARGET/web/public/pages/index.html")" "<title>Shop - desc</title>"
  assert_contains "$(cat "$TARGET/web/public/pages/index.html")" "Open the app"
}

test_default_starter_is_the_repo_the_script_lives_in_also_through_a_symlink() {
  new_env
  cp "$SCAFFOLD" "$GW/.claude/skills/new-web-app/scripts/scaffold.sh"
  git -C "$GW" add -A; git -C "$GW" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m skill
  local sc="$GW/.claude/skills/new-web-app/scripts/scaffold.sh" head; head="$(git -C "$GW" rev-parse HEAD)"
  ( unset LOTUS_DIR; bash "$sc" "$TARGET" shop "Shop" "desc" >/dev/null 2>&1 )
  assert_eq "$head" "$(tr -d '[:space:]' < "$TARGET/$MARK")"
  rm -rf "$TARGET"; mkdir "$TARGET"
  mkdir -p "$T_ROOT/home/.claude/skills"; rm -f "$T_ROOT/home/.claude/skills/new-web-app"
  ln -s "$GW/.claude/skills/new-web-app" "$T_ROOT/home/.claude/skills/new-web-app"      # linked skill dir
  ( unset LOTUS_DIR; bash "$T_ROOT/home/.claude/skills/new-web-app/scripts/scaffold.sh" "$TARGET" shop "Shop" "desc" >/dev/null 2>&1 )
  assert_eq "$head" "$(tr -d '[:space:]' < "$TARGET/$MARK")"
  rm -rf "$TARGET"; mkdir "$TARGET"
  ln -sf "$sc" "$T_ROOT/link-scaffold.sh"                                                # linked script
  ( unset LOTUS_DIR; bash "$T_ROOT/link-scaffold.sh" "$TARGET" shop "Shop" "desc" >/dev/null 2>&1 )
  assert_eq "$head" "$(tr -d '[:space:]' < "$TARGET/$MARK")"
  # LOTUS_DIR still overrides
  rm -rf "$TARGET" "$T_ROOT/gw2"; mkdir "$TARGET"; cp -R "$GW" "$T_ROOT/gw2"
  git -C "$T_ROOT/gw2" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m other
  LOTUS_DIR="$T_ROOT/gw2" bash "$sc" "$TARGET" shop "Shop" "desc" >/dev/null 2>&1
  assert_eq "$(git -C "$T_ROOT/gw2" rev-parse HEAD)" "$(tr -d '[:space:]' < "$TARGET/$MARK")"
}

test_a_failing_fast_tier_leaves_the_target_untouched() {
  new_env
  touch "$GW/web/FAIL_TEST_FAST"; git -C "$GW" add -A
  git -C "$GW" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fail
  echo keep > "$TARGET/mine.txt"
  local before after rc=0 out
  before="$(snapshot "$TARGET")"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 1 "$rc"
  after="$(snapshot "$TARGET")"
  assert_eq "$before" "$after"
}

test_the_caritos_package_is_not_copied_into_the_app() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  [ -f "$TARGET/ios/README.md" ]
  [ ! -e "$TARGET/ios/Caritos" ]
  [ -f "$GW/ios/Caritos/Package.swift" ]   # still in the starter
}

test_existing_ios_files_are_not_modified() {
  new_env
  mkdir -p "$TARGET/ios/App"; echo "swift" > "$TARGET/ios/App/main.swift"; echo "mine" > "$TARGET/ios/README.md"
  local before out
  before="$(snapshot "$TARGET/ios")"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")"
  assert_eq "$before" "$(snapshot "$TARGET/ios")"
  assert_contains "$out" "skipped ios/"
  # without an ios/ in the target, the starter's placeholder is copied
  rm -rf "$TARGET"; mkdir "$TARGET"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  [ -f "$TARGET/ios/README.md" ]
}

test_prints_the_copy_rewrite_reminder_and_next_steps() {
  new_env
  local out; out="$(run_scaffold "$TARGET" shop "Shop" "desc")"
  assert_contains "$out" "example notes app"
  for w in privacy terms FAQ support; do assert_contains "$out" "$w"; done
  assert_contains "$out" "ssh-copy-id"
  assert_contains "$out" "--port"
}

# ---- web/scripts/deploy-app.sh: the Mac-side deploy settings -------------------------------------

deploy_app_env() {  # runs the generated deploy-app.sh with a fake ssh first on PATH
  make_fakebin "$T_ROOT/fakebin" ssh 'exit 0'
  export DEPLOY_ENV_LOG="$T_ROOT/deploy-env.log"; rm -f "$DEPLOY_ENV_LOG"
  PATH="$T_ROOT/fakebin:$PATH" bash "$TARGET/web/scripts/deploy-app.sh" "$@" 2>&1
}

test_deploy_app_exports_the_deploy_settings_and_runs_deploy_sh() {
  new_env
  run_scaffold "$TARGET" shop "Tom's & <Notes> \$HOME \`x\`" "desc" --port 8123 >/dev/null
  [ -x "$TARGET/web/scripts/deploy-app.sh" ]
  deploy_app_env me@host --check >/dev/null
  local log; log="$(cat "$DEPLOY_ENV_LOG")"
  assert_contains "$log" "PUBLIC_URL=https://shop.caritos.com"
  assert_contains "$log" "EXPECT_PUBLIC_LISTENER=1"
  assert_contains "$log" "REQUIRE_BACKUP_TIMER=1"
  # the text smoke.sh must find in the page HTML: escaped like the page, never expanded by the shell
  assert_contains "$log" "APP_NAME=Tom&#39;s &amp; &lt;Notes&gt; \$HOME \`x\`"
  assert_contains "$log" "ARGS=me@host --check"
}

test_deploy_app_rejects_the_placeholder_port_before_any_ssh_call() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null     # no --port
  local rc=0 out
  out="$(deploy_app_env me@host)" || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "port"
  assert_contains "$out" ".env.example"
  [ ! -e "$DEPLOY_ENV_LOG" ]                        # deploy.sh never ran
  ! grep -q '^ssh ' "$FAKE_LOG"
}

test_deploy_app_follows_the_port_edited_into_env_example() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  perl -pi -e 's/^ADDR=.*/ADDR=0.0.0.0:8222/' "$TARGET/web/deploy/.env.example"
  deploy_app_env me@host >/dev/null
  [ -e "$DEPLOY_ENV_LOG" ]
}

test_deploy_app_is_not_a_stale_layout_violation() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" --port 8123 >/dev/null
  # layout.test.sh scans for "deploy/<script>.sh"-style stale paths; the new script must not trip it
  ! grep -nE '(^|[^A-Za-z0-9_/])deploy/' "$TARGET/web/scripts/deploy-app.sh"
}

# ---- host targets: the starter's layout guard is host-aware now, so no warning ------------------------

test_no_layout_warning_for_a_target_with_ios_or_a_root_claude_md() {
  new_env
  mkdir -p "$TARGET/ios"; echo x > "$TARGET/ios/a.swift"; echo "# mine" > "$TARGET/CLAUDE.md"
  local out rc=0; out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 0 "$rc"
  assert_not_contains "$out" "layout.test.sh"
  assert_not_contains "$out" "L3"
  assert_not_contains "$out" "WARNING"
  assert_contains "$out" "skipped ios/"
}

# ---- relative <repo-dir> ----------------------------------------------------------------------

test_relative_dot_target_lands_in_the_current_directory() {
  new_env
  local out
  out="$(cd "$TARGET" && bash "$SCAFFOLD" . shop "Shop" "desc" 2>&1)"
  [ -f "$TARGET/web/scripts/deploy-app.sh" ]; [ -f "$TARGET/$MARK" ]
  local real; real="$(cd "$TARGET" && pwd -P)"
  assert_contains "$out" "written to $real"
  assert_not_contains "$out" "written to ."
}

test_relative_sibling_target_lands_in_the_intended_directory() {
  new_env
  mkdir "$T_ROOT/sib"
  local out
  out="$(cd "$T_ROOT/sib" && bash "$SCAFFOLD" ../app shop "Shop" "desc" 2>&1)"
  [ -f "$T_ROOT/app/web/scripts/deploy-app.sh" ]; [ ! -e "$T_ROOT/sib/app" ]
  assert_contains "$out" "written to $(cd "$T_ROOT/app" && pwd -P)"
}

test_a_failure_does_not_leave_a_new_target_dir_behind() {
  new_env
  touch "$GW/web/FAIL_TEST_FAST"; git -C "$GW" add -A
  git -C "$GW" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fail
  local rc=0
  (cd "$T_ROOT" && bash "$SCAFFOLD" newapp shop "Shop" "desc" >/dev/null 2>&1) || rc=$?
  assert_eq 1 "$rc"
  [ ! -e "$T_ROOT/newapp" ]
}
