#!/bin/bash
# Puts the license texts, notices and source information that the
# PearLegacyEngine binary distribution needs next to the staged engine:
#
#   COPYING                          GPL-3.0 text: the touchHLE/PearLegacyEngine
#                                    *binary* is GPL-3.0-or-later (statically
#                                    linked OpenAL Soft, SDL2, Dynarmic, ...)
#   LICENSE.MPL-2.0                  the engine's source license
#   NOTICES.txt                      the binary's own `--copyright` output
#                                    (Rust crates, Dynarmic, SDL2, OpenAL Soft,
#                                    stb_image, PVRTDecompress)
#   SOURCE.txt                       where the Corresponding Source of this
#                                    exact build is published
#   touchHLE_dylibs/angle/LICENSE.ANGLE, THIRD_PARTY_LICENSES.txt
#                                    ANGLE plus the Dawn, abseil, libc++, zlib,
#                                    ... builds shipped beside it
#
# touchHLE_dylibs/COPYING.* and touchHLE_fonts/LICENSE.* come with the engine
# checkout and are copied by scripts/setup-legacy-engine.sh.
#
# Usage: scripts/stage-legacy-licenses.sh <stage-dir> <engine-checkout> [<jit-checkout>]
set -euo pipefail

stage="${1:?usage: stage-legacy-licenses.sh <stage-dir> <engine-checkout> [<jit-checkout>]}"
engine_home="${2:?usage: stage-legacy-licenses.sh <stage-dir> <engine-checkout> [<jit-checkout>]}"
jit_home="${3:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$(cd "$stage" && pwd)"
engine_home="$(cd "$engine_home" && pwd)"
binary="$stage/touchHLE"
fail() { echo "error: $*" >&2; exit 1; }

[[ -x "$binary" ]] || fail "$binary is missing"
[[ -f "$engine_home/LICENSE" ]] || fail "$engine_home/LICENSE (MPL-2.0) is missing"
[[ -f "$engine_home/dev-scripts/gpl-3.0.txt" ]] || fail "$engine_home/dev-scripts/gpl-3.0.txt is missing"

cp "$engine_home/LICENSE" "$stage/LICENSE.MPL-2.0"
cp "$engine_home/dev-scripts/gpl-3.0.txt" "$stage/COPYING"

# The binary prints its notices on stderr after a few log lines; keep the
# notices only. It writes nothing to its working directory for --copyright.
notices_tmp="$(mktemp -d)"
trap 'rm -rf "$notices_tmp"' EXIT
( cd "$notices_tmp" && "$binary" --copyright >"$notices_tmp/raw.txt" 2>&1 ) \
  || fail "$binary --copyright failed"
awk 'found || /^The following authorship, copyright and license information/ {found=1; print}' \
  "$notices_tmp/raw.txt" > "$stage/NOTICES.txt"
grep -q "GNU General Public License" "$stage/NOTICES.txt" \
  || fail "$binary --copyright did not print the expected license notice"

# --- Corresponding Source --------------------------------------------------
# The binary embeds `git describe --always` of the commit it was built from,
# which may be older than the checkout's HEAD.
version="$({ "$binary" --version 2>&1 || true; } | sed -n 's/^PearLegacyEngine \(v[^ ]*\).*/\1/p' | head -1)"
[[ -n "$version" ]] || fail "cannot read the engine version from $binary"
engine_ref="$version"
if [[ "$version" =~ -g([0-9a-f]+)$ ]]; then
  engine_ref="${BASH_REMATCH[1]}"
