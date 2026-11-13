#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
angle_dir="${1:-$root/runtime/third_party/angle/out/PearMetal}"
angle_dir="$(cd "$angle_dir" && pwd)"
probe="$(mktemp -d "${TMPDIR:-/tmp}/pear-angle-routing.XXXXXX")"
if [[ "${PEAR_KEEP_ROUTING_PROBE:-0}" == 1 ]]; then
  echo "Routing probe: $probe"
else
  trap 'rm -rf "$probe"' EXIT
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
common=(-std=c++17 -target arm64-apple-ios15.0-macabi -isysroot "$sdk"
        -iframework "$sdk/System/iOSSupport/System/Library/Frameworks"
        -fobjc-arc -I"$root/runtime/include" -I"$root/runtime/third_party/angle/include" -Wl,-no_fixup_chains)
app="$probe/RoutingProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
# Link-time public export declarations only; no system implementation copied.
python3 - "$probe/OpenGLES.tbd" <<'PY'
import pathlib, sys
symbols = ['glGenRenderbuffers', 'glBindRenderbuffer', 'glGetRenderbufferParameteriv',
           'glGenFramebuffers', 'glBindFramebuffer', 'glFramebufferRenderbuffer',
           'glClearColor', 'glClear', 'glReadPixels', 'glGetError', 'glDeleteRenderbuffers']
pathlib.Path(sys.argv[1]).write_text('''--- !tapi-tbd
tbd-version: 4
targets: [ arm64-maccatalyst ]
install-name: /System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES
exports:
  - targets: [ arm64-maccatalyst ]
    symbols: [ %s ]
    objc-classes: [ EAGLContext ]
...
''' % ', '.join('_' + name for name in symbols))
PY
cat > "$probe/ProcFixture.mm" <<'CPP'
extern "C" void *EAGLGetProcAddress(const char *) { return nullptr; }
CPP
xcrun clang++ "${common[@]}" -dynamiclib "$probe/ProcFixture.mm" \
  -Wl,-install_name,@rpath/libProcFixture.dylib -o "$app/Contents/Frameworks/libProcFixture.dylib"
xcrun clang++ "${common[@]}" -dynamiclib \
  "$root/runtime/modules/graphics-gl/ANGLEBackend.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEContext.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEDrawable.mm" \
  "$root/runtime/modules/graphics-gl/EAGLContextAdapter.mm" \
  "$root/runtime/modules/graphics-gl/ANGLEGameRouting.mm" \
  "$root/runtime/modules/core/ModuleRegistry.mm" \
  -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -Wl,-install_name,@rpath/libPearRuntime.dylib -o "$app/Contents/Frameworks/libPearRuntime.dylib"
xcrun clang++ "${common[@]}" "$root/scripts/angle-routing-smoke.mm" "$probe/OpenGLES.tbd" \
  -L"$app/Contents/Frameworks" -lProcFixture -framework Foundation -framework QuartzCore \
  -Wl,-rpath,@executable_path/../Frameworks -o "$app/Contents/MacOS/RoutingProbe"
PEAR_GRAPHICS_BACKEND=angle PEAR_ANGLE_LIB_DIR="$angle_dir" \
  DYLD_INSERT_LIBRARIES="$app/Contents/Frameworks/libPearRuntime.dylib" "$app/Contents/MacOS/RoutingProbe"
set +e
PEAR_GRAPHICS_BACKEND=system DYLD_INSERT_LIBRARIES="$app/Contents/Frameworks/libPearRuntime.dylib" \
  "$app/Contents/MacOS/RoutingProbe" --native
status=$?
[[ "$status" == 78 ]] || { echo 'System backend must be refused' >&2; exit 1; }
PEAR_GRAPHICS_BACKEND=angle PEAR_RUNTIME_DISABLE=graphics-gl PEAR_ANGLE_LIB_DIR="$angle_dir" \
  DYLD_INSERT_LIBRARIES="$app/Contents/Frameworks/libPearRuntime.dylib" "$app/Contents/MacOS/RoutingProbe"
status=$?
set -e
[[ "$status" == 78 ]] || { echo 'Disabled GL module must refuse ANGLE routing' >&2; exit 1; }
echo 'PASS: system backend and disabled-module rejection'
