#!/bin/bash
# A real linked GLES client with no system OpenGLES dependency, no visible UI.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
angle_dir="${1:-$root/runtime/third_party/angle/out/PearCatalyst}"
angle_dir="$(cd "$angle_dir" && pwd)"
probe="$(mktemp -d "${TMPDIR:-/tmp}/pear-angle-exclusive.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"
common=(-std=c++17 -target arm64-apple-ios15.0-macabi -isysroot "$sdk"
        -iframework "$sdk/System/iOSSupport/System/Library/Frameworks"
        -fobjc-arc -I"$root/runtime/include" -I"$root/runtime/third_party/angle/include" -Wl,-no_fixup_chains)
source "$root/runtime/bridge/context-aliases.sh"
app="$probe/ExclusiveProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
xcrun clang++ "${common[@]}" -dynamiclib \
  "$root/runtime/modules/graphics-gl/ANGLEBackend.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEContext.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEDrawable.mm" \
  "$root/runtime/modules/graphics-gl/EAGLContextAdapter.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEGameRouting.mm" \
  "$root/runtime/modules/core/ModuleRegistry.mm" \
  -framework Foundation -framework QuartzCore -framework CoreGraphics "${PEAR_EAGL_ALIAS_FLAGS[@]}" \
  -Wl,-install_name,@rpath/libPearRuntime.dylib -o "$app/Contents/Frameworks/libPearRuntime.dylib"
bash "$root/runtime/build-angle-bridge.sh" "$app/Contents/Frameworks/libPearRuntime.dylib"
xcrun clang++ "${common[@]}" -DPEAR_EXCLUSIVE_PROBE "$root/scripts/angle-routing-smoke.mm" \
  -L"$app/Contents/Frameworks" -lPearOpenGLES -framework Foundation -framework QuartzCore \
  -Wl,-rpath,@executable_path/../Frameworks -o "$app/Contents/MacOS/ExclusiveProbe"
# No injection: the client loads the runtime through its bridge dependency.
PEAR_GRAPHICS_BACKEND=angle PEAR_ANGLE_LIB_DIR="$angle_dir" "$app/Contents/MacOS/ExclusiveProbe"
/usr/bin/env -u PEAR_GRAPHICS_BACKEND PEAR_ANGLE_LIB_DIR="$angle_dir" "$app/Contents/MacOS/ExclusiveProbe"

# Run-time-only GL: the client links the runtime but not the bridge, and
# dlopens the system OpenGLES path. ANGLE comes from Frameworks/PearANGLE.
dynamic="$probe/DynamicProbe.app"
mkdir -p "$dynamic/Contents/MacOS"
cp -R "$app/Contents/Frameworks" "$dynamic/Contents/Frameworks"
mkdir -p "$dynamic/Contents/Frameworks/PearANGLE"
cp "$angle_dir/libEGL.dylib" "$angle_dir/libGLESv2.dylib" "$dynamic/Contents/Frameworks/PearANGLE/"
xcrun clang++ "${common[@]}" "$root/scripts/angle-dynamic-smoke.mm" \
  -L"$dynamic/Contents/Frameworks" -lPearRuntime -framework Foundation \
  -Wl,-rpath,@executable_path/../Frameworks -o "$dynamic/Contents/MacOS/DynamicProbe"
if otool -L "$dynamic/Contents/MacOS/DynamicProbe" | grep -qE "OpenGLES|libPearOpenGLES"; then
  echo "FAIL: dynamic probe must not link OpenGL ES" >&2; exit 1
fi
/usr/bin/env -u PEAR_GRAPHICS_BACKEND -u PEAR_ANGLE_LIB_DIR "$dynamic/Contents/MacOS/DynamicProbe"
