#!/bin/bash
# Scaffold a new native iOS app: Kit package + thin SwiftUI app (XcodeGen) + ship.sh + deploy.sh.
#
# Usage: bash scaffold.sh <repo-dir> <AppName> <bundle-slug> ["Display Name"]
#   repo-dir     existing or new directory for the project (created if missing)
#   AppName      PascalCase, letters/digits only, e.g. Fressh      -> target, scheme, FresshKit
#   bundle-slug  lowercase-with-hyphens, e.g. fressh               -> com.caritos.fressh
#   Display Name shown under the icon (default: AppName)

set -euo pipefail

[ $# -ge 3 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
REPO="$1"; APP="$2"; SLUG="$3"; DISPLAY="${4:-$APP}"

[[ "$APP" =~ ^[A-Z][A-Za-z0-9]*$ ]]   || { echo "error: AppName must be PascalCase letters/digits: $APP" >&2; exit 2; }
[[ "$SLUG" =~ ^[a-z][a-z0-9-]*$ ]]    || { echo "error: bundle-slug must be lowercase-with-hyphens: $SLUG" >&2; exit 2; }
command -v xcodegen >/dev/null        || { echo "error: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do   # follow symlinks (the skill is linked into ~/.claude/skills)
  d="$(cd "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF" ;; esac
done
SKILL_DIR="$(cd "$(dirname "$SELF")/.." && pwd -P)"   # the script file may be reached through a linked skill dir
T="$SKILL_DIR/templates"
# .claude/skills/new-ios-app -> the lotus root is 3 levels up. The shared package is copied from lotus's
# committed HEAD (git archive), so uncommitted edits, untracked files and build products never reach an app.
LOTUS="$(cd "$SKILL_DIR/../../.." && pwd -P)"
CARITOS_SRC="$LOTUS/ios/Caritos"
top="$(git -C "$LOTUS" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$LOTUS" ]; then
  echo "error: $LOTUS is not a git repository; the shared package is copied from its committed HEAD" >&2; exit 1
fi
git -C "$LOTUS" cat-file -e "HEAD:ios/Caritos/Package.swift" 2>/dev/null \
  || { echo "error: shared package not found at $CARITOS_SRC in the committed HEAD of $LOTUS" >&2; exit 1; }
IOS="$REPO/ios"
APPDIR="$IOS/App"
XPROJ="$APPDIR/$APP"

if [ -e "$IOS/Package.swift" ] || [ -e "$XPROJ" ]; then
  echo "error: $IOS already looks scaffolded; refusing to overwrite." >&2; exit 1
fi

# Extract the snapshot before anything is created, so a failure leaves no partial scaffold.
# The target is lotus itself when its ios/Caritos is the source: then nothing is copied.
SELF_TARGET=0
if [ -d "$IOS/Caritos" ] && [ "$(cd "$IOS/Caritos" && pwd -P)" = "$CARITOS_SRC" ]; then SELF_TARGET=1; fi
CARITOS_TMP=""
if [ "$SELF_TARGET" = 0 ]; then
  CARITOS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nia-caritos.XXXXXX")"
  trap 'rm -rf "$CARITOS_TMP"' EXIT
  git -C "$LOTUS" archive HEAD:ios/Caritos | tar -x -C "$CARITOS_TMP" \
    || { echo "error: could not extract ios/Caritos from the committed HEAD of $LOTUS" >&2; exit 1; }
fi

fill() {  # fill <template> <dest>
  mkdir -p "$(dirname "$2")"
  sed -e "s/__APP__/$APP/g" -e "s/__SLUG__/$SLUG/g" -e "s/__DISPLAY__/$DISPLAY/g" "$1" > "$2"
}

mkdir -p "$REPO"
fill "$T/Package.swift"               "$IOS/Package.swift"
fill "$T/kit/Greeting.swift"          "$IOS/Sources/${APP}Kit/Greeting.swift"
fill "$T/kit/GreetingTests.swift"     "$IOS/Tests/${APP}KitTests/GreetingTests.swift"
fill "$T/kit/CaritosLinkTests.swift"  "$IOS/Tests/${APP}KitTests/CaritosLinkTests.swift"
# Snapshot of the shared package from lotus's committed HEAD; fixes go to lotus first.
if [ "$SELF_TARGET" = 0 ]; then
  mkdir -p "$IOS/Caritos"
  (cd "$CARITOS_TMP" && tar -cf - .) | tar -xf - -C "$IOS/Caritos"
fi
fill "$T/project.yml"                "$XPROJ/project.yml"
fill "$T/app/App.swift"               "$XPROJ/$APP/${APP}App.swift"
fill "$T/app/ContentView.swift"       "$XPROJ/$APP/ContentView.swift"
fill "$T/gitignore"                   "$IOS/.gitignore"
[ -e "$REPO/CLAUDE.md" ] || fill "$T/CLAUDE.md" "$REPO/CLAUDE.md"

cp "$T/ship.sh" "$T/deploy.sh" "$T/ExportOptions.plist" "$T/asc-verify.mjs" "$APPDIR/"
chmod +x "$APPDIR/ship.sh" "$APPDIR/deploy.sh"
printf 'APP_NAME=%s\nPROJECT_DIR=%s\nBUNDLE_ID=com.caritos.%s\n' "$APP" "$APP" "$SLUG" > "$APPDIR/app.env"

# Placeholder 1024x1024 opaque RGB icon (no alpha) so the first TestFlight upload isn't rejected.
ICONSET="$XPROJ/$APP/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
cat > "$XPROJ/$APP/Assets.xcassets/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
python3 -I - "$ICONSET/icon-1024.png" <<'PY'
import sys, zlib, struct
n = 1024
row = b"\x00" + bytes([40, 90, 200]) * n          # filter byte + RGB pixels
raw = row * n
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0)) \
      + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

(cd "$XPROJ" && xcodegen generate)

echo ""
echo "Scaffolded $APP in $REPO"
echo "  swift test        (cd $IOS && swift test)"
echo "  deploy to phone   $APPDIR/deploy.sh"
echo "  ship to TestFlight $APPDIR/ship.sh --check   # then ./ship.sh"
echo ""
echo "Before the first ship.sh (the only manual steps; ship.sh does the rest):"
echo "  1. create the app record in App Store Connect for com.caritos.$SLUG"
echo "       My Apps -> + -> New App, bundle ID com.caritos.$SLUG (the API cannot do this)"
echo "  2. ~/.appstoreconnect/env + private_keys/AuthKey_<id>.p8 exist (one-time per machine)"
echo "  3. replace the placeholder icon (~/src/generate-ios-icon), opaque 1024px, no alpha"
echo "ship.sh then creates the Internal TestFlight group, waits for the build to be VALID,"
echo "and exits non-zero if it is not. Set TESTER_EMAIL=<your ASC user email> to be added to the group."
