#!/usr/bin/env python3
"""Headless production SandboxShim filesystem tests, plus Catalyst syntax check.

Usage: python3 scripts/filesystem-smoke.py [--baseline-ref HEAD]
Requires macOS, a non-root user, Xcode/CLT clang++, and Python's standard library.
Includes production SandboxShim.mm in a native command-line fixture with inert
interpose tables; invokes the actual wrappers against synthetic temporary files.
The standalone production source is also syntax-checked for arm64 Mac Catalyst
with its real PearRuntime.h/UIKit headers. No apps, UI, network, sandbox profiles,
installed files, shared build outputs, or system/user settings are touched.
All builds, module caches, homes, and data are removed with the temporary root.

--baseline-ref additionally compiles that Git revision's SandboxShim and requires
the isolated exact-0405 regression to fail at writable reopen with EACCES. Use a
pre-fix revision; omit this option once HEAD contains the fix.
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


def compile_fixture(compiler, sdk, directory, source=None):
    directory.mkdir()
    env = isolated_environment(directory)
    # Native macOS has no UIKit. SandboxShim only needs PearLog from this header;
    # the separate Catalyst check uses the unmodified production UIKit header.
    (directory / "PearRuntime.h").write_text(
        '#import <Foundation/Foundation.h>\nvoid PearLog(NSString *format, ...);\n'
    )
    executable = directory / "filesystem-smoke"
    flags = []
    if source is not None:
        flags.extend([f'-DPEAR_FILESYSTEM_SOURCE="{source}"', "-DPEAR_FILESYSTEM_BASELINE=1"])
    subprocess.run([
        compiler, "-std=c++17", "-fobjc-arc", "-Wno-deprecated-declarations",
        "-isysroot", sdk, "-I", str(directory), *flags,
        "-framework", "Foundation", str(ROOT / "scripts/filesystem-smoke.mm"),
        "-o", str(executable),
    ], cwd=ROOT, env=env, check=True, timeout=90)
    # A fixture must never globally interpose filesystem calls, even at startup.
    load_commands = subprocess.check_output(
        ["xcrun", "otool", "-l", str(executable)],
        cwd=ROOT, env=env, text=True, timeout=15,
    )
    if "sectname __interpose" in load_commands:
        raise RuntimeError("fixture unexpectedly contains an active interpose table")
    return executable, env


def catalyst_syntax(compiler, sdk, env):
    frameworks = Path(sdk) / "System/iOSSupport/System/Library/Frameworks"
    if not frameworks.is_dir():
        raise RuntimeError("SDK has no Mac Catalyst frameworks")
    print("\nChecking standalone production SandboxShim: arm64 Mac Catalyst syntax", flush=True)
    subprocess.run([
        compiler, "-std=c++17", "-fobjc-arc", "-Wno-deprecated-declarations",
        "-target", "arm64-apple-ios15.0-macabi", "-isysroot", sdk,
        "-iframework", str(frameworks), "-I", str(ROOT / "runtime/include"),
        "-include", "PearRuntime.h", "-fsyntax-only", str(ROOT / "runtime/SandboxShim.mm"),
    ], cwd=ROOT, env=env, check=True, timeout=90)
    print("PASS production Catalyst syntax (real PearRuntime.h/UIKit; no build outputs)", flush=True)


def baseline_regression(ref, compiler, sdk, directory, env):
    print(f"\nBuilding pre-fix source from Git {ref!r} for the negative regression control", flush=True)
    source = directory / "baseline-SandboxShim.mm"
    source.write_bytes(subprocess.check_output(
        ["git", "--no-pager", "show", "--end-of-options", f"{ref}:runtime/SandboxShim.mm"],
        cwd=ROOT, env=env, timeout=15,
    ))
    executable, baseline_env = compile_fixture(compiler, sdk, directory / "baseline", source)
    result = subprocess.run(
        [str(executable), "regression"], cwd=ROOT, env=baseline_env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
    )
    print(result.stdout, end="", flush=True)
    expected = "REGRESSION: mode 0405 writable reopen failed (errno=13)"
    if result.returncode != 1 or expected not in result.stdout:
        raise RuntimeError("baseline did not fail at the expected EACCES writable reopen; choose a pre-fix revision")
    print("PASS negative control: pre-fix production source deterministically fails exact 0405 writable reopen", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="pre-fix Git revision to verify against the exact-0405 regression")
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
        print("Building native headless fixture including production SandboxShim.mm", flush=True)
        executable, fixture_env = compile_fixture(compiler, sdk, directory / "current")
        for mode in ("all", "persist"):
            subprocess.run(
                [str(executable), mode], cwd=ROOT, env=fixture_env, check=True, timeout=60,
            )
        catalyst_syntax(compiler, sdk, env)
        if args.baseline_ref:
            baseline_regression(args.baseline_ref, compiler, sdk, directory, env)
    print("\nPASS filesystem smoke: temporary synthetic data, builds and caches removed; no live-app/gameplay claim", flush=True)


if __name__ == "__main__":
    main()
