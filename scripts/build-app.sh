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
APP_VERSION="0.9.1"
APP_BUILD="38"
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

# --- 2b) Build runtime dylib ----------------------------------------------
if [[ -x "$ROOT/runtime/build.sh" ]]; then
  echo ">> Building runtime dylib"
  PEAR_BUILD_DIR="$BUILD_DIR" "$ROOT/runtime/build.sh"
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

if [[ -f "$BUILD_DIR/libPearRuntime.dylib" ]]; then
  cp "$BUILD_DIR/libPearRuntime.dylib" "$OUT/Contents/Resources/"
fi
if [[ -f "$BUILD_DIR/libswiftUIKit.dylib" ]]; then
  cp "$BUILD_DIR/libswiftUIKit.dylib" "$OUT/Contents/Resources/"
fi
if [[ -f "$BUILD_DIR/libcxxcompat.dylib" ]]; then
  cp "$BUILD_DIR/libcxxcompat.dylib" "$OUT/Contents/Resources/"
fi
if [[ -d "$BUILD_DIR/MarketplaceKit.framework" ]]; then
  cp -R "$BUILD_DIR/MarketplaceKit.framework" "$OUT/Contents/Resources/"
fi
# OpenGL ES runs only on ANGLE: the installer copies the GLES/EAGL bridge and
# the Catalyst ANGLE dylibs into every compatibility app and refuses to
# prepare one without them. Never fall back to another copy's resources.
for component in libPearOpenGLES.dylib PearANGLE/libEGL.dylib PearANGLE/libGLESv2.dylib; do
  if [[ ! -f "$BUILD_DIR/$component" ]]; then
    echo "ERROR: $BUILD_DIR/$component is missing (runtime/build.sh stages it)." >&2
    exit 1
  fi
done
cp "$BUILD_DIR/libPearOpenGLES.dylib" "$OUT/Contents/Resources/"
rm -rf "$OUT/Contents/Resources/PearANGLE"
cp -R "$BUILD_DIR/PearANGLE" "$OUT/Contents/Resources/PearANGLE"

# --- 3a-legacy) Bundle PearLegacyEngine (32-bit iOS runtime) --------------
if [[ -n "${PEAR_LEGACY_ENGINE_REPO:-}" ]]; then
  LEGACY_REPO="${PEAR_LEGACY_ENGINE_REPO}"
elif [[ -d "$HOME/PearLegacyEngine" ]]; then
  LEGACY_REPO="$HOME/PearLegacyEngine"
else
  LEGACY_REPO="$HOME/Documents/PearLegacyEngine"
fi
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
    for candidate in "$LEGACY_REPO" "$ROOT/../PearLegacyEngine"; do
      [[ -z "$LEGACY_SRC_REPO" && -f "$candidate/LICENSE" ]] && LEGACY_SRC_REPO="$candidate"
    done
    "$ROOT/scripts/stage-legacy-licenses.sh" "$LEGACY_STAGE" "${LEGACY_SRC_REPO:?no PearLegacyEngine checkout found for the engine license files}" \
      "${PEAR_DYNARMIC_ROOT:-$ROOT/../PearLegacyJIT}"
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
cp "$ROOT/Vendor/PearDebug/LICENSE" "$LICENSES/LICENSE.PearDebug"
sub_commit() { git -C "$ROOT/$1" rev-parse HEAD 2>/dev/null || echo unknown; }
cat > "$LICENSES/SOURCE.txt" <<SOURCE
PearSilicon $APP_VERSION (build $APP_BUILD) was built from these public sources:

  PearSilicon   https://github.com/denizomer10/PearSilicon/tree/$COMMIT
  PearRuntime   https://github.com/denizomer10/PearRuntime/tree/$(sub_commit runtime)
  PearDebug     https://github.com/denizomer10/PearDebug/tree/$(sub_commit Vendor/PearDebug)
  PearANGLE     https://github.com/denizomer10/PearANGLE/tree/$(sub_commit runtime/third_party/angle)

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
