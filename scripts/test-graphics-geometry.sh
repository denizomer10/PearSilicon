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
# legacy-direct-touch-smoke.mm and screen-cache-smoke.mm drive the production
# Rust modules (input/legacy_touch.rs, graphics/screen.rs) with in-test fakes
# for the window lookup and GL touch mapping, through the smoke build's hooks.
runtime="$("$root/scripts/build-smoke-runtime.sh" catalyst | tail -n 1)"
smoke_link=(-framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore
            -framework Metal -framework GameController -framework Security -framework AppKit
            -framework AudioToolbox -framework IOKit -Wl,-dead_strip "$runtime")
for probe_name in legacy-direct-touch screen-cache; do
  xcrun clang++ "${common[@]}" "$root/scripts/$probe_name-smoke.mm" "${smoke_link[@]}" -o "$probe/$probe_name"
  "$probe/$probe_name"
done
