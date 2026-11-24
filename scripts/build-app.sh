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
APP_VERSION="0.9.3"
APP_BUILD="44"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
CONFIG="${1:-release}"
BUILD_DIR="${PEAR_BUILD_DIR:-$ROOT/build}"
case "$BUILD_DIR" in /*) ;; *) BUILD_DIR="$ROOT/$BUILD_DIR" ;; esac
OUT="$BUILD_DIR/$APP_NAME.app"

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

# --- 2b) Build the PearHost frameworks (macOS-platform UIKit & co.) --------
# The launcher's PearHost mode installs these into an app; it looks for them
# in Contents/Resources/PearHost. OpenGLES.framework re-exports the macOS
# PearANGLE build (runtime/host/build-pearangle.sh) when one is available.
HOST_ANGLE="${PEAR_HOST_ANGLE_DIR:-}"
for candidate in "$BUILD_DIR/host/PearANGLE-src" "$ROOT/runtime/build/host/PearANGLE-src"; do
  [[ -z "$HOST_ANGLE" && -f "$candidate/libGLESv2.dylib" ]] && HOST_ANGLE="$candidate"
done
echo ">> Building PearHost frameworks"
PEAR_BUILD_DIR="$BUILD_DIR" PEAR_HOST_ANGLE_DIR="${HOST_ANGLE:-$BUILD_DIR/host/PearANGLE-src}" \
  "$ROOT/runtime/host/build-host.sh"

# --- 3) Assemble .app -----------------------------------------------------
echo ">> Assembling bundle: $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

RES_BUNDLE="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$OUT/Contents/Resources/"
fi

for opt in "$BUILD_DIR/host/libswiftUIKit.dylib" "$BUILD_DIR/host/libcxxcompat.dylib" \
           "$BUILD_DIR/libswiftUIKit.dylib" "$BUILD_DIR/libcxxcompat.dylib"; do
  if [[ -f "$opt" && ! -f "$OUT/Contents/Resources/$(basename "$opt")" ]]; then
    cp "$opt" "$OUT/Contents/Resources/"
  fi
done
if [[ -d "$BUILD_DIR/MarketplaceKit.framework" ]]; then
  cp -R "$BUILD_DIR/MarketplaceKit.framework" "$OUT/Contents/Resources/"
fi

# PearHost frameworks, and the macOS PearANGLE they re-export, if built.
HOST_OUT="$OUT/Contents/Resources/PearHost"
rm -rf "$HOST_OUT"
mkdir -p "$HOST_OUT"
cp "$ROOT/runtime/LICENSE" "$HOST_OUT/LICENSE.PearRuntime"
for fw in "$BUILD_DIR/host"/*.framework; do
  [[ -d "$fw" ]] && cp -R "$fw" "$HOST_OUT/"
done
for lib in libcxxcompat.dylib libswiftUIKit.dylib libPearHostPlaceholder.dylib libpear_controller.dylib; do
  [[ -f "$BUILD_DIR/host/$lib" ]] && cp "$BUILD_DIR/host/$lib" "$HOST_OUT/"
done
if [[ -d "$BUILD_DIR/host/PearANGLE" ]]; then
  cp -R "$BUILD_DIR/host/PearANGLE" "$HOST_OUT/PearANGLE"
else
  echo "WARNING: no macOS PearANGLE; PearHost apps will have no OpenGL ES (run runtime/host/build-pearangle.sh)" >&2
fi

# --- 3a-legacy) Bundle PearLegacyEngine (32-bit iOS runtime) --------------
# The engine's sources are part of PearRuntime (runtime/third_party/legacy-engine).
LEGACY_REPO="${PEAR_LEGACY_ENGINE_REPO:-$ROOT/runtime/third_party/legacy-engine}"
LEGACY_BIN=""
LEGACY_STAGE="$BUILD_DIR/PearLegacyEngine"
# A tree staged by scripts/setup-legacy-engine.sh is already in the release
# layout (binary plus dylibs with ANGLE in touchHLE_dylibs/angle), so it is used
# as-is: copying the source checkout's resources over it would drop ANGLE.
LEGACY_FROM_STAGE=0
if [[ -x "$LEGACY_STAGE/touchHLE" && -d "$LEGACY_STAGE/touchHLE_dylibs/angle" ]]; then
  LEGACY_BIN="$LEGACY_STAGE/touchHLE"
  LEGACY_FROM_STAGE=1
fi
if [[ -n "${PEAR_LEGACY_ENGINE_PATH:-}" && -x "${PEAR_LEGACY_ENGINE_PATH}" ]]; then
  LEGACY_BIN="${PEAR_LEGACY_ENGINE_PATH}"
  LEGACY_FROM_STAGE=0
elif [[ "$LEGACY_FROM_STAGE" == 0 && -x "$LEGACY_REPO/target/release/touchHLE" ]]; then
  LEGACY_BIN="$LEGACY_REPO/target/release/touchHLE"
elif [[ "$LEGACY_FROM_STAGE" == 0 && -x "$LEGACY_REPO/target/debug/touchHLE" ]]; then
  LEGACY_BIN="$LEGACY_REPO/target/debug/touchHLE"
fi

if [[ -n "$LEGACY_BIN" ]]; then
  echo ">> Bundling PearLegacyEngine from $LEGACY_BIN"
  mkdir -p "$LEGACY_STAGE"
  if [[ "$LEGACY_BIN" != "$LEGACY_STAGE/touchHLE" ]]; then
    cp "$LEGACY_BIN" "$LEGACY_STAGE/touchHLE"
  fi
  chmod +x "$LEGACY_STAGE/touchHLE"
  if [[ "$LEGACY_FROM_STAGE" == 0 && -d "$LEGACY_REPO" ]]; then
    [[ -f "$LEGACY_REPO/touchHLE_default_options.txt" ]] && cp "$LEGACY_REPO/touchHLE_default_options.txt" "$LEGACY_STAGE/"
    if [[ -d "$LEGACY_REPO/touchHLE_dylibs" ]]; then
      # The repo's dylibs have no ANGLE build; keep the staged one (from
      # scripts/setup-legacy-engine.sh) so the engine can still render.
      ANGLE_KEEP=""
      if [[ -d "$LEGACY_STAGE/touchHLE_dylibs/angle" ]]; then
        ANGLE_KEEP="$BUILD_DIR/.angle-keep"
        rm -rf "$ANGLE_KEEP"
        mv "$LEGACY_STAGE/touchHLE_dylibs/angle" "$ANGLE_KEEP"
      fi
      rm -rf "$LEGACY_STAGE/touchHLE_dylibs"
      cp -R "$LEGACY_REPO/touchHLE_dylibs" "$LEGACY_STAGE/touchHLE_dylibs"
      if [[ -n "$ANGLE_KEEP" ]]; then
        mv "$ANGLE_KEEP" "$LEGACY_STAGE/touchHLE_dylibs/angle"
      fi
    fi
    if [[ -d "$LEGACY_REPO/touchHLE_fonts" ]]; then
      rm -rf "$LEGACY_STAGE/touchHLE_fonts"
      cp -R "$LEGACY_REPO/touchHLE_fonts" "$LEGACY_STAGE/touchHLE_fonts"
    fi
  fi
  if [[ ! -d "$LEGACY_STAGE/touchHLE_dylibs/angle" ]]; then
    echo "WARNING: ANGLE is not staged in $LEGACY_STAGE/touchHLE_dylibs/angle" >&2
    echo "         run scripts/setup-legacy-engine.sh, or set PEAR_ANGLE_LIB_DIR at runtime" >&2
  fi
  # The engine binary is GPL-3.0-or-later; its license, notices and source
  # pointer are staged by scripts/setup-legacy-engine.sh. Stage them here when
  # the engine came from somewhere else.
  if [[ ! -f "$LEGACY_STAGE/SOURCE.txt" || "$LEGACY_FROM_STAGE" == 0 ]]; then
    LEGACY_SRC_REPO="${PEAR_LEGACY_ENGINE_HOME:-}"
    for candidate in "$LEGACY_REPO" "$ROOT/runtime/third_party/legacy-engine"; do
      [[ -z "$LEGACY_SRC_REPO" && -f "$candidate/LICENSE" ]] && LEGACY_SRC_REPO="$candidate"
    done
    "$ROOT/scripts/stage-legacy-licenses.sh" "$LEGACY_STAGE" "${LEGACY_SRC_REPO:?runtime/third_party/legacy-engine not found for the engine license files}" \
      "${PEAR_DYNARMIC_ROOT:-$ROOT/runtime/third_party/legacy-jit}"
  fi
  rm -rf "$OUT/Contents/Resources/PearLegacyEngine"
  cp -R "$LEGACY_STAGE" "$OUT/Contents/Resources/PearLegacyEngine"
fi

# --- 3a-licenses) License texts, notices and source pointers -------------
# The ZIP holds only the app, so everything the redistributed components
# require travels inside it. scripts/verify-licenses.sh fails the build when
# something is missing.
LICENSES="$OUT/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp "$ROOT/LICENSE" "$LICENSES/LICENSE.PearSilicon"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$LICENSES/THIRD_PARTY_NOTICES.md"
cp "$ROOT/runtime/LICENSE" "$LICENSES/LICENSE.PearRuntime"
cp "$ROOT/runtime/debug/LICENSE" "$LICENSES/LICENSE.PearDebug"
sub_commit() { git -C "$ROOT/$1" rev-parse HEAD 2>/dev/null || echo unknown; }
cat > "$LICENSES/SOURCE.txt" <<SOURCE
PearSilicon $APP_VERSION (build $APP_BUILD) was built from these public sources:

  PearSilicon   https://github.com/denizomer10/PearSilicon/tree/$COMMIT
  PearRuntime   https://github.com/denizomer10/PearRuntime/tree/$(sub_commit runtime)
    PearDebug   https://github.com/denizomer10/PearRuntime/tree/$(sub_commit runtime)/debug
    PearANGLE   https://github.com/denizomer10/PearRuntime/tree/$(sub_commit runtime)/third_party/angle

PearLegacyEngine/SOURCE.txt lists the sources of the 32-bit iOS engine.
SOURCE
"$ROOT/scripts/verify-licenses.sh" "$OUT"

# --- 3b) App icon from the repo logo -------------------------------------
ICON_KEY=""
if [[ -f "$ROOT/logo.png" ]]; then
  echo ">> Generating app icon"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
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
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>PearBuildCommit</key><string>$COMMIT</string>
  <key>PearBuildChannel</key><string>development-beta</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>PearSilicon uses Bluetooth Low Energy to detect and connect Nintendo Switch 2 Joy-Con and Pro controllers.</string>
$ICON_KEY
</dict>
</plist>
PLIST

# --- 4) Sign (adhoc) ------------------------------------------------------
echo ">> Adhoc signing"
codesign --force --deep --sign - "$OUT"
codesign --verify --deep --strict "$OUT"
# A locally built app must not inherit a stale browser quarantine flag. This
# does not affect a ZIP downloaded later; that copy gets its own flag.
xattr -dr com.apple.quarantine "$OUT" 2>/dev/null || true

echo ">> Done: $OUT"
