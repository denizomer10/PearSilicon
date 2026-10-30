#!/bin/bash
# Local development helper: refresh selected apps in the default library only.
# Uses the checkout path below and does not handle relocated storage roots.
set -uo pipefail
ROOT="/Users/mac/pearsilicone"
LIBRARY="$HOME/Library/Application Support/PearSilicon/Applications"
RUNTIME="$ROOT/build/libPearRuntime.dylib"
SWIFT_OVERLAY="$ROOT/build/libswiftUIKit.dylib"
ENT="$HOME/Library/Application Support/PearSilicon/Work/entitlements.plist"

sign() {
  if [[ -f "$ENT" ]]; then
    codesign --force --sign - --entitlements "$ENT" "$1" >/dev/null 2>&1
  else
    codesign --force --sign - "$1" >/dev/null 2>&1
  fi
}

for id in "$@"; do
  APP="$LIBRARY/$id.app"
  [[ -d "$APP" ]] || { echo "missing $id"; continue; }
  mkdir -p "$APP/Frameworks"
  cp "$RUNTIME" "$APP/Frameworks/libPearRuntime.dylib"
  [[ -f "$SWIFT_OVERLAY" ]] && cp "$SWIFT_OVERLAY" "$APP/Frameworks/libswiftUIKit.dylib"
  for fw in "$APP"/Frameworks/*.framework; do
    [[ -d "$fw" ]] && sign "$fw"
  done
  while IFS= read -r f; do
    [[ -n "$f" ]] && sign "$f"
  done < <(find "$APP" -name '*.dylib' -type f 2>/dev/null)
  EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"
  [[ -n "$EXE" && -f "$APP/$EXE" ]] && sign "$APP/$EXE"
  if codesign --force --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1; then
    echo "ok $id"
  else
    echo "FAIL $id"
  fi
done
