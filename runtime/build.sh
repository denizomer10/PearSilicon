#!/bin/bash
# Builds libPearRuntime.dylib for the iOS SDK (arm64).
#
# The dylib must match the host process, which is an iOS binary, so we
# link against the iOS SDK rather than the macOS one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/libPearRuntime.dylib"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "ERROR: iOS SDK not found. Is Xcode installed?"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CXX="$(xcrun --find clang++)"
mkdir -p "$OUT_DIR"

# Emit a compilation database so editors/clangd resolve UIKit for these files.
# The iOS frameworks live under iOSSupport inside the macOS SDK, so the same
# -iframework the build uses must be present here or clangd reports a false
# "'UIKit/UIKit.h' file not found".
cat > "$ROOT/runtime/compile_commands.json" <<JSON
[
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/PearRuntime.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c PearRuntime.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/TouchSynthesizer.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c TouchSynthesizer.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/PointerLockShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c PointerLockShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/BeepShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c BeepShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/ODRShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c ODRShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/UsercentricsShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c UsercentricsShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/NetworkShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c NetworkShim.mm"
  },
  {
    "directory": "$ROOT/runtime/include",
    "file": "$ROOT/runtime/include/PearRuntime.h",
    "command": "$CXX -x objective-c++-header -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -fobjc-arc -I$ROOT/runtime/include -fsyntax-only PearRuntime.h"
  }
]
JSON

echo ">> Building $OUT (Mac Catalyst)"
xcrun --sdk macosx clang++ \
  -target arm64-apple-ios15.0-macabi \
  -isysroot "$SDK" \
  -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -I"$ROOT/runtime/include" \
  -include PearRuntime.h \
  -std=c++17 \
  -dynamiclib \
  -fobjc-arc \
  -framework Foundation \
  -framework UIKit \
  -framework GameController \
  -framework QuartzCore \
  -framework Metal \
  -framework CoreGraphics \
  -framework Security \
  -framework AppKit \
  -install_name @rpath/libPearRuntime.dylib \
  -o "$OUT" \
  "$ROOT/runtime/PearRuntime.mm" \
  "$ROOT/runtime/KeychainShim.mm" \
  "$ROOT/runtime/CloudKitShim.mm" \
  "$ROOT/runtime/DeviceShim.mm" \
  "$ROOT/runtime/ScreenShim.mm" \
  "$ROOT/runtime/PathShim.mm" \
  "$ROOT/runtime/MetalLayerShim.mm" \
  "$ROOT/runtime/TouchSynthesizer.mm" \
  "$ROOT/runtime/PointerLockShim.mm" \
  "$ROOT/runtime/BeepShim.mm" \
  "$ROOT/runtime/ODRShim.mm" \
  "$ROOT/runtime/UsercentricsShim.mm" \
  "$ROOT/runtime/NetworkShim.mm" \
  "$ROOT/runtime/GLShim.mm"

echo ">> Done: $OUT"
file "$OUT"
