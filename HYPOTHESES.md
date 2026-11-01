# Hypotheses — DELTARUNE black window (2026-10-31)

| ID | Hypothesis | Status | Evidence |
| --- | --- | --- | --- |
| H1 | wined3d's per-frame `glClear` (`GL_INVALID_FRAMEBUFFER_OPERATION`) is the root cause | **Rejected** | Only 1 occurrence, during context init (`context_gl.c:2246`, `new_drawable`); not per-frame. |
| H2 | DXMT is not loaded because of `WINEDLLPATH`/override ordering | **Confirmed** (mechanism) | Wine's builtin search checks `lib/wine` before `WINEDLLPATH` (`dlls/ntdll/unix/loader.c`). Log mapped the 417 KB runtime builtin, not DXMT's 5.35 MB. |
| H3 | DXMT builtin deployment works and fixes rendering | **Rejected in this engine** | DXMT loads, then `Failed to create metal view...` and `abort()`. |
| H4 | The engine's winemac.so lacks exported Metal-view symbols | **Confirmed** | `nm -gU winemac.so` shows only 2 exports; DXMT dlsyms `macdrv_functions`/`macdrv_view_create_metal_view`/`get_win_data`. |
| H5 | Windows present black frames because the window is hidden / stacking | **Rejected** | `+macdrv` shows 400+ presents to the on-screen 1280x960 window; one visible Wine window. |
| H6 | wined3d is producing black content for this GameMaker/D3D11 workload | **Confirmed (behavioral)** | Both wined3d GL and wined3d Vulkan renderers present but display stays black (user-confirmed). |
| H7 | A different D3D11 → Vulkan implementation (DXVK) renders correctly | **Confirmed** | DXVK-macOS 1.10.3 + MoltenVK: Metal swapchain created, `Entering main loop`, user saw the game. |
| H8 | Upstream DXVK 3.1.1 works on MoltenVK | **Rejected** | Device rejected: `geometryShader` unsupported. |

## Controller support (2026-11-01)

| ID | Hypothesis | Status | Evidence |
| --- | --- | --- | --- |
| C1 | The runtime has no GameController controller bridge (only keyboard/mouse) | **Confirmed** | Only `GCKeyboard`/`GCMouse` code in `PearRuntime.mm`. |
| C2 | macOS GameController exposes the Switch Pro to Catalyst apps | **Confirmed** | Catalyst probe received `connected Pro Controller` (~1 s after scene). |
| C3 | Genshin never queries controllers | **Rejected** | Runtime swizzle logged `app queried controllers -> 1`. |
| C4 | Genshin filters controllers by vendor/identity | **Confirmed (behavioral)** | It queried 1 controller but never logged `[MiHoYoGamepad]`; official iOS whitelist is Xbox/DualShock 4. |
| C5 | Normalizing the controller to an Xbox identity makes it acceptable | **Confirmed in probe** | Runtime/probe report `Xbox Wireless Controller`; Genshin relaunch verification pending. |
| C6 | Early checks miss the asynchronous connect notification | **Confirmed** | First `controllers` query returns 0, connect arrives ~1 s later. |
| C7 | Replaying the connect notification helps late observers | **Confirmed in probe** | `replay tick: 1 controller(s)` and a second connect event. |
