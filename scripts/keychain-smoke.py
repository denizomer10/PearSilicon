#!/usr/bin/env python3
"""Headless production KeychainShim tests; synthetic keys, no system keychain/UI.

Usage: python3 scripts/keychain-smoke.py [--platform all|macos|catalyst]
                                       [--active-interpose]
Requires macOS, Xcode/CLT clang++, and Python's standard library. Builds and all
keys live in a temporary directory under .build/keychain-smoke/ and are removed.
The default suite remaps the shim's Security interpose entries to an adapter
using real, in-memory SecKeyCreateRandomKey/SecKeyCopyPublicKey. Native macOS RSA
512 rejection is reported, never replaced with a larger key; Catalyst must pass.
The optional active check calls ACTUAL Catalyst SecKeyGeneratePair through a
production-shim dylib. It first requires sandbox guards denying securityd/Mach
lookup, networking, user-keychain reads, and filesystem writes outside the test
root (except device I/O). Generation is never attempted if those guards fail.
No app/GUI/network or native-macOS legacy generator is launched.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build" / "keychain-smoke"


def isolated_environment(directory):
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("PEAR_", "PEARSILICON_", "DYLD_"))
    }
    for name in ("home", "tmp", "modules"):
        (directory / name).mkdir(parents=True, exist_ok=True)
    env.update({
        "HOME": str(directory / "home"),
        "CFFIXED_USER_HOME": str(directory / "home"),
        "TMPDIR": str(directory / "tmp"),
        "CLANG_MODULE_CACHE_PATH": str(directory / "modules"),
        "PEAR_KEYCHAIN_DIR": str(directory / "unused-keychain"),
        "PEAR_SUPPORT_ROOT": str(directory / "support"),
        "PEAR_LOG_FILE": str(directory / "unused.log"),
        "KEYCHAIN_SMOKE_ROOT": str(directory),
    })
    return env


def run_platform(name, directory, compiler, sdk):
    directory.mkdir()
    env = isolated_environment(directory)
    executable = directory / "keychain-smoke"
    flags = []
    if name == "catalyst":
        frameworks = Path(sdk) / "System/iOSSupport/System/Library/Frameworks"
        if not frameworks.is_dir():
            raise RuntimeError("SDK has no Mac Catalyst frameworks")
        flags = [
            "-target", f"{platform.machine()}-apple-ios15.0-macabi",
            "-iframework", str(frameworks),
        ]
        env.update({
            "DYLD_FRAMEWORK_PATH": "/System/iOSSupport/System/Library/Frameworks",
            "DYLD_FALLBACK_FRAMEWORK_PATH": "/System/iOSSupport/System/Library/Frameworks",
            "DYLD_LIBRARY_PATH": "/System/iOSSupport/usr/lib",
            "DYLD_FALLBACK_LIBRARY_PATH": "/System/iOSSupport/usr/lib",
        })
    print(f"\nBuilding {name} headless fixture", flush=True)
    subprocess.run([
        compiler, "-std=c++17", "-fobjc-arc", "-Wno-deprecated-declarations",
        "-isysroot", sdk, *flags,
        "-framework", "Foundation", "-framework", "Security",
        str(ROOT / "scripts/keychain-smoke.mm"), "-o", str(executable),
    ], cwd=ROOT, env=env, check=True, timeout=90)
    failed = []
    rsa512_supported = True
    for mode in ("unit", "write", "read", "rsa512", "read512"):
        if mode == "read512" and not rsa512_supported:
            print(f"[{name}] SKIP read512: platform rejected RSA 512; no replacement key size", flush=True)
            continue
        print(f"[{name}] {mode}", flush=True)
        result = subprocess.run(
            [str(executable), mode], cwd=ROOT, env=env, timeout=90,
        )
        if mode == "rsa512" and result.returncode:
            rsa512_supported = False
            if result.returncode == 77 and name == "macos":
                print("[macos] NOTE: real RSA 512 rejection propagated correctly", flush=True)
                continue
        if result.returncode:
            failed.append(mode)
    return failed


def run_active_interpose(directory, compiler, sdk, shim_source=None):
    directory.mkdir()
    env = isolated_environment(directory)
    env["PEAR_KEYCHAIN_DIR"] = str(directory / "store")
    env["KEYCHAIN_SMOKE_RUN_ID"] = "pearsilicon-keychain-smoke-" + uuid.uuid4().hex
    denied = directory.parent / (directory.name + "-denied-synthetic-file")
    denied.write_text("synthetic sandbox guard; not credential data\n")
    env["KEYCHAIN_SMOKE_DENIED_FILE"] = str(denied)
    fixture = ROOT / "scripts/keychain-smoke.mm"
    dylib = directory / "keychain-active.dylib"
    executable = directory / "keychain-active"
    common = [
        compiler, "-std=c++17", "-fobjc-arc", "-Wno-deprecated-declarations",
        "-target", f"{platform.machine()}-apple-ios15.0-macabi",
        "-isysroot", sdk, "-iframework", str(Path(sdk) / "System/iOSSupport/System/Library/Frameworks"),
        "-framework", "Foundation", "-framework", "Security",
    ]
    source_flags = [] if shim_source is None else [f'-DPEAR_KEYCHAIN_SOURCE="{shim_source}"']
    print("\nBuilding ACTUAL Catalyst legacy/interpose check (sandbox required)", flush=True)
    subprocess.run([
        *common, *source_flags, "-DPEAR_KEYCHAIN_ACTIVE_DYLIB", "-dynamiclib",
        "-install_name", str(dylib), str(fixture), "-o", str(dylib),
    ], cwd=ROOT, env=env, check=True, timeout=90)
    subprocess.run([
        *common, "-DPEAR_KEYCHAIN_ACTIVE_CLI", str(fixture), str(dylib), "-o", str(executable),
    ], cwd=ROOT, env=env, check=True, timeout=90)

    # The exception is only our temporary subtree. No Security daemon can be
    # reached, and direct keychain DB reads/writes cannot escape into user data.
    root = json.dumps(str(directory))
    profile = directory / "active.sb"
    profile.write_text(f'''(version 1)
(allow default)
(deny mach-lookup)
(deny mach-register)
(deny network*)
(deny file-write* (require-not (require-any (subpath {root}) (subpath "/dev"))))
(deny file-read* (require-all (subpath "/Users") (require-not (subpath {root}))))
(deny file-read* (subpath "/Library/Keychains") (subpath "/private/var/root")
                 (subpath "/private/var/db/Keychains") (subpath "/private/var/db/SystemKey"))
''')
    # sandbox-exec is a protected system executable: set DYLD paths only AFTER
    # it applies the profile. The shim itself is an LC_LOAD_DYLIB, not an adapter.
    command = [
        "/usr/bin/sandbox-exec", "-f", str(profile), "/usr/bin/env",
        "DYLD_FRAMEWORK_PATH=/System/iOSSupport/System/Library/Frameworks",
        "DYLD_FALLBACK_FRAMEWORK_PATH=/System/iOSSupport/System/Library/Frameworks",
        "DYLD_LIBRARY_PATH=/System/iOSSupport/usr/lib",
        "DYLD_FALLBACK_LIBRARY_PATH=/System/iOSSupport/usr/lib",
        str(executable),
    ]
    for mode in ("guard", "generate", "reload"):
        print(f"[active-interpose] {mode}", flush=True)
        result = subprocess.run([*command, mode], cwd=directory, env=env, timeout=30)
        if result.returncode:
            print(f"[active-interpose] STOP: {mode} exited {result.returncode}; no later stages attempted", flush=True)
            return [mode]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("all", "macos", "catalyst"), default="all")
    parser.add_argument("--active-interpose", action="store_true", help="also test the real Catalyst legacy generator under verified sandbox guards")
    args = parser.parse_args()
    if args.active_interpose and args.platform == "macos":
        parser.error("The active legacy check is Catalyst-only, never native macOS")
    if platform.system() != "Darwin":
        parser.error("These tests require macOS Security/Foundation")
    compiler = subprocess.check_output(["xcrun", "--find", "clang++"], text=True, timeout=15).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True, timeout=15).strip()
    BUILD.mkdir(parents=True, exist_ok=True)
    failures = {}
    with tempfile.TemporaryDirectory(prefix="run-", dir=BUILD) as temporary:
        for name in (("macos", "catalyst") if args.platform == "all" else (args.platform,)):
            failed = run_platform(name, Path(temporary) / name, compiler, sdk)
            if failed:
                failures[name] = failed
        if args.active_interpose:
            failed = run_active_interpose(Path(temporary) / "active", compiler, sdk)
            if failed:
                failures["active-interpose"] = failed
    if failures:
        raise SystemExit(f"FAIL: {failures}")
    print("\nPASS: checks completed (platform limitations reported above); temporary synthetic keys/builds removed", flush=True)


if __name__ == "__main__":
    main()
