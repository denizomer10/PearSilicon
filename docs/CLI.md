# `pearsilicon` — command line tool

`pearsilicon` installs and launches iOS apps through PearSilicon without using
the GUI. It is built into the app binary, so it shares the installer, patcher,
signer, launcher and keymap code with the app. The supported inputs and options
differ in places; for example, `.app` directory installation is currently a CLI
workflow. See [Architecture](ARCHITECTURE.md) for the execution model.

It is designed for two workflows:

- **installing** an IPA archive (or a device-built `.app`) and launching it;
- **developing** an iOS app in a project toolchain and running it natively on the Mac, with no
  simulator, with logs and LLDB.

---

## Getting the command

The CLI lives in the PearSilicon binary; no separate CLI package is needed.
Opening the prebuilt GUI does not require a developer toolchain, but some app
preparation/relocation paths use `otool` and `install_name_tool` and require
Apple Command Line Tools. Source and project builds require full Xcode.

### After installing the app

```sh
sudo ln -sf /Applications/PearSilicon.app/Contents/MacOS/PearSilicon \
               /usr/local/bin/pearsilicon
pearsilicon --version
```

Or run `pearsilicon link` (from the app binary) and it creates that symlink for
you, printing the `sudo` command if it cannot.

### From a checkout

```sh
swift build
bin/pearsilicon help          # finds .build/debug/PearSilicon
# or, directly:
.build/debug/PearSilicon help
```

`bin/pearsilicon` only finds the binary; every command is implemented in the
app target (`Sources/PearSilicon/App/CLI.swift`).

> **Do not add a SwiftPM product named `pearsilicon`.** macOS filesystems are
> case-insensitive by default, so it collides with the `PearSilicon` app
> product and the two binaries overwrite each other. That is why the wrapper is
> a shell script in `bin/`.

---

## Commands

```
pearsilicon install <package|app>   Prepare and install an app package or a toolchain-built .app
pearsilicon run <package|app>       install + launch (--no-launch to stop after install)
pearsilicon launch <id|name>    Launch an installed app
pearsilicon debug <id|name>     Launch with touch logging and follow the log
pearsilicon stop <id|name>      Terminate a running app
pearsilicon list                List installed apps (--json for machines)
pearsilicon info <id|name>      Paths, version, keymap, runtime, ODR folder, pid
pearsilicon uninstall <id|name> Remove an app and its keymap
pearsilicon keymap <id|name>    Print the keymap (--path, --generate, --set FILE)
pearsilicon keys <id|name> [on|off]  Print or set the keymapper toggle
pearsilicon hud <id|name> [on|off]   Print or set the Metal HUD/FPS overlay
pearsilicon pointerlock <id|name> [on|off]  Allow or disallow the game's pointer lock
pearsilicon logs <id|name>      Print or follow the log (--follow, --system)
pearsilicon paths               Show the Application Support layout
pearsilicon storage [move <folder>|remove-previous]  Show storage or experimentally relocate managed apps/data
pearsilicon doctor              Report build tools, runtime location and library status
pearsilicon link                Symlink this binary to /usr/local/bin
pearsilicon build <project>     Build a scheme for a device, install, launch
```

`<id|name>` accepts either the bundle identifier or the display name. An
ambiguous display name lists the candidates instead of guessing.

### Common options

| Option | Meaning |
| --- | --- |
| `--keys` / `--no-keys` | Force the keymapper on/off for this launch (otherwise the per-app setting, then the global default, applies) |
| `--metal-hud` / `--no-metal-hud` | Force Metal's FPS/performance overlay on or off for this launch |
| `--pointer-lock` / `--no-pointer-lock` | Force the game's pointer lock on or off for this launch |
| `--log` | Write `Logs/<id>.log` under the selected storage root and follow it; the CLI exits when the app exits |
| `--wait` | Wait for the app to exit without creating a log file |
| `--background` | Do not activate the app or request foreground focus |
| `--env-injection` | Experimental: load the same full in-process runtime via `DYLD_INSERT_LIBRARIES`, with a local KV/static-device-profile host |
| `--load-command` | Select runtime `LC_LOAD_DYLIB` loading (the new-install default; launches otherwise preserve a saved environment-injection mode) |
| `--sandboxed` | Experimental permissive `sandbox-exec` launch; not secure per-app isolation, and not supported with environment injection |
| `--env KEY=VALUE` | Extra environment variable for the game (repeatable) |
| `--trace` | Shorthand for the runtime's touch debugging (`PEAR_DEBUG_TOUCH=1`) |
| `--lldb` | (`debug` only) attach LLDB to the launched process |
| `--no-keymap` | Do not auto-generate a starter keymap at install time |
| `--yes` | (`uninstall`) skip the confirmation prompt |

