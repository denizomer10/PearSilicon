# Debug Journal — 2026-10-31 (Wine graphics / DELTARUNE)

Environment: macOS 27.2 (26B123), M1, Wine Staging 11.21 x86_64 (Gcenx),
engine `~/Library/Application Support/PearSilicon/Engines/wine-staging-11-21`.
Test game: DELTARUNE. All destructive tests ran on clones in `/tmp`; the real
engine/prefix were not modified until the final integration step.

## E1 — Baseline GL wined3d (real engine, 30 s)
Command: `PEAR_WINEDEBUG="err+d3d,err+wined3d,..." sh .build/dxmt-start.sh moltenvk`
Observation: game reaches `Entering main loop`, audio, window on screen
(1280x992), **1** GL error only:
`GL_INVALID_FRAMEBUFFER_OPERATION from glClear @ context_gl.c:2246` during
`wined3d_context_gl_init` (`new_drawable`).
Conclusion: H1 rejected; the error is an init-time clear of an incomplete
default framebuffer.

## E2 — Window/present tracing (+macdrv)
Observation: for HWND 0x100a0, 1160 `client_surface_update`, 413+ presents;
window `show_window`, title `DELTARUNE Chapter 1` → `CONTACT`; one on-screen
1280x960 client. Conclusion: presentation happens; window is visible.

## E3 — wined3d Vulkan renderer (`WINE_D3D_CONFIG=renderer=vulkan`)
Observation: `Using the Vulkan renderer.`; MoltenVK active; thousands of
`VK_ERROR_OUT_OF_POOL_MEMORY` warnings (active drawing). User: still black.
Conclusion: wined3d is the common failing component (H6).

## E4 — DXMT upstream builtin install on a cloned engine
Files: runtime `lib/wine/x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll`,
`x86_64-unix/winemetal.so`; prefix system32 `winemetal.dll`; **no overrides**.
Observation: DXMT does load (DXMT log lines, feature level 11_1), then
`err: Failed to create metal view, it seems like your Wine has no exported
symbols needed by DXMT.` and `abort()`.
Conclusion: H3 rejected; H4 confirmed (winemac.so exports only
`___wine_unix_call_funcs`, `___wine_unix_call_wow64_funcs`).

## E5 — DXMT via system32 + `n,b` overrides
Observation: Wine mapped the runtime's 417 KB builtin, not DXMT (`lsof` /
`+module`), because builtin search order checks `lib/wine` first. Conclusion:
H2 mechanism confirmed; this integration cannot work as designed.

## E6 — DXVK 3.1.1 (upstream) with MoltenVK
Observation: `Skipping: Device does not support required feature
'geometryShader'`, `No adapters found`, `Failed to initialize DXVK`.
Conclusion: H8 rejected.

## E7 — DXVK-macOS 1.10.3 (Gcenx) with MoltenVK
Prefix clone; `x64/{d3d11,d3d10core}.dll` into `system32`;
`WINEDLLOVERRIDES="d3d11,d3d10core=n;winemenubuilder.exe=d"`.
Observation:
```
info: DXVK: v1.10.3-20230507-async (macOS)
[mvk-info] Created 3 swapchain images ... CAMetalLayer: WineMetalView ... on screen Main Screen
Entering main loop.
```
User confirmed the game is visible. Conclusion: H7 confirmed → implement as
an app component.

## Artifacts
`.build/dxvk-start.sh`, `.build/dxvk-stop.sh`, `.build/dxvk-test.sh`,
`.build/dxmt-builtin-diag.sh`, `.build/dxmt-builtin-start.sh`,
`.build/dxmt-builtin-stop.sh`, `.build/all-windows.swift`.
Hashes pinned in STATUS.md §2.4.


## 2026-11-01 — Controller support (Genshin / Catalyst)

Environment: same M1 / macOS 27.2. Controllers: Bluetooth „Pro Controller"
(Nintendo Switch Pro, VID 0x057E/PID 0x2009) and gamecontrollerd's synthetic
``GamePad-1`` (Microsoft Xbox 360 logical device).

### E8 — Catalyst GameController probe
A scene-based Mac Catalyst app (`/tmp/CatProbe2.app`) logged:
```
[catprobe2] scene controllers=0
[catprobe2] connected Pro Controller
[catprobe2] t+1 controllers=1 vendor=Pro Controller extended=true
```
Conclusion: iOS-on-Mac apps receive controllers, but enumeration is asynchronous;
an app that checks once at launch can see zero.

### E9 — Genshin process (runtime diagnostics)
With an instrumented runtime and `PEAR_DEBUG_GC=1`:
```
[PearRuntime][input] game controllers at bootstrap: 0
[PearRuntime][input] game controller connected: Pro Controller extended=1 micro=1
[PearRuntime][input] app queried controllers -> 1
[PearRuntime][input] MHYGameController class=MHYGameController
```
Genshin does query controllers and sees the Pro Controller, but never logs
`[MiHoYoGamepad] …`. Its official iOS whitelist is Xbox / Xbox Elite / DualShock
4, so the Switch controller is filtered out by identity.

### E10 — Identity normalization + replay (default-on)
Swizzled `GCController.vendorName`/`productCategory` for non-Xbox/PlayStation
controllers and replayed `GCControllerDidConnectNotification` once after 3 s.
Probe via `open --env DYLD_INSERT_LIBRARIES=…`:
```
[PearRuntime][input] controller 'Pro Controller' reported as Xbox Wireless Controller
[catprobe2] connected Xbox Wireless Controller
[catprobe2] t+1 vendor=Xbox Wireless Controller
[PearRuntime][input] replay tick: 1 controller(s)
```
Conclusion: the shim presents the Switch Pro as an Xbox controller and replays
the connection. Genshin's runtime copy was updated; its running process keeps the
old inode until relaunch.

### Disk cleanup (same day)
Removed `.build` (31 GB), `/tmp/pear-*` clones (~2.2 GB) and three regenerable
caches (~680 MB). `/System/Volumes/Data` free space went 14 GB → 37 GB. The
Genshin game-data directory (32 GB) and all app data were left untouched.
