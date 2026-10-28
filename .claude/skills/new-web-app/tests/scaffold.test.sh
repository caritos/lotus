#!/bin/bash
# Fast tier: scripts/scaffold.sh against a small fixture repo standing in for goweb.
# Sourced by run.sh (lib.sh already loaded). Each test runs in its own subshell under `set -e`.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$SKILL_DIR/scripts/scaffold.sh"
T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nwa-scaffold.XXXXXX")"
trap 'rm -rf "$T_ROOT"' EXIT
export FAKE_LOG="$T_ROOT/fake.log"

# make_goweb <dir>: a git repo with the few files the wrapper touches. rename.sh is a tiny stand-in
# (same CLI, refuses a dirty tree, replaces goweb in tracked text files).
make_goweb() {
  local d="$1"
  mkdir -p "$d/scripts" "$d/web/api/internal/web/pages" "$d/ios" "$d/docs/superpowers"
  cat > "$d/scripts/rename.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
A=(); for a in "$@"; do case "$a" in --force|--regen) ;; *) A+=("$a") ;; esac; done
[ "${#A[@]}" -eq 2 ] || exit 2
echo "rename ${A[*]}" >> "${FAKE_LOG:-/dev/null}"
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "rename: dirty tree" >&2; exit 1; }
for f in $(git ls-files); do
  case "$f" in docs/superpowers/*) continue ;; esac
  perl -pi -e "s/goweb/${A[1]}/g" "$f"
done
EOS
  cat > "$d/scripts/deploy.sh" <<'EOS'
#!/usr/bin/env bash
{ echo "PUBLIC_URL=${PUBLIC_URL:-}"; echo "EXPECT_PUBLIC_LISTENER=${EXPECT_PUBLIC_LISTENER:-}"
  echo "REQUIRE_BACKUP_TIMER=${REQUIRE_BACKUP_TIMER:-}"; echo "APP_NAME=${APP_NAME:-}"; echo "ARGS=$*"; } > "${DEPLOY_ENV_LOG:?}"
EOS
  cat > "$d/scripts/backup-pull.env.example" <<'EOS'
REMOTE=deploy@host.example.com
REMOTE_DIR=goweb/data/backups
#DEST=$HOME/Backups/goweb
#KEEP=30
#MIRROR_DIR="/path/to/second drive/backups/goweb"
EOS
  cat > "$d/.env.example" <<'EOS'
APP_ENV=production
PUBLIC_ORIGIN=
# ADDR is the listen address
ADDR=127.0.0.1:8080
TRUSTED_PROXY=127.0.0.1/32
EOS
  printf 'node_modules/\n*.log\n' > "$d/.gitignore"
  printf '# goweb\n\nA starter. Run `cd goweb`.\n' > "$d/README.md"
  printf '# goweb CLAUDE\n' > "$d/CLAUDE.md"
  printf '# goweb AGENTS\n' > "$d/AGENTS.md"
  printf '# ios\nreserved\n' > "$d/ios/README.md"
  printf 'history of goweb\n' > "$d/docs/superpowers/plan.md"
  printf '<title>goweb</title>\n' > "$d/web/index.html"
  local p
  for p in index faq privacy terms support; do
    cat > "$d/web/api/internal/web/pages/$p.html" <<'EOS'
<title>goweb - simple notes with photos</title>
<a class="brand" href="/">goweb</a>
<p>Email <a href="mailto:support@example.com">support@example.com</a>.</p>
<p class="note">Replace support@example.com with your real support address.</p>
<p>goweb is a placeholder name. Replace this footer with your own.</p>
EOS
  done
  printf 'test-fast:\n\t@test ! -f FAIL_TEST_FAST\n' > "$d/Makefile"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fixture
}

# new_env: sets GW (fixture goweb) and TARGET (empty repo dir); exports GOWEB_DIR.
new_env() {
  rm -rf "$T_ROOT/gw" "$T_ROOT/target"; : > "$FAKE_LOG"
  GW="$T_ROOT/gw"; TARGET="$T_ROOT/target"
  make_goweb "$GW"; mkdir -p "$TARGET"
  export GOWEB_DIR="$GW"
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

test_refuses_when_goweb_is_missing() {
  new_env
  local rc=0 out
  out="$(GOWEB_DIR="$T_ROOT/nope" run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 1 "$rc"; assert_contains "$out" "goweb"
  mkdir "$T_ROOT/plain"; rc=0
  GOWEB_DIR="$T_ROOT/plain" run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null || rc=$?
  assert_eq 1 "$rc" "not a git repo"
  [ -z "$(ls -A "$TARGET")" ]
}

test_refuses_a_dirty_goweb_unless_allow_dirty() {
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
  [ -f "$TARGET/scripts/deploy.sh" ]
}

test_appends_only_missing_gitignore_lines() {
  new_env
  printf '.DS_Store\nnode_modules/' > "$TARGET/.gitignore"   # no trailing newline
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  assert_eq $'.DS_Store\nnode_modules/\n*.log' "$(cat "$TARGET/.gitignore")"
}

test_root_claude_md_gets_a_pointer_and_goweb_s_goes_to_web() {
  new_env
  printf '# Mine\nkeep this\n' > "$TARGET/CLAUDE.md"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  assert_contains "$(cat "$TARGET/CLAUDE.md")" "keep this"
  assert_contains "$(cat "$TARGET/CLAUDE.md")" "web/CLAUDE.md"
  assert_eq 1 "$(grep -c 'web/CLAUDE.md' "$TARGET/CLAUDE.md")"
  assert_contains "$(cat "$TARGET/web/CLAUDE.md")" "shop CLAUDE"
  # without an existing root file, goweb's lands at the root and no web/CLAUDE.md exists
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

test_writes_goweb_origin_with_the_commit_hash() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  assert_eq "$(git -C "$GW" rev-parse HEAD)" "$(tr -d '[:space:]' < "$TARGET/.goweb-origin")"
}

test_display_name_is_html_escaped_in_pages() {
  new_env
  run_scaffold "$TARGET" shop "Tom's & <Notes>" "Notes for <Tom> & co" >/dev/null
  local p f
  for p in index faq privacy terms support; do
    f="$TARGET/web/api/internal/web/pages/$p.html"
    assert_contains "$(cat "$f")" "Tom&#39;s &amp; &lt;Notes&gt;" "$p"
    ! grep -q "<Notes>" "$f"
  done
  assert_contains "$(cat "$TARGET/web/api/internal/web/pages/index.html")" "<title>Tom&#39;s &amp; &lt;Notes&gt; - Notes for &lt;Tom&gt; &amp; co</title>"
  assert_contains "$(cat "$TARGET/web/index.html")" "<title>Tom&#39;s &amp; &lt;Notes&gt;</title>"
  assert_eq "# Tom&#39;s &amp; &lt;Notes&gt;" "$(sed -n 1p "$TARGET/README.md")"
  # the slug is not the visible brand any more, the slug stays in the Go-facing text
  ! grep -q 'class="brand" href="/">shop<' "$TARGET/web/api/internal/web/pages/index.html"
}

test_footer_and_support_address_use_caritos() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local f="$TARGET/web/api/internal/web/pages/support.html"
  assert_contains "$(cat "$f")" "support@caritos.com"
  ! grep -q "example.com" "$f"
  ! grep -q "placeholder name" "$f"
  assert_contains "$(cat "$f")" "Shop - contact support@caritos.com"
  ! grep -q "Replace support@" "$f"
}

test_port_flag_sets_ADDR_and_without_it_the_placeholder_is_invalid() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" --port 8123 >/dev/null
  assert_eq "ADDR=0.0.0.0:8123" "$(grep '^ADDR=' "$TARGET/.env.example")"
  rm -rf "$TARGET"; mkdir "$TARGET"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local a; a="$(grep '^ADDR=' "$TARGET/.env.example")"
  assert_contains "$a" "0.0.0.0:"
  case "${a##*:}" in *[!0-9]*) ;; *) echo "placeholder port is numeric: $a" >&2; return 1 ;; esac
}

test_applies_the_hosting_defaults() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" --port 8123 >/dev/null
  assert_eq "PUBLIC_ORIGIN=https://shop.caritos.com" "$(grep '^PUBLIC_ORIGIN=' "$TARGET/.env.example")"
  local b="$TARGET/scripts/backup-pull.env.example"
  assert_eq 'MIRROR_DIR="/Volumes/Treasure Chest/backups/shop"' "$(grep '^MIRROR_DIR=' "$b")"
  assert_eq 'REMOTE_DIR=shop/data/backups' "$(grep '^REMOTE_DIR=' "$b")"
  assert_eq 'DEST=$HOME/Backups/shop' "$(grep '^DEST=' "$b")"
  assert_eq "#KEEP=30" "$(grep 'KEEP' "$b")"
  grep -qxF "rename github.com/caritos/shop shop" "$FAKE_LOG"
}

test_hosting_specifics_stay_out_of_goweb() {
  new_env
  local before after
  before="$(snapshot "$GW")"
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  after="$(snapshot "$GW")"
  assert_eq "$before" "$after"
  [ -z "$(git -C "$GW" status --porcelain)" ]
  ! grep -rq "caritos.com\|Treasure Chest" "$GW" --exclude-dir=.git
}

test_no_goweb_text_is_left_in_written_files() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" >/dev/null
  local left
  left="$(grep -rli goweb "$TARGET" | grep -v '\.goweb-origin$\|/docs/superpowers/' || true)"
  assert_eq "" "$left"
}

test_a_failing_fast_tier_leaves_the_target_untouched() {
  new_env
  touch "$GW/FAIL_TEST_FAST"; git -C "$GW" add -A
  git -C "$GW" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fail
  echo keep > "$TARGET/mine.txt"
  local before after rc=0 out
  before="$(snapshot "$TARGET")"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 1 "$rc"
  after="$(snapshot "$TARGET")"
  assert_eq "$before" "$after"
}

test_existing_ios_files_are_not_modified() {
  new_env
  mkdir -p "$TARGET/ios/App"; echo "swift" > "$TARGET/ios/App/main.swift"; echo "mine" > "$TARGET/ios/README.md"
  local before out
  before="$(snapshot "$TARGET/ios")"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")"
  assert_eq "$before" "$(snapshot "$TARGET/ios")"
  assert_contains "$out" "skipped ios/"
  # without an ios/ in the target, goweb's placeholder is copied
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

# ---- scripts/deploy-app.sh: the Mac-side deploy settings -------------------------------------

deploy_app_env() {  # runs the generated deploy-app.sh with a fake ssh first on PATH
  make_fakebin "$T_ROOT/fakebin" ssh 'exit 0'
  export DEPLOY_ENV_LOG="$T_ROOT/deploy-env.log"; rm -f "$DEPLOY_ENV_LOG"
  PATH="$T_ROOT/fakebin:$PATH" bash "$TARGET/scripts/deploy-app.sh" "$@" 2>&1
}

test_deploy_app_exports_the_deploy_settings_and_runs_deploy_sh() {
  new_env
  run_scaffold "$TARGET" shop "Tom's & <Notes> \$HOME \`x\`" "desc" --port 8123 >/dev/null
  [ -x "$TARGET/scripts/deploy-app.sh" ]
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
  perl -pi -e 's/^ADDR=.*/ADDR=0.0.0.0:8222/' "$TARGET/.env.example"
  deploy_app_env me@host >/dev/null
  [ -e "$DEPLOY_ENV_LOG" ]
}

