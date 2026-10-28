#!/bin/bash
# Build, bump the build number, and upload to TestFlight - entirely via CLI
# (xcodebuild + an App Store Connect API key). No Xcode GUI, no Apple ID login.
# After it finishes, install the build from the TestFlight app on your phone.
#
# Usage: ./ship.sh [--check]
#   --check   Validate setup and do an unsigned simulator build. Uploads nothing,
#             touches no signing, changes no files except the regenerated project.
#
# Env:
#   NEXT_MARKETING_VERSION=2.0   also change the marketing version (default: build number only)
#   API_KEY_ID / API_ISSUER_ID   override ~/.appstoreconnect/env
#
# One-time setup (shared by every app):
#   1. App Store Connect -> Users and Access -> Integrations -> App Store Connect API:
#      create a key (role App Manager or Admin), download the .p8 ONCE, save it as
#      ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   2. Create ~/.appstoreconnect/env containing:
#        API_KEY_ID=<KEY_ID>
#        API_ISSUER_ID=<issuer uuid shown on that page>
# One-time setup (per app):
#   3. Create the app record in App Store Connect (My Apps -> + -> New App) using this
#      app's bundle ID. The upload is rejected until that record exists.
#
# Deliberately does NOT submit for App Store review - it only lands in TestFlight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/app.env"   # APP_NAME, PROJECT_DIR (xcodegen dir, relative to this script)

CHECK=false
[ "${1:-}" = "--check" ] && CHECK=true

# Homebrew's rsync rejects Apple's --extended-attributes flag, which breaks the export step.
export PATH="/usr/bin:$PATH"

PROJECT_PATH="$SCRIPT_DIR/$PROJECT_DIR"
PROJECT_YML="$PROJECT_PATH/project.yml"
XCODEPROJ="$APP_NAME.xcodeproj"
BUILD_DIR="${TMPDIR:-/tmp}/${APP_NAME}-ship-build"

STAGE=setup
on_exit() {
  local rc=$?
  [ $rc -eq 0 ] && return
  [ "$STAGE" = "build" ] || return 0   # config errors above are self-explanatory
  echo "" >&2
  echo "ship.sh failed (exit $rc). Common causes:" >&2
  echo "  - errSecInternalComponent: keychain is locked (typical over SSH). Run:" >&2
  echo "      security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
  echo "  - Upload rejected / app not found: create the app record in App Store Connect for this bundle ID." >&2
  echo "  - ITMS-90592: ITSAppUsesNonExemptEncryption must be false (never set a compliance code)." >&2
  echo "  - Version rejected: the marketing version must be >= the live App Store version." >&2
}
trap on_exit EXIT

command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }

# --- App Store Connect credentials -------------------------------------------------
# shellcheck source=/dev/null
[ -f "$HOME/.appstoreconnect/env" ] && source "$HOME/.appstoreconnect/env"
KEY_DIR="$HOME/.appstoreconnect/private_keys"
if [ -z "${API_KEY_ID:-}" ]; then
  shopt -s nullglob
  keys=("$KEY_DIR"/AuthKey_*.p8)
  shopt -u nullglob
  if [ "${#keys[@]}" -eq 1 ]; then
    API_KEY_ID="$(basename "${keys[0]}" .p8)"; API_KEY_ID="${API_KEY_ID#AuthKey_}"
  fi
fi
API_KEY_PATH="$KEY_DIR/AuthKey_${API_KEY_ID:-MISSING}.p8"

asc_problem=""
if [ -z "${API_KEY_ID:-}" ]; then
  asc_problem="API_KEY_ID not set (put it in ~/.appstoreconnect/env)"
elif [ -z "${API_ISSUER_ID:-}" ]; then
  asc_problem="API_ISSUER_ID not set (put it in ~/.appstoreconnect/env)"
elif [ ! -f "$API_KEY_PATH" ]; then
  asc_problem="API key not found at $API_KEY_PATH"
fi

