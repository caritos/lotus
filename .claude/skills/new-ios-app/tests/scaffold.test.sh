#!/bin/bash
# Tests for scripts/scaffold.sh: it copies the shared Caritos package from lotus's committed HEAD into the
# app and depends on it. The HEAD-only cases run against throwaway git copies, never this checkout.
# Usage: scaffold.test.sh [--fast]   (--fast skips the `swift test` step in a scaffolded app)
# Prints PASS/FAIL lines and "passed: N failed: M"; exits non-zero on any failure.
export PATH="/usr/bin:/bin:/opt/homebrew/bin:$PATH"
FAST=0
case "${1:-}" in "") ;; --fast) FAST=1 ;; *) echo "usage: scaffold.test.sh [--fast]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
LOTUS="$(cd "$SKILL_DIR/../../.." && pwd -P)"
T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nia-scaffold.XXXXXX")"
trap 'rm -rf "$T_ROOT"' EXIT

pass=0; fail=0
check() {  # check <name> <command...>
  local name="$1"; shift
  if "$@" >"$T_ROOT/out.log" 2>&1; then pass=$((pass+1)); echo "PASS $name"
  else fail=$((fail+1)); echo "FAIL $name"; sed 's/^/    /' "$T_ROOT/out.log" | tail -25; fi
}

# The skill reached through a symlink, the way ~/.claude/skills/new-ios-app is.
ln -s "$SKILL_DIR" "$T_ROOT/linked-skill"

# Scaffold twice: directly and through the symlink.
bash "$SKILL_DIR/scripts/scaffold.sh" "$T_ROOT/direct" Demo demo >"$T_ROOT/direct.log" 2>&1 || { echo "scaffold (direct) failed:"; tail -20 "$T_ROOT/direct.log"; }
bash "$T_ROOT/linked-skill/scripts/scaffold.sh" "$T_ROOT/linked" Demo demo >"$T_ROOT/linked.log" 2>&1 || { echo "scaffold (symlink) failed:"; tail -20 "$T_ROOT/linked.log"; }

for kind in direct linked; do
  R="$T_ROOT/$kind"
  t_has_package() { [ -f "$R/ios/Caritos/Package.swift" ] && [ -d "$R/ios/Caritos/Sources/CaritosLogging" ] && [ -d "$R/ios/Caritos/Tests" ]; }
  t_no_build() { [ ! -e "$R/ios/Caritos/.build" ] && [ ! -e "$R/ios/Caritos/.swiftpm" ]; }
  t_package_dep() { grep -q 'dependencies: \[.package(path: "Caritos")\]' "$R/ios/Package.swift"; }
  t_product_dep() { grep -q '.product(name: "CaritosLogging", package: "Caritos")' "$R/ios/Package.swift"; }
  t_link_test() { grep -q 'import CaritosLogging' "$R/ios/Tests/DemoKitTests/CaritosLinkTests.swift" && grep -q 'LogLevel.error > LogLevel.debug' "$R/ios/Tests/DemoKitTests/CaritosLinkTests.swift"; }
  t_no_placeholders() { ! grep -rq '__APP__' "$R/ios/Package.swift" "$R/ios/Tests"; }
  check "$kind: copies ios/Caritos with its sources and tests" t_has_package
  check "$kind: the copy excludes .build and .swiftpm" t_no_build
  check "$kind: Package.swift names the Caritos path package" t_package_dep
  check "$kind: the Kit depends on CaritosLogging" t_product_dep
  check "$kind: CaritosLinkTests is generated" t_link_test
  check "$kind: no placeholder is left" t_no_placeholders
  t_claude_snapshot() { grep -q 'ios/Caritos.*read-only snapshot' "$R/CLAUDE.md" && grep -q 'fix .*in lotus first' "$R/CLAUDE.md"; }
  check "$kind: CLAUDE.md says ios/Caritos is a read-only snapshot fixed in lotus first" t_claude_snapshot
  t_gitignore() { grep -qx '\.build/' "$R/ios/.gitignore" && grep -qx '\.swiftpm/' "$R/ios/.gitignore"; }
  check "$kind: ios/.gitignore ignores .build/ and .swiftpm/" t_gitignore
done