test_deploy_app_is_not_a_stale_layout_violation() {
  new_env
  run_scaffold "$TARGET" shop "Shop" "desc" --port 8123 >/dev/null
  # layout.test.sh scans for "deploy/<script>.sh"-style stale paths; the new script must not trip it
  ! grep -nE '(^|[^A-Za-z0-9_/])deploy/' "$TARGET/scripts/deploy-app.sh"
}

# ---- L3 warning: goweb's layout guard assumes goweb's own root ---------------------------------

test_warns_when_the_target_has_ios_or_a_root_claude_md() {
  new_env
  mkdir -p "$TARGET/ios"; echo x > "$TARGET/ios/a.swift"
  local out rc=0; out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 0 "$rc"
  assert_contains "$out" "scripts/layout.test.sh"
  assert_contains "$out" "L3"
  new_env
  echo "# mine" > "$TARGET/CLAUDE.md"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")"
  assert_contains "$out" "scripts/layout.test.sh"
  new_env
  mkdir -p "$TARGET/ios"; echo x > "$TARGET/ios/a.swift"; echo "# mine" > "$TARGET/CLAUDE.md"
  out="$(run_scaffold "$TARGET" shop "Shop" "desc")"
  assert_contains "$out" "make test"
}

test_no_layout_warning_for_an_empty_target() {
  new_env
  local rc=0 out; out="$(run_scaffold "$TARGET" shop "Shop" "desc")" || rc=$?
  assert_eq 0 "$rc"
  assert_not_contains "$out" "layout.test.sh"
  assert_not_contains "$out" "L3"
}

