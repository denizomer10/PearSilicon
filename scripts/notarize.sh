#!/bin/bash
# Developer ID signing + Apple notarization for PearSilicon.
#
# Prerequisites:
#   1. An Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in the login keychain.
#   3. Notary credentials stored once:
#        xcrun notarytool store-credentials "pearsilicon-notary" \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "app-specific-password"
#
# Usage:
#   PEAR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   PEAR_NOTARY_PROFILE="pearsilicon-notary" \
#   ./scripts/notarize.sh build/PearSilicon.app
#
# This script does not create certificates, enroll in the Developer Program, or
# bypass Gatekeeper. Without a Developer ID and notarization, builds remain
# ad-hoc and macOS will warn when they are downloaded.
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/PearSilicon.app}"
IDENTITY="${PEAR_SIGN_IDENTITY:?Set PEAR_SIGN_IDENTITY to a Developer ID Application certificate}"
PROFILE="${PEAR_NOTARY_PROFILE:?Set PEAR_NOTARY_PROFILE to a notarytool keychain profile}"

if [[ ! -d "$APP" ]]; then
  echo "ERROR: app bundle not found: $APP" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
  echo "ERROR: signing identity not found in the keychain: $IDENTITY" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notary profile is not usable. Store credentials with notarytool first." >&2
  exit 1
fi

echo ">> Signing with hardened runtime and timestamp"
# Sign nested frameworks/dylibs first, then the outer app. --deep is used only
# here as a safety net for nested code this project may add later.
find "$APP/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 |
  while IFS= read -r -d '' file; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$file"
  done
find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0 2>/dev/null |
  while IFS= read -r -d '' framework; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$framework"
  done
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pear-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/PearSilicon.zip"
echo ">> Creating notarization archive"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ">> Submitting to Apple notary service"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo ">> Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo ">> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

echo ">> Notarized app: $APP"
echo "Distribute this signed and stapled app. Do not re-zip an ad-hoc build."