# --- Project -----------------------------------------------------------------------
echo "==> Regenerating Xcode project from project.yml"
(cd "$PROJECT_PATH" && xcodegen generate)

if $CHECK; then
  echo "==> Check: unsigned simulator build"
  (cd "$PROJECT_PATH" && xcodebuild build \
    -project "$XCODEPROJ" -scheme "$APP_NAME" -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO -quiet)
  if [ -n "$asc_problem" ]; then
    echo "WARNING: $asc_problem   (ship.sh would fail here)" >&2
  else
    echo "==> App Store Connect key OK ($API_KEY_ID)"
  fi
  echo "==> Check passed."
  exit 0
fi

[ -z "$asc_problem" ] || { echo "error: $asc_problem" >&2; exit 1; }

get_yml() { awk -v k="$1:" '$1==k {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML"; }
MARKETING_VERSION="$(get_yml MARKETING_VERSION)"
CURRENT_BUILD="$(get_yml CURRENT_PROJECT_VERSION)"
[ -n "$MARKETING_VERSION" ] && [ -n "$CURRENT_BUILD" ] || { echo "error: could not read versions from $PROJECT_YML" >&2; exit 1; }
NEXT_BUILD=$((CURRENT_BUILD + 1))
NEXT_MARKETING_VERSION="${NEXT_MARKETING_VERSION:-$MARKETING_VERSION}"

STAGE=build
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

AUTH=(-allowProvisioningUpdates
  -authenticationKeyPath "$API_KEY_PATH"
  -authenticationKeyID "$API_KEY_ID"
  -authenticationKeyIssuerID "$API_ISSUER_ID")

# Version/build are passed as overrides and written to project.yml only AFTER a successful
# archive + export, so a failed run leaves the working tree untouched.
echo "==> Archiving $APP_NAME $NEXT_MARKETING_VERSION (build $NEXT_BUILD)..."
(cd "$PROJECT_PATH" && xcodebuild archive \
  -project "$XCODEPROJ" -scheme "$APP_NAME" -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -skipPackagePluginValidation \
  "${AUTH[@]}" \
  MARKETING_VERSION="$NEXT_MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$NEXT_BUILD")

# ExportOptions.plist has destination=upload, so this step uploads straight to TestFlight.
echo "==> Exporting and uploading to App Store Connect..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  "${AUTH[@]}"

echo "==> Recording shipped version in project.yml"
sed -i '' -E "s/(MARKETING_VERSION: *\"?)[^\" ]+/\1$NEXT_MARKETING_VERSION/" "$PROJECT_YML"
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: *\"?)[^\" ]+/\1$NEXT_BUILD/" "$PROJECT_YML"
(cd "$PROJECT_PATH" && xcodegen generate)

# Confirm TestFlight can deliver it: Internal group exists with automatic distribution
# and the build reaches VALID. Skipped for apps whose app.env has no BUNDLE_ID.
STAGE=verify
VERIFY_RC=0
if [ -n "${BUNDLE_ID:-}" ] && [ -f "$SCRIPT_DIR/asc-verify.mjs" ]; then
  echo "==> Waiting for Apple to process build $NEXT_BUILD (up to ${WAIT_MINUTES:-40} min)"
  "$(command -v bun || command -v node)" "$SCRIPT_DIR/asc-verify.mjs" "$BUNDLE_ID" "$NEXT_BUILD" || VERIFY_RC=$?
fi

echo ""
echo "Uploaded $APP_NAME v$NEXT_MARKETING_VERSION (build $NEXT_BUILD) to App Store Connect."
case "$VERIFY_RC" in
  0) echo "Build is VALID. Install it from the TestFlight app." ;;
  3) echo "Still processing at Apple; it will appear in TestFlight shortly." ;;
  *) echo "Upload succeeded but TestFlight verification failed (exit $VERIFY_RC); see the asc-verify messages above." >&2 ;;
esac
echo "Commit the version bump: project.yml and $PROJECT_DIR/$XCODEPROJ/project.pbxproj"
exit "$VERIFY_RC"
