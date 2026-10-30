<p align="center">
  <img src="logo.png" alt="PearSilicon" width="160">
</p>

<h1 align="center">PearSilicon</h1>

<p align="center">
  <strong>Run compatible iOS apps on Apple silicon Macs.</strong><br>
  Mac Catalyst-based app preparation, runtime shims and input mapping.
</p>

<p align="center">
  <a href="https://github.com/denizomer10/PearSilicon/releases"><img src="https://img.shields.io/github/v/release/denizomer10/PearSilicon?include_prereleases&label=release&style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20arm64-lightgrey?style=flat-square" alt="macOS arm64">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <a href="https://discord.gg/yRVC5ZCyby"><img src="https://img.shields.io/badge/Discord-community-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="https://pearsilicon.pages.dev">Website</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/denizomer10/PearSilicon/releases/tag/development-beta">Download</a>
  &nbsp;·&nbsp;
  <a href="docs/CLI.md">CLI reference</a>
  &nbsp;·&nbsp;
  <a href="docs/ARCHITECTURE.md">Architecture</a>
  &nbsp;·&nbsp;
  <a href="#community">Community</a>
  &nbsp;·&nbsp;
  <a href="https://discord.gg/yRVC5ZCyby">Discord</a>
</p>

---

PearSilicon prepares compatible arm64 iOS applications to run on macOS using
Apple's Mac Catalyst and `/System/iOSSupport` frameworks. Its in-process runtime
adds compatibility shims and optional keyboard/mouse mapping on top of that
Apple-provided environment. It is not a standalone reimplementation of iOS or
UIKit. Use it only with applications you are authorized to run.

| | |
| :--- | :--- |
| **Install** | Drop an `.ipa` archive or an iOS device `.app` bundle onto the window |
| **Input** | Opt-in keymapper, multi-touch synthesis, Metal HUD and pointer-lock controls |
| **Organise** | Managed app/data folder with experimental storage relocation |
| **Compatibility** | Runtime shims for keychain, graphics setup, local cloud surfaces, device identity and more |

## Release channels

This README describes current development source, which can be newer than a
published download. Choose an artifact by its release notes rather than assuming
that every feature on this page is included in every version.

