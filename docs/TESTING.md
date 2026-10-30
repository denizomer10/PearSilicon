# Testing and validation

PearSilicon is validated in layers. Each layer answers a narrower question than
"the game works": a passing process check is not a gameplay, input-coordinate,
account, download or rendering result. Reports should name the layer that was
actually exercised.

## Automated suites

Run from the repository root with a full Xcode toolchain and free space:

```sh
# Swift unit/integration tests, including adversarial installer and GUI-state tests
swift test

# Installed filesystem shim: permissions, relocation boundaries, symlink/hardlink
python3 scripts/filesystem-smoke.py

# Keychain/key generation: in-memory pair persistence and the real Catalyst
# SecKeyGeneratePair path under an isolated sandbox
python3 scripts/keychain-smoke.py --active-interpose

# Runtime IPC/KV, deadlines, malformed peers, ubiquity-token/Base64 compatibility
python3 scripts/runtime-client-smoke.py <path-to-PearSilicon-executable>
```

The optional runtime-client executable is invoked only as `host-service`; the
suite does not open the GUI or launch a game. All fixtures use temporary data
roots. The keychain suite never reads real credentials or calls a real cloud
service.

### What the suites cover

| Suite | Main checks |
| --- | --- |
| `swift test` | Installer atomic replacement, CRC and archive admission, stopped-app leases, mode switches, storage migration, GUI import routing/FIFO/cancellation, host protocol |
| `filesystem-smoke.py` | Writable reopen repair only inside `PEAR_HOME_DIR`; path/symlink/hardlink escapes; mode and errno preservation; pre-fix negative control |
| `keychain-smoke.py` | Symmetric public/private sanitization, tagged lookup across processes, signing/verification, real Catalyst legacy generation |
| `runtime-client-smoke.py` | Authenticated IPC framing, timeouts, loss/ACK behavior, malformed replies, immutable KV cache, stable `NSData` ubiquity token |

Tests that require a real signed/decrypted fixture are skipped when that fixture
is unavailable. A skip is not a pass for that path.

## Background app checks

The tracked launcher-level check starts installed apps with `--background`, so it
does not request focus or synthesize input:

```sh
python3 scripts/e2e-games.py \
  --cli /Applications/PearSilicon.app/Contents/MacOS/PearSilicon \
  --settle 12 --cycles 2 --stress \
  --json-out /tmp/pearsilicon-e2e.json
```

By default it checks Cut the Rope, Run Sackboy and Candy Crush Soda. Override the
set with repeated `--app <bundle-id>` arguments.

The script:

- skips any app that was already running and never stops it;
- launches only apps it started, waits a bounded settle period and verifies the
  process is still alive;
- reads only the newly appended runtime-log segment for `signal`/`exception`
  markers and checks for new crash reports;
- stops its own app, verifies shutdown, and with `--stress` also verifies that a
  second launch is rejected while running and a second stop fails cleanly;
- checks that no `.pear-install-*` staging directory remains.

It does **not** verify menus, touch coordinates, downloads, login/OAuth, GPU
output, frame pacing or sustained gameplay. Those require a manual session or a
future instrumented harness. Do not describe a passing run as "the game works".

## Manual checks

For a release candidate, manually verify at least:

1. Drop an IPA and an `.app` bundle onto the GUI; confirm the correct installer
   path is used and the library refreshes once.
2. Start two imports close together; the second must wait, and the busy state
   must clear only after both finish.
3. Launch, quit and relaunch a game; confirm mouse/touch coordinates with the
   keymapper disabled, then with one explicit tap binding.
4. Move storage to an external disk and launch through PearSilicon; confirm saves,
   keymaps and the previous copy remain intact.
5. Exercise an account/login flow separately. Record the app version and whether
   the failure is local (runtime log, crash report) or remote (network/service).

## Safety boundaries

- The installer validates ZIP entry names before extraction and rejects
  traversal, absolute paths, Windows drive paths and ambiguous separators.
- Failed preparation or signing leaves the installed bundle in place. Uninstall
  and preparation switches take the same stopped-app lease as launch.
- GUI imports are serialized; launch, uninstall and storage changes do not run
  concurrently with an import.
- The filesystem and keychain suites use temporary roots and print no key or
  credential material.
- These mechanisms are compatibility and data-safety checks, not a security
  boundary for untrusted apps. PearSilicon still runs on Apple's
  Catalyst/iOSSupport frameworks; it does not replace UIKit or the kernel.

## Independence from PlayCover

The repository contains no PlayTools/PlayCover runtime or code dependency, and
the launcher, installer, shims, keymapper and host service are implemented here.
That is independence from the PlayCover project, not from Apple's iOSSupport
frameworks. See [Architecture](ARCHITECTURE.md) for the full execution model.
