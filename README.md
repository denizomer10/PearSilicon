<p align="center">
  <img src="logo.png" alt="PearSilicon" width="140">
</p>

<h1 align="center">PearSilicon</h1>

<p align="center">
  <strong>One library for iOS apps, Mac apps and Windows games on Apple silicon.</strong>
</p>

<p align="center">
  <a href="https://github.com/denizomer10/PearSilicon/releases"><img src="https://img.shields.io/github/v/release/denizomer10/PearSilicon?include_prereleases&label=release&style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" alt="MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%20·%20Apple%20silicon-lightgrey?style=flat-square" alt="macOS 26, Apple silicon">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <a href="https://discord.gg/yRVC5ZCyby"><img src="https://img.shields.io/badge/Discord-community-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="https://pearsilicon.pages.dev">Website</a> ·
  <a href="https://github.com/denizomer10/PearSilicon/releases">Releases</a> ·
  <a href="docs/CLI.md">CLI</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a> ·
  <a href="https://discord.gg/yRVC5ZCyby">Discord</a>
</p>

---

PearSilicon is a native macOS app that keeps iOS apps, Mac apps and Windows
games in one library and runs each of them the right way:

- **64-bit iOS apps** are prepared for Mac Catalyst and run on Apple's
  `/System/iOSSupport` frameworks, with [PearRuntime](https://github.com/denizomer10/PearRuntime)
  loaded inside the app for input, graphics and system-service compatibility.
  OpenGL ES games render through [PearANGLE](https://github.com/denizomer10/PearANGLE) on Metal.
- **32-bit iOS games** (`armv6`/`armv7`), which macOS cannot load, run on
  [PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine).
- **Mac apps** are imported as copies with their data redirected into the library.
- **Windows games** run in a private Wine prefix per game.

PearSilicon is not a virtual machine and ships no apps, games or Apple software.
Use it only with software you are entitled to run.

## Features

| Area | What you get |
| --- | --- |
| **iOS apps** | IPA and device `.app` import, automatic Mac Catalyst preparation, OpenGL ES on Metal, performance HUD, pointer lock, per-app compatibility profile |
| **32-bit iOS games** | detected and routed to PearLegacyEngine automatically, launched in a window carrying the game's own name and icon, free resizing and fullscreen |
| **Input** | keyboard, mouse and controller keymapper (tap, hold, joystick, swipe, mouse-look); Xbox, DualSense/DualShock, Switch Pro and other GameController pads; virtual gamepad for games with native controller support |
| **Windows games** | MetalSharp Wine by default (native arm64, no Rosetta), optional WineHQ builds, Steam support, installer detection |
| **Library** | iOS, Mac and Windows tabs, movable storage including external disks, one-file `.pearbackup` backups |
| **Updates** | in-app updater that verifies GitHub's SHA-256 digest and the build commit |
| **CLI** | `pearsilicon install`, `launch`, `doctor`, `analyze` and more ([docs/CLI.md](docs/CLI.md)) |
| **Diagnostics** | a [PearDebug](https://github.com/denizomer10/PearDebug) log session per launch, with an analyzer |

## Requirements

- An Apple silicon Mac with macOS 26 or later.
- The prebuilt app needs nothing else. Some preparation steps use `otool` and
  `install_name_tool` from the Command Line Tools.
- x86_64 Wine builds need Rosetta 2.
- Building from source needs Xcode with the macOS 26 SDK.

## Installation

1. Download `PearSilicon.zip` from the latest
   [release](https://github.com/denizomer10/PearSilicon/releases).
2. Unzip it and move `PearSilicon.app` to `/Applications`.
3. Open it. Builds are ad-hoc signed and not notarized, so the first launch may
   need **System Settings → Privacy & Security → Open Anyway**.

Every build is published as its own release with notes on its version, commit
and what was tested.

## Getting started

1. Pick **iOS Apps**, **Mac Apps** or **Wine Games** with the platform switch.
2. Click **+** or drop a package: an `.ipa` or device `.app`, a Mac `.app`, or a
   Windows game folder or `.exe`.
3. Select the entry to launch, stop, back up or reveal its data.
4. For touch-only iOS games, enable the keymapper in the **Keymap** tab and
   relaunch.

From the command line:

```sh
bin/pearsilicon install ~/Downloads/Game.ipa --launch
bin/pearsilicon launch com.example.game --log
bin/pearsilicon doctor
```

## iOS apps

**Preparation.** The installer works on a copy: it normalizes `Info.plist`,
thins universal binaries to arm64, marks the Mach-O for Mac Catalyst, adds the
runtime and the ANGLE libraries, and re-signs. Installed apps receive a new
runtime automatically after a PearSilicon update.

**Automatic compatibility.** Older scene-less apps built with an iOS SDK before
15 need a window bridge and synthesized touches. PearSilicon detects them from
`Info.plist` and applies both; the **Compatibility** card shows what is active
and offers **Use automatic** when a manual override is stored.

**Controllers and keymapper.** The keymapper is opt-in per app. The Keymap
editor records keyboard or controller bindings; **R STICK** drives an analog
camera with dead zone, response curve and sensitivity. Games with their own
controller support (Unreal and Unity titles) receive the pad directly, and the
pad-to-touch fallback switches itself off for them. **Keyboard Mouse to Gamepad
Inputs** gives such games a virtual controller driven by keyboard and mouse.

## 32-bit iOS games

32-bit games are tagged **32-bit** in the library and launched on
PearLegacyEngine. The installed app is kept byte-for-byte as shipped, with no
patching or re-signing; saves live in `Games/<bundle-id>`. Keyboard keymaps and
the **Performance HUD** work for these games too.

Release builds of PearSilicon include the engine. For a source build, stage it
with:

```sh
./scripts/setup-legacy-engine.sh            # builds PearLegacyEngine + PearLegacyJIT into build/PearLegacyEngine
./scripts/setup-legacy-engine.sh --check    # only reports the checkouts it would use
```

`PEARSILICON_LEGACY_ENGINE` points the app at another engine build.

## Windows games

Each game lives in `wine-apps/<id>/` with `Payload`, `Data` and a private
`Prefix`. Host drive mappings are removed; a `g:` drive exposes only the game.

- **MetalSharp Wine** ([metalsharp/MetalSharp-Wine](https://github.com/metalsharp/MetalSharp-Wine))
  is the default engine: native arm64 Wine with FEX, Direct3D on Metal, DXVK and
  VKD3D. It is downloaded the first time you add a Windows game, checked against
  GitHub's SHA-256 and kept with its original Developer ID signature.
- **WineHQ** Staging and Development builds (x86_64, Rosetta 2) and local or
  community runtimes can be added in **Settings → Wine**.
- **Installers** are detected by name and markers. PearSilicon snapshots the
  private C: drive, waits for setup to finish and offers the installed
  executable.
- **Steam** starts through `C:\PearSiliconSteam` to avoid a MetalSharp launcher
  rule that crashes Steam's browser.

Kernel anti-cheat and kernel drivers are not supported.

## Data and backups

```text
~/Library/Application Support/PearSilicon/
  ios-apps/   mac-apps/   wine-apps/
  Engines/    Keymaps/    Logs/    ODR/    Keychain/    Work/
```

- **Storage** can be moved to another disk from **Settings → General → Move
  Storage…**; apps, saves, engines, ODR and keychain data move together.
- **iOS data** lives in `Games/<bundle-id>` (`Documents`, `Library`, `tmp`);
  extra On-Demand Resources go in `ODR/<bundle-id>/`.
- **Backups** are one `.pearbackup` file per entry, integrity-checked but
  **not encrypted** — treat them as sensitive.
- **Uninstall** offers *Keep Saves* or *Delete Everything*. **Clean start**
  resets the current library after confirmation and never touches files
  outside it.
- **Mac apps** get redirected home, caches and preferences, but they are not
  sandboxed and can still write absolute paths.

## Building from source

```sh
git clone --recurse-submodules https://github.com/denizomer10/PearSilicon.git
cd PearSilicon
bash scripts/build-angle-metal.sh --sync     # PearANGLE for Mac Catalyst (first time)
./scripts/setup-legacy-engine.sh             # optional: 32-bit engine
./scripts/build-app.sh release               # build/PearSilicon.app
./scripts/make-zip.sh release                # build/PearSilicon.zip
```

`build-app.sh` also places every license text, notice and source pointer the
bundled components require into the app and runs `scripts/verify-licenses.sh`;
the build fails when one is missing.

## Testing

```sh
swift test
bash scripts/test-angle-exclusive.sh
python3 scripts/filesystem-smoke.py
python3 scripts/keychain-smoke.py --active-interpose
```

`swift test` covers installer atomicity, archive admission, storage migration,
backup and restore, Mac and Wine launch planning and update parsing. Graphics
and external-disk tests are described in [docs/TESTING.md](docs/TESTING.md).
A successful launch is not a compatibility claim for a game.

## Architecture

| Project | Role | License |
| --- | --- | --- |
| **PearSilicon** | SwiftUI app: library, installer, launcher, updater, CLI | MIT |
| [PearRuntime](https://github.com/denizomer10/PearRuntime) (`runtime/`) | in-process compatibility layer for arm64 iOS apps | MIT |
| [PearANGLE](https://github.com/denizomer10/PearANGLE) (`runtime/third_party/angle`) | OpenGL ES on Metal, fork of ANGLE | BSD-3-Clause |
| [PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine) | 32-bit iOS engine, fork of touchHLE | MPL-2.0 source, GPL-3.0-or-later binary |
| [PearLegacyJIT](https://github.com/denizomer10/PearLegacyJIT) | ARMv7 recompiler, fork of Dynarmic | 0BSD |
| [PearDebug](https://github.com/denizomer10/PearDebug) (`Vendor/PearDebug`) | logging, analysis and probes | MIT |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the execution model and
[docs/CLI.md](docs/CLI.md) for commands, diagnostics and environment variables.

## Limitations

- 64-bit iOS apps depend on Apple's Mac Catalyst and iOSSupport stack;
  compatibility varies by app.
- The 32-bit engine's compatibility is narrower: one release may run some games
  well and crash in others.
- Wine cannot run kernel anti-cheat. Mac apps are not sandboxed.
- Updates verify bytes against GitHub's metadata, which is not a publisher
  signature; builds are not notarized. Updating is refused while a game runs.

## Community

Questions, setup help and compatibility reports are welcome on
[Discord](https://discord.gg/yRVC5ZCyby). When reporting a problem, include the
app name and version, the macOS version and the output of `pearsilicon doctor`.

## License

PearSilicon is MIT licensed — see [LICENSE](LICENSE).
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists every component the app
ships, its license and where its source is; the same files are inside every
`PearSilicon.app` under `Contents/Resources/Licenses`. Apps you install keep
their own licenses.
