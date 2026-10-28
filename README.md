<p align="center">
  <img src="logo.png" alt="PearSilicon" width="160">
</p>

# PearSilicon

*A native iOS compatibility layer for macOS.*

**Version 0.1.9**

PearSilicon runs iOS applications natively on arm64 Macs by translating the
system APIs they expect. It is an independent, clean-room compatibility layer
for applications you legally own and prepare yourself. It does not modify
application logic or protection systems.

## Features

- Install an app package or an `.app` bundle and launch it as a normal macOS app.
- Keymapper, opt-in per app and off by default: tap, hold, joystick, mouse-look
  and swipe.
- Real multi-touch through the platform's own touch machinery.
- Per-app Metal HUD and pointer-lock controls.
- Mandatory repeat-rate protection in the keymapper.
- Local compatibility shims for keychain, screen, Metal, OpenGL, cloud, device,
  paths, on-demand resources, consent and networking.
- MIT-licensed.

## Requirements

- macOS 26 or later
- an arm64 Mac
- for the app and its project build commands: the platform's full development
  toolchain selected
- for the compatibility runtime alone: the Command Line Tools are enough

The app checks the toolchain at launch; `pearsilicon doctor` reports it from a
terminal. `./runtime/build.sh` works with either toolchain because the Catalyst
frameworks ship inside the macOS SDK.

## Install and run

1. Build the app or use a release bundle.
2. Open PearSilicon, add an app package or `.app` bundle, and launch it.

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

## Build

```sh
./scripts/build-app.sh          # app + runtime (full toolchain)
open build/PearSilicon.app

./scripts/make-zip.sh           # build/PearSilicon.zip

swift build
swift test
./runtime/build.sh              # runtime dylib only (Command Line Tools work)
```

## How it works

1. The installer prepares the app for macOS: it normalizes the `Info.plist`,
   patches the Mach-O images, and reduces universal binaries to `arm64`.
2. The runtime is loaded through an `LC_LOAD_DYLIB` entry. It is a clean-room
   API compatibility layer; it does not modify the app's own logic or memory.
3. The app is launched through LaunchServices on the `/System/iOSSupport`
   runtime, so it behaves like a regular foreground app.
4. The runtime supplies the compatibility shims and, when enabled, the keymapper.

### Compatibility shims

| Shim | Purpose |
| --- | --- |
| `KeychainShim` | local keychain store and software key generation |
| `ScreenShim` | make `UIScreen` follow the key window |
| `MetalLayerShim` | provide a Metal device and a usable drawable |
| `GLShim` | OpenGL ES entry point and drawable fitting |
| `CredentialShim` | safe client-credential handling |
| `CloudShim` | local-only key-value, ubiquity, CloudKit and GameKit surface |
| `DeviceShim` | coherent device identity |
| `PathShim` | keep app data, group containers and temporary files contained |
| `PointerLockShim` | per-app pointer-lock control |
| `ODRShim` | resolve packaged and user-supplied on-demand resources |
| `ServicesShim` | audio-session, haptics, store availability, remote-notification and background-task surfaces |
| `ConsentShim` | local consent entry points |
| `NetworkShim` | iOS-style request identity and HTTP/2 |
| `BeepShim` | silence the alert beep for unhandled keys |
| `libswiftUIKit` | source-built Swift UIKit compatibility overlay |

Each shim can be disabled with its `PEAR_NO_*` variable.

## App data

App data is kept under:

```
~/Library/Application Support/PearSilicon/Games/<bundle-id>/
  Documents/  Library/  Library/Caches/  Library/Group Containers/  tmp/
```

Override the root with `PEAR_HOME_DIR`.

Some apps keep content in On-Demand Resources that their package does not
carry. Put those bundles in the per-app ODR folder:

```
~/Library/Application Support/PearSilicon/ODR/<bundle-id>/
```

The folder accepts flat bundle files or a copy of the Addressables tree with a
`BuildTarget/` subdirectory. At launch the runtime merges it with the bundles
inside the app, without copying the files. Override the folder with
`PEAR_ODR_PATH=<dir>`.

## Per-app options

- **Metal HUD** — launches with `MTL_HUD_ENABLED=1`.
- **Pointer lock** — on by default; disable it if the cursor gets trapped.
- **iOS-like container** — part of the base environment and applied to every
  launch; there is no per-app switch.

Repeat-rate protection is always on and not configurable.

## Keymapper

The keymapper is opt-in and off by default. It can record a physical key, add a
tap, hold, joystick, mouse-look or swipe binding, and clear all bindings. Edits
apply live.

A keymap is a small JSON file per app:

```json
{
  "version": 1,
  "bundleID": "com.example.app",
  "bindings": [
    { "key": "wasd",  "action": { "joystick": { "center": { "x": 0.14, "y": 0.72 }, "radius": 0.1 } } },
    { "key": "space", "action": { "tap": { "_0": { "x": 0.9, "y": 0.82 } } } }
  ]
}
```

## Diagnostics

- `PEAR_LOG_FILE=<path>` writes the runtime log to a file.
- The iOS-like filesystem view is applied to every launch.
- `PEAR_ODR_PATH=<dir>` overrides the per-app folder for On-Demand Resources.
- `PEAR_DEBUG_SERVICES=1` logs the installed service surfaces.
- `PEAR_DEBUG_TOUCH`, `PEAR_DEBUG_SCREEN`, `PEAR_DEBUG_GL` and
  `PEAR_DEBUG_CLOUD` add logging.
- `PEAR_NO_*` disables a shim.
- `PEAR_DISABLE` loads the runtime without enabling its shims.
- `pearsilicon doctor` checks the toolchain, runtime and library.

## Clean-room

PearSilicon is an independent implementation written from scratch. It contains
no copied platform or application code, and it redistributes no platform
headers, frameworks, or binaries.

The compatibility layer is original work, intended only for applications you
legally own and prepare yourself. It is provided for interoperability and
educational use.

## License

MIT — see [LICENSE](LICENSE).