fi
engine_commit="$(git -C "$engine_home" rev-parse --verify --quiet "$engine_ref^{commit}" 2>/dev/null || true)"
[[ -n "$engine_commit" ]] || fail "engine commit $engine_ref ($version) is not in $engine_home"
engine_dirty=""
if [[ "$engine_commit" == "$(git -C "$engine_home" rev-parse HEAD)" && \
      -n "$(git -C "$engine_home" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  engine_dirty=" (WARNING: the checkout had uncommitted changes when this was staged)"
fi

jit_line="not used (the engine's vendor/dynarmic submodule)"
if [[ -n "$jit_home" && -e "$jit_home/.git" ]]; then
  jit_commit="$(git -C "$jit_home" rev-parse HEAD)"
  jit_line="https://github.com/denizomer10/PearLegacyJIT/tree/$jit_commit"
  if [[ -n "$(git -C "$jit_home" status --porcelain --untracked-files=no)" ]]; then
    jit_line="$jit_line (WARNING: uncommitted changes)"
  fi
fi

angle_dir="$stage/touchHLE_dylibs/angle"
angle_hash=""
if [[ -f "$angle_dir/libGLESv2.dylib" ]]; then
  angle_hash="$(strings -a "$angle_dir/libGLESv2.dylib" | sed -n 's/.*git hash: \([0-9a-f]\{7,\}\).*/\1/p' | head -1)"
fi

{
  cat <<EOF
PearLegacyEngine — source code for this binary distribution
==========================================================

The touchHLE executable in this folder is PearLegacyEngine $version, a fork of
touchHLE (https://github.com/touchHLE/touchHLE). Its own source files are
under the Mozilla Public License 2.0 (LICENSE.MPL-2.0); the executable, which
statically links OpenAL Soft (LGPL-2.0-or-later), SDL2, Dynarmic and other
libraries, is distributed under the GNU General Public License version 3 or
later (COPYING). NOTICES.txt lists every library inside it.

The complete Corresponding Source, including the build scripts, is available
at no charge from the public repositories below, at exactly these commits:

  PearLegacyEngine  https://github.com/denizomer10/PearLegacyEngine/tree/$engine_commit$engine_dirty
  PearLegacyJIT     $jit_line
EOF
  if [[ -n "$angle_hash" ]]; then
    echo "  ANGLE (dylibs)    https://github.com/denizomer10/angle/tree/$angle_hash"
  fi
  echo
  echo "Submodules pinned by that PearLegacyEngine commit (git submodule update --init):"
  urls="$(git -C "$engine_home" show "$engine_commit:.gitmodules" 2>/dev/null || true)"
  git -C "$engine_home" ls-tree "$engine_commit" vendor/ | while read -r mode type object path; do
    [[ "$type" == commit ]] || continue
    url="$(printf '%s\n' "$urls" | awk -v p="$path" '
      $1 == "path" && $3 == p {hit=1; next}
      hit && $1 == "url" {print $3; exit}
      /^\[submodule/ {hit=0}')"
    printf '  %-20s %s @ %s\n' "$path" "${url:-unknown}" "$object"
  done
  cat <<EOF

touchHLE_dylibs/ holds guest libraries loaded into the emulated iOS app, each
with its own license and source (touchHLE_dylibs/README.md, COPYING.*), and
touchHLE_fonts/ holds fonts under the SIL Open Font License (LICENSE.*).
If any link above stops working, ask the PearSilicon maintainers through
https://github.com/denizomer10/PearSilicon/issues for a copy of the source.
EOF
} > "$stage/SOURCE.txt"

# --- ANGLE beside the engine -------------------------------------------------
# The engine's ANGLE is a component build: Dawn, abseil, libc++ and zlib ship
# as separate dylibs, and libGLESv2 itself contains astc-encoder and xxHash.
if [[ -d "$angle_dir" ]]; then
  angle_root=""
  for candidate in "${PEAR_ANGLE_SOURCE_DIR:-}" "$engine_home/vendor/angle" "$repo_root/runtime/third_party/angle"; do
    if [[ -n "$candidate" && -f "$candidate/LICENSE" && -d "$candidate/third_party/abseil-cpp" ]]; then
      angle_root="$candidate"
      break
    fi
  done
  [[ -n "$angle_root" ]] || fail "no ANGLE checkout with third_party/ to take license texts from; set PEAR_ANGLE_SOURCE_DIR"
  cp "$angle_root/LICENSE" "$angle_dir/LICENSE.ANGLE"
  components=(abseil-cpp astc-encoder libc++ libc++abi spirv-headers vulkan-headers xxhash zlib)
  license_args=()
  if compgen -G "$angle_dir/libdawn_*.dylib" >/dev/null; then
    components+=(dawn)
    if [[ ! -f "$angle_root/third_party/dawn/LICENSE" ]]; then
      license_args+=(--license "dawn=$repo_root/licenses/dawn/LICENSE")
    fi
  fi
  for component in "${components[@]}"; do license_args+=(--component "$component"); done
  python3 "$repo_root/runtime/collect-angle-licenses.py" --angle-root "$angle_root" \
    --title "the PearLegacyEngine ANGLE build" \
    --out "$angle_dir/THIRD_PARTY_LICENSES.txt" "${license_args[@]}" >/dev/null
fi

echo ">> License notices staged in $stage (engine $version, commit ${engine_commit:0:12})"