Exit codes: `0` success, `1` expected failure (not installed, invalid input),
`126`/`127` the wrapper could not execute PearSilicon.

### Examples

```sh
pearsilicon install ~/Downloads/App.app --launch
pearsilicon run ~/Downloads/App.app --keys --log
pearsilicon debug com.example.game --lldb
pearsilicon logs com.example.game --follow
pearsilicon keymap com.example.game --generate
pearsilicon keymap com.example.game --set ./my-keymap.json
pearsilicon keys com.example.game on
pearsilicon hud com.example.game on
pearsilicon pointerlock com.example.game off
pearsilicon run ~/Downloads/App.app --metal-hud
pearsilicon list --json
pearsilicon doctor
```

`doctor` reports macOS/architecture, full build-toolchain availability and
selection, the runtime library it would load, and the library location. A missing
full Xcode toolchain does not mean the prebuilt GUI cannot open. `pearsilicon build`
requires that toolchain and stops with setup instructions if it is unavailable.
`doctor` is not a clean-Mac installation test or a game compatibility check.

---

## Installing an app

`install` accepts two shapes:

- **package** — an `.ipa` (or the older `.app package`) zip; the `Payload/*.app`
  is prepared and signed;
- **`.app` directory** — an arm64 iOS device-build bundle. Unsupported binaries,
  including simulator builds, cannot be made compatible by renaming the bundle.

IPA archives can also be **dragged onto the main window**. For `.app` directories,
use `pearsilicon install <path-to-app>`: the GUI currently routes accepted URLs
through the archive installer and does not implement the directory-install path.

The pipeline is the same as the GUI: `Info.plist` rewrite → legacy metadata
removal → Mach-O platform patch (iOS → Mac Catalyst, arm64) → loading the
runtime with `LC_LOAD_DYLIB` by default (or launcher insertion with
`--env-injection`) → inside-out ad-hoc signing. Both modes still modify the
installed copy and rely on Apple's `/System/iOSSupport` frameworks; neither
provides an independent UIKit implementation. Default signing adds no debug
entitlements.

**Simulator builds are unsupported.** The `.app` directory installer rejects
bundles whose metadata declares a simulator platform; archive installation does
not perform that same check. Use an iOS device build (`generic/platform=iOS`),
which is the default destination for `pearsilicon build`.

A starter keymap is generated if the app has none (disable with `--no-keymap`).
The keymapper itself stays opt-in: pass `--keys`, or enable it for the app in
the GUI. Without it, no keymap path is passed and the keymapper's keyboard/mouse
handlers are not installed. Other compatibility hooks can still run.

---

## Experimental host-service split

```sh
pearsilicon install ~/Downloads/App.ipa --env-injection
pearsilicon launch com.example.game --background
# Explicitly select default load-command preparation while the app is stopped:
pearsilicon launch com.example.game --load-command --background
```

An environment-mode app keeps that mode on subsequent GUI/CLI launches; it is
not silently converted back. `--env-injection` and `--load-command` are mutually
exclusive. Close a running app before launching it again or changing modes.
A per-app interprocess lease covers the stopped-state check, preparation, and
spawn/host attachment, so two GUI/CLI launches cannot race a mode change.
Mode changes prepare and sign a staging copy, verify it, and atomically swap it
with the installed copy. Failures leave the installed copy unchanged.

In environment-injection mode the installed executable has **no runtime
`LC_LOAD_DYLIB`**. The launcher starts a separate, headless host, verifies its
readiness and device profile over an authenticated, per-launch Unix socket,
and supplies `DYLD_INSERT_LIBRARIES` plus the host handoff when starting the game.
The runtime's KV client connects from inside the game after loading. If host
startup or profile verification fails, the game is not started—there is no
automatic binary rewrite or local-store fallback. The host tracks the launched
PID, survives a short-lived CLI, and exits when the game exits. Failed launches
stop their host; post-spawn attachment failures also roll back the newly
launched game process.
An unattached host expires after 15 seconds.