# ---- relative <repo-dir> ----------------------------------------------------------------------

test_relative_dot_target_lands_in_the_current_directory() {
  new_env
  local out
  out="$(cd "$TARGET" && bash "$SCAFFOLD" . shop "Shop" "desc" 2>&1)"
  [ -f "$TARGET/scripts/deploy-app.sh" ]; [ -f "$TARGET/.goweb-origin" ]
  local real; real="$(cd "$TARGET" && pwd -P)"
  assert_contains "$out" "written to $real"
  assert_not_contains "$out" "written to ."
}

test_relative_sibling_target_lands_in_the_intended_directory() {
  new_env
  mkdir "$T_ROOT/sib"
  local out
  out="$(cd "$T_ROOT/sib" && bash "$SCAFFOLD" ../app shop "Shop" "desc" 2>&1)"
  [ -f "$T_ROOT/app/scripts/deploy-app.sh" ]; [ ! -e "$T_ROOT/sib/app" ]
  assert_contains "$out" "written to $(cd "$T_ROOT/app" && pwd -P)"
}

test_a_failure_does_not_leave_a_new_target_dir_behind() {
  new_env
  touch "$GW/FAIL_TEST_FAST"; git -C "$GW" add -A
  git -C "$GW" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fail
  local rc=0
  (cd "$T_ROOT" && bash "$SCAFFOLD" newapp shop "Shop" "desc" >/dev/null 2>&1) || rc=$?
  assert_eq 1 "$rc"
  [ ! -e "$T_ROOT/newapp" ]
}
