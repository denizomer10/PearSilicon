#!/bin/bash
# Builds the PearRuntime Rust sources with their `smoke` test seams as a static
# library for the source-level smoke tests, and prints the archive's path as
# the last line of stdout (cargo's progress goes to stderr).
#
#   scripts/build-smoke-runtime.sh catalyst         pear-catalyst, Mac Catalyst
#   scripts/build-smoke-runtime.sh keychain-macos   pear-keychain, native macOS
#   scripts/build-smoke-runtime.sh keychain-catalyst pear-keychain, Mac Catalyst
#
# A smoke build has no image initializer and inert interpose tables (see
# runtime/rust/crates/pear-catalyst/src/smoke.rs), so a fixture linking it
# changes nothing in its own process until it calls a module itself. It is
# separate from build.sh's libPearRuntime.dylib and never shipped. Outputs go
# to $PEAR_RUNTIME_BUILD/rust-smoke (default runtime/build/rust-smoke), which
# later runs reuse incrementally.
#
# Catalyst fixtures link the Catalyst archive with:
#   -target arm64-apple-ios15.0-macabi -iframework <SDK>/System/iOSSupport/...
#   -framework Foundation -framework UIKit ... (build.sh's frameworks)
#   -Wl,-dead_strip <archive>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="${PEAR_RUNTIME_BUILD:-$root/runtime/build}"
case "$build" in /*) ;; *) build="$root/$build" ;; esac
target_dir="$build/rust-smoke"
manifest="$root/runtime/rust/Cargo.toml"
export IPHONEOS_DEPLOYMENT_TARGET=15.0 RUSTC_BOOTSTRAP=1
# build.sh reports the crates' warnings; keep the test output to the tests.
export RUSTFLAGS="${RUSTFLAGS:-} -Awarnings"
catalyst=(--target aarch64-apple-ios-macabi -Zbuild-std=std,panic_abort)

case "${1:-}" in
  catalyst)
    cargo build --manifest-path "$manifest" --profile smoke -p pear-catalyst --features smoke \
      "${catalyst[@]}" --target-dir "$target_dir" >&2
    echo "$target_dir/aarch64-apple-ios-macabi/smoke/libpear_catalyst.a"
    ;;
  keychain-macos)
    cargo rustc --manifest-path "$manifest" --profile smoke -p pear-keychain --features smoke \
      --crate-type staticlib --target-dir "$target_dir/host" >&2
    echo "$target_dir/host/smoke/libpear_keychain.a"
    ;;
  keychain-catalyst)
    cargo rustc --manifest-path "$manifest" --profile smoke -p pear-keychain --features smoke \
      --crate-type staticlib "${catalyst[@]}" --target-dir "$target_dir" >&2
    echo "$target_dir/aarch64-apple-ios-macabi/smoke/libpear_keychain.a"
    ;;
  *)
    echo "usage: $0 catalyst|keychain-macos|keychain-catalyst" >&2
    exit 2
    ;;
esac
