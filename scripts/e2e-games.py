#!/usr/bin/env python3
"""Background game launch/relaunch checks through the packaged CLI.

This is a process-level smoke test, not a gameplay or input test. It launches an
installed app with `--background` (no focus change), verifies that the process
stays alive for a bounded settle period, checks the new runtime log segment for
signal/exception entries, then stops only the app it started. Apps that were
already running are skipped, never stopped.

Usage:
  python3 scripts/e2e-games.py --cli /Applications/PearSilicon.app/Contents/MacOS/PearSilicon
  python3 scripts/e2e-games.py --cli ... --app com.zeptolab.ctrexperimentslite --cycles 2
"""
import argparse
import json
import plistlib
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_APPS = [
    "com.zeptolab.ctrexperimentslite",
    "com.playstation.runsackboyrun",
    "com.midasplayer.apps.candycrushsodasaga",
]
SUPPORT = Path.home() / "Library/Application Support/PearSilicon"
LOGS = SUPPORT / "Logs"
DIAGNOSTICS = Path.home() / "Library/Logs/DiagnosticReports"
FAIL_MARKERS = ("[PearRuntime][signal]", "[PearRuntime][exception]")


def run(cli, *arguments, timeout=90):
    return subprocess.run(
        [str(cli), *arguments], capture_output=True, text=True, timeout=timeout
    )


def inventory(cli):
    result = run(cli, "list", "--json", timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "list failed")
    return {row["bundleID"]: row for row in json.loads(result.stdout)}


def is_running(cli, bundle):
    row = inventory(cli).get(bundle)
    return bool(row and row.get("running"))


def log_tail(path, limit=12):
    if not path.exists():
        return ["<no runtime log>"]
    lines = path.read_text(errors="replace").splitlines()
    return lines[-limit:] if lines else ["<empty runtime log>"]


def new_crashes(executable, before):
    if not DIAGNOSTICS.is_dir():
        return []
    current = set()
    for entry in DIAGNOSTICS.iterdir():
        if entry.is_file() and entry.name.startswith(executable + "-") and entry.name.endswith(".ips"):
            current.add(entry.name)
    return sorted(current - before)


def crash_snapshot(executable):
    if not DIAGNOSTICS.is_dir():
        return set()
    return {
        entry.name for entry in DIAGNOSTICS.iterdir()
        if entry.is_file() and entry.name.startswith(executable + "-") and entry.name.endswith(".ips")
    }


def executable_name(bundle_path):
    try:
        info = plistlib.loads((Path(bundle_path) / "Info.plist").read_bytes())
        return info.get("CFBundleExecutable") or Path(bundle_path).stem
    except Exception:
        return Path(bundle_path).stem


