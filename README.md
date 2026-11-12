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
  <img src="https://img.shields.io/badge/platform-macOS%20arm64-lightgrey?style=flat-square" alt="macOS arm64">
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

PearSilicon prepares compatible arm64 iOS apps to run through Apple’s Mac
Catalyst and `/System/iOSSupport` frameworks, runs legacy 32-bit (`armv7` /
`armv6`) iOS games via the companion **[PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine)**
runtime, manages native Mac apps, and runs Windows games in isolated Wine
prefixes. An in-process runtime adds targeted compatibility shims and optional
keyboard, mouse and controller mapping.

It is **not** a full OS virtual machine. Use it only with apps and games you are
authorized to run.

## Highlights

| Platform | What it does |
| --- | --- |
| **iOS Apps (64-bit & 32-bit)** | IPA / device `.app` import; Catalyst runtime shims, performance HUD, pointer lock and opt-in keymapper for 64-bit apps, plus automatic **[PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine)** execution for 32-bit iOS games |
| **Mac Apps** | Copy-only `.app` import with redirected data, launched natively |
| **Wine Games** | Per-game prefixes, private data, verified engines, DXVK or DXMT graphics |
| **Library** | iOS, Mac and Wine tabs; movable library; per-entry `.pearbackup` backups |
| **Input** | GameController pads, controller/keyboard keymapper, analog right-stick camera |
| **Updates** | Explicit **Check for Updates**, staged verification, development builds |

- **iOS (64-bit):** installs an authorized IPA or `.app`, patches the copy to Mac Catalyst,
  re-signs it, and loads `libPearRuntime.dylib` inside the app process.
- **iOS (32-bit via PearLegacyEngine):** automatically detects 32-bit ARM (`armv7` / `armv6`)
  IPA and `.app` packages (such as *Miku Flick*), installs them cleanly into the
  unified iOS library, and launches them in a game-named macOS `.app` host powered
  by **[PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine)** with
  SwiftUI controls for free window resizing, fullscreen mode, and save data.
- **Controllers:** Xbox, DualSense/DualShock, Switch Pro and other macOS
  GameController pads are discovered early; non-whitelisted identities are
  normalized, prepared apps receive capability keys, and the keymapper can drive
  touch-only games from pad buttons and sticks.
- **Wine:** self-contained engines, a private prefix per game, a relative `g:`
  drive exposing only the game folder, and no host root (`z:`) mapping.
- **Graphics:** MoltenVK + DXVK 1.10.3 for D3D11, or DXMT on Wine builds that
  export winemac’s Metal view API. Both components are pinned and SHA-256
  verified.
- **Updates:** development builds are published as separate prereleases. If
  GitHub’s unauthenticated API is rate-limited, the updater falls back to the
  public release feed while still checking the asset digest and release commit.

## Requirements

- macOS 26 or later on Apple silicon.
- **Prebuilt app:** no Xcode, Swift or Homebrew required.
- **Source builds:** full Xcode with the macOS 26 SDK.
- Some preparation paths use `otool` and `install_name_tool`; Command Line Tools
  may be required.
- x86_64 Wine engines require Rosetta 2.
- Builds are ad-hoc signed and not notarized; Gatekeeper may ask for approval.

## Install

