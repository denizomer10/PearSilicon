# Architecture

PearSilicon is a **Mac Catalyst-based compatibility project** for supported arm64
iOS apps on macOS. It prepares installed app copies and adds an in-process
compatibility runtime on top of Apple's frameworks. It is not an independent
implementation of iOS, UIKit or a device kernel.

## Execution path

1. The installer extracts an IPA or copies an iOS device `.app` bundle.
2. It prepares that copy: normalizes metadata, thins supported binaries to
   `arm64`, changes relevant Mach-O platform metadata to **Mac Catalyst (6)**,
   adds compatibility dependencies and ad-hoc signs the result.
3. The launcher directs framework/library lookup to Apple's
   `/System/iOSSupport` stack. UIKit and other Apple frameworks execute in the
   app's process; they are not replaced by PearSilicon implementations.
4. `libPearRuntime.dylib` loads in that same process and installs API hooks,
   local compatibility surfaces and optional keymapper handlers.

The source IPA is not changed. The installed copy **is modified and re-signed**,
including when launcher-based runtime loading is selected. CPU execution is
native arm64, but that does not imply an unmodified app or an Apple-independent
environment.

Implementation references:
[`BinaryPatcher.swift`](../Sources/PearSilicon/Core/Services/BinaryPatcher.swift),
[`PackageInstaller.swift`](../Sources/PearSilicon/Core/Services/PackageInstaller.swift),
[`AppLauncher.swift`](../Sources/PearSilicon/Core/Services/AppLauncher.swift) and
[`runtime/build.sh`](../runtime/build.sh). The runtime build target is
`arm64-apple-ios15.0-macabi`, linked against Apple frameworks including UIKit,
Foundation, Metal and QuartzCore.

## Runtime loading modes

| | Default load-command mode | Experimental environment-injection mode |
| --- | --- | --- |
| Runtime loading | An `LC_LOAD_DYLIB` entry in the prepared executable | Launcher-supplied `DYLD_INSERT_LIBRARIES` |
| Runtime location | Inside the app process | Inside the app process |
| Library scope | Full `libPearRuntime.dylib` | The same full `libPearRuntime.dylib` |
| Separate state service | No managed host session | Local KV backing state and static device-profile configuration |
| Apple compatibility frameworks | Required | Required |
| Installed-copy preparation/signing | Required | Required |

An environment-injection app needs the PearSilicon launcher to supply its
runtime and host handoff. The mode is retained on subsequent managed launches
unless explicitly changed. Neither mode selectively loads only the shims an
app needs, and disabling a hook does not remove its code from the loaded library.

## Experimental host-service split

The launcher starts an authenticated, headless host before starting the game.
It verifies readiness and a static device-profile snapshot, then passes the
handoff to the game. The runtime's local KV client connects after loading;
device and network-header lookups read a startup C snapshot rather than making
per-query IPC calls.

The host currently owns only:

- Local `NSUbiquitousKeyValueStore` backing state.
- Static device-profile configuration/identity policy.

UIKit integration, input, rendering hooks, audio hooks, device API interception
and keychain handling remain in-process. The split does not currently reduce
the injected library. See the [CLI host-service reference](CLI.md#experimental-host-service-split)
for protocol limits, lifecycle and failure behavior, and
[`HostService.swift`](../Sources/PearSilicon/Core/Runtime/HostService.swift),
[`runtime/HostService.mm`](../runtime/HostService.mm) and
[`runtime/DeviceProfile.mm`](../runtime/DeviceProfile.mm) for implementation.

## What the shims do—and do not do

- **Graphics:** [`MetalLayerShim`](../runtime/MetalLayerShim.mm) adjusts existing
  Metal devices, layers, drawable sizes and texture descriptors. It does not
  replace the game's renderer, rewrite shaders or provide a general graphics
  translation engine. Rendering still uses the game's engine and Apple's stack.
- **Paths:** [`PathShim`](../runtime/PathShim.mm) redirects supported directory
  APIs. This is not a new filesystem or enforcement of filesystem isolation.
  Launcher-provided root variables matter; direct Finder launches do not infer
  the selected storage location. See [storage limitations](CLI.md#storage-location).
- **Cloud surfaces:** [`CloudShim`](../runtime/CloudShim.mm) supplies local-only
  compatibility behavior, not access to real iCloud/Game Center accounts or
  equivalent online service functionality.
- **Device identity:** synthetic descriptors can satisfy some API expectations;
  they do not turn the Mac into genuine iOS hardware or grant missing OS features.
- **Controls:** hook opt-outs vary by component. `PEAR_DISABLE` skips the main
  runtime bootstrap, including the keymapper; separate shim initializers can
  still run, so it is not a global no-hooks mode.

## Wine/Proton and PlayCover comparisons

Wine implements a loader and Windows APIs using host-system facilities.
PearSilicon instead relies on Apple's existing Mac Catalyst/iOSSupport framework
implementations, with additional hooks and local shims. The experimental
host-service work has a limited similarity to separating state management from
in-process API handling; it does **not** make the overall project a Wine/Proton-style
reimplementation of iOS.

PearSilicon and PlayCover/PlayTools share the broad approach of app preparation,
Apple compatibility frameworks and an injected in-process runtime. Custom API
hooks, input mapping and local service shims are not, by themselves, a categorical
difference from that approach. Implementation details can differ, but neither
architectural similarity nor a runtime's name establishes source-code provenance.
No clean-room provenance certification is claimed here.

Upstream descriptions: [Wine introduction](https://github.com/wine-mirror/wine#introduction)
and [PlayTools: how it works](https://github.com/PlayCover/PlayTools#how-it-works).

## Performance, compatibility and safety

- There are no published controlled benchmarks here establishing lower RAM/CPU
  use, higher FPS or lower latency than PlayCover. Shims and a separate host can
  add overhead; comparisons must include the whole process tree and matched apps,
  hardware, settings and test conditions.
- Unit tests and headless IPC tests validate their specific paths. A short
  startup/aliveness/shutdown check does not validate menus, touch coordinates,
  downloads, sustained gameplay, rendering correctness or frame pacing.
- Background GUI startup does not establish that GUI installation, drag-and-drop
  or settings interactions work end to end. A CLI install test is not a GUI test.
- The prebuilt bundle includes PearSilicon's libraries, but some app-preparation
  and relocation paths still require Command Line Tools. That is not a fully
  tool-free clean-Mac installation guarantee.
- [`SandboxShim`](../runtime/SandboxShim.mm) requests a macOS sandbox profile
  through `sandbox_init`; if accepted, macOS enforces those rules. The experimental
  `--sandboxed` route uses `sandbox-exec`. Both profiles use `(allow default)`
  with selected path denials, not comprehensive app isolation or iOS kernel
  emulation. Socket authentication controls host protocol access; it is not
  isolation from all same-user processes. Do not treat these mechanisms as a
  security boundary for untrusted apps.

For setup and current limitations, see the [README](../README.md) and
[CLI reference](CLI.md). Release notes identify the tested build separately from
ongoing source/documentation changes.