def stale_staging():
    applications = SUPPORT / "Applications"
    if not applications.is_dir():
        return []
    return sorted(path.name for path in applications.glob(".pear-install-*"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="packaged PearSilicon executable")
    parser.add_argument("--app", action="append", dest="apps", help="bundle id (repeatable)")
    parser.add_argument("--settle", type=float, default=12.0)
    parser.add_argument("--cycles", type=int, default=1)
    parser.add_argument("--stop-timeout", type=float, default=25.0)
    parser.add_argument("--restart-delay", type=float, default=2.0)
    parser.add_argument("--stress", action="store_true", help="also verify duplicate-launch/duplicate-stop error paths")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--log-tail", type=int, default=12)
    args = parser.parse_args()

    cli = args.cli.resolve()
    if not cli.is_file():
        parser.error("CLI executable not found: %s" % cli)
    if args.cycles < 1:
        parser.error("--cycles must be at least 1")
    bundle_ids = args.apps or DEFAULT_APPS
    rows = []
    failures = 0

    started_inventory = inventory(cli)
    for bundle in bundle_ids:
        app = started_inventory.get(bundle)
        row = {"bundleID": bundle, "cycles": [], "status": "skipped"}
        rows.append(row)
        if not app:
            row.update(status="missing", error="not installed")
            failures += 1
            print("SKIP %s: not installed" % bundle, flush=True)
            continue
        if app.get("running"):
            row.update(status="already-running")
            print("SKIP %s: already running; left untouched" % bundle, flush=True)
            continue

        executable = executable_name(app["path"])
        log_path = LOGS / (bundle + ".log")
        row.update(name=app.get("name"), executable=executable)
        for cycle in range(1, args.cycles + 1):
            cycle_row = {"cycle": cycle}
            row["cycles"].append(cycle_row)
            crash_before = crash_snapshot(executable)
            log_before = log_path.stat().st_size if log_path.exists() else 0
            launched = run(cli, "launch", bundle, "--background")
            cycle_row["launch"] = {
                "returncode": launched.returncode,
                "output": (launched.stdout + launched.stderr).strip()[-1500:],
            }
            if launched.returncode:
                cycle_row.update(status="launch-failed")
                failures += 1
                break

            deadline = time.monotonic() + args.settle
            while time.monotonic() < deadline:
                if not is_running(cli, bundle):
                    break
                time.sleep(0.5)
            alive = is_running(cli, bundle)
            cycle_row["runningAfterSettle"] = alive
            cycle_row["runtimeLog"] = log_tail(log_path, args.log_tail)
            cycle_row["newCrashes"] = new_crashes(executable, crash_before)
            appended = ""
            if log_path.exists() and log_path.stat().st_size > log_before:
                with log_path.open("rb") as handle:
                    handle.seek(log_before)
                    appended = handle.read().decode(errors="replace")
            cycle_row["newRuntimeFailures"] = [
                marker for marker in FAIL_MARKERS if marker in appended
            ]

            if args.stress and alive:
                duplicate = run(cli, "launch", bundle, "--background")
                process_count = len(subprocess.run(
                    ["/usr/bin/pgrep", "-f", app["path"] + "/"], capture_output=True, text=True
                ).stdout.split())
                cycle_row["duplicateLaunch"] = {
                    "returncode": duplicate.returncode,
                    "output": (duplicate.stdout + duplicate.stderr).strip()[-500:],
                    "processes": process_count,
                }
                if duplicate.returncode == 0 or process_count < 1:
                    cycle_row["status"] = "duplicate-launch"
                    failures += 1

            if not alive:
                cycle_row.update(status="exited")
                failures += 1
            elif cycle_row["newCrashes"] or cycle_row["newRuntimeFailures"]:
                cycle_row.update(status="runtime-error")
                failures += 1
            else:
                cycle_row.update(status="alive")

            stopped = run(cli, "stop", bundle, timeout=60)
            cycle_row["stop"] = {
                "returncode": stopped.returncode,
                "output": (stopped.stdout + stopped.stderr).strip()[-800:],
            }
            stop_deadline = time.monotonic() + args.stop_timeout
            while time.monotonic() < stop_deadline and is_running(cli, bundle):
                time.sleep(0.5)
            cycle_row["stopped"] = not is_running(cli, bundle)
            if not cycle_row["stopped"]:
                cycle_row["status"] = "stop-timeout"
                failures += 1
            elif args.stress:
                repeated = run(cli, "stop", bundle, timeout=30)
                cycle_row["duplicateStop"] = {
                    "returncode": repeated.returncode,
                    "output": (repeated.stdout + repeated.stderr).strip()[-500:],
                }
                if repeated.returncode == 0:
                    cycle_row["status"] = "duplicate-stop"
                    failures += 1
            if cycle_row["status"] != "alive":
                break
            if cycle < args.cycles:
                time.sleep(args.restart_delay)

        if row["cycles"]:
            row["status"] = (
                "passed" if all(c.get("status") == "alive" for c in row["cycles"]) else "failed"
            )
        print("%s %s: %s" % (row["status"].upper(), bundle, json.dumps(row)[:1200]), flush=True)

    staging = stale_staging()
    report = {
        "cli": str(cli),
        "settleSeconds": args.settle,
        "cycles": args.cycles,
        "apps": rows,
        "staleStagingDirectories": staging,
        "note": "Process-level launch/stop only; gameplay, rendering and account flows are not verified.",
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2) + "\n")
    if staging:
        failures += 1
        print("FAIL stale install staging remains: %s" % staging, flush=True)
    if failures:
        print("E2E GAMES: FAIL (%d failure(s))" % failures, flush=True)
        return 1
    print("E2E GAMES: PASS (process-level background launch/stop)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
