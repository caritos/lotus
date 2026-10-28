#!/bin/bash
# Build the app and install + launch it on a connected iPhone - entirely via CLI
# (xcodebuild + xcrun devicectl). No Xcode GUI. This is the fast inner loop;
# use ship.sh for TestFlight.
#
# Usage: ./deploy.sh [--list] [device-name-substring]
#   ./deploy.sh                 # first connected iPhone/iPad
#   ./deploy.sh "16 Plus"       # first connected device whose name contains this
#   ./deploy.sh --list          # show devices and what would be picked, then exit
# Env: DEVICE=<substring> is the same as the argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/app.env"   # APP_NAME, PROJECT_DIR (xcodegen dir, relative to this script)

LIST_ONLY=false
if [ "${1:-}" = "--list" ]; then LIST_ONLY=true; shift; fi
WANT="${1:-${DEVICE:-}}"

PROJECT_PATH="$SCRIPT_DIR/$PROJECT_DIR"
XCODEPROJ="$APP_NAME.xcodeproj"
DERIVED="$PROJECT_PATH/DerivedData"

# devicectl takes the CoreDevice identifier; xcodebuild -destination takes the UDID.
# Parse JSON, not the text table (device names contain curly apostrophes).
JSON="$(mktemp)"; trap 'rm -f "$JSON"' EXIT
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true

PICK="$(python3 -I - "$JSON" "$WANT" "$LIST_ONLY" <<'PY'
import json, sys
path, want, list_only = sys.argv[1], sys.argv[2].lower(), sys.argv[3] == "true"
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    devices = []
rows = []
for d in devices:
    hw, dp, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS":
        continue
    rows.append({"name": dp.get("name", ""), "core": d["identifier"], "udid": hw.get("udid", ""),
                 "kind": hw.get("deviceType", ""), "pair": cp.get("pairingState"), "tunnel": cp.get("tunnelState")})
paired = [r for r in rows if r["pair"] == "paired"]
if want:
    # An explicit name may match a device that is asleep ("disconnected"); never an "unavailable" one.
    usable = [r for r in paired if want in r["name"].lower() and r["tunnel"] in ("connected", "disconnected")]
    usable.sort(key=lambda r: r["tunnel"] != "connected")
else:
    # No name: only devices that are actually connected right now, iPhones before iPads.
    usable = [r for r in paired if r["tunnel"] == "connected"]
    usable.sort(key=lambda r: r["kind"] != "iPhone")
    iphones = [r for r in usable if r["kind"] == "iPhone"]
    if len(iphones) > 1 or (not iphones and len(usable) > 1):
        pool = iphones or usable
        print("error: more than one device is connected; pass a name (or export DEVICE=...):", file=sys.stderr)
        for r in pool:
            print(f"  {r['name']}", file=sys.stderr)
        sys.exit(3)
if list_only:
    for r in rows:
        mark = "->" if usable and r is usable[0] else "  "
        print(f"{mark} {r['name']}  [{r['pair']}, {r['tunnel']}]", file=sys.stderr)
if usable:
    u = usable[0]
    print(f"{u['core']}|{u['udid']}|{u['name']}")
PY
)" || exit 1

if $LIST_ONLY; then exit 0; fi

if [ -z "$PICK" ]; then
  echo "error: no connected iPhone/iPad${WANT:+ matching '$WANT'}." >&2
  echo "Plug the phone in (or enable wireless debugging), unlock it, and run ./deploy.sh --list." >&2
  exit 1
fi
IFS='|' read -r CORE_ID UDID NAME <<< "$PICK"
echo "==> Device: $NAME"

echo "==> Building $APP_NAME (Debug)..."
(cd "$PROJECT_PATH" && xcodegen generate >/dev/null 2>&1 || true)
(cd "$PROJECT_PATH" && xcodebuild build \
  -project "$XCODEPROJ" -scheme "$APP_NAME" -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -skipPackagePluginValidation -quiet)

APP_PATH="$(ls -d "$DERIVED"/Build/Products/Debug-iphoneos/*.app | head -1)"
BUNDLE_ID="$(defaults read "$APP_PATH/Info" CFBundleIdentifier)"

echo "==> Installing $BUNDLE_ID..."
xcrun devicectl device install app --device "$CORE_ID" "$APP_PATH"

echo "==> Launching..."
if ! OUT="$(xcrun devicectl device process launch --terminate-existing --device "$CORE_ID" "$BUNDLE_ID" 2>&1)"; then
  echo "$OUT" >&2
  case "$OUT" in
    *[Ll]ocked*) echo "hint: unlock the phone and run ./deploy.sh again (installed, not launched)." >&2 ;;
    *[Tt]rust*|*profile*) echo "hint: on the phone, Settings > General > VPN & Device Management > trust the developer, then rerun." >&2 ;;
  esac
  exit 1
fi
echo "==> Done. $BUNDLE_ID is running on $NAME."
