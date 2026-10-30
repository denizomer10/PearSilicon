#!/bin/bash
# Builds libPearRuntime.dylib for the Catalyst target (arm64).
#
# The dylib must match the host process, which is an iOS binary, so it is
# compiled for the Catalyst target. The iOS frameworks ship inside the macOS
# SDK's iOSSupport directory, so this works with the Command Line Tools alone
# as well as with a full toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${PEAR_BUILD_DIR:-$ROOT/build}"
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$ROOT/$OUT_DIR" ;; esac
OUT="$OUT_DIR/libPearRuntime.dylib"
SWIFT_OVERLAY="$OUT_DIR/libswiftUIKit.dylib"
CXX_COMPAT="$OUT_DIR/libcxxcompat.dylib"
DEVICE_PROFILE="$OUT_DIR/PearDeviceProfile.o"

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
    "file": "$ROOT/runtime/DeviceProfile.mm",
    "command": "$CXX -x c++ -target arm64-apple-ios15.0-macabi -isysroot $SDK -std=c++17 -I$ROOT/runtime/include -c DeviceProfile.mm"
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

# Do not force-include PearRuntime.h into the early device snapshot. Compiling
# it as plain C++ also keeps ObjC/Foundation initialization out of this object.
xcrun --sdk macosx clang++ \
  -x c++ -target arm64-apple-ios15.0-macabi -isysroot "$SDK" \
  -I"$ROOT/runtime/include" -std=c++17 -c "$ROOT/runtime/DeviceProfile.mm" \
  -o "$DEVICE_PROFILE"

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
  -framework AudioToolbox \
  -install_name @rpath/libPearRuntime.dylib \
  -o "$OUT" \
  "$ROOT/runtime/PearRuntime.mm" \
  "$ROOT/runtime/KeychainShim.mm" \
  "$ROOT/runtime/CloudShim.mm" \
  "$ROOT/runtime/CredentialShim.mm" \
  "$ROOT/runtime/DeviceShim.mm" \
  "$DEVICE_PROFILE" \
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
  "$ROOT/runtime/GLShim.mm" \
  "$ROOT/runtime/WebInputShim.mm" \
  "$ROOT/runtime/FoundationShim.mm" \
  "$ROOT/runtime/HostService.mm"

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
# host runtime does not ship. Build the small source-built overlay used by the
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

# Some store builds link MarketplaceKit, which the host ships as resources
# only. Without a binary the dynamic linker cannot resolve the weak Swift
# references and aborts while registering metadata. The installer copies this
# stub into apps that need it; `-enable-library-evolution` is required for the
# enum case constructors the already-compiled client binds to.
echo ">> Building MarketplaceKit.framework (distribution metadata stub)"
MARKETPLACE="$OUT_DIR/MarketplaceKit.framework"
rm -rf "$MARKETPLACE"
mkdir -p "$MARKETPLACE/Versions/A/Resources"
"$SWIFTC" -target "$CLANG_TARGET" -sdk "$SDK" -F "$IOS_FRAMEWORKS" \
  -emit-library -module-name MarketplaceKit -enable-library-evolution \
  -Xlinker -install_name -Xlinker @rpath/MarketplaceKit.framework/MarketplaceKit \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  -o "$MARKETPLACE/Versions/A/MarketplaceKit" \
  "$ROOT/runtime/swift/MarketplaceKit.swift"
ln -s A "$MARKETPLACE/Versions/Current"
ln -s Versions/Current/MarketplaceKit "$MARKETPLACE/MarketplaceKit"
ln -s Versions/Current/Resources "$MARKETPLACE/Resources"
cat > "$MARKETPLACE/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MarketplaceKit</string>
  <key>CFBundleIdentifier</key><string>com.pearsilicon.marketplacekit</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
file "$MARKETPLACE/MarketplaceKit"
