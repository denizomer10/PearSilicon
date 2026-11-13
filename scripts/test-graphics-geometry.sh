#!/bin/bash
# In-memory input/screen regression tests; no desktop automation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
probe="$(mktemp -d "${TMPDIR:-/tmp}/pear-geometry.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"
common=(-std=c++17 -fobjc-arc -target arm64-apple-ios15.0-macabi -isysroot "$sdk"
        -iframework "$sdk/System/iOSSupport/System/Library/Frameworks" -I"$root/runtime/include")
xcrun clang++ "${common[@]}" "$root/scripts/touch-geometry-smoke.mm" -framework CoreGraphics -o "$probe/geometry"
"$probe/geometry"
xcrun clang++ "${common[@]}" -include PearRuntime.h "$root/scripts/legacy-direct-touch-smoke.mm" \
  "$root/runtime/modules/input/LegacyDirectTouch.mm" -framework UIKit -framework Foundation -framework CoreGraphics -o "$probe/touch"
"$probe/touch"
xcrun clang++ "${common[@]}" "$root/scripts/screen-cache-smoke.mm" \
  -framework UIKit -framework Foundation -framework CoreGraphics -o "$probe/screen"
"$probe/screen"
