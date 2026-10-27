#!/bin/bash
# Replaces the runtime dylib in every installed app with the freshly
# built one and re-signs each bundle inside-out.
#
# The runtime is copied into an app at install time, so apps installed with an
# older build keep an older runtime. This refreshes them without a full
# reinstall. Note: it only swaps the runtime — it does not re-run the Mach-O
# platform/slicing patches, so apps that need those still need a reinstall.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBRARY="$HOME/Library/Application Support/PearSilicon/Applications"
RUNTIME="$ROOT/build/libPearRuntime.dylib"
SWIFT_OVERLAY="$ROOT/build/libswiftUIKit.dylib"
ENT="$HOME/Library/Application Support/PearSilicon/Work/entitlements.plist"

[[ -f "$RUNTIME" ]] || { echo "runtime not built: $RUNTIME"; exit 1; }
[[ -f "$ENT" ]] || { echo "entitlements not found: $ENT"; exit 1; }

sign() {
  codesign --force --sign - --entitlements "$ENT" "$1" >/dev/null 2>&1
}

ok=0
fail=0

for APP in "$LIBRARY"/*.app; do
  [[ -d "$APP" ]] || continue
  name="$(basename "$APP")"

  mkdir -p "$APP/Frameworks"
  cp "$RUNTIME" "$APP/Frameworks/libPearRuntime.dylib"
  if [[ -f "$SWIFT_OVERLAY" ]]; then
    cp "$SWIFT_OVERLAY" "$APP/Frameworks/libswiftUIKit.dylib"
  fi

  # inside-out signing: nested code first, then the executable, then the bundle
  for fw in "$APP"/Frameworks/*.framework; do
    [[ -d "$fw" ]] && sign "$fw"
  done
  for x in "$APP"/PlugIns/*.appex "$APP"/PlugIns/*.framework; do
    [[ -d "$x" ]] && sign "$x"
  done
  while IFS= read -r f; do
    [[ -n "$f" ]] && sign "$f"
  done < <(find "$APP" -name '*.dylib' -type f 2>/dev/null)

  EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"
  [[ -n "$EXE" && -f "$APP/$EXE" ]] && sign "$APP/$EXE"

  if codesign --force --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1; then
    echo "  ok   $name"
    ok=$((ok + 1))
  else
    echo "  FAIL $name"
    fail=$((fail + 1))
  fi
done

echo "updated: $ok ok, $fail failed"
