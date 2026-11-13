#!/usr/bin/env python3
"""Create isolated ad-hoc signed probes; never edit installed games or saves."""
import argparse
import shutil
import json
import pathlib
import plistlib
import re
import subprocess

WORKSPACE = pathlib.Path(__file__).resolve().parents[1]


def prepare(source, destination, label, bundle_id):
    if destination.exists():
        raise RuntimeError(f"Refusing to overwrite existing test bundle: {destination}")
    subprocess.run(["/bin/cp", "-cR", str(source), str(destination)], check=True)
    info_path = destination / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = bundle_id + ".angleprobe"
    info["CFBundleDisplayName"] = info["CFBundleName"] = label + " ANGLE Test"
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run([
        "/bin/cp", str(WORKSPACE / "runtime/build/libPearRuntime.dylib"),
        str(destination / "Frameworks/libPearRuntime.dylib"),
    ], check=True)
    frameworks = destination / "Frameworks"
    shutil.copy2(WORKSPACE / "runtime/build/libPearOpenGLES.dylib", frameworks / "libPearOpenGLES.dylib")
    shutil.copytree(WORKSPACE / "runtime/build/PearANGLE", frameworks / "PearANGLE", dirs_exist_ok=True)
    images = []
    for image in destination.rglob("*"):
        if image.is_symlink() or not image.is_file():
            continue
        with image.open("rb") as handle:
            magic = handle.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
            continue
        images.append(image)
        dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(image)], text=True)
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(" (compatibility version")[0]
            if dependency.startswith(str(source) + "/"):
                replacement = str(destination) + dependency[len(str(source)):]
                subprocess.run([
                    "/usr/bin/install_name_tool", "-change", dependency, replacement, str(image),
                ], check=True, capture_output=True)
        commands = subprocess.check_output(["/usr/bin/otool", "-l", str(image)], text=True)
        rpaths = set(re.findall(r"(?m)^\s*path (.+) \(offset \d+\)$", commands))
        for old in rpaths:
            if old.startswith(str(source) + "/"):
                replacement = str(destination) + old[len(str(source)):]
                subprocess.run([
                    "/usr/bin/install_name_tool", "-rpath", old, replacement, str(image),
                ], check=True, capture_output=True)
    # Replace modified Mach-O files with fresh inodes before signing. This
    # avoids stale executable-page validation after install_name_tool edits.
    for image in images:
        replacement = image.with_name(image.name + ".pear-signing")
        shutil.copy2(image, replacement)
        replacement.replace(image)
    containers = [item for item in destination.rglob("*")
                  if not item.is_symlink() and item.is_dir() and item.suffix in (".framework", ".appex", ".xpc", ".app")]
    for item in sorted(set(images + containers), key=lambda path: (len(path.parts), str(path)), reverse=True):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(item)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(destination)], check=True, capture_output=True)
    subprocess.run([
        "/usr/bin/codesign", "--verify", "--deep", str(destination),
    ], check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=pathlib.Path, default=pathlib.Path.home() /
                        "Library/Application Support/PearSilicon/ios-apps")
    parser.add_argument("--output", type=pathlib.Path, default=WORKSPACE / "build/angle-game-tests")
    parser.add_argument("--bundle-id", action="append", help="Installed bundle ID; repeat for several games")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    targets = [("com.zeptolab.ctrexperimentslite", "Cut the Rope"), ("com.mojang.minecraftpe", "Minecraft")]
    if args.bundle_id:
        targets = []
        for identifier in args.bundle_id:
            if not re.fullmatch(r"[A-Za-z0-9._-]+", identifier):
                raise ValueError("Invalid bundle identifier")
            info = plistlib.loads((args.library / (identifier + ".app") / "Info.plist").read_bytes())
            targets.append((identifier, info.get("CFBundleDisplayName", info.get("CFBundleName", identifier))))
    for bundle_id, label in targets:
        destination = output / f"{bundle_id}.angleprobe.app"
        prepare(args.library.resolve() / f"{bundle_id}.app", destination, label, bundle_id)
        home = output / (bundle_id + ".home")
        for child in ("Documents", "Library/Caches", "Library/Preferences", "tmp"):
            (home / child).mkdir(parents=True, exist_ok=True)
        rows.append({"id": bundle_id + ".angleprobe", "bundle": str(destination),
                     "home": str(home), "label": label})
    (output / "games.json").write_text(json.dumps(rows, indent=2) + "\n")
    print("Prepared isolated game bundles:", *[row["label"] for row in rows])


if __name__ == "__main__":
    main()
