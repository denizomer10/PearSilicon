#!/bin/bash
# In-memory input/screen regression tests; no desktop automation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
probe="$(mktemp -d "${TMPDIR:-/tmp}/pear-geometry.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"
common=(-std=c++17 -fobjc-arc -target arm64-apple-ios15.0-macabi -isysroot "$sdk"
        -iframework "$sdk/System/iOSSupport/System/Library/Frameworks" -I"$root/runtime/include")
xcrun clang++ "${common[@]}" "$root/scripts/touch-geometry-smoke.mm" -framework CoreGraphics -o "$probe/geometry"
"$probe/geometry"
# legacy-direct-touch-smoke.mm and screen-cache-smoke.mm replace runtime
# internals (window lookup, GL touch mapping, screen cache) with in-test fakes
# by compiling the runtime sources into the probe. The runtime is Rust now;
# those probes need a Rust-side harness before they can run again.
echo "SKIP: legacy-direct-touch and screen-cache probes need a Rust-side harness (runtime sources are Rust)"
