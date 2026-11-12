# PearWine 2.0 integration — 2026-11-12

`Vendor/PearWine` pins the runtime registry/API as a Git submodule. Clone with
`git submodule update --init --recursive`. SwiftPM links `PearWineKit`; the app
build copies its Python sources/catalog resource bundle. No new Wine binaries
are embedded, patched or re-signed. Existing 1.x engine manifests and custom
engines remain usable.

Before an explicit Wine launch, the assessment reads the real PE architecture
and SHA-256, probes the host, and checks known-runtime CPU/OS eligibility. The
known 1.0.1 app must pass deep/strict codesign verification and exact registry
Team ID/CDHash matching. Unknown engines receive no verified identity. If Python
3.9+ is absent, the UI reports analysis unavailable and retains the existing
launch path; the client never installs Python. An identity failure is fatal.
Analysis never silently chooses a new engine, applies patches, or adds graphics
controls. The ten initial PearWine game profiles remain untested proposals.

The UI exposes read-only compatibility analysis. Each entry's Data directory
stores `pearwine-compatibility.json`. CLI commands:

```sh
pearsilicon wine-import '/path/to/game' --exe game.exe --engine pearwine-1.0.1
pearsilicon wine-compat 'Game' --json
pearsilicon wine-launch 'Game' --observe-seconds 30 --stop-after-observation --diagnostics
```

`--wait` follows the private Wine session across launcher re-exec. Observation
JSON is saved as `Data/pearwine-launch-observation.json`; `gameplay_verified` is
always false. `--arguments-json '["arg"]'` passes a JSON string array as literal
EXE arguments. `--diagnostics` opts into Wine error logging. Stop affects only
the entry's private prefix. Normal launch does not force diagnostic settings.
A fresh Steam CEF StorageService fatal is shown as a startup issue and yields
nonzero CLI status, even while the main process is alive.

## Real tests

Host API: arm64, macOS 27.2, 8 GB, Metal present, Rosetta unavailable.
Runtime: signed pearwine-1.0.1 (MetalSharp v6, Wine 11.20), exact registry hash
and signer identity verified. Runtime signature is preserved.

- **Vice City:** real Documents folder imported, x86 EXE SHA-256
  `565ac7f80db4374a5bac5e195f947815451eade528a7bbe877d43317624a4022`.
  The integrated CLI observed 35 seconds of running execution. The user confirmed
  correct menu/game image. Controls, sustained gameplay and performance were
  not qualified. This is scoped menu/render evidence, not a general game pass.
- **Steam:** backed up the existing prefix before testing. The official client
  updater completed (x64 build 1794424036, EXE SHA-256
  `1e17d08cc3aaf4e0bec9584db41348305c9c9fd73b0318543fb15f4c71d4d699`).
  The user observed a window loop. Fresh logs repeatedly report
  `FATAL:target_services.cc(121)`, `process_state_.InitCalled()` from CEF's
  StorageService. Wine graphics, fresh browser cache and `WINEMSYNC=0` retries
  did not fix it. Settings were not persisted; previous cache is retained in
  `Data/Recovery/htmlcache-before-PearWine2`. Steam is **not stable/verified** on
  this signed runtime; an upstream CEF compatibility fix remains necessary.
  The new 20-second CLI health test correctly returned failure despite a live
  Steam process and stopped only its prefix.

Per-prefix session tracking fixes the host losing Steam after updater re-exec;
it does not fix the upstream CEF crash. No security-disabling workaround was
added. Real game binaries, full logs, caches and backups are not committed.

Automated coverage includes the actual bundled API/PE path, rejection of fake
known-engine identity, re-exec lifetime and isolation between two prefixes,
fresh versus historical CEF log errors, and existing setup handoff regressions.
Full local suite: 354 XCTest cases, 22 optional skips, zero failures, plus 24
backup tests. PearWine: 28 Python cases and four Swift API tests. Remote CI and
other Macs are not claimed as tested.
