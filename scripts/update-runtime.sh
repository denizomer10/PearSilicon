#!/bin/bash
# Refreshes runtime libraries in the default Application Support library only
# and re-signs each bundle inside-out. Relocated storage roots are not handled;
# build the runtime before running this script.
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
CXX_COMPAT="$ROOT/build/libcxxcompat.dylib"
MARKETPLACE_STUB="$ROOT/build/MarketplaceKit.framework"
ENT_DIR="$HOME/Library/Application Support/PearSilicon/Work"
# Shipping installs carry no extra entitlements. Set PEAR_DEBUG_SIGNING=1 for a
# short debugging session (get-task-allow and JIT keys) when LLDB is needed.
if [[ "${PEAR_DEBUG_SIGNING:-0}" == "1" ]]; then
  ENT="$ENT_DIR/debug-entitlements.plist"
else
  ENT="$ENT_DIR/entitlements.plist"
fi

[[ -f "$RUNTIME" ]] || { echo "runtime not built: $RUNTIME"; exit 1; }

sign() {
  if [[ -f "$ENT" ]]; then
    codesign --force --sign - --entitlements "$ENT" "$1" >/dev/null 2>&1
  else
    codesign --force --sign - "$1" >/dev/null 2>&1
  fi
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

  # Only apps that reference MarketplaceKit carry this stub. Refresh it for
  # those; deleting first keeps the framework's symlink layout intact.
  if [[ -d "$MARKETPLACE_STUB" && -d "$APP/Frameworks/MarketplaceKit.framework" ]]; then
    rm -rf "$APP/Frameworks/MarketplaceKit.framework"
    cp -R "$MARKETPLACE_STUB" "$APP/Frameworks/"
  fi

  EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"
  if [[ -f "$CXX_COMPAT" && -n "$EXE" && -f "$APP/$EXE" ]] &&
     nm -gU "$APP/$EXE" 2>/dev/null | grep -q "__ZNSt3__119piecewise_constructE"; then
    cp "$CXX_COMPAT" "$APP/Frameworks/libcxxcompat.dylib"
    install_name_tool -change /usr/lib/libc++.1.dylib \
      "$APP/Frameworks/libcxxcompat.dylib" "$APP/$EXE" 2>/dev/null || true
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
