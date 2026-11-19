#!/usr/bin/env python3
"""Headless production storage/sandbox.rs filesystem tests (Mac Catalyst).

Usage: python3 scripts/filesystem-smoke.py
Requires macOS, a non-root user, Xcode/CLT clang++, cargo with rust-src, and
Python's standard library. Links the runtime's Rust smoke build
(scripts/build-smoke-runtime.sh: inert interpose tables) into a headless
fixture that invokes the actual wrappers against synthetic temporary files.
No apps, UI, network, sandbox profiles, installed files or system/user
settings are touched. Fixture builds, module caches, homes and data are
removed with the temporary root; the smoke library stays in runtime/build.
"""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def clean_environment():
    return {
        key: value for key, value in os.environ.items()
        if not key.startswith(("PEAR_", "PEARSILICON_", "DYLD_"))
    }


def isolated_environment(directory):
    env = clean_environment()
    for name in ("process-home", "tmp", "modules", "user-files", "relocated data/app-data"):
        (directory / name).mkdir(parents=True)
    env.update({
        "HOME": str(directory / "process-home"),
        "CFFIXED_USER_HOME": str(directory / "process-home"),
        "TMPDIR": str(directory / "tmp"),
        "CLANG_MODULE_CACHE_PATH": str(directory / "modules"),
        "XDG_CACHE_HOME": str(directory / "modules"),
        "FILESYSTEM_SMOKE_ROOT": str(directory),
        "PEAR_HOME_DIR": str(directory / "relocated data/app-data"),
        "PEAR_SUPPORT_ROOT": str(directory / "default-support"),
    })
    # In particular, PEAR_IOS_SANDBOX and PEAR_DEBUG_PATHS stay UNSET. The real
    # constructors run, but may not apply a profile or write /tmp/pear-fs.log.
    assert "PEAR_IOS_SANDBOX" not in env and "PEAR_DEBUG_PATHS" not in env
    return env


def compile_fixture(compiler, sdk, directory, runtime):
    directory.mkdir()
    env = isolated_environment(directory)
    frameworks = Path(sdk) / "System/iOSSupport/System/Library/Frameworks"
    if not frameworks.is_dir():
        raise RuntimeError("SDK has no Mac Catalyst frameworks")
    executable = directory / "filesystem-smoke"
    subprocess.run([
        compiler, "-std=c++17", "-fobjc-arc", "-Wno-deprecated-declarations",
        "-target", "arm64-apple-ios15.0-macabi", "-isysroot", sdk, "-iframework", str(frameworks),
        str(ROOT / "scripts/filesystem-smoke.mm"),
        *[flag for name in ("Foundation", "UIKit", "CoreGraphics", "QuartzCore", "Metal", "GameController",
                            "Security", "AppKit", "AudioToolbox", "IOKit") for flag in ("-framework", name)],
        "-Wl,-dead_strip", runtime, "-o", str(executable),
    ], cwd=ROOT, env=env, check=True, timeout=90)
    # A fixture must never globally interpose filesystem calls, even at startup.
    load_commands = subprocess.check_output(
        ["xcrun", "otool", "-l", str(executable)],
        cwd=ROOT, env=env, text=True, timeout=15,
    )
    if "sectname __interpose" in load_commands:
        raise RuntimeError("fixture unexpectedly contains an active interpose table")
    return executable, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("these tests require macOS Foundation and Darwin filesystem APIs")
    if os.geteuid() == 0:
        parser.error("run as a non-root user so native permission denials are meaningful")
    with tempfile.TemporaryDirectory(prefix="pear-filesystem-smoke-") as temporary:
        directory = Path(temporary).resolve()
        tools = directory / "tools"
        tools.mkdir()
        env = isolated_environment(tools)
        compiler = subprocess.check_output(
            ["xcrun", "--find", "clang++"], env=env, text=True, timeout=15,
        ).strip()
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True, timeout=15,
        ).strip()
        runtime = subprocess.check_output(
            [str(ROOT / "scripts/build-smoke-runtime.sh"), "catalyst"], text=True, timeout=1800,
        ).strip().splitlines()[-1]
        print("Building headless Catalyst fixture linking production storage/sandbox.rs", flush=True)
        executable, fixture_env = compile_fixture(compiler, sdk, directory / "current", runtime)
        for mode in ("all", "persist"):
            subprocess.run(
                [str(executable), mode], cwd=ROOT, env=fixture_env, check=True, timeout=60,
            )
    print("\nPASS filesystem smoke: temporary synthetic data, builds and caches removed; no live-app/gameplay claim", flush=True)


if __name__ == "__main__":
    main()
