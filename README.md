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
Catalyst and `/System/iOSSupport` frameworks, manages native Mac apps, and runs
Windows games in isolated Wine prefixes. An in-process runtime adds targeted
compatibility shims and optional keyboard, mouse and controller mapping.

It is **not** an iOS emulator, a UIKit reimplementation, or a Windows VM. Use it
only with apps and games you are authorized to run.

## Highlights

| Platform | What it does |
| --- | --- |
| **iOS Apps** | IPA / device `.app` preparation, Catalyst runtime shims, Metal HUD, pointer lock, opt-in keymapper |
| **Mac Apps** | Copy-only `.app` import with redirected data, launched natively |
| **Wine Games** | Per-game prefixes, private data, verified engines, DXVK or DXMT graphics |
| **Library** | iOS, Mac and Wine tabs; movable library; per-entry `.pearbackup` backups |
| **Input** | GameController pads, controller/keyboard keymapper, analog right-stick camera |
| **Updates** | Explicit **Check for Updates**, staged verification, development builds |

- **iOS:** installs an authorized IPA or `.app`, patches the copy to Mac Catalyst,
  re-signs it, and loads `libPearRuntime.dylib` inside the app process.
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
tested commit and scope. If macOS blocks the first launch, use
**System Settings → Privacy & Security → Open Anyway** or right-click → **Open**.

### Build from source

```sh
./scripts/build-app.sh release     # app + runtime
open build/PearSilicon.app

./scripts/make-zip.sh release      # build/PearSilicon.zip
swift test                         # test suite
./runtime/build.sh                 # runtime dylib only
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
- Genshin Impact’s iOS build does not expose its native controller mode on Mac;
  its Control Type remains “Touchscreen”. Controller keymapper bindings still
  drive its touch controls.

Configure bindings in the in-app **Keymap** tab.

## Wine, engines and graphics

Imported games live under `wine-apps/<id>/` with `Payload`, `Data` and `Prefix`.
The prefix is private to the game; absolute host drive mappings are removed.

- Install open-source WineHQ **Staging** or **Development** engines from
  **Settings → Wine**, or register a local runtime.
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
tests are documented in `docs/TESTING.md`.

A successful launch is not a gameplay-compatibility result. No controlled
benchmark establishes a performance advantage over PlayCover.

## Limitations

- Compatible iOS apps still depend on Apple’s Catalyst/iOSSupport stack.
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