**Current scope:** the local `NSUbiquitousKeyValueStore` backing state and the
static device-profile configuration are host-owned. The same full runtime is
still loaded into the game; UIKit, ObjC bridging, rendering, touch, audio,
device API hooks and keychain shims remain in-process. Only the device profile's
configuration/identity policy moved, not the numeric hardware, motion, or IOKit
implementation. The Wine/Proton analogy is limited to separating some state
management from in-process hooks, not the loader/API architecture. This is not
kernel-level iOS emulation, a wineserver equivalent, or a smaller injected
library. The original IPA is untouched,
but the installed copy still needs platform preparation, signing and dependency
fixups. API shims still intercept calls in the game's process.

The socket's directory is mode `0700`, its endpoint `0600`; peers must have the
same UID and supply the per-launch capability. Frames are bounded binary plists
so data/date/nested values retain their types. Current POC limits are 1 MiB per
frame, 512 KiB per persisted KV store, 1024 UTF-8 bytes per key, and eight clients.
A corrupt or oversized existing store is preserved and produces an explicit
startup error, not an empty replacement. Cold KV operations share one deadline
across lock waits and IPC (100 ms on the main thread, 500 ms on workers).
The host is the only KV file writer in a managed environment-injection session, persists before
acknowledging, and rejects a
second host for the same store. During an outage, the runtime may read its last
confirmed host cache but cannot write a separate local file; failed writes do
not make `synchronize` succeed. Socket authentication **does not** isolate a
hostile game from another process with the same UID. Directory hooks and
permissive macOS sandbox profiles, including the `sandbox-exec` experiment, are
not a strong per-app security boundary.

Host logs: `Logs/<bundleID>.host.log`. KV data stays at
`Games/<bundleID>/Library/Cloud/key-values.plist`, or under the selected
`PEAR_HOME_DIR` (including a migrated native container). Host socket/token
variables are launcher-managed. Children created after runtime bootstrap do
not inherit the launcher insertion/capability; earlier library initializers
are outside that guarantee.

### Startup device profile

After authenticated `ping`, the launcher fetches the read-only `device.get`
snapshot and verifies its schema, bundle binding, values, and synthetic vendor
identifier within the **same startup deadline**. Only six explicitly selected
raw settings are forwarded to the host; inherited profile metadata is stripped.
Missing, invalid, or mismatched profiles fail before the game is started.

The canonical snapshot is handed to the game through its startup environment.
`runtime/DeviceProfile.mm` captures it once into bounded C storage, shared by
`DeviceShim` and `NetworkShim`. Early `sysctl`/`uname` paths do not touch
Foundation, files, host IPC, or device-profile generation. Repeated API/header
lookups stay local, and a later host outage does not change the device profile.
KV outage/write behavior remains as described above.

| Input (`--env KEY=VALUE`) | Default | Managed-mode validation |
| --- | --- | --- |
| `PEAR_DEVICE_MODEL` | `iPhone15,2` | 1–63 ASCII bytes; starts with a letter, followed by letters/digits/commas/underscores/hyphens |
| `PEAR_DEVICE_NAME` | `iPhone` | Nonempty, at most 127 UTF-8 bytes, no Unicode controls |
| `PEAR_DEVICE_IDIOM` | `phone` | `phone`/`iphone` or `pad`/`ipad`, case-insensitive; normalized to `phone`/`pad` |
| `PEAR_FAKE_IOS_VERSION` | `16.0` | 1–3 dot-separated numeric components, 1–4 digits each |
| `PEAR_FAKE_IOS_BUILD` | `20A000` | 1–64 ASCII bytes; alphanumeric first, then letters/digits/dots/underscores/hyphens |
| `PEAR_FAKE_DARWIN` | `22.6.0` | Same numeric component syntax as the iOS version |

Absent or empty inputs select the defaults. These are compatibility descriptors,
not evidence of genuine iOS hardware, OS capabilities, or an Apple identity.
The synthetic vendor UUID preserves the existing bundle-and-model FNV algorithm;
it is stable for the same inputs, without reading host/Apple device identifiers
or storing an account token. `PEAR_DEVICE_PROFILE_SOURCE`,
`PEAR_DEVICE_PROFILE_BUNDLE`, and `PEAR_DEVICE_VENDOR_UUID` are launcher-managed
handoff fields, not user overrides.

