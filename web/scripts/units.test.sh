#!/usr/bin/env bash
# Guards the systemd units in web/deploy/. The namespace-based sandbox lines
# (ProtectSystem, ReadWritePaths, PrivateTmp) must ship commented out: they exit with
# status=226/NAMESPACE on hosts that refuse unprivileged mount namespaces, and a reboot
# can turn such a host on without warning (caritos.com, 2026-10-30: 502 until fixed).
# NoNewPrivileges needs no namespace and stays on.
# Run: bash web/scripts/units.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
no() { fail=$((fail+1)); echo "FAIL - $1"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }

for u in app.service app-backup.service; do
  f="$DEPLOY/$u"
  check "$u: exists" test -f "$f"
  for key in ProtectSystem ReadWritePaths PrivateTmp; do
    check "$u: $key is not active" test -z "$(grep -E "^[[:space:]]*$key=" "$f")"
    check "$u: $key is kept as a commented line to switch on" grep -qE "^#[[:space:]]*$key=" "$f"
  done
  check "$u: NoNewPrivileges stays active" grep -qE '^NoNewPrivileges=yes$' "$f"
  check "$u: explains the 226/NAMESPACE reason" grep -q '226/NAMESPACE' "$f"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
