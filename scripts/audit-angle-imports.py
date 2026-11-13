#!/usr/bin/env python3
"""Read-only public ABI inventory; does not disassemble game implementation."""
import json
import pathlib
import plistlib
import re
import subprocess
import sys


def audit(bundle):
    bundle = pathlib.Path(bundle)
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    executable = bundle / info["CFBundleExecutable"]
    result = subprocess.run(["/usr/bin/nm", "-u", str(executable)],
                            text=True, capture_output=True, check=True)
    symbols = sorted(set(re.findall(r"(?m)^\s*_(gl[A-Z]\w*|EAGLGetProcAddress)\s*$", result.stdout)))
    return {"bundleID": info.get("CFBundleIdentifier"), "binary": str(executable),
            "directGLImports": symbols,
            "importsEAGLContext": "_OBJC_CLASS_$_EAGLContext" in result.stdout,
            "note": "Main executable only; dynamic lookups and embedded frameworks require separate audit. Imports do not prove the active renderer."}


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: audit-angle-imports.py /path/to/Game.app [...]")
    print(json.dumps([audit(path) for path in sys.argv[1:]], indent=2))
