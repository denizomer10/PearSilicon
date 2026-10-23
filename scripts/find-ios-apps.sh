#!/bin/bash
# Scans app bundles on this Mac and reports those whose main executable is an
# iOS binary (i.e. how Apple ships "Designed for iPad" apps).
set -u

for dir in /Applications "$HOME/Applications" /System/Applications /System/Applications/Utilities; do
  [ -d "$dir" ] || continue
  for app in "$dir"/*.app; do
    [ -d "$app" ] || continue
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || continue

    plats=$(/usr/libexec/PlistBuddy -c "Print :CFBundleSupportedPlatforms" "$plist" 2>/dev/null)
    if printf '%s' "$plats" | grep -qi "iPhoneOS"; then
      echo "=== iOS APP: $app"
      printf '%s\n' "$plats" | tr -d '\n'
      echo

      exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)
      bin="$app/Contents/MacOS/$exe"
      [ -f "$bin" ] || bin="$app/$exe"
      if [ -f "$bin" ]; then
        echo "-- binary: $bin"
        vtool -show-build "$bin" 2>/dev/null | grep -E "platform|minos|sdk"
        echo "-- entitlements:"
        codesign -d --entitlements - "$bin" 2>/dev/null | grep -E "get-task-allow|platform-application|iossimulator|no-container|library-validation"
      fi
    fi
  done
done
echo "=== scan done ==="
