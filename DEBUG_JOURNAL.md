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
