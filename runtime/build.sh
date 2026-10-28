#!/bin/bash
# Builds libPearRuntime.dylib for the Catalyst target (arm64).
#
# The dylib must match the host process, which is an iOS binary, so it is
# compiled for the Catalyst target. The iOS frameworks ship inside the macOS
# SDK's iOSSupport directory, so this works with the Command Line Tools alone
# as well as with a full toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/libPearRuntime.dylib"
SWIFT_OVERLAY="$OUT_DIR/libswiftUIKit.dylib"
CXX_COMPAT="$OUT_DIR/libcxxcompat.dylib"

SDK="${PEAR_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
IOS_FRAMEWORKS="$SDK/System/iOSSupport/System/Library/Frameworks"
if [[ ! -d "$IOS_FRAMEWORKS" ]]; then
  echo "ERROR: the macOS SDK does not include the iOSSupport frameworks."
  echo "       SDK: $SDK"
  echo "       Install the Command Line Tools or a full toolchain with macOS SDK 26 or later."
  exit 1
fi

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
    "file": "$ROOT/runtime/ServicesShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c ServicesShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/PlatformShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c PlatformShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/ConsentShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c ConsentShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/NetworkShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c NetworkShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/TrackingShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c TrackingShim.mm"
  },
  {
    "directory": "$ROOT/runtime",
    "file": "$ROOT/runtime/SandboxShim.mm",
    "command": "$CXX -target arm64-apple-ios15.0-macabi -isysroot $SDK -iframework $SDK/System/iOSSupport/System/Library/Frameworks -std=c++17 -fobjc-arc -I$ROOT/runtime/include -include PearRuntime.h -c SandboxShim.mm"
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
  -Wl,-undefined,dynamic_lookup \
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
  "$ROOT/runtime/CloudShim.mm" \
  "$ROOT/runtime/CredentialShim.mm" \
  "$ROOT/runtime/DeviceShim.mm" \
  "$ROOT/runtime/ScreenShim.mm" \
  "$ROOT/runtime/PathShim.mm" \
  "$ROOT/runtime/MetalLayerShim.mm" \
  "$ROOT/runtime/TouchSynthesizer.mm" \
  "$ROOT/runtime/PointerLockShim.mm" \
  "$ROOT/runtime/BeepShim.mm" \
  "$ROOT/runtime/ODRShim.mm" \
  "$ROOT/runtime/ServicesShim.mm" \
  "$ROOT/runtime/PlatformShim.mm" \
  "$ROOT/runtime/ConsentShim.mm" \
  "$ROOT/runtime/NetworkShim.mm" \
  "$ROOT/runtime/TrackingShim.mm" \
  "$ROOT/runtime/SandboxShim.mm" \
  "$ROOT/runtime/GLShim.mm"

echo ">> Done: $OUT"
file "$OUT"

# A few Catalyst binaries carry a weak C++ placeholder that the host runtime
# does not export. This small library re-exports the system C++ runtime and
# supplies the missing empty tag object.
echo ">> Building $CXX_COMPAT (C++ runtime compatibility)"
xcrun --sdk macosx clang++ \
  -target arm64-apple-ios15.0-macabi \
  -isysroot "$SDK" \
  -dynamiclib \
  -Wl,-reexport_library,"$SDK/usr/lib/libc++.1.tbd" \
  -install_name @rpath/libcxxcompat.dylib \
  -o "$CXX_COMPAT" \
  "$ROOT/runtime/cxxcompat.cpp"
file "$CXX_COMPAT"

# Some Swift SDKs link against the UIKit Swift overlay, which the Mac Catalyst
# host runtime does not ship. Build the small clean-room overlay used by the
# installer. It contains only public API bridges from runtime/swift/.
echo ">> Building $SWIFT_OVERLAY (Swift UIKit compatibility)"
CLANG_TARGET="arm64-apple-ios15.0-macabi"
CLANG="$(xcrun --find clang)"
SWIFTC="$(xcrun --find swiftc)"
"$CLANG" -c -target "$CLANG_TARGET" -isysroot "$SDK" \
  "$ROOT/runtime/swift/PearSwiftUIKitSupport.c" \
  -o "$OUT_DIR/PearSwiftUIKitSupport.o"
"$SWIFTC" -target "$CLANG_TARGET" -sdk "$SDK" -F "$IOS_FRAMEWORKS" \
  -emit-library -module-name PearSwiftUIKit \
  -Xlinker -install_name -Xlinker @rpath/libswiftUIKit.dylib \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  -o "$SWIFT_OVERLAY" \
  "$ROOT/runtime/swift/PearSwiftUIKit.swift" \
  "$OUT_DIR/PearSwiftUIKitSupport.o"
file "$SWIFT_OVERLAY"
