#!/bin/bash
# Tests for scripts/scaffold.sh: it copies the shared Caritos package into the app and depends on it.
# Usage: scaffold.test.sh [--fast]   (--fast skips the `swift test` step in a scaffolded app)
# Prints PASS/FAIL lines and "passed: N failed: M"; exits non-zero on any failure.
export PATH="/usr/bin:/bin:/opt/homebrew/bin:$PATH"
FAST=0
case "${1:-}" in "") ;; --fast) FAST=1 ;; *) echo "usage: scaffold.test.sh [--fast]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
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
done

if [ "$FAST" = 0 ]; then
  t_swift_test() { (cd "$T_ROOT/linked/ios" && swift test); }
  check "linked: swift test passes in the scaffolded app (incl. CaritosLinkTests)" t_swift_test
else
  echo "skip swift test (--fast)"
fi

echo "---"
echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