This does **not** enable `PEAR_DEVICE_UI_DETAILS`, `PEAR_FORCE_TRAIT_IDIOM`,
`PEAR_DEVICE_UNAME`, `PEAR_DEVICE_KERNEL`, or `PEAR_SPOOF_OS_VERSION`; their
existing opt-in behavior is unchanged. Device/network opt-outs still apply.
Network identity headers share the profile and use an `iPad` UA token for a pad
profile, without changing the existing policy for app-supplied headers. A
malformed manually supplied managed snapshot skips profile-derived overrides
as a whole, not field-by-field defaults; unrelated compatibility hooks retain
their original opt-out behavior.

Default/load-command mode still accepts its previous permissive overrides, but
both modes now capture device values once: changing `environ` later is not a
live update. Restart to change a profile. Legacy text overrides have a 4095-byte
safety limit; longer values reject the snapshot rather than being truncated.
Managed bundle metadata is limited to 255 UTF-8 bytes without Unicode controls.

Headless verification (no game/window/screenshot required):

```sh
swift build
swift test
bash runtime/build.sh
python3 scripts/runtime-client-smoke.py .build/debug/PearSilicon
python3 scripts/device-profile-smoke.py .build/debug/PearSilicon
```

These tests use temporary data and headless child processes. Passing them does
not establish that a particular game starts, downloads content, or is playable.

---

## Storage location

PearSilicon groups its **managed** installed apps, runtime data, keymaps, ODR
packs, local keychain store, logs and work files under a selected root. The
default is `~/Library/Application Support/PearSilicon`. Storage relocation is
**experimental**: it copies that root to a destination folder, rebases installed
apps and records the new location. Settings and some existing macOS-container
data can remain outside it; this is not a guarantee that every app write or save
is confined to one disk.

External disks are an intended use case, but an actual external-volume move and
subsequent gameplay have not been validated end to end. Keep a separate backup,
close games and avoid concurrent installs/launches during a move. Test the copied
apps and saves before removing the old copy.

```sh
pearsilicon storage                        # show the current root and previous copy
pearsilicon storage move /Volumes/Games    # experimental copy to /Volumes/Games/PearSilicon
pearsilicon storage remove-previous        # delete the retained rollback copy
```

The same commands are available in **Settings → Storage location**.

How a move works:

1. Close games first. The move checks for running apps in the source library;
   this check does not serialize every storage operation across GUI/CLI processes.
2. The whole root is copied to a staging folder on the target volume. The old
   copy is never modified or deleted.
3. Each installed app's absolute compatibility paths (`LC_LOAD_DYLIB`,
   `LC_ID_DYLIB`, `LC_RPATH` entries pointing at the old root) are rewritten for
   the new root and the copy is re-signed with the same preparation mode it
   already had. The runtime version is not updated by a move.
4. Non-app regular-file sizes and installed-app counts are checked. These are
   **not content-hash checks**. The new root is then activated and recorded;
   failures before activation leave the old root selected.
5. The old root is kept as a rollback until `remove-previous` deletes it.

The migration uses a `.pear-storage-root` marker and refuses nonempty destination
folders rather than merging them. Root-availability checks catch some missing
paths, but do not establish that the original external volume is mounted at the
expected path in every case. Bookmarks are best-effort; a changed mount path is
not a guarantee that every installed binary path will be rebased automatically.

**Launch moved apps through PearSilicon.** Its launcher passes the selected root
through `PEAR_SUPPORT_ROOT`, `PEAR_HOME_DIR`, `PEAR_KEYCHAIN_DIR` and `PEAR_ODR_PATH`.
Opening an installed game directly from Finder does not infer that root and may
use default paths or lack the environment-injected runtime.

The launcher may reuse an existing macOS container if the selected root lacks
the app's `Documents`. Migration attempts to copy `Documents`, `Library` and
`tmp` from such containers into `Games/<id>` and leaves the container untouched;
permissions or existing destination files can make that step fail. Verify the
actual saves rather than assuming every app's data was migrated. Longer binary
path replacements can also require Command Line Tools (`install_name_tool`).

