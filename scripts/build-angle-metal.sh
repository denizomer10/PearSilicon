#!/bin/bash
# Build the pinned fork with Chromium's DEPS-pinned Clang and the local SDK.
set -euo pipefail
angle_workspace="$(cd "$(dirname "$0")/.." && pwd)"
angle_source="$angle_workspace/runtime/third_party/angle"
angle_tools="${PEAR_DEPOT_TOOLS:-$angle_workspace/build/angle-tools/depot_tools}"
angle_jobs="${PEAR_ANGLE_JOBS:-4}"
case "$angle_jobs" in ''|*[!0-9]*) echo 'PEAR_ANGLE_JOBS must be a positive integer' >&2; exit 2;; esac
if [[ "$angle_jobs" -lt 1 || "$angle_jobs" -gt 64 ]]; then exit 2; fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --sync ) ]]; then
  echo "usage: [PEAR_ANGLE_TARGET=catalyst|macos] bash scripts/build-angle-metal.sh [--sync]" >&2; exit 2
fi
# The compatibility runtime loads ANGLE into Mac Catalyst game processes, so
# the shipped build targets arm64-apple-ios15.0-macabi (out/PearCatalyst).
# The macOS build (out/PearMetal) stays available for the 32-bit engine and
# for comparison runs.
angle_target="${PEAR_ANGLE_TARGET:-catalyst}"
case "$angle_target" in
  catalyst) angle_out_name=PearCatalyst; angle_args=angle-catalyst-args.gn; angle_platform='Mac Catalyst arm64 (arm64-apple-ios15.0-macabi)';;
  macos) angle_out_name=PearMetal; angle_args=angle-metal-args.gn; angle_platform='macOS arm64; Catalyst dynamic loading tested';;
  *) echo 'PEAR_ANGLE_TARGET must be catalyst or macos' >&2; exit 2;;
esac
if [[ ! -f "$angle_source/DEPS" ]]; then
  echo 'Initialize runtime/third_party/angle before building.' >&2; exit 2
fi
if [[ "${1:-}" == --sync ]]; then
  if [[ ! -f "$angle_tools/gclient.py" ]]; then
    mkdir -p "$(dirname "$angle_tools")"
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$angle_tools"
  fi
  [[ -f "$angle_source/.gclient" ]] || cp "$angle_workspace/scripts/angle-metal.gclient" "$angle_source/.gclient"
  git -C "$angle_source" submodule update --init --depth 1 testing
  (cd "$angle_source" && PATH="$angle_tools:$PATH" DEPOT_TOOLS_UPDATE=0 "$angle_tools/gclient" sync --nohooks --shallow)
fi
if [[ ! -x "$angle_source/buildtools/mac/gn" || ! -x "$angle_source/third_party/llvm-build/Release+Asserts/bin/clang++" ]]; then
  echo 'Pinned build tools are missing. Run this script with --sync.' >&2; exit 2
fi
angle_ninja="${PEAR_ANGLE_NINJA:-$(command -v ninja || true)}"
if [[ -z "$angle_ninja" ]]; then echo 'ninja is required.' >&2; exit 2; fi
angle_out="$angle_source/out/$angle_out_name"
mkdir -p "$angle_out"
rm -f "$angle_out/pearruntime-build.json"
cp "$angle_workspace/scripts/$angle_args" "$angle_out/args.gn"
(cd "$angle_source" && PATH="$angle_tools:$PATH" DEPOT_TOOLS_UPDATE=0 ./buildtools/mac/gn gen "out/$angle_out_name")
"$angle_ninja" -C "$angle_out" -j "$angle_jobs" libEGL libGLESv2
{
  bash "$angle_workspace/scripts/test-angle-backend.sh" "$angle_out"
  bash "$angle_workspace/scripts/test-angle-routing.sh" "$angle_out"
  bash "$angle_workspace/scripts/test-graphics-geometry.sh"
  if [[ "$angle_target" == catalyst ]]; then
    bash "$angle_workspace/scripts/test-angle-exclusive.sh" "$angle_out"
  fi
} | tee "$angle_out/pearruntime-tests.log"
python3 - "$angle_source" "$angle_out_name" "$angle_platform" <<'PY'
import hashlib, json, pathlib, subprocess, sys
source = pathlib.Path(sys.argv[1])
workspace = source.parents[2]
out = source / 'out' / sys.argv[2]
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
patch = subprocess.check_output(['git', '-C', str(source), 'diff', '--binary', 'HEAD'])
manifest = {
    'sourceRevision': revision,
    'binaryPlatform': sys.argv[3],
    'compiler': subprocess.check_output([str(source / 'third_party/llvm-build/Release+Asserts/bin/clang++'), '--version'], text=True).splitlines()[0],
    'macOSSDKVersion': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
    'trackedWorkingTreeDiffSHA256': hashlib.sha256(patch).hexdigest() if patch else None,
    'gnArgsSHA256': hashlib.sha256((out / 'args.gn').read_bytes()).hexdigest(),
    'testLogSHA256': hashlib.sha256((out / 'pearruntime-tests.log').read_bytes()).hexdigest(),
    'testSourcesSHA256': {str(path.relative_to(workspace)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in [*sorted((workspace / 'scripts').glob('angle-*-smoke.mm')),
                                      workspace / 'scripts/test-angle-backend.sh',
                                      workspace / 'scripts/test-angle-routing.sh',
                                      workspace / 'scripts/test-graphics-geometry.sh',
                                      workspace / 'scripts/screen-cache-smoke.mm',
                                      workspace / 'scripts/legacy-direct-touch-smoke.mm',
                                      workspace / 'scripts/touch-geometry-smoke.mm',
                                      *sorted((workspace / 'runtime/include').glob('PearANGLE*.h')),
                                      *sorted((workspace / 'runtime/include').glob('PearEAGL*.h')),
                                      workspace / 'runtime/include/PearGLTouch.h',
                                      *sorted((workspace / 'runtime/modules/graphics-gl').glob('ANGLE*.mm')),
                                      workspace / 'runtime/modules/graphics-gl/EAGLContextAdapter.mm',
                                      workspace / 'runtime/modules/graphics-gl/GLShim.mm',
                                      workspace / 'runtime/modules/graphics/ScreenShim.mm',
                                      workspace / 'runtime/modules/input/LegacyDirectTouch.mm']},
    'artifacts': {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                  for name in ['libEGL.dylib', 'libGLESv2.dylib']},
    'validated': ['Catalyst Metal pbuffer readback', 'loader lifecycle',
                  'context sharing, resize, ownership, thread-exit cleanup',
                  'GLES2/3 framebuffer copy and GL state preservation',
                  'GLES2/3 GLSL compile/link and Metal triangle readback',
                  'detached native layers: readback/swap, scale rebind, host coordinates',
                  'GLES2/3 renderbuffer storage/presentation, input-thread geometry generations',
                  'original EAGL selectors, sharegroups, drawable properties and TLS release',
                  'real Mach-O import and dynamic GL/class routing, opt-out, module rejection',
                  'synthetic current/previous touch mapping and render-thread screen refresh'],
    'automatedImportRoutingValidated': True,
    'gameRoutingValidated': False,
}
(out / 'pearruntime-build.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Wrote source/artifact provenance:', out / 'pearruntime-build.json')
PY
