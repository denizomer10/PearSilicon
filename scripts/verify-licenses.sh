#!/bin/bash
# Checks that a PearSilicon.app (or the ZIP it is shipped in) carries every
# license text, notice and source pointer its redistributed components need.
# Run by scripts/build-app.sh before signing and by scripts/publish-release.sh
# on the built and on the downloaded archive.
#
#   --remote   also check that every commit named in the source files exists
#              on GitHub (needs `gh`), so the Corresponding Source of the
#              GPL-3.0 engine and the pinned ANGLE fork can really be fetched.
#
# Usage: scripts/verify-licenses.sh [--remote] <PearSilicon.app | PearSilicon.zip>
set -euo pipefail

remote=0
if [[ "${1:-}" == "--remote" ]]; then remote=1; shift; fi
target="${1:?usage: verify-licenses.sh [--remote] <PearSilicon.app|PearSilicon.zip>}"

errors=0
fail() { echo "license check: $*" >&2; errors=$((errors + 1)); }

if [[ "$target" == *.zip ]]; then
  unpacked="$(mktemp -d)"
  trap 'rm -rf "$unpacked"' EXIT
  ditto -x -k "$target" "$unpacked"
  target="$unpacked/PearSilicon.app"
fi
res="$target/Contents/Resources"
[[ -d "$res" ]] || { echo "license check: $res not found" >&2; exit 1; }

# need FILE [PATTERN...]: FILE exists, is not empty and contains each pattern.
need() {
  local file="$1"; shift
  if [[ ! -s "$res/$file" ]]; then fail "missing $file"; return; fi
  local pattern
  for pattern in "$@"; do
    grep -q -- "$pattern" "$res/$file" || fail "$file does not mention '$pattern'"
  done
}

# --- PearSilicon, PearRuntime, PearDebug (MIT) -------------------------------
need Licenses/LICENSE.PearSilicon "MIT License"
need Licenses/LICENSE.PearRuntime "MIT License"
need Licenses/LICENSE.PearDebug "MIT License"
need Licenses/THIRD_PARTY_NOTICES.md "GPL-3.0-or-later" "ANGLE" "OpenAL Soft"
need Licenses/SOURCE.txt "github.com/denizomer10/PearSilicon/tree/"

# --- ANGLE for Mac Catalyst apps --------------------------------------------
need PearANGLE/LICENSE.ANGLE "Redistribution and use"
need PearANGLE/THIRD_PARTY_LICENSES.txt "abseil-cpp" "zlib"

# --- PearLegacyEngine (GPL-3.0-or-later binary) ------------------------------
engine="PearLegacyEngine"
if [[ -e "$res/$engine/touchHLE" ]]; then
  need "$engine/COPYING" "GNU GENERAL PUBLIC LICENSE" "Version 3"
  need "$engine/LICENSE.MPL-2.0" "Mozilla Public License Version 2.0"
  need "$engine/NOTICES.txt" "GNU General Public License" "OpenAL Soft" "SDL 2" "Dynarmic"
  need "$engine/SOURCE.txt" "github.com/denizomer10/PearLegacyEngine/tree/"
  if grep -q "WARNING" "$res/$engine/SOURCE.txt" 2>/dev/null; then
    fail "$engine/SOURCE.txt: the engine was staged from a checkout with uncommitted changes"
  fi
  need "$engine/touchHLE_dylibs/README.md" "Source code"
  for lib in libgcc libstdcxx libz libsqlite3 libxml2; do
    need "$engine/touchHLE_dylibs/COPYING.$lib"
  done
  need "$engine/touchHLE_fonts/LICENSE.liberation"
  need "$engine/touchHLE_fonts/LICENSE.noto"
  angle="$engine/touchHLE_dylibs/angle"
  if [[ -d "$res/$angle" ]]; then
    need "$angle/LICENSE.ANGLE" "Redistribution and use"
    need "$angle/THIRD_PARTY_LICENSES.txt"
    for pair in "libdawn_:dawn" "libc++_chrome:libc++" "abseil-cpp:abseil-cpp" "chrome_zlib:zlib"; do
      if compgen -G "$res/$angle/*${pair%%:*}*.dylib" >/dev/null; then
        need "$angle/THIRD_PARTY_LICENSES.txt" "${pair#*:} ("
      fi
    done
  fi
fi

# --- Every shipped Mach-O must be covered ------------------------------------
# PearSilicon's own components are covered by Licenses/; anything else must sit
# in a directory (or a parent inside Resources) that has its own license file.
own='^(libPearRuntime|libPearOpenGLES|libcxxcompat|libswiftUIKit)\.dylib$|^MarketplaceKit\.framework/'
while IFS= read -r -d '' file; do
  rel="${file#"$res"/}"
  file -b "$file" | grep -q "Mach-O" || continue
  [[ "$rel" =~ $own ]] && continue
  dir="$(dirname "$file")"
  covered=0
  while [[ "$dir" == "$res"/* ]]; do
    if compgen -G "$dir/LICENSE*" >/dev/null || compgen -G "$dir/COPYING*" >/dev/null; then
      covered=1; break
    fi
    dir="$(dirname "$dir")"
  done
  [[ "$covered" == 1 ]] || fail "$rel has no license file next to it"
done < <(find "$res" -type f -print0)

# --- Source availability ------------------------------------------------------
if [[ "$remote" == 1 ]]; then
  while read -r repo sha; do
    if ! gh api "repos/denizomer10/$repo/commits/$sha" --silent >/dev/null 2>&1; then
      fail "commit $sha is not available on github.com/denizomer10/$repo"
    fi
  done < <(cat "$res/Licenses/SOURCE.txt" "$res/$engine/SOURCE.txt" 2>/dev/null \
    | grep -oE 'github\.com/denizomer10/[A-Za-z0-9_.-]+/tree/[0-9a-f]{7,40}' \
    | sed -E 's#github\.com/denizomer10/([^/]+)/tree/#\1 #' | sort -u)
fi

if [[ "$errors" -gt 0 ]]; then
  echo "license check: $errors problem(s) in $1" >&2
  exit 1
fi
echo ">> License notices OK: $1"
