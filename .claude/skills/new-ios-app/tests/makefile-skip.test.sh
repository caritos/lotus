#!/bin/bash
# Tests for web/Makefile's test-skills target: it skips the new-ios-app tier with one clear line when
# xcodegen or swift is not on PATH (CI runs on Linux), and still runs it when both exist.
# Also its test-ios target (part of `make test`): it runs ios/Caritos's `swift test` when swift is on PATH,
# skips with one clear line when it is not, and does nothing where there is no ios/Caritos (a new web app).
# A copy of the Makefile runs in a throwaway tree whose skill tests are stubs, with a fake-bin PATH.
# Usage: makefile-skip.test.sh        Prints PASS/FAIL lines and "passed: N failed: M".
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../../../.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/nia-makefile.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/web/scripts" "$T/.claude/skills/new-web-app/tests" "$T/.claude/skills/new-ios-app/tests" "$T/bin"
cp "$REPO/web/Makefile" "$T/web/Makefile"
cp "$REPO/web/scripts/build-id.sh" "$T/web/scripts/build-id.sh"
printf '#!/bin/bash\necho STUB-WEB-FAST\n' > "$T/.claude/skills/new-web-app/tests/run.sh"
printf '#!/bin/bash\necho STUB-IOS-FAST "$@"\n' > "$T/.claude/skills/new-ios-app/tests/scaffold.test.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/.claude/skills/new-ios-app/tests/makefile-skip.test.sh"  # stands in for this file
# PATH is only this directory: on a Mac /usr/bin/swift would otherwise still be found.
for t in make bash sh env git date cat sed grep awk tr head cut dirname basename uname mktemp rm cp mv; do
  for d in /usr/bin /bin; do [ -x "$d/$t" ] && { ln -s "$d/$t" "$T/bin/$t"; break; }; done
done
for tool in xcodegen swift; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$tool"; chmod +x "$T/bin/$tool"; done
mkdir -p "$T/ios/Caritos"; : > "$T/ios/Caritos/Package.swift"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/    /'; }
run() { OUT="$(cd "$T/web" && PATH="$T/bin" make --no-print-directory test-skills 2>&1)"; RC=$?; }

run
if [ $RC -eq 0 ] && echo "$OUT" | grep -q STUB-WEB-FAST && echo "$OUT" | grep -q 'STUB-IOS-FAST --fast' && ! echo "$OUT" | grep -q skipped; then
  ok "both tools present: the new-ios-app fast tier runs, nothing skipped"
else
  bad "both tools present" "rc=$RC $OUT"
fi

for gone in xcodegen swift; do
  mv "$T/bin/$gone" "$T/bin/$gone.off"
  run
  if [ $RC -eq 0 ] && echo "$OUT" | grep -q STUB-WEB-FAST && ! echo "$OUT" | grep -q STUB-IOS-FAST \
     && [ "$(echo "$OUT" | grep -c 'skipped new-ios-app tests: xcodegen or swift not installed')" = 1 ]; then
    ok "$gone missing: the new-ios-app tier is skipped with one clear line, the web tier still runs"
  else
    bad "$gone missing" "rc=$RC $OUT"
  fi
  mv "$T/bin/$gone.off" "$T/bin/$gone"
done

# ---- test-ios
printf '#!/bin/sh\necho "FAKE-SWIFT $*"\n' > "$T/bin/swift"; chmod +x "$T/bin/swift"
run_ios() { OUT="$(cd "$T/web" && PATH="$T/bin" make --no-print-directory test-ios 2>&1)"; RC=$?; }

run_ios
if [ $RC -eq 0 ] && echo "$OUT" | grep -q 'FAKE-SWIFT test --package-path ../ios/Caritos' && ! echo "$OUT" | grep -q skipped; then
  ok "test-ios: swift present runs swift test on ../ios/Caritos"
else
  bad "test-ios: swift present" "rc=$RC $OUT"
fi

printf '#!/bin/sh\necho FAKE-SWIFT-FAILS; exit 1\n' > "$T/bin/swift"
run_ios
if [ $RC -ne 0 ]; then ok "test-ios: a failing swift test fails the target"; else bad "test-ios: failing swift test" "rc=$RC $OUT"; fi
printf '#!/bin/sh\necho "FAKE-SWIFT $*"\n' > "$T/bin/swift"

mv "$T/bin/swift" "$T/bin/swift.off"
run_ios
if [ $RC -eq 0 ] && ! echo "$OUT" | grep -q FAKE-SWIFT \
   && [ "$(echo "$OUT" | grep -c 'skipped ios/Caritos tests: swift not installed')" = 1 ]; then
  ok "test-ios: swift missing is skipped with one clear line"
else
  bad "test-ios: swift missing" "rc=$RC $OUT"
fi
mv "$T/bin/swift.off" "$T/bin/swift"

mv "$T/ios/Caritos" "$T/ios/Caritos.off"
run_ios
if [ $RC -eq 0 ] && ! echo "$OUT" | grep -q FAKE-SWIFT && echo "$OUT" | grep -q 'test-ios: no ios/Caritos here, nothing to run'; then
  ok "test-ios: no ios/Caritos (a new web app) does nothing"
else
  bad "test-ios: no ios/Caritos" "rc=$RC $OUT"
fi
mv "$T/ios/Caritos.off" "$T/ios/Caritos"

# the full tier calls it (make -n prints the recursive make's recipe without running anything)
OUT="$(cd "$T/web" && PATH="$T/bin" make --no-print-directory -n test 2>&1)"
if echo "$OUT" | grep -q 'swift test --package-path ../ios/Caritos'; then
  ok "make test (full tier) runs test-ios"
else
  bad "make test runs test-ios" "$OUT"
fi
OUT="$(cd "$T/web" && PATH="$T/bin" make --no-print-directory -n test-fast 2>&1)"
if ! echo "$OUT" | grep -q 'swift test'; then ok "make test-fast does not run test-ios"; else bad "test-fast runs swift" "$OUT"; fi

echo "---"
echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
