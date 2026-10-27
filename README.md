<p align="center">
  <img src="logo.png" alt="PearSilicon" width="160">
</p>

# PearSilicon

*A native iOS compatibility layer for macOS.*

**Version 0.1.5**

> **Core philosophy**
>
> PearSilicon is built on the principles of **interoperability** and
> **clean-room engineering**. It translates system APIs so that legally owned
> iOS applications can run natively on macOS.
>
> - **Respect for platform protections.** We do not modify or patch platform
>   or application protection systems, and we do not alter how an application
>   enforces them. An application that needs this is out of scope and is
>   intentionally left unhandled.
> - **Fair play guaranteed.** An anti-macro guard is hard-coded and always on.
>   It cannot be disabled by the user. The keymapper refuses synthetic input or
>   turbo/macro speeds that exceed human capability, keeping multiplayer
>   environments fair.
> - **API translation only.** We do not add code to an application or alter its
>   logic or core binaries beyond declaring platform compatibility.
>
> Use this tool only with applications you have legally purchased and prepared
> from your own devices.

---

## Features

- **One-click install** — unzip an app package, prepare it for macOS, sign it.
- **Launch** through LaunchServices on the `/System/iOSSupport` runtime, so the
  app behaves like a real foreground app.
- **Keymapper**, opt-in per app and **off by default** — map physical keys to
  taps, holds, a virtual joystick, mouse-look and swipes. The editor can record
  the next key press, add a binding by gesture type, and clear all bindings.
- **Real multi-touch** — genuine, simultaneous touches through the platform's
  own virtual-touch machinery. No special permissions, no pointer lock: the
  cursor stays visible and can always leave the window.
- **App-owned overlay** — the keymapper UI is the app's own window over the
  target; no UI code is added to the target.
- **Metal HUD / FPS** — a per-app switch that launches with `MTL_HUD_ENABLED=1`,
  showing Metal's FPS, GPU time and memory overlay.
- **Per-app pointer lock** — on by default; a title that traps the cursor can
  have it disabled in that app's settings.
- **Repeat-rate protection** — always on and not configurable; the keymapper
  rejects implausibly fast repeated presses.
- **Clean-room**, MIT-licensed.

## Requirements

- macOS 26 or later
- an arm64 Mac
- the platform's full development toolchain (the Catalyst SDK ships with it)

The app checks the toolchain at launch and reports the exact selector command
if it is missing or not selected. `pearsilicon doctor` does the same from a
terminal.

## Install and first launch

1. Install the platform's full development toolchain, open it once, and select
   it. If it is not selected, the app shows the exact command.
2. Build the app (below) or use a release bundle.
3. Open the app, install an app package or an `.app` bundle, then launch.

## Build and run

```sh
./scripts/build-app.sh      # compile the app + runtime, assemble the bundle
open build/PearSilicon.app
```

To produce a distributable archive:

```sh
./scripts/make-zip.sh       # → build/PearSilicon.zip
```

For development:

```sh
swift build
swift test
./runtime/build.sh          # builds libPearRuntime.dylib for the target process
```

## Command line

The app binary also contains a CLI, so the same installer, signer and launcher
can be driven from a terminal:

```sh
bin/pearsilicon install ~/Downloads/App.app --launch
bin/pearsilicon launch com.example.app --log
bin/pearsilicon debug com.example.app --lldb
```

After installing the app, link the command once:

```sh
sudo ln -sf /Applications/PearSilicon.app/Contents/MacOS/PearSilicon \
               /usr/local/bin/pearsilicon
```

Full command reference: [docs/CLI.md](docs/CLI.md).

## How it works

1. **Install** — unzip the package, read its `Info.plist`, and move the `.app`
   into the library.
