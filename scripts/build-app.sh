#!/bin/bash
# Builds PearSilicon and assembles a runnable .app bundle.
#
# Requires the full development toolchain (the command-line tools alone are not
# enough, because the SwiftUI macro plugins ship with the full toolchain).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="PearSilicon"
BUNDLE_ID="com.pearsilicon.app"
CONFIG="${1:-release}"
OUT="$ROOT/build/$APP_NAME.app"

# --- 1) Environment check -------------------------------------------------
DEV_DIR="$(xcode-select -p)"
if [[ ! -d "$DEV_DIR/Platforms/MacOSX.platform" ]]; then
  echo "ERROR: the active developer directory is not a full toolchain: $DEV_DIR"
  echo "Select a full toolchain with: sudo xcode-select -s /Applications/<Toolchain>.app"
  exit 1
fi

# --- 2) Compile -----------------------------------------------------------
echo ">> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

# --- 2b) Build runtime dylib ----------------------------------------------
if [[ -x "$ROOT/runtime/build.sh" ]]; then
  echo ">> Building runtime dylib"
  "$ROOT/runtime/build.sh"
fi

# --- 3) Assemble .app -----------------------------------------------------
echo ">> Assembling bundle: $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

RES_BUNDLE="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$OUT/Contents/Resources/"
fi

if [[ -f "$ROOT/build/libPearRuntime.dylib" ]]; then
  cp "$ROOT/build/libPearRuntime.dylib" "$OUT/Contents/Resources/"
fi
if [[ -f "$ROOT/build/libswiftUIKit.dylib" ]]; then
  cp "$ROOT/build/libswiftUIKit.dylib" "$OUT/Contents/Resources/"
fi

# --- 3b) App icon from the repo logo -------------------------------------
ICON_KEY=""
if [[ -f "$ROOT/logo.png" ]]; then
  echo ">> Generating app icon"
  ICONSET="$ROOT/build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  icon() { sips -z "$1" "$1" "$ROOT/logo.png" --out "$ICONSET/$2" >/dev/null 2>&1; }
  icon 16   icon_16x16.png
  icon 32   icon_16x16@2x.png
  icon 32   icon_32x32.png
  icon 64   icon_32x32@2x.png
  icon 128  icon_128x128.png
  icon 256  icon_128x128@2x.png
  icon 256  icon_256x256.png
  icon 512  icon_256x256@2x.png
  icon 512  icon_512x512.png
  icon 1024 icon_512x512@2x.png
  if iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    cp "$ROOT/logo.png" "$OUT/Contents/Resources/logo.png"
    ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
  fi
fi

# --- 3c) CLI marker -------------------------------------------------------
# Tells the `pearsilicon` wrapper that this bundle's binary understands the
# CLI commands (older builds would just open the GUI).
printf '1\n' > "$OUT/Contents/Resources/pearsilicon-cli"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.6</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$ICON_KEY
</dict>
</plist>
PLIST

# --- 4) Sign (adhoc) ------------------------------------------------------
echo ">> Adhoc signing"
codesign --force --deep --sign - "$OUT" || echo "(warning) codesign failed"

echo ">> Done: $OUT"
