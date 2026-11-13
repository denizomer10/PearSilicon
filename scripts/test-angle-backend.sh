#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
angle_dir="${1:-$root/runtime/third_party/angle/out/PearMetal}"
if [[ ! -f "$angle_dir/libEGL.dylib" ]]; then
  echo 'Build the fork with scripts/build-angle-metal.sh --sync, or pass an ANGLE library directory.' >&2
  exit 2
fi
angle_dir="$(cd "$angle_dir" && pwd)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
angle_smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/pear-angle-smoke.XXXXXX")"
trap 'rm -rf "$angle_smoke_root"' EXIT
common=(-std=c++17 -target arm64-apple-ios15.0-macabi -isysroot "$sdk"
        -iframework "$sdk/System/iOSSupport/System/Library/Frameworks"
        -fobjc-arc -I"$root/runtime/include" -I"$root/runtime/third_party/angle/include")
xcrun clang++ "${common[@]}" "$root/scripts/angle-catalyst-smoke.mm" -o "$angle_smoke_root/render"
"$angle_smoke_root/render" "$angle_dir/libEGL.dylib"
xcrun clang++ "${common[@]}" "$root/scripts/angle-loader-smoke.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEBackend.mm" -framework Foundation -o "$angle_smoke_root/loader"
"$angle_smoke_root/loader" "$angle_dir"
xcrun clang++ "${common[@]}" "$root/scripts/angle-context-smoke.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEBackend.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEContext.mm" -framework Foundation -o "$angle_smoke_root/context"
"$angle_smoke_root/context" "$angle_dir"
xcrun clang++ "${common[@]}" "$root/scripts/angle-shader-smoke.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEBackend.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEContext.mm" -framework Foundation -o "$angle_smoke_root/shaders"
"$angle_smoke_root/shaders" "$angle_dir"
