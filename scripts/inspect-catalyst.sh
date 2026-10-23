#!/bin/bash
# Inspects Mac Catalyst apps to learn how macOS runs UIKit-based binaries:
# what platform value they use, and where they load UIKit from.
set -u

APPS=(
  "/System/Applications/Home.app"
  "/System/Applications/News.app"
  "/System/Applications/Stocks.app"
  "/System/Applications/VoiceMemos.app"
  "/System/Applications/Maps.app"
  "/System/Applications/Freeform.app"
)

for app in "${APPS[@]}"; do
  [ -d "$app" ] || continue
  plist="$app/Contents/Info.plist"
  exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)
  bin="$app/Contents/MacOS/$exe"
  [ -f "$bin" ] || continue

  echo "=== $app"
  echo "-- plist supported platforms:"
  /usr/libexec/PlistBuddy -c "Print :CFBundleSupportedPlatforms" "$plist" 2>/dev/null | tr -d '\n'; echo
  echo "-- dtplatform:"
  /usr/libexec/PlistBuddy -c "Print :DTPlatformName" "$plist" 2>/dev/null
  echo "-- binary build:"
  vtool -show-build "$bin" 2>/dev/null | grep -E "platform|minos|sdk"
  echo "-- UIKit load path:"
  otool -L "$bin" 2>/dev/null | grep -iE "UIKit|Catalyst|iOSSupport"
  echo
done
echo "=== done ==="
