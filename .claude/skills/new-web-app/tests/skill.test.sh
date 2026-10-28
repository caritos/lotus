#!/bin/bash
# Tests for SKILL.md (sourced by run.sh; lib.sh already loaded).
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SKILL_MD="$SKILL_DIR/SKILL.md"

test_skill_frontmatter_name_and_use_when() {
  [ "$(sed -n 1p "$SKILL_MD")" = "---" ]
  grep -q '^name: new-web-app$' "$SKILL_MD"
  grep -q '^description: Use when ' "$SKILL_MD"
}

test_skill_under_100_lines() {
  local n; n="$(wc -l < "$SKILL_MD")"
  [ "$n" -lt 100 ] || { echo "SKILL.md has $n lines" >&2; return 1; }
}

test_skill_carries_the_setup_table_and_failure_signatures() {
  local c; c="$(cat "$SKILL_MD")"
  for s in scripts/scaffold.sh ssh-copy-id 'ss -tln' 'ps aux' 'Proxy Server' 'deploy-app.sh' '--check' \
           install-backup-agent.sh backup-pull.env 'Index of /' 'SFTP' 'HTTP/1.0' 'Content-Length' \
           'Treasure Chest' '--port' '.go''web-origin' 'Retro before closing' 'rewrite' 'LOTUS_DIR' 'rename.sh --check' '.claude/skills'; do
    assert_contains "$c" "$s"
  done
}

test_skill_has_no_dead_references() {
  local md="$SKILL_MD" n=0 t rc=0 g="${LOTUS_DIR:-$(cd "$SKILL_DIR/../../.." && pwd -P)}"
  for t in $(grep -oE '[A-Za-z0-9_./~-]+\.sh' "$md" | sort -u); do
    n=$((n+1))
    case "$t" in
      scripts/scaffold.sh|*/new-web-app/scripts/scaffold.sh) [ -f "$SKILL_DIR/scripts/scaffold.sh" ] || { echo "missing $t" >&2; rc=1; } ;;
      */new-web-app/tests/run.sh) [ -f "$SKILL_DIR/tests/run.sh" ] || { echo "missing $t" >&2; rc=1; } ;;
      web/scripts/deploy-app.sh) grep -q 'deploy-app.sh' "$SKILL_DIR/scripts/scaffold.sh" || { echo "scaffold never writes $t" >&2; rc=1; } ;;
      web/scripts/*) [ -f "$g/$t" ] || { echo "$t not in the starter" >&2; rc=1; } ;;
      *) echo "unexpected script reference $t" >&2; rc=1 ;;
    esac
  done
  [ "$n" -gt 0 ] || { echo "no script references extracted" >&2; return 1; }
  return $rc
}

test_skill_has_no_obsolete_l3_note_or_home_checkout_path() {
  local c; c="$(cat "$SKILL_MD")"
  assert_not_contains "$c" "L3"
  assert_not_contains "$c" "~/src/lotus"
}

test_old_skill_names_are_gone() {
  local old="new-backend""-server"   # split so a repo-wide grep for the old name finds nothing here
  ! grep -q "$old" "$SKILL_MD"
  [ ! -d "$SKILL_DIR/templates" ]
  [ ! -d "$SKILL_DIR/../$old" ]
}