---

## Project build integration

### Option 1 — let the CLI build the project

```sh
pearsilicon build ~/Code/MyApp/MyApp.xcodeproj --scheme MyApp
# workspace:
pearsilicon build ~/Code/MyApp/MyApp.xcworkspace --scheme MyApp
```

This runs the project builder for `generic/platform=iOS` with code signing disabled
(PearSilicon signs the bundle itself), reads `BUILT_PRODUCTS_DIR` /
`FULL_PRODUCT_NAME` from the build settings, installs the product and launches
it. If no full development toolchain is selected it stops with the toolchain selector command to run
(see `pearsilicon doctor`). Options:

| Option | Default |
| --- | --- |
| `--scheme NAME` | required |
| `--configuration NAME` | `Debug` |
| `--destination DEST` | `generic/platform=iOS` |
| `--no-launch` | install only |
| `--keys` / `--no-keys`, `--log`, `--env` | as usual |

Derived data is kept under `Work/ProjectBuildData` in the selected storage root
(default: `~/Library/Application Support/PearSilicon/Work/ProjectBuildData`), so
rebuilds are incremental.

### Option 2 — keep the IDE Run action

Point the scheme's Run action at the PearSilicon binary and pass the built
product as an argument:

1. **Product → Scheme → Edit Scheme → Run**
2. **Executable:** *Other…* →
   `/Applications/PearSilicon.app/Contents/MacOS/PearSilicon`
3. **Arguments:** `run "$(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)" --log`
4. Set the destination to a **device** (not a simulator) before building.

The IDE expands the build settings in scheme arguments. The command installs the
just-built bundle, launches it and follows the log; when the app exits, the CLI
exits, so the Run session ends cleanly.

If the IDE insists on a simulator destination for a custom executable, use Option
1 (or a *Run Script* phase that calls `pearsilicon run …`) instead.

---

## Debugging

`debug` launches with a log file and touch tracing, then follows the log:

```sh
pearsilicon debug com.example.game
pearsilicon debug com.example.game --lldb
```

`--lldb` waits briefly and runs `lldb -p <pid>`; it does not enable debug signing.
Default installs are ad-hoc signed **without** `com.apple.security.get-task-allow`.
The installer writes a separate `Work/debug-entitlements.plist` for explicit
debug-signing workflows, but does not apply it automatically. Attaching depends
on the app's signature and macOS debugging permissions and can be denied.

The runtime also logs through `os_log` (subsystem `com.pearsilicon.runtime`):

```sh
pearsilicon logs com.example.game --system
# equivalent to:
log stream --style compact --predicate 'subsystem == "com.pearsilicon.runtime"'
```

See the [README diagnostics](../README.md#diagnostics) for common logging flags.
Opt-outs are component-specific; `PEAR_DISABLE` skips the main bootstrap, not
all independently initialized shims.

---

## Environment overrides

| Variable | Purpose |
| --- | --- |
| `PEARSILICON_APP` | Path to an `.app` or binary to use (wrapper and runtime lookup) |
| `PEARSILICON_RUNTIME` | Path to `libPearRuntime.dylib` to load |
| `--env KEY=VALUE` | Anything passed to the launched app (`PEAR_*`) |

`bin/pearsilicon` prefers a checkout's `.build/debug/PearSilicon`, then
`.build/release`, then an installed app that carries the CLI marker
(`Contents/Resources/pearsilicon-cli`) — an older app without the marker is
skipped so that it cannot open the GUI by accident.

---

## Files it touches

Default managed layout (a selected storage root replaces the top-level path):

```
~/Library/Application Support/PearSilicon/
  Applications/<bundleID>.app
  Keymaps/<bundleID>.json
  Logs/<bundleID>.log
  Logs/<bundleID>.host.log        (experimental environment-injection mode)
  Games/<bundleID>/Library/Cloud/key-values.plist
  ODR/<bundleID>/                 (drop ODR packs here)
  Runtime/LaunchLocks/<hashed-id>.lock
  Work/ProjectBuildData/          (pearsilicon build)
```

The GUI listens for `com.pearsilicon.libraryChanged` and refreshes its library
when the CLI installs or removes an app, so an open window stays in sync.