Download the newest development build from
**[Releases](https://github.com/denizomer10/PearSilicon/releases)**, unzip it,
move `PearSilicon.app` to `/Applications`, and open it.

Each development build is its own prerelease; release notes identify its version,
tested commit and scope. Release notes are written in English by default. If macOS
blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**
or right-click → **Open**.

### Build from source

```sh
git clone --recurse-submodules https://github.com/denizomer10/PearSilicon.git
# existing checkout: git submodule update --init --recursive
./scripts/build-app.sh release     # app + runtime
open build/PearSilicon.app

./scripts/make-zip.sh release      # build/PearSilicon.zip
swift test                         # test suite
./runtime/build.sh                 # PearRuntime only (submodule)
```

## Quick start

1. Choose **iOS Apps**, **Mac Apps** or **Wine Games** with the platform switch.
2. Click **+** or drop a package:
   - iOS: `.ipa` or iOS device `.app`
   - Mac: native `.app`
   - Wine: game folder or `.exe`, after installing an engine in
     **Settings → Wine**
3. Select the entry to launch, stop, back up or reveal its data.
4. For iOS apps, enable the keymapper in the **Keymap** tab if needed, then
   relaunch.

CLI:

```sh
bin/pearsilicon install ~/Downloads/App.app --launch
bin/pearsilicon launch com.example.app --log
bin/pearsilicon doctor
```

Optional command symlink:

```sh
sudo ln -sf /Applications/PearSilicon.app/Contents/MacOS/PearSilicon \
               /usr/local/bin/pearsilicon
```

Full command reference: [docs/CLI.md](docs/CLI.md).

## 32-bit iOS apps (PearLegacyEngine)

Apps built before iOS 11 (armv6/armv7) cannot be loaded by macOS at all, so
PearSilicon runs them as guest code inside
[PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine), a 32-bit
iOS compatibility layer built on ANGLE/Metal. Install flow is unchanged: pick the
`.ipa`, nothing else. Such apps are tagged **32-bit** in the library and show
`Runtime: PearLegacyEngine (32-bit iOS)` in the detail view.

One-time engine setup — download the release and place it where PearSilicon
looks for it:

```sh
curl -L -o /tmp/ple.tar.gz \
  https://github.com/denizomer10/PearLegacyEngine/releases/latest/download/PearLegacyEngine-0.7.2-macos-arm64.tar.gz
mkdir -p "$HOME/Library/Application Support/PearSilicon"
tar -xzf /tmp/ple.tar.gz -C "$HOME/Library/Application Support/PearSilicon"
```

The archive extracts as `PearLegacyEngine/`, which is the first location
searched. In a source checkout the engine is also found next to the working
directory, and `PEAR_LEGACY_ENGINE_HOME=/path/to/PearLegacyEngine` overrides
everything. Requirements: Apple Silicon, macOS 26 or later.

When building from source, stage the engine with its Metal-backed ANGLE runtime
instead of downloading it:

```sh
./scripts/setup-legacy-engine.sh            # builds PearLegacyEngine + PearLegacyJIT, stages build/PearLegacyEngine
./scripts/setup-legacy-engine.sh --check    # only report the resolved checkouts and pins
```

`scripts/build-app.sh release` picks that directory up and bundles it into the
app. Pinned revisions and licenses are listed in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Unlike 64-bit apps, the installed `.app` is kept byte-for-byte as shipped — no
platform patch, runtime injection or re-signing — and each app keeps its guest
storage in `Games/<bundleID>`, so saves stay with the library.

## Controllers and keymapper

The keymapper is **opt-in per iOS app** and off by default. Supported actions are
tap, hold, joystick, mouse-look and swipe.

- The Keymap editor has a **Keyboard / Controller** switch. Controller bindings
  can be recorded by pressing A/B/X/Y, shoulders, triggers, D-pad,
  MENU/OPTIONS or a stick, or selected from a menu.
- **L STICK** drives a joystick binding; **R STICK** drives an analog camera
  (60 Hz, dead zone, response curve and adjustable sensitivity).
- If no controller bindings exist, a compatibility fallback maps the standard pad
  to the keyboard keymap. Mapped keyboard events are consumed to suppress the
  system key beep.
- Games with their own controller support (Unreal and Unity titles such as
  GTA: Vice City – Definitive Edition and Genshin Impact) get the pad directly.
  PearRuntime 0.8 no longer re-posts a "controller connected" event that these
  engines treated as a second player. Once a game shows that it drives
  controllers itself, the automatic pad-to-touch fallback turns off, so touch
  input no longer pulls the game back to touch mode. Explicit controller
  bindings in the Keymap editor still apply.
- **Keyboard Mouse to Gamepad Inputs** is a separate per-app toggle for games
  with native controller support. The game receives a hidden virtual controller;
  every A/B/X/Y, shoulder, trigger, D-pad, MENU/OPTIONS and stick control can be
  rebound to a key or mouse button, along with the left-stick keys. Click the
  game to capture the mouse and Escape releases it. Mouse sensitivity and an
  invert-vertical-look switch are included. This mode does not use the touch
  keymapper or native pointer lock.

Configure bindings in the in-app **Keymap** tab.

Keyboard keymaps apply to **32-bit iOS games too**. PearSilicon passes the
active keymap to PearLegacyEngine through `PEAR_KEYMAP`, and the engine
synthesises real touches from it (`tap`, `hold`, `swipe` and a dead-zoned
`joystick`), so touch-only legacy titles such as Miku Flick are fully playable
from the keyboard. Bindings with `source: "controller"` stay on the
GameController bridge and are ignored by the engine.

### Performance HUD on 32-bit titles

The **Performance HUD (FPS)** switch in a 32-bit app's settings sets
`PEAR_FPS_HUD=1`, which draws a frame-rate overlay with the engine's own
OpenGL ES renderer. Metal's `MTL_HUD_ENABLED` cannot apply here because these
titles never touch Metal, so the engine draws an equivalent overlay and logs the
same numbers to the app log.

## Automatic compatibility

Older scene-less apps built with an iOS SDK before 15 need a window re-attach
and synthesized touches to receive mouse input. PearSilicon detects this per
game from its `Info.plist` (no scene manifest plus `DTSDKName` major below 15)
and applies the bridges automatically — there is nothing to configure.

The **Compatibility** card on a game's detail page shows the detected profile
and the effective *Window bridge* and *Mouse→touch* state. Existing manual
values are preserved but hidden; when an override is stored, the card offers
**Use automatic**. Automation for scripted setups is available from the CLI:

```sh
pearsilicon compat com.example.game
pearsilicon legacy com.example.game auto
pearsilicon mousetouch com.example.game off
```

## Wine, engines and graphics

Imported games live under `wine-apps/<id>/` with `Payload`, `Data` and `Prefix`.
The prefix is private to the game; absolute host drive mappings are removed.

- **MetalSharp Wine is the default engine**
  ([metalsharp/MetalSharp-Wine](https://github.com/metalsharp/MetalSharp-Wine)):
  native arm64 Wine with FEX for 32- and 64-bit Windows programs, Direct3D on
  Metal, DXVK and VKD3D, no Rosetta. The first time you add a Windows game,
  PearSilicon downloads the signed arm64 release, checks GitHub's SHA-256 and
  installs it, with progress at the bottom-left of the window. No trip to
  Settings is needed.
- **Optional WineHQ builds**: WineHQ Staging and Development (x86_64, need
  Rosetta 2) can be installed from **Settings → Wine**. If a game stops right
  after starting, its detail pane offers the next installed engine.
- **Steam** on MetalSharp starts through `C:\PearSiliconSteam`, a link to the
  Steam folder. MetalSharp's launcher rule for `\Steam\bin\cef\` otherwise
  crashes Steam's browser (StorageService). Steam's files stay where they are.
- Or register a local runtime in **Settings → Wine**.
- Remove a registered engine from Settings; game prefixes and saves are kept.
- Community engines: paste a GitHub repository URL. The newest release archive
  is resolved automatically; if there is no release, the source ZIP is used.
  No manual hash is required; GitHub’s digest is checked when published.
- **DXVK** is pinned to 1.10.3 (Gcenx macOS build) and mirrored into the selected
  game’s prefix; Wine’s files are restored when the backend changes.
- **DXMT** requires a Wine build that exports winemac’s Metal view symbols.
  Automatic Gcenx builds hide them, so the app refuses DXMT there instead of
  opening a black window.

Wine is not a Windows VM. Kernel anti-cheat and kernel drivers are unsupported.

## Updates

**Settings → Updates** has a single **Check for Updates** button and follows the
development channel; there is no Stable selector. Each development build is a
separate prerelease.

The updater verifies the downloaded asset against GitHub’s SHA-256 digest, checks
the embedded `PearBuildCommit` against the release tag, and re-checks the release
before staging. If the GitHub API returns 403/429, it reconstructs the tag,
commit and digest from the public release feed and pages.

## Data and backups

Default support root:

```text
~/Library/Application Support/PearSilicon/
  ios-apps/   mac-apps/   wine-apps/
  Engines/    Keymaps/    Logs/    ODR/    Keychain/    Work/
```

- **Backups:** one `.pearbackup` file per entry, including saves, keychain data,
  ODR and Wine prefixes. Backups are uncompressed, integrity-checked and **not
  encrypted**; treat them as sensitive.
- **Storage:** the library can be moved to another disk from
  **Settings → General → Move Storage…**.
- **iOS data:** `Games/<bundle-id>/Documents`, `Library`, `Library/Caches`,
  `Library/Group Containers` and `tmp`.
- **ODR:** put additional On-Demand Resources in `ODR/<bundle-id>/`.
- **Mac apps:** home, caches, preferences and temp are redirected into the
  entry; absolute host paths remain reachable and no sandbox is claimed.

## Architecture

1. The installer works on a copy: normalizes `Info.plist`, thins universal
   binaries to arm64, sets the Mach-O platform to Mac Catalyst, adds runtime
   dependencies and re-signs.
2. The runtime loads inside the app process. Apple’s `/System/iOSSupport`
   frameworks provide UIKit; the runtime adjusts specific APIs rather than
   replacing UIKit or Metal.
3. Optional shims cover keychain, screen, Metal layer setup, OpenGL ES,
   credentials, cloud surfaces, device identity, paths, pointer lock, ODR,
   audio/haptics, consent, networking and unhandled-key beeps.
4. Wine entries run as direct native processes; no nested sandbox or VM.

PearSilicon is split into separate projects:

| Project | Role |
|---|---|
| [PearRuntime](https://github.com/denizomer10/PearRuntime) | Modular compatibility layer for modern arm64 iOS apps (`runtime/`, git submodule) |
| [PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine) | 32-bit iOS engine |
| [PearDebug](https://github.com/denizomer10/PearDebug) | Log sessions, log analysis and engine probes (`Vendor/PearDebug`, git submodule) |

After a PearSilicon update, installed iOS apps get the new runtime
automatically in the background (progress in the bottom-left of the window);
only iOS apps wait until it finishes.

Every launch writes a PearDebug log session (the previous run is kept as
`<id>….1.log`). `pearsilicon analyze <app>` runs PearDebug's analyzer on the newest log.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the execution model and
[docs/CLI.md](docs/CLI.md) for diagnostics and environment variables.

## Validation

```sh
swift test
python3 scripts/filesystem-smoke.py
python3 scripts/keychain-smoke.py --active-interpose
python3 scripts/runtime-client-smoke.py build/PearSilicon.app/Contents/MacOS/PearSilicon
```

`swift test` covers installer atomicity, archive admission, storage migration,
GUI import routing, portable-library scanning, backup/restore, native Mac launch,
Wine launch planning and update parsing. Optional graphics and external-disk
tests are documented in [docs/TESTING.md](docs/TESTING.md).

A successful launch is not a gameplay-compatibility result. No controlled
benchmark establishes a performance advantage over PlayCover.

## Limitations

- Compatible 64-bit iOS apps still depend on Apple’s Catalyst/iOSSupport stack;
  32-bit apps instead need the PearLegacyEngine bundle installed separately
  (see above).
- The 32-bit engine is Apple Silicon only and needs macOS 26 or later, and its
  app compatibility is narrower than the 64-bit path — one engine release may
  run some games well and crash in others.
- Compatibility varies by app; check release notes rather than assuming a feature
  or game works.
- Mac apps are not sandboxed; Wine cannot run kernel anti-cheat.
- Genshin Impact does not expose a native Controller option on Mac.
- Release digests verify bytes against GitHub metadata; they are not a publisher
  signature. Builds are not notarized.
- Update replacement is refused while a game is running.
- Backups are unencrypted and may contain credentials.

## Community

Questions, setup help and compatibility reports: join the
**[PearSilicon Discord](https://discord.gg/yRVC5ZCyby)**.

When reporting a problem, include the app name/version, macOS version and the
output of `pearsilicon doctor`.

## License

MIT — see [LICENSE](LICENSE). Apple frameworks and installed apps retain their own
licenses. PearSilicon does not provide app licenses, accounts or iOS firmware.

### Signed MetalSharp runtime

The MetalSharp install uses the signed `MetalSharp-Wine-<version>-arm64.zip`
release asset. The installer verifies its SHA-256, checks archive paths and
links before extraction, and verifies the app signature.
`Runtime/MetalSharp-Wine.app` stays intact, keeping the original Developer ID
signature and the cross-architecture entitlement 32-bit programs need. No
upstream app is re-signed. PearSilicon applies its MetalSharp defaults (msync,
GCMouse raw input, Option as Alt) at launch and prefix creation. Engines
installed earlier as "PearWine" are this same signed app and load as MetalSharp
Wine 6.0 without reinstalling.

Windows executable admission permits sections overlapping `SizeOfHeaders`,
as seen in GTA Vice City, while rejecting truncated raw sections and headers.
Real-game import and signed-runtime tests are opt-in; see
`SignedWineIntegrationTests.swift` and `ManagedAppTests.swift`.

### App data, removal and clean start

Compatibility iOS launches use `Games/<bundle-id>` under the selected storage
root for HOME, Documents, Library and temporary downloads. Older native-container
Documents/Library/tmp content is moved into that portable home before launch;
conflicts are preserved in `NativeMigrationConflicts/<bundle-id>`. Mac entries
use their private Data home; Wine entries use Data and their private Prefix.
The existing Move Storage flow copies these locations, retained saves, engines,
ODR and keychain data together, including to external storage.

Every GUI uninstall offers Cancel, Keep Saves and Remove App, or Delete
Everything. iOS save retention keeps Games, ODR, keychain and mappings. Managed
Mac/Wine retention stores the entry in `SavedData/<platform>/<id>`; reinstalling
the same ID restores Data/Prefix. Wine also restores missing program-side files.
Original program files remain available for recovery under Data/RetainedProgramFiles
on reinstall, so keeping saves can retain substantial disk space. Full removal
also removes the retained entry. CLI iOS uninstall accepts `--keep-saves`.

Settings → General → Clean start resets the **current marked library** after
confirmation and refuses while apps are running. It removes apps, engines,
retained saves, downloads, caches and local settings while retaining the storage
location/marker. Previous storage copies are separate: remove those with Remove
Previous Copy. Reset does not erase the disk or arbitrary files outside the root.

Native Mac applications can bypass HOME and write absolute host paths; these
paths cannot be universally redirected or identified for removal. Real Genshin
Impact downloads and real external-volume gameplay have not been verified by
the temporary-directory lifecycle tests. No live user save data is deleted by tests.

### Windows installers

Wine entries now use their engine's own graphics defaults; the GUI no longer
has a graphics API picker or DXVK/DXMT installation buttons. Existing explicit
backend metadata remains readable for old backups; GUI launches switch to the
engine defaults and restore DLLs previously mirrored by PearSilicon.

An EXE with a setup/install name or recognized installer markers is imported
as an installer and started. Unknown installers can use Run as Installer.
Complete the Windows installer UI normally. PearSilicon snapshots the private
C: drive, waits for the setup process and `wineserver -w` (including child
processes), then scans new/changed executables outside Windows system folders.
One clear program is selected automatically; ambiguous results open a program
picker. For installers that leave their application running, use Installation
Finished — Find Installed Apps. No result leaves the entry available to retry;
nonzero setup exits and missing usable programs leave installation unfinished.

The original setup path and the selected installed executable are stored
separately. Installed paths use `Prefix/drive_c/...` and launch with C: paths,
so the prefix, downloads, configuration and launch target move with storage.
Only EXEs inside the imported program folder or private C: drive are accepted.
Installer recognition is heuristic; it does not automate EULAs or install steps.
The synthetic setup test covers an early-exiting bootstrapper, delayed child,
prefix discovery, saved target and subsequent application launch. Real Steam
installation and Windows installer UIs have not been verified in that test.