The recommended download is the
**[development beta](https://github.com/denizomer10/PearSilicon/releases/tag/development-beta)**,
a prerelease updated in place. Its notes identify the artifact's last tested
commit and the exact scope of those checks. This is not a stable-release promise
or a verified catalog of playable games.

IPA/`.app` package drop handling, host/environment injection and storage
relocation are current development features. Consult the beta's artifact notes: source changes
can be newer than the published ZIP.

## Features

- Install IPA archives and iOS device `.app` bundles through the GUI or CLI.
- Keymapper, opt-in per app and off by default: tap, hold, joystick, mouse-look
  and swipe.
- Multi-touch event synthesis through the platform's touch machinery.
- Per-app Metal HUD and pointer-lock controls.
- Mandatory repeat-rate protection in the keymapper.
- Local compatibility shims for keychain, screen, Metal, OpenGL, cloud, device,
  paths, on-demand resources, consent and networking.
- MIT-licensed.

## Requirements

- macOS 26 or later
- an arm64 Mac
- **Prebuilt app:** opening the GUI does not require Xcode, Swift, Homebrew or a
  source checkout. The release bundle includes PearSilicon's runtime libraries;
  Apple's compatibility frameworks are supplied by macOS.
- **App preparation and relocation:** some paths invoke `otool` and
  `install_name_tool` and require Apple's Command Line Tools. Installation is
  therefore not guaranteed to be tool-free on a clean Mac.
- **Source/project builds:** select a full Xcode toolchain. The runtime-only
  build can use Command Line Tools with a macOS SDK containing iOSSupport.

Current development builds are ad-hoc signed, not Developer ID-signed or
notarized, so downloaded copies may require explicit Gatekeeper approval.
`pearsilicon doctor` reports build-tool availability, runtime location and
library status; it does not certify game compatibility.

## Install and run

1. Download the [development beta](https://github.com/denizomer10/PearSilicon/releases/tag/development-beta),
   or build the app yourself. The beta is updated in place; its
   notes identify the last tested commit and the scope of those checks.
2. Unzip the download, move `PearSilicon.app` to `/Applications` and open it.
3. Use the **Install** button to select a prepared `.ipa` or an iOS device
   `.app` bundle, wait for installation, and launch it. Development builds also
   accept those packages as drops onto the window. `pearsilicon install
   <path-to-app>` remains available for scripts.

The same installer and launcher are available from a terminal:

```sh
bin/pearsilicon install ~/Downloads/App.app --launch
bin/pearsilicon launch com.example.app --log
bin/pearsilicon doctor
```

After installing the app, link the command once:

```sh
sudo ln -sf /Applications/PearSilicon.app/Contents/MacOS/PearSilicon \
               /usr/local/bin/pearsilicon
```

Full command reference: [docs/CLI.md](docs/CLI.md).

Before installation, the full bundle is checked for supported ARM64/platform
metadata and encrypted or malformed Mach-O images. CRC-damaged archives are
rejected. Failed staged preparation/signing leaves an existing installation in
place. This does not decrypt code or guarantee working gameplay.

For read-only checks use `pearsilicon validate <App.app|Mach-O>`; see
[startup diagnostics](docs/STARTUP_DIAGNOSTICS.md), including the limits of the
Genshin/Telemetry SIGILL investigation. Previously prepared copies whose
`cryptid` was cleared need a fresh verified input; they cannot be repaired by
merely updating the launcher.

## Validation

PearSilicon is tested in layers rather than by a single "game works" claim:

```sh
swift test
python3 scripts/filesystem-smoke.py
python3 scripts/keychain-smoke.py --active-interpose
python3 scripts/runtime-client-smoke.py <path-to-PearSilicon-executable>
python3 scripts/e2e-games.py --cli <path-to-PearSilicon-executable> --stress
```

`swift test` covers installer atomicity, archive admission, stopped-app leases,
storage migration and GUI import routing/FIFO/cancellation. The runtime suites
use temporary data and exercise permissions, keychain generation, IPC deadlines
and cloud-identity compatibility. The background app check launches only apps it
started, skips already-running apps, and verifies process liveness, clean
shutdown, duplicate-launch rejection and the absence of runtime signal/exception
markers. It does not verify gameplay, input coordinates, downloads or account
flows. See [Testing and validation](docs/TESTING.md) for the exact scope and
manual checklist.

## Build

```sh
./scripts/build-app.sh          # app + runtime (full toolchain)
open build/PearSilicon.app

./scripts/make-zip.sh           # build/PearSilicon.zip

swift build
swift test
./runtime/build.sh              # runtime dylib only (Command Line Tools work)

# Package elsewhere without replacing an app currently open from build/:
PEAR_BUILD_DIR=.build/package-check ./scripts/make-zip.sh
```

## How it works

1. The installer works on a copy: it normalizes `Info.plist`, thins supported
   universal binaries to `arm64`, patches Mach-O platform metadata to
   **Mac Catalyst (6)**, adds compatibility dependencies, and re-signs the copy.
   The input IPA is not changed; the installed app is modified.
2. By default, `LC_LOAD_DYLIB` loads `libPearRuntime.dylib` **inside the app's
   process**. Experimental `--env-injection` uses launcher-provided
   `DYLD_INSERT_LIBRARIES` to load the **same full runtime**, not selected shims.
3. The launcher uses Apple's `/System/iOSSupport` frameworks, including UIKit.
   Normal launches use LaunchServices; `--background` avoids requesting focus.
4. Runtime hooks adjust specific API behavior and, when enabled, map input.
   They do not replace UIKit, the kernel, or the app's Metal renderer.

The experimental [host-service split](docs/CLI.md#experimental-host-service-split)
moves only local key-value backing state and static device-profile configuration
to a separate process. UIKit, input, rendering, audio, device API hooks and
keychain handling remain in-process. This is not kernel-level iOS emulation or
a security sandbox for untrusted apps.

See [Architecture](docs/ARCHITECTURE.md) for the execution model, its limited
Wine/Proton analogy and the scope of comparisons with PlayCover. No controlled
benchmarks currently establish lower memory/CPU use, higher FPS or lower latency
than PlayCover. A successful launch check is not a gameplay compatibility result.

### Compatibility shims

| Shim | Purpose |
| --- | --- |
| `KeychainShim` | local keychain store and software key generation |
| `ScreenShim` | make `UIScreen` follow the key window |
| `MetalLayerShim` | fix existing Metal device/layer/drawable and texture setup; not a replacement renderer |
| `GLShim` | OpenGL ES entry point and drawable fitting |
| `CredentialShim` | safe client-credential handling |
| `CloudShim` | local-only key-value, ubiquity, CloudKit and GameKit surface |
| `DeviceShim` | coherent device identity |
| `PathShim` | redirect supported home, group-container and temporary-directory APIs; not filesystem isolation |
| `PointerLockShim` | per-app pointer-lock control |
| `ODRShim` | resolve packaged and user-supplied on-demand resources |
| `ServicesShim` | audio-session, haptics, store availability, remote-notification and background-task surfaces |
| `ConsentShim` | local consent entry points |
| `NetworkShim` | iOS-style request identity and HTTP/2 |
| `BeepShim` | silence the alert beep for unhandled keys |
| `libswiftUIKit` | source-built Swift UIKit compatibility overlay |

Opt-outs are shim-specific, for example `PEAR_NO_METAL_FIX=1` and
`PEAR_NO_CLOUD_SHIM=1`. Not every component has a matching `PEAR_NO_*` switch;
consult its source before using an override.

## App data

The default runtime data location is:

```
~/Library/Application Support/PearSilicon/Games/<bundle-id>/
  Documents/  Library/  Library/Caches/  Library/Group Containers/  tmp/
```

The launcher supplies `PEAR_HOME_DIR` for the app's data directory and
`PEAR_SUPPORT_ROOT`, `PEAR_KEYCHAIN_DIR` and `PEAR_ODR_PATH` for other managed
paths. It may reuse an existing macOS container when that contains the app's
previous data. `PEAR_HOME_DIR` alone does not move the library or all other stores.

Experimental relocation is available in **Settings → Storage location** and
`pearsilicon storage move <folder>`. Launch moved games through PearSilicon:
direct Finder launches do not infer the selected storage root. Back up saves,
keep the previous copy and test the destination before removing it. External-disk
migration has not been validated end to end; see
[storage location](docs/CLI.md#storage-location) for checks and limitations.

Some apps keep content in On-Demand Resources that their package does not
carry. Put those bundles in the per-app ODR folder:

```
~/Library/Application Support/PearSilicon/ODR/<bundle-id>/
```

The folder accepts flat bundle files or a copy of the Addressables tree with a
`BuildTarget/` subdirectory. At launch the runtime merges these with packaged
bundles using symlinks where possible, falling back to copying if symlink creation
fails. Override the folder with `PEAR_ODR_PATH=<dir>`.

## Per-app options

- **Metal HUD** — launches with `MTL_HUD_ENABLED=1`.
- **Pointer lock** — on by default; disable it if the cursor gets trapped.
- **iOS-like container** — part of the base environment and applied to every
  launch; there is no per-app switch.

Repeat-rate protection is always on and not configurable.

## Keymapper

The keymapper is opt-in and off by default. It can record a physical key, add a
tap, hold, joystick, mouse-look or swipe binding, and clear all bindings. Saved
binding edits can reload while the keymapper is active. Enabling or disabling
the keymapper takes effect on the next launch.

A keymap is a JSON file per app. This complete format includes the metadata and
binding IDs required by GUI/CLI import; adapt the bundle ID and coordinates to
your app, or generate a starter map with `pearsilicon keymap <id> --generate`:

```json
{
  "version": 1,
  "bundleID": "com.example.app",
  "engine": "unknown",
  "isAutoGenerated": false,
  "createdAt": "2026-10-30T00:00:00Z",
  "bindings": [
    {
      "id": "8C2A9D40-6A89-4BFE-B3F7-90F7C3A26D91",
      "key": "wasd",
      "action": { "joystick": { "center": { "x": 0.14, "y": 0.72 }, "radius": 0.1 } }
    },
    {
      "id": "533090C0-D5BF-44C5-921F-FA14154260CB",
      "key": "space",
      "action": { "tap": { "_0": { "x": 0.9, "y": 0.82 } } }
    }
  ]
}
```

## Diagnostics

- `PEAR_LOG_FILE=<path>` writes the runtime log to a file.
- Launcher-managed compatibility launches enable an iOS-like filesystem view
  through hooks and request a permissive macOS sandbox profile. This is not iOS
  kernel emulation or secure per-app isolation.
- `PEAR_ODR_PATH=<dir>` overrides the per-app folder for On-Demand Resources.
- `PEAR_DEBUG_SERVICES=1` logs the installed service surfaces.
- `PEAR_DEBUG_TOUCH`, `PEAR_DEBUG_SCREEN`, `PEAR_DEBUG_GL` and
  `PEAR_DEBUG_CLOUD` add logging.
- Supported `PEAR_NO_*` variables opt out of specific hooks; names and behavior vary.
- `PEAR_DISABLE=1` skips the main runtime bootstrap, including the keymapper;
  separate shim initializers can still run. It is not a global no-hooks mode.
- `pearsilicon doctor` reports build tools, runtime location and library status.

## Scope and licensing

PearSilicon's source is MIT-licensed. It depends on Apple frameworks supplied by
macOS; those frameworks and the apps you install retain their respective licenses.
The project is intended for interoperability and educational use with apps you
are authorized to run. It does not provide app licenses, accounts or iOS firmware.

## Community

Questions, setup help, compatibility reports and development discussion live on
Discord:

**[Join the PearSilicon Discord →](https://discord.gg/yRVC5ZCyby)**

When reporting a problem, please include the app name and version, your macOS
version and the output of `pearsilicon doctor` — that makes it much easier to
reproduce and fix.

## License

MIT — see [LICENSE](LICENSE).