2. **Prepare for macOS** — rewrite `Info.plist`
   (`CFBundleSupportedPlatforms → MacOSX`, `DTPlatformName → macosx`), remove
   stale signature sidecars, patch every Mach-O image (`iOS → Mac Catalyst`,
   drop legacy min-version commands, normalize legacy load commands), and
   reduce universal binaries to the `arm64` slice.
3. **Load the runtime** — add an `LC_LOAD_DYLIB` entry so the dynamic linker
   loads `libPearRuntime.dylib` alongside the app. The runtime is a clean-room
   API compatibility layer for system surfaces such as CFNetwork, UIKit and
   device APIs. It does not modify the app's internal logic, memory, or
   protection systems. The older environment-variable loading path is refused
   for these processes; a real load command is honored. Sign inside-out.
4. **Launch** — spawn through LaunchServices with the `/System/iOSSupport` dyld
   search paths. A plain `posix_spawn` renders but is never *activated*, so the
   window server does not deliver input.
5. **Runtime** — inside the app: load the keymap, capture keyboard and mouse,
   synthesize touches, and supply the compatibility shims.
6. **Keymapper** — a small always-on-top button and a drag-to-place editor over
   the target window. No UI code is added to the target for it.

### Input: real multi-touch

A mapped key becomes a touch by driving the platform's own virtual-touch
machinery (`UINSVirtualDigitizer` / `UINSVirtualFinger`) — the same mechanism
behind Touch Alternatives on the Mac. Each binding drives a *named* finger, so
several can be down at once. Tap, hold, joystick, mouse-look and swipe are all
wired through it. This needs no Accessibility permission and never moves the
system cursor.

Two routes are kept only as diagnostics: **CGEvent** (single pointer, and the
post is dropped unless the poster is trusted for Accessibility) and
**IOHIDEvent** (inert on macOS, where touches arrive through the UIKitMac glue,
not an in-process HID client). See `runtime/TouchSynthesizer.mm`.

