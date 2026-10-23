#!/bin/bash
# Builds a distributable ZIP for installing PearSilicon: the app bundle,
# archived with ditto so code signatures, permissions, extended attributes and
# symlinks survive the round trip. The user unzips it and drags the app into
# /Applications.
#
# Usage: make-zip.sh [debug|release]   (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="PearSilicon"
CONFIG="${1:-release}"
APP="$ROOT/build/$APP_NAME.app"
ZIP="$ROOT/build/$APP_NAME.zip"

# --- 1) Build the app -----------------------------------------------------
echo ">> Building app ($CONFIG)"
"$ROOT/scripts/build-app.sh" "$CONFIG"

# --- 2) Create the archive ------------------------------------------------
# --keepParent keeps PearSilicon.app as the top-level entry, so extracting
# yields the bundle directly instead of dumping its contents into the folder.
echo ">> Creating $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ">> Done: $ZIP"
ls -lh "$ZIP" | awk '{print "   " $5, $9}'
