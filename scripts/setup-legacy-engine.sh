#!/bin/bash
# Resolves PearLegacyEngine and PearLegacyJIT, builds them, and stages the
# result where PearSilicon looks for the 32-bit iOS runtime:
#
#   build/PearLegacyEngine/touchHLE
#   build/PearLegacyEngine/touchHLE_dylibs/
#   build/PearLegacyEngine/touchHLE_fonts/
#   build/PearLegacyEngine/touchHLE_default_options.txt
#
# See docs/ARCHITECTURE.md for the pinned commits and THIRD_PARTY_NOTICES.md for
# the licenses involved.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/setup-legacy-engine.sh [--check] [--no-build]

  --check      Only report what would be used; build and stage nothing.
  --no-build   Stage an existing build instead of running cargo.

Environment:
  PEAR_LEGACY_ENGINE_HOME   PearLegacyEngine checkout (default: ../PearLegacyEngine)
  PEAR_DYNARMIC_ROOT        PearLegacyJIT checkout (default: ../PearLegacyJIT)
EOF
}

check_only=0
build=1
for arg in "$@"; do
    case "$arg" in
        --check) check_only=1 ;;
        --no-build) build=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$repo_root/build/PearLegacyEngine"

find_dir() {
    local override="$1"; shift
    local candidate
    if [[ -n "$override" ]]; then
        if [[ -d "$override" ]]; then printf '%s\n' "$override"; return 0; fi
        echo "note: $override does not exist, falling back to the defaults" >&2
    fi
    for candidate in "$@"; do
        if [[ -d "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

engine_home="$(find_dir "${PEAR_LEGACY_ENGINE_HOME:-}" \
    "$repo_root/../PearLegacyEngine" "$HOME/PearLegacyEngine")" || {
    echo "error: no PearLegacyEngine checkout found." >&2
    echo "       clone https://github.com/denizomer10/PearLegacyEngine and set" >&2
    echo "       PEAR_LEGACY_ENGINE_HOME, or point PEARSILICON_LEGACY_ENGINE at a binary." >&2
    exit 1
}

jit_home="$(find_dir "${PEAR_DYNARMIC_ROOT:-}" \
    "$repo_root/../PearLegacyJIT" "$HOME/PearLegacyJIT")" || jit_home=""

engine_rev="$(git -C "$engine_home" describe --tags --always 2>/dev/null || echo unknown)"
jit_rev="unknown"
if [[ -n "$jit_home" ]]; then
    jit_rev="$(git -C "$jit_home" describe --tags --always 2>/dev/null || echo unknown)"
fi

echo "PearLegacyEngine: $engine_home ($engine_rev)"
if [[ -n "$jit_home" ]]; then
    echo "PearLegacyJIT:    $jit_home ($jit_rev)"
else
    echo "PearLegacyJIT:    not found, the engine's bundled Dynarmic submodule will be used"
fi

if [[ "$check_only" == 1 ]]; then
    echo "Staging target would be: $stage"
    exit 0
fi

if [[ "$build" == 1 ]]; then
    echo ">> Building PearLegacyEngine (release)"
    build_env=()
    if [[ -n "$jit_home" ]]; then
        build_env+=("PEAR_DYNARMIC_ROOT=$jit_home")
    fi
    ( cd "$engine_home" && env "${build_env[@]}" cargo build --release )
fi

binary="$engine_home/target/release/touchHLE"
if [[ ! -x "$binary" ]]; then
    echo "error: $binary is missing; run without --no-build first." >&2
    exit 1
fi

echo ">> Staging into $stage"
mkdir -p "$stage"
cp "$binary" "$stage/touchHLE"
for resource in touchHLE_dylibs touchHLE_fonts; do
    if [[ -d "$engine_home/$resource" ]]; then
        rm -rf "$stage/$resource"
        cp -R "$engine_home/$resource" "$stage/$resource"
    else
        echo "error: $engine_home/$resource is missing." >&2
        exit 1
    fi
done
if [[ -f "$engine_home/touchHLE_default_options.txt" ]]; then
    cp "$engine_home/touchHLE_default_options.txt" "$stage/touchHLE_default_options.txt"
fi

# ANGLE: the engine looks for touchHLE_dylibs/angle next to its resources, so
# stage the Metal-backed GLES runtime that the engine was built against.
angle_src=""
for candidate in "${PEAR_ANGLE_LIB_DIR:-}" "$engine_home/vendor/angle/out/MacMetal"; do
    if [[ -n "$candidate" && -f "$candidate/libEGL.dylib" ]]; then
        angle_src="$candidate"
        break
    fi
done
if [[ -z "$angle_src" ]]; then
    echo "error: ANGLE's libEGL.dylib was not found." >&2
    echo "       build it in the engine checkout (vendor/angle/build-macos.sh or the" >&2
    echo "       documented gn/ninja command) or set PEAR_ANGLE_LIB_DIR." >&2
    exit 1
fi

echo ">> Staging ANGLE from $angle_src"
angle_stage="$stage/touchHLE_dylibs/angle"
mkdir -p "$angle_stage"
# SwiftShader and the Vulkan validation layer are not used by the Metal path and
# account for most of ANGLE's size.
for lib in "$angle_src"/*.dylib; do
    case "$(basename "$lib")" in
        libVkLayer_khronos_validation.dylib|libvk_swiftshader.dylib) continue ;;
    esac
    cp "$lib" "$angle_stage/"
done
for lib in libEGL.dylib libGLESv2.dylib; do
    if [[ ! -f "$angle_stage/$lib" ]]; then
        echo "error: $lib is missing from $angle_src." >&2
        exit 1
    fi
done

echo ">> Ready: $stage/touchHLE ($engine_rev, JIT $jit_rev)"