Input handlers are **chained**, not replaced: if the target installs its own
`GCMouse`/`GCKeyboard` handlers, both the target's and the runtime's run (the
target's first).

### Compatibility shims

| Shim | Purpose |
| --- | --- |
| `KeychainShim` | clean-room keychain store behind `SecItem*`/`SecKey`, with a synthetic access group for SDKs that read it back |
| `ScreenShim` | make `UIScreen` follow the key window instead of the whole display |
| `MetalLayerShim` | give a `CAMetalLayer` a device and a usable drawable, and recover a key window |
| `GLShim` | define `EAGLGetProcAddress` and aspect-fit oversized legacy OpenGL drawables |
| `CredentialShim` | return nil for a client credential that has no identity instead of trapping in CFNetwork |
| `CloudShim` | local-only account surface: key-value storage, ubiquity container, GameKit player IDs and CloudKit status; no remote account or credentials |
| `DeviceShim` | keep hardware and UIKit identity values coherent for device-profile selection |
| `PathShim` | keep the app's data inside its own container |
| `PointerLockShim` | per-app pointer-lock control, applied only to the live controller hierarchy |
| `ODRShim` | resolve on-demand resource requests to the bundles present in the package |
| `ConsentShim` | replace a consent SDK's UI entry points and report "no consent required" |
| `NetworkShim` | iOS-style `User-Agent` and device headers, HTTP/2 instead of QUIC |
| `BeepShim` | silence the AppKit alert beep for unhandled key presses |
| `libswiftUIKit` bridge | source-built compatibility overlay for the small set of Swift UIKit conveniences missing from the host runtime |

Each can be disabled with its `PEAR_NO_*` variable (see Diagnostics).

### Where app data lives

A windowed iOS app is not sandboxed, so by default its document directory is the
user's real documents folder, and apps scatter saves and caches across the home
directory. `PathShim` contains them under:

```
~/Library/Application Support/PearSilicon/Games/<bundle-id>/
```

`NSDocumentDirectory`, `NSLibraryDirectory`, `NSApplicationSupportDirectory`,
`NSCachesDirectory`, `NSUbiquitousContainer`-style lookups and
`NSHomeDirectory()` all resolve there. Override the root with `PEAR_HOME_DIR`.

### Per-app options

Each app's overview has two switches:

- **Metal HUD (FPS)** — launches with `MTL_HUD_ENABLED=1`. Metal renderers only.
- **Allow pointer lock** — lets the app take pointer lock. On by default; turn it
  off if the cursor gets trapped in the window.

Repeat-rate protection is not a switch: it is always on.

### Keymapper

- **Opt-in toggle** (per app, default off) — when off, no keymap is passed and
  the runtime installs no input handlers at all.
- **Key recording** — the keyboard button records the next physical key, so the
  binding follows that key rather than the current layout's character.
- **Gesture picker** — the add menu creates a tap, hold, joystick, mouse-look or
  swipe binding directly; changing the picker later keeps the marker position.
- **Clear all** — removes every binding for the app after confirmation.
- **Repeat-rate protection** — always on, not configurable. It drops presses
  faster than a human hand, per key and across all keys. Releases are never
  blocked.
- **Joystick** — touch-down starts at the binding centre, then the finger drags
  to `centre + direction × radius`. The centre is dragged directly on the canvas;
  the radius has a slider and is drawn as a dashed ellipse.
- **Stop** — a red button stops a running app; quitting the app asks before
  stopping running targets.
- The runtime reloads the keymap as the overlay saves it, so edits apply live.

### Keymap format

One JSON file per app (`bindings` drive touches; coordinates are normalized 0–1):

```json
{
  "version": 1, "bundleID": "com.example.app", "engine": "unity",
  "bindings": [
    { "key": "wasd",  "action": { "joystick":  { "center": { "x": 0.14, "y": 0.72 }, "radius": 0.1 } } },
    { "key": "mouse", "action": { "mouseLook": { "region": { "x": 0.2, "y": 0.1, "width": 0.6, "height": 0.8 }, "sensitivity": 1 } } },
    { "key": "space", "action": { "tap":       { "_0": { "x": 0.9, "y": 0.82 } } } },
    { "key": "shift", "action": { "hold":      { "_0": { "x": 0.85, "y": 0.9 } } } }
  ]
}
```

Actions: `tap`, `hold`, `joystick`, `mouseLook`, `swipe`.

## Diagnostics

The runtime is driven by environment variables, set when launching the app
(`PEAR_KEYMAP` and friends are handled automatically; the rest are for
debugging).

| Variable | Effect |
| --- | --- |
| `PEAR_LOG_FILE=<path>` | also write logs to a file (the unified log redacts values) |
| `PEAR_DEBUG_TOUCH` | log input translation and touches |
| `PEAR_DEBUG_SCREEN` / `PEAR_DEBUG_VIEWS` | dump screen metrics / the view and layer trees |
| `PEAR_DEBUG_GL` | dump how the app sizes its GL surface |
| `PEAR_NO_SCREEN_SHIM`, `PEAR_NO_METAL_FIX`, `PEAR_NO_CLOUD_SHIM`, `PEAR_NO_DEVICE_SHIM`, `PEAR_NO_CREDENTIAL_SHIM`, `PEAR_NO_PATH_SHIM`, `PEAR_NO_ODR_SHIM`, `PEAR_NO_CONSENT_SHIM`, `PEAR_NO_NETWORK_SHIM` | disable a shim |
| `PEAR_NO_GL_FIT` | leave an oversized legacy OpenGL drawable untouched |
| `PEAR_NETWORK_KEEP_UA` | keep an app-supplied non-Mac `User-Agent` instead of replacing it |
| `PEAR_FAKE_IOS_VERSION`, `PEAR_DEVICE_MODEL` | values reported in the device and network headers (default `16.0`, `iPhone15,2`) |
| `PEAR_DEVICE_NAME`, `PEAR_DEVICE_IDIOM` | user-visible model name and `phone`/`pad` idiom |
| `PEAR_DEVICE_KERNEL`, `PEAR_DEVICE_UNAME` | opt in to kernel-release and `uname` identity overrides |
| `PEAR_DEVICE_UI_DETAILS` | opt in to vendor-token and layout-idiom overrides |
| `PEAR_DEBUG_CLOUD` / `PEAR_DEBUG_METAL` | log cloud compatibility and Metal-layer recovery |
| `PEAR_ALLOW_POINTER_LOCK` | let the target keep the pointer locked (pointer-lock shim off) |
| `PEAR_KEEP_BEEP` | keep the platform alert beep for unhandled key presses |
| `PEAR_DEBUG_BEEP` | log the beep hook that was installed |
| `PEAR_DEBUG_CONSENT` | log the consent classes found and each method's return-type kind |
| `PEAR_NO_GAME_TWEAKS` | skip the user-provided `tweaks.json` option fixes applied before launch |
| `PEAR_MOUSE_CAPTURE=1` | opt in to keeping the cursor inside the window during mouse look |
| `PEAR_DEBUG_POINTER` | log which classes had pointer lock disabled |
| `PEAR_TEST_TAP_AT=x,y[,seconds]` | diagnostic: synthesize one tap (default 8 s after launch) |
| `PEAR_HOME_DIR` | override where the app's data is contained |
| `PEAR_DISABLE` | load the runtime but do nothing |
| `PEAR_TEST_TAP`, `PEAR_TEST_MULTITOUCH`, `PEAR_TEST_LOOK`, `PEAR_TEST_SWIPE` | self-tests |

## Clean-room

This project is written from scratch as an interoperability layer:

- **No platform-vendor code.** No source, header or binary from the platform
  vendor is copied or redistributed. The runtime reaches the platform through
  its runtime *interfaces* — `dlsym` for private symbols, Objective-C message
  sends, method swizzling and `__DATA,__interpose` — the same technique used by
  any compatibility shim. A few private symbol names and numeric event/field
  constants are referenced; those are interface facts, not implementation.
- **No application code.** Nothing is copied from or derived from application
  binaries. Behaviour was learned from the outside (observing what the system
  does for a real touch, a real launch, a real frame) and reimplemented here.
- **No titles named in the repository.** Shims match the SDK's own metadata and
  discover assemblies through the platform's runtime API. Title-specific detail
  lives in per-app settings, never in `runtime/` or the repository docs.
- **A compatibility layer, not a patch.** `LC_LOAD_DYLIB` is used only so the
  dynamic linker loads the runtime. The runtime supplies clean-room
  implementations of system surfaces (CFNetwork, UIKit, device APIs); it does
  not modify the app's internal logic, memory, or protection systems.
- **Respect for platform protections.** Applications that need a protection
  system modified to run are out of scope and are intentionally left unhandled.

Using private platform interfaces may be restricted by the platform vendor's
terms for signed/store software; that is a separate question from the origin of
this code.

## Scope and limitations

- **Legacy OpenGL titles** can create a drawable larger than their window before
  the scene is attached. `GLShim` aspect-fits that drawable and keeps its native
  renderbuffer so the whole frame stays visible; use `PEAR_NO_GL_FIT` to opt out.
- **On-demand resources cannot be downloaded on a Mac.** Some titles keep most
  of their content in store-delivered packs that a packaged archive may not
  contain. `ODRShim` makes the request succeed and logs which tag is missing,
  but the content must already be present in the package.
- **A bad ZIP CRC does not abort the install.** `unzip` still extracts the
  remaining entries; the installer reports the damaged files as
  `corruptedFiles`. A damaged asset can still crash the app, so re-download the
  package if that happens.
- **Automatic keymap** means an engine-aware *template*, not computer vision on
  live frames.

## License

MIT — see [LICENSE](LICENSE).