# ---- copies from the committed HEAD, in a throwaway git copy: this skill as it is now + ios/Caritos as committed
qgit() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
mk_src() {  # mk_src <dir> [with-caritos]: a minimal lotus holding this skill, optionally with ios/Caritos
  mkdir -p "$1/.claude/skills/new-ios-app"
  (cd "$SKILL_DIR" && tar -cf - .) | tar -xf - -C "$1/.claude/skills/new-ios-app"
  if [ "${2:-}" = with-caritos ]; then git -C "$LOTUS" archive HEAD ios/Caritos | tar -x -C "$1"; fi
}
SRC="$T_ROOT/src"
mk_src "$SRC" with-caritos
qgit -C "$SRC" init -q
qgit -C "$SRC" add -A
qgit -C "$SRC" commit -q -m src
COMMITTED_README="$(cat "$SRC/ios/Caritos/README.md")"
echo "UNCOMMITTED-EDIT" >> "$SRC/ios/Caritos/README.md"
echo scratch > "$SRC/ios/Caritos/UNTRACKED-SCRATCH.txt"
: > "$SRC/ios/Caritos/.DS_Store"
mkdir -p "$SRC/ios/Caritos/.build" "$SRC/ios/Caritos/.swiftpm"
: > "$SRC/ios/Caritos/.build/junk"
: > "$SRC/ios/Caritos/.swiftpm/junk"
bash "$SRC/.claude/skills/new-ios-app/scripts/scaffold.sh" "$T_ROOT/fromhead" Demo demo >"$T_ROOT/fromhead.log" 2>&1
HEAD_RC=$?
H="$T_ROOT/fromhead/ios/Caritos"
t_head_ok() { [ "$HEAD_RC" = 0 ] && [ -f "$H/Package.swift" ] || { cat "$T_ROOT/fromhead.log"; false; }; }
t_head_no_edit() { [ "$(cat "$H/README.md")" = "$COMMITTED_README" ]; }
t_head_no_untracked() { [ ! -e "$H/UNTRACKED-SCRATCH.txt" ] && [ ! -e "$H/.DS_Store" ]; }
t_head_no_build() { [ ! -e "$H/.build" ] && [ ! -e "$H/.swiftpm" ]; }
check "from HEAD: the scaffold succeeds" t_head_ok
check "from HEAD: an uncommitted edit under ios/Caritos does not reach the app" t_head_no_edit
check "from HEAD: untracked files (.DS_Store, scratch) do not reach the app" t_head_no_untracked
check "from HEAD: .build and .swiftpm do not reach the app" t_head_no_build

# the target is lotus itself: ios/Caritos is the source, so it is left alone (no copy onto itself)
bash "$SRC/.claude/skills/new-ios-app/scripts/scaffold.sh" "$SRC" Demo demo >"$T_ROOT/self.log" 2>&1
SELF_RC=$?
t_self() { [ "$SELF_RC" = 0 ] && [ -f "$SRC/ios/Caritos/UNTRACKED-SCRATCH.txt" ] && grep -q UNCOMMITTED-EDIT "$SRC/ios/Caritos/README.md" \
  && [ -f "$SRC/ios/Package.swift" ] || { echo "rc=$SELF_RC"; cat "$T_ROOT/self.log"; false; }; }
check "into lotus itself: the scaffold succeeds and leaves ios/Caritos untouched" t_self

# the lotus root is not a git repository: refuse, create nothing
NOGIT="$T_ROOT/nogit"
mk_src "$NOGIT" with-caritos
bash "$NOGIT/.claude/skills/new-ios-app/scripts/scaffold.sh" "$T_ROOT/nogit-app" Demo demo >"$T_ROOT/nogit.log" 2>&1
NOGIT_RC=$?
t_nogit() { [ "$NOGIT_RC" = 1 ] && grep -q 'is not a git repository' "$T_ROOT/nogit.log" && [ ! -e "$T_ROOT/nogit-app" ] || { echo "rc=$NOGIT_RC"; cat "$T_ROOT/nogit.log"; false; }; }
check "lotus is not a git repo: exit 1, a clear message, nothing created" t_nogit

# HEAD has no ios/Caritos (only an uncommitted copy in the working tree): refuse, create nothing
NOPKG="$T_ROOT/nopkg"
mk_src "$NOPKG"
qgit -C "$NOPKG" init -q
qgit -C "$NOPKG" add -A
qgit -C "$NOPKG" commit -q -m nopkg
git -C "$LOTUS" archive HEAD ios/Caritos | tar -x -C "$NOPKG"
bash "$NOPKG/.claude/skills/new-ios-app/scripts/scaffold.sh" "$T_ROOT/nopkg-app" Demo demo >"$T_ROOT/nopkg.log" 2>&1
NOPKG_RC=$?
t_nopkg() { [ "$NOPKG_RC" = 1 ] && grep -q 'shared package not found' "$T_ROOT/nopkg.log" && [ ! -e "$T_ROOT/nopkg-app" ] || { echo "rc=$NOPKG_RC"; cat "$T_ROOT/nopkg.log"; false; }; }
check "HEAD lacks ios/Caritos: exit 1, \"shared package not found\", nothing created" t_nopkg

if [ "$FAST" = 0 ]; then
  t_swift_test() { (cd "$T_ROOT/linked/ios" && swift test); }
  check "linked: swift test passes in the scaffolded app (incl. CaritosLinkTests)" t_swift_test
else
  echo "skip swift test (--fast)"
fi

echo "---"
echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
